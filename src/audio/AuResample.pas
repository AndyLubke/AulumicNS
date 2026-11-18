unit AuResample;

{ ==============================================================================
  AulumicNS - AuResample
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Sample rate conversion of AulumicNS, in Pascal, all in
  double precision. A polyphase converter (rational
  L / M, Kaiser windowed sinc, two stages for ratios of 3 and more)
  with these resampler settings:

  - Quality: the precision in bits like soxr (0 = 32, 1 = 28, 2 = 24,
    3 = 20, 4 = 16 bits); the stop band attenuation is 6.02 dB per bit.
  - Bandwidth: where the pass band ends, in % of the Nyquist frequency of
    the lower rate (soxr passband_end).
  - Anti-aliasing: where the stop band starts, in % of that Nyquist
    frequency (soxr stopband_begin): 100 = no aliasing / imaging at all,
    105 / 110 = a little of the transition band beyond Nyquist.
  - Phase response, separately for up- and downsampling:
      linear        symmetric filter, pre- and post-ringing (soxr 50)
      minimum       no pre-ringing, the ringing comes after the transient
                    (soxr 0); made from the linear filter with the cepstral
                    method (same magnitude response)
      intermediate  the phase half way between both (soxr 25): the same
                    magnitude, the mean of the minimum and the linear phase

  Designing a long minimum phase filter takes some time (FFTs of up to 2^20
  points), so every designed filter is kept (FilterCache) and shared by all
  converters with the same parameters - a seek or the next track of an
  album does not design again.

  A stage runs in direct form or, where that is cheaper, in FFT form
  (overlap-save, blocks at fixed stream positions; SetResampleFft). The inner
  loops are also written in SSE2 and AVX assembler with the same result bit
  for bit (SetResampleSimd).

  TAuStreamResampler has a streaming interface like
  libsoxr's: Process takes input frames, returns how many it used and how many
  output frames it wrote (interleaved doubles). Call Flush once at the end
  of the input, or the last block of an FFT stage never comes out.
  =============================================================================}

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, Math, SyncObjs, ALAudioTypes;

type
  TDoubleArray = array of Double;
  TAuPhase = (rpLinear, rpIntermediate, rpMinimum);

  { The filter's inner loop (the dot product of the taps):
    rsAuto takes AVX when the CPU and Windows support it, else SSE2 (every
    x64 CPU); rsPascal / rsSSE2 / rsAVX force one (Tools\AudioSim --simd=,
    to compare). All give the same output bit for bit. }
  TResampleSimd = (rsAuto, rsPascal, rsSSE2, rsAVX);

{ chooses the inner loop (rsAVX falls back to SSE2 without AVX support) }
procedure SetResampleSimd(AMode: TResampleSimd);
{ the inner loop in use: 'AVX', 'SSE2' or 'Pascal' }
function ResampleSimdName: string;
{ Long filters of 2x up / 2:1 down stages by FFT (default on);
  off = every stage in direct form (to compare: AudioSim --fft=0).
  Applies to converters created afterwards. }
procedure SetResampleFft(AOn: Boolean);
function ResampleFftOn: Boolean;

type

  { TAuFftPlan - a complex radix-2 FFT of one size (twiddles and the bit
    reversal computed once) }

  TAuFftPlan = class
  private
    FN: Integer;
    FSwapA, FSwapB: array of Integer;   // the bit reversal as pairs to swap
    FWr, FWi: TDoubleArray;             // twiddles, stage of half size H at H - 1 ..
  public
    constructor Create(AN: Integer);
    { forward transform in place (Re, Im: N values each), no scaling. The
      inverse: Forward(Im, Re) (real and imaginary swapped), then / N }
    procedure Forward(Re, Im: PDouble);
    property N: Integer read FN;
  end;

  { TAuPolyStage - one rational L / M polyphase stage }

  TAuPolyStage = class
  private
    FIn, FOut: Cardinal;
    FL, FM: Integer;              // up / down factors
    FT: Integer;                  // taps per phase
    FD: Int64;                    // output alignment (upsampled domain)
    FCh: Integer;
    FCoef: TDoubleArray;          // FL phases x FT taps, reversed per phase (shared)
    FHist: array of TDoubleArray; // per channel input from FBase on
    FHistLen: Integer;
    FBase: Int64;
    FOutCount: Int64;
    FStepQ, FStepR: Integer;      // FM div FL, FM mod FL (Produce steps with them)
    { The FFT form (overlap-save). Each phase P is a
      convolution of the input with its FT taps; the stage computes it for
      blocks of up to FBlk input frames at once: one FFT of the block (two
      channels at a time, as real and imaginary part), per phase a product
      with the phase's spectrum and an inverse FFT. The blocks lie at fixed
      places of the stream (FInStart on by FBlk, or up to a Flush), so the
      output does not depend on how the input is cut. }
    FFft: Boolean;
    FN, FBlk, FPairs: Integer;    // FFT size, new frames per block, channel pairs
    FPlan: TAuFftPlan;
    FHRe, FHIm: array of TDoubleArray;   // per phase: the spectrum of its taps / FN
    FXr, FXi, FWr, FWi: TDoubleArray;    // work
    FQ: TDoubleArray;             // the last block's outputs in output order ...
    FQPos, FQLen: Integer;        // ... (frames), not delivered from FQPos on
    FGenCount: Int64;             // outputs put into FQ so far
    FInStart: Int64;              // the first input frame not in a block yet
    FBlkStart: Int64;             // the last block: its first input frame ...
    FBlkCount: Integer;           // ... and its length
    FFlushAt: array of Int64;     // blocks end there (Flush), oldest first
    FFlushN: Integer;
    procedure Append(Src: PDouble; Frames: Integer);
    function Produce(Dst: PDouble; Cap: Integer): Integer;
    procedure SetupFft;
    function NextBlock: Boolean;
    procedure FftBlock(K: Integer);
    function ProduceFft(Dst: PDouble; Cap: Integer): Integer;
  public
    { Pass / Stop: edges of the filter in Hz; Atten: stop band in dB }
    constructor Create(InRate, OutRate: Cardinal; Channels: Integer; Pass, Stop, Atten: Double;
      Phase: TAuPhase);
    destructor Destroy; override;
    { feeds SrcFrames interleaved frames, writes the available output frames
      to Dst (grown when needed); returns the number of output frames }
    function Process(Src: PDouble; SrcFrames: Integer; var Dst: TDoubleArray): Integer;
    { the input so far is all there is for now (end of the stream): the
      next Process gives every output it determines. The direct form gives
      them anyway; the FFT form computes its last, shorter block. More input
      may follow (gapless). }
    procedure Flush;
    procedure Reset;
    property TapsPerPhase: Integer read FT;
    property UpFactor: Integer read FL;
    property DownFactor: Integer read FM;
    property UsesFft: Boolean read FFft;
    property FftSize: Integer read FN;
  end;

  { TAuResampler - one or two stages }

  TAuResampler = class
  private
    FIn, FOut: Cardinal;
    FCh: Integer;
    FS1, FS2: TAuPolyStage;
    FTmp: TDoubleArray;
  public
    constructor Create(InRate, OutRate: Cardinal; Channels: Integer; const Config: TSoXConfig);
    destructor Destroy; override;
    function Process(Src: PDouble; SrcFrames: Integer; var Dst: TDoubleArray): Integer;
    { end of the input for now: writes what is still due to Dst (see
      TAuPolyStage.Flush) and returns the number of frames }
    function Flush(var Dst: TDoubleArray): Integer;
    procedure Reset;
    function TapsPerPhase: Integer;
    { 'direct' / 'FFT' per stage, e.g. 'FFT 4096 + direct' }
    function Describe: string;
    property InRate: Cardinal read FIn;
    property OutRate: Cardinal read FOut;
    property Stage1: TAuPolyStage read FS1;
    property Stage2: TAuPolyStage read FS2;
  end;

  { TAuStreamResampler - the soxr style streaming interface }

  TAuStreamResampler = class
  private
    FRes: TAuResampler;
    FCh: Integer;
    FRatio: Double;
    FFifo: TDoubleArray;          // produced, not yet delivered
    FFifoPos, FFifoLen: Integer;  // in frames
    FTmp: TDoubleArray;
  public
    constructor Create(InRate, OutRate: Cardinal; Channels: Integer; const Config: TSoXConfig);
    destructor Destroy; override;
    { uses up to InFrames frames of InBuf (InDone) and writes up to OutFrames
      frames to OutBuf (OutDone); the unused input stays with the caller }
    procedure Process(InBuf: PDouble; InFrames: Integer; out InDone: Integer;
      OutBuf: PDouble; OutFrames: Integer; out OutDone: Integer);
    { The input has ended (for now): what it still gives
      comes with the next Process calls (InFrames 0 is fine). Needed by the
      FFT stages, harmless for the direct ones. }
    procedure Flush;
    { output frames waiting for the next Process }
    function Pending: Integer;
    procedure Reset;
    property Resampler: TAuResampler read FRes;
  end;

{ the stop band attenuation for a quality index (soxr precision bits) }
function QualityAttenuation(Quality: Integer): Double;
{ the phase of a setting index (0 linear, 1 intermediate, 2 minimum) }
function PhaseOfSetting(Index: Integer): TAuPhase;
{ the prototype of a stage (for tests): FT taps per phase, L phases, in time
  order (not reversed), with its DC gain normalised to L }
function DesignPrototype(FsP, Pass, Stop, Atten: Double; L: Integer; Phase: TAuPhase;
  out FT: Integer): TDoubleArray;
{ in-place radix-2 FFT of N = power of two points; Inverse divides by N }
procedure FFT(var Re, Im: TDoubleArray; N: Integer; Inverse: Boolean);
procedure ClearFilterCache;

implementation

uses
  cpu;

const
  { The largest FFT of an FFT stage }
  FFT_MAX_SIZE = 1 shl 16;

{ ---- the inner loop ----

  An output sample is the dot product of FT coefficients with FT input
  samples per channel. The Pascal loop keeps four running sums per channel:
  S0 gets the products of taps 0, 4, 8 ..., S1 those of 1, 5, 9 ..., and so
  on; at the end (S0 + S1) + (S2 + S3). Every product and every sum is one
  IEEE double operation, rounded as such (Free Pascal uses SSE2 scalar
  instructions for Double on x64).

  The SIMD loops do exactly these operations, only several at once: SSE2
  keeps S0 / S1 in one 128 bit register and S2 / S3 in another (two doubles
  per instruction), AVX all four in one 256 bit register. Each lane adds the
  same products in the same order as its scalar sum, with a separate
  multiply and add (no fused multiply-add, which rounds once instead of
  twice). So the output is the same bit for bit (checked with the hashes of
  Tools\AudioSim bench), only faster.

  The loops cover the taps in groups of 4 (N); the caller adds the last
  0 .. 3 taps to S0 / R0 and joins the sums, as the Pascal loop does.
  Win64 calling convention: the argument record in rcx; only rax, rcx, rdx,
  r8 - r11 and xmm0 - xmm5 / ymm0 - ymm5 are used (free to change). After
  AVX, vzeroupper: the following SSE code of the compiler would otherwise
  pay for the switch between AVX and SSE states. }

type
  TDotArgs = record
    Cf, Hp, Hq: PDouble;   // coefficients; history of channel 1 (and 2)
    N: PtrInt;             // taps, a multiple of 4
    Acc: PDouble;          // out: S0..S3 (and R0..R3)
  end;
  PDotArgs = ^TDotArgs;
  TDotProc = procedure(A: PDotArgs);

{$asmmode intel}

procedure DotStereoSSE2(A: PDotArgs); assembler; nostackframe;
asm
  mov    rax, [rcx]            // Cf
  mov    rdx, [rcx + 8]        // Hp
  mov    r8,  [rcx + 16]       // Hq
  mov    r9,  [rcx + 24]       // N
  mov    r10, [rcx + 32]       // Acc
  xorpd  xmm0, xmm0            // S0 S1
  xorpd  xmm1, xmm1            // S2 S3
  xorpd  xmm2, xmm2            // R0 R1
  xorpd  xmm3, xmm3            // R2 R3
  shl    r9, 3                 // N in bytes
  xor    r11, r11
  test   r9, r9
  jz     @done
@loop:
  movupd xmm4, [rax + r11]     // K0 K1
  movupd xmm5, [rdx + r11]
  mulpd  xmm5, xmm4
  addpd  xmm0, xmm5
  movupd xmm5, [r8 + r11]
  mulpd  xmm5, xmm4
  addpd  xmm2, xmm5
  movupd xmm4, [rax + r11 + 16] // K2 K3
  movupd xmm5, [rdx + r11 + 16]
  mulpd  xmm5, xmm4
  addpd  xmm1, xmm5
  movupd xmm5, [r8 + r11 + 16]
  mulpd  xmm5, xmm4
  addpd  xmm3, xmm5
  add    r11, 32
  cmp    r11, r9
  jb     @loop
@done:
  movupd [r10], xmm0
  movupd [r10 + 16], xmm1
  movupd [r10 + 32], xmm2
  movupd [r10 + 48], xmm3
end;

procedure DotMonoSSE2(A: PDotArgs); assembler; nostackframe;
asm
  mov    rax, [rcx]            // Cf
  mov    rdx, [rcx + 8]        // Hp
  mov    r9,  [rcx + 24]       // N
  mov    r10, [rcx + 32]       // Acc
  xorpd  xmm0, xmm0            // S0 S1
  xorpd  xmm1, xmm1            // S2 S3
  shl    r9, 3
  xor    r11, r11
  test   r9, r9
  jz     @done
@loop:
  movupd xmm4, [rax + r11]
  movupd xmm5, [rdx + r11]
  mulpd  xmm5, xmm4
  addpd  xmm0, xmm5
  movupd xmm4, [rax + r11 + 16]
  movupd xmm5, [rdx + r11 + 16]
  mulpd  xmm5, xmm4
  addpd  xmm1, xmm5
  add    r11, 32
  cmp    r11, r9
  jb     @loop
@done:
  movupd [r10], xmm0
  movupd [r10 + 16], xmm1
end;

procedure DotStereoAVX(A: PDotArgs); assembler; nostackframe;
asm
  mov     rax, [rcx]           // Cf
  mov     rdx, [rcx + 8]       // Hp
  mov     r8,  [rcx + 16]      // Hq
  mov     r9,  [rcx + 24]      // N
  mov     r10, [rcx + 32]      // Acc
  vxorpd  ymm0, ymm0, ymm0     // S0 S1 S2 S3
  vxorpd  ymm1, ymm1, ymm1     // R0 R1 R2 R3
  shl     r9, 3
  xor     r11, r11
  test    r9, r9
  jz      @done
@loop:
  vmovupd ymm2, [rax + r11]    // K0..K3
  vmovupd ymm3, [rdx + r11]
  vmulpd  ymm3, ymm3, ymm2
  vaddpd  ymm0, ymm0, ymm3
  vmovupd ymm4, [r8 + r11]
  vmulpd  ymm4, ymm4, ymm2
  vaddpd  ymm1, ymm1, ymm4
  add     r11, 32
  cmp     r11, r9
  jb      @loop
@done:
  vmovupd [r10], ymm0
  vmovupd [r10 + 32], ymm1
  vzeroupper
end;

procedure DotMonoAVX(A: PDotArgs); assembler; nostackframe;
asm
  mov     rax, [rcx]           // Cf
  mov     rdx, [rcx + 8]       // Hp
  mov     r9,  [rcx + 24]      // N
  mov     r10, [rcx + 32]      // Acc
  vxorpd  ymm0, ymm0, ymm0     // S0 S1 S2 S3
  shl     r9, 3
  xor     r11, r11
  test    r9, r9
  jz      @done
@loop:
  vmovupd ymm2, [rax + r11]
  vmovupd ymm3, [rdx + r11]
  vmulpd  ymm3, ymm3, ymm2
  vaddpd  ymm0, ymm0, ymm3
  add     r11, 32
  cmp     r11, r9
  jb      @loop
@done:
  vmovupd [r10], ymm0
  vzeroupper
end;

{ The FFT butterflies of one group (TAuFftPlan.Forward, the
  stages of half size H >= 4): Count butterflies, pairs H apart. Each lane
  does what the Pascal loop does for its K, in the same order and without
  fused multiply-add, so all three give the same bits. The pointers are
  moved to the ends and indexed from -Count up to 0 (seven registers). }

type
  TBflyArgs = record
    Ra, Ia, Rb, Ib, Wr, Wi: PDouble;
    Count: PtrInt;          // a multiple of 4
  end;
  PBflyArgs = ^TBflyArgs;
  TBflyProc = procedure(A: PBflyArgs);

procedure BflySSE2(A: PBflyArgs); assembler; nostackframe;
asm
  mov    rax, [rcx]            // Ra
  mov    rdx, [rcx + 8]        // Ia
  mov    r8,  [rcx + 16]       // Rb
  mov    r9,  [rcx + 24]       // Ib
  mov    r10, [rcx + 32]       // Wr
  mov    r11, [rcx + 40]       // Wi
  mov    rcx, [rcx + 48]       // Count
  shl    rcx, 3
  add    rax, rcx
  add    rdx, rcx
  add    r8,  rcx
  add    r9,  rcx
  add    r10, rcx
  add    r11, rcx
  neg    rcx
  jz     @done
@loop:
  movupd xmm0, [r10 + rcx]     // CR
  movupd xmm1, [r11 + rcx]     // CI
  movupd xmm2, [r8 + rcx]      // BR
  movupd xmm3, [r9 + rcx]      // BI
  movapd xmm4, xmm2
  mulpd  xmm4, xmm0            // BR * CR
  movapd xmm5, xmm3
  mulpd  xmm5, xmm1            // BI * CI
  subpd  xmm4, xmm5            // TR
  mulpd  xmm2, xmm1            // BR * CI
  mulpd  xmm3, xmm0            // BI * CR
  addpd  xmm2, xmm3            // TI
  movupd xmm0, [rax + rcx]     // AR
  movupd xmm1, [rdx + rcx]     // AI
  movapd xmm3, xmm0
  subpd  xmm3, xmm4            // AR - TR
  addpd  xmm0, xmm4            // AR + TR
  movupd [r8 + rcx], xmm3
  movupd [rax + rcx], xmm0
  movapd xmm3, xmm1
  subpd  xmm3, xmm2            // AI - TI
  addpd  xmm1, xmm2            // AI + TI
  movupd [r9 + rcx], xmm3
  movupd [rdx + rcx], xmm1
  add    rcx, 16
  jnz    @loop
@done:
end;

procedure BflyAVX(A: PBflyArgs); assembler; nostackframe;
asm
  mov     rax, [rcx]
  mov     rdx, [rcx + 8]
  mov     r8,  [rcx + 16]
  mov     r9,  [rcx + 24]
  mov     r10, [rcx + 32]
  mov     r11, [rcx + 40]
  mov     rcx, [rcx + 48]
  shl     rcx, 3
  add     rax, rcx
  add     rdx, rcx
  add     r8,  rcx
  add     r9,  rcx
  add     r10, rcx
  add     r11, rcx
  neg     rcx
  jz      @done
@loop:
  vmovupd ymm0, [r10 + rcx]    // CR
  vmovupd ymm1, [r11 + rcx]    // CI
  vmovupd ymm2, [r8 + rcx]     // BR
  vmovupd ymm3, [r9 + rcx]     // BI
  vmulpd  ymm4, ymm2, ymm0     // BR * CR
  vmulpd  ymm5, ymm3, ymm1     // BI * CI
  vsubpd  ymm4, ymm4, ymm5     // TR
  vmulpd  ymm2, ymm2, ymm1     // BR * CI
  vmulpd  ymm3, ymm3, ymm0     // BI * CR
  vaddpd  ymm2, ymm2, ymm3     // TI
  vmovupd ymm0, [rax + rcx]    // AR
  vmovupd ymm1, [rdx + rcx]    // AI
  vsubpd  ymm3, ymm0, ymm4
  vaddpd  ymm0, ymm0, ymm4
  vmovupd [r8 + rcx], ymm3
  vmovupd [rax + rcx], ymm0
  vsubpd  ymm3, ymm1, ymm2
  vaddpd  ymm1, ymm1, ymm2
  vmovupd [r9 + rcx], ymm3
  vmovupd [rdx + rcx], ymm1
  add     rcx, 32
  jnz     @loop
@done:
  vzeroupper
end;

{ the spectrum product of an FFT stage: W = X x H (complex, Count points, a
  multiple of 4): Wr = Xr Hr - Xi Hi, Wi = Xr Hi + Xi Hr, as CMulPas }

type
  TCMulArgs = record
    Xr, Xi, Hr, Hi, Wr, Wi: PDouble;
    Count: PtrInt;
  end;
  PCMulArgs = ^TCMulArgs;
  TCMulProc = procedure(A: PCMulArgs);

procedure CMulSSE2(A: PCMulArgs); assembler; nostackframe;
asm
  mov    rax, [rcx]            // Xr
  mov    rdx, [rcx + 8]        // Xi
  mov    r8,  [rcx + 16]       // Hr
  mov    r9,  [rcx + 24]       // Hi
  mov    r10, [rcx + 32]       // Wr
  mov    r11, [rcx + 40]       // Wi
  mov    rcx, [rcx + 48]       // Count
  shl    rcx, 3
  add    rax, rcx
  add    rdx, rcx
  add    r8,  rcx
  add    r9,  rcx
  add    r10, rcx
  add    r11, rcx
  neg    rcx
  jz     @done
@loop:
  movupd xmm0, [rax + rcx]     // A
  movupd xmm1, [rdx + rcx]     // B
  movupd xmm2, [r8 + rcx]      // CR
  movupd xmm3, [r9 + rcx]      // CI
  movapd xmm4, xmm0
  mulpd  xmm4, xmm2            // A * CR
  movapd xmm5, xmm1
  mulpd  xmm5, xmm3            // B * CI
  subpd  xmm4, xmm5
  mulpd  xmm0, xmm3            // A * CI
  mulpd  xmm1, xmm2            // B * CR
  addpd  xmm0, xmm1
  movupd [r10 + rcx], xmm4
  movupd [r11 + rcx], xmm0
  add    rcx, 16
  jnz    @loop
@done:
end;

procedure CMulAVX(A: PCMulArgs); assembler; nostackframe;
asm
  mov     rax, [rcx]
  mov     rdx, [rcx + 8]
  mov     r8,  [rcx + 16]
  mov     r9,  [rcx + 24]
  mov     r10, [rcx + 32]
  mov     r11, [rcx + 40]
  mov     rcx, [rcx + 48]
  shl     rcx, 3
  add     rax, rcx
  add     rdx, rcx
  add     r8,  rcx
  add     r9,  rcx
  add     r10, rcx
  add     r11, rcx
  neg     rcx
  jz      @done
@loop:
  vmovupd ymm0, [rax + rcx]
  vmovupd ymm1, [rdx + rcx]
  vmovupd ymm2, [r8 + rcx]
  vmovupd ymm3, [r9 + rcx]
  vmulpd  ymm4, ymm0, ymm2     // A * CR
  vmulpd  ymm5, ymm1, ymm3     // B * CI
  vsubpd  ymm4, ymm4, ymm5
  vmulpd  ymm0, ymm0, ymm3     // A * CI
  vmulpd  ymm1, ymm1, ymm2     // B * CR
  vaddpd  ymm0, ymm0, ymm1
  vmovupd [r10 + rcx], ymm4
  vmovupd [r11 + rcx], ymm0
  add     rcx, 32
  jnz     @loop
@done:
  vzeroupper
end;

{$asmmode default}

procedure CMulPas(A: PCMulArgs);
var
  I: PtrInt;
  X, Y, CR, CI: Double;
begin
  for I := 0 to A^.Count - 1 do
  begin
    X := A^.Xr[I];
    Y := A^.Xi[I];
    CR := A^.Hr[I];
    CI := A^.Hi[I];
    A^.Wr[I] := X * CR - Y * CI;
    A^.Wi[I] := X * CI + Y * CR;
  end;
end;

procedure BflyPas(A: PBflyArgs);
var
  K: PtrInt;
  TR, TI, AR, AI, BR, BI, CR, CI: Double;
begin
  for K := 0 to A^.Count - 1 do
  begin
    CR := A^.Wr[K];
    CI := A^.Wi[K];
    BR := A^.Rb[K];
    BI := A^.Ib[K];
    TR := BR * CR - BI * CI;
    TI := BR * CI + BI * CR;
    AR := A^.Ra[K];
    AI := A^.Ia[K];
    A^.Rb[K] := AR - TR;
    A^.Ib[K] := AI - TI;
    A^.Ra[K] := AR + TR;
    A^.Ia[K] := AI + TI;
  end;
end;

{ the Pascal loop (for comparisons) }
procedure DotStereoPas(A: PDotArgs);
var
  J: PtrInt;
  Cf, Hp, Hq, Acc: PDouble;
  S0, S1, S2, S3, R0, R1, R2, R3, K0, K1, K2, K3: Double;
begin
  Cf := A^.Cf;
  Hp := A^.Hp;
  Hq := A^.Hq;
  Acc := A^.Acc;
  S0 := 0; S1 := 0; S2 := 0; S3 := 0;
  R0 := 0; R1 := 0; R2 := 0; R3 := 0;
  J := 0;
  while J < A^.N do
  begin
    K0 := Cf[J];
    K1 := Cf[J + 1];
    K2 := Cf[J + 2];
    K3 := Cf[J + 3];
    S0 := S0 + K0 * Hp[J];
    R0 := R0 + K0 * Hq[J];
    S1 := S1 + K1 * Hp[J + 1];
    R1 := R1 + K1 * Hq[J + 1];
    S2 := S2 + K2 * Hp[J + 2];
    R2 := R2 + K2 * Hq[J + 2];
    S3 := S3 + K3 * Hp[J + 3];
    R3 := R3 + K3 * Hq[J + 3];
    Inc(J, 4);
  end;
  Acc[0] := S0; Acc[1] := S1; Acc[2] := S2; Acc[3] := S3;
  Acc[4] := R0; Acc[5] := R1; Acc[6] := R2; Acc[7] := R3;
end;

procedure DotMonoPas(A: PDotArgs);
var
  J: PtrInt;
  Cf, Hp, Acc: PDouble;
  S0, S1, S2, S3: Double;
begin
  Cf := A^.Cf;
  Hp := A^.Hp;
  Acc := A^.Acc;
  S0 := 0; S1 := 0; S2 := 0; S3 := 0;
  J := 0;
  while J < A^.N do
  begin
    S0 := S0 + Cf[J] * Hp[J];
    S1 := S1 + Cf[J + 1] * Hp[J + 1];
    S2 := S2 + Cf[J + 2] * Hp[J + 2];
    S3 := S3 + Cf[J + 3] * Hp[J + 3];
    Inc(J, 4);
  end;
  Acc[0] := S0; Acc[1] := S1; Acc[2] := S2; Acc[3] := S3;
end;

var
  GDotStereo: TDotProc = @DotStereoSSE2;
  GDotMono: TDotProc = @DotMonoSSE2;
  GBfly: TBflyProc = @BflySSE2;
  GCMul: TCMulProc = @CMulSSE2;
  GSimdName: string = 'SSE2';

procedure SetResampleSimd(AMode: TResampleSimd);
begin
  if (AMode in [rsAuto, rsAVX]) and AVXSupport then
  begin
    GDotStereo := @DotStereoAVX;
    GDotMono := @DotMonoAVX;
    GBfly := @BflyAVX;
    GCMul := @CMulAVX;
    GSimdName := 'AVX';
  end
  else if AMode = rsPascal then
  begin
    GDotStereo := @DotStereoPas;
    GDotMono := @DotMonoPas;
    GBfly := @BflyPas;
    GCMul := @CMulPas;
    GSimdName := 'Pascal';
  end
  else
  begin
    GDotStereo := @DotStereoSSE2;
    GDotMono := @DotMonoSSE2;
    GBfly := @BflySSE2;
    GCMul := @CMulSSE2;
    GSimdName := 'SSE2';
  end;
end;

function ResampleSimdName: string;
begin
  Result := GSimdName;
end;

var
  GFftOn: Boolean = True;

procedure SetResampleFft(AOn: Boolean);
begin
  GFftOn := AOn;
end;

function ResampleFftOn: Boolean;
begin
  Result := GFftOn;
end;

{ ---- TAuFftPlan ----

  Radix-2, decimation in time: the input in bit reversed order, then log2 N
  stages of butterflies. The stage of half size H combines pairs H apart
  with the twiddles exp(-i pi K / H), K < H, stored one after the other for
  each stage (index H - 1 + K), so the inner loop reads them in order. }

constructor TAuFftPlan.Create(AN: Integer);
var
  I, J, K, H, Count: Integer;
begin
  inherited Create;
  FN := AN;
  { the pairs the bit reversal swaps }
  SetLength(FSwapA, AN div 2);
  SetLength(FSwapB, AN div 2);
  Count := 0;
  J := 0;
  for I := 0 to AN - 2 do
  begin
    if I < J then
    begin
      if Count >= Length(FSwapA) then
      begin
        SetLength(FSwapA, Count * 2);
        SetLength(FSwapB, Count * 2);
      end;
      FSwapA[Count] := I;
      FSwapB[Count] := J;
      Inc(Count);
    end;
    K := AN shr 1;
    while (K >= 1) and (J >= K) do
    begin
      Dec(J, K);
      K := K shr 1;
    end;
    Inc(J, K);
  end;
  SetLength(FSwapA, Count);
  SetLength(FSwapB, Count);
  SetLength(FWr, Math.Max(1, AN - 1));
  SetLength(FWi, Math.Max(1, AN - 1));
  H := 1;
  while H < AN do
  begin
    for K := 0 to H - 1 do
      if K = 0 then
      begin
        FWr[H - 1] := 1;                 // exact: 0 and 90 degrees
        FWi[H - 1] := 0;
      end
      else if 2 * K = H then
      begin
        FWr[H - 1 + K] := 0;
        FWi[H - 1 + K] := -1;
      end
      else
      begin
        FWr[H - 1 + K] := Cos(Pi * K / H);
        FWi[H - 1 + K] := -Sin(Pi * K / H);
      end;
    H := H shl 1;
  end;
end;

procedure TAuFftPlan.Forward(Re, Im: PDouble);
var
  I, H, H2, A, B: Integer;
  T, AR, AI, BR, BI: Double;
  Args: TBflyArgs;
begin
  for I := 0 to High(FSwapA) do
  begin
    A := FSwapA[I];
    B := FSwapB[I];
    T := Re[A]; Re[A] := Re[B]; Re[B] := T;
    T := Im[A]; Im[A] := Im[B]; Im[B] := T;
  end;
  if FN < 4 then
  begin
    if FN = 2 then
    begin
      AR := Re[0]; AI := Im[0]; BR := Re[1]; BI := Im[1];
      Re[0] := AR + BR; Im[0] := AI + BI;
      Re[1] := AR - BR; Im[1] := AI - BI;
    end;
    Exit;
  end;
  { H = 1 and H = 2 together: the twiddles are 1 and -i (no products) }
  I := 0;
  while I < FN do
  begin
    { H = 1 }
    AR := Re[I]; AI := Im[I];
    BR := Re[I + 1]; BI := Im[I + 1];
    Re[I] := AR + BR; Im[I] := AI + BI;
    Re[I + 1] := AR - BR; Im[I + 1] := AI - BI;
    AR := Re[I + 2]; AI := Im[I + 2];
    BR := Re[I + 3]; BI := Im[I + 3];
    Re[I + 2] := AR + BR; Im[I + 2] := AI + BI;
    Re[I + 3] := AR - BR; Im[I + 3] := AI - BI;
    { H = 2: I with I + 2 (twiddle 1), I + 1 with I + 3 (twiddle -i:
      (BR + i BI) (-i) = BI - i BR) }
    AR := Re[I]; AI := Im[I];
    BR := Re[I + 2]; BI := Im[I + 2];
    Re[I] := AR + BR; Im[I] := AI + BI;
    Re[I + 2] := AR - BR; Im[I + 2] := AI - BI;
    AR := Re[I + 1]; AI := Im[I + 1];
    BR := Im[I + 3]; BI := -Re[I + 3];
    Re[I + 1] := AR + BR; Im[I + 1] := AI + BI;
    Re[I + 3] := AR - BR; Im[I + 3] := AI - BI;
    Inc(I, 4);
  end;
  { H >= 4: the butterflies of each group by the SIMD loop (GBfly) }
  H := 4;
  while H < FN do
  begin
    H2 := 2 * H;
    Args.Wr := @FWr[H - 1];
    Args.Wi := @FWi[H - 1];
    Args.Count := H;
    I := 0;
    while I < FN do
    begin
      Args.Ra := Re + I;
      Args.Ia := Im + I;
      Args.Rb := Re + I + H;
      Args.Ib := Im + I + H;
      GBfly(@Args);
      Inc(I, H2);
    end;
    H := H2;
  end;
end;

{ ---- helpers ---- }

function GcdC(A, B: Int64): Int64;
var
  T: Int64;
begin
  while B <> 0 do
  begin
    T := A mod B;
    A := B;
    B := T;
  end;
  Result := A;
end;

function BesselI0(X: Double): Double;
var
  Sum, Term, Y: Double;
  K: Integer;
begin
  Sum := 1;
  Term := 1;
  Y := X * X / 4;
  K := 1;
  repeat
    Term := Term * Y / (K * K);
    Sum := Sum + Term;
    Inc(K);
  until (Term < Sum * 1E-17) or (K > 500);
  Result := Sum;
end;

{ Kaiser window value at offset K from the centre of an N tap filter (in
  Double on purpose: Math.Max may pick the Single overload) }
function KaiserWindow(K: Double; N: Integer; Beta, I0B: Double): Double;
var
  R: Double;
begin
  R := 2 * K / (N - 1);
  R := 1 - R * R;
  if R < 0 then R := 0;
  Result := BesselI0(Beta * Sqrt(R)) / I0B;
end;

function KaiserBeta(Atten: Double): Double;
begin
  if Atten > 50 then Result := 0.1102 * (Atten - 8.7)
  else if Atten > 21 then Result := 0.5842 * Power(Atten - 21, 0.4) + 0.07886 * (Atten - 21)
  else Result := 0;
end;

function QualityAttenuation(Quality: Integer): Double;
var
  Bits: Double;
begin
  case Quality of
    0: Bits := 32;
    1: Bits := 28;
    2: Bits := 24;
    3: Bits := 20;
    4: Bits := 16;
  else
    Bits := 24;
  end;
  Result := Bits * 6.0206;
end;

function PhaseOfSetting(Index: Integer): TAuPhase;
begin
  case Index of
    0: Result := rpLinear;
    2: Result := rpMinimum;
  else
    Result := rpIntermediate;
  end;
end;

{ ---- FFT ---- }

procedure FFT(var Re, Im: TDoubleArray; N: Integer; Inverse: Boolean);
var
  I, J, K, M, Half, Step: Integer;
  TR, TI, WR, WI, UR, UI, Ang, CS, SN, Inv: Double;
  CosT, SinT: TDoubleArray;
begin
  { bit reversal }
  J := 0;
  for I := 0 to N - 2 do
  begin
    if I < J then
    begin
      TR := Re[I]; Re[I] := Re[J]; Re[J] := TR;
      TI := Im[I]; Im[I] := Im[J]; Im[J] := TI;
    end;
    K := N shr 1;
    while (K >= 1) and (J >= K) do
    begin
      Dec(J, K);
      K := K shr 1;
    end;
    Inc(J, K);
  end;
  { twiddles for the largest stage; smaller stages take every Step-th }
  SetLength(CosT, N div 2);
  SetLength(SinT, N div 2);
  for I := 0 to N div 2 - 1 do
  begin
    Ang := 2 * Pi * I / N;
    CosT[I] := Cos(Ang);
    if Inverse then SinT[I] := Sin(Ang) else SinT[I] := -Sin(Ang);
  end;
  M := 2;
  while M <= N do
  begin
    Half := M shr 1;
    Step := N div M;
    I := 0;
    while I < N do
    begin
      for K := 0 to Half - 1 do
      begin
        CS := CosT[K * Step];
        SN := SinT[K * Step];
        WR := Re[I + K + Half];
        WI := Im[I + K + Half];
        UR := WR * CS - WI * SN;
        UI := WR * SN + WI * CS;
        Re[I + K + Half] := Re[I + K] - UR;
        Im[I + K + Half] := Im[I + K] - UI;
        Re[I + K] := Re[I + K] + UR;
        Im[I + K] := Im[I + K] + UI;
      end;
      Inc(I, M);
    end;
    M := M shl 1;
  end;
  if Inverse then
  begin
    Inv := 1 / N;
    for I := 0 to N - 1 do
    begin
      Re[I] := Re[I] * Inv;
      Im[I] := Im[I] * Inv;
    end;
  end;
end;

{ ---- filter design ---- }

{ the linear phase prototype: N = FT * L - 1 taps (odd, integer delay) }
function DesignLinear(FsP, Pass, Stop, Atten: Double; L: Integer; out FT: Integer; out N: Integer): TDoubleArray;
var
  Fc, Beta, I0B, K, X, Wn: Double;
  I: Integer;
  D: Integer;
begin
  Fc := (Pass + Stop) / 2 / FsP;
  Wn := 2 * Pi * (Stop - Pass) / FsP;
  N := Ceil((Atten - 8) / (2.285 * Wn)) + 1;
  FT := Math.Max(8, (N + L - 1) div L);
  if FT mod 2 = 1 then Inc(FT);
  N := FT * L - 1;
  D := (N - 1) div 2;
  Beta := KaiserBeta(Atten);
  I0B := BesselI0(Beta);
  Result := nil;
  SetLength(Result, FT * L);
  for I := 0 to N - 1 do
  begin
    K := I - D;
    if K = 0 then X := 2 * Fc
    else X := Sin(2 * Pi * Fc * K) / (Pi * K);
    Result[I] := X * KaiserWindow(K, N, Beta, I0B);
  end;
  Result[N] := 0;
end;

{ minimum / intermediate phase from the linear prototype H (N taps), with
  the same magnitude response (cepstral method). Returns the new taps (as
  many as needed for the tail to fall below the stop band). }
function MakeNonLinear(const H: TDoubleArray; N: Integer; Atten: Double; Phase: TAuPhase): TDoubleArray;
var
  NFFT, I, J, Len, MaxLen, Peak, Half, First, Last, Best: Integer;
  Re, Im, Pre, Post: TDoubleArray;
  MaxMag, Floor_, Mag, D, Ph, E, K, Total, Tail, Limit, BestOut: Double;
begin
  NFFT := 1;
  while NFFT < 8 * N do NFFT := NFFT shl 1;
  if NFFT > 1 shl 20 then NFFT := 1 shl 20;
  while NFFT < 2 * N do NFFT := NFFT shl 1;
  SetLength(Re, NFFT);
  SetLength(Im, NFFT);
  for I := 0 to N - 1 do Re[I] := H[I];
  FFT(Re, Im, NFFT, False);
  { log magnitude (with a floor far below the stop band) }
  MaxMag := 0;
  for I := 0 to NFFT - 1 do
  begin
    Mag := Sqrt(Sqr(Re[I]) + Sqr(Im[I]));
    Re[I] := Mag;
    if Mag > MaxMag then MaxMag := Mag;
  end;
  Floor_ := MaxMag * Power(10, -(Atten + 60) / 20);
  for I := 0 to NFFT - 1 do
  begin
    if Re[I] < Floor_ then Re[I] := Floor_;
    Re[I] := Ln(Re[I]);
    Im[I] := 0;
  end;
  { real cepstrum }
  FFT(Re, Im, NFFT, True);
  { fold: the causal part twice, the anti-causal part removed }
  for I := 1 to NFFT div 2 - 1 do Re[I] := 2 * Re[I];
  for I := NFFT div 2 + 1 to NFFT - 1 do Re[I] := 0;
  for I := 0 to NFFT - 1 do Im[I] := 0;
  { the complex log spectrum of the minimum phase filter }
  FFT(Re, Im, NFFT, False);
  D := (N - 1) / 2;
  for I := 0 to NFFT - 1 do
  begin
    Ph := Im[I];
    if Phase = rpIntermediate then
    begin
      if I <= NFFT div 2 then K := I else K := I - NFFT;
      Ph := 0.5 * Ph + 0.5 * (-2 * Pi * K * D / NFFT);
    end;
    E := Exp(Re[I]);
    Re[I] := E * Cos(Ph);
    Im[I] := E * Sin(Ph);
  end;
  FFT(Re, Im, NFFT, True);
  { The response is circular. The minimum phase one starts at 0; the
    intermediate one starts before its delay (that part wraps to the end of
    the buffer), as soxr's does. Both ends are found from the point opposite
    the peak: the samples before the start and after the end may hold only
    Limit / 2 of the energy each (summed from the far side, so the small
    values are not lost against the total) }
  Total := 0;
  Peak := 0;
  for I := 0 to NFFT - 1 do
  begin
    Total := Total + Sqr(Re[I]);
    if Abs(Re[I]) > Abs(Re[Peak]) then Peak := I;
  end;
  Limit := Total * Power(10, -(Atten + 20) / 10) / 2;
  Half := NFFT div 2;
  Tail := 0;
  First := Peak;
  for I := 1 to Half - 1 do
  begin
    J := (Peak - Half + I + NFFT) mod NFFT;          // from far before the peak towards it
    Tail := Tail + Sqr(Re[J]);
    if Tail > Limit then
    begin
      First := Peak - Half + I;                      // may be < 0: before the buffer start
      Break;
    end;
  end;
  Tail := 0;
  Last := Peak;
  for I := 1 to Half - 1 do
  begin
    J := (Peak + Half - I) mod NFFT;                 // from far after the peak towards it
    Tail := Tail + Sqr(Re[J]);
    if Tail > Limit then
    begin
      Last := Peak + Half - I;
      Break;
    end;
  end;
  if Phase = rpIntermediate then MaxLen := 2 * N else MaxLen := N + N div 2;
  MaxLen := Math.Min(MaxLen, Half);
  Len := Last - First + 1;
  if Len > MaxLen then
  begin
    { longer than allowed (the intermediate response decays slowly on both
      sides): the window of MaxLen taps with the least energy outside, found
      from the two tail sums (Pre[K]: the K samples from the far point on
      before the peak; Post[K]: the samples after Peak + K) }
    Len := MaxLen;
    SetLength(Pre, Half + 1);
    SetLength(Post, Half + 1);
    Pre[0] := 0;
    for I := 1 to Half do
      Pre[I] := Pre[I - 1] + Sqr(Re[(Peak - Half + I - 1 + NFFT) mod NFFT]);
    Post[Half] := 0;
    Post[Half - 1] := 0;
    for I := Half - 2 downto 0 do
      Post[I] := Post[I + 1] + Sqr(Re[(Peak + I + 1) mod NFFT]);
    Best := -1;
    BestOut := 0;
    for I := 0 to Len - 1 do                         // the window starts I samples before the peak
    begin
      if (I >= Half) or (Len - 1 - I >= Half) then Continue;
      E := Pre[Half - I] + Post[Len - 1 - I];
      if (Best < 0) or (E < BestOut) then
      begin
        Best := I;
        BestOut := E;
      end;
    end;
    if Best >= 0 then First := Peak - Best;
  end;
  if Len < N div 2 then Len := N div 2;
  Result := nil;
  SetLength(Result, Len);
  for I := 0 to Len - 1 do Result[I] := Re[((First + I) mod NFFT + NFFT) mod NFFT];
end;

function DesignPrototype(FsP, Pass, Stop, Atten: Double; L: Integer; Phase: TAuPhase;
  out FT: Integer): TDoubleArray;
var
  H, NL: TDoubleArray;
  N, I: Integer;
  Sum, Scale: Double;
begin
  H := DesignLinear(FsP, Pass, Stop, Atten, L, FT, N);
  if Phase <> rpLinear then
  begin
    NL := MakeNonLinear(H, N, Atten, Phase);
    FT := (Length(NL) + L - 1) div L;
    if FT < 8 then FT := 8;
    H := nil;
    SetLength(H, FT * L);
    for I := 0 to High(NL) do H[I] := NL[I];
  end;
  Sum := 0;
  for I := 0 to High(H) do Sum := Sum + H[I];
  Scale := L / Sum;                              // zero stuffing gain L
  for I := 0 to High(H) do H[I] := H[I] * Scale;
  Result := H;
end;

{ ---- the filter cache ---- }

type
  TCacheEntry = class
    Key: string;
    FT: Integer;
    Coef: TDoubleArray;   // polyphase, reversed per phase
  end;

var
  CacheLock: TCriticalSection = nil;
  Cache: TList = nil;

procedure ClearFilterCache;
var
  I: Integer;
begin
  if CacheLock = nil then Exit;
  CacheLock.Enter;
  try
    for I := 0 to Cache.Count - 1 do TCacheEntry(Cache[I]).Free;
    Cache.Clear;
  finally
    CacheLock.Leave;
  end;
end;

{ the polyphase coefficients of a stage (designed once per parameter set);
  phase P uses H[P + J * L], stored reversed so that it is a dot product with
  the history in time order }
procedure GetStageCoefs(FsP, Pass, Stop, Atten: Double; L: Integer; Phase: TAuPhase;
  out FT: Integer; out Coef: TDoubleArray);
var
  Key: string;
  I, P, J: Integer;
  E: TCacheEntry;
  H: TDoubleArray;
begin
  Key := Format('%.6f|%.6f|%.6f|%.3f|%d|%d', [FsP, Pass, Stop, Atten, L, Ord(Phase)]);
  CacheLock.Enter;
  try
    for I := 0 to Cache.Count - 1 do
      if TCacheEntry(Cache[I]).Key = Key then
      begin
        FT := TCacheEntry(Cache[I]).FT;
        Coef := TCacheEntry(Cache[I]).Coef;
        Exit;
      end;
  finally
    CacheLock.Leave;
  end;
  { designed outside the lock (another thread may design the same at the
    same time: harmless, the first one is kept) }
  H := DesignPrototype(FsP, Pass, Stop, Atten, L, Phase, FT);
  Coef := nil;
  SetLength(Coef, L * FT);
  for P := 0 to L - 1 do
    for J := 0 to FT - 1 do
      Coef[P * FT + (FT - 1 - J)] := H[P + J * L];
  CacheLock.Enter;
  try
    for I := 0 to Cache.Count - 1 do
      if TCacheEntry(Cache[I]).Key = Key then
      begin
        FT := TCacheEntry(Cache[I]).FT;
        Coef := TCacheEntry(Cache[I]).Coef;
        Exit;
      end;
    E := TCacheEntry.Create;
    E.Key := Key;
    E.FT := FT;
    E.Coef := Coef;
    Cache.Add(E);
    { keep the cache small: the oldest go first }
    while Cache.Count > 24 do
    begin
      TCacheEntry(Cache[0]).Free;
      Cache.Delete(0);
    end;
  finally
    CacheLock.Leave;
  end;
end;

{ ---- the cost of the two forms ----

  In nanoseconds per output frame (stereo) on one E-core of the development
  PC, measured with AVX. Only the ratio decides, and with fixed
  numbers, so that a stage takes the same form (and gives the same output)
  on every PC. }

{ the direct form: the dot product of FT taps and a fixed part per output }
function DirectCost(FT: Integer): Double;
begin
  Result := 12 + 0.28 * FT;
end;

{ the FFT form with the best size N (returned): per block of N - FT + 1 new
  input frames one forward and L inverse FFTs (0.64 ns x N log2 N, more for
  sizes beyond the caches), L spectrum products (0.5 ns per point) and
  1 ns per output; the block gives (N - FT + 1) x L / M outputs }
function FftCost(FT, L, M: Integer; out N: Integer): Double;
var
  K, LogK: Integer;
  PerNLogN, C, Outs: Double;
begin
  N := 0;
  Result := 1E300;
  K := 256;
  LogK := 8;
  while K < 2 * FT do
  begin
    K := K shl 1;
    Inc(LogK);
  end;
  while K <= FFT_MAX_SIZE do
  begin
    case LogK of
      0..11: PerNLogN := 0.64;
      12: PerNLogN := 0.72;
      13: PerNLogN := 0.78;
      14: PerNLogN := 0.80;
      15: PerNLogN := 1.05;
    else
      PerNLogN := 1.10;
    end;
    Outs := Double(K - FT + 1) * L / M;
    C := ((1 + L) * PerNLogN * K * LogK + L * 0.5 * K) / Outs + 1;
    if C < Result then
    begin
      Result := C;
      N := K;
    end;
    K := K shl 1;
    Inc(LogK);
  end;
end;

{ ---- TAuPolyStage ---- }

constructor TAuPolyStage.Create(InRate, OutRate: Cardinal; Channels: Integer; Pass, Stop, Atten: Double;
  Phase: TAuPhase);
var
  G: Int64;
begin
  inherited Create;
  if (InRate = 0) or (OutRate = 0) or (Channels < 1) then
    raise EAudioEngineError.CreateTyped(aeAudioFail, 'Resampler: invalid rate');
  FIn := InRate;
  FOut := OutRate;
  FCh := Channels;
  G := GcdC(InRate, OutRate);
  FL := OutRate div G;
  FM := InRate div G;
  GetStageCoefs(Double(InRate) * FL, Pass, Stop, Atten, FL, Phase, FT, FCoef);
  { linear phase: the output is aligned with the input (its delay is
    compensated); the other phases are causal (no output ahead of time) }
  if Phase = rpLinear then FD := (FT * FL - 2) div 2 else FD := 0;
  FStepQ := FM div FL;
  FStepR := FM mod FL;
  SetLength(FHist, FCh);
  { The FFT form for upsampling by an integer (FM = 1, up to
    8) and 2:1 downsampling, when it costs less than the direct form
    (FftCost: the steep stages at every quality, most short ones too) }
  FFft := GFftOn and (((FM = 1) and (FL >= 2) and (FL <= 8)) or ((FL = 1) and (FM = 2))) and
    (FftCost(FT, FL, FM, FN) < 0.8 * DirectCost(FT));
  if FFft then SetupFft;
  Reset;
end;

destructor TAuPolyStage.Destroy;
begin
  FPlan.Free;
  inherited Destroy;
end;

procedure TAuPolyStage.SetupFft;
var
  P, J: Integer;
  Inv: Double;
begin
  FBlk := FN - FT + 1;
  FPairs := (FCh + 1) div 2;
  FPlan := TAuFftPlan.Create(FN);
  SetLength(FHRe, FL);
  SetLength(FHIm, FL);
  Inv := 1 / FN;
  for P := 0 to FL - 1 do
  begin
    SetLength(FHRe[P], FN);
    SetLength(FHIm[P], FN);
    { the phase's taps in time order (FCoef holds them reversed) }
    for J := 0 to FT - 1 do FHRe[P][J] := FCoef[P * FT + FT - 1 - J];
    FPlan.Forward(@FHRe[P][0], @FHIm[P][0]);
    for J := 0 to FN - 1 do
    begin
      FHRe[P][J] := FHRe[P][J] * Inv;
      FHIm[P][J] := FHIm[P][J] * Inv;
    end;
  end;
  SetLength(FXr, FN);
  SetLength(FXi, FN);
  SetLength(FWr, FN);
  SetLength(FWi, FN);
  SetLength(FQ, (FBlk * FL div FM + 4) * FCh);
end;

procedure TAuPolyStage.Reset;
var
  C: Integer;
begin
  for C := 0 to FCh - 1 do
  begin
    SetLength(FHist[C], 4096 + FT);
    FillChar(FHist[C][0], FT * SizeOf(Double), 0);
  end;
  FHistLen := FT;
  FBase := -FT;
  FOutCount := 0;
  FInStart := 0;
  FBlkStart := 0;
  FBlkCount := 0;
  FFlushN := 0;
  FGenCount := 0;
  FQPos := 0;
  FQLen := 0;
end;

procedure TAuPolyStage.Flush;
var
  E: Int64;
begin
  if not FFft then Exit;
  E := FBase + FHistLen;
  if E <= FInStart then Exit;
  if (FFlushN > 0) and (FFlushAt[FFlushN - 1] >= E) then Exit;
  if FFlushN >= Length(FFlushAt) then SetLength(FFlushAt, FFlushN + 4);
  FFlushAt[FFlushN] := E;
  Inc(FFlushN);
end;

{ the next block, if its input is there: FBlk frames, or up to the oldest
  Flush point when that comes first }
function TAuPolyStage.NextBlock: Boolean;
var
  K, Avail: Int64;
begin
  Result := False;
  while (FFlushN > 0) and (FFlushAt[0] <= FInStart) do
  begin
    if FFlushN > 1 then Move(FFlushAt[1], FFlushAt[0], (FFlushN - 1) * SizeOf(Int64));
    Dec(FFlushN);
  end;
  K := FBlk;
  if (FFlushN > 0) and (FFlushAt[0] - FInStart < K) then K := FFlushAt[0] - FInStart;
  Avail := FBase + FHistLen - FInStart;
  if (K <= 0) or (Avail < K) then Exit;
  FftBlock(Integer(K));
  Result := True;
end;

{ one block of K new frames from FInStart on: the FFT input is the FT - 1
  frames before it and the K new ones (zeros after); output I + FT - 1 of
  the circular convolution is the phase's output for input frame
  FInStart + I (no wrap around there) }
procedure TAuPolyStage.FftBlock(K: Integer);
var
  Pair, C0, C1, I, P, Src0, Len, W, J, JStep: Integer;
  Wr, Wi, Q: PDouble;
  Mul: TCMulArgs;
  T0, Last, Base: Int64;
begin
  { the outputs of this block: from output FGenCount (T0) on, all whose
    input frame lies before FInStart + K }
  T0 := FGenCount * FM + FD;
  Last := (FInStart + K) * FL - 1;
  if Last >= T0 then W := Integer((Last - T0) div FM + 1) else W := 0;
  Q := @FQ[0];
  Src0 := Integer(FInStart - FT + 1 - FBase);
  Len := FT - 1 + K;
  for Pair := 0 to FPairs - 1 do
  begin
    C0 := 2 * Pair;
    C1 := C0 + 1;
    Move(FHist[C0][Src0], FXr[0], Len * SizeOf(Double));
    if Len < FN then FillChar(FXr[Len], (FN - Len) * SizeOf(Double), 0);
    if C1 < FCh then
    begin
      Move(FHist[C1][Src0], FXi[0], Len * SizeOf(Double));
      if Len < FN then FillChar(FXi[Len], (FN - Len) * SizeOf(Double), 0);
    end
    else
      FillChar(FXi[0], FN * SizeOf(Double), 0);
    FPlan.Forward(@FXr[0], @FXi[0]);
    Wr := @FWr[0];
    Wi := @FWi[0];
    Mul.Xr := @FXr[0];
    Mul.Xi := @FXi[0];
    Mul.Wr := Wr;
    Mul.Wi := Wi;
    Mul.Count := FN;
    for P := 0 to FL - 1 do
    begin
      Mul.Hr := @FHRe[P][0];
      Mul.Hi := @FHIm[P][0];
      GCMul(@Mul);                           // W = X x H
      { the inverse: real and imaginary part swapped (the 1 / N is in H) }
      FPlan.Forward(Wi, Wr);
      { straight into FQ: output N is phase T mod FL at input frame T div FL
        (T = N * FM + FD), so the value for input frame FInStart + I of
        phase P is output number ((FInStart + I) * FL + P - T0) / FM. FM = 1:
        every frame, FL apart in FQ; FL = 1, FM = 2: every second frame. }
      if FM = 1 then
      begin
        Base := FInStart * FL + P - T0;
        if Base >= 0 then I := 0 else I := Integer((FL - 1 - Base) div FL);
        J := Integer(Base + Int64(I) * FL);
        JStep := FL;
      end
      else
      begin
        I := Integer(T0 - FInStart);
        J := 0;
        JStep := 1;
      end;
      if C1 < FCh then
        while I < K do
        begin
          Q[J * FCh + C0] := Wr[FT - 1 + I];
          Q[J * FCh + C1] := Wi[FT - 1 + I];
          Inc(I, FM);
          Inc(J, JStep);
        end
      else
        while I < K do
        begin
          Q[J * FCh + C0] := Wr[FT - 1 + I];
          Inc(I, FM);
          Inc(J, JStep);
        end;
    end;
  end;
  FBlkStart := FInStart;
  FBlkCount := K;
  Inc(FInStart, K);
  Inc(FGenCount, W);
  FQPos := 0;
  FQLen := W;
end;

{ the outputs of the blocks (FftBlock puts them into FQ in order) }
function TAuPolyStage.ProduceFft(Dst: PDouble; Cap: Integer): Integer;
var
  N: Integer;
begin
  Result := 0;
  while Result < Cap do
  begin
    if FQPos >= FQLen then
      if not NextBlock then Break
      else Continue;
    N := Math.Min(Cap - Result, FQLen - FQPos);
    Move(FQ[FQPos * FCh], Dst[Result * FCh], N * FCh * SizeOf(Double));
    Inc(FQPos, N);
    Inc(Result, N);
  end;
  Inc(FOutCount, Result);
end;

procedure TAuPolyStage.Append(Src: PDouble; Frames: Integer);
var
  C, I, Need: Integer;
begin
  Need := FHistLen + Frames;
  if Length(FHist[0]) < Need then
    for C := 0 to FCh - 1 do SetLength(FHist[C], Need + Need div 2);
  for C := 0 to FCh - 1 do
    for I := 0 to Frames - 1 do FHist[C][FHistLen + I] := Src[I * FCh + C];
  Inc(FHistLen, Frames);
end;

function TAuPolyStage.Produce(Dst: PDouble; Cap: Integer): Integer;
var
  T, M0, First: Int64;
  P, C, J, Off, Drop, FT4: Integer;
  Cf, Hp, Hq: PDouble;
  S0, S1, S2, S3, R0, R1, R2, R3: Double;
  Args: TDotArgs;
  Acc: array[0..7] of Double;
begin
  Result := 0;
  FT4 := FT and not 3;
  { The position of the first output; then it steps on by
    FM / FL with additions (no 64-bit div and mod per output sample) }
  T := FOutCount * FM + FD;
  M0 := T div FL;                         // newest input sample used
  P := Integer(T mod FL);                 // the phase
  Args.N := FT4;
  Args.Acc := @Acc[0];
  while Result < Cap do
  begin
    if M0 >= FBase + FHistLen then Break; // not received yet
    First := M0 - FT + 1;
    Off := Integer(First - FBase);
    Cf := @FCoef[P * FT];
    Args.Cf := Cf;
    { The taps in groups of 4 by the SIMD loop (see
      TDotArgs), the last 0 .. 3 and the sums in Pascal: bit-identical.
      Stereo in one pass: each coefficient is loaded once for both. }
    if FCh = 2 then
    begin
      Hp := @FHist[0][Off];
      Hq := @FHist[1][Off];
      Args.Hp := Hp;
      Args.Hq := Hq;
      GDotStereo(@Args);
      S0 := Acc[0]; S1 := Acc[1]; S2 := Acc[2]; S3 := Acc[3];
      R0 := Acc[4]; R1 := Acc[5]; R2 := Acc[6]; R3 := Acc[7];
      J := FT4;
      while J < FT do
      begin
        S0 := S0 + Cf[J] * Hp[J];
        R0 := R0 + Cf[J] * Hq[J];
        Inc(J);
      end;
      Dst[Result * 2] := (S0 + S1) + (S2 + S3);
      Dst[Result * 2 + 1] := (R0 + R1) + (R2 + R3);
    end
    else
      for C := 0 to FCh - 1 do
      begin
        Hp := @FHist[C][Off];
        Args.Hp := Hp;
        GDotMono(@Args);
        S0 := Acc[0]; S1 := Acc[1]; S2 := Acc[2]; S3 := Acc[3];
        J := FT4;
        while J < FT do
        begin
          S0 := S0 + Cf[J] * Hp[J];
          Inc(J);
        end;
        Dst[Result * FCh + C] := (S0 + S1) + (S2 + S3);
      end;
    Inc(Result);
    Inc(FOutCount);
    { the next output: T + FM = (M0 + FStepQ) * FL + (P + FStepR) }
    Inc(M0, FStepQ);
    Inc(P, FStepR);
    if P >= FL then
    begin
      Dec(P, FL);
      Inc(M0);
    end;
  end;
  { drop history that no future output needs }
  T := FOutCount * FM + FD;
  First := T div FL - FT + 1;
  Drop := Integer(First - FBase);
  if Drop > 4096 then
  begin
    for C := 0 to FCh - 1 do Move(FHist[C][Drop], FHist[C][0], (FHistLen - Drop) * SizeOf(Double));
    Dec(FHistLen, Drop);
    Inc(FBase, Drop);
  end;
end;

function TAuPolyStage.Process(Src: PDouble; SrcFrames: Integer; var Dst: TDoubleArray): Integer;
var
  Cap: Int64;
  Drop, C: Integer;
begin
  if SrcFrames > 0 then Append(Src, SrcFrames);
  { Room for every output the input so far allows (output N
    needs input frame (N * FM + FD) div FL); the FFT form gives a whole
    block at once }
  Cap := (Int64(FBase + FHistLen) * FL - FD) div FM - FOutCount + 2;
  if Cap < 1 then Exit(0);
  if Length(Dst) < Cap * FCh then SetLength(Dst, Cap * FCh);
  if not FFft then Exit(Produce(@Dst[0], Integer(Cap)));
  Result := ProduceFft(@Dst[0], Integer(Cap));
  { drop the input the next block no longer needs (once per call: a block
    at a time would move the rest of a long input again and again) }
  Drop := Integer(FInStart - FT + 1 - FBase);
  if Drop > 4096 then
  begin
    for C := 0 to FCh - 1 do Move(FHist[C][Drop], FHist[C][0], (FHistLen - Drop) * SizeOf(Double));
    Dec(FHistLen, Drop);
    Inc(FBase, Drop);
  end;
end;

{ ---- TAuResampler ---- }

constructor TAuResampler.Create(InRate, OutRate: Cardinal; Channels: Integer; const Config: TSoXConfig);
var
  Lo, Pass, Stop, Atten: Double;
  Phase: TAuPhase;
begin
  inherited Create;
  if (InRate = 0) or (OutRate = 0) then
    raise EAudioEngineError.CreateTyped(aeAudioFail, 'Resampler: invalid rate');
  FIn := InRate;
  FOut := OutRate;
  FCh := Channels;
  Atten := QualityAttenuation(Config.Quality);
  if OutRate >= InRate then Phase := PhaseOfSetting(Config.UpsamplePhase)
  else Phase := PhaseOfSetting(Config.DownsamplePhase);
  if OutRate >= 3 * Int64(InRate) then
  begin
    { up: the steep filter at 2 x In, then a short one up to Out (the images
      of the first stage start at 2 x In - Stop) }
    Lo := InRate / 2;
    Pass := Lo * Config.Bandwidth / 100;
    Stop := Lo * Config.AntiAlias / 100;
    FS1 := TAuPolyStage.Create(InRate, 2 * InRate, Channels, Pass, Stop, Atten, Phase);
    { the short filter gets 45 dB more: the Kaiser length estimate is too
      optimistic for few taps }
    FS2 := TAuPolyStage.Create(2 * InRate, OutRate, Channels, Pass, 4 * Lo - Stop, Atten + 45, rpLinear);
  end
  else if InRate >= 3 * Int64(OutRate) then
  begin
    { down: a short filter to 2 x Out (what would fold into the band lies
      above 2 x Out - Stop), then the steep one }
    Lo := OutRate / 2;
    Pass := Lo * Config.Bandwidth / 100;
    Stop := Lo * Config.AntiAlias / 100;
    FS1 := TAuPolyStage.Create(InRate, 2 * OutRate, Channels, Pass, 4 * Lo - Stop, Atten + 45, rpLinear);
    FS2 := TAuPolyStage.Create(2 * OutRate, OutRate, Channels, Pass, Stop, Atten, Phase);
  end
  else
  begin
    if InRate < OutRate then Lo := InRate / 2 else Lo := OutRate / 2;
    Pass := Lo * Config.Bandwidth / 100;
    Stop := Lo * Config.AntiAlias / 100;
    FS1 := TAuPolyStage.Create(InRate, OutRate, Channels, Pass, Stop, Atten, Phase);
  end;
end;

destructor TAuResampler.Destroy;
begin
  FS1.Free;
  FS2.Free;
  inherited Destroy;
end;

function TAuResampler.Process(Src: PDouble; SrcFrames: Integer; var Dst: TDoubleArray): Integer;
var
  N: Integer;
begin
  if FS2 = nil then Exit(FS1.Process(Src, SrcFrames, Dst));
  N := FS1.Process(Src, SrcFrames, FTmp);
  if N > 0 then Result := FS2.Process(@FTmp[0], N, Dst)
  else Result := FS2.Process(nil, 0, Dst);
end;

function TAuResampler.Flush(var Dst: TDoubleArray): Integer;
var
  N: Integer;
begin
  FS1.Flush;
  if FS2 = nil then Exit(FS1.Process(nil, 0, Dst));
  N := FS1.Process(nil, 0, FTmp);
  if N > 0 then Result := FS2.Process(@FTmp[0], N, Dst)
  else Result := 0;
  FS2.Flush;
  { what the second stage's last block still gives, after the rest }
  N := FS2.Process(nil, 0, FTmp);
  if N > 0 then
  begin
    if Length(Dst) < (Result + N) * FCh then SetLength(Dst, (Result + N) * FCh);
    Move(FTmp[0], Dst[Result * FCh], N * FCh * SizeOf(Double));
    Inc(Result, N);
  end;
end;

function TAuResampler.Describe: string;

  function One(S: TAuPolyStage): string;
  begin
    if S.UsesFft then Result := Format('FFT %d', [S.FftSize])
    else Result := Format('direct %d', [S.TapsPerPhase]);
  end;

begin
  Result := One(FS1);
  if FS2 <> nil then Result := Result + ' + ' + One(FS2);
end;

procedure TAuResampler.Reset;
begin
  FS1.Reset;
  if FS2 <> nil then FS2.Reset;
end;

function TAuResampler.TapsPerPhase: Integer;
begin
  Result := FS1.TapsPerPhase;
  if FS2 <> nil then Inc(Result, FS2.TapsPerPhase);
end;

{ ---- TAuStreamResampler ---- }

constructor TAuStreamResampler.Create(InRate, OutRate: Cardinal; Channels: Integer; const Config: TSoXConfig);
begin
  inherited Create;
  FCh := Channels;
  FRatio := OutRate / InRate;
  FRes := TAuResampler.Create(InRate, OutRate, Channels, Config);
end;

destructor TAuStreamResampler.Destroy;
begin
  FRes.Free;
  inherited Destroy;
end;

procedure TAuStreamResampler.Reset;
begin
  FRes.Reset;
  FFifoPos := 0;
  FFifoLen := 0;
end;

procedure TAuStreamResampler.Process(InBuf: PDouble; InFrames: Integer; out InDone: Integer;
  OutBuf: PDouble; OutFrames: Integer; out OutDone: Integer);
var
  N, Take, Chunk, Rest: Integer;
begin
  InDone := 0;
  OutDone := 0;
  { first what is waiting from the last call }
  if FFifoLen > 0 then
  begin
    Take := Math.Min(FFifoLen, OutFrames);
    Move(FFifo[FFifoPos * FCh], OutBuf[0], Take * FCh * SizeOf(Double));
    Inc(FFifoPos, Take);
    Dec(FFifoLen, Take);
    Inc(OutDone, Take);
    if FFifoLen = 0 then FFifoPos := 0;
  end;
  { then new input, in pieces of about the input the free output room needs }
  while (OutDone < OutFrames) and (InDone < InFrames) do
  begin
    Chunk := Ceil((OutFrames - OutDone) / FRatio) + 1;
    if Chunk < 16 then Chunk := 16;
    if Chunk > InFrames - InDone then Chunk := InFrames - InDone;
    N := FRes.Process(@InBuf[InDone * FCh], Chunk, FTmp);
    Inc(InDone, Chunk);
    Take := Math.Min(N, OutFrames - OutDone);
    if Take > 0 then
    begin
      Move(FTmp[0], OutBuf[OutDone * FCh], Take * FCh * SizeOf(Double));
      Inc(OutDone, Take);
    end;
    Rest := N - Take;
    if Rest > 0 then
    begin
      { more than fits: kept for the next call }
      if FFifoPos > 0 then
      begin
        if FFifoLen > 0 then Move(FFifo[FFifoPos * FCh], FFifo[0], FFifoLen * FCh * SizeOf(Double));
        FFifoPos := 0;
      end;
      if Length(FFifo) < (FFifoLen + Rest) * FCh then SetLength(FFifo, (FFifoLen + Rest) * FCh * 2);
      Move(FTmp[Take * FCh], FFifo[FFifoLen * FCh], Rest * FCh * SizeOf(Double));
      Inc(FFifoLen, Rest);
    end;
  end;
end;

procedure TAuStreamResampler.Flush;
var
  N: Integer;
begin
  N := FRes.Flush(FTmp);
  if N <= 0 then Exit;
  if FFifoPos > 0 then
  begin
    if FFifoLen > 0 then Move(FFifo[FFifoPos * FCh], FFifo[0], FFifoLen * FCh * SizeOf(Double));
    FFifoPos := 0;
  end;
  if Length(FFifo) < (FFifoLen + N) * FCh then SetLength(FFifo, (FFifoLen + N) * FCh * 2);
  Move(FTmp[0], FFifo[FFifoLen * FCh], N * FCh * SizeOf(Double));
  Inc(FFifoLen, N);
end;

function TAuStreamResampler.Pending: Integer;
begin
  Result := FFifoLen;
end;

initialization
  CacheLock := TCriticalSection.Create;
  Cache := TList.Create;
  SetResampleSimd(rsAuto);           // AVX when the CPU and Windows have it, else SSE2

finalization
  ClearFilterCache;
  Cache.Free;
  CacheLock.Free;

end.
