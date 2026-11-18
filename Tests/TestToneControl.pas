unit TestToneControl;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestToneControl
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The tone control (uToneControl): up to five biquad filters in series per
  channel (low shelf, three peaking, high shelf; RBJ's formulas,
  Q = 1 / sqrt 2, Direct Form II Transposed with the anti-denormal offset).
  The play thread inlines ProcessSampleL / R; these tests hold the output,
  bit for bit, against the same filters written out here, so a change of how
  the code is compiled or arranged (inlining, block processing) cannot change
  the sound unnoticed. Bass, mid and treble alone give the samples of a
  three-band chain; settings with three bands move their mid to its band.
  TTestToneGlide: a setting changed while music plays glides in without a
  jump, also through 0 dB and into "off"; the curve (ToneResponseDB) is the
  level a sine really gets.
  =============================================================================}

interface

uses
  Classes, SysUtils, Math, fpcunit, testregistry, ALAudioTypes, uToneControl, uSettingsManager;

type
  TTestToneControl = class(TTestCase)
  private
    procedure CompareWithReference(ARate, ABassHz, AMidHz, ATrebleHz,
      ABassTenths, AMidTenths, ATrebleTenths: Integer);
  published
    procedure AllBandsMatchTheReferenceBitForBit;
    procedure SingleBandsMatchTheReference;
    procedure HighRateMatchesTheReference;
    procedure FiveBandsMatchTheReference;
    procedure ThreeBandsOfFiveAreTheOldThree;
    procedure SettingsWithThreeBandsMoveTheirMid;
    procedure ZeroGainIsNotActive;
    procedure DirectModeIsNotActive;
  end;

  { The glide to a new setting (TToneControl.Advance) and the curve of the
    Tone Control window (ToneResponseDB) }
  TTestToneGlide = class(TTestCase)
  published
    procedure BeforeAnySampleASettingArrivesAtOnce;
    procedure WhilePlayingASettingGlides;
    procedure TheGlideIsFarSmootherThanAStep;
    procedure AfterTheGlideTheFiltersAreThoseOfTheSetting;
    procedure OffGlidesToZeroAndThenBypasses;
    procedure TheStepsDoNotDependOnTheBlockSizes;
    procedure StatePutBackInTheMiddleOfAGlide;
    procedure AResetEndsAGlide;
    procedure TheCurveIsWhatTheFiltersDo;
  end;

implementation

type
  TRefFilter = (rfLowShelf, rfPeaking, rfHighShelf);

  TRefBiquad = record
    b0, b1, b2, a1, a2, s1, s2: Double;
  end;

const
  REF_Q = 0.7071067811865475;

{ RBJ Audio EQ Cookbook, as TToneControl.CalcCoeffs }
function RefCoeffs(AType: TRefFilter; ARate: Integer; AFreq, AGainDB: Double): TRefBiquad;
var
  A, w0, sinW0, cosW0, alpha, tsa, Ap1, Am1, Am1Cos, Ap1Cos: Double;
  b0, b1, b2, a0, a1, a2, invA0: Double;
begin
  Result := Default(TRefBiquad);
  if Abs(AGainDB) < 0.001 then
  begin
    Result.b0 := 1.0;
    Exit;
  end;
  if AFreq > ARate * 0.49 then AFreq := ARate * 0.49;
  A := Power(10.0, AGainDB / 40.0);
  w0 := (2.0 * Pi * AFreq) / ARate;
  SinCos(w0, sinW0, cosW0);
  alpha := sinW0 / (2.0 * REF_Q);
  b0 := 1.0; b1 := 0.0; b2 := 0.0; a0 := 1.0; a1 := 0.0; a2 := 0.0;
  case AType of
    rfLowShelf:
      begin
        tsa := 2.0 * Sqrt(A) * alpha;
        Ap1 := A + 1.0; Am1 := A - 1.0; Am1Cos := Am1 * cosW0; Ap1Cos := Ap1 * cosW0;
        b0 := A * (Ap1 - Am1Cos + tsa);
        b1 := 2.0 * A * (Am1 - Ap1Cos);
        b2 := A * (Ap1 - Am1Cos - tsa);
        a0 := Ap1 + Am1Cos + tsa;
        a1 := -2.0 * (Am1 + Ap1Cos);
        a2 := Ap1 + Am1Cos - tsa;
      end;
    rfPeaking:
      begin
        b0 := 1.0 + alpha * A;
        b1 := -2.0 * cosW0;
        b2 := 1.0 - alpha * A;
        a0 := 1.0 + alpha / A;
        a1 := b1;
        a2 := 1.0 - alpha / A;
      end;
    rfHighShelf:
      begin
        tsa := 2.0 * Sqrt(A) * alpha;
        Ap1 := A + 1.0; Am1 := A - 1.0; Am1Cos := Am1 * cosW0; Ap1Cos := Ap1 * cosW0;
        b0 := A * (Ap1 + Am1Cos + tsa);
        b1 := -2.0 * A * (Am1 + Ap1Cos);
        b2 := A * (Ap1 + Am1Cos - tsa);
        a0 := Ap1 - Am1Cos + tsa;
        a1 := 2.0 * (Am1 - Ap1Cos);
        a2 := Ap1 - Am1Cos - tsa;
      end;
  end;
  invA0 := 1.0 / a0;
  Result.b0 := b0 * invA0;
  Result.b1 := b1 * invA0;
  Result.b2 := b2 * invA0;
  Result.a1 := a1 * invA0;
  Result.a2 := a2 * invA0;
end;

{ Direct Form II Transposed; a plain function (a call per filter) }
function RefStep(var F: TRefBiquad; AInput: Double): Double;
begin
  Result := (F.b0 * AInput) + F.s1;
  F.s1   := (F.b1 * AInput) - (F.a1 * Result) + F.s2;
  F.s2   := (F.b2 * AInput) - (F.a2 * Result) + ANTI_DENORMAL_OFFSET;
end;

{ TTestToneControl }

procedure TTestToneControl.CompareWithReference(ARate, ABassHz, AMidHz, ATrebleHz,
  ABassTenths, AMidTenths, ATrebleTenths: Integer);
const
  FRAMES = 20000;
var
  Tone: TToneControl;
  Ref: array[0..1, 0..2] of TRefBiquad;
  Seed: Cardinal;
  I, Ch, B, Diffs: Integer;
  X, Got, Want: Double;
  Gains: array[0..2] of Integer;
begin
  Gains[0] := ABassTenths; Gains[1] := AMidTenths; Gains[2] := ATrebleTenths;
  for Ch := 0 to 1 do
  begin
    Ref[Ch, 0] := RefCoeffs(rfLowShelf, ARate, ABassHz, ABassTenths * 0.1);
    Ref[Ch, 1] := RefCoeffs(rfPeaking, ARate, AMidHz, AMidTenths * 0.1);
    Ref[Ch, 2] := RefCoeffs(rfHighShelf, ARate, ATrebleHz, ATrebleTenths * 0.1);
  end;
  Tone := TToneControl.Create;
  try
    Tone.SetSampleRate(ARate);
    Tone.SetFrequencies(ABassHz, AMidHz, ATrebleHz);
    Tone.SetGains(ABassTenths, AMidTenths, ATrebleTenths);
    Tone.SetDirectMode(False);
    AssertTrue('Active', Tone.IsActive);
    Seed := 12345;
    Diffs := 0;
    for I := 0 to FRAMES - 1 do
      for Ch := 0 to 1 do
      begin
        { 24-bit samples of noise, with a stretch of silence in the middle }
        Seed := Cardinal((QWord(Seed) * 1664525 + 1013904223) and $FFFFFFFF);
        if (I >= 8000) and (I < 9000) then X := 0.0
        else X := Integer(Seed shr 8) - 8388608;
        if Ch = 0 then Got := Tone.ProcessSampleL(X) else Got := Tone.ProcessSampleR(X);
        Want := X;
        for B := 0 to 2 do
          if Gains[B] <> 0 then Want := RefStep(Ref[Ch, B], Want);
        if Got <> Want then Inc(Diffs);
      end;
    AssertEquals('Samples that differ from the reference', 0, Diffs);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneControl.AllBandsMatchTheReferenceBitForBit;
begin
  CompareWithReference(44100, 150, 1000, 6000, 45, -30, 25);
  CompareWithReference(96000, 100, 2500, 10000, -120, 200, -200);
end;

procedure TTestToneControl.SingleBandsMatchTheReference;
begin
  CompareWithReference(48000, 150, 1000, 6000, 60, 0, 0);
  CompareWithReference(48000, 150, 1000, 6000, 0, -45, 0);
  CompareWithReference(48000, 150, 1000, 6000, 0, 0, 5);
end;

procedure TTestToneControl.HighRateMatchesTheReference;
begin
  CompareWithReference(705600, 150, 1000, 6000, 30, 15, -40);
  { a treble frequency above 0.49 x the rate is held there }
  CompareWithReference(44100, 150, 1000, 30000, 10, 10, 10);
end;

{ all five bands against the same filters written out: low shelf, three
  peaking filters, high shelf, in this order }
procedure TTestToneControl.FiveBandsMatchTheReference;
const
  FRAMES = 20000;
  HZ: TToneInts = (120, 300, 1500, 5000, 10000);
  DB: TToneInts = (45, -30, 20, -55, 35);
  KIND: array[0..4] of TRefFilter = (rfLowShelf, rfPeaking, rfPeaking, rfPeaking, rfHighShelf);
var
  Tone: TToneControl;
  Ref: array[0..1, 0..4] of TRefBiquad;
  Seed: Cardinal;
  I, Ch, B, Diffs: Integer;
  X, Got, Want: Double;
begin
  for Ch := 0 to 1 do
    for B := 0 to 4 do
      Ref[Ch, B] := RefCoeffs(KIND[B], 96000, HZ[B], DB[B] * 0.1);
  Tone := TToneControl.Create;
  try
    Tone.SetSampleRate(96000);
    Tone.SetBandFrequencies(HZ);
    Tone.SetBandGains(DB);
    Tone.SetDirectMode(False);
    Seed := 777;
    Diffs := 0;
    for I := 0 to FRAMES - 1 do
      for Ch := 0 to 1 do
      begin
        Seed := Cardinal((QWord(Seed) * 1664525 + 1013904223) and $FFFFFFFF);
        X := Integer(Seed shr 8) - 8388608;
        if Ch = 0 then Got := Tone.ProcessSampleL(X) else Got := Tone.ProcessSampleR(X);
        Want := X;
        for B := 0 to 4 do
          Want := RefStep(Ref[Ch, B], Want);
        if Got <> Want then Inc(Diffs);
      end;
    AssertEquals('Samples that differ from the reference', 0, Diffs);
  finally
    Tone.Free;
  end;
end;

{ a setting of bass, mid and treble only, with its mid in any of the three
  middle bands, gives the samples of three bands: a band at 0 dB is not in
  the chain }
procedure TTestToneControl.ThreeBandsOfFiveAreTheOldThree;
var
  Old, New: TToneControl;
  Hz, Db: TToneInts;
  Slot, I, Diffs: Integer;
  Seed: Cardinal;
  X: Double;
begin
  for Slot := 1 to 3 do
  begin
    Old := TToneControl.Create;
    New := TToneControl.Create;
    try
      Old.SetSampleRate(44100);
      Old.SetFrequencies(150, 500, 6000);
      Old.SetGains(40, -35, 25);
      Old.SetDirectMode(False);
      Hz[0] := 150; Hz[1] := 400; Hz[2] := 1000; Hz[3] := 4000; Hz[4] := 6000;
      Db[0] := 40; Db[1] := 0; Db[2] := 0; Db[3] := 0; Db[4] := 25;
      Hz[Slot] := 500;
      Db[Slot] := -35;
      New.SetSampleRate(44100);
      New.SetBandFrequencies(Hz);
      New.SetBandGains(Db);
      New.SetDirectMode(False);
      Seed := 4242;
      Diffs := 0;
      for I := 0 to 9999 do
      begin
        Seed := Cardinal((QWord(Seed) * 1664525 + 1013904223) and $FFFFFFFF);
        X := Integer(Seed shr 8) - 8388608;
        if Old.ProcessSampleL(X) <> New.ProcessSampleL(X) then Inc(Diffs);
        if Old.ProcessSampleR(X) <> New.ProcessSampleR(X) then Inc(Diffs);
      end;
      AssertEquals(Format('Mid in band %d: samples that differ', [Slot]), 0, Diffs);
    finally
      Old.Free;
      New.Free;
    end;
  end;
end;

{ stored settings with three bands: their Mid band is at 220 Hz .. 3 kHz }
procedure TTestToneControl.SettingsWithThreeBandsMoveTheirMid;

  procedure Check(AMidHz, AMidDB, WantMidHz, WantMidDB, WantLowHz, WantLowDB, WantHighHz, WantHighDB: Integer);
  var
    MidHz, MidDB, LowHz, LowDB, HighHz, HighDB: Integer;
    M: string;
  begin
    MidHz := AMidHz; MidDB := AMidDB;
    LowHz := 400; LowDB := 0; HighHz := 4000; HighDB := 0;
    MoveThreeBandMid(MidHz, MidDB, LowHz, LowDB, HighHz, HighDB);
    M := Format('Mid at %d Hz: ', [AMidHz]);
    AssertEquals(M + 'mid Hz', WantMidHz, MidHz);
    AssertEquals(M + 'mid dB', WantMidDB, MidDB);
    AssertEquals(M + 'low mid Hz', WantLowHz, LowHz);
    AssertEquals(M + 'low mid dB', WantLowDB, LowDB);
    AssertEquals(M + 'high mid Hz', WantHighHz, HighHz);
    AssertEquals(M + 'high mid dB', WantHighDB, HighDB);
  end;

begin
  Check(220, -35, 1000, 0, 220, -35, 4000, 0);
  Check(500, 60, 1000, 0, 500, 60, 4000, 0);
  Check(1000, 45, 1000, 45, 400, 0, 4000, 0);
  Check(2000, -10, 2000, -10, 400, 0, 4000, 0);
  Check(3000, 25, 1000, 0, 400, 0, 3000, 25);
end;

procedure TTestToneControl.ZeroGainIsNotActive;
var
  Tone: TToneControl;
begin
  Tone := TToneControl.Create;
  try
    Tone.SetSampleRate(44100);
    Tone.SetDirectMode(False);
    Tone.SetGains(0, 0, 0);
    AssertFalse('All bands at 0 dB: the samples are left alone', Tone.IsActive);
    AssertEquals('A sample passes unchanged', 1234.0, Tone.ProcessSampleL(1234.0));
    Tone.SetGains(0, 5, 0);
    AssertTrue('One band set', Tone.IsActive);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneControl.DirectModeIsNotActive;
var
  Tone: TToneControl;
begin
  Tone := TToneControl.Create;
  try
    Tone.SetSampleRate(44100);
    Tone.SetGains(30, 30, 30);
    Tone.SetDirectMode(True);
    AssertFalse('Direct: off whatever the bands say', Tone.IsActive);
    Tone.SetDirectMode(False);
    AssertTrue('Direct off', Tone.IsActive);
  finally
    Tone.Free;
  end;
end;

{ TTestToneGlide }

const
  G_RATE = 48000;
  G_AMP  = 1000000.0;

type
  TDoubles = array of Double;

{ ACount frames of a sine of AFreq Hz (from frame AFrom on) through the left
  channel, AChunk frames at a time at most, as the play thread does it }
function Feed(ATone: TToneControl; AFreq: Double; AFrom, ACount, AChunk: Integer): TDoubles;
var
  I, N, Stop: Integer;
  Glide, IsOn: Boolean;
  X: Double;
begin
  Result := nil;
  SetLength(Result, ACount);
  I := 0;
  while I < ACount do
  begin
    Glide := ATone.Gliding;
    IsOn  := ATone.IsActive;
    N := ACount - I;
    if N > AChunk then N := AChunk;
    if Glide and (ATone.GlideChunk < N) then N := ATone.GlideChunk;
    Stop := I + N;
    while I < Stop do
    begin
      X := G_AMP * Sin(2.0 * Pi * AFreq * (AFrom + I) / G_RATE);
      if IsOn then Result[I] := ATone.ProcessSampleL(X) else Result[I] := X;
      Inc(I);
    end;
    if Glide then ATone.Advance(N);
  end;
  ATone.MarkPlayed;
end;

function NewTone(ABass, AMid, ATreble: Integer): TToneControl;
begin
  Result := TToneControl.Create;
  Result.SetSampleRate(G_RATE);
  Result.SetFrequencies(150, 1000, 6000);
  Result.SetGains(ABass, AMid, ATreble);
  Result.SetDirectMode(False);
end;

{ the curve of NewTone: bass, mid and treble set, the two other bands at 0 dB }
function TestCurve(ABass, AMid, ATreble: Integer): TToneCurve;
begin
  Result := Default(TToneCurve);
  Result.Rate := G_RATE;
  Result.Hz[0] := 150; Result.Hz[1] := 400; Result.Hz[2] := 1000; Result.Hz[3] := 4000; Result.Hz[4] := 6000;
  Result.Tenths[0] := ABass; Result.Tenths[2] := AMid; Result.Tenths[4] := ATreble;
end;

{ the largest |y[n] - 2 y[n-1] + y[n-2]|: a step in the samples shows here }
function Roughness(const A: TDoubles): Double;
var
  I: Integer;
  D: Double;
begin
  Result := 0.0;
  for I := 2 to High(A) do
  begin
    D := Abs(A[I] - 2.0 * A[I - 1] + A[I - 2]);
    if D > Result then Result := D;
  end;
end;

{ the last frames of ABefore and all of AAfter: the join is in it }
function Joined(const ABefore, AAfter: TDoubles): TDoubles;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, 8 + Length(AAfter));
  for I := 0 to 7 do
    Result[I] := ABefore[Length(ABefore) - 8 + I];
  for I := 0 to High(AAfter) do
    Result[8 + I] := AAfter[I];
end;

function Rms(const A: TDoubles): Double;
var
  I: Integer;
begin
  Result := 0.0;
  for I := 0 to High(A) do
    Result := Result + A[I] * A[I];
  Result := Sqrt(Result / Length(A));
end;

function Peak(const A: TDoubles; AFrom: Integer): Double;
var
  I: Integer;
begin
  Result := 0.0;
  for I := AFrom to High(A) do
    if Abs(A[I]) > Result then Result := Abs(A[I]);
end;

procedure TTestToneGlide.BeforeAnySampleASettingArrivesAtOnce;
var
  Tone: TToneControl;
begin
  Tone := NewTone(60, 0, 0);
  try
    AssertFalse('Nothing played yet: no glide', Tone.Gliding);
    Tone.SetGains(-60, 0, 0);
    AssertFalse('Still none', Tone.Gliding);
    AssertTrue('Active', Tone.IsActive);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneGlide.WhilePlayingASettingGlides;
var
  Tone: TToneControl;
  A: TDoubles;
  Len: Integer;
begin
  Tone := NewTone(60, 0, 0);
  try
    Feed(Tone, 60, 0, 4800, 4800);
    Tone.SetGains(60, 0, 0);
    AssertFalse('The same setting again: nothing to do', Tone.Gliding);
    Tone.SetGains(-60, 0, 0);
    AssertTrue('A new gain glides', Tone.Gliding);
    Len := G_RATE * TONE_GLIDE_MS div 1000;
    A := Feed(Tone, 60, 4800, Len - 1, 100000);
    AssertTrue('One frame before its end', Tone.Gliding);
    A := Feed(Tone, 60, 4800 + Len - 1, 1, 100000);
    AssertFalse('Done after TONE_GLIDE_MS', Tone.Gliding);
    AssertEquals(1, Length(A));
    Tone.SetFrequencies(250, 1000, 6000);
    AssertTrue('A new frequency glides too', Tone.Gliding);
    Tone.FinishGlide;
    AssertFalse('FinishGlide', Tone.Gliding);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneGlide.TheGlideIsFarSmootherThanAStep;
var
  Tone: TToneControl;
  Glided, Stepped, Before: TDoubles;
  Curve: TToneCurve;
begin
  { +10 dB of bass to 0 dB under a 60 Hz tone, switched at the tone's crest }
  Tone := NewTone(100, 0, 0);
  try
    Before := Feed(Tone, 60, 0, 4600, 4600);
    Tone.SetGains(0, 0, 0);
    Glided := Joined(Before, Feed(Tone, 60, 4600, 4800, 100000));
  finally
    Tone.Free;
  end;
  Tone := NewTone(100, 0, 0);
  try
    Before := Feed(Tone, 60, 0, 4600, 4600);
    Tone.SetGains(0, 0, 0);
    Tone.FinishGlide;                 // without the glide: at once
    Stepped := Joined(Before, Feed(Tone, 60, 4600, 4800, 100000));
  finally
    Tone.Free;
  end;
  AssertTrue(Format('Roughness with the glide %.1f, with a step %.1f: at least 20 times less',
    [Roughness(Glided), Roughness(Stepped)]), Roughness(Glided) * 20.0 < Roughness(Stepped));
  AssertTrue('Never louder than before the change', Peak(Glided, 0) <= G_AMP * Power(10.0, 10.0 / 20.0) * 1.01);

  { through 0 dB: +10 dB to -10 dB, treble under a 9 kHz tone }
  Tone := NewTone(0, 0, 100);
  try
    Before := Feed(Tone, 9000, 0, 4801, 4801);
    Tone.SetGains(0, 0, -100);
    Glided := Joined(Before, Feed(Tone, 9000, 4801, 4800, 100000));
    { a tone of that level alone has a roughness of about 1.9 x its peak }
    AssertTrue(Format('Through 0 dB: roughness %.1f', [Roughness(Glided)]),
      Roughness(Glided) <= 1.9 * G_AMP * Power(10.0, 10.0 / 20.0) * 1.02);
    Curve := TestCurve(0, 0, -100);
    AssertEquals('Arrived at the new level', G_AMP * Power(10.0, ToneResponseDB(Curve, 9000) / 20.0),
      Rms(Feed(Tone, 9000, 9601, 4800, 4800)) * Sqrt(2.0), G_AMP * 0.005);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneGlide.AfterTheGlideTheFiltersAreThoseOfTheSetting;
var
  Tone, Fresh: TToneControl;
  A, B: TDoubles;
  I: Integer;
  Worst: Double;
begin
  Tone := NewTone(60, -30, 20);
  Fresh := NewTone(-45, 50, -80);
  try
    Fresh.SetFrequencies(80, 2000, 10000);
    Feed(Tone, 440, 0, 4800, 512);
    Tone.SetGains(-45, 50, -80);
    Tone.SetFrequencies(80, 2000, 10000);
    Feed(Tone, 440, 4800, 4800, 512);
    AssertFalse('Arrived', Tone.Gliding);
    Feed(Fresh, 440, 0, 9600, 512);
    { both in the steady state of the same filters: the same samples }
    Feed(Tone, 440, 9600, 96000, 512);
    Feed(Fresh, 440, 9600, 96000, 512);
    A := Feed(Tone, 440, 105600, 480, 512);
    B := Feed(Fresh, 440, 105600, 480, 512);
    Worst := 0.0;
    for I := 0 to High(A) do
      if Abs(A[I] - B[I]) > Worst then Worst := Abs(A[I] - B[I]);
    AssertTrue(Format('Difference %.6g of %.0f', [Worst, G_AMP]), Worst < G_AMP * 1e-9);
  finally
    Tone.Free;
    Fresh.Free;
  end;
end;

procedure TTestToneGlide.OffGlidesToZeroAndThenBypasses;
var
  Tone: TToneControl;
  A: TDoubles;
  I: Integer;
begin
  Tone := NewTone(0, 80, 0);
  try
    Feed(Tone, 1000, 0, 4800, 4800);
    Tone.SetDirectMode(True);
    AssertTrue('Off: on its way', Tone.Gliding);
    AssertTrue('Still working until it has arrived', Tone.IsActive);
    A := Feed(Tone, 1000, 4800, 4800, 300);
    AssertFalse('Arrived', Tone.Gliding);
    AssertFalse('Bypassed', Tone.IsActive);
    for I := 4000 to 4799 do
      AssertEquals('Untouched samples', G_AMP * Sin(2.0 * Pi * 1000 * (4800 + I) / G_RATE), A[I]);
    AssertTrue('No step on the way', Roughness(A) < G_AMP * 0.05);
    { and on again: from 0 dB, with a glide }
    Tone.SetDirectMode(False);
    AssertTrue('On: gliding', Tone.Gliding);
    AssertTrue('On: active at once', Tone.IsActive);
    A := Feed(Tone, 1000, 9600, 9600, 300);
    AssertEquals('The boost is back', G_AMP * Power(10.0, 8.0 / 20.0), Peak(A, 4800), G_AMP * 0.01);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneGlide.TheStepsDoNotDependOnTheBlockSizes;
var
  One, Two: TToneControl;
  A, B: TDoubles;
  I, Diffs: Integer;
begin
  One := NewTone(60, -30, 20);
  Two := NewTone(60, -30, 20);
  try
    Feed(One, 440, 0, 4800, 4800);
    Feed(Two, 440, 0, 4800, 7);
    One.SetGains(-20, 40, 0);
    Two.SetGains(-20, 40, 0);
    A := Feed(One, 440, 4800, 4800, 100000);
    B := Feed(Two, 440, 4800, 4800, 1);
    Diffs := 0;
    for I := 0 to High(A) do
      if A[I] <> B[I] then Inc(Diffs);
    AssertEquals('Samples that differ', 0, Diffs);
  finally
    One.Free;
    Two.Free;
  end;
end;

procedure TTestToneGlide.StatePutBackInTheMiddleOfAGlide;
var
  Tone: TToneControl;
  Saved: TToneSnapshot;
  A, B: TDoubles;
  I, Diffs: Integer;
begin
  Tone := NewTone(60, -30, 20);
  try
    Feed(Tone, 440, 0, 4800, 4800);
    Tone.SetDirectMode(True);
    Feed(Tone, 440, 4800, 700, 64);
    AssertTrue('In the middle', Tone.Gliding);
    Tone.SaveState(Saved);
    A := Feed(Tone, 440, 5500, 3000, 64);
    AssertFalse('The look ahead went past the end', Tone.IsActive);
    Tone.RestoreState(Saved);
    AssertTrue('Back in the middle', Tone.Gliding and Tone.IsActive);
    B := Feed(Tone, 440, 5500, 3000, 333);
    Diffs := 0;
    for I := 0 to High(A) do
      if A[I] <> B[I] then Inc(Diffs);
    AssertEquals('Samples that differ', 0, Diffs);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneGlide.AResetEndsAGlide;
var
  Tone: TToneControl;
begin
  Tone := NewTone(60, 0, 0);
  try
    Feed(Tone, 440, 0, 4800, 4800);
    Tone.SetGains(0, 0, 0);
    AssertTrue(Tone.Gliding);
    Tone.ResetAllStates;              // a seek
    AssertFalse('No glide after a reset', Tone.Gliding);
    AssertFalse('And at the setting: off', Tone.IsActive);
    Tone.SetGains(30, 0, 0);
    AssertFalse('Nothing played since: at once', Tone.Gliding);
    Feed(Tone, 440, 0, 480, 480);
    Tone.SetSampleRate(96000);
    Tone.SetGains(50, 0, 0);
    AssertFalse('Another sample rate is a reset too', Tone.Gliding);
  finally
    Tone.Free;
  end;
end;

procedure TTestToneGlide.TheCurveIsWhatTheFiltersDo;
const
  FREQS: array[0..5] of Double = (30, 150, 700, 1000, 6000, 15000);
var
  Tone: TToneControl;
  Curve: TToneCurve;
  A: TDoubles;
  F: Integer;
  Measured: Double;
begin
  Curve := TestCurve(60, -45, 30);
  for F := 0 to High(FREQS) do
  begin
    Tone := NewTone(60, -45, 30);
    try
      Feed(Tone, FREQS[F], 0, 48000, 48000);
      A := Feed(Tone, FREQS[F], 48000, 9600, 9600);
      Measured := 20.0 * Log10(Rms(A) / (G_AMP / Sqrt(2.0)));
      AssertEquals(Format('%.0f Hz', [FREQS[F]]), Measured, ToneResponseDB(Curve, FREQS[F]), 0.02);
    finally
      Tone.Free;
    end;
  end;
  Curve := TestCurve(0, 0, 0);
  AssertEquals('Flat', 0.0, ToneResponseDB(Curve, 1000), 0.0);
  AssertEquals('Above half the rate: nothing', 0.0, ToneResponseDB(Curve, 30000), 0.0);
end;

initialization
  RegisterTest(TTestToneControl);
  RegisterTest(TTestToneGlide);

end.
