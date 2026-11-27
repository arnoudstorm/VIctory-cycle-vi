# One Cycle VII runtime test: launches the build through the laptop launcher with no
# console window, samples the system, waits for the process to end on its own (never
# restarts it) and records the run's metadata. Extra VICTORY_* settings: -Env @{K='V'}.
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Exe,
    [string]$Launcher = 'C:\Users\Arnou\VIctory-laptop\run-laptop.ps1',
    [string]$GameDir = 'C:\Users\Arnou\Downloads\build',
    [hashtable]$Env = @{},
    [int]$MaxMinutes = 30,
    [string[]]$LauncherArgs = @()
)
$root = 'C:\Users\Arnou\victory-runs\cycle-vii\data'
$dir = Join-Path $root $Name
New-Item -ItemType Directory -Force $dir | Out-Null
foreach ($k in $Env.Keys) { Set-Item "Env:$k" $Env[$k] }

$procName = [IO.Path]::GetFileNameWithoutExtension($Exe)
$hash = (Get-FileHash $Exe -Algorithm SHA256).Hash
$meta = [ordered]@{
    name = $Name; exe = $Exe; exe_sha256 = $hash; exe_bytes = (Get-Item $Exe).Length
    exe_written = (Get-Item $Exe).LastWriteTime.ToString('o'); extra_env = $Env; launcher_args = $LauncherArgs
    ram_available_mb_before = [int](Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    started = (Get-Date).ToString('o')
}
$sampler = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'sample-system.ps1'), '-Out', (Join-Path $dir 'system.csv'), '-ProcessName', $procName
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Launcher, '-GameDir', $GameDir, '-BuildPath', $Exe, '-NoCapture') + @($LauncherArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$launch = Start-Process powershell -WindowStyle Hidden -PassThru -WorkingDirectory (Split-Path $Launcher) -ArgumentList $argList `
    -RedirectStandardError (Join-Path $dir 'victory.log') -RedirectStandardOutput (Join-Path $dir 'launcher.out')
$t = Get-Date; $v = $null
while (-not $v -and ((Get-Date) - $t).TotalSeconds -lt 60) { $v = Get-Process $procName -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $v) { Start-Sleep -Milliseconds 300 } }
if (-not $v) { $meta.result = 'victory.exe did not start'; $meta | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 (Join-Path $dir 'run.json'); exit 1 }
$v.PriorityClass = 'High'
$meta.pid = $v.Id
$auditor = Start-Process python -WindowStyle Hidden -PassThru -ArgumentList '-I', (Join-Path $PSScriptRoot 'audit_live.py'), "`"$dir`"", $procName `
    -RedirectStandardError (Join-Path $dir 'auditor.err')
$capped = -not $v.WaitForExit($MaxMinutes * 60 * 1000)
if ($capped) { Stop-Process -Id $v.Id -Force; $meta.stopped_by_cap_minutes = $MaxMinutes }
$launch.WaitForExit(30000) | Out-Null
$auditor.WaitForExit(180000) | Out-Null
$meta.ended = (Get-Date).ToString('o')
$meta.runtime_s = [math]::Round(((Get-Date) - [datetime]$meta.started).TotalSeconds, 1)
$meta.launcher_exit = $launch.ExitCode
$log = Join-Path $dir 'victory.log'
$fail = Select-String -Path $log -Pattern '^VIctory: ' | Select-Object -Last 1
$meta.termination = if ($capped) { "stopped after the $MaxMinutes-minute cap" } elseif ($fail) { $fail.Line } else { 'process exited without a VIctory failure line' }
$meta | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 (Join-Path $dir 'run.json')
$meta.termination
