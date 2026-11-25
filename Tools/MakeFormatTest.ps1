# ==============================================================================
#  AulumicNS tools - MakeFormatTest.ps1
#
#  Builds the folder of format test files: every format the program plays, in
#  every sample rate, bit depth and channel layout, each file with a channel
#  check that can be heard:
#
#    second 0: one beep in channel 1 (front left)
#    second 1: two beeps in channel 2 (front right)
#    second 2: three beeps in channel 3 ...     (one second per channel)
#    then two seconds of all channels together
#
#  Every channel has its own pitch; the LFE channel is a low 80 Hz.
#
#  PCM (WAV, AIFF, ALAC, FLAC) is made by ffmpeg, DSD (DSF, DFF) by the audio simulator
#  (AudioSim dsdtest: stereo at DSD64 .. DSD512, the layouts with more channels
#  at DSD64). A new format: one more entry in $Formats.
#
#    Tools\MakeFormatTest.ps1 [-Out <folder>] [-Check] [-CopyTo <folder>]
#
#  -Check   decodes every file with the engine (AudioSim bench) and lists the
#           ones that fail
#  -CopyTo  copies the finished set there; files that are already there and are not
#           part of the set (own music added for a test) are left alone
#
#  ffmpeg is not part of the project: -Ffmpeg names ffmpeg.exe (default: the
#  copy under lib\ffmpeg). The set is not published.
# ==============================================================================
param(
  [string]$Out = '',
  [string]$Ffmpeg = '',
  [string]$CopyTo = '',
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ($Out -eq '') { $Out = Join-Path $Root 'lib\FormatTest' }
if ($Ffmpeg -eq '') {
  $found = Get-ChildItem (Join-Path $Root 'lib\ffmpeg') -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { $Ffmpeg = $found.FullName }
}
if (($Ffmpeg -eq '') -or -not (Test-Path -LiteralPath $Ffmpeg)) { throw 'ffmpeg.exe not found: pass -Ffmpeg <path>' }
$Sim = Join-Path $Root 'Tools\AudioSim\bin\AudioSim-Release.exe'
if (-not (Test-Path -LiteralPath $Sim)) { throw 'AudioSim-Release.exe not found: build Tools\AudioSim\AudioSim.lpi in Release mode' }

$Inv = [Globalization.CultureInfo]::InvariantCulture

# ---- what is made ------------------------------------------------------------

# name (also the folder), ffmpeg's layout name, the pitch of every channel in
# the order the file stores them
$Layouts = @(
  @{ Name = 'mono';         Ff = 'mono';   Freq = @('440') },
  @{ Name = 'stereo';       Ff = 'stereo'; Freq = @('440', '554.37') },
  @{ Name = '3.0';          Ff = '3.0';    Freq = @('440', '554.37', '659.26') },
  @{ Name = 'quadraphonic'; Ff = 'quad';   Freq = @('440', '554.37', '880', '1108.73') },
  @{ Name = '5.0';          Ff = '5.0';    Freq = @('440', '554.37', '659.26', '880', '1108.73') },
  @{ Name = '5.1';          Ff = '5.1';    Freq = @('440', '554.37', '659.26', '80', '880', '1108.73') },
  @{ Name = '6.1';          Ff = '6.1';    Freq = @('440', '554.37', '659.26', '80', '987.77', '1318.51', '1760') },
  @{ Name = '7.1';          Ff = '7.1';    Freq = @('440', '554.37', '659.26', '80', '880', '1108.73', '1318.51', '1760') }
)

$AllRates   = 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000
$MultiRates = 44100, 96000, 192000

# Ext, the highest rate the format takes, its bit depths, and the encoder
# arguments per bit depth
$Formats = @(
  @{ Name = 'WAV';  Ext = 'wav';  MaxRate = 768000; Bits = 16, 24, 32
     Args = @{ 16 = @('-c:a', 'pcm_s16le'); 24 = @('-c:a', 'pcm_s24le'); 32 = @('-c:a', 'pcm_s32le') } },
  @{ Name = 'AIFF'; Ext = 'aiff'; MaxRate = 768000; Bits = 16, 24, 32
     Args = @{ 16 = @('-c:a', 'pcm_s16be', '-write_id3v2', '1'); 24 = @('-c:a', 'pcm_s24be', '-write_id3v2', '1')
               32 = @('-c:a', 'pcm_s32be', '-write_id3v2', '1') } },
  @{ Name = 'ALAC'; Ext = 'm4a'; MaxRate = 384000; Bits = 16, 24
     Args = @{ 16 = @('-c:a', 'alac', '-sample_fmt', 's16p'); 24 = @('-c:a', 'alac', '-sample_fmt', 's32p') } },
  @{ Name = 'FLAC'; Ext = 'flac'; MaxRate = 384000; Bits = 16, 24
     Args = @{ 16 = @('-c:a', 'flac', '-sample_fmt', 's16')
               24 = @('-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24') } }
)

# ---- helpers -------------------------------------------------------------------

function Get-RateText([int]$Rate) {
  ($Rate / 1000.0).ToString('0.###', $Inv)
}

# the channel check as an ffmpeg source: one expression per channel
function Get-CheckSource($Layout, [int]$Rate) {
  $n = $Layout.Freq.Count
  $ex = for ($i = 0; $i -lt $n; $i++) {
    "0.25*sin(2*PI*$($Layout.Freq[$i])*t)*(between(t,$i,$i+0.999)*lt(mod(t-$i,0.12),0.07)*lt(floor((t-$i)/0.12),$($i + 1))+gte(t,$n))"
  }
  "aevalsrc=exprs='" + ($ex -join '|') + "':s=${Rate}:d=$($n + 2):c=$($Layout.Ff)"
}

# ---- PCM ---------------------------------------------------------------------

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Force $Out | Out-Null

$made = 0
$failed = New-Object System.Collections.Generic.List[string]
foreach ($fmt in $Formats) {
  foreach ($lay in $Layouts) {
    $dir = Join-Path $Out (Join-Path $fmt.Name $lay.Name)
    New-Item -ItemType Directory -Force $dir | Out-Null
    if ($lay.Freq.Count -le 2) { $rates = $AllRates } else { $rates = $MultiRates }
    $track = 0
    foreach ($rate in $rates) {
      if ($rate -gt $fmt.MaxRate) { continue }
      foreach ($bits in $fmt.Bits) {
        $track++
        $what = "$($fmt.Name) $bits/$(Get-RateText $rate) $($lay.Name)"
        $file = Join-Path $dir ("{0:00} {1} {2}-{3} {4}.{5}" -f $track, $fmt.Name, $bits, (Get-RateText $rate), $lay.Name, $fmt.Ext)
        $a = @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', (Get-CheckSource $lay $rate)) +
             $fmt.Args[$bits] +
             @('-metadata', "title=$what", '-metadata', "album=Format test - $($fmt.Name) $($lay.Name)",
               '-metadata', 'artist=Aulumic format test', '-metadata', "track=$track", $file)
        & $Ffmpeg @a
        if (($LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $file)) { $failed.Add("not made: $what") } else { $made++ }
      }
    }
  }
}

# ---- DSD -----------------------------------------------------------------------

& $Sim dsdtest $Out | Out-Null
$dsd = @(Get-ChildItem -LiteralPath $Out -Recurse -File | Where-Object { $_.Extension -in '.dsf', '.dff' })
$made += $dsd.Count
if ($dsd.Count -ne 16) { $failed.Add("DSD: $($dsd.Count) files instead of 16") }

# ---- a note in the folder ------------------------------------------------------

$note = @'
Aulumic format test files
=========================

Every file holds a channel check:

  second 0: one beep in channel 1 (front left)
  second 1: two beeps in channel 2 (front right)
  second 2: three beeps in channel 3, and so on - one second per channel
  then two seconds of all channels together

Channel order: front left, front right, centre, LFE (a low 80 Hz), then the
surround channels. Every channel has its own pitch.

A DSD file with more than two channels is always converted to PCM for this.

Files with more than two channels are mixed to stereo: the fronts on their
side, the centre in the middle, the surrounds on their side but lower, and
nothing from the LFE channel.

File names: number, format, bit depth - sample rate in kHz, layout.
Made by Tools\MakeFormatTest.ps1; the folder can be deleted and made again.
'@
[IO.File]::WriteAllText((Join-Path $Out 'README.txt'), $note, (New-Object Text.UTF8Encoding $false))

# ---- check with the engine -----------------------------------------------------

if ($Check) {
  $checked = 0
  foreach ($f in (Get-ChildItem -LiteralPath $Out -Recurse -File | Where-Object { $_.Name -ne 'README.txt' })) {
    $checked++
    $res = & $Sim bench $f.FullName --secs=0 --resample=0 2>&1 | ForEach-Object { "$_" }
    if (-not ($res | Select-String -Pattern '^RESULT mode=bench' -Quiet)) {
      $failed.Add("does not decode: $($f.FullName.Substring($Out.Length + 1))")
    }
  }
}

$size = (Get-ChildItem -LiteralPath $Out -Recurse -File | Measure-Object Length -Sum).Sum
"{0} files, {1:N2} GB in {2}" -f $made, ($size / 1GB), $Out
if ($Check) { "$checked files decoded by the engine" }
foreach ($f in $failed) { "FAILED  $f" }

if (($CopyTo -ne '') -and ($failed.Count -eq 0)) {
  robocopy $Out $CopyTo /E /NFL /NDL /NJH /NP | Select-Object -Last 8
  if ($LASTEXITCODE -ge 8) { $failed.Add('copy failed') }
}
exit $failed.Count
