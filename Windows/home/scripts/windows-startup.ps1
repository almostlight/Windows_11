$ErrorActionPreference = "Stop"

$BasePath = [Environment]::GetFolderPath("UserProfile")
$ProgramFiles = ${env:ProgramFiles}

$komorebi = Join-Path $ProgramFiles "komorebi\bin\komorebi.exe"
$komorebiBar = Join-Path $ProgramFiles "komorebi\bin\komorebi-bar.exe"
$whkd = Join-Path $ProgramFiles "whkd\bin\whkd.exe"
$autoHotkey = Join-Path $ProgramFiles "AutoHotkey\v2\AutoHotkey.exe"

$processes = Get-Process -Name "komorebi" -ErrorAction SilentlyContinue
if (-not $processes) {
    Start-Process $komorebi `
        -ArgumentList @("--config", (Join-Path $BasePath "komorebi.json")) `
        -WorkingDirectory $BasePath
    Start-Sleep -Seconds 2
}

if (-not (Get-Process -Name "komorebi-bar" -ErrorAction SilentlyContinue)) {
    Start-Process $komorebiBar -WorkingDirectory $BasePath
}

if (-not (Get-Process -Name "whkd" -ErrorAction SilentlyContinue)) {
    Start-Process $whkd `
        -ArgumentList @("-c", (Join-Path $BasePath ".config\whkdrc")) `
        -WorkingDirectory $BasePath
}

if (-not (Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue)) {
    Start-Process $autoHotkey `
        -ArgumentList (Join-Path $BasePath "scripts\autohotkey\master.ahk") `
        -WorkingDirectory (Join-Path $BasePath "scripts\autohotkey")
}
