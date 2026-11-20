unit uInputBlock;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - uInputBlock
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The program does not take input for a moment, but stays alive: while a worker
  thread wakes a drive (AuTagLoader.TDriveWaiter) the UI thread keeps handling
  messages - the windows paint, the timers run, the time of the track moves
  on - and the mouse and the keyboard are ignored, as in a window that is busy
  on its own thread, only without the window turning white.

  How: a WH_GETMESSAGE hook on the calling thread turns every input message it
  takes out of the queue (mouse, keyboard, touch, pen, gestures) into WM_NULL.
  Not EnableWindow(False): over a disabled window Windows shows the arrow
  instead of the busy cursor, and every click beeps and flashes.
  The input of that time is dropped, not kept: nothing happens afterwards for
  a click made while the program did not listen.

  - BeginInputBlock / EndInputBlock: in pairs, on the same thread; they nest.
  - InputBlockAllow: one window (with its child windows) that takes input all
    the same - the "Waiting for drive..." window with its Cancel button.
  - InputBlockEscaped: Escape was pressed (in a window that is blocked) since
    the block began: the caller's "stop waiting".
  Messages that are SENT to a window never pass the hook (a close from the
  taskbar, the end of the Windows session): the callers handle those as ever.
  - DiscardPendingInput: for work that runs ON the UI thread (a large playlist
    built again): nothing is handled meanwhile anyway, but the clicks and keys
    of that time wait in the queue and would all run afterwards, on a list
    that is no longer the one that was clicked. This takes them out - the
    presses, not the releases: a button or key that went down before the
    work began (the double click that started it) still gets its "up", so
    no control is left holding the mouse. A release without its press does
    nothing.
  Tests: Tests\TestInputBlock.pas.
  =============================================================================}

interface

uses
  Classes, Windows;

procedure BeginInputBlock;
procedure EndInputBlock;
function InputBlocked: Boolean;
procedure InputBlockAllow(AWindow: HWND);
function InputBlockEscaped: Boolean;

// The input messages waiting in this thread's queue are removed, unhandled;
// the number of messages removed
function DiscardPendingInput: Integer;

// True for the messages the block drops
function IsInputMessage(AMsg: UINT): Boolean;

{ Called now and then by work that keeps the window's thread busy for
  seconds (building a large playlist, opening a whole branch of the library
  tree, checking the files of a playlist). It tells Windows that the thread
  is alive: a thread that does not look at its messages for 5 s gets its
  window greyed out with "Not responding". No message is taken out of the
  queue and none is handled, so nothing the user did meanwhile runs in the
  middle of the work; only messages SENT to the thread's windows are
  answered (the hang watchdog's among them). It looks at most every
  KEEP_ALIVE_MS, so it may be called in every pass of a loop; on another
  thread it does nothing. }
procedure KeepWindowAlive;

implementation

const
  WM_NCMOUSE_FIRST = $00A0;   // WM_NCMOUSEMOVE
  WM_NCMOUSE_LAST  = $00AD;   // WM_NCXBUTTONDBLCLK
  WM_KEY_FIRST     = $0100;   // WM_KEYDOWN
  WM_KEY_LAST      = $0109;   // WM_UNICHAR
  WM_GESTURE_MSG   = $0119;
  WM_MOUSE_FIRST   = $0200;   // WM_MOUSEMOVE
  WM_MOUSE_LAST    = $020E;   // WM_MOUSEHWHEEL
  WM_TOUCH_MSG     = $0240;
  WM_POINTER_FIRST = $0241;   // WM_NCPOINTERUPDATE
  WM_POINTER_LAST  = $0257;   // WM_POINTERROUTEDRELEASED

var
  BlockDepth : Integer = 0;
  BlockHook  : HHOOK = 0;
  BlockThread: DWORD = 0;
  AllowWnd   : HWND = 0;
  Escaped    : Boolean = False;

const
  KEEP_ALIVE_MS = 250;

var
  GKeepAliveTick: QWord = 0;

procedure KeepWindowAlive;
var
  Msg: TMsg;
  Now_: QWord;
begin
  if GetCurrentThreadId <> MainThreadID then Exit;
  Now_ := GetTickCount64;
  if Now_ - GKeepAliveTick < KEEP_ALIVE_MS then Exit;
  GKeepAliveTick := Now_;
  PeekMessageW(Msg, 0, 0, 0, PM_NOREMOVE);
end;

function IsInputMessage(AMsg: UINT): Boolean;
begin
  Result := ((AMsg >= WM_NCMOUSE_FIRST) and (AMsg <= WM_NCMOUSE_LAST)) or
            ((AMsg >= WM_KEY_FIRST) and (AMsg <= WM_KEY_LAST)) or
            (AMsg = WM_GESTURE_MSG) or
            ((AMsg >= WM_MOUSE_FIRST) and (AMsg <= WM_MOUSE_LAST)) or
            (AMsg = WM_TOUCH_MSG) or
            ((AMsg >= WM_POINTER_FIRST) and (AMsg <= WM_POINTER_LAST));
end;

function Allowed(AWnd: HWND): Boolean;
begin
  Result := (AllowWnd <> 0) and (AWnd <> 0) and
            ((AWnd = AllowWnd) or IsChild(AllowWnd, AWnd));
end;

// Called by Windows on the blocked thread for every message GetMessage /
// PeekMessage hands out
function GetMsgHook(ACode: Integer; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
var
  M: PMsg;
begin
  if (ACode = HC_ACTION) and (AWParam = PM_REMOVE) and (ALParam <> 0) and (BlockDepth > 0) then
  begin
    M := PMsg(ALParam);
    if IsInputMessage(M^.message) and not Allowed(M^.hwnd) then
    begin
      if (M^.message = WM_KEYDOWN) and (M^.wParam = VK_ESCAPE) then
        Escaped := True;
      M^.message := WM_NULL;
      M^.wParam  := 0;
      M^.lParam  := 0;
    end;
  end;
  Result := CallNextHookEx(0, ACode, AWParam, ALParam);
end;

procedure BeginInputBlock;
begin
  if BlockDepth = 0 then
  begin
    Escaped     := False;
    AllowWnd    := 0;
    BlockThread := GetCurrentThreadId;
    BlockHook   := SetWindowsHookExW(WH_GETMESSAGE, @GetMsgHook, 0, BlockThread);
    // (no hook: the block does nothing, the wait itself goes on as before)
  end;
  Inc(BlockDepth);
end;

procedure EndInputBlock;
begin
  if BlockDepth = 0 then
    Exit;
  Dec(BlockDepth);
  if BlockDepth = 0 then
  begin
    if BlockHook <> 0 then
      UnhookWindowsHookEx(BlockHook);
    BlockHook := 0;
    AllowWnd  := 0;
  end;
end;

function InputBlocked: Boolean;
begin
  Result := (BlockDepth > 0) and (BlockHook <> 0);
end;

procedure InputBlockAllow(AWindow: HWND);
begin
  AllowWnd := AWindow;
end;

function InputBlockEscaped: Boolean;
begin
  Result := Escaped;
end;

function DiscardPendingInput: Integer;

const
  // button down / double click (client and frame), wheel; keys down and the
  // characters made of them; gestures and touch. Not: the "up" messages
  // ($0202, $0205, $0208, $020C; $00A2, $00A5, $00A8, $00AC; $0101, $0105)
  // and the mouse moves.
  PRESSES: array[0..23] of UINT = (
    $0201, $0203, $0204, $0206, $0207, $0209, $020A, $020B, $020D, $020E,
    $00A1, $00A3, $00A4, $00A6, $00A7, $00A9, $00AB, $00AD,
    $0100, $0102, $0103, $0104, $0106, $0107);
var
  M: TMsg;
  I: Integer;

  procedure Take(AMsg: UINT);
  begin
    while PeekMessageW(M, 0, AMsg, AMsg, PM_REMOVE) do
      Inc(Result);
  end;

begin
  Result := 0;
  M := Default(TMsg);
  for I := 0 to High(PRESSES) do
    Take(PRESSES[I]);
  Take($0109);            // WM_UNICHAR
  Take(WM_GESTURE_MSG);
  Take(WM_TOUCH_MSG);
end;

finalization
  if BlockHook <> 0 then
    UnhookWindowsHookEx(BlockHook);

end.
