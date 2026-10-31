$ErrorActionPreference = "Continue"

$t = $env:TEMP
Write-Output ("TEMP = " + $t)

Write-Output "--- dd_vs_BuildTools_decompression_log.txt ---"
$d = Join-Path $t "dd_vs_BuildTools_decompression_log.txt"
if (Test-Path $d) {
    Get-Content $d -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("  " + $_) }
} else { Write-Output "  absent" }

Write-Output "--- extracted dirs ---"
Get-ChildItem $t -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^[0-9a-f]{20,}" } | ForEach-Object {
    Write-Output ("  dir: " + $_.FullName)
    Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { Write-Output ("    " + $_.Length + "  " + $_.Name) }
}

Write-Output "--- all dd_* logs, read ---"
Get-ChildItem $t -Filter "dd_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
    Write-Output ("  === " + $_.Name + " (" + $_.Length + " bytes) ===")
    Get-Content $_.FullName -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("    " + $_) }
}

Write-Output "--- VS directories ---"
$paths = @("${env:ProgramFiles(x86)}\Microsoft Visual Studio", "${env:ProgramFiles}\Microsoft Visual Studio")
foreach ($p in $paths) { if (Test-Path $p) { Write-Output ("  EXISTS " + $p) } else { Write-Output ("  absent " + $p) } }
