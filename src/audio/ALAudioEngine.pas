unit ALAudioEngine;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALAudioEngine
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The core audio engine, all in Free Pascal: it owns the play thread, lists
  the output devices (WASAPI endpoints and ASIO drivers) and takes the
  settings. Plays WAV, FLAC, DSF and DFF files; FLAC is decoded by the
  built-in decoder (AuDecFlac), no DLL is used.
  File names, device ids and names, error texts are UTF-8; the device ids and
  names Windows returns (UTF-16) are converted where they are read.
  =============================================================================}

interface

uses
  Classes, SysUtils, Windows, ActiveX, ComObj, ALReaders, ALAudioThread,
  ALWasapiApi,      // the device list's COM declarations
  ALSourceFactory,  // TPlayThreadConfig, TPreparedNext
  ALOutputAsio,     // the ASIO driver list
  ALAudioTypes, AuLog,
  uAudioUtils;      // TSignalInfo

type

  { TAudioEngine }

  TAudioEngine = class
  private
    FCurrentThread      : TPlayThread;
    // When the last stream closed (Stop: the thread's
    // ClosedTick); Play gives the next one SETTLE_MS when that is recent
    FLastCloseTick      : QWord;
    // Changes on every Play; a source prepared for an earlier play
    // thread (TPreparedNext.StreamId) is never handed to a newer one
    FStreamId           : integer;
    // Changes on every seek and every new stream, so the peak
    // meter can drop slices from before it (UI thread only)
    FMeterEpoch         : integer;
    FNotifyHandle       : THandle;
    // 0 WASAPI, 1 ASIO; DSD as DSD over ASIO
    FOutputApi          : integer;
    FAsioNativeDsd      : boolean;
    FVolume             : integer;
    FUseDoP             : boolean;

    FResamplePCM        : boolean;
    FResampleQuality    : Integer;
    FDsdGain            : Integer;
    FDsdLowPassFilter   : boolean;
    FTargetSampleRate   : integer;
    FBufferMs           : integer;
    FRateMaps           : TRateMapArray;

    // ReplayGain Variables
    FReplayGainMode     : integer;
    FRGTrackTags        : string;
    FRGAlbumTags        : string;
    FRGTrackPeakTags    : string;
    FRGAlbumPeakTags    : string;

    FDisableVolume      : Boolean;
    FPreampDB           : Double;
    FEnableSoftClipping : Boolean;
    FAutoHeadroom       : Boolean;   // see TPlayThread.RunGain

    FUpsamplePhase      : integer;
    FDownsamplePhase    : integer;

    // Advanced resampler parameters
    FResampleBandWidth  : double;
    FResampleAntiAlias  : double;

    // System Optimization Fields
    FUseHighResTimer    : boolean;
    FOptimizeAffinity   : boolean;
    FEnableMMCSS        : boolean;

    // Tone Control
    FToneDirect         : boolean;
    FToneBassDB         : Integer;
    FToneLowMidDB          : Integer;
    FToneMidDB          : Integer;
    FToneHighMidDB          : Integer;
    FToneTrebleDB       : Integer;
    FToneBassHz         : Integer;
    FToneLowMidHz          : Integer;
    FToneMidHz          : Integer;
    FToneHighMidHz          : Integer;
    FToneTrebleHz       : Integer;
    FToneLowMidWidth    : Integer;   // TONE_WIDTH_*
    FToneMidWidth       : Integer;
    FToneHighMidWidth   : Integer;

    class var FLibraryChecked     : boolean;
    class var FResamplerAvailable : boolean;
    class var FFlacAvailable      : boolean;

    procedure SetDSDGainDB(Value: Integer);
    procedure LogEvent(EventCode: integer; HRes: HRESULT = 0);
    procedure SetNotifyHandle(Value: THandle);

  public
    constructor Create;
    destructor Destroy; override;
    class procedure CheckLibraries;
    class procedure EnumerateDevices(Devices: TStrings; out DefaultIndex: integer);
    // The installed ASIO drivers ('Name|CLSID')
    class procedure EnumerateAsioDevices(Devices: TStrings);
    // Friendly name (UTF-8) of any known endpoint, also when it is switched off
    // or unplugged; '' when Windows does not know the device
    class function GetDeviceFriendlyName(const DeviceId: string): string;

    procedure Play(const FileName, DeviceId: string);
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Seek(Percent: double);
    // False = rejected because an unconsumed gapless swap is pending
    function  SetNextFile(const FileName: string): Boolean;
    // Snapshot for PrepareNextSource; False while nothing plays
    function  GetNextPrepareParams(out AParams: TNextPrepareParams): Boolean;
    // Queues a source built by PrepareNextSource. Takes ownership of
    // APrep.Source in every case (one of another stream is freed). Result as
    // SetNextFile.
    function  SetPreparedNext(var APrep: TPreparedNext): Boolean;
    procedure SetVolume(Value: integer);
    procedure SetToneControl(const State: TToneState);
    procedure SetRateMapping(const Maps: array of TRateMap);
    procedure ForceGaplessSwap;
    procedure GetAndClearPeaks(out L, R: double; out cL, cR: boolean);
    // HasL / HasR: a new block was measured since the last read
    procedure ReadPeaks(out L, R: double; out HasL, HasR: boolean; out cL, cR: boolean);
    // Meter slices measured since the previous call (oldest first)
    procedure ReadMeterSlices(var Dest: array of TMeterSlice; out Count: Integer);

    function IsPlaying         : boolean;
    function IsPaused          : boolean;
    function HasFinished       : boolean;
    function CheckClipping     : boolean;
    function GetProgress       : double;
    function GetDuration       : double;
    function WasTrackSwapped   : boolean;
    function GetInputRate      : integer;
    function GetOutputRate     : integer;
    function HasError          : boolean;
    function GetErrorMessage   : string;
    function GetErrorType      : TAudioErrorType;
    function GetFailedSampleRate: Integer;
    // Technical details of an unexpected engine exception ('' if none)
    function GetErrorDetail    : string;

    function GetAppliedReplayGain : double;
    function GetBitDepth          : integer;
    function IsBitPerfect         : boolean;
    function GetChannels          : integer;
    // The stages of the signal path (Valid = False: no stream)
    function GetSignalInfo        : TSignalInfo;

    property NotifyHandle: THandle read FNotifyHandle write SetNotifyHandle;
    property MeterEpoch: integer read FMeterEpoch;
    property StreamId: integer read FStreamId;
    property UseDoP: boolean read FUseDoP write FUseDoP;
    property OutputApi: integer read FOutputApi write FOutputApi;
    property AsioNativeDsd: boolean read FAsioNativeDsd write FAsioNativeDsd;

    property ResamplePCM: boolean read FResamplePCM write FResamplePCM;
    property ResampleQuality: integer read FResampleQuality write FResampleQuality;
    property DsdGainDB: Integer read FDsdGain write SetDSDGainDB;
    property DsdLowPassFilter: boolean read FDsdLowPassFilter write FDsdLowPassFilter;
    property TargetSampleRate: integer read FTargetSampleRate write FTargetSampleRate;
    property BufferSizeMs: integer read FBufferMs write FBufferMs;
    property UseHighResTimer: boolean read FUseHighResTimer write FUseHighResTimer;
    property OptimizeAffinity: boolean read FOptimizeAffinity write FOptimizeAffinity;
    property EnableMMCSS: boolean read FEnableMMCSS write FEnableMMCSS;

    // Tone Control Properties
    property ToneDirect: boolean read FToneDirect write FToneDirect;
    property ToneBassDB: Integer read FToneBassDB write FToneBassDB;
    property ToneLowMidDB: Integer read FToneLowMidDB write FToneLowMidDB;
    property ToneMidDB: Integer read FToneMidDB write FToneMidDB;
    property ToneHighMidDB: Integer read FToneHighMidDB write FToneHighMidDB;
    property ToneTrebleDB: Integer read FToneTrebleDB write FToneTrebleDB;
    property ToneBassHz: Integer read FToneBassHz write FToneBassHz;
    property ToneLowMidHz: Integer read FToneLowMidHz write FToneLowMidHz;
    property ToneMidHz: Integer read FToneMidHz write FToneMidHz;
    property ToneHighMidHz: Integer read FToneHighMidHz write FToneHighMidHz;
    property ToneTrebleHz: Integer read FToneTrebleHz write FToneTrebleHz;

    // ReplayGain Properties
    property ReplayGainMode: integer read FReplayGainMode write FReplayGainMode;
    property RGTrackTags: string read FRGTrackTags write FRGTrackTags;
    property RGAlbumTags: string read FRGAlbumTags write FRGAlbumTags;
    property RGTrackPeakTags: string read FRGTrackPeakTags write FRGTrackPeakTags;
    property RGAlbumPeakTags: string read FRGAlbumPeakTags write FRGAlbumPeakTags;
    property DisableVolume: boolean read FDisableVolume write FDisableVolume;
    property PreampDB: double read FPreampDB write FPreampDB;
    property EnableSoftClipping: Boolean read FEnableSoftClipping write FEnableSoftClipping;
    property AutoHeadroom: Boolean read FAutoHeadroom write FAutoHeadroom;
    property UpsamplePhase: integer read FUpsamplePhase write FUpsamplePhase;
    property DownsamplePhase: integer read FDownsamplePhase write FDownsamplePhase;

    // Resampler quality properties
    property ResampleBandWidth: double read FResampleBandWidth write FResampleBandWidth;
    property ResampleAntiAlias: double read FResampleAntiAlias write FResampleAntiAlias;
  end;

// True while a play thread that did not stop in time (see
// TAudioEngine.Stop) is still running. The shutdown then leaves alone what
// that thread may still use when it ends (the headroom book; see
// uAppLifetime.EndProcessIfThreadsLeft). UI thread only.
function PlayThreadsStillRunning: Boolean;

implementation

uses uAppStrings, uAppConsts;

const
  // How long the stream after a just-closed one may wait for
  // the device (TPlayThreadConfig.SettleMs). The WASAPI endpoint of some
  // DACs is gone for 0.5 - 0.7 s after native DSD over ASIO.
  SETTLE_MS = 3000;

var
  // Play threads that did not end within PLAY_THREAD_STOP_TIMEOUT_MS
  // after Stop (stuck in a file read on an unreachable drive, or in the audio
  // driver). They are set aside, so the window does not freeze, and freed as
  // soon as they have ended. UI thread only.
  RetiredThreads: TList = nil;

// Frees the set-aside play threads that have ended. Waits up to AWaitMs in
// total for the others (0 = only check).
procedure ReapRetiredThreads(AWaitMs: Cardinal);
var
  I         : Integer;
  T         : TPlayThread;
  StartTick : QWord;
  Elapsed   : QWord;
  WaitMs    : Cardinal;
begin
  if not Assigned(RetiredThreads) then
    Exit;

  StartTick := GetTickCount64;
  for I := RetiredThreads.Count - 1 downto 0 do
  begin
    T       := TPlayThread(RetiredThreads[I]);
    Elapsed := GetTickCount64 - StartTick;
    if Elapsed < AWaitMs then
      WaitMs := AWaitMs - Cardinal(Elapsed)
    else
      WaitMs := 0;

    if T.StopAndWait(WaitMs) then
    begin
      RetiredThreads.Delete(I);
      T.Free;
    end;
  end;
end;

function PlayThreadsStillRunning: Boolean;
begin
  ReapRetiredThreads(0);
  Result := Assigned(RetiredThreads) and (RetiredThreads.Count > 0);
end;

{ TAudioEngine }

constructor TAudioEngine.Create;
begin
  inherited Create;
  CheckLibraries;
  FVolume           := VAL_DEF_VOLUME;
  FUseDoP           := True;
  FResamplePCM      := False;
  FDsdGain          := VAL_DEF_DSDGAIN;
  FDsdLowPassFilter := True;
  FTargetSampleRate := VAL_DEF_TARGET_RATE;
  FResampleQuality  := VAL_DEF_RESAMPLE_QUAL;
  FBufferMs         := VAL_DEF_PCMBUFFER;

  // Initialize ReplayGain
  FReplayGainMode   := VAL_DEF_RG_MODE;
  FRGTrackTags      := '';
  FRGAlbumTags      := '';
  FRGTrackPeakTags  := '';
  FRGAlbumPeakTags  := '';

  FUpsamplePhase    := VAL_DEF_UPSAMPLE_PHASE;
  FDownsamplePhase  := VAL_DEF_DOWNSAMPLE_PHASE;

  // Initialize DSP defaults
  FResampleBandWidth := VAL_DEF_BANDWIDTH_FLOAT;
  FResampleAntiAlias := VAL_DEF_ANTI_ALIAS_FLOAT;

  // Set Audiophile System defaults
  FUseHighResTimer  := True;
  FOptimizeAffinity := True;
  FEnableMMCSS      := True;

  // Init DSP bypass
  FToneDirect       := VAL_DEF_TONE_DIRECT;
  FToneBassDB       := VAL_DEF_TONE_DB;
  FToneLowMidDB        := VAL_DEF_TONE_DB;
  FToneMidDB        := VAL_DEF_TONE_DB;
  FToneHighMidDB        := VAL_DEF_TONE_DB;
  FToneTrebleDB     := VAL_DEF_TONE_DB;
  FToneBassHz       := VAL_DEF_BASSHZ;
  FToneLowMidHz        := VAL_DEF_LOWMIDHZ;
  FToneMidHz        := VAL_DEF_MIDHZ;
  FToneHighMidHz        := VAL_DEF_HIGHMIDHZ;
  FToneTrebleHz     := VAL_DEF_TREBLEHZ;
  FToneLowMidWidth  := TONE_WIDTH_NORMAL;
  FToneMidWidth     := TONE_WIDTH_NORMAL;
  FToneHighMidWidth := TONE_WIDTH_NORMAL;
end;

destructor TAudioEngine.Destroy;
begin
  Stop;
  inherited;
end;

class procedure TAudioEngine.CheckLibraries;
begin
  if not FLibraryChecked then
  begin
    // FLAC decoder and resampler are built in
    FResamplerAvailable := True;
    FFlacAvailable      := True;
    FLibraryChecked     := True;
  end;
end;

class procedure TAudioEngine.EnumerateDevices(Devices: TStrings; out DefaultIndex: integer);
var
  EnumObj         : IMMDeviceEnumerator;
  Collection      : IMMDeviceCollection;
  Endpoint,
  DefaultEndpoint : IMMDevice;
  Props           : IPropertyStore;
  Count, I        : UINT;
  PV              : TPropVariant;
  IdStr           : pwidechar;
  DefaultId,
  CurrentId       : string;
  PropKeyName     : TPropertyKey;
  AddedIndex      : integer;
  Entry           : string;  // 'Name|Id', UTF-8
  HrCoInit        : HRESULT;
begin
  Devices.Clear;
  DefaultIndex := -1;
  DefaultId    := '';
  // Initialize PV up front to silence compiler hint
  PV           := Default(TPropVariant);

  // Ensure COM is initialized on the calling thread
  HrCoInit := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      if Failed(CoCreateInstance(CLSID_MMDeviceEnumerator,
                nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, EnumObj)) then
        Exit;

      if Succeeded(EnumObj.GetDefaultAudioEndpoint(0, 0, DefaultEndpoint)) then
      begin
        if Succeeded(DefaultEndpoint.GetId(IdStr)) then
        begin
          // The UTF-16 id as UTF-8
          DefaultId := UTF8Encode(UnicodeString(IdStr));
          CoTaskMemFree(IdStr);
        end;
      end;

      // Count and I are
      // unsigned, so with no active playback device (Count = 0) "Count - 1"
      // would be 4294967295 and the loop would call Item 4.3 billion times on
      // the UI thread (minutes, "Not responding"): hence "Count > 0". No
      // device happens during native DSD
      // over ASIO when the DAC's WASAPI endpoint is gone and it is the only
      // playback device of the PC; the device button and Preferences' Output
      // page list the devices. A failed GetCount leaves Count at 0.
      Count := 0;
      if Succeeded(EnumObj.EnumAudioEndpoints(0, 1, Collection)) and
         Succeeded(Collection.GetCount(Count)) and (Count > 0) then
      begin
        PropKeyName.fmtid := PKEY_Device_FriendlyName_FMTID;
        PropKeyName.pid   := PKEY_Device_FriendlyName_PID;
        for I := 0 to Count - 1 do
        begin
          if Succeeded(Collection.Item(I, Endpoint)) then
          begin
            if Succeeded(Endpoint.GetId(IdStr)) then
            begin
              // The UTF-16 id and name as UTF-8
              CurrentId := UTF8Encode(UnicodeString(IdStr));
              CoTaskMemFree(IdStr);
              if Succeeded(Endpoint.OpenPropertyStore(STGM_READ, Props)) then
              begin
                FillChar(PV, SizeOf(PV), 0);
                if Succeeded(Props.GetValue(PropKeyName, PV)) then
                begin
                  if PV.vt = 31 then
                    Entry := UTF8Encode(UnicodeString(PV.pwszVal)) + '|' + CurrentId
                  else
                    Entry := CurrentId + '|' + CurrentId;

                  AddedIndex := Devices.Add(Entry);

                  if CurrentId = DefaultId then
                    DefaultIndex := AddedIndex;
                  PropVariantClear(PV);
                end;
              end;
            end;
          end;
        end;
      end;
    except
      // Silent fail
    end;
  finally
    if Succeeded(HrCoInit) then
      CoUninitialize;
  end;
end;

class procedure TAudioEngine.EnumerateAsioDevices(Devices: TStrings);
begin
  TAsioOutput.EnumerateDrivers(Devices);
end;

class function TAudioEngine.GetDeviceFriendlyName(const DeviceId: string): string;
var
  EnumObj     : IMMDeviceEnumerator;
  Endpoint    : IMMDevice;
  Props       : IPropertyStore;
  PV          : TPropVariant;
  PropKeyName : TPropertyKey;
  WideId      : UnicodeString;
  HrCoInit    : HRESULT;
begin
  Result := '';
  if Length(DeviceId) = 0 then
    Exit;

  PV       := Default(TPropVariant);
  HrCoInit := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      if Succeeded(CoCreateInstance(CLSID_MMDeviceEnumerator,
                   nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, EnumObj)) then
      begin
        WideId := UTF8Decode(DeviceId); // explicit UTF-8 -> UTF-16
        if Succeeded(EnumObj.GetDevice(PWideChar(WideId), Endpoint)) and
           Succeeded(Endpoint.OpenPropertyStore(STGM_READ, Props)) then
        begin
          PropKeyName.fmtid := PKEY_Device_FriendlyName_FMTID;
          PropKeyName.pid   := PKEY_Device_FriendlyName_PID;
          if Succeeded(Props.GetValue(PropKeyName, PV)) then
          begin
            if PV.vt = 31 then
              Result := UTF8Encode(UnicodeString(PV.pwszVal)); // UTF-16 -> UTF-8
            PropVariantClear(PV);
          end;
        end;
      end;
    except
      Result := '';
    end;
  finally
    // Release the COM objects before CoUninitialize
    Props    := nil;
    Endpoint := nil;
    EnumObj  := nil;
    if Succeeded(HrCoInit) then
      CoUninitialize;
  end;
end;

function TAudioEngine.HasError: boolean;
begin
  Result := False;

  if Assigned(FCurrentThread) then
    Result := FCurrentThread.HasError;
end;

function TAudioEngine.GetErrorMessage: string;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.ErrorMessage
  else
    Result := ERR_AUDIO_UNKNOWN;
end;

function TAudioEngine.GetErrorType: TAudioErrorType;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.ErrorType
  else
    Result := aeNone;
end;

function TAudioEngine.GetFailedSampleRate: Integer;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.FailedSampleRate
  else
    Result := 0;
end;

function TAudioEngine.GetErrorDetail: string;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.ErrorDetail
  else
    Result := '';
end;

procedure TAudioEngine.Play(const FileName, DeviceId: string);
var
  Config: TPlayThreadConfig;
begin
  Stop;

  // Zero-initialize the managed record before populating
  Config := Default(TPlayThreadConfig);

  // Build the configuration payload
  Config.FileName           := FileName;
  Config.DeviceId           := DeviceId;
  Config.OutputApi          := FOutputApi;
  Config.AsioNativeDsd      := FAsioNativeDsd;
  Config.UseDoP             := FUseDoP;
  Config.ResamplePCM        := FResamplePCM;
  Config.TargetSampleRate   := FTargetSampleRate;
  Config.ResampleQuality    := FResampleQuality;
  Config.BufferMs           := FBufferMs;
  Config.RateMaps           := FRateMaps;
  Config.ReplayGainMode     := FReplayGainMode;
  Config.RGTrackTags        := FRGTrackTags;
  Config.RGAlbumTags        := FRGAlbumTags;
  Config.RGTrackPeakTags    := FRGTrackPeakTags;
  Config.RGAlbumPeakTags    := FRGAlbumPeakTags;
  Config.DisableVolume      := FDisableVolume;
  Config.PreampDB           := FPreampDB;
  Config.EnableSoftClipping := FEnableSoftClipping;
  Config.AutoHeadroom       := FAutoHeadroom;
  Config.UpsamplePhase      := FUpsamplePhase;
  Config.DownsamplePhase    := FDownsamplePhase;
  Config.ResampleBandWidth  := FResampleBandWidth;
  Config.ResampleAntiAlias  := FResampleAntiAlias;
  Config.DsdGainDB          := FDsdGain;
  Config.DsdLowPassFilter   := FDsdLowPassFilter;
  Config.UseHighResTimer    := FUseHighResTimer;
  Config.OptimizeAffinity   := FOptimizeAffinity;
  Config.EnableMMCSS        := FEnableMMCSS;

  // Map Tone Control to Thread
  Config.ToneDirect         := FToneDirect;
  Config.ToneBassDB         := FToneBassDB;
  Config.ToneLowMidDB          := FToneLowMidDB;
  Config.ToneMidDB          := FToneMidDB;
  Config.ToneHighMidDB          := FToneHighMidDB;
  Config.ToneTrebleDB       := FToneTrebleDB;
  Config.ToneBassHz         := FToneBassHz;
  Config.ToneLowMidHz          := FToneLowMidHz;
  Config.ToneMidHz          := FToneMidHz;
  Config.ToneHighMidHz          := FToneHighMidHz;
  Config.ToneTrebleHz       := FToneTrebleHz;
  Config.ToneLowMidWidth    := FToneLowMidWidth;
  Config.ToneMidWidth       := FToneMidWidth;
  Config.ToneHighMidWidth   := FToneHighMidWidth;

  Config.NotifyHandle       := FNotifyHandle;
  Config.StartVolume        := FVolume;
  // A stream closed just now (a switch of the output or a
  // setting during a track: RestartCurrent; the next track after the last
  // one ended): the device may still be changing over
  if (FLastCloseTick <> 0) and (GetTickCount64 - FLastCloseTick < SETTLE_MS) then
    Config.SettleMs := SETTLE_MS
  else
    Config.SettleMs := 0;

  // Pass the payload to the constructor
  Inc(FStreamId);
  FCurrentThread            := TPlayThread.Create(Config);
  Inc(FMeterEpoch);
  FCurrentThread.Start;
end;

// Waits at most PLAY_THREAD_STOP_TIMEOUT_MS for the play thread
// (never without a limit, as TThread.WaitFor would). See TPlayThread.StopAndWait:
// the wait runs no other threads' Synchronize / Queue calls in between,
// and a stuck thread does not freeze the window or the shutdown. It is set
// aside (RetiredThreads), logged, and freed once it has ended.
procedure TAudioEngine.Stop;
var
  OldThread: TPlayThread;
begin
  if Assigned(FCurrentThread) then
  begin
    OldThread      := FCurrentThread;
    FCurrentThread := nil;

    if OldThread.StopAndWait(PLAY_THREAD_STOP_TIMEOUT_MS) then
    begin
      if OldThread.ClosedTick <> 0 then
        FLastCloseTick := OldThread.ClosedTick;
      OldThread.Free;
    end
    else
    begin
      FLastCloseTick := GetTickCount64;   // still closing: the device is busy
      if not Assigned(RetiredThreads) then
        RetiredThreads := TList.Create;
      RetiredThreads.Add(OldThread);
      LogEvent(ord(alPlayThreadStopTimeout), PLAY_THREAD_STOP_TIMEOUT_MS);
    end;
  end;

  // Set-aside threads that have ended in the meantime
  ReapRetiredThreads(0);
end;

procedure TAudioEngine.Pause;
begin
  if Assigned(FCurrentThread) then
    FCurrentThread.Pause;
end;

procedure TAudioEngine.Resume;
begin
  if Assigned(FCurrentThread) then
    FCurrentThread.Resume;
end;

procedure TAudioEngine.Seek(Percent: double);
begin
  Inc(FMeterEpoch);
  if Assigned(FCurrentThread) then
    FCurrentThread.Seek(Percent);
end;

function TAudioEngine.SetNextFile(const FileName: string): Boolean;
begin
  Result := True;
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.SetNextFile(FileName);
end;

function TAudioEngine.GetNextPrepareParams(out AParams: TNextPrepareParams): Boolean;
begin
  AParams := Default(TNextPrepareParams);
  Result  := Assigned(FCurrentThread);
  if Result then
  begin
    FCurrentThread.GetPrepareParams(AParams);
    AParams.StreamId := FStreamId;
  end;
end;

function TAudioEngine.SetPreparedNext(var APrep: TPreparedNext): Boolean;
begin
  Result := True;
  if Assigned(FCurrentThread) and (APrep.StreamId = FStreamId) then
    Result := FCurrentThread.SetPreparedNext(APrep);
  // Not handed over (no play thread, or built for an earlier one)
  FreePreparedNext(APrep);
end;

procedure TAudioEngine.SetVolume(Value: integer);
begin
  FVolume := Value;
  if Assigned(FCurrentThread) then
    FCurrentThread.SetVolume(Value);
end;

procedure TAudioEngine.SetToneControl(const State: TToneState);
begin
  FToneDirect   := State.DirectMode;
  FToneBassDB   := State.BassDB;
  FToneLowMidDB    := State.LowMidDB;
  FToneMidDB    := State.MidDB;
  FToneHighMidDB    := State.HighMidDB;
  FToneTrebleDB := State.TrebleDB;
  FToneBassHz   := State.BassHz;
  FToneLowMidHz    := State.LowMidHz;
  FToneMidHz    := State.MidHz;
  FToneHighMidHz    := State.HighMidHz;
  FToneTrebleHz := State.TrebleHz;
  FToneLowMidWidth  := State.LowMidWidth;
  FToneMidWidth     := State.MidWidth;
  FToneHighMidWidth := State.HighMidWidth;

  if Assigned(FCurrentThread) then
    FCurrentThread.SetToneControl(State);
end;

procedure TAudioEngine.SetDSDGainDB(Value: Integer);
begin
  FDsdGain := Value;
  if Assigned(FCurrentThread) then
  begin
    // Do not overwrite FCurrentThread.DsdGainDB before
    // calling SetDSDGain(Value)! SetDSDGain updates FConfig.DsdGainDB under
    // FLock and needs the previous value to calculate DeltaDB for ReplayGain.
    FCurrentThread.SetDSDGain(Value);
  end;
end;

procedure TAudioEngine.LogEvent(EventCode: integer; HRes: HRESULT);
begin
  if FNotifyHandle <> 0 then
    PostMessage(FNotifyHandle, WM_AUDIO_ENGINE_LOG, EventCode, HRes);
end;

procedure TAudioEngine.SetNotifyHandle(Value: THandle);
begin
  FNotifyHandle := Value;
  if Assigned(FCurrentThread) then
    FCurrentThread.NotifyHandle := Value;
end;

procedure TAudioEngine.ForceGaplessSwap;
begin
  if Assigned(FCurrentThread) then
    FCurrentThread.ForceGaplessSwap;
end;

procedure TAudioEngine.GetAndClearPeaks(out L, R: double; out cL, cR: boolean);
begin
  if Assigned(FCurrentThread) then
    FCurrentThread.GetAndClearPeaks(L, R, cL, cR)
  else
  begin
    L  := 0;
    R  := 0;
    cL := False;
    cR := False;
  end;
end;

procedure TAudioEngine.ReadPeaks(out L, R: double; out HasL, HasR: boolean; out cL, cR: boolean);
begin
  if Assigned(FCurrentThread) then
    FCurrentThread.ReadPeaks(L, R, HasL, HasR, cL, cR)
  else
  begin
    L    := 0;
    R    := 0;
    HasL := False;
    HasR := False;
    cL   := False;
    cR   := False;
  end;
end;

procedure TAudioEngine.ReadMeterSlices(var Dest: array of TMeterSlice; out Count: Integer);
begin
  if Assigned(FCurrentThread) then
    FCurrentThread.ReadMeterSlices(Dest, Count)
  else
    Count := 0;
end;

function TAudioEngine.IsPlaying: boolean;
begin
  Result := Assigned(FCurrentThread);
end;

function TAudioEngine.IsPaused: boolean;
begin
  Result := False;
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.IsPaused;
end;

function TAudioEngine.HasFinished: boolean;
begin
  Result := False;
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.Finished;
end;

function TAudioEngine.GetProgress: double;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.Progress
  else
    Result := 0.0;
end;

function TAudioEngine.GetDuration: double;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.Duration
  else
    Result := 0.0;
end;

function TAudioEngine.WasTrackSwapped: boolean;
begin
  Result := False;
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.ReadAndClearSwapFlag;
end;

function TAudioEngine.GetInputRate: integer;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.InputSampleRate
  else
    Result := 0;
end;

function TAudioEngine.GetOutputRate: integer;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.OutputSampleRate
  else
    Result := 0;
end;

function TAudioEngine.CheckClipping: boolean;
begin
  Result := False;
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.WasClipped;
end;

procedure TAudioEngine.SetRateMapping(const Maps: array of TRateMap);
var
  I: integer;
begin
  SetLength(FRateMaps, Length(Maps));

  for I := 0 to High(Maps) do
    FRateMaps[I] := Maps[I];
end;

function TAudioEngine.GetAppliedReplayGain: double;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.GetAppliedReplayGain
  else
    Result := 0.0;
end;

function TAudioEngine.IsBitPerfect: boolean;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.IsBitPerfect
  else
    Result := False;
end;

function TAudioEngine.GetSignalInfo: TSignalInfo;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.GetSignalInfo
  else
    Result := Default(TSignalInfo);
end;

function TAudioEngine.GetBitDepth: integer;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.GetBitDepth
  else
    Result := 0;
end;

function TAudioEngine.GetChannels: integer;
begin
  if Assigned(FCurrentThread) then
    Result := FCurrentThread.GetChannels
  else
    Result := 0;
end;

finalization
  // Only the list. A play thread that is still running at this point
  // is left alone (it owns all its data); Windows ends it with the process.
  FreeAndNil(RetiredThreads);

end.
