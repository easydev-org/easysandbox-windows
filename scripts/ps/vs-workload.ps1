# Add the VCTools workload to BuildTools.
#
# WHAT THE INSTALLER SAID, finally read from its own log rather than guessed from exit codes:
#   ManifestVerifier Result: Success
#   Download of 'https://download.visualstudio.microsoft.com/...'
#   Status changed to NoUpdate
#   setup exit: 1
#
# NoUpdate means the installer decided there was nothing to do. 'modify --add' against an
# installation that already exists reports the workload as unchanged rather than missing, so
# nothing is downloaded and the exit is a failure. The supported way to put a workload on a
# BuildTools install is to run 'install' with --installPath and the workload - the installer
# treats it as the same product and adds the missing components.
$ErrorActionPreference = 'Continue'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output 'NO_VSWHERE'; exit 1 }

$path = & $vswhere -latest -products * -property installationPath
if (-not $path) { Write-Output 'NO_INSTALL_PATH'; exit 1 }
Write-Output ("install path: " + $path)

$setup = Join-Path (Split-Path $vswhere) 'setup.exe'

Write-Output '--- setup.exe install --installPath ... --add VCTools ---'
$args = @(
    'install',
    '--installPath', $path,
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended',
    '--quiet', '--norestart', '--wait'
)
$p = Start-Process -FilePath $setup -ArgumentList $args -PassThru -Wait
Write-Output ("setup exit: " + $p.ExitCode)

# THE DECIDING QUESTION, asked of the product rather than the process - four exit codes have
# each meant something other than what they appeared to.
$pkgs = & $vswhere -latest -products * -property packages 2>$null
if ($pkgs -and ($pkgs -match 'Microsoft.VisualStudio.Workload.VCTools')) {
    Write-Output 'VCTOOLS_PRESENT'
} else {
    Write-Output 'VCTOOLS_ABSENT'
}

$log = Get-ChildItem (Join-Path $env:TEMP 'dd_setup_*.log') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) {
    Write-Output ('--- ' + $log.Name + ' (last 12) ---')
    Get-Content $log.FullName -Tail 12 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Output ('  ' + $_) }
}
