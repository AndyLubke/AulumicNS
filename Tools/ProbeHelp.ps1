<#
  Checks the help window with the real window: copies the debug build to a
  scratch folder, runs it with --help-probe and prints the report.

  The probe (AuHelp.RunHelpProbe) scrolls through the whole help text down
  and up, by program and with the mouse wheel; goes to every topic; pulls the
  window to many sizes, maximizes and restores it; drags the lower edge of
  the picture panel with the real mouse; enlarges the picture; changes the
  text size; hides and shows the window. At every step it checks that the
  picture of the section at the top of the text is the one shown, that it is
  really on the screen, and that a topic's heading stands under the picture.

  Real mouse input for a few seconds (the pointer moves); the help window is
  in front for about two minutes. AulumicNS must not be running.
  Exit code = number of failed checks (100+ = the run itself failed).
  Run it after a change to AuHelp or to the help text's pictures.
#>
param([switch]$NoBuild, [int]$TimeoutSec = 900)

$proj = Split-Path -Parent $PSScriptRoot
if (Get-Process AulumicNS -ErrorAction SilentlyContinue) { 'AulumicNS is running: close it first'; exit 100 }
if (-not $NoBuild) {
  $b = & C:\Lazarus\lazbuild.exe --build-mode=Debug (Join-Path $proj 'AulumicNS.lpi') 2>&1
  $b | Select-String 'Error:|Fatal:' | ForEach-Object { $_.Line }
  if ($LASTEXITCODE -ne 0) { 'the debug build failed'; exit 101 }
}
$work = Join-Path $env:TEMP ('AulumicNS-helpprobe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
try {
  Copy-Item (Join-Path $proj 'bin\Debug\AulumicNS.exe') $work
  $report = Join-Path $work 'report.txt'
  $p = Start-Process (Join-Path $work 'AulumicNS.exe') -ArgumentList "`"--help-probe=$report`"" -PassThru
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); 'the probe timed out'; exit 102 }
  if (Test-Path $report) { Get-Content $report } else { 'no report was written'; exit 103 }
  $h = Join-Path $work 'heaptrc.log'
  if (Test-Path $h) { Get-Content $h | Select-String 'unfreed memory blocks' | ForEach-Object { 'heaptrc: ' + $_.Line } }
  "exit code: $($p.ExitCode)"
  exit $p.ExitCode
}
finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
