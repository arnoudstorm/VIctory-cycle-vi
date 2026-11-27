# Captures the game window to a PNG, and optionally first sends keys to it.
# -Keys: SendKeys codes in order, e.g. '{DOWN}','{ENTER}','{ESC}'; -Gap ms between keys.
# -Press: virtual-key names held down for -Down ms each (Esc, Enter, Up, Down, Left, Right, Tab, Back), for slow frame rates.
param([Parameter(Mandatory)][string]$Out, [string[]]$Keys = @(), [string[]]$Press = @(), [int]$Down = 1500, [int]$Gap = 400, [int]$Hold = 600)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
'@
[W]::SetProcessDPIAware() | Out-Null
$p = Get-Process victory* -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { 'no game window'; exit 1 }
$h = $p.MainWindowHandle
[W]::ShowWindow($h, 9) | Out-Null
[W]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0001 -bor 0x0004) | Out-Null
[W]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300
foreach ($k in $Keys) { [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds $Gap }
$Press = @($Press | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$vk = @{ Esc = 0x1B; Enter = 0x0D; Up = 0x26; Down = 0x28; Left = 0x25; Right = 0x27; Tab = 0x09; Back = 0x08 }
foreach ($k in $Press) { $c = if ($vk.ContainsKey($k)) { [byte]$vk[$k] } else { [byte][char]$k.ToUpper() }; [W]::keybd_event($c, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds $Down; [W]::keybd_event($c, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds $Gap }
if ($Keys -or $Press) { Start-Sleep -Milliseconds $Hold }
$r = New-Object W+R
[W]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Ri - $r.L; $hgt = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$small = New-Object System.Drawing.Bitmap $bmp, ([int]($w / 2)), ([int]($hgt / 2))
$small.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out ($w x $hgt); title: $($p.MainWindowTitle)"
