unit TestLibraryScanner;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestLibraryScanner
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for the library scan (TLibraryManager.StartScan with the
  TLibraryScannerThread of uLibraryScanner) on a temporary folder with small
  generated WAV files: the first scan finds every file, a refresh notices an
  added, a changed and a deleted file, a refresh without changes reports no
  changes, the full rebuild reads unchanged files again and keeps their
  "date added", and progress is reported. The scan runs on its own thread; the
  test waits for it with CheckSynchronize (progress and the end of the scan
  are delivered to the main thread with TThread.Queue / Synchronize).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uLibraryManager, uLibraryTypes;

type
  TTestLibraryScanner = class(TTestCase)
  private
    FDir        : string;
    FMusic      : string;
    FLib        : TLibraryManager;
    FDoneCount  : Integer;
    FLastChange : Boolean;
    FProgress   : Integer;
    procedure ScanDone(Sender: TObject; HasChanges: Boolean);
    procedure ScanProgress(Sender: TObject; const ScanMsg: string;
      const CurrentFolder: string; TrackCount, TotalTracks: Integer);
    // Starts a scan (a refresh, or with AFullRebuild the full rebuild of
    // Preferences > Repair) and waits until it has ended (fails after 30 s)
    procedure RunScan(AFullRebuild: Boolean = False);
    function  HasTrack(const APath: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure FirstScanFindsEveryFile;
    procedure RefreshNoticesAddedChangedAndDeletedFiles;
    procedure RefreshWithoutChangesReportsNoChanges;
    procedure FullRebuildRereadsUnchangedFiles;
    procedure ARebuildFillsTheWorksOfAnOlderLibrary;
    procedure ReplayGainNeedsAnAlbumGainOnlyWithAnAlbumTag;
  end;

implementation

uses
  DateUtils, uLibraryDatabase, uAppConsts, uAppStrings, uDbStore, TestHelpers;

{ TTestLibraryScanner }

procedure TTestLibraryScanner.SetUp;
begin
  FDir   := CreateTestDir;
  FMusic := FDir + 'Music';
  WriteTestWav(FMusic + '\Album A\01 - One.wav');
  WriteTestWav(FMusic + '\Album A\02 - Two.wav');
  WriteTestWav(FMusic + '\Album B\01 - Three.wav', 8820, 96000, 24);

  FLib := TLibraryManager.Create(FDir + 'library.adb');
  FLib.OnScanDone     := @ScanDone;
  FLib.OnScanProgress := @ScanProgress;
  FLib.AddScanFolder(FMusic);
  FDoneCount := 0;
  FProgress  := 0;
end;

procedure TTestLibraryScanner.TearDown;
begin
  FreeAndNil(FLib);
  // The scan folders are subfolders of FDir; remove them first
  RemoveTestDir(FMusic + '\Album A');
  RemoveTestDir(FMusic + '\Album B');
  RemoveTestDir(FMusic);
  RemoveTestDir(FDir);
end;

procedure TTestLibraryScanner.ScanDone(Sender: TObject; HasChanges: Boolean);
begin
  Inc(FDoneCount);
  FLastChange := HasChanges;
end;

procedure TTestLibraryScanner.ScanProgress(Sender: TObject; const ScanMsg: string;
  const CurrentFolder: string; TrackCount, TotalTracks: Integer);
begin
  Inc(FProgress);
end;

procedure TTestLibraryScanner.RunScan(AFullRebuild: Boolean);
var
  Before : Integer;
  Start  : QWord;
begin
  Before := FDoneCount;
  FLib.StartScan(AFullRebuild);
  AssertTrue('Scan started', FLib.IsScanning);
  Start := GetTickCount64;
  while FLib.IsScanning do
  begin
    CheckSynchronize(20);
    if GetTickCount64 - Start > 30000 then
      Fail('The scan did not end within 30 s');
  end;
  AssertEquals('OnScanDone once', Before + 1, FDoneCount);
end;

function TTestLibraryScanner.HasTrack(const APath: string): Boolean;
var
  T: TTrackInfo;
begin
  Result := FLib.TryGetTrack(APath, T);
end;

// "Has ReplayGain" = a track gain and an album gain; a track
// without an album tag cannot get an album gain: its track gain is enough
procedure TTestLibraryScanner.ReplayGainNeedsAnAlbumGainOnlyWithAnAlbumTag;
var
  T: TTrackInfo;
begin
  // album tag, track gain only: still to scan
  AddWavId3Tag(FMusic + '\Album A\01 - One.wav',
    ['TALB', 'Album A', 'TXXX', 'REPLAYGAIN_TRACK_GAIN'#0'-6.00 dB']);
  // album tag, both gains
  AddWavId3Tag(FMusic + '\Album A\02 - Two.wav',
    ['TALB', 'Album A', 'TXXX', 'REPLAYGAIN_TRACK_GAIN'#0'-6.00 dB',
     'TXXX', 'REPLAYGAIN_ALBUM_GAIN'#0'-7.00 dB']);
  // no album tag, track gain only: nothing more to get
  AddWavId3Tag(FMusic + '\Album B\01 - Three.wav',
    ['TXXX', 'REPLAYGAIN_TRACK_GAIN'#0'-6.00 dB']);
  RunScan;
  AssertTrue('One', FLib.TryGetTrack(FMusic + '\Album A\01 - One.wav', T));
  AssertEquals('Its album', 'Album A', T.Album);
  AssertFalse('With an album tag a track gain alone is not enough', T.HasReplayGain);
  AssertTrue('Two', FLib.TryGetTrack(FMusic + '\Album A\02 - Two.wav', T));
  AssertTrue('Both gains', T.HasReplayGain);
  AssertTrue('Three', FLib.TryGetTrack(FMusic + '\Album B\01 - Three.wav', T));
  AssertEquals('No album tag: the library''s placeholder', LBL_UNKNOWN_ALBUM, T.Album);
  AssertTrue('Without an album tag the track gain is all there is', T.HasReplayGain);
end;

// The snapshot as a version without the Work field wrote it: without the
// block of the works behind its tracks (the magic, a flag byte and one text
// id per track)
procedure StripWorksBlock(const AFile: string; ATracks: Integer);
var
  Gen: QWord;
  Body: TBytes;
  Err: string;
begin
  if not LoadSnapshot(AFile, 'AUNSLIBR', Gen, Body, Err) then
    raise Exception.Create('The snapshot could not be read: ' + Err);
  SetLength(Body, Length(Body) - (4 + 1 + 4 * ATracks));
  if not SaveSnapshot(AFile, 'AUNSLIBR', Gen, Body, Err) then
    raise Exception.Create('The snapshot could not be written: ' + Err);
end;

// A scan reads the work from the tag. A library written without the works
// (by an earlier version) says so, keeps saying so after a save and after a
// refresh, and knows them again after a rebuild.
procedure TTestLibraryScanner.ARebuildFillsTheWorksOfAnOlderLibrary;
var
  One: string;
  T: TTrackInfo;

  procedure Reopen;
  begin
    FreeAndNil(FLib);
    FLib := TLibraryManager.Create(FDir + 'library.adb');
    FLib.OnScanDone     := @ScanDone;
    FLib.OnScanProgress := @ScanProgress;
    FLib.LoadDatabase;
  end;

begin
  One := FMusic + '\Album A\01 - One.wav';
  AddWavId3Tag(One, ['TALB', 'Album A', 'TXXX', 'WORK'#0'Symphony No. 9']);
  RunScan;
  AssertTrue('Found', FLib.TryGetTrack(One, T));
  AssertEquals('The work from the tag', 'Symphony No. 9', T.Work);
  AssertFalse('A library made here knows its works', FLib.NeedsRebuildForWorks);
  FLib.SaveDatabase;

  Reopen;
  AssertFalse('Nor does a reload ask for a rebuild', FLib.NeedsRebuildForWorks);
  AssertTrue('Found again', FLib.TryGetTrack(One, T));
  AssertEquals('The work from the snapshot', 'Symphony No. 9', T.Work);

  // the same library as an earlier version wrote it
  FLib.IsDirty := False;
  FreeAndNil(FLib);
  StripWorksBlock(FDir + 'library.adb', 3);
  Reopen;
  AssertEquals('The tracks are all there', 3, FLib.GetTrackCount);
  AssertTrue('It has to be rebuilt', FLib.NeedsRebuildForWorks);
  AssertTrue('Found', FLib.TryGetTrack(One, T));
  AssertEquals('No work is known', '', T.Work);
  AssertEquals('The other fields are', 'Album A', T.Album);

  // saved by this version: the question stays
  FLib.IsDirty := True;
  FLib.SaveDatabase;
  Reopen;
  AssertTrue('Still to be rebuilt after a save', FLib.NeedsRebuildForWorks);

  // a refresh reads no unchanged file
  RunScan;
  AssertTrue('Still to be rebuilt after a refresh', FLib.NeedsRebuildForWorks);
  AssertTrue('Found', FLib.TryGetTrack(One, T));
  AssertEquals('Still no work', '', T.Work);

  // the rebuild
  RunScan(True);
  AssertTrue('The rebuild counts as a change', FLastChange);
  AssertFalse('Rebuilt', FLib.NeedsRebuildForWorks);
  AssertTrue('Found', FLib.TryGetTrack(One, T));
  AssertEquals('The work is back', 'Symphony No. 9', T.Work);
  FLib.SaveDatabase;
  Reopen;
  AssertFalse('And it stays so', FLib.NeedsRebuildForWorks);
  AssertTrue('Found', FLib.TryGetTrack(One, T));
  AssertEquals('The work after the reload', 'Symphony No. 9', T.Work);
end;

procedure TTestLibraryScanner.FirstScanFindsEveryFile;
var
  T: TTrackInfo;
begin
  RunScan;
  AssertTrue('Changes reported', FLastChange);
  AssertTrue('Progress reported', FProgress > 0);
  AssertEquals('Three tracks', 3, FLib.GetTrackCount);
  AssertFalse('All folders reachable', FLib.LastScanHadUnavailableRoots);

  AssertTrue('Album B track', FLib.TryGetTrack(FMusic + '\Album B\01 - Three.wav', T));
  AssertEquals('Folder', FMusic + '\Album B', T.FolderDir);
  AssertEquals('Sample rate read from the file', 96000, T.SampleRate);
  AssertEquals('Bit depth read from the file', 24, T.BitDepth);
  AssertTrue('Size stored', T.FileSize > 0);
  AssertTrue('Date stored', T.LastModified > 0);
  AssertEquals('Search fields filled', LowerCase(T.FolderDir), T.CleanFolder);
end;

procedure TTestLibraryScanner.RefreshNoticesAddedChangedAndDeletedFiles;
var
  Changed : string;
  Before, After: TTrackInfo;
begin
  RunScan;
  Changed := FMusic + '\Album A\01 - One.wav';
  AssertTrue('Found before', FLib.TryGetTrack(Changed, Before));

  // Added, changed (longer, other date), deleted
  WriteTestWav(FMusic + '\Album B\02 - Four.wav');
  WriteTestWav(Changed, 44100);
  FileSetDate(Changed, DateTimeToFileDate(IncMinute(Now, 5)));
  DeleteFile(FMusic + '\Album A\02 - Two.wav');

  RunScan;
  AssertTrue('Changes reported', FLastChange);
  AssertEquals('Three tracks again (one added, one deleted)', 3, FLib.GetTrackCount);
  AssertTrue('Added file found', HasTrack(FMusic + '\Album B\02 - Four.wav'));
  AssertFalse('Deleted file gone', HasTrack(FMusic + '\Album A\02 - Two.wav'));
  AssertTrue('Changed file still there', FLib.TryGetTrack(Changed, After));
  AssertTrue('New size read', After.FileSize > Before.FileSize);
  AssertTrue('New date read', After.LastModified <> Before.LastModified);
end;

procedure TTestLibraryScanner.RefreshWithoutChangesReportsNoChanges;
begin
  RunScan;
  AssertTrue('First scan: changes', FLastChange);
  RunScan;
  AssertFalse('Second scan: no changes', FLastChange);
  AssertEquals('Still three tracks', 3, FLib.GetTrackCount);
end;

// The full rebuild (Preferences > Repair; the scanner without IsRefresh)
// reads every file again, also one whose date did not change, which a
// refresh keeps as it is. Each track keeps its "date added". (The rebuild
// also empties the thumbnail cache: in the test that is the Cache\Thumbs
// folder next to the test program, not the program's.)
procedure TTestLibraryScanner.FullRebuildRereadsUnchangedFiles;
const
  OLD_DATE_ADDED = 1500000000; // 14 Jul 2017
var
  Path  : string;
  OldAge: LongInt;
  T     : TTrackInfo;
  SL    : TStringList;
  I     : Integer;
  Tracks: TTrackInfoArray;
begin
  RunScan;
  Path := FMusic + '\Album A\01 - One.wav';
  AssertTrue('Found after the first scan', FLib.TryGetTrack(Path, T));
  AssertEquals('Sample rate before', 44100, T.SampleRate);

  // An old "date added" for this track (as in a library that has existed for
  // years): written as the tests' text library with the old date,
  // imported, saved as AulumicNS' snapshot and loaded again
  SL := TStringList.Create;
  try
    FLib.GetScanFolders(SL);
    for I := 0 to SL.Count - 1 do
      SL[I] := DB_FOLDER_MARKER + EncodeDbField(SL[I]);
    Tracks := FLib.SnapshotTracks;
    for I := 0 to High(Tracks) do
    begin
      T := Tracks[I];
      if SameFileName(T.FilePath, Path) then
        T.DateAdded := OLD_DATE_ADDED;
      SL.Add(FormatTrackLine(T));
    end;
    SL.SaveToFile(FDir + 'Edited.txt', TEncoding.UTF8);
  finally
    SL.Free;
  end;
  AssertEquals('Imported', 3, ImportTextDatabase(FLib, FDir + 'Edited.txt'));
  FLib.SaveDatabase;
  FLib.LoadDatabase;
  AssertTrue('Found after loading', FLib.TryGetTrack(Path, T));
  AssertEquals('Old date added loaded', OLD_DATE_ADDED, T.DateAdded);

  // Other content (96 kHz / 24 bit), but the old file date
  OldAge := FileAge(Path);
  WriteTestWav(Path, 9600, 96000, 24);
  AssertEquals('Old file date restored', 0, FileSetDate(Path, OldAge));

  RunScan;
  AssertTrue('Found after the refresh', FLib.TryGetTrack(Path, T));
  AssertEquals('A refresh keeps the stored record (same date)', 44100, T.SampleRate);

  FProgress := 0;
  RunScan(True);
  AssertTrue('A full rebuild always reports changes', FLastChange);
  AssertTrue('Progress reported', FProgress > 0);
  AssertEquals('Still three tracks', 3, FLib.GetTrackCount);
  AssertTrue('Found after the full rebuild', FLib.TryGetTrack(Path, T));
  AssertEquals('The full rebuild read the file again: sample rate', 96000, T.SampleRate);
  AssertEquals('...and bit depth', 24, T.BitDepth);
  AssertEquals('Date added kept', OLD_DATE_ADDED, T.DateAdded);
  AssertTrue('Other tracks still there', HasTrack(FMusic + '\Album B\01 - Three.wav'));
end;

initialization
  RegisterTest(TTestLibraryScanner);

end.
