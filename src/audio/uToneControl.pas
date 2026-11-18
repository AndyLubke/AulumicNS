unit uToneControl;

{$mode objfpc}{$H+}

// =============================================================================
// AulumicNS - uToneControl
// Copyright (C) 2026 André Lubke
// Licensed under the GNU General Public License, version 3 (see LICENSE).
//
// The tone control: a hybrid 'Baxandall / semi parametric EQ' of five bands,
// each with an adjustable frequency - bass (low shelf), low mid, mid, high mid
// (peaking), treble (high shelf), in series in this order, all with
// Q = 1 / sqrt 2. (Three bands - bass, mid, treble - until 2026-11-14.) A band
// at 0 dB is skipped, so the three bands of before (bass, one of the mids,
// treble) give the samples they always gave. ToneResponseDB gives the curve
// the Tone Control window draws, from the same coefficients.
// Strictly accepts Integers for thread-safe UI transport, converting to
// 64-bit Doubles internally for DSP math.
//
// ---> AulumicNS: the glide. A setting changed while music plays does not
// replace the coefficients in one step (a faint tick on loud music): every
// band moves from where it is to the new setting in TONE_GLIDE_MS, its gain
// in dB and its frequency in octaves along an eased line (a half cosine), and
// the coefficients are set again TONE_GLIDE_STEPS_PER_S times a second on the
// way. "Off" (direct mode) and 0 dB are a glide to 0 dB, after which the band
// is bypassed as before; "on" is a glide from 0 dB. A change made before any
// sample went through, or after a reset (seek, another sample rate), arrives
// at once, as it always did. With unchanged settings nothing here runs: the
// samples are what they were, bit for bit (TTestToneControl).
// The caller counts the frames: see Gliding / GlideChunk / Advance.
// =============================================================================

interface

uses
  Classes, SysUtils, Math, ALAudioTypes;

const
  // Microscopic anti-denormal offset prevents CPU subnormal stalls during silence
  // ---> AulumicNS: in the interface (was in the implementation). The play
  // thread inlines ProcessSampleL / R, and the compiler can only inline
  // ProcessBiquad into another unit when everything it uses is visible
  // there: with the constant hidden, every filter of every sample was a call.
  ANTI_DENORMAL_OFFSET = 1.0e-20;

  // ---> AulumicNS: a new setting arrives in this time, the coefficients are
  // set again this often on the way
  TONE_GLIDE_MS          = 40;
  TONE_GLIDE_STEPS_PER_S = 4000;

type
  TFilterType = (ftLowShelf, ftPeaking, ftHighShelf);

  // Stores the normalized coefficients and delay states for one channel
  TBiquad = record
    b0, b1, b2, a1, a2: Double;
    s1, s2: Double;
  end;

  TToneBandValues = array[0..TONE_BANDS - 1] of Double;

  // ---> AulumicNS: everything that changes while samples run through the
  // tone control - the filters with their memory and a glide in work
  // (SaveState / RestoreState)
  TToneSnapshot = record
    L, R: array[0..TONE_BANDS - 1] of TBiquad;
    Active: array[0..TONE_BANDS - 1] of Boolean;
    CurDB, CurHz, FromDB, FromHz: TToneBandValues;
    GlideLen, GlidePos, StepLen, StepLeft: Integer;
  end;

  // ---> AulumicNS: settings as the curve in the Tone Control window needs
  // them (the bands in their order; gains in tenths of a dB, as everywhere)
  TToneCurve = record
    Rate: Integer;
    Hz, Tenths: TToneInts;
  end;

  { TToneControl }
  TToneControl = class
  private
    FSampleRate: Integer;
    FDirectMode: Boolean;

    // Per-band active flags bypass 0 dB filters in real time
    FActive: array[0..TONE_BANDS - 1] of Boolean;

    // Frequencies and Gains stored as Integers (Matches Settings Payload)
    FHzInt, FDBInt: TToneInts;

    // Independent stereo filters for series processing (the bands in order)
    FL, FR: array[0..TONE_BANDS - 1] of TBiquad;

    // ---> AulumicNS: the glide. FCur* is what the filters are set to now
    // (0 dB = the band is off), on its way from FFrom* to the settings;
    // FGlidePos of FGlideLen frames are done, the coefficients are set again
    // every FStepLen frames (FStepLeft until the next time). FHot: samples
    // went through since the last reset, so a new setting must not arrive
    // as a step.
    FCurDB, FCurHz, FFromDB, FFromHz: TToneBandValues;
    FGlideLen, FGlidePos, FStepLen, FStepLeft: Integer;
    FHot: Boolean;

    function TargetDB(ABand: Integer): Double;
    function TargetHz(ABand: Integer): Double;
    procedure SetBand(ABand: Integer; AHz, ADB: Double; AActive: Boolean);
    procedure Snap;
    procedure Retarget;

    procedure ResetState(var F: TBiquad);
    procedure CalcCoeffs(var ALeft, ARight: TBiquad; AFilterType: TFilterType; Freq, GainDB, Q: Double;
      AUnityAtZero: Boolean = True);

    function ProcessBiquad(var F: TBiquad; Input: Double): Double; inline;
  public
    constructor Create;

    procedure ResetAllStates;
    procedure SetSampleRate(ARate: Integer);
    // (bass, mid and treble alone: the two other bands keep what they have)
    procedure SetFrequencies(ABassHz, AMidHz, ATrebleHz: Integer);
    procedure SetGains(ABassDB, AMidDB, ATrebleDB: Integer);
    // ---> AulumicNS: all five bands
    procedure SetBandFrequencies(const AHz: TToneInts);
    procedure SetBandGains(const ATenths: TToneInts);

    procedure SetDirectMode(AEnabled: Boolean);

    // Returns True only when not in DirectMode AND at least one band is non-zero
    // ---> AulumicNS: and while a glide to "off" or to 0 dB is still running
    function IsActive: Boolean; inline;

    // ---> AulumicNS: the glide. While Gliding, hand over at most GlideChunk
    // frames at a time and call Advance with their number afterwards (the
    // coefficients change there; IsActive may change too). MarkPlayed after
    // a block of samples: from then on a new setting glides. FinishGlide
    // ends a glide at once, for a caller that cannot count frames.
    function Gliding: Boolean; inline;
    function GlideChunk: Integer; inline;
    procedure Advance(AFrames: Integer);
    procedure FinishGlide;
    procedure MarkPlayed; inline;

    property DirectMode: Boolean read FDirectMode;

    // Inline processing per channel for maximum performance in the audio loop
    function ProcessSampleL(Input: Double): Double; inline;
    function ProcessSampleR(Input: Double): Double; inline;

    // ---> AulumicNS: the filters' memory and the glide, to run samples
    // through them and then put everything back as if nothing had been
    // processed (the automatic headroom looks at a block behind the tone
    // control before it is played: TPlayThread.RunGain). The settings are
    // not part of it.
    procedure SaveState(out AState: TToneSnapshot);
    procedure RestoreState(const AState: TToneSnapshot);
  end;

// ---> AulumicNS: what the three filters do to a tone of AFreq Hz, in dB, with
// the coefficients the tone control itself uses at that sample rate
function ToneResponseDB(const ACurve: TToneCurve; AFreq: Double): Double;

implementation

uses uAppConsts;

const
  DEFAULT_FILTER_Q     = 0.7071067811865475; // 1 / Sqrt(2) Butterworth Q

  // ---> AUDIT FIX T1: Safe bounds for tone control frequencies (Hz) and gains (0.1 dB units)
  TONE_MIN_FREQ_HZ     = 10;
  TONE_MAX_FREQ_HZ     = 40000;
  TONE_MIN_GAIN_TENTHS = -200; // -20.0 dB
  TONE_MAX_GAIN_TENTHS = 200;  // +20.0 dB

  BAND_FILTER: array[0..TONE_BANDS - 1] of TFilterType =
    (ftLowShelf, ftPeaking, ftPeaking, ftPeaking, ftHighShelf);
  BAND_DEF_HZ: array[0..TONE_BANDS - 1] of Integer =
    (VAL_DEF_BASSHZ, VAL_DEF_LOWMIDHZ, VAL_DEF_MIDHZ, VAL_DEF_HIGHMIDHZ, VAL_DEF_TREBLEHZ);

{ TToneControl }

constructor TToneControl.Create;
var
  B: Integer;
begin
  inherited Create;
  FSampleRate := RATE_FAMILY_44K;
  FDirectMode := True;

  // Defaults stored as integers
  for B := 0 to TONE_BANDS - 1 do
  begin
    FHzInt[B]  := BAND_DEF_HZ[B];
    FDBInt[B]  := 0;
    FActive[B] := False;
  end;
  FHot := False;

  ResetAllStates;
end;

procedure TToneControl.ResetState(var F: TBiquad);
begin
  F.s1 := 0.0;
  F.s2 := 0.0;
end;

// ---> AulumicNS: the filters start anew (seek, a new stream): nothing to
// glide from, so a glide in work ends where it was going
procedure TToneControl.ResetAllStates;
var
  B: Integer;
begin
  for B := 0 to TONE_BANDS - 1 do
  begin
    ResetState(FL[B]);
    ResetState(FR[B]);
  end;
  FHot := False;
  Snap;
end;

// Clear filter delay lines when hardware sample rate changes
procedure TToneControl.SetSampleRate(ARate: Integer);
begin
  if (ARate > 0) and (FSampleRate <> ARate) then
  begin
    FSampleRate := ARate;
    ResetAllStates;
  end;
end;

procedure TToneControl.SetFrequencies(ABassHz, AMidHz, ATrebleHz: Integer);
var
  A: TToneInts;
begin
  A    := FHzInt;
  A[0] := ABassHz;
  A[2] := AMidHz;
  A[4] := ATrebleHz;
  SetBandFrequencies(A);
end;

procedure TToneControl.SetGains(ABassDB, AMidDB, ATrebleDB: Integer);
var
  A: TToneInts;
begin
  A    := FDBInt;
  A[0] := ABassDB;
  A[2] := AMidDB;
  A[4] := ATrebleDB;
  SetBandGains(A);
end;

procedure TToneControl.SetBandFrequencies(const AHz: TToneInts);
var
  B, V: Integer;
  Changed: Boolean;
begin
  Changed := False;
  for B := 0 to TONE_BANDS - 1 do
  begin
    // ---> AUDIT FIX T1: Clamp frequencies to sane bounds before updating coefficients
    V := EnsureRange(AHz[B], TONE_MIN_FREQ_HZ, TONE_MAX_FREQ_HZ);
    if FHzInt[B] <> V then
    begin
      FHzInt[B] := V;
      Changed   := True;
    end;
  end;
  if Changed then
    Retarget;
end;

procedure TToneControl.SetBandGains(const ATenths: TToneInts);
var
  B, V: Integer;
  Changed: Boolean;
begin
  Changed := False;
  for B := 0 to TONE_BANDS - 1 do
  begin
    // ---> AUDIT FIX T1: Clamp gains to [-20.0 .. +20.0 dB] so Power(10, GainDB / 40)
    // can never overflow on a corrupted configuration value!
    V := EnsureRange(ATenths[B], TONE_MIN_GAIN_TENTHS, TONE_MAX_GAIN_TENTHS);
    if FDBInt[B] <> V then
    begin
      FDBInt[B] := V;
      Changed   := True;
    end;
  end;
  if Changed then
    Retarget;
end;

procedure TToneControl.SetDirectMode(AEnabled: Boolean);
begin
  if FDirectMode <> AEnabled then
  begin
    FDirectMode := AEnabled;
    Retarget;
  end;
end;

// True bit-perfect bypass check when EQ is enabled but all bands are 0.0 dB
// ---> AulumicNS: the band flags alone - in direct mode every band is off
// (after its glide to 0 dB)
function TToneControl.IsActive: Boolean; inline;
begin
  Result := FActive[0] or FActive[1] or FActive[2] or FActive[3] or FActive[4];
end;

{ ---- the glide ---- }

// Where band ABand is going: its setting, or 0 dB in direct mode. The same
// expression as ever (tenths x 0.1), so the coefficients at the end of a
// glide are those of a tone control that was set this way from the start.
function TToneControl.TargetDB(ABand: Integer): Double;
begin
  if FDirectMode then
    Exit(0.0);
  Result := FDBInt[ABand] * 0.1;
end;

function TToneControl.TargetHz(ABand: Integer): Double;
begin
  Result := FHzInt[ABand];
end;

// Band ABand at AHz / ADB; a band that is switched off loses its memory
procedure TToneControl.SetBand(ABand: Integer; AHz, ADB: Double; AActive: Boolean);
begin
  FCurHz[ABand]  := AHz;
  FCurDB[ABand]  := ADB;
  FActive[ABand] := AActive;
  if not AActive then
  begin
    ResetState(FL[ABand]);
    ResetState(FR[ABand]);
  end;
  CalcCoeffs(FL[ABand], FR[ABand], BAND_FILTER[ABand], AHz, ADB, DEFAULT_FILTER_Q, not AActive);
end;

// The settings at once: no glide (in work or new)
procedure TToneControl.Snap;
var
  B: Integer;
  D: Double;
begin
  FGlideLen := 0;
  FGlidePos := 0;
  FStepLen  := 0;
  FStepLeft := 0;
  for B := 0 to TONE_BANDS - 1 do
  begin
    D := TargetDB(B);
    SetBand(B, TargetHz(B), D, D <> 0.0);
    FFromDB[B] := FCurDB[B];
    FFromHz[B] := FCurHz[B];
  end;
end;

// A setting changed: glide to it from where the bands are now, or take it
// at once while nothing plays
procedure TToneControl.Retarget;
var
  B: Integer;
  Moves: Boolean;
begin
  if (not FHot) or (FSampleRate <= 0) then
  begin
    Snap;
    Exit;
  end;

  Moves := False;
  for B := 0 to TONE_BANDS - 1 do
    if (FCurDB[B] = 0.0) and (TargetDB(B) = 0.0) then
      // off and staying off: only its frequency is noted
      SetBand(B, TargetHz(B), 0.0, False)
    else
    begin
      if (FCurDB[B] <> TargetDB(B)) or (FCurHz[B] <> TargetHz(B)) then
        Moves := True;
      // a band that comes on starts from 0 dB (unity) with an empty memory
      if FCurDB[B] = 0.0 then
        SetBand(B, TargetHz(B), 0.0, True);
    end;

  for B := 0 to TONE_BANDS - 1 do
  begin
    FFromDB[B] := FCurDB[B];
    FFromHz[B] := FCurHz[B];
  end;

  if not Moves then
  begin
    // every band is where it has to be
    Snap;
    Exit;
  end;

  FGlideLen := (Int64(FSampleRate) * TONE_GLIDE_MS) div 1000;
  if FGlideLen < 1 then
    FGlideLen := 1;
  FStepLen := FSampleRate div TONE_GLIDE_STEPS_PER_S;
  if FStepLen < 1 then
    FStepLen := 1;
  FGlidePos := 0;
  FStepLeft := FStepLen;
end;

function TToneControl.Gliding: Boolean; inline;
begin
  Result := FGlidePos < FGlideLen;
end;

function TToneControl.GlideChunk: Integer; inline;
begin
  Result := FStepLeft;
  if Result < 1 then
    Result := 1;
end;

procedure TToneControl.MarkPlayed; inline;
begin
  FHot := True;
end;

procedure TToneControl.FinishGlide;
begin
  if Gliding then
    Snap;
end;

// AFrames frames went through (at most GlideChunk): the next coefficients
// when their time has come, the settings themselves at the end
procedure TToneControl.Advance(AFrames: Integer);
var
  B: Integer;
  T, Hz: Double;
begin
  if (AFrames <= 0) or (not Gliding) then
    Exit;
  Inc(FGlidePos, AFrames);
  Dec(FStepLeft, AFrames);
  if FGlidePos >= FGlideLen then
  begin
    Snap;
    Exit;
  end;
  if FStepLeft > 0 then
    Exit;
  FStepLeft := FStepLen;
  // (eased: the first and the last steps are the smallest, so a band joins
  // and leaves the bypass without a step)
  T := 0.5 - 0.5 * Cos(Pi * FGlidePos / FGlideLen);
  for B := 0 to TONE_BANDS - 1 do
  begin
    if (FFromDB[B] = TargetDB(B)) and (FFromHz[B] = TargetHz(B)) then
      Continue;                      // this band stays as it is
    if (FFromDB[B] = 0.0) and (TargetDB(B) = 0.0) then
      Continue;                      // off
    if FFromHz[B] = TargetHz(B) then
      Hz := FFromHz[B]
    else
      Hz := FFromHz[B] * Power(TargetHz(B) / FFromHz[B], T);
    SetBand(B, Hz, FFromDB[B] + (TargetDB(B) - FFromDB[B]) * T, True);
  end;
end;

// Pre-calculates Cos(w0), Sin(w0), Sqrt(A), InvA0, and clamps Nyquist
// ---> AulumicNS: AUnityAtZero off for a band that is working (a glide through
// or from 0 dB): the plain formulas, which give b = a there. The unity set
// below ignores the filter's memory - with samples in it, that is a step.
procedure TToneControl.CalcCoeffs(var ALeft, ARight: TBiquad; AFilterType: TFilterType; Freq, GainDB, Q: Double;
  AUnityAtZero: Boolean);
var
  A, w0, sinW0, cosW0, alpha, twoSqrtAAlpha: Double;
  Ap1, Am1, Am1Cos, Ap1Cos: Double;
  b0, b1, b2, a0, a1, a2, invA0: Double;
  ClampedFreq, ClampedGainDB: Double;
begin
  if FSampleRate <= 0 then
    Exit;

  // ---> AUDIT FIX T1: Secondary defence-in-depth clamp inside CalcCoeffs
  if IsNan(GainDB) or IsInfinite(GainDB) then
    ClampedGainDB := 0.0
  else
    ClampedGainDB := EnsureRange(GainDB, -20.0, 20.0);

  // Fast unity-gain bypass if band gain is 0 dB
  if AUnityAtZero and (Abs(ClampedGainDB) < 0.001) then
  begin
    ALeft.b0 := 1.0;
    ALeft.b1 := 0.0;
    ALeft.b2 := 0.0;
    ALeft.a1 := 0.0;
    ALeft.a2 := 0.0;

    ARight.b0 := 1.0;
    ARight.b1 := 0.0;
    ARight.b2 := 0.0;
    ARight.a1 := 0.0;
    ARight.a2 := 0.0;
    Exit;
  end;

  // Clamp frequency safely below Nyquist (49% of SampleRate) to guarantee stability
  ClampedFreq := Freq;
  if ClampedFreq < 10.0 then
    ClampedFreq := 10.0
  else if ClampedFreq > (FSampleRate * 0.49) then
    ClampedFreq := FSampleRate * 0.49;

  A     := Power(10.0, ClampedGainDB / 40.0);
  w0    := (2.0 * Pi * ClampedFreq) / FSampleRate;
  SinCos(w0, sinW0, cosW0);
  alpha := sinW0 / (2.0 * Q);

  // ---> AulumicNS: unity until the case sets them (the -O3 data flow
  // analysis cannot see that the case covers every filter type)
  b0 := 1.0; b1 := 0.0; b2 := 0.0;
  a0 := 1.0; a1 := 0.0; a2 := 0.0;
  case AFilterType of
    ftLowShelf:
      begin
        twoSqrtAAlpha := 2.0 * Sqrt(A) * alpha;
        Ap1           := A + 1.0;
        Am1           := A - 1.0;
        Am1Cos        := Am1 * cosW0;
        Ap1Cos        := Ap1 * cosW0;

        b0 := A * (Ap1 - Am1Cos + twoSqrtAAlpha);
        b1 := 2.0 * A * (Am1 - Ap1Cos);
        b2 := A * (Ap1 - Am1Cos - twoSqrtAAlpha);
        a0 := Ap1 + Am1Cos + twoSqrtAAlpha;
        a1 := -2.0 * (Am1 + Ap1Cos);
        a2 := Ap1 + Am1Cos - twoSqrtAAlpha;
      end;
    ftPeaking:
      begin
        b0 := 1.0 + alpha * A;
        b1 := -2.0 * cosW0;
        b2 := 1.0 - alpha * A;
        a0 := 1.0 + alpha / A;
        a1 := b1;
        a2 := 1.0 - alpha / A;
      end;
    ftHighShelf:
      begin
        twoSqrtAAlpha := 2.0 * Sqrt(A) * alpha;
        Ap1           := A + 1.0;
        Am1           := A - 1.0;
        Am1Cos        := Am1 * cosW0;
        Ap1Cos        := Ap1 * cosW0;

        b0 := A * (Ap1 + Am1Cos + twoSqrtAAlpha);
        b1 := -2.0 * A * (Am1 + Ap1Cos);
        b2 := A * (Ap1 + Am1Cos - twoSqrtAAlpha);
        a0 := Ap1 - Am1Cos + twoSqrtAAlpha;
        a1 := 2.0 * (Am1 - Ap1Cos);
        a2 := Ap1 - Am1Cos - twoSqrtAAlpha;
      end;
  end;

  // Normalize coefficients via single reciprocal multiplication
  invA0 := 1.0 / a0;
  ALeft.b0 := b0 * invA0;
  ALeft.b1 := b1 * invA0;
  ALeft.b2 := b2 * invA0;
  ALeft.a1 := a1 * invA0;
  ALeft.a2 := a2 * invA0;

  ARight.b0 := ALeft.b0;
  ARight.b1 := ALeft.b1;
  ARight.b2 := ALeft.b2;
  ARight.a1 := ALeft.a1;
  ARight.a2 := ALeft.a2;
end;

// Direct Form II Transposed with zero-overhead anti-denormal guard
function TToneControl.ProcessBiquad(var F: TBiquad; Input: Double): Double; inline;
begin
  Result := (F.b0 * Input) + F.s1;
  F.s1   := (F.b1 * Input) - (F.a1 * Result) + F.s2;
  F.s2   := (F.b2 * Input) - (F.a2 * Result) + ANTI_DENORMAL_OFFSET;
end;

// Only processes bands that have non-zero gain!
function TToneControl.ProcessSampleL(Input: Double): Double; inline;
begin
  Result := Input;
  if FActive[0] then
    Result := ProcessBiquad(FL[0], Result);
  if FActive[1] then
    Result := ProcessBiquad(FL[1], Result);
  if FActive[2] then
    Result := ProcessBiquad(FL[2], Result);
  if FActive[3] then
    Result := ProcessBiquad(FL[3], Result);
  if FActive[4] then
    Result := ProcessBiquad(FL[4], Result);
end;

function TToneControl.ProcessSampleR(Input: Double): Double; inline;
begin
  Result := Input;
  if FActive[0] then
    Result := ProcessBiquad(FR[0], Result);
  if FActive[1] then
    Result := ProcessBiquad(FR[1], Result);
  if FActive[2] then
    Result := ProcessBiquad(FR[2], Result);
  if FActive[3] then
    Result := ProcessBiquad(FR[3], Result);
  if FActive[4] then
    Result := ProcessBiquad(FR[4], Result);
end;

procedure TToneControl.SaveState(out AState: TToneSnapshot);
begin
  AState.L        := FL;
  AState.R        := FR;
  AState.Active   := FActive;
  AState.CurDB    := FCurDB;
  AState.CurHz    := FCurHz;
  AState.FromDB   := FFromDB;
  AState.FromHz   := FFromHz;
  AState.GlideLen := FGlideLen;
  AState.GlidePos := FGlidePos;
  AState.StepLen  := FStepLen;
  AState.StepLeft := FStepLeft;
end;

procedure TToneControl.RestoreState(const AState: TToneSnapshot);
begin
  FL        := AState.L;
  FR        := AState.R;
  FActive   := AState.Active;
  FCurDB    := AState.CurDB;
  FCurHz    := AState.CurHz;
  FFromDB   := AState.FromDB;
  FFromHz   := AState.FromHz;
  FGlideLen := AState.GlideLen;
  FGlidePos := AState.GlidePos;
  FStepLen  := AState.StepLen;
  FStepLeft := AState.StepLeft;
end;

{ ---- the curve ---- }

// |H| of one biquad at the angle W (radians per sample), in dB
function BiquadDB(const F: TBiquad; W: Double): Double;
var
  C1, S1, C2, S2, NumRe, NumIm, DenRe, DenIm, Num, Den: Double;
begin
  SinCos(W, S1, C1);
  SinCos(2.0 * W, S2, C2);
  NumRe := F.b0 + F.b1 * C1 + F.b2 * C2;
  NumIm := -(F.b1 * S1 + F.b2 * S2);
  DenRe := 1.0 + F.a1 * C1 + F.a2 * C2;
  DenIm := -(F.a1 * S1 + F.a2 * S2);
  Num := NumRe * NumRe + NumIm * NumIm;
  Den := DenRe * DenRe + DenIm * DenIm;
  if (Num <= 0.0) or (Den <= 0.0) then
    Exit(0.0);
  Result := 10.0 * Log10(Num / Den);
end;

function ToneResponseDB(const ACurve: TToneCurve; AFreq: Double): Double;
var
  Tone: TToneControl;
  W: Double;
  B: Integer;
begin
  Result := 0.0;
  if (ACurve.Rate <= 0) or (AFreq <= 0.0) or (AFreq >= ACurve.Rate * 0.5) then
    Exit;
  Tone := TToneControl.Create;
  try
    Tone.SetSampleRate(ACurve.Rate);
    Tone.SetBandFrequencies(ACurve.Hz);
    Tone.SetBandGains(ACurve.Tenths);
    Tone.SetDirectMode(False);
    W := 2.0 * Pi * AFreq / ACurve.Rate;
    for B := 0 to TONE_BANDS - 1 do
      if Tone.FActive[B] then
        Result := Result + BiquadDB(Tone.FL[B], W);
  finally
    Tone.Free;
  end;
end;

end.
