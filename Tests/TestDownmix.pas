unit TestDownmix;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestDownmix
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  PCM files with more than two channels are mixed to stereo (TDownmixSource).
  The weights of every channel layout, the samples of a 5.1 file in 16 and
  24 bit against the sums worked out here, the same samples whatever the
  read sizes, seeking, what the source factory builds, and the play thread:
  the mix at its safe level, the level given back with the automatic
  headroom, full scale in every channel without an overflow, and never
  reported as bit-perfect.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, TestPlayback;

type
  TTestDownmix = class(TTestCase)
  private
    FDir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheWeightsFollowTheChannelLayout;
    procedure EveryLayoutHasAName;
    procedure A51FileIn16BitIsTheWeightedSum;
    procedure A51FileIn24BitIsTheWeightedSum;
    procedure A51FlacIsTheWeightedSum;
    procedure FullScaleInEveryChannelStaysInside;
    procedure OddReadSizesGiveTheSameSamples;
    procedure SeekContinuesAtTheTarget;
    procedure TheFactoryMixesDownOnlyAboveTwoChannels;
    procedure TheFactoryPutsTheResamplerBehindTheMix;
  end;

  TTestPlaybackDownmix = class(TPlaybackTestBase)
  published
    procedure PlaysAtTheSafeLevelAndIsNotBitPerfect;
    procedure TheAutomaticHeadroomGivesTheLevelBack;
    procedure FullScaleWithTheHeadroomDoesNotOverflow;
    procedure AStereoTrackAfterItIsBitPerfectAgain;
    procedure A51FlacPlaysAsTheSameMix;
  end;

implementation

uses
  Math, ALAudioTypes, ALReaders, ALSourceFactory, uAudioUtils, TestHelpers;

const
  SIDE   = 0.70710678118654752;
  NORM51 = 1.0 + 2.0 * SIDE;

// The sample of a made-up multichannel file: every frame and channel
// different, both signs, well inside ABits
function ChanSample(AFrame, AChannel, ABits: Integer): Integer;
var
  V: Integer;
begin
  V := ((AFrame * 37 + AChannel * 1009 + 11) mod 20001) - 10000;   // -10000 .. 10000
  if ABits = 24 then
    V := V * 256 + ((AFrame + AChannel) and $FF);
  Result := V;
end;

procedure PutSample(var AData: TBytes; var APos: Integer; AValue, ABits: Integer);
begin
  AData[APos] := Byte(AValue and $FF);
  AData[APos + 1] := Byte((AValue shr 8) and $FF);
  if ABits = 24 then
    AData[APos + 2] := Byte((AValue shr 16) and $FF);
  Inc(APos, ABits div 8);
end;

// A PCM WAV file of AFrames frames and AChannels channels of ChanSample, or
// of AFixed in every sample when AUseFixed
procedure WriteChanWav(const APath: string; AFrames, AChannels, ABits: Integer;
  AUseFixed: Boolean = False; AFixed: Integer = 0; ARate: Integer = 44100);
var
  Data: TBytes;
  F, C, P: Integer;
begin
  Data := nil;
  SetLength(Data, AFrames * AChannels * (ABits div 8));
  P := 0;
  for F := 0 to AFrames - 1 do
    for C := 0 to AChannels - 1 do
      if AUseFixed then
        PutSample(Data, P, AFixed, ABits)
      else
        PutSample(Data, P, ChanSample(F, C, ABits), ABits);
  WriteWavData(APath, ARate, ABits, AChannels, Data);
end;

// What a 5.1 frame of ChanSample comes out as (AGain 1 = the safe level)
procedure Expect51(AFrame, ABits: Integer; AGain: Double; out AL, AR: Double);
var
  Up: Double;
begin
  if ABits = 24 then Up := 256.0 else Up := 65536.0;
  AL := (ChanSample(AFrame, 0, ABits) + SIDE * ChanSample(AFrame, 2, ABits) +
         SIDE * ChanSample(AFrame, 4, ABits)) * Up / NORM51 * AGain;
  AR := (ChanSample(AFrame, 1, ABits) + SIDE * ChanSample(AFrame, 2, ABits) +
         SIDE * ChanSample(AFrame, 5, ABits)) * Up / NORM51 * AGain;
end;

function ReadAll(ASource: TAudioSource; AChunk: Integer): TBytes;
var
  Got, Total: Integer;
begin
  Result := nil;
  Total := 0;
  repeat
    SetLength(Result, Total + AChunk);
    Got := ASource.ReadData(@Result[Total], AChunk);
    if Got > 0 then Inc(Total, Got);
  until Got <= 0;
  SetLength(Result, Total);
end;

function Int32At(const AData: TBytes; AIndex: Integer): Integer;
begin
  Result := PInteger(@AData[AIndex * 4])^;
end;

{ TTestDownmix }

procedure TTestDownmix.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestDownmix.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure TTestDownmix.TheWeightsFollowTheChannelLayout;
var
  L, R: TDownmixWeights;
  N: Double;
  I: Integer;
begin
  DownmixMatrix(6, L, R, N);                      // L R C LFE Ls Rs
  AssertEquals('5.1: the largest sum', NORM51, N, 1e-12);
  AssertEquals('Front left to the left', 1.0, L[0], 0);
  AssertEquals('Front left not to the right', 0.0, R[0], 0);
  AssertEquals('Front right to the right', 1.0, R[1], 0);
  AssertEquals('Centre to the left', SIDE, L[2], 1e-12);
  AssertEquals('Centre to the right', SIDE, R[2], 1e-12);
  AssertEquals('LFE left out (left)', 0.0, L[3], 0);
  AssertEquals('LFE left out (right)', 0.0, R[3], 0);
  AssertEquals('Left surround to the left', SIDE, L[4], 1e-12);
  AssertEquals('Left surround not to the right', 0.0, R[4], 0);
  AssertEquals('Right surround to the right', SIDE, R[5], 1e-12);

  DownmixMatrix(3, L, R, N);                      // L R C
  AssertEquals('3.0', 1.0 + SIDE, N, 1e-12);
  DownmixMatrix(4, L, R, N);                      // L R Ls Rs
  AssertEquals('Quadraphonic', 1.0 + SIDE, N, 1e-12);
  AssertEquals('Quadraphonic: the third channel is a surround', 0.0, R[2], 0);
  DownmixMatrix(5, L, R, N);                      // L R C Ls Rs
  AssertEquals('5.0', NORM51, N, 1e-12);
  AssertEquals('5.0: the fourth channel is a surround', SIDE, L[3], 1e-12);
  DownmixMatrix(7, L, R, N);                      // L R C LFE Cs Sl Sr
  AssertEquals('6.1', 1.0 + SIDE + 0.5 + SIDE, N, 1e-12);
  AssertEquals('6.1: the rear centre to both', 0.5, R[4], 0);
  DownmixMatrix(8, L, R, N);                      // L R C LFE Bl Br Sl Sr
  AssertEquals('7.1', 1.0 + 3.0 * SIDE, N, 1e-12);

  DownmixMatrix(12, L, R, N);
  AssertEquals('An unknown layout: the first two channels as they are', 1.0, N, 0);
  for I := 2 to High(L) do
    AssertEquals('Nothing else', 0.0, L[I] + R[I], 0);
end;

procedure TTestDownmix.EveryLayoutHasAName;
begin
  AssertEquals('3.0', ChannelLayoutName(3));
  AssertEquals('quadraphonic', ChannelLayoutName(4));
  AssertEquals('5.0', ChannelLayoutName(5));
  AssertEquals('5.1', ChannelLayoutName(6));
  AssertEquals('6.1', ChannelLayoutName(7));
  AssertEquals('7.1', ChannelLayoutName(8));
  AssertEquals('12 channels', ChannelLayoutName(12));
end;

procedure CheckSums(ATest: TTestCase; const AData: TBytes; AFrames, ABits, AFirst: Integer);
var
  F: Integer;
  L, R: Double;
begin
  ATest.AssertEquals('All frames, 32-bit stereo', AFrames * 8, Length(AData));
  for F := 0 to AFrames - 1 do
  begin
    Expect51(AFirst + F, ABits, 1.0, L, R);
    if (Int32At(AData, F * 2) <> Round(L)) or (Int32At(AData, F * 2 + 1) <> Round(R)) then
      ATest.Fail(Format('Frame %d: %d / %d, expected %d / %d', [F, Int32At(AData, F * 2),
        Int32At(AData, F * 2 + 1), Round(L), Round(R)]));
  end;
end;

procedure TTestDownmix.A51FileIn16BitIsTheWeightedSum;
var
  S: TAudioSource;
begin
  WriteChanWav(FDir + 'a.wav', 5000, 6, 16);
  S := TDownmixSource.Create(TWavSource.Create(FDir + 'a.wav'));
  try
    AssertEquals('Stereo', 2, Integer(S.GetChannels));
    AssertEquals('32 bit', 32, Integer(S.GetBitsPerSample));
    AssertEquals('The rate of the file', 44100, Integer(S.GetSampleRate));
    CheckSums(Self, ReadAll(S, 8 * 1024), 5000, 16, 0);
  finally
    S.Free;
  end;
end;

procedure TTestDownmix.A51FileIn24BitIsTheWeightedSum;
var
  S: TAudioSource;
begin
  WriteChanWav(FDir + 'a.wav', 5000, 6, 24);
  S := TDownmixSource.Create(TWavSource.Create(FDir + 'a.wav'));
  try
    CheckSums(Self, ReadAll(S, 8 * 1024), 5000, 24, 0);
  finally
    S.Free;
  end;
end;

procedure TTestDownmix.A51FlacIsTheWeightedSum;
var
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate: Integer;
begin
  // six channels through the FLAC decoder, in 16 and in 24 bit; more frames
  // than one block of the file
  C := Default(TPlayThreadConfig);
  WriteChannelFlac(FDir + 'a.flac', 9000, 6, @ChanSample, 44100, 16);
  S := CreateSourceFor(C, 0, nil, FDir + 'a.flac', InRate, OutRate);
  try
    AssertTrue('A downmix in the chain', Assigned(S.FindLayer(TDownmixSource)));
    AssertEquals('Stereo', 2, Integer(S.GetChannels));
    CheckSums(Self, ReadAll(S, 8 * 1024), 9000, 16, 0);
  finally
    S.Free;
  end;

  WriteChannelFlac(FDir + 'b.flac', 9000, 6, @ChanSample, 96000, 24);
  S := CreateSourceFor(C, 0, nil, FDir + 'b.flac', InRate, OutRate);
  try
    AssertEquals('At the rate of the file', 96000, OutRate);
    CheckSums(Self, ReadAll(S, 8 * 333), 9000, 24, 0);
  finally
    S.Free;
  end;
end;

procedure TTestDownmix.FullScaleInEveryChannelStaysInside;
var
  S: TAudioSource;
  D: TBytes;
  I: Integer;
begin
  // The most negative sample in all eight channels: the largest sum there is
  WriteChanWav(FDir + 'a.wav', 100, 8, 16, True, -32768);
  S := TDownmixSource.Create(TWavSource.Create(FDir + 'a.wav'));
  try
    D := ReadAll(S, 4096);
    AssertEquals(100 * 8, Length(D));
    for I := 0 to 199 do
      AssertEquals('Exactly full scale, no wrap', Low(Integer), Int32At(D, I));
  finally
    S.Free;
  end;
end;

procedure TTestDownmix.OddReadSizesGiveTheSameSamples;
var
  S: TAudioSource;
  A, B: TBytes;
begin
  // more frames than one slice of the source's buffer holds
  WriteChanWav(FDir + 'a.wav', 9000, 6, 24);
  S := TDownmixSource.Create(TWavSource.Create(FDir + 'a.wav'));
  try
    A := ReadAll(S, 64 * 1024);
  finally
    S.Free;
  end;
  S := TDownmixSource.Create(TWavSource.Create(FDir + 'a.wav'));
  try
    B := ReadAll(S, 8 * 37);
  finally
    S.Free;
  end;
  AssertEquals('The same length', Length(A), Length(B));
  AssertEquals('All frames', 9000 * 8, Length(A));
  AssertTrue('The same bytes', CompareMem(@A[0], @B[0], Length(A)));
end;

procedure TTestDownmix.SeekContinuesAtTheTarget;
var
  S: TAudioSource;
  D: TBytes;
begin
  WriteChanWav(FDir + 'a.wav', 4000, 6, 16);
  S := TDownmixSource.Create(TWavSource.Create(FDir + 'a.wav'));
  try
    S.Seek(0.5);
    D := ReadAll(S, 8 * 1024);
    CheckSums(Self, D, 2000, 16, 2000);
  finally
    S.Free;
  end;
end;

procedure TTestDownmix.TheFactoryMixesDownOnlyAboveTwoChannels;
var
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate: Integer;
  Mix: TAudioSource;
begin
  C := Default(TPlayThreadConfig);
  WriteChanWav(FDir + 'six.wav', 2000, 6, 16);
  WriteChanWav(FDir + 'two.wav', 2000, 2, 16);
  WriteChanWav(FDir + 'one.wav', 2000, 1, 16);

  S := CreateSourceFor(C, 0, nil, FDir + 'six.wav', InRate, OutRate);
  try
    AssertEquals('Stereo behind the factory', 2, Integer(S.GetChannels));
    Mix := S.FindLayer(TDownmixSource);
    AssertTrue('A downmix in the chain', Assigned(Mix));
    AssertEquals('Of six channels', 6, TDownmixSource(Mix).SourceChannels);
    AssertEquals('Of a 16 bit file', 16, TDownmixSource(Mix).SourceBits);
    AssertEquals('Scaled by the largest sum', NORM51, TDownmixSource(Mix).MakeupGain, 1e-12);
    AssertEquals('At the rate of the file', 44100, OutRate);
    CheckSums(Self, ReadAll(S, 8 * 1024), 2000, 16, 0);
  finally
    S.Free;
  end;

  S := CreateSourceFor(C, 0, nil, FDir + 'two.wav', InRate, OutRate);
  try
    AssertFalse('Stereo is left alone', Assigned(S.FindLayer(TDownmixSource)));
    AssertEquals('In its own bit depth', 16, Integer(S.GetBitsPerSample));
  finally
    S.Free;
  end;

  S := CreateSourceFor(C, 0, nil, FDir + 'one.wav', InRate, OutRate);
  try
    AssertFalse('Mono is doubled, not mixed', Assigned(S.FindLayer(TDownmixSource)));
    AssertEquals(2, Integer(S.GetChannels));
  finally
    S.Free;
  end;
end;

procedure TTestDownmix.TheFactoryPutsTheResamplerBehindTheMix;
var
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate: Integer;
  D: TBytes;
begin
  C := Default(TPlayThreadConfig);
  C.ResamplePCM       := True;
  C.TargetSampleRate  := 88200;
  C.ResampleQuality   := 2;
  C.ResampleBandWidth := VAL_DEF_BANDWIDTH_FLOAT;
  C.ResampleAntiAlias := VAL_DEF_ANTI_ALIAS_FLOAT;
  SetLength(C.RateMaps, 1);
  C.RateMaps[0].InRate  := 44100;
  C.RateMaps[0].OutRate := 88200;

  WriteChanWav(FDir + 'six.wav', 8000, 6, 16);
  S := CreateSourceFor(C, 0, nil, FDir + 'six.wav', InRate, OutRate);
  try
    AssertEquals('In at the rate of the file', 44100, InRate);
    AssertEquals('Out at the target', 88200, OutRate);
    AssertEquals('Stereo', 2, Integer(S.GetChannels));
    AssertTrue('The resampler', Assigned(S.FindLayer(TResamplerSource)));
    AssertTrue('The downmix under it', Assigned(S.FindLayer(TDownmixSource)));
    D := ReadAll(S, 16 * 1024);
    AssertTrue('About twice the frames', Abs(Length(D) div (2 * (S.GetBitsPerSample div 8)) - 16000) < 400);
  finally
    S.Free;
  end;
end;

{ TTestPlaybackDownmix }

const
  PLAY_FRAMES = 30000;
  SKIP_FRAMES = 4000;      // a glide to the first gain is over by then

// The recorded 32-bit stereo data against the 5.1 sums times AGain, within
// ATol steps of 32 bit, from frame AFrom on
procedure CheckPlayed(ATest: TTestCase; const AData: TBytes; ABits: Integer; AGain: Double;
  AFrom, ACount: Integer; ATol: Double);
var
  F: Integer;
  L, R: Double;
begin
  ATest.AssertTrue('All frames were played', Length(AData) >= ACount * 8);
  for F := AFrom to ACount - 1 do
  begin
    Expect51(F, ABits, AGain, L, R);
    if (Abs(Int32At(AData, F * 2) - L) > ATol) or (Abs(Int32At(AData, F * 2 + 1) - R) > ATol) then
      ATest.Fail(Format('Frame %d: %d / %d, expected %.1f / %.1f', [F, Int32At(AData, F * 2),
        Int32At(AData, F * 2 + 1), L, R]));
  end;
end;

procedure TTestPlaybackDownmix.PlaysAtTheSafeLevelAndIsNotBitPerfect;
var
  Si: TSignalInfo;
begin
  WriteChanWav(FDir + 'six.wav', PLAY_FRAMES, 6, 16);
  // the signal path is read while the track plays
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'six.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  Si := FThread.GetSignalInfo;
  FRecorder.GoOn;
  AssertEquals('Six channels in the signal path', 6, Si.DownmixFrom);
  AssertEquals('Of 16 bit', 16, Si.DownmixBits);
  AssertEquals('At the safe level', -20.0 * Log10(NORM51), Si.DownmixDB, 0.001);
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  AssertEquals('At the rate of the file', 44100, Integer(FRecorder.Opens(0).Rate));
  // nothing but the mix touches the samples: exact
  CheckPlayed(Self, FRecorder.Data, 16, 1.0, 0, PLAY_FRAMES, 0.5);
  AssertFalse('A mix is not bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlaybackDownmix.TheAutomaticHeadroomGivesTheLevelBack;
var
  Si: TSignalInfo;
begin
  // samples far below full scale: the headroom has nothing to lower
  FHeadroom := True;
  WriteChanWav(FDir + 'six.wav', PLAY_FRAMES, 6, 16);
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'six.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  Si := FThread.GetSignalInfo;
  FRecorder.GoOn;
  AssertEquals('Six channels in the signal path', 6, Si.DownmixFrom);
  AssertEquals('The level is given back', 0.0, Si.DownmixDB, 0.001);
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  CheckPlayed(Self, FRecorder.Data, 16, NORM51, SKIP_FRAMES, PLAY_FRAMES, 3.0);
  AssertFalse('Not bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlaybackDownmix.FullScaleWithTheHeadroomDoesNotOverflow;
var
  D: TBytes;
  I, V, Peak: Integer;
begin
  // full scale in all six channels, of one sign: 2.4 times too much without
  // the headroom
  FHeadroom := True;
  WriteChanWav(FDir + 'six.wav', PLAY_FRAMES, 6, 16, True, 32767);
  Play(FDir + 'six.wav');
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  D := FRecorder.Data;
  Peak := 0;
  for I := 0 to PLAY_FRAMES * 2 - 1 do
  begin
    V := Int32At(D, I);
    AssertTrue(Format('Sample %d keeps its sign (%d)', [I, V]), V > 0);
    if V > Peak then Peak := V;
  end;
  AssertTrue('Close to full scale, not far below', Peak > 0.8 * High(Integer));
end;

procedure TTestPlaybackDownmix.AStereoTrackAfterItIsBitPerfectAgain;
const
  FRAMES = 20000;
begin
  WriteChanWav(FDir + 'six.wav', FRAMES, 6, 16);
  Play(FDir + 'six.wav');
  AssertTrue('The mix ends', WaitForEnd(20000));
  CheckNoError;
  AssertFalse('The mix is not bit-perfect', FThread.IsBitPerfect);

  Restart;
  WritePatternWav(FDir + 'two.wav', FRAMES);
  Play(FDir + 'two.wav');
  AssertTrue('The stereo track ends', WaitForEnd(20000));
  CheckNoError;
  CheckPattern('Stereo, untouched', FRecorder.Data, 32, 16, 0, 0, FRAMES);
  AssertTrue('Stereo is bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlaybackDownmix.A51FlacPlaysAsTheSameMix;
begin
  WriteChannelFlac(FDir + 'six.flac', PLAY_FRAMES, 6, @ChanSample, 44100, 16);
  Play(FDir + 'six.flac');
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  CheckPlayed(Self, FRecorder.Data, 16, 1.0, 0, PLAY_FRAMES, 0.5);
  AssertFalse('Not bit-perfect', FThread.IsBitPerfect);
end;

initialization
  RegisterTest(TTestDownmix);
  RegisterTest(TTestPlaybackDownmix);

end.
