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
    Robustness fixes (64-bit positions, bounds checks); uses the data-safe
    base class saving.
}
{A lot of code taken from
  Audio Tools Library  from Jurgen Faul and  The MAC Team
  http://mac.sourceforge.net/atl/
}
{$I ovotag.inc}
unit file_mp3;

interface

uses
  Classes, SysUtils, audiotag, basetag, tag_id3v2, CommonFunctions, bufstream;

const
  Mp3FileMask: string    = '*.mpa;*.mp1;*.mp2;*.mp3;';

type

  { TMP3Reader }
  VBRData = packed record
    Found: boolean;                                { True if VBR header found }
    ID: array [1..4] of char;                   { Header ID: "Xing" or "VBRI" }
    Frames: integer;                                 { Total number of frames }
    Bytes: integer;                                   { Total number of bytes }
    Scale: byte;                                         { VBR scale (1..100) }
    VendorID: string;                                { Vendor ID (if present) }
  end;

  { MPEG frame header data}
  FrameData = packed record
    Found: boolean;                                     { True if frame found }
    // ---> AUDIT FIX 1.2: Widened Position from 32-bit Integer to Int64
    Position: int64;                             { Frame position in the file }
    Size: word;                                          { Frame size (bytes) }
    Xing: boolean;                                     { True if Xing encoder }
    Data: array [1..4] of byte;                 { The whole frame header data }
    VersionID: byte;                                        { MPEG version ID }
    LayerID: byte;                                            { MPEG layer ID }
    ProtectionBit: boolean;                        { True if protected by CRC }
    BitRateID: word;                                            { Bit rate ID }
    SampleRateID: word;                                      { Sample rate ID }
    PaddingBit: boolean;                               { True if frame padded }
    PrivateBit: boolean;                                  { Extra information }
    ModeID: byte;                                           { Channel mode ID }
    ModeExtensionID: byte;             { Mode extension ID (for Joint Stereo) }
    CopyrightBit: boolean;                        { True if audio copyrighted }
    OriginalBit: boolean;                            { True if original media }
    EmphasisID: byte;                                           { Emphasis ID }
  end;

  TMP3Reader = class(TTagReader)
  private
    fTags: TID3Tags;
    FVBR: VBRData;
    FFrame: FrameData;
    FMPEGStart: int64;
    FMPEGEnd: int64;
    fMediaProperty: TMediaProperty;
  protected
    function GetTags: TTags; override;
    function GetDuration: int64; override;
    Function DumpInfo: TMediaProperty; override;
  public
    // ---> AUDIT FIX 2.4: Removed unsafe UpdateFile override; inherits base TTagReader.UpdateFile
    function isUpdateable: boolean; override;
    function LoadFromFile(const AFileName: Tfilename): boolean; override;
    function SaveToFile(const AFileName: Tfilename): boolean; override;
  end;

implementation

{ TMP3Reader }

const
  { Table for bit rates }
  MPEG_BIT_RATE: array [0..3, 0..3, 0..15] of word =
    (
    { For MPEG 2.5 }
    ((0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0),
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0),
    (0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0)),
    { Reserved }
    ((0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
    { For MPEG 2 }
    ((0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0),
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0),
    (0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0)),
    { For MPEG 1 }
    ((0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0),
    (0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0),
    (0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0))
    );

  { Table for sample rates }
  MPEG_SAMPLE_RATE: array [0..3, 0..3] of word =
    (
    (11025, 12000, 8000, 0),                                   { For MPEG 2.5 }
    (0, 0, 0, 0),                                                  { Reserved }
    (22050, 24000, 16000, 0),                                    { For MPEG 2 }
    (44100, 48000, 32000, 0)                                     { For MPEG 1 }
    );

  MPEG_CM_MONO = 3;                                                    { Mono }
  { Channel mode names }
  MPEG_CM_MODE: array [0..4] of string =
      ('Stereo', 'Joint Stereo', 'Dual Channel', 'Mono', 'Unknown');

  MPEG_VERSION_1 = 3;
  MAX_MPEG_FRAME_LENGTH = 1729;                      { Max. MPEG frame length }
  MPEG_LAYER_II = 2;                                               { Layer II }
  MPEG_LAYER_I = 3;

  { VBR header ID for Xing/FhG }
  VBR_ID_XING = 'Xing';                                         { Xing VBR ID }
  VBR_ID_FHG = 'VBRI';                                           { FhG VBR ID }


{ --------------------------------------------------------------------------- }
function IsFrameHeader(const HeaderData: array of byte): boolean;
begin
  { Check for valid frame header }
  if ((HeaderData[0] and $FF) <> $FF) or ((HeaderData[1] and $E0) <> $E0) or
    (((HeaderData[1] shr 3) and 3) = 1) or (((HeaderData[1] shr 1) and 3) = 0) or
    ((HeaderData[2] and $F0) = $F0) or ((HeaderData[2] and $F0) = 0) or
    (((HeaderData[2] shr 2) and 3) = 3) or ((HeaderData[3] and 3) = 2) then
    Result := False
  else
    Result := True;
end;

{ --------------------------------------------------------------------------- }

procedure DecodeHeader(const HeaderData: array of byte; var Frame: FrameData);
begin
  { Decode frame header data }
  Move(HeaderData, Frame.Data, SizeOf(Frame.Data));
  Frame.VersionID := (HeaderData[1] shr 3) and 3;
  Frame.LayerID := (HeaderData[1] shr 1) and 3;
  Frame.ProtectionBit := (HeaderData[1] and 1) <> 1;
  Frame.BitRateID := HeaderData[2] shr 4;
  Frame.SampleRateID := (HeaderData[2] shr 2) and 3;
  Frame.PaddingBit := ((HeaderData[2] shr 1) and 1) = 1;
  Frame.PrivateBit := (HeaderData[2] and 1) = 1;
  Frame.ModeID := (HeaderData[3] shr 6) and 3;
  Frame.ModeExtensionID := (HeaderData[3] shr 4) and 3;
  Frame.CopyrightBit := ((HeaderData[3] shr 3) and 1) = 1;
  Frame.OriginalBit := ((HeaderData[3] shr 2) and 1) = 1;
  Frame.EmphasisID := HeaderData[3] and 3;
end;

{ --------------------------------------------------------------------------- }

function ValidFrameAt(const Index: word; Data: array of byte): boolean;
var
  HeaderData: array [1..4] of byte;
begin
  { Check for frame at given position }
  if (Index + 3) >= Length(Data) then
    Exit(False);
  HeaderData[1] := Data[Index];
  HeaderData[2] := Data[Index + 1];
  HeaderData[3] := Data[Index + 2];
  HeaderData[4] := Data[Index + 3];
  Result := IsFrameHeader(HeaderData);
end;

{ --------------------------------------------------------------------------- }

function GetCoefficient(const Frame: FrameData): byte;
begin
  { Get frame size coefficient }
  if Frame.VersionID = MPEG_VERSION_1 then
    if Frame.LayerID = MPEG_LAYER_I then
      Result := 48
    else
      Result := 144
  else
  if Frame.LayerID = MPEG_LAYER_I then
    Result := 24
  else if Frame.LayerID = MPEG_LAYER_II then
    Result := 144
  else
    Result := 72;
end;

function GetBitRate(const Frame: FrameData): Dword;
begin
  { Get bit rate }
  Result := MPEG_BIT_RATE[Frame.VersionID, Frame.LayerID, Frame.BitRateID];
end;

function GetSampleRate(const Frame: FrameData): Dword;
begin
  { Get sample rate }
  Result := MPEG_SAMPLE_RATE[Frame.VersionID, Frame.SampleRateID];
end;

function GetPadding(const Frame: FrameData): byte;
begin
  { Get frame padding }
  if Frame.PaddingBit then
    if Frame.LayerID = MPEG_LAYER_I then
      Result := 4
    else
      Result := 1
  else
    Result := 0;
end;

function GetFrameLength(const Frame: FrameData): Dword;
var
  Coefficient, BitRate, SampleRate, Padding: word;
begin
  { Calculate MPEG frame length }
  Coefficient := GetCoefficient(Frame);
  BitRate := GetBitRate(Frame);
  SampleRate := GetSampleRate(Frame);
  Padding := GetPadding(Frame);
  if SampleRate = 0 then
    Exit(0);
  Result := Trunc(Coefficient * BitRate * 1000 / SampleRate) + Padding;
end;

{ --------------------------------------------------------------------------- }

function IsXing(const Index: word; Data: array of byte): boolean;
begin
  if (Index + 5) >= Length(Data) then
    Exit(False);
  { Get true if Xing encoder }
  Result :=
    (Data[Index] = 0) and (Data[Index + 1] = 0) and (Data[Index + 2] = 0) and
    (Data[Index + 3] = 0) and (Data[Index + 4] = 0) and (Data[Index + 5] = 0);
end;

{ --------------------------------------------------------------------------- }

function GetXingInfo(const Index: word; Data: array of byte): VBRData;
begin
  { Extract Xing VBR info at given position }
  Result := Default(VBRData);   // ---> AulumicNS: a managed record (VendorID)
  if (Index + 127) >= Length(Data) then
    Exit;
  Result.Found := True;
  Result.Frames :=
    Data[Index + 8] * $1000000 + Data[Index + 9] * $10000 +
    Data[Index + 10] * $100 + Data[Index + 11];
  Result.Bytes :=
    Data[Index + 12] * $1000000 + Data[Index + 13] * $10000 +
    Data[Index + 14] * $100 + Data[Index + 15];
  Result.Scale := Data[Index + 119];
  { Vendor ID can be not present }
  Result.VendorID :=
    Chr(Data[Index + 120]) + Chr(Data[Index + 121]) + Chr(Data[Index + 122]) +
    Chr(Data[Index + 123]) + Chr(Data[Index + 124]) + Chr(Data[Index + 125]) +
    Chr(Data[Index + 126]) + Chr(Data[Index + 127]);
end;

{ --------------------------------------------------------------------------- }

function GetFhGInfo(const Index: word; Data: array of byte): VBRData;
begin
  { Extract FhG VBR info at given position }
  Result := Default(VBRData);   // ---> AulumicNS: a managed record (VendorID)
  if (Index + 17) >= Length(Data) then
    Exit;
  Result.Found := True;
  Result.Scale := Data[Index + 9];
  Result.Bytes :=
    Data[Index + 10] * $1000000 + Data[Index + 11] * $10000 +
    Data[Index + 12] * $100 + Data[Index + 13];
  Result.Frames :=
    Data[Index + 14] * $1000000 + Data[Index + 15] * $10000 +
    Data[Index + 16] * $100 + Data[Index + 17];
end;

{ --------------------------------------------------------------------------- }

function FindVBR(const Index: word; Data: array of byte): VBRData;
begin
  { Check for VBR header at given position }
  Result := Default(VBRData);   // ---> AulumicNS: a managed record (VendorID)
  if (Index + 3) >= Length(Data) then
    Exit;
  if Chr(Data[Index]) + Chr(Data[Index + 1]) + Chr(Data[Index + 2]) +
     Chr(Data[Index + 3]) = VBR_ID_XING then
    Result := GetXingInfo(Index, Data);
  if Chr(Data[Index]) + Chr(Data[Index + 1]) + Chr(Data[Index + 2]) +
     Chr(Data[Index + 3]) = VBR_ID_FHG then
    Result := GetFhGInfo(Index, Data);
end;

{ --------------------------------------------------------------------------- }

function GetVBRDeviation(const Frame: FrameData): byte;
begin
  { Calculate VBR deviation }
  if Frame.VersionID = MPEG_VERSION_1 then
    if Frame.ModeID <> MPEG_CM_MONO then
      Result := 36
    else
      Result := 21
  else
  if Frame.ModeID <> MPEG_CM_MONO then
    Result := 21
  else
    Result := 13;
end;

{ --------------------------------------------------------------------------- }

function FindFrame(const Data: array of byte; var VBR: VBRData): FrameData;
var
  HeaderData: array [1..4] of byte;
  Iterator, VBRIdx: DWORD;
begin
  { Search for valid frame }
  Result := Default(FrameData);   // ---> AulumicNS: a managed record (VendorID)
  Move(Data, HeaderData, SizeOf(HeaderData));
  for Iterator := 0 to SizeOf(Data) - MAX_MPEG_FRAME_LENGTH do
  begin
    { Decode data if frame header found }
    if IsFrameHeader(HeaderData) then
    begin
      DecodeHeader(HeaderData, Result);
      { Check for next frame and try to find VBR header }
      VBRIdx := Iterator + GetFrameLength(Result);
      // ---> AUDIT FIX 3.1: Guard VBRIdx + 3 < SizeOf(Data) so ValidFrameAt never reads past Data!
      if ((VBRIdx + 3) < SizeOf(Data)) and ValidFrameAt(VBRIdx, Data) then
      begin
        Result.Found := True;
        Result.Position := Iterator;
        Result.Size := GetFrameLength(Result);
        Result.Xing := IsXing(Iterator + SizeOf(HeaderData), Data);
        VBR := FindVBR(Iterator + GetVBRDeviation(Result), Data);
        break;
      end;
    end;
    { Prepare next data block }
    HeaderData[1] := HeaderData[2];
    HeaderData[2] := HeaderData[3];
    HeaderData[3] := HeaderData[4];
    HeaderData[4] := Data[Iterator + SizeOf(HeaderData)];
  end;
end;

function TMP3Reader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TID3Tags.Create;
  Result := fTags;
end;

function TMP3Reader.GetDuration: int64;
var
  MPEGSize: int64;
  SR, BR: DWord;
begin
  Result := 0;
  if FFrame.Found then
  begin
    SR := GetSampleRate(FFrame);
    BR := GetBitRate(FFrame);
    if (FVBR.Found) and (FVBR.Frames > 0) and (SR > 0) then
      Result := Trunc(Int64(FVBR.Frames) * GetCoefficient(FFrame) * 8 / SR * 1000)
    else if BR > 0 then
    begin
      MPEGSize := FMPEGEnd - FMPEGStart;
      if MPEGSize > 0 then
        Result := Trunc(MPEGSize / BR * 8);
    end;
  end;
end;

function TMP3Reader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TMP3Reader.isUpdateable: boolean;
begin
  Result := True;
end;

function TMP3Reader.LoadFromFile(const AFileName: Tfilename): boolean;
const
  SizeOfData = MAX_MPEG_FRAME_LENGTH * 2;
var
  fStream: TBufferedFileStream;
  Data: array [1..SizeOfData] of byte;
  Transferred: DWord;
  ChunkStartPos: Int64;
begin
  Result := inherited LoadFromFile(AFileName);
  FillChar(FVBR, SizeOf(FVBR), 0);
  FillChar(FFrame, SizeOf(FFrame), 0);
  FillChar(Data, SizeOf(Data), 0);
  FMPEGStart     := 0;
  FMPEGEnd       := 0;
  fMediaProperty := Default(TMediaProperty);

  // ---> AUDIT FIX 4.3: Free existing fTags if reader is reused
  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TID3Tags.Create;

  fStream := TBufferedFileStream.Create(fileName, fmOpenRead or fmShareDenyNone);
  try
    fTags.ReadFromStream(fStream);

    fStream.Seek(fTags.Size, soFromBeginning);

    ChunkStartPos := fStream.Position;
    Transferred   := fStream.Read(Data[1], SizeOfData);
    FFrame        := FindFrame(Data, FVBR);
    if (not FFrame.Found) and (Transferred = SizeOfData) then
    begin
      repeat
        ChunkStartPos := fStream.Position;
        Transferred   := fStream.Read(Data[1], SizeOfData);
        FFrame        := FindFrame(Data, FVBR);
      until (FFrame.Found) or (Transferred < SizeOfData);
    end;

    if FFrame.Found then
    begin
      // ---> AUDIT FIX 1.2: Use 64-bit ChunkStartPos + FFrame.Position
      FFrame.Position := ChunkStartPos + FFrame.Position;
      FMPEGStart      := FFrame.Position;
      FMPEGEnd        := fStream.Size;
      fMediaProperty.BitRate     := GetBitRate(FFrame);
      fMediaProperty.Sampling    := GetSampleRate(FFrame);
      fMediaProperty.ChannelMode := MPEG_CM_MODE[FFrame.ModeID];
      Result := True;
    end;
  finally
    fStream.Free;
  end;
end;

// =============================================================================
// ---> AUDIT FIX 2.1, 2.2, 2.3, 2.4 & 4.1:
// 1. Initializes fOldSize := -1 so untagged/ID3v1 MP3 files never read stack garbage!
// 2. Calculates AudioOffset = 10 + fOldSize (+ 10 if ID3v2.4 footer flag $10 is set).
// 3. Always writes the complete file to DestStream (AFileName) inside try..finally
//    so UpdateFile's atomic replacement handles the swap without in-place corruption
//    or leaked file handles!
// =============================================================================
function TMP3Reader.SaveToFile(const AFileName: Tfilename): boolean;
var
  SourceStream: TBufferedFileStream;
  DestStream: TBufferedFileStream;
  fOldSize: int64;
  AudioOffset: int64;
  wHeader: TID3Header;
begin
  Result := False;
  inherited SaveToFile(AFileName);

  if not Assigned(fTags) then
    Exit(False);

  // ---> AUDIT FIX: Never rewrite a tag that was only partially loaded
  // (oversized frames skipped on read) - those frames would be lost
  if fTags.HasSkippedFrames then
    Exit(False);

  fOldSize     := -1;
  AudioOffset  := 0;
  FillChar(wHeader, SizeOf(wHeader), 0);
  SourceStream := nil;
  DestStream   := nil;

  try
    try
      SourceStream := TBufferedFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
      DestStream   := TBufferedFileStream.Create(AFileName, fmCreate or fmOpenReadWrite or fmShareDenyWrite);

      if SourceStream.Read(wHeader, SizeOf(wHeader)) = SizeOf(wHeader) then
      begin
        if wHeader.Marker = ID3_HEADER_MARKER then
        begin
          fOldSize    := SyncSafe_Decode(wHeader.size);
          AudioOffset := SizeOf(TID3Header) + fOldSize;
          // Account for 10-byte ID3v2.4 footer if flag $10 is set
          if (wHeader.Flags and $10) <> 0 then
            Inc(AudioOffset, 10);
          // ---> AUDIT FIX: A tag size that reaches or passes the end of the file
          // means the header is corrupt (or there is no audio). Refuse to save
          // instead of writing a file without any audio data.
          if AudioOffset >= SourceStream.Size then
            Exit(False);
        end;
      end;

      // Keep the old padding (capped at 1 MB so a corrupt size field can never
      // force a huge zero-filled allocation); the file is always rebuilt anyway
      if (fOldSize >= 0) and (fOldSize >= Int64(fTags.RealSize)) then
      begin
        if (fOldSize - Int64(fTags.RealSize)) > (1024 * 1024) then
          fTags.Padding := 1024 * 1024
        else
          fTags.Padding := Integer(fOldSize - Int64(fTags.RealSize));
      end
      else
        fTags.Padding := 0;

      fTags.WriteToStream(DestStream);

      // ---> AUDIT FIX: Abort if any frame could not be written (v2.2 16 MB / 256 MB limits)
      if fTags.LastWriteDroppedFrames then
        Exit(False);

      SourceStream.Seek(AudioOffset, soFromBeginning);
      if SourceStream.Size > SourceStream.Position then
        DestStream.CopyFrom(SourceStream, SourceStream.Size - SourceStream.Position);

      Result := True;
    except
      Result := False;
    end;
  finally
    if Assigned(DestStream) then
      FreeAndNil(DestStream);
    if Assigned(SourceStream) then
      FreeAndNil(SourceStream);
  end;
end;

initialization
  RegisterTagReader(Mp3FileMask, TMP3Reader);
end.
