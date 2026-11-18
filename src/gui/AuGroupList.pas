unit AuGroupList;

{ ==============================================================================
  AulumicNS - AuGroupList
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TAuGroupList - owner-drawn list of groups and items for the playlist pane.
  A row is either a
  group header (an album: cover, one or two lines of text) or an item (a
  track). Items of a collapsed group are hidden. The list holds only the row
  structure and an owner value per row; the owner paints the content
  (OnDrawRow) - the list paints selection, hover, the collapse triangle,
  the three dots menu button and the drop marker.
  Scrolling is in pixels because headers are higher than items.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType, LazUTF8,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls;

type
  TAuRowKind = (rkItem, rkHeader);
  TAuRowState = set of (rsSelected, rsHover, rsFocused, rsListFocused);

  TAuGroupRow = record
    Kind: TAuRowKind;
    Data: PtrInt;
    Group: Integer;       // row index of the header of an item (-1: none)
    Lines: Integer;       // header: one or two text lines
    Collapsed: Boolean;
    Selected: Boolean;
  end;

  TAuRowArray = array of Integer;
  TAuGLDrawEvent = procedure(Sender: TObject; G: TGfx; Row: Integer; X, Y, W, H: Single;
    State: TAuRowState) of object;
  TAuGLRowEvent = procedure(Sender: TObject; Row: Integer) of object;
  TAuGLClickEvent = procedure(Sender: TObject; Row: Integer; X, Y: Integer) of object;
  TAuGLContextEvent = procedure(Sender: TObject; Row: Integer; ScreenPt: TPoint) of object;
  // the text type-ahead searches in (OnRowText)
  TAuGLTextEvent = function(Sender: TObject; Row: Integer): string of object;

  { TAuGroupList }

  TAuGroupList = class(TAuControl)
  private
    FRows: array of TAuGroupRow;
    FCount: Integer;
    FVis: array of Integer;       // visible rows
    FVisY: array of Integer;      // their top in content pixels
    FVisCount, FContentH: Integer;
    FDirty: Boolean;
    FUpdating: Integer;
    FScroll: TAuScrollBar;
    FTop: Integer;                // scroll position in pixels
    FTextSize: Single;
    FItemH: Integer;
    FFocus, FAnchor, FHoverRow, FDownRow: Integer;
    FHot: TAuHotFade;                  // the hover highlight fading from row to row
    FHoverMenu, FDownOnSelected, FDragArmed: Boolean;
    FDownPt: TPoint;
    FMultiSelect, FRowMenu, FDragEnabled: Boolean;
    FDropRow: Integer;            // row index of the drop marker (-1 none)
    FDropAbove: Boolean;
    FEmptyText: string;
    FOnDrawRow: TAuGLDrawEvent;
    FOnActivate: TAuGLRowEvent;
    FOnRowClick: TAuGLClickEvent;
    FOnRowContext: TAuGLContextEvent;
    FOnSelChange, FOnTextSizeChange, FOnCollapseChange: TNotifyEvent;
    // type-ahead as in TAuTreeView (the letters typed within
    // 0.9 s; OnRowText gives each row's text)
    FOnRowText: TAuGLTextEvent;
    FTypeText: string;
    FTypeTick: QWord;
    procedure TypeAhead(const Ch: string);
    procedure ScrollChanged(Sender: TObject);
    procedure SetTextSize(V: Single);
    procedure UpdateItemH;
    procedure Rebuild;
    procedure NeedVis;
    function RowH(R: Integer): Integer;
    function VisIndexOf(R: Integer): Integer;
    function VisAt(Y: Integer): Integer;
    function ViewW: Integer;
    function GapAbove(R: Integer): Integer;
    function MenuGutter: Integer;
    function InMenuButton(X: Integer): Boolean;
    function InExpander(R, X: Integer): Boolean;
    procedure UpdateScroll;
    procedure SelectVisRange(A, B: Integer; Add: Boolean);
    procedure ClearSelQuiet;
    procedure MoveFocusVis(V: Integer; Shift: TShiftState);
    procedure DoSelChange;
    function GetKind(I: Integer): TAuRowKind;
    function GetData(I: Integer): PtrInt;
    function GetGroup(I: Integer): Integer;
    function GetCollapsed(I: Integer): Boolean;
    procedure SetCollapsed(I: Integer; V: Boolean);
    function GetSelected(I: Integer): Boolean;
    procedure SetSelected(I: Integer; V: Boolean);
    function GetLines(I: Integer): Integer;
    procedure SetDropRow(V: Integer);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function PanBy(DX, DY: Integer): Boolean; override;   // touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure DpiChanged; override;
    procedure BeginUpdate;
    procedure EndUpdate;
    procedure Clear;
    function AddHeader(AData: PtrInt; ALines: Integer = 1): Integer;
    function AddItem(AData: PtrInt): Integer;
    procedure Changed;
    function HeaderHeight(ALines: Integer): Integer;
    procedure EnsureVisible(R: Integer; Center: Boolean = False);
    procedure SelectOnly(R: Integer);
    procedure SelectAll;
    procedure ClearSelection;
    function SelectedRows: TAuRowArray;
    function SelCount: Integer;
    { the items of a group (header row index) }
    function GroupItems(H: Integer): TAuRowArray;
    function RowAtPoint(X, Y: Integer): Integer;
    function RowRect(R: Integer): TRect;
    { where a drop at Y goes: before row R (Above) or after it; -1 = at the end }
    procedure DropTargetAt(Y: Integer; out R: Integer; out Above: Boolean);
    procedure SetDropMarker(R: Integer; Above: Boolean);
    function IsVisibleRow(R: Integer): Boolean;
    property RowCount: Integer read FCount;
    property Kind[I: Integer]: TAuRowKind read GetKind;
    property Data[I: Integer]: PtrInt read GetData;
    property Group[I: Integer]: Integer read GetGroup;
    property Lines[I: Integer]: Integer read GetLines;
    property Collapsed[I: Integer]: Boolean read GetCollapsed write SetCollapsed;
    property Selected[I: Integer]: Boolean read GetSelected write SetSelected;
    property FocusedRow: Integer read FFocus;
    property ItemHeight: Integer read FItemH;
    property TextSize: Single read FTextSize write SetTextSize;
    property MultiSelect: Boolean read FMultiSelect write FMultiSelect;
    property RowMenu: Boolean read FRowMenu write FRowMenu;
    property DragEnabled: Boolean read FDragEnabled write FDragEnabled;
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnDrawRow: TAuGLDrawEvent read FOnDrawRow write FOnDrawRow;
    property OnActivate: TAuGLRowEvent read FOnActivate write FOnActivate;
    property OnRowClick: TAuGLClickEvent read FOnRowClick write FOnRowClick;
    property OnRowContext: TAuGLContextEvent read FOnRowContext write FOnRowContext;
    property OnSelChange: TNotifyEvent read FOnSelChange write FOnSelChange;
    property OnTextSizeChange: TNotifyEvent read FOnTextSizeChange write FOnTextSizeChange;
    property OnCollapseChange: TNotifyEvent read FOnCollapseChange write FOnCollapseChange;
    // the text of a row for type-ahead (not set: no type-ahead)
    property OnRowText: TAuGLTextEvent read FOnRowText write FOnRowText;
  end;

implementation

constructor TAuGroupList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FGpuPaint := True;
  FWantKeys := True;
  TabStop := True;
  FTextSize := 13;
  FFocus := -1;
  FAnchor := -1;
  FHoverRow := -1;
  FDownRow := -1;
  FDropRow := -1;
  FMultiSelect := True;
  FRowMenu := True;
  FDirty := True;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Visible := False;
  FScroll.OnScroll := @ScrollChanged;
  UpdateItemH;
end;

procedure TAuGroupList.UpdateItemH;
begin
  FItemH := Math.Max(S(18), Round(SF(FTextSize * FontScale) * 1.95));
  FScroll.SmallStep := FItemH;
  FDirty := True;
end;

procedure TAuGroupList.SetTextSize(V: Single);
begin
  V := EnsureRange(V, 8, 28);
  if V = FTextSize then Exit;
  FTextSize := V;
  UpdateItemH;
  Changed;
end;

procedure TAuGroupList.ScaleCached(K: Double);
begin
  UpdateItemH;
end;

procedure TAuGroupList.DpiChanged;
begin
  UpdateItemH;
  inherited DpiChanged;
end;

function TAuGroupList.HeaderHeight(ALines: Integer): Integer;
begin
  if ALines < 1 then ALines := 1;
  Result := Round(FItemH * (0.95 + 0.75 * ALines)) + S(8);
end;

function TAuGroupList.RowH(R: Integer): Integer;
begin
  if FRows[R].Kind = rkHeader then Result := HeaderHeight(FRows[R].Lines)
  else Result := FItemH;
end;

function TAuGroupList.GapAbove(R: Integer): Integer;
begin
  { a little air above every header but the first }
  if (FRows[R].Kind = rkHeader) and (R > 0) then Result := S(10) else Result := 0;
end;

procedure TAuGroupList.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure TAuGroupList.EndUpdate;
begin
  if FUpdating > 0 then Dec(FUpdating);
  if FUpdating = 0 then Changed;
end;

procedure TAuGroupList.Clear;
begin
  FCount := 0;
  SetLength(FRows, 0);
  FFocus := -1;
  FAnchor := -1;
  FHoverRow := -1;
  FDownRow := -1;
  FDropRow := -1;
  FDirty := True;
  if FUpdating = 0 then
  begin
    FScroll.Position := 0;
    Changed;
  end;
end;

function TAuGroupList.AddHeader(AData: PtrInt; ALines: Integer): Integer;
begin
  if FCount >= Length(FRows) then SetLength(FRows, Math.Max(64, Length(FRows) * 2));
  Result := FCount;
  FRows[Result].Kind := rkHeader;
  FRows[Result].Data := AData;
  FRows[Result].Group := -1;
  FRows[Result].Lines := EnsureRange(ALines, 1, 2);
  FRows[Result].Collapsed := False;
  FRows[Result].Selected := False;
  Inc(FCount);
  FDirty := True;
end;

function TAuGroupList.AddItem(AData: PtrInt): Integer;
var
  H: Integer;
begin
  if FCount >= Length(FRows) then SetLength(FRows, Math.Max(64, Length(FRows) * 2));
  Result := FCount;
  H := -1;
  if Result > 0 then
  begin
    if FRows[Result - 1].Kind = rkHeader then H := Result - 1 else H := FRows[Result - 1].Group;
  end;
  FRows[Result].Kind := rkItem;
  FRows[Result].Data := AData;
  FRows[Result].Group := H;
  FRows[Result].Lines := 1;
  FRows[Result].Collapsed := False;
  FRows[Result].Selected := False;
  Inc(FCount);
  FDirty := True;
end;

procedure TAuGroupList.Rebuild;
var
  I, N, Y: Integer;
  Hidden: Boolean;
begin
  SetLength(FVis, FCount);
  SetLength(FVisY, FCount);
  N := 0;
  Y := 0;
  Hidden := False;
  for I := 0 to FCount - 1 do
  begin
    if FRows[I].Kind = rkHeader then Hidden := False
    else if (FRows[I].Group >= 0) then Hidden := FRows[FRows[I].Group].Collapsed;
    if Hidden then Continue;
    Inc(Y, GapAbove(I));
    FVis[N] := I;
    FVisY[N] := Y;
    Inc(Y, RowH(I));
    Inc(N);
  end;
  FVisCount := N;
  FContentH := Y + S(6);
  FDirty := False;
end;

procedure TAuGroupList.NeedVis;
begin
  if FDirty then Rebuild;
end;

procedure TAuGroupList.Changed;
begin
  FDirty := True;
  if FUpdating > 0 then Exit;
  UpdateScroll;
  Invalidate;
end;

function TAuGroupList.ViewW: Integer;
begin
  Result := ClientWidth;
  if FScroll.Visible then Dec(Result, FScroll.Width);
end;

procedure TAuGroupList.UpdateScroll;
var
  SB: Integer;
begin
  NeedVis;
  SB := S(12);
  FScroll.Visible := FContentH > ClientHeight;
  FScroll.SetBounds(ClientWidth - SB, 0, SB, ClientHeight);
  FScroll.SetParams(FContentH, ClientHeight);
  FTop := FScroll.Position;
end;

procedure TAuGroupList.ScrollChanged(Sender: TObject);
begin
  FTop := FScroll.Position;
  Invalidate;
end;

procedure TAuGroupList.Resize;
begin
  inherited Resize;
  UpdateScroll;
end;

function TAuGroupList.VisIndexOf(R: Integer): Integer;
var
  Lo, Hi, M: Integer;
begin
  NeedVis;
  { FVis is sorted: binary search }
  Lo := 0;
  Hi := FVisCount - 1;
  while Lo <= Hi do
  begin
    M := (Lo + Hi) div 2;
    if FVis[M] = R then Exit(M);
    if FVis[M] < R then Lo := M + 1 else Hi := M - 1;
  end;
  Result := -1;
end;

function TAuGroupList.VisAt(Y: Integer): Integer;
var
  Lo, Hi, M, CY: Integer;
begin
  NeedVis;
  Result := -1;
  CY := Y + FTop;
  Lo := 0;
  Hi := FVisCount - 1;
  while Lo <= Hi do
  begin
    M := (Lo + Hi) div 2;
    if CY < FVisY[M] then Hi := M - 1
    else if CY >= FVisY[M] + RowH(FVis[M]) then Lo := M + 1
    else Exit(M);
  end;
end;

function TAuGroupList.RowAtPoint(X, Y: Integer): Integer;
var
  V: Integer;
begin
  V := VisAt(Y);
  if V < 0 then Result := -1 else Result := FVis[V];
end;

function TAuGroupList.RowRect(R: Integer): TRect;
var
  V: Integer;
begin
  V := VisIndexOf(R);
  if V < 0 then Exit(Rect(0, 0, 0, 0));
  Result := Rect(0, FVisY[V] - FTop, ViewW, FVisY[V] - FTop + RowH(R));
end;

function TAuGroupList.IsVisibleRow(R: Integer): Boolean;
begin
  Result := VisIndexOf(R) >= 0;
end;

function TAuGroupList.MenuGutter: Integer;
begin
  if FRowMenu and Assigned(FOnRowContext) then Result := S(34) else Result := 0;
end;

function TAuGroupList.InMenuButton(X: Integer): Boolean;
begin
  Result := (MenuGutter > 0) and (X >= ViewW - S(34)) and (X < ViewW - S(2));
end;

function TAuGroupList.InExpander(R, X: Integer): Boolean;
begin
  Result := (R >= 0) and (FRows[R].Kind = rkHeader) and (X < S(30));
end;

function TAuGroupList.GetKind(I: Integer): TAuRowKind;
begin
  Result := FRows[I].Kind;
end;

function TAuGroupList.GetData(I: Integer): PtrInt;
begin
  Result := FRows[I].Data;
end;

function TAuGroupList.GetGroup(I: Integer): Integer;
begin
  Result := FRows[I].Group;
end;

function TAuGroupList.GetLines(I: Integer): Integer;
begin
  Result := FRows[I].Lines;
end;

function TAuGroupList.GetCollapsed(I: Integer): Boolean;
begin
  Result := (I >= 0) and (I < FCount) and FRows[I].Collapsed;
end;

procedure TAuGroupList.SetCollapsed(I: Integer; V: Boolean);
var
  J: Integer;
begin
  if (I < 0) or (I >= FCount) or (FRows[I].Kind <> rkHeader) or (FRows[I].Collapsed = V) then Exit;
  FRows[I].Collapsed := V;
  if V then
  begin
    { hidden items lose the selection and the focus moves to the header }
    J := I + 1;
    while (J < FCount) and (FRows[J].Kind = rkItem) do
    begin
      FRows[J].Selected := False;
      if FFocus = J then FFocus := I;
      Inc(J);
    end;
  end;
  Changed;
  if Assigned(FOnCollapseChange) then FOnCollapseChange(Self);
end;

function TAuGroupList.GetSelected(I: Integer): Boolean;
begin
  Result := (I >= 0) and (I < FCount) and FRows[I].Selected;
end;

procedure TAuGroupList.SetSelected(I: Integer; V: Boolean);
begin
  if (I < 0) or (I >= FCount) or (FRows[I].Selected = V) then Exit;
  FRows[I].Selected := V;
  Invalidate;
end;

procedure TAuGroupList.SetDropRow(V: Integer);
begin
  if V = FDropRow then Exit;
  FDropRow := V;
  Invalidate;
end;

procedure TAuGroupList.SetDropMarker(R: Integer; Above: Boolean);
begin
  if (R = FDropRow) and (Above = FDropAbove) then Exit;
  FDropAbove := Above;
  FDropRow := -2;     // force the repaint
  SetDropRow(R);
end;

procedure TAuGroupList.DropTargetAt(Y: Integer; out R: Integer; out Above: Boolean);
var
  V: Integer;
  RR: TRect;
begin
  V := VisAt(Y);
  Above := True;
  if V < 0 then
  begin
    R := -1;
    Exit;
  end;
  R := FVis[V];
  RR := RowRect(R);
  Above := Y < (RR.Top + RR.Bottom) div 2;
end;

procedure TAuGroupList.ClearSelQuiet;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do FRows[I].Selected := False;
end;

procedure TAuGroupList.ClearSelection;
begin
  ClearSelQuiet;
  Invalidate;
  DoSelChange;
end;

procedure TAuGroupList.SelectAll;
var
  I: Integer;
begin
  if not FMultiSelect then Exit;
  NeedVis;
  for I := 0 to FVisCount - 1 do FRows[FVis[I]].Selected := True;
  Invalidate;
  DoSelChange;
end;

procedure TAuGroupList.SelectOnly(R: Integer);
begin
  ClearSelQuiet;
  if (R >= 0) and (R < FCount) then
  begin
    { an item of a collapsed group: open the group first }
    if (FRows[R].Kind = rkItem) and (FRows[R].Group >= 0) and FRows[FRows[R].Group].Collapsed then
      SetCollapsed(FRows[R].Group, False);
    FRows[R].Selected := True;
    FFocus := R;
    FAnchor := R;
    EnsureVisible(R);
  end;
  Invalidate;
  DoSelChange;
end;

function TAuGroupList.SelectedRows: TAuRowArray;
var
  I, N: Integer;
begin
  Result := nil;
  SetLength(Result, FCount);
  N := 0;
  for I := 0 to FCount - 1 do
    if FRows[I].Selected then
    begin
      Result[N] := I;
      Inc(N);
    end;
  SetLength(Result, N);
end;

function TAuGroupList.SelCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FCount - 1 do if FRows[I].Selected then Inc(Result);
end;

function TAuGroupList.GroupItems(H: Integer): TAuRowArray;
var
  I, N: Integer;
begin
  Result := nil;
  if (H < 0) or (H >= FCount) or (FRows[H].Kind <> rkHeader) then Exit;
  N := 0;
  I := H + 1;
  while (I < FCount) and (FRows[I].Kind = rkItem) do
  begin
    SetLength(Result, N + 1);
    Result[N] := I;
    Inc(N);
    Inc(I);
  end;
end;

procedure TAuGroupList.SelectVisRange(A, B: Integer; Add: Boolean);
var
  I, T: Integer;
begin
  NeedVis;
  if not Add then ClearSelQuiet;
  if A > B then begin T := A; A := B; B := T; end;
  if A < 0 then A := 0;
  for I := A to Math.Min(B, FVisCount - 1) do FRows[FVis[I]].Selected := True;
end;

procedure TAuGroupList.DoSelChange;
begin
  if Assigned(FOnSelChange) then FOnSelChange(Self);
end;

procedure TAuGroupList.EnsureVisible(R: Integer; Center: Boolean);
var
  V, Y, H: Integer;
begin
  UpdateScroll;
  V := VisIndexOf(R);
  if V < 0 then Exit;
  Y := FVisY[V];
  H := RowH(R);
  if Center then FScroll.Position := Y - (ClientHeight - H) div 2
  else if Y - GapAbove(R) < FTop then FScroll.Position := Y - GapAbove(R)
  else if Y + H > FTop + ClientHeight then FScroll.Position := Y + H - ClientHeight;
  FTop := FScroll.Position;
  Invalidate;
end;

procedure TAuGroupList.MoveFocusVis(V: Integer; Shift: TShiftState);
var
  A: Integer;
begin
  NeedVis;
  if FVisCount = 0 then Exit;
  V := EnsureRange(V, 0, FVisCount - 1);
  FFocus := FVis[V];
  A := VisIndexOf(FAnchor);
  if (ssShift in Shift) and FMultiSelect and (A >= 0) then
    SelectVisRange(A, V, ssCtrl in Shift)
  else if not (ssCtrl in Shift) then
  begin
    SelectVisRange(V, V, False);
    FAnchor := FFocus;
  end;
  EnsureVisible(FFocus);
  DoSelChange;
end;

procedure TAuGroupList.DoPaint(G: TGfx);
var
  V, R, Y, VW, H: Integer;
  Bg: TARGB;
  St: TAuRowState;
  Foc: Boolean;
  CX: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  NeedVis;
  VW := ViewW;
  Foc := Focused;
  if (FVisCount = 0) and (FEmptyText <> '') then
  begin
    G.Text(FEmptyText, S(20), 0, VW - S(40), ClientHeight, UIFont(13), clTextFaint, 1, 1, tfWrap);
    Exit;
  end;
  HotSet(FHot, FHoverRow, Self);
  { the first visible row }
  V := VisAt(0);
  if V < 0 then
  begin
    V := 0;
    while (V < FVisCount) and (FVisY[V] + RowH(FVis[V]) <= FTop) do Inc(V);
  end;
  while V < FVisCount do
  begin
    R := FVis[V];
    Y := FVisY[V] - FTop;
    if Y >= ClientHeight then Break;
    H := RowH(R);
    St := [];
    if FRows[R].Selected then Include(St, rsSelected);
    if R = FHoverRow then Include(St, rsHover);
    if R = FFocus then Include(St, rsFocused);
    if Foc then Include(St, rsListFocused);
    Bg := 0;
    if FRows[R].Selected then
    begin
      if Foc then Bg := clSelection else Bg := clSelectionDim;
    end
    else if HotLevel(FHot, R) > 0 then Bg := Blend(EffBack, clHover, HotLevel(FHot, R));
    if Bg <> 0 then G.FillRound(S(4), Y + 1, VW - S(8), H - 2, S(6), Bg);
    if Foc and KeyboardCues and (R = FFocus) then
      G.StrokeRound(S(4), Y + 1, VW - S(8), H - 2, S(6), SF(1.5), clAccent);
    if FRows[R].Kind = rkHeader then
    begin
      CX := S(16);
      if FRows[R].Collapsed then DrawIcon(G, icTriRight, CX, Y + H / 2, S(12), clTextDim)
      else DrawIcon(G, icTriDown, CX, Y + H / 2, S(12), clTextDim);
      if Assigned(FOnDrawRow) then FOnDrawRow(Self, G, R, S(30), Y, VW - S(30) - MenuGutter - S(4), H, St);
    end
    else if Assigned(FOnDrawRow) then
      FOnDrawRow(Self, G, R, S(30), Y, VW - S(30) - MenuGutter - S(4), H, St);
    if (MenuGutter > 0) and (FRows[R].Selected or (R = FHoverRow)) then
    begin
      if Bg = 0 then Bg := EffBack;
      if (R = FHoverRow) and FHoverMenu then
        G.FillRound(VW - S(34), Y + (H - FItemH) div 2 + S(2), S(30), FItemH - S(4), S(5), Blend(Bg, clText, 0.12));
      DrawIcon(G, icMore, VW - S(19), Y + H / 2, Math.Min(S(16), FItemH * 0.7), clTextDim);
    end;
    if R = FDropRow then
    begin
      if FDropAbove then G.FillRound(S(8), Y - SF(1.5), VW - S(16), SF(3), SF(1.5), clAccent)
      else G.FillRound(S(8), Y + H - SF(1.5), VW - S(16), SF(3), SF(1.5), clAccent);
    end;
    Inc(V);
  end;
end;

procedure TAuGroupList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  V, R: Integer;
  RR: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  FDownRow := -1;
  FDragArmed := False;
  FDownOnSelected := False;
  V := VisAt(Y);
  if V < 0 then
  begin
    if (Button = mbLeft) and not (ssCtrl in Shift) then ClearSelection;
    Exit;
  end;
  R := FVis[V];
  if (Button = mbLeft) and InMenuButton(X) then
  begin
    if not FRows[R].Selected then
    begin
      SelectVisRange(V, V, False);
      FAnchor := R;
    end;
    FFocus := R;
    Invalidate;
    DoSelChange;
    RR := RowRect(R);
    if Assigned(FOnRowContext) then FOnRowContext(Self, R, ClientToScreen(Point(ViewW - S(34), RR.Bottom)));
    Exit;
  end;
  if (Button = mbLeft) and InExpander(R, X) and not (ssShift in Shift) and not (ssCtrl in Shift) then
  begin
    SetCollapsed(R, not FRows[R].Collapsed);
    Exit;
  end;
  if Button = mbRight then
  begin
    if not FRows[R].Selected then
    begin
      SelectVisRange(V, V, False);
      FAnchor := R;
    end;
    FFocus := R;
    Invalidate;
    DoSelChange;
    if Assigned(FOnRowContext) then FOnRowContext(Self, R, ClientToScreen(Point(X, Y)));
    Exit;
  end;
  if Button <> mbLeft then Exit;
  FFocus := R;
  FDownRow := R;
  FDownPt := Point(X, Y);
  if (ssShift in Shift) and FMultiSelect and (VisIndexOf(FAnchor) >= 0) then
    SelectVisRange(VisIndexOf(FAnchor), V, ssCtrl in Shift)
  else if (ssCtrl in Shift) and FMultiSelect then
  begin
    FRows[R].Selected := not FRows[R].Selected;
    FAnchor := R;
  end
  else if FRows[R].Selected and (SelCount > 1) then
    FDownOnSelected := True
  else
  begin
    SelectVisRange(V, V, False);
    FAnchor := R;
  end;
  FDragArmed := FDragEnabled and FRows[R].Selected;
  Invalidate;
  DoSelChange;
  if Assigned(FOnRowClick) and not (ssShift in Shift) and not (ssCtrl in Shift) then
  begin
    RR := RowRect(R);
    FOnRowClick(Self, R, X - S(30), Y - RR.Top);
  end;
end;

procedure TAuGroupList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  R: Integer;
  M: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragArmed and (ssLeft in Shift) and (FDownRow >= 0) and
     ((Abs(X - FDownPt.X) > S(6)) or (Abs(Y - FDownPt.Y) > S(6))) then
  begin
    FDragArmed := False;
    FDownOnSelected := False;
    BeginDrag(True);
    Exit;
  end;
  R := RowAtPoint(X, Y);
  M := (R >= 0) and InMenuButton(X);
  if (R <> FHoverRow) or (M <> FHoverMenu) then
  begin
    FHoverRow := R;
    FHoverMenu := M;
    Invalidate;
  end;
end;

procedure TAuGroupList.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R, V: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  R := RowAtPoint(X, Y);
  if FDownOnSelected and (R >= 0) and (R = FDownRow) then
  begin
    V := VisIndexOf(R);
    SelectVisRange(V, V, False);
    FAnchor := R;
    Invalidate;
    DoSelChange;
  end;
  FDownOnSelected := False;
  FDragArmed := False;
  FDownRow := -1;
end;

procedure TAuGroupList.MouseLeave;
begin
  inherited MouseLeave;
  FHoverRow := -1;
  FHoverMenu := False;
  Invalidate;
end;

procedure TAuGroupList.DblClick;
var
  P: TPoint;
  R: Integer;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  R := RowAtPoint(P.X, P.Y);
  if (R < 0) or InExpander(R, P.X) or InMenuButton(P.X) then Exit;
  if Assigned(FOnActivate) then FOnActivate(Self, R);
end;

procedure TAuGroupList.KeyDown(var Key: Word; Shift: TShiftState);
var
  V: Integer;
  P: TPoint;
  RR: TRect;
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  NeedVis;
  V := VisIndexOf(FFocus);
  case Key of
    VK_UP: MoveFocusVis(V - 1, Shift);
    VK_DOWN: MoveFocusVis(V + 1, Shift);
    VK_PRIOR: MoveFocusVis(V - Math.Max(1, ClientHeight div FItemH) + 1, Shift);
    VK_NEXT: MoveFocusVis(V + Math.Max(1, ClientHeight div FItemH) - 1, Shift);
    VK_HOME: MoveFocusVis(0, Shift);
    VK_END: MoveFocusVis(FVisCount - 1, Shift);
    VK_LEFT:
      if FFocus >= 0 then
      begin
        if FRows[FFocus].Kind = rkHeader then SetCollapsed(FFocus, True)
        else if FRows[FFocus].Group >= 0 then SelectOnly(FRows[FFocus].Group);
      end;
    VK_RIGHT:
      if (FFocus >= 0) and (FRows[FFocus].Kind = rkHeader) then SetCollapsed(FFocus, False);
    VK_RETURN:
      if (FFocus >= 0) and Assigned(FOnActivate) then FOnActivate(Self, FFocus);
    VK_APPS, VK_F10:
      begin
        if (Key = VK_F10) and not (ssShift in Shift) then Exit;
        if (FFocus >= 0) and Assigned(FOnRowContext) then
        begin
          EnsureVisible(FFocus);
          RR := RowRect(FFocus);
          P := ClientToScreen(Point(S(40), RR.Bottom));
          FOnRowContext(Self, FFocus, P);
        end;
      end;
  else
    if (ssCtrl in Shift) and (Key = Ord('A')) then SelectAll
    else Exit;
  end;
  Key := 0;
end;

{ as TAuTreeView.TypeAhead: the visible row after the focus
  (a new search) or from it (more letters) whose text starts with the letters
  typed within 0.9 s }
procedure TAuGroupList.TypeAhead(const Ch: string);
var
  I, Start, V: Integer;
  U: string;
begin
  if not Assigned(FOnRowText) then Exit;
  if GetTickCount64 - FTypeTick > 900 then FTypeText := '';
  FTypeTick := GetTickCount64;
  FTypeText := FTypeText + Ch;
  U := UTF8LowerCase(FTypeText);
  NeedVis;
  if FVisCount = 0 then Exit;
  Start := Math.Max(0, VisIndexOf(FFocus));
  if Length(FTypeText) = Length(Ch) then Start := Start + 1;   // a new search starts after the focus
  for I := 0 to FVisCount - 1 do
  begin
    V := (Start + I) mod FVisCount;
    if Pos(U, UTF8LowerCase(FOnRowText(Self, FVis[V]))) = 1 then
    begin
      MoveFocusVis(V, []);
      Exit;
    end;
  end;
end;

procedure TAuGroupList.UTF8KeyPress(var UTF8Key: TUTF8Char);
begin
  inherited UTF8KeyPress(UTF8Key);
  { a space only within a search (alone it is Play / Pause) }
  if Assigned(FOnRowText) and (UTF8Key <> '') and (UTF8Key[1] >= ' ') and
     not ((UTF8Key = ' ') and ((FTypeText = '') or (GetTickCount64 - FTypeTick > 900))) then
  begin
    TypeAhead(UTF8Key);
    UTF8Key := '';
  end;
end;

function TAuGroupList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if ssCtrl in Shift then
  begin
    TextSize := FTextSize + Sign(WheelDelta);
    if Assigned(FOnTextSizeChange) then FOnTextSizeChange(Self);
    Exit;
  end;
  FScroll.WheelBy(-Sign(WheelDelta) * FItemH * 3);     // glides; ScrollChanged follows
end;

{ touch - the list follows the finger (pixels) }
function TAuGroupList.PanBy(DX, DY: Integer): Boolean;
begin
  if not FScroll.Visible then Exit(inherited PanBy(DX, DY));
  if DY <> 0 then
  begin
    FScroll.Position := FScroll.Position - DY;
    FTop := FScroll.Position;
    Invalidate;
  end;
  Result := True;
end;

function TAuGroupList.ScrollOffset: Integer;
begin
  Result := FTop;
end;

end.
