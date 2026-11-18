unit ALSourceFactory;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALSourceFactory
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Building the audio source of a track from a snapshot of the play settings
  (TPlayThreadConfig), without a TPlayThread: the decoder (WAV, FLAC, DSF and
  DFF / DSD to PCM), the resampler, mono to stereo, the ReplayGain values and
  factor, the negotiated bit depth, and the key of the chain for the
  automatic headroom (HeadroomChainKey). Used by the play thread (the current
  track) and the playback I/O worker (PrepareNextSource: the next track).
  Moved unchanged from ALAudioThread (phase 7b). The rules without file
  access (CalcTargetRate, CalcRGFactor) and the tag reading are covered by
  Tests\TestAudioRules.pas.
  ---> CHANGED (ObjFPC switch, step 2): ObjFPC like the rest of Aulumic: file
  names and tag names are UTF-8 and go to the metadata helpers unconverted.
  ============================================================================}

interface

uses
  ALReaders, ALAudioTypes;

const
  // ---> AUDIT FIX 2.4: Sane clamping bounds for ReplayGain tags (dB)
  RG_MIN_GAIN_DB = -60.0;
  RG_MAX_GAIN_DB = 24.0;

type
  // The Parameter Configuration Record
  TPlayThreadConfig = record
    FileName          : string;
    DeviceId          : string;
    // ---> AulumicNS: 0 = WASAPI exclusive (DeviceId = endpoint id), 1 = ASIO
    // (DeviceId = driver CLSID); AsioNativeDsd: DSD as DSD over ASIO
    OutputApi         : integer;
    AsioNativeDsd     : boolean;
    UseDoP            : boolean;
    ResamplePCM       : boolean;
    TargetSampleRate  : integer;
    ResampleQuality   : integer;
    BufferMs          : integer;
    RateMaps          : TRateMapArray;
    ReplayGainMode    : integer;
    RGTrackTags       : string;
    RGAlbumTags       : string;
    RGTrackPeakTags   : string;
    RGAlbumPeakTags   : string;
    DisableVolume     : boolean;
    PreampDB          : Double;  // e.g., 0.0, -2.0, -3.0
    EnableSoftClipping: Boolean;
    // ---> AulumicNS: automatic headroom (ALHeadroom, TPlayThread.RunGain):
    // the gain never goes above what the album's highest peak allows
    AutoHeadroom      : Boolean;

    UpsamplePhase     : integer;
    DownsamplePhase   : integer;

    // Advanced SoX DSP properties
    ResampleBandWidth : double;
    ResampleAntiAlias : double;

    DsdGainDB         : Integer;
    DsdLowPassFilter  : boolean;
    UseHighResTimer   : boolean;
    OptimizeAffinity  : boolean;
    EnableMMCSS       : boolean;
    NotifyHandle      : THandle;
    StartVolume       : integer;
    // ---> AulumicNS: > 0 = a stream on the engine closed just before (a
    // switch of the output or a setting during a track): the first open may
    // wait this long for the device (a FiiO K11's WASAPI endpoint is gone
    // for about 0.7 s after native DSD over ASIO) and for a refused format.
    // 0 = a missing device or a refused format is reported at once.
    SettleMs          : integer;

    FToneState        : TToneState;

    ToneDirect        : boolean;
    ToneBassDB        : integer;
    ToneLowMidDB         : integer;
    ToneMidDB         : integer;
    ToneHighMidDB         : integer;
    ToneTrebleDB      : integer;
    ToneBassHz        : integer;
    ToneLowMidHz         : integer;
    ToneMidHz         : integer;
    ToneHighMidHz         : integer;
    ToneTrebleHz      : integer;
  end;

  // ---> ADDED: Everything needed to build the next track's source away from
  // the play thread (on the playback I/O worker), so the UI thread does no disk
  // access at a gapless change. A snapshot: TPlayThread.GetPrepareParams.
  TNextPrepareParams = record
    Config         : TPlayThreadConfig;
    DsdGainDB      : Integer;                 // current DSD -> PCM gain
    NegotiatedBits : Integer;                 // 0 = not known yet
    FloatDSP       : TResamplerFloatDSPProc;  // the play thread's resampler DSP
    StreamId       : Integer;                 // set by TAudioEngine
  end;

  // ---> ADDED: A next source built by PrepareNextSource. Whoever holds the
  // record owns Source: hand it to TAudioEngine.SetPreparedNext or free it
  // with FreePreparedNext.
  TPreparedNext = record
    Source    : TAudioSource;
    StreamId  : Integer;
    InRate    : Integer;
    OutRate   : Integer;
    GainDB    : Double;
    Peak      : Double;
    RGFactor  : Double;
    DsdGainDB : Integer;
    IsDSD     : Boolean;
    HeadKey   : string;    // ---> AulumicNS: CalcHeadroomKey ('' = headroom off)
  end;

// The output sample rate of a track: its entry in RateMaps, else
// TargetSampleRate (0 = the input rate)
function  CalcTargetRate(const ACfg: TPlayThreadConfig; AInputRate: integer): integer;
// The volume factor of a ReplayGain value: PreampDB plus GainDB (when
// ReplayGainMode > 0), limited to RG_MIN_GAIN_DB..RG_MAX_GAIN_DB; with a
// peak, the loudest sample never above the preamp's level (a negative
// PreampDB; else full scale). 1.0 when DisableVolume.
function  CalcRGFactor(const ACfg: TPlayThreadConfig; GainDB, Peak: double): double;
// The ReplayGain gain / peak of a file from its tags (track or album mode,
// album falls back to track), limited; a DSD file converted to PCM with a
// DSD gain gets that gain taken off (it is not applied twice). 0 / 0 when
// ReplayGainMode = 0.
procedure CalcReplayGainForFile(const ACfg: TPlayThreadConfig; ADsdGainDB: Integer;
  const AFileName: string; out OutGain, OutPeak: double);
// ---> AulumicNS: the key of a file's peak in the headroom book (ALHeadroom):
// its album (folder, album artist and album from its tags) and the chain
// that makes the peak - HeadroomChainKey. '' when ACfg.AutoHeadroom is off.
// Reads the tags of the file.
function  CalcHeadroomKey(const ACfg: TPlayThreadConfig; const AFileName: string;
  AInRate, AOutRate: Integer): string;
// The chain of a file in a few characters: PCM or DSD converted to PCM (with
// its filter), the rate it comes at and, when resampled, the output rate and
// the resampler's settings. Two chains with the same text give the same
// samples before the gain. No file access.
function  HeadroomChainKey(const ACfg: TPlayThreadConfig; const AFileName: string;
  AInRate, AOutRate: Integer): string;
// The source of a file: decoder, resampler when needed (its float DSP is
// AFloatDSP), mono wrapped as stereo. ---> AulumicNS: DSD converted to PCM
// comes at 0 dB; ADsdGainDB is not applied here any more (the play thread's
// DSP does, after the resampler). nil for an unsupported file type;
// raises EAudioEngineError for an invalid or multi-channel file or when the
// resampler library is missing.
function  CreateSourceFor(const ACfg: TPlayThreadConfig; ADsdGainDB: Integer;
  AFloatDSP: TResamplerFloatDSPProc; const Filename: string;
  out InRate, OutRate: integer): TAudioSource;

// ---> ADDED: Builds the source of the next track from AParams: opens the file
// and its decoder (and resampler), reads its ReplayGain tags and matches the
// negotiated bit depth. Any thread; touches no TPlayThread. Never raises.
// False = an error occurred (the caller logs it); True with Source = nil = a
// file type that cannot be played (nothing to queue).
function  PrepareNextSource(const AParams: TNextPrepareParams; const AFileName: string;
  out APrep: TPreparedNext): Boolean;
// ---> ADDED: Frees a prepared source that was not handed over (nil is fine)
procedure FreePreparedNext(var APrep: TPreparedNext);

implementation

uses
  SysUtils, Math, ALMetadata, ALHeadroom, uAppStrings, uAudioUtils, uMetaUtils;

// =============================================================================
// ---> CHANGED: Source building as plain functions of a config snapshot (they
// were TPlayThread methods), so the next track can also be built on the
// playback I/O worker (PrepareNextSource). The TPlayThread methods
// CalculateRGFactor, CalculateReplayGainForFile and CreateSource call these.
// =============================================================================

function CalcTargetRate(const ACfg: TPlayThreadConfig; AInputRate: integer): integer;
var
  I: integer;
begin
  Result := AInputRate;

  if Length(ACfg.RateMaps) > 0 then
  begin
    for I := 0 to High(ACfg.RateMaps) do
    begin
      if ACfg.RateMaps[I].InRate = AInputRate then
      begin
        Result := ACfg.RateMaps[I].OutRate;
        Exit;
      end;
    end;
  end;

  if (Result = AInputRate) and (ACfg.TargetSampleRate > 0) then
    Result := ACfg.TargetSampleRate;
end;

function CalcRGFactor(const ACfg: TPlayThreadConfig; GainDB, Peak: double): double;
var
  CombinedGainDB, Ceiling: double;
begin
  Result := 1.0;
  if ACfg.DisableVolume then
    Exit;

  // ---> AUDIT FIX 2.4: Guard against NaN or Infinite inputs
  if IsNan(GainDB) or IsInfinite(GainDB) then
    GainDB := 0.0
  else
    GainDB := EnsureRange(GainDB, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);

  if IsNan(Peak) or IsInfinite(Peak) or (Peak < 0.0) then
    Peak := 0.0;

  CombinedGainDB := ACfg.PreampDB;

  if (ACfg.ReplayGainMode > 0) and (GainDB <> 0.0) then
    CombinedGainDB := CombinedGainDB + GainDB;

  CombinedGainDB := EnsureRange(CombinedGainDB, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);

  if CombinedGainDB <> 0.0 then
  begin
    Result := Power(10.0, CombinedGainDB / 20.0);

    // ---> AulumicNS (2026-11-12): the peak protection keeps the preamp's
    // headroom. It allowed the loudest sample up to full scale (1 / Peak),
    // which used up the preamp: a quiet track with a high ReplayGain gain
    // and a high peak then reached 0 dBFS, and its inter-sample peaks after
    // resampling clipped although -3 dB were set. Now the peak may come up
    // to the preamp's level at most (-3 dBFS with -3 dB).
    if (ACfg.ReplayGainMode > 0) and (Peak > 0.0) then
    begin
      Ceiling := 1.0;
      if ACfg.PreampDB < 0.0 then
        Ceiling := Power(10.0, ACfg.PreampDB / 20.0);
      if (Result * Peak) > Ceiling then
        Result := Ceiling / Peak;
    end;
  end;
end;

procedure CalcReplayGainForFile(const ACfg: TPlayThreadConfig; ADsdGainDB: Integer;
  const AFileName: string; out OutGain, OutPeak: double);
var
  CachedTags     : string;
  IsDSD          : Boolean;
begin
  OutGain := 0.0;
  OutPeak := 0.0;

  IsDSD := IsDSDFile(AFileName);

  if ACfg.ReplayGainMode > 0 then
  begin
    // ---> AulumicNS: text only: the embedded cover is not loaded for this
    CachedTags := ReadTrackTextTags(AFileName).AllTags;

    if ACfg.ReplayGainMode = 2 then // Album Mode
    begin
      OutGain := ExtractReplayGain(CachedTags, ACfg.RGAlbumTags);
      OutPeak := ExtractReplayGain(CachedTags, ACfg.RGAlbumPeakTags);

      if (OutGain = 0.0) and (OutPeak = 0.0) then
      begin
        OutGain := ExtractReplayGain(CachedTags, ACfg.RGTrackTags);
        OutPeak := ExtractReplayGain(CachedTags, ACfg.RGTrackPeakTags);
      end;
    end
    else // Track Mode
    begin
      OutGain := ExtractReplayGain(CachedTags, ACfg.RGTrackTags);
      OutPeak := ExtractReplayGain(CachedTags, ACfg.RGTrackPeakTags);
    end;

    // ---> AUDIT FIX 2.4: Sanitize and clamp parsed ReplayGain values
    if IsNan(OutGain) or IsInfinite(OutGain) then
      OutGain := 0.0
    else
      OutGain := EnsureRange(OutGain, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);

    if IsNan(OutPeak) or IsInfinite(OutPeak) or (OutPeak < 0.0) then
      OutPeak := 0.0;

    // =========================================================================
    // DSD Double-Amplification Shield
    // =========================================================================
    if IsDSD and (not ACfg.UseDoP) and (ADsdGainDB <> 0) then
    begin
      // 1. Subtract the DSD->PCM pre-amp gain so we don't double-boost
      OutGain := EnsureRange(OutGain - ADsdGainDB, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);

      // 2. Scale up the expected peak so ApplyDSP's safety clipper clamps correctly
      if OutPeak > 0.0 then
        OutPeak := OutPeak * Power(10.0, ADsdGainDB / 20.0);
    end;
  end;
end;

function HeadroomChainKey(const ACfg: TPlayThreadConfig; const AFileName: string;
  AInRate, AOutRate: Integer): string;
var
  Phase: Integer;
begin
  if IsDSDFile(AFileName) then
  begin
    if ACfg.UseDoP then
      Exit('dop');        // DSD as DSD: no gain, no peak
    Result := 'dsd';
    if ACfg.DsdLowPassFilter then
      Result := Result + 'f';
  end
  else
    Result := 'pcm';
  Result := Result + IntToStr(AInRate);

  if (AOutRate > 0) and (AOutRate <> AInRate) then
  begin
    if AOutRate > AInRate then
      Phase := ACfg.UpsamplePhase
    else
      Phase := ACfg.DownsamplePhase;
    Result := Result + '>' + IntToStr(AOutRate) +
              'q' + IntToStr(ACfg.ResampleQuality) +
              'p' + IntToStr(Phase) +
              'b' + IntToStr(Round(ACfg.ResampleBandWidth * 10000)) +
              'a' + IntToStr(Round(ACfg.ResampleAntiAlias * 10000));
  end;
end;

function CalcHeadroomKey(const ACfg: TPlayThreadConfig; const AFileName: string;
  AInRate, AOutRate: Integer): string;
var
  Meta: TAudioMetadata;
begin
  Result := '';
  if not ACfg.AutoHeadroom then
    Exit;
  Meta   := ReadTrackTextTags(AFileName);
  Result := HeadroomAlbumKey(AFileName, Meta.AlbumArtist, Meta.Album) + '|' +
            HeadroomChainKey(ACfg, AFileName, AInRate, AOutRate);
end;

function CreateSourceFor(const ACfg: TPlayThreadConfig; ADsdGainDB: Integer;
  AFloatDSP: TResamplerFloatDSPProc; const Filename: string;
  out InRate, OutRate: integer): TAudioSource;
var
  Res, TempResampler: TAudioSource;
  FinalRate: integer;
  SoxCfg: TSoXConfig;
begin
  Result  := nil;
  InRate  := 0;
  OutRate := 0;
  Res     := nil;

  // 1. Create the base audio source
  if IsDSDFile(Filename) then
  begin
    if ACfg.UseDoP then
      Res := TDsfSource.Create(Filename)
    else
    begin
      { ---> AulumicNS (2026-11-12): converted at 0 dB, always. The DSD gain
        (ADsdGainDB) is applied by the play thread's DSP together with the
        volume and the preamp (TPlayThread.FDsdGainLin), after the resampler:
        the converter clamps to 32 bits, and SACDs peak up to ~3 dB above
        their 0 dB reference - at +6 dB here that clipped (the RCO "Sacre du
        printemps": 11 of 14 tracks), and the preamp came too late to help. }
      Res := TDsdToPcmSource.Create(Filename, 0, ACfg.DsdLowPassFilter);
      // ---> AulumicNS: a target that is the DSD rate / 64 .. / 256 comes
      // straight from the DSD filter when that alone keeps it alias-free
      // (SetOutputRate): the resampler below then sees nothing to do
      if ACfg.ResamplePCM then
      begin
        FinalRate := CalcTargetRate(ACfg, Res.GetSampleRate);
        if (FinalRate > 0) and (FinalRate < Integer(Res.GetSampleRate)) then
          TDsdToPcmSource(Res).SetOutputRate(Cardinal(FinalRate));
      end;
    end;
  end
  else if IsWavFile(Filename) then
  begin
    Res := TWavSource.Create(Filename);
  end
  else if IsFlacFile(Filename) then
  begin
    Res := TFlacSource.Create(Filename);
  end
  else
  begin
    Exit; // Unsupported file type
  end;

  InRate := Res.GetSampleRate;

  // =========================================================================
  // THE 0 HZ, BIT-DEPTH & CHANNEL SANITY GATES
  // ---> AUDIT FIX 2.3, 2.5 & 2.6: Validate sample rate, bit depth, and
  // channel count (and wrap mono PCM) upfront in CreateSource!
  // =========================================================================
  if (InRate <= 0) or (not (Res.GetBitsPerSample in [16, 24, 32])) or (Res.GetChannels < 1) then
  begin
    Res.Free;
    raise EAudioEngineError.CreateTyped(aeAudioFail, ERR_AUDIO_INVALID);
  end;

  if (Res.GetChannels > 2) or (IsDSDFile(Filename) and (Res.GetChannels <> 2)) then
  begin
    Res.Free;
    raise EAudioEngineError.CreateTyped(aeMultiChannel, ERR_AUDIO_MULTI_CHANNEL);
  end;

  // 2. Apply the Resampler if required
  if (not (Res is TDsfSource)) and ACfg.ResamplePCM then
  begin
    FinalRate := CalcTargetRate(ACfg, InRate);

    // =========================================================================
    // THE BIT-PERFECT GATEKEEPER
    // =========================================================================
    if (FinalRate > 0) and (FinalRate <> InRate) then
    begin
      // ---> AulumicNS: the resampler is built in (AuResample): always there
      SoxCfg := DefaultSoXConfig;

      SoxCfg.Quality         := ACfg.ResampleQuality;
      SoxCfg.UpsamplePhase   := ACfg.UpsamplePhase;
      SoxCfg.DownsamplePhase := ACfg.DownsamplePhase;
      SoxCfg.Bandwidth       := ACfg.ResampleBandWidth;
      SoxCfg.AntiAlias       := ACfg.ResampleAntiAlias;

      // ---> AUDIT FIX 1.1: TResamplerSource.Create takes ownership of Res
      // immediately on entry (and frees Res via TResamplerSource.Destroy if
      // an exception occurs inside the constructor). Do not double-free Res!
      TempResampler := TResamplerSource.Create(Res, FinalRate, SoxCfg);
      TResamplerSource(TempResampler).OnFloatDSP := AFloatDSP;
      Res := TempResampler;
    end;
  end;

  // ---> AUDIT FIX 2.6 & 3.3: Wrap mono PCM in TMonoToStereoSource here so
  // mono-to-stereo allocation never happens inside FLock on the render thread.
  if Res.GetChannels = 1 then
    Res := TMonoToStereoSource.Create(Res);

  // 3. Finalize and return
  OutRate := Res.GetSampleRate;
  Result  := Res;
end;

function PrepareNextSource(const AParams: TNextPrepareParams; const AFileName: string;
  out APrep: TPreparedNext): Boolean;
var
  NewSource : TAudioSource;
  Wrapped   : TAudioSource;
  TempIn    : integer;
  TempOut   : integer;
  TempGain  : double;
  TempPeak  : double;
begin
  APrep           := Default(TPreparedNext);
  APrep.StreamId  := AParams.StreamId;
  APrep.DsdGainDB := AParams.DsdGainDB;
  Result          := False;

  try
    NewSource := CreateSourceFor(AParams.Config, AParams.DsdGainDB, AParams.FloatDSP,
                   AFileName, TempIn, TempOut);
  except
    Exit;
  end;

  // Unsupported file type: nothing to queue
  if NewSource = nil then
    Exit(True);

  // ---> AUDIT FIX 1.2: Protect NewSource against exceptions during ReplayGain parsing
  try
    CalcReplayGainForFile(AParams.Config, AParams.DsdGainDB, AFileName, TempGain, TempPeak);
    APrep.RGFactor := CalcRGFactor(AParams.Config, TempGain, TempPeak);
    APrep.HeadKey  := CalcHeadroomKey(AParams.Config, AFileName, TempIn, TempOut);

    // ---> AUDIT FIX 3.3: Match the negotiated WASAPI bit depth here, outside
    // FLock, exactly as CommitSeamlessSwap would (it keeps its own check as a
    // fallback, e.g. if the depth changes after a rate switch)
    if AParams.NegotiatedBits > 0 then
      NewSource.SetTargetBitDepth(AParams.NegotiatedBits);
  except
    NewSource.Free;
    Exit;
  end;

  if (AParams.NegotiatedBits > 0) and (NewSource.GetBitsPerSample <> AParams.NegotiatedBits) then
  begin
    try
      Wrapped := TBitDepthConverterSource.Create(NewSource, AParams.NegotiatedBits);
    except
      // The converter takes ownership on entry; if its constructor raises,
      // its destructor has already freed NewSource. Do not free it again.
      Exit;
    end;
    NewSource := Wrapped;
  end;

  APrep.Source  := NewSource;
  APrep.InRate  := TempIn;
  APrep.OutRate := TempOut;
  APrep.GainDB  := TempGain;
  APrep.Peak    := TempPeak;
  APrep.IsDSD   := IsDSDFile(AFileName);
  Result        := True;
end;

procedure FreePreparedNext(var APrep: TPreparedNext);
begin
  FreeAndNil(APrep.Source);
end;

end.