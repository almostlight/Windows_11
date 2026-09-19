# Yes, it is vibe-coded. I'm not learning Powershell. 
param(
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"

# --- Self-elevation ---
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $(if ($WhatIf) {'-WhatIf'})" `
        -Verb RunAs
    exit
}

# --- Core paths ---
$date = Get-Date -Format "yyyy-MM-dd_HH_mm_ss"
$BasePath = "C:\Users\Public\Automation"
$Downloads = Join-Path $BasePath "Downloads"
$LogPath = Join-Path $BasePath "setup.$date.log"
$StatePath = Join-Path $BasePath "state.json"

New-Item -ItemType Directory -Force -Path $BasePath, $Downloads | Out-Null

# --- Logging ---
function Write-Log {
    param($Msg, $Type="INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Host $line
    Add-Content $LogPath $line
}

Write-Log "Starting provisioning"

# --- State ---
$State = if (Test-Path $StatePath) {
    Get-Content $StatePath | ConvertFrom-Json -AsHashtable
} else { @{} }

function Save-State { $State | ConvertTo-Json | Set-Content $StatePath }

function Run-Step($Name, $ScriptBlock) {
    if ($State[$Name]) {
        Write-Log "SKIP: $Name"
        return
    }

    Write-Log "RUN: $Name"

    if ($WhatIf) { return }

    try {
        & $ScriptBlock
        $State[$Name] = $true
        Save-State
    } catch {
        Write-Log "FAILED: $Name - $_" "ERROR"
    }
}

# --- Mode selection ---
if (-not $State.Mode) {
    Write-Host "1) VM with GPU passthrough"
    Write-Host "2) Bare-metal"

    do { $choice = Read-Host "Enter 1 or 2" }
    while ($choice -notin "1","2")

    $State.Mode = if ($choice -eq "1") { "VM" } else { "BareMetal" }
    Save-State
}

Write-Log "Mode: $($State.Mode)"

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
    Write-Log "Installing $id"
    winget install -e --id $id --silent `
        --accept-package-agreements --accept-source-agreements
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
        git -C $Repo pull
    } else {
        git clone https://github.com/almostlight/WindowsSetup $Repo
    }
}

# Run-Step "ssh" {
#     if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
#         Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
#     }
#     Set-Service sshd -StartupType Automatic
#     Start-Service sshd
# }

Run-Step "rdp" {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
}

# =========================
# VM FEATURES
# =========================

if ($State.Mode -eq "VM") {

    Run-Step "virtio" {
        $file = Join-Path $Downloads "virtio.exe"
        Get-File "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win-guest-tools.exe" $file
        Start-Process $file -ArgumentList "/quiet" -Wait
    }

    Run-Step "lookingglass" {
        $lgDir = Join-Path $Downloads "lg"

        $existing = Get-ChildItem $lgDir -Recurse -Filter "looking-glass-host-setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($existing) {
            Write-Log "Looking Glass already extracted/available, skipping download" "SUCCESS"
            Start-Process $existing.FullName -Wait
            return
        }

        $zip = Join-Path $Downloads "lg.zip"
        Get-File "https://looking-glass.io/artifact/stable/host" $zip

        $dir = Join-Path $Downloads "lg"
        Expand-Archive $zip $dir -Force

        $exe = Get-ChildItem $dir -Recurse -Filter "looking-glass-host-setup.exe" | Select-Object -First 1

        if ($exe) { Start-Process $exe.FullName -Wait }
    }

    Run-Step "vdd" {
        $vddInstallPath = "C:\Program Files\VDD_Control"
        $vddExe = Get-ChildItem $vddInstallPath -Recurse -Filter "VDD Control.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($vddExe) {
            Write-Log "VDD already installed at $($vddExe.FullName), skipping download/install" "SUCCESS"
            return
        }

        if (-not (Test-Path $vddInstallPath)) {
            New-Item $vddInstallPath -ItemType Directory -Force | Out-Null
        }

        $vddUrl = Get-LatestGitHubRelease `
            -Repo "VirtualDrivers/Virtual-Display-Driver" `
            -AssetPattern "VDD.Control.*.zip"

        $zip = Join-Path $env:TEMP "vdd.zip"
        Invoke-WebRequest $vddUrl -OutFile $zip

        Expand-Archive $zip $vddInstallPath -Force
        Remove-Item $zip -Force

        $exe = Get-ChildItem $vddInstallPath -Recurse -Filter "VDD Control.exe" | Select-Object -First 1

        if ($exe) { Start-Process $exe.FullName }
    }

    Run-Step "autologon" {
        $dir = Join-Path $Downloads "Autologon"
        New-Item $dir -ItemType Directory -Force | Out-Null

        Invoke-WebRequest "https://live.sysinternals.com/Autologon.exe" -OutFile "$dir\Autologon.exe"
        Invoke-WebRequest "https://live.sysinternals.com/Autologon64.exe" -OutFile "$dir\Autologon64.exe"

        Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" AutoAdminLogon "1"
    }

}

# =========================
# UI / SYSTEM TWEAKS
# =========================

Run-Step "ui" {
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

Run-Step "winkey" {
    try {
        $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        New-Item -Path $p -Force | Out-Null
        Set-ItemProperty -Path $p -Name "NoWinKeys" -Value 0 -Type DWord -Force
        Write-Log "Win key enabled"
    } catch {
        Write-Log "Failed enabling Win key: $_" "ERROR"
    }
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
# DDU
# =========================

Run-Step "ddu" {
    $path = Join-Path $Downloads "DDU.exe"
    Invoke-WebRequest "https://www.wagnardsoft.com/DDU/download/DDU%20v18.0.8.5.exe" -OutFile $path
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
# CLEANUP
# =========================

Run-Step "cleanup" {
    if ($State.Values -notcontains $false) {
        Remove-Item $StatePath -Force
        Write-Log "State removed"
    }
}

Run-Step "open log" { 
    $openLog = Read-Host "nWould you like to open the log file? (y/N)" 
    if ($openLog -eq 'Y' -or $openLog -eq 'y') { 
        notepad $LogPath 
    } 
}

# Explorer restart
Stop-Process explorer -Force
Write-Log "Provisioning complete"
