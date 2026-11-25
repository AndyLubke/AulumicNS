unit ALReaderDSF;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALReaderDSF
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Used by ALReaders to read DSF files.
  The file name is UTF-8 (opened as it is, no conversion).
==============================================================================}

interface

uses
  SysUtils, Classes, Math,
  AuAudioTypes,  // LongPath (paths of 260 characters and more)
  ALAudioTypes,
  ALReaderDFF;   // DFF files are read by TDffReader

type

  { TDsfReader }

  TDsfReader = class
  private
    FFile: TStream;
    FDataStart: int64;
    FDataSize: int64;
    FValidAudioBytes: int64;
    FValidBytesPerChan: int64;
    FBlockSize: cardinal;
    FTotalBlocks: int64;
    FCurrentBlockIndex: int64;
    FBlockMemory: pbyte;
    FBufferL: pbyte;
    FBufferR: pbyte;
    FBlockOffset: cardinal;
    FBytesRead: int64;
    FMarker: byte;
    FSampleRate: cardinal;
    // Separate physical file channels (1=Mono, 2=Stereo, >2=Multi)
    // from output DoP stream channels (2 for Mono/Stereo, >2 for Multi-Channel)
    FFileChannels: word;
    FChannelCount: word;
    FChannelType: integer;   // of a DSF file (its fmt chunk)
    // A DSDIFF file is read by this reader (same output)
    FDff: TDffReader;

    procedure ReadNextBlocks;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;

    function ReadData(Buffer: Pointer; BytesToRead: integer): integer;
    // Every channel of the file: ASteps bytes per channel, the channels of
    // one step side by side, the DSD bits MSB first. Returns the steps read.
    // For files with more than two channels (ReadData gives the first two).
    function ReadRaw(ADest: PByte; ASteps: Integer): Integer;
    // What each channel is: from the channel type of a DSF file, the channel
    // names of a DFF file (nil when unknown)
    function Roles: TChannelRoles;
    function GetProgress: double;
    procedure Seek(Percent: double);
    function GetBitsPerSample: word;

    function GetDoPMarker: byte;
    procedure SetDoPMarker(Value: byte);

    property GetSampleRate: cardinal read FSampleRate;
    property GetChannels: word read FChannelCount;
    property FileChannels: word read FFileChannels;
    // Expose 2-channel normalized valid bytes so TDsfSource
    // calculates exact duration for both Mono and Stereo DSF files
    property DataSize: int64 read FValidAudioBytes;
  end;

implementation

uses uAppStrings, uAppConsts;

type
  TDsfChunkHeader = packed record
    ID: array[0..3] of ansichar;
    Size: int64;
  end;

  TDsfFmtChunk = packed record
    Header: TDsfChunkHeader;
    FormatVersion: integer;
    FormatID: integer;
    ChannelType: integer;
    ChannelNum: integer;
    SamplingFreq: integer;
    BitsPerSample: integer;
    SampleCount: int64;
    BlockSizePerChannel: integer;
    Reserved: integer;
  end;

// =============================================================================
// Pre-computed static Bit-Reversal Table (0 CPU cycles on open)
// =============================================================================
const
  BIT_REVERSE_TABLE: array[0..255] of byte = (
    $00, $80, $40, $C0, $20, $A0, $60, $E0, $10, $90, $50, $D0, $30, $B0, $70, $F0,
    $08, $88, $48, $C8, $28, $A8, $68, $E8, $18, $98, $58, $D8, $38, $B8, $78, $F8,
    $04, $84, $44, $C4, $24, $A4, $64, $E4, $14, $94, $54, $D4, $34, $B4, $74, $F4,
    $0C, $8C, $4C, $CC, $2C, $AC, $6C, $EC, $1C, $9C, $5C, $DC, $3C, $BC, $7C, $FC,
    $02, $82, $42, $C2, $22, $A2, $62, $E2, $12, $92, $52, $D2, $32, $B2, $72, $F2,
    $0A, $8A, $4A, $CA, $2A, $AA, $6A, $EA, $1A, $9A, $5A, $DA, $3A, $BA, $7A, $FA,
    $06, $86, $46, $C6, $26, $A6, $66, $E6, $16, $96, $56, $D6, $36, $B6, $76, $F6,
    $0E, $8E, $4E, $CE, $2E, $AE, $6E, $EE, $1E, $9E, $5E, $DE, $3E, $BE, $7E, $FE,
    $01, $81, $41, $C1, $21, $A1, $61, $E1, $11, $91, $51, $D1, $31, $B1, $71, $F1,
    $09, $89, $49, $C9, $29, $A9, $69, $E9, $19, $99, $59, $D9, $39, $B9, $79, $F9,
    $05, $85, $45, $C5, $25, $A5, $65, $E5, $15, $95, $55, $D5, $35, $B5, $75, $F5,
    $0D, $8D, $4D, $CD, $2D, $AD, $6D, $ED, $1D, $9D, $5D, $DD, $3D, $BD, $7D, $FD,
    $03, $83, $43, $C3, $23, $A3, $63, $E3, $13, $93, $53, $D3, $33, $B3, $73, $F3,
    $0B, $8B, $4B, $CB, $2B, $AB, $6B, $EB, $1B, $9B, $5B, $DB, $3B, $BB, $7B, $FB,
    $07, $87, $47, $C7, $27, $A7, $67, $E7, $17, $97, $57, $D7, $37, $B7, $77, $F7,
    $0F, $8F, $4F, $CF, $2F, $AF, $6F, $EF, $1F, $9F, $5F, $DF, $3F, $BF, $7F, $FF
  );

constructor TDsfReader.Create(const FileName: string);
var
  Header: TDsfChunkHeader;
  Fmt: TDsfFmtChunk;
  ChunkStart, FileSizeCached, BlockPairBytes: int64;
begin
  inherited Create;

  // Initialize local records
  Header := Default(TDsfChunkHeader);
  Fmt    := Default(TDsfFmtChunk);

  if not AuFileExists(FileName) then
    raise Exception.Create(ERR_FILE_NOT_FOUND + ' ' + FileName);

  // DSDIFF (.dff): the same DoP output from TDffReader
  if IsDffFile(FileName) then
  begin
    FDff            := TDffReader.Create(FileName);
    FSampleRate     := FDff.SampleRate;
    FChannelCount   := FDff.Channels;
    FFileChannels   := FDff.Channels;
    FValidAudioBytes := FDff.DataSize;
    Exit;
  end;

  FFile          := AuOpenFile(FileName, fmOpenRead or fmShareDenyWrite);
  FileSizeCached := FFile.Size;

  // ===========================================================================
  // !!! WARNING !!!
  // If the value of FMarker is changed Then the READDATA must be changed too!!!
  // ===========================================================================
  FMarker    := $05;
  FBytesRead := 0;

  FFile.ReadBuffer(Header, SizeOf(Header));
  if (Header.ID <> 'DSD ') or (Header.Size < SizeOf(Header)) or (Header.Size >= FileSizeCached) then
    raise Exception.Create(ERR_DECODE_NOTDSD);

  FFile.Position := Header.Size;
  FFile.ReadBuffer(Fmt, SizeOf(Fmt));

  // Validate DSF format chunk fields before allocating memory
  // - FormatID must be 0 (DSD raw)
  // - BitsPerSample must be 1 (LSB-first DSF; 8 = MSB-first)
  // - BlockSizePerChannel must be within 1..65536 (spec standard is 4096)
  // - ChannelNum must be within 1..8
  // - SamplingFreq must be a valid DSD multiple of 44.1 kHz (2,822,400 Hz) or 48 kHz (3,072,000 Hz)
  if (Fmt.Header.ID <> 'fmt ') or
     (Fmt.FormatID <> 0) or
     (Fmt.BitsPerSample <> 1) or
     (Fmt.BlockSizePerChannel < 1) or (Fmt.BlockSizePerChannel > 65536) or
     (Fmt.ChannelNum < 1) or (Fmt.ChannelNum > 8) or
     (Fmt.SampleCount <= 0) or
     (Fmt.SamplingFreq < DSD64_SAMPLE_RATE) or
     (((Fmt.SamplingFreq mod DSD64_SAMPLE_RATE) <> 0) and ((Fmt.SamplingFreq mod DSD64_48K_SAMPLE_RATE) <> 0)) then
    raise Exception.Create(ERR_DECODE_DSDHEADER);

  FBlockSize    := cardinal(Fmt.BlockSizePerChannel);
  FFileChannels := word(Fmt.ChannelNum);
  FChannelType  := Fmt.ChannelType;
  FSampleRate   := cardinal(Fmt.SamplingFreq) div 16; // DoP Rate

  // Mono DSF files are natively output as 2-channel dual-mono DoP frames
  // (FBufferR := FBufferL), while >2 channel files preserve their channel count
  // so CreateSource / RunWasapi rejects multi-channel streams.
  if FFileChannels = 1 then
    FChannelCount := 2
  else
    FChannelCount := FFileChannels;

  FValidBytesPerChan := Fmt.SampleCount div 8;
  if (Fmt.SampleCount mod 8) <> 0 then
    Inc(FValidBytesPerChan);

  // ReadData always advances FBytesRead by 4 bytes (2 channels * 2 bytes) per
  // 6-byte stereo DoP frame, so FValidAudioBytes is always 2 * FValidBytesPerChan.
  FValidAudioBytes := FValidBytesPerChan * 2;

  ChunkStart := Fmt.Header.Size + Header.Size;
  if (ChunkStart <= 0) or (ChunkStart >= FileSizeCached) then
    raise Exception.Create(ERR_DECODE_DSDHEADER);

  FFile.Position := ChunkStart;
  FFile.ReadBuffer(Header, SizeOf(Header));

  while (Header.ID <> 'data') and (FFile.Position < FileSizeCached) do
  begin
    if Header.Size <= SizeOf(Header) then
      Break;
    FFile.Position := FFile.Position + Header.Size - SizeOf(Header);
    FFile.ReadBuffer(Header, SizeOf(Header));
  end;

  if Header.ID <> 'data' then
    raise Exception.Create(ERR_DECODE_DSDHEADER);

  FDataStart := FFile.Position;
  FDataSize  := Header.Size - SizeOf(Header);
  if (FDataStart + FDataSize) > FileSizeCached then
    FDataSize := FileSizeCached - FDataStart;

  if FDataSize <= 0 then
    raise Exception.Create(ERR_DECODE_DSDHEADER);

  // Use physical FFileChannels for disk block calculations
  BlockPairBytes := Int64(FBlockSize) * FFileChannels;
  FTotalBlocks   := FDataSize div BlockPairBytes;

  if (FDataSize mod BlockPairBytes) <> 0 then
    Inc(FTotalBlocks);

  GetMem(FBlockMemory, FBlockSize * Max(2, Integer(FFileChannels)));
  FBufferL := FBlockMemory;
  if FFileChannels >= 2 then
    FBufferR := FBlockMemory + FBlockSize
  else
    FBufferR := FBlockMemory; // Mono fallback points R to L

  FCurrentBlockIndex := -1;
  FBlockOffset       := FBlockSize;
end;

destructor TDsfReader.Destroy;
begin
  FDff.Free;
  if Assigned(FBlockMemory) then
    FreeMem(FBlockMemory);
  if Assigned(FFile) then
    FFile.Free;
  inherited;
end;

procedure TDsfReader.ReadNextBlocks;
var
  BlockGroupBytes, BlockByteOffset, BytesLeft, ValidEndOffset, ValidInThisBlock: int64;
  BytesReadFromDisk: longint;
begin
  Inc(FCurrentBlockIndex);
  if FCurrentBlockIndex >= FTotalBlocks then
  begin
    FillChar(FBufferL^, FBlockSize, $69); // Pad with DSD Silence
    if FBufferR <> FBufferL then
      FillChar(FBufferR^, FBlockSize, $69);
    Exit;
  end;

  // Use physical FFileChannels when reading block groups from disk
  BlockGroupBytes := Int64(FBlockSize) * FFileChannels;
  BlockByteOffset := FCurrentBlockIndex * BlockGroupBytes;
  BytesLeft       := FDataSize - BlockByteOffset;

  if BytesLeft >= BlockGroupBytes then
  begin
    BytesReadFromDisk := FFile.Read(FBlockMemory^, BlockGroupBytes);
    if BytesReadFromDisk < BlockGroupBytes then
      FillChar((FBlockMemory + BytesReadFromDisk)^, BlockGroupBytes - BytesReadFromDisk, $69);
  end
  else
  begin
    FillChar(FBlockMemory^, BlockGroupBytes, $69);
    if BytesLeft > 0 then
      FFile.Read(FBlockMemory^, BytesLeft);
  end;

  ValidEndOffset := (FCurrentBlockIndex + 1) * Int64(FBlockSize);
  if ValidEndOffset > FValidBytesPerChan then
  begin
    ValidInThisBlock := FValidBytesPerChan - (FCurrentBlockIndex * Int64(FBlockSize));
    if ValidInThisBlock < 0 then
      ValidInThisBlock := 0;

    if ValidInThisBlock < FBlockSize then
    begin
      FillChar((FBufferL + ValidInThisBlock)^, FBlockSize - ValidInThisBlock, $69);
      if FBufferR <> FBufferL then
        FillChar((FBufferR + ValidInThisBlock)^, FBlockSize - ValidInThisBlock, $69);
    end;
  end;

  FBlockOffset := 0;
end;

function TDsfReader.ReadData(Buffer: Pointer; BytesToRead: integer): integer;
var
  POut, PL, PR: pbyte;
  BytesProduced: integer;
  FramesNeeded, FramesInBlock, FramesToCopy, I: integer;
  // Keep FramesValidLeft as Int64 so DSF files larger than
  // 8.58 GB never overflow 32-bit signed Integer and terminate early!
  ValidRemainingBytes, FramesValidLeft: int64;
  MarkerLocal: byte;
begin
  if FDff <> nil then
    Exit(FDff.ReadData(Buffer, BytesToRead));

  POut          := pbyte(Buffer);
  BytesProduced := 0;
  MarkerLocal   := FMarker;

  while (BytesProduced + 6) <= BytesToRead do
  begin
    if FBytesRead >= FValidAudioBytes then
      Break;

    if FBlockOffset >= FBlockSize then
    begin
      ReadNextBlocks;
      if FCurrentBlockIndex >= FTotalBlocks then
        Break;
    end;

    if (FBlockOffset + 1) >= FBlockSize then
    begin
      FBlockOffset := FBlockSize;
      Continue;
    end;

    // Calculate how many 6-byte DoP frames we can produce uninterrupted in this pass
    FramesNeeded  := (BytesToRead - BytesProduced) div 6;
    FramesInBlock := (FBlockSize - FBlockOffset) div 2;

    ValidRemainingBytes := FValidAudioBytes - FBytesRead;
    // Round up odd valid tail byte so the last valid sample is never dropped
    FramesValidLeft := (ValidRemainingBytes + 3) div 4;

    FramesToCopy := FramesNeeded;
    if FramesInBlock < FramesToCopy then
      FramesToCopy := FramesInBlock;
    if FramesValidLeft < Int64(FramesToCopy) then
      FramesToCopy := Integer(FramesValidLeft);

    if FramesToCopy <= 0 then
      Break;

    PL := FBufferL + FBlockOffset;
    PR := FBufferR + FBlockOffset;

    for I := 0 to FramesToCopy - 1 do
    begin
      // Write Left DoP Frame: [BitRev(L2)] [BitRev(L1)] [Marker]
      POut[0] := BIT_REVERSE_TABLE[PL[1]];
      POut[1] := BIT_REVERSE_TABLE[PL[0]];
      POut[2] := MarkerLocal;

      // Write Right DoP Frame: [BitRev(R2)] [BitRev(R1)] [Marker]
      POut[3] := BIT_REVERSE_TABLE[PR[1]];
      POut[4] := BIT_REVERSE_TABLE[PR[0]];
      POut[5] := MarkerLocal;

      Inc(PL, 2);
      Inc(PR, 2);
      Inc(POut, 6);

      // Fast DoP marker toggle ($05 xor $FF = $FA, $FA xor $FF = $05)
      MarkerLocal := MarkerLocal xor $FF;
    end;

    Inc(FBlockOffset, FramesToCopy * 2);
    Inc(FBytesRead, Int64(FramesToCopy) * 4);
    Inc(BytesProduced, FramesToCopy * 6);

    if FBytesRead > FValidAudioBytes then
      FBytesRead := FValidAudioBytes;
  end;

  FMarker := MarkerLocal;
  Result  := BytesProduced;
end;

function TDsfReader.ReadRaw(ADest: PByte; ASteps: Integer): Integer;
var
  N, I, C, Ch: Integer;
  Left: Int64;
  PSrc, POut: PByte;
begin
  if FDff <> nil then
    Exit(FDff.ReadRaw(ADest, ASteps));

  Result := 0;
  Ch     := FFileChannels;
  while Result < ASteps do
  begin
    if FBytesRead >= FValidAudioBytes then
      Break;

    if FBlockOffset >= FBlockSize then
    begin
      ReadNextBlocks;
      if FCurrentBlockIndex >= FTotalBlocks then
        Break;
    end;

    N := ASteps - Result;
    if Integer(FBlockSize - FBlockOffset) < N then
      N := Integer(FBlockSize - FBlockOffset);
    // FBytesRead counts two channels' worth of bytes per step
    Left := (FValidAudioBytes - FBytesRead + 1) div 2;
    if Left < N then
      N := Integer(Left);
    if N <= 0 then
      Break;

    // A block holds FBlockSize bytes of every channel in turn, LSB first
    for C := 0 to Ch - 1 do
    begin
      PSrc := FBlockMemory + Int64(C) * FBlockSize + FBlockOffset;
      POut := ADest + Int64(Result) * Ch + C;
      for I := 0 to N - 1 do
      begin
        POut^ := BIT_REVERSE_TABLE[PSrc[I]];
        Inc(POut, Ch);
      end;
    end;

    Inc(FBlockOffset, N);
    Inc(FBytesRead, Int64(N) * 2);
    if FBytesRead > FValidAudioBytes then
      FBytesRead := FValidAudioBytes;
    Inc(Result, N);
  end;
end;

function TDsfReader.Roles: TChannelRoles;
const
  T3: array[0..2] of TChannelRole = (chLeft, chRight, chCentre);
  T4: array[0..3] of TChannelRole = (chLeft, chRight, chSurroundLeft, chSurroundRight);
  T5: array[0..3] of TChannelRole = (chLeft, chRight, chCentre, chLfe);
  T6: array[0..4] of TChannelRole = (chLeft, chRight, chCentre, chSurroundLeft, chSurroundRight);
  T7: array[0..5] of TChannelRole = (chLeft, chRight, chCentre, chLfe, chSurroundLeft, chSurroundRight);

  function Copied(const A: array of TChannelRole): TChannelRoles;
  var
    I: Integer;
  begin
    Result := nil;
    if Length(A) <> Integer(FFileChannels) then
      Exit;
    SetLength(Result, Length(A));
    for I := 0 to High(A) do
      Result[I] := A[I];
  end;

begin
  if FDff <> nil then
    Exit(FDff.Roles);
  // The channel type of the fmt chunk: 3 = three channels, 4 = quadraphonic,
  // 5 = four channels with LFE, 6 = five channels, 7 = 5.1
  case FChannelType of
    3: Result := Copied(T3);
    4: Result := Copied(T4);
    5: Result := Copied(T5);
    6: Result := Copied(T6);
    7: Result := Copied(T7);
  else
    Result := nil;
  end;
end;

procedure TDsfReader.Seek(Percent: double);
var
  ClampedPercent: double;
  TargetBlock, MaxValidBlock, BlockGroupBytes: int64;
begin
  if FDff <> nil then
  begin
    FDff.Seek(Percent);
    Exit;
  end;

  ClampedPercent := EnsureRange(Percent, 0.0, 1.0);

  // Use FFileChannels for disk stride and FValidBytesPerChan for block count
  BlockGroupBytes := Int64(FBlockSize) * FFileChannels;
  if (BlockGroupBytes <= 0) or (FTotalBlocks <= 0) or (FBlockSize = 0) then
    Exit;

  MaxValidBlock := FValidBytesPerChan div FBlockSize;
  if MaxValidBlock >= FTotalBlocks then
    MaxValidBlock := FTotalBlocks - 1;
  if MaxValidBlock < 0 then
    MaxValidBlock := 0;

  TargetBlock := Round(ClampedPercent * MaxValidBlock);
  if TargetBlock > MaxValidBlock then
    TargetBlock := MaxValidBlock;

  FFile.Position     := FDataStart + (TargetBlock * BlockGroupBytes);
  FBytesRead         := TargetBlock * Int64(FBlockSize) * 2;
  FCurrentBlockIndex := TargetBlock - 1;
  FBlockOffset       := FBlockSize;
end;

function TDsfReader.GetProgress: double;
begin
  if FDff <> nil then
    Exit(FDff.GetProgress);
  if FValidAudioBytes <= 0 then
    Result := 0.0
  else
    Result := double(FBytesRead) / double(FValidAudioBytes);
end;

function TDsfReader.GetBitsPerSample: word;
begin
  Result := 24;
end;

function TDsfReader.GetDoPMarker: byte;
begin
  if FDff <> nil then
    Exit(FDff.GetDoPMarker);
  Result := FMarker;
end;

procedure TDsfReader.SetDoPMarker(Value: byte);
begin
  if FDff <> nil then
  begin
    FDff.SetDoPMarker(Value);
    Exit;
  end;
  if (Value = $05) or (Value = $FA) then
    FMarker := Value
  else
    FMarker := $05;
end;

end.
