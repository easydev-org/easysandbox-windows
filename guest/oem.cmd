@echo off
rem =====================================================================
rem Windows guest OEM launch logic (served by nginx :8090 /oem.cmd).
rem
rem This is the ONLY place the launch logic lives. It is served by the
rem container's nginx (host.lan:8090/oem.cmd) and pulled by the tiny,
rem never-changing on-disk loader (C:\Users\Docker\bootstrap.vbs, the only file
rem on the golden disk). So any change here is an IMAGE change — no golden-disk
rem rebake ever needed.
rem
rem Started by the `Bootstrap` scheduled task (runs as `Docker`, interactive,
rem High-IL: UAC is off, so jobs need no elevation).
rem
rem Responsibilities:
rem   1. fetch the pod env (WORKER_TOKEN + SANDBOX_PROXY) from host.lan:8090/env
rem   2. fetch the current easyworker.exe  (host.lan:8090/worker)
rem   3. fetch + start the easystream daemon (host.lan:8090/easystream)
rem   4. run easyworker.exe, supervised
rem =====================================================================
setlocal enabledelayedexpansion

set "WROOT=C:\Users\Docker"
set "BIN=%WROOT%\easyworker.exe"
set "DL=%WROOT%\easyworker.dl.exe"
set "WS=%WROOT%\workspace"
set "LOG=%WS%\easyworker.log"

if not exist "%WS%" mkdir "%WS%"

rem --- 1. pod env: WORKER_TOKEN (pre-auth) + SANDBOX_PROXY (HTTP proxy) -----
set "PODENV=%TEMP%\aw-env.txt"
set /a N=0
:try
curl.exe -s -m 2 -o "%PODENV%" http://host.lan:8090/env 2>nul
for %%A in ("%PODENV%") do set "PODSZ=%%~zA"
if defined PODSZ if !PODSZ! GTR 0 goto have
set /a N+=1
if !N! lss 10 (ping -n 2 127.0.0.1 >nul & goto try)
:have
set "WORKER_TOKEN="
set "EAZYSTREAM_CONTROL_TOKEN="
set "EAZYSTREAM_VIEW_TOKEN="
for /f "usebackq tokens=1,* delims==" %%a in ("%PODENV%") do (
  if /i "%%a"=="WORKER_TOKEN" set "WORKER_TOKEN=%%b"
  if /i "%%a"=="SANDBOX_PROXY" set "SANDBOX_PROXY=%%b"
  if /i "%%a"=="EAZYSTREAM_CONTROL_TOKEN" set "EAZYSTREAM_CONTROL_TOKEN=%%b"
  if /i "%%a"=="EAZYSTREAM_VIEW_TOKEN" set "EAZYSTREAM_VIEW_TOKEN=%%b"
)
rem The daemon must be LOCKED: control needs the token (default to the worker's
rem own token), view stays open. Without this it would run unauthenticated and
rem any process that reached :48079/:48078 could drive the guest.
if not defined EAZYSTREAM_CONTROL_TOKEN set "EAZYSTREAM_CONTROL_TOKEN=%WORKER_TOKEN%"
if defined SANDBOX_PROXY (
  set "HTTP_PROXY=!SANDBOX_PROXY!"
  set "HTTPS_PROXY=!SANDBOX_PROXY!"
  set "http_proxy=!SANDBOX_PROXY!"
  set "https_proxy=!SANDBOX_PROXY!"
  set "NO_PROXY=localhost,127.0.0.1,.svc,.svc.cluster.local,host.lan,artifact.worker.svc.cluster.local"
  set "no_proxy=!NO_PROXY!"
  rem winget reads the WinINET (IE) proxy, NOT WinHTTP, so set BOTH.
  set "BYPASS=<local>;*.svc;*.svc.cluster.local;host.lan;*.nip.io;localhost;127.0.0.1"
  netsh winhttp set proxy proxy-server="!SANDBOX_PROXY!" bypass-list="!BYPASS!" >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "!SANDBOX_PROXY!" /f >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "!BYPASS!" /f >nul 2>&1
)

rem --- 2. firewall: STATIC (disabled at bake time on the golden disk) -------

rem --- 3. boot-fetch the worker binary (dynamic ONLY, no disk fallback) -----
>>"%LOG%" echo [%DATE% %TIME%] bootstrap: fetching worker from host.lan:8090/worker
del "%DL%" >nul 2>&1
curl.exe -s -m 60 -o "%DL%" http://host.lan:8090/worker 2>>"%LOG%"
for %%A in ("%DL%") do set "DLSZ=%%~zA"
if defined DLSZ if !DLSZ! GTR 1000000 (
  move /y "%DL%" "%BIN%" >nul 2>&1 || set "BIN=%DL%"
) else (
  del "%DL%" >nul 2>&1
  echo [%DATE% %TIME%] bootstrap: worker fetch FAILED (no fallback) >>"%LOG%"
  rem Do NOT skip the rest: the easystream daemon must still be started, and
  rem the disk copy of the worker is used below. (Jumping to :run here meant a
  rem bootstrap that ran before the container's nginx was up never started the
  rem daemon at all.)
  ping -n 3 127.0.0.1 >nul
)

rem --- 3c. easystream (est://) daemon: boot-fetch + start DETACHED ---------
rem The Go worker talks to easystream over est:// on 127.0.0.1:48079; the
rem daemon owns capture/encode/input/UIA. Start it before the worker.
set "NABIN=%WROOT%\easystream.exe"
set "NADL=%WROOT%\easystream.dl.exe"
>>"%LOG%" echo [%DATE% %TIME%] bootstrap: fetching easystream from host.lan:8090/easystream
del "%NADL%" >nul 2>&1
curl.exe -s -m 60 -o "%NADL%" http://host.lan:8090/easystream 2>>"%LOG%"
for %%A in ("%NADL%") do set "NASZ=%%~zA"
if defined NASZ if !NASZ! GTR 10000 (
  move /y "%NADL%" "%NABIN%" >nul 2>&1
  rem Start the daemon DETACHED in this (interactive) session.
  rem
  rem We used to register a Scheduled Task for this, but oem.cmd runs as the
  rem plain interactive token, so `schtasks /create /rl HIGHEST` failed with
  rem "Access is denied" and the daemon never started. A plain `start /b`
  rem launches it in the session that bootstrap.vbs already owns (High-IL,
  rem outside any worker job object) and it survives — verified: the daemon
  rem serves :48078/:48079 for the life of the VM.
  rem
  rem `start /b` = no new console window (nothing flashes on the desktop);
  rem the VBS wrapper we used before is no longer needed.
  start "" /b "%NABIN%" serve > "%WS%\easystream.log" 2>&1
  powershell -NoProfile -Command "Start-Sleep -Seconds 3" >>"%LOG%" 2>&1
) else (
  del "%NADL%" >nul 2>&1
  echo [%DATE% %TIME%] bootstrap: easystream fetch FAILED >>"%LOG%"
)

rem --- 4. run the worker in this (docker) session, supervised ---------------
rem On-demand toolchains: the guest's QEMU user-net DNS resolves the cluster
rem names (it inherits the container's resolv.conf), so the worker downloads
rem toolchains straight from the registry — no nginx proxy hop is involved.
set "WORKER_TOOLCHAIN_INDEX=http://artifact.worker.svc.cluster.local/artifacts/generic/toolchains/index/index.json"
set /a RESTARTS=0
:run
>>"%LOG%" echo [%DATE% %TIME%] bootstrap: starting worker as %USERNAME% (%BIN%)
"%BIN%" -addr 0.0.0.0:48080 -workspace "%WS%" -db "%WS%\jobs.db" >>"%LOG%" 2>&1
set "RC=!ERRORLEVEL!"
set /a RESTARTS+=1
>>"%LOG%" echo [%DATE% %TIME%] bootstrap: worker exited rc=!RC! (restart #!RESTARTS!)
set /a WAIT=3
if !RESTARTS! GTR 5 set /a WAIT=10
if !RESTARTS! GTR 20 set /a WAIT=30
ping -n !WAIT! 127.0.0.1 >nul
goto run

endlocal
