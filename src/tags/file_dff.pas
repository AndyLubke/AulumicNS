{
  AulumicTag DFF (DSDIFF) handler - new in AulumicNS.
  Reads the DSD audio properties of a DSDIFF file (big-endian IFF: 'FRM8'
  container, 'PROP' / 'SND ' with 'FS  ' and 'CHNL', the 'DSD ' or 'DST '
  sound chunk) and the ID3v2 tag that DSDIFF players store in an 'ID3 '
  chunk - inside the FRM8 container or right after it (both are found in
  the wild). The tag is parsed with OvoTag's ID3v2 class, as in file_dsf.
  Writing: the file is rebuilt chunk by chunk
  - every chunk but the old 'ID3 ' chunks is copied unchanged, the new tag
  goes into one 'ID3 ' chunk at the end of the FRM8 container (where
  foobar2000 and JRiver put it) and the container size is set anew. A tag
  that was read only in part is never rewritten (as file_dsf).
}
unit file_dff;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, AudioTag, baseTag, tag_id3v2;

const
  DffFileMask: string = '*.dff;';

type
  { TDffTagReader (TDffReader is the audio reader of ALReaderDFF) }

  TDffTagReader = class(TTagReader)
  private
    fTags: TID3Tags;
    FSampleRate: cardinal;
    FChannels: cardinal;
    FTotalSamples: int64;      // DSD samples (bits) per channel
    fMediaProperty: TMediaProperty;
    FTagTruncated: boolean;    // the ID3 chunk was too big to read: never saved
  protected
    function GetDuration: int64; override;
    function GetTags: TTags; override;
    function DumpInfo: TMediaProperty; override;
  public
    { the tags are freed by TTagReader.Destroy (GetTags) }
    function LoadFromFile(const AFileName: TFileName): boolean; override;
    function SaveToFile(const AFileName: TFileName): boolean; override;
    function isUpdateable: boolean; override;
  end;

implementation

uses
  CommonFunctions, AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  MAX_DFF_ID3_SIZE = 64 * 1024 * 1024;   // safety cap for the ID3 chunk

function ReadU16BE(S: TStream; out V: cardinal): boolean;
var
  B: array[0..1] of byte;
begin
  Result := S.Read(B, 2) = 2;
  if Result then V := (cardinal(B[0]) shl 8) or B[1] else V := 0;
end;

function ReadU32BE(S: TStream; out V: cardinal): boolean;
var
  B: array[0..3] of byte;
begin
  Result := S.Read(B, 4) = 4;
  if Result then
    V := (cardinal(B[0]) shl 24) or (cardinal(B[1]) shl 16) or (cardinal(B[2]) shl 8) or B[3]
  else
    V := 0;
end;

function ReadU64BE(S: TStream; out V: int64): boolean;
var
  Hi, Lo: cardinal;
begin
  Result := ReadU32BE(S, Hi) and ReadU32BE(S, Lo);
  if Result then V := (int64(Hi) shl 32) or Lo else V := 0;
end;

function ReadId(S: TStream; out Id: string): boolean;
var
  B: array[0..3] of ansichar;
begin
  Result := S.Read(B, 4) = 4;
  if Result then SetString(Id, PAnsiChar(@B[0]), 4) else Id := '';
end;

{ TDffTagReader }

function TDffTagReader.GetDuration: int64;
begin
  Result := 0;
  if (FSampleRate > 0) and (FTotalSamples > 0) then
    Result := Trunc((FTotalSamples / FSampleRate) * 1000);
end;

function TDffTagReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TID3Tags.Create;
  Result := fTags;
end;

function TDffTagReader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TDffTagReader.LoadFromFile(const AFileName: TFileName): boolean;
var
  fStream: TStream;
  Id, SubId: string;
  FormSize, ChunkSize, SubSize, Pos, FormEnd, PropEnd, SubPos, Id3Pos, Id3Size: int64;
  V, Frames, FrameRate: cardinal;

  { an 'ID3 ' chunk at APos (its payload starts with the ID3v2 header) }
  procedure ReadId3(APos, ASize: int64);
  var
    MemStream: TMemoryStream;
  begin
    if (ASize < 10) or (APos + ASize > fStream.Size) then Exit;
    if ASize > MAX_DFF_ID3_SIZE then
    begin
      FTagTruncated := True;
      Exit;
    end;
    fStream.Position := APos;
    MemStream := TMemoryStream.Create;
    try
      MemStream.CopyFrom(fStream, ASize);
      MemStream.Position := 0;
      fTags.ReadFromStream(MemStream);
    finally
      MemStream.Free;
    end;
  end;

begin
  inherited LoadFromFile(AFileName);
  Result := False;
  FSampleRate := 0;
  FChannels := 0;
  FTotalSamples := 0;
  fMediaProperty := Default(TMediaProperty);
  FTagTruncated := False;
  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TID3Tags.Create;
  Id3Pos := 0;
  Id3Size := 0;
  Frames := 0;
  FrameRate := 0;

  fStream := nil;
  try
    try
      fStream := AuOpenFile(AFileName, fmOpenRead or fmShareDenyNone);
      if (not ReadId(fStream, Id)) or (Id <> 'FRM8') then Exit(False);
      if not ReadU64BE(fStream, FormSize) then Exit(False);
      if (not ReadId(fStream, Id)) or (Id <> 'DSD ') then Exit(False);
      FormEnd := 12 + FormSize;
      if FormEnd > fStream.Size then FormEnd := fStream.Size;

      Pos := 16;
      while Pos + 12 <= fStream.Size do
      begin
        fStream.Position := Pos;
        if not (ReadId(fStream, Id) and ReadU64BE(fStream, ChunkSize)) then Break;
        if (ChunkSize < 0) or (Pos + 12 + ChunkSize > fStream.Size) then
          ChunkSize := fStream.Size - Pos - 12;
        if Id = 'PROP' then
        begin
          PropEnd := Pos + 12 + ChunkSize;
          if ReadId(fStream, SubId) and (SubId = 'SND ') then
          begin
            SubPos := fStream.Position;
            while SubPos + 12 <= PropEnd do
            begin
              fStream.Position := SubPos;
              if not (ReadId(fStream, SubId) and ReadU64BE(fStream, SubSize)) then Break;
              if SubSize < 0 then Break;
              if SubId = 'FS  ' then
              begin
                if ReadU32BE(fStream, V) then FSampleRate := V;
              end
              else if SubId = 'CHNL' then
              begin
                if ReadU16BE(fStream, V) then FChannels := V;
              end;
              SubPos := SubPos + 12 + SubSize + (SubSize and 1);
            end;
          end;
        end
        else if Id = 'DSD ' then
        begin
          if FChannels > 0 then
            FTotalSamples := (ChunkSize * 8) div FChannels;
        end
        else if Id = 'DST ' then
        begin
          { compressed: the frame count and rate ('FRTE') give the length }
          if ReadId(fStream, SubId) and (SubId = 'FRTE') and ReadU64BE(fStream, SubSize) and
             ReadU32BE(fStream, Frames) and ReadU16BE(fStream, FrameRate) and
             (FrameRate > 0) and (FSampleRate > 0) then
            FTotalSamples := (int64(Frames) * FSampleRate) div FrameRate;
        end
        else if Id = 'ID3 ' then
        begin
          Id3Pos := Pos + 12;
          Id3Size := ChunkSize;
        end;
        Pos := Pos + 12 + ChunkSize + (ChunkSize and 1);
        { past the container: only an ID3 chunk may follow it }
        if (Pos >= FormEnd) and (Id3Pos > 0) then Break;
      end;

      if (FSampleRate = 0) or (FChannels = 0) then Exit(False);
      if Id3Pos > 0 then ReadId3(Id3Pos, Id3Size);

      fMediaProperty.Sampling    := FSampleRate;
      fMediaProperty.BitRate     := (FSampleRate * FChannels) div 1000;
      fMediaProperty.ChannelMode := DecodeChannelNumber(FChannels);
      fMediaProperty.BitDepth    := 1;
      fMediaProperty.Channels    := FChannels;
      Result := True;
    except
      Result := False;
    end;
  finally
    if Assigned(fStream) then
      FreeAndNil(fStream);
  end;
end;

procedure WriteU64BE(S: TStream; V: int64);
var
  B: array[0..7] of byte;
  I: integer;
begin
  for I := 7 downto 0 do
  begin
    B[I] := byte(V and $FF);
    V := V shr 8;
  end;
  S.WriteBuffer(B, 8);
end;

procedure WriteId(S: TStream; const Id: string);
var
  B: array[0..3] of ansichar;
  I: integer;
begin
  for I := 0 to 3 do
    if I < Length(Id) then B[I] := Id[I + 1] else B[I] := ' ';
  S.WriteBuffer(B, 4);
end;

function TDffTagReader.SaveToFile(const AFileName: TFileName): boolean;
var
  Src, Dst: TStream;
  Tag: TMemoryStream;
  Id: string;
  FormSize, ChunkSize, Pos, FormEnd, Copied: int64;
  Pad: byte;
begin
  Result := False;
  if FTagTruncated or (Assigned(fTags) and (fTags.HasSkippedFrames or fTags.HasUnreadableData)) then Exit(False);
  Src := nil;
  Dst := nil;
  Tag := nil;
  try
    try
      Src := AuOpenFile(FileName, fmOpenRead or fmShareDenyNone);
      if (not ReadId(Src, Id)) or (Id <> 'FRM8') then Exit(False);
      if not ReadU64BE(Src, FormSize) then Exit(False);
      if (not ReadId(Src, Id)) or (Id <> 'DSD ') then Exit(False);
      FormEnd := 12 + FormSize;
      if FormEnd > Src.Size then FormEnd := Src.Size;
      { the new tag first: a frame that cannot be written stops the save }
      Tag := TMemoryStream.Create;
      if Assigned(fTags) and ((fTags.Count > 0) or fTags.HasRawForWrite) then
      begin
        fTags.Padding := 0;
        fTags.WriteToStream(Tag);
        if fTags.LastWriteDroppedFrames then Exit(False);
      end;
      Dst := AuOpenFile(AFileName, fmCreate or fmOpenReadWrite);
      WriteId(Dst, 'FRM8');
      WriteU64BE(Dst, 0);                // set below
      WriteId(Dst, 'DSD ');
      { the chunks of the container, without the old tag }
      Pos := 16;
      while Pos + 12 <= FormEnd do
      begin
        Src.Position := Pos;
        if not (ReadId(Src, Id) and ReadU64BE(Src, ChunkSize)) then Exit(False);
        if (ChunkSize < 0) or (Pos + 12 + ChunkSize > Src.Size) then Exit(False);   // damaged: keep the file
        if Id <> 'ID3 ' then
        begin
          Src.Position := Pos;
          Copied := 12 + ChunkSize + (ChunkSize and 1);
          if Pos + Copied > Src.Size then Copied := 12 + ChunkSize;
          Dst.CopyFrom(Src, Copied);
          if Copied < 12 + ChunkSize + (ChunkSize and 1) then
          begin
            Pad := 0;
            Dst.WriteBuffer(Pad, 1);
          end;
        end;
        Pos := Pos + 12 + ChunkSize + (ChunkSize and 1);
      end;
      { the new tag at the end of the container }
      if Tag.Size > 0 then
      begin
        WriteId(Dst, 'ID3 ');
        WriteU64BE(Dst, Tag.Size);
        Tag.Position := 0;
        Dst.CopyFrom(Tag, Tag.Size);
        if Odd(Tag.Size) then
        begin
          Pad := 0;
          Dst.WriteBuffer(Pad, 1);
        end;
      end;
      FormSize := Dst.Size - 12;
      { after the container: an old outside tag goes, anything else stays }
      Pos := FormEnd;
      if Pos + 12 <= Src.Size then
      begin
        Src.Position := Pos;
        if ReadId(Src, Id) and (Id = 'ID3 ') and ReadU64BE(Src, ChunkSize) and (ChunkSize >= 0) then
          Pos := Pos + 12 + ChunkSize + (ChunkSize and 1);
      end;
      if Pos < Src.Size then
      begin
        Src.Position := Pos;
        Dst.CopyFrom(Src, Src.Size - Pos);
      end;
      Dst.Position := 4;
      WriteU64BE(Dst, FormSize);
      Result := True;
    except
      Result := False;
    end;
  finally
    Tag.Free;
    Dst.Free;
    Src.Free;
  end;
end;

function TDffTagReader.isUpdateable: boolean;
begin
  Result := True;
end;

initialization
  RegisterTagReader(DffFileMask, TDffTagReader);

end.
