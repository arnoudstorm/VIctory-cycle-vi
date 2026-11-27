<#
Makes the benchmark save from the title's newest save, for bench-saved.sh.

Play until the character stands somewhere quiet in free gameplay (no cutscene coming,
no menu open), let the game save (an autosave, or a manual save), close the game, then:

  powershell -ExecutionPolicy Bypass -File capture-bench-save.ps1 [-Note "where it is"]

It copies the most recently written SARC* save into <runs>\bench-save. A save already
there is moved to bench-save-old-<time>, never deleted. The title's own save stays where
it is. -Name picks a save other than the newest.
#>
param(
    [string]$Runs = (Join-Path $env:USERPROFILE 'victory-runs\cycle-vii'),
    [string]$Name,
    [string]$Note = ''
)
$ErrorActionPreference = 'Stop'
$u = Join-Path $env:LOCALAPPDATA 'victory\data\7952987A\saves\0009000000000001\00000000-0000-0000-0000-00007952987a'
$saves = @(Get-ChildItem $u -Directory -Filter 'SARC*' | ForEach-Object {
    $newest = Get-ChildItem $_.FullName -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    [pscustomobject]@{ Dir = $_; Written = if ($newest) { $newest.LastWriteTime } else { $_.LastWriteTime } }
} | Sort-Object Written -Descending)
if (-not $saves.Count) { throw "no SARC save in $u" }
$pick = if ($Name) { $saves | Where-Object { $_.Dir.Name -eq $Name } | Select-Object -First 1 } else { $saves[0] }
if (-not $pick) { throw "no save named $Name; there are: $($saves.Dir.Name -join ', ')" }
if (Get-Process | Where-Object { $_.Name -like 'victory*' }) { throw 'a VIctory process is running: close the game first' }

$bench = Join-Path $Runs 'bench-save'
if (Test-Path $bench) {
    $old = Join-Path $Runs ('bench-save-old-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item $bench $old
    Write-Host "previous benchmark save kept in $old"
}
New-Item -ItemType Directory -Force $bench | Out-Null
Copy-Item -Recurse $pick.Dir.FullName $bench
$info = "$($pick.Dir.Name), written $($pick.Written.ToString('yyyy-MM-dd HH:mm')), captured $(Get-Date -Format 'yyyy-MM-dd HH:mm')$(if ($Note) { ": $Note" })"
Set-Content -Encoding utf8 (Join-Path $bench 'SAVE-INFO.txt') $info
Write-Host "benchmark save: $info"
if ($saves.Count -gt 1) { Write-Host "other saves present (not used): $(($saves | Select-Object -Skip 1).Dir.Name -join ', ')" }
