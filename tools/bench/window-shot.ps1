# Captures the game window's content with PrintWindow (PW_RENDERFULLCONTENT) without
# focusing, moving or raising it, at half size. Exit 1 when there is no game window.
param([Parameter(Mandatory)][string]$Out, [string]$ProcessName = 'victory*')
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class P {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[P]::SetProcessDPIAware() | Out-Null
$p = Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { exit 1 }
$r = New-Object P+R
[P]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.Ri - $r.L; $h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { exit 1 }
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
$ok = [P]::PrintWindow($p.MainWindowHandle, $dc, 2)
$g.ReleaseHdc($dc)
$small = New-Object System.Drawing.Bitmap $bmp, ([int]($w / 2)), ([int]($h / 2))
$small.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
if (-not $ok) { exit 2 }
