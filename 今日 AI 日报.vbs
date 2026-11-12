Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "AI-Digest\ensure-today.ps1")
If Not fso.FileExists(scriptPath) Then
  MsgBox "AI Digest launcher is not installed.", 16, "AI Digest"
  WScript.Quit 1
End If
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
