# Start slim.ps1 detached. ResetBase takes ten to twenty minutes and no ssh call survives it.
$slim = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'slim.ps1'
Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$slim) -WindowStyle Hidden
