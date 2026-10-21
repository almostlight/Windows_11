$ErrorActionPreference = "Stop"

$BasePath = [Environment]::GetFolderPath("UserProfile")
$ProgramFiles = ${env:ProgramFiles}

$komorebic = Join-Path $ProgramFiles "komorebi\bin\komorebic.exe"
$autoHotkey = Join-Path $ProgramFiles "AutoHotkey\v2\AutoHotkey.exe"

$processes = Get-Process -Name "komorebi" -ErrorAction SilentlyContinue
if (-not $processes) {
    Start-Process $komorebic `
        -ArgumentList @("start", "--whkd", "--bar") `
        -WorkingDirectory $BasePath `
        -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

if (-not (Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue)) {
    Start-Process $autoHotkey `
        -ArgumentList (Join-Path $BasePath "scripts\autohotkey\master.ahk") `
        -WorkingDirectory (Join-Path $BasePath "scripts\autohotkey") `
        -WindowStyle Hidden
}
