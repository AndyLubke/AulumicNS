unit ALOutputWasapi;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALOutputWasapi
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TWasapiOutput: the TAudioOutput (ALAudioOutput) of a WASAPI exclusive-mode
  stream in event-driven mode.
  ---> CHANGED (step 2b): Open does what TPlayThread.RunWasapi did before:
  the device enumerator, the configured device (only when active), the
  format check (32/32, 32/24, 24/24, 16/16; never below 24 bits for DoP),
  Initialize with the retry for a buffer duration that is not aligned, then
  the event, the buffer size and the render client. The same calls in the
  same order; a failure is reported by kind (TOutputOpenResult), the play
  thread does the waits and retries. Called on the play thread (COM is
  initialized there).
  ---> CHANGED (ObjFPC switch, step 1): ObjFPC like the rest of Aulumic; the
  UTF-8 device id becomes UTF-16 only for IMMDeviceEnumerator.GetDevice.
  ============================================================================}

interface

uses
  Windows, ActiveX, ComObj, ALWasapiApi, ALAudioOutput;

type
  { TWasapiOutput }
  TWasapiOutput = class(TAudioOutput)
  private
    FClient : IAudioClient;
    FRender : IAudioRenderClient;
    FEvent  : THandle;
    FFrames : UInt32;              // buffer size in frames (GetBufferSize)
    FFormat : TAudioOutputFormat;
    // ---> AulumicNS: the diagnostics (DropoutCount / LeastBufferedMs). At an
    // event the device starts the buffer released last; the next one must be
    // released within one period (FPeriodUs) of the event.
    FPeriodUs : Int64;
    FEventUs  : Int64;             // the event the buffer being filled answers (0 = none)
    FLate     : Integer;           // buffers released after their play start
    FLeastUs  : Int64;             // the least time to spare (High(Int64) = none yet)
  public
    destructor Destroy; override;

    function Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
      AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
      out AErrorText: string): TOutputOpenResult; override;
    function Format: TAudioOutputFormat; override;
    function BufferBytes: Integer; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Reset; override;
    function WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait; override;
    function GetBuffer(out AData: PByte; out AError: HRESULT): Boolean; override;
    procedure ReleaseBuffer(AFull: Boolean); override;
    procedure Close; override;
    // ---> AulumicNS: the last buffer plays to its end (see TAudioOutput)
    function DrainTail: Boolean; override;
    procedure Drain(AStopEvent: THandle); override;
    function DropoutCount: Integer; override;
    function LeastBufferedMs: Integer; override;
    function BufferedMs: Integer; override;
  end;

implementation

uses
  uAppStrings, uOSUtils;

const
  SHAREMODE_EXCLUSIVE        = 1;          // AUDCLNT_SHAREMODE_EXCLUSIVE
  STREAMFLAGS_EVENTCALLBACK  = $00040000;  // AUDCLNT_STREAMFLAGS_EVENTCALLBACK
  MIN_BUFFER_HNS             = 50 * 10000; // ---> AulumicNS: the shortest buffer Open falls back to (50 ms)

{ TWasapiOutput }

destructor TWasapiOutput.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TWasapiOutput.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
  out AErrorText: string): TOutputOpenResult;
var
  EnumObj        : IMMDeviceEnumerator;
  Dev            : IMMDevice;
  WideId         : UnicodeString;  // ---> ADDED (ObjFPC switch): for GetDevice
  AC             : IAudioClient;
  WfxExt         : WAVEFORMATEXTENSIBLE;
  HR             : HRESULT;
  DevState       : DWORD;
  ClosestMatch   : PWAVEFORMATEX;
  TestDepths     : array[0..3] of Word;  // container bits
  TestValid      : array[0..3] of Word;  // valid bits
  DepthIndex     : Integer;
  FormatAccepted : Boolean;
  BufferDuration : Int64;

  { ---> AulumicNS: Initialize with ADuration as period and buffer (as
    before, with the retry for a size the device wants aligned). AFresh: a
    new IAudioClient first (one that failed to initialize cannot be used again). }
  function InitStream(ADuration: Int64; AFresh: Boolean): HRESULT;
  var
    BFC: UInt32;
  begin
    if AFresh then
    begin
      AC := nil;
      Dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, IUnknown(AC));
      if not Assigned(AC) then
        Exit(AUDCLNT_E_DEVICE_INVALIDATED);
    end;
    Result := AC.Initialize(SHAREMODE_EXCLUSIVE, STREAMFLAGS_EVENTCALLBACK, ADuration,
                            ADuration, @WfxExt.Format, nil);
    if Result = AUDCLNT_E_BUFDURATION_PERIOD_NOT_ALIGNED then
    begin
      BFC := 0;
      if Succeeded(AC.GetBufferSize(BFC)) and (BFC > 0) then
      begin
        ADuration := Round((10000000.0 * BFC / WfxExt.Format.nSamplesPerSec) + 0.5);
        AC := nil;
        Dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, IUnknown(AC));
        if Assigned(AC) then
          Result := AC.Initialize(SHAREMODE_EXCLUSIVE, STREAMFLAGS_EVENTCALLBACK, ADuration,
                                  ADuration, @WfxExt.Format, nil);
      end;
    end;
  end;

begin
  Close;
  AError     := 0;
  AErrorText := '';
  FFormat    := Default(TAudioOutputFormat);

  HR := CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, EnumObj);
  if Failed(HR) or (not Assigned(EnumObj)) then
  begin
    AError := HR;
    Exit(oorEndpointFail);
  end;

  // ---> Device availability: never fall back to another device when the
  // configured DAC is missing, and only use it when it is active (not
  // switched off / unplugged). The play thread waits for it during a recovery.
  Dev      := nil;
  AC       := nil;
  DevState := 0;

  if ADeviceId <> '' then
  begin
    // ---> CHANGED (ObjFPC switch): the UTF-8 id as UTF-16 (was a cast to
    // WideString of the UTF-16 id)
    WideId := UTF8Decode(ADeviceId);
    HR     := EnumObj.GetDevice(PWideChar(WideId), Dev);
  end
  else
    HR := EnumObj.GetDefaultAudioEndpoint(0, 0, Dev);

  if Succeeded(HR) and Assigned(Dev) and Succeeded(Dev.GetState(DevState)) and
     (DevState = DEVICE_STATE_ACTIVE) then
    HR := Dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, IUnknown(AC));

  if (not Succeeded(HR)) or (not Assigned(AC)) then
  begin
    AError := HR;
    Exit(oorNoDevice);
  end;

  WfxExt := Default(WAVEFORMATEXTENSIBLE);

  WfxExt.Format.wFormatTag     := WAVE_FORMAT_EXTENSIBLE;
  WfxExt.Format.nChannels      := AChannels;
  WfxExt.Format.nSamplesPerSec := ARate;

  FormatAccepted := False;
  ClosestMatch   := nil;

  // ---> AUDIT FIX: Also offer 24 valid bits in a 32-bit container. Some
  // interfaces accept only this layout and previously fell back to 24-bit
  // packed or 16-bit. Order: 32/32, 32/24, 24/24, 16/16.
  TestDepths[0]  := 32;  TestValid[0] := 32;
  TestDepths[1]  := 32;  TestValid[1] := 24;
  TestDepths[2]  := 24;  TestValid[2] := 24;
  TestDepths[3]  := 16;  TestValid[3] := 16;

  for DepthIndex := 0 to 3 do
  begin
    // ---> AUDIT FIX (DoP 16-Bit Gate): Native DoP requires at least 24-bit
    // samples (8-bit DoP marker + 16-bit DSD payload). Never negotiate 16-bit DoP!
    if AIsDoP and (TestDepths[DepthIndex] < 24) then
      Continue;

    WfxExt.Format.wBitsPerSample  := TestDepths[DepthIndex];
    WfxExt.wValidBitsPerSample    := TestValid[DepthIndex];
    WfxExt.Format.nBlockAlign     := (WfxExt.Format.nChannels * WfxExt.Format.wBitsPerSample) div 8;
    WfxExt.Format.nAvgBytesPerSec := WfxExt.Format.nSamplesPerSec * WfxExt.Format.nBlockAlign;

    WfxExt.Format.cbSize := 22;
    if WfxExt.Format.nChannels = 2 then
      WfxExt.dwChannelMask := 3
    else
      WfxExt.dwChannelMask := 0;
    WfxExt.SubFormat := KSDATAFORMAT_SUBTYPE_PCM;

    HR := AC.IsFormatSupported(SHAREMODE_EXCLUSIVE, @WfxExt.Format, ClosestMatch);

    if ClosestMatch <> nil then
    begin
      CoTaskMemFree(ClosestMatch);
      ClosestMatch := nil;
    end;

    // The device disappeared or reset its stream meanwhile: not a sample
    // rate problem (the play thread waits and tries again during a recovery)
    if (HR = AUDCLNT_E_DEVICE_INVALIDATED) or (HR = AUDCLNT_E_RESOURCES_INVALIDATED) then
    begin
      AError := HR;
      Exit(oorLostWhileChecking);
    end;

    if HR = S_OK then
    begin
      FormatAccepted := True;
      Break;
    end;
  end;

  if not FormatAccepted then
  begin
    AError     := HR;
    AErrorText := GetWasapiErrorString(AUDCLNT_E_UNSUPPORTED_FORMAT);
    Exit(oorFormatUnsupported);
  end;

  BufferDuration := Int64(ABufferMs) * 10000;
  HR := InitStream(BufferDuration, False);

  // ---> AulumicNS: a driver that refuses so long a period gets a shorter
  // one, down to MIN_BUFFER_HNS. Event-driven exclusive streams have one
  // period of the whole buffer, and drivers may cap it. A safety net: a
  // FiiO K11 takes even 1000 ms at 384 kHz and for DoP DSD128 (measured);
  // the user's failure there was the endpoint gone after native DSD over
  // ASIO (TPlayThreadConfig.SettleMs).
  // Not for a device in use or gone, nor for a format it does not take.
  while (HR <> 0) and (HR <> AUDCLNT_E_DEVICE_IN_USE) and (HR <> HRESULT_RESOURCE_IN_USE) and
        (HR <> AUDCLNT_E_DEVICE_INVALIDATED) and (HR <> AUDCLNT_E_RESOURCES_INVALIDATED) and
        (HR <> AUDCLNT_E_UNSUPPORTED_FORMAT) and (BufferDuration > MIN_BUFFER_HNS) do
  begin
    BufferDuration := BufferDuration div 2;
    if BufferDuration < MIN_BUFFER_HNS then
      BufferDuration := MIN_BUFFER_HNS;
    HR := InitStream(BufferDuration, True);
  end;

  if HR <> 0 then
  begin
    AError := HR;
    case HR of
      AUDCLNT_E_DEVICE_IN_USE,
      HRESULT_RESOURCE_IN_USE:
        Result := oorInUse;
      AUDCLNT_E_DEVICE_INVALIDATED,
      AUDCLNT_E_RESOURCES_INVALIDATED:
        Result := oorLostWhileStarting;
    else
      begin
        AErrorText := GetWasapiErrorString(HR) +
          SafeFormat(FMT_ERR_ATTEMPTED_FORMAT, [Integer(ARate), WfxExt.Format.wBitsPerSample]);
        Result := oorFailed;
      end;
    end;
    Exit;
  end;

  FClient := AC;
  FFormat.SampleRate := WfxExt.Format.nSamplesPerSec;
  FFormat.Channels   := WfxExt.Format.nChannels;
  FFormat.Bits       := WfxExt.Format.wBitsPerSample;
  FFormat.ValidBits  := WfxExt.wValidBitsPerSample;
  FFormat.BlockAlign := WfxExt.Format.nBlockAlign;

  // The event the device signals for each buffer, the buffer size, the
  // render client (as RunWasapi did after Initialize)
  FFrames := 0;
  FEvent  := CreateEvent(nil, False, False, nil);
  FClient.SetEventHandle(FEvent);
  FClient.GetBufferSize(FFrames);
  FClient.GetService(IID_IAudioRenderClient, IUnknown(FRender));

  FPeriodUs := 0;
  if FFormat.SampleRate > 0 then
    FPeriodUs := (Int64(FFrames) * 1000000) div FFormat.SampleRate;
  FEventUs := 0;
  FLate    := 0;
  FLeastUs := High(Int64);

  Result := oorOK;
end;

function TWasapiOutput.Format: TAudioOutputFormat;
begin
  Result := FFormat;
end;

function TWasapiOutput.BufferBytes: Integer;
begin
  Result := Integer(FFrames) * FFormat.BlockAlign;
end;

procedure TWasapiOutput.Start;
begin
  FClient.Start;
end;

procedure TWasapiOutput.Stop;
begin
  FClient.Stop;
  FEventUs := 0;
end;

procedure TWasapiOutput.Reset;
begin
  FClient.Reset;
  FEventUs := 0;
end;

function TWasapiOutput.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
var
  Events: array[0..1] of THandle;
begin
  Events[0] := AStopEvent;
  Events[1] := FEvent;
  case WaitForMultipleObjects(2, @Events[0], False, ATimeoutMs) of
    WAIT_OBJECT_0     : Result := owStop;
    WAIT_OBJECT_0 + 1 :
      begin
        Result   := owBufferReady;
        FEventUs := OutputNowUs;
      end;
    WAIT_TIMEOUT      : Result := owTimeout;
  else
    Result := owFailed;
  end;
end;

function TWasapiOutput.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  AData  := nil;
  AError := FRender.GetBuffer(FFrames, AData);
  Result := AError = 0;
end;

procedure TWasapiOutput.ReleaseBuffer(AFull: Boolean);
var
  Spare: Int64;
begin
  if AFull then
    FRender.ReleaseBuffer(FFrames, 0)
  else
    FRender.ReleaseBuffer(0, 0);
  { ---> AulumicNS: the time to spare of a buffer that answers an event }
  if AFull and (FEventUs <> 0) and (FPeriodUs > 0) then
  begin
    Spare := FPeriodUs - (OutputNowUs - FEventUs);
    if Spare < FLeastUs then FLeastUs := Spare;
    if Spare < 0 then Inc(FLate);
  end;
  FEventUs := 0;
end;

function TWasapiOutput.BufferedMs: Integer;
begin
  if (FClient = nil) or (FFormat.SampleRate = 0) then Result := -1
  else Result := Integer((Int64(FFrames) * 1000) div FFormat.SampleRate);
end;

function TWasapiOutput.DropoutCount: Integer;
begin
  if FClient = nil then Result := -1 else Result := FLate;
end;

function TWasapiOutput.LeastBufferedMs: Integer;
begin
  if (FClient = nil) or (FLeastUs = High(Int64)) then Result := -1
  else if FLeastUs < 0 then Result := 0
  else Result := Integer(FLeastUs div 1000);
end;

function TWasapiOutput.DrainTail: Boolean;
begin
  Result := True;
end;

{ the event came when the last buffer with music started playing, and the
  play thread has just released a silent one after it: the next event comes
  when the last buffer has played (one period) }
procedure TWasapiOutput.Drain(AStopEvent: THandle);
var
  Events: array[0..1] of THandle;
  PeriodMs: Cardinal;
begin
  if (FClient = nil) or (FEvent = 0) or (FFormat.SampleRate = 0) then Exit;
  PeriodMs := Cardinal((Int64(FFrames) * 1000) div FFormat.SampleRate);
  Events[0] := AStopEvent;
  Events[1] := FEvent;
  WaitForMultipleObjects(2, @Events[0], False, 2 * PeriodMs + 100);
end;

procedure TWasapiOutput.Close;
begin
  if Assigned(FClient) then
    FClient.Stop;
  if FEvent <> 0 then
  begin
    CloseHandle(FEvent);
    FEvent := 0;
  end;
  FRender := nil;
  FClient := nil;
  FFrames := 0;
end;

end.
