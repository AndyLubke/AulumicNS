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
    Size and bounds validation of metadata atoms.
}
{$I ovotag.inc}
unit tag_MP4;

interface

uses
  Classes, SysUtils, baseTag;

type
  { TMp4Frame }

  TMp4Frame = class(TFrameElement)
  private
    fFlags: DWord;
    Data: RawByteString;
    fSize: Integer;
  protected
    function GetAsString: string; override;
    procedure SetAsString(const AValue: string); override;
    function GetSize: DWord; override;
  public
    constructor Create; override;
    destructor Destroy; override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;
  end;

  { TMp4Tags }

  TMp4Tags = class(TTags)
  public
    function GetCommonTags: TCommonTags; override;
    procedure SetCommonTags(const CommonTags: TCommonTags); override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;
  end;

implementation

uses
  file_Mp4, CommonFunctions;

const
  MAX_MP4_FRAME_SIZE = 16 * 1024 * 1024; // 16 MB safety ceiling per MP4 metadata atom
  knowntagCount = 10;
  knowntag: array [0..knowntagCount - 1] of string = (
    #169 + 'nam', #169 + 'cmt', #169 + 'day', #169 + 'ART', #169 + 'trk',
    #169 + 'alb', #169 + 'gen', 'gnre', 'trkn', 'aART'
  );

{ TMp4Frame }

// ---> AUDIT FIX 3.2: Check Length(Data) before dereferencing PWord/PDWord!
function TMp4Frame.GetAsString: string;
begin
  Result := '';
  if (fFlags and $00ffffff) = 1 then
    Result := Data
  else if (fFlags and $00ffffff) = 0 then
  begin
    if (fSize = 24) and (Length(Data) >= 4) then
      Result := IntToStr(BEtoN(PDWord(@Data[1])^))
    else if Length(Data) >= 2 then
      Result := IntToStr(BEtoN(PWord(@Data[1])^));
  end;
end;

procedure TMp4Frame.SetAsString(const AValue: string);
begin
end;

function TMp4Frame.GetSize: DWord;
begin
  if fSize > 0 then
    Result := DWord(fSize)
  else
    Result := 0;
end;

constructor TMp4Frame.Create;
begin
  inherited Create;
end;

destructor TMp4Frame.Destroy;
begin
  SetLength(Data, 0);
  inherited Destroy;
end;

// ---> AUDIT FIX 1.3 & 3.2: Validate fSize (16 .. MAX_MP4_FRAME_SIZE) and stream
// bounds before allocating Data or calling AStream.Read!
function TMp4Frame.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
var
  wName: AtomName;
  PayloadLen: Integer;
begin
  Result := False;
  SetLength(Data, 0);
  fSize  := 0;

  if (not Assigned(AStream)) or ((AStream.Size - AStream.Position) < 16) then
    Exit;

  fSize := Integer(BEtoN(AStream.ReadDWord));
  if (fSize < 16) or (fSize > MAX_MP4_FRAME_SIZE) then
    Exit;

  PayloadLen := fSize - 16;
  if PayloadLen > (AStream.Size - AStream.Position - 12) then
    Exit;

  if AStream.Read(wName, 4) < 4 then
    Exit;
  fFlags := BEtoN(AStream.ReadDWord);
  AStream.ReadDWord;

  if PayloadLen > 0 then
  begin
    SetLength(Data, PayloadLen);
    if AStream.Read(Data[1], PayloadLen) < PayloadLen then
    begin
      SetLength(Data, 0);
      Exit;
    end;
  end;

  Result := True;
end;

function TMp4Frame.WriteToStream(AStream: TStream): DWord;
begin
  Result := 0;
end;

{ TMp4Tags }

function TMp4Tags.GetCommonTags: TCommonTags;
var
  tmpst: string;
  xInt: Longint;
begin
  Result             := inherited GetCommonTags;
  Result.Album       := GetFrameValue(#169 + 'alb');
  Result.Artist      := GetFrameValue(#169 + 'ART');
  Result.AlbumArtist := GetFrameValue('aART');
  if Result.AlbumArtist = '' then
    Result.AlbumArtist := Result.Artist;
  Result.Comment     := GetFrameValue(#169 + 'cmt');
  Result.Title       := GetFrameValue(#169 + 'nam');
  Result.Genre       := '';
  tmpst              := GetFrameValue(#169 + 'gen');
  if tmpst <> '' then
    Result.Genre := ExtractGenre(tmpst, -1);

  if Result.Genre = '' then
    Result.Genre := ExtractGenre(GetFrameValue('gnre'), -1);

  Result.Year        := ExtractYear('', GetFrameValue(#169 + 'day'));
  Result.TrackString := GetFrameValue(#169 + 'trk');
  tmpst              := GetFrameValue('trkn');
  if not TryStrToInt(tmpst, xInt) then
    Result.Track := ExtractTrack(GetFrameValue(#169 + 'trk'))
  else
    Result.Track := xInt;
end;

procedure TMp4Tags.SetCommonTags(const CommonTags: TCommonTags);
begin
  inherited SetCommonTags(CommonTags);
end;

function TMp4Tags.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
var
  Frame: TMp4Frame;
  i, j: integer;
  ilst, CurrAtom: TMp4Atom;
  ReadOk: Boolean;
begin
  Clear;
  Result := False;
  ilst   := TMp4Atom(ExtInfo);
  if Assigned(ilst) and Assigned(AStream) then
  begin
    for i := 0 to ilst.children.Count - 1 do
    begin
      CurrAtom := TMp4Atom(ilst.children[i]);
      for j := 0 to knowntagCount - 1 do
      begin
        if CurrAtom.Name = knowntag[j] then
        begin
          if (CurrAtom.Offset + 8) > AStream.Size then
            Continue;

          AStream.Seek(CurrAtom.Offset + 8, soFromBeginning);
          Frame        := TMp4Frame.Create;
          Frame.Tagger := Self;
          Frame.ID     := CurrAtom.Name;

          // ---> AUDIT FIX 4.2: Protect Frame against exceptions or failed reads
          try
            ReadOk := Frame.ReadFromStream(AStream, CurrAtom);
          except
            FreeAndNil(Frame);
            raise;
          end;

          if ReadOk then
            Add(Frame)
          else
            FreeAndNil(Frame);
        end;
      end;
    end;
  end;
  Result := True;
end;

function TMp4Tags.WriteToStream(AStream: TStream): DWord;
begin
  Result := AStream.Size;
end;

end.
