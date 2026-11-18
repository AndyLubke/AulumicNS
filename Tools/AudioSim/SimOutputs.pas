unit SimOutputs;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tools - SimOutputs
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AudioSim: simulated output devices for the real play thread (TPlayThread
  with OutputFactory), in real time.

  TSimWasapiOutput - WASAPI exclusive, event driven: the device plays one
    buffer (BufferMs) while the play thread fills the other. Buffer n starts
    playing at T0 + n * P; it must be released before that, else it is a
    glitch (the device had nothing to play). WaitForBuffer returns at the
    event of the buffer being played (T0 + (n - 1) * P).
  TSimAsioOutput - ASIO: a driver thread calls "bufferSwitch" every period
    (AsioPeriod frames) at exact times and takes one period from the real
    TOutputRing (ALOutputRing) of the engine; an empty ring is an underrun.
    The ring is sized as the engine sizes it (RingPeriodsFor) or with a fixed
    number of periods (3 = before the fix).

  Both can stall the play thread on purpose (Jitter: JitterMs about every
  JitterEveryMs, after its wait for the device) to show how much a delay the
  buffer absorbs, and both measure: glitches / underruns, the least margin
  (WASAPI: time between the release and the start of play; ASIO: the ring's
  fill before a take), how long the play thread needs per buffer, and the
  audio that was handed over but not played when the output was closed (the
  cut: WASAPI the rest of the buffers queued, ASIO the ring's fill).
  Prefill / Drain False = the engine before the fix (one buffer before Start,
  closed at once at the end of the stream), to compare.

  TRealAsioProbe - no simulation: the real TAsioOutput with the real ASIO
    driver and DAC (play silent files!), measured from outside: the ring's
    underruns and least fill, the cut at Close. AsioRingPeriods > 0 opens it
    with the ring before the fix (3 periods); stalls as above.
  ============================================================================}

interface

uses
  Windows, Classes, SysUtils, Math, ALAudioOutput, ALOutputRing, ALOutputAsio, ALOutputWasapi;

type
  { skRealWasapi: TRealWasapiProbe - the real TWasapiOutput on the real
    device (silent files only), measured like TRealAsioProbe: its open
    attempts (the format retries of the play thread), the buffer it took
    (the fallback for a refused period), its dropout estimate }
  TSimKind = (skWasapi, skAsio, skRealAsio, skRealWasapi);

  TSimSettings = record
    Kind: TSimKind;
    AsioPeriod: Integer;         // frames per ASIO period
    AsioRingPeriods: Integer;    // 0 = the engine's rule (RingPeriodsFor), else fixed
    JitterEveryMs: Integer;      // 0 = no stalls
    JitterMs: Double;
    DeviceBits, DeviceValid: Integer;
    Prefill: Boolean;            // ASIO: about 40 ms before Start (as TAsioOutput)
    Drain: Boolean;              // play out before Close (as TWasapiOutput / TAsioOutput)
    Fade: Boolean;               // ASIO: FadeOut before a Close mid-music (as TAsioOutput)
    NativeDsd: Boolean;          // real ASIO: DSD as native DSD when the driver can
    AllowDoP: Boolean;           // real ASIO: DoP as PCM allowed (a DAC that does not
                                 // decode DoP plays its markers: not silent)
    SineHz, SineDb: Double;      // > 0: check the output as a sine of SineHz at SineDb dBFS
  end;

  { TSineCheck: finds discontinuities in a pure sine (32 bit interleaved
    frames): for a sine x[n+1] + x[n-1] - 2 cos(w) x[n] = 0, so a lost, doubled
    or faded sample shows as a spike of that residual. Relative to the
    amplitude; the first 0.1 s (the filter's start) is not counted. }
  TSineCheck = class
  private
    FC2, FAmp: Double;
    FCh: Integer;
    FRate: Cardinal;
    FPrev: array[0..7, 0..1] of Double;
    FN, FSkip: Int64;
  public
    MaxRel: Double;              // the largest residual / amplitude
    Outliers: Int64;             // residuals over 1e-3 of the amplitude
    Spikes: string;              // the first ones (seconds)
    constructor Create(AFreq, ADb: Double; ARate: Cardinal; AChannels: Integer);
    procedure Feed(P: PLongInt; AFrames: Integer);
  end;

  TSimStats = record
    Glitches: Integer;           // WASAPI: late buffers; ASIO: underruns
    Buffers: Integer;            // buffers / periods released by the play thread
    Taken: Integer;              // ASIO: periods the driver took (or wanted)
    MinMarginUs: Int64;          // the least margin (see above); High(Int64) = none
    FillMaxUs, FillSumUs: Int64; // GetBuffer -> ReleaseBuffer of the play thread
    FillCount: Integer;
    Stalls: Integer;             // stalls injected
    Rate: Cardinal;
    PeriodFrames: Integer;       // WASAPI: buffer frames; ASIO: period frames
    RingPeriods: Integer;
    Opens: Integer;
    CutLastUs, CutMaxUs: Int64;  // audio not played at a Close (the last one, the most)
    MinMarginAt: Integer;        // ASIO: the take (Taken) / WASAPI: the buffer of the least margin
    NativeDsd: Boolean;          // real ASIO: the driver took native DSD
    ValidBits: Integer;          // the device's valid bits
    OpenAttempts, OpenFailures: Integer;  // real outputs: Open calls / not oorOK
    OpenErrors: string;          // the failed ones: result:HRESULT;...
    BufferMsTaken: Integer;      // real outputs: BufferedMs of the last good open
  end;

  { TSimRecorder: the settings and the results of one run }

  TSimRecorder = class
  private
    FLock: TRTLCriticalSection;
    FStats: TSimStats;
    FNextStallUs: Int64;
    FSeed: Cardinal;
    FSine: TSineCheck;
  public
    Settings: TSimSettings;
    { the simulated ASIO device: the last period it got before Close - the
      absolute value of its last sample and its peak (EndSeen: there was one) }
    EndSeen: Boolean;
    EndLast, EndPeak: Int64;
    constructor Create;
    destructor Destroy; override;
    function CreateOutput: TAudioOutput;   // TAudioOutputFactory
    function Stats: TSimStats;
    procedure AddFill(AUs: Int64);
    procedure AddMargin(AUs: Int64);
    procedure AddGlitch;
    procedure AddBuffer;
    procedure AddStall;
    procedure AddTaken;
    procedure AddCut(AUs: Int64);
    procedure AddGlitches(ACount: Integer);
    procedure SetFormat(ARate: Cardinal; APeriodFrames, ARingPeriods: Integer);
    procedure SetDeviceInfo(ANativeDsd: Boolean; AValidBits: Integer);
    procedure AddOpen(AResult: TOutputOpenResult; AError: HRESULT; ABufferMs: Integer);
    { the statistics of a new phase (rt --switchafter); the settings stay }
    procedure ResetStats;
    { a stall of the play thread (Settings.Jitter*); called after its wait }
    procedure MaybeStall;
    { a released buffer (32 bit frames) for the sine check (Settings.SineHz) }
    procedure FeedSine(AData: PByte; ABytes: Integer; ARate: Cardinal; AChannels: Integer);
    property Sine: TSineCheck read FSine;
  end;

function NowUs: Int64;
procedure WaitUntilUs(ATimeUs: Int64);

implementation

uses
  MMSystem;

var
  QpcFreq: Int64 = 0;

function NowUs: Int64;
var
  C: Int64;
begin
  QueryPerformanceCounter(C);
  Result := C * 1000000 div QpcFreq;
end;

{ sleeps while more than 2 ms are left (timer resolution 1 ms), spins the rest }
procedure WaitUntilUs(ATimeUs: Int64);
var
  Left: Int64;
begin
  repeat
    Left := ATimeUs - NowUs;
    if Left <= 0 then Exit;
    if Left > 2000 then Sleep(1)
    else if Left > 200 then Sleep(0);
  until False;
end;

type
  { TSimOutputBase }

  TSimOutputBase = class(TAudioOutput)
  protected
    FRec: TSimRecorder;
    FFormat: TAudioOutputFormat;
    FStage: TBytes;
    FGetUs: Int64;
    procedure MaybeStall;
  public
    constructor Create(ARec: TSimRecorder);
    function Format: TAudioOutputFormat; override;
    function BufferBytes: Integer; override;
  end;

  { TSimWasapiOutput }

  TSimWasapiOutput = class(TSimOutputBase)
  private
    FPeriodUs: Double;
    FT0: Int64;
    FQueued: Integer;           // buffers released since the clock started
    FStarted: Boolean;
    FTailGiven: Boolean;        // the last buffer released is the silent tail
  public
    function DrainTail: Boolean; override;
    procedure Drain(AStopEvent: THandle); override;
    function Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
      AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
      out AErrorText: string): TOutputOpenResult; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Reset; override;
    function WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait; override;
    function GetBuffer(out AData: PByte; out AError: HRESULT): Boolean; override;
    procedure ReleaseBuffer(AFull: Boolean); override;
    procedure Close; override;
  end;

  TSimAsioOutput = class;

  { TSimDriverThread: the driver's bufferSwitch, every period }

  TSimDriverThread = class(TThread)
  private
    FOut: TSimAsioOutput;
  protected
    procedure Execute; override;
  public
    constructor Create(AOut: TSimAsioOutput);
  end;

  { TSimAsioOutput }

  TSimAsioOutput = class(TSimOutputBase)
  private
    FRing: TOutputRing;
    FDriver: TSimDriverThread;
    FPeriodUs: Double;
    FStarted: Boolean;
    FDraining: Boolean;
    FTake: TBytes;
    FFade: TPeriodFade;
  public
    destructor Destroy; override;
    function PrefillBuffers: Integer; override;
    procedure Drain(AStopEvent: THandle); override;
    procedure FadeOut; override;
    procedure NoteEnd;
    function Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
      AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
      out AErrorText: string): TOutputOpenResult; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Reset; override;
    function WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait; override;
    function GetBuffer(out AData: PByte; out AError: HRESULT): Boolean; override;
    procedure ReleaseBuffer(AFull: Boolean); override;
    procedure Close; override;
  end;

  { TRealWasapiProbe: the real WASAPI output, measured }

  TRealWasapiProbe = class(TWasapiOutput)
  private
    FRec: TSimRecorder;
    FGetUs: Int64;
    FStopSeen: Boolean;
    FDropsAtStop: Integer;
  public
    constructor Create(ARec: TSimRecorder);
    function Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
      AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
      out AErrorText: string): TOutputOpenResult; override;
    function WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait; override;
    function GetBuffer(out AData: PByte; out AError: HRESULT): Boolean; override;
    procedure ReleaseBuffer(AFull: Boolean); override;
    procedure Close; override;
  end;

  { TRealAsioProbe: the real ASIO output, measured }

  TRealAsioProbe = class(TAsioOutput)
  private
    FRec: TSimRecorder;
    FGetUs: Int64;
    FStopSeen: Boolean;
    FUnderrunsAtStop: Integer;
  public
    constructor Create(ARec: TSimRecorder);
    function Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
      AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
      out AErrorText: string): TOutputOpenResult; override;
    function PrefillBuffers: Integer; override;
    procedure Drain(AStopEvent: THandle); override;
    function WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait; override;
    function GetBuffer(out AData: PByte; out AError: HRESULT): Boolean; override;
    procedure ReleaseBuffer(AFull: Boolean); override;
    procedure Close; override;
  end;

{ ---- TSimRecorder ---- }

constructor TSimRecorder.Create;
begin
  inherited Create;
  InitializeCriticalSection(FLock);
  FStats := Default(TSimStats);
  FStats.MinMarginUs := High(Int64);
  Settings.DeviceBits := 32;
  Settings.DeviceValid := 24;
  Settings.AsioPeriod := 512;
  Settings.Prefill := True;
  Settings.Drain := True;
  Settings.NativeDsd := True;
  FSeed := $1234567;
end;

destructor TSimRecorder.Destroy;
begin
  FSine.Free;
  DeleteCriticalSection(FLock);
  inherited Destroy;
end;

procedure TSimRecorder.FeedSine(AData: PByte; ABytes: Integer; ARate: Cardinal; AChannels: Integer);
begin
  if (Settings.SineHz <= 0) or (AData = nil) or (AChannels < 1) then Exit;
  if FSine = nil then FSine := TSineCheck.Create(Settings.SineHz, Settings.SineDb, ARate, AChannels);
  FSine.Feed(PLongInt(AData), ABytes div (4 * AChannels));
end;

{ ---- TSineCheck ---- }

constructor TSineCheck.Create(AFreq, ADb: Double; ARate: Cardinal; AChannels: Integer);
begin
  inherited Create;
  FRate := ARate;
  FCh := Min(AChannels, 8);
  FC2 := 2 * Cos(2 * Pi * AFreq / ARate);
  FAmp := 2147483648.0 * Power(10, ADb / 20);
  FSkip := ARate div 10;
end;

procedure TSineCheck.Feed(P: PLongInt; AFrames: Integer);
var
  I, C: Integer;
  X, R: Double;
begin
  for I := 0 to AFrames - 1 do
  begin
    for C := 0 to FCh - 1 do
    begin
      X := P^;
      Inc(P);
      if FN >= 2 then
      begin
        R := Abs(X + FPrev[C, 0] - FC2 * FPrev[C, 1]) / FAmp;
        if FN >= FSkip then
        begin
          if R > MaxRel then MaxRel := R;
          if R > 1E-3 then
          begin
            Inc(Outliers);
            if (Outliers <= 5) and (C = 0) then
              Spikes := Spikes + FormatFloat('0.0000', FN / FRate) + ';';
          end;
        end;
      end;
      FPrev[C, 0] := FPrev[C, 1];
      FPrev[C, 1] := X;
    end;
    Inc(FN);
  end;
end;

function TSimRecorder.CreateOutput: TAudioOutput;
begin
  case Settings.Kind of
    skAsio: Result := TSimAsioOutput.Create(Self);
    skRealAsio: Result := TRealAsioProbe.Create(Self);
    skRealWasapi: Result := TRealWasapiProbe.Create(Self);
  else
    Result := TSimWasapiOutput.Create(Self);
  end;
end;

function TSimRecorder.Stats: TSimStats;
begin
  EnterCriticalSection(FLock);
  Result := FStats;
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddFill(AUs: Int64);
begin
  EnterCriticalSection(FLock);
  if AUs > FStats.FillMaxUs then FStats.FillMaxUs := AUs;
  Inc(FStats.FillSumUs, AUs);
  Inc(FStats.FillCount);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddMargin(AUs: Int64);
begin
  EnterCriticalSection(FLock);
  if AUs < FStats.MinMarginUs then
  begin
    FStats.MinMarginUs := AUs;
    if Settings.Kind = skAsio then FStats.MinMarginAt := FStats.Taken
    else FStats.MinMarginAt := FStats.Buffers;
  end;
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddGlitch;
begin
  EnterCriticalSection(FLock);
  Inc(FStats.Glitches);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddBuffer;
begin
  EnterCriticalSection(FLock);
  Inc(FStats.Buffers);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddStall;
begin
  EnterCriticalSection(FLock);
  Inc(FStats.Stalls);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddTaken;
begin
  EnterCriticalSection(FLock);
  Inc(FStats.Taken);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddCut(AUs: Int64);
begin
  if AUs < 0 then AUs := 0;
  EnterCriticalSection(FLock);
  FStats.CutLastUs := AUs;
  if AUs > FStats.CutMaxUs then FStats.CutMaxUs := AUs;
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddGlitches(ACount: Integer);
begin
  EnterCriticalSection(FLock);
  Inc(FStats.Glitches, ACount);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.SetFormat(ARate: Cardinal; APeriodFrames, ARingPeriods: Integer);
begin
  EnterCriticalSection(FLock);
  FStats.Rate := ARate;
  FStats.PeriodFrames := APeriodFrames;
  FStats.RingPeriods := ARingPeriods;
  Inc(FStats.Opens);
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.SetDeviceInfo(ANativeDsd: Boolean; AValidBits: Integer);
begin
  EnterCriticalSection(FLock);
  FStats.NativeDsd := ANativeDsd;
  FStats.ValidBits := AValidBits;
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.AddOpen(AResult: TOutputOpenResult; AError: HRESULT; ABufferMs: Integer);
begin
  EnterCriticalSection(FLock);
  Inc(FStats.OpenAttempts);
  if AResult = oorOK then
    FStats.BufferMsTaken := ABufferMs
  else
  begin
    Inc(FStats.OpenFailures);
    FStats.OpenErrors := FStats.OpenErrors + IntToStr(Ord(AResult)) + ':' + IntToHex(Cardinal(AError), 8) + ';';
  end;
  LeaveCriticalSection(FLock);
end;

procedure TSimRecorder.ResetStats;
begin
  EnterCriticalSection(FLock);
  FStats := Default(TSimStats);
  FStats.MinMarginUs := High(Int64);
  LeaveCriticalSection(FLock);
end;

{ JitterMs, about every JitterEveryMs (+-50 %) }
procedure TSimRecorder.MaybeStall;
var
  T: Int64;
begin
  if Settings.JitterEveryMs <= 0 then Exit;
  T := NowUs;
  if FNextStallUs = 0 then
  begin
    FNextStallUs := T + Int64(Settings.JitterEveryMs) * 1000;
    Exit;
  end;
  if T < FNextStallUs then Exit;
  FSeed := FSeed * 1103515245 + 12345;
  FNextStallUs := T + Int64(Settings.JitterEveryMs) * 500 +
    Int64(FSeed shr 8) mod (Int64(Settings.JitterEveryMs) * 1000 + 1);
  WaitUntilUs(T + Round(Settings.JitterMs * 1000));
  AddStall;
end;

{ ---- TSimOutputBase ---- }

constructor TSimOutputBase.Create(ARec: TSimRecorder);
begin
  inherited Create;
  FRec := ARec;
end;

function TSimOutputBase.Format: TAudioOutputFormat;
begin
  Result := FFormat;
end;

function TSimOutputBase.BufferBytes: Integer;
begin
  Result := Length(FStage);
end;

{ a stall of the play thread after its wait (as a late wake-up would be) }
procedure TSimOutputBase.MaybeStall;
begin
  FRec.MaybeStall;
end;

{ ---- TSimWasapiOutput ---- }

function TSimWasapiOutput.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT; out AErrorText: string): TOutputOpenResult;
var
  Frames: Integer;
begin
  AError := 0;
  AErrorText := '';
  FFormat := Default(TAudioOutputFormat);
  FFormat.SampleRate := ARate;
  FFormat.Channels := AChannels;
  FFormat.Bits := FRec.Settings.DeviceBits;
  FFormat.ValidBits := FRec.Settings.DeviceValid;
  if AIsDoP and (FFormat.ValidBits < 24) then FFormat.ValidBits := 24;
  FFormat.BlockAlign := AChannels * (FFormat.Bits div 8);
  Frames := Integer((Int64(ARate) * ABufferMs) div 1000);
  if Frames < 16 then Frames := 16;
  SetLength(FStage, Frames * FFormat.BlockAlign);
  FPeriodUs := Frames * 1000000.0 / ARate;
  FQueued := 0;
  FStarted := False;
  FTailGiven := False;
  FRec.SetFormat(ARate, Frames, 2);
  Result := oorOK;
end;

procedure TSimWasapiOutput.Start;
begin
  { the buffers released before Start: the first plays now }
  FT0 := NowUs;
  FStarted := True;
end;

procedure TSimWasapiOutput.Stop;
begin
  FStarted := False;
end;

procedure TSimWasapiOutput.Reset;
begin
  FQueued := 0;
end;

function TSimWasapiOutput.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
var
  EventAt: Int64;
begin
  if WaitForSingleObject(AStopEvent, 0) = WAIT_OBJECT_0 then Exit(owStop);
  if not FStarted then Exit(owBufferReady);
  { the event of buffer FQueued - 1 (it starts playing): the next is wanted }
  EventAt := FT0 + Round((FQueued - 1) * FPeriodUs);
  while NowUs < EventAt do
  begin
    if WaitForSingleObject(AStopEvent, 0) = WAIT_OBJECT_0 then Exit(owStop);
    if EventAt - NowUs > 3000 then
    begin
      if WaitForSingleObject(AStopEvent, 1) = WAIT_OBJECT_0 then Exit(owStop);
    end
    else
      WaitUntilUs(EventAt);
  end;
  MaybeStall;
  Result := owBufferReady;
end;

function TSimWasapiOutput.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  AError := 0;
  AData := @FStage[0];
  FGetUs := NowUs;
  Result := True;
end;

procedure TSimWasapiOutput.ReleaseBuffer(AFull: Boolean);
var
  T, Deadline: Int64;
begin
  T := NowUs;
  if not AFull then Exit;
  FRec.AddFill(T - FGetUs);
  FRec.AddBuffer;
  FRec.FeedSine(@FStage[0], Length(FStage), FFormat.SampleRate, FFormat.Channels);
  if FStarted then
  begin
    { buffer FQueued starts playing at T0 + FQueued * P }
    Deadline := FT0 + Round(FQueued * FPeriodUs);
    FRec.AddMargin(Deadline - T);
    if T > Deadline then FRec.AddGlitch;
  end;
  Inc(FQueued);
end;

function TSimWasapiOutput.DrainTail: Boolean;
begin
  Result := FRec.Settings.Drain;
end;

{ as TWasapiOutput.Drain: the next event, when the silent tail starts playing }
procedure TSimWasapiOutput.Drain(AStopEvent: THandle);
var
  EventAt: Int64;
begin
  if (not FRec.Settings.Drain) or (not FStarted) then Exit;
  FTailGiven := True;
  EventAt := FT0 + Round((FQueued - 1) * FPeriodUs);
  while NowUs < EventAt do
    if WaitForSingleObject(AStopEvent, 1) = WAIT_OBJECT_0 then Exit;
end;

procedure TSimWasapiOutput.Close;
begin
  { what was queued with audio and has not played yet }
  if FStarted then
    FRec.AddCut(FT0 + Round((FQueued - Ord(FTailGiven)) * FPeriodUs) - NowUs);
  FStarted := False;
end;

{ ---- TSimDriverThread ---- }

constructor TSimDriverThread.Create(AOut: TSimAsioOutput);
begin
  FOut := AOut;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSimDriverThread.Execute;
var
  T0, N: Int64;
  Fill: Integer;
begin
  SetThreadPriority(GetCurrentThread, THREAD_PRIORITY_TIME_CRITICAL);
  T0 := NowUs;
  N := 0;
  while not Terminated do
  begin
    Inc(N);
    WaitUntilUs(T0 + Round(N * FOut.FPeriodUs));
    if Terminated then Break;
    if not FOut.FStarted then Continue;
    { the fill before the take, as margin (not while the ring plays empty on purpose) }
    Fill := FOut.FRing.Fill;
    if not FOut.FDraining then
      FOut.FRec.AddMargin(Round(Fill / FOut.FFormat.BlockAlign * 1000000.0 / FOut.FFormat.SampleRate));
    FOut.FRec.AddTaken;
    if FOut.FRing.Take(@FOut.FTake[0], not FOut.FDraining) then
    begin
      { as TAsioOutput.Switch }
      if (FOut.FFade <> nil) and FOut.FFade.Active then
        FOut.FFade.Apply(PLongInt(@FOut.FTake[0]), Length(FOut.FTake) div FOut.FFormat.BlockAlign, FOut.FFormat.Channels);
      FOut.NoteEnd;
    end
    else
    begin
      if (FOut.FFade <> nil) and FOut.FFade.Active then
        FOut.FFade.Silence(Length(FOut.FTake) div FOut.FFormat.BlockAlign);
      if not FOut.FDraining then FOut.FRec.AddGlitch;
    end;
  end;
end;

{ ---- TSimAsioOutput ---- }

destructor TSimAsioOutput.Destroy;
begin
  Close;
  FreeAndNil(FFade);
  inherited Destroy;
end;

function TSimAsioOutput.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT; out AErrorText: string): TOutputOpenResult;
var
  Periods: Integer;
begin
  Close;
  AError := 0;
  AErrorText := '';
  FFormat := Default(TAudioOutputFormat);
  FFormat.SampleRate := ARate;
  FFormat.Channels := AChannels;
  FFormat.Bits := 32;
  FFormat.ValidBits := FRec.Settings.DeviceValid;
  if AIsDoP and (FFormat.ValidBits < 24) then FFormat.ValidBits := 24;
  FFormat.BlockAlign := 4 * AChannels;
  SetLength(FStage, FRec.Settings.AsioPeriod * FFormat.BlockAlign);
  SetLength(FTake, Length(FStage));
  FPeriodUs := FRec.Settings.AsioPeriod * 1000000.0 / ARate;
  if FRec.Settings.AsioRingPeriods > 0 then Periods := FRec.Settings.AsioRingPeriods
  else Periods := RingPeriodsFor(FRec.Settings.AsioPeriod, ARate, ABufferMs);
  FRing := TOutputRing.Create(Length(FStage), Periods);
  FStarted := False;
  FDraining := False;
  FRec.SetFormat(ARate, FRec.Settings.AsioPeriod, Periods);
  FDriver := TSimDriverThread.Create(Self);
  Result := oorOK;
end;

procedure TSimAsioOutput.Start;
begin
  FStarted := True;
end;

procedure TSimAsioOutput.Stop;
begin
  FStarted := False;
end;

procedure TSimAsioOutput.Reset;
begin
  if FRing <> nil then FRing.Clear;
end;

function TSimAsioOutput.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
begin
  if FRing = nil then Exit(owBufferReady);
  Result := FRing.WaitForSpace(AStopEvent, ATimeoutMs, not FStarted);
  if Result = owBufferReady then MaybeStall;
end;

function TSimAsioOutput.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  AError := 0;
  AData := @FStage[0];
  FGetUs := NowUs;
  Result := True;
end;

procedure TSimAsioOutput.ReleaseBuffer(AFull: Boolean);
begin
  if (not AFull) or (FRing = nil) then Exit;
  FRec.AddFill(NowUs - FGetUs);
  FRec.AddBuffer;
  FRec.FeedSine(@FStage[0], Length(FStage), FFormat.SampleRate, FFormat.Channels);
  FRing.Put(@FStage[0]);
end;

{ as TAsioOutput.PrefillBuffers }
function TSimAsioOutput.PrefillBuffers: Integer;
var
  Frames: Integer;
begin
  Result := 1;
  if (not FRec.Settings.Prefill) or (FRing = nil) then Exit;
  Frames := FRec.Settings.AsioPeriod;
  Result := Integer((Int64(FFormat.SampleRate) * 40 div 1000 + Frames - 1) div Frames);
  if Result > FRing.Periods - 1 then Result := FRing.Periods - 1;
  if Result < 1 then Result := 1;
end;

{ the period the device just got: its last sample and its peak }
procedure TSimAsioOutput.NoteEnd;
var
  P: PLongInt;
  I, N: Integer;
  V, Pk: Int64;
begin
  P := PLongInt(@FTake[0]);
  N := Length(FTake) div 4;
  Pk := 0;
  for I := 0 to N - 1 do
  begin
    V := Abs(Int64(P[I]));
    if V > Pk then Pk := V;
  end;
  FRec.EndPeak := Pk;
  FRec.EndLast := Abs(Int64(P[N - FFormat.Channels]));
  FRec.EndSeen := True;
end;

{ as TAsioOutput.FadeOut }
procedure TSimAsioOutput.FadeOut;
var
  StartTick: QWord;
  Frames: Integer;
begin
  if (not FRec.Settings.Fade) or (FRing = nil) or (not FStarted) or FDraining or
     (FFormat.SampleRate = 0) or (FRing.Fill = 0) then Exit;
  if FFade = nil then FFade := TPeriodFade.Create;
  Frames := Integer((Int64(FFormat.SampleRate) * 15) div 1000);
  if Frames < FRec.Settings.AsioPeriod then Frames := FRec.Settings.AsioPeriod;
  FDraining := True;
  FFade.Start(Frames);
  StartTick := GetTickCount64;
  while (FFade.SilentFrames < Integer((Int64(FFormat.SampleRate) * 40) div 1000)) and
        (GetTickCount64 - StartTick < 250) do
    Sleep(1);
end;

{ as TAsioOutput.Drain }
procedure TSimAsioOutput.Drain(AStopEvent: THandle);
var
  StartTick, LimitMs: QWord;
  PeriodMs: Cardinal;
begin
  if (not FRec.Settings.Drain) or (FRing = nil) or (not FStarted) then Exit;
  PeriodMs := Round(FPeriodUs / 1000) + 2;
  LimitMs := QWord(FRing.Periods) * PeriodMs + 500;
  FDraining := True;   // until Close, as TAsioOutput
  StartTick := GetTickCount64;
  while (FRing.Fill > 0) and (GetTickCount64 - StartTick < LimitMs) do
    if WaitForSingleObject(AStopEvent, 2) = WAIT_OBJECT_0 then Exit;
  WaitForSingleObject(AStopEvent, PeriodMs);
end;

procedure TSimAsioOutput.Close;
begin
  { what is still in the ring is not played }
  if FStarted and (FRing <> nil) and (FFormat.SampleRate > 0) then
    FRec.AddCut(Round(FRing.Fill / FFormat.BlockAlign * 1000000.0 / FFormat.SampleRate));
  FStarted := False;
  if FDriver <> nil then
  begin
    FDriver.Terminate;
    FDriver.WaitFor;
    FreeAndNil(FDriver);
  end;
  FreeAndNil(FRing);
end;

{ ---- TRealWasapiProbe ---- }

constructor TRealWasapiProbe.Create(ARec: TSimRecorder);
begin
  inherited Create;
  FRec := ARec;
end;

function TRealWasapiProbe.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT; out AErrorText: string): TOutputOpenResult;
var
  F: TAudioOutputFormat;
begin
  FStopSeen := False;
  Result := inherited Open(ADeviceId, ARate, AChannels, AIsDoP, ABufferMs, AError, AErrorText);
  if Result = oorOK then
  begin
    F := Format;
    FRec.SetFormat(ARate, BufferBytes div Max(1, Integer(F.BlockAlign)), 2);
    FRec.SetDeviceInfo(False, F.ValidBits);
    FRec.AddOpen(Result, 0, BufferedMs);
  end
  else
    FRec.AddOpen(Result, AError, 0);
end;

function TRealWasapiProbe.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
begin
  Result := inherited WaitForBuffer(AStopEvent, ATimeoutMs);
  if Result = owBufferReady then
    FRec.MaybeStall
  else if (Result = owStop) and (not FStopSeen) then
  begin
    FStopSeen := True;
    FDropsAtStop := DropoutCount;
  end;
end;

function TRealWasapiProbe.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  Result := inherited GetBuffer(AData, AError);
  FGetUs := NowUs;
end;

procedure TRealWasapiProbe.ReleaseBuffer(AFull: Boolean);
begin
  if AFull then
  begin
    FRec.AddFill(NowUs - FGetUs);
    FRec.AddBuffer;
  end;
  inherited ReleaseBuffer(AFull);
end;

procedure TRealWasapiProbe.Close;
var
  N: Integer;
begin
  if DropoutCount >= 0 then
  begin
    if FStopSeen then N := FDropsAtStop else N := DropoutCount;
    FRec.AddGlitches(N);
    if LeastBufferedMs >= 0 then FRec.AddMargin(Int64(LeastBufferedMs) * 1000);
  end;
  inherited Close;
end;

{ ---- TRealAsioProbe ---- }

constructor TRealAsioProbe.Create(ARec: TSimRecorder);
begin
  inherited Create(ARec.Settings.NativeDsd);
  FRec := ARec;
end;

function TRealAsioProbe.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT; out AErrorText: string): TOutputOpenResult;
var
  BufMs: Integer;
  F: TAudioOutputFormat;
begin
  { ring=N: the ring before the fix (RingPeriodsFor makes 3 periods of 1 ms) }
  if FRec.Settings.AsioRingPeriods > 0 then BufMs := 1 else BufMs := ABufferMs;
  FStopSeen := False;
  Result := inherited Open(ADeviceId, ARate, AChannels, AIsDoP, BufMs, AError, AErrorText);
  if (Result = oorOK) and AIsDoP and (not NativeDsd) and (not FRec.Settings.AllowDoP) then
  begin
    inherited Close;
    AErrorText := 'probe: the driver refused native DSD; DoP as PCM not allowed (--allowdop=1)';
    FRec.AddOpen(oorFormatUnsupported, 0, 0);
    Exit(oorFormatUnsupported);
  end;
  if Result = oorOK then
  begin
    F := Format;
    FRec.SetFormat(ARate, BufferBytes div Max(1, Integer(F.BlockAlign)), RingPeriods);
    FRec.SetDeviceInfo(NativeDsd, F.ValidBits);
    FRec.AddOpen(Result, 0, BufferedMs);
  end
  else
    FRec.AddOpen(Result, AError, 0);
end;

function TRealAsioProbe.PrefillBuffers: Integer;
begin
  if FRec.Settings.Prefill then Result := inherited PrefillBuffers
  else Result := 1;
end;

procedure TRealAsioProbe.Drain(AStopEvent: THandle);
begin
  if FRec.Settings.Drain then inherited Drain(AStopEvent);
end;

function TRealAsioProbe.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
begin
  Result := inherited WaitForBuffer(AStopEvent, ATimeoutMs);
  if Result = owBufferReady then
    FRec.MaybeStall
  else if (Result = owStop) and (not FStopSeen) then
  begin
    { the run is over: what follows (the stop) is no underrun }
    FStopSeen := True;
    FUnderrunsAtStop := Underruns;
  end;
end;

function TRealAsioProbe.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  Result := inherited GetBuffer(AData, AError);
  FGetUs := NowUs;
end;

procedure TRealAsioProbe.ReleaseBuffer(AFull: Boolean);
begin
  if AFull then
  begin
    FRec.AddFill(NowUs - FGetUs);
    FRec.AddBuffer;
  end;
  inherited ReleaseBuffer(AFull);
end;

procedure TRealAsioProbe.Close;
var
  F: TAudioOutputFormat;
  N, MinF: Integer;
begin
  if RingPeriods > 0 then
  begin
    F := Format;
    if FStopSeen then N := FUnderrunsAtStop else N := Underruns;
    FRec.AddGlitches(N);
    MinF := RingMinFill;
    if (F.BlockAlign > 0) and (F.SampleRate > 0) then
    begin
      if MinF >= 0 then
        FRec.AddMargin(Round(MinF / F.BlockAlign * 1000000.0 / F.SampleRate));
      FRec.AddCut(Round(RingFill / F.BlockAlign * 1000000.0 / F.SampleRate));
    end;
  end;
  inherited Close;
end;

initialization
  QueryPerformanceFrequency(QpcFreq);
  timeBeginPeriod(1);

finalization
  timeEndPeriod(1);

end.
