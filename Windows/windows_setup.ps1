# Yes, it is vibe-coded. I'm not learning Powershell.
param(
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ScriptUrl = "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/Windows/windows_setup.ps1"

# --- Self-elevation ---
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $elevatedScript = Join-Path $env:TEMP "windows-setup-$PID.ps1"
    if ($PSCommandPath -and (Test-Path $PSCommandPath -PathType Leaf)) {
        Copy-Item $PSCommandPath $elevatedScript -Force
    } else {
        Invoke-WebRequest $ScriptUrl -OutFile $elevatedScript -UseBasicParsing
    }

    $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $shell) { $shell = (Get-Command powershell.exe).Source }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedScript`""
    if ($WhatIf) { $arguments += " -WhatIf" }
    $process = Start-Process $shell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    Remove-Item $elevatedScript -Force -ErrorAction SilentlyContinue
    exit $process.ExitCode
}

# --- Core paths ---
$date = Get-Date -Format "yyyy-MM-dd_HH_mm_ss"
$BasePath = [Environment]::GetFolderPath("UserProfile")
$Downloads = Join-Path $BasePath "Downloads"
$ScriptsPath = Join-Path $BasePath "scripts"
$LogPath = Join-Path $ScriptsPath "setup.$date.log"

New-Item -ItemType Directory -Force -Path $Downloads, $ScriptsPath | Out-Null

# --- Logging ---
function Write-SetupLog {
    param($Msg, $Type = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Output $line
    Add-Content $LogPath $line
}

Write-SetupLog "Starting provisioning"

function Invoke-Step($Name, $ScriptBlock) {
    Write-SetupLog "RUN: $Name"

    if ($WhatIf) { return }

    try {
        & $ScriptBlock
    } catch {
        Write-SetupLog "FAILED: $Name - $_" "ERROR"
        throw
    }
}

# --- Download helper ---
function Get-File($Url, $Out) {
    if (Test-Path $Out) { return }

    for ($i=0; $i -lt 3; $i++) {
        try {
            Invoke-WebRequest $Url -OutFile $Out -TimeoutSec 60
            return
        } catch {
            Start-Sleep 2
        }
    }

    throw "Download failed: $Url"
}

function Get-RawRepositoryFile($RelativePath, $Out) {
    Get-File `
        "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/$RelativePath" `
        $Out
}

function Find-Executable {
    param(
        [string]$Name,
        [string[]]$FallbackPaths
    )

    $paths = @(
        (Get-Command $Name -ErrorAction SilentlyContinue).Source
        $FallbackPaths
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) }

    if ($paths) {
        return $paths | Select-Object -First 1
    }

    throw "$Name was not found"
}

# =========================
# CORE SYSTEM SETUP BLOCKS
# =========================

Invoke-Step "winget" {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $pkg = Join-Path $Downloads "winget.msixbundle"
        Get-File "https://aka.ms/getwinget" $pkg
        Add-AppxPackage $pkg
        Start-Sleep 5
    }
}

function Install-SetupPackage($id) {
    $installed = & winget list --exact --id $id `
        --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($installed -match "(?im)\b$([regex]::Escape($id))\b") {
        Write-SetupLog "Skipping already installed package $id"
        return
    }

    Write-SetupLog "Installing $id"
    & winget install -e --id $id --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "Winget failed for $id with exit code $LASTEXITCODE"
    }
}

function Get-LatestGitHubRelease {
    param(
        [string]$Repo,
        [string]$AssetPattern
    )

    $api = "https://api.github.com/repos/$Repo/releases/latest"

    $release = Invoke-RestMethod -Uri $api -Headers @{
        "User-Agent" = "PowerShell"
    }

    $asset = $release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1

    if (-not $asset) {
        throw "No asset matching $AssetPattern in $Repo"
    }

    return $asset.browser_download_url
}

Invoke-Step "packages" {
    $packageList = Join-Path $env:TEMP "WindowsSetup-winget-packages.txt"
    Get-RawRepositoryFile "Windows/winget-packages.txt" $packageList

    Get-Content $packageList |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") } |
        ForEach-Object { Install-SetupPackage $_ }
}

Invoke-Step "home-config-and-startup" {
    $sourceHome = Join-Path $env:TEMP "WindowsSetup-home"
    $configFiles = @{
        "komorebi.bar.json" = "komorebi.bar.json"
        "komorebi.json" = "komorebi.json"
        ".config\whkdrc" = ".config\whkdrc"
        "scripts\autohotkey\loop_accept.ahk" = "scripts\autohotkey\loop_accept.ahk"
        "scripts\autohotkey\master.ahk" = "scripts\autohotkey\master.ahk"
    }

    foreach ($relativePath in $configFiles.Keys) {
        $target = Join-Path $sourceHome $configFiles[$relativePath]
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        Get-RawRepositoryFile "Windows/home/$relativePath" $target
    }

    Get-ChildItem -Path $sourceHome -Force | Copy-Item -Destination $BasePath -Recurse -Force

    $masterScript = Join-Path $BasePath "scripts\autohotkey\master.ahk"
    if (-not (Test-Path $masterScript -PathType Leaf)) {
        throw "Master AutoHotkey script was not deployed: $masterScript"
    }

    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) {
        throw "Could not resolve the signed-in user's Startup folder"
    }
    New-Item -ItemType Directory -Force -Path $startup | Out-Null

    $autoHotkey = Find-Executable "AutoHotkey.exe" @(
        (Join-Path ${env:ProgramFiles} "AutoHotkey\v2\AutoHotkey.exe"),
        (Join-Path ${env:ProgramFiles} "AutoHotkey\AutoHotkey.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\AutoHotkey\v2\AutoHotkey.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\AutoHotkey\AutoHotkey.exe")
    )

    $shell = New-Object -ComObject WScript.Shell
    $autoHotkeyShortcut = $shell.CreateShortcut((Join-Path $startup "AutoHotkey master.lnk"))
    $autoHotkeyShortcut.TargetPath = $autoHotkey
    $autoHotkeyShortcut.Arguments = "`"$masterScript`""
    $autoHotkeyShortcut.WorkingDirectory = Split-Path $masterScript
    $autoHotkeyShortcut.Save()
    Write-SetupLog "Configured AutoHotkey master script to start with Windows"

    $komorebic = Find-Executable "komorebic.exe" @(
        (Join-Path ${env:ProgramFiles} "komorebi\bin\komorebic.exe")
    )

    $komorebiShortcut = $shell.CreateShortcut((Join-Path $startup "Komorebi.lnk"))
    $komorebiShortcut.TargetPath = $komorebic
    $komorebiShortcut.Arguments = "start --whkd --bar"
    $komorebiShortcut.WorkingDirectory = Split-Path $komorebic
    $komorebiShortcut.WindowStyle = 7
    $komorebiShortcut.Save()
    Write-SetupLog "Configured Komorebi and its bar to start for the signed-in user"
}

Invoke-Step "edge-blocker" {
    $edgeUrl = "https://securedl.chip-downloads.de/downloads/41092168/EdgeBlock2.0.zip?cdr=4&cid=88734083&platform=chip&1779964617-1779972117-46994b-B-30a845019b172eaee80a888a40bb5b9f"
    $out = Join-Path $Downloads "EdgeBlocker.zip"
    $dir = Join-Path $Downloads "EdgeBlocker"

    try {
        Write-SetupLog "Downloading Edge Blocker from secured mirror"
        Get-File $edgeUrl $out

        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive $out $dir -Force

        $exe = Get-ChildItem $dir -Recurse -Filter "*EdgeBlock*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($exe) {
            Write-SetupLog "Launching Edge Blocker: $($exe.FullName)"
            Start-Process -FilePath $exe.FullName -WorkingDirectory $dir -Verb RunAs
        } else {
            Write-SetupLog "EdgeBlocker executable not found after extraction, opening download pages" "WARN"
            Start-Process "https://www.sordum.org/9312/edge-blocker-v2-0/"
            Start-Process "https://github.com/Sordum/Edge-Blocker/releases"
        }
    } catch {
        Write-SetupLog "Edge Blocker automated install failed: $_" "WARN"
        Start-Process "https://www.sordum.org/9312/edge-blocker-v2-0/"
        Start-Process "https://github.com/Sordum/Edge-Blocker/releases"
    }
}

Invoke-Step "repo" {
    $Repo = Join-Path $BasePath "WindowsSetup"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git missing"
    }

    if (Test-Path $Repo) {
        if (-not (Test-Path (Join-Path $Repo ".git"))) {
            throw "Path exists but is not a Git repository: $Repo"
        }
        & git -C $Repo pull
    } else {
        & git clone https://github.com/almostlight/WindowsSetup $Repo
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Git failed with exit code $LASTEXITCODE"
    }
}

#Invoke-Step "ssh" {
#    $capabilityName = "OpenSSH.Server~~~~0.0.1.0"
#    $capability = Get-WindowsCapability -Online -Name $capabilityName
#
#    if ($capability.State -ne "Installed") {
#        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
#    }
#
#    $service = Get-Service -Name "sshd" -ErrorAction Stop
#    Set-Service -Name "sshd" -StartupType Automatic
#
#    if ($service.Status -ne "Running") {
#        Start-Service -Name "sshd"
#    }
#}

Invoke-Step "rdp" {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
}

# =========================
# UI / SYSTEM TWEAKS
# =========================

Invoke-Step "ui-and-komorebi-hotkeys" {
    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    New-Item $p -Force | Out-Null
    Set-ItemProperty -Path $p -Name "AppsUseLightTheme" -Value 0
    Set-ItemProperty -Path $p -Name "SystemUsesLightTheme" -Value 0

    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    New-Item $p -Force | Out-Null
    Set-ItemProperty -Path $p -Name "TaskbarAl" -Value 0

    reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve
}

Invoke-Step "keyboard" {
    $lang = New-WinUserLanguageList en-US
    $lang[0].InputMethodTips.Clear()
    $lang[0].InputMethodTips.Add("0415:00000415")
    Set-WinUserLanguageList $lang -Force
}

# =========================
# DEBLOAT
# =========================

Invoke-Step "debloat" {
    $apps = @(
        "Microsoft.XboxApp","Microsoft.XboxGamingOverlay","Microsoft.XboxGameOverlay",
        "Microsoft.XboxSpeechToTextOverlay","Microsoft.GamingApp","Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo","Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GetHelp",
        "Microsoft.Getstarted","Microsoft.MicrosoftOfficeHub","Microsoft.People",
        "Microsoft.PowerAutomateDesktop","Microsoft.Todos","Microsoft.WindowsFeedbackHub",
        "MicrosoftTeams","Microsoft.SkypeApp","Microsoft.YourPhone"
    )

    foreach ($a in $apps) {
        Get-AppxPackage -Name $a -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
    }

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\" -Name "OneDrive" -ErrorAction SilentlyContinue
}

# =========================
# NVCLEANSTALL
# =========================

Invoke-Step "nvclean" {
    $nvUrl = "https://securedl.chip-downloads.de/downloads/121468823/NVCleanstall_1.19.0.exe?cdr=4&cid=176735254&platform=chip&1779964955-1779972455-6c9997-B-933592b8e46cca0af302c6d4d04b9043.exe"
    $path = Join-Path $Downloads "NVCleanstall_1.19.0.exe"

    function Test-IsHtmlFile($p) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $len = [Math]::Min(512, $bytes.Length)
            $s = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $len)
            if ($s -match '<!doctype' -or $s -match '<html') { return $true }
        } catch {
            return $false
        }
        return $false
    }

    try {
        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }

        Write-SetupLog "Downloading NVCleanstall from secured mirror"
        Get-File $nvUrl $path

        if (-not (Test-Path $path)) { throw "Download failed: $nvUrl" }

        if (Test-IsHtmlFile $path) {
            Write-SetupLog "Downloaded file appears to be HTML/redirect; removing and falling back" "WARN"
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            throw "Downloaded file invalid (HTML)"
        }

        Write-SetupLog "Launching NVCleanstall: $path"
        Start-Process -FilePath $path -WorkingDirectory $Downloads -Verb RunAs
    } catch {
        Write-SetupLog "NVCleanstall automated install failed: $_" "WARN"
        Start-Process "https://sourceforge.net/projects/nvcleanstall/files/"
        Start-Process "https://sourceforge.net/projects/nvcleanstall/files/latest/download"
    }
}

# =========================
# QUICK ACCESS PINNING
# =========================

Invoke-Step "quickaccess" {
    $shell = New-Object -ComObject Shell.Application
    foreach ($p in @($Downloads, $BasePath)) {
        if (Test-Path $p) {
            ($shell.Namespace($p)).Self.InvokeVerb("pintohome")
        }
    }
}

# =========================
# OPEN LOG AND CLEANUP
# =========================

Invoke-Step "open log" {
    $openLog = Read-Host "Would you like to open the log file? (y/N)"
    if ($openLog -eq "Y" -or $openLog -eq "y") {
        notepad $LogPath
    }
}

Write-SetupLog "Provisioning complete"
