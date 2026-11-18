unit TestMemoryOutput;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestMemoryOutput
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  ---> ADDED (output split, step 3a): An output device for the playback tests
  (TestPlayback). TMemoryOutput is a TAudioOutput (ALAudioOutput) that keeps
  every buffer the play thread hands over in memory instead of playing it, and
  asks for the next buffer at once (no real time: seconds of audio play in
  milliseconds). The play thread gets it through TPlayThread.OutputFactory
  (TMemoryOutputRecorder.CreateOutput).

  TMemoryOutputRecorder belongs to the test. It sets how the "device" behaves
  (its bit depth, rates it refuses, opens that fail, a buffer that is lost,
  a hold after some buffers so the test can seek or queue the next track at
  a known point) and records what the play thread did (every open with its
  format and where its data starts, Start / Stop / Reset, the data of every
  full buffer, outputs made and freed). The play thread makes a new output for
  each open (rate switch, recovery); all of them write to the one recorder.
  Thread-safe: the play thread writes, the test reads while the thread holds
  or after it has ended.

  ---> CHANGED (ObjFPC switch, step 1): ObjFPC like ALAudioOutput (device id
  and error text are UTF-8 strings).
  =============================================================================}

interface

uses
  Classes, SysUtils, Windows, ALAudioOutput;

const
  // The message of a refused rate (oorFormatUnsupported) and of oorFailed
  MEMORY_OUTPUT_REFUSED_TEXT = 'Memory output: format refused';
  // The error code of a lost buffer (as AUDCLNT_E_DEVICE_INVALIDATED)
  MEMORY_OUTPUT_LOST_HR = HRESULT($88890004);

type
  TMemoryOutputRecorder = class;

  // One Open call of the play thread
  TRecordedOpen = record
    Rate      : Cardinal;
    Channels  : Word;
    IsDoP     : Boolean;
    BufferMs  : Integer;
    Result    : TOutputOpenResult;
    Format    : TAudioOutputFormat;  // oorOK only
    DataStart : Int64;               // bytes recorded before this open
  end;

  { TMemoryOutput }
  TMemoryOutput = class(TAudioOutput)
  private
    FRecorder : TMemoryOutputRecorder;
    FFormat   : TAudioOutputFormat;
    FBuffer   : TBytes;
    FIsOpen   : Boolean;
  public
    constructor Create(ARecorder: TMemoryOutputRecorder);
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
  end;

  { TMemoryOutputRecorder }
  TMemoryOutputRecorder = class
  private
    FLock          : TRTLCriticalSection;
    FData          : TMemoryStream;
    FOpens         : array of TRecordedOpen;
    FFailures      : array of TOutputOpenResult;  // the next opens' results, in order
    FNextFailure   : Integer;
    FRefusedRates  : array of Cardinal;
    FDeviceBits    : Word;
    FDeviceValid   : Word;
    FStarts        : Integer;
    FStops         : Integer;
    FResets        : Integer;
    FResetDataPos  : Int64;
    FCloses        : Integer;
    FBuffersFull   : Integer;   // ReleaseBuffer(True)
    FBuffersEmpty  : Integer;   // ReleaseBuffer(False)
    FGetBufferCalls: Integer;
    FLoseBufferAt  : Integer;   // GetBuffer call number that fails (0 = none)
    FHoldAfter     : Integer;   // hold once after this many full buffers (0 = never)
    FHoldDone      : Boolean;
    FHeldEvent     : THandle;   // set while the play thread holds
    FGoOnEvent     : THandle;   // set by GoOn
    FOutputsMade   : Integer;
    FOutputsAlive  : Integer;

    // TMemoryOutput's calls (play thread)
    function  OpenResultFor(ARate: Cardinal; AIsDoP: Boolean; out AErrorText: string): TOutputOpenResult;
    procedure RecordOpen(const AOpen: TRecordedOpen);
    procedure CountCall(var ACounter: Integer);
    procedure RecordReset;
    function  NextGetBufferFails: Boolean;
    procedure RecordBuffer(const ABuffer: TBytes; AFull: Boolean);
    function  HoldNow: Boolean;
    procedure OutputMade;
    procedure OutputFreed;
    function  GetInt(var AValue: Integer): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    // ---- Settings (before the play thread starts) ----
    // The bit depth the device opens with (container / valid); default 32 / 32
    procedure SetDeviceBits(ABits, AValidBits: Word);
    // Open returns these results in order before it succeeds again
    procedure FailNextOpens(const AResults: array of TOutputOpenResult);
    // Open refuses this rate (oorFormatUnsupported)
    procedure RefuseRate(ARate: Cardinal);
    // The ANumber-th GetBuffer call fails once (the device "drops out")
    procedure LoseBuffer(ANumber: Integer);
    // After ACount full buffers the next WaitForBuffer holds until GoOn (or
    // the stop event, or 10 s); once
    procedure HoldAfterBuffers(ACount: Integer);

    // The TAudioOutputFactory for TPlayThread.OutputFactory (play thread)
    function  CreateOutput: TAudioOutput;

    // ---- While the play thread runs ----
    function  WaitUntilHeld(ATimeoutMs: Cardinal): Boolean;
    procedure GoOn;

    // ---- Results ----
    function  Data: TBytes;           // a copy of every full buffer, in order
    function  OpenCount: Integer;
    function  Opens(AIndex: Integer): TRecordedOpen;
    function  Starts: Integer;
    function  Stops: Integer;
    function  Resets: Integer;
    function  ResetDataPos: Int64;    // bytes recorded at the last Reset (-1 = none)
    function  Closes: Integer;
    function  BuffersFull: Integer;
    function  BuffersEmpty: Integer;
    function  OutputsMade: Integer;
    function  OutputsAlive: Integer;  // made and not freed yet
  end;

implementation

{ TMemoryOutput }

constructor TMemoryOutput.Create(ARecorder: TMemoryOutputRecorder);
begin
  inherited Create;
  FRecorder := ARecorder;
  FRecorder.OutputMade;
end;

destructor TMemoryOutput.Destroy;
begin
  Close;
  FRecorder.OutputFreed;
  inherited Destroy;
end;

function TMemoryOutput.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
  out AErrorText: string): TOutputOpenResult;
var
  Rec: TRecordedOpen;
  Frames: Integer;
begin
  Close;
  AError     := 0;
  AErrorText := '';
  FFormat    := Default(TAudioOutputFormat);

  Result := FRecorder.OpenResultFor(ARate, AIsDoP, AErrorText);
  if Result = oorOK then
  begin
    // The device bits are set before the play thread starts (no lock needed)
    FFormat.SampleRate := ARate;
    FFormat.Channels   := AChannels;
    FFormat.Bits       := FRecorder.FDeviceBits;
    FFormat.ValidBits  := FRecorder.FDeviceValid;
    FFormat.BlockAlign := AChannels * (FFormat.Bits div 8);

    // About ABufferMs of audio per buffer, as WASAPI
    Frames := Integer((Int64(ARate) * ABufferMs) div 1000);
    if Frames < 1 then
      Frames := 1;
    SetLength(FBuffer, Frames * FFormat.BlockAlign);
    FIsOpen := True;
  end
  else
    AError := E_FAIL;

  Rec          := Default(TRecordedOpen);
  Rec.Rate     := ARate;
  Rec.Channels := AChannels;
  Rec.IsDoP    := AIsDoP;
  Rec.BufferMs := ABufferMs;
  Rec.Result   := Result;
  Rec.Format   := FFormat;
  FRecorder.RecordOpen(Rec);
end;

function TMemoryOutput.Format: TAudioOutputFormat;
begin
  Result := FFormat;
end;

function TMemoryOutput.BufferBytes: Integer;
begin
  Result := Length(FBuffer);
end;

procedure TMemoryOutput.Start;
begin
  FRecorder.CountCall(FRecorder.FStarts);
end;

procedure TMemoryOutput.Stop;
begin
  FRecorder.CountCall(FRecorder.FStops);
end;

procedure TMemoryOutput.Reset;
begin
  FRecorder.RecordReset;
end;

function TMemoryOutput.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
var
  Events: array[0..1] of THandle;
begin
  if WaitForSingleObject(AStopEvent, 0) = WAIT_OBJECT_0 then
    Exit(owStop);

  if FRecorder.HoldNow then
  begin
    SetEvent(FRecorder.FHeldEvent);
    Events[0] := AStopEvent;
    Events[1] := FRecorder.FGoOnEvent;
    // 10 s at most: a test that fails before GoOn must not hang the run
    if WaitForMultipleObjects(2, @Events[0], False, 10000) = WAIT_OBJECT_0 then
      Exit(owStop);
  end;

  // The "device" always wants the next buffer at once
  Result := owBufferReady;
end;

function TMemoryOutput.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  AData  := nil;
  AError := 0;
  if (not FIsOpen) or (Length(FBuffer) = 0) or FRecorder.NextGetBufferFails then
  begin
    AError := MEMORY_OUTPUT_LOST_HR;
    Exit(False);
  end;
  AData := @FBuffer[0];
  Result := True;
end;

procedure TMemoryOutput.ReleaseBuffer(AFull: Boolean);
begin
  FRecorder.RecordBuffer(FBuffer, AFull);
end;

procedure TMemoryOutput.Close;
begin
  if not FIsOpen then
    Exit;
  FIsOpen := False;
  FBuffer := nil;
  FRecorder.CountCall(FRecorder.FCloses);
end;

{ TMemoryOutputRecorder }

constructor TMemoryOutputRecorder.Create;
begin
  inherited Create;
  InitializeCriticalSection(FLock);
  FData         := TMemoryStream.Create;
  FDeviceBits   := 32;
  FDeviceValid  := 32;
  FResetDataPos := -1;
  FHeldEvent    := CreateEvent(nil, True, False, nil);
  FGoOnEvent    := CreateEvent(nil, True, False, nil);
end;

destructor TMemoryOutputRecorder.Destroy;
begin
  CloseHandle(FHeldEvent);
  CloseHandle(FGoOnEvent);
  FData.Free;
  DeleteCriticalSection(FLock);
  inherited Destroy;
end;

procedure TMemoryOutputRecorder.SetDeviceBits(ABits, AValidBits: Word);
begin
  FDeviceBits  := ABits;
  FDeviceValid := AValidBits;
end;

procedure TMemoryOutputRecorder.FailNextOpens(const AResults: array of TOutputOpenResult);
var
  I: Integer;
begin
  SetLength(FFailures, Length(AResults));
  for I := 0 to High(AResults) do
    FFailures[I] := AResults[I];
  FNextFailure := 0;
end;

procedure TMemoryOutputRecorder.RefuseRate(ARate: Cardinal);
begin
  SetLength(FRefusedRates, Length(FRefusedRates) + 1);
  FRefusedRates[High(FRefusedRates)] := ARate;
end;

procedure TMemoryOutputRecorder.LoseBuffer(ANumber: Integer);
begin
  FLoseBufferAt := ANumber;
end;

procedure TMemoryOutputRecorder.HoldAfterBuffers(ACount: Integer);
begin
  FHoldAfter := ACount;
  FHoldDone  := False;
  ResetEvent(FHeldEvent);
  ResetEvent(FGoOnEvent);
end;

function TMemoryOutputRecorder.CreateOutput: TAudioOutput;
begin
  Result := TMemoryOutput.Create(Self);
end;

function TMemoryOutputRecorder.WaitUntilHeld(ATimeoutMs: Cardinal): Boolean;
begin
  Result := WaitForSingleObject(FHeldEvent, ATimeoutMs) = WAIT_OBJECT_0;
end;

procedure TMemoryOutputRecorder.GoOn;
begin
  SetEvent(FGoOnEvent);
end;

function TMemoryOutputRecorder.OpenResultFor(ARate: Cardinal; AIsDoP: Boolean;
  out AErrorText: string): TOutputOpenResult;
var
  I: Integer;
begin
  AErrorText := '';
  EnterCriticalSection(FLock);
  try
    if FNextFailure <= High(FFailures) then
    begin
      Result := FFailures[FNextFailure];
      Inc(FNextFailure);
      if Result in [oorFormatUnsupported, oorFailed] then
        AErrorText := MEMORY_OUTPUT_REFUSED_TEXT;
      Exit;
    end;

    // DoP needs at least 24 bits (as TWasapiOutput never opens it below)
    if AIsDoP and (FDeviceBits < 24) then
    begin
      AErrorText := MEMORY_OUTPUT_REFUSED_TEXT;
      Exit(oorFormatUnsupported);
    end;

    for I := 0 to High(FRefusedRates) do
      if FRefusedRates[I] = ARate then
      begin
        AErrorText := MEMORY_OUTPUT_REFUSED_TEXT;
        Exit(oorFormatUnsupported);
      end;

    Result := oorOK;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOutputRecorder.RecordOpen(const AOpen: TRecordedOpen);
begin
  EnterCriticalSection(FLock);
  try
    SetLength(FOpens, Length(FOpens) + 1);
    FOpens[High(FOpens)]           := AOpen;
    FOpens[High(FOpens)].DataStart := FData.Size;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOutputRecorder.CountCall(var ACounter: Integer);
begin
  EnterCriticalSection(FLock);
  try
    Inc(ACounter);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOutputRecorder.RecordReset;
begin
  EnterCriticalSection(FLock);
  try
    Inc(FResets);
    FResetDataPos := FData.Size;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.NextGetBufferFails: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Inc(FGetBufferCalls);
    Result := (FLoseBufferAt > 0) and (FGetBufferCalls = FLoseBufferAt);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOutputRecorder.RecordBuffer(const ABuffer: TBytes; AFull: Boolean);
begin
  EnterCriticalSection(FLock);
  try
    if AFull then
    begin
      Inc(FBuffersFull);
      if Length(ABuffer) > 0 then
        FData.WriteBuffer(ABuffer[0], Length(ABuffer));
    end
    else
      Inc(FBuffersEmpty);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.HoldNow: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := (FHoldAfter > 0) and (not FHoldDone) and (FBuffersFull >= FHoldAfter);
    if Result then
      FHoldDone := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOutputRecorder.OutputMade;
begin
  EnterCriticalSection(FLock);
  try
    Inc(FOutputsMade);
    Inc(FOutputsAlive);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOutputRecorder.OutputFreed;
begin
  EnterCriticalSection(FLock);
  try
    Dec(FOutputsAlive);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.GetInt(var AValue: Integer): Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := AValue;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.Data: TBytes;
begin
  EnterCriticalSection(FLock);
  try
    Result := nil;
    SetLength(Result, FData.Size);
    if FData.Size > 0 then
      Move(FData.Memory^, Result[0], FData.Size);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.OpenCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := Length(FOpens);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.Opens(AIndex: Integer): TRecordedOpen;
begin
  EnterCriticalSection(FLock);
  try
    Result := FOpens[AIndex];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.Starts: Integer;
begin
  Result := GetInt(FStarts);
end;

function TMemoryOutputRecorder.Stops: Integer;
begin
  Result := GetInt(FStops);
end;

function TMemoryOutputRecorder.Resets: Integer;
begin
  Result := GetInt(FResets);
end;

function TMemoryOutputRecorder.ResetDataPos: Int64;
begin
  EnterCriticalSection(FLock);
  try
    Result := FResetDataPos;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMemoryOutputRecorder.Closes: Integer;
begin
  Result := GetInt(FCloses);
end;

function TMemoryOutputRecorder.BuffersFull: Integer;
begin
  Result := GetInt(FBuffersFull);
end;

function TMemoryOutputRecorder.BuffersEmpty: Integer;
begin
  Result := GetInt(FBuffersEmpty);
end;

function TMemoryOutputRecorder.OutputsMade: Integer;
begin
  Result := GetInt(FOutputsMade);
end;

function TMemoryOutputRecorder.OutputsAlive: Integer;
begin
  Result := GetInt(FOutputsAlive);
end;

end.
