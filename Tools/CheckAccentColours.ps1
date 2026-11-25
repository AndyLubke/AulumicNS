<#
  AulumicNS - CheckAccentColours.ps1

  Checks the accent palette of src\gui\AuTheme.pas (AccentDark, AccentLight)
  for colour blindness: every colour is simulated for protanopia,
  deuteranopia and tritanopia (Machado et al. 2009, full severity, linear
  sRGB) and the CIEDE2000 distance of every pair is measured. Printed per
  theme: the closest pair for normal sight and each deficiency (below about
  10 two colours are easy to mix up), and each colour's contrast on the
  theme's background (WCAG). Pure PowerShell, nothing compiled.

  -Mode opt searches a palette: each colour keeps its hue family, the dark
  theme stays pastel, the light theme dark enough for text on white; the
  closest pair over all four visions is made as large as possible
  (coordinate descent, a minute or two). The palette of 2026-11-11 started
  from its result (a little more chroma for Blue, Peach, Rose).

  Usage: & .\Tools\CheckAccentColours.ps1 [-Mode opt]
#>
param([string]$Mode = 'eval')

function Lin([double]$c) { $c = $c / 255.0; if ($c -le 0.04045) { $c / 12.92 } else { [math]::Pow(($c + 0.055) / 1.055, 2.4) } }
function Gam([double]$c) { if ($c -le 0) { return 0 }; if ($c -ge 1) { return 255 }; if ($c -le 0.0031308) { $v = 12.92 * $c } else { $v = 1.055 * [math]::Pow($c, 1 / 2.4) - 0.055 }; [math]::Round($v * 255) }

$CvdMat = @{
  normal = @(1,0,0, 0,1,0, 0,0,1)
  protan = @(0.152286,1.052583,-0.204868, 0.114503,0.786281,0.099216, -0.003882,-0.048116,1.051998)
  deutan = @(0.367322,0.860646,-0.227968, 0.280085,0.672501,0.047413, -0.011820,0.042940,0.968881)
  tritan = @(1.255528,-0.076749,-0.178779, -0.078411,0.930809,0.147602, 0.004733,0.691367,0.303900)
}

function HexRgb([string]$h) { $h = $h.TrimStart('#'); @([convert]::ToInt32($h.Substring(0,2),16), [convert]::ToInt32($h.Substring(2,2),16), [convert]::ToInt32($h.Substring(4,2),16)) }

function LabOfLin($r, $g, $b) {
  $X = 0.4124564*$r + 0.3575761*$g + 0.1804375*$b
  $Y = 0.2126729*$r + 0.7151522*$g + 0.0721750*$b
  $Z = 0.0193339*$r + 0.1191920*$g + 0.9503041*$b
  $xr = $X / 0.95047; $yr = $Y; $zr = $Z / 1.08883
  $f = { param($t) if ($t -gt 0.008856) { [math]::Pow($t, 1/3) } else { (903.3 * $t + 16) / 116 } }
  $fx = & $f $xr; $fy = & $f $yr; $fz = & $f $zr
  @((116 * $fy - 16), (500 * ($fx - $fy)), (200 * ($fy - $fz)))
}

function Sim($rgb, [string]$kind) {
  $m = $CvdMat[$kind]; $r = Lin $rgb[0]; $g = Lin $rgb[1]; $b = Lin $rgb[2]
  $r2 = [math]::Min(1.0,[math]::Max(0.0, $m[0]*$r + $m[1]*$g + $m[2]*$b))
  $g2 = [math]::Min(1.0,[math]::Max(0.0, $m[3]*$r + $m[4]*$g + $m[5]*$b))
  $b2 = [math]::Min(1.0,[math]::Max(0.0, $m[6]*$r + $m[7]*$g + $m[8]*$b))
  LabOfLin $r2 $g2 $b2
}

function DE2000($p, $q) {
  $L1,$a1,$b1 = $p; $L2,$a2,$b2 = $q
  $C1 = [math]::Sqrt($a1*$a1 + $b1*$b1); $C2 = [math]::Sqrt($a2*$a2 + $b2*$b2); $Cb = ($C1 + $C2) / 2
  $G = 0.5 * (1 - [math]::Sqrt([math]::Pow($Cb,7) / ([math]::Pow($Cb,7) + [math]::Pow(25,7))))
  $a1p = (1 + $G) * $a1; $a2p = (1 + $G) * $a2
  $C1p = [math]::Sqrt($a1p*$a1p + $b1*$b1); $C2p = [math]::Sqrt($a2p*$a2p + $b2*$b2)
  $h1p = if ($C1p -eq 0) { 0 } else { ([math]::Atan2($b1, $a1p) * 180 / [math]::PI + 360) % 360 }
  $h2p = if ($C2p -eq 0) { 0 } else { ([math]::Atan2($b2, $a2p) * 180 / [math]::PI + 360) % 360 }
  $dL = $L2 - $L1; $dC = $C2p - $C1p
  if ($C1p * $C2p -eq 0) { $dh = 0 } else { $dh = $h2p - $h1p; if ($dh -gt 180) { $dh -= 360 } elseif ($dh -lt -180) { $dh += 360 } }
  $dH = 2 * [math]::Sqrt($C1p * $C2p) * [math]::Sin($dh * [math]::PI / 360)
  $Lb = ($L1 + $L2) / 2; $Cbp = ($C1p + $C2p) / 2
  if ($C1p * $C2p -eq 0) { $hb = $h1p + $h2p } elseif ([math]::Abs($h1p - $h2p) -le 180) { $hb = ($h1p + $h2p) / 2 } elseif ($h1p + $h2p -lt 360) { $hb = ($h1p + $h2p + 360) / 2 } else { $hb = ($h1p + $h2p - 360) / 2 }
  $T = 1 - 0.17*[math]::Cos(($hb - 30)*[math]::PI/180) + 0.24*[math]::Cos(2*$hb*[math]::PI/180) + 0.32*[math]::Cos((3*$hb + 6)*[math]::PI/180) - 0.20*[math]::Cos((4*$hb - 63)*[math]::PI/180)
  $dTh = 30 * [math]::Exp(-[math]::Pow(($hb - 275) / 25, 2))
  $RC = 2 * [math]::Sqrt([math]::Pow($Cbp,7) / ([math]::Pow($Cbp,7) + [math]::Pow(25,7)))
  $SL = 1 + (0.015 * [math]::Pow($Lb - 50, 2)) / [math]::Sqrt(20 + [math]::Pow($Lb - 50, 2))
  $SC = 1 + 0.045 * $Cbp; $SH = 1 + 0.015 * $Cbp * $T
  $RT = -[math]::Sin(2 * $dTh * [math]::PI / 180) * $RC
  [math]::Sqrt([math]::Pow($dL/$SL,2) + [math]::Pow($dC/$SC,2) + [math]::Pow($dH/$SH,2) + $RT * ($dC/$SC) * ($dH/$SH))
}

# LCh (D65) -> sRGB, $null when out of gamut
function RgbOfLch([double]$L, [double]$C, [double]$h) {
  $a = $C * [math]::Cos($h * [math]::PI / 180); $b = $C * [math]::Sin($h * [math]::PI / 180)
  $fy = ($L + 16) / 116; $fx = $fy + $a / 500; $fz = $fy - $b / 200
  $inv = { param($t) if ([math]::Pow($t,3) -gt 0.008856) { [math]::Pow($t,3) } else { (116 * $t - 16) / 903.3 } }
  $X = 0.95047 * (& $inv $fx); $Y = (& $inv $fy); $Z = 1.08883 * (& $inv $fz)
  $r =  3.2404542*$X - 1.5371385*$Y - 0.4985314*$Z
  $g = -0.9692660*$X + 1.8760108*$Y + 0.0415560*$Z
  $bb = 0.0556434*$X - 0.2040259*$Y + 1.0572252*$Z
  if ($r -lt -0.001 -or $r -gt 1.001 -or $g -lt -0.001 -or $g -gt 1.001 -or $bb -lt -0.001 -or $bb -gt 1.001) { return $null }
  @((Gam $r), (Gam $g), (Gam $bb))
}

function Hex($rgb) { '#{0:X2}{1:X2}{2:X2}' -f [int]$rgb[0], [int]$rgb[1], [int]$rgb[2] }

# the smallest distance of a palette, per vision, and the pair
function Report([string]$name, $hexes) {
  $rgbs = $hexes | ForEach-Object { ,(HexRgb $_) }
  $line = "{0,-10}" -f $name
  foreach ($k in 'normal','protan','deutan','tritan') {
    $labs = $rgbs | ForEach-Object { ,(Sim $_ $k) }
    $min = 999; $pair = ''
    for ($i = 0; $i -lt $labs.Count; $i++) { for ($j = $i + 1; $j -lt $labs.Count; $j++) {
      $d = DE2000 $labs[$i] $labs[$j]; if ($d -lt $min) { $min = $d; $pair = "$i-$j" } } }
    $line += "  {0} {1,5:N1} ({2})" -f $k, $min, $pair
  }
  $line
}

function RelLum($rgb) { 0.2126 * (Lin $rgb[0]) + 0.7152 * (Lin $rgb[1]) + 0.0722 * (Lin $rgb[2]) }
function Contrast($rgb, $bg) { $a = RelLum $rgb; $b = RelLum $bg; ([math]::Max($a,$b) + 0.05) / ([math]::Min($a,$b) + 0.05) }

if ($Mode -eq 'eval') {
  # the palette as AuTheme.pas has it ($FFrrggbb)
  $src = Get-Content (Join-Path $PSScriptRoot '..\src\gui\AuTheme.pas') -Raw
  $names = [regex]::Match($src, "AccentNames:[^=]*=\s*\(([^)]*)\)").Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") }
  foreach ($t in @(@('AccentDark', 'dark', @(21,22,26)), @('AccentLight', 'light', @(255,255,255)))) {
    $arr = [regex]::Match($src, "$($t[0]):[^=]*=\s*\(([^)]*)\)").Groups[1].Value
    $hexes = [regex]::Matches($arr, '\$FF([0-9A-Fa-f]{6})') | ForEach-Object { '#' + $_.Groups[1].Value.ToUpper() }
    "--- $($t[1]) theme"
    for ($i = 0; $i -lt $hexes.Count; $i++) {
      "  {0,-8} {1}  contrast on the background {2:N1}" -f $names[$i], $hexes[$i], (Contrast (HexRgb $hexes[$i]) $t[2])
    }
    Report "  closest" $hexes
  }
  # selected text in an input field (AuTheme.TextSelectionFor): the field's
  # background with as much accent as leaves the text on it at 4.5 or more
  $inputs = [regex]::Matches($src, 'clInput := \$FF([0-9A-Fa-f]{6})') | ForEach-Object { ,(HexRgb $_.Groups[1].Value) }
  $texts = [regex]::Matches($src, 'clText := \$FF([0-9A-Fa-f]{6})') | ForEach-Object { ,(HexRgb $_.Groups[1].Value) }
  $n = 0
  foreach ($t in @(@('AccentDark', 'dark'), @('AccentLight', 'light'))) {
    $arr = [regex]::Match($src, "$($t[0]):[^=]*=\s*\(([^)]*)\)").Groups[1].Value
    $hexes = [regex]::Matches($arr, '\$FF([0-9A-Fa-f]{6})') | ForEach-Object { '#' + $_.Groups[1].Value.ToUpper() }
    $bg = $inputs[$n]; $tx = $texts[$n]; $n++
    "--- $($t[1]) theme: selected text in an input field"
    for ($i = 0; $i -lt $hexes.Count; $i++) {
      $acc = HexRgb $hexes[$i]
      for ($m = 0.55; $m -ge 0.2999; $m -= 0.01) {
        $sel = @(0,1,2) | ForEach-Object { [math]::Round($bg[$_] + ($acc[$_] - $bg[$_]) * $m) }
        if ((Contrast $tx $sel) -ge 4.5) { break }
      }
      "  {0,-8} {1}  {2:P0} accent  on the field {3:N2}  text on it {4:N1}" -f $names[$i], (Hex $sel), $m, (Contrast $sel $bg), (Contrast $tx $sel)
    }
  }
}

if ($Mode -eq 'opt') {
  # coordinate descent per theme: each colour keeps its hue family (+-12),
  # L / C inside the theme's limits; the goal: the largest smallest
  # distance over all pairs and all four visions (normal counts 0.8)
  # name, hue, dark L range, light L range (pastel in the dark theme; dark
  # enough for text on white in the light one; yellow stays yellow)
  $fam = @(@('Blue', 275, 62, 74, 38, 50), @('Mint', 170, 76, 88, 44, 54), @('Yellow', 95, 82, 90, 54, 62),
           @('Peach', 55, 70, 80, 50, 58), @('Rose', 5, 60, 72, 42, 52), @('Lilac', 315, 70, 84, 34, 46))
  $kinds = 'normal','protan','deutan','tritan'
  foreach ($theme in 'dark', 'light') {
    if ($theme -eq 'dark') { $Cs = 30, 36, 42, 48; $bg = @(21,22,26); $minCon = 5.0 }
    else { $Cs = 40, 48, 56, 64; $bg = @(255,255,255); $minCon = 3.0 }
    # options per colour, with their simulated Labs
    $opts = @()
    foreach ($f in $fam) {
      if ($theme -eq 'dark') { $Ls = $f[2]..$f[3] | Where-Object { $_ % 2 -eq 0 } } else { $Ls = $f[4]..$f[5] | Where-Object { $_ % 2 -eq 0 } }
      $list = @()
      foreach ($dh in -10, -5, 0, 5, 10) { foreach ($L in $Ls) { foreach ($C in $Cs) {
        $h = ($f[1] + $dh + 360) % 360; $rgb = RgbOfLch $L $C $h
        if ($rgb -eq $null) { continue }
        if ((Contrast $rgb $bg) -lt $minCon) { continue }
        $labs = @{}; foreach ($k in $kinds) { $labs[$k] = Sim $rgb $k }
        $list += ,@{ L = $L; C = $C; h = $h; rgb = $rgb; labs = $labs } } } }
      $opts += ,$list
    }
    # start: the middle option of each
    $cur = @(); foreach ($list in $opts) { $cur += ,$list[[int]($list.Count / 2)] }
    function PairD($x, $y) { $m = 999; foreach ($k in 'normal','protan','deutan','tritan') { $d = DE2000 $x.labs[$k] $y.labs[$k]; if ($k -eq 'normal') { $d *= 0.8 }; if ($d -lt $m) { $m = $d } }; $m }
    function Score($set) { $m = 999; for ($i = 0; $i -lt $set.Count; $i++) { for ($j = $i + 1; $j -lt $set.Count; $j++) { $d = PairD $set[$i] $set[$j]; if ($d -lt $m) { $m = $d } } }; $m }
    for ($sweep = 0; $sweep -lt 3; $sweep++) {
      for ($i = 0; $i -lt $cur.Count; $i++) {
        $best = $cur[$i]; $bestS = Score $cur
        foreach ($o in $opts[$i]) {
          # only the pairs with colour i change: the others give a cap
          $m = 999
          for ($j = 0; $j -lt $cur.Count; $j++) { if ($j -ne $i) { $d = PairD $o $cur[$j]; if ($d -lt $m) { $m = $d } } }
          if ($m -le $bestS) { continue }
          $trial = @($cur); $trial[$i] = $o; $s = Score $trial
          if ($s -gt $bestS) { $bestS = $s; $best = $o }
        }
        $cur[$i] = $best
      }
      "$theme sweep $sweep : smallest distance {0:N1}" -f (Score $cur)
    }
    for ($i = 0; $i -lt $cur.Count; $i++) {
      "  {0,-7} {1}  L{2} C{3} h{4}  contrast {5:N1}" -f $fam[$i][0], (Hex $cur[$i].rgb), $cur[$i].L, $cur[$i].C, $cur[$i].h, (Contrast $cur[$i].rgb $bg)
    }
    Report "  $theme" ($cur | ForEach-Object { Hex $_.rgb })
  }
}
