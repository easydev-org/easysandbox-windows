#!/usr/bin/env bash
# Offline rebake of a Windows golden disk: install Git + repair the machine
# Path + import the VS (vcvars) environment — WITHOUT booting the guest.
#
# Why: an older `worker-launch.cmd` clobbered the machine Path
# (`reg add ... /d "%PATH%;%XDIR%"`), dropping the dotnet / MSVC / Windows SDK
# entries, so jobs could not see `dotnet`/`cl` without `cmd /c`; and the OEM
# bake's `winget install Git.Git` silently skipped, so the disk had no git.
#
# This edits the qcow2 directly (libguestfs + hivexregedit), which needs no
# KVM/guest boot and no hostPath-persisted disk. Run on a Linux box with
# `libguestfs-tools` + `hivexregedit` (+ `p7zip` for the PortableGit archive).
#
#   ./offline-rebake.sh in.qcow2 out.qcow2
#
# Then publish out.qcow2 SAFELY (a raw `curl -T` truncates the artifact if the
# upload is interrupted — use the checked wrapper):
#   bash ../publish-golden.sh out.qcow2 http://artifact.../golden-windows/11/data-devtools.qcow2
set -euo pipefail
IN="${1:?usage: offline-rebake.sh in.qcow2 out.qcow2}"
OUT="${2:?usage: offline-rebake.sh in.qcow2 out.qcow2}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
export LIBGUESTFS_BACKEND=direct

PORTABLEGIT_URL="${PORTABLEGIT_URL:-https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/PortableGit-2.55.0.5-64-bit.7z.exe}"
PROXY="${PROXY:-}"

# 1. PortableGit (self-contained; no installer).
echo "== fetching PortableGit =="
if [ -n "${PROXY}" ]; then
  curl -sSL -x "${PROXY}" -o "${WORK}/pg.7z" "${PORTABLEGIT_URL}"
else
  curl -sSL -o "${WORK}/pg.7z" "${PORTABLEGIT_URL}"
fi
mkdir -p "${WORK}/git"
7z x -y -o"${WORK}/git" "${WORK}/pg.7z" >/dev/null || 7za x -y -o"${WORK}/git" "${WORK}/pg.7z" >/dev/null

# 2. Pull the SYSTEM hive out of the NTFS (partition 3 on the shipped disks).
echo "== extracting SYSTEM hive =="
guestfish -a "${IN}" <<GF
run
mount-ro /dev/sda3 /
download /Windows/System32/config/SYSTEM ${WORK}/SYSTEM
GF

# 3. Build the corrected environment and merge it in. Versions are the ones on
#    the devtools disk (adjust if the MSVC/SDK versions change).
VC='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207'
SDK='C:\Program Files (x86)\Windows Kits\10'
# The MSVC + Windows SDK `bin` dirs are REQUIRED so `cl`/`link` resolve from a
# plain shell (the vcvars env alone provides INCLUDE/LIB, not the compiler on
# PATH). Verified e2e: `cl` then runs with no per-job `call vcvars64.bat`.
NEWPATH='C:\WINDOWS\system32;C:\WINDOWS;C:\WINDOWS\System32\Wbem;C:\WINDOWS\System32\WindowsPowerShell\v1.0\;C:\WINDOWS\System32\OpenSSH\;C:\Program Files\dotnet\;C:\Program Files\Git\cmd;'"$VC"'\bin\Hostx64\x64;'"$SDK"'\bin\10.0.26100.0\x64;C:\Users\Docker\AppData\Local\Microsoft\WindowsApps;C:\Users\Docker\bin'
INCLUDE="${VC}\\include;${SDK}\\Include\\10.0.26100.0\\ucrt;${SDK}\\Include\\10.0.26100.0\\shared;${SDK}\\Include\\10.0.26100.0\\um;${SDK}\\Include\\10.0.26100.0\\winrt"
LIB="${VC}\\lib\\x64;${SDK}\\Lib\\10.0.26100.0\\ucrt\\x64;${SDK}\\Lib\\10.0.26100.0\\um\\x64"
LIBPATH="${VC}\\lib\\x64"
mk() { local h; h=$(printf '%s' "$2" | iconv -f UTF-8 -t UTF-16LE | xxd -p | tr -d '\n'); printf '"%s"=hex(2):%s0000\n' "$1" "$h"; }
{
  echo 'Windows Registry Editor Version 5.00'; echo
  echo '[\ControlSet001\Control\Session Manager\Environment]'
  mk Path "${NEWPATH}"; mk INCLUDE "${INCLUDE}"; mk LIB "${LIB}"; mk LIBPATH "${LIBPATH}"
} > "${WORK}/env.reg"
hivexregedit --merge "${WORK}/SYSTEM" "${WORK}/env.reg"

# 4. Write Git + the hive back into the disk.
echo "== writing Git + hive into the disk =="
guestfish -a "${IN}" <<GF
run
mount /dev/sda3 /
mkdir-p "/Program Files/Git"
copy-in ${WORK}/git/. "/Program Files/Git"
upload ${WORK}/SYSTEM /Windows/System32/config/SYSTEM
# CRITICAL: drop the SYSTEM hive's transaction logs. Windows replays
# SYSTEM.LOG1/LOG2 at boot and would REVERT the hive we just edited (a real
# gotcha: the machine Path silently reverted until these were removed).
rm-f /Windows/System32/config/SYSTEM.LOG1
rm-f /Windows/System32/config/SYSTEM.LOG2
sync
GF

# 5. Recompress to the published (internal zstd qcow2) form.
echo "== recompressing -> ${OUT} =="
qemu-img convert -c -O qcow2 -o compression_type=zstd "${IN}" "${OUT}"
echo "done: ${OUT}"
