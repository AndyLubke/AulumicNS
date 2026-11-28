unit TestLibraryTiles;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestLibraryTiles
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The album tiles of the library pane (TLibraryTiles.SetTracks): which tracks
  make one tile, the order of the tracks in it, the artist line, the four
  orders of the tiles, the count of the tracks a search found, and that a
  selection survives when the same part of the library is read again.
  =============================================================================}

interface

uses
  Classes, SysUtils, Types, Controls, Forms, fpcunit, testregistry, uLibraryTypes, AuLibraryTiles, AuTileGrid;

type
  TTestLibraryTiles = class(TTestCase)
  private
    FForm: TForm;
    FTiles: TLibraryTiles;
    FTracks: TTrackList;
    FPlayed, FMenuOf, FPlayCount, FMenuCount: Integer;
    procedure Add(const AFolder, AFile, AAlbumArtist, AArtist, AAlbum: string;
      ADisc, ATrack: Integer; AYear: Integer = 0; AAdded: Int64 = 0);
    function IndexOfTitle(const ATitle: string): Integer;
    function Titles: string;
    procedure AddAlbums(ACount: Integer);
    function Part(AFrom, ATo: Integer): TTrackList;
    procedure NotePlay(Sender: TObject; Index: Integer);
    procedure NoteMenu(Sender: TObject; Index: Integer; ScreenPt: TPoint);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AnAlbumOverTwoFoldersIsOneTileInAlbumOrder;
    procedure WithoutAnAlbumArtistTheFolderKeepsAlbumsApart;
    procedure TracksWithoutAnAlbumTagAreATilePerFolder;
    procedure TheSameFileTwiceCountsOnce;
    procedure TheTilesFollowTheChosenOrder;
    procedure ByComposerKeepsRecordingsOfAWorkTogether;
    procedure ByFolderFollowsTheTree;
    procedure ASearchCountsTheTracksFound;
    procedure TheSelectionSurvivesReadingTheSameAgain;
    procedure APlaceComesBackAsItWasLeft;
    procedure ASearchInBetweenReturnsToThePlace;
    procedure ComingUpShowsTheAlbumThatWasLeft;
    procedure TheTopTilesStayWhenTheSizeChanges;
    procedure TheButtonsOfATilePlayAndOpenTheMenu;
  end;

implementation

type
  { the grid's mouse methods, for the tests }
  TGridAccess = class(TAuTileGrid);

procedure TTestLibraryTiles.NotePlay(Sender: TObject; Index: Integer);
begin
  FPlayed := Index;
  Inc(FPlayCount);
end;

procedure TTestLibraryTiles.NoteMenu(Sender: TObject; Index: Integer; ScreenPt: TPoint);
begin
  FMenuOf := Index;
  Inc(FMenuCount);
end;

{ the play and the menu button of a tile: on the tile under the pointer and
  on the selected tile with the focus; a click on a selected tile's button
  keeps the selection, on another tile it selects that one; a press that is
  let go elsewhere does nothing }
procedure TTestLibraryTiles.TheButtonsOfATilePlayAndOpenTheMenu;
var
  G: TGridAccess;
  RP, RM, R: TRect;
  Idx: Integer;

  procedure ClickAt(const ARect: TRect; AShift: TShiftState = []);
  var
    X, Y: Integer;
  begin
    X := (ARect.Left + ARect.Right) div 2;
    Y := (ARect.Top + ARect.Bottom) div 2;
    G.MouseMove([], X, Y);
    G.MouseDown(mbLeft, AShift + [ssLeft], X, Y);
    G.MouseUp(mbLeft, AShift, X, Y);
  end;

begin
  Add('m:\a', '1.flac', 'A', 'A', 'Alpha', 1, 1);
  Add('m:\b', '1.flac', 'B', 'B', 'Bravo', 1, 1);
  Add('m:\c', '1.flac', 'C', 'C', 'Charlie', 1, 1);
  FTiles.Sort := tsAlbum;
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  G := TGridAccess(FTiles.Grid);
  G.TabStop := False;       // (a click takes the focus, which a hidden form cannot give)
  G.OnTilePlay := @NotePlay;
  G.OnTileContext := @NoteMenu;
  FPlayed := -1;
  FMenuOf := -1;
  AssertFalse('no pointer, nothing selected: no buttons', G.ShowsButtons(1));
  R := G.TileRect(1);
  G.MouseMove([], R.Left + 10, R.Top + 10);
  AssertTrue('under the pointer', G.ShowsButtons(1));
  AssertFalse('and only there', G.ShowsButtons(0));
  G.ButtonRects(1, RP, RM);
  ClickAt(RP);
  AssertEquals('play', 1, FPlayed);
  AssertEquals('once', 1, FPlayCount);
  AssertTrue('the tile is the one selected', G.Selected[1] and (G.SelCount = 1));
  G.MouseMove([], (RM.Left + RM.Right) div 2, (RM.Top + RM.Bottom) div 2);
  AssertEquals('the menu button is found', TILE_BTN_MENU,
    G.ButtonAt((RM.Left + RM.Right) div 2, (RM.Top + RM.Bottom) div 2, Idx));
  ClickAt(RM);
  AssertEquals('the menu of that tile', 1, FMenuOf);
  AssertEquals('no second play', 1, FPlayCount);
  { two tiles selected: the button of one of them keeps both }
  G.SelectOnly(0);
  R := G.TileRect(2);
  ClickAt(Rect(R.Left + 4, R.Top + 4, R.Left + 12, R.Top + 12), [ssCtrl]);
  AssertEquals(2, G.SelCount);
  G.ButtonRects(2, RP, RM);
  ClickAt(RP);
  AssertEquals('play on a selected tile', 2, FPlayed);
  AssertEquals('the selection stays', 2, G.SelCount);
  { without the pointer: the selected tile with the focus has them }
  G.MouseLeave;
  AssertTrue(G.ShowsButtons(2));
  AssertFalse('a selected tile without the focus has none', G.ShowsButtons(0));
  { pressed on the button, let go beside it }
  G.MouseMove([], RP.Left + 3, RP.Top + 3);
  G.MouseDown(mbLeft, [ssLeft], RP.Left + 3, RP.Top + 3);
  G.MouseUp(mbLeft, [], RP.Left + 3, RP.Top - 30);
  AssertEquals('nothing played', 2, FPlayCount);
  AssertEquals('no menu', 1, FMenuCount);
end;

procedure TTestLibraryTiles.SetUp;
begin
  FForm := TForm.CreateNew(nil);
  FForm.SetBounds(0, 0, 600, 600);
  FTiles := TLibraryTiles.Create(FForm);
  FTiles.Parent := FForm;
  FTiles.SetBounds(0, 0, 600, 600);
  FTracks := TTrackList.Create;
end;

procedure TTestLibraryTiles.TearDown;
begin
  FreeAndNil(FTracks);
  FreeAndNil(FForm);
end;

procedure TTestLibraryTiles.Add(const AFolder, AFile, AAlbumArtist, AArtist, AAlbum: string;
  ADisc, ATrack: Integer; AYear: Integer; AAdded: Int64);
var
  T: TTrackInfo;
begin
  T := Default(TTrackInfo);
  T.FolderDir := AFolder;
  T.FilePath := AFolder + '\' + AFile;
  T.Title := AFile;
  T.AlbumArtist := AAlbumArtist;
  T.Artist := AArtist;
  T.Album := AAlbum;
  T.DiscNumber := ADisc;
  T.TrackNumber := ATrack;
  T.Year := AYear;
  T.DateAdded := AAdded;
  FTracks.Add(T);
end;

function TTestLibraryTiles.IndexOfTitle(const ATitle: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FTiles.TileCount - 1 do
    if FTiles.Tile(I)^.Title = ATitle then Exit(I);
  Result := -1;
end;

{ the titles in the order shown, joined by '|' }
function TTestLibraryTiles.Titles: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FTiles.TileCount - 1 do
  begin
    if I > 0 then Result := Result + '|';
    Result := Result + FTiles.Tile(I)^.Title;
  end;
end;

procedure TTestLibraryTiles.AnAlbumOverTwoFoldersIsOneTileInAlbumOrder;
var
  T: PLibTile;
begin
  Add('m:\box\CD2', 'b.flac', 'Quartet', 'Quartet', 'The Box', 2, 2);
  Add('m:\box\CD1', 'b.flac', 'Quartet', 'Quartet', 'The Box', 1, 2);
  Add('m:\box\CD2', 'a.flac', 'quartet', 'Quartet', 'the box', 2, 1);
  Add('m:\box\CD1', 'a.flac', 'Quartet', 'Quartet', 'The Box', 1, 1);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals('one tile', 1, FTiles.TileCount);
  T := FTiles.Tile(0);
  AssertEquals('its tracks', 4, T^.PathCount);
  AssertEquals('m:\box\CD1\a.flac', T^.Paths[0]);
  AssertEquals('m:\box\CD1\b.flac', T^.Paths[1]);
  AssertEquals('m:\box\CD2\a.flac', T^.Paths[2]);
  AssertEquals('m:\box\CD2\b.flac', T^.Paths[3]);
  AssertEquals('Quartet', T^.Artist);
end;

procedure TTestLibraryTiles.WithoutAnAlbumArtistTheFolderKeepsAlbumsApart;
var
  A, B: PLibTile;
begin
  Add('m:\one\Greatest Hits', '1.flac', '', 'First Band', 'Greatest Hits', 0, 1);
  Add('m:\one\Greatest Hits', '2.flac', '', 'First Band', 'Greatest Hits', 0, 2);
  Add('m:\two\Greatest Hits', '1.flac', '', 'Singer A', 'Greatest Hits', 0, 1);
  Add('m:\two\Greatest Hits', '2.flac', '', 'Singer B', 'Greatest Hits', 0, 2);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals('two tiles', 2, FTiles.TileCount);
  A := FTiles.Tile(0);
  B := FTiles.Tile(1);
  if A^.FolderDir <> 'm:\one\Greatest Hits' then
  begin
    A := FTiles.Tile(1);
    B := FTiles.Tile(0);
  end;
  AssertEquals('one artist: named', 'First Band', A^.Artist);
  AssertEquals('several artists', 'Various artists', B^.Artist);
end;

procedure TTestLibraryTiles.TracksWithoutAnAlbumTagAreATilePerFolder;
begin
  Add('m:\loose\Singles', 'x.flac', '', 'Somebody', '', 0, 0);
  Add('m:\loose\Singles', 'y.flac', '', 'Somebody', '', 0, 0);
  Add('m:\loose\Demos', 'z.flac', '', 'Somebody', '', 0, 0);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals('a tile per folder', 2, FTiles.TileCount);
  AssertTrue('named after the folder', IndexOfTitle('Singles') >= 0);
  AssertTrue('named after the folder', IndexOfTitle('Demos') >= 0);
  AssertEquals(2, FTiles.Tile(IndexOfTitle('Singles'))^.PathCount);
end;

procedure TTestLibraryTiles.TheSameFileTwiceCountsOnce;
begin
  Add('m:\a', '1.flac', 'Band', 'Band', 'Album', 1, 1);
  Add('m:\a', '2.flac', 'Band', 'Band', 'Album', 1, 2);
  Add('m:\a', '1.flac', 'Band', 'Band', 'Album', 1, 1);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals(1, FTiles.TileCount);
  AssertEquals('the file once', 2, FTiles.Tile(0)^.PathCount);
end;

procedure TTestLibraryTiles.TheTilesFollowTheChosenOrder;
begin
  Add('m:\1', '1.flac', 'Zed', 'Zed', 'Alpha', 1, 1, 2001, 300);
  Add('m:\2', '1.flac', 'Abel', 'Abel', 'Charlie', 1, 1, 1990, 100);
  Add('m:\3', '1.flac', 'Abel', 'Abel', 'Bravo', 1, 1, 0, 200);
  Add('m:\4', '1.flac', 'Mid', 'Mid', 'Delta', 1, 1, 1985, 400);
  FTiles.Sort := tsArtist;
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals('by artist, then year (none last)', 'Charlie|Bravo|Delta|Alpha', Titles);
  FTiles.Sort := tsAlbum;
  AssertEquals('by album', 'Alpha|Bravo|Charlie|Delta', Titles);
  FTiles.Reverse := True;
  AssertEquals('by album, backwards', 'Delta|Charlie|Bravo|Alpha', Titles);
  FTiles.Reverse := False;
  FTiles.Sort := tsYear;
  AssertEquals('by year, without a year last', 'Delta|Charlie|Alpha|Bravo', Titles);
  FTiles.Sort := tsAdded;
  AssertEquals('the newest first', 'Delta|Alpha|Bravo|Charlie', Titles);
end;

{ the order by composer: an album's composer is the one its tracks name
  (tracks without one do not count), several make it "Various composers";
  those and the albums without a composer come last }
procedure TTestLibraryTiles.ByComposerKeepsRecordingsOfAWorkTogether;

  procedure AddC(const AFolder, AFile, AArtist, AAlbum, AComposer: string; ATrack: Integer);
  begin
    Add(AFolder, AFile, AArtist, AArtist, AAlbum, 1, ATrack);
    FTracks[FTracks.Count - 1]^.Composer := AComposer;
  end;

begin
  AddC('m:\1', '1.flac', 'Lang', 'Goldberg L', 'Bach', 1);
  AddC('m:\2', '1.flac', 'Gould', 'Goldberg G', 'bach', 1);
  AddC('m:\3', '1.flac', 'Pianist', 'Recital', 'Bach', 1);
  AddC('m:\3', '2.flac', 'Pianist', 'Recital', '', 2);
  AddC('m:\3', '3.flac', 'Pianist', 'Recital', 'Liszt', 3);
  AddC('m:\4', '1.flac', 'Band', 'Songs', '', 1);
  AddC('m:\5', '1.flac', 'Trio', 'Trios', '', 1);
  AddC('m:\5', '2.flac', 'Trio', 'Trios', 'Arensky', 2);
  FTiles.Sort := tsComposer;
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals('by composer, then album; several and none last',
    'Trios|Goldberg G|Goldberg L|Recital|Songs', Titles);
  AssertEquals('named by a later track', 'Arensky', FTiles.Tile(0)^.Composer);
  AssertEquals('two composers', 'Various composers', FTiles.Tile(3)^.Composer);
  AssertEquals('none', '', FTiles.Tile(4)^.Composer);
  FTiles.Reverse := True;
  AssertEquals('backwards', 'Songs|Recital|Goldberg L|Goldberg G|Trios', Titles);
end;

{ the order by folder: as the tree lists the folders - part by part of the
  path, not the path as one text; a folder's sub folders before the album
  in the folder itself; two albums of one folder by their titles }
procedure TTestLibraryTiles.ByFolderFollowsTheTree;
begin
  Add('m:\Rock', '1.flac', 'A', 'A', 'Loose', 1, 1);
  Add('m:\Rock\Zed', '1.flac', 'A', 'A', 'Inner', 1, 1);
  Add('m:\jazz live\x', '1.flac', 'B', 'B', 'Live', 1, 1);
  Add('m:\Jazz\b', '1.flac', 'C', 'C', 'Studio', 1, 1);
  Add('m:\Jazz\b', '2.flac', 'D', 'D', 'Another', 1, 1);
  Add('m:\Jazz\a', '1.flac', 'Z', 'Z', 'Zulu', 1, 1);
  FTiles.Sort := tsFolder;
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals('as the folders stand in the tree', 'Zulu|Another|Studio|Live|Inner|Loose', Titles);
  FTiles.Reverse := True;
  AssertEquals('backwards', 'Loose|Inner|Live|Studio|Another|Zulu', Titles);
  AssertEquals('one folder', 0, CompareFolderOrder('m:\a\', 'M:\A'));
end;

procedure TTestLibraryTiles.ASearchCountsTheTracksFound;
var
  Found: TStringList;
begin
  Add('m:\a', '1.flac', 'Band', 'Band', 'Album', 1, 1);
  Add('m:\a', '2.flac', 'Band', 'Band', 'Album', 1, 2);
  Add('m:\a', '3.flac', 'Band', 'Band', 'Album', 1, 3);
  Add('m:\b', '1.flac', 'Other', 'Other', 'Else', 1, 1);
  Found := TStringList.Create;
  try
    Found.UseLocale := False;
    Found.CaseSensitive := True;
    Found.Sorted := True;
    Found.Add('m:\a\1.flac');
    Found.Add('m:\a\3.flac');
    FTiles.SetTracks(FTracks, Found, 'harbour', 'Search: harbour', '', False);
  finally
    Found.Free;
  end;
  AssertEquals(2, FTiles.Tile(IndexOfTitle('Album'))^.Found);
  AssertEquals(0, FTiles.Tile(IndexOfTitle('Else'))^.Found);
end;

procedure TTestLibraryTiles.TheSelectionSurvivesReadingTheSameAgain;
var
  I: Integer;
begin
  Add('m:\2', '1.flac', 'Band', 'Band', 'Bravo', 1, 1);
  Add('m:\3', '1.flac', 'Band', 'Band', 'Charlie', 1, 1);
  FTiles.Sort := tsAlbum;
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  FTiles.Grid.SelectOnly(IndexOfTitle('Charlie'));
  { an album more, in front of it }
  Add('m:\1', '1.flac', 'Band', 'Band', 'Alpha', 1, 1);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, True);
  I := IndexOfTitle('Charlie');
  AssertEquals('it moved', 2, I);
  AssertTrue('still selected', FTiles.Grid.Selected[I]);
  AssertEquals('and nothing else', 1, FTiles.Grid.SelCount);
  AssertEquals('the focus went with it', I, FTiles.Grid.FocusIndex);
  { without AKeep: a new set of tiles, nothing selected }
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False);
  AssertEquals(0, FTiles.Grid.SelCount);
end;

{ ACount albums "Album 01" .. of one band, a folder each; the tiles show them
  in this order }
procedure TTestLibraryTiles.AddAlbums(ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do
    Add(Format('m:\%.2d', [I]), '1.flac', 'Band', 'Band', Format('Album %.2d', [I]), 1, 1);
  FTiles.Sort := tsAlbum;
end;

{ only the albums AFrom .. ATo of AddAlbums, as a part of the library }
function TTestLibraryTiles.Part(AFrom, ATo: Integer): TTrackList;
var
  I: Integer;
begin
  Result := TTrackList.Create;
  for I := AFrom to ATo do Result.Add(FTracks[I - 1]^);
end;

procedure TTestLibraryTiles.APlaceComesBackAsItWasLeft;
var
  Top, Off, Got: Integer;
begin
  AddAlbums(90);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  AssertEquals('a place not shown before starts at the top', 0, FTiles.Grid.ScrollOffset);
  FTiles.Grid.SelectOnly(IndexOfTitle('Album 62'));
  FTiles.Grid.ScrollToTile(IndexOfTitle('Album 60'), 7);
  Top := FTiles.Grid.TopTile(Off);
  AssertTrue('the test scrolled', FTiles.Grid.ScrollOffset > 0);
  AssertEquals(7, Off);
  { the tiles are put away (the tree is shown) and come back }
  FTiles.SetTracks(nil, nil, '', '', '', False);
  AssertEquals(0, FTiles.TileCount);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  Got := FTiles.Grid.TopTile(Off);
  AssertEquals('the same album at the top', Top, Got);
  AssertEquals('scrolled as far into its row', 7, Off);
  AssertTrue('the selection is back', FTiles.Grid.Selected[IndexOfTitle('Album 62')]);
  AssertEquals(1, FTiles.Grid.SelCount);
  AssertEquals('and the focus', IndexOfTitle('Album 62'), FTiles.Grid.FocusIndex);
end;

procedure TTestLibraryTiles.ASearchInBetweenReturnsToThePlace;
var
  Top, Off, Got: Integer;
  Few: TTrackList;
begin
  AddAlbums(90);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  FTiles.Grid.ScrollToTile(IndexOfTitle('Album 45'), 3);
  Top := FTiles.Grid.TopTile(Off);
  Few := Part(10, 12);
  try
    { two letters typed, then a third: two searches }
    FTiles.SetTracks(Few, nil, 'al', 'Search: al', '', False);
    AssertEquals('a search starts at the top', 0, FTiles.Grid.ScrollOffset);
    FTiles.SetTracks(Few, nil, 'alb', 'Search: alb', '', False);
  finally
    Few.Free;
  end;
  { the search box is emptied }
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  Got := FTiles.Grid.TopTile(Off);
  AssertEquals('where it was before the search', Top, Got);
  AssertEquals(3, Off);
end;

procedure TTestLibraryTiles.ComingUpShowsTheAlbumThatWasLeft;
var
  Few: TTrackList;
  R: TRect;
  I, Off: Integer;
begin
  AddAlbums(90);
  { all albums were looked at, near their beginning }
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  FTiles.Grid.ScrollToTile(IndexOfTitle('Album 10'));
  { a folder inside (reached through the tree: the tiles were put away) }
  FTiles.SetTracks(nil, nil, '', '', '', False);
  Few := Part(70, 75);
  try
    FTiles.SetTracks(Few, nil, '', 'Folders'#1'Seventies', '', True, False, 'Folders'#1'Seventies');
    AssertEquals(6, FTiles.TileCount);
    FTiles.Grid.SelectOnly(IndexOfTitle('Album 72'));
  finally
    Few.Free;
  end;
  { up through the path above the tiles }
  FTiles.SetTracks(FTracks, nil, '', 'Folders', '', True, False, 'Folders');
  I := IndexOfTitle('Album 72');
  AssertEquals('the album left has the focus', I, FTiles.Grid.FocusIndex);
  AssertTrue('and is selected', FTiles.Grid.Selected[I]);
  R := FTiles.Grid.TileRect(I);
  AssertTrue('in the top row', (R.Top >= 0) and (R.Top < FTiles.Grid.RowHeight));
  { and up to all albums: again the album left, not where all albums were
    scrolled to before }
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  R := FTiles.Grid.TileRect(IndexOfTitle('Album 72'));
  AssertTrue('in the top row of all albums', (R.Top >= 0) and (R.Top < FTiles.Grid.RowHeight));
  { a folder beside it is no way up: it starts at the top }
  Few := Part(1, 60);
  try
    FTiles.SetTracks(Few, nil, '', 'Folders'#1'Other', '', True, False, 'Folders'#1'Other');
    AssertEquals(0, FTiles.Grid.TopTile(Off));
    AssertEquals(0, FTiles.Grid.ScrollOffset);
  finally
    Few.Free;
  end;
end;

procedure TTestLibraryTiles.TheTopTilesStayWhenTheSizeChanges;
var
  I, Size: Integer;
  R: TRect;
begin
  AddAlbums(90);
  FTiles.SetTracks(FTracks, nil, '', 'All albums', '', False, False, TILE_PLACE_ALL);
  I := FTiles.Grid.TopTile(Size);
  FTiles.Grid.ScrollToTile(IndexOfTitle('Album 50'));
  I := FTiles.Grid.TopTile(Size);
  AssertTrue('scrolled', I > 0);
  for Size := TILE_SIZE_LIST to TILE_SIZE_MAX do
  begin
    FTiles.Grid.TileSize := Size;
    R := FTiles.Grid.TileRect(I);
    AssertTrue(Format('size %d: the album is still in the top row', [Size]),
      (R.Top >= 0) and (R.Top < FTiles.Grid.RowHeight));
  end;
  { a narrower pane: other columns }
  FTiles.Grid.TileSize := 2;
  FTiles.SetBounds(0, 0, 380, 600);
  R := FTiles.Grid.TileRect(I);
  AssertTrue('narrower: still in the top row', (R.Top >= 0) and (R.Top < FTiles.Grid.RowHeight));
end;

initialization
  RegisterTest(TTestLibraryTiles);

end.
