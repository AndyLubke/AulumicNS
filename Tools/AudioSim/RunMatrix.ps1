<#
  Runs AudioSim over a matrix of files x settings and prints a table.
    -Mode bench : decode + resample speed and the time per ASIO period / WASAPI buffer
    -Mode rt    : real-time runs against the simulated devices (slow: Secs each)
  -Files: paths (literal) of music files; -Exe Release|Debug.
  Example: Tools\AudioSim\RunMatrix.ps1 -Mode bench -Files (Get-Content files.txt)
#>
param(
  [ValidateSet('bench', 'rt', 'check')] [string]$Mode = 'bench',
  [string[]]$Files,
  [string]$Exe = 'Release',
  [double]$Secs = 10,
  [string[]]$Settings,
  [string]$Out = ''
)
$sim = Join-Path $PSScriptRoot "bin\AudioSim-$Exe.exe"
if (-not $Settings) {
  if ($Mode -eq 'bench') {
    $Settings = @(
      'off        |--resample=0 --out=asio --period=512',
      'up q2 int  |--rate44=352800 --rate48=384000 --q=2 --up=1 --out=asio --period=512',
      'up q0 lin  |--rate44=352800 --rate48=384000 --q=0 --up=0 --out=asio --period=512',
      'up q0 min  |--rate44=352800 --rate48=384000 --q=0 --up=2 --out=asio --period=512',
      'up q4 int  |--rate44=352800 --rate48=384000 --q=4 --up=1 --out=asio --period=512',
      'up 768 q2  |--rate44=705600 --rate48=768000 --q=2 --up=1 --out=asio --period=512',
      'down 88 q2 |--rate44=88200 --rate48=96000 --q=2 --down=2 --out=asio --period=512',
      'dsd>pcm    |--dop=0 --out=asio --period=512',
      'dsd>pcm up |--dop=0 --dsdresample=1 --rate44=352800 --rate48=384000 --out=asio --period=512')
  } else {
    $Settings = @(
      'asio512 r3  |--out=asio --period=512 --ring=3 --jitter=1000:5',
      'asio512 new |--out=asio --period=512 --ring=0 --jitter=1000:5',
      'wasapi      |--out=wasapi --jitter=1000:5')
  }
}
$rows = @()
foreach ($f in $Files) {
  if (-not (Test-Path -LiteralPath $f)) { "missing: $f"; continue }
  $name = Split-Path $f -Leaf
  if ($name.Length -gt 34) { $name = $name.Substring(0, 34) }
  foreach ($s in $Settings) {
    $label, $opts = $s.Split('|', 2)
    $a = @($Mode, "`"$f`"", "--secs=$Secs") + $opts.Trim().Split(' ')
    # (no Select-Object -First: it stops the pipeline under the running exe)
    $found = @(& $sim @a 2>&1 | Select-String 'RESULT')
    $line = $null
    if ($found.Count -gt 0) { $line = ($found | ForEach-Object { $_.Line }) -join ' ' }
    $kv = @{}
    if ($line) { foreach ($m in [regex]::Matches($line, '(\w+)=(\S*)')) { $kv[$m.Groups[1].Value] = $m.Groups[2].Value } }
    if ($Mode -eq 'bench') {
      $rows += [pscustomobject]@{ File = $name; Setting = $label.Trim(); In = "$($kv['in'])/$($kv['bits'])"; Out = $kv['out'];
        Create_ms = $kv['create_ms']; xRT = $kv['x_realtime']; Avg_ms = $kv['call_avg_ms']; P99_ms = $kv['call_p99_ms'];
        Max_ms = $kv['call_max_ms']; MaxPct = $kv['max_of_period']; Short = "$($kv['short'])/$($kv['short_before_end'])";
        Hash = $kv['hash']; Err = $kv['error'] }
    } elseif ($Mode -eq 'check') {
      $rows += [pscustomobject]@{ File = $name; Setting = $label.Trim(); Rate = $kv['rate']; Chunks = "$($kv['chunk1'])/$($kv['chunk2'])";
        Secs = $kv['seconds']; Mismatch = $kv['mismatches']; MaxDiff = $kv['max_diff']; Tails = "$($kv['tail_a'])/$($kv['tail_b'])";
        SineMax = $kv['sine_max_rel']; Outliers = $kv['sine_outliers']; Spikes = $kv['sine_spikes_s']; Err = $kv['error'] }
    } else {
      $rows += [pscustomobject]@{ File = $name; Setting = $label.Trim(); Rate = $kv['rate']; Period = $kv['period_frames'];
        Native = $kv['native_dsd']; Ring = $kv['ring']; Buffers = $kv['buffers'];
        Glitches = $kv['glitches']; Stalls = $kv['stalls']; MinMargin_ms = $kv['min_margin_ms']; FillMax_ms = $kv['fill_max_ms'];
        Ended = $kv['ended']; Cut_ms = $kv['cut_last_ms']; SineMax = $kv['sine_max_rel']; Outliers = $kv['sine_outliers'];
        Err = $kv['error'] }
    }
  }
}
# (-Property *: the automatic table shows only the first 10 columns)
$rows | Format-Table -Property * -AutoSize | Out-String -Width 300
if ($Out) { $rows | Export-Csv -NoTypeInformation -Path $Out }
