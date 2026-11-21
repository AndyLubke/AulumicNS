unit AuLibraryPane;

{ ==============================================================================
  AulumicNS - AuLibraryPane
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The library pane on the left of the main window, on the tree control
  (TAuTreeView): a search box and the rescan
  button above the library tree with the categories Folders, Artists,
  Albums and Genres (Artists / Albums / Genres as set in the preferences).

  Two buttons next to the search box switch between the tree and tiles
  (TLibraryTiles): the albums under the node selected in the tree, or what
  the search finds, as covers. The tree stays as it is behind the tiles.
  What is done with a tile is done with the tracks of its album: the tiles
  answer ActionNodes with one track node per track (nodes that are in no
  tree), so everything that works on the tree's selection works on tiles.

  How it works:
  - the children of a node are read from the library when it is opened
    (OnExpanding), never from the disk: a sleeping drive is not woken, an
    unplugged drive still shows its folders (a library folder that cannot be
    reached is shown dimmed with "(not available)");
  - virtual folders (.aullink) list their target folders (from the library);
  - typing in the search box (2 characters or more, after a short pause)
    shows the matching folders, artists, albums, genres and tracks;
  - a refresh keeps the opened nodes, the selection and the scroll position.

  The node data is in the tree node itself:
  Kind = TLibNodeType, Tag = TLibCategory for a category node, Text = the
  name it stands for (artist, album, genre), Path = folder / file / link,
  Filter = the artist or genre of an album below it, Data = flag bits
  (LNF_VIRTUAL, LNF_OFFLINE). The code decides by these, never by the shown
  caption.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, LCLType, ExtCtrls, StrUtils,
  AuGfx, AuTheme, AuIcons, AuControls, AuTree, AuTileGrid, AuLibraryTiles, uLibraryTypes, uLibraryManager;

type
  TLibNodeType = (lntCategory, lntArtist, lntArtistAlbum, lntAlbum, lntGenre, lntGenreAlbum,
    lntFolder, lntTrack);
  TLibCategory = (lcNone, lcFolders, lcArtists, lcAlbums, lcGenres, lcTracks);

const
  LNF_VIRTUAL = 1;     // a virtual folder (.aullink)
  LNF_OFFLINE = 2;     // a library folder that could not be reached

type
  { TLibraryPane }

  TLibraryPane = class(TAuPanel)
  private
    FTop: TAuPanel;
    FLib: TLibraryManager;
    FSearchTimer: TTimer;
    FSearchActive: Boolean;
    FHasOfflineFolders: Boolean;
    FTileMode: Boolean;
    FTileAll: Boolean;            // the tiles show all albums, not the tree's node
    FTileQuery: string;           // the search the tiles were made for
    FTileNodes: TFPList;          // the track nodes handed out by ActionNodes
    FOnTileModeChange: TNotifyEvent;
    FWantTopRow, FWantTileScroll: Integer;   // the scroll positions of the last run, put back once the window is laid out
    procedure ScrollLater(Data: PtrInt);
    procedure TreeBtnClick(Sender: TObject);
    procedure TilesBtnClick(Sender: TObject);
    procedure TileSizeWheel(Sender: TObject; Index: Integer);
    procedure TileSortChange(Sender: TObject);
    procedure TileClearScope(Sender: TObject);
    procedure TileCrumbClick(Sender: TObject; Index: Integer);
    function TileOffline(const AFolder: string): Boolean;
    procedure FreeTileNodes;
    function TileActionNodes: TAuTreeNodeArray;
    function SearchQuery: string;
    procedure TopResize(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure SearchTimer(Sender: TObject);
    procedure TreeExpanding(Sender: TObject; Node: TAuTreeNode);
    function AddNode(AParent: TAuTreeNode; AType: TLibNodeType; const ACaption, AText, APath: string;
      AIcon: TAuIcon; AHasChildren: Boolean): TAuTreeNode;
    function AddCategory(const ACaption: string; ACat: TLibCategory; AIcon: TAuIcon): TAuTreeNode;
    procedure FillTracks(ANode: TAuTreeNode; AList: TTrackList; AWithNumbers: Boolean);
    procedure FillFolder(ANode: TAuTreeNode);
    procedure UpdateRootAvailability(ANode: TAuTreeNode);
    procedure CollectExpanded(N: TAuTreeNode; AList: TStrings);
    function GetFlags(N: TAuTreeNode): PtrInt;
  public
    Search: TAuEdit;
    BtnRescan: TAuIconButton;
    BtnTree, BtnTiles: TAuIconButton;
    Tree: TAuTreeView;
    Tiles: TLibraryTiles;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { ARestoreView: the opened nodes, the selection and the scroll positions
      of the last run come back (SaveView wrote them) }
    procedure Init(ALib: TLibraryManager; ARestoreView: Boolean = False);
    { the place in the library into the settings: the tree's opened nodes,
      selection and first row, what the tiles show and how far they are
      scrolled. Not while a search is shown. }
    procedure SaveView;
    { the four categories, all closed }
    procedure Populate;
    { rebuilds the tree from the library, keeping the opened nodes, the
      selection and the scroll position; ends a search }
    procedure RefreshLibrary;
    { F5: a folder node is filled again from the library, else RefreshLibrary }
    procedure RefreshCurrentFolder;
    procedure PerformSearch;
    procedure ClearSearch;
    { copies of the tracks of the nodes, in library order per node; virtual
      folders give the tracks of their targets }
    procedure CollectTracks(const ANodes: TAuTreeNodeArray; AList: TTrackList);
    { the selected nodes (the focused one when nothing is selected); with
      the tiles shown: a track node for every track of the selected tiles }
    function ActionNodes: TAuTreeNodeArray;
    { tiles or the tree; ASave: the choice is kept in the settings }
    procedure SetTileMode(AOn, ASave: Boolean);
    { the tiles again from the library: the search, else the tree's node.
      AKeep: the same part of the library read again - selection and scroll
      position stay }
    procedure RebuildTiles(AKeep: Boolean = False);
    { the tiles take the text size of the tree }
    procedure TextSizeChanged;
    function ListFocused: Boolean;
    procedure FocusList;
    { back to the tree, at the folder of this tile (during a search: at what
      was found) }
    procedure ShowTileInTree(Index: Integer);
    function TileFolder(Index: Integer): string;
    { the controls above the tree in the order the Tab key visits them
      ("search arrow order tree tiles rescan"), with their left edges - a
      check for the shot mode }
    function TopTabOrder: string;
    property TileMode: Boolean read FTileMode;
    property OnTileModeChange: TNotifyEvent read FOnTileModeChange write FOnTileModeChange;
    procedure ExpandAll(N: TAuTreeNode);
    procedure ShowScanning(AScanning: Boolean);
    { demo content for the screenshots (debug --shots): no library needed }
    procedure FillDemo;
    function NodeType(N: TAuTreeNode): TLibNodeType;
    function Category(N: TAuTreeNode): TLibCategory;
    function IsVirtualLink(N: TAuTreeNode): Boolean;
    function IsInsideVirtualLink(N: TAuTreeNode): Boolean;
    function IsOffline(N: TAuTreeNode): Boolean;
    property HasOfflineFolders: Boolean read FHasOfflineFolders;
    property SearchActive: Boolean read FSearchActive;
  end;

const
  NODE_FOLDERS = 'Folders';
  NODE_ARTISTS = 'Artists';
  NODE_ALBUMS  = 'Albums';
  NODE_GENRES  = 'Genres';
  NODE_TRACKS  = 'Tracks';
  { below this width (unscaled) the pane has one button for tree / tiles }
  NARROW_PANE_WIDTH = 290;
  { from this width (unscaled) the tiles' sort buttons are next to the search box }
  SORT_IN_TOP_WIDTH = 400;
  LIB_EMPTY_TEXT = 'The library is empty.' + LineEnding +
    'Add the music folders: Main menu > Library > Library folders...';

implementation

uses
  uInputBlock, uAppConsts, uAppStrings, uAudioUtils, uSettingsManager, uOSUtils, AuLog;

{ multi-line tags flattened }
function CleanNodeText(const S: string): string;
begin
  Result := Trim(S);
  if (Pos(#10, Result) = 0) and (Pos(#13, Result) = 0) then Exit;
  Result := StringReplace(Result, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
end;

constructor TLibraryPane.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crPanel;
  FTop := TAuPanel.Create(Self);
  FTop.Parent := Self;
  FTop.Align := alTop;
  FTop.Height := S(50);
  FTop.OnResize := @TopResize;
  Search := TAuEdit.Create(Self);
  Search.Parent := FTop;
  Search.Search := True;
  Search.Placeholder := 'Search here... (Ctrl+F)';
  Search.OnChange := @SearchChange;
  BtnRescan := TAuIconButton.Create(Self);
  BtnRescan.Parent := FTop;
  BtnRescan.Icon := icRefresh;
  BtnRescan.IconSize := 17;
  BtnRescan.Hint := 'Rescan the library folders (Ctrl+F5)';
  BtnRescan.ShowHint := True;
  BtnTree := TAuIconButton.Create(Self);
  BtnTree.Parent := FTop;
  BtnTree.Icon := icList;
  BtnTree.IconSize := 16;
  BtnTree.Active := True;
  BtnTree.Hint := 'Show the library as a tree (Ctrl+G)';
  BtnTree.ShowHint := True;
  BtnTree.OnClick := @TreeBtnClick;
  BtnTiles := TAuIconButton.Create(Self);
  BtnTiles.Parent := FTop;
  BtnTiles.Icon := icGrid;
  BtnTiles.IconSize := 16;
  BtnTiles.Hint := 'Show the albums of the selected node as tiles (Ctrl+G)';
  BtnTiles.ShowHint := True;
  BtnTiles.OnClick := @TilesBtnClick;
  FTileNodes := TFPList.Create;
  Tiles := TLibraryTiles.Create(Self);
  Tiles.Parent := Self;
  Tiles.Align := alClient;
  Tiles.Visible := False;
  Tiles.OnSortChange := @TileSortChange;
  Tiles.OnClearScope := @TileClearScope;
  Tiles.OnCrumbClick := @TileCrumbClick;
  Tiles.OnOffline := @TileOffline;
  Tiles.Grid.OnSizeWheel := @TileSizeWheel;
  Tree := TAuTreeView.Create(Self);
  Tree.Parent := Self;
  Tree.Align := alClient;
  Tree.BorderSpacing.Left := S(4);
  Tree.BorderSpacing.Bottom := S(4);
  Tree.DragEnabled := True;
  Tree.MultiSelect := True;
  Tree.RowMenu := True;
  Tree.OnExpanding := @TreeExpanding;
  Tree.EmptyText := LIB_EMPTY_TEXT;
  FSearchTimer := TTimer.Create(Self);
  FSearchTimer.Enabled := False;
  FSearchTimer.Interval := LIB_SEARCH_DELAY_MS;
  FSearchTimer.OnTimer := @SearchTimer;
  Search.TabOrder := 0;
  BtnTree.TabOrder := 1;
  BtnTiles.TabOrder := 2;
  BtnRescan.TabOrder := 3;
  TopResize(nil);
end;

destructor TLibraryPane.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  FreeTileNodes;
  FTileNodes.Free;
  FTileNodes := nil;
  inherited Destroy;
end;

procedure TLibraryPane.TopResize(Sender: TObject);
var
  Right, VW: Integer;
begin
  if (Search = nil) or (BtnRescan = nil) or (BtnTree = nil) or (BtnTiles = nil) then Exit;
  BtnRescan.SetBounds(FTop.Width - S(10) - S(36), S(9), S(36), S(34));
  BtnTiles.SetBounds(BtnRescan.Left - S(32), S(9), S(32), S(34));
  BtnTree.SetBounds(BtnTiles.Left - S(32), S(9), S(32), S(34));
  { a narrow pane keeps the room for the search box: one button, which
    switches to and fro (TilesBtnClick) }
  BtnTree.Visible := FTop.Width >= S(NARROW_PANE_WIDTH);
  if BtnTree.Visible then Right := BtnTree.Left else Right := BtnTiles.Left;
  { with the tiles shown: their two sort buttons, placed as the playlist's
    are above the playlist. A pane too narrow for them keeps them in the
    line above the tiles. }
  if Tiles <> nil then
  begin
    if FTileMode and (FTop.Width >= S(SORT_IN_TOP_WIDTH)) then
    begin
      Tiles.HostSort(FTop);
      { the Tab key goes from left to right: the buttons that came in last
        stand between the search box and the tree button }
      Search.TabOrder := 0;
      Tiles.BtnDir.TabOrder := 1;
      Tiles.BtnSort.TabOrder := 2;
      BtnTree.TabOrder := 3;
      BtnTiles.TabOrder := 4;
      BtnRescan.TabOrder := 5;
      VW := Tiles.BtnSort.PreferredWidth;
      Tiles.BtnSort.SetBounds(Right - S(4) - VW, S(10), VW, S(32));
      Tiles.BtnDir.SetBounds(Tiles.BtnSort.Left - S(34), S(9), S(34), S(34));
      Right := Tiles.BtnDir.Left + S(2);
    end
    else
      Tiles.HostSort(nil);
  end;
  Search.SetBounds(S(10), S(10), Math.Max(S(40), Right - S(16)), S(32));
end;

{ a node's path for the settings file: its captions joined by '|' (a '|' or
  '%' inside a caption is written as %7C / %25) }
function PathToText(const APath: string): string;
begin
  Result := StringReplace(APath, '%', '%25', [rfReplaceAll]);
  Result := StringReplace(Result, '|', '%7C', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #1, '|', [rfReplaceAll]);
end;

function TextToPath(const AText: string): string;
begin
  Result := StringReplace(AText, '|', #1, [rfReplaceAll]);
  Result := StringReplace(Result, '%7C', '|', [rfReplaceAll]);
  Result := StringReplace(Result, '%25', '%', [rfReplaceAll]);
end;

const
  { between two paths in the settings file (a path has no empty part) }
  PATH_LIST_SEP = '||';
  { more opened nodes than this are not written }
  MAX_SAVED_OPEN_NODES = 300;

procedure TLibraryPane.SaveView;
var
  Expanded: TStringList;
  I: Integer;
  S1: string;
begin
  if (FLib = nil) or FSearchActive then Exit;
  Expanded := TStringList.Create;
  try
    for I := 0 to Tree.RootCount - 1 do CollectExpanded(Tree.Roots(I), Expanded);
    S1 := '';
    for I := 0 to Math.Min(Expanded.Count, MAX_SAVED_OPEN_NODES) - 1 do
    begin
      if I > 0 then S1 := S1 + PATH_LIST_SEP;
      S1 := S1 + PathToText(Expanded[I]);
    end;
    AppSettings.Data.LibraryExpanded := S1;
  finally
    Expanded.Free;
  end;
  if Tree.FocusedNode <> nil then AppSettings.Data.LibrarySelection := PathToText(Tree.NodePath(Tree.FocusedNode))
  else AppSettings.Data.LibrarySelection := '';
  AppSettings.Data.LibraryTopRow := Tree.TopRow;
  AppSettings.Data.LibraryTilesAll := FTileAll;
  { the tiles' position only while they show what the tree's node gives (not
    a search) }
  if FTileMode and (FTileQuery = '') then
    AppSettings.Data.LibraryTilesScroll := Round(Tiles.Grid.ScrollOffset / UIScale)
  else if not FTileMode then
    AppSettings.Data.LibraryTilesScroll := 0;
end;

{ the scroll positions of the last run: once the window has its size }
procedure TLibraryPane.ScrollLater(Data: PtrInt);
begin
  if FWantTopRow > 0 then Tree.TopRow := FWantTopRow;
  if FTileMode and (FWantTileScroll > 0) then
    Tiles.Grid.RestoreState(nil, -1, S(FWantTileScroll));
  FWantTopRow := 0;
  FWantTileScroll := 0;
end;

procedure TLibraryPane.Init(ALib: TLibraryManager; ARestoreView: Boolean);
var
  Parts: TStringList;
  I: Integer;
  N: TAuTreeNode;
  Sel, All: string;
begin
  FLib := ALib;
  Populate;
  if ARestoreView and (Tree.RootCount > 0) then
  begin
    { the nodes that were open (parents come before their children), then
      the selection; a node that is gone: its parent }
    Parts := TStringList.Create;
    Tree.BeginUpdate;
    try
      All := AppSettings.Data.LibraryExpanded;
      while All <> '' do
      begin
        I := Pos(PATH_LIST_SEP, All);
        if I = 0 then I := Length(All) + 1;
        if I > 1 then Parts.Add(TextToPath(Copy(All, 1, I - 1)));
        Delete(All, 1, I - 1 + Length(PATH_LIST_SEP));
      end;
      for I := 0 to Parts.Count - 1 do
      begin
        KeepWindowAlive;
        N := Tree.FindPath(Parts[I], True);
        if N <> nil then N.Expanded := True;
      end;
    finally
      Tree.EndUpdate;
      Parts.Free;
    end;
    Sel := TextToPath(AppSettings.Data.LibrarySelection);
    N := Tree.FindPath(Sel, True);
    while (N = nil) and (Pos(#1, Sel) > 0) do
    begin
      Sel := Copy(Sel, 1, RPos(#1, Sel) - 1);
      N := Tree.FindPath(Sel, True);
    end;
    if N <> nil then Tree.SelectNode(N);
    FWantTopRow := AppSettings.Data.LibraryTopRow;
    FWantTileScroll := AppSettings.Data.LibraryTilesScroll;
    Application.QueueAsyncCall(@ScrollLater, 0);
  end;
  Tiles.Grid.TileSize := AppSettings.Data.LibraryTileSize;
  Tiles.Sort := TTileSort(EnsureRange(AppSettings.Data.LibraryTileSort, Ord(Low(TTileSort)), Ord(High(TTileSort))));
  Tiles.Reverse := AppSettings.Data.LibraryTileSortRev;
  if AppSettings.Data.LibraryTiles then
  begin
    SetTileMode(True, False);
    { SetTileMode starts at the selected node: all albums, if it was so }
    if ARestoreView and AppSettings.Data.LibraryTilesAll then
    begin
      FTileAll := True;
      RebuildTiles;
    end;
  end;
end;

{ ---- node data ---- }

function TLibraryPane.NodeType(N: TAuTreeNode): TLibNodeType;
begin
  Result := TLibNodeType(EnsureRange(N.Kind, Ord(Low(TLibNodeType)), Ord(High(TLibNodeType))));
end;

function TLibraryPane.Category(N: TAuTreeNode): TLibCategory;
begin
  if (N = nil) or (NodeType(N) <> lntCategory) then Exit(lcNone);
  Result := TLibCategory(EnsureRange(N.Tag, Ord(Low(TLibCategory)), Ord(High(TLibCategory))));
end;

function TLibraryPane.GetFlags(N: TAuTreeNode): PtrInt;
begin
  Result := PtrInt(N.Data);
end;

function TLibraryPane.IsVirtualLink(N: TAuTreeNode): Boolean;
begin
  Result := (N <> nil) and ((GetFlags(N) and LNF_VIRTUAL) <> 0);
end;

function TLibraryPane.IsOffline(N: TAuTreeNode): Boolean;
begin
  Result := (N <> nil) and ((GetFlags(N) and LNF_OFFLINE) <> 0);
end;

function TLibraryPane.IsInsideVirtualLink(N: TAuTreeNode): Boolean;
begin
  Result := False;
  if N = nil then Exit;
  N := N.Parent;
  while N <> nil do
  begin
    if IsVirtualLink(N) then Exit(True);
    N := N.Parent;
  end;
end;

function TLibraryPane.AddNode(AParent: TAuTreeNode; AType: TLibNodeType; const ACaption, AText,
  APath: string; AIcon: TAuIcon; AHasChildren: Boolean): TAuTreeNode;
begin
  Result := AParent.AddChild(ACaption, AIcon);
  Result.Kind := Ord(AType);
  Result.Text := AText;
  Result.Path := APath;
  Result.HasChildren := AHasChildren;
  Result.ChildrenLoaded := not AHasChildren;
end;

function TLibraryPane.AddCategory(const ACaption: string; ACat: TLibCategory; AIcon: TAuIcon): TAuTreeNode;
begin
  Result := Tree.AddRoot(ACaption, AIcon);
  Result.Kind := Ord(lntCategory);
  Result.Tag := Ord(ACat);
  Result.Text := ACaption;
  Result.Accent := True;
  Result.HasChildren := True;
end;

{ ---- building ---- }

procedure TLibraryPane.Populate;
begin
  FSearchActive := False;
  FHasOfflineFolders := False;
  Tree.EmptyText := LIB_EMPTY_TEXT;
  Tree.BeginUpdate;
  try
    Tree.Clear;
    if (FLib = nil) or ((FLib.GetTrackCount = 0) and not FLib.HasScanFolders) then
      Exit;                                   // the empty text explains what to do
    AddCategory(NODE_FOLDERS, lcFolders, icFolder);
    if AppSettings.Data.ShowLibArtist then AddCategory(NODE_ARTISTS, lcArtists, icArtist);
    if AppSettings.Data.ShowLibAlbum then AddCategory(NODE_ALBUMS, lcAlbums, icAlbum);
    if AppSettings.Data.ShowLibGenre then AddCategory(NODE_GENRES, lcGenres, icGenre);
  finally
    Tree.EndUpdate;
  end;
  if Tree.RootCount > 0 then Tree.SelectNode(Tree.Roots(0));
end;

procedure TLibraryPane.FillTracks(ANode: TAuTreeNode; AList: TTrackList; AWithNumbers: Boolean);
var
  I: Integer;
  T: PTrackInfo;
  Cap: string;
begin
  for I := 0 to AList.Count - 1 do
  begin
    T := AList[I];
    if not AWithNumbers then Cap := ExtractFileName(T^.FilePath)
    else if T^.TrackNumber > 0 then Cap := CleanNodeText(Format('%.2d. %s', [T^.TrackNumber, T^.Title]))
    else Cap := CleanNodeText(T^.Title);
    AddNode(ANode, lntTrack, Cap, T^.Title, T^.FilePath, icNote, False);
  end;
end;

{ a library root: the "(not available)" mark follows the drive (no disk access) }
procedure TLibraryPane.UpdateRootAvailability(ANode: TAuTreeNode);
var
  NowOffline: Boolean;
  Flags: PtrInt;
begin
  if (FLib = nil) or (ANode = nil) or (ANode.Parent = nil) or
     (NodeType(ANode) <> lntFolder) or (Category(ANode.Parent) <> lcFolders) then Exit;
  NowOffline := not FLib.IsRootAvailable(ANode.Path);
  if NowOffline = IsOffline(ANode) then Exit;
  Flags := GetFlags(ANode);
  if NowOffline then
  begin
    ANode.Caption := ANode.Caption + LBL_NOT_AVAILABLE;
    Flags := Flags or LNF_OFFLINE;
    FHasOfflineFolders := True;
  end
  else
  begin
    if EndsStr(LBL_NOT_AVAILABLE, ANode.Caption) then
      ANode.Caption := Copy(ANode.Caption, 1, Length(ANode.Caption) - Length(LBL_NOT_AVAILABLE));
    Flags := Flags and not LNF_OFFLINE;
  end;
  ANode.Data := Pointer(Flags);
  ANode.Dim := NowOffline;
  Tree.Changed;
end;

procedure TLibraryPane.FillFolder(ANode: TAuTreeNode);
var
  SL, LinkPaths: TStringList;
  TL: TTrackList;
  I: Integer;
  C: TAuTreeNode;
  Sub: string;
begin
  SL := TStringList.Create;
  TL := TTrackList.Create;
  try
    UpdateRootAvailability(ANode);
    if IsAulLinkFile(ANode.Path) then
    begin
      { the targets of a virtual folder (from the library, only those with music) }
      LinkPaths := TStringList.Create;
      try
        FLib.GetVirtualLinkTargets(ANode.Path, LinkPaths, True);
        for I := 0 to LinkPaths.Count - 1 do
          AddNode(ANode, lntFolder, ExtractFileName(ExcludeTrailingPathDelimiter(LinkPaths[I])), '',
            LinkPaths[I], icFolder, True);
      finally
        LinkPaths.Free;
      end;
    end
    else
    begin
      { the sub folders and virtual folders with music, from the library }
      FLib.GetSubFolders(ANode.Path, SL);
      SL.Sort;
      for I := 0 to SL.Count - 1 do
      begin
        Sub := SL[I];
        if IsAulLinkFile(Sub) then
        begin
          C := AddNode(ANode, lntFolder, ChangeFileExt(Sub, ''), '',
            IncludeTrailingPathDelimiter(ANode.Path) + Sub, icLink, True);
          C.Data := Pointer(PtrInt(LNF_VIRTUAL));
        end
        else
          AddNode(ANode, lntFolder, Sub, '', IncludeTrailingPathDelimiter(ANode.Path) + Sub, icFolder, True);
      end;
      FLib.GetTracksInFolder(ExcludeTrailingPathDelimiter(ANode.Path), TL);
    end;
    TL.Sort(@SortTracks_ByFolder);
    FillTracks(ANode, TL, False);
  finally
    TL.Free;
    SL.Free;
  end;
end;

procedure TLibraryPane.TreeExpanding(Sender: TObject; Node: TAuTreeNode);
var
  SL: TStringList;
  TL: TTrackList;
  I: Integer;
  C: TAuTreeNode;
  OldCursor: TCursor;
begin
  if (FLib = nil) or Node.ChildrenLoaded then Exit;
  SL := TStringList.Create;
  TL := TTrackList.Create;
  Tree.BeginUpdate;
  { (the hourglass right before the try whose finally takes it away) }
  OldCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    case NodeType(Node) of
      lntCategory:
        case Category(Node) of
          lcArtists:
            begin
              FLib.GetUniqueArtists(SL);
              for I := 0 to SL.Count - 1 do
                AddNode(Node, lntArtist, CleanNodeText(SL[I]), SL[I], '', icArtist, True);
            end;
          lcAlbums:
            begin
              FLib.GetUniqueAlbums(SL);
              for I := 0 to SL.Count - 1 do
                AddNode(Node, lntAlbum, CleanNodeText(SL[I]), SL[I], '', icAlbum, True);
            end;
          lcGenres:
            begin
              FLib.GetUniqueGenres(SL);
              for I := 0 to SL.Count - 1 do
                AddNode(Node, lntGenre, CleanNodeText(SL[I]), SL[I], '', icGenre, True);
            end;
          lcFolders:
            begin
              FLib.GetScanFolders(SL);
              for I := 0 to SL.Count - 1 do
              begin
                C := AddNode(Node, lntFolder, ExtractFileName(ExcludeTrailingPathDelimiter(SL[I])), '',
                  ExcludeTrailingPathDelimiter(SL[I]), icFolder, True);
                if C.Caption = '' then C.Caption := SL[I];
                if not FLib.IsRootAvailable(C.Path) then
                begin
                  C.Caption := C.Caption + LBL_NOT_AVAILABLE;
                  C.Data := Pointer(PtrInt(LNF_OFFLINE));
                  C.Dim := True;
                  FHasOfflineFolders := True;
                end;
              end;
            end;
        end;
      lntArtist:
        begin
          FLib.GetAlbumsByArtist(Node.Text, SL);
          for I := 0 to SL.Count - 1 do
          begin
            C := AddNode(Node, lntArtistAlbum, CleanNodeText(SL[I]), SL[I], '', icAlbum, True);
            C.Filter := Node.Text;
          end;
        end;
      lntGenre:
        begin
          FLib.GetAlbumsByGenre(Node.Text, SL);
          for I := 0 to SL.Count - 1 do
          begin
            C := AddNode(Node, lntGenreAlbum, CleanNodeText(SL[I]), SL[I], '', icAlbum, True);
            C.Filter := Node.Text;
          end;
        end;
      lntAlbum:
        begin
          FLib.GetTracksByAlbum(Node.Text, TL);
          TL.Sort(@SortTracks_ByAlbum);
          FillTracks(Node, TL, True);
        end;
      lntArtistAlbum:
        begin
          FLib.GetTracksByArtistAndAlbum(Node.Filter, Node.Text, TL);
          TL.Sort(@SortTracks_ByAlbum);
          FillTracks(Node, TL, True);
        end;
      lntGenreAlbum:
        begin
          FLib.GetTracksByGenreAndAlbum(Node.Filter, Node.Text, TL);
          TL.Sort(@SortTracks_ByAlbum);
          FillTracks(Node, TL, True);
        end;
      lntFolder:
        FillFolder(Node);
    else
      ;
    end;
    Node.ChildrenLoaded := True;
    if Node.Count = 0 then Node.HasChildren := False;
  finally
    Tree.EndUpdate;
    TL.Free;
    SL.Free;
    Screen.Cursor := OldCursor;
  end;
end;

{ ---- refresh ---- }

procedure TLibraryPane.CollectExpanded(N: TAuTreeNode; AList: TStrings);
var
  I: Integer;
begin
  if N.Expanded then
  begin
    AList.Add(Tree.NodePath(N));
    for I := 0 to N.Count - 1 do CollectExpanded(N[I], AList);
  end;
end;

procedure TLibraryPane.RefreshLibrary;
var
  Expanded: TStringList;
  SelPath: string;
  I: Integer;
  N: TAuTreeNode;
begin
  if Search.Text <> '' then
  begin
    FSearchTimer.Enabled := False;
    Search.Text := '';
  end;
  Expanded := TStringList.Create;
  try
    for I := 0 to Tree.RootCount - 1 do CollectExpanded(Tree.Roots(I), Expanded);
    SelPath := '';
    if Tree.FocusedNode <> nil then SelPath := Tree.NodePath(Tree.FocusedNode);
    Tree.BeginUpdate;
    try
      Populate;
      { parents come before their children in the list }
      for I := 0 to Expanded.Count - 1 do
      begin
        N := Tree.FindPath(Expanded[I], True);
        if N <> nil then N.Expanded := True;
      end;
    finally
      Tree.EndUpdate;
    end;
    if SelPath <> '' then
    begin
      N := Tree.FindPath(SelPath, True);
      { gone (deleted / renamed): its parent }
      while (N = nil) and (Pos(#1, SelPath) > 0) do
      begin
        SelPath := Copy(SelPath, 1, RPos(#1, SelPath) - 1);
        N := Tree.FindPath(SelPath, True);
      end;
      if N <> nil then
      begin
        Tree.SelectNode(N);
        Tree.MakeVisible(N);
      end;
    end;
  finally
    Expanded.Free;
  end;
  if FTileMode then
  begin
    Tiles.ClearThumbCache;        // a scan may have made covers
    RebuildTiles(True);
  end;
end;

procedure TLibraryPane.RefreshCurrentFolder;
var
  N: TAuTreeNode;
begin
  N := Tree.FocusedNode;
  if (N <> nil) and (NodeType(N) = lntFolder) and not FSearchActive then
  begin
    Tree.BeginUpdate;
    try
      N.Expanded := False;
      N.DeleteChildren;
      N.ChildrenLoaded := False;
      N.HasChildren := True;
      N.Expanded := True;
    finally
      Tree.EndUpdate;
    end;
    Exit;
  end;
  RefreshLibrary;
end;

{ ---- search ---- }

procedure TLibraryPane.SearchChange(Sender: TObject);
begin
  FSearchTimer.Enabled := False;
  FSearchTimer.Enabled := True;
end;

procedure TLibraryPane.SearchTimer(Sender: TObject);
begin
  FSearchTimer.Enabled := False;
  PerformSearch;
end;

procedure TLibraryPane.ClearSearch;
begin
  if Search.Text = '' then Exit;
  FSearchTimer.Enabled := False;
  Search.Text := '';
  FSearchTimer.Enabled := False;
  if FSearchActive then Populate;
  if FTileMode then RebuildTiles;
end;

procedure TLibraryPane.PerformSearch;
var
  Q: string;
  MArt, MAlb, MGen, MFld: TStringList;
  MTrk: TTrackList;
  I: Integer;
  Cat: TAuTreeNode;
  T: PTrackInfo;
  Cap: string;
  OldCursor: TCursor;
begin
  if FLib = nil then Exit;
  { with the tiles shown the search fills them; the tree follows when it
    comes back (SetTileMode) }
  if FTileMode then
  begin
    if SearchQuery <> FTileQuery then RebuildTiles;
    Exit;
  end;
  Q := Trim(Search.Text);
  if Length(Q) < 2 then
  begin
    if FSearchActive then Populate;
    Exit;
  end;
  FSearchActive := True;
  MArt := TStringList.Create;
  MAlb := TStringList.Create;
  MGen := TStringList.Create;
  MFld := TStringList.Create;
  MTrk := TTrackList.Create;
  OldCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    FLib.SearchLibrary(Q, MArt, MAlb, MGen, MFld, MTrk);
    Tree.BeginUpdate;
    try
      Tree.Clear;
      if MFld.Count > 0 then
      begin
        Cat := AddCategory(NODE_FOLDERS, lcFolders, icFolder);
        Cat.ChildrenLoaded := True;
        for I := 0 to MFld.Count - 1 do
          AddNode(Cat, lntFolder, ExtractFileName(ExcludeTrailingPathDelimiter(MFld[I])), '',
            ExcludeTrailingPathDelimiter(MFld[I]), icFolder, True);
        Cat.Expanded := True;
      end;
      if MArt.Count > 0 then
      begin
        Cat := AddCategory(NODE_ARTISTS, lcArtists, icArtist);
        Cat.ChildrenLoaded := True;
        for I := 0 to MArt.Count - 1 do
          AddNode(Cat, lntArtist, CleanNodeText(MArt[I]), MArt[I], '', icArtist, True);
        Cat.Expanded := True;
      end;
      if MAlb.Count > 0 then
      begin
        Cat := AddCategory(NODE_ALBUMS, lcAlbums, icAlbum);
        Cat.ChildrenLoaded := True;
        for I := 0 to MAlb.Count - 1 do
          AddNode(Cat, lntAlbum, CleanNodeText(MAlb[I]), MAlb[I], '', icAlbum, True);
        Cat.Expanded := True;
      end;
      if MGen.Count > 0 then
      begin
        Cat := AddCategory(NODE_GENRES, lcGenres, icGenre);
        Cat.ChildrenLoaded := True;
        for I := 0 to MGen.Count - 1 do
          AddNode(Cat, lntGenre, CleanNodeText(MGen[I]), MGen[I], '', icGenre, True);
        Cat.Expanded := True;
      end;
      MTrk.Sort(@SortTracks_ByArtist);
      if MTrk.Count > 0 then
      begin
        Cat := AddCategory(NODE_TRACKS, lcTracks, icNote);
        Cat.ChildrenLoaded := True;
        for I := 0 to MTrk.Count - 1 do
        begin
          T := MTrk[I];
          if Trim(T^.Artist) <> '' then Cap := CleanNodeText(T^.Artist + ' - ' + T^.Title)
          else Cap := CleanNodeText(T^.Title);
          AddNode(Cat, lntTrack, Cap, T^.Title, T^.FilePath, icNote, False);
        end;
        Cat.Expanded := True;
      end;
    finally
      Tree.EndUpdate;
    end;
    if Tree.RootCount = 0 then
      Tree.EmptyText := 'Nothing found for "' + Q + '".'
    else
      Tree.EmptyText := '';
  finally
    MArt.Free;
    MAlb.Free;
    MGen.Free;
    MFld.Free;
    MTrk.Free;
    Screen.Cursor := OldCursor;
  end;
end;

{ ---- actions ---- }

function TLibraryPane.ActionNodes: TAuTreeNodeArray;
begin
  if FTileMode then Exit(TileActionNodes);
  Result := Tree.SelectedNodes;
  if (Length(Result) = 0) and (Tree.FocusedNode <> nil) then
  begin
    SetLength(Result, 1);
    Result[0] := Tree.FocusedNode;
  end;
end;

procedure TLibraryPane.CollectTracks(const ANodes: TAuTreeNodeArray; AList: TTrackList);
var
  I, J: Integer;
  N: TAuTreeNode;
  Part, Sub: TTrackList;
  Links: TStringList;
  T: TTrackInfo;
begin
  if FLib = nil then Exit;
  Part := TTrackList.Create;
  Sub := TTrackList.Create;
  Links := TStringList.Create;
  try
    for I := 0 to High(ANodes) do
    begin
      KeepWindowAlive;
      N := ANodes[I];
      Part.Clear;
      case NodeType(N) of
        lntArtist: FLib.GetTracksByArtist(N.Text, Part);
        lntAlbum: FLib.GetTracksByAlbum(N.Text, Part);
        lntArtistAlbum: FLib.GetTracksByArtistAndAlbum(N.Filter, N.Text, Part);
        lntGenre: FLib.GetTracksByGenre(N.Text, Part);
        lntGenreAlbum: FLib.GetTracksByGenreAndAlbum(N.Filter, N.Text, Part);
        lntFolder:
          if IsVirtualLink(N) or IsAulLinkFile(N.Path) then
          begin
            Links.Clear;
            FLib.GetVirtualLinkTargets(N.Path, Links);
            for J := 0 to Links.Count - 1 do
            begin
              KeepWindowAlive;
              Sub.Clear;
              FLib.GetTracksInFolderRecursive(ExcludeTrailingPathDelimiter(Links[J]), Sub);
              Part.AddList(Sub);
            end;
          end
          else
            FLib.GetTracksInFolderRecursive(ExcludeTrailingPathDelimiter(N.Path), Part);
        lntTrack:
          if FLib.TryGetTrack(N.Path, T) then Part.Add(T);
      else
        ;   // a category: never the whole library at once
      end;
      if NodeType(N) in [lntArtist, lntGenre] then Part.Sort(@SortTracks_ByArtist)
      else if NodeType(N) in [lntAlbum, lntArtistAlbum, lntGenreAlbum] then Part.Sort(@SortTracks_ByAlbum);
      AList.AddList(Part);
    end;
  finally
    Links.Free;
    Sub.Free;
    Part.Free;
  end;
end;

procedure TLibraryPane.ExpandAll(N: TAuTreeNode);
var
  I: Integer;
begin
  if (N = nil) or (NodeType(N) = lntTrack) then Exit;
  { a whole branch of a large library takes a while: the window stays alive }
  KeepWindowAlive;
  N.Expanded := True;
  for I := 0 to N.Count - 1 do ExpandAll(N[I]);
end;

procedure TLibraryPane.FillDemo;
var
  Cat, N, M: TAuTreeNode;

  procedure Leafs(P: TAuTreeNode; AType: TLibNodeType; AIcon: TAuIcon; const Names: array of string);
  var
    I: Integer;
  begin
    for I := 0 to High(Names) do AddNode(P, AType, Names[I], Names[I], '', AIcon, False);
  end;

begin
  SetTileMode(False, False);
  FLib := nil;
  Tree.BeginUpdate;
  try
    Tree.Clear;
    Cat := AddCategory(NODE_FOLDERS, lcFolders, icFolder);
    Cat.ChildrenLoaded := True;
    N := AddNode(Cat, lntFolder, 'Music', '', 'D:\Music', icFolder, True);
    Leafs(N, lntFolder, icFolder, ['Ambient - Electronic', 'Classical', 'Jazz', 'Rock - Pop', 'Soundtracks', 'Various']);
    M := AddNode(N, lntFolder, 'Royal Concertgebouw Orchestra', '', 'D:\Music\RCO.aullink', icLink, True);
    M.Data := Pointer(PtrInt(LNF_VIRTUAL));
    Leafs(M, lntFolder, icFolder, ['Mahler - Symphony No. 2', 'Bruckner - Symphony No. 7']);
    N.Expanded := True;
    N := AddNode(Cat, lntFolder, 'Limbo', '', 'E:\Limbo', icFolder, True);
    Leafs(N, lntFolder, icFolder, ['To sort']);
    N := AddNode(Cat, lntFolder, 'NAS Archive' + LBL_NOT_AVAILABLE, '', '\\nas\archive', icFolder, False);
    N.Dim := True;
    Cat.Expanded := True;
    Cat := AddCategory(NODE_ARTISTS, lcArtists, icArtist);
    Leafs(Cat, lntArtist, icArtist, ['Andy Lu', 'Juniper Avenue', 'Northern Lights Quartet']);
    Cat := AddCategory(NODE_ALBUMS, lcAlbums, icAlbum);
    Leafs(Cat, lntAlbum, icAlbum, ['Distant Shores', 'Silence, Noise and Calm', 'Silent Skies']);
    Cat := AddCategory(NODE_GENRES, lcGenres, icGenre);
    Leafs(Cat, lntGenre, icGenre, ['Ambient', 'Classical', 'Electronic', 'Jazz']);
  finally
    Tree.EndUpdate;
  end;
end;

{ ---- tiles ---- }

procedure TLibraryPane.TreeBtnClick(Sender: TObject);
begin
  SetTileMode(False, True);
  FocusList;
end;

procedure TLibraryPane.TilesBtnClick(Sender: TObject);
begin
  if BtnTree.Visible then SetTileMode(True, True)
  else SetTileMode(not FTileMode, True);
  FocusList;
end;

procedure TLibraryPane.TileSizeWheel(Sender: TObject; Index: Integer);
begin
  Tiles.Grid.TileSize := Tiles.Grid.TileSize + Index;
  AppSettings.Data.LibraryTileSize := Tiles.Grid.TileSize;
end;

procedure TLibraryPane.TileSortChange(Sender: TObject);
begin
  AppSettings.Data.LibraryTileSort := Ord(Tiles.Sort);
  AppSettings.Data.LibraryTileSortRev := Tiles.Reverse;
  TopResize(nil);                 // the order's name may have another width
end;

procedure TLibraryPane.TileClearScope(Sender: TObject);
begin
  FTileAll := True;
  RebuildTiles;
end;

{ a part of the path above the tiles: the tiles go up to that node of the
  tree (its first part is a category: all albums) }
procedure TLibraryPane.TileCrumbClick(Sender: TObject; Index: Integer);
var
  N: TAuTreeNode;
begin
  N := Tree.FocusedNode;
  if (N <> nil) and (NodeType(N) = lntTrack) then N := N.Parent;
  while (N <> nil) and (N.Level > Index) do N := N.Parent;
  if (N = nil) or (N.Level <> Index) then Exit;
  Tree.SelectNode(N);
  FTileAll := False;
  RebuildTiles;
  FocusList;
end;

{ no disk access: only whether the drive / share of the folder is there }
function TLibraryPane.TileOffline(const AFolder: string): Boolean;
begin
  Result := (FLib <> nil) and not FLib.IsRootAvailable(AFolder);
end;

procedure TLibraryPane.TextSizeChanged;
begin
  Tiles.Grid.TextSize := Tree.TextSize;
  Tiles.Grid.Changed;             // the font scale or the DPI may have changed too
end;

function TLibraryPane.ListFocused: Boolean;
begin
  Result := Tree.Focused or Tiles.Grid.Focused;
end;

procedure TLibraryPane.FocusList;
begin
  if FTileMode then
  begin
    if Tiles.Grid.CanFocus then Tiles.Grid.SetFocus;
  end
  else if Tree.CanFocus then Tree.SetFocus;
end;

{ what the search box asks for ('' below two characters) }
function TLibraryPane.SearchQuery: string;
begin
  Result := Trim(Search.Text);
  if Length(Result) < 2 then Result := '';
end;

procedure TLibraryPane.FreeTileNodes;
var
  I: Integer;
begin
  if FTileNodes = nil then Exit;
  for I := 0 to FTileNodes.Count - 1 do TAuTreeNode(FTileNodes[I]).Free;
  FTileNodes.Clear;
end;

{ a track node for every track of the selected tiles (the focused tile when
  none is selected), in the order of the tiles and of each album. The nodes
  are in no tree; they live until the next call. }
function TLibraryPane.TileActionNodes: TAuTreeNodeArray;
var
  Sel: TAuTileIntArray;
  I, J, N: Integer;
  T: PLibTile;
  Node: TAuTreeNode;
begin
  Result := nil;
  FreeTileNodes;
  Sel := Tiles.Grid.SelectedIndexes;
  if (Length(Sel) = 0) and (Tiles.Grid.FocusIndex >= 0) then
  begin
    SetLength(Sel, 1);
    Sel[0] := Tiles.Grid.FocusIndex;
  end;
  N := 0;
  for I := 0 to High(Sel) do
  begin
    T := Tiles.Tile(Sel[I]);
    if T = nil then Continue;
    SetLength(Result, N + T^.PathCount);
    for J := 0 to T^.PathCount - 1 do
    begin
      Node := TAuTreeNode.Create(nil, nil);
      Node.Kind := Ord(lntTrack);
      Node.Path := T^.Paths[J];
      FTileNodes.Add(Node);
      Result[N] := Node;
      Inc(N);
    end;
  end;
end;

function TLibraryPane.TopTabOrder: string;
var
  I, T: Integer;
  C: TControl;
  W: TWinControl;
  What: string;
begin
  Result := '';
  for T := 0 to FTop.ControlCount - 1 do
    for I := 0 to FTop.ControlCount - 1 do
    begin
      C := FTop.Controls[I];
      if not (C is TWinControl) then Continue;
      W := TWinControl(C);
      if (W.TabOrder <> T) or not W.Visible or not W.TabStop then Continue;
      if W = Search then What := 'search'
      else if W = BtnTree then What := 'tree'
      else if W = BtnTiles then What := 'tiles'
      else if W = BtnRescan then What := 'rescan'
      else if W = Tiles.BtnDir then What := 'arrow'
      else if W = Tiles.BtnSort then What := 'order'
      else What := '?';
      Result := Result + Format('%s@%d ', [What, W.Left]);
    end;
  Result := Trim(Result);
end;

function TLibraryPane.TileFolder(Index: Integer): string;
var
  T: PLibTile;
begin
  T := Tiles.Tile(Index);
  if T = nil then Result := '' else Result := T^.FolderDir;
end;

procedure TLibraryPane.SetTileMode(AOn, ASave: Boolean);
begin
  if AOn = FTileMode then Exit;
  FTileMode := AOn;
  FTileAll := False;
  BtnTree.Active := not AOn;
  BtnTiles.Active := AOn;
  if ASave then AppSettings.Data.LibraryTiles := AOn;
  if AOn then
  begin
    Tiles.Grid.TextSize := Tree.TextSize;
    Tiles.Visible := True;
    Tree.Visible := False;
    RebuildTiles;
  end
  else
  begin
    FreeTileNodes;
    Tree.Visible := True;
    Tiles.Visible := False;
    Tiles.SetTracks(nil, nil, '', '', '', False);
    FTileQuery := '';
    { the tree catches up with a search typed while the tiles were shown }
    if (SearchQuery <> '') or FSearchActive then PerformSearch;
  end;
  TopResize(nil);
  if Assigned(FOnTileModeChange) then FOnTileModeChange(Self);
end;

procedure TLibraryPane.RebuildTiles(AKeep: Boolean);
var
  Q, Crumb, Key, EmptyText: string;
  L, Part, MTrk: TTrackList;
  Found, Whole, Done, MArt, MAlb, MGen, MFld: TStringList;
  N: TAuTreeNode;
  A: TAuTreeNodeArray;
  T, P: PTrackInfo;
  I, J, At: Integer;
  CanClear, NoAlbum: Boolean;
  OldCursor: TCursor;
  StartTick: QWord;

  function PathSet: TStringList;
  begin
    Result := TStringList.Create;
    Result.UseLocale := False;
    Result.CaseSensitive := True;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
  end;

begin
  if not FTileMode then Exit;
  Q := SearchQuery;
  FTileQuery := Q;
  if FLib = nil then
  begin
    Tiles.SetTracks(nil, nil, '', '', '', False);
    Exit;
  end;
  StartTick := GetTickCount64;
  L := TTrackList.Create;
  Part := TTrackList.Create;
  MTrk := TTrackList.Create;
  Found := PathSet;
  Whole := PathSet;
  Done := PathSet;
  MArt := TStringList.Create;
  MAlb := TStringList.Create;
  MGen := TStringList.Create;
  MFld := TStringList.Create;
  OldCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    if Q <> '' then
    begin
      FLib.SearchLibrary(Q, MArt, MAlb, MGen, MFld, MTrk);
      { what was found as an artist, album, genre or folder: all its albums }
      for I := 0 to MArt.Count - 1 do
      begin
        KeepWindowAlive;
        Part.Clear;
        FLib.GetTracksByArtist(MArt[I], Part);
        L.AddList(Part);
      end;
      for I := 0 to MAlb.Count - 1 do
      begin
        KeepWindowAlive;
        Part.Clear;
        FLib.GetTracksByAlbum(MAlb[I], Part);
        L.AddList(Part);
      end;
      for I := 0 to MGen.Count - 1 do
      begin
        KeepWindowAlive;
        Part.Clear;
        FLib.GetTracksByGenre(MGen[I], Part);
        L.AddList(Part);
      end;
      for I := 0 to MFld.Count - 1 do
      begin
        KeepWindowAlive;
        Part.Clear;
        FLib.GetTracksInFolderRecursive(ExcludeTrailingPathDelimiter(MFld[I]), Part);
        L.AddList(Part);
      end;
      for I := 0 to L.Count - 1 do Whole.Add(L[I]^.FilePath);
      { a track that was found: its whole album, marked with how many of its
        tracks were found }
      for I := 0 to MTrk.Count - 1 do
      begin
        T := MTrk[I];
        Found.Add(T^.FilePath);
        if Whole.Find(T^.FilePath, At) then Continue;
        NoAlbum := (Trim(T^.Album) = '') or SameText(Trim(T^.Album), LBL_UNKNOWN_ALBUM);
        if NoAlbum or (Trim(T^.AlbumArtist) = '') then
          Key := #1 + T^.FolderDir + #1 + T^.Album
        else
          Key := T^.AlbumArtist + #1 + T^.Album;
        if Done.Find(Key, At) then Continue;
        Done.Add(Key);
        KeepWindowAlive;
        Part.Clear;
        if NoAlbum then
          FLib.GetTracksInFolder(ExcludeTrailingPathDelimiter(T^.FolderDir), Part)
        else
          FLib.GetTracksByAlbum(T^.Album, Part);
        for J := 0 to Part.Count - 1 do
        begin
          P := Part[J];
          if P^.Album <> T^.Album then Continue;
          if P^.AlbumArtist <> T^.AlbumArtist then Continue;
          if (NoAlbum or (Trim(T^.AlbumArtist) = '')) and (P^.FolderDir <> T^.FolderDir) then Continue;
          L.Add(P^);
        end;
      end;
      Tiles.SetTracks(L, Found, Q, 'Search: ' + Q, 'Nothing found for "' + Q + '".', False, AKeep);
    end
    else
    begin
      { the tree may still show what an earlier search found }
      if FSearchActive then Populate;
      N := Tree.FocusedNode;
      if (N <> nil) and (NodeType(N) = lntTrack) then N := N.Parent;
      if FTileAll or (N = nil) or (NodeType(N) = lntCategory) then
      begin
        FLib.GetAllTracks(L);
        Crumb := LBL_ALL_ALBUMS;
        CanClear := False;
      end
      else
      begin
        SetLength(A, 1);
        A[0] := N;
        CollectTracks(A, L);
        Crumb := Tree.NodePath(N);
        CanClear := True;
      end;
      if FLib.GetTrackCount = 0 then EmptyText := LIB_EMPTY_TEXT
      else EmptyText := 'No albums here.';
      Tiles.SetTracks(L, nil, '', Crumb, EmptyText, CanClear, AKeep);
    end;
    AddLog(SafeFormat('[Library] Tiles: %d albums of %d tracks.', [Tiles.TileCount, L.Count]), StartTick);
  finally
    MFld.Free;
    MGen.Free;
    MAlb.Free;
    MArt.Free;
    Done.Free;
    Whole.Free;
    Found.Free;
    MTrk.Free;
    Part.Free;
    L.Free;
    Screen.Cursor := OldCursor;
  end;
end;

procedure TLibraryPane.ShowTileInTree(Index: Integer);
var
  Dir: string;
  I: Integer;
  N, C, Hit: TAuTreeNode;
  Searching: Boolean;
begin
  Dir := ExcludeTrailingPathDelimiter(TileFolder(Index));
  if Dir = '' then Exit;
  Searching := SearchQuery <> '';
  SetTileMode(False, True);
  if Searching then Exit;
  N := nil;
  for I := 0 to Tree.RootCount - 1 do
    if Category(Tree.Roots(I)) = lcFolders then N := Tree.Roots(I);
  if N = nil then Exit;
  { down the folders, opening one after the other }
  Tree.BeginUpdate;
  try
    while N <> nil do
    begin
      Tree.Expand(N);
      Hit := nil;
      for I := 0 to N.Count - 1 do
      begin
        C := N[I];
        if (NodeType(C) <> lntFolder) or IsVirtualLink(C) or (C.Path = '') then Continue;
        if SameText(C.Path, Dir) or
           AnsiStartsText(IncludeTrailingPathDelimiter(C.Path), IncludeTrailingPathDelimiter(Dir)) then
        begin
          Hit := C;
          Break;
        end;
      end;
      if Hit = nil then Break;
      N := Hit;
      if SameText(N.Path, Dir) then Break;
    end;
  finally
    Tree.EndUpdate;
  end;
  if NodeType(N) <> lntFolder then Exit;
  Tree.SelectNode(N);
  Tree.Expand(N);
  Tree.MakeVisible(N);
  FocusList;
end;

procedure TLibraryPane.ShowScanning(AScanning: Boolean);
begin
  BtnRescan.Enabled := not AScanning;
  if AScanning then BtnRescan.Hint := 'The library is being scanned...'
  else BtnRescan.Hint := 'Rescan the library folders (Ctrl+F5)';
end;

end.
