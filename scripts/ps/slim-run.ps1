# Wrapper run by the scheduled task, with every step written down.
#
# Last run left these notes:
#   user=WIN-...$
#   SystemDrive=[C:]
#   slim exists=True
#   -- running slim.ps1 --
#   -- done. slim.log exists=False
#
# slim.ps1 was called and produced nothing in between. This checks the one thing that would
# explain that - whether this account can write to the root of C: at all - and stops hiding
# the reason.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $env:SystemDrive 'slim.out'

function Note($m) { Add-Content -Path $out -Value $m -ErrorAction SilentlyContinue }

Note ('wrapper start ' + (Get-Date).ToString('HH:mm:ss'))
Note ('  user=' + $env:USERNAME + '  cwd=' + (Get-Location).Path)

$probe = Join-Path $env:SystemDrive 'write-probe.txt'
try {
    Set-Content -Path $probe -Value 'ok' -ErrorAction Stop
    Note ('  write to C: SUCCEEDED')
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
} catch {
    Note ('  write to C: FAILED: ' + $_.Exception.Message)
}

$slim = Join-Path $here 'slim.ps1'
Note '-- running slim.ps1 --'
try {
    & $slim *>&1 | ForEach-Object { Note ('  | ' + $_) }
    Note '  (returned normally)'
} catch {
    Note ('  EXCEPTION: ' + $_.Exception.Message)
    Note ('  at ' + $_.InvocationInfo.PositionMessage)
}

Note ('-- done. slim.log exists=' + (Test-Path ($env:SystemDrive + '\slim.log')))
