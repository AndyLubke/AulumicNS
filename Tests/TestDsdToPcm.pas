unit TestDsdToPcm;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   AulumicNS - tests (audio chain: DSD to PCM)

  TDsdToPcmSource.SetOutputRate decimates straight to a lower rate (the DSD
  rate / 64 .. / 256) only when its DSD filter alone keeps the output free
  of aliasing: with the 30 kHz low-pass DSD512 -> 352.8 / 176.4, DSD256 ->
  176.4 and DSD128 -> 88.2, never without the low-pass, never a rate that is
  not a power-of-two part. A direct output has half the samples and the same
  level. CreateSourceFor then leaves out the resampler; without the
  low-pass the resampler stays (the old chain).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestDsdToPcm = class(TTestCase)
  private
    FDir: string;
    function Dsf(const AName: string; ADsdRate: Integer): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DirectRateFollowsTheAliasRule;
    procedure DirectDecimationHalvesTheSamplesAndKeepsTheLevel;
    procedure FactoryLeavesOutTheResamplerOnlyWhenDirect;
    procedure DsdNamesOfBothFamilies;
    procedure DsdBufferOnlyForDsdSentAsDsd;
  end;

implementation

uses
  Math, ALAudioTypes, ALReaders, ALSourceFactory, uAudioUtils, uPlaybackManager, TestHelpers;

const
  DSD64  = 2822400;
  DSD128 = 2 * DSD64;
  DSD256 = 4 * DSD64;
  DSD512 = 8 * DSD64;
  BYTES  = 64 * 4096;   // per channel: 0.09 s of DSD512

procedure TTestDsdToPcm.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestDsdToPcm.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestDsdToPcm.Dsf(const AName: string; ADsdRate: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + AName;
  if not FileExists(Result) then
    WriteTestDsf(Result, BYTES, dpSquare, 0, ADsdRate);
end;

procedure TTestDsdToPcm.DirectRateFollowsTheAliasRule;

  procedure Check(const AWhat, AFile: string; ALPF: Boolean; ARate: Cardinal;
    AExpected: Boolean; AExpectedRate: Cardinal);
  var
    S: TDsdToPcmSource;
  begin
    S := TDsdToPcmSource.Create(AFile, 0, ALPF);
    try
      AssertEquals(AWhat, AExpected, S.SetOutputRate(ARate));
      AssertEquals(AWhat + ': rate', AExpectedRate, S.GetSampleRate);
    finally
      S.Free;
    end;
  end;

var
  F512, F256, F128, F64: string;
begin
  F512 := Dsf('d512.dsf', DSD512);
  F256 := Dsf('d256.dsf', DSD256);
  F128 := Dsf('d128.dsf', DSD128);
  F64  := Dsf('d64.dsf', DSD64);
  Check('DSD512 -> 352.8', F512, True, 352800, True, 352800);
  Check('DSD512 -> 176.4', F512, True, 176400, True, 176400);
  Check('DSD512 -> 88.2 (would alias)', F512, True, 88200, False, 705600);
  Check('DSD512 -> 352.8 without the low-pass', F512, False, 352800, False, 705600);
  Check('DSD512 -> its own rate', F512, True, 705600, False, 705600);
  Check('DSD512 -> not a power-of-two part', F512, True, 235200, False, 705600);
  Check('DSD256 -> 176.4', F256, True, 176400, True, 176400);
  Check('DSD256 -> 88.2 (would alias)', F256, True, 88200, False, 352800);
  Check('DSD128 -> 88.2', F128, True, 88200, True, 88200);
  Check('DSD64 -> 44.1 (would alias)', F64, True, 44100, False, 88200);
end;

procedure TTestDsdToPcm.DirectDecimationHalvesTheSamplesAndKeepsTheLevel;

  { the frames and the RMS of the left channel after the fade-in (1/4 on) }
  procedure Decode(ADirect: Boolean; out AFrames: Integer; out ARms: Double);
  var
    S: TDsdToPcmSource;
    Buf: array of LongInt;
    N, I, Total: Integer;
    All: array of Double;
    Sum: Double;
  begin
    S := TDsdToPcmSource.Create(Dsf('d512.dsf', DSD512), 0, True);
    try
      if ADirect then AssertTrue(S.SetOutputRate(352800));
      SetLength(Buf, 2 * 4096);
      SetLength(All, 0);
      Total := 0;
      repeat
        N := S.ReadData(@Buf[0], Length(Buf) * 4) div 8;
        if Total + N > Length(All) then SetLength(All, (Total + N) * 2);
        for I := 0 to N - 1 do All[Total + I] := Buf[I * 2];
        Inc(Total, N);
      until N = 0;
      AFrames := Total;
      Sum := 0;
      for I := Total div 4 to Total - 1 do Sum := Sum + Sqr(All[I]);
      ARms := Sqrt(Sum / Max(1, Total - Total div 4));
    finally
      S.Free;
    end;
  end;

var
  N1, N2: Integer;
  R1, R2: Double;
begin
  Decode(False, N1, R1);
  Decode(True, N2, R2);
  AssertEquals('every DSD bit used once: 32 per sample, then 64', N1 div 2, N2);
  AssertTrue('a signal', R1 > 1E6);
  AssertEquals('the same level (dB)', 0.0, 20 * Log10(R2 / R1), 0.05);
end;

procedure TTestDsdToPcm.FactoryLeavesOutTheResamplerOnlyWhenDirect;

  function Make(ALPF: Boolean): TAudioSource;
  var
    C: TPlayThreadConfig;
    InRate, OutRate: Integer;
  begin
    C := Default(TPlayThreadConfig);
    C.UseDoP := False;
    C.ResamplePCM := True;
    C.DsdLowPassFilter := ALPF;
    C.ResampleQuality := VAL_DEF_RESAMPLE_QUAL;
    C.ResampleBandWidth := VAL_DEF_BANDWIDTH_FLOAT;
    C.ResampleAntiAlias := VAL_DEF_ANTI_ALIAS_FLOAT;
    SetLength(C.RateMaps, 1);
    C.RateMaps[0].InRate := 705600;
    C.RateMaps[0].OutRate := 352800;
    Result := CreateSourceFor(C, 0, nil, Dsf('d512.dsf', DSD512), InRate, OutRate);
    AssertEquals('the output rate', 352800, OutRate);
  end;

var
  S: TAudioSource;
begin
  S := Make(True);
  try
    AssertTrue('direct: no resampler', S.FindLayer(TResamplerSource) = nil);
    AssertTrue(S.FindLayer(TDsdToPcmSource) <> nil);
  finally
    S.Free;
  end;
  S := Make(False);
  try
    AssertTrue('without the low-pass: the resampler as before', S.FindLayer(TResamplerSource) <> nil);
  finally
    S.Free;
  end;
end;

{ uAudioUtils.DsdMultiple / DsdRateName (the banner, the signal path, the
  cover viewer): DSD64 is 64 x 44.1 kHz or 64 x 48 kHz; a DoP carrier rate
  x 16 is the DSD rate }
procedure TTestDsdToPcm.DsdNamesOfBothFamilies;
begin
  AssertEquals('DSD64 (44.1 kHz family)', 64, DsdMultiple(2822400));
  AssertEquals('DSD64 (48 kHz family; was DSD69)', 64, DsdMultiple(3072000));
  AssertEquals('DSD128', 128, DsdMultiple(5644800));
  AssertEquals('DSD128 (48)', 128, DsdMultiple(6144000));
  AssertEquals('DSD256', 256, DsdMultiple(11289600));
  AssertEquals('DSD512', 512, DsdMultiple(22579200));
  AssertEquals('DSD512 (48)', 512, DsdMultiple(24576000));
  AssertEquals('no rate', 0, DsdMultiple(0));
  AssertEquals('DoP carrier of DSD64', 'DSD64', DsdRateName(176400 * 16));
  AssertEquals('DoP carrier of DSD64 (48)', 'DSD64', DsdRateName(192000 * 16));
  AssertEquals('DoP carrier of DSD256', 'DSD256', DsdRateName(705600 * 16));
end;

{ uPlaybackManager.DsdBufferFor: the DSD buffer when DSD goes to the DAC as
  DSD (DoP / native), the PCM buffer when it is converted to PCM }
procedure TTestDsdToPcm.DsdBufferOnlyForDsdSentAsDsd;
var
  C: TManagerConfig;
begin
  C := Default(TManagerConfig);
  C.PCMBufferMs := 250;
  C.DSDBufferMs := 500;
  C.UseDoP := True;
  AssertEquals('DoP / native DSD: the DSD buffer', 500, DsdBufferFor(C));
  C.UseDoP := False;
  AssertEquals('DSD converted to PCM: the PCM buffer', 250, DsdBufferFor(C));
end;

initialization
  RegisterTest(TTestDsdToPcm);

end.
