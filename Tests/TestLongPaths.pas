unit TestLongPaths;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   AulumicNS - test program
  Unit Name: TestLongPaths

  Files whose path has 260 characters or more (Windows' MAX_PATH): the file
  calls take the \\?\ form (AuAudioTypes.LongPath). Before, such a file was
  listed by the scan but could not be opened: it was not in the library, and
  every scan "had changes" (the library was replaced and saved at each start).

  A FLAC file is written at a short path and moved into nested folders so its
  path has about 300 characters. Then: the tags are read, the scan finds it
  and a second scan reports no changes, a tag is written and read back (the
  temporary file next to it has an even longer name), and the player's reader
  opens it.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uLibraryManager, uLibraryTypes;

type
  TTestLongPaths = class(TTestCase)
  private
    FDir       : string;
    FMusic     : string;
    FLongDir   : string;
    FFile      : string;
    FLib       : TLibraryManager;
    FDoneCount : Integer;
    FLastChange: Boolean;
    procedure ScanDone(Sender: TObject; HasChanges: Boolean);
    procedure RunScan;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure LongPathLeavesOtherPathsAlone;
    procedure TheFileIsReallyBeyondMaxPath;
    procedure TagsAreRead;
    procedure ScanFindsItAndTheNextScanHasNoChanges;
    procedure TagIsWrittenAndReadBack;
    procedure ThePlayerOpensIt;
    procedure ACoverPictureIsLoaded;
    procedure ABookletIsRendered;
  end;

implementation

uses
  Windows, AuAudioTypes, ALMetadata, AudioTag, baseTag, ALReaderFLAC, TestHelpers,
  AuGfx, AuPdf, AuDemoLibrary;

{ every folder and file below ADir, then ADir (\\?\ paths) }
procedure RemoveLongTree(const ADir: string);
var
  SR: TSearchRec;
  P: string;
begin
  if FindFirst(LongPath(ADir + '\*'), faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        P := ADir + '\' + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then RemoveLongTree(P)
        else Windows.DeleteFileW(PWideChar(UTF8Decode(LongPath(P))));
      until FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
  end;
  Windows.RemoveDirectoryW(PWideChar(UTF8Decode(LongPath(ADir))));
end;

{ TTestLongPaths }

procedure TTestLongPaths.SetUp;
const
  PART = 'A folder name of forty characters - 0123';
var
  Short: string;
begin
  FDir   := CreateTestDir;
  FMusic := FDir + 'Music';
  AssertTrue('Music folder', ForceDirectories(FMusic));
  FLongDir := FMusic;
  while Length(FLongDir) < 250 do
  begin
    FLongDir := FLongDir + '\' + PART;
    AssertTrue('Folder made: ' + IntToStr(Length(FLongDir)),
      Windows.CreateDirectoryW(PWideChar(UTF8Decode(LongPath(FLongDir))), nil));
  end;
  FFile := FLongDir + '\01 - A track with a long name in a long folder.flac';
  Short := FDir + 'short.flac';
  WritePatternFlac(Short, 4410);
  AssertTrue('Moved to the long path',
    Windows.MoveFileW(PWideChar(UTF8Decode(Short)), PWideChar(UTF8Decode(LongPath(FFile)))));

  FLib := TLibraryManager.Create(FDir + 'library.adb');
  FLib.OnScanDone := @ScanDone;
  FLib.AddScanFolder(FMusic);
  FDoneCount := 0;
end;

procedure TTestLongPaths.TearDown;
begin
  FreeAndNil(FLib);
  RemoveLongTree(FMusic);
  RemoveTestTree(FDir);
end;

procedure TTestLongPaths.ScanDone(Sender: TObject; HasChanges: Boolean);
begin
  Inc(FDoneCount);
  FLastChange := HasChanges;
end;

procedure TTestLongPaths.RunScan;
var
  Before: Integer;
  Start: QWord;
begin
  Before := FDoneCount;
  FLib.StartScan(False);
  Start := GetTickCount64;
  while FLib.IsScanning do
  begin
    CheckSynchronize(20);
    if GetTickCount64 - Start > 30000 then
      Fail('The scan did not end within 30 s');
  end;
  AssertEquals('OnScanDone once', Before + 1, FDoneCount);
end;

procedure TTestLongPaths.LongPathLeavesOtherPathsAlone;
var
  Long: string;
begin
  Long := 'C:\' + StringOfChar('a', 250) + '\file.flac';
  AssertEquals('Short path', 'C:\Music\a.flac', LongPath('C:\Music\a.flac'));
  AssertEquals('Long drive path', '\\?\' + Long, LongPath(Long));
  AssertEquals('Already prefixed', '\\?\' + Long, LongPath('\\?\' + Long));
  AssertEquals('UNC', '\\?\UNC\server\share\' + StringOfChar('a', 250),
    LongPath('\\server\share\' + StringOfChar('a', 250)));
  AssertEquals('Relative path', StringOfChar('a', 250) + '\x.flac',
    LongPath(StringOfChar('a', 250) + '\x.flac'));
  AssertEquals('Forward slashes', 'C:/' + StringOfChar('a', 250),
    LongPath('C:/' + StringOfChar('a', 250)));
  AssertEquals('Parent folder inside', 'C:\' + StringOfChar('a', 250) + '\..\x',
    LongPath('C:\' + StringOfChar('a', 250) + '\..\x'));
  AssertEquals('Empty', '', LongPath(''));
end;

procedure TTestLongPaths.TheFileIsReallyBeyondMaxPath;
begin
  AssertTrue('Path of 260 characters or more: ' + IntToStr(Length(FFile)), Length(FFile) >= 260);
  AssertTrue('There with the \\?\ form', FileExists(LongPath(FFile)));
end;

procedure TTestLongPaths.TagsAreRead;
var
  M: TAudioMetadata;
begin
  M := ReadTrackMetadata(FFile, False);
  AssertEquals('Sample rate from the file', 44100, M.SampleRate);
  AssertEquals('Bit depth from the file', 16, M.BitDepth);
end;

procedure TTestLongPaths.ScanFindsItAndTheNextScanHasNoChanges;
var
  T: TTrackInfo;
begin
  RunScan;
  AssertTrue('First scan: changes', FLastChange);
  AssertEquals('One track', 1, FLib.GetTrackCount);
  AssertTrue('In the library', FLib.TryGetTrack(FFile, T));
  AssertEquals('Folder', FLongDir, T.FolderDir);
  AssertEquals('Sample rate', 44100, T.SampleRate);
  AssertTrue('Size stored', T.FileSize > 0);

  RunScan;
  AssertFalse('Second scan: no changes', FLastChange);
  AssertEquals('Still one track', 1, FLib.GetTrackCount);
end;

procedure TTestLongPaths.TagIsWrittenAndReadBack;
var
  R: TTagReader;
  C: TCommonTags;
  M: TAudioMetadata;
  Temp: string;
begin
  R := GetFileTagsObject(FFile);
  try
    C := R.GetCommonTags;
    C.Title := 'Written into a long path';
    C.Artist := 'Test Artist';
    R.SetCommonTags(C);
    AssertTrue('Saved: ' + R.LastUpdateError, R.UpdateFile);
  finally
    R.Free;
  end;
  M := ReadTrackMetadata(FFile, False);
  AssertEquals('Title read back', 'Written into a long path', M.Title);
  AssertEquals('Artist read back', 'Test Artist', M.Artist);
  AssertEquals('Still a FLAC file of 44.1 kHz', 44100, M.SampleRate);
  Temp := ChangeFileExt(FFile, '.~.' + ExtractFileExt(FFile));
  AssertFalse('No temporary file left', FileExists(LongPath(Temp)));
end;

procedure TTestLongPaths.ThePlayerOpensIt;
var
  R: TFlacReader;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  R := TFlacReader.Create(FFile);
  try
    AssertEquals('Sample rate', 44100, Integer(R.SampleRate));
    N := R.ReadData(@Buf[0], SizeOf(Buf));
    AssertTrue('Audio read', N > 0);
  finally
    R.Free;
  end;
end;

{ a JPEG of 64 x 48 pixels at a short path; its bytes }
function MakeJpeg(const AFile: string): TBytes;
var
  B: TGfxBitmap;
begin
  B := TGfxBitmap.Create(64, 48);
  try
    if not SaveBitmapJpeg(B, AFile) then
      raise Exception.Create('The JPEG could not be written');
  finally
    DisposeBitmap(B);
  end;
  Result := ReadFileBytes(AFile);
end;

procedure TTestLongPaths.ACoverPictureIsLoaded;
var
  Pic: string;
  B: TGfxBitmap;
  W, H: Integer;
begin
  MakeJpeg(FDir + 'c.jpg');
  Pic := FLongDir + '\folder.jpg';
  AssertTrue('Moved', Windows.MoveFileW(PWideChar(UTF8Decode(FDir + 'c.jpg')),
    PWideChar(UTF8Decode(LongPath(Pic)))));
  AssertTrue('Path of 260 characters or more', Length(Pic) >= 260);
  B := ImageFromFile(Pic, 0);
  AssertTrue('Picture decoded', B <> nil);
  try
    AssertTrue('Size known', BitmapSize(B, W, H));
    AssertEquals('Width', 64, W);
    AssertEquals('Height', 48, H);
  finally
    DisposeBitmap(B);
  end;
end;

procedure TTestLongPaths.ABookletIsRendered;
var
  Pdf: string;
  Jpeg: TBytes;
  Pages: TStringList;
  R: TAuPdfRenderer;
  Res: TAuPdfResults;
  Start: QWord;
  I: Integer;
begin
  if not PdfEngineAvailable then
  begin
    Ignore('No PDF engine in this Windows');
    Exit;
  end;
  Jpeg := MakeJpeg(FDir + 'c.jpg');
  Pages := TStringList.Create;
  try
    Pages.Add('Tracks' + LineEnding + '1. One (1:00)');
    AssertTrue('PDF written', WriteDemoBookletPdf(FDir + 'b.pdf', Jpeg, 64, 48, Pages));
  finally
    Pages.Free;
  end;
  Pdf := FLongDir + '\An album - Booklet.pdf';
  AssertTrue('Moved', Windows.MoveFileW(PWideChar(UTF8Decode(FDir + 'b.pdf')),
    PWideChar(UTF8Decode(LongPath(Pdf)))));
  AssertTrue('Path of 260 characters or more', Length(Pdf) >= 260);

  R := TAuPdfRenderer.Create(Pdf);
  try
    Start := GetTickCount64;
    while (not R.Loaded) and (GetTickCount64 - Start < 15000) do Sleep(10);
    AssertTrue('Loaded', R.Loaded);
    AssertEquals('No error', '', R.Error);
    AssertTrue('Pages: ' + IntToStr(R.PageCount), R.PageCount >= 1);
    R.Request(0, 200);
    Res := nil;
    Start := GetTickCount64;
    while (Length(Res) = 0) and (GetTickCount64 - Start < 15000) do
    begin
      Sleep(10);
      Res := R.TakeResults;
    end;
    AssertTrue('A page was rendered', Length(Res) > 0);
    for I := 0 to High(Res) do
      if Res[I].Bitmap <> nil then DisposeBitmap(Res[I].Bitmap);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TTestLongPaths);

end.
