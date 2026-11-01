# Fill the free space with zeros, then delete the file.
#
# qemu-img convert -O qcow2 skips clusters that are zero and stores the rest. NTFS leaves the
# bytes of a deleted file in its clusters, so without this every clean produces an image the
# same size as before - which is what has been happening.
#
# Detached from the ssh session that starts it: filling 35 GB takes tens of minutes and no
# single ssh call survives that. A marker file says when it finished.
$ErrorActionPreference = 'Continue'

$done = Join-Path $env:SystemDrive 'zero.done'
Remove-Item $done -Force -ErrorAction SilentlyContinue

$free = (Get-PSDrive C -ErrorAction SilentlyContinue).Free
$limit = $free - 200MB
$path = Join-Path $env:SystemDrive 'zero.fill'

$written = 0
$err = ''
try {
    $fs = [System.IO.File]::Create($path)
    $buf = New-Object byte[] (4MB)
    while ($written -lt $limit) {
        $fs.Write($buf, 0, $buf.Length)
        $written += $buf.Length
    }
    $fs.Flush()
    $fs.Close()
} catch {
    $err = $_.Exception.Message
} finally {
    if ($fs) { try { $fs.Close() } catch { } }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
}

Add-Content -Path $done -Value ("written=" + $written + " error=" + $err)
