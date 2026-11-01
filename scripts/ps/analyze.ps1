# Where did the space go? Read-only analysis, nothing is deleted.
#
# The qcow2 that gets published is 21.5 GiB while the guest reports 28.8 GiB used. Those
# numbers can both be true - qcow2 only stores non-zero clusters - but an image 9 GiB bigger
# than its parent is worth accounting for before calling it the toolchain.
#
# Every section prints MB, largest first, and the total is printed at the end.
$ErrorActionPreference = 'Continue'

function SizeMB($p) {
    if (-not (Test-Path $p)) { return -1 }
    $s = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $s) { return 0 }
    return [math]::Round($s/1MB,1)
}

$drive = Get-PSDrive C -ErrorAction SilentlyContinue
Write-Output ("=== disk ===")
Write-Output ("  size:  " + [math]::Round(($drive.Used + $drive.Free)/1GB,2) + " GB")
Write-Output ("  used:  " + [math]::Round($drive.Used/1GB,2) + " GB")
Write-Output ("  free:  " + [math]::Round($drive.Free/1GB,2) + " GB")

Write-Output ("=== top level of C: ===")
Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $d = $_
    [pscustomobject]@{ Name = $d.Name; MB = (SizeMB $d.FullName) }
} | Sort-Object MB -Descending | Select-Object -First 12 | ForEach-Object {
    $e = $_
    Write-Output ("  " + $e.MB.ToString().PadLeft(10) + " MB  " + $e.Name)
}

Write-Output ("=== the installed toolchain, by top-level folder ===")
$tool = @(
    "C:\Program Files (x86)\Microsoft Visual Studio",
    "C:\Program Files\Microsoft Visual Studio",
    "C:\Program Files (x86)\Windows Kits",
    "C:\Program Files\Windows Kits",
    "C:\Program Files\dotnet",
    "C:\Program Files\PowerShell"
)
foreach ($p in $tool) {
    $mb = SizeMB $p
    if ($mb -ge 0) { Write-Output ("  " + $mb.ToString().PadLeft(10) + " MB  " + $p) } else { Write-Output ("  " + "absent".PadLeft(10) + "     " + $p) }
}

Write-Output ("=== ProgramData: the VS payload cache and friends ===")
Get-ChildItem "C:\ProgramData" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $d = $_
    [pscustomobject]@{ Name = $d.Name; MB = (SizeMB $d.FullName) }
} | Sort-Object MB -Descending | Select-Object -First 10 | ForEach-Object {
    $e = $_
    Write-Output ("  " + $e.MB.ToString().PadLeft(10) + " MB  " + $e.Name)
}

Write-Output ("=== Windows: the parts that grow ===")
foreach ($p in @(
    "C:\Windows\WinSxS",
    "C:\Windows\Installer",
    "C:\Windows\SoftwareDistribution",
    "C:\Windows\Temp",
    "C:\Windows\Logs",
    "C:\Windows\System32\DriverStore"
)) {
    $mb = SizeMB $p
    if ($mb -ge 0) { Write-Output ("  " + $mb.ToString().PadLeft(10) + " MB  " + $p) }
}

Write-Output ("=== user profile ===")
Get-ChildItem $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $d = $_
    [pscustomobject]@{ Name = $d.Name; MB = (SizeMB $d.FullName) }
} | Sort-Object MB -Descending | Select-Object -First 8 | ForEach-Object {
    $e = $_
    Write-Output ("  " + $e.MB.ToString().PadLeft(10) + " MB  " + $e.Name)
}

Write-Output ("=== largest single files over 200 MB ===")
Get-ChildItem C:\ -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 200MB } |
    Sort-Object Length -Descending | Select-Object -First 20 |
    ForEach-Object { Write-Output ("  " + [math]::Round($_.Length/1MB,0).ToString().PadLeft(6) + " MB  " + $_.FullName) }

Write-Output "ANALYZE_DONE"
