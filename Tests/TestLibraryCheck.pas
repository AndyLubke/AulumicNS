unit TestLibraryCheck;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestLibraryCheck
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The check of the tags (uLibraryCheck): albums without a composer and albums
  where only some tracks have one, with the files to look at; composers that
  share a surname but are written in several ways; artists and genres that
  are the same name without case, accents and punctuation - and what is not
  reported (a complete album, two ensembles that end on the same word, a name
  written one way); the order of the findings.
  =============================================================================}

interface

uses
  Classes, SysUtils, Forms, fpcunit, testregistry, uLibraryTypes, uLibraryCheck, AuForms, AuLibraryCheck;

type
  TTestLibraryCheck = class(TTestCase)
  private
    FTracks: TTrackList;
    FFound: TCheckFindings;
    FOpened: TStringList;
    procedure TakeOpened(APaths: TStrings);
    procedure Add(const AFolder, AFile, AArtist, AAlbum, AComposer: string; const AGenre: string = 'Classical');
    procedure RunCheck;
    function CountOf(AKind: TCheckKind): Integer;
    function FindText(AKind: TCheckKind; const APart: string): Integer;
    function Last: PTrackInfo;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheKeysOfNames;
    procedure NothingToCheckFindsNothing;
    procedure AlbumsWithoutAComposer;
    procedure ComposersWithOneSurname;
    procedure ArtistsAndGenresByTheWholeName;
    procedure TheFindingsAreInOrder;
    procedure SeveralFindingsOpenTogether;
    procedure TheBasicsThatAreMissing;
    procedure AnAlbumThatDisagreesWithItself;
    procedure TrackNumbersTwiceAndGaps;
    procedure TheWindowShowsOneKind;
    procedure SortedByFindingAnAlbumStaysTogether;
  end;

implementation

procedure TTestLibraryCheck.SetUp;
begin
  FTracks := TTrackList.Create;
  FOpened := TStringList.Create;
  FFound := nil;
end;

procedure TTestLibraryCheck.TearDown;
begin
  FFound := nil;
  FreeAndNil(FOpened);
  FreeAndNil(FTracks);
end;

procedure TTestLibraryCheck.Add(const AFolder, AFile, AArtist, AAlbum, AComposer: string; const AGenre: string);
var
  T: TTrackInfo;
  I: Integer;
begin
  T := Default(TTrackInfo);
  T.FolderDir := AFolder;
  T.FilePath := AFolder + '\' + AFile;
  { a complete track unless a test takes something away: a title of its own,
    the next number of its album, a year }
  T.Title := 'Title of ' + ChangeFileExt(AFile, '');
  T.TrackNumber := 1;
  for I := 0 to FTracks.Count - 1 do
    if (FTracks[I]^.FolderDir = AFolder) and (FTracks[I]^.Album = AAlbum) then Inc(T.TrackNumber);
  T.DiscNumber := 1;
  T.Year := 2000;
  T.Artist := AArtist;
  T.AlbumArtist := AArtist;
  T.Album := AAlbum;
  T.Composer := AComposer;
  T.Genre := AGenre;
  FTracks.Add(T);
end;

procedure TTestLibraryCheck.RunCheck;
begin
  CheckTracks(FTracks, FFound);
end;

function TTestLibraryCheck.CountOf(AKind: TCheckKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FFound) do
    if FFound[I].Kind = AKind then Inc(Result);
end;

function TTestLibraryCheck.FindText(AKind: TCheckKind; const APart: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FFound) do
    if (FFound[I].Kind = AKind) and (Pos(APart, FFound[I].Text) > 0) then Exit(I);
  Result := -1;
end;

procedure TTestLibraryCheck.TheKeysOfNames;
begin
  AssertEquals('The last word', 'bach', PersonKey('Johann Sebastian Bach'));
  AssertEquals('Initials', 'bach', PersonKey('J. S. Bach'));
  AssertEquals('Before the comma', 'bach', PersonKey('Bach, Johann Sebastian'));
  AssertEquals('Without accents', PersonKey('Antonin Dvorak'), PersonKey('Antonín Dvořák'));
  AssertEquals('One word', 'shostakovich', PersonKey('Shostakovich'));
  AssertEquals('Case and a leading "the"', NameKey('beatles'), NameKey('The Beatles'));
  AssertEquals('Punctuation and spaces', NameKey('Hip Hop'), NameKey('hip-hop'));
  AssertTrue('Two ensembles differ', NameKey('Kronos Quartet') <> NameKey('Arditti Quartet'));
  AssertTrue('A name not in Latin letters keeps a key', NameKey('Шостакович') <> '');
  AssertTrue('And differs from another', NameKey('Шостакович') <> NameKey('Чайковский'));
end;

procedure TTestLibraryCheck.NothingToCheckFindsNothing;
begin
  RunCheck;
  AssertEquals('An empty list', 0, Length(FFound));
  CheckTracks(nil, FFound);
  AssertEquals('No list', 0, Length(FFound));
  Add('m:\a', '1.flac', 'Pianist', 'Recital', 'Bach');
  Add('m:\a', '2.flac', 'Pianist', 'Recital', 'Bach');
  RunCheck;
  AssertEquals('A complete album, one spelling', 0, Length(FFound));
end;

procedure TTestLibraryCheck.AlbumsWithoutAComposer;
var
  I: Integer;
begin
  Add('m:\a', '1.flac', 'Pianist', 'Recital', 'Bach');
  Add('m:\a', '2.flac', 'Pianist', 'Recital', '');
  Add('m:\a', '3.flac', 'Pianist', 'Recital', 'Bach');
  Add('m:\b', '1.flac', 'Band', 'Songs', '');
  Add('m:\b', '2.flac', 'Band', 'Songs', '  ');
  Add('m:\c', '1.flac', 'Trio', 'Trios', 'Arensky');
  { two albums in one folder are two albums }
  Add('m:\d', '1.flac', 'Duo', 'First', 'Bach');
  Add('m:\d', '2.flac', 'Duo', 'Second', '');
  RunCheck;
  AssertEquals('Without any', 2, CountOf(ckNoComposer));
  AssertEquals('With some', 1, CountOf(ckPartComposer));

  I := FindText(ckPartComposer, 'Pianist - Recital');
  AssertTrue('The recital', I >= 0);
  AssertEquals('1 of 3 tracks without', FFound[I].Note);
  AssertEquals('The file without', 1, Length(FFound[I].Paths));
  AssertEquals('m:\a\2.flac', FFound[I].Paths[0]);

  I := FindText(ckNoComposer, 'Band - Songs');
  AssertTrue('The songs', I >= 0);
  AssertEquals('2 tracks', FFound[I].Note);
  AssertEquals('Both files', 2, Length(FFound[I].Paths));

  I := FindText(ckNoComposer, 'Duo - Second');
  AssertTrue('The second album of the folder', I >= 0);
  AssertEquals('1 track', FFound[I].Note);
  AssertEquals('The complete albums are not listed', -1, FindText(ckNoComposer, 'Trios'));
end;

procedure TTestLibraryCheck.ComposersWithOneSurname;
var
  I: Integer;
begin
  Add('m:\a', '1.flac', 'P', 'A', 'Johann Sebastian Bach');
  Add('m:\a', '2.flac', 'P', 'A', 'Johann Sebastian Bach');
  Add('m:\a', '3.flac', 'P', 'A', 'Johann Sebastian Bach; Charles Gounod');
  Add('m:\b', '1.flac', 'P', 'B', 'J. S. Bach');
  Add('m:\c', '1.flac', 'P', 'C', 'Bach, J.S.');
  Add('m:\d', '1.flac', 'P', 'D', 'Richard Strauss');
  Add('m:\d', '2.flac', 'P', 'D', 'Richard Strauss');
  Add('m:\e', '1.flac', 'P', 'E', 'Johann Strauss');
  Add('m:\f', '1.flac', 'P', 'F', 'Maurice Ravel');
  RunCheck;
  AssertEquals('Bach and Strauss', 2, CountOf(ckComposerNames));

  I := FindText(ckComposerNames, 'J. S. Bach');
  AssertTrue('Bach', I >= 0);
  AssertEquals('3 spellings', FFound[I].Note);
  AssertEquals('The most used first, with the counts',
    'Johann Sebastian Bach (3)' + CHECK_NAME_SEPARATOR + 'Bach, J.S. (1)' + CHECK_NAME_SEPARATOR + 'J. S. Bach (1)',
    FFound[I].Text);
  AssertEquals('The files of the two rarer spellings', 2, Length(FFound[I].Paths));

  I := FindText(ckComposerNames, 'Johann Strauss');
  AssertTrue('Two people with one surname are listed too', I >= 0);
  AssertEquals('Only the rarer one''s file', 1, Length(FFound[I].Paths));
  AssertEquals('m:\e\1.flac', FFound[I].Paths[0]);

  AssertEquals('A name written one way', -1, FindText(ckComposerNames, 'Ravel'));
  AssertEquals('Nor the second composer of a track', -1, FindText(ckComposerNames, 'Gounod'));
end;

procedure TTestLibraryCheck.ArtistsAndGenresByTheWholeName;
var
  I: Integer;
begin
  Add('m:\a', '1.flac', 'Dvořák Quartet', 'A', 'X', 'Hip-Hop');
  Add('m:\a', '2.flac', 'Dvořák Quartet', 'A', 'X', 'Hip-Hop; Jazz');
  Add('m:\b', '1.flac', 'Dvorak Quartet', 'B', 'X', 'Hip Hop');
  Add('m:\c', '1.flac', 'Kronos Quartet', 'C', 'X', 'Jazz');
  Add('m:\d', '1.flac', 'Arditti Quartet', 'D', 'X', 'jazz');
  Add('m:\e', '1.flac', 'The Beatles', 'E', 'X', 'Pop');
  Add('m:\f', '1.flac', 'Beatles', 'F', 'X', 'Pop');
  RunCheck;
  AssertEquals('Dvořák and the Beatles', 2, CountOf(ckArtistNames));
  I := FindText(ckArtistNames, 'Dvorak Quartet');
  AssertTrue('With and without accents', I >= 0);
  AssertEquals('Dvořák Quartet (2)' + CHECK_NAME_SEPARATOR + 'Dvorak Quartet (1)', FFound[I].Text);
  AssertEquals('m:\b\1.flac', FFound[I].Paths[0]);
  AssertEquals('Two ensembles are two names', -1, FindText(ckArtistNames, 'Kronos'));

  AssertEquals('Hip-Hop and Jazz', 2, CountOf(ckGenreNames));
  I := FindText(ckGenreNames, 'Hip Hop');
  AssertTrue('With and without the hyphen', I >= 0);
  AssertEquals('Hip-Hop (2)' + CHECK_NAME_SEPARATOR + 'Hip Hop (1)', FFound[I].Text);
  I := FindText(ckGenreNames, 'jazz');
  AssertTrue('Only the case differs', I >= 0);
  AssertEquals('The one file in lower case', 1, Length(FFound[I].Paths));
  AssertEquals('m:\d\1.flac', FFound[I].Paths[0]);
end;

procedure TTestLibraryCheck.TheFindingsAreInOrder;
var
  I: Integer;
begin
  Add('m:\a', '1.flac', 'P', 'Small', '');
  Add('m:\b', '1.flac', 'P', 'Large', '');
  Add('m:\b', '2.flac', 'P', 'Large', '');
  Add('m:\b', '3.flac', 'P', 'Large', '');
  Add('m:\c', '1.flac', 'P', 'Part', 'Bach');
  Add('m:\c', '2.flac', 'P', 'Part', '');
  Add('m:\d', '1.flac', 'P', 'Whole', 'J. S. Bach');
  RunCheck;
  AssertTrue('Some findings', Length(FFound) >= 4);
  for I := 1 to High(FFound) do
  begin
    AssertTrue('By kind', FFound[I - 1].Kind <= FFound[I].Kind);
    if FFound[I - 1].Kind = FFound[I].Kind then
      AssertTrue('Within a kind the most files first', Length(FFound[I - 1].Paths) >= Length(FFound[I].Paths));
  end;
  AssertEquals('The larger album first', 'P - Large', FFound[0].Text);
end;

{ the track added last, to take something away from it }
function TTestLibraryCheck.Last: PTrackInfo;
begin
  Result := FTracks[FTracks.Count - 1];
end;

{ no album, no artist, no title, no track number }
procedure TTestLibraryCheck.TheBasicsThatAreMissing;
var
  I: Integer;
begin
  { a complete album: nothing }
  Add('m:\Bach\Goldberg', '1.flac', 'Gould', 'Goldberg', 'Bach');
  Add('m:\Bach\Goldberg', '2.flac', 'Gould', 'Goldberg', 'Bach');
  { two tracks without an album tag (the library calls it Unknown Album) and one with }
  Add('m:\Loose\Singles', 'a.flac', 'Singer', '', 'X');
  Add('m:\Loose\Singles', 'b.flac', 'Singer', 'Unknown Album', 'X');
  Add('m:\Loose\Singles', 'c.flac', 'Singer', 'An Album', 'X');
  { no artist on one of two tracks; no title on the other }
  Add('m:\c', '1.flac', 'Unknown Artist', 'Album C', 'X');
  Last^.AlbumArtist := 'Band';
  Add('m:\c', '2.flac', 'Band', 'Album C', 'X');
  Last^.Title := '2.FLAC';
  { no track numbers on an album; a single loose track needs none }
  Add('m:\d', '1.flac', 'Band', 'Album D', 'X');
  Last^.TrackNumber := 0;
  Add('m:\d', '2.flac', 'Band', 'Album D', 'X');
  Add('m:\e', '1.flac', 'Band', 'Album E', 'X');
  Last^.TrackNumber := 0;
  RunCheck;

  AssertEquals('One folder with tracks without an album', 1, CountOf(ckNoAlbum));
  I := FindText(ckNoAlbum, 'Loose\Singles');
  AssertTrue('Named by its folder', I >= 0);
  AssertEquals('2 of 3 tracks', FFound[I].Note);
  AssertEquals('The two files', 2, Length(FFound[I].Paths));

  AssertEquals('One album with a track without an artist', 1, CountOf(ckNoArtist));
  I := FindText(ckNoArtist, 'Band - Album C');
  AssertTrue('The album', I >= 0);
  AssertEquals('1 of 2 tracks', FFound[I].Note);
  AssertEquals('m:\c\1.flac', FFound[I].Paths[0]);

  AssertEquals('One title that is the file name', 1, CountOf(ckNoTitle));
  I := FindText(ckNoTitle, 'Album C');
  AssertEquals('m:\c\2.flac', FFound[I].Paths[0]);

  AssertEquals('One album without all its numbers', 1, CountOf(ckNoTrackNumber));
  I := FindText(ckNoTrackNumber, 'Band - Album D');
  AssertTrue('Album D', I >= 0);
  AssertEquals('1 of 2 tracks', FFound[I].Note);
  AssertEquals('A single track without a number is not listed', -1, FindText(ckNoTrackNumber, 'Album E'));
  AssertEquals('The complete album is in none of these', -1, FindText(ckNoTitle, 'Goldberg'));
end;

{ several album names in a folder, several album artists and years in an album }
procedure TTestLibraryCheck.AnAlbumThatDisagreesWithItself;
var
  I: Integer;
begin
  Add('m:\Box\CD1', '1.flac', 'Band', 'The Box', 'X');
  Add('m:\Box\CD1', '2.flac', 'Band', 'The Box', 'X');
  Add('m:\Box\CD1', '3.flac', 'Band', 'The Box (Disc 1)', 'X');
  Add('m:\Mix', '1.flac', 'Band', 'Mixed', 'X');
  Add('m:\Mix', '2.flac', 'Band', 'Mixed', 'X');
  Last^.AlbumArtist := 'Various Artists';
  Add('m:\Mix', '3.flac', 'Band', 'Mixed', 'X');
  Last^.Year := 1999;
  Add('m:\Fine', '1.flac', 'band', 'Fine', 'X');
  Add('m:\Fine', '2.flac', 'Band', 'Fine', 'X');
  RunCheck;

  AssertEquals('One folder with two album names', 1, CountOf(ckAlbumNames));
  I := FindText(ckAlbumNames, 'Box\CD1');
  AssertTrue('The folder', I >= 0);
  AssertEquals('2 album names', FFound[I].Note);
  AssertTrue('The names with their counts, the most used first',
    Pos('The Box (2)' + CHECK_NAME_SEPARATOR + 'The Box (Disc 1) (1)', FFound[I].Text) > 0);
  AssertEquals('The file of the rarer name', 1, Length(FFound[I].Paths));
  AssertEquals('m:\Box\CD1\3.flac', FFound[I].Paths[0]);

  AssertEquals('One album with two album artists', 1, CountOf(ckAlbumArtists));
  I := FindText(ckAlbumArtists, 'Mixed');
  AssertEquals('2 album artists', FFound[I].Note);
  AssertEquals('m:\Mix\2.flac', FFound[I].Paths[0]);
  AssertEquals('Only the case differs: one album artist', -1, FindText(ckAlbumArtists, 'Fine'));

  AssertEquals('One album with two years', 1, CountOf(ckYears));
  I := FindText(ckYears, 'Mixed');
  AssertEquals('2 years', FFound[I].Note);
  AssertTrue('Both years are named', (Pos('2000 (2)', FFound[I].Text) > 0) and (Pos('1999 (1)', FFound[I].Text) > 0));
end;

{ a track number twice on one disc, and a gap between the numbers }
procedure TTestLibraryCheck.TrackNumbersTwiceAndGaps;
var
  I: Integer;

  procedure AddNum(const AFolder, AAlbum: string; ADisc, ANum: Integer);
  begin
    Add(AFolder, Format('%d-%d-%d.flac', [ADisc, ANum, FTracks.Count]), 'Band', AAlbum, 'X');
    Last^.DiscNumber := ADisc;
    Last^.TrackNumber := ANum;
  end;

begin
  AddNum('m:\twice', 'Twice', 1, 1);
  AddNum('m:\twice', 'Twice', 1, 2);
  AddNum('m:\twice', 'Twice', 1, 2);
  AddNum('m:\gap', 'Gap', 1, 1);
  AddNum('m:\gap', 'Gap', 1, 2);
  AddNum('m:\gap', 'Gap', 1, 5);
  { two discs with the same numbers, and a second disc that counts on: fine }
  AddNum('m:\discs', 'Discs', 1, 1);
  AddNum('m:\discs', 'Discs', 1, 2);
  AddNum('m:\discs', 'Discs', 2, 1);
  AddNum('m:\discs', 'Discs', 2, 2);
  AddNum('m:\on', 'Counts On', 1, 1);
  AddNum('m:\on', 'Counts On', 1, 2);
  AddNum('m:\on', 'Counts On', 2, 3);
  AddNum('m:\on', 'Counts On', 2, 4);
  RunCheck;

  AssertEquals('One album with a number twice', 1, CountOf(ckTrackTwice));
  I := FindText(ckTrackTwice, 'Band - Twice');
  AssertTrue('The album', I >= 0);
  AssertEquals('track 2 twice', FFound[I].Note);
  AssertEquals('Both tracks with that number', 2, Length(FFound[I].Paths));

  AssertEquals('One album with a gap', 1, CountOf(ckTrackGap));
  I := FindText(ckTrackGap, 'Band - Gap');
  AssertTrue('The album', I >= 0);
  AssertEquals('missing: 3, 4', FFound[I].Note);
  AssertEquals('All its tracks, to look at', 3, Length(FFound[I].Paths));
  AssertEquals('The same numbers on two discs are fine', -1, FindText(ckTrackTwice, 'Discs'));
  AssertEquals('A disc that counts on has no gap', -1, FindText(ckTrackGap, 'Counts On'));
end;

{ the window's filter: all kinds, or the lines of one kind }
procedure TTestLibraryCheck.TheWindowShowsOneKind;
var
  F: TAuForm;
begin
  Add('m:\a', '1.flac', 'Band', 'A', '');
  Add('m:\a', '2.flac', 'Band', 'A', '');
  Add('m:\b', '1.flac', 'Band', 'B', '');
  Add('m:\c', '1.flac', 'Unknown Artist', 'C', 'X');
  RunCheck;
  AssertEquals('Two albums without a composer, one track without an artist', 3, Length(FFound));
  F := CreateLibraryCheckForm(nil, 'A test', FTracks);
  try
    AssertEquals('All kinds', 3, LibraryCheckRowCount(F));
    AssertTrue('The kind is offered', LibraryCheckFilter(F, 'No composer'));
    AssertEquals('Its two lines', 2, LibraryCheckRowCount(F));
    LibraryCheckOpenRows(F, [1], @TakeOpened);
    AssertEquals('The second of them opens the smaller album', 'm:\b\1.flac', FOpened.Text.Trim);
    AssertTrue('No artist', LibraryCheckFilter(F, 'No artist'));
    AssertEquals('One line', 1, LibraryCheckRowCount(F));
    AssertFalse('A kind without findings is not offered', LibraryCheckFilter(F, 'No title'));
    AssertTrue('Back to all', LibraryCheckFilter(F, ''));
    AssertEquals('All three again', 3, LibraryCheckRowCount(F));
  finally
    F.Free;
  end;
end;

{ a click on the Finding heading puts the lines of one album under each
  other, whatever their kind; Kind brings the order of the check back }
procedure TTestLibraryCheck.SortedByFindingAnAlbumStaysTogether;
var
  F: TAuForm;
  I: Integer;
begin
  { two albums, each without a composer and with a track without an artist }
  Add('m:\z', '1.flac', 'Zed', 'Zulu', '');
  Add('m:\z', '2.flac', 'Unknown Artist', 'Zulu', '');
  Last^.AlbumArtist := 'Zed';
  Add('m:\a', '1.flac', 'Abel', 'Alpha', '');
  Add('m:\a', '2.flac', 'Unknown Artist', 'Alpha', '');
  Last^.AlbumArtist := 'Abel';
  F := CreateLibraryCheckForm(nil, 'A test', FTracks);
  try
    AssertEquals('Two kinds for two albums', 4, LibraryCheckRowCount(F));
    AssertEquals('By kind first', 'No artist', LibraryCheckCell(F, 0, 0));
    AssertEquals('Both lines of that kind together', 'No artist', LibraryCheckCell(F, 1, 0));
    AssertEquals('Then the next kind', 'No composer', LibraryCheckCell(F, 2, 0));

    LibraryCheckSort(F, 1);
    AssertEquals('By finding: the first album', 'Abel - Alpha', LibraryCheckCell(F, 0, 1));
    AssertEquals('Its second line right under it', 'Abel - Alpha', LibraryCheckCell(F, 1, 1));
    AssertEquals('In the order of the kinds', 'No artist', LibraryCheckCell(F, 0, 0));
    AssertEquals('The other album after it', 'Zed - Zulu', LibraryCheckCell(F, 2, 1));
    LibraryCheckSort(F, 1);
    AssertEquals('A second click: backwards', 'Zed - Zulu', LibraryCheckCell(F, 0, 1));

    LibraryCheckSort(F, 0);
    for I := 0 to 1 do AssertEquals('By kind again', 'No artist', LibraryCheckCell(F, I, 0));
    { the order holds under the filter }
    LibraryCheckSort(F, 1);
    AssertTrue('One kind', LibraryCheckFilter(F, 'No composer'));
    AssertEquals('Its two lines by album', 'Abel - Alpha', LibraryCheckCell(F, 0, 1));
    AssertEquals('Zed - Zulu', LibraryCheckCell(F, 1, 1));
  finally
    F.Free;
  end;
end;

procedure TTestLibraryCheck.TakeOpened(APaths: TStrings);
begin
  FOpened.Assign(APaths);
end;

{ the window: several lines selected open the files of all of them, a file
  that two findings name only once; one line opens its own files }
procedure TTestLibraryCheck.SeveralFindingsOpenTogether;
var
  F: TAuForm;
begin
  { the first album has no composer at all and its artist is written in a
    second way too: its file is in two findings }
  Add('m:\a', '1.flac', 'the band', 'Songs', '');
  Add('m:\b', '1.flac', 'The Band', 'More', 'Bach');
  Add('m:\b', '2.flac', 'The Band', 'More', 'Bach');
  Add('m:\c', '1.flac', 'Solo', 'Alone', '');
  RunCheck;
  AssertEquals('Two albums without a composer, one artist in two spellings', 3, Length(FFound));
  F := CreateLibraryCheckForm(nil, 'A test', FTracks);
  try
    AssertEquals('A line per finding', 3, LibraryCheckRowCount(F));
    LibraryCheckOpenRows(F, [0], @TakeOpened);
    AssertEquals('One line: its file', 1, FOpened.Count);
    LibraryCheckOpenRows(F, [0, 1, 2], @TakeOpened);
    AssertEquals('All lines: each file once', 2, FOpened.Count);
    AssertTrue('The first', FOpened.IndexOf('m:\a\1.flac') >= 0);
    AssertTrue('The second', FOpened.IndexOf('m:\c\1.flac') >= 0);
    FOpened.Clear;
    LibraryCheckOpenRows(F, [], @TakeOpened);
    AssertEquals('No line: nothing is opened', 0, FOpened.Count);
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TTestLibraryCheck);

end.
