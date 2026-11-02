# State of the slim run, with enough detail to tell the three cases apart:
#   never started   no scheduled task
#   died at once    task Ready, rc != 0, and slim.out says why
#   running         task Running, or a log with content
$log  = Join-Path $env:SystemDrive 'slim.log'
$done = Join-Path $env:SystemDrive 'slim.done'
$out  = Join-Path $env:SystemDrive 'slim.out'
$task = Get-ScheduledTask -TaskName 'slim-golden' -ErrorAction SilentlyContinue

if (Test-Path $done) {
    Write-Output 'SLIM_DONE'
    exit 0
}

if ($task) {
    $ti = Get-ScheduledTaskInfo -TaskName 'slim-golden' -ErrorAction SilentlyContinue
    Write-Output ('  task=' + $task.State + ' rc=' + $ti.LastTaskResult)
} else {
    Write-Output '  no scheduled task'
}

if (Test-Path $log) {
    Write-Output '  log: '
    Get-Content $log -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ('    ' + $_) }
} else {
    Write-Output '  no slim.log yet'
}

# slim.out holds the powershell stream. When the task returns rc=1 and the log is empty,
# this is the only place the reason appears.
if (Test-Path $out) {
    $err = Get-Content $out -Tail 6 -ErrorAction SilentlyContinue
    if ($err) {
        Write-Output '  slim.out: '
        $err | ForEach-Object { Write-Output ('    ' + $_) }
    }
}
