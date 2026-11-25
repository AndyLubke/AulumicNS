unit TestAlac;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestAlac
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Apple Lossless in M4A files.

  The decoder (ALDecAlac) against two files made by another encoder: every
  sample must be the one the file was made from. The MP4 container (ALMp4)
  and the reader (TAlacReader) with files built here from their bytes, their
  packets stored uncoded so each one holds exactly the case it tests: the
  packets found through the tables, a last packet that is shorter, read sizes
  and seeking, the tables in the wide form, AAC and foreign files refused, a
  packet that lies outside the file. The engine: the source factory, the
  order of the channels of a file with more than two, a track played to the
  end bit-perfect. The tags: every field under its name, track and disc
  numbers, free-form entries, the cover.

  Saving tags (TTestM4aTags): one field is changed and everything else must
  still be there - the sound packet for packet, every entry of the tag list
  that was not edited byte for byte, also the ones no field shows; with the
  description in front of the sound (its positions move) and behind it, with
  the wide tables, for a file that had no tags; several values, numbers,
  free-form entries, a field removed, the cover replaced, added and removed;
  a file made by another encoder; and the files that are not rewritten.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, TestPlayback;

type
  TTestAlac = class(TTestCase)
  private
    FDir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ACompressed16BitFileIsDecodedExactly;
    procedure ACompressed24BitFileIsDecodedExactly;
    procedure ThePacketsAreFoundThroughTheTables;
    procedure OddReadSizesGiveTheSameSamples;
    procedure SeekContinuesAtTheTarget;
    procedure WidePositionsAndOneChunkPerPacket;
    procedure TwentyFourBitStoredUncoded;
    procedure AacAndForeignFilesAreRefused;
    procedure APacketOutsideTheFileIsRefused;
    procedure TheNamesOfM4aFiles;
    procedure TheFactoryBuildsItsSource;
    procedure TheCentreComesFirstInAFileWithMoreChannels;
    procedure TheTagsComeUnderTheNamesOfAFlacFile;
    procedure TheCoverIsReadAndLeftOutOnRequest;
    procedure TheLibraryReadsItsProperties;
  end;

  TTestM4aTags = class(TTestCase)
  private
    FDir: string;
    // Sets AField to AValue ('' removes it) and saves; '' when saved
    function SetField(const AFile, AField, AValue: string): string;
    function Field(const AFile, AField: string): string;
    // The file still holds AFrames frames of the test samples
    procedure CheckSound(const AFile: string; AFrames: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ASaveKeepsTheSoundAndEveryOtherEntry;
    procedure TheSoundBehindTheDescriptionIsFoundAgain;
    procedure TheDescriptionBehindTheSoundNeedsNoMove;
    procedure WideTablesAreMovedToo;
    procedure AFileWithoutTagsGetsThem;
    procedure ASaveWithoutAChangeLeavesTheFileAsItWas;
    procedure NumbersFreeFormAndSeveralValues;
    procedure AFieldCanBeRemoved;
    procedure TheCoverIsReplacedAddedAndRemoved;
    procedure AFileOfAnotherEncoderStillDecodesTheSame;
    procedure FilesThatAreNotRewritten;
  end;

  TTestPlaybackAlac = class(TPlaybackTestBase)
  published
    procedure PlaysBitPerfect;
  end;

implementation

uses
  Math, base64, ALAudioTypes, ALReaders, ALReaderALAC, ALMp4, ALDecAlac, ALSourceFactory, ALMetadata,
  uAudioUtils, uAppStrings, AudioTag, baseTag, tag_vorbis, TestHelpers;

{$I AlacFixtures.inc}

const
  FRAME_LEN = 4096;

{ ---- bytes ---- }

function BE16(V: Integer): AnsiString;
begin
  Result := AnsiChar((V shr 8) and $FF) + AnsiChar(V and $FF);
end;

function BE32(V: Cardinal): AnsiString;
begin
  Result := AnsiChar(V shr 24) + AnsiChar((V shr 16) and $FF) + AnsiChar((V shr 8) and $FF) + AnsiChar(V and $FF);
end;

function BE64(V: Int64): AnsiString;
begin
  Result := BE32(Cardinal(V shr 32)) + BE32(Cardinal(V and $FFFFFFFF));
end;

function Box(const AType, ABody: AnsiString): AnsiString;
begin
  Result := BE32(8 + Length(ABody)) + AType + ABody;
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

function FnvOf(const AData: TBytes): QWord;
var
  I: Integer;
begin
  Result := QWord($CBF29CE484222325);
  {$push}{$Q-}{$R-}
  for I := 0 to High(AData) do
    Result := (Result xor AData[I]) * QWord($100000001B3);
  {$pop}
end;

{ ---- a packet whose samples are stored uncoded ---- }

type
  TBitWriter2 = record
    Data: AnsiString;
    Acc: Cardinal;
    Bits: Integer;
  end;

procedure Put(var W: TBitWriter2; AValue: Cardinal; ABits: Integer);
var
  I: Integer;
begin
  for I := ABits - 1 downto 0 do
  begin
    W.Acc := (W.Acc shl 1) or ((AValue shr I) and 1);
    Inc(W.Bits);
    if W.Bits = 8 then
    begin
      W.Data := W.Data + AnsiChar(W.Acc and $FF);
      W.Acc  := 0;
      W.Bits := 0;
    end;
  end;
end;

// The sample of frame AFrame, AChannel of a test file: every one different,
// both signs, the full width of ABits
function TestSample(AFrame, AChannel, ABits: Integer): Integer;
var
  V: Int64;
begin
  V := (Int64(AFrame) * 2654435761 + Int64(AChannel) * 40503 + 12345) and $FFFFFFFF;
  V := V and ((Int64(1) shl ABits) - 1);
  if V >= (Int64(1) shl (ABits - 1)) then
    V := V - (Int64(1) shl ABits);
  Result := V;
end;

// One packet of ACount frames from frame AFirst on: AChannels channels as the
// format lays them out (one channel, pairs, then single ones), stored uncoded
function UncodedPacket(AFirst, ACount, AChannels, ABits: Integer): AnsiString;
var
  W: TBitWriter2;
  Ch, I, K, N: Integer;
  Pair: Boolean;
  V: Cardinal;
begin
  W := Default(TBitWriter2);
  Ch := 0;
  while Ch < AChannels do
  begin
    // the layouts: mono; a pair; with more channels the centre alone first,
    // then pairs, a last single one
    Pair := (AChannels = 2) or ((AChannels > 2) and (Ch >= 1) and (Ch + 1 < AChannels));
    if Pair then N := 2 else N := 1;
    if Pair then Put(W, 1, 3) else Put(W, 0, 3);
    Put(W, 0, 4);                           // the number of the element
    Put(W, 0, 12);
    if ACount <> FRAME_LEN then Put(W, 9, 4) else Put(W, 1, 4);   // uncoded; a shorter packet says so
    if ACount <> FRAME_LEN then Put(W, ACount, 32);
    for I := 0 to ACount - 1 do
      for K := 0 to N - 1 do
      begin
        V := Cardinal(TestSample(AFirst + I, Ch + K, ABits));
        Put(W, V and ((QWord(1) shl ABits) - 1), ABits);
      end;
    Inc(Ch, N);
  end;
  Put(W, 7, 3);                             // the end
  while W.Bits <> 0 do
    Put(W, 0, 1);
  Result := W.Data;
end;

// The decoder's settings as the file stores them
function Cookie(AChannels, ABits: Integer; ARate: Cardinal): AnsiString;
begin
  Result := BE32(FRAME_LEN) + #0 + AnsiChar(ABits) + #40 + #10 + #14 + AnsiChar(AChannels) +
    BE16(255) + BE32(0) + BE32(0) + BE32(ARate);
end;

type
  TMp4Options = record
    Codec: AnsiString;       // 'alac' or what the sound is said to be coded in
    Wide: Boolean;           // the positions as 64-bit numbers
    OneChunk: Boolean;       // all packets in one chunk (else one chunk each)
    Tags: AnsiString;        // the boxes of the tag list
    BadOffset: Boolean;      // a packet that lies outside the file
    MoovLast: Boolean;       // the description behind the sound
  end;

// An M4A file of AFrames frames: a sound track with its tables in 'moov',
// then the packets
function Mp4Bytes(AFrames, AChannels, ABits: Integer; ARate: Cardinal; const AOpt: TMp4Options): AnsiString;
var
  Packets: array of AnsiString;
  N, I, First, Count: Integer;
  Ftyp, Stsd, Stts, Stsc, Stsz, Stco, Stbl, Trak, Moov, Mdat, Entry, Udta, Codec: AnsiString;
  Offset: Int64;
begin
  Packets := nil;
  N := (AFrames + FRAME_LEN - 1) div FRAME_LEN;
  SetLength(Packets, N);
  First := 0;
  for I := 0 to N - 1 do
  begin
    Count := Min(FRAME_LEN, AFrames - First);
    Packets[I] := UncodedPacket(First, Count, AChannels, ABits);
    Inc(First, Count);
  end;

  Codec := AOpt.Codec;
  if Codec = '' then Codec := 'alac';
  Ftyp := Box('ftyp', 'M4A ' + BE32(0) + 'M4A mp42isom');
  Entry := StringOfChar(#0, 6) + BE16(1) +                       // reserved, data reference
    BE16(0) + BE16(0) + BE32(0) + BE16(AChannels) + BE16(16) + BE16(0) + BE16(0) + BE32(ARate shl 16) +
    Box(Codec, BE32(0) + Cookie(AChannels, ABits, ARate));
  Stsd := Box('stsd', BE32(0) + BE32(1) + Box(Codec, Entry));
  Stts := Box('stts', BE32(0) + BE32(1) + BE32(AFrames) + BE32(1));
  Stsz := BE32(0) + BE32(0) + BE32(N);
  for I := 0 to N - 1 do
    Stsz := Stsz + BE32(Length(Packets[I]));
  Stsz := Box('stsz', Stsz);
  if AOpt.OneChunk then
    Stsc := Box('stsc', BE32(0) + BE32(1) + BE32(1) + BE32(N) + BE32(1))
  else
    Stsc := Box('stsc', BE32(0) + BE32(1) + BE32(1) + BE32(1) + BE32(1));

  Udta := '';
  if AOpt.Tags <> '' then
    Udta := Box('udta', Box('meta', BE32(0) + Box('hdlr', BE32(0) + BE32(0) + 'mdirappl' + StringOfChar(#0, 9)) +
      Box('ilst', AOpt.Tags)));

  // The positions depend on the size of 'moov', which holds them: twice
  Stco := '';
  Moov := '';
  for Count := 1 to 2 do
  begin
    Offset := Length(Ftyp) + Length(Moov) + 8;
    if AOpt.MoovLast then
      Offset := Length(Ftyp) + 8;
    if AOpt.BadOffset then
      Offset := Offset + 100000000;
    if AOpt.Wide then
    begin
      if AOpt.OneChunk then
        Stco := BE32(0) + BE32(1) + BE64(Offset)
      else
      begin
        Stco := BE32(0) + BE32(N);
        for I := 0 to N - 1 do
        begin
          Stco := Stco + BE64(Offset);
          Inc(Offset, Length(Packets[I]));
        end;
      end;
      Stco := Box('co64', Stco);
    end
    else
    begin
      if AOpt.OneChunk then
        Stco := BE32(0) + BE32(1) + BE32(Offset)
      else
      begin
        Stco := BE32(0) + BE32(N);
        for I := 0 to N - 1 do
        begin
          Stco := Stco + BE32(Offset);
          Inc(Offset, Length(Packets[I]));
        end;
      end;
      Stco := Box('stco', Stco);
    end;
    Stbl := Box('stbl', Stsd + Stts + Stsc + Stsz + Stco);
    Trak := Box('trak',
      Box('tkhd', StringOfChar(#0, 84)) +
      Box('mdia',
        Box('mdhd', BE32(0) + BE32(0) + BE32(0) + BE32(ARate) + BE32(AFrames) + BE32(0)) +
        Box('hdlr', BE32(0) + BE32(0) + 'soun' + StringOfChar(#0, 13)) +
        Box('minf', Box('smhd', StringOfChar(#0, 8)) + Stbl)));
    Moov := Box('moov', Box('mvhd', StringOfChar(#0, 100)) + Trak + Udta);
  end;

  Mdat := '';
  for I := 0 to N - 1 do
    Mdat := Mdat + Packets[I];
  if AOpt.MoovLast then
    Result := Ftyp + Box('mdat', Mdat) + Moov
  else
    Result := Ftyp + Moov + Box('mdat', Mdat);
end;

procedure WriteM4a(const AFile: string; AFrames, AChannels, ABits: Integer; ARate: Cardinal = 44100);
begin
  SaveBytes(AFile, Mp4Bytes(AFrames, AChannels, ABits, ARate, Default(TMp4Options)));
end;

function ReadAll(AReader: TAlacReader; AChunk: Integer): TBytes;
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

// AData holds ACount frames of the test samples from frame AFirst on
procedure CheckSamples(ATest: TTestCase; const AData: TBytes; AFirst, ACount, AChannels, ABits: Integer);
var
  F, C: Integer;
begin
  ATest.AssertEquals('The frames', ACount * AChannels * (ABits div 8), Length(AData));
  for F := 0 to ACount - 1 do
    for C := 0 to AChannels - 1 do
      if SampleOf(AData, F * AChannels + C, ABits) <> TestSample(AFirst + F, C, ABits) then
        ATest.Fail(Format('Frame %d, channel %d: %d, expected %d', [AFirst + F, C,
          SampleOf(AData, F * AChannels + C, ABits), TestSample(AFirst + F, C, ABits)]));
end;

{ ---- tags ---- }

function TextItem(const AName, AValue: AnsiString): AnsiString;
begin
  Result := Box(AName, Box('data', BE32(1) + BE32(0) + AValue));
end;

function FreeItem(const AName, AValue: AnsiString): AnsiString;
begin
  Result := Box('----', Box('mean', BE32(0) + 'com.apple.iTunes') + Box('name', BE32(0) + AName) +
    Box('data', BE32(1) + BE32(0) + AValue));
end;

{ TTestAlac }

procedure TTestAlac.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestAlac.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure TTestAlac.ACompressed16BitFileIsDecodedExactly;
var
  R: TAlacReader;
  D: TBytes;
begin
  SaveBytes(FDir + 'a.m4a', DecodeStringBase64(ALAC_FIX16_B64));
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    AssertEquals(2, Integer(R.Channels));
    AssertEquals(16, Integer(R.BitsPerSample));
    AssertEquals(44100, Integer(R.SampleRate));
    D := ReadAll(R, 64 * 1024);
    AssertEquals('5000 frames', 5000 * 4, Length(D));
    AssertTrue('Every sample is the one the file was made from', FnvOf(D) = ALAC_FIX16_HASH);
  finally
    R.Free;
  end;
  // and whatever the read sizes
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    D := ReadAll(R, 4 * 61 + 3);
    AssertEquals(5000 * 4, Length(D));
    AssertTrue('The same samples in small reads', FnvOf(D) = ALAC_FIX16_HASH);
  finally
    R.Free;
  end;
end;

procedure TTestAlac.ACompressed24BitFileIsDecodedExactly;
var
  R: TAlacReader;
  D: TBytes;
begin
  SaveBytes(FDir + 'a.m4a', DecodeStringBase64(ALAC_FIX24_B64));
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    AssertEquals(1, Integer(R.Channels));
    AssertEquals(24, Integer(R.BitsPerSample));
    AssertEquals(96000, Integer(R.SampleRate));
    D := ReadAll(R, 64 * 1024);
    AssertEquals('5000 frames', 5000 * 3, Length(D));
    AssertTrue('Every sample is the one the file was made from', FnvOf(D) = ALAC_FIX24_HASH);
  finally
    R.Free;
  end;
end;

procedure TTestAlac.ThePacketsAreFoundThroughTheTables;
const
  FRAMES = 3 * FRAME_LEN + 777;       // three whole packets and a shorter one
var
  R: TAlacReader;
  M: TMp4File;
begin
  WriteM4a(FDir + 'a.m4a', FRAMES, 2, 16);
  M := TMp4File.Create(FDir + 'a.m4a');
  try
    AssertEquals('alac', M.Codec);
    AssertEquals('Four packets', 4, M.PacketCount);
    AssertEquals(Int64(FRAMES), M.TotalFrames);
    AssertEquals('The settings of the decoder', 24, Length(M.Cookie));
  finally
    M.Free;
  end;
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    AssertEquals(Int64(FRAMES) * 4, R.DataSize);
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, FRAMES, 2, 16);
    AssertEquals('At the end', 1.0, R.GetProgress, 0.0001);
  finally
    R.Free;
  end;
end;

procedure TTestAlac.OddReadSizesGiveTheSameSamples;
const
  FRAMES = 2 * FRAME_LEN + 100;
var
  R: TAlacReader;
begin
  WriteM4a(FDir + 'a.m4a', FRAMES, 2, 16);
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    CheckSamples(Self, ReadAll(R, 4 * 97 + 1), 0, FRAMES, 2, 16);
  finally
    R.Free;
  end;
end;

procedure TTestAlac.SeekContinuesAtTheTarget;
const
  FRAMES = 4 * FRAME_LEN;
var
  R: TAlacReader;
  D: TBytes;
begin
  WriteM4a(FDir + 'a.m4a', FRAMES, 2, 16);
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    // into the middle of a packet
    R.Seek(0.3);
    D := ReadAll(R, 64 * 1024);
    CheckSamples(Self, D, Round(0.3 * FRAMES), FRAMES - Round(0.3 * FRAMES), 2, 16);
    // back to the start
    R.Seek(0.0);
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, FRAMES, 2, 16);
    R.Seek(1.0);
    AssertEquals('Nothing behind the end', 0, Length(ReadAll(R, 4096)));
  finally
    R.Free;
  end;
end;

procedure TTestAlac.WidePositionsAndOneChunkPerPacket;
const
  FRAMES = 2 * FRAME_LEN + 500;
var
  R: TAlacReader;
  O: TMp4Options;
begin
  O := Default(TMp4Options);
  O.Wide := True;
  SaveBytes(FDir + 'wide.m4a', Mp4Bytes(FRAMES, 2, 16, 48000, O));
  R := TAlacReader.Create(FDir + 'wide.m4a');
  try
    AssertEquals(48000, Integer(R.SampleRate));
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, FRAMES, 2, 16);
  finally
    R.Free;
  end;

  O := Default(TMp4Options);
  O.OneChunk := True;
  SaveBytes(FDir + 'one.m4a', Mp4Bytes(FRAMES, 2, 16, 48000, O));
  R := TAlacReader.Create(FDir + 'one.m4a');
  try
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, FRAMES, 2, 16);
  finally
    R.Free;
  end;
end;

procedure TTestAlac.TwentyFourBitStoredUncoded;
const
  FRAMES = FRAME_LEN + 300;
var
  R: TAlacReader;
begin
  WriteM4a(FDir + 'a.m4a', FRAMES, 2, 24, 96000);
  R := TAlacReader.Create(FDir + 'a.m4a');
  try
    AssertEquals(24, Integer(R.BitsPerSample));
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, FRAMES, 2, 24);
  finally
    R.Free;
  end;
  // one channel
  WriteM4a(FDir + 'mono.m4a', FRAMES, 1, 16);
  R := TAlacReader.Create(FDir + 'mono.m4a');
  try
    AssertEquals(1, Integer(R.Channels));
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, FRAMES, 1, 16);
  finally
    R.Free;
  end;
end;

function ErrorOf(const AFile: string): string;
var
  R: TAlacReader;
begin
  Result := '';
  try
    R := TAlacReader.Create(AFile);
    R.Free;
  except
    on E: Exception do
      Result := E.Message;
  end;
end;

procedure TTestAlac.AacAndForeignFilesAreRefused;
var
  O: TMp4Options;
begin
  O := Default(TMp4Options);
  O.Codec := 'mp4a';
  SaveBytes(FDir + 'aac.m4a', Mp4Bytes(FRAME_LEN, 2, 16, 44100, O));
  AssertEquals('AAC has its own message', ERR_DECODE_M4A_AAC, ErrorOf(FDir + 'aac.m4a'));

  O.Codec := 'ac-3';
  SaveBytes(FDir + 'other.m4a', Mp4Bytes(FRAME_LEN, 2, 16, 44100, O));
  AssertEquals(ERR_DECODE_M4A_OTHER, ErrorOf(FDir + 'other.m4a'));

  WriteTestWav(FDir + 'wav.m4a');
  AssertTrue('A WAV file with the wrong name', Pos(ERR_DECODE_M4A_INVALID, ErrorOf(FDir + 'wav.m4a')) = 1);

  SaveBytes(FDir + 'empty.m4a', Box('ftyp', 'M4A ' + BE32(0)) + Box('mdat', 'nothing'));
  AssertTrue('No description of the sound', Pos(ERR_DECODE_M4A_INVALID, ErrorOf(FDir + 'empty.m4a')) = 1);

  AssertTrue(IsMp4File(FDir + 'aac.m4a'));
  AssertFalse(IsMp4File(FDir + 'wav.m4a'));
end;

procedure TTestAlac.APacketOutsideTheFileIsRefused;
var
  O: TMp4Options;
begin
  O := Default(TMp4Options);
  O.BadOffset := True;
  SaveBytes(FDir + 'a.m4a', Mp4Bytes(2 * FRAME_LEN, 2, 16, 44100, O));
  AssertTrue('Refused', Pos(ERR_DECODE_M4A_INVALID, ErrorOf(FDir + 'a.m4a')) = 1);
end;

procedure TTestAlac.TheNamesOfM4aFiles;
begin
  AssertTrue(IsM4aFile('C:\Music\a.m4a'));
  AssertTrue(IsM4aFile('C:\Music\a.M4A'));
  AssertFalse(IsM4aFile('C:\Music\a.mp4'));
  AssertTrue('The scanner takes them', IsValidMusicFile('C:\Music\a.m4a'));
end;

procedure TTestAlac.TheFactoryBuildsItsSource;
var
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate: Integer;
begin
  C := Default(TPlayThreadConfig);
  WriteM4a(FDir + 'a.m4a', 3 * FRAME_LEN, 2, 24, 88200);
  S := CreateSourceFor(C, 0, nil, FDir + 'a.m4a', InRate, OutRate);
  try
    AssertTrue('A source', Assigned(S));
    AssertEquals(88200, OutRate);
    AssertEquals(2, Integer(S.GetChannels));
    AssertEquals(24, Integer(S.GetBitsPerSample));
    AssertEquals('Its length', 3 * FRAME_LEN / 88200, S.GetDuration, 0.0001);
  finally
    S.Free;
  end;
end;

procedure TTestAlac.TheCentreComesFirstInAFileWithMoreChannels;
var
  Ro: TChannelRoles;
  L, R: TDownmixWeights;
  N: Double;
  C: TPlayThreadConfig;
  S: TAudioSource;
  InRate, OutRate, Bits: Integer;
  Makeup: Double;
  Rd: TAlacReader;
begin
  Ro := AlacChannelRoles(6);
  AssertEquals(6, Length(Ro));
  AssertTrue('The centre first', Ro[0] = chCentre);
  AssertTrue(Ro[1] = chLeft);
  AssertTrue(Ro[2] = chRight);
  AssertTrue(Ro[3] = chSurroundLeft);
  AssertTrue(Ro[4] = chSurroundRight);
  AssertTrue('The LFE last', Ro[5] = chLfe);
  AssertEquals('Two channels have no names', 0, Length(AlacChannelRoles(2)));
  AssertTrue(DownmixWeights(Ro, L, R, N));
  AssertEquals('The first channel goes to both sides', L[0], R[0], 0);
  AssertEquals('The second to the left only', 1.0, L[1], 0);
  AssertEquals(0.0, R[1], 0);
  AssertEquals('The last one is left out', 0.0, L[5] + R[5], 0);

  // the file itself: the channels as stored, then mixed by what they are
  WriteM4a(FDir + 'six.m4a', FRAME_LEN + 10, 6, 16);
  Rd := TAlacReader.Create(FDir + 'six.m4a');
  try
    AssertEquals(6, Integer(Rd.Channels));
    CheckSamples(Self, ReadAll(Rd, 64 * 1024), 0, FRAME_LEN + 10, 6, 16);
  finally
    Rd.Free;
  end;
  C := Default(TPlayThreadConfig);
  S := CreateSourceFor(C, 0, nil, FDir + 'six.m4a', InRate, OutRate);
  try
    AssertEquals(2, Integer(S.GetChannels));
    AssertEquals('Mixed from six channels', 6, DownmixOf(S, Bits, Makeup));
    AssertEquals(16, Bits);
  finally
    S.Free;
  end;
end;

procedure TTestAlac.TheTagsComeUnderTheNamesOfAFlacFile;
var
  O: TMp4Options;
  R: TTagReader;
  M: TAudioMetadata;
begin
  O := Default(TMp4Options);
  O.Tags := TextItem(#$A9'nam', 'The title') + TextItem(#$A9'ART', 'The artist') +
    TextItem('aART', 'The album artist') + TextItem(#$A9'alb', 'The album') +
    TextItem(#$A9'gen', 'Jazz') + TextItem(#$A9'day', '2024-05-01') + TextItem(#$A9'wrt', 'A composer') +
    Box('trkn', Box('data', BE32(0) + BE32(0) + BE16(0) + BE16(3) + BE16(12) + BE16(0))) +
    Box('disk', Box('data', BE32(0) + BE32(0) + BE16(0) + BE16(2) + BE16(4))) +
    FreeItem('replaygain_track_gain', '-6.50 dB') + FreeItem('WORK', 'A work') +
    Box('cpil', Box('data', BE32(21) + BE32(0) + #1));
  SaveBytes(FDir + 'a.m4a', Mp4Bytes(FRAME_LEN, 2, 16, 44100, O));

  R := GetFileTagsObject(FDir + 'a.m4a');
  try
    AssertFalse('Loaded', R.LoadFailed);
    AssertTrue('Fields as in a FLAC file', R.Tags is TVorbisTags);
    AssertEquals('The title', R.Tags.GetFrameValue('TITLE'));
    AssertEquals('The artist', R.Tags.GetFrameValue('ARTIST'));
    AssertEquals('The album artist', R.Tags.GetFrameValue('ALBUMARTIST'));
    AssertEquals('The album', R.Tags.GetFrameValue('ALBUM'));
    AssertEquals('3/12', R.Tags.GetFrameValue('TRACKNUMBER'));
    AssertEquals('2/4', R.Tags.GetFrameValue('DISCNUMBER'));
    AssertEquals('A free-form entry, its name in capitals', '-6.50 dB', R.Tags.GetFrameValue('REPLAYGAIN_TRACK_GAIN'));
  finally
    R.Free;
  end;

  M := ReadTrackMetadata(FDir + 'a.m4a', False);
  AssertEquals('The title', M.Title);
  AssertEquals('The artist', M.Artist);
  AssertEquals('The album artist', M.AlbumArtist);
  AssertEquals('The album', M.Album);
  AssertEquals('Jazz', M.Genre);
  AssertEquals('A composer', M.Composer);
  AssertEquals('A work', M.Work);
  AssertEquals(3, M.TrackNumber);
  AssertEquals(2, M.DiscNumber);
  AssertEquals(2024, M.Year);
end;

procedure TTestAlac.TheCoverIsReadAndLeftOutOnRequest;
var
  O: TMp4Options;
  R: TTagReader;
  Pic: AnsiString;
begin
  Pic := #$89'PNG'#13#10#26#10 + StringOfChar(#7, 500);
  O := Default(TMp4Options);
  O.Tags := TextItem(#$A9'nam', 'The title') + Box('covr', Box('data', BE32(14) + BE32(0) + Pic));
  SaveBytes(FDir + 'a.m4a', Mp4Bytes(FRAME_LEN, 2, 16, 44100, O));

  R := GetFileTagsObject(FDir + 'a.m4a');
  try
    AssertEquals('One picture', 1, R.Tags.ImageCount);
    AssertEquals('image/png', R.Tags.Images[0].MIMEType);
    AssertEquals('All of its bytes', Int64(Length(Pic)), R.Tags.Images[0].Image.Size);
    AssertEquals('The picture is no text field', 1, R.Tags.Count);
  finally
    R.Free;
  end;
  // text only: the picture is not loaded
  R := GetFileTagsObject(FDir + 'a.m4a', True);
  try
    AssertEquals('No picture', 0, R.Tags.ImageCount);
    AssertEquals('The title', R.Tags.GetFrameValue('TITLE'));
  finally
    R.Free;
  end;
  AssertTrue('The library knows there is a cover', ReadTrackMetadata(FDir + 'a.m4a', False).HasCover);
end;

procedure TTestAlac.TheLibraryReadsItsProperties;
var
  M: TAudioMetadata;
begin
  WriteM4a(FDir + 'a.m4a', 96000, 2, 24, 96000);
  M := ReadTrackMetadata(FDir + 'a.m4a', False);
  AssertEquals(96000, M.SampleRate);
  AssertEquals(24, M.BitDepth);
  AssertEquals(2, M.Channels);
  AssertTrue('A length: ' + M.DurationStr, Pos('0:01', M.DurationStr) > 0);
  AssertTrue(M.ReadOk);
end;

{ TTestM4aTags }

const
  TAG_FRAMES = 2 * FRAME_LEN + 321;

procedure TTestM4aTags.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestM4aTags.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestM4aTags.SetField(const AFile, AField, AValue: string): string;
var
  R: TTagReader;
  I: Integer;
begin
  R := GetFileTagsObject(AFile);
  try
    if R.LoadFailed then
      Exit('not loaded');
    if AValue = '' then
    begin
      for I := R.Tags.Count - 1 downto 0 do
        if SameText(R.Tags.Frames[I].ID, AField) then
          R.Tags.Remove(R.Tags.Frames[I]);
    end
    else
      R.Tags.SetFrameValue(AField, AValue, TVorbisFrame);
    if R.UpdateFile then
      Result := ''
    else
      Result := 'not saved: ' + R.LastUpdateError;
  finally
    R.Free;
  end;
end;

function TTestM4aTags.Field(const AFile, AField: string): string;
var
  R: TTagReader;
begin
  R := GetFileTagsObject(AFile);
  try
    Result := R.Tags.GetFrameValue(AField);
  finally
    R.Free;
  end;
end;

procedure TTestM4aTags.CheckSound(const AFile: string; AFrames: Integer);
var
  R: TAlacReader;
begin
  R := TAlacReader.Create(AFile);
  try
    CheckSamples(Self, ReadAll(R, 64 * 1024), 0, AFrames, 2, 16);
  finally
    R.Free;
  end;
end;

function Bytes(const AFile: string): AnsiString;
var
  B: TBytes;
begin
  B := ReadFileBytes(AFile);
  SetString(Result, PAnsiChar(@B[0]), Length(B));
end;

// A tag list with entries of every kind: text, numbers, free-form, a flag,
// a sort name no field shows, and a picture
function RichTags(out AFlag, ASort, ACover, AArtist: AnsiString): AnsiString;
begin
  AFlag   := Box('cpil', Box('data', BE32(21) + BE32(0) + #1));
  ASort   := TextItem('sonm', 'Title, The');
  ACover  := Box('covr', Box('data', BE32(14) + BE32(0) + #$89'PNG'#13#10#26#10 + StringOfChar(#9, 700)));
  AArtist := TextItem(#$A9'ART', 'The artist');
  Result := TextItem(#$A9'nam', 'The title') + AArtist + AFlag + TextItem(#$A9'alb', 'The album') +
    Box('trkn', Box('data', BE32(0) + BE32(0) + BE16(0) + BE16(3) + BE16(12) + BE16(0))) +
    ASort + FreeItem('replaygain_track_gain', '-6.50 dB') + ACover;
end;

procedure TTestM4aTags.ASaveKeepsTheSoundAndEveryOtherEntry;
var
  O: TMp4Options;
  F: string;
  Flag, Sort, Cover, Artist, After: AnsiString;
  Before: Integer;
begin
  O := Default(TMp4Options);
  O.Tags := RichTags(Flag, Sort, Cover, Artist);
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  Before := Length(Bytes(F));

  AssertEquals('Saved', '', SetField(F, 'TITLE', 'A new and much longer title than before'));
  After := Bytes(F);
  AssertEquals('A new and much longer title than before', Field(F, 'TITLE'));
  AssertEquals('The artist', Field(F, 'ARTIST'));
  AssertEquals('The album', Field(F, 'ALBUM'));
  AssertEquals('3/12', Field(F, 'TRACKNUMBER'));
  AssertEquals('-6.50 dB', Field(F, 'REPLAYGAIN_TRACK_GAIN'));
  AssertTrue('The artist entry byte for byte', Pos(Artist, After) > 0);
  AssertTrue('The flag no field shows', Pos(Flag, After) > 0);
  AssertTrue('The sort name no field shows', Pos(Sort, After) > 0);
  AssertTrue('The picture', Pos(Cover, After) > 0);
  AssertTrue('The free-form entry with its own name',
    Pos(FreeItem('replaygain_track_gain', '-6.50 dB'), After) > 0);
  AssertEquals('The file grew by the longer title', Before + Length('A new and much longer title than before') -
    Length('The title'), Length(After));
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.TheSoundBehindTheDescriptionIsFoundAgain;
var
  O: TMp4Options;
  F: string;
  Flag, Sort, Cover, Artist: AnsiString;
  M: TMp4File;
  First: Int64;
begin
  // the description in front: every position of the sound moves with it,
  // growing and shrinking
  O := Default(TMp4Options);
  O.Tags := RichTags(Flag, Sort, Cover, Artist);
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  M := TMp4File.Create(F);
  try
    First := M.PacketOffset(0);
  finally
    M.Free;
  end;

  AssertEquals('', SetField(F, 'COMMENT', StringOfChar('x', 5000)));
  M := TMp4File.Create(F);
  try
    AssertTrue('The sound moved back', M.PacketOffset(0) > First + 5000);
  finally
    M.Free;
  end;
  CheckSound(F, TAG_FRAMES);

  AssertEquals('', SetField(F, 'COMMENT', ''));
  M := TMp4File.Create(F);
  try
    AssertEquals('And forward again, to where it was', First, M.PacketOffset(0));
  finally
    M.Free;
  end;
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.TheDescriptionBehindTheSoundNeedsNoMove;
var
  O: TMp4Options;
  F: string;
  M: TMp4File;
  First: Int64;
begin
  O := Default(TMp4Options);
  O.MoovLast := True;
  O.Tags := TextItem(#$A9'nam', 'The title');
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  M := TMp4File.Create(F);
  try
    First := M.PacketOffset(0);
  finally
    M.Free;
  end;
  CheckSound(F, TAG_FRAMES);

  AssertEquals('', SetField(F, 'TITLE', StringOfChar('y', 3000)));
  M := TMp4File.Create(F);
  try
    AssertEquals('The sound stays where it is', First, M.PacketOffset(0));
  finally
    M.Free;
  end;
  AssertEquals(StringOfChar('y', 3000), Field(F, 'TITLE'));
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.WideTablesAreMovedToo;
var
  O: TMp4Options;
  F: string;
begin
  O := Default(TMp4Options);
  O.Wide := True;
  O.Tags := TextItem(#$A9'nam', 'The title');
  F := FDir + 'wide.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  AssertEquals('', SetField(F, 'ALBUM', 'An album that was not there'));
  AssertEquals('An album that was not there', Field(F, 'ALBUM'));
  CheckSound(F, TAG_FRAMES);

  O := Default(TMp4Options);
  O.OneChunk := True;
  O.Tags := TextItem(#$A9'nam', 'The title');
  F := FDir + 'one.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  AssertEquals('', SetField(F, 'ALBUM', 'An album that was not there'));
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.AFileWithoutTagsGetsThem;
var
  F: string;
begin
  F := FDir + 'a.m4a';
  WriteM4a(F, TAG_FRAMES, 2, 16);
  AssertEquals('No title yet', '', Field(F, 'TITLE'));
  AssertEquals('Saved', '', SetField(F, 'TITLE', 'A first title'));
  AssertEquals('A first title', Field(F, 'TITLE'));
  CheckSound(F, TAG_FRAMES);
  // and a second save finds the list the first one made
  AssertEquals('', SetField(F, 'ARTIST', 'An artist'));
  AssertEquals('A first title', Field(F, 'TITLE'));
  AssertEquals('An artist', Field(F, 'ARTIST'));
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.ASaveWithoutAChangeLeavesTheFileAsItWas;
var
  O: TMp4Options;
  F: string;
  Flag, Sort, Cover, Artist, Before: AnsiString;
  R: TTagReader;
begin
  O := Default(TMp4Options);
  O.Tags := RichTags(Flag, Sort, Cover, Artist);
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  Before := Bytes(F);
  R := GetFileTagsObject(F);
  try
    AssertTrue('The reader can update a file', R.isUpdateable);
    AssertTrue('Saved', R.UpdateFile);
  finally
    R.Free;
  end;
  AssertTrue('Not one byte is different', Bytes(F) = Before);
end;

procedure TTestM4aTags.NumbersFreeFormAndSeveralValues;
var
  O: TMp4Options;
  F: string;
  After: AnsiString;
  R: TTagReader;
  Fr: TVorbisFrame;
  I, Count: Integer;
begin
  O := Default(TMp4Options);
  O.Tags := TextItem(#$A9'nam', 'The title') +
    Box('trkn', Box('data', BE32(0) + BE32(0) + BE16(0) + BE16(3) + BE16(12) + BE16(0)));
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));

  AssertEquals('', SetField(F, 'TRACKNUMBER', '7/12'));
  AssertEquals('7/12', Field(F, 'TRACKNUMBER'));
  AssertEquals('', SetField(F, 'DISCNUMBER', '2'));
  AssertEquals('2', Field(F, 'DISCNUMBER'));
  After := Bytes(F);
  AssertTrue('The track as its bytes',
    Pos(Box('trkn', Box('data', BE32(0) + BE32(0) + BE16(0) + BE16(7) + BE16(12) + BE16(0))), After) > 0);
  AssertTrue('The disc as its bytes',
    Pos(Box('disk', Box('data', BE32(0) + BE32(0) + BE16(0) + BE16(2) + BE16(0))), After) > 0);

  // a field the format has no entry for: free-form, ReplayGain in small letters
  AssertEquals('', SetField(F, 'REPLAYGAIN_TRACK_GAIN', '-3.25 dB'));
  AssertEquals('', SetField(F, 'MOOD', 'Calm'));
  After := Bytes(F);
  AssertTrue(Pos(FreeItem('replaygain_track_gain', '-3.25 dB'), After) > 0);
  AssertTrue(Pos(FreeItem('MOOD', 'Calm'), After) > 0);
  AssertEquals('-3.25 dB', Field(F, 'REPLAYGAIN_TRACK_GAIN'));
  AssertEquals('Calm', Field(F, 'MOOD'));
  // and changed again it keeps the name it has in the file
  AssertEquals('', SetField(F, 'REPLAYGAIN_TRACK_GAIN', '-4.00 dB'));
  AssertTrue(Pos(FreeItem('replaygain_track_gain', '-4.00 dB'), Bytes(F)) > 0);

  // two artists: two values of one entry
  R := GetFileTagsObject(F);
  try
    Fr := TVorbisFrame.Create('ARTIST');
    Fr.AsString := 'First artist';
    R.Tags.Add(Fr);
    Fr := TVorbisFrame.Create('ARTIST');
    Fr.AsString := 'Second artist';
    R.Tags.Add(Fr);
    AssertTrue(R.UpdateFile);
  finally
    R.Free;
  end;
  R := GetFileTagsObject(F);
  try
    Count := 0;
    for I := 0 to R.Tags.Count - 1 do
      if SameText(R.Tags.Frames[I].ID, 'ARTIST') then
      begin
        if Count = 0 then AssertEquals('First artist', R.Tags.Frames[I].AsString)
        else AssertEquals('Second artist', R.Tags.Frames[I].AsString);
        Inc(Count);
      end;
    AssertEquals('Both artists', 2, Count);
  finally
    R.Free;
  end;
  AssertEquals('7/12', Field(F, 'TRACKNUMBER'));
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.AFieldCanBeRemoved;
var
  O: TMp4Options;
  F: string;
  Flag, Sort, Cover, Artist, After: AnsiString;
begin
  O := Default(TMp4Options);
  O.Tags := RichTags(Flag, Sort, Cover, Artist);
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));
  AssertEquals('', SetField(F, 'ALBUM', ''));
  After := Bytes(F);
  AssertEquals('The album is gone', '', Field(F, 'ALBUM'));
  AssertEquals(0, Pos('The album', After));
  AssertEquals('The title stays', 'The title', Field(F, 'TITLE'));
  AssertTrue('And what no field shows', (Pos(Flag, After) > 0) and (Pos(Sort, After) > 0) and (Pos(Cover, After) > 0));
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.TheCoverIsReplacedAddedAndRemoved;
var
  O: TMp4Options;
  F: string;
  Flag, Sort, Cover, Artist, NewPic: AnsiString;
  R: TTagReader;
  Pic: TImageElement;

  procedure SetCover(const AData: AnsiString);
  begin
    R := GetFileTagsObject(F);
    try
      R.Tags.ClearImages;
      if AData <> '' then
      begin
        Pic := TImageElement.Create;
        Pic.MIMEType := 'image/jpeg';
        Pic.PictureType := 3;
        Pic.Image.WriteBuffer(AData[1], Length(AData));
        Pic.Image.Position := 0;
        R.Tags.AddImage(Pic);
      end;
      AssertTrue('Saved', R.UpdateFile);
    finally
      R.Free;
    end;
  end;

  function CoverOf: AnsiString;
  var
    Rd: TTagReader;
  begin
    Result := '';
    Rd := GetFileTagsObject(F);
    try
      if Rd.Tags.ImageCount > 0 then
      begin
        SetLength(Result, Rd.Tags.Images[0].Image.Size);
        Rd.Tags.Images[0].Image.Position := 0;
        Rd.Tags.Images[0].Image.ReadBuffer(Result[1], Length(Result));
        AssertEquals('image/jpeg', Rd.Tags.Images[0].MIMEType);
      end;
    finally
      Rd.Free;
    end;
  end;

begin
  NewPic := #$FF#$D8#$FF#$E0 + StringOfChar(#3, 2000);
  O := Default(TMp4Options);
  O.Tags := RichTags(Flag, Sort, Cover, Artist);
  F := FDir + 'a.m4a';
  SaveBytes(F, Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O));

  SetCover(NewPic);
  AssertTrue('The new picture', CoverOf = NewPic);
  AssertEquals('The old one is gone', 0, Pos(Cover, Bytes(F)));
  AssertEquals('The title stays', 'The title', Field(F, 'TITLE'));
  AssertTrue('And what no field shows', Pos(Sort, Bytes(F)) > 0);
  CheckSound(F, TAG_FRAMES);

  SetCover('');
  AssertTrue('No picture', CoverOf = '');
  AssertEquals(0, Pos('covr', Bytes(F)));
  CheckSound(F, TAG_FRAMES);

  SetCover(NewPic);
  AssertTrue('A picture for a file that has none', CoverOf = NewPic);
  CheckSound(F, TAG_FRAMES);
end;

procedure TTestM4aTags.AFileOfAnotherEncoderStillDecodesTheSame;
var
  F: string;
  R: TAlacReader;
  D: TBytes;
begin
  // a compressed file, its description behind the sound
  F := FDir + 'a.m4a';
  SaveBytes(F, DecodeStringBase64(ALAC_FIX16_B64));
  AssertEquals('Saved', '', SetField(F, 'TITLE', 'A title for a file that had none'));
  AssertEquals('', SetField(F, 'REPLAYGAIN_TRACK_GAIN', '-1.00 dB'));
  AssertEquals('A title for a file that had none', Field(F, 'TITLE'));
  R := TAlacReader.Create(F);
  try
    D := ReadAll(R, 64 * 1024);
    AssertEquals(5000 * 4, Length(D));
    AssertTrue('Every sample as before', FnvOf(D) = ALAC_FIX16_HASH);
  finally
    R.Free;
  end;

  // and a compressed 24-bit one
  F := FDir + 'b.m4a';
  SaveBytes(F, DecodeStringBase64(ALAC_FIX24_B64));
  AssertEquals('', SetField(F, 'ALBUM', 'An album'));
  R := TAlacReader.Create(F);
  try
    D := ReadAll(R, 64 * 1024);
    AssertTrue('Every sample as before', FnvOf(D) = ALAC_FIX24_HASH);
  finally
    R.Free;
  end;
end;

procedure TTestM4aTags.FilesThatAreNotRewritten;
var
  O: TMp4Options;
  F: string;
  Good, Before: AnsiString;
  R: TTagReader;
begin
  O := Default(TMp4Options);
  O.Tags := TextItem(#$A9'nam', 'The title');
  Good := Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O);
  F := FDir + 'a.m4a';

  // a file in fragments keeps positions a save does not correct
  Before := Good + Box('moof', StringOfChar(#0, 16));
  SaveBytes(F, Before);
  AssertTrue('In fragments: refused', Pos('not saved', SetField(F, 'TITLE', 'New')) = 1);
  AssertTrue('The file is as it was', Bytes(F) = Before);

  // bytes behind the last box
  Before := Good + 'xyz';
  SaveBytes(F, Before);
  AssertTrue('Loose bytes at the end: refused', Pos('not saved', SetField(F, 'TITLE', 'New')) = 1);
  AssertTrue('The file is as it was', Bytes(F) = Before);

  // a tag list with bytes that are no entry
  O.Tags := TextItem(#$A9'nam', 'The title') + 'junk';
  Before := Mp4Bytes(TAG_FRAMES, 2, 16, 44100, O);
  SaveBytes(F, Before);
  AssertTrue('A damaged tag list: refused', Pos('not saved', SetField(F, 'TITLE', 'New')) = 1);
  AssertTrue('The file is as it was', Bytes(F) = Before);

  // read without its pictures: a save would lose them
  SaveBytes(F, Good);
  R := GetFileTagsObject(F, True);
  try
    R.Tags.SetFrameValue('TITLE', 'New', TVorbisFrame);
    AssertFalse('Text only: refused', R.UpdateFile);
  finally
    R.Free;
  end;
  AssertTrue('The file is as it was', Bytes(F) = Good);

  // no temporary file is left behind by a refused save
  AssertFalse(FileExists(FDir + 'a.~..m4a'));
end;

{ TTestPlaybackAlac }

procedure TTestPlaybackAlac.PlaysBitPerfect;
const
  FRAMES = 12 * FRAME_LEN + 1234;
var
  D: TBytes;
  F, C: Integer;
begin
  WriteM4a(FDir + 'a.m4a', FRAMES, 2, 16);
  Play(FDir + 'a.m4a');
  AssertTrue('The thread ends by itself', WaitForEnd(20000));
  CheckNoError;
  AssertEquals('At the rate of the file', 44100, Integer(FRecorder.Opens(0).Rate));
  D := FRecorder.Data;
  AssertTrue('All frames were played', Length(D) >= FRAMES * 8);
  // the 16-bit samples padded to the 32 bits of the device
  for F := 0 to FRAMES - 1 do
    for C := 0 to 1 do
      if PInteger(@D[(F * 2 + C) * 4])^ <> TestSample(F, C, 16) * 65536 then
        Fail(Format('Frame %d, channel %d', [F, C]));
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
end;

initialization
  RegisterTest(TTestAlac);
  RegisterTest(TTestM4aTags);
  RegisterTest(TTestPlaybackAlac);

end.
