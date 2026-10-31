# Report whether the detached Visual Studio install is still running, and whether VCTools
# ended up present. One short ssh round trip; the install itself is not tied to this session.
$ErrorActionPreference = 'Continue'

$pidFile = Join-Path $env:TEMP 'vs-install.pid'
$running = $false
if (Test-Path $pidFile) {
    $procId = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($procId) {
        # The bootstrapper hands off to setup.exe, so check every installer process, not one pid.
        $procs = Get-Process -Name 'vs_BuildTools','setup','vs_installer','vs_installershell' -ErrorAction SilentlyContinue
        if ($procs) { $running = $true }
    }
}
if ($running) { Write-Output 'INSTALL_RUNNING' } else { Write-Output 'INSTALL_NOT_RUNNING' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $pkgs = & $vswhere -latest -products * -property packages 2>$null
    if ($pkgs -and ($pkgs -match 'Microsoft.VisualStudio.Workload.VCTools')) {
        Write-Output 'VCTOOLS_PRESENT'
    } else {
        Write-Output 'VCTOOLS_ABSENT'
    }
    $inst = & $vswhere -latest -products * -property installationVersion 2>$null
    if ($inst) { Write-Output ('version: ' + $inst) }
} else {
    Write-Output 'VCTOOLS_ABSENT'
}
