@echo off
rem Enable OpenSSH Server inside the Windows guest, during the unattended
rem installation, so the finished golden disk is reachable over ssh.
rem
rem HOW THIS RUNS. dockur copies /storage/oem into the install media's
rem $OEM$/$1/OEM/, Windows places it at C:\OEM\, and Windows executes
rem C:\OEM\install.bat from the OEM_SCRIPT block that sits in every version's
rem setup script (assets/<version>.cmd) - the line
rem   if exist "C:\OEM\install.bat" start "Install" cmd.exe /d /c ...
rem is present in the stock templates, so no fork of dockur is needed and LOG=Y
rem is not required. The /storage/oem lookup is dockur's own (install.sh,
rem getOemFolder), which also checks /oem, /OEM and /storage/OEM.
rem
rem WHY THE INSTALL PHASE. Windows has a native hook that macOS does not: a script
rem that runs inside the installer, before the first desktop. Everything written
rem here lands in the golden disk, so every future boot has ssh already available
rem - no clicks, no OCR, no first-boot daemon racing the account.
setlocal

rem dockur starts this script with its own stdout already redirected to
rem C:\OEM\install.log. Writing there as well would interleave two writers, so
rem this script keeps its own file and dockur's copy keeps the console output.
set LOG=C:\OEM\ssh-setup.log

echo [ssh] enabling OpenSSH Server

rem The client is present in most builds; the server is an optional capability
rem and is the piece that is usually missing.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >> %LOG% 2>&1

rem Without this the service exists but never starts, which looks like ssh is
rem missing rather than disabled.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name sshd -StartupType Automatic" >> %LOG% 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Service sshd" >> %LOG% 2>&1

rem Windows ships sshd_config with password authentication commented out, and a
rem correct password being refused is the usual symptom.
if not exist "%ProgramData%\ssh" mkdir "%ProgramData%\ssh"
if not exist "%ProgramData%\ssh\sshd_config" echo PasswordAuthentication yes > "%ProgramData%\ssh\sshd_config"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='C:\ProgramData\ssh\sshd_config'; $c=Get-Content $p; $c=$c -replace '^#?\s*PasswordAuthentication.*','PasswordAuthentication yes'; Set-Content -Path $p -Value $c" >> %LOG% 2>&1

rem Listen on 2222, not the default 22.
rem
rem The base layer forwards a published container port to the guest port with the
rem same number, and the host side cannot use 22 (privileged, refused for the
rem runner user). So the whole chain is 2222:  host 2222 -> container 2222 -> guest
rem 2222. Changing sshd's port here is what closes the loop.
powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Content 'C:\ProgramData\ssh\sshd_config') -replace '^#?\s*Port\s.*','Port 2222' | Set-Content 'C:\ProgramData\ssh\sshd_config'" >> %LOG% 2>&1

rem The firewall rule the capability normally adds can be missing when the
rem service starts this early, and a closed port looks exactly like a dead sshd
rem from the network side.
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 2222 | Out-Null }" >> %LOG% 2>&1

rem Report what actually happened. A capability install that quietly fails has no
rem other symptom, and this log is the only record that survives into the disk.
echo [ssh] state >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Service sshd | Select-Object Name,Status,StartType | Format-List" >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-WindowsCapability -Online -Name OpenSSH.Server* | Select-Object Name,State | Format-List" >> %LOG% 2>&1

rem Record the accounts that exist, so the disk carries its own answer to "who can
rem log in here". The bake passes USERNAME/PASSWORD to dockur, which creates the
rem account in the unattend XML before this script runs - but nothing on the disk
rem said which name it chose, and an earlier version of this pipeline shipped a
rem check that logged in as an account that had never been created.
echo [ssh] local users >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-LocalUser | Select-Object Name,Enabled | Format-Table -AutoSize" >> %LOG% 2>&1
echo [ssh] listening ports >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 2222 | Select-Object LocalAddress,LocalPort,State | Format-Table -AutoSize" >> %LOG% 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command "Test-NetConnection -ComputerName 127.0.0.1 -Port 2222 -InformationLevel Quiet" >> %LOG% 2>&1

echo [ssh] done
endlocal
exit /b 0
