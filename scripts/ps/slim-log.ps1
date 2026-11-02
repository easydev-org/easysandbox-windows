# The whole slim log, so the caller can print it after the run.
Get-Content (Join-Path $env:SystemDrive 'slim.log') -ErrorAction SilentlyContinue
