# Add the VCTools workload, and decide the outcome by asking the installer.
#
# HISTORY, because this file has been wrong three times:
#   1. vs_installer.exe modify              -> 0 in 4s; it is a launcher, nothing installed
#   2. setup.exe modify --wait              -> 87, ERROR_INVALID_PARAMETER
#   3. setup.exe modify --quiet --norestart -> 1 in under a second
#
# Under a second is not an install. So rather than guess a fourth switch combination, the
# script runs the modify and then asks vswhere whether VCTools is present - the exit code is
# reported but not trusted, because every previous interpretation of it was wrong.
$ErrorActionPreference = 'Continue'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output 'NO_VSWHERE'; exit 1 }

$path = & $vswhere -latest -products * -property installationPath
if (-not $path) { Write-Output 'NO_INSTALL_PATH'; exit 1 }
Write-Output ("install path: " + $path)

$setup = Join-Path (Split-Path $vswhere) 'setup.exe'
Write-Output ("setup: " + $setup)

$args = @(
    'modify',
    '--installPath', $path,
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended',
    '--quiet', '--norestart', '--wait'
)
Write-Output ('args: ' + ($args -join ' '))
$p = Start-Process -FilePath $setup -ArgumentList $args -PassThru -Wait
Write-Output ("setup exit: " + $p.ExitCode)

# THE DECIDING QUESTION, asked of the product rather than the process.
$pkgs = & $vswhere -latest -products * -property packages 2>$null
if ($pkgs -and ($pkgs -match 'Microsoft.VisualStudio.Workload.VCTools')) {
    Write-Output 'VCTOOLS_PRESENT'
} else {
    Write-Output 'VCTOOLS_ABSENT'
}

$log = Get-ChildItem (Join-Path $env:TEMP 'dd_setup_*.log') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { Write-Output ('log: ' + $log.FullName) }
