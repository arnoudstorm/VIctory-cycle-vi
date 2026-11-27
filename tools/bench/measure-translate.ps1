# Runs `translate` over the game folder with the launcher's translation switches and
# records wall time, peak private and working-set memory (sampled every 500 ms).
param([string]$Exe = 'C:\Users\Arnou\victory-runs\cycle-vii\exe\victory-phase0-0e6e5eab-crtstatic.exe',
      [string]$Game = 'C:\Users\Arnou\Downloads\build', [string]$Out = 'C:\Users\Arnou\victory-runs\cycle-vii\data\shader-audit',
      [int]$Jobs = 4)
$env:VICTORY_SHADER_LOOP_LIMIT = '64'; $env:VICTORY_F16_NEAREST = '1'
$t0 = Get-Date
$p = Start-Process $Exe -ArgumentList 'translate', '--jobs', $Jobs, $Game -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput "$Out\translate.out" -RedirectStandardError "$Out\translate.err"
$peakPriv = 0; $peakWs = 0
while (-not $p.HasExited) {
    try { $p.Refresh(); $peakPriv = [math]::Max($peakPriv, $p.PrivateMemorySize64); $peakWs = [math]::Max($peakWs, $p.WorkingSet64) } catch {}
    Start-Sleep -Milliseconds 500
}
[ordered]@{ exe = $Exe; game = $Game; jobs = $Jobs; started = $t0.ToString('o'); seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  exit_code = $p.ExitCode; peak_private_mb = [int]($peakPriv / 1MB); peak_working_set_mb = [int]($peakWs / 1MB)
  cpu_seconds = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1) } | ConvertTo-Json | Out-File -Encoding utf8 "$Out\translate-measure.json"
Get-Content "$Out\translate-measure.json"
