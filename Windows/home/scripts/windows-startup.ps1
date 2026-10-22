$ErrorActionPreference = "Stop"

$BasePath = [Environment]::GetFolderPath("UserProfile")
$ProgramFiles = ${env:ProgramFiles}

$komorebic = Join-Path $ProgramFiles "komorebi\bin\komorebic.exe"
$autoHotkey = Join-Path $ProgramFiles "AutoHotkey\v2\AutoHotkey.exe"
$processPriority = [Diagnostics.ProcessPriorityClass]::High

function Set-StartupProcessPriority {
    param(
        [string[]]$Names
    )

    foreach ($process in (Get-Process -Name $Names -ErrorAction SilentlyContinue)) {
        $process.PriorityClass = $processPriority
    }
}

$processes = Get-Process -Name "komorebi" -ErrorAction SilentlyContinue
if (-not $processes) {
    Start-Process $komorebic `
        -ArgumentList @("start", "--whkd", "--bar") `
        -WorkingDirectory $BasePath `
        -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

Set-StartupProcessPriority @("komorebi", "whkd")

$autoHotkeyProcesses = Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue
if (-not $autoHotkeyProcesses) {
    Start-Process $autoHotkey `
        -ArgumentList (Join-Path $BasePath "scripts\autohotkey\master.ahk") `
        -WorkingDirectory (Join-Path $BasePath "scripts\autohotkey") `
        -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    $autoHotkeyProcesses = Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue
}

Set-StartupProcessPriority "AutoHotkey*"

# taskkill /f /im explorer.exe      # this is buggy    
