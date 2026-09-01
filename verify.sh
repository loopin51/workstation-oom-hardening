#!/usr/bin/env bash
#
# workstation-oom-hardening -- 설치 결과 검증
#
# 유닛 파일이 아니라 "실제로 적용된 값"을 본다.
# systemctl show 가 아니라 /proc/<pid>/, /sys/fs/cgroup/, /dev/ 를 읽는 이유는
# 설정이 존재하는 것과 반영된 것이 다를 수 있기 때문이다.
#
HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_UNITS=("ssh.service:-" "tailscaled.service:-" "rustdesk.service:-" "gdm.service:-")
HUNG_TASK_TIMEOUT="120"
INOTIFY_INSTANCES="1024"
EARLYOOM_THRESHOLDS="10,5"
# shellcheck source=/dev/null
[[ -f "$HERE/config.env" ]] && source "$HERE/config.env"

ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; }
info() { printf '  \033[1;34m[i]\033[0m    %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
g()    { local v=${1:-0}; [[ -z $v || $v == infinity || $v == max || $v == 0 ]] && echo "-" || echo "$((v/1024/1024))M"; }

hdr "1. sysctl"
cs() { local v; v="$(sysctl -n "$1" 2>/dev/null)"
       [[ "$v" == "$2" ]] && ok "$1 = $v" || bad "$1 = ${v:-없음} (기대값 $2)"; }
cs vm.panic_on_oom 1
cs kernel.hung_task_panic 1
cs kernel.hung_task_timeout_secs "$HUNG_TASK_TIMEOUT"
cs kernel.panic_on_oops 1
[[ "$(sysctl -n kernel.panic 2>/dev/null)" -gt 0 ]] \
  && ok "kernel.panic = $(sysctl -n kernel.panic) (패닉 후 자동 재부팅)" \
  || bad "kernel.panic = 0 (패닉 시 재부팅되지 않고 멈춤)"
inst="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null)"
(( inst >= INOTIFY_INSTANCES )) && ok "fs.inotify.max_user_instances = $inst" \
  || bad "fs.inotify.max_user_instances = $inst ('Too many open files' 발생 가능)"

hdr "1b. kubelet 의 sysctl 되돌림 방지"
# kubelet 은 기동할 때마다 vm.panic_on_oom=0 을 강제로 쓴다.
K=0
for u in k3s.service kubelet.service k3s-agent.service; do
  [[ -f "/etc/systemd/system/${u}.d/10-restore-panic-on-oom.conf" ]] && { ok "$u ExecStartPost drop-in"; K=1; }
done
(( K )) || info "쿠버네티스 유닛 없음 (drop-in 불필요)"
if systemctl is-active --quiet oom-sysctl-enforce.timer; then
  ok "oom-sysctl-enforce.timer 동작 중"
  info "$(systemctl list-timers oom-sysctl-enforce.timer --no-pager 2>/dev/null | sed -n 2p)"
  LT="$(systemctl show oom-sysctl-enforce.service -p ExecMainStatus --value 2>/dev/null)"
  [[ "$LT" == "0" ]] && ok "마지막 실행 종료코드 0" || bad "마지막 실행 종료코드 $LT"
else
  bad "oom-sysctl-enforce.timer 미동작 - kubelet 이 되돌린 값을 복구하지 못함"
fi
info "참고: vm.overcommit_memory=$(sysctl -n vm.overcommit_memory) 는 kubelet 요구값이라 그대로 둠"

hdr "2. 하드웨어 워치독"
if [[ -e /dev/watchdog ]]; then
  ok "/dev/watchdog 존재 ($(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo unknown))"
  info "timeout=$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null)s / state=$(cat /sys/class/watchdog/watchdog0/state 2>/dev/null)"
else
  bad "/dev/watchdog 없음 - RuntimeWatchdogSec 가 동작하지 않습니다"
fi
# 커널 패키지가 blacklist 하므로 modules-load.d 도 initramfs conf/modules 도 안 된다.
# sysinit 단계의 명시적 modprobe 유닛이 유일하게 동작하는 경로다.
if systemctl is-enabled --quiet hw-watchdog-load.service 2>/dev/null; then
  ok "hw-watchdog-load.service enabled (부팅 시 모듈 로드)"
  lsmod | grep -qE '^(iTCO_wdt|sp5100_tco|softdog)' && ok "워치독 모듈 로드됨" || bad "워치독 모듈 미로드"
  lsmod | grep -q '^softdog' && info "softdog 폴백 - 커널이 완전히 얼면 동작하지 않음"
else
  bad "hw-watchdog-load.service 미등록 - 재부팅하면 /dev/watchdog 이 사라집니다"
fi
[[ -f /etc/modules-load.d/hw-watchdog.conf ]] \
  && bad "/etc/modules-load.d/hw-watchdog.conf 잔존 - deny-list 때문에 무효"
grep -qE '^(iTCO_wdt|sp5100_tco|softdog)$' /etc/initramfs-tools/modules 2>/dev/null \
  && bad "initramfs-tools/modules 잔존 - conf/modules 는 읽히지 않아 무효"
RW="$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)"
[[ -n "$RW" && "$RW" != "0" ]] && ok "RuntimeWatchdogSec = $RW" || bad "RuntimeWatchdogSec 미설정"
info "RebootWatchdogSec = $(systemctl show -p RebootWatchdogUSec --value 2>/dev/null)"
journalctl -b 0 --no-pager 2>/dev/null | grep -q 'Using hardware watchdog' \
  && info "$(journalctl -b 0 --no-pager 2>/dev/null | grep -m1 'Using hardware watchdog' | cut -d']' -f2-)"

hdr "3. earlyoom"
if systemctl is-active --quiet earlyoom; then
  # 유닛 파일이 아니라 실행 중인 프로세스의 인자를 본다.
  # apt 설치 시 기본 설정으로 먼저 뜨므로, 재시작하지 않으면 설정이 반영되지 않는다.
  EP=$(pgrep -x earlyoom | head -1)
  CMD=$(tr '\0' ' ' < "/proc/$EP/cmdline" 2>/dev/null)
  if [[ "$CMD" == *"--avoid"* && "$CMD" == *"-m $EARLYOOM_THRESHOLDS"* ]]; then
    ok "earlyoom 실행 중 (설정 반영됨)"
  else
    bad "earlyoom 이 기본 설정으로 실행 중 - 'systemctl restart earlyoom' 필요"
  fi
  info "cmdline: ${CMD:0:110}..."
  EA=$(cat "/proc/$EP/oom_score_adj" 2>/dev/null)
  EN=$(ps -o ni= -p "$EP" 2>/dev/null | tr -d ' ')
  case "$EA" in
    -1000) ok "earlyoom oom_score_adj=-1000, nice=${EN}" ;;
    -100)  bad "earlyoom oom_score_adj=-100 - EARLYOOM_ARGS 에 -p 가 남아있다"
           info "-p 는 earlyoom 이 자기 oom_score_adj 를 -100 으로 되돌리게 한다(man earlyoom)." ;;
    *)     bad "earlyoom oom_score_adj=$EA (기대값 -1000)" ;;
  esac
else
  bad "earlyoom 미실행"
fi
systemctl is-active --quiet systemd-oomd && bad "systemd-oomd 아직 실행 중 (earlyoom 과 중복)" || ok "systemd-oomd 비활성"

hdr "4. 원격 접속 경로 예약"
TOTAL=0
for entry in "${REMOTE_UNITS[@]}"; do
  u="${entry%%:*}"
  systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q . || continue
  mmin="$(systemctl show "$u" -p MemoryMin --value 2>/dev/null)"
  oadj="$(systemctl show "$u" -p OOMScoreAdjust --value 2>/dev/null)"
  if [[ -n "$mmin" && "$mmin" != "0" ]]; then
    TOTAL=$(( TOTAL + mmin/1024/1024 ))
    printf '  \033[1;32m[OK]\033[0m   %-22s MemoryMin=%-6s OOMScoreAdjust=%s\n' "$u" "$(g "$mmin")" "$oadj"
  else
    bad "$u  MemoryMin 미설정"
  fi
done
umin="$(systemctl show user.slice -p MemoryMin --value 2>/dev/null)"
if [[ -n "$umin" && "$umin" != "0" ]]; then
  TOTAL=$(( TOTAL + umin/1024/1024 )); ok "user.slice             MemoryMin=$(g "$umin")"
else
  bad "user.slice MemoryMin 미설정"
fi
[[ -f /etc/systemd/system/ssh@.service.d/10-oom-protect.conf ]] \
  && ok "ssh@.service           drop-in 존재 (socket-activated 인스턴스용)"
printf '  ------------------------------------------\n'
ok "예약 합계 ${TOTAL}MiB"
# 실행 중인 프로세스에 실제로 반영됐는지 확인 (유닛 재시작 없이 적용했으므로)
for name in "${REMOTE_PROCS[@]:-sshd tailscaled rustdesk gdm3}"; do
  p=$(pgrep -x "$name" 2>/dev/null | head -1); [[ -n $p ]] || continue
  v=$(cat "/proc/$p/oom_score_adj" 2>/dev/null)
  [[ "$v" == "-1000" ]] && ok "$name (pid $p) oom_score_adj=-1000" \
                        || bad "$name (pid $p) oom_score_adj=$v"
done

hdr "5. 스왑"
[[ -z "$(swapon --show --noheadings 2>/dev/null)" ]] && ok "스왑 비활성" \
  || bad "스왑 아직 활성: $(swapon --show --noheadings | tr '\n' ' ')"
grep -qE '^\s*[^#].*[[:space:]]swap[[:space:]]' /etc/fstab && bad "/etc/fstab 에 활성 swap 항목 잔존" || ok "/etc/fstab 정리됨"

hdr "6. 위험 요소"
if mount | grep -qE 'type nfs.*[,(]hard'; then
  bad "NFS 가 hard 로 마운트됨 - 서버 다운 시 hung_task_panic 오탐 재부팅 가능"
  mount | grep -E 'type nfs.*[,(]hard' | awk '{print "         "$3}'
  grep -q 'soft,softerr' /etc/fstab && info "/etc/fstab 은 수정됨. 재부팅하면 해소됩니다."
else
  ok "NFS hard 마운트 없음"
fi
D="$(ps -eo state,pid,comm --no-headers | awk '$1=="D"{print $2"/"$3}' | tr '\n' ' ')"
[[ -n "$D" ]] && bad "D 상태 프로세스: $D" || ok "D 상태 프로세스 없음"
info "워크로드에는 cgroup 상한이 없습니다."
info "전역 OOM 에 도달하면 설계대로 커널 패닉 -> 자동 재부팅됩니다."

hdr "7. 현재 메모리 (anon 기준, page cache 제외)"
a() { awk '/^anon /{printf "%d", $2/1048576}' "$1/memory.stat" 2>/dev/null || echo 0; }
for c in system.slice user.slice kubepods.slice; do
  [[ -d /sys/fs/cgroup/$c ]] && printf '  %-18s %6s MiB\n' "$c" "$(a /sys/fs/cgroup/$c)"
done
awk '/^(MemTotal|MemAvailable|SUnreclaim):/{printf "  %-18s %6d MiB\n",$1,$2/1024}' /proc/meminfo

hdr "8. 직전 부팅의 OOM / 패닉 이력"
# OOM 으로 재부팅됐다면 원인은 죽기 직전 부팅(-1)에 남는다.
journalctl -k -b -1 --no-pager 2>/dev/null \
  | grep -iE 'out of memory|oom-kill|kernel panic|hung_task|blocked for more than' | tail -5 \
  || info "관련 기록 없음"
echo
