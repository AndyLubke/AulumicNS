unit TestResampler;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   AulumicNS - test program
  Unit Name: TestResampler

  Tests of the built-in resampler (AuResample, replaces libsoxr). Everything
  is computed, nothing is played:
    TTestResamplerFilters: the prototype filters (DesignPrototype) of the three
      phase responses: the same magnitude in the pass band (flat within
      0.01 dB), the stop band attenuation of the quality setting; minimum
      phase has no pre-ringing, intermediate lies between minimum and linear
    TTestResamplerSignals: sines through TAuStreamResampler at single and two
      stage ratios, up and down: the level is kept, what is left after the
      fitted sine (images, aliases) stays below the attenuation; a tone above
      the new Nyquist frequency is removed; a linear phase converter keeps an
      impulse in its place; chunked processing gives the very same output as
      one call; Reset starts again like a new converter; the output length
      follows the ratio; the FFT form of the stages is used, agrees with the
      direct form to the rounding and does not depend on the chunks
  =============================================================================}

interface

uses
  Classes, SysUtils, Math, fpcunit, testregistry, ALAudioTypes, AuResample;

type
  TTestResamplerFilters = class(TTestCase)
  private
    // |H(f)| / L in dB of a prototype at frequency AFreq (rate AFs)
    function GainDb(const H: TDoubleArray; L: Integer; AFreq, AFs: Double): Double;
    // how long before its peak H first reaches -80 dB of the peak, in input
    // samples (L taps of the prototype)
    function PreRinging(const H: TDoubleArray; L: Integer): Double;
  published
    procedure QualityGivesTheAttenuation;
    procedure AllPhasesHaveTheSameMagnitude;
    procedure MinimumPhaseHasNoPreRinging;
  end;

  TTestResamplerSignals = class(TTestCase)
  private
    // resamples AFrames stereo frames of AInput (then a second of silence to
    // flush the filter); AChunkIn / AChunkOut > 0: random block sizes up to that
    function Resample(AIn, AOut: Cardinal; APhase, AQuality: Integer; const AInput: TDoubleArray;
      AFrames: Integer; out AOutFrames: Integer; AChunkIn: Integer = 0;
      AChunkOut: Integer = 0): TDoubleArray;
    function Sine(AFreq, AAmp: Double; ARate: Cardinal; AFrames: Integer; AFreqR: Double): TDoubleArray;
    // least squares fit of a sine at AFreq to channel ACh of frames [AFrom, ATo):
    // the amplitude and the RMS of what is left, both linear
    procedure FitSine(const AData: TDoubleArray; ACh: Integer; AFrom, ATo: Integer;
      AFreq: Double; ARate: Cardinal; out AAmp, AResidual: Double);
    procedure CheckSineThrough(AIn, AOut: Cardinal; APhase: Integer);
  published
    procedure UpsamplingKeepsTheSine;
    procedure DownsamplingKeepsTheSine;
    procedure TwoStageRatiosKeepTheSine;
    procedure ToneAboveTheNewNyquistIsRemoved;
    procedure LinearPhaseKeepsAnImpulseInPlace;
    procedure ChunkedProcessingGivesTheSameOutput;
    procedure ResetStartsAgain;
    procedure OutputLengthFollowsTheRatio;
    procedure FftStagesAreUsed;
    procedure FftFormMatchesTheDirectForm;
    procedure FftChunkedProcessingGivesTheSameOutput;
  end;

implementation

const
  QUALITY    = 2;            // 24 bits: 144.5 dB
  BANDWIDTH  = 95.0;         // % of the lower Nyquist frequency
  ANTI_ALIAS = 100.0;

function Config(APhase, AQuality: Integer): TSoXConfig;
begin
  Result := Default(TSoXConfig);
  Result.Quality := AQuality;
  Result.UpsamplePhase := APhase;
  Result.DownsamplePhase := APhase;
  Result.Bandwidth := BANDWIDTH;
  Result.AntiAlias := ANTI_ALIAS;
end;

function ToDb(V: Double): Double;
begin
  if V <= 1e-300 then Result := -3000 else Result := 20 * Log10(V);
end;

{ TTestResamplerFilters }

function TTestResamplerFilters.GainDb(const H: TDoubleArray; L: Integer; AFreq, AFs: Double): Double;
var
  I: Integer;
  W, Re, Im: Double;
begin
  W := 2 * Pi * AFreq / AFs;
  Re := 0;
  Im := 0;
  for I := 0 to High(H) do
  begin
    Re := Re + H[I] * Cos(W * I);
    Im := Im - H[I] * Sin(W * I);
  end;
  Result := ToDb(Sqrt(Re * Re + Im * Im) / L);
end;

function TTestResamplerFilters.PreRinging(const H: TDoubleArray; L: Integer): Double;
var
  I, P, Onset: Integer;
begin
  P := 0;
  for I := 1 to High(H) do
    if Abs(H[I]) > Abs(H[P]) then P := I;
  Onset := P;
  for I := 0 to P do
    if Abs(H[I]) > 1e-4 * Abs(H[P]) then
    begin
      Onset := I;
      Break;
    end;
  Result := (P - Onset) / L;
end;

procedure TTestResamplerFilters.QualityGivesTheAttenuation;
begin
  AssertEquals('32 bits', 192.66, QualityAttenuation(0), 0.01);
  AssertEquals('24 bits', 144.49, QualityAttenuation(2), 0.01);
  AssertEquals('16 bits', 96.33, QualityAttenuation(4), 0.01);
  AssertTrue('Linear', PhaseOfSetting(0) = rpLinear);
  AssertTrue('Intermediate', PhaseOfSetting(1) = rpIntermediate);
  AssertTrue('Minimum', PhaseOfSetting(2) = rpMinimum);
end;

{ 44.1 -> 96 kHz: L = 320, the prototype runs at 44100 x 320 Hz }
procedure TTestResamplerFilters.AllPhasesHaveTheSameMagnitude;
const
  L = 320;
  FS_P = 44100.0 * L;
var
  Ph: TAuPhase;
  H: TDoubleArray;
  FT, I: Integer;
  Atten, Pass, Stop, F, G, Worst: Double;
  Name: string;
begin
  Atten := QualityAttenuation(QUALITY);
  Pass := 22050 * BANDWIDTH / 100;
  Stop := 22050 * ANTI_ALIAS / 100;
  for Ph := Low(TAuPhase) to High(TAuPhase) do
  begin
    WriteStr(Name, Ph);
    H := DesignPrototype(FS_P, Pass, Stop, Atten, L, Ph, FT);
    AssertTrue(Name + ': taps', Length(H) >= FT * L);
    { pass band: flat }
    Worst := 0;
    for I := 0 to 40 do
    begin
      F := Pass * I / 40;
      G := GainDb(H, L, F, FS_P);
      if Abs(G) > Worst then Worst := Abs(G);
    end;
    AssertTrue(Format('%s: pass band within 0.01 dB (%.5f dB)', [Name, Worst]), Worst < 0.01);
    { stop band: from the stop frequency to 8 times it, and some far out }
    Worst := -3000;
    for I := 0 to 160 do
    begin
      F := Stop + (8 * Stop - Stop) * I / 160;
      G := GainDb(H, L, F, FS_P);
      if G > Worst then Worst := G;
    end;
    for I := 1 to 20 do
    begin
      G := GainDb(H, L, FS_P / 2 * I / 20, FS_P);
      if G > Worst then Worst := G;
    end;
    AssertTrue(Format('%s: stop band below -%.0f dB (%.1f dB)', [Name, Atten - 6, Worst]),
      Worst < -(Atten - 6));
  end;
end;

procedure TTestResamplerFilters.MinimumPhaseHasNoPreRinging;
const
  L = 320;
  FS_P = 44100.0 * L;
var
  H: TDoubleArray;
  FT: Integer;
  Atten, Pass, Stop, PreLin, PreInt, PreMin: Double;
begin
  Atten := QualityAttenuation(QUALITY);
  Pass := 22050 * BANDWIDTH / 100;
  Stop := 22050 * ANTI_ALIAS / 100;
  H := DesignPrototype(FS_P, Pass, Stop, Atten, L, rpLinear, FT);
  PreLin := PreRinging(H, L);
  H := DesignPrototype(FS_P, Pass, Stop, Atten, L, rpIntermediate, FT);
  PreInt := PreRinging(H, L);
  H := DesignPrototype(FS_P, Pass, Stop, Atten, L, rpMinimum, FT);
  PreMin := PreRinging(H, L);
  AssertTrue(Format('Linear rings long before the peak (%.1f samples)', [PreLin]), PreLin > 50);
  { minimum phase: from -80 dB to the peak in a few samples - the rise of
    the pulse itself (about 0.1 ms at 44.1 kHz), no ringing before it }
  AssertTrue(Format('Minimum: only the rise of the pulse (%.1f samples)', [PreMin]), PreMin < 8);
  AssertTrue(Format('Intermediate between (%.1f < %.1f < %.1f)', [PreMin, PreInt, PreLin]),
    (PreInt > 2 * PreMin) and (PreInt < 0.75 * PreLin));
end;

{ TTestResamplerSignals }

function TTestResamplerSignals.Resample(AIn, AOut: Cardinal; APhase, AQuality: Integer;
  const AInput: TDoubleArray; AFrames: Integer; out AOutFrames: Integer;
  AChunkIn: Integer; AChunkOut: Integer): TDoubleArray;
var
  R: TAuStreamResampler;
  Src: TDoubleArray;
  Total, Pos, InN, OutN, InDone, OutDone, Cap, Stuck: Integer;
begin
  { the input and a second of silence that pushes the filter's tail out }
  Total := AFrames + Integer(AIn);
  Src := nil;
  SetLength(Src, Total * 2);
  if AFrames > 0 then Move(AInput[0], Src[0], AFrames * 2 * SizeOf(Double));
  Cap := Trunc(Int64(Total) * AOut / AIn) + 100000;
  Result := nil;
  SetLength(Result, Cap * 2);
  AOutFrames := 0;
  Pos := 0;
  Stuck := 0;
  R := TAuStreamResampler.Create(AIn, AOut, 2, Config(APhase, AQuality));
  try
    while (Pos < Total) and (Stuck < 3) do
    begin
      InN := Total - Pos;
      if AChunkIn > 0 then InN := Min(InN, 1 + Random(AChunkIn));
      OutN := Cap - AOutFrames;
      if AChunkOut > 0 then OutN := Min(OutN, 1 + Random(AChunkOut));
      R.Process(@Src[Pos * 2], InN, InDone, @Result[AOutFrames * 2], OutN, OutDone);
      Inc(Pos, InDone);
      Inc(AOutFrames, OutDone);
      if (InDone = 0) and (OutDone = 0) then Inc(Stuck) else Stuck := 0;
    end;
    { what is still waiting inside (the FFT stages compute their last block
      at the Flush, as the engine has them do at the end of a file) }
    R.Flush;
    repeat
      OutN := Cap - AOutFrames;
      if AChunkOut > 0 then OutN := Min(OutN, 1 + Random(AChunkOut));
      R.Process(nil, 0, InDone, @Result[AOutFrames * 2], OutN, OutDone);
      Inc(AOutFrames, OutDone);
    until OutDone = 0;
  finally
    R.Free;
  end;
  AssertTrue('All input taken', Pos = Total);
end;

function TTestResamplerSignals.Sine(AFreq, AAmp: Double; ARate: Cardinal; AFrames: Integer;
  AFreqR: Double): TDoubleArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, AFrames * 2);
  for I := 0 to AFrames - 1 do
  begin
    Result[2 * I] := AAmp * Sin(2 * Pi * AFreq * I / ARate);
    { the right channel: another tone, at half the level }
    Result[2 * I + 1] := 0.5 * AAmp * Sin(2 * Pi * AFreqR * I / ARate + 1.0);
  end;
end;

procedure TTestResamplerSignals.FitSine(const AData: TDoubleArray; ACh: Integer; AFrom, ATo: Integer;
  AFreq: Double; ARate: Cardinal; out AAmp, AResidual: Double);
var
  I: Integer;
  W, S, C, Y, S11, S12, S22, R1, R2, Det, A, B, E: Double;
begin
  W := 2 * Pi * AFreq / ARate;
  S11 := 0; S12 := 0; S22 := 0; R1 := 0; R2 := 0;
  for I := AFrom to ATo - 1 do
  begin
    S := Sin(W * I);
    C := Cos(W * I);
    Y := AData[2 * I + ACh];
    S11 := S11 + S * S;
    S12 := S12 + S * C;
    S22 := S22 + C * C;
    R1 := R1 + Y * S;
    R2 := R2 + Y * C;
  end;
  Det := S11 * S22 - S12 * S12;
  A := (R1 * S22 - R2 * S12) / Det;
  B := (R2 * S11 - R1 * S12) / Det;
  AAmp := Sqrt(A * A + B * B);
  E := 0;
  for I := AFrom to ATo - 1 do
    E := E + Sqr(AData[2 * I + ACh] - A * Sin(W * I) - B * Cos(W * I));
  AResidual := Sqrt(E / (ATo - AFrom));
end;

procedure TTestResamplerSignals.CheckSineThrough(AIn, AOut: Cardinal; APhase: Integer);
const
  LEVEL = 0.5;
  F_L = 1000.0;
  F_R = 17000.0;     // near the top of the pass band of 44.1 kHz
var
  Input, Output: TDoubleArray;
  OutFrames, A, B: Integer;
  Got, Res, Limit: Double;
  Name: string;
begin
  Name := Format('%d -> %d, phase %d', [AIn, AOut, APhase]);
  Input := Sine(F_L, LEVEL, AIn, AIn, F_R);          // one second
  Output := Resample(AIn, AOut, APhase, QUALITY, Input, AIn, OutFrames);
  { the middle half second: away from the start and the end }
  A := Integer(AOut) div 4;
  B := 3 * Integer(AOut) div 4;
  AssertTrue(Name + ': enough output', OutFrames > B);
  Limit := -(QualityAttenuation(QUALITY) - 20);   // 124 dB below the tone
  FitSine(Output, 0, A, B, F_L, AOut, Got, Res);
  AssertEquals(Name + ': left level (dB)', 0, ToDb(Got / LEVEL), 0.01);
  AssertTrue(Format('%s: left residual %.1f dB', [Name, ToDb(Res / (LEVEL / Sqrt(2)))]),
    ToDb(Res / (LEVEL / Sqrt(2))) < Limit);
  FitSine(Output, 1, A, B, F_R, AOut, Got, Res);
  AssertEquals(Name + ': right level (dB)', 0, ToDb(Got / (0.5 * LEVEL)), 0.01);
  AssertTrue(Format('%s: right residual %.1f dB', [Name, ToDb(Res / (0.5 * LEVEL / Sqrt(2)))]),
    ToDb(Res / (0.5 * LEVEL / Sqrt(2))) < Limit);
end;

procedure TTestResamplerSignals.UpsamplingKeepsTheSine;
var
  Ph: Integer;
begin
  for Ph := 0 to 2 do
  begin
    CheckSineThrough(44100, 96000, Ph);
    CheckSineThrough(48000, 88200, Ph);
  end;
end;

procedure TTestResamplerSignals.DownsamplingKeepsTheSine;
var
  Ph: Integer;
begin
  for Ph := 0 to 2 do
  begin
    CheckSineThrough(96000, 44100, Ph);
    CheckSineThrough(88200, 48000, Ph);
  end;
end;

procedure TTestResamplerSignals.TwoStageRatiosKeepTheSine;
var
  Ph: Integer;
begin
  for Ph := 0 to 2 do
  begin
    CheckSineThrough(44100, 192000, Ph);
    CheckSineThrough(192000, 44100, Ph);
  end;
end;

{ 96 -> 44.1 kHz: a 30 kHz tone would fold to 14.1 kHz }
procedure TTestResamplerSignals.ToneAboveTheNewNyquistIsRemoved;
const
  AMP = 0.5;
var
  Input, Output: TDoubleArray;
  OutFrames, I, A, B, Ph: Integer;
  E, Level: Double;
begin
  for Ph := 0 to 2 do
  begin
    Input := Sine(30000, AMP, 96000, 96000, 40000);
    Output := Resample(96000, 44100, Ph, QUALITY, Input, 96000, OutFrames);
    A := 44100 div 4;
    B := 3 * 44100 div 4;
    E := 0;
    for I := A to B - 1 do E := E + Sqr(Output[2 * I]) + Sqr(Output[2 * I + 1]);
    Level := ToDb(Sqrt(E / (2 * (B - A))) / (AMP / Sqrt(2)));
    AssertTrue(Format('Phase %d: what is left %.1f dB', [Ph, Level]),
      Level < -(QualityAttenuation(QUALITY) - 20));
  end;
end;

{ linear phase: the delay of the filter is taken out, an impulse at input
  frame N comes out at N x Out / In }
procedure TTestResamplerSignals.LinearPhaseKeepsAnImpulseInPlace;
const
  AT = 10000;
var
  Input, Output: TDoubleArray;
  OutFrames, I, Peak: Integer;
  Expected: Double;
begin
  Input := nil;
  SetLength(Input, 2 * 20000);
  Input[2 * AT] := 1;
  Input[2 * AT + 1] := -1;
  Output := Resample(44100, 88200, 0, QUALITY, Input, 20000, OutFrames);
  Peak := 0;
  for I := 1 to OutFrames - 1 do
    if Abs(Output[2 * I]) > Abs(Output[2 * Peak]) then Peak := I;
  Expected := AT * 2;
  AssertEquals('The impulse stays in place', Expected, Peak, 1);
  AssertTrue('Right channel inverted', Output[2 * Peak + 1] < 0);
end;

procedure TTestResamplerSignals.ChunkedProcessingGivesTheSameOutput;
var
  Input, Whole, Chunked: TDoubleArray;
  I, N1, N2, Ph: Integer;
begin
  RandSeed := 12345;
  Input := nil;
  SetLength(Input, 2 * 30000);
  for I := 0 to High(Input) do Input[I] := Random - 0.5;
  for Ph := 0 to 2 do
  begin
    Whole := Resample(44100, 96000, Ph, QUALITY, Input, 30000, N1);
    RandSeed := 777 + Ph;
    Chunked := Resample(44100, 96000, Ph, QUALITY, Input, 30000, N2, 997, 613);
    AssertEquals(Format('Phase %d: the same length', [Ph]), N1, N2);
    for I := 0 to 2 * N1 - 1 do
      if Whole[I] <> Chunked[I] then
        Fail(Format('Phase %d: differs at sample %d (%g / %g)', [Ph, I, Whole[I], Chunked[I]]));
  end;
end;

procedure TTestResamplerSignals.ResetStartsAgain;
var
  A, B: TDoubleArray;
  R: TAuStreamResampler;
  O1, O2: TDoubleArray;
  InDone, D1, D2, I, Total1, Total2: Integer;
begin
  A := Sine(1000, 0.5, 44100, 20000, 3000);
  B := Sine(5000, 0.3, 44100, 20000, 7000);
  O1 := nil;
  O2 := nil;
  SetLength(O1, 2 * 60000);
  SetLength(O2, 2 * 60000);
  { a converter that had other music before the Reset ... }
  R := TAuStreamResampler.Create(44100, 96000, 2, Config(2, QUALITY));
  try
    R.Process(@A[0], 20000, InDone, @O1[0], 60000, D1);
    R.Reset;
    Total1 := 0;
    I := 0;
    repeat
      R.Process(@B[I * 2], 20000 - I, InDone, @O1[Total1 * 2], 60000 - Total1, D1);
      Inc(I, InDone);
      Inc(Total1, D1);
    until (I >= 20000) or ((InDone = 0) and (D1 = 0));
  finally
    R.Free;
  end;
  { ... gives what a new one gives }
  R := TAuStreamResampler.Create(44100, 96000, 2, Config(2, QUALITY));
  try
    Total2 := 0;
    I := 0;
    repeat
      R.Process(@B[I * 2], 20000 - I, InDone, @O2[Total2 * 2], 60000 - Total2, D2);
      Inc(I, InDone);
      Inc(Total2, D2);
    until (I >= 20000) or ((InDone = 0) and (D2 = 0));
  finally
    R.Free;
  end;
  AssertEquals('The same length', Total2, Total1);
  for I := 0 to 2 * Total1 - 1 do
    if O1[I] <> O2[I] then Fail(Format('Differs at sample %d', [I]));
end;

procedure TTestResamplerSignals.OutputLengthFollowsTheRatio;
const
  RATES: array[0..5] of array[0..1] of Cardinal =
    ((44100, 96000), (96000, 44100), (44100, 192000), (192000, 44100), (48000, 44100), (44100, 48000));
var
  I, OutFrames: Integer;
  Input: TDoubleArray;
  Expected: Double;
begin
  for I := 0 to High(RATES) do
  begin
    Input := Sine(1000, 0.5, RATES[I][0], 10000, 2000);
    Resample(RATES[I][0], RATES[I][1], 0, QUALITY, Input, 10000, OutFrames);
    { the input and the second of silence after it; the filter holds back
      its delay (a few ms), never more than the ratio gives }
    Expected := (10000 + Int64(RATES[I][0])) * RATES[I][1] / RATES[I][0];
    AssertTrue(Format('%d -> %d: %d frames for %.0f', [RATES[I][0], RATES[I][1], OutFrames, Expected]),
      (OutFrames <= Expected + 1) and (OutFrames >= Expected - 0.02 * RATES[I][1]));
  end;
end;

{ ---> 2026-11-11: the FFT form of the stages (2x up, 2:1 down, the short
  upsampling stages): the ratios below take it }
procedure TTestResamplerSignals.FftStagesAreUsed;
const
  RATES: array[0..3] of array[0..1] of Cardinal =
    ((44100, 88200), (88200, 44100), (44100, 705600), (176400, 44100));
var
  I: Integer;
  R: TAuResampler;
  S: string;
begin
  for I := 0 to High(RATES) do
  begin
    R := TAuResampler.Create(RATES[I][0], RATES[I][1], 2, Config(1, QUALITY));
    try
      S := R.Describe;
    finally
      R.Free;
    end;
    AssertTrue(Format('%d -> %d: %s', [RATES[I][0], RATES[I][1], S]), Pos('FFT', S) > 0);
  end;
end;

{ the same filter, only computed another way: the outputs agree to the
  rounding of doubles (far below 1e-12 of full scale = -240 dB) }
procedure TTestResamplerSignals.FftFormMatchesTheDirectForm;
const
  RATES: array[0..4] of array[0..1] of Cardinal =
    ((44100, 88200), (88200, 44100), (44100, 705600), (176400, 44100), (192000, 768000));
var
  Input, ByFft, Direct: TDoubleArray;
  I, J, Ph, N1, N2, Frames: Integer;
  Worst: Double;
begin
  for I := 0 to High(RATES) do
    for Ph := 0 to 2 do
    begin
      Frames := Integer(RATES[I][0]) div 2;
      RandSeed := 4321 + I;
      Input := nil;
      SetLength(Input, 2 * Frames);
      for J := 0 to High(Input) do Input[J] := Random - 0.5;
      ByFft := Resample(RATES[I][0], RATES[I][1], Ph, QUALITY, Input, Frames, N1);
      SetResampleFft(False);
      try
        Direct := Resample(RATES[I][0], RATES[I][1], Ph, QUALITY, Input, Frames, N2);
      finally
        SetResampleFft(True);
      end;
      AssertEquals(Format('%d -> %d, phase %d: the same length', [RATES[I][0], RATES[I][1], Ph]), N2, N1);
      Worst := 0;
      for J := 0 to 2 * N1 - 1 do
        if Abs(ByFft[J] - Direct[J]) > Worst then Worst := Abs(ByFft[J] - Direct[J]);
      AssertTrue(Format('%d -> %d, phase %d: differs by %g', [RATES[I][0], RATES[I][1], Ph, Worst]),
        Worst < 1E-12);
    end;
end;

{ the blocks lie at fixed places of the stream: any cutting of the input and
  the output gives the very same bits }
procedure TTestResamplerSignals.FftChunkedProcessingGivesTheSameOutput;
const
  RATES: array[0..2] of array[0..1] of Cardinal = ((44100, 705600), (88200, 44100), (176400, 44100));
var
  Input, Whole, Chunked: TDoubleArray;
  I, J, N1, N2: Integer;
begin
  for I := 0 to High(RATES) do
  begin
    RandSeed := 999 + I;
    Input := nil;
    SetLength(Input, 2 * 40000);
    for J := 0 to High(Input) do Input[J] := Random - 0.5;
    Whole := Resample(RATES[I][0], RATES[I][1], 1, QUALITY, Input, 40000, N1);
    RandSeed := 31 + I;
    Chunked := Resample(RATES[I][0], RATES[I][1], 1, QUALITY, Input, 40000, N2, 1777, 2903);
    AssertEquals(Format('%d -> %d: the same length', [RATES[I][0], RATES[I][1]]), N1, N2);
    for J := 0 to 2 * N1 - 1 do
      if Whole[J] <> Chunked[J] then
        Fail(Format('%d -> %d: differs at sample %d', [RATES[I][0], RATES[I][1], J]));
  end;
end;

initialization
  RegisterTest(TTestResamplerFilters);
  RegisterTest(TTestResamplerSignals);

end.
