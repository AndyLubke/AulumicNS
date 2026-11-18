unit TestHeadroom;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   AulumicNS - test program
  Unit Name: TestHeadroom

  The automatic headroom (ALHeadroom, TPlayThread.RunGain).

  TTestHeadroomBook: the peaks learned per album and chain - only a higher
  peak counts, nonsense is refused, the file round trip, a damaged file.
  TTestHeadroomKeys: the chain part of the key (HeadroomChainKey).
  TTestHeadroomPlayback: real play threads into the memory output.
    The test signal is a sine at a quarter of the sample rate, 45 degrees off
    the samples: every sample is at 0.707 of the sine's amplitude, so a file
    whose samples stay below full scale holds a wave of up to +3 dB. The
    resampler rebuilds that wave (44.1 -> 88.2 kHz puts samples on its tops):
    without headroom it clips, with it the level comes down to just below
    full scale and nothing is clipped. The same for a gain above 1 without a
    resampler (a ReplayGain gain without a peak tag). The level is that of
    the album (the folder): a quiet track after the loud one stays down in
    the same folder and is untouched in another. A remembered peak (the book)
    gives the level from the first frame. Before the first over the samples
    are those of a run without headroom, to the bit. Playback without a gain
    stays bit-perfect.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, TestPlayback;

type
  TTestHeadroomBook = class(TTestCase)
  private
    FDir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure OnlyAHigherPeakIsLearned;
    procedure NonsenseIsRefused;
    procedure SavedAndLoadedAgain;
    procedure NothingIsWrittenWithoutAChange;
    procedure ADamagedFileStartsAnEmptyBook;
    procedure TheAlbumIsFolderArtistAndAlbum;
  end;

  TTestHeadroomKeys = class(TTestCase)
  published
    procedure TheChainNamesWhatMakesThePeak;
  end;

  TTestHeadroomPlayback = class(TPlaybackTestBase)
  private
    // A 16-bit stereo WAV at 44.1 kHz: the quarter-rate sine with the
    // amplitude AAmp (of full scale; its samples are at 0.707 of it), faded
    // in and out over 100 ms. ALeadFrames > 0: that many frames first at
    // ALeadAmp, then up to AAmp within 10 ms.
    procedure WriteSine(const APath: string; AFrames: Integer; AAmp: Double;
      ALeadFrames: Integer = 0; ALeadAmp: Double = 0.0);
    // The highest sample of the frames AFrom .. ATo - 1 of 32-bit stereo
    // data, of full scale
    function  PeakIn(const AData: TBytes; AFrom, ATo: Integer): Double;
    // The samples at the positive or negative end of 32 bits
    function  RailCount(const AData: TBytes): Integer;
    // The first frame with a sample at the end of 32 bits (-1 = none)
    function  FirstRailFrame(const AData: TBytes): Integer;
  protected
    procedure TearDown; override;
  published
    procedure WithoutHeadroomTheResampledPeaksClip;
    procedure ResampledPeaksStayBelowFullScale;
    procedure TheSignalPathShowsWhatIsTakenOff;
    procedure BeforeTheFirstOverNothingChanges;
    procedure ARememberedPeakGivesTheLevelFromTheStart;
    procedure TheNextTrackOfTheAlbumKeepsTheLevel;
    procedure AnotherAlbumStartsAtItsOwnLevel;
    procedure TracksWithoutAnAlbumTagEachHaveTheirOwnLevel;
    procedure AGainAboveOneWithoutAResamplerIsHeld;
    procedure PlaybackWithoutAGainStaysBitPerfect;
    procedure AVolumeBelowThePeakNeedsNoHeadroom;
    procedure AToneBoostDoesNotClip;
    procedure AToneBoostWithoutAResamplerDoesNotClip;
    procedure AToneCutCostsNoLevel;
    procedure AToneSettingChangedWhilePlayingGlides;
    procedure WithoutTheBoostTheLevelComesBack;
  end;

implementation

uses
  Math, ALHeadroom, ALSourceFactory, ALAudioTypes, uAudioUtils, TestHelpers;

const
  END_WAIT_MS = 10000;
  FULL_32     = 2147483648.0;
  LOUD        = 1.38;     // the sine's amplitude: +2.8 dB, samples at 0.976
  LOUD_SAMPLE = 0.9758;   // LOUD * sin(45 degrees)
  SECOND      = 44100;

function Sample32(const AData: TBytes; AIndex: Integer): Integer;
begin
  Result := Integer(LongWord(AData[AIndex * 4]) or (LongWord(AData[AIndex * 4 + 1]) shl 8) or
            (LongWord(AData[AIndex * 4 + 2]) shl 16) or (LongWord(AData[AIndex * 4 + 3]) shl 24));
end;

{ TTestHeadroomBook }

procedure TTestHeadroomBook.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestHeadroomBook.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure TTestHeadroomBook.OnlyAHigherPeakIsLearned;
var
  B: THeadroomBook;
begin
  B := THeadroomBook.Create('');
  try
    AssertEquals('Unknown', 0.0, B.Known('a'), 0.0);
    AssertTrue('New', B.Learn('a', 1.2));
    AssertEquals('Known', 1.2, B.Known('a'), 1e-12);
    AssertFalse('Lower: not learned', B.Learn('a', 1.1));
    AssertFalse('The same: not learned', B.Learn('a', 1.2));
    AssertEquals('Still the higher one', 1.2, B.Known('a'), 1e-12);
    AssertTrue('Higher', B.Learn('a', 1.3));
    AssertEquals('The new one', 1.3, B.Known('a'), 1e-12);
    AssertTrue('Another key', B.Learn('b', 0.4));
    AssertEquals('Two entries', 2, B.Count);
    AssertEquals('The first is untouched', 1.3, B.Known('a'), 1e-12);
    B.Clear;
    AssertEquals('Forgotten', 0, B.Count);
    AssertEquals('Unknown again', 0.0, B.Known('a'), 0.0);
  finally
    B.Free;
  end;
end;

procedure TTestHeadroomBook.NonsenseIsRefused;
var
  B: THeadroomBook;
begin
  B := THeadroomBook.Create('');
  try
    AssertFalse('No key', B.Learn('', 1.2));
    AssertFalse('Zero', B.Learn('a', 0.0));
    AssertFalse('Negative', B.Learn('a', -1.0));
    AssertFalse('NaN', B.Learn('a', NaN));
    AssertFalse('Infinite', B.Learn('a', Infinity));
    AssertFalse('Above +24 dB', B.Learn('a', HEADROOM_MAX_PEAK * 1.01));
    AssertEquals('Nothing learned', 0, B.Count);
    AssertFalse('Not changed', B.Dirty);
    AssertEquals('No key: unknown', 0.0, B.Known(''), 0.0);
  finally
    B.Free;
  end;
end;

procedure TTestHeadroomBook.SavedAndLoadedAgain;
var
  B: THeadroomBook;
  Err, LongKey: string;
begin
  LongKey := 'g:\music\' + StringOfChar('x', 300) + '|an artist|an album with ümlauts|pcm44100>352800q4p0b9130a10000';
  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    AssertTrue('A missing file is no error', B.Load(Err));
    AssertEquals('Empty', 0, B.Count);
    B.Learn('a', 1.25);
    B.Learn(LongKey, 1.0625);
    AssertTrue('Changed', B.Dirty);
    AssertTrue('Saved: ' + Err, B.Save(Err));
    AssertFalse('Not changed any more', B.Dirty);
  finally
    B.Free;
  end;
  AssertTrue('The file is there', FileExists(FDir + HEADROOM_FILE));

  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    AssertTrue('Loaded: ' + Err, B.Load(Err));
    AssertEquals('Both entries', 2, B.Count);
    AssertEquals('The first', 1.25, B.Known('a'), 0.0);
    AssertEquals('The long key', 1.0625, B.Known(LongKey), 0.0);
    AssertFalse('Loading is no change', B.Dirty);
    // and a second generation
    B.Learn('a', 1.5);
    AssertTrue('Saved again: ' + Err, B.Save(Err));
  finally
    B.Free;
  end;

  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    AssertTrue('Loaded again: ' + Err, B.Load(Err));
    AssertEquals('The higher peak', 1.5, B.Known('a'), 0.0);
  finally
    B.Free;
  end;
end;

procedure TTestHeadroomBook.NothingIsWrittenWithoutAChange;
var
  B: THeadroomBook;
  Err: string;
begin
  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    AssertTrue('Nothing to save is fine', B.Save(Err));
    AssertFalse('No file', FileExists(FDir + HEADROOM_FILE));
    B.Learn('a', 1.1);
    AssertTrue('Saved', B.Save(Err));
    AssertTrue('Deleted', SysUtils.DeleteFile(FDir + HEADROOM_FILE));
    AssertTrue('Nothing new: fine', B.Save(Err));
    AssertFalse('And not written again', FileExists(FDir + HEADROOM_FILE));
  finally
    B.Free;
  end;
end;

procedure TTestHeadroomBook.ADamagedFileStartsAnEmptyBook;
var
  B: THeadroomBook;
  Err: string;
  Raw: TBytes;
begin
  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    B.Learn('a', 1.1);
    B.Learn('b', 1.2);
    AssertTrue('Saved', B.Save(Err));
  finally
    B.Free;
  end;
  Raw := ReadFileBytes(FDir + HEADROOM_FILE);
  AssertTrue('A file with content', Length(Raw) > 24);
  Raw[Length(Raw) - 3] := Raw[Length(Raw) - 3] xor $5A;
  WriteFileBytes(FDir + HEADROOM_FILE, Raw);

  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    AssertFalse('Reported', B.Load(Err));
    AssertTrue('With a reason', Err <> '');
    AssertEquals('Empty', 0, B.Count);
    // and it works on
    AssertTrue('Learns', B.Learn('a', 1.3));
    AssertTrue('Saves over the damaged file: ' + Err, B.Save(Err));
  finally
    B.Free;
  end;

  B := THeadroomBook.Create(FDir + HEADROOM_FILE);
  try
    AssertTrue('Readable again: ' + Err, B.Load(Err));
    AssertEquals('The new entry', 1.3, B.Known('a'), 0.0);
  finally
    B.Free;
  end;
end;

procedure TTestHeadroomBook.TheAlbumIsFolderArtistAndAlbum;
begin
  AssertEquals('Folder, artist, album in lower case',
    'g:\music\artist\album|the artist|the album',
    HeadroomAlbumKey('G:\Music\Artist\Album\01 - Track.flac', ' The Artist ', 'The Album'));
  AssertEquals('Two tracks of a folder: one album',
    HeadroomAlbumKey('G:\M\A\01.flac', 'X', 'Y'), HeadroomAlbumKey('G:\M\A\02.flac', 'X', 'Y'));
  AssertTrue('CD sub folders are albums of their own',
    HeadroomAlbumKey('G:\M\A\CD1\01.flac', 'X', 'Y') <> HeadroomAlbumKey('G:\M\A\CD2\01.flac', 'X', 'Y'));
  AssertTrue('Two albums in one folder',
    HeadroomAlbumKey('G:\M\A\01.flac', 'X', 'Y') <> HeadroomAlbumKey('G:\M\A\02.flac', 'X', 'Z'));
  // no album tag: the file is its own album
  AssertEquals('Without an album tag: the file itself', 'g:\m\a\01.flac||',
    HeadroomAlbumKey('G:\M\A\01.flac', 'X', ' '));
  AssertTrue('Two loose tracks of a folder are two albums',
    HeadroomAlbumKey('G:\M\A\01.flac', '', '') <> HeadroomAlbumKey('G:\M\A\02.flac', '', ''));
  AssertEquals('0 dB', 0.0, FactorToDb(1.0), 1e-12);
  AssertEquals('-6 dB', -6.0206, FactorToDb(0.5), 1e-4);
  AssertEquals('Nonsense is 0 dB', 0.0, FactorToDb(0.0), 0.0);
end;

{ TTestHeadroomKeys }

procedure TTestHeadroomKeys.TheChainNamesWhatMakesThePeak;
var
  C, D: TPlayThreadConfig;
  K: string;
begin
  C := Default(TPlayThreadConfig);
  C.ResampleQuality   := 4;
  C.UpsamplePhase     := 0;
  C.DownsamplePhase   := 2;
  C.ResampleBandWidth := 0.913;
  C.ResampleAntiAlias := 1.0;

  AssertEquals('Not resampled: only the rate', 'pcm44100', HeadroomChainKey(C, 'a.flac', 44100, 44100));
  K := HeadroomChainKey(C, 'a.flac', 44100, 352800);
  AssertEquals('Resampled: rates and settings', 'pcm44100>352800q4p0b9130a10000', K);
  AssertEquals('Downsampling takes its own phase', 'pcm96000>48000q4p2b9130a10000',
    HeadroomChainKey(C, 'a.flac', 96000, 48000));

  D := C;
  D.UpsamplePhase := 1;
  AssertTrue('Another phase: another chain', HeadroomChainKey(D, 'a.flac', 44100, 352800) <> K);
  D := C;
  D.ResampleQuality := 3;
  AssertTrue('Another quality', HeadroomChainKey(D, 'a.flac', 44100, 352800) <> K);
  D := C;
  D.ResampleBandWidth := 0.95;
  AssertTrue('Another bandwidth', HeadroomChainKey(D, 'a.flac', 44100, 352800) <> K);
  D := C;
  D.ResampleAntiAlias := 0.5;
  AssertTrue('Another anti-aliasing', HeadroomChainKey(D, 'a.flac', 44100, 352800) <> K);
  AssertTrue('Another output rate', HeadroomChainKey(C, 'a.flac', 44100, 176400) <> K);
  // settings that change nothing before the gain
  D := C;
  D.PreampDB := -3;
  D.ReplayGainMode := 2;
  D.DsdGainDB := 6;
  D.EnableSoftClipping := True;
  AssertEquals('The gain settings are not part of it', K, HeadroomChainKey(D, 'a.flac', 44100, 352800));

  AssertEquals('DSD to PCM', 'dsd352800', HeadroomChainKey(C, 'a.dsf', 352800, 352800));
  D := C;
  D.DsdLowPassFilter := True;
  AssertEquals('With its low-pass filter', 'dsdf352800', HeadroomChainKey(D, 'a.dff', 352800, 352800));
  D := C;
  D.UseDoP := True;
  AssertEquals('DSD as DSD has no peak', 'dop', HeadroomChainKey(D, 'a.dsf', 176400, 176400));

  AssertEquals('Off: no key (and no file is read)', '',
    CalcHeadroomKey(C, 'Z:\no such folder\a.flac', 44100, 352800));
end;

{ TTestHeadroomPlayback }

procedure TTestHeadroomPlayback.TearDown;
begin
  inherited TearDown;        // the play thread first: it uses the book
  FreeAndNil(HeadroomBook);
end;

procedure TTestHeadroomPlayback.WriteSine(const APath: string; AFrames: Integer; AAmp: Double;
  ALeadFrames: Integer; ALeadAmp: Double);
const
  FADE = 4410;   // 100 ms
  RISE = 441;    // 10 ms from the lead to the full amplitude
var
  Raw: TBytes;
  N, V: Integer;
  A: Double;
begin
  Raw := nil;
  SetLength(Raw, AFrames * 4);
  for N := 0 to AFrames - 1 do
  begin
    if N < ALeadFrames then
      A := ALeadAmp
    else if N < ALeadFrames + RISE then
    begin
      if ALeadFrames > 0 then
        A := ALeadAmp + (AAmp - ALeadAmp) * ((N - ALeadFrames) / RISE)
      else
        A := AAmp;
    end
    else
      A := AAmp;
    if N < FADE then
      A := A * (N / FADE);
    if N >= AFrames - FADE then
      A := A * ((AFrames - 1 - N) / FADE);
    V := Round(A * Sin(Pi / 2 * N + Pi / 4) * 32768.0);
    if V > 32767 then V := 32767;
    if V < -32768 then V := -32768;
    Raw[N * 4]     := Byte(V and $FF);
    Raw[N * 4 + 1] := Byte((V shr 8) and $FF);
    Raw[N * 4 + 2] := Raw[N * 4];
    Raw[N * 4 + 3] := Raw[N * 4 + 1];
  end;
  ForceDirectories(ExtractFileDir(APath));
  WriteWavData(APath, 44100, 16, 2, Raw);
end;

function TTestHeadroomPlayback.PeakIn(const AData: TBytes; AFrom, ATo: Integer): Double;
var
  I: Integer;
  A: Double;
begin
  Result := 0.0;
  if ATo > Length(AData) div 8 then
    ATo := Length(AData) div 8;
  for I := AFrom * 2 to ATo * 2 - 1 do
  begin
    A := Abs(Sample32(AData, I) / FULL_32);
    if A > Result then
      Result := A;
  end;
end;

function TTestHeadroomPlayback.RailCount(const AData: TBytes): Integer;
var
  I, S: Integer;
begin
  Result := 0;
  for I := 0 to Length(AData) div 4 - 1 do
  begin
    S := Sample32(AData, I);
    if (S = High(Integer)) or (S = Low(Integer)) then
      Inc(Result);
  end;
end;

function TTestHeadroomPlayback.FirstRailFrame(const AData: TBytes): Integer;
var
  I, S: Integer;
begin
  for I := 0 to Length(AData) div 4 - 1 do
  begin
    S := Sample32(AData, I);
    if (S = High(Integer)) or (S = Low(Integer)) then
      Exit(I div 2);
  end;
  Result := -1;
end;

// The control: this file does clip when nothing is done about it
procedure TTestHeadroomPlayback.WithoutHeadroomTheResampledPeaksClip;
var
  D: TBytes;
begin
  WriteSine(FDir + 'loud.wav', SECOND, LOUD);
  FResample44To := 88200;
  Play(FDir + 'loud.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertTrue('Clipped', FThread.WasClipped);
  AssertTrue('Samples at the end of the scale', RailCount(D) > 1000);
  // the same file without the resampler does not: its samples are below
  Restart;
  FResample44To := 0;
  Play(FDir + 'loud.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  D := FRecorder.Data;
  AssertFalse('Not clipped as it is', FThread.WasClipped);
  AssertEquals('The samples of the file', LOUD_SAMPLE, PeakIn(D, 0, SECOND), 0.001);
end;

procedure TTestHeadroomPlayback.ResampledPeaksStayBelowFullScale;
var
  D: TBytes;
  Mid: Double;
begin
  WriteSine(FDir + 'loud.wav', SECOND, LOUD);
  FResample44To := 88200;
  FHeadroom     := True;
  Play(FDir + 'loud.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertFalse('Not clipped', FThread.WasClipped);
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  AssertTrue(Format('Never above the ceiling (%.5f)', [PeakIn(D, 0, MaxInt)]),
    PeakIn(D, 0, MaxInt) <= HEADROOM_CEILING + 1e-6);
  // and no lower than needed: the tops of the wave are at the ceiling
  Mid := PeakIn(D, 40000, 70000);
  AssertTrue(Format('The tops are at the ceiling (%.5f)', [Mid]),
    (Mid > HEADROOM_CEILING * 0.995) and (Mid <= HEADROOM_CEILING + 1e-6));
end;

procedure TTestHeadroomPlayback.TheSignalPathShowsWhatIsTakenOff;
var
  Info: TSignalInfo;
  Expected: Double;
begin
  WriteSine(FDir + 'loud.wav', SECOND, LOUD);
  FResample44To := 88200;
  FHeadroom     := True;
  FRecorder.HoldAfterBuffers(10);     // half a second: the full level was there
  Play(FDir + 'loud.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  Info := FThread.GetSignalInfo;
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  AssertTrue('Switched on', Info.HeadroomOn);
  Expected := 20 * Log10(HEADROOM_CEILING / LOUD);    // -2.8 dB
  AssertEquals('What the headroom takes off', Expected, Info.HeadroomDB, 0.05);
end;

// A quiet lead of 0.62 s, then the loud wave: up to 10 ms before the first
// over the output is that of a run without headroom, to the bit
procedure TTestHeadroomPlayback.BeforeTheFirstOverNothingChanges;
const
  LEAD = 27342;
var
  Plain, D: TBytes;
  FirstOver, Same, I: Integer;
begin
  WriteSine(FDir + 'lead.wav', SECOND, LOUD, LEAD, 0.3);
  FResample44To := 88200;
  Play(FDir + 'lead.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  Plain := FRecorder.Data;
  FirstOver := FirstRailFrame(Plain);
  AssertTrue('The plain run clips after the lead', FirstOver > 2 * LEAD);

  Restart;
  FHeadroom := True;
  Play(FDir + 'lead.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('As long as the plain run', Length(Plain), Length(D));
  AssertFalse('Not clipped', FThread.WasClipped);
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));

  // 10 ms are 882 frames; the glide may begin that long before the over
  Same := FirstOver - 1000;
  for I := 0 to Same * 2 - 1 do
    if Sample32(D, I) <> Sample32(Plain, I) then
      Fail(Format('Frame %d differs from the plain run (the first over is at frame %d)',
        [I div 2, FirstOver]));
  AssertEquals('The lead at its level', 0.3, PeakIn(D, 20000, 50000), 0.003);
  // from the over on it is lower, and it never comes back up
  AssertTrue('Lower at the over', Abs(Sample32(D, FirstOver * 2)) < Abs(Sample32(Plain, FirstOver * 2)));
  AssertTrue('The tops are at the ceiling',
    PeakIn(D, 70000, 80000) > HEADROOM_CEILING * 0.995);
end;

procedure TTestHeadroomPlayback.ARememberedPeakGivesTheLevelFromTheStart;
var
  Run1, Run2: TBytes;
  Early1, Early2: Double;
begin
  HeadroomBook := THeadroomBook.Create('');
  WriteSine(FDir + 'loud.wav', SECOND, LOUD);
  FResample44To := 88200;
  FHeadroom     := True;
  Play(FDir + 'loud.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  Run1 := FRecorder.Data;
  AssertEquals('One album learned', 1, HeadroomBook.Count);
  AssertTrue('The book has changed', HeadroomBook.Dirty);

  Restart;
  Play(FDir + 'loud.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  Run2 := FRecorder.Data;
  AssertEquals('Still one album', 1, HeadroomBook.Count);
  AssertEquals('No sample at the end of the scale', 0, RailCount(Run2));

  // 50 ms into the fade-in the wave is at half its level: below full scale,
  // so the first run played it as it is - the second one at the album's
  // level already
  Early1 := PeakIn(Run1, 4000, 4800);
  Early2 := PeakIn(Run2, 4000, 4800);
  AssertTrue(Format('The first run begins untouched (%.4f)', [Early1]), (Early1 > 0.55) and (Early1 < 0.80));
  AssertEquals('Both runs end at the same level', PeakIn(Run1, 40000, 70000), PeakIn(Run2, 40000, 70000), 0.002);
  AssertEquals('The second run begins at the album''s level', Early1 * HEADROOM_CEILING / LOUD, Early2, 0.01);
end;

procedure TTestHeadroomPlayback.TheNextTrackOfTheAlbumKeepsTheLevel;
var
  D: TBytes;
begin
  WriteSine(FDir + 'Album\01.wav', SECOND, LOUD);
  WriteSine(FDir + 'Album\02.wav', SECOND, 0.5);
  AddWavId3Tag(FDir + 'Album\01.wav', ['TALB', 'The Album']);
  AddWavId3Tag(FDir + 'Album\02.wav', ['TALB', 'The Album']);
  FResample44To := 88200;
  FHeadroom     := True;
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'Album\01.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'Album\02.wav'));
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  // the quiet track of the same album: as far down as the loud one
  AssertEquals('The quiet track keeps the album''s level', 0.5 * HEADROOM_CEILING / LOUD,
    PeakIn(D, 2 * SECOND + 30000, 2 * SECOND + 60000), 0.004);
end;

procedure TTestHeadroomPlayback.AnotherAlbumStartsAtItsOwnLevel;
var
  D: TBytes;
begin
  WriteSine(FDir + 'Album A\01.wav', SECOND, LOUD);
  WriteSine(FDir + 'Album B\01.wav', SECOND, 0.5);
  FResample44To := 88200;
  FHeadroom     := True;
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'Album A\01.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'Album B\01.wav'));
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('The loud album at the ceiling', HEADROOM_CEILING, PeakIn(D, 40000, 70000), 0.005);
  // the other album has no peak above full scale: untouched
  AssertEquals('The quiet album at its own level', 0.5,
    PeakIn(D, 2 * SECOND + 30000, 2 * SECOND + 60000), 0.003);
end;

// Two tracks of one folder without an album tag are no album: the loud one
// does not take the quiet one down with it
procedure TTestHeadroomPlayback.TracksWithoutAnAlbumTagEachHaveTheirOwnLevel;
var
  D: TBytes;
begin
  WriteSine(FDir + 'Loose\01.wav', SECOND, LOUD);
  WriteSine(FDir + 'Loose\02.wav', SECOND, 0.5);
  FResample44To := 88200;
  FHeadroom     := True;
  HeadroomBook  := THeadroomBook.Create('');
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'Loose\01.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'Loose\02.wav'));
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  AssertEquals('The loud track at the ceiling', HEADROOM_CEILING, PeakIn(D, 40000, 70000), 0.005);
  AssertEquals('The quiet track at its own level', 0.5,
    PeakIn(D, 2 * SECOND + 30000, 2 * SECOND + 60000), 0.003);
  AssertEquals('Each remembered on its own', 2, HeadroomBook.Count);
end;

// No resampler: integer samples are never above full scale, but a gain above
// 1 takes them there - a ReplayGain gain of +6 dB without a peak tag
procedure TTestHeadroomPlayback.AGainAboveOneWithoutAResamplerIsHeld;
var
  D: TBytes;
begin
  WriteSine(FDir + 'gain.wav', SECOND, LOUD);
  AddWavId3Tag(FDir + 'gain.wav', ['TXXX', 'REPLAYGAIN_TRACK_GAIN'#0'+6.00 dB']);
  FTrackGain := True;
  Play(FDir + 'gain.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertTrue('Without headroom the gain clips', FThread.WasClipped);
  AssertTrue('Samples at the end of the scale', RailCount(FRecorder.Data) > 1000);

  Restart;
  FHeadroom := True;
  Play(FDir + 'gain.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertFalse('Not clipped', FThread.WasClipped);
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  AssertEquals('The samples come up to the ceiling', HEADROOM_CEILING, PeakIn(D, 15000, 30000), 0.002);
end;

procedure TTestHeadroomPlayback.PlaybackWithoutAGainStaysBitPerfect;
const
  FRAMES = 20000;
var
  Raw, D: TBytes;
  I: Integer;
begin
  FHeadroom := True;
  WritePatternWav(FDir + 'a.wav', FRAMES);
  Play(FDir + 'a.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  CheckPattern('The pattern, untouched', FRecorder.Data, 32, 16, 0, 0, FRAMES);
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);

  // samples at full scale, both ends: nothing to lower without a gain
  Restart;
  Raw := nil;
  SetLength(Raw, FRAMES * 4);
  for I := 0 to FRAMES * 2 - 1 do
    if (I div 2) mod 2 = 0 then
    begin
      Raw[I * 2]     := $FF;     // 32767
      Raw[I * 2 + 1] := $7F;
    end
    else
    begin
      Raw[I * 2]     := $00;     // -32768
      Raw[I * 2 + 1] := $80;
    end;
  WriteWavData(FDir + 'full.wav', 44100, 16, 2, Raw);
  Play(FDir + 'full.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertTrue('Bit-perfect at full scale', FThread.IsBitPerfect);
  for I := 0 to FRAMES * 2 - 1 do
    if (I div 2) mod 2 = 0 then
    begin
      if Sample32(D, I) <> 32767 shl 16 then
        Fail(Format('Sample %d is %d, not 32767 in 32 bits', [I, Sample32(D, I)]));
    end
    else if Sample32(D, I) <> Low(Integer) then
      Fail(Format('Sample %d is %d, not -32768 in 32 bits', [I, Sample32(D, I)]));
end;

// The cap is on the gain: with the volume down far enough the peak is below
// full scale anyway, and the output is that of a run without headroom
procedure TTestHeadroomPlayback.AVolumeBelowThePeakNeedsNoHeadroom;
const
  VOLUME_6DB = 707;    // a factor of 0.5 (the volume is squared)
var
  Plain, D: TBytes;
  I: Integer;
  Info: TSignalInfo;
begin
  WriteSine(FDir + 'loud.wav', SECOND, LOUD);
  FResample44To := 88200;
  Play(FDir + 'loud.wav', False, VOLUME_6DB);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  Plain := FRecorder.Data;
  AssertFalse('The plain run does not clip at this volume', FThread.WasClipped);

  Restart;
  FHeadroom := True;
  FRecorder.HoldAfterBuffers(10);
  Play(FDir + 'loud.wav', False, VOLUME_6DB);
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  Info := FThread.GetSignalInfo;
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('Nothing taken off', 0.0, Info.HeadroomDB, 0.0);
  AssertEquals('As long as the plain run', Length(Plain), Length(D));
  for I := 0 to Length(D) div 4 - 1 do
    if Sample32(D, I) <> Sample32(Plain, I) then
      Fail(Format('Sample %d differs from the plain run', [I]));
end;

// The tone control works before the gain, inside the block routines. The
// play thread looks at every block behind it first, so a boost is lowered
// like any other peak: nothing clips, not even at the start.
procedure TTestHeadroomPlayback.AToneBoostDoesNotClip;
var
  Plain, D: TBytes;
begin
  // a wave below full scale also behind the resampler; 11 kHz is in the
  // treble band
  WriteSine(FDir + 'tone.wav', SECOND, 0.9);
  FResample44To := 88200;
  FTrebleDB     := 60;       // +6 dB
  Play(FDir + 'tone.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  Plain := FRecorder.Data;
  AssertTrue('The boost clips without headroom', FThread.WasClipped);
  AssertTrue('All through the track', RailCount(Plain) > 1000);

  Restart;
  HeadroomBook := THeadroomBook.Create('');
  FHeadroom    := True;
  Play(FDir + 'tone.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertFalse('Not clipped', FThread.WasClipped);
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  AssertTrue(Format('Never above the ceiling (%.5f)', [PeakIn(D, 0, MaxInt)]),
    PeakIn(D, 0, MaxInt) <= HEADROOM_CEILING + 1e-6);
  AssertTrue(Format('The tops are at the ceiling (%.4f)', [PeakIn(D, 44100, 70000)]),
    PeakIn(D, 44100, 70000) > HEADROOM_CEILING * 0.995);
  // the album's own peak is what is remembered: 0.9, not the boosted one
  AssertEquals('One album in the book', 1, HeadroomBook.Count);
end;

// The same without a resampler and without a gain: integer samples below
// full scale, raised above it by the tone control alone
procedure TTestHeadroomPlayback.AToneBoostWithoutAResamplerDoesNotClip;
var
  D: TBytes;
begin
  WriteSine(FDir + 'tone.wav', SECOND, LOUD);     // samples at 0.976
  FTrebleDB := 60;
  Play(FDir + 'tone.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  AssertTrue('The boost clips without headroom', FThread.WasClipped);

  Restart;
  FHeadroom := True;
  Play(FDir + 'tone.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertFalse('Not clipped', FThread.WasClipped);
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  AssertTrue(Format('The tops are at the ceiling (%.4f)', [PeakIn(D, 15000, 30000)]),
    (PeakIn(D, 15000, 30000) > HEADROOM_CEILING * 0.995) and
    (PeakIn(D, 15000, 30000) <= HEADROOM_CEILING + 1e-6));
end;

// A cut takes the peaks down: behind it the loud wave fits, so nothing is
// lowered and the output is that of a run without headroom, to the bit
// (which also shows that looking at a block leaves the filters as they were)
procedure TTestHeadroomPlayback.AToneCutCostsNoLevel;
var
  Plain, D: TBytes;
  I: Integer;
  Info: TSignalInfo;
begin
  WriteSine(FDir + 'cut.wav', SECOND, LOUD);
  FResample44To := 88200;
  FTrebleDB     := -100;     // -10 dB
  Play(FDir + 'cut.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  Plain := FRecorder.Data;
  AssertFalse('The cut wave does not clip', FThread.WasClipped);
  AssertTrue('And is well below full scale', PeakIn(Plain, 0, MaxInt) < 0.9);

  Restart;
  FHeadroom := True;
  FRecorder.HoldAfterBuffers(10);
  Play(FDir + 'cut.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  Info := FThread.GetSignalInfo;
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('Nothing taken off', 0.0, Info.HeadroomDB, 0.0);
  AssertEquals('As long as the plain run', Length(Plain), Length(D));
  for I := 0 to Length(D) div 4 - 1 do
    if Sample32(D, I) <> Sample32(Plain, I) then
      Fail(Format('Sample %d differs from the plain run', [I]));
end;

// The tone control switched off while the track plays (no headroom, nothing
// near full scale): the level goes from the boosted one to the plain one in
// the glide's time, through the play thread's gain stage - not in one step
procedure TTestHeadroomPlayback.AToneSettingChangedWhilePlayingGlides;
const
  WIN = 16;                 // two periods of the wave at 88.2 kHz
var
  D: TBytes;
  Tone: TToneState;
  Boosted, Plain, P: Double;
  I, First, Last, Frames: Integer;
begin
  WriteSine(FDir + 'glide.wav', 2 * SECOND, 0.4);
  FResample44To := 88200;
  FTrebleDB     := 60;
  FRecorder.HoldAfterBuffers(10);
  Play(FDir + 'glide.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  Tone := Default(TToneState);
  Tone.DirectMode := True;
  Tone.BassHz     := 100;
  Tone.MidHz      := 1000;
  Tone.TrebleHz   := 10000;
  FThread.SetToneControl(Tone);
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  Frames  := Length(D) div 8;
  Boosted := PeakIn(D, 20000, 30000);
  Plain   := PeakIn(D, 130000, 140000);
  AssertEquals('The plain wave', 0.4, Plain, 0.004);
  AssertTrue(Format('The boost was there (%.3f)', [Boosted]), Boosted > Plain * 1.3);
  // the first window below the boosted level, the first at the plain one
  First := -1;
  Last  := -1;
  I := 20000;
  while I + WIN <= Frames - 20000 do
  begin
    P := PeakIn(D, I, I + WIN);
    AssertTrue(Format('Never above the boosted level (%.4f at %d)', [P, I]), P <= Boosted * 1.002);
    if (First < 0) and (P < Boosted - (Boosted - Plain) * 0.02) then
      First := I;
    if (First >= 0) and (P < Plain + (Boosted - Plain) * 0.02) then
    begin
      Last := I;
      Break;
    end;
    Inc(I, WIN);
  end;
  AssertTrue('The level came down', (First >= 0) and (Last > First));
  // 40 ms at 88.2 kHz are 3528 frames; between 2 % and 98 % of the way the
  // eased line needs about 80 % of them
  AssertTrue(Format('In the glide''s time, not at once (%d frames)', [Last - First]),
    (Last - First > 2000) and (Last - First < 3600));
end;

// The boost is switched off while the track plays: what it needed is not
// held on to, the level comes back to the album's own
procedure TTestHeadroomPlayback.WithoutTheBoostTheLevelComesBack;
var
  D: TBytes;
  Tone: TToneState;
begin
  WriteSine(FDir + 'tone.wav', 2 * SECOND, 0.9);
  FResample44To := 88200;
  FTrebleDB     := 60;
  FHeadroom     := True;
  FRecorder.HoldAfterBuffers(10);     // half a second with the boost
  Play(FDir + 'tone.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  Tone := Default(TToneState);
  Tone.DirectMode := True;
  Tone.BassHz     := 100;
  Tone.MidHz      := 1000;
  Tone.TrebleHz   := 10000;
  FThread.SetToneControl(Tone);
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertEquals('No sample at the end of the scale', 0, RailCount(D));
  AssertTrue('With the boost: at the ceiling', PeakIn(D, 20000, 40000) > HEADROOM_CEILING * 0.995);
  // the wave itself is at 0.9: untouched again
  AssertEquals('Without it: the wave as it is', 0.9, PeakIn(D, 100000, 150000), 0.005);
end;

initialization
  RegisterTest(TTestHeadroomBook);
  RegisterTest(TTestHeadroomKeys);
  RegisterTest(TTestHeadroomPlayback);

end.
