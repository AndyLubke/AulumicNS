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
    Adapted to the base class changes; tags object always present.
}
{$I ovotag.inc}
unit file_Dummy;

interface

uses
  Classes, SysUtils, baseTag, tag_Dummy;

const
  DummyFileMask: string = '';

type

  { TDummyReader }

  TDummyReader = class(TTagReader)
  private
    fTags: TTags;
  protected
    function GetDuration: int64; override;
    function GetTags: TTags; override;
  public
    function LoadFromFile(const AFileName: Tfilename): boolean; override;
    function SaveToFile(const AFileName: Tfilename): boolean; override;
  end;

implementation

{ TDummyReader }

function TDummyReader.GetDuration: int64;
begin
  Result := 0;
end;

function TDummyReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TDummyTags.Create;
  Result := fTags;
end;

function TDummyReader.LoadFromFile(const AFileName: Tfilename): boolean;
begin
  inherited LoadFromFile(AFileName);
  Result := False;
  // Free existing fTags if reader is reused
  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TDummyTags.Create;
end;

function TDummyReader.SaveToFile(const AFileName: Tfilename): boolean;
begin
  Result := False;
end;

initialization
// Moved to Audiotag unit because this must be always registered
//  RegisterTagReader(DummyFileMask, TDummyReader);
end.
