unit uHangWatch;

{$mode ObjFPC}{$H+}
{$PACKRECORDS C}

{ ==============================================================================
  AulumicNS - uHangWatch
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  A watchdog for a frozen main window. A thread looks at the
  window every second: it is frozen when Windows calls it hung (IsHungAppWindow:
  no message taken for 5 s although it does not wait for input - the white
  "Not responding" window) or when it does not answer a sent message within
  the hang time. Then it writes HangReport_<time>.txt next to the exe (or into
  the data folder), once per freeze:
  - the windows of the program (class, visible, owner / parent and their
    threads). A window that hangs on a window of ANOTHER thread ties the input
    of both threads together: a thread of such a pair that does not handle
    messages freezes the other one at the next click (focus changes become
    synchronous);
  - per thread with windows its GUI state (GetGUIThreadInfo: active, focus,
    capture window, menu / move mode). Threads that share their input show
    the same active and focus window;
  - every thread's name (SetThreadDescription) and call stack (module+offset,
    the nearest export, for the exe the line when debug info is there; else
    the offset is looked up in the .dbg of the same build);
  - the last lines of the log (HangReportExtra).
  When the window answers again, the report gets a last line with the time.
  The stacks are walked while the thread is suspended, without allocating
  memory and without a call that may wait for a lock (a suspended thread may
  hold the heap lock); the text is made after ResumeThread.
==============================================================================}

interface

uses
  Windows, Classes, SysUtils;

type
  THangReportExtra = function: string;

var
  { more text for the report (the main window: the last log lines). Runs on
    the watchdog thread while the UI thread hangs: it must not wait for the
    UI thread. }
  HangReportExtra: THangReportExtra = nil;
  { the exe's frames with routine and line (from the debug info; the first
    lookup reads it, a few seconds in a debug build). Off: module+offset only
    (the tests). }
  HangReportLineInfo: Boolean = True;

{ AFolder '' = next to the exe (else the data folder); AHangMs: the time a
  sent message may take; APollMs: how often the window is looked at }
procedure StartHangWatch(AWnd: HWND; const AFolder: string = ''; AHangMs: Cardinal = 5000;
  APollMs: Cardinal = 1000);
{ before the window closes (its shutdown may take a while): waits for the
  watchdog and answers its messages meanwhile }
procedure StopHangWatch;
{ the file of the last report ('' = none yet) }
function LastHangReport: string;
{ the report's text now, for the window AWnd (tests; the watchdog writes it) }
function BuildHangReport(AWnd: HWND; const AReason: string): string;

implementation

uses
  AuSettings, uAudioUtils;

const
  MAX_FRAMES = 48;
  MAX_THREADS = 256;
  THREAD_SUSPEND_RESUME_ = $0002;
  THREAD_GET_CONTEXT_ = $0008;
  THREAD_QUERY_INFORMATION_ = $0040;
  THREAD_QUERY_LIMITED_INFORMATION_ = $0800;
  TH32CS_SNAPTHREAD_ = $00000004;
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT_ = 2;
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS_ = 4;
  CONTEXT_FULL_ = $0010000B;     // CONTEXT_AMD64 or CONTROL or INTEGER or FLOATING_POINT
  HWND_MESSAGE_ = HWND(-3);
  GUI_CARETBLINKING_ = $01;
  GUI_INMOVESIZE_ = $02;
  GUI_INMENUMODE_ = $04;
  GUI_SYSTEMMENUMODE_ = $08;
  GUI_POPUPMENUMODE_ = $10;

type
  TThreadEntry32_ = record
    dwSize, cntUsage, th32ThreadID, th32OwnerProcessID: DWORD;
    tpBasePri, tpDeltaPri: LongInt;
    dwFlags: DWORD;
  end;

  TGuiThreadInfo_ = record
    cbSize, flags: DWORD;
    hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret: HWND;
    rcCaret: TRect;
  end;

  TThreadBasicInfo_ = record
    ExitStatus: LongInt;
    TebBaseAddress: Pointer;
    UniqueProcess, UniqueThread: THandle;
    AffinityMask: PtrUInt;
    Priority, BasePriority: LongInt;
  end;

  TStackShot = record
    Tid: DWORD;
    Ok: Boolean;
    Count: Integer;
    Pc: array[0..MAX_FRAMES - 1] of QWord;
  end;

  TGetThreadDescription = function(hThread: THandle; out ppszThreadDescription: PWideChar): HRESULT; stdcall;

function CreateToolhelp32Snapshot_(dwFlags, th32ProcessID: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateToolhelp32Snapshot';
function Thread32First_(hSnapshot: THandle; var lpte: TThreadEntry32_): BOOL; stdcall;
  external 'kernel32.dll' name 'Thread32First';
function Thread32Next_(hSnapshot: THandle; var lpte: TThreadEntry32_): BOOL; stdcall;
  external 'kernel32.dll' name 'Thread32Next';
function OpenThread_(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwThreadId: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'OpenThread';
function RtlLookupFunctionEntry_(ControlPc: QWord; ImageBase: PQWord; HistoryTable: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'RtlLookupFunctionEntry';
function RtlVirtualUnwind_(HandlerType: DWORD; ImageBase, ControlPc: QWord; FunctionEntry: Pointer;
  ContextRecord: Pointer; HandlerData: PPointer; EstablisherFrame: PQWord; ContextPointers: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'RtlVirtualUnwind';
function GetModuleHandleExW_(dwFlags: DWORD; lpModuleName: Pointer; out phModule: HMODULE): BOOL; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleExW';
function NtQueryInformationThread_(ThreadHandle: THandle; ThreadInformationClass: LongInt;
  ThreadInformation: Pointer; ThreadInformationLength: ULONG; ReturnLength: PULONG): LongInt; stdcall;
  external 'ntdll.dll' name 'NtQueryInformationThread';
function GetGUIThreadInfo_(idThread: DWORD; var pgui: TGuiThreadInfo_): BOOL; stdcall;
  external 'user32.dll' name 'GetGUIThreadInfo';
function InternalGetWindowText_(hWnd: HWND; pString: PWideChar; cchMaxCount: Integer): Integer; stdcall;
  external 'user32.dll' name 'InternalGetWindowText';
function IsHungAppWindow_(hWnd: HWND): BOOL; stdcall;
  external 'user32.dll' name 'IsHungAppWindow';
function EnumWindows_(lpEnumFunc: Pointer; lParam: LPARAM): BOOL; stdcall;
  external 'user32.dll' name 'EnumWindows';
function EnumChildWindows_(hWndParent: HWND; lpEnumFunc: Pointer; lParam: LPARAM): BOOL; stdcall;
  external 'user32.dll' name 'EnumChildWindows';

type
  { THangWatch }

  THangWatch = class(TThread)
  private
    FWnd: HWND;
    FFolder: string;
    FHangMs, FPollMs: Cardinal;
    FStop: THandle;
    FFile: string;
    procedure WriteReport(const AReason: string);
    procedure AppendLine(const ALine: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AWnd: HWND; const AFolder: string; AHangMs, APollMs: Cardinal);
    destructor Destroy; override;
  end;

var
  GWatch: THangWatch = nil;
  GLastReport: string = '';

{ ---- stacks ---- }

{ one thread's stack: the thread is suspended; no memory is allocated here }
procedure WalkStack(Ctx: PContext; StackLow, StackHigh: QWord; var Shot: TStackShot);
var
  N: Integer;
  Pc, Base, Est, Ret: QWord;
  Fn, HData: Pointer;
  Done: PtrUInt;
begin
  Shot.Count := 0;
  for N := 0 to MAX_FRAMES - 1 do
  begin
    Pc := Ctx^.Rip;
    if Pc = 0 then Break;
    Shot.Pc[N] := Pc;
    Shot.Count := N + 1;
    if (Ctx^.Rsp < StackLow) or (Ctx^.Rsp >= StackHigh) then Break;
    Base := 0;
    Fn := RtlLookupFunctionEntry_(Pc, @Base, nil);
    if Fn <> nil then
    begin
      HData := nil;
      Est := 0;
      RtlVirtualUnwind_(0, Base, Pc, Fn, Ctx, @HData, @Est, nil);
    end
    else
    begin
      { a leaf function: the return address is on top of the stack }
      Ret := 0;
      Done := 0;
      if not ReadProcessMemory(GetCurrentProcess, Pointer(PtrUInt(Ctx^.Rsp)), @Ret, 8, Done) then Break;
      Ctx^.Rip := Ret;
      Ctx^.Rsp := Ctx^.Rsp + 8;
    end;
  end;
end;

procedure TakeShot(var Shot: TStackShot; Ctx: PContext);
var
  H: THandle;
  TBI: TThreadBasicInfo_;
  Teb: PByte;
  High_, Low_: QWord;
begin
  Shot.Ok := False;
  Shot.Count := 0;
  H := OpenThread_(THREAD_SUSPEND_RESUME_ or THREAD_GET_CONTEXT_ or THREAD_QUERY_INFORMATION_, False, Shot.Tid);
  if H = 0 then Exit;
  try
    FillChar(TBI, SizeOf(TBI), 0);
    if NtQueryInformationThread_(H, 0, @TBI, SizeOf(TBI), nil) < 0 then Exit;
    Teb := TBI.TebBaseAddress;
    if Teb = nil then Exit;
    if SuspendThread(H) = DWORD(-1) then Exit;
    try
      FillChar(Ctx^, SizeOf(TContext), 0);
      Ctx^.ContextFlags := CONTEXT_FULL_;
      if GetThreadContext(H, Ctx^) then
      begin
        { NT_TIB: StackBase at +8, StackLimit at +16 }
        High_ := PQWord(Teb + 8)^;
        Low_ := PQWord(Teb + 16)^;
        WalkStack(Ctx, Low_, High_, Shot);
        Shot.Ok := True;
      end;
    finally
      ResumeThread(H);
    end;
  finally
    CloseHandle(H);
  end;
end;

{ the nearest exported name at or below Rva (Windows' DLLs: win32u, user32,
  ntdll export the calls a thread waits in) }
function NearestExport(Base, Rva: QWord; out AName: string; out AOff: QWord): Boolean;
var
  P: PByte;
  NtOff: LongInt;
  DirRva, DirSize, NNames, F, Best: DWORD;
  Funcs, Names: PDWORD;
  Ords: PWord;
  I: Integer;
  BestName: PAnsiChar;
begin
  Result := False;
  AName := '';
  AOff := 0;
  P := PByte(PtrUInt(Base));
  if PWord(P)^ <> $5A4D then Exit;                       // MZ
  NtOff := PLongInt(P + $3C)^;
  if PDWORD(P + NtOff)^ <> $00004550 then Exit;          // PE#0#0
  if PWord(P + NtOff + 24)^ <> $020B then Exit;          // PE32+
  DirRva := PDWORD(P + NtOff + 24 + 112)^;
  DirSize := PDWORD(P + NtOff + 24 + 116)^;
  if (DirRva = 0) or (DirSize = 0) then Exit;
  NNames := PDWORD(P + DirRva + 24)^;
  if NNames = 0 then Exit;
  Funcs := PDWORD(P + PDWORD(P + DirRva + 28)^);
  Names := PDWORD(P + PDWORD(P + DirRva + 32)^);
  Ords := PWord(P + PDWORD(P + DirRva + 36)^);
  Best := 0;
  BestName := nil;
  for I := 0 to Integer(NNames) - 1 do
  begin
    F := Funcs[Ords[I]];
    if (F >= DirRva) and (F < DirRva + DirSize) then Continue;   // a forwarder
    if (F <= Rva) and (F > Best) then
    begin
      Best := F;
      BestName := PAnsiChar(P + Names[I]);
    end;
  end;
  if BestName = nil then Exit;
  AName := string(BestName);
  AOff := Rva - Best;
  Result := True;
end;

function FrameText(Pc: QWord): string;
var
  M: HMODULE;
  Buf: array[0..MAX_PATH] of WideChar;
  Rva, Off: QWord;
  Name, Exp, Line: string;
  P: Integer;
begin
  M := 0;
  if not GetModuleHandleExW_(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS_ or
     GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT_, Pointer(PtrUInt(Pc)), M) or (M = 0) then
    Exit(Format('$%.16x', [Pc]));
  FillChar(Buf, SizeOf(Buf), 0);
  GetModuleFileNameW(M, @Buf[0], MAX_PATH);
  Name := ExtractFileName(UTF8Encode(UnicodeString(PWideChar(@Buf[0]))));
  Rva := Pc - QWord(M);
  Result := Format('%s+$%x', [Name, Rva]);
  if M = GetModuleHandle(nil) then
  begin
    if not HangReportLineInfo then Exit;
    { the exe: the routine and line when the build has debug info }
    Line := Trim(BackTraceStrFunc(Pointer(PtrUInt(Pc))));
    if (Line <> '') and (Line[1] = '$') then
    begin
      P := Pos(' ', Line);
      if P > 0 then Line := Trim(Copy(Line, P + 1, MaxInt)) else Line := '';
    end;
    if Line <> '' then Result := Result + '  ' + Line;
  end
  else if NearestExport(QWord(M), Rva, Exp, Off) then
    Result := Result + Format('  (%s+$%x)', [Exp, Off]);
end;

function ThreadName(Tid: DWORD): string;
var
  H: THandle;
  P: TGetThreadDescription;
  W: PWideChar;
begin
  Result := '';
  P := TGetThreadDescription(GetProcAddress(GetModuleHandle('kernel32.dll'), 'GetThreadDescription'));
  if not Assigned(P) then Exit;
  H := OpenThread_(THREAD_QUERY_LIMITED_INFORMATION_, False, Tid);
  if H = 0 then Exit;
  try
    W := nil;
    if (P(H, W) >= 0) and (W <> nil) then
    begin
      Result := UTF8Encode(UnicodeString(W));
      LocalFree(HLOCAL(W));
    end;
  finally
    CloseHandle(H);
  end;
end;

{ ---- windows ---- }

function Pick(B: Boolean; const T, F: string): string;
begin
  if B then Result := T else Result := F;
end;

type
  TWinCollect = record
    Pid: DWORD;
    List: TList;
  end;
  PWinCollect = ^TWinCollect;

function CollectChild(W: HWND; L: LPARAM): LongBool; stdcall;
begin
  PWinCollect(L)^.List.Add(Pointer(W));
  Result := True;
end;

function CollectTop(W: HWND; L: LPARAM): LongBool; stdcall;
var
  Pid: DWORD;
begin
  Pid := 0;
  GetWindowThreadProcessId(W, @Pid);
  if Pid = PWinCollect(L)^.Pid then
  begin
    PWinCollect(L)^.List.Add(Pointer(W));
    EnumChildWindows_(W, @CollectChild, L);
  end;
  Result := True;
end;

function WinClass(W: HWND): string;
var
  Buf: array[0..255] of WideChar;
  N: Integer;
begin
  N := GetClassNameW(W, @Buf[0], 256);
  if N <= 0 then Exit('');
  Result := UTF8Encode(Copy(UnicodeString(PWideChar(@Buf[0])), 1, N));
end;

{ the title without a message to the window (its thread may hang) }
function WinTitle(W: HWND): string;
var
  Buf: array[0..80] of WideChar;
  N: Integer;
begin
  N := InternalGetWindowText_(W, @Buf[0], 80);
  if N <= 0 then Exit('');
  Result := UTF8Encode(Copy(UnicodeString(PWideChar(@Buf[0])), 1, N));
end;

function WinTid(W: HWND): DWORD;
begin
  Result := GetWindowThreadProcessId(W, nil);
end;

function OurWindow(W: HWND): Boolean;
var
  Pid: DWORD;
begin
  Pid := 0;
  GetWindowThreadProcessId(W, @Pid);
  Result := (W <> 0) and (Pid = GetCurrentProcessId);
end;

{ the window list: top-level and message-only windows with their threads;
  child windows only when they are of another thread than their parent
  (the main window has hundreds of its own) }
procedure DescribeWindows(L: TStrings; ThreadsWithWindows: TList);
var
  C: TWinCollect;
  W, Owner, Parent: HWND;
  I, SameChildren: Integer;
  T: DWORD;
  S: string;
  IsChild, Tied: Boolean;
begin
  C.Pid := GetCurrentProcessId;
  C.List := TList.Create;
  try
    EnumWindows_(@CollectTop, LPARAM(@C));
    W := FindWindowExW(HWND_MESSAGE_, 0, nil, nil);
    while W <> 0 do
    begin
      CollectTop(W, LPARAM(@C));
      W := FindWindowExW(HWND_MESSAGE_, W, nil, nil);
    end;
    SameChildren := 0;
    for I := 0 to C.List.Count - 1 do
    begin
      W := HWND(C.List[I]);
      T := WinTid(W);
      if ThreadsWithWindows.IndexOf(Pointer(PtrUInt(T))) < 0 then
        ThreadsWithWindows.Add(Pointer(PtrUInt(T)));
      IsChild := (GetWindowLongPtrW(W, GWL_STYLE) and WS_CHILD) <> 0;
      Owner := GetWindow(W, GW_OWNER);
      Parent := 0;
      if IsChild then Parent := GetAncestor(W, GA_PARENT);
      if IsChild and OurWindow(Parent) and (WinTid(Parent) = T) then
      begin
        Inc(SameChildren);
        Continue;
      end;
      S := Format('  $%.8x  thread %d  "%s"  %s', [PtrUInt(W), T, WinClass(W),
        Pick(IsWindowVisible(W), 'visible', 'hidden')]);
      if WinTitle(W) <> '' then S := S + '  "' + WinTitle(W) + '"';
      Tied := False;
      if OurWindow(Owner) then
      begin
        S := S + Format('  owner $%.8x (thread %d)', [PtrUInt(Owner), WinTid(Owner)]);
        Tied := WinTid(Owner) <> T;
      end;
      if IsChild and OurWindow(Parent) then
      begin
        S := S + Format('  child of $%.8x (thread %d)', [PtrUInt(Parent), WinTid(Parent)]);
        Tied := Tied or (WinTid(Parent) <> T);
      end;
      if Tied then S := S + '  <-- ANOTHER THREAD: the input of both threads is tied together';
      L.Add(S);
    end;
    if SameChildren > 0 then
      L.Add(Format('  (and %d child windows in the thread of their parent)', [SameChildren]));
  finally
    C.List.Free;
  end;
end;

procedure DescribeGuiState(L: TStrings; ThreadsWithWindows: TList);
var
  I: Integer;
  T: DWORD;
  G: TGuiThreadInfo_;
  S: string;
begin
  for I := 0 to ThreadsWithWindows.Count - 1 do
  begin
    T := DWORD(PtrUInt(ThreadsWithWindows[I]));
    FillChar(G, SizeOf(G), 0);
    G.cbSize := SizeOf(G);
    if not GetGUIThreadInfo_(T, G) then
    begin
      L.Add(Format('  thread %d: (no GUI state)', [T]));
      Continue;
    end;
    S := Format('  thread %d: active $%.8x, focus $%.8x, capture $%.8x', [T, PtrUInt(G.hwndActive),
      PtrUInt(G.hwndFocus), PtrUInt(G.hwndCapture)]);
    if G.hwndMenuOwner <> 0 then S := S + Format(', menu owner $%.8x', [PtrUInt(G.hwndMenuOwner)]);
    if G.hwndMoveSize <> 0 then S := S + Format(', move / size $%.8x', [PtrUInt(G.hwndMoveSize)]);
    if (G.flags and GUI_INMENUMODE_) <> 0 then S := S + ', in menu mode';
    if (G.flags and GUI_POPUPMENUMODE_) <> 0 then S := S + ', popup menu';
    if (G.flags and GUI_SYSTEMMENUMODE_) <> 0 then S := S + ', system menu';
    if (G.flags and GUI_INMOVESIZE_) <> 0 then S := S + ', moving / sizing';
    if (G.flags and GUI_CARETBLINKING_) <> 0 then S := S + ', caret';
    L.Add(S);
  end;
end;

{ ---- the report ---- }

function BuildHangReport(AWnd: HWND; const AReason: string): string;
var
  L: TStringList;
  WinThreads: TList;
  Shots: array of TStackShot;
  Snap: THandle;
  TE: TThreadEntry32_;
  N, I, J: Integer;
  CtxMem: Pointer;
  Ctx: PContext;
  Me: DWORD;
  S, Extra: string;
begin
  L := TStringList.Create;
  WinThreads := TList.Create;
  try
    L.Add('Aulumic hang report');
    L.Add('Time: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    L.Add(AReason);
    L.Add(Format('Main window $%.8x (thread %d), IsHungAppWindow = %d; main thread %d',
      [PtrUInt(AWnd), WinTid(AWnd), Ord(IsHungAppWindow_(AWnd)), DWORD(MainThreadID)]));
    L.Add(Format('Program: %s, loaded at $%x; Windows %d.%d.%d',
      [ExtractFileName(ParamStr(0)), PtrUInt(GetModuleHandle(nil)), Win32MajorVersion,
       Win32MinorVersion, Win32BuildNumber]));
    L.Add('');

    { the threads first: their stacks are taken as close to the freeze as
      possible (all memory before the first SuspendThread) }
    Me := GetCurrentThreadId;
    SetLength(Shots, MAX_THREADS);
    N := 0;
    Snap := CreateToolhelp32Snapshot_(TH32CS_SNAPTHREAD_, 0);
    if Snap <> INVALID_HANDLE_VALUE then
    try
      FillChar(TE, SizeOf(TE), 0);
      TE.dwSize := SizeOf(TE);
      if Thread32First_(Snap, TE) then
        repeat
          if (TE.th32OwnerProcessID = GetCurrentProcessId) and (TE.th32ThreadID <> Me) and (N < MAX_THREADS) then
          begin
            Shots[N].Tid := TE.th32ThreadID;
            Inc(N);
          end;
          TE.dwSize := SizeOf(TE);
        until not Thread32Next_(Snap, TE);
    finally
      CloseHandle(Snap);
    end;
    GetMem(CtxMem, SizeOf(TContext) + 16);
    try
      Ctx := PContext((PtrUInt(CtxMem) + 15) and not PtrUInt(15));
      for I := 0 to N - 1 do
        TakeShot(Shots[I], Ctx);
    finally
      FreeMem(CtxMem);
    end;

    L.Add('Windows of the program (top-level and message-only; child windows only');
    L.Add('when they are of another thread than their parent):');
    DescribeWindows(L, WinThreads);
    if WinThreads.IndexOf(Pointer(PtrUInt(DWORD(MainThreadID)))) < 0 then
      WinThreads.Insert(0, Pointer(PtrUInt(DWORD(MainThreadID))));
    L.Add('');
    L.Add('GUI state per thread with windows (threads whose input is tied together');
    L.Add('show the same active / focus window):');
    DescribeGuiState(L, WinThreads);
    L.Add('');

    L.Add(Format('Threads (%d, without this watchdog):', [N]));
    for I := 0 to N - 1 do
    begin
      S := Format('thread %d', [Shots[I].Tid]);
      Extra := ThreadName(Shots[I].Tid);
      if Extra <> '' then S := S + '  "' + Extra + '"';
      if Shots[I].Tid = DWORD(MainThreadID) then S := S + '  [main thread: the window]';
      if WinThreads.IndexOf(Pointer(PtrUInt(Shots[I].Tid))) >= 0 then S := S + '  [has windows]';
      L.Add(S);
      if not Shots[I].Ok then
        L.Add('    (no stack)')
      else
        for J := 0 to Shots[I].Count - 1 do
          L.Add('    ' + FrameText(Shots[I].Pc[J]));
    end;

    if Assigned(HangReportExtra) then
    begin
      try
        Extra := HangReportExtra();
      except
        Extra := '';
      end;
      if Extra <> '' then
      begin
        L.Add('');
        L.Add('The last lines of the log:');
        L.Add(Extra);
      end;
    end;
    Result := L.Text;
  finally
    WinThreads.Free;
    L.Free;
  end;
end;

{ ---- THangWatch ---- }

constructor THangWatch.Create(AWnd: HWND; const AFolder: string; AHangMs, APollMs: Cardinal);
begin
  FWnd := AWnd;
  FFolder := AFolder;
  FHangMs := AHangMs;
  FPollMs := APollMs;
  FStop := CreateEvent(nil, True, False, nil);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor THangWatch.Destroy;
begin
  CloseHandle(FStop);
  inherited Destroy;
end;

procedure THangWatch.WriteReport(const AReason: string);
var
  Text, Name: string;
  Dirs: array[0..1] of string;
  I: Integer;
  F: TFileStream;
begin
  try
    Text := BuildHangReport(FWnd, AReason);
  except
    on E: Exception do Text := 'Aulumic hang report' + LineEnding + AReason + LineEnding +
      'The report could not be made: ' + E.Message + LineEnding;
  end;
  Name := 'HangReport_' + FormatDateTime('yyyy-mm-dd_hhnnss', Now) + '.txt';
  if FFolder <> '' then
  begin
    Dirs[0] := IncludeTrailingPathDelimiter(FFolder);
    Dirs[1] := '';
  end
  else
  begin
    Dirs[0] := ExtractFilePath(ParamStr(0));
    Dirs[1] := AppDataDir;
  end;
  for I := 0 to 1 do
  begin
    if Dirs[I] = '' then Continue;
    try
      F := TFileStream.Create(Dirs[I] + Name, fmCreate);
      try
        if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
      finally
        F.Free;
      end;
      FFile := Dirs[I] + Name;
      GLastReport := FFile;
      Exit;
    except
      // the next folder
    end;
  end;
end;

{ Tried for up to 3 s. When another program has the fresh report open at that
  moment without sharing it for writing (a virus scanner, the search indexer,
  an editor - or a test that reads it every 100 ms), the open fails; with one
  try only the "answered again" line would be lost for good. }
procedure THangWatch.AppendLine(const ALine: string);
const
  TRIES   = 30;
  WAIT_MS = 100;
var
  F: TFileStream;
  S: string;
  I: Integer;
begin
  if FFile = '' then Exit;
  S := ALine + LineEnding;
  for I := 1 to TRIES do
  begin
    try
      F := TFileStream.Create(FFile, fmOpenReadWrite or fmShareDenyNone);
      try
        F.Seek(0, soEnd);
        F.WriteBuffer(S[1], Length(S));
      finally
        F.Free;
      end;
      Exit;
    except
      // in use: once more, unless the watchdog is being stopped
    end;
    if WaitForSingleObject(FStop, WAIT_MS) <> WAIT_TIMEOUT then Exit;
  end;
end;

procedure THangWatch.Execute;
var
  Res: DWORD_PTR;
  Answered, Hung: Boolean;
  HungSince: QWord;
  Reason: string;
begin
  NameThisThread('hang watch');
  Hung := False;
  HungSince := 0;
  while WaitForSingleObject(FStop, FPollMs) = WAIT_TIMEOUT do
  begin
    if not IsWindow(FWnd) then Continue;
    Reason := '';
    if IsHungAppWindow_(FWnd) then
      Reason := 'Windows calls the main window hung (no message taken for 5 s: "Not responding").'
    else
    begin
      Res := 0;
      Answered := SendMessageTimeoutW(FWnd, WM_NULL, 0, 0, SMTO_NORMAL, FHangMs, @Res) <> 0;
      if (not Answered) and (GetLastError = ERROR_TIMEOUT) then
        Reason := Format('The main window did not answer a message within %d ms.', [FHangMs]);
    end;
    if WaitForSingleObject(FStop, 0) = WAIT_OBJECT_0 then Break;
    if Reason <> '' then
    begin
      if not Hung then
      begin
        Hung := True;
        HungSince := GetTickCount64;
        WriteReport(Reason);
      end;
    end
    else if Hung then
    begin
      Hung := False;
      { one write: the empty line and the text together }
      AppendLine(LineEnding + Format('%s: the main window answered again (about %.1f s after this report).',
        [FormatDateTime('hh:nn:ss', Now), (GetTickCount64 - HungSince) / 1000]));
      FFile := '';
    end;
  end;
end;

{ ---- public ---- }

procedure StartHangWatch(AWnd: HWND; const AFolder: string; AHangMs, APollMs: Cardinal);
begin
  if (GWatch <> nil) or (AWnd = 0) then Exit;
  GWatch := THangWatch.Create(AWnd, AFolder, AHangMs, APollMs);
end;

{ the watchdog may be in SendMessageTimeout to this thread's window: the
  messages sent to this thread are answered while it waits }
procedure StopHangWatch;
const
  PM_QS_SENDMESSAGE_ = QS_SENDMESSAGE shl 16;
var
  W: THangWatch;
  H: THandle;
  StartTick, Elapsed: QWord;
  R: DWORD;
  Msg: TMsg;
begin
  if GWatch = nil then Exit;
  W := GWatch;
  GWatch := nil;
  SetEvent(W.FStop);
  H := W.Handle;
  StartTick := GetTickCount64;
  repeat
    PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE_);
    Elapsed := GetTickCount64 - StartTick;
    if Elapsed >= 10000 then Break;
    R := MsgWaitForMultipleObjects(1, H, False, DWORD(10000 - Elapsed), QS_SENDMESSAGE);
  until R <> WAIT_OBJECT_0 + 1;
  if WaitForSingleObject(H, 0) = WAIT_OBJECT_0 then
    W.Free;
  { else: it is still writing a report; it ends with the process }
end;

function LastHangReport: string;
begin
  Result := GLastReport;
end;

end.
