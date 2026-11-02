# Launch slim.ps1 so it survives the ssh session that starts it.
#
# Start-Process alone does not: the child is in the same job object as the ssh logon session,
# and Windows tears that whole tree down when the session ends. That is why slim.log was never
# created - slim.ps1 was killed before its first line.
#
# A scheduled task runs under the Task Scheduler service, which is not part of any logon
# session, so the work survives.
#
# STDOUT AND STDERR GO TO A FILE. The task reported rc=1 and produced no log, which means the
# failure was in the first statements or in powershell itself; that output would have said so.
$slim = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'slim.ps1'
$name = 'slim-golden'
$out  = Join-Path $env:SystemDrive 'slim.out'

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $out -Force -ErrorAction SilentlyContinue

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg  = '-NoProfile -ExecutionPolicy Bypass -File "' + $slim + '" -WindowStyle Hidden *> "' + $out + '"'
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output ('started task ' + $name + ' -> ' + $out)
