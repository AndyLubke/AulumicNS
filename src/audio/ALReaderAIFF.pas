unit ALReaderAIFF;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALReaderAIFF
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Used by ALReaders to read AIFF and AIFF-C files (.aif, .aiff, .aifc).
  The samples come out as the engine takes them from every PCM reader:
  interleaved, little-endian, 16, 24 or 32 bit signed.

  An AIFF file stores its samples big-endian; AIFF-C names how they are
  stored: 'NONE', 'twos', 'in24', 'in32' (big-endian), 'sowt' (little-endian),
  'fl32' and 'fl64' (floating point, converted to 32 bit). Compressed kinds
  (ima4, ulaw, alaw ...) are refused. 8-bit files are widened to 16 bit, and a
  sample size that does not fill its bytes (20 bit in 3 bytes) is read with
  its bytes: the format keeps such samples at the top.
  The file name is UTF-8 (opened as it is, no conversion).
==============================================================================}

interface

uses
  SysUtils, Classes,
  AuAudioTypes;  // LongPath (paths of 260 characters and more)

type
  // How the samples lie in the file
  TAiffSampleKind = (askBigEndian, askLittleEndian, askFloat32, askFloat64);

  TAiffReader = class
  private
    FFileStream: TStream;
    FDataStart: int64;
    FDataSize: int64;        // of the output, in bytes
    FBytesRead: int64;       // of the output
    FSampleRate: cardinal;
    FChannels: word;
    FBitsPerSample: word;    // of the output
    FKind: TAiffSampleKind;
    FInBytes: integer;       // bytes of one sample in the file
    FOutBytes: integer;      // and in the output
    FTemp: array of byte;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;

    function ReadData(Buffer: Pointer; Count: integer): integer;
    function GetProgress: double;
    procedure Seek(Percent: double);

    property SampleRate: cardinal read FSampleRate;
    property Channels: word read FChannels;
    property BitsPerSample: word read FBitsPerSample;
    property DataSize: int64 read FDataSize;
  end;

// The sample rate of a COMM chunk: ten bytes, an 80-bit extended number,
// big-endian. 0 when it is not a usable rate.
function AiffRateFromExtended(const ABytes: array of byte): cardinal;

implementation

uses uAppStrings, Math;

const
  TEMP_FRAMES = 4096;
  // more channels than any file has: a damaged count would size the buffer
  MAX_AIFF_CHANNELS = 64;

function AiffRateFromExtended(const ABytes: array of byte): cardinal;
var
  Exponent, I: integer;
  Mantissa: QWord;
  Value: double;
begin
  Result := 0;
  if Length(ABytes) < 10 then
    Exit;
  if (ABytes[0] and $80) <> 0 then
    Exit;                                       // negative
  Exponent := ((ABytes[0] and $7F) shl 8) or ABytes[1];
  Mantissa := 0;
  for I := 2 to 9 do
    Mantissa := (Mantissa shl 8) or ABytes[I];
  if (Exponent = 0) or (Exponent = $7FFF) or (Mantissa = 0) then
    Exit;
  // the mantissa has its point behind the first bit
  Value := Mantissa * Power(2.0, Exponent - 16383 - 63);
  if (Value >= 1.0) and (Value <= 4000000.0) then
    Result := Round(Value);
end;

function ReadBE32(AStream: TStream; out AValue: cardinal): boolean;
var
  B: array[0..3] of byte;
begin
  AValue := 0;
  Result := AStream.Read(B, 4) = 4;
  if Result then
    AValue := (cardinal(B[0]) shl 24) or (cardinal(B[1]) shl 16) or (cardinal(B[2]) shl 8) or B[3];
end;

constructor TAiffReader.Create(const FileName: string);
type
  TFourCC = array[0..3] of ansichar;
var
  ChunkID, FormType, Compression: TFourCC;
  ChunkSize, FormSize, Frames, Offset, BlockSize: cardinal;
  Comm: array[0..17] of byte;
  FileSizeCached, ChunkStart, ChunkEnd, SoundBytes: int64;
  HasComm, HasSound, IsAifc: boolean;
  SampleSize, InFrame: integer;
  C: string;
begin
  inherited Create;

  ChunkID     := Default(TFourCC);
  FormType    := Default(TFourCC);
  Compression := 'NONE';
  HasComm     := False;
  HasSound    := False;
  Frames      := 0;
  SampleSize  := 0;
  SoundBytes  := 0;

  if not AuFileExists(FileName) then
    raise Exception.Create(ERR_FILE_NOT_FOUND + ' ' + FileName);

  FFileStream    := AuOpenFile(FileName, fmOpenRead or fmShareDenyWrite);
  FileSizeCached := FFileStream.Size;

  FFileStream.ReadBuffer(ChunkID, 4);
  if not ReadBE32(FFileStream, FormSize) then
    raise Exception.Create(ERR_DECODE_NOTAIFF);
  FFileStream.ReadBuffer(FormType, 4);
  if (ChunkID <> 'FORM') or ((FormType <> 'AIFF') and (FormType <> 'AIFC')) then
    raise Exception.Create(ERR_DECODE_NOTAIFF);
  IsAifc := FormType = 'AIFC';

  // The chunks may come in any order: the sound data before its description
  while FFileStream.Position + 8 <= FileSizeCached do
  begin
    if FFileStream.Read(ChunkID, 4) < 4 then
      Break;
    if not ReadBE32(FFileStream, ChunkSize) then
      Break;
    ChunkStart := FFileStream.Position;
    ChunkEnd   := ChunkStart + ChunkSize;

    if ChunkID = 'COMM' then
    begin
      if (ChunkSize < 18) or (FFileStream.Read(Comm, 18) < 18) then
        raise Exception.Create(ERR_DECODE_AIFFINVALID);
      FChannels   := (word(Comm[0]) shl 8) or Comm[1];
      Frames      := (cardinal(Comm[2]) shl 24) or (cardinal(Comm[3]) shl 16) or
                     (cardinal(Comm[4]) shl 8) or Comm[5];
      SampleSize  := (integer(Comm[6]) shl 8) or Comm[7];
      FSampleRate := AiffRateFromExtended(Comm[8..17]);
      if IsAifc and (ChunkSize >= 22) then
        FFileStream.ReadBuffer(Compression, 4);
      HasComm := True;
    end
    else if ChunkID = 'SSND' then
    begin
      if (ChunkSize < 8) or (not ReadBE32(FFileStream, Offset)) or
         (not ReadBE32(FFileStream, BlockSize)) then
        raise Exception.Create(ERR_DECODE_AIFFINVALID);
      FDataStart := FFileStream.Position + Offset;
      SoundBytes := Int64(ChunkSize) - 8 - Offset;
      // A size that reaches beyond the file: what is there
      if FDataStart + SoundBytes > FileSizeCached then
        SoundBytes := FileSizeCached - FDataStart;
      HasSound := True;
    end;

    // Chunks are padded to an even length
    if (ChunkSize and 1) <> 0 then
      Inc(ChunkEnd);
    if (ChunkEnd <= ChunkStart) and (ChunkSize > 0) then
      Break;
    if ChunkEnd > FileSizeCached then
      Break;
    FFileStream.Position := ChunkEnd;
  end;

  if (not HasComm) or (not HasSound) or (FChannels < 1) or (FChannels > MAX_AIFF_CHANNELS) or (FSampleRate = 0) or
     (SampleSize < 1) or (SampleSize > 64) or (SoundBytes <= 0) then
    raise Exception.Create(ERR_DECODE_AIFFINVALID);

  // How the samples are stored
  C := LowerCase(string(Compression));
  FInBytes := (SampleSize + 7) div 8;
  if (C = 'none') or (C = 'twos') or (C = 'in24') or (C = 'in32') then
    FKind := askBigEndian
  else if C = 'sowt' then
    FKind := askLittleEndian
  else if C = 'fl32' then
  begin
    FKind    := askFloat32;
    FInBytes := 4;
  end
  else if C = 'fl64' then
  begin
    FKind    := askFloat64;
    FInBytes := 8;
  end
  else
    raise Exception.Create(ERR_DECODE_AIFF_COMPRESSED);

  case FKind of
    askFloat32, askFloat64:
      FOutBytes := 4;
  else
    begin
      if (FInBytes < 1) or (FInBytes > 4) then
        raise Exception.Create(ERR_DECODE_AIFFINVALID);
      // 8 bit is widened: the engine starts at 16
      if FInBytes = 1 then FOutBytes := 2 else FOutBytes := FInBytes;
    end;
  end;
  FBitsPerSample := FOutBytes * 8;

  // The frames the description names, as far as the data reaches
  InFrame := FInBytes * FChannels;
  if (Frames = 0) or (Int64(Frames) * InFrame > SoundBytes) then
    Frames := SoundBytes div InFrame;
  if Frames = 0 then
    raise Exception.Create(ERR_DECODE_AIFFINVALID);
  FDataSize  := Int64(Frames) * FOutBytes * FChannels;
  FBytesRead := 0;

  SetLength(FTemp, TEMP_FRAMES * InFrame);
  FFileStream.Position := FDataStart;
end;

destructor TAiffReader.Destroy;
begin
  if Assigned(FFileStream) then
    FFileStream.Free;
  inherited;
end;

function TAiffReader.ReadData(Buffer: Pointer; Count: integer): integer;
var
  InFrame, OutFrame, FramesWanted, Chunk, Got, Samples, I: integer;
  PIn, POut: pbyte;
  U32: cardinal;
  U64: QWord;
  V: double;
  S16: smallint;
begin
  Result   := 0;
  InFrame  := FInBytes * FChannels;
  OutFrame := FOutBytes * FChannels;
  if (Count <= 0) or (OutFrame <= 0) then
    Exit;

  if FBytesRead + Count > FDataSize then
    Count := FDataSize - FBytesRead;
  FramesWanted := Count div OutFrame;
  POut := pbyte(Buffer);

  while FramesWanted > 0 do
  begin
    Chunk := FramesWanted;
    if Chunk > TEMP_FRAMES then
      Chunk := TEMP_FRAMES;
    Got := FFileStream.Read(FTemp[0], Chunk * InFrame);
    if Got <= 0 then
      Break;
    // A partial frame at the end of a short read goes back
    if (Got mod InFrame) <> 0 then
    begin
      FFileStream.Seek(-(Got mod InFrame), soFromCurrent);
      Got := Got - (Got mod InFrame);
      if Got <= 0 then
        Break;
    end;

    Samples := (Got div InFrame) * FChannels;
    PIn     := @FTemp[0];
    case FKind of
      askLittleEndian:
        if FInBytes = 1 then
          for I := 0 to Samples - 1 do
          begin
            S16 := smallint(shortint(PIn^)) * 256;
            PSmallInt(POut)^ := S16;
            Inc(PIn);
            Inc(POut, 2);
          end
        else
        begin
          Move(PIn^, POut^, Samples * FInBytes);
          Inc(POut, Samples * FInBytes);
        end;
      askBigEndian:
        case FInBytes of
          1: for I := 0 to Samples - 1 do
             begin
               S16 := smallint(shortint(PIn^)) * 256;
               PSmallInt(POut)^ := S16;
               Inc(PIn);
               Inc(POut, 2);
             end;
          2: for I := 0 to Samples - 1 do
             begin
               POut[0] := PIn[1];
               POut[1] := PIn[0];
               Inc(PIn, 2);
               Inc(POut, 2);
             end;
          3: for I := 0 to Samples - 1 do
             begin
               POut[0] := PIn[2];
               POut[1] := PIn[1];
               POut[2] := PIn[0];
               Inc(PIn, 3);
               Inc(POut, 3);
             end;
        else
          for I := 0 to Samples - 1 do
          begin
            POut[0] := PIn[3];
            POut[1] := PIn[2];
            POut[2] := PIn[1];
            POut[3] := PIn[0];
            Inc(PIn, 4);
            Inc(POut, 4);
          end;
        end;
      askFloat32, askFloat64:
        for I := 0 to Samples - 1 do
        begin
          if FKind = askFloat32 then
          begin
            U32 := (cardinal(PIn[0]) shl 24) or (cardinal(PIn[1]) shl 16) or
                   (cardinal(PIn[2]) shl 8) or PIn[3];
            V := PSingle(@U32)^;
            Inc(PIn, 4);
          end
          else
          begin
            U64 := (QWord(PIn[0]) shl 56) or (QWord(PIn[1]) shl 48) or (QWord(PIn[2]) shl 40) or
                   (QWord(PIn[3]) shl 32) or (QWord(PIn[4]) shl 24) or (QWord(PIn[5]) shl 16) or
                   (QWord(PIn[6]) shl 8) or PIn[7];
            V := PDouble(@U64)^;
            Inc(PIn, 8);
          end;
          // -1 .. +1 is full scale
          if IsNan(V) or IsInfinite(V) then
            V := 0.0
          else
            V := V * 2147483647.0;
          if V > 2147483647.0 then
            PInteger(POut)^ := 2147483647
          else if V < -2147483648.0 then
            PInteger(POut)^ := -2147483648
          else
            PInteger(POut)^ := Round(V);
          Inc(POut, 4);
        end;
    end;

    Inc(Result, (Got div InFrame) * OutFrame);
    Dec(FramesWanted, Got div InFrame);
    if Got < Chunk * InFrame then
      Break;
  end;

  Inc(FBytesRead, Result);
end;

procedure TAiffReader.Seek(Percent: double);
var
  Frames, Target: int64;
  OutFrame: integer;
begin
  OutFrame := FOutBytes * FChannels;
  if OutFrame <= 0 then
    Exit;
  Frames := FDataSize div OutFrame;
  Target := Round(EnsureRange(Percent, 0.0, 1.0) * Frames);
  if Target > Frames then
    Target := Frames;
  if Target < 0 then
    Target := 0;
  FBytesRead           := Target * OutFrame;
  FFileStream.Position := FDataStart + Target * FInBytes * FChannels;
end;

function TAiffReader.GetProgress: double;
begin
  if FDataSize <= 0 then
    Result := 0.0
  else
    Result := double(FBytesRead) / double(FDataSize);
  if Result > 1.0 then
    Result := 1.0;
end;

end.
