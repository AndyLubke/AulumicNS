unit ALReaderWAV;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:      Aulumic
  Unit Name:    ALReaderWAV
  Author:       André Lubke
  Date Created: 2025

  Used by ALReaders to read WAV files.
  ---> CHANGED (ObjFPC switch, step 2): ObjFPC like the rest of Aulumic; the
  file name is UTF-8 (opened as it is, no conversion).
==============================================================================}

interface

uses
  SysUtils, Classes,
  AuAudioTypes;  // ---> AulumicNS: LongPath (paths of 260 characters and more)

type
  TWavReader = class
  private
    FFileStream: TFileStream;
    FDataStart: int64;
    FDataSize: int64;
    FBytesRead: int64;

    FSampleRate: cardinal;
    FChannels: word;
    FBitsPerSample: word;
    // ---> AUDIT FIX 2.3: Cached frame size in bytes for whole-frame read alignment
    FBlockAlign: integer;
    // Supports 32-bit IEEE Float WAVs (converted to 32-bit Int PCM)
    FIsFloat: boolean;
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

implementation

uses uAppStrings, Math;

const
  WAV_FORMAT_PCM        = $0001;
  WAV_FORMAT_IEEE_FLOAT = $0003;
  WAV_FORMAT_EXTENSIBLE = $FFFE;

constructor TWavReader.Create(const FileName: string);
type
  TFourCC = array[0..3] of ansichar;
var
  ChunkID: TFourCC;
  ChunkSize: cardinal;
  RiffType: TFourCC;
  AudioFormat, SubFormatTag: word;
  FileSizeCached, SkipBytes: int64;
  HasFmtChunk: boolean;
begin
  inherited Create;

  // ---> AUDIT FIX: Initialize local variables
  ChunkID      := Default(TFourCC);
  ChunkSize    := 0;
  RiffType     := Default(TFourCC);
  AudioFormat  := 0;
  SubFormatTag := 0;
  HasFmtChunk  := False;

  if not FileExists(LongPath(FileName)) then
    raise Exception.Create(ERR_FILE_NOT_FOUND + ' ' + FileName);

  FFileStream    := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyWrite);
  FileSizeCached := FFileStream.Size;
  FBytesRead     := 0;
  FBlockAlign    := 0;
  FIsFloat       := False;

  // 1. Mandatory Headers (ReadBuffer)
  FFileStream.ReadBuffer(ChunkID, 4);
  FFileStream.ReadBuffer(ChunkSize, 4);
  FFileStream.ReadBuffer(RiffType, 4);

  if (ChunkID <> 'RIFF') or (RiffType <> 'WAVE') then
    raise Exception.Create(ERR_DECODE_NOTWAV);

  FSampleRate := 0;
  FDataSize   := 0;
  FDataStart  := 0;

  // Uses cached FileSizeCached instead of querying OS FileSeek per chunk
  while FFileStream.Position < FileSizeCached do
  begin
    // 2. Graceful Scanning (Standard Read)
    if FFileStream.Read(ChunkID, 4) < 4 then
      Break;
    if FFileStream.Read(ChunkSize, 4) < 4 then
      Break;

    if ChunkID = 'fmt ' then
    begin
      if ChunkSize < 16 then
        raise Exception.Create(ERR_DECODE_WAVINVALID);

      // 3. Mandatory Audio Parameters (ReadBuffer)
      FFileStream.ReadBuffer(AudioFormat, 2);
      FFileStream.ReadBuffer(FChannels, 2);
      FFileStream.ReadBuffer(FSampleRate, 4);
      FFileStream.Seek(6, soFromCurrent); // Skip ByteRate and BlockAlign
      FFileStream.ReadBuffer(FBitsPerSample, 2);

      // ---> AUDIT FIX 2.1: Strictly whitelist PCM ($0001) and IEEE_FLOAT ($0003)
      if AudioFormat = WAV_FORMAT_PCM then
      begin
        FIsFloat    := False;
        HasFmtChunk := True;
      end
      else if AudioFormat = WAV_FORMAT_IEEE_FLOAT then
      begin
        FIsFloat    := True;
        HasFmtChunk := True;
      end
      else if (AudioFormat = WAV_FORMAT_EXTENSIBLE) and (ChunkSize >= 40) then
      begin
        // Skip cbSize (2), wValidBitsPerSample (2), dwChannelMask (4) -> 8 bytes
        FFileStream.Seek(8, soFromCurrent);
        // Read first 2 bytes of SubFormat GUID (0x0001 = PCM, 0x0003 = IEEE Float)
        FFileStream.ReadBuffer(SubFormatTag, 2);
        if SubFormatTag = WAV_FORMAT_PCM then
        begin
          FIsFloat    := False;
          HasFmtChunk := True;
        end
        else if SubFormatTag = WAV_FORMAT_IEEE_FLOAT then
        begin
          FIsFloat    := True;
          HasFmtChunk := True;
        end
        else
          raise Exception.Create(ERR_DECODE_WAVINVALID);

        // Skip remaining 14 bytes of GUID plus any extra fmt bytes
        SkipBytes := Int64(ChunkSize) - 26;
        if (ChunkSize and 1) <> 0 then
          Inc(SkipBytes);
        if SkipBytes > 0 then
          FFileStream.Seek(SkipBytes, soFromCurrent);
        Continue;
      end
      else
        raise Exception.Create(ERR_DECODE_WAVINVALID);

      SkipBytes := Int64(ChunkSize) - 16;
      // RIFF word-alignment padding byte for odd-sized chunks
      if (ChunkSize and 1) <> 0 then
        Inc(SkipBytes);
      if SkipBytes > 0 then
        FFileStream.Seek(SkipBytes, soFromCurrent);
    end
    else if ChunkID = 'data' then
    begin
      FDataSize  := ChunkSize;
      FDataStart := FFileStream.Position;
      // Clamp FDataSize if header size exceeds physical file length
      if (FDataStart + FDataSize) > FileSizeCached then
        FDataSize := FileSizeCached - FDataStart;
      Break;
    end
    else
    begin
      // Skip odd-chunk RIFF padding byte so subsequent 'data'
      // chunk headers are never misaligned by 1 byte!
      SkipBytes := ChunkSize;
      if (ChunkSize and 1) <> 0 then
        Inc(SkipBytes);
      FFileStream.Seek(SkipBytes, soFromCurrent);
    end;
  end;

  // ---> AUDIT FIX 2.1: Validate parsed format, channels, and bit depth
  if (not HasFmtChunk) or (FChannels < 1) or (FSampleRate = 0) then
    raise Exception.Create(ERR_DECODE_WAVINVALID);

  if FIsFloat then
  begin
    if FBitsPerSample <> 32 then
      raise Exception.Create(ERR_DECODE_WAVINVALID);
  end
  else if not (FBitsPerSample in [16, 24, 32]) then
    raise Exception.Create(ERR_DECODE_WAVINVALID);

  // ---> AUDIT FIX 2.3: Trim FDataSize to an exact multiple of FBlockAlign
  FBlockAlign := Integer(FChannels) * (Integer(FBitsPerSample) div 8);
  if (FBlockAlign <= 0) or (FDataSize < FBlockAlign) then
    raise Exception.Create(ERR_DECODE_WAVINVALID);

  FDataSize := FDataSize - (FDataSize mod FBlockAlign);
  if FDataSize <= 0 then
    raise Exception.Create(ERR_DECODE_WAVINVALID);

  FFileStream.Position := FDataStart;
end;

destructor TWavReader.Destroy;
begin
  if Assigned(FFileStream) then
    FFileStream.Free;
  inherited;
end;

function TWavReader.ReadData(Buffer: Pointer; Count: integer): integer;
var
  I, SampleCount, Remainder: integer;
  PFlt: PSingle;
  PInt: PInteger;
  ValDbl: double;
begin
  if (FBytesRead + Count) > FDataSize then
    Count := FDataSize - FBytesRead;

  // ---> AUDIT FIX 2.3: Round Count down to whole frames
  if FBlockAlign > 1 then
    Count := Count - (Count mod FBlockAlign);

  if Count <= 0 then
    Exit(0);

  Result := FFileStream.Read(Buffer^, Count);
  if Result <= 0 then
    Exit(0);

  // ---> AUDIT FIX 2.3: If a short read returned a partial frame, rewind the
  // trailing bytes so gapless buffer splices never lose frame alignment!
  if (FBlockAlign > 1) and ((Result mod FBlockAlign) <> 0) then
  begin
    Remainder := Result mod FBlockAlign;
    Dec(Result, Remainder);
    FFileStream.Seek(-Remainder, soFromCurrent);
    if Result <= 0 then
      Exit(0);
  end;

  Inc(FBytesRead, Result);

  // Convert 32-bit IEEE Float WAV samples (-1.0..+1.0) in-place
  // to 32-bit Signed Integer PCM so they play cleanly instead of digital noise!
  if FIsFloat and (FBitsPerSample = 32) then
  begin
    SampleCount := Result div 4;
    PFlt        := PSingle(Buffer);
    PInt        := PInteger(Buffer);
    for I := 0 to SampleCount - 1 do
    begin
      if IsNan(PFlt^) or IsInfinite(PFlt^) then
        ValDbl := 0.0
      else
        ValDbl := PFlt^ * 2147483647.0;

      if ValDbl > 2147483647.0 then
        PInt^ := 2147483647
      else if ValDbl < -2147483648.0 then
        PInt^ := -2147483648
      else
        PInt^ := Round(ValDbl);

      Inc(PFlt);
      Inc(PInt);
    end;
  end;
end;

procedure TWavReader.Seek(Percent: double);
var
  ClampedPercent: double;
  Target: int64;
begin
  ClampedPercent := EnsureRange(Percent, 0.0, 1.0);
  Target         := Round(ClampedPercent * FDataSize);

  // Align to sample boundary
  if FBlockAlign > 0 then
    Target := Target - (Target mod FBlockAlign);

  if Target > FDataSize then
    Target := FDataSize;
  if Target < 0 then
    Target := 0;

  FBytesRead           := Target;
  FFileStream.Position := FDataStart + Target;
end;

function TWavReader.GetProgress: double;
begin
  if FDataSize <= 0 then
    Result := 0.0
  else
    Result := double(FBytesRead) / double(FDataSize);

  if Result > 1.0 then
    Result := 1.0;
end;

end.
