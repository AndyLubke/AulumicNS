unit uVersionHelper;

{$mode objfpc}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uVersionHelper
  Author:    André Lubke
  Created:   2026

  Loads the .exe's version info (Project Options > Version Info in Lazarus:
  the numbers and strings of AulumicNS.lpi).
  ---> AulumicNS: ported from Aulumic. GetAppBuildDate is the time the program
  file was written, not the compile time of this unit: the DATE macro only
  changes when this unit itself is compiled again, so a build that left it
  alone showed an old date. New: GetCompilerInfo.
  =============================================================================}

interface

uses
  Classes, SysUtils, fileinfo, winpeimagereader;

function GetAppVersion: string;
function GetAppBuildDate: string;
function GetProductVersion: string;

function GetAppCompanyName  : string;
function GetAppCopyright    : string;
function GetAppDescription  : string;
function GetAppComments     : string;

function GetAllVersionInfo: string;

// ---> AulumicNS: 'Lazarus 4.8, Free Pascal 3.2.2, x86_64-win64'
function GetCompilerInfo: string;

implementation

uses
  LCLVersion, uAppConsts;

// =========================================================================
// ---> Private global variables to cache the strings in memory
// =========================================================================
var
  FCachedAppVersion     : string  = '';
  FCachedProductVersion : string  = '';
  FCachedCompanyName    : string  = '';
  FCachedCopyright      : string  = '';
  FCachedDescription    : string  = '';
  FCachedComments       : string  = '';
  FCachedAllInfo        : string  = '';
  FIsCached             : Boolean = False;

// =========================================================================
// Master caching procedure. Reads the info from the .exe file exactly ONCE.
// =========================================================================
procedure CacheVersionInfo;
var
  FileVerInfo: TFileVersionInfo;
  I: Integer;
begin
  if FIsCached then Exit;

  FileVerInfo := TFileVersionInfo.Create(nil);
  try
    try
      FileVerInfo.FileName := AppExePath;
      FileVerInfo.ReadFileInfo;

      // Extract everything into memory at once
      FCachedAppVersion     := FileVerInfo.VersionStrings.Values['FileVersion'];
      FCachedProductVersion := FileVerInfo.VersionStrings.Values['ProductVersion'];
      FCachedCompanyName    := FileVerInfo.VersionStrings.Values['CompanyName'];
      FCachedCopyright      := FileVerInfo.VersionStrings.Values['LegalCopyright'];
      FCachedDescription    := FileVerInfo.VersionStrings.Values['FileDescription'];
      FCachedComments       := FileVerInfo.VersionStrings.Values['Comments'];

      // Dump everything for GetAllVersionInfo
      for I := 0 to FileVerInfo.VersionStrings.Count - 1 do
      begin
        FCachedAllInfo := FCachedAllInfo + FileVerInfo.VersionStrings[I] + sLineBreak;
      end;

    except
      //Just to be sure:
      FCachedAppVersion     := '';
      FCachedProductVersion := '';
      FCachedAllInfo        := '';
    end;
  finally
    FileVerInfo.Free;
  end;

  // Fallbacks (---> AulumicNS: a program without version info says so; it
  // showed a made-up '1.0.0.0')
  if FCachedAppVersion = '' then
    FCachedAppVersion := 'unknown';

  if FCachedProductVersion = '' then
    FCachedProductVersion := FCachedAppVersion;

  if FCachedAllInfo = '' then
    FCachedAllInfo := 'No version information found.';

  // Lock the cache so the file is never opened again
  FIsCached := True;
end;

// =========================================================================
// All functions just trigger the cache and return memory
// =========================================================================
function GetAppVersion: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedAppVersion;
end;

function GetProductVersion: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedProductVersion;
end;

function GetAppBuildDate: string;
var
  Age: TDateTime;
begin
  // ---> AulumicNS: when the program file was written (see the unit header)
  if FileAge(AppExePath, Age) then
    Result := FormatDateTime('yyyy-mm-dd hh:nn', Age)
  else
    Result := 'unknown';
end;

function GetAppCompanyName: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedCompanyName;
end;

function GetAppCopyright: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedCopyright;
end;

function GetAppDescription: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedDescription;
end;

function GetAppComments: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedComments;
end;

function GetAllVersionInfo: string;
begin
  if not FIsCached then CacheVersionInfo;
  Result := FCachedAllInfo;
end;

function GetCompilerInfo: string;
begin
  Result := Format('Lazarus %d.%d, Free Pascal %s, %s-%s', [lcl_major, lcl_minor,
    {$I %FPCVERSION%}, {$I %FPCTARGETCPU%}, LowerCase({$I %FPCTARGETOS%})]);
end;

end.
