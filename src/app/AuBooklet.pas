unit AuBooklet;

{ ==============================================================================
  AulumicNS - AuBooklet
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Booklet viewer: PDF booklets of an album in their own window.

  Pages are shown one at a time or as a booklet spread (the cover alone,
  then facing pages side by side; landscape pages are spreads already and
  stay single). The view fits the window; Ctrl+wheel / + / - zoom, drag or
  the wheel pans when zoomed, double click switches between fit and 200 %.
  Arrow keys, Page Up / Down, Space, Home / End and the wheel (at fit)
  turn the pages. Pages are rendered by the Windows PDF engine in the
  background at the size they are shown, neighbours in advance.

  The bar and the view are on Body (below the own title bar); FindBooklets
  is in uMetaUtils (the playback IO worker uses it for the banner's booklet
  button); CloseBooklet frees the viewer at exit.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType, LCLIntf,
  AuGfx, AuTheme, AuIcons, AuControls, AuForms, AuMenus, AuPdf, uMetaUtils;

type
  TPageBitmap = record
    Width: Integer;
    Bitmap: TGfxBitmap;
  end;

  TAuBookletForm = class;

  { TAuPdfView }

  TAuPdfView = class(TAuControl)
  private
    FForm: TAuBookletForm;
    FDragging: Boolean;
    FDragX, FDragY, FDragOX, FDragOY: Integer;
    FSwipe: Integer;                // touch at fit: the way swiped so far
    FSwiped: Boolean;               // this swipe turned its page (one page per swipe)
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function PanBy(DX, DY: Integer): Boolean; override;
  public
    function ScrollOffset: Integer; override;
  protected
    function GesturePan: Integer; override;
  end;

  { TAuBookletForm }

  TAuBookletForm = class(TAuForm)
  private
    FFiles: TStringList;
    FFileIdx: Integer;
    FFileMenu: TAuMenu;
    FPageMenu: TAuMenu;              // the menu of a right-click on the page
    FTitle: TAuLabel;
    FPageLbl: TAuLabel;
    FBtnPrev, FBtnNext, FBtnZoomOut, FBtnZoomIn, FBtnFit, FBtnFile, FBtnExternal: TAuIconButton;
    FMode: TAuSegmented;
    FBar: TAuPanel;
    FView: TAuPdfView;
    FRenderer: TAuPdfRenderer;
    FTimer: TTimer;
    FCache: array of array of TPageBitmap;
    FSlot: Integer;               // index of the spread / page shown
    FZoom: Double;                // 1 = fit
    FOffX, FOffY: Integer;        // pan offset of a zoomed view
    FLoadedShown: Boolean;
    FStartPage: Integer;          // page to show once the document is loaded
    procedure OpenFile(Idx: Integer);
    procedure CloseFile;
    procedure Tick(Sender: TObject);
    procedure PrevClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure ZoomInClick(Sender: TObject);
    procedure ZoomOutClick(Sender: TObject);
    procedure FitClick(Sender: TObject);
    procedure ModeChange(Sender: TObject);
    procedure FileClick(Sender: TObject);
    procedure PageMenu;
    procedure FolderClick(Sender: TObject);
    procedure FilePick(Sender: TObject);
    procedure FormClosed(Sender: TObject; var CloseAction: TCloseAction);
    procedure ExternalClick(Sender: TObject);
    procedure LayoutBar;
    function SpreadMode: Boolean;
    function SlotCount: Integer;
    procedure SlotPages(Slot: Integer; out A, B: Integer);
    procedure SetSlot(V: Integer);
    procedure SetZoom(V: Double; AtX, AtY: Integer);
    procedure UpdateLabels;
    { geometry of the shown pages at the current zoom (view pixels) }
    procedure Geometry(out PageA, PageB: Integer; out RA, RB: TRect; out ContentW, ContentH: Integer);
    function BestBitmap(Page, PxWidth: Integer): TGfxBitmap;
    procedure RequestVisible;
    procedure ClampOffset;
    // the render width for page P wanted at Px (128 px steps,
    // at most MAX_PAGE_PIXELS); the width of the shown page at fit
    function RenderWidth(P, Px: Integer): Integer;
    function FitPageWidth: Integer;
    procedure PruneLargeBitmaps;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure Resize; override;
    procedure DpiUpdated; override;
  public
    constructor CreateBooklet(AOwner: TComponent);
    destructor Destroy; override;
    procedure ShowFiles(Files: TStrings; Index: Integer = 0);
  end;

procedure ShowBooklet(Files: TStrings; Index: Integer = 0; StartPage: Integer = 0);
function BookletWindow: TCustomForm;
{ frees the viewer (exit) }
procedure CloseBooklet;

implementation

uses
  AuTagLoader;

var
  BookletForm: TAuBookletForm = nil;

function BookletWindow: TCustomForm;
begin
  Result := BookletForm;
end;

procedure CloseBooklet;
begin
  FreeAndNil(BookletForm);
end;

procedure ShowBooklet(Files: TStrings; Index: Integer; StartPage: Integer);
begin
  if Files.Count = 0 then Exit;
  if BookletForm = nil then BookletForm := TAuBookletForm.CreateBooklet(Application);
  BookletForm.FStartPage := StartPage;
  BookletForm.ShowFiles(Files, Index);
end;

{ ---- TAuPdfView ---- }

procedure TAuPdfView.DoPaint(G: TGfx);
var
  F: TAuBookletForm;
  PA, PB, CW, CH: Integer;
  RA, RB: TRect;

  procedure DrawPage(P: Integer; const R: TRect);
  var
    B: TGfxBitmap;
  begin
    if (P < 0) or IsRectEmpty(R) then Exit;
    G.FillRect(R.Left + S(3), R.Top + S(4), R.Right - R.Left, R.Bottom - R.Top, $50000000);
    G.FillRect(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, $FFFFFFFF);
    B := F.BestBitmap(P, R.Right - R.Left);
    if B <> nil then G.DrawBitmap(B, R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top)
    else DrawIcon(G, icDocument, (R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2, S(40), $40000000);
  end;

begin
  F := FForm;
  G.FillRect(0, 0, Width, Height, Blend(clBg, $FF000000, 0.35));
  if F.FRenderer = nil then Exit;
  if not F.FRenderer.Loaded then
  begin
    G.Text('Opening the booklet...', 0, 0, Width, Height, UIFont(14), clTextDim, 1, 1);
    Exit;
  end;
  if F.FRenderer.Error <> '' then
  begin
    G.Text(F.FRenderer.Error, S(40), 0, Width - S(80), Height, UIFont(14), clTextDim, 1, 1);
    Exit;
  end;
  if F.FRenderer.PageCount = 0 then Exit;
  F.Geometry(PA, PB, RA, RB, CW, CH);
  DrawPage(PA, RA);
  DrawPage(PB, RB);
end;

procedure TAuPdfView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbRight then
  begin
    FForm.PageMenu;
    Exit;
  end;
  if (Button = mbLeft) and (FForm.FZoom > 1.001) then
  begin
    FDragging := True;
    FDragX := X;
    FDragY := Y;
    FDragOX := FForm.FOffX;
    FDragOY := FForm.FOffY;
    Cursor := crSizeAll;
  end;
end;

procedure TAuPdfView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then
  begin
    FForm.FOffX := FDragOX - (X - FDragX);
    FForm.FOffY := FDragOY - (Y - FDragY);
    FForm.ClampOffset;
    Invalidate;
  end;
end;

procedure TAuPdfView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging then
  begin
    FDragging := False;
    Cursor := crDefault;
    FForm.RequestVisible;
  end;
end;

procedure TAuPdfView.DblClick;
var
  P: TPoint;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  if FForm.FZoom > 1.001 then FForm.SetZoom(1, P.X, P.Y) else FForm.SetZoom(2, P.X, P.Y);
end;

function TAuPdfView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  Result := True;
  P := ScreenToClient(MousePos);
  if (P.X < 0) or (P.Y < 0) or (P.X > Width) or (P.Y > Height) then P := ScreenToClient(Mouse.CursorPos);
  if ssCtrl in Shift then
  begin
    if WheelDelta > 0 then FForm.SetZoom(FForm.FZoom * 1.25, P.X, P.Y)
    else FForm.SetZoom(FForm.FZoom / 1.25, P.X, P.Y);
  end
  else if FForm.FZoom > 1.001 then
  begin
    if ssShift in Shift then Dec(FForm.FOffX, WheelDelta div 2) else Dec(FForm.FOffY, WheelDelta div 2);
    FForm.ClampOffset;
    Invalidate;
    FForm.RequestVisible;
  end
  else if WheelDelta < 0 then FForm.SetSlot(FForm.FSlot + 1)
  else FForm.SetSlot(FForm.FSlot - 1);
end;

{ Touch. Zoomed in, the page follows the finger both ways; at fit, a swipe
  of S(120) (left / up = on) turns the page - one page per swipe: the rest
  of the finger's way and the inertia after it are ignored (they would turn
  a second page) }
function TAuPdfView.GesturePan: Integer;
begin
  Result := GESTURE_PAN_VH;
end;

function TAuPdfView.PanBy(DX, DY: Integer): Boolean;
begin
  Result := True;
  if (DX = 0) and (DY = 0) then
  begin
    FSwipe := 0;                  // a new swipe
    FSwiped := False;
    Exit;
  end;
  if FForm.FZoom > 1.001 then
  begin
    Dec(FForm.FOffX, DX);
    Dec(FForm.FOffY, DY);
    FForm.ClampOffset;
    Invalidate;
    FForm.RequestVisible;
    Exit;
  end;
  if FSwiped then Exit;
  if Abs(DX) >= Abs(DY) then Inc(FSwipe, DX) else Inc(FSwipe, DY);
  if FSwipe <= -S(120) then
  begin
    FSwiped := True;
    FForm.SetSlot(FForm.FSlot + 1);
  end
  else if FSwipe >= S(120) then
  begin
    FSwiped := True;
    FForm.SetSlot(FForm.FSlot - 1);
  end;
end;

function TAuPdfView.ScrollOffset: Integer;
begin
  // the page (spread) shown, and the pan offset of a zoomed view
  Result := FForm.FSlot * 100000 + FForm.FOffY;
end;

{ ---- TAuBookletForm ---- }

constructor TAuBookletForm.CreateBooklet(AOwner: TComponent);

  function Btn(Ic: TAuIcon; const H: string; Click: TNotifyEvent): TAuIconButton;
  begin
    Result := TAuIconButton.Create(Self);
    Result.Parent := FBar;
    Result.Icon := Ic;
    Result.Hint := H;
    Result.ShowHint := True;
    Result.OnClick := Click;
  end;

begin
  CreateAu(AOwner, 'Booklet', Min(1280, Round(Screen.WorkAreaWidth / UIScale * 0.85)),
    Min(900, Round(Screen.WorkAreaHeight / UIScale * 0.88)));
  IsDialog := False;
  HelpKeyword := 'Booklet Viewer';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Constraints.MinWidth := S(560);
  Constraints.MinHeight := S(400);
  FFiles := TStringList.Create;
  FFileMenu := TAuMenu.Create;
  FZoom := 1;
  OnClose := @FormClosed;

  FBar := TAuPanel.Create(Self);
  FBar.Parent := Body;
  FBar.Align := alTop;
  FBar.Height := S(56);
  FBar.BackRole := crPanel;
  FBar.BorderRole := crBorder;
  FBar.BorderSides := 8;

  FTitle := TAuLabel.Create(Self);
  FTitle.Parent := FBar;
  FTitle.FontSize := 14;
  FTitle.Bold := True;
  FBtnFile := Btn(icDocument, 'Other booklets of this album', @FileClick);
  FBtnPrev := Btn(icChevronLeft, 'Previous page (Left)', @PrevClick);
  FPageLbl := TAuLabel.Create(Self);
  FPageLbl.Parent := FBar;
  FPageLbl.FontSize := 13;
  FPageLbl.HAlign := 1;
  FBtnNext := Btn(icChevronRight, 'Next page (Right)', @NextClick);
  FMode := TAuSegmented.Create(Self);
  FMode.Parent := FBar;
  FMode.Items.Add('Single');
  FMode.Items.Add('Spread');
  FMode.ItemIndex := 1;
  FMode.OnChange := @ModeChange;
  FBtnZoomOut := Btn(icMinus, 'Zoom out (-)', @ZoomOutClick);
  FBtnFit := Btn(icFit, 'Fit to window (0)', @FitClick);
  FBtnZoomIn := Btn(icPlus, 'Zoom in (+)', @ZoomInClick);
  FBtnExternal := Btn(icFolder, 'Open with the PDF program of Windows', @ExternalClick);

  FView := TAuPdfView.Create(Self);
  FView.FForm := Self;
  FView.Parent := Body;
  FView.Align := alClient;
  FView.TabStop := True;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 30;
  FTimer.OnTimer := @Tick;
  LayoutBar;
end;

destructor TAuBookletForm.Destroy;
begin
  FTimer.Enabled := False;
  CloseFile;
  FFiles.Free;
  FFileMenu.Free;
  FPageMenu.Free;
  if BookletForm = Self then BookletForm := nil;
  inherited Destroy;
end;

procedure TAuBookletForm.LayoutBar;
var
  X, W: Integer;
begin
  if FBar = nil then Exit;
  W := FBar.ClientWidth;
  X := W - S(16) - S(36);
  FBtnExternal.SetBounds(X, S(10), S(36), S(36));
  Dec(X, S(48));
  FBtnZoomIn.SetBounds(X, S(10), S(36), S(36));
  Dec(X, S(40));
  FBtnFit.SetBounds(X, S(10), S(36), S(36));
  Dec(X, S(40));
  FBtnZoomOut.SetBounds(X, S(10), S(36), S(36));
  Dec(X, S(12) + S(170));
  FMode.SetBounds(X, S(10), S(170), S(36));
  X := (W - S(200)) div 2;
  if X + S(200) > FMode.Left - S(12) then X := FMode.Left - S(12) - S(200);
  FBtnPrev.SetBounds(X, S(10), S(36), S(36));
  FPageLbl.SetBounds(X + S(40), S(10), S(120), S(36));
  FBtnNext.SetBounds(X + S(164), S(10), S(36), S(36));
  FBtnFile.SetBounds(S(16), S(10), S(36), S(36));
  if FBtnFile.Visible then FTitle.SetBounds(S(60), S(10), Max(S(60), X - S(72)), S(36))
  else FTitle.SetBounds(S(20), S(10), Max(S(60), X - S(32)), S(36));
end;

procedure TAuBookletForm.Resize;
begin
  inherited Resize;
  LayoutBar;
  ClampOffset;
  if FView <> nil then RequestVisible;
end;

procedure TAuBookletForm.DpiUpdated;
begin
  inherited DpiUpdated;
  FBar.Height := S(56);
  LayoutBar;
end;

procedure TAuBookletForm.ShowFiles(Files: TStrings; Index: Integer);
var
  Same: Boolean;
  I: Integer;
begin
  Same := Files.Count = FFiles.Count;
  if Same then
    for I := 0 to Files.Count - 1 do
      if not SameText(Files[I], FFiles[I]) then Same := False;
  if not Same or (Index <> FFileIdx) or (FRenderer = nil) then
  begin
    FTimer.Enabled := True;
  begin
    FFiles.Assign(Files);
    OpenFile(EnsureRange(Index, 0, FFiles.Count - 1));
  end;
  end;
  FBtnFile.Visible := FFiles.Count > 1;
  LayoutBar;
  if WindowState = wsMinimized then WindowState := wsNormal;
  Show;
  BringToFront;
  FView.SetFocus;
end;

procedure TAuBookletForm.CloseFile;
var
  I, J: Integer;
begin
  FreeAndNil(FRenderer);
  for I := 0 to High(FCache) do
    for J := 0 to High(FCache[I]) do
      if FCache[I][J].Bitmap <> nil then DisposeBitmap(FCache[I][J].Bitmap);
  FCache := nil;
end;

procedure TAuBookletForm.OpenFile(Idx: Integer);
begin
  CloseFile;
  FFileIdx := Idx;
  FSlot := 0;
  FZoom := 1;
  FOffX := 0;
  FOffY := 0;
  FLoadedShown := False;
  Caption := 'Booklet - ' + ExtractFileName(FFiles[Idx]);
  FTitle.Caption := ChangeFileExt(ExtractFileName(FFiles[Idx]), '');
  FRenderer := TAuPdfRenderer.Create(FFiles[Idx]);
  FTimer.Enabled := True;
  UpdateLabels;
  FView.Invalidate;
end;

procedure TAuBookletForm.Tick(Sender: TObject);
var
  R: TAuPdfResults;
  I, J, N: Integer;
  Got: Boolean;
begin
  if FRenderer = nil then Exit;
  if FRenderer.Loaded and not FLoadedShown then
  begin
    FLoadedShown := True;
    SetLength(FCache, FRenderer.PageCount);
    { landscape pages are spreads already }
    if (FRenderer.PageCount > 0) and (FRenderer.PageSize(Min(1, FRenderer.PageCount - 1)).W >
      1.25 * FRenderer.PageSize(Min(1, FRenderer.PageCount - 1)).H) then FMode.ItemIndex := 0
    else FMode.ItemIndex := 1;
    if FStartPage > 0 then
    begin
      if SpreadMode then FSlot := (FStartPage + 1) div 2 else FSlot := FStartPage;
      FSlot := EnsureRange(FSlot, 0, Max(0, SlotCount - 1));
      FStartPage := 0;
    end;
    UpdateLabels;
    RequestVisible;
    FView.Invalidate;
  end;
  R := FRenderer.TakeResults;
  Got := False;
  for I := 0 to High(R) do
  begin
    if (R[I].Page < 0) or (R[I].Page > High(FCache)) then
    begin
      DisposeBitmap(R[I].Bitmap);
      Continue;
    end;
    { keep at most two sizes of a page: the new one and the largest other }
    N := Length(FCache[R[I].Page]);
    if N >= 2 then
    begin
      J := 0;
      if FCache[R[I].Page][1].Width < FCache[R[I].Page][0].Width then J := 1;
      DisposeBitmap(FCache[R[I].Page][J].Bitmap);
      FCache[R[I].Page][J].Width := R[I].Width;
      FCache[R[I].Page][J].Bitmap := R[I].Bitmap;
    end
    else
    begin
      SetLength(FCache[R[I].Page], N + 1);
      FCache[R[I].Page][N].Width := R[I].Width;
      FCache[R[I].Page][N].Bitmap := R[I].Bitmap;
    end;
    Got := True;
  end;
  if Got then
  begin
    { free pages far from the view }
    for I := 0 to High(FCache) do
      if Abs(I - FSlot * 2) > 12 then
      begin
        for J := 0 to High(FCache[I]) do DisposeBitmap(FCache[I][J].Bitmap);
        FCache[I] := nil;
      end;
    PruneLargeBitmaps;
    FView.Invalidate;
  end;
end;

{ Memory: a page rendered at a zoomed width of 6000 px is ~200 MB as a
  bitmap (~600 MB while it is rendered), and two sizes of up to 25 pages
  would be gigabytes. So a page is at most MAX_PAGE_PIXELS (drawn larger
  beyond that), the neighbours are rendered at fit size, and the large
  bitmaps go again: of a page that is not shown at once, of the shown ones
  at fit once their fit size is there. }
const
  MAX_PAGE_PIXELS = 20000000;    // ~80 MB as a 32-bit bitmap

function TAuBookletForm.RenderWidth(P, Px: Integer): Integer;
var
  Sz: TAuPdfPageSize;
  MaxW: Integer;
begin
  Result := ((Px + 127) div 128) * 128;
  if (FRenderer = nil) or (P < 0) or (P >= FRenderer.PageCount) then Exit;
  Sz := FRenderer.PageSize(P);
  if (Sz.W <= 0) or (Sz.H <= 0) then Exit;
  MaxW := Trunc(Sqrt(MAX_PAGE_PIXELS * Sz.W / Sz.H));
  MaxW := (MaxW div 128) * 128;
  if Result > MaxW then Result := Max(128, MaxW);
end;

function TAuBookletForm.FitPageWidth: Integer;
var
  Z: Double;
  PA, PB, CW, CH: Integer;
  RA, RB: TRect;
begin
  Z := FZoom;
  FZoom := 1;
  try
    Geometry(PA, PB, RA, RB, CW, CH);
  finally
    FZoom := Z;
  end;
  Result := RA.Right - RA.Left;
end;

procedure TAuBookletForm.PruneLargeBitmaps;
var
  PA, PB, I, J, Fit, Limit: Integer;
  HasSmall: Boolean;
begin
  if (FRenderer = nil) or not FRenderer.Loaded or (FRenderer.PageCount = 0) then Exit;
  SlotPages(FSlot, PA, PB);
  Fit := FitPageWidth;
  for I := 0 to High(FCache) do
  begin
    Limit := RenderWidth(I, Fit) + 128;
    if ((I = PA) or (I = PB)) and (FZoom > 1.001) then Continue;   // zoomed: needed
    HasSmall := False;
    for J := 0 to High(FCache[I]) do
      if FCache[I][J].Width <= Limit then HasSmall := True;
    { a page shown at fit keeps its large size until the fit size is there }
    if (not HasSmall) and ((I = PA) or (I = PB)) then Continue;
    for J := High(FCache[I]) downto 0 do
      if FCache[I][J].Width > Limit then
      begin
        DisposeBitmap(FCache[I][J].Bitmap);
        Delete(FCache[I], J, 1);
      end;
  end;
end;

function TAuBookletForm.BestBitmap(Page, PxWidth: Integer): TGfxBitmap;
var
  I, Best: Integer;
begin
  Result := nil;
  if (Page < 0) or (Page > High(FCache)) then Exit;
  Best := -1;
  for I := 0 to High(FCache[Page]) do
    if (Best < 0) or (Abs(FCache[Page][I].Width - PxWidth) < Abs(FCache[Page][Best].Width - PxWidth)) and
       ((FCache[Page][I].Width >= PxWidth) or (FCache[Page][Best].Width < PxWidth)) then Best := I;
  if Best >= 0 then Result := FCache[Page][Best].Bitmap;
end;

function TAuBookletForm.SpreadMode: Boolean;
begin
  Result := FMode.ItemIndex = 1;
end;

function TAuBookletForm.SlotCount: Integer;
var
  N: Integer;
begin
  if (FRenderer = nil) or not FRenderer.Loaded then Exit(0);
  N := FRenderer.PageCount;
  if not SpreadMode or (N <= 2) then Result := N
  else Result := 1 + (N - 1 + 1) div 2;     // cover, then pairs
end;

procedure TAuBookletForm.SlotPages(Slot: Integer; out A, B: Integer);
var
  N: Integer;
begin
  A := -1;
  B := -1;
  if FRenderer = nil then Exit;
  N := FRenderer.PageCount;
  if not SpreadMode or (N <= 2) then
  begin
    if (Slot >= 0) and (Slot < N) then A := Slot;
    Exit;
  end;
  if Slot = 0 then A := 0
  else
  begin
    A := 2 * Slot - 1;
    B := A + 1;
    if B >= N then B := -1;
    if A >= N then A := -1;
  end;
end;

procedure TAuBookletForm.Geometry(out PageA, PageB: Integer; out RA, RB: TRect; out ContentW, ContentH: Integer);
var
  Pad, AvW, AvH, W, H, X0, Y0: Integer;
  SA, SB: TAuPdfPageSize;
  TotW, TotH, K: Double;
begin
  RA := Rect(0, 0, 0, 0);
  RB := Rect(0, 0, 0, 0);
  ContentW := 0;
  ContentH := 0;
  SlotPages(FSlot, PageA, PageB);
  if PageA < 0 then Exit;
  Pad := S(24);
  AvW := Max(10, FView.Width - 2 * Pad);
  AvH := Max(10, FView.Height - 2 * Pad);
  SA := FRenderer.PageSize(PageA);
  if PageB >= 0 then SB := FRenderer.PageSize(PageB) else SB := SA;
  { both pages at the same height }
  if PageB >= 0 then TotW := SA.W + SB.W * SA.H / SB.H
  else if SpreadMode and (PageA = 0) and (FRenderer.PageCount > 2) then TotW := SA.W * 2    // the cover in the right half
  else TotW := SA.W;
  TotH := SA.H;
  K := Min(AvW / TotW, AvH / TotH) * FZoom;
  ContentW := Round(TotW * K);
  ContentH := Round(TotH * K);
  X0 := (FView.Width - ContentW) div 2;
  Y0 := (FView.Height - ContentH) div 2;
  if ContentW > FView.Width then X0 := -FOffX;
  if ContentH > FView.Height then Y0 := -FOffY;
  W := Round(SA.W * K);
  H := Round(SA.H * K);
  if SpreadMode and (PageA = 0) and (PageB < 0) and (FRenderer.PageCount > 2) then
    RA := Rect(X0 + ContentW - W, Y0, X0 + ContentW, Y0 + H)
  else
    RA := Rect(X0, Y0, X0 + W, Y0 + H);
  if PageB >= 0 then
  begin
    W := Round(SB.W * SA.H / SB.H * K);
    RB := Rect(RA.Right, Y0, RA.Right + W, Y0 + H);
  end;
end;

procedure TAuBookletForm.ClampOffset;
var
  PA, PB, CW, CH: Integer;
  RA, RB: TRect;
begin
  if (FRenderer = nil) or not FRenderer.Loaded or (FRenderer.PageCount = 0) then Exit;
  FOffX := Max(0, FOffX);
  FOffY := Max(0, FOffY);
  Geometry(PA, PB, RA, RB, CW, CH);
  FOffX := EnsureRange(FOffX, 0, Max(0, CW - FView.Width));
  FOffY := EnsureRange(FOffY, 0, Max(0, CH - FView.Height));
end;

{ render requests: the shown pages at their size, then the neighbours at fit size }
procedure TAuBookletForm.RequestVisible;
var
  PA, PB, CW, CH, Fit, I, NA, NB: Integer;
  RA, RB: TRect;

  procedure Need(P, Px: Integer);
  var
    K: Integer;
  begin
    if (P < 0) or (P > High(FCache)) then Exit;
    Px := RenderWidth(P, Px);
    for K := 0 to High(FCache[P]) do
      if FCache[P][K].Width = Px then Exit;
    FRenderer.Request(P, Px);
  end;

begin
  if (FRenderer = nil) or not FRenderer.Loaded or (FRenderer.PageCount = 0) then Exit;
  FRenderer.CancelRequests;
  Geometry(PA, PB, RA, RB, CW, CH);
  Fit := FitPageWidth;
  { neighbours first: the renderer serves the newest request first }
  for I := 2 downto 1 do
  begin
    SlotPages(FSlot + I, NA, NB);
    Need(NB, Fit);
    Need(NA, Fit);
  end;
  SlotPages(FSlot - 1, NA, NB);
  Need(NA, Fit);
  Need(NB, Fit);
  if PB >= 0 then Need(PB, RB.Right - RB.Left);
  Need(PA, RA.Right - RA.Left);
end;

procedure TAuBookletForm.SetSlot(V: Integer);
begin
  V := EnsureRange(V, 0, Max(0, SlotCount - 1));
  if V = FSlot then Exit;
  FSlot := V;
  FZoom := 1;
  FOffX := 0;
  FOffY := 0;
  UpdateLabels;
  RequestVisible;
  FView.Invalidate;
end;

procedure TAuBookletForm.SetZoom(V: Double; AtX, AtY: Integer);
var
  PA, PB, CW0, CH0, CW1, CH1: Integer;
  RA, RB: TRect;
  FX, FY: Double;
begin
  if (FRenderer = nil) or not FRenderer.Loaded or (FRenderer.PageCount = 0) then Exit;
  V := EnsureRange(V, 1, 8);
  Geometry(PA, PB, RA, RB, CW0, CH0);
  { the point under the mouse stays where it is }
  FX := (AtX + FOffX - Max(0, (FView.Width - CW0) div 2)) / Max(1, CW0);
  FY := (AtY + FOffY - Max(0, (FView.Height - CH0) div 2)) / Max(1, CH0);
  if CW0 <= FView.Width then FX := (AtX - (FView.Width - CW0) div 2) / Max(1, CW0);
  if CH0 <= FView.Height then FY := (AtY - (FView.Height - CH0) div 2) / Max(1, CH0);
  FZoom := V;
  Geometry(PA, PB, RA, RB, CW1, CH1);
  FOffX := Round(FX * CW1 - AtX);
  FOffY := Round(FY * CH1 - AtY);
  ClampOffset;
  UpdateLabels;
  RequestVisible;
  { back at fit: the large sizes go when the fit size is already there }
  if FZoom <= 1.001 then PruneLargeBitmaps;
  FView.Invalidate;
end;

procedure TAuBookletForm.UpdateLabels;
var
  A, B, N: Integer;
begin
  if (FRenderer = nil) or not FRenderer.Loaded or (FRenderer.PageCount = 0) then
  begin
    FPageLbl.Caption := '';
    FBtnPrev.Enabled := False;
    FBtnNext.Enabled := False;
    Exit;
  end;
  N := FRenderer.PageCount;
  SlotPages(FSlot, A, B);
  if B >= 0 then FPageLbl.Caption := Format('%d-%d / %d', [A + 1, B + 1, N])
  else FPageLbl.Caption := Format('%d / %d', [A + 1, N]);
  FBtnPrev.Enabled := FSlot > 0;
  FBtnNext.Enabled := FSlot < SlotCount - 1;
  if FZoom > 1.001 then FBtnFit.Hint := Format('Fit to window (0)  -  now %d %%', [Round(FZoom * 100)])
  else FBtnFit.Hint := 'Fit to window (0)';
end;

procedure TAuBookletForm.PrevClick(Sender: TObject);
begin
  SetSlot(FSlot - 1);
end;

procedure TAuBookletForm.NextClick(Sender: TObject);
begin
  SetSlot(FSlot + 1);
end;

procedure TAuBookletForm.ZoomInClick(Sender: TObject);
begin
  SetZoom(FZoom * 1.25, FView.Width div 2, FView.Height div 2);
end;

procedure TAuBookletForm.ZoomOutClick(Sender: TObject);
begin
  SetZoom(FZoom / 1.25, FView.Width div 2, FView.Height div 2);
end;

procedure TAuBookletForm.FitClick(Sender: TObject);
begin
  SetZoom(1, FView.Width div 2, FView.Height div 2);
end;

procedure TAuBookletForm.ModeChange(Sender: TObject);
var
  A, B: Integer;
begin
  { keep the page that was shown }
  SlotPages(FSlot, A, B);
  if A < 0 then A := 0;
  if SpreadMode then FSlot := (A + 1) div 2 else FSlot := A;
  FSlot := EnsureRange(FSlot, 0, Max(0, SlotCount - 1));
  FZoom := 1;
  FOffX := 0;
  FOffY := 0;
  UpdateLabels;
  RequestVisible;
  FView.Invalidate;
end;

procedure TAuBookletForm.PageMenu;
begin
  if (FFileIdx < 0) or (FFileIdx >= FFiles.Count) then Exit;
  FPageMenu.Free;
  FPageMenu := TAuMenu.Create;
  FPageMenu.Add('Open folder...', @FolderClick, icFolder);
  FPageMenu.PopupAtCursor;
end;

{ Explorer at the booklet that is shown }
procedure TAuBookletForm.FolderClick(Sender: TObject);
begin
  if (FFileIdx < 0) or (FFileIdx >= FFiles.Count) then Exit;
  OpenFolderWithWindow(Self, FFiles[FFileIdx]);
end;

procedure TAuBookletForm.FileClick(Sender: TObject);
var
  I: Integer;
  It: TAuMenuItem;
begin
  FFileMenu.Clear;
  for I := 0 to FFiles.Count - 1 do
  begin
    It := FFileMenu.Add(ExtractFileName(FFiles[I]), @FilePick, icDocument, '', I);
    It.Checked := I = FFileIdx;
  end;
  FFileMenu.PopupBelow(FBtnFile);
end;

procedure TAuBookletForm.FilePick(Sender: TObject);
var
  I: Integer;
begin
  I := TAuMenuItem(Sender).Tag;
  if (I >= 0) and (I < FFiles.Count) and (I <> FFileIdx) then OpenFile(I);
end;

procedure TAuBookletForm.FormClosed(Sender: TObject; var CloseAction: TCloseAction);
begin
  { a hidden viewer keeps no document open }
  FTimer.Enabled := False;
  CloseFile;
  FFiles.Clear;
  CloseAction := caHide;
end;

procedure TAuBookletForm.ExternalClick(Sender: TObject);
begin
  if FFiles.Count > 0 then OpenDocument(FFiles[FFileIdx]);
end;

procedure TAuBookletForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) and (Shift = []) then
  begin
    Key := 0;
    Close;
    Exit;
  end;
  if Shift = [] then
    case Key of
      VK_RIGHT, VK_NEXT, VK_SPACE, VK_DOWN:
        if (FZoom <= 1.001) or (Key in [VK_NEXT, VK_SPACE]) then
        begin
          NextClick(nil);
          Key := 0;
        end;
      VK_LEFT, VK_PRIOR, VK_UP:
        if (FZoom <= 1.001) or (Key = VK_PRIOR) then
        begin
          PrevClick(nil);
          Key := 0;
        end;
      VK_HOME: begin SetSlot(0); Key := 0; end;
      VK_END: begin SetSlot(SlotCount - 1); Key := 0; end;
      VK_ADD, VK_OEM_PLUS: begin ZoomInClick(nil); Key := 0; end;
      VK_SUBTRACT, VK_OEM_MINUS: begin ZoomOutClick(nil); Key := 0; end;
      Ord('0'), VK_NUMPAD0: begin FitClick(nil); Key := 0; end;
      Ord('S'): begin FMode.ItemIndex := 1 - FMode.ItemIndex; ModeChange(nil); Key := 0; end;
    end;
  if (Key <> 0) and (FZoom > 1.001) and (Shift = []) then
    case Key of
      VK_LEFT: begin Dec(FOffX, S(60)); ClampOffset; FView.Invalidate; Key := 0; end;
      VK_RIGHT: begin Inc(FOffX, S(60)); ClampOffset; FView.Invalidate; Key := 0; end;
      VK_UP: begin Dec(FOffY, S(60)); ClampOffset; FView.Invalidate; Key := 0; end;
      VK_DOWN: begin Inc(FOffY, S(60)); ClampOffset; FView.Invalidate; Key := 0; end;
    end;
  if Key <> 0 then inherited KeyDown(Key, Shift);
end;

end.
