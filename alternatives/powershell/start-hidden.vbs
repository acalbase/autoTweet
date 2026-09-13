Set objFso = CreateObject("Scripting.FileSystemObject")
Set objShell = CreateObject("WScript.Shell")
strPath = objFso.GetParentFolderName(WScript.ScriptFullName)
strCmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strPath & "\YoutubeLiveTweet.ps1"""
objShell.Run strCmd, 0, False
