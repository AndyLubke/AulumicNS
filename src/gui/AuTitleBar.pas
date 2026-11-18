unit AuTitleBar;

{ ==============================================================================
  AulumicNS - AuTitleBar
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  A title bar drawn by the program instead of Windows: the icon, the window
  caption and the minimize / maximize / close buttons in the colours of the
  current theme, switching live with it.

  How it works (Win32, below the LCL):
  - The form keeps its normal window styles (resize frame, caption, system
    menu), so Windows still gives it the shadow, the rounded corners of
    Windows 11, Aero snap, the system menu (Alt+Space, right click on the
    caption) and the minimize / maximize animations.
  - WM_NCCALCSIZE of the form removes only the caption: the client area
    reaches the top edge of the window (when maximized it starts below the
    part of the frame that lies outside the screen). The left, right and
    bottom resize borders stay as Windows makes them.
  - The title bar is a child control at the top of the form. Its own
    WM_NCHITTEST answers HTCLIENT over the minimize and close buttons (they
    are handled as normal clicks) and HTTRANSPARENT elsewhere, so the form
    is asked: it answers HTCAPTION (drag, double click maximizes, snap),
    HTTOP / HTTOPLEFT / HTTOPRIGHT for the top resize edge, HTSYSMENU over
    the icon and HTMAXBUTTON over the maximize button - which makes Windows
    11 show its snap layouts there. Clicks on HTMAXBUTTON are handled here,
    so Windows never draws its own button.
  The window procedures are replaced with SetWindowLongPtr (the LCL handles
  the non-client messages in its own way) and put back at WM_NCDESTROY.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuAppIcon;

type
  { ---> AulumicNS: tbX0 .. tbX3 are the program's own buttons (AddButton):
    at the left next to the icon (the main menu of the main window) or at
    the right before minimize (its Preferences) }
  TAuTitleBtn = (tbNone, tbIcon, tbX0, tbX1, tbX2, tbX3, tbMin, tbMax, tbClose);
  TAuTitlePaintEvent = procedure(Sender: TObject; G: TGfx) of object;

  TAuTitleExtra = record
    Icon: TAuIcon;
    Hint: string;
    OnClick: TNotifyEvent;
    AtLeft: Boolean;     // next to the icon (else before minimize)
  end;

  { TAuTitleBar }

  TAuTitleBar = class(TAuControl)
  private
    FHot, FDown: TAuTitleBtn;
    FFormActive: Boolean;
    FShowMinMax, FSizeable, FShowIcon: Boolean;
    FShowMinimize: Boolean;          // ---> AulumicNS: with ShowMinMax (not for a modal dialog)
    FOnPaintBack: TAuTitlePaintEvent;
    FExtras: array of TAuTitleExtra;
    procedure SetFormActive(V: Boolean);
    function RootWnd: HWND;
    function IsExtra(B: TAuTitleBtn): Boolean;
  protected
    procedure CreateWnd; override;
    procedure DoPaint(G: TGfx); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    function ButtonRect(B: TAuTitleBtn): TRect;
    function ButtonAt(X, Y: Integer): TAuTitleBtn;
    { ---> AulumicNS: a button of the program (at most 4): before minimize,
      or with ALeft next to the icon; each side in the order added. A click
      runs AClick. The index. }
    function AddButton(AIcon: TAuIcon; const AHint: string; AClick: TNotifyEvent;
      ALeft: Boolean = False): Integer;
    { where the caption may begin and must end (between the buttons) }
    procedure CaptionSpan(out ALeft, ARight: Integer);
    { the screen rectangle of button AIndex (a menu opens below it) }
    function ButtonScreenRect(AIndex: Integer): TRect;
    { the top edge where the window can be resized (inside the title bar) }
    function ResizeBand: Integer;
    procedure SetHot(B: TAuTitleBtn);
    procedure SetDown(B: TAuTitleBtn);
    property Hot: TAuTitleBtn read FHot;
    property Down: TAuTitleBtn read FDown;
    property FormActive: Boolean read FFormActive write SetFormActive;
    property ShowMinMax: Boolean read FShowMinMax write FShowMinMax;
    { ---> AulumicNS: False shows maximize without minimize (a modal dialog:
      minimized it has no taskbar button and its owner stays disabled) }
    property ShowMinimize: Boolean read FShowMinimize write FShowMinimize;
    property Sizeable: Boolean read FSizeable write FSizeable;
    property ShowIcon: Boolean read FShowIcon write FShowIcon;
    { paints the background (e.g. the colour of the banner below it) }
    property OnPaintBack: TAuTitlePaintEvent read FOnPaintBack write FOnPaintBack;
  end;

{ replaces the window procedure of the form (after its handle exists, e.g.
  in CreateWnd) and recalculates the frame }
procedure InstallCustomFrame(Form: TCustomForm; Bar: TAuTitleBar);
{ the thickness of the resize frame of a window at its DPI }
function FrameThickness(Wnd: HWND; Vertical: Boolean): Integer;

const
  TitleBarHeight = 34;       // unscaled
  TitleButtonWidth = 46;

implementation

const
  FramePropName: PWideChar = 'AulumicNS.Frame';
  BarPropName: PWideChar = 'AulumicNS.TitleBar';
  WM_NCMOUSELEAVE_ = $02A2;
  TME_NONCLIENT_ = $00000010;

type
  PFrameInfo = ^TFrameInfo;
  TFrameInfo = record
    OldProc: WNDPROC;
    Bar: TAuTitleBar;
  end;

  TGetDpiForWindow = function(Wnd: HWND): UINT; stdcall;
  TGetSystemMetricsForDpi = function(Index: Integer; Dpi: UINT): Integer; stdcall;

var
  PGetDpiForWindow: TGetDpiForWindow = nil;
  PGetSystemMetricsForDpi: TGetSystemMetricsForDpi = nil;
  ApiLoaded: Boolean = False;

procedure LoadApi;
var
  Lib: HMODULE;
begin
  if ApiLoaded then Exit;
  ApiLoaded := True;
  Lib := GetModuleHandle('user32.dll');
  if Lib = 0 then Exit;
  PGetDpiForWindow := TGetDpiForWindow(GetProcAddress(Lib, 'GetDpiForWindow'));
  PGetSystemMetricsForDpi := TGetSystemMetricsForDpi(GetProcAddress(Lib, 'GetSystemMetricsForDpi'));
end;

function FrameThickness(Wnd: HWND; Vertical: Boolean): Integer;
const
  SM_CXPADDEDBORDER = 92;
var
  D: UINT;
  Idx: Integer;
begin
  LoadApi;
  if Vertical then Idx := SM_CYFRAME else Idx := SM_CXFRAME;
  if Assigned(PGetDpiForWindow) and Assigned(PGetSystemMetricsForDpi) then
  begin
    D := PGetDpiForWindow(Wnd);
    if D < 48 then D := 96;
    Result := PGetSystemMetricsForDpi(Idx, D) + PGetSystemMetricsForDpi(SM_CXPADDEDBORDER, D);
  end
  else
    Result := GetSystemMetrics(Idx) + GetSystemMetrics(SM_CXPADDEDBORDER);
end;

function PointFromLParam(LP: LPARAM): TPoint;
begin
  Result.X := SmallInt(LP and $FFFF);
  Result.Y := SmallInt((LP shr 16) and $FFFF);
end;

{ ---- the window procedure of the form ---- }

function FrameProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  Info: PFrameInfo;
  NC: PNCCalcSizeParams;
  OrigTop, Band, Corner, W: Integer;
  P: TPoint;
  R: TRect;
  Bar: TAuTitleBar;
  TME: TTrackMouseEvent;
  Old: WNDPROC;
begin
  Info := PFrameInfo(GetPropW(Wnd, FramePropName));
  if Info = nil then Exit(DefWindowProcW(Wnd, Msg, WP, LP));
  Bar := Info^.Bar;
  case Msg of
    WM_NCCALCSIZE:
      if WP <> 0 then
      begin
        NC := PNCCalcSizeParams(LP);
        OrigTop := NC^.rgrc[0].Top;
        Result := CallWindowProcW(Info^.OldProc, Wnd, Msg, WP, LP);
        { no caption: the client area starts at the top of the window; a
          maximized window lies partly outside the screen by its frame }
        NC^.rgrc[0].Top := OrigTop;
        if IsZoomed(Wnd) then Inc(NC^.rgrc[0].Top, FrameThickness(Wnd, True));
        Exit;
      end;
    WM_NCHITTEST:
      begin
        Result := CallWindowProcW(Info^.OldProc, Wnd, Msg, WP, LP);
        if Result <> HTCLIENT then Exit;          // left, right and bottom borders
        P := PointFromLParam(LP);
        Windows.ScreenToClient(Wnd, P);
        Windows.GetClientRect(Wnd, R);
        W := R.Right - R.Left;
        if (Bar <> nil) and Bar.Sizeable and not IsZoomed(Wnd) then
        begin
          Band := Bar.ResizeBand;
          Corner := FrameThickness(Wnd, False) * 2;
          if (P.Y >= 0) and (P.Y < Band) then
          begin
            if P.X < Corner then Exit(HTTOPLEFT);
            if P.X >= W - Corner then Exit(HTTOPRIGHT);
            Exit(HTTOP);
          end;
        end;
        if (Bar <> nil) and Bar.Visible and (P.Y >= Bar.Top) and (P.Y < Bar.Top + Bar.Height) then
        begin
          case Bar.ButtonAt(P.X - Bar.Left, P.Y - Bar.Top) of
            tbMax: Exit(HTMAXBUTTON);
            tbIcon: Exit(HTSYSMENU);
            tbX0..tbX3, tbMin, tbClose: Exit(HTCLIENT);
          else
            Exit(HTCAPTION);
          end;
        end;
        Exit;
      end;
    WM_NCMOUSEMOVE:
      if Bar <> nil then
      begin
        if WP = HTMAXBUTTON then
        begin
          Bar.SetHot(tbMax);
          FillChar(TME, SizeOf(TME), 0);
          TME.cbSize := SizeOf(TME);
          TME.dwFlags := TME_LEAVE or TME_NONCLIENT_;
          TME.hwndTrack := Wnd;
          TrackMouseEvent(TME);
        end
        else if Bar.Hot = tbMax then
          Bar.SetHot(tbNone);
      end;
    WM_NCMOUSELEAVE_:
      if Bar <> nil then
      begin
        if Bar.Hot = tbMax then Bar.SetHot(tbNone);
        if Bar.Down = tbMax then Bar.SetDown(tbNone);
      end;
    WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK:
      if (WP = HTMAXBUTTON) and (Bar <> nil) then
      begin
        { handled here: Windows would draw its own (old style) button }
        Bar.SetDown(tbMax);
        Exit(0);
      end;
    WM_NCLBUTTONUP:
      if (WP = HTMAXBUTTON) and (Bar <> nil) then
      begin
        if Bar.Down = tbMax then
        begin
          if IsZoomed(Wnd) then PostMessageW(Wnd, WM_SYSCOMMAND, SC_RESTORE, 0)
          else PostMessageW(Wnd, WM_SYSCOMMAND, SC_MAXIMIZE, 0);
        end;
        Bar.SetDown(tbNone);
        Exit(0);
      end
      else if Bar <> nil then
        Bar.SetDown(tbNone);
    WM_NCACTIVATE:
      if Bar <> nil then Bar.FormActive := WP <> 0;
    WM_SIZE:
      if Bar <> nil then Bar.Invalidate;      // maximize / restore glyph
    WM_NCDESTROY:
      begin
        Old := Info^.OldProc;
        SetWindowLongPtrW(Wnd, GWLP_WNDPROC, LONG_PTR(Pointer(Old)));
        RemovePropW(Wnd, FramePropName);
        Dispose(Info);
        Exit(CallWindowProcW(Old, Wnd, Msg, WP, LP));
      end;
  end;
  Result := CallWindowProcW(Info^.OldProc, Wnd, Msg, WP, LP);
end;

procedure InstallCustomFrame(Form: TCustomForm; Bar: TAuTitleBar);
var
  Info: PFrameInfo;
  Wnd: HWND;
begin
  if (Form = nil) or not Form.HandleAllocated then Exit;
  Wnd := Form.Handle;
  if GetPropW(Wnd, FramePropName) <> 0 then Exit;   // already installed
  New(Info);
  Info^.Bar := Bar;
  Info^.OldProc := WNDPROC(GetWindowLongPtrW(Wnd, GWLP_WNDPROC));
  SetPropW(Wnd, FramePropName, THandle(Info));
  SetWindowLongPtrW(Wnd, GWLP_WNDPROC, LONG_PTR(@FrameProc));
  { the frame is calculated again with the new WM_NCCALCSIZE }
  SetWindowPos(Wnd, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
end;

{ ---- the window procedure of the title bar control ---- }

function BarProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  Info: PFrameInfo;
  P: TPoint;
  Old: WNDPROC;
  Bar: TAuTitleBar;
begin
  Info := PFrameInfo(GetPropW(Wnd, BarPropName));
  if Info = nil then Exit(DefWindowProcW(Wnd, Msg, WP, LP));
  case Msg of
    WM_NCHITTEST:
      begin
        Bar := Info^.Bar;
        P := PointFromLParam(LP);
        Windows.ScreenToClient(Wnd, P);
        { the top resize edge and everything but minimize / close belong to
          the form (caption, maximize with snap layouts, the icon) }
        if Bar.Sizeable and not IsZoomed(GetAncestor(Wnd, GA_ROOT)) and (P.Y < Bar.ResizeBand) then
          Exit(HTTRANSPARENT);
        if Bar.ButtonAt(P.X, P.Y) in [tbX0..tbX3, tbMin, tbClose] then Exit(HTCLIENT);
        Exit(HTTRANSPARENT);
      end;
    WM_NCDESTROY:
      begin
        Old := Info^.OldProc;
        SetWindowLongPtrW(Wnd, GWLP_WNDPROC, LONG_PTR(Pointer(Old)));
        RemovePropW(Wnd, BarPropName);
        Dispose(Info);
        Exit(CallWindowProcW(Old, Wnd, Msg, WP, LP));
      end;
  end;
  Result := CallWindowProcW(Info^.OldProc, Wnd, Msg, WP, LP);
end;

{ ---- TAuTitleBar ---- }

constructor TAuTitleBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FocusOnClick := False;
  TabStop := False;
  BackRole := crPanel;
  FFormActive := True;
  FShowMinMax := True;
  FShowMinimize := True;
  FSizeable := True;
  FShowIcon := True;
  Height := S(TitleBarHeight);
  Align := alTop;
  ShowHint := True;
end;

procedure TAuTitleBar.CreateWnd;
var
  Info: PFrameInfo;
begin
  inherited CreateWnd;
  if GetPropW(Handle, BarPropName) <> 0 then Exit;
  New(Info);
  Info^.Bar := Self;
  Info^.OldProc := Windows.WNDPROC(GetWindowLongPtrW(Handle, GWLP_WNDPROC));
  SetPropW(Handle, BarPropName, THandle(Info));
  SetWindowLongPtrW(Handle, GWLP_WNDPROC, LONG_PTR(@BarProc));
end;

function TAuTitleBar.RootWnd: HWND;
begin
  if HandleAllocated then Result := GetAncestor(Handle, GA_ROOT) else Result := 0;
end;

procedure TAuTitleBar.SetFormActive(V: Boolean);
begin
  if V = FFormActive then Exit;
  FFormActive := V;
  Invalidate;
end;

function TAuTitleBar.ResizeBand: Integer;
begin
  Result := Math.Max(S(4), Round(S(TitleBarHeight) * 0.15));
end;

function TAuTitleBar.IsExtra(B: TAuTitleBtn): Boolean;
begin
  Result := (B >= tbX0) and (B <= tbX3) and (Ord(B) - Ord(tbX0) < Length(FExtras));
end;

function TAuTitleBar.AddButton(AIcon: TAuIcon; const AHint: string; AClick: TNotifyEvent;
  ALeft: Boolean): Integer;
begin
  Result := Length(FExtras);
  if Result > Ord(tbX3) - Ord(tbX0) then Exit(-1);
  SetLength(FExtras, Result + 1);
  FExtras[Result].Icon := AIcon;
  FExtras[Result].Hint := AHint;
  FExtras[Result].OnClick := AClick;
  FExtras[Result].AtLeft := ALeft;
  Invalidate;
end;

procedure TAuTitleBar.CaptionSpan(out ALeft, ARight: Integer);
var
  I: Integer;
  R: TRect;
begin
  ALeft := S(12);
  if FShowIcon then ALeft := ALeft + S(18) + S(10);
  R := ButtonRect(tbMin);
  if R.Right <= R.Left then R := ButtonRect(tbMax);
  if R.Right <= R.Left then R := ButtonRect(tbClose);
  ARight := R.Left;
  for I := 0 to High(FExtras) do
  begin
    R := ButtonRect(TAuTitleBtn(Ord(tbX0) + I));
    if FExtras[I].AtLeft then
    begin
      if R.Right + S(8) > ALeft then ALeft := R.Right + S(8);
    end
    else if R.Left < ARight then ARight := R.Left;
  end;
end;

function TAuTitleBar.ButtonScreenRect(AIndex: Integer): TRect;
var
  R: TRect;
begin
  Result := Rect(0, 0, 0, 0);
  if (AIndex < 0) or (AIndex >= Length(FExtras)) then Exit;
  R := ButtonRect(TAuTitleBtn(Ord(tbX0) + AIndex));
  Result.TopLeft := ClientToScreen(R.TopLeft);
  Result.BottomRight := ClientToScreen(R.BottomRight);
end;

function TAuTitleBar.ButtonRect(B: TAuTitleBtn): TRect;
var
  BW, RightX, LeftX, EW, I, K, Before, After: Integer;
begin
  BW := S(TitleButtonWidth);
  if IsExtra(B) then
  begin
    EW := S(42);
    I := Ord(B) - Ord(tbX0);
    { the buttons of its side before and after it }
    Before := 0;
    After := 0;
    for K := 0 to High(FExtras) do
      if FExtras[K].AtLeft = FExtras[I].AtLeft then
      begin
        if K < I then Inc(Before)
        else if K > I then Inc(After);
      end;
    if FExtras[I].AtLeft then
    begin
      { after the icon (or at the left edge) }
      if FShowIcon then LeftX := S(6) + Height + S(2) else LeftX := S(6);
      Result := Rect(LeftX + Before * EW, 0, LeftX + (Before + 1) * EW, Height);
    end
    else
    begin
      { right-aligned before minimize (or maximize, or close), a small gap between }
      if FShowMinMax and FShowMinimize then RightX := Width - 3 * BW
      else if FShowMinMax then RightX := Width - 2 * BW
      else RightX := Width - BW;
      Dec(RightX, S(6));
      Result := Rect(RightX - (After + 1) * EW, 0, RightX - After * EW, Height);
    end;
    Exit;
  end;
  case B of
    tbClose: Result := Rect(Width - BW, 0, Width, Height);
    tbMax: if FShowMinMax then Result := Rect(Width - 2 * BW, 0, Width - BW, Height) else Result := Rect(0, 0, 0, 0);
    tbMin: if FShowMinMax and FShowMinimize then Result := Rect(Width - 3 * BW, 0, Width - 2 * BW, Height)
           else Result := Rect(0, 0, 0, 0);
    tbIcon: if FShowIcon then Result := Rect(S(6), 0, S(6) + Height, Height) else Result := Rect(0, 0, 0, 0);
  else
    Result := Rect(0, 0, 0, 0);
  end;
end;

function TAuTitleBar.ButtonAt(X, Y: Integer): TAuTitleBtn;
var
  B: TAuTitleBtn;
begin
  for B := tbIcon to tbClose do
    if PtInRect(ButtonRect(B), Point(X, Y)) then Exit(B);
  Result := tbNone;
end;

procedure TAuTitleBar.SetHot(B: TAuTitleBtn);
begin
  if B = FHot then Exit;
  FHot := B;
  Invalidate;
end;

procedure TAuTitleBar.SetDown(B: TAuTitleBtn);
begin
  if B = FDown then Exit;
  FDown := B;
  Invalidate;
end;

procedure TAuTitleBar.DoPaint(G: TGfx);
var
  B: TAuTitleBtn;
  R: TRect;
  Bg, Fg, TextC: TARGB;
  CX, CY, U, LW: Single;
  CapL, CapR, CapAvail, CapW: Integer;
  Zoomed: Boolean;
  F: TCustomForm;
  Cap: string;
begin
  if Assigned(FOnPaintBack) then FOnPaintBack(Self, G)
  else G.FillRect(0, 0, Width, Height, EffBack);
  if FFormActive then TextC := clTextDim else TextC := clTextFaint;
  { icon and caption }
  if FShowIcon then
    DrawAppLogo(G, S(12), (Height - S(18)) / 2, S(18), True);
  F := GetParentForm(Self);
  if F <> nil then Cap := F.Caption else Cap := '';
  CaptionSpan(CapL, CapR);
  { the caption in the middle of the window; next to what stands at its
    sides when that leaves no room there, and cut off when it is too long }
  CapAvail := Math.Max(0, CapR - CapL - S(8));
  CapW := Ceil(TextWidth(Cap, UIFont(12))) + S(2);
  if CapW < CapAvail then
    CapL := Math.Max(CapL, Math.Min((Width - CapW) div 2, CapL + CapAvail - CapW));
  G.Text(Cap, CapL, 0, Math.Max(0, CapR - CapL - S(8)), Height, UIFont(12), TextC, 0, 1);
  { ---> AulumicNS: the program's buttons }
  for B := tbX0 to tbX3 do
  begin
    if not IsExtra(B) then Break;
    R := ButtonRect(B);
    if FDown = B then G.FillRect(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, WithAlpha(clText, 36))
    else if FHot = B then G.FillRect(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, WithAlpha(clText, 22));
    if FFormActive then Fg := clText else Fg := clTextFaint;
    DrawIcon(G, FExtras[Ord(B) - Ord(tbX0)].Icon, (R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2, S(16), Fg);
  end;
  { the buttons }
  Zoomed := (RootWnd <> 0) and IsZoomed(RootWnd);
  U := UIScale;
  LW := Math.Max(1, Round(U));
  for B := tbMin to tbClose do
  begin
    R := ButtonRect(B);
    if R.Right <= R.Left then Continue;
    Bg := 0;
    if FFormActive then Fg := clText else Fg := clTextFaint;
    if B = tbClose then
    begin
      if FDown = B then Bg := $FFB3271A
      else if FHot = B then Bg := $FFC42B1C;
      if Bg <> 0 then Fg := $FFFFFFFF;
    end
    else
    begin
      if FDown = B then Bg := WithAlpha(clText, 36)
      else if FHot = B then Bg := WithAlpha(clText, 22);
      if Bg <> 0 then Fg := clText;
    end;
    if Bg <> 0 then G.FillRect(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, Bg);
    { glyphs on whole pixels (+ half a line) so that the thin lines stay sharp }
    CX := Round((R.Left + R.Right) / 2) + LW / 2;
    CY := Round((R.Top + R.Bottom) / 2) + LW / 2;
    case B of
      tbMin: G.Line(CX - Round(5 * U), CY, CX + Round(5 * U), CY, LW, Fg);
      tbMax:
        if Zoomed then
        begin
          { restore: a square with a second one behind it }
          G.StrokeRound(CX - Round(5 * U), CY - Round(3 * U), Round(8 * U), Round(8 * U), SF(1.2), LW, Fg);
          G.Line(CX - Round(3 * U), CY - Round(5 * U), CX + Round(3 * U), CY - Round(5 * U), LW, Fg);
          G.Line(CX + Round(5 * U), CY - Round(3 * U), CX + Round(5 * U), CY + Round(3 * U), LW, Fg);
          G.Arc(CX + Round(3 * U), CY - Round(3 * U), Round(2 * U), 270, 90, LW, Fg);
        end
        else
          G.StrokeRound(CX - Round(5 * U), CY - Round(5 * U), Round(10 * U), Round(10 * U), SF(1.5), LW, Fg);
      tbClose:
        begin
          G.Line(CX - Round(5 * U), CY - Round(5 * U), CX + Round(5 * U), CY + Round(5 * U), LW, Fg);
          G.Line(CX + Round(5 * U), CY - Round(5 * U), CX - Round(5 * U), CY + Round(5 * U), LW, Fg);
        end;
    end;
  end;
end;

procedure TAuTitleBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  B: TAuTitleBtn;
begin
  inherited MouseMove(Shift, X, Y);
  B := ButtonAt(X, Y);
  if not (IsExtra(B) or (B in [tbMin, tbClose])) then B := tbNone;
  SetHot(B);
  case B of
    tbMin: Hint := 'Minimize';
    tbClose: Hint := 'Close';
  else
    if IsExtra(B) then Hint := FExtras[Ord(B) - Ord(tbX0)].Hint else Hint := '';
  end;
end;

procedure TAuTitleBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  B: TAuTitleBtn;
begin
  inherited MouseDown(Button, Shift, X, Y);
  B := ButtonAt(X, Y);
  if (Button = mbLeft) and (IsExtra(B) or (B in [tbMin, tbClose])) then SetDown(B);
end;

procedure TAuTitleBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  B, D: TAuTitleBtn;
begin
  inherited MouseUp(Button, Shift, X, Y);
  D := FDown;
  SetDown(tbNone);
  if Button <> mbLeft then Exit;
  B := ButtonAt(X, Y);
  if (B <> D) or (RootWnd = 0) then Exit;
  case B of
    tbMin: PostMessageW(RootWnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
    tbClose: PostMessageW(RootWnd, WM_SYSCOMMAND, SC_CLOSE, 0);
  else
    if IsExtra(B) and Assigned(FExtras[Ord(B) - Ord(tbX0)].OnClick) then
    begin
      SetHot(tbNone);
      FExtras[Ord(B) - Ord(tbX0)].OnClick(Self);
    end;
  end;
end;

procedure TAuTitleBar.MouseLeave;
begin
  inherited MouseLeave;
  if IsExtra(FHot) or (FHot in [tbMin, tbClose]) then SetHot(tbNone);
  if IsExtra(FDown) or (FDown in [tbMin, tbClose]) then SetDown(tbNone);
end;

end.
