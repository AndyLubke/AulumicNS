unit AuLoudness;

{ ==============================================================================
  AulumicNS - AuLoudness
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  EBU R128 / ITU-R BS.1770-4 loudness measurement (the meter only - the
  scan thread is uReplayGainThread):
    K-weighting (high shelf + high pass, coefficients for any sample rate),
    the mean square per channel with the BS.1770 channel weights, 400 ms
    blocks with 75 % overlap, absolute gate -70 LUFS, relative gate -10 LU;
    the peak is the sample peak over all channels.
  IntegratedLoudness over the blocks of one track is its loudness, over the
  blocks of all tracks of an album the album loudness (the gates applied to
  all blocks together, as ebur128_loudness_global_multiple).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

type
  TLoudnessBlocks = array of Double;
  TLoudnessBlockSets = array of TLoudnessBlocks;

  { TAuLoudnessMeter }

  TAuLoudnessMeter = class
  private
    FCh: Integer;
    FWeights: array of Double;
    FB, FA: array[0..1, 0..2] of Double;      // stage 0 shelf, stage 1 high pass
    FZ: array of array[0..1, 0..1] of Double; // per channel, per stage, two states
    FSubLen, FSubPos: Integer;
    FSubSum: Double;
    FSubs: array[0..3] of Double;
    FSubCount: Integer;
    FBlocks: TLoudnessBlocks;
    FBlockCount: Integer;
    FPeak: Double;
    FFrames: Int64;
    procedure AddFrame(const X: array of Double);
  public
    constructor Create(ARate: Cardinal; AChannels: Integer);
    { interleaved frames, full scale = 1.0 }
    procedure AddSingle(Src: PSingle; AFrames: Integer);
    { the mean square energies of the 400 ms blocks so far }
    function Blocks: TLoudnessBlocks;
    { the integrated loudness of what was added (LUFS; -Infinity when all of it
      is below the absolute gate) }
    function Loudness: Double;
    property Peak: Double read FPeak;
    property Frames: Int64 read FFrames;
    property Channels: Integer read FCh;
  end;

{ integrated loudness in LUFS over the blocks of one or more tracks;
  -Infinity when everything is below the absolute gate }
function IntegratedLoudness(const ASets: TLoudnessBlockSets): Double;

implementation

{ ---- TAuLoudnessMeter ---- }

constructor TAuLoudnessMeter.Create(ARate: Cardinal; AChannels: Integer);
var
  F0, G, Q, K, Vh, Vb, A0: Double;
  C: Integer;
begin
  inherited Create;
  if AChannels < 1 then AChannels := 1;
  if ARate < 8000 then ARate := 8000;
  FCh := AChannels;
  SetLength(FWeights, FCh);
  for C := 0 to FCh - 1 do
  begin
    FWeights[C] := 1.0;
    { 5.1 order L R C LFE Ls Rs: no LFE, the surrounds +1.5 dB }
    if FCh >= 5 then
    begin
      if (FCh = 6) and (C = 3) then FWeights[C] := 0
      else if C >= FCh - 2 then FWeights[C] := 1.41;
    end;
  end;
  { stage 1: high shelf (+4 dB above ~1.5 kHz) }
  F0 := 1681.974450955533;
  G := 3.999843853973347;
  Q := 0.7071752369554196;
  K := Tan(Pi * F0 / ARate);
  Vh := Power(10, G / 20);
  Vb := Power(Vh, 0.4996667741545416);
  A0 := 1 + K / Q + K * K;
  FB[0, 0] := (Vh + Vb * K / Q + K * K) / A0;
  FB[0, 1] := 2 * (K * K - Vh) / A0;
  FB[0, 2] := (Vh - Vb * K / Q + K * K) / A0;
  FA[0, 0] := 1;
  FA[0, 1] := 2 * (K * K - 1) / A0;
  FA[0, 2] := (1 - K / Q + K * K) / A0;
  { stage 2: high pass at ~38 Hz }
  F0 := 38.13547087602444;
  Q := 0.5003270373238773;
  K := Tan(Pi * F0 / ARate);
  A0 := 1 + K / Q + K * K;
  FB[1, 0] := 1;
  FB[1, 1] := -2;
  FB[1, 2] := 1;
  FA[1, 0] := 1;
  FA[1, 1] := 2 * (K * K - 1) / A0;
  FA[1, 2] := (1 - K / Q + K * K) / A0;
  SetLength(FZ, FCh);
  for C := 0 to FCh - 1 do FillChar(FZ[C], SizeOf(FZ[C]), 0);
  FSubLen := Round(ARate * 0.1);
  if FSubLen < 1 then FSubLen := 1;
end;

procedure TAuLoudnessMeter.AddFrame(const X: array of Double);
var
  C, S: Integer;
  V, Y, Sum, A: Double;
begin
  Sum := 0;
  for C := 0 to FCh - 1 do
  begin
    V := X[C];
    A := Abs(V);
    if A > FPeak then FPeak := A;
    if FWeights[C] = 0 then Continue;
    { two biquads, transposed direct form II }
    for S := 0 to 1 do
    begin
      Y := FB[S, 0] * V + FZ[C][S, 0];
      FZ[C][S, 0] := FB[S, 1] * V - FA[S, 1] * Y + FZ[C][S, 1];
      FZ[C][S, 1] := FB[S, 2] * V - FA[S, 2] * Y;
      V := Y;
    end;
    Sum := Sum + FWeights[C] * V * V;
  end;
  FSubSum := FSubSum + Sum;
  Inc(FSubPos);
  Inc(FFrames);
  if FSubPos = FSubLen then
  begin
    FSubs[FSubCount and 3] := FSubSum;
    Inc(FSubCount);
    FSubSum := 0;
    FSubPos := 0;
    if FSubCount >= 4 then
    begin
      if FBlockCount >= Length(FBlocks) then SetLength(FBlocks, FBlockCount * 2 + 256);
      FBlocks[FBlockCount] := (FSubs[0] + FSubs[1] + FSubs[2] + FSubs[3]) / (4 * FSubLen);
      Inc(FBlockCount);
    end;
  end;
end;

procedure TAuLoudnessMeter.AddSingle(Src: PSingle; AFrames: Integer);
var
  I, C: Integer;
  X: array of Double;
begin
  X := nil;
  SetLength(X, FCh);
  for I := 0 to AFrames - 1 do
  begin
    for C := 0 to FCh - 1 do X[C] := Src[I * FCh + C];
    AddFrame(X);
  end;
end;

function TAuLoudnessMeter.Blocks: TLoudnessBlocks;
begin
  Result := Copy(FBlocks, 0, FBlockCount);
end;

function TAuLoudnessMeter.Loudness: Double;
var
  Sets: TLoudnessBlockSets;
begin
  Sets := nil;
  SetLength(Sets, 1);
  Sets[0] := Blocks;
  Result := IntegratedLoudness(Sets);
end;

function EnergyToLufs(E: Double): Double; inline;
begin
  if E <= 0 then Result := NegInfinity else Result := -0.691 + 10 * Log10(E);
end;

function IntegratedLoudness(const ASets: TLoudnessBlockSets): Double;
var
  AbsGate, RelGate, Sum: Double;
  I, J, N: Integer;
begin
  AbsGate := Power(10, (-70 + 0.691) / 10);
  Sum := 0;
  N := 0;
  for I := 0 to High(ASets) do
    for J := 0 to High(ASets[I]) do
      if ASets[I][J] > AbsGate then
      begin
        Sum := Sum + ASets[I][J];
        Inc(N);
      end;
  if N = 0 then Exit(NegInfinity);
  { the relative gate 10 LU below the absolute-gated loudness }
  RelGate := Sum / N * Power(10, -10 / 10);
  if RelGate < AbsGate then RelGate := AbsGate;
  Sum := 0;
  N := 0;
  for I := 0 to High(ASets) do
    for J := 0 to High(ASets[I]) do
      if ASets[I][J] > RelGate then
      begin
        Sum := Sum + ASets[I][J];
        Inc(N);
      end;
  if N = 0 then Exit(NegInfinity);
  Result := EnergyToLufs(Sum / N);
end;

end.
