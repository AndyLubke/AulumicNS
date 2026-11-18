unit ALOutputAsio;

{$mode ObjFPC}{$H+}
{$PACKRECORDS C}
{$R-}{$Q-}

{ ==============================================================================
  AulumicNS - ALOutputAsio
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TAsioOutput, the ASIO output of the engine - a TAudioOutput
  like TWasapiOutput, so the play thread (TPlayThread.RunOutput: reading,
  DSP, track switches, waits and retries) is the same for both.

  The ASIO driver interface is declared here (no Steinberg SDK).
  ASIO drivers are apartment threaded COM objects without
  a proxy, so they are created and controlled on an own STA thread with a
  message loop (TAsioHost); the play thread (MTA, for WASAPI) asks it to
  open, start, stop and close. The driver calls bufferSwitch on its own
  thread: it takes one period from a ring buffer that the play thread fills
  with WaitForBuffer / GetBuffer / ReleaseBuffer (whole periods).

  PCM: the play thread gets a 32 bit container with the valid bits of the
  driver's sample type (16 / 18 / 20 / 24 / 32, left aligned like WASAPI's
  32 / 24); bufferSwitch converts to the driver's type (Int16 / Int24 /
  Int32 / Int32 with 16 .. 24 bits / Float32 / Float64).
  DSD: the engine always delivers DoP frames. With native DSD on and a
  driver that can switch to DSD (kAsioSetIoFormat), the DoP frames are
  unpacked back to the DSD bytes (DSDInt8MSB1 / LSB1 / NER8): bit exact.
  Otherwise DoP goes out as PCM (at least 24 bits), as over WASAPI.
  Only one ASIO driver can be active (the callbacks carry no context).
==============================================================================}

interface

uses
  Windows, Classes, SysUtils, Registry, ActiveX, SyncObjs, ALAudioOutput, ALOutputRing;

type
  TAsioHost = class;

  { TAsioOutput }

  TAsioOutput = class(TAudioOutput)
  private
    FHost: TAsioHost;
    FDriver: IUnknown;
    FNativeDsdWanted: Boolean;
    { open parameters / results (for the host thread) }
    FReqId: string;
    FReqRate: Cardinal;
    FReqChannels: Word;
    FReqDoP: Boolean;
    FResult: TOutputOpenResult;
    FResultText: string;
    { stream }
    FFormat: TAudioOutputFormat;
    FNativeDsd: Boolean;
    FBufSize: Integer;                      // ASIO buffer size (samples; DSD: bits)
    FSampleType: Integer;
    FPostOutput: Boolean;
    FChanBufs: array[0..1, 0..1] of Pointer;
    FPeriodBytes: Integer;                  // one period in the play thread's format
    FStage: array of Byte;                  // GetBuffer's buffer
    FSwitchBuf: array of Int32;             // the period bufferSwitch converts (no allocation there)
    { the periods between the play thread and bufferSwitch (ALOutputRing),
      about the buffer time of the settings }
    FRing: TOutputRing;
    FReqBufferMs: Integer;
    FStarted: Boolean;
    FLost: Boolean;
    FDraining: Boolean;                     // Drain: an empty ring is no underrun
    FFade: TPeriodFade;                     // FadeOut: the last periods before a Close mid-music
    function GetUnderruns: Integer;
    function GetRingPeriods: Integer;
    function GetRingFill: Integer;
    function GetRingMinFill: Integer;
    procedure HostOpen;
    procedure HostStart;
    procedure HostStop;
    procedure HostClose;
    procedure Switch(Index: Integer);
    procedure ClearState;
  public
    { ANativeDsd: DSD as DSD when the driver can (else DoP as PCM) }
    constructor Create(ANativeDsd: Boolean);
    destructor Destroy; override;
    class procedure EnumerateDrivers(Devices: TStrings);
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
    // About 40 ms before the driver starts; the ring plays
    // empty before Close / a reopen (see TAudioOutput)
    function PrefillBuffers: Integer; override;
    procedure Drain(AStopEvent: THandle); override;
    procedure FadeOut; override;
    // The ring's underruns and least fill (see TAudioOutput)
    function DropoutCount: Integer; override;
    function LeastBufferedMs: Integer; override;
    function BufferedMs: Integer; override;
    property NativeDsd: Boolean read FNativeDsd;
    property Underruns: Integer read GetUnderruns;
    property RingPeriods: Integer read GetRingPeriods;
    { diagnostics (Tools\AudioSim): bytes in the ring now / the least a take
      found (-1 = none); 0 while no stream is open }
    property RingFill: Integer read GetRingFill;
    property RingMinFill: Integer read GetRingMinFill;
  end;

  { TAsioHost - the STA thread of the driver }

  TAsioHost = class(TThread)
  private
    FOwner: TAsioOutput;
    FCmd: Integer;
    FCmdEvent, FDoneEvent: THandle;
    // The window the driver gets at init (its sysHandle): a
    // hidden window of this thread, not the main window (see Execute)
    FWnd: HWND;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAsioOutput);
    destructor Destroy; override;
    function Run(ACmd: Integer; ATimeoutMs: Cardinal): Boolean;
  end;

{ Windows of this program that hang on a window of another
  thread (owner or parent): such a pair shares its input, and a thread of
  the pair that does not handle messages freezes the other one at a click.
  AToMain: pairs with the main thread (MainThreadID), AToOther: the rest.
  AulumicNS makes none itself; an ASIO driver may (see CreateHostWindow).
  Sends no message (safe from any thread). }
procedure CountTiedWindows(out AToMain, AToOther: Integer);

implementation

uses
  uAudioUtils;

type
  ASIOBool = LongInt;
  ASIOError = LongInt;
  ASIOSampleRate = Double;

  TASIOSamples = record
    hi, lo: Cardinal;
  end;
  PASIOSamples = ^TASIOSamples;
  PASIOTimeStamp = ^TASIOSamples;

  TASIOChannelInfo = record
    channel: LongInt;
    isInput: ASIOBool;
    isActive: ASIOBool;
    channelGroup: LongInt;
    sampleType: LongInt;
    name: array[0..31] of AnsiChar;
  end;
  PASIOChannelInfo = ^TASIOChannelInfo;

  TASIOBufferInfo = record
    isInput: ASIOBool;
    channelNum: LongInt;
    buffers: array[0..1] of Pointer;
  end;
  PASIOBufferInfo = ^TASIOBufferInfo;

  TBufferSwitchProc = procedure(DoubleBufferIndex: LongInt; DirectProcess: ASIOBool); cdecl;
  TSampleRateChangedProc = procedure(sRate: ASIOSampleRate); cdecl;
  TAsioMessageFunc = function(Selector, Value: LongInt; Msg: Pointer; Opt: PDouble): LongInt; cdecl;
  TBufferSwitchTimeInfoFunc = function(Params: Pointer; DoubleBufferIndex: LongInt; DirectProcess: ASIOBool): Pointer; cdecl;

  TASIOCallbacks = record
    bufferSwitch: TBufferSwitchProc;
    sampleRateDidChange: TSampleRateChangedProc;
    asioMessage: TAsioMessageFunc;
    bufferSwitchTimeInfo: TBufferSwitchTimeInfoFunc;
  end;

  TASIOIoFormat = record
    FormatType: LongInt;
    future: array[0..507] of AnsiChar;
  end;

  IASIO = interface(IUnknown)
    function init(sysHandle: Pointer): ASIOBool; stdcall;
    procedure getDriverName(name: PAnsiChar); stdcall;
    function getDriverVersion: LongInt; stdcall;
    procedure getErrorMessage(str: PAnsiChar); stdcall;
    function start: ASIOError; stdcall;
    function stop: ASIOError; stdcall;
    function getChannels(out numInputChannels, numOutputChannels: LongInt): ASIOError; stdcall;
    function getLatencies(out inputLatency, outputLatency: LongInt): ASIOError; stdcall;
    function getBufferSize(out minSize, maxSize, preferredSize, granularity: LongInt): ASIOError; stdcall;
    function canSampleRate(sampleRate: ASIOSampleRate): ASIOError; stdcall;
    function getSampleRate(out sampleRate: ASIOSampleRate): ASIOError; stdcall;
    function setSampleRate(sampleRate: ASIOSampleRate): ASIOError; stdcall;
    function getClockSources(clocks: Pointer; numSources: PLongInt): ASIOError; stdcall;
    function setClockSource(reference: LongInt): ASIOError; stdcall;
    function getSamplePosition(sPos: PASIOSamples; tStamp: PASIOTimeStamp): ASIOError; stdcall;
    function getChannelInfo(info: PASIOChannelInfo): ASIOError; stdcall;
    function createBuffers(bufferInfos: PASIOBufferInfo; numChannels, bufferSize: LongInt; callbacks: Pointer): ASIOError; stdcall;
    function disposeBuffers: ASIOError; stdcall;
    function controlPanel: ASIOError; stdcall;
    function future(selector: LongInt; opt: Pointer): ASIOError; stdcall;
    function outputReady: ASIOError; stdcall;
  end;

const
  ASE_OK = 0;
  ASE_SUCCESS = $3F4847A0;
  ASIOSTInt16LSB = 16;
  ASIOSTInt24LSB = 17;
  ASIOSTInt32LSB = 18;
  ASIOSTFloat32LSB = 19;
  ASIOSTFloat64LSB = 20;
  ASIOSTInt32LSB16 = 24;
  ASIOSTInt32LSB18 = 25;
  ASIOSTInt32LSB20 = 26;
  ASIOSTInt32LSB24 = 27;
  ASIOSTDSDInt8LSB1 = 32;
  ASIOSTDSDInt8MSB1 = 33;
  ASIOSTDSDInt8NER8 = 40;
  kAsioSelectorSupported = 1;
  kAsioEngineVersion = 2;
  kAsioResetRequest = 3;
  kAsioBufferSizeChange = 4;
  kAsioResyncRequest = 5;
  kAsioLatenciesChanged = 6;
  kAsioSupportsTimeInfo = 7;
  kAsioSetIoFormat = $23111961;
  kASIOPCMFormat = 0;
  kASIODSDFormat = 1;

  CMD_OPEN = 1;
  CMD_START = 2;
  CMD_STOP = 3;
  CMD_CLOSE = 4;
  CMD_QUIT = 5;

  HOST_TIMEOUT_MS = 8000;      // a driver that hangs in init / start
  E_ASIO_LOST = HRESULT($88890004);   // reported as AUDCLNT_E_DEVICE_INVALIDATED

var
  Active: TAsioOutput = nil;
  Callbacks: TASIOCallbacks;
  BitRev: array[0..255] of Byte;

procedure BufferSwitch(DoubleBufferIndex: LongInt; DirectProcess: ASIOBool); cdecl;
begin
  if Active <> nil then Active.Switch(DoubleBufferIndex);
end;

function BufferSwitchTimeInfo(Params: Pointer; DoubleBufferIndex: LongInt; DirectProcess: ASIOBool): Pointer; cdecl;
begin
  if Active <> nil then Active.Switch(DoubleBufferIndex);
  Result := Params;
end;

procedure SampleRateChanged(sRate: ASIOSampleRate); cdecl;
begin
  if Active <> nil then Active.FLost := True;
end;

function AsioMessage(Selector, Value: LongInt; Msg: Pointer; Opt: PDouble): LongInt; cdecl;
begin
  Result := 0;
  case Selector of
    kAsioSelectorSupported:
      if Value in [kAsioResetRequest, kAsioEngineVersion, kAsioResyncRequest, kAsioLatenciesChanged,
        kAsioBufferSizeChange] then Result := 1;
    kAsioEngineVersion: Result := 2;
    kAsioResetRequest, kAsioBufferSizeChange:
      begin
        { the driver wants to be reopened: the play thread recovers }
        if Active <> nil then Active.FLost := True;
        Result := 1;
      end;
    kAsioResyncRequest, kAsioLatenciesChanged: Result := 1;
    kAsioSupportsTimeInfo: Result := 0;
  end;
end;

function Drv(O: TAsioOutput): IASIO; inline;
begin
  Result := IASIO(Pointer(O.FDriver));
end;

{ ---- TAsioHost ---- }

constructor TAsioHost.Create(AOwner: TAsioOutput);
begin
  FOwner := AOwner;
  FCmdEvent := CreateEvent(nil, False, False, nil);
  FDoneEvent := CreateEvent(nil, False, False, nil);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TAsioHost.Destroy;
begin
  CloseHandle(FCmdEvent);
  CloseHandle(FDoneEvent);
  inherited Destroy;
end;

const
  HOST_WND_CLASS = 'AulumicNSAsioHost';

{ The driver's window (its sysHandle). Not the main window,
  as in a host that calls ASIO on its UI thread: ASIO runs on this thread
  here. A window that a driver makes as a child / owned window of the main
  window on another thread would tie that thread's input to the UI thread's.
  A hidden top-level window of this thread (the one that calls the driver)
  keeps whatever the driver does with it away from the UI. }
type
  TTieCount = record
    Pid: DWORD;
    ToMain, ToOther: Integer;
  end;
  PTieCount = ^TTieCount;

function EnumWindows_(lpEnumFunc: Pointer; lParam: LPARAM): BOOL; stdcall;
  external 'user32.dll' name 'EnumWindows';
function EnumChildWindows_(hWndParent: HWND; lpEnumFunc: Pointer; lParam: LPARAM): BOOL; stdcall;
  external 'user32.dll' name 'EnumChildWindows';

procedure CheckTie(W: HWND; C: PTieCount);
var
  Pid, RPid, T, RT: DWORD;
  Rel: HWND;
begin
  Pid := 0;
  T := GetWindowThreadProcessId(W, @Pid);
  if Pid <> C^.Pid then Exit;
  Rel := GetWindow(W, GW_OWNER);
  if Rel = 0 then Rel := GetAncestor(W, GA_PARENT);
  if Rel = 0 then Exit;
  { (the desktop and the message-only root are not this program's) }
  RPid := 0;
  RT := GetWindowThreadProcessId(Rel, @RPid);
  if (RPid <> C^.Pid) or (RT = 0) or (RT = T) then Exit;
  if (T = DWORD(MainThreadID)) or (RT = DWORD(MainThreadID)) then Inc(C^.ToMain)
  else Inc(C^.ToOther);
end;

function TieChildProc(W: HWND; L: LPARAM): LongBool; stdcall;
begin
  CheckTie(W, PTieCount(L));
  Result := True;
end;

function TieTopProc(W: HWND; L: LPARAM): LongBool; stdcall;
var
  Pid: DWORD;
begin
  Pid := 0;
  GetWindowThreadProcessId(W, @Pid);
  if Pid = PTieCount(L)^.Pid then
  begin
    CheckTie(W, PTieCount(L));
    EnumChildWindows_(W, @TieChildProc, L);
  end;
  Result := True;
end;

procedure CountTiedWindows(out AToMain, AToOther: Integer);
const
  HWND_MESSAGE_ = HWND(-3);
var
  C: TTieCount;
  W: HWND;
begin
  C.Pid := GetCurrentProcessId;
  C.ToMain := 0;
  C.ToOther := 0;
  EnumWindows_(@TieTopProc, LPARAM(@C));
  { message-only windows (EnumWindows does not list them) }
  W := FindWindowExW(HWND_MESSAGE_, 0, nil, nil);
  while W <> 0 do
  begin
    TieTopProc(W, LPARAM(@C));
    W := FindWindowExW(HWND_MESSAGE_, W, nil, nil);
  end;
  AToMain := C.ToMain;
  AToOther := C.ToOther;
end;

function CreateHostWindow: HWND;
var
  WC: TWndClassW;
begin
  FillChar(WC, SizeOf(WC), 0);
  if not GetClassInfoW(HInstance, HOST_WND_CLASS, @WC) then
  begin
    WC.lpfnWndProc := @DefWindowProcW;
    WC.hInstance := HInstance;
    WC.lpszClassName := HOST_WND_CLASS;
    RegisterClassW(@WC);      // (a second thread may have registered it: fine)
  end;
  Result := CreateWindowExW(WS_EX_TOOLWINDOW, HOST_WND_CLASS, 'Aulumic ASIO', WS_POPUP,
    0, 0, 0, 0, 0, 0, HInstance, nil);
end;

procedure TAsioHost.Execute;
const
  MWMO_INPUTAVAILABLE_ = $0004;
var
  R: DWORD;
  M: TMsg;
  Cmd: Integer;
begin
  NameThisThread('ASIO host');
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  FWnd := CreateHostWindow;
  try
    while True do
    begin
      { the driver's messages (some drivers use windows or timers), also the
        ones that came during a command; MWMO_INPUTAVAILABLE: wake for any
        message in the queue, not only for new ones }
      while PeekMessageW(M, 0, 0, 0, PM_REMOVE) do
      begin
        TranslateMessage(M);
        DispatchMessageW(M);
      end;
      R := MsgWaitForMultipleObjectsEx(1, FCmdEvent, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE_);
      if R = WAIT_OBJECT_0 then
      begin
        Cmd := FCmd;
        try
          case Cmd of
            CMD_OPEN: FOwner.HostOpen;
            CMD_START: FOwner.HostStart;
            CMD_STOP: FOwner.HostStop;
            CMD_CLOSE: FOwner.HostClose;
          end;
        except
          on E: Exception do
          begin
            FOwner.FResult := oorFailed;
            FOwner.FResultText := 'ASIO: ' + E.Message;
          end;
        end;
        SetEvent(FDoneEvent);
        if Cmd = CMD_QUIT then Break;
      end;
    end;
  finally
    if FWnd <> 0 then DestroyWindow(FWnd);
    FWnd := 0;
    CoUninitialize;
  end;
end;

function TAsioHost.Run(ACmd: Integer; ATimeoutMs: Cardinal): Boolean;
begin
  FCmd := ACmd;
  SetEvent(FCmdEvent);
  Result := WaitForSingleObject(FDoneEvent, ATimeoutMs) = WAIT_OBJECT_0;
end;

{ ---- TAsioOutput ---- }

constructor TAsioOutput.Create(ANativeDsd: Boolean);
begin
  inherited Create;
  FNativeDsdWanted := ANativeDsd;
  FFade := TPeriodFade.Create;
end;

destructor TAsioOutput.Destroy;
begin
  Close;
  FreeAndNil(FRing);
  FreeAndNil(FFade);
  inherited Destroy;
end;

function TAsioOutput.GetUnderruns: Integer;
begin
  if FRing <> nil then Result := FRing.Underruns else Result := 0;
end;

function TAsioOutput.GetRingPeriods: Integer;
begin
  if FRing <> nil then Result := FRing.Periods else Result := 0;
end;

function TAsioOutput.GetRingFill: Integer;
begin
  if FRing <> nil then Result := FRing.Fill else Result := 0;
end;

function TAsioOutput.GetRingMinFill: Integer;
begin
  if FRing <> nil then Result := FRing.MinFill else Result := -1;
end;

function TAsioOutput.DropoutCount: Integer;
begin
  if FRing <> nil then Result := FRing.Underruns else Result := -1;
end;

{ the ring without the period the driver is playing }
function TAsioOutput.BufferedMs: Integer;
begin
  Result := -1;
  if (FRing = nil) or (FFormat.SampleRate = 0) or (FFormat.BlockAlign = 0) then Exit;
  Result := Integer((Int64(FRing.Periods - 1) * (FPeriodBytes div FFormat.BlockAlign) * 1000) div
    FFormat.SampleRate);
end;

function TAsioOutput.LeastBufferedMs: Integer;
var
  M: Integer;
begin
  Result := -1;
  if (FRing = nil) or (FFormat.SampleRate = 0) or (FFormat.BlockAlign = 0) then Exit;
  M := FRing.MinFill;
  if M >= 0 then
    Result := Integer((Int64(M div FFormat.BlockAlign) * 1000) div FFormat.SampleRate);
end;

class procedure TAsioOutput.EnumerateDrivers(Devices: TStrings);
var
  R: TRegistry;
  Keys: TStringList;
  I: Integer;
  Clsid, Desc: string;
begin
  Devices.Clear;
  R := TRegistry.Create(KEY_READ);
  Keys := TStringList.Create;
  try
    R.RootKey := HKEY_LOCAL_MACHINE;
    if not R.OpenKeyReadOnly('SOFTWARE\ASIO') then Exit;
    R.GetKeyNames(Keys);
    R.CloseKey;
    for I := 0 to Keys.Count - 1 do
      if R.OpenKeyReadOnly('SOFTWARE\ASIO\' + Keys[I]) then
      begin
        Clsid := '';
        Desc := Keys[I];
        if R.ValueExists('CLSID') then Clsid := R.ReadString('CLSID');
        if R.ValueExists('Description') then Desc := R.ReadString('Description');
        R.CloseKey;
        { 'Name|Id' like TAudioEngine.EnumerateDevices }
        if Clsid <> '' then Devices.Add(Desc + '|' + Clsid);
      end;
  finally
    Keys.Free;
    R.Free;
  end;
end;

procedure TAsioOutput.ClearState;
begin
  FDriver := nil;
  FStarted := False;
  FLost := False;
  FNativeDsd := False;
  FDraining := False;
  if FFade <> nil then FFade.Reset;
  { the driver does not call bufferSwitch now (its buffers are disposed) }
  FreeAndNil(FRing);
end;

{ on the host thread }
procedure TAsioOutput.HostOpen;
var
  Clsid: TGUID;
  Unk: IUnknown;
  D: IASIO;
  Fmt: TASIOIoFormat;
  NIn, NOut, MinS, MaxS, Pref, Gran: LongInt;
  Infos: array[0..1] of TASIOBufferInfo;
  CI: TASIOChannelInfo;
  Name: array[0..127] of AnsiChar;
  C, Periods: Integer;
  DsdRate: Double;
  Parent: Pointer;
begin
  FResult := oorFailed;
  FResultText := '';
  try
    Clsid := StringToGUID(FReqId);
  except
    FResult := oorNoDevice;
    FResultText := 'The ASIO driver is not installed.';
    Exit;
  end;
  { the ASIO convention: the CLSID is also the interface id }
  if Failed(CoCreateInstance(Clsid, nil, CLSCTX_INPROC_SERVER, Clsid, Unk)) or (Unk = nil) then
  begin
    FResult := oorNoDevice;
    FResultText := 'The ASIO driver cannot be loaded.';
    Exit;
  end;
  FDriver := Unk;
  Unk := nil;
  D := Drv(Self);
  // The host thread's hidden window (never the main window)
  Parent := nil;
  if FHost <> nil then Parent := Pointer(FHost.FWnd);
  if Parent = nil then Parent := Pointer(GetDesktopWindow);
  if D.init(Parent) = 0 then
  begin
    FillChar(Name, SizeOf(Name), 0);
    D.getErrorMessage(@Name[0]);
    FResultText := 'ASIO driver: ' + string(PAnsiChar(@Name[0]));
    FDriver := nil;
    { a DAC that is switched off or unplugged }
    FResult := oorNoDevice;
    Exit;
  end;
  if (D.getChannels(NIn, NOut) <> ASE_OK) or (NOut < FReqChannels) then
  begin
    FResult := oorFormatUnsupported;
    FResultText := 'The ASIO driver has too few output channels.';
    Exit;
  end;
  { native DSD: the DoP carrier rate x 16 = the DSD rate }
  FNativeDsd := False;
  if FReqDoP and FNativeDsdWanted then
  begin
    FillChar(Fmt, SizeOf(Fmt), 0);
    Fmt.FormatType := kASIODSDFormat;
    DsdRate := FReqRate * 16.0;
    if (D.future(kAsioSetIoFormat, @Fmt) = ASE_SUCCESS) then
    begin
      if D.canSampleRate(DsdRate) = ASE_OK then
        FNativeDsd := True
      else
      begin
        Fmt.FormatType := kASIOPCMFormat;
        D.future(kAsioSetIoFormat, @Fmt);
      end;
    end;
  end;
  if FNativeDsd then
  begin
    D.setSampleRate(FReqRate * 16.0);
  end
  else
  begin
    if D.canSampleRate(FReqRate) <> ASE_OK then
    begin
      FResult := oorFormatUnsupported;
      FResultText := SysUtils.Format('The ASIO driver does not support %d Hz.', [FReqRate]);
      Exit;
    end;
    D.setSampleRate(FReqRate);
  end;
  if D.getBufferSize(MinS, MaxS, Pref, Gran) <> ASE_OK then Pref := 2048;
  FBufSize := Pref;
  if FNativeDsd then FBufSize := (FBufSize div 16) * 16;    // whole DoP frames
  if FBufSize < 16 then FBufSize := 16;
  FillChar(Infos, SizeOf(Infos), 0);
  for C := 0 to FReqChannels - 1 do
  begin
    Infos[C].isInput := 0;
    Infos[C].channelNum := C;
  end;
  Callbacks.bufferSwitch := @BufferSwitch;
  Callbacks.sampleRateDidChange := @SampleRateChanged;
  Callbacks.asioMessage := @AsioMessage;
  Callbacks.bufferSwitchTimeInfo := @BufferSwitchTimeInfo;
  if Active <> nil then
  begin
    FResult := oorInUse;
    FResultText := 'Another ASIO stream is active.';
    Exit;
  end;
  Active := Self;
  if D.createBuffers(@Infos[0], FReqChannels, FBufSize, @Callbacks) <> ASE_OK then
  begin
    Active := nil;
    FResult := oorInUse;
    FResultText := 'The ASIO buffers cannot be created (is another program using the device?).';
    Exit;
  end;
  for C := 0 to FReqChannels - 1 do
  begin
    FChanBufs[C, 0] := Infos[C].buffers[0];
    FChanBufs[C, 1] := Infos[C].buffers[1];
  end;
  FillChar(CI, SizeOf(CI), 0);
  CI.channel := 0;
  CI.isInput := 0;
  D.getChannelInfo(@CI);
  FSampleType := CI.sampleType;
  FPostOutput := D.outputReady = ASE_OK;
  { the format the play thread delivers: a left aligned 32 bit container }
  FFormat.SampleRate := FReqRate;
  FFormat.Channels := FReqChannels;
  FFormat.Bits := 32;
  FFormat.BlockAlign := 4 * FReqChannels;
  if FNativeDsd then
  begin
    if not (FSampleType in [ASIOSTDSDInt8LSB1, ASIOSTDSDInt8MSB1, ASIOSTDSDInt8NER8]) then
    begin
      FResult := oorFormatUnsupported;
      FResultText := SysUtils.Format('Unsupported ASIO DSD sample type %d.', [FSampleType]);
      Exit;
    end;
    FFormat.ValidBits := 24;                        // DoP frames: 24 bits
    FPeriodBytes := (FBufSize div 16) * FFormat.BlockAlign;
  end
  else
  begin
    case FSampleType of
      ASIOSTInt16LSB, ASIOSTInt32LSB16: FFormat.ValidBits := 16;
      ASIOSTInt32LSB18: FFormat.ValidBits := 18;
      ASIOSTInt32LSB20: FFormat.ValidBits := 20;
      ASIOSTInt24LSB, ASIOSTInt32LSB24, ASIOSTFloat32LSB: FFormat.ValidBits := 24;
      ASIOSTInt32LSB, ASIOSTFloat64LSB: FFormat.ValidBits := 32;
    else
      begin
        FResult := oorFormatUnsupported;
        FResultText := SysUtils.Format('Unsupported ASIO sample type %d.', [FSampleType]);
        Exit;
      end;
    end;
    if FReqDoP and (FFormat.ValidBits < 24) then
    begin
      FResult := oorFormatUnsupported;
      FResultText := 'DoP needs at least 24 bits.';
      Exit;
    end;
    FPeriodBytes := FBufSize * FFormat.BlockAlign;
  end;
  SetLength(FStage, FPeriodBytes);
  SetLength(FSwitchBuf, FPeriodBytes div 4);
  { the ring: about the buffer time of the settings, at least 3 periods
    (3 alone would be 4.4 ms at 352.8 kHz with 512 samples, too little for
    any stall of the play thread) }
  Periods := RingPeriodsFor(FPeriodBytes div FFormat.BlockAlign, FFormat.SampleRate, FReqBufferMs);
  FreeAndNil(FRing);
  FRing := TOutputRing.Create(FPeriodBytes, Periods);
  FLost := False;
  FResult := oorOK;
end;

procedure TAsioOutput.HostStart;
begin
  if FDriver = nil then Exit;
  FStarted := True;
  if Drv(Self).start <> ASE_OK then FLost := True;
end;

procedure TAsioOutput.HostStop;
begin
  if FDriver = nil then Exit;
  if FStarted then Drv(Self).stop;
  FStarted := False;
end;

procedure TAsioOutput.HostClose;
var
  D: IASIO;
  Fmt: TASIOIoFormat;
begin
  if FDriver = nil then Exit;
  D := Drv(Self);
  if FStarted then D.stop;
  FStarted := False;
  D.disposeBuffers;
  if FNativeDsd then
  begin
    FillChar(Fmt, SizeOf(Fmt), 0);
    Fmt.FormatType := kASIOPCMFormat;
    D.future(kAsioSetIoFormat, @Fmt);
  end;
  if Active = Self then Active := nil;
  D := nil;
  FDriver := nil;
end;

function TAsioOutput.Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
  AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
  out AErrorText: string): TOutputOpenResult;
begin
  Close;
  AError := 0;
  AErrorText := '';
  FFormat := Default(TAudioOutputFormat);
  if (AChannels < 1) or (AChannels > 2) then
  begin
    AErrorText := 'ASIO: only mono and stereo.';
    Exit(oorFormatUnsupported);
  end;
  FReqId := ADeviceId;
  FReqRate := ARate;
  FReqChannels := AChannels;
  FReqDoP := AIsDoP;
  FReqBufferMs := ABufferMs;
  FHost := TAsioHost.Create(Self);
  if not FHost.Run(CMD_OPEN, HOST_TIMEOUT_MS) then
  begin
    { the driver hangs: the host thread is left alone (it cannot be ended) }
    FHost := nil;
    AErrorText := 'The ASIO driver does not respond.';
    Exit(oorFailed);
  end;
  Result := FResult;
  AErrorText := FResultText;
  if Result <> oorOK then Close;
end;

function TAsioOutput.Format: TAudioOutputFormat;
begin
  Result := FFormat;
end;

function TAsioOutput.BufferBytes: Integer;
begin
  Result := FPeriodBytes;
end;

procedure TAsioOutput.Start;
begin
  if FHost <> nil then FHost.Run(CMD_START, HOST_TIMEOUT_MS);
end;

procedure TAsioOutput.Stop;
begin
  if FHost <> nil then FHost.Run(CMD_STOP, HOST_TIMEOUT_MS);
end;

procedure TAsioOutput.Reset;
begin
  if FRing <> nil then FRing.Clear;
end;

function TAsioOutput.PrefillBuffers: Integer;
var
  Frames: Integer;
begin
  Result := 1;
  if (FRing = nil) or (FFormat.SampleRate = 0) or (FFormat.BlockAlign = 0) then Exit;
  Frames := FPeriodBytes div FFormat.BlockAlign;
  if Frames <= 0 then Exit;
  Result := Integer((Int64(FFormat.SampleRate) * 40 div 1000 + Frames - 1) div Frames);
  if Result > FRing.Periods - 1 then Result := FRing.Periods - 1;
  if Result < 1 then Result := 1;
end;

{ the ring plays empty, then the period the driver is playing out. FDraining
  stays set until Close (ClearState): the silence after the end is no underrun. }
procedure TAsioOutput.Drain(AStopEvent: THandle);
var
  StartTick, LimitMs: QWord;
  PeriodMs: Cardinal;
begin
  if (FRing = nil) or (not FStarted) or FLost or (FFormat.SampleRate = 0) or (FFormat.BlockAlign = 0) then Exit;
  PeriodMs := Cardinal((Int64(FPeriodBytes div FFormat.BlockAlign) * 1000) div FFormat.SampleRate) + 2;
  LimitMs := QWord(FRing.Periods) * PeriodMs + 500;
  FDraining := True;
  StartTick := GetTickCount64;
  while (FRing.Fill > 0) and (GetTickCount64 - StartTick < LimitMs) do
    if WaitForSingleObject(AStopEvent, 2) = WAIT_OBJECT_0 then Exit;
  WaitForSingleObject(AStopEvent, PeriodMs);
end;

{ The driver thread fades the periods it takes from now on
  (FADE_MS), then hands over silence; this waits until SILENT_MS of silence
  went to the driver (what it had queued has played then), at most
  FADE_LIMIT_MS. What is still in the ring is not played: the listener asked for
  something else. Not for DSD (native or DoP): those samples are no levels. }
procedure TAsioOutput.FadeOut;
const
  FADE_MS       = 15;
  SILENT_MS     = 40;
  FADE_LIMIT_MS = 250;
var
  StartTick: QWord;
  Frames: Integer;
begin
  if (FRing = nil) or (not FStarted) or FLost or FDraining or FReqDoP or FNativeDsd or
     (FFormat.SampleRate = 0) or (FRing.Fill = 0) then Exit;
  Frames := Integer((Int64(FFormat.SampleRate) * FADE_MS) div 1000);
  if Frames < FBufSize then Frames := FBufSize;      // at least one period
  FDraining := True;                                 // the silence after it is no underrun
  FFade.Start(Frames);
  StartTick := GetTickCount64;
  while (FFade.SilentFrames < Integer((Int64(FFormat.SampleRate) * SILENT_MS) div 1000)) and
        (GetTickCount64 - StartTick < FADE_LIMIT_MS) and not FLost do
    Sleep(1);
end;

function TAsioOutput.WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait;
begin
  { a lost driver: GetBuffer reports it (the play thread recovers) }
  if FRing = nil then Exit(owBufferReady);
  Result := FRing.WaitForSpace(AStopEvent, ATimeoutMs, FLost or not FStarted);
end;

function TAsioOutput.GetBuffer(out AData: PByte; out AError: HRESULT): Boolean;
begin
  AData := nil;
  AError := 0;
  if FLost or (FDriver = nil) then
  begin
    AError := E_ASIO_LOST;
    Exit(False);
  end;
  AData := @FStage[0];
  Result := True;
end;

procedure TAsioOutput.ReleaseBuffer(AFull: Boolean);
begin
  if (not AFull) or (FRing = nil) then Exit;
  FRing.Put(@FStage[0]);    // (always room: WaitForBuffer waited for it)
end;

procedure TAsioOutput.Close;
begin
  if FHost <> nil then
  begin
    FHost.Run(CMD_CLOSE, HOST_TIMEOUT_MS);
    if FHost.Run(CMD_QUIT, 2000) then
    begin
      FHost.WaitFor;
      FHost.Free;
    end;
    { else: a hanging driver - its thread is left alone }
    FHost := nil;
  end;
  if Active = Self then Active := nil;
  ClearState;
end;

{ called by the driver (its thread): the next period into the half Index }
procedure TAsioOutput.Switch(Index: Integer);
var
  Frames, C, I, Ch, K: Integer;
  Src: PInt32;
  D: PByte;
  V: Int32;
  B1, B2: Byte;
  Have: Boolean;
  Tmp: PInt32;
begin
  Ch := FFormat.Channels;
  if (Ch < 1) or (Length(FSwitchBuf) = 0) then Exit;
  if FNativeDsd then Frames := FBufSize div 16 else Frames := FBufSize;
  Tmp := @FSwitchBuf[0];
  { take one period from the ring (or silence; counted as an underrun) }
  Have := FStarted and (FRing <> nil) and FRing.Take(PByte(Tmp), not FDraining);
  { FadeOut (PCM only): this period goes down to nothing }
  if FFade.Active then
    if Have then FFade.Apply(PLongInt(Tmp), Frames, Ch) else FFade.Silence(Frames);
  for C := 0 to Ch - 1 do
  begin
    D := FChanBufs[C, Index];
    if D = nil then Continue;
    if FNativeDsd then
    begin
      { DoP frame (left aligned): marker | first DSD byte | second DSD byte | 0 }
      for I := 0 to Frames - 1 do
      begin
        if Have then
        begin
          V := Tmp[I * Ch + C];
          B1 := (V shr 16) and $FF;
          B2 := (V shr 8) and $FF;
        end
        else
        begin
          B1 := $69;
          B2 := $69;
        end;
        case FSampleType of
          ASIOSTDSDInt8LSB1:
            begin
              D[2 * I] := BitRev[B1];
              D[2 * I + 1] := BitRev[B2];
            end;
          ASIOSTDSDInt8NER8:
            for K := 0 to 7 do
            begin
              D[16 * I + K] := (B1 shr (7 - K)) and 1;
              D[16 * I + 8 + K] := (B2 shr (7 - K)) and 1;
            end;
        else
          begin
            D[2 * I] := B1;
            D[2 * I + 1] := B2;
          end;
        end;
      end;
    end
    else
    begin
      if not Have then
      begin
        case FSampleType of
          ASIOSTInt16LSB: FillChar(D^, Frames * 2, 0);
          ASIOSTInt24LSB: FillChar(D^, Frames * 3, 0);
          ASIOSTFloat64LSB: FillChar(D^, Frames * 8, 0);
        else
          FillChar(D^, Frames * 4, 0);
        end;
        Continue;
      end;
      Src := Tmp;
      case FSampleType of
        ASIOSTInt16LSB: for I := 0 to Frames - 1 do PSmallInt(D + I * 2)^ := SmallInt(Src[I * Ch + C] shr 16);
        ASIOSTInt24LSB: for I := 0 to Frames - 1 do
          begin
            V := Src[I * Ch + C] shr 8;
            D[I * 3] := V and $FF;
            D[I * 3 + 1] := (V shr 8) and $FF;
            D[I * 3 + 2] := (V shr 16) and $FF;
          end;
        ASIOSTInt32LSB: for I := 0 to Frames - 1 do PInt32(D + I * 4)^ := Src[I * Ch + C];
        ASIOSTInt32LSB16: for I := 0 to Frames - 1 do PInt32(D + I * 4)^ := SarLongint(Src[I * Ch + C], 16);
        ASIOSTInt32LSB18: for I := 0 to Frames - 1 do PInt32(D + I * 4)^ := SarLongint(Src[I * Ch + C], 14);
        ASIOSTInt32LSB20: for I := 0 to Frames - 1 do PInt32(D + I * 4)^ := SarLongint(Src[I * Ch + C], 12);
        ASIOSTInt32LSB24: for I := 0 to Frames - 1 do PInt32(D + I * 4)^ := SarLongint(Src[I * Ch + C], 8);
        ASIOSTFloat32LSB: for I := 0 to Frames - 1 do PSingle(D + I * 4)^ := Src[I * Ch + C] * (1 / 2147483648.0);
        ASIOSTFloat64LSB: for I := 0 to Frames - 1 do PDouble(D + I * 8)^ := Src[I * Ch + C] * (1 / 2147483648.0);
      end;
    end;
  end;
  if FPostOutput and (FDriver <> nil) then Drv(Self).outputReady;
end;

procedure InitBitRev;
var
  I, J: Integer;
  B: Byte;
begin
  for I := 0 to 255 do
  begin
    B := 0;
    for J := 0 to 7 do
      if I and (1 shl J) <> 0 then B := B or (1 shl (7 - J));
    BitRev[I] := B;
  end;
end;

initialization
  InitBitRev;

end.
