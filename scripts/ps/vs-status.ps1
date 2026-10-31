# Report the detached Visual Studio install: still running, and if it finished, WHY it failed.
$ErrorActionPreference = 'Continue'

$pidFile = Join-Path $env:TEMP 'vs-install.pid'
$running = $false
if (Test-Path $pidFile) {
    $procs = Get-Process -Name 'vs_BuildTools','setup','vs_installer','vs_installershell','vs_setup' -ErrorAction SilentlyContinue
    if ($procs) { $running = $true }
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
    Write-Output 'NO_VSWHERE'
    Write-Output 'VCTOOLS_ABSENT'
}

# Free space, because the download is several GB.
$d = Get-PSDrive C -ErrorAction SilentlyContinue
if ($d) { Write-Output ('free on C: ' + [math]::Round($d.Free/1GB,1) + ' GB') }

# ONLY WHEN FINISHED: the installer's own log. A failure that ran nine minutes and installed
# nothing has a reason in here, and the answer is not going to be an exit code.
if (-not $running) {
    $logs = @()
    $logs += Get-ChildItem $env:TEMP -Filter 'dd_*.log' -ErrorAction SilentlyContinue
    $logs += Get-ChildItem (Join-Path $env:TEMP 'dd_bootstrapper*') -ErrorAction SilentlyContinue
    $latest = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Write-Output ('--- ' + $latest.Name + ' ---')
        Get-Content $latest.FullName -Tail 30 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Output ('  ' + $_) }
    } else {
        Write-Output 'no installer log in TEMP'
        Get-ChildItem $env:TEMP -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
            ForEach-Object { Write-Output ('  log: ' + $_.Name + ' ' + $_.Length) }
    }
}
