Set fso = CreateObject("Scripting.FileSystemObject")
strPath = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = strPath & "\launch-gui.ps1"

If fso.FileExists(ps1Path) Then
    Set WshShell = CreateObject("WScript.Shell")
    WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """", 0, False
Else
    MsgBox "Could not find launcher script: " & ps1Path, 16, "ssh-client Error"
End If
