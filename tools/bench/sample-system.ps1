# Samples the system every $Every seconds while the game process runs and writes a CSV.
# Columns: time, total CPU %, GPU 3D engine % (all adapters, summed), available RAM MB,
# game private MB, game working set MB, game CPU % (of all cores), the game's GPU memory
# (dedicated and shared, from "GPU Process Memory"), system committed MB, hard page
# reads+writes per second (Pages/sec), game threads and handles.
# Temperatures are not exposed by Windows for this CPU/GPU without vendor tools: not sampled.
param([Parameter(Mandatory)][string]$Out, [string]$ProcessName = "victory", [int]$Every = 2, [int]$WaitStart = 60)

$t0 = Get-Date
while (-not (Get-Process $ProcessName -ErrorAction SilentlyContinue)) {
    if (((Get-Date) - $t0).TotalSeconds -gt $WaitStart) { exit 1 }
    Start-Sleep -Milliseconds 500
}
"time,cpu_total_pct,gpu_3d_pct,ram_available_mb,victory_private_mb,victory_working_set_mb,victory_cpu_pct,gpu_dedicated_mb,gpu_shared_mb,committed_mb,pages_per_s,threads,handles" |
    Out-File -Encoding utf8 $Out
$cores = [Environment]::ProcessorCount
$prev = $null
$counters = '\Processor(_Total)\% Processor Time', '\Memory\Available MBytes', '\Memory\Committed Bytes', '\Memory\Pages/sec'
while ($p = Get-Process $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $now = Get-Date
    $cpu = $avail = $commit = $pages = ''
    try {
        $c = (Get-Counter -Counter $counters -ErrorAction Stop).CounterSamples
        $cpu = [math]::Round($c[0].CookedValue, 1)
        $avail = [int]$c[1].CookedValue
        $commit = [int]($c[2].CookedValue / 1MB)
        $pages = [int]$c[3].CookedValue
    } catch {}
    $gpu = $ded = $sh = ''
    try {
        $g = (Get-Counter -Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples |
            Measure-Object CookedValue -Sum
        $gpu = [math]::Round([math]::Min(100, $g.Sum), 1)
    } catch {}
    try {
        $m = (Get-Counter -Counter "\GPU Process Memory(pid_$($p.Id)*)\Dedicated Usage", "\GPU Process Memory(pid_$($p.Id)*)\Shared Usage" -ErrorAction Stop).CounterSamples
        $ded = [int](($m | Where-Object Path -like '*dedicated usage' | Measure-Object CookedValue -Sum).Sum / 1MB)
        $sh = [int](($m | Where-Object Path -like '*shared usage' | Measure-Object CookedValue -Sum).Sum / 1MB)
    } catch {}
    $vcpu = ''
    if ($prev) {
        $dt = ($now - $prev.Time).TotalSeconds
        if ($dt -gt 0) { $vcpu = [math]::Round(100 * ($p.TotalProcessorTime - $prev.Cpu).TotalSeconds / ($dt * $cores), 1) }
    }
    $prev = @{ Time = $now; Cpu = $p.TotalProcessorTime }
    "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12}" -f $now.ToString('o'), $cpu, $gpu, $avail,
        [int]($p.PrivateMemorySize64 / 1MB), [int]($p.WorkingSet64 / 1MB), $vcpu, $ded, $sh, $commit, $pages,
        $p.Threads.Count, $p.HandleCount | Out-File -Append -Encoding utf8 $Out
    Start-Sleep -Seconds $Every
}
