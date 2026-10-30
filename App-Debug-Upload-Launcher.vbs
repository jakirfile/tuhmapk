Option Explicit

Dim shell, scriptPath, batchPath, powershellPath, command, argumentIndex
Set shell = CreateObject("WScript.Shell")

scriptPath = WScript.Arguments(0)
batchPath = WScript.Arguments(1)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = """" & powershellPath & """ -NoProfile -STA -ExecutionPolicy Bypass -File """ & scriptPath & """ -BatchPath """ & batchPath & """"
For argumentIndex = 2 To WScript.Arguments.Count - 1
    If Left(WScript.Arguments(argumentIndex), 1) = "-" Then
        command = command & " " & WScript.Arguments(argumentIndex)
    Else
        command = command & " """ & WScript.Arguments(argumentIndex) & """"
    End If
Next
shell.Run command, 0, False
