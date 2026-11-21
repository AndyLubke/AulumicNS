{
This file is part of OvoTag
Copyright (C) 2011 Marco Caselli

OvoPlayer is free software; you can redistribute it and/or
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
    Robustness: safe extension matching (no partial or empty matches),
    https:// recognised as a stream.
}
{$I ovotag.inc}
unit AudioTag;

interface

uses
  Classes, SysUtils, Song,
  baseTag;

function SupportedExtension: string;

procedure RegisterTagReader(const Extensions: string;
                            const TagReader: TTagReaderClass);

function LoadTags(Song: TSong): boolean;
function ExtractTags(FileName: string): TCommonTags; overload;
function ExtractTags(FileTags: TTagReader): TCommonTags; overload;
// ATextOnly: embedded pictures are not loaded (see
// basetag.TagReadTextOnly); such a reader cannot save
// ARecover: a damaged ID3v2 tag is read as far as it can be repaired (see
// basetag.TagReadRecover)
function GetFileTagsObject(FileName: string; ATextOnly: boolean = False;
  ARecover: boolean = False): TTagReader;
function IdentifyKind(FileName: string): TTagReaderClass;

implementation

uses
  strutils, file_Dummy,
  AuAudioTypes;   // LongPath (paths of 260 characters and more)

type
  RTagReader = record
    Extensions: string;
    TagReader: TTagReaderClass;
  end;

var
  AReaderList: array of RTagReader;

function SupportedExtension: string;
var
  i: Integer;
begin
  Result := '';
  for i := Low(AReaderList) to High(AReaderList) do
    Result := Result + AReaderList[i].Extensions;
end;

procedure RegisterTagReader(const Extensions: string;
  const TagReader: TTagReaderClass);
var
  tr: RTagReader;
begin
  tr.Extensions := LowerCase(Extensions);
  tr.TagReader  := TagReader;
  SetLength(AReaderList, Length(AReaderList) + 1);
  AReaderList[High(AReaderList)] := tr;
end;

function LoadTags(Song: TSong): boolean;
begin
  Result := False;
  if not Assigned(Song) then
    Exit;

  try
    Result := FileExists(LongPath(Song.FullName));
    if Result and not Song.TagLoaded then
    begin
      Song.SetTags(ExtractTags(Song.FullName));
      Song.TagLoaded := True;
      Result         := Song.Tags.Title <> '';
    end;
  except
    on E: Exception do
      Result := False;
  end;
end;

function GetFileTagsObject(FileName: string; ATextOnly: boolean; ARecover: boolean): TTagReader;
var
  kind: TTagReaderClass;
  Before, BeforeRecover: boolean;
begin
  kind   := IdentifyKind(FileName);
  Before := TagReadTextOnly;
  BeforeRecover   := TagReadRecover;
  TagReadTextOnly := ATextOnly;
  TagReadRecover  := ARecover;
  try
    Result := kind.Create(FileName);
  finally
    TagReadTextOnly := Before;
    TagReadRecover  := BeforeRecover;
  end;
end;

function IdentifyKind(FileName: string): TTagReaderClass;
var
  ext: string;
  i: Integer;
begin
  Result := TDummyReader;
  if AnsiStartsStr('HTTP:\\', UpperCase(FileName)) or
     AnsiStartsStr('MMS:\\', UpperCase(FileName)) or
     AnsiStartsStr('HTTP://', UpperCase(FileName)) or
     AnsiStartsStr('HTTPS://', UpperCase(FileName)) then
  begin
    Exit;
  end;

  ext := LowerCase(Trim(ExtractFileExt(FileName)));
  // Guard against empty extensions (Pos('', S) returns 1!)
  // and match against ';' delimiter so '.mp3' never partially matches '.mp34'
  if ext = '' then
    Exit;

  for i := Low(AReaderList) to High(AReaderList) do
  begin
    if (Pos(ext + ';', AReaderList[i].Extensions) > 0) or
       (Pos('*' + ext + ';', AReaderList[i].Extensions) > 0) then
    begin
      Result := AReaderList[i].TagReader;
      Exit;
    end;
  end;
end;

function ExtractTags(FileTags: TTagReader): TCommonTags;
begin
  Result := Default(TCommonTags);
  if FileTags = nil then
    Exit;
  Result := FileTags.GetCommonTags;
end;

function ExtractTags(FileName: string): TCommonTags;
var
  InteTags: TTagReader;
begin
  InteTags := GetFileTagsObject(FileName);
  try
    Result := ExtractTags(InteTags);
  finally
    InteTags.Free;
  end;
end;

initialization
  SetLength(AReaderList, 0);
  RegisterTagReader(DummyFileMask, TDummyReader);

finalization
  SetLength(AReaderList, 0);
end.
