Set fso = CreateObject("Scripting.FileSystemObject")
strPath = fso.GetParentFolderName(WScript.ScriptFullName)
batPath = strPath & "\launch-gui.bat"

If fso.FileExists(batPath) Then
    Set WshShell = CreateObject("WScript.Shell")
    args = ""
    For Each arg In WScript.Arguments
        args = args & " """ & arg & """"
    Next
    WshShell.Run """" & batPath & """" & args, 0, False
Else
    MsgBox "Could not find launcher script: " & batPath, 16, "ssh-client Error"
End If
