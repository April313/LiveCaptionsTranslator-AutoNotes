' ============================================================
'  Quiet launcher: no console window, no "press any key".
'  ASCII-only on purpose so file encoding never matters.
'  Double-click this file, or use the desktop shortcut.
' ============================================================
Option Explicit
Dim fso, sh, appDir, ps, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

appDir = fso.GetParentFolderName(WScript.ScriptFullName)

ps = "powershell.exe"
cmd = """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
      & appDir & "\launch.ps1"""

sh.CurrentDirectory = appDir
' 0 = hidden window, False = do not wait for it to finish
sh.Run cmd, 0, False
