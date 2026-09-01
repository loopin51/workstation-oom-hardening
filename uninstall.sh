#!/usr/bin/env bash
#
# workstation-oom-hardening -- 전체 롤백
#
# 설치한 파일을 모두 제거하고 커널 파라미터를 기본값으로 되돌린다.
# NFS 옵션과 스왑 항목은 /etc/fstab 에 남긴 주석을 근거로 복원한다.
#
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "sudo bash $0" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_UNITS=(
  "ssh.service:-" "ssh@.service:-" "tailscaled.service:-"
  "rustdesk.service:-" "gdm.service:-"
)
RESTORE_SWAP=1
# shellcheck source=/dev/null
[[ -f "$HERE/config.env" ]] && source "$HERE/config.env"

echo "==> 설정 파일 제거"
rm -f /etc/sysctl.d/99-oom-reboot.conf \
      /etc/systemd/system.conf.d/10-watchdog.conf \
      /etc/modules-load.d/hw-watchdog.conf \
      /etc/modprobe.d/hw-watchdog.conf \
      /etc/default/earlyoom \
      /etc/cloud/cloud.cfg.d/99-no-swap.cfg
rm -rf /etc/systemd/system/earlyoom.service.d

echo "==> systemd 유닛 제거"
systemctl disable --now oom-sysctl-enforce.timer 2>/dev/null || true
systemctl disable --now hw-watchdog-load.service 2>/dev/null || true
rm -f /etc/systemd/system/oom-sysctl-enforce.service \
      /etc/systemd/system/oom-sysctl-enforce.timer \
      /etc/systemd/system/hw-watchdog-load.service
for u in k3s.service kubelet.service k3s-agent.service; do
  rm -f "/etc/systemd/system/${u}.d/10-restore-panic-on-oom.conf"
  rmdir "/etc/systemd/system/${u}.d" 2>/dev/null || true
done
for entry in "${REMOTE_UNITS[@]}" "user.slice:-"; do
  u="${entry%%:*}"
  rm -f "/etc/systemd/system/${u}.d/10-oom-protect.conf"
  rmdir "/etc/systemd/system/${u}.d" 2>/dev/null || true
done

echo "==> initramfs 워치독 항목 정리 (이전 버전 잔재)"
if grep -qE '^(iTCO_wdt|sp5100_tco|softdog)$' /etc/initramfs-tools/modules 2>/dev/null; then
  sed -i '/oom-hardening/,+1d' /etc/initramfs-tools/modules
  sed -i '/^\(iTCO_wdt\|sp5100_tco\|softdog\)$/d' /etc/initramfs-tools/modules
  update-initramfs -u >/dev/null 2>&1 && echo "    initramfs 재생성 완료" \
    || echo "    update-initramfs 실패 - 수동 실행 필요"
fi

echo "==> earlyoom 중지, systemd-oomd 복구"
systemctl disable --now earlyoom.service 2>/dev/null || true
systemctl unmask systemd-oomd.service 2>/dev/null || true
systemctl enable --now systemd-oomd.service 2>/dev/null || true

echo "==> 커널 파라미터 런타임 복구"
sysctl -w vm.panic_on_oom=0 kernel.hung_task_panic=0 vm.swappiness=60 >/dev/null
sysctl --system >/dev/null

echo "==> /etc/fstab 복원"
# install.sh 가 남긴 주석에서 원래 옵션을 읽어 되돌린다.
#   # changed by oom-hardening (was: <원래 옵션>)
#   <바뀐 줄>
cp -a /etc/fstab "/etc/fstab.oom-hardening-uninstall.$(date +%s)"
tmp="$(mktemp)"
prev_opts=""
while IFS= read -r line; do
  if [[ "$line" =~ ^\#\ changed\ by\ oom-hardening\ \(was:\ (.*)\)$ ]]; then
    prev_opts="${BASH_REMATCH[1]}"; continue
  fi
  if [[ -n "$prev_opts" ]]; then
    read -ra f <<< "$line"
    printf '%s %s %s %s %s %s\n' "${f[0]}" "${f[1]}" "${f[2]}" "$prev_opts" \
           "${f[4]:-0}" "${f[5]:-0}" >> "$tmp"
    echo "    NFS 옵션 복원: ${f[1]} -> $prev_opts"
    prev_opts=""; continue
  fi
  printf '%s\n' "$line" >> "$tmp"
done < /etc/fstab
cat "$tmp" > /etc/fstab; rm -f "$tmp"

if (( RESTORE_SWAP )); then
  sed -i 's|^# disabled by oom-hardening: ||' /etc/fstab
  # 스왑 파일이 삭제됐다면 fstab 에 적힌 크기를 알 수 없으므로 8GiB 로 재생성한다.
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    read -ra f <<< "$line"
    (( ${#f[@]} >= 3 )) && [[ "${f[2]}" == "swap" ]] || continue
    if [[ "${f[0]}" != /dev/* && ! -e "${f[0]}" ]]; then
      echo "    스왑 파일 재생성: ${f[0]} (8GiB)"
      fallocate -l 8G "${f[0]}" && chmod 600 "${f[0]}" && mkswap "${f[0]}" >/dev/null
    fi
  done < /etc/fstab
  swapon -a 2>/dev/null || true
  echo "    스왑 활성화"
fi

systemctl daemon-reload
echo "==> 완료. 워치독 모듈 언로드와 NFS 옵션은 재부팅 후 적용됩니다."
