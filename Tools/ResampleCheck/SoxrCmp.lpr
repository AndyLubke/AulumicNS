program SoxrCmp;

{ ==============================================================================
  AulumicNS tools - SoxrCmp
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AulumicNS' AuResample against libsoxr (the libsoxr DLL, the same settings).
  A check tool, not part of the program.

  Build (from the project folder; nothing is written into src):
    C:\Lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe -MObjFPC -O3 -dRELEASE
      -Fusrc\audio -FU<out>\units -FE<out>
      Tools\ResampleCheck\SoxrCmp.lpr
  and copy libsoxr.dll (64 bit, from the SoX Resampler project; not part of
  this repository) next to the exe.
  Keep <out> out of %TEMP%: security software may quarantine scripts there
  that start it.

  Modes (--mode=):
    all / speed / quality  17 cases: speed (x real time, stereo, 250 ms chunks,
      --core=<n> pins it, 20 = an E-core) and quality (coherent sine tests,
      rectangular window, 2^18 point FFT of the output):
        nd    noise + distortion 20 Hz .. 20 kHz, 1 kHz tone at -1 dBFS (dB re tone)
        spur  up: the largest component above the input Nyquist (images) with a
              tone at 0.9 x input Nyquist; down: the largest output component
              with a tone at 1.1 x output Nyquist (alias), dB re the input tone
        g09   gain at 0.9 x the lower Nyquist (dB), g1k gain at 1 kHz
      --fft=0: our stages in direct form. --only=<part of a case name>.
    stages     each stage of ours alone (x real time) and its form
    fftspeed   TAuFftPlan per size (ns per N log2 N)
    impulse    one full-scale impulse: the peak of ours and of soxr
    train      an impulse train through TAuStreamResampler with Flush
    file       real music: --src=<AudioSim dump of the source (bench
               --resample=0 --dump=)> --au=<AudioSim dump of ours (bench
               --floatpeak=1 --gain=-12 --dump=)> --scale=0.251188643150958
               --inr= --outr= --q= --ph= --bw= --aa=: the lag, the peaks and
               the difference below 19 kHz / to Nyquist / above it
  WavGen.lpr writes the worst-case test signals (WavGen <folder> <rate>).
  =============================================================================}

{$mode objfpc}{$H+}
{$R-}{$Q-}

uses
  Windows, Classes, SysUtils, Math, ALAudioTypes, AuResample;

{$PACKRECORDS C}
type
  soxr_t = Pointer;
  soxr_io_spec_t = record
    itype, otype: Cardinal;
    scale: Double;
    e: Pointer;
    flags: Cardinal;
  end;
  soxr_quality_spec_t = record
    precision, phase_response, passband_end, stopband_begin: Double;
    e: Pointer;
    flags: Cardinal;
  end;
{$PACKRECORDS DEFAULT}
  Tsoxr_create = function(input_rate, output_rate: Double; num_channels: Cardinal;
    error: PPointer; io_spec, q_spec, runtime_spec: Pointer): soxr_t; cdecl;
  Tsoxr_process = function(r: soxr_t; in_buf: Pointer; in_len: SizeUInt; idone: PSizeUInt;
    out_buf: Pointer; out_len: SizeUInt; odone: PSizeUInt): PAnsiChar; cdecl;
  Tsoxr_delete = procedure(r: soxr_t); cdecl;
  Tsoxr_str = function(r: soxr_t): PAnsiChar; cdecl;
  Tsoxr_version = function: PAnsiChar; cdecl;

var
  soxr_create: Tsoxr_create;
  soxr_process: Tsoxr_process;
  soxr_delete: Tsoxr_delete;
  soxr_engine: Tsoxr_str;
  soxr_version: Tsoxr_version;

type
  TCase = record
    Name: string;
    InR, OutR: Cardinal;
    Q, Ph: Integer;        // quality index 0..4, phase setting 0 lin / 1 int / 2 min
    BW, AA: Double;
  end;

  TEngine = (enAu, enSoxr);

  TConv = class
    Eng: TEngine;
    Au: TAuResampler;
    Sx: soxr_t;
    Ratio: Double;
    OutBuf: TDoubleArray;
    constructor Create(AEng: TEngine; const C: TCase);
    destructor Destroy; override;
    { converts Frames stereo frames of Src; appends the output to Dst when Keep }
    function Feed(Src: PDouble; Frames: Integer; var Dst: TDoubleArray; var DstLen: Integer;
      Keep: Boolean): Integer;
  end;

const
  CH = 2;
  NFFT = 1 shl 18;
  EngName: array[TEngine] of string = ('au', 'soxr');

function NowS: Double;
var
  C, F: Int64;
begin
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := C / F;
end;

constructor TConv.Create(AEng: TEngine; const C: TCase);
var
  Cfg: TSoXConfig;
  Io: soxr_io_spec_t;
  Qs: soxr_quality_spec_t;
  Err: Pointer;
begin
  Eng := AEng;
  Ratio := C.OutR / C.InR;
  if Eng = enAu then
  begin
    Cfg := DefaultSoXConfig;
    Cfg.Quality := C.Q;
    Cfg.UpsamplePhase := C.Ph;
    Cfg.DownsamplePhase := C.Ph;
    Cfg.Bandwidth := C.BW;
    Cfg.AntiAlias := C.AA;
    Au := TAuResampler.Create(C.InR, C.OutR, CH, Cfg);
  end
  else
  begin
    { libsoxr with the same settings as ours }
    FillChar(Io, SizeOf(Io), 0);
    Io.itype := 1;      // SOXR_FLOAT64_I
    Io.otype := 1;
    Io.scale := 1.0;
    FillChar(Qs, SizeOf(Qs), 0);
    case C.Q of
      0: Qs.precision := 32;
      1: Qs.precision := 28;
      2: Qs.precision := 24;
      3: Qs.precision := 20;
      else Qs.precision := 16;
    end;
    case C.Ph of
      0: Qs.phase_response := 50;
      2: Qs.phase_response := 0;
      else Qs.phase_response := 25;
    end;
    Qs.passband_end := C.BW / 100;
    Qs.stopband_begin := C.AA / 100;
    Err := nil;
    Sx := soxr_create(C.InR, C.OutR, CH, @Err, @Io, @Qs, nil);
    if Sx = nil then
      raise Exception.Create('soxr_create: ' + string(PAnsiChar(Err)));
  end;
end;

destructor TConv.Destroy;
begin
  Au.Free;
  if Sx <> nil then soxr_delete(Sx);
  inherited Destroy;
end;

function TConv.Feed(Src: PDouble; Frames: Integer; var Dst: TDoubleArray; var DstLen: Integer;
  Keep: Boolean): Integer;
var
  N, Cap: Integer;
  Done, ID, OD: SizeUInt;
  E: PAnsiChar;

  procedure Put(P: PDouble; K: Integer);
  begin
    if not Keep or (K <= 0) then Exit;
    if Length(Dst) < (DstLen + K) * CH then SetLength(Dst, (DstLen + K) * CH * 2);
    Move(P^, Dst[DstLen * CH], K * CH * SizeOf(Double));
    Inc(DstLen, K);
  end;

begin
  Result := 0;
  if Eng = enAu then
  begin
    N := Au.Process(Src, Frames, OutBuf);
    if N > 0 then Put(@OutBuf[0], N);
    Result := N;
    Exit;
  end;
  Cap := Ceil(Frames * Ratio) + 8192;
  if Length(OutBuf) < Cap * CH then SetLength(OutBuf, Cap * CH);
  Done := 0;
  while Done < SizeUInt(Frames) do
  begin
    ID := 0;
    OD := 0;
    E := soxr_process(Sx, Src + Done * CH, SizeUInt(Frames) - Done, @ID, @OutBuf[0], Cap, @OD);
    if E <> nil then raise Exception.Create('soxr_process: ' + string(E));
    Inc(Done, ID);
    if OD > 0 then Put(@OutBuf[0], OD);
    Inc(Result, OD);
    if (ID = 0) and (OD = 0) then Break;
  end;
end;

{ ---- speed ---- }

var
  Noise: TDoubleArray;

procedure MakeNoise(Frames: Integer);
var
  I: Integer;
  S: QWord;
begin
  SetLength(Noise, Frames * CH);
  S := 12345;
  for I := 0 to Frames * CH - 1 do
  begin
    S := S * 6364136223846793005 + 1442695040888963407;
    Noise[I] := ((S shr 11) / 9007199254740992.0 - 0.5);   // -6 dBFS white
  end;
end;

procedure Bench(Eng: TEngine; const C: TCase; Secs: Double; out XRt, CreateMs: Double);
var
  Conv: TConv;
  Frames, Pos, Chunk, Run: Integer;
  T0, T, Best: Double;
  Dummy: TDoubleArray;
  DL: Integer;
begin
  Frames := Round(C.InR * Secs);
  if Length(Noise) < Frames * CH then MakeNoise(Frames);
  Chunk := C.InR div 4;
  Best := 1E30;
  CreateMs := 0;
  Dummy := nil;
  for Run := 1 to 2 do
  begin
    if Eng = enAu then ClearFilterCache;    // time the filter design as on first use
    T0 := NowS;
    Conv := TConv.Create(Eng, C);
    if Run = 1 then CreateMs := (NowS - T0) * 1000;
    try
      DL := 0;
      T0 := NowS;
      Pos := 0;
      while Pos < Frames do
      begin
        Conv.Feed(@Noise[Pos * CH], Min(Chunk, Frames - Pos), Dummy, DL, False);
        Inc(Pos, Chunk);
      end;
      T := NowS - T0;
      if T < Best then Best := T;
    finally
      Conv.Free;
    end;
  end;
  XRt := Secs / Best;
end;

{ ---- quality ---- }

type
  TSpectrum = record
    P: TDoubleArray;     // power per bin 0 .. NFFT / 2
    KF: Integer;         // the tone's bin
    Amp: Double;         // the input tone's amplitude
  end;

function ToneSpectrum(Eng: TEngine; const C: TCase; FWant: Double): TSpectrum;
var
  Conv: TConv;
  K, Skip, NeedOut, InFrames, Pos, Chunk, DL, I: Integer;
  Inp, Outp, Re, Im: TDoubleArray;
  Num, Den: Int64;
  V: Double;
begin
  K := Round(FWant * NFFT / C.OutR);
  Result.KF := K;
  Result.Amp := Power(10, -1 / 20);
  Skip := C.OutR div 2;
  NeedOut := Skip + NFFT + C.OutR div 10;
  InFrames := Ceil(NeedOut * (C.InR / C.OutR)) + C.InR div 2;
  SetLength(Inp, InFrames * CH);
  Den := Int64(NFFT) * C.InR;
  for I := 0 to InFrames - 1 do
  begin
    Num := (Int64(K) * C.OutR * I) mod Den;
    V := Result.Amp * Sin(2 * Pi * (Num / Den));
    Inp[I * 2] := V;
    Inp[I * 2 + 1] := V;
  end;
  Outp := nil;
  DL := 0;
  Conv := TConv.Create(Eng, C);
  try
    Chunk := C.InR div 4;
    Pos := 0;
    while Pos < InFrames do
    begin
      Conv.Feed(@Inp[Pos * CH], Min(Chunk, InFrames - Pos), Outp, DL, True);
      Inc(Pos, Chunk);
    end;
  finally
    Conv.Free;
  end;
  if DL < Skip + NFFT then
    raise Exception.CreateFmt('%s: only %d output frames', [C.Name, DL]);
  SetLength(Re, NFFT);
  SetLength(Im, NFFT);
  for I := 0 to NFFT - 1 do
  begin
    Re[I] := Outp[(Skip + I) * CH];
    Im[I] := 0;
  end;
  FFT(Re, Im, NFFT, False);
  SetLength(Result.P, NFFT div 2 + 1);
  for I := 0 to NFFT div 2 do
    Result.P[I] := Sqr(Re[I]) + Sqr(Im[I]);
end;

function Db(X: Double): Double;
begin
  if X <= 1E-300 then Result := -999 else Result := 10 * Log10(X);
end;

{ tone gain in dB (amplitude at its bin against the input amplitude) }
function GainDb(const S: TSpectrum): Double;
begin
  Result := Db(S.P[S.KF] / Sqr(S.Amp * NFFT / 2));
end;

procedure Quality(Eng: TEngine; const C: TCase; out ND, Spur, G1k, G09: Double);
var
  S: TSpectrum;
  K, KLo, KHi: Integer;
  Sum, Mx, LowNyq: Double;
begin
  LowNyq := Min(C.InR, C.OutR) / 2;
  { 1 kHz: noise + distortion 20 Hz .. 20 kHz }
  S := ToneSpectrum(Eng, C, 1000);
  G1k := GainDb(S);
  KLo := Ceil(20.0 * NFFT / C.OutR);
  KHi := Floor(20000.0 * NFFT / C.OutR);
  Sum := 0;
  for K := KLo to KHi do
    if Abs(K - S.KF) > 2 then Sum := Sum + S.P[K];
  ND := Db(Sum / S.P[S.KF]);
  if C.OutR > C.InR then
  begin
    { 0.9 x input Nyquist: pass band gain, images above the input Nyquist }
    S := ToneSpectrum(Eng, C, 0.9 * LowNyq);
    G09 := GainDb(S);
    Mx := 0;
    for K := Ceil(C.InR / 2 * NFFT / C.OutR) to NFFT div 2 do
      if S.P[K] > Mx then Mx := S.P[K];
    Spur := Db(Mx / S.P[S.KF]);
  end
  else
  begin
    S := ToneSpectrum(Eng, C, 0.9 * LowNyq);
    G09 := GainDb(S);
    { 1.1 x output Nyquist: everything that comes out is alias }
    S := ToneSpectrum(Eng, C, 1.1 * LowNyq);
    Mx := 0;
    for K := 1 to NFFT div 2 do
      if S.P[K] > Mx then Mx := S.P[K];
    Spur := Db(Mx / Sqr(S.Amp * NFFT / 2));
  end;
end;

{ each stage of our converter alone (x real time of the input) }
procedure StageSpeed(const C: TCase; Secs: Double);
var
  Cfg: TSoXConfig;
  R: TAuResampler;
  Frames, Pos, Chunk, N, Mid, MidLen: Integer;
  T0, T1, T2: Double;
  Tmp, MidBuf: TDoubleArray;
begin
  Cfg := DefaultSoXConfig;
  Cfg.Quality := C.Q;
  Cfg.UpsamplePhase := C.Ph;
  Cfg.DownsamplePhase := C.Ph;
  Cfg.Bandwidth := C.BW;
  Cfg.AntiAlias := C.AA;
  Frames := Round(C.InR * Secs);
  if Length(Noise) < Frames * CH then MakeNoise(Frames);
  R := TAuResampler.Create(C.InR, C.OutR, CH, Cfg);
  try
    Chunk := C.InR div 4;
    MidBuf := nil;
    MidLen := 0;
    Tmp := nil;
    T0 := NowS;
    Pos := 0;
    while Pos < Frames do
    begin
      N := R.Stage1.Process(@Noise[Pos * CH], Min(Chunk, Frames - Pos), Tmp);
      if Length(MidBuf) < (MidLen + N) * CH then SetLength(MidBuf, (MidLen + N) * CH * 2);
      if N > 0 then Move(Tmp[0], MidBuf[MidLen * CH], N * CH * 8);
      Inc(MidLen, N);
      Inc(Pos, Chunk);
    end;
    T1 := NowS - T0;
    T2 := 0;
    if R.Stage2 <> nil then
    begin
      Chunk := Integer(R.Stage1.UpFactor * C.InR div R.Stage1.DownFactor) div 4;
      T0 := NowS;
      Mid := 0;
      while Mid < MidLen do
      begin
        R.Stage2.Process(@MidBuf[Mid * CH], Min(Chunk, MidLen - Mid), Tmp);
        Inc(Mid, Chunk);
      end;
      T2 := NowS - T0;
    end;
    WriteLn(Format('%-24s stage 1 %8.1f x  stage 2 %8.1f x  together %8.1f x  (%s)', [C.Name,
      Secs / T1, Secs / Max(T2, 1E-9), Secs / (T1 + T2), R.Describe]));
  finally
    R.Free;
  end;
end;

procedure FftSpeed;
var
  N, LogN, R, Reps, I: Integer;
  Re, Im, Re0, Im0: TDoubleArray;
  Plan: TAuFftPlan;
  T0, T: Double;
begin
  N := 256;
  LogN := 8;
  while N <= 65536 do
  begin
    SetLength(Re, N);
    SetLength(Im, N);
    for I := 0 to N - 1 do
    begin
      Re[I] := Sin(I * 0.1);
      Im[I] := Cos(I * 0.37);
    end;
    Plan := TAuFftPlan.Create(N);
    Reps := Max(20, 20000000 div (N * LogN));
    SetLength(Re0, N);
    SetLength(Im0, N);
    Move(Re[0], Re0[0], N * 8);
    Move(Im[0], Im0[0], N * 8);
    T0 := NowS;
    for R := 1 to Reps do
    begin
      Move(Re0[0], Re[0], N * 8);
      Move(Im0[0], Im[0], N * 8);
      Plan.Forward(@Re[0], @Im[0]);
    end;
    T := (NowS - T0) / Reps;
    WriteLn(Format('N=%6d  %8.1f us  %6.2f ns per N log2 N', [N, T * 1E6, T * 1E9 / (N * LogN)]));
    Plan.Free;
    N := N * 2;
    Inc(LogN);
  end;
end;

{ ---- real music: ours (an AudioSim dump) against soxr on the same input ----
  --mode=file --src=<int32 stereo dump of the source> --au=<int32 dump of our
  output, scaled by --scale> --inr= --outr= --q= --ph= --bw= --aa= }

function ReadInt32Dump(const AName: string; AScale: Double): TDoubleArray;
var
  F: TFileStream;
  Raw: array of LongInt;
  I, N: Integer;
begin
  F := TFileStream.Create(AName, fmOpenRead or fmShareDenyNone);
  try
    N := F.Size div 4;
    SetLength(Raw, N);
    if N > 0 then F.ReadBuffer(Raw[0], N * 4);
  finally
    F.Free;
  end;
  SetLength(Result, N);
  for I := 0 to N - 1 do Result[I] := Raw[I] / 2147483648.0 / AScale;
end;

function OptS(const AName, ADef: string): string;
var
  I: Integer;
begin
  Result := ADef;
  for I := 1 to ParamCount do
    if ParamStr(I).StartsWith('--' + AName + '=') then Result := Copy(ParamStr(I), Length(AName) + 4, MaxInt);
end;

{ where the difference lies: the FFT of (ours - soxr), left channel, over
  2^N samples from 0.1 s on; the energy below 19 kHz, from 19 kHz to the
  lower Nyquist and above it, each in dB against a full-scale sine }
procedure BandSplit(const Au, Sx: TDoubleArray; Lag: Integer; const C: TCase);
var
  N, I, K0, K1, K: Integer;
  Re, Im: TDoubleArray;
  Plan: TAuFftPlan;
  W, E1, E2, E3, Ref: Double;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  N := 1;
  while (N * 2 <= (Length(Au) div CH) - Integer(C.OutR) div 5) and (N < 1 shl 22) do N := N * 2;
  SetLength(Re, N);
  SetLength(Im, N);
  K0 := C.OutR div 10;
  for I := 0 to N - 1 do
  begin
    { a Hann window against leakage }
    W := 0.5 - 0.5 * Cos(2 * Pi * I / N);
    if (K0 + I + Lag >= 0) and ((K0 + I + Lag) * CH < Length(Sx)) then
      Re[I] := (Au[(K0 + I) * CH] - Sx[(K0 + I + Lag) * CH]) * W
    else
      Re[I] := 0;
  end;
  Plan := TAuFftPlan.Create(N);
  try
    Plan.Forward(@Re[0], @Im[0]);
  finally
    Plan.Free;
  end;
  K1 := Round(19000.0 * N / C.OutR);
  K := Round(Min(C.InR, C.OutR) / 2 * N / C.OutR);
  E1 := 0; E2 := 0; E3 := 0;
  for I := 1 to N div 2 do
  begin
    W := Sqr(Re[I]) + Sqr(Im[I]);
    if I < K1 then E1 := E1 + W
    else if I < K then E2 := E2 + W
    else E3 := E3 + W;
  end;
  { a full-scale sine through the same window: (N / 4)^2 x 2 bins x 1.5 (Hann) ... as its total }
  Ref := Sqr(N / 4) * 1.5;
  WriteLn(Format('BANDS below_19k_db=%.1f 19k_to_nyq_db=%.1f above_nyq_db=%.1f (re a full-scale sine)',
    [Db(E1 / Ref), Db(E2 / Ref), Db(E3 / Ref)], FS));
end;

{ --mode=impulse: one full-scale impulse (L +1, R -1) at input frame 2000;
  the largest output, where it is, and the value at the impulse's place }
procedure ImpulseTest;
var
  C: TCase;
  Inp, Outp, Buf: TDoubleArray;
  Eng: TEngine;
  Conv: TConv;
  Frames, DL, I, PkI: Integer;
  Pk, Center: Double;
  OD: SizeUInt;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  C.Name := 'impulse';
  C.InR := StrToInt(OptS('inr', '44100'));
  C.OutR := StrToInt(OptS('outr', '705600'));
  C.Q := StrToInt(OptS('q', '2'));
  C.Ph := StrToInt(OptS('ph', '0'));
  C.BW := StrToFloat(OptS('bw', '91.3'), FS);
  C.AA := StrToFloat(OptS('aa', '100'), FS);
  Frames := 8000;
  SetLength(Inp, Frames * CH);
  Inp[2000 * CH] := 1;
  Inp[2000 * CH + 1] := -1;
  for Eng in TEngine do
  begin
    Outp := nil;
    DL := 0;
    Conv := TConv.Create(Eng, C);
    try
      Conv.Feed(@Inp[0], Frames, Outp, DL, True);
      if Eng = enSoxr then
      begin
        SetLength(Buf, 1 shl 18);
        repeat
          OD := 0;
          soxr_process(Conv.Sx, nil, 0, nil, @Buf[0], Length(Buf) div CH, @OD);
          if OD > 0 then
          begin
            if Length(Outp) < (DL + Integer(OD)) * CH then SetLength(Outp, (DL + Integer(OD)) * CH);
            Move(Buf[0], Outp[DL * CH], OD * CH * 8);
            Inc(DL, OD);
          end;
        until OD = 0;
      end;
    finally
      Conv.Free;
    end;
    Pk := 0;
    PkI := 0;
    for I := 0 to DL - 1 do
      if Abs(Outp[I * CH]) > Pk then
      begin
        Pk := Abs(Outp[I * CH]);
        PkI := I;
      end;
    I := Round(2000.0 * C.OutR / C.InR);
    if I < DL then Center := Outp[I * CH] else Center := 0;
    WriteLn(Format('IMPULSE %-4s peak=%.6f (%.3f dB) at %d (impulse place %d)  value there %.6f',
      [EngName[Eng], Pk, 20 * Log10(Max(Pk, 1E-300)), PkI, I, Center], FS));
  end;
end;

{ --mode=train: the impulse WAV of the test (+1 L / -1 R every 0.1 s, the
  first at 0, 10 s) through TAuStreamResampler in engine-sized pieces with
  Flush, as TResamplerSource does; the peak, where, and its neighbours }
procedure TrainTest;
var
  C: TCase;
  Cfg: TSoXConfig;
  R: TAuStreamResampler;
  Inp, Outp: TDoubleArray;
  Frames, Pos, InDone, OutDone, DL, I, PkI, Chunk: Integer;
  Pk: Double;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  C.InR := StrToInt(OptS('inr', '44100'));
  C.OutR := StrToInt(OptS('outr', '705600'));
  Cfg := DefaultSoXConfig;
  Cfg.Quality := StrToInt(OptS('q', '2'));
  Cfg.UpsamplePhase := StrToInt(OptS('ph', '0'));
  Cfg.DownsamplePhase := Cfg.UpsamplePhase;
  Cfg.Bandwidth := StrToFloat(OptS('bw', '91.3'), FS);
  Cfg.AntiAlias := StrToFloat(OptS('aa', '100'), FS);
  Frames := C.InR * 10;
  SetLength(Inp, Frames * CH);
  for I := 0 to Frames - 1 do
    if I mod (Integer(C.InR) div 10) = 0 then
    begin
      Inp[I * CH] := 8388607 / 8388608;
      Inp[I * CH + 1] := -8388607 / 8388608;
    end;
  SetLength(Outp, (Int64(Frames) * C.OutR div C.InR + 100000) * CH);
  R := TAuStreamResampler.Create(C.InR, C.OutR, CH, Cfg);
  try
    WriteLn('stages: ', R.Resampler.Describe);
    Pos := 0;
    DL := 0;
    Chunk := 8192;
    while Pos < Frames do
    begin
      R.Process(@Inp[Pos * CH], Min(Chunk, Frames - Pos), InDone, @Outp[DL * CH],
        Length(Outp) div CH - DL, OutDone);
      Inc(Pos, InDone);
      Inc(DL, OutDone);
    end;
    R.Flush;
    repeat
      R.Process(nil, 0, InDone, @Outp[DL * CH], Length(Outp) div CH - DL, OutDone);
      Inc(DL, OutDone);
    until OutDone = 0;
  finally
    R.Free;
  end;
  Pk := 0;
  PkI := 0;
  for I := 0 to DL * CH - 1 do
    if Abs(Outp[I]) > Pk then
    begin
      Pk := Abs(Outp[I]);
      PkI := I;
    end;
  WriteLn(Format('TRAIN frames=%d peak=%.6f (%.3f dB) at sample %d = frame %d ch %d (%.6f s)',
    [DL, Pk, 20 * Log10(Max(Pk, 1E-300)), PkI, PkI div CH, PkI mod CH, (PkI div CH) / C.OutR], FS));
  for I := Max(0, PkI div CH - 3) to Min(DL - 1, PkI div CH + 3) do
    WriteLn(Format('  frame %d: %.6f %.6f', [I, Outp[I * CH], Outp[I * CH + 1]], FS));
  { the same without the first 10 ms (the start of the stream) }
  Pk := 0;
  for I := (C.OutR div 100) * CH to DL * CH - 1 do
    if Abs(Outp[I]) > Pk then
    begin
      Pk := Abs(Outp[I]);
      PkI := I;
    end;
  WriteLn(Format('TRAIN after 10 ms: peak=%.6f (%.3f dB) at %.6f s', [Pk, 20 * Log10(Max(Pk, 1E-300)),
    (PkI div CH) / C.OutR], FS));
end;

procedure FileCompare;
var
  C: TCase;
  Src, Au, Sx, Buf: TDoubleArray;
  Conv: TConv;
  Frames, DL, I, K, Best, N0, N1, Cnt, Lag: Integer;
  Err, BestErr, D, MaxD, SumD2, PkA, PkS: Double;
  Done, ID, OD: SizeUInt;
  E: PAnsiChar;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  C.Name := 'file';
  C.InR := StrToInt(OptS('inr', '44100'));
  C.OutR := StrToInt(OptS('outr', '705600'));
  C.Q := StrToInt(OptS('q', '2'));
  C.Ph := StrToInt(OptS('ph', '0'));
  C.BW := StrToFloat(OptS('bw', '91.3'), FS);
  C.AA := StrToFloat(OptS('aa', '100'), FS);
  Src := ReadInt32Dump(OptS('src', ''), 1);
  Au := ReadInt32Dump(OptS('au', ''), StrToFloat(OptS('scale', '0.5'), FS));
  Frames := Length(Src) div CH;
  { soxr: all input at once, then the flush (nil input) }
  Sx := nil;
  DL := 0;
  Conv := TConv.Create(enSoxr, C);
  try
    Conv.Feed(@Src[0], Frames, Sx, DL, True);
    SetLength(Buf, 1 shl 20);
    repeat
      OD := 0;
      E := soxr_process(Conv.Sx, nil, 0, nil, @Buf[0], Length(Buf) div CH, @OD);
      if E <> nil then raise Exception.Create(string(E));
      if OD > 0 then
      begin
        if Length(Sx) < (DL + Integer(OD)) * CH then SetLength(Sx, (DL + Integer(OD)) * CH);
        Move(Buf[0], Sx[DL * CH], OD * CH * 8);
        Inc(DL, OD);
      end;
    until OD = 0;
  finally
    Conv.Free;
  end;
  { the lag of soxr against ours: least squares over one second in the middle }
  N0 := (Length(Au) div CH) div 2;
  N1 := Min(N0 + Integer(C.OutR), Length(Au) div CH);
  Best := 0;
  BestErr := 1E300;
  for K := -400 to 400 do
  begin
    Err := 0;
    for I := N0 to N1 - 1 do
      if (I + K >= 0) and (I + K < DL) then Err := Err + Sqr(Au[I * CH] - Sx[(I + K) * CH]);
    if Err < BestErr then
    begin
      BestErr := Err;
      Best := K;
    end;
  end;
  Lag := Best;
  { the whole overlap without 0.1 s at both ends }
  MaxD := 0;
  SumD2 := 0;
  Cnt := 0;
  PkA := 0;
  PkS := 0;
  for I := C.OutR div 10 to (Length(Au) div CH) - C.OutR div 10 - 1 do
  begin
    if (I + Lag < 0) or (I + Lag >= DL) then Continue;
    for K := 0 to CH - 1 do
    begin
      D := Abs(Au[I * CH + K] - Sx[(I + Lag) * CH + K]);
      if D > MaxD then MaxD := D;
      SumD2 := SumD2 + D * D;
      Inc(Cnt);
      if Abs(Au[I * CH + K]) > PkA then PkA := Abs(Au[I * CH + K]);
      if Abs(Sx[(I + Lag) * CH + K]) > PkS then PkS := Abs(Sx[(I + Lag) * CH + K]);
    end;
  end;
  WriteLn(Format('FILECMP lag=%d compared=%d max_diff_db=%.1f rms_diff_db=%.1f peak_au_db=%.3f peak_soxr_db=%.3f',
    [Lag, Cnt, Db(Sqr(MaxD)), Db(SumD2 / Max(1, Cnt)), Db(Sqr(PkA)), Db(Sqr(PkS))], FS));
  BandSplit(Au, Sx, Lag, C);
end;

{ ---- cases ---- }

function Mk(const AName: string; AIn, AOut: Cardinal; AQ, APh: Integer; ABW: Double = 91.3;
  AAA: Double = 100): TCase;
begin
  Result.Name := AName;
  Result.InR := AIn;
  Result.OutR := AOut;
  Result.Q := AQ;
  Result.Ph := APh;
  Result.BW := ABW;
  Result.AA := AAA;
end;

var
  Cases: array of TCase;
  Lib: HMODULE;
  I: Integer;
  Eng: TEngine;
  X, Cr, ND, Spur, G1k, G09: Double;
  Sx: soxr_t;
  Io: soxr_io_spec_t;
  Only, Mode, Desc: string;
  Secs: Double;
begin
  Mode := 'all';
  Only := '';
  Secs := 10;
  for I := 1 to ParamCount do
  begin
    if ParamStr(I).StartsWith('--core=') then
      SetProcessAffinityMask(GetCurrentProcess, QWord(1) shl StrToInt(Copy(ParamStr(I), 8, 9)));
    if ParamStr(I).StartsWith('--mode=') then Mode := Copy(ParamStr(I), 8, 99);
    if ParamStr(I).StartsWith('--only=') then Only := Copy(ParamStr(I), 8, 99);
    if ParamStr(I).StartsWith('--secs=') then Secs := StrToFloat(Copy(ParamStr(I), 8, 99));
  end;
  Lib := LoadLibraryW(PWideChar(UnicodeString(ExtractFilePath(ParamStr(0)) + 'libsoxr.dll')));
  if Lib = 0 then begin WriteLn('libsoxr.dll not loaded'); Halt(1); end;
  Pointer(soxr_create) := GetProcAddress(Lib, 'soxr_create');
  Pointer(soxr_process) := GetProcAddress(Lib, 'soxr_process');
  Pointer(soxr_delete) := GetProcAddress(Lib, 'soxr_delete');
  Pointer(soxr_engine) := GetProcAddress(Lib, 'soxr_engine');
  Pointer(soxr_version) := GetProcAddress(Lib, 'soxr_version');
  if Assigned(soxr_version) then WriteLn('libsoxr ', soxr_version());
  WriteLn('AuResample inner loop: ', ResampleSimdName);
  if Mode = 'fftspeed' then
  begin
    FftSpeed;
    Exit;
  end;
  if Mode = 'file' then
  begin
    FileCompare;
    Exit;
  end;
  if Mode = 'impulse' then
  begin
    ImpulseTest;
    Exit;
  end;
  if Mode = 'train' then
  begin
    TrainTest;
    Exit;
  end;
  if Pos('--fft=0', CmdLine) > 0 then SetResampleFft(False);

  Cases := [
    Mk('44.1 -> 705.6', 44100, 705600, 2, 1),
    Mk('48 -> 768', 48000, 768000, 2, 1),
    Mk('96 -> 768', 96000, 768000, 2, 1),
    Mk('176.4 -> 705.6', 176400, 705600, 2, 1),
    Mk('192 -> 768', 192000, 768000, 2, 1),
    Mk('352.8 -> 705.6', 352800, 705600, 2, 1),
    Mk('176.4 -> 44.1 down', 176400, 44100, 2, 2),
    Mk('44.1 -> 48', 44100, 48000, 2, 1),
    Mk('44.1 -> 705.6 linear', 44100, 705600, 2, 0),
    Mk('44.1 -> 705.6 16 bit', 44100, 705600, 4, 1),
    Mk('44.1 -> 705.6 q0', 44100, 705600, 0, 1),
    Mk('176.4 -> 705.6 q0', 176400, 705600, 0, 1),
    Mk('44.1 -> 705.6 q0 fast', 44100, 705600, 0, 1, 99),
    Mk('176.4 -> 705.6 q0 fast', 176400, 705600, 0, 1, 99),
    Mk('352.8 -> 705.6 q0 fast', 352800, 705600, 0, 1, 99),
    Mk('192 -> 96 q0 fast', 192000, 96000, 0, 2, 99),
    Mk('705.6 -> 88.2 q0 fast', 705600, 88200, 0, 2, 99)
  ];

  { which engine soxr picks for the first and the steep cases }
  FillChar(Io, SizeOf(Io), 0);
  if Assigned(soxr_engine) then
    for I in [0, 9, 13] do
      with TConv.Create(enSoxr, Cases[I]) do
      try
        WriteLn('soxr engine for ', Cases[I].Name, ': ', soxr_engine(Sx));
      finally
        Free;
      end;
  Sx := nil;

  if Mode = 'stages' then
  begin
    for I := 0 to High(Cases) do
      if (Only = '') or (Pos(Only, Cases[I].Name) > 0) then StageSpeed(Cases[I], Secs);
    Exit;
  end;

  WriteLn;
  WriteLn(Format('%-24s %6s %8s %9s %9s %8s %8s %10s %10s', ['case', 'eng', 'x_rt', 'create_ms',
    'nd_dB', 'spur_dB', 'g1k_dB', 'g09_dB', '']));
  for I := 0 to High(Cases) do
  begin
    if (Only <> '') and (Pos(Only, Cases[I].Name) = 0) then Continue;
    for Eng in TEngine do
    begin
      X := 0; Cr := 0; ND := 0; Spur := 0; G1k := 0; G09 := 0;
      if Mode <> 'quality' then Bench(Eng, Cases[I], Secs, X, Cr);
      if Mode <> 'speed' then Quality(Eng, Cases[I], ND, Spur, G1k, G09);
      if Eng = enAu then
        with TConv.Create(enAu, Cases[I]) do
        try
          Desc := Au.Describe;
        finally
          Free;
        end
      else
        Desc := '';
      WriteLn(Format('%-24s %6s %8.1f %9.1f %9.1f %8.1f %8.5f %10.5f  %s', [Cases[I].Name,
        EngName[Eng], X, Cr, ND, Spur, G1k, G09, Desc]));
      Flush(Output);
    end;
  end;
  FreeLibrary(Lib);
end.
