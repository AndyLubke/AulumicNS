unit TestPlaylistImport;

{$mode ObjFPC}{$H+}
{$codepage UTF8}

{ ==============================================================================
  Project:   Aulumic - test program
  Unit Name: TestPlaylistImport

  Tests for uPlaylistImport (what comes into a playlist from outside):
    TTestM3UFiles          : UTF-8 detection, M3U / M3U8 text with and
                             without BOM, ANSI files (Windows code page),
                             #EXTINF title / length, relative / absolute / UNC
                             paths, comments, empty files, a missing file
    TTestCollectMusicFiles : the music files of dropped / chosen files and
                             folders: name order, files before subfolders,
                             the scanner's skip rules (hidden, system, '.',
                             '$', '.~.'), non-music and missing paths
    TTestImportTracks      : the track of an added file (Add Files / Add
                             Folder / a drop) and of an M3U entry, with
                             generated WAV files (one with an ID3 tag) and a
                             library of one track: library tags, file tags,
                             missing files, #EXTINF info, library-only
                             import; the differences between the two rules
  Only files in a temporary folder are used.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uLibraryTypes, uLibraryManager,
  uPlaylistImport;

type
  TTestM3UFiles = class(TTestCase)
  private
    FDir: string;
    // Writes the byte strings one after the other into FDir + AName
    procedure WriteParts(const AName: string; const AParts: array of RawByteString);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ValidUTF8IsRecognised;
    procedure Utf8WithAndWithoutBOM;
    procedure AnsiFileUsesTheWindowsCodePage;
    procedure EntriesWithExtinfAndPaths;
    procedure EmptyAndCommentOnlyFiles;
    procedure MissingFileRaises;
  end;

  TTestCollectMusicFiles = class(TTestCase)
  private
    FDir  : string;
    FRoot : string;
    FFiles: TStringList;
    // An empty file FRoot + ARelPath (folders are created)
    procedure Touch(const ARelPath: string);
    // FFiles relative to FRoot, comma-separated
    function  Found: string;
    procedure Collect(const APaths: array of string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure FolderFilesFirstThenSubfoldersInNameOrder;
    procedure SkipsHiddenSystemAndTemporaryEntries;
    procedure GivenItemsInNameOrder;
    procedure OnlyMusicFilesAndExistingPaths;
    procedure AddsToTheGivenList;
  end;

  TTestImportTracks = class(TTestCase)
  private
    FDir     : string;
    FLib     : TLibraryManager;
    FTagged  : string;  // title and artist tags, 96 kHz / 24 bit
    FUntagged: string;  // no tags, in the same folder
    FInLib   : string;  // no tags; in the library with tags
    FMissing : string;  // no such file
    function Entry(const APath, AExtTitle: string; AExtSecs: Integer): TM3UEntry;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure M3UEntryInTheLibraryTakesTheLibraryTags;
    procedure M3UEntryOutsideTheLibraryReadsTheFile;
    procedure M3UEntryNotFoundKeepsTheExtinfInfo;
    procedure M3UEntryOnADriveThatDoesNotAnswer;
    procedure OnlyLibraryLeavesTheOthersOut;
    procedure WithoutALibraryTheFileIsRead;
  end;

implementation

uses
  Windows, uAppStrings, uLibraryDatabase, TestHelpers;

const
  // Typed (UTF-8 string): see TestLibraryDatabase
  DVORAK_PATH: string = 'D:\Klassik\Dvořák\02 - Largo.flac';
  CAFE_PATH  : string = 'D:\Music\Café\01.flac';

// A byte string from byte values (independent of the source code page)
function Bytes(const AValues: array of Byte): RawByteString;
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I + 1] := AnsiChar(AValues[I]);
end;

{ TTestM3UFiles }

procedure TTestM3UFiles.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestM3UFiles.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure TTestM3UFiles.WriteParts(const AName: string; const AParts: array of RawByteString);
var
  FS: TFileStream;
  I : Integer;
begin
  FS := TFileStream.Create(FDir + AName, fmCreate);
  try
    for I := 0 to High(AParts) do
      if Length(AParts[I]) > 0 then
        FS.WriteBuffer(AParts[I][1], Length(AParts[I]));
  finally
    FS.Free;
  end;
end;

procedure TTestM3UFiles.ValidUTF8IsRecognised;
begin
  AssertTrue('Empty', IsValidUTF8Bytes(''));
  AssertTrue('ASCII', IsValidUTF8Bytes('D:\Music\01.flac'));
  AssertTrue('2 bytes (é)', IsValidUTF8Bytes(Bytes([$43, $C3, $A9])));
  AssertTrue('3 bytes (€)', IsValidUTF8Bytes(Bytes([$E2, $82, $AC])));
  AssertTrue('4 bytes (U+1F3B5)', IsValidUTF8Bytes(Bytes([$F0, $9F, $8E, $B5])));

  AssertFalse('ANSI é', IsValidUTF8Bytes(Bytes([$43, $E9, $43])));
  AssertFalse('Overlong', IsValidUTF8Bytes(Bytes([$C0, $80])));
  AssertFalse('Cut off', IsValidUTF8Bytes(Bytes([$41, $C3])));
  AssertFalse('Lone continuation byte', IsValidUTF8Bytes(Bytes([$80])));
  AssertFalse('Above U+10FFFF', IsValidUTF8Bytes(Bytes([$F5, $80, $80, $80])));
  AssertFalse('Bad continuation', IsValidUTF8Bytes(Bytes([$C3, $28])));
end;

procedure TTestM3UFiles.Utf8WithAndWithoutBOM;
var
  Entries: TM3UEntries;
  SL: TStringList;
begin
  WriteParts('bom.m3u8', [Bytes([$EF, $BB, $BF]), DVORAK_PATH, #13#10]);
  WriteParts('nobom.m3u8', [DVORAK_PATH, #13#10]);

  SL := TStringList.Create;
  try
    LoadM3UText(FDir + 'bom.m3u8', SL);
    AssertEquals('One line', 1, SL.Count);
    AssertEquals('BOM removed, UTF-8 read', DVORAK_PATH, SL[0]);
  finally
    SL.Free;
  end;

  ParseM3UEntries(FDir + 'bom.m3u8', Entries);
  AssertEquals('With BOM: one entry', 1, Length(Entries));
  AssertEquals('With BOM: path', DVORAK_PATH, Entries[0].Path);

  ParseM3UEntries(FDir + 'nobom.m3u8', Entries);
  AssertEquals('Without BOM: one entry', 1, Length(Entries));
  AssertEquals('Without BOM: path', DVORAK_PATH, Entries[0].Path);
end;

procedure TTestM3UFiles.AnsiFileUsesTheWindowsCodePage;
var
  Entries: TM3UEntries;
begin
  // 'Café' as Windows-1252: é = $E9 (not valid UTF-8)
  if GetACP <> 1252 then
    Ignore('Needs Windows code page 1252 (this system: ' + IntToStr(GetACP) + ')');

  WriteParts('ansi.m3u', ['D:\Music\Caf', Bytes([$E9]), '\01.flac', #13#10]);
  ParseM3UEntries(FDir + 'ansi.m3u', Entries);
  AssertEquals('One entry', 1, Length(Entries));
  AssertEquals('Read as Windows-1252', CAFE_PATH, Entries[0].Path);
end;

procedure TTestM3UFiles.EntriesWithExtinfAndPaths;
var
  Entries: TM3UEntries;
begin
  WriteParts('list.m3u', [
    '#EXTM3U'#13#10,
    '#EXTINF:123,Miles Davis - So What'#13#10,
    'Music\01 - So What.flac'#13#10,
    'D:\Abs\02.flac'#13#10,
    #13#10,
    '# a comment'#13#10,
    '\\server\share\03.flac'#13#10,
    '#extinf:-1,No Length'#13#10,
    '..\Up\04.flac'#13#10,
    '  05.flac  '#13#10]);

  ParseM3UEntries(FDir + 'list.m3u', Entries);
  AssertEquals('Five tracks', 5, Length(Entries));

  AssertEquals('Relative path', ExpandFileName(FDir + 'Music\01 - So What.flac'), Entries[0].Path);
  AssertEquals('#EXTINF title', 'Miles Davis - So What', Entries[0].ExtTitle);
  AssertEquals('#EXTINF length', 123, Entries[0].ExtSecs);

  AssertEquals('Absolute path', 'D:\Abs\02.flac', Entries[1].Path);
  AssertEquals('#EXTINF belongs to one track only', '', Entries[1].ExtTitle);
  AssertEquals('...and its length', 0, Entries[1].ExtSecs);

  AssertEquals('UNC path kept', '\\server\share\03.flac', Entries[2].Path);

  AssertEquals('Relative path with ..', ExpandFileName(FDir + '..\Up\04.flac'), Entries[3].Path);
  AssertEquals('#extinf in lower case', 'No Length', Entries[3].ExtTitle);
  AssertEquals('Unknown length stays -1', -1, Entries[3].ExtSecs);

  AssertEquals('Spaces trimmed', ExpandFileName(FDir + '05.flac'), Entries[4].Path);
end;

procedure TTestM3UFiles.EmptyAndCommentOnlyFiles;
var
  Entries: TM3UEntries;
begin
  WriteParts('empty.m3u', []);
  ParseM3UEntries(FDir + 'empty.m3u', Entries);
  AssertEquals('Empty file', 0, Length(Entries));

  WriteParts('comments.m3u', ['#EXTM3U'#13#10, '# only comments'#13#10,
    '#EXTINF:10,A title without a track'#13#10]);
  ParseM3UEntries(FDir + 'comments.m3u', Entries);
  AssertEquals('Comments only', 0, Length(Entries));
end;

procedure TTestM3UFiles.MissingFileRaises;
var
  Entries: TM3UEntries;
begin
  try
    ParseM3UEntries(FDir + 'nosuch.m3u', Entries);
    Fail('A missing file must raise');
  except
    on E: EFOpenError do
      ; // expected
  end;
end;

{ TTestCollectMusicFiles }

procedure TTestCollectMusicFiles.SetUp;
begin
  FDir   := CreateTestDir;
  FRoot  := FDir + 'Root\';
  FFiles := TStringList.Create;
  ForceDirectories(FRoot);
end;

procedure TTestCollectMusicFiles.TearDown;
begin
  FFiles.Free;
  RemoveTestTree(FDir);
end;

procedure TTestCollectMusicFiles.Touch(const ARelPath: string);
var
  FS: TFileStream;
begin
  ForceDirectories(ExtractFileDir(FRoot + ARelPath));
  FS := TFileStream.Create(FRoot + ARelPath, fmCreate);
  FS.Free;
end;

function TTestCollectMusicFiles.Found: string;
var
  I: Integer;
  S: string;
begin
  Result := '';
  for I := 0 to FFiles.Count - 1 do
  begin
    S := FFiles[I];
    if Pos(FRoot, S) = 1 then
      Delete(S, 1, Length(FRoot));
    if I > 0 then
      Result := Result + ',';
    Result := Result + S;
  end;
end;

procedure TTestCollectMusicFiles.Collect(const APaths: array of string);
var
  Paths: TStringList;
  I: Integer;
begin
  Paths := TStringList.Create;
  try
    for I := 0 to High(APaths) do
      Paths.Add(APaths[I]);
    CollectMusicFiles(Paths, FFiles);
  finally
    Paths.Free;
  end;
end;

procedure TTestCollectMusicFiles.FolderFilesFirstThenSubfoldersInNameOrder;
begin
  Touch('B.flac');
  Touch('a.wav');
  Touch('c.dsf');
  Touch('sub2\z.dsf');
  Touch('Sub1\y.flac');
  Touch('Sub1\Deeper\x.flac');

  Collect([FDir + 'Root']);
  AssertEquals('Files (name order, any case), then each subfolder the same way',
    'a.wav,B.flac,c.dsf,Sub1\y.flac,Sub1\Deeper\x.flac,sub2\z.dsf', Found);
end;

procedure TTestCollectMusicFiles.SkipsHiddenSystemAndTemporaryEntries;
begin
  Touch('keep.flac');
  Touch('._keep.flac');         // macOS metadata file
  Touch('$recycle.flac');       // '$' names
  Touch('song.~.flac');         // temporary file
  Touch('hidden.flac');
  Touch('system.flac');
  Touch('.git\a.flac');         // folder starting with '.'
  Touch('HiddenDir\b.flac');
  Touch('notes.txt');
  Touch('cover.jpg');
  {$PUSH}{$WARN 5044 OFF} // faHidden / faSysFile: Windows-only (so is Aulumic)
  AssertEquals('Hide a file', 0, FileSetAttr(FRoot + 'hidden.flac', faHidden));
  AssertEquals('System file', 0, FileSetAttr(FRoot + 'system.flac', faSysFile));
  AssertEquals('Hide a folder', 0, FileSetAttr(FRoot + 'HiddenDir', faHidden));
  {$POP}

  Collect([FDir + 'Root']);
  AssertEquals('Only the normal music file', 'keep.flac', Found);
end;

procedure TTestCollectMusicFiles.GivenItemsInNameOrder;
begin
  Touch('b.flac');
  Touch('c.flac');
  Touch('A\x.flac');

  // Windows passes a drop in no particular order
  Collect([FRoot + 'c.flac', FRoot + 'b.flac', FRoot + 'A']);
  AssertEquals('Sorted by name', 'A\x.flac,b.flac,c.flac', Found);
end;

procedure TTestCollectMusicFiles.OnlyMusicFilesAndExistingPaths;
begin
  Touch('notes.txt');
  Touch('real.FLAC');

  Collect([FRoot + 'notes.txt', FRoot + 'missing.flac', FRoot + 'real.FLAC',
    FRoot + 'NoSuchFolder']);
  AssertEquals('Only the existing music file (extension in any case)', 'real.FLAC', Found);
end;

procedure TTestCollectMusicFiles.AddsToTheGivenList;
begin
  Touch('one.flac');
  FFiles.Add('already there');

  Collect([FRoot + 'one.flac']);
  AssertEquals('Appended', 'already there,one.flac', Found);

  CollectMusicFiles(nil, FFiles);
  Collect([]);
  AssertEquals('Nothing given, nothing added', 2, FFiles.Count);
end;

{ TTestImportTracks }

procedure TTestImportTracks.SetUp;
var
  T : TTrackInfo;
  SL: TStringList;
begin
  FDir      := CreateTestDir;
  FTagged   := FDir + 'Music\Album A\01 - One.wav';
  FUntagged := FDir + 'Music\Album A\02 - Two.wav';
  FInLib    := FDir + 'Music\Album B\03 - Three.wav';
  FMissing  := FDir + 'Music\Gone\04 - Four.flac';

  WriteTestWav(FTagged, 9600, 96000, 24);
  AddWavId3Tag(FTagged, ['TIT2', 'So What', 'TPE1', 'Miles Davis']);
  WriteTestWav(FUntagged);
  WriteTestWav(FInLib);

  // The library: FInLib with tags (the file itself has none)
  T             := Default(TTrackInfo);
  T.FilePath    := FInLib;
  T.FolderDir   := ExtractFileDir(FInLib);
  T.Title       := 'Three';
  T.Artist      := 'Lib Artist';
  T.AlbumArtist := 'Lib Album Artist';
  T.Album       := 'Lib Album';
  T.Genre       := 'Jazz';
  T.TrackNumber := 3;
  T.DiscNumber  := 2;
  T.DurationStr := '04:05';
  T.Year        := 1959;
  T.DateStr     := '1959-08-17';
  T.SampleRate  := 48000;
  T.BitDepth    := 24;
  SL := TStringList.Create;
  try
    SL.Add(FormatTrackLine(T));
    SL.SaveToFile(FDir + 'Library.db', TEncoding.UTF8);
  finally
    SL.Free;
  end;
  // ---> AulumicNS: Aulumic's text library imported (the store is library.adb)
  FLib := TLibraryManager.Create(FDir + 'library.adb');
  ImportAulumicDatabase(FLib, FDir + 'Library.db');
end;

procedure TTestImportTracks.TearDown;
begin
  FreeAndNil(FLib);
  RemoveTestTree(FDir);
end;

function TTestImportTracks.Entry(const APath, AExtTitle: string; AExtSecs: Integer): TM3UEntry;
begin
  Result.Path     := APath;
  Result.ExtTitle := AExtTitle;
  Result.ExtSecs  := AExtSecs;
end;

procedure TTestImportTracks.M3UEntryInTheLibraryTakesTheLibraryTags;
var
  T: TTrackInfo;
begin
  AssertEquals('Library loaded', 1, FLib.GetTrackCount);
  AssertTrue('From the library',
    TrackFromM3UEntry(Entry(FInLib, 'Ext Title', 125), FLib, False, T) = msLibrary);
  AssertEquals('Path', FInLib, T.FilePath);
  AssertEquals('Folder from the path', FDir + 'Music\Album B', T.FolderDir);
  AssertEquals('Library title before #EXTINF', 'Three', T.Title);
  AssertEquals('Artist', 'Lib Artist', T.Artist);
  AssertEquals('Album artist', 'Lib Album Artist', T.AlbumArtist);
  AssertEquals('Album', 'Lib Album', T.Album);
  AssertEquals('Genre', 'Jazz', T.Genre);
  AssertEquals('Track', 3, T.TrackNumber);
  AssertEquals('Disc', 2, T.DiscNumber);
  AssertEquals('Library length before #EXTINF', '04:05', T.DurationStr);
  AssertEquals('Year', 1959, T.Year);
  AssertEquals('Date', '1959-08-17', T.DateStr);
  AssertEquals('Sample rate (library, not file)', 48000, T.SampleRate);
  AssertEquals('Bit depth', 24, T.BitDepth);
end;

procedure TTestImportTracks.M3UEntryOutsideTheLibraryReadsTheFile;
var
  T: TTrackInfo;
begin
  AssertTrue('Tagged file',
    TrackFromM3UEntry(Entry(FTagged, 'Ext Title', 125), FLib, False, T) = msFile);
  AssertEquals('Title tag before #EXTINF', 'So What', T.Title);
  AssertEquals('Artist', 'Miles Davis', T.Artist);
  AssertEquals('No album artist: the artist', 'Miles Davis', T.AlbumArtist);
  AssertEquals('Sample rate', 96000, T.SampleRate);
  AssertTrue('Length of the file', (T.DurationStr <> '') and (T.DurationStr <> '2:05'));

  // The tag reader gives a file without a title tag its name without the
  // extension, which comes before the #EXTINF title
  AssertTrue('Untagged file',
    TrackFromM3UEntry(Entry(FUntagged, 'Ext Title', 0), FLib, False, T) = msFile);
  AssertEquals('No title tag: the reader''s file name', '02 - Two', T.Title);
  AssertEquals('No album artist', '', T.AlbumArtist);
  AssertEquals('No album', '', T.Album);
  AssertEquals('Sample rate', 44100, T.SampleRate);
end;

procedure TTestImportTracks.M3UEntryNotFoundKeepsTheExtinfInfo;
var
  T: TTrackInfo;
begin
  AssertTrue('Not found',
    TrackFromM3UEntry(Entry(FMissing, 'Gone Song', 125), FLib, False, T) = msNotFound);
  AssertEquals('Path', FMissing, T.FilePath);
  AssertEquals('Folder', FDir + 'Music\Gone', T.FolderDir);
  AssertEquals('#EXTINF title', 'Gone Song', T.Title);
  AssertEquals('#EXTINF length', '2:05', T.DurationStr);

  TrackFromM3UEntry(Entry(FMissing, '', 3605), FLib, False, T);
  AssertEquals('No #EXTINF title: the file name', '04 - Four.flac', T.Title);
  AssertEquals('Long length in minutes', '60:05', T.DurationStr);

  TrackFromM3UEntry(Entry(FMissing, '', -1), FLib, False, T);
  AssertEquals('Unknown length', '', T.DurationStr);
end;

// ---> ADDED: An entry on a network drive whose server does not answer
// (ADriveAnswers = False): outside the library it is left out and its file is
// not read (the file here exists and has tags); a library track is kept
procedure TTestImportTracks.M3UEntryOnADriveThatDoesNotAnswer;
var
  T: TTrackInfo;
begin
  T.Title := 'Old';
  AssertTrue('Outside the library: left out',
    TrackFromM3UEntry(Entry(FTagged, 'Ext Title', 125), FLib, False, T, False) = msDriveNotAnswering);
  AssertEquals('Empty track', '', T.FilePath);
  AssertEquals('Empty title', '', T.Title);

  AssertTrue('In the library: the library''s tags as always',
    TrackFromM3UEntry(Entry(FInLib, '', 0), FLib, False, T, False) = msLibrary);
  AssertEquals('Library title', 'Three', T.Title);

  AssertTrue('Only library tracks: left out as before',
    TrackFromM3UEntry(Entry(FTagged, '', 0), FLib, True, T, False) = msLeftOut);

  AssertTrue('The drive answers: the file is read as before',
    TrackFromM3UEntry(Entry(FTagged, 'Ext Title', 125), FLib, False, T, True) = msFile);
end;

procedure TTestImportTracks.OnlyLibraryLeavesTheOthersOut;
var
  T: TTrackInfo;
begin
  T.Title := 'Old';
  AssertTrue('Outside the library: left out',
    TrackFromM3UEntry(Entry(FTagged, 'Ext', 10), FLib, True, T) = msLeftOut);
  AssertEquals('Empty track', '', T.FilePath);
  AssertEquals('Empty title', '', T.Title);

  AssertTrue('Missing file: left out too',
    TrackFromM3UEntry(Entry(FMissing, '', 0), FLib, True, T) = msLeftOut);

  AssertTrue('In the library: imported',
    TrackFromM3UEntry(Entry(FInLib, '', 0), FLib, True, T) = msLibrary);
  AssertEquals('Library title', 'Three', T.Title);
end;

procedure TTestImportTracks.WithoutALibraryTheFileIsRead;
var
  T: TTrackInfo;
begin
  AssertTrue('No library: the file',
    TrackFromM3UEntry(Entry(FInLib, '', 0), nil, False, T) = msFile);
  AssertEquals('The file''s name (it has no title tag)', '03 - Three', T.Title);
  AssertEquals('Sample rate of the file', 44100, T.SampleRate);

  AssertTrue('No library, only library tracks: left out',
    TrackFromM3UEntry(Entry(FInLib, '', 0), nil, True, T) = msLeftOut);
end;

initialization
  RegisterTest(TTestM3UFiles);
  RegisterTest(TTestCollectMusicFiles);
  RegisterTest(TTestImportTracks);

end.
