unit AuMenus;

{ ==============================================================================
  AulumicNS - AuMenus
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Themed popup / context menus with icons, check marks, shortcuts and sub
  menus. Fully keyboard operable (arrows, Enter, Escape, Left / Right).
  A menu that is higher than the screen has room
  for is as high as fits and scrolls (scroll bar, mouse wheel, touch, the
  arrow keys, Home / End, Page Up / Down), so that with many playlists the
  lower ones can be reached.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls;

type
  TAuMenu = class;

  TAuMenuItem = class
  public
    Caption, ShortCut: string;
    Icon: TAuIcon;
    OnClick: TNotifyEvent;
    Enabled, Checked, Separator: Boolean;
    Tag: PtrInt;
    SubMenu: TAuMenu;
    constructor Create;
    destructor Destroy; override;
  end;

  TAuMenu = class
  private
    FItems: TList;
    FLastClose: QWord;
    FPopup: TAuPopup;
    procedure PopupClosed(Sender: TObject);
  public
    OnPopup: TNotifyEvent;
    { the popup is at least this wide (a drop-down under a wide button) }
    MinWidth: Integer;
    constructor Create;
    destructor Destroy; override;
    function Add(const ACaption: string; AClick: TNotifyEvent; AIcon: TAuIcon = icNone;
      const AShortCut: string = ''; ATag: PtrInt = 0): TAuMenuItem;
    function AddSub(const ACaption: string; AIcon: TAuIcon = icNone): TAuMenu;
    procedure AddSeparator;
    procedure Clear;
    function Count: Integer;
    function Item(I: Integer): TAuMenuItem;
    procedure Popup(X, Y: Integer);
    procedure PopupAtCursor;
    procedure PopupBelow(C: TControl; AlignRight: Boolean = False);
    function IsOpen: Boolean;
  end;

implementation

type
  TAuMenuPopup = class;

  { TAuMenuList }

  TAuMenuList = class(TAuControl)
  private
    FMenu: TAuMenu;
    FHoverIdx: Integer;
    FHot: TAuHotFade;                  // the highlight fading from item to item
    FSubTimer: TTimer;
    FPopup: TAuMenuPopup;
    // a button was pressed inside this list (MouseDown); only
    // then does its release choose an item. A menu opened on a right press
    // (the library tree, the playlist) gets that press's release: near the
    // bottom of the screen the menu opens upwards and its last item lies
    // under the cursor - it would be run at once.
    FPressInList: Boolean;
    // a menu too high for the screen scrolls (pixels)
    FScroll: TAuScrollBar;
    FOffset: Integer;
    procedure ScrollChanged(Sender: TObject);
    procedure EnsureVisible(I: Integer);
    function ItemH(I: Integer): Integer;
    function ItemTop(I: Integer): Integer;
    function ItemAt(Y: Integer): Integer;
    procedure SubTimer(Sender: TObject);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Resize; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    function ContentHeight: Integer;
    function ContentWidth: Integer;
    function PanBy(DX, DY: Integer): Boolean; override;
    function ScrollOffset: Integer; override;
    procedure MoveHover(D: Integer);
    { the next entry that can be chosen and begins with this letter or digit;
      False: none }
    function HoverLetter(ACh: Char): Boolean;
    { the first (ALast: the last) item that can be chosen, or a page up / down }
    procedure HoverEnd(ALast: Boolean);
    procedure HoverPage(ADown: Boolean);
    procedure Activate(I: Integer; ByKey: Boolean);
    procedure OpenSub(I: Integer; ByKey: Boolean);
  end;

  { TAuMenuPopup }

  TAuMenuPopup = class(TAuPopup)
  private
    FList: TAuMenuList;
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor CreateMenu(AMenu: TAuMenu; AParent: TAuMenuPopup);
  end;

  { runs the picked item after the popup chain is gone }
  TMenuRunner = class
  public
    Pending: TAuMenuItem;
    procedure Run(Data: PtrInt);
  end;

var
  Runner: TMenuRunner = nil;

procedure TMenuRunner.Run(Data: PtrInt);
var
  It: TAuMenuItem;
begin
  It := Pending;
  Pending := nil;
  if (It <> nil) and It.Enabled and Assigned(It.OnClick) then It.OnClick(It);
end;

{ ---- TAuMenuItem ---- }

constructor TAuMenuItem.Create;
begin
  inherited Create;
  Enabled := True;
end;

destructor TAuMenuItem.Destroy;
begin
  SubMenu.Free;
  inherited Destroy;
end;

{ ---- TAuMenu ---- }

constructor TAuMenu.Create;
begin
  inherited Create;
  FItems := TList.Create;
end;

destructor TAuMenu.Destroy;
begin
  if FPopup <> nil then
  begin
    FPopup.OnClosed := nil;
    FPopup.CloseTree;
  end;
  Clear;
  FItems.Free;
  inherited Destroy;
end;

procedure TAuMenu.Clear;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do TAuMenuItem(FItems[I]).Free;
  FItems.Clear;
end;

function TAuMenu.Count: Integer;
begin
  Result := FItems.Count;
end;

function TAuMenu.Item(I: Integer): TAuMenuItem;
begin
  Result := TAuMenuItem(FItems[I]);
end;

function TAuMenu.Add(const ACaption: string; AClick: TNotifyEvent; AIcon: TAuIcon;
  const AShortCut: string; ATag: PtrInt): TAuMenuItem;
begin
  Result := TAuMenuItem.Create;
  Result.Caption := ACaption;
  Result.ShortCut := AShortCut;
  Result.OnClick := AClick;
  Result.Icon := AIcon;
  Result.Tag := ATag;
  FItems.Add(Result);
end;

function TAuMenu.AddSub(const ACaption: string; AIcon: TAuIcon): TAuMenu;
var
  It: TAuMenuItem;
begin
  It := Add(ACaption, nil, AIcon);
  It.SubMenu := TAuMenu.Create;
  Result := It.SubMenu;
end;

procedure TAuMenu.AddSeparator;
var
  M: TAuMenuItem;
begin
  M := TAuMenuItem.Create;
  M.Separator := True;
  FItems.Add(M);
end;

function TAuMenu.IsOpen: Boolean;
begin
  Result := FPopup <> nil;
end;

procedure TAuMenu.PopupClosed(Sender: TObject);
begin
  FPopup := nil;
  FLastClose := GetTickCount64;
end;

{ the height a menu of AHeight gets at Y: all of it where it
  fits below Y or (AAboveY >= 0) above AAboveY - TAuPopup.ShowAt then puts
  it there -, else what the larger of the two has room for; the list scrolls.
  AAboveY < 0: the menu may be moved up, so the whole work area counts. }
function MenuHeightAt(X, Y, AHeight, AAboveY: Integer): Integer;
var
  WA: TRect;
  Below, Above, Edge: Integer;
begin
  WA := Screen.MonitorFromPoint(Point(X, Y)).WorkareaRect;
  Edge := S(8);
  Below := WA.Bottom - Y - Edge;
  if AAboveY >= 0 then Above := AAboveY - WA.Top - Edge
  else Above := WA.Bottom - WA.Top - 2 * Edge;
  if (AHeight <= Below) or (AHeight <= Above) then Exit(AHeight);
  if AAboveY < 0 then Result := Above
  else if Below >= Above then Result := Below
  else Result := Above;
  if Result < S(120) then Result := S(120);
end;

procedure TAuMenu.Popup(X, Y: Integer);
var
  P: TAuMenuPopup;
  H, Edge: Integer;
  WA: TRect;
begin
  if FPopup <> nil then
  begin
    FPopup.CloseTree;
    Exit;
  end;
  if GetTickCount64 - FLastClose < 250 then Exit;   // the click that closed it
  if Assigned(OnPopup) then OnPopup(Self);
  if FItems.Count = 0 then Exit;
  P := TAuMenuPopup.CreateMenu(Self, nil);
  P.OnClosed := @PopupClosed;
  FPopup := P;
  { below the point where it fits there, else above it where
    it fits there. A menu that is too high for either side but not for the
    screen is moved up as far as needed (it then lies over the point, as a
    Windows menu does). Only a menu higher than the screen scrolls. }
  H := P.FList.ContentHeight;
  WA := Screen.MonitorFromPoint(Point(X, Y)).WorkareaRect;
  Edge := S(8);
  if (H <= WA.Bottom - Y - Edge) or (H <= Y - WA.Top - Edge) then
    P.ShowAt(X, Y, P.FList.ContentWidth, H, Y)
  else
    P.ShowAt(X, Y, P.FList.ContentWidth, MenuHeightAt(X, Y, H, -1), -1);
  if KeyboardCues then P.FList.MoveHover(1);
end;

procedure TAuMenu.PopupAtCursor;
var
  Pt: TPoint;
begin
  GetCursorPos(Pt);
  Popup(Pt.X, Pt.Y);
end;

procedure TAuMenu.PopupBelow(C: TControl; AlignRight: Boolean);
var
  P: TPoint;
  W: Integer;
  Tmp: TAuMenuPopup;
begin
  if FPopup <> nil then
  begin
    FPopup.CloseTree;
    Exit;
  end;
  if GetTickCount64 - FLastClose < 250 then Exit;
  if Assigned(OnPopup) then OnPopup(Self);
  if FItems.Count = 0 then Exit;
  Tmp := TAuMenuPopup.CreateMenu(Self, nil);
  Tmp.OnClosed := @PopupClosed;
  FPopup := Tmp;
  W := Max(Tmp.FList.ContentWidth, MinWidth);
  if AlignRight then P := C.ClientToScreen(Point(C.Width - W, C.Height + S(4)))
  else P := C.ClientToScreen(Point(0, C.Height + S(4)));
  Tmp.ShowAt(P.X, P.Y, W, MenuHeightAt(P.X, P.Y, Tmp.FList.ContentHeight, P.Y - C.Height - S(8)),
    P.Y - C.Height - S(8));
  if KeyboardCues then Tmp.FList.MoveHover(1);
end;

{ ---- TAuMenuList ---- }

constructor TAuMenuList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHoverIdx := -1;
  BackRole := crCard;
  FSubTimer := TTimer.Create(Self);
  FSubTimer.Enabled := False;
  FSubTimer.Interval := 280;
  FSubTimer.OnTimer := @SubTimer;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Visible := False;
  FScroll.OnScroll := @ScrollChanged;
end;

procedure TAuMenuList.Resize;
begin
  inherited Resize;
  if (FMenu = nil) or (FScroll = nil) then Exit;
  FScroll.SetBounds(Width - S(12), S(4), S(12), Height - S(8));
  FScroll.SetParams(ContentHeight, Height);
  FScroll.SmallStep := S(32);
  FScroll.Visible := FScroll.NeedScroll;
  FOffset := FScroll.Position;
end;

procedure TAuMenuList.ScrollChanged(Sender: TObject);
begin
  if FOffset = FScroll.Position then Exit;
  FOffset := FScroll.Position;
  { the row under the pointer is another one now; a sub menu would hang
    beside the wrong row }
  FHoverIdx := -1;
  if (FPopup <> nil) and (FPopup.ChildPopup <> nil) then FPopup.ChildPopup.CloseTree;
  Invalidate;
end;

function TAuMenuList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if FScroll.Visible then
    FScroll.WheelBy(-Sign(WheelDelta) * 3 * S(32));
  Result := True;
end;

function TAuMenuList.PanBy(DX, DY: Integer): Boolean;
begin
  if not FScroll.Visible then Exit(inherited PanBy(DX, DY));
  if DY <> 0 then FScroll.Position := FScroll.Position - DY;
  Result := True;
end;

function TAuMenuList.ScrollOffset: Integer;
begin
  Result := FOffset;
end;

procedure TAuMenuList.EnsureVisible(I: Integer);
var
  T: Integer;
begin
  if (I < 0) or not FScroll.Visible then Exit;
  T := ItemTop(I);
  if T - S(5) < FOffset then FScroll.Position := T - S(5)
  else if T + ItemH(I) + S(5) > FOffset + Height then FScroll.Position := T + ItemH(I) + S(5) - Height;
  FOffset := FScroll.Position;
end;

procedure TAuMenuList.HoverEnd(ALast: Boolean);
begin
  { MoveHover steps from the hovered row and wraps around }
  if ALast then
  begin
    FHoverIdx := 0;
    MoveHover(-1);
  end
  else
  begin
    FHoverIdx := FMenu.Count - 1;
    MoveHover(1);
  end;
end;

procedure TAuMenuList.HoverPage(ADown: Boolean);
var
  I, N, Target, Rows: Integer;
begin
  N := FMenu.Count;
  if N = 0 then Exit;
  Rows := Math.Max(1, Height div S(32) - 1);
  I := FHoverIdx;
  if I < 0 then I := 0;
  if ADown then Target := Math.Min(N - 1, I + Rows) else Target := Math.Max(0, I - Rows);
  { the nearest row that can be chosen, towards the end that was asked for }
  while (Target >= 0) and (Target < N) and
        (FMenu.Item(Target).Separator or not FMenu.Item(Target).Enabled) do
    if ADown then Inc(Target) else Dec(Target);
  if (Target < 0) or (Target >= N) then
  begin
    HoverEnd(ADown);
    Exit;
  end;
  FHoverIdx := Target;
  EnsureVisible(Target);
  Invalidate;
end;

function TAuMenuList.ItemH(I: Integer): Integer;
begin
  if FMenu.Item(I).Separator then Result := S(9) else Result := S(32);
end;

function TAuMenuList.ItemTop(I: Integer): Integer;
var
  J: Integer;
begin
  Result := S(5);
  for J := 0 to I - 1 do Inc(Result, ItemH(J));
end;

function TAuMenuList.ContentHeight: Integer;
begin
  Result := ItemTop(FMenu.Count) + S(5);
end;

function TAuMenuList.ContentWidth: Integer;
var
  I: Integer;
  W, SW: Single;
  It: TAuMenuItem;
begin
  W := 0; SW := 0;
  for I := 0 to FMenu.Count - 1 do
  begin
    It := FMenu.Item(I);
    if It.Separator then Continue;
    W := Math.Max(W, TextWidth(It.Caption, UIFont(13)));
    if It.ShortCut <> '' then SW := Math.Max(SW, TextWidth(It.ShortCut, UIFont(12)) + S(24));
    if It.SubMenu <> nil then SW := Math.Max(SW, S(24));
  end;
  { 40 icon column + 40 right margin (matches the text area in DoPaint) }
  Result := Ceil(W + SW) + S(40 + 44);
  if Result < S(200) then Result := S(200);
end;

function TAuMenuList.ItemAt(Y: Integer): Integer;
var
  I, T: Integer;
begin
  T := S(5) - FOffset;
  for I := 0 to FMenu.Count - 1 do
  begin
    if (Y >= T) and (Y < T + ItemH(I)) then
    begin
      if FMenu.Item(I).Separator then Exit(-1);
      Exit(I);
    end;
    Inc(T, ItemH(I));
  end;
  Result := -1;
end;

procedure TAuMenuList.DoPaint(G: TGfx);
var
  I, T, H: Integer;
  It: TAuMenuItem;
  C: TARGB;
  Open: Boolean;
  W: Integer;
begin
  G.FillRect(0, 0, Width, Height, clCard);
  HotSet(FHot, FHoverIdx, Self);
  { scrolled by FOffset; the scroll bar takes its strip }
  W := Width;
  if FScroll.Visible then Dec(W, FScroll.Width);
  T := S(5) - FOffset;
  for I := 0 to FMenu.Count - 1 do
  begin
    It := FMenu.Item(I);
    H := ItemH(I);
    if (T + H <= 0) or (T >= Height) then
    begin
      Inc(T, H);
      Continue;
    end;
    if It.Separator then
      G.FillRect(S(12), T + H div 2, W - S(24), 1, clBorder)
    else
    begin
      Open := (FPopup.ChildPopup <> nil) and (It.SubMenu <> nil) and
        (TAuMenuPopup(FPopup.ChildPopup).FList.FMenu = It.SubMenu);
      if Open and It.Enabled then G.FillRound(S(5), T, W - S(10), H, S(6), clHover)
      else if It.Enabled and (HotLevel(FHot, I) > 0) then
        G.FillRound(S(5), T, W - S(10), H, S(6), Blend(clCard, clHover, HotLevel(FHot, I)));
      if It.Enabled then C := clText else C := clTextFaint;
      if It.Checked then DrawIcon(G, icCheck, S(22), T + H / 2, S(14), clAccentText)
      else if It.Icon <> icNone then
      begin
        if It.Enabled then DrawIcon(G, It.Icon, S(22), T + H / 2, S(15), clTextDim)
        else DrawIcon(G, It.Icon, S(22), T + H / 2, S(15), clTextFaint);
      end;
      G.Text(It.Caption, S(40), T, W - S(80), H, UIFont(13), C, 0, 1);
      if It.ShortCut <> '' then
        G.Text(It.ShortCut, S(40), T, W - S(54), H, UIFont(12), clTextFaint, 2, 1);
      if It.SubMenu <> nil then
        DrawIcon(G, icChevronRight, W - S(20), T + H / 2, S(12), clTextDim);
    end;
    Inc(T, H);
  end;
end;

procedure TAuMenuList.SubTimer(Sender: TObject);
begin
  FSubTimer.Enabled := False;
  if (FHoverIdx >= 0) and (FMenu.Item(FHoverIdx).SubMenu <> nil) then OpenSub(FHoverIdx, False)
  else if FPopup.ChildPopup <> nil then FPopup.ChildPopup.CloseTree;
end;

procedure TAuMenuList.OpenSub(I: Integer; ByKey: Boolean);
var
  It: TAuMenuItem;
  Sub: TAuMenuPopup;
  P: TPoint;
begin
  It := FMenu.Item(I);
  if (It.SubMenu = nil) or not It.Enabled then Exit;
  if FPopup.ChildPopup <> nil then
  begin
    if TAuMenuPopup(FPopup.ChildPopup).FList.FMenu = It.SubMenu then Exit;
    FPopup.ChildPopup.CloseTree;
  end;
  if Assigned(It.SubMenu.OnPopup) then It.SubMenu.OnPopup(It.SubMenu);
  if It.SubMenu.Count = 0 then Exit;
  Sub := TAuMenuPopup.CreateMenu(It.SubMenu, FPopup);
  P := ClientToScreen(Point(Width - S(4), ItemTop(I) - FOffset - S(5)));
  Sub.ShowAt(P.X, P.Y, Sub.FList.ContentWidth, MenuHeightAt(P.X, P.Y, Sub.FList.ContentHeight, -1));
  { a sub menu that does not fit on the right opens on the left }
  if Sub.Left < P.X - S(8) then Sub.Left := ClientToScreen(Point(0, 0)).X - Sub.Width + S(4);
  if ByKey then Sub.FList.MoveHover(1);
  Invalidate;
end;

procedure TAuMenuList.Activate(I: Integer; ByKey: Boolean);
var
  It: TAuMenuItem;
begin
  if I < 0 then Exit;
  It := FMenu.Item(I);
  if not It.Enabled or It.Separator then Exit;
  if It.SubMenu <> nil then
  begin
    OpenSub(I, ByKey);
    Exit;
  end;
  Runner.Pending := It;
  FPopup.Root.CloseTree;
  Application.QueueAsyncCall(@Runner.Run, 0);
end;

procedure TAuMenuList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  I := ItemAt(Y);
  if I <> FHoverIdx then
  begin
    FHoverIdx := I;
    Invalidate;
    FSubTimer.Enabled := False;
    if (I >= 0) and ((FMenu.Item(I).SubMenu <> nil) or (FPopup.ChildPopup <> nil)) then
      FSubTimer.Enabled := True;
  end;
end;

procedure TAuMenuList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button in [mbLeft, mbRight] then FPressInList := True;
end;

procedure TAuMenuList.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  WasPressed: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  { only the release of a press inside the list chooses (see FPressInList) }
  WasPressed := FPressInList;
  FPressInList := False;
  if WasPressed and (Button in [mbLeft, mbRight]) then Activate(ItemAt(Y), False);
end;

procedure TAuMenuList.MoveHover(D: Integer);
var
  I, N, Guard: Integer;
begin
  N := FMenu.Count;
  if N = 0 then Exit;
  I := FHoverIdx;
  Guard := 0;
  repeat
    I := I + D;
    if I < 0 then I := N - 1;
    if I >= N then I := 0;
    Inc(Guard);
  until ((not FMenu.Item(I).Separator) and FMenu.Item(I).Enabled) or (Guard > N);
  FHoverIdx := I;
  EnsureVisible(I);
  Invalidate;
end;

function TAuMenuList.HoverLetter(ACh: Char): Boolean;
var
  K, I, N: Integer;
  S1: string;
begin
  Result := False;
  N := FMenu.Count;
  if (ACh = #0) or (N = 0) then Exit;
  for K := 1 to N do
  begin
    I := (Math.Max(FHoverIdx, -1) + K) mod N;
    if FMenu.Item(I).Separator or not FMenu.Item(I).Enabled then Continue;
    S1 := TrimLeft(FMenu.Item(I).Caption);
    if (S1 <> '') and (UpCase(S1[1]) = ACh) then
    begin
      FHoverIdx := I;
      EnsureVisible(I);
      Invalidate;
      Exit(True);
    end;
  end;
end;

{ ---- TAuMenuPopup ---- }

constructor TAuMenuPopup.CreateMenu(AMenu: TAuMenu; AParent: TAuMenuPopup);
begin
  inherited CreatePopup(AParent);
  FList := TAuMenuList.Create(Self);
  FList.FMenu := AMenu;
  FList.FPopup := Self;
  FList.Parent := Self;
  FList.Align := alClient;
  OnKeyDown := @FormKey;
end;

procedure TAuMenuPopup.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  KeyboardCues := True;
  case Key of
    VK_ESCAPE: Close;
    VK_LEFT: if ParentPopup <> nil then Close;
    VK_UP: FList.MoveHover(-1);
    VK_DOWN: FList.MoveHover(1);
    VK_HOME: FList.HoverEnd(False);
    VK_END: FList.HoverEnd(True);
    VK_PRIOR: FList.HoverPage(False);
    VK_NEXT: FList.HoverPage(True);
    VK_RIGHT: if FList.FHoverIdx >= 0 then FList.OpenSub(FList.FHoverIdx, True);
    VK_RETURN, VK_SPACE: FList.Activate(FList.FHoverIdx, True);
    VK_TAB: Root.CloseTree;
  else
    { a letter or digit: the next entry that begins with it }
    if not FList.HoverLetter(LetterOfKey(Key, Shift)) then Exit;
  end;
  Key := 0;
end;

initialization
  Runner := TMenuRunner.Create;

finalization
  Runner.Free;

end.
