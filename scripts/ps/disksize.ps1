# Size of one folder, in MB. Called once per folder by stage_analyze.
#
# One folder per ssh round trip, because the sessions that measured several at once kept
# dying: a single walk of C:\Windows includes WinSxS and takes too long to survive.
#
# -List prints every immediate subdirectory with its own size, so a folder that turns out
# to be unexpectedly large can be opened up without another round of guessing.
param([string]$Path, [switch]$List)
$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path $Path)) { Write-Output 'ABSENT'; exit 0 }

if ($List) {
    foreach ($d in (Get-ChildItem $Path -Directory -Force -ErrorAction SilentlyContinue)) {
        try {
            $m = Get-ChildItem $d.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            $mb = if ($m.Sum) { [math]::Round($m.Sum/1MB,1) } else { 0 }
            Write-Output ($mb.ToString() + '|' + $d.Name)
        } catch {
            Write-Output ('-1|' + $d.Name)
        }
    }
    exit 0
}

try {
    $m = Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if (-not $m.Sum) { Write-Output '0' } else { Write-Output ([math]::Round($m.Sum/1MB,1)) }
} catch {
    Write-Output 'ERR'
}
