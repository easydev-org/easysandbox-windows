$ErrorActionPreference = "Continue"

$t = $env:TEMP

Write-Output "--- extracted dir contents ---"
Get-ChildItem $t -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^[0-9a-f]{20,}" } | ForEach-Object {
    Write-Output ("dir: " + $_.FullName)
    Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Output ("  " + $_.Length + "  " + $_.Name)
    }
}

Write-Output "--- does vs_setup exist in the extracted dir ---"
$setup = Get-ChildItem $t -Recurse -Filter "vs_setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 3
if ($setup) { $setup | ForEach-Object { Write-Output ("  " + $_.FullName + "  " + $_.Length) } } else { Write-Output "  no vs_setup.exe found" }

Write-Output "--- dd_setup logs (the installer itself) ---"
Get-ChildItem $t -Filter "dd_setup*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
    Write-Output ("  === " + $_.Name + " (" + $_.Length + ")")
    Get-Content $_.FullName -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("    " + $_) }
}

Write-Output "--- anything matching error in dd_bootstrapper ---"
Get-ChildItem $t -Filter "dd_bootstrapper*" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output ("  === " + $_.Name + " (")
    Get-Content $_.FullName -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("    " + $_) }
}
