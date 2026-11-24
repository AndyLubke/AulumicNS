unit TestPlaylistFormat;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestPlaylistFormat
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The album header and track formats as fields: every format of the fixed
  lists that settings and playlists were stored with reads as fields and is
  written back as the very same text; empty places, a field twice and no
  field at all; texts that are no such format; the quick formats of the View
  menu; a line without a separator at its ends. And the row of boxes itself:
  a format shows in its boxes with its example line, a pick changes it, no
  field shows what the caller falls back to.
  =============================================================================}

interface

uses
  Classes, SysUtils, Forms, fpcunit, testregistry, AuForms, uPlaylistFormat, AuFormatBoxes;

type
  TTestPlaylistFormat = class(TTestCase)
  private
    function Fields(A, B, C, D: TFmtField): TFmtFields;
  published
    procedure EveryStoredHeaderFormatSurvives;
    procedure EveryStoredTrackFormatSurvives;
    procedure AStoredFormatReadsAsItsFields;
    procedure EmptyPlacesAndDoublesAreLeftOut;
    procedure NoFieldIsNoFormat;
    procedure TheFieldThatIsNeverEmptyStandsWithoutBrackets;
    procedure OtherTextsAreNoFieldFormats;
    procedure TheQuickFormatsAreFieldFormats;
    procedure ALineHasNoSeparatorAtItsEnds;
  end;

  TTestFormatBoxes = class(TTestCase)
  private
    FForm: TAuForm;
    FChanges: Integer;
    procedure BoxesChanged(Sender: TObject);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AFormatShowsItsExample;
    procedure APickChangesTheFormat;
    procedure NoFieldShowsTheFallback;
    procedure AnotherTextIsKeptUntilABoxChanges;
  end;

implementation

const
  { the formats of the lists that were offered before the fields }
  STORED_HEADER: array[0..11] of string = (
    '%album%',
    '%album%[ • %first_albumartist%]',
    '%album%[ • %first_albumartist%][ • %resolution%]',
    '%album%[ • %year%][ • %first_albumartist%]',
    '%album%[ • %year%][ • %first_albumartist%][ • %resolution%]',
    '[%first_albumartist% • ]%album%',
    '[%first_albumartist% • ]%album%[ • %resolution%]',
    '[%first_albumartist% • ][%year% • ]%album%',
    '[%first_albumartist% • ][%year% • ]%album%[ • %resolution%]',
    '[%year% • ]%album%',
    '[%year% • ]%album%[ • %resolution%]',
    '[%first_genre% • ][%first_albumartist% • ]%album%');
  STORED_HEADER_NAMES: array[0..11] of string = (
    'Album', 'Album • Artist', 'Album • Artist • Specs', 'Album • Year • Artist',
    'Album • Year • Artist • Specs', 'Artist • Album', 'Artist • Album • Specs',
    'Artist • Year • Album', 'Artist • Year • Album • Specs', 'Year • Album',
    'Year • Album • Specs', 'Genre • Artist • Album');
  STORED_TRACK: array[0..6] of string = (
    '%title%',
    '%title%[ • %resolution%]',
    '%title%[ • %first_artist%]',
    '[%first_artist% • ]%title%',
    '[%first_artist% • ]%title%[ • %resolution%]',
    '[%first_artist% • ][%album% • ]%title%',
    '%filename%');
  STORED_TRACK_NAMES: array[0..6] of string = (
    'Title', 'Title • Specs', 'Title • Artist', 'Artist • Title', 'Artist • Title • Specs',
    'Artist • Album • Title', 'File name');

function TTestPlaylistFormat.Fields(A, B, C, D: TFmtField): TFmtFields;
begin
  Result[0] := A;
  Result[1] := B;
  Result[2] := C;
  Result[3] := D;
end;

procedure TTestPlaylistFormat.EveryStoredHeaderFormatSurvives;
var
  I: Integer;
  F: TFmtFields;
begin
  for I := 0 to High(STORED_HEADER) do
  begin
    AssertTrue('Reads as fields: ' + STORED_HEADER[I], FormatToFields(fkHeader, STORED_HEADER[I], F));
    AssertEquals('Written back unchanged', STORED_HEADER[I], FieldsToFormat(fkHeader, F));
    AssertEquals('Its name', STORED_HEADER_NAMES[I], FormatName(fkHeader, STORED_HEADER[I]));
  end;
end;

procedure TTestPlaylistFormat.EveryStoredTrackFormatSurvives;
var
  I: Integer;
  F: TFmtFields;
begin
  for I := 0 to High(STORED_TRACK) do
  begin
    AssertTrue('Reads as fields: ' + STORED_TRACK[I], FormatToFields(fkTrack, STORED_TRACK[I], F));
    AssertEquals('Written back unchanged', STORED_TRACK[I], FieldsToFormat(fkTrack, F));
    AssertEquals('Its name', STORED_TRACK_NAMES[I], FormatName(fkTrack, STORED_TRACK[I]));
  end;
end;

procedure TTestPlaylistFormat.AStoredFormatReadsAsItsFields;
var
  F: TFmtFields;
begin
  AssertTrue(FormatToFields(fkHeader, '[%first_albumartist% • ][%year% • ]%album%[ • %resolution%]', F));
  AssertTrue('Artist', F[0] = ffArtist);
  AssertTrue('Year', F[1] = ffYear);
  AssertTrue('Album', F[2] = ffAlbum);
  AssertTrue('Specs', F[3] = ffSpecs);
  AssertTrue(FormatToFields(fkTrack, '%title%', F));
  AssertTrue('Title', F[0] = ffTitle);
  AssertTrue('The other places are empty', (F[1] = ffNone) and (F[2] = ffNone) and (F[3] = ffNone));
end;

procedure TTestPlaylistFormat.EmptyPlacesAndDoublesAreLeftOut;
var
  F: TFmtFields;
begin
  AssertEquals('An empty place between two fields', '[%first_albumartist% • ]%album%',
    FieldsToFormat(fkHeader, Fields(ffNone, ffArtist, ffNone, ffAlbum)));
  AssertEquals('A field twice counts once', '%album%[ • %year%]',
    FieldsToFormat(fkHeader, Fields(ffAlbum, ffYear, ffAlbum, ffYear)));
  AssertEquals('A field the kind does not have', '%album%',
    FieldsToFormat(fkHeader, Fields(ffTitle, ffAlbum, ffFileName, ffNone)));
  F := TidyFields(fkTrack, Fields(ffNone, ffArtist, ffArtist, ffTitle));
  AssertTrue('Moved up', (F[0] = ffArtist) and (F[1] = ffTitle) and (F[2] = ffNone) and (F[3] = ffNone));
end;

procedure TTestPlaylistFormat.NoFieldIsNoFormat;
var
  F: TFmtFields;
begin
  AssertEquals('', FieldsToFormat(fkHeader, Fields(ffNone, ffNone, ffNone, ffNone)));
  AssertEquals('', FieldsToFormat(fkTrack, Fields(ffNone, ffNone, ffNone, ffNone)));
  AssertFalse('The empty text', FormatToFields(fkHeader, '', F));
  AssertEquals('The defaults are field formats', 'Album', FormatName(fkHeader, FMT_DEFAULT[fkHeader]));
  AssertEquals('Title', FormatName(fkTrack, FMT_DEFAULT[fkTrack]));
end;

procedure TTestPlaylistFormat.TheFieldThatIsNeverEmptyStandsWithoutBrackets;
var
  S: string;
  F: TFmtFields;
begin
  AssertEquals('The album before the artist', '[%composer% • ]%album%[ • %first_albumartist%]',
    FieldsToFormat(fkHeader, Fields(ffComposer, ffAlbum, ffArtist, ffNone)));
  AssertEquals('Without an album: the artist', '[%year% • ]%first_albumartist%[ • %first_genre%]',
    FieldsToFormat(fkHeader, Fields(ffYear, ffArtist, ffGenre, ffNone)));
  AssertEquals('The title before the file name', '[%filename% • ]%title%',
    FieldsToFormat(fkTrack, Fields(ffFileName, ffTitle, ffNone, ffNone)));
  AssertEquals('A track without title and file name: the artist', '[%composer% • ]%first_artist%',
    FieldsToFormat(fkTrack, Fields(ffComposer, ffArtist, ffNone, ffNone)));
  { only fields that can be empty: the first one }
  S := FieldsToFormat(fkHeader, Fields(ffYear, ffGenre, ffComposer, ffSpecs));
  AssertEquals('%year%[ • %first_genre%][ • %composer%][ • %resolution%]', S);
  AssertTrue('Such a format reads back too', FormatToFields(fkHeader, S, F));
  AssertTrue((F[0] = ffYear) and (F[1] = ffGenre) and (F[2] = ffComposer) and (F[3] = ffSpecs));
  AssertEquals('Year • Genre • Composer • Specs', FormatName(fkHeader, S));
end;

procedure TTestPlaylistFormat.OtherTextsAreNoFieldFormats;
var
  F: TFmtFields;
begin
  AssertFalse('A tag the fields do not have', FormatToFields(fkHeader, '%album%[ • %comment%]', F));
  AssertTrue('No fields are given then', F[0] = ffNone);
  AssertFalse('Another separator', IsFieldFormat(fkHeader, '%album% - %year%'));
  AssertFalse('Words around the tags', IsFieldFormat(fkTrack, 'Track: %title%'));
  AssertFalse('The header''s artist in a track format', IsFieldFormat(fkTrack, '%title%[ • %first_albumartist%]'));
  AssertFalse('The track''s artist in a header format', IsFieldFormat(fkHeader, '%album%[ • %first_artist%]'));
  AssertFalse('The title in a header format', IsFieldFormat(fkHeader, '%title%'));
  AssertFalse('Brackets on the other side', IsFieldFormat(fkHeader, '%first_albumartist%[ • %album%]'));
  AssertFalse('A field twice', IsFieldFormat(fkHeader, '%album%[ • %album%]'));
  AssertFalse('No tag at all', IsFieldFormat(fkTrack, 'title'));
  AssertFalse('A tag that is not closed', IsFieldFormat(fkTrack, '%title'));
  AssertFalse('Five fields', IsFieldFormat(fkHeader,
    '%album%[ • %year%][ • %first_genre%][ • %composer%][ • %resolution%][ • %first_albumartist%]'));
  AssertEquals('No name for it', '', FormatName(fkHeader, '%folder%'));
end;

procedure TTestPlaylistFormat.TheQuickFormatsAreFieldFormats;
var
  I: Integer;
begin
  for I := 0 to High(FMT_QUICK_HEADER) do
    AssertTrue(FMT_QUICK_HEADER[I], IsFieldFormat(fkHeader, FMT_QUICK_HEADER[I]));
  for I := 0 to High(FMT_QUICK_TRACK) do
    AssertTrue(FMT_QUICK_TRACK[I], IsFieldFormat(fkTrack, FMT_QUICK_TRACK[I]));
  AssertEquals('The first is the default', FMT_DEFAULT[fkHeader], FMT_QUICK_HEADER[0]);
  AssertEquals(FMT_DEFAULT[fkTrack], FMT_QUICK_TRACK[0]);
end;

procedure TTestPlaylistFormat.ALineHasNoSeparatorAtItsEnds;
begin
  AssertEquals('Jazz • 24/96', TidyFormatted(' • Jazz • 24/96'));
  AssertEquals('Jazz', TidyFormatted('Jazz • '));
  AssertEquals('Two in a row', 'Jazz', TidyFormatted(' •  • Jazz'));
  AssertEquals('Only separators', '', TidyFormatted(' • '));
  AssertEquals('Untouched', 'A • B', TidyFormatted('A • B'));
  AssertEquals('', TidyFormatted(''));
end;

{ ---- TTestFormatBoxes ---- }

procedure TTestFormatBoxes.SetUp;
begin
  FForm := TAuForm.CreateAu(nil, 'Formats', 700, 200);
  FChanges := 0;
end;

procedure TTestFormatBoxes.TearDown;
begin
  FreeAndNil(FForm);
end;

procedure TTestFormatBoxes.BoxesChanged(Sender: TObject);
begin
  Inc(FChanges);
end;

procedure TTestFormatBoxes.AFormatShowsItsExample;
var
  B: TFormatBoxes;
begin
  B := TFormatBoxes.CreateBoxes(FForm, FForm.Body, fkHeader, 20, 20, 640);
  B.OnChange := @BoxesChanged;
  B.Format := '[%first_albumartist% • ][%year% • ]%album%';
  AssertEquals('Read back unchanged', '[%first_albumartist% • ][%year% • ]%album%', B.Format);
  AssertEquals('Mara Lindqvist • 2019 • Northern Lights', B.PreviewText);
  AssertEquals('Setting a format is no change by the user', 0, FChanges);
  B := TFormatBoxes.CreateBoxes(FForm, FForm.Body, fkTrack, 20, 100, 640);
  B.Format := '%title%[ • %resolution%]';
  AssertEquals('First Snow • 24/96', B.PreviewText);
end;

procedure TTestFormatBoxes.APickChangesTheFormat;
var
  B: TFormatBoxes;
begin
  B := TFormatBoxes.CreateBoxes(FForm, FForm.Body, fkHeader, 20, 20, 640);
  B.OnChange := @BoxesChanged;
  B.Format := '%album%';
  B.Choose(2, ffComposer);
  AssertEquals('An empty box between them is passed over', '%album%[ • %composer%]', B.Format);
  AssertEquals('Northern Lights • Erik Sandvik', B.PreviewText);
  AssertEquals('The caller is told', 1, FChanges);
  B.Choose(0, ffYear);
  AssertEquals('%year%[ • %composer%]', B.Format);
  B.Choose(3, ffComposer);
  AssertEquals('The same field in two boxes counts once', '%year%[ • %composer%]', B.Format);
end;

procedure TTestFormatBoxes.NoFieldShowsTheFallback;
var
  B: TFormatBoxes;
begin
  B := TFormatBoxes.CreateBoxes(FForm, FForm.Body, fkTrack, 20, 20, 640);
  B.Format := '';
  AssertEquals('', B.Format);
  AssertEquals('Without a fallback given: the plain title', 'First Snow', B.PreviewText);
  B.SetEmpty('As in Preferences: ', '[%first_artist% • ]%title%');
  AssertEquals('As in Preferences: Mara Lindqvist • First Snow', B.PreviewText);
  B.Choose(0, ffTitle);
  AssertEquals('%title%', B.Format);
  AssertEquals('First Snow', B.PreviewText);
  B.Choose(0, ffNone);
  AssertEquals('Emptied again', '', B.Format);
end;

procedure TTestFormatBoxes.AnotherTextIsKeptUntilABoxChanges;
var
  B: TFormatBoxes;
begin
  B := TFormatBoxes.CreateBoxes(FForm, FForm.Body, fkHeader, 20, 20, 640);
  B.Format := '%album% - %comment%';
  AssertEquals('Not lost by opening the window', '%album% - %comment%', B.Format);
  B.Choose(0, ffAlbum);
  AssertEquals('Replaced by a pick', '%album%', B.Format);
end;

initialization
  RegisterTest(TTestPlaylistFormat);
  RegisterTest(TTestFormatBoxes);

end.
