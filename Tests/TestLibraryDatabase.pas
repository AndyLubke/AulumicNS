unit TestLibraryDatabase;

{$mode ObjFPC}{$H+}
{$codepage UTF8}

{ ==============================================================================
  AulumicNS tests - TestLibraryDatabase
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for the library database file of TLibraryManager:
  loading a hand-written file (all 21 track fields, library folders, virtual
  folders, escaped characters), save + reload keeps everything, escaping of
  tabs / line breaks / a literal '<br>' in tags, and that nothing is written
  when nothing changed. Only files in a temporary folder are used.
  The hand-written file is the tests' text format (uLibraryDatabase), loaded
  with ImportTextDatabase and saved as the library's snapshot before
  each test loads it. TTestLibraryStore: the journal (an edit survives
  without a save, a journal of an older snapshot and a torn record are
  ignored), a damaged snapshot is kept as a backup, the user stats journal,
  and uDbStore's reader refuses short data.

  TTestLibraryAccess: the thread-safe methods other units use instead of the
  library's lock (TryGetTrack, SnapshotTracks, the ReplayGain flag methods),
  and reading from a second thread while the main thread edits a record.
  The track lists (TTrackList) hold copies that stay valid when the library
  replaces its records.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uLibraryManager, uLibraryTypes;

type
  TTestLibraryDatabase = class(TTestCase)
  private
    FDir    : string;
    FDbFile : string;
    procedure WriteSampleDatabase;
    procedure CheckSameTrack(const AMsg: string; AExpected, AActual: PTrackInfo);
    procedure CheckSameLibrary(AExpected, AActual: TLibraryManager);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure LoadReadsEveryField;
    procedure LoadReadsFoldersAndVirtualFolders;
    procedure LoadDecodesEscapedCharacters;
    procedure SaveAndReloadKeepsEverything;
    procedure EditedTagsWithSpecialCharactersSurvive;
    procedure NothingIsWrittenWhenNothingChanged;
    procedure MissingFileGivesAnEmptyLibrary;
  end;

  TTestLibraryAccess = class(TTestCase)
  private
    FDir : string;
    FLib : TLibraryManager;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TryGetTrackReturnsACopy;
    procedure TryGetTrackOfAnUnknownPathFails;
    procedure SnapshotHasCopiesOfAllTracks;
    procedure AnyTrackMissingReplayGain;
    procedure SetReplayGainFlagIsSavedWithDateAndSize;
    procedure SetReplayGainFlagWithoutAChangeKeepsTheLibraryClean;
    procedure SetReplayGainFlagsCountsTheChanges;
    procedure ClearReplayGainForAlbumsOnlyTouchesThoseAlbums;
    procedure ReadsFromAThreadWhileTheMainThreadEdits;
    // The track lists are copies (TTrackList)
    procedure TrackListsHoldCopies;
    procedure TrackListsStayValidWhenTheLibraryIsReplaced;
    procedure TrackListGettersFindTheRightTracks;
  end;

  { Snapshot + journal (uDbStore) }
  TTestLibraryStore = class(TTestCase)
  private
    FDir    : string;
    FDbFile : string;
    function TitleAfterReload(const APath: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AnEditSurvivesWithoutASave;
    procedure AJournalOfAnOlderSnapshotIsIgnored;
    procedure ATornJournalRecordIsIgnored;
    procedure ADamagedSnapshotIsKeptAsABackup;
    procedure StatsSurviveWithoutASave;
    procedure StatsSnapshotKeepsEveryValue;
    procedure ReaderRefusesShortData;
  end;

implementation

uses
  TestHelpers, uDbStore, uUserStatsManager, uLibraryDatabase;

const
  TRACK1_PATH = 'D:\Music\Miles Davis\Kind of Blue\01 - So What.flac';
  // Typed (UTF-8 string): an untyped constant with non-ASCII characters is a
  // UTF-16 constant, and comparing it with a string needs a conversion
  TRACK2_PATH: string = 'E:\Klassik\Dvořák\Symphonie Nr. 9\02 - Largo.flac';
  LINK_PATH   = 'D:\Music\Favourites.aullink';
  EMPTY_LINK  = 'D:\Music\Empty.aullink';

// One track line of the text format: the 21 fields in order, tab-separated
function TrackLine(const AFields: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
  begin
    if I > 0 then
      Result := Result + #9;
    Result := Result + AFields[I];
  end;
end;

{ TTestLibraryDatabase }

procedure TTestLibraryDatabase.SetUp;
begin
  FDir    := CreateTestDir;
  FDbFile := FDir + 'Library.db';
end;

procedure TTestLibraryDatabase.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure WriteSampleLibrary(const AFile: string); forward;

procedure TTestLibraryDatabase.WriteSampleDatabase;
begin
  WriteSampleLibrary(FDbFile);
end;

// The sample library: two library folders, two virtual folders, two tracks
// (track 1 with ReplayGain, album 'Kind of Blue'; track 2 without)
procedure SampleLines(SL: TStrings);
begin
    SL.Add('?FOLDER?D:\Music');
    SL.Add('?FOLDER?E:\Klassik');
    SL.Add('?LINK?' + LINK_PATH + #9 + 'E:\Klassik\Bach');
    SL.Add('?LINK?' + LINK_PATH + #9 + 'E:\Klassik\Händel');
    SL.Add('?LINK?' + EMPTY_LINK);
    // FilePath, FolderDir, Title, Artist, Album, Genre, TrackNumber,
    // LastModified, DurationStr, AlbumArtist, DiscNumber, Year, DateStr,
    // SampleRate, BitDepth, DateAdded, HasReplayGain, FileSize, Comment,
    // Composer, Performer
    SL.Add(TrackLine([TRACK1_PATH, 'D:\Music\Miles Davis\Kind of Blue\', 'So What',
      'Miles Davis', 'Kind of Blue', 'Jazz', '1', '1499990016', '09:22', 'Miles Davis',
      '1', '1959', '1959-08-17', '44100', '16', '1700000000', 'True', '41234567',
      'Remastered', 'Miles Davis', 'Miles Davis Sextet']));
    // Escaped: '<br>' = line break, '<tab>' = tab, '<lt>' = a literal '<'
    SL.Add(TrackLine([TRACK2_PATH, 'E:\Klassik\Dvořák\Symphonie Nr. 9', 'Largo<br>Goin'' Home',
      'Wiener Philharmoniker', 'Symphonie Nr. 9 <lt>br> «Aus der Neuen Welt»', 'Klassik',
      '2', '1500000000', '12:01', 'Antonín Dvořák', '1', '1985', '1985', '96000', '24',
      '1700000100', 'False', '123456789', 'Live<tab>1985', 'Antonín Dvořák', '']));
end;

// The sample as a text file (for ImportTextDatabase)
procedure WriteSampleText(const AFile: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SampleLines(SL);
    SL.SaveToFile(AFile, TEncoding.UTF8);
  finally
    SL.Free;
  end;
end;

// The sample library in AulumicNS' own format at AFile:
// the text imported (ImportTextDatabase) and saved as a snapshot, so
// every test that loads AFile reads the snapshot written by SaveDatabase
procedure WriteSampleLibrary(const AFile: string);
var
  Lib: TLibraryManager;
  Txt: string;
begin
  Txt := AFile + '.aulumic.txt';
  WriteSampleText(Txt);
  Lib := TLibraryManager.Create(AFile);
  try
    if ImportTextDatabase(Lib, Txt) <> 2 then
      raise Exception.Create('The sample library could not be imported');
    Lib.SaveDatabase;
    if Lib.IsDirty then
      raise Exception.Create('The sample library could not be saved');
  finally
    Lib.Free;
  end;
  DeleteFile(Txt);
end;

procedure TTestLibraryDatabase.CheckSameTrack(const AMsg: string;
  AExpected, AActual: PTrackInfo);
begin
  AssertNotNull(AMsg + ' exists', AActual);
  AssertEquals(AMsg + ' FilePath',      AExpected^.FilePath,      AActual^.FilePath);
  AssertEquals(AMsg + ' FolderDir',     AExpected^.FolderDir,     AActual^.FolderDir);
  AssertEquals(AMsg + ' Title',         AExpected^.Title,         AActual^.Title);
  AssertEquals(AMsg + ' Artist',        AExpected^.Artist,        AActual^.Artist);
  AssertEquals(AMsg + ' AlbumArtist',   AExpected^.AlbumArtist,   AActual^.AlbumArtist);
  AssertEquals(AMsg + ' Album',         AExpected^.Album,         AActual^.Album);
  AssertEquals(AMsg + ' Genre',         AExpected^.Genre,         AActual^.Genre);
  AssertEquals(AMsg + ' Composer',      AExpected^.Composer,      AActual^.Composer);
  AssertEquals(AMsg + ' Performer',     AExpected^.Performer,     AActual^.Performer);
  AssertEquals(AMsg + ' TrackNumber',   AExpected^.TrackNumber,   AActual^.TrackNumber);
  AssertEquals(AMsg + ' DiscNumber',    AExpected^.DiscNumber,    AActual^.DiscNumber);
  AssertEquals(AMsg + ' LastModified',  AExpected^.LastModified,  AActual^.LastModified);
  AssertEquals(AMsg + ' FileSize',      AExpected^.FileSize,      AActual^.FileSize);
  AssertEquals(AMsg + ' DurationStr',   AExpected^.DurationStr,   AActual^.DurationStr);
  AssertEquals(AMsg + ' Comment',       AExpected^.Comment,       AActual^.Comment);
  AssertEquals(AMsg + ' Year',          AExpected^.Year,          AActual^.Year);
  AssertEquals(AMsg + ' DateStr',       AExpected^.DateStr,       AActual^.DateStr);
  AssertEquals(AMsg + ' SampleRate',    AExpected^.SampleRate,    AActual^.SampleRate);
  AssertEquals(AMsg + ' BitDepth',      AExpected^.BitDepth,      AActual^.BitDepth);
  AssertEquals(AMsg + ' DateAdded',     AExpected^.DateAdded,     AActual^.DateAdded);
  AssertEquals(AMsg + ' HasReplayGain', AExpected^.HasReplayGain, AActual^.HasReplayGain);
end;

procedure TTestLibraryDatabase.CheckSameLibrary(AExpected, AActual: TLibraryManager);
var
  I: Integer;
  Expected: TTrackInfoArray;
  Actual: TTrackInfo;
  FoldersA, FoldersB: TStringList;
begin
  AssertEquals('Track count', AExpected.GetTrackCount, AActual.GetTrackCount);
  Expected := AExpected.SnapshotTracks;
  for I := 0 to High(Expected) do
  begin
    AssertTrue(ExtractFileName(Expected[I].FilePath) + ' found',
      AActual.TryGetTrack(Expected[I].FilePath, Actual));
    CheckSameTrack(ExtractFileName(Expected[I].FilePath), @Expected[I], @Actual);
  end;

  FoldersA := TStringList.Create;
  FoldersB := TStringList.Create;
  try
    AExpected.GetScanFolders(FoldersA);
    AActual.GetScanFolders(FoldersB);
    AssertEquals('Library folders', FoldersA.Text, FoldersB.Text);

    FoldersA.Clear;
    FoldersB.Clear;
    AssertTrue('Link known before', AExpected.GetVirtualLinkTargets(LINK_PATH, FoldersA));
    AssertTrue('Link known after', AActual.GetVirtualLinkTargets(LINK_PATH, FoldersB));
    AssertEquals('Link targets', FoldersA.Text, FoldersB.Text);
  finally
    FoldersA.Free;
    FoldersB.Free;
  end;
end;

procedure TTestLibraryDatabase.LoadReadsEveryField;
var
  Lib: TLibraryManager;
  Rec: TTrackInfo;
  T: PTrackInfo;
begin
  WriteSampleDatabase;
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertEquals('Track count', 2, Lib.GetTrackCount);

    AssertTrue('Track 1 found', Lib.TryGetTrack(TRACK1_PATH, Rec));
    T := @Rec;
    AssertEquals('FolderDir without trailing backslash',
      'D:\Music\Miles Davis\Kind of Blue', T^.FolderDir);
    AssertEquals('Title', 'So What', T^.Title);
    AssertEquals('Artist', 'Miles Davis', T^.Artist);
    AssertEquals('Album', 'Kind of Blue', T^.Album);
    AssertEquals('Genre', 'Jazz', T^.Genre);
    AssertEquals('TrackNumber', 1, T^.TrackNumber);
    AssertEquals('LastModified', 1499990016, T^.LastModified);
    AssertEquals('DurationStr', '09:22', T^.DurationStr);
    AssertEquals('AlbumArtist', 'Miles Davis', T^.AlbumArtist);
    AssertEquals('DiscNumber', 1, T^.DiscNumber);
    AssertEquals('Year', 1959, T^.Year);
    AssertEquals('DateStr', '1959-08-17', T^.DateStr);
    AssertEquals('SampleRate', 44100, T^.SampleRate);
    AssertEquals('BitDepth', 16, T^.BitDepth);
    AssertEquals('DateAdded', 1700000000, T^.DateAdded);
    AssertTrue('HasReplayGain', T^.HasReplayGain);
    AssertEquals('FileSize', 41234567, T^.FileSize);
    AssertEquals('Comment', 'Remastered', T^.Comment);
    AssertEquals('Composer', 'Miles Davis', T^.Composer);
    AssertEquals('Performer', 'Miles Davis Sextet', T^.Performer);

    AssertTrue('Path lookup ignores case', Lib.ContainsTrack(UpperCase(TRACK1_PATH)));
    AssertTrue('Forward slashes', Lib.ContainsTrack(StringReplace(TRACK1_PATH, '\', '/', [rfReplaceAll])));
    AssertFalse('Unknown path', Lib.ContainsTrack('D:\Music\Not\In\Library.flac'));
    AssertFalse('Empty path', Lib.ContainsTrack(''));
  finally
    Lib.Free;
  end;
end;

procedure TTestLibraryDatabase.LoadReadsFoldersAndVirtualFolders;
var
  Lib: TLibraryManager;
  SL: TStringList;
begin
  WriteSampleDatabase;
  Lib := TLibraryManager.Create(FDbFile);
  SL  := TStringList.Create;
  try
    Lib.LoadDatabase;

    Lib.GetScanFolders(SL);
    AssertEquals('Library folder count', 2, SL.Count);
    AssertTrue('D:\Music', SL.IndexOf('D:\Music') >= 0);
    AssertTrue('E:\Klassik', SL.IndexOf('E:\Klassik') >= 0);

    SL.Clear;
    AssertTrue('Link known', Lib.GetVirtualLinkTargets(LINK_PATH, SL));
    AssertEquals('Link target count', 2, SL.Count);
    AssertTrue('Bach', SL.IndexOf('E:\Klassik\Bach') >= 0);
    AssertTrue('Händel', SL.IndexOf('E:\Klassik\Händel') >= 0);

    SL.Clear;
    AssertTrue('Link without targets known', Lib.GetVirtualLinkTargets(EMPTY_LINK, SL));
    AssertEquals('No targets', 0, SL.Count);
  finally
    SL.Free;
    Lib.Free;
  end;
end;

procedure TTestLibraryDatabase.LoadDecodesEscapedCharacters;
var
  Lib: TLibraryManager;
  Rec: TTrackInfo;
  T: PTrackInfo;
begin
  WriteSampleDatabase;
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('Track 2 found', Lib.TryGetTrack(TRACK2_PATH, Rec));
    T := @Rec;
    AssertEquals('<br> becomes a line break', 'Largo' + sLineBreak + 'Goin'' Home', T^.Title);
    AssertEquals('<lt> becomes a literal <', 'Symphonie Nr. 9 <br> «Aus der Neuen Welt»', T^.Album);
    AssertEquals('<tab> becomes a tab', 'Live' + #9 + '1985', T^.Comment);
    AssertEquals('Unicode', 'Antonín Dvořák', T^.AlbumArtist);
    AssertFalse('HasReplayGain', T^.HasReplayGain);
    AssertEquals('Empty field', '', T^.Performer);
  finally
    Lib.Free;
  end;
end;

procedure TTestLibraryDatabase.SaveAndReloadKeepsEverything;
var
  First, Second: TLibraryManager;
begin
  WriteSampleDatabase;
  First := TLibraryManager.Create(FDbFile);
  try
    First.LoadDatabase;
    // Save with the library's own writer, then read it again
    First.IsDirty := True;
    First.SaveDatabase;
    AssertFalse('Clean after the save', First.IsDirty);

    Second := TLibraryManager.Create(FDbFile);
    try
      Second.LoadDatabase;
      CheckSameLibrary(First, Second);
    finally
      Second.Free;
    end;
  finally
    First.Free;
  end;
end;

procedure TTestLibraryDatabase.EditedTagsWithSpecialCharactersSurvive;
var
  First, Second: TLibraryManager;
  Edit, Rec: TTrackInfo;
  T: PTrackInfo;
begin
  WriteSampleDatabase;
  First := TLibraryManager.Create(FDbFile);
  try
    First.LoadDatabase;

    // As the tag editor does it (TMetadataCustodian -> UpdateRecord)
    AssertTrue('Track 1 found', First.TryGetTrack(TRACK1_PATH, Edit));
    Edit.Title       := 'Literal <br> and <tab> and <lt> text';
    Edit.Album       := 'Album' + #9 + 'with a tab';
    Edit.Comment     := 'First line' + sLineBreak + 'Second line';
    Edit.Composer    := '坂本龍一';
    First.UpdateRecord(Edit);
    AssertTrue('Dirty after the edit', First.IsDirty);
    First.SaveDatabase;

    Second := TLibraryManager.Create(FDbFile);
    try
      Second.LoadDatabase;
      AssertTrue('Track 1 found after reload', Second.TryGetTrack(TRACK1_PATH, Rec));
      T := @Rec;
      AssertEquals('Literal tokens stay text', 'Literal <br> and <tab> and <lt> text', T^.Title);
      AssertEquals('Tab', 'Album' + #9 + 'with a tab', T^.Album);
      AssertEquals('Line break', 'First line' + sLineBreak + 'Second line', T^.Comment);
      AssertEquals('Unicode', '坂本龍一', T^.Composer);
      CheckSameLibrary(First, Second);
    finally
      Second.Free;
    end;
  finally
    First.Free;
  end;
end;

procedure TTestLibraryDatabase.NothingIsWrittenWhenNothingChanged;
var
  Lib: TLibraryManager;
begin
  WriteSampleDatabase;
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertFalse('Not dirty after loading', Lib.IsDirty);
    // If SaveDatabase wrote anything, the file would exist again
    AssertTrue('Remove the file', DeleteFile(FDbFile));
    Lib.SaveDatabase;
    AssertFalse('Nothing written', FileExists(FDbFile));
  finally
    Lib.Free;
  end;
end;

procedure TTestLibraryDatabase.MissingFileGivesAnEmptyLibrary;
var
  Lib: TLibraryManager;
begin
  Lib := TLibraryManager.Create(FDir + 'NoSuchLibrary.db');
  try
    Lib.LoadDatabase;
    AssertEquals('No tracks', 0, Lib.GetTrackCount);
    AssertFalse('No library folders', Lib.HasScanFolders);
  finally
    Lib.Free;
  end;
end;

{ TTestLibraryAccess }

procedure TTestLibraryAccess.SetUp;
begin
  FDir := CreateTestDir;
  WriteSampleLibrary(FDir + 'Library.db');
  FLib := TLibraryManager.Create(FDir + 'Library.db');
  FLib.LoadDatabase;
end;

procedure TTestLibraryAccess.TearDown;
begin
  FreeAndNil(FLib);
  RemoveTestDir(FDir);
end;

procedure TTestLibraryAccess.TryGetTrackReturnsACopy;
var
  T, Again: TTrackInfo;
begin
  AssertTrue('Found', FLib.TryGetTrack(TRACK1_PATH, T));
  AssertEquals('Title', 'So What', T.Title);
  AssertTrue('HasReplayGain', T.HasReplayGain);

  // Changing the copy must not change the library
  T.Title         := 'Changed';
  T.HasReplayGain := False;
  AssertTrue('Found again', FLib.TryGetTrack(TRACK1_PATH, Again));
  AssertEquals('Library title unchanged', 'So What', Again.Title);
  AssertTrue('Library flag unchanged', Again.HasReplayGain);
  AssertFalse('Not dirty', FLib.IsDirty);
end;

procedure TTestLibraryAccess.TryGetTrackOfAnUnknownPathFails;
var
  T: TTrackInfo;
begin
  T.Title := 'left over';
  AssertFalse('Unknown path', FLib.TryGetTrack('D:\Music\Not\In\Library.flac', T));
  AssertEquals('Empty record', '', T.Title);
  AssertEquals('Empty path', '', T.FilePath);
end;

procedure TTestLibraryAccess.SnapshotHasCopiesOfAllTracks;
var
  Snap: TTrackInfoArray;
  T: TTrackInfo;
  I: Integer;
  Found1, Found2: Boolean;
begin
  Snap := FLib.SnapshotTracks;
  AssertEquals('Count', FLib.GetTrackCount, Length(Snap));
  Found1 := False;
  Found2 := False;
  for I := 0 to High(Snap) do
  begin
    if Snap[I].FilePath = TRACK1_PATH then Found1 := True;
    if Snap[I].FilePath = TRACK2_PATH then Found2 := True;
    Snap[I].Title := 'Changed';
  end;
  AssertTrue('Track 1 in the snapshot', Found1);
  AssertTrue('Track 2 in the snapshot', Found2);

  AssertTrue('Found', FLib.TryGetTrack(TRACK1_PATH, T));
  AssertEquals('Library unchanged by the snapshot', 'So What', T.Title);
end;

procedure TTestLibraryAccess.AnyTrackMissingReplayGain;
var
  Files: TStringList;
begin
  Files := TStringList.Create;
  try
    AssertFalse('Empty list', FLib.AnyTrackMissingReplayGain(Files));

    Files.Add(TRACK1_PATH);
    AssertFalse('Only a track with ReplayGain', FLib.AnyTrackMissingReplayGain(Files));

    Files.Add('D:\Music\Not\In\Library.flac');
    AssertFalse('Files outside the library do not count', FLib.AnyTrackMissingReplayGain(Files));

    Files.Add(TRACK2_PATH);
    AssertTrue('Track 2 has no ReplayGain', FLib.AnyTrackMissingReplayGain(Files));

    AssertFalse('nil list', FLib.AnyTrackMissingReplayGain(nil));
  finally
    Files.Free;
  end;
end;

procedure TTestLibraryAccess.SetReplayGainFlagIsSavedWithDateAndSize;
var
  Reloaded: TLibraryManager;
  T: TTrackInfo;
begin
  AssertFalse('Clean after loading', FLib.IsDirty);
  AssertTrue('Track 2 found', FLib.SetReplayGainFlag(TRACK2_PATH, True, 1600000123, 987654321));
  AssertTrue('Dirty after the change', FLib.IsDirty);

  FLib.SaveDatabase;
  Reloaded := TLibraryManager.Create(FDir + 'Library.db');
  try
    Reloaded.LoadDatabase;
    AssertTrue('Found after reload', Reloaded.TryGetTrack(TRACK2_PATH, T));
    AssertTrue('Flag saved', T.HasReplayGain);
    AssertEquals('Date saved', 1600000123, T.LastModified);
    AssertEquals('Size saved', 987654321, T.FileSize);
  finally
    Reloaded.Free;
  end;

  AssertFalse('Unknown path', FLib.SetReplayGainFlag('D:\Music\Not\In\Library.flac', True));
end;

procedure TTestLibraryAccess.SetReplayGainFlagWithoutAChangeKeepsTheLibraryClean;
var
  T: TTrackInfo;
begin
  // Track 1 already has ReplayGain; no date / size given
  AssertTrue('Found', FLib.SetReplayGainFlag(TRACK1_PATH, True));
  AssertFalse('Nothing changed, nothing to save', FLib.IsDirty);

  // The same date and size as stored: still no change
  AssertTrue('Found', FLib.TryGetTrack(TRACK1_PATH, T));
  FLib.SetReplayGainFlag(TRACK1_PATH, True, T.LastModified, T.FileSize);
  AssertFalse('Same date and size, nothing to save', FLib.IsDirty);
end;

procedure TTestLibraryAccess.SetReplayGainFlagsCountsTheChanges;
var
  Files: TStringList;
  T: TTrackInfo;
begin
  Files := TStringList.Create;
  try
    Files.Add(TRACK1_PATH);                      // already True
    Files.Add(TRACK2_PATH);                      // False -> True
    Files.Add('D:\Music\Not\In\Library.flac');   // not in the library
    AssertEquals('One track changed', 1, FLib.SetReplayGainFlags(Files, True));
    AssertTrue('Dirty', FLib.IsDirty);
    AssertTrue('Found', FLib.TryGetTrack(TRACK2_PATH, T));
    AssertTrue('Track 2 now has ReplayGain', T.HasReplayGain);

    AssertEquals('Nothing left to change', 0, FLib.SetReplayGainFlags(Files, True));
    AssertEquals('Both cleared', 2, FLib.SetReplayGainFlags(Files, False));
  finally
    Files.Free;
  end;
end;

procedure TTestLibraryAccess.ClearReplayGainForAlbumsOnlyTouchesThoseAlbums;
var
  Albums: TStringList;
  T: TTrackInfo;
begin
  // Give track 2 ReplayGain too, then clear only track 1's album
  FLib.SetReplayGainFlag(TRACK2_PATH, True);
  FLib.IsDirty := False;

  Albums := TStringList.Create;
  try
    Albums.Sorted := True;   // as TMetadataCustodian's tainted album list
    Albums.Add('Kind of Blue');
    AssertEquals('One track cleared', 1, FLib.ClearReplayGainForAlbums(Albums));
    AssertTrue('Dirty', FLib.IsDirty);

    AssertTrue('Track 1 found', FLib.TryGetTrack(TRACK1_PATH, T));
    AssertFalse('Track 1 cleared', T.HasReplayGain);
    AssertTrue('Track 2 found', FLib.TryGetTrack(TRACK2_PATH, T));
    AssertTrue('Track 2 untouched', T.HasReplayGain);

    AssertEquals('Nothing left to clear', 0, FLib.ClearReplayGainForAlbums(Albums));
  finally
    Albums.Free;
  end;
end;

type
  // Reads track 1 again and again (as the ReplayGain thread does)
  TTrackReaderThread = class(TThread)
  private
    FLib    : TLibraryManager;
    FRounds : Integer;
  protected
    procedure Execute; override;
  public
    Reads, BadTitles : Integer;
    ErrorText        : string;
    constructor Create(ALib: TLibraryManager; ARounds: Integer);
  end;

constructor TTrackReaderThread.Create(ALib: TLibraryManager; ARounds: Integer);
begin
  FLib            := ALib;
  FRounds         := ARounds;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TTrackReaderThread.Execute;
var
  I: Integer;
  T: TTrackInfo;
begin
  try
    for I := 1 to FRounds do
      if FLib.TryGetTrack(TRACK1_PATH, T) then
      begin
        Inc(Reads);
        if (T.Title <> 'So What') and (T.Title <> 'Title A') and (T.Title <> 'Title B') then
          Inc(BadTitles);
      end;
  except
    on E: Exception do
      ErrorText := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TTestLibraryAccess.ReadsFromAThreadWhileTheMainThreadEdits;
const
  ROUNDS = 20000;
var
  Reader : TTrackReaderThread;
  Edit   : TTrackInfo;
  I      : Integer;
begin
  AssertTrue('Found', FLib.TryGetTrack(TRACK1_PATH, Edit));
  Reader := TTrackReaderThread.Create(FLib, ROUNDS);
  try
    // UpdateRecord replaces the record's strings; without the lock the reader
    // could copy a string that is being freed (a crash or a garbled title)
    for I := 1 to ROUNDS do
    begin
      if Odd(I) then
        Edit.Title := 'Title A'
      else
        Edit.Title := 'Title B';
      FLib.UpdateRecord(Edit);
    end;
    Reader.WaitFor;

    AssertEquals('No error in the reader', '', Reader.ErrorText);
    AssertEquals('Every read found the track', ROUNDS, Reader.Reads);
    AssertEquals('Every title read was complete', 0, Reader.BadTitles);
  finally
    Reader.Free;
  end;
end;

procedure TTestLibraryAccess.TrackListsHoldCopies;
var
  L: TTrackList;
  T: TTrackInfo;
begin
  L := TTrackList.Create;
  try
    FLib.GetTracksByArtist('Miles Davis', L);
    AssertEquals('One Miles Davis track', 1, L.Count);
    AssertEquals('Title', 'So What', L[0]^.Title);

    // Changing the copy must not change the library
    L[0]^.Title         := 'Changed';
    L[0]^.HasReplayGain := False;
    AssertTrue('Found', FLib.TryGetTrack(TRACK1_PATH, T));
    AssertEquals('Library title unchanged', 'So What', T.Title);
    AssertTrue('Library flag unchanged', T.HasReplayGain);
    AssertFalse('Not dirty', FLib.IsDirty);
  finally
    L.Free;
  end;
end;

// A list fetched before the library replaces all its records (here by an
// import; a finished scan does the same) keeps complete, unchanged tracks:
// it holds copies, not pointers to the library's records, which are
// disposed by then.
procedure TTestLibraryAccess.TrackListsStayValidWhenTheLibraryIsReplaced;
var
  InMusic, All: TTrackList;
  SL: TStringList;
  T: TTrackInfo;
  I: Integer;
  Track2: PTrackInfo;
begin
  InMusic := TTrackList.Create;
  All     := TTrackList.Create;
  SL      := TStringList.Create;
  try
    FLib.GetTracksInFolderRecursive('D:\Music', InMusic);
    FLib.GetAllTracks(All);
    AssertEquals('One track below D:\Music', 1, InMusic.Count);
    AssertEquals('All tracks', 2, All.Count);

    // A new library: track 1 with another title, track 2 gone (imported
    // from an edited text; the import replaces all records as a
    // load or a finished scan does)
    SampleLines(SL);
    for I := SL.Count - 1 downto 0 do
      if Pos(TRACK2_PATH, SL[I]) = 1 then
        SL.Delete(I)
      else
        SL[I] := StringReplace(SL[I], #9'So What'#9, #9'So What (Take 2)'#9, []);
    SL.SaveToFile(FDir + 'Edited.txt', TEncoding.UTF8);
    AssertEquals('Imported', 1, ImportTextDatabase(FLib, FDir + 'Edited.txt'));

    AssertEquals('Library reloaded', 1, FLib.GetTrackCount);
    AssertTrue('Track 1 still there', FLib.TryGetTrack(TRACK1_PATH, T));
    AssertEquals('Library has the new title', 'So What (Take 2)', T.Title);
    AssertFalse('Track 2 gone from the library', FLib.ContainsTrack(TRACK2_PATH));

    // The copies are untouched
    AssertEquals('Copy keeps its title', 'So What', InMusic[0]^.Title);
    AssertEquals('Copy keeps its path', TRACK1_PATH, InMusic[0]^.FilePath);
    Track2 := nil;
    for I := 0 to All.Count - 1 do
      if All[I]^.FilePath = TRACK2_PATH then
        Track2 := All[I];
    AssertNotNull('Copy of the removed track 2 still there', Track2);
    AssertEquals('...and complete', 'Antonín Dvořák', Track2^.AlbumArtist);
    AssertEquals('...with its line break', 'Largo' + sLineBreak + 'Goin'' Home', Track2^.Title);
  finally
    SL.Free;
    All.Free;
    InMusic.Free;
  end;
end;

procedure TTestLibraryAccess.TrackListGettersFindTheRightTracks;
var
  L: TTrackList;
  Artists, Albums, Genres, Folders: TStringList;
begin
  L       := TTrackList.Create;
  Artists := TStringList.Create;
  Albums  := TStringList.Create;
  Genres  := TStringList.Create;
  Folders := TStringList.Create;
  try
    AssertEquals('Track count', 2, FLib.GetTrackCount);

    // Each getter empties the list first
    FLib.GetAllTracks(L);
    AssertEquals('All tracks', 2, L.Count);
    FLib.GetTracksByGenre('Klassik', L);
    AssertEquals('Genre', 1, L.Count);
    AssertEquals('Genre track', TRACK2_PATH, L[0]^.FilePath);

    FLib.GetTracksInFolder('E:\Klassik\Dvořák\Symphonie Nr. 9', L);
    AssertEquals('Folder', 1, L.Count);
    FLib.GetTracksInFolder('E:\Klassik', L);
    AssertEquals('Not recursive', 0, L.Count);
    FLib.GetTracksInFolderRecursive('E:\Klassik', L);
    AssertEquals('Recursive', 1, L.Count);

    FLib.GetTracksByAlbum('Miles Davis - Kind of Blue', L);
    AssertEquals('Album (artist - album)', 1, L.Count);
    FLib.GetTracksByArtistAndAlbum('Miles Davis', 'Kind of Blue', L);
    AssertEquals('Artist and album', 1, L.Count);
    FLib.GetTracksByGenreAndAlbum('Jazz', 'Kind of Blue', L);
    AssertEquals('Genre and album', 1, L.Count);
    FLib.GetTracksByGenreAndAlbum('Klassik', 'Kind of Blue', L);
    AssertEquals('Wrong genre for the album', 0, L.Count);

    FLib.SearchLibrary('largo', Artists, Albums, Genres, Folders, L);
    AssertEquals('Search: one track', 1, L.Count);
    AssertEquals('Search track', TRACK2_PATH, L[0]^.FilePath);
    AssertEquals('Search: its genre', 'Klassik', Genres.Text.Trim);
  finally
    Folders.Free;
    Genres.Free;
    Albums.Free;
    Artists.Free;
    L.Free;
  end;
end;

{ TTestLibraryStore }

procedure TTestLibraryStore.SetUp;
begin
  FDir    := CreateTestDir;
  FDbFile := FDir + 'library.adb';
  WriteSampleLibrary(FDbFile);
end;

procedure TTestLibraryStore.TearDown;
begin
  RemoveTestTree(FDir);
end;

function TTestLibraryStore.TitleAfterReload(const APath: string): string;
var
  Lib: TLibraryManager;
  T: TTrackInfo;
begin
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('Found after the reload', Lib.TryGetTrack(APath, T));
    Result := T.Title;
  finally
    Lib.IsDirty := False;
    Lib.Free;
  end;
end;

// An edit is in the journal at once: a crash before the next snapshot (here:
// IsDirty cleared, so the destructor writes none) loses nothing
procedure TTestLibraryStore.AnEditSurvivesWithoutASave;
var
  Lib: TLibraryManager;
  T: TTrackInfo;
begin
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('Found', Lib.TryGetTrack(TRACK1_PATH, T));
    T.Title := 'So What (journal)';
    Lib.UpdateRecord(T);
    AssertTrue('Flag changed', Lib.SetReplayGainFlag(TRACK2_PATH, True, 1600000000, 42));
    AssertTrue('Journal written', FileExists(FDir + 'library.jnl'));
    Lib.IsDirty := False;
  finally
    Lib.Free;
  end;
  AssertEquals('The edit came back from the journal', 'So What (journal)', TitleAfterReload(TRACK1_PATH));
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('A replayed journal is merged into the next snapshot', Lib.IsDirty);
    AssertTrue('Track 2 found', Lib.TryGetTrack(TRACK2_PATH, T));
    AssertTrue('ReplayGain flag from the journal', T.HasReplayGain);
    AssertEquals('Date from the journal', 1600000000, T.LastModified);
    AssertEquals('Size from the journal', 42, T.FileSize);
    AssertEquals('The other fields from the snapshot', 'Antonín Dvořák', T.AlbumArtist);
    AssertEquals('No track added', 2, Lib.GetTrackCount);
    Lib.SaveDatabase;
    AssertFalse('Merged', Lib.IsDirty);
  finally
    Lib.Free;
  end;
  AssertEquals('Kept in the new snapshot', 'So What (journal)', TitleAfterReload(TRACK1_PATH));
end;

// A crash right after a snapshot was written, before its new journal was
// started, leaves the old journal: it belongs to the previous snapshot and
// must not be replayed over the newer one
procedure TTestLibraryStore.AJournalOfAnOlderSnapshotIsIgnored;
var
  Lib: TLibraryManager;
  T: TTrackInfo;
  Old: TBytes;
begin
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('Found', Lib.TryGetTrack(TRACK1_PATH, T));
    T.Title := 'Old edit';
    Lib.UpdateRecord(T);
    Old := ReadFileBytes(FDir + 'library.jnl');
    Lib.SaveDatabase;
    T.Title := 'New edit';
    Lib.UpdateRecord(T);
    Lib.SaveDatabase;
  finally
    Lib.Free;
  end;
  WriteFileBytes(FDir + 'library.jnl', Old);
  AssertEquals('The newer snapshot wins', 'New edit', TitleAfterReload(TRACK1_PATH));
end;

procedure TTestLibraryStore.ATornJournalRecordIsIgnored;
var
  Lib: TLibraryManager;
  T: TTrackInfo;
  J: TBytes;
  N: Integer;
begin
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('Found', Lib.TryGetTrack(TRACK1_PATH, T));
    T.Title := 'First edit';
    Lib.UpdateRecord(T);
    T.Title := 'Second edit';
    Lib.UpdateRecord(T);
    Lib.IsDirty := False;
  finally
    Lib.Free;
  end;
  { the second record cut in half, as by a crash during the write }
  J := ReadFileBytes(FDir + 'library.jnl');
  N := Length(J);
  SetLength(J, N - 20);
  WriteFileBytes(FDir + 'library.jnl', J);
  AssertEquals('Up to the last whole record', 'First edit', TitleAfterReload(TRACK1_PATH));

  { a new record after the torn one is read (the torn one was cut off) }
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertTrue('Found', Lib.TryGetTrack(TRACK1_PATH, T));
    T.Title := 'Third edit';
    Lib.UpdateRecord(T);
    Lib.IsDirty := False;
  finally
    Lib.Free;
  end;
  AssertEquals('Appended after the last good record', 'Third edit', TitleAfterReload(TRACK1_PATH));
end;

procedure TTestLibraryStore.ADamagedSnapshotIsKeptAsABackup;
var
  Lib: TLibraryManager;
  B: TBytes;
  SR: TSearchRec;
  Backups: Integer;
begin
  B := ReadFileBytes(FDbFile);
  B[Length(B) div 2] := B[Length(B) div 2] xor $FF;
  WriteFileBytes(FDbFile, B);
  Lib := TLibraryManager.Create(FDbFile);
  try
    Lib.LoadDatabase;
    AssertEquals('Nothing loaded from a damaged file', 0, Lib.GetTrackCount);
  finally
    Lib.Free;
  end;
  Backups := 0;
  if FindFirst(FDir + 'library.adb.*.bak', faAnyFile, SR) = 0 then
  begin
    repeat
      Inc(Backups);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  AssertEquals('The damaged file kept as a backup', 1, Backups);
end;

procedure TTestLibraryStore.StatsSurviveWithoutASave;
var
  S: TUserStatsManager;
  P: PUserTrackStats;
begin
  S := TUserStatsManager.Create(FDir + 'stats.adb');
  try
    S.LoadFromFile;
    S.SetRating('miles davis::kind of blue::so what', 4);
    S.LogPlay('miles davis::kind of blue::so what');
    S.LogPlay('miles davis::kind of blue::so what');
    S.SetFavorite('dvorak::symphonie nr. 9::largo', True);
    S.IsDirty := False;            // a crash: no snapshot
  finally
    S.Free;
  end;
  AssertFalse('No snapshot written', FileExists(FDir + 'stats.adb'));
  S := TUserStatsManager.Create(FDir + 'stats.adb');
  try
    S.LoadFromFile;
    P := S.PeekStats('miles davis::kind of blue::so what');
    AssertNotNull('Entry from the journal', P);
    AssertEquals('Rating', 4, P^.Rating);
    AssertEquals('Plays', 2, P^.PlayCount);
    AssertTrue('Last played set', P^.LastPlayed > 0);
    P := S.PeekStats('dvorak::symphonie nr. 9::largo');
    AssertNotNull('Favorite from the journal', P);
    AssertTrue('Favorite', P^.IsFavorite);
    AssertEquals('A favorite has 5 stars', 5, P^.Rating);
  finally
    S.Free;
  end;
  AssertTrue('Merged into a snapshot on exit', FileExists(FDir + 'stats.adb'));
end;

procedure TTestLibraryStore.StatsSnapshotKeepsEveryValue;
var
  S: TUserStatsManager;
  P: PUserTrackStats;
begin
  S := TUserStatsManager.Create(FDir + 'stats.adb');
  try
    S.LoadFromFile;
    S.SetRating('a::b::c', 3);
    S.LogPlay('a::b::c');
    S.SetRating('only::viewed::once', 0);   // no activity: not stored
    S.SaveToFile;
    AssertFalse('Clean after the save', S.IsDirty);
  finally
    S.Free;
  end;
  S := TUserStatsManager.Create(FDir + 'stats.adb');
  try
    S.LoadFromFile;
    AssertFalse('Nothing to merge', S.IsDirty);
    P := S.PeekStats('a::b::c');
    AssertNotNull('Entry', P);
    AssertEquals('Rating', 3, P^.Rating);
    AssertEquals('Plays', 1, P^.PlayCount);
    AssertNull('An entry without activity is not stored', S.PeekStats('only::viewed::once'));
  finally
    S.Free;
  end;
end;

procedure TTestLibraryStore.ReaderRefusesShortData;
var
  W: TDbWriter;
  R: TDbReader;
  B: TBytes;
  Failed: Boolean;
begin
  W := TDbWriter.Create;
  try
    W.Str('Dvořák');
    W.I64(-5);
    W.U32(7);
    B := W.Bytes;
  finally
    W.Free;
  end;
  R := TDbReader.Create(B);
  try
    AssertEquals('Text', 'Dvořák', R.Str);
    AssertEquals('Int64', -5, R.I64);
    AssertEquals('UInt32', 7, R.U32);
    AssertTrue('At the end', R.AtEnd);
  finally
    R.Free;
  end;
  SetLength(B, Length(B) - 2);
  R := TDbReader.Create(B);
  try
    R.Str;
    R.I64;
    Failed := False;
    try
      R.U32;
    except
      on EDbFormat do Failed := True;
    end;
    AssertTrue('A value past the end is refused', Failed);
  finally
    R.Free;
  end;
  { a length larger than the data }
  B := nil;
  SetLength(B, 4);
  B[0] := $FF;
  B[1] := $FF;
  R := TDbReader.Create(B);
  try
    Failed := False;
    try
      R.Str;
    except
      on EDbFormat do Failed := True;
    end;
    AssertTrue('A text longer than the data is refused', Failed);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TTestLibraryDatabase);
  RegisterTest(TTestLibraryAccess);
  RegisterTest(TTestLibraryStore);

end.
