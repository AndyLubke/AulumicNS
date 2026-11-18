# ProbeSessionEnd.ps1 - checks what AulumicNS does when Windows ends the session
# (shutdown, restart, log-off), without ending the session.
#
# Copies the debug build to %TEMP% (portable data there, nothing of the real
# program is touched), starts it and sends its main window the two messages
# Windows sends:
#   WM_QUERYENDSESSION  "may the session end?"  -> must answer 1 (yes), keep
#                       running and have saved its settings
#   WM_ENDSESSION       "it ends now"           -> must close by itself
# Then the end of heaptrc.log (0 unfreed memory blocks) and ShutdownTraceLog.txt
# (written only when a step of the close failed). Exit code = failures.
# AulumicNS must not be running (the copy would hand over to it and exit).
param([string]$Exe = "$PSScriptRoot\..\bin\Debug\AulumicNS.exe")

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public static class SessionProbe {
  [DllImport("user32.dll", SetLastError = true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr res);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  // every top-level window of the process, visible or not (Windows sends the
  // session messages to all of them; the LCL answers on its hidden
  // application window, not on the main form)
  public static IntPtr[] TopWindows(uint pid) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) list.Add(h); return true; }, IntPtr.Zero);
    return list.ToArray();
  }
  // the message to all of them; the number that answered in time, and
  // whether every answer was the wanted one
  public static int SendAll(uint pid, uint msg, IntPtr w, long want, out bool allWanted) {
    int n = 0; allWanted = true;
    foreach (var h in TopWindows(pid)) {
      IntPtr res;
      if (SendMessageTimeout(h, msg, w, IntPtr.Zero, 2, 20000, out res) != IntPtr.Zero) { n++; if (res.ToInt64() != want) allWanted = false; }
    }
    return n;
  }
}
"@

$fail = 0
function Check($name, $ok, $detail = '') {
  if ($ok) { "  ok    $name $detail" } else { "  FAIL  $name $detail"; $script:fail++ }
}

if (Get-Process AulumicNS -ErrorAction SilentlyContinue) { 'AulumicNS is running: close it first.'; exit 99 }
if (-not (Test-Path $Exe)) { "Not found: $Exe"; exit 99 }

$dir = Join-Path $env:TEMP ('AulumicNS_SessionEnd_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item $Exe $dir
$copy = Join-Path $dir 'AulumicNS.exe'
$ini = Join-Path $dir 'Data\AulumicNS.ini'
try {
  $p = Start-Process $copy -PassThru
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000 -and -not $p.HasExited) { Start-Sleep -Milliseconds 50; $p.Refresh() }
  Check 'the window is there' ($p.MainWindowHandle -ne 0)
  Start-Sleep -Seconds 3
  $p.Refresh()
  $h = $p.MainWindowHandle
  $before = if (Test-Path $ini) { (Get-Item $ini).LastWriteTimeUtc } else { [DateTime]::MinValue }
  Start-Sleep -Milliseconds 1100

  'WM_QUERYENDSESSION (to every top-level window of the program)'
  $all = $false
  $n = [SessionProbe]::SendAll([uint32]$p.Id, 0x0011, [IntPtr]::Zero, 1, [ref]$all)
  Check 'answered within 20 s' ($n -gt 0) "($n windows)"
  Check 'answer: the session may end' $all
  Start-Sleep -Milliseconds 500
  $p.Refresh()
  Check 'still running after the question' (-not $p.HasExited)
  $after = if (Test-Path $ini) { (Get-Item $ini).LastWriteTimeUtc } else { [DateTime]::MinValue }
  Check 'settings saved at the question' ($after -gt $before)

  'WM_ENDSESSION'
  $sw.Restart()
  $n = [SessionProbe]::SendAll([uint32]$p.Id, 0x0016, [IntPtr]1, 0, [ref]$all)
  Check 'answered within 20 s' ($n -gt 0) "($n windows, $($sw.ElapsedMilliseconds) ms)"
  $exited = $p.WaitForExit(20000)
  Check 'the program ended by itself' $exited "($($sw.ElapsedMilliseconds) ms after the message)"
  if (-not $exited) { Stop-Process -Id $p.Id -Force }

  $heap = Join-Path $dir 'heaptrc.log'
  if (Test-Path $heap) {
    $tail = Get-Content $heap | Where-Object { $_ -match 'unfreed memory blocks' } | Select-Object -Last 1
    Check 'no memory left behind' ($tail -match '^0 unfreed') "($tail)"
  } else { '  note  no heaptrc.log (not a debug build?)' }
  $trace = Join-Path $dir 'ShutdownTraceLog.txt'
  if (Test-Path $trace) {
    Check 'no failed step in the close' $false
    Get-Content $trace | Select-Object -Last 15 | ForEach-Object { "        $_" }
  } else { Check 'no failed step in the close' $true }
}
finally {
  Get-Process AulumicNS -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $copy } | Stop-Process -Force
  Start-Sleep -Milliseconds 300
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
"failures: $fail"
exit $fail
