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
function Write-Log {
    param($Msg, $Type="INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Host $line
    Add-Content $LogPath $line
}

Write-Log "Starting provisioning"

function Run-Step($Name, $ScriptBlock) {
    Write-Log "RUN: $Name"

    if ($WhatIf) { return }

    try {
        & $ScriptBlock
    } catch {
        Write-Log "FAILED: $Name - $_" "ERROR"
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

Run-Step "winget" {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $pkg = Join-Path $Downloads "winget.msixbundle"
        Get-File "https://aka.ms/getwinget" $pkg
        Add-AppxPackage $pkg
        Start-Sleep 5
    }
}

function Install-Package($id) {
    $installed = & winget list --exact --id $id `
        --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($installed -match "(?im)\b$([regex]::Escape($id))\b") {
        Write-Log "Skipping already installed package $id"
        return
    }

    Write-Log "Installing $id"
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

Run-Step "packages" {
<<<<<<< HEAD:Windows/windows_setup.ps1
    $packageList = Join-Path $env:TEMP "WindowsSetup-winget-packages.txt"
    Get-RawRepositoryFile "Windows/winget-packages.txt" $packageList

    Get-Content $packageList |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") } |
        ForEach-Object { Install-Package $_ }
}

Run-Step "home-config-and-startup" {
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
    $autoHotkeyCandidates = @(
        (Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue).Source,
        (Join-Path ${env:ProgramFiles} "AutoHotkey\v2\AutoHotkey.exe"),
        (Join-Path ${env:ProgramFiles} "AutoHotkey\AutoHotkey.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\AutoHotkey\v2\AutoHotkey.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\AutoHotkey\AutoHotkey.exe")
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } |
        Select-Object -First 1
    if (-not $autoHotkeyCandidates) {
        throw "AutoHotkey.exe was not found after package installation"
    }

    $shell = New-Object -ComObject WScript.Shell
    $autoHotkeyShortcut = $shell.CreateShortcut((Join-Path $startup "AutoHotkey master.lnk"))
    $autoHotkeyShortcut.TargetPath = $autoHotkeyCandidates
    $autoHotkeyShortcut.Arguments = "`"$masterScript`""
    $autoHotkeyShortcut.WorkingDirectory = Split-Path $masterScript
    $autoHotkeyShortcut.Save()
    Write-Log "Configured AutoHotkey master script to start with Windows"

    $komorebiCandidates = @(
        (Get-Command komorebic.exe -ErrorAction SilentlyContinue).Source,
        (Join-Path ${env:ProgramFiles} "komorebi\bin\komorebic.exe")
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } |
        Select-Object -First 1
    if (-not $komorebiCandidates) {
        throw "komorebic.exe was not found after package installation"
    }

    $hiddenShell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $hiddenShell) {
        throw "powershell.exe was not found for hidden Komorebi startup"
    }

    $komorebiShortcut = $shell.CreateShortcut((Join-Path $startup "Komorebi.lnk"))
    $komorebiShortcut.TargetPath = $hiddenShell
    $komorebiShortcut.Arguments = "-NoProfile -WindowStyle Hidden -Command `"Start-Process -FilePath '$komorebiCandidates' -ArgumentList 'start --whkd --bar' -WindowStyle Hidden -Wait`""
    $komorebiShortcut.WorkingDirectory = Split-Path $komorebiCandidates
    $komorebiShortcut.WindowStyle = 7
    $komorebiShortcut.Save()
    Write-Log "Configured Komorebi to start hidden with Windows"
=======
    @(
        "7zip.7zip",
        "AutoHotkey.AutoHotkey",
	    "Bambulab.Bambustudio",
        "Kitware.CMake",
        "GIMP.GIMP",
        "Git.Git",
        "GitHub.cli",
        "GitHub.GitHubDesktop",
		"Inkscape.Inkscape",
        "Oracle.JDK.21",
        "Oracle.JDK.26",
        "KeePassXCTeam.KeePassXC",
        "Klocman.BulkCrapUninstaller",
        "Microsoft.DotNet.DesktopRuntime.8",
        "Microsoft.DotNet.DesktopRuntime.9",
        "Microsoft.Office",
        "Microsoft.PowerShell",
        "Microsoft.PowerToys",
        "Microsoft.VisualStudioCode",
        "Mozilla.Firefox",
        "Nextcloud.NextcloudDesktop",
        "REALiX.HWiNFO",
        "Tailscale.Tailscale",
        "WinFsp.WinFsp",
        "vim.vim"
    ) | ForEach-Object { Install-Package $_ }
>>>>>>> 94b73149a75713a9078543496af29a1509cba243:windows_setup.ps1
}

Run-Step "edge-blocker" {
    $edgeUrl = "https://securedl.chip-downloads.de/downloads/41092168/EdgeBlock2.0.zip?cdr=4&cid=88734083&platform=chip&1779964617-1779972117-46994b-B-30a845019b172eaee80a888a40bb5b9f"
    $out = Join-Path $Downloads "EdgeBlocker.zip"
    $dir = Join-Path $Downloads "EdgeBlocker"

    try {
        Write-Log "Downloading Edge Blocker from secured mirror"
        Get-File $edgeUrl $out

        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive $out $dir -Force

        $exe = Get-ChildItem $dir -Recurse -Filter "*EdgeBlock*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($exe) {
            Write-Log "Launching Edge Blocker: $($exe.FullName)"
            Start-Process -FilePath $exe.FullName -WorkingDirectory $dir -Verb RunAs
        } else {
            Write-Log "EdgeBlocker executable not found after extraction, opening download pages" "WARN"
            Start-Process "https://www.sordum.org/9312/edge-blocker-v2-0/"
            Start-Process "https://github.com/Sordum/Edge-Blocker/releases"
        }
    } catch {
        Write-Log "Edge Blocker automated install failed: $_" "WARN"
        Start-Process "https://www.sordum.org/9312/edge-blocker-v2-0/"
        Start-Process "https://github.com/Sordum/Edge-Blocker/releases"
    }
}

Run-Step "repo" {
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

#Run-Step "ssh" {
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

Run-Step "rdp" {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
}

# =========================
# UI / SYSTEM TWEAKS
# =========================

Run-Step "ui-and-komorebi-hotkeys" {
    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    New-Item $p -Force | Out-Null
    Set-ItemProperty $p AppsUseLightTheme 0
    Set-ItemProperty $p SystemUsesLightTheme 0

    $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    New-Item $p -Force | Out-Null
    Set-ItemProperty $p TaskbarAl 0

    reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve
}

Run-Step "keyboard" {
    $lang = New-WinUserLanguageList en-US
    $lang[0].InputMethodTips.Clear()
    $lang[0].InputMethodTips.Add("0415:00000415")
    Set-WinUserLanguageList $lang -Force
}

# =========================
# DEBLOAT
# =========================

Run-Step "debloat" {
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

Run-Step "nvclean" {
    $nvUrl = "https://securedl.chip-downloads.de/downloads/121468823/NVCleanstall_1.19.0.exe?cdr=4&cid=176735254&platform=chip&1779964955-1779972455-6c9997-B-933592b8e46cca0af302c6d4d04b9043.exe"
    $path = Join-Path $Downloads "NVCleanstall_1.19.0.exe"

    function Test-IsHtmlFile($p) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $len = [Math]::Min(512, $bytes.Length)
            $s = [System.Text.Encoding]::ASCII.GetString($bytes,0,$len)
            if ($s -match '<!doctype' -or $s -match '<html') { return $true }
        } catch { }
        return $false
    }

    try {
        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }

        Write-Log "Downloading NVCleanstall from secured mirror"
        Get-File $nvUrl $path

        if (-not (Test-Path $path)) { throw "Download failed: $nvUrl" }

        if (Test-IsHtmlFile $path) {
            Write-Log "Downloaded file appears to be HTML/redirect; removing and falling back" "WARN"
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            throw "Downloaded file invalid (HTML)"
        }

        Write-Log "Launching NVCleanstall: $path"
        Start-Process -FilePath $path -WorkingDirectory $Downloads -Verb RunAs
    } catch {
        Write-Log "NVCleanstall automated install failed: $_" "WARN"
        Start-Process "https://sourceforge.net/projects/nvcleanstall/files/"
        Start-Process "https://sourceforge.net/projects/nvcleanstall/files/latest/download"
    }
}

# =========================
# QUICK ACCESS PINNING
# =========================

Run-Step "quickaccess" {
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

Run-Step "open log" {
    $openLog = Read-Host "Would you like to open the log file? (y/N)"
    if ($openLog -eq "Y" -or $openLog -eq "y") {
        notepad $LogPath
    }
}

# =========================
# RESTART DESKTOP PROCESSES
# =========================

if (-not $WhatIf) {
    foreach ($name in @("komorebi", "komorebi-bar", "whkd", "AutoHotkey", "explorer")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }

    $komorebic = Join-Path ${env:ProgramFiles} "komorebi\bin\komorebic.exe"
    if (-not (Test-Path $komorebic -PathType Leaf)) {
        throw "komorebic.exe was not found while restarting desktop processes"
    }
    Start-Process -FilePath $komorebic `
        -ArgumentList "start --whkd --bar" -WindowStyle Hidden

    $autoHotkey = @(
        (Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue).Source,
        (Join-Path ${env:ProgramFiles} "AutoHotkey\v2\AutoHotkey.exe"),
        (Join-Path ${env:ProgramFiles} "AutoHotkey\AutoHotkey.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\AutoHotkey\v2\AutoHotkey.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\AutoHotkey\AutoHotkey.exe")
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } |
        Select-Object -First 1
    if (-not $autoHotkey) {
        throw "AutoHotkey.exe was not found while restarting desktop processes"
    }
    Start-Process -FilePath $autoHotkey `
        -ArgumentList "`"$BasePath\scripts\autohotkey\master.ahk`"" `
        -WorkingDirectory "$BasePath\scripts\autohotkey" -WindowStyle Hidden

    Start-Process explorer.exe
}

Write-Log "Provisioning complete"
