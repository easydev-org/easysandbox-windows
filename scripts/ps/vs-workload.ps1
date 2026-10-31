# Diagnose why setup.exe refuses the modify.
#
# The previous attempt printed the log path and nothing else, because the glob
# dd_setup_*.log matched a file whose content had no line containing Error or VCTools - or
# the file was the wrong one. So: list every dd_* file with its size, print the tail of the
# newest, and ask the installer what products it knows about.
$ErrorActionPreference = 'Continue'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$path = & $vswhere -latest -products * -property installationPath
$setup = Join-Path (Split-Path $vswhere) 'setup.exe'

Write-Output '--- installer files ---'
Get-ChildItem (Join-Path $env:TEMP 'dd_*') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
    ForEach-Object { Write-Output ('  ' + $_.LastWriteTime.ToString('HH:mm:ss') + '  ' + $_.Length + '  ' + $_.Name) }

Write-Output '--- products the installer knows ---'
$boot = Join-Path (Split-Path $vswhere) '..\..\..\..\ProgramData\Microsoft\VisualStudio\Packages\_Instances'
Get-ChildItem $boot -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ('  instance: ' + $_.Name) }

Write-Output '--- channel manifest ---'
$state = Join-Path $path '..\..\..\ProgramData\Microsoft\VisualStudio\Packages\_Instances'
$ch = Get-ChildItem $state -Recurse -Filter 'state.json' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ch) {
    $j = Get-Content $ch.FullName -Raw | ConvertFrom-Json
    Write-Output ('  channelId:   ' + $j.channelId)
    Write-Output ('  installPath: ' + $j.installationPath)
    Write-Output ('  productId:   ' + $j.product.id)
    Write-Output ('  nickname:    ' + $j.product.nickname)
} else {
    Write-Output '  no state.json found'
}

Write-Output '--- setup.exe modify, verbose ---'
$args = @('modify', '--installPath', $path,
          '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended',
          '--quiet', '--norestart')
$p = Start-Process -FilePath $setup -ArgumentList $args -PassThru -Wait
Write-Output ('setup exit: ' + $p.ExitCode)

Write-Output '--- newest log, last 20 lines ---'
$log = Get-ChildItem (Join-Path $env:TEMP 'dd_*') -ErrorAction SilentlyContinue |
    Where-Object { -not $_.PSIsContainer } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) {
    Write-Output ('  ' + $log.Name)
    Get-Content $log.FullName -Tail 20 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Output ('    ' + $_) }
}

$pkgs = & $vswhere -latest -products * -property packages 2>$null
if ($pkgs -and ($pkgs -match 'Microsoft.VisualStudio.Workload.VCTools')) {
    Write-Output 'VCTOOLS_PRESENT'
} else {
    Write-Output 'VCTOOLS_ABSENT'
}
