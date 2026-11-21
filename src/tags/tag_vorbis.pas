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
    Bounded comment and picture parsing, UTF-8 writing, protection against
    saving a partly read tag.
}
{$I ovotag.inc}
unit tag_vorbis;

interface

uses
  Classes, SysUtils, baseTag;

type

  { TVorbisFrame }

  TVorbisFrame = class(TFrameElement)
  private
    fValue: string;
    // The comment as it stands in the file, and the name it was read under.
    // While neither name nor value is changed, WriteToStream writes these
    // bytes again: text in another encoding than UTF-8 and the capitals of
    // the name stay as they are.
    fRaw: RawByteString;
    fRawID: string;
  protected
    function GetAsString: string; override;
    procedure SetAsString(const AValue: string); override;
  public
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;
  end;

  { TVorbisTags }

  TVorbisTags = class(TTags)
  private
    // True when ReadFromStream could not read every comment
    // (damaged length, oversized or malformed comment, too many comments,
    // damaged vendor field). Savers refuse to rewrite the file in that case,
    // because the comments that were not read would be lost.
    fReadIncomplete: boolean;
  public
    Vendor: string;
    property ReadIncomplete: boolean read fReadIncomplete;
    function ReadImageFromStream(AStream: TStream): boolean;
    function GetCommonTags: TCommonTags; override;
    procedure SetCommonTags(const CommonTags: TCommonTags); override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;
  end;

implementation

uses
  CommonFunctions;

const
  MAX_VORBIS_FRAME_SIZE = 16 * 1024 * 1024; // 16 MB safety cap per Vorbis frame/picture

{ TVorbisFrame }

function TVorbisFrame.GetAsString: string;
begin
  Result := fValue;
end;

procedure TVorbisFrame.SetAsString(const AValue: string);
begin
  if AValue <> fValue then
    fRaw := '';
  fValue := AValue;
end;

function TVorbisFrame.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
var
  fSize: Cardinal;
  Data: RawByteString;
  iSep: Integer;
  TmpSt: string;
  Remaining: Int64;
begin
  Result := False;
  if not Assigned(AStream) then
    Exit;

  Remaining := AStream.Size - AStream.Position;
  if Remaining < 4 then
  begin
    AStream.Position := AStream.Size;
    Exit;
  end;

  fSize := LEtoN(AStream.ReadDWord);

  // If fSize is invalid, advance AStream.Position to AStream.Size
  // so TVorbisTags.ReadFromStream breaks immediately instead of reading comment
  // text as the next 4-byte length field!
  if (fSize = 0) or (Int64(fSize) > (AStream.Size - AStream.Position)) or (fSize > MAX_VORBIS_FRAME_SIZE) then
  begin
    AStream.Position := AStream.Size;
    Exit;
  end;

  SetLength(Data, fSize);
  if AStream.Read(Data[1], fSize) < LongInt(fSize) then
  begin
    AStream.Position := AStream.Size;
    Exit;
  end;

  TmpSt := string(Data);
  iSep  := Pos('=', TmpSt);
  if iSep > 0 then
  begin
    ID     := UpperCase(Copy(TmpSt, 1, iSep - 1));
    fValue := Copy(TmpSt, iSep + 1, MaxInt);
    fRaw   := Data;
    fRawID := ID;
    Result := True;
  end;
end;

function TVorbisFrame.WriteToStream(AStream: TStream): DWord;
var
  fSize: Cardinal;
  // Explicit UTF8String guarantees byte-accurate length and WriteBuffer
  Data: UTF8String;
begin
  Result := 0;
  // not changed since it was read: the bytes of the file
  if (fRaw <> '') and (ID = fRawID) then
  begin
    fSize := Length(fRaw);
    AStream.WriteDWord(NtoLE(fSize));
    AStream.WriteBuffer(fRaw[1], fSize);
    Exit(fSize);
  end;
  Data   := UTF8Encode(ID + '=' + fValue);
  fSize  := Length(Data);
  AStream.WriteDWord(NtoLE(fSize));
  if fSize > 0 then
    AStream.WriteBuffer(Data[1], fSize);
  Result := fSize;
end;

{ TVorbisTags }

function TVorbisTags.ReadImageFromStream(AStream: TStream): boolean;
var
  img: TImageElement;
  Size: DWord;
  MimeStr, DescStr: RawByteString;
begin
  Result := False;
  if (not Assigned(AStream)) or ((AStream.Size - AStream.Position) < 32) then
    Exit;

  img := TImageElement.Create;
  try
    img.PictureType := BEtoN(AStream.ReadDWord);

    // 1. Read MIME Type safely without StrPas buffer overread
    Size := BEtoN(AStream.ReadDWord);
    if (Int64(Size) > (AStream.Size - AStream.Position)) or (Size > 1024) then
    begin
      FreeAndNil(img);
      Exit;
    end;
    if Size > 0 then
    begin
      SetLength(MimeStr, Size);
      AStream.ReadBuffer(MimeStr[1], Size);
      img.MIMEType := Trim(StringReplace(string(MimeStr), #0, '', [rfReplaceAll]));
    end
    else
      img.MIMEType := '';

    // 2. Read UTF-8 Description safely without StrPas overread or Utf8ToAnsi corruption
    if (AStream.Size - AStream.Position) < 4 then
    begin
      FreeAndNil(img);
      Exit;
    end;
    Size := BEtoN(AStream.ReadDWord);
    if (Int64(Size) > (AStream.Size - AStream.Position)) or (Size > 65536) then
    begin
      FreeAndNil(img);
      Exit;
    end;
    if Size > 0 then
    begin
      SetLength(DescStr, Size);
      AStream.ReadBuffer(DescStr[1], Size);
      img.Description := Trim(StringReplace(string(DescStr), #0, '', [rfReplaceAll]));
    end
    else
      img.Description := '';

    // 3. Skip Width, Height, Color Depth, Number of Colors (16 bytes) + Read Image Size (4 bytes)
    if (AStream.Size - AStream.Position) < 20 then
    begin
      FreeAndNil(img);
      Exit;
    end;

    AStream.ReadDWord; // Width
    AStream.ReadDWord; // Height
    AStream.ReadDWord; // Color depth
    AStream.ReadDWord; // Number of colors

    Size := BEtoN(AStream.ReadDWord);
    if (Size = 0) or (Int64(Size) > (AStream.Size - AStream.Position)) or (Size > MAX_VORBIS_FRAME_SIZE) then
    begin
      FreeAndNil(img);
      Exit;
    end;

    img.Image.CopyFrom(AStream, Size);
    img.Image.Position := 0;
    AddImage(img);
    Result := True;
  except
    FreeAndNil(img);
    Result := False;
  end;
end;

function TVorbisTags.GetCommonTags: TCommonTags;
begin
  Result := inherited GetCommonTags;

  Result.Album       := GetFrameValue('ALBUM');
  Result.AlbumArtist := GetFrameValue('ALBUMARTIST');
  Result.Artist      := GetFrameValue('ARTIST');
  Result.Comment     := GetFrameValue('COMMENT');
  if Result.Comment = '' then
    Result.Comment := GetFrameValue('DESCRIPTION');
  Result.Genre       := GetFrameValue('GENRE');
  Result.Title       := GetFrameValue('TITLE');
  Result.Track       := ExtractTrack(GetFrameValue('TRACKNUMBER'));
  Result.TrackString := GetFrameValue('TRACKNUMBER');
  Result.Year        := GetFrameValue('DATE');

  if Result.AlbumArtist = '' then
    Result.AlbumArtist := Result.Artist;

  Result.HasImage := ImageCount > 0;
end;

procedure TVorbisTags.SetCommonTags(const CommonTags: TCommonTags);
begin
  inherited SetCommonTags(CommonTags);

  SetFrameValue('ALBUM', CommonTags.Album, TVorbisFrame);
  SetFrameValue('ALBUMARTIST', CommonTags.AlbumArtist, TVorbisFrame);
  SetFrameValue('ARTIST', CommonTags.Artist, TVorbisFrame);
  SetFrameValue('COMMENT', CommonTags.Comment, TVorbisFrame);
  SetFrameValue('GENRE', CommonTags.Genre, TVorbisFrame);
  SetFrameValue('TITLE', CommonTags.Title, TVorbisFrame);
  SetFrameValue('TRACKNUMBER', CommonTags.TrackString, TVorbisFrame);
  SetFrameValue('DATE', CommonTags.Year, TVorbisFrame);
end;

function TVorbisTags.WriteToStream(AStream: TStream): DWord;
var
  fSize: Cardinal;
  i: LongInt;
  // Explicit UTF8String guarantees byte-accurate length and WriteBuffer
  VendorUTF8: UTF8String;
begin
  VendorUTF8 := UTF8Encode(Vendor);
  fSize      := Length(VendorUTF8);
  AStream.WriteDWord(NtoLE(fSize));
  if fSize > 0 then
    AStream.WriteBuffer(VendorUTF8[1], fSize);

  AStream.WriteDWord(NtoLE(Cardinal(Count)));
  for i := 0 to Count - 1 do
    Frames[i].WriteToStream(AStream);

  Result := SizeOf(DWord) * 2;
end;

function TVorbisTags.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
var
  fSize: Cardinal;
  Data: RawByteString;
  FrameCount: Cardinal;
  i: LongInt;
  Frame: TVorbisFrame;
  ReadOk: Boolean;
begin
  Clear;
  Result          := False;
  fReadIncomplete := False;
  if (not Assigned(AStream)) or ((AStream.Size - AStream.Position) < 8) then
  begin
    // A block too small for vendor + count is damaged (an absent block is
    // never passed here)
    fReadIncomplete := True;
    Exit;
  end;

  fSize := LEtoN(AStream.ReadDWord);
  if (Int64(fSize) > (AStream.Size - AStream.Position)) or (fSize > 65536) then
  begin
    fReadIncomplete := True;
    Exit;
  end;

  if fSize > 0 then
  begin
    SetLength(Data, fSize);
    AStream.ReadBuffer(Data[1], fSize);
    Vendor := Trim(StringReplace(string(Data), #0, '', [rfReplaceAll]));
  end
  else
    Vendor := '';

  if (AStream.Size - AStream.Position) < 4 then
  begin
    fReadIncomplete := True;
    Exit;
  end;

  FrameCount := LEtoN(AStream.ReadDWord);
  // Cap FrameCount so a corrupt header cannot loop millions of times
  if FrameCount > 4096 then
  begin
    FrameCount      := 4096;
    fReadIncomplete := True;
  end;

  for i := 0 to LongInt(FrameCount) - 1 do
  begin
    if (AStream.Size - AStream.Position) < 4 then
    begin
      // Fewer comments in the block than its header announces
      fReadIncomplete := True;
      Break;
    end;

    Frame := TVorbisFrame.Create;
    // Free Frame if ReadFromStream raises an exception before Add(Frame)
    try
      ReadOk := Frame.ReadFromStream(AStream);
    except
      FreeAndNil(Frame);
      raise;
    end;

    if ReadOk then
      Add(Frame)
    else
    begin
      FreeAndNil(Frame);
      // This comment (and possibly the rest) was not read
      fReadIncomplete := True;
      // If ReadFromStream hit a corrupt length header, it
      // moves AStream.Position to AStream.Size so we Break here instead of desyncing!
      if AStream.Position >= AStream.Size then
        Break;
    end;
  end;

  Result := Count > 0;
end;

end.
