# Test -> optimize -> run loop for the 16 GB Radeon 780M laptop.
# Runs the game once per variant below, watches it until the GPU device is lost, it exits, or it
# survives -SurviveMinutes, then kills it, lets RAM recover, and goes on with the next variant.
# Results: results.csv next to this script (one row per run) and a summary at the end.
#   powershell -ExecutionPolicy Bypass -File tools-laptop\optimize-loop.ps1 [-SurviveMinutes 4] [-Only B,C]
param([double]$SurviveMinutes = 4, [string[]]$Only, [int]$Round = 1)

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path (Get-Content (Join-Path $repo 'game_dir.txt') -TotalCount 1).Trim() 'game_scarlett_master.exe'
$play = Join-Path $repo 'scripts\play-foxhound.ps1'
$logs = Join-Path $env:LOCALAPPDATA 'victory\logs'
$csv = Join-Path $PSScriptRoot 'results.csv'

# Every variant starts from the same base: textures at 50 % of the card's budget, small card copies.
$base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50'; VICTORY_CARD_BUFFERS_MB = '256'; VICTORY_MEMORY_CARD_MB = '512' }
$variants = [ordered]@{
    'A-base'        = @{ More = @{}; Args = @{} }
    'B-relay1'      = @{ More = @{ VICTORY_RELAY = '1' }; Args = @{} }   # fewer lists in the air
    'C-fps30'       = @{ More = @{}; Args = @{ Fps = 30 } }              # the title's own rate, not uncapped
    'D-textures'    = @{ More = @{ VICTORY_TEXTURE_KEEP = '0'; VICTORY_LEVELS_ON_DEMAND = '1'; VICTORY_TEXTURE_BUDGET_MB = '512'; VICTORY_UPLOAD_AHEAD = '0' }; Args = @{} }
    'E-pools'       = @{ More = @{ VICTORY_SNAPSHOT_POOL = '64'; VICTORY_KEEP_SNAPSHOTS_MB = '64'; VICTORY_DSTORAGE_STAGING_MB = '64'; VICTORY_KEEP_FREED = '0' }; Args = @{} }
    'F-all'         = @{ More = @{ VICTORY_RELAY = '1'; VICTORY_TEXTURE_KEEP = '0'; VICTORY_LEVELS_ON_DEMAND = '1'; VICTORY_TEXTURE_BUDGET_MB = '512'; VICTORY_UPLOAD_AHEAD = '0'; VICTORY_SNAPSHOT_POOL = '64'; VICTORY_KEEP_SNAPSHOTS_MB = '64'; VICTORY_DSTORAGE_STAGING_MB = '64'; VICTORY_KEEP_FREED = '0'; VICTORY_AMBIENT = 'off' }; Args = @{ Fps = 30 } }
}
# Round 2: what the laptop builds (which reach the world here) do differently. The NVIDIA build keeps
# second copies of title data "on the card"; on a shared-memory GPU that is the same RAM, twice.
$noCard = @{
    VICTORY_CARD_BUFFERS_MB = '0'; VICTORY_MEMORY_CARD_MB = '0'; VICTORY_CARD_STEPS = '0'; VICTORY_CARD_AWAKE = '0'
    VICTORY_WC_NO_BACK = '0'; VICTORY_RELAY_COPY = '0'; VICTORY_INDIRECT_CARD_BUDGET = '0'
}
# The laptop launcher's 'low' preset, where this build has the switch (no TILED_WINDOWS, NO_WATCHDOG,
# LAZY_LISTS, PRELUDE_POOL, SKIP_BROKEN_LISTS, FFX_BUILTIN, COMPILE_HEADROOM_MB here).
$laptopLow = @{
    VICTORY_WIDE_REFRESH = '1'; VICTORY_WINDOW_KB = '256'; VICTORY_WINDOW_TAILS = '1'; VICTORY_INPLACE = '1'
    VICTORY_TEXTURE_BUDGET_MB = '1024'; VICTORY_TEXTURE_MIN_FREE_MB = '3072'; VICTORY_TEXTURE_STAGE_MB = '32'
    VICTORY_TEXTURE_STAGE_MS = '100'; VICTORY_TEXTURE_CATCHUP = '0'; VICTORY_AMBIENT = '0.6'
}
if ($Round -eq 2) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'G-nocard'        = @{ More = $noCard; Args = @{} }
        'H-nocard-laptop' = @{ More = $noCard + $laptopLow; Args = @{} }
        'I-H-fps30'       = @{ More = $noCard + $laptopLow; Args = @{ Fps = 30 } }
    }
}
# Round 3: the laptop fork's fixes ported into this build (prelude pool, skip broken lists; the compile
# headroom gate is on by default at 1536 MB).
$ported = @{ VICTORY_PRELUDE_POOL = '1'; VICTORY_SKIP_BROKEN_LISTS = '1' }
if ($Round -eq 3) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'J-H-ported' = @{ More = $noCard + $laptopLow + $ported; Args = @{} }
        'K-G-ported' = @{ More = $noCard + $ported; Args = @{} }
    }
}
# Round 4: also lazy host lists (a list is opened only when something is recorded into it), ported
# from the laptop fork; saves the allocators of the many lists that stay empty.
$lazy = @{ VICTORY_LAZY_LISTS = '1' }
if ($Round -eq 4) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'L-K-lazy' = @{ More = $noCard + $ported + $lazy; Args = @{} }
        'M-J-lazy' = @{ More = $noCard + $laptopLow + $ported + $lazy; Args = @{} }
    }
}
# Round 5: what fills RAM once in the world (run L's log): ~850 MB of title buffers snapshotted a frame,
# pooled up to 1024 buffers, with 2 frames in the air (RELAY=2); textures past their line while render
# targets hold ~2 GB.
$fewSnaps = @{ VICTORY_SNAPSHOT_POOL = '32'; VICTORY_KEEP_SNAPSHOTS_MB = '64'; VICTORY_RELAY = '1' }
$lessTex = @{ VICTORY_LEVELS_ON_DEMAND = '1'; VICTORY_UPLOAD_AHEAD = '0'; VICTORY_TEXTURE_KEEP = '0'; VICTORY_DSTORAGE_STAGING_MB = '64' }
if ($Round -eq 5) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'N-L-snaps'      = @{ More = $noCard + $ported + $lazy + $fewSnaps; Args = @{} }
        'O-N-tex35'      = @{ More = $noCard + $ported + $lazy + $fewSnaps + $lessTex + @{ VICTORY_TEXTURE_ROOM_PERCENT = '35' }; Args = @{} }
        'P-O-fps30'      = @{ More = $noCard + $ported + $lazy + $fewSnaps + $lessTex + @{ VICTORY_TEXTURE_ROOM_PERCENT = '35' }; Args = @{ Fps = 30 } }
    }
}
# Round 6: N sat on the start screen for 4 minutes (11 draws, 5.8 GB); O/P (fewer textures) were worse.
# The snapshot cap again, with and without one frame in the air.
$snapsOnly = @{ VICTORY_SNAPSHOT_POOL = '32'; VICTORY_KEEP_SNAPSHOTS_MB = '64' }
if ($Round -eq 6) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'Q-L-snapsonly' = @{ More = $noCard + $ported + $lazy + $snapsOnly; Args = @{} }
        'R-N-again'     = @{ More = $noCard + $ported + $lazy + $fewSnaps; Args = @{} }
    }
}
# Round 7: run L in the diagnostics build, whose memory line says what holds the card's memory by kind.
if ($Round -eq 7) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'S-L-diag' = @{ More = $noCard + $ported + $lazy + @{ VICTORY_MEMORY_MAP = '0' }; Args = @{ Build = 'diag' } }
    }
}
# Round 8: the diag memory line of S: the card 7460 MB of a 6522 MB budget; host textures 1650 MB, but host
# copies of title memory 3326 MB, of them 2496 MB in 4 MiB windows of which ~1135 MB is ever asked for.
# Finer windows, tails, and windows placed over title memory instead of copied (INPLACE=1; 2 is unsafe
# with this build's LATE_WAIT=2).
$windows = @{ VICTORY_WINDOW_KB = '256'; VICTORY_WINDOW_TAILS = '1' }
if ($Round -eq 8) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'T-L-windows'      = @{ More = $noCard + $ported + $lazy + $windows; Args = @{} }
        'U-T-inplace'      = @{ More = $noCard + $ported + $lazy + $windows + @{ VICTORY_INPLACE = '1' }; Args = @{} }
        'V-U-diag'         = @{ More = $noCard + $ported + $lazy + $windows + @{ VICTORY_INPLACE = '1'; VICTORY_MEMORY_MAP = '0' }; Args = @{ Build = 'diag' } }
    }
}
# Round 9: V's memory line: windows 1978 MB on the 256 KiB grid (1113 MB ever copied), snapshot buffers kept
# 442 MB, host textures 2577 MB. The two cheap cuts together, and the finest window grid.
if ($Round -eq 9) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'W-T-snaps'   = @{ More = $noCard + $ported + $lazy + $windows + $snapsOnly; Args = @{} }
        # (Not `+ @{ VICTORY_WINDOW_KB = ... }`: adding a key twice throws, and the round ran round 1's list.)
        'X-W-64k'     = @{ More = $noCard + $ported + $lazy + $snapsOnly + @{ VICTORY_WINDOW_KB = '64'; VICTORY_WINDOW_TAILS = '1' }; Args = @{} }
    }
}
# Round 10: idle textures that only descriptor slots hold are let go over the card's line too
# (VICTORY_EVICT_SHOWN=1, new): their slots go null and are queued again.
$evict = @{ VICTORY_EVICT_SHOWN = '1' }
if ($Round -eq 10) {
    $base = @{ VICTORY_TEXTURE_ROOM_PERCENT = '50' }
    $variants = [ordered]@{
        'Y-W-evict'      = @{ More = $noCard + $ported + $lazy + $windows + $snapsOnly + $evict; Args = @{} }
        'Z-Y-diag'       = @{ More = $noCard + $ported + $lazy + $windows + $snapsOnly + $evict + @{ VICTORY_MEMORY_MAP = '0' }; Args = @{ Build = 'diag' } }
    }
}

function Stop-Game { Get-Process victory -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
function Free-GB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2) }

if (-not (Test-Path $csv)) { 'time,variant,result,seconds,peak_private_gb,min_free_gb,card_peak_mb,budget_after_mb,error,max_draws,world_at_s' | Set-Content $csv -Encoding ascii }
elseif (-not ((Get-Content $csv -TotalCount 1) -match 'max_draws')) {
    $old = Get-Content $csv; ($old[0] + ',max_draws,world_at_s') | Set-Content $csv -Encoding ascii; $old | Select -Skip 1 | Add-Content $csv -Encoding ascii
}

foreach ($name in $variants.Keys) {
    if ($Only -and -not ($Only | Where-Object { $name -like "$_*" })) { continue }
    $v = $variants[$name]
    $more = @{} + $base; foreach ($k in $v.More.Keys) { $more[$k] = $v.More[$k] }
    Stop-Game
    # Let RAM come back before each start (up to 60 s).
    for ($i = 0; $i -lt 12 -and (Free-GB) -lt 8; $i++) { Start-Sleep 5 }
    Write-Host ("==== {0}  free {1} GB  switches: {2}" -f $name, (Free-GB), (($more.GetEnumerator() | Sort Name | % { "$($_.Name)=$($_.Value)" }) -join ' '))

    $began = Get-Date
    $job = Start-Job -ScriptBlock {
        param($play, $exe, $more, $extra)
        $a = @{ Exe = $exe; SeriesS = $true; Dlss = 'off'; NoFrameGenReady = $true; More = $more } + $extra
        & $play @a *> $null
    } -ArgumentList $play, $exe, $more, $v.Args

    # (Doubles, not ints: [math]::Max(int, double) picks the int overload and rounds to whole GB.)
    $log = $null; [double]$peak = 0; [double]$minFree = 99; $result = 'survived'; $err = ''; $draws = 0; $worldAt = $null
    while ($true) {
        Start-Sleep 5
        if (-not $log) { $log = Get-ChildItem $logs -Filter 'victory-nvidia-*.log' | Where-Object { $_.CreationTime -ge $began.AddSeconds(-2) } | Sort CreationTime | Select -First 1 -ExpandProperty FullName }
        $p = Get-Process victory -ErrorAction SilentlyContinue | Sort PrivateMemorySize64 -Desc | Select -First 1
        if ($p) { $peak = [math]::Max($peak, [math]::Round($p.PrivateMemorySize64 / 1GB, 2)) }
        # The world draws thousands a frame; loading screens and menus about 1-11.
        $w = Get-Process victory -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match '(\d+) draws' } | Select -First 1
        if ($w -and $w.MainWindowTitle -match '(\d+) draws') { $draws = [math]::Max($draws, [int]$Matches[1]); if ($draws -ge 1000 -and -not $worldAt) { $worldAt = [int]((Get-Date) - $began).TotalSeconds; Write-Host "     WORLD reached at $worldAt s ($draws draws/frame)" } }
        $minFree = [math]::Min($minFree, (Free-GB))
        $secs = [int]((Get-Date) - $began).TotalSeconds
        if ($log -and (Select-String -LiteralPath $log -Pattern 'host GPU failure' -Quiet)) {
            $result = 'device-lost'
            $err = ((Select-String -LiteralPath $log -Pattern 'host GPU failure' | Select -First 1).Line -replace '^.*?host GPU failure:\s*', '' -replace '[;,].*$', '')
            break
        }
        if ($secs -gt 30 -and -not $p) { $result = 'exited'; break }
        if ($secs -ge $SurviveMinutes * 60) { break }
        if ($secs -gt 300 + $SurviveMinutes * 60) { $result = 'timeout'; break }
    }
    Start-Sleep 2; Stop-Game; Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue

    $card = 0; $after = ''
    if ($log) {
        $m = Select-String -LiteralPath $log -Pattern 'the card has (\d+) MB in use' ; if ($m) { $card = ($m | % { [int]$_.Matches[0].Groups[1].Value } | Measure -Max).Maximum }
        $b = Select-String -LiteralPath $log -Pattern 'changed the budget of the card.s memory from \d+ MB to (\d+) MB' | Select -Last 1; if ($b) { $after = $b.Matches[0].Groups[1].Value }
    }
    $row = '{0},{1},{2},{3},{4},{5},{6},{7},"{8}",{9},{10}' -f (Get-Date -Format s), $name, $result, $secs, $peak, $minFree, $card, $after, $err, $draws, $worldAt
    Add-Content $csv $row -Encoding ascii
    Write-Host "     -> $result after $secs s, world at $(if ($worldAt) { "$worldAt s" } else { 'never' }), most draws/frame $draws, peak private $peak GB, min free $minFree GB, card peak $card MB"
}
Stop-Game
Write-Host ''; Write-Host '==== results'; Import-Csv $csv | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host 'LOOP DONE'
