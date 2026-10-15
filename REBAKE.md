# Re-baking the Windows `devtools` golden disk (end-to-end)

How to (re)produce the Windows golden disk that the `sandbox-windows:devtools*`
image boots. This is the *runtime* recipe (boot a VM, install tools, export the
disk), used because the original `devtools` disk was not archived. It also
documents the traps that silently destroy your work.

## TL;DR

```
1. pvc-create golden-windows 128Gi
2. service-deploy winbake  (sandbox-windows:devtools-nodisk, kvm, 16Gi,
                            volumes: golden-windows -> /storage,
                            env GOLDEN_DISK_URL=<base golden url>)
3. wait for boot; get the worker token
4. bake inside the guest (VS BuildTools + .NET + git + OpenSSH, via winget)
5. fix the machine PATH (envfix) + register the hidden AgentWorker task
6. clean caches, graceful `shutdown /s`
7. export: flatten the overlay -> upload to artifact as the new golden
8. reboot a fresh VM and VERIFY the tools survive
```

## 0. The traps (read first)

### Static vs dynamic — the launcher contract

Anything that changes **per boot** MUST be (re)applied by the launcher on every
boot from the pod env; anything **fixed** lives in the golden disk (static) and
the launcher must NOT re-fetch it.

| Thing | Route | Where |
|---|---|---|
| `WORKER_TOKEN`, `SANDBOX_PROXY` | **dynamic** | fetched from `host.lan:8090/env` every boot (they change per sandbox) |
| proxy (WinHTTP + WinINet / macOS system proxy) | **dynamic** | set from `SANDBOX_PROXY` every boot (value changes per deployment) |
| **`agent-worker` binary** | **dynamic, NO disk fallback** | boot-fetched from `host.lan:8090/worker` every boot; a worker upgrade is an image change, never a rebake. If the fetch fails the worker does not start (retry, no fallback). |
| **`xa11y`** | **static** | baked into the golden disk (`C:\Users\Docker\bin\xa11y.exe` / `/usr/local/bin/xa11y`); the launcher only ensures it is on PATH |
| firewall off (Windows) | **static** | baked registry state (`EnableFirewall=0`, all profiles) — the launcher does NOT re-apply |
| TCC grants (macOS) | **static** | baked into the disk's TCC.db by `guest/bake-hardening.sh`; keyed by the STABLE paths, so they persist across boots and worker upgrades |
| machine PATH (dotnet/MSVC/SDK/Git/OpenSSH) | **static** | baked (`envfix.ps1`); the launcher must never rewrite it |
| displayplacer | **removed** | never re-add a hard dependency (it 404s) |

Rule of thumb: **per-sandbox values → dynamic (from `/env`); anything that is
machine state on the disk → static (bake it, do not re-apply).**

These are the failure modes that make "install then reboot -> everything is
gone". They are ALL real and were hit while producing this disk.

| Trap | Symptom | Fix |
|---|---|---|
| **Another pod mounting the same PVC deletes the disk** | disk vanishes *only at shutdown* | Keep **exactly one** pod mounting the PVC. A leftover probe/service whose command is `rm -f .../data.qcow2` (or that re-runs `golden-disk.sh`) will delete/replace the disk the instant the VM releases its file handle. **Delete every other pod on that PVC.** |
| **No PVC mounted** | `/storage` is emptyDir; changes lost on pod restart | Always mount the PVC at `/storage`. |
| **`golden-disk.sh` overlay replaced** | overlay is recreated (fresh base) | The overlay is reused only when its backing == the cached base. **Never change the artifact golden while baking** — a size change makes `golden-disk.sh` refetch the base and rebuild the overlay (losing the guest's writes). Bake against a FROZEN golden URL. |
| **Interrupting the base download** | no base, no overlay | Do NOT delete the pod mid-download. Let `[golden-disk] downloaded N bytes` + `creating overlay` finish. |
| **machine PATH clobbered** | `where cl/dotnet/git` empty after reboot | The launcher must APPEND to the machine Path (PowerShell), never `reg add ... /d "%PATH%;%X"` (that clobbers it). `envfix.ps1` repairs it; run it as the last bake step. |
| **winget hangs on GitHub** | `Downloading ...` never finishes | winget reads the **WinINet (IE)** proxy, NOT `netsh winhttp`. Set BOTH (see §3). |

## 1. Prerequisites

- KVM available (`kvm: true`).
- A PVC for the disk: `pvc-create golden-windows 128Gi` (class `workspace-local`).
- The **base** golden published at
  `http://artifact.worker.svc.cluster.local/artifacts/generic/golden-windows/11/data-devtools.qcow2`.
  (If you have no golden at all, bake from `sandbox-windows:base` first — it
  ships the plain Windows install; `devtools` = base + VS/.NET/git/OpenSSH.)

## 2. Boot the bake VM (single pod on the PVC)

Deploy the disk-less image with the PVC and the golden URL:

```
image:   artifact.worker.svc.cluster.local/sandbox/sandbox-windows:devtools-nodisk
kvm:     true
cpu:     4
memory:  16Gi
volumes: [{ pvc: golden-windows, mount-path: /storage }]
env:
  GOLDEN_DISK_URL: http://artifact.worker.svc.cluster.local/artifacts/generic/golden-windows/11/data-devtools.qcow2
  SANDBOX_PROXY:   http://mihomo.develop.svc.cluster.local:7890
  WORKER_TOKEN:    <any pre-auth token>
services: [ {tcp80 -> 48080 worker}, {name: vnc, tcp80 -> 6080} ]
```

`golden-disk.sh` downloads the base once to `/storage/.cache/base-<key>.qcow2`
and creates the per-VM overlay `/storage/data.qcow2` (backing = base). The
**overlay is the disk you will export**.

Wait for: `[golden-disk] downloaded N bytes`, `creating overlay`, and
`Windows started successfully`.

## 3. Guest networking / proxy (REQUIRED for any download)

The guest has no direct internet; it reaches the cluster proxy `mihomo`. Set
BOTH proxies (winget uses WinINet; .NET/Invoke-WebRequest use WinHTTP):

```
netsh winhttp set proxy proxy-server="http://mihomo.develop.svc.cluster.local:7890" ^
  bypass-list="<local>;*.svc;*.svc.cluster.local;host.lan;*.nip.io;localhost;127.0.0.1"
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "http://mihomo.develop.svc.cluster.local:7890" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "<local>;*.svc;*.svc.cluster.local;host.lan;*.nip.io;localhost;127.0.0.1" /f
set HTTP_PROXY=http://mihomo.develop.svc.cluster.local:7890
set HTTPS_PROXY=http://mihomo.develop.svc.cluster.local:7890
```

The launcher (`guest/worker-launch.cmd`) now does this automatically from
`SANDBOX_PROXY` on every boot, so a baked disk is already correct — but during a
manual bake you must set it before installing anything.

## 4. Bake the tools (inside the guest)

Use the worker (`POST /worker.v1.WorkerService/Execute` with the token from
`/env`, or `WORKER_TOKEN`). Install via **winget** (no
manual curl of installers):

```
:: Visual Studio Build Tools + Windows SDK (MSVC)
curl.exe -sL -o %USERPROFILE%\vs_BuildTools.exe https://aka.ms/vs/17/release/vs_BuildTools.exe
%USERPROFILE%\vs_BuildTools.exe --quiet --wait --norestart --nocache ^
  --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100 ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.22621

:: .NET SDK
winget install --id Microsoft.DotNet.SDK.10 -e --source winget ^
  --accept-package-agreements --accept-source-agreements --silent --disable-interactivity

:: Git for Windows
winget install --id Git.Git -e --source winget ^
  --accept-package-agreements --accept-source-agreements --silent --disable-interactivity

:: OpenSSH SERVER  (winget id is Microsoft.OpenSSH.Preview — NOT OpenSSH.Beta)
winget install --id Microsoft.OpenSSH.Preview -e --source winget ^
  --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
:: The MSI registers + starts sshd automatically; verify:
sc query sshd
```

Notes:
- The winget source must be up to date: `winget source update`.
- `Microsoft.OpenSSH.Beta` is NOT in the winget source; the live id is
  `Microsoft.OpenSSH.Preview` (installs `C:\Program Files\OpenSSH\sshd.exe` and
  registers the `sshd` service).

## 5. Embed xa11y + fix the environment + hide the console

```
:: xa11y computer-use CLI is embedded at C:\Users\Docker\bin\xa11y.exe
:: (copy the darwin/win binary from the image /opt/agent-worker/xa11y.exe)

:: repair machine PATH (dotnet/Git/MSVC/SDK/OpenSSH) + import vcvars INCLUDE/LIB
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Docker\envfix.ps1

:: run the worker with NO visible console window, still in the Docker session:
schtasks /create /tn AgentWorker /tr "wscript C:\Users\Docker\worker-launch.vbs" ^
  /sc onlogon /ru Docker /rp admin /rl HIGHEST /it /f
```

`envfix.ps1` must APPEND to the machine Path (never overwrite it) and set
`INCLUDE`/`LIB`/`LIBPATH` from `vcvars64.bat`, so a plain job shell resolves
`cl`/`dotnet`/`git` with no per-job `call vcvars64.bat`.

## 6. Clean + graceful shutdown

```
del /q /s /f "%TEMP%\*"  &  del /q /s /f "C:\Windows\Temp\*"
del /q /s /f "C:\Windows\Prefetch\*"
rd /s /q "C:\ProgramData\Package Cache"
rd /s /q "C:\ProgramData\Microsoft\VisualStudio\Packages"
rd /s /q "C:\Users\Docker\ws\*"  &  rd /s /q "C:\Users\Docker\workspace\*"
del /q "C:\Users\Docker\*.cmd" "C:\Users\Docker\*.ps1" "C:\Users\Docker\*.b64"
shutdown /s /t 0          :: graceful — flushes NTFS; never kill the pod
```

## 7. Export the disk

With the VM **stopped** (pod deleted so the file handle is released):

```
# flatten the overlay into a standalone qcow2 (no backing file)
qemu-img convert -c -O qcow2 -o compression_type=zstd /storage/data.qcow2 /storage/win-golden.qcow2
# then publish it (streaming; use the checked wrapper, a raw curl -T truncates on failure)
```

Because the disk lives on the node-local PVC, export it from a pod **on the
same node** (or from the bake pod's own sidecar) — otherwise you read an empty
`/storage`.

## 8. Verify (mandatory)

Start a fresh VM against the new golden URL and confirm, after a **reboot**:

```
where cl          -> C:\...\MSVC\...\bin\Hostx64\x64\cl.exe
where dotnet      -> C:\Program Files\dotnet\dotnet.exe
where git         -> C:\Program Files\Git\cmd\git.exe
sc query sshd     -> RUNNING
C:\Users\Docker\bin\xa11y.exe present
```

Only after the reboot-verify passes is the golden usable.

---

# Re-baking the macOS `xcode` golden disk

Same shape as Windows, with macOS-specific differences.

## Differences from Windows

| Topic | Windows | macOS |
|---|---|---|
| Disk path | `/storage/data.qcow2` | `/storage/15/data.qcow2` |
| Boot support files | `/storage/windows.*` | `/storage/15/{boot.img,boot.sig,macos.id,macos.mac,macos.mlb,macos.rom,macos.sn,macos.vars}` |
| Filesystem | NTFS (readable by libguestfs) | **APFS** — libguestfs CANNOT read/write it; edit only from inside the running guest (SSH) |
| Golden URL | `.../golden-windows/11/data-devtools.qcow2` | `.../golden-macos/15/data-xcode.qcow2` |
| guest user | `Docker` / `admin` | `docker` / `admin` |
| Service port | worker 48080, vnc 6080 | worker 48080, vnc 6080, ssh 22 |
| SSH server | OpenSSH (winget `Microsoft.OpenSSH.Preview`) | Remote Login already on; `sshd` runs as-is |

## PVC seed (REQUIRED)

Mounting the PVC at `/storage` hides the image's `/storage/15/macos.*` support
files. **Seed them into the PVC first** (mount the PVC somewhere else, e.g.
`/mnt`, and copy the image's `/storage/15/*` into `/mnt/15/`), exactly like the
Windows `windows.*` seed.

## Bake (via SSH into the guest)

SSH in as `docker` (port 22 in-guest; the k8s Service `...-ssh` maps to it):

```
sshpass -p admin ssh -p <svc-port> docker@<macbake-ssh-host>
```

Then, on the guest (docker has passwordless sudo):

```
# 1. new launcher (from the repo) + real xa11y at /usr/local/bin/xa11y
#    (the disk ships a bad/0-byte xa11y and an OLD launcher that fetches /token)
# 2. bake the launchd units + sudoers + autologin:
sudo bash /tmp/bake-guest.sh        # guest/bake-guest.sh, BAKE_GUEST_OK
# 3. clean caches, then graceful reboot:
sudo shutdown -r now
```

## macOS-specific traps

| Trap | Symptom | Fix |
|---|---|---|
| **displayplacer 404** | worker NEVER starts; agent `last exit code = 127` | The artifact path for `displayplacer-darwin-amd64` 404s, so the launcher fetched a 33-byte JSON error body; `displayplacer list` then aborted the script under `set -e`+`pipefail`. **displayplacer was removed from the launcher** — do not reintroduce a hard failure there. |
| **old launcher fetches `/token`** | worker `unauthenticated` (401) | The disk's launcher must fetch `http://host.lan:8090/env` (the container exposes `/env`, NOT `/token`). Refresh `worker-launch.sh` from the repo before baking. |
| **`ws` owned by root** | worker `attempt to write a readonly database` | The launcher must `chown -R docker:staff ~/ws` (it does, in the daemon path). Don't create `ws/jobs.db` as root manually. |
| **missing launchd units** | `launchctl` has no `com.agentworker.worker` | Run `guest/bake-guest.sh` (creates the LaunchDaemon + LaunchAgent + sudoers + autologin). |
| **xa11y is a 0-byte/bogus file** | computer-use fails | Embed the real Mach-O at `/usr/local/bin/xa11y` (do NOT leave a symlink to a missing `~/xa11y`). |

## Verify

```
launchctl list | grep agentworker      # com.agentworker.worker present
lsof -iTCP:48080 -sTCP:LISTEN          # worker listening
curl -s http://127.0.0.1:48080/healthz # ok
```
