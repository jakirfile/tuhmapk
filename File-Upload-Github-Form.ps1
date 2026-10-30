param(
    [Parameter(Mandatory = $true)]
    [string]$BatchPath
)

$ErrorActionPreference = 'Stop'
trap {
    $startupError = $_.Exception.ToString()
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "The GitHub upload form could not start.`r`n`r`n$startupError",
            'Form startup failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        [Console]::Error.WriteLine($startupError)
        [Console]::Error.WriteLine($_.Exception.Message)
        [void][Console]::ReadKey($true)
    }
    exit 1
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace AllAppFileUpload -Name ConsoleWindow -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    public static extern System.IntPtr GetConsoleWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr handle, int command);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr SendMessage(System.IntPtr handle, int message, int wParam, int lParam);
'@
[IntPtr]$consoleWindow = [AllAppFileUpload.ConsoleWindow]::GetConsoleWindow()
if ($consoleWindow -ne [IntPtr]::Zero) {
    [void][AllAppFileUpload.ConsoleWindow]::ShowWindow($consoleWindow, 0)
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$projectRoot = Split-Path -Parent $BatchPath
$repoConfig = Join-Path $env:LOCALAPPDATA 'AllApp\File-Upload-Github.repository'
$repositoryUrl = 'https://github.com/jakirfile/AllApp-Android-Source.git'
if (Test-Path -LiteralPath $repoConfig -PathType Leaf) {
    $savedUrl = (Get-Content -LiteralPath $repoConfig -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($savedUrl)) { $repositoryUrl = $savedUrl }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AllApp - GitHub File Upload'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.FormBorderStyle = 'None'
$form.MinimizeBox = $false
$form.ShowInTaskbar = $true
$form.ClientSize = New-Object System.Drawing.Size(800, 602)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-FormLabel([string]$Text, [int]$X, [int]$Y, [int]$Width = 720, [int]$Height = 22) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(47, 61, 77)
    $form.Controls.Add($label)
    return $label
}

function Add-FormTextBox([string]$Text, [int]$X, [int]$Y, [int]$Width) {
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, 30)
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $box.BorderStyle = 'FixedSingle'
    $form.Controls.Add($box)
    return $box
}

[void](Add-FormLabel 'GitHub repository URL' 28 12)
$repositoryBox = Add-FormTextBox $repositoryUrl 28 36 650

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = [char]0xE8C8
$copyButton.Location = New-Object System.Drawing.Point(688, 34)
$copyButton.Size = New-Object System.Drawing.Size(36, 34)
$copyButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
$form.Controls.Add($copyButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = [char]0xE72C
$refreshButton.Location = New-Object System.Drawing.Point(732, 34)
$refreshButton.Size = New-Object System.Drawing.Size(36, 34)
$refreshButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
$form.Controls.Add($refreshButton)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($copyButton, 'Copy repository URL')
$toolTip.SetToolTip($refreshButton, 'Reload the last uploaded repository')

[void](Add-FormLabel 'New GitHub repository URL' 28 76)
$newRepositoryBox = Add-FormTextBox '' 28 100 650
$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = [char]0xE71B
$applyButton.Location = New-Object System.Drawing.Point(732, 98)
$applyButton.Size = New-Object System.Drawing.Size(36, 34)
$applyButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
$form.Controls.Add($applyButton)
$toolTip.SetToolTip($applyButton, 'Apply repository URL')

$hintLabel = Add-FormLabel "Source folder: $projectRoot. Uploading replaces the files on the selected main branch." 29 132 738

[void](Add-FormLabel 'Upload preview' 28 158)
$previewBox = New-Object System.Windows.Forms.TextBox
$previewBox.Location = New-Object System.Drawing.Point(28, 182)
$previewBox.Size = New-Object System.Drawing.Size(740, 230)
$previewBox.Multiline = $true
$previewBox.ReadOnly = $true
$previewBox.ScrollBars = 'Vertical'
$previewBox.BorderStyle = 'FixedSingle'
$previewBox.BackColor = [System.Drawing.Color]::White
$previewBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($previewBox)

$warning = Add-FormLabel 'This upload replaces all files on the GitHub main branch. Files found only on GitHub will be removed; commit history is kept.' 29 420 738 38
$warning.ForeColor = [System.Drawing.Color]::FromArgb(156, 76, 20)
$warning.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)

$confirmBox = New-Object System.Windows.Forms.CheckBox
$confirmBox.Text = 'I understand that existing repository files will be replaced.'
$confirmBox.Location = New-Object System.Drawing.Point(28, 462)
$confirmBox.Size = New-Object System.Drawing.Size(740, 25)
$confirmBox.ForeColor = [System.Drawing.Color]::FromArgb(47, 61, 77)
$form.Controls.Add($confirmBox)

$statusLabel = Add-FormLabel 'Ready. No files have been uploaded.' 29 516 420 24
$previewButton = New-Object System.Windows.Forms.Button
$previewButton.Text = 'Refresh preview'
$previewButton.Location = New-Object System.Drawing.Point(482, 506)
$previewButton.Size = New-Object System.Drawing.Size(126, 36)
$form.Controls.Add($previewButton)

$uploadButton = New-Object System.Windows.Forms.Button
$uploadButton.Text = 'Upload'
$uploadButton.Location = New-Object System.Drawing.Point(620, 506)
$uploadButton.Size = New-Object System.Drawing.Size(148, 36)
$uploadButton.Enabled = $false
$uploadButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 177)
$uploadButton.ForeColor = [System.Drawing.Color]::White
$uploadButton.FlatStyle = 'Flat'
$form.Controls.Add($uploadButton)

foreach ($control in @($form.Controls)) {
    $control.Top += 32
}

$titleBar = New-Object System.Windows.Forms.Panel
$titleBar.Location = New-Object System.Drawing.Point(0, 0)
$titleBar.Size = New-Object System.Drawing.Size(800, 32)
$titleBar.BackColor = [System.Drawing.SystemColors]::Control
$form.Controls.Add($titleBar)
$titleBar.BringToFront()

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'AllApp - GitHub File Upload'
$titleLabel.Location = New-Object System.Drawing.Point(10, 7)
$titleLabel.Size = New-Object System.Drawing.Size(620, 20)
$titleBar.Controls.Add($titleLabel)

$minimizeButton = New-Object System.Windows.Forms.Button
$minimizeButton.Text = [char]0xE921
$minimizeButton.Location = New-Object System.Drawing.Point(680, 0)
$minimizeButton.Size = New-Object System.Drawing.Size(40, 32)
$minimizeButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
$minimizeButton.FlatStyle = 'Flat'
$minimizeButton.FlatAppearance.BorderSize = 0
$minimizeButton.BackColor = [System.Drawing.SystemColors]::Control
$titleBar.Controls.Add($minimizeButton)

$restartButton = New-Object System.Windows.Forms.Button
$restartButton.Text = [char]0xE72C
$restartButton.Location = New-Object System.Drawing.Point(720, 0)
$restartButton.Size = New-Object System.Drawing.Size(40, 32)
$restartButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
$restartButton.FlatStyle = 'Flat'
$restartButton.FlatAppearance.BorderSize = 0
$restartButton.BackColor = [System.Drawing.SystemColors]::Control
$titleBar.Controls.Add($restartButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = [char]0xE8BB
$closeButton.Location = New-Object System.Drawing.Point(760, 0)
$closeButton.Size = New-Object System.Drawing.Size(40, 32)
$closeButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = [System.Drawing.SystemColors]::Control
$titleBar.Controls.Add($closeButton)

$script:previewReady = $false
$script:uploadRunning = $false
$script:uploadProcess = $null
$script:uploadLogPath = $null
$script:uploadStatusPath = $null
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

function Normalize-RepositoryUrl([string]$Value) {
    $uri = $null
    if (
        -not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https', 'http') -or
        $uri.Host -ine 'github.com' -or
        $uri.Query -or $uri.Fragment -or $uri.UserInfo
    ) {
        throw 'Enter a GitHub repository URL such as https://github.com/owner/repository.'
    }
    $segments = @($uri.AbsolutePath.Trim('/') -split '/')
    if ($segments.Count -ne 2 -or $segments[0] -notmatch '^[A-Za-z0-9-]+$' -or $segments[1] -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'The URL must point directly to a GitHub repository (owner/repository), not a folder or file.'
    }
    $repo = $segments[1] -replace '\.git$', ''
    if ([string]::IsNullOrWhiteSpace($repo)) { throw 'Enter a valid GitHub repository name.' }
    return "https://github.com/$($segments[0])/$repo.git"
}

function Update-UploadPreview {
    try {
        $normalized = Normalize-RepositoryUrl $repositoryBox.Text
        $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
        $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
        $pendingDirectories.Push($projectRoot)
        while ($pendingDirectories.Count -gt 0) {
            $currentDirectory = $pendingDirectories.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop) {
                if ($item.PSIsContainer) {
                    if ($item.Name -ne '.git' -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        $pendingDirectories.Push($item.FullName)
                    }
                } else {
                    $files.Add($item)
                }
            }
        }
        $files = @($files | Sort-Object FullName)
        $lines = @(
            "Repository: $($normalized -replace '\.git$', '')",
            'Branch: main',
            "Source folder: $projectRoot",
            "Files to upload: $($files.Count)",
            ''
        )
        $shownFiles = $files | Select-Object -First 250
        foreach ($file in $shownFiles) {
            $relative = $file.FullName.Substring($projectRoot.TrimEnd('\', '/').Length).TrimStart('\', '/')
            $lines += "  $relative"
        }
        if ($files.Count -gt $shownFiles.Count) {
            $lines += "  ... and $($files.Count - $shownFiles.Count) more files"
        }
        $previewBox.Text = $lines -join [Environment]::NewLine
        $script:previewReady = $true
        $statusLabel.Text = 'Preview ready. No files have been uploaded.'
        $uploadButton.Enabled = $confirmBox.Checked -and -not $script:uploadRunning
    } catch {
        $script:previewReady = $false
        $previewBox.Text = $_.Exception.Message
        $statusLabel.Text = 'Preview failed. Correct the repository URL before uploading.'
        $uploadButton.Enabled = $false
    }
}

$repositoryBox.Add_TextChanged({
    $script:previewReady = $false
    $uploadButton.Enabled = $false
    $statusLabel.Text = 'Refresh the preview after changing the repository URL.'
})
$confirmBox.Add_CheckedChanged({
    $uploadButton.Enabled = $confirmBox.Checked -and $script:previewReady -and -not $script:uploadRunning
})
$previewButton.Add_Click({ Update-UploadPreview })
$refreshButton.Add_Click({
    try {
        $repositoryBox.Text = 'https://github.com/jakirfile/AllApp-Android-Source.git'
        if (Test-Path -LiteralPath $repoConfig -PathType Leaf) {
            $savedUrl = (Get-Content -LiteralPath $repoConfig -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($savedUrl)) { $repositoryBox.Text = $savedUrl }
        }
        Update-UploadPreview
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Refresh failed') | Out-Null
    }
})
$copyButton.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText($repositoryBox.Text.Trim())
        $statusLabel.Text = 'Repository URL copied.'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "Could not copy repository URL.`r`n$($_.Exception.Message)", 'Copy failed') | Out-Null
    }
})
$minimizeButton.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
$closeButton.Add_Click({ $form.Close() })
$restartButton.Add_Click({
    if ($script:uploadRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Wait for the upload to finish before restarting the form.',
            'Upload in progress',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    try {
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -BatchPath "{1}"' -f $PSCommandPath, $BatchPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $projectRoot
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not restart the form.`r`n$($_.Exception.Message)",
            'Restart failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})
$titleBar.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [void][AllAppFileUpload.ConsoleWindow]::ReleaseCapture()
        [void][AllAppFileUpload.ConsoleWindow]::SendMessage($form.Handle, 0xA1, 2, 0)
    }
})
$titleLabel.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [void][AllAppFileUpload.ConsoleWindow]::ReleaseCapture()
        [void][AllAppFileUpload.ConsoleWindow]::SendMessage($form.Handle, 0xA1, 2, 0)
    }
})
$applyButton.Add_Click({
    try {
        $repositoryBox.Text = Normalize-RepositoryUrl $newRepositoryBox.Text
        $newRepositoryBox.Clear()
        Update-UploadPreview
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Invalid repository URL') | Out-Null
    }
})

$uploadButton.Add_Click({
    try {
        $normalized = Normalize-RepositoryUrl $repositoryBox.Text
        if (-not $confirmBox.Checked -or -not $script:previewReady) { return }
        $script:uploadLogPath = Join-Path ([IO.Path]::GetTempPath()) ('allapp-file-upload-' + [guid]::NewGuid().ToString('N') + '.log')
        $script:uploadStatusPath = Join-Path ([IO.Path]::GetTempPath()) ('allapp-file-upload-status-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($script:uploadStatusPath, 'Starting upload...')
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /c ""{0}" > "{1}" 2>&1"' -f $BatchPath, $script:uploadLogPath
        $startInfo.WorkingDirectory = $projectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.EnvironmentVariables['FILE_UPLOAD_FORM_MODE'] = '1'
        $startInfo.EnvironmentVariables['FILE_UPLOAD_REPOSITORY_URL'] = $normalized
        $startInfo.EnvironmentVariables['FILE_UPLOAD_STATUS_PATH'] = $script:uploadStatusPath
        $script:uploadProcess = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $script:uploadProcess) { throw 'The upload process could not be started.' }
        $script:uploadRunning = $true
        $uploadButton.Enabled = $false
        $previewButton.Enabled = $false
        $applyButton.Enabled = $false
        $copyButton.Enabled = $false
        $refreshButton.Enabled = $false
        $repositoryBox.Enabled = $false
        $newRepositoryBox.Enabled = $false
        $confirmBox.Enabled = $false
        $statusLabel.Text = 'Connecting to GitHub repository...'
        $timer.Start()
    } catch {
        foreach ($temporaryPath in @($script:uploadLogPath, $script:uploadStatusPath)) {
            if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
        $script:uploadLogPath = $null
        $script:uploadStatusPath = $null
        [System.Windows.Forms.MessageBox]::Show($form, "Could not start upload.`r`n$($_.Exception.Message)", 'Upload could not start') | Out-Null
    }
})

$timer.Add_Tick({
    if ($script:uploadProcess -and $script:uploadProcess.HasExited) {
        $timer.Stop()
        $exitCode = $script:uploadProcess.ExitCode
        $script:uploadProcess.Dispose()
        $script:uploadProcess = $null
        $log = ''
        try {
            if (Test-Path -LiteralPath $script:uploadLogPath) { $log = Get-Content -LiteralPath $script:uploadLogPath -Raw }
        } finally {
            if (Test-Path -LiteralPath $script:uploadLogPath) { Remove-Item -LiteralPath $script:uploadLogPath -Force }
            if (Test-Path -LiteralPath $script:uploadStatusPath) { Remove-Item -LiteralPath $script:uploadStatusPath -Force }
            $script:uploadLogPath = $null
            $script:uploadStatusPath = $null
        }
        $script:uploadRunning = $false
        $previewButton.Enabled = $true
        $applyButton.Enabled = $true
        $copyButton.Enabled = $true
        $refreshButton.Enabled = $true
        $repositoryBox.Enabled = $true
        $newRepositoryBox.Enabled = $true
        $confirmBox.Enabled = $true
        $uploadButton.Enabled = $confirmBox.Checked -and $script:previewReady
        if ($exitCode -eq 0) {
            $statusLabel.Text = 'Success: all project files uploaded to GitHub.'
        } else {
            $statusLabel.Text = "Upload failed (exit code $exitCode)."
            if ($log.Length -gt 12000) { $log = $log.Substring($log.Length - 12000) }
            [System.Windows.Forms.MessageBox]::Show($form, "The upload failed.`r`n`r`n$log", 'Upload failed') | Out-Null
        }
    } elseif ($script:uploadProcess -and $script:uploadStatusPath) {
        try {
            if (Test-Path -LiteralPath $script:uploadStatusPath -PathType Leaf) {
                $progress = (Get-Content -LiteralPath $script:uploadStatusPath -Raw).Trim()
                if (-not [string]::IsNullOrWhiteSpace($progress)) { $statusLabel.Text = $progress }
            }
        } catch {
            $statusLabel.Text = "Upload is running; progress unavailable: $($_.Exception.Message)"
        }
    }
})

$previewStartupTimer = New-Object System.Windows.Forms.Timer
$previewStartupTimer.Interval = 100
$previewStartupTimer.Add_Tick({
    $previewStartupTimer.Stop()
    Update-UploadPreview
})
$form.Add_Shown({
    $form.Activate()
    $previewStartupTimer.Start()
})
$form.Add_FormClosed({
    $previewStartupTimer.Dispose()
    $timer.Dispose()
    $toolTip.Dispose()
})
[void]$form.ShowDialog()
