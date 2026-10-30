# Add the VCTools workload to an already-installed BuildTools, and WAIT for it.
#
# vs_installer.exe modify returns 0 within a second or two: it hands the work to setup.exe
# and exits. The first version of this script took that exit code as success and the
# verification then found NO_VCTOOLS, because the install had only just started.
# So the launcher is started, and then the real installer process is waited on.
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output 'NO_VSWHERE'; exit 1 }

$path = & $vswhere -latest -products * -property installationPath
if (-not $path) { Write-Output 'NO_INSTALL_PATH'; exit 1 }
Write-Output ("install path: " + $path)

$installerDir = Split-Path $vswhere
$setup = Join-Path $installerDir 'setup.exe'
if (-not (Test-Path $setup)) { Write-Output 'NO_SETUP_EXE'; exit 1 }

# setup.exe with modify, run as a process we can wait on. -Wait blocks until the whole
# install finishes, and the exit code is the installer's own.
Write-Output 'starting setup.exe modify (this takes several minutes)'
$args = @(
    'modify',
    '--installPath', $path,
    '--quiet', '--wait', '--norestart',
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
