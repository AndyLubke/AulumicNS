program AudioSim;

{$mode ObjFPC}{$H+}
{$APPTYPE CONSOLE}

{ ==============================================================================
  AudioSim - the audio chain of AulumicNS under the microscope.

  bench <file> [options]   decode + resample as the play thread does
                           (CreateSourceFor, the device's bit depth), one
                           device buffer per call, as fast as possible: the
                           time to build the chain (filter design), the speed
                           (x real time), the time per buffer (mean, max) and
                           reads that came back short before the end
  rt <file> [options]      the real play thread (TPlayThread) against a
                           simulated WASAPI or ASIO device in real time
                           (SimOutputs): glitches / underruns, the least
                           margin, the play thread's time per buffer
                           --out=realasio: the real ASIO driver and DAC
                           (only with SILENT files: see silent)
  silent <folder>          writes silent test files for realasio: FLAC
                           16/44.1, 24/48, 24/96 (60 s) and DSF DSD64 ..
                           DSD512 (20 s, the DSD idle pattern)
  tone <folder>            writes sine test files: WAV 16/44.1, 24/44.1,
                           24/96, 5 kHz at -6 dBFS, 30 s (for sine=5000)
  check <file> [options]   the signal: the chain (as bench) read twice, in
                           WASAPI-sized reads (chunk1, default the buffer)
                           and odd ones (chunk2=1009 frames); both must be
                           identical bit for bit. With sine=HZ the first
                           pass is checked for discontinuities (TSineCheck).
                           rt with sine=HZ checks what the play thread hands
                           to the device the same way.

  Options (--name=value):
    secs=20          bench: audio seconds (0 = the whole file); rt: run time
    resample=1       PCM resampling on
    rate44=352800    target of the 44.1 kHz family; rate48=384000
    q=2              quality 0 (32 bit) .. 4 (16 bit)
    up=1 down=2      phase: 0 linear, 1 intermediate, 2 minimum
    bw=91.3 aa=100   bandwidth / anti-aliasing (% of Nyquist)
    simd=auto        the resampler's inner loop: auto | pascal | sse2 | avx (the output
                     is the same bit for bit; bench prints the one used: simd=)
    dop=1            DSD as DoP (0: DSD to PCM); dsdresample=0; lpf=1 (the 30 kHz DSD low-pass)
    vol=1000         0..1000 (1000 = 100 %, untouched)
    out=wasapi       wasapi | asio | realasio | realwasapi (the real devices: SILENT files only)
    driver=          realasio: a part of the ASIO driver's name or its CLSID ('' = the first)
    device=          realwasapi: a part of the WASAPI device's name (required)
    switchafter=S    rt: after S seconds the output changes to --switchto=OUT (as
                     the program does it during a track: close, then open at once);
                     switchdop=0/1 changes "DSD as DoP" with it
    native=1         realasio: DSD as native DSD when the driver can (0: DoP)
    allowdop=0       realasio: 1 = DoP as PCM allowed (else refused: a DAC that does not
                     decode DoP would play its markers)
    sine=0 sinedb=-6 check / rt: the file is a sine of this frequency and level
    dump=FILE        bench: writes the raw 32-bit output (a reference of this build)
    compare=FILE     bench: compares the output sample by sample with such a dump
    bufms=250        the PCM buffer (DSD: dsdbufms=500)
    period=512       ASIO period (frames); ring=0 (the engine's rule) or a fixed count
                     (realasio: the driver's period; ring>0 = the 3 periods before the fix)
    jitter=0:0       rt: a stall of MS about every EVERY ms (EVERY:MS)
    load=0           rt: busy threads at normal priority
    prefill=1        rt: ASIO starts with about 40 ms (0: one period, as before the fix)
    drain=1          rt: the outputs play out before Close (0: closed at once, as before)
    fade=1           rt, out=asio: the fade-out before a Close in the middle of the music
                     (0: cut, as before); prints END last_sample_dbfs= last_period_peak_dbfs=
    from=0           rt: start at this part of the track (0..1; 0.98 = near the end,
                     to see the end of the stream: cut_last_ms)
  Output: one line "RESULT key=value ..." (parsed by Tools\AudioSim\RunMatrix.ps1).
  ============================================================================}

uses
  Interfaces, Forms, Classes, SysUtils, Windows, Math, uAppLifetime,
  ALAudioTypes, ALSourceFactory, ALReaders, ALAudioThread, ALAudioEngine, ALOutputRing, ALOutputAsio,
  AuDemoLibrary, AuLog, SimOutputs, AuResample, uAppConsts, AuLoudness, ALReaderFLAC, ALReaderWAV,
  uAudioUtils, ALMetadata, uMetaUtils, RegExpr, uToneControl, uReplayGainScan, uReplayGainThread;

function Opt(const AName, ADefault: string): string;
var
  I: Integer;
  P: string;
begin
  Result := ADefault;
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if Pos('--' + AName + '=', P) = 1 then Exit(Copy(P, Length(AName) + 4, MaxInt));
  end;
end;

function OptInt(const AName: string; ADefault: Integer): Integer;
begin
  Result := StrToIntDef(Opt(AName, IntToStr(ADefault)), ADefault);
end;

function OptFloat(const AName: string; ADefault: Double): Double;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := StrToFloatDef(Opt(AName, FloatToStr(ADefault, FS)), ADefault, FS);
end;

function IsDsd(const AFile: string): Boolean;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(AFile));
  Result := (E = '.dsf') or (E = '.dff');
end;

{ the CLSID of the ASIO driver whose name contains ASpec (or that is ASpec);
  '' = the first one; Name = its name }
function FindAsioDriver(const ASpec: string; out AName: string): string;
var
  L: TStringList;
  I, P: Integer;
  N, Id: string;
begin
  Result := '';
  AName := '';
  L := TStringList.Create;
  try
    TAsioOutput.EnumerateDrivers(L);
    for I := 0 to L.Count - 1 do
    begin
      P := Pos('|', L[I]);
      N := Copy(L[I], 1, P - 1);
      Id := Copy(L[I], P + 1, MaxInt);
      if (ASpec = '') or (Pos(LowerCase(ASpec), LowerCase(N)) > 0) or SameText(ASpec, Id) then
      begin
        AName := N;
        Exit(Id);
      end;
    end;
  finally
    L.Free;
  end;
end;

{ the config as TPlaybackManager.PrepareEngineForTrack builds it }
function BuildConfig(const AFile: string): TPlayThreadConfig;
const
  R44: array[0..6] of Integer = (44100, 88200, 176400, 352800, 705600, 1411200, 2822400);
  R48: array[0..6] of Integer = (48000, 96000, 192000, 384000, 768000, 1536000, 3072000);
var
  C: TPlayThreadConfig;
  I, T44, T48: Integer;
begin
  C := Default(TPlayThreadConfig);
  C.FileName := AFile;
  C.UseDoP := OptInt('dop', 1) = 1;
  if Opt('out', 'wasapi') <> 'wasapi' then C.OutputApi := 1 else C.OutputApi := 0;
  C.AsioNativeDsd := OptInt('native', 1) = 1;
  C.ResampleQuality := OptInt('q', VAL_DEF_RESAMPLE_QUAL);
  C.UpsamplePhase := OptInt('up', VAL_DEF_UPSAMPLE_PHASE);
  C.DownsamplePhase := OptInt('down', VAL_DEF_DOWNSAMPLE_PHASE);
  C.ResampleBandWidth := OptFloat('bw', VAL_DEF_BANDWIDTH_FLOAT);
  C.ResampleAntiAlias := OptFloat('aa', VAL_DEF_ANTI_ALIAS_FLOAT);
  { ---> 2026-11-12: the gain stage of the play thread (--floatpeak=1 uses it):
    ReplayGain 0 off / 1 track / 2 album from the file's tags, the preamp }
  C.ReplayGainMode := OptInt('rg', 0);
  C.PreampDB := OptFloat('preamp', 0);
  { ---> 2026-11-12: automatic headroom (rt prints GAIN headroom= clipped= headroom_db=) }
  C.AutoHeadroom := OptInt('headroom', 0) = 1;
  C.RGTrackTags := RG_TAGS_TRACK_GAIN;
  C.RGAlbumTags := RG_TAGS_ALBUM_GAIN;
  C.RGTrackPeakTags := RG_TAGS_TRACK_PEAK;
  C.RGAlbumPeakTags := RG_TAGS_ALBUM_PEAK;
  C.DsdGainDB := OptInt('dsdgain', 6);   // Preferences > DSD: DSD to PCM gain
  C.DsdLowPassFilter := OptInt('lpf', 1) = 1;
  C.UseHighResTimer := True;
  C.OptimizeAffinity := True;
  C.EnableMMCSS := True;
  C.StartVolume := OptInt('vol', 1000);
  C.FToneState.DirectMode := True;
  C.FToneState.BassHz := 150;
  C.FToneState.MidHz := 1000;
  C.FToneState.TrebleHz := 6000;
  C.ToneDirect := True;
  C.ToneBassHz := 150;
  C.ToneMidHz := 1000;
  C.ToneTrebleHz := 6000;
  if IsDsd(AFile) then
  begin
    { as uPlaybackManager.DsdBufferFor: the DSD buffer for DSD sent as DSD,
      the PCM buffer for DSD converted to PCM }
    if C.UseDoP then C.BufferMs := OptInt('dsdbufms', 500)
    else C.BufferMs := OptInt('bufms', 250);
    if C.UseDoP then C.ResamplePCM := False
    else C.ResamplePCM := (OptInt('resample', 1) = 1) and (OptInt('dsdresample', 0) = 1);
  end
  else
  begin
    C.BufferMs := OptInt('bufms', 250);
    C.ResamplePCM := OptInt('resample', 1) = 1;
  end;
  T44 := OptInt('rate44', 352800);
  T48 := OptInt('rate48', 384000);
  SetLength(C.RateMaps, 14);
  for I := 0 to 6 do
  begin
    C.RateMaps[I].InRate := R44[I];
    C.RateMaps[I].OutRate := T44;
    C.RateMaps[7 + I].InRate := R48[I];
    C.RateMaps[7 + I].OutRate := T48;
  end;
  Result := C;
end;

function Ms(AUs: Int64): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FormatFloat('0.000', AUs / 1000, FS);
end;

function Fx(V: Double; const AFmt: string): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FormatFloat(AFmt, V, FS);
end;

{ ---- bench ---- }

procedure SortInt64(var A: array of Int64; L, R: Integer);
var
  I, J: Integer;
  P, T: Int64;
begin
  while L < R do
  begin
    I := L;
    J := R;
    P := A[(L + R) div 2];
    repeat
      while A[I] < P do Inc(I);
      while A[J] > P do Dec(J);
      if I <= J then
      begin
        T := A[I]; A[I] := A[J]; A[J] := T;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if J - L < R - I then
    begin
      SortInt64(A, L, J);
      L := I;
    end
    else
    begin
      SortInt64(A, I, R);
      R := J;
    end;
  end;
end;

type
  { --floatpeak=1: in place of the play thread's float DSP after the
    resampler (TPlayThread.ApplyResamplerFloatDSP, without tone control and
    soft clipping): the peak of the resampler's output, then --gain=<dB> (the
    preamp, volume 100 %), the 32-bit scale and the clamp; Overs counts the
    samples the clamp cut. }
  TFloatProbe = class
    Peak: Double;
    Overs: Int64;
    Gain: Double;     // --gain, and the DSD gain for DSD converted to PCM (as the play thread)
    procedure DSP(Buffer: PDouble; FrameCount, Channels, OutBits: Integer; out OutClipped: Boolean);
    { without a resampler: the gain on the 32-bit samples (TPlayThread.ApplyDSP) }
    procedure IntDSP(P: PLongInt; Count: Integer);
  end;

procedure TFloatProbe.IntDSP(P: PLongInt; Count: Integer);
var
  I: Integer;
  V: Double;
begin
  for I := 0 to Count - 1 do
  begin
    V := P^;
    if Abs(V) / 2147483648.0 > Peak then Peak := Abs(V) / 2147483648.0;
    V := V * Gain;
    if V > 2147483647.0 then
    begin
      V := 2147483647.0;
      Inc(Overs);
    end
    else if V < -2147483648.0 then
    begin
      V := -2147483648.0;
      Inc(Overs);
    end;
    P^ := LongInt(Round(V));
    Inc(P);
  end;
end;

procedure TFloatProbe.DSP(Buffer: PDouble; FrameCount, Channels, OutBits: Integer; out OutClipped: Boolean);
var
  I: Integer;
  V: Double;
  P: PDouble;
begin
  OutClipped := False;
  P := Buffer;
  for I := 0 to FrameCount * Channels - 1 do
  begin
    V := P^;
    if Abs(V) > Peak then Peak := Abs(V);
    V := V * Gain * 2147483647.0;
    if V > 2147483647.0 then
    begin
      V := 2147483647.0;
      Inc(Overs);
      OutClipped := True;
    end
    else if V < -2147483648.0 then
    begin
      V := -2147483648.0;
      Inc(Overs);
      OutClipped := True;
    end;
    P^ := V;
    Inc(P);
  end;
end;

function DbFs(A: Double): string;
begin
  if A <= 0 then Result := '-inf' else Result := Fx(20 * Log10(A), '0.00');
end;

procedure Bench(const AFile: string);
const
  { a 32-bit sample at full scale: the clamp's value, or a 24-bit source at
    its largest value (8388607 shl 8) }
  FS_LEVEL = Int64(2147483392);
var
  Probe: TFloatProbe;
  MaxAbs, FsCount, FsRuns, FsFirst, SampleK: Int64;
  RunLen: array[0..7] of Integer;
  V32, AbsV: Int64;
  ChI: Integer;
  NoResampler: Boolean;
  RgGain, RgPeak: Double;
  Vol: Integer;
  C: TPlayThreadConfig;
  Src: TAudioSource;
  InRate, OutRate, Ch, PeriodFrames, Len, N, Calls, Short, ShortBeforeEnd, SrcBits: Integer;
  T, Dt, CreateUs, SumUs, MaxUs, P99Us: Int64;
  Times: array of Int64;
  Buf: TBytes;
  Frames, Limit: Int64;
  Secs, PeriodUs: Double;
  LastShort: Boolean;
  Hash: QWord;      // FNV-1a over the output: a change that must not alter it shows here
  K: Integer;
  DumpFS, RefFS: TFileStream;
  RefBuf: TBytes;
  RefN: Integer;
  Diffs, MaxDiff, FirstDiff, SampleNo: Int64;
  D: Int64;
begin
  Hash := QWord($CBF29CE484222325);
  DumpFS := nil;
  RefFS := nil;
  RefBuf := nil;
  Diffs := 0;
  MaxDiff := 0;
  FirstDiff := -1;
  SampleNo := 0;
  if Opt('dump', '') <> '' then DumpFS := TFileStream.Create(Opt('dump', ''), fmCreate);
  if Opt('compare', '') <> '' then RefFS := TFileStream.Create(Opt('compare', ''), fmOpenRead or fmShareDenyNone);
  C := BuildConfig(AFile);
  Probe := nil;
  RgGain := 0;
  RgPeak := 0;
  if OptInt('floatpeak', 0) = 1 then
  begin
    Probe := TFloatProbe.Create;
    { ---> 2026-11-12: the gain of the play thread's DSP (ApplyDSP /
      ApplyResamplerFloatDSP): volume (squared curve) x ReplayGain factor
      with the preamp and the peak protection (CalcRGFactor) x the DSD gain
      for DSD converted to PCM (the converter works at 0 dB); --gain adds dB }
    Vol := OptInt('vol', 1000);
    if Vol >= 1000 then Probe.Gain := 1.0
    else if Vol <= 0 then Probe.Gain := 0.0
    else Probe.Gain := Sqr(Vol * 0.001);
    if C.ReplayGainMode > 0 then CalcReplayGainForFile(C, C.DsdGainDB, AFile, RgGain, RgPeak);
    Probe.Gain := Probe.Gain * CalcRGFactor(C, RgGain, RgPeak);
    if IsDsd(AFile) and not C.UseDoP then Probe.Gain := Probe.Gain * Power(10, C.DsdGainDB / 20);
    Probe.Gain := Probe.Gain * Power(10, OptFloat('gain', 0) / 20);
  end;
  MaxAbs := 0;
  FsCount := 0;
  FsRuns := 0;
  FsFirst := -1;
  SampleK := 0;
  FillChar(RunLen, SizeOf(RunLen), 0);
  T := NowUs;
  if Probe <> nil then Src := CreateSourceFor(C, C.DsdGainDB, @Probe.DSP, AFile, InRate, OutRate)
  else Src := CreateSourceFor(C, C.DsdGainDB, nil, AFile, InRate, OutRate);
  { --from=<0..1>: start there (a seek, as the player does) }
  if (Src <> nil) and (OptFloat('from', 0) > 0) then Src.Seek(OptFloat('from', 0));
  CreateUs := NowUs - T;
  if Src = nil then
  begin
    WriteLn('RESULT mode=bench error=unsupported');
    Probe.Free;
    Exit;
  end;
  try
    NoResampler := Src.FindLayer(TResamplerSource) = nil;
    SrcBits := Src.GetBitsPerSample;
    Src.SetTargetBitDepth(32);
    if Src.GetBitsPerSample <> 32 then Src := TBitDepthConverterSource.Create(Src, 32);
    Ch := Src.GetChannels;
    OutRate := Src.GetSampleRate;
    if Opt('out', 'wasapi') = 'asio' then PeriodFrames := OptInt('period', 512)
    else PeriodFrames := Integer(Int64(OutRate) * C.BufferMs div 1000);
    Len := PeriodFrames * Ch * 4;
    SetLength(Buf, Len);
    PeriodUs := PeriodFrames * 1000000.0 / OutRate;
    Secs := OptFloat('secs', 20);
    if Secs > 0 then Limit := Round(Secs * OutRate) else Limit := High(Int64);
    Frames := 0;
    Calls := 0;
    Short := 0;
    ShortBeforeEnd := 0;
    LastShort := False;
    SumUs := 0;
    MaxUs := 0;
    SetLength(Times, 0);
    while Frames < Limit do
    begin
      T := NowUs;
      N := Src.ReadData(@Buf[0], Len);
      Dt := NowUs - T;
      if N <= 0 then Break;
      if Frames + N div (Ch * 4) > Limit then N := Integer(Limit - Frames) * Ch * 4;
      { no resampler (its float DSP): the play thread's ApplyDSP gain }
      if (Probe <> nil) and NoResampler then Probe.IntDSP(PLongInt(@Buf[0]), N div 4);
      {$PUSH}{$Q-}{$R-}
      for K := 0 to N - 1 do Hash := (Hash xor Buf[K]) * QWord($100000001B3);
      {$POP}
      { the level: the peak, samples at full scale, and runs of 3 or more of
        them in a channel (what clipping leaves) }
      for K := 0 to N div 4 - 1 do
      begin
        V32 := PLongInt(@Buf[K * 4])^;
        AbsV := Abs(V32);
        if AbsV > MaxAbs then MaxAbs := AbsV;
        ChI := Integer(SampleK mod Ch) and 7;
        if AbsV >= FS_LEVEL then
        begin
          Inc(FsCount);
          if FsFirst < 0 then FsFirst := SampleK;
          Inc(RunLen[ChI]);
          if RunLen[ChI] = 3 then Inc(FsRuns);
        end
        else
          RunLen[ChI] := 0;
        Inc(SampleK);
      end;
      if DumpFS <> nil then DumpFS.WriteBuffer(Buf[0], N);
      if RefFS <> nil then
      begin
        { the 32-bit samples against the reference (a dump of another build) }
        if Length(RefBuf) < N then SetLength(RefBuf, N);
        RefN := RefFS.Read(RefBuf[0], N);
        for K := 0 to RefN div 4 - 1 do
        begin
          D := Abs(Int64(PLongInt(@Buf[K * 4])^) - PLongInt(@RefBuf[K * 4])^);
          if D <> 0 then
          begin
            Inc(Diffs);
            if D > MaxDiff then MaxDiff := D;
            if FirstDiff < 0 then FirstDiff := SampleNo + K;
          end;
        end;
        Inc(SampleNo, N div 4);
      end;
      if LastShort then Inc(ShortBeforeEnd);   // a short read and still data after it
      LastShort := N < Len;
      if LastShort then Inc(Short);
      Inc(Calls);
      Inc(SumUs, Dt);
      if Dt > MaxUs then MaxUs := Dt;
      if Calls > Length(Times) then SetLength(Times, Calls * 2 + 64);
      Times[Calls - 1] := Dt;
      Inc(Frames, N div (Ch * 4));
    end;
    P99Us := 0;
    if Calls > 0 then
    begin
      SetLength(Times, Calls);
      SortInt64(Times, 0, Calls - 1);
      P99Us := Times[Min(Calls - 1, Trunc(Calls * 0.99))];
    end;
    WriteLn(Format('RESULT mode=bench in=%d bits=%d ch=%d out=%d period_frames=%d period_ms=%s create_ms=%s ' +
      'audio_s=%s cpu_s=%s x_realtime=%s call_avg_ms=%s call_p99_ms=%s call_max_ms=%s max_of_period=%s%% ' +
      'short=%d short_before_end=%d simd=' + ResampleSimdName + ' fft=' + IntToStr(Ord(ResampleFftOn)) +
      ' hash=%s', [InRate, SrcBits, Ch, OutRate, PeriodFrames,
      Ms(Round(PeriodUs)), Ms(CreateUs), Fx(Frames / OutRate, '0.00'), Fx(SumUs / 1E6, '0.000'),
      Fx((Frames / OutRate) / Max(1E-9, SumUs / 1E6), '0.0'), Ms(SumUs div Max(1, Calls)), Ms(P99Us), Ms(MaxUs),
      Fx(100 * MaxUs / PeriodUs, '0.0'), Short, ShortBeforeEnd, IntToHex(Hash, 16)]));
    if RefFS <> nil then
      WriteLn(Format('RESULT2 compared_samples=%d differing=%d max_diff_lsb32=%d first_diff_sample=%d',
        [SampleNo, Diffs, MaxDiff, FirstDiff]));
    { --> 2026-11-12: levels (the user heard distortion in loud passages) }
    if FsFirst >= 0 then
      WriteLn(Format('LEVEL peak_dbfs=%s fullscale=%d fullscale_runs=%d first_fullscale_s=%s',
        [DbFs(MaxAbs / 2147483648.0), FsCount, FsRuns, Fx(FsFirst / Ch / OutRate, '0.00')]))
    else
      WriteLn(Format('LEVEL peak_dbfs=%s fullscale=0 fullscale_runs=0',
        [DbFs(MaxAbs / 2147483648.0)]));
    if Probe <> nil then
      WriteLn(Format('FLOAT resampler_peak_dbfs=%s gain_db=%s out_peak_dbfs=%s clipped_after_gain=%d ' +
        'rg_gain_db=%s rg_peak=%s',
        [DbFs(Probe.Peak), DbFs(Probe.Gain), DbFs(Probe.Peak * Probe.Gain), Probe.Overs,
         Fx(RgGain, '0.00'), Fx(RgPeak, '0.000000')]));
  finally
    DumpFS.Free;
    RefFS.Free;
    Src.Free;
    Probe.Free;
  end;
end;

{ ---- rgcheck (2026-11-12) ----
  The stored ReplayGain tags of an album against a fresh measurement, read
  only. As TReplayGainThread.ScanFile and its album step: the same readers
  (FLAC, WAV, DSD converted at 0 dB), TAuLoudnessMeter per track, the album
  loudness over the blocks of all tracks together, gain = -18 LUFS - loudness
  (silence: 0 dB), the sample peak. The tags through CalcReplayGainForFile
  (track and album mode, no DSD gain taken off). One line per track and one
  for the album; the folder is the album (with its sub folders). }

{ --ebur128=<libebur128.dll>: the same samples also through libebur128 (as
  Aulumic used it: mode I + M + sample peak, float frames), for comparison }
type
  TEbInit = function(Channels, Rate: Cardinal; Mode: Integer): Pointer; cdecl;
  TEbDestroy = procedure(var St: Pointer); cdecl;
  TEbAddFloat = function(St: Pointer; Src: PSingle; Frames: SizeUInt): Integer; cdecl;
  TEbGlobal = function(St: Pointer; OutVal: PDouble): Integer; cdecl;
  TEbGlobalMulti = function(Sts: PPointer; Size: SizeUInt; OutVal: PDouble): Integer; cdecl;

var
  EbLib: HMODULE = 0;
  EbInit: TEbInit;
  EbDestroy: TEbDestroy;
  EbAddFloat: TEbAddFloat;
  EbGlobal: TEbGlobal;
  EbGlobalMulti: TEbGlobalMulti;
  EbState: Pointer;            // the state of the file MeasureFile just measured

function LoadEbur(const ADll: string): Boolean;
begin
  EbLib := LoadLibraryW(PWideChar(UnicodeString(ADll)));
  Result := EbLib <> 0;
  if not Result then Exit;
  Pointer(EbInit) := GetProcAddress(EbLib, 'ebur128_init');
  Pointer(EbDestroy) := GetProcAddress(EbLib, 'ebur128_destroy');
  Pointer(EbAddFloat) := GetProcAddress(EbLib, 'ebur128_add_frames_float');
  Pointer(EbGlobal) := GetProcAddress(EbLib, 'ebur128_loudness_global');
  Pointer(EbGlobalMulti) := GetProcAddress(EbLib, 'ebur128_loudness_global_multiple');
  Result := Assigned(EbInit) and Assigned(EbDestroy) and Assigned(EbAddFloat) and
    Assigned(EbGlobal) and Assigned(EbGlobalMulti);
end;

function RgGainFromLoudness(L: Double): Double;
begin
  if (not IsNan(L)) and (not IsInfinite(L)) and (L > -70.0) then
    Result := EnsureRange(-18.0 - L, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB)
  else
    Result := 0.0;
end;

function MeasureFile(const AFile: string; out ABlocks: TLoudnessBlocks; out ALufs, APeak: Double): Boolean;
var
  Flac: TFlacReader;
  Wav: TWavReader;
  Dsd: TDsdToPcmSource;
  Meter: TAuLoudnessMeter;
  Ch, Rate, Bits, FrameSize, N, Frames, I, S32: Integer;
  Raw: TBytes;
  Flt: array of Single;
  P8: PByte;
begin
  Result := False;
  Flac := nil;
  Wav := nil;
  Dsd := nil;
  Meter := nil;
  ABlocks := nil;
  ALufs := 0;
  APeak := 0;
  try
    if IsFlacFile(AFile) then
    begin
      Flac := TFlacReader.Create(AFile);
      Ch := Flac.Channels; Rate := Flac.SampleRate; Bits := Flac.BitsPerSample;
    end
    else if IsWavFile(AFile) then
    begin
      Wav := TWavReader.Create(AFile);
      Ch := Wav.Channels; Rate := Wav.SampleRate; Bits := Wav.BitsPerSample;
    end
    else if IsDsd(AFile) then
    begin
      Dsd := TDsdToPcmSource.Create(AFile, 0, True);
      Ch := Dsd.GetChannels; Rate := Dsd.GetSampleRate; Bits := Dsd.GetBitsPerSample;
    end
    else
      Exit;
    if (Ch <= 0) or (Ch > 8) or not (Bits in [16, 24, 32]) then Exit;
    FrameSize := Ch * (Bits div 8);
    Meter := TAuLoudnessMeter.Create(Rate, Ch);
    EbState := nil;
    if EbLib <> 0 then EbState := EbInit(Ch, Rate, (1 shl 2) or 1 or (1 shl 4));
    SetLength(Raw, 8192 * FrameSize);
    SetLength(Flt, 8192 * Ch);
    repeat
      if Flac <> nil then N := Flac.ReadData(@Raw[0], Length(Raw))
      else if Wav <> nil then N := Wav.ReadData(@Raw[0], Length(Raw))
      else N := Dsd.ReadData(@Raw[0], Length(Raw));
      if N < FrameSize then Break;
      Frames := N div FrameSize;
      P8 := @Raw[0];
      for I := 0 to Frames * Ch - 1 do
      begin
        case Bits of
          16: begin Flt[I] := PSmallInt(P8)^ / 32768.0; Inc(P8, 2); end;
          24: begin
                S32 := P8[0] or (P8[1] shl 8) or (ShortInt(P8[2]) shl 16);
                Flt[I] := S32 / 8388608.0;
                Inc(P8, 3);
              end;
        else
          begin Flt[I] := PLongInt(P8)^ / 2147483648.0; Inc(P8, 4); end;
        end;
      end;
      Meter.AddSingle(@Flt[0], Frames);
      if EbState <> nil then EbAddFloat(EbState, @Flt[0], Frames);
    until False;
    ABlocks := Meter.Blocks;
    ALufs := Meter.Loudness;
    APeak := Meter.Peak;
    Result := Meter.Frames > 0;
  finally
    Meter.Free;
    Flac.Free;
    Wav.Free;
    Dsd.Free;
  end;
end;

procedure RgCheck(const AFolder: string);
var
  Files: TStringList;
  C: TPlayThreadConfig;
  Sets: TLoudnessBlockSets;
  I, N: Integer;
  Lufs, Peak, TagG, TagP, AlbTagG, AlbTagP, MeasG, AlbPeak, AlbLufs, Worst, EbL: Double;
  Blocks: TLoudnessBlocks;
  EbStates: array of Pointer;
  EbText: string;

  procedure Collect(const ADir: string);
  var
    SR: TSearchRec;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then Collect(IncludeTrailingPathDelimiter(ADir) + SR.Name)
        else if IsFlacFile(SR.Name) or IsWavFile(SR.Name) or IsDsd(SR.Name) then
          Files.Add(IncludeTrailingPathDelimiter(ADir) + SR.Name);
      until FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
  end;

begin
  Files := TStringList.Create;
  try
    Collect(AFolder);
    Files.Sort;
    if (Opt('ebur128', '') <> '') and (EbLib = 0) and not LoadEbur(Opt('ebur128', '')) then
      WriteLn('ebur128: not loaded');
    SetLength(EbStates, Files.Count);
    C := Default(TPlayThreadConfig);
    C.RGTrackTags := RG_TAGS_TRACK_GAIN;
    C.RGAlbumTags := RG_TAGS_ALBUM_GAIN;
    C.RGTrackPeakTags := RG_TAGS_TRACK_PEAK;
    C.RGAlbumPeakTags := RG_TAGS_ALBUM_PEAK;
    SetLength(Sets, Files.Count);
    N := 0;
    AlbPeak := 0;
    AlbTagG := NaN;
    AlbTagP := NaN;
    Worst := 0;
    for I := 0 to Files.Count - 1 do
    begin
      EbState := nil;
      if not MeasureFile(Files[I], Blocks, Lufs, Peak) then
      begin
        if EbState <> nil then EbDestroy(EbState);
        WriteLn('TRACK error=decode file=', ExtractFileName(Files[I]));
        Continue;
      end;
      Sets[N] := Blocks;
      EbStates[N] := EbState;
      EbText := '';
      if EbState <> nil then
      begin
        EbL := 0;
        EbGlobal(EbState, @EbL);
        EbText := ' ebur128_lufs=' + Fx(EbL, '0.00');
      end;
      Inc(N);
      if Peak > AlbPeak then AlbPeak := Peak;
      C.ReplayGainMode := 1;
      CalcReplayGainForFile(C, 0, Files[I], TagG, TagP);
      C.ReplayGainMode := 2;
      if IsNan(AlbTagG) then
      begin
        CalcReplayGainForFile(C, 0, Files[I], AlbTagG, AlbTagP);
      end;
      MeasG := RgGainFromLoudness(Lufs);
      if Abs(MeasG - TagG) > Worst then Worst := Abs(MeasG - TagG);
      WriteLn(Format('TRACK lufs=%s gain=%s tag_gain=%s diff=%s peak=%s tag_peak=%s%s file=%s',
        [Fx(Lufs, '0.00'), Fx(MeasG, '0.00'), Fx(TagG, '0.00'), Fx(MeasG - TagG, '0.00'),
         Fx(Peak, '0.000000'), Fx(TagP, '0.000000'), EbText, ExtractFileName(Files[I])]));
    end;
    SetLength(Sets, N);
    AlbLufs := IntegratedLoudness(Sets);
    MeasG := RgGainFromLoudness(AlbLufs);
    EbText := '';
    if (N > 0) and (EbStates[0] <> nil) then
    begin
      EbL := 0;
      EbGlobalMulti(@EbStates[0], N, @EbL);
      EbText := ' ebur128_lufs=' + Fx(EbL, '0.00') + ' ebur128_gain=' + Fx(RgGainFromLoudness(EbL), '0.00');
    end;
    WriteLn(Format('ALBUM tracks=%d lufs=%s gain=%s tag_gain=%s diff=%s peak=%s tag_peak=%s worst_track_diff=%s%s',
      [N, Fx(AlbLufs, '0.00'), Fx(MeasG, '0.00'), Fx(AlbTagG, '0.00'), Fx(MeasG - AlbTagG, '0.00'),
       Fx(AlbPeak, '0.000000'), Fx(AlbTagP, '0.000000'), Fx(Worst, '0.00'), EbText]));
  finally
    for I := 0 to High(EbStates) do
      if EbStates[I] <> nil then EbDestroy(EbStates[I]);
    Files.Free;
  end;
end;

{ rgtags <file> (read only): the ReplayGain / R128 fields as stored (their
  exact text shows which program wrote them), the names of all fields, and
  fields that may name a program (encoder, tool, software, comment) }
procedure RgTags(const AFile: string);
var
  Md: TAudioMetadata;
  L: TStringList;
  I: Integer;
  S, U, Keys: string;
begin
  Md := ReadTrackMetadata(AFile, False, True);
  L := TStringList.Create;
  try
    L.Text := Md.AllTagsDisplay;
    Keys := '';
    for I := 0 to L.Count - 1 do
    begin
      S := L[I];
      U := UpperCase(S);
      if (Pos('REPLAYGAIN', U) > 0) or (Pos('R128', U) > 0) or (Pos('ENCOD', U) > 0) or
         (Pos('TOOL', U) > 0) or (Pos('SOFTWARE', U) > 0) or (Pos('VENDOR', U) > 0) or
         (Pos('AUDIRVANA', U) > 0) or (Pos('FOOBAR', U) > 0) or (Pos('AULUMIC', U) > 0) then
        WriteLn('TAG ', S);
      if Pos('=', S) > 0 then Keys := Keys + Copy(S, 1, Pos('=', S) - 1) + ','
      else if Pos(':', S) > 0 then Keys := Keys + Copy(S, 1, Pos(':', S) - 1) + ',';
    end;
    WriteLn('KEYS ', Keys);
  finally
    L.Free;
  end;
end;

{ rgscreen <root> --out=<csv> (read only, tags only): every album of a library
  - files grouped by folder (CD / Disc sub folders into their parent) and
  album tag - checked from its ReplayGain tags: the same album gain in all
  tracks, the album gain within the range of the track gains, the album peak
  = the highest track peak, missing values; and the album gain estimated
  from the track gains (the duration-weighted mean of the track loudness,
  -18 LUFS - gain): far from the stored one = worth measuring (rgcheck). }

type
  TRgAlbum = class
    Folder, Album: string;
    Tracks, WithTG, MissingAG, MissingTP: Integer;
    DurSum, Energy, MinTG, MaxTG, MaxTP: Double;
    AG, AP: Double;
    HaveAG, HaveAP, AGDiffers, APDiffers: Boolean;
  end;

function FxN(V: Double; Have: Boolean; const AFmt: string): string;
begin
  if Have then Result := Fx(V, AFmt) else Result := '';
end;

function DurationSecs(const S: string): Double;
var
  P: Integer;
begin
  P := Pos(':', S);
  if P = 0 then Exit(0);
  Result := StrToIntDef(Copy(S, 1, P - 1), 0) * 60.0 + StrToIntDef(Copy(S, P + 1, 9), 0);
end;

var
  RgBadValues: Integer = 0;   // rgscreen: values that were there but no number

function HasTag(const AllTags, Keys: string): Boolean; forward;

{ a ReplayGain value of the tags: False when missing or not a number }
function RgValue(const AllTags, Keys: string; out V: Double): Boolean;
begin
  Result := False;
  V := 0;
  if not HasTag(AllTags, Keys) then Exit;
  V := ExtractReplayGain(AllTags, Keys);
  if IsNan(V) or IsInfinite(V) then
  begin
    Inc(RgBadValues);
    V := 0;
    Exit;
  end;
  Result := True;
end;

function HasTag(const AllTags, Keys: string): Boolean;
var
  L: TStringList;
  I: Integer;
  U: string;
begin
  Result := False;
  U := UpperCase(AllTags);
  L := TStringList.Create;
  try
    L.Delimiter := ';';
    L.StrictDelimiter := True;
    L.DelimitedText := Keys;
    for I := 0 to L.Count - 1 do
      if (Trim(L[I]) <> '') and (Pos(UpperCase(Trim(L[I])), U) > 0) then Exit(True);
  finally
    L.Free;
  end;
end;

procedure RgScreen(const ARoot: string);
var
  Groups: TStringList;
  Out: TStringList;
  Files: Integer;

  procedure AddFile(const AFile: string);
  var
    Md: TAudioMetadata;
    Dir, Key: string;
    G: TRgAlbum;
    Idx: Integer;
    TG, TP, AG, AP, D: Double;
  begin
    Md := ReadTrackMetadata(AFile, False);
    Inc(Files);
    Dir := ExtractFileDir(AFile);
    if ExecRegExpr('^(CD|DIS[CK])[ _.-]*\d+', UpperCase(ExtractFileName(Dir))) then Dir := ExtractFileDir(Dir);
    Key := Dir + '|' + UpperCase(Md.Album);
    Idx := Groups.IndexOf(Key);
    if Idx < 0 then
    begin
      G := TRgAlbum.Create;
      G.Folder := Dir;
      G.Album := Md.Album;
      G.MinTG := 1E9;
      G.MaxTG := -1E9;
      Groups.AddObject(Key, G);
    end
    else
      G := TRgAlbum(Groups.Objects[Idx]);
    Inc(G.Tracks);
    D := DurationSecs(Md.DurationStr);
    if RgValue(Md.AllTags, RG_TAGS_TRACK_GAIN, TG) then
    begin
      Inc(G.WithTG);
      if TG < G.MinTG then G.MinTG := TG;
      if TG > G.MaxTG then G.MaxTG := TG;
      if D > 0 then
      begin
        G.DurSum := G.DurSum + D;
        G.Energy := G.Energy + D * Power(10, (-18.0 - TG) / 10);
      end;
    end;
    if RgValue(Md.AllTags, RG_TAGS_TRACK_PEAK, TP) then
    begin
      if TP > G.MaxTP then G.MaxTP := TP;
    end
    else
      Inc(G.MissingTP);
    if RgValue(Md.AllTags, RG_TAGS_ALBUM_GAIN, AG) then
    begin
      if not G.HaveAG then
      begin
        G.AG := AG;
        G.HaveAG := True;
      end
      else if Abs(AG - G.AG) > 0.005 then
        G.AGDiffers := True;
    end
    else
      Inc(G.MissingAG);
    if RgValue(Md.AllTags, RG_TAGS_ALBUM_PEAK, AP) then
    begin
      if not G.HaveAP then
      begin
        G.AP := AP;
        G.HaveAP := True;
      end
      else if Abs(AP - G.AP) > 0.000005 then
        G.APDiffers := True;
    end;
  end;

  procedure Walk(const ADir: string);
  var
    SR: TSearchRec;
    Subs, Audio: TStringList;
    I: Integer;
  begin
    Subs := TStringList.Create;
    Audio := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if (SR.Attr and faDirectory) <> 0 then Subs.Add(IncludeTrailingPathDelimiter(ADir) + SR.Name)
          else if IsFlacFile(SR.Name) or IsWavFile(SR.Name) or IsDsd(SR.Name) then
            Audio.Add(IncludeTrailingPathDelimiter(ADir) + SR.Name);
        until FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
      Audio.Sort;
      for I := 0 to Audio.Count - 1 do AddFile(Audio[I]);
      Subs.Sort;
      for I := 0 to Subs.Count - 1 do Walk(Subs[I]);
    finally
      Subs.Free;
      Audio.Free;
    end;
  end;

  function Q(const S: string): string;
  begin
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"';
  end;

var
  I: Integer;
  G: TRgAlbum;
  Est, Diff: Double;
  Flags: string;
begin
  Groups := TStringList.Create;
  Groups.Sorted := True;
  Groups.Duplicates := dupIgnore;
  Out := TStringList.Create;
  Files := 0;
  try
    Walk(ARoot);
    Out.Add('folder,album,tracks,with_track_gain,missing_album_gain,album_gain,est_album_gain,diff,' +
      'min_track_gain,max_track_gain,album_peak,max_track_peak,flags');
    for I := 0 to Groups.Count - 1 do
    begin
      G := TRgAlbum(Groups.Objects[I]);
      Flags := '';
      Est := NaN;
      Diff := NaN;
      if (G.DurSum > 0) and (G.Energy > 0) then
        Est := -18.0 - 10 * Log10(G.Energy / G.DurSum);
      if G.WithTG = 0 then Flags := Flags + 'no_rg '
      else if G.WithTG < G.Tracks then Flags := Flags + 'some_tracks_without_rg ';
      if (G.WithTG > 0) and (G.MissingAG > 0) then Flags := Flags + 'album_gain_missing ';
      if G.AGDiffers then Flags := Flags + 'album_gain_differs_between_tracks ';
      if G.APDiffers then Flags := Flags + 'album_peak_differs_between_tracks ';
      if G.HaveAG and (G.WithTG > 0) and ((G.AG < G.MinTG - 0.05) or (G.AG > G.MaxTG + 0.05)) then
        Flags := Flags + 'album_gain_outside_track_range ';
      if G.HaveAP and (G.MaxTP > 0) and (Abs(G.AP - G.MaxTP) > 0.0005) then
        Flags := Flags + 'album_peak_not_max_track_peak ';
      if G.HaveAG and not IsNan(Est) then Diff := G.AG - Est;
      Out.Add(Q(G.Folder) + ',' + Q(G.Album) + Format(',%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,',
        [G.Tracks, G.WithTG, G.MissingAG, FxN(G.AG, G.HaveAG, '0.00'), FxN(Est, not IsNan(Est), '0.00'),
         FxN(Diff, not IsNan(Diff), '0.00'), FxN(G.MinTG, G.WithTG > 0, '0.00'),
         FxN(G.MaxTG, G.WithTG > 0, '0.00'), FxN(G.AP, G.HaveAP, '0.000000'),
         FxN(G.MaxTP, G.MaxTP > 0, '0.000000')]) + Q(Trim(Flags)));
    end;
    Out.SaveToFile(Opt('out', 'rgscreen.csv'));
    WriteLn(Format('RGSCREEN files=%d albums=%d values_not_numbers=%d out=%s',
      [Files, Groups.Count, RgBadValues, Opt('out', 'rgscreen.csv')]));
  finally
    for I := 0 to Groups.Count - 1 do Groups.Objects[I].Free;
    Groups.Free;
    Out.Free;
  end;
end;

{ ---- rt ---- }

type
  TBusyThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TBusyThread.Execute;
var
  X: Double;
begin
  X := 1;
  while not Terminated do X := Sin(X) + 1.0001;
  if X = 12345 then WriteLn;
end;

const
  HWND_MESSAGE = HWND(-3);   // the parent of a message-only window (not in FPC's Windows unit)

{ the engine's log messages (WM_AUDIO_ENGINE_LOG) of a message-only window,
  formatted by the program's log (TAppLog) }
procedure PumpLog(ALog: TAppLog);
var
  M: TMsg;
begin
  while PeekMessage(M, 0, 0, 0, PM_REMOVE) do
    if M.message = WM_AUDIO_ENGINE_LOG then ALog.EngineMessage(M.wParam, M.lParam)
    else DispatchMessage(M);
end;

{ the WASAPI endpoint whose name contains ASpec (no default: realwasapi must
  name the device, so nothing plays on another one by mistake) }
function FindWasapiDevice(const ASpec: string; out AName: string): string;
var
  L: TStringList;
  I, P, DefIdx: Integer;
begin
  Result := '';
  AName := '';
  if ASpec = '' then Exit;
  L := TStringList.Create;
  try
    TAudioEngine.EnumerateDevices(L, DefIdx);
    for I := 0 to L.Count - 1 do
    begin
      P := Pos('|', L[I]);
      if (P > 0) and (Pos(LowerCase(ASpec), LowerCase(Copy(L[I], 1, P - 1))) > 0) then
      begin
        AName := Copy(L[I], 1, P - 1);
        Exit(Copy(L[I], P + 1, MaxInt));
      end;
    end;
  finally
    L.Free;
  end;
end;

var
  { the real devices, looked up once before the first phase (the program
    keeps the id too: after a switch the endpoint may not be listed yet) }
  GAsioId, GAsioName, GWasapiId, GWasapiName: string;

procedure ResolveDevices;
begin
  GAsioId := FindAsioDriver(Opt('driver', ''), GAsioName);
  GWasapiId := FindWasapiDevice(Opt('device', ''), GWasapiName);
end;

{ the output AOut for the recorder and the config; False: no such device }
function ConfigureOutput(const AOut: string; var C: TPlayThreadConfig; Rec: TSimRecorder;
  out AName: string): Boolean;
begin
  Result := True;
  AName := '';
  if AOut = 'realasio' then
  begin
    Rec.Settings.Kind := skRealAsio;
    C.OutputApi := 1;
    C.DeviceId := GAsioId;
    AName := GAsioName;
    Result := C.DeviceId <> '';
  end
  else if AOut = 'realwasapi' then
  begin
    Rec.Settings.Kind := skRealWasapi;
    C.OutputApi := 0;
    C.DeviceId := GWasapiId;
    AName := GWasapiName;
    Result := C.DeviceId <> '';
  end
  else if AOut = 'asio' then Rec.Settings.Kind := skAsio
  else Rec.Settings.Kind := skWasapi;
end;

{ one TPlayThread for ASecs (or to the end of the file), the log pumped }
procedure RunPhase(const C: TPlayThreadConfig; Rec: TSimRecorder; ALog: TAppLog; ASecs, AFrom: Double;
  out AEnded: Boolean; out AError: string; out ARunUs: Int64);
var
  Th: TPlayThread;
  TH_: THandle;
  Deadline: QWord;
  T0: Int64;
  Info: TSignalInfo;
  HeadDb: Double;
begin
  Th := TPlayThread.Create(C);
  try
    Th.OutputFactory := @Rec.CreateOutput;
    if AFrom > 0 then Th.Seek(AFrom);
    T0 := NowUs;
    Th.Start;
    TH_ := Th.Handle;
    Deadline := GetTickCount64 + QWord(Round(ASecs * 1000));
    AEnded := False;
    HeadDb := 0;
    repeat
      if MsgWaitForMultipleObjects(1, TH_, False, 50, QS_ALLINPUT) = WAIT_OBJECT_0 then
      begin
        AEnded := True;
        Break;
      end;
      PumpLog(ALog);
      { ---> 2026-11-12: what the automatic headroom takes off (the lowest seen) }
      Info := Th.GetSignalInfo;
      if Info.HeadroomDB < HeadDb then HeadDb := Info.HeadroomDB;
    until GetTickCount64 >= Deadline;
    Th.StopAndWait(5000);
    PumpLog(ALog);
    ARunUs := NowUs - T0;
    AError := Th.ErrorMessage;
    WriteLn(Format('GAIN headroom=%d clipped=%d headroom_db=%s',
      [Ord(C.AutoHeadroom), Ord(Th.WasClipped), Fx(HeadDb, '0.00')]));
  finally
    Th.Free;
  end;
  PumpLog(ALog);
end;

procedure PrintPhase(const APhase, AOut, AName: string; Rec: TSimRecorder; ARunUs: Int64;
  AEnded: Boolean; const AError: string);
var
  St: TSimStats;
begin
  St := Rec.Stats;
  if St.MinMarginUs = High(Int64) then St.MinMarginUs := -1;
  WriteLn(Format('RESULT mode=rt phase=%s out=%s rate=%d period_frames=%d ring=%d run_s=%s ended=%d buffers=%d ' +
    'glitches=%d stalls=%d min_margin_ms=%s min_margin_at=%d/%d fill_avg_ms=%s fill_max_ms=%s opens=%d ' +
    'cut_last_ms=%s cut_max_ms=%s native_dsd=%d valid=%d open_attempts=%d open_failures=%d open_errors=%s ' +
    'buffer_ms=%d driver=%s error=%s',
    [APhase, AOut, St.Rate, St.PeriodFrames, St.RingPeriods, Fx(ARunUs / 1E6, '0.0'),
     Ord(AEnded), St.Buffers, St.Glitches, St.Stalls, Ms(St.MinMarginUs), St.MinMarginAt,
     Max(St.Taken, St.Buffers),
     Ms(St.FillSumUs div Max(1, St.FillCount)), Ms(St.FillMaxUs), St.Opens, Ms(St.CutLastUs),
     Ms(St.CutMaxUs), Ord(St.NativeDsd), St.ValidBits, St.OpenAttempts, St.OpenFailures, St.OpenErrors,
     St.BufferMsTaken, StringReplace(AName, ' ', '_', [rfReplaceAll]),
     StringReplace(AError, ' ', '_', [rfReplaceAll])]));
  { the last period the simulated ASIO device got before Close }
  if Rec.EndSeen then
    WriteLn(Format('END last_sample_dbfs=%s last_period_peak_dbfs=%s',
      [Fx(20 * Log10(Max(1, Rec.EndLast) / 2147483648.0), '0.0'), Fx(20 * Log10(Max(1, Rec.EndPeak) / 2147483648.0), '0.0')]));
  if Rec.Sine <> nil then
    WriteLn(Format('RESULT2 sine_max_rel=%s sine_outliers=%d sine_spikes_s=%s',
      [Fx(Rec.Sine.MaxRel, '0.000000'), Rec.Sine.Outliers, Rec.Sine.Spikes]));
end;

{ waitdevice --device=NAME [--secs=30]: polls the WASAPI endpoints every
  100 ms and prints when the device is listed (active) and when not }
procedure WaitDevice;
var
  T0, Last: QWord;
  Found, WasFound: Integer;
  Name: string;
begin
  T0 := GetTickCount64;
  WasFound := -1;
  repeat
    if FindWasapiDevice(Opt('device', ''), Name) <> '' then Found := 1 else Found := 0;
    if Found <> WasFound then
    begin
      WriteLn(Format('DEVICE t=%dms listed=%d %s', [GetTickCount64 - T0, Found, Name]));
      WasFound := Found;
    end;
    Last := GetTickCount64;
    Sleep(100);
  until Last - T0 >= QWord(Round(OptFloat('secs', 30) * 1000));
end;

{ rt: one phase, or with --switchafter=S --switchto=OUT two, as the program
  switches the output during a track (TPlaybackManager.RestartCurrent: the
  old stream closes, the new one opens at once) }
procedure RealTime(const AFile: string);
var
  C: TPlayThreadConfig;
  Rec: TSimRecorder;
  Busy: array of TBusyThread;
  I, J: Integer;
  Secs, SwitchAfter: Double;
  J1, DevName: string;
  RunUs: Int64;
  Ended: Boolean;
  Err: string;
  LogWnd: THandle;
  Log: TAppLog;
begin
  C := BuildConfig(AFile);
  LogWnd := CreateWindowEx(0, 'STATIC', '', 0, 0, 0, 0, 0, HWND_MESSAGE, 0, HInstance, nil);
  C.NotifyHandle := LogWnd;
  Log := TAppLog.Create;
  Rec := TSimRecorder.Create;
  Busy := nil;
  try
    ResolveDevices;
    if not ConfigureOutput(Opt('out', 'wasapi'), C, Rec, DevName) then
    begin
      WriteLn('RESULT mode=rt error=device_not_found_(realasio:--driver,_realwasapi:--device)');
      Exit;
    end;
    Rec.Settings.NativeDsd := C.AsioNativeDsd;
    Rec.Settings.AllowDoP := OptInt('allowdop', 0) = 1;
    Rec.Settings.SineHz := OptFloat('sine', 0);
    Rec.Settings.SineDb := OptFloat('sinedb', -6);
    Rec.Settings.AsioPeriod := OptInt('period', 512);
    Rec.Settings.AsioRingPeriods := OptInt('ring', 0);
    Rec.Settings.Prefill := OptInt('prefill', 1) = 1;
    Rec.Settings.Drain := OptInt('drain', 1) = 1;
    Rec.Settings.Fade := OptInt('fade', 1) = 1;
    J1 := Opt('jitter', '0:0');
    J := Pos(':', J1);
    if J > 0 then
    begin
      Rec.Settings.JitterEveryMs := StrToIntDef(Copy(J1, 1, J - 1), 0);
      Rec.Settings.JitterMs := StrToFloatDef(StringReplace(Copy(J1, J + 1, 20), '.', DefaultFormatSettings.DecimalSeparator, []), 0);
    end;
    SetLength(Busy, OptInt('load', 0));
    for I := 0 to High(Busy) do Busy[I] := TBusyThread.Create(False);
    Secs := OptFloat('secs', 20);
    SwitchAfter := OptFloat('switchafter', 0);
    if (SwitchAfter > 0) and (SwitchAfter < Secs) then
    begin
      RunPhase(C, Rec, Log, SwitchAfter, OptFloat('from', 0), Ended, Err, RunUs);
      PrintPhase('1', Opt('out', 'wasapi'), DevName, Rec, RunUs, Ended, Err);
      { the switch: the new output opens right after the old one closed;
        --switchdop=0/1 changes "DSD as DoP" with it (a setting changed
        during a DSD track) }
      Rec.ResetStats;
      if Opt('switchdop', '') <> '' then
      begin
        C.UseDoP := OptInt('switchdop', 1) = 1;
        C.AsioNativeDsd := C.UseDoP;
        Rec.Settings.NativeDsd := C.UseDoP;
        if IsDsd(AFile) then
          C.ResamplePCM := (not C.UseDoP) and (OptInt('resample', 1) = 1) and (OptInt('dsdresample', 0) = 1);
      end;
      if not ConfigureOutput(Opt('switchto', ''), C, Rec, DevName) then
      begin
        WriteLn('RESULT mode=rt phase=2 error=device_not_found');
        Exit;
      end;
      { as TAudioEngine.Play gives it after a stream that closed just now
        (--settle=0: as before the fix) }
      C.SettleMs := OptInt('settle', 3000);
      RunPhase(C, Rec, Log, Secs - SwitchAfter, 0, Ended, Err, RunUs);
      PrintPhase('2', Opt('switchto', ''), DevName, Rec, RunUs, Ended, Err);
    end
    else
    begin
      RunPhase(C, Rec, Log, Secs, OptFloat('from', 0), Ended, Err, RunUs);
      PrintPhase('1', Opt('out', 'wasapi'), DevName, Rec, RunUs, Ended, Err);
    end;
    for I := 0 to Log.Lines.Count - 1 do WriteLn('LOG ', Log.Lines[I]);
  finally
    for I := 0 to High(Busy) do Busy[I].Terminate;
    for I := 0 to High(Busy) do
    begin
      Busy[I].WaitFor;
      Busy[I].Free;
    end;
    Rec.Free;
    Log.Free;
    if LogWnd <> 0 then DestroyWindow(LogWnd);
  end;
end;

{ ---- silent test files ---- }

{ a stereo DSF file of ASeconds of the DSD idle pattern ($69: as many ones as
  zeros, digital silence) }
procedure WriteSilentDsf(const APath: string; ADsdRate: Integer; ASeconds: Double);
const
  BLOCK = 4096;               // bytes per channel and block (DSF)
var
  FS: TFileStream;
  Blocks, B, BytesPerCh, DataSize: Int64;
  Buf: TBytes;

  procedure Tag(const S: AnsiString);
  begin
    FS.WriteBuffer(S[1], 4);
  end;

  procedure I32(V: Integer);
  begin
    FS.WriteBuffer(V, 4);
  end;

  procedure I64(V: Int64);
  begin
    FS.WriteBuffer(V, 8);
  end;

begin
  Blocks := (Round(ADsdRate / 8 * ASeconds) + BLOCK - 1) div BLOCK;
  BytesPerCh := Blocks * BLOCK;
  DataSize := BytesPerCh * 2;
  SetLength(Buf, BLOCK * 2);
  FillChar(Buf[0], Length(Buf), $69);
  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('DSD '); I64(28); I64(28 + 52 + 12 + DataSize); I64(0);
    Tag('fmt '); I64(52); I32(1); I32(0); I32(2); I32(2); I32(ADsdRate); I32(1);
    I64(BytesPerCh * 8); I32(BLOCK); I32(0);
    Tag('data'); I64(12 + DataSize);
    for B := 1 to Blocks do FS.WriteBuffer(Buf[0], Length(Buf));
  finally
    FS.Free;
  end;
end;

procedure MakeSilentFiles(const ADir: string);
var
  D: string;
  I: Integer;
begin
  D := IncludeTrailingPathDelimiter(ADir);
  ForceDirectories(D);
  WriteSilentFlac(D + 'silent_16_44100.flac', 44100, 16, 2, 60 * 44100, nil, nil);
  WriteSilentFlac(D + 'silent_24_48000.flac', 48000, 24, 2, 60 * 48000, nil, nil);
  WriteSilentFlac(D + 'silent_24_96000.flac', 96000, 24, 2, 60 * 96000, nil, nil);
  for I := 0 to 3 do
    WriteSilentDsf(D + Format('silent_dsd%d.dsf', [64 shl I]), 2822400 shl I, 20);
  WriteLn('RESULT mode=silent dir=', D);
end;

{ a stereo PCM WAV of a sine (AFreq, ADb dBFS), ASeconds long; ASkipAt > 0:
  one sample is left out there (a control: check must find it) }
procedure WriteToneWav(const APath: string; ARate, ABits: Integer; AFreq, ADb, ASeconds: Double;
  ASkipAt: Double = 0);
var
  FS: TFileStream;
  Frames, I, C, BytesPer: Integer;
  Amp, V: Double;
  S: Integer;
  Data: TBytes;
  P: Integer;

  procedure Tag(const T: AnsiString);
  begin
    FS.WriteBuffer(T[1], 4);
  end;

  procedure I32(X: Integer);
  begin
    FS.WriteBuffer(X, 4);
  end;

  procedure I16(X: Word);
  begin
    FS.WriteBuffer(X, 2);
  end;

begin
  Frames := Round(ARate * ASeconds);
  BytesPer := ABits div 8;
  SetLength(Data, Int64(Frames) * 2 * BytesPer);
  Amp := Power(10, ADb / 20) * (Int64(1) shl (ABits - 1));
  P := 0;
  for I := 0 to Frames - 1 do
  begin
    if (ASkipAt > 0) and (I >= Round(ASkipAt * ARate)) then
      V := Amp * Sin(2 * Pi * AFreq * (I + 1) / ARate)
    else
      V := Amp * Sin(2 * Pi * AFreq * I / ARate);
    S := Round(V);
    for C := 0 to 1 do
    begin
      Data[P] := Byte(S);
      Data[P + 1] := Byte(S shr 8);
      if BytesPer = 3 then Data[P + 2] := Byte(S shr 16);
      Inc(P, BytesPer);
    end;
  end;
  FS := TFileStream.Create(APath, fmCreate);
  try
    Tag('RIFF'); I32(36 + Length(Data)); Tag('WAVE');
    Tag('fmt '); I32(16); I16(1); I16(2); I32(ARate); I32(ARate * 2 * BytesPer);
    I16(2 * BytesPer); I16(ABits);
    Tag('data'); I32(Length(Data));
    FS.WriteBuffer(Data[0], Length(Data));
  finally
    FS.Free;
  end;
end;

procedure MakeToneFiles(const ADir: string);
var
  D: string;
begin
  D := IncludeTrailingPathDelimiter(ADir);
  ForceDirectories(D);
  WriteToneWav(D + 'tone_16_44100.wav', 44100, 16, 5000, -6, 30);
  WriteToneWav(D + 'tone_24_44100.wav', 44100, 24, 5000, -6, 30);
  WriteToneWav(D + 'tone_24_96000.wav', 96000, 24, 5000, -6, 30);
  WriteToneWav(D + 'control_skip_at_10s.wav', 44100, 16, 5000, -6, 30, 10.0);
  WriteLn('RESULT mode=tone dir=', D);
end;

{ ---- check: the signal ---- }

function MakeCheckSource(const AFile: string; const C: TPlayThreadConfig): TAudioSource;
var
  InRate, OutRate: Integer;
begin
  Result := CreateSourceFor(C, C.DsdGainDB, nil, AFile, InRate, OutRate);
  if Result = nil then Exit;
  Result.SetTargetBitDepth(32);
  if Result.GetBitsPerSample <> 32 then Result := TBitDepthConverterSource.Create(Result, 32);
end;

procedure CheckSignal(const AFile: string);
var
  C: TPlayThreadConfig;
  SA, SB: TAudioSource;
  Ch, CA, CB, LA, LB, M, N, I: Integer;
  QA, QB: array of LongInt;
  EndA, EndB: Boolean;
  Compared, Limit, Mismatch, FirstMismatch, TailA, TailB: Int64;
  MaxDiff: Int64;
  Rate: Cardinal;
  Sine: TSineCheck;
begin
  C := BuildConfig(AFile);
  SA := MakeCheckSource(AFile, C);
  SB := MakeCheckSource(AFile, C);
  Sine := nil;
  try
    if (SA = nil) or (SB = nil) then
    begin
      WriteLn('RESULT mode=check error=unsupported');
      Exit;
    end;
    Ch := SA.GetChannels;
    Rate := SA.GetSampleRate;
    CA := OptInt('chunk1', Integer(Int64(Rate) * C.BufferMs div 1000));
    CB := OptInt('chunk2', 1009);
    SetLength(QA, (CA + CB) * Ch * 2);
    SetLength(QB, (CA + CB) * Ch * 2);
    if OptFloat('sine', 0) > 0 then
      Sine := TSineCheck.Create(OptFloat('sine', 0), OptFloat('sinedb', -6), Rate, Ch);
    if OptFloat('secs', 0) > 0 then Limit := Round(OptFloat('secs', 0) * Rate) * Ch
    else Limit := High(Int64);
    LA := 0; LB := 0;
    EndA := False; EndB := False;
    Compared := 0; Mismatch := 0; FirstMismatch := -1; MaxDiff := 0; TailA := 0; TailB := 0;
    while Compared < Limit do
    begin
      if (not EndA) and ((LA <= LB) or EndB) then
      begin
        N := SA.ReadData(@QA[LA], CA * Ch * 4) div 4;
        if N <= 0 then EndA := True
        else
        begin
          if Sine <> nil then Sine.Feed(@QA[LA], N div Ch);
          Inc(LA, N);
        end;
      end
      else if not EndB then
      begin
        N := SB.ReadData(@QB[LB], CB * Ch * 4) div 4;
        if N <= 0 then EndB := True else Inc(LB, N);
      end
      else
        Break;
      M := Min(LA, LB);
      if M > 0 then
      begin
        for I := 0 to M - 1 do
          if QA[I] <> QB[I] then
          begin
            Inc(Mismatch);
            if FirstMismatch < 0 then FirstMismatch := Compared + I;
            if Abs(Int64(QA[I]) - QB[I]) > MaxDiff then MaxDiff := Abs(Int64(QA[I]) - QB[I]);
          end;
        Inc(Compared, M);
        Move(QA[M], QA[0], (LA - M) * 4);
        Move(QB[M], QB[0], (LB - M) * 4);
        Dec(LA, M);
        Dec(LB, M);
      end;
      { one pass ended: what the other delivers beyond it is a length difference }
      if EndB and (LB = 0) and (LA > 0) then begin Inc(TailA, LA); LA := 0; end;
      if EndA and (LA = 0) and (LB > 0) then begin Inc(TailB, LB); LB := 0; end;
    end;
    Inc(TailA, LA);
    Inc(TailB, LB);
    { at the end both must have delivered the same length }
    Write(Format('RESULT mode=check rate=%d chunk1=%d chunk2=%d seconds=%s mismatches=%d first_mismatch_s=%s ' +
      'max_diff=%d tail_a=%d tail_b=%d', [Rate, CA, CB, Fx(Compared / Ch / Rate, '0.00'), Mismatch,
      Fx(Max(-1, FirstMismatch) / Ch / Rate, '0.0000'), MaxDiff, TailA, TailB]));
    if Sine <> nil then
      Write(Format(' sine_max_rel=%s sine_outliers=%d sine_spikes_s=%s',
        [Fx(Sine.MaxRel, '0.000000'), Sine.Outliers, Sine.Spikes]));
    WriteLn;
  finally
    Sine.Free;
    SA.Free;
    SB.Free;
  end;
end;

{ ---- spectrum: what a decimation without a filter would fold into the band ---- }

{ in-place radix-2 FFT (Re / Im, N a power of two) }
procedure Fft(var Re, Im: array of Double; N: Integer);
var
  I, J, K, M, Step: Integer;
  T, Wr, Wi, Ur, Ui, Ang, Tr, Ti: Double;
begin
  J := 0;
  for I := 0 to N - 2 do
  begin
    if I < J then
    begin
      T := Re[I]; Re[I] := Re[J]; Re[J] := T;
      T := Im[I]; Im[I] := Im[J]; Im[J] := T;
    end;
    K := N shr 1;
    while (K >= 1) and (J >= K) do
    begin
      Dec(J, K);
      K := K shr 1;
    end;
    Inc(J, K);
  end;
  Step := 1;
  while Step < N do
  begin
    Ang := -Pi / Step;
    for M := 0 to Step - 1 do
    begin
      Wr := Cos(Ang * M);
      Wi := Sin(Ang * M);
      I := M;
      while I < N do
      begin
        J := I + Step;
        Tr := Wr * Re[J] - Wi * Im[J];
        Ti := Wr * Im[J] + Wi * Re[J];
        Ur := Re[I]; Ui := Im[I];
        Re[I] := Ur + Tr; Im[I] := Ui + Ti;
        Re[J] := Ur - Tr; Im[J] := Ui - Ti;
        Inc(I, 2 * Step);
      end;
    end;
    Step := Step * 2;
  end;
end;

{ the left channel's power spectrum (Welch: Hann, half overlap, N = 16384)
  in bands, in dB relative to a full-scale sine: the audio band 0..20 kHz,
  20..fold/2 and what a decimation to --fold=RATE without a filter would put
  into 0..20 kHz (|f - k x fold| <= 20 kHz, k >= 1) }
procedure Spectrum(const AFile: string);
const
  N = 16384;
var
  C: TPlayThreadConfig;
  Src: TAudioSource;
  Rate, Fold: Double;
  Ch, Frames, Got, I, Blocks, K, Bin: Integer;
  Buf: TBytes;
  Hist: array of Double;
  Re, Im, Win: array of Double;
  WinSum, P, F, Nearest: Double;
  PAudio, PMid, PAlias, PTotal, Limit, Done: Double;

  function Db(AP: Double): string;
  begin
    if AP <= 0 then Exit('-inf');
    Result := Fx(10 * Log10(AP / (Blocks * WinSum * N) / 0.5), '0.0');
  end;

begin
  C := BuildConfig(AFile);
  Src := MakeCheckSource(AFile, C);
  if Src = nil then
  begin
    WriteLn('RESULT mode=spectrum error=unsupported');
    Exit;
  end;
  try
    Rate := Src.GetSampleRate;
    Ch := Src.GetChannels;
    Fold := OptFloat('fold', Rate / 2);
    SetLength(Buf, N * Ch * 4);
    SetLength(Hist, N);
    SetLength(Re, N);
    SetLength(Im, N);
    SetLength(Win, N);
    WinSum := 0;
    for I := 0 to N - 1 do
    begin
      Win[I] := 0.5 - 0.5 * Cos(2 * Pi * I / N);
      WinSum := WinSum + Sqr(Win[I]);
    end;
    PAudio := 0; PMid := 0; PAlias := 0; PTotal := 0;
    Blocks := 0;
    Limit := OptFloat('secs', 30) * Rate;
    Done := 0;
    { the first half block, then half blocks (half overlap) }
    Got := Src.ReadData(@Buf[0], (N div 2) * Ch * 4) div (Ch * 4);
    for I := 0 to Got - 1 do Hist[N div 2 + I] := PLongInt(@Buf[I * Ch * 4])^ / 2147483648.0;
    { skip the first second (the start of the filters, the fade-in) }
    Frames := 0;
    while Done < Limit do
    begin
      Move(Hist[N div 2], Hist[0], (N div 2) * SizeOf(Double));
      Got := Src.ReadData(@Buf[0], (N div 2) * Ch * 4) div (Ch * 4);
      if Got < N div 2 then Break;
      for I := 0 to Got - 1 do Hist[N div 2 + I] := PLongInt(@Buf[I * Ch * 4])^ / 2147483648.0;
      Inc(Frames, Got);
      if Frames < Rate then Continue;
      Done := Done + Got;
      for I := 0 to N - 1 do
      begin
        Re[I] := Hist[I] * Win[I];
        Im[I] := 0;
      end;
      Fft(Re, Im, N);
      for Bin := 1 to N div 2 - 1 do
      begin
        P := 2 * (Sqr(Re[Bin]) + Sqr(Im[Bin]));   // both halves of the spectrum
        F := Bin * Rate / N;
        PTotal := PTotal + P;
        if F <= 20000 then PAudio := PAudio + P
        else if F <= Fold / 2 then PMid := PMid + P;
        K := Round(F / Fold);
        Nearest := K * Fold;
        if (K >= 1) and (Abs(F - Nearest) <= 20000) then PAlias := PAlias + P;
      end;
      Inc(Blocks);
    end;
    if Blocks = 0 then
    begin
      WriteLn('RESULT mode=spectrum error=too_short');
      Exit;
    end;
    WriteLn(Format('RESULT mode=spectrum rate=%s fold=%s seconds=%s audio_0_20k_db=%s band_20k_to_half_fold_db=%s ' +
      'folds_into_0_20k_db=%s alias_below_audio_db=%s',
      [Fx(Rate, '0'), Fx(Fold, '0'), Fx(Done / Rate, '0.0'), Db(PAudio), Db(PMid), Db(PAlias),
       Fx(10 * Log10(Max(PAlias, 1E-300) / Max(PAudio, 1E-300)), '0.0')]));
  finally
    Src.Free;
  end;
end;

{ tonebench <rate> [--secs=10]: the tone control with all three bands on, a
  stereo stream of <rate> Hz. "inline" is what the play thread does
  (ProcessSampleL / R inlined, the filters inside them too); "calls" runs the
  same filter arithmetic with one function call per filter and sample - how
  it was compiled before the fix of 2026-11-12 (the compiler could not inline
  the filter into another unit). Prints the time per second of audio. }
type
  TBenchBiquad = record
    b0, b1, b2, a1, a2, s1, s2: Double;
  end;

function BenchBiquadStep(var F: TBenchBiquad; AInput: Double): Double;
begin
  Result := (F.b0 * AInput) + F.s1;
  F.s1   := (F.b1 * AInput) - (F.a1 * Result) + F.s2;
  F.s2   := (F.b2 * AInput) - (F.a2 * Result) + ANTI_DENORMAL_OFFSET;
end;

procedure ToneBench(ARate: Integer);
const
  BLOCK = 8192;
var
  Tone: TToneControl;
  Ref: array[0..1, 0..2] of TBenchBiquad;
  Buf: array of Double;
  Frames, Done, N, I, B, Ch: Integer;
  Seed: Cardinal;
  T0, TInline, TCalls: Int64;
  Sum1, Sum2, X: Double;
  Secs: Integer;
begin
  if ARate < 8000 then ARate := 705600;
  Secs := OptInt('secs', 10);
  Frames := ARate * Secs;
  Buf := nil;
  SetLength(Buf, BLOCK * 2);
  Seed := 1;
  for I := 0 to High(Buf) do
  begin
    Seed := Cardinal((QWord(Seed) * 1664525 + 1013904223) and $FFFFFFFF);
    Buf[I] := Integer(Seed shr 8) - 8388608;
  end;
  { any stable filters: only the time matters here }
  for Ch := 0 to 1 do
    for B := 0 to 2 do
    begin
      Ref[Ch, B] := Default(TBenchBiquad);
      Ref[Ch, B].b0 := 1.01; Ref[Ch, B].b1 := -1.9; Ref[Ch, B].b2 := 0.9;
      Ref[Ch, B].a1 := -1.9; Ref[Ch, B].a2 := 0.905;
    end;
  Tone := TToneControl.Create;
  try
    Tone.SetSampleRate(ARate);
    Tone.SetGains(30, -20, 25);
    Tone.SetDirectMode(False);
    Sum1 := 0;
    T0 := NowUs;
    Done := 0;
    while Done < Frames do
    begin
      N := Min(BLOCK, Frames - Done);
      for I := 0 to N - 1 do
      begin
        Sum1 := Sum1 + Tone.ProcessSampleL(Buf[2 * I]);
        Sum1 := Sum1 + Tone.ProcessSampleR(Buf[2 * I + 1]);
      end;
      Inc(Done, N);
    end;
    TInline := NowUs - T0;
    Sum2 := 0;
    T0 := NowUs;
    Done := 0;
    while Done < Frames do
    begin
      N := Min(BLOCK, Frames - Done);
      for I := 0 to N - 1 do
        for Ch := 0 to 1 do
        begin
          X := Buf[2 * I + Ch];
          for B := 0 to 2 do X := BenchBiquadStep(Ref[Ch, B], X);
          Sum2 := Sum2 + X;
        end;
      Inc(Done, N);
    end;
    TCalls := NowUs - T0;
    WriteLn(Format('RESULT mode=tonebench rate=%d secs=%d inline_ms_per_s=%s calls_ms_per_s=%s inline_cpu_pct=%s ' +
      'calls_cpu_pct=%s ratio=%s check=%s',
      [ARate, Secs, Fx(TInline / 1000 / Secs, '0.00'), Fx(TCalls / 1000 / Secs, '0.00'),
       Fx(TInline / 10000 / Secs, '0.00'), Fx(TCalls / 10000 / Secs, '0.00'),
       Fx(TCalls / Max(1, TInline), '0.00'), Fx(Abs(Sum1) + Abs(Sum2), '0')]));
  finally
    Tone.Free;
  end;
end;

{ rgbench <album folder> [--threads=1,2,4]: the program's ReplayGain scan
  (TReplayGainThread, as the ReplayGain window starts it) on the music files
  of the folder as one album, once per thread count: the time, the speed-up
  and a check that every run gave the same gains. Read only: the results are
  measured and thrown away, nothing is written. }
type
  TRgBenchSink = class
    Sum: Double;
    Count: Integer;
    procedure Results(Sender: TObject; AResults: TList);
  end;

procedure TRgBenchSink.Results(Sender: TObject; AResults: TList);
var
  I: Integer;
  R: PRGScanResult;
begin
  for I := 0 to AResults.Count - 1 do
  begin
    R := PRGScanResult(AResults[I]);
    if R^.Status = rsReadyToSave then
    begin
      Sum := Sum + R^.TrackGain * (I + 1) + R^.AlbumGain + R^.TrackPeak;
      Inc(Count);
    end;
    Dispose(R);
  end;
end;

procedure RgBench(const AFolder: string);
var
  Files, Counts: TStringList;
  SR: TSearchRec;
  K, N: Integer;
  Groups: TRGAlbumGroups;
  Thread: TReplayGainThread;
  Sink: TRgBenchSink;
  T0, Us, FirstUs: Int64;
  FirstSum: Double;
  Line: string;
begin
  Files := TStringList.Create;
  Counts := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(AFolder) + '*', faAnyFile, SR) = 0 then
    begin
      repeat
        if ((SR.Attr and faDirectory) = 0) and IsValidMusicFile(SR.Name) then
          Files.Add(IncludeTrailingPathDelimiter(AFolder) + SR.Name);
      until FindNext(SR) <> 0;
      SysUtils.FindClose(SR);
    end;
    Files.Sort;
    if Files.Count = 0 then
    begin
      WriteLn('RESULT mode=rgbench error=no_music_files');
      Exit;
    end;
    Counts.CommaText := Opt('threads', '1,2,4');
    FirstUs := 0;
    FirstSum := 0;
    Line := Format('RESULT mode=rgbench tracks=%d', [Files.Count]);
    for K := 0 to Counts.Count - 1 do
    begin
      N := StrToIntDef(Counts[K], 1);
      Groups := TRGAlbumGroups.Create;
      Groups.Add(TStringList.Create);
      Groups[0].Assign(Files);
      Sink := TRgBenchSink.Create;
      Thread := TReplayGainThread.Create(Groups, True, nil);
      try
        Thread.OnResults := @Sink.Results;
        Thread.ThreadCount := N;
        T0 := NowUs;
        Thread.Start;
        while not Thread.Finished do CheckSynchronize(10);
        Thread.WaitFor;
        Us := NowUs - T0;
        if K = 0 then
        begin
          FirstUs := Us;
          FirstSum := Sink.Sum;
        end;
        Line := Line + Format(' t%d_s=%s t%d_speedup=%s t%d_same=%s',
          [N, Fx(Us / 1E6, '0.00'), N, Fx(FirstUs / Max(1, Us), '0.00'), N,
           BoolToStr((Sink.Sum = FirstSum) and (Sink.Count = Files.Count), 'yes', 'NO')]);
      finally
        Thread.Free;
        Sink.Free;
      end;
    end;
    WriteLn(Line);
  finally
    Counts.Free;
    Files.Free;
  end;
end;

var
  Mode, F: string;
begin
  Application.Initialize;
  if ParamCount < 2 then
  begin
    WriteLn('AudioSim bench|rt <file> [--options]  (see the source)');
    ExitCode := 2;
  end
  else
  begin
    Mode := ParamStr(1);
    F := ParamStr(2);
    if Opt('simd', 'auto') = 'pascal' then SetResampleSimd(rsPascal)
    else if Opt('simd', 'auto') = 'sse2' then SetResampleSimd(rsSSE2)
    else if Opt('simd', 'auto') = 'avx' then SetResampleSimd(rsAVX);
    { --fft=0: every resampler stage in direct form (the output before the
      FFT stages, 2026-11-11) }
    SetResampleFft(OptInt('fft', 1) = 1);
    try
      if Mode = 'bench' then Bench(F)
      else if Mode = 'rt' then RealTime(F)
      else if Mode = 'silent' then MakeSilentFiles(F)
      else if Mode = 'tone' then MakeToneFiles(F)
      else if Mode = 'check' then CheckSignal(F)
      else if Mode = 'rgcheck' then RgCheck(F)
      else if Mode = 'rgtags' then RgTags(F)
      else if Mode = 'rgscreen' then RgScreen(F)
      else if Mode = 'spectrum' then Spectrum(F)
      else if Mode = 'waitdevice' then WaitDevice
      else if Mode = 'tonebench' then ToneBench(StrToIntDef(F, 705600))
      else if Mode = 'rgbench' then RgBench(F)
      else WriteLn('unknown mode ', Mode);
    except
      on E: Exception do
      begin
        WriteLn('RESULT error=', StringReplace(E.ClassName + ':' + E.Message, ' ', '_', [rfReplaceAll]));
        ExitCode := 1;
      end;
    end;
  end;
  FreeAppSingletons;
end.
