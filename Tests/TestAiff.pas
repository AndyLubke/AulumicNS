unit TestAiff;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestAiff
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AIFF and AIFF-C files, built here from their bytes so each one holds exactly
  the case it tests.

  The reader (TAiffReader): the sample rate from its 80-bit number, big-endian
  samples of 16, 24 and 32 bit, little-endian AIFF-C, floating point, 8 bit,
  the sound before its description, an odd chunk in between, compressed and
  foreign files refused, read sizes and seeking.
  The engine: the source factory, mono, more than two channels, and a track
  played to the end bit-perfect.
  The tag library: a file without a tag gets one, a tag is replaced, and a
  save leaves the sound and every other chunk byte for byte; a damaged file is
  not rewritten. What the library and the ReplayGain scan read from a file.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, TestPlayback;

type
  TTestAiff = class(TTestCase)
  private
    FDir: string;
    function Retitle(const AFile: string): string;
    function Field(const AFile, AID: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheRateIsReadFromItsExtendedNumber;
    procedure BigEndianSamplesComeOutAsThePattern;
    procedure LittleEndianAifcIsReadAsItIs;
    procedure FloatingPointBecomes32Bit;
    procedure EightBitIsWidenedTo16;
    procedure TheSoundMayComeBeforeItsDescription;
    procedure CompressedAndForeignFilesAreRefused;
    procedure OddReadSizesGiveTheSameSamples;
    procedure SeekContinuesAtTheTarget;
    procedure TheNamesOfAiffFiles;
    procedure TheFactoryBuildsItsSource;
    procedure AFileWithoutATagGetsOne;
    procedure ASaveKeepsTheSoundAndEveryOtherChunk;
    procedure ATagIsReplacedNotAdded;
    procedure ADamagedFileIsNotRewritten;
    procedure TheLibraryReadsItsProperties;
  end;

  TTestPlaybackAiff = class(TPlaybackTestBase)
  published
    procedure Plays16BitBitPerfect;
    procedure Plays24BitBitPerfect;
  end;

implementation

uses
  Math, ALAudioTypes, ALReaders, ALReaderAIFF, ALSourceFactory, ALMetadata, uAudioUtils, uAppStrings,
  AudioTag, baseTag, tag_id3v2, TestHelpers;

{ ---- bytes ---- }

function BE16(V: Integer): AnsiString;
begin
  Result := AnsiChar((V shr 8) and $FF) + AnsiChar(V and $FF);
end;

function BE32(V: Cardinal): AnsiString;
begin
  Result := AnsiChar(V shr 24) + AnsiChar((V shr 16) and $FF) + AnsiChar((V shr 8) and $FF) + AnsiChar(V and $FF);
end;

// A whole number as the 80-bit extended number of a COMM chunk
function Ext80(ARate: Cardinal): AnsiString;
var
  Exponent, I: Integer;
  Mantissa: QWord;
begin
  if ARate = 0 then
    Exit(StringOfChar(#0, 10));
  Exponent := 0;
  while (QWord(1) shl (Exponent + 1)) <= ARate do
    Inc(Exponent);
  Mantissa := QWord(ARate) shl (63 - Exponent);
  Result := BE16(16383 + Exponent);
  for I := 7 downto 0 do
    Result := Result + AnsiChar((Mantissa shr (I * 8)) and $FF);
end;

function Chunk(const AID, AData: AnsiString): AnsiString;
begin
  Result := AID + BE32(Length(AData)) + AData;
  if Odd(Length(AData)) then
    Result := Result + #0;
end;

function Comm(AChannels, AFrames, ABits: Integer; ARate: Cardinal; const ACompression: AnsiString = ''): AnsiString;
var
  S: AnsiString;
begin
  S := BE16(AChannels) + BE32(AFrames) + BE16(ABits) + Ext80(ARate);
  if ACompression <> '' then
    S := S + ACompression + #0#0;          // an empty name of the compression
  Result := Chunk('COMM', S);
end;

function Sound(const AData: AnsiString): AnsiString;
begin
  Result := Chunk('SSND', BE32(0) + BE32(0) + AData);
end;

function Form(const AKind, AChunks: AnsiString): AnsiString;
begin
  Result := 'FORM' + BE32(4 + Length(AChunks)) + AKind + AChunks;
end;

procedure SaveBytes(const AFile: string; const AData: AnsiString);
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, Length(AData));
  Move(AData[1], B[0], Length(AData));
  WriteFileBytes(AFile, B);
end;

function FileBytes(const AFile: string): AnsiString;
var
  B: TBytes;
begin
  B := ReadFileBytes(AFile);
  SetString(Result, PAnsiChar(@B[0]), Length(B));
end;

// The stereo pattern of the playback tests as AIFF sound data: big-endian,
// or little-endian for 'sowt'
function PatternData(AFrames, ABits: Integer; ALittle: Boolean = False; AFirst: Integer = 0): AnsiString;
var
  F, Ch, V, K, N: Integer;
begin
  Result := '';
  N := ABits div 8;
  SetLength(Result, AFrames * 2 * N);
  K := 1;
  for F := 0 to AFrames - 1 do
    for Ch := 0 to 1 do
    begin
      V := PatternSample(AFirst + F, Ch, ABits);
      if ABits = 32 then
        V := PatternSample(AFirst + F, Ch, 24) * 256 + (F and $FF);
      case N of
        2: if ALittle then begin Result[K] := AnsiChar(V and $FF); Result[K + 1] := AnsiChar((V shr 8) and $FF); end
           else begin Result[K] := AnsiChar((V shr 8) and $FF); Result[K + 1] := AnsiChar(V and $FF); end;
        3: begin
             Result[K] := AnsiChar((V shr 16) and $FF);
             Result[K + 1] := AnsiChar((V shr 8) and $FF);
             Result[K + 2] := AnsiChar(V and $FF);
           end;
      else
        begin
          Result[K] := AnsiChar((V shr 24) and $FF);
          Result[K + 1] := AnsiChar((V shr 16) and $FF);
          Result[K + 2] := AnsiChar((V shr 8) and $FF);
          Result[K + 3] := AnsiChar(V and $FF);
        end;
      end;
      Inc(K, N);
    end;
end;

procedure WritePatternAiff(const AFile: string; AFrames, ABits: Integer; ARate: Cardinal = 44100);
begin
  SaveBytes(AFile, Form('AIFF', Comm(2, AFrames, ABits, ARate) + Sound(PatternData(AFrames, ABits))));
end;

function ReadAll(AReader: TAiffReader; AChunk: Integer): TBytes;
var
  Got, Total: Integer;
begin
  Result := nil;
  Total := 0;
  repeat
    SetLength(Result, Total + AChunk);
    Got := AReader.ReadData(@Result[Total], AChunk);
    if Got > 0 then Inc(Total, Got);
  until Got <= 0;
  SetLength(Result, Total);
end;

// The sample at AIndex of little-endian data of ABits
function SampleOf(const AData: TBytes; AIndex, ABits: Integer): Integer;
var
  O: Integer;
begin
  O := AIndex * (ABits div 8);
  case ABits of
    16: Result := SmallInt(AData[O] or (AData[O + 1] shl 8));
    24: begin
          Result := AData[O] or (AData[O + 1] shl 8) or (AData[O + 2] shl 16);
          if (Result and $800000) <> 0 then Result := Result or Integer($FF000000);
        end;
  else
    Result := PInteger(@AData[O])^;
  end;
end;

{ TTestAiff }

procedure TTestAiff.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestAiff.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestAiff.Retitle(const AFile: string): string;
var
  R: TTagReader;
begin
  R := GetFileTagsObject(AFile);
  try
    if R.LoadFailed then
      Exit('not loaded');
    AssertTrue('An ID3 tag', R.Tags is TID3Tags);
    R.Tags.SetFrameValue('TIT2', 'New title', TID3Frame);
    if R.UpdateFile then
      Result := ''
    else
      Result := 'not saved: ' + R.LastUpdateError;
  finally
    R.Free;
  end;
end;

function TTestAiff.Field(const AFile, AID: string): string;
var
  R: TTagReader;
begin
  R := GetFileTagsObject(AFile);
  try
    Result := R.Tags.GetFrameValue(AID);
  finally
    R.Free;
  end;
end;

procedure TTestAiff.TheRateIsReadFromItsExtendedNumber;
const
  RATES: array[0..11] of Cardinal = (8000, 22050, 44100, 48000, 88200, 96000, 176400, 192000,
    352800, 384000, 705600, 768000);
var
  I, K: Integer;
  S: AnsiString;
  B: array[0..9] of Byte;
begin
  for I := 0 to High(RATES) do
  begin
    S := Ext80(RATES[I]);
    for K := 0 to 9 do B[K] := Ord(S[K + 1]);
    AssertEquals(Format('%d Hz', [RATES[I]]), Integer(RATES[I]), Integer(AiffRateFromExtended(B)));
  end;
  // 44100 as most files store it
  B[0] := $40; B[1] := $0E; B[2] := $AC; B[3] := $44;
  for K := 4 to 9 do B[K] := 0;
  AssertEquals('The usual bytes of 44100', 44100, Integer(AiffRateFromExtended(B)));

  for K := 0 to 9 do B[K] := 0;
  AssertEquals('Zero', 0, Integer(AiffRateFromExtended(B)));
  B[0] := $C0; B[1] := $0E; B[2] := $AC; B[3] := $44;
  AssertEquals('A negative number', 0, Integer(AiffRateFromExtended(B)));
  B[0] := $7F; B[1] := $FF;
  AssertEquals('Not a number', 0, Integer(AiffRateFromExtended(B)));
end;

procedure TTestAiff.BigEndianSamplesComeOutAsThePattern;
const
  FRAMES = 5000;
var
  R: TAiffReader;
  D: TBytes;
  Bits, F: Integer;
begin
  for Bits in [16, 24] do
  begin
    WritePatternAiff(FDir + 'a.aiff', FRAMES, Bits, 96000);
    R := TAiffReader.Create(FDir + 'a.aiff');
    try
      AssertEquals(2, Integer(R.Channels));
      AssertEquals(Bits, Integer(R.BitsPerSample));
      AssertEquals(96000, Integer(R.SampleRate));
      AssertEquals('The size of the sound', Int64(FRAMES) * 2 * (Bits div 8), R.DataSize);
      D := ReadAll(R, 64 * 1024);
      AssertEquals('All of it', R.DataSize, Int64(Length(D)));
      for F := 0 to FRAMES - 1 do
        if (SampleOf(D, F * 2, Bits) <> PatternSample(F, 0, Bits)) or
           (SampleOf(D, F * 2 + 1, Bits) <> PatternSample(F, 1, Bits)) then
          Fail(Format('%d bit, frame %d: %d / %d', [Bits, F, SampleOf(D, F * 2, Bits), SampleOf(D, F * 2 + 1, Bits)]));
      AssertEquals('At the end', 1.0, R.GetProgress, 0.0001);
    finally
      R.Free;
    end;
  end;

  // 32 bit: every byte of a sample is different
  SaveBytes(FDir + 'b.aiff', Form('AIFF', Comm(2, 2, 32, 48000) +
    Sound(#$12#$34#$56#$78 + #$FE#$DC#$BA#$98 + #$80#$00#$00#$00 + #$7F#$FF#$FF#$FF)));
  R := TAiffReader.Create(FDir + 'b.aiff');
  try
    D := ReadAll(R, 4096);
    AssertEquals(16, Length(D));
    AssertEquals($12345678, SampleOf(D, 0, 32));
    AssertEquals(Integer($FEDCBA98), SampleOf(D, 1, 32));
    AssertEquals(Low(Integer), SampleOf(D, 2, 32));
    AssertEquals(High(Integer), SampleOf(D, 3, 32));
  finally
    R.Free;
  end;
end;

procedure TTestAiff.LittleEndianAifcIsReadAsItIs;
const
  FRAMES = 3000;
var
  R: TAiffReader;
  D: TBytes;
  F: Integer;
begin
  SaveBytes(FDir + 'a.aifc', Form('AIFC', Chunk('FVER', BE32($A2805140)) +
    Comm(2, FRAMES, 16, 44100, 'sowt') + Sound(PatternData(FRAMES, 16, True))));
  R := TAiffReader.Create(FDir + 'a.aifc');
  try
    AssertEquals(16, Integer(R.BitsPerSample));
    D := ReadAll(R, 64 * 1024);
    AssertEquals(FRAMES * 4, Length(D));
    for F := 0 to FRAMES - 1 do
      if (SampleOf(D, F * 2, 16) <> PatternSample(F, 0, 16)) or
         (SampleOf(D, F * 2 + 1, 16) <> PatternSample(F, 1, 16)) then
        Fail(Format('Frame %d', [F]));
  finally
    R.Free;
  end;
end;

procedure TTestAiff.FloatingPointBecomes32Bit;
var
  R: TAiffReader;
  D: TBytes;
begin
  // 0.5, -0.5, 1.0, -1.0, 2.0 (over full scale), 0.0 as 32-bit numbers,
  // big-endian
  SaveBytes(FDir + 'a.aifc', Form('AIFC', Comm(1, 6, 32, 48000, 'fl32') +
    Sound(#$3F#$00#$00#$00 + #$BF#$00#$00#$00 + #$3F#$80#$00#$00 + #$BF#$80#$00#$00 +
          #$40#$00#$00#$00 + #$00#$00#$00#$00)));
  R := TAiffReader.Create(FDir + 'a.aifc');
  try
    AssertEquals(32, Integer(R.BitsPerSample));
    D := ReadAll(R, 4096);
    AssertEquals(24, Length(D));
    AssertEquals('0.5', 1073741824, SampleOf(D, 0, 32), 1);
    AssertEquals('-0.5', -1073741824, SampleOf(D, 1, 32), 1);
    AssertEquals('1.0 is full scale', High(Integer), SampleOf(D, 2, 32));
    AssertEquals('-1.0', -2147483647, SampleOf(D, 3, 32), 1);
    AssertEquals('2.0 is limited', High(Integer), SampleOf(D, 4, 32));
    AssertEquals('0.0', 0, SampleOf(D, 5, 32));
  finally
    R.Free;
  end;

  // the same as 64-bit numbers
  SaveBytes(FDir + 'b.aifc', Form('AIFC', Comm(1, 3, 64, 48000, 'fl64') +
    Sound(#$3F#$E0#0#0#0#0#0#0 + #$BF#$E0#0#0#0#0#0#0 + #$3F#$D0#0#0#0#0#0#0)));
  R := TAiffReader.Create(FDir + 'b.aifc');
  try
    AssertEquals(32, Integer(R.BitsPerSample));
    D := ReadAll(R, 4096);
    AssertEquals(12, Length(D));
    AssertEquals('0.5', 1073741824, SampleOf(D, 0, 32), 1);
    AssertEquals('-0.5', -1073741824, SampleOf(D, 1, 32), 1);
    AssertEquals('0.25', 536870912, SampleOf(D, 2, 32), 1);
  finally
    R.Free;
  end;
end;

procedure TTestAiff.EightBitIsWidenedTo16;
var
  R: TAiffReader;
  D: TBytes;
begin
  // AIFF 8 bit is signed
  SaveBytes(FDir + 'a.aiff', Form('AIFF', Comm(1, 4, 8, 22050) + Sound(#$80#$7F#$00#$01)));
  R := TAiffReader.Create(FDir + 'a.aiff');
  try
    AssertEquals('Played as 16 bit', 16, Integer(R.BitsPerSample));
    AssertEquals(8, Integer(R.DataSize));
    D := ReadAll(R, 4096);
    AssertEquals(8, Length(D));
    AssertEquals(-32768, SampleOf(D, 0, 16));
    AssertEquals(127 * 256, SampleOf(D, 1, 16));
    AssertEquals(0, SampleOf(D, 2, 16));
    AssertEquals(256, SampleOf(D, 3, 16));
  finally
    R.Free;
  end;
end;

procedure TTestAiff.TheSoundMayComeBeforeItsDescription;
const
  FRAMES = 1000;
var
  R: TAiffReader;
  D: TBytes;
begin
  // the sound first, then a chunk of odd length, then the description
  SaveBytes(FDir + 'a.aiff', Form('AIFF', Sound(PatternData(FRAMES, 16)) +
    Chunk('NAME', 'odd') + Comm(2, FRAMES, 16, 44100)));
  R := TAiffReader.Create(FDir + 'a.aiff');
  try
    D := ReadAll(R, 64 * 1024);
    AssertEquals(FRAMES * 4, Length(D));
    AssertEquals(PatternSample(0, 0, 16), SampleOf(D, 0, 16));
    AssertEquals(PatternSample(FRAMES - 1, 1, 16), SampleOf(D, FRAMES * 2 - 1, 16));
  finally
    R.Free;
  end;

  // a description that names more frames than the file holds: what is there
  SaveBytes(FDir + 'b.aiff', Form('AIFF', Comm(2, 5000, 16, 44100) + Sound(PatternData(FRAMES, 16))));
  R := TAiffReader.Create(FDir + 'b.aiff');
  try
    AssertEquals(Int64(FRAMES) * 4, R.DataSize);
  finally
    R.Free;
  end;
end;

procedure TTestAiff.CompressedAndForeignFilesAreRefused;

  function ErrorOf(const AFile: string): string;
  var
    R: TAiffReader;
  begin
    Result := '';
    try
      R := TAiffReader.Create(AFile);
      R.Free;
    except
      on E: Exception do
        Result := E.Message;
    end;
  end;

begin
  SaveBytes(FDir + 'ima.aifc', Form('AIFC', Comm(2, 100, 16, 44100, 'ima4') + Sound(StringOfChar(#1, 400))));
  AssertEquals('Compressed', ERR_DECODE_AIFF_COMPRESSED, ErrorOf(FDir + 'ima.aifc'));

  WriteTestWav(FDir + 'wav.aiff');
  AssertEquals('A WAV file with the wrong name', ERR_DECODE_NOTAIFF, ErrorOf(FDir + 'wav.aiff'));

  SaveBytes(FDir + 'nosound.aiff', Form('AIFF', Comm(2, 100, 16, 44100)));
  AssertEquals('No sound', ERR_DECODE_AIFFINVALID, ErrorOf(FDir + 'nosound.aiff'));

  SaveBytes(FDir + 'nocomm.aiff', Form('AIFF', Sound(StringOfChar(#1, 400))));
  AssertEquals('No description', ERR_DECODE_AIFFINVALID, ErrorOf(FDir + 'nocomm.aiff'));

  SaveBytes(FDir + 'norate.aiff', Form('AIFF', Comm(2, 100, 16, 0) + Sound(StringOfChar(#1, 400))));
  AssertEquals('No sample rate', ERR_DECODE_AIFFINVALID, ErrorOf(FDir + 'norate.aiff'));
end;

procedure TTestAiff.OddReadSizesGiveTheSameSamples;
var
  R: TAiffReader;
  A, B: TBytes;
begin
  // more frames than the reader's own buffer holds
  WritePatternAiff(FDir + 'a.aiff', 9000, 24);
  R := TAiffReader.Create(FDir + 'a.aiff');
  try
    A := ReadAll(R, 64 * 1024);
  finally
    R.Free;
  end;
  R := TAiffReader.Create(FDir + 'a.aiff');
  try
    B := ReadAll(R, 6 * 37 + 5);          // not a whole number of frames
  finally
    R.Free;
  end;
  AssertEquals(9000 * 6, Length(A));
  AssertEquals(Length(A), Length(B));
  AssertTrue('The same bytes', CompareMem(@A[0], @B[0], Length(A)));
end;

procedure TTestAiff.SeekContinuesAtTheTarget;
var
  R: TAiffReader;
  D: TBytes;
begin
  WritePatternAiff(FDir + 'a.aiff', 4000, 16);
  R := TAiffReader.Create(FDir + 'a.aiff');
  try
    R.Seek(0.5);
    AssertEquals(0.5, R.GetProgress, 0.0001);
    D := ReadAll(R, 64 * 1024);
    AssertEquals(2000 * 4, Length(D));
    AssertEquals(PatternSample(2000, 0, 16), SampleOf(D, 0, 16));
    AssertEquals(PatternSample(2000, 1, 16), SampleOf(D, 1, 16));
    R.Seek(1.0);
    AssertEquals('Nothing behind the end', 0, Length(ReadAll(R, 4096)));
  finally
    R.Free;
  end;
end;

procedure TTestAiff.TheNamesOfAiffFiles;
begin
  AssertTrue(IsAiffFile('C:\Music\a.aiff'));
  AssertTrue(IsAiffFile('C:\Music\a.AIF'));
  AssertTrue(IsAiffFile('C:\Music\a.aifc'));
  AssertFalse(IsAiffFile('C:\Music\a.wav'));
  AssertTrue('The scanner takes them', IsValidMusicFile('C:\Music\a.aiff'));
  AssertTrue(IsValidMusicFile('C:\Music\a.aif'));
  AssertTrue(IsValidMusicFile('C:\Music\a.aifc'));
end;

procedure TTestAiff.TheFactoryBuildsItsSource;
var
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate, Bits: Integer;
  Makeup: Double;
begin
  C := Default(TPlayThreadConfig);
  WritePatternAiff(FDir + 'a.aif', 2000, 24, 88200);
  S := CreateSourceFor(C, 0, nil, FDir + 'a.aif', InRate, OutRate);
  try
    AssertTrue('A source', Assigned(S));
    AssertEquals(88200, OutRate);
    AssertEquals(2, Integer(S.GetChannels));
    AssertEquals(24, Integer(S.GetBitsPerSample));
    AssertEquals('Its length', 2000 / 88200, S.GetDuration, 0.0001);
  finally
    S.Free;
  end;

  // one channel is doubled, six are mixed
  SaveBytes(FDir + 'mono.aiff', Form('AIFF', Comm(1, 1000, 16, 44100) + Sound(StringOfChar(#1, 2000))));
  S := CreateSourceFor(C, 0, nil, FDir + 'mono.aiff', InRate, OutRate);
  try
    AssertEquals(2, Integer(S.GetChannels));
    AssertEquals('Not a mix', 0, DownmixOf(S, Bits, Makeup));
  finally
    S.Free;
  end;
  SaveBytes(FDir + 'six.aiff', Form('AIFF', Comm(6, 1000, 16, 44100) + Sound(StringOfChar(#1, 12000))));
  S := CreateSourceFor(C, 0, nil, FDir + 'six.aiff', InRate, OutRate);
  try
    AssertEquals(2, Integer(S.GetChannels));
    AssertEquals('Mixed from six channels', 6, DownmixOf(S, Bits, Makeup));
    AssertEquals(16, Bits);
  finally
    S.Free;
  end;
end;

procedure TTestAiff.AFileWithoutATagGetsOne;
var
  F: string;
  Snd, After: AnsiString;
begin
  F := FDir + 'a.aiff';
  Snd := PatternData(2000, 16);
  SaveBytes(F, Form('AIFF', Comm(2, 2000, 16, 44100) + Sound(Snd)));
  AssertEquals('Saved', '', Retitle(F));
  AssertEquals('New title', Field(F, 'TIT2'));
  After := FileBytes(F);
  AssertTrue('The sound', Pos(Snd, After) > 0);
  AssertTrue('The size of the FORM', Copy(After, 5, 4) = BE32(Length(After) - 8));
  AssertTrue('The tag chunk', Pos('ID3 ', After) > 0);
  AssertEquals('An even length', 0, Length(After) mod 2);
end;

procedure TTestAiff.ASaveKeepsTheSoundAndEveryOtherChunk;
var
  F: string;
  Before, Snd, After, Name, Appl: AnsiString;
  R: TAiffReader;
  D: TBytes;
begin
  // an AIFF-C file with chunks the tag library does not know, one of odd
  // length, and bytes behind the FORM
  F := FDir + 'a.aifc';
  Snd  := PatternData(1500, 24);
  Name := Chunk('NAME', 'An odd name');
  Appl := Chunk('APPL', 'stoc' + StringOfChar(#7, 40));
  Before := Form('AIFC', Chunk('FVER', BE32($A2805140)) + Comm(2, 1500, 24, 96000, 'NONE') +
    Name + Sound(Snd) + Appl) + 'TRAILER';
  SaveBytes(F, Before);

  AssertEquals('Saved', '', Retitle(F));
  After := FileBytes(F);
  AssertEquals('New title', Field(F, 'TIT2'));
  AssertTrue('The sound', Pos(Snd, After) > 0);
  AssertTrue('The name chunk with its pad byte', Pos(Name, After) > 0);
  AssertTrue('The application chunk', Pos(Appl, After) > 0);
  AssertTrue('The version chunk', Pos(Chunk('FVER', BE32($A2805140)), After) > 0);
  AssertTrue('Still AIFF-C', Copy(After, 9, 4) = 'AIFC');
  AssertTrue('The bytes behind the FORM, still behind it', Copy(After, Length(After) - 6, 7) = 'TRAILER');
  AssertTrue('The size of the FORM without them', Copy(After, 5, 4) = BE32(Length(After) - 8 - 7));
  AssertTrue('Everything before the tag as it was',
    Copy(After, 13, Length(Before) - 12 - 7) = Copy(Before, 13, Length(Before) - 12 - 7));

  // and it still plays the same
  R := TAiffReader.Create(F);
  try
    D := ReadAll(R, 64 * 1024);
    AssertEquals(1500 * 6, Length(D));
    AssertEquals(PatternSample(1499, 1, 24), SampleOf(D, 2999, 24));
  finally
    R.Free;
  end;
end;

procedure TTestAiff.ATagIsReplacedNotAdded;
var
  F: string;
  Snd, After: AnsiString;
  Count, P: Integer;
begin
  F := FDir + 'a.aiff';
  Snd := PatternData(1000, 16);
  SaveBytes(F, Form('AIFF', Comm(2, 1000, 16, 44100) + Sound(Snd)));
  AssertEquals('', Retitle(F));
  AssertEquals('', Retitle(F));
  AssertEquals('', Retitle(F));
  After := FileBytes(F);
  Count := 0;
  P := Pos('ID3 ', After);
  while P > 0 do
  begin
    Inc(Count);
    P := Pos('ID3 ', After, P + 4);
  end;
  AssertEquals('One tag chunk after three saves', 1, Count);
  AssertTrue('The sound', Pos(Snd, After) > 0);
  AssertTrue('The size of the FORM', Copy(After, 5, 4) = BE32(Length(After) - 8));
end;

procedure TTestAiff.ADamagedFileIsNotRewritten;
var
  F: string;
  Before: AnsiString;
begin
  // a FORM that says it is longer than the file
  F := FDir + 'a.aiff';
  Before := Form('AIFF', Comm(2, 1000, 16, 44100) + Sound(PatternData(1000, 16)));
  Before[5] := #$7F;
  SaveBytes(F, Before);
  AssertTrue('A FORM longer than the file: refused', Pos('not saved', Retitle(F)) = 1);
  AssertTrue('The file is as it was', FileBytes(F) = Before);

  // a chunk that runs out of the FORM
  Before := Form('AIFF', Comm(2, 1000, 16, 44100) + 'SSND' + BE32(900000) + PatternData(1000, 16));
  SaveBytes(F, Before);
  AssertTrue('Refused', Retitle(F) <> '');
  AssertTrue('The file is as it was', FileBytes(F) = Before);
end;

procedure TTestAiff.TheLibraryReadsItsProperties;
var
  F: string;
  M: TAudioMetadata;
begin
  F := FDir + 'a.aiff';
  SaveBytes(F, Form('AIFF', Comm(2, 96000, 24, 96000) + Sound(StringOfChar(#0, 96000 * 6))));
  AssertEquals('', Retitle(F));
  M := ReadTrackMetadata(F, False);
  AssertEquals('New title', M.Title);
  AssertEquals(96000, M.SampleRate);
  AssertEquals(24, M.BitDepth);
  AssertEquals(2, M.Channels);
  AssertTrue('A length: ' + M.DurationStr, Pos('0:01', M.DurationStr) > 0);
end;

{ TTestPlaybackAiff }

procedure TTestPlaybackAiff.Plays16BitBitPerfect;
const
  FRAMES = 50000;
begin
  WritePatternAiff(FDir + 'a.aiff', FRAMES, 16);
  Play(FDir + 'a.aiff');
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  AssertEquals('At the rate of the file', 44100, Integer(FRecorder.Opens(0).Rate));
  CheckPattern('32-bit device', FRecorder.Data, 32, 16, 0, 0, FRAMES);
  CheckSilence('After the last frame', FRecorder.Data, FRAMES * 8, Length(FRecorder.Data));
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlaybackAiff.Plays24BitBitPerfect;
const
  FRAMES = 30000;
begin
  WritePatternAiff(FDir + 'a.aif', FRAMES, 24, 96000);
  Play(FDir + 'a.aif');
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  AssertEquals('At the rate of the file', 96000, Integer(FRecorder.Opens(0).Rate));
  CheckPattern('32-bit device', FRecorder.Data, 32, 24, 0, 0, FRAMES);
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
end;

initialization
  RegisterTest(TTestAiff);
  RegisterTest(TTestPlaybackAiff);

end.
