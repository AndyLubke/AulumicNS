unit AuLists;

{ ==============================================================================
  AulumicNS - AuLists
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Virtual, owner-drawn collection controls:
  TAuListView  - multi-column track list: resizable / sortable columns,
                 multi-selection, horizontal + vertical themed scroll bars
  TAuTileView  - grid of cover tiles (albums, artists)
  TAuNavRail   - vertical navigation (collapsible to icons)
  All of them hold no data: they ask the owner through events, so they scale
  to libraries with hundreds of thousands of tracks.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType, 
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls;

type
  TAuGetCellEvent = procedure(Sender: TObject; Row, Col: Integer; var AText: string) of object;
  TAuDrawCellEvent = procedure(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
    var Handled: Boolean) of object;
  TAuRowStyleEvent = procedure(Sender: TObject; Row: Integer; var Bold: Boolean; var Color: TARGB) of object;
  TAuColEvent = procedure(Sender: TObject; Col: Integer) of object;
  TIntegerArray = array of Integer;
  TAuRowPointEvent = procedure(Sender: TObject; Row: Integer; ScreenPt: TPoint) of object;
  { left click on a cell; XInCell = pixels from the left edge of the cell }
  TAuCellClickEvent = procedure(Sender: TObject; Row, Col, XInCell: Integer) of object;

  TAuColumn = record
    Caption: string;
    Width: Integer;      // unscaled px
    MinWidth: Integer;
    Align: Integer;      // 0 left, 1 centre, 2 right
    Flex: Boolean;       // takes the remaining width
    Visible: Boolean;
    Tag: Integer;
  end;

  { TAuListView }

  TAuListView = class(TAuControl)
  private
    FCols: array of TAuColumn;
    FRowCount, FFocusRow, FAnchorRow, FHoverRow, FTop, FScrollX: Integer;
    FHot: TAuHotFade;                  // the hover highlight fading from row to row
    FSel: array of Boolean;
    FSelCount: Integer;
    FRowH: Integer;
    FShowHeader, FMultiSelect: Boolean;
    FVScroll, FHScroll: TAuScrollBar;
    FSortCol: Integer;
    FSortDesc: Boolean;
    FEmptyText: string;
    FResizeCol, FResizeStartX, FResizeStartW, FHoverHeader, FDownRow: Integer;
    FAutoFit, FFitPending: Boolean;
    FOnHeaderContext: TAuRowPointEvent;
    FDownOnSelected: Boolean;
    FOnGetCell: TAuGetCellEvent;
    FOnDrawCell: TAuDrawCellEvent;
    FOnRowStyle: TAuRowStyleEvent;
    FOnHeaderClick: TAuColEvent;
    FOnActivate: TAuRowEvent;
    FOnSelChange: TNotifyEvent;
    FOnRowContext: TAuRowPointEvent;
    FOnCellClick: TAuCellClickEvent;
    FRowMenu: Boolean;
    FHoverMenu: Integer;            // row (or -2 = header) whose menu button is under the mouse
    FOnColumnsChanged: TNotifyEvent;
    function MenuGutter: Integer;
    function InMenuButton(X: Integer): Boolean;
    procedure SetRowCount(V: Integer);
    procedure ScrollChanged(Sender: TObject);
    function HeaderH: Integer;
    function VisibleRows: Integer;
    function RowAt(Y: Integer): Integer;
    function ColWidthPx(C: Integer; FlexW: Integer): Integer;
    function FlexWidth: Integer;
    function TotalWidth: Integer;
    function ViewW: Integer;
    function ViewH: Integer;
    function ColAt(X: Integer; out Edge: Boolean): Integer;
    function NextVisible(C: Integer): Integer;
    procedure UpdateScrollBars;
    procedure SelectRange(A, B: Integer; Add: Boolean);
    procedure DoSelChange;
    function GetSelected(I: Integer): Boolean;
    procedure SetSelected(I: Integer; V: Boolean);
    procedure MoveFocus(N: Integer; Shift: TShiftState);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function PanBy(DX, DY: Integer): Boolean; override;   // ---> AulumicNS: touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    function AddColumn(const ACaption: string; AWidth: Integer; AAlign: Integer = 0; AFlex: Boolean = False): Integer;
    procedure ClearColumns;
    function ColumnCount: Integer;
    function Column(I: Integer): TAuColumn;
    procedure SetColumnWidth(I, W: Integer);
    procedure SetColumnVisible(I: Integer; V: Boolean);
    procedure SetColumnMinWidth(I, W: Integer);
    procedure FitColumns;
    procedure Changed;
    procedure EnsureVisible(Row: Integer);
    procedure ClearSelection;
    procedure SelectAll;
    procedure SelectOnly(Row: Integer);
    function ColumnLeft(C: Integer): Integer;
    function SelectedRows: TIntegerArray;
    property RowCount: Integer read FRowCount write SetRowCount;
    property FocusedRow: Integer read FFocusRow;
    { the first row in view and how many rows fit }
    property TopRow: Integer read FTop;
    function PageRows: Integer;
    property Selected[I: Integer]: Boolean read GetSelected write SetSelected;
    property SelCount: Integer read FSelCount;
    property RowHeight: Integer read FRowH write FRowH;
    property ShowHeader: Boolean read FShowHeader write FShowHeader;
    property MultiSelect: Boolean read FMultiSelect write FMultiSelect;
    property SortColumn: Integer read FSortCol write FSortCol;
    property SortDescending: Boolean read FSortDesc write FSortDesc;
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnGetCell: TAuGetCellEvent read FOnGetCell write FOnGetCell;
    property OnDrawCell: TAuDrawCellEvent read FOnDrawCell write FOnDrawCell;
    property OnRowStyle: TAuRowStyleEvent read FOnRowStyle write FOnRowStyle;
    property OnHeaderClick: TAuColEvent read FOnHeaderClick write FOnHeaderClick;
    property OnActivate: TAuRowEvent read FOnActivate write FOnActivate;
    property OnSelChange: TNotifyEvent read FOnSelChange write FOnSelChange;
    property OnRowContext: TAuRowPointEvent read FOnRowContext write FOnRowContext;
    property OnCellClick: TAuCellClickEvent read FOnCellClick write FOnCellClick;
    { a menu button (three dots) on the hovered / selected rows and in the header:
      opens OnRowContext / OnHeaderContext for touch screens and one-button mice }
    property RowMenu: Boolean read FRowMenu write FRowMenu;
    property OnColumnsChanged: TNotifyEvent read FOnColumnsChanged write FOnColumnsChanged;
    property OnHeaderContext: TAuRowPointEvent read FOnHeaderContext write FOnHeaderContext;
    { flex columns refit on every resize (single column lists) }
    property AutoFit: Boolean read FAutoFit write FAutoFit;
    { flex columns are fitted once when the list first gets a size; set to
      False after restoring saved column widths }
    property FitPending: Boolean read FFitPending write FFitPending;
  end;

  TAuGetTileEvent = procedure(Sender: TObject; Index: Integer; var Title, Subtitle: string;
    var Bitmap: TGfxBitmap) of object;

  { TAuTileView }

  TAuTileView = class(TAuControl)
  private
    FCount, FIndex, FHoverIdx, FTileW, FScrollY: Integer;
    FHoverPlay, FRoundArt, FHoverMenu: Boolean;
    FScroll: TAuScrollBar;
    FEmptyText: string;
    FOnGetTile: TAuGetTileEvent;
    FOnActivate, FOnPlay: TAuRowEvent;
    FOnSelect: TNotifyEvent;
    FOnContext: TAuRowPointEvent;
    function MenuHit(I, X, Y: Integer): Boolean;
    procedure SetCount(V: Integer);
    procedure SetIndex(V: Integer);
    procedure ScrollChanged(Sender: TObject);
    procedure Layout(out Cols: Integer; out CellW, CellH, Gap: Single);
    function IndexAt(X, Y: Integer; out IsPlay: Boolean): Integer;
    procedure UpdateScroll;
    function ContentH: Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function PanBy(DX, DY: Integer): Boolean; override;   // ---> AulumicNS: touch
  public
    function ScrollOffset: Integer; override;
    constructor Create(AOwner: TComponent); override;
    procedure Changed;
    procedure EnsureVisible(I: Integer);
    property Count: Integer read FCount write SetCount;
    property ItemIndex: Integer read FIndex write SetIndex;
    property TileWidth: Integer read FTileW write FTileW;
    property RoundArt: Boolean read FRoundArt write FRoundArt;   // circles (artists)
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnGetTile: TAuGetTileEvent read FOnGetTile write FOnGetTile;
    property OnActivate: TAuRowEvent read FOnActivate write FOnActivate;
    property OnPlay: TAuRowEvent read FOnPlay write FOnPlay;
    property OnSelect: TNotifyEvent read FOnSelect write FOnSelect;
    property OnContext: TAuRowPointEvent read FOnContext write FOnContext;
  end;

  TAuNavItem = record
    Caption: string;
    Icon: TAuIcon;
    IsHeader: Boolean;
    Badge: string;
  end;

  { TAuNavRail }

  TAuNavRail = class(TAuControl)
  private
    FItems: array of TAuNavItem;
    FIndex, FHoverIdx: Integer;
    FCollapsed: Boolean;
    FTitle: string;
    FOnChange: TNotifyEvent;
    FOnToggle: TNotifyEvent;
    function ItemTop(I: Integer): Integer;
    function ItemH(I: Integer): Integer;
    function ItemAt(Y: Integer): Integer;
    function ToggleRect: TRect;
    procedure SetIndex(V: Integer);
    procedure SetCollapsed(V: Boolean);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    function AddItem(const ACaption: string; AIcon: TAuIcon): Integer;
    procedure AddHeader(const ACaption: string);
    procedure SetBadge(I: Integer; const ABadge: string);
    function ItemCaption(I: Integer): string;
    function ExpandedWidth: Integer;
    function CollapsedWidth: Integer;
    property ItemIndex: Integer read FIndex write SetIndex;
    property Collapsed: Boolean read FCollapsed write SetCollapsed;
    property Title: string read FTitle write FTitle;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
  end;

procedure DrawTileArt(G: TGfx; Bmp: TGfxBitmap; X, Y, W, H, R: Single; const Key: string; Round: Boolean);

implementation

procedure DrawTileArt(G: TGfx; Bmp: TGfxBitmap; X, Y, W, H, R: Single; const Key: string; Round: Boolean);
var
  C1, C2: TARGB;
  St: UINT;
begin
  if Round then R := W / 2;
  if Bmp <> nil then
  begin
    G.DrawBitmapCover(Bmp, X, Y, W, H, R);
    Exit;
  end;
  C1 := HashColor(Key);
  C2 := Blend(C1, HashColor(Key + '#'), 0.5);
  if ThemeIsDark then C2 := Blend(C2, $FF000000, 0.35) else C2 := Blend(C2, $FFFFFFFF, 0.2);
  St := G.Save;
  G.IntersectClipRound(X, Y, W, H, R);
  G.FillRoundGrad(X, Y, W, H, 0, C1, C2, True);
  G.Restore(St);
  if Round then DrawIcon(G, icArtist, X + W / 2, Y + H / 2, W * 0.36, WithAlpha($FFFFFF, $A0))
  else DrawIcon(G, icNote, X + W / 2, Y + H / 2, W * 0.32, WithAlpha($FFFFFF, $90));
end;

{ ==== TAuListView ==== }

constructor TAuListView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FWantKeys := True;
  TabStop := True;
  FFocusRow := -1;
  FAnchorRow := -1;
  FHoverRow := -1;
  FDownRow := -1;
  FResizeCol := -1;
  FHoverHeader := -1;
  FHoverMenu := -1;
  FSortCol := -1;
  FFitPending := True;
  FRowH := S(32);
  FShowHeader := True;
  FMultiSelect := True;
  FVScroll := TAuScrollBar.Create(Self);
  FVScroll.Parent := Self;
  FVScroll.Visible := False;
  FVScroll.OnScroll := @ScrollChanged;
  FHScroll := TAuScrollBar.Create(Self);
  FHScroll.Kind := aoHorizontal;
  FHScroll.Parent := Self;
  FHScroll.Visible := False;
  FHScroll.SmallStep := S(20);
  FHScroll.OnScroll := @ScrollChanged;
end;

function TAuListView.AddColumn(const ACaption: string; AWidth: Integer; AAlign: Integer; AFlex: Boolean): Integer;
begin
  Result := Length(FCols);
  SetLength(FCols, Result + 1);
  FCols[Result].Caption := ACaption;
  FCols[Result].Width := AWidth;
  FCols[Result].MinWidth := 40;
  FCols[Result].Align := AAlign;
  FCols[Result].Flex := AFlex;
  FCols[Result].Visible := True;
  FCols[Result].Tag := Result;
  Changed;
end;

procedure TAuListView.ClearColumns;
begin
  SetLength(FCols, 0);
  Changed;
end;

function TAuListView.ColumnCount: Integer;
begin
  Result := Length(FCols);
end;

function TAuListView.Column(I: Integer): TAuColumn;
begin
  Result := FCols[I];
end;

procedure TAuListView.SetColumnWidth(I, W: Integer);
begin
  if (I < 0) or (I > High(FCols)) then Exit;
  FCols[I].Width := Math.Max(FCols[I].MinWidth, W);
  Changed;
end;

procedure TAuListView.SetColumnVisible(I: Integer; V: Boolean);
begin
  if (I < 0) or (I > High(FCols)) then Exit;
  FCols[I].Visible := V;
  Changed;
end;

function TAuListView.HeaderH: Integer;
begin
  if FShowHeader then Result := S(34) else Result := 0;
end;

function TAuListView.MenuGutter: Integer;
begin
  if FRowMenu and Assigned(FOnRowContext) then Result := S(36) else Result := 0;
end;

function TAuListView.InMenuButton(X: Integer): Boolean;
begin
  Result := (MenuGutter > 0) and (X >= ViewW - S(38)) and (X < ViewW - S(2));
end;

function TAuListView.ViewW: Integer;
begin
  Result := ClientWidth;
  if FVScroll.Visible then Dec(Result, FVScroll.Width);
end;

function TAuListView.ViewH: Integer;
begin
  Result := ClientHeight - HeaderH;
  if FHScroll.Visible then Dec(Result, FHScroll.Height);
end;

function TAuListView.VisibleRows: Integer;
begin
  Result := ViewH div FRowH;
  if Result < 1 then Result := 1;
end;

{ Column model: every column has its own width (like the Explorer details
  view). Dragging an edge resizes only the column left of it; the columns to
  the right move along. "Flex" columns take the free width when the columns
  are fitted: once when the list first gets a size (unless saved widths were
  restored), on "Fit columns to window", and on every resize in AutoFit mode
  (single column lists such as the queue). }
function TAuListView.FlexWidth: Integer;
begin
  Result := 0;
end;

function TAuListView.PageRows: Integer;
begin
  Result := VisibleRows;
end;

function TAuListView.ColWidthPx(C: Integer; FlexW: Integer): Integer;
begin
  if not FCols[C].Visible then Exit(0);
  Result := S(FCols[C].Width);
end;

{ Makes the visible columns exactly fill the list: flex columns take the
  free width; when even their minimum does not fit, the other columns are
  first narrowed proportionally (never below their own minimum). Works in
  96-dpi units. }
procedure TAuListView.FitColumns;
var
  C, Fixed, FixedMin, FlexMin, NFlex, Avail, Room, VW: Integer;
  K: Double;
begin
  Fixed := 0; FixedMin := 0; FlexMin := 0; NFlex := 0;
  for C := 0 to High(FCols) do
    if FCols[C].Visible then
    begin
      if FCols[C].Flex then
      begin
        Inc(NFlex);
        Inc(FlexMin, FCols[C].MinWidth);
      end
      else
      begin
        Inc(Fixed, FCols[C].Width);
        Inc(FixedMin, FCols[C].MinWidth);
      end;
    end;
  if NFlex = 0 then Exit;
  VW := ClientWidth - MenuGutter;
  if FRowCount * FRowH > ClientHeight - HeaderH then Dec(VW, S(12));
  Avail := Trunc((VW - S(16)) / UIScale);    // never a pixel too wide (no needless scroll bar)
  { not enough room: narrow the other columns towards their minimum }
  if (Fixed + FlexMin > Avail) and (Fixed > FixedMin) then
  begin
    Room := Avail - FlexMin - FixedMin;
    if Room < 0 then Room := 0;
    K := Room / (Fixed - FixedMin);
    if K > 1 then K := 1;
    Fixed := 0;
    for C := 0 to High(FCols) do
      if FCols[C].Visible and not FCols[C].Flex then
      begin
        FCols[C].Width := FCols[C].MinWidth + Trunc((FCols[C].Width - FCols[C].MinWidth) * K);
        Inc(Fixed, FCols[C].Width);
      end;
  end;
  for C := 0 to High(FCols) do
    if FCols[C].Visible and FCols[C].Flex then
      FCols[C].Width := Math.Max(FCols[C].MinWidth, (Avail - Fixed) div NFlex);
  UpdateScrollBars;
  Invalidate;
end;

procedure TAuListView.SetColumnMinWidth(I, W: Integer);
begin
  if (I >= 0) and (I <= High(FCols)) then FCols[I].MinWidth := W;
end;

function TAuListView.TotalWidth: Integer;
var
  C, FW: Integer;
begin
  FW := FlexWidth;
  Result := S(16) + MenuGutter;
  for C := 0 to High(FCols) do Inc(Result, ColWidthPx(C, FW));
end;

procedure TAuListView.UpdateScrollBars;
var
  NeedH, NeedV: Boolean;
  SB: Integer;
begin
  SB := S(12);
  NeedV := FRowCount * FRowH > ClientHeight - HeaderH;
  FVScroll.Visible := NeedV;
  NeedH := TotalWidth > ViewW;
  FHScroll.Visible := NeedH;
  NeedV := FRowCount * FRowH > ViewH;
  FVScroll.Visible := NeedV;
  FVScroll.SetBounds(ClientWidth - SB, HeaderH, SB, ClientHeight - HeaderH - IfThen(NeedH, SB, 0));
  FHScroll.SetBounds(0, ClientHeight - SB, ClientWidth - IfThen(NeedV, SB, 0), SB);
  FVScroll.SetParams(FRowCount, VisibleRows);
  FHScroll.SetParams(TotalWidth, ViewW);
  FTop := FVScroll.Position;
  FScrollX := FHScroll.Position;
end;

procedure TAuListView.Changed;
begin
  if Length(FSel) <> FRowCount then SetLength(FSel, FRowCount);
  UpdateScrollBars;
  Invalidate;
end;

procedure TAuListView.SetRowCount(V: Integer);
var
  I: Integer;
begin
  if V < 0 then V := 0;
  FRowCount := V;
  SetLength(FSel, V);
  FSelCount := 0;
  for I := 0 to V - 1 do if FSel[I] then Inc(FSelCount);
  if FFocusRow >= V then FFocusRow := V - 1;
  if FAnchorRow >= V then FAnchorRow := V - 1;
  Changed;
end;

function TAuListView.GetSelected(I: Integer): Boolean;
begin
  Result := (I >= 0) and (I < FRowCount) and FSel[I];
end;

procedure TAuListView.SetSelected(I: Integer; V: Boolean);
begin
  if (I < 0) or (I >= FRowCount) or (FSel[I] = V) then Exit;
  FSel[I] := V;
  if V then Inc(FSelCount) else Dec(FSelCount);
  Invalidate;
end;

procedure TAuListView.ClearSelection;
var
  I: Integer;
begin
  for I := 0 to FRowCount - 1 do FSel[I] := False;
  FSelCount := 0;
  Invalidate;
end;

procedure TAuListView.SelectAll;
var
  I: Integer;
begin
  if not FMultiSelect then Exit;
  for I := 0 to FRowCount - 1 do FSel[I] := True;
  FSelCount := FRowCount;
  Invalidate;
  DoSelChange;
end;

procedure TAuListView.SelectOnly(Row: Integer);
begin
  ClearSelection;
  if (Row >= 0) and (Row < FRowCount) then
  begin
    FSel[Row] := True;
    FSelCount := 1;
    FFocusRow := Row;
    FAnchorRow := Row;
    EnsureVisible(Row);
  end;
  DoSelChange;
end;

function TAuListView.SelectedRows: TIntegerArray;
var
  I, N: Integer;
begin
  Result := nil;
  SetLength(Result, FSelCount);
  N := 0;
  for I := 0 to FRowCount - 1 do
    if FSel[I] and (N < Length(Result)) then
    begin
      Result[N] := I;
      Inc(N);
    end;
  SetLength(Result, N);
end;

procedure TAuListView.SelectRange(A, B: Integer; Add: Boolean);
var
  I, T: Integer;
begin
  if not Add then
  begin
    for I := 0 to FRowCount - 1 do FSel[I] := False;
    FSelCount := 0;
  end;
  if A > B then begin T := A; A := B; B := T; end;
  if A < 0 then A := 0;
  for I := A to Math.Min(B, FRowCount - 1) do
    if not FSel[I] then
    begin
      FSel[I] := True;
      Inc(FSelCount);
    end;
end;

procedure TAuListView.DoSelChange;
begin
  if Assigned(FOnSelChange) then FOnSelChange(Self);
end;

procedure TAuListView.EnsureVisible(Row: Integer);
begin
  if Row < 0 then Exit;
  if Row < FTop then FVScroll.Position := Row
  else if Row >= FTop + VisibleRows then FVScroll.Position := Row - VisibleRows + 1;
  FTop := FVScroll.Position;
  Invalidate;
end;

procedure TAuListView.ScrollChanged(Sender: TObject);
begin
  FTop := FVScroll.Position;
  FScrollX := FHScroll.Position;
  Invalidate;
end;

procedure TAuListView.Resize;
begin
  inherited Resize;
  if FAutoFit and (ClientWidth > S(60)) then FitColumns
  { a wider window: the flex columns take the free room again (narrowing
    keeps the user's widths and scrolls) }
  else if not FFitPending and (ClientWidth > S(60)) and (TotalWidth < ViewW - S(4)) then FitColumns;
  UpdateScrollBars;
end;

procedure TAuListView.ScaleCached(K: Double);
begin
  FRowH := Math.Max(8, Round(FRowH * K));
end;

function TAuListView.RowAt(Y: Integer): Integer;
begin
  if (Y < HeaderH) or (Y >= HeaderH + ViewH) then Exit(-1);
  Result := FTop + (Y - HeaderH) div FRowH;
  if Result >= FRowCount then Result := -1;
end;

function TAuListView.NextVisible(C: Integer): Integer;
begin
  Result := C + 1;
  while (Result <= High(FCols)) and not FCols[Result].Visible do Inc(Result);
  if Result > High(FCols) then Result := -1;
end;

function TAuListView.ColAt(X: Integer; out Edge: Boolean): Integer;
var
  C, FW, CX, W: Integer;
begin
  Edge := False;
  FW := FlexWidth;
  CX := S(8) - FScrollX;
  for C := 0 to High(FCols) do
  begin
    W := ColWidthPx(C, FW);
    if W = 0 then Continue;
    { every right edge can be dragged; in AutoFit lists not the last one,
      which is the edge of the list itself }
    if (Abs(X - (CX + W)) <= S(4)) and not (FAutoFit and (NextVisible(C) < 0)) then
    begin
      Edge := True;
      Exit(C);
    end;
    if (X >= CX) and (X < CX + W) then Exit(C);
    Inc(CX, W);
  end;
  Result := -1;
end;

procedure TAuListView.DoPaint(G: TGfx);
var
  FW, C, X, Y, R, CW, Pad, VW: Integer;
  F, BF, HF: TGfxFont;
  T: string;
  Col, Bg, RowColor: TARGB;
  Handled, Bold, Sel, Foc: Boolean;
  St: UINT;
  Ic: TAuIcon;
begin
  { first fit when the list is shown for the first time - by then the window
    has its final (maybe maximized) size }
  if FFitPending and (ClientWidth > S(60)) then
  begin
    FFitPending := False;
    FitColumns;
  end;
  G.FillRect(0, 0, Width, Height, EffBack);
  FW := FlexWidth;
  VW := ViewW;
  F := UIFont(13);
  BF := UIFont(13, True);
  HF := UIFont(12, True);
  Pad := S(10);
  Foc := Focused;
  { header }
  if FShowHeader then
  begin
    St := G.Save;
    G.IntersectClipRect(0, 0, VW, HeaderH);
    X := S(8) - FScrollX;
    for C := 0 to High(FCols) do
    begin
      CW := ColWidthPx(C, FW);
      if CW = 0 then Continue;
      if C = FHoverHeader then G.FillRound(X + S(2), S(4), CW - S(4), HeaderH - S(8), S(5), clHover);
      if C = FSortCol then Col := clText else Col := clTextDim;
      G.Text(FCols[C].Caption, X + Pad, 0, CW - 2 * Pad - IfThen(C = FSortCol, S(14), 0), HeaderH, HF, Col, FCols[C].Align, 1);
      if C = FSortCol then
      begin
        if FSortDesc then Ic := icChevronDown else Ic := icChevronUp;
        if FCols[C].Align = 2 then DrawIcon(G, Ic, X + S(10), HeaderH / 2, S(11), clAccentText)
        else DrawIcon(G, Ic, X + CW - S(12), HeaderH / 2, S(11), clAccentText);
      end;
      if (C = FHoverHeader) or (C = FResizeCol) then
        G.FillRect(X + CW - 1, S(9), 1, HeaderH - S(18), clBorderHi);
      Inc(X, CW);
    end;
    G.Restore(St);
    if (MenuGutter > 0) and Assigned(FOnHeaderContext) then
    begin
      G.FillRect(VW - S(40), 0, S(40), HeaderH - 1, EffBack);
      if FHoverMenu = -2 then G.FillRound(VW - S(36), S(5), S(30), HeaderH - S(10), S(6), clHover);
      DrawIcon(G, icMore, VW - S(21), HeaderH / 2, S(15), clTextDim);
    end;
    G.FillRect(S(8), HeaderH - 1, VW - S(16), 1, clBorder);
  end;
  { rows }
  St := G.Save;
  G.IntersectClipRect(0, HeaderH, VW, ViewH);
  if (FRowCount = 0) and (FEmptyText <> '') then
    G.Text(FEmptyText, S(20), HeaderH, VW - S(40), ViewH, UIFont(13), clTextFaint, 1, 1, tfWrap);
  HotSet(FHot, FHoverRow, Self);
  Y := HeaderH;
  R := FTop;
  { the wheel's glide: the rows are shifted by what is left of it }
  if (FVScroll.GlideOffset <> 0) and (FRowH > 0) then
  begin
    R := Math.Max(0, FTop + Floor(-FVScroll.GlideOffset / FRowH));
    Y := HeaderH + FVScroll.GlideOffset + (R - FTop) * FRowH;
  end;
  while (R < FRowCount) and (Y < HeaderH + ViewH) do
  begin
    Sel := FSel[R];
    Bg := 0;
    if Sel then
    begin
      if Foc then Bg := clSelection else Bg := clSelectionDim;
    end
    else if HotLevel(FHot, R) > 0 then Bg := Blend(EffBack, clHover, HotLevel(FHot, R));
    if Bg <> 0 then G.FillRound(S(6) - FScrollX, Y + 1, Math.Max(VW, TotalWidth) - S(12), FRowH - 2, S(6), Bg);
    if Foc and KeyboardCues and (R = FFocusRow) then
      G.StrokeRound(S(6) - FScrollX, Y + 1, Math.Max(VW, TotalWidth) - S(12), FRowH - 2, S(6), SF(1.5), clAccent);
    Bold := False;
    RowColor := 0;
    if Assigned(FOnRowStyle) then FOnRowStyle(Self, R, Bold, RowColor);
    X := S(8) - FScrollX;
    for C := 0 to High(FCols) do
    begin
      CW := ColWidthPx(C, FW);
      if CW = 0 then Continue;
      if (X + CW >= 0) and (X < VW) then
      begin
        Handled := False;
        if Assigned(FOnDrawCell) then FOnDrawCell(Self, G, R, C, X, Y, CW, FRowH, Handled);
        if not Handled then
        begin
          T := '';
          if Assigned(FOnGetCell) then FOnGetCell(Self, R, C, T);
          Col := RowColor;
          if Col = 0 then
          begin
            if C = 0 then Col := clText else Col := clTextDim;
            if Sel then Col := clText;
          end;
          if Bold then G.Text(T, X + Pad, Y, CW - 2 * Pad, FRowH, BF, Col, FCols[C].Align, 1)
          else G.Text(T, X + Pad, Y, CW - 2 * Pad, FRowH, F, Col, FCols[C].Align, 1);
        end;
      end;
      Inc(X, CW);
    end;
    if (MenuGutter > 0) and (Sel or (R = FHoverRow)) then
    begin
      if Bg = 0 then Bg := EffBack;
      G.FillRect(VW - S(40), Y + S(3), S(34), FRowH - S(6), Bg);
      if R = FHoverMenu then G.FillRound(VW - S(37), Y + S(4), S(32), FRowH - S(8), S(6), Blend(Bg, clText, 0.12));
      DrawIcon(G, icMore, VW - S(21), Y + FRowH / 2, S(16), clText);
    end;
    Inc(Y, FRowH);
    Inc(R);
  end;
  G.Restore(St);
  if FVScroll.Visible and FHScroll.Visible then
    G.FillRect(ClientWidth - FVScroll.Width, ClientHeight - FHScroll.Height, FVScroll.Width, FHScroll.Height, EffBack);
end;

procedure TAuListView.MoveFocus(N: Integer; Shift: TShiftState);
begin
  if FRowCount = 0 then Exit;
  if N < 0 then N := 0;
  if N >= FRowCount then N := FRowCount - 1;
  FFocusRow := N;
  if (ssShift in Shift) and FMultiSelect and (FAnchorRow >= 0) then
    SelectRange(FAnchorRow, N, ssCtrl in Shift)
  else if not (ssCtrl in Shift) then
  begin
    SelectRange(N, N, False);
    FAnchorRow := N;
  end;
  EnsureVisible(N);
  Invalidate;
  DoSelChange;
end;

procedure TAuListView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R, C: Integer;
  Edge: Boolean;
  P: TPoint;
begin
  inherited MouseDown(Button, Shift, X, Y);
  { the menu buttons }
  if (Button = mbLeft) and InMenuButton(X) then
  begin
    if (Y < HeaderH) and (Y >= 0) then
    begin
      if Assigned(FOnHeaderContext) then FOnHeaderContext(Self, -1, ClientToScreen(Point(ViewW - S(38), HeaderH)));
      Exit;
    end;
    R := RowAt(Y);
    if R >= 0 then
    begin
      if not FSel[R] then
      begin
        SelectRange(R, R, False);
        FAnchorRow := R;
      end;
      FFocusRow := R;
      Invalidate;
      DoSelChange;
      if Assigned(FOnRowContext) then
        FOnRowContext(Self, R, ClientToScreen(Point(ViewW - S(38), HeaderH + (R - FTop + 1) * FRowH)));
      Exit;
    end;
  end;
  if (Y < HeaderH) and (Button = mbRight) then
  begin
    if Assigned(FOnHeaderContext) then FOnHeaderContext(Self, ColAt(X, Edge), ClientToScreen(Point(X, Y)));
    Exit;
  end;
  if (Y < HeaderH) and (Button = mbLeft) then
  begin
    C := ColAt(X, Edge);
    if Edge then
    begin
      FResizeCol := C;
      FResizeStartX := X;
      FResizeStartW := ColWidthPx(C, 0);
    end;
    Exit;
  end;
  R := RowAt(Y);
  FDownRow := R;
  FDownOnSelected := False;
  if R < 0 then
  begin
    if (Button = mbLeft) and not (ssCtrl in Shift) then
    begin
      ClearSelection;
      DoSelChange;
    end;
    Exit;
  end;
  if Button = mbRight then
  begin
    if not FSel[R] then
    begin
      SelectRange(R, R, False);
      FAnchorRow := R;
    end;
    FFocusRow := R;
    Invalidate;
    DoSelChange;
    P := ClientToScreen(Point(X, Y));
    if Assigned(FOnRowContext) then FOnRowContext(Self, R, P);
    Exit;
  end;
  if Button <> mbLeft then Exit;
  FFocusRow := R;
  if (ssShift in Shift) and FMultiSelect and (FAnchorRow >= 0) then
    SelectRange(FAnchorRow, R, ssCtrl in Shift)
  else if (ssCtrl in Shift) and FMultiSelect then
  begin
    SetSelected(R, not FSel[R]);
    FAnchorRow := R;
  end
  else if FSel[R] and (FSelCount > 1) then
    FDownOnSelected := True        // keep the multi-selection until mouse up (drag later)
  else
  begin
    SelectRange(R, R, False);
    FAnchorRow := R;
  end;
  Invalidate;
  DoSelChange;
  if Assigned(FOnCellClick) and not (ssShift in Shift) and not (ssCtrl in Shift) then
  begin
    C := ColAt(X, Edge);
    if (C >= 0) and not Edge then FOnCellClick(Self, R, C, X - ColumnLeft(C));
  end;
end;

function TAuListView.ColumnLeft(C: Integer): Integer;
var
  I, FW: Integer;
begin
  FW := FlexWidth;
  Result := S(8) - FScrollX;
  for I := 0 to Math.Min(C, Length(FCols)) - 1 do Inc(Result, ColWidthPx(I, FW));
end;

procedure TAuListView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  C, R: Integer;
  Edge: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FResizeCol >= 0 then
  begin
    FResizeCol := -1;
    Invalidate;
    if Assigned(FOnColumnsChanged) then FOnColumnsChanged(Self);
    Exit;
  end;
  if (Button = mbLeft) and (Y < HeaderH) and (Y >= 0) then
  begin
    C := ColAt(X, Edge);
    if (C >= 0) and not Edge and Assigned(FOnHeaderClick) then FOnHeaderClick(Self, C);
    Exit;
  end;
  R := RowAt(Y);
  if FDownOnSelected and (R = FDownRow) and (R >= 0) then
  begin
    SelectRange(R, R, False);
    FAnchorRow := R;
    Invalidate;
    DoSelChange;
  end;
  FDownOnSelected := False;
  FDownRow := -1;
end;

procedure TAuListView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  R, C, W: Integer;
  Edge: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  if FResizeCol < 0 then
  begin
    if not InMenuButton(X) then R := -1
    else if (Y < HeaderH) and (Y >= 0) then R := -2
    else R := RowAt(Y);
    if (R = -2) and not Assigned(FOnHeaderContext) then R := -1;
    if R <> FHoverMenu then
    begin
      FHoverMenu := R;
      Invalidate;
    end;
  end;
  if FResizeCol >= 0 then
  begin
    { the dragged edge follows the mouse: only the column left of it changes,
      the columns to the right move along with the edge }
    W := Round((FResizeStartW + X - FResizeStartX) / UIScale);
    FCols[FResizeCol].Width := Math.Max(FCols[FResizeCol].MinWidth, W);
    if FAutoFit then FitColumns;
    UpdateScrollBars;
    Invalidate;
    Exit;
  end;
  if (Y < HeaderH) and (Y >= 0) then
  begin
    C := ColAt(X, Edge);
    if Edge then Cursor := crHSplit else Cursor := crDefault;
    if C <> FHoverHeader then
    begin
      FHoverHeader := C;
      Invalidate;
    end;
    if FHoverRow <> -1 then
    begin
      FHoverRow := -1;
      Invalidate;
    end;
    Exit;
  end;
  Cursor := crDefault;
  if FHoverHeader <> -1 then
  begin
    FHoverHeader := -1;
    Invalidate;
  end;
  R := RowAt(Y);
  if R <> FHoverRow then
  begin
    FHoverRow := R;
    Invalidate;
  end;
end;

procedure TAuListView.MouseLeave;
begin
  inherited MouseLeave;
  FHoverRow := -1;
  FHoverHeader := -1;
  FHoverMenu := -1;
  Invalidate;
end;

procedure TAuListView.DblClick;
var
  P: TPoint;
  R: Integer;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  R := RowAt(P.Y);
  if (R >= 0) and Assigned(FOnActivate) then FOnActivate(Self, R);
end;

procedure TAuListView.KeyDown(var Key: Word; Shift: TShiftState);
var
  P: TPoint;
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  case Key of
    VK_UP: MoveFocus(FFocusRow - 1, Shift);
    VK_DOWN: MoveFocus(FFocusRow + 1, Shift);
    VK_PRIOR: MoveFocus(FFocusRow - VisibleRows + 1, Shift);
    VK_NEXT: MoveFocus(FFocusRow + VisibleRows - 1, Shift);
    VK_HOME: MoveFocus(0, Shift);
    VK_END: MoveFocus(FRowCount - 1, Shift);
    VK_LEFT: FHScroll.Position := FHScroll.Position - S(40);
    VK_RIGHT: FHScroll.Position := FHScroll.Position + S(40);
    VK_SPACE:
      if (ssCtrl in Shift) and (FFocusRow >= 0) then
      begin
        SetSelected(FFocusRow, not FSel[FFocusRow]);
        DoSelChange;
      end
      else
        Exit;
    VK_RETURN: if (FFocusRow >= 0) and Assigned(FOnActivate) then FOnActivate(Self, FFocusRow);
    VK_APPS, VK_F10:
      begin
        if (Key = VK_F10) and not (ssShift in Shift) then Exit;
        if FFocusRow >= 0 then
        begin
          EnsureVisible(FFocusRow);
          P := ClientToScreen(Point(S(40), HeaderH + (FFocusRow - FTop + 1) * FRowH));
          if Assigned(FOnRowContext) then FOnRowContext(Self, FFocusRow, P);
        end;
      end;
  else
    if (ssCtrl in Shift) and (Key = Ord('A')) then SelectAll
    else Exit;
  end;
  Key := 0;
end;

function TAuListView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if ssShift in Shift then FHScroll.Position := FHScroll.Position - Sign(WheelDelta) * S(60)
  else FVScroll.WheelRows(-Sign(WheelDelta) * 3, FRowH);   // the picture glides after it (DoPaint)
  FTop := FVScroll.Position;
  FScrollX := FHScroll.Position;
  Invalidate;
  Result := True;
end;

function TAuListView.PanBy(DX, DY: Integer): Boolean;
var
  N: Integer;
begin
  if not FVScroll.Visible then Exit(inherited PanBy(DX, DY));
  N := PanRows(DY, FRowH);
  if N <> 0 then
  begin
    FVScroll.Position := FVScroll.Position + N;
    FTop := FVScroll.Position;
    Invalidate;
  end;
  Result := True;
end;

function TAuListView.ScrollOffset: Integer;
begin
  Result := FTop;
end;

{ ==== TAuTileView ==== }

constructor TAuTileView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FWantKeys := True;
  TabStop := True;
  FIndex := -1;
  FHoverIdx := -1;
  FTileW := 176;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Visible := False;
  FScroll.SmallStep := S(20);
  FScroll.OnScroll := @ScrollChanged;
end;

procedure TAuTileView.Layout(out Cols: Integer; out CellW, CellH, Gap: Single);
var
  Avail: Single;
begin
  Gap := S(20);
  Avail := ClientWidth - S(12) - 2 * S(16);
  Cols := Math.Max(1, Trunc((Avail + Gap) / (S(FTileW) + Gap)));
  CellW := (Avail - (Cols - 1) * Gap) / Cols;
  CellH := CellW + S(52);
end;

function TAuTileView.ContentH: Integer;
var
  Cols, Rows: Integer;
  CW, CH, Gap: Single;
begin
  Layout(Cols, CW, CH, Gap);
  Rows := (FCount + Cols - 1) div Cols;
  Result := Ceil(Rows * (CH + Gap)) + S(16);
end;

procedure TAuTileView.UpdateScroll;
begin
  FScroll.SetBounds(ClientWidth - S(12), 0, S(12), ClientHeight);
  FScroll.SetParams(ContentH, ClientHeight);
  FScroll.Visible := FScroll.NeedScroll;
  FScrollY := FScroll.Position;
end;

procedure TAuTileView.Changed;
begin
  UpdateScroll;
  Invalidate;
end;

procedure TAuTileView.SetCount(V: Integer);
begin
  FCount := Math.Max(0, V);
  if FIndex >= FCount then FIndex := FCount - 1;
  Changed;
end;

procedure TAuTileView.SetIndex(V: Integer);
begin
  if V >= FCount then V := FCount - 1;
  if V < -1 then V := -1;
  if V = FIndex then Exit;
  FIndex := V;
  EnsureVisible(V);
  Invalidate;
  if Assigned(FOnSelect) then FOnSelect(Self);
end;

procedure TAuTileView.ScrollChanged(Sender: TObject);
begin
  FScrollY := FScroll.Position;
  Invalidate;
end;

procedure TAuTileView.Resize;
begin
  inherited Resize;
  UpdateScroll;
end;

procedure TAuTileView.EnsureVisible(I: Integer);
var
  Cols, Row: Integer;
  CW, CH, Gap, T: Single;
begin
  if I < 0 then Exit;
  Layout(Cols, CW, CH, Gap);
  Row := I div Cols;
  T := S(16) + Row * (CH + Gap);
  if T < FScrollY then FScroll.Position := Round(T) - S(8)
  else if T + CH > FScrollY + ClientHeight then FScroll.Position := Round(T + CH - ClientHeight) + S(8);
  FScrollY := FScroll.Position;
end;

{ the menu button (three dots) in the top right corner of tile I }
function TAuTileView.MenuHit(I, X, Y: Integer): Boolean;
var
  Cols: Integer;
  CW, CH, Gap, CX, CY: Single;
begin
  Result := False;
  if (I < 0) or not Assigned(FOnContext) then Exit;
  Layout(Cols, CW, CH, Gap);
  CX := S(16) + (I mod Cols) * (CW + Gap) + CW - S(22);
  CY := S(16) + (I div Cols) * (CH + Gap) - FScrollY + S(22);
  Result := Sqr(X - CX) + Sqr(Y - CY) <= Sqr(S(17));
end;

function TAuTileView.IndexAt(X, Y: Integer; out IsPlay: Boolean): Integer;
var
  Cols, Col, Row: Integer;
  CW, CH, Gap, LX, LY, PX, PY: Single;
begin
  IsPlay := False;
  Result := -1;
  Layout(Cols, CW, CH, Gap);
  LX := X - S(16);
  LY := Y + FScrollY - S(16);
  if (LX < 0) or (LY < 0) then Exit;
  Col := Trunc(LX / (CW + Gap));
  Row := Trunc(LY / (CH + Gap));
  if (Col >= Cols) or (LX - Col * (CW + Gap) > CW) or (LY - Row * (CH + Gap) > CH) then Exit;
  Result := Row * Cols + Col;
  if Result >= FCount then Exit(-1);
  PX := Col * (CW + Gap) + CW - S(28);
  PY := Row * (CH + Gap) + CW - S(28);
  IsPlay := Sqr(LX - PX) + Sqr(LY - PY) <= Sqr(S(20));
end;

procedure TAuTileView.DoPaint(G: TGfx);
var
  Cols, I, First, Last: Integer;
  CW, CH, Gap, X, Y: Single;
  Title, Sub: string;
  Bmp: TGfxBitmap;
  Hot: Boolean;
  PB: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if (FCount = 0) and (FEmptyText <> '') then
  begin
    G.Text(FEmptyText, S(20), 0, Width - S(40), Height, UIFont(13), clTextFaint, 1, 1, tfWrap);
    Exit;
  end;
  Layout(Cols, CW, CH, Gap);
  First := Math.Max(0, Trunc((FScrollY - S(16)) / (CH + Gap))) * Cols;
  Last := Math.Min(FCount - 1, (Trunc((FScrollY + ClientHeight) / (CH + Gap)) + 1) * Cols + Cols - 1);
  for I := First to Last do
  begin
    X := S(16) + (I mod Cols) * (CW + Gap);
    Y := S(16) + (I div Cols) * (CH + Gap) - FScrollY;
    Title := '';
    Sub := '';
    Bmp := nil;
    if Assigned(FOnGetTile) then FOnGetTile(Self, I, Title, Sub, Bmp);
    Hot := I = FHoverIdx;
    if (I = FIndex) or Hot then
    begin
      if I = FIndex then PB := Blend(EffBack, clText, 0.07) else PB := Blend(EffBack, clText, 0.04);
      G.FillRound(X - S(8), Y - S(8), CW + S(16), CH + S(8), S(10), PB);
    end;
    if (I = FIndex) and ShowFocus then
      G.StrokeRound(X - S(8), Y - S(8), CW + S(16), CH + S(8), S(10), SF(1.8), clAccent);
    DrawTileArt(G, Bmp, X, Y, CW, CW, S(8), Title + '|' + Sub, FRoundArt);
    if Hot and Assigned(FOnPlay) then
    begin
      if FHoverPlay then PB := clAccentHi else PB := clAccent;
      G.FillCircle(X + CW - S(28), Y + CW - S(28), S(20), WithAlpha(clShadow, $50));
      G.FillCircle(X + CW - S(28), Y + CW - S(29), S(19), PB);
      DrawIcon(G, icPlay, X + CW - S(27), Y + CW - S(29), S(16), clOnAccent);
    end;
    if (Hot or (I = FIndex)) and Assigned(FOnContext) then
    begin
      if Hot and FHoverMenu then PB := $C0000000 else PB := $80000000;
      G.FillCircle(X + CW - S(22), Y + S(22), S(15), PB);
      DrawIcon(G, icMore, X + CW - S(22), Y + S(22), S(16), $FFFFFFFF);
    end;
    if FRoundArt then
    begin
      G.Text(Title, X, Y + CW + S(8), CW, S(20), UIFont(13.5, True), clText, 1, 1);
      G.Text(Sub, X, Y + CW + S(28), CW, S(18), UIFont(12), clTextDim, 1, 1);
    end
    else
    begin
      G.Text(Title, X + S(2), Y + CW + S(8), CW - S(4), S(20), UIFont(13.5, True), clText, 0, 1);
      G.Text(Sub, X + S(2), Y + CW + S(28), CW - S(4), S(18), UIFont(12), clTextDim, 0, 1);
    end;
  end;
end;

procedure TAuTileView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  IsPlay: Boolean;
  P: TPoint;
begin
  inherited MouseDown(Button, Shift, X, Y);
  I := IndexAt(X, Y, IsPlay);
  if I < 0 then Exit;
  ItemIndex := I;
  if (Button = mbLeft) and MenuHit(I, X, Y) then
  begin
    P := ClientToScreen(Point(X - S(8), Y + S(14)));
    FOnContext(Self, I, P);
    Exit;
  end;
  if Button = mbRight then
  begin
    P := ClientToScreen(Point(X, Y));
    if Assigned(FOnContext) then FOnContext(Self, I, P);
  end;
end;

procedure TAuTileView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  IsPlay: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  I := IndexAt(X, Y, IsPlay);
  if (I >= 0) and IsPlay and not MenuHit(I, X, Y) and Assigned(FOnPlay) then FOnPlay(Self, I);
end;

procedure TAuTileView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  IsPlay: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  I := IndexAt(X, Y, IsPlay);
  if (I <> FHoverIdx) or (IsPlay <> FHoverPlay) or (MenuHit(I, X, Y) <> FHoverMenu) then
  begin
    FHoverIdx := I;
    FHoverPlay := IsPlay;
    FHoverMenu := MenuHit(I, X, Y);
    if IsPlay or FHoverMenu then Cursor := crHandPoint else Cursor := crDefault;
    Invalidate;
  end;
end;

procedure TAuTileView.MouseLeave;
begin
  inherited MouseLeave;
  FHoverIdx := -1;
  FHoverPlay := False;
  Invalidate;
end;

procedure TAuTileView.DblClick;
var
  P: TPoint;
  I: Integer;
  IsPlay: Boolean;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  I := IndexAt(P.X, P.Y, IsPlay);
  if (I >= 0) and not IsPlay and not MenuHit(I, P.X, P.Y) and Assigned(FOnActivate) then FOnActivate(Self, I);
end;

procedure TAuTileView.KeyDown(var Key: Word; Shift: TShiftState);
var
  Cols, PageRows: Integer;
  CW, CH, Gap: Single;
  P: TPoint;
begin
  inherited KeyDown(Key, Shift);
  if (Key = 0) or (FCount = 0) then Exit;
  Layout(Cols, CW, CH, Gap);
  PageRows := Math.Max(1, Trunc(ClientHeight / (CH + Gap)));
  case Key of
    VK_LEFT: ItemIndex := Math.Max(0, FIndex - 1);
    VK_RIGHT: ItemIndex := FIndex + 1;
    VK_UP: if FIndex < 0 then ItemIndex := 0 else ItemIndex := Math.Max(0, FIndex - Cols);
    VK_DOWN: if FIndex < 0 then ItemIndex := 0 else ItemIndex := Math.Min(FCount - 1, FIndex + Cols);
    VK_PRIOR: ItemIndex := Math.Max(0, FIndex - Cols * PageRows);
    VK_NEXT: ItemIndex := Math.Min(FCount - 1, FIndex + Cols * PageRows);
    VK_HOME: ItemIndex := 0;
    VK_END: ItemIndex := FCount - 1;
    VK_RETURN:
      if FIndex >= 0 then
      begin
        if (ssShift in Shift) and Assigned(FOnPlay) then FOnPlay(Self, FIndex)
        else if Assigned(FOnActivate) then FOnActivate(Self, FIndex);
      end;
    VK_APPS:
      if (FIndex >= 0) and Assigned(FOnContext) then
      begin
        P := ClientToScreen(Point(Round(S(16) + (FIndex mod Cols) * (CW + Gap) + CW / 2),
          Round(S(16) + (FIndex div Cols) * (CH + Gap) - FScrollY + CW / 2)));
        FOnContext(Self, FIndex, P);
      end;
  else
    Exit;
  end;
  Key := 0;
end;

function TAuTileView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  FScroll.WheelBy(-Sign(WheelDelta) * S(90));
  FScrollY := FScroll.Position;
  Invalidate;
  Result := True;
end;

function TAuTileView.PanBy(DX, DY: Integer): Boolean;
begin
  if not FScroll.Visible then Exit(inherited PanBy(DX, DY));
  if DY <> 0 then
  begin
    FScroll.Position := FScroll.Position - DY;
    FScrollY := FScroll.Position;
    Invalidate;
  end;
  Result := True;
end;

function TAuTileView.ScrollOffset: Integer;
begin
  Result := FScrollY;
end;

{ ==== TAuNavRail ==== }

constructor TAuNavRail.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crPanel;
  FWantKeys := True;
  TabStop := True;
  FHoverIdx := -1;
  Width := ExpandedWidth;
end;

function TAuNavRail.ExpandedWidth: Integer;
begin
  Result := S(224);
end;

function TAuNavRail.CollapsedWidth: Integer;
begin
  Result := S(64);
end;

function TAuNavRail.AddItem(const ACaption: string; AIcon: TAuIcon): Integer;
begin
  Result := Length(FItems);
  SetLength(FItems, Result + 1);
  FItems[Result].Caption := ACaption;
  FItems[Result].Icon := AIcon;
  FItems[Result].IsHeader := False;
  Invalidate;
end;

procedure TAuNavRail.AddHeader(const ACaption: string);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N].Caption := ACaption;
  FItems[N].Icon := icNone;
  FItems[N].IsHeader := True;
end;

procedure TAuNavRail.SetBadge(I: Integer; const ABadge: string);
begin
  if (I >= 0) and (I <= High(FItems)) then FItems[I].Badge := ABadge;
  Invalidate;
end;

function TAuNavRail.ItemCaption(I: Integer): string;
begin
  if (I >= 0) and (I <= High(FItems)) then Result := FItems[I].Caption else Result := '';
end;

function TAuNavRail.ItemH(I: Integer): Integer;
begin
  if FItems[I].IsHeader then
  begin
    if FCollapsed then Result := S(17) else Result := S(36);
  end
  else
    Result := S(40);
end;

function TAuNavRail.ItemTop(I: Integer): Integer;
var
  J: Integer;
begin
  Result := S(72);
  for J := 0 to I - 1 do Inc(Result, ItemH(J));
end;

function TAuNavRail.ItemAt(Y: Integer): Integer;
var
  I, T: Integer;
begin
  T := S(72);
  for I := 0 to High(FItems) do
  begin
    if (Y >= T) and (Y < T + ItemH(I)) then
    begin
      if FItems[I].IsHeader then Exit(-1);
      Exit(I);
    end;
    Inc(T, ItemH(I));
  end;
  Result := -1;
end;

function TAuNavRail.ToggleRect: TRect;
begin
  Result := Rect(S(12), Height - S(52), S(52), Height - S(12));
end;

procedure TAuNavRail.SetIndex(V: Integer);
begin
  if (V < 0) or (V > High(FItems)) or FItems[V].IsHeader or (V = FIndex) then Exit;
  FIndex := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TAuNavRail.SetCollapsed(V: Boolean);
begin
  if V = FCollapsed then Exit;
  FCollapsed := V;
  if V then Width := CollapsedWidth else Width := ExpandedWidth;
  Invalidate;
end;

procedure TAuNavRail.DoPaint(G: TGfx);
var
  I, T, H: Integer;
  C: TARGB;
  X0, W: Single;
  Sel: Boolean;
  TR: TRect;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  G.FillRect(Width - 1, 0, 1, Height, clBorder);
  { brand }
  G.FillRoundGrad(S(18), S(20), S(28), S(28), S(8), clAccentHi, clAccentLo, True);
  DrawIcon(G, icWave, S(32), S(34), S(16), clOnAccent);
  if not FCollapsed then
    G.Text(FTitle, S(56), S(18), Width - S(64), S(32), UIFont(17, True), clText, 0, 1);
  X0 := S(10);
  W := Width - S(20);
  for I := 0 to High(FItems) do
  begin
    T := ItemTop(I);
    H := ItemH(I);
    if FItems[I].IsHeader then
    begin
      if FCollapsed then G.FillRect(S(20), T + H / 2, Width - S(40), 1, clBorder)
      else G.Text(UpperCase(FItems[I].Caption), S(22), T + S(12), W, H - S(12), UIFont(10.5, True), clTextFaint, 0, 1);
      Continue;
    end;
    Sel := I = FIndex;
    if Sel then G.FillRound(X0, T + S(2), W, H - S(4), S(8), Blend(EffBack, clText, 0.07))
    else if I = FHoverIdx then G.FillRound(X0, T + S(2), W, H - S(4), S(8), Blend(EffBack, clText, 0.045));
    if Sel then G.FillRound(X0 - S(4), T + S(12), S(3), H - S(24), SF(1.5), clAccent);
    if Sel and ShowFocus then G.StrokeRound(X0, T + S(2), W, H - S(4), S(8), SF(1.6), clAccent);
    if Sel then C := clText else if I = FHoverIdx then C := clText else C := clTextDim;
    if FCollapsed then
    begin
      if Sel then DrawIcon(G, FItems[I].Icon, Width / 2, T + H / 2, S(18), clAccentText)
      else DrawIcon(G, FItems[I].Icon, Width / 2, T + H / 2, S(18), C);
    end
    else
    begin
      if Sel then DrawIcon(G, FItems[I].Icon, S(32), T + H / 2, S(18), clAccentText)
      else DrawIcon(G, FItems[I].Icon, S(32), T + H / 2, S(18), C);
      G.Text(FItems[I].Caption, S(54), T, W - S(54), H, UIFont(13.5, Sel), C, 0, 1);
      if FItems[I].Badge <> '' then
        G.Text(FItems[I].Badge, S(54), T, W - S(56), H, UIFont(11.5), clTextFaint, 2, 1);
    end;
  end;
  TR := ToggleRect;
  if FHoverIdx = -2 then G.FillRound(TR.Left, TR.Top, TR.Right - TR.Left, TR.Bottom - TR.Top, S(8), clHover);
  DrawIcon(G, icSidebar, (TR.Left + TR.Right) / 2, (TR.Top + TR.Bottom) / 2, S(18), clTextDim);
end;

procedure TAuNavRail.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if PtInRect(ToggleRect, Point(X, Y)) then
  begin
    Collapsed := not Collapsed;
    if Assigned(FOnToggle) then FOnToggle(Self);
    Exit;
  end;
  I := ItemAt(Y);
  if I >= 0 then ItemIndex := I;
end;

procedure TAuNavRail.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  NewHint: string;
begin
  inherited MouseMove(Shift, X, Y);
  if PtInRect(ToggleRect, Point(X, Y)) then I := -2 else I := ItemAt(Y);
  if I <> FHoverIdx then
  begin
    FHoverIdx := I;
    Invalidate;
    NewHint := '';
    if I = -2 then
    begin
      if FCollapsed then NewHint := 'Expand sidebar' else NewHint := 'Collapse sidebar';
    end
    else if FCollapsed and (I >= 0) then NewHint := FItems[I].Caption;
    if NewHint <> Hint then
    begin
      Application.CancelHint;
      Hint := NewHint;
      ShowHint := NewHint <> '';
    end;
  end;
end;

procedure TAuNavRail.MouseLeave;
begin
  inherited MouseLeave;
  FHoverIdx := -1;
  Invalidate;
end;

procedure TAuNavRail.KeyDown(var Key: Word; Shift: TShiftState);
var
  I: Integer;
begin
  inherited KeyDown(Key, Shift);
  I := FIndex;
  case Key of
    VK_UP:
      repeat
        Dec(I);
      until (I < 0) or not FItems[I].IsHeader;
    VK_DOWN:
      repeat
        Inc(I);
      until (I > High(FItems)) or not FItems[I].IsHeader;
    VK_HOME: begin I := 0; while (I <= High(FItems)) and FItems[I].IsHeader do Inc(I); end;
    VK_END: I := High(FItems);
  else
    Exit;
  end;
  Key := 0;
  if (I >= 0) and (I <= High(FItems)) then ItemIndex := I;
end;

end.
