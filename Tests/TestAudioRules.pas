unit TestAudioRules;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestAudioRules
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for ALSourceFactory (how a track's audio source is built, without a
  play thread or a sound device):
    TTestAudioRules  : the output rate (rate table, fixed target), the
                       ReplayGain factor (preamp, mode, limits, peak
                       protection, invalid values, volume disabled)
    TTestTrackSource : the ReplayGain tags of a file (track / album mode, album
                       falling back to track, off, limits) and
                       PrepareNextSource on generated WAV files (rates, bit
                       depth matched, mono as stereo, the ReplayGain factor,
                       unsupported and missing files); ---> ADDED: the tests
                       run in UTF-8 like Aulumic, tags and PrepareNextSource
                       of a file with a non-ASCII name (TestHelpers.NonAsciiName)
    TTestDsdToPcm    : ---> ADDED: the DSD-to-PCM rate rules of ALReaders: the
                       DC blocker's -3 dB point is DSD_DC_BLOCK_HZ and 20 Hz
                       passes within 0.1 dB at every DSD rate (DsdDcBlockPole),
                       the fade-in lasts DSD_FADE_IN_MS at every rate
  ---> CHANGED (ObjFPC switch, step 2): ALSourceFactory is ObjFPC now; file
  names are passed as they are (UTF-8), as uPlaybackIOWorker does. Resampling is
  tested in TestResampler; the DSD gain correction is not tested here (it
  needs a tagged DSF file).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, ALReaders, ALSourceFactory;

type
  TTestAudioRules = class(TTestCase)
  published
    procedure RateIsTheInputRateWithoutSettings;
    procedure RateFromTheTableBeforeTheTarget;
    procedure FactorIsOneWhenVolumeIsDisabled;
    procedure FactorFromPreampAndReplayGain;
    procedure FactorIsLimited;
    procedure PeakProtectionOnlyWithReplayGain;
    procedure InvalidValuesCountAsZero;
  end;

  TTestTrackSource = class(TTestCase)
  private
    FDir: string;
    function Config(AMode: Integer): TPlayThreadConfig;
    function Prepare(const AFile: string; ANegotiatedBits: Integer; AMode: Integer;
      out APrep: TPreparedNext): Boolean;
    // A WAV file with ReplayGain tags (TXXX frames: description #0 value)
    procedure WriteTaggedWav(const AFile: string; AWithAlbum: Boolean;
      const ATrackGain: string = '-6.50 dB');
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TrackModeReadsTheTrackTags;
    procedure AlbumModeReadsTheAlbumTags;
    procedure AlbumModeFallsBackToTheTrackTags;
    procedure ReplayGainOffReadsNothing;
    procedure TagGainIsLimited;
    procedure WavSourceKeepsItsRate;
    procedure SourceMatchesTheNegotiatedBitDepth;
    procedure MonoBecomesStereo;
    procedure PreparedSourceGetsItsReplayGainFactor;
    procedure UnsupportedAndMissingFiles;
    procedure TheTestsRunInUtf8LikeAulumic;
    procedure NonAsciiNameReadsTheReplayGainTags;
    procedure NonAsciiNameIsPrepared;
  end;

  // ---> ADDED
  TTestDsdToPcm = class(TTestCase)
  published
    procedure DcBlockerCornerIsTheSameAtEveryRate;
    procedure DcBlockerKeepsTheAudioBand;
    procedure FadeInLastsTheSameTimeAtEveryRate;
  end;

implementation

uses
  Math, TestHelpers;

const
  DELTA = 0.0001;

function Cfg: TPlayThreadConfig;
begin
  Result := Default(TPlayThreadConfig);
end;

function DbToFactor(ADB: Double): Double;
begin
  Result := Power(10.0, ADB / 20.0);
end;

{ TTestAudioRules }

procedure TTestAudioRules.RateIsTheInputRateWithoutSettings;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  AssertEquals('No table, no target', 44100, CalcTargetRate(C, 44100));
  C.TargetSampleRate := 96000;
  AssertEquals('Fixed target', 96000, CalcTargetRate(C, 44100));
  AssertEquals('Fixed target for every rate', 96000, CalcTargetRate(C, 192000));
end;

procedure TTestAudioRules.RateFromTheTableBeforeTheTarget;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  SetLength(C.RateMaps, 2);
  C.RateMaps[0].InRate := 44100;  C.RateMaps[0].OutRate := 88200;
  C.RateMaps[1].InRate := 48000;  C.RateMaps[1].OutRate := 96000;

  AssertEquals('44.1 kHz from the table', 88200, CalcTargetRate(C, 44100));
  AssertEquals('48 kHz from the table', 96000, CalcTargetRate(C, 48000));
  AssertEquals('Not in the table, no target: unchanged', 192000, CalcTargetRate(C, 192000));

  C.TargetSampleRate := 384000;
  AssertEquals('The table comes first', 88200, CalcTargetRate(C, 44100));
  AssertEquals('Not in the table: the target', 384000, CalcTargetRate(C, 192000));
end;

procedure TTestAudioRules.FactorIsOneWhenVolumeIsDisabled;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  C.DisableVolume  := True;
  C.ReplayGainMode := 1;
  C.PreampDB       := 6.0;
  AssertEquals('Volume disabled: untouched', 1.0, CalcRGFactor(C, -9.0, 0.5), DELTA);
end;

procedure TTestAudioRules.FactorFromPreampAndReplayGain;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  AssertEquals('Nothing set', 1.0, CalcRGFactor(C, 0.0, 0.0), DELTA);
  AssertEquals('ReplayGain off: the tag gain is ignored', 1.0, CalcRGFactor(C, -6.0, 0.9), DELTA);

  C.PreampDB := -3.0;
  AssertEquals('ReplayGain off: the preamp only', DbToFactor(-3.0), CalcRGFactor(C, -6.0, 0.9), DELTA);

  C.PreampDB       := 0.0;
  C.ReplayGainMode := 1;
  AssertEquals('Track gain', DbToFactor(-6.5), CalcRGFactor(C, -6.5, 0.9), DELTA);

  C.PreampDB := 2.0;
  AssertEquals('Preamp plus gain', DbToFactor(-4.0), CalcRGFactor(C, -6.0, 0.5), DELTA);
end;

procedure TTestAudioRules.FactorIsLimited;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  C.ReplayGainMode := 1;
  AssertEquals('At most +24 dB', DbToFactor(RG_MAX_GAIN_DB), CalcRGFactor(C, 99.0, 0.0), DELTA);
  AssertEquals('At least -60 dB', DbToFactor(RG_MIN_GAIN_DB), CalcRGFactor(C, -99.0, 0.0), 0.000001);

  C.PreampDB := 20.0;
  AssertEquals('Preamp plus gain limited too', DbToFactor(RG_MAX_GAIN_DB), CalcRGFactor(C, 20.0, 0.0), DELTA);
end;

procedure TTestAudioRules.PeakProtectionOnlyWithReplayGain;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  C.ReplayGainMode := 1;
  // +10 dB on a peak of 0.9 would clip: never louder than 1 / peak
  AssertEquals('Limited by the peak', 1.0 / 0.9, CalcRGFactor(C, 10.0, 0.9), DELTA);
  AssertEquals('Unknown peak: not limited', DbToFactor(10.0), CalcRGFactor(C, 10.0, 0.0), DELTA);
  AssertEquals('No clipping: not limited', DbToFactor(-6.0), CalcRGFactor(C, -6.0, 0.9), DELTA);

  { ---> 2026-11-12: the peak protection keeps the preamp's headroom: the
    peak comes up to -3 dBFS at most with -3 dB (not to full scale) }
  C.PreampDB := -3.0;
  AssertEquals('Limited by the peak, the headroom kept', DbToFactor(-3.0) / 0.9,
    CalcRGFactor(C, 10.0, 0.9), DELTA);
  AssertEquals('Below the headroom: not limited', DbToFactor(-3.0 + 2.0),
    CalcRGFactor(C, 2.0, 0.5), DELTA);
  C.PreampDB := 0.0;

  C.ReplayGainMode := 0;
  C.PreampDB       := 6.0;
  AssertEquals('ReplayGain off: the preamp is not limited by the peak',
    DbToFactor(6.0), CalcRGFactor(C, 0.0, 0.9), DELTA);
end;

procedure TTestAudioRules.InvalidValuesCountAsZero;
var
  C: TPlayThreadConfig;
begin
  C := Cfg;
  C.ReplayGainMode := 1;
  AssertEquals('NaN gain', 1.0, CalcRGFactor(C, NaN, 0.5), DELTA);
  AssertEquals('Infinite gain', 1.0, CalcRGFactor(C, Infinity, 0.5), DELTA);
  AssertEquals('NaN peak: no protection', DbToFactor(10.0), CalcRGFactor(C, 10.0, NaN), DELTA);
  AssertEquals('Negative peak: no protection', DbToFactor(10.0), CalcRGFactor(C, 10.0, -1.0), DELTA);
end;

{ TTestTrackSource }

procedure TTestTrackSource.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestTrackSource.TearDown;
begin
  RemoveTestTree(FDir);
end;

function TTestTrackSource.Config(AMode: Integer): TPlayThreadConfig;
begin
  Result                 := Default(TPlayThreadConfig);
  Result.ReplayGainMode  := AMode;
  Result.RGTrackTags     := 'REPLAYGAIN_TRACK_GAIN';
  Result.RGTrackPeakTags := 'REPLAYGAIN_TRACK_PEAK';
  Result.RGAlbumTags     := 'REPLAYGAIN_ALBUM_GAIN';
  Result.RGAlbumPeakTags := 'REPLAYGAIN_ALBUM_PEAK';
end;

function TTestTrackSource.Prepare(const AFile: string; ANegotiatedBits: Integer;
  AMode: Integer; out APrep: TPreparedNext): Boolean;
var
  Params: TNextPrepareParams;
begin
  Params                := Default(TNextPrepareParams);
  Params.Config         := Config(AMode);
  Params.NegotiatedBits := ANegotiatedBits;
  Params.StreamId       := 7;
  Result := PrepareNextSource(Params, FDir + AFile, APrep);
end;

procedure TTestTrackSource.WriteTaggedWav(const AFile: string; AWithAlbum: Boolean;
  const ATrackGain: string);
begin
  WriteTestWav(FDir + AFile);
  if AWithAlbum then
    AddWavId3Tag(FDir + AFile, [
      'TXXX', 'REPLAYGAIN_TRACK_GAIN'#0 + ATrackGain,
      'TXXX', 'REPLAYGAIN_TRACK_PEAK'#0'0.950000',
      'TXXX', 'REPLAYGAIN_ALBUM_GAIN'#0'-7.25 dB',
      'TXXX', 'REPLAYGAIN_ALBUM_PEAK'#0'0.990000'])
  else
    AddWavId3Tag(FDir + AFile, [
      'TXXX', 'REPLAYGAIN_TRACK_GAIN'#0 + ATrackGain,
      'TXXX', 'REPLAYGAIN_TRACK_PEAK'#0'0.950000']);
end;

procedure TTestTrackSource.TrackModeReadsTheTrackTags;
var
  Gain, Peak: Double;
begin
  WriteTaggedWav('Tagged.wav', True);
  CalcReplayGainForFile(Config(1), 0, FDir + 'Tagged.wav', Gain, Peak);
  AssertEquals('Track gain', -6.5, Gain, DELTA);
  AssertEquals('Track peak', 0.95, Peak, DELTA);
end;

procedure TTestTrackSource.AlbumModeReadsTheAlbumTags;
var
  Gain, Peak: Double;
begin
  WriteTaggedWav('Tagged.wav', True);
  CalcReplayGainForFile(Config(2), 0, FDir + 'Tagged.wav', Gain, Peak);
  AssertEquals('Album gain', -7.25, Gain, DELTA);
  AssertEquals('Album peak', 0.99, Peak, DELTA);
end;

procedure TTestTrackSource.AlbumModeFallsBackToTheTrackTags;
var
  Gain, Peak: Double;
begin
  WriteTaggedWav('TrackOnly.wav', False);
  CalcReplayGainForFile(Config(2), 0, FDir + 'TrackOnly.wav', Gain, Peak);
  AssertEquals('No album tags: the track gain', -6.5, Gain, DELTA);
  AssertEquals('No album tags: the track peak', 0.95, Peak, DELTA);
end;

procedure TTestTrackSource.ReplayGainOffReadsNothing;
var
  Gain, Peak: Double;
begin
  WriteTaggedWav('Tagged.wav', True);
  CalcReplayGainForFile(Config(0), 0, FDir + 'Tagged.wav', Gain, Peak);
  AssertEquals('No gain', 0.0, Gain, DELTA);
  AssertEquals('No peak', 0.0, Peak, DELTA);

  WriteTestWav(FDir + 'Untagged.wav');
  CalcReplayGainForFile(Config(1), 0, FDir + 'Untagged.wav', Gain, Peak);
  AssertEquals('Untagged file: no gain', 0.0, Gain, DELTA);
  AssertEquals('Untagged file: no peak', 0.0, Peak, DELTA);
end;

procedure TTestTrackSource.TagGainIsLimited;
var
  Gain, Peak: Double;
begin
  WriteTaggedWav('Loud.wav', False, '+50.00 dB');
  CalcReplayGainForFile(Config(1), 0, FDir + 'Loud.wav', Gain, Peak);
  AssertEquals('At most +24 dB', RG_MAX_GAIN_DB, Gain, DELTA);
end;

procedure TTestTrackSource.WavSourceKeepsItsRate;
var
  Prep: TPreparedNext;
begin
  WriteTestWav(FDir + 'Plain.wav', 4410, 44100, 16, 2);
  AssertTrue('Prepared', Prepare('Plain.wav', 0, 0, Prep));
  try
    AssertTrue('A source', Assigned(Prep.Source));
    AssertEquals('Stream number kept', 7, Prep.StreamId);
    AssertEquals('Input rate', 44100, Prep.InRate);
    AssertEquals('No resampling: output rate = input rate', 44100, Prep.OutRate);
    AssertEquals('Source rate', 44100, Integer(Prep.Source.GetSampleRate));
    AssertEquals('16 bit', 16, Integer(Prep.Source.GetBitsPerSample));
    AssertEquals('Stereo', 2, Integer(Prep.Source.GetChannels));
    AssertFalse('Not DSD', Prep.IsDSD);
    AssertEquals('ReplayGain off: factor 1', 1.0, Prep.RGFactor, DELTA);
  finally
    FreePreparedNext(Prep);
  end;
  AssertTrue('Freed', Prep.Source = nil);
end;

procedure TTestTrackSource.SourceMatchesTheNegotiatedBitDepth;
var
  Prep: TPreparedNext;
begin
  WriteTestWav(FDir + 'Sixteen.wav', 4410, 44100, 16, 2);
  AssertTrue('Prepared', Prepare('Sixteen.wav', 24, 0, Prep));
  try
    AssertEquals('Delivered as 24 bit, as the device was opened', 24,
      Integer(Prep.Source.GetBitsPerSample));
  finally
    FreePreparedNext(Prep);
  end;
end;

procedure TTestTrackSource.MonoBecomesStereo;
var
  Prep: TPreparedNext;
begin
  WriteTestWav(FDir + 'Mono.wav', 4410, 48000, 16, 1);
  AssertTrue('Prepared', Prepare('Mono.wav', 0, 0, Prep));
  try
    AssertEquals('Mono played as stereo', 2, Integer(Prep.Source.GetChannels));
    AssertEquals('Rate', 48000, Prep.OutRate);
  finally
    FreePreparedNext(Prep);
  end;
end;

procedure TTestTrackSource.PreparedSourceGetsItsReplayGainFactor;
var
  Prep: TPreparedNext;
begin
  WriteTaggedWav('Tagged.wav', True);
  AssertTrue('Prepared', Prepare('Tagged.wav', 0, 1, Prep));
  try
    AssertEquals('Gain from the tags', -6.5, Prep.GainDB, DELTA);
    AssertEquals('Peak from the tags', 0.95, Prep.Peak, DELTA);
    AssertEquals('Factor of -6.5 dB', DbToFactor(-6.5), Prep.RGFactor, DELTA);
  finally
    FreePreparedNext(Prep);
  end;
end;

procedure TTestTrackSource.UnsupportedAndMissingFiles;
var
  Prep: TPreparedNext;
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('not audio');
    SL.SaveToFile(FDir + 'Song.ogg');
  finally
    SL.Free;
  end;

  AssertTrue('Unsupported type: no error', Prepare('Song.ogg', 0, 0, Prep));
  AssertTrue('...and nothing to queue', Prep.Source = nil);

  AssertFalse('Missing file: an error', Prepare('Gone.wav', 0, 0, Prep));
  AssertTrue('...and no source', Prep.Source = nil);
end;

// ---> ADDED: Aulumic runs with UTF-8 as its code page (Lazarus' LazUTF8):
// every `string` outside the audio units is UTF-8. The tests with non-ASCII
// file names mean something only when the test program does the same.
procedure TTestTrackSource.TheTestsRunInUtf8LikeAulumic;
begin
  AssertEquals('The system code page is UTF-8', CP_UTF8, Integer(DefaultSystemCodePage));
  AssertEquals('File names are UTF-8', CP_UTF8, Integer(DefaultFileSystemCodePage));
  AssertEquals('The non-ASCII name in UTF-8 bytes', NON_ASCII_UTF8_BYTES, Length(NonAsciiName));
  AssertEquals('...and in UTF-16 code units', NON_ASCII_UTF16_CHARS,
    Length(UTF8Decode(NonAsciiName)));
end;

// ---> ADDED: The ReplayGain tags of a file whose name is not plain ASCII
procedure TTestTrackSource.NonAsciiNameReadsTheReplayGainTags;
var
  Gain, Peak: Double;
begin
  WriteTaggedWav(NonAsciiName + '.wav', True);
  AssertTrue('The file is there', FileExists(FDir + NonAsciiName + '.wav'));
  CalcReplayGainForFile(Config(1), 0, FDir + NonAsciiName + '.wav', Gain, Peak);
  AssertEquals('Track gain', -6.5, Gain, DELTA);
  AssertEquals('Track peak', 0.95, Peak, DELTA);
end;

// ---> ADDED: PrepareNextSource (the I/O worker's next track) on a file whose
// name is not plain ASCII
procedure TTestTrackSource.NonAsciiNameIsPrepared;
var
  Prep: TPreparedNext;
begin
  WriteTaggedWav(NonAsciiName + '.wav', True);
  AssertTrue('Prepared', Prepare(NonAsciiName + '.wav', 0, 1, Prep));
  try
    AssertTrue('A source', Assigned(Prep.Source));
    AssertEquals('Input rate', 44100, Prep.InRate);
    AssertEquals('Gain from the tags', -6.5, Prep.GainDB, DELTA);
  finally
    FreePreparedNext(Prep);
  end;
end;

{ TTestDsdToPcm }

const
  // PCM output rates of DSD64 / 128 / 256 / 512 (44.1 kHz family) and DSD64 /
  // DSD128 of the 48 kHz family
  DSD_PCM_RATES: array[0..5] of Cardinal = (88200, 176400, 352800, 705600, 96000, 192000);

// Level in dB of TDsdToPcmSource's DC blocker y[n] = x[n] - x[n-1] + p*y[n-1]
function DcBlockerDB(APole, AFreq, ARate: Double): Double;
var
  W, NumRe, NumIm, DenRe, DenIm: Double;
begin
  W     := 2 * Pi * AFreq / ARate;
  NumRe := 1 - Cos(W);
  NumIm := Sin(W);
  DenRe := 1 - APole * Cos(W);
  DenIm := APole * Sin(W);
  Result := 10 * Log10((Sqr(NumRe) + Sqr(NumIm)) / (Sqr(DenRe) + Sqr(DenIm)));
end;

procedure TTestDsdToPcm.DcBlockerCornerIsTheSameAtEveryRate;
var
  I: Integer;
  Rate: Cardinal;
  P: Double;
begin
  for I := Low(DSD_PCM_RATES) to High(DSD_PCM_RATES) do
  begin
    Rate := DSD_PCM_RATES[I];
    P    := DsdDcBlockPole(Rate);
    AssertEquals('-3 dB at the corner, ' + IntToStr(Rate) + ' Hz',
      -3.01, DcBlockerDB(P, DSD_DC_BLOCK_HZ, Rate), 0.1);
    AssertTrue('20 Hz within 0.1 dB, ' + IntToStr(Rate) + ' Hz (' +
      FloatToStrF(DcBlockerDB(P, 20, Rate), ffFixed, 6, 3) + ' dB)',
      DcBlockerDB(P, 20, Rate) > -0.1);
  end;

  // No rate (an invalid file): the DSD64 rate
  AssertEquals('No rate', DsdDcBlockPole(88200), DsdDcBlockPole(0), 1e-15);
end;

procedure TTestDsdToPcm.DcBlockerKeepsTheAudioBand;
var
  I: Integer;
begin
  for I := Low(DSD_PCM_RATES) to High(DSD_PCM_RATES) do
  begin
    AssertTrue('1 kHz untouched', DcBlockerDB(DsdDcBlockPole(DSD_PCM_RATES[I]), 1000,
      DSD_PCM_RATES[I]) > -0.001);
    AssertTrue('Stable (pole below 1)', DsdDcBlockPole(DSD_PCM_RATES[I]) < 1.0);
  end;
end;

procedure TTestDsdToPcm.FadeInLastsTheSameTimeAtEveryRate;
var
  I: Integer;
begin
  for I := Low(DSD_PCM_RATES) to High(DSD_PCM_RATES) do
    AssertEquals('Fade-in at ' + IntToStr(DSD_PCM_RATES[I]) + ' Hz',
      Round(DSD_PCM_RATES[I] * DSD_FADE_IN_MS / 1000), DsdFadeInSamples(DSD_PCM_RATES[I]));
  AssertEquals('DSD64: as before', 8820, DsdFadeInSamples(88200));
  AssertEquals('DSD256: four times as many samples', 35280, DsdFadeInSamples(352800));
  AssertEquals('No rate: the DSD64 rate', 8820, DsdFadeInSamples(0));
end;

initialization
  RegisterTest(TTestAudioRules);
  RegisterTest(TTestTrackSource);
  RegisterTest(TTestDsdToPcm);

end.
