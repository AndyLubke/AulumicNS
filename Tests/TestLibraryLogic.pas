unit TestLibraryLogic;

{$mode ObjFPC}{$H+}
{$codepage UTF8}

{ ==============================================================================
  AulumicNS tests - TestLibraryLogic
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for the library's pure logic (no files, no threads):
    TTestTrackSorting : NaturalCompareText, SmartTrackCompare and the
                        SortTracks_By... list sorts (library / playlist order);
                        ---> ADDED: names sort as in the library pane
                        (accents, Japanese, punctuation), SortTracksFast gives
                        the exact order, TTrackList.Sort takes the fast path;
                        the library order (CompareTrackInfo) is language- and
                        number-aware
    TTestTrackQuery   : the auto-playlist filter (ParseQuery + EvaluateTrack)
    TTestDatabaseLines: the Library.db field encoding and track line format
                        (uLibraryDatabase)
    TTestTagReaders   : ALMetadata links a real AulumicTag reader for every
                        format AulumicNS plays (FILE_VALID_EXTS); without
                        one, files silently read as untagged
    TTestTrackList    : TTrackList stores and disposes copies (heaptrc must
                        report no leak)
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uTagParser, uLibraryTypes, uLibraryQuery,
  uLibraryDatabase;

type
  TTestTrackSorting = class(TTestCase)
  published
    procedure NaturalCompareSortsNumbersByValue;
    procedure NaturalCompareIgnoresCase;
    procedure NaturalCompareHandlesHugeNumbers;
    procedure SmartCompareOrdersByDiscFirst;
    procedure SmartCompareUsesFileNamesThatStartWithDigits;
    procedure SmartCompareUsesTrackNumbersOtherwise;
    procedure SortByAlbumGroupsAlbumsThenTracks;
    procedure SortByFolderKeepsTrackOrderInsideFolders;
    procedure SortsNamesLikeTheLibraryPane;
    procedure FastSortGivesTheSameOrder;
    procedure TrackListSortTakesTheFastPath;
    procedure LibraryOrderIsLanguageAndNumberAware;
  end;

  TTestTrackQuery = class(TTestCase)
  private
    FTrack: TTrackInfo;
    function Matches(const AQuery: string): Boolean;
  protected
    procedure SetUp; override;
  published
    procedure EmptyQueryMatchesEverything;
    procedure HasFindsPartOfAWord;
    procedure HasIgnoresCaseAndAccents;
    procedure IsNeedsTheWholeValue;
    procedure OrMatchesAnyAlternative;
    procedure NotHasExcludes;
    procedure StartsWithChecksTheBeginning;
    procedure NumberComparisons;
    procedure AllConditionsMustMatch;
    procedure CodecAndResolution;
    procedure UnknownTagsAreIgnored;
  end;

  TTestDatabaseLines = class(TTestCase)
  published
    procedure EncodeDecodeRoundTrip;
    procedure EncodedFieldsHaveNoTabsOrLineBreaks;
    procedure SingleLineBreakCharactersBecomeCRLF;
    procedure ControlCharactersAreDropped;
    procedure FormatAndParseKeepEveryField;
    procedure ParseReadsOldSevenFieldLines;
    procedure ParseConvertsOldDateAdded;
    procedure ParseTakesTheFolderFromThePathWhenEmpty;
    procedure ParseRejectsShortLines;
  end;

  TTestTagReaders = class(TTestCase)
  published
    procedure EveryAulumicFormatHasARealReader;
    procedure WavFileIsReadWithItsFormat;
    // ---> AulumicNS: the new DFF reader (file_dff)
    procedure DffFileIsReadWithItsFormat;
  end;

  // ---> ADDED (phase 4): the list that owns copies of track records
  TTestTrackList = class(TTestCase)
  published
    procedure AddStoresACopy;
    procedure AddListCopiesEveryTrack;
    procedure AddListOfItselfDoesNothing;
    procedure SortOrdersTheCopies;
    procedure ListViewSeesTheSameItems;
    procedure ClearEmptiesTheList;
  end;

// A library record with the cached search fields filled in as the library
// does (Clean* = lower case without accents, FileNameOnly)
function MakeTrack(const APath, ATitle, AArtist, AAlbum: string;
  ATrackNr: Integer = 0; ADiscNr: Integer = 0): TTrackInfo;

implementation

uses
  DateUtils, uMetaUtils, uAppConsts,
  // Deliberately not RegisterAllReader: ALMetadata must link the readers itself
  AudioTag, file_Dummy, ALMetadata, TestHelpers;

function MakeTrack(const APath, ATitle, AArtist, AAlbum: string;
  ATrackNr: Integer; ADiscNr: Integer): TTrackInfo;
begin
  Result              := Default(TTrackInfo);
  Result.FilePath     := APath;
  Result.FolderDir    := ExcludeTrailingPathDelimiter(ExtractFileDir(APath));
  Result.FileNameOnly := ExtractFileName(APath);
  Result.Title        := ATitle;
  Result.Artist       := AArtist;
  Result.AlbumArtist  := AArtist;
  Result.Album        := AAlbum;
  Result.TrackNumber  := ATrackNr;
  Result.DiscNumber   := ADiscNr;

  Result.CleanTitle       := LowerCase(StripAccents(Result.Title));
  Result.CleanArtist      := LowerCase(StripAccents(Result.Artist));
  Result.CleanAlbumArtist := LowerCase(StripAccents(Result.AlbumArtist));
  Result.CleanAlbum       := LowerCase(StripAccents(Result.Album));
  Result.CleanFolder      := LowerCase(StripAccents(Result.FolderDir));
end;

// Sorts copies of ATracks with ACompare and returns the titles in order
function SortedTitles(const ATracks: array of TTrackInfo; ACompare: TListSortCompare): string;
var
  List : TList;
  I    : Integer;
  Recs : TTrackInfoArray;
begin
  SetLength(Recs, Length(ATracks));
  for I := 0 to High(ATracks) do
    Recs[I] := ATracks[I];

  List := TList.Create;
  try
    for I := 0 to High(Recs) do
      List.Add(@Recs[I]);
    List.Sort(ACompare);
    Result := '';
    for I := 0 to List.Count - 1 do
    begin
      if I > 0 then
        Result := Result + ',';
      Result := Result + PTrackInfo(List[I])^.Title;
    end;
  finally
    List.Free;
  end;
end;

{ TTestTrackSorting }

procedure TTestTrackSorting.NaturalCompareSortsNumbersByValue;
begin
  AssertTrue('2 before 10', NaturalCompareText('Track 2', 'Track 10') < 0);
  AssertTrue('10 after 9', NaturalCompareText('Track 10', 'Track 9') > 0);
  AssertTrue('01 = 1 as a number, shorter first', NaturalCompareText('01', '1') > 0);
  AssertEquals('Equal', 0, NaturalCompareText('Disc 1 Track 3', 'Disc 1 Track 3'));
  AssertTrue('Text before the number decides', NaturalCompareText('A 10', 'B 2') < 0);
  AssertTrue('Shorter string first when equal so far', NaturalCompareText('Track', 'Track 1') < 0);
end;

procedure TTestTrackSorting.NaturalCompareIgnoresCase;
begin
  AssertEquals('Case', 0, NaturalCompareText('so what', 'SO WHAT'));
  AssertTrue('Letters', NaturalCompareText('apple', 'Banana') < 0);
end;

procedure TTestTrackSorting.NaturalCompareHandlesHugeNumbers;
begin
  // More digits than an Int64 holds: must not overflow (range checks are on)
  AssertTrue('Huge numbers compare without an error',
    NaturalCompareText('99999999999999999999999 a', '99999999999999999999999 b') < 0);
end;

procedure TTestTrackSorting.SmartCompareOrdersByDiscFirst;
var
  A, B: TTrackInfo;
begin
  A := MakeTrack('D:\M\Album\01.flac', 'Disc 2 opener', 'X', 'Album', 1, 2);
  B := MakeTrack('D:\M\Album\09.flac', 'Disc 1 closer', 'X', 'Album', 9, 1);
  AssertTrue('Disc 1 before disc 2', SmartTrackCompare(@B, @A) < 0);
  AssertTrue('Disc 2 after disc 1', SmartTrackCompare(@A, @B) > 0);
end;

procedure TTestTrackSorting.SmartCompareUsesFileNamesThatStartWithDigits;
var
  A, B: TTrackInfo;
begin
  // File names win over (possibly wrong) track number tags
  A := MakeTrack('D:\M\Album\2 - Second.flac', 'Second', 'X', 'Album', 10);
  B := MakeTrack('D:\M\Album\10 - Tenth.flac', 'Tenth', 'X', 'Album', 2);
  AssertTrue('2 before 10 by file name', SmartTrackCompare(@A, @B) < 0);
end;

procedure TTestTrackSorting.SmartCompareUsesTrackNumbersOtherwise;
var
  A, B: TTrackInfo;
begin
  A := MakeTrack('D:\M\Album\Zebra.flac', 'Zebra', 'X', 'Album', 1);
  B := MakeTrack('D:\M\Album\Apple.flac', 'Apple', 'X', 'Album', 2);
  AssertTrue('Track 1 before track 2', SmartTrackCompare(@A, @B) < 0);
end;

procedure TTestTrackSorting.SortByAlbumGroupsAlbumsThenTracks;
begin
  AssertEquals('Album order, then track order',
    'A1,A2,A10,B1,B2',
    SortedTitles([
      MakeTrack('D:\M\Beta\01 - b1.flac',  'B1',  'Y', 'Beta', 1),
      MakeTrack('D:\M\Alpha\10 - a10.flac', 'A10', 'X', 'Alpha', 10),
      MakeTrack('D:\M\Beta\02 - b2.flac',  'B2',  'Y', 'Beta', 2),
      MakeTrack('D:\M\Alpha\01 - a1.flac', 'A1',  'X', 'Alpha', 1),
      MakeTrack('D:\M\Alpha\02 - a2.flac', 'A2',  'X', 'Alpha', 2)
    ], @SortTracks_ByAlbum));
end;

procedure TTestTrackSorting.SortByFolderKeepsTrackOrderInsideFolders;
begin
  AssertEquals('Folder order, then track order',
    'F1-1,F1-2,F2-1',
    SortedTitles([
      MakeTrack('D:\M\Folder2\01.flac', 'F2-1', 'X', 'Same', 1),
      MakeTrack('D:\M\Folder1\02.flac', 'F1-2', 'X', 'Same', 2),
      MakeTrack('D:\M\Folder1\01.flac', 'F1-1', 'X', 'Same', 1)
    ], @SortTracks_ByFolder));
end;

// ---> ADDED: Names with accents, a Japanese name, punctuation and digits,
// each different from the others also when the case is ignored
const
  PANE_NAMES: array[0..21] of string = ('Zappa', 'Bach', 'Elvis', 'Édith', 'Ánimals',
    'Ólafur', 'Oasis', 'Ñandú', 'Nirvana', '坂本龍一', 'Abba', 'Ünal', 'Ultravox',
    'AC/DC', 'a-ha', 'Guns N'' Roses', 'Gunsmith', 'Björk', 'Bowie', 'Øystein',
    '2Pac', '10cc');

// The names in the order the library pane shows them: its lists are
// TStringLists with CaseSensitive = False and UseLocale = True
function PaneOrder(const AFolderPrefix: string): string;
var
  SL: TStringList;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    for I := 0 to High(PANE_NAMES) do
      SL.Add(AFolderPrefix + PANE_NAMES[I]);
    SL.Sort;
    Result := '';
    for I := 0 to SL.Count - 1 do
    begin
      if I > 0 then
        Result := Result + ',';
      Result := Result + SL[I];
    end;
  finally
    SL.Free;
  end;
end;

// One track per name: as album artist (AOrder = tsoArtist), album (tsoAlbum)
// or folder (tsoFolder); the title is the name (or its folder) so the sorted
// titles can be compared with PaneOrder
function PaneTracks(AOrder: TTrackSortOrder): TTrackInfoArray;
var
  I: Integer;
  N: string;
begin
  Result := nil;
  SetLength(Result, Length(PANE_NAMES));
  for I := 0 to High(PANE_NAMES) do
  begin
    N := PANE_NAMES[I];
    case AOrder of
      tsoArtist: Result[I] := MakeTrack('D:\M\Same\' + IntToStr(I) + '.flac', N, N, 'Same', 1);
      tsoAlbum:  Result[I] := MakeTrack('D:\M\Same\' + IntToStr(I) + '.flac', N, 'Same', N, 1);
    else
      Result[I] := MakeTrack('D:\M\' + N + '\01.flac', 'D:\M\' + N, 'Same', 'Same', 1);
    end;
  end;
end;

// The titles of ATracks after TTrackList.Sort (the fast path)
function TrackListTitles(const ATracks: TTrackInfoArray; ACompare: TListSortCompare): string;
var
  TL: TTrackList;
  I: Integer;
begin
  TL := TTrackList.Create;
  try
    for I := 0 to High(ATracks) do
      TL.Add(ATracks[I]);
    TL.Sort(ACompare);
    Result := '';
    for I := 0 to TL.Count - 1 do
    begin
      if I > 0 then
        Result := Result + ',';
      Result := Result + TL[I]^.Title;
    end;
  finally
    TL.Free;
  end;
end;

procedure TTestTrackSorting.SortsNamesLikeTheLibraryPane;
const
  // The orders of library adds to a playlist (the library order, tsoLibrary,
  // is number-aware and has its own test)
  SORTS: array[tsoArtist..tsoFolder] of TListSortCompare =
    (@SortTracks_ByArtist, @SortTracks_ByAlbum, @SortTracks_ByFolder);
  WHAT: array[tsoArtist..tsoFolder] of string = ('album artists', 'albums', 'folders');
var
  O: TTrackSortOrder;
  Prefix: string;
begin
  for O := tsoArtist to tsoFolder do
  begin
    if O = tsoFolder then
      Prefix := 'D:\M\'
    else
      Prefix := '';
    AssertEquals('The compare function: ' + WHAT[O] + ' in the pane''s order',
      PaneOrder(Prefix), SortedTitles(PaneTracks(O), SORTS[O]));
    AssertEquals('TTrackList.Sort: ' + WHAT[O] + ' in the pane''s order',
      PaneOrder(Prefix), TrackListTitles(PaneTracks(O), SORTS[O]));
  end;

  // In every language Windows offers: an accented letter sorts with its
  // letter, never after Z (CompareText put it there)
  AssertTrue('Édith before Zappa', CompareLibraryNames('Édith', 'Zappa') < 0);
  AssertTrue('Ánimals before Bach', CompareLibraryNames('Ánimals', 'Bach') < 0);
  AssertEquals('Case is ignored, also for accented letters', 0,
    CompareLibraryNames('ÉDITH PIAF', 'édith piaf'));
end;

// ---> ADDED: Many tracks of a pool of names (with case variants), several per
// folder; every file name is different, so the order is strict
function ManyTracks(ACount: Integer): TTrackInfoArray;
const
  ARTISTS: array[0..11] of string = ('Édith', 'ÉDITH', 'Elvis', 'Zappa', 'a-ha',
    'AC/DC', 'Björk', 'Bowie', '坂本龍一', 'Guns N'' Roses', 'the beatles', 'The Beatles');
  ALBUMS: array[0..6] of string = ('Ágætis byrjun', 'Takk...', 'Élan', 'élan',
    '(What''s the Story)', 'Album 2', 'Album 10');
var
  I: Integer;
  Artist, Album: string;
begin
  Result := nil;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
  begin
    Artist := ARTISTS[(I div 3) mod Length(ARTISTS)];
    Album  := ALBUMS[(I div 7) mod Length(ALBUMS)];
    Result[I] := MakeTrack(Format('D:\M\%s\%s %d\%.2d - %d.flac',
      [Artist, Album, (I div 11) mod 5, I mod 9 + 1, I]), IntToStr(I), Artist, Album, I mod 9 + 1);
  end;
end;

// Pointers to ATracks in a shuffled order (the same every run)
function ShuffledPointers(var ATracks: TTrackInfoArray): TList;
var
  I, J: Integer;
  Seed: Cardinal;
  P: Pointer;
begin
  Result := TList.Create;
  for I := 0 to High(ATracks) do
    Result.Add(@ATracks[I]);
  Seed := 12345;
  for I := Result.Count - 1 downto 1 do
  begin
    Seed := Cardinal((Int64(Seed) * 1103515245 + 12345) and $FFFFFFFF);
    J := (Seed shr 8) mod Cardinal(I + 1);
    P := Result[I]; Result[I] := Result[J]; Result[J] := P;
  end;
end;

procedure TTestTrackSorting.FastSortGivesTheSameOrder;
const
  SORTS: array[TTrackSortOrder] of TListSortCompare =
    (@SortTracks_ByArtist, @SortTracks_ByAlbum, @SortTracks_ByFolder, @CompareTrackInfo);
var
  Tracks: TTrackInfoArray;
  Exact, Fast: TList;
  O: TTrackSortOrder;
  I: Integer;
begin
  Tracks := ManyTracks(3000);
  for O := Low(TTrackSortOrder) to High(TTrackSortOrder) do
  begin
    Exact := ShuffledPointers(Tracks);
    Fast  := TList.Create;
    try
      Fast.Assign(Exact);
      Exact.Sort(SORTS[O]);
      SortTracksFast(Fast, O);
      for I := 0 to Exact.Count - 1 do
        if Exact[I] <> Fast[I] then
          Fail(Format('Order %d: position %d is track %s, the exact sort has %s',
            [Ord(O), I, PTrackInfo(Fast[I])^.Title, PTrackInfo(Exact[I])^.Title]));
    finally
      Fast.Free;
      Exact.Free;
    end;
  end;

  // Nothing to do for an empty list or a single track
  Fast := TList.Create;
  try
    SortTracksFast(Fast, tsoArtist);
    AssertEquals('Empty', 0, Fast.Count);
    Fast.Add(@Tracks[0]);
    SortTracksFast(Fast, tsoArtist);
    AssertTrue('One track', Fast[0] = @Tracks[0]);
  finally
    Fast.Free;
  end;
end;

// ---> ADDED: TTrackList.Sort takes the fast path for the library orders:
// a Windows comparison per step is several times slower (about 6x measured)
procedure TTestTrackSorting.TrackListSortTakesTheFastPath;
const
  // ---> ADDED: also the library order (CompareTrackInfo)
  SORTS: array[0..1] of TListSortCompare = (@SortTracks_ByArtist, @CompareTrackInfo);
  WHAT: array[0..1] of string = ('by artist', 'library order');
var
  Tracks: TTrackInfoArray;
  Exact: TList;
  TL: TTrackList;
  I, S: Integer;
  Start, ExactMs, ListMs: QWord;
begin
  Tracks := ManyTracks(20000);

  for S := 0 to High(SORTS) do
  begin
    Exact := ShuffledPointers(Tracks);
    try
      Start := GetTickCount64;
      Exact.Sort(SORTS[S]);
      ExactMs := GetTickCount64 - Start;
    finally
      Exact.Free;
    end;

    TL := TTrackList.Create;
    try
      Exact := ShuffledPointers(Tracks);
      try
        for I := 0 to Exact.Count - 1 do
          TL.Add(PTrackInfo(Exact[I])^);
      finally
        Exact.Free;
      end;
      Start := GetTickCount64;
      TL.Sort(SORTS[S]);
      ListMs := GetTickCount64 - Start;
    finally
      TL.Free;
    end;

    AssertTrue(Format('%s: TTrackList.Sort %d ms, the exact compare function %d ms',
      [WHAT[S], ListMs, ExactMs]), 3 * ListMs < ExactMs);
  end;
end;

// ---> ADDED: The library order (CompareTrackInfo: auto-playlists): accented
// names with their letter, numbers by value, case ignored; the compare
// function and TTrackList.Sort (the fast path) alike
procedure TTestTrackSorting.LibraryOrderIsLanguageAndNumberAware;
const
  FOLDERS: array[0..6] of string = ('Zappa', 'Édith Piaf', 'Bach', 'CD10', 'CD2', 'cd3', 'Ánimals');
  EXPECTED = 'Ánimals,Bach,CD2,cd3,CD10,Édith Piaf,Zappa';
var
  Tracks: TTrackInfoArray;
  I: Integer;
begin
  Tracks := nil;
  SetLength(Tracks, Length(FOLDERS));
  for I := 0 to High(FOLDERS) do
    Tracks[I] := MakeTrack('D:\M\' + FOLDERS[I] + '\01.flac', FOLDERS[I], 'Same', 'Same', 1);

  AssertEquals('CompareTrackInfo', EXPECTED, SortedTitles(Tracks, @CompareTrackInfo));
  AssertEquals('TTrackList.Sort', EXPECTED, TrackListTitles(Tracks, @CompareTrackInfo));

  AssertTrue('Vol. 2 before Vol. 10', CompareLibraryNamesNatural('Vol. 2', 'Vol. 10') < 0);
  AssertTrue('Édith before Zappa', CompareLibraryNamesNatural('Édith', 'Zappa') < 0);
  AssertEquals('Case is ignored', 0, CompareLibraryNamesNatural('ÉDITH PIAF', 'édith piaf'));
  AssertTrue('An empty name first', CompareLibraryNamesNatural('', 'A') < 0);
  AssertTrue('...from both sides', CompareLibraryNamesNatural('A', '') > 0);
end;

{ TTestTrackQuery }

procedure TTestTrackQuery.SetUp;
begin
  FTrack            := MakeTrack('D:\Music\Jazz\Kind of Blue\01 - So What.flac',
                         'So What', 'Miles Davis', 'Kind of Blue', 1, 1);
  FTrack.Genre      := 'Jazz';
  FTrack.CleanGenre := 'jazz';
  FTrack.Year       := 1959;
  FTrack.SampleRate := 96000;
  FTrack.BitDepth   := 24;
end;

function TTestTrackQuery.Matches(const AQuery: string): Boolean;
begin
  Result := EvaluateTrack(ParseQuery(AQuery), @FTrack, nil);
end;

procedure TTestTrackQuery.EmptyQueryMatchesEverything;
begin
  AssertTrue(Matches(''));
end;

procedure TTestTrackQuery.HasFindsPartOfAWord;
begin
  AssertTrue('Part of the artist', Matches('%artist% HAS dav'));
  AssertFalse('Not in the artist', Matches('%artist% HAS coltrane'));
end;

procedure TTestTrackQuery.HasIgnoresCaseAndAccents;
var
  T: TTrackInfo;
begin
  AssertTrue('Case', Matches('%album% HAS KIND OF'));
  T := MakeTrack('E:\Klassik\Dvořák\01.flac', 'Largo', 'Antonín Dvořák', 'Symphonie Nr. 9');
  AssertTrue('Without accents finds accents',
    EvaluateTrack(ParseQuery('%artist% HAS dvorak'), @T, nil));
  AssertTrue('With accents',
    EvaluateTrack(ParseQuery('%artist% HAS Dvořák'), @T, nil));
end;

procedure TTestTrackQuery.IsNeedsTheWholeValue;
begin
  AssertTrue('Whole value', Matches('%genre% IS jazz'));
  AssertFalse('Part only', Matches('%genre% IS jaz'));
end;

procedure TTestTrackQuery.OrMatchesAnyAlternative;
begin
  AssertTrue('Second alternative', Matches('%genre% IS rock OR jazz'));
  AssertFalse('No alternative', Matches('%genre% IS rock OR blues'));
  AssertTrue('Numbers', Matches('%year% = 1958 OR 1959'));
end;

procedure TTestTrackQuery.NotHasExcludes;
begin
  AssertTrue('Not in the title', Matches('%title% NOT HAS live'));
  AssertFalse('In the title', Matches('%title% NOT HAS what'));
end;

procedure TTestTrackQuery.StartsWithChecksTheBeginning;
begin
  AssertTrue('Beginning', Matches('%artist% STARTSWITH miles'));
  AssertFalse('Not the beginning', Matches('%artist% STARTSWITH davis'));
end;

procedure TTestTrackQuery.NumberComparisons;
begin
  AssertTrue('>=', Matches('%year% >= 1959'));
  AssertFalse('>', Matches('%year% > 1959'));
  AssertTrue('<', Matches('%year% < 1960'));
  AssertTrue('<>', Matches('%year% <> 1960'));
  AssertTrue('Sample rate', Matches('%samplerate% >= 88200'));
  AssertTrue('Bit depth', Matches('%bitdepth% = 24'));
end;

procedure TTestTrackQuery.AllConditionsMustMatch;
begin
  AssertTrue('Both match', Matches('%artist% HAS miles; %year% < 1960'));
  AssertFalse('One fails', Matches('%artist% HAS miles; %year% > 1960'));
end;

procedure TTestTrackQuery.CodecAndResolution;
var
  T: TTrackInfo;
begin
  AssertTrue('FLAC codec', Matches('%codec% IS flac'));
  T := MakeTrack('D:\Music\DSD\01 - Track.dsf', 'Track', 'X', 'DSD Album');
  T.SampleRate := 2822400;
  AssertTrue('DSD codec', EvaluateTrack(ParseQuery('%codec% IS dsd'), @T, nil));
end;

procedure TTestTrackQuery.UnknownTagsAreIgnored;
begin
  // ParseQuery drops statements with an unknown tag or operator
  AssertTrue('Unknown tag', Matches('%nosuchtag% IS x'));
  AssertTrue('Unknown operator', Matches('%artist% LIKE x'));
end;

{ TTestDatabaseLines }

procedure TTestDatabaseLines.EncodeDecodeRoundTrip;
const
  Samples: array[0..7] of string = (
    '', 'Plain text', 'a<b', 'Literal <br> and <tab> and <lt>', 'Tab'#9'here',
    'Größe & Dvořák 坂本龍一', '<', 'ends with <');
var
  I: Integer;
begin
  for I := 0 to High(Samples) do
    AssertEquals('Sample ' + IntToStr(I), Samples[I], DecodeDbField(EncodeDbField(Samples[I])));
  AssertEquals('Line break', 'one' + sLineBreak + 'two',
    DecodeDbField(EncodeDbField('one' + sLineBreak + 'two')));
end;

procedure TTestDatabaseLines.EncodedFieldsHaveNoTabsOrLineBreaks;
var
  S: string;
begin
  S := EncodeDbField('a'#9'b'#13#10'c'#10'd'#13'e');
  AssertEquals('No tab', 0, Pos(#9, S));
  AssertEquals('No CR', 0, Pos(#13, S));
  AssertEquals('No LF', 0, Pos(#10, S));
  AssertEquals('Encoded', 'a<tab>b<br>c<br>d<br>e', S);
end;

procedure TTestDatabaseLines.SingleLineBreakCharactersBecomeCRLF;
begin
  AssertEquals('LF', 'a' + sLineBreak + 'b', DecodeDbField(EncodeDbField('a'#10'b')));
  AssertEquals('CR', 'a' + sLineBreak + 'b', DecodeDbField(EncodeDbField('a'#13'b')));
end;

procedure TTestDatabaseLines.ControlCharactersAreDropped;
begin
  AssertEquals('ab', EncodeDbField('a'#1#2#27'b'));
end;

procedure TTestDatabaseLines.FormatAndParseKeepEveryField;
var
  T, P: TTrackInfo;
  Line: string;
  I, Tabs: Integer;
begin
  T := Default(TTrackInfo);
  T.FilePath      := 'D:\Music\A\01 - X.flac';
  T.FolderDir     := 'D:\Music\A';
  T.Title         := 'Title with'#9'tab and <br>';
  T.Artist        := 'Artist';
  T.Album         := 'Album';
  T.Genre         := 'Jazz';
  T.TrackNumber   := 1;
  T.LastModified  := 1499990016;
  T.DurationStr   := '05:30';
  T.AlbumArtist   := 'Album Artist';
  T.DiscNumber    := 2;
  T.Year          := 1999;
  T.DateStr       := '1999-12-31';
  T.SampleRate    := 192000;
  T.BitDepth      := 24;
  T.DateAdded     := 1700000000;
  T.HasReplayGain := True;
  T.FileSize      := 123456789012;
  T.Comment       := 'Line 1' + sLineBreak + 'Line 2';
  T.Composer      := 'Composer';
  T.Performer     := 'Performer';

  Line := FormatTrackLine(T);
  Tabs := 0;
  for I := 1 to Length(Line) do
    if Line[I] = #9 then
      Inc(Tabs);
  AssertEquals('21 fields = 20 tabs', 20, Tabs);

  AssertTrue('Parsed', ParseTrackLine(Line, P));
  AssertEquals('FilePath', T.FilePath, P.FilePath);
  AssertEquals('FolderDir', T.FolderDir, P.FolderDir);
  AssertEquals('Title', T.Title, P.Title);
  AssertEquals('Artist', T.Artist, P.Artist);
  AssertEquals('Album', T.Album, P.Album);
  AssertEquals('Genre', T.Genre, P.Genre);
  AssertEquals('TrackNumber', T.TrackNumber, P.TrackNumber);
  AssertEquals('LastModified', T.LastModified, P.LastModified);
  AssertEquals('DurationStr', T.DurationStr, P.DurationStr);
  AssertEquals('AlbumArtist', T.AlbumArtist, P.AlbumArtist);
  AssertEquals('DiscNumber', T.DiscNumber, P.DiscNumber);
  AssertEquals('Year', T.Year, P.Year);
  AssertEquals('DateStr', T.DateStr, P.DateStr);
  AssertEquals('SampleRate', T.SampleRate, P.SampleRate);
  AssertEquals('BitDepth', T.BitDepth, P.BitDepth);
  AssertEquals('DateAdded', T.DateAdded, P.DateAdded);
  AssertEquals('HasReplayGain', T.HasReplayGain, P.HasReplayGain);
  AssertEquals('FileSize', T.FileSize, P.FileSize);
  AssertEquals('Comment', T.Comment, P.Comment);
  AssertEquals('Composer', T.Composer, P.Composer);
  AssertEquals('Performer', T.Performer, P.Performer);
  AssertEquals('Search fields are left empty', '', P.CleanTitle);
end;

procedure TTestDatabaseLines.ParseReadsOldSevenFieldLines;
var
  P: TTrackInfo;
begin
  // The oldest format: '|' separated, 7 fields
  AssertTrue('Parsed', ParseTrackLine('D:\M\A\01.wav|D:\M\A|Title|Artist|Album|Genre|5', P));
  AssertEquals('Title', 'Title', P.Title);
  AssertEquals('TrackNumber', 5, P.TrackNumber);
  AssertEquals('Duration default', ZERO_TIME, P.DurationStr);
  AssertEquals('AlbumArtist = Artist', 'Artist', P.AlbumArtist);
  AssertEquals('No date', 0, P.LastModified);
  AssertFalse('No ReplayGain', P.HasReplayGain);
end;

procedure TTestDatabaseLines.ParseConvertsOldDateAdded;
var
  P: TTrackInfo;
  FileDate: LongInt;
begin
  // Older files stored DateAdded as a small file-date value: it is replaced
  // by the Unix time of LastModified
  FileDate := DateTimeToFileDate(EncodeDate(2020, 1, 2));
  AssertTrue('Parsed', ParseTrackLine(
    'D:\M\A\01.flac'#9'D:\M\A'#9'T'#9'A'#9'Al'#9'G'#9'1'#9 + IntToStr(FileDate) +
    #9'01:00'#9'A'#9'0'#9'2020'#9'2020'#9'44100'#9'16'#9'12345', P));
  AssertEquals('Unix time of LastModified',
    DateTimeToUnix(FileDateToDateTime(FileDate), False), P.DateAdded);
end;

procedure TTestDatabaseLines.ParseTakesTheFolderFromThePathWhenEmpty;
var
  P: TTrackInfo;
begin
  AssertTrue('Parsed', ParseTrackLine('D:\M\Album\01.flac'#9#9'T'#9'A'#9'Al'#9'G'#9'1', P));
  AssertEquals('Folder from the path', 'D:\M\Album', P.FolderDir);
end;

procedure TTestDatabaseLines.ParseRejectsShortLines;
var
  P: TTrackInfo;
begin
  AssertFalse('6 fields', ParseTrackLine('a'#9'b'#9'c'#9'd'#9'e'#9'f', P));
  AssertFalse('Empty line', ParseTrackLine('', P));
  AssertEquals('Empty record', '', P.FilePath);
end;

{ TTestTagReaders }

procedure TTestTagReaders.EveryAulumicFormatHasARealReader;
var
  Exts : TStringList;
  I    : Integer;
begin
  Exts := TStringList.Create;
  try
    Exts.CommaText := FILE_VALID_EXTS;   // '.flac,.wav,.dsf'
    AssertTrue('Formats listed', Exts.Count > 0);
    for I := 0 to Exts.Count - 1 do
      AssertTrue('No tag reader registered for ' + Exts[I] +
                 ' (ALMetadata must use RegisterAllReader)',
        IdentifyKind('D:\Music\Album\01 - Track' + Exts[I]) <> TDummyReader);
  finally
    Exts.Free;
  end;
end;

procedure TTestTagReaders.DffFileIsReadWithItsFormat;
const
  BYTES = 352800;               // 1 s of DSD64 per channel (2822400 bits)
var
  Dir  : string;
  Meta : TAudioMetadata;
begin
  Dir := CreateTestDir;
  try
    WriteTestDff(Dir + 'Test.dff', BYTES);
    Meta := ReadTrackMetadata(Dir + 'Test.dff', False);
    AssertEquals('DSD64 rate', 2822400, Meta.SampleRate);
    AssertEquals('Channels', 2, Meta.Channels);
    AssertEquals('One second', '0:01', Meta.DurationStr);
  finally
    RemoveTestTree(Dir);
  end;
end;

procedure TTestTagReaders.WavFileIsReadWithItsFormat;
var
  Dir  : string;
  Meta : TAudioMetadata;
begin
  Dir := CreateTestDir;
  try
    WriteTestWav(Dir + 'Test.wav', 9600, 96000, 24, 2);
    Meta := ReadTrackMetadata(Dir + 'Test.wav', False);
    AssertEquals('Sample rate', 96000, Meta.SampleRate);
    AssertEquals('Bit depth', 24, Meta.BitDepth);
    AssertEquals('Channels', 2, Meta.Channels);
  finally
    RemoveTestDir(Dir);
  end;
end;

{ TTestTrackList }

// Titles of the list items in order, comma-separated
function ListTitles(AList: TTrackList): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AList.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + AList[I]^.Title;
  end;
end;

procedure TTestTrackList.AddStoresACopy;
var
  L: TTrackList;
  Source: TTrackInfo;
  Added: PTrackInfo;
begin
  L := TTrackList.Create;
  try
    Source := MakeTrack('D:\Music\Album\01 - One.flac', 'One', 'Artist', 'Album', 1);
    Added  := L.Add(Source);
    AssertEquals('Count', 1, L.Count);
    AssertTrue('Add returns the stored copy', Added = L[0]);
    AssertTrue('Not the source record', Added <> @Source);

    Source.Title := 'Changed source';
    AssertEquals('Copy unchanged by the source', 'One', L[0]^.Title);
    L[0]^.Artist := 'Changed copy';
    AssertEquals('Source unchanged by the copy', 'Artist', Source.Artist);
  finally
    L.Free;
  end;
end;

procedure TTestTrackList.AddListCopiesEveryTrack;
var
  A, B: TTrackList;
begin
  A := TTrackList.Create;
  B := TTrackList.Create;
  try
    A.Add(MakeTrack('D:\M\01 - One.flac', 'One', 'X', 'Y', 1));
    A.Add(MakeTrack('D:\M\02 - Two.flac', 'Two', 'X', 'Y', 2));
    B.Add(MakeTrack('D:\M\03 - Three.flac', 'Three', 'X', 'Y', 3));

    B.AddList(A);
    AssertEquals('Appended', 'Three,One,Two', ListTitles(B));
    AssertTrue('Own records, not A''s', B[1] <> A[0]);

    // A can go away: B keeps complete copies
    A.Free;
    A := nil;
    AssertEquals('Copies survive the source list', 'Three,One,Two', ListTitles(B));
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TTestTrackList.AddListOfItselfDoesNothing;
var
  L: TTrackList;
begin
  L := TTrackList.Create;
  try
    L.Add(MakeTrack('D:\M\01 - One.flac', 'One', 'X', 'Y', 1));
    L.AddList(L);
    L.AddList(nil);
    AssertEquals('Unchanged', 1, L.Count);
  finally
    L.Free;
  end;
end;

procedure TTestTrackList.SortOrdersTheCopies;
var
  L: TTrackList;
begin
  L := TTrackList.Create;
  try
    L.Add(MakeTrack('D:\M\10 - Ten.flac', 'Ten', 'X', 'Y', 10));
    L.Add(MakeTrack('D:\M\01 - One.flac', 'One', 'X', 'Y', 1));
    L.Add(MakeTrack('D:\M\02 - Two.flac', 'Two', 'X', 'Y', 2));
    L.Sort(@CompareTrackInfo);
    AssertEquals('Library order', 'One,Two,Ten', ListTitles(L));
  finally
    L.Free;
  end;
end;

procedure TTestTrackList.ListViewSeesTheSameItems;
var
  L: TTrackList;
begin
  L := TTrackList.Create;
  try
    L.Add(MakeTrack('D:\M\02 - Two.flac', 'Two', 'X', 'Y', 2));
    L.Add(MakeTrack('D:\M\01 - One.flac', 'One', 'X', 'Y', 1));
    AssertEquals('Same count', L.Count, L.List.Count);
    AssertTrue('Same item', PTrackInfo(L.List[1]) = L[1]);

    // Reordering through the TList view (as PrepareAutoPlaylistView does)
    // keeps the items owned by the TTrackList
    L.List.Exchange(0, 1);
    AssertEquals('Reordered', 'One,Two', ListTitles(L));
  finally
    L.Free;  // heaptrc: both copies disposed exactly once
  end;
end;

procedure TTestTrackList.ClearEmptiesTheList;
var
  L: TTrackList;
begin
  L := TTrackList.Create;
  try
    L.Add(MakeTrack('D:\M\01 - One.flac', 'One', 'X', 'Y', 1));
    L.Add(MakeTrack('D:\M\02 - Two.flac', 'Two', 'X', 'Y', 2));
    L.Clear;
    AssertEquals('Empty', 0, L.Count);
    L.Add(MakeTrack('D:\M\03 - Three.flac', 'Three', 'X', 'Y', 3));
    AssertEquals('Usable after Clear', 'Three', ListTitles(L));
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TTestTrackSorting);
  RegisterTest(TTestTrackQuery);
  RegisterTest(TTestDatabaseLines);
  RegisterTest(TTestTagReaders);
  RegisterTest(TTestTrackList);

end.
