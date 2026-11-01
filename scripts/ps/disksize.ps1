# Size of one folder, in MB. Called once per folder by stage_analyze.
#
# One folder per ssh round trip, because the sessions that measured several at once kept
# dying: a single walk of C:\\Windows includes WinSxS and takes too long to survive.
param([string]$Path)
$ErrorActionPreference = 'SilentlyContinue'
if (-not (Test-Path $Path)) { Write-Output 'ABSENT'; exit 0 }
try {
    $m = Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if (-not $m.Sum) { Write-Output '0' } else { Write-Output ([math]::Round($m.Sum/1MB,1)) }
} catch {
    Write-Output 'ERR'
}
