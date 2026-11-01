# Start zero.ps1 detached. Its own file so the Start-Process quoting never crosses an ssh
# command line, where it was being mangled.
$zero = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'zero.ps1'
Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$zero) -WindowStyle Hidden
