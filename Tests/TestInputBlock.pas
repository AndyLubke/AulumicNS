unit TestInputBlock;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestInputBlock
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  uInputBlock: while the block is on, the input messages posted to the windows
  of this thread are dropped and everything else arrives; one allowed window
  (with its children) takes input all the same; Escape is noticed; blocks
  nest. DiscardPendingInput takes the presses out of the queue and leaves
  the releases.
  The messages are posted (PostMessage), as Windows posts real input.
  =============================================================================}

interface

uses
  Classes, SysUtils, Windows, fpcunit, testregistry, uInputBlock;

type
  TTestInputBlock = class(TTestCase)
  private
    FWnd, FOther, FChild: HWND;
    procedure Pump;
    function Got(AWnd: HWND; AMsg: UINT): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure WhichMessagesAreInput;
    procedure WithoutABlockEverythingArrives;
    procedure TheBlockDropsInputAndNothingElse;
    procedure TheAllowedWindowAndItsChildrenTakeInput;
    procedure EscapeIsNoticed;
    procedure BlocksNest;
    procedure PendingInputIsDiscarded;
  end;

implementation

const
  CLASS_NAME = 'AulumicNSTestInputBlock';
  WM_OWN     = WM_USER + 77;
  MAX_SEEN   = 64;

var
  SeenWnd: array[0..MAX_SEEN - 1] of HWND;
  SeenMsg: array[0..MAX_SEEN - 1] of UINT;
  SeenCount: Integer = 0;
  ClassDone: Boolean = False;

function TestWndProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
begin
  if (IsInputMessage(AMsg) or (AMsg = WM_OWN) or (AMsg = WM_TIMER)) and (SeenCount < MAX_SEEN) then
  begin
    SeenWnd[SeenCount] := AWnd;
    SeenMsg[SeenCount] := AMsg;
    Inc(SeenCount);
    Exit(0);
  end;
  Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

function NewWindow(AParent: HWND): HWND;
var
  WC: TWndClassW;
  Style: DWORD;
begin
  if not ClassDone then
  begin
    FillChar(WC, SizeOf(WC), 0);
    WC.lpfnWndProc   := @TestWndProc;
    WC.hInstance     := HInstance;
    WC.lpszClassName := CLASS_NAME;
    Windows.RegisterClassW(WC);
    ClassDone := True;
  end;
  if AParent <> 0 then Style := WS_CHILD else Style := WS_POPUP;
  Result := CreateWindowExW(0, CLASS_NAME, 'test', Style, 0, 0, 10, 10, AParent, 0, HInstance, nil);
end;

{ TTestInputBlock }

procedure TTestInputBlock.SetUp;
begin
  SeenCount := 0;
  FWnd   := NewWindow(0);
  FOther := NewWindow(0);
  FChild := NewWindow(FOther);
  AssertTrue('Windows', (FWnd <> 0) and (FOther <> 0) and (FChild <> 0));
end;

procedure TTestInputBlock.TearDown;
begin
  while InputBlocked do EndInputBlock;
  DestroyWindow(FChild);
  DestroyWindow(FOther);
  DestroyWindow(FWnd);
  Pump;
end;

// what a message loop does (Application.ProcessMessages)
procedure TTestInputBlock.Pump;
var
  M: TMsg;
begin
  M := Default(TMsg);
  while PeekMessageW(M, 0, 0, 0, PM_REMOVE) do
  begin
    TranslateMessage(M);
    DispatchMessageW(M);
  end;
end;

function TTestInputBlock.Got(AWnd: HWND; AMsg: UINT): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to SeenCount - 1 do
    if (SeenWnd[I] = AWnd) and (SeenMsg[I] = AMsg) then Inc(Result);
end;

procedure TTestInputBlock.WhichMessagesAreInput;
begin
  AssertTrue('Mouse', IsInputMessage(WM_MOUSEMOVE) and IsInputMessage(WM_LBUTTONDOWN) and
    IsInputMessage(WM_LBUTTONUP) and IsInputMessage(WM_MOUSEWHEEL) and IsInputMessage($020E));
  AssertTrue('Mouse on the frame', IsInputMessage(WM_NCLBUTTONDOWN) and IsInputMessage(WM_NCMOUSEMOVE));
  AssertTrue('Keys', IsInputMessage(WM_KEYDOWN) and IsInputMessage(WM_KEYUP) and IsInputMessage(WM_CHAR) and
    IsInputMessage(WM_SYSKEYDOWN));
  AssertTrue('Touch, pen, gestures', IsInputMessage($0240) and IsInputMessage($0245) and IsInputMessage($0119));
  AssertFalse('Painting', IsInputMessage(WM_PAINT));
  AssertFalse('Timers', IsInputMessage(WM_TIMER));
  AssertFalse('The program''s own messages', IsInputMessage(WM_USER) or IsInputMessage(WM_APP + 5));
  AssertFalse('Close, commands', IsInputMessage(WM_CLOSE) or IsInputMessage(WM_SYSCOMMAND) or
    IsInputMessage(WM_COMMAND));
  AssertFalse('Nothing', IsInputMessage(WM_NULL));
end;

procedure TTestInputBlock.WithoutABlockEverythingArrives;
begin
  PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
  PostMessageW(FWnd, WM_KEYDOWN, VK_SPACE, 0);
  PostMessageW(FWnd, WM_OWN, 0, 0);
  Pump;
  AssertEquals('Click', 1, Got(FWnd, WM_LBUTTONDOWN));
  AssertEquals('Key', 1, Got(FWnd, WM_KEYDOWN));
  AssertEquals('Own message', 1, Got(FWnd, WM_OWN));
  AssertFalse('No block', InputBlocked);
end;

procedure TTestInputBlock.TheBlockDropsInputAndNothingElse;
begin
  BeginInputBlock;
  try
    AssertTrue('Blocked', InputBlocked);
    PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
    PostMessageW(FWnd, WM_LBUTTONUP, 0, 0);
    PostMessageW(FWnd, WM_MOUSEMOVE, 0, 0);
    PostMessageW(FWnd, WM_MOUSEWHEEL, 0, 0);
    PostMessageW(FWnd, WM_KEYDOWN, VK_SPACE, 0);
    PostMessageW(FWnd, WM_KEYUP, VK_SPACE, 0);
    PostMessageW(FWnd, WM_NCLBUTTONDOWN, HTCLOSE, 0);
    PostMessageW(FWnd, WM_OWN, 0, 0);
    PostMessageW(FWnd, WM_TIMER, 1, 0);
    Pump;
    AssertEquals('No click', 0, Got(FWnd, WM_LBUTTONDOWN) + Got(FWnd, WM_LBUTTONUP));
    AssertEquals('No move, no wheel', 0, Got(FWnd, WM_MOUSEMOVE) + Got(FWnd, WM_MOUSEWHEEL));
    AssertEquals('No key', 0, Got(FWnd, WM_KEYDOWN) + Got(FWnd, WM_KEYUP));
    AssertEquals('No click on the frame', 0, Got(FWnd, WM_NCLBUTTONDOWN));
    AssertEquals('The own message arrives', 1, Got(FWnd, WM_OWN));
    AssertEquals('The timer runs', 1, Got(FWnd, WM_TIMER));
  finally
    EndInputBlock;
  end;
  // dropped, not kept: nothing of it arrives afterwards
  Pump;
  AssertEquals('Nothing is replayed', 0, Got(FWnd, WM_LBUTTONDOWN) + Got(FWnd, WM_KEYDOWN));
  PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
  Pump;
  AssertEquals('Input counts again', 1, Got(FWnd, WM_LBUTTONDOWN));
end;

procedure TTestInputBlock.TheAllowedWindowAndItsChildrenTakeInput;
begin
  BeginInputBlock;
  try
    InputBlockAllow(FOther);
    PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
    PostMessageW(FOther, WM_LBUTTONDOWN, 0, 0);
    PostMessageW(FChild, WM_LBUTTONDOWN, 0, 0);
    PostMessageW(FChild, WM_KEYDOWN, VK_RETURN, 0);
    Pump;
    AssertEquals('The blocked window', 0, Got(FWnd, WM_LBUTTONDOWN));
    AssertEquals('The allowed window', 1, Got(FOther, WM_LBUTTONDOWN));
    AssertEquals('Its child: the click', 1, Got(FChild, WM_LBUTTONDOWN));
    AssertEquals('Its child: the key', 1, Got(FChild, WM_KEYDOWN));
  finally
    EndInputBlock;
  end;
  // the next block starts without an allowed window
  BeginInputBlock;
  try
    PostMessageW(FOther, WM_LBUTTONDOWN, 0, 0);
    Pump;
    AssertEquals('No longer allowed', 1, Got(FOther, WM_LBUTTONDOWN));
  finally
    EndInputBlock;
  end;
end;

procedure TTestInputBlock.EscapeIsNoticed;
begin
  BeginInputBlock;
  try
    InputBlockAllow(FOther);
    AssertFalse('Not yet', InputBlockEscaped);
    PostMessageW(FWnd, WM_KEYDOWN, VK_SPACE, 0);
    Pump;
    AssertFalse('Another key', InputBlockEscaped);
    // in the allowed window Escape is that window's own business
    PostMessageW(FChild, WM_KEYDOWN, VK_ESCAPE, 0);
    Pump;
    AssertFalse('Escape in the allowed window', InputBlockEscaped);
    AssertEquals('It got the key', 1, Got(FChild, WM_KEYDOWN));
    PostMessageW(FWnd, WM_KEYDOWN, VK_ESCAPE, 0);
    Pump;
    AssertTrue('Escape in a blocked window', InputBlockEscaped);
    AssertEquals('Which did not get it', 0, Got(FWnd, WM_KEYDOWN));
  finally
    EndInputBlock;
  end;
  BeginInputBlock;
  try
    AssertFalse('A new block starts without it', InputBlockEscaped);
  finally
    EndInputBlock;
  end;
end;

procedure TTestInputBlock.BlocksNest;
begin
  BeginInputBlock;
  BeginInputBlock;
  EndInputBlock;
  AssertTrue('Still blocked after the inner one', InputBlocked);
  PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
  Pump;
  AssertEquals('Dropped', 0, Got(FWnd, WM_LBUTTONDOWN));
  EndInputBlock;
  AssertFalse('Open again', InputBlocked);
  EndInputBlock;   // one too many: nothing happens
  AssertFalse('Still open', InputBlocked);
end;

{ the input that queued up while the thread worked is taken out; the rest
  of the queue stays }
procedure TTestInputBlock.PendingInputIsDiscarded;
var
  N: Integer;
begin
  PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
  PostMessageW(FWnd, WM_LBUTTONUP, 0, 0);
  PostMessageW(FWnd, WM_OWN, 0, 0);
  PostMessageW(FOther, WM_KEYDOWN, VK_SPACE, 0);
  PostMessageW(FChild, WM_MOUSEWHEEL, 0, 0);
  PostMessageW(FWnd, WM_NCLBUTTONDOWN, HTCLOSE, 0);
  N := DiscardPendingInput;
  AssertEquals('The four presses are removed', 4, N);
  Pump;
  AssertEquals('No click', 0, Got(FWnd, WM_LBUTTONDOWN) + Got(FWnd, WM_NCLBUTTONDOWN));
  { the release stays: a button that went down before the work began gets
    its "up" (a release without its press does nothing) }
  AssertEquals('The release arrives', 1, Got(FWnd, WM_LBUTTONUP));
  AssertEquals('No key, no wheel', 0, Got(FOther, WM_KEYDOWN) + Got(FChild, WM_MOUSEWHEEL));
  AssertEquals('The own message is still handled', 1, Got(FWnd, WM_OWN));
  AssertEquals('Nothing left to remove', 0, DiscardPendingInput);
  PostMessageW(FWnd, WM_KEYDOWN, VK_DELETE, 0);
  PostMessageW(FWnd, WM_KEYUP, VK_DELETE, 0);
  AssertEquals('A key press goes, its release stays', 1, DiscardPendingInput);
  Pump;
  AssertEquals('No key down', 0, Got(FWnd, WM_KEYDOWN));
  AssertEquals('The key up', 1, Got(FWnd, WM_KEYUP));
  PostMessageW(FWnd, WM_LBUTTONDOWN, 0, 0);
  Pump;
  AssertEquals('The next click counts', 1, Got(FWnd, WM_LBUTTONDOWN));
end;

initialization
  RegisterTest(TTestInputBlock);

end.
