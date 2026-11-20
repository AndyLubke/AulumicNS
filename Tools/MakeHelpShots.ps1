<#
  Makes the screenshots of the help and the resource file that builds the
  help into the exe:
    1. builds the debug version (skip with -NoBuild)
    2. writes the made-up demo library (--make-demo-library) into help\work;
       it is shown as a drive letter of its own (subst, removed at the end),
       so the paths in the screenshots are short and name nothing of this PC
    3. runs --shots at 150 % (--shot-dpi=144) with that library
    4. copies the screenshots the help text uses (![caption](name) lines of
       help\AulumicNS_help.md, with or without {markers} behind them) into
       help\shots and shrinks them, and with them anchors.txt: where the
       parts of the main window are in its pictures
       (Tools\ShrinkPng.ps1: 256 colours, optimal PNG filters and deflate;
       2.5 MB -> about 1 MB, agreed 2026-11-11; -Colors 0 keeps them lossless)
    5. writes AulumicNS_help.rc: the help text and those screenshots
  Then build the release version: the help is inside the exe.
  Exit code: 0 = done, else the number of missing screenshots (or 100+ for a
  failed step).
#>
param([switch]$NoBuild, [int]$TimeoutSec = 300, [switch]$KeepWork, [int]$Colors = 256)

$proj = Split-Path -Parent $PSScriptRoot
$help = Join-Path $proj 'help'
$work = Join-Path $help 'work'
$shotsOut = Join-Path $help 'shots'
$md = Join-Path $help 'AulumicNS_help.md'
$rc = Join-Path $proj 'AulumicNS_help.rc'

if (-not $NoBuild) {
  $b = & C:\Lazarus\lazbuild.exe --build-mode=Debug (Join-Path $proj 'AulumicNS.lpi') 2>&1
  $b | Select-String 'Error:|Fatal:' | ForEach-Object { $_.Line }
  if ($LASTEXITCODE -ne 0) { 'the debug build failed'; exit 100 }
}

if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force "$work\run", "$work\lib" | Out-Null
Copy-Item "$proj\bin\Debug\AulumicNS.exe" "$work\run\"

# a free drive letter for the library
$drive = $null
foreach ($l in 'MNOPQRSTUVWXYZ'.ToCharArray()) {
  if (-not (Test-Path "${l}:\")) { $drive = "${l}:"; break }
}
$libRoot = "$work\lib"
$subst = $false
if ($drive) {
  subst $drive "$work\lib"
  if ($LASTEXITCODE -eq 0) { $subst = $true; $libRoot = "$drive\" }
}
$failed = 0
try {
  $p = Start-Process "$work\run\AulumicNS.exe" -ArgumentList "`"--make-demo-library=$libRoot`"" -PassThru -Wait
  if ($p.ExitCode -ne 0) { 'the demo library could not be written'; $failed = 101 }
  else {
    $lib = Join-Path $libRoot 'Demo Music'
    $args = @("`"--shots=$work\shots`"", "`"--add-folder=$lib`"", '--shot-dpi=144')
    $p = Start-Process "$work\run\AulumicNS.exe" -ArgumentList $args -PassThru -WorkingDirectory "$work\run"
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); 'the screenshots timed out'; $failed = 102 }
    else {
      $h = Join-Path "$work\run" 'heaptrc.log'
      if (Test-Path $h) { Get-Content $h | Select-String 'unfreed memory blocks' | ForEach-Object { $_.Line } }
    }
  }
}
finally {
  if ($subst) { subst $drive /d | Out-Null }
}
if ($failed -ne 0) { exit $failed }

# the screenshots of the help text
$names = Select-String -Path $md -Pattern '^\s*!\[[^\]]*\]\(([^)]+)\)\s*(\{[^}]*\})?\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
  Select-Object -Unique
if (Test-Path $shotsOut) { Remove-Item $shotsOut -Recurse -Force }
New-Item -ItemType Directory -Force $shotsOut | Out-Null
$missing = 0
$lines = @('AULUMICNSHELP RCDATA "help\\AulumicNS_help.md"')
foreach ($n in $names) {
  $src = Join-Path "$work\shots" "$n.png"
  if (-not (Test-Path $src)) { "missing: $n"; $missing++; continue }
  Copy-Item $src (Join-Path $shotsOut "$n.png")
  $res = ('HELPIMG_' + $n.ToUpperInvariant()) -replace '[^A-Z0-9_]', '_'
  $lines += "$res RCDATA `"help\\shots\\$n.png`""
}
# where the parts of the main window are in its pictures (the markers of the help)
$anchors = Join-Path "$work\shots" 'anchors.txt'
if (Test-Path $anchors) {
  Copy-Item $anchors (Join-Path $shotsOut 'anchors.txt')
  $lines += 'AULUMICNSHELPANCHORS RCDATA "help\\shots\\anchors.txt"'
} else { 'no anchors.txt: markers at named places will be missing' }
$shrunk = & (Join-Path $PSScriptRoot 'ShrinkPng.ps1') -Folder $shotsOut -Colors $Colors
$shrunk | Select-Object -Last 1
$enc = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($rc, ($lines -join "`r`n") + "`r`n", $enc)
$all = Get-ChildItem $shotsOut -Filter *.png
"{0} screenshots in help\shots ({1:N1} MB); {2} written" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB), (Split-Path $rc -Leaf)
if (-not $KeepWork) { Remove-Item $work -Recurse -Force }
exit $missing
