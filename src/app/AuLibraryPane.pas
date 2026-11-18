unit AuLibraryPane;

{ ==============================================================================
  AulumicNS - AuLibraryPane
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The library pane on the left of the main window, on the tree control
  (TAuTreeView): a search box and the rescan
  button above the library tree with the categories Folders, Artists,
  Albums and Genres (Artists / Albums / Genres as set in the preferences).

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
  AuGfx, AuTheme, AuIcons, AuControls, AuTree, uLibraryTypes, uLibraryManager;

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
    Tree: TAuTreeView;
    constructor Create(AOwner: TComponent); override;
    procedure Init(ALib: TLibraryManager);
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
    { the selected nodes (the focused one when nothing is selected) }
    function ActionNodes: TAuTreeNodeArray;
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
  LIB_EMPTY_TEXT = 'Your library is empty.' + LineEnding +
    'Add your music folders: Main menu > Library > Library folders...';

implementation

uses
  uAppConsts, uAppStrings, uAudioUtils, uSettingsManager;

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
  BtnRescan.TabOrder := 1;
  TopResize(nil);
end;

procedure TLibraryPane.TopResize(Sender: TObject);
begin
  if (Search = nil) or (BtnRescan = nil) then Exit;
  BtnRescan.SetBounds(FTop.Width - S(10) - S(36), S(9), S(36), S(34));
  Search.SetBounds(S(10), S(10), Math.Max(S(40), BtnRescan.Left - S(18)), S(32));
end;

procedure TLibraryPane.Init(ALib: TLibraryManager);
begin
  FLib := ALib;
  Populate;
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

procedure TLibraryPane.ShowScanning(AScanning: Boolean);
begin
  BtnRescan.Enabled := not AScanning;
  if AScanning then BtnRescan.Hint := 'The library is being scanned...'
  else BtnRescan.Hint := 'Rescan the library folders (Ctrl+F5)';
end;

end.
