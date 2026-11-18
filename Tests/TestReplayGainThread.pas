unit TestReplayGainThread;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic - test program (---> AulumicNS: ported, milestone 5)
  Unit Name: TestReplayGainThread

  Runs the real ReplayGain scan thread (TReplayGainThread) on
  generated WAV files and checks what it reports through its events:
    * a 1 kHz tone at -23 dBFS (EBU Tech 3341 test 1: -23 LUFS) gets +5 dB,
      its peak is its level
    * silent tracks get 0 dB
    * an album with a broken file: decode error, the rest "album incomplete"
    * an album with a missing file: file missing, the rest "album incomplete"
    * the album name falls back to the folder name (no library, no tags)
    * progress events arrive; Detach stops the events
    * ---> ADDED: a folder and a file with non-ASCII names (TestHelpers.
      NonAsciiName) are measured, the album name comes back intact
    * ---> AulumicNS: the album gain gates the blocks of all tracks together
      (a -23 and a -33 dBFS tone: -25.6 LUFS, +7.6 dB)
  ---> AulumicNS: the loudness is measured by the built-in EBU R128 meter
  (AuLoudness), so no DLL is needed and no test is skipped.
  The thread ends on its own; the test waits with CheckSynchronize (its
  events and log lines are delivered with Synchronize).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uReplayGainScan, uReplayGainThread;

type
  TTestReplayGainThread = class(TTestCase)
  private
    FDir          : string;
    FResults      : TList;     // PRGScanResult, taken over from the thread
    FProgressCount: Integer;
    FLastProgress : TRGProgress;
    FThreads      : Integer;   // TReplayGainThread.ThreadCount of RunScan
    FStopAtProgress: Boolean;  // RunScan stops the scan at its first progress
    FScanThread   : TReplayGainThread;
    FLooseTracks  : Boolean;   // Group leaves the files without an album tag
    procedure ScanProgress(Sender: TObject; const AProgress: TRGProgress);
    procedure ScanResults(Sender: TObject; AResults: TList);
    // Runs a scan of AGroups (the thread owns them) and waits for its end
    // (fails after 60 s); returns the stale file count
    function  RunScan(AGroups: TRGAlbumGroups; ADetach: Boolean = False): Integer;
    // ---> AulumicNS: the files as one album; every WAV file among them gets
    // an album tag (the name of its folder) unless FLooseTracks is set
    function  Group(const AFiles: array of string): TStringList;
    function  FindResult(const AFileName: string): PRGScanResult;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ToneGetsItsGainAndPeak;
    procedure SilenceGetsZeroDecibels;
    procedure BrokenFileMakesTheAlbumIncomplete;
    procedure MissingFileMakesTheAlbumIncomplete;
    procedure DetachStopsTheEvents;
    procedure NonAsciiNamesAreScanned;
    procedure AlbumGainGatesAllTracksTogether;
    procedure SeveralThreadsGiveTheSameResults;
    procedure BrokenFileWithSeveralThreads;
    procedure StopWithSeveralThreadsEndsCleanly;
    procedure TracksWithoutAnAlbumTagGetTheirTrackGainOnly;
  end;

implementation

uses
  Math, uAppConsts, TestHelpers;

const
  GAIN_DELTA = 0.2;   // dB
  TONE_DBFS  = -23.0;

{ TTestReplayGainThread }

function IsRiffFile(const AFile: string): Boolean;
var
  FS: TFileStream;
  Head: array[0..3] of AnsiChar;
begin
  Result := False;
  if not FileExists(AFile) then
    Exit;
  FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    Result := (FS.Read(Head, 4) = 4) and (Head = 'RIFF');
  finally
    FS.Free;
  end;
end;

procedure TTestReplayGainThread.SetUp;
begin
  FDir           := CreateTestDir;
  FResults       := TList.Create;
  FProgressCount := 0;
  FLastProgress  := Default(TRGProgress);
  FThreads       := 1;
  FStopAtProgress := False;
  FScanThread    := nil;
  FLooseTracks   := False;
end;

procedure TTestReplayGainThread.TearDown;
var
  I: Integer;
begin
  for I := 0 to FResults.Count - 1 do
    Dispose(PRGScanResult(FResults[I]));
  FResults.Free;
  RemoveTestTree(FDir);
end;


procedure TTestReplayGainThread.ScanProgress(Sender: TObject; const AProgress: TRGProgress);
begin
  Inc(FProgressCount);
  FLastProgress := AProgress;
  if FStopAtProgress and (FScanThread <> nil) then
    FScanThread.Terminate;
end;

procedure TTestReplayGainThread.ScanResults(Sender: TObject; AResults: TList);
var
  I: Integer;
begin
  for I := 0 to AResults.Count - 1 do
    FResults.Add(AResults[I]);
end;

function TTestReplayGainThread.RunScan(AGroups: TRGAlbumGroups; ADetach: Boolean): Integer;
var
  Thread: TReplayGainThread;
  Start : QWord;
begin
  Thread := TReplayGainThread.Create(AGroups, True, nil);
  try
    Thread.OnProgress := @ScanProgress;
    Thread.OnResults  := @ScanResults;
    Thread.ThreadCount := FThreads;
    FScanThread := Thread;
    if ADetach then
      Thread.Detach;
    Thread.Start;

    Start := GetTickCount64;
    while not Thread.Finished do
    begin
      CheckSynchronize(20);
      if GetTickCount64 - Start > 60000 then
        Fail('The scan did not end within 60 s');
    end;
    Thread.WaitFor;

    AssertTrue('No crash', not Assigned(Thread.FatalException));
    Result := Thread.StaleFileCount;
  finally
    FScanThread := nil;
    Thread.Free;
  end;
end;

function TTestReplayGainThread.Group(const AFiles: array of string): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 0 to High(AFiles) do
  begin
    Result.Add(FDir + AFiles[I]);
    if (not FLooseTracks) and IsRiffFile(FDir + AFiles[I]) then
      AddWavId3Tag(FDir + AFiles[I],
        ['TALB', ExtractFileName(ExtractFileDir(FDir + AFiles[I]))]);
  end;
end;

// ---> AulumicNS: loose tracks (no album tag) are no album: each one that
// can be analysed is saved with its track gain, none gets an album gain, and
// a broken one among them holds nothing back
procedure TTestReplayGainThread.TracksWithoutAnAlbumTagGetTheirTrackGainOnly;
var
  Groups: TRGAlbumGroups;
  A, B: PRGScanResult;
  SL: TStringList;
begin
  FLooseTracks := True;
  WriteToneWav(FDir + 'Loose\01 - Loud.wav', 1000.0, TONE_DBFS, 3.0);
  WriteToneWav(FDir + 'Loose\02 - Soft.wav', 1000.0, TONE_DBFS - 10.0, 3.0);
  SL := TStringList.Create;
  try
    SL.Add('This is not a WAV file.');
    SL.SaveToFile(FDir + 'Loose\03 - Broken.wav');
  finally
    SL.Free;
  end;

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Loose\01 - Loud.wav', 'Loose\02 - Soft.wav', 'Loose\03 - Broken.wav']));
  RunScan(Groups);

  AssertEquals('Three results', 3, FResults.Count);
  A := FindResult('01 - Loud.wav');
  B := FindResult('02 - Soft.wav');
  AssertTrue('Track gain only', (A^.Status = rsTrackOnly) and (B^.Status = rsTrackOnly));
  AssertEquals('The loud one: its own gain', 5.0, A^.TrackGain, GAIN_DELTA);
  AssertEquals('The soft one: its own gain', 15.0, B^.TrackGain, GAIN_DELTA);
  AssertEquals('Its peak', Power(10.0, TONE_DBFS / 20.0), A^.TrackPeak, 0.001);
  AssertEquals('No album gain', 0.0, A^.AlbumGain, 0.0);
  AssertEquals('No album peak', 0.0, A^.AlbumPeak, 0.0);
  AssertEquals('None for the other either', 0.0, B^.AlbumGain, 0.0);
  AssertTrue('The broken one: decode error', FindResult('03 - Broken.wav')^.Status = rsDecodeError);
end;

function TTestReplayGainThread.FindResult(const AFileName: string): PRGScanResult;
var
  I: Integer;
begin
  for I := 0 to FResults.Count - 1 do
    if SameText(ExtractFileName(PRGScanResult(FResults[I])^.FilePath), AFileName) then
      Exit(PRGScanResult(FResults[I]));
  Result := nil;
  Fail('No result for ' + AFileName);
end;

procedure TTestReplayGainThread.ToneGetsItsGainAndPeak;
var
  Groups: TRGAlbumGroups;
  R: PRGScanResult;
begin
  WriteToneWav(FDir + 'Tone\01 - Tone.wav', 1000.0, TONE_DBFS, 3.0);

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Tone\01 - Tone.wav']));
  AssertEquals('Nothing missing', 0, RunScan(Groups));

  AssertEquals('One result', 1, FResults.Count);
  R := FindResult('01 - Tone.wav');
  AssertTrue('Ready to save', R^.Status = rsReadyToSave);
  AssertEquals('Album: the folder name', 'Tone', R^.Album);
  AssertEquals('Track gain: -18 - (-23 LUFS)', 5.0, R^.TrackGain, GAIN_DELTA);
  AssertEquals('Album gain (one track)', 5.0, R^.AlbumGain, GAIN_DELTA);
  AssertEquals('Track peak: the tone''s level', Power(10.0, TONE_DBFS / 20.0), R^.TrackPeak, 0.001);
  AssertEquals('Album peak', R^.TrackPeak, R^.AlbumPeak, 0.000001);

  AssertTrue('Progress reported', FProgressCount > 0);
  AssertEquals('Progress: album 1 of 1', 1, FLastProgress.TotalAlbums);
  AssertEquals('Progress: the album', 'Tone', FLastProgress.AlbumText);
end;

procedure TTestReplayGainThread.SilenceGetsZeroDecibels;
var
  Groups: TRGAlbumGroups;
  R: PRGScanResult;
begin
  WriteTestWav(FDir + 'Silence\01.wav', 48000, 48000);
  WriteTestWav(FDir + 'Silence\02.wav', 48000, 48000);

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Silence\01.wav', 'Silence\02.wav']));
  RunScan(Groups);

  AssertEquals('Two results', 2, FResults.Count);
  R := FindResult('01.wav');
  AssertTrue('Ready to save', R^.Status = rsReadyToSave);
  AssertEquals('Silent track: 0 dB', 0.0, R^.TrackGain, 0.000001);
  AssertEquals('Silent album: 0 dB', 0.0, R^.AlbumGain, 0.000001);
  AssertEquals('No peak', 0.0, R^.TrackPeak, 0.000001);
  AssertTrue('Second track ready too', FindResult('02.wav')^.Status = rsReadyToSave);
end;

procedure TTestReplayGainThread.BrokenFileMakesTheAlbumIncomplete;
var
  Groups: TRGAlbumGroups;
  SL: TStringList;
begin
  WriteTestWav(FDir + 'Broken\01 - Good.wav', 48000, 48000);
  SL := TStringList.Create;
  try
    SL.Add('This is not a WAV file.');
    SL.SaveToFile(FDir + 'Broken\02 - Broken.wav');
  finally
    SL.Free;
  end;

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Broken\01 - Good.wav', 'Broken\02 - Broken.wav']));
  RunScan(Groups);

  AssertEquals('Two results', 2, FResults.Count);
  AssertTrue('The broken file: decode error',
    FindResult('02 - Broken.wav')^.Status = rsDecodeError);
  AssertTrue('The good one: its album is incomplete, nothing saved',
    FindResult('01 - Good.wav')^.Status = rsAlbumIncomplete);
end;

procedure TTestReplayGainThread.MissingFileMakesTheAlbumIncomplete;
var
  Groups: TRGAlbumGroups;
begin
  WriteTestWav(FDir + 'Missing\01 - Here.wav', 48000, 48000);

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Missing\01 - Here.wav', 'Missing\02 - Gone.wav']));
  AssertEquals('One file not found', 1, RunScan(Groups));

  AssertEquals('Two results', 2, FResults.Count);
  AssertTrue('The missing file', FindResult('02 - Gone.wav')^.Status = rsFileMissing);
  AssertTrue('The other one: album incomplete',
    FindResult('01 - Here.wav')^.Status = rsAlbumIncomplete);
end;

procedure TTestReplayGainThread.DetachStopsTheEvents;
var
  Groups: TRGAlbumGroups;
begin
  WriteTestWav(FDir + 'Detached\01.wav', 48000, 48000);

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Detached\01.wav']));
  RunScan(Groups, True);

  AssertEquals('No progress after Detach', 0, FProgressCount);
  AssertEquals('No results handed over (freed with the thread)', 0, FResults.Count);
end;

// ---> ADDED: A folder and a file whose names are not plain ASCII: measured,
// and the album name (the folder's) comes back intact
procedure TTestReplayGainThread.NonAsciiNamesAreScanned;
var
  Groups: TRGAlbumGroups;
  Rel: string;
  R: PRGScanResult;
begin
  // ---> AulumicNS: without an album tag (the test's tag writer is Latin-1
  // only): the name shown is the folder's, the track gets its track gain
  FLooseTracks := True;
  Rel := NonAsciiName + '\01 ' + NonAsciiName + '.wav';
  WriteToneWav(FDir + Rel, 1000.0, TONE_DBFS, 3.0);
  AssertTrue('The file is there', FileExists(FDir + Rel));

  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group([Rel]));
  AssertEquals('Nothing missing', 0, RunScan(Groups));

  R := FindResult('01 ' + NonAsciiName + '.wav');
  AssertTrue('Ready to save (track gain only)', R^.Status = rsTrackOnly);
  AssertEquals('Album: the folder name', NonAsciiName, R^.Album);
  AssertEquals('Track gain: -18 - (-23 LUFS)', 5.0, R^.TrackGain, GAIN_DELTA);
end;

// ---> AulumicNS: the album loudness over the blocks of both tracks: energies
// E and E/10 in equal parts, both above the relative gate: -23 + 10 log10(0.55)
procedure TTestReplayGainThread.AlbumGainGatesAllTracksTogether;
var
  Groups: TRGAlbumGroups;
  A, B: PRGScanResult;
begin
  WriteToneWav(FDir + 'Two\01 - Loud.wav', 1000.0, TONE_DBFS, 3.0);
  WriteToneWav(FDir + 'Two\02 - Soft.wav', 1000.0, TONE_DBFS - 10.0, 3.0);
  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Two\01 - Loud.wav', 'Two\02 - Soft.wav']));
  AssertEquals('Nothing missing', 0, RunScan(Groups));
  A := FindResult('01 - Loud.wav');
  B := FindResult('02 - Soft.wav');
  AssertTrue('Both ready', (A^.Status = rsReadyToSave) and (B^.Status = rsReadyToSave));
  AssertEquals('Loud track', 5.0, A^.TrackGain, GAIN_DELTA);
  AssertEquals('Soft track', 15.0, B^.TrackGain, GAIN_DELTA);
  AssertEquals('Album gain', -18.0 - (-23.0 + 10 * Log10(0.55)), A^.AlbumGain, GAIN_DELTA);
  AssertEquals('The same album gain for both', A^.AlbumGain, B^.AlbumGain, 0.000001);
  AssertEquals('Album peak: the louder one', A^.TrackPeak, B^.AlbumPeak, 0.000001);
end;

// ---> AulumicNS: the tracks of an album measured by several threads at once
// (ThreadCount): the same results, bit for bit and in the same order, as with
// one thread - two albums, tracks of different level, length and format
procedure TTestReplayGainThread.SeveralThreadsGiveTheSameResults;
type
  TKept = record
    Path: string;
    TG, TP, AG, AP: Double;
    Status: TRGResultStatus;
  end;
var
  Kept: array of TKept;
  I, N: Integer;
  R: PRGScanResult;

  function Albums: TRGAlbumGroups;
  begin
    Result := TRGAlbumGroups.Create;
    Result.Add(Group(['Six\01.wav', 'Six\02.wav', 'Six\03.wav', 'Six\04.flac', 'Six\05.wav', 'Six\06.wav']));
    Result.Add(Group(['Two\01.wav', 'Two\02.wav']));
  end;

begin
  WriteToneWav(FDir + 'Six\01.wav', 1000.0, -23.0, 3.0);
  WriteToneWav(FDir + 'Six\02.wav', 440.0, -30.0, 1.0);
  WriteToneWav(FDir + 'Six\03.wav', 2000.0, -12.0, 4.0, 44100);
  WritePatternFlac(FDir + 'Six\04.flac', 60000);
  WriteToneWav(FDir + 'Six\05.wav', 100.0, -18.0, 2.0);
  WriteTestWav(FDir + 'Six\06.wav', 48000, 48000);
  WriteToneWav(FDir + 'Two\01.wav', 1000.0, -20.0, 2.0);
  WriteToneWav(FDir + 'Two\02.wav', 1000.0, -26.0, 2.0);

  FThreads := 1;
  AssertEquals('Nothing missing', 0, RunScan(Albums));
  N := FResults.Count;
  AssertEquals('Eight results', 8, N);
  Kept := nil;
  SetLength(Kept, N);
  for I := 0 to N - 1 do
  begin
    R := PRGScanResult(FResults[I]);
    AssertTrue('One thread: ready to save ' + R^.FilePath, R^.Status = rsReadyToSave);
    Kept[I].Path := R^.FilePath;
    Kept[I].TG := R^.TrackGain; Kept[I].TP := R^.TrackPeak;
    Kept[I].AG := R^.AlbumGain; Kept[I].AP := R^.AlbumPeak;
    Kept[I].Status := R^.Status;
    Dispose(R);
  end;
  FResults.Clear;

  FThreads := 4;
  AssertEquals('Nothing missing', 0, RunScan(Albums));
  AssertEquals('Eight results again', N, FResults.Count);
  for I := 0 to N - 1 do
  begin
    R := PRGScanResult(FResults[I]);
    AssertEquals('The same order', Kept[I].Path, R^.FilePath);
    AssertTrue('The same status ' + R^.FilePath, Kept[I].Status = R^.Status);
    AssertTrue('The same track gain ' + R^.FilePath, Kept[I].TG = R^.TrackGain);
    AssertTrue('The same track peak ' + R^.FilePath, Kept[I].TP = R^.TrackPeak);
    AssertTrue('The same album gain ' + R^.FilePath, Kept[I].AG = R^.AlbumGain);
    AssertTrue('The same album peak ' + R^.FilePath, Kept[I].AP = R^.AlbumPeak);
  end;
  AssertTrue('Progress reported', FProgressCount > 0);
end;

procedure TTestReplayGainThread.BrokenFileWithSeveralThreads;
var
  Groups: TRGAlbumGroups;
  SL: TStringList;
begin
  WriteToneWav(FDir + 'Mixed\01.wav', 1000.0, -23.0, 2.0);
  WriteToneWav(FDir + 'Mixed\02.wav', 1000.0, -23.0, 2.0);
  WriteToneWav(FDir + 'Mixed\04.wav', 1000.0, -23.0, 2.0);
  SL := TStringList.Create;
  try
    SL.Add('This is not a WAV file.');
    SL.SaveToFile(FDir + 'Mixed\03.wav');
  finally
    SL.Free;
  end;
  FThreads := 3;
  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(['Mixed\01.wav', 'Mixed\02.wav', 'Mixed\03.wav', 'Mixed\04.wav', 'Mixed\05 - Gone.wav']));
  AssertEquals('One file not found', 1, RunScan(Groups));
  AssertEquals('Five results', 5, FResults.Count);
  AssertTrue('The broken file', FindResult('03.wav')^.Status = rsDecodeError);
  AssertTrue('The missing file', FindResult('05 - Gone.wav')^.Status = rsFileMissing);
  AssertTrue('The good ones: album incomplete', (FindResult('01.wav')^.Status = rsAlbumIncomplete) and
    (FindResult('02.wav')^.Status = rsAlbumIncomplete) and (FindResult('04.wav')^.Status = rsAlbumIncomplete));
end;

// Stop while several tracks are being measured: the workers end, nothing is
// handed over for the album in work, no memory stays behind (the test
// program's end checks that)
procedure TTestReplayGainThread.StopWithSeveralThreadsEndsCleanly;
var
  Groups: TRGAlbumGroups;
  I: Integer;
  Names: array of string;
begin
  Names := nil;
  SetLength(Names, 6);
  for I := 0 to 5 do
  begin
    Names[I] := Format('Long\%.2d.wav', [I + 1]);
    WriteTestWav(FDir + Names[I], 48000 * 60, 48000);   // a minute of silence each
  end;
  FThreads := 4;
  FStopAtProgress := True;
  Groups := TRGAlbumGroups.Create;
  Groups.Add(Group(Names));
  RunScan(Groups);
  AssertTrue('Stopped at the first progress', FProgressCount >= 1);
  AssertEquals('Nothing handed over', 0, FResults.Count);
end;

initialization
  RegisterTest(TTestReplayGainThread);

end.
