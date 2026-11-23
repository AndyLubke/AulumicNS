unit TestPlaylistRows;

{$mode ObjFPC}{$H+}
{$codepage UTF8}

{ ==============================================================================
  AulumicNS tests - TestPlaylistRows
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for uPlaylistRows (the playlist's rows without UI):
    TTestRowCopies  : track <-> stored playlist entry
    TTestRowRules   : CleanTag, TimeStrToSecs, FormatGroupDuration,
                      PlaylistGroupKey
    TTestRatings    : the rating key (album artist / album fallbacks),
                      average, star under a click, same star clears
    TTestHeaderText : a group header in one or two lines (FitTextWithEllipsis,
                      SplitHeaderIntoTwoLines), measured at 10 px per character
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uAppConsts, uLibraryTypes,
  uPlaylistFile, uPlaylistRows;

type
  TTestRowCopies = class(TTestCase)
  published
    procedure TrackEntryTrackKeepsEveryField;
  end;

  TTestRowRules = class(TTestCase)
  published
    procedure CleanTagPutsATagOnOneLine;
    procedure TimeStrToSecsReadsMinutesAndHours;
    procedure GroupDurationInMinutesOrHours;
    procedure GroupKeyByFolderOrAlbum;
    procedure AWorkIsNamedInFrontOfTheColon;
    procedure WorksAreTracksInARowWithOneWork;
    procedure DeadRowsOnlyOnDrivesThatAnswer;
  end;

  TTestRatings = class(TTestCase)
  published
    procedure RatingTagsFallBackToArtistAndUnknown;
    procedure RowFingerprintUsesThePlayStatistics;
    procedure AverageIsRounded;
    procedure StarUnderTheClick;
    procedure SameStarAgainClears;
  end;

  TTestHeaderText = class(TTestCase)
  private
    // 10 px per character (not per byte)
    function CharWidth(const S: string): Integer;
  published
    procedure FittingTextIsUnchanged;
    procedure TooLongTextGetsAnEllipsis;
    procedure SplitAtTheLastBulletWhereBothHalvesFit;
    procedure SplitAtABulletAndShortenTheSecondLine;
    procedure SplitAPathAfterABackslash;
    procedure OneLongWordStaysOnOneLine;
  end;

implementation

uses
  uAppStrings, uUserStatsManager, TestHelpers;

const
  // Typed (UTF-8 string): see TestLibraryDatabase
  HDR_THREE: string = 'Artist • Album • 2001';
  HDR_LONG2: string = 'Artist • A very long album name here';

function SampleTrack: TTrackInfo;
begin
  Result             := Default(TTrackInfo);
  Result.FilePath    := 'D:\Music\Miles Davis\Kind of Blue\01 - So What.flac';
  Result.FolderDir   := 'D:\Music\Miles Davis\Kind of Blue';
  Result.Title       := 'So What';
  Result.Artist      := 'Miles Davis';
  Result.AlbumArtist := 'Miles Davis Sextet';
  Result.Album       := 'Kind of Blue';
  Result.Genre       := 'Jazz';
  Result.TrackNumber := 1;
  Result.DiscNumber  := 2;
  Result.DurationStr := '9:22';
  Result.Year        := 1959;
  Result.DateStr     := '1959-08-17';
  Result.SampleRate  := 96000;
  Result.BitDepth    := 24;
end;

{ TTestRowCopies }

procedure TTestRowCopies.TrackEntryTrackKeepsEveryField;
var
  T, Back: TTrackInfo;
  E: TPlaylistEntry;
begin
  T := SampleTrack;
  E := EntryFromTrack(T);
  AssertTrue('Genre stored', E.HasGenre);
  AssertTrue('Extended info stored', E.HasExtendedInfo);

  Back := TrackFromEntry(E);
  AssertEquals('Path', T.FilePath, Back.FilePath);
  AssertEquals('Folder', T.FolderDir, Back.FolderDir);
  AssertEquals('Title', T.Title, Back.Title);
  AssertEquals('Artist', T.Artist, Back.Artist);
  AssertEquals('Album artist', T.AlbumArtist, Back.AlbumArtist);
  AssertEquals('Album', T.Album, Back.Album);
  AssertEquals('Genre', T.Genre, Back.Genre);
  AssertEquals('Track number', T.TrackNumber, Back.TrackNumber);
  AssertEquals('Disc number', T.DiscNumber, Back.DiscNumber);
  AssertEquals('Length', T.DurationStr, Back.DurationStr);
  AssertEquals('Year', T.Year, Back.Year);
  AssertEquals('Date', T.DateStr, Back.DateStr);
  AssertEquals('Sample rate', T.SampleRate, Back.SampleRate);
  AssertEquals('Bit depth', T.BitDepth, Back.BitDepth);
end;

{ TTestRowRules }

procedure TTestRowRules.CleanTagPutsATagOnOneLine;
begin
  AssertEquals('Empty', '', CleanTag(''));
  AssertEquals('Trimmed', 'x', CleanTag('  x  '));
  AssertEquals('LF', 'a b', CleanTag('a'#10'b'));
  AssertEquals('CR LF', 'a b', CleanTag('a'#13#10'b'));
  AssertEquals('CR', 'a b', CleanTag('a'#13'b'));
end;

procedure TTestRowRules.TimeStrToSecsReadsMinutesAndHours;
begin
  AssertEquals('m:ss', 252, TimeStrToSecs('4:12'));
  AssertEquals('h:mm:ss', 3723, TimeStrToSecs('1:02:03'));
  AssertEquals('Empty', 0, TimeStrToSecs(''));
  AssertEquals('No colon', 0, TimeStrToSecs('abc'));
  AssertEquals('Bad seconds count as 0', 600, TimeStrToSecs('10:xx'));
end;

procedure TTestRowRules.GroupDurationInMinutesOrHours;
begin
  AssertEquals('Minutes', Format(FMT_DURATION_MS, [42, 7]), FormatGroupDuration(42 * 60 + 7));
  AssertEquals('Just under an hour', Format(FMT_DURATION_MS, [59, 59]), FormatGroupDuration(3599));
  AssertEquals('Hours', Format(FMT_DURATION_HM, [1, 5]), FormatGroupDuration(3900));
  AssertEquals('Nothing', Format(FMT_DURATION_MS, [0, 0]), FormatGroupDuration(0));
end;

procedure TTestRowRules.AWorkIsNamedInFrontOfTheColon;
var
  W, P: string;
begin
  AssertTrue('Work and part', SplitWorkTitle('Symphony No. 5 in C minor, Op. 67: I. Allegro con brio', W, P));
  AssertEquals('Symphony No. 5 in C minor, Op. 67', W);
  AssertEquals('I. Allegro con brio', P);
  AssertTrue('The first colon counts', SplitWorkTitle('Act 1: Scene 2: Aria', W, P));
  AssertEquals('Act 1', W);
  AssertEquals('Scene 2: Aria', P);
  AssertFalse('No colon', SplitWorkTitle('So What', W, P));
  AssertEquals('Nothing given back', '', W + P);
  AssertFalse('A colon without a space is a time or a ratio', SplitWorkTitle('Take 5:30', W, P));
  AssertFalse('Nothing behind it', SplitWorkTitle('Symphony No. 5: ', W, P));
  AssertFalse('Too short to be a work', SplitWorkTitle('II: Adagio', W, P));
  AssertFalse('An empty title', SplitWorkTitle('', W, P));
end;

{ which tracks of a group get a work heading, and what is left of their
  titles under it }
procedure TTestRowRules.WorksAreTracksInARowWithOneWork;
var
  R: TWorkRows;

  procedure Add(const ATitle, AWork: string; ADisc: Integer = 1);
  begin
    SetLength(R, Length(R) + 1);
    R[High(R)] := Default(TWorkRow);
    R[High(R)].Title := ATitle;
    R[High(R)].Work := AWork;
    R[High(R)].Disc := ADisc;
  end;

begin
  R := nil;
  FindWorks(R);                                          // nothing: no error

  { the work from the titles }
  Add('Symphony No. 5: I. Allegro', '');
  Add('Symphony No. 5: II. Andante', '');
  Add('symphony no. 5: III. Scherzo', '');               // the case may differ
  Add('Overture', '');                                   // a piece of one track
  Add('Symphony No. 7: I. Poco sostenuto', '');
  Add('Symphony No. 7: II. Allegretto', '');
  FindWorks(R);
  AssertEquals('The first work', 'Symphony No. 5', R[0].Heading);
  AssertEquals('Its part', 'I. Allegro', R[0].Part);
  AssertEquals('No heading inside it', '', R[1].Heading);
  AssertEquals('II. Andante', R[1].Part);
  AssertEquals('III. Scherzo', R[2].Part);
  AssertEquals('A single piece has no heading', '', R[3].Heading);
  AssertEquals('And its whole title', '', R[3].Part);
  AssertEquals('The second work', 'Symphony No. 7', R[4].Heading);
  AssertEquals('II. Allegretto', R[5].Part);

  { the work from the tag: also where the titles do not name it; the titles
    stay whole unless they all name the same work in front of the colon }
  R := nil;
  Add('Allegro', 'Sonata in A');
  Add('Adagio', 'Sonata in A');
  Add('Sonate Nr. 2: I. Allegro', 'Sonata no. 2');
  Add('Sonate Nr. 2: II. Largo', 'Sonata no. 2');
  Add('Prelude: Lento', 'A Single Piece');
  FindWorks(R);
  AssertEquals('From the tag', 'Sonata in A', R[0].Heading);
  AssertEquals('The plain title stays', '', R[0].Part);
  AssertEquals('The tag''s name, not the title''s', 'Sonata no. 2', R[2].Heading);
  AssertEquals('The part where the titles agree', 'I. Allegro', R[2].Part);
  AssertEquals('II. Largo', R[3].Part);
  AssertEquals('One track with a work: no heading', '', R[4].Heading);
  AssertEquals('And its whole title', '', R[4].Part);

  { a work does not run over to another disc, and two titles that only look
    alike are no work }
  R := nil;
  Add('Suite: I', '', 1);
  Add('Suite: II', '', 2);
  Add('Live: One', '', 2);
  Add('Other: Two', '', 2);
  FindWorks(R);
  AssertEquals('Not across the discs', '', R[0].Heading + R[1].Heading);
  AssertEquals('Different texts in front of the colon', '', R[2].Heading + R[3].Heading);
end;

procedure TTestRowRules.GroupKeyByFolderOrAlbum;
var
  T: TTrackInfo;
begin
  T := SampleTrack;
  AssertEquals('Folder', T.FolderDir, PlaylistGroupKey(T, gmFolder));
  AssertEquals('Album', T.FolderDir + '|Miles Davis Sextet|Kind of Blue', PlaylistGroupKey(T, gmAlbum));
  AssertEquals('Flat list', '', PlaylistGroupKey(T, gmFlat));
end;

var
  // The files RowFileState asked about (a fake FileExists: only '...\here.flac' exists)
  AskedFiles: string = '';

function FakeFileExists(const APath: string): Boolean;
begin
  AskedFiles := AskedFiles + ExtractFileName(APath) + ';';
  Result := SameText(ExtractFileName(APath), 'here.flac');
end;

// Remove dead items (TMainForm.MnRemoveDead): only a file that is gone from
// a drive that answers is dead; files on drives that cannot be reached are
// kept and never checked
procedure TTestRowRules.DeadRowsOnlyOnDrivesThatAnswer;
var
  Offline: TStringList;
begin
  Offline := TStringList.Create;
  try
    Offline.Add('E:');
    Offline.Add('\\NAS\Music');
    AskedFiles := '';

    AssertTrue('Present', RowFileState('D:\M\here.flac', Offline, @FakeFileExists) = rfsPresent);
    AssertTrue('Missing on a drive that answers: dead',
      RowFileState('D:\M\gone.flac', Offline, @FakeFileExists) = rfsMissing);
    AssertTrue('Drive not connected: kept',
      RowFileState('E:\M\a.flac', Offline, @FakeFileExists) = rfsDriveOffline);
    AssertTrue('Drive letter in any case', RowFileState('e:\M\b.flac', Offline, @FakeFileExists) = rfsDriveOffline);
    AssertTrue('Network share that is down: kept (any case)',
      RowFileState('\\nas\music\Album\c.flac', Offline, @FakeFileExists) = rfsDriveOffline);
    AssertTrue('Another share on the same NAS answers',
      RowFileState('\\NAS\Other\d.flac', Offline, @FakeFileExists) = rfsMissing);
    AssertEquals('Files on offline drives are never checked (that could hang)',
      'here.flac;gone.flac;d.flac;', AskedFiles);

    AssertTrue('No offline list: missing is dead',
      RowFileState('E:\M\a.flac', nil, @FakeFileExists) = rfsMissing);

    AssertTrue('On an offline drive', IsOnOfflineDrive('E:\M\a.flac', Offline));
    AssertFalse('On a drive that answers', IsOnOfflineDrive('D:\M\a.flac', Offline));
    AssertFalse('Relative path: no drive', IsOnOfflineDrive('M\a.flac', Offline));
    AssertFalse('No offline list', IsOnOfflineDrive('E:\M\a.flac', nil));
  finally
    Offline.Free;
  end;
end;

{ TTestRatings }

procedure TTestRatings.RatingTagsFallBackToArtistAndUnknown;
var
  Row: TTrackNodeData;
  Artist, Album: string;
begin
  Row := Default(TTrackNodeData);
  Row.AlbumArtist := 'AA';
  Row.Artist      := 'A';
  Row.Album       := 'B';
  RatingTags(Row, Artist, Album);
  AssertEquals('Album artist first', 'AA', Artist);
  AssertEquals('Album', 'B', Album);

  Row.AlbumArtist := '';
  RatingTags(Row, Artist, Album);
  AssertEquals('Else the artist', 'A', Artist);

  Row.Artist := '';
  Row.Album  := '';
  RatingTags(Row, Artist, Album);
  AssertEquals('Else Unknown Artist', LBL_UNKNOWN_ARTIST, Artist);
  AssertEquals('Else Unknown Album', LBL_UNKNOWN_ALBUM, Album);
end;

procedure TTestRatings.RowFingerprintUsesThePlayStatistics;
var
  Row: TTrackNodeData;
  Dir: string;
  Stats: TUserStatsManager;
begin
  Row := Default(TTrackNodeData);
  Row.Artist := 'Miles Davis';
  Row.Album  := '';
  Row.Title  := 'So What';

  AssertNull('No play statistics in the test program', UserStatsManager);
  AssertEquals('Without play statistics', '', RowRatingFingerprint(Row));

  Dir   := CreateTestDir;
  Stats := TUserStatsManager.Create(Dir + 'UserStats.db');
  UserStatsManager := Stats;
  try
    AssertEquals('Artist (no album artist) and Unknown Album',
      Stats.GenerateFingerprint('Miles Davis', LBL_UNKNOWN_ALBUM, 'So What'),
      RowRatingFingerprint(Row));
  finally
    UserStatsManager := nil;
    Stats.Free;
    RemoveTestDir(Dir);
  end;
end;

procedure TTestRatings.AverageIsRounded;
begin
  AssertEquals('No tracks', 0, AverageRating(0, 0));
  AssertEquals('One track', 5, AverageRating(5, 1));
  AssertEquals('10 / 3', 3, AverageRating(10, 3));
  AssertEquals('Halves as Round does', Round(9 / 2), AverageRating(9, 2));
end;

procedure TTestRatings.StarUnderTheClick;
begin
  // 5 stars of 10 px from x = 20
  AssertEquals('Left of the stars', 0, StarAtOffset(19, 20, 10));
  AssertEquals('First star, left edge', 1, StarAtOffset(20, 20, 10));
  AssertEquals('First star, right edge', 1, StarAtOffset(29, 20, 10));
  AssertEquals('Second star', 2, StarAtOffset(30, 20, 10));
  AssertEquals('Fifth star', 5, StarAtOffset(69, 20, 10));
  AssertEquals('Right edge of the stars', 5, StarAtOffset(70, 20, 10));
  AssertEquals('Right of the stars', 0, StarAtOffset(71, 20, 10));
  AssertEquals('No star width', 0, StarAtOffset(25, 20, 0));
end;

procedure TTestRatings.SameStarAgainClears;
begin
  AssertEquals('Same as now: cleared', 0, NextRating(3, 3));
  AssertEquals('Other star', 3, NextRating(3, 2));
  AssertEquals('From none', 1, NextRating(1, 0));
end;

{ TTestHeaderText }

function TTestHeaderText.CharWidth(const S: string): Integer;
begin
  Result := Length(UTF8Decode(S)) * 10;
end;

procedure TTestHeaderText.FittingTextIsUnchanged;
begin
  AssertEquals('Fits', 'Hello', FitTextWithEllipsis('Hello', 50, @CharWidth));
  AssertEquals('Empty', '', FitTextWithEllipsis('', 50, @CharWidth));
  AssertEquals('No width given', 'Hello World', FitTextWithEllipsis('Hello World', 0, @CharWidth));
end;

procedure TTestHeaderText.TooLongTextGetsAnEllipsis;
begin
  AssertEquals('Cut to fit with ...', 'Hello...', FitTextWithEllipsis('Hello World', 80, @CharWidth));
  AssertEquals('No space before ...', 'Hello...', FitTextWithEllipsis('Hello World', 90, @CharWidth));
end;

procedure TTestHeaderText.SplitAtTheLastBulletWhereBothHalvesFit;
var
  L1, L2: string;
begin
  // 'Artist • Album' is 14 characters, 'Album • 2001' 12
  SplitHeaderIntoTwoLines(HDR_THREE, 140, @CharWidth, L1, L2);
  AssertEquals('Both bullets fit: the last one, line 1', 'Artist • Album', L1);
  AssertEquals('...line 2', '2001', L2);

  SplitHeaderIntoTwoLines(HDR_THREE, 120, @CharWidth, L1, L2);
  AssertEquals('Only the first bullet fits, line 1', 'Artist', L1);
  AssertEquals('...line 2', 'Album • 2001', L2);
end;

procedure TTestHeaderText.SplitAtABulletAndShortenTheSecondLine;
var
  L1, L2: string;
begin
  SplitHeaderIntoTwoLines(HDR_LONG2, 100, @CharWidth, L1, L2);
  AssertEquals('Line 1', 'Artist', L1);
  AssertEquals('Line 2 shortened', 'A very...', L2);
end;

procedure TTestHeaderText.SplitAPathAfterABackslash;
var
  L1, L2: string;
begin
  SplitHeaderIntoTwoLines('D:\Music\Long Folder\Sub', 100, @CharWidth, L1, L2);
  AssertEquals('Line 1 ends with the backslash', 'D:\Music\', L1);
  AssertEquals('Line 2 shortened', 'Long Fo...', L2);
end;

procedure TTestHeaderText.OneLongWordStaysOnOneLine;
var
  L1, L2: string;
begin
  SplitHeaderIntoTwoLines('Supercalifragilistic', 80, @CharWidth, L1, L2);
  AssertEquals('Shortened', 'Super...', L1);
  AssertEquals('No second line', '', L2);

  SplitHeaderIntoTwoLines('', 80, @CharWidth, L1, L2);
  AssertEquals('Empty: line 1', '', L1);
  AssertEquals('Empty: line 2', '', L2);
end;

initialization
  RegisterTest(TTestRowCopies);
  RegisterTest(TTestRowRules);
  RegisterTest(TTestRatings);
  RegisterTest(TTestHeaderText);

end.
