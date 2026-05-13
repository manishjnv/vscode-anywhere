' ============================================================================
' run-hidden.vbs -- invisible launcher for PowerShell scripts
' ----------------------------------------------------------------------------
' Used by the "Dev Environment Health Check" scheduled task. Task Scheduler
' runs powershell.exe with -WindowStyle Hidden, but Windows still flashes the
' console window for a fraction of a second before the WindowStyle directive
' is applied. That flash is what the user sees as a popup every 2 minutes.
'
' WScript.Run with intWindowStyle=0 starts the process with no window at all,
' so there is nothing to flash. The script then exits immediately.
'
' Usage from Task Scheduler:
'   Program:   wscript.exe
'   Arguments: "E:\code\remote-vscode-wsl-cloudflare\windows\run-hidden.vbs" "E:\code\remote-vscode-wsl-cloudflare\windows\health-check.ps1"
'
' First arg = path to a .ps1 file. Remaining args are forwarded to it.
' ============================================================================

If WScript.Arguments.Count < 1 Then
    WScript.Quit 2
End If

Dim shell, cmd, i
Set shell = CreateObject("WScript.Shell")

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " """ & WScript.Arguments(i) & """"
Next

' intWindowStyle = 0 (hidden), bWaitOnReturn = False (fire and forget)
shell.Run cmd, 0, False
