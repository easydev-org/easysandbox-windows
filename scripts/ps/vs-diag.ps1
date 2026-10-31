$ErrorActionPreference = "Continue"

Write-Output "--- defender status ---"
try { $m = Get-MpPreference -ErrorAction Stop; Write-Output ("  DisableRealtimeMonitoring: " + $m.DisableRealtimeMonitoring) } catch { Write-Output "  Get-MpPreference unavailable" }
try { $s = Get-MpComputerStatus -ErrorAction Stop; Write-Output ("  RealTimeProtectionEnabled: " + $s.RealTimeProtectionEnabled); Write-Output ("  AntivirusEnabled: " + $s.AntivirusEnabled) } catch { Write-Output "  Get-MpComputerStatus unavailable" }

Write-Output "--- defender detections in the last hour ---"
try {
    Get-MpThreatDetection -ErrorAction Stop | Sort-Object InitialDetectionTime -Descending | Select-Object -First 5 | ForEach-Object { Write-Output ("  " + $_.InitialDetectionTime + "  " + $_.Resources) }
} catch { Write-Output "  no detections or unavailable" }

Write-Output "--- defender quarantine ---"
try {
    Get-MpThreat -ErrorAction Stop | Sort-Object LastThreatStatusChangeTime -Descending | Select-Object -First 5 | ForEach-Object { Write-Output ("  " + $_.ThreatName + "  " + $_.Resources) }
} catch { Write-Output "  none" }

Write-Output "--- the exe itself ---"
$exe = Join-Path $env:TEMP "vs_BuildTools.exe"
if (Test-Path $exe) {
    $f = Get-Item $exe
    Write-Output ("  size: " + $f.Length)
    Write-Output ("  created: " + $f.CreationTime)
    $h = (Get-FileHash $exe -Algorithm SHA256).Hash
    Write-Output ("  sha256: " + $h)
    $sig = Get-AuthenticodeSignature $exe
    Write-Output ("  signature: " + $sig.Status)
    Write-Output ("  signer: " + $sig.SignerCertificate.Subject)
} else { Write-Output "  vs_BuildTools.exe gone" }

Write-Output "--- disk errors in system log ---"
Get-EventLog -LogName System -EntryType Error -Newest 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("  " + $_.TimeGenerated.ToString("HH:mm") + "  " + $_.Source + ": " + ($_.Message -split [char]10)[0]) }
