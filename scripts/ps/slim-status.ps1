# State of the slim run, including whether the scheduled task exists at all.
#
# starting for twenty minutes was indistinguishable from never started, and it was the
# latter: the Start-Process child was killed with the ssh session. Reporting the task state
# and its last result makes that visible next time.
$log  = Join-Path $env:SystemDrive 'slim.log'
$done = Join-Path $env:SystemDrive 'slim.done'
$task = Get-ScheduledTask -TaskName 'slim-golden' -ErrorAction SilentlyContinue
$note = ''
if ($task) {
    $ti = Get-ScheduledTaskInfo -TaskName 'slim-golden' -ErrorAction SilentlyContinue
    $note = '  [task=' + $task.State + ' rc=' + $ti.LastTaskResult + ']'
} else {
    $note = '  [no scheduled task]'
}
if (Test-Path $done) {
    Write-Output ('SLIM_DONE' + $note)
} elseif (Test-Path $log) {
    $last = Get-Content $log -Tail 1 -ErrorAction SilentlyContinue
    Write-Output (($last) + $note)
} else {
    Write-Output ('starting (no log yet)' + $note)
}
