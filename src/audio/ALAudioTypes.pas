unit ALAudioTypes;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALAudioTypes
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Shared constants and types used for Audio Engine settings.
  =============================================================================}

interface

uses
  SysUtils; // Required for the Exception class

const
  // =========================================================================
  // Default Audio values
  // =========================================================================
  // Core Defaults
  VAL_DEF_VOLUME          = 1000;
  VAL_MIN_BUFFER          = 50;
  VAL_DEF_PCMBUFFER       = 250;
  VAL_DEF_DSDBUFFER       = 500;
  VAL_DEF_SAMPLERATE44    = 176400;
  VAL_DEF_SAMPLERATE48    = 192000;
  VAL_DEF_TARGET_RATE     = 0;     // 0 = Native Rate (Bypass)

  VAL_DEF_DSDGAIN         = 6;

  VAL_DEF_BANDWIDTH_IDX   = 0;
  VAL_DEF_ANTI_ALIAS_IDX  = 0;

  // Audio Engine Defaults
  VAL_DEF_PREAMP_DB       = 0;
  VAL_DEF_RESAMPLE_QUAL   = 2; // High (24-bit Precision)
  VAL_DEF_UPSAMPLE_PHASE  = 1; // Intermediate Phase
  VAL_DEF_DOWNSAMPLE_PHASE= 2; // Minimum Phase
  VAL_DEF_BYPASS_THRESH   = 0; // None (Resample All)
  VAL_DEF_RG_MODE         = 0; // Disabled

  // Math & Sanitization Limits
  VAL_MIN_VOLUME          = 0;
  VAL_MAX_VOLUME          = 1000;
  VAL_SAFE_FALLBACK       = -999999;

  VAL_MIN_TONE_GAIN       = -100;
  VAL_MAX_TONE_GAIN       = 100;

  VAL_DEF_TONE_DB         = 0;     // 0 dB (Flat EQ)
  VAL_DEF_TONE_DIRECT     = True;  // Direct Mode enabled by default
  VAL_DEF_BASSHZ          = 150;
  VAL_DEF_LOWMIDHZ        = 400;   // five bands
  VAL_DEF_MIDHZ           = 1000;
  VAL_DEF_HIGHMIDHZ       = 4000;
  VAL_DEF_TREBLEHZ        = 6000;

  VAL_DEF_BANDWIDTH_FLOAT = 91.3;
  VAL_DEF_ANTI_ALIAS_FLOAT= 100.0;

  // Resampler Bandwidth (Roll-off) Options
  VAL_BANDWIDTH_MED       = 95.0;
  VAL_BANDWIDTH_FAST      = 99.0;

  // Resampler Anti-Alias (Suppression) Options
  VAL_ANTIALIAS_HIGH      = 105.0;
  VAL_ANTIALIAS_STD       = 110.0;


const
  // Peak meter slices. The audio thread measures the peak of every
  // METER_SLICE_MS of output and keeps the last METER_RING_SIZE slices
  // (power of 2) for the UI.
  METER_SLICE_MS  = 20;
  METER_RING_SIZE = 256;

type
  // Peak of one meter slice, 0.0 .. 1.0 (1.0 = full scale)
  TMeterSlice = record
    PeakL: Single;
    PeakR: Single;
  end;

  // 1. The strongly-typed Error Enum
  TAudioErrorType = (
    aeNone,
    aeUnknown,
    aeFileNotFound,
    aeDeviceInUse,
    aeExclusiveDisabled,
    aeSampleRateUnsupported,
    aeDeviceDisabled,
    aeEndpointFail,
    aeBufferUnaligned,
    aeAccessDenied,
    aeAudioFail,
    aeResamplerMissing,
    aeNotDSD,
    aeDsdHeader,
    aeFlacDecoder,
    aeFlacInit,
    aeNotWav,
    aeWavInvalid,
    aeMultiChannel
  );

  // Five bands - bass (low shelf), low mid, mid,
  // high mid (peaking), treble (high shelf); in this order in every array
  // of bands (TToneInts). Gains in tenths of a dB.
  TToneState = record
    DirectMode  : Boolean;
    BassDB      : Integer;
    LowMidDB    : Integer;
    MidDB       : Integer;
    HighMidDB   : Integer;
    TrebleDB    : Integer;
    BassHz      : Integer;
    LowMidHz    : Integer;
    MidHz       : Integer;
    HighMidHz   : Integer;
    TrebleHz    : Integer;
    // How wide the three middle bands work around their frequency
    // (TONE_WIDTH_*; 0 = normal, so a cleared record is the plain setting)
    LowMidWidth : Integer;
    MidWidth    : Integer;
    HighMidWidth: Integer;
  end;

const
  TONE_BANDS = 5;

  TONE_WIDTH_NORMAL = 0;   // about two octaves
  TONE_WIDTH_NARROW = 1;   // about one octave
  TONE_WIDTH_WIDE   = 2;   // about three octaves
  TONE_WIDTH_MAX    = 2;

type
  TToneInts = array[0..TONE_BANDS - 1] of Integer;

function ToneGainsOf(const S: TToneState): TToneInts;
function ToneFreqsOf(const S: TToneState): TToneInts;
procedure SetToneGains(var S: TToneState; const A: TToneInts);
procedure SetToneFreqs(var S: TToneState; const A: TToneInts);
// the widths of the middle bands (the two shelves have none: always 0)
function ToneWidthsOf(const S: TToneState): TToneInts;
procedure SetToneWidths(var S: TToneState; const A: TToneInts);
// at least one band is not at 0 dB
function ToneAnyGain(const S: TToneState): Boolean;

type

  // 2. The Custom Exception Carrier
  EAudioEngineError = class(Exception)
  public
    ErrorType: TAudioErrorType;
    FailedRate: Integer;
    constructor CreateTyped(Err: TAudioErrorType; const Msg: string; Rate: Integer = 0);
  end;

  TResamplerConfig = record
    Quality         : Integer;
    UpsamplePhase   : Integer;
    DownsamplePhase : Integer;
    Bandwidth       : Double;
    AntiAlias       : Double;
  end;

  function DefaultResamplerConfig: TResamplerConfig; // Helper function

implementation

constructor EAudioEngineError.CreateTyped(Err: TAudioErrorType; const Msg: string; Rate: Integer);
begin
  inherited Create(Msg);
  ErrorType  := Err;
  FailedRate := Rate;
end;

function ToneWidthsOf(const S: TToneState): TToneInts;
begin
  Result[0] := TONE_WIDTH_NORMAL;
  Result[1] := S.LowMidWidth;
  Result[2] := S.MidWidth;
  Result[3] := S.HighMidWidth;
  Result[4] := TONE_WIDTH_NORMAL;
end;

procedure SetToneWidths(var S: TToneState; const A: TToneInts);
begin
  S.LowMidWidth  := A[1];
  S.MidWidth     := A[2];
  S.HighMidWidth := A[3];
end;

function ToneGainsOf(const S: TToneState): TToneInts;
begin
  Result[0] := S.BassDB;
  Result[1] := S.LowMidDB;
  Result[2] := S.MidDB;
  Result[3] := S.HighMidDB;
  Result[4] := S.TrebleDB;
end;

function ToneFreqsOf(const S: TToneState): TToneInts;
begin
  Result[0] := S.BassHz;
  Result[1] := S.LowMidHz;
  Result[2] := S.MidHz;
  Result[3] := S.HighMidHz;
  Result[4] := S.TrebleHz;
end;

procedure SetToneGains(var S: TToneState; const A: TToneInts);
begin
  S.BassDB    := A[0];
  S.LowMidDB  := A[1];
  S.MidDB     := A[2];
  S.HighMidDB := A[3];
  S.TrebleDB  := A[4];
end;

procedure SetToneFreqs(var S: TToneState; const A: TToneInts);
begin
  S.BassHz    := A[0];
  S.LowMidHz  := A[1];
  S.MidHz     := A[2];
  S.HighMidHz := A[3];
  S.TrebleHz  := A[4];
end;

function ToneAnyGain(const S: TToneState): Boolean;
begin
  Result := (S.BassDB <> 0) or (S.LowMidDB <> 0) or (S.MidDB <> 0) or (S.HighMidDB <> 0) or
    (S.TrebleDB <> 0);
end;

function DefaultResamplerConfig: TResamplerConfig;
begin
  Result.Quality         := VAL_DEF_RESAMPLE_QUAL;
  Result.UpsamplePhase   := VAL_DEF_UPSAMPLE_PHASE;
  Result.DownsamplePhase := VAL_DEF_DOWNSAMPLE_PHASE;
  Result.Bandwidth       := VAL_DEF_BANDWIDTH_FLOAT;
  Result.AntiAlias       := VAL_DEF_ANTI_ALIAS_FLOAT;
end;

end.
