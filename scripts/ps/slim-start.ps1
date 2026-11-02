# Launch slim.ps1 so it survives the ssh session that starts it.
#
# Start-Process alone does not: the child is in the same job object as the ssh logon session,
# and Windows tears the whole thing down when the session ends. That is why slim.log was never
# created - the status script kept reporting starting because slim.ps1 was killed before its
# first line ran.
#
# A scheduled task runs under the Task Scheduler service instead, which is not part of the ssh
# session. The task starts immediately, and the ssh call returns without waiting.
$slim = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'slim.ps1'
$name = 'slim-golden'

# A previous run of this task, if any, must go first or Register fails.
Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $slim + '" -WindowStyle Hidden'
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output ('started scheduled task ' + $name)
