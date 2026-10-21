<# 
Yes, it is vibe-coded. I'm not learning Powershell.
#>

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
    $localStartupScript = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "home\scripts\windows-startup.ps1"
    }
    $elevatedStartupScript = Join-Path $env:TEMP "windows-setup-startup.ps1"
    if ($PSCommandPath -and (Test-Path $PSCommandPath -PathType Leaf)) {
        Copy-Item $PSCommandPath $elevatedScript -Force
        if (Test-Path $localStartupScript -PathType Leaf) {
            Copy-Item $localStartupScript $elevatedStartupScript -Force
        }
    } else {
        Invoke-WebRequest $ScriptUrl -OutFile $elevatedScript -UseBasicParsing
    }

    $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $shell) { $shell = (Get-Command powershell.exe).Source }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedScript`""
    if ($WhatIf) { $arguments += " -WhatIf" }
    $process = Start-Process $shell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    Remove-Item $elevatedScript -Force -ErrorAction SilentlyContinue
    Remove-Item $elevatedStartupScript -Force -ErrorAction SilentlyContinue
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

Invoke-Step "packages" {
    $packageList = Join-Path $env:TEMP "WindowsSetup-winget-packages.txt"
    $strictlyNecessaryPackages = @("LGUG2Z.komorebi", "LGUG2Z.whkd", "AutoHotkey.AutoHotkey")

    Get-RawRepositoryFile "Windows/winget-packages.txt" $packageList

    $allRecommendedPackages = Get-Content $packageList |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") }

    $installAllRecommendedPackages = $false
    if (-not $WhatIf) {
        $response = Read-Host "Install all recommended packages? [y/N] (Choosing 'N' installs only strictly necessary packages)"
        if ($response -match '^(y|yes)$') {
            $installAllRecommendedPackages = $true
        } elseif ($response -and $response -notmatch '^(n|no|)$') {
            Write-SetupLog "Unrecognized package installation choice: '$response'. Defaulting to install all recommended packages" "WARN"
        }
    }

    $packagesToInstall = if ($installAllRecommendedPackages) {
        $allRecommendedPackages
    } else {
        $strictlyNecessaryPackages
    }

    foreach ($packageId in $packagesToInstall) {
        Install-SetupPackage $packageId
    }
}

Invoke-Step "home-config-and-startup" {
    $sourceHome = Join-Path $env:TEMP "WindowsSetup-home"
    $configFiles = @{
        "komorebi.bar.json" = "komorebi.bar.json"
        "komorebi.json" = "komorebi.json"
        ".config\whkdrc" = ".config\whkdrc"
        "scripts\autohotkey\loop_accept.ahk" = "scripts\autohotkey\loop_accept.ahk"
        "scripts\autohotkey\master.ahk" = "scripts\autohotkey\master.ahk"
        "scripts\windows-startup.ps1" = "scripts\windows-startup.ps1"
    }

    foreach ($relativePath in $configFiles.Keys) {
        $target = Join-Path $sourceHome $configFiles[$relativePath]
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        $repositoryPath = $relativePath -replace "\\", "/"
        if ($relativePath -eq "scripts\windows-startup.ps1" -and
            (Test-Path (Join-Path $env:TEMP "windows-setup-startup.ps1"))) {
            Copy-Item (Join-Path $env:TEMP "windows-setup-startup.ps1") $target -Force
        } else {
            Get-RawRepositoryFile "Windows/home/$repositoryPath" $target
        }
        if ($relativePath -eq ".config\whkdrc") {
            (Get-Content $target -Raw) -replace "(?im)^super\b", "win" |
                Set-Content $target -Encoding utf8
        } elseif ($relativePath -eq "komorebi.json") {
            (Get-Content $target -Raw) -replace '(?m)^\s*"app_specific_configuration_path":[^\r\n]*\r?\n', "" |
                Set-Content $target -Encoding utf8
        }
    }

    Get-ChildItem -Path $sourceHome -Force | Copy-Item -Destination $BasePath -Recurse -Force

    $startup = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not $startup) {
        throw "Could not resolve the machine-wide Startup folder"
    }
    New-Item -ItemType Directory -Force -Path $startup | Out-Null

    $startupScript = Join-Path $BasePath "scripts\windows-startup.ps1"
    if (-not (Test-Path $startupScript -PathType Leaf)) {
        throw "Startup script was not deployed: $startupScript"
    }

    $shell = New-Object -ComObject WScript.Shell
    $shellApplication = New-Object -ComObject Shell.Application
    $homeFolder = $shellApplication.Namespace($BasePath)
    if (-not $homeFolder) {
        throw "Could not access the user's home folder: $BasePath"
    }
    $homeFolder.Self.InvokeVerb("pintohome")
    Write-SetupLog "Pinned the user's home folder to Quick Access"

    $startupShortcut = $shell.CreateShortcut(
        (Join-Path $startup "01-startup.lnk")
    )
    $startupShortcut.TargetPath = (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    $startupShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startupScript`""
    $startupShortcut.WorkingDirectory = Split-Path $startupScript
    $startupShortcut.WindowStyle = 7
    $startupShortcut.Save()
    Write-SetupLog "Configured one machine-wide startup launcher"
}

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
    if (-not (Test-Path $p)) {
        New-Item $p | Out-Null
    }
    Set-ItemProperty -Path $p -Name "AppsUseLightTheme" -Value 0
    Set-ItemProperty -Path $p -Name "SystemUsesLightTheme" -Value 0

    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (-not (Test-Path $p)) {
        New-Item $p | Out-Null
    }
    Set-ItemProperty -Path $p -Name "TaskbarAl" -Value 0
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

# =========================
# OPEN LOG AND CLEANUP
# =========================

Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

Invoke-Step "open log" {
    $openLog = Read-Host "Would you like to open the log file? (y/N)"
    if ($openLog -eq "Y" -or $openLog -eq "y") {
        notepad $LogPath
    }
}

Write-SetupLog "Provisioning complete"
