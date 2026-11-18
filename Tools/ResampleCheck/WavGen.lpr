program WavGen;

{ ==============================================================================
  AulumicNS tools - WavGen
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Worst-case test signals for inter-sample peaks: 24-bit stereo WAV, 10 s.
  WavGen <folder> <rate>
  =============================================================================}

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math;

const
  FS24 = 8388607;

procedure WriteWav(const AName: string; ARate: Integer; const L, R: array of Double);
var
  F: TFileStream;
  N, I, V: Integer;
  B: array[0..5] of Byte;

  procedure W32(X: LongWord); begin F.WriteBuffer(X, 4); end;
  procedure W16(X: Word); begin F.WriteBuffer(X, 2); end;
  procedure Put(Y: Double; Ofs: Integer);
  begin
    V := Round(EnsureRange(Y, -1, 1) * FS24);
    B[Ofs] := V and $FF;
    B[Ofs + 1] := (V shr 8) and $FF;
    B[Ofs + 2] := (V shr 16) and $FF;
  end;

begin
  N := Length(L);
  F := TFileStream.Create(AName, fmCreate);
  try
    F.WriteBuffer(PChar('RIFF')^, 4);
    W32(36 + N * 6);
    F.WriteBuffer(PChar('WAVEfmt ')^, 8);
    W32(16); W16(1); W16(2); W32(ARate); W32(ARate * 6); W16(6); W16(24);
    F.WriteBuffer(PChar('data')^, 4);
    W32(N * 6);
    for I := 0 to N - 1 do
    begin
      Put(L[I], 0);
      Put(R[I], 3);
      F.WriteBuffer(B, 6);
    end;
  finally
    F.Free;
  end;
end;

var
  Dir: string;
  Rate, N, I: Integer;
  L, R: array of Double;
  S: QWord;
  X: Double;

function Rnd: Double;
begin
  S := S * 6364136223846793005 + 1442695040888963407;
  Result := (S shr 11) / 9007199254740992.0 * 2 - 1;
end;

begin
  Dir := IncludeTrailingPathDelimiter(ParamStr(1));
  Rate := StrToInt(ParamStr(2));
  N := Rate * 10;
  SetLength(L, N);
  SetLength(R, N);
  { 1. fs / 4 at 45 degrees: the samples are +-1, the wave between them +3.01 dB }
  for I := 0 to N - 1 do
  begin
    L[I] := Sqrt(2) * Sin(Pi / 2 * I + Pi / 4);
    R[I] := L[I];
  end;
  WriteWav(Dir + Format('fs4_45deg_%d.wav', [Rate]), Rate, L, R);
  { 2. a full-scale square wave of 1 kHz (not band-limited) }
  for I := 0 to N - 1 do
  begin
    if Frac(I * 1000 / Rate) < 0.5 then L[I] := 1 else L[I] := -1;
    R[I] := L[I];
  end;
  WriteWav(Dir + Format('square1k_%d.wav', [Rate]), Rate, L, R);
  { 3. white noise, 12 dB too loud, hard-clipped (a "brickwall" master) }
  S := 4711;
  for I := 0 to N - 1 do
  begin
    L[I] := EnsureRange(4 * Rnd, -1, 1);
    R[I] := EnsureRange(4 * Rnd, -1, 1);
  end;
  WriteWav(Dir + Format('clippednoise_%d.wav', [Rate]), Rate, L, R);
  { 4. a 997 Hz sine at full scale }
  for I := 0 to N - 1 do
  begin
    L[I] := Sin(2 * Pi * 997 * I / Rate);
    R[I] := L[I];
  end;
  WriteWav(Dir + Format('sine997_%d.wav', [Rate]), Rate, L, R);
  { 5. single full-scale impulses, 0.1 s apart (+1 left, -1 right) }
  for I := 0 to N - 1 do
  begin
    if I mod (Rate div 10) = 0 then X := 1 else X := 0;
    L[I] := X;
    R[I] := -X;
  end;
  WriteWav(Dir + Format('impulses_%d.wav', [Rate]), Rate, L, R);
  WriteLn('written: 5 files at ', Rate);
end.
