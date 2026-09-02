#!/usr/bin/env bash
#
# workstation-oom-hardening
#
# 학습 워크로드가 메모리를 다 써서 시스템이 멈췄을 때, 물리 접근 없이 복구되게 만든다.
#
#   sudo bash install.sh      설치 (재실행 안전)
#   sudo bash verify.sh       검증
#   sudo bash uninstall.sh    전체 롤백
#
# 워크로드에는 cgroup 상한을 걸지 않는다. 메모리가 고갈되면 earlyoom 이 먼저
# 개입하고, 그래도 전역 OOM 에 도달하면 커널 패닉 -> 자동 재부팅으로 복구한다.
# 원격 접속 데몬만 항상 살아있도록 메모리를 예약한다.
#
# 설정은 config.env 로 분리되어 있다. config.env.example 참고.
#
set -euo pipefail

# ===========================================================================
#  기본값 -- 고치려면 이 파일이 아니라 config.env 를 만드세요
# ===========================================================================
NFS_MOUNTS=""
WDT_MODULE=""
RUNTIME_WATCHDOG="60"
REBOOT_WATCHDOG="10min"
REMOTE_UNITS=(
  "ssh.service:64M"
  "ssh@.service:64M"
  "tailscaled.service:128M"
  "rustdesk.service:512M"
  "gdm.service:256M"
)
RSV_USER_SLICE="256M"
REMOTE_PROCS=(sshd tailscaled rustdesk gdm3)
EARLYOOM_THRESHOLDS="10,5"
EARLYOOM_REPORT_INTERVAL="3600"
EARLYOOM_AVOID='^(sshd|ssh|tailscaled|tailscale|rustdesk|systemd|systemd-.*|dbus-daemon|dbus-broker|gdm3|gdm-.*|gnome-shell|gnome-session.*|Xorg|Xwayland|NetworkManager|wpa_supplicant|login|agetty|sudo|su|bash|zsh|earlyoom|k3s-server|k3s|containerd|containerd-shim|dockerd|kubelet)$'
EARLYOOM_PREFER='^(python3?|pt_main_thread|pt_data_worker|pt_autograd_.*|ray::.*|jupyter.*|torchrun|deepspeed|accelerate|node|next-server.*|chrome|java)$'
DISABLE_SWAP=1
DELETE_SWAP_FILE=0
HUNG_TASK_TIMEOUT="120"
PANIC_REBOOT_DELAY="10"
INOTIFY_INSTANCES="1024"
INOTIFY_WATCHES="524288"
# ===========================================================================

if [[ $EUID -ne 0 ]]; then echo "root 권한이 필요합니다: sudo bash $0" >&2; exit 1; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$HERE/config.env" ]] && source "$HERE/config.env"

DOC_URL="https://github.com/loopin51/workstation-oom-hardening"
BACKUP="/root/oom-hardening-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
backup() { [[ -e "$1" ]] && cp -a "$1" "$BACKUP/$(echo "$1" | tr '/' '_')" || true; }
have_unit() { systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q . ; }

say "백업 위치: $BACKUP"
[[ -f "$HERE/config.env" ]] && echo "  설정: $HERE/config.env" || echo "  설정: 기본값 (config.env 없음)"

# ---------------------------------------------------------------------------
# 0. 사전 점검 -- hung_task_panic=1 은 즉시 재부팅을 유발할 수 있다
# ---------------------------------------------------------------------------
say "0/7  사전 점검"
DSTATE="$(ps -eo state,pid,comm --no-headers | awk '$1=="D"{print "    "$2" "$3}')"
if [[ -n "$DSTATE" ]]; then
  warn "현재 D 상태(uninterruptible)인 프로세스가 있습니다:"
  echo "$DSTATE"
  warn "hung_task_panic=1 적용 직후 재부팅될 수 있습니다."
  read -r -p "  그래도 계속할까요? [y/N] " a; [[ "${a,,}" == "y" ]] || exit 1
else
  echo "  D 상태 프로세스 없음"
fi

# ---------------------------------------------------------------------------
# 1. NFS hard -> soft,softerr
# ---------------------------------------------------------------------------
# hard 마운트는 서버가 응답하지 않으면 접근 프로세스를 D 상태로 무한 대기시킨다.
# hung_task_panic=1 과 만나면 NAS 가 잠깐 끊기는 것만으로 워크스테이션이 재부팅된다.
say "1/7  NFS 마운트 옵션"
if [[ -z "$NFS_MOUNTS" ]]; then
  echo "  NFS_MOUNTS 미설정 - 건너뜀"
else
  # 옵션 문자열에서 hard/soft/softerr/timeo/retrans 를 걷어내고 새로 붙인다.
  retune_opts() {
    local out=() o
    IFS=',' read -ra _o <<< "$1"
    for o in "${_o[@]}"; do
      case "$o" in
        hard|soft|softerr|timeo=*|retrans=*) ;;
        *) out+=("$o") ;;
      esac
    done
    out+=(soft softerr timeo=100 retrans=3)
    (IFS=','; echo "${out[*]}")
  }

  changed=0
  backup /etc/fstab
  tmp="$(mktemp)"
  while IFS= read -r line; do
    read -ra f <<< "$line"
    if [[ "$line" =~ ^[[:space:]]*# ]] || (( ${#f[@]} < 4 )); then
      printf '%s\n' "$line" >> "$tmp"; continue
    fi
    # fstype 이 nfs 계열이고, 대상 마운트 지점이며, hard 옵션이 있는 줄만
    if [[ "${f[2]}" == nfs* ]] && [[ " $NFS_MOUNTS " == *" ${f[1]} "* ]] \
       && [[ ",${f[3]}," == *",hard,"* ]]; then
      printf '# changed by oom-hardening (was: %s)\n' "${f[3]}" >> "$tmp"
      printf '%s %s %s %s %s %s\n' "${f[0]}" "${f[1]}" "${f[2]}" \
             "$(retune_opts "${f[3]}")" "${f[4]:-0}" "${f[5]:-0}" >> "$tmp"
      changed=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < /etc/fstab

  if (( changed )); then
    cat "$tmp" > /etc/fstab
    grep -A1 'changed by oom-hardening' /etc/fstab | sed 's/^/    /'
    for m in $NFS_MOUNTS; do
      mount -o remount "$m" 2>/dev/null || true
      if mount | grep -q " $m .*[,(]hard"; then
        warn "$m 이 사용 중이라 지금은 remount 불가 -> 다음 재부팅 시 적용됩니다."
      fi
    done
  else
    echo "  변경 대상 없음 (이미 적용되었거나 hard 마운트 없음)"
  fi
  rm -f "$tmp"
fi

# ---------------------------------------------------------------------------
# 2. sysctl -- OOM / hung task 시 패닉 후 자동 재부팅
# ---------------------------------------------------------------------------
say "2/7  sysctl (/etc/sysctl.d/99-oom-reboot.conf)"
backup /etc/sysctl.d/99-oom-reboot.conf
cat > /etc/sysctl.d/99-oom-reboot.conf <<EOF
# workstation-oom-hardening
# $DOC_URL

# 시스템 전역 OOM 발생 시 커널 패닉.
# 값 1은 "전역 OOM"에만 반응하고, cgroup 상한 초과로 발생한 OOM에는 반응하지 않는다.
# (컨테이너가 자기 limits 를 넘겨 죽는 경우 등은 재부팅으로 이어지지 않는다)
# 값 2로 하면 cgroup OOM 에도 패닉하므로 절대 사용하지 말 것.
vm.panic_on_oom=1

# 패닉 후 자동 재부팅까지의 대기 시간
kernel.panic=$PANIC_REBOOT_DELAY

# D 상태(uninterruptible)로 멈춘 태스크 감지 시 패닉 -> kernel.panic 경로로 재부팅.
# NFS 를 hard 로 쓰고 있다면 서버 다운 시 오탐이 나므로 soft,softerr 로 바꿀 것.
kernel.hung_task_panic=1
kernel.hung_task_timeout_secs=$HUNG_TASK_TIMEOUT

# oops 발생 시에도 패닉 (배포판 기본값 1, 명시적으로 고정)
kernel.panic_on_oops=1

# OOM 시 태스크 목록을 로그에 남겨 사후 분석 가능하게
vm.oom_dump_tasks=1

# 스왑을 끄므로 swappiness 는 사실상 무의미하지만 명시
vm.swappiness=0

# inotify 한계 상향. 기본값 128 instances 는 컨테이너를 여러 개 돌리면 쉽게
# 소진되어 systemctl 이 "Too many open files" 를 낸다.
fs.inotify.max_user_instances=$INOTIFY_INSTANCES
fs.inotify.max_user_watches=$INOTIFY_WATCHES
EOF
sysctl --system >/dev/null
for k in vm.panic_on_oom kernel.panic kernel.hung_task_panic kernel.hung_task_timeout_secs \
         kernel.panic_on_oops fs.inotify.max_user_instances; do
  printf '    %-34s = %s\n' "$k" "$(sysctl -n $k)"
done

# --- kubelet 이 vm.panic_on_oom 을 0으로 되돌리는 문제 ----------------------
# kubelet 은 기동할 때마다 자기 요구 값을 강제로 쓴다:
#   vm.overcommit_memory=1  vm.panic_on_oom=0  kernel.panic=10  kernel.panic_on_oops=1
# 쿠버네티스는 파드 OOM 으로 노드가 죽는 걸 원하지 않기 때문인데, 여기서는 정반대로
# 전역 OOM 시 재부팅되기를 원한다. 기동 직후 다시 써주고 타이머로도 재확인한다.
say "2b   kubelet 의 sysctl 되돌림 방지"
K8S_FOUND=0
for u in k3s.service kubelet.service k3s-agent.service; do
  have_unit "$u" || continue
  K8S_FOUND=1
  mkdir -p "/etc/systemd/system/${u}.d"
  cat > "/etc/systemd/system/${u}.d/10-restore-panic-on-oom.conf" <<'EOF'
# ExecStartPost 만 추가하는 drop-in 이라 패키지를 업그레이드해도 안전하다.
# (ExecStart 를 복제하지 않으므로 실행 인자가 바뀌어도 영향 없음)
[Service]
ExecStartPost=/usr/sbin/sysctl -q -w vm.panic_on_oom=1
EOF
  echo "  $u ExecStartPost drop-in 설치"
done
(( K8S_FOUND )) || echo "  쿠버네티스 유닛 없음 - drop-in 생략 (타이머는 그대로 설치)"

cat > /etc/systemd/system/oom-sysctl-enforce.service <<EOF
[Unit]
Description=Re-assert OOM sysctl values overwritten by kubelet
Documentation=$DOC_URL

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -q -p /etc/sysctl.d/99-oom-reboot.conf
EOF

cat > /etc/systemd/system/oom-sysctl-enforce.timer <<EOF
[Unit]
Description=Re-assert OOM sysctl values every minute

[Timer]
# kubelet 의 ExecStartPost 는 kubelet 이 sysctl 을 쓰기 전에 실행될 수도 있다.
# (Type=notify 라 apiserver 준비 시점에 돌고, 내장 kubelet 은 그 뒤에 뜰 수 있음)
# 그 틈을 1분 이내로 좁힌다. sysctl 호출 한 번이라 비용은 무시할 수준이다.
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
echo "  1분 주기 타이머로 vm.panic_on_oom=1 재확인"

# ---------------------------------------------------------------------------
# 3. 하드웨어 워치독
# ---------------------------------------------------------------------------
say "3/7  하드웨어 워치독"
backup /etc/modprobe.d/hw-watchdog.conf
cat > /etc/modprobe.d/hw-watchdog.conf <<'EOF'
options iTCO_wdt nowayout=0
options sp5100_tco nowayout=0
# BMC 워치독. action=reset 이면 핑이 끊겼을 때 BMC 가 직접 리셋을 건다.
# start_now=0 이라 systemd 가 열기 전에는 카운트가 시작되지 않는다.
options ipmi_watchdog action=reset timeout=60 nowayout=0 start_now=0
# softdog 폴백: 타임아웃 시 패닉을 유발해 로그를 남기고 kernel.panic 으로 재부팅
options softdog soft_panic=1 soft_margin=60
EOF

# 후보 결정: 명시값 > 칩셋 워치독 > BMC(IPMI) 워치독 > softdog
#
# 서버 보드에서는 칩셋 워치독이 안 붙는 경우가 많다. BMC 가 TCO 영역을 점유해
# lpc_ich 가 MFD 셀을 만들지 못하기 때문이다. 커널 로그에 이렇게 남는다:
#   lpc_ich 0000:00:1f.0: I/O space for ACPI uninitialized
#   lpc_ich 0000:00:1f.0: No MFD cells added
# 이때 /dev/ipmi0 이 있으면 ipmi_watchdog 이 훨씬 낫다. BMC 가 직접 도는
# 진짜 하드웨어 워치독이라 커널이 완전히 얼어붙어도 리셋이 걸린다.
if [[ -n "$WDT_MODULE" ]]; then
  CANDIDATES=("$WDT_MODULE")
elif grep -qi 'vendor_id.*AuthenticAMD' /proc/cpuinfo; then
  CANDIDATES=(sp5100_tco)
else
  CANDIDATES=(iTCO_wdt)
fi
# BMC 가 있으면 softdog 보다 먼저 시도한다.
[[ -e /dev/ipmi0 || -e /dev/ipmi/0 || -e /dev/ipmidev/0 ]] && CANDIDATES+=(ipmi_watchdog)
CANDIDATES+=(softdog)

echo "  후보 순서: ${CANDIDATES[*]}"

# --- 어느 모듈을 쓸지는 "부팅 시점"에 정한다 -------------------------------
#
# 설치 시점에 판정하면 안 된다. 이미 다른 워치독 모듈이 물려 있으면
# /dev/watchdog 이 존재한다는 사실만으로는 어느 모듈이 만든 것인지 구분할 수
# 없기 때문이다. 실제로 이 함정에 빠졌다: 이전 부팅의 softdog 이 물려 있는
# 상태에서 재실행하니, iTCO_wdt 는 모듈만 올라가고 장치를 못 만드는데도
# (BIOS 가 NO_REBOOT 플래그로 막아둠) /dev/watchdog 이 보여서 동작한다고
# 오판했다. 재부팅 후 softdog 이 없어지자 워치독이 통째로 사라졌다.
#
# 부팅 직후에는 워치독 모듈이 하나도 없으므로 판정이 명확하다.
# 후보를 순서대로 올려 보고, 장치를 실제로 만든 첫 모듈을 채택한다.
# 실패한 모듈은 즉시 내려 다음 후보를 오염시키지 않는다.
cat > /usr/local/sbin/hw-watchdog-load <<EOF
#!/bin/sh
# workstation-oom-hardening -- 부팅 시 워치독 모듈 선택
# $DOC_URL
#
# 후보를 순서대로 시도해 /dev/watchdog 을 실제로 만드는 첫 모듈을 채택한다.
# 모듈이 로드되는 것과 장치를 만드는 것은 다르다:
#   iTCO_wdt: unable to reset NO_REBOOT flag, device disabled by hardware/BIOS
# 위 경우 modprobe 는 성공하지만 워치독 장치는 생기지 않는다.
set -u
for m in ${CANDIDATES[*]}; do
    modprobe "\$m" 2>/dev/null || continue
    if [ -c /dev/watchdog ] || [ -c /dev/watchdog0 ]; then
        echo "hw-watchdog: \$m 채택"
        exit 0
    fi
    # 장치를 못 만들었으면 내려서 다음 후보 판정을 방해하지 않게 한다
    modprobe -r "\$m" 2>/dev/null || true
    echo "hw-watchdog: \$m 은 장치를 만들지 못함, 다음 후보로"
done
echo "hw-watchdog: 사용 가능한 워치독 없음" >&2
exit 0
EOF
chmod 755 /usr/local/sbin/hw-watchdog-load

# 지금 무장할 수 있는지 판단한다.
# 이미 워치독이 물려 있으면(systemd 가 잡고 있어 내릴 수도 없다) 판정이
# 불가능하므로 건드리지 않고 다음 부팅으로 미룬다.
if [[ -c /dev/watchdog || -c /dev/watchdog0 ]]; then
  CUR="$(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo unknown)"
  warn "이미 워치독이 물려 있습니다 ($CUR). 지금은 재판정하지 않습니다."
  warn "다음 부팅 때 후보 순서대로 다시 고릅니다."
else
  # 깨끗한 상태이므로 지금 판정해도 안전하다
  /usr/local/sbin/hw-watchdog-load | sed 's/^/  /'
fi

WDT_MOD="$(lsmod | grep -oE '^(iTCO_wdt|sp5100_tco|ipmi_watchdog|softdog)' | head -1)" || true
if [[ -z "$WDT_MOD" ]]; then
  warn "현재 로드된 워치독 모듈이 없습니다."
else
  echo "  현재 모듈: $WDT_MOD"
  sed 's/^/  identity: /' /sys/class/watchdog/watchdog0/identity 2>/dev/null || true
  case "$WDT_MOD" in
    softdog)
      warn "softdog 폴백입니다. 커널이 완전히 얼어붙으면 동작하지 않습니다."
      journalctl -k -b 0 --no-pager 2>/dev/null | grep -qE 'No MFD cells added|unable to reset NO_REBOOT' && {
        warn "원인: 이 보드는 칩셋 워치독이 BIOS/BMC 에 의해 막혀 있습니다."
        journalctl -k -b 0 --no-pager 2>/dev/null | grep -oE 'unable to reset NO_REBOOT.*' | head -1 | sed 's/^/      /'
      } || true
      ;;
    ipmi_watchdog)
      echo "  BMC 워치독입니다. 칩셋 워치독보다 낫습니다 (BMC 가 직접 리셋)."
      ;;
  esac
fi

# --- 부팅 시 자동 로드 -----------------------------------------------------
# 표준 경로 두 개가 모두 막혀 있다:
#
#  1) /etc/modules-load.d/ -- 배포판 커널 패키지가
#     /usr/lib/modprobe.d/blacklist_*.conf 에서 워치독 모듈을 blacklist 하고,
#     systemd-modules-load 는 deny-list 된 모듈을 거부한다.
#     ("Module 'iTCO_wdt' is deny-listed (by kmod)")
#
#  2) /etc/initramfs-tools/modules -- initramfs-tools 는 load_modules() 를
#     scripts/functions 에 정의만 해두고 init 어디에서도 호출하지 않는다.
#     conf/modules 가 생성되지만 읽히지 않는다. 모듈과 의존성이 initrd 에
#     들어갔는데도 로드되지 않는 것을 확인했다.
#
# blacklist 는 alias 자동 로드만 막고 명시적 modprobe 는 막지 않으므로,
# sysinit 단계에서 위 선택 스크립트를 돌린다. 장치가 생기면 systemd(PID 1)가
# 다음 핑 주기에 열기를 재시도해 자동으로 무장한다.
rm -f /etc/modules-load.d/hw-watchdog.conf
if grep -qE '^(iTCO_wdt|sp5100_tco|ipmi_watchdog|softdog)$' /etc/initramfs-tools/modules 2>/dev/null; then
  backup /etc/initramfs-tools/modules
  sed -i '/oom-hardening/,+1d' /etc/initramfs-tools/modules
  sed -i '/^\(iTCO_wdt\|sp5100_tco\|ipmi_watchdog\|softdog\)$/d' /etc/initramfs-tools/modules
  echo "  이전 initramfs 항목 제거 (동작하지 않는 경로)"
  update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs 실패 (무해)"
fi

cat > /etc/systemd/system/hw-watchdog-load.service <<EOF
[Unit]
Description=Select and load hardware watchdog module
Documentation=$DOC_URL
# 커널 패키지가 blacklist 해 두어 systemd-modules-load 가 거부하고,
# initramfs-tools 의 conf/modules 경로도 동작하지 않는다.
# blacklist 는 alias 자동 로드만 막으므로 명시적 modprobe 로 우회한다.
#
# 어느 모듈을 쓸지는 부팅 시점에 정한다. 모듈이 로드되는 것과 워치독 장치를
# 만드는 것은 다르므로(BIOS 가 막아둔 경우 등), 실제로 /dev/watchdog 이
# 생기는지 확인하고 안 되면 다음 후보로 넘어간다.
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/hw-watchdog-load

[Install]
WantedBy=sysinit.target
EOF
systemctl daemon-reload
systemctl enable hw-watchdog-load.service >/dev/null 2>&1
echo "  hw-watchdog-load.service 등록 (부팅 시 후보 순서대로 판정)"

mkdir -p /etc/systemd/system.conf.d
backup /etc/systemd/system.conf.d/10-watchdog.conf
cat > /etc/systemd/system.conf.d/10-watchdog.conf <<EOF
[Manager]
# systemd(PID 1)가 주기적으로 /dev/watchdog 을 핑한다.
# PID 1 이 멈추면 핑이 끊기고 워치독이 하드웨어 리셋을 건다.
RuntimeWatchdogSec=$RUNTIME_WATCHDOG
# 재부팅 절차가 이 시간 안에 끝나지 않으면 강제 리셋
RebootWatchdogSec=$REBOOT_WATCHDOG
KExecWatchdogSec=off
EOF
echo "  RuntimeWatchdogSec=$RUNTIME_WATCHDOG / RebootWatchdogSec=$REBOOT_WATCHDOG"

# ---------------------------------------------------------------------------
# 4. earlyoom
# ---------------------------------------------------------------------------
say "4/7  earlyoom"
if ! command -v earlyoom >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq earlyoom
fi
backup /etc/default/earlyoom
cat > /etc/default/earlyoom <<EOF
# workstation-oom-hardening
# $DOC_URL
#
# -m  사용 가능 메모리가 첫 값 아래면 SIGTERM, 둘째 값 아래면 SIGKILL (백분율)
# -r  메모리 리포트 주기(초). 0 이면 끔
#
# -p 는 일부러 쓰지 않는다. man earlyoom:
#   "-p: set niceness of earlyoom to -20 and oom_score_adj to -100"
# 즉 systemd 가 준 OOMScoreAdjust=-1000 을 earlyoom 이 스스로 -100 으로
# 되돌려버린다. 대신 drop-in 에서 Nice=-20 을 주므로 우선순위는 그대로
# 얻으면서 oom_score_adj=-1000 이 유지된다.
EARLYOOM_ARGS="-m $EARLYOOM_THRESHOLDS -r $EARLYOOM_REPORT_INTERVAL --avoid '$EARLYOOM_AVOID' --prefer '$EARLYOOM_PREFER'"
EOF

mkdir -p /etc/systemd/system/earlyoom.service.d
cat > /etc/systemd/system/earlyoom.service.d/10-protect.conf <<'EOF'
[Service]
MemoryMin=32M
OOMScoreAdjust=-1000
# earlyoom 의 -p 옵션 대신 여기서 우선순위를 준다.
# -p 를 쓰면 earlyoom 이 자기 oom_score_adj 를 -100 으로 되돌려버린다.
Nice=-20
ManagedOOMPreference=avoid
Restart=always
RestartSec=2
EOF

# apt 가 설치하면서 기본 설정으로 이미 기동시켜 놓기 때문에 반드시 재시작해야
# /etc/default/earlyoom 과 위 drop-in 이 실제로 반영된다.
systemctl daemon-reload
systemctl restart earlyoom.service
sleep 1
# set -e + pipefail 주의: pgrep 이 못 찾으면 파이프라인 상태가 1 이 되어
# 대입문 자체가 실패로 취급되고 스크립트가 그 자리에서 종료된다. || true 필수.
EO_PID=$(pgrep -x earlyoom | head -1) || true
MEM_TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
T1="${EARLYOOM_THRESHOLDS%%,*}"; T2="${EARLYOOM_THRESHOLDS##*,}"
printf '  -m %s (여유 %.1fGiB 에서 경고, %.1fGiB 에서 kill)\n' \
  "$EARLYOOM_THRESHOLDS" \
  "$(awk -v m=$MEM_TOTAL_MB -v p=$T1 'BEGIN{print m*p/100/1024}')" \
  "$(awk -v m=$MEM_TOTAL_MB -v p=$T2 'BEGIN{print m*p/100/1024}')"
echo "  oom_score_adj: $(cat /proc/$EO_PID/oom_score_adj 2>/dev/null)  (기대값 -1000)"
echo "  nice: $(ps -o ni= -p "$EO_PID" 2>/dev/null | tr -d ' ')  (기대값 -20)"
echo "  워크로드에 상한이 없으므로 earlyoom 이 유일한 사전 방어선입니다."

# ---------------------------------------------------------------------------
# 5. systemd-oomd 비활성화 (earlyoom 과 이중 kill 방지)
# ---------------------------------------------------------------------------
say "5/7  systemd-oomd 비활성화 (earlyoom 으로 일원화)"
systemctl disable --now systemd-oomd.service 2>/dev/null || true
systemctl mask systemd-oomd.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. 원격 접속 경로 메모리 예약
# ---------------------------------------------------------------------------
say "6/7  원격 접속 경로 메모리 예약"
TOTAL_RSV=0
for entry in "${REMOTE_UNITS[@]}"; do
  unit="${entry%%:*}"; mmin="${entry##*:}"
  # 템플릿 유닛(ssh@.service)은 list-unit-files 에 ssh@.service 로 나온다.
  if ! have_unit "$unit"; then
    printf '  %-26s (없음 - 건너뜀)\n' "$unit"; continue
  fi
  mkdir -p "/etc/systemd/system/${unit}.d"
  cat > "/etc/systemd/system/${unit}.d/10-oom-protect.conf" <<EOF
# 원격 접속 경로 보호 - 이게 죽으면 물리 접근 외에 복구 수단이 없다.
#   MemoryMin=$mmin        : 이 양만큼은 메모리 회수(reclaim) 대상에서 제외 = 진짜 예약
#   OOMScoreAdjust=-1000   : 커널 OOM killer 가 절대 선택하지 않음
#   OOMPolicy=continue     : 자식이 OOM 으로 죽어도 서비스 전체를 내리지 않음
[Service]
MemoryMin=$mmin
OOMScoreAdjust=-1000
ManagedOOMPreference=avoid
OOMPolicy=continue
EOF
  printf '  %-26s MemoryMin=%s\n' "$unit" "$mmin"
  TOTAL_RSV=$(( TOTAL_RSV + ${mmin%M} ))
done

mkdir -p /etc/systemd/system/user.slice.d
cat > /etc/systemd/system/user.slice.d/10-oom-protect.conf <<EOF
[Slice]
# SSH 로그인 세션은 user.slice 아래에 생성되므로 여기도 최소한을 예약한다.
MemoryMin=$RSV_USER_SLICE
EOF
printf '  %-26s MemoryMin=%s\n' "user.slice" "$RSV_USER_SLICE"
TOTAL_RSV=$(( TOTAL_RSV + ${RSV_USER_SLICE%M} ))
echo "  ------------------------------------------"
echo "  합계 ${TOTAL_RSV}MiB 예약"

# ---------------------------------------------------------------------------
# 7. 스왑 비활성화
# ---------------------------------------------------------------------------
say "7/7  스왑"
if (( ! DISABLE_SWAP )); then
  echo "  DISABLE_SWAP=0 - 건너뜀"
else
  SWAP_USED_MB=$(awk 'NR>1{s+=$4} END{print int(s/1024)+0}' /proc/swaps)
  AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  echo "  스왑 사용량 ${SWAP_USED_MB}MiB / 여유 메모리 ${AVAIL_MB}MiB"
  if (( SWAP_USED_MB > 0 && AVAIL_MB < SWAP_USED_MB + 4096 )); then
    warn "스왑 내용을 되돌릴 메모리 여유가 부족합니다. swapoff 를 건너뜁니다."
    warn "무거운 작업을 종료한 뒤 'sudo swapoff -a' 를 직접 실행하세요."
  else
    (( SWAP_USED_MB > 0 )) && echo "  swapoff 진행 중 (수십 초 걸릴 수 있음)..."
    swapoff -a
    echo "  swapoff 완료"
  fi

  # fstab 의 swap 항목을 주석 처리하고, 원하면 스왑 "파일"만 삭제한다.
  backup /etc/fstab
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    read -ra f <<< "$line"
    (( ${#f[@]} >= 3 )) && [[ "${f[2]}" == "swap" ]] || continue
    sed -i "s|^\(${f[0]//\//\\/}[[:space:]].*\)$|# disabled by oom-hardening: \1|" /etc/fstab
    echo "  fstab 주석 처리: ${f[0]}"
    if (( DELETE_SWAP_FILE )) && [[ -f "${f[0]}" ]] \
       && ! swapon --show --noheadings 2>/dev/null | grep -q "^${f[0]} "; then
      rm -f "${f[0]}"
      echo "  스왑 파일 삭제: ${f[0]}"
    fi
  done < /etc/fstab

  [[ -d /etc/cloud/cloud.cfg.d ]] && printf 'swap: {}\n' > /etc/cloud/cloud.cfg.d/99-no-swap.cfg
fi

# ---------------------------------------------------------------------------
say "반영"
systemctl daemon-reload
systemctl enable --now earlyoom.service
systemctl enable --now oom-sysctl-enforce.timer

# 중요: ssh.service 를 재시작하면 이 스크립트를 돌리고 있는 SSH 세션이 끊긴다.
# MemoryMin(cgroup memory.min)은 daemon-reload 만으로 실행 중인 유닛에 즉시 적용되고,
# OOMScoreAdjust 는 새로 생기는 프로세스에만 적용되므로 이미 떠 있는 데몬에는
# /proc/<pid>/oom_score_adj 에 직접 써서 재시작 없이 반영한다.
for name in "${REMOTE_PROCS[@]}"; do
  for p in $(pgrep -x "$name" 2>/dev/null); do
    echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null || true
  done
done
echo "  실행 중인 원격 데몬에 oom_score_adj=-1000 직접 적용 (재시작 없음)"
for name in "${REMOTE_PROCS[@]}"; do
  # || true 가 없으면 해당 데몬이 실행 중이 아닐 때 pgrep 실패 -> pipefail ->
  # 대입문 실패 -> set -e 로 스크립트가 여기서 종료된다.
  p=$(pgrep -x "$name" 2>/dev/null | head -1) || true
  if [[ -n $p ]]; then
    printf '    %-12s pid=%-8s oom_score_adj=%s\n' \
      "$name" "$p" "$(cat "/proc/$p/oom_score_adj")"
  else
    printf '    %-12s (실행 중 아님)\n' "$name"
  fi
done

say "완료. 백업: $BACKUP"
cat <<EOF

  검증:  sudo bash $HERE/verify.sh
  롤백:  sudo bash $HERE/uninstall.sh

  지금 적용됨:
    sysctl / earlyoom / 원격 데몬 ${TOTAL_RSV}MiB 예약 / sysctl 되돌림 방지 타이머

  재부팅해야 적용됨:
    RuntimeWatchdogSec (부팅 시점부터 워치독 무장)
    NFS soft,softerr (마운트가 사용 중이라 remount 불가한 경우)

  이 스크립트는 SSH 세션을 끊지 않습니다 (ssh.service 를 재시작하지 않음).

EOF
