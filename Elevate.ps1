Set-StrictMode -Version Latest

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-PSExePath {
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = "powershell.exe" }
    return $psExe
}

function Get-SafeFileNameFromUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        $u = [Uri]$Url
        $name = [IO.Path]::GetFileName($u.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "download_" + (Get-Date -Format "yyyyMMdd_HHmmss")
        }
        return $name
    }
    catch {
        return "download_" + (Get-Date -Format "yyyyMMdd_HHmmss")
    }
}

function Show-FileTrustInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Write-Host ""
    Write-Host "File info:" -ForegroundColor Cyan
    Write-Host ("  Path   : {0}" -f $Path)
    try {
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $Path
        Write-Host ("  SHA256 : {0}" -f $hash.Hash)
    }
    catch {
        Write-Host "  SHA256 : (unable to compute)" -ForegroundColor DarkYellow
    }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        Write-Host ("  Signed : {0}" -f ($sig.SignerCertificate -ne $null))
        Write-Host ("  Status : {0}" -f $sig.Status)
        if ($sig.SignerCertificate) {
            Write-Host ("  Signer : {0}" -f $sig.SignerCertificate.Subject)
        }
    }
    catch {
        Write-Host "  Signature: (unable to read)" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

function Invoke-ElevateSelf {
    if (Test-IsAdmin) {
        Write-Host "Already running elevated (Administrator)." -ForegroundColor Green
        return
    }

    $psExe = Get-PSExePath
    $scriptPath = $PSCommandPath

    $argList = @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
    )

    if ($scriptPath -and (Test-Path -LiteralPath $scriptPath)) {
        $argList += @("-File", "`"$scriptPath`"")
    }
    else {
        $argList += @(
            "-NoExit",
            "-Command",
            "Set-Location -LiteralPath `"$PWD`"; Write-Host 'Elevated session started.' -ForegroundColor Green"
        )
    }

    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs | Out-Null
        Write-Host "Elevation requested. Approve the UAC prompt if shown." -ForegroundColor Yellow
        if ($scriptPath) { exit 0 }
    }
    catch {
        Write-Host "Elevation failed or was cancelled." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
    }
}

function Invoke-DownloadFromUrl {
    # Ensure TLS 1.2 for older Windows PowerShell environments
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $url = Read-Host "Enter URL to download"
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-Host "No URL provided." -ForegroundColor DarkYellow
        return
    }

    # Default destination: user's Downloads
    $defaultDir = Join-Path $env:USERPROFILE "Downloads"
    $nameFromUrl = Get-SafeFileNameFromUrl -Url $url
    $defaultPath = Join-Path $defaultDir $nameFromUrl

    $dest = Read-Host "Save as (press Enter for default: $defaultPath)"
    if ([string]::IsNullOrWhiteSpace($dest)) { $dest = $defaultPath }

    $destDir = Split-Path -Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destDir)) {
        try {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        catch {
            Write-Host "Unable to create folder: $destDir" -ForegroundColor Red
            return
        }
    }

    Write-Host ""
    Write-Host "Downloading..." -ForegroundColor Cyan
    Write-Host ("  From: {0}" -f $url)
    Write-Host ("  To  : {0}" -f $dest)

    $downloaded = $false

    # Prefer BITS when available (more resilient)
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $url -Destination $dest -ErrorAction Stop
            $downloaded = $true
        }
    }
    catch {
        $downloaded = $false
    }

    # Fallback to Invoke-WebRequest
    if (-not $downloaded) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop | Out-Null
            $downloaded = $true
        }
        catch {
            Write-Host "Download failed." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor DarkRed
            return
        }
    }

    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Host "Download did not produce a file at destination." -ForegroundColor Red
        return
    }

    Write-Host "Download complete." -ForegroundColor Green
    Show-FileTrustInfo -Path $dest

    $runNow = Read-Host "Run it now with elevated permissions? (y/N)"
    if ($runNow -match '^(y|yes)$') {
        Invoke-RunInstallerElevated -Path $dest
    }
}

function Select-ExeOrMsiFile {
    param(
        [string]$InitialDirectory = $PWD.Path
    )

    # Load WinForms
    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select an installer (EXE or MSI)"
    $dlg.Filter = "Installers (*.exe;*.msi)|*.exe;*.msi|Executable (*.exe)|*.exe|Windows Installer (*.msi)|*.msi|All files (*.*)|*.*"
    $dlg.Multiselect = $false
    $dlg.CheckFileExists = $true
    $dlg.CheckPathExists = $true

    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) {
        $dlg.InitialDirectory = $InitialDirectory
    } else {
        $dlg.InitialDirectory = [Environment]::GetFolderPath("Desktop")
    }

    $result = $dlg.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and
        -not [string]::IsNullOrWhiteSpace($dlg.FileName)) {
        return $dlg.FileName
    }

    return $null
}

function Invoke-RunInstallerElevated {
    param(
        [string]$Path
    )

    # Ask for path (paste-friendly)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Read-Host "Enter full path to EXE or MSI (press Enter to browse)"
    }

    # If blank -> open file picker UI
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $picked = Select-ExeOrMsiFile -InitialDirectory $PWD.Path
        if (-not $picked) {
            Write-Host "No file selected." -ForegroundColor DarkYellow
            return
        }
        $Path = $picked
        Write-Host ("Selected: {0}" -f $Path) -ForegroundColor Cyan
    }

    # Resolve path
    $resolved = $Path
    try { $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { }

    if (-not (Test-Path -LiteralPath $resolved)) {
        Write-Host "File not found: $resolved" -ForegroundColor Red
        return
    }

    $ext = ([IO.Path]::GetExtension($resolved)).ToLowerInvariant()

    # Optional args
    $arg0 = Read-Host "Optional arguments (press Enter for none)"

    # Trust info (hash + signature)
    Show-FileTrustInfo -Path $resolved

    try {
        if ($ext -eq ".msi") {
            # Use msiexec for MSI
            $msiArgs = @("/i", "`"$resolved`"")
            if (-not [string]::IsNullOrWhiteSpace($arg0)) {
                $msiArgs += $arg0
            }

            Write-Host "Launching MSI elevated via msiexec..." -ForegroundColor Cyan
            Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Verb RunAs -Wait
            Write-Host "MSI process completed." -ForegroundColor Green
            return
        }

        if ($ext -eq ".exe") {
            Write-Host "Launching EXE elevated..." -ForegroundColor Cyan
            if ([string]::IsNullOrWhiteSpace($arg0)) {
                Start-Process -FilePath $resolved -Verb RunAs -Wait
            } else {
                Start-Process -FilePath $resolved -ArgumentList $arg0 -Verb RunAs -Wait
            }
            Write-Host "EXE process completed." -ForegroundColor Green
            return
        }

        Write-Host "Unsupported file type: $ext (only .exe or .msi)" -ForegroundColor Red
    } catch {
        Write-Host "Launch failed or was cancelled." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
    }
}

function Show-ElevateMenu {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "       Administrator's Elevate Utility        " -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "1. Elevate Self"
    Write-Host "2. Download from URL"
    Write-Host "3. Run EXE or MSI with elevated permissions"
    Write-Host "0. Exit"
    Write-Host ""
}

function Elevate {
    while ($true) {
        Show-ElevateMenu
        $choice = Read-Host "Select an option"

        switch ($choice) {
            "1" {
                Invoke-ElevateSelf
                Start-Sleep -Milliseconds 600
            }
            "2" {
                Invoke-DownloadFromUrl
                Read-Host "Press Enter to return to menu" | Out-Null
            }
            "3" {
                Invoke-RunInstallerElevated
                Read-Host "Press Enter to return to menu" | Out-Null
            }
            "0" { return }
            default {
                Write-Host "Invalid option: $choice" -ForegroundColor Red
                Start-Sleep -Milliseconds 600
            }
        }
    }
}

Elevate