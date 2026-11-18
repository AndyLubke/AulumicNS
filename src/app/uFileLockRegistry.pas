unit uFileLockRegistry;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uFileLockRegistry
  Author:    André Lubke
  Created:   2026

  Central 'Registry' for locking and releasing files (used by file management
  routines).
  =============================================================================}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  { TFileLockRegistry }
  TFileLockRegistry = class
  private
    FLockedFiles: TStringList;
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AcquireLock(const AFilePath: string);
    procedure ReleaseLock(const AFilePath: string);
    function  IsFileBusy(const AFilePath: string): Boolean;
  end;

function FileLockRegistry: TFileLockRegistry;
procedure FreeFileLockRegistry;

implementation

uses
  uCrashTracer;

var
  GlobalRegistry: TFileLockRegistry = nil;

{$IFDEF WINDOWS}
function AL_GetLongPathNameW(lpszShortPath, lpszLongPath: PWideChar;
  cchBuffer: LongWord): LongWord; stdcall; external 'kernel32.dll' name 'GetLongPathNameW';
function AL_GetDriveTypeW(lpRootPathName: PWideChar): LongWord; stdcall;
  external 'kernel32.dll' name 'GetDriveTypeW';
// mpr.dll is a standard Windows system DLL (Multiple Provider Router)
function AL_WNetGetConnectionW(lpLocalName, lpRemoteName: PWideChar;
  var lpnLength: LongWord): LongWord; stdcall; external 'mpr.dll' name 'WNetGetConnectionW';

const
  AL_DRIVE_REMOTE         = 4;
  AL_NO_ERROR             = 0;
  // How long a drive-letter -> UNC mapping is cached (ms)
  DRIVE_MAP_CACHE_TIME_MS = 10000;

type
  TDriveMapEntry = record
    Checked  : Boolean;
    Tick     : QWord;
    UNCRoot  : string;   // '' = local drive or mapping unavailable
  end;

var
  DriveMapCache : array['A'..'Z'] of TDriveMapEntry;
  DriveMapLock  : TCriticalSection = nil;

// ---> AUDIT FIX: Returns the UNC root ('\\server\share') a mapped network
// drive letter points to, or '' for local drives. Cached per drive letter for
// 10 s so frequent IsFileBusy calls (scanner, playback) stay cheap.
function GetMappedDriveUNCRoot(ADrive: Char): string;
var
  Root, Local, Remote : UnicodeString;
  Len                 : LongWord;
  NowTick             : QWord;
begin
  Result := '';
  ADrive := UpCase(ADrive);
  if not (ADrive in ['A'..'Z']) then
    Exit;

  NowTick := GetTickCount64;

  if Assigned(DriveMapLock) then
  begin
    DriveMapLock.Enter;
    try
      if DriveMapCache[ADrive].Checked and
         (NowTick - DriveMapCache[ADrive].Tick < DRIVE_MAP_CACHE_TIME_MS) then
        Exit(DriveMapCache[ADrive].UNCRoot);
    finally
      DriveMapLock.Leave;
    end;
  end;

  Root := UnicodeString(ADrive) + ':\';
  if AL_GetDriveTypeW(PWideChar(Root)) = AL_DRIVE_REMOTE then
  begin
    Local := UnicodeString(ADrive) + ':';
    Len   := 1024;
    Remote := '';
    SetLength(Remote, Len);
    if AL_WNetGetConnectionW(PWideChar(Local), PWideChar(Remote), Len) = AL_NO_ERROR then
    begin
      Remote := UnicodeString(PWideChar(Remote)); // cut at the terminating #0
      Result := ExcludeTrailingPathDelimiter(UTF8Encode(Remote));
      // Only accept a real UNC root
      if Copy(Result, 1, 2) <> '\\' then
        Result := '';
    end;
  end;

  if Assigned(DriveMapLock) then
  begin
    DriveMapLock.Enter;
    try
      DriveMapCache[ADrive].Checked := True;
      DriveMapCache[ADrive].Tick    := NowTick;
      DriveMapCache[ADrive].UNCRoot := Result;
    finally
      DriveMapLock.Leave;
    end;
  end;
end;
{$ENDIF}

// ---> AUDIT FIX F1: Normalizes separators, resolves '.'/'..' and relative
// segments (ExpandFileName), and expands 8.3 short names to long names so the
// same file always maps to the same registry key.
// ---> AUDIT FIX: A path on a mapped network drive ('Z:\Music\x.flac') is
// rewritten to its UNC spelling ('\\nas\share\Music\x.flac'), so both
// spellings of the same file share one registry key.
function NormalizeLockPath(const AFilePath: string): string;
{$IFDEF WINDOWS}
var
  WideIn, WideOut: UnicodeString;
  Len: LongWord;
  UNCRoot: string;
{$ENDIF}
begin
  Result := Trim(AFilePath);
  if Result = '' then
    Exit;
  if Pos('/', Result) > 0 then
    Result := SetDirSeparators(Result);
  Result := ExpandFileName(Result);

  {$IFDEF WINDOWS}
  // Only needed when a '~' suggests an 8.3 short-name component
  if Pos('~', Result) > 0 then
  begin
    WideIn := UTF8Decode(Result);
    WideOut := '';
    SetLength(WideOut, 32768);
    Len := AL_GetLongPathNameW(PWideChar(WideIn), PWideChar(WideOut), Length(WideOut));
    if (Len > 0) and (Len < LongWord(Length(WideOut))) then
    begin
      SetLength(WideOut, Len);
      Result := UTF8Encode(WideOut);
    end;
  end;

  // Mapped network drive -> UNC
  if (Length(Result) >= 3) and (Result[2] = ':') and (Result[3] = '\') then
  begin
    UNCRoot := GetMappedDriveUNCRoot(Result[1]);
    if UNCRoot <> '' then
      Result := UNCRoot + Copy(Result, 3, MaxInt);
  end;
  {$ENDIF}
end;

function FileLockRegistry: TFileLockRegistry;
begin
  Result := GlobalRegistry;
end;

procedure FreeFileLockRegistry;
begin
  if Assigned(GlobalRegistry) then
    FreeAndNil(GlobalRegistry);

  WriteShutDownTrace(' * [uFileLockRegistry] object GlobalRegistry is destroyed.');
end;

{ TFileLockRegistry }

constructor TFileLockRegistry.Create;
begin
  inherited Create;
  FLock                      := TCriticalSection.Create;
  FLockedFiles               := TStringList.Create;
  FLockedFiles.Sorted        := True;
  FLockedFiles.Duplicates    := dupIgnore;
  FLockedFiles.CaseSensitive := False; // Case-insensitive for Windows filesystem paths
end;

destructor TFileLockRegistry.Destroy;
begin
  FLockedFiles.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFileLockRegistry.AcquireLock(const AFilePath: string);
var
  Idx: Integer;
  RefCount: PtrInt;
  NormPath: string;
begin
  if (Self = nil) or (AFilePath = '') then
    Exit;

  NormPath := NormalizeLockPath(AFilePath);
  if NormPath = '' then
    Exit;

  FLock.Enter;
  try
    if FLockedFiles.Find(NormPath, Idx) then
    begin
      RefCount                  := PtrInt(FLockedFiles.Objects[Idx]) + 1;
      FLockedFiles.Objects[Idx] := TObject(RefCount);
    end
    else
      FLockedFiles.AddObject(NormPath, TObject(PtrInt(1)));
  finally
    FLock.Leave;
  end;
end;

procedure TFileLockRegistry.ReleaseLock(const AFilePath: string);
var
  Idx: Integer;
  RefCount: PtrInt;
  NormPath: string;
begin
  if (Self = nil) or (AFilePath = '') then
    Exit;

  NormPath := NormalizeLockPath(AFilePath);
  if NormPath = '' then
    Exit;

  FLock.Enter;
  try
    if FLockedFiles.Find(NormPath, Idx) then
    begin
      RefCount := PtrInt(FLockedFiles.Objects[Idx]) - 1;
      if RefCount <= 0 then
        FLockedFiles.Delete(Idx)
      else
        FLockedFiles.Objects[Idx] := TObject(RefCount);
    end;
  finally
    FLock.Leave;
  end;
end;

function TFileLockRegistry.IsFileBusy(const AFilePath: string): Boolean;
var
  Idx: Integer;
  NormPath: string;
begin
  Result := False;
  if (Self = nil) or (AFilePath = '') then
    Exit;

  NormPath := NormalizeLockPath(AFilePath);
  if NormPath = '' then
    Exit;

  FLock.Enter;
  try
    Result := FLockedFiles.Find(NormPath, Idx);
  finally
    FLock.Leave;
  end;
end;

initialization
  {$IFDEF WINDOWS}
  DriveMapLock   := TCriticalSection.Create;
  {$ENDIF}
  GlobalRegistry := TFileLockRegistry.Create;

finalization
  {$IFDEF WINDOWS}
  FreeAndNil(DriveMapLock);
  {$ENDIF}

end.
