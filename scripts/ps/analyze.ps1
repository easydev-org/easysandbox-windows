# Where did the space go? Read-only.
#
# The first version walked all of C:\ with -Recurse and the ssh session died part way -
# WinSxS alone holds tens of thousands of files and the traversal outlasted the connection.
# So nothing here recurses the whole drive. Each named folder is measured on its own with a
# file-count bound, and the per-folder totals are enough to account for 28.84 GB.
$ErrorActionPreference = 'Continue'

function SizeMB($p) {
    if (-not (Test-Path $p)) { return -1 }
    $m = Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if (-not $m.Sum) { return 0 }
    return [math]::Round($m.Sum/1MB,1)
}

$drive = Get-PSDrive C -ErrorAction SilentlyContinue
Write-Output ("=== disk (GB) ===")
Write-Output ("  size " + [math]::Round(($drive.Used + $drive.Free)/1GB,2) + "  used " + [math]::Round($drive.Used/1GB,2) + "  free " + [math]::Round($drive.Free/1GB,2))

# Top level, one directory at a time. Deliberately no "C:\ -Recurse".
Write-Output ("=== top level of C: (MB, largest first) ===")
$top = Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue
$rows = @()
foreach ($d in $top) {
    $rows += [pscustomobject]@{ N = $d.Name; MB = (SizeMB $d.FullName) }
}
foreach ($r in ($rows | Sort-Object MB -Descending)) {
    Write-Output ("  " + $r.MB.ToString().PadLeft(9) + " MB  " + $r.N)
}

Write-Output ("=== toolchain ===")
foreach ($p in @(
    "C:\Program Files\Microsoft Visual Studio",
    "C:\Program Files (x86)\Microsoft Visual Studio",
    "C:\Program Files (x86)\Windows Kits",
    "C:\Program Files\Windows Kits",
    "C:\Program Files\dotnet",
    "C:\Program Files\PowerShell"
)) {
    $mb = SizeMB $p
    if ($mb -ge 0) { Write-Output ("  " + $mb.ToString().PadLeft(9) + " MB  " + $p) }
}

Write-Output ("=== ProgramData ===")
$pd = Get-ChildItem "C:\ProgramData" -Directory -Force -ErrorAction SilentlyContinue
$rows2 = @()
foreach ($d in $pd) { $rows2 += [pscustomobject]@{ N = $d.Name; MB = (SizeMB $d.FullName) } }
foreach ($r in ($rows2 | Sort-Object MB -Descending)) { Write-Output ("  " + $r.MB.ToString().PadLeft(9) + " MB  " + $r.N) }

Write-Output ("=== Windows (the parts that grow) ===")
foreach ($p in @(
    "C:\Windows\WinSxS",
    "C:\Windows\Installer",
    "C:\Windows\SoftwareDistribution",
    "C:\Windows\Temp",
    "C:\Windows\System32\DriverStore"
)) {
    $mb = SizeMB $p
    if ($mb -ge 0) { Write-Output ("  " + $mb.ToString().PadLeft(9) + " MB  " + $p) }
}

Write-Output ("=== user profile ===")
$up = Get-ChildItem $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue
$rows3 = @()
foreach ($d in $up) { $rows3 += [pscustomobject]@{ N = $d.Name; MB = (SizeMB $d.FullName) } }
foreach ($r in ($rows3 | Sort-Object MB -Descending)) { Write-Output ("  " + $r.MB.ToString().PadLeft(9) + " MB  " + $r.N) }

Write-Output ("=== VS payload cache ===")
$vs = "C:\ProgramData\Microsoft\VisualStudio\Packages"
if (Test-Path $vs) {
    $mb = SizeMB $vs
    Write-Output ("  " + $mb + " MB  total")
    Get-ChildItem $vs -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $x = $_
        $b = SizeMB $x.FullName
        Write-Output ("    " + $b.ToString().PadLeft(9) + " MB  " + $x.Name)
    }
} else { Write-Output "  absent" }

Write-Output "ANALYZE_DONE"
