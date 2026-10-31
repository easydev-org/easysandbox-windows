# Install VCTools with the evergreen bootstrapper, WITHOUT holding the ssh session open.
#
# WHY NOT -Wait. The bootstrapper installs several GB and takes ten to twenty minutes. The ssh
# session that launched it does not survive that: the run showed
#     Connection to 127.0.0.1 closed by remote host
# immediately after 'running the bootstrapper', and the install carried on unwatched.
#
# So it is started without -Wait, the process id is written down, and a separate command polls
# it. Each poll is a short ssh round trip; no session has to stay alive for the duration.
$ErrorActionPreference = 'Continue'

$boot = Join-Path $env:TEMP 'vs_BuildTools.exe'
$marker = Join-Path $env:TEMP 'vs-install.done'
Remove-Item $marker -ErrorAction SilentlyContinue

Write-Output ('OS build: ' + [System.Environment]::OSVersion.Version.ToString())

if (-not (Test-Path $boot)) {
    Write-Output 'downloading vs_BuildTools.exe (evergreen)'
    try {
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $boot -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Output ('DOWNLOAD_FAILED: ' + $_.Exception.Message); exit 1
    }
}
Write-Output ('bootstrapper: ' + (Get-Item $boot).Length + ' bytes')

$args = @('--quiet','--wait','--norestart','--nocache',
          '--add','Microsoft.VisualStudio.Workload.VCTools','--includeRecommended')
Write-Output ('args: ' + ($args -join ' '))

# DETACHED. -PassThru gives the pid; the process keeps running after this script exits.
$p = Start-Process -FilePath $boot -ArgumentList $args -PassThru
Write-Output ('started pid ' + $p.Id)
$p.Id | Out-File -FilePath (Join-Path $env:TEMP 'vs-install.pid') -Encoding ascii
