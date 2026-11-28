{ =============================================================================
  AulumicNS tests - TestLibraryPane
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The library pane's tree with a made-up library (no file is read): the tree
  keeps its opened nodes, its selection and its scroll position when it is
  built again from the library; a search that is emptied gives back the tree
  as it was before the search; a search on screen survives a rebuild.
  =============================================================================}
unit TestLibraryPane;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, fpcunit, testregistry,
  uLibraryTypes, uLibraryManager, uSettingsManager, AuTree, AuLibraryPane, TestHelpers;

type
  TTestLibraryPane = class(TTestCase)
  private
    FDir: string;
    FForm: TForm;
    FLib: TLibraryManager;
    FPane: TLibraryPane;
    FKept: TAppSettingsData;
    procedure Fill(AArtists: Integer);
    function Artists: TAuTreeNode;
    function Node(const APath: string): TAuTreeNode;
    function Open(const APath: string): TAuTreeNode;
    function PathOfTop: string;
    function SelectedPaths: string;
    procedure Search(const AText: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ARebuildKeepsOpenNodesSelectionAndScrollPosition;
    procedure ANodeThatIsGoneLeavesTheFocusOnItsParent;
    procedure AnEmptiedSearchGivesTheTreeBack;
    procedure ASearchOnScreenSurvivesARebuild;
    procedure ATileSearchShowsTheAlbumsOfTheTracksFound;
    procedure TheNameListsAreAsAListSortsThem;
  end;

implementation

const
  SEP = #1;

procedure TTestLibraryPane.SetUp;
begin
  FKept := AppSettings.Data;
  AppSettings.Data.ShowLibArtist := True;
  AppSettings.Data.ShowLibAlbum := True;
  AppSettings.Data.ShowLibGenre := False;
  AppSettings.Data.ShowLibComposer := False;
  FDir := CreateTestDir;
  FLib := TLibraryManager.Create(FDir + 'library.adb');
  FForm := TForm.CreateNew(nil);
  FForm.SetBounds(0, 0, 400, 500);
  FPane := TLibraryPane.Create(FForm);
  FPane.Parent := FForm;
  FPane.SetBounds(0, 0, 400, 500);
end;

procedure TTestLibraryPane.TearDown;
begin
  FreeAndNil(FForm);
  FreeAndNil(FLib);
  RemoveTestDir(FDir);
  AppSettings.Data := FKept;
end;

{ AArtists artists "Artist 01" .., three albums each, two tracks per album }
procedure TTestLibraryPane.Fill(AArtists: Integer);
var
  A: TTrackInfoArray;
  T: TTrackInfo;
  I, Alb, Trk, N: Integer;
  Folders, Links: TStringList;
begin
  A := nil;
  SetLength(A, AArtists * 6);
  N := 0;
  for I := 1 to AArtists do
    for Alb := 1 to 3 do
      for Trk := 1 to 2 do
      begin
        T := Default(TTrackInfo);
        T.Artist := Format('Artist %.2d', [I]);
        T.AlbumArtist := T.Artist;
        T.Album := Format('Album %.2d-%d', [I, Alb]);
        T.Title := Format('Song %d', [Trk]);
        T.TrackNumber := Trk;
        T.FolderDir := Format('m:\%.2d\%d\', [I, Alb]);
        T.FilePath := T.FolderDir + Format('%.2d.flac', [Trk]);
        A[N] := T;
        Inc(N);
      end;
  Folders := TStringList.Create;
  Links := TStringList.Create;
  try
    Folders.Add('m:\');
    FLib.ReplaceContent(A, Folders, Links);
  finally
    Links.Free;
    Folders.Free;
  end;
end;

function TTestLibraryPane.Artists: TAuTreeNode;
begin
  Result := FPane.Tree.FindPath('Artists', True);
  AssertNotNull('the Artists group', Result);
end;

{ the node of exactly this path, nil without one (FindPath gives the last
  part it finds) }
function TTestLibraryPane.Node(const APath: string): TAuTreeNode;
begin
  Result := FPane.Tree.FindPath(APath, False);
  if (Result <> nil) and (FPane.Tree.NodePath(Result) <> APath) then Result := nil;
end;

{ the node of this path, its parents opened, itself opened too }
function TTestLibraryPane.Open(const APath: string): TAuTreeNode;
begin
  Result := FPane.Tree.FindPath(APath, True);
  AssertNotNull(StringReplace(APath, SEP, ' > ', [rfReplaceAll]), Result);
  FPane.Tree.Expand(Result);
end;

function TTestLibraryPane.PathOfTop: string;
begin
  if FPane.Tree.TopNode = nil then Result := ''
  else Result := StringReplace(FPane.Tree.NodePath(FPane.Tree.TopNode), SEP, ' > ', [rfReplaceAll]);
end;

function TTestLibraryPane.SelectedPaths: string;
var
  A: TAuTreeNodeArray;
  I: Integer;
begin
  Result := '';
  A := FPane.Tree.SelectedNodes;
  for I := 0 to High(A) do
  begin
    if I > 0 then Result := Result + ' | ';
    Result := Result + StringReplace(FPane.Tree.NodePath(A[I]), SEP, ' > ', [rfReplaceAll]);
  end;
end;

{ the text typed and the wait for the search over }
procedure TTestLibraryPane.Search(const AText: string);
begin
  FPane.Search.Text := AText;
  FPane.PerformSearch;
end;

procedure TTestLibraryPane.ARebuildKeepsOpenNodesSelectionAndScrollPosition;
var
  N: TAuTreeNode;
  Top: string;
begin
  Fill(60);
  FPane.Init(FLib);
  FPane.Tree.Expand(Artists);
  Open('Artists' + SEP + 'Artist 30');
  N := FPane.Tree.FindPath('Artists' + SEP + 'Artist 30' + SEP + 'Album 30-2', True);
  AssertNotNull('an album of the artist', N);
  FPane.Tree.SelectNode(N);
  { a second node selected, and the tree scrolled so that the selection is
    not at an edge }
  FPane.Tree.FindPath('Artists' + SEP + 'Artist 30' + SEP + 'Album 30-3', False).Selected := True;
  AssertTrue(FPane.Tree.ScrollNodeToTop(FPane.Tree.FindPath('Artists' + SEP + 'Artist 25', False)));
  Top := PathOfTop;
  AssertEquals('Artists > Artist 25', Top);

  FPane.RefreshLibrary;

  AssertTrue('the artist is open again', FPane.Tree.FindPath('Artists' + SEP + 'Artist 30', False).Expanded);
  AssertEquals('the same node in the first row', Top, PathOfTop);
  AssertEquals('both nodes selected',
    'Artists > Artist 30 > Album 30-2 | Artists > Artist 30 > Album 30-3', SelectedPaths);
  AssertEquals('the focus where it was', 'Album 30-2', FPane.Tree.FocusedNode.Caption);
end;

procedure TTestLibraryPane.ANodeThatIsGoneLeavesTheFocusOnItsParent;
var
  N: TAuTreeNode;
begin
  Fill(10);
  FPane.Init(FLib);
  FPane.Tree.Expand(Artists);
  Open('Artists' + SEP + 'Artist 10');
  N := FPane.Tree.FindPath('Artists' + SEP + 'Artist 10' + SEP + 'Album 10-1', True);
  FPane.Tree.SelectNode(N);
  { the library without that artist }
  Fill(9);
  FPane.RefreshLibrary;
  AssertNotNull(FPane.Tree.FocusedNode);
  AssertEquals('Artists', FPane.Tree.FocusedNode.Caption);
  AssertTrue('the group is still open', Artists.Expanded);
end;

procedure TTestLibraryPane.AnEmptiedSearchGivesTheTreeBack;
var
  Top: string;
begin
  Fill(60);
  FPane.Init(FLib);
  FPane.Tree.Expand(Artists);
  Open('Artists' + SEP + 'Artist 40');
  FPane.Tree.SelectNode(FPane.Tree.FindPath('Artists' + SEP + 'Artist 40' + SEP + 'Album 40-1', True));
  AssertTrue(FPane.Tree.ScrollNodeToTop(FPane.Tree.FindPath('Artists' + SEP + 'Artist 35', False)));
  Top := PathOfTop;

  { two searches in a row: the letters typed one after the other }
  Search('Artist 15');
  AssertNull('what was found is another tree', Node('Artists' + SEP + 'Artist 40'));
  Search('Artist 12');
  Search('');

  AssertNotNull(Node('Artists' + SEP + 'Artist 40'));
  AssertTrue('the artist is open again', Node('Artists' + SEP + 'Artist 40').Expanded);
  AssertEquals('the same node in the first row', Top, PathOfTop);
  AssertEquals('the selection', 'Artists > Artist 40 > Album 40-1', SelectedPaths);

  { the same through the button that empties the box }
  Search('Artist 12');
  FPane.ClearSearch;
  AssertEquals('', FPane.Search.Text);
  AssertEquals('again the same node in the first row', Top, PathOfTop);
  AssertEquals('Artists > Artist 40 > Album 40-1', SelectedPaths);
end;

procedure TTestLibraryPane.ASearchOnScreenSurvivesARebuild;
var
  N: TAuTreeNode;
begin
  Fill(60);
  FPane.Init(FLib);
  FPane.Tree.Expand(Artists);
  Open('Artists' + SEP + 'Artist 40');
  Search('Artist 15');
  N := Node('Artists' + SEP + 'Artist 15');
  AssertNotNull('found', N);
  FPane.Tree.SelectNode(N);

  FPane.RefreshLibrary;

  AssertEquals('the search is still in the box', 'Artist 15', FPane.Search.Text);
  AssertNotNull('and its results in the tree', Node('Artists' + SEP + 'Artist 15'));
  AssertNull('not the whole tree', Node('Artists' + SEP + 'Artist 40'));
  AssertEquals('the selection in the results', 'Artists > Artist 15', SelectedPaths);
  { and emptying it still leads back to the tree before the search }
  Search('');
  AssertNotNull(Node('Artists' + SEP + 'Artist 40'));
  AssertTrue(Node('Artists' + SEP + 'Artist 40').Expanded);
end;

procedure TTestLibraryPane.ATileSearchShowsTheAlbumsOfTheTracksFound;
var
  Found, Albums: TTrackList;
  A, B, C, D: TStringList;
  I, Hits: Integer;
begin
  Fill(20);
  { the library's part: the albums of the tracks found, each whole }
  Found := TTrackList.Create;
  Albums := TTrackList.Create;
  A := TStringList.Create;
  B := TStringList.Create;
  C := TStringList.Create;
  D := TStringList.Create;
  try
    { one album by its name: both of its tracks are found }
    FLib.SearchLibrary('Album 07-2', A, B, C, D, Found);
    AssertEquals(2, Found.Count);
    FLib.GetAlbumsOfTracks(Found, Albums);
    AssertEquals('that album and no other', 2, Albums.Count);
    for I := 0 to Albums.Count - 1 do AssertEquals('Album 07-2', Albums[I]^.Album);

    { tracks of each album of an artist (both of the first, one of the
      others): the three albums whole - and not the other albums of the
      genre or of the folders above }
    FLib.SearchLibrary('Artist 07 Song 1', A, B, C, D, Found);
    AssertEquals('four of the six tracks', 4, Found.Count);
    FLib.GetAlbumsOfTracks(Found, Albums);
    AssertEquals('three albums of two tracks', 6, Albums.Count);
    for I := 0 to Albums.Count - 1 do AssertEquals('Artist 07', Albums[I]^.AlbumArtist);

    { nothing found: nothing }
    Found.Clear;
    FLib.GetAlbumsOfTracks(Found, Albums);
    AssertEquals(0, Albums.Count);
  finally
    D.Free;
    C.Free;
    B.Free;
    A.Free;
    Albums.Free;
    Found.Free;
  end;

  { and the pane: a tile per album that has a track found }
  FPane.Init(FLib);
  FPane.SetTileMode(True, False);
  AssertEquals('all albums before the search', 60, FPane.Tiles.TileCount);
  Search('Artist 07 Song 1');
  AssertEquals('the three albums of that artist', 3, FPane.Tiles.TileCount);
  Hits := 0;
  for I := 0 to FPane.Tiles.TileCount - 1 do Inc(Hits, FPane.Tiles.Tile(I)^.Found);
  AssertEquals('the tiles count the tracks found', 4, Hits);
  Search('');
  AssertEquals('all albums again', 60, FPane.Tiles.TileCount);
end;

{ the names of the Artists, Albums and Genres groups: each name once (two
  spellings that a sorted list takes for the same name: the one met first),
  in the order of a sorted list that compares as Windows does - whatever way
  the library builds them }
procedure TTestLibraryPane.TheNameListsAreAsAListSortsThem;
const
  NAMES: array[0..22] of string = ('The Beatles', 'the beatles', 'Bj'#$C3#$B6'rk', 'Bjork', 'bjork', '10cc', '2Pac',
    'AC/DC', 'a-ha', 'A Perfect Circle', #$C3#$89'dith Piaf', 'Edith Piaf', 'Zappa', 'zappa; Beefheart', '  Beck ',
    'Beck', 'M'#$C3#$B6't'#$C3#$B6'rhead', 'Motorhead', 'Sigur R'#$C3#$B3's', '!!!', '...And You Will Know Us',
    #$C3#$93'lafur Arnalds', 'Olafur Arnalds');
var
  A: TTrackInfoArray;
  T: TTrackInfo;
  I, P: Integer;
  Folders, Links, Got, Want: TStringList;
  Raw, Item: string;
begin
  A := nil;
  SetLength(A, Length(NAMES) * 2);
  for I := 0 to High(A) do
  begin
    T := Default(TTrackInfo);
    T.AlbumArtist := NAMES[I mod Length(NAMES)];
    T.Artist := T.AlbumArtist;
    T.Album := 'Album of ' + NAMES[(I * 7) mod Length(NAMES)];
    T.Genre := NAMES[(I * 3) mod Length(NAMES)];
    T.Title := Format('Song %d', [I]);
    T.FolderDir := Format('m:\%.2d\', [I]);
    T.FilePath := T.FolderDir + '01.flac';
    A[I] := T;
  end;
  Folders := TStringList.Create;
  Links := TStringList.Create;
  Got := TStringList.Create;
  Want := TStringList.Create;
  try
    Folders.Add('m:\');
    FLib.ReplaceContent(A, Folders, Links);
    { the plain way: every item of every track into a sorted list }
    Want.Sorted := True;
    Want.Duplicates := dupIgnore;
    for I := 0 to High(A) do
    begin
      Raw := A[I].AlbumArtist;
      repeat
        P := Pos(';', Raw);
        if P > 0 then
        begin
          Item := Trim(Copy(Raw, 1, P - 1));
          Raw := Copy(Raw, P + 1, MaxInt);
        end
        else
          Item := Trim(Raw);
        if Item <> '' then Want.Add(Item);
      until P = 0;
    end;
    FLib.GetUniqueArtists(Got);
    AssertEquals('the artists, each once and in the list''s order', Want.CommaText, Got.CommaText);

    Want.Clear;
    for I := 0 to High(A) do
    begin
      Raw := A[I].Genre;
      repeat
        P := Pos(';', Raw);
        if P > 0 then
        begin
          Item := Trim(Copy(Raw, 1, P - 1));
          Raw := Copy(Raw, P + 1, MaxInt);
        end
        else
          Item := Trim(Raw);
        if Item <> '' then Want.Add(Item);
      until P = 0;
    end;
    FLib.GetUniqueGenres(Got);
    AssertEquals('the genres', Want.CommaText, Got.CommaText);

    Want.Clear;
    for I := 0 to High(A) do
      Want.Add(Trim(A[I].AlbumArtist) + ' - ' + Trim(A[I].Album));
    FLib.GetUniqueAlbums(Got);
    AssertEquals('the albums', Want.CommaText, Got.CommaText);

    { and again after the library changed (the lists are built anew): a
      track more, of an artist that sorts into the middle }
    SetLength(A, Length(A) + 1);
    T := Default(TTrackInfo);
    T.AlbumArtist := 'Kraftwerk';
    T.Artist := T.AlbumArtist;
    T.Album := 'Autobahn';
    T.Genre := 'Electronic';
    T.Title := 'One more';
    T.FolderDir := 'm:\more\';
    T.FilePath := T.FolderDir + '01.flac';
    A[High(A)] := T;
    FLib.ReplaceContent(A, Folders, Links);
    Want.Clear;
    for I := 0 to High(A) do
    begin
      Raw := A[I].AlbumArtist;
      repeat
        P := Pos(';', Raw);
        if P > 0 then
        begin
          Item := Trim(Copy(Raw, 1, P - 1));
          Raw := Copy(Raw, P + 1, MaxInt);
        end
        else
          Item := Trim(Raw);
        if Item <> '' then Want.Add(Item);
      until P = 0;
    end;
    FLib.GetUniqueArtists(Got);
    AssertEquals('the artists after a change of the library: still each once and in order',
      Want.CommaText, Got.CommaText);
    AssertTrue('the new artist is among them', Got.IndexOf('Kraftwerk') >= 0);
  finally
    Want.Free;
    Got.Free;
    Links.Free;
    Folders.Free;
  end;
end;

initialization
  RegisterTest(TTestLibraryPane);

end.
