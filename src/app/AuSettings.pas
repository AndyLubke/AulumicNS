unit AuSettings;

{ ==============================================================================
  AulumicNS - AuSettings
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Where AulumicNS keeps its data (portable):
    <exe>\Data\    settings (AulumicNS.ini), library, playlists, artist info, log
    <exe>\Cache\   thumbnails, cover cache
  When the folder of the exe cannot be written (e.g. under Program Files):
    %APPDATA%\AulumicNS\ (and its Cache sub folder).
  The settings themselves are Aulumic's TAppSettings (uSettingsManager),
  extended with the AulumicNS fields; uAppConsts builds its paths from here.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function AppDataDir: string;
function CacheDir: string;

implementation

var
  GDataDir, GCacheDir: string;

const
  AppFolderName = 'AulumicNS';

function DirWritable(const Dir: string): Boolean;
var
  F: THandle;
  Probe: string;
begin
  Result := False;
  if not ForceDirectories(Dir) then Exit;
  Probe := Dir + '~aulumicns-write-test.tmp';
  F := FileCreate(Probe);
  if F = THandle(-1) then Exit;
  FileClose(F);
  SysUtils.DeleteFile(Probe);
  Result := True;
end;

procedure ResolveDirs;
var
  Exe, Roaming: string;
begin
  Exe := ExtractFilePath(ParamStr(0));
  Roaming := GetEnvironmentVariable('APPDATA');
  if Roaming <> '' then Roaming := IncludeTrailingPathDelimiter(Roaming) + AppFolderName + PathDelim;
  if DirWritable(Exe + 'Data' + PathDelim) then
  begin
    GDataDir := Exe + 'Data' + PathDelim;
    GCacheDir := Exe + 'Cache' + PathDelim;
  end
  else if Roaming <> '' then
  begin
    GDataDir := Roaming;
    GCacheDir := Roaming + 'Cache' + PathDelim;
  end
  else
  begin
    GDataDir := Exe;
    GCacheDir := Exe + 'Cache' + PathDelim;
  end;
  ForceDirectories(GDataDir);
end;

function AppDataDir: string;
begin
  if GDataDir = '' then ResolveDirs;
  Result := GDataDir;
end;

function CacheDir: string;
begin
  if GDataDir = '' then ResolveDirs;
  Result := GCacheDir;
end;

end.
