# Wrapper run by the scheduled task. Its only job is to run slim.ps1 with its output
# captured, in a normal powershell session where redirection works.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$slim = Join-Path $here 'slim.ps1'
$out  = Join-Path $env:SystemDrive 'slim.out'
Set-Location $env:SystemDrive
& $slim *> $out
Add-Content -Path $out -Value ('EXITCODE=' + $LASTEXITCODE)
