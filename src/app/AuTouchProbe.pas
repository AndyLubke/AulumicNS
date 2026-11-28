unit AuTouchProbe;

{ ==============================================================================
  AulumicNS - AuTouchProbe
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Debug build only: the touch probe (--touch-probe=<report>,
  run by Tools\ProbeTouch.ps1). It checks touch scrolling without a touch
  screen: Windows' touch injection (InjectTouchInput, Windows 8 and later,
  no touch hardware needed) puts a simulated finger on the screen, and
  Windows' own gesture recognition turns its moves into the same WM_GESTURE /
  GID_PAN messages a touch screen gives. The mouse checks use real input as
  well (SendInput: the wheel, a drag of the scroll bar thumb, a click on its
  track), so they show that the wheel and the scroll bars still work.

  Each check reads the control's scroll position (TAuControl.ScrollOffset)
  before and after: exact, no screenshots needed. A swipe's line also counts
  the messages the UI thread got (thread hooks: pointer, gesture, mouse; the
  pan's begin / inertia / end) and the pan configuration Windows has for the
  window under the finger - what a swipe became when it did not scroll.
  The touches come from a thread of their own (TInjector): InjectTouchInput
  waits until the touch is delivered, so from the UI thread into its own
  windows it times out.

  This is real input on the desktop for about half a minute: the windows are
  put on top and the mouse pointer is moved (and put back at the end).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, StrUtils, Controls, Forms, AuControls, AuMenus, AuAnim;

type
  { shows or hides something the probe wants to look at }
  TProbeSwitch = procedure(AOn: Boolean) of object;

{ runs every check over the main window (APlaylist, ATree, and ATiles once
  AShowTiles has put the album tiles in the tree's place), Preferences, the
  help and a booklet (APdf; '' = none), writes the report to AReport and
  returns the number of failures }
function RunTouchProbe(AMain: TCustomForm; APlaylist, ATree, ATiles: TAuControl;
  AShowTiles: TProbeSwitch; const APdf, AReport: string): Integer;

implementation

uses
  AuTheme, AuForms, AuPrefs, AuHelp, AuBooklet, AuPlaylistPane, uAppConsts;

{$PACKRECORDS C}
type
  TPointerInfo_ = record
    pointerType, pointerId, frameId, pointerFlags: DWORD;
    sourceDevice: THandle;
    hwndTarget: HWND;
    ptPixelLocation, ptHimetricLocation, ptPixelLocationRaw, ptHimetricLocationRaw: TPoint;
    dwTime, historyCount: DWORD;
    InputData: LongInt;
    dwKeyStates: DWORD;
    PerformanceCount: QWord;
    ButtonChangeType: LongInt;
  end;

  TPointerTouchInfo_ = record
    pointerInfo: TPointerInfo_;
    touchFlags, touchMask: DWORD;
    rcContact, rcContactRaw: TRect;
    orientation, pressure: DWORD;
  end;

  TMouseInput_ = record
    dx, dy: LongInt;
    mouseData, dwFlags, time: DWORD;
    dwExtraInfo: PtrUInt;
  end;

  TInput_ = record
    itype: DWORD;
    mi: TMouseInput_;
  end;
{$PACKRECORDS DEFAULT}

  TInitializeTouchInjection_ = function(maxCount, dwMode: DWORD): BOOL; stdcall;
  TInjectTouchInput_ = function(count: DWORD; contacts: Pointer): BOOL; stdcall;

const
  POINTER_TOUCH_INFO_SIZE = 144;     // sizeof(POINTER_TOUCH_INFO) on x64
  PT_TOUCH_ = 2;
  PF_INRANGE = $2;
  PF_INCONTACT = $4;
  PF_DOWN = $10000;
  PF_UPDATE = $20000;
  PF_UP = $40000;
  TOUCH_MASK_ALL = 7;                // contact area, orientation, pressure
  TOUCH_FEEDBACK_NONE_ = 3;
  INPUT_MOUSE_ = 0;
  ME_MOVE = $0001;
  ME_LEFTDOWN = $0002;
  ME_LEFTUP = $0004;
  ME_WHEEL = $0800;
  ME_VIRTUALDESK = $4000;
  ME_ABSOLUTE = $8000;
  { what a check expects of the scroll position }
  EXPECT_MORE = 1;
  EXPECT_LESS = -1;
  EXPECT_SAME = 0;
  { the booklet's ScrollOffset: page (spread) * PAGE_STEP + pan offset }
  PAGE_STEP = 100000;

{$IF SizeOf(TPointerTouchInfo_) <> POINTER_TOUCH_INFO_SIZE}
  {$ERROR TPointerTouchInfo_ does not match POINTER_TOUCH_INFO}
{$ENDIF}
{$IF SizeOf(TInput_) <> 40}
  {$ERROR TInput_ does not match INPUT}
{$ENDIF}

function SendInput_(cInputs: UINT; pInputs: Pointer; cbSize: Integer): UINT; stdcall;
  external 'user32.dll' name 'SendInput';

{ ---- the messages the UI thread gets (thread hooks): what a swipe became ---- }

type
  TMsgKind = (mkPtrDown, mkPtrUpdate, mkPtrUp, mkGestureNotify, mkGesture, mkTouch,
    mkLButtonDown, mkMouseMove, mkWheel);

const
  { the moves of a simulated finger, 15 ms apart: a swipe, and a tap }
  SWIPE_STEPS = 24;
  TAP_STEPS = 2;
  MSG_IDS: array[TMsgKind] of UINT =($0246, $0245, $0247, $011A, $0119, $0240,
    $0201, $0200, $020A);
  MSG_NAMES: array[TMsgKind] of string = ('pointer down', 'pointer update', 'pointer up',
    'gesture notify', 'gesture', 'touch', 'left button down', 'mouse move', 'wheel');

type
  {$PUSH}{$PACKRECORDS C}
  TGestureInfoRec_ = record
    cbSize, dwFlags, dwID: DWORD;
    hwndTarget: HWND;
    ptsX, ptsY: SmallInt;
    dwInstanceID, dwSequenceID: DWORD;
    ullArguments: QWord;
    cbExtraArgs: UINT;
  end;
  {$POP}

function GetGestureInfoX_(hGestureInfo: THandle; var pGestureInfo: TGestureInfoRec_): BOOL; stdcall;
  external 'user32.dll' name 'GetGestureInfo';

var
  GHookGet: HHOOK = 0;
  GHookCall: HHOOK = 0;
  GMsgCount: array[TMsgKind] of Integer;
  GPanBegin, GPanInertia, GPanEnd: Integer;   // the GID_PAN flags seen

procedure CountMsg(M: UINT; LP: LPARAM);
var
  K: TMsgKind;
  GI: TGestureInfoRec_;
begin
  for K := Low(TMsgKind) to High(TMsgKind) do
    if MSG_IDS[K] = M then
    begin
      Inc(GMsgCount[K]);
      if K = mkGesture then
      begin
        FillChar(GI, SizeOf(GI), 0);
        GI.cbSize := SizeOf(GI);
        if GetGestureInfoX_(THandle(LP), GI) and (GI.dwID = 4) then
        begin
          if (GI.dwFlags and 1) <> 0 then Inc(GPanBegin);
          if (GI.dwFlags and 2) <> 0 then Inc(GPanInertia);
          if (GI.dwFlags and 4) <> 0 then Inc(GPanEnd);
        end;
      end;
      Exit;
    end;
end;

function GetMsgHook(nCode: LongInt; wP: WPARAM; lP: LPARAM): LRESULT; stdcall;
begin
  if (nCode = HC_ACTION) and (wP = PM_REMOVE) then
    CountMsg(PMsg(lP)^.message, PMsg(lP)^.lParam);
  Result := CallNextHookEx(GHookGet, nCode, wP, lP);
end;

function CallWndHook(nCode: LongInt; wP: WPARAM; lP: LPARAM): LRESULT; stdcall;
begin
  if nCode = HC_ACTION then CountMsg(PCWPStruct(lP)^.message, PCWPStruct(lP)^.lParam);
  Result := CallNextHookEx(GHookCall, nCode, wP, lP);
end;

function MsgSummary: string;
var
  K: TMsgKind;
begin
  Result := '';
  for K := Low(TMsgKind) to High(TMsgKind) do
    if GMsgCount[K] > 0 then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + MSG_NAMES[K] + ' ' + IntToStr(GMsgCount[K]);
    end;
  if Result = '' then Result := 'no messages';
  if GPanBegin + GPanInertia + GPanEnd > 0 then
    Result := Result + Format(' (pan: begin %d, inertia %d, end %d)', [GPanBegin, GPanInertia, GPanEnd]);
end;

procedure ResetMsgCount;
begin
  FillChar(GMsgCount, SizeOf(GMsgCount), 0);
  GPanBegin := 0;
  GPanInertia := 0;
  GPanEnd := 0;
end;

{ the control (or window class) at screen point P }
function WhoIsAt(const P: TPoint): string;
var
  H: HWND;
  C: TWinControl;
  Cls: array[0..63] of WideChar;
begin
  H := WindowFromPoint(P);
  C := FindControl(H);
  if C <> nil then Result := C.ClassName
  else
  begin
    FillChar(Cls, SizeOf(Cls), 0);
    GetClassNameW(H, @Cls[0], 63);
    Result := 'window class ' + UTF8Encode(WideString(PWideChar(@Cls[0])));
  end;
end;

type
  TGestureConfigRec_ = record
    dwID, dwWant, dwBlock: DWORD;
  end;

function GetGestureConfig_(hwnd: HWND; dwReserved, dwFlags: DWORD; pcIDs: PUINT;
  pGestureConfig: Pointer; cbSize: UINT): BOOL; stdcall;
  external 'user32.dll' name 'GetGestureConfig';

{ the pan configuration of the window at P (as Windows has it) }
function PanConfigAt(const P: TPoint): string;
var
  C: TGestureConfigRec_;
  N: UINT;
  H: HWND;
begin
  H := WindowFromPoint(P);
  C.dwID := 4;                   // GID_PAN
  C.dwWant := 0;
  C.dwBlock := 0;
  N := 1;
  if GetGestureConfig_(H, 0, 0, @N, @C, SizeOf(C)) then
    Result := Format('pan config want $%x block $%x', [C.dwWant, C.dwBlock])
  else
    Result := 'GetGestureConfig error ' + IntToStr(GetLastError);
end;

{ True when the window at P is V or one of its children }
function IsOver(V: TWinControl; const P: TPoint): Boolean;
var
  C: TWinControl;
begin
  C := FindControl(WindowFromPoint(P));
  Result := (C <> nil) and ((C = V) or V.ContainsControl(C));
end;

type
  { InjectTouchInput waits until the touch is delivered: injected from the UI
    thread into its own windows, it times out (error 1460). So a thread of
    its own injects, while the UI thread goes on handling its messages. }
  TInjector = class(TThread)
  private
    FGo: PRTLEvent;
    FBusy: LongInt;               // 1 while initialising or swiping
    FInject: TInjectTouchInput_;
    FP0, FP1: TPoint;
    FSteps: Integer;              // the moves of a swipe, 15 ms apart (a tap: two)
    FOk: Boolean;
    FError: string;
    function Touch(X, Y: Integer; AFlags: DWORD): Boolean;
    procedure DoSwipe;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TProbe = class
  private
    FLines: TStringList;
    FReport: string;
    FFailures: Integer;
    FInj: TInjector;
    FError: string;
    function WaitInjector(AMs: Integer): Boolean;
    procedure Mouse(AFlags: DWORD; AData: DWORD = 0);
    procedure MouseAt(X, Y: Integer);
    function Swipe(const P0, P1: TPoint; ASteps: Integer = SWIPE_STEPS): Boolean;
    procedure Wheel(const P: TPoint; ADelta: Integer);
    procedure Drag(const P0, P1: TPoint);
    procedure Click(const P: TPoint);
    function Covered(V: TWinControl; const P: TPoint): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Pump(AMs: Integer);
    procedure Line(const S: string);
    procedure Check(const AWhat: string; AOk: Boolean; const ANote: string);
    procedure SwipeCheck(const AWhat: string; V: TAuControl; FX0, FY0, FX1, FY1: Double;
      AExpect: Integer);
    procedure WheelCheck(const AWhat: string; V: TAuControl);
    procedure GlideCheck(const AWhat: string; V: TAuControl);
    procedure ScrollBarChecks(const AName: string; V: TAuControl);
    { swipes up and back, the wheel, the scroll bar }
    procedure ViewChecks(const AName: string; V: TAuControl);
    { a booklet swipe: exactly one page on (ADir = 1) or back (-1) }
    procedure PageSwipeCheck(const AWhat: string; V: TAuControl; ADir: Integer);
    { the mouse drags the splitter of APane 40 px wider and back (it paints
      the panes while it moves: they must still follow) }
    procedure SplitterCheck(APane: TControl);
    procedure ColumnEdgeCheck(APlaylist: TAuControl; ALibPane: TControl);
    procedure PictureEdgeCheck(AHelp: TWinControl);
    { a menu of 80 items (as the playlist selector with many playlists): it
      fits the screen and the wheel scrolls it down to its last item }
    procedure LongMenuCheck(AMain: TCustomForm);
    property Failures: Integer read FFailures;
  end;

{ a point of C at fractions of its client area, in screen pixels }
function At(C: TControl; FX, FY: Double): TPoint;
begin
  Result := C.ClientToScreen(Point(Round(FX * C.ClientWidth), Round(FY * C.ClientHeight)));
end;

function ExpectText(AExpect: Integer): string;
begin
  case AExpect of
    EXPECT_MORE: Result := 'expected more';
    EXPECT_LESS: Result := 'expected less';
  else
    Result := 'expected no change';
  end;
end;

function Met(A, B, AExpect: Integer): Boolean;
begin
  case AExpect of
    EXPECT_MORE: Result := B > A;
    EXPECT_LESS: Result := B < A;
  else
    Result := B = A;
  end;
end;

{ the window on top of every other one; ALogW = 0: keeps its size }
procedure PlaceOnTop(F: TCustomForm; ALogW, ALogH: Integer);
var
  K: Double;
  R: TRect;
  Flags: UINT;
begin
  if F.WindowState <> wsNormal then F.WindowState := wsNormal;
  K := WindowDpi(F.Handle) / 96;
  if K <= 0 then K := 1;
  R := Rect(0, 0, 0, 0);
  SystemParametersInfo(SPI_GETWORKAREA, 0, @R, 0);
  Flags := SWP_SHOWWINDOW;
  if ALogW <= 0 then Flags := Flags or SWP_NOSIZE;
  SetWindowPos(F.Handle, HWND_TOPMOST, R.Left + Round(40 * K), R.Top + Round(40 * K),
    Round(ALogW * K), Round(ALogH * K), Flags);
  SetForegroundWindow(F.Handle);
end;

{ the first visible control of this class below AParent }
function FindOfClass(AParent: TWinControl; const AClass: string): TAuControl;
var
  I: Integer;
  C: TControl;
begin
  Result := nil;
  if AParent = nil then Exit;
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    if not C.Visible then Continue;
    if (C is TAuControl) and SameText(C.ClassName, AClass) then Exit(TAuControl(C));
    if C is TWinControl then
    begin
      Result := FindOfClass(TWinControl(C), AClass);
      if Result <> nil then Exit;
    end;
  end;
end;

{ the vertical scroll bar of V, when it can scroll }
function ScrollBarOf(V: TWinControl): TAuScrollBar;
var
  I: Integer;
  B: TAuScrollBar;
begin
  Result := nil;
  if V = nil then Exit;
  for I := 0 to V.ControlCount - 1 do
    if V.Controls[I] is TAuScrollBar then
    begin
      B := TAuScrollBar(V.Controls[I]);
      if B.Visible and B.NeedScroll and (B.Kind = aoVertical) then Exit(B);
    end;
end;

{ the first visible scroll box below AParent that can scroll }
function FindScrollingBox(AParent: TWinControl): TAuControl;
var
  I: Integer;
  C: TControl;
begin
  Result := nil;
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    if not C.Visible then Continue;
    if (C is TAuScrollBox) and (ScrollBarOf(TWinControl(C)) <> nil) then Exit(TAuControl(C));
    if C is TWinControl then
    begin
      Result := FindScrollingBox(TWinControl(C));
      if Result <> nil then Exit;
    end;
  end;
end;

{ ---- TInjector ---- }

constructor TInjector.Create;
begin
  FGo := RTLEventCreate;
  FBusy := 1;                     // until the injection is initialised
  inherited Create(False);
end;

destructor TInjector.Destroy;
begin
  Terminate;
  RTLEventSetEvent(FGo);
  inherited Destroy;              // waits for Execute
  RTLEventDestroy(FGo);
end;

procedure TInjector.Execute;
var
  Init: TInitializeTouchInjection_;
  U: HMODULE;
begin
  FInject := nil;
  U := GetModuleHandle('user32.dll');
  Init := TInitializeTouchInjection_(GetProcAddress(U, 'InitializeTouchInjection'));
  if not Assigned(Init) then
    FError := 'InitializeTouchInjection is missing (Windows 8 or later needed)'
  else if not Init(1, TOUCH_FEEDBACK_NONE_) then
    FError := 'InitializeTouchInjection failed, error ' + IntToStr(GetLastError)
  else
    FInject := TInjectTouchInput_(GetProcAddress(U, 'InjectTouchInput'));
  InterlockedExchange(FBusy, 0);
  while not Terminated do
  begin
    RTLEventWaitFor(FGo);
    if Terminated then Break;
    DoSwipe;
    InterlockedExchange(FBusy, 0);
  end;
end;

function TInjector.Touch(X, Y: Integer; AFlags: DWORD): Boolean;
var
  C: TPointerTouchInfo_;
begin
  FillChar(C, SizeOf(C), 0);
  C.pointerInfo.pointerType := PT_TOUCH_;
  C.pointerInfo.pointerId := 0;
  C.pointerInfo.pointerFlags := AFlags;
  C.pointerInfo.ptPixelLocation := Point(X, Y);
  C.touchMask := TOUCH_MASK_ALL;
  C.rcContact := Rect(X - 4, Y - 4, X + 4, Y + 4);
  C.orientation := 90;
  C.pressure := 32000;
  Result := FInject(1, @C);
  if not Result then FError := 'InjectTouchInput failed, error ' + IntToStr(GetLastError);
end;

{ a finger from FP0 to FP1 (screen pixels) }
procedure TInjector.DoSwipe;
const
  STEP_MS = 15;
var
  I, Steps: Integer;
begin
  FOk := False;
  Steps := FSteps;
  if Steps < 1 then Steps := 1;
  if not Assigned(FInject) then Exit;
  if not Touch(FP0.X, FP0.Y, PF_DOWN or PF_INRANGE or PF_INCONTACT) then Exit;
  Sleep(30);
  for I := 1 to Steps do
  begin
    if not Touch(FP0.X + (FP1.X - FP0.X) * I div Steps, FP0.Y + (FP1.Y - FP0.Y) * I div Steps,
      PF_UPDATE or PF_INRANGE or PF_INCONTACT) then
    begin
      Touch(FP1.X, FP1.Y, PF_UP);           // never leave the finger down
      Exit;
    end;
    Sleep(STEP_MS);
  end;
  FOk := Touch(FP1.X, FP1.Y, PF_UP);
end;

{ ---- TProbe ---- }

constructor TProbe.Create;
begin
  inherited Create;
  FLines := TStringList.Create;
  ResetMsgCount;
  GHookGet := SetWindowsHookEx(WH_GETMESSAGE, @GetMsgHook, 0, GetCurrentThreadId);
  GHookCall := SetWindowsHookEx(WH_CALLWNDPROC, @CallWndHook, 0, GetCurrentThreadId);
  FInj := TInjector.Create;
  if not WaitInjector(5000) then FError := 'the touch injection thread did not start';
  if FError = '' then FError := FInj.FError;
end;

destructor TProbe.Destroy;
begin
  if GHookGet <> 0 then UnhookWindowsHookEx(GHookGet);
  if GHookCall <> 0 then UnhookWindowsHookEx(GHookCall);
  GHookGet := 0;
  GHookCall := 0;
  FInj.Free;
  FLines.Free;
  inherited Destroy;
end;

{ waits (handling the messages) until the injector is idle }
function TProbe.WaitInjector(AMs: Integer): Boolean;
var
  T: QWord;
begin
  T := GetTickCount64 + QWord(AMs);
  while (InterlockedCompareExchange(FInj.FBusy, 0, 0) <> 0) and (GetTickCount64 < T) do
  begin
    Application.ProcessMessages;
    Sleep(2);
  end;
  Result := InterlockedCompareExchange(FInj.FBusy, 0, 0) = 0;
end;

procedure TProbe.Pump(AMs: Integer);
var
  T: QWord;
begin
  T := GetTickCount64 + QWord(AMs);
  repeat
    Application.ProcessMessages;
    if GetTickCount64 >= T then Break;
    Sleep(2);
  until False;
end;

procedure TProbe.Line(const S: string);
begin
  FLines.Add(S);
  { written at once: a probe that hangs shows how far it came }
  if FReport <> '' then
  try
    FLines.SaveToFile(FReport);
  except
    FReport := '';
  end;
end;

procedure TProbe.Check(const AWhat: string; AOk: Boolean; const ANote: string);
begin
  if AOk then Line('ok   ' + AWhat + '  (' + ANote + ')')
  else
  begin
    Inc(FFailures);
    Line('FAIL ' + AWhat + '  (' + ANote + ')');
  end;
end;

{ a finger from P0 to P1 (screen pixels), then the inertia of the pan }
function TProbe.Swipe(const P0, P1: TPoint; ASteps: Integer): Boolean;
begin
  Result := False;
  if not Assigned(FInj.FInject) then
  begin
    FError := FInj.FError;
    Exit;
  end;
  FInj.FP0 := P0;
  FInj.FP1 := P1;
  FInj.FSteps := ASteps;
  InterlockedExchange(FInj.FBusy, 1);
  RTLEventSetEvent(FInj.FGo);
  if not WaitInjector(15000) then
  begin
    FError := 'the touch injection did not finish';
    Exit;
  end;
  Result := FInj.FOk;
  if not Result then FError := FInj.FError;
  Pump(1500);
end;

procedure TProbe.Mouse(AFlags: DWORD; AData: DWORD);
var
  I: TInput_;
begin
  FillChar(I, SizeOf(I), 0);
  I.itype := INPUT_MOUSE_;
  I.mi.dwFlags := AFlags;
  I.mi.mouseData := AData;
  SendInput_(1, @I, SizeOf(I));
end;

procedure TProbe.MouseAt(X, Y: Integer);
var
  I: TInput_;
  VL, VT, VW, VH: Integer;
begin
  VL := GetSystemMetrics(SM_XVIRTUALSCREEN);
  VT := GetSystemMetrics(SM_YVIRTUALSCREEN);
  VW := GetSystemMetrics(SM_CXVIRTUALSCREEN);
  VH := GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (VW < 2) or (VH < 2) then Exit;
  FillChar(I, SizeOf(I), 0);
  I.itype := INPUT_MOUSE_;
  I.mi.dx := MulDiv(X - VL, 65535, VW - 1);
  I.mi.dy := MulDiv(Y - VT, 65535, VH - 1);
  I.mi.dwFlags := ME_MOVE or ME_ABSOLUTE or ME_VIRTUALDESK;
  SendInput_(1, @I, SizeOf(I));
  SetCursorPos(X, Y);
end;

procedure TProbe.Wheel(const P: TPoint; ADelta: Integer);
begin
  MouseAt(P.X, P.Y);
  Pump(150);
  Mouse(ME_WHEEL, DWORD(ADelta));
  Pump(600);
end;

procedure TProbe.Drag(const P0, P1: TPoint);
const
  STEPS = 12;
var
  I: Integer;
begin
  MouseAt(P0.X, P0.Y);
  Pump(100);
  Mouse(ME_LEFTDOWN);
  Pump(100);
  for I := 1 to STEPS do
  begin
    MouseAt(P0.X + (P1.X - P0.X) * I div STEPS, P0.Y + (P1.Y - P0.Y) * I div STEPS);
    Pump(25);
  end;
  Mouse(ME_LEFTUP);
  Pump(400);
end;

procedure TProbe.Click(const P: TPoint);
begin
  MouseAt(P.X, P.Y);
  Pump(100);
  Mouse(ME_LEFTDOWN);
  Pump(60);
  Mouse(ME_LEFTUP);
  Pump(400);
end;

{ True (and noted) when not V (or a child of it) is at P }
function TProbe.Covered(V: TWinControl; const P: TPoint): Boolean;
begin
  Result := not IsOver(V, P);
  if Result then
    FError := Format('at %d, %d is %s, not the %s', [P.X, P.Y, WhoIsAt(P), V.ClassName]);
end;

procedure TProbe.SwipeCheck(const AWhat: string; V: TAuControl; FX0, FY0, FX1, FY1: Double;
  AExpect: Integer);
var
  A, B: Integer;
  P0, P1: TPoint;
begin
  if V = nil then
  begin
    Check(AWhat, False, 'control not found');
    Exit;
  end;
  P0 := At(V, FX0, FY0);
  P1 := At(V, FX1, FY1);
  if Covered(V, P0) then
  begin
    Check(AWhat, False, FError);
    Exit;
  end;
  A := V.ScrollOffset;
  ResetMsgCount;
  if not Swipe(P0, P1) then
  begin
    Check(AWhat, False, FError);
    Exit;
  end;
  B := V.ScrollOffset;
  Check(AWhat, Met(A, B, AExpect), Format('offset %d -> %d, %s; %s; %s at the start: %s',
    [A, B, ExpectText(AExpect), MsgSummary, WhoIsAt(P0), PanConfigAt(P0)]));
end;

{ the wheel over the middle of V: up when it is scrolled, else down }
procedure TProbe.WheelCheck(const AWhat: string; V: TAuControl);
var
  A, B, E, D: Integer;
  P: TPoint;
begin
  if V = nil then Exit;
  P := At(V, 0.5, 0.5);
  if Covered(V, P) then
  begin
    Check(AWhat, False, FError);
    Exit;
  end;
  A := V.ScrollOffset;
  if A > 0 then begin D := 120; E := EXPECT_LESS; end
  else begin D := -120; E := EXPECT_MORE; end;
  ResetMsgCount;
  Wheel(P, D);
  B := V.ScrollOffset;
  Check(AWhat, Met(A, B, E), Format('wheel %s: offset %d -> %d, %s; %s',
    [IfThen(D > 0, '+', '') + IntToStr(D), A, B, ExpectText(E), MsgSummary]));
end;

{ the wheel with animations on (the other checks run without
  them): the list glides, and it must arrive where the wheel without
  animations takes it - one notch down gliding, one notch up at once, and
  the list is back where it was }
procedure TProbe.GlideCheck(const AWhat: string; V: TAuControl);
var
  A, B, C, Mid: Integer;
  P: TPoint;
  Shown: Boolean;
begin
  if V = nil then Exit;
  P := At(V, 0.5, 0.5);
  if Covered(V, P) then
  begin
    Check(AWhat, False, FError);
    Exit;
  end;
  { from the top, so that one notch has its full way }
  while V.ScrollOffset > 0 do
  begin
    A := V.ScrollOffset;
    Wheel(P, 120);
    if V.ScrollOffset >= A then Break;
  end;
  A := V.ScrollOffset;
  AnimationsOn := True;
  try
    Shown := AnimActive;
    Wheel(P, -120);
    Mid := V.ScrollOffset;
    Pump(700);
    B := V.ScrollOffset;
  finally
    AnimationsOn := False;
  end;
  Wheel(P, 120);
  Pump(100);
  C := V.ScrollOffset;
  Check(AWhat, (B > A) and (C = A), Format('offset %d -> %d gliding (%d right after the notch), %d after a notch back at once%s',
    [A, B, Mid, C, IfThen(Shown, '', ' (Windows shows no animations here: nothing glided)')]));
end;

procedure TProbe.ScrollBarChecks(const AName: string; V: TAuControl);
var
  Sb: TAuScrollBar;
  K: Double;
  A, B, ThumbEnd, ClickY: Integer;
  P0, P1: TPoint;
begin
  Sb := ScrollBarOf(V);
  if Sb = nil then
  begin
    Check(AName + ': scroll bar', False, 'no scroll bar that can scroll');
    Exit;
  end;
  K := WindowDpi(Sb.Handle) / 96;
  if K <= 0 then K := 1;
  { a drag of the thumb (at the top: S(2), at least S(32) long) }
  Sb.Position := 0;
  Pump(200);
  A := V.ScrollOffset;
  P0 := Sb.ClientToScreen(Point(Sb.ClientWidth div 2, Round(18 * K)));
  P1 := Sb.ClientToScreen(Point(Sb.ClientWidth div 2, Round(18 * K) + Sb.ClientHeight * 2 div 5));
  if Covered(V, P0) then Check(AName + ': dragging the scroll bar thumb scrolls', False, FError)
  else
  begin
    Drag(P0, P1);
    B := V.ScrollOffset;
    Check(AName + ': dragging the scroll bar thumb scrolls', Met(A, B, EXPECT_MORE),
      Format('offset %d -> %d', [A, B]));
  end;
  { a click on the track below the thumb: one page on }
  Sb.Position := 0;
  Pump(200);
  A := V.ScrollOffset;
  ThumbEnd := Round(2 * K) + Round((Sb.ClientHeight - 4 * K) * Sb.PageSize /
    (Sb.MaxPos + Sb.PageSize));
  ClickY := Sb.ClientHeight - Round(6 * K);
  if ClickY <= ThumbEnd then
  begin
    Line('     ' + AName + ': (the thumb fills the track: no track click)');
    Exit;
  end;
  P0 := Sb.ClientToScreen(Point(Sb.ClientWidth div 2, ClickY));
  if Covered(V, P0) then Check(AName + ': a click on the scroll bar track pages', False, FError)
  else
  begin
    Click(P0);
    B := V.ScrollOffset;
    Check(AName + ': a click on the scroll bar track pages', Met(A, B, EXPECT_MORE),
      Format('offset %d -> %d', [A, B]));
  end;
  Sb.Position := 0;
  Pump(100);
end;

procedure TProbe.ViewChecks(const AName: string; V: TAuControl);
begin
  if V = nil then
  begin
    Check(AName, False, 'control not found');
    Exit;
  end;
  with V.ClientToScreen(Point(0, 0)) do
    Line(Format('     %s (%s): at %d, %d, %d x %d px', [AName, V.ClassName, X, Y, V.Width, V.Height]));
  if ScrollBarOf(V) = nil then
  begin
    Check(AName + ': can scroll', False, 'its content fits: nothing to scroll');
    Exit;
  end;
  SwipeCheck(AName + ': a swipe up scrolls down', V, 0.5, 0.8, 0.5, 0.2, EXPECT_MORE);
  if V.ScrollOffset > 0 then
    SwipeCheck(AName + ': a swipe down scrolls back', V, 0.5, 0.2, 0.5, 0.8, EXPECT_LESS);
  WheelCheck(AName + ': the mouse wheel scrolls', V);
  ScrollBarChecks(AName, V);
end;

procedure TProbe.PageSwipeCheck(const AWhat: string; V: TAuControl; ADir: Integer);
var
  A, B: Integer;
  P0, P1: TPoint;
begin
  if V = nil then
  begin
    Check(AWhat, False, 'booklet view not found');
    Exit;
  end;
  if ADir > 0 then
  begin
    P0 := At(V, 0.8, 0.5);
    P1 := At(V, 0.2, 0.5);
  end
  else
  begin
    P0 := At(V, 0.2, 0.5);
    P1 := At(V, 0.8, 0.5);
  end;
  if Covered(V, P0) then
  begin
    Check(AWhat, False, FError);
    Exit;
  end;
  A := V.ScrollOffset div PAGE_STEP;
  ResetMsgCount;
  if not Swipe(P0, P1) then
  begin
    Check(AWhat, False, FError);
    Exit;
  end;
  B := V.ScrollOffset div PAGE_STEP;
  Check(AWhat, B - A = ADir, Format('page %d -> %d; %s', [A + 1, B + 1, MsgSummary]));
end;

procedure TProbe.SplitterCheck(APane: TControl);
var
  I, A, B, C, D: Integer;
  Sp: TAuSplitter;
  K: Double;
  P0, P1: TPoint;
begin
  Sp := nil;
  if (APane <> nil) and (APane.Parent <> nil) then
    for I := 0 to APane.Parent.ControlCount - 1 do
      if (APane.Parent.Controls[I] is TAuSplitter) and (TAuSplitter(APane.Parent.Controls[I]).Target = APane) then
        Sp := TAuSplitter(APane.Parent.Controls[I]);
  if Sp = nil then
  begin
    Check('splitter: dragging resizes the pane', False, 'no splitter found');
    Exit;
  end;
  K := WindowDpi(Sp.Handle) / 96;
  if K <= 0 then K := 1;
  { 40 px: inside the limits (the playlist keeps at least 400 px) }
  D := Round(40 * K);
  P0 := Sp.ClientToScreen(Point(Sp.ClientWidth div 2, Sp.ClientHeight div 2));
  P1 := Point(P0.X + D, P0.Y);
  if Covered(Sp, P0) then
  begin
    Check('splitter: dragging resizes the pane', False, FError);
    Exit;
  end;
  A := APane.Width;
  Drag(P0, P1);
  B := APane.Width;
  { back from where the splitter is now }
  P1 := Sp.ClientToScreen(Point(Sp.ClientWidth div 2, Sp.ClientHeight div 2));
  Drag(P1, Point(P1.X - D, P1.Y));
  C := APane.Width;
  Check('splitter: dragging widens the library pane', Abs(B - A - D) <= 2,
    Format('%d -> %d px (dragged %d; limits %d .. %d)', [A, B, D, Sp.MinSize, Sp.MaxSize]));
  Check('splitter: dragging back narrows it again', Abs(C - A) <= 2, Format('%d -> %d px', [B, C]));

  { with a finger the splitter reaches further than it is drawn: 8 px
    beside it, on the pane to its right and on the one to its left }
  P0 := Sp.ClientToScreen(Point(Sp.ClientWidth + Round(8 * K), Sp.ClientHeight div 2));
  A := APane.Width;
  if not Swipe(P0, Point(P0.X + D, P0.Y)) then
  begin
    Check('splitter: a finger beside it drags it', False, FError);
    Exit;
  end;
  B := APane.Width;
  Check('splitter: a finger beside it (right) widens the pane', Abs(B - A - D) <= 3,
    Format('%d -> %d px (dragged %d); %s', [A, B, D, MsgSummary]));
  P0 := Sp.ClientToScreen(Point(-Round(8 * K), Sp.ClientHeight div 2));
  if not Swipe(P0, Point(P0.X - D, P0.Y)) then
  begin
    Check('splitter: a finger beside it drags it', False, FError);
    Exit;
  end;
  C := APane.Width;
  Check('splitter: a finger beside it (left) narrows it again', Abs(C - A) <= 3,
    Format('%d -> %d px; %s', [B, C, MsgSummary]));
  { a tap there is no drag. A short one (TAP_STEPS): a finger that rests for
    half a second and more is a press-and-hold to Windows, which opens the
    row's menu - and the click that follows would choose its first entry. }
  P0 := Sp.ClientToScreen(Point(Sp.ClientWidth + Round(8 * K), Sp.ClientHeight div 2));
  Swipe(P0, Point(P0.X + 1, P0.Y), TAP_STEPS);
  Check('splitter: a tap beside it resizes nothing', APane.Width = C, Format('%d -> %d px', [C, APane.Width]));
  { the mouse has to hit the splitter itself: a click beside it }
  Click(P0);
  Check('splitter: a mouse click beside it resizes nothing', (APane.Width = C) and not Sp.Dragging,
    Format('%d -> %d px', [C, APane.Width]));
  { further away than the reach a finger does not take it }
  P0 := Sp.ClientToScreen(Point(Sp.ClientWidth + Round(40 * K), Sp.ClientHeight div 2));
  Swipe(P0, Point(P0.X + D, P0.Y));
  Check('splitter: a finger 40 px away does not drag it', APane.Width = C, Format('%d -> %d px', [C, APane.Width]));
end;

{ The flat playlist: a finger beside the left edge of the Album column drags
  that edge (the column gets narrower by what the finger moved). }
procedure TProbe.ColumnEdgeCheck(APlaylist: TAuControl; ALibPane: TControl);
const
  WHAT = 'flat playlist: a finger beside a column edge drags it';
var
  C: TWinControl;
  Pane: TPlaylistPane;
  Head: TAuControl;
  R: TPlColRects;
  I, Idx, X0, D, W0, W1, LibW: Integer;
  Which: TPlColumn;
  K: Double;
  P0: TPoint;
begin
  C := APlaylist.Parent;
  while (C <> nil) and not (C is TPlaylistPane) do C := C.Parent;
  if C = nil then
  begin
    Check(WHAT, False, 'no playlist pane found');
    Exit;
  end;
  Pane := TPlaylistPane(C);
  { room for the columns: the library pane narrow meanwhile }
  LibW := 0;
  if ALibPane <> nil then
  begin
    LibW := ALibPane.Width;
    K := WindowDpi(Pane.Handle) / 96;
    if K <= 0 then K := 1;
    ALibPane.Width := Round(280 * K);
  end;
  Pane.SetView(gmFlat, '', '', '', False);
  Pane.Rebuild;
  Pump(700);
  try
    Head := FindOfClass(Pane, 'TPlColumnHeader');
    R := Pane.ColumnRects(Pane.List.ContentWidth);
    { the first column behind the first whose left edge can be dragged }
    Idx := -1;
    for I := High(R) downto 1 do
      if R[I].Col in [pcArtist, pcAlbum, pcAlbumArtist, pcYear, pcGenre, pcFormat] then Idx := I;
    if (Head = nil) or (Idx < 0) then
    begin
      Check(WHAT, False, Format('heading row found: %s; columns shown: %d (list %d px wide)',
        [BoolToStr(Head <> nil, True), Length(R), Pane.List.ContentWidth]));
      Exit;
    end;
    Which := R[Idx].Col;
    K := WindowDpi(Head.Handle) / 96;
    if K <= 0 then K := 1;
    D := Round(30 * K);
    X0 := Pane.List.Left + Pane.List.ContentLeft;
    W0 := R[Idx].W;
    { 9 px right of the edge: outside the reach of the mouse (5 px) }
    P0 := Head.ClientToScreen(Point(X0 + R[Idx].X + Round(9 * K), Head.ClientHeight div 2));
    if Covered(Head, P0) or not Swipe(P0, Point(P0.X + D, P0.Y)) then
    begin
      Check(WHAT, False, FError);
      Exit;
    end;
    R := Pane.ColumnRects(Pane.List.ContentWidth);
    W1 := W0;
    for I := 0 to High(R) do
      if R[I].Col = Which then W1 := R[I].W;
    { by about what the finger moved; the columns are fitted to the room, so
      not to the pixel }
    Check(WHAT, (W0 - W1 >= D div 2) and (W0 - W1 <= 2 * D),
      Format('column %d: %d -> %d px (dragged %d); %s', [Ord(Which), W0, W1, D, MsgSummary]));
    { the mouse at the same distance takes no edge }
    R := Pane.ColumnRects(Pane.List.ContentWidth);
    for I := 0 to High(R) do
      if R[I].Col = Which then Idx := I;
    P0 := Head.ClientToScreen(Point(X0 + R[Idx].X + Round(9 * K), Head.ClientHeight div 2));
    Drag(P0, Point(P0.X + D, P0.Y));
    R := Pane.ColumnRects(Pane.List.ContentWidth);
    W0 := W1;
    for I := 0 to High(R) do
      if R[I].Col = Which then W0 := R[I].W;
    Check('flat playlist: the mouse beside a column edge drags nothing', W0 = W1, Format('%d -> %d px', [W1, W0]));
  finally
    Pane.SetView(gmAlbum, '', '', '', False);
    Pane.Rebuild;
    if (ALibPane <> nil) and (LibW > 0) then ALibPane.Width := LibW;
    Pump(500);
  end;
end;

{ The help: a finger a little above the lower edge of the picture panel
  drags that edge (a pan gesture would scroll instead). }
procedure TProbe.PictureEdgeCheck(AHelp: TWinControl);
const
  WHAT = 'help: a finger on the picture''s lower edge makes the panel lower';
var
  Pic: TAuControl;
  K: Double;
  A, B, C, D: Integer;
  P0: TPoint;
begin
  Pic := FindOfClass(AHelp, 'TMdPicture');
  if (Pic = nil) or (not Pic.Visible) or (Pic.Height < 100) then
  begin
    Check(WHAT, False, 'no picture panel');
    Exit;
  end;
  K := WindowDpi(Pic.Handle) / 96;
  if K <= 0 then K := 1;
  D := Round(60 * K);
  A := Pic.Height;
  { 14 px above the edge: outside the reach of the mouse (8 px) }
  P0 := Pic.ClientToScreen(Point(Pic.ClientWidth div 4, Pic.ClientHeight - Round(14 * K)));
  if Covered(Pic, P0) or not Swipe(P0, Point(P0.X, P0.Y - D)) then
  begin
    Check(WHAT, False, FError);
    Exit;
  end;
  Pump(600);
  B := Pic.Height;
  Check(WHAT, B <= A - D div 2, Format('%d -> %d px (dragged %d up); %s', [A, B, D, MsgSummary]));
  P0 := Pic.ClientToScreen(Point(Pic.ClientWidth div 4, Pic.ClientHeight - Round(14 * K)));
  Swipe(P0, Point(P0.X, P0.Y + D));
  Pump(600);
  C := Pic.Height;
  Check('help: and dragged down it gets higher again', C >= B + D div 2, Format('%d -> %d px', [B, C]));
end;

procedure TProbe.LongMenuCheck(AMain: TCustomForm);
const
  ITEMS = 80;
var
  M: TAuMenu;
  I, A, B, MaxOffset: Integer;
  Pop: TCustomForm;
  List: TAuControl;
  WA, R: TRect;
  P: TPoint;
begin
  M := TAuMenu.Create;
  try
    for I := 1 to ITEMS do M.Add(Format('Playlist %.2d', [I]), nil);
    P := AMain.ClientToScreen(Point(S(60), S(120)));
    M.Popup(P.X, P.Y);
    Pump(700);
    Pop := nil;
    for I := 0 to Screen.CustomFormCount - 1 do
      if (Screen.CustomForms[I] is TAuPopup) and Screen.CustomForms[I].Visible then
        Pop := Screen.CustomForms[I];
    if (Pop = nil) or (Pop.ControlCount = 0) or not (Pop.Controls[0] is TAuControl) then
    begin
      Check('long menu: opens', False, 'no menu window found');
      Exit;
    end;
    List := TAuControl(Pop.Controls[0]);
    WA := Screen.MonitorFromPoint(P).WorkareaRect;
    Windows.GetWindowRect(Pop.Handle, R);
    Check('long menu: fits the screen', (R.Top >= WA.Top) and (R.Bottom <= WA.Bottom),
      Format('menu %d .. %d, work area %d .. %d', [R.Top, R.Bottom, WA.Top, WA.Bottom]));
    { 80 rows of 32 and 5 above and below (TAuMenuList) }
    MaxOffset := ITEMS * S(32) + 2 * S(5) - List.Height;
    Check('long menu: is higher than its window', MaxOffset > 0,
      Format('content %d px in %d px', [ITEMS * S(32) + 2 * S(5), List.Height]));
    A := List.ScrollOffset;
    Wheel(At(List, 0.4, 0.5), -120);
    B := List.ScrollOffset;
    Check('long menu: the wheel scrolls it', (A = 0) and (B > A), Format('offset %d -> %d', [A, B]));
    for I := 1 to (ITEMS div 3) + 4 do Wheel(At(List, 0.4, 0.5), -120);
    B := List.ScrollOffset;
    Check('long menu: the last item can be reached', B = MaxOffset,
      Format('offset %d, the end is at %d', [B, MaxOffset]));
    Wheel(At(List, 0.4, 0.5), 120);
    Check('long menu: and back up', List.ScrollOffset < B, Format('offset %d -> %d', [B, List.ScrollOffset]));
  finally
    M.Free;
    Pump(300);
  end;
end;

{ every check, in order (RunTouchProbe catches what they raise) }
procedure ProbeAll(P: TProbe; AMain: TCustomForm; APlaylist, ATree, ATiles: TAuControl;
  AShowTiles: TProbeSwitch; const APdf: string);
var
  F: TAuForm;
  B: TCustomForm;
  SL: TStringList;
  V: TAuControl;
  A, N: Integer;
begin
  P.Line('');
  P.Line('--- main window (demo playlist and library tree, 900 x 560)');
  PlaceOnTop(AMain, 900, 560);
  P.Pump(1200);
  P.ViewChecks('playlist', APlaylist);
  P.ViewChecks('library tree', ATree);
  { sideways a touch drag stays a mouse drag (drag and drop): no scrolling }
  P.SwipeCheck('library tree: a sideways drag does not scroll', ATree, 0.25, 0.5, 0.75, 0.52,
    EXPECT_SAME);
  P.GlideCheck('playlist: the wheel glides to the same place', APlaylist);
  P.GlideCheck('library tree: the wheel glides to the same place', ATree);
  P.SplitterCheck(ATree.Parent);
  P.LongMenuCheck(AMain);
  { on top again: closing the menu may have handed the foreground to
    another program }
  PlaceOnTop(AMain, 0, 0);
  P.Pump(400);
  P.ColumnEdgeCheck(APlaylist, ATree.Parent);
  PlaceOnTop(AMain, 0, 0);
  P.Pump(400);

  { the album tiles in the tree's place (made-up albums: more than fit) }
  if Assigned(AShowTiles) and (ATiles <> nil) then
  begin
    P.Line('');
    P.Line('--- main window, the library pane as album tiles');
    AShowTiles(True);
    try
      P.Pump(800);
      P.ViewChecks('album tiles', ATiles);
      P.SwipeCheck('album tiles: a sideways drag does not scroll', ATiles, 0.25, 0.5, 0.75, 0.52,
        EXPECT_SAME);
      P.GlideCheck('album tiles: the wheel glides to the same place', ATiles);
    finally
      AShowTiles(False);
      P.Pump(400);
    end;
  end;

  P.Line('');
  P.Line('--- Preferences (Output page, 900 x 420 as on a small screen: the page scrolls;');
  P.Line('    the swipes start on the settings)');
  SL := TStringList.Create;
  try
    F := CreatePrefsForm(AMain, SL, PREFS_OUTPUT);
  finally
    SL.Free;
  end;
  try
    { every page fits the dialog's own size: lower, so this one scrolls }
    F.Constraints.MinHeight := 0;
    F.Show;
    PlaceOnTop(F, 900, 420);
    P.Pump(1000);
    P.ViewChecks('Preferences page', FindScrollingBox(F));
  finally
    F.Free;
  end;
  P.Pump(300);

  P.Line('');
  P.Line('--- Help (900 x 650)');
  F := CreateHelpForm(AMain, 'Features');
  try
    F.Show;
    PlaceOnTop(F, 900, 650);
    P.Pump(1200);
    P.ViewChecks('help', FindOfClass(F, 'TMdView'));
    P.PictureEdgeCheck(F);
  finally
    F.Free;
  end;
  P.Pump(300);

  P.Line('');
  if (APdf = '') or not FileExists(APdf) then
  begin
    P.Line('--- Booklet: no PDF given (--touch-pdf=<file>)');
    Exit;
  end;
  P.Line('--- Booklet (' + ExtractFileName(APdf) + ', 900 x 650)');
  SL := TStringList.Create;
  try
    SL.Add(APdf);
    ShowBooklet(SL);
  finally
    SL.Free;
  end;
  try
    B := BookletWindow;
    if B = nil then
    begin
      P.Check('booklet', False, 'the viewer did not open');
      Exit;
    end;
    PlaceOnTop(B, 900, 650);
    P.Pump(2500);                               // the document is loaded and rendered
    V := FindOfClass(B, 'TAuPdfView');
    P.PageSwipeCheck('booklet: a swipe to the left turns one page on', V, 1);
    P.PageSwipeCheck('booklet: a swipe to the right turns one page back', V, -1);
    if V <> nil then
    begin
      A := V.ScrollOffset div PAGE_STEP;
      P.Wheel(At(V, 0.5, 0.5), -120);
      N := V.ScrollOffset div PAGE_STEP;
      P.Check('booklet: the mouse wheel turns the page', N = A + 1,
        Format('page %d -> %d', [A + 1, N + 1]));
    end;
  finally
    CloseBooklet;
  end;
end;

function RunTouchProbe(AMain: TCustomForm; APlaylist, ATree, ATiles: TAuControl;
  AShowTiles: TProbeSwitch; const APdf, AReport: string): Integer;
var
  P: TProbe;
  Cursor0: TPoint;
begin
  P := TProbe.Create;
  P.FReport := AReport;
  Cursor0 := Point(0, 0);
  GetCursorPos(Cursor0);
  try
    P.Line('Aulumic touch probe, ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    P.Line('Simulated touch (InjectTouchInput) and real mouse input (SendInput);');
    P.Line('each check compares the scroll position before and after.');
    if not Assigned(P.FInj.FInject) then P.Check('touch injection', False, P.FError);
    { an exception ends the probe as a failure (no error dialog to wait on) }
    try
      ProbeAll(P, AMain, APlaylist, ATree, ATiles, AShowTiles, APdf);
    except
      on E: Exception do P.Check('the probe', False, 'stopped by ' + E.ClassName + ': ' + E.Message);
    end;
    P.Line('');
    P.Line('failures: ' + IntToStr(P.Failures));
    Result := P.Failures;
    if (AReport <> '') and (P.FReport = '') then Result := Result + 1000;   // no report
  finally
    SetCursorPos(Cursor0.X, Cursor0.Y);
    P.Free;
  end;
end;

end.
