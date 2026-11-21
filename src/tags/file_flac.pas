{
This file is part of OvoTag
Copyright (C) 2011 Marco Caselli

OvoTag is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
}
{
  AulumicTag - modified for Aulumic by André Lubke, 2026.
  AulumicTag is a fork of OvoTag (C) 2011 Marco Caselli; see README.md.
  Changes:
    Robust metadata block parsing (bounded blocks, prepended ID3 tags),
    writing of picture blocks, no save when comments or pictures were only
    partly read.
}
{$I ovotag.inc}
unit file_flac;

interface

uses
  Classes, SysUtils, AudioTag, baseTag, tag_Vorbis;

const
  FlacFileMask: string = '*.flac;';

type
  { TFlacReader }
  TFlacReader = class(TTagReader)
  private
    fTags: TVorbisTags;
    FSampleRate: integer;
    FSamples: int64;
    FChannels: byte;
    FBitsPerSample: byte;
    fMediaProperty: TMediaProperty;
    // True when a picture block could not be read or the file
    // has more than one comment block. SaveToFile then refuses to save, because
    // the old picture / comment blocks are replaced by what was read.
    FReadIncomplete: boolean;
    FLeadingData: boolean;
  protected
    function GetDuration: int64; override;
    function GetTags: TTags; override;
    function DumpInfo: TMediaProperty; override;
  public
    function LoadFromFile(const AFileName: Tfilename): boolean; override;
    function SaveToFile(const AFileName: Tfilename): boolean; override;
    function isUpdateable: boolean; override;
    // True when the file has something in front of its FLAC data (an ID3v2
    // tag, as some programs write it). SaveToFile writes the FLAC data only.
    property HasLeadingData: boolean read FLeadingData;
  end;

implementation

uses
  CommonFunctions, AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  FLAC_IDENTIFIER           = 'fLaC';
  BLOCK_TYPE_VORBIS_COMMENT = 4;
  BLOCK_TYPE_PICTURE        = 6;
  MAX_FLAC_BLOCK_SIZE       = $FFFFFF; // 24-bit FLAC block size limit (16,777,215 bytes)

type
  TMetaDataBlockHeader = array[1..4] of byte;

  TFlacHeader = packed record
    Marker: array[1..4] of ansichar;
    MetaDataBlockHeader: TMetaDataBlockHeader;
    StreamInfo: array[1..18] of byte;
    MD5Sign: array[1..16] of byte;
  end;

// =============================================================================
// In-Memory Hex Scanner with STREAMINFO Header Verification
// Bypasses any prepended ID3 tags or custom padding, and verifies that the
// 'fLaC' marker is immediately followed by a 34-byte STREAMINFO block header
// ((Byte4 and $7F) = 0, Length = 0x000022) so false 'fLaC' bytes inside a
// corrupt ID3 tag can never be mistaken for the start of the FLAC stream!
// =============================================================================
function SkipID3AndFindFlacMarker(Stream: TStream): Boolean;
var
  ID3Header: array[0..9] of Byte;
  TagSize: Integer;
  Buf: array[0..4095] of Byte;
  BytesRead, I: Integer;
  MaxSearch: Integer;
  StartPos: Int64;
begin
  Result          := False;
  Stream.Position := 0;
  if Stream.Size < SizeOf(TFlacHeader) then
    Exit;

  // 1. Check for and skip ID3v2 safely
  Stream.Read(ID3Header[0], 10);
  if (ID3Header[0] = $49) and (ID3Header[1] = $44) and (ID3Header[2] = $33) then
  begin
    TagSize := (Integer(ID3Header[6]) shl 21) or (Integer(ID3Header[7]) shl 14) or
               (Integer(ID3Header[8]) shl 7) or Integer(ID3Header[9]);
    if (10 + Int64(TagSize)) < Stream.Size then
      Stream.Position := 10 + Int64(TagSize)
    else
      Stream.Position := 0;
  end
  else
  begin
    Stream.Position := 0;
  end;

  // 2. Perform a fast RAM scan for 'fLaC' + 34-byte STREAMINFO header
  MaxSearch := 128 * 1024;
  while MaxSearch > 0 do
  begin
    StartPos  := Stream.Position;
    BytesRead := Stream.Read(Buf[0], SizeOf(Buf));
    if BytesRead < 8 then
      Exit;

    for I := 0 to BytesRead - 8 do
    begin
      if (Buf[I] = Ord('f')) and (Buf[I + 1] = Ord('L')) and
         (Buf[I + 2] = Ord('a')) and (Buf[I + 3] = Ord('C')) and
         ((Buf[I + 4] and $7F) = 0) and
         (Buf[I + 5] = 0) and (Buf[I + 6] = 0) and (Buf[I + 7] = 34) then
      begin
        Stream.Position := StartPos + I;
        Result          := True;
        Exit;
      end;
    end;

    if BytesRead < SizeOf(Buf) then
      Exit;

    // Rewind 7 bytes to catch 8-byte signatures split across 4KB buffer boundaries
    Stream.Position := Stream.Position - 7;
    Dec(MaxSearch, BytesRead - 7);
  end;
end;

{ TFlacReader }

function TFlacReader.GetDuration: int64;
begin
  if (FSampleRate > 0) and (FSamples > 0) then
    Result := Trunc((Double(FSamples) / Double(FSampleRate)) * 1000.0)
  else
    Result := 0;
end;

function TFlacReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TVorbisTags.Create;
  Result := fTags;
end;

function TFlacReader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TFlacReader.LoadFromFile(const AFileName: Tfilename): boolean;
var
  fStream: TFileStream;
  BlockMem: TMemoryStream;
  Header: TFlacHeader;
  BlockHeader: TMetaDataBlockHeader;
  BlockLength: integer;
  BlockType: integer;
  BlockStart: Int64;
  DurMS: Int64;
  VorbisBlocks: Integer;
begin
  inherited LoadFromFile(AFileName);
  Result          := False;
  FSampleRate     := 0;
  FSamples        := 0;
  FChannels       := 0;
  FBitsPerSample  := 0;
  FReadIncomplete := False;
  FLeadingData    := False;
  VorbisBlocks    := 0;
  fMediaProperty  := Default(TMediaProperty);

  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TVorbisTags.Create;

  fStream := nil;
  try
    try
      fStream := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);

      if not SkipID3AndFindFlacMarker(fStream) then
        Exit(False);
      FLeadingData := fStream.Position > 0;

      if fStream.Read(Header, SizeOf(Header)) < SizeOf(Header) then
        Exit(False);

      if Header.Marker <> FLAC_IDENTIFIER then
        Exit(False);

      with Header do
      begin
        // 1. Channels (3 bits)
        FChannels      := ((StreamInfo[13] shr 1) and $07) + 1;

        // 2. Sample Rate (20 bits)
        FSampleRate    := (Integer(StreamInfo[11]) shl 12) or
                          (Integer(StreamInfo[12]) shl 4) or
                          (StreamInfo[13] shr 4);

        // 3. Bits Per Sample (5 bits)
        FBitsPerSample := (((StreamInfo[13] and $01) shl 4) or (StreamInfo[14] shr 4)) + 1;

        // 4. Total Samples (36 bits)
        FSamples       := (Int64(StreamInfo[14] and $0F) shl 32) or
                          (Int64(StreamInfo[15]) shl 24) or
                          (Int64(StreamInfo[16]) shl 16) or
                          (Int64(StreamInfo[17]) shl 8) or
                          Int64(StreamInfo[18]);
      end;

      if (Header.MetaDataBlockHeader[1] and $80) <> 0 then
      begin
        Result := True;
        Exit;
      end;

      repeat
        if fStream.Read(BlockHeader, SizeOf(BlockHeader)) < SizeOf(BlockHeader) then
          Break;

        BlockType   := (BlockHeader[1] and $7F);
        BlockLength := (Integer(BlockHeader[2]) shl 16) or
                       (Integer(BlockHeader[3]) shl 8) or
                       Integer(BlockHeader[4]);
        BlockStart  := fStream.Position;

        // Prevent corrupted block lengths from seeking past EOF!
        if (BlockLength < 0) or ((BlockStart + BlockLength) > fStream.Size) then
          Break;

        // Isolate Vorbis Comment and Picture blocks inside a bounded TMemoryStream
        // of exact BlockLength bytes so corrupt internal lengths can never read
        // past the block into FLAC audio frames!
        case BlockType of
          BLOCK_TYPE_VORBIS_COMMENT:
          begin
            // A second comment block would replace the first in
            // memory (ReadFromStream clears), so its comments would be lost
            Inc(VorbisBlocks);
            if VorbisBlocks > 1 then
              FReadIncomplete := True;
            if BlockLength > 0 then
            begin
              BlockMem := TMemoryStream.Create;
              try
                BlockMem.CopyFrom(fStream, BlockLength);
                BlockMem.Position := 0;
                fTags.ReadFromStream(BlockMem);
              finally
                BlockMem.Free;
              end;
            end;
          end;
          BLOCK_TYPE_PICTURE:
          begin
            // text only: the picture stays in the file (and
            // this reader must never save: it would drop the pictures)
            if FTextOnly then
              FReadIncomplete := True
            else if BlockLength > 0 then
            begin
              BlockMem := TMemoryStream.Create;
              try
                BlockMem.CopyFrom(fStream, BlockLength);
                BlockMem.Position := 0;
                // A picture that cannot be read would be dropped
                // on save (all old picture blocks are replaced)
                if not fTags.ReadImageFromStream(BlockMem) then
                  FReadIncomplete := True;
              finally
                BlockMem.Free;
              end;
            end;
          end;
        end;

        fStream.Position := BlockStart + BlockLength;

      until (BlockHeader[1] and $80) <> 0;

      Result := True;
    except
      on E: Exception do
      begin
        Result := False;
      end;
    end;
  finally
    if Assigned(fStream) then
    begin
      DurMS := GetDuration;
      if Result and (DurMS > 0) and (fStream.Size > fStream.Position) then
        fMediaProperty.BitRate := Round(((fStream.Size - fStream.Position) * 8.0) / Double(DurMS))
      else
        fMediaProperty.BitRate := 0;

      fMediaProperty.Sampling    := FSampleRate;
      fMediaProperty.ChannelMode := DecodeChannelNumber(FChannels);
      fMediaProperty.BitDepth    := FBitsPerSample;
      fMediaProperty.Channels    := FChannels;
      FreeAndNil(fStream);
    end;
  end;
end;

function TFlacReader.SaveToFile(const AFileName: Tfilename): boolean;
type
  TFlacBlock = record
    BType: Byte;
    Data: TMemoryStream;
  end;
var
  SourceStream, DestStream: TFileStream;
  Header: TFlacHeader;
  BlockHeader: TMetaDataBlockHeader;
  BlockType, BlockLength, I, NewIdx: integer;
  IsLastBlock: boolean;
  Blocks: array of TFlacBlock;
  Img: TImageElement;
  L: Cardinal;
  MimeA, DescA: AnsiString;
begin
  Result       := False;
  SourceStream := nil;
  DestStream   := nil;
  SetLength(Blocks, 0);

  // Never rewrite a file whose comments or pictures were only
  // partly read: everything that was not read would be lost
  if FReadIncomplete or (Assigned(fTags) and fTags.ReadIncomplete) then
    Exit(False);

  try
    try
      SourceStream := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);
      DestStream   := TFileStream.Create(LongPath(AFileName), fmCreate or fmOpenReadWrite);

      if not SkipID3AndFindFlacMarker(SourceStream) then
        Exit(False);

      if SourceStream.Read(Header, SizeOf(Header)) < SizeOf(Header) then
        Exit(False);

      if Header.Marker <> FLAC_IDENTIFIER then
        Exit(False);

      // Support saving tags to untagged FLAC files where STREAMINFO
      // had the is_last ($80) flag set! Clear $80 on STREAMINFO because we will
      // always write at least a VORBIS_COMMENT block after it.
      IsLastBlock := (Header.MetaDataBlockHeader[1] and $80) <> 0;
      Header.MetaDataBlockHeader[1] := Header.MetaDataBlockHeader[1] and $7F;

      DestStream.WriteBuffer(Header, SizeOf(Header));

      // 1. Read existing metadata blocks (if any), dropping old Comments and Pictures
      if not IsLastBlock then
      begin
        repeat
          if SourceStream.Read(BlockHeader, SizeOf(BlockHeader)) < SizeOf(BlockHeader) then
            Exit(False);

          BlockType   := (BlockHeader[1] and $7F);
          IsLastBlock := (BlockHeader[1] and $80) <> 0;
          BlockLength := (Integer(BlockHeader[2]) shl 16) or
                         (Integer(BlockHeader[3]) shl 8) or
                         Integer(BlockHeader[4]);

          if (BlockLength < 0) or ((SourceStream.Position + BlockLength) > SourceStream.Size) then
            Exit(False);

          if (BlockType <> BLOCK_TYPE_VORBIS_COMMENT) and (BlockType <> BLOCK_TYPE_PICTURE) then
          begin
            // Register the new block in Blocks[] BEFORE CopyFrom so
            // the finally block always frees Data if CopyFrom raises an exception!
            NewIdx := Length(Blocks);
            SetLength(Blocks, NewIdx + 1);
            Blocks[NewIdx].BType := BlockType;
            Blocks[NewIdx].Data  := TMemoryStream.Create;
            if BlockLength > 0 then
              Blocks[NewIdx].Data.CopyFrom(SourceStream, BlockLength);
          end
          else
          begin
            SourceStream.Seek(BlockLength, soFromCurrent);
          end;
        until IsLastBlock;
      end;

      // 2. Generate the new Vorbis Comment Block
      if not Assigned(fTags) then
        fTags := TVorbisTags.Create;

      NewIdx := Length(Blocks);
      SetLength(Blocks, NewIdx + 1);
      Blocks[NewIdx].BType := BLOCK_TYPE_VORBIS_COMMENT;
      Blocks[NewIdx].Data  := TMemoryStream.Create;
      fTags.WriteToStream(Blocks[NewIdx].Data);

      // 3. Generate the new Picture Blocks
      for I := 0 to fTags.ImageCount - 1 do
      begin
        Img := fTags.Images[I];
        if (not Assigned(Img)) or (not Assigned(Img.Image)) or (Img.Image.Size <= 0) then
          Continue;

        // Silently skip any picture block that would overflow the
        // 24-bit FLAC block header ($FFFFFF) so ReplayGain / text tag saves
        // still succeed without failing!
        if Img.Image.Size > (MAX_FLAC_BLOCK_SIZE - 1024) then
          Continue;

        NewIdx := Length(Blocks);
        SetLength(Blocks, NewIdx + 1);
        Blocks[NewIdx].BType := BLOCK_TYPE_PICTURE;
        Blocks[NewIdx].Data  := TMemoryStream.Create;

        L := SwapEndian(Cardinal(Img.PictureType));
        Blocks[NewIdx].Data.WriteBuffer(L, 4);

        MimeA := AnsiString(Img.MIMEType);
        L     := SwapEndian(Cardinal(Length(MimeA)));
        Blocks[NewIdx].Data.WriteBuffer(L, 4);

        if Length(MimeA) > 0 then
          Blocks[NewIdx].Data.WriteBuffer(MimeA[1], Length(MimeA));

        DescA := UTF8Encode(Img.Description);
        L     := SwapEndian(Cardinal(Length(DescA)));
        Blocks[NewIdx].Data.WriteBuffer(L, 4);

        if Length(DescA) > 0 then
          Blocks[NewIdx].Data.WriteBuffer(DescA[1], Length(DescA));

        L := 0;
        Blocks[NewIdx].Data.WriteBuffer(L, 4);
        Blocks[NewIdx].Data.WriteBuffer(L, 4);
        Blocks[NewIdx].Data.WriteBuffer(L, 4);
        Blocks[NewIdx].Data.WriteBuffer(L, 4);

        L := SwapEndian(Cardinal(Img.Image.Size));
        Blocks[NewIdx].Data.WriteBuffer(L, 4);

        Img.Image.Position := 0;
        Blocks[NewIdx].Data.CopyFrom(Img.Image, Img.Image.Size);

        // A block of more than 16 MB cannot be written: the picture is left out
        if Blocks[NewIdx].Data.Size > MAX_FLAC_BLOCK_SIZE then
        begin
          Blocks[NewIdx].Data.Free;
          Blocks[NewIdx].Data := nil;
          SetLength(Blocks, NewIdx);
        end;
      end;

      // 4. Write all blocks to the new file
      for I := 0 to High(Blocks) do
      begin
        BlockLength := Blocks[I].Data.Size;
        if BlockLength > MAX_FLAC_BLOCK_SIZE then
          Exit(False);

        BlockHeader[1] := Blocks[I].BType;
        if I = High(Blocks) then
          BlockHeader[1] := BlockHeader[1] or $80;

        BlockHeader[2] := (BlockLength and $FF0000) shr 16;
        BlockHeader[3] := (BlockLength and $00FF00) shr 8;
        BlockHeader[4] := (BlockLength and $0000FF);

        DestStream.WriteBuffer(BlockHeader, SizeOf(BlockHeader));
        if BlockLength > 0 then
        begin
          Blocks[I].Data.Position := 0;
          DestStream.CopyFrom(Blocks[I].Data, BlockLength);
        end;
      end;

      // 5. Copy the raw audio data payload
      if SourceStream.Size > SourceStream.Position then
        DestStream.CopyFrom(SourceStream, SourceStream.Size - SourceStream.Position);

      Result := True;
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

    for I := 0 to High(Blocks) do
    begin
      if Assigned(Blocks[I].Data) then
      begin
        Blocks[I].Data.Free;
        Blocks[I].Data := nil;
      end;
    end;
    SetLength(Blocks, 0);
  end;
end;

function TFlacReader.isUpdateable: boolean;
begin
  Result := True;
end;

initialization
  RegisterTagReader(FlacFileMask, TFlacReader);

end.
