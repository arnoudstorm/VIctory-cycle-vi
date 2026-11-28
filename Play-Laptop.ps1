# Frees as much RAM as possible on the 16 GB Radeon 780M laptop, then starts the game.
# Closes Chrome and the Claude app first (they hold 1-2 GB), then runs the NVIDIA build with the
# Series S profile and no DLSS (this laptop has no NVIDIA card).
#   powershell -ExecutionPolicy Bypass -File Play-Laptop.ps1 [-DelaySeconds 30]
param([int]$DelaySeconds = 0)

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

$repo = $PSScriptRoot
$gameDir = (Get-Content (Join-Path $repo 'game_dir.txt') -TotalCount 1).Trim()
$exe = Join-Path $gameDir 'game_scarlett_master.exe'

function Close-App([string]$name) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    Write-Host "Closing $name ..."
    $procs | ForEach-Object { try { [void]$_.CloseMainWindow() } catch {} }
    Start-Sleep -Seconds 5
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Close-App 'chrome'
Close-App 'msedge'
Close-App 'claude'
Start-Sleep -Seconds 3

$free = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
Write-Host "Free RAM before the game: $free GB"

& (Join-Path $repo 'scripts\play-foxhound.ps1') -Exe $exe -SeriesS -Dlss off -NoFrameGenReady
Write-Host ''
Write-Host 'The game has ended. Its log is in %LOCALAPPDATA%\victory\logs.'
Read-Host 'Press Enter to close this window'
