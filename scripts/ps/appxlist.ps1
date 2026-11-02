# Every appx package installed or provisioned on this image, biggest first.
#
# Read-only. Two things this needs to show: what is actually present, and how much each one
# costs - the package folder under WindowsApps is the size that matters, not the display name.
# Provisioned packages matter too: removing an installed appx alone leaves the provisioned
# copy behind, and it comes back for every new user profile.
$ErrorActionPreference = 'SilentlyContinue'

$wa = Join-Path $env:ProgramFiles 'WindowsApps'

function FolderMB($name) {
    if (-not $name) { return 0 }
    $p = Join-Path $wa $name
    if (-not (Test-Path $p)) { return 0 }
    $s = (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if (-not $s) { return 0 }
    return [math]::Round($s/1MB,1)
}

Write-Output '=== WindowsApps total ==='
if (Test-Path $wa) {
    $t = (Get-ChildItem $wa -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    Write-Output ('  ' + [math]::Round($t/1MB,1) + ' MB')
} else {
    Write-Output '  absent'
}

Write-Output '=== installed packages, with folder size ==='
$rows = @()
foreach ($p in (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
    $mb = FolderMB $p.InstallLocation
    $rows += [pscustomobject]@{ MB = $mb; N = $p.Name; V = $p.Version }
}
foreach ($r in ($rows | Sort-Object MB -Descending)) {
    Write-Output ('  ' + $r.MB.ToString().PadLeft(9) + ' MB  ' + $r.N + '  ' + $r.V)
}

Write-Output '=== provisioned packages ==='
foreach ($p in (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
    Write-Output ('  ' + $p.DisplayName)
}

Write-Output 'APPXLIST_DONE'
