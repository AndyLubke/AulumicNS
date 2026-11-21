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
    Reading and writing of the ID3v2 tag chunk with RIFF validation (pad
    bytes, chunk IDs, 4 GB limit, data chunk always preserved, trailing bytes
    kept).
}
{$I ovotag.inc}
unit file_wave;

interface

uses
  Classes, SysUtils, AudioTag, baseTag, tag_id3v2;

const
  WaveFileMask: string = '*.wav;';

type
  WAVHeader = packed record
    { RIFF file header }
    RIFFHeader: array [1..4] of ansichar; { Must be "RIFF" }
    FileSize: cardinal;                   { Must be "RealFileSize - 8" }
    WAVEHeader: array [1..4] of ansichar; { Must be "WAVE" }
  end;

  ChunkHeader = packed record
    ChunkName: array [1..4] of ansichar;
    ChunkSize: cardinal;
  end;

  FmtHeader = packed record
    FormatID: word;
    ChannelNumber: word;
    SampleRate: integer;
    BytesPerSecond: integer;
    BlockAlign: word;
    BitsPerSample: word;
  end;

  { TWaveReader }

  TWaveReader = class(TTagReader)
  private
    fTags: TID3Tags;
    fMediaProperty: TMediaProperty;
    fFileSize: int64;
    fmt: FmtHeader;
    DataPos: int64;
    // Int64: the size of the data chunk, clamped to the length of the file
    SampleNumber: int64;
    FPointerToID3: int64;
    // True when the 'id3 ' chunk exceeded MAX_WAV_ID3_SIZE and was
    // only partially loaded; SaveToFile then refuses to rewrite the file.
    FTagTruncated: boolean;
  protected
    function GetDuration: int64; override;
    function GetTags: TTags; override;
    function DumpInfo: TMediaProperty; override;
  public
    function LoadFromFile(const AFileName: Tfilename): boolean; override;
    function SaveToFile(const AFileName: Tfilename): boolean; override;
    function isUpdateable: boolean; override;
  end;

implementation

uses
  CommonFunctions, AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  MAX_WAV_ID3_SIZE  = 64 * 1024 * 1024; // 64 MB safety cap for embedded ID3 chunk
  MAX_RIFF_WAV_SIZE = Int64($FFFFFFFF); // 32-bit classic RIFF size ceiling

// Validates that a 4-byte RIFF FourCC contains printable ASCII
function IsValidRiffChunkID(const AName: array of AnsiChar): boolean;
var
  I: Integer;
begin
  if Length(AName) < 4 then
    Exit(False);
  for I := 0 to 3 do
  begin
    if not (AName[I] in [#32..#126]) then
      Exit(False);
  end;
  Result := True;
end;

{ TWaveReader }

function TWaveReader.GetDuration: int64;
var
  BytesPerSec: Double;
begin
  Result := 0;
  // Guard against division by zero when ChannelNumber or BitsPerSample is 0,
  // and multiply by 1000 before Trunc so sub-second precision is preserved!
  if (SampleNumber > 0) and (fmt.SampleRate > 0) and
     (fmt.ChannelNumber > 0) and (fmt.BitsPerSample > 0) then
  begin
    BytesPerSec := Double(fmt.SampleRate) * Double(fmt.ChannelNumber) * (Double(fmt.BitsPerSample) / 8.0);
    if BytesPerSec > 0 then
      Result := Trunc((Double(SampleNumber) / BytesPerSec) * 1000.0);
  end
  else if (SampleNumber = 0) and (fmt.BytesPerSecond > 0) and (fFileSize > DataPos) then
  begin
    Result := Trunc((Double(fFileSize - DataPos) / Double(fmt.BytesPerSecond)) * 1000.0);
  end;
end;

function TWaveReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TID3Tags.Create;
  Result := fTags;
end;

function TWaveReader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TWaveReader.isUpdateable: boolean;
begin
  Result := True;
end;

function HeaderIsValid(const WAVData: WAVHeader): boolean;
begin
  Result := (WAVData.RIFFHeader = 'RIFF') and (WAVData.WAVEHeader = 'WAVE');
end;

function TWaveReader.LoadFromFile(const AFileName: Tfilename): boolean;
var
  fStream: TFileStream;
  TagMem: TMemoryStream;
  WaveH: WAVHeader;
  Chunk: ChunkHeader;
  FmtReadBytes: Int64;
  TagCopySize: Int64;

  // Case-insensitive chunk finder with printable FourCC
  // validation and missing-pad-byte recovery on odd-sized chunks!
  function FindChunkCI(const aChunk: string): boolean;
  var
    UnpaddedEnd, PaddedEnd: Int64;
    PeekID: array[1..4] of AnsiChar;
    ChunkStr: string;
  begin
    Result := False;
    while (fStream.Position + SizeOf(ChunkHeader)) <= fFileSize do
    begin
      if fStream.Read(Chunk, SizeOf(ChunkHeader)) < SizeOf(ChunkHeader) then
        Exit(False);

      if not IsValidRiffChunkID(Chunk.ChunkName) then
        Exit(False);

      SetString(ChunkStr, PAnsiChar(@Chunk.ChunkName[1]), 4);
      if SameText(ChunkStr, aChunk) then
        Exit(True);

      UnpaddedEnd := fStream.Position + Int64(Chunk.ChunkSize);
      if (UnpaddedEnd < fStream.Position) or (UnpaddedEnd > fFileSize) then
        Exit(False);

      if (Chunk.ChunkSize and 1) <> 0 then
      begin
        PaddedEnd := UnpaddedEnd + 1;
        // Detect non-compliant writers that omitted the RIFF pad byte
        if (UnpaddedEnd + 4) <= fFileSize then
        begin
          fStream.Position := UnpaddedEnd;
          if (fStream.Read(PeekID, 4) = 4) and
             (PeekID[1] <> #0) and IsValidRiffChunkID(PeekID) then
          begin
            fStream.Position := UnpaddedEnd;
            Continue;
          end;
        end;
        if PaddedEnd > fFileSize then
          Exit(False);
        fStream.Position := PaddedEnd;
      end
      else
        fStream.Position := UnpaddedEnd;
    end;
  end;

begin
  inherited LoadFromFile(AFileName);
  Result         := False;
  fMediaProperty := Default(TMediaProperty);
  fmt            := Default(FmtHeader);
  DataPos        := 0;
  SampleNumber   := 0;
  FPointerToID3  := 0;
  FTagTruncated  := False;

  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TID3Tags.Create;

  fStream := nil;
  try
    try
      fStream   := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);
      fFileSize := fStream.Size;

      if fFileSize < SizeOf(WAVHeader) then
        Exit(False);

      if fStream.Read(WaveH, SizeOf(WaveH)) < SizeOf(WaveH) then
        Exit(False);

      if not HeaderIsValid(WaveH) then
        Exit(False);

      // 1. Find the FORMAT chunk
      fStream.Position := 12;
      if FindChunkCI('fmt ') then
      begin
        FmtReadBytes := SizeOf(fmt);
        if Chunk.ChunkSize < FmtReadBytes then
          FmtReadBytes := Chunk.ChunkSize;
        if FmtReadBytes > 0 then
          fStream.Read(fmt, FmtReadBytes);
      end;

      // 2. Find the AUDIO DATA chunk
      fStream.Position := 12;
      if FindChunkCI('data') then
      begin
        DataPos := fStream.Position;
        // Clamp SampleNumber if header size is $FFFFFFFF or exceeds file length
        if (Chunk.ChunkSize = $FFFFFFFF) or ((DataPos + Int64(Chunk.ChunkSize)) > fFileSize) then
          SampleNumber := fFileSize - DataPos
        else
          SampleNumber := Chunk.ChunkSize;
      end;

      fMediaProperty.ChannelMode := DecodeChannelNumber(fmt.ChannelNumber);
      // Compute BitRate in 64-bit Int64 to avoid 32-bit overflow
      if fmt.BytesPerSecond > 0 then
        fMediaProperty.BitRate := (Int64(fmt.BytesPerSecond) * 8) div 1000
      else
        fMediaProperty.BitRate := 0;
      fMediaProperty.Sampling    := fmt.SampleRate;
      fMediaProperty.BitDepth    := fmt.BitsPerSample;
      fMediaProperty.Channels    := fmt.ChannelNumber;

      // 3. Find the ID3 TAG chunk (matches both 'id3 ' and 'ID3 ')
      fStream.Position := 12;
      if FindChunkCI('id3 ') then
      begin
        FPointerToID3 := fStream.Position - SizeOf(ChunkHeader);
        TagCopySize   := Chunk.ChunkSize;
        if (fStream.Position + TagCopySize) > fFileSize then
          TagCopySize := fFileSize - fStream.Position;
        if TagCopySize > MAX_WAV_ID3_SIZE then
        begin
          TagCopySize   := MAX_WAV_ID3_SIZE;
          FTagTruncated := True;
        end;

        // Read the ID3 chunk via a dedicated TMemoryStream so
        // TID3Tags.ReadFromStream starts at Position = 0 regardless of where the
        // chunk sits in the WAV file!
        if TagCopySize >= 10 then
        begin
          TagMem := TMemoryStream.Create;
          try
            TagMem.CopyFrom(fStream, TagCopySize);
            TagMem.Position := 0;
            fTags.ReadFromStream(TagMem);
          finally
            TagMem.Free;
          end;
        end;
      end;

      Result := True;
    except
      on E: Exception do
        Result := False;
    end;
  finally
    if Assigned(fStream) then
      FreeAndNil(fStream);
  end;
end;

function TWaveReader.SaveToFile(const AFileName: Tfilename): boolean;
var
  SourceStream, DestStream: TFileStream;
  MemoryStream: TMemoryStream;
  WaveH: WAVHeader;
  Chunk: ChunkHeader;
  ChunkStr: string;
  ChunkCopyBytes, UnpaddedEnd, RiffLimit: Int64;
  NewRiffSize, TagSize: Cardinal;
  ChunkID: array[0..3] of AnsiChar;
  PeekID: array[1..4] of AnsiChar;
  PadByte: Byte;
  SawDataChunk, HasPadByteInSource: Boolean;
  TrailStart: Int64;
begin
  Result       := False;
  SourceStream := nil;
  DestStream   := nil;
  MemoryStream := nil;
  SawDataChunk := False;

  // Never rewrite a tag that was only partially loaded
  // (oversized frames skipped, or the 'id3 ' chunk exceeded the 64 MB read cap)
  if FTagTruncated or (Assigned(fTags) and (fTags.HasSkippedFrames or fTags.HasUnreadableData)) then
    Exit(False);

  try
    try
      SourceStream := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);
      // Refuse to rewrite WAV files larger than the 4 GB RIFF limit
      if (SourceStream.Size < SizeOf(WAVHeader)) or (SourceStream.Size > (MAX_RIFF_WAV_SIZE + 8)) then
        Exit(False);

      if SourceStream.Read(WaveH, SizeOf(WaveH)) < SizeOf(WaveH) then
        Exit(False);

      if (not HeaderIsValid(WaveH)) or (WaveH.FileSize = $FFFFFFFF) then
        Exit(False);

      DestStream   := TFileStream.Create(LongPath(AFileName), fmCreate or fmOpenReadWrite);
      MemoryStream := TMemoryStream.Create;

      // Bound chunk parsing to the declared RIFF payload
      RiffLimit := Int64(WaveH.FileSize) + 8;
      if (RiffLimit < SizeOf(WAVHeader)) or (RiffLimit > SourceStream.Size) then
        RiffLimit := SourceStream.Size;

      // 1. Write the 12-byte RIFF/WAVE header
      DestStream.WriteBuffer(WaveH, SizeOf(WaveH));

      // Copy all non-ID3 chunks sequentially with strict FourCC & alignment checks
      while (SourceStream.Position + SizeOf(ChunkHeader)) <= RiffLimit do
      begin
        if SourceStream.Read(Chunk, SizeOf(ChunkHeader)) < SizeOf(ChunkHeader) then
          Break;

        // Abort immediately if chunk ID is not printable ASCII
        // (protects against missing pad bytes or corrupt chunk headers!)
        if (not IsValidRiffChunkID(Chunk.ChunkName)) or (Chunk.ChunkSize = $FFFFFFFF) then
          Exit(False);

        SetString(ChunkStr, PAnsiChar(@Chunk.ChunkName[1]), 4);

        UnpaddedEnd := SourceStream.Position + Int64(Chunk.ChunkSize);
        if UnpaddedEnd > SourceStream.Size then
        begin
          // Do not allow a truncated 'data' chunk or malformed chunk to be rewritten
          if SameText(ChunkStr, 'data') then
            Exit(False);
          ChunkCopyBytes := SourceStream.Size - SourceStream.Position;
          UnpaddedEnd    := SourceStream.Size;
        end
        else
          ChunkCopyBytes := Int64(Chunk.ChunkSize);

        // Check if an odd-sized chunk actually has a pad byte in the source file
        HasPadByteInSource := False;
        if (ChunkCopyBytes mod 2) <> 0 then
        begin
          if (UnpaddedEnd + 4) <= SourceStream.Size then
          begin
            SourceStream.Position := UnpaddedEnd;
            if (SourceStream.Read(PeekID, 4) = 4) and
               (PeekID[1] <> #0) and IsValidRiffChunkID(PeekID) then
              HasPadByteInSource := False
            else
              HasPadByteInSource := True;
            SourceStream.Position := UnpaddedEnd - ChunkCopyBytes;
          end
          else if UnpaddedEnd < SourceStream.Size then
            HasPadByteInSource := True;
        end;

        if SameText(ChunkStr, 'id3 ') then
        begin
          // Skip existing 'id3 ' / 'ID3 ' chunk (and its pad byte if present)
          if HasPadByteInSource and ((UnpaddedEnd + 1) <= SourceStream.Size) then
            SourceStream.Position := UnpaddedEnd + 1
          else
            SourceStream.Position := UnpaddedEnd;
        end
        else
        begin
          if SameText(ChunkStr, 'data') then
          begin
            // A 0-byte 'data' chunk is a placeholder written by
            // interrupted/streaming recorders (the audio follows it). Rewriting
            // would discard that audio, so refuse.
            if ChunkCopyBytes = 0 then
              Exit(False);
            SawDataChunk := True;
          end;

          Chunk.ChunkSize := Cardinal(ChunkCopyBytes);
          DestStream.WriteBuffer(Chunk, SizeOf(ChunkHeader));
          if ChunkCopyBytes > 0 then
            DestStream.CopyFrom(SourceStream, ChunkCopyBytes);

          // Always write standard RIFF word-alignment pad byte to DestStream
          if (ChunkCopyBytes mod 2) <> 0 then
          begin
            PadByte := 0;
            if HasPadByteInSource and (SourceStream.Position < SourceStream.Size) then
              SourceStream.Read(PadByte, 1);
            DestStream.WriteBuffer(PadByte, 1);
          end;
        end;
      end;

      // Never overwrite a WAV file if the 'data' chunk was not preserved!
      if not SawDataChunk then
        Exit(False);

      // Bytes after the declared RIFF form (e.g. a trailing ID3v1
      // 'TAG' block or chunks appended without updating the RIFF size) are kept
      // and copied unchanged after the new RIFF form instead of being dropped.
      TrailStart := SourceStream.Position;
      if TrailStart < RiffLimit then
        TrailStart := RiffLimit;

      // 2. Serialize and append the updated ID3v2 tag chunk at the end
      if Assigned(fTags) and ((fTags.Count > 0) or fTags.HasRawForWrite) then
      begin
        fTags.Padding := 0;
        fTags.WriteToStream(MemoryStream);
        // Abort if any frame could not be written
        if fTags.LastWriteDroppedFrames then
          Exit(False);
      end;

      if MemoryStream.Size > 0 then
      begin
        ChunkID := 'id3 ';
        TagSize := Cardinal(MemoryStream.Size);

        DestStream.WriteBuffer(ChunkID, 4);
        DestStream.WriteBuffer(TagSize, 4);

        MemoryStream.Position := 0;
        DestStream.CopyFrom(MemoryStream, TagSize);

        if (TagSize mod 2) <> 0 then
        begin
          PadByte := 0;
          DestStream.WriteBuffer(PadByte, 1);
        end;
      end;

      // Refuse to commit if the new file exceeds the 4 GB RIFF ceiling
      if (DestStream.Size < SizeOf(WAVHeader)) or ((DestStream.Size - 8) > MAX_RIFF_WAV_SIZE) then
        Exit(False);

      // 3. Update the master RIFF size field at offset 4 (RIFF form only)
      NewRiffSize := Cardinal(DestStream.Size - 8);

      // 4. Append any trailing bytes that lay outside the original RIFF form
      if TrailStart < SourceStream.Size then
      begin
        SourceStream.Position := TrailStart;
        DestStream.Position   := DestStream.Size;
        DestStream.CopyFrom(SourceStream, SourceStream.Size - TrailStart);
      end;

      DestStream.Position := 4;
      DestStream.WriteBuffer(NewRiffSize, 4);

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
    if Assigned(MemoryStream) then
      FreeAndNil(MemoryStream);
  end;
end;

initialization
  RegisterTagReader(WaveFileMask, TWaveReader);
end.
