param(
    [Parameter(Mandatory = $true)]
    [string]$BatchPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace AllAppUpload -Name ConsoleWindow -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    public static extern System.IntPtr GetConsoleWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr handle, int command);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr SendMessage(System.IntPtr handle, int message, int wParam, int lParam);
'@
[IntPtr]$consoleWindow = [AllAppUpload.ConsoleWindow]::GetConsoleWindow()
if ($consoleWindow -ne [IntPtr]::Zero) {
    [void][AllAppUpload.ConsoleWindow]::ShowWindow($consoleWindow, 0)
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$projectRoot = Split-Path -Parent $BatchPath
$script:uploadDirectory = '.'
$repoConfig = Join-Path $env:LOCALAPPDATA 'AllApp\App-Debug-Upload.repository'
$repositoryUrl = 'https://github.com/jakirfile/allapp.git'
if (Test-Path -LiteralPath $repoConfig -PathType Leaf) {
    $savedRepositoryUrl = (Get-Content -LiteralPath $repoConfig -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($savedRepositoryUrl)) {
        $repositoryUrl = $savedRepositoryUrl
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AllApp - Debug APK Upload'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'None'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(620, 594)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-FormLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 540)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 22)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(47, 61, 77)
    $form.Controls.Add($label)
    return $label
}

function Add-FormTextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$ReadOnly = $false)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, 28)
    $box.ReadOnly = $ReadOnly
    $box.BorderStyle = 'FixedSingle'
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.Controls.Add($box)
    return $box
}

[void](Add-FormLabel 'GitHub repository URL' 26 24)
$repositoryBox = Add-FormTextBox $repositoryUrl 26 49 488

$copyRepositoryButton = New-Object System.Windows.Forms.Button
$copyRepositoryButton.Text = [char]0xE8C8
$copyRepositoryButton.Location = New-Object System.Drawing.Point(524, 47)
$copyRepositoryButton.Size = New-Object System.Drawing.Size(32, 32)
$copyRepositoryButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
$copyRepositoryButton.FlatStyle = 'System'
$form.Controls.Add($copyRepositoryButton)

$refreshRepositoryButton = New-Object System.Windows.Forms.Button
$refreshRepositoryButton.Text = [char]0xE72C
$refreshRepositoryButton.Location = New-Object System.Drawing.Point(562, 47)
$refreshRepositoryButton.Size = New-Object System.Drawing.Size(32, 32)
$refreshRepositoryButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
$refreshRepositoryButton.FlatStyle = 'System'
$form.Controls.Add($refreshRepositoryButton)

$repositoryToolTip = New-Object System.Windows.Forms.ToolTip
$repositoryToolTip.SetToolTip($copyRepositoryButton, 'Copy repository URL')
$repositoryToolTip.SetToolTip($refreshRepositoryButton, 'Reload saved repository URL')

[void](Add-FormLabel 'New GitHub URL or upload folder' 26 95)
$directoryBox = Add-FormTextBox '' 26 120 488
$updateLinksButton = New-Object System.Windows.Forms.Button
$updateLinksButton.Text = [char]0xE71B
$updateLinksButton.Location = New-Object System.Drawing.Point(562, 118)
$updateLinksButton.Size = New-Object System.Drawing.Size(32, 32)
$updateLinksButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
$updateLinksButton.FlatStyle = 'System'
$form.Controls.Add($updateLinksButton)
$repositoryToolTip.SetToolTip($updateLinksButton, 'Update app download and update links')

$directoryHint = New-Object System.Windows.Forms.Label
$directoryHint.Text = 'Current folder: repository root. Enter a GitHub URL or relative folder, then click the link icon.'
$directoryHint.Location = New-Object System.Drawing.Point(27, 151)
$directoryHint.Size = New-Object System.Drawing.Size(560, 22)
$directoryHint.ForeColor = [System.Drawing.Color]::FromArgb(103, 116, 131)
$form.Controls.Add($directoryHint)

[void](Add-FormLabel 'Upload preview' 26 187)
$previewBox = New-Object System.Windows.Forms.TextBox
$previewBox.Location = New-Object System.Drawing.Point(26, 212)
$previewBox.Size = New-Object System.Drawing.Size(568, 180)
$previewBox.Multiline = $true
$previewBox.ReadOnly = $true
$previewBox.ScrollBars = 'Vertical'
$previewBox.BorderStyle = 'FixedSingle'
$previewBox.BackColor = [System.Drawing.Color]::White
$previewBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($previewBox)

$warning = New-Object System.Windows.Forms.Label
$warning.Text = 'This upload replaces the entire repository. Only the selected folder will contain the uploaded files.'
$warning.Location = New-Object System.Drawing.Point(27, 404)
$warning.Size = New-Object System.Drawing.Size(566, 40)
$warning.ForeColor = [System.Drawing.Color]::FromArgb(156, 76, 20)
$warning.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$form.Controls.Add($warning)

$confirmBox = New-Object System.Windows.Forms.CheckBox
$confirmBox.Text = 'I understand that existing repository files will be replaced.'
$confirmBox.Location = New-Object System.Drawing.Point(26, 448)
$confirmBox.Size = New-Object System.Drawing.Size(568, 25)
$confirmBox.ForeColor = [System.Drawing.Color]::FromArgb(47, 61, 77)
$form.Controls.Add($confirmBox)

$script:uploadRunning = $false
$script:previewReady = $false
$script:uploadProcess = $null
$script:uploadLogPath = $null
$script:uploadStatusPath = $null

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready. No new APK build will be started.'
$statusLabel.Location = New-Object System.Drawing.Point(27, 514)
$statusLabel.Size = New-Object System.Drawing.Size(325, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(103, 116, 131)
$form.Controls.Add($statusLabel)

$previewButton = New-Object System.Windows.Forms.Button
$previewButton.Text = 'Refresh preview'
$previewButton.Location = New-Object System.Drawing.Point(364, 506)
$previewButton.Size = New-Object System.Drawing.Size(105, 34)
$previewButton.FlatStyle = 'System'
$form.Controls.Add($previewButton)

$uploadButton = New-Object System.Windows.Forms.Button
$uploadButton.Text = 'Upload'
$uploadButton.Location = New-Object System.Drawing.Point(480, 506)
$uploadButton.Size = New-Object System.Drawing.Size(114, 34)
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
$titleBar.Size = New-Object System.Drawing.Size(620, 32)
$titleBar.BackColor = [System.Drawing.SystemColors]::Control
$form.Controls.Add($titleBar)
$titleBar.BringToFront()

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'AllApp - Debug APK Upload'
$titleLabel.Location = New-Object System.Drawing.Point(10, 7)
$titleLabel.Size = New-Object System.Drawing.Size(390, 20)
$titleLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
$titleBar.Controls.Add($titleLabel)

$minimizeButton = New-Object System.Windows.Forms.Button
$minimizeButton.Text = [char]0xE921
$minimizeButton.Location = New-Object System.Drawing.Point(480, 0)
$minimizeButton.Size = New-Object System.Drawing.Size(46, 32)
$minimizeButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
$minimizeButton.FlatStyle = 'Flat'
$minimizeButton.FlatAppearance.BorderSize = 0
$minimizeButton.BackColor = [System.Drawing.SystemColors]::Control
$titleBar.Controls.Add($minimizeButton)

$restartButton = New-Object System.Windows.Forms.Button
$restartButton.Text = [char]0xE72C
$restartButton.Location = New-Object System.Drawing.Point(526, 0)
$restartButton.Size = New-Object System.Drawing.Size(46, 32)
$restartButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
$restartButton.FlatStyle = 'Flat'
$restartButton.FlatAppearance.BorderSize = 0
$restartButton.BackColor = [System.Drawing.SystemColors]::Control
$titleBar.Controls.Add($restartButton)
$repositoryToolTip.SetToolTip($restartButton, 'Restart this form')

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = [char]0xE8BB
$closeButton.Location = New-Object System.Drawing.Point(572, 0)
$closeButton.Size = New-Object System.Drawing.Size(48, 32)
$closeButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = [System.Drawing.SystemColors]::Control
$titleBar.Controls.Add($closeButton)

$titleBar.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [void][AllAppUpload.ConsoleWindow]::ReleaseCapture()
        [void][AllAppUpload.ConsoleWindow]::SendMessage($form.Handle, 0xA1, 2, 0)
    }
})
$titleLabel.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [void][AllAppUpload.ConsoleWindow]::ReleaseCapture()
        [void][AllAppUpload.ConsoleWindow]::SendMessage($form.Handle, 0xA1, 2, 0)
    }
})
$minimizeButton.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
$closeButton.Add_Click({ $form.Close() })

$confirmBox.Add_CheckedChanged({
    $uploadButton.Enabled = $confirmBox.Checked -and $script:previewReady -and -not $script:uploadRunning
})

function Update-UploadPreview {
    $previewButton.Enabled = $false
    $statusLabel.Text = 'Checking the existing APK and upload files...'
    $form.Refresh()
    try {
        $previewOutput = @(
            & (Join-Path $projectRoot 'Show-App-Debug-Upload-Preview.ps1') `
                -ApkPath (Join-Path $projectRoot 'app\build\outputs\apk\debug\app-debug.apk') `
                -ApkMetadataPath (Join-Path $projectRoot 'app\build\outputs\apk\debug\output-metadata.json') `
                -StringsPath (Join-Path $projectRoot 'app\src\main\res\values\strings.xml') `
                -ManifestPath (Join-Path $projectRoot 'update.json') `
                -IndexPath (Join-Path $projectRoot 'index.html') `
                -QrPath (Join-Path $projectRoot 'qr.png') `
                -UploadDirectory $script:uploadDirectory
        )
        $previewBox.Text = ($previewOutput -join [Environment]::NewLine).Replace('\', '/')
        $script:previewReady = $true
        $uploadButton.Enabled = $confirmBox.Checked -and -not $script:uploadRunning
        $statusLabel.Text = 'Preview ready. No files have been uploaded.'
    } catch {
        $script:previewReady = $false
        $previewBox.Text = $_.Exception.Message
        $uploadButton.Enabled = $false
        $statusLabel.Text = 'Preview failed. Fix the issue before uploading.'
    } finally {
        $previewButton.Enabled = -not $script:uploadRunning
    }
}

$previewButton.Add_Click({ Update-UploadPreview })
$restartButton.Add_Click({
    if ($script:uploadRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Wait for the upload to finish before restarting this form.',
            'Upload in progress',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    try {
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -BatchPath "{1}"' -f $PSCommandPath, $BatchPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden
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
$updateLinksButton.Add_Click({
    $oldRepositoryUrl = $env:APP_UPLOAD_REPOSITORY_URL
    $oldUploadDirectory = $env:UPLOAD_DIRECTORY
    $newValue = $directoryBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($newValue)) {
        $statusLabel.Text = 'Enter a GitHub URL or relative folder first.'
        return
    }

    $newRepositoryUrl = $repositoryBox.Text.Trim()
    $newUploadDirectory = $script:uploadDirectory
    if ($newValue -match '^https?://') {
        $newRepositoryUrl = $newValue
    } else {
        $newUploadDirectory = $newValue
    }

    $previewButton.Enabled = $false
    $updateLinksButton.Enabled = $false
    $restartButton.Enabled = $false
    $uploadButton.Enabled = $false
    $statusLabel.Text = 'Applying the new repository or folder...'
    $form.Refresh()
    try {
        $env:APP_UPLOAD_REPOSITORY_URL = $newRepositoryUrl
        $env:UPLOAD_DIRECTORY = $newUploadDirectory
        $validationResult = Join-Path ([IO.Path]::GetTempPath()) ('allapp-upload-form-' + [Guid]::NewGuid().ToString('N') + '.txt')
        & (Join-Path $projectRoot 'Set-App-Upload-Directory.ps1') `
            -ProjectRoot $projectRoot `
            -ResultPath $validationResult | Out-Null
        if (-not (Test-Path -LiteralPath $validationResult -PathType Leaf)) {
            throw 'Could not validate the selected repository and folder.'
        }
        $normalized = (Get-Content -LiteralPath $validationResult -Raw).Trim().Split('|')
        if ($normalized.Count -ne 5) {
            throw 'The validated destination returned an invalid result.'
        }
        $normalizedDirectory = $normalized[0]
        $normalizedRepositoryUrl = "https://github.com/$($normalized[2]).git"
        Remove-Item -LiteralPath $validationResult -Force

        $env:APP_UPLOAD_REPOSITORY_URL = $normalizedRepositoryUrl
        $env:UPLOAD_DIRECTORY = $normalizedDirectory
        & (Join-Path $projectRoot 'Set-App-Upload-Directory.ps1') `
            -ProjectRoot $projectRoot `
            -SaveRepositoryPreference `
            -Apply
        $repositoryBox.Text = $normalizedRepositoryUrl
        $script:uploadDirectory = $normalizedDirectory
        $directoryBox.Clear()
        $directoryHint.Text = if ($script:uploadDirectory -eq '.') {
            'Current folder: repository root. Enter a GitHub URL or relative folder, then click the link icon.'
        } else {
            "Current folder: $($script:uploadDirectory). Enter a GitHub URL or relative folder, then click the link icon."
        }
        Update-UploadPreview
        $statusLabel.Text = 'Destination updated. Input field cleared.'
    } catch {
        $script:previewReady = $false
        $uploadButton.Enabled = $false
        $statusLabel.Text = 'Could not apply the new repository or folder.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not apply the new repository or folder.`r`n$($_.Exception.Message)",
            'Destination update failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        if ($validationResult -and (Test-Path -LiteralPath $validationResult)) {
            Remove-Item -LiteralPath $validationResult -Force
        }
        $env:APP_UPLOAD_REPOSITORY_URL = $oldRepositoryUrl
        $env:UPLOAD_DIRECTORY = $oldUploadDirectory
        $previewButton.Enabled = -not $script:uploadRunning
        $updateLinksButton.Enabled = -not $script:uploadRunning
    }
})
$copyRepositoryButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($repositoryBox.Text)) {
        $statusLabel.Text = 'Enter a GitHub repository URL before copying.'
        return
    }
    try {
        [System.Windows.Forms.Clipboard]::SetText($repositoryBox.Text.Trim())
        $statusLabel.Text = 'Repository URL copied.'
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not copy the repository URL.`r`n$($_.Exception.Message)",
            'Copy failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})
$refreshRepositoryButton.Add_Click({
    try {
        $repositoryBox.Text = 'https://github.com/jakirfile/allapp.git'
        if (Test-Path -LiteralPath $repoConfig -PathType Leaf) {
            $savedRepositoryUrl = (Get-Content -LiteralPath $repoConfig -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($savedRepositoryUrl)) {
                $repositoryBox.Text = $savedRepositoryUrl
            }
        }
        Update-UploadPreview
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not reload the saved repository URL.`r`n$($_.Exception.Message)",
            'Refresh failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})
$form.Add_FormClosed({
    $repositoryToolTip.Dispose()
})
$directoryBox.Add_TextChanged({
    if (-not [string]::IsNullOrWhiteSpace($directoryBox.Text)) {
        $script:previewReady = $false
        $uploadButton.Enabled = $false
        $statusLabel.Text = 'Click the link icon to apply the new repository or folder.'
    }
})
$repositoryBox.Add_TextChanged({
    $script:previewReady = $false
    $uploadButton.Enabled = $false
    $statusLabel.Text = 'Refresh the preview after changing the repository URL.'
})

$uploadButton.Add_Click({
    $validationResult = Join-Path ([IO.Path]::GetTempPath()) ('allapp-upload-form-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $oldRepositoryUrl = $env:APP_UPLOAD_REPOSITORY_URL
    $oldUploadDirectory = $env:UPLOAD_DIRECTORY
    try {
        $env:APP_UPLOAD_REPOSITORY_URL = $repositoryBox.Text.Trim()
        $env:UPLOAD_DIRECTORY = $script:uploadDirectory
        & (Join-Path $projectRoot 'Set-App-Upload-Directory.ps1') `
            -ProjectRoot $projectRoot `
            -ResultPath $validationResult | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Check upload destination',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    } finally {
        $env:APP_UPLOAD_REPOSITORY_URL = $oldRepositoryUrl
        $env:UPLOAD_DIRECTORY = $oldUploadDirectory
        if (Test-Path -LiteralPath $validationResult) {
            Remove-Item -LiteralPath $validationResult -Force
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $script:uploadLogPath = Join-Path ([IO.Path]::GetTempPath()) ('allapp-upload-' + [Guid]::NewGuid().ToString('N') + '.log')
    $script:uploadStatusPath = Join-Path ([IO.Path]::GetTempPath()) ('allapp-upload-status-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($script:uploadStatusPath, 'Starting upload...')
    $startInfo.Arguments = '/d /c ""{0}" > "{1}" 2>&1"' -f $BatchPath, $script:uploadLogPath
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.EnvironmentVariables['APP_UPLOAD_FORM_MODE'] = '1'
    $startInfo.EnvironmentVariables['APP_UPLOAD_REPOSITORY_URL'] = $repositoryBox.Text.Trim()
    $startInfo.EnvironmentVariables['APP_UPLOAD_DIRECTORY'] = $script:uploadDirectory
    $startInfo.EnvironmentVariables['APP_UPLOAD_STATUS_PATH'] = $script:uploadStatusPath

    try {
        $script:uploadProcess = [System.Diagnostics.Process]::Start($startInfo)
    } catch {
        if ($script:uploadLogPath -and (Test-Path -LiteralPath $script:uploadLogPath)) {
            Remove-Item -LiteralPath $script:uploadLogPath -Force
        }
        if ($script:uploadStatusPath -and (Test-Path -LiteralPath $script:uploadStatusPath)) {
            Remove-Item -LiteralPath $script:uploadStatusPath -Force
        }
        $script:uploadLogPath = $null
        $script:uploadStatusPath = $null
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not start the upload process.`r`n$($_.Exception.Message)",
            'Upload could not start',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $script:uploadRunning = $true
    $uploadButton.Enabled = $false
    $previewButton.Enabled = $false
    $updateLinksButton.Enabled = $false
    $repositoryBox.Enabled = $false
    $directoryBox.Enabled = $false
    $confirmBox.Enabled = $false
    $statusLabel.Text = 'Upload is running in the background...'
    $timer.Start()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($script:uploadProcess -and $script:uploadProcess.HasExited) {
        $timer.Stop()
        $exitCode = $script:uploadProcess.ExitCode
        $script:uploadProcess.Dispose()
        $script:uploadProcess = $null
        $uploadLog = ''
        try {
            if (Test-Path -LiteralPath $script:uploadLogPath -PathType Leaf) {
                $uploadLog = Get-Content -LiteralPath $script:uploadLogPath -Raw
            }
        } catch {
            $uploadLog = "Could not read the upload log: $($_.Exception.Message)"
        } finally {
            if (Test-Path -LiteralPath $script:uploadLogPath) {
                Remove-Item -LiteralPath $script:uploadLogPath -Force
            }
            $script:uploadLogPath = $null
            if (Test-Path -LiteralPath $script:uploadStatusPath) {
                Remove-Item -LiteralPath $script:uploadStatusPath -Force
            }
            $script:uploadStatusPath = $null
        }
        $script:uploadRunning = $false
        $repositoryBox.Enabled = $true
        $directoryBox.Enabled = $true
        $confirmBox.Enabled = $true
        $previewButton.Enabled = $true
        $updateLinksButton.Enabled = $true
        $restartButton.Enabled = $true
        $uploadButton.Enabled = $confirmBox.Checked -and $script:previewReady
        if ($exitCode -eq 0) {
            $statusLabel.Text = 'Success: upload completed successfully.'
        } else {
            $statusLabel.Text = "Upload failed (exit code $exitCode)."
            if ($uploadLog.Length -gt 12000) {
                $uploadLog = $uploadLog.Substring($uploadLog.Length - 12000)
            }
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "The background upload failed.`r`n`r`n$uploadLog",
                'Upload failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    } elseif ($script:uploadProcess -and $script:uploadStatusPath) {
        try {
            if (Test-Path -LiteralPath $script:uploadStatusPath -PathType Leaf) {
                $progress = (Get-Content -LiteralPath $script:uploadStatusPath -Raw).Trim()
                if (-not [string]::IsNullOrWhiteSpace($progress)) {
                    $statusLabel.Text = $progress
                }
            }
        } catch {
            $statusLabel.Text = "Upload is running; progress unavailable: $($_.Exception.Message)"
        }
    }
})

$form.Add_Shown({ Update-UploadPreview })
[void]$form.ShowDialog()
