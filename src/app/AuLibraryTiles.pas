unit AuLibraryTiles;

{ ==============================================================================
  AulumicNS - AuLibraryTiles
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The albums of a part of the library as tiles (TAuTileGrid): the second
  look of the library pane, next to the tree. A line above the tiles says
  what they show: the path of the tree's node, whose parts can be clicked to
  go up to them (TCrumbBar), with a button that widens it to all albums. At
  its right are the order of the tiles and the arrow that reverses it.

  SetTracks takes the tracks to show and makes one tile per album:
  - tracks with an album tag: album artist + album (as the cover thumbnails
    of the library scan are kept); without an album artist the folder
    counts too, so two albums of the same name stay apart;
  - tracks without an album tag: one tile per folder, named after it.
  A tile keeps the paths of its tracks in album order (disc, track number,
  file name); what is done with a tile is done with those tracks.

  The pictures are the thumbnails of the library scan, read when a tile is
  painted (a few per paint) and kept while they are few; no music file is
  touched.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, LCLType, LazUTF8,
  AuGfx, AuTheme, AuIcons, AuControls, AuMenus, AuTileGrid, uLibraryTypes;

type
  TTileSort = (tsArtist, tsAlbum, tsYear, tsAdded);

  TLibTile = record
    Key: string;                      // what makes it one album (see the unit's head)
    Title, Artist: string;            // as shown
    RawArtist, RawAlbum: string;      // the tags (the key of the thumbnail)
    FolderDir: string;                // the folder of its first track
    Hash: string;                     // the thumbnail's file name, made when needed
    Year: Integer;
    Added: Int64;
    Found: Integer;                   // a search: how many of its tracks were found as tracks
    Offline: Integer;                 // 0 not asked yet, 1 its drive is there, 2 it is not
    PathCount: Integer;
    Paths: array of string;           // its tracks in album order (PathCount of them)
  end;
  PLibTile = ^TLibTile;

  TTileOfflineEvent = function(const AFolder: string): Boolean of object;

  { a track while the tiles are made: the key of its album and its place in it }
  TTileBuildRec = record
    Key: string;
    Disc, Track: Integer;
    T: PTrackInfo;
  end;
  TTileIdxCompare = function(A, B: Integer): Integer of object;

  TCrumbClickEvent = procedure(Sender: TObject; Index: Integer) of object;

  { TCrumbBar - a path as parts with arrows between them. All parts but the
    last can be clicked. A path too long for the bar loses its first parts
    (shown as "..."). }

  TCrumbBar = class(TAuControl)
  private
    FParts: array of string;
    FRects: array of TRect;           // where each part was drawn (empty: not shown)
    FLinks: Boolean;
    FHotPart: Integer;
    FOnPartClick: TCrumbClickEvent;
    function PartAt(X, Y: Integer): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { APath: the parts joined by #1; with more than one part all but the
      last are links }
    procedure SetPath(const APath: string);
    function PartCount: Integer;
    { the width the whole path needs }
    function NeededWidth: Integer;
    property OnPartClick: TCrumbClickEvent read FOnPartClick write FOnPartClick;
  end;
  { TLibraryTiles }

  TLibraryTiles = class(TAuPanel)
  private
    FHead: TAuPanel;
    FCrumb: TCrumbBar;
    FBtnClear, FBtnDir: TAuIconButton;
    FBtnSort: TAuButton;
    FTiles: array of TLibTile;
    FTileN: Integer;
    FOrder: array of Integer;         // the tiles in the order shown
    FBuild: array of TTileBuildRec;   // only while SetTracks runs
    FThumbs: TStringList;             // thumbnail name -> TGfxBitmap (nil: none)
    FThumbPx: Integer;                // the size the kept thumbnails were read at
    FSort: TTileSort;
    FReverse: Boolean;
    FSortHost: TWinControl;           // where the two sort buttons are (nil: in the line above the tiles)
    FPlainAll: Boolean;               // all albums, no search: the line has nothing to say
    FQuery: string;                   // the search the tiles are for, in lower case
    FSortMenu: TAuMenu;
    FOnOffline: TTileOfflineEvent;
    FOnSortChange, FOnClearScope: TNotifyEvent;
    FOnCrumbClick: TCrumbClickEvent;
    procedure CrumbClick(Sender: TObject; Index: Integer);
    procedure DirClick(Sender: TObject);
    procedure ShowSort;
    procedure Resort;
    procedure SetReverse(V: Boolean);
    procedure UpdateHead;
    procedure HeadResize(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure SortClick(Sender: TObject);
    procedure SortItemClick(Sender: TObject);
    procedure SortIdx(var A: array of Integer; L, R: Integer; Cmp: TTileIdxCompare);
    function CompareBuild(A, B: Integer): Integer;
    function CompareTiles(A, B: Integer): Integer;
    procedure SortTiles;
    procedure SetSort(V: TTileSort);
    procedure TakeState(ASel: TStringList; out AFocus: string; out AScroll: Integer);
    procedure PutState(ASel: TStringList; const AFocus: string; AScroll: Integer);
    procedure GridInfo(Sender: TObject; Index: Integer; out Info: TAuTileInfo);
    function GridArt(Sender: TObject; Index: Integer; var ABudget: Integer;
      out APending: Boolean): TGfxBitmap;
    function GridTypeText(Sender: TObject; Index: Integer): string;
    procedure GridPrepare(Sender: TObject);
    function WantedThumbPx: Integer;
  public
    Grid: TAuTileGrid;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { the tiles of these tracks (nil: none). AFound: the sorted paths of the
      tracks a search found as tracks, or nil; AQuery: what was searched for.
      ACrumb: the line above the tiles (a path: its parts joined by #1); ACanClear: with the button that
      widens it to all albums; AKeep: the albums that were selected are
      selected again and the tiles stay where they were scrolled to (the
      same part of the library, read again) }
    procedure SetTracks(AList: TTrackList; AFound: TStringList; const AQuery, ACrumb, AEmptyText: string;
      ACanClear: Boolean; AKeep: Boolean = False);
    function TileCount: Integer;
    procedure ClearThumbCache;
    { the two sort buttons move into AHost (the caller places them there) or,
      with nil, back into the line above the tiles. With the buttons
      elsewhere that line is slim, and hidden while it would only say
      "All albums". }
    procedure HostSort(AHost: TWinControl);
    function BtnSort: TAuButton;
    function BtnDir: TAuIconButton;
    { a tile by its place in the grid }
    function Tile(Index: Integer): PLibTile;
    property Sort: TTileSort read FSort write SetSort;
    { the chosen order backwards }
    property Reverse: Boolean read FReverse write SetReverse;
    { a part of the path above the tiles was clicked (0 = the first) }
    property OnCrumbClick: TCrumbClickEvent read FOnCrumbClick write FOnCrumbClick;
    property OnOffline: TTileOfflineEvent read FOnOffline write FOnOffline;
    property OnSortChange: TNotifyEvent read FOnSortChange write FOnSortChange;
    property OnClearScope: TNotifyEvent read FOnClearScope write FOnClearScope;
  end;

const
  TILE_SORT_NAMES: array[TTileSort] of string = ('Artist', 'Album', 'Year', 'Added to library');
  LBL_ALL_ALBUMS = 'All albums';

implementation

uses
  AuAudioTypes, uAppConsts, uAppStrings, uMetaUtils;

const
  LBL_VARIOUS_ARTISTS = 'Various artists';
  { the thumbnails kept in memory may take this much: beyond it they are all
    let go and the ones in view are read again }
  THUMB_MEMORY = 48 * 1024 * 1024;
  THUMB_PX_STEP = 64;
  { below this width (unscaled) the line above the tiles has no arrow button }
  NARROW_HEAD_WIDTH = 250;

{ multi-line tags flattened }
function OneLine(const S: string): string;
begin
  Result := Trim(S);
  if (Pos(#10, Result) = 0) and (Pos(#13, Result) = 0) then Exit;
  Result := StringReplace(Result, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
end;

{ ---- TCrumbBar ---- }

constructor TCrumbBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHotPart := -1;
end;

function TCrumbBar.PartCount: Integer;
begin
  Result := Length(FParts);
end;

function TCrumbBar.NeededWidth: Integer;
var
  I: Integer;
  F: TGfxFont;
begin
  Result := 0;
  F := UIFont(12);
  for I := 0 to High(FParts) do
  begin
    Inc(Result, Ceil(TextWidth(FParts[I], F)) + S(2));
    if I > 0 then Inc(Result, S(16));
  end;
end;

procedure TCrumbBar.SetPath(const APath: string);
var
  SL: TStringList;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Delimiter := #1;
    SL.StrictDelimiter := True;
    SL.DelimitedText := APath;
    SetLength(FParts, SL.Count);
    for I := 0 to SL.Count - 1 do FParts[I] := OneLine(SL[I]);
  finally
    SL.Free;
  end;
  FLinks := Length(FParts) > 1;
  SetLength(FRects, Length(FParts));
  for I := 0 to High(FRects) do FRects[I] := Rect(0, 0, 0, 0);
  FHotPart := -1;
  Cursor := crDefault;
  Invalidate;
end;

{ a part that can be clicked at this point, or -1 }
function TCrumbBar.PartAt(X, Y: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  if not FLinks then Exit;
  for I := 0 to High(FParts) - 1 do
    if (I <= High(FRects)) and (X >= FRects[I].Left) and (X < FRects[I].Right) and
       (Y >= FRects[I].Top) and (Y < FRects[I].Bottom) then Exit(I);
end;

procedure TCrumbBar.DoPaint(G: TGfx);
const
  DOTS = '...';
var
  F: TGfxFont;
  W: array of Integer;
  I, First, Total, SepW, DotsW, X, PW: Integer;
  C: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  for I := 0 to High(FRects) do FRects[I] := Rect(0, 0, 0, 0);
  if Length(FParts) = 0 then Exit;
  F := UIFont(12);
  SepW := S(16);
  DotsW := Ceil(TextWidth(DOTS, F)) + SepW;
  W := nil;
  SetLength(W, Length(FParts));
  Total := 0;
  for I := 0 to High(FParts) do
  begin
    W[I] := Ceil(TextWidth(FParts[I], F)) + S(2);
    Inc(Total, W[I]);
    if I > 0 then Inc(Total, SepW);
  end;
  { too long: the first parts go, the last one always stays }
  First := 0;
  while (First < High(FParts)) and (Total + IfThen(First > 0, DotsW, 0) > Width) do
  begin
    Dec(Total, W[First] + SepW);
    Inc(First);
  end;
  X := 0;
  if First > 0 then
  begin
    G.Text(DOTS, X, 0, DotsW - SepW, Height, F, clTextFaint, 0, 1);
    DrawIcon(G, icChevronRight, X + DotsW - SepW / 2, Height / 2, S(9), clTextFaint);
    Inc(X, DotsW);
  end;
  for I := First to High(FParts) do
  begin
    PW := Math.Min(W[I], Math.Max(S(10), Width - X));
    if I = High(FParts) then C := clText
    else if I = FHotPart then C := clAccentText
    else C := clTextDim;
    G.Text(FParts[I], X, 0, PW, Height, F, C, 0, 1);
    if (I = FHotPart) and (I < High(FParts)) then
      G.FillRect(X, Height div 2 + S(9), PW - S(2), Math.Max(1, S(1)), clAccentText);
    FRects[I] := Rect(X, S(4), X + PW, Height - S(4));
    Inc(X, PW);
    if I < High(FParts) then
    begin
      DrawIcon(G, icChevronRight, X + SepW / 2, Height / 2, S(9), clTextFaint);
      Inc(X, SepW);
    end;
  end;
end;

procedure TCrumbBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  P: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  P := PartAt(X, Y);
  if P = FHotPart then Exit;
  FHotPart := P;
  if P >= 0 then Cursor := crHandPoint else Cursor := crDefault;
  Invalidate;
end;

procedure TCrumbBar.MouseLeave;
begin
  inherited MouseLeave;
  if FHotPart < 0 then Exit;
  FHotPart := -1;
  Cursor := crDefault;
  Invalidate;
end;

procedure TCrumbBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  P: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  P := PartAt(X, Y);
  if (P >= 0) and Assigned(FOnPartClick) then FOnPartClick(Self, P);
end;

{ ---- TLibraryTiles ---- }

constructor TLibraryTiles.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crPanel;
  FThumbs := TStringList.Create;
  FThumbs.Sorted := True;
  FThumbs.Duplicates := dupIgnore;
  FThumbs.UseLocale := False;
  FSortMenu := TAuMenu.Create;
  FHead := TAuPanel.Create(Self);
  FHead.Parent := Self;
  FHead.Align := alTop;
  FHead.Height := S(34);
  FHead.OnResize := @HeadResize;
  FCrumb := TCrumbBar.Create(Self);
  FCrumb.Parent := FHead;
  FCrumb.OnPartClick := @CrumbClick;
  FBtnClear := TAuIconButton.Create(Self);
  FBtnClear.Parent := FHead;
  FBtnClear.Icon := icClose;
  FBtnClear.IconSize := 11;
  FBtnClear.Hint := 'Show all albums';
  FBtnClear.ShowHint := True;
  FBtnClear.Visible := False;
  FBtnClear.OnClick := @ClearClick;
  FBtnSort := TAuButton.Create(Self);
  FBtnSort.Parent := FHead;
  FBtnSort.Kind := bkFlat;
  FBtnSort.Hint := 'Sort: the order of the tiles';
  FBtnSort.ShowHint := True;
  FBtnSort.OnClick := @SortClick;
  FBtnDir := TAuIconButton.Create(Self);
  FBtnDir.Parent := FHead;
  FBtnDir.IconSize := 16;
  FBtnDir.Hint := 'Reverse the order';
  FBtnDir.ShowHint := True;
  FBtnDir.OnClick := @DirClick;
  ShowSort;
  Grid := TAuTileGrid.Create(Self);
  Grid.Parent := Self;
  Grid.Align := alClient;
  Grid.BorderSpacing.Left := S(4);
  Grid.BorderSpacing.Bottom := S(4);
  Grid.DragEnabled := True;
  Grid.OnInfo := @GridInfo;
  Grid.OnArt := @GridArt;
  Grid.OnTypeText := @GridTypeText;
  Grid.OnPrepare := @GridPrepare;
  HeadResize(nil);
end;

destructor TLibraryTiles.Destroy;
var
  I: Integer;
begin
  for I := 0 to FThumbs.Count - 1 do
    if FThumbs.Objects[I] <> nil then DisposeBitmap(TGfxBitmap(FThumbs.Objects[I]));
  FThumbs.Free;
  FSortMenu.Free;
  inherited Destroy;
end;

procedure TLibraryTiles.HeadResize(Sender: TObject);
var
  X, R, W: Integer;
begin
  if (FCrumb = nil) or (FBtnSort = nil) or (FBtnDir = nil) or (FBtnClear = nil) then Exit;
  R := FHead.Width - S(6);
  if FSortHost = nil then
  begin
    { at the right: the arrow and the name of the order, as above the
      playlist; a narrow pane has no room for the arrow }
    W := Math.Min(FBtnSort.PreferredWidth, Math.Max(S(40), FHead.Width div 2));
    FBtnSort.SetBounds(R - W, S(3), W, S(28));
    R := FBtnSort.Left;
    FBtnDir.Visible := FHead.Width >= S(NARROW_HEAD_WIDTH);
    if FBtnDir.Visible then
    begin
      FBtnDir.SetBounds(R - S(30), S(3), S(30), S(28));
      R := FBtnDir.Left;
    end;
  end;
  R := R - S(4);
  X := S(14);
  { the cross follows the path }
  W := Math.Max(S(20), R - X);
  if FBtnClear.Visible then W := Math.Max(S(20), W - S(28));
  W := Math.Min(W, Math.Max(S(20), FCrumb.NeededWidth + S(2)));
  FCrumb.SetBounds(X, 0, W, FHead.Height);
  if FBtnClear.Visible then
    FBtnClear.SetBounds(FCrumb.Left + FCrumb.Width + S(2), (FHead.Height - S(22)) div 2, S(26), S(22));
end;

function TLibraryTiles.BtnSort: TAuButton;
begin
  Result := FBtnSort;
end;

function TLibraryTiles.BtnDir: TAuIconButton;
begin
  Result := FBtnDir;
end;

procedure TLibraryTiles.HostSort(AHost: TWinControl);
begin
  if AHost = FSortHost then Exit;
  FSortHost := AHost;
  if AHost = nil then AHost := FHead;
  FBtnSort.Parent := AHost;
  FBtnDir.Parent := AHost;
  FBtnDir.Visible := True;
  { in the line above the tiles the Tab key goes from left to right: the
    cross, the arrow, the order's name (a host sets its own order) }
  if FSortHost = nil then
  begin
    FBtnClear.TabOrder := 0;
    FBtnDir.TabOrder := 1;
    FBtnSort.TabOrder := 2;
  end;
  UpdateHead;
end;

{ the line above the tiles: tall with the sort buttons in it, slim without
  them, and not there while it would only say "All albums" }
procedure TLibraryTiles.UpdateHead;
var
  H: Integer;
  NeedLine: Boolean;
begin
  if FSortHost = nil then H := S(34) else H := S(26);
  NeedLine := (FSortHost = nil) or not FPlainAll;
  if FHead.Height <> H then FHead.Height := H;
  if FHead.Visible <> NeedLine then FHead.Visible := NeedLine;
  { without the line the first tiles stand where the first album header of
    the playlist stands }
  if NeedLine then Grid.TopPad := 8 else Grid.TopPad := 5;
  HeadResize(nil);
end;

procedure TLibraryTiles.ClearClick(Sender: TObject);
begin
  if Assigned(FOnClearScope) then FOnClearScope(Self);
end;

procedure TLibraryTiles.SortClick(Sender: TObject);
var
  K: TTileSort;
  It: TAuMenuItem;
begin
  FSortMenu.Clear;
  for K := Low(TTileSort) to High(TTileSort) do
  begin
    It := FSortMenu.Add(TILE_SORT_NAMES[K], @SortItemClick, icNone, '', Ord(K));
    It.Checked := K = FSort;
  end;
  FSortMenu.PopupBelow(FBtnSort, True);
end;

procedure TLibraryTiles.SortItemClick(Sender: TObject);
begin
  if Sender is TAuMenuItem then
    SetSort(TTileSort(EnsureRange(TAuMenuItem(Sender).Tag, Ord(Low(TTileSort)), Ord(High(TTileSort)))));
end;

procedure TLibraryTiles.SetSort(V: TTileSort);
begin
  if V = FSort then Exit;
  FSort := V;
  Resort;
end;

procedure TLibraryTiles.SetReverse(V: Boolean);
begin
  if V = FReverse then Exit;
  FReverse := V;
  Resort;
end;

{ the tiles in the chosen order: what was selected stays selected, the
  tiles scroll to where the focus is now }
procedure TLibraryTiles.Resort;
var
  Sel: TStringList;
  Focus: string;
  Scroll: Integer;
begin
  Sel := TStringList.Create;
  try
    TakeState(Sel, Focus, Scroll);
    SortTiles;
    Grid.SetCount(FTileN);
    PutState(Sel, Focus, -1);
  finally
    Sel.Free;
  end;
  ShowSort;
  if Assigned(FOnSortChange) then FOnSortChange(Self);
end;

{ the two sort buttons say what is chosen }
procedure TLibraryTiles.ShowSort;
begin
  FBtnSort.Caption := TILE_SORT_NAMES[FSort];
  if FReverse then FBtnDir.Icon := icSortDesc else FBtnDir.Icon := icSortAsc;
  FBtnDir.Invalidate;
  HeadResize(nil);
end;

procedure TLibraryTiles.DirClick(Sender: TObject);
begin
  SetReverse(not FReverse);
end;

procedure TLibraryTiles.CrumbClick(Sender: TObject; Index: Integer);
begin
  if Assigned(FOnCrumbClick) then FOnCrumbClick(Self, Index);
end;

{ the selected albums by their keys, the focused one and the scroll position }
procedure TLibraryTiles.TakeState(ASel: TStringList; out AFocus: string; out AScroll: Integer);
var
  I: Integer;
begin
  ASel.UseLocale := False;
  ASel.CaseSensitive := True;
  ASel.Sorted := True;
  ASel.Duplicates := dupIgnore;
  AFocus := '';
  for I := 0 to FTileN - 1 do
    if Grid.Selected[I] then ASel.Add(Tile(I)^.Key);
  if Tile(Grid.FocusIndex) <> nil then AFocus := Tile(Grid.FocusIndex)^.Key;
  AScroll := Grid.ScrollOffset;
end;

procedure TLibraryTiles.PutState(ASel: TStringList; const AFocus: string; AScroll: Integer);
var
  Sel: TAuTileIntArray;
  I, N, Focus, At: Integer;
begin
  Sel := nil;
  SetLength(Sel, FTileN);
  N := 0;
  Focus := -1;
  for I := 0 to FTileN - 1 do
  begin
    if ASel.Find(Tile(I)^.Key, At) then
    begin
      Sel[N] := I;
      Inc(N);
    end;
    if (AFocus <> '') and (Tile(I)^.Key = AFocus) then Focus := I;
  end;
  SetLength(Sel, N);
  Grid.RestoreState(Sel, Focus, AScroll);
end;

function TLibraryTiles.Tile(Index: Integer): PLibTile;
begin
  if (Index < 0) or (Index >= FTileN) then Exit(nil);
  Result := @FTiles[FOrder[Index]];
end;

{ ---- building ---- }

procedure TLibraryTiles.SortIdx(var A: array of Integer; L, R: Integer; Cmp: TTileIdxCompare);
var
  I, J, P, T: Integer;
begin
  while L < R do
  begin
    I := L;
    J := R;
    P := A[(L + R) shr 1];
    repeat
      while Cmp(A[I], P) < 0 do Inc(I);
      while Cmp(A[J], P) > 0 do Dec(J);
      if I <= J then
      begin
        T := A[I];
        A[I] := A[J];
        A[J] := T;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    { the smaller part by a call, the larger one in the loop }
    if J - L < R - I then
    begin
      SortIdx(A, L, J, Cmp);
      L := I;
    end
    else
    begin
      SortIdx(A, I, R, Cmp);
      R := J;
    end;
  end;
end;

{ the tracks: by album, then in album order }
function TLibraryTiles.CompareBuild(A, B: Integer): Integer;
begin
  Result := CompareStr(FBuild[A].Key, FBuild[B].Key);
  if Result <> 0 then Exit;
  Result := FBuild[A].Disc - FBuild[B].Disc;
  if Result <> 0 then Exit;
  Result := FBuild[A].Track - FBuild[B].Track;
  if Result <> 0 then Exit;
  Result := CompareStr(FBuild[A].T^.FilePath, FBuild[B].T^.FilePath);
  if Result = 0 then Result := A - B;
end;

function TLibraryTiles.CompareTiles(A, B: Integer): Integer;

  function ByArtist: Integer;
  begin
    Result := CompareLibraryNames(FTiles[A].Artist, FTiles[B].Artist);
  end;

  function ByTitle: Integer;
  begin
    Result := CompareLibraryNamesNatural(FTiles[A].Title, FTiles[B].Title);
  end;

  { an album without a year after those with one }
  function ByYear: Integer;
  var
    YA, YB: Integer;
  begin
    YA := FTiles[A].Year;
    YB := FTiles[B].Year;
    if YA <= 0 then YA := MaxInt;
    if YB <= 0 then YB := MaxInt;
    Result := CompareValue(YA, YB);
  end;

begin
  Result := 0;
  case FSort of
    tsArtist:
      begin
        Result := ByArtist;
        if Result = 0 then Result := ByYear;
        if Result = 0 then Result := ByTitle;
      end;
    tsAlbum:
      begin
        Result := ByTitle;
        if Result = 0 then Result := ByArtist;
      end;
    tsYear:
      begin
        Result := ByYear;
        if Result = 0 then Result := ByArtist;
        if Result = 0 then Result := ByTitle;
      end;
    tsAdded:
      begin
        Result := CompareValue(FTiles[B].Added, FTiles[A].Added);     // the newest first
        if Result = 0 then Result := ByArtist;
        if Result = 0 then Result := ByTitle;
      end;
  end;
  if FReverse then Result := -Result;
  if Result = 0 then Result := A - B;
end;

procedure TLibraryTiles.SortTiles;
var
  I: Integer;
begin
  SetLength(FOrder, FTileN);
  for I := 0 to FTileN - 1 do FOrder[I] := I;
  if FTileN > 1 then SortIdx(FOrder, 0, FTileN - 1, @CompareTiles);
end;

function TLibraryTiles.TileCount: Integer;
begin
  Result := FTileN;
end;

procedure TLibraryTiles.SetTracks(AList: TTrackList; AFound: TStringList; const AQuery, ACrumb,
  AEmptyText: string; ACanClear, AKeep: Boolean);
var
  Idx: array of Integer;
  I, N, FoundAt: Integer;
  T: PTrackInfo;
  Alb, Art, LastKey: string;
  Cur: PLibTile;
  ArtistFixed: Boolean;
  KeepSel: TStringList;
  KeepFocus: string;
  KeepScroll: Integer;
begin
  KeepSel := TStringList.Create;
  try
  TakeState(KeepSel, KeepFocus, KeepScroll);
  FTileN := 0;
  FTiles := nil;
  FQuery := UTF8LowerCase(Trim(AQuery));
  if AList = nil then N := 0 else N := AList.Count;
  Idx := nil;
  SetLength(FBuild, N);
  SetLength(Idx, N);
  try
    for I := 0 to N - 1 do
    begin
      T := AList[I];
      Alb := Trim(T^.Album);
      Art := Trim(T^.AlbumArtist);
      if (Alb = '') or SameText(Alb, LBL_UNKNOWN_ALBUM) then
        FBuild[I].Key := #2 + UTF8LowerCase(ExcludeTrailingPathDelimiter(T^.FolderDir))
      else if Art = '' then
        FBuild[I].Key := #1 + UTF8LowerCase(Alb) + #1 + UTF8LowerCase(ExcludeTrailingPathDelimiter(T^.FolderDir))
      else
        FBuild[I].Key := UTF8LowerCase(Art) + #1 + UTF8LowerCase(Alb);
      FBuild[I].Disc := T^.DiscNumber;
      FBuild[I].Track := T^.TrackNumber;
      FBuild[I].T := T;
      Idx[I] := I;
    end;
    if N > 1 then SortIdx(Idx, 0, N - 1, @CompareBuild);
    SetLength(FTiles, 64);
    Cur := nil;
    LastKey := '';
    ArtistFixed := False;
    for I := 0 to N - 1 do
    begin
      T := FBuild[Idx[I]].T;
      if (Cur = nil) or (FBuild[Idx[I]].Key <> LastKey) then
      begin
        LastKey := FBuild[Idx[I]].Key;
        if FTileN >= Length(FTiles) then SetLength(FTiles, Length(FTiles) * 2);
        Cur := @FTiles[FTileN];
        Inc(FTileN);
        Cur^ := Default(TLibTile);
        Cur^.Key := LastKey;
        Cur^.RawArtist := T^.AlbumArtist;
        Cur^.RawAlbum := T^.Album;
        Cur^.FolderDir := T^.FolderDir;
        Alb := Trim(T^.Album);
        if (Alb = '') or SameText(Alb, LBL_UNKNOWN_ALBUM) then
          Cur^.Title := ExtractFileName(ExcludeTrailingPathDelimiter(T^.FolderDir))
        else
          Cur^.Title := OneLine(Alb);
        if Cur^.Title = '' then Cur^.Title := T^.FolderDir;
        Cur^.Artist := OneLine(T^.AlbumArtist);
        ArtistFixed := Cur^.Artist <> '';
        if not ArtistFixed then Cur^.Artist := OneLine(T^.Artist);
        Cur^.Year := T^.Year;
        Cur^.Added := T^.DateAdded;
      end
      else
      begin
        { the same file twice (it came from two sources) }
        if (Cur^.PathCount > 0) and (Cur^.Paths[Cur^.PathCount - 1] = T^.FilePath) then Continue;
        if (not ArtistFixed) and not SameText(OneLine(T^.Artist), Cur^.Artist) then
        begin
          Cur^.Artist := LBL_VARIOUS_ARTISTS;
          ArtistFixed := True;
        end;
        if Cur^.Year <= 0 then Cur^.Year := T^.Year;
        if T^.DateAdded > Cur^.Added then Cur^.Added := T^.DateAdded;
      end;
      if Cur^.PathCount >= Length(Cur^.Paths) then
        SetLength(Cur^.Paths, Math.Max(16, Length(Cur^.Paths) * 2));
      Cur^.Paths[Cur^.PathCount] := T^.FilePath;
      Inc(Cur^.PathCount);
      if (AFound <> nil) and AFound.Find(T^.FilePath, FoundAt) then Inc(Cur^.Found);
    end;
  finally
    FBuild := nil;
  end;
  SortTiles;
  FCrumb.SetPath(ACrumb);
  FBtnClear.Visible := ACanClear;
  FPlainAll := (not ACanClear) and (FQuery = '');
  UpdateHead;
  Grid.EmptyText := AEmptyText;
  Grid.SetCount(FTileN);
  if AKeep then PutState(KeepSel, KeepFocus, KeepScroll);
  finally
    KeepSel.Free;
  end;
end;

{ ---- the grid's questions ---- }

procedure TLibraryTiles.GridInfo(Sender: TObject; Index: Integer; out Info: TAuTileInfo);
var
  T: PLibTile;
begin
  Info := Default(TAuTileInfo);
  T := Tile(Index);
  if T = nil then Exit;
  Info.Title := T^.Title;
  { an album that is there for some of its tracks only (its own name and
    artist do not hold what was searched for): how many were found }
  if (T^.Found > 0) and (T^.Found < T^.PathCount) and (FQuery <> '') and
     (Pos(FQuery, UTF8LowerCase(T^.Title)) = 0) and (Pos(FQuery, UTF8LowerCase(T^.Artist)) = 0) then
  begin
    if T^.Found = 1 then Info.Sub := '1 track found'
    else Info.Sub := Format('%d tracks found', [T^.Found]);
  end
  else if (FSort = tsYear) and (T^.Year > 0) then
    Info.Sub := Trim(IntToStr(T^.Year) + '  ' + T^.Artist)
  else
    Info.Sub := T^.Artist;
  Info.ArtKey := T^.RawAlbum + T^.RawArtist;
  if T^.Offline = 0 then
  begin
    if Assigned(FOnOffline) and FOnOffline(T^.FolderDir) then T^.Offline := 2
    else T^.Offline := 1;
  end;
  Info.Dim := T^.Offline = 2;
end;

function TLibraryTiles.GridTypeText(Sender: TObject; Index: Integer): string;
var
  T: PLibTile;
begin
  Result := '';
  T := Tile(Index);
  if T = nil then Exit;
  if FSort = tsArtist then Result := T^.Artist else Result := T^.Title;
end;

function TLibraryTiles.GridArt(Sender: TObject; Index: Integer; var ABudget: Integer;
  out APending: Boolean): TGfxBitmap;
var
  T: PLibTile;
  F: string;
  I: Integer;
begin
  Result := nil;
  APending := False;
  T := Tile(Index);
  if (T = nil) or (AppCacheThumbsDir = '') then Exit;
  if T^.Hash = '' then T^.Hash := GenerateAlbumHash(T^.RawArtist, T^.RawAlbum, T^.FolderDir);
  if FThumbs.Find(T^.Hash, I) then Exit(TGfxBitmap(FThumbs.Objects[I]));
  if ABudget <= 0 then
  begin
    APending := True;
    Exit;
  end;
  Dec(ABudget);
  F := AppCacheThumbsDir + T^.Hash + '.jpg';
  if FileExists(LongPath(F)) then Result := ImageFromFile(F, FThumbPx);
  FThumbs.AddObject(T^.Hash, TObject(Result));
end;

{ before a paint draws: too many thumbnails are let go (never during the
  paint - a picture drawn in it must live until it ends) }
{ the thumbnails are read at the size they are shown at, in steps (a small
  tile does not keep a large picture) }
function TLibraryTiles.WantedThumbPx: Integer;
begin
  Result := EnsureRange(((Grid.ArtPixels + THUMB_PX_STEP - 1) div THUMB_PX_STEP) * THUMB_PX_STEP,
    THUMB_PX_STEP, CACHE_THUMB_SIZE);
end;

procedure TLibraryTiles.GridPrepare(Sender: TObject);
var
  I, Px: Integer;
begin
  Px := WantedThumbPx;
  if (Px = FThumbPx) and
     (Int64(FThumbs.Count) * FThumbPx * FThumbPx * 4 <= THUMB_MEMORY) then Exit;
  FThumbPx := Px;
  for I := 0 to FThumbs.Count - 1 do
    if FThumbs.Objects[I] <> nil then DisposeBitmap(TGfxBitmap(FThumbs.Objects[I]));
  FThumbs.Clear;
end;

procedure TLibraryTiles.ClearThumbCache;
var
  I: Integer;
begin
  if FThumbs = nil then Exit;
  for I := 0 to FThumbs.Count - 1 do
    if FThumbs.Objects[I] <> nil then DisposeBitmap(TGfxBitmap(FThumbs.Objects[I]));
  FThumbs.Clear;
  if (Grid <> nil) and Grid.HandleAllocated then Grid.Invalidate;
end;

end.
