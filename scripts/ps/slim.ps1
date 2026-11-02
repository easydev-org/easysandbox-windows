# Remove Windows components this image does not need, then compact the component store.
#
# Three groups, in order of how much they give back:
#
#   ResetBase      DISM StartComponentCleanup /ResetBase removes superseded component
#                  versions from WinSxS and drops the ability to uninstall old updates.
#                  On a golden image that trade is right - nothing uninstalls an update on
#                  a build agent - and it is the single largest saving available.
#
#   capabilities   features that exist for compatibility and are legacy now. Removing a
#                  capability deletes its files, unlike disabling a feature.
#
#   optional       features that are installed but never used on a build agent: fax, IIS,
#                  Media Player, PowerShell 2 and the PDF/XPS printers.
#
#   appx           provisioned and installed packages. This removes what ships with
#                  Windows, not what the pipeline installed - the toolchain is untouched.
#
# WHAT IS LEFT ALONE, on purpose: Edge and WebView (asked for explicitly), the Store,
# Windows Terminal, the servicing stack, and anything the toolchain depends on.
#
# Runs detached from clean.ps1 because ResetBase alone takes ten to twenty minutes and no
# single ssh call survives that. Progress goes to a marker file.
$ErrorActionPreference = 'SilentlyContinue'


$log = Join-Path $env:SystemDrive 'slim.log'
$done = Join-Path $env:SystemDrive 'slim.done'
Remove-Item $log, $done -Force -ErrorAction SilentlyContinue

# FIRST LINE OF EVIDENCE, written after the old logs are cleared so it is not immediately
# deleted. rc=1 with no log at all means powershell never ran this file; a log holding only
# this line means it started and something later broke.
Set-Content -Path $log -Value (('started ' + (Get-Date).ToString('HH:mm:ss') + ' as ' + $env:USERNAME)) -ErrorAction SilentlyContinue

function Say($m) {
    Add-Content -Path $log -Value $m
}

function SizeOf($p) {
    if (-not (Test-Path $p)) { return 0 }
    $s = (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if (-not $s) { return 0 }
    return [math]::Round($s/1MB,1)
}

$before = (Get-PSDrive C).Used
Say ("used before: " + [math]::Round($before/1MB,0) + " MB")
Say ("WinSxS before: " + (SizeOf "$env:SystemRoot\WinSxS") + " MB")

Say '--- stage 1: capabilities ---'
# Remove-WindowsCapability deletes the files. Order matters only in that the ones that are
# not present raise an error, which is suppressed - a missing capability is not a problem.
$caps = @(
    'Browser.InternetExplorer*',
    'Microsoft.Windows.WordPad*',
    'App.StepsRecorder*',
    'MathRecognizer*',
    'Microsoft.Windows.PowerShell.ISE*',
    'Print.Fax.Scan*',
    'Print.Management.Console*',
    'App.Support.QuickAssist*'
)
foreach ($c in $caps) {
    $found = Get-WindowsCapability -Online -Name $c -ErrorAction SilentlyContinue
    foreach ($f in $found) {
        if ($f.State -eq 'Installed') {
            Say ('  removing ' + $f.Name)
            Remove-WindowsCapability -Online -Name $f.Name -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
Say ('  capabilities done, used ' + [math]::Round((Get-PSDrive C).Used/1MB,0) + ' MB')

Say '--- stage 2: optional features ---'
$feats = @(
    'FaxServicesClientPackage',
    'IIS-WebServerRole',
    'IIS-WebServer',
    'IIS-CommonHttpFeatures',
    'LegacyComponents',
    'MediaPlayback',
    'MicrosoftWindowsPowerShellV2',
    'MicrosoftWindowsPowerShellV2Root',
    'Printing-PrintToPDFServices-Features',
    'Printing-XPSServices-Features',
    'WorkFolders-Client',
    'WindowsMediaPlayer'
)
foreach ($f in $feats) {
    $s = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
    if ($s -and $s.State -eq 'Enabled') {
        Say ('  disabling ' + $f)
        Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }
}
Say ('  optional features done, used ' + [math]::Round((Get-PSDrive C).Used/1MB,0) + ' MB')

Say '--- stage 3: appx ---'
# INSTALLED AND PROVISIONED. Removing the installed package alone leaves the provisioned
# copy, which is laid down again for every new user profile - the disk would look clean and
# the next account would get the apps back.
#
# Edge, the Store and Terminal are not in this list. Neither is anything the toolchain
# touches; VS, the SDK and dotnet do not ship as appx.
$apps = @(
    'Clipchamp.Clipchamp',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.BingFinance',
    'Microsoft.BingSports',
    'Microsoft.BingFoodAndDrink',
    'Microsoft.BingTravel',
    'Microsoft.BingHealthAndFitness',
    'Microsoft.BingTranslator',
    'Microsoft.GamingApp',
    'Microsoft.XboxApp',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.Xbox.TCUI',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MixedReality.Portal',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'Microsoft.549981C3F5F10',
    'Microsoft.Windows.DevHome',
    'Microsoft.Windows.Copilot',
    'Microsoft.Copilot',
    'MicrosoftTeams',
    'MSTeams',
    'Microsoft.OutlookForWindows',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'Microsoft.MicrosoftPCManager',
    'Microsoft.Windows.AIHub',
    'Microsoft.NetworkSpeedTest',
    'Microsoft.Office.OneNote',
    'Microsoft.Office.Sway',
    'Microsoft.Print3D',
    'Microsoft.OneConnect',
    'Microsoft.Messaging',
    'Microsoft.MicrosoftJournal',
    'Microsoft.MicrosoftPowerBIForWindows',
    'ACGMediaPlayer',
    'ActiproSoftwareLLC',
    'AdobeSystemsIncorporated.AdobePhotoshopExpress',
    'Amazon.com.Amazon',
    'AmazonVideo.PrimeVideo',
    'Asphalt8Airborne',
    'AutodeskSketchBook',
    'CaesarsSlotsFreeCasino',
    'COOKINGFEVER',
    'CyberLinkMediaSuiteEssentials',
    'DisneyMagicKingdoms',
    'Disney.37853FC22B2CE',
    'DrawboardPDF',
    'Duolingo-LearnLanguagesforFree',
    'EclipseManager',
    'Facebook.Facebook',
    'FarmVille2CountryEscape',
    'Fitbit.FitbitCoach',
    'Flipboard.Flipboard',
    'GAMELOFTSA.Asphalt8Airborne',
    'HiddenCityMysteryofShadows',
    'HuluLLC.HuluPlus',
    'KoeiTecmoAmerica.NobunagasAmbitionSphereofInfluence',
    'Microsoft.BingNews',
    'Microsoft.SkypeApp',
    'Microsoft.Wallet',
    'Microsoft.WindowsCommunicationsApps',
    'NetflixInc.Netflix',
    'PandoraMediaInc.Pandora',
    'PhototasticCollage',
    'PicsArt-PhotoStudio',
    'Playtika.CaesarsSlotsFreeCasino',
    'Royal Revolt 2',
    'ShazamEntertainmentLtd.Shazam',
    'Sidia.LiveWallpaper',
    'SpotifyAB.SpotifyMusic',
    'TheNewYorkTimes.NYTCrossword',
    'TuneIn.TuneInRadio',
    'WinZipUniversal',
    'Wunderlist',
    'XING.EU'
)
$removed = 0
foreach ($n in $apps) {
    foreach ($p in (Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)) {
        Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        $removed++
    }
    foreach ($p in (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like ($n + '*') })) {
        Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null
        $removed++
    }
}
Say ('  removed ' + $removed + ' appx entries')
Say ('  appx done, used ' + [math]::Round((Get-PSDrive C).Used/1MB,0) + ' MB')

Say '--- stage 4: component store ---'
# THE BIG ONE, and the slowest. StartComponentCleanup removes superseded component
# versions; /ResetBase additionally drops the record of previous versions, which is what
# makes them removable from the store. The cost is that installed updates can no longer be
# uninstalled - acceptable on a golden image, since nothing uninstalls an update on a
# build agent.
#
# This is where the ten to twenty minutes go.
$wsBefore = SizeOf "$env:SystemRoot\WinSxS"
# DISM writes progress to its own log; this only records that it ran and what it said.
$out = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
$code = $LASTEXITCODE
Say ('  dism exit ' + $code)
# Only the tail: DISM prints a percentage bar that would fill the log with noise.
$out | Select-Object -Last 6 | ForEach-Object { Say ('    ' + $_.ToString().Trim()) }
$wsAfter = SizeOf ($env:SystemRoot + '\WinSxS')
Say ('  WinSxS after: ' + $wsAfter + ' MB')

$after = (Get-PSDrive C).Used
Say ('used after:  ' + [math]::Round($after/1MB,0) + ' MB')
Say ('freed:       ' + [math]::Round(($before - $after)/1MB,0) + ' MB')
Add-Content -Path $done -Value 'SLIM_DONE'
