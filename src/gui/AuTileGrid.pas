unit AuTileGrid;

{ ==============================================================================
  AulumicNS - AuTileGrid
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TAuTileGrid - a grid of tiles: a square picture with two lines of text
  under it, as many per row as the width gives. The tiles stretch to fill
  the row. The smallest size is a list: one tile per row, a small picture
  with the two lines beside it.

  The grid owns no data. The owner sets Count and answers the events:
  OnInfo (the texts of a tile), OnArt (its picture; it may load only a few
  per paint and report the rest as pending - the grid then paints again),
  OnTypeText (what typing a letter is matched against).

  Features: multi-selection, keyboard, type-ahead, a context menu event,
  dragging the selection to another control (LCL drag and drop: the target
  receives this grid as Source), Ctrl + mouse wheel for the tile size, the
  full text as a hint when a line is cut, touch.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType, LazUTF8,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls, AuLists;

const
  TILE_SIZE_LIST = 0;        // a list: a small picture, the text beside it
  TILE_SIZE_MAX = 3;
  TILE_SIZE_DEFAULT = 2;
  { the two buttons on a tile }
  TILE_BTN_NONE = 0;
  TILE_BTN_PLAY = 1;
  TILE_BTN_MENU = 2;

type
  TAuTileInfo = record
    Title, Sub: string;
    ArtKey: string;          // colours the placeholder of a tile without a picture
    Dim: Boolean;            // drawn faint
  end;

  TAuTileIntArray = array of Integer;
  TAuTileInfoEvent = procedure(Sender: TObject; Index: Integer; out Info: TAuTileInfo) of object;
  { the picture of a tile, or nil. ABudget: how many pictures may still be
    loaded during this paint (the owner counts it down); a picture that has
    to wait is reported with APending }
  TAuTileArtEvent = function(Sender: TObject; Index: Integer; var ABudget: Integer;
    out APending: Boolean): TGfxBitmap of object;
  TAuTileEvent = procedure(Sender: TObject; Index: Integer) of object;
  TAuTileContextEvent = procedure(Sender: TObject; Index: Integer; ScreenPt: TPoint) of object;
  TAuTileTextEvent = function(Sender: TObject; Index: Integer): string of object;

  { TAuTileGrid }

  TAuTileGrid = class(TAuControl)
  private
    FTileCount: Integer;
    FSel: array of Boolean;
    FFocusIdx, FAnchorIdx, FHoverIdx, FDownIdx: Integer;
    FHot: TAuHotFade;
    FScroll: TAuScrollBar;
    FTileSize: Integer;
    FTextSize: Single;
    FCols, FCellW, FCellH, FArt, FPad, FPadTop, FGap, FLineH: Integer;
    FTopPad: Integer;                // the room above the first row (unscaled)
    FDownPt: TPoint;
    FDownOnSelected, FDragArmed, FDragEnabled, FMoreQueued: Boolean;
    FHoverBtn, FDownBtn: Integer;    // TILE_BTN_*: under the pointer, pressed
    FEmptyText, FTypeText: string;
    FTypeTick: QWord;
    FOnInfo: TAuTileInfoEvent;
    FOnArt: TAuTileArtEvent;
    FOnActivate, FOnSizeWheel, FOnTilePlay: TAuTileEvent;
    FOnTileContext: TAuTileContextEvent;
    FOnTypeText: TAuTileTextEvent;
    FOnSelChange, FOnPrepare: TNotifyEvent;
    procedure ScrollChanged(Sender: TObject);
    procedure Layout;
    procedure LayoutKeepingTop;
    function ViewW: Integer;
    function TextW: Integer;
    function HighlightRect(I: Integer): TRect;
    procedure SetTileSize(V: Integer);
    procedure SetTextSize(V: Single);
    procedure SetTopPad(V: Integer);
    procedure SelectRange(A, B: Integer; Add: Boolean);
    procedure MoveFocus(I: Integer; Shift: TShiftState);
    procedure DoSelChange;
    procedure TypeAhead(const Ch: string);
    procedure MoreArt(Data: PtrInt);
    procedure GridShowHint(Sender: TObject; HintInfo: PHintInfo);
    function GetSelected(I: Integer): Boolean;
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
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DpiChanged; override;
    function ScrollOffset: Integer; override;
    { a new set of tiles: nothing selected, scrolled to the top }
    procedure SetCount(N: Integer);
    { the same tiles in another order or with other texts }
    procedure Changed;
    function IndexAt(X, Y: Integer): Integer;
    { the play and the menu button: on the tile under the pointer and on the
      selected tile that has the focus }
    function ShowsButtons(I: Integer): Boolean;
    procedure ButtonRects(I: Integer; out APlay, AMenu: TRect);
    { which button of which tile is at this point (TILE_BTN_NONE: none) }
    function ButtonAt(X, Y: Integer; out AIndex: Integer): Integer;
    { the place of a tile's picture and text (client coordinates) }
    function TileRect(I: Integer): TRect;
    procedure EnsureVisible(I: Integer);
    { the first tile of the top row in view (-1 without tiles) and how many
      pixels of that row are scrolled out }
    function TopTile(out AOffset: Integer): Integer;
    { the row of tile I at the top, AOffset pixels of it scrolled out }
    procedure ScrollToTile(I: Integer; AOffset: Integer = 0);
    procedure SelectOnly(I: Integer);
    { after SetCount: this selection and focus again, scrolled to AScroll
      (below 0: to where the focus is) }
    procedure RestoreState(const ASel: TAuTileIntArray; AFocus, AScroll: Integer);
    function SelectedIndexes: TAuTileIntArray;
    function SelCount: Integer;
    property Count: Integer read FTileCount;
    { the side of a tile's picture in pixels }
    property ArtPixels: Integer read FArt;
    { the height of a row of tiles in pixels }
    property RowHeight: Integer read FCellH;
    property Selected[I: Integer]: Boolean read GetSelected;
    property FocusIndex: Integer read FFocusIdx;
    property TileSize: Integer read FTileSize write SetTileSize;
    property TextSize: Single read FTextSize write SetTextSize;
    { the room above the first row (unscaled pixels) }
    property TopPad: Integer read FTopPad write SetTopPad;
    property DragEnabled: Boolean read FDragEnabled write FDragEnabled;
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnInfo: TAuTileInfoEvent read FOnInfo write FOnInfo;
    property OnArt: TAuTileArtEvent read FOnArt write FOnArt;
    { called before a paint draws anything: the owner may free pictures here }
    property OnPrepare: TNotifyEvent read FOnPrepare write FOnPrepare;
    property OnActivate: TAuTileEvent read FOnActivate write FOnActivate;
    { the play button of a tile was clicked (the tile is selected then) }
    property OnTilePlay: TAuTileEvent read FOnTilePlay write FOnTilePlay;
    property OnTileContext: TAuTileContextEvent read FOnTileContext write FOnTileContext;
    property OnTypeText: TAuTileTextEvent read FOnTypeText write FOnTypeText;
    property OnSelChange: TNotifyEvent read FOnSelChange write FOnSelChange;
    { Ctrl + wheel: Index is +1 (larger) or -1 (smaller) }
    property OnSizeWheel: TAuTileEvent read FOnSizeWheel write FOnSizeWheel;
  end;

implementation

const
  { the least width of a tile's picture per size (unscaled); the tiles of a
    row share what is left over }
  TILE_MIN_W: array[1..TILE_SIZE_MAX] of Integer = (84, 112, 148);
  ART_LOADS_PER_PAINT = 6;

constructor TAuTileGrid.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FGpuPaint := True;
  FWantKeys := True;
  TabStop := True;
  FTextSize := 13;
  FTopPad := 10;
  FTileSize := TILE_SIZE_DEFAULT;
  FFocusIdx := -1;
  FAnchorIdx := -1;
  FHoverIdx := -1;
  FDownIdx := -1;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Visible := False;
  FScroll.OnScroll := @ScrollChanged;
  ShowHint := True;
  OnShowHint := @GridShowHint;
  Layout;
end;

destructor TAuTileGrid.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

function TAuTileGrid.ViewW: Integer;
begin
  { the scroll bar's strip is always kept free: the tiles do not change
    their size when the bar comes and goes }
  Result := Math.Max(S(40), ClientWidth - S(12));
end;

{ the width the two text lines of a tile have }
function TAuTileGrid.TextW: Integer;
begin
  if FTileSize = TILE_SIZE_LIST then Result := Math.Max(S(20), ViewW - FPad * 2 - FArt - S(12))
  else Result := FArt;
end;

procedure TAuTileGrid.Layout;
var
  W, MinW, Rows, Total: Integer;
begin
  FLineH := Math.Max(S(12), Round(SF(FTextSize * FontScale) * 1.42));
  FPad := S(10);
  FPadTop := S(FTopPad);
  FGap := S(12);
  W := Math.Max(S(40), ViewW - FPad * 2);
  if FTileSize = TILE_SIZE_LIST then
  begin
    FCols := 1;
    FCellW := W;
    FArt := Math.Max(S(34), FLineH * 2);
    FCellH := FArt + S(8);
  end
  else
  begin
    MinW := S(TILE_MIN_W[EnsureRange(FTileSize, 1, TILE_SIZE_MAX)]);
    FCols := Math.Max(1, (W + FGap) div (MinW + FGap));
    FCellW := (W + FGap) div FCols;
    FArt := FCellW - FGap;
    FCellH := FArt + S(6) + FLineH * 2 + S(14);
  end;
  Rows := (FTileCount + FCols - 1) div FCols;
  Total := Rows * FCellH + FPadTop + FPad;
  FScroll.Visible := Total > ClientHeight;
  FScroll.SetBounds(ClientWidth - S(12), 0, S(12), ClientHeight);
  FScroll.SetParams(Total, ClientHeight);
  FScroll.SmallStep := FCellH;
end;

procedure TAuTileGrid.Resize;
begin
  inherited Resize;
  LayoutKeepingTop;
end;

procedure TAuTileGrid.ScaleCached(K: Double);
begin
  Layout;
end;

procedure TAuTileGrid.DpiChanged;
begin
  Layout;
  inherited DpiChanged;
end;

procedure TAuTileGrid.ScrollChanged(Sender: TObject);
begin
  Invalidate;
end;

function TAuTileGrid.ScrollOffset: Integer;
begin
  Result := FScroll.Position;
end;

function TAuTileGrid.TopTile(out AOffset: Integer): Integer;
var
  Row: Integer;
begin
  AOffset := 0;
  if (FTileCount = 0) or (FCellH <= 0) or (FCols <= 0) then Exit(-1);
  Row := Math.Max(0, FScroll.Position) div FCellH;
  AOffset := Math.Max(0, FScroll.Position) - Row * FCellH;
  Result := Math.Min(Row * FCols, FTileCount - 1);
end;

procedure TAuTileGrid.ScrollToTile(I: Integer; AOffset: Integer);
begin
  if (I < 0) or (I >= FTileCount) or (FCols <= 0) then Exit;
  FScroll.Position := (I div FCols) * FCellH + EnsureRange(AOffset, 0, Math.Max(0, FCellH - 1));
  Invalidate;
end;

{ a layout with other columns or another tile height: the tiles that were at
  the top stay there }
procedure TAuTileGrid.LayoutKeepingTop;
var
  Keep, Off, OldH: Integer;
begin
  Keep := TopTile(Off);
  OldH := FCellH;
  Layout;
  if Keep < 0 then Exit;
  if (OldH > 0) and (FCellH <> OldH) then Off := Int64(Off) * FCellH div OldH;
  ScrollToTile(Keep, Off);
end;

procedure TAuTileGrid.SetTileSize(V: Integer);
begin
  V := EnsureRange(V, TILE_SIZE_LIST, TILE_SIZE_MAX);
  if V = FTileSize then Exit;
  FTileSize := V;
  LayoutKeepingTop;
  Invalidate;
end;

procedure TAuTileGrid.SetTextSize(V: Single);
begin
  V := EnsureRange(V, 8, 28);
  if V = FTextSize then Exit;
  FTextSize := V;
  Layout;
  Invalidate;
end;

procedure TAuTileGrid.SetTopPad(V: Integer);
begin
  if V = FTopPad then Exit;
  FTopPad := V;
  Layout;
  Invalidate;
end;

procedure TAuTileGrid.SetCount(N: Integer);
var
  I: Integer;
begin
  FTileCount := Math.Max(0, N);
  SetLength(FSel, FTileCount);
  for I := 0 to FTileCount - 1 do FSel[I] := False;
  if FTileCount > 0 then FFocusIdx := 0 else FFocusIdx := -1;
  FAnchorIdx := FFocusIdx;
  FHoverIdx := -1;
  FDownIdx := -1;
  FTypeText := '';
  Layout;
  FScroll.Position := 0;
  Invalidate;
end;

procedure TAuTileGrid.Changed;
begin
  Layout;
  Invalidate;
end;

function TAuTileGrid.GetSelected(I: Integer): Boolean;
begin
  Result := (I >= 0) and (I < FTileCount) and FSel[I];
end;

function TAuTileGrid.SelectedIndexes: TAuTileIntArray;
var
  I, N: Integer;
begin
  Result := nil;
  SetLength(Result, FTileCount);
  N := 0;
  for I := 0 to FTileCount - 1 do
    if FSel[I] then
    begin
      Result[N] := I;
      Inc(N);
    end;
  SetLength(Result, N);
end;

function TAuTileGrid.SelCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FTileCount - 1 do
    if FSel[I] then Inc(Result);
end;

function TAuTileGrid.TileRect(I: Integer): TRect;
var
  X, Y: Integer;
begin
  if (I < 0) or (I >= FTileCount) or (FCols <= 0) then Exit(Rect(0, 0, 0, 0));
  X := FPad + (I mod FCols) * FCellW;
  Y := FPadTop + (I div FCols) * FCellH - FScroll.Position;
  if FTileSize = TILE_SIZE_LIST then Result := Rect(X, Y, X + FCellW, Y + FCellH)
  else Result := Rect(X, Y, X + FArt, Y + FCellH - S(14));
end;

{ what is filled for a selected or hovered tile }
function TAuTileGrid.HighlightRect(I: Integer): TRect;
begin
  Result := TileRect(I);
  if FTileSize = TILE_SIZE_LIST then
    Result := Rect(S(4), Result.Top + 1, ViewW - S(4), Result.Bottom - 1)
  else
    Result := Rect(Result.Left - S(5), Result.Top - S(5), Result.Right + S(5), Result.Bottom + S(5));
end;

function TAuTileGrid.ShowsButtons(I: Integer): Boolean;
begin
  Result := (I >= 0) and (I < FTileCount) and ((I = FHoverIdx) or (FSel[I] and (I = FFocusIdx)));
end;

procedure TAuTileGrid.ButtonRects(I: Integer; out APlay, AMenu: TRect);
var
  R: TRect;
  D, Y: Integer;
begin
  R := TileRect(I);
  if FTileSize = TILE_SIZE_LIST then
  begin
    { a list: at the right end of the row }
    D := Math.Min(S(26), FCellH - S(8));
    Y := R.Top + (FCellH - D) div 2;
    AMenu := Rect(ViewW - S(10) - D, Y, ViewW - S(10), Y + D);
    APlay := Rect(AMenu.Left - S(6) - D, Y, AMenu.Left - S(6), Y + D);
  end
  else
  begin
    { on the lower edge of the picture: play at the left, the menu at the right }
    D := Math.Max(S(8), Math.Min(S(28), (FArt - S(16)) div 2));   // (two of them fit side by side)
    Y := R.Top + FArt - S(6) - D;
    APlay := Rect(R.Left + S(6), Y, R.Left + S(6) + D, Y + D);
    AMenu := Rect(R.Left + FArt - S(6) - D, Y, R.Left + FArt - S(6), Y + D);
  end;
end;

function TAuTileGrid.ButtonAt(X, Y: Integer; out AIndex: Integer): Integer;
var
  RP, RM: TRect;
begin
  Result := TILE_BTN_NONE;
  AIndex := IndexAt(X, Y);
  if not ShowsButtons(AIndex) then Exit;
  ButtonRects(AIndex, RP, RM);
  if PtInRect(RP, Point(X, Y)) then Result := TILE_BTN_PLAY
  else if PtInRect(RM, Point(X, Y)) then Result := TILE_BTN_MENU;
end;

function TAuTileGrid.IndexAt(X, Y: Integer): Integer;
var
  PX, PY, Col: Integer;
begin
  Result := -1;
  if (FCellH <= 0) or (FCellW <= 0) or (X >= ViewW) then Exit;
  PY := Y + FScroll.Position - FPadTop;
  PX := X - FPad;
  if PY < 0 then Exit;
  if FTileSize = TILE_SIZE_LIST then Col := 0
  else
  begin
    if PX < 0 then Exit;
    Col := PX div FCellW;
    if Col >= FCols then Exit;
  end;
  Result := (PY div FCellH) * FCols + Col;
  if Result >= FTileCount then Result := -1;
end;

procedure TAuTileGrid.EnsureVisible(I: Integer);
var
  Y: Integer;
begin
  if (I < 0) or (I >= FTileCount) or (FCols <= 0) then Exit;
  Y := FPadTop + (I div FCols) * FCellH;
  if Y - FPadTop < FScroll.Position then FScroll.Position := Y - FPadTop
  else if Y + FCellH > FScroll.Position + ClientHeight then
    FScroll.Position := Y + FCellH - ClientHeight;
  Invalidate;
end;

procedure TAuTileGrid.SelectRange(A, B: Integer; Add: Boolean);
var
  I, T: Integer;
begin
  if not Add then
    for I := 0 to FTileCount - 1 do FSel[I] := False;
  if A > B then begin T := A; A := B; B := T; end;
  for I := Math.Max(0, A) to Math.Min(B, FTileCount - 1) do FSel[I] := True;
end;

procedure TAuTileGrid.SelectOnly(I: Integer);
begin
  if (I < 0) or (I >= FTileCount) then Exit;
  SelectRange(I, I, False);
  FFocusIdx := I;
  FAnchorIdx := I;
  EnsureVisible(I);
  DoSelChange;
end;

procedure TAuTileGrid.RestoreState(const ASel: TAuTileIntArray; AFocus, AScroll: Integer);
var
  I: Integer;
begin
  for I := 0 to FTileCount - 1 do FSel[I] := False;
  for I := 0 to High(ASel) do
    if (ASel[I] >= 0) and (ASel[I] < FTileCount) then FSel[ASel[I]] := True;
  if (AFocus >= 0) and (AFocus < FTileCount) then
  begin
    FFocusIdx := AFocus;
    FAnchorIdx := AFocus;
  end;
  if AScroll >= 0 then FScroll.Position := AScroll
  else if FFocusIdx >= 0 then EnsureVisible(FFocusIdx);
  Invalidate;
end;

procedure TAuTileGrid.DoSelChange;
begin
  if Assigned(FOnSelChange) then FOnSelChange(Self);
end;

procedure TAuTileGrid.MoveFocus(I: Integer; Shift: TShiftState);
begin
  if FTileCount = 0 then Exit;
  I := EnsureRange(I, 0, FTileCount - 1);
  FFocusIdx := I;
  if (ssShift in Shift) and (FAnchorIdx >= 0) then
    SelectRange(FAnchorIdx, I, ssCtrl in Shift)
  else if not (ssCtrl in Shift) then
  begin
    SelectRange(I, I, False);
    FAnchorIdx := I;
  end;
  EnsureVisible(I);
  DoSelChange;
end;

procedure TAuTileGrid.MoreArt(Data: PtrInt);
begin
  FMoreQueued := False;
  Invalidate;
end;

procedure TAuTileGrid.DoPaint(G: TGfx);
var
  F, F2: TGfxFont;
  I, Budget, TX, TY, TW: Integer;
  R, HR, RP, RM: TRect;
  Info: TAuTileInfo;
  Bmp: TGfxBitmap;
  Bg, Fg, Fg2: TARGB;
  Foc, Pending, More: Boolean;

  { a round button on a picture: dark under any cover, the accent under the pointer }
  procedure DrawButton(const ARect: TRect; AIcon: TAuIcon; AHot: Boolean);
  var
    CX, CY, Rad: Single;
  begin
    CX := (ARect.Left + ARect.Right) / 2;
    CY := (ARect.Top + ARect.Bottom) / 2;
    Rad := (ARect.Right - ARect.Left) / 2;
    if AHot then
    begin
      G.FillCircle(CX, CY, Rad, clAccent);
      DrawIcon(G, AIcon, CX, CY, S(14), clOnAccent);
    end
    else
    begin
      G.FillCircle(CX, CY, Rad, TARGB($C8101216));
      DrawIcon(G, AIcon, CX, CY, S(14), TARGB($FFFFFFFF));
    end;
  end;

begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if Assigned(FOnPrepare) then FOnPrepare(Self);
  if (FTileCount = 0) or not Assigned(FOnInfo) then
  begin
    if FEmptyText <> '' then
      G.Text(FEmptyText, S(16), 0, ViewW - S(32), ClientHeight, UIFont(13), clTextFaint, 1, 1, tfWrap);
    Exit;
  end;
  HotSet(FHot, FHoverIdx, Self);
  F := UIFont(FTextSize);
  F2 := UIFont(FTextSize - 1);
  Foc := Focused;
  Budget := ART_LOADS_PER_PAINT;
  More := False;
  TW := TextW;
  I := Math.Max(0, (FScroll.Position - FPadTop) div FCellH) * FCols;
  while I < FTileCount do
  begin
    R := TileRect(I);
    if R.Top >= ClientHeight then Break;
    FOnInfo(Self, I, Info);
    HR := HighlightRect(I);
    Bg := 0;
    if FSel[I] then
    begin
      if Foc then Bg := clSelection else Bg := clSelectionDim;
    end
    else if HotLevel(FHot, I) > 0 then Bg := Blend(EffBack, clHover, HotLevel(FHot, I));
    if Bg <> 0 then
      G.FillRound(HR.Left, HR.Top, HR.Right - HR.Left, HR.Bottom - HR.Top, S(7), Bg);
    if Foc and KeyboardCues and (I = FFocusIdx) then
      G.StrokeRound(HR.Left, HR.Top, HR.Right - HR.Left, HR.Bottom - HR.Top, S(7), SF(1.5), clAccent);
    Bmp := nil;
    Pending := False;
    if Assigned(FOnArt) then Bmp := FOnArt(Self, I, Budget, Pending);
    if Pending then More := True;
    if FTileSize = TILE_SIZE_LIST then
    begin
      DrawTileArt(G, Bmp, R.Left, R.Top + S(4), FArt, FArt, S(4), Info.ArtKey, False);
      TX := R.Left + FArt + S(12);
      TY := R.Top + (FCellH - FLineH * 2) div 2;
    end
    else
    begin
      DrawTileArt(G, Bmp, R.Left, R.Top, FArt, FArt, S(6), Info.ArtKey, False);
      TX := R.Left;
      TY := R.Top + FArt + S(6);
    end;
    if Info.Dim then
    begin
      { a faint tile: the picture under a veil of the background }
      if FTileSize = TILE_SIZE_LIST then
        G.FillRound(R.Left, R.Top + S(4), FArt, FArt, S(4), WithAlpha(EffBack, $A8))
      else
        G.FillRound(R.Left, R.Top, FArt, FArt, S(6), WithAlpha(EffBack, $A8));
      Fg := clTextFaint;
      Fg2 := clTextFaint;
    end
    else
    begin
      Fg := clText;
      Fg2 := clTextDim;
    end;
    G.Text(Info.Title, TX, TY, TW, FLineH, F, Fg, 0, 1);
    if Info.Sub <> '' then G.Text(Info.Sub, TX, TY + FLineH, TW, FLineH, F2, Fg2, 0, 1);
    if ShowsButtons(I) then
    begin
      ButtonRects(I, RP, RM);
      DrawButton(RP, icPlay, (I = FHoverIdx) and (FHoverBtn = TILE_BTN_PLAY));
      DrawButton(RM, icMore, (I = FHoverIdx) and (FHoverBtn = TILE_BTN_MENU));
    end;
    Inc(I);
  end;
  { pictures that had to wait: the next paint loads some more }
  if More and not FMoreQueued then
  begin
    FMoreQueued := True;
    Application.QueueAsyncCall(@MoreArt, 0);
  end;
end;

procedure TAuTileGrid.GridShowHint(Sender: TObject; HintInfo: PHintInfo);
var
  I: Integer;
  Info: TAuTileInfo;
  TW: Integer;
begin
  HintInfo^.HintStr := '';
  case ButtonAt(HintInfo^.CursorPos.X, HintInfo^.CursorPos.Y, I) of
    TILE_BTN_PLAY: begin HintInfo^.HintStr := 'Play'; Exit; end;
    TILE_BTN_MENU: begin HintInfo^.HintStr := 'More actions'; Exit; end;
  end;
  if (I < 0) or not Assigned(FOnInfo) then Exit;
  FOnInfo(Self, I, Info);
  { only when a line is cut: the full text }
  TW := TextW;
  if (TextWidth(Info.Title, UIFont(FTextSize)) <= TW) and
     (TextWidth(Info.Sub, UIFont(FTextSize - 1)) <= TW) then Exit;
  HintInfo^.CursorRect := HighlightRect(I);
  if Info.Sub <> '' then HintInfo^.HintStr := Info.Title + LineEnding + Info.Sub
  else HintInfo^.HintStr := Info.Title;
end;

procedure TAuTileGrid.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I, B: Integer;
  HR: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  I := IndexAt(X, Y);
  FDownIdx := -1;
  FDownBtn := TILE_BTN_NONE;
  FDragArmed := False;
  FDownOnSelected := False;
  if I < 0 then
  begin
    if (Button = mbLeft) and not (ssCtrl in Shift) then
    begin
      SelectRange(0, -1, False);
      Invalidate;
      DoSelChange;
    end;
    Exit;
  end;
  if Button = mbRight then
  begin
    if not FSel[I] then
    begin
      SelectRange(I, I, False);
      FAnchorIdx := I;
    end;
    FFocusIdx := I;
    Invalidate;
    DoSelChange;
    if Assigned(FOnTileContext) then FOnTileContext(Self, I, ClientToScreen(Point(X, Y)));
    Exit;
  end;
  if Button <> mbLeft then Exit;
  { a button of the tile. A finger has no pointer that shows the buttons
    first: there they count only on the tile that had them before the tap. }
  if (not MouseFromTouch) or (FSel[I] and (I = FFocusIdx)) then
    FDownBtn := ButtonAt(X, Y, B)
  else
    FDownBtn := TILE_BTN_NONE;
  if FDownBtn <> TILE_BTN_NONE then
  begin
    { a selected tile keeps the selection (the button acts on all of it),
      any other becomes the one selected }
    if not FSel[I] then
    begin
      SelectRange(I, I, False);
      FAnchorIdx := I;
    end;
    FFocusIdx := I;
    FDownIdx := I;
    Invalidate;
    DoSelChange;
    Exit;
  end;
  HR := HighlightRect(I);
  if (FTileSize <> TILE_SIZE_LIST) and ((X < HR.Left) or (X >= HR.Right)) then Exit;
  FFocusIdx := I;
  FDownIdx := I;
  FDownPt := Point(X, Y);
  if (ssShift in Shift) and (FAnchorIdx >= 0) then
    SelectRange(FAnchorIdx, I, ssCtrl in Shift)
  else if ssCtrl in Shift then
  begin
    FSel[I] := not FSel[I];
    FAnchorIdx := I;
  end
  else if FSel[I] and (SelCount > 1) then
    FDownOnSelected := True           // the selection stays: a drag may start
  else
  begin
    SelectRange(I, I, False);
    FAnchorIdx := I;
  end;
  FDragArmed := FDragEnabled and FSel[I];
  Invalidate;
  DoSelChange;
end;

procedure TAuTileGrid.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I, B: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragArmed and (ssLeft in Shift) and (FDownIdx >= 0) and
     ((Abs(X - FDownPt.X) > S(6)) or (Abs(Y - FDownPt.Y) > S(6))) then
  begin
    FDragArmed := False;
    FDownOnSelected := False;
    BeginDrag(True);
    Exit;
  end;
  I := IndexAt(X, Y);
  if I <> FHoverIdx then
  begin
    FHoverIdx := I;
    Invalidate;
  end;
  B := ButtonAt(X, Y, I);
  if B <> FHoverBtn then
  begin
    FHoverBtn := B;
    Invalidate;
  end;
end;

procedure TAuTileGrid.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I, B, D: Integer;
  RP, RM: TRect;
begin
  inherited MouseUp(Button, Shift, X, Y);
  { a button: released where it was pressed }
  if FDownBtn <> TILE_BTN_NONE then
  begin
    B := FDownBtn;
    D := FDownIdx;
    FDownBtn := TILE_BTN_NONE;
    FDownIdx := -1;
    if (Button = mbLeft) and (ButtonAt(X, Y, I) = B) and (I = D) then
    begin
      if B = TILE_BTN_PLAY then
      begin
        if Assigned(FOnTilePlay) then FOnTilePlay(Self, I);
      end
      else if Assigned(FOnTileContext) then
      begin
        ButtonRects(I, RP, RM);
        FOnTileContext(Self, I, ClientToScreen(Point(RM.Left, RM.Bottom + S(2))));
      end;
    end;
    Exit;
  end;
  I := IndexAt(X, Y);
  if FDownOnSelected and (I >= 0) and (I = FDownIdx) then
  begin
    SelectRange(I, I, False);
    FAnchorIdx := I;
    Invalidate;
    DoSelChange;
  end;
  FDownOnSelected := False;
  FDragArmed := False;
  FDownIdx := -1;
end;

procedure TAuTileGrid.MouseLeave;
begin
  inherited MouseLeave;
  FHoverBtn := TILE_BTN_NONE;
  if FHoverIdx <> -1 then
  begin
    FHoverIdx := -1;
    Invalidate;
  end;
end;

procedure TAuTileGrid.DblClick;
var
  P: TPoint;
  I: Integer;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  { a button has done its work at the first click }
  if ButtonAt(P.X, P.Y, I) <> TILE_BTN_NONE then Exit;
  if (I >= 0) and Assigned(FOnActivate) then FOnActivate(Self, I);
end;

procedure TAuTileGrid.KeyDown(var Key: Word; Shift: TShiftState);
var
  PageRows: Integer;
  R: TRect;
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  PageRows := Math.Max(1, ClientHeight div Math.Max(1, FCellH) - 1);
  case Key of
    VK_LEFT: if FTileSize <> TILE_SIZE_LIST then MoveFocus(FFocusIdx - 1, Shift) else Exit;
    VK_RIGHT: if FTileSize <> TILE_SIZE_LIST then MoveFocus(FFocusIdx + 1, Shift) else Exit;
    VK_UP: if FFocusIdx - FCols >= 0 then MoveFocus(FFocusIdx - FCols, Shift);
    VK_DOWN: if FFocusIdx + FCols < FTileCount then MoveFocus(FFocusIdx + FCols, Shift)
             else MoveFocus(FTileCount - 1, Shift);
    VK_PRIOR: MoveFocus(Math.Max(FFocusIdx mod Math.Max(1, FCols), FFocusIdx - PageRows * FCols), Shift);
    VK_NEXT: MoveFocus(FFocusIdx + PageRows * FCols, Shift);
    VK_HOME: MoveFocus(0, Shift);
    VK_END: MoveFocus(FTileCount - 1, Shift);
    VK_RETURN:
      if (FFocusIdx >= 0) and Assigned(FOnActivate) then FOnActivate(Self, FFocusIdx);
    VK_APPS, VK_F10:
      begin
        if (Key = VK_F10) and not (ssShift in Shift) then Exit;
        if (FFocusIdx >= 0) and Assigned(FOnTileContext) then
        begin
          EnsureVisible(FFocusIdx);
          if not FSel[FFocusIdx] then
          begin
            SelectRange(FFocusIdx, FFocusIdx, False);
            DoSelChange;
          end;
          R := TileRect(FFocusIdx);
          FOnTileContext(Self, FFocusIdx, ClientToScreen(Point(R.Left + S(20), R.Top + S(20))));
        end;
      end;
  else
    if (ssCtrl in Shift) and (Key = Ord('A')) then
    begin
      SelectRange(0, FTileCount - 1, False);
      Invalidate;
      DoSelChange;
    end
    else Exit;
  end;
  Key := 0;
end;

{ letters typed shortly after each other add up; the next tile after the
  focus whose text starts with them gets the focus }
procedure TAuTileGrid.TypeAhead(const Ch: string);
var
  I, Start, N: Integer;
  U: string;
begin
  if not Assigned(FOnTypeText) then Exit;
  if GetTickCount64 - FTypeTick > 900 then FTypeText := '';
  FTypeTick := GetTickCount64;
  FTypeText := FTypeText + Ch;
  U := UTF8LowerCase(FTypeText);
  N := FTileCount;
  if N = 0 then Exit;
  Start := Math.Max(0, FFocusIdx);
  if Length(FTypeText) = Length(Ch) then Start := Start + 1;   // a new search starts after the focus
  for I := 0 to N - 1 do
    if Pos(U, UTF8LowerCase(FOnTypeText(Self, (Start + I) mod N))) = 1 then
    begin
      MoveFocus((Start + I) mod N, []);
      Exit;
    end;
end;

procedure TAuTileGrid.UTF8KeyPress(var UTF8Key: TUTF8Char);
begin
  inherited UTF8KeyPress(UTF8Key);
  if (UTF8Key <> '') and (UTF8Key[1] >= ' ') then
  begin
    TypeAhead(UTF8Key);
    UTF8Key := '';
  end;
end;

function TAuTileGrid.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if ssCtrl in Shift then
  begin
    if Assigned(FOnSizeWheel) then FOnSizeWheel(Self, Sign(WheelDelta));
    Exit;
  end;
  if FTileSize = TILE_SIZE_LIST then FScroll.WheelBy(-Round(WheelDelta / 120 * FCellH * 3))
  else FScroll.WheelBy(-Round(WheelDelta / 120 * FCellH * 0.75));
end;

function TAuTileGrid.PanBy(DX, DY: Integer): Boolean;
begin
  if not FScroll.Visible then Exit(inherited PanBy(DX, DY));
  if DY <> 0 then FScroll.Position := FScroll.Position - DY;
  Result := True;
end;

end.
