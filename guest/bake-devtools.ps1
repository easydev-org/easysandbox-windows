# One-shot bake for the Windows `devtools` golden disk. Run INSIDE the guest
# (as the `Docker` user; UAC is off and Docker is an admin) with internet.
#
# It fixes the three gaps found on the shipped devtools disk:
#   1. Git for Windows is NOT present (VS Build Tools does not ship it).
#   2. The MACHINE Path was clobbered by an older launcher
#      (`reg add ... /d "%PATH%;%XDIR%"`), which dropped the dotnet / MSVC /
#      Windows SDK entries — so a plain job shell could not see dotnet/cl.
#   3. The VS dev environment (vcvars) was not in the machine env, so `cl`
#      needed an explicit `call vcvars64.bat` per job.
$ErrorActionPreference = 'Stop'

Write-Host '== 1. install Git for Windows =='
winget install --id Git.Git -e --source winget `
  --accept-package-agreements --accept-source-agreements `
  --silent --disable-interactivity

Write-Host '== 2. repair the machine Path (add dotnet + Git) =='
$m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$parts = @($m.Split(';') | Where-Object { $_ -ne '' })
foreach ($d in @('C:\Program Files\dotnet\', 'C:\Program Files\Git\cmd')) {
  if ($parts -notcontains $d) { $parts += $d }
}
[Environment]::SetEnvironmentVariable('Path', (($parts | Select-Object -Unique) -join ';'), 'Machine')

Write-Host '== 3. import the VS dev environment (vcvars64) into the machine env =='
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
if (Test-Path $vcvars) {
  $dump = cmd /c "`"$vcvars`" >nul && set"
  foreach ($line in $dump) {
    $i = $line.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $line.Substring(0, $i); $v = $line.Substring($i + 1)
    switch -Regex ($k.ToUpperInvariant()) {
      '^PATH$' {
        $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $cp = @($cur.Split(';') | Where-Object { $_ -ne '' })
        foreach ($d in $v.Split(';')) { if ($d -and ($cp -notcontains $d)) { $cp += $d } }
        [Environment]::SetEnvironmentVariable('Path', ($cp -join ';'), 'Machine')
      }
      '^(INCLUDE|LIB|LIBPATH)$' {
        [Environment]::SetEnvironmentVariable($k, $v, 'Machine')
      }
    }
  }
} else {
  Write-Warning "vcvars64.bat not found at $vcvars (cl will need a per-job call)"
}

Write-Host 'bake-devtools: done. Verify with: git --version; dotnet --version; where cl'

Write-Host '== 4. register the easystream daemon task (admin, interactive) =='
# oem.cmd cannot create this at boot: it runs as the unprivileged interactive
# token, and `schtasks /create /rl HIGHEST` then fails with "Access is denied"
# (the daemon never started). Register it HERE, at bake time, as an admin.
# The task runs a hidden VBS wrapper so no console window appears on the
# desktop, and Task Scheduler starts it OUTSIDE the worker's job object (a
# child process would be killed with the job).
$daemonVbs = 'C:\Users\Docker\daemon.vbs'
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>easystream est:// daemon (hidden, interactive)</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$env:COMPUTERNAME\Docker</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Windows\System32\wscript.exe</Command>
      <Arguments>//B //Nologo $daemonVbs</Arguments>
      <WorkingDirectory>C:\Users\Docker</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
$tmp = 'C:\Users\Docker\easystream-task.xml'
[IO.File]::WriteAllText($tmp, $xml, [Text.Encoding]::Unicode)
schtasks /create /tn Easystream /xml $tmp /f
Remove-Item $tmp -Force
Write-Host 'bake-devtools: easystream task registered'
