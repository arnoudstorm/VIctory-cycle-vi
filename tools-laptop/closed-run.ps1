# Closes the Claude app and the browsers, then runs the loop's round 14 (the best switches) with the RAM
# they held. A run that survives is left running to play on. What happened: tools-laptop\closed-run.txt
# and a row in results.csv.
#   powershell -ExecutionPolicy Bypass -File tools-laptop\closed-run.ps1 [-DelaySeconds 20]
param([int]$DelaySeconds = 20, [double]$SurviveMinutes = 5)

$out = Join-Path $PSScriptRoot 'closed-run.txt'
"started $(Get-Date -Format s); closing apps in $DelaySeconds s" | Set-Content $out -Encoding ascii
Start-Sleep $DelaySeconds
Get-Process claude, chrome, msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 5
$os = Get-CimInstance Win32_OperatingSystem
"apps closed; free RAM {0:N1} GB" -f ($os.FreePhysicalMemory / 1MB) | Add-Content $out -Encoding ascii
& (Join-Path $PSScriptRoot 'optimize-loop.ps1') -Round 14 -SurviveMinutes $SurviveMinutes -KeepRunning *>> $out
"done $(Get-Date -Format s)" | Add-Content $out -Encoding ascii
