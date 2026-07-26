#Requires -Version 5.1
<#
.SYNOPSIS
    GUI PowerShell tool to sync a Cryptomator vault to any cloud storage exposed
    via SFTP or WebDAV, using rclone. Also supports reverse download (restore)
    and an optional local USB backup.

.DESCRIPTION
    Provider-independent: works with any storage that exposes SFTP access (a
    VPS, a NAS, a storage box) or WebDAV (Nextcloud/ownCloud or other
    WebDAV-compatible services).

    Single-file build. UI strings are localized via JSON files under .\lang
    (default: en.json). No personal data or provider-specific reference is
    baked into the code: all configuration is entered at runtime and saved
    only locally under %APPDATA%\CloudVaultSync.

.NOTES
    License: MIT (see LICENSE)
#>

# Application version, shown in the main window title.
$ScriptVersion = "1.0.0"

# Project root, used to locate the lang/ folder.
$AppRoot = $PSScriptRoot

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppDataDir  = Join-Path $env:APPDATA "CloudVaultSync"
$ConfigPath  = Join-Path $AppDataDir "config.json"
$RcloneDir   = Join-Path $AppDataDir "rclone"
$RclonePath  = Join-Path $RcloneDir "rclone.exe"
$LogPath     = Join-Path $AppDataDir "sync-log.txt"
$LangDir     = Join-Path $AppRoot "lang"
$DefaultLanguage = "en"

if (-not (Test-Path $AppDataDir)) {
    New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
}

function Get-Config {
    if (Test-Path $ConfigPath) {
        return Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Get-Strings {
    param([string]$LanguageCode)

    $path = Join-Path $LangDir "$LanguageCode.json"
    if (-not (Test-Path $path)) {
        $path = Join-Path $LangDir "$DefaultLanguage.json"
    }
    if (-not (Test-Path $path)) {
        throw "Language file not found: $path"
    }
    return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Format-Str {
    param([string]$Template, [object[]]$Values)
    return ($Template -f $Values)
}

function Get-SiteCertificateInfo {
    param([string]$Url)

    $script:capturedCert = $null
    $originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($senderObj, $certificate, $chain, $sslPolicyErrors)
        $script:capturedCert = $certificate
        return $true
    }

    try {
        Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # A HEAD request may be rejected by the server, but the TLS handshake
        # (and therefore the certificate callback above) has already happened
        # by that point regardless of the HTTP-level outcome.
    }
    finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
    }

    return $script:capturedCert
}

function Confirm-RcloneDownload {
    $downloadUrl = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    $cert = Get-SiteCertificateInfo -Url "https://downloads.rclone.org"

    if ($cert) {
        $certDetails = Format-Str $Strings.LabelCertDetails @(
            $cert.Subject, $cert.Issuer, $cert.GetExpirationDateString(), $cert.GetCertHashString()
        )
    } else {
        $certDetails = $Strings.LabelCertUnavailable
    }

    $message = Format-Str $Strings.MsgRcloneConfirmDownload @($downloadUrl, $certDetails)
    $result = [System.Windows.Forms.MessageBox]::Show($message, $Strings.MsgRcloneNotFoundTitle, "YesNo", "Question")
    return ($result -eq "Yes")
}

function Ensure-Rclone {
    param([System.Windows.Forms.TextBox]$LogBox)

    if (Test-Path $RclonePath) {
        return $true
    }

    if (-not (Confirm-RcloneDownload)) {
        Append-Log $LogBox $Strings.LogRcloneDownloadDeclined
        return $false
    }

    Append-Log $LogBox $Strings.LogRcloneMissing

    try {
        $zipUrl  = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
        $zipPath = Join-Path $env:TEMP "rclone-download.zip"

        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        $extractDir = Join-Path $env:TEMP "rclone-extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        $exeFound = Get-ChildItem -Path $extractDir -Filter "rclone.exe" -Recurse | Select-Object -First 1
        if (-not $exeFound) {
            Append-Log $LogBox $Strings.LogRcloneExtractError
            return $false
        }

        New-Item -ItemType Directory -Path $RcloneDir -Force | Out-Null
        Copy-Item $exeFound.FullName -Destination $RclonePath -Force

        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

        Append-Log $LogBox (Format-Str $Strings.LogRcloneDownloaded @($RclonePath))
        return $true
    }
    catch {
        Append-Log $LogBox (Format-Str $Strings.LogRcloneDownloadError @($_.Exception.Message))
        Append-Log $LogBox $Strings.LogRcloneManual
        return $false
    }
}

# ============================================================
# RCLONE: non-interactive remote creation (SFTP or WebDAV)
# ============================================================

function New-RcloneRemote {
    param($cfg, [System.Windows.Forms.TextBox]$LogBox)

    Append-Log $LogBox (Format-Str $Strings.LogConfiguringRemote @($cfg.RemoteName, $cfg.Protocol))

    & $RclonePath config delete $cfg.RemoteName 2>$null | Out-Null

    if ($cfg.Protocol -eq "SFTP") {
        $rcloneArgs = @(
            "config", "create", $cfg.RemoteName, "sftp",
            "host=$($cfg.SftpHost)",
            "user=$($cfg.SftpUser)",
            "port=$($cfg.SftpPort)"
        )

        $usesKey = $cfg.SshKeyFile -and (Test-Path $cfg.SshKeyFile)

        if ($usesKey) {
            $rcloneArgs += "key_file=$($cfg.SshKeyFile)"
            if ($cfg.KnownHostsFile) {
                $rcloneArgs += "known_hosts_file=$($cfg.KnownHostsFile)"
            }
            # If the private key is passphrase-protected, rclone needs it via
            # key_file_pass, which must be stored obscured. We obscure it up
            # front so it never lands in the config in clear text.
            if (-not [string]::IsNullOrWhiteSpace($cfg.SshKeyPassphrase)) {
                $obscured = (& $RclonePath obscure $cfg.SshKeyPassphrase 2>&1 | Select-Object -First 1)
                $rcloneArgs += "key_file_pass=$obscured"
            }
            $result = & $RclonePath @rcloneArgs 2>&1
        }
        else {
            $rcloneArgs += "pass=$($cfg.SftpPassword)"
            if ($cfg.KnownHostsFile) {
                $rcloneArgs += "known_hosts_file=$($cfg.KnownHostsFile)"
            }
            $rcloneArgs += "--obscure"
            $result = & $RclonePath @rcloneArgs 2>&1
        }
    }
    else {
        $rcloneArgs = @(
            "config", "create", $cfg.RemoteName, "webdav",
            "url=$($cfg.WebDavUrl)",
            "vendor=$($cfg.WebDavVendor)",
            "user=$($cfg.WebDavUser)",
            "pass=$($cfg.WebDavPassword)",
            "--obscure"
        )
        $result = & $RclonePath @rcloneArgs 2>&1
    }

    Append-Log $LogBox ($result -join "`n")

    if ($LASTEXITCODE -eq 0) {
        Append-Log $LogBox $Strings.LogRemoteOk
        return $true
    } else {
        Append-Log $LogBox $Strings.LogRemoteError
        return $false
    }
}

function Test-RcloneConnection {
    param($cfg, [System.Windows.Forms.TextBox]$LogBox)

    Append-Log $LogBox (Format-Str $Strings.LogTestConnection @($cfg.RemoteName))
    $result = & $RclonePath lsd "$($cfg.RemoteName):" 2>&1
    Append-Log $LogBox ($result -join "`n")

    if ($LASTEXITCODE -eq 0) {
        Append-Log $LogBox $Strings.LogConnectionOk
        return $true
    } else {
        Append-Log $LogBox $Strings.LogConnectionError
        return $false
    }
}

# ============================================================
# LOG UTILITY
# ============================================================

function Append-Log {
    param([System.Windows.Forms.TextBox]$LogBox, [string]$Text)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Text"

    if ($LogBox) {
        $LogBox.AppendText("$line`r`n")
        $LogBox.ScrollToCaret()
    }
    Add-Content -Path $LogPath -Value $line
    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================
# RCLONE: execution in a separate console window
# ============================================================
#
# Windows PowerShell 5.1 has a long-standing issue: merging a native command's
# stdout/stderr with 2>&1 (or redirecting to a file and tailing it) can lag or
# buffer unpredictably. The reliable fix is to not go through PowerShell's
# pipeline at all: rclone runs in its own native console window, so what you
# see is exactly what rclone itself is writing to the terminal, with zero
# intermediary. The trade-off is that this output can't be parsed or shown
# inside the app's own log box -- only a start/end marker is logged there.
#
# The window is kept open after rclone exits (via a "pause" in a small
# generated batch file) so the final summary can be read before it closes;
# the app waits for that window to close before returning control to the GUI.

function ConvertTo-ArgString {
    param([string[]]$Items)
    return ($Items | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-RcloneConsole {
    param([string[]]$RcloneArgs)

    $argString = ConvertTo-ArgString $RcloneArgs
    $batchPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".bat")

    $batchContent = @"
@echo off
"$RclonePath" $argString
echo.
echo $($Strings.MsgPressKeyToReturn)
pause >nul
"@
    Set-Content -Path $batchPath -Value $batchContent -Encoding ASCII

    try {
        $proc = Start-Process -FilePath $batchPath -PassThru

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.Application]::DoEvents()
        }

        return $proc.ExitCode
    }
    finally {
        Remove-Item $batchPath -Force -ErrorAction SilentlyContinue
    }
}


function Show-SetupForm {
    param($existingCfg)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Strings.SetupTitle
    $form.Size = New-Object System.Drawing.Size(560, 820)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.AutoScroll = $true

    $script:inputs = @{}
    $script:groups = @{}   # group name -> list of controls (for show/hide)
    $script:y = 15

    function Register-InGroup($group, $control) {
        if ($group) {
            if (-not $script:groups.ContainsKey($group)) {
                $script:groups[$group] = New-Object System.Collections.Generic.List[object]
            }
            $script:groups[$group].Add($control)
        }
    }

    function Add-SectionLabel($text, $group) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $text
        $lbl.Location = New-Object System.Drawing.Point(15, $script:y)
        $lbl.Size = New-Object System.Drawing.Size(510, 18)
        $lbl.Font = New-Object System.Drawing.Font($lbl.Font, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($lbl)
        Register-InGroup $group $lbl
        $script:y += 22
    }

    function Add-TextField($name, $labelText, $default, [switch]$Password, $group) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText
        $lbl.Location = New-Object System.Drawing.Point(15, $script:y)
        $lbl.Size = New-Object System.Drawing.Size(510, 18)
        $form.Controls.Add($lbl)
        Register-InGroup $group $lbl
        $script:y += 20

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(15, $script:y)
        $txt.Size = New-Object System.Drawing.Size(510, 22)
        if ($Password) { $txt.PasswordChar = '*' }

        $currentValue = $default
        if ($existingCfg -and $existingCfg.PSObject.Properties.Name -contains $name) {
            $currentValue = $existingCfg.$name
        }
        $txt.Text = $currentValue

        $form.Controls.Add($txt)
        Register-InGroup $group $txt
        $script:inputs[$name] = $txt
        $script:y += 32
    }

    function Add-CheckboxField($name, $labelText, [bool]$default) {
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = $labelText
        $chk.Location = New-Object System.Drawing.Point(15, $script:y)
        $chk.Size = New-Object System.Drawing.Size(510, 22)

        $currentValue = $default
        if ($existingCfg -and $existingCfg.PSObject.Properties.Name -contains $name) {
            $currentValue = [bool]$existingCfg.$name
        }
        $chk.Checked = $currentValue

        $form.Controls.Add($chk)
        $script:inputs[$name] = $chk
        $script:y += 28
    }

    # --- Language selector ---
    $lblLang = New-Object System.Windows.Forms.Label
    $lblLang.Text = $Strings.LabelLanguage
    $lblLang.Location = New-Object System.Drawing.Point(15, $script:y)
    $lblLang.Size = New-Object System.Drawing.Size(510, 18)
    $form.Controls.Add($lblLang)
    $script:y += 20

    $comboLang = New-Object System.Windows.Forms.ComboBox
    $comboLang.Location = New-Object System.Drawing.Point(15, $script:y)
    $comboLang.Size = New-Object System.Drawing.Size(510, 24)
    $comboLang.DropDownStyle = "DropDownList"
    $availableLangs = Get-ChildItem -Path $LangDir -Filter "*.json" | ForEach-Object { $_.BaseName }
    foreach ($l in $availableLangs) { [void]$comboLang.Items.Add($l) }
    $selectedLang = $DefaultLanguage
    if ($existingCfg -and $existingCfg.Language) { $selectedLang = $existingCfg.Language }
    $idx = $comboLang.Items.IndexOf($selectedLang)
    $comboLang.SelectedIndex = [Math]::Max($idx, 0)
    $form.Controls.Add($comboLang)
    $script:inputs["Language"] = $comboLang
    $script:y += 34

    # --- Remote name ---
    Add-TextField "RemoteName" $Strings.LabelRemoteName $Strings.DefaultRemoteName

    # --- Protocol selector ---
    $lblProto = New-Object System.Windows.Forms.Label
    $lblProto.Text = $Strings.LabelProtocol
    $lblProto.Location = New-Object System.Drawing.Point(15, $script:y)
    $lblProto.Size = New-Object System.Drawing.Size(510, 18)
    $form.Controls.Add($lblProto)
    $script:y += 20

    $comboProto = New-Object System.Windows.Forms.ComboBox
    $comboProto.Location = New-Object System.Drawing.Point(15, $script:y)
    $comboProto.Size = New-Object System.Drawing.Size(510, 24)
    $comboProto.DropDownStyle = "DropDownList"
    [void]$comboProto.Items.Add("SFTP")
    [void]$comboProto.Items.Add("WebDAV")
    $comboProto.SelectedIndex = 0
    if ($existingCfg -and $existingCfg.Protocol -eq "WebDAV") { $comboProto.SelectedIndex = 1 }
    $form.Controls.Add($comboProto)
    $script:inputs["Protocol"] = $comboProto
    $script:y += 34

    # --- SFTP section ---
    Add-SectionLabel $Strings.SectionSftp -group "SFTP"
    Add-TextField "SftpHost" $Strings.LabelSftpHost "" -group "SFTP"
    Add-TextField "SftpUser" $Strings.LabelSftpUser "" -group "SFTP"
    Add-TextField "SftpPort" $Strings.LabelSftpPort "22" -group "SFTP"
    Add-TextField "SshKeyFile" $Strings.LabelSshKeyFile "$env:USERPROFILE\.ssh\id_ed25519" -group "SFTP"
    Add-TextField "SshKeyPassphrase" $Strings.LabelSshKeyPassphrase "" -Password -group "SFTP"
    Add-TextField "SftpPassword" $Strings.LabelSftpPassword "" -Password -group "SFTP"
    Add-TextField "KnownHostsFile" $Strings.LabelKnownHostsFile "$env:USERPROFILE\.ssh\known_hosts" -group "SFTP"

    # --- WebDAV section ---
    Add-SectionLabel $Strings.SectionWebdav -group "WebDAV"
    Add-TextField "WebDavUrl" $Strings.LabelWebdavUrl "" -group "WebDAV"
    Add-TextField "WebDavUser" $Strings.LabelWebdavUser "" -group "WebDAV"
    Add-TextField "WebDavPassword" $Strings.LabelWebdavPassword "" -Password -group "WebDAV"
    Add-TextField "WebDavVendor" $Strings.LabelWebdavVendor "other" -group "WebDAV"

    # --- Vault section ---
    Add-SectionLabel $Strings.SectionVault
    Add-CheckboxField "IsCryptomatorVault" $Strings.LabelIsCryptomatorVault $true
    Add-TextField "VaultLocalPath" $Strings.LabelVaultLocalPath ""
    Add-TextField "VaultDriveLetter" $Strings.LabelVaultDriveLetter "X:\"
    Add-TextField "RemoteVaultPath" $Strings.LabelRemoteVaultPath "cryptomator-vault"
    Add-TextField "BandwidthMbit" $Strings.LabelBandwidthMbit "0"

    # --- USB backup section (optional, 3-2-1 rule) ---
    Add-SectionLabel $Strings.SectionUsbBackup
    Add-CheckboxField "UsbBackupEnabled" $Strings.LabelUsbBackupEnabled $false
    Add-TextField "UsbBackupPath" $Strings.LabelUsbBackupPath ""

    # --- Generate SSH key button ---
    $btnGenKey = New-Object System.Windows.Forms.Button
    $btnGenKey.Text = $Strings.ButtonGenKey
    $btnGenKey.Location = New-Object System.Drawing.Point(15, $script:y)
    $btnGenKey.Size = New-Object System.Drawing.Size(320, 28)
    $btnGenKey.Add_Click({
        $keyPath = $script:inputs["SshKeyFile"].Text
        $keyDir = Split-Path $keyPath -Parent
        if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }

        Start-Process -FilePath "ssh-keygen" -ArgumentList "-t ed25519 -f `"$keyPath`"" -Wait -NoNewWindow

        [System.Windows.Forms.MessageBox]::Show(
            (Format-Str $Strings.MsgKeyGenerated @($keyPath)),
            $Strings.MsgKeyGeneratedTitle, "OK", "Information") | Out-Null
    })
    $form.Controls.Add($btnGenKey)
    $script:y += 36

    # --- Protocol-driven show/hide of SFTP vs WebDAV sections ---
    $applyProtocolVisibility = {
        $selected = $comboProto.SelectedItem
        foreach ($grpName in $script:groups.Keys) {
            $visible = ($grpName -eq $selected)
            foreach ($ctrl in $script:groups[$grpName]) {
                $ctrl.Visible = $visible
            }
        }
        # The SSH-key generation button only makes sense for SFTP
        $btnGenKey.Visible = ($selected -eq "SFTP")
    }
    $comboProto.Add_SelectedIndexChanged($applyProtocolVisibility)
    & $applyProtocolVisibility

    # --- Save/Cancel buttons ---
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = $Strings.ButtonSave
    $btnSave.Location = New-Object System.Drawing.Point(15, $script:y)
    $btnSave.Size = New-Object System.Drawing.Size(230, 30)
    $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = $Strings.ButtonCancel
    $btnCancel.Location = New-Object System.Drawing.Point(260, $script:y)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnSave
    $script:y += 40
    $form.ClientSize = New-Object System.Drawing.Size(560, [Math]::Min($script:y + 20, 820))

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $cfg = [PSCustomObject]@{}
        foreach ($key in $script:inputs.Keys) {
            $control = $script:inputs[$key]
            if ($control -is [System.Windows.Forms.ComboBox]) {
                $value = $control.SelectedItem
            } elseif ($control -is [System.Windows.Forms.CheckBox]) {
                $value = $control.Checked
            } else {
                $value = $control.Text
            }
            $cfg | Add-Member -MemberType NoteProperty -Name $key -Value $value
        }
        return $cfg
    }
    return $null
}

function Show-MainForm {
    param($cfg)

    $script:reloadRequested = $false

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($Strings.MainTitle) v$ScriptVersion"
    $form.Size = New-Object System.Drawing.Size(780, 560)
    $form.StartPosition = "CenterScreen"

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 15)
    $lblStatus.Size = New-Object System.Drawing.Size(740, 20)
    $lblStatus.Text = Format-Str $Strings.StatusLabel @($cfg.RemoteName, $cfg.Protocol, $cfg.VaultLocalPath)
    $form.Controls.Add($lblStatus)

    # --- Dynamic vault status (refreshed periodically) ---
    $lblVaultStatus = New-Object System.Windows.Forms.Label
    $lblVaultStatus.Location = New-Object System.Drawing.Point(15, 38)
    $lblVaultStatus.Size = New-Object System.Drawing.Size(740, 20)
    $lblVaultStatus.Font = New-Object System.Drawing.Font($lblVaultStatus.Font, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblVaultStatus)

    # --- Config file path (clickable: opens the containing folder) ---
    $lblConfigPath = New-Object System.Windows.Forms.LinkLabel
    $lblConfigPath.Location = New-Object System.Drawing.Point(15, 180)
    $lblConfigPath.Size = New-Object System.Drawing.Size(365, 18)
    $lblConfigPath.Text = Format-Str $Strings.LabelConfigPath @($ConfigPath)
    $lblConfigPath.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblConfigPath.Add_LinkClicked({
        if (Test-Path $ConfigPath) {
            Start-Process "explorer.exe" -ArgumentList "/select,`"$ConfigPath`""
        } elseif (Test-Path $AppDataDir) {
            Start-Process "explorer.exe" -ArgumentList "`"$AppDataDir`""
        }
    })
    $form.Controls.Add($lblConfigPath)

    # --- Log file path (clickable: opens the log file, or its folder) ---
    $lblLogPath = New-Object System.Windows.Forms.LinkLabel
    $lblLogPath.Location = New-Object System.Drawing.Point(390, 180)
    $lblLogPath.Size = New-Object System.Drawing.Size(365, 18)
    $lblLogPath.Text = Format-Str $Strings.LabelLogPath @($LogPath)
    $lblLogPath.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblLogPath.Add_LinkClicked({
        if (Test-Path $LogPath) {
            Start-Process "notepad.exe" -ArgumentList "`"$LogPath`""
        } elseif (Test-Path $AppDataDir) {
            Start-Process "explorer.exe" -ArgumentList "`"$AppDataDir`""
        }
    })
    $form.Controls.Add($lblLogPath)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(15, 205)
    $logBox.Size = New-Object System.Drawing.Size(740, 290)
    $logBox.Multiline = $true
    $logBox.ScrollBars = "Vertical"
    $logBox.ReadOnly = $true
    $logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $form.Controls.Add($logBox)

    # --- 1. Sync local vault to remote ---
    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = "1. " + $Strings.ButtonSync
    $btnSync.Location = New-Object System.Drawing.Point(15, 65)
    $btnSync.Size = New-Object System.Drawing.Size(230, 32)
    $btnSync.Add_Click({
        $isVault = -not ($cfg.PSObject.Properties.Name -contains "IsCryptomatorVault") -or [bool]$cfg.IsCryptomatorVault

        if ($isVault -and (Test-Path $cfg.VaultDriveLetter)) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                (Format-Str $Strings.MsgVaultLockedBody @($cfg.VaultDriveLetter)),
                $Strings.MsgWarningTitle, "YesNo", "Warning")
            if ($confirm -eq "No") { return }
        }

        $bwArgs = @()
        if ([int]$cfg.BandwidthMbit -gt 0) {
            $bwMB = [math]::Round(([int]$cfg.BandwidthMbit / 8), 3)
            $bwArgs = @("--bwlimit", "${bwMB}M")
        }

        Append-Log $logBox (Format-Str $Strings.LogSyncHeader @($cfg.RemoteName))
        Append-Log $logBox $Strings.LogSyncConsoleOpened

        $dest = "$($cfg.RemoteName):$($cfg.RemoteVaultPath)"
        $rcloneArgs = @("copy", $cfg.VaultLocalPath, $dest,
                  "--transfers", "6", "--checkers", "4", "-v", "-P", "--stats", "2s") + $bwArgs
        $exitCode = Invoke-RcloneConsole -RcloneArgs $rcloneArgs

        if ($exitCode -eq 0) {
            Append-Log $logBox $Strings.LogSyncDone
        } else {
            Append-Log $logBox (Format-Str $Strings.LogSyncFailed @($exitCode))
        }
    })
    $form.Controls.Add($btnSync)

    # --- 2. Download from remote to local (reverse sync) ---
    $btnDownload = New-Object System.Windows.Forms.Button
    $btnDownload.Text = "2. " + $Strings.ButtonDownload
    $btnDownload.Location = New-Object System.Drawing.Point(255, 65)
    $btnDownload.Size = New-Object System.Drawing.Size(230, 32)
    $btnDownload.Add_Click({
        $isVault = -not ($cfg.PSObject.Properties.Name -contains "IsCryptomatorVault") -or [bool]$cfg.IsCryptomatorVault

        # The vault must be LOCKED here too: we're writing raw ciphertext files
        # into the local folder, and a mounted (unlocked) Cryptomator on top of
        # that folder could see an inconsistent state mid-write.
        if ($isVault -and (Test-Path $cfg.VaultDriveLetter)) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                (Format-Str $Strings.MsgVaultLockedBody @($cfg.VaultDriveLetter)),
                $Strings.MsgWarningTitle, "YesNo", "Warning")
            if ($confirm -eq "No") { return }
        }

        # Explicit overwrite warning: download can replace local files whose
        # remote counterpart differs, potentially overwriting newer local edits.
        $warn = [System.Windows.Forms.MessageBox]::Show(
            (Format-Str $Strings.MsgDownloadWarning @($cfg.VaultLocalPath)),
            $Strings.MsgDownloadWarningTitle, "YesNo", "Warning")
        if ($warn -eq "No") { return }

        $bwArgs = @()
        if ([int]$cfg.BandwidthMbit -gt 0) {
            $bwMB = [math]::Round(([int]$cfg.BandwidthMbit / 8), 3)
            $bwArgs = @("--bwlimit", "${bwMB}M")
        }

        Append-Log $logBox (Format-Str $Strings.LogDownloadHeader @($cfg.RemoteName))
        Append-Log $logBox $Strings.LogSyncConsoleOpened

        $src = "$($cfg.RemoteName):$($cfg.RemoteVaultPath)"
        $rcloneArgs = @("copy", $src, $cfg.VaultLocalPath,
                  "--transfers", "6", "--checkers", "4", "-v", "-P", "--stats", "2s") + $bwArgs
        $exitCode = Invoke-RcloneConsole -RcloneArgs $rcloneArgs

        if ($exitCode -eq 0) {
            Append-Log $logBox $Strings.LogDownloadDone
        } else {
            Append-Log $logBox (Format-Str $Strings.LogDownloadFailed @($exitCode))
        }
    })
    $form.Controls.Add($btnDownload)

    # --- 3. Verify integrity ---
    $btnVerify = New-Object System.Windows.Forms.Button
    $btnVerify.Text = "3. " + $Strings.ButtonVerify
    $btnVerify.Location = New-Object System.Drawing.Point(495, 65)
    $btnVerify.Size = New-Object System.Drawing.Size(180, 32)
    $btnVerify.Add_Click({
        Append-Log $logBox $Strings.LogVerifyHeader
        Append-Log $logBox $Strings.LogSyncConsoleOpened

        $dest = "$($cfg.RemoteName):$($cfg.RemoteVaultPath)"
        $verifyArgs = @("check", $cfg.VaultLocalPath, $dest, "--exclude", ".DAV/**", "--exclude", "**/.DAV/**", "-v", "-P")
        Invoke-RcloneConsole -RcloneArgs $verifyArgs | Out-Null
        Append-Log $logBox $Strings.LogVerifyDone
    })
    $form.Controls.Add($btnVerify)

    # --- 4. Backup local vault to USB (optional, 3-2-1 rule) ---
    $btnUsbBackup = New-Object System.Windows.Forms.Button
    $btnUsbBackup.Text = "4. " + $Strings.ButtonUsbBackup
    $btnUsbBackup.Location = New-Object System.Drawing.Point(15, 105)
    $btnUsbBackup.Size = New-Object System.Drawing.Size(230, 32)
    $btnUsbBackup.Add_Click({
        if (-not [bool]$cfg.UsbBackupEnabled -or [string]::IsNullOrWhiteSpace($cfg.UsbBackupPath)) {
            [System.Windows.Forms.MessageBox]::Show($Strings.MsgUsbNotConfigured, $Strings.MsgInfoTitle, "OK", "Information") | Out-Null
            return
        }

        $driveRoot = [System.IO.Path]::GetPathRoot($cfg.UsbBackupPath)
        if (-not (Test-Path $driveRoot)) {
            [System.Windows.Forms.MessageBox]::Show((Format-Str $Strings.MsgUsbDriveNotFound @($driveRoot)), $Strings.MsgWarningTitle, "OK", "Warning") | Out-Null
            return
        }

        $isVault = -not ($cfg.PSObject.Properties.Name -contains "IsCryptomatorVault") -or [bool]$cfg.IsCryptomatorVault
        if ($isVault -and (Test-Path $cfg.VaultDriveLetter)) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                (Format-Str $Strings.MsgVaultLockedBody @($cfg.VaultDriveLetter)),
                $Strings.MsgWarningTitle, "YesNo", "Warning")
            if ($confirm -eq "No") { return }
        }

        if (-not (Test-Path $cfg.UsbBackupPath)) {
            try {
                New-Item -ItemType Directory -Path $cfg.UsbBackupPath -Force -ErrorAction Stop | Out-Null
                Append-Log $logBox (Format-Str $Strings.LogUsbDestCreated @($cfg.UsbBackupPath))
            }
            catch {
                Append-Log $logBox (Format-Str $Strings.MsgUsbDestCreateError @($cfg.UsbBackupPath, $_.Exception.Message))
                return
            }
        }

        Append-Log $logBox (Format-Str $Strings.LogUsbBackupHeader @($cfg.UsbBackupPath))
        Append-Log $logBox $Strings.LogSyncConsoleOpened

        $usbArgs = @("copy", $cfg.VaultLocalPath, $cfg.UsbBackupPath, "--transfers", "6", "--checkers", "4", "-v", "-P")
        $exitCode = Invoke-RcloneConsole -RcloneArgs $usbArgs

        if ($exitCode -eq 0) {
            Append-Log $logBox $Strings.LogUsbBackupDone
        } else {
            Append-Log $logBox (Format-Str $Strings.LogUsbBackupFailed @($exitCode))
        }
    })
    $form.Controls.Add($btnUsbBackup)

    # --- Utility row: test connection / dry-run / reconfigure ---
    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = $Strings.ButtonTest
    $btnTest.Location = New-Object System.Drawing.Point(15, 150)
    $btnTest.Size = New-Object System.Drawing.Size(130, 28)
    $btnTest.Add_Click({ Test-RcloneConnection -cfg $cfg -LogBox $logBox })
    $form.Controls.Add($btnTest)

    $btnDryRun = New-Object System.Windows.Forms.Button
    $btnDryRun.Text = $Strings.ButtonDryRun
    $btnDryRun.Location = New-Object System.Drawing.Point(155, 150)
    $btnDryRun.Size = New-Object System.Drawing.Size(180, 28)
    $btnDryRun.Add_Click({
        Append-Log $logBox $Strings.LogDryRunHeader
        Append-Log $logBox $Strings.LogSyncConsoleOpened
        $dryRunArgs = @("copy", $cfg.VaultLocalPath, "$($cfg.RemoteName):$($cfg.RemoteVaultPath)", "--dry-run", "-v", "-P")
        Invoke-RcloneConsole -RcloneArgs $dryRunArgs | Out-Null
        Append-Log $logBox $Strings.LogDryRunDone
    })
    $form.Controls.Add($btnDryRun)

    $btnReconfig = New-Object System.Windows.Forms.Button
    $btnReconfig.Text = $Strings.ButtonReconfig
    $btnReconfig.Location = New-Object System.Drawing.Point(345, 150)
    $btnReconfig.Size = New-Object System.Drawing.Size(130, 28)
    $btnReconfig.Add_Click({
        $newCfg = Show-SetupForm -existingCfg $cfg
        if ($newCfg) {
            Save-Config $newCfg
            # Signal the startup loop to reload with the new config, then close
            # this window. The loop will rebuild the remote and reopen the main
            # form -- no manual restart needed.
            $script:reloadRequested = $true
            $form.Close()
        }
    })
    $form.Controls.Add($btnReconfig)

    # --- Vault status refresh logic ---
    # "1. Sync" works on the raw encrypted folder and should only run once the
    # vault is locked, so writes are flushed and stable -- see prior discussion.
    # None of this applies when IsCryptomatorVault is false (plain folder sync):
    # there is no lock/unlock state, so the status label is hidden and the
    # buttons stay enabled unconditionally.
    $isVault = -not ($cfg.PSObject.Properties.Name -contains "IsCryptomatorVault") -or [bool]$cfg.IsCryptomatorVault

    $updateVaultStatus = {
        if (-not $isVault) {
            $lblVaultStatus.Visible = $false
            $btnSync.Enabled = $true
            $btnDownload.Enabled = $true
            $btnUsbBackup.Enabled = $true
            return
        }

        $unlocked = Test-Path $cfg.VaultDriveLetter

        if ($unlocked) {
            $lblVaultStatus.Text = Format-Str $Strings.LabelVaultStatusUnlocked @($cfg.VaultDriveLetter)
            $lblVaultStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $lblVaultStatus.Text = $Strings.LabelVaultStatusLocked
            $lblVaultStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        }

        $btnSync.Enabled = -not $unlocked
        $btnDownload.Enabled = -not $unlocked
        $btnUsbBackup.Enabled = -not $unlocked
    }

    & $updateVaultStatus

    $statusTimer = New-Object System.Windows.Forms.Timer
    $statusTimer.Interval = 1500
    $statusTimer.Add_Tick($updateVaultStatus)
    $statusTimer.Start()

    $form.Add_FormClosed({
        $statusTimer.Stop()
        $statusTimer.Dispose()
    })

    $form.ShowDialog() | Out-Null

    return $script:reloadRequested
}

# ============================================================
# BOOTSTRAP + STARTUP
# ============================================================

$initialCfg = Get-Config
$langCode = $DefaultLanguage
if ($initialCfg -and $initialCfg.PSObject.Properties.Name -contains "Language" -and $initialCfg.Language) {
    $langCode = $initialCfg.Language
}
$Strings = Get-Strings -LanguageCode $langCode

$cfg = $initialCfg

if (-not $cfg) {
    [System.Windows.Forms.MessageBox]::Show($Strings.MsgWelcome, $Strings.MsgWelcomeTitle, "OK", "Information") | Out-Null

    $cfg = Show-SetupForm -existingCfg $null
    if (-not $cfg) {
        exit
    }
    Save-Config $cfg

    if ($cfg.Language) {
        $Strings = Get-Strings -LanguageCode $cfg.Language
    }
}

if (-not (Ensure-Rclone -LogBox $null)) {
    [System.Windows.Forms.MessageBox]::Show($Strings.MsgNoRclone, $Strings.MsgErrorTitle, "OK", "Error") | Out-Null
    exit
}

# Main loop: (re)build the rclone remote from the current config, show the main
# window, and if the user reconfigured, reload everything and loop again.
$reload = $true
while ($reload) {
    $cfg = Get-Config
    if ($cfg -and $cfg.Language) {
        $Strings = Get-Strings -LanguageCode $cfg.Language
    }

    New-RcloneRemote -cfg $cfg -LogBox $null | Out-Null

    $reload = Show-MainForm -cfg $cfg
}
