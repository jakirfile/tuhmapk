param(
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    throw 'Could not determine the project folder from the script location.'
}
$rootPath = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    throw "Project folder does not exist: $rootPath"
}

$source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class FolderRestartManager
{
    [StructLayout(LayoutKind.Sequential)]
    public struct UniqueProcess
    {
        public int ProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct ProcessInfo
    {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string ApplicationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string ServiceShortName;
        public uint ApplicationType;
        public uint ApplicationStatus;
        public uint TerminalServicesSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool Restartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmStartSession(out uint sessionHandle, int flags, StringBuilder sessionKey);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmRegisterResources(
        uint sessionHandle,
        uint fileCount,
        string[] fileNames,
        uint applicationCount,
        UniqueProcess[] applications,
        uint serviceCount,
        string[] serviceNames);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmGetList(
        uint sessionHandle,
        out uint processInfoNeeded,
        ref uint processInfoCount,
        [In, Out] ProcessInfo[] affectedApplications,
        ref uint rebootReasons);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmShutdown(uint sessionHandle, int actionFlags, IntPtr statusCallback);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint sessionHandle);
}
'@

Add-Type -TypeDefinition $source

function Get-AffectedProcesses([uint32]$SessionHandle) {
    [uint32]$needed = 0
    [uint32]$count = 0
    [uint32]$rebootReasons = 0
    $result = [FolderRestartManager]::RmGetList(
        $SessionHandle, [ref]$needed, [ref]$count, $null, [ref]$rebootReasons
    )

    if ($result -eq 0 -and $needed -eq 0) {
        return @()
    }
    if ($result -ne 234 -and $result -ne 0) {
        throw "Windows could not query processes using this folder (error $result)."
    }

    $count = $needed
    $processInfo = [FolderRestartManager+ProcessInfo[]]::new([int]$needed)
    $result = [FolderRestartManager]::RmGetList(
        $SessionHandle, [ref]$needed, [ref]$count, $processInfo, [ref]$rebootReasons
    )
    if ($result -ne 0) {
        throw "Windows could not retrieve the list of processes (error $result)."
    }

    return @($processInfo | Select-Object -First ([int]$count))
}

function Get-AffectedProcessesForFile([string]$Path) {
    $fileSessionKey = [Text.StringBuilder]::new(33)
    [uint32]$fileSessionHandle = 0
    $fileResult = [FolderRestartManager]::RmStartSession(
        [ref]$fileSessionHandle, 0, $fileSessionKey
    )
    if ($fileResult -ne 0) {
        throw "Could not start a file check for '$Path' (error $fileResult)."
    }

    try {
        [string[]]$filePath = @($Path)
        $fileResult = [FolderRestartManager]::RmRegisterResources(
            $fileSessionHandle, 1, $filePath, 0, $null, 0, $null
        )
        if ($fileResult -ne 0) {
            throw "Could not check whether '$Path' is in use (error $fileResult)."
        }

        return @(Get-AffectedProcesses $fileSessionHandle)
    }
    finally {
        $fileResult = [FolderRestartManager]::RmEndSession($fileSessionHandle)
        if ($fileResult -ne 0) {
            throw "Could not close the file-check session for '$Path' (error $fileResult)."
        }
    }
}

$sessionKey = [Text.StringBuilder]::new(33)
[uint32]$sessionHandle = 0
$result = [FolderRestartManager]::RmStartSession([ref]$sessionHandle, 0, $sessionKey)
if ($result -ne 0) {
    throw "Could not start Windows Restart Manager (error $result)."
}

try {
    $paths = [System.Collections.Generic.List[string]]::new()
    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($rootPath)

    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if (
                $entry.PSIsContainer -and
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
            ) {
                $pendingDirectories.Push($entry.FullName)
            } elseif (-not $entry.PSIsContainer) {
                $paths.Add($entry.FullName)
            }
        }
    }

    if ($paths.Count -eq 0) {
        Write-Host "No files were found in this folder:"
        Write-Host $rootPath
        exit 0
    }

    for ($offset = 0; $offset -lt $paths.Count; $offset += 1000) {
        $last = [Math]::Min($offset + 999, $paths.Count - 1)
        [string[]]$batch = $paths.GetRange($offset, $last - $offset + 1).ToArray()
        $result = [FolderRestartManager]::RmRegisterResources(
            $sessionHandle, [uint32]$batch.Length, $batch, 0, $null, 0, $null
        )
        if ($result -ne 0) {
            throw "Could not register project files with Windows Restart Manager (error $result)."
        }
    }

    $affected = @(Get-AffectedProcesses $sessionHandle)
    if ($affected.Count -eq 0) {
        Write-Host "Restart Manager found no application locking a file in this folder:"
        Write-Host $rootPath
        Write-Host ""
        Write-Host "A folder handle or a temporary sync/indexing lock may not appear in this list."
        $possibleApps = @(
            Get-Process -Name Code, studio64, java, adb, GoogleDriveFS -ErrorAction SilentlyContinue |
                Sort-Object ProcessName, Id
        )
        if ($possibleApps.Count -gt 0) {
            Write-Host "Running apps to check (not confirmed as the cause):"
            foreach ($process in $possibleApps) {
                Write-Host ("  {0} (PID {1})  {2}" -f $process.ProcessName, $process.Id, $process.Path)
            }
        }
        Write-Host "Close any relevant app or sync window, then try renaming the folder again."
        exit 0
    }

    Write-Host "Checking which files are in use..."
    $fileLocks = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $paths.Count; $index++) {
        $file = $paths[$index]
        $fileProcesses = @(Get-AffectedProcessesForFile $file)
        foreach ($item in $fileProcesses) {
            $processId = $item.Process.ProcessId
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            $name = if ($process) { $process.ProcessName } else { $item.ApplicationName }
            $fileLocks.Add([pscustomobject]@{
                Path = $file
                ProcessId = $processId
                ProcessName = $name
            })
        }
        Write-Progress -Activity 'Finding locked project files' `
            -Status "$($index + 1) of $($paths.Count)" `
            -PercentComplete ((($index + 1) / $paths.Count) * 100)
    }
    Write-Progress -Activity 'Finding locked project files' -Completed

    if ($fileLocks.Count -gt 0) {
        Write-Host "Files in use and the applications using them:"
        foreach ($lock in $fileLocks) {
            Write-Host ("  {0}  <-- {1} (PID {2})" -f $lock.Path, $lock.ProcessName, $lock.ProcessId)
        }
    } else {
        Write-Host "Windows identified applications using this project but could not map them to individual files."
        foreach ($item in $affected) {
            $processId = $item.Process.ProcessId
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            $name = if ($process) { $process.ProcessName } else { $item.ApplicationName }
            Write-Host ("  {0} (PID {1})" -f $name, $processId)
        }
        Write-Host "A folder handle or a file opened during the scan may be responsible."
    }
    Write-Host ""
    Write-Host "Windows will ask these applications to close normally. Save your work first."
    Write-Host "This does not force-terminate applications."
    $confirmation = Read-Host "Continue? [y/N]"
    if ($confirmation -cne 'y' -and $confirmation -cne 'Y') {
        Write-Host "No applications were asked to close."
        exit 0
    }

    $result = [FolderRestartManager]::RmShutdown($sessionHandle, 0, [IntPtr]::Zero)
    if ($result -ne 0) {
        throw "Windows could not close all listed applications (error $result). Save your work and close them manually."
    }

    Start-Sleep -Seconds 2
    $remaining = @(Get-AffectedProcesses $sessionHandle)
    if ($remaining.Count -gt 0) {
        Write-Host "Some applications are still using the project; close them manually:"
        foreach ($item in $remaining) {
            Write-Host ("  {0} (PID {1})" -f $item.ApplicationName, $item.Process.ProcessId)
        }
        exit 1
    }

    Write-Host "The listed applications were closed. You can try renaming the folder now."
}
finally {
    $result = [FolderRestartManager]::RmEndSession($sessionHandle)
    if ($result -ne 0) {
        Write-Warning "Could not cleanly end the Windows Restart Manager session (error $result)."
    }
}
