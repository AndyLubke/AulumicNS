{
  OvoTag native DSF (DSD Stream File) handler.
  Reads DSD audio properties and utilizes OvoTag's existing ID3v2
  class to parse the metadata stored at the end of the file.
}
{
  AulumicTag - written for Aulumic by André Lubke, 2026.
  Part of AulumicTag, a fork of OvoTag (C) 2011 Marco Caselli; see README.md.
  Changes:
    New in AulumicTag: reading and writing ID3v2 tags in DSF (DSD Stream File)
    files, with validation so the audio data is never cut off.
}
unit file_dsf;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, AudioTag, baseTag, tag_id3v2;

const
  DsfFileMask: string = '*.dsf;';

type
  { TDsfReader }

  TDsfReader = class(TTagReader)
  private
    fTags: TID3Tags;
    FSampleRate: cardinal;
    FTotalSamples: int64;
    FChannels: cardinal;
    FPointerToID3: int64;
    // Tracks the physical end of the 'data' chunk so a
    // corrupt FPointerToID3 can never point inside the audio payload!
    FDataEndOffset: int64;
    // True when the ID3 tag was larger than MAX_DSF_ID3_SIZE and
    // therefore only partially (or not) loaded; SaveToFile then refuses to save.
    FTagTruncated: boolean;
    fMediaProperty: TMediaProperty;
  protected
    function GetDuration: int64; override;
    function GetTags: TTags; override;
    function DumpInfo: TMediaProperty; override;
  public
    function LoadFromFile(const AFileName: TFileName): boolean; override;
    function SaveToFile(const AFileName: TFileName): boolean; override;
    function isUpdateable: boolean; override;
  end;

implementation

uses
  CommonFunctions, AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  MAX_DSF_ID3_SIZE = 64 * 1024 * 1024; // 64 MB safety cap for embedded ID3v2 block

{ TDsfReader }

function TDsfReader.GetDuration: int64;
begin
  Result := 0;
  if (FSampleRate > 0) and (FTotalSamples > 0) then
    Result := Trunc((FTotalSamples / FSampleRate) * 1000);
end;

function TDsfReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TID3Tags.Create;
  Result := fTags;
end;

function TDsfReader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TDsfReader.LoadFromFile(const AFileName: TFileName): boolean;
var
  fStream: TFileStream;
  MemStream: TMemoryStream;
  ChunkID: array[0..3] of ansichar;
  ID3Header: array[0..9] of byte;
  TagSize, TrailingTagSize: cardinal;
  DSDStart, CopyLen, MinValidID3Offset: int64;
  ChunkSize, TotalSize, SubChunkSize, ScanPos: int64;
begin
  inherited LoadFromFile(AFileName);
  Result         := False;
  FPointerToID3  := 0;
  FDataEndOffset := 0;
  FTagTruncated  := False;
  FSampleRate    := 0;
  FTotalSamples  := 0;
  FChannels      := 0;
  fMediaProperty := Default(TMediaProperty);

  // Cleanly recreate fTags if this reader object is reused
  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TID3Tags.Create;

  fStream := nil;
  try
    try
      fStream := TFileStream.Create(LongPath(AFileName), fmOpenRead or fmShareDenyNone);

      if fStream.Read(ChunkID, 4) < 4 then
        Exit(False);

      if ChunkID = 'ID3' then
      begin
        fStream.Position := 0;
        if fStream.Read(ID3Header, 10) = 10 then
        begin
          TagSize := (Cardinal(ID3Header[6]) shl 21) or
                     (Cardinal(ID3Header[7]) shl 14) or
                     (Cardinal(ID3Header[8]) shl 7) or
                     Cardinal(ID3Header[9]);
          if (10 + Int64(TagSize) + 4) <= fStream.Size then
          begin
            fStream.Position := 10 + Int64(TagSize);
            if fStream.Read(ChunkID, 4) < 4 then
              Exit(False);
          end
          else
            Exit(False);
        end
        else
          Exit(False);
      end;

      if ChunkID <> 'DSD ' then
        Exit(False);

      DSDStart := fStream.Position - 4;

      if fStream.Read(ChunkSize, 8) < 8 then
        Exit(False);
      if fStream.Read(TotalSize, 8) < 8 then
        Exit(False);
      if fStream.Read(FPointerToID3, 8) < 8 then
        Exit(False);

      if fStream.Size >= DSDStart + 72 then
      begin
        fStream.Position := DSDStart + 52;
        fStream.Read(FChannels, 4);

        fStream.Position := DSDStart + 56;
        fStream.Read(FSampleRate, 4);

        fStream.Position := DSDStart + 64;
        fStream.Read(FTotalSamples, 8);
      end;

      // Locate the 'data' chunk header and record its end
      // offset so FPointerToID3 is verified to sit at or past the audio data!
      if (ChunkSize >= 28) and ((DSDStart + ChunkSize + 12) <= fStream.Size) then
      begin
        ScanPos := DSDStart + ChunkSize;
        while (ScanPos + 12) <= fStream.Size do
        begin
          fStream.Position := ScanPos;
          if fStream.Read(ChunkID, 4) < 4 then
            Break;
          if fStream.Read(SubChunkSize, 8) < 8 then
            Break;
          if SubChunkSize < 12 then
            Break;

          if ChunkID = 'data' then
          begin
            FDataEndOffset := ScanPos + SubChunkSize;
            if FDataEndOffset > fStream.Size then
              FDataEndOffset := fStream.Size;
            Break;
          end;

          ScanPos := ScanPos + SubChunkSize;
        end;
      end;

      fMediaProperty.Sampling    := FSampleRate;
      fMediaProperty.BitRate     := (FSampleRate * FChannels) div 1000;
      fMediaProperty.ChannelMode := DecodeChannelNumber(FChannels);
      fMediaProperty.BitDepth    := 1;
      fMediaProperty.Channels    := FChannels;

      MinValidID3Offset := DSDStart + 92;
      if FDataEndOffset > MinValidID3Offset then
        MinValidID3Offset := FDataEndOffset;

      // Validate that FPointerToID3 points past the DSD/fmt/data chunks
      // and actually starts with an 'ID3' header before copying to RAM or trusting it for SaveToFile!
      if (FPointerToID3 >= MinValidID3Offset) and (FPointerToID3 + 10 <= fStream.Size) then
      begin
        fStream.Position := FPointerToID3;
        if (fStream.Read(ID3Header, 10) = 10) and
           (ID3Header[0] = Ord('I')) and (ID3Header[1] = Ord('D')) and (ID3Header[2] = Ord('3')) then
        begin
          TrailingTagSize := (Cardinal(ID3Header[6]) shl 21) or
                             (Cardinal(ID3Header[7]) shl 14) or
                             (Cardinal(ID3Header[8]) shl 7) or
                             Cardinal(ID3Header[9]);
          CopyLen := 10 + Int64(TrailingTagSize);
          if CopyLen > (fStream.Size - FPointerToID3) then
            CopyLen := fStream.Size - FPointerToID3;
          if CopyLen > MAX_DSF_ID3_SIZE then
          begin
            CopyLen       := MAX_DSF_ID3_SIZE;
            FTagTruncated := True;
          end;

          fStream.Position := FPointerToID3;
          MemStream := TMemoryStream.Create;
          try
            MemStream.CopyFrom(fStream, CopyLen);
            MemStream.Position := 0;
            fTags.ReadFromStream(MemStream);
          finally
            MemStream.Free;
          end;
        end
        else
        begin
          // Invalid pointer: reset to 0 so SaveToFile never truncates audio!
          FPointerToID3 := 0;
        end;
      end
      else
      begin
        FPointerToID3 := 0;
      end;

      // If no trailing tag was found, but a prepended ID3 tag exists at byte 0,
      // only copy DSDStart bytes (the ID3 block) instead of the entire multi-hundred-MB DSF file!
      // A prepended tag larger than the cap is not loaded at all; flag it so
      // SaveToFile (which drops the prepended tag) never discards it unread
      if (FPointerToID3 = 0) and (DSDStart > MAX_DSF_ID3_SIZE) then
        FTagTruncated := True;

      if (FPointerToID3 = 0) and (DSDStart >= 10) and (DSDStart <= MAX_DSF_ID3_SIZE) then
      begin
        fStream.Position := 0;
        MemStream := TMemoryStream.Create;
        try
          MemStream.CopyFrom(fStream, DSDStart);
          MemStream.Position := 0;
          fTags.ReadFromStream(MemStream);
        finally
          MemStream.Free;
        end;
      end;

      Result := True;
    except
      Result := False;
    end;
  finally
    if Assigned(fStream) then
      FreeAndNil(fStream);
  end;
end;

function TDsfReader.SaveToFile(const AFileName: TFileName): boolean;
var
  SourceStream, DestStream: TFileStream;
  ChunkID: array[0..3] of ansichar;
  ID3Header: array[0..9] of byte;
  TagSize: cardinal;
  AudioDataSize, NewTotalSize, NewPointerToID3, StartOffset, MinEndOffset: int64;
  MemoryStream: TMemoryStream;
begin
  Result       := False;
  SourceStream := nil;
  DestStream   := nil;
  MemoryStream := nil;

  // Never rewrite a tag that was only partially loaded
  // (oversized frames skipped, or the tag exceeded the 64 MB read cap)
  if FTagTruncated or (Assigned(fTags) and (fTags.HasSkippedFrames or fTags.HasUnreadableData)) then
    Exit(False);

  try
    try
      SourceStream := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);
      DestStream   := TFileStream.Create(LongPath(AFileName), fmCreate or fmOpenReadWrite);
      MemoryStream := TMemoryStream.Create;

      StartOffset := 0;
      if SourceStream.Read(ChunkID, 4) = 4 then
      begin
        if ChunkID = 'ID3' then
        begin
          SourceStream.Position := 0;
          if SourceStream.Read(ID3Header, 10) = 10 then
          begin
            TagSize := (Cardinal(ID3Header[6]) shl 21) or
                       (Cardinal(ID3Header[7]) shl 14) or
                       (Cardinal(ID3Header[8]) shl 7) or
                       Cardinal(ID3Header[9]);
            if (10 + Int64(TagSize)) < SourceStream.Size then
              StartOffset := 10 + Int64(TagSize);
          end;
        end;
      end;

      SourceStream.Position := StartOffset;

      // Verify that StartOffset actually points to the 'DSD ' chunk!
      if (SourceStream.Read(ChunkID, 4) = 4) and (ChunkID = 'DSD ') then
      begin
        // Require FPointerToID3 to be >= FDataEndOffset so
        // saving tags can never cut off the end of the 'data' chunk!
        MinEndOffset := StartOffset + 92;
        if FDataEndOffset > MinEndOffset then
          MinEndOffset := FDataEndOffset;

        if (FPointerToID3 >= MinEndOffset) and (FPointerToID3 <= SourceStream.Size) then
          AudioDataSize := FPointerToID3 - StartOffset
        else
          AudioDataSize := SourceStream.Size - StartOffset;

        SourceStream.Position := StartOffset;
        DestStream.CopyFrom(SourceStream, AudioDataSize);

        if Assigned(fTags) and ((fTags.Count > 0) or fTags.HasRawForWrite) then
        begin
          // Zero padding on trailing DSF ID3 tags to avoid dead bloat
          fTags.Padding := 0;
          fTags.WriteToStream(MemoryStream);
          // Abort if any frame could not be written
          if fTags.LastWriteDroppedFrames then
            Exit(False);
        end;

        if MemoryStream.Size > 0 then
        begin
          NewPointerToID3       := DestStream.Position;
          MemoryStream.Position := 0;
          DestStream.CopyFrom(MemoryStream, MemoryStream.Size);
        end
        else
        begin
          NewPointerToID3 := 0;
        end;

        NewTotalSize := DestStream.Size;

        DestStream.Position := 12;
        DestStream.WriteBuffer(NewTotalSize, 8);
        DestStream.Position := 20;
        DestStream.WriteBuffer(NewPointerToID3, 8);

        Result := True;
      end;
    except
      on E: Exception do
      begin
        Result := False;
      end;
    end;
  finally
    if Assigned(SourceStream) then
      FreeAndNil(SourceStream);
    if Assigned(DestStream) then
      FreeAndNil(DestStream);
    if Assigned(MemoryStream) then
      FreeAndNil(MemoryStream);
  end;
end;

function TDsfReader.isUpdateable: boolean;
begin
  Result := True;
end;

initialization
  RegisterTagReader(DsfFileMask, TDsfReader);

end.
