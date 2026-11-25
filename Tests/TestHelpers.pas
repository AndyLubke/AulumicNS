unit TestHelpers;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestHelpers
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Small helpers shared by the test units: a temporary folder per test (under
  %TEMP%\AulumicTests, never inside the project or the program's data) and
  reading / writing raw file bytes for the "damaged file" tests.
  =============================================================================}

interface

uses
  Classes, SysUtils;

// A new, empty folder for one test, with a trailing path delimiter
function  CreateTestDir: string;
// Deletes the files in ADir and the folder itself (tests use no subfolders)
procedure RemoveTestDir(const ADir: string);
// Deletes ADir with all its files and subfolders (also hidden
// ones); for tests that build a folder tree
procedure RemoveTestTree(const ADir: string);

function  ReadFileBytes(const APath: string): TBytes;
procedure WriteFileBytes(const APath: string; const ABytes: TBytes);

// Builders for hand-made binary files (little-endian Int32, strings as Int32
// byte length + UTF-8 bytes, the layout uPlaylistFile uses)
procedure StreamWriteInt(AStrm: TStream; AValue: Integer);
procedure StreamWriteStr(AStrm: TStream; const S: string);

// A valid PCM WAV file of AFrames frames of silence (no tags), for scanner
// tests; creates the folder when needed
procedure WriteTestWav(const APath: string; AFrames: Integer = 4410;
  ASampleRate: Integer = 44100; ABits: Integer = 16; AChannels: Integer = 2);

// A PCM WAV file with the sample bytes AData; creates the folder when needed
procedure WriteWavData(const APath: string; ASampleRate, ABits, AChannels: Integer;
  const AData: TBytes);

// A 16-bit stereo PCM WAV file of a sine tone, the same
// in both channels: AFreqHz, peak level APeakDbfs (dB below full scale),
// ASeconds long. EBU Tech 3341 test 1: 1000 Hz at -23 dBFS = -23 LUFS.
procedure WriteToneWav(const APath: string; AFreqHz, APeakDbfs, ASeconds: Double;
  ASampleRate: Integer = 48000);

// The counting pattern of the playback
// tests. Frame N holds N: the left sample the low 15 bits (positive), the
// right sample the next 15 bits complemented (negative, so a wrong sign
// extension shows). In 24 bit the 15 bits sit above a low byte that holds
// more bits of N (left: N and $FF, right: (N shr 8) and $FF), so all 24 bits
// are checked. Every frame is different (up to 2^30 frames): a gap, a doubled
// frame or a jump shows. Two files with AFirstFrame following on make one
// continuous count (gapless).
// The sample of frame AFrame, AChannel (0 = left, 1 = right) in ABits (16 / 24)
function  PatternSample(AFrame, AChannel, ABits: Integer): Integer;
// The frame number of a pattern frame from its two samples (for messages)
function  PatternFrameOf(ALeft, ARight, ABits: Integer): Integer;
// A stereo PCM WAV file (16 or 24 bit) of the pattern
procedure WritePatternWav(const APath: string; AFrames: Integer;
  ASampleRate: Integer = 44100; AFirstFrame: Integer = 0; ABits: Integer = 16);
// A stereo FLAC file (16 or 24 bit) of the pattern,
// written by hand (the program only decodes FLAC): STREAMINFO, then frames
// of ABlockSize samples (the last one shorter) with VERBATIM subframes
// (uncompressed), CRC-8 / CRC-16 as the format asks. No MD5 (zero = not
// checked), no seek table (the decoder seeks by searching the frames).
procedure WritePatternFlac(const APath: string; AFrames: Integer;
  ASampleRate: Integer = 44100; AFirstFrame: Integer = 0; ABits: Integer = 16;
  ABlockSize: Integer = 4096);
// A FLAC file of AChannels independent channels (1 .. 8), written the same
// way; the sample of frame AFrame, AChannel comes from ASample
type
  TChannelSampleFunc = function(AFrame, AChannel, ABits: Integer): Integer;
procedure WriteChannelFlac(const APath: string; AFrames, AChannels: Integer;
  ASample: TChannelSampleFunc; ASampleRate: Integer = 44100; ABits: Integer = 16;
  ABlockSize: Integer = 4096);

type
  // The DSD bytes of a test DSF file
  TDsdPattern = (
    dpCount,     // counting bytes (DoP bit-perfect tests): see DsfPatternByte
    dpSquare     // a square wave of about 1 kHz at DSD64, about half scale
  );

const
  DSF_BLOCK_SIZE = 4096;   // bytes per channel and block (the DSF standard)

// A stereo DSF file (DSD64 = 2822400 Hz by default) of
// ABytesPerChannel DSD bytes per channel, in DSF_BLOCK_SIZE blocks per channel
// (the last block padded with DSD silence $69); byte J of a channel is
// DsfPatternByte(AFirstByte + J, ...).
procedure WriteTestDsf(const APath: string; ABytesPerChannel: Integer;
  APattern: TDsdPattern = dpCount; AFirstByte: Integer = 0; ADsdRate: Integer = 2822400);
// Byte AIndex of channel AChannel (0 / 1) as the file stores it (LSB first)
// The same DSD as WriteTestDsf in a DSDIFF (.dff) file: MSB
// first, the channels interleaved byte by byte, no padding after the end
// (a DFF file has no blocks), so it plays exactly like the DSF file
procedure WriteTestDff(const APath: string; ABytesPerChannel: Integer;
  APattern: TDsdPattern = dpCount; AFirstByte: Integer = 0; ADsdRate: Integer = 2822400);
function  DsfPatternByte(AIndex, AChannel: Integer; APattern: TDsdPattern): Byte;
// The byte with its bits in reverse order (DSF stores LSB first, DoP MSB first)
function  ReverseBits(AByte: Byte): Byte;

// Adds an 'id3 ' chunk (an ID3v2.3 tag) to a WAV file
// of WriteTestWav. AFrames: frame ID and text in pairs, e.g. ['TIT2', 'Title',
// 'TPE1', 'Artist'] (plain ASCII text)
procedure AddWavId3Tag(const APath: string; const AFrames: array of string);

const
  // The lengths of NonAsciiName
  NON_ASCII_UTF8_BYTES  = 28;   // bytes in UTF-8
  NON_ASCII_UTF16_CHARS = 17;   // UTF-16 code units (the emoji counts 2)

// A file name part (UTF-8) with characters outside ASCII: accented
// Latin letters (2 UTF-8 bytes each), Japanese (3 bytes each) and an emoji
// outside the Basic Multilingual Plane (4 bytes; a UTF-16 surrogate pair):
// 'Café Müßig 日本語 🎵'. Built from the code points, so it does not depend
// on how the compiler reads this source file.
function NonAsciiName: string;

implementation

uses
  Math;

var
  DirCounter: Integer = 0;

function CreateTestDir: string;
begin
  Inc(DirCounter);
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'AulumicTests' + PathDelim +
            Format('%d_%d', [GetProcessID, DirCounter]) + PathDelim;
  if DirectoryExists(Result) then
    RemoveTestDir(Result);
  if not ForceDirectories(Result) then
    raise Exception.CreateFmt('Cannot create the test folder %s', [Result]);
end;

procedure RemoveTestDir(const ADir: string);
var
  SR  : TSearchRec;
  Dir : string;
begin
  if ADir = '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
          DeleteFile(Dir + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(Dir);
end;

procedure RemoveTestTree(const ADir: string);
var
  SR  : TSearchRec;
  Dir : string;
begin
  if ADir = '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) <> 0 then
          RemoveTestTree(Dir + SR.Name)
        else
        begin
          FileSetAttr(Dir + SR.Name, 0);
          DeleteFile(Dir + SR.Name);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  FileSetAttr(ExcludeTrailingPathDelimiter(Dir), 0);
  RemoveDir(Dir);
end;

function ReadFileBytes(const APath: string): TBytes;
var
  FS: TFileStream;
begin
  Result := nil;
  // Also a file another handle writes (a library journal)
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[0], FS.Size);
  finally
    FS.Free;
  end;
end;

procedure WriteFileBytes(const APath: string; const ABytes: TBytes);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      FS.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    FS.Free;
  end;
end;

procedure StreamWriteInt(AStrm: TStream; AValue: Integer);
begin
  AStrm.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure StreamWriteStr(AStrm: TStream; const S: string);
var
  L: Integer;
begin
  L := Length(S);
  AStrm.WriteBuffer(L, SizeOf(L));
  if L > 0 then
    AStrm.WriteBuffer(S[1], L);
end;

// A PCM WAV file with the sample bytes AData; creates the folder when needed
procedure WriteWavData(const APath: string; ASampleRate, ABits, AChannels: Integer;
  const AData: TBytes);
var
  FS: TFileStream;
  BlockAlign, DataSize: Integer;
  W: Word;

  procedure Tag(const S: AnsiString);
  begin
    FS.WriteBuffer(S[1], 4);
  end;

  procedure Int32(AValue: Integer);
  begin
    FS.WriteBuffer(AValue, 4);
  end;

begin
  ForceDirectories(ExtractFileDir(APath));
  BlockAlign := AChannels * (ABits div 8);
  DataSize   := Length(AData);

  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('RIFF');
    Int32(36 + DataSize);
    Tag('WAVE');
    Tag('fmt ');
    Int32(16);
    W := 1;            FS.WriteBuffer(W, 2);   // PCM
    W := AChannels;    FS.WriteBuffer(W, 2);
    Int32(ASampleRate);
    Int32(ASampleRate * BlockAlign);
    W := BlockAlign;   FS.WriteBuffer(W, 2);
    W := ABits;        FS.WriteBuffer(W, 2);
    Tag('data');
    Int32(DataSize);
    if DataSize > 0 then
      FS.WriteBuffer(AData[0], DataSize);
  finally
    FS.Free;
  end;
end;

procedure WriteTestWav(const APath: string; AFrames: Integer; ASampleRate: Integer;
  ABits: Integer; AChannels: Integer);
var
  Silence: TBytes;
begin
  Silence := nil;
  SetLength(Silence, AFrames * AChannels * (ABits div 8));
  if Length(Silence) > 0 then
    FillChar(Silence[0], Length(Silence), 0);
  WriteWavData(APath, ASampleRate, ABits, AChannels, Silence);
end;

procedure WriteToneWav(const APath: string; AFreqHz, APeakDbfs, ASeconds: Double;
  ASampleRate: Integer);
var
  Data: TBytes;
  Frames, N: Integer;
  Amp: Double;
  S: SmallInt;
begin
  Frames := Round(ASeconds * ASampleRate);
  Amp    := Power(10.0, APeakDbfs / 20.0) * 32767.0;
  Data   := nil;
  SetLength(Data, Frames * 4);  // 16-bit stereo
  for N := 0 to Frames - 1 do
  begin
    S := SmallInt(Round(Amp * Sin(2.0 * Pi * AFreqHz * N / ASampleRate)));
    Move(S, Data[N * 4], 2);      // left
    Move(S, Data[N * 4 + 2], 2);  // right
  end;
  WriteWavData(APath, ASampleRate, 16, 2, Data);
end;

function PatternSample(AFrame, AChannel, ABits: Integer): Integer;
var
  Lo, Hi: Integer;
begin
  Lo := AFrame and $7FFF;
  Hi := (AFrame shr 15) and $7FFF;
  if ABits = 24 then
  begin
    if AChannel = 0 then
      Result := (Lo shl 8) or (AFrame and $FF)
    else
      Result := not ((Hi shl 8) or ((AFrame shr 8) and $FF));
  end
  else
  begin
    if AChannel = 0 then
      Result := Lo
    else
      Result := not Hi;
  end;
end;

function PatternFrameOf(ALeft, ARight, ABits: Integer): Integer;
begin
  if ABits = 24 then
    Result := ((ALeft shr 8) and $7FFF) or ((((not ARight) shr 8) and $7FFF) shl 15)
  else
    Result := (ALeft and $7FFF) or (((not ARight) and $7FFF) shl 15);
end;

procedure WritePatternWav(const APath: string; AFrames: Integer;
  ASampleRate: Integer; AFirstFrame: Integer; ABits: Integer);
var
  Data: TBytes;
  I, Ch, S, Bytes, P: Integer;
begin
  Bytes := ABits div 8;
  Data  := nil;
  SetLength(Data, AFrames * 2 * Bytes);
  P := 0;
  for I := 0 to AFrames - 1 do
    for Ch := 0 to 1 do
    begin
      S := PatternSample(AFirstFrame + I, Ch, ABits);
      Data[P]     := Byte(S);
      Data[P + 1] := Byte(S shr 8);
      if Bytes = 3 then
        Data[P + 2] := Byte(S shr 16);
      Inc(P, Bytes);
    end;
  WriteWavData(APath, ASampleRate, ABits, 2, Data);
end;

// ---------------------------------------------------------------------------
// FLAC writer
// ---------------------------------------------------------------------------

type
  // Collects bits MSB first into bytes
  TBitWriter = class
  private
    FData  : TBytes;
    FLen   : Integer;
    FAcc   : Integer;
    FNBits : Integer;
    procedure AddByte(AValue: Byte);
  public
    procedure Put(AValue: QWord; ACount: Integer);
    procedure PutBytes(const ABytes: TBytes);
    procedure Clear;
    function  Bytes: TBytes;   // the whole bytes so far (a copy)
    property  Len: Integer read FLen;
  end;

procedure TBitWriter.AddByte(AValue: Byte);
begin
  if FLen >= Length(FData) then
    SetLength(FData, FLen * 2 + 1024);
  FData[FLen] := AValue;
  Inc(FLen);
end;

procedure TBitWriter.Put(AValue: QWord; ACount: Integer);
var
  I: Integer;
begin
  for I := ACount - 1 downto 0 do
  begin
    FAcc := (FAcc shl 1) or Integer((AValue shr I) and 1);
    Inc(FNBits);
    if FNBits = 8 then
    begin
      AddByte(Byte(FAcc));
      FAcc   := 0;
      FNBits := 0;
    end;
  end;
end;

procedure TBitWriter.PutBytes(const ABytes: TBytes);
var
  I: Integer;
begin
  for I := 0 to High(ABytes) do
    Put(ABytes[I], 8);
end;

procedure TBitWriter.Clear;
begin
  FLen   := 0;
  FAcc   := 0;
  FNBits := 0;
end;

function TBitWriter.Bytes: TBytes;
begin
  Result := nil;
  SetLength(Result, FLen);
  if FLen > 0 then
    Move(FData[0], Result[0], FLen);
end;

// CRC-8 of the frame header (polynomial x^8 + x^2 + x + 1, start 0)
function FlacCrc8(const AData: TBytes; ACount: Integer): Byte;
var
  I, K: Integer;
  C: Byte;
begin
  C := 0;
  for I := 0 to ACount - 1 do
  begin
    C := C xor AData[I];
    for K := 1 to 8 do
      if (C and $80) <> 0 then
        C := Byte((C shl 1) xor $07)
      else
        C := Byte(C shl 1);
  end;
  Result := C;
end;

// CRC-16 of the whole frame (polynomial x^16 + x^15 + x^2 + 1, start 0)
function FlacCrc16(const AData: TBytes; ACount: Integer): Word;
var
  I, K: Integer;
  C: Word;
begin
  C := 0;
  for I := 0 to ACount - 1 do
  begin
    C := C xor (Word(AData[I]) shl 8);
    for K := 1 to 8 do
      if (C and $8000) <> 0 then
        C := Word((C shl 1) xor $8005)
      else
        C := Word(C shl 1);
  end;
  Result := C;
end;

// The frame number in FLAC's "UTF-8" coding (up to 2^21 - 1 here)
procedure PutFlacNumber(W: TBitWriter; AValue: Cardinal);
begin
  if AValue < $80 then
    W.Put(AValue, 8)
  else if AValue < $800 then
  begin
    W.Put($C0 or (AValue shr 6), 8);
    W.Put($80 or (AValue and $3F), 8);
  end
  else if AValue < $10000 then
  begin
    W.Put($E0 or (AValue shr 12), 8);
    W.Put($80 or ((AValue shr 6) and $3F), 8);
    W.Put($80 or (AValue and $3F), 8);
  end
  else
  begin
    W.Put($F0 or (AValue shr 18), 8);
    W.Put($80 or ((AValue shr 12) and $3F), 8);
    W.Put($80 or ((AValue shr 6) and $3F), 8);
    W.Put($80 or (AValue and $3F), 8);
  end;
end;

procedure WritePatternFlac(const APath: string; AFrames: Integer;
  ASampleRate: Integer; AFirstFrame: Integer; ABits: Integer; ABlockSize: Integer);
var
  FS: TFileStream;
  W: TBitWriter;
  Frame: TBytes;
  FrameNo, First, Count, I, Ch: Integer;
  Mask: QWord;
begin
  ForceDirectories(ExtractFileDir(APath));
  Mask := (QWord(1) shl ABits) - 1;

  FS := TFileStream.Create(APath, fmCreate);
  W  := TBitWriter.Create;
  try
    // "fLaC" and the STREAMINFO block (the last metadata block)
    W.Put(Ord('f'), 8); W.Put(Ord('L'), 8); W.Put(Ord('a'), 8); W.Put(Ord('C'), 8);
    W.Put(1, 1);                       // last metadata block
    W.Put(0, 7);                       // STREAMINFO
    W.Put(34, 24);                     // its length
    W.Put(ABlockSize, 16);             // min block size
    W.Put(ABlockSize, 16);             // max block size
    W.Put(0, 24);                      // min frame size: unknown
    W.Put(0, 24);                      // max frame size: unknown
    W.Put(ASampleRate, 20);
    W.Put(2 - 1, 3);                   // channels - 1
    W.Put(ABits - 1, 5);               // bits per sample - 1
    W.Put(AFrames, 36);                // total samples (per channel)
    for I := 1 to 16 do
      W.Put(0, 8);                     // MD5: zero = not known
    Frame := W.Bytes;
    FS.WriteBuffer(Frame[0], Length(Frame));

    FrameNo := 0;
    First   := 0;
    while First < AFrames do
    begin
      Count := ABlockSize;
      if First + Count > AFrames then
        Count := AFrames - First;

      W.Clear;
      // Frame header
      W.Put($3FFE, 14);                // sync
      W.Put(0, 1);                     // reserved
      W.Put(0, 1);                     // fixed block size
      W.Put(7, 4);                     // block size: 16 bits (size - 1) at the end
      W.Put(0, 4);                     // sample rate: from STREAMINFO
      W.Put(1, 4);                     // two independent channels (left, right)
      if ABits = 24 then
        W.Put(6, 3)                    // 24 bits per sample
      else
        W.Put(4, 3);                   // 16 bits per sample
      W.Put(0, 1);                     // reserved
      PutFlacNumber(W, FrameNo);
      W.Put(Count - 1, 16);
      Frame := W.Bytes;
      W.Put(FlacCrc8(Frame, Length(Frame)), 8);

      // One VERBATIM subframe per channel
      for Ch := 0 to 1 do
      begin
        W.Put(0, 1);                   // zero bit
        W.Put(1, 6);                   // VERBATIM
        W.Put(0, 1);                   // no wasted bits
        for I := 0 to Count - 1 do
          W.Put(QWord(Int64(PatternSample(AFirstFrame + First + I, Ch, ABits))) and Mask, ABits);
      end;

      // Byte aligned already (8-bit subframe headers, 16 / 24-bit samples)
      Frame := W.Bytes;
      W.Put(FlacCrc16(Frame, Length(Frame)), 16);
      Frame := W.Bytes;
      FS.WriteBuffer(Frame[0], Length(Frame));

      Inc(FrameNo);
      Inc(First, Count);
    end;
  finally
    W.Free;
    FS.Free;
  end;
end;

procedure WriteChannelFlac(const APath: string; AFrames, AChannels: Integer;
  ASample: TChannelSampleFunc; ASampleRate: Integer; ABits: Integer; ABlockSize: Integer);
var
  FS: TFileStream;
  W: TBitWriter;
  Frame: TBytes;
  FrameNo, First, Count, I, Ch: Integer;
  Mask: QWord;
begin
  ForceDirectories(ExtractFileDir(APath));
  Mask := (QWord(1) shl ABits) - 1;

  FS := TFileStream.Create(APath, fmCreate);
  W  := TBitWriter.Create;
  try
    // "fLaC" and the STREAMINFO block (the last metadata block)
    W.Put(Ord('f'), 8); W.Put(Ord('L'), 8); W.Put(Ord('a'), 8); W.Put(Ord('C'), 8);
    W.Put(1, 1);                       // last metadata block
    W.Put(0, 7);                       // STREAMINFO
    W.Put(34, 24);                     // its length
    W.Put(ABlockSize, 16);             // min block size
    W.Put(ABlockSize, 16);             // max block size
    W.Put(0, 24);                      // min frame size: unknown
    W.Put(0, 24);                      // max frame size: unknown
    W.Put(ASampleRate, 20);
    W.Put(AChannels - 1, 3);           // channels - 1
    W.Put(ABits - 1, 5);               // bits per sample - 1
    W.Put(AFrames, 36);                // total samples (per channel)
    for I := 1 to 16 do
      W.Put(0, 8);                     // MD5: zero = not known
    Frame := W.Bytes;
    FS.WriteBuffer(Frame[0], Length(Frame));

    FrameNo := 0;
    First   := 0;
    while First < AFrames do
    begin
      Count := ABlockSize;
      if First + Count > AFrames then
        Count := AFrames - First;

      W.Clear;
      // Frame header
      W.Put($3FFE, 14);                // sync
      W.Put(0, 1);                     // reserved
      W.Put(0, 1);                     // fixed block size
      W.Put(7, 4);                     // block size: 16 bits (size - 1) at the end
      W.Put(0, 4);                     // sample rate: from STREAMINFO
      W.Put(AChannels - 1, 4);         // independent channels
      if ABits = 24 then
        W.Put(6, 3)                    // 24 bits per sample
      else
        W.Put(4, 3);                   // 16 bits per sample
      W.Put(0, 1);                     // reserved
      PutFlacNumber(W, FrameNo);
      W.Put(Count - 1, 16);
      Frame := W.Bytes;
      W.Put(FlacCrc8(Frame, Length(Frame)), 8);

      // One VERBATIM subframe per channel
      for Ch := 0 to AChannels - 1 do
      begin
        W.Put(0, 1);                   // zero bit
        W.Put(1, 6);                   // VERBATIM
        W.Put(0, 1);                   // no wasted bits
        for I := 0 to Count - 1 do
          W.Put(QWord(Int64(ASample(First + I, Ch, ABits))) and Mask, ABits);
      end;

      // Byte aligned already (8-bit subframe headers, 16 / 24-bit samples)
      Frame := W.Bytes;
      W.Put(FlacCrc16(Frame, Length(Frame)), 16);
      Frame := W.Bytes;
      FS.WriteBuffer(Frame[0], Length(Frame));

      Inc(FrameNo);
      Inc(First, Count);
    end;
  finally
    W.Free;
    FS.Free;
  end;
end;

// ---------------------------------------------------------------------------
// DSF writer
// ---------------------------------------------------------------------------

function ReverseBits(AByte: Byte): Byte;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 7 do
    if (AByte and (1 shl I)) <> 0 then
      Result := Result or Byte(1 shl (7 - I));
end;

function DsfPatternByte(AIndex, AChannel: Integer; APattern: TDsdPattern): Byte;
begin
  case APattern of
    dpSquare:
      // 176 bytes = 1408 DSD64 bits up, 176 down: about 1002 Hz. $EE / $11
      // (six or two of eight bits set) is about half scale, far from overload
      if ((AIndex div 176) and 1) = 0 then
        Result := $EE
      else
        Result := $11;
  else
    // Counting: the left byte the low 8 bits of the index, the right byte
    // the next 8 (inverted, so the two channels differ)
    if AChannel = 0 then
      Result := Byte(AIndex)
    else
      Result := Byte(not (AIndex shr 8));
  end;
end;

procedure WriteTestDsf(const APath: string; ABytesPerChannel: Integer;
  APattern: TDsdPattern; AFirstByte: Integer; ADsdRate: Integer);
const
  HEADER_SIZE = 28 + 52 + 12;   // 'DSD ', 'fmt ' and the 'data' chunk header
var
  FS: TFileStream;
  Blocks, B, Ch, I, Index: Integer;
  Block: TBytes;
  DataSize, FileSize: Int64;

  procedure Tag(const S: AnsiString);
  begin
    FS.WriteBuffer(S[1], 4);
  end;

  procedure Int32(AValue: Integer);
  begin
    FS.WriteBuffer(AValue, 4);
  end;

  procedure Int64W(AValue: Int64);
  begin
    FS.WriteBuffer(AValue, 8);
  end;

begin
  ForceDirectories(ExtractFileDir(APath));
  Blocks   := (ABytesPerChannel + DSF_BLOCK_SIZE - 1) div DSF_BLOCK_SIZE;
  DataSize := Int64(Blocks) * DSF_BLOCK_SIZE * 2;
  FileSize := HEADER_SIZE + DataSize;
  Block    := nil;
  SetLength(Block, DSF_BLOCK_SIZE);

  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('DSD ');
    Int64W(28);                        // chunk size
    Int64W(FileSize);
    Int64W(0);                         // no metadata chunk
    Tag('fmt ');
    Int64W(52);
    Int32(1);                          // format version
    Int32(0);                          // DSD raw
    Int32(2);                          // channel type: stereo
    Int32(2);                          // channels
    Int32(ADsdRate);
    Int32(1);                          // bits per sample: 1 = LSB first
    Int64W(Int64(ABytesPerChannel) * 8);  // samples (bits) per channel
    Int32(DSF_BLOCK_SIZE);
    Int32(0);                          // reserved
    Tag('data');
    Int64W(12 + DataSize);

    // Per block: the left channel's block, then the right channel's
    for B := 0 to Blocks - 1 do
      for Ch := 0 to 1 do
      begin
        for I := 0 to DSF_BLOCK_SIZE - 1 do
        begin
          Index := B * DSF_BLOCK_SIZE + I;
          if Index < ABytesPerChannel then
            Block[I] := DsfPatternByte(AFirstByte + Index, Ch, APattern)
          else
            Block[I] := $69;           // DSD silence after the end
        end;
        FS.WriteBuffer(Block[0], DSF_BLOCK_SIZE);
      end;
  finally
    FS.Free;
  end;
end;

procedure WriteTestDff(const APath: string; ABytesPerChannel: Integer;
  APattern: TDsdPattern; AFirstByte: Integer; ADsdRate: Integer);
var
  FS: TFileStream;
  Data: TBytes;
  I: Integer;
  DataSize, PropSize: Int64;

  procedure Tag(const S: AnsiString);
  begin
    FS.WriteBuffer(S[1], 4);
  end;

  procedure U16(AValue: Word);
  var
    B: array[0..1] of Byte;
  begin
    B[0] := Byte(AValue shr 8);
    B[1] := Byte(AValue);
    FS.WriteBuffer(B, 2);
  end;

  procedure U32(AValue: Cardinal);
  var
    B: array[0..3] of Byte;
  begin
    B[0] := Byte(AValue shr 24);
    B[1] := Byte(AValue shr 16);
    B[2] := Byte(AValue shr 8);
    B[3] := Byte(AValue);
    FS.WriteBuffer(B, 4);
  end;

  procedure U64(AValue: Int64);
  begin
    U32(Cardinal(AValue shr 32));
    U32(Cardinal(AValue and $FFFFFFFF));
  end;

const
  CMPR_NAME: AnsiString = 'not compressed';   // 14 characters
begin
  ForceDirectories(ExtractFileDir(APath));
  DataSize := Int64(ABytesPerChannel) * 2;
  Data := nil;
  SetLength(Data, DataSize);
  for I := 0 to ABytesPerChannel - 1 do
  begin
    // DSF stores the bits LSB first, DFF MSB first
    Data[2 * I] := ReverseBits(DsfPatternByte(AFirstByte + I, 0, APattern));
    Data[2 * I + 1] := ReverseBits(DsfPatternByte(AFirstByte + I, 1, APattern));
  end;
  // PROP: 'SND ', FS (12 + 4), CHNL (12 + 2 + 8), CMPR (12 + 4 + 1 + 14, + 1 pad)
  PropSize := 4 + (12 + 4) + (12 + 10) + (12 + 20);
  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('FRM8');
    U64(4 + (12 + 4) + (12 + PropSize) + (12 + DataSize));
    Tag('DSD ');
    Tag('FVER');
    U64(4);
    U32($01050000);
    Tag('PROP');
    U64(PropSize);
    Tag('SND ');
    Tag('FS  ');
    U64(4);
    U32(Cardinal(ADsdRate));
    Tag('CHNL');
    U64(10);
    U16(2);
    Tag('SLFT');
    Tag('SRGT');
    Tag('CMPR');
    U64(19);
    Tag('DSD ');
    FS.WriteByte(Length(CMPR_NAME));
    FS.WriteBuffer(CMPR_NAME[1], Length(CMPR_NAME));
    FS.WriteByte(0);                   // pad to an even size
    Tag('DSD ');
    U64(DataSize);
    if DataSize > 0 then FS.WriteBuffer(Data[0], DataSize);
  finally
    FS.Free;
  end;
end;

procedure AddWavId3Tag(const APath: string; const AFrames: array of string);
var
  Frames: TMemoryStream;
  FS: TFileStream;
  I: Integer;
  Size: LongWord;
  Text: AnsiString;

  procedure Bytes(AStrm: TStream; const AValues: array of Byte);
  var
    K: Integer;
    B: Byte;
  begin
    for K := 0 to High(AValues) do
    begin
      B := AValues[K];
      AStrm.WriteBuffer(B, 1);
    end;
  end;

  procedure Chars(AStrm: TStream; const S: AnsiString);
  begin
    if Length(S) > 0 then
      AStrm.WriteBuffer(S[1], Length(S));
  end;

begin
  // The frames: ID, size (big-endian, without the 10-byte frame header),
  // 2 flag bytes, encoding 0 (ISO-8859-1), the text
  Frames := TMemoryStream.Create;
  try
    I := 0;
    while I < High(AFrames) do
    begin
      Text := AFrames[I + 1];
      Size := Length(Text) + 1;
      Chars(Frames, AFrames[I]);
      Bytes(Frames, [Byte(Size shr 24), Byte(Size shr 16), Byte(Size shr 8), Byte(Size), 0, 0, 0]);
      Chars(Frames, Text);
      Inc(I, 2);
    end;

    FS := TFileStream.Create(APath, fmOpenReadWrite);
    try
      FS.Seek(0, soEnd);
      // The chunk: 'id3 ', its size (little-endian), the tag (header with a
      // syncsafe size, the frames), a pad byte to an even size
      Size := 10 + Frames.Size;
      Chars(FS, 'id3 ');
      FS.WriteBuffer(Size, 4);
      Chars(FS, 'ID3');
      Bytes(FS, [3, 0, 0,
        Byte((Frames.Size shr 21) and $7F), Byte((Frames.Size shr 14) and $7F),
        Byte((Frames.Size shr 7) and $7F), Byte(Frames.Size and $7F)]);
      Frames.Position := 0;
      FS.CopyFrom(Frames, Frames.Size);
      if Odd(Size) then
        Bytes(FS, [0]);

      // The RIFF size: the whole file after its first 8 bytes
      Size := FS.Size - 8;
      FS.Position := 4;
      FS.WriteBuffer(Size, 4);
    finally
      FS.Free;
    end;
  finally
    Frames.Free;
  end;
end;

function NonAsciiName: string;
var
  W: UnicodeString;
begin
  W := 'Caf' + WideChar($00E9) + ' M' + WideChar($00FC) + WideChar($00DF) + 'ig ' +
       WideChar($65E5) + WideChar($672C) + WideChar($8A9E) + ' ' +
       WideChar($D83C) + WideChar($DFB5);   // U+1F3B5 (musical note)
  Result := UTF8Encode(W);
end;

end.
