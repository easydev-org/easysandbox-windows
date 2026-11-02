# Current state of the slim run: the last few log lines, or the completion marker.
$log = Join-Path $env:SystemDrive 'slim.log'
$done = Join-Path $env:SystemDrive 'slim.done'
if (Test-Path $done) {
    'SLIM_DONE'
} elseif (Test-Path $log) {
    Get-Content $log -Tail 1
} else {
    'starting'
}
