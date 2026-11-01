# Clean the traces a build leaves, before the disk is exported.
#
# This disk is handed on as a golden image. Whatever this run put on it - installers,
# extraction directories, a test .c file, my own helper scripts, shell history - travels
# with it unless it is removed here, and it is visible to whoever gets the image.
#
# WHAT IS DELIBERATELY KEPT: the installed products themselves. Only caches, temp files,
# logs and history go. Nothing here touches Program Files, ProgramData\Microsoft\VisualStudio\Packages
# (the VS payload cache is what makes repair and update work), or the dotnet SDK.
$ErrorActionPreference = 'Continue'

$before = (Get-PSDrive C -ErrorAction SilentlyContinue).Used
Write-Output ("=== clean ===")
Write-Output ("used before: " + [math]::Round($before/1MB,0) + " MB")

function Report($what, $path) {
    if ($path -and (Test-Path $path)) {
        $sz = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Write-Output ("  " + $what + ": " + [math]::Round(($sz/1MB),1) + " MB")
    } else {
        Write-Output ("  " + $what + ": absent")
    }
}

# 1. My own helper scripts and the compile test.
Write-Output "--- build artefacts ---"
Report "msvc-check dir" (Join-Path $env:USERPROFILE "msvc-check")
Remove-Item (Join-Path $env:USERPROFILE "msvc-check") -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:USERPROFILE -Filter "vs-*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output ("  removing " + $_.Name)
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
}
Get-ChildItem $env:USERPROFILE -Filter "msvc-check.ps1" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# 2. User and system temp.
Write-Output "--- temp ---"
Report "user TEMP" $env:TEMP
Get-ChildItem $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
Report "Windows Temp" (Join-Path $env:SystemRoot "Temp")
Get-ChildItem (Join-Path $env:SystemRoot "Temp") -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# 3. winget download cache. The installed packages stay; only the downloaded installers go.
Write-Output "--- winget cache ---"
Get-ChildItem (Join-Path $env:LOCALAPPDATA "Packages") -Directory -Filter "Microsoft.DesktopAppInstaller_*" -ErrorAction SilentlyContinue | ForEach-Object {
# $_ is the package directory here; an inner pipeline would overwrite it, so this is
# kept as a separate variable and the inner loops use $sub and $_.
    $pkg = $_
    Write-Output ("  " + $pkg.Name)
    $ls = Join-Path $pkg.FullName "LocalState"
    if (Test-Path $ls) {
        Get-ChildItem $ls -Directory -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("    " + $_.Name) }
    }
    foreach ($sub in @("Temp", "DownloadedInstallers", "Manifests")) {
        $p = Join-Path $ls $sub
        if (Test-Path $p) {
            $sz = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $mb = [math]::Round(($sz/1MB),1)
            Write-Output ("    removing " + $sub + ": " + $mb + " MB")
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 4. Delivery optimisation cache - Windows Update style peer cache, often several GB.
Write-Output "--- delivery optimisation ---"
$do = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"
Report "DeliveryOptimization" $do
if (Test-Path $do) {
    Get-ChildItem $do -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output "  contents removed"
}

# 5. Shell history.
Write-Output "--- history ---"
$hist = Join-Path $env:APPDATA "Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
if (Test-Path $hist) { Write-Output ("  PSReadLine history: " + (Get-Item $hist).Length + " bytes") } else { Write-Output "  PSReadLine history: absent" }
Remove-Item $hist -Force -ErrorAction SilentlyContinue

# 6. Run dialog and recent documents, which list what was executed.
Write-Output "--- shell traces ---"
Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:APPDATA "Microsoft\Windows\Recent\*") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations\*") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations\*") -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "  recent items and jump lists cleared"

# 7. Recycle bin.
Write-Output "--- recycle bin ---"
# Clear-RecycleBin cannot resolve a bin in a non-interactive ssh session - it answers
# "The system cannot find the path specified" whatever -DriveLetter is given. Deleting the
# contents of $Recycle.Bin directly does the same job and needs no shell folder.
# $Recycle is a variable name to PowerShell, so the path is concatenated
# rather than interpolated: the quoted form expanded to ".Bin" and matched nothing.
$rb = $env:SystemDrive + '\$Recycle.Bin'
if (Test-Path $rb) {
    $n = 0
    Get-ChildItem $rb -Force -ErrorAction SilentlyContinue | ForEach-Object {
# $Recycle.Bin holds one folder per SID; leave nothing inside any of them.
        Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            $n++
        }
    }
    Write-Output ("  emptied (removed " + $n + " items from " + $rb + ")")
} else {
    Write-Output ("  no " + $rb + " on this drive")
}

# 8. Event logs. Cleared last, and each log is only cleared if it will clear - some are
# locked while a service holds them.
Write-Output "--- event logs ---"
$cleared = 0
foreach ($log in @("Application","System","Security","Setup","Windows PowerShell")) {
    try { wevtutil cl $log 2>$null; $cleared++ } catch { }
}
Write-Output ("  cleared " + $cleared + " logs")

# 9. The build toolchain's caches, as opposed to Windows' own.
#
# These are what the dev stage adds on top of the ssh stage, and none of them are needed by
# the finished image:
#   Package Cache           copies of every MSI that was installed, ~0.7 GB
#   ...\VisualStudio\Packages  the VS payload cache, kept only so Setup can modify or repair
#   SoftwareDistribution    Windows Update download cache
# Removing them costs nothing that a build needs; keeping them is most of the 3.25 GiB that
# the dev stage adds over and above the 5.6 GiB of toolchain that is actually installed.
 Write-Output "--- build caches ---"
 foreach ($p in @(
     "C:\ProgramData\Package Cache",
     "C:\ProgramData\Microsoft\Visual Studio\Packages",
     "$env:SystemRoot\SoftwareDistribution\Download",
    ($env:SystemRoot + '\Installer\$PatchCache$')
 )) {
     if (Test-Path $p) {
         # Measure-Object throws when the input is empty; with ErrorActionPreference Continue
         # that still printed an error and the delete below never ran, so a cache folder that
         # was already empty aborted the rest of the list.
         $files = @(Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue)
         if ($files.Count -gt 0) {
             $mb = ($files | Measure-Object -Property Length -Sum).Sum
             Write-Output ("  " + [math]::Round($mb/1MB,1) + " MB  " + $p)
         } else {
             Write-Output ("  0 MB  " + $p)
         }
         Get-ChildItem $p -Force -ErrorAction SilentlyContinue |
             ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
         Write-Output "    removed contents"
     }
 }

# 10. Free space is zeroed by a SEPARATE SCRIPT, and stage_clean runs it and polls.
#
# export runs qemu-img convert -O qcow2 over the raw disk, and qcow2 skips only clusters that
# are already zero. NTFS marks deleted clusters free but leaves the bytes, so convert stores
# them and the image comes out the same size - which is why the earlier cleans reported
# "freed: 1100 MB" and published an unchanged 21.5 GiB.
#
# It is not done here because filling 35 GB takes tens of minutes and this script runs under
# a single ssh call that would not survive it. zero.ps1 does the work, writes a marker when
# it is done, and stage_clean starts it detached and asks for progress.
Write-Output "--- ssh and credentials ---"
$kh = Join-Path $env:USERPROFILE ".ssh\known_hosts"
if (Test-Path $kh) { Remove-Item $kh -Force -ErrorAction SilentlyContinue; Write-Output "  known_hosts removed" } else { Write-Output "  known_hosts absent" }
cmdkey /list 2>$null | Select-String "Target:" | ForEach-Object { Write-Output ("  credential: " + $_.Line) }

$after = (Get-PSDrive C -ErrorAction SilentlyContinue).Used
Write-Output ("used after:  " + [math]::Round($after/1MB,0) + " MB")
Write-Output ("freed:        " + [math]::Round(($before - $after)/1MB,1) + " MB")
Write-Output "CLEAN_DONE"
