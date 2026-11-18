unit TestHangWatch;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   AulumicNS - test program
  Unit Name: TestHangWatch

  ---> AulumicNS: uHangWatch, the watchdog for a frozen main window. A thread
  plays the UI thread: it owns a window and stops taking messages for a while
  (Sleep). A second thread makes a window owned by that window (as an ASIO
  driver may do with the window it gets: their input is tied together). The
  report must be written, name the frozen thread with its stack (the Sleep),
  flag the owned window of the other thread, and get the "answered again"
  line when the thread takes messages again.
  =============================================================================}

interface

uses
  Windows, Classes, SysUtils, fpcunit, testregistry, uHangWatch;

type
  TTestHangWatch = class(TTestCase)
  published
    procedure FrozenWindowIsReported;
    procedure TiedWindowsAreCounted;
    procedure AsioHostWindowComesAndGoes;
  end;

implementation

uses
  uAudioUtils, ALAudioOutput, ALOutputAsio;

const
  TEST_CLASS = 'AulumicNSHangTest';

type
  { a thread with a window and a message loop; Freeze: no messages for
    FreezeMs; AOwner <> 0: the window is owned by that one (another thread's) }
  TWindowThread = class(TThread)
  private
    FName: string;
    FOwner: HWND;
    FReady, FFreeze: THandle;
    FWnd: HWND;
  protected
    procedure Execute; override;
  public
    FreezeMs: Cardinal;
    constructor Create(const AName: string; AOwner: HWND);
    destructor Destroy; override;
    procedure Quit;
    property Wnd: HWND read FWnd;
    property Ready: THandle read FReady;
    property FreezeEvent: THandle read FFreeze;
  end;

constructor TWindowThread.Create(const AName: string; AOwner: HWND);
begin
  FName := AName;
  FOwner := AOwner;
  FReady := CreateEvent(nil, True, False, nil);
  FFreeze := CreateEvent(nil, False, False, nil);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TWindowThread.Destroy;
begin
  CloseHandle(FReady);
  CloseHandle(FFreeze);
  inherited Destroy;
end;

procedure TWindowThread.Quit;
begin
  Terminate;
  if FWnd <> 0 then PostMessageW(FWnd, WM_NULL, 0, 0);
  WaitFor;
end;

procedure TWindowThread.Execute;
var
  WC: TWndClassW;
  M: TMsg;
  R: DWORD;
begin
  NameThisThread(FName);
  FillChar(WC, SizeOf(WC), 0);
  if not GetClassInfoW(HInstance, TEST_CLASS, @WC) then
  begin
    WC.lpfnWndProc := @DefWindowProcW;
    WC.hInstance := HInstance;
    WC.lpszClassName := TEST_CLASS;
    RegisterClassW(@WC);
  end;
  FWnd := CreateWindowExW(WS_EX_TOOLWINDOW, TEST_CLASS, PWideChar(UnicodeString(FName)), WS_POPUP,
    0, 0, 10, 10, FOwner, 0, HInstance, nil);
  SetEvent(FReady);
  while not Terminated do
  begin
    while PeekMessageW(M, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(M);
      DispatchMessageW(M);
    end;
    R := MsgWaitForMultipleObjects(1, FFreeze, False, 50, QS_ALLINPUT);
    if R = WAIT_OBJECT_0 then
      Sleep(FreezeMs);     // frozen: no message is taken
  end;
  DestroyWindow(FWnd);
  FWnd := 0;
end;

function FileHas(const AFile, AText: string): Boolean;
var
  L: TStringList;
begin
  Result := False;
  if not FileExists(AFile) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(AFile);
    except
      Exit;   // the watchdog is writing it
    end;
    Result := Pos(AText, L.Text) > 0;
  finally
    L.Free;
  end;
end;

procedure TTestHangWatch.FrozenWindowIsReported;
var
  UiT, DrvT: TWindowThread;
  Dir, Report: string;
  StartTick: QWord;
  SR: TSearchRec;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'AulumicNSHangTest' + PathDelim;
  ForceDirectories(Dir);
  UiT := TWindowThread.Create('test UI thread', 0);
  DrvT := nil;
  try
    AssertTrue('The window thread is ready', WaitForSingleObject(UiT.Ready, 5000) = WAIT_OBJECT_0);
    DrvT := TWindowThread.Create('test driver thread', UiT.Wnd);
    AssertTrue('The owned window is made', WaitForSingleObject(DrvT.Ready, 5000) = WAIT_OBJECT_0);
    AssertTrue('Both windows exist', IsWindow(UiT.Wnd) and IsWindow(DrvT.Wnd));

    { module+offset only: the line lookup reads the debug info (seconds) }
    HangReportLineInfo := False;
    StartHangWatch(UiT.Wnd, Dir, 300, 100);
    try
      UiT.FreezeMs := 1500;
      SetEvent(UiT.FreezeEvent);
      StartTick := GetTickCount64;
      Report := '';
      while (GetTickCount64 - StartTick < 30000) do
      begin
        Report := LastHangReport;
        if (Report <> '') and FileHas(Report, 'answered again') then Break;
        Sleep(100);
      end;
    finally
      StopHangWatch;
      HangReportLineInfo := True;
    end;

    AssertTrue('A report was written', (Report <> '') and FileExists(Report));
    AssertTrue('In the folder asked for', SameText(ExtractFilePath(Report), Dir));
    AssertTrue('The reason', FileHas(Report, 'did not answer a message within 300 ms'));
    AssertTrue('The frozen thread by its name', FileHas(Report, '"test UI thread"'));
    AssertTrue('Its stack shows the Sleep',
      FileHas(Report, 'NtDelayExecution') or FileHas(Report, 'SleepEx'));
    AssertTrue('The windows by their class', FileHas(Report, '"' + TEST_CLASS + '"'));
    AssertTrue('The owned window of the other thread is flagged',
      FileHas(Report, Format('owner $%.8x (thread %d)  <-- ANOTHER THREAD', [PtrUInt(UiT.Wnd), DWORD(UiT.ThreadID)])));
    AssertTrue('The window answered again', FileHas(Report, 'answered again'));
  finally
    if DrvT <> nil then
    begin
      DrvT.Quit;
      DrvT.Free;
    end;
    UiT.Quit;
    UiT.Free;
    if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
    begin
      repeat
        if (SR.Attr and faDirectory) = 0 then DeleteFile(Dir + SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    RemoveDir(Dir);
  end;
end;

{ ALOutputAsio.CountTiedWindows (the log line after an ASIO start): a window
  owned by another thread's window counts; neither thread is the main one }
procedure TTestHangWatch.TiedWindowsAreCounted;
var
  UiT, DrvT: TWindowThread;
  Main0, Other0, Main1, Other1, Main2, Other2: Integer;
begin
  CountTiedWindows(Main0, Other0);
  UiT := TWindowThread.Create('test UI thread', 0);
  DrvT := nil;
  try
    AssertTrue('The window thread is ready', WaitForSingleObject(UiT.Ready, 5000) = WAIT_OBJECT_0);
    CountTiedWindows(Main1, Other1);
    AssertEquals('A window of its own ties nothing', Other0, Other1);
    DrvT := TWindowThread.Create('test driver thread', UiT.Wnd);
    AssertTrue('The owned window is made', WaitForSingleObject(DrvT.Ready, 5000) = WAIT_OBJECT_0);
    CountTiedWindows(Main2, Other2);
    AssertEquals('The owned window of another thread is counted', Other0 + 1, Other2);
    AssertEquals('Not with the main thread', Main0, Main2);
  finally
    if DrvT <> nil then
    begin
      DrvT.Quit;
      DrvT.Free;
    end;
    UiT.Quit;
    UiT.Free;
  end;
  CountTiedWindows(Main1, Other1);
  AssertEquals('Gone with its thread', Other0, Other1);
end;

{ TAsioOutput's host thread makes its own hidden window for the driver (not
  the main window) and destroys it at Close. A driver that is not installed:
  no device, no window left, no thread left waiting. }
// The windows of the ASIO host's class that belong to this process
function OwnHostWindows: Integer;
var
  W: HWND;
  Pid: DWORD;
begin
  Result := 0;
  W := FindWindowExW(0, 0, 'AulumicNSAsioHost', nil);
  while W <> 0 do
  begin
    Pid := 0;
    GetWindowThreadProcessId(W, @Pid);
    if Pid = GetCurrentProcessId then
      Inc(Result);
    W := FindWindowExW(0, W, 'AulumicNSAsioHost', nil);
  end;
  // (message-only windows are not among the top-level ones)
  W := FindWindowExW(HWND(-3), 0, 'AulumicNSAsioHost', nil);
  while W <> 0 do
  begin
    Pid := 0;
    GetWindowThreadProcessId(W, @Pid);
    if Pid = GetCurrentProcessId then
      Inc(Result);
    W := FindWindowExW(HWND(-3), W, 'AulumicNSAsioHost', nil);
  end;
end;

procedure TTestHangWatch.AsioHostWindowComesAndGoes;
var
  O: TAsioOutput;
  E: HRESULT;
  T: string;
  R: TOutputOpenResult;
  WC: TWndClassW;
begin
  O := TAsioOutput.Create(True);
  try
    R := O.Open('{0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0}', 44100, 2, False, 250, E, T);
    AssertTrue('No such driver: ' + T, R = oorNoDevice);
  finally
    O.Free;
  end;
  FillChar(WC, SizeOf(WC), 0);
  AssertTrue('The host thread registered its window class',
    GetClassInfoW(HInstance, 'AulumicNSAsioHost', @WC));
  // (of this process: AulumicNS itself may be running and have one)
  AssertEquals('Its window is gone after Close', 0, OwnHostWindows);
end;

initialization
  RegisterTest(TTestHangWatch);
end.
