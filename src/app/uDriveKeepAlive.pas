unit uDriveKeepAlive;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uDriveKeepAlive
  Author:    André Lubke
  Created:   2026

  Keeps the drives of the current and the next track awake during playback
  (Preferences > System > Keep Music Drives Awake During Playback), so a
  sleeping USB hard disk or NAS does not pause the music at a track change.

  How: every KEEPALIVE_INTERVAL_MS one small block (KEEPALIVE_BLOCK_SIZE) is
  READ from each target file - nothing is ever written, so there is no wear.
    * Uncached (FILE_FLAG_NO_BUFFERING): Windows cannot answer from its file
      cache, the read really reaches the drive (or the NAS).
    * At a different offset every round (KEEPALIVE_OFFSET_STEP further), so
      the drive's own cache or the NAS memory cannot answer it either.
    * One read per drive: when the current and the next track are on the same
      drive (or share), only the next track is read.
    * The file is opened read-only with full sharing and closed right away, so
      it never blocks a tag save or the player.

  ---> ADDED: WakeDrives / FindOfflineDrives: before the UI thread reads files
  on drives that may be asleep (Properties, Add Files, playlist import, ...),
  a short-lived worker thread wakes them (or checks they can be reached)
  while the window keeps responding. A thread that does not end in time (a
  cancelled wake; at exit the playback I/O worker or this keep-alive thread
  blocked by a drive) is set aside (SetThreadAside): its file access is
  aborted where Windows can (CancelSynchronousIo) and it is freed once it
  has ended, never by itself; FinishSetAsideThreads at exit.
  ---> CHANGED: The abort runs on a helper thread (TFileAccessCanceller):
  CancelSynchronousIo waits until a USB disk that is spinning up has answered,
  and on the UI thread that froze Aulumic after Cancel. The UI thread never
  calls it.
  ---> ADDED: A network drive (a share or a mapped drive letter) whose server
  does not answer at all (switched off, no network) is found within
  NAS_ANSWER_TIMEOUT_MS by a short connection attempt (ServerAnswers) and is
  not touched: Windows would wait 20-60 s for every access to it. WakeDrives
  reports it, so the caller does not read its files either.
  Covered by Tests\TestDriveWake.pas.

  Safety rules (as in uPlaybackIOWorker):
    1. One thread, owned by TPlaybackManager, lowest priority.
    2. The UI thread only hands over two paths (SetTargets); the thread copies
       them under a lock and never touches other objects.
    3. Each read runs inside try..except; errors (drive gone, file moved) are
       ignored, the next round simply tries again.
    4. Shutdown waits a limited time. A thread still blocked on a sleeping or
       unreachable drive is set aside (SetThreadAside) and freed once it has
       ended.
  =============================================================================}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  { TDriveKeepAlive }

  TDriveKeepAlive = class(TThread)
  private
    FLock      : SyncObjs.TCriticalSection;
    FStopEvent : SyncObjs.TEvent;
    FCurrent   : string;   // guarded by FLock
    FNext      : string;   // guarded by FLock
    FRound     : Cardinal; // thread only
    FLostDrive : string;   // guarded by FLock: drive that could not be reached ('' = all fine)
    function ReadBlock(const APath: string; ABuffer: Pointer): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;

    // UI thread: the files to keep awake ('' = none)
    procedure SetTargets(const ACurrentFile, ANextFile: string);

    // Stops the thread; returns False if it did not finish within ATimeoutMs
    function Shutdown(ATimeoutMs: Cardinal): Boolean;

    // UI thread: the drive (e.g. 'E:' or '\\NAS\Music') that could not be
    // reached in the last round, '' when all targets were reachable
    function LostDrive: string;
  end;

// ---> ADDED: Reads the first block of APath uncached (normal read as
// fallback), so a sleeping drive spins up now. Blocks until the drive answers;
// call it from a worker thread only. False when nothing could be read.
function WakeFile(const APath: string): Boolean;

// =============================================================================
// ---> ADDED: Waking drives before the UI thread reads them. While a sleeping
// USB disk or NAS spins up, the first access blocks for seconds; done on the
// UI thread, Aulumic stops responding (Windows then shows a "Not Responding"
// stand-in of its windows). These run that first access on a worker thread
// and let the window handle messages meanwhile, so it stays responsive and
// Cancel works; afterwards the UI thread's own reads are fast.
// =============================================================================
type
  // Called about every 20 ms while WakeDrives / FindOfflineDrives wait. It lets
  // Windows handle messages (and may update a "Waiting for drive..." text);
  // True = stop waiting (Cancel).
  TDriveWaitFunc = function: Boolean of object;

  // Tests only: replaces the access that wakes one path (see DriveWakeProc)
  TDriveWakeProc = function(const APath: string): Boolean;

  // ---> ADDED: Whether the server of a network drive answers (ServerAnswers)
  TShareAnswer = (
    saAnswers,     // it answered (connected or refused): the machine is there
    saNoAnswer,    // its name was found, but nothing answered in time
    saNotChecked   // a local drive, or its name could not be looked up: nothing known
  );

  // Tests only: replaces the answer check of one drive (see DriveAnswerProc)
  TDriveAnswerProc = function(const ADrive: string): TShareAnswer;

  // ---> ADDED: Tests only: replaces the abort of a thread's file access
  // (see FileAccessCancelProc)
  TFileAccessCancelProc = function(AThreadHandle: THandle): Boolean;

// The drive of a path as the wake functions group it: 'C:' or '\\NAS\Music'
// ('' for a relative path)
function DriveOfPath(const APath: string): string;

// ---> ADDED: The server of a drive as DriveOfPath gives it: '\\NAS\Music' ->
// 'NAS'; a drive letter mapped to a share -> the server of that share
// (Windows answers this from its own list; the server is not contacted).
// '' = not checked: a local drive, '\\?\' and '\\.\' device paths, WebDAV
// names ('\\server@SSL\...').
function ServerOfDrive(const ADrive: string): string;

// ---> ADDED: Worker thread only. Does AServer answer on one of APorts within
// ATimeoutMs? One connection attempt per address and port, all at once; a
// port that connects or refuses means the machine is there (the connection is
// closed again at once, nothing is sent). saNotChecked when the name cannot
// be looked up or the network cannot be used: then nothing is known (looking
// up a name that does not exist can take a few seconds). AStop (may be nil)
// is asked about every 100 ms; True = stop (saNotChecked).
function ServerAnswers(const AServer: string; const APorts: array of Word;
  ATimeoutMs: Cardinal; AStop: TDriveWaitFunc): TShareAnswer;

// The first path of each drive / network share among APaths, in list order
procedure OnePathPerDrive(APaths, AResult: TStrings);

// ---> ADDED: The drives of ADrives for a message, in list order:
// 'E:, \\NAS\Music' ('' for none)
function DriveListText(ADrives: TStrings): string;

// UI thread. Wakes the drives of APaths (files or folders; one access per
// drive or share) on a worker thread while AOnWait runs every 20 ms. True when
// done, also when a drive could not be reached (the caller's own read finds
// that out, quickly now). ---> ADDED: A network drive whose server does not
// answer at all (ServerAnswers) is not touched and goes into AUnreachable (may
// be nil) as DriveOfPath gives it ('\\NAS\Music', 'Z:'): the caller must not
// read its files either (each read would wait 20-60 s). False when AOnWait
// stopped it (AUnreachable then gets nothing); the worker is then set aside
// (SetThreadAside). AOnWait = nil: just waits.
function WakeDrives(APaths: TStrings; AOnWait: TDriveWaitFunc;
  AUnreachable: TStrings = nil): Boolean;

// UI thread. The drives / shares of APaths that cannot be reached (their root
// folder does not answer: a USB disk switched off, a NAS that is down; ---> ADDED:
// a network drive whose server does not answer at all is found within
// NAS_ANSWER_TIMEOUT_MS), each once in AOffline ('E:', '\\NAS\Music'), checked
// on a worker thread while AOnWait runs as above. False when AOnWait stopped
// it (AOffline is then empty).
function FindOfflineDrives(APaths, AOffline: TStrings; AOnWait: TDriveWaitFunc): Boolean;

// ---> AulumicNS: drives that answered a moment ago. Waking a drive costs a
// worker thread and, for a network drive, a name lookup and a connection to
// its server - a second or more on some networks, at every click on a cover,
// although the NAS had just delivered the last one or was playing. WakeDrives
// leaves out the drives noted here within DRIVE_ANSWER_MEMORY_MS.
// NoteDriveAnswered: any thread; APath = a file or folder on the drive.
procedure NoteDriveAnswered(const APath: string);
function DriveAnsweredRecently(const APath: string): Boolean;
procedure ForgetAnsweredDrives;

// ---> ADDED: Asks Windows to abort the file access AThread is blocked in
// (CancelSynchronousIo). Works for network shares; a local disk that is
// spinning up mostly finishes first. The aborted call simply fails, so only
// for a thread that is being stopped.
// ---> CHANGED: UI thread; returns at once. CancelSynchronousIo waits until
// the aborted call has returned, for a USB disk that is spinning up the whole
// spin-up (on the UI thread Aulumic stopped responding after Cancel). So a
// helper thread does it, again and again until AThread has ended (a thread
// that was between two calls may start a new one). The helper holds its own
// handle of AThread (AThread may be freed first) and is freed like a thread
// set aside. One helper per thread.
procedure CancelThreadFileAccess(AThread: TThread);

// UI thread. A thread that did not end in time (a cancelled wake worker; at
// exit a playback worker blocked by its drive) is set aside here instead of
// being told to free itself: it is terminated, its file access is aborted
// where possible, and it is freed once it has ended (on the next call of
// these functions, at the latest by FinishSetAsideThreads).
procedure SetThreadAside(AThread: TThread);

// True while a thread set aside may still be running, also after
// FinishSetAsideThreads had to leave one: libFLAC / libsoxr stay loaded then
// (it may be inside them)
function SetAsideThreadsRunning: Boolean;

// At exit (uAppLifetime.FreeAppSingletons): waits up to ATimeoutMs for the
// threads set aside, aborting their file access again and again, and frees
// those that ended. One still blocked after that is left to Windows, which
// ends it with the process (it holds nothing else); only the Debug build's
// memory report would list it.
procedure FinishSetAsideThreads(ATimeoutMs: Cardinal);

var
  // Tests only: the access that wakes one path (nil = the normal one: a block
  // of a file, the entries of a folder)
  DriveWakeProc: TDriveWakeProc = nil;
  // ---> ADDED: Tests only: the answer check of one drive (nil = the normal
  // one: ServerOfDrive, then ServerAnswers on the file sharing ports)
  DriveAnswerProc: TDriveAnswerProc = nil;
  // ---> ADDED: Tests only: the abort of CancelThreadFileAccess, called on its
  // helper thread with the helper's handle of the thread (nil = the normal
  // one: CancelSynchronousIo)
  FileAccessCancelProc: TFileAccessCancelProc = nil;
  // ---> AulumicNS: UI thread. What the last WakeDrives that ran to its end
  // spent its time on, per drive (for the log; '' = nothing had to be woken)
  LastWakeReport: string = '';

implementation

uses
  AuAudioTypes, Windows, WinSock2, uAppConsts;

// ---> AUDIT FIX: Per-thread error mode (Windows 7+). Without
// SEM_FAILCRITICALERRORS, touching a removable drive without media (card
// reader, optical drive) can show the system "There is no disk in the drive"
// dialog. Only this thread is affected.
function AL_SetThreadErrorMode(dwNewMode: DWORD; lpOldMode: LPDWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetThreadErrorMode';

const
  AL_SEM_FAILCRITICALERRORS = $0001;

  KEEPALIVE_INTERVAL_MS = 45000;          // well below common sleep timers (minutes)
  KEEPALIVE_BLOCK_SIZE  = 4096;           // one 4 KB sector-aligned block
  KEEPALIVE_OFFSET_STEP = 1024 * 1024;    // 1 MB further each round

{ TDriveKeepAlive }

constructor TDriveKeepAlive.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Priority        := tpLowest;

  FLock      := SyncObjs.TCriticalSection.Create;
  FStopEvent := SyncObjs.TEvent.Create(nil, True, False, '');  // manual reset
  FCurrent   := '';
  FNext      := '';
  FRound     := 0;
  FLostDrive := '';

  Start;
end;

destructor TDriveKeepAlive.Destroy;
begin
  // Normally Shutdown has already been called. A thread that did not stop in
  // time is set aside and freed only after it has ended (Finished is then
  // True), so it never waits here.
  // ---> AUDIT FIX: "not Suspended" as in TThread.Destroy: when the
  // constructor fails before Start, the thread never ran and WaitFor would
  // wait forever.
  if (not Finished) and (not Suspended) then
  begin
    Terminate;
    if Assigned(FStopEvent) then
      FStopEvent.SetEvent;
    WaitFor;
  end;

  FStopEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDriveKeepAlive.SetTargets(const ACurrentFile, ANextFile: string);
begin
  FLock.Enter;
  try
    FCurrent := ACurrentFile;
    FNext    := ANextFile;
    UniqueString(FCurrent);
    UniqueString(FNext);
    // Nothing to keep awake: forget an old "cannot be reached"
    if (FCurrent = '') and (FNext = '') then
      FLostDrive := '';
  finally
    FLock.Leave;
  end;
end;

function TDriveKeepAlive.LostDrive: string;
begin
  FLock.Enter;
  try
    Result := FLostDrive;
    UniqueString(Result);
  finally
    FLock.Leave;
  end;
end;

function TDriveKeepAlive.Shutdown(ATimeoutMs: Cardinal): Boolean;
begin
  Terminate;
  FStopEvent.SetEvent;
  Result := Windows.WaitForSingleObject(Handle, ATimeoutMs) = WAIT_OBJECT_0;
end;

// ---> MODIFIED: Shared by the keep-alive rounds and WakeFile. Opens APath,
// reads one block at the offset for ARound and closes it again: first
// uncached (so the read really reaches the drive or NAS), then once more as a
// normal read when the uncached open or read fails (a file system that refuses
// uncached access, or sectors larger than 4 KB; at a new offset each round a
// normal read still mostly reaches the drive). AOpened: the file could be
// opened at all. ABuffer: page-aligned, KEEPALIVE_BLOCK_SIZE bytes.
function ReadFileBlock(const APath: string; ARound: Cardinal; ABuffer: Pointer;
  out AOpened: Boolean): Boolean;
var
  WidePath: UnicodeString;
  OpenedUncached, OpenedCached: Boolean;

  function TryRead(AFlags: DWORD; out AOpenedNow: Boolean): Boolean;
  var
    H: THandle;
    SizeLo, SizeHi: DWORD;
    FileSize, Offset, Span: Int64;
    OffLo: DWORD;
    OffHi: LONG;
    BytesRead: DWORD;
  begin
    Result := False;
    H := CreateFileW(PWideChar(WidePath), GENERIC_READ,
           FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
           nil, OPEN_EXISTING, AFlags, 0);
    AOpenedNow := H <> INVALID_HANDLE_VALUE;
    if not AOpenedNow then
      Exit;

    try
      SizeHi := 0;
      SizeLo := Windows.GetFileSize(H, @SizeHi);
      if (SizeLo = $FFFFFFFF) and (GetLastError <> NO_ERROR) then
        Exit;
      FileSize := (Int64(SizeHi) shl 32) or SizeLo;

      // A different, block-aligned offset every round (no-buffering reads must
      // be aligned to the sector size; 4 KB covers 512 and 4K sectors)
      Span := FileSize - KEEPALIVE_BLOCK_SIZE;
      if Span > 0 then
        Offset := ((Int64(ARound) * KEEPALIVE_OFFSET_STEP) mod Span) and
                  not Int64(KEEPALIVE_BLOCK_SIZE - 1)
      else
        Offset := 0;

      OffLo := DWORD(Offset and $FFFFFFFF);
      OffHi := LONG(Offset shr 32);
      if (Windows.SetFilePointer(H, LONG(OffLo), @OffHi, FILE_BEGIN) = $FFFFFFFF) and
         (GetLastError <> NO_ERROR) then
        Exit;

      BytesRead := 0;
      Result := Windows.ReadFile(H, ABuffer^, KEEPALIVE_BLOCK_SIZE, BytesRead, nil);
    finally
      CloseHandle(H);
    end;
  end;

begin
  WidePath := UnicodeString(APath);
  Result   := TryRead(FILE_FLAG_NO_BUFFERING, OpenedUncached);
  if not Result then
    Result := TryRead(FILE_ATTRIBUTE_NORMAL, OpenedCached)
  else
    OpenedCached := False;
  AOpened := OpenedUncached or OpenedCached;
end;

function WakeFile(const APath: string): Boolean;
var
  Buffer: Pointer;
  Opened: Boolean;
  OldMode: DWORD;
begin
  Result := False;
  if APath = '' then
    Exit;
  // Page-aligned buffer, as required for uncached reads
  Buffer := VirtualAlloc(nil, KEEPALIVE_BLOCK_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  if Buffer = nil then
    Exit;
  // No "no disk in the drive" dialog for a removable drive without media;
  // the caller's thread gets its own error mode back afterwards
  OldMode := 0;
  AL_SetThreadErrorMode(AL_SEM_FAILCRITICALERRORS, @OldMode);
  try
    // Round 0 = the start of the file, which the engine reads first
    Result := ReadFileBlock(APath, 0, Buffer, Opened);
  finally
    AL_SetThreadErrorMode(OldMode, nil);
    VirtualFree(Buffer, 0, MEM_RELEASE);
  end;
end;

// =============================================================================
// ---> ADDED: Waking drives before the UI thread reads them
// =============================================================================

const
  DRIVE_WAKE_POLL_MS = 20;  // how often the waiting UI thread handles messages

  // ---> ADDED: The ports a file server listens on: Windows file sharing (SMB;
  // 139 = its older form), NFS, WebDAV (http, https). One that answers is enough.
  SHARE_PORTS: array[0..4] of Word = (445, 139, 2049, 80, 443);
  SHARE_MAX_ADDRESSES = 4;    // addresses of one name that are tried (IPv4, IPv6)
  SHARE_STOP_POLL_MS  = 100;  // how often ServerAnswers asks AStop

  AL_ERROR_CONNECTION_UNAVAIL = 1201;  // a remembered mapping, not connected now

type
  TDriveWakeMode = (dwmWake, dwmFindOffline);

  { TDriveWaker: one wake (or reachability check) of a list of paths, one per
    drive. Owned by WakeDrives / FindOfflineDrives; after a Cancel set aside
    (SetThreadAside) until it has ended. It touches only its own fields. }
  TDriveWaker = class(TThread)
  private
    FPaths      : TStringList;
    FMode       : TDriveWakeMode;
    FOffline    : TStringList;  // dwmFindOffline; read only after the thread ended
    FUnreachable: TStringList;  // dwmWake: servers that did not answer; the same
    FReport     : string;       // dwmWake: the times per drive; the same
    function IsStopping: Boolean;
    function DriveAnswer(const ADrive: string): TShareAnswer;
  protected
    procedure Execute; override;
  public
    constructor Create(APaths: TStrings; AMode: TDriveWakeMode);
    destructor Destroy; override;
  end;

  { ---> ADDED: TFileAccessCanceller: aborts the file access of one thread that
    is being stopped (CancelThreadFileAccess), again and again until that
    thread has ended. Its own thread, because CancelSynchronousIo waits until
    the aborted call has returned (for a USB disk that is spinning up: the
    whole spin-up). It holds its own handle of the thread, so the thread's
    object may be freed before it. In SetAsideList, freed once it has ended. }
  TFileAccessCanceller = class(TThread)
  private
    FTarget  : THandle;    // own duplicate of the thread's handle (0 = none)
    FTargetId: TThreadID;  // CancelThreadFileAccess: one helper per thread
  protected
    procedure Execute; override;
  public
    constructor Create(AThread: TThread);
    destructor Destroy; override;
  end;

  // ---> ADDED: ADDRINFOW of GetAddrInfoW (ws2tcpip.h); not in FPC's WinSock2
  PAddrInfoW = ^TAddrInfoW;
  TAddrInfoW = record
    ai_flags    : Integer;
    ai_family   : Integer;
    ai_socktype : Integer;
    ai_protocol : Integer;
    ai_addrlen  : SizeUInt;
    ai_canonname: PWideChar;
    ai_addr     : PSockAddr;
    ai_next     : PAddrInfoW;
  end;

// ---> ADDED: Name lookup (Windows Vista+) and the share of a mapped drive letter
function AL_GetAddrInfoW(pNodeName, pServiceName: PWideChar; pHints: PAddrInfoW;
  var ppResult: PAddrInfoW): Integer; stdcall; external 'ws2_32.dll' name 'GetAddrInfoW';
procedure AL_FreeAddrInfoW(pAddrInfo: PAddrInfoW); stdcall;
  external 'ws2_32.dll' name 'FreeAddrInfoW';
function AL_WNetGetConnectionW(lpLocalName, lpRemoteName: PWideChar;
  var lpnLength: DWORD): DWORD; stdcall; external 'mpr.dll' name 'WNetGetConnectionW';

var
  // Threads set aside (SetThreadAside), freed once they have ended
  // (PruneSetAside, FinishSetAsideThreads). UI thread only.
  SetAsideList     : TList = nil;
  // FinishSetAsideThreads had to leave a thread running
  LeftRunningAtExit: Boolean = False;

// ---> ADDED: Aborts the synchronous I/O a thread is blocked in (Windows Vista+)
function AL_CancelSynchronousIo(hThread: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'CancelSynchronousIo';

// ---> AulumicNS: the drives that answered a moment ago (NoteDriveAnswered)
const
  ANSWERED_SLOTS = 16;

var
  AnsweredLock : TRTLCriticalSection;
  AnsweredDrive: array[0..ANSWERED_SLOTS - 1] of string;
  AnsweredTick : array[0..ANSWERED_SLOTS - 1] of QWord;

procedure NoteDriveAnswered(const APath: string);
var
  Drive: string;
  I, Slot: Integer;
begin
  Drive := UpperCase(DriveOfPath(APath));
  if Drive = '' then
    Exit;
  EnterCriticalSection(AnsweredLock);
  try
    // its own slot, else the one not used for the longest time
    Slot := 0;
    for I := 0 to ANSWERED_SLOTS - 1 do
    begin
      if AnsweredDrive[I] = Drive then
      begin
        Slot := I;
        Break;
      end;
      if AnsweredTick[I] < AnsweredTick[Slot] then
        Slot := I;
    end;
    if AnsweredDrive[Slot] <> Drive then
    begin
      AnsweredDrive[Slot] := Drive;
      UniqueString(AnsweredDrive[Slot]);
    end;
    AnsweredTick[Slot] := GetTickCount64;
  finally
    LeaveCriticalSection(AnsweredLock);
  end;
end;

function DriveAnsweredRecently(const APath: string): Boolean;
var
  Drive: string;
  I: Integer;
begin
  Result := False;
  Drive  := UpperCase(DriveOfPath(APath));
  if Drive = '' then
    Exit;
  EnterCriticalSection(AnsweredLock);
  try
    for I := 0 to ANSWERED_SLOTS - 1 do
      if AnsweredDrive[I] = Drive then
      begin
        Result := (AnsweredTick[I] <> 0) and
                  (GetTickCount64 - AnsweredTick[I] < DRIVE_ANSWER_MEMORY_MS);
        Break;
      end;
  finally
    LeaveCriticalSection(AnsweredLock);
  end;
end;

procedure ForgetAnsweredDrives;
var
  I: Integer;
begin
  EnterCriticalSection(AnsweredLock);
  try
    for I := 0 to ANSWERED_SLOTS - 1 do
    begin
      AnsweredDrive[I] := '';
      AnsweredTick[I]  := 0;
    end;
  finally
    LeaveCriticalSection(AnsweredLock);
  end;
end;

// The normal wake access: the entries of a folder, else a block of a file;
// for a missing file at least its folder
function WakePath(const APath: string): Boolean;
var
  SR : TSearchRec;
  Dir: string;
begin
  if DirectoryExists(LongPath(APath)) then
  begin
    Result := SysUtils.FindFirst(LongPath(IncludeTrailingPathDelimiter(APath) + '*'), faAnyFile, SR) = 0;
    if Result then
      SysUtils.FindClose(SR);
    Exit;
  end;

  Result := WakeFile(APath);
  if not Result then
  begin
    Dir    := ExtractFileDir(APath);
    Result := (Dir <> '') and DirectoryExists(LongPath(Dir));
  end;
end;

// =============================================================================
// ---> ADDED: Does the server of a network drive answer?
// =============================================================================

function ServerOfDrive(const ADrive: string): string;
var
  Share : string;
  Remote: array[0..1023] of WideChar;
  Len   : DWORD;
  Res   : DWORD;
  P     : Integer;
begin
  Result := '';
  Share  := Trim(ADrive);
  if (Length(Share) = 2) and (Share[2] = ':') then
  begin
    // A drive letter: the share it stands for, when it is a mapped network
    // drive (also one that is remembered but not connected now)
    FillChar(Remote, SizeOf(Remote), 0);
    Len := Length(Remote);
    Res := AL_WNetGetConnectionW(PWideChar(UTF8Decode(Share)), @Remote[0], Len);
    if (Res <> NO_ERROR) and (Res <> AL_ERROR_CONNECTION_UNAVAIL) then
      Exit;
    Share := UTF8Encode(UnicodeString(PWideChar(@Remote[0])));
  end;

  // '\\server\share': the server. '\\?\...' and '\\.\...' are device paths.
  if (Length(Share) < 3) or (Share[1] <> '\') or (Share[2] <> '\') or
     (Share[3] in ['?', '.', '\']) then
    Exit;
  Delete(Share, 1, 2);
  P := Pos('\', Share);
  if P > 0 then
    SetLength(Share, P - 1);
  // WebDAV ('\\server@SSL\...', '\\server@8080\...') is reached another way
  if Pos('@', Share) > 0 then
    Exit;
  Result := Share;
end;

function ServerAnswers(const AServer: string; const APorts: array of Word;
  ATimeoutMs: Cardinal; AStop: TDriveWaitFunc): TShareAnswer;
var
  WSA     : TWSAData;
  Hints   : TAddrInfoW;
  Found   : PAddrInfoW;
  Item    : PAddrInfoW;
  Socks   : array of TSocket;
  Count   : Integer;
  Used    : Integer;
  I, P    : Integer;
  S       : TSocket;
  Target  : SOCKADDR_STORAGE;
  NonBlock: u_long;
  Start   : QWord;
  Elapsed : QWord;
  Wait    : Cardinal;
  WriteSet: TFDSet;
  ErrorSet: TFDSet;
  TV      : TTimeVal;
  Err     : Longint;
  ErrLen  : Longint;
  AnyOpen : Boolean;
begin
  Result := saNotChecked;
  if (Trim(AServer) = '') or (Length(APorts) = 0) then
    Exit;
  if WSAStartup($0202, WSA) <> 0 then
    Exit;

  Socks := nil;
  Count := 0;
  try
    // The addresses of the name (a name that does not exist can take a few
    // seconds: the waiting window and Cancel work meanwhile)
    FillChar(Hints, SizeOf(Hints), 0);
    Hints.ai_family   := AF_UNSPEC;
    Hints.ai_socktype := SOCK_STREAM;
    Hints.ai_protocol := IPPROTO_TCP;
    Found := nil;
    if (AL_GetAddrInfoW(PWideChar(UTF8Decode(Trim(AServer))), nil, @Hints, Found) <> 0) or
       (Found = nil) then
      Exit;  // not found: nothing is known (Windows may still find it)

    // From here on only an answer makes it "there"
    Result := saNoAnswer;
    try
      I := SHARE_MAX_ADDRESSES * Length(APorts);
      if I > FD_SETSIZE then
        I := FD_SETSIZE;
      SetLength(Socks, I);

      // One connection attempt per address and port, all at once
      Used := 0;
      Item := Found;
      while Assigned(Item) and (Used < SHARE_MAX_ADDRESSES) do
      begin
        if Assigned(Item^.ai_addr) and (Item^.ai_addrlen <= SizeOf(Target)) and
           ((Item^.ai_family = AF_INET) or (Item^.ai_family = AF_INET6)) then
        begin
          Inc(Used);
          for P := 0 to High(APorts) do
          begin
            if Count >= Length(Socks) then
              Break;
            S := socket(Item^.ai_family, SOCK_STREAM, IPPROTO_TCP);
            if S = INVALID_SOCKET then
              Continue;
            NonBlock := 1;
            ioctlsocket(S, Longint(FIONBIO), NonBlock);
            FillChar(Target, SizeOf(Target), 0);
            Move(Item^.ai_addr^, Target, Item^.ai_addrlen);
            // The port is at the same place in an IPv4 and an IPv6 address
            PWord(PByte(@Target) + 2)^ := htons(APorts[P]);
            if connect(S, PSockAddr(@Target), Longint(Item^.ai_addrlen)) = 0 then
            begin
              closesocket(S);
              Exit(saAnswers);
            end;
            if WSAGetLastError = WSAEWOULDBLOCK then
            begin
              Socks[Count] := S;
              Inc(Count);
            end
            else
              closesocket(S);  // no route to it: no answer
          end;
        end;
        Item := Item^.ai_next;
      end;
    finally
      AL_FreeAddrInfoW(Found);
    end;

    // The first answer counts
    Start := GetTickCount64;
    repeat
      AnyOpen := False;
      FD_ZERO(WriteSet);
      FD_ZERO(ErrorSet);
      for I := 0 to Count - 1 do
        if Socks[I] <> INVALID_SOCKET then
        begin
          FD_SET(Socks[I], WriteSet);
          FD_SET(Socks[I], ErrorSet);
          AnyOpen := True;
        end;
      if not AnyOpen then
        Break;

      Elapsed := GetTickCount64 - Start;
      if Elapsed >= ATimeoutMs then
        Break;
      Wait := ATimeoutMs - Cardinal(Elapsed);
      if Wait > SHARE_STOP_POLL_MS then
        Wait := SHARE_STOP_POLL_MS;
      TV.tv_sec  := Wait div 1000;
      TV.tv_usec := (Wait mod 1000) * 1000;

      if select(0, nil, @WriteSet, @ErrorSet, @TV) = SOCKET_ERROR then
        Break;
      for I := 0 to Count - 1 do
      begin
        if Socks[I] = INVALID_SOCKET then
          Continue;
        // Connected: the machine is there
        if FD_ISSET(Socks[I], WriteSet) then
          Exit(saAnswers);
        if FD_ISSET(Socks[I], ErrorSet) then
        begin
          Err    := 0;
          ErrLen := SizeOf(Err);
          getsockopt(Socks[I], SOL_SOCKET, SO_ERROR, Err, ErrLen);
          // Refused: the machine is there, only this port is closed
          if Err = WSAECONNREFUSED then
            Exit(saAnswers);
          closesocket(Socks[I]);
          Socks[I] := INVALID_SOCKET;
        end;
      end;

      if Assigned(AStop) and AStop() then
        Exit(saNotChecked);
    until False;
  finally
    for I := 0 to Count - 1 do
      if Socks[I] <> INVALID_SOCKET then
        closesocket(Socks[I]);
    WSACleanup;
  end;
end;

{ TDriveWaker }

constructor TDriveWaker.Create(APaths: TStrings; AMode: TDriveWakeMode);
begin
  FPaths       := TStringList.Create;
  FOffline     := TStringList.Create;
  FUnreachable := TStringList.Create;
  FPaths.Assign(APaths);
  FMode        := AMode;
  inherited Create(True);
  FreeOnTerminate := False;
end;

destructor TDriveWaker.Destroy;
begin
  // Only freed once its thread has ended (WakeDrives, FindOfflineDrives,
  // PruneSetAside)
  FPaths.Free;
  FOffline.Free;
  FUnreachable.Free;
  inherited Destroy;
end;

function TDriveWaker.IsStopping: Boolean;
begin
  Result := Terminated;
end;

// saNoAnswer only for a network drive whose server's name was found but which
// did not answer at all
function TDriveWaker.DriveAnswer(const ADrive: string): TShareAnswer;
var
  Server: string;
begin
  if Assigned(DriveAnswerProc) then
    Exit(DriveAnswerProc(ADrive));
  Server := ServerOfDrive(ADrive);
  if Server = '' then
    Exit(saNotChecked);
  Result := ServerAnswers(Server, SHARE_PORTS, NAS_ANSWER_TIMEOUT_MS, @IsStopping);
end;

procedure TDriveWaker.Execute;
var
  I        : Integer;
  Root     : string;
  Reachable: Boolean;
  T0, T1   : QWord;
begin
  // No "There is no disk in the drive" dialog for a card reader without media
  AL_SetThreadErrorMode(AL_SEM_FAILCRITICALERRORS, nil);

  for I := 0 to FPaths.Count - 1 do
  begin
    if Terminated then
      Exit;
    try
      // ---> ADDED: A network drive whose server does not answer at all is
      // not touched (Windows would wait 20-60 s for it); it is reported
      Root := DriveOfPath(FPaths[I]);
      T0   := GetTickCount64;
      if (Root <> '') and (DriveAnswer(Root) = saNoAnswer) then
      begin
        if FMode = dwmWake then
        begin
          FUnreachable.Add(Root);
          FReport := FReport + Format('%s: its server did not answer in %d ms. ',
            [Root, GetTickCount64 - T0]);
        end
        else
          FOffline.Add(Root);
        Continue;
      end;
      if Terminated then
        Exit;

      if FMode = dwmWake then
      begin
        T1 := GetTickCount64;
        if Assigned(DriveWakeProc) then
          Reachable := DriveWakeProc(FPaths[I])
        else
          Reachable := WakePath(FPaths[I]);
        // ---> AulumicNS: it answered: awake for the next moments, and where
        // the time went (the server check of a network drive: looking up its
        // name and connecting to it; then the first read)
        if Reachable then
          NoteDriveAnswered(FPaths[I]);
        FReport := FReport + Format('%s: server check %d ms, first read %d ms. ',
          [Root, T1 - T0, GetTickCount64 - T1]);
      end
      else
      begin
        // The same rule as uOSUtils.IsDriveRootMissing: the drive's root folder
        if Root = '' then
          Continue;
        if Assigned(DriveWakeProc) then
          Reachable := DriveWakeProc(Root)
        else
          Reachable := DirectoryExists(LongPath(IncludeTrailingPathDelimiter(Root)));
        if not Reachable then
          FOffline.Add(Root);
      end;
    except
      // A drive that fails is found out by the caller's own access
    end;
  end;
end;

{ TFileAccessCanceller }

constructor TFileAccessCanceller.Create(AThread: TThread);
begin
  FTarget   := 0;
  FTargetId := AThread.ThreadID;
  if not DuplicateHandle(GetCurrentProcess, AThread.Handle, GetCurrentProcess,
           @FTarget, 0, False, DUPLICATE_SAME_ACCESS) then
    FTarget := 0;  // nothing to abort with: Execute ends at once
  inherited Create(True);
  FreeOnTerminate := False;
end;

destructor TFileAccessCanceller.Destroy;
begin
  // Freed only once its thread has ended (PruneSetAside)
  inherited Destroy;
  if FTarget <> 0 then
    CloseHandle(FTarget);
end;

procedure TFileAccessCanceller.Execute;
begin
  if FTarget = 0 then
    Exit;
  // Until the thread has ended: a thread that was between two calls may have
  // started a new one since
  repeat
    if Assigned(FileAccessCancelProc) then
      FileAccessCancelProc(FTarget)
    else
      AL_CancelSynchronousIo(FTarget);  // False = nothing to abort now: fine
  until Terminated or
        (Windows.WaitForSingleObject(FTarget, DRIVE_WAKE_POLL_MS) <> WAIT_TIMEOUT);
end;

// ---> CHANGED: Starts a TFileAccessCanceller instead of calling
// CancelSynchronousIo here (it could wait for seconds). Not when one is still
// running for this thread (TPlaybackManager calls this, then SetThreadAside).
procedure CancelThreadFileAccess(AThread: TThread);
var
  I: Integer;
  C: TFileAccessCanceller;
begin
  if not Assigned(AThread) then
    Exit;
  if Assigned(SetAsideList) then
    for I := 0 to SetAsideList.Count - 1 do
      if (TObject(SetAsideList[I]) is TFileAccessCanceller) then
      begin
        C := TFileAccessCanceller(SetAsideList[I]);
        if (C.FTargetId = AThread.ThreadID) and (not C.Finished) then
          Exit;
      end;

  try
    C := TFileAccessCanceller.Create(AThread);
  except
    Exit;  // no helper: the thread ends when its drive answers
  end;
  if not Assigned(SetAsideList) then
    SetAsideList := TList.Create;
  SetAsideList.Add(C);
  C.Start;
end;

// Frees the threads set aside that have ended. Their handle is signalled only
// when the thread is really gone, so Free never waits (and never runs other
// threads' Synchronize calls, as TThread.WaitFor would).
procedure PruneSetAside;
var
  I: Integer;
  T: TThread;
begin
  if not Assigned(SetAsideList) then
    Exit;
  for I := SetAsideList.Count - 1 downto 0 do
  begin
    T := TThread(SetAsideList[I]);
    if Windows.WaitForSingleObject(T.Handle, 0) = WAIT_OBJECT_0 then
    begin
      T.Free;
      SetAsideList.Delete(I);
    end;
  end;
end;

procedure SetThreadAside(AThread: TThread);
begin
  if not Assigned(AThread) then
    Exit;
  // Freed here once it has ended, never by itself (a thread that frees itself
  // could do so while the program is already being taken down)
  AThread.FreeOnTerminate := False;
  AThread.Terminate;
  // ---> CHANGED: Returns at once (a helper thread aborts the access). Before
  // AThread is in the list: nothing frees it meanwhile.
  CancelThreadFileAccess(AThread);
  if not Assigned(SetAsideList) then
    SetAsideList := TList.Create;
  SetAsideList.Add(AThread);
end;

function SetAsideThreadsRunning: Boolean;
begin
  PruneSetAside;
  Result := LeftRunningAtExit or (Assigned(SetAsideList) and (SetAsideList.Count > 0));
end;

// Starts AWaker and waits until its thread has ended, calling AOnWait every
// DRIVE_WAKE_POLL_MS. True = ended (the caller frees AWaker). False = AOnWait
// stopped the wait: AWaker is set aside (SetThreadAside).
function RunWaker(AWaker: TDriveWaker; AOnWait: TDriveWaitFunc): Boolean;
begin
  AWaker.Start;
  repeat
    if Windows.WaitForSingleObject(AWaker.Handle, DRIVE_WAKE_POLL_MS) = WAIT_OBJECT_0 then
      Exit(True);
    if Assigned(AOnWait) and AOnWait() then
    begin
      SetThreadAside(AWaker);
      Exit(False);
    end;
  until False;
end;

// A started worker for the first path of each drive of APaths; nil when
// there is nothing to do or the thread could not be created (the caller then
// simply goes on: its own reads wake the drives, as before)
function NewWaker(APaths: TStrings; AMode: TDriveWakeMode): TDriveWaker;
var
  Paths: TStringList;
begin
  Result := nil;
  if (not Assigned(APaths)) or (APaths.Count = 0) then
    Exit;
  Paths := TStringList.Create;
  try
    OnePathPerDrive(APaths, Paths);
    if Paths.Count > 0 then
    try
      Result := TDriveWaker.Create(Paths, AMode);
    except
      Result := nil;
    end;
  finally
    Paths.Free;
  end;
end;

function DriveOfPath(const APath: string): string;
begin
  Result := ExtractFileDrive(Trim(APath));
end;

procedure OnePathPerDrive(APaths, AResult: TStrings);
var
  Seen : TStringList;
  I    : Integer;
  Drive: string;
begin
  if (not Assigned(APaths)) or (not Assigned(AResult)) then
    Exit;
  Seen := TStringList.Create;
  try
    Seen.Sorted        := True;
    Seen.Duplicates    := dupIgnore;
    Seen.CaseSensitive := False;
    Seen.UseLocale     := False;
    for I := 0 to APaths.Count - 1 do
    begin
      Drive := DriveOfPath(APaths[I]);
      if (Drive = '') or (Seen.IndexOf(Drive) >= 0) then
        Continue;
      Seen.Add(Drive);
      AResult.Add(APaths[I]);
    end;
  finally
    Seen.Free;
  end;
end;

function DriveListText(ADrives: TStrings): string;
var
  I: Integer;
begin
  Result := '';
  if not Assigned(ADrives) then
    Exit;
  for I := 0 to ADrives.Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ADrives[I];
  end;
end;

function WakeDrives(APaths: TStrings; AOnWait: TDriveWaitFunc;
  AUnreachable: TStrings): Boolean;
var
  Waker: TDriveWaker;
  Todo : TStringList;
  I    : Integer;
begin
  PruneSetAside;
  Result := True;
  LastWakeReport := '';
  if (not Assigned(APaths)) or (APaths.Count = 0) then
    Exit;

  // ---> AulumicNS: a drive that answered a moment ago is awake - no worker,
  // no server check, no window
  Todo := TStringList.Create;
  try
    OnePathPerDrive(APaths, Todo);
    for I := Todo.Count - 1 downto 0 do
      if DriveAnsweredRecently(Todo[I]) then
        Todo.Delete(I);
    Waker := NewWaker(Todo, dwmWake);
  finally
    Todo.Free;
  end;
  if not Assigned(Waker) then
    Exit;

  Result := RunWaker(Waker, AOnWait);
  if Result then
  begin
    if Assigned(AUnreachable) then
      AUnreachable.AddStrings(Waker.FUnreachable);
    LastWakeReport := Trim(Waker.FReport);
    Waker.Free;
  end;
end;

function FindOfflineDrives(APaths, AOffline: TStrings; AOnWait: TDriveWaitFunc): Boolean;
var
  Waker: TDriveWaker;
begin
  PruneSetAside;
  Result := True;
  LastWakeReport := '';
  if not Assigned(AOffline) then
    Exit;
  Waker := NewWaker(APaths, dwmFindOffline);
  if not Assigned(Waker) then
    Exit;

  Result := RunWaker(Waker, AOnWait);
  if Result then
  begin
    AOffline.AddStrings(Waker.FOffline);
    Waker.Free;
  end;
end;

procedure FinishSetAsideThreads(ATimeoutMs: Cardinal);
var
  Start: QWord;
  I    : Integer;
begin
  if not Assigned(SetAsideList) then
    Exit;

  // ---> CHANGED: Only waits. Each thread set aside has a helper that keeps
  // aborting its file access (SetThreadAside); calling CancelSynchronousIo
  // here could wait for a disk that is spinning up, past ATimeoutMs.
  Start := GetTickCount64;
  PruneSetAside;
  while (SetAsideList.Count > 0) and (GetTickCount64 - Start < ATimeoutMs) do
  begin
    Sleep(DRIVE_WAKE_POLL_MS);
    PruneSetAside;
  end;

  // Helpers still running stop once their current abort has returned
  for I := 0 to SetAsideList.Count - 1 do
    if TObject(SetAsideList[I]) is TFileAccessCanceller then
      TThread(SetAsideList[I]).Terminate;

  // A thread still blocked by its drive is not freed (it may still run); it
  // ends with the process
  LeftRunningAtExit := SetAsideList.Count > 0;
  FreeAndNil(SetAsideList);
end;

// Reads one block of APath for this round. Returns False only when the file
// cannot be opened AND its drive / share is gone (a moved or locked file, or
// a read error, is not a drive problem).
function TDriveKeepAlive.ReadBlock(const APath: string; ABuffer: Pointer): Boolean;
var
  Opened: Boolean;
begin
  Result := True;
  if ReadFileBlock(APath, FRound, ABuffer, Opened) or Opened then
  begin
    NoteDriveAnswered(APath);   // ---> AulumicNS: awake, as far as WakeDrives cares
    Exit;
  end;
  Result := DirectoryExists(IncludeTrailingPathDelimiter(ExtractFileDrive(APath)));
end;

procedure TDriveKeepAlive.Execute;
var
  Buffer: Pointer;
  Cur, Nxt, Lost: string;
begin
  AL_SetThreadErrorMode(AL_SEM_FAILCRITICALERRORS, nil);

  // Page-aligned buffer, as required for uncached reads
  Buffer := VirtualAlloc(nil, KEEPALIVE_BLOCK_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  if Buffer = nil then
    Exit;

  try
    while not Terminated do
    begin
      // Sleeps the interval; wakes at once when the program closes
      if FStopEvent.WaitFor(KEEPALIVE_INTERVAL_MS) <> wrTimeout then
        Break;
      if Terminated then
        Break;

      FLock.Enter;
      try
        Cur := FCurrent;
        Nxt := FNext;
        UniqueString(Cur);
        UniqueString(Nxt);
      finally
        FLock.Leave;
      end;

      // The next track first (needed soonest); the current one only when it
      // is on another drive or share
      Lost := '';
      try
        if (Nxt <> '') and (not ReadBlock(Nxt, Buffer)) then
          Lost := ExtractFileDrive(Nxt);
        // ---> AUDIT FIX: Closing while a read was stuck: stop at once, do
        // nothing more than needed after the program has shut down
        if Terminated then
          Break;
        if (Cur <> '') and
           ((Nxt = '') or (not SameText(ExtractFileDrive(Cur), ExtractFileDrive(Nxt)))) and
           (not ReadBlock(Cur, Buffer)) and (Lost = '') then
          Lost := ExtractFileDrive(Cur);
      except
        // Drive disconnected, file moved, network gone: try again next round
      end;
      if Terminated then
        Break;

      // Only when the targets did not change meanwhile (else the result is
      // about files that no longer matter)
      FLock.Enter;
      try
        if (FCurrent = Cur) and (FNext = Nxt) then
        begin
          FLostDrive := Lost;
          UniqueString(FLostDrive);
        end;
      finally
        FLock.Leave;
      end;

      Inc(FRound);
    end;
  finally
    VirtualFree(Buffer, 0, MEM_RELEASE);
  end;
end;

initialization
  InitCriticalSection(AnsweredLock);

finalization
  DoneCriticalSection(AnsweredLock);

end.
