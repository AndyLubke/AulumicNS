<#
  AulumicNS - FindCodeAddress.ps1  (ported from Aulumic's Tools\FindCodeAddress.ps1)

  Turns code addresses from the AulumicNS log or a hang report into the
  routine, source file and line, using the symbol file (AulumicNS.dbg) of
  exactly that build.

  Where the addresses come from:
      [Unhandled Exception] EAccessViolation: ... at AulumicNS.exe+$1A2B <- AulumicNS.exe+$3C4D
      HangReport_<time>.txt: one frame per line, "    AulumicNS.exe+$AA634"
  Every AulumicNS.exe+$... in the text (or the file) is looked up. The first
  address of an exception line is the place itself; the others (callers,
  stack frames) are return addresses: they are looked up one byte earlier,
  so the line is the call, not the line after it.

  Usage (single quotes, so PowerShell does not read $2D98E0 as a variable):
      & .\Tools\FindCodeAddress.ps1 'AulumicNS.exe+$2D98E0'
      & .\Tools\FindCodeAddress.ps1 'whole log line with AulumicNS.exe+$2D98E0 <- AulumicNS.exe+$12AB'
      & .\Tools\FindCodeAddress.ps1 -File D:\Music\Aulumic\HangReport_2026-11-10_232425.txt
      & .\Tools\FindCodeAddress.ps1 '$2D98E0' -Exe 'D:\Releases\1.0\AulumicNS.exe'

  By default the current Release build is used (bin\Release\AulumicNS.exe and
  its AulumicNS.dbg). For an address from another build, pass that build's exe
  with -Exe; its .dbg must lie next to it (or pass -Dbg). The script checks
  that the .dbg belongs to the exe (name + CRC32 in its .gnu_debuglink).
  A Debug build keeps its debug information inside the exe: pass it with
  -Exe 'bin\Debug\AulumicNS.exe' (no .dbg needed).

  Needs the gdb.exe that comes with Lazarus (C:\Lazarus\mingw\...).
  Exit code: 0 = found, 1 = not found / error, 2 = only addresses of other modules.
#>
param(
  [Parameter(Position = 0)][string]$Address = '',
  [string]$File = '',
  [string]$Exe = '',
  [string]$Dbg = '',
  [string]$Gdb = 'C:\Lazarus\mingw\x86_64-win64\bin\gdb.exe'
)

$ErrorActionPreference = 'Stop'

if (-not ('AulumicNSTools.Crc32' -as [type])) {
  Add-Type -Language CSharp -TypeDefinition @'
namespace AulumicNSTools {
  public static class Crc32 {
    static readonly uint[] Table = MakeTable();
    static uint[] MakeTable() {
      var t = new uint[256];
      for (uint i = 0; i < 256; i++) {
        uint c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        t[i] = c;
      }
      return t;
    }
    public static uint OfFile(string path) {
      uint crc = 0xFFFFFFFFu;
      var buf = new byte[1 << 20];
      using (var fs = System.IO.File.OpenRead(path)) {
        int n;
        while ((n = fs.Read(buf, 0, buf.Length)) > 0)
          for (int i = 0; i < n; i++) crc = Table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
      }
      return crc ^ 0xFFFFFFFFu;
    }
  }
}
'@
}

if (($Address -eq '') -and ($File -eq '')) { Write-Host 'Pass an address (or a log line) or -File <log or hang report>.'; exit 1 }
if ($File -ne '') {
  if (-not (Test-Path -LiteralPath $File)) { Write-Host "File not found: $File"; exit 1 }
  $Address = [IO.File]::ReadAllText($File)
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ($Exe -eq '') { $Exe = Join-Path $ProjectRoot 'bin\Release\AulumicNS.exe' }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "Exe not found: $Exe"; exit 1 }
if (-not (Test-Path -LiteralPath $Gdb)) { Write-Host "gdb not found: $Gdb (pass -Gdb)"; exit 1 }

# ---- Read the PE header: image base and the .gnu_debuglink section ----
$Bytes   = [IO.File]::ReadAllBytes($Exe)
$Pe      = [BitConverter]::ToInt32($Bytes, 0x3C)
$NumSec  = [BitConverter]::ToUInt16($Bytes, $Pe + 6)
$SymPtr  = [BitConverter]::ToUInt32($Bytes, $Pe + 12)
$NumSym  = [BitConverter]::ToUInt32($Bytes, $Pe + 16)
$OptSize = [BitConverter]::ToUInt16($Bytes, $Pe + 20)
$Magic   = [BitConverter]::ToUInt16($Bytes, $Pe + 24)
if ($Magic -eq 0x20B) { $ImageBase = [BitConverter]::ToUInt64($Bytes, $Pe + 24 + 24) }
else                  { $ImageBase = [uint64][BitConverter]::ToUInt32($Bytes, $Pe + 24 + 28) }

$LinkName = ''
$LinkCrc  = $null
$StrTab   = $SymPtr + 18 * $NumSym   # COFF string table (long section names)
$SecHdr   = $Pe + 24 + $OptSize
for ($i = 0; $i -lt $NumSec; $i++) {
  $o    = $SecHdr + 40 * $i
  $Name = [Text.Encoding]::ASCII.GetString($Bytes, $o, 8).TrimEnd([char]0)
  if ($Name.StartsWith('/') -and ($SymPtr -gt 0)) {
    $NameOfs = [int]$Name.Substring(1)
    $End = $StrTab + $NameOfs
    while ($Bytes[$End] -ne 0) { $End++ }
    $Name = [Text.Encoding]::ASCII.GetString($Bytes, $StrTab + $NameOfs, $End - $StrTab - $NameOfs)
  }
  if ($Name -eq '.gnu_debuglink') {
    $Raw = [BitConverter]::ToUInt32($Bytes, $o + 20)
    $End = $Raw
    while ($Bytes[$End] -ne 0) { $End++ }
    $LinkName = [Text.Encoding]::ASCII.GetString($Bytes, $Raw, $End - $Raw)
    $CrcPos   = ($End + 4) -band (-bnot 3)   # name + #0, padded to 4 bytes
    $LinkCrc  = [BitConverter]::ToUInt32($Bytes, $CrcPos)
  }
}

if ($Dbg -eq '') {
  if ($LinkName -ne '') { $Dbg = Join-Path (Split-Path -Parent $Exe) $LinkName }
  else {
    $Dbg = [IO.Path]::ChangeExtension($Exe, '.dbg')
    # A Debug build has no .gnu_debuglink: its debug information is in the exe
    if (-not (Test-Path -LiteralPath $Dbg)) { $Dbg = $Exe }
  }
}
if (-not (Test-Path -LiteralPath $Dbg)) {
  Write-Host "Symbol file not found: $Dbg"
  Write-Host "Build the Release mode (it writes AulumicNS.dbg), or pass the .dbg kept with that build."
  exit 1
}
if ($null -ne $LinkCrc) {
  $DbgCrc = [AulumicNSTools.Crc32]::OfFile($Dbg)
  if ($DbgCrc -ne $LinkCrc) {
    Write-Host ("WARNING: {0} does not belong to {1} (CRC {2:X8}, the exe expects {3:X8})." -f `
      (Split-Path -Leaf $Dbg), (Split-Path -Leaf $Exe), $DbgCrc, $LinkCrc)
    Write-Host "         The results below are probably wrong. Use the .dbg of the same build."
  }
}
elseif ($Dbg -ne $Exe) {
  Write-Host "Note: this exe has no .gnu_debuglink; the .dbg cannot be checked against it."
}

# ---- The addresses: every <module>+$hex; else one plain $hex / hex ----
$ExeName = Split-Path -Leaf $Exe
$List = New-Object System.Collections.Generic.List[object]
$Other = 0
foreach ($m in [regex]::Matches($Address, '([A-Za-z0-9_.\-]+\.(exe|dll|DLL|EXE))\s*\+\s*(\$|0x)?([0-9A-Fa-f]+)')) {
  if ($m.Groups[1].Value -ne $ExeName) { $Other++; continue }
  $List.Add([Convert]::ToUInt64($m.Groups[4].Value, 16))
}
if (($List.Count -eq 0) -and ($Other -eq 0)) {
  if ($Address -match '(\$|0x)([0-9A-Fa-f]+)') { $List.Add([Convert]::ToUInt64($Matches[2], 16)) }
  elseif ($Address -match '^\s*([0-9A-Fa-f]+)\s*$') { $List.Add([Convert]::ToUInt64($Matches[1], 16)) }
}
if ($List.Count -eq 0) {
  if ($Other -gt 0) { Write-Host "Only addresses of other modules (Windows DLLs, drivers): nothing to look up in $ExeName."; exit 2 }
  Write-Host "No address found."
  exit 1
}

Write-Host "Symbols : $Dbg   (image base 0x$('{0:X}' -f $ImageBase))"
Write-Host ''
# one gdb run for all of them
$GdbArgs = @('-batch', '-nx')
$Shown = @()
for ($i = 0; $i -lt $List.Count; $i++) {
  $Value = $List[$i]
  if ($Value -ge $ImageBase) { $Abs = $Value } else { $Abs = $ImageBase + $Value }
  # a return address (all but the first): the call is one byte before it
  if ($i -gt 0) { $Look = $Abs - 1 } else { $Look = $Abs }
  $LookHex = '0x{0:X}' -f $Look
  $GdbArgs += '-ex'; $GdbArgs += ('echo === {0}+${1:X}\n' -f $ExeName, ($Abs - $ImageBase))
  $GdbArgs += '-ex'; $GdbArgs += "info symbol $LookHex"
  $GdbArgs += '-ex'; $GdbArgs += "info line *$LookHex"
}
$Out = & $Gdb @GdbArgs $Dbg 2>&1
$Found = $false
foreach ($l in $Out) {
  $s = "$l"
  if ($s -match '^Reading symbols') { continue }
  if ($s -match '^Line \d+ of') { $Found = $true }
  Write-Host "  $s"
}
if ($Found) { exit 0 } else { exit 1 }
