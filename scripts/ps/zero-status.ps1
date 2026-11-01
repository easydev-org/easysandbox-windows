# One line about the zero fill: in progress, or the final written= record.
$done = Join-Path $env:SystemDrive 'zero.done'
$fill = Join-Path $env:SystemDrive 'zero.fill'
if (Test-Path $done) {
    Get-Content $done
} elseif (Test-Path $fill) {
    'filling ' + [math]::Round((Get-Item $fill).Length/1GB,2) + ' GB'
} else {
    'starting'
}
