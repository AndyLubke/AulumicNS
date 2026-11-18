unit ALReaders;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALReaders
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Used by the AudioEngine to read FLAC, WAV, DSF and DFF files: the audio
  sources of the play thread, among them DSD as DoP (TDsfSource) and DSD
  converted to PCM (TDsdToPcmSource).
  ---> CHANGED (ObjFPC switch, step 2): ObjFPC like the rest of Aulumic (file
  names are UTF-8).
==============================================================================}

interface

uses
  Classes, SysUtils, Math, ALReaderWAV, ALReaderFLAC, ALReaderDSF, 
  AuResample,      // ---> AulumicNS: the built-in resampler (was libsoxr)
  ALAudioTypes;

type
  TRateMap = record
    InRate: integer;
    OutRate: integer;
  end;
  TRateMapArray = array of TRateMap;

  { TAudioSource }

  TAudioSource = class
  protected
    FClipped: boolean;
    FTargetBits: word; // Stores the WASAPI negotiated depth
  public
    function GetSampleRate: cardinal; virtual; abstract;
    function GetChannels: word; virtual; abstract;
    function GetBitsPerSample: word; virtual; abstract;
    function IsDoP: boolean; virtual;
    function GetDoPMarker: byte; virtual;
    procedure SetDoPMarker(Value: byte); virtual;
    function GetProgress: double; virtual; abstract;
    function GetDuration: double; virtual; abstract;
    function ReadData(Buffer: Pointer; BytesToRead: integer): integer; virtual; abstract;
    procedure Seek(Percent: double); virtual; abstract;
    function CheckClipping: boolean; virtual;
    procedure PrepareGapless(Previous: TAudioSource); virtual;

    procedure SetDSDGain(GainDB: double); virtual;
    procedure SetTargetBitDepth(Bits: word); virtual;
    // Tunnels through wrapper classes (BitDepth, MonoToStereo, Resampler)
    // so PrepareGapless always finds its matching layer
    function FindLayer(AClass: TClass): TAudioSource; virtual;
  end;

  TWavSource = class(TAudioSource)
  private
    FReader: TWavReader;
    FDuration: Double;
  public
    constructor Create(const f: string);
    destructor Destroy; override;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(B: Pointer; len: integer): integer; override;
    procedure Seek(Percent: double); override;
  end;

  TFlacSource = class(TAudioSource)
  private
    FReader: TFlacReader;
    FDuration: Double;
  public
    constructor Create(const f: string);
    destructor Destroy; override;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(B: Pointer; len: integer): integer; override;
    procedure Seek(Percent: double); override;
  end;

  { TDsfSource }

  TDsfSource = class(TAudioSource)
  private
    FReader: TDsfReader;
    FDuration: double;
  public
    constructor Create(const f: string);
    destructor Destroy; override;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function IsDoP: boolean; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(B: Pointer; len: integer): integer; override;
    procedure Seek(Percent: double); override;
    procedure PrepareGapless(Previous: TAudioSource); override;
    function GetDoPMarker: byte; override;
    procedure SetDoPMarker(Value: byte); override;
  end;

  { TDsdToPcmSource }

  TDsdToPcmSource = class(TAudioSource)
  private
    FSource: TAudioSource;
    FInputBuffer: array of byte;
    FGainLinear: double;
    FFadeInSamples: integer;
    FApplyLPF: Boolean;
    // ---> ADDED: From the output rate (constructor): the DC blocker's pole
    // and the fade-in length, so both act the same at every DSD rate
    FDcPole: double;
    FFadeLength: integer;
    FInvFadeLength: double;

    // 256 bytes (2048 bits/taps) for DSD64/128/256/512 support
    // ---> AulumicNS: as a ring written twice (at P and P + 256), so the
    // window - FHistL[FHistPos] .. FHistL[FHistPos + 255], oldest first - is
    // always in one piece (was: both windows moved by 4 bytes per sample)
    FHistL: array[0..511] of byte;
    FHistR: array[0..511] of byte;
    FHistPos: integer;
    FLookupFIR: array[0..255, 0..255] of double;

    FLastInL, FLastInR: double;
    FDcOutL, FDcOutR: double;

    // ---> AulumicNS: the output is the DSD rate / (32 x FDecim) (1, 2, 4, 8;
    // SetOutputRate)
    FDecim: integer;

    procedure InitLookupTable;
    procedure InitRateDependent;
  public
    constructor Create(const FileName: string; GaindB: Integer; ApplyLPF: Boolean);
    destructor Destroy; override;
    { ---> AulumicNS: decimates straight to ARate (the DSD rate / 64, / 128
      or / 256) when the DSD filter alone keeps it free of aliasing; then no
      resampler is needed after it (DSD512 -> 352.8 kHz: one filter instead
      of two, about three times less work). False: unchanged (DSD rate / 32).
      Before the first ReadData only. }
    function SetOutputRate(ARate: cardinal): Boolean;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function IsDoP: boolean; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(Buffer: Pointer; BytesToRead: integer): integer; override;
    procedure Seek(Percent: double); override;
    procedure PrepareGapless(Previous: TAudioSource); override;
    procedure SetDSDGain(GainDB: double); override;
  end;

  // Hook to run 64-bit float DSP, headroom, and single-pass
  // dithering before FOutputBufferFloat is quantized to integer PCM
  TResamplerFloatDSPProc = procedure(Buffer: PDouble; FrameCount, Channels, OutBits: Integer;
                                     out OutClipped: Boolean) of object;

  { TResamplerSource }

  TResamplerSource = class(TAudioSource)
  private
    FBaseSource: TAudioSource;
    // ---> AulumicNS: the built-in converter (AuResample) instead of a soxr state
    FSoxrState: TAuStreamResampler;
    FInputBufferFloat: array of double;
    FOutputBufferFloat: array of double;
    FInternalBufferInt: array of byte;
    FLeftoverBuffer: array of double;
    FLeftoverCount: integer;
    // ---> AulumicNS: the converter got its Flush at the end of the file
    // (its FFT stages compute their last block then)
    FEndFlushed: Boolean;
    FRatio: double;
    FTargetRate: cardinal;
    FConfig: TSoXConfig;
    FDitherSeed: cardinal;
    FOnFloatDSP: TResamplerFloatDSPProc;
    procedure CreateSoxrState;
  public
    constructor Create(Base: TAudioSource; TargetRate: Cardinal;
                       const Config: TSoXConfig);
    destructor Destroy; override;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(B: Pointer; len: integer): integer; override;
    procedure Seek(Percent: double); override;
    procedure PrepareGapless(Previous: TAudioSource); override;
    procedure SetDSDGain(GainDB: double); override;
    procedure SetTargetBitDepth(Bits: word); override;
    function CheckClipping: boolean; override;
    function FindLayer(AClass: TClass): TAudioSource; override;

    property OnFloatDSP: TResamplerFloatDSPProc read FOnFloatDSP write FOnFloatDSP;
  end;

  { TBitDepthConverterSource }

  TBitDepthConverterSource = class(TAudioSource)
  private
    FBaseSource: TAudioSource;
    FTempBuffer: array of byte;
    FDitherSeed: cardinal;
  public
    constructor Create(Base: TAudioSource; TargetBits: word);
    destructor Destroy; override;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(B: Pointer; len: integer): integer; override;
    procedure Seek(Percent: double); override;
    procedure PrepareGapless(Previous: TAudioSource); override;
    procedure SetDSDGain(GainDB: double); override;
    function IsDoP: boolean; override;
    function CheckClipping: boolean; override;
    function GetDoPMarker: byte; override;
    procedure SetDoPMarker(Value: byte); override;
    function FindLayer(AClass: TClass): TAudioSource; override;
    // ---> ADDED: Bit depth of the wrapped source (before the conversion)
    function GetSourceBitsPerSample: word;
  end;

  { TMonoToStereoSource }

  TMonoToStereoSource = class(TAudioSource)
  private
    FBaseSource: TAudioSource;
    FTempBuffer: array of byte;
  public
    constructor Create(Base: TAudioSource);
    destructor Destroy; override;
    function GetSampleRate: cardinal; override;
    function GetChannels: word; override;
    function GetBitsPerSample: word; override;
    function GetProgress: double; override;
    function GetDuration: double; override;
    function ReadData(B: Pointer; len: integer): integer; override;
    procedure Seek(Percent: double); override;
    procedure PrepareGapless(Previous: TAudioSource); override;
    procedure SetDSDGain(GainDB: double); override;
    function IsDoP: boolean; override;
    function CheckClipping: boolean; override;
    function GetDoPMarker: byte; override;
    procedure SetDoPMarker(Value: byte); override;
    procedure SetTargetBitDepth(Bits: word); override;
    function FindLayer(AClass: TClass): TAudioSource; override;
  end;

const
  // ---> ADDED: DSD-to-PCM (TDsdToPcmSource), the same at every DSD rate
  DSD_DC_BLOCK_HZ = 2.0;   // the DC blocker's -3 dB point
  DSD_FADE_IN_MS  = 100;   // anti-pop fade-in after start / seek

// ---> ADDED: For TDsdToPcmSource's PCM output rate AOutRate: the pole of its
// first-order DC blocker, so that its -3 dB point is DSD_DC_BLOCK_HZ at every
// DSD rate (the fixed pole 0.9995 doubled it with every DSD rate: 7 Hz at
// DSD64, 28 Hz at DSD256, audible as weaker deep bass), and the fade-in length
// in samples (DSD_FADE_IN_MS; was a fixed 8820 samples = 25 ms at DSD256)
function DsdDcBlockPole(AOutRate: Cardinal): Double;
function DsdFadeInSamples(AOutRate: Cardinal): Integer;

implementation

uses
  uAppStrings, uAppConsts;

const
  // ===========================================================================
  // PCM Integer & Floating-Point Rails / Scale Factors
  // ---> AUDIT FIX: Removed unused PCM16_MAX_INT and PCM16_MIN_INT constants
  // ===========================================================================
  PCM16_MAX_FLT       = 32767.0;
  PCM16_MIN_FLT       = -32768.0;
  PCM16_SCALE_FLT     = 32768.0;
  INV_PCM16_FLT       = 1.0 / PCM16_SCALE_FLT;

  PCM24_MAX_INT       = 8388607;
  PCM24_MIN_INT       = -8388608;
  PCM24_MAX_FLT       = 8388607.0;
  PCM24_MIN_FLT       = -8388608.0;
  PCM24_SCALE_FLT     = 8388608.0;
  INV_PCM24_FLT       = 1.0 / PCM24_SCALE_FLT;
  PCM24_SIGN_BIT      = $800000;
  PCM24_SIGN_EXT_MASK = Integer($FF000000);

  PCM32_MAX_INT       = 2147483647;
  PCM32_MIN_INT       = -2147483648;
  PCM32_MAX_FLT       = 2147483647.0;
  PCM32_MIN_FLT       = -2147483648.0;
  PCM32_SCALE_FLT     = 2147483648.0;
  INV_PCM32_FLT       = 1.0 / PCM32_SCALE_FLT;

  // ===========================================================================
  // TPDF Dither & Integer Rounding Constants
  // ===========================================================================
  TPDF_DITHER_SCALE   = 1.0 / 2147483648.0; // 2^-31 scale for 31-bit PRNG diff
  DEFAULT_PRNG_SEED   = $A341316C;
  ROUND_BIAS_8BIT     = 128;                // Half-LSB bias before shr 8
  ROUND_BIAS_16BIT    = 32768;              // Half-LSB bias before shr 16

  // ===========================================================================
  // DoP & DSD-to-PCM Decimation Constants
  // ===========================================================================
  DOP_MARKER_DEFAULT    = $05;
  DOP_DECIMATE_IN_BYTES = 12;               // 2 DoP stereo frames (32 DSD bits/ch)
  PCM32_STEREO_BYTES    = 8;                // 1 stereo 32-bit PCM frame (2 * 4 bytes)

  DSD_FIR_TAPS          = 2048;             // 2048-tap Blackman symmetric FIR
  DSD_FIR_BYTES         = 256;              // 2048 bits / 8 bits per byte


  DSD_IN_CHUNK_FRAMES   = 8192;             // 8,192 frames * 12 B = 96 KB L2 chunk
  // ---> CHANGED: The fade-in length and the DC blocker pole come from the
  // output rate (DsdFadeInSamples, DsdDcBlockPole; DSD_FADE_IN_MS / DSD_DC_BLOCK_HZ)
  DSD_LPF_CUTOFF_HZ     = 30000.0;          // 30 kHz ultrasonic low-pass cutoff
  DSD_DEFAULT_RAW_RATE  = 2822400.0;        // DSD64 raw bit rate (64 * 44.1 kHz)
  DSD_FALLBACK_PCM_RATE = 88200;

  // ===========================================================================
  // Resampler (libSoXR) & Converter Buffer Constants
  // ===========================================================================
  RESAMP_IN_BUF_SAMPLES  = 16384;
  RESAMP_OUT_BUF_SAMPLES = 65536;
  RESAMP_INT_BUF_BYTES   = RESAMP_IN_BUF_SAMPLES * 4;
  SOXR_LOOKAHEAD_FRAMES  = 512;

  SOXR_MIN_BANDWIDTH     = 70.0;
  SOXR_MAX_BANDWIDTH     = 99.0;
  SOXR_MIN_ANTIALIAS     = 100.0;
  SOXR_MAX_ANTIALIAS     = 120.0;

  CONV_TEMP_BUF_BYTES    = 65536;           // 64 KB L2-cache-friendly slice buffer

// =============================================================================
// TPDF DITHER: Lock-free Xorshift32 Triangular PDF generator (-1.0..+1.0 LSB)
// =============================================================================
function NextTPDFDither(var Seed: cardinal): double; inline;
var
  R1, R2: cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  R1   := Seed;

  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  R2   := Seed;

  Result := (Integer(R1 shr 1) - Integer(R2 shr 1)) * TPDF_DITHER_SCALE;
end;

{ TAudioSource }

function TAudioSource.IsDoP: boolean;
begin
  Result := False;
end;

function TAudioSource.CheckClipping: boolean;
begin
  Result   := FClipped;
  FClipped := False;
end;

procedure TAudioSource.PrepareGapless(Previous: TAudioSource);
begin
end;

procedure TAudioSource.SetDSDGain(GainDB: double);
begin
end;

procedure TAudioSource.SetTargetBitDepth(Bits: word);
begin
  FTargetBits := Bits;
end;

function TAudioSource.GetDoPMarker: byte;
begin
  Result := $05;
end;

procedure TAudioSource.SetDoPMarker(Value: byte);
begin
end;

function TAudioSource.FindLayer(AClass: TClass): TAudioSource;
begin
  if Self is AClass then
    Result := Self
  else
    Result := nil;
end;

{ TWavSource }

constructor TWavSource.Create(const f: string);
var
  Denom: Int64;
begin
  inherited Create;
  FReader := TWavReader.Create(f);
  FClipped := False;

  Denom := Int64(FReader.SampleRate) * Int64(FReader.Channels * (FReader.BitsPerSample div 8));
  if Denom > 0 then
    FDuration := FReader.DataSize / Denom
  else
    FDuration := 0.0;
end;

destructor TWavSource.Destroy;
begin
  FReader.Free;
  inherited;
end;

function TWavSource.GetSampleRate: cardinal;
begin
  Result := FReader.SampleRate;
end;

function TWavSource.GetChannels: word;
begin
  Result := FReader.Channels;
end;

function TWavSource.GetBitsPerSample: word;
begin
  Result := FReader.BitsPerSample;
end;

function TWavSource.GetProgress: double;
begin
  Result := FReader.GetProgress;
end;

function TWavSource.GetDuration: double;
begin
  Result := FDuration;
end;

function TWavSource.ReadData(B: Pointer; len: integer): integer;
begin
  Result := FReader.ReadData(B, len);
end;

procedure TWavSource.Seek(Percent: double);
begin
  // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
  FReader.Seek(EnsureRange(Percent, 0.0, 1.0));
end;

{ TFlacSource }

constructor TFlacSource.Create(const f: string);
var
  Denom: Int64;
begin
  inherited Create;
  FReader := TFlacReader.Create(f);
  FClipped := False;

  Denom := Int64(FReader.SampleRate) * Int64(FReader.Channels) * (FReader.BitsPerSample div 8);
  if Denom > 0 then
    FDuration := FReader.DataSize / Denom
  else
    FDuration := 0.0;
end;

destructor TFlacSource.Destroy;
begin
  FReader.Free;
  inherited;
end;

function TFlacSource.GetSampleRate: cardinal;
begin
  Result := FReader.SampleRate;
end;

function TFlacSource.GetChannels: word;
begin
  Result := FReader.Channels;
end;

function TFlacSource.GetBitsPerSample: word;
begin
  Result := FReader.BitsPerSample;
end;

function TFlacSource.GetProgress: double;
begin
  Result := FReader.GetProgress;
end;

function TFlacSource.GetDuration: double;
begin
  Result := FDuration;
end;

function TFlacSource.ReadData(B: Pointer; len: integer): integer;
begin
  Result := FReader.ReadData(B, len);
end;

procedure TFlacSource.Seek(Percent: double);
begin
  // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
  FReader.Seek(EnsureRange(Percent, 0.0, 1.0));
end;

{ TDsfSource }

constructor TDsfSource.Create(const f: string);
var
  BytesPerSec: int64;
begin
  inherited Create;
  FReader := TDsfReader.Create(f);
  FClipped := False;

  if (FReader.DataSize > 0) and (FReader.GetSampleRate > 0) then
  begin
    BytesPerSec := int64(FReader.GetSampleRate) * 4;
    FDuration   := FReader.DataSize / BytesPerSec;
  end
  else
    FDuration := 0.0;
end;

destructor TDsfSource.Destroy;
begin
  FReader.Free;
  inherited;
end;

function TDsfSource.GetSampleRate: cardinal;
begin
  Result := FReader.GetSampleRate;
end;

function TDsfSource.GetChannels: word;
begin
  Result := FReader.GetChannels;
end;

function TDsfSource.GetBitsPerSample: word;
begin
  Result := FReader.GetBitsPerSample;
end;

function TDsfSource.IsDoP: boolean;
begin
  Result := True;
end;

function TDsfSource.GetProgress: double;
begin
  Result := FReader.GetProgress;
end;

function TDsfSource.GetDuration: double;
begin
  Result := FDuration;
end;

function TDsfSource.ReadData(B: Pointer; len: integer): integer;
begin
  Result := FReader.ReadData(B, len);
end;

procedure TDsfSource.Seek(Percent: double);
begin
  // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
  FReader.Seek(EnsureRange(Percent, 0.0, 1.0));
end;

procedure TDsfSource.PrepareGapless(Previous: TAudioSource);
var
  PrevDsf: TDsfSource;
begin
  inherited PrepareGapless(Previous);

  if Assigned(Previous) then
  begin
    PrevDsf := TDsfSource(Previous.FindLayer(TDsfSource));
    if Assigned(PrevDsf) then
      Self.FReader.SetDoPMarker(PrevDsf.FReader.GetDoPMarker);
  end;
end;

function TDsfSource.GetDoPMarker: byte;
begin
  Result := FReader.GetDoPMarker;
end;

procedure TDsfSource.SetDoPMarker(Value: byte);
begin
  FReader.SetDoPMarker(Value);
end;

{ DSD-to-PCM rate rules }

function DsdDcBlockPole(AOutRate: Cardinal): Double;
begin
  if AOutRate = 0 then
    AOutRate := DSD_FALLBACK_PCM_RATE;
  // y[n] = x[n] - x[n-1] + p * y[n-1]: -3 dB at about fc for p = e^(-2 pi fc / fs)
  Result := Exp(-2.0 * Pi * DSD_DC_BLOCK_HZ / AOutRate);
end;

function DsdFadeInSamples(AOutRate: Cardinal): Integer;
begin
  if AOutRate = 0 then
    AOutRate := DSD_FALLBACK_PCM_RATE;
  Result := Round(AOutRate * (DSD_FADE_IN_MS / 1000.0));
  if Result < 1 then
    Result := 1;
end;

{ TDsdToPcmSource }

{ ---> AulumicNS: the 2048-tap FIR of both channels from the byte lookup
  table: ARows = FLookupFIR[0, 0] (256 rows of 256 doubles), AL / AR = the
  256-byte windows, oldest first. On its own, so the compiler keeps the
  pointers and sums in registers (in ReadData it reloaded Self and the row
  offset for every byte). Four partial sums per channel (byte J goes to sum
  J mod 4) break the chain of 256 dependent additions: about twice as fast.
  The result differs from one running sum only in the last bits of a double
  (rarely +-1 in the 32-bit output, about -186 dBFS). }
procedure DsdFirStereo(ARows: PDouble; AL, AR: PByte; out AOutL, AOutR: Double);
var
  J: Integer;
  L0, L1, L2, L3, R0, R1, R2, R3: Double;
begin
  L0 := 0.0; L1 := 0.0; L2 := 0.0; L3 := 0.0;
  R0 := 0.0; R1 := 0.0; R2 := 0.0; R3 := 0.0;
  for J := 0 to (DSD_FIR_BYTES div 4) - 1 do
  begin
    L0 := L0 + ARows[AL[0]];
    R0 := R0 + ARows[AR[0]];
    L1 := L1 + ARows[256 + AL[1]];
    R1 := R1 + ARows[256 + AR[1]];
    L2 := L2 + ARows[512 + AL[2]];
    R2 := R2 + ARows[512 + AR[2]];
    L3 := L3 + ARows[768 + AL[3]];
    R3 := R3 + ARows[768 + AR[3]];
    Inc(ARows, 1024);
    Inc(AL, 4);
    Inc(AR, 4);
  end;
  AOutL := (L0 + L1) + (L2 + L3);
  AOutR := (R0 + R1) + (R2 + R3);
end;

constructor TDsdToPcmSource.Create(const FileName: string; GaindB: Integer; ApplyLPF: Boolean);
begin
  inherited Create;
  FDecim  := 1;
  FSource := TDsfSource.Create(FileName);

  // ---> AUDIT FIX 2.2 & 2.3: Validate DSF DoP rate and stereo channel count
  // BEFORE building the FIR lookup table! If this raises, TDsdToPcmSource.Destroy
  // automatically frees FSource.
  // Accept both the 44.1 kHz family (DSD64 = 176,400 Hz DoP) and the
  // 48 kHz family (DSD64 @ 3.072 MHz = 192,000 Hz DoP)
  if (FSource.GetSampleRate < 88200) or
     (((FSource.GetSampleRate mod RATE_FAMILY_44K) <> 0) and ((FSource.GetSampleRate mod RATE_FAMILY_48K) <> 0)) then
    raise EAudioEngineError.CreateTyped(aeAudioFail, ERR_DECODE_DSF_RATE);

  if FSource.GetChannels <> 2 then
    raise EAudioEngineError.CreateTyped(aeMultiChannel, ERR_DECODE_DSF_STEREO);

  // Fixed 96 KB DoP input buffer (8,192 stereo frames * 12 bytes)
  SetLength(FInputBuffer, DSD_IN_CHUNK_FRAMES * DOP_DECIMATE_IN_BYTES);
  FGainLinear := Power(10.0, GaindB / 20.0);
  FApplyLPF   := ApplyLPF;

  FillChar(FHistL, SizeOf(FHistL), 0);
  FillChar(FHistR, SizeOf(FHistR), 0);
  FHistPos := 0;

  InitLookupTable;
  InitRateDependent;

  FLastInL       := 0.0;
  FLastInR       := 0.0;
  FDcOutL        := 0.0;
  FDcOutR        := 0.0;
  FClipped       := False;
end;

destructor TDsdToPcmSource.Destroy;
begin
  FSource.Free;
  inherited;
end;

procedure TDsdToPcmSource.SetDSDGain(GainDB: double);
begin
  FGainLinear := Power(10.0, GainDB / 20.0);
end;

{ ---> ADDED: The same DC blocker corner and fade-in time at every DSD rate
  (---> AulumicNS: also after SetOutputRate) }
procedure TDsdToPcmSource.InitRateDependent;
begin
  FDcPole        := DsdDcBlockPole(GetSampleRate);
  FFadeLength    := DsdFadeInSamples(GetSampleRate);
  FInvFadeLength := 1.0 / FFadeLength;
  FFadeInSamples := FFadeLength;
end;

function TDsdToPcmSource.SetOutputRate(ARate: cardinal): Boolean;
var
  Natural, F: cardinal;
  Fc, Tw: double;
begin
  Result := False;
  if (FSource = nil) or (ARate = 0) then
    Exit;
  Natural := FSource.GetSampleRate div 2;      // the DSD rate / 32
  if (ARate >= Natural) or ((Natural mod ARate) <> 0) then
    Exit;
  F := Natural div ARate;
  if (F > 8) or ((F and (F - 1)) <> 0) then
    Exit;
  { the images of the band fold back around ARate: the cut-off plus the
    filter's transition band (Blackman, 74 dB: 5.5 / N of the DSD rate) must
    end below ARate - cut-off. True with the 30 kHz low-pass for DSD512 ->
    352.8 / 176.4, DSD256 -> 176.4, DSD128 -> 88.2; never without it (its
    cut-off follows the output rate). }
  if FApplyLPF then
    Fc := DSD_LPF_CUTOFF_HZ
  else
    Fc := ARate * 0.45;
  Tw := 5.5 * (FSource.GetSampleRate * 16.0) / DSD_FIR_TAPS;
  if ARate < 2.0 * Fc + Tw then
    Exit;
  FDecim := Integer(F);
  InitLookupTable;
  InitRateDependent;
  Result := True;
end;

procedure TDsdToPcmSource.PrepareGapless(Previous: TAudioSource);
var
  Prev: TDsdToPcmSource;
begin
  if Assigned(Previous) then
  begin
    Prev := TDsdToPcmSource(Previous.FindLayer(TDsdToPcmSource));
    // ---> AulumicNS: the window holds DSD bytes: only from a stream of the
    // same DSD rate and decimation (another one starts with its fade-in)
    if Assigned(Prev) and (Prev.FDecim = Self.FDecim) and Assigned(Prev.FSource) and
       (Prev.FSource.GetSampleRate = Self.FSource.GetSampleRate) then
    begin
      Self.FLastInL := Prev.FLastInL;
      Self.FLastInR := Prev.FLastInR;
      Self.FDcOutL  := Prev.FDcOutL;
      Self.FDcOutR  := Prev.FDcOutR;
      Move(Prev.FHistL[0], Self.FHistL[0], SizeOf(FHistL));
      Move(Prev.FHistR[0], Self.FHistR[0], SizeOf(FHistR));
      Self.FHistPos := Prev.FHistPos;
      Self.FFadeInSamples := 0;
    end;
  end;
end;

procedure TDsdToPcmSource.InitLookupTable;
var
  i, byteVal, bitIdx, tap: integer;
  x, fc, sumH, sincVal, window, sumVal, RawDsdRate: double;
  h: array[0..DSD_FIR_TAPS - 1] of double;
begin
  if Assigned(FSource) and (FSource.GetSampleRate > 0) then
    RawDsdRate := FSource.GetSampleRate * 16.0
  else
    RawDsdRate := DSD_DEFAULT_RAW_RATE;

  if FApplyLPF then
    fc := DSD_LPF_CUTOFF_HZ / RawDsdRate
  else
    fc := (GetSampleRate * 0.45) / RawDsdRate;

  // ---> AUDIT FIX 2.2: Ensure fc is strictly positive so sumH can never be 0.0
  if fc <= 0.0 then
    fc := DSD_LPF_CUTOFF_HZ / DSD_DEFAULT_RAW_RATE;

  sumH := 0.0;

  for i := 0 to DSD_FIR_TAPS - 1 do
  begin
    x       := i - ((DSD_FIR_TAPS - 1) * 0.5);
    sincVal := Sin(2.0 * Pi * fc * x) / (Pi * x);
    window  := 0.42 - 0.5 * Cos(2.0 * Pi * i / (DSD_FIR_TAPS - 1)) +
               0.08 * Cos(4.0 * Pi * i / (DSD_FIR_TAPS - 1));
    h[i]    := sincVal * window;
    sumH    := sumH + h[i];
  end;

  if Abs(sumH) < 1e-18 then
    sumH := 1.0;

  for i := 0 to DSD_FIR_TAPS - 1 do
    h[i] := h[i] / sumH;

  for i := 0 to DSD_FIR_BYTES - 1 do
  begin
    for byteVal := 0 to 255 do
    begin
      sumVal := 0.0;
      for bitIdx := 0 to 7 do
      begin
        tap := (i * 8) + bitIdx;
        if (byteVal and (1 shl (7 - bitIdx))) <> 0 then
          sumVal := sumVal + h[tap]
        else
          sumVal := sumVal - h[tap];
      end;
      FLookupFIR[i, byteVal] := sumVal;
    end;
  end;
end;

function TDsdToPcmSource.GetSampleRate: cardinal;
begin
  if Assigned(FSource) then
    Result := FSource.GetSampleRate div cardinal(2 * Max(1, FDecim))
  else
    Result := DSD_FALLBACK_PCM_RATE;
end;

function TDsdToPcmSource.GetChannels: word;
begin
  if Assigned(FSource) then
    Result := FSource.GetChannels
  else
    Result := 2;
end;

function TDsdToPcmSource.GetBitsPerSample: word;
begin
  Result := 32;
end;

function TDsdToPcmSource.IsDoP: boolean;
begin
  Result := False;
end;

function TDsdToPcmSource.GetProgress: double;
begin
  Result := FSource.GetProgress;
end;

function TDsdToPcmSource.GetDuration: double;
begin
  Result := FSource.GetDuration;
end;

procedure TDsdToPcmSource.Seek(Percent: double);
begin
  // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
  FSource.Seek(EnsureRange(Percent, 0.0, 1.0));
  FillChar(FHistL, SizeOf(FHistL), 0);
  FillChar(FHistR, SizeOf(FHistR), 0);
  FHistPos       := 0;
  FFadeInSamples := FFadeLength;
  FLastInL       := 0.0;
  FLastInR       := 0.0;
  FDcOutL        := 0.0;
  FDcOutR        := 0.0;
end;

function TDsdToPcmSource.ReadData(Buffer: Pointer; BytesToRead: integer): integer;
var
  TotalSamplesNeeded, TotalSamplesDone, MaxChunkSamples,
  ChunkSamples, DoPBytesNeeded, BytesRead, SamplesRead, I: integer;
  InBytesPerOut, N, P: integer;
  PIn, PL, PR: pbyte;
  PO32: PInteger;
  ValL, ValR, DcCurrL, DcCurrR, ScaleFactor, FadeScale: double;
begin
  if BytesToRead <= 0 then
    Exit(0);

  TotalSamplesNeeded := BytesToRead div PCM32_STEREO_BYTES;
  if TotalSamplesNeeded <= 0 then
    Exit(0);

  // Process in fixed chunks that fit inside FInputBuffer (Zero SetLength)
  // ---> AulumicNS: 2 x FDecim DoP frames (12 x FDecim bytes) per output sample
  InBytesPerOut   := DOP_DECIMATE_IN_BYTES * FDecim;
  MaxChunkSamples := Length(FInputBuffer) div InBytesPerOut;
  if MaxChunkSamples <= 0 then
    Exit(0);

  TotalSamplesDone := 0;
  PO32             := PInteger(Buffer);
  ScaleFactor      := FGainLinear * PCM32_SCALE_FLT;

  while TotalSamplesDone < TotalSamplesNeeded do
  begin
    ChunkSamples := TotalSamplesNeeded - TotalSamplesDone;
    if ChunkSamples > MaxChunkSamples then
      ChunkSamples := MaxChunkSamples;

    DoPBytesNeeded := ChunkSamples * InBytesPerOut;
    BytesRead      := FSource.ReadData(@FInputBuffer[0], DoPBytesNeeded);
    if BytesRead <= 0 then
      Break;

    SamplesRead := BytesRead div InBytesPerOut;
    if SamplesRead <= 0 then
      Break;

    PIn := @FInputBuffer[0];

    for I := 0 to SamplesRead - 1 do
    begin
      // ---> AulumicNS: the new DSD bytes of this sample into the ring (per
      // DoP frame and channel the high byte is the earlier one); the window
      // is then the newest 256 bytes (2048 bits), oldest first
      for N := 1 to 2 * FDecim do
      begin
        P := FHistPos;
        FHistL[P] := PIn[1];  FHistL[P + DSD_FIR_BYTES] := PIn[1];
        FHistR[P] := PIn[4];  FHistR[P + DSD_FIR_BYTES] := PIn[4];
        P := (P + 1) and (DSD_FIR_BYTES - 1);
        FHistL[P] := PIn[0];  FHistL[P + DSD_FIR_BYTES] := PIn[0];
        FHistR[P] := PIn[3];  FHistR[P + DSD_FIR_BYTES] := PIn[3];
        FHistPos := (P + 1) and (DSD_FIR_BYTES - 1);
        Inc(PIn, DOP_DECIMATE_IN_BYTES div 2);
      end;
      PL := @FHistL[FHistPos];
      PR := @FHistR[FHistPos];
      DsdFirStereo(@FLookupFIR[0, 0], PL, PR, ValL, ValR);

      DcCurrL  := ValL - FLastInL + (FDcPole * FDcOutL);
      DcCurrR  := ValR - FLastInR + (FDcPole * FDcOutR);
      FLastInL := ValL;
      FLastInR := ValR;
      FDcOutL  := DcCurrL;
      FDcOutR  := DcCurrR;

      ValL := DcCurrL * ScaleFactor;
      ValR := DcCurrR * ScaleFactor;

      if FFadeInSamples > 0 then
      begin
        FadeScale := 1.0 - (FFadeInSamples * FInvFadeLength);
        ValL      := ValL * FadeScale;
        ValR      := ValR * FadeScale;
        Dec(FFadeInSamples);
      end;

      if ValL > PCM32_MAX_FLT then
      begin
        ValL     := PCM32_MAX_FLT;
        FClipped := True;
      end
      else if ValL < PCM32_MIN_FLT then
      begin
        ValL     := PCM32_MIN_FLT;
        FClipped := True;
      end;

      if ValR > PCM32_MAX_FLT then
      begin
        ValR     := PCM32_MAX_FLT;
        FClipped := True;
      end
      else if ValR < PCM32_MIN_FLT then
      begin
        ValR     := PCM32_MIN_FLT;
        FClipped := True;
      end;

      PO32^ := Round(ValL);
      Inc(PO32);
      PO32^ := Round(ValR);
      Inc(PO32);
    end;

    Inc(TotalSamplesDone, SamplesRead);

    if BytesRead < DoPBytesNeeded then
      Break;
  end;

  Result := TotalSamplesDone * PCM32_STEREO_BYTES;
end;

{ TResamplerSource }

constructor TResamplerSource.Create(Base: TAudioSource; TargetRate: Cardinal;
  const Config: TSoXConfig);
begin
  inherited Create;

  FBaseSource := Base;
  FTargetRate := TargetRate;
  FDitherSeed := DEFAULT_PRNG_SEED;

  FConfig.Quality         := Config.Quality;
  FConfig.UpsamplePhase   := Config.UpsamplePhase;
  FConfig.DownsamplePhase := Config.DownsamplePhase;

  if Config.Bandwidth < SOXR_MIN_BANDWIDTH then
    FConfig.Bandwidth := VAL_DEF_BANDWIDTH_FLOAT
  else if Config.Bandwidth > SOXR_MAX_BANDWIDTH then
    FConfig.Bandwidth := SOXR_MAX_BANDWIDTH
  else
    FConfig.Bandwidth := Config.Bandwidth;

  if Config.AntiAlias < SOXR_MIN_ANTIALIAS then
    FConfig.AntiAlias := VAL_DEF_ANTI_ALIAS_FLOAT
  else if Config.AntiAlias > SOXR_MAX_ANTIALIAS then
    FConfig.AntiAlias := SOXR_MAX_ANTIALIAS
  else
    FConfig.AntiAlias := Config.AntiAlias;

  if (FTargetRate > 0) and (FBaseSource.GetSampleRate > 0) then
    FRatio := FTargetRate / FBaseSource.GetSampleRate
  else
    FRatio := 2.0;

  CreateSoxrState;

  SetLength(FInternalBufferInt, RESAMP_INT_BUF_BYTES);
  SetLength(FInputBufferFloat,  RESAMP_IN_BUF_SAMPLES);
  SetLength(FOutputBufferFloat, RESAMP_OUT_BUF_SAMPLES);
  SetLength(FLeftoverBuffer,    RESAMP_IN_BUF_SAMPLES);

  FLeftoverCount := 0;
  FClipped       := False;
end;

procedure TResamplerSource.SetDSDGain(GainDB: double);
begin
  if Assigned(FBaseSource) then
    FBaseSource.SetDSDGain(GainDB);
end;

procedure TResamplerSource.SetTargetBitDepth(Bits: word);
begin
  FTargetBits := Bits;
end;

function TResamplerSource.CheckClipping: boolean;
var
  BaseClipped: boolean;
begin
  BaseClipped := False;
  if Assigned(FBaseSource) then
    BaseClipped := FBaseSource.CheckClipping;

  Result   := FClipped or BaseClipped;
  FClipped := False;
end;

function TResamplerSource.FindLayer(AClass: TClass): TAudioSource;
begin
  if Self is AClass then
    Result := Self
  else if Assigned(FBaseSource) then
    Result := FBaseSource.FindLayer(AClass)
  else
    Result := nil;
end;

procedure TResamplerSource.PrepareGapless(Previous: TAudioSource);
var
  PrevUp: TResamplerSource;
  MaxLeftoverFrames: integer;
begin
  if Assigned(Previous) then
  begin
    PrevUp := TResamplerSource(Previous.FindLayer(TResamplerSource));
    if Assigned(PrevUp) and
       Assigned(Self.FBaseSource) and Assigned(PrevUp.FBaseSource) and
       (Self.FBaseSource.GetSampleRate = PrevUp.FBaseSource.GetSampleRate) and
       (Self.FBaseSource.GetChannels = PrevUp.FBaseSource.GetChannels) then
    begin
      FreeAndNil(Self.FSoxrState);

      Self.FSoxrState   := PrevUp.FSoxrState;
      PrevUp.FSoxrState := nil;
      Self.FDitherSeed  := PrevUp.FDitherSeed;

      // Clamp against pre-allocated FLeftoverBuffer capacity (Zero SetLength)
      MaxLeftoverFrames   := Length(Self.FLeftoverBuffer) div Max(1, Integer(Self.GetChannels));
      Self.FLeftoverCount := Min(PrevUp.FLeftoverCount, MaxLeftoverFrames);
      if Self.FLeftoverCount > 0 then
        Move(PrevUp.FLeftoverBuffer[0], Self.FLeftoverBuffer[0],
          Self.FLeftoverCount * Self.GetChannels * SizeOf(double));
      PrevUp.FLeftoverCount := 0;
    end;

    if Assigned(Self.FBaseSource) then
      Self.FBaseSource.PrepareGapless(Previous);
  end;
end;

// ---> AulumicNS: the built-in converter (AuResample) with the same settings
// as libsoxr had: precision from the quality, the phase response for up- or
// downsampling, the pass band end (bandwidth) and the stop band start
// (anti-aliasing).
procedure TResamplerSource.CreateSoxrState;
begin
  try
    FSoxrState := TAuStreamResampler.Create(FBaseSource.GetSampleRate, FTargetRate,
      FBaseSource.GetChannels, FConfig);
  except
    on E: Exception do
      raise EAudioEngineError.CreateTyped(aeAudioFail, ERR_SOXR_INIT + ' ' + E.Message);
  end;
end;
destructor TResamplerSource.Destroy;
begin
  FreeAndNil(FSoxrState);

  FBaseSource.Free;
  inherited;
end;

function TResamplerSource.GetSampleRate: cardinal;
begin
  if FTargetRate > 0 then
    Result := FTargetRate
  else
    Result := FBaseSource.GetSampleRate * 2;
end;

function TResamplerSource.GetChannels: word;
begin
  Result := FBaseSource.GetChannels;
end;

function TResamplerSource.GetBitsPerSample: word;
begin
  if FTargetBits > 0 then
    Result := FTargetBits
  else
    Result := FBaseSource.GetBitsPerSample;
end;

function TResamplerSource.GetProgress: double;
begin
  Result := FBaseSource.GetProgress;
end;

function TResamplerSource.GetDuration: double;
begin
  Result := FBaseSource.GetDuration;
end;

procedure TResamplerSource.Seek(Percent: double);
begin
  if Assigned(FBaseSource) then
    // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
    FBaseSource.Seek(EnsureRange(Percent, 0.0, 1.0));

  // ---> AulumicNS: the converter starts again (the designed filter is kept
  // in the cache, so this costs nothing)
  if FSoxrState <> nil then
    FSoxrState.Reset
  else
    CreateSoxrState;
  FLeftoverCount := 0;
  FEndFlushed := False;
end;

function TResamplerSource.ReadData(B: Pointer; len: integer): integer;
var
  SafeFramesOut, TargetFramesOut, TotalOdone: integer;
  MaxOutFrames, MaxInFrames, MaxReadFrames: integer;
  SamplesNeeded, BytesRead, FramesRead, I, Channels, BytesPerSample,
  TotalFramesToProcess, NewSampleCount, OutSampleCount, BaseOffset: integer;
  InBits, OutBits, TargetBytesPerSample: integer;
  idone, odone: SizeUInt;
  ProcIn, ProcOut: Integer;
  PI16: PSmallInt;
  PI24: pbyte;
  PI32: PInteger;
  PO16: PSmallInt;
  PO24: pbyte;
  PO32: PInteger;
  S32: double;
  Val24: integer;
  LocalSeed: cardinal;
  FileHitEOF: Boolean;
  BlockClipped: Boolean;
begin
  if len <= 0 then
    Exit(0);

  // ---> AUDIT FIX 2.1: If FSoxrState is nil, return 0 (EOF) rather than
  // feeding mismatched sample rate / bit depth bytes into the WASAPI buffer.
  if FSoxrState = nil then
    Exit(0);

  Channels := FBaseSource.GetChannels;
  InBits   := FBaseSource.GetBitsPerSample;
  if FTargetBits > 0 then
    OutBits := FTargetBits
  else
    OutBits := InBits;

  if (Channels = 0) or (InBits < 8) or (OutBits < 8) then
    Exit(0);

  BytesPerSample       := InBits div 8;
  TargetBytesPerSample := OutBits div 8;

  MaxOutFrames := Length(FOutputBufferFloat) div Channels;
  MaxInFrames  := Length(FInputBufferFloat) div Channels;

  SafeFramesOut := len div (Channels * TargetBytesPerSample);
  TotalOdone    := 0;
  FileHitEOF    := False;
  LocalSeed     := FDitherSeed;

  PO16 := PSmallInt(B);
  PO24 := pbyte(B);
  PO32 := PInteger(B);

  while TotalOdone < SafeFramesOut do
  begin
    TargetFramesOut := SafeFramesOut - TotalOdone;
    if TargetFramesOut > MaxOutFrames then
      TargetFramesOut := MaxOutFrames;

    MaxReadFrames := Length(FInternalBufferInt) div (Channels * BytesPerSample);
    if MaxReadFrames > (MaxInFrames - FLeftoverCount) then
      MaxReadFrames := MaxInFrames - FLeftoverCount;
    if MaxReadFrames < 0 then
      MaxReadFrames := 0;

    // ---> AUDIT FIX 2.7: Clamp Int64 Trunc before narrowing to Integer
    SamplesNeeded := EnsureRange(Trunc(TargetFramesOut / FRatio), 0, MaxReadFrames) +
                     SOXR_LOOKAHEAD_FRAMES - FLeftoverCount;
    if SamplesNeeded > MaxReadFrames then
      SamplesNeeded := MaxReadFrames;
    if SamplesNeeded < 0 then
      SamplesNeeded := 0;

    BytesRead := 0;
    if (SamplesNeeded > 0) and (not FileHitEOF) then
    begin
      BytesRead := FBaseSource.ReadData(@FInternalBufferInt[0], SamplesNeeded * Channels * BytesPerSample);
      if BytesRead = 0 then
        FileHitEOF := True;
    end;

    if FileHitEOF and (FLeftoverCount = 0) then
    begin
      // ---> AulumicNS: all input is in: the converter's FFT stages compute
      // their last (shorter) block; what it gives is taken below like any
      // output (input 0). A gapless next track continues the converter.
      if not FEndFlushed then
      begin
        FSoxrState.Flush;
        FEndFlushed := True;
      end;
      if FSoxrState.Pending = 0 then
        Break;
    end;

    FramesRead           := BytesRead div (Channels * BytesPerSample);
    TotalFramesToProcess := FLeftoverCount + FramesRead;

    if FLeftoverCount > 0 then
      Move(FLeftoverBuffer[0], FInputBufferFloat[0], FLeftoverCount * Channels * SizeOf(double));

    NewSampleCount := FramesRead * Channels;
    BaseOffset     := FLeftoverCount * Channels;

    if NewSampleCount > 0 then
    begin
      if InBits = 16 then
      begin
        PI16 := PSmallInt(@FInternalBufferInt[0]);
        for I := 0 to NewSampleCount - 1 do
        begin
          FInputBufferFloat[BaseOffset + I] := PI16^ * INV_PCM16_FLT;
          Inc(PI16);
        end;
      end
      else if InBits = 24 then
      begin
        PI24 := pbyte(@FInternalBufferInt[0]);
        for I := 0 to NewSampleCount - 1 do
        begin
          Val24 := (PI24[0]) or (PI24[1] shl 8) or (PI24[2] shl 16);
          if (Val24 and PCM24_SIGN_BIT) <> 0 then
            Val24 := Val24 or PCM24_SIGN_EXT_MASK;
          FInputBufferFloat[BaseOffset + I] := Val24 * INV_PCM24_FLT;
          Inc(PI24, 3);
        end;
      end
      else if InBits = 32 then
      begin
        PI32 := PInteger(@FInternalBufferInt[0]);
        for I := 0 to NewSampleCount - 1 do
        begin
          FInputBufferFloat[BaseOffset + I] := PI32^ * INV_PCM32_FLT;
          Inc(PI32);
        end;
      end;
    end;

    idone := 0;
    odone := 0;

    FSoxrState.Process(@FInputBufferFloat[0], TotalFramesToProcess, ProcIn,
      @FOutputBufferFloat[0], TargetFramesOut, ProcOut);
    idone := SizeUInt(ProcIn);
    odone := SizeUInt(ProcOut);

    if idone < SizeUInt(TotalFramesToProcess) then
    begin
      FLeftoverCount := TotalFramesToProcess - idone;
      Move(FInputBufferFloat[idone * Channels], FLeftoverBuffer[0],
        FLeftoverCount * Channels * SizeOf(double));
    end
    else
      FLeftoverCount := 0;

    if (FileHitEOF and (odone = 0)) or ((idone = 0) and (odone = 0)) then
      Break;

    OutSampleCount := integer(odone) * Channels;

    if Assigned(FOnFloatDSP) then
    begin
      BlockClipped := False;
      FOnFloatDSP(@FOutputBufferFloat[0], integer(odone), Channels, OutBits, BlockClipped);
      if BlockClipped then
        FClipped := True;

      if OutBits = 32 then
      begin
        for I := 0 to OutSampleCount - 1 do
        begin
          PO32^ := Round(FOutputBufferFloat[I]);
          Inc(PO32);
        end;
      end
      else if OutBits = 24 then
      begin
        for I := 0 to OutSampleCount - 1 do
        begin
          Val24   := Round(FOutputBufferFloat[I]);
          PO24[0] := Val24 and $FF;
          PO24[1] := (Val24 shr 8) and $FF;
          PO24[2] := (Val24 shr 16) and $FF;
          Inc(PO24, 3);
        end;
      end
      else if OutBits = 16 then
      begin
        for I := 0 to OutSampleCount - 1 do
        begin
          PO16^ := Round(FOutputBufferFloat[I]);
          Inc(PO16);
        end;
      end;
    end
    else
    begin
      if OutBits = 32 then
      begin
        for I := 0 to OutSampleCount - 1 do
        begin
          S32 := FOutputBufferFloat[I] * PCM32_SCALE_FLT;
          if S32 > PCM32_MAX_FLT then
          begin
            S32      := PCM32_MAX_FLT;
            FClipped := True;
          end
          else if S32 < PCM32_MIN_FLT then
          begin
            S32      := PCM32_MIN_FLT;
            FClipped := True;
          end;
          PO32^ := Round(S32);
          Inc(PO32);
        end;
      end
      else if OutBits = 24 then
      begin
        for I := 0 to OutSampleCount - 1 do
        begin
          S32 := (FOutputBufferFloat[I] * PCM24_SCALE_FLT) + NextTPDFDither(LocalSeed);
          if S32 > PCM24_MAX_FLT then
          begin
            S32      := PCM24_MAX_FLT;
            FClipped := True;
          end
          else if S32 < PCM24_MIN_FLT then
          begin
            S32      := PCM24_MIN_FLT;
            FClipped := True;
          end;
          Val24   := Round(S32);
          PO24[0] := Val24 and $FF;
          PO24[1] := (Val24 shr 8) and $FF;
          PO24[2] := (Val24 shr 16) and $FF;
          Inc(PO24, 3);
        end;
      end
      else if OutBits = 16 then
      begin
        for I := 0 to OutSampleCount - 1 do
        begin
          S32 := (FOutputBufferFloat[I] * PCM16_SCALE_FLT) + NextTPDFDither(LocalSeed);
          if S32 > PCM16_MAX_FLT then
          begin
            S32      := PCM16_MAX_FLT;
            FClipped := True;
          end
          else if S32 < PCM16_MIN_FLT then
          begin
            S32      := PCM16_MIN_FLT;
            FClipped := True;
          end;
          PO16^ := Round(S32);
          Inc(PO16);
        end;
      end;
    end;

    Inc(TotalOdone, odone);
  end;

  FDitherSeed := LocalSeed;
  Result      := TotalOdone * Channels * TargetBytesPerSample;
end;

{ TBitDepthConverterSource }

constructor TBitDepthConverterSource.Create(Base: TAudioSource; TargetBits: word);
begin
  inherited Create;
  FBaseSource := Base;
  FTargetBits := TargetBits;
  FDitherSeed := DEFAULT_PRNG_SEED;
  SetLength(FTempBuffer, CONV_TEMP_BUF_BYTES);
end;

destructor TBitDepthConverterSource.Destroy;
begin
  FBaseSource.Free;
  inherited;
end;

function TBitDepthConverterSource.GetSampleRate: cardinal;
begin
  Result := FBaseSource.GetSampleRate;
end;

function TBitDepthConverterSource.GetChannels: word;
begin
  Result := FBaseSource.GetChannels;
end;

function TBitDepthConverterSource.GetBitsPerSample: word;
begin
  Result := FTargetBits;
end;

function TBitDepthConverterSource.GetSourceBitsPerSample: word;
begin
  if Assigned(FBaseSource) then
    Result := FBaseSource.GetBitsPerSample
  else
    Result := FTargetBits;
end;

function TBitDepthConverterSource.GetProgress: double;
begin
  Result := FBaseSource.GetProgress;
end;

function TBitDepthConverterSource.GetDuration: double;
begin
  Result := FBaseSource.GetDuration;
end;

procedure TBitDepthConverterSource.Seek(Percent: double);
begin
  // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
  FBaseSource.Seek(EnsureRange(Percent, 0.0, 1.0));
end;

procedure TBitDepthConverterSource.PrepareGapless(Previous: TAudioSource);
var
  PrevBit: TBitDepthConverterSource;
begin
  if Assigned(Previous) then
  begin
    PrevBit := TBitDepthConverterSource(Previous.FindLayer(TBitDepthConverterSource));
    if Assigned(PrevBit) then
      Self.FDitherSeed := PrevBit.FDitherSeed;
  end;
  FBaseSource.PrepareGapless(Previous);
end;

procedure TBitDepthConverterSource.SetDSDGain(GainDB: double);
begin
  FBaseSource.SetDSDGain(GainDB);
end;

function TBitDepthConverterSource.IsDoP: boolean;
begin
  Result := FBaseSource.IsDoP;
end;

function TBitDepthConverterSource.CheckClipping: boolean;
var
  BaseClipped: boolean;
begin
  BaseClipped := False;
  if Assigned(FBaseSource) then
    BaseClipped := FBaseSource.CheckClipping;

  Result   := FClipped or BaseClipped;
  FClipped := False;
end;

function TBitDepthConverterSource.GetDoPMarker: byte;
begin
  if Assigned(FBaseSource) then
    Result := FBaseSource.GetDoPMarker
  else
    Result := DOP_MARKER_DEFAULT;
end;

procedure TBitDepthConverterSource.SetDoPMarker(Value: byte);
begin
  if Assigned(FBaseSource) then
    FBaseSource.SetDoPMarker(Value);
end;

function TBitDepthConverterSource.FindLayer(AClass: TClass): TAudioSource;
begin
  if Self is AClass then
    Result := Self
  else if Assigned(FBaseSource) then
    Result := FBaseSource.FindLayer(AClass)
  else
    Result := nil;
end;

function TBitDepthConverterSource.ReadData(B: Pointer; len: integer): integer;
var
  InBits, OutBits, Channels, InBlockAlign, OutBlockAlign: integer;
  TotalFramesRequested, TotalFramesDone, MaxChunkFrames, ChunkFrames: integer;
  BytesToRead, BytesRead, FramesRead, TotalSamples, I, Val32, Dither: integer;
  Val64: int64;
  LocalSeed: cardinal;
  PI16, PO16: PSmallInt;
  PI24, PO24: pbyte;
  PI32, PO32: PInteger;
begin
  InBits   := FBaseSource.GetBitsPerSample;
  OutBits  := FTargetBits;
  Channels := FBaseSource.GetChannels;

  if (Channels = 0) or (InBits < 8) or (OutBits < 8) then
    Exit(0);

  if InBits = OutBits then
    Exit(FBaseSource.ReadData(B, len));

  if len <= 0 then
    Exit(0);

  InBlockAlign  := Channels * (InBits div 8);
  OutBlockAlign := Channels * (OutBits div 8);

  MaxChunkFrames       := Length(FTempBuffer) div InBlockAlign;
  TotalFramesRequested := len div OutBlockAlign;
  if (MaxChunkFrames <= 0) or (TotalFramesRequested <= 0) then
    Exit(0);

  TotalFramesDone := 0;
  LocalSeed       := FDitherSeed;

  PO16 := PSmallInt(B);
  PO24 := pbyte(B);
  PO32 := PInteger(B);

  while TotalFramesDone < TotalFramesRequested do
  begin
    ChunkFrames := TotalFramesRequested - TotalFramesDone;
    if ChunkFrames > MaxChunkFrames then
      ChunkFrames := MaxChunkFrames;

    BytesToRead := ChunkFrames * InBlockAlign;
    BytesRead   := FBaseSource.ReadData(@FTempBuffer[0], BytesToRead);
    if BytesRead <= 0 then
      Break;

    FramesRead := BytesRead div InBlockAlign;
    if FramesRead <= 0 then
      Break;

    TotalSamples := FramesRead * Channels;

    PI16 := PSmallInt(@FTempBuffer[0]);
    PI24 := pbyte(@FTempBuffer[0]);
    PI32 := PInteger(@FTempBuffer[0]);

    if (InBits = 16) and (OutBits = 32) then
    begin
      for I := 0 to TotalSamples - 1 do
      begin
        PO32^ := Integer(PI16^) shl 16;
        Inc(PI16);
        Inc(PO32);
      end;
    end
    else if (InBits = 24) and (OutBits = 32) then
    begin
      for I := 0 to TotalSamples - 1 do
      begin
        Val32 := PI24[0] or (PI24[1] shl 8) or (PI24[2] shl 16);
        if (Val32 and PCM24_SIGN_BIT) <> 0 then
          Val32 := Val32 or PCM24_SIGN_EXT_MASK;
        PO32^ := Val32 shl 8;
        Inc(PI24, 3);
        Inc(PO32);
      end;
    end
    else if (InBits = 16) and (OutBits = 24) then
    begin
      for I := 0 to TotalSamples - 1 do
      begin
        Val32   := Integer(PI16^) shl 8;
        PO24[0] := Val32 and $FF;
        PO24[1] := (Val32 shr 8) and $FF;
        PO24[2] := (Val32 shr 16) and $FF;
        Inc(PI16);
        Inc(PO24, 3);
      end;
    end
    else if (InBits = 32) and (OutBits = 24) then
    begin
      for I := 0 to TotalSamples - 1 do
      begin
        LocalSeed := LocalSeed xor (LocalSeed shl 13);
        LocalSeed := LocalSeed xor (LocalSeed shr 17);
        LocalSeed := LocalSeed xor (LocalSeed shl 5);

        Dither := Integer(LocalSeed and $FF) - Integer((LocalSeed shr 16) and $FF);
        Val64  := Int64(PI32^) + ROUND_BIAS_8BIT + Dither;

        if Val64 > PCM32_MAX_INT then
        begin
          Val64    := PCM32_MAX_INT;
          FClipped := True;
        end
        else if Val64 < PCM32_MIN_INT then
        begin
          Val64    := PCM32_MIN_INT;
          FClipped := True;
        end;

        Val32   := Integer(Val64 shr 8);
        PO24[0] := Val32 and $FF;
        PO24[1] := (Val32 shr 8) and $FF;
        PO24[2] := (Val32 shr 16) and $FF;
        Inc(PI32);
        Inc(PO24, 3);
      end;
    end
    else if (InBits = 24) and (OutBits = 16) then
    begin
      for I := 0 to TotalSamples - 1 do
      begin
        Val32 := PI24[0] or (PI24[1] shl 8) or (PI24[2] shl 16);
        if (Val32 and PCM24_SIGN_BIT) <> 0 then
          Val32 := Val32 or PCM24_SIGN_EXT_MASK;

        LocalSeed := LocalSeed xor (LocalSeed shl 13);
        LocalSeed := LocalSeed xor (LocalSeed shr 17);
        LocalSeed := LocalSeed xor (LocalSeed shl 5);

        Dither := Integer(LocalSeed and $FF) - Integer((LocalSeed shr 16) and $FF);
        Val32  := Val32 + ROUND_BIAS_8BIT + Dither;

        if Val32 > PCM24_MAX_INT then
        begin
          Val32    := PCM24_MAX_INT;
          FClipped := True;
        end
        else if Val32 < PCM24_MIN_INT then
        begin
          Val32    := PCM24_MIN_INT;
          FClipped := True;
        end;

        PO16^ := SmallInt(Val32 shr 8);
        Inc(PI24, 3);
        Inc(PO16);
      end;
    end
    else if (InBits = 32) and (OutBits = 16) then
    begin
      for I := 0 to TotalSamples - 1 do
      begin
        LocalSeed := LocalSeed xor (LocalSeed shl 13);
        LocalSeed := LocalSeed xor (LocalSeed shr 17);
        LocalSeed := LocalSeed xor (LocalSeed shl 5);

        Dither := Integer(LocalSeed and $FFFF) - Integer(LocalSeed shr 16);
        Val64  := Int64(PI32^) + ROUND_BIAS_16BIT + Dither;

        if Val64 > PCM32_MAX_INT then
        begin
          Val64    := PCM32_MAX_INT;
          FClipped := True;
        end
        else if Val64 < PCM32_MIN_INT then
        begin
          Val64    := PCM32_MIN_INT;
          FClipped := True;
        end;

        PO16^ := SmallInt(Val64 shr 16);
        Inc(PI32);
        Inc(PO16);
      end;
    end;

    Inc(TotalFramesDone, FramesRead);

    if BytesRead < BytesToRead then
      Break;
  end;

  FDitherSeed := LocalSeed;
  Result      := TotalFramesDone * OutBlockAlign;
end;

{ TMonoToStereoSource }

constructor TMonoToStereoSource.Create(Base: TAudioSource);
begin
  inherited Create;
  FBaseSource := Base;
  SetLength(FTempBuffer, CONV_TEMP_BUF_BYTES);
end;

destructor TMonoToStereoSource.Destroy;
begin
  FBaseSource.Free;
  inherited;
end;

function TMonoToStereoSource.GetSampleRate: cardinal;
begin
  Result := FBaseSource.GetSampleRate;
end;

function TMonoToStereoSource.GetChannels: word;
begin
  Result := 2;
end;

function TMonoToStereoSource.GetBitsPerSample: word;
begin
  Result := FBaseSource.GetBitsPerSample;
end;

function TMonoToStereoSource.GetProgress: double;
begin
  Result := FBaseSource.GetProgress;
end;

function TMonoToStereoSource.GetDuration: double;
begin
  Result := FBaseSource.GetDuration;
end;

procedure TMonoToStereoSource.Seek(Percent: double);
begin
  // ---> AUDIT FIX 2.7: Clamp seek range to 0.0..1.0
  FBaseSource.Seek(EnsureRange(Percent, 0.0, 1.0));
end;

procedure TMonoToStereoSource.PrepareGapless(Previous: TAudioSource);
begin
  FBaseSource.PrepareGapless(Previous);
end;

procedure TMonoToStereoSource.SetDSDGain(GainDB: double);
begin
  FBaseSource.SetDSDGain(GainDB);
end;

function TMonoToStereoSource.IsDoP: boolean;
begin
  Result := FBaseSource.IsDoP;
end;

function TMonoToStereoSource.CheckClipping: boolean;
begin
  Result := FBaseSource.CheckClipping;
end;

function TMonoToStereoSource.GetDoPMarker: byte;
begin
  Result := FBaseSource.GetDoPMarker;
end;

procedure TMonoToStereoSource.SetDoPMarker(Value: byte);
begin
  FBaseSource.SetDoPMarker(Value);
end;

procedure TMonoToStereoSource.SetTargetBitDepth(Bits: word);
begin
  FBaseSource.SetTargetBitDepth(Bits);
end;

function TMonoToStereoSource.FindLayer(AClass: TClass): TAudioSource;
begin
  if Self is AClass then
    Result := Self
  else if Assigned(FBaseSource) then
    Result := FBaseSource.FindLayer(AClass)
  else
    Result := nil;
end;

function TMonoToStereoSource.ReadData(B: Pointer; len: integer): integer;
var
  BytesPerSample, TotalFramesRequested, TotalFramesDone,
  MaxChunkFrames, ChunkFrames, BytesToRead, BytesRead, FramesRead, I: integer;
  PI16, PO16: PSmallInt;
  PI32, PO32: PInteger;
  PIn, POut: pbyte;
begin
  if len <= 0 then
    Exit(0);

  BytesPerSample := FBaseSource.GetBitsPerSample div 8;
  if BytesPerSample <= 0 then
    Exit(0);

  // Loop in fixed 64 KB FTempBuffer slices (Zero SetLength)
  MaxChunkFrames       := Length(FTempBuffer) div BytesPerSample;
  TotalFramesRequested := len div (2 * BytesPerSample);
  if (MaxChunkFrames <= 0) or (TotalFramesRequested <= 0) then
    Exit(0);

  TotalFramesDone := 0;
  PO16            := PSmallInt(B);
  PO32            := PInteger(B);
  POut            := pbyte(B);

  while TotalFramesDone < TotalFramesRequested do
  begin
    ChunkFrames := TotalFramesRequested - TotalFramesDone;
    if ChunkFrames > MaxChunkFrames then
      ChunkFrames := MaxChunkFrames;

    BytesToRead := ChunkFrames * BytesPerSample;
    BytesRead   := FBaseSource.ReadData(@FTempBuffer[0], BytesToRead);
    if BytesRead <= 0 then
      Break;

    FramesRead := BytesRead div BytesPerSample;
    if FramesRead <= 0 then
      Break;

    if BytesPerSample = 2 then // 16-bit
    begin
      PI16 := PSmallInt(@FTempBuffer[0]);
      for I := 0 to FramesRead - 1 do
      begin
        PO16^ := PI16^;
        Inc(PO16);
        PO16^ := PI16^;
        Inc(PO16);
        Inc(PI16);
      end;
    end
    else if BytesPerSample = 3 then // 24-bit
    begin
      PIn := pbyte(@FTempBuffer[0]);
      for I := 0 to FramesRead - 1 do
      begin
        POut[0] := PIn[0];
        POut[1] := PIn[1];
        POut[2] := PIn[2];
        POut[3] := PIn[0];
        POut[4] := PIn[1];
        POut[5] := PIn[2];
        Inc(POut, 6);
        Inc(PIn, 3);
      end;
    end
    else if BytesPerSample = 4 then // 32-bit
    begin
      PI32 := PInteger(@FTempBuffer[0]);
      for I := 0 to FramesRead - 1 do
      begin
        PO32^ := PI32^;
        Inc(PO32);
        PO32^ := PI32^;
        Inc(PO32);
        Inc(PI32);
      end;
    end
    else if BytesPerSample = 1 then // 8-bit
    begin
      PIn := pbyte(@FTempBuffer[0]);
      for I := 0 to FramesRead - 1 do
      begin
        POut^ := PIn^;
        Inc(POut);
        POut^ := PIn^;
        Inc(POut);
        Inc(PIn);
      end;
    end;

    Inc(TotalFramesDone, FramesRead);

    if BytesRead < BytesToRead then
      Break;
  end;

  Result := TotalFramesDone * 2 * BytesPerSample;
end;

end.
