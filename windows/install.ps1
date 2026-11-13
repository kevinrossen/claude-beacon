<#
  Installs the claude-beacon tray client for the current Windows user.

    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Url http://my-server:8799 -Token <token>
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall

  - copies ClaudeBeacon.ps1 to %LOCALAPPDATA%\claude-beacon
  - writes %APPDATA%\claude-beacon\client.json (asks for URL and token if it doesn't exist)
  - adds a Startup shortcut so it runs at login, then starts it now
#>
param(
    [string]$Url,
    [string]$Token,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$appDir = Join-Path $env:LOCALAPPDATA 'claude-beacon'
$cfgDir = Join-Path $env:APPDATA 'claude-beacon'
$cfgPath = Join-Path $cfgDir 'client.json'
$script = Join-Path $appDir 'ClaudeBeacon.ps1'
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Beacon.lnk'

function Stop-Beacon {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ClaudeBeacon.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Stop-Beacon
    Remove-Item $lnk -ErrorAction SilentlyContinue
    Remove-Item $appDir -Recurse -ErrorAction SilentlyContinue
    Write-Host "Removed. Config left in $cfgDir (delete it if you want)."
    return
}

New-Item -ItemType Directory -Force -Path $appDir, $cfgDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'ClaudeBeacon.ps1') $script -Force

if ($Url -or $Token -or -not (Test-Path $cfgPath)) {
    while (-not $Url) { $Url = Read-Host 'Beacon URL, e.g. http://my-server:8799 (where the beacon server runs)' }
    while (-not $Token) { $Token = Read-Host 'Beacon token (BEACON_TOKEN from the server''s env file)' }
    # keep any settings already in the file (layout, notify, ...); write without a BOM
    $cfgOut = [ordered]@{}
    if (Test-Path $cfgPath) {
        try { (Get-Content $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfgOut[$_.Name] = $_.Value } } catch { }
    }
    $cfgOut['url'] = $Url.TrimEnd('/')
    $cfgOut['token'] = $Token.Trim()
    [System.IO.File]::WriteAllText($cfgPath, ($cfgOut | ConvertTo-Json))
}

# Check the beacon answers before wiring up login
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
try {
    $state = Invoke-RestMethod -Uri "$($cfg.url)/state" -Headers @{ Authorization = "Bearer $($cfg.token)" } -TimeoutSec 5
    Write-Host "Beacon reachable: $(@($state.sessions).Count) session(s), $($state.waiting) waiting."
} catch {
    Write-Warning "Could not reach $($cfg.url)/state : $($_.Exception.Message)"
    Write-Warning 'Installing anyway; the tray icon shows a gray "!" until it can connect.'
}

$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = (Get-Command powershell.exe).Source
$sc.Arguments = $psArgs
$sc.WorkingDirectory = $appDir
$sc.WindowStyle = 7   # minimized, so no console flashes at login
$sc.Description = 'Claude Beacon tray client'
$sc.Save()

Stop-Beacon
Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $psArgs -WindowStyle Hidden
Write-Host "Installed. Look for the Claude Beacon icon in the tray (click ^ if Windows hides it,"
Write-Host "then drag it onto the taskbar or turn it on under Settings > Personalization > Taskbar > Other system tray icons)."
