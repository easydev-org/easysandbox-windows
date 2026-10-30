# Add the VCTools workload to an already-installed BuildTools.
# A file, not an inline command: the paths contain spaces and backslashes, and inline they
# have to survive ssh -> cmd.exe -> powershell, which is where the previous attempts lost
# characters.
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output 'NO_VSWHERE'; exit 1 }

$path = & $vswhere -latest -products * -property installationPath
if (-not $path) { Write-Output 'NO_INSTALL_PATH'; exit 1 }
Write-Output ("install path: " + $path)

$installer = Join-Path (Split-Path $vswhere) 'vs_installer.exe'
Write-Output ("installer: " + $installer)
if (-not (Test-Path $installer)) { Write-Output 'NO_INSTALLER'; exit 1 }

& $installer modify --installPath "$path" --quiet --wait --norestart `
    --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended
Write-Output ("modify exit: " + $LASTEXITCODE)
