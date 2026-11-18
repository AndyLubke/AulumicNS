unit TestPlayback;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestPlayback
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Playback tests. A real TPlayThread plays generated files into the memory
  output of TestMemoryOutput (TPlayThread.OutputFactory) instead of a sound
  device: what reaches the "device" is checked sample by sample. The PCM
  files count their frames (TestHelpers.PatternSample), so a missing, doubled
  or changed frame shows.
    TTestPlayback (WAV):
    - a whole track: bit-perfect, padded to the device's container (32, 24,
      16 bits), silence after the last frame, the thread ends by itself;
      24-bit files on 32 / 24-bit devices
    - gapless at the same rate: no frame missing between the tracks, the
      device is not reopened; at another rate: reopened at the new rate, the
      new track from its first frame
    - seek: playback goes on exactly at the target frame
    - opening the device: a refused rate, no device, no device system (the
      message at once), a device in use (three more tries 1 s apart)
    - a buffer the device loses: reopened after 1 s, nothing lost or doubled
    - stop: the thread ends at once, every output is closed and freed
    - pause hands over no buffers, resume goes on without a gap
    - a DAC with 24 valid bits in a 32-bit container: bit-perfect at full
      volume; turned down, rounded to 24 bits with dither (the lowest 8 bits
      0, within 1.5 steps, no bias); a full 32-bit DAC gets the exact values
    - file names that are not plain ASCII (TestHelpers.NonAsciiName: accents,
      Japanese, an emoji) play, also as the gapless next track; a missing one
      is named intact in the error
    - a new volume and mute glide, without a step
    TTestPlaybackFlac: hand-written FLAC files (16 / 24 bit, uncompressed
    frames), decoded by AuDecFlac: bit-perfect, gapless, seek to the exact
    frame, dithered on a 24-in-32 DAC, a non-ASCII name.
    TTestPlaybackDsd: DSF and DFF files. DoP: every DSD byte arrives
    bit-reversed in its place with the 05 / FA markers alternating over the
    whole stream (also across a gapless change and a seek, and in the DSD
    silence after the end), on 32 / 24-bit devices, never touched on a
    24-in-32 DAC; a 16-bit device refuses DoP; a seek starts at a DSF block.
    DSD to PCM: opened at a 32nd of the DSD rate, fades in over 100 ms and
    out at the end, dithered on a 24-in-32 DAC. A non-ASCII name plays.
    TTestValidBitsRounding: the rounding itself (RoundSamplesToValidBits):
    the grid, full scale, the dither's shape and bias, other valid bits, the
    seed across buffers.
    TTestNativeLayouts: sizes and field offsets of the records WASAPI reads.
    TTestDeviceNames: the real device list and the name lookup by id agree
    (reading only, nothing is played).
  The device itself (WASAPI) and the sound are tested by ear. The "device in
  use" and recovery tests wait the play thread's real retry times (about 4 s
  and 1 s).
  =============================================================================}

interface

uses
  Classes, SysUtils, Windows, fpcunit, testregistry, ALAudioThread,
  ALSourceFactory, ALAudioTypes, ALAudioOutput, TestMemoryOutput;

type
  { TPlaybackTestBase: what every playback test needs (not registered) }
  TPlaybackTestBase = class(TTestCase)
  protected
    FDir      : string;
    FRecorder : TMemoryOutputRecorder;
    FThread   : TPlayThread;
    FSettleMs : Integer;   // TPlayThreadConfig.SettleMs of Play (0 = a normal start)
    FResample44To: Integer; // > 0 = Play resamples 44.1 kHz files to this rate
    FHeadroom : Boolean;    // TPlayThreadConfig.AutoHeadroom of Play
    FTrackGain: Boolean;    // Play applies the ReplayGain track gain of the file
    FTrebleDB : Integer;    // the tone control's treble of Play, in 0.1 dB (0 = off)
    procedure SetUp; override;
    procedure TearDown; override;
    // Starts a play thread on AFile that plays into FRecorder's output
    // AVolume 0..1000 (1000 = full: nothing touches the samples)
    procedure Play(const AFile: string; AUseDoP: Boolean = False; AVolume: Integer = 1000);
    // True when the play thread has ended within ATimeoutMs
    function  WaitForEnd(ATimeoutMs: Cardinal): Boolean;
    // Frees the play thread and starts a new recorder (a second play in a test)
    procedure Restart;
    procedure CheckNoError;
    // AData from frame AStartFrame on holds ACount pattern frames numbered
    // AFirstNumber, AFirstNumber + 1, ..., each sample the ASourceBits pattern
    // sample padded with zero bits to ADeviceBits (bit-perfect)
    procedure CheckPattern(const AMsg: string; const AData: TBytes;
      ADeviceBits, ASourceBits: Integer; AStartFrame, AFirstNumber, ACount: Integer);
    // AData[AFrom .. ATo - 1] is digital silence
    procedure CheckSilence(const AMsg: string; const AData: TBytes; AFrom, ATo: Int64);
    // AData (32-bit stereo) from frame 0 on holds ACount pattern
    // frames of ASourceBits, padded to 32 bits and times AFactor. AValidBits =
    // 32: exactly that, rounded; 24: rounded to 24 bits with dither (the lowest
    // 8 bits 0, at most 1.5 steps of 24 bits off, no bias, the dither there)
    procedure CheckScaledPattern(const AMsg: string; const AData: TBytes;
      ASourceBits: Integer; AFactor: Double; ACount, AValidBits: Integer);
  end;

  { TTestPlayback: WAV files }
  TTestPlayback = class(TPlaybackTestBase)
  published
    procedure PlaysTheWholeTrackBitPerfect;
    procedure PadsTo24And16BitDevices;
    procedure Plays24BitFilesBitPerfect;
    procedure GaplessNextTrackHasNoGap;
    procedure NextTrackAtAnotherRateReopens;
    procedure SeekContinuesAtTheTarget;
    procedure PauseHoldsTheBuffersAndResumes;
    procedure RefusedRateIsReported;
    procedure FormatRefusedForAMomentPlays;
    procedure MissingDeviceIsReportedAtOnce;
    procedure DeviceInUseIsTriedThreeMoreTimes;
    procedure LostBufferRecoversWithoutLoss;
    procedure StopEndsThePlayback;
    procedure FullVolumeOn24In32StaysBitPerfect;
    procedure LowerVolumeOn24In32IsDithered;
    procedure LowerVolumeOn32BitIsExact;
    procedure NonAsciiNamesPlayAndGoOnGapless;
    procedure MissingFileNamesTheFile;
    procedure VolumeChangeGlidesWithoutAStep;
    procedure VolumeChangeGlidesBehindTheResampler;
    procedure MuteGlidesToSilence;
  end;

  { TTestPlaybackFlac: FLAC files through AuDecFlac }
  TTestPlaybackFlac = class(TPlaybackTestBase)
  published
    procedure Flac16BitPlaysBitPerfect;
    procedure Flac24BitPlaysBitPerfect;
    procedure FlacGaplessHasNoGap;
    procedure FlacSeekContinuesAtTheTarget;
    procedure FlacLowerVolumeOn24In32IsDithered;
    procedure FlacWithNonAsciiNamePlays;
  end;

  { TTestPlaybackDsd: DSF files as DoP and as PCM }
  TTestPlaybackDsd = class(TPlaybackTestBase)
  private
    // AData from frame AStartFrame on holds ACount DoP frames of a dpCount
    // DSF file whose first frame carries the DSD bytes AFirstByte and
    // AFirstByte + 1; the marker of recorded frame I is $05 for an even I,
    // $FA for an odd one (one alternating sequence over the whole recording)
    procedure CheckDop(const AMsg: string; const AData: TBytes; ADeviceBits: Integer;
      AStartFrame, AFirstByte, ACount: Integer);
    // From frame AStartFrame to the end: DoP silence ($69 $69 and the marker)
    procedure CheckDopSilence(const AMsg: string; const AData: TBytes;
      ADeviceBits: Integer; AStartFrame: Integer);
    // The highest absolute 32-bit sample (both channels) in frames [AFrom, ATo)
    function  PeakOf(const AData: TBytes; AFrom, ATo: Integer): Double;
    // The last 32-bit stereo frame that is not silent (-1 = none)
    function  LastSoundFrame(const AData: TBytes): Integer;
  published
    procedure DopIsBitPerfectWithTheMarkers;
    procedure DopIsRefusedBelow24Bits;
    procedure DopGaplessKeepsTheMarkerSequence;
    procedure DopSeekStartsAtABlock;
    procedure DsdToPcmFadesInAndOut;
    procedure DsdToPcmFadesOutAtABufferBoundary;
    procedure DsdToPcmGaplessDoesNotDip;
    procedure DopOn24In32IsUntouched;
    procedure DsdToPcmOn24In32IsDithered;
    procedure DsfWithNonAsciiNamePlays;
    procedure DffDopIsBitPerfectWithTheMarkers;
    procedure DffAsPcmEqualsTheDsf;
  end;

  { TTestValidBitsRounding: RoundSamplesToValidBits (24 valid bits in 32) }
  TTestValidBitsRounding = class(TTestCase)
  published
    procedure RoundsToTheGridWithinOneAndAHalfSteps;
    procedure FullScaleStaysInsideTheContainer;
    procedure DitherIsUnbiasedAndTriangular;
    procedure OtherValidBitsUseTheirOwnGrid;
    procedure FullOrUnknownValidBitsChangeNothing;
    procedure TheDitherGoesOnAcrossBuffers;
  end;

  { TTestNativeLayouts: the records that Windows (WASAPI) reads keep the
    sizes and field offsets the C side expects. A change of a unit's compiler
    mode must not move them, and the compiler cannot see it. }
  TTestNativeLayouts = class(TTestCase)
  private
    procedure CheckOffset(const AName: string; ABase, AField: Pointer; AExpected: PtrUInt);
  published
    procedure WasapiRecordsMatchWindows;
  end;

  { TTestDeviceNames: the real Windows
    device list (TAudioEngine.EnumerateDevices; reading only, nothing is
    played) and the name looked up by a device's id (GetDeviceFriendlyName)
    agree, so names and ids pass both ways intact. Skipped without devices. }
  TTestDeviceNames = class(TTestCase)
  published
    procedure ListedNamesMatchTheNameLookup;
  end;

implementation

uses
  Math, uAppConsts, TestHelpers,
  ALWasapiApi,                   // TTestNativeLayouts
  ALAudioEngine;                 // TTestDeviceNames

const
  BUFFER_MS     = 50;     // the smallest buffer the play thread allows
  FRAMES_44     = 2205;   // frames of one buffer at 44.1 kHz
  END_WAIT_MS   = 10000;  // a play that does not end within this has hung
  DOP64_RATE    = 176400; // the DoP rate of DSD64 (2822400 / 16)
  PCM_BUFFER    = 4410;   // frames of one buffer of DSD64 as PCM (50 ms at 88.2 kHz)
  // 24 valid bits in a 32-bit container
  STEP_24       = 256;    // one step of 24 bits
  MAX_ERROR_24  = 383;    // the most TPDF dither of +-1 step and the rounding add up to
  VOLUME_12DB   = 500;    // the volume position of a factor of 0.25 (-12 dB)

{ TPlaybackTestBase }

procedure TPlaybackTestBase.SetUp;
begin
  FDir      := CreateTestDir;
  FRecorder := TMemoryOutputRecorder.Create;
  FThread   := nil;
  FResample44To := 0;
  FHeadroom  := False;
  FTrackGain := False;
  FTrebleDB  := 0;
end;

procedure TPlaybackTestBase.TearDown;
begin
  if Assigned(FThread) then
  begin
    FThread.StopAndWait(5000);
    FreeAndNil(FThread);
  end;
  FreeAndNil(FRecorder);
  RemoveTestTree(FDir);
end;

procedure TPlaybackTestBase.Play(const AFile: string; AUseDoP: Boolean; AVolume: Integer);
var
  C: TPlayThreadConfig;
begin
  C              := Default(TPlayThreadConfig);
  C.FileName     := AFile;
  C.UseDoP       := AUseDoP;
  C.BufferMs     := BUFFER_MS;
  C.StartVolume  := AVolume;
  C.ToneBassHz   := 100;    // the usual tone frequencies, all gains 0 (off)
  C.ToneMidHz    := 1000;
  C.ToneTrebleHz := 10000;
  C.SettleMs     := FSettleMs;
  C.AutoHeadroom := FHeadroom;
  C.ToneTrebleDB := FTrebleDB;
  if FTrackGain then
  begin
    C.ReplayGainMode  := 1;
    C.RGTrackTags     := 'REPLAYGAIN_TRACK_GAIN';
    C.RGTrackPeakTags := 'REPLAYGAIN_TRACK_PEAK';
  end;
  if FResample44To > 0 then
  begin
    C.ResamplePCM       := True;
    C.TargetSampleRate  := FResample44To;
    C.ResampleQuality   := 2;
    C.ResampleBandWidth := VAL_DEF_BANDWIDTH_FLOAT;
    C.ResampleAntiAlias := VAL_DEF_ANTI_ALIAS_FLOAT;
    SetLength(C.RateMaps, 1);
    C.RateMaps[0].InRate  := 44100;
    C.RateMaps[0].OutRate := FResample44To;
  end;

  FThread := TPlayThread.Create(C);
  FThread.OutputFactory := @FRecorder.CreateOutput;
  FThread.Start;
end;

function TPlaybackTestBase.WaitForEnd(ATimeoutMs: Cardinal): Boolean;
begin
  Result := WaitForSingleObject(FThread.Handle, ATimeoutMs) = WAIT_OBJECT_0;
end;

procedure TPlaybackTestBase.Restart;
begin
  if Assigned(FThread) then
  begin
    FThread.StopAndWait(5000);
    FreeAndNil(FThread);
  end;
  FreeAndNil(FRecorder);
  FRecorder := TMemoryOutputRecorder.Create;
end;

procedure TPlaybackTestBase.CheckNoError;
begin
  AssertFalse('No error: ' + FThread.ErrorMessage, FThread.HasError);
end;

// The sample at byte AOffset of a container of ABits, sign-extended
function SampleAt(const AData: TBytes; AOffset: Int64; ABits: Integer): Integer;
begin
  case ABits of
    16: Result := SmallInt(AData[AOffset] or (AData[AOffset + 1] shl 8));
    24: begin
          Result := AData[AOffset] or (AData[AOffset + 1] shl 8) or (AData[AOffset + 2] shl 16);
          if (Result and $800000) <> 0 then
            Result := Result or Integer($FF000000);
        end;
  else
    Result := Integer(LongWord(AData[AOffset]) or (LongWord(AData[AOffset + 1]) shl 8) or
              (LongWord(AData[AOffset + 2]) shl 16) or (LongWord(AData[AOffset + 3]) shl 24));
  end;
end;

procedure TPlaybackTestBase.CheckPattern(const AMsg: string; const AData: TBytes;
  ADeviceBits, ASourceBits: Integer; AStartFrame, AFirstNumber, ACount: Integer);
var
  SampleBytes, Shift, K, Available, ExpL, ExpR: Integer;
  Offset: Int64;
  L, R: Integer;
begin
  SampleBytes := ADeviceBits div 8;
  Shift       := ADeviceBits - ASourceBits;

  // The frames that are there first (a gap or jump is named where it is),
  // then whether all of them are there
  Available := (Length(AData) div (2 * SampleBytes)) - AStartFrame;
  if Available > ACount then
    Available := ACount;

  for K := 0 to Available - 1 do
  begin
    Offset := Int64(AStartFrame + K) * 2 * SampleBytes;
    L := SampleAt(AData, Offset, ADeviceBits);
    R := SampleAt(AData, Offset + SampleBytes, ADeviceBits);
    ExpL := PatternSample(AFirstNumber + K, 0, ASourceBits) shl Shift;
    ExpR := PatternSample(AFirstNumber + K, 1, ASourceBits) shl Shift;

    if (L <> ExpL) or (R <> ExpR) then
      Fail(Format('%s: frame %d is L=%d R=%d (number %d), expected L=%d R=%d (number %d)',
        [AMsg, K, L, R, PatternFrameOf(SarLongint(L, Shift), SarLongint(R, Shift), ASourceBits),
         ExpL, ExpR, AFirstNumber + K]));
  end;

  if Available < ACount then
    Fail(Format('%s: only %d of %d frames recorded', [AMsg, Max(Available, 0), ACount]));
end;

procedure TPlaybackTestBase.CheckSilence(const AMsg: string; const AData: TBytes; AFrom, ATo: Int64);
var
  I: Int64;
begin
  for I := AFrom to ATo - 1 do
    if AData[I] <> 0 then
      Fail(Format('%s: byte %d of %d..%d is %d', [AMsg, I, AFrom, ATo - 1, AData[I]]));
end;

procedure TPlaybackTestBase.CheckScaledPattern(const AMsg: string; const AData: TBytes;
  ASourceBits: Integer; AFactor: Double; ACount, AValidBits: Integer);
var
  K, Ch, S, OffHalf, Samples: Integer;
  Exp, Err, SumErr: Double;
begin
  if Length(AData) div 8 < ACount then
    Fail(Format('%s: only %d of %d frames recorded', [AMsg, Length(AData) div 8, ACount]));

  SumErr  := 0.0;
  OffHalf := 0;
  for K := 0 to ACount - 1 do
    for Ch := 0 to 1 do
    begin
      S   := SampleAt(AData, Int64(K) * 8 + Ch * 4, 32);
      Exp := Double(PatternSample(K, Ch, ASourceBits) shl (32 - ASourceBits)) * AFactor;
      Err := S - Exp;

      if AValidBits = 32 then
      begin
        if S <> Round(Exp) then
          Fail(Format('%s: frame %d channel %d is %d, expected %d', [AMsg, K, Ch, S, Round(Exp)]));
        Continue;
      end;

      if (S and (STEP_24 - 1)) <> 0 then
        Fail(Format('%s: frame %d channel %d is $%.8x: the lowest 8 bits are not 0',
          [AMsg, K, Ch, S]));
      if Abs(Err) > MAX_ERROR_24 then
        Fail(Format('%s: frame %d channel %d is %d, expected %.0f within 1.5 steps of 24 bits',
          [AMsg, K, Ch, S, Exp]));
      SumErr := SumErr + Err;
      if Abs(Err) > STEP_24 div 2 then
        Inc(OffHalf);
    end;

  if AValidBits = 32 then
    Exit;

  // TPDF dither: the error averages out; without it no sample would be more
  // than half a step off
  Samples := 2 * ACount;
  AssertTrue(Format('%s: no bias (mean error %.2f)', [AMsg, SumErr / Samples]),
    Abs(SumErr / Samples) < 16.0);
  AssertTrue(Format('%s: the dither is there (%d of %d samples more than half a step off)',
    [AMsg, OffHalf, Samples]), OffHalf > Samples div 10);
end;

{ TTestPlayback }

procedure TTestPlayback.PlaysTheWholeTrackBitPerfect;
const
  FRAMES = 50000;   // 22 whole buffers and part of a 23rd
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);
  Play(FDir + 'a.wav');
  AssertTrue('The thread ends by itself', WaitForEnd(END_WAIT_MS));
  CheckNoError;

  AssertEquals('Opened once', 1, FRecorder.OpenCount);
  AssertEquals('At the track''s rate', 44100, Integer(FRecorder.Opens(0).Rate));
  AssertEquals('Started once', 1, FRecorder.Starts);

  D := FRecorder.Data;
  AssertEquals('Whole buffers only', 0, Length(D) mod (FRAMES_44 * 8));
  AssertEquals('23 buffers', 23, FRecorder.BuffersFull);
  CheckPattern('32-bit device', D, 32, 16, 0, 0, FRAMES);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));

  AssertTrue('Reported as bit-perfect', FThread.IsBitPerfect);
  AssertEquals('Progress at the end', 1.0, FThread.Progress, 0.0001);
  AssertEquals('Closed once', 1, FRecorder.Closes);
  AssertEquals('Every output freed', 0, FRecorder.OutputsAlive);
end;

procedure TTestPlayback.PadsTo24And16BitDevices;
const
  FRAMES = 10000;
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);

  FRecorder.SetDeviceBits(24, 24);
  Play(FDir + 'a.wav');
  AssertTrue('24 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('24 bit: the format', 24, Integer(FRecorder.Opens(0).Format.Bits));
  D := FRecorder.Data;
  CheckPattern('24-bit device', D, 24, 16, 0, 0, FRAMES);
  CheckSilence('24 bit: after the last frame', D, FRAMES * 6, Length(D));
  AssertTrue('24 bit: bit-perfect', FThread.IsBitPerfect);

  Restart;
  FRecorder.SetDeviceBits(16, 16);
  Play(FDir + 'a.wav');
  AssertTrue('16 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('16-bit device', D, 16, 16, 0, 0, FRAMES);
  CheckSilence('16 bit: after the last frame', D, FRAMES * 4, Length(D));
  AssertTrue('16 bit: bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlayback.Plays24BitFilesBitPerfect;
const
  FRAMES = 10000;
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES, 44100, 0, 24);

  Play(FDir + 'a.wav');
  AssertTrue('32 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('24-bit file, 32-bit device', D, 32, 24, 0, 0, FRAMES);
  CheckSilence('32 bit: after the last frame', D, FRAMES * 8, Length(D));
  AssertTrue('32 bit: bit-perfect', FThread.IsBitPerfect);

  Restart;
  FRecorder.SetDeviceBits(24, 24);
  Play(FDir + 'a.wav');
  AssertTrue('24 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('24-bit file, 24-bit device', D, 24, 24, 0, 0, FRAMES);
  CheckSilence('24 bit: after the last frame', D, FRAMES * 6, Length(D));
  AssertTrue('24 bit: bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlayback.GaplessNextTrackHasNoGap;
const
  FRAMES = 30000;
var
  D: TBytes;
begin
  // The second file counts on where the first one stops
  WritePatternWav(FDir + 'a.wav', FRAMES, 44100, 0);
  WritePatternWav(FDir + 'b.wav', FRAMES, 44100, FRAMES);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'b.wav'));
  FRecorder.GoOn;

  AssertTrue('Ends after the second track', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);

  D := FRecorder.Data;
  CheckPattern('Both tracks without a gap', D, 32, 16, 0, 0, 2 * FRAMES);
  CheckSilence('After the second track', D, 2 * FRAMES * 8, Length(D));
  AssertTrue('The swap is reported', FThread.ReadAndClearSwapFlag);
end;

procedure TTestPlayback.NextTrackAtAnotherRateReopens;
const
  FRAMES_A = 20000;
  FRAMES_B = 24000;
  FIRST_B  = 100000;
var
  D: TBytes;
  StartB: Int64;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES_A, 44100, 0);
  WritePatternWav(FDir + 'b.wav', FRAMES_B, 48000, FIRST_B);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'b.wav'));
  FRecorder.GoOn;

  AssertTrue('Ends after the second track', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Reopened once', 2, FRecorder.OpenCount);
  AssertEquals('First at 44.1 kHz', 44100, Integer(FRecorder.Opens(0).Rate));
  AssertEquals('Then at 48 kHz', 48000, Integer(FRecorder.Opens(1).Rate));

  D      := FRecorder.Data;
  StartB := FRecorder.Opens(1).DataStart;
  CheckPattern('The first track', D, 32, 16, 0, 0, FRAMES_A);
  CheckSilence('Rest of the first track''s last buffer', D, FRAMES_A * 8, StartB);
  CheckPattern('The second track from its first frame', D, 32, 16, StartB div 8, FIRST_B, FRAMES_B);
  CheckSilence('After the second track', D, StartB + FRAMES_B * 8, Length(D));
  AssertEquals('Both outputs closed', 2, FRecorder.Closes);
  AssertEquals('Every output freed', 0, FRecorder.OutputsAlive);
end;

procedure TTestPlayback.SeekContinuesAtTheTarget;
const
  FRAMES = 88200;          // 2 s
  TARGET = FRAMES div 2;   // Seek(0.5)
var
  D: TBytes;
  ResetAt: Int64;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  FThread.Seek(0.5);
  FRecorder.GoOn;

  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('The device was reset once', 1, FRecorder.Resets);

  // Everything up to the reset plays from the start; after it, from the target
  D       := FRecorder.Data;
  ResetAt := FRecorder.ResetDataPos;
  AssertTrue('Some buffers before the seek', ResetAt >= 2 * FRAMES_44 * 8);
  CheckPattern('Before the seek', D, 32, 16, 0, 0, ResetAt div 8);
  CheckPattern('From the target on', D, 32, 16, ResetAt div 8, TARGET, FRAMES - TARGET);
  CheckSilence('After the last frame', D, ResetAt + (FRAMES - TARGET) * 8, Length(D));
  AssertEquals('Progress at the end', 1.0, FThread.Progress, 0.0001);
end;

procedure TTestPlayback.PauseHoldsTheBuffersAndResumes;
const
  FRAMES = 30000;
var
  Before: Integer;
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  FThread.Pause;
  FRecorder.GoOn;

  // The buffer in hand is finished, then nothing more while paused
  Sleep(150);
  Before := FRecorder.BuffersFull;
  Sleep(300);
  AssertEquals('No buffers while paused', Before, FRecorder.BuffersFull);
  AssertTrue('The device was stopped', FRecorder.Stops >= 1);
  AssertTrue('Paused', FThread.IsPaused);

  FThread.Resume;
  AssertTrue('Ends after the resume', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertTrue('Started again', FRecorder.Starts >= 2);
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);

  D := FRecorder.Data;
  CheckPattern('Nothing lost or doubled around the pause', D, 32, 16, 0, 0, FRAMES);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
end;

procedure TTestPlayback.RefusedRateIsReported;
begin
  WritePatternWav(FDir + 'a.wav', 10000);
  FRecorder.RefuseRate(44100);
  Play(FDir + 'a.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));

  AssertTrue('An error', FThread.HasError);
  AssertEquals('Rate unsupported', Ord(aeSampleRateUnsupported), Ord(FThread.ErrorType));
  AssertEquals('The refused rate', 44100, FThread.FailedSampleRate);
  AssertEquals('The device''s message', MEMORY_OUTPUT_REFUSED_TEXT, FThread.ErrorMessage);
  // a normal start: at once (no settle time)
  AssertEquals('Opened once', 1, FRecorder.OpenCount);
  AssertEquals('Nothing played', 0, Length(FRecorder.Data));
  AssertEquals('Every output freed', 0, FRecorder.OutputsAlive);

  // Right after another stream (SettleMs): asked again four
  // times, 500 ms apart, then reported
  Restart;
  FSettleMs := 3000;
  FRecorder.RefuseRate(44100);
  Play(FDir + 'a.wav');
  AssertTrue('Settling: ends', WaitForEnd(END_WAIT_MS));
  AssertEquals('Settling: rate unsupported', Ord(aeSampleRateUnsupported), Ord(FThread.ErrorType));
  AssertEquals('Settling: opened five times', 5, FRecorder.OpenCount);
end;

// Right after another stream (a switch of the output during
// a track) the device may be gone for a moment (some DACs' WASAPI endpoint
// after native DSD over ASIO: 0.5 - 0.7 s) or refuse a format: it plays once
// it is there
procedure TTestPlayback.FormatRefusedForAMomentPlays;
const
  FRAMES = 10000;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);
  FSettleMs := 3000;
  FRecorder.FailNextOpens([oorNoDevice, oorNoDevice, oorFormatUnsupported, oorFailed]);
  Play(FDir + 'a.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Opened five times', 5, FRecorder.OpenCount);
  CheckPattern('The whole track', FRecorder.Data, 32, 16, 0, 0, FRAMES);
  AssertEquals('Every output freed', 0, FRecorder.OutputsAlive);
end;

procedure TTestPlayback.MissingDeviceIsReportedAtOnce;
var
  T0: QWord;
begin
  WritePatternWav(FDir + 'a.wav', 10000);

  // No device on the first open of a play: the message at once, no waiting
  FRecorder.FailNextOpens([oorNoDevice]);
  T0 := GetTickCount64;
  Play(FDir + 'a.wav');
  AssertTrue('No device: ends', WaitForEnd(END_WAIT_MS));
  AssertTrue('No device: at once', GetTickCount64 - T0 < 900);
  AssertTrue('No device: an error', FThread.HasError);
  AssertEquals('No device: device unavailable', Ord(aeDeviceDisabled), Ord(FThread.ErrorType));
  AssertEquals('No device: opened once', 1, FRecorder.OpenCount);

  Restart;
  FRecorder.FailNextOpens([oorEndpointFail]);
  Play(FDir + 'a.wav');
  AssertTrue('No device system: ends', WaitForEnd(END_WAIT_MS));
  AssertTrue('No device system: an error', FThread.HasError);
  AssertEquals('No device system: endpoint error', Ord(aeEndpointFail), Ord(FThread.ErrorType));
  AssertEquals('No device system: every output freed', 0, FRecorder.OutputsAlive);
end;

procedure TTestPlayback.DeviceInUseIsTriedThreeMoreTimes;
const
  FRAMES = 10000;
var
  T0: QWord;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);

  // In use every time: three more tries 1 s apart, then the message
  FRecorder.FailNextOpens([oorInUse, oorInUse, oorInUse, oorInUse]);
  T0 := GetTickCount64;
  Play(FDir + 'a.wav');
  AssertTrue('Always in use: ends', WaitForEnd(END_WAIT_MS));
  AssertTrue('Always in use: waited between the tries', GetTickCount64 - T0 >= 2500);
  AssertTrue('Always in use: an error', FThread.HasError);
  AssertEquals('Always in use: device in use', Ord(aeDeviceInUse), Ord(FThread.ErrorType));
  AssertEquals('Always in use: four opens', 4, FRecorder.OpenCount);
  AssertEquals('Always in use: every output freed', 0, FRecorder.OutputsAlive);

  // In use once: the next try plays the whole track
  Restart;
  FRecorder.FailNextOpens([oorInUse]);
  Play(FDir + 'a.wav');
  AssertTrue('In use once: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('In use once: two opens', 2, FRecorder.OpenCount);
  CheckPattern('In use once: the whole track', FRecorder.Data, 32, 16, 0, 0, FRAMES);
end;

procedure TTestPlayback.LostBufferRecoversWithoutLoss;
const
  FRAMES = 50000;
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);
  FRecorder.LoseBuffer(4);
  Play(FDir + 'a.wav');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;

  AssertEquals('Reopened after the lost buffer', 2, FRecorder.OpenCount);
  AssertEquals('At the same rate', 44100, Integer(FRecorder.Opens(1).Rate));
  D := FRecorder.Data;
  CheckPattern('Nothing lost or doubled', D, 32, 16, 0, 0, FRAMES);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
  AssertEquals('Both outputs closed', 2, FRecorder.Closes);
  AssertEquals('Every output freed', 0, FRecorder.OutputsAlive);
end;

procedure TTestPlayback.StopEndsThePlayback;
begin
  WritePatternWav(FDir + 'a.wav', 88200);
  FRecorder.HoldAfterBuffers(1);
  Play(FDir + 'a.wav');
  AssertTrue('Held after one buffer', FRecorder.WaitUntilHeld(5000));

  AssertTrue('Stops within 2 s', FThread.StopAndWait(2000));
  CheckNoError;
  AssertEquals('Opened once', 1, FRecorder.OpenCount);
  AssertEquals('Closed', 1, FRecorder.Closes);
  AssertEquals('Every output freed', 0, FRecorder.OutputsAlive);
end;

// A DAC with 24 valid bits in a 32-bit container, full volume:
// the padded samples are already on the 24-bit grid, nothing is rounded
procedure TTestPlayback.FullVolumeOn24In32StaysBitPerfect;
const
  FRAMES = 10000;
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);
  WritePatternWav(FDir + 'b.wav', FRAMES, 44100, 0, 24);

  FRecorder.SetDeviceBits(32, 24);
  Play(FDir + 'a.wav');
  AssertTrue('16 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('16 bit: 32-bit container', 32, Integer(FRecorder.Opens(0).Format.Bits));
  AssertEquals('16 bit: 24 valid bits', 24, Integer(FRecorder.Opens(0).Format.ValidBits));
  D := FRecorder.Data;
  CheckPattern('16-bit file, 24 in 32', D, 32, 16, 0, 0, FRAMES);
  CheckSilence('16 bit: after the last frame', D, FRAMES * 8, Length(D));
  AssertTrue('16 bit: bit-perfect', FThread.IsBitPerfect);

  Restart;
  FRecorder.SetDeviceBits(32, 24);
  Play(FDir + 'b.wav');
  AssertTrue('24 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('24-bit file, 24 in 32', D, 32, 24, 0, 0, FRAMES);
  CheckSilence('24 bit: after the last frame', D, FRAMES * 8, Length(D));
  AssertTrue('24 bit: bit-perfect', FThread.IsBitPerfect);
end;

// Turned down on a DAC with 24 valid bits in a 32-bit container:
// every sample is rounded to 24 bits with dither
procedure TTestPlayback.LowerVolumeOn24In32IsDithered;
const
  FRAMES = 20000;
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES, 44100, 0, 24);

  FRecorder.SetDeviceBits(32, 24);
  Play(FDir + 'a.wav', False, VOLUME_12DB);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckScaledPattern('24-bit file at -12 dB, 24 in 32', D, 24, 0.25, FRAMES, 24);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
  AssertFalse('Not bit-perfect (turned down)', FThread.IsBitPerfect);
end;

// The same volume on a DAC that takes all 32 bits: exactly the
// scaled samples, nothing rounded to 24 bits
procedure TTestPlayback.LowerVolumeOn32BitIsExact;
const
  FRAMES = 20000;
var
  D: TBytes;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES, 44100, 0, 24);

  Play(FDir + 'a.wav', False, VOLUME_12DB);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('32 valid bits', 32, Integer(FRecorder.Opens(0).Format.ValidBits));
  D := FRecorder.Data;
  CheckScaledPattern('24-bit file at -12 dB, 32 bit', D, 24, 0.25, FRAMES, 32);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
end;

// Files whose names are not plain ASCII: played bit-perfect, and
// the next one follows gapless
procedure TTestPlayback.NonAsciiNamesPlayAndGoOnGapless;
const
  FRAMES = 30000;
var
  A, B: string;
  D: TBytes;
begin
  A := FDir + NonAsciiName + '.wav';
  B := FDir + NonAsciiName + ' 2.wav';
  WritePatternWav(A, FRAMES, 44100, 0);
  WritePatternWav(B, FRAMES, 44100, FRAMES);
  AssertTrue('The files are there', FileExists(A) and FileExists(B));

  FRecorder.HoldAfterBuffers(2);
  Play(A);
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(B));
  FRecorder.GoOn;

  AssertTrue('Ends after the second track', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);
  D := FRecorder.Data;
  CheckPattern('Both tracks without a gap', D, 32, 16, 0, 0, 2 * FRAMES);
  CheckSilence('After the second track', D, 2 * FRAMES * 8, Length(D));
end;

// A missing file whose name is not plain ASCII: the error names it
// intact (the WAV, FLAC and DSF readers each build that message)
procedure TTestPlayback.MissingFileNamesTheFile;
const
  EXTS: array[0..2] of string = ('.wav', '.flac', '.dsf');
var
  I: Integer;
  Name, Msg: string;
begin
  for I := Low(EXTS) to High(EXTS) do
  begin
    if I > 0 then
      Restart;
    Name := NonAsciiName + ' (gone)' + EXTS[I];
    Play(FDir + Name, EXTS[I] = '.dsf');
    AssertTrue(EXTS[I] + ': ends', WaitForEnd(END_WAIT_MS));
    AssertTrue(EXTS[I] + ': an error', FThread.HasError);
    Msg := FThread.ErrorMessage;
    AssertTrue(Format('%s: the message names the file (%s)', [EXTS[I], Msg]),
      Pos(Name, Msg) > 0);
  end;
end;

// A new volume is not applied in one step. Two buffers at
// full volume (untouched), then -12 dB: the gain glides there over 10 ms (441
// frames at 44.1 kHz) from the first frame of the next buffer, then stays.
procedure TTestPlayback.VolumeChangeGlidesWithoutAStep;
const
  FRAMES = 6 * FRAMES_44;
  RAMP   = 441;
var
  D: TBytes;
  K, Ch, F, S: Integer;
  G, Exp: Double;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.wav');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  FThread.SetVolume(VOLUME_12DB);
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  AssertTrue('All frames recorded', Length(D) div 8 >= FRAMES);

  CheckPattern('Before the change: untouched', D, 32, 16, 0, 0, 2 * FRAMES_44);
  for K := 0 to RAMP - 1 do
  begin
    F := 2 * FRAMES_44 + K;
    G := 1.0 + (0.25 - 1.0) * ((K + 1) / RAMP);
    for Ch := 0 to 1 do
    begin
      S   := SampleAt(D, Int64(F) * 8 + Ch * 4, 32);
      Exp := Double(PatternSample(F, Ch, 16) shl 16) * G;
      if Abs(S - Exp) > 2.0 then
        Fail(Format('Glide frame %d channel %d is %d, expected %.0f (gain %.4f)', [K, Ch, S, Exp, G]));
    end;
  end;
  for F := 2 * FRAMES_44 + RAMP to FRAMES - 1 do
    for Ch := 0 to 1 do
    begin
      S   := SampleAt(D, Int64(F) * 8 + Ch * 4, 32);
      Exp := Double(PatternSample(F, Ch, 16) shl 16) * 0.25;
      if S <> Round(Exp) then
        Fail(Format('After the glide: frame %d channel %d is %d, expected %d', [F, Ch, S, Round(Exp)]));
    end;
end;

// A constant level through the resampler (44.1 -> 88.2 kHz; the gain is
// applied behind it, in the float path): after the change the level falls
// evenly to a quarter within 10 ms (882 frames), never in a jump
procedure TTestPlayback.VolumeChangeGlidesBehindTheResampler;
const
  FRAMES_IN = 44100;          // one second
  LEVEL     = 16000;          // of 32768
  RAMP      = 882;
var
  Raw, D: TBytes;
  I, Total, First, Last, S, Prev: Integer;
  Full, Quarter, MaxStep, Step: Double;
begin
  Raw := nil;
  SetLength(Raw, FRAMES_IN * 4);
  for I := 0 to FRAMES_IN * 2 - 1 do
  begin
    Raw[I * 2]     := Byte(LEVEL and $FF);
    Raw[I * 2 + 1] := Byte(LEVEL shr 8);
  end;
  WriteWavData(FDir + 'dc.wav', 44100, 16, 2, Raw);

  FResample44To := 88200;
  FRecorder.HoldAfterBuffers(4);    // 200 ms: the resampler's filter has settled
  Play(FDir + 'dc.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  FThread.SetVolume(VOLUME_12DB);
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Resampled to 88.2 kHz', 88200, Integer(FRecorder.Opens(0).Rate));
  D := FRecorder.Data;
  Total := Length(D) div 8;
  AssertTrue('Audio recorded', Total > 6 * 4410);

  Full    := LEVEL * 65536.0;
  Quarter := Full * 0.25;
  // the glide: from the first frame clearly below the full level to the
  // first one at a quarter
  First := -1;
  for I := 3 * 4410 to Total - 1 do
    if SampleAt(D, Int64(I) * 8, 32) < Full * 0.999 then
    begin
      First := I;
      Break;
    end;
  AssertTrue('The level comes down', First > 0);
  Last := -1;
  for I := First to Total - 1 do
    if SampleAt(D, Int64(I) * 8, 32) <= Quarter * 1.001 then
    begin
      Last := I;
      Break;
    end;
  AssertTrue('It reaches a quarter', Last > 0);
  AssertTrue(Format('The glide takes about 10 ms (%d frames)', [Last - First]),
    (Last - First > RAMP - 30) and (Last - First <= RAMP));

  MaxStep := (Full - Quarter) / RAMP * 1.5;
  Prev := SampleAt(D, Int64(First - 1) * 8, 32);
  for I := First to Last do
  begin
    S    := SampleAt(D, Int64(I) * 8, 32);
    Step := Prev - S;
    if (Step < -Full * 0.0005) or (Step > MaxStep) then
      Fail(Format('Frame %d steps by %.0f (at most %.0f, never up)', [I - First, Step, MaxStep]));
    Prev := S;
  end;
  // and it stays there (the end of the file fades out: 50 ms left alone)
  for I := Last to Min(Total - 1, Last + 4410) do
    AssertEquals('After the glide', Quarter, SampleAt(D, Int64(I) * 8, 32), Quarter * 0.001);
end;

// Mute (volume 0): the level glides to digital silence within 10 ms
procedure TTestPlayback.MuteGlidesToSilence;
const
  FRAMES = 6 * FRAMES_44;
  RAMP   = 441;
var
  D: TBytes;
  F, Ch, S: Integer;
  G, Exp: Double;
begin
  WritePatternWav(FDir + 'a.wav', FRAMES);
  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.wav');
  AssertTrue('Held', FRecorder.WaitUntilHeld(5000));
  FThread.SetVolume(0);
  FRecorder.GoOn;
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('Before Mute: untouched', D, 32, 16, 0, 0, 2 * FRAMES_44);
  // half way down after 5 ms
  F := 2 * FRAMES_44 + RAMP div 2;
  G := 1.0 - (RAMP div 2 + 1) / RAMP;
  for Ch := 0 to 1 do
  begin
    S   := SampleAt(D, Int64(F) * 8 + Ch * 4, 32);
    Exp := Double(PatternSample(F, Ch, 16) shl 16) * G;
    AssertTrue(Format('Half way: %d, expected %.0f', [S, Exp]), Abs(S - Exp) <= 2.0);
  end;
  CheckSilence('Silent after the glide', D, Int64(2 * FRAMES_44 + RAMP) * 8, Int64(FRAMES) * 8);
end;

{ TTestPlaybackFlac }

procedure TTestPlaybackFlac.Flac16BitPlaysBitPerfect;
const
  FRAMES = 50000;   // 12 FLAC frames of 4096 and a shorter 13th
var
  D: TBytes;
begin
  WritePatternFlac(FDir + 'a.flac', FRAMES);
  Play(FDir + 'a.flac');
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('At the track''s rate', 44100, Integer(FRecorder.Opens(0).Rate));

  D := FRecorder.Data;
  CheckPattern('16-bit FLAC, 32-bit device', D, 32, 16, 0, 0, FRAMES);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
  AssertEquals('Progress at the end', 1.0, FThread.Progress, 0.0001);
end;

procedure TTestPlaybackFlac.Flac24BitPlaysBitPerfect;
const
  FRAMES = 30000;
var
  D: TBytes;
begin
  // 96 kHz: a rate of the 48 kHz family
  WritePatternFlac(FDir + 'a.flac', FRAMES, 96000, 0, 24);

  Play(FDir + 'a.flac');
  AssertTrue('32 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('32 bit: at 96 kHz', 96000, Integer(FRecorder.Opens(0).Rate));
  D := FRecorder.Data;
  CheckPattern('24-bit FLAC, 32-bit device', D, 32, 24, 0, 0, FRAMES);
  CheckSilence('32 bit: after the last frame', D, FRAMES * 8, Length(D));
  AssertTrue('32 bit: bit-perfect', FThread.IsBitPerfect);

  Restart;
  FRecorder.SetDeviceBits(24, 24);
  Play(FDir + 'a.flac');
  AssertTrue('24 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('24-bit FLAC, 24-bit device', D, 24, 24, 0, 0, FRAMES);
  CheckSilence('24 bit: after the last frame', D, FRAMES * 6, Length(D));
  AssertTrue('24 bit: bit-perfect', FThread.IsBitPerfect);
end;

procedure TTestPlaybackFlac.FlacGaplessHasNoGap;
const
  FRAMES = 30000;
var
  D: TBytes;
begin
  // Another FLAC block size (1152) than the default, the count goes on
  WritePatternFlac(FDir + 'a.flac', FRAMES, 44100, 0, 16, 1152);
  WritePatternFlac(FDir + 'b.flac', FRAMES, 44100, FRAMES, 16, 1152);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.flac');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'b.flac'));
  FRecorder.GoOn;

  AssertTrue('Ends after the second track', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);
  D := FRecorder.Data;
  CheckPattern('Both FLAC tracks without a gap', D, 32, 16, 0, 0, 2 * FRAMES);
  CheckSilence('After the second track', D, 2 * FRAMES * 8, Length(D));
end;

procedure TTestPlaybackFlac.FlacSeekContinuesAtTheTarget;
const
  FRAMES = 88200;
  TARGET = FRAMES div 2;   // Round(0.5 * total samples)
var
  D: TBytes;
  ResetAt: Int64;
begin
  WritePatternFlac(FDir + 'a.flac', FRAMES);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.flac');
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  FThread.Seek(0.5);
  FRecorder.GoOn;

  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('The device was reset once', 1, FRecorder.Resets);
  D       := FRecorder.Data;
  ResetAt := FRecorder.ResetDataPos;
  CheckPattern('Before the seek', D, 32, 16, 0, 0, ResetAt div 8);
  // The seek lands on the exact sample (inside a FLAC frame)
  CheckPattern('From the target on', D, 32, 16, ResetAt div 8, TARGET, FRAMES - TARGET);
  CheckSilence('After the last frame', D, ResetAt + (FRAMES - TARGET) * 8, Length(D));
end;

// A 16-bit FLAC turned down on a DAC with 24 valid bits in a
// 32-bit container: rounded to 24 bits with dither, as a WAV
procedure TTestPlaybackFlac.FlacLowerVolumeOn24In32IsDithered;
const
  FRAMES = 30000;
var
  D: TBytes;
begin
  WritePatternFlac(FDir + 'a.flac', FRAMES);

  FRecorder.SetDeviceBits(32, 24);
  Play(FDir + 'a.flac', False, VOLUME_12DB);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckScaledPattern('16-bit FLAC at -12 dB, 24 in 32', D, 16, 0.25, FRAMES, 24);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
  AssertFalse('Not bit-perfect (turned down)', FThread.IsBitPerfect);
end;

// A FLAC file whose name is not plain ASCII (opened by
// its UTF-8 name)
procedure TTestPlaybackFlac.FlacWithNonAsciiNamePlays;
const
  FRAMES = 20000;
var
  F: string;
  D: TBytes;
begin
  F := FDir + NonAsciiName + '.flac';
  WritePatternFlac(F, FRAMES);
  AssertTrue('The file is there', FileExists(F));

  Play(F);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckPattern('FLAC with a non-ASCII name', D, 32, 16, 0, 0, FRAMES);
  CheckSilence('After the last frame', D, FRAMES * 8, Length(D));
end;

{ TTestPlaybackDsd }

procedure TTestPlaybackDsd.CheckDop(const AMsg: string; const AData: TBytes;
  ADeviceBits: Integer; AStartFrame, AFirstByte, ACount: Integer);
var
  FrameBytes, SampleBytes, K, Ch, Available: Integer;
  Offset: Int64;
  Exp: array[0..3] of Byte;
  B1, B2, Marker: Byte;
  I, Pad: Integer;
begin
  SampleBytes := ADeviceBits div 8;   // 3 or 4
  FrameBytes  := 2 * SampleBytes;
  Pad         := SampleBytes - 3;     // zero bytes below the DoP sample (32 bit)

  Available := (Length(AData) div FrameBytes) - AStartFrame;
  if Available > ACount then
    Available := ACount;

  for K := 0 to Available - 1 do
  begin
    if ((AStartFrame + K) and 1) = 0 then
      Marker := $05
    else
      Marker := $FA;

    for Ch := 0 to 1 do
    begin
      // The DoP sample (little-endian): the 2nd DSD byte, the 1st, the marker;
      // DSF stores LSB first, DoP sends MSB first
      B1 := DsfPatternByte(AFirstByte + 2 * K, Ch, dpCount);
      B2 := DsfPatternByte(AFirstByte + 2 * K + 1, Ch, dpCount);
      FillChar(Exp, SizeOf(Exp), 0);
      Exp[Pad]     := ReverseBits(B2);
      Exp[Pad + 1] := ReverseBits(B1);
      Exp[Pad + 2] := Marker;

      Offset := Int64(AStartFrame + K) * FrameBytes + Ch * SampleBytes;
      for I := 0 to SampleBytes - 1 do
        if AData[Offset + I] <> Exp[I] then
          Fail(Format('%s: frame %d channel %d byte %d is $%.2x, expected $%.2x',
            [AMsg, K, Ch, I, AData[Offset + I], Exp[I]]));
    end;
  end;

  if Available < ACount then
    Fail(Format('%s: only %d of %d DoP frames recorded', [AMsg, Max(Available, 0), ACount]));
end;

procedure TTestPlaybackDsd.CheckDopSilence(const AMsg: string; const AData: TBytes;
  ADeviceBits: Integer; AStartFrame: Integer);
var
  FrameBytes, SampleBytes, Frames, K, Ch, I, Pad: Integer;
  Offset: Int64;
  Exp: array[0..3] of Byte;
  Marker: Byte;
begin
  SampleBytes := ADeviceBits div 8;
  FrameBytes  := 2 * SampleBytes;
  Pad         := SampleBytes - 3;
  Frames      := Length(AData) div FrameBytes;
  AssertEquals(AMsg + ': whole frames', 0, Length(AData) mod FrameBytes);

  for K := AStartFrame to Frames - 1 do
  begin
    if (K and 1) = 0 then
      Marker := $05
    else
      Marker := $FA;
    FillChar(Exp, SizeOf(Exp), 0);
    Exp[Pad]     := $69;
    Exp[Pad + 1] := $69;
    Exp[Pad + 2] := Marker;

    for Ch := 0 to 1 do
    begin
      Offset := Int64(K) * FrameBytes + Ch * SampleBytes;
      for I := 0 to SampleBytes - 1 do
        if AData[Offset + I] <> Exp[I] then
          Fail(Format('%s: frame %d channel %d byte %d is $%.2x, expected $%.2x',
            [AMsg, K, Ch, I, AData[Offset + I], Exp[I]]));
    end;
  end;
end;

function TTestPlaybackDsd.PeakOf(const AData: TBytes; AFrom, ATo: Integer): Double;
var
  K: Integer;
begin
  Result := 0.0;
  for K := AFrom to ATo - 1 do
  begin
    Result := Max(Result, Abs(Double(SampleAt(AData, Int64(K) * 8, 32))));
    Result := Max(Result, Abs(Double(SampleAt(AData, Int64(K) * 8 + 4, 32))));
  end;
end;

function TTestPlaybackDsd.LastSoundFrame(const AData: TBytes): Integer;
var
  K: Integer;
begin
  Result := -1;
  for K := (Length(AData) div 8) - 1 downto 0 do
    if (SampleAt(AData, Int64(K) * 8, 32) <> 0) or (SampleAt(AData, Int64(K) * 8 + 4, 32) <> 0) then
      Exit(K);
end;

procedure TTestPlaybackDsd.DopIsBitPerfectWithTheMarkers;
const
  BYTES  = 40000;          // 9 DSF blocks and part of a 10th, per channel
  FRAMES = BYTES div 2;    // two DSD bytes per channel and DoP frame
var
  D: TBytes;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES);

  Play(FDir + 'a.dsf', True);
  AssertTrue('32 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('32 bit: opened once', 1, FRecorder.OpenCount);
  AssertEquals('32 bit: at the DoP rate', DOP64_RATE, Integer(FRecorder.Opens(0).Rate));
  AssertTrue('32 bit: opened as DoP', FRecorder.Opens(0).IsDoP);
  D := FRecorder.Data;
  CheckDop('32-bit device', D, 32, 0, 0, FRAMES);
  CheckDopSilence('32 bit: DoP silence after the end', D, 32, FRAMES);
  AssertTrue('32 bit: bit-perfect', FThread.IsBitPerfect);

  Restart;
  FRecorder.SetDeviceBits(24, 24);
  Play(FDir + 'a.dsf', True);
  AssertTrue('24 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckDop('24-bit device', D, 24, 0, 0, FRAMES);
  CheckDopSilence('24 bit: DoP silence after the end', D, 24, FRAMES);
  AssertTrue('24 bit: bit-perfect', FThread.IsBitPerfect);
end;

{ A DFF file (MSB first, no blocks) gives the same DoP stream
  as the DSF file with the same DSD }
procedure TTestPlaybackDsd.DffDopIsBitPerfectWithTheMarkers;
const
  BYTES  = 40001;          // an odd number of bytes per channel
  FRAMES = BYTES div 2;
var
  D: TBytes;
begin
  WriteTestDff(FDir + 'a.dff', BYTES);
  Play(FDir + 'a.dff', True);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Opened once', 1, FRecorder.OpenCount);
  AssertEquals('At the DoP rate', DOP64_RATE, Integer(FRecorder.Opens(0).Rate));
  AssertTrue('Opened as DoP', FRecorder.Opens(0).IsDoP);
  D := FRecorder.Data;
  CheckDop('DFF on a 32-bit device', D, 32, 0, 0, FRAMES);
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
end;

{ DSD to PCM: the DFF and the DSF file with the same DSD give the same PCM }
procedure TTestPlaybackDsd.DffAsPcmEqualsTheDsf;
const
  BYTES = 3 * DSF_BLOCK_SIZE * 8;   // whole DSF blocks: no padding in the DSF
var
  Dsf, Dff: TBytes;
  I: Integer;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES, dpSquare);
  WriteTestDff(FDir + 'a.dff', BYTES, dpSquare);
  Play(FDir + 'a.dsf', False);
  AssertTrue('DSF: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  Dsf := FRecorder.Data;
  Restart;
  Play(FDir + 'a.dff', False);
  AssertTrue('DFF: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  Dff := FRecorder.Data;
  AssertTrue('Some PCM', Length(Dsf) > 0);
  AssertEquals('The same length', Length(Dsf), Length(Dff));
  for I := 0 to High(Dsf) do
    if Dsf[I] <> Dff[I] then
      Fail(Format('The PCM differs at byte %d', [I]));
end;

procedure TTestPlaybackDsd.DopIsRefusedBelow24Bits;
begin
  WriteTestDsf(FDir + 'a.dsf', 20000);
  FRecorder.SetDeviceBits(16, 16);
  Play(FDir + 'a.dsf', True);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));

  AssertTrue('An error', FThread.HasError);
  AssertEquals('Rate unsupported', Ord(aeSampleRateUnsupported), Ord(FThread.ErrorType));
  AssertEquals('The DoP rate', DOP64_RATE, FThread.FailedSampleRate);
  AssertEquals('Nothing played', 0, Length(FRecorder.Data));
end;

procedure TTestPlaybackDsd.DopGaplessKeepsTheMarkerSequence;
const
  BYTES_A = 40000;
  BYTES_B = 30000;
var
  D: TBytes;
  Frames: Integer;
begin
  // The second file's DSD bytes go on counting where the first one stops
  WriteTestDsf(FDir + 'a.dsf', BYTES_A);
  WriteTestDsf(FDir + 'b.dsf', BYTES_B, dpCount, BYTES_A);
  Frames := (BYTES_A + BYTES_B) div 2;

  FRecorder.HoldAfterBuffers(1);
  Play(FDir + 'a.dsf', True);
  AssertTrue('Held after one buffer', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'b.dsf'));
  FRecorder.GoOn;

  AssertTrue('Ends after the second track', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);
  D := FRecorder.Data;
  CheckDop('Both tracks, one marker sequence', D, 32, 0, 0, Frames);
  CheckDopSilence('DoP silence after the second track', D, 32, Frames);
end;

procedure TTestPlaybackDsd.DopSeekStartsAtABlock;
const
  BLOCKS     = 20;
  BYTES      = BLOCKS * DSF_BLOCK_SIZE + 1000;       // 20 whole blocks and a bit
  TARGET     = (BLOCKS div 2) * DSF_BLOCK_SIZE;       // Seek(0.5): block 10
var
  D: TBytes;
  ResetAt: Int64;
  ResetFrame: Integer;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES);

  FRecorder.HoldAfterBuffers(1);
  Play(FDir + 'a.dsf', True);
  AssertTrue('Held after one buffer', FRecorder.WaitUntilHeld(5000));
  FThread.Seek(0.5);
  FRecorder.GoOn;

  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('The device was reset once', 1, FRecorder.Resets);
  D          := FRecorder.Data;
  ResetAt    := FRecorder.ResetDataPos;
  ResetFrame := ResetAt div 8;
  CheckDop('Before the seek', D, 32, 0, 0, ResetFrame);
  // From the start of block 10 on; the markers go on alternating
  CheckDop('From the target block on', D, 32, ResetFrame, TARGET, (BYTES - TARGET) div 2);
  CheckDopSilence('DoP silence after the end', D, 32, ResetFrame + (BYTES - TARGET) div 2);
end;

procedure TTestPlaybackDsd.DsdToPcmFadesInAndOut;
const
  BYTES      = 180000;          // 1,440,000 DSD64 bits per channel
  PCM_RATE   = 88200;           // DSD64 / 32
  PCM_FRAMES = BYTES * 8 div 32;  // 45000: not a whole number of buffers
  FADE_IN    = PCM_RATE div 10;   // DSD_FADE_IN_MS = 100 ms
  LAST_BUF   = (PCM_FRAMES div PCM_BUFFER) * PCM_BUFFER;  // the last (partial) buffer
var
  D: TBytes;
  LastAudio: Integer;
  Mid, Half, StartPeak, LastStart, EndPeak: Double;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES, dpSquare);
  Play(FDir + 'a.dsf', False);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Opened at a 32nd of the DSD rate', PCM_RATE, Integer(FRecorder.Opens(0).Rate));
  AssertFalse('Not opened as DoP', FRecorder.Opens(0).IsDoP);
  AssertFalse('Not bit-perfect (converted)', FThread.IsBitPerfect);

  D         := FRecorder.Data;
  LastAudio := LastSoundFrame(D);
  AssertTrue(Format('The audio ends near frame %d (last sound at %d)', [PCM_FRAMES, LastAudio]),
    Abs(LastAudio - PCM_FRAMES) < 200);

  Mid       := PeakOf(D, 20000, 30000);
  Half      := PeakOf(D, FADE_IN div 2 - 100, FADE_IN div 2);
  StartPeak := PeakOf(D, 0, 10);
  LastStart := PeakOf(D, LAST_BUF, LAST_BUF + 100);
  EndPeak   := PeakOf(D, LastAudio - 20, LastAudio + 1);

  AssertTrue(Format('Loud in the middle (%.0f)', [Mid]), Mid > 0.2 * 2147483648.0);
  AssertTrue(Format('Starts silent (%.0f)', [StartPeak]), StartPeak < 0.01 * Mid);
  AssertTrue(Format('Half way up after 50 ms (%.2f)', [Half / Mid]),
    (Half > 0.35 * Mid) and (Half < 0.65 * Mid));
  // Only the last buffer fades (from its start at full level to 0)
  AssertTrue(Format('The last buffer starts at full level (%.2f)', [LastStart / Mid]),
    LastStart > 0.7 * Mid);
  AssertTrue(Format('Fades out at the end (%.3f)', [EndPeak / Mid]), EndPeak < 0.05 * Mid);
end;

procedure TTestPlaybackDsd.DsdToPcmFadesOutAtABufferBoundary;
const
  PCM_FRAMES = 10 * PCM_BUFFER;         // 44100: exactly 10 buffers
  BYTES      = PCM_FRAMES * 32 div 8;   // 176400 DSD64 bytes per channel
  LAST_BUF   = PCM_FRAMES - PCM_BUFFER;
var
  D: TBytes;
  LastAudio: Integer;
  Mid, LastStart, EndPeak: Double;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES, dpSquare);
  Play(FDir + 'a.dsf', False);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  // The track fills its last buffer completely; the next read finds nothing
  AssertEquals('10 full buffers', 10, FRecorder.BuffersFull);

  D         := FRecorder.Data;
  LastAudio := LastSoundFrame(D);
  AssertTrue(Format('The audio ends at frame %d (last sound at %d)', [PCM_FRAMES, LastAudio]),
    Abs(LastAudio - (PCM_FRAMES - 1)) < 50);

  Mid       := PeakOf(D, 20000, 30000);
  LastStart := PeakOf(D, LAST_BUF, LAST_BUF + 100);
  EndPeak   := PeakOf(D, LastAudio - 20, LastAudio + 1);
  AssertTrue(Format('The last buffer starts at full level (%.2f)', [LastStart / Mid]),
    LastStart > 0.7 * Mid);
  AssertTrue(Format('Fades out at the end of the last full buffer (%.3f)', [EndPeak / Mid]),
    EndPeak < 0.05 * Mid);
end;

procedure TTestPlaybackDsd.DsdToPcmGaplessDoesNotDip;
const
  PCM_A   = 10 * PCM_BUFFER;   // the first track ends exactly on a buffer boundary
  BYTES_A = PCM_A * 32 div 8;
  BYTES_B = 90000;             // 22500 frames: ends inside a buffer
var
  D: TBytes;
  LastAudio: Integer;
  Mid, BeforeChange, AfterChange, EndPeak: Double;
begin
  // The second file's square wave goes on where the first one stops
  WriteTestDsf(FDir + 'a.dsf', BYTES_A, dpSquare);
  WriteTestDsf(FDir + 'b.dsf', BYTES_B, dpSquare, BYTES_A);

  FRecorder.HoldAfterBuffers(2);
  Play(FDir + 'a.dsf', False);
  AssertTrue('Held after two buffers', FRecorder.WaitUntilHeld(5000));
  AssertTrue('Next track queued', FThread.SetNextFile(FDir + 'b.dsf'));
  FRecorder.GoOn;

  AssertTrue('Ends after the second track', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertEquals('Not reopened', 1, FRecorder.OpenCount);

  D            := FRecorder.Data;
  Mid          := PeakOf(D, 20000, 30000);
  BeforeChange := PeakOf(D, PCM_A - 100, PCM_A);
  AfterChange  := PeakOf(D, PCM_A, PCM_A + 100);
  AssertTrue(Format('No fade-out before the change (%.2f)', [BeforeChange / Mid]),
    BeforeChange > 0.7 * Mid);
  AssertTrue(Format('No fade-in after the change (%.2f)', [AfterChange / Mid]),
    AfterChange > 0.7 * Mid);

  LastAudio := LastSoundFrame(D);
  EndPeak   := PeakOf(D, LastAudio - 20, LastAudio + 1);
  AssertTrue(Format('The second track ends near frame %d (last sound at %d)',
    [PCM_A + BYTES_B * 8 div 32, LastAudio]), Abs(LastAudio - (PCM_A + BYTES_B * 8 div 32)) < 200);
  AssertTrue(Format('The second track fades out (%.3f)', [EndPeak / Mid]), EndPeak < 0.05 * Mid);
end;

// DoP on a DAC with 24 valid bits in a 32-bit container: the DSD
// bytes and the markers are never rounded, also with the volume turned down
procedure TTestPlaybackDsd.DopOn24In32IsUntouched;
const
  BYTES  = 40000;
  FRAMES = BYTES div 2;
var
  D: TBytes;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES);

  FRecorder.SetDeviceBits(32, 24);
  Play(FDir + 'a.dsf', True, VOLUME_12DB);
  AssertTrue('Ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertTrue('Opened as DoP', FRecorder.Opens(0).IsDoP);
  D := FRecorder.Data;
  CheckDop('DoP, 24 in 32', D, 32, 0, 0, FRAMES);
  CheckDopSilence('DoP silence after the end', D, 32, FRAMES);
  AssertTrue('Bit-perfect', FThread.IsBitPerfect);
end;

// DSD to PCM on a DAC with 24 valid bits in a 32-bit container:
// the samples of a full 32-bit DAC, rounded to 24 bits with dither
procedure TTestPlaybackDsd.DsdToPcmOn24In32IsDithered;
const
  BYTES = 90000;   // 22500 PCM frames
var
  D32, D24: TBytes;
  K, S32, S24, OffHalf, Samples: Integer;
  Err, SumErr: Double;
begin
  WriteTestDsf(FDir + 'a.dsf', BYTES, dpSquare);

  Play(FDir + 'a.dsf', False);
  AssertTrue('32 bit: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D32 := FRecorder.Data;

  Restart;
  FRecorder.SetDeviceBits(32, 24);
  Play(FDir + 'a.dsf', False);
  AssertTrue('24 in 32: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertFalse('Not bit-perfect (converted)', FThread.IsBitPerfect);
  D24 := FRecorder.Data;
  AssertEquals('As long as on the 32-bit DAC', Length(D32), Length(D24));

  // Every sample of the recording (the silence after the end stays 0)
  Samples := Length(D24) div 4;
  SumErr  := 0.0;
  OffHalf := 0;
  for K := 0 to Samples - 1 do
  begin
    S32 := SampleAt(D32, Int64(K) * 4, 32);
    S24 := SampleAt(D24, Int64(K) * 4, 32);
    if (S24 and (STEP_24 - 1)) <> 0 then
      Fail(Format('Sample %d is $%.8x: the lowest 8 bits are not 0', [K, S24]));
    Err := Double(S24) - S32;
    if Abs(Err) > MAX_ERROR_24 then
      Fail(Format('Sample %d is %d, on the 32-bit DAC %d: more than 1.5 steps of 24 bits off',
        [K, S24, S32]));
    SumErr := SumErr + Err;
    if Abs(Err) > STEP_24 div 2 then
      Inc(OffHalf);
  end;

  AssertTrue(Format('No bias (mean error %.2f)', [SumErr / Samples]), Abs(SumErr / Samples) < 16.0);
  AssertTrue(Format('The dither is there (%d of %d samples more than half a step off)',
    [OffHalf, Samples]), OffHalf > Samples div 10);
end;

// A DSF file whose name is not plain ASCII: as DoP (exact) and as
// PCM (it plays)
procedure TTestPlaybackDsd.DsfWithNonAsciiNamePlays;
const
  BYTES  = 40000;
  FRAMES = BYTES div 2;
var
  F: string;
  D: TBytes;
begin
  F := FDir + NonAsciiName + '.dsf';
  WriteTestDsf(F, BYTES);
  AssertTrue('The file is there', FileExists(F));

  Play(F, True);
  AssertTrue('DoP: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  D := FRecorder.Data;
  CheckDop('DoP with a non-ASCII name', D, 32, 0, 0, FRAMES);

  Restart;
  Play(F, False);
  AssertTrue('PCM: ends', WaitForEnd(END_WAIT_MS));
  CheckNoError;
  AssertTrue('PCM: sound', LastSoundFrame(FRecorder.Data) > 0);
end;

{ TTestValidBitsRounding }

// A repeatable spread of 32-bit values over the whole range
function SpreadValue(AIndex: Integer): LongInt;
begin
  Result := LongInt(LongWord((Int64(AIndex) * 2654435761) and $FFFFFFFF));
end;

procedure TTestValidBitsRounding.RoundsToTheGridWithinOneAndAHalfSteps;
const
  COUNT = 100000;
var
  A, B: array of LongInt;
  I: Integer;
  Seed: Cardinal;
begin
  SetLength(A, COUNT);
  SetLength(B, COUNT);
  for I := 0 to COUNT - 1 do
  begin
    A[I] := SpreadValue(I);
    B[I] := A[I];
  end;

  Seed := 1;
  RoundSamplesToValidBits(@B[0], COUNT, 24, Seed);

  for I := 0 to COUNT - 1 do
  begin
    if (B[I] and (STEP_24 - 1)) <> 0 then
      Fail(Format('%d became $%.8x: the lowest 8 bits are not 0', [A[I], B[I]]));
    if Abs(Int64(B[I]) - A[I]) > MAX_ERROR_24 then
      Fail(Format('%d became %d: more than 1.5 steps off', [A[I], B[I]]));
  end;
end;

procedure TTestValidBitsRounding.FullScaleStaysInsideTheContainer;
const
  COUNT    = 10000;
  TOP_24   = High(LongInt) - (STEP_24 - 1);   // $7FFFFF00: the highest 24-bit value
var
  A: array of LongInt;
  I: Integer;
  Seed: Cardinal;
begin
  SetLength(A, COUNT);
  for I := 0 to COUNT - 1 do
    if Odd(I) then
      A[I] := Low(LongInt)
    else
      A[I] := High(LongInt);

  Seed := 1;
  RoundSamplesToValidBits(@A[0], COUNT, 24, Seed);

  for I := 0 to COUNT - 1 do
    if Odd(I) then
    begin
      // Never wraps round to the other end
      if (A[I] <> Low(LongInt)) and (A[I] <> Low(LongInt) + STEP_24) then
        Fail(Format('The negative full scale became %d', [A[I]]));
    end
    else if A[I] <> TOP_24 then
      Fail(Format('The positive full scale became $%.8x, expected $%.8x', [A[I], TOP_24]));
end;

procedure TTestValidBitsRounding.DitherIsUnbiasedAndTriangular;
const
  COUNT   = 100000;
  ON_GRID = 40 * STEP_24;
  BETWEEN = 40 * STEP_24 + 85;   // a third of the way to the next step
var
  A: array of LongInt;
  I, Up, Down: Integer;
  Seed: Cardinal;
  Sum: Double;
begin
  SetLength(A, COUNT);
  Seed := 1;

  // A value on the grid: TPDF dither of +-1 step moves about an eighth of the
  // samples one step up and an eighth one step down, never further; plain
  // rounding would move none
  for I := 0 to COUNT - 1 do
    A[I] := ON_GRID;
  RoundSamplesToValidBits(@A[0], COUNT, 24, Seed);
  Up   := 0;
  Down := 0;
  for I := 0 to COUNT - 1 do
    if A[I] = ON_GRID + STEP_24 then
      Inc(Up)
    else if A[I] = ON_GRID - STEP_24 then
      Inc(Down)
    else if A[I] <> ON_GRID then
      Fail(Format('%d became %d: more than one step', [ON_GRID, A[I]]));
  AssertTrue(Format('About an eighth one step up (%d of %d)', [Up, COUNT]),
    (Up > COUNT div 10) and (Up < COUNT div 7));
  AssertTrue(Format('About an eighth one step down (%d of %d)', [Down, COUNT]),
    (Down > COUNT div 10) and (Down < COUNT div 7));

  // A value between two steps: on average it stays where it is (plain
  // rounding would always give the lower step, 85 below)
  for I := 0 to COUNT - 1 do
    A[I] := BETWEEN;
  RoundSamplesToValidBits(@A[0], COUNT, 24, Seed);
  Sum := 0.0;
  for I := 0 to COUNT - 1 do
    Sum := Sum + A[I];
  AssertEquals('The mean of a value between two steps', BETWEEN, Sum / COUNT, 4.0);
end;

procedure TTestValidBitsRounding.OtherValidBitsUseTheirOwnGrid;
const
  COUNT = 20000;
  VALID: array[0..1] of Integer = (20, 16);
var
  A, B: array of LongInt;
  I, V, Step: Integer;
  Seed: Cardinal;
begin
  SetLength(A, COUNT);
  SetLength(B, COUNT);
  for V := Low(VALID) to High(VALID) do
  begin
    Step := 1 shl (32 - VALID[V]);
    for I := 0 to COUNT - 1 do
    begin
      A[I] := SpreadValue(I + 7);
      B[I] := A[I];
    end;

    Seed := 1;
    RoundSamplesToValidBits(@B[0], COUNT, VALID[V], Seed);

    for I := 0 to COUNT - 1 do
    begin
      if (B[I] and (Step - 1)) <> 0 then
        Fail(Format('%d valid bits: %d became $%.8x, not on the grid', [VALID[V], A[I], B[I]]));
      if Abs(Int64(B[I]) - A[I]) > (3 * Step) div 2 - 1 then
        Fail(Format('%d valid bits: %d became %d: more than 1.5 steps off', [VALID[V], A[I], B[I]]));
    end;
  end;
end;

procedure TTestValidBitsRounding.FullOrUnknownValidBitsChangeNothing;
const
  COUNT = 1000;
  VALID: array[0..4] of Integer = (0, 8, 15, 32, 33);
var
  A, B: array of LongInt;
  I, V: Integer;
  Seed: Cardinal;
begin
  SetLength(A, COUNT);
  SetLength(B, COUNT);
  for V := Low(VALID) to High(VALID) do
  begin
    for I := 0 to COUNT - 1 do
    begin
      A[I] := SpreadValue(I);
      B[I] := A[I];
    end;
    Seed := 12345;
    RoundSamplesToValidBits(@B[0], COUNT, VALID[V], Seed);
    for I := 0 to COUNT - 1 do
      AssertEquals(Format('%d valid bits: sample %d unchanged', [VALID[V], I]), A[I], B[I]);
    AssertEquals(Format('%d valid bits: the seed unchanged', [VALID[V]]), 12345, Integer(Seed));
  end;

  // No samples: nothing happens
  Seed := 12345;
  RoundSamplesToValidBits(nil, COUNT, 24, Seed);
  RoundSamplesToValidBits(@B[0], 0, 24, Seed);
  AssertEquals('No samples: the seed unchanged', 12345, Integer(Seed));
end;

procedure TTestValidBitsRounding.TheDitherGoesOnAcrossBuffers;
const
  COUNT = 1000;
  SPLIT = 400;
var
  A, B: array of LongInt;
  I: Integer;
  S1, S2: Cardinal;
begin
  SetLength(A, COUNT);
  SetLength(B, COUNT);

  // Two calls that hand the seed on give the same as one call over both
  for I := 0 to COUNT - 1 do
  begin
    A[I] := SpreadValue(I);
    B[I] := A[I];
  end;
  S1 := 777;
  RoundSamplesToValidBits(@A[0], COUNT, 24, S1);
  S2 := 777;
  RoundSamplesToValidBits(@B[0], SPLIT, 24, S2);
  RoundSamplesToValidBits(@B[SPLIT], COUNT - SPLIT, 24, S2);
  AssertTrue('The seed moves on', S1 <> 777);
  AssertEquals('The same seed after both', Integer(S1), Integer(S2));
  for I := 0 to COUNT - 1 do
    AssertEquals(Format('Sample %d the same', [I]), A[I], B[I]);

  // Seed 0 starts like the default seed
  for I := 0 to COUNT - 1 do
  begin
    A[I] := SpreadValue(I);
    B[I] := A[I];
  end;
  S1 := 0;
  RoundSamplesToValidBits(@A[0], COUNT, 24, S1);
  S2 := $A341316C;
  RoundSamplesToValidBits(@B[0], COUNT, 24, S2);
  for I := 0 to COUNT - 1 do
    AssertEquals(Format('Seed 0: sample %d as with the default seed', [I]), A[I], B[I]);
end;

{ TTestNativeLayouts }

procedure TTestNativeLayouts.CheckOffset(const AName: string; ABase, AField: Pointer;
  AExpected: PtrUInt);
begin
  AssertEquals(AName + ': offset', Int64(AExpected), Int64(PtrUInt(AField) - PtrUInt(ABase)));
end;

procedure TTestNativeLayouts.WasapiRecordsMatchWindows;
var
  Wfx: WAVEFORMATEXTENSIBLE;
  Key: TPropertyKey;
  PV : TPropVariant;
begin
  Wfx := Default(WAVEFORMATEXTENSIBLE);
  Key := Default(TPropertyKey);
  PV  := Default(TPropVariant);

  // mmreg.h: WAVEFORMATEX is packed, 18 bytes
  AssertEquals('WAVEFORMATEX: size', 18, SizeOf(WAVEFORMATEX));
  CheckOffset('nChannels', @Wfx.Format, @Wfx.Format.nChannels, 2);
  CheckOffset('nSamplesPerSec', @Wfx.Format, @Wfx.Format.nSamplesPerSec, 4);
  CheckOffset('nAvgBytesPerSec', @Wfx.Format, @Wfx.Format.nAvgBytesPerSec, 8);
  CheckOffset('nBlockAlign', @Wfx.Format, @Wfx.Format.nBlockAlign, 12);
  CheckOffset('wBitsPerSample', @Wfx.Format, @Wfx.Format.wBitsPerSample, 14);
  CheckOffset('cbSize', @Wfx.Format, @Wfx.Format.cbSize, 16);

  // mmreg.h: WAVEFORMATEXTENSIBLE, 40 bytes
  AssertEquals('WAVEFORMATEXTENSIBLE: size', 40, SizeOf(WAVEFORMATEXTENSIBLE));
  CheckOffset('wValidBitsPerSample', @Wfx, @Wfx.wValidBitsPerSample, 18);
  CheckOffset('dwChannelMask', @Wfx, @Wfx.dwChannelMask, 20);
  CheckOffset('SubFormat', @Wfx, @Wfx.SubFormat, 24);

  // PROPERTYKEY: a GUID and a DWORD
  AssertEquals('PROPERTYKEY: size', 20, SizeOf(TPropertyKey));
  CheckOffset('pid', @Key, @Key.pid, 16);

  // PROPVARIANT (64 bit): the type, three reserved words, a 16-byte value
  AssertEquals('PROPVARIANT: size', 24, SizeOf(TPropVariant));
  CheckOffset('pwszVal', @PV, @PV.pwszVal, 8);
end;

{ TTestDeviceNames }

procedure TTestDeviceNames.ListedNamesMatchTheNameLookup;
var
  List: TStringList;
  DefaultIdx, I, P: Integer;
  DevName, DevId: string;
begin
  List := TStringList.Create;
  try
    TAudioEngine.EnumerateDevices(List, DefaultIdx);
    if List.Count = 0 then
      Ignore('No active audio output device: nothing to compare');
    AssertTrue('The default is in the list (or none)',
      (DefaultIdx >= -1) and (DefaultIdx < List.Count));

    for I := 0 to List.Count - 1 do
    begin
      // 'Name|Id' (the id holds no '|')
      P := LastDelimiter('|', List[I]);
      AssertTrue('Name|Id: ' + List[I], P > 1);
      DevName := Copy(List[I], 1, P - 1);
      DevId   := Copy(List[I], P + 1, MaxInt);
      AssertTrue('A render endpoint id: ' + DevId, Pos('{0.0.0.', DevId) = 1);
      // A device without a name is listed as Id|Id; the lookup gives '' then
      if DevName <> DevId then
        AssertEquals('The name looked up by its id', DevName,
          string(TAudioEngine.GetDeviceFriendlyName(DevId)));
    end;

    AssertEquals('An unknown id has no name', '',
      string(TAudioEngine.GetDeviceFriendlyName('{0.0.0.00000000}.{00000000-0000-0000-0000-000000000000}')));
  finally
    List.Free;
  end;
end;

initialization
  RegisterTest(TTestPlayback);
  RegisterTest(TTestPlaybackFlac);
  RegisterTest(TTestPlaybackDsd);
  RegisterTest(TTestValidBitsRounding);
  RegisterTest(TTestNativeLayouts);
  RegisterTest(TTestDeviceNames);

end.
