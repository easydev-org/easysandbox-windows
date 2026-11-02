# Wrapper run by the scheduled task, with every step written down.
#
# The previous version reported rc=0 and created slim.out, but the file held only an empty
# EXITCODE= and slim.log was never created. Rather than guess which part of the environment
# was missing, this records each one before calling slim.ps1.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $env:SystemDrive 'slim.out'

function Note($m) { Add-Content -Path $out -Value $m -ErrorAction SilentlyContinue }

Note ('wrapper start ' + (Get-Date).ToString('HH:mm:ss'))
Note ('  user=' + $env:USERNAME)
Note ('  SystemDrive=[' + $env:SystemDrive + ']')
Note ('  here=' + $here)

$slim = Join-Path $here 'slim.ps1'
Note ('  slim exists=' + (Test-Path $slim))

Note '-- running slim.ps1 --'
$ErrorActionPreference = 'Continue'
& $slim *>&1 | ForEach-Object { Note ('  | ' + $_) }

Note ('-- done. slim.log exists=' + (Test-Path ($env:SystemDrive + '\slim.log')))
