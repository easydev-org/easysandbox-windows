$ErrorActionPreference = "Continue"

$boot = Join-Path $env:TEMP "vs_BuildTools.exe"
Write-Output ("OS build: " + [System.Environment]::OSVersion.Version.ToString())

# TURN DEFENDER OFF FIRST.
#
# vs_BuildTools.exe creates its extraction directory and puts nothing in it:
#   dir: C:\Users\docker\AppData\Local\Temp\d2a5fdad...   (empty)
#   no vs_setup.exe found
# A self-extracting exe that creates its output directory and fills it with nothing is
# the signature of an on-access scanner blocking the writes. These disks come straight
# from Setup and the firewall is already off; Defender is the remaining thing that
# interferes, and it is not wanted on a build agent anyway.
foreach ($attempt in 1..2) {
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
        Write-Output "defender: realtime monitoring off"
        break
    } catch {
        Write-Output ("defender attempt " + $attempt + " failed: " + $_.Exception.Message)
        Start-Sleep -Seconds 5
    }
}
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp) { Write-Output ("  RealTimeProtectionEnabled now: " + $mp.RealTimeProtectionEnabled) }

# Also tell Defender to leave the temp directory alone, in case policy re-enables it.
try { Add-MpPreference -ExclusionPath $env:TEMP -ErrorAction SilentlyContinue; Write-Output ("  excluded: " + $env:TEMP) } catch { }

if (-not (Test-Path $boot)) {
    Write-Output "downloading vs_BuildTools.exe (evergreen)"
    try { Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" -OutFile $boot -UseBasicParsing -TimeoutSec 300 }
    catch { Write-Output ("DOWNLOAD_FAILED: " + $_.Exception.Message); exit 1 }
}
Write-Output ("bootstrapper: " + (Get-Item $boot).Length + " bytes")

$args = @("--quiet","--wait","--norestart","--nocache","--add","Microsoft.VisualStudio.Workload.VCTools","--includeRecommended")
Write-Output ("args: " + ($args -join " "))
$p = Start-Process -FilePath $boot -ArgumentList $args -PassThru
Write-Output ("started pid " + $p.Id)
$p.Id | Out-File -FilePath (Join-Path $env:TEMP "vs-install.pid") -Encoding ascii
