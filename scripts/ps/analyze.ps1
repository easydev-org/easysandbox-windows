# Where did the space go? Read-only.
#
# Two lessons from the first attempts:
#   walking all of C:\ with Get-ChildItem -Recurse killed the ssh session - WinSxS alone
#     holds tens of thousands of files
#   measuring each top-level folder with the same call still recursed C:\Windows
#
# So sizes come from System.IO.Directory, which enumerates far faster than Get-ChildItem,
# and every stage prints as it goes so a partial result is still useful.
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Core -ErrorAction SilentlyContinue

function SizeMB($p) {
    if (-not (Test-Path $p)) { return -1 }
    try {
        $sum = [System.IO.Directory]::EnumerateFiles($p, "*", [System.IO.SearchOption]::AllDirectories) |
                ForEach-Object { try { (New-Object System.IO.FileInfo $_).Length } catch { 0 } } |
                Measure-Object -Sum
        if (-not $sum.Sum) { return 0 }
        return [math]::Round($sum.Sum/1MB,1)
    } catch {
        return -2
    }
}

$drive = Get-PSDrive C -ErrorAction SilentlyContinue
Write-Output ("=== disk (GB) ===")
Write-Output ("  size " + [math]::Round(($drive.Used + $drive.Free)/1GB,2) + "  used " + [math]::Round($drive.Used/1GB,2) + "  free " + [math]::Round($drive.Free/1GB,2))

Write-Output ("=== top level of C: (MB) ===")
foreach ($d in (Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue)) {
    $mb = SizeMB $d.FullName
    Write-Output ("  " + $mb.ToString().PadLeft(9) + " MB  " + $d.Name)
}

Write-Output ("=== toolchain ===")
foreach ($p in @(
    "C:\Program Files\Microsoft Visual Studio",
    "C:\Program Files (x86)\Microsoft Visual Studio",
    "C:\Program Files (x86)\Windows Kits",
    "C:\Program Files\Windows Kits",
    "C:\Program Files\dotnet"
)) {
    $mb = SizeMB $p
    if ($mb -ge 0) { Write-Output ("  " + $mb.ToString().PadLeft(9) + " MB  " + $p) }
}

Write-Output ("=== ProgramData ===")
foreach ($d in (Get-ChildItem "C:\ProgramData" -Directory -Force -ErrorAction SilentlyContinue)) {
    $mb = SizeMB $d.FullName
    Write-Output ("  " + $mb.ToString().PadLeft(9) + " MB  " + $d.Name)
}

Write-Output ("=== Windows ===")
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
foreach ($d in (Get-ChildItem $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue)) {
    $mb = SizeMB $d.FullName
    Write-Output ("  " + $mb.ToString().PadLeft(9) + " MB  " + $d.Name)
}

Write-Output "ANALYZE_DONE"
