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
  AulumicTag - written for Aulumic by André Lubke, 2026, after file_wave.
  AulumicTag is a fork of OvoTag (C) 2011 Marco Caselli; see README.md.

  AIFF and AIFF-C (.aif, .aiff, .aifc): the ID3v2 tag in the 'ID3 ' chunk of
  the FORM, read and written. A save copies every other chunk byte for byte
  (the sound data always, and whatever it does not know), puts the tag chunk
  at the end and corrects the size of the FORM. Sizes are big-endian and
  chunks are padded to an even length.
}
{$I ovotag.inc}
unit file_aiff;

interface

uses
  Classes, SysUtils, AudioTag, baseTag, tag_id3v2;

const
  AiffFileMask: string = '*.aif;*.aiff;*.aifc;';

type

  { TAiffTagReader }

  TAiffTagReader = class(TTagReader)
  private
    fTags: TID3Tags;
    fMediaProperty: TMediaProperty;
    fDurationMs: int64;
    // The 'ID3 ' chunk was larger than the read limit and only partly loaded:
    // SaveToFile then refuses to write
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
  Math, CommonFunctions, AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  MAX_AIFF_ID3_SIZE = 64 * 1024 * 1024;  // read limit of the tag chunk
  MAX_FORM_SIZE     = Int64($FFFFFFFF);  // a FORM size is 32 bit
  FORM_HEADER       = 12;                // 'FORM', size, 'AIFF' / 'AIFC'

type
  TFourCC = array[0..3] of AnsiChar;

function IsChunkID(const AName: TFourCC): boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to 3 do
    if not (AName[I] in [#32..#126]) then
      Exit(False);
end;

function IsId3Chunk(const AName: TFourCC): boolean;
begin
  Result := SameText(string(AName), 'ID3 ');
end;

function ReadBE32(AStream: TStream; out AValue: Cardinal): boolean;
var
  B: array[0..3] of Byte;
begin
  AValue := 0;
  Result := AStream.Read(B, 4) = 4;
  if Result then
    AValue := (Cardinal(B[0]) shl 24) or (Cardinal(B[1]) shl 16) or (Cardinal(B[2]) shl 8) or B[3];
end;

procedure WriteBE32(AStream: TStream; AValue: Cardinal);
var
  B: array[0..3] of Byte;
begin
  B[0] := Byte(AValue shr 24);
  B[1] := Byte(AValue shr 16);
  B[2] := Byte(AValue shr 8);
  B[3] := Byte(AValue);
  AStream.WriteBuffer(B, 4);
end;

// The sample rate of a COMM chunk: an 80-bit extended number, big-endian
function RateFromExtended(const B: array of Byte): Integer;
var
  Exponent, I: Integer;
  Mantissa: QWord;
  Value: Double;
begin
  Result := 0;
  if (Length(B) < 10) or ((B[0] and $80) <> 0) then
    Exit;
  Exponent := ((B[0] and $7F) shl 8) or B[1];
  Mantissa := 0;
  for I := 2 to 9 do
    Mantissa := (Mantissa shl 8) or B[I];
  if (Exponent = 0) or (Exponent = $7FFF) or (Mantissa = 0) then
    Exit;
  Value := Mantissa * Power(2.0, Exponent - 16383 - 63);
  if (Value >= 1.0) and (Value <= 4000000.0) then
    Result := Round(Value);
end;

function IsAiffForm(AStream: TStream; out AFormSize: Cardinal): boolean;
var
  Id, Kind: TFourCC;
begin
  AFormSize := 0;
  Result := False;
  if AStream.Size < FORM_HEADER then
    Exit;
  AStream.Position := 0;
  if AStream.Read(Id, 4) < 4 then
    Exit;
  if not ReadBE32(AStream, AFormSize) then
    Exit;
  if AStream.Read(Kind, 4) < 4 then
    Exit;
  Result := (Id = 'FORM') and ((Kind = 'AIFF') or (Kind = 'AIFC'));
end;

{ TAiffTagReader }

function TAiffTagReader.GetDuration: int64;
begin
  Result := fDurationMs;
end;

function TAiffTagReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TID3Tags.Create;
  Result := fTags;
end;

function TAiffTagReader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TAiffTagReader.isUpdateable: boolean;
begin
  Result := True;
end;

function TAiffTagReader.LoadFromFile(const AFileName: Tfilename): boolean;
var
  fStream: TStream;
  TagMem: TMemoryStream;
  Id, Compression: TFourCC;
  FormSize, ChunkSize, Frames, Offset: Cardinal;
  Comm: array[0..17] of Byte;
  FileSize, ChunkStart, ChunkEnd, TagCopy, SoundBytes: Int64;
  Channels, SampleSize, Rate, SampleBytes: Integer;
  HasComm, HasTag, IsAifc: Boolean;
  C: string;
begin
  inherited LoadFromFile(AFileName);
  Result         := False;
  fMediaProperty := Default(TMediaProperty);
  fDurationMs    := 0;
  FTagTruncated  := False;

  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TID3Tags.Create;

  Channels    := 0;
  SampleSize  := 0;
  Rate        := 0;
  Frames      := 0;
  SoundBytes  := 0;
  HasComm     := False;
  HasTag      := False;
  Compression := 'NONE';

  fStream := nil;
  try
    try
      fStream  := AuOpenFile(FileName, fmOpenRead or fmShareDenyNone);
      FileSize := fStream.Size;
      if not IsAiffForm(fStream, FormSize) then
        Exit(False);
      fStream.Position := 8;
      fStream.ReadBuffer(Id, 4);
      IsAifc := Id = 'AIFC';

      while fStream.Position + 8 <= FileSize do
      begin
        if fStream.Read(Id, 4) < 4 then
          Break;
        if not ReadBE32(fStream, ChunkSize) then
          Break;
        if not IsChunkID(Id) then
          Break;
        ChunkStart := fStream.Position;
        ChunkEnd   := ChunkStart + ChunkSize;

        if (Id = 'COMM') and (ChunkSize >= 18) then
        begin
          if fStream.Read(Comm, 18) = 18 then
          begin
            Channels   := (Integer(Comm[0]) shl 8) or Comm[1];
            Frames     := (Cardinal(Comm[2]) shl 24) or (Cardinal(Comm[3]) shl 16) or
                          (Cardinal(Comm[4]) shl 8) or Comm[5];
            SampleSize := (Integer(Comm[6]) shl 8) or Comm[7];
            Rate       := RateFromExtended(Comm[8..17]);
            if IsAifc and (ChunkSize >= 22) then
              fStream.Read(Compression, 4);
            HasComm := True;
          end;
        end
        else if (Id = 'SSND') and (ChunkSize >= 8) then
        begin
          if ReadBE32(fStream, Offset) then
          begin
            SoundBytes := Int64(ChunkSize) - 8 - Offset;
            if ChunkStart + 8 + Offset + SoundBytes > FileSize then
              SoundBytes := FileSize - (ChunkStart + 8 + Offset);
          end;
        end
        else if IsId3Chunk(Id) and (not HasTag) then
        begin
          TagCopy := ChunkSize;
          if ChunkStart + TagCopy > FileSize then
            TagCopy := FileSize - ChunkStart;
          if TagCopy > MAX_AIFF_ID3_SIZE then
          begin
            TagCopy       := MAX_AIFF_ID3_SIZE;
            FTagTruncated := True;
          end;
          // From a stream of its own, so the tag is read from position 0
          if TagCopy >= 10 then
          begin
            TagMem := TMemoryStream.Create;
            try
              TagMem.CopyFrom(fStream, TagCopy);
              TagMem.Position := 0;
              fTags.ReadFromStream(TagMem);
            finally
              TagMem.Free;
            end;
          end;
          HasTag := True;
        end;

        if (ChunkSize and 1) <> 0 then
          Inc(ChunkEnd);
        if ChunkEnd > FileSize then
          Break;
        fStream.Position := ChunkEnd;
      end;

      if HasComm then
      begin
        // The samples as they play: floating point as 32 bit, 8 bit as 16
        C := LowerCase(string(Compression));
        SampleBytes := (SampleSize + 7) div 8;
        if C = 'fl32' then SampleBytes := 4
        else if C = 'fl64' then SampleBytes := 8;
        fMediaProperty.Channels    := Channels;
        fMediaProperty.ChannelMode := DecodeChannelNumber(Channels);
        fMediaProperty.Sampling    := Rate;
        if (C = 'fl32') or (C = 'fl64') then
          fMediaProperty.BitDepth := 32
        else if SampleBytes = 1 then
          fMediaProperty.BitDepth := 16
        else
          fMediaProperty.BitDepth := SampleBytes * 8;
        if (Channels > 0) and (SampleBytes > 0) then
        begin
          if (Frames = 0) or (Int64(Frames) * SampleBytes * Channels > SoundBytes) then
            Frames := SoundBytes div (Int64(SampleBytes) * Channels);
          fMediaProperty.BitRate := (Int64(Rate) * SampleBytes * Channels * 8) div 1000;
          if Rate > 0 then
            fDurationMs := Trunc(Double(Frames) / Rate * 1000.0);
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

function TAiffTagReader.SaveToFile(const AFileName: Tfilename): boolean;
var
  Source, Dest: TStream;
  TagData: TMemoryStream;
  Id, Kind: TFourCC;
  FormSize, ChunkSize: Cardinal;
  FormEnd, ChunkEnd, NewFormSize: Int64;
  Pad: Byte;
  SawSound, SawComm: Boolean;
begin
  Result  := False;
  Source  := nil;
  Dest    := nil;
  TagData := nil;

  // A tag that was not read to its end is never written back
  if FTagTruncated or (Assigned(fTags) and (fTags.HasSkippedFrames or fTags.HasUnreadableData)) then
    Exit(False);

  try
    try
      Source := AuOpenFile(FileName, fmOpenRead or fmShareDenyNone);
      if not IsAiffForm(Source, FormSize) then
        Exit(False);
      Source.Position := 8;
      Source.ReadBuffer(Kind, 4);

      // Only what the FORM says it holds is taken apart; a FORM that claims
      // more than the file has is not rewritten
      FormEnd := Int64(FormSize) + 8;
      if (FormEnd < FORM_HEADER) or (FormEnd > Source.Size) then
        Exit(False);

      Dest    := AuOpenFile(AFileName, fmCreate or fmOpenReadWrite);
      TagData := TMemoryStream.Create;

      Id := 'FORM';
      Dest.WriteBuffer(Id, 4);
      WriteBE32(Dest, 0);                 // corrected at the end
      Dest.WriteBuffer(Kind, 4);

      SawSound := False;
      SawComm  := False;
      while Source.Position + 8 <= FormEnd do
      begin
        Source.ReadBuffer(Id, 4);
        if not ReadBE32(Source, ChunkSize) then
          Exit(False);
        if not IsChunkID(Id) then
          Exit(False);
        ChunkEnd := Source.Position + ChunkSize;
        // A chunk that runs out of the FORM: the file is damaged
        if ChunkEnd > FormEnd then
          Exit(False);

        if IsId3Chunk(Id) then
          Source.Position := ChunkEnd
        else
        begin
          if Id = 'SSND' then SawSound := True;
          if Id = 'COMM' then SawComm := True;
          Dest.WriteBuffer(Id, 4);
          WriteBE32(Dest, ChunkSize);
          if ChunkSize > 0 then
            Dest.CopyFrom(Source, ChunkSize);
        end;

        // The pad byte of an odd chunk: the file's own when it has one
        if (ChunkSize and 1) <> 0 then
        begin
          Pad := 0;
          if Source.Position < FormEnd then
            Source.Read(Pad, 1);
          if not IsId3Chunk(Id) then
            Dest.WriteBuffer(Pad, 1);
        end;
      end;

      // Without its sound and its description the file would be lost
      if (not SawSound) or (not SawComm) then
        Exit(False);

      if Assigned(fTags) and ((fTags.Count > 0) or fTags.HasRawForWrite) then
      begin
        fTags.Padding := 0;
        fTags.WriteToStream(TagData);
        if fTags.LastWriteDroppedFrames then
          Exit(False);
      end;

      if TagData.Size > 0 then
      begin
        Id := 'ID3 ';
        Dest.WriteBuffer(Id, 4);
        WriteBE32(Dest, Cardinal(TagData.Size));
        TagData.Position := 0;
        Dest.CopyFrom(TagData, TagData.Size);
        if (TagData.Size and 1) <> 0 then
        begin
          Pad := 0;
          Dest.WriteBuffer(Pad, 1);
        end;
      end;

      NewFormSize := Dest.Size - 8;
      if NewFormSize > MAX_FORM_SIZE then
        Exit(False);

      // Bytes behind the FORM are kept as they are
      if FormEnd < Source.Size then
      begin
        Source.Position := FormEnd;
        Dest.CopyFrom(Source, Source.Size - FormEnd);
      end;

      Dest.Position := 4;
      WriteBE32(Dest, Cardinal(NewFormSize));
      Result := True;
    except
      on E: Exception do
        Result := False;
    end;
  finally
    if Assigned(Source) then
      FreeAndNil(Source);
    if Assigned(Dest) then
      FreeAndNil(Dest);
    if Assigned(TagData) then
      FreeAndNil(TagData);
  end;
end;

initialization
  RegisterTagReader(AiffFileMask, TAiffTagReader);
end.
