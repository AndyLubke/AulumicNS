unit uOSUtils;

{$mode ObjFPC}{$H+}

// =============================================================================
// AulumicNS - uOSUtils
// Copyright (C) 2026 André Lubke
// Licensed under the GNU General Public License, version 3 (see LICENSE).
//
// Helper routines for OS related stuff.
// =============================================================================

interface

uses
  Windows, ShellApi, Classes, SysUtils, Forms, buttons, controls, extCtrls,
  comctrls, graphics, DateUtils, Menus, uAppConsts;

type
  TFileNameError = (feValid, feEmpty, feIllegalChar);

function IsDriveRootMissing(const APath: String): boolean;
// False only when APath is on a drive letter that is not there (unplugged).
// Uses GetLogicalDrives, so it never waits for a sleeping drive. Network
// paths (\\server\share) always count as present.
function IsDrivePresent(const APath: String): boolean;

function InvalidFileNameChar(aFileNameChar: Char): boolean;
function SanitizeAndValidateFileName(var aFileName: string): TFileNameError;
// True for Windows reserved device names (CON, PRN, AUX, NUL,
// COM1..COM9, LPT1..LPT9), also with an extension ("nul.txt") or trailing spaces.
function IsReservedDeviceName(const AName: string): boolean;

// === Shared Menu Actions ===
procedure RevealFileInExplorer(const FilePath: string);

// CPU Monitor
function GetAppCPUUsage: double;

// Explicit destructor, called from FreeAppSingletons (uAppLifetime)
procedure FreeOSUtilsSingletons;

// Check if a file is locked
function IsFileLocked(const AFileName: string): boolean;

// True when the file cannot be replaced (renamed / deleted) right
// now, i.e. some process holds it open WITHOUT delete sharing (for example
// the program's own audio reader). Readers that allow replacement, such as virus
// scanners or the search indexer, do not block. This is exactly the condition
// a tag save (temp file + MoveFileEx) needs.
function IsFileReplaceBlocked(const AFileName: string): boolean;

// Names the processes that currently have AFileName open (via the
// Windows Restart Manager), e.g. 'MsMpEng.exe (PID 4120)' or 'Aulumic itself'.
// Returns '' when nothing is found or the information is unavailable.
function DescribeFileUsers(const AFileName: string): string;

// Centralized Atomic File Operations
function CommitAtomicFile(const ATempFile, ATargetFile: string; out AErrorMsg: string; AWriteThrough: Boolean = True): boolean; overload;
function CommitAtomicFile(const ATempFile, ATargetFile: string; AWriteThrough: Boolean = True): boolean; overload;
function SaveStringsAtomic(ALines: TStrings; const ATargetFile: string; out AErrorMsg: string; AEncoding: TEncoding = nil): boolean; overload;
function SaveStringsAtomic(ALines: TStrings; const ATargetFile: string; AEncoding: TEncoding = nil): boolean; overload;
function SaveStreamAtomic(AStream: TStream; const ATargetFile: string; AWriteThrough: Boolean = True): boolean;

// Copies AFileName to "<AFileName>.yyyymmdd-hhnnss.bak" (never overwrites an
// existing backup). Returns True and the backup path on success.
function BackupFileWithTimestamp(const AFileName: string; out ABackupPath: string): boolean;

function SafeFormat(const Fmt: string; const Args: array of const; const DefaultFmt: string = ''): string;

procedure RateLimitThreadUI(AThread: TThread; var ALastTick: QWord; AMethod: TThreadMethod);

// Opts the process out of Windows power throttling (EcoQoS): the
// CPU speed is not lowered and the 1 ms timer request is honoured also when
// the window is minimized or hidden (Windows 11). False = back to the Windows
// default. Returns False when not supported (before Windows 10 1709).
function SetPowerThrottlingOptOut(AOptOut: Boolean): Boolean;

implementation

uses
  LCLIntf, SyncObjs, uCrashTracer, uAppStrings,
  AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  // Win32 MoveFileExW flags for atomic NTFS file replacement
  WIN32_MOVEFILE_REPLACE_EXISTING = $00000001;
  WIN32_MOVEFILE_WRITE_THROUGH    = $00000008;

type
  TAppCPUMonitor = class
  private
    FLastSysTime   : Int64;
    FLastProcTime  : Int64;
    FLock          : TCriticalSection;
    FLastResult    : Double;
    FLastCheckTick : QWord;
    FProcessorCount: DWORD;
  public
    constructor Create;
    destructor Destroy; override;
    function GetUsage: Double;
  end;

var
  GlobalCPUMonitor: TAppCPUMonitor = nil;

{ TAppCPUMonitor }

constructor TAppCPUMonitor.Create;
var
  SysInfo: TSystemInfo;
begin
  inherited Create;
  FLastSysTime   := 0;
  FLastProcTime  := 0;
  FLastResult    := 0.0;
  FLastCheckTick := 0;
  FLock          := TCriticalSection.Create;

  // Zero-initialize SysInfo via Default() to silence compiler hint
  SysInfo := Default(TSystemInfo);
  GetSystemInfo(SysInfo);
  if SysInfo.dwNumberOfProcessors > 0 then
    FProcessorCount := SysInfo.dwNumberOfProcessors
  else
    FProcessorCount := 1;
end;

destructor TAppCPUMonitor.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TAppCPUMonitor.GetUsage: Double;
var
  CreationTime, ExitTime, KernelTime, UserTime: TFileTime;
  SysTime: TSystemTime;
  SysTimeAsFileTime: TFileTime;
  SysTime64, ProcTime64, SysDiff, ProcDiff: int64;
  CurrentTick: QWord;
begin
  // Initialize Win32 out structs to silence Hint 5057
  CreationTime      := Default(TFileTime);
  ExitTime          := Default(TFileTime);
  KernelTime        := Default(TFileTime);
  UserTime          := Default(TFileTime);
  SysTime           := Default(TSystemTime);
  SysTimeAsFileTime := Default(TFileTime);

  FLock.Enter;
  try
    CurrentTick := GetTickCount64;
    if (CurrentTick - FLastCheckTick) < 500 then
    begin
      Result := FLastResult;
      Exit;
    end;

    Result := FLastResult;

    GetSystemTime(SysTime);
    SystemTimeToFileTime(SysTime, SysTimeAsFileTime);
    SysTime64 := PInt64(@SysTimeAsFileTime)^;

    if GetProcessTimes(GetCurrentProcess(), CreationTime, ExitTime, KernelTime, UserTime) then
    begin
      ProcTime64 := PInt64(@KernelTime)^ + PInt64(@UserTime)^;

      if FLastSysTime > 0 then
      begin
        SysDiff  := SysTime64 - FLastSysTime;
        ProcDiff := ProcTime64 - FLastProcTime;

        if SysDiff > 0 then
        begin
          Result := ((ProcDiff / SysDiff) * 100.0) / FProcessorCount;
          if Result < 0.0 then
            Result := 0.0
          else if Result > 100.0 then
            Result := 100.0;
          FLastResult := Result;
        end;
      end;

      FLastSysTime   := SysTime64;
      FLastProcTime  := ProcTime64;
      FLastCheckTick := CurrentTick;
    end;
  finally
    FLock.Leave;
  end;
end;

function GetAppCPUUsage: double;
begin
  if Assigned(GlobalCPUMonitor) then
    Result := GlobalCPUMonitor.GetUsage
  else
    Result := 0.0;
end;

procedure FreeOSUtilsSingletons;
begin
  if Assigned(GlobalCPUMonitor) then
    FreeAndNil(GlobalCPUMonitor);

  WriteShutDownTrace(' * [uOSUtils] object GlobalCPUMonitor is destroyed.');
end;

// =============================================================================
// Direct Win32 CreateFileW lock test.
// Eliminates TFileStream heap allocation and EFOpenError exception unwinding
// (and prevents Lazarus IDE debugger breakups when testing locked audio files).
// =============================================================================
function IsFileLocked(const AFileName: string): boolean;
{$IFDEF WINDOWS}
var
  WidePath: UnicodeString;
  HFile: THandle;
  Err: DWORD;
begin
  Result := False;
  if AFileName = '' then
    Exit;

  WidePath := UTF8Decode(LongPath(AFileName));
  HFile    := Windows.CreateFileW(
    PWideChar(WidePath),
    GENERIC_READ or GENERIC_WRITE,
    0, // Exclusive access (0 = no sharing)
    nil,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    0
  );

  if HFile <> INVALID_HANDLE_VALUE then
  begin
    Windows.CloseHandle(HFile);
    Result := False;
  end
  else
  begin
    Err := Windows.GetLastError;
    if (Err = ERROR_FILE_NOT_FOUND) or (Err = ERROR_PATH_NOT_FOUND) then
      Result := False
    else if Err = ERROR_ACCESS_DENIED then
    begin
      // A read-only file (or read-only media) refuses
      // GENERIC_WRITE even when nobody has it open. Re-test with read access only,
      // still exclusive, so it is not misreported as "locked by another process".
      HFile := Windows.CreateFileW(PWideChar(WidePath), GENERIC_READ, 0, nil,
                                   OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
      if HFile <> INVALID_HANDLE_VALUE then
      begin
        Windows.CloseHandle(HFile);
        Result := False;
      end
      else
        Result := True;
    end
    else
      Result := True;
  end;
end;
{$ELSE}
var
  F: TFileStream;
begin
  Result := False;
  if not FileExists(LongPath(AFileName)) then
    Exit;
  try
    F := TFileStream.Create(LongPath(AFileName), fmOpenWrite or fmShareExclusive);
    F.Free;
  except
    Result := True;
  end;
end;
{$ENDIF}

// =============================================================================
// Replace-ability check and lock diagnostics
// =============================================================================
function IsFileReplaceBlocked(const AFileName: string): boolean;
{$IFDEF WINDOWS}
const
  AL_DELETE            = $00010000;
  AL_FILE_SHARE_ALL    = $00000007; // READ or WRITE or DELETE
var
  WidePath : UnicodeString;
  HFile    : THandle;
  Err      : DWORD;
begin
  Result := False;
  if AFileName = '' then
    Exit;

  WidePath := UTF8Decode(LongPath(AFileName));
  // Requesting DELETE access while sharing everything fails only when another
  // handle was opened without FILE_SHARE_DELETE, i.e. when MoveFileEx could not
  // replace the file.
  HFile := Windows.CreateFileW(PWideChar(WidePath), AL_DELETE, AL_FILE_SHARE_ALL,
                               nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if HFile <> INVALID_HANDLE_VALUE then
  begin
    Windows.CloseHandle(HFile);
    Exit(False);
  end;

  Err := Windows.GetLastError;
  if (Err = ERROR_FILE_NOT_FOUND) or (Err = ERROR_PATH_NOT_FOUND) then
    Result := False
  else
    Result := True;
end;
{$ELSE}
begin
  Result := IsFileLocked(AFileName);
end;
{$ENDIF}

function DescribeFileUsers(const AFileName: string): string;
{$IFDEF WINDOWS}
const
  AL_LOAD_LIBRARY_SEARCH_SYSTEM32 = $00000800;
  AL_ERROR_MORE_DATA              = 234;
  CCH_RM_SESSION_KEY              = 32;
  CCH_RM_MAX_APP_NAME             = 255;
  CCH_RM_MAX_SVC_NAME             = 63;
  MAX_PROCS                       = 16;
type
  TRmUniqueProcess = record
    dwProcessId      : DWORD;
    ProcessStartTime : TFileTime;
  end;
  TRmProcessInfo = record
    Process             : TRmUniqueProcess;
    strAppName          : array[0..CCH_RM_MAX_APP_NAME] of WideChar;
    strServiceShortName : array[0..CCH_RM_MAX_SVC_NAME] of WideChar;
    ApplicationType     : DWORD;
    AppStatus           : DWORD;
    TSSessionId         : DWORD;
    bRestartable        : BOOL;
  end;
  // Named, so Default() can zero them (no "not initialized" hint)
  TRmSessionKey         = array[0..CCH_RM_SESSION_KEY] of WideChar;
  TRmProcessInfos       = array[0..MAX_PROCS - 1] of TRmProcessInfo;
  TRmStartSession       = function(out pSessionHandle: DWORD; dwSessionFlags: DWORD;
                            strSessionKey: PWideChar): DWORD; stdcall;
  TRmRegisterResources  = function(dwSessionHandle: DWORD; nFiles: UINT;
                            rgsFilenames: Pointer; nApplications: UINT;
                            rgApplications: Pointer; nServices: UINT;
                            rgsServiceNames: Pointer): DWORD; stdcall;
  TRmGetList            = function(dwSessionHandle: DWORD; var pnProcInfoNeeded: UINT;
                            var pnProcInfo: UINT; rgAffectedApps: Pointer;
                            var lpdwRebootReasons: DWORD): DWORD; stdcall;
  TRmEndSession         = function(dwSessionHandle: DWORD): DWORD; stdcall;
var
  Lib            : HMODULE;
  RmStart        : TRmStartSession;
  RmRegister     : TRmRegisterResources;
  RmList         : TRmGetList;
  RmEnd          : TRmEndSession;
  Session        : DWORD;
  SessionKey     : TRmSessionKey;
  WidePath       : UnicodeString;
  PathPtr        : PWideChar;
  Needed, Count  : UINT;
  Reasons        : DWORD;
  Infos          : TRmProcessInfos;
  Res            : DWORD;
  I              : Integer;
  Name           : string;
begin
  Result := '';
  if AFileName = '' then
    Exit;

  // rstrtmgr.dll is part of Windows; load it from System32 only
  Lib := Windows.LoadLibraryExW('rstrtmgr.dll', 0, AL_LOAD_LIBRARY_SEARCH_SYSTEM32);
  if Lib = 0 then
    Exit;
  try
    Pointer(RmStart)    := Windows.GetProcAddress(Lib, 'RmStartSession');
    Pointer(RmRegister) := Windows.GetProcAddress(Lib, 'RmRegisterResources');
    Pointer(RmList)     := Windows.GetProcAddress(Lib, 'RmGetList');
    Pointer(RmEnd)      := Windows.GetProcAddress(Lib, 'RmEndSession');
    if (not Assigned(RmStart)) or (not Assigned(RmRegister)) or
       (not Assigned(RmList)) or (not Assigned(RmEnd)) then
      Exit;

    SessionKey := Default(TRmSessionKey);
    if RmStart(Session, 0, @SessionKey[0]) <> 0 then
      Exit;
    try
      WidePath := UTF8Decode(AFileName);
      PathPtr  := PWideChar(WidePath);
      if RmRegister(Session, 1, @PathPtr, 0, nil, 0, nil) <> 0 then
        Exit;

      Infos := Default(TRmProcessInfos);
      Needed  := 0;
      Count   := MAX_PROCS;
      Reasons := 0;
      Res := RmList(Session, Needed, Count, @Infos[0], Reasons);
      if (Res <> 0) and (Res <> AL_ERROR_MORE_DATA) then
        Exit;
      // More users than slots: the array is not filled in that case
      if Res = AL_ERROR_MORE_DATA then
        Exit(SafeFormat(FMT_LOG_FILE_USERS_MANY, [Needed]));

      for I := 0 to Integer(Count) - 1 do
      begin
        if Infos[I].Process.dwProcessId = Windows.GetCurrentProcessId then
          Name := LOG_FILE_USER_SELF
        else
        begin
          Name := UTF8Encode(UnicodeString(PWideChar(@Infos[I].strAppName[0])));
          if Name = '' then
            Name := LOG_FILE_USER_UNKNOWN;
          Name := SafeFormat(FMT_LOG_FILE_USER_PID, [Name, Infos[I].Process.dwProcessId]);
        end;

        if Result <> '' then
          Result := Result + ', ';
        Result := Result + Name;
      end;
    finally
      RmEnd(Session);
    end;
  finally
    Windows.FreeLibrary(Lib);
  end;
end;
{$ELSE}
begin
  Result := '';
end;
{$ENDIF}

// =============================================================================
// Centralized Atomic File Replacement, Stream & TStrings Savers
// =============================================================================

function CommitAtomicFile(const ATempFile, ATargetFile: string; out AErrorMsg: string; AWriteThrough: Boolean = True): boolean;
{$IFDEF WINDOWS}
var
  WideTemp, WideTarget: UnicodeString;
  Flags, ErrCode: DWORD;
{$ENDIF}
begin
  Result    := False;
  AErrorMsg := '';

  if (ATempFile = '') or (ATargetFile = '') then
  begin
    AErrorMsg := ERR_INVALID_FILE_PATH;
    Exit;
  end;

  {$IFDEF WINDOWS}
  WideTemp   := UTF8Decode(LongPath(ATempFile));
  WideTarget := UTF8Decode(LongPath(ATargetFile));

  Flags := WIN32_MOVEFILE_REPLACE_EXISTING;
  if AWriteThrough then
    Flags := Flags or WIN32_MOVEFILE_WRITE_THROUGH;

  if Windows.MoveFileExW(PWideChar(WideTemp), PWideChar(WideTarget), Flags) then
  begin
    Result := True;
  end
  else
  begin
    ErrCode   := Windows.GetLastError;
    AErrorMsg := SafeFormat(FMT_ERR_OS_ERROR, [ErrCode, SysErrorMessage(ErrCode)]);
    if SysUtils.FileExists(LongPath(ATempFile)) then
    begin
      try
        SysUtils.DeleteFile(LongPath(ATempFile));
      except
      end;
    end;
  end;
  {$ELSE}
  try
    if SysUtils.FileExists(LongPath(ATargetFile)) then
      SysUtils.DeleteFile(LongPath(ATargetFile));
    Result := SysUtils.RenameFile(LongPath(ATempFile), LongPath(ATargetFile));
    if not Result then
      AErrorMsg := ERR_RENAME_FAILED;
  except
    on E: Exception do
      AErrorMsg := E.Message;
  end;

  if (not Result) and SysUtils.FileExists(LongPath(ATempFile)) then
  begin
    try
      SysUtils.DeleteFile(LongPath(ATempFile));
    except
    end;
  end;
  {$ENDIF}
end;

function CommitAtomicFile(const ATempFile, ATargetFile: string; AWriteThrough: Boolean = True): boolean;
var
  DummyErr: string;
begin
  Result := CommitAtomicFile(ATempFile, ATargetFile, DummyErr, AWriteThrough);
end;

// Flushes the temp file contents via FlushFileBuffers before the
// atomic rename when AWriteThrough is True
function SaveStreamAtomic(AStream: TStream; const ATargetFile: string; AWriteThrough: Boolean = True): boolean;
var
  TempFile, TargetDir: string;
  FS: TFileStream;
begin
  Result := False;
  if (not Assigned(AStream)) or (Trim(ATargetFile) = '') then
    Exit;

  TargetDir := ExtractFileDir(ATargetFile);
  if (TargetDir <> '') and (not DirectoryExists(LongPath(TargetDir))) then
    ForceDirectories(TargetDir);

  TempFile := ATargetFile + '.tmp';
  try
    FS := TFileStream.Create(LongPath(TempFile), fmCreate);
    try
      if AStream is TMemoryStream then
      begin
        if TMemoryStream(AStream).Size > 0 then
          FS.WriteBuffer(TMemoryStream(AStream).Memory^, TMemoryStream(AStream).Size);
      end
      else if AStream.Size > 0 then
      begin
        AStream.Position := 0;
        FS.CopyFrom(AStream, AStream.Size);
      end;

      {$IFDEF WINDOWS}
      if AWriteThrough then
        Windows.FlushFileBuffers(FS.Handle);
      {$ENDIF}
    finally
      FS.Free;
    end;

    Result := CommitAtomicFile(TempFile, ATargetFile, AWriteThrough);
  except
    if SysUtils.FileExists(LongPath(TempFile)) then
    begin
      try
        SysUtils.DeleteFile(LongPath(TempFile));
      except
      end;
    end;
  end;
end;

// Writes via TFileStream and calls FlushFileBuffers(FS.Handle) before
// CommitAtomicFile, so the file data is durable on disk prior to the rename
function SaveStringsAtomic(ALines: TStrings; const ATargetFile: string; out AErrorMsg: string; AEncoding: TEncoding = nil): boolean;
var
  TempFile: string;
  TargetDir: string;
  FS: TFileStream;
begin
  Result    := False;
  AErrorMsg := '';

  if (not Assigned(ALines)) or (Trim(ATargetFile) = '') then
  begin
    AErrorMsg := ERR_ATOMIC_SAVE_PARAMS;
    Exit;
  end;

  TargetDir := ExtractFileDir(ATargetFile);
  if (TargetDir <> '') and (not DirectoryExists(LongPath(TargetDir))) then
    ForceDirectories(TargetDir);

  TempFile := ATargetFile + '.tmp';

  try
    FS := TFileStream.Create(LongPath(TempFile), fmCreate);
    try
      if Assigned(AEncoding) then
        ALines.SaveToStream(FS, AEncoding)
      else
        ALines.SaveToStream(FS, TEncoding.UTF8);

      {$IFDEF WINDOWS}
      Windows.FlushFileBuffers(FS.Handle);
      {$ENDIF}
    finally
      FS.Free;
    end;

    Result := CommitAtomicFile(TempFile, ATargetFile, AErrorMsg, True);
  except
    on E: Exception do
    begin
      AErrorMsg := E.Message;
      if SysUtils.FileExists(LongPath(TempFile)) then
      begin
        try
          SysUtils.DeleteFile(LongPath(TempFile));
        except
        end;
      end;
    end;
    else
    begin
      AErrorMsg := ERR_ATOMIC_SAVE_UNKNOWN;
      if SysUtils.FileExists(LongPath(TempFile)) then
      begin
        try
          SysUtils.DeleteFile(LongPath(TempFile));
        except
        end;
      end;
    end;
  end;
end;

function SaveStringsAtomic(ALines: TStrings; const ATargetFile: string; AEncoding: TEncoding = nil): boolean;
var
  DummyErr: string;
begin
  Result := SaveStringsAtomic(ALines, ATargetFile, DummyErr, AEncoding);
end;

function IsDriveRootMissing(const APath: String): boolean;
var
  DriveRoot: String;
begin
  Result    := False;
  DriveRoot := ExtractFileDrive(Trim(APath));
  if (DriveRoot <> '') and
     (not DirectoryExists(LongPath(IncludeTrailingPathDelimiter(DriveRoot)))) then
    Result := True;
end;

function IsDrivePresent(const APath: String): boolean;
var
  Drive: String;
  Bit: Integer;
begin
  Result := True;
  Drive  := ExtractFileDrive(Trim(APath));
  if (Length(Drive) = 2) and (Drive[2] = ':') then
  begin
    Bit := Ord(UpCase(Drive[1])) - Ord('A');
    Result := (Bit >= 0) and (Bit <= 25) and
              ((GetLogicalDrives and (DWORD(1) shl Bit)) <> 0);
  end;
end;

const
  InvalidChars = ['\', '/', ':', '*', '?', '"', '<', '>', '|'];

function InvalidFileNameChar(aFileNameChar: Char): boolean;
begin
  Result := aFileNameChar in InvalidChars;
end;

function SanitizeAndValidateFileName(var aFileName: string): TFileNameError;
var
  I: integer;
begin
  aFileName := Trim(aFileName);

  // Clean trailing dots
  while (Length(aFileName) > 0) and (aFileName[Length(aFileName)] = '.') do
    Delete(aFileName, Length(aFileName), 1);

  // Make sure there were no spaces hiding before the trailing dot
  aFileName := Trim(aFileName);

  // An empty string is not a valid file name
  if Length(aFileName) = 0 then
  begin
    Result := feEmpty;
    Exit;
  end;

  Result := feValid;

  for I := 1 to Length(aFileName) do
  begin
    if InvalidFileNameChar(aFileName[I]) then
    begin
      Result := feIllegalChar;
      Exit;
    end;
  end;

  // Windows cannot create files named after a device
  // (CON, NUL, AUX, ...), so treat them like an illegal name.
  if IsReservedDeviceName(aFileName) then
    Result := feIllegalChar;
end;

function IsReservedDeviceName(const AName: string): boolean;
var
  Base: string;
  P: Integer;
begin
  Result := False;

  // Only the part before the first dot counts ("CON.alpl" is still CON)
  Base := AName;
  P    := Pos('.', Base);
  if P > 0 then
    Base := Copy(Base, 1, P - 1);
  Base := UpperCase(Trim(Base));

  if (Base = 'CON') or (Base = 'PRN') or (Base = 'AUX') or (Base = 'NUL') then
    Exit(True);

  if (Length(Base) = 4) and
     ((Copy(Base, 1, 3) = 'COM') or (Copy(Base, 1, 3) = 'LPT')) and
     (Base[4] in ['1'..'9']) then
    Exit(True);
end;

procedure RevealFileInExplorer(const FilePath: string);
var
  {$IFDEF WINDOWS}
  Params: UnicodeString;
  {$ENDIF}
  OldCursor: TCursor;
  Found: Boolean;
begin
  if Trim(FilePath) = '' then
    Exit;

  // The check below wakes a sleeping drive: show the hourglass meanwhile
  Found         := False;
  OldCursor     := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    Found := FileExists(LongPath(FilePath)) or DirectoryExists(LongPath(FilePath));
  finally
    Screen.Cursor := OldCursor;
  end;
  if not Found then
    Exit;

  {$IFDEF WINDOWS}
  // Direct ShellExecuteW avoids TProcess allocation and keeps
  // '/select,"Path"' attached without an intermediate space.
  Params := UTF8Decode('/select,"' + FilePath + '"');
  ShellExecuteW(0, 'open', 'explorer.exe', PWideChar(Params), nil, SW_SHOWNORMAL);
  {$ELSE}
  OpenDocument(ExtractFileDir(FilePath));
  {$ENDIF}
end;

function BackupFileWithTimestamp(const AFileName: string; out ABackupPath: string): boolean;
begin
  Result      := False;
  ABackupPath := '';
  if (AFileName = '') or (not FileExists(LongPath(AFileName))) then
    Exit;

  ABackupPath := AFileName + '.' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.bak';
  try
    {$IFDEF WINDOWS}
    // bFailIfExists = True: never clobber an earlier backup
    Result := Windows.CopyFileW(PWideChar(UTF8Decode(LongPath(AFileName))),
                                PWideChar(UTF8Decode(LongPath(ABackupPath))), True);
    {$ELSE}
    Result := False;
    {$ENDIF}
  except
    Result := False;
  end;

  if not Result then
    ABackupPath := '';
end;

function SafeFormat(const Fmt: string; const Args: array of const; const DefaultFmt: string = ''): string;
begin
  try
    Result := Format(Fmt, Args);
  except
    if DefaultFmt <> '' then
    begin
      try
        Result := Format(DefaultFmt, Args);
      except
        Result := DefaultFmt;
      end;
    end
    else
      Result := Fmt;
  end;
end;

procedure RateLimitThreadUI(AThread: TThread; var ALastTick: QWord; AMethod: TThreadMethod);
var
  CurrentTick: QWord;
begin
  if (not Assigned(AThread)) or (not Assigned(AMethod)) then
    Exit;

  CurrentTick := GetTickCount64;
  if (CurrentTick - ALastTick) > THREAD_DELAY_MS then
  begin
    ALastTick := CurrentTick;
    TThread.Queue(AThread, AMethod);
  end;
end;

function SetPowerThrottlingOptOut(AOptOut: Boolean): Boolean;
type
  TPowerThrottlingState = record
    Version     : ULONG;
    ControlMask : ULONG;
    StateMask   : ULONG;
  end;
  TSetProcessInformation = function(hProcess: THandle; AInfoClass: Integer;
    AInfo: Pointer; AInfoSize: DWORD): BOOL; stdcall;
const
  AL_PROCESS_POWER_THROTTLING                   = 4;   // ProcessPowerThrottling
  AL_POWER_THROTTLING_VERSION                   = 1;
  AL_POWER_THROTTLING_EXECUTION_SPEED           = $1;
  AL_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION   = $4;  // Windows 11
var
  SetProcInfo: TSetProcessInformation;
  State: TPowerThrottlingState;
begin
  Result := False;
  Pointer(SetProcInfo) := Windows.GetProcAddress(
    Windows.GetModuleHandleW('kernel32.dll'), 'SetProcessInformation');
  if not Assigned(SetProcInfo) then
    Exit;

  State.Version   := AL_POWER_THROTTLING_VERSION;
  State.StateMask := 0;  // 0 for a controlled flag = never throttle
  if AOptOut then
    State.ControlMask := AL_POWER_THROTTLING_EXECUTION_SPEED or
                         AL_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION
  else
    State.ControlMask := 0;  // nothing controlled = Windows decides

  Result := SetProcInfo(Windows.GetCurrentProcess, AL_PROCESS_POWER_THROTTLING,
              @State, SizeOf(State));

  // Windows 10 does not know the timer flag: then the CPU speed only
  if (not Result) and AOptOut then
  begin
    State.ControlMask := AL_POWER_THROTTLING_EXECUTION_SPEED;
    Result := SetProcInfo(Windows.GetCurrentProcess, AL_PROCESS_POWER_THROTTLING,
                @State, SizeOf(State));
  end;
end;

initialization
  GlobalCPUMonitor := TAppCPUMonitor.Create;

end.
