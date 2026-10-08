' Starts the clawdex pet with no console window. Used by the desktop shortcut and by the SessionStart hook.
Set sh = CreateObject("WScript.Shell")
root = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.clawdex"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & root & "\clawdex.ps1"" -Command wake", 0, False
