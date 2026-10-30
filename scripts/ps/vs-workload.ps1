# Add the VCTools workload to an already-installed BuildTools, and wait for it.
#
# WHY setup.exe AND NOT vs_installer.exe: vs_installer.exe is a launcher. It hands the work
# to setup.exe and exits 0 within a second or two, so its exit code says nothing about
# whether anything was installed - which the verification then reported as NO_VCTOOLS.
#
# WHY --wait IS NOT PASSED: it belongs to that launcher. setup.exe is synchronous and
# rejects it with exit 87 (ERROR_INVALID_PARAMETER). The manifest lists it as Custom for the
# launcher, which is where the earlier attempts picked it up.
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output 'NO_VSWHERE'; exit 1 }

$path = & $vswhere -latest -products * -property installationPath
if (-not $path) { Write-Output 'NO_INSTALL_PATH'; exit 1 }
Write-Output ("install path: " + $path)

$setup = Join-Path (Split-Path $vswhere) 'setup.exe'
if (-not (Test-Path $setup)) { Write-Output 'NO_SETUP_EXE'; exit 1 }

Write-Output 'starting setup.exe modify (this takes several minutes)'
$args = @(
    'modify',
    '--installPath', $path,
    '--quiet', '--norestart',
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended'
)
$p = Start-Process -FilePath $setup -ArgumentList $args -Wait -PassThru
Write-Output ("setup exit: " + $p.ExitCode)

# 3010 = reboot required; the components are installed.
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    Write-Output ('MODIFY_FAILED: ' + $p.ExitCode)
    exit 1
}
Write-Output 'MODIFY_OK'
