# agent-worker Windows image

The agent-worker Windows 11 sandbox: a self-owned runtime (the generic
`qemux/qemu` Debian base + the vendored boot scripts in `vendor/`) wrapped
around a pre-baked guest disk that already contains the worker, its launcher and
the scheduled task. No upstream sandbox image is referenced.

## Layout

- `Containerfile` — self-owned runtime: `FROM <registry>/qemu:750`, the vendored
  boot scripts, the pre-baked disk + boot support files, the boot-fetched worker
  binary, and the token bridge.
- `build.sh` — build + push (buildkitd → skopeo → the registry). Variants:
  `base` (plain) and `devtools` (MSVC + Windows SDK + .NET).
- `repack-disk.sh` — shrink the disk layer (defrag + long-window zstd).
- `vendor/` — the boot scripts + unattended assets copied in (not upstream).
- `guest/` — the files baked *into the guest disk* (not part of the image build):
  - `worker-launch.cmd` — fetches `WORKER_TOKEN`/`SANDBOX_PROXY` from `host.lan:8090/env`,
    boot-fetches the worker from `host.lan:8090/worker` (falling back to the
    disk copy), starts `agent-worker.exe` as the current user.
  - `ewelevate.cmd` — run a command as `NT AUTHORITY\SYSTEM` (escape hatch).
  - `agent-worker-task.xml` — the `AgentWorker` task definition (Docker user,
    HIGHEST, interactive, at logon). The hostname/user inside must match the
    guest; `install-worker.cmd` registers an equivalent task without XML.
  - `install-worker.cmd` — (re)install the worker in a running guest.

## Guest worker model

The worker runs as the **`Docker`** user in the interactive session, not as
SYSTEM. UAC is disabled in these images and `Docker` is an Administrator, so the
worker and every job it spawns already hold a full **High-IL** admin token.
`ewelevate.cmd` is there for the rare case that needs SYSTEM itself.

## Variants

| tag | contents |
|---|---|
| `base`     | clean Windows 11 + worker + computer-use (xa11y) |
| `devtools` | + Visual Studio Build Tools (MSVC) + Windows SDK + .NET SDK |

Both tags carry computer-use: `xa11y.exe` is **baked into the golden disk** at
`C:\Users\Docker\bin\xa11y.exe` (a STATIC tool); the launcher only puts it on
PATH. (The worker binary, by contrast, IS boot-fetched — see below.)

### Rebaking `devtools`

The devtools disk is a `base` disk plus a one-shot MSVC install, run inside the
guest (the guest has internet + admin). Recipe:

```cmd
curl.exe -sL -o %USERPROFILE%\vs_BuildTools.exe https://aka.ms/vs/17/release/vs_BuildTools.exe
%USERPROFILE%\vs_BuildTools.exe --quiet --wait --norestart --nocache ^
  --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100 ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.22621 ^
  --add Microsoft.VisualStudio.Component.Windows81SDK
powershell -File dotnet-install.ps1 -Channel 10.0 -InstallDir "C:\Program Files\dotnet"
```

It produces VS Build Tools 2022 (17.14.x), MSVC 14.44.x, Windows SDK
10.0.22621 + 10.0.26100 (+ Kits 8.1) and .NET SDK 10.0.x. xa11y is baked into
the disk as on `base`, so `devtools` also has computer-use.

See `REBAKE.md` for the full end-to-end recipe (winget installs, the WinINet
proxy trap, PATH repair, export, reboot-verify) and the static-vs-dynamic
launcher contract.

The disk also carries **git** (installed at bake time via winget):
the Flutter SDK checks out through git, and most dev jobs need it. It is
best-effort — a bake without internet simply skips it.

### Repairing a devtools disk: `offline-rebake.sh`

On the **shipped** `devtools` disk three gaps were found (verified in a live
sandbox), all fixed by an **offline** rebake (no guest boot, no KVM, no
hostPath-persisted disk — it edits the qcow2 directly with libguestfs +
hivexregedit):

1. **git was absent.** `oem-install.bat` *tries* `winget install Git.Git`, but
   during OEM setup winget's context is limited, so it silently skipped — the
   disk has no `git`. The rebake drops a **PortableGit** tree into
   `C:\Program Files\Git` and adds `C:\Program Files\Git\cmd` to the machine
   `Path`.
2. **the machine `Path` had been CLOBBERED.** An older `worker-launch.cmd`
   rewrote the machine `Path` with `reg add ... /d "%PATH%;%XDIR%"`; since
   `%PATH%` at that point is only the session value, it **dropped the
   dotnet / MSVC / Windows SDK entries**. Jobs then could not see `dotnet` (or
   `cl`) without `cmd /c`. The rebake rewrites the machine `Path`
   (`...dotnet;...Git\cmd;...`); `worker-launch.cmd` no longer clobbers it.
3. **`vcvars` was not in the machine env.** The rebake writes the VS
   `INCLUDE`/`LIB`/`LIBPATH` into the machine environment, so a plain job shell
   finds `cl` — no per-job `call vcvars64.bat`.

```sh
# on a Linux box (libguestfs-tools + hivexregedit + p7zip):
./agent-toolchain/vm/windows/offline-rebake.sh in.qcow2 out.qcow2
# then publish out.qcow2 to golden-windows/11/data-devtools.qcow2
```

(The previously-shipped `golden-windows/11/data-devtools.qcow2` was rebaked
this way and re-published.)

Two gotchas found the hard way while rebaking (both handled by the script):

- **Registry transaction logs.** Editing only `SYSTEM` in the hive is not
  enough: Windows **replays `SYSTEM.LOG1`/`LOG2` at boot** and reverts the edit
  (the machine `Path` silently reverted until the logs were deleted). The
  rebake removes them.
- **Stale embedded disk / image cache.** If the image still embeds an old disk
  (or the node cache serves an older image because the tag did not change), a
  runtime `golden-disk.sh` that "skips when a disk exists" keeps the stale one.
  `golden-disk.sh` now replaces any disk that is **not backed by the golden
  base**; and a full rollout must rebuild the image **and** let the node
  re-pull it (a same-tag re-push may be served from the kubelet cache).

## Building

```sh
# stage (git-ignored): agent-toolchain/vm/windows/<variant>/data.qcow2
#                      agent-toolchain/vm/windows/<variant>/disk-support/
scripts/build-all.sh                        # dist/agent-worker-windows-amd64.exe
./agent-toolchain/vm/windows/build.sh base
./agent-toolchain/vm/windows/build.sh devtools

# optional: shrink the disk layer
qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M,lazy_refcounts=on \
  base/data.qcow2 base/defrag.qcow2
./agent-toolchain/vm/windows/repack-disk.sh base/defrag.qcow2 base base
```

The guest disk is rebuilt by booting the previous image's disk (hostPath-backed
so changes persist), running `guest/install-worker.cmd` inside it, then
committing and defragmenting it.

## computer-use (xa11y)

The **xa11y** Windows CLI is baked into the golden disk at
`C:\Users\Docker\bin\xa11y.exe` (STATIC) and put on PATH by the launcher, so a
job can read/drive native apps through UI Automation (`xa11y apps` / `tree` /
`find` / `action` / `screenshot`). The worker binary IS boot-fetched from nginx
`:8090 /worker` (DYNAMIC), so a worker change needs only an image change — but
an xa11y change requires a disk rebake.

The golden disk can be extracted straight from the published image (no
node-local copy needed): `skopeo copy docker://…/sandbox-windows:base dir:…`,
then `zstd -d | tar -x` the largest layer to get `storage/data.qcow2`, and the
small `disk-support` layers for `storage/windows.*`. To rebake, boot that disk
as a hostPath `/storage` (a KVM pod on the image's node), let the launcher run,
verify `xa11y apps`, `shutdown /s`, defrag (`qemu-img convert -o
cluster_size=1M`), then build a fresh image and push it as `base`.
