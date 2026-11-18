<#
  AulumicNS - finds unused code. Every routine, constant (uAppStrings, uAppConsts,
  ALAudioTypes) and unit of src\ is counted by where its name is used: the program
  (src + AulumicNS.lpr), the tests (Tests\) and the simulator (Tools\AudioSim); strings and
  comments are left out (one left-to-right pass: a "{" inside a string stays a string).
  A routine is unused when its name appears only at its declaration and its body (a helper of
  the implementation part: only at its body). COM interface methods are not listed (they keep
  the method table's order and must stay).
    powershell -ExecutionPolicy Bypass -File Tools\FindUnusedCode.ps1 [-Out unused.csv]
  Prints a summary; -Out writes every counted name with its counts (CSV).
  Not a proof: a name used only through a string (RTTI) would count as unused, a common
  name (Clear, Add) used elsewhere hides an unused one. Build and run the tests after
  removing anything (milestone clean-up, 2026-11-10: about 1,100 lines went this way).
#>
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)), [string]$Out = '')
$ErrorActionPreference = 'Stop'

$script:LexRe = New-Object System.Text.RegularExpressions.Regex("'(?:[^'\r\n]|'')*'|\{[^}]*\}|\(\*[\s\S]*?\*\)|//[^\r\n]*")
$script:LexEval = [System.Text.RegularExpressions.MatchEvaluator]{
  param($m)
  if ($m.Value.StartsWith("'")) { return "''" }
  return ($m.Value -replace '[^\r\n]', '')
}
function Strip([string]$t) { return $script:LexRe.Replace($t, $script:LexEval) }

function Tokens([string[]]$files) {
  $h = @{}
  foreach ($f in $files) {
    $t = Strip ([IO.File]::ReadAllText($f))
    foreach ($m in [regex]::Matches($t, '\b[A-Za-z_][A-Za-z0-9_]*\b')) {
      $k = $m.Value.ToLowerInvariant()
      if ($h.ContainsKey($k)) { $h[$k]++ } else { $h[$k] = 1 }
    }
  }
  return $h
}

$src   = @(Get-ChildItem -LiteralPath "$Root\src" -Recurse -File | Where-Object { $_.Extension -in '.pas','.inc' } | ForEach-Object FullName) + "$Root\AulumicNS.lpr"
$tests = @(Get-ChildItem -LiteralPath "$Root\Tests" -Recurse -File | Where-Object { $_.Extension -in '.pas','.lpr' } | Where-Object { $_.FullName -notmatch '\\lib\\' } | ForEach-Object FullName)
$tools = @(Get-ChildItem -LiteralPath "$Root\Tools\AudioSim" -Recurse -File | Where-Object { $_.Extension -in '.pas','.lpr' } | Where-Object { $_.FullName -notmatch '\\lib\\' } | ForEach-Object FullName)
$TS = Tokens $src; $TT = Tokens $tests; $TL = Tokens $tools

$rows = New-Object System.Collections.Generic.List[object]
$skipNames = 'create','destroy','execute','paint','dopaint','resize','keydown','keyup','mousedown','mouseup','mousemove','wndproc','loaded','click'
foreach ($f in (Get-ChildItem -LiteralPath "$Root\src" -Recurse -File | Where-Object { $_.Extension -eq '.pas' })) {
  $rel = $f.FullName.Substring($Root.Length + 1)
  $lines = (Strip ([IO.File]::ReadAllText($f.FullName))) -split "`n"
  $inImpl = $false
  $inIntf = $false        # inside "= interface(...)"
  $declared = @{}
  foreach ($l in $lines) {
    if ($l -match '^\s*implementation\b') { $inImpl = $true }
    if ($l -match '=\s*(dispinterface|interface)\s*(\(|$)') { $inIntf = $true }
    if ($inIntf -and ($l -match '^\s*end\s*;')) { $inIntf = $false; continue }
    $m = [regex]::Match($l, '^\s*(?:class\s+)?(function|procedure)\s+([A-Za-z_]\w*)\s*[\(;:]')
    if ($m.Success -and ($l -notmatch '\b(override|message|forward)\b')) {
      $n = $m.Groups[2].Value; $k = $n.ToLowerInvariant()
      if ($skipNames -contains $k) { continue }
      if (-not $inImpl) {
        if ($inIntf) { $where = 'com' }
        elseif ($l -match '^(function|procedure)\s') { $where = 'global' }
        else { $where = 'method' }
        $declared[$k] = $true
      }
      elseif ($l -match '^(function|procedure)\s') {
        if ($declared.ContainsKey($k)) { continue }      # the body of an interface routine
        if ($l -match '\bexternal\b') { $where = 'import' } else { $where = 'local' }
      }
      else { continue }
      $rows.Add([pscustomobject]@{ Kind = 'routine'; Where = $where; Name = $n; Unit = $rel; Src = $TS[$k]; Tests = [int]$TT[$k]; Tools = [int]$TL[$k] })
    }
  }
}
foreach ($u in 'src\app\uAppStrings.pas', 'src\app\uAppConsts.pas', 'src\audio\ALAudioTypes.pas') {
  $t = Strip ([IO.File]::ReadAllText("$Root\$u"))
  foreach ($m in [regex]::Matches($t, '(?m)^\s{2,}([A-Z][A-Z0-9_]+)\s*(?::\s*[^=;]+)?=')) {
    $n = $m.Groups[1].Value; $k = $n.ToLowerInvariant()
    $rows.Add([pscustomobject]@{ Kind = 'const'; Name = $n; Unit = $u; Src = $TS[$k]; Tests = [int]$TT[$k]; Tools = [int]$TL[$k] })
  }
}
foreach ($f in (Get-ChildItem -LiteralPath "$Root\src" -Recurse -File | Where-Object { $_.Extension -eq '.pas' })) {
  $n = $f.BaseName; $k = $n.ToLowerInvariant()
  $rows.Add([pscustomobject]@{ Kind = 'unit'; Name = $n; Unit = $f.FullName.Substring($Root.Length + 1); Src = $TS[$k]; Tests = [int]$TT[$k]; Tools = [int]$TL[$k] })
}
if ($Out) { $rows | Export-Csv -NoTypeInformation -Path $Out }

function IsUnused($x) {
  if ($x.Kind -eq 'const') { return ([int]$x.Src -le 1) }
  if ($x.Kind -ne 'routine' -or $x.Where -eq 'com') { return $false }
  if ($x.Where -in 'global', 'method') { return ([int]$x.Src -le 2) }
  return ([int]$x.Src -le 1)
}
$unused   = @($rows | Where-Object { (IsUnused $_) -and [int]$_.Tests -eq 0 -and [int]$_.Tools -eq 0 })
$testOnly = @($rows | Where-Object { (IsUnused $_) -and [int]$_.Tests -gt 0 })
"Counted: {0} routines, {1} constants, {2} units" -f @($rows | Where-Object Kind -eq 'routine').Count, @($rows | Where-Object Kind -eq 'const').Count, @($rows | Where-Object Kind -eq 'unit').Count
"Unused, by area:"
$unused | Group-Object { if ($_.Unit -match '\\tags\\') { 'tags (AulumicTag source)' } elseif ($_.Unit -match 'AuGdip|ALWasapiApi') { 'API bindings' } elseif ($_.Unit -match '\\gui\\') { 'GUI library (Aulos)' } else { 'program' } } |
  ForEach-Object { "  {0,-26} {1,4}" -f $_.Name, $_.Count }
"In the program's own code:"
$unused | Where-Object { $_.Unit -notmatch '\\tags\\|AuGdip|ALWasapiApi|\\gui\\' } | ForEach-Object { "  {0} {1} [{2}]" -f $_.Kind, $_.Name, $_.Unit }
"Used only by the tests: {0}" -f $testOnly.Count
$testOnly | ForEach-Object { "  {0} {1} [{2}]" -f $_.Kind, $_.Name, $_.Unit }
