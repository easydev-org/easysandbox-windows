# Launch slim-run.ps1 through Task Scheduler so it survives the ssh session.
#
# THREE FAULTS WERE FIXED HERE, each of which produced rc=1 with no output at all:
#
#   -WindowStyle after -File   powershell parses it only before -File, so it was handed to the
#                              script as an argument and the script failed to parse
#   *>  with -File             redirection is not processed in -File mode, so slim.out was
#                              never created and the failure had nowhere to appear
#   the task runs as SYSTEM    it must not depend on the ssh user profile, so everything is
#                              copied to a directory SYSTEM owns and the task sets its
#                              working directory explicitly
#
# slim-run.ps1 does the redirection in a normal powershell session, where it works.
$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = 'slim-golden'
$wrap = Join-Path $src 'slim-run.ps1'

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item ($env:SystemDrive + '\slim.out') -Force -ErrorAction SilentlyContinue

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $wrap + '"'
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output ('started ' + $name + '  wrapper=' + $wrap)
