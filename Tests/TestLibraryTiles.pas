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
  Classes, SysUtils, Forms, fpcunit, testregistry, uLibraryTypes, AuLibraryTiles, AuTileGrid;

type
  TTestLibraryTiles = class(TTestCase)
  private
    FForm: TForm;
    FTiles: TLibraryTiles;
    FTracks: TTrackList;
    procedure Add(const AFolder, AFile, AAlbumArtist, AArtist, AAlbum: string;
      ADisc, ATrack: Integer; AYear: Integer = 0; AAdded: Int64 = 0);
    function IndexOfTitle(const ATitle: string): Integer;
    function Titles: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AnAlbumOverTwoFoldersIsOneTileInAlbumOrder;
    procedure WithoutAnAlbumArtistTheFolderKeepsAlbumsApart;
    procedure TracksWithoutAnAlbumTagAreATilePerFolder;
    procedure TheSameFileTwiceCountsOnce;
    procedure TheTilesFollowTheChosenOrder;
    procedure ASearchCountsTheTracksFound;
    procedure TheSelectionSurvivesReadingTheSameAgain;
  end;

implementation

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

initialization
  RegisterTest(TTestLibraryTiles);

end.
