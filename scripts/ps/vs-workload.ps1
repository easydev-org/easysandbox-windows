# Install the VCTools workload using the LATEST Visual Studio bootstrapper.
#
# WHY THIS IS NOT A switch PROBLEM. The pinned package winget carries is
# Microsoft.VisualStudio.2022.BuildTools 17.9.7. Its manifest declares supported OS versions
# with an upper bound of 10.0.22000, written when Windows 11 25H2 did not exist. This guest is
# 10.0.26200 - newer than that bound - and the installer treats an out-of-range build as
# unsupported, marks every component 'not applicable', does nothing, and exits 1.
#
# That is what five runs of switch guessing were actually looking at:
#   Package Microsoft.VisualStudio.Debugger.DbgHelp.Win8 is not applicable:
#     The current OS Version '10.0.26200.0' is not in the supported version range
#     '[10.0.19042,10.0.22000]'
#
# The cure is not a switch, it is a newer bootstrapper. aka.ms/vs/17/release/vs_BuildTools.exe
# is the evergreen launcher: it fetches a manifest that knows about current builds, then
# installs whatever the latest 17.x is.
$ErrorActionPreference = 'Continue'

$boot = Join-Path $env:TEMP 'vs_BuildTools.exe'
Write-Output ('OS build: ' + [System.Environment]::OSVersion.Version.ToString())

# NOTHING TO UNINSTALL. Every run starts from the ssh-latest disk pulled from ghcr, which
# carries sshd and nothing else - the packages installed here live only in this run VM and
# are thrown away with it. An earlier version of this script tried to remove a winget
# BuildTools first; there is never one to remove on a fresh disk, and if there were, the
# bootstrapper would handle it as an upgrade.


$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Write-Output 'downloading vs_BuildTools.exe (evergreen)'
try {
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $boot -UseBasicParsing -TimeoutSec 300
} catch {
    Write-Output ('DOWNLOAD_FAILED: ' + $_.Exception.Message)
    exit 1
}
if (-not (Test-Path $boot)) { Write-Output 'NO_BOOTSTRAPPER'; exit 1 }
Write-Output ('downloaded: ' + (Get-Item $boot).Length + ' bytes')

Write-Output 'running the bootstrapper with VCTools'
$args = @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended'
)
Write-Output ('args: ' + ($args -join ' '))
$p = Start-Process -FilePath $boot -ArgumentList $args -PassThru -Wait
Write-Output ('bootstrap exit: ' + $p.ExitCode)

# ASK THE PRODUCT, not the process - six exit codes have each meant something else.
if (Test-Path $vswhere) {
    $pkgs = & $vswhere -latest -products * -property packages 2>$null
    if ($pkgs -and ($pkgs -match 'Microsoft.VisualStudio.Workload.VCTools')) {
        Write-Output 'VCTOOLS_PRESENT'
    } else {
        Write-Output 'VCTOOLS_ABSENT'
    }
    $inst = & $vswhere -latest -products * -property installationVersion 2>$null
    Write-Output ('installed version: ' + $inst)
} else {
    Write-Output 'NO_VSWHERE'
}
