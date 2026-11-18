unit TestDriveWake;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestDriveWake
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for the drive wake of uDriveKeepAlive (WakeDrives, FindOfflineDrives,
  FinishSetAsideThreads): one access per drive or network share, the waiting
  callback keeps being called while a (simulated) slow drive spins up, Cancel
  stops the wait at once and the worker then ends and is freed, a drive letter
  that does not exist is reported offline. A slow drive is simulated with
  DriveWakeProc (a test function that sleeps); the real wake is used only on
  the temporary folder. heaptrc's "0 unfreed memory blocks" shows that no
  worker is left behind.
  ---> ADDED: A thread blocked in a file access that Windows can abort
  (CancelSynchronousIo), simulated by reading an empty pipe: Cancel and
  SetThreadAside abort it, so it ends at once and is freed.
  ---> ADDED: An abort that takes long (CancelSynchronousIo waits for a USB
  disk that is spinning up; simulated with FileAccessCancelProc): Cancel and
  SetThreadAside still return at once, a helper thread aborts the access.
  ---> ADDED: Whether a network drive's server answers: ServerOfDrive, and
  ServerAnswers against a port on this PC that listens or refuses, the
  reserved address 192.0.2.1 that never answers, a name that does not exist.
  A share that does not answer (simulated with DriveAnswerProc) is reported
  and never touched. All other tests switch the network check off.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uDriveKeepAlive;

type
  TTestDriveWake = class(TTestCase)
  private
    FDir        : string;
    FWaitCalls  : Integer;
    FCancelAfter: Integer;  // the wait callback says "stop" from this call on (0 = never)
    function  OnWait: Boolean;
    function  List(const APaths: array of string): TStringList;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DriveOfPathIsTheLetterOrTheShare;
    procedure OnePathPerDriveKeepsTheFirst;
    procedure DriveListTextForAMessage;
    procedure NothingToWakeStartsNoWorker;
    procedure WakesRealFilesAndFolders;
    procedure SlowDriveKeepsCallingTheWait;
    procedure ADriveThatJustAnsweredIsNotWokenAgain;
    procedure TheReportSaysWhereTheTimeWent;
    procedure CancelStopsAtOnceAndTheWorkerEnds;
    procedure MissingDriveIsOffline;
    procedure CancelledOfflineCheckReportsNothing;
    procedure CancelAbortsABlockedAccess;
    procedure ThreadSetAsideIsAbortedAndFreed;
    procedure CancelDoesNotWaitForTheAbort;
    procedure SetThreadAsideDoesNotWaitForTheAbort;
    procedure ServerOfDriveFindsTheServer;
    procedure ListeningPortAnswers;
    procedure RefusedPortAnswers;
    procedure SilentAddressDoesNotAnswer;
    procedure StopEndsTheCheckAtOnce;
    procedure UnknownNameIsNotChecked;
    procedure ShareThatDoesNotAnswerIsNotTouched;
    procedure ShareThatDoesNotAnswerIsOffline;
  end;

implementation

uses
  Windows, WinSock2, TypInfo, TestHelpers;

var
  // The simulated slow drive (DriveWakeProc runs on the worker thread)
  WakeCalls  : LongInt = 0;
  WakeDelayMs: Integer = 0;
  WakeResult : Boolean = True;

function SlowWake(const APath: string): Boolean;
begin
  InterLockedIncrement(WakeCalls);
  Sleep(WakeDelayMs);
  Result := WakeResult;
end;

var
  // An empty pipe: reading it blocks in a synchronous file access, as a
  // drive that does not answer does, until it is aborted or written to
  PipeRead, PipeWrite: THandle;

function ReadEmptyPipe: Boolean;
var
  B  : Byte;
  Got: DWORD;
begin
  B   := 0;
  Got := 0;
  Result := ReadFile(PipeRead, B, 1, Got, nil);
end;

function BlockedWake(const APath: string): Boolean;
begin
  InterLockedIncrement(WakeCalls);
  Result := ReadEmptyPipe;
end;

type
  // A thread blocked in a file access, like a playback worker on a drive
  TBlockedReader = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TBlockedReader.Execute;
begin
  ReadEmptyPipe;
end;

procedure OpenPipe;
begin
  if not CreatePipe(PipeRead, PipeWrite, nil, 0) then
    raise Exception.Create('CreatePipe failed');
end;

// ---> ADDED: An abort that takes long, as CancelSynchronousIo does for a USB
// disk that is spinning up (it waits until the read has returned). Runs on
// the helper thread of CancelThreadFileAccess.
var
  CancelCalls  : LongInt = 0;
  CancelDelayMs: Integer = 0;

function AL_CancelSynchronousIo(hThread: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'CancelSynchronousIo';

function SlowCancel(AThreadHandle: THandle): Boolean;
begin
  InterLockedIncrement(CancelCalls);
  Sleep(CancelDelayMs);
  Result := AL_CancelSynchronousIo(AThreadHandle);
end;

// Unblocks a reader the test could not abort (no hang), then closes the pipe
procedure ClosePipe;
begin
  CloseHandle(PipeWrite);
  FinishSetAsideThreads(5000);
  CloseHandle(PipeRead);
end;

// ---> ADDED: The network check switched off (the drives in most tests are
// made-up letters; their real check could take time on some PCs)
function NoNetworkDrive(const ADrive: string): TShareAnswer;
begin
  Result := saNotChecked;
end;

// ---> ADDED: '\\DEAD\Music' does not answer, other shares do
function DeadShareAnswer(const ADrive: string): TShareAnswer;
begin
  if SameText(ADrive, '\\DEAD\Music') then
    Result := saNoAnswer
  else if Copy(ADrive, 1, 2) = '\\' then
    Result := saAnswers
  else
    Result := saNotChecked;
end;

function AnswerText(A: TShareAnswer): string;
begin
  Result := GetEnumName(TypeInfo(TShareAnswer), Ord(A));
end;

procedure StartWinsock;
var
  WSA: TWSAData;
begin
  if WSAStartup($0202, WSA) <> 0 then
    raise Exception.Create('WSAStartup failed');
end;

// ---> ADDED: A TCP port on this PC that listens (the caller closes the socket;
// closed at once, nothing listens there and a connection is refused)
function OpenListener(out APort: Word): TSocket;
var
  SA : TSockAddrIn;
  Len: Longint;
begin
  Result := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Result = INVALID_SOCKET then
    raise Exception.Create('socket failed');
  FillChar(SA, SizeOf(SA), 0);
  SA.sin_family      := AF_INET;
  SA.sin_addr.S_addr := inet_addr('127.0.0.1');
  SA.sin_port        := 0;  // any free port
  if (bind(Result, SA, SizeOf(SA)) <> 0) or (listen(Result, 1) <> 0) then
  begin
    closesocket(Result);
    raise Exception.Create('bind / listen failed');
  end;
  Len := SizeOf(SA);
  getsockname(Result, SA, Len);
  APort := ntohs(SA.sin_port);
end;

// A drive letter that does not exist on this machine ('' when all are used)
function FreeDriveLetter: string;
var
  Used: DWORD;
  C: Char;
begin
  Result := '';
  Used := GetLogicalDrives;
  for C := 'Z' downto 'G' do
    if (Used and (DWORD(1) shl (Ord(C) - Ord('A')))) = 0 then
      Exit(C + ':');
end;

{ TTestDriveWake }

procedure TTestDriveWake.SetUp;
begin
  FDir         := CreateTestDir;
  FWaitCalls   := 0;
  FCancelAfter := 0;
  WakeCalls    := 0;
  WakeDelayMs  := 0;
  WakeResult   := True;
  CancelCalls  := 0;
  CancelDelayMs := 0;
  DriveAnswerProc := @NoNetworkDrive;
  ForgetAnsweredDrives;   // every test starts with drives nobody has heard from
end;

procedure TTestDriveWake.TearDown;
begin
  DriveWakeProc   := nil;
  DriveAnswerProc := nil;
  FileAccessCancelProc := nil;
  // A cancelled worker is freed here at the latest
  FinishSetAsideThreads(5000);
  RemoveTestTree(FDir);
end;

function TTestDriveWake.OnWait: Boolean;
begin
  Inc(FWaitCalls);
  Result := (FCancelAfter > 0) and (FWaitCalls >= FCancelAfter);
end;

function TTestDriveWake.List(const APaths: array of string): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 0 to High(APaths) do
    Result.Add(APaths[I]);
end;

procedure TTestDriveWake.DriveOfPathIsTheLetterOrTheShare;
begin
  AssertEquals('Drive letter', 'C:', DriveOfPath('C:\Music\01.flac'));
  AssertEquals('Network share', '\\NAS\Music', DriveOfPath('\\NAS\Music\Album\01.flac'));
  AssertEquals('Relative path: none', '', DriveOfPath('Album\01.flac'));
end;

procedure TTestDriveWake.OnePathPerDriveKeepsTheFirst;
var
  Paths, Res: TStringList;
begin
  Paths := List(['C:\a\1.flac', 'c:\b\2.flac', 'D:\x.flac', '\\NAS\Music\a.flac',
                 '\\nas\music\b.flac', '\\NAS\Other\c.flac', 'relative.flac']);
  Res := TStringList.Create;
  try
    OnePathPerDrive(Paths, Res);
    Res.Delimiter       := ',';
    Res.StrictDelimiter := True;
    AssertEquals('The first of each drive / share, any case',
      'C:\a\1.flac,D:\x.flac,\\NAS\Music\a.flac,\\NAS\Other\c.flac', Res.DelimitedText);
  finally
    Res.Free;
    Paths.Free;
  end;
end;

procedure TTestDriveWake.DriveListTextForAMessage;
var
  Drives: TStringList;
begin
  AssertEquals('No list', '', DriveListText(nil));
  Drives := List([]);
  try
    AssertEquals('Empty list', '', DriveListText(Drives));
    Drives.Add('E:');
    AssertEquals('One drive', 'E:', DriveListText(Drives));
    Drives.Add('\\NAS\Music');
    AssertEquals('In list order', 'E:, \\NAS\Music', DriveListText(Drives));
  finally
    Drives.Free;
  end;
end;

procedure TTestDriveWake.NothingToWakeStartsNoWorker;
var
  Paths: TStringList;
begin
  DriveWakeProc := @SlowWake;
  AssertTrue('No list', WakeDrives(nil, @OnWait));

  Paths := List([]);
  try
    AssertTrue('Empty list', WakeDrives(Paths, @OnWait));
    Paths.Add('relative.flac');
    AssertTrue('No drive in the list', WakeDrives(Paths, @OnWait));
  finally
    Paths.Free;
  end;
  AssertEquals('Nothing woken', 0, WakeCalls);
  AssertEquals('Nothing waited for', 0, FWaitCalls);
end;

procedure TTestDriveWake.WakesRealFilesAndFolders;
var
  Paths: TStringList;
begin
  WriteTestWav(FDir + 'Album\01.wav');
  // The real wake: a block of the file; a folder's entries; a missing file
  // (with the real network check: a local drive is not checked)
  DriveAnswerProc := nil;
  Paths := List([FDir + 'Album\01.wav']);
  try
    AssertTrue('A file', WakeDrives(Paths, @OnWait));
    Paths[0] := FDir + 'Album';
    AssertTrue('A folder', WakeDrives(Paths, @OnWait));
    Paths[0] := FDir + 'Gone\02.wav';
    AssertTrue('A missing file: done anyway', WakeDrives(Paths, @OnWait));
  finally
    Paths.Free;
  end;
end;

procedure TTestDriveWake.SlowDriveKeepsCallingTheWait;
var
  Paths: TStringList;
begin
  DriveWakeProc := @SlowWake;
  WakeDelayMs   := 300;
  // Two drives, two more paths on them: one access per drive
  Paths := List(['C:\Music\a.flac', 'C:\Music\b.flac', 'D:\Music\c.flac', 'D:\d.flac']);
  try
    AssertTrue('Done', WakeDrives(Paths, @OnWait));
  finally
    Paths.Free;
  end;
  AssertEquals('One access per drive', 2, WakeCalls);
  // About 600 ms of waiting, one call per 20 ms
  AssertTrue('The window was kept responding (' + IntToStr(FWaitCalls) + ' calls)',
    FWaitCalls >= 10);
end;

// ---> AulumicNS: the memory of drives that answered a moment ago
procedure TTestDriveWake.ADriveThatJustAnsweredIsNotWokenAgain;
var
  Paths: TStringList;
begin
  DriveWakeProc := @SlowWake;
  Paths := List(['C:\Music\a.flac', 'D:\Music\c.flac']);
  try
    AssertTrue('Done', WakeDrives(Paths, @OnWait));
    AssertEquals('Both woken', 2, WakeCalls);
    AssertTrue('C: answered', DriveAnsweredRecently('c:\other\x.flac'));

    AssertTrue('Again', WakeDrives(Paths, @OnWait));
    AssertEquals('Not woken again', 2, WakeCalls);
    AssertEquals('Nothing to report', '', LastWakeReport);

    Paths.Add('E:\b.flac');
    AssertTrue('With a third drive', WakeDrives(Paths, @OnWait));
    AssertEquals('Only the new one', 3, WakeCalls);

    ForgetAnsweredDrives;
    AssertFalse('Forgotten', DriveAnsweredRecently('C:\a.flac'));
    AssertTrue('After that', WakeDrives(Paths, @OnWait));
    AssertEquals('All three again', 6, WakeCalls);
  finally
    Paths.Free;
  end;

  // noted from elsewhere (the track that plays, the keep-alive read)
  ForgetAnsweredDrives;
  NoteDriveAnswered('\\NAS\Music\Album\01.flac');
  AssertTrue('The same share, any case', DriveAnsweredRecently('\\nas\music\Other\02.flac'));
  AssertFalse('Another share of the server', DriveAnsweredRecently('\\NAS\Video\a.mkv'));
  AssertFalse('A relative path has no drive', DriveAnsweredRecently('a.flac'));
  NoteDriveAnswered('relative.flac');   // nothing happens
  Paths := List(['\\NAS\Music\Album\cover.jpg']);
  try
    WakeCalls := 0;
    AssertTrue('The noted share', WakeDrives(Paths, @OnWait));
    AssertEquals('No access', 0, WakeCalls);
  finally
    Paths.Free;
  end;
end;

procedure TTestDriveWake.TheReportSaysWhereTheTimeWent;
var
  Paths: TStringList;
begin
  DriveWakeProc := @SlowWake;
  WakeDelayMs   := 60;
  Paths := List(['C:\Music\a.flac']);
  try
    AssertTrue('Done', WakeDrives(Paths, @OnWait));
  finally
    Paths.Free;
  end;
  AssertTrue('The drive and its times: ' + LastWakeReport,
    (Pos('C:: server check ', LastWakeReport) = 1) and (Pos('first read ', LastWakeReport) > 0));
end;

procedure TTestDriveWake.CancelStopsAtOnceAndTheWorkerEnds;
var
  Paths: TStringList;
  Start: QWord;
begin
  DriveWakeProc := @SlowWake;
  WakeDelayMs   := 400;
  FCancelAfter  := 3;
  Paths := List(['C:\a.flac', 'D:\b.flac', 'E:\c.flac']);
  try
    Start := GetTickCount64;
    AssertFalse('Cancelled', WakeDrives(Paths, @OnWait));
    AssertTrue('At once, not after the slow drive', GetTickCount64 - Start < 300);
  finally
    Paths.Free;
  end;

  // The worker finishes the access it is in and then stops
  FinishSetAsideThreads(5000);
  AssertEquals('No further drive after Cancel', 1, WakeCalls);
end;

procedure TTestDriveWake.MissingDriveIsOffline;
var
  Paths, Offline: TStringList;
  Letter: string;
begin
  Letter := FreeDriveLetter;
  if Letter = '' then
    Ignore('Every drive letter from G: to Z: is in use');

  DriveAnswerProc := nil;  // the real network check
  Paths   := List([FDir + 'a.flac', Letter + '\Music\b.flac', Letter + '\Music\c.flac']);
  Offline := TStringList.Create;
  try
    AssertTrue('Done', FindOfflineDrives(Paths, Offline, @OnWait));
    AssertEquals('Only the missing drive, once', 1, Offline.Count);
    AssertEquals('The missing drive', Letter, Offline[0]);
  finally
    Offline.Free;
    Paths.Free;
  end;
end;

procedure TTestDriveWake.CancelledOfflineCheckReportsNothing;
var
  Paths, Offline: TStringList;
begin
  DriveWakeProc := @SlowWake;
  WakeDelayMs   := 300;
  WakeResult    := False;  // every drive would be offline
  FCancelAfter  := 2;
  Paths   := List(['C:\a.flac', 'D:\b.flac']);
  Offline := TStringList.Create;
  try
    AssertFalse('Cancelled', FindOfflineDrives(Paths, Offline, @OnWait));
    AssertEquals('No result after Cancel', 0, Offline.Count);
  finally
    Offline.Free;
    Paths.Free;
  end;
end;

procedure TTestDriveWake.CancelAbortsABlockedAccess;
var
  Paths: TStringList;
  Start: QWord;
begin
  OpenPipe;
  try
    DriveWakeProc := @BlockedWake;
    FCancelAfter  := 3;
    Paths := List(['C:\a.flac', 'D:\b.flac']);
    try
      AssertFalse('Cancelled', WakeDrives(Paths, @OnWait));
    finally
      Paths.Free;
    end;

    // Cancel aborted the access: the worker ends at once, without the next drive
    Start := GetTickCount64;
    FinishSetAsideThreads(3000);
    AssertTrue('Ended at once (' + IntToStr(GetTickCount64 - Start) + ' ms)',
      GetTickCount64 - Start < 1500);
    AssertFalse('Nothing left running', SetAsideThreadsRunning);
    AssertEquals('No further drive after Cancel', 1, WakeCalls);
  finally
    ClosePipe;
  end;
end;

procedure TTestDriveWake.ThreadSetAsideIsAbortedAndFreed;
var
  Reader: TBlockedReader;
  Start : QWord;
begin
  OpenPipe;
  try
    Reader := TBlockedReader.Create(False);
    Sleep(50);  // let it block in the read
    AssertTrue('Blocked', WaitForSingleObject(Reader.Handle, 0) <> WAIT_OBJECT_0);

    // As TPlaybackManager does with a worker that did not stop in time
    SetThreadAside(Reader);
    Start := GetTickCount64;
    FinishSetAsideThreads(3000);
    AssertTrue('Aborted and freed at once (' + IntToStr(GetTickCount64 - Start) + ' ms)',
      GetTickCount64 - Start < 1500);
    AssertFalse('Nothing left running', SetAsideThreadsRunning);
  finally
    ClosePipe;
  end;
end;

// ---> ADDED: Cancel while the worker's access cannot be aborted quickly (a USB
// disk spinning up): the wait still ends at once; the helper thread aborts
// the access later, then the worker ends and is freed
procedure TTestDriveWake.CancelDoesNotWaitForTheAbort;
var
  Paths: TStringList;
  Start: QWord;
  Took : QWord;
begin
  OpenPipe;
  try
    DriveWakeProc        := @BlockedWake;
    FileAccessCancelProc := @SlowCancel;
    CancelDelayMs        := 1000;
    FCancelAfter         := 3;
    Paths := List(['C:\a.flac', 'D:\b.flac']);
    try
      Start := GetTickCount64;
      AssertFalse('Cancelled', WakeDrives(Paths, @OnWait));
      Took := GetTickCount64 - Start;
      AssertTrue('Cancel returned at once (' + IntToStr(Took) + ' ms), not after the abort',
        Took < 500);
    finally
      Paths.Free;
    end;

    FinishSetAsideThreads(5000);
    AssertTrue('The access was aborted by the helper', CancelCalls >= 1);
    AssertFalse('Nothing left running', SetAsideThreadsRunning);
    AssertEquals('No further drive after Cancel', 1, WakeCalls);
  finally
    ClosePipe;
  end;
end;

// ---> ADDED: The same for a thread set aside (a playback worker at exit)
procedure TTestDriveWake.SetThreadAsideDoesNotWaitForTheAbort;
var
  Reader: TBlockedReader;
  Start : QWord;
  Took  : QWord;
begin
  OpenPipe;
  try
    FileAccessCancelProc := @SlowCancel;
    CancelDelayMs        := 1000;
    Reader := TBlockedReader.Create(False);
    Sleep(50);  // let it block in the read
    AssertTrue('Blocked', WaitForSingleObject(Reader.Handle, 0) <> WAIT_OBJECT_0);

    Start := GetTickCount64;
    SetThreadAside(Reader);
    Took := GetTickCount64 - Start;
    AssertTrue('Returned at once (' + IntToStr(Took) + ' ms)', Took < 200);

    // Freed once the helper's abort has ended the read (after about 1 s)
    FinishSetAsideThreads(5000);
    AssertTrue('The access was aborted by the helper', CancelCalls >= 1);
    AssertFalse('Aborted and freed', SetAsideThreadsRunning);
  finally
    ClosePipe;
  end;
end;

procedure TTestDriveWake.ServerOfDriveFindsTheServer;
begin
  AssertEquals('Network share', 'NAS', ServerOfDrive('\\NAS\Music'));
  AssertEquals('An address', '192.168.1.10', ServerOfDrive('\\192.168.1.10\Music'));
  AssertEquals('Only a server', 'nas', ServerOfDrive('\\nas'));
  AssertEquals('Device path', '', ServerOfDrive('\\?\C:'));
  AssertEquals('Device path (pipe)', '', ServerOfDrive('\\.\pipe'));
  AssertEquals('WebDAV: not checked', '', ServerOfDrive('\\server@SSL\DavWWWRoot'));
  AssertEquals('Nothing', '', ServerOfDrive(''));
  AssertEquals('The local drive of the test folder', '', ServerOfDrive(DriveOfPath(FDir)));
end;

procedure TTestDriveWake.ListeningPortAnswers;
var
  L    : TSocket;
  Port : Word;
  Start: QWord;
begin
  StartWinsock;
  try
    L := OpenListener(Port);
    try
      Start := GetTickCount64;
      AssertEquals('Answers', AnswerText(saAnswers),
        AnswerText(ServerAnswers('127.0.0.1', [Port], 3000, nil)));
      AssertTrue('At once (' + IntToStr(GetTickCount64 - Start) + ' ms)',
        GetTickCount64 - Start < 1000);
      // One port that answers is enough
      AssertEquals('One of several ports', AnswerText(saAnswers),
        AnswerText(ServerAnswers('127.0.0.1', [Port, 445, 2049], 3000, nil)));
    finally
      closesocket(L);
    end;
  finally
    WSACleanup;
  end;
end;

procedure TTestDriveWake.RefusedPortAnswers;
var
  Port: Word;
begin
  StartWinsock;
  try
    // Nothing listens on the port any more: the connection is refused, so the
    // machine is there (Windows tries a refused connection again for about a
    // second before it reports it)
    closesocket(OpenListener(Port));
    AssertEquals('A refusal is an answer', AnswerText(saAnswers),
      AnswerText(ServerAnswers('127.0.0.1', [Port], 5000, nil)));
  finally
    WSACleanup;
  end;
end;

procedure TTestDriveWake.SilentAddressDoesNotAnswer;
var
  Start, Took: QWord;
begin
  // 192.0.2.1 is reserved for documentation: nothing ever answers there
  Start := GetTickCount64;
  AssertEquals('No answer', AnswerText(saNoAnswer),
    AnswerText(ServerAnswers('192.0.2.1', [445, 139], 300, nil)));
  Took := GetTickCount64 - Start;
  AssertTrue('Within the time limit (' + IntToStr(Took) + ' ms)', Took < 1500);
end;

procedure TTestDriveWake.StopEndsTheCheckAtOnce;
var
  Start : QWord;
  Answer: TShareAnswer;
begin
  FCancelAfter := 1;  // the first question already says "stop"
  Start  := GetTickCount64;
  Answer := ServerAnswers('192.0.2.1', [445], 5000, @OnWait);
  if (Answer = saNoAnswer) and (FWaitCalls = 0) then
    Ignore('This PC has no route to any network (the attempt failed at once)');
  AssertEquals('Stopped: nothing known', AnswerText(saNotChecked), AnswerText(Answer));
  AssertTrue('At once (' + IntToStr(GetTickCount64 - Start) + ' ms)',
    GetTickCount64 - Start < 1000);
end;

procedure TTestDriveWake.UnknownNameIsNotChecked;
begin
  // '.invalid' names never exist: nothing is known, so the drive is not
  // treated as not connected (Windows decides as before)
  AssertEquals('Name not found', AnswerText(saNotChecked),
    AnswerText(ServerAnswers('aulumic-test.invalid', [445], 300, nil)));
  AssertEquals('No name', AnswerText(saNotChecked),
    AnswerText(ServerAnswers('', [445], 300, nil)));
end;

procedure TTestDriveWake.ShareThatDoesNotAnswerIsNotTouched;
var
  Paths, Unreachable: TStringList;
begin
  DriveWakeProc   := @SlowWake;
  DriveAnswerProc := @DeadShareAnswer;
  Paths := List(['\\DEAD\Music\a.flac', '\\dead\music\b.flac', '\\NAS\Music\c.flac', 'C:\d.flac']);
  Unreachable := TStringList.Create;
  try
    AssertTrue('Done', WakeDrives(Paths, @OnWait, Unreachable));
    AssertEquals('Reported once', 1, Unreachable.Count);
    AssertEquals('The share that does not answer', '\\DEAD\Music', Unreachable[0]);
    AssertEquals('Only the other drives were woken', 2, WakeCalls);
  finally
    Unreachable.Free;
    Paths.Free;
  end;
end;

procedure TTestDriveWake.ShareThatDoesNotAnswerIsOffline;
var
  Paths, Offline: TStringList;
begin
  DriveWakeProc   := @SlowWake;  // every root folder answers
  DriveAnswerProc := @DeadShareAnswer;
  Paths   := List(['\\DEAD\Music\a.flac', '\\NAS\Music\c.flac', 'C:\d.flac']);
  Offline := TStringList.Create;
  try
    AssertTrue('Done', FindOfflineDrives(Paths, Offline, @OnWait));
    AssertEquals('Only the share that does not answer', 1, Offline.Count);
    AssertEquals('The share', '\\DEAD\Music', Offline[0]);
    AssertEquals('Its root folder was not touched', 2, WakeCalls);
  finally
    Offline.Free;
    Paths.Free;
  end;
end;

initialization
  RegisterTest(TTestDriveWake);

end.
