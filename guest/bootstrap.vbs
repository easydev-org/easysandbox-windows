' bootstrap.vbs — the ONLY file on the golden disk (plus the `Bootstrap` task).
'
' Its single job: pull the real launch script (oem.cmd) from the container and
' run it hidden — never a visible console window on the desktop.
' Everything else (worker binary, easystream daemon, launch logic) is served by
' the image's nginx, so ANY launch change is an image change — the golden disk
' never needs a rebake.
'
' Window style 0 = hidden (the `Bootstrap` task runs it as `Docker`,
' interactive, High-IL, so UAC is off and jobs need no elevation).
Option Explicit
Dim sh, fso, boot, f, n, sz
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

boot = "C:\Users\Docker\oem.cmd"
If Not fso.FolderExists("C:\Users\Docker\workspace") Then
  fso.CreateFolder("C:\Users\Docker\workspace")
End If

' Register the easystream daemon task HERE, once, as an ADMIN.
' This script is launched by the pre-registered `Bootstrap` task with
' RunLevel=HighestAvailable, so we hold the elevation that
' `schtasks /create /rl HIGHEST` needs. oem.cmd runs as the plain interactive
' token and CANNOT create it ("Access is denied"), which is why the daemon
' never started. Task Scheduler also starts the daemon OUTSIDE the worker's
' job object (a child process would be killed with the job).
Dim daemonXml, daemonVbs
daemonVbs = "C:\Users\Docker\daemon.vbs"
daemonXml = "C:\Users\Docker\easystream-task.xml"
If Not fso.FileExists(daemonXml) Then
  Dim x, ts
  x = "<?xml version=""1.0"" encoding=""UTF-16""?>" & vbCrLf & _
      "<Task version=""1.4"" xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task"">" & vbCrLf & _
      "  <RegistrationInfo><Description>easystream est daemon (hidden, interactive)</Description></RegistrationInfo>" & vbCrLf & _
      "  <Triggers />" & vbCrLf & _
      "  <Principals><Principal id=""Author""><UserId>" & sh.ExpandEnvironmentStrings("%COMPUTERNAME%") & "\Docker</UserId>" & _
      "<LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>" & vbCrLf & _
      "  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>" & _
      "<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>" & _
      "<AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>" & _
      "<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden>" & _
      "<RunOnlyIfIdle>false</RunOnlyIfIdle><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority></Settings>" & vbCrLf & _
      "  <Actions Context=""Author""><Exec><Command>C:\Windows\System32\wscript.exe</Command>" & _
      "<Arguments>//B //Nologo " & daemonVbs & "</Arguments><WorkingDirectory>C:\Users\Docker</WorkingDirectory></Exec></Actions>" & vbCrLf & _
      "</Task>"
  Set ts = fso.CreateTextFile(daemonXml, True, True)   ' True = Unicode (UTF-16)
  ts.Write x
  ts.Close
End If
On Error Resume Next
sh.Run "cmd /c schtasks /create /tn Easystream /xml """ & daemonXml & """ /f", 0, True
On Error GoTo 0

' Retry: at logon the container's nginx may not be up yet.
For n = 1 To 60
  On Error Resume Next
  fso.DeleteFile boot, True
  On Error GoTo 0
  sh.Run "cmd /c curl.exe -s -m 30 -o """ & boot & """ http://host.lan:8090/oem.cmd", 0, True
  sz = 0
  If fso.FileExists(boot) Then sz = fso.GetFile(boot).Size
  If sz > 100 Then Exit For
  WScript.Sleep 2000
Next

If sz > 100 Then
  ' Run oem.cmd with a HIDDEN console. `cmd /c` alone can flash a window (and
  ' any console child it spawns can show one); `start "" /b` with a 0 window
  ' style keeps the whole tree invisible on the desktop.
  sh.Run "cmd /c start """" /b cmd /c """ & boot & """", 0, False
Else
  sh.Run "cmd /c echo bootstrap fetch FAILED >> C:\Users\Docker\workspace\easyworker.log", 0, True
End If
