<#
  AulumicNS - ProbeTouch.ps1

  Checks touch scrolling without a touch screen, and that the mouse wheel and
  the scroll bars still work. The checks are in the debug build itself
  (src\app\AuTouchProbe.pas, switch --touch-probe=<report>): Windows' touch
  injection (InjectTouchInput, Windows 8 and later, no touch hardware needed)
  puts a simulated finger on the screen, Windows' own gesture recognition
  turns its moves into the WM_GESTURE / GID_PAN messages a touch screen
  gives; the mouse checks use real input (SendInput). Each check compares the
  control's scroll position before and after.

  It checks: the playlist, the library tree, a Preferences page (the swipe
  starts on a setting), the help and a booklet (swipes turn one page).

  The script copies the debug exe to a scratch folder (its Data\ stays apart
  from bin\Debug\Data), writes the demo library there for a booklet PDF, runs
  the probe and prints the report and the end of heaptrc.log.

  NOTE: this is real input on the desktop for about half a minute (the
  windows come to the front, the mouse pointer moves and is put back);
  do not use the mouse or the keyboard meanwhile.
  Usage: & .\Tools\ProbeTouch.ps1 [-Exe <debug exe>]     Exit code = failures.
#>
param([string]$Exe = "$PSScriptRoot\..\bin\Debug\AulumicNS.exe")

$ErrorActionPreference = 'Stop'
# one AulumicNS at a time: a running copy would get the probe handed over
if (Get-Process AulumicNS -ErrorAction SilentlyContinue) { 'AulumicNS is running: close it first.'; exit 100 }
if (-not (Test-Path $Exe)) { "No debug build at $Exe"; exit 101 }

$work = Join-Path $env:TEMP 'AulumicNS_ProbeTouch'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force "$work\run", "$work\lib" | Out-Null
$exeCopy = "$work\run\AulumicNS.exe"
Copy-Item $Exe $exeCopy

# a booklet: the demo library has PDF booklets
$null = Start-Process $exeCopy -ArgumentList "`"--make-demo-library=$work\lib`"" -PassThru -Wait
$pdf = Get-ChildItem "$work\lib" -Recurse -Filter *.pdf | Select-Object -First 1
# the demo library run leaves its heaptrc.log; the probe's own is checked below
Remove-Item "$work\run\heaptrc.log" -ErrorAction SilentlyContinue

$report = "$work\touch-report.txt"
$probeArgs = @("`"--touch-probe=$report`"")
if ($pdf) { $probeArgs += "`"--touch-pdf=$($pdf.FullName)`"" }
$p = Start-Process $exeCopy -ArgumentList $probeArgs -WorkingDirectory "$work\run" -PassThru
if (-not $p.WaitForExit(180000)) {
  $p.Kill()
  'The probe did not finish in 3 minutes (killed). It came this far:'
  if (Test-Path $report) { Get-Content $report }
  exit 102
}
$code = $p.ExitCode

if (Test-Path $report) { Get-Content $report } else { 'No report was written.' }
$heap = "$work\run\heaptrc.log"
if (Test-Path $heap) {
  $last = (Get-Content $heap | Where-Object { $_ -match 'unfreed memory blocks' } | Select-Object -Last 1)
  "heaptrc: $last"
  if ($last -notmatch '^0 unfreed') { $code++ }
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
"exit code: $code"
exit $code
