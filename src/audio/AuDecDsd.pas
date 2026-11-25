unit AuDecDsd;

{ ==============================================================================
  AulumicNS - AuDecDsd
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  DSD decoders: DSF (Sony) and DFF / DSDIFF (Philips, uncompressed DSD).
  Both deliver interleaved bytes, one per channel per frame, with the earliest
  DSD sample in the most significant bit. ReplayGain from the ID3v2 tag
  (DSF metadata chunk, DFF 'ID3 ' chunk). DST compressed DFF files are
  reported as unsupported.
  =============================================================================}

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, AuAudioTypes, AuDecoder;

type
  { TAuDsfDecoder }

  TAuDsfDecoder = class(TAuDecoder)
  private
    FR: TAuBufReader;
    FDataStart: Int64;
    FBlock: Integer;             // bytes per channel per block (4096)
    FLsbFirst: Boolean;
    FGroup: array of Byte;       // one block of every channel
    FGroupIdx: Int64;            // index of the block group in FGroup (-1 = none)
    procedure LoadGroup(G: Int64);
  public
    destructor Destroy; override;
    procedure Open(const AFileName: string); override;
    function ReadDsd(Dest: PByte; MaxFrames: Integer): Integer; override;
    procedure Seek(Frame: Int64); override;
  end;

  { TAuDffDecoder }

  TAuDffDecoder = class(TAuDecoder)
  private
    FR: TAuBufReader;
    FDataStart: Int64;
  public
    // The channel names of the file in their order ('SLFT', 'C   ', 'LS  ' ...);
    // empty when the file names none
    ChannelIds: array of string;
    destructor Destroy; override;
    procedure Open(const AFileName: string); override;
    function ReadDsd(Dest: PByte; MaxFrames: Integer): Integer; override;
    procedure Seek(Frame: Int64); override;
  end;

var
  BitReverse: array[0..255] of Byte;

implementation

procedure InitBitReverse;
var
  I, J: Integer;
  B: Byte;
begin
  for I := 0 to 255 do
  begin
    B := 0;
    for J := 0 to 7 do
      if I and (1 shl J) <> 0 then B := B or (1 shl (7 - J));
    BitReverse[I] := B;
  end;
end;

procedure ReadId3At(R: TAuBufReader; Pos, Size: Int64; var RG: TAuReplayGain; var Tags: TAuBasicTags);
var
  B: TBytes;
begin
  if (Pos <= 0) or (Size < 10) or (Size > 64 * 1024 * 1024) or (Pos + Size > R.Size) then Exit;
  B := nil;
  SetLength(B, Size);
  R.Seek(Pos);
  R.ReadExact(B[0], Size);
  ParseId3ReplayGain(B, RG, Tags);
end;

{ ---- DSF ---- }

destructor TAuDsfDecoder.Destroy;
begin
  FR.Free;
  inherited Destroy;
end;

procedure TAuDsfDecoder.Open(const AFileName: string);
var
  MetaPtr, FmtSize, Samples, DataSize: QWord;
  Ch, Rate, Bits: Cardinal;
begin
  FR := TAuBufReader.Create(AFileName);
  if FR.ReadTag4 <> 'DSD ' then raise EAuAudio.CreateKind(aekFormat, 'Not a DSF file');
  FR.ReadU64LE;                    // chunk size (28)
  FR.ReadU64LE;                    // file size
  MetaPtr := FR.ReadU64LE;
  if FR.ReadTag4 <> 'fmt ' then raise EAuAudio.CreateKind(aekFormat, 'DSF: missing fmt chunk');
  FmtSize := FR.ReadU64LE;
  FR.ReadU32LE;                    // format version
  if FR.ReadU32LE <> 0 then raise EAuAudio.CreateKind(aekUnsupported, 'DSF: unsupported format id');
  FR.ReadU32LE;                    // channel type
  Ch := FR.ReadU32LE;
  Rate := FR.ReadU32LE;
  Bits := FR.ReadU32LE;
  Samples := FR.ReadU64LE;
  FBlock := FR.ReadU32LE;
  FR.Seek(28 + FmtSize);
  if FR.ReadTag4 <> 'data' then raise EAuAudio.CreateKind(aekFormat, 'DSF: missing data chunk');
  DataSize := FR.ReadU64LE;
  FDataStart := FR.Position;
  if (Ch < 1) or (Ch > 6) or (Rate < 2822400) or (FBlock <= 0) or (FBlock > 1024 * 1024) then
    raise EAuAudio.CreateKind(aekFormat, 'DSF: invalid header');
  if not (Bits in [1, 8]) then raise EAuAudio.CreateKind(aekFormat, 'DSF: invalid bit order');
  FLsbFirst := Bits = 1;
  FInfo.Kind := skDsd;
  FInfo.Codec := 'DSF';
  FInfo.SampleRate := Rate;
  FInfo.Channels := Ch;
  FInfo.BitsPerSample := 1;
  FInfo.TotalFrames := Int64((Samples + 7) div 8);
  { a broken sample count: limit it to the data that is there }
  if FInfo.TotalFrames > Int64(DataSize - 12) div Ch then FInfo.TotalFrames := Int64(DataSize - 12) div Ch;
  SetLength(FGroup, FBlock * Integer(Ch));
  FGroupIdx := -1;
  ReadId3At(FR, MetaPtr, FR.Size - Int64(MetaPtr), FRg, FTags);
  Seek(0);
end;

procedure TAuDsfDecoder.LoadGroup(G: Int64);
var
  N: Integer;
begin
  FR.Seek(FDataStart + G * Length(FGroup));
  N := FR.Read(FGroup[0], Length(FGroup));
  if N < Length(FGroup) then FillChar(FGroup[N], Length(FGroup) - N, 0);
  FGroupIdx := G;
end;

function TAuDsfDecoder.ReadDsd(Dest: PByte; MaxFrames: Integer): Integer;
var
  G: Int64;
  Off, N, I, C, Ch: Integer;
  Src: PByte;
begin
  Result := 0;
  Ch := FInfo.Channels;
  while Result < MaxFrames do
  begin
    if FPos >= FInfo.TotalFrames then Break;
    G := FPos div FBlock;
    if G <> FGroupIdx then LoadGroup(G);
    Off := Integer(FPos mod FBlock);
    N := FBlock - Off;
    if N > MaxFrames - Result then N := MaxFrames - Result;
    if FPos + N > FInfo.TotalFrames then N := Integer(FInfo.TotalFrames - FPos);
    for C := 0 to Ch - 1 do
    begin
      Src := @FGroup[C * FBlock + Off];
      if FLsbFirst then
        for I := 0 to N - 1 do Dest[(Result + I) * Ch + C] := BitReverse[Src[I]]
      else
        for I := 0 to N - 1 do Dest[(Result + I) * Ch + C] := Src[I];
    end;
    Inc(Result, N);
    Inc(FPos, N);
  end;
end;

procedure TAuDsfDecoder.Seek(Frame: Int64);
begin
  if Frame < 0 then Frame := 0;
  if Frame > FInfo.TotalFrames then Frame := FInfo.TotalFrames;
  FPos := Frame;
end;

{ ---- DFF / DSDIFF ---- }

destructor TAuDffDecoder.Destroy;
begin
  FR.Free;
  inherited Destroy;
end;

procedure TAuDffDecoder.Open(const AFileName: string);
var
  Id, Sub: string;
  Size, SubSize: QWord;
  Start, PropEnd, SubStart: Int64;
  Rate: Cardinal;
  Ch, I: Integer;
  Cmpr: string;
  DataSize: QWord;
begin
  FR := TAuBufReader.Create(AFileName);
  if FR.ReadTag4 <> 'FRM8' then raise EAuAudio.CreateKind(aekFormat, 'Not a DFF file');
  FR.ReadU64BE;
  if FR.ReadTag4 <> 'DSD ' then raise EAuAudio.CreateKind(aekFormat, 'Not a DSDIFF file');
  Rate := 0;
  Ch := 0;
  Cmpr := 'DSD ';
  FDataStart := -1;
  DataSize := 0;
  while FR.Position + 12 <= FR.Size do
  begin
    Id := FR.ReadTag4;
    Size := FR.ReadU64BE;
    Start := FR.Position;
    // A chunk that says it is longer than the file: the sound is taken as
    // far as the file reaches, anything else ends the chunks
    if Size > QWord(FR.Size - Start) then
    begin
      if (Id = 'DSD ') and (FDataStart < 0) then
      begin
        FDataStart := Start;
        DataSize := QWord(FR.Size - Start);
      end;
      Break;
    end;
    if Id = 'PROP' then
    begin
      PropEnd := Start + Int64(Size);
      if FR.ReadTag4 = 'SND ' then
        while FR.Position + 12 <= PropEnd do
        begin
          Sub := FR.ReadTag4;
          SubSize := FR.ReadU64BE;
          SubStart := FR.Position;
          if Sub = 'FS  ' then Rate := FR.ReadU32BE
          else if Sub = 'CHNL' then
          begin
            Ch := FR.ReadU16BE;
            ChannelIds := nil;
            if (Ch >= 1) and (Ch <= 6) and (SubSize >= QWord(2 + 4 * Ch)) then
            begin
              SetLength(ChannelIds, Ch);
              for I := 0 to Ch - 1 do ChannelIds[I] := FR.ReadTag4;
            end;
          end
          else if Sub = 'CMPR' then Cmpr := FR.ReadTag4;
          FR.Seek(SubStart + Int64(SubSize) + (SubSize and 1));
        end;
    end
    else if (Id = 'DSD ') or (Id = 'DST ') then
    begin
      if Id = 'DST ' then Cmpr := 'DST ';
      FDataStart := Start;
      DataSize := Size;
    end
    else if Id = 'ID3 ' then
      ReadId3At(FR, Start, Int64(Size), FRg, FTags);
    FR.Seek(Start + Int64(Size) + (Size and 1));
  end;
  if Cmpr <> 'DSD ' then
    raise EAuAudio.CreateKind(aekUnsupported, 'DFF: DST compressed DSD is not supported');
  if (Rate < 2822400) or (Ch < 1) or (Ch > 6) or (FDataStart < 0) then
    raise EAuAudio.CreateKind(aekFormat, 'DFF: invalid file');
  if FDataStart + Int64(DataSize) > FR.Size then DataSize := FR.Size - FDataStart;
  FInfo.Kind := skDsd;
  FInfo.Codec := 'DFF';
  FInfo.SampleRate := Rate;
  FInfo.Channels := Ch;
  FInfo.BitsPerSample := 1;
  FInfo.TotalFrames := Int64(DataSize) div Ch;
  Seek(0);
end;

function TAuDffDecoder.ReadDsd(Dest: PByte; MaxFrames: Integer): Integer;
var
  N: Int64;
begin
  N := FInfo.TotalFrames - FPos;
  if N > MaxFrames then N := MaxFrames;
  if N <= 0 then Exit(0);
  Result := FR.Read(Dest^, Integer(N) * FInfo.Channels) div FInfo.Channels;
  Inc(FPos, Result);
end;

procedure TAuDffDecoder.Seek(Frame: Int64);
begin
  if Frame < 0 then Frame := 0;
  if Frame > FInfo.TotalFrames then Frame := FInfo.TotalFrames;
  FPos := Frame;
  FR.Seek(FDataStart + Frame * FInfo.Channels);
end;

initialization
  InitBitReverse;

end.
