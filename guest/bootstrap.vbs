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
  sh.Run "cmd /c echo bootstrap fetch FAILED >> C:\Users\Docker\workspace\agent-worker.log", 0, True
End If
