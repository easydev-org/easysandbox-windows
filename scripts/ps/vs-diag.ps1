# Find out what the bootstrapper actually did.
#
# Previous run: INSTALL_RUNNING for nine minutes, free space 37.6 GB, then nothing installed
# and 'no installer log in TEMP'. A bootstrapper that runs nine minutes and leaves no log has
# either failed before it could log, or logged somewhere this script is not looking.
#
# So: look everywhere. %TEMP%, %LOCALAPPDATA%\Temp, the VS installer directory, ProgramData.
# Print what is there with sizes, and the exit state of anything left behind.
$ErrorActionPreference = 'Continue'

Write-Output ('OS build: ' + [System.Environment]::OSVersion.Version.ToString())
$d = Get-PSDrive C -ErrorAction SilentlyContinue
if ($d) { Write-Output ('free on C: ' + [math]::Round($d.Free/1GB,1) + ' GB') }

$dirs = @(
    $env:TEMP,
    (Join-Path $env:LOCALAPPDATA 'Temp'),
    (Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages'),
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { Write-Output ('MISSING ' + $dir); continue }
    Write-Output ('--- ' + $dir + ' ---')
    Get-ChildItem $dir -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 12 |
        ForEach-Object {
            $kind = if ($_.PSIsContainer) { '<dir>' } else { [string]$_.Length }
            Write-Output ('  ' + $_.LastWriteTime.ToString('MM-dd HH:mm') + '  ' + $kind + '  ' + $_.Name)
        }
}

# Is any installer process still alive, or did something crash?
Write-Output '--- processes ---'
Get-Process -Name 'vs_BuildTools','vs_setup','setup','vs_installer','vs_installershell','vs_installershell' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output ('  ' + $_.Name + ' pid=' + $_.Id) }

# The bootstrapper's own log lives here when it gets that far.
$bl = Join-Path $env:TEMP 'dd_bootstrapper_*.log'
$b = Get-ChildItem $bl -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($b) {
    Write-Output ('--- ' + $b.Name + ' (last 40) ---')
    Get-Content $b.FullName -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ('  ' + $_) }
} else {
    Write-Output 'no dd_bootstrapper log'
}

# Any HTTP failure the bootstrapper recorded in the event log.
Write-Output '--- recent application errors ---'
Get-EventLog -LogName Application -EntryType Error -Newest 5 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output ('  ' + $_.TimeGenerated.ToString('HH:mm') + '  ' + $_.Source + ': ' + ($_.Message -split [char]10)[0]) }
