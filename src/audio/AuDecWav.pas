unit AuDecWav;

{ ==============================================================================
  AulumicNS - AuDecWav
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  WAV / RF64 decoder: integer PCM 8 - 32 bit (also valid bits < container),
  IEEE float 32 / 64 bit, WAVE_FORMAT_EXTENSIBLE. ReplayGain from an ID3
  chunk.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, AuAudioTypes, AuDecoder;

type
  TAuWavDecoder = class(TAuDecoder)
  private
    FR: TAuBufReader;
    FDataStart, FDataSize: Int64;
    FBlockAlign, FContainer: Integer;
    FBuf: array of Byte;
    function ReadRaw(MaxFrames: Integer): Integer;
  public
    destructor Destroy; override;
    procedure Open(const AFileName: string); override;
    function ReadPcm(Dest: PInt32; MaxFrames: Integer): Integer; override;
    function ReadFloat(Dest: PDouble; MaxFrames: Integer): Integer; override;
    procedure Seek(Frame: Int64); override;
  end;

implementation

destructor TAuWavDecoder.Destroy;
begin
  FR.Free;
  inherited Destroy;
end;

procedure TAuWavDecoder.Open(const AFileName: string);
var
  Riff, Id: string;
  Size, DS64Data: QWord;
  ChunkStart: Int64;
  Tag, Channels, BlockAlign, Bits, Valid: Integer;
  Rate: Cardinal;
  HaveFmt, IsRF64, IsFloat: Boolean;
  Sub: array[0..15] of Byte;
  Id3: TBytes;
begin
  FR := TAuBufReader.Create(AFileName);
  Riff := FR.ReadTag4;
  IsRF64 := (Riff = 'RF64') or (Riff = 'BW64');
  if (Riff <> 'RIFF') and not IsRF64 then raise EAuAudio.CreateKind(aekFormat, 'Not a WAV file');
  FR.ReadU32LE;
  if FR.ReadTag4 <> 'WAVE' then raise EAuAudio.CreateKind(aekFormat, 'Not a WAV file');
  HaveFmt := False;
  IsFloat := False;
  DS64Data := 0;
  Tag := 0; Channels := 0; Rate := 0; BlockAlign := 0; Bits := 0; Valid := 0;
  FDataStart := -1;
  while FR.Position + 8 <= FR.Size do
  begin
    Id := FR.ReadTag4;
    Size := FR.ReadU32LE;
    ChunkStart := FR.Position;
    if Id = 'ds64' then
    begin
      FR.ReadU64LE;                      // RIFF size
      DS64Data := FR.ReadU64LE;
    end
    else if Id = 'fmt ' then
    begin
      Tag := FR.ReadU16LE;
      Channels := FR.ReadU16LE;
      Rate := FR.ReadU32LE;
      FR.ReadU32LE;
      BlockAlign := FR.ReadU16LE;
      Bits := FR.ReadU16LE;
      Valid := Bits;
      if (Tag = $FFFE) and (Size >= 40) then
      begin
        FR.ReadU16LE;                    // cbSize
        Valid := FR.ReadU16LE;
        FR.ReadU32LE;                    // channel mask
        FR.ReadExact(Sub, 16);
        Tag := Sub[0] or (Sub[1] shl 8);
      end;
      HaveFmt := True;
    end
    else if Id = 'data' then
    begin
      FDataStart := ChunkStart;
      if IsRF64 and (Size = $FFFFFFFF) then FDataSize := DS64Data else FDataSize := Size;
      if FDataStart + FDataSize > FR.Size then FDataSize := FR.Size - FDataStart;
      Size := FDataSize;
    end
    else if ((Id = 'id3 ') or (Id = 'ID3 ')) and (Size > 10) and (Size < 64 * 1024 * 1024) then
    begin
      Id3 := nil;
      SetLength(Id3, Size);
      FR.ReadExact(Id3[0], Size);
      ParseId3ReplayGain(Id3, FRg, FTags);
    end;
    FR.Seek(ChunkStart + Int64(Size) + (Size and 1));
  end;
  if not HaveFmt or (FDataStart < 0) then raise EAuAudio.CreateKind(aekFormat, 'WAV file without format or data');
  if Tag = 3 then IsFloat := True
  else if Tag <> 1 then raise EAuAudio.CreateKind(aekUnsupported, Format('Unsupported WAV encoding (format tag %d)', [Tag]));
  if (Channels < 1) or (Rate = 0) or (BlockAlign = 0) then raise EAuAudio.CreateKind(aekFormat, 'Invalid WAV header');
  FContainer := (BlockAlign div Channels) * 8;
  if IsFloat and not (FContainer in [32, 64]) then raise EAuAudio.CreateKind(aekUnsupported, 'Unsupported float WAV');
  if not IsFloat and ((FContainer < 8) or (FContainer > 32)) then raise EAuAudio.CreateKind(aekUnsupported, 'Unsupported WAV bit depth');
  if (Valid <= 0) or (Valid > FContainer) then Valid := FContainer;
  FBlockAlign := BlockAlign;
  FInfo.Codec := 'WAV';
  FInfo.SampleRate := Rate;
  FInfo.Channels := Channels;
  if IsFloat then
  begin
    FInfo.Kind := skPcmFloat;
    FInfo.BitsPerSample := FContainer;
  end
  else
  begin
    FInfo.Kind := skPcmInt;
    FInfo.BitsPerSample := Valid;
  end;
  FInfo.TotalFrames := FDataSize div BlockAlign;
  Seek(0);
end;

function TAuWavDecoder.ReadRaw(MaxFrames: Integer): Integer;
var
  Left: Int64;
begin
  Left := FInfo.TotalFrames - FPos;
  if MaxFrames > Left then MaxFrames := Left;
  if MaxFrames <= 0 then Exit(0);
  if Length(FBuf) < MaxFrames * FBlockAlign then SetLength(FBuf, MaxFrames * FBlockAlign);
  Result := FR.Read(FBuf[0], MaxFrames * FBlockAlign) div FBlockAlign;
  Inc(FPos, Result);
end;

function TAuWavDecoder.ReadPcm(Dest: PInt32; MaxFrames: Integer): Integer;
var
  I, N, Sh: Integer;
  P: PByte;
begin
  if FInfo.Kind <> skPcmInt then Exit(inherited ReadPcm(Dest, MaxFrames));
  Result := ReadRaw(MaxFrames);
  N := Result * FInfo.Channels;
  P := @FBuf[0];
  Sh := FContainer - FInfo.BitsPerSample;
  case FContainer of
    8: for I := 0 to N - 1 do Dest[I] := Int32(P[I]) - 128;
    16: for I := 0 to N - 1 do Dest[I] := SmallInt(P[2 * I] or (P[2 * I + 1] shl 8));
    24: for I := 0 to N - 1 do
          Dest[I] := Int32(Cardinal(P[3 * I] shl 8) or (Cardinal(P[3 * I + 1]) shl 16) or (Cardinal(P[3 * I + 2]) shl 24)) div 256;
    32: for I := 0 to N - 1 do Dest[I] := PInt32(P + 4 * I)^;
  end;
  if Sh > 0 then
    for I := 0 to N - 1 do Dest[I] := SarLongint(Dest[I], Sh);
end;

function TAuWavDecoder.ReadFloat(Dest: PDouble; MaxFrames: Integer): Integer;
var
  I, N: Integer;
begin
  if FInfo.Kind <> skPcmFloat then Exit(inherited ReadFloat(Dest, MaxFrames));
  Result := ReadRaw(MaxFrames);
  N := Result * FInfo.Channels;
  if FContainer = 32 then
    for I := 0 to N - 1 do Dest[I] := PSingle(@FBuf[4 * I])^
  else
    for I := 0 to N - 1 do Dest[I] := PDouble(@FBuf[8 * I])^;
end;

procedure TAuWavDecoder.Seek(Frame: Int64);
begin
  if Frame < 0 then Frame := 0;
  if Frame > FInfo.TotalFrames then Frame := FInfo.TotalFrames;
  FPos := Frame;
  FR.Seek(FDataStart + Frame * FBlockAlign);
end;

end.
