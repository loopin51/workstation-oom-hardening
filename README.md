# workstation-oom-hardening

학습 워크로드가 메모리를 다 써서 리눅스 워크스테이션이 멈췄을 때, **물리 접근 없이 복구되게** 만드는 설정 모음입니다.

OOM이 나면 SSH도 Tailscale도 원격 데스크톱도 전부 응답하지 않게 되고, 결국 전원 버튼을 누르러 가야 합니다. 원격지에 있으면 그것도 못 합니다. 이 저장소는 그 상황을 두 방향에서 없앱니다 — 원격 접속 경로가 죽지 않게 메모리를 예약하고, 그래도 시스템이 멈추면 사람 대신 커널과 하드웨어가 재부팅하게 합니다.

```bash
git clone https://github.com/loopin51/workstation-oom-hardening
cd workstation-oom-hardening
cp config.env.example config.env && $EDITOR config.env   # 선택
sudo bash install.sh
sudo bash verify.sh
```

`install.sh`는 재실행해도 안전하고, **실행 중인 SSH 세션을 끊지 않습니다.** 되돌리려면 `sudo bash uninstall.sh`.

Ubuntu 24.04 / systemd 255에서 개발하고 검증했습니다. Debian 계열이면 대체로 그대로 동작합니다.

## 방어선

워크로드에는 cgroup 상한을 걸지 않습니다. 상한을 걸면 학습 작업의 메모리 상한을 미리 정해야 하는데, 그게 가능한 환경이면 애초에 이 문제가 잘 안 생깁니다. 대신 **원격 접속 경로만 지키고, 시스템이 멈추는 대신 재부팅되게** 만듭니다.

| # | 계층 | 동작 | 재부팅 |
|---|---|---|---|
| 1 | 메모리 예약 | 원격 접속 데몬이 `MemoryMin`만큼은 페이지를 뺏기지 않음 | 안 함 |
| 2 | `OOMScoreAdjust=-1000` | 커널 OOM killer가 그 데몬들을 절대 선택하지 않음 | 안 함 |
| 3 | earlyoom | 여유 메모리 5% 미만이면 가장 큰 학습 프로세스를 미리 kill | 안 함 |
| 4 | `vm.panic_on_oom=1` | 그래도 전역 OOM이 나면 커널 패닉 → `kernel.panic`초 뒤 재부팅 | 함 |
| 5 | `kernel.hung_task_panic=1` | 태스크가 120초 D 상태면 패닉 | 함 |
| 6 | 하드웨어 워치독 | PID 1이 60초간 핑을 못 하면 하드웨어가 강제 리셋 | 강제 |

1~3이 통하면 학습만 죽고 SSH는 살아있습니다. 통하지 않으면 4~6이 멈춘 상태 대신 재부팅을 만들어냅니다. 어느 쪽이든 사람이 갈 필요가 없습니다.

부수적으로 스왑을 끕니다. 스왑이 켜져 있으면 OOM 대신 몇 시간짜리 스왑 스래싱이 오는데, 그동안 시스템은 응답하지 않으면서 OOM killer도 발동하지 않아 워치독 말고는 빠져나올 방법이 없습니다.

## 설정

전부 `config.env`로 분리되어 있고, 이 파일은 `.gitignore`에 있어 커밋되지 않습니다. 없으면 `install.sh` 상단의 기본값이 쓰입니다. 자세한 항목은 [`config.env.example`](config.env.example)에 주석과 함께 있습니다.

가장 자주 고칠 것들입니다.

```bash
NFS_MOUNTS="/mnt/nas"        # hard → soft,softerr 로 바꿀 NFS 마운트. 비우면 건너뜀
WDT_MODULE=""                # 비우면 CPU 벤더로 자동 판별
REMOTE_UNITS=(               # 보호할 원격 접속 유닛. 없는 유닛은 자동으로 건너뜀
  "ssh.service:64M"
  "tailscaled.service:128M"
  "rustdesk.service:512M"
)
EARLYOOM_PREFER='^(python3?|torchrun|deepspeed|...)$'   # 먼저 죽일 대상
```

`MemoryMin`은 상한이 아니라 **예약**입니다. 이 양만큼은 메모리 회수 대상에서 빠지므로 시스템이 아무리 쪼들려도 해당 데몬은 페이지를 뺏기지 않습니다. 안 쓰는 만큼은 다른 프로세스가 그대로 씁니다.

## 삽질 기록

이 저장소의 실제 가치는 여기 있습니다. 문서대로 하면 될 것 같은데 안 되는 것들입니다.

### kubelet이 `vm.panic_on_oom`을 0으로 되돌린다

k3s/kubelet은 기동할 때마다 자기 요구 값을 강제로 씁니다.

```
vm.overcommit_memory=1   vm.panic_on_oom=0
kernel.panic=10          kernel.panic_on_oops=1
```

쿠버네티스는 파드 OOM으로 노드가 죽는 걸 원하지 않기 때문인데, 여기서는 정반대가 필요합니다. `/etc/sysctl.d/`에 써두는 것만으로는 유지되지 않습니다. **`kernel.panic=10`이 처음부터 설정돼 있는 것처럼 보였던 것도 kubelet이 써둔 값이었습니다.**

두 겹으로 막습니다.
- 쿠버네티스 유닛에 `ExecStartPost=/usr/sbin/sysctl -q -w vm.panic_on_oom=1` drop-in. `ExecStart`를 복제하지 않으므로 패키지를 업그레이드해도 안전합니다.
- `oom-sysctl-enforce.timer` — 1분 주기 재확인. `ExecStartPost`는 내장 kubelet이 sysctl을 쓰기 **전에** 실행될 수 있어서, 그 틈을 좁히는 용도입니다.

`vm.overcommit_memory=1`은 kubelet 요구값이라 건드리지 않았습니다. 스왑이 없는 상태에서 항상 오버커밋한다는 뜻이라 전역 OOM이 조금 더 쉽게 발생합니다.

### 워치독 모듈 자동 로드 경로가 둘 다 막혀 있다

`iTCO_wdt`(Intel)와 `sp5100_tco`(AMD)는 배포판 커널 패키지가 blacklist해 둡니다.

```
/usr/lib/modprobe.d/blacklist_linux-hwe-7.0_7.0.0-30-generic.conf:26: blacklist iTCO_wdt
```

1. **`/etc/modules-load.d/`** — `systemd-modules-load`가 deny-list된 모듈을 거부합니다. `Module 'iTCO_wdt' is deny-listed (by kmod)`.
2. **`/etc/initramfs-tools/modules`** — initramfs-tools가 `load_modules()`를 `scripts/functions`에 정의만 해두고 `init` 어디에서도 호출하지 않습니다. `conf/modules`가 생성되긴 하는데 읽히지 않습니다. 모듈 파일과 의존성 `intel_pmc_bxt`까지 initrd에 정상적으로 들어갔는데도 부팅 후 `lsmod`에 없었습니다.

blacklist는 **alias 자동 로드만** 막고 명시적 `modprobe`는 막지 않습니다. 그래서 sysinit 단계에서 직접 `modprobe`하는 유닛(`hw-watchdog-load.service`)을 씁니다. 모듈이 올라오면 systemd(PID 1)가 다음 핑 주기에 장치 열기를 재시도해 자동으로 무장합니다.

```
21:25:12  부팅
21:25:14  Finished hw-watchdog-load.service
21:25:14  Using hardware watchdog 'iTCO_wdt', version 6, device /dev/watchdog0
21:25:14  Watchdog running with a timeout of 1min.
```

### 서버 보드에서는 칩셋 워치독이 아예 안 붙는다

ASUS Z11PA-U12(Xeon Gold) 두 대에서 `iTCO_wdt`가 붙지 않았습니다. 커널 로그가 원인을 그대로 말해줍니다.

```
lpc_ich 0000:00:1f.0: I/O space for ACPI uninitialized
lpc_ich 0000:00:1f.0: No MFD cells added
```

`lpc_ich`가 MFD 셀을 만들지 못하면 `iTCO_wdt`가 바인딩할 플랫폼 장치 자체가 생기지 않습니다. BMC가 TCO 영역을 점유해서 생기는 일이라 BIOS 토글로 해결되지 않습니다. 같은 커널·같은 배포판인데도 데스크톱 보드(Core Ultra 9 285K)에서는 정상적으로 붙었습니다.

이런 보드에는 **BMC 워치독**이 있습니다. `/dev/ipmi0`이 보이면 `ipmi_watchdog`을 씁니다. BMC가 직접 도는 진짜 하드웨어 워치독이라 커널이 완전히 얼어붙어도 리셋이 걸리고, 칩셋 워치독보다 오히려 낫습니다.

**모듈이 로드되는 것과 워치독 장치가 생기는 것은 다릅니다.** 같은 보드에서 `modprobe iTCO_wdt`는 성공하지만 장치는 만들어지지 않습니다.

```
iTCO_wdt iTCO_wdt: unable to reset NO_REBOOT flag, device disabled by hardware/BIOS
```

그래서 **어느 모듈을 쓸지는 설치 시점이 아니라 부팅 시점에 정합니다.** 설치 중에 판정하면, 이전 부팅에서 올라온 다른 워치독 모듈이 이미 `/dev/watchdog`을 제공하고 있을 때 어느 모듈이 만든 것인지 구분할 수 없습니다. 실제로 이 함정에 빠져서, softdog이 물려 있는 상태에서 재실행하니 `iTCO_wdt`가 동작한다고 오판했고 재부팅 후 워치독이 통째로 사라졌습니다.

부팅 직후에는 워치독 모듈이 하나도 없으므로 판정이 명확합니다. `hw-watchdog-load.service`가 후보를 순서대로 올려 보고, 장치를 실제로 만든 첫 모듈을 채택합니다. 실패한 모듈은 즉시 내려 다음 후보 판정을 오염시키지 않습니다.

```
칩셋 워치독 (iTCO_wdt / sp5100_tco)
  → BMC 워치독 (ipmi_watchdog, /dev/ipmi0 이 있을 때)
    → softdog 폴백
```

`softdog`까지 내려가면 커널이 완전히 얼었을 때는 못 잡습니다. 그 경우 `install.sh`가 `No MFD cells added` 로그를 확인해서 원인을 함께 알려줍니다.

### `pgrep <이름>`으로 검증하면 엉뚱한 프로세스를 본다

한 서버에서 `tailscaled`의 `oom_score_adj`가 0으로 보여 보호가 안 된 줄 알았습니다. 실제로는 tailscaled가 두 개였습니다.

```
pid=1408  /home/user/tailscale/tailscaled   cgroup=/system.slice/cron.service        adj=0
pid=1933  /usr/sbin/tailscaled              cgroup=/system.slice/tailscaled.service  adj=-1000
```

`pgrep -x tailscaled | head -1`이 PID가 낮은 쪽, 즉 cron이 띄운 별개 인스턴스를 집었습니다. `verify.sh`는 유닛의 `MainPID`를 읽습니다. 우리가 보호한 그 프로세스를 정확히 가리키는 유일한 방법입니다.

### `set -e` + `pipefail`에서 `pgrep` 대입이 스크립트를 죽인다

```bash
p=$(pgrep -x "$name" | head -1)    # 프로세스가 없으면 여기서 스크립트 종료
```

`pgrep`이 못 찾으면 종료코드 1, `pipefail` 때문에 파이프라인 전체가 1, 그러면 대입문 자체가 실패로 취급되어 `set -e`가 스크립트를 끝냅니다. `[[ ]] && cmd`나 `(( )) && cmd`는 `&&` 리스트의 마지막이 아니므로 안전한데, 이건 아닙니다. `|| true`가 필요합니다.

### earlyoom의 `-p`가 자기 `oom_score_adj`를 되돌린다

`man earlyoom`: *"-p: set niceness of earlyoom to -20 and **oom_score_adj to -100**"*.

systemd가 `OOMScoreAdjust=-1000`을 줘도 earlyoom이 기동 직후 스스로 -100으로 올립니다. `-p`를 빼고 drop-in에서 `Nice=-20`을 주면 우선순위는 그대로 얻으면서 -1000이 유지됩니다.

그리고 **apt가 설치하면서 earlyoom을 기본 설정으로 먼저 기동시킵니다.** `/etc/default/earlyoom`을 쓴 뒤 반드시 `systemctl restart earlyoom`을 해야 반영됩니다. `verify.sh`가 유닛 파일이 아니라 `/proc/<pid>/cmdline`을 읽는 이유입니다.

### NFS `hard` 마운트 + `hung_task_panic=1` = 오탐 재부팅

`hard` 마운트는 서버가 응답하지 않으면 접근 프로세스를 D 상태로 무한 대기시킵니다. `hung_task_panic=1`과 만나면 **NAS가 2분만 끊겨도 워크스테이션이 재부팅됩니다.** `install.sh`가 `NFS_MOUNTS`에 적힌 마운트를 `soft,softerr,timeo=100,retrans=3`으로 바꿉니다. 대신 서버 무응답 시 진행 중이던 I/O가 `EIO`로 실패할 수 있습니다.

마운트가 사용 중이면 `remount`로는 안 바뀌고 다음 재부팅에 적용됩니다.

### `ssh.service`를 재시작하면 자기 세션이 끊긴다

drop-in을 쓰고 `systemctl restart ssh`를 하면 스크립트를 돌리고 있던 SSH 세션이 그 자리에서 죽습니다. `install.sh`는 재시작하지 않습니다.

- `MemoryMin`(cgroup `memory.min`)은 `daemon-reload`만으로 실행 중인 유닛에 즉시 적용됩니다.
- `OOMScoreAdjust`는 새로 생기는 프로세스에만 적용되므로, 이미 떠 있는 데몬에는 `/proc/<pid>/oom_score_adj`에 직접 씁니다.

### `vm.panic_on_oom`은 1이어야 한다. 2가 아니다

- `1` — **전역** OOM에만 패닉. cgroup 상한 초과로 죽는 것(컨테이너가 자기 `limits`를 넘는 정상 상황)은 그냥 넘어갑니다.
- `2` — cgroup OOM에도 패닉. 파드 하나 죽으면 될 일에 노드 전체가 재부팅됩니다.

## 구성 요소

설치되는 파일입니다. 전부 `uninstall.sh`가 되돌립니다.

| 경로 | 역할 |
|---|---|
| `/etc/sysctl.d/99-oom-reboot.conf` | 패닉/재부팅 정책, inotify 한계 |
| `/etc/systemd/system.conf.d/10-watchdog.conf` | `RuntimeWatchdogSec` / `RebootWatchdogSec` |
| `/etc/systemd/system/hw-watchdog-load.service` | 워치독 모듈 명시적 로드 |
| `/etc/systemd/system/oom-sysctl-enforce.{service,timer}` | kubelet 되돌림 방어 |
| `/etc/systemd/system/<k8s>.d/10-restore-panic-on-oom.conf` | 기동 직후 재적용 |
| `/etc/systemd/system/<remote>.d/10-oom-protect.conf` | `MemoryMin` + `OOMScoreAdjust` |
| `/etc/systemd/system/user.slice.d/10-oom-protect.conf` | SSH 로그인 세션 예약 |
| `/etc/default/earlyoom` + `earlyoom.service.d/10-protect.conf` | earlyoom 설정 |
| `/etc/modprobe.d/hw-watchdog.conf` | 워치독 모듈 옵션 |

`install.sh`는 건드리는 모든 파일을 `/root/oom-hardening-backup-<timestamp>/`에 먼저 백업합니다.

## 사후 분석

OOM으로 재부팅됐다면 원인은 **죽기 직전 부팅**에 남습니다.

```bash
journalctl -k -b -1 | grep -iE 'oom-kill|Out of memory|kernel panic|hung_task'
journalctl -u earlyoom -b -1
```

`oom-kill:` 줄의 `constraint=`가 원인을 알려줍니다.

- `CONSTRAINT_NONE` + `global_oom` → 전역 OOM. 재부팅됐을 것입니다.
- `CONSTRAINT_MEMCG` → 개별 cgroup 상한 초과. 재부팅되지 않습니다.

하드웨어 워치독이 강제 리셋을 걸면 마지막 몇 초의 로그가 디스크에 안 써지고 날아갈 수 있습니다. `kernel.panic` 경로로 재부팅된 경우는 패닉 메시지가 남습니다.

## 주의

- **의도적으로 재부팅을 유발하는 설정입니다.** 전역 OOM이나 120초 hung task에서 시스템이 재부팅됩니다. 진행 중인 작업은 사라집니다. 멈춘 채 방치되는 것보다 낫다는 판단이 전제입니다.
- `install.sh`는 시작 전에 D 상태 프로세스가 있는지 확인하고, 있으면 물어봅니다. `hung_task_panic=1`을 적용하는 순간 재부팅될 수 있기 때문입니다.
- 하드웨어 워치독이 안 잡히면 BIOS에서 `Watch Dog Timer` / `WDT`를 Enabled로 바꿔보세요. 그 전까지는 `softdog` 폴백인데, 커널이 완전히 얼어붙은 경우에는 동작하지 않습니다.

## 라이선스

MIT
