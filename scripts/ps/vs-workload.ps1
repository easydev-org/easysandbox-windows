# Add the VCTools workload, and report WHY if the installer refuses.
#
# Four attempts have been read from the exit code alone:
#   vs_installer modify  -> 0 in 4s (a launcher; nothing installed)
#   setup --wait         -> 87 (--wait is the launcher switch, not setup.exe)
#   setup, no --wait     -> 1 in a second
#   setup, cleaned args  -> 1 in a second
#
# Each time I guessed at the next switch combination. The installer writes a log that says
# what it objected to, and it has been sitting at a path printed in every run. So this prints
# the tail of that log instead of guessing a fifth time.
$ErrorActionPreference = 'Continue'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output 'NO_VSWHERE'; exit 1 }

$path = & $vswhere -latest -products * -property installationPath
$setup = Join-Path (Split-Path $vswhere) 'setup.exe'
Write-Output ("install path: " + $path)

$args = @(
    'modify',
    '--installPath', $path,
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended',
    '--quiet', '--norestart'
)
Write-Output ('args: ' + ($args -join ' '))
$p = Start-Process -FilePath $setup -ArgumentList $args -PassThru -Wait
Write-Output ("setup exit: " + $p.ExitCode)

$pkgs = & $vswhere -latest -products * -property packages 2>$null
if ($pkgs -and ($pkgs -match 'Microsoft.VisualStudio.Workload.VCTools')) {
    Write-Output 'VCTOOLS_PRESENT'
} else {
    Write-Output 'VCTOOLS_ABSENT'
}

# WHY. The newest installer log, and the lines that mention an error or the workload.
$log = Get-ChildItem (Join-Path $env:TEMP 'dd_setup_*.log') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) {
    Write-Output ('--- log: ' + $log.FullName + ' ---')
    Get-Content $log.FullName -ErrorAction SilentlyContinue |
        Where-Object { $_ -match 'Error|error|VCTools|invalid|Invalid|return code|Exit code' } |
        Select-Object -Last 25 |
        ForEach-Object { Write-Output ('  ' + $_) }
} else {
    Write-Output 'no dd_setup log found'
}
