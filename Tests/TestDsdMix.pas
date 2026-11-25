unit TestDsdMix;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestDsdMix
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  DSD files with more than two channels are converted to PCM and mixed to
  stereo (TDsdMixSource), whatever the setting for DSD says. The mix is
  compared with what the stereo converter makes of the same DSD bytes: the
  front channels as they are, the centre in both, the LFE left out, the
  surrounds on their side; DSF by its channel type and DFF by the channel
  names in the file, also in another order; seeking; what the source factory
  builds with DSD sent as DSD switched on; and the play thread.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, TestPlayback;

type
  TTestDsdMix = class(TTestCase)
  private
    FDir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheWeightsFollowWhatAChannelIs;
    procedure ADsfNamesItsChannelsByItsType;
    procedure ADffNamesItsChannels;
    procedure TheFrontsComeOutAsFromTheStereoConverter;
    procedure TheCentreGoesToBothSides;
    procedure TheLfeChannelIsLeftOut;
    procedure TheSurroundsGoToTheirSide;
    procedure ADffGivesTheSameAsTheDsf;
    procedure ADffInAnotherOrderIsMixedByItsNames;
    procedure OddReadSizesGiveTheSameSamples;
    procedure SeekStartsAgainWithAFadeIn;
    procedure TheFactoryConvertsAlsoWithDsdSentAsDsd;
    procedure OnlyUpToTwoChannelsGoOutAsDsd;
  end;

  TTestPlaybackDsdMix = class(TPlaybackTestBase)
  published
    procedure PlaysAsPcmAlthoughDsdIsSentAsDsd;
    procedure AStereoDsdFileStillGoesOutAsDsd;
  end;

implementation

uses
  Math, ALAudioTypes, ALReaders, ALReaderDSF, ALSourceFactory, uAudioUtils, TestHelpers;

const
  SIDE   = 0.70710678118654752;
  NORM51 = 1.0 + 2.0 * SIDE;
  BYTES  = 60000;                  // per channel: 15000 PCM frames at DSD64
  DSD64  = 2822400;

  // what a channel of a test file holds
  K_IDLE = 0;                      // the DSD idle pattern: silence
  K_A    = 1;                      // a square wave of about 1 kHz
  K_B    = 2;                      // one of about 1.5 kHz

type
  TKinds = array of Integer;

// The DSD byte at AIndex of a channel, the bits in the order of time (MSB
// first). $EE / $11 is about half scale.
function KindByte(AKind, AIndex: Integer): Byte;
begin
  case AKind of
    K_A: if ((AIndex div 176) and 1) = 0 then Result := $EE else Result := $11;
    K_B: if ((AIndex div 120) and 1) = 0 then Result := $EE else Result := $11;
  else
    Result := $69;
  end;
end;

function Reversed(AByte: Byte): Byte;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 7 do
    if (AByte and (1 shl I)) <> 0 then
      Result := Result or Byte(1 shl (7 - I));
end;

function Kinds(const A: array of Integer): TKinds;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

// A DSF file: one channel per entry of AKinds, AChannelType as the format
// names the layouts
procedure WriteKindDsf(const APath: string; AChannelType: Integer; const AKinds: TKinds);
const
  BLOCK = 4096;
var
  FS: TFileStream;
  Blocks, B, DataSize: Int64;
  Buf: TBytes;
  I, Ch, N: Integer;

  procedure Tag(const S: AnsiString);
  begin
    FS.WriteBuffer(S[1], 4);
  end;

  procedure I32(V: Integer);
  begin
    FS.WriteBuffer(V, 4);
  end;

  procedure I64(V: Int64);
  begin
    FS.WriteBuffer(V, 8);
  end;

begin
  N := Length(AKinds);
  Blocks := (BYTES + BLOCK - 1) div BLOCK;
  DataSize := Blocks * BLOCK * N;
  Buf := nil;
  SetLength(Buf, BLOCK);
  ForceDirectories(ExtractFileDir(APath));
  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('DSD '); I64(28); I64(28 + 52 + 12 + DataSize); I64(0);
    Tag('fmt '); I64(52); I32(1); I32(0); I32(AChannelType); I32(N); I32(DSD64); I32(1);
    I64(Int64(BYTES) * 8); I32(BLOCK); I32(0);
    Tag('data'); I64(12 + DataSize);
    for B := 0 to Blocks - 1 do
      for Ch := 0 to N - 1 do
      begin
        for I := 0 to BLOCK - 1 do
          if B * BLOCK + I < BYTES then
            Buf[I] := Reversed(KindByte(AKinds[Ch], B * BLOCK + I))   // DSF: LSB first
          else
            Buf[I] := $69;
        FS.WriteBuffer(Buf[0], BLOCK);
      end;
  finally
    FS.Free;
  end;
end;

// A DFF file: AIds names every channel
procedure WriteKindDff(const APath: string; const AIds: array of AnsiString; const AKinds: TKinds);
const
  CMPR_NAME: AnsiString = 'not compressed';
var
  FS: TFileStream;
  Data: TBytes;
  I, C, N: Integer;
  DataSize, PropSize, ChnlSize: Int64;

  procedure Tag(const S: AnsiString);
  begin
    FS.WriteBuffer(S[1], 4);
  end;

  procedure U32(AValue: Cardinal);
  var
    Q: array[0..3] of Byte;
  begin
    Q[0] := Byte(AValue shr 24);
    Q[1] := Byte(AValue shr 16);
    Q[2] := Byte(AValue shr 8);
    Q[3] := Byte(AValue);
    FS.WriteBuffer(Q, 4);
  end;

  procedure U64(AValue: Int64);
  begin
    U32(Cardinal(AValue shr 32));
    U32(Cardinal(AValue and $FFFFFFFF));
  end;

begin
  N := Length(AKinds);
  DataSize := Int64(BYTES) * N;
  Data := nil;
  SetLength(Data, DataSize);
  for I := 0 to BYTES - 1 do
    for C := 0 to N - 1 do
      Data[I * N + C] := KindByte(AKinds[C], I);
  ChnlSize := 2 + 4 * N;
  PropSize := 4 + (12 + 4) + (12 + ChnlSize) + (12 + 20);
  ForceDirectories(ExtractFileDir(APath));
  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('FRM8'); U64(4 + (12 + 4) + (12 + PropSize) + (12 + DataSize)); Tag('DSD ');
    Tag('FVER'); U64(4); U32($01050000);
    Tag('PROP'); U64(PropSize); Tag('SND ');
    Tag('FS  '); U64(4); U32(DSD64);
    Tag('CHNL'); U64(ChnlSize); FS.WriteByte(0); FS.WriteByte(N);
    for C := 0 to N - 1 do Tag(AIds[C]);
    Tag('CMPR'); U64(19); Tag('DSD ');
    FS.WriteByte(Length(CMPR_NAME));
    FS.WriteBuffer(CMPR_NAME[1], Length(CMPR_NAME));
    FS.WriteByte(0);
    Tag('DSD '); U64(DataSize);
    FS.WriteBuffer(Data[0], DataSize);
  finally
    FS.Free;
  end;
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

// What the stereo converter makes of a file with the channels AL and AR
function StereoOf(const ADir: string; AL, AR: Integer): TBytes;
var
  S: TAudioSource;
begin
  WriteKindDsf(ADir + 'stereo.dsf', 2, Kinds([AL, AR]));
  S := TDsdToPcmSource.Create(ADir + 'stereo.dsf', 0, True);
  try
    Result := ReadAll(S, 64 * 1024);
  finally
    S.Free;
  end;
end;

function MixOf(const AFile: string; AChunk: Integer = 64 * 1024): TBytes;
var
  S: TAudioSource;
begin
  S := TDsdMixSource.Create(AFile, True);
  try
    Result := ReadAll(S, AChunk);
  finally
    S.Free;
  end;
end;

// What the stereo converter makes of one channel of AKind (rounded to 32 bit)
function ConvOf(const ADir: string; AKind: Integer): TBytes;
begin
  Result := StereoOf(ADir, AKind, AKind);
end;

// The mix of AFile against the sum worked out here: every channel as the
// stereo converter converts it (also a silent one: it has the same start-up
// as any other), times its weight, divided by ANorm. The references are
// rounded, so the sum may be off by their weights' worth of half steps.
procedure CheckMix(ATest: TTestCase; const ADir, AFile: string; const AKinds: TKinds;
  const AL, AR: array of Double; ANorm: Double);
var
  Conv: array[K_IDLE..K_B] of TBytes;
  Mix: TBytes;
  K, I, C, Frames: Integer;
  SumL, SumR: Double;
  Loud: Boolean;
begin
  for K := K_IDLE to K_B do
    Conv[K] := ConvOf(ADir, K);
  Mix := MixOf(AFile);
  ATest.AssertEquals('As many frames as the stereo converter gives', Length(Conv[K_IDLE]), Length(Mix));
  Frames := Length(Mix) div 8;
  ATest.AssertTrue('Frames at all', Frames > 10000);
  Loud := False;
  for I := 0 to Frames - 1 do
  begin
    SumL := 0.0;
    SumR := 0.0;
    for C := 0 to High(AKinds) do
    begin
      SumL := SumL + AL[C] * Int32At(Conv[AKinds[C]], I * 2);
      SumR := SumR + AR[C] * Int32At(Conv[AKinds[C]], I * 2);
    end;
    SumL := SumL / ANorm;
    SumR := SumR / ANorm;
    if Abs(SumL) + Abs(SumR) > 50000000 then Loud := True;
    if (Abs(Int32At(Mix, I * 2) - SumL) > 3.0) or (Abs(Int32At(Mix, I * 2 + 1) - SumR) > 3.0) then
      ATest.Fail(Format('Frame %d: %d / %d, expected %.1f / %.1f', [I, Int32At(Mix, I * 2),
        Int32At(Mix, I * 2 + 1), SumL, SumR]));
  end;
  ATest.AssertTrue('The comparison is of sound, not of silence', Loud);
end;

const
  // 5.1 as a DSF file stores it: left, right, centre, LFE, the surrounds
  L51: array[0..5] of Double = (1.0, 0.0, SIDE, 0.0, SIDE, 0.0);
  R51: array[0..5] of Double = (0.0, 1.0, SIDE, 0.0, 0.0, SIDE);
  // five channels: no LFE
  L50: array[0..4] of Double = (1.0, 0.0, SIDE, SIDE, 0.0);
  R50: array[0..4] of Double = (0.0, 1.0, SIDE, 0.0, SIDE);
{ TTestDsdMix }

procedure TTestDsdMix.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestDsdMix.TearDown;
begin
  RemoveTestDir(FDir);
end;

function Roles(const A: array of TChannelRole): TChannelRoles;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

procedure TTestDsdMix.TheWeightsFollowWhatAChannelIs;
var
  L, R: TDownmixWeights;
  N: Double;
begin
  AssertTrue(DownmixWeights(Roles([chLeft, chRight, chCentre, chLfe, chSurroundLeft, chSurroundRight]), L, R, N));
  AssertEquals('5.1', NORM51, N, 1e-12);
  AssertEquals(1.0, L[0], 0);
  AssertEquals(0.0, R[0], 0);
  AssertEquals(SIDE, L[2], 1e-12);
  AssertEquals(SIDE, R[2], 1e-12);
  AssertEquals('LFE out', 0.0, L[3] + R[3], 0);
  AssertEquals(SIDE, L[4], 1e-12);
  AssertEquals(SIDE, R[5], 1e-12);

  AssertTrue(DownmixWeights(Roles([chLeft, chRight, chSurroundLeft, chSurroundRight, chCentre, chLfe]), L, R, N));
  AssertEquals('Another order, the same sum', NORM51, N, 1e-12);
  AssertEquals('The third channel is the left surround here', SIDE, L[2], 1e-12);
  AssertEquals(0.0, R[2], 0);
  AssertEquals('The fifth is the centre', SIDE, R[4], 1e-12);
  AssertEquals('The sixth the LFE', 0.0, L[5] + R[5], 0);

  AssertTrue(DownmixWeights(Roles([chLeft, chRight, chCentre, chLfe]), L, R, N));
  AssertEquals('Four channels with LFE', 1.0 + SIDE, N, 1e-12);

  AssertFalse('Without a left and a right channel: not usable',
    DownmixWeights(Roles([chCentre, chLfe, chNone]), L, R, N));
  AssertFalse('No names at all', DownmixWeights(nil, L, R, N));
end;

procedure TTestDsdMix.ADsfNamesItsChannelsByItsType;
var
  Rd: TDsfReader;
  Ro: TChannelRoles;
begin
  WriteKindDsf(FDir + 'a.dsf', 7, Kinds([K_A, K_A, K_A, K_A, K_A, K_A]));
  Rd := TDsfReader.Create(FDir + 'a.dsf');
  try
    AssertEquals(6, Integer(Rd.FileChannels));
    Ro := Rd.Roles;
    AssertEquals(6, Length(Ro));
    AssertTrue('5.1: the fourth is the LFE', Ro[3] = chLfe);
    AssertTrue('the fifth the left surround', Ro[4] = chSurroundLeft);
  finally
    Rd.Free;
  end;

  // four channels are quadraphonic (type 4) or left, right, centre, LFE (type 5)
  WriteKindDsf(FDir + 'q.dsf', 4, Kinds([K_A, K_A, K_A, K_A]));
  Rd := TDsfReader.Create(FDir + 'q.dsf');
  try
    Ro := Rd.Roles;
    AssertTrue('Quadraphonic: the third is a surround', Ro[2] = chSurroundLeft);
  finally
    Rd.Free;
  end;
  WriteKindDsf(FDir + 'f.dsf', 5, Kinds([K_A, K_A, K_A, K_A]));
  Rd := TDsfReader.Create(FDir + 'f.dsf');
  try
    Ro := Rd.Roles;
    AssertTrue('Type 5: the third is the centre', Ro[2] = chCentre);
    AssertTrue('and the fourth the LFE', Ro[3] = chLfe);
  finally
    Rd.Free;
  end;

  // a type that does not fit the channel count: no names, the count decides
  WriteKindDsf(FDir + 'x.dsf', 7, Kinds([K_A, K_A, K_A]));
  Rd := TDsfReader.Create(FDir + 'x.dsf');
  try
    AssertEquals(0, Length(Rd.Roles));
  finally
    Rd.Free;
  end;
end;

procedure TTestDsdMix.ADffNamesItsChannels;
var
  Rd: TDsfReader;
  Ro: TChannelRoles;
begin
  WriteKindDff(FDir + 'a.dff', ['MLFT', 'MRGT', 'LS  ', 'RS  ', 'C   ', 'LFE '],
    Kinds([K_A, K_A, K_A, K_A, K_A, K_A]));
  Rd := TDsfReader.Create(FDir + 'a.dff');
  try
    AssertEquals(6, Integer(Rd.FileChannels));
    Ro := Rd.Roles;
    AssertEquals(6, Length(Ro));
    AssertTrue(Ro[0] = chLeft);
    AssertTrue(Ro[1] = chRight);
    AssertTrue(Ro[2] = chSurroundLeft);
    AssertTrue(Ro[3] = chSurroundRight);
    AssertTrue(Ro[4] = chCentre);
    AssertTrue(Ro[5] = chLfe);
  finally
    Rd.Free;
  end;
end;

procedure TTestDsdMix.TheFrontsComeOutAsFromTheStereoConverter;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_IDLE, K_IDLE, K_IDLE, K_IDLE]));
  CheckMix(Self, FDir, FDir + 'six.dsf', Kinds([K_A, K_B, K_IDLE, K_IDLE, K_IDLE, K_IDLE]), L51, R51, NORM51);
end;

procedure TTestDsdMix.TheCentreGoesToBothSides;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_IDLE, K_IDLE, K_A, K_IDLE, K_IDLE, K_IDLE]));
  CheckMix(Self, FDir, FDir + 'six.dsf', Kinds([K_IDLE, K_IDLE, K_A, K_IDLE, K_IDLE, K_IDLE]), L51, R51, NORM51);
end;

procedure TTestDsdMix.TheLfeChannelIsLeftOut;
var
  A, B: TBytes;
begin
  // the same file with a loud and with a silent LFE channel: not one sample
  // may differ
  WriteKindDsf(FDir + 'loud.dsf', 7, Kinds([K_A, K_B, K_B, K_A, K_B, K_A]));
  WriteKindDsf(FDir + 'silent.dsf', 7, Kinds([K_A, K_B, K_B, K_IDLE, K_B, K_A]));
  A := MixOf(FDir + 'loud.dsf');
  B := MixOf(FDir + 'silent.dsf');
  AssertEquals(Length(A), Length(B));
  AssertTrue('Frames at all', Length(A) > 80000);
  AssertTrue('The LFE channel changes nothing', CompareMem(@A[0], @B[0], Length(A)));
end;
procedure TTestDsdMix.TheSurroundsGoToTheirSide;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_IDLE, K_IDLE, K_IDLE, K_IDLE, K_A, K_B]));
  CheckMix(Self, FDir, FDir + 'six.dsf', Kinds([K_IDLE, K_IDLE, K_IDLE, K_IDLE, K_A, K_B]), L51, R51, NORM51);

  // five channels (type 6) have no LFE: the surrounds are the fourth and fifth
  WriteKindDsf(FDir + 'five.dsf', 6, Kinds([K_IDLE, K_IDLE, K_IDLE, K_A, K_B]));
  CheckMix(Self, FDir, FDir + 'five.dsf', Kinds([K_IDLE, K_IDLE, K_IDLE, K_A, K_B]), L50, R50, NORM51);

  // and everything at once
  WriteKindDsf(FDir + 'all.dsf', 7, Kinds([K_A, K_B, K_B, K_A, K_B, K_A]));
  CheckMix(Self, FDir, FDir + 'all.dsf', Kinds([K_A, K_B, K_B, K_A, K_B, K_A]), L51, R51, NORM51);
end;
procedure TTestDsdMix.ADffGivesTheSameAsTheDsf;
var
  A, B: TBytes;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  WriteKindDff(FDir + 'six.dff', ['MLFT', 'MRGT', 'C   ', 'LFE ', 'LS  ', 'RS  '],
    Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  A := MixOf(FDir + 'six.dsf');
  B := MixOf(FDir + 'six.dff');
  AssertEquals('The same length', Length(A), Length(B));
  AssertTrue('Frames at all', Length(A) > 80000);
  AssertTrue('The same samples', CompareMem(@A[0], @B[0], Length(A)));
end;

procedure TTestDsdMix.ADffInAnotherOrderIsMixedByItsNames;
var
  A, B: TBytes;
  I: Integer;
begin
  // the same music, the channels stored in another order
  WriteKindDff(FDir + 'a.dff', ['MLFT', 'MRGT', 'C   ', 'LFE ', 'LS  ', 'RS  '],
    Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  WriteKindDff(FDir + 'b.dff', ['LS  ', 'RS  ', 'LFE ', 'C   ', 'MRGT', 'MLFT'],
    Kinds([K_B, K_A, K_B, K_A, K_B, K_A]));
  A := MixOf(FDir + 'a.dff');
  B := MixOf(FDir + 'b.dff');
  AssertEquals(Length(A), Length(B));
  // the sums are made in another order: the last bit may differ
  for I := 0 to Length(A) div 4 - 1 do
    if Abs(Int32At(A, I) - Int32At(B, I)) > 2 then
      Fail(Format('Sample %d: %d and %d', [I, Int32At(A, I), Int32At(B, I)]));
end;

procedure TTestDsdMix.OddReadSizesGiveTheSameSamples;
var
  A, B: TBytes;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  A := MixOf(FDir + 'six.dsf', 64 * 1024);
  B := MixOf(FDir + 'six.dsf', 8 * 37);
  AssertEquals('The same length', Length(A), Length(B));
  AssertTrue('The same samples', CompareMem(@A[0], @B[0], Length(A)));
end;

procedure TTestDsdMix.SeekStartsAgainWithAFadeIn;
var
  S: TAudioSource;
  D: TBytes;
  Frames: Integer;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  S := TDsdMixSource.Create(FDir + 'six.dsf', True);
  try
    S.Seek(0.5);
    D := ReadAll(S, 16 * 1024);
    Frames := Length(D) div 8;
    AssertTrue(Format('About half of the file (%d frames)', [Frames]), Abs(Frames - 7500) < 1100);
    AssertTrue('Starts at silence', Abs(Int32At(D, 0)) < 1000000);
    AssertTrue('And is at its level later', Abs(Int32At(D, Frames)) + Abs(Int32At(D, Frames + 1)) > 10000000);
  finally
    S.Free;
  end;
end;

procedure TTestDsdMix.TheFactoryConvertsAlsoWithDsdSentAsDsd;
var
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate, Bits: Integer;
  Makeup: Double;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  WriteKindDsf(FDir + 'two.dsf', 2, Kinds([K_A, K_B]));
  C := Default(TPlayThreadConfig);
  C.UseDoP := True;
  C.DsdLowPassFilter := True;

  S := CreateSourceFor(C, 6, nil, FDir + 'six.dsf', InRate, OutRate);
  try
    AssertFalse('Not sent as DSD', S.IsDoP);
    AssertEquals('Stereo', 2, Integer(S.GetChannels));
    AssertEquals('PCM at the DSD rate / 32', 88200, OutRate);
    AssertEquals('Mixed from six channels', 6, DownmixOf(S, Bits, Makeup));
    AssertEquals('Of a one-bit file', 1, Bits);
    AssertEquals(NORM51, Makeup, 1e-12);
  finally
    S.Free;
  end;

  S := CreateSourceFor(C, 6, nil, FDir + 'two.dsf', InRate, OutRate);
  try
    AssertTrue('Two channels are sent as DSD', S.IsDoP);
    AssertEquals('No mix', 0, DownmixOf(S, Bits, Makeup));
  finally
    S.Free;
  end;

  C.UseDoP := False;
  S := CreateSourceFor(C, 6, nil, FDir + 'two.dsf', InRate, OutRate);
  try
    AssertFalse('Converted when that is the setting', S.IsDoP);
    AssertEquals('The stereo converter: no mix', 0, DownmixOf(S, Bits, Makeup));
  finally
    S.Free;
  end;
end;

procedure TTestDsdMix.OnlyUpToTwoChannelsGoOutAsDsd;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_A, K_B, K_B, K_A]));
  WriteKindDsf(FDir + 'two.dsf', 2, Kinds([K_A, K_B]));
  WriteKindDsf(FDir + 'one.dsf', 1, Kinds([K_A]));
  WriteTestWav(FDir + 'a.wav');
  AssertEquals(6, DsdFileChannels(FDir + 'six.dsf'));
  AssertEquals(2, DsdFileChannels(FDir + 'two.dsf'));
  AssertEquals(0, DsdFileChannels(FDir + 'missing.dsf'));
  AssertFalse('Six channels: never as DSD', DsdGoesOutAsDsd(True, FDir + 'six.dsf'));
  AssertTrue('Two channels: as DSD', DsdGoesOutAsDsd(True, FDir + 'two.dsf'));
  AssertTrue('One channel: as DSD', DsdGoesOutAsDsd(True, FDir + 'one.dsf'));
  AssertFalse('Not when that is switched off', DsdGoesOutAsDsd(False, FDir + 'two.dsf'));
  AssertFalse('A PCM file never', DsdGoesOutAsDsd(True, FDir + 'a.wav'));
end;

{ TTestPlaybackDsdMix }

procedure TTestPlaybackDsdMix.PlaysAsPcmAlthoughDsdIsSentAsDsd;
var
  Si: TSignalInfo;
  D: TBytes;
  I, Peak: Integer;
begin
  WriteKindDsf(FDir + 'six.dsf', 7, Kinds([K_A, K_B, K_A, K_IDLE, K_B, K_A]));
  FRecorder.HoldAfterBuffers(1);
  Play(FDir + 'six.dsf', True);          // DSD sent as DSD is switched on
  AssertTrue('Held after a buffer', FRecorder.WaitUntilHeld(5000));
  Si := FThread.GetSignalInfo;
  FRecorder.GoOn;
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;

  AssertTrue('A DSD file', Si.IsDsd);
  AssertFalse('Not as DoP', Si.DoP);
  AssertTrue('Converted to PCM', Si.DsdToPcm);
  AssertEquals('Mixed from six channels', 6, Si.DownmixFrom);
  AssertEquals('PCM at the DSD rate / 32', 88200, Integer(FRecorder.Opens(0).Rate));
  AssertFalse('Opened as PCM, not as DoP', FRecorder.Opens(0).IsDoP);
  AssertFalse('Not bit-perfect', FThread.IsBitPerfect);

  D := FRecorder.Data;
  Peak := 0;
  for I := 0 to Length(D) div 4 - 1 do
    if Abs(Int32At(D, I)) > Peak then Peak := Abs(Int32At(D, I));
  AssertTrue('Music came out', Peak > 100000000);
end;

procedure TTestPlaybackDsdMix.AStereoDsdFileStillGoesOutAsDsd;
begin
  WriteKindDsf(FDir + 'two.dsf', 2, Kinds([K_A, K_B]));
  Play(FDir + 'two.dsf', True);
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  AssertTrue('Opened as DoP', FRecorder.Opens(0).IsDoP);
  AssertEquals('At the DoP rate', 176400, Integer(FRecorder.Opens(0).Rate));
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
end;

initialization
  RegisterTest(TTestDsdMix);
  RegisterTest(TTestPlaybackDsdMix);

end.
