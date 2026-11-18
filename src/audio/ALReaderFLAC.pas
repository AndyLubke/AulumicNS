unit ALReaderFLAC;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:      AulumicNS (from Aulumic)
  Unit Name:    ALReaderFLAC

  Used by ALReaders to read FLAC files.
  ---> AulumicNS: decodes with the built-in FLAC decoder of Aulos
  (AuDecFlac.TAuFlacDecoder, Pascal) instead of libFLAC.dll. The interface and
  the output are the same as in Aulumic: interleaved little endian PCM in a
  16, 24 or 32 bit container; streams of fewer bits are shifted up into it
  (e.g. 20 bit -> 24 bit container), so a 16 / 24 bit file reaches the DAC
  unchanged. The file name is UTF-8.
==============================================================================}

interface

uses
  SysUtils, Classes, Math, AuAudioTypes, AuDecoder, AuDecFlac;

type
  TFlacReader = class
  private
    FDecoder: TAuFlacDecoder;
    FPcm: array of Int32;       // decoded frames (right aligned samples)

    // Audio Format
    FSampleRate: cardinal;
    FChannels: word;
    FBitsPerSample: word;       // container: 16, 24 or 32
    FSourceBitsPerSample: word; // as in the stream (e.g. 20)
    FBitShift: word;
    FTotalSamples: int64;
    FDataSize: int64;

    FBytesReadTotal: int64;
    // bytes of a frame that did not fit into the last ReadData call
    FCarry: array of byte;
    FCarryLen: integer;

    procedure PackFrames(Src: PInt32; Frames: Integer; Dest: PByte);
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;

    function ReadData(Buffer: Pointer; BytesToRead: integer): integer;
    function GetProgress: double;
    procedure Seek(Percent: double);

    property SampleRate: cardinal read FSampleRate;
    property Channels: word read FChannels;
    property BitsPerSample: word read FBitsPerSample;
    property DataSize: int64 read FDataSize;
  end;

implementation

uses uAppStrings;

const
  // frames decoded per step (any FLAC block size fits; the decoder keeps the rest)
  DECODE_FRAMES = 8192;

constructor TFlacReader.Create(const FileName: string);
begin
  inherited Create;

  if not FileExists(LongPath(FileName)) then
    raise Exception.Create(ERR_FILE_NOT_FOUND + ' ' + FileName);

  FDecoder := TAuFlacDecoder.Create;
  try
    FDecoder.Open(FileName);
  except
    on E: Exception do
    begin
      FreeAndNil(FDecoder);
      raise Exception.Create(ERR_DECODE_FLACFAIL + ' (' + E.Message + ')');
    end;
  end;

  FSampleRate          := FDecoder.Info.SampleRate;
  FChannels            := word(FDecoder.Info.Channels);
  FSourceBitsPerSample := word(FDecoder.Info.BitsPerSample);

  if (FSourceBitsPerSample < 4) or (FSourceBitsPerSample > 32) or (FChannels = 0) or (FSampleRate = 0) then
  begin
    FreeAndNil(FDecoder);
    raise Exception.Create(ERR_DECODE_FLACINIT);
  end;

  // Map all <= 16-bit FLAC streams (8, 12 bit ...) into a signed 16-bit
  // container, 17 .. 24 into 24, more into 32 (as Aulumic did)
  if FSourceBitsPerSample <= 16 then
  begin
    FBitsPerSample := 16;
    FBitShift      := 16 - FSourceBitsPerSample;
  end
  else if FSourceBitsPerSample <= 24 then
  begin
    FBitsPerSample := 24;
    FBitShift      := 24 - FSourceBitsPerSample;
  end
  else
  begin
    FBitsPerSample := 32;
    FBitShift      := 32 - FSourceBitsPerSample;
  end;

  if FDecoder.Info.TotalFrames > 0 then
    FTotalSamples := FDecoder.Info.TotalFrames
  else
    FTotalSamples := 0;
  FDataSize := Int64(FTotalSamples) * Int64(FChannels) * (FBitsPerSample div 8);

  SetLength(FPcm, DECODE_FRAMES * FChannels);
  SetLength(FCarry, Integer(FChannels) * 4);
  FCarryLen := 0;
  FBytesReadTotal := 0;
end;

destructor TFlacReader.Destroy;
begin
  FDecoder.Free;
  inherited;
end;

procedure TFlacReader.PackFrames(Src: PInt32; Frames: Integer; Dest: PByte);
var
  I, N: Integer;
  V: Int32;
  Sh: Integer;
begin
  N := Frames * FChannels;
  Sh := FBitShift;
  case FBitsPerSample of
    16:
      for I := 0 to N - 1 do
      begin
        PSmallInt(Dest)^ := SmallInt(Src[I] shl Sh);
        Inc(Dest, 2);
      end;
    24:
      for I := 0 to N - 1 do
      begin
        V := Src[I] shl Sh;
        Dest[0] := V and $FF;
        Dest[1] := (V shr 8) and $FF;
        Dest[2] := (V shr 16) and $FF;
        Inc(Dest, 3);
      end;
  else
    for I := 0 to N - 1 do
    begin
      PInt32(Dest)^ := Src[I] shl Sh;
      Inc(Dest, 4);
    end;
  end;
end;

function TFlacReader.ReadData(Buffer: Pointer; BytesToRead: integer): integer;
var
  Dest: PByte;
  FrameBytes, WantFrames, Got, Whole, Bytes: Integer;
  Tmp: array of byte;
begin
  Result := 0;
  if (FDecoder = nil) or (BytesToRead <= 0) then Exit;
  Dest := PByte(Buffer);
  FrameBytes := Integer(FChannels) * (FBitsPerSample div 8);

  // the rest of a frame of the last call first
  if FCarryLen > 0 then
  begin
    Bytes := Min(FCarryLen, BytesToRead);
    Move(FCarry[0], Dest^, Bytes);
    if Bytes < FCarryLen then Move(FCarry[Bytes], FCarry[0], FCarryLen - Bytes);
    Dec(FCarryLen, Bytes);
    Inc(Dest, Bytes);
    Inc(Result, Bytes);
    Inc(FBytesReadTotal, Bytes);
  end;

  while Result < BytesToRead do
  begin
    WantFrames := (BytesToRead - Result + FrameBytes - 1) div FrameBytes;
    if WantFrames > DECODE_FRAMES then WantFrames := DECODE_FRAMES;
    try
      Got := FDecoder.ReadPcm(@FPcm[0], WantFrames);
    except
      // a damaged stream ends here (as libFLAC's error state did)
      Got := 0;
    end;
    if Got <= 0 then Break;
    Whole := Min(Got, (BytesToRead - Result) div FrameBytes);
    if Whole > 0 then
    begin
      PackFrames(@FPcm[0], Whole, Dest);
      Bytes := Whole * FrameBytes;
      Inc(Dest, Bytes);
      Inc(Result, Bytes);
      Inc(FBytesReadTotal, Bytes);
    end;
    if Whole < Got then
    begin
      // a frame that does not fit completely: its first bytes now, the rest
      // in the next call (the caller asks for whole buffers, rarely needed)
      SetLength(Tmp, (Got - Whole) * FrameBytes);
      PackFrames(@FPcm[Whole * FChannels], Got - Whole, @Tmp[0]);
      Bytes := BytesToRead - Result;
      if Bytes > 0 then
      begin
        Move(Tmp[0], Dest^, Bytes);
        Inc(Result, Bytes);
        Inc(FBytesReadTotal, Bytes);
      end;
      FCarryLen := Length(Tmp) - Bytes;
      if Length(FCarry) < FCarryLen then SetLength(FCarry, FCarryLen);
      if FCarryLen > 0 then Move(Tmp[Bytes], FCarry[0], FCarryLen);
      Break;
    end;
  end;
end;

procedure TFlacReader.Seek(Percent: double);
var
  TargetSample, OldSample, FrameBytes: int64;
begin
  if (FDecoder = nil) or (FTotalSamples <= 0) then
    Exit;

  TargetSample := Round(EnsureRange(Percent, 0.0, 1.0) * FTotalSamples);
  if TargetSample >= FTotalSamples then
    TargetSample := FTotalSamples - 1;
  if TargetSample < 0 then
    TargetSample := 0;

  FrameBytes := Int64(FChannels) * (FBitsPerSample div 8);
  if FrameBytes > 0 then OldSample := FBytesReadTotal div FrameBytes else OldSample := 0;
  FCarryLen := 0;

  try
    FDecoder.Seek(TargetSample);
    FBytesReadTotal := TargetSample * FrameBytes;
  except
    // a failed seek goes back to where playback was, so that audio and the
    // progress value agree again
    try
      FDecoder.Seek(OldSample);
      FBytesReadTotal := OldSample * FrameBytes;
    except
    end;
  end;
end;

function TFlacReader.GetProgress: double;
begin
  if FDataSize <= 0 then
    Result := 0.0
  else
    Result := double(FBytesReadTotal) / double(FDataSize);

  if Result > 1.0 then
    Result := 1.0;
end;

end.
