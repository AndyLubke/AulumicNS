unit ALOutputRing;

{$mode ObjFPC}{$H+}
{$R-}{$Q-}

{ ==============================================================================
  AulumicNS - ALOutputRing
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The ring between the play thread and a device that pulls
  whole periods on its own thread (the ASIO driver's bufferSwitch; the
  simulated driver of Tools\AudioSim). A unit of its own, so the
  simulation runs the same code as TAsioOutput.

  The play thread waits for room for one period (WaitForSpace), fills a
  period and puts it in (Put); the device thread takes one period per call
  (Take) and counts an underrun when none is there. Whole periods only.
  TPeriodFade fades the last periods out on the device thread when a stream
  is closed in the middle of the music (a manual switch, Stop).

  RingPeriodsFor sizes the ring by time: the buffer of the settings (about
  BufferMs, at least 3 periods). Three periods alone are too few: ASIO
  drivers keep their period in samples, so at 352.8 kHz three periods of 512
  samples hold 4.4 ms - every stall of the play thread longer than that is a
  dropout (at 44.1 kHz the same ring holds 35 ms).
  ============================================================================}

interface

uses
  Windows, SysUtils, SyncObjs, ALAudioOutput;

type
  { TOutputRing }

  TOutputRing = class
  private
    FData: array of Byte;
    FPeriodBytes: Integer;
    FPeriods: Integer;
    FSize: Integer;
    FReadPos, FWritePos, FFill: Integer;
    FLock: TCriticalSection;
    FSpaceEvent: THandle;
    FUnderruns: Integer;
    FMinFill: Integer;          // the least fill a Take found (-1 = none yet)
  public
    constructor Create(APeriodBytes, APeriods: Integer);
    destructor Destroy; override;
    { empties the ring (a seek); the counters stay }
    procedure Clear;
    { room for one period, or AStopEvent; ABypass = True returns owBufferReady
      at once (a device that is not started, or lost) }
    function WaitForSpace(AStopEvent: THandle; ATimeoutMs: Cardinal; ABypass: Boolean): TOutputWait;
    { one period from AData; False when there is no room (dropped) }
    function Put(AData: PByte): Boolean;
    { one period into ADest; False (nothing copied) = an underrun when
      ACount is True }
    function Take(ADest: PByte; ACount: Boolean): Boolean;
    function Fill: Integer;
    { resets the statistics (Underruns, MinFill) }
    procedure ResetStats;
    property PeriodBytes: Integer read FPeriodBytes;
    property Periods: Integer read FPeriods;
    property Size: Integer read FSize;
    property Underruns: Integer read FUnderruns;
    { the least fill (bytes) seen by Take before it took; -1 = no Take yet }
    property MinFill: Integer read FMinFill;
  end;

  { TPeriodFade - a fade-out of the last milliseconds before a stream is
    stopped in the middle of the music (a manual switch to a track of another
    rate, Stop): cut at a full sample value, the stop is a tick. The play
    thread starts it (Start), the device thread runs every period it hands to
    the driver through Apply: a raised cosine down to nothing over AFrames,
    then silence. PCM only (32 bit samples, interleaved); never for DSD / DoP.
    Normal playback is not touched: without Start, Apply does nothing. }
  TPeriodFade = class
  private
    FState: LongInt;            // 0 off, 1 fading, 2 silent
    FLen, FPos: Integer;
    FSilentFrames: LongInt;     // frames of silence handed over since the fade ended
  public
    procedure Start(AFrames: Integer);
    procedure Reset;
    procedure Apply(ASamples: PLongInt; AFrames, AChannels: Integer);
    { a period of silence went to the device instead (the ring was empty) }
    procedure Silence(AFrames: Integer);
    function Active: Boolean;
    function SilentFrames: Integer;
  end;

{ the periods of a ring for about ABufferMs at ARate (frames per second) with
  APeriodFrames frames per period: at least 3, at most 4096 }
function RingPeriodsFor(APeriodFrames: Integer; ARate: Cardinal; ABufferMs: Integer): Integer;

implementation

{ TPeriodFade }

procedure TPeriodFade.Start(AFrames: Integer);
begin
  if AFrames < 1 then AFrames := 1;
  FLen := AFrames;
  FPos := 0;
  InterlockedExchange(FSilentFrames, 0);
  InterlockedExchange(FState, 1);     // last: the device thread reads FLen / FPos after it
end;

procedure TPeriodFade.Reset;
begin
  InterlockedExchange(FState, 0);
  InterlockedExchange(FSilentFrames, 0);
end;

procedure TPeriodFade.Silence(AFrames: Integer);
begin
  if FState = 0 then Exit;
  InterlockedExchange(FState, 2);
  InterlockedExchangeAdd(FSilentFrames, AFrames);
end;

function TPeriodFade.Active: Boolean;
begin
  Result := FState <> 0;
end;

function TPeriodFade.SilentFrames: Integer;
begin
  Result := FSilentFrames;
end;

procedure TPeriodFade.Apply(ASamples: PLongInt; AFrames, AChannels: Integer);
var
  I, C, Done: Integer;
  G: Double;
begin
  if (FState = 0) or (ASamples = nil) or (AFrames <= 0) or (AChannels <= 0) then Exit;
  Done := 0;
  if FState = 1 then
  begin
    for I := 0 to AFrames - 1 do
    begin
      if FPos >= FLen then Break;
      G := 0.5 * (1.0 + Cos(Pi * (FPos + 1) / FLen));
      for C := 0 to AChannels - 1 do
        ASamples[I * AChannels + C] := Round(ASamples[I * AChannels + C] * G);
      Inc(FPos);
      Inc(Done);
    end;
    if FPos >= FLen then InterlockedExchange(FState, 2);
  end;
  if Done < AFrames then
  begin
    FillChar(ASamples[Done * AChannels], (AFrames - Done) * AChannels * SizeOf(LongInt), 0);
    InterlockedExchangeAdd(FSilentFrames, AFrames - Done);
  end;
end;

function RingPeriodsFor(APeriodFrames: Integer; ARate: Cardinal; ABufferMs: Integer): Integer;
var
  Frames: Int64;
begin
  Result := 3;
  if (APeriodFrames <= 0) or (ARate = 0) or (ABufferMs <= 0) then Exit;
  Frames := (Int64(ARate) * ABufferMs) div 1000;
  { the buffer's periods, rounded up, plus the one the device is playing }
  Result := Integer((Frames + APeriodFrames - 1) div APeriodFrames) + 1;
  if Result < 3 then Result := 3;
  if Result > 4096 then Result := 4096;
end;

constructor TOutputRing.Create(APeriodBytes, APeriods: Integer);
begin
  inherited Create;
  if APeriodBytes < 1 then APeriodBytes := 1;
  if APeriods < 2 then APeriods := 2;
  FPeriodBytes := APeriodBytes;
  FPeriods := APeriods;
  FSize := APeriodBytes * APeriods;
  SetLength(FData, FSize);
  FLock := TCriticalSection.Create;
  FSpaceEvent := CreateEvent(nil, False, False, nil);
  FMinFill := -1;
end;

destructor TOutputRing.Destroy;
begin
  CloseHandle(FSpaceEvent);
  FLock.Free;
  inherited Destroy;
end;

procedure TOutputRing.Clear;
begin
  FLock.Enter;
  try
    FReadPos := 0;
    FWritePos := 0;
    FFill := 0;
  finally
    FLock.Leave;
  end;
  SetEvent(FSpaceEvent);
end;

procedure TOutputRing.ResetStats;
begin
  FLock.Enter;
  try
    FUnderruns := 0;
    FMinFill := -1;
  finally
    FLock.Leave;
  end;
end;

function TOutputRing.Fill: Integer;
begin
  FLock.Enter;
  Result := FFill;
  FLock.Leave;
end;

function TOutputRing.WaitForSpace(AStopEvent: THandle; ATimeoutMs: Cardinal; ABypass: Boolean): TOutputWait;
var
  Events: array[0..1] of THandle;
  StartTick, Elapsed: QWord;
  Free_: Integer;
begin
  StartTick := GetTickCount64;
  while True do
  begin
    if WaitForSingleObject(AStopEvent, 0) = WAIT_OBJECT_0 then Exit(owStop);
    FLock.Enter;
    Free_ := FSize - FFill;
    FLock.Leave;
    if ABypass or (Free_ >= FPeriodBytes) then Exit(owBufferReady);
    Elapsed := GetTickCount64 - StartTick;
    if Elapsed >= ATimeoutMs then Exit(owTimeout);
    Events[0] := AStopEvent;
    Events[1] := FSpaceEvent;
    case WaitForMultipleObjects(2, @Events[0], False, Cardinal(ATimeoutMs - Elapsed)) of
      WAIT_OBJECT_0: Exit(owStop);
      WAIT_OBJECT_0 + 1: ;   // room: check again
      WAIT_TIMEOUT: Exit(owTimeout);
    else
      Exit(owFailed);
    end;
  end;
end;

function TOutputRing.Put(AData: PByte): Boolean;
var
  N: Integer;
begin
  FLock.Enter;
  try
    Result := FSize - FFill >= FPeriodBytes;
    if not Result then Exit;
    N := FSize - FWritePos;
    if N >= FPeriodBytes then
      Move(AData^, FData[FWritePos], FPeriodBytes)
    else
    begin
      Move(AData^, FData[FWritePos], N);
      Move(AData[N], FData[0], FPeriodBytes - N);
    end;
    FWritePos := (FWritePos + FPeriodBytes) mod FSize;
    Inc(FFill, FPeriodBytes);
  finally
    FLock.Leave;
  end;
end;

function TOutputRing.Take(ADest: PByte; ACount: Boolean): Boolean;
var
  P: Integer;
begin
  FLock.Enter;
  try
    if ACount and ((FMinFill < 0) or (FFill < FMinFill)) then FMinFill := FFill;
    Result := FFill >= FPeriodBytes;
    if Result then
    begin
      P := FSize - FReadPos;
      if P >= FPeriodBytes then
        Move(FData[FReadPos], ADest^, FPeriodBytes)
      else
      begin
        Move(FData[FReadPos], ADest^, P);
        Move(FData[0], ADest[P], FPeriodBytes - P);
      end;
      FReadPos := (FReadPos + FPeriodBytes) mod FSize;
      Dec(FFill, FPeriodBytes);
    end
    else if ACount then
      Inc(FUnderruns);
  finally
    FLock.Leave;
  end;
  if Result then SetEvent(FSpaceEvent);
end;

end.
