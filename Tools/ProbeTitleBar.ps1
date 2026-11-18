# Starts AulumicNS (debug build), checks the custom title bar from outside:
# the hit test codes Windows gets (caption, icon, buttons, resize edges) and
# the client area in the normal and the maximized state. Closes it again.
# Usage: powershell -ExecutionPolicy Bypass -File Tools\ProbeTitleBar.ps1 [-Exe <path>]
param([string]$Exe = "$PSScriptRoot\..\bin\Debug\AulumicNS.exe")

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cb; public RECT rcMonitor, rcWork; public int flags; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr h, POINT p, uint f);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  public static void ClickChild(IntPtr top, int x, int y) { POINT p; p.X = x; p.Y = y; ScreenToClient(top, ref p); IntPtr c = ChildWindowFromPointEx(top, p, 1); POINT q; q.X = x; q.Y = y; ScreenToClient(c, ref q); IntPtr lp = (IntPtr)(((q.Y & 0xFFFF) << 16) | (q.X & 0xFFFF)); PostMessage(c, 0x200, IntPtr.Zero, lp); PostMessage(c, 0x201, (IntPtr)1, lp); PostMessage(c, 0x202, IntPtr.Zero, lp); }
  public static void ClickNcMax(IntPtr top, int x, int y) { IntPtr lp = (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF)); PostMessage(top, 0xA1, (IntPtr)9, lp); PostMessage(top, 0xA2, (IntPtr)9, lp); }
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO i);
  public static int Hit(IntPtr top, int x, int y) {
    POINT p; p.X = x; p.Y = y; ScreenToClient(top, ref p);
    IntPtr child = ChildWindowFromPointEx(top, p, 1);
    IntPtr lp = (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF));
    int r = -1;
    if (child != IntPtr.Zero && child != top) r = (int)SendMessage(child, 0x84, IntPtr.Zero, lp);
    if (r == -1) r = (int)SendMessage(top, 0x84, IntPtr.Zero, lp);
    return r;
  }
}
"@

# physical pixels, like the per-monitor aware program (otherwise the
# coordinates of this script are scaled by Windows)
[void][W]::SetThreadDpiAwarenessContext([IntPtr](-4))

$names = @{ -1='TRANSPARENT'; 1='CLIENT'; 2='CAPTION'; 3='SYSMENU'; 8='MINBUTTON'; 9='MAXBUTTON'; 10='LEFT'; 11='RIGHT'; 12='TOP'; 13='TOPLEFT'; 14='TOPRIGHT'; 15='BOTTOM'; 16='BOTTOMLEFT'; 17='BOTTOMRIGHT'; 20='CLOSE' }
$p = Start-Process -FilePath $Exe -PassThru
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 50 -and $h -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 200; $p.Refresh(); $h = $p.MainWindowHandle }
if ($h -eq [IntPtr]::Zero) { "no main window"; $p.Kill(); exit 1 }
Start-Sleep -Milliseconds 800
$fail = 0
function Check([string]$what, [int]$x, [int]$y, [int]$expect) {
  $r = [W]::Hit($h, $x, $y)
  $ok = if ($r -eq $expect) { 'ok  ' } else { $script:fail++; 'FAIL' }
  "{0} {1,-22} -> {2,-12} (expected {3})" -f $ok, $what, $names[$r], $names[$expect]
}
function Probe([string]$state) {
  $wr = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$wr)
  $cr = New-Object W+RECT; [void][W]::GetClientRect($h, [ref]$cr)
  $o = New-Object W+POINT; [void][W]::ClientToScreen($h, [ref]$o)
  $k = [W]::GetDpiForWindow($h) / 96.0
  "--- $state  (dpi scale $k) window top $($wr.T), client top $($o.Y), client $($cr.R)x$($cr.B)"
  $cx = $o.X + [int]($cr.R / 2); $ty = $o.Y + [int](17 * $k); $right = $o.X + $cr.R
  Check 'caption' $cx $ty 2
  Check 'icon' ($o.X + [int](20 * $k)) $ty 3
  Check 'minimize' ($right - [int](46 * 2.5 * $k)) $ty 1
  Check 'maximize' ($right - [int](46 * 1.5 * $k)) $ty 9
  Check 'close' ($right - [int](23 * $k)) $ty 1
  # AulumicNS: Preferences left of minimize (42 wide, 6 gap); the main menu next to the icon (from 42, 42 wide)
  Check 'preferences button' ($right - [int]((3 * 46 + 6 + 21) * $k)) $ty 1
  Check 'main menu button' ($o.X + [int](63 * $k)) $ty 1
  Check 'caption right of it' ($o.X + [int](110 * $k)) $ty 2
  Check 'caption left of it' ($right - [int]((3 * 46 + 6 + 63) * $k)) $ty 2
  Check 'banner' $cx ($o.Y + [int](120 * $k)) 1
  if ($state -eq 'normal') {
    Check 'top edge' $cx ($o.Y + 1) 12
    Check 'top-left corner' ($o.X + 2) ($o.Y + 1) 13
    Check 'top-right corner' ($right - 2) ($o.Y + 1) 14
    Check 'top edge over close' ($right - [int](23 * $k)) ($o.Y + 1) 12
    Check 'left border' ($wr.L + 3) ($o.Y + [int]($cr.B / 2)) 10
    Check 'bottom border' $cx ($wr.B - 3) 15
    if ($o.Y -ne $wr.T) { $script:fail++; "FAIL client area does not start at the window top" } else { "ok   client area starts at the window top (no Windows caption)" }
  } else {
    $mi = New-Object W+MONITORINFO; $mi.cb = [Runtime.InteropServices.Marshal]::SizeOf($mi)
    [void][W]::GetMonitorInfo([W]::MonitorFromWindow($h, 2), [ref]$mi)
    Check 'top edge (maximized)' $cx ($o.Y + 1) 2
    if (($o.Y -eq $mi.rcWork.T) -and ($o.X -eq $mi.rcWork.L)) { "ok   maximized client area starts at the work area ($($mi.rcWork.L),$($mi.rcWork.T))" }
    else { $script:fail++; "FAIL maximized client origin ($($o.X),$($o.Y)) <> work area ($($mi.rcWork.L),$($mi.rcWork.T))" }
  }
}
Probe 'normal'
[void][W]::ShowWindow($h, 3); Start-Sleep -Milliseconds 700
Probe 'maximized'
[void][W]::ShowWindow($h, 9); Start-Sleep -Milliseconds 500
# the buttons, clicked the way Windows delivers the clicks
function Btn([string]$which) {
  $cr = New-Object W+RECT; [void][W]::GetClientRect($h, [ref]$cr)
  $o = New-Object W+POINT; [void][W]::ClientToScreen($h, [ref]$o)
  $k = [W]::GetDpiForWindow($h) / 96.0
  $y = $o.Y + [int](17 * $k); $right = $o.X + $cr.R
  switch ($which) {
    'min' { [W]::ClickChild($h, $right - [int](46 * 2.5 * $k), $y) }
    'max' { [W]::ClickNcMax($h, $right - [int](46 * 1.5 * $k), $y) }
    'close' { [W]::ClickChild($h, $right - [int](23 * $k), $y) }
  }
  Start-Sleep -Milliseconds 700
}
Btn 'max'; if ([W]::IsZoomed($h)) { "ok   maximize button maximizes" } else { $fail++; "FAIL maximize button" }
Btn 'max'; if (-not [W]::IsZoomed($h)) { "ok   restore button restores" } else { $fail++; "FAIL restore button" }
Btn 'min'; if ([W]::IsIconic($h)) { "ok   minimize button minimizes" } else { $fail++; "FAIL minimize button" }
[void][W]::ShowWindow($h, 9); Start-Sleep -Milliseconds 700
Btn 'close'
if (-not $p.WaitForExit(15000)) { $p.Kill(); "killed" } else { "closed, exit code $($p.ExitCode)" }
"failures: $fail"
exit $fail
