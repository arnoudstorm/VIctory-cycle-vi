# Launch the newest build in this worktree with the settings measured on the
# Ryzen 7 8840HS / Radeon 780M laptop. The variables exist only for this
# PowerShell process and the game process it starts.
param(
    [string]$GameDir,
    [string]$BuildPath,
    [ValidateSet('auto', 'low', 'lowmem', 'balanced', 'quality')]
    [string]$Preset = 'auto',
    [switch]$Safe,
    [switch]$Bilinear,
    [switch]$NoAmbient,
    [switch]$AutoStart,
    [switch]$CutsceneTest,
    [switch]$NoCapture,
    [string]$CaptureDir,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TitleArguments
)

$ErrorActionPreference = 'Stop'

if ($CutsceneTest) {
    $AutoStart = $true
}

if (-not $BuildPath) {
    $candidates = @(
        'target-planes\release\victory.exe'
        'target-planes\diag\victory.exe'
        'target\release\victory.exe'
        'target\diag\victory.exe'
    ) | ForEach-Object { Join-Path $PSScriptRoot $_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-Item -LiteralPath $_ }
    if ($AutoStart) {
        # Scripted input is intentionally a diagnostics-only feature.
        $candidates = $candidates | Where-Object { $_.Directory.Name -eq 'diag' }
    }
    $BuildPath = $candidates |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $BuildPath -or -not (Test-Path -LiteralPath $BuildPath -PathType Leaf)) {
    throw "No victory.exe build found. Build one with 'cargo build --profile diag -p victory --features diagnostics'."
}
$BuildPath = (Resolve-Path -LiteralPath $BuildPath).Path

if (-not $GameDir) {
    $GameDir = $env:VICTORY_GAME_DIR
}
if (-not $DryRun) {
    if (-not $GameDir -or -not (Test-Path -LiteralPath $GameDir -PathType Container)) {
        throw 'Pass -GameDir with the folder containing your game_*.exe, or set VICTORY_GAME_DIR.'
    }
    $GameDir = (Resolve-Path -LiteralPath $GameDir).Path
}

# Pick conservative defaults automatically on 16 GB UMA machines. Explicit
# presets make the same launcher useful on nearby lower- and higher-end PCs.
$totalRamGB = [math]::Round(
    (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB,
    1
)
if ($Preset -eq 'auto') {
    $Preset = if ($totalRamGB -le 17) { 'low' } else { 'balanced' }
}
$profile = switch ($Preset) {
    'low' {
        @{
            # Copy-back on a second thread, and reads of title memory wait
            # only for the flights that wrote it: world frames 2.3 s -> 1.2 s
            # on the 780M (docs/SESSIONS-2026-11-24-25.md, docs/audit-780m.md).
            # The device removals seen with it were memory exhaustion
            # (docs/updates/update-4-relay-off.md). -Safe turns it off.
            Relay = '2'
            Filter = 'bilinear'
            TextureStageMB = '32'
            TextureStageMS = '100'
            TextureCatchup = '0'
            TextureBudgetMB = '1024'
            TextureMinFreeMB = '3072'
            CompileHeadroomMB = '3072'
            PreludePool = '1'
            ShaderLoopLimit = '64'
            # Texture refreshes do not wait for remaps: on the 780M the
            # worst frame-line "textures" fell from 195.5 ms to 5.5-6.1 ms in
            # two guarded runs, with no texture failures.
            TextureNoWait = '1'
        }
    }
    'lowmem' {
        # Opt-in, for 16 GB UMA laptops running out of memory in the world:
        # 'low' with a smaller host texture budget, fewer kept snapshots and
        # translated loops stopped sooner.
        @{
            Relay = '2'
            Filter = 'bilinear'
            TextureStageMB = '16'
            TextureStageMS = '100'
            TextureCatchup = '0'
            TextureBudgetMB = '768'
            TextureMinFreeMB = '3584'
            CompileHeadroomMB = '3072'
            PreludePool = '1'
            ShaderLoopLimit = '32'
            KeepSnapshotsMB = '64'
            TextureNoWait = '1'
        }
    }
    'balanced' {
        @{
            Relay = '2'
            Filter = 'bicubic'
            TextureStageMB = '96'
            TextureStageMS = '200'
            TextureCatchup = '1'
            TextureBudgetMB = '2048'
            TextureMinFreeMB = '2048'
            CompileHeadroomMB = '2048'
            PreludePool = '1'
            ShaderLoopLimit = '256'
        }
    }
    'quality' {
        @{
            Relay = '2'
            Filter = 'bicubic'
            TextureStageMB = '128'
            TextureStageMS = '250'
            TextureCatchup = '1'
            TextureBudgetMB = '4096'
            TextureMinFreeMB = '1536'
            CompileHeadroomMB = '1536'
            PreludePool = '0'
            ShaderLoopLimit = '1024'
        }
    }
}

# Measured memory/performance settings shared by all laptop profiles.
$settings = [ordered]@{
    VICTORY_NO_WATCHDOG       = '1'
    VICTORY_SKIP_BROKEN_LISTS = '1'
    VICTORY_F16_NEAREST       = '1'
    VICTORY_LAZY_LISTS        = '1'
    VICTORY_PRELUDE_POOL      = $profile.PreludePool
    VICTORY_TILED_WINDOWS     = '1'
    VICTORY_WIDE_REFRESH      = '1'
    VICTORY_WIDE_BACK         = '1'
    VICTORY_JOIN_COPIES       = '1'
    VICTORY_WINDOW_KB         = '256'
    VICTORY_WINDOW_TAILS      = '1'
    VICTORY_INPLACE           = '1'
    VICTORY_CARD_BUFFERS_MB   = '256'
    VICTORY_TEXTURE_STAGE_MB  = $profile.TextureStageMB
    VICTORY_TEXTURE_STAGE_MS  = $profile.TextureStageMS
    VICTORY_TEXTURE_CATCHUP   = $profile.TextureCatchup
    VICTORY_TEXTURE_BUDGET_MB = $profile.TextureBudgetMB
    VICTORY_TEXTURE_MIN_FREE_MB = $profile.TextureMinFreeMB
    VICTORY_COMPILE_HEADROOM_MB = $profile.CompileHeadroomMB
    VICTORY_SHADER_LOOP_LIMIT = $profile.ShaderLoopLimit
    VICTORY_TEXTURE_NO_WAIT   = $(if ($profile.TextureNoWait) { $profile.TextureNoWait } else { '0' })
    VICTORY_FFX_BUILTIN       = '1'
    VICTORY_FFX_FILTER        = $(if ($Bilinear) { 'bilinear' } else { $profile.Filter })
    VICTORY_AMBIENT           = $(if ($NoAmbient) { 'off' } else { '0.6' })
    VICTORY_RELAY             = $(if ($Safe) { '0' } else { $profile.Relay })
}
if ($CutsceneTest) {
    # Stop before the engine cutscene begins so later A presses cannot skip it.
    $settings.VICTORY_KEYS = (10..60 |
        Where-Object { $_ % 5 -eq 0 } |
        ForEach-Object { "${_}:Enter" }) -join ','
    $settings.VICTORY_INPUT_LOG = '1'
    if (-not $NoCapture) {
        $settings.VICTORY_CAPTURE_WORLD = '1'
        if (-not $CaptureDir) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $CaptureDir = Join-Path $env:LOCALAPPDATA "victory\captures\cutscene-$stamp"
        }
        if (-not $DryRun) {
            $null = New-Item -ItemType Directory -Path $CaptureDir -Force
            $CaptureDir = (Resolve-Path -LiteralPath $CaptureDir).Path
        }
        $settings.VICTORY_CAPTURE = $CaptureDir
    }
} elseif ($AutoStart) {
    # Enter is pad A, including when a real controller is connected. Repeat
    # through first boot, legal screens and the start menu.
    $settings.VICTORY_KEYS = (10..240 |
        Where-Object { $_ % 5 -eq 0 } |
        ForEach-Object { "${_}:Enter" }) -join ','
}
if ($profile.KeepSnapshotsMB) {
    $settings.VICTORY_KEEP_SNAPSHOTS_MB = $profile.KeepSnapshotsMB
}
if ($GameDir) {
    $settings.VICTORY_GAME_DIR = $GameDir
}
foreach ($entry in $settings.GetEnumerator()) {
    Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
}

Write-Host "Build: $BuildPath"
Write-Host "Profile: $Preset / Series S / $totalRamGB GB RAM$(if ($Safe) { ' / safe relay-off' })"
if ($totalRamGB -le 17) {
    Write-Warning '16 GB is enough to boot and render the world, but this fork can still page heavily in gameplay. Close other applications first.'
}
if ($CutsceneTest) {
    Write-Host $(if ($NoCapture) { 'Cutscene capture: disabled' } else { "Cutscene capture: $CaptureDir" })
}
foreach ($entry in $settings.GetEnumerator()) {
    Write-Host "$($entry.Key)=$($entry.Value)"
}
if ($DryRun) {
    exit 0
}

$title = Get-ChildItem -LiteralPath $GameDir -File -Filter 'game_*.exe' |
    Sort-Object Name |
    Select-Object -First 1
if (-not $title) {
    throw "No game_*.exe found in $GameDir"
}

$run = @('run', $title.FullName, '--execute', '--console', 'series-s')
if ($TitleArguments.Count -gt 0) {
    $run += '--'
    $run += $TitleArguments
}
& $BuildPath @run
exit $LASTEXITCODE
