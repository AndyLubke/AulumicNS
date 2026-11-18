unit ALAudioThread;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALAudioThread
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The play thread (TPlayThread): the time-critical part of playback. It reads
  the audio source of the track (decoder, the built-in resampler, DSD as DoP
  or converted to PCM), runs the gain stage (volume, ReplayGain, automatic
  headroom, tone control; none of it when the output is bit-perfect) and
  hands whole buffers to the output - WASAPI exclusive mode or ASIO
  (ALAudioOutput). Gapless track changes, seeking, the peak levels for the
  meter and the diagnostics of the output are here too.
  ---> CHANGED (ObjFPC switch, step 2): ObjFPC like the rest of Aulumic: file
  name, device id and error texts are UTF-8; UTF-16 only at the Windows W
  calls (module name of a code address, the MMCSS task name).
  =============================================================================}

interface

uses
  Classes, SysUtils, Windows, ActiveX, ComObj, Dialogs, ALReaders,
  Math, ALAudioTypes, AuLog, uToneControl,
  // ---> REMOVED (phase 7b): libSoxr_Dynamic, ALMetadata (only the source
  // building used them; it is in ALSourceFactory now)
  // ---> REMOVED (output split, step 2b): ALWasapiApi (the WASAPI calls are in
  // ALOutputWasapi now)
  ALSourceFactory,  // ---> ADDED (phase 7b): TPlayThreadConfig, source building (moved there)
  ALAudioOutput,    // ---> MOVED (output split, step 3a): from the implementation (TAudioOutputFactory)
  uAudioUtils;      // ---> AulumicNS: TSignalInfo (moved from the implementation uses)

const
  // ---> MOVED (phase 7a): The WASAPI GUIDs, error codes, wave format
  // records and COM interfaces are in ALWasapiApi (used by ALOutputWasapi)

  // Device availability (DAC switched off / unplugged / switched on again)
  DEVICE_POLL_MS        = 250;   // poll step while waiting for the device
  DEVICE_RETRY_MS       = 1000;  // wait after a failed format check / Initialize
  RECOVERY_WINDOW_MS    = 20000; // how long a recovery may take (a DAC switching on needs several seconds)
  // ---> AulumicNS: a refused format is asked again FORMAT_RETRIES times,
  // FORMAT_RETRY_MS apart (a DAC that changes mode: see RunOutput)
  FORMAT_RETRIES        = 4;
  FORMAT_RETRY_MS       = 500;
  RECOVERY_STABLE_MS    = 5000;  // normal buffer flow this long ends the recovery

type
  // ---> MOVED (phase 7b): TPlayThreadConfig, TNextPrepareParams and
  // TPreparedNext are in ALSourceFactory

  // ---> AulumicNS: the two gain stages RunGain works for: integer samples
  // (ApplyDSPBlock) and the resampler's doubles (ApplyFloatDSPBlock)
  TGainKind = (gkInt, gkFloat);

  { TPlayThread }

  TPlayThread = class(TThread)
  private
    FConfig           : TPlayThreadConfig;
    FNotifyHandle     : THandle;
    // ---> AulumicNS: GetTickCount64 when the output was closed last (0 =
    // never); TAudioEngine.Stop reads it after the thread ended
    FClosedTick       : QWord;
    FFileName         : string;

    FSource           : TAudioSource;
    FNextSource       : TAudioSource;
    FStopEvent        : THandle;
    FVolumeInt        : integer;
    FToneState        : TToneState;
    FToneDirty        : boolean;
    FToneGlided       : Boolean;  // ---> AulumicNS: the tone control was gliding in the last block (RunGain)
    FDitherSeed       : Cardinal;

    // ---> AUDIT FIX 3.3: Bit depth negotiated with WASAPI (0 = not yet known).
    // Lets SetNextFile pre-wrap the next source in a TBitDepthConverterSource on
    // the UI thread so CommitSeamlessSwap normally allocates nothing under FLock.
    FNegotiatedBits   : integer;
    // ---> ADDED: Valid bits of the negotiated format (e.g. 24 in a 32-bit
    // container; 0 = not yet known), and the bit-perfect state of the last
    // buffer (1 = untouched, see ApplyDSP). Both via Interlocked*.
    FNegotiatedValid  : integer;
    FBitPerfect       : integer;
    // ---> AulumicNS: 1 = the open output sends DSD as DSD (ASIO), Interlocked
    FNativeDsdOut     : integer;
    // ---> AUDIT FIX 3.3: A retired source handed from the render thread to the
    // UI thread (freed in ReadAndClearSwapFlag) so file handles, decoders and
    // soxr states are normally not torn down on the MMCSS thread.
    FPendingFree      : TAudioSource;

    FProgressCache    : double;
    FDurationCache    : double;
    FToneControl      : TToneControl;

    FOutputFramesWritten: int64;
    FTotalFrames        : int64;

    FSeekRequested    : boolean;
    FSeekPosition     : double;
    FPaused           : boolean;
    FTrackSwapped     : boolean;

    FInputSampleRate  : integer;
    FOutputSampleRate : integer;
    FNextInputRate    : integer;
    FNextOutputRate   : integer;
    FWasClipped       : boolean;
    FLock             : TRTLCriticalSection;

    FErrorType        : TAudioErrorType;
    FFailedSampleRate : Integer;
    FErrorMessage     : string;
    // ---> ADDED: Technical details of an unexpected exception (class, message,
    // module + offset) for the log; the user sees FErrorMessage. Under FLock.
    FErrorDetail      : string;

    FForceGaplessSwap : boolean;
    FCurrentIsDSD     : boolean;
    FNextIsDSD        : boolean;

    // ---> ADDED (output split, step 3a): see OutputFactory
    FOutputFactory    : TAudioOutputFactory;

    FReplayGainDB       : double;
    FReplayGainPeak     : double;
    FRGFactor           : double;
    FNextReplayGainDB   : double;
    FNextReplayGainPeak : double;
    FNextRGFactor       : double;
    { ---> AulumicNS: the DSD gain (FConfig.DsdGainDB) as a factor, applied by
      ApplyDSP / ApplyResamplerFloatDSP to DSD converted to PCM (also with the
      volume locked); the converter itself works at 0 dB }
    FDsdGainLin         : double;
    { ---> AulumicNS: the gain the block routines work with (FGainNow), the
      gain of the last frame played (FGainCur; -1 = no block yet) and the
      glide in work: from FRampFrom to FRampTo over FRampLen frames, FRampPos
      of them done (the gain rests at FRampTo when they are equal). A change
      of the gain (volume, ReplayGain with the preamp, DSD gain: TargetGain;
      the headroom) is not applied in one step: see RunGain. }
    FGainNow            : double;
    FGainCur            : double;
    FRampFrom           : double;
    FRampTo             : double;
    FRampLen            : integer;
    FRampPos            : integer;
    { ---> AulumicNS: automatic headroom (RunGain). The album and chain of
      the track in work and of the queued one (CalcHeadroomKey), the highest
      peak of that album before the gain (of full scale; from the book and
      from the blocks played), the gain limit learned from blocks that went
      over behind the tone control (HEAD_NO_CAP = none), the highest output
      of the block in work (of full scale, set by the block routines) and,
      for the signal path, what the headroom takes off (1/1000 dB). All but
      the last and FNextHeadKey (under FLock) are the play thread's. }
    FHeadKey            : string;
    FNextHeadKey        : string;
    FHeadPeak           : double;
    { the peak the cap works with: FHeadPeak, or with the tone control
      active the highest peak behind it (of this album and tone setting;
      not kept), and the levels behind the tone control of the block in
      work, one per frame }
    FHeadUse            : double;
    FToneLevels         : array of Double;
    FHeadOverCap        : double;
    FBlockOutPeak       : double;
    FVolatileHeadroom   : integer;

    FVolatilePeakL      : integer;
    FVolatilePeakR      : integer;
    FVolatileClipL      : integer;
    FVolatileClipR      : integer;

    // ---> ADDED: Peak meter slices (see ScanMeterSlices / ReadMeterSlices).
    // FMeterRing and FMeterWriteCount are written by the audio thread only;
    // FMeterReadCount is used by the UI thread only.
    FMeterRing       : array[0..METER_RING_SIZE - 1] of TMeterSlice;
    FMeterWriteCount : LongInt;
    FMeterReadCount  : LongInt;
    FSliceRate       : Cardinal;   // audio thread only
    FSliceFrames     : Integer;
    FSliceFill       : Integer;
    FSliceMaxL       : Int64;
    FSliceMaxR       : Int64;

    procedure ScanMeterSlices(Buffer: Pointer; BytesRead: integer);

    procedure CalculateReplayGainForFile(const AFileName: string; out OutGain, OutPeak: double);
    function  CalculateRGFactor(GainDB, Peak: double): double;
    procedure DeferFreeSource(var ASource: TAudioSource);

    procedure RunOutput;  // ---> CHANGED (output split, step 2b): was RunWasapi
    procedure ApplyDSP(Buffer: Pointer; BytesRead: integer);
    procedure ApplyResamplerFloatDSP(Buffer: PDouble; FrameCount, Channels, OutBits: Integer;
                                         out OutClipped: Boolean);
    // ---> AulumicNS: the two above hand the samples to RunGain (the glide to
    // a new gain, the automatic headroom), and that to these, which work
    // with the one gain FGainNow (they were ApplyDSP and
    // ApplyResamplerFloatDSP themselves)
    procedure ApplyDSPBlock(Buffer: Pointer; BytesRead: integer);
    procedure ApplyFloatDSPBlock(Buffer: PDouble; FrameCount, Channels, OutBits: Integer;
                                 out OutClipped: Boolean);
    function  TargetGain: Double;
    procedure RunGain(AKind: TGainKind; ABuffer: Pointer;
                      AFrames, AChannels, ABits, ARate: Integer; out AClipped: Boolean);
    procedure HeadroomForTrack(const AKey: string);
    procedure SyncToneSettings;
    function  ToneLevelsOf(AKind: TGainKind; ABuffer: Pointer; AFrames, AChannels, ABits: Integer): Double;

    procedure FadeOutLastBlock(Buffer: Pointer; BytesRead: integer; BitDepth: integer);

    function  CreateSource(const Filename: string; out InRate, OutRate: integer): TAudioSource;
    procedure FillDsdSilence(Buffer: Pointer; ByteCount, BitDepth: integer; var ADoPMarker: byte);
    // ---> ADDED (output split, step 1): one buffer's work in one place each,
    // instead of three copies in RunOutput (independent of the device)
    procedure FillTail(PTail: PByte; ACount: Integer; AIsDoP: Boolean);
    procedure CountOutputFrames(ABytes, ABlockAlign: Integer; AUpdateProgress: Boolean);
    function  FillBlock(PData: PByte; ABytes, ABlockAlign: Integer;
                        AUpdateProgress: Boolean): Integer;
    procedure LogEvent(EventCode: integer; HRes: HRESULT = 0);
    // ---> AulumicNS: a log event with a 64-bit value (the LPARAM on Win64)
    procedure LogEvent64(EventCode: integer; AValue: Int64);

    procedure UpdatePeakAtomic(var Target: integer; NewValue: integer);
    function  GetHasError: boolean;
    // ---> AUDIT FIX 3.2: Thread-safe getters for error state
    function  GetErrorMessageSafe: string;
    function  GetErrorTypeSafe: TAudioErrorType;
    function  GetFailedSampleRateSafe: Integer;
    function  GetErrorDetailSafe: string;

  protected
    procedure Execute; override;
    procedure SetError(ErrType: TAudioErrorType; const Msg: string; RateInfo: Integer = 0;
      const ADetail: string = '');

  public
    property TrackSwapped: boolean read FTrackSwapped write FTrackSwapped;
    // ---> AUDIT FIX 3.2: Route error properties through thread-safe getters
    property ErrorMessage: string read GetErrorMessageSafe;
    property UseDoP: boolean read FConfig.UseDoP write FConfig.UseDoP;
    property ResamplePCM: boolean read FConfig.ResamplePCM write FConfig.ResamplePCM;
    property Progress: double read FProgressCache;
    property Duration: double read FDurationCache;
    property InputSampleRate: integer read FInputSampleRate;
    property OutputSampleRate: integer read FOutputSampleRate;
    property WasClipped: boolean read FWasClipped;
    property HasError: boolean read GetHasError;
    property NotifyHandle: THandle read FNotifyHandle write FNotifyHandle;
    property ClosedTick: QWord read FClosedTick;
    class var FLastHardwareRate: integer;

    property DsdGainDB: Integer read FConfig.DsdGainDB write FConfig.DsdGainDB;
    property DsdLowPassFilter: Boolean read FConfig.DsdLowPassFilter write FConfig.DsdLowPassFilter;

    property ErrorType : TAudioErrorType read GetErrorTypeSafe;
    property FailedSampleRate: integer read GetFailedSampleRateSafe;
    // ---> ADDED: '' unless the thread stopped on an unexpected exception
    property ErrorDetail: string read GetErrorDetailSafe;

    // ---> ADDED (output split, step 3a): Makes the output for each open of
    // the device; set before Start. Not set (TAudioEngine never sets it) = a
    // TWasapiOutput. The test program plays into a memory output with it.
    property OutputFactory: TAudioOutputFactory read FOutputFactory write FOutputFactory;

    // Thread-Level Optimization Properties
    property UseHighResTimer: boolean read FConfig.UseHighResTimer write FConfig.UseHighResTimer;
    property OptimizeAffinity: boolean read FConfig.OptimizeAffinity write FConfig.OptimizeAffinity;
    property EnableMMCSS: boolean read FConfig.EnableMMCSS write FConfig.EnableMMCSS;

    constructor Create(const Config: TPlayThreadConfig);
    destructor Destroy; override;

    procedure StopPlayback;
    // ---> ADDED: Asks the thread to stop and waits up to ATimeoutMs for it to
    // end. True = ended (it can be freed without blocking). UI thread.
    function  StopAndWait(ATimeoutMs: Cardinal): Boolean;
    procedure SetVolume(Value: integer);
    procedure SetToneControl(const State: TToneState);
    procedure Seek(Percent: double);
    procedure Pause;
    procedure Resume;
    function  IsPaused: boolean;
    function  ReadAndClearSwapFlag: Boolean;
    // ---> AUDIT FIX: Returns False (and queues nothing) when a gapless swap has
    // happened that the UI has not consumed yet: the caller's idea of "next" is
    // then stale. Returns True in every other case (including load failures).
    function  SetNextFile(const NextFileName: string): Boolean;
    // ---> ADDED: Snapshot for PrepareNextSource (any thread may then use it)
    procedure GetPrepareParams(out AParams: TNextPrepareParams);
    // ---> ADDED: Queues a source built by PrepareNextSource; takes ownership
    // of APrep.Source in every case. Result as SetNextFile.
    function  SetPreparedNext(var APrep: TPreparedNext): Boolean;
    procedure ForceGaplessSwap;
    procedure SetDSDGain(GainDB: Integer);
    procedure GetAndClearPeaks(out L, R: double; out cL, cR: boolean);
    // ---> ADDED: Like GetAndClearPeaks, but also reports per channel whether
    // a new block was measured since the previous read (HasL / HasR)
    procedure ReadPeaks(out L, R: double; out HasL, HasR: boolean; out cL, cR: boolean);
    // ---> ADDED: Copies the meter slices measured since the previous call
    // (oldest first, at most Length(Dest)). UI thread only.
    procedure ReadMeterSlices(var Dest: array of TMeterSlice; out Count: Integer);

    function GetAppliedReplayGain: double;
    function GetBitDepth: integer;
    function GetChannels: integer;
    // ---> ADDED: True when the last buffer reached the DAC untouched
    function IsBitPerfect: boolean;
    // ---> AulumicNS: the stages of the signal path (UI thread; reads only)
    function GetSignalInfo: TSignalInfo;
  end;


// ---> MOVED (phase 7b): PrepareNextSource and FreePreparedNext are in
// ALSourceFactory

// ---> ADDED: Rounds ACount 32-bit samples to their top AValidBits (16..31)
// with TPDF dither of +-1 step: the bits below become 0 and a full-scale
// sample stays inside the container. For a DAC opened with fewer valid bits
// than its 32-bit container (24 in 32), which ignores the bits below. Any
// other AValidBits leaves the samples unchanged. ASeed: the dither's xorshift
// state (0 = the default start). Used by ApplyDSP; no allocation, no locks.
procedure RoundSamplesToValidBits(ASamples: PLongInt; ACount, AValidBits: Integer;
  var ASeed: Cardinal);

implementation

uses uAppStrings, uMetaUtils, uOSUtils,
  ALHeadroom,      // ---> AulumicNS: the automatic headroom's ceiling and book
  ALOutputWasapi,  // ---> ADDED (output split, step 2a)
  ALOutputAsio;    // ---> AulumicNS: the ASIO output

// =========================================================================
// AUDIO MATH CONSTANTS (Strictly for local DSP use)
// =========================================================================
const
  // 16-Bit Boundaries
  PCM16_MAX_INT = 32767;
  PCM16_MIN_INT = -32768;
  PCM16_MAX_FLT = 32768.0;
  PCM16_CLIP_TH = 26214.0; // 80% Threshold
  PCM16_CLIP_HR = 6554.0;  // 20% Headroom

  // 24-Bit Boundaries
  PCM24_MAX_INT = 8388607;
  PCM24_MIN_INT = -8388608;
  PCM24_MAX_FLT = 8388608.0;
  PCM24_CLIP_TH = 6710886.0; // 80% Threshold
  PCM24_CLIP_HR = 1677722.0; // 20% Headroom

  // 32-Bit Boundaries
  PCM32_MAX_INT = 2147483647;
  PCM32_MIN_INT = -2147483648;
  PCM32_MAX_FLT = 2147483648.0;
  PCM32_CLIP_TH = 1717986918.0; // 80% Threshold
  PCM32_CLIP_HR = 429496730.0;  // 20% Headroom

  // ---> ADDED: The start of a TPDF dither (as ApplyDSP's DEFAULT_PRNG_SEED)
  DITHER_DEFAULT_SEED = $A341316C;

  // ---> MOVED (phase 7b): RG_MIN_GAIN_DB / RG_MAX_GAIN_DB are in ALSourceFactory

// Import Timer API from winmm.dll
function timeBeginPeriod(uPeriod: UINT): UINT; stdcall; external 'winmm.dll' name 'timeBeginPeriod';
function timeEndPeriod(uPeriod: UINT): UINT; stdcall; external 'winmm.dll' name 'timeEndPeriod';

// ---> ADDED: For the error details of unexpected exceptions (DescribeException)
function AL_GetModuleHandleExW(dwFlags: DWORD; lpModuleName: PWideChar;
  var phModule: HMODULE): BOOL; stdcall; external 'kernel32.dll' name 'GetModuleHandleExW';

const
  AL_MODULE_FROM_ADDRESS      = $00000004; // GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
  AL_MODULE_UNCHANGED_REFCNT  = $00000002; // GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT

// ---> ADDED: 'Aulumic.exe+$1A2B3C' or 'libFLAC.dll+$4D5E' for a code address,
// so a log line tells whether an error happened in Aulumic or in a library
// (and, with the map / debug file of that build, where). '$ADDRESS' when the
// address belongs to no module.
function DescribeCodeAddress(AAddr: Pointer): string;
var
  Module : HMODULE;
  Name   : array[0..MAX_PATH] of WideChar;
  Len    : DWORD;
begin
  Module := 0;
  if (AAddr <> nil) and
     AL_GetModuleHandleExW(AL_MODULE_FROM_ADDRESS or AL_MODULE_UNCHANGED_REFCNT,
       PWideChar(AAddr), Module) and (Module <> 0) then
  begin
    Len := GetModuleFileNameW(Module, @Name[0], MAX_PATH);
    if Len > 0 then
    begin
      // ---> CHANGED (ObjFPC switch): the UTF-16 module path as UTF-8
      Result := ExtractFileName(UTF8Encode(UnicodeString(PWideChar(@Name[0])))) + '+$' +
                IntToHex(PtrUInt(AAddr) - PtrUInt(Module), 1);
      Exit;
    end;
  end;
  Result := '$' + IntToHex(PtrUInt(AAddr), SizeOf(Pointer) * 2);
end;

// ---> ADDED: Class, message and place of an exception, for the log
function DescribeException(E: TObject; AAddr: Pointer): string;
begin
  if E is Exception then
    Result := E.ClassName + ': ' + Exception(E).Message
  else if Assigned(E) then
    Result := E.ClassName
  else
    Result := 'unknown exception object';
  Result := Result + ' at ' + DescribeCodeAddress(AAddr);
end;

// ---> MOVED (phase 7b): The source building (CalcTargetRate, CalcRGFactor,
// CalcReplayGainForFile, CreateSourceFor, PrepareNextSource,
// FreePreparedNext) is in ALSourceFactory

{ TPlayThread }

constructor TPlayThread.Create(const Config: TPlayThreadConfig);
begin
  inherited Create(True);
  Priority := tpTimeCritical;

  InitializeCriticalSection(FLock);

  FConfig := Config;

  // Initialize mutable fields
  FFileName     := Config.FileName;
  FNotifyHandle := Config.NotifyHandle;
  FVolumeInt    := Config.StartVolume;

  // Hardcoded internal state initializations
  FStopEvent           := CreateEvent(nil, True, False, nil);
  FreeOnTerminate      := False;
  FWasClipped          := False;
  FErrorType           := aeNone;
  FFailedSampleRate    := 0;
  FErrorMessage        := '';
  FForceGaplessSwap    := False;
  FCurrentIsDSD        := False;
  FNextIsDSD           := False;
  FOutputFactory       := nil;
  FOutputFramesWritten := 0;
  FTotalFrames         := 1;
  FNegotiatedBits      := 0;
  FNegotiatedValid     := 0;
  FBitPerfect          := 0;
  FPendingFree         := nil;

  FReplayGainDB        := 0.0;
  FReplayGainPeak      := 0.0;
  FRGFactor            := CalculateRGFactor(0.0, 0.0);
  FNextReplayGainDB    := 0.0;
  FNextReplayGainPeak  := 0.0;
  FNextRGFactor        := 1.0;
  FDsdGainLin          := Power(10.0, FConfig.DsdGainDB / 20.0);
  FGainNow             := 1.0;
  FGainCur             := -1.0;   // the first block starts at its gain, no glide
  FRampFrom            := 1.0;
  FRampTo              := 1.0;
  FRampLen             := 0;
  FRampPos             := 0;
  FHeadKey             := '';
  FNextHeadKey         := '';
  FHeadPeak            := 0.0;
  FHeadUse             := 0.0;
  FToneLevels          := nil;
  FHeadOverCap         := 1.0e30; // HEAD_NO_CAP
  FBlockOutPeak        := 0.0;
  FVolatileHeadroom    := 0;

  FVolatilePeakL       := 0;
  FVolatilePeakR       := 0;
  FVolatileClipL       := 0;
  FVolatileClipR       := 0;

  // Map the config payload into our thread-safe record
  FToneState.DirectMode := Config.ToneDirect;
  FToneState.BassDB     := Config.ToneBassDB;
  FToneState.LowMidDB      := Config.ToneLowMidDB;
  FToneState.MidDB      := Config.ToneMidDB;
  FToneState.HighMidDB      := Config.ToneHighMidDB;
  FToneState.TrebleDB   := Config.ToneTrebleDB;
  FToneState.BassHz     := Config.ToneBassHz;
  FToneState.LowMidHz      := Config.ToneLowMidHz;
  FToneState.MidHz      := Config.ToneMidHz;
  FToneState.HighMidHz      := Config.ToneHighMidHz;
  FToneState.TrebleHz   := Config.ToneTrebleHz;
  FToneDirty            := True;
  FDitherSeed           := $A341316C;

  FToneControl := TToneControl.Create;
end;

// ---> CHANGED: Body moved to CalcRGFactor (shared with PrepareNextSource)
function TPlayThread.CalculateRGFactor(GainDB, Peak: double): double;
begin
  Result := CalcRGFactor(FConfig, GainDB, Peak);
end;

// ---> CHANGED: Body moved to CalcReplayGainForFile (shared with PrepareNextSource)
procedure TPlayThread.CalculateReplayGainForFile(const AFileName: string;
  out OutGain, OutPeak: double);
var
  LocalDsdGainDB : Integer;
begin
  // ---> AUDIT FIX 3.4: Snapshot DsdGainDB under FLock
  EnterCriticalSection(FLock);
  try
    LocalDsdGainDB := FConfig.DsdGainDB;
  finally
    LeaveCriticalSection(FLock);
  end;

  CalcReplayGainForFile(FConfig, LocalDsdGainDB, AFileName, OutGain, OutPeak);
end;

destructor TPlayThread.Destroy;
begin
  // 1. Signal the WASAPI loop to break
  if FStopEvent <> 0 then
    SetEvent(FStopEvent);
  Terminate;

  // 2. The Absolute Gatekeeper
  // ---> CHANGED: WaitForSingleObject instead of TThread.WaitFor (see
  // StopAndWait). Normally TAudioEngine has already waited with a time limit,
  // so the thread has ended. Not when it never started (constructor failed:
  // TThread.Destroy starts and ends it) or already finished.
  if (not Finished) and (not Suspended) then
    Windows.WaitForSingleObject(Handle, INFINITE);

  // 3. Silently clean up native OS Handles
  try
    if FStopEvent <> 0 then
      CloseHandle(FStopEvent);
  except
    // Swallow silently
  end;

  try
    DeleteCriticalSection(FLock);
  except
    // Swallow silently
  end;

  FToneControl.Free;

  if Assigned(FSource) then
    FreeAndNil(FSource);

  if Assigned(FNextSource) then
    FreeAndNil(FNextSource);

  // ---> AUDIT FIX 3.3: Free a retired source the UI never collected
  if Assigned(FPendingFree) then
    FreeAndNil(FPendingFree);

  inherited;
end;

// ---> AUDIT FIX 3.3: Called on the render thread after a gapless swap. Parks the
// retired source for the UI thread (ReadAndClearSwapFlag frees it). Only if the
// UI has not collected the previous one yet is that older one freed here.
procedure TPlayThread.DeferFreeSource(var ASource: TAudioSource);
var
  Older: TAudioSource;
begin
  EnterCriticalSection(FLock);
  try
    Older        := FPendingFree;
    FPendingFree := ASource;
  finally
    LeaveCriticalSection(FLock);
  end;
  ASource := nil;

  if Assigned(Older) then
    FreeAndNil(Older);
end;

procedure TPlayThread.StopPlayback;
begin
  SetEvent(FStopEvent);
end;

// ---> ADDED: Waits with WaitForSingleObject, not TThread.WaitFor. On the UI
// thread, TThread.WaitFor also runs the Synchronize / Queue calls of every
// other thread while it waits, so e.g. the metadata custodian could pause the
// player in the middle of TPlaybackManager.PlayNext. This thread never calls
// Synchronize or Queue (it only posts WM_AUDIO_ENGINE_LOG), so a plain wait
// cannot deadlock. The time limit keeps the window responsive when the thread
// is stuck in a file read (unreachable drive) or in the audio driver.
// ---> AulumicNS: ... and it delivers the messages SENT to this thread's
// windows while it waits (only those: input, timers and Synchronize / Queue
// stay queued). A driver that sends to a window of this thread while it stops
// (the play thread waits for that in TAsioOutput.Close) no longer waits for
// the time limit. (ASIO drivers once got the main window at init; they now
// get a window of their host thread, see ALOutputAsio.CreateHostWindow.)
function TPlayThread.StopAndWait(ATimeoutMs: Cardinal): Boolean;
const
  PM_QS_SENDMESSAGE_ = QS_SENDMESSAGE shl 16;   // PeekMessage: sent messages only
var
  H: THandle;
  StartTick, Elapsed: QWord;
  R: DWORD;
  Msg: TMsg;
begin
  if FStopEvent <> 0 then
    SetEvent(FStopEvent);
  Terminate;

  // Never started: nothing runs, TThread.Destroy takes care of it
  if Suspended then
    Exit(True);

  H := Handle;
  StartTick := GetTickCount64;
  PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE_);   // already pending ones
  repeat
    Elapsed := GetTickCount64 - StartTick;
    if Elapsed >= ATimeoutMs then
      Exit(Windows.WaitForSingleObject(H, 0) = WAIT_OBJECT_0);
    R := MsgWaitForMultipleObjects(1, H, False, DWORD(ATimeoutMs - Elapsed), QS_SENDMESSAGE);
    if R = WAIT_OBJECT_0 then
      Exit(True);
    if R <> WAIT_OBJECT_0 + 1 then
      Exit(Windows.WaitForSingleObject(H, 0) = WAIT_OBJECT_0);
    PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE_);   // delivers the sent ones
  until False;
end;

procedure TPlayThread.Pause;
begin
  FPaused := True;
end;

procedure TPlayThread.Resume;
begin
  FPaused := False;
end;

function TPlayThread.IsPaused: boolean;
begin
  Result := FPaused;
end;

function TPlayThread.ReadAndClearSwapFlag: Boolean;
var
  ToFree: TAudioSource;
begin
  EnterCriticalSection(FLock);
  try
    Result := FTrackSwapped;
    FTrackSwapped := False;
    // ---> AUDIT FIX 3.3: Collect the source retired by the render thread
    ToFree       := FPendingFree;
    FPendingFree := nil;
  finally
    LeaveCriticalSection(FLock);
  end;

  // Freed on the calling (UI) thread, outside FLock
  if Assigned(ToFree) then
    ToFree.Free;
end;

procedure TPlayThread.SetVolume(Value: integer);
begin
  InterlockedExchange(FVolumeInt, Value);
end;

procedure TPlayThread.SetToneControl(const State: TToneState);
begin
  EnterCriticalSection(FLock);
  try
    FToneState := State;
    FToneDirty := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPlayThread.Seek(Percent: double);
begin
  EnterCriticalSection(FLock);
  try
    // ---> AUDIT FIX 2.7: Clamp seek position to 0.0..1.0
    FSeekPosition  := EnsureRange(Percent, 0.0, 1.0);
    FSeekRequested := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPlayThread.ForceGaplessSwap;
begin
  FForceGaplessSwap := True;
end;

procedure TPlayThread.SetDSDGain(GainDB: Integer);
var
  DeltaDB: Integer;
begin
  EnterCriticalSection(FLock);
  try
    DeltaDB := GainDB - FConfig.DsdGainDB;
    FConfig.DsdGainDB := GainDB;
    // ---> AulumicNS: the DSP applies it (the converter stays at 0 dB)
    FDsdGainLin := Power(10.0, GainDB / 20.0);

    if Assigned(FSource) then
    begin
      // Keep ReplayGain compensation in sync during live DSD gain changes
      if FCurrentIsDSD and (not FConfig.UseDoP) and (FConfig.ReplayGainMode > 0) and (DeltaDB <> 0) then
      begin
        FReplayGainDB := EnsureRange(FReplayGainDB - DeltaDB, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);
        if FReplayGainPeak > 0.0 then
          FReplayGainPeak := FReplayGainPeak * Power(10.0, DeltaDB / 20.0);
        FRGFactor := CalculateRGFactor(FReplayGainDB, FReplayGainPeak);
      end;
    end;

    if Assigned(FNextSource) then
    begin
      if FNextIsDSD and (not FConfig.UseDoP) and (FConfig.ReplayGainMode > 0) and (DeltaDB <> 0) then
      begin
        FNextReplayGainDB := EnsureRange(FNextReplayGainDB - DeltaDB, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);
        if FNextReplayGainPeak > 0.0 then
          FNextReplayGainPeak := FNextReplayGainPeak * Power(10.0, DeltaDB / 20.0);
        FNextRGFactor := CalculateRGFactor(FNextReplayGainDB, FNextReplayGainPeak);
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

// Using InterlockedExchange to pull and clear data without locking the WASAPI loop
procedure TPlayThread.GetAndClearPeaks(out L, R: double; out cL, cR: boolean);
var
  HasL, HasR: boolean;
begin
  ReadPeaks(L, R, HasL, HasR, cL, cR);
end;

// ---> ADDED: The audio thread measures one peak per WASAPI block (one block
// = the buffer size, e.g. 250 ms), while the UI reads every 50 ms. A stored 0
// means "no block measured since the last read", so the meter can keep the
// last value instead of averaging in silence (which made it pulse).
// One atomic exchange per channel: the value and the "new" flag cannot tear.
procedure TPlayThread.ReadPeaks(out L, R: double; out HasL, HasR: boolean; out cL, cR: boolean);
var
  RawL, RawR: integer;
begin
  RawL := InterlockedExchange(FVolatilePeakL, 0);
  RawR := InterlockedExchange(FVolatilePeakR, 0);
  HasL := RawL > 0;
  HasR := RawR > 0;
  L    := Max(RawL - 1, 0) / 1000000.0;
  R    := Max(RawR - 1, 0) / 1000000.0;
  cL   := InterlockedExchange(FVolatileClipL, 0) = 1;
  cR   := InterlockedExchange(FVolatileClipR, 0) = 1;
end;

// ---> ADDED: UI thread. Copies the slices written since the previous call.
// Only slices well inside the ring are copied (a margin of 64 slices, more than
// the 50 of the largest 1000 ms block), so the audio thread never overwrites a
// slice while it is being copied.
// The counters may wrap (after about 497 days of playback in one thread):
// overflow / range checks are off here, so the differences and the ring
// index stay correct in the Debug build as well (2^32 is a multiple of the
// ring size).
{$PUSH}{$Q-}{$R-}
procedure TPlayThread.ReadMeterSlices(var Dest: array of TMeterSlice; out Count: Integer);
const
  RING_SAFE = METER_RING_SIZE - 64;
var
  W, Avail, First, I: LongInt;  // ---> CHANGED (ObjFPC switch): First (Start is TThread.Start)
begin
  Count := 0;
  W     := InterlockedCompareExchange(FMeterWriteCount, 0, 0);  // atomic read
  Avail := W - FMeterReadCount;
  if Avail <= 0 then
  begin
    FMeterReadCount := W;
    Exit;
  end;

  if Avail > RING_SAFE then
    Avail := RING_SAFE;
  if Avail > Length(Dest) then
    Avail := Length(Dest);

  First := W - Avail;
  for I := 0 to Avail - 1 do
    Dest[I] := FMeterRing[(First + I) and (METER_RING_SIZE - 1)];

  FMeterReadCount := W;
  Count           := Avail;
end;
{$POP}

function TPlayThread.SetNextFile(const NextFileName: string): Boolean;
var
  OldSource : TAudioSource;
  Params    : TNextPrepareParams;
  Prep      : TPreparedNext;
begin
  Result    := True;
  OldSource := nil;

  // Safely wipe the waiting room if the UI sends a blank string
  if Trim(NextFileName) = '' then
  begin
    // ---> AUDIT FIX 3.3: Detach pointer inside FLock and free outside FLock
    // so the real-time WASAPI thread never blocks behind file-handle teardown!
    EnterCriticalSection(FLock);
    try
      OldSource   := FNextSource;
      FNextSource := nil;
    finally
      LeaveCriticalSection(FLock);
    end;
    FreeAndNil(OldSource);
    Exit;
  end;

  // ---> CHANGED: The same steps the I/O worker runs (PrepareNextSource), here
  // on the calling thread. TPlaybackManager now normally hands over a source
  // the worker has built (SetPreparedNext) and only falls back to this.
  GetPrepareParams(Params);
  if not PrepareNextSource(Params, NextFileName, Prep) then
  begin
    LogEvent(ord(alGaplessLoadFailed), 0);
    Exit;
  end;

  Result := SetPreparedNext(Prep);
end;

procedure TPlayThread.GetPrepareParams(out AParams: TNextPrepareParams);
begin
  AParams := Default(TNextPrepareParams);

  EnterCriticalSection(FLock);
  try
    AParams.Config    := FConfig;
    AParams.DsdGainDB := FConfig.DsdGainDB;
  finally
    LeaveCriticalSection(FLock);
  end;

  AParams.NegotiatedBits := InterlockedCompareExchange(FNegotiatedBits, 0, 0);
  AParams.FloatDSP       := @ApplyResamplerFloatDSP;
end;

function TPlayThread.SetPreparedNext(var APrep: TPreparedNext): Boolean;
var
  NewSource : TAudioSource;
  OldSource : TAudioSource;
  Wrapped   : TAudioSource;
  Bits      : integer;
  DeltaDB   : Integer;
begin
  Result       := True;
  NewSource    := APrep.Source;
  APrep.Source := nil;   // owned here from now on
  if NewSource = nil then
    Exit;

  // ---> AUDIT FIX 3.3: Match the negotiated WASAPI bit depth here, outside
  // FLock. It may have become known (or changed) after the source was built.
  Bits := InterlockedCompareExchange(FNegotiatedBits, 0, 0);
  if Bits > 0 then
  begin
    try
      NewSource.SetTargetBitDepth(Bits);
    except
      NewSource.Free;
      LogEvent(ord(alGaplessLoadFailed), 0);
      Exit;
    end;

    if NewSource.GetBitsPerSample <> Bits then
    begin
      try
        Wrapped := TBitDepthConverterSource.Create(NewSource, Bits);
      except
        // The converter takes ownership on entry; if its constructor raises,
        // its destructor has already freed NewSource. Do not free it again.
        LogEvent(ord(alGaplessLoadFailed), 0);
        Exit;
      end;
      NewSource := Wrapped;
    end;
  end;

  // ---> AUDIT FIX 3.3: Swap FNextSource under FLock and free OldSource outside FLock
  EnterCriticalSection(FLock);
  try
    if FTrackSwapped then
    begin
      // ---> AUDIT FIX: The render thread swapped to the previously queued track
      // after the caller last checked. This "next" was chosen relative to the old
      // current track, so reject it; the caller consumes the swap and retries.
      OldSource := NewSource;
      Result    := False;
    end
    else
    begin
      // ---> ADDED: The DSD gain changed after the source was built: the
      // ReplayGain compensation as SetDSDGain does for a queued FNextSource
      // (---> AulumicNS: the gain itself is the DSP's, FDsdGainLin)
      DeltaDB := FConfig.DsdGainDB - APrep.DsdGainDB;
      if DeltaDB <> 0 then
      begin
        if APrep.IsDSD and (not FConfig.UseDoP) and (FConfig.ReplayGainMode > 0) then
        begin
          APrep.GainDB := EnsureRange(APrep.GainDB - DeltaDB, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB);
          if APrep.Peak > 0.0 then
            APrep.Peak := APrep.Peak * Power(10.0, DeltaDB / 20.0);
          APrep.RGFactor := CalculateRGFactor(APrep.GainDB, APrep.Peak);
        end;
      end;

      OldSource           := FNextSource;
      FNextSource         := NewSource;
      FNextIsDSD          := APrep.IsDSD;
      FNextInputRate      := APrep.InRate;
      FNextOutputRate     := APrep.OutRate;
      FNextReplayGainDB   := APrep.GainDB;
      FNextReplayGainPeak := APrep.Peak;
      FNextRGFactor       := APrep.RGFactor;
      FNextHeadKey        := APrep.HeadKey;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;

  FreeAndNil(OldSource);
end;

// Atomic Compare & Swap ensures we always keep the highest peak safely
procedure TPlayThread.UpdatePeakAtomic(var Target: integer; NewValue: integer);
var
  CurrentVal: integer;
begin
  repeat
    CurrentVal := Target;
    if NewValue <= CurrentVal then
      Break;
  until InterlockedCompareExchange(Target, NewValue, CurrentVal) = CurrentVal;
end;

// ---> AUDIT FIX 3.2: Synchronize error state reads and writes under FLock
function TPlayThread.GetHasError: boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := (FErrorType <> aeNone);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPlayThread.GetErrorMessageSafe: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPlayThread.GetErrorTypeSafe: TAudioErrorType;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorType;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPlayThread.GetFailedSampleRateSafe: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FFailedSampleRate;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPlayThread.GetErrorDetailSafe: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorDetail;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPlayThread.FillDsdSilence(Buffer: Pointer; ByteCount, BitDepth: integer; var ADoPMarker: byte);
var
  P: pbyte;
  I, Stride: integer;
begin
  P := pbyte(Buffer);
  if BitDepth = 32 then
    Stride := 8
  else
    Stride := 6;

  for I := 0 to (ByteCount div Stride) - 1 do
  begin
    if BitDepth = 32 then
    begin
      P[0] := $00; P[1] := $69; P[2] := $69; P[3] := ADoPMarker;
      P[4] := $00; P[5] := $69; P[6] := $69; P[7] := ADoPMarker;
    end
    else
    begin
      P[0] := $69; P[1] := $69; P[2] := ADoPMarker;
      P[3] := $69; P[4] := $69; P[5] := ADoPMarker;
    end;
    Inc(P, Stride);

    // Toggle the marker state
    if ADoPMarker = $05 then
      ADoPMarker := $FA
    else
      ADoPMarker := $05;
  end;

  if (ByteCount mod Stride) > 0 then
    FillChar(P^, ByteCount mod Stride, 0);
end;

// ---> ADDED (output split, step 1): The rest of a buffer the source did not
// fill: DoP silence (continuing the marker sequence) or digital zeros
procedure TPlayThread.FillTail(PTail: PByte; ACount: Integer; AIsDoP: Boolean);
var
  MarkerState: Byte;
begin
  if ACount <= 0 then
    Exit;
  if AIsDoP then
  begin
    MarkerState := FSource.GetDoPMarker;
    FillDsdSilence(PTail, ACount, FSource.GetBitsPerSample, MarkerState);
    FSource.SetDoPMarker(MarkerState);
  end
  else
    FillChar(PTail^, ACount, 0);
end;

// ---> ADDED (output split, step 1): ABytes more were handed to the device.
// Resampled output counts frames (the source's position is the input side);
// otherwise the progress is the source's. AUpdateProgress = False: only the
// frame count (after a seek the progress is the seek target).
procedure TPlayThread.CountOutputFrames(ABytes, ABlockAlign: Integer; AUpdateProgress: Boolean);
begin
  if FConfig.ResamplePCM and (ABlockAlign > 0) then
  begin
    FOutputFramesWritten := FOutputFramesWritten + (ABytes div ABlockAlign);
    // ---> AUDIT FIX 2.7: Clamp FProgressCache to 0.0..1.0
    if AUpdateProgress then
      FProgressCache := EnsureRange(FOutputFramesWritten / FTotalFrames, 0.0, 1.0);
  end
  else if AUpdateProgress then
    FProgressCache := EnsureRange(FSource.GetProgress, 0.0, 1.0);
end;

// ---> ADDED (output split, step 1): Fills one device buffer from the current
// source: read, the rest as silence, count the frames, DSP. Returns the bytes
// the source delivered. Used for the first buffer and the buffer after a
// seek; the normal loop also switches tracks between read and DSP.
function TPlayThread.FillBlock(PData: PByte; ABytes, ABlockAlign: Integer;
  AUpdateProgress: Boolean): Integer;
begin
  Result := FSource.ReadData(PData, ABytes);
  if Result < ABytes then
    FillTail(PData + Result, ABytes - Result, FSource.IsDoP);
  CountOutputFrames(Result, ABlockAlign, AUpdateProgress);
  ApplyDSP(PData, Result);
end;

// ---> ADDED: see the declaration. The grid step is 2^(32 - AValidBits) (256
// for 24 valid bits); the dither is the difference of two uniform values of
// one step each (two xorshift states, as NextTPDFDither in ApplyDSP).
procedure RoundSamplesToValidBits(ASamples: PLongInt; ACount, AValidBits: Integer;
  var ASeed: Cardinal);
var
  I: Integer;
  Mask, Seed, R1, R2: Cardinal;
  Half, Val64: Int64;
begin
  if (ASamples = nil) or (ACount <= 0) or (AValidBits < 16) or (AValidBits >= 32) then
    Exit;

  Mask := (Cardinal(1) shl (32 - AValidBits)) - 1;  // the bits the DAC ignores
  Half := Int64(Mask shr 1) + 1;                    // half a step: to the nearest
  Seed := ASeed;
  if Seed = 0 then
    Seed := DITHER_DEFAULT_SEED;

  for I := 0 to ACount - 1 do
  begin
    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor (Seed shl 5);
    R1   := Seed and Mask;

    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor (Seed shl 5);
    R2   := Seed and Mask;

    Val64 := Int64(ASamples^) + Half + (Int64(R1) - Int64(R2));
    if Val64 > PCM32_MAX_INT then
      Val64 := PCM32_MAX_INT
    else if Val64 < PCM32_MIN_INT then
      Val64 := PCM32_MIN_INT;

    // Clearing the ignored bits rounds down to the grid (two's complement):
    // with Half added, that is to the nearest step
    ASamples^ := LongInt(Val64 and not Int64(Mask));
    Inc(ASamples);
  end;

  ASeed := Seed;
end;

//==============================================================================
// 64-bit float DSP engine (Volume, Tone Control, Soft Clipping, 16/24-bit TPDF
// Dithering, and Peak Meter extraction)
//==============================================================================
// =============================================================================
// ---> AulumicNS: the gain, its glide and the automatic headroom (2026-11-12)
//
// The glide. A new volume (also Mute), another ReplayGain factor or DSD gain
// was applied to the next block in one step: a jump in the waveform, heard
// as a click or, while the volume slider is dragged, as "zipper" noise. Now
// the gain glides from the old value to the new one over GAIN_RAMP_MS, one
// frame at a time, through the same block routines (so the tone control, the
// soft clipper, the dither and the meter see every frame as always). The
// glide goes on in the next block when a block is shorter than it (an ASIO
// period at 352.8 kHz is 1.5 ms). With an unchanged gain the block goes
// through in one call, exactly as before: bit-perfect playback is not
// touched.
//
// The automatic headroom (FConfig.AutoHeadroom). The peak of every block is
// measured before the gain (of full scale; behind the resampler it is above
// 1 where the waveform between the samples of a loud master is rebuilt), and
// the gain never goes above HEADROOM_CEILING / the highest peak of the album
// (FHeadPeak): the gain is lowered, nothing is clipped or limited. The level
// is the same for the whole album, and the peak is remembered (ALHeadroom:
// HeadroomBook), so the album starts at that level the next time.
// A block with a new highest peak: the gain glides down before the first
// frame that would go over (FirstFrameAbove), so that frame is played at the
// new gain already. Only when there is no room for that - the over is in the
// first 10 ms of the block, or a glide is in work - the glide begins at once
// and a frame that would go over inside it is held at the ceiling (for those
// few frames that is what clipping did to every peak before; it happens once
// per new highest peak, the first time an album is played). The gain itself
// never jumps. In the integer path (no resampler) samples cannot be
// above full scale: the headroom works there only with a gain above 1 (DSD
// converted to PCM with the DSD gain, ReplayGain without a peak tag);
// playback without a gain is not looked at.
// The tone control comes before the gain, inside the block routines. While
// it is active the block is first run through it for its levels only
// (ToneLevelsOf: the filters get their memory back afterwards), and the cap
// works with the highest peak behind it (FHeadUse) - so a boost is lowered
// before it clips, like any other peak, and a cut costs no level. That peak
// belongs to the tone setting: it is not remembered and starts again from
// the album's own peak (FHeadPeak, the one the book keeps) when the tone
// control is changed. With the tone control active the headroom also works
// in the integer path at any gain.
// A block that still went over full scale (FBlockOutPeak) lowers the gain
// from the next block on (FHeadOverCap): a last line of defence.
// =============================================================================
const
  GAIN_RAMP_MS = 10;
  HEAD_NO_CAP  = 1.0e30;

// One sample as a part of full scale (0 .. 1; a float sample may be above)
function SampleLevel(AKind: TGainKind; P: Pointer; AIndex, ABits: Integer): Double; inline;
var
  B: PByte;
  V: Integer;
begin
  if AKind = gkFloat then
    Result := Abs(PDouble(P)[AIndex])
  else if ABits = 16 then
    Result := Abs(Integer(PSmallInt(P)[AIndex])) * (1.0 / PCM16_MAX_FLT)
  else if ABits = 32 then
    Result := Abs(Int64(PInteger(P)[AIndex])) * (1.0 / PCM32_MAX_FLT)
  else
  begin
    B := PByte(P) + AIndex * 3;
    V := (B[0]) or (B[1] shl 8) or (B[2] shl 16);
    if (V and $800000) <> 0 then
      V := V or Integer($FF000000);
    Result := Abs(V) * (1.0 / PCM24_MAX_FLT);
  end;
end;

// The highest of ASamples samples
function BlockLevel(AKind: TGainKind; P: Pointer; ASamples, ABits: Integer): Double;
var
  I: Integer;
  A: Double;
  D: PDouble;
begin
  Result := 0.0;
  if AKind = gkFloat then
  begin
    D := PDouble(P);
    for I := 0 to ASamples - 1 do
    begin
      A := Abs(D^);
      if A > Result then
        Result := A;
      Inc(D);
    end;
  end
  else
    for I := 0 to ASamples - 1 do
    begin
      A := SampleLevel(AKind, P, I, ABits);
      if A > Result then
        Result := A;
    end;
end;

// The first frame with a sample above ALimit; -1 = none
function FirstFrameAbove(AKind: TGainKind; P: Pointer; AFrames, AChannels, ABits: Integer;
  ALimit: Double): Integer;
var
  I: Integer;
begin
  for I := 0 to AFrames * AChannels - 1 do
    if SampleLevel(AKind, P, I, ABits) > ALimit then
      Exit(I div AChannels);
  Result := -1;
end;

// Volume (squared), ReplayGain with the preamp (FRGFactor) and, for DSD
// converted to PCM, the DSD gain: the factor the samples are multiplied with
// (before the headroom)
function TPlayThread.TargetGain: Double;
var
  LocalVol: Integer;
begin
  if FConfig.DisableVolume then
    Result := 1.0
  else
  begin
    LocalVol := FVolumeInt;
    if LocalVol <= 0 then
      Result := 0.0
    else if LocalVol >= 1000 then
      Result := 1.0
    else
      Result := Sqr(LocalVol * 0.001);

    Result := Result * FRGFactor;
  end;
  if FCurrentIsDSD then
    Result := Result * FDsdGainLin;
end;

// The track in work belongs to this album and chain (CalcHeadroomKey): its
// peak so far from the book. Play thread only.
procedure TPlayThread.HeadroomForTrack(const AKey: string);
begin
  if AKey = FHeadKey then
    Exit;                     // the same album: its peak goes on
  FHeadKey     := AKey;
  FHeadPeak    := 0.0;
  FHeadOverCap := HEAD_NO_CAP;
  if (AKey <> '') and Assigned(HeadroomBook) then
    FHeadPeak := HeadroomBook.Known(AKey);
  FHeadUse := FHeadPeak;
end;

// The tone settings the UI has set since the last block (as the block
// routines do at their start; they find nothing left to do after this)
procedure TPlayThread.SyncToneSettings;
var
  LocalTone: TToneState;
begin
  if not (Assigned(FToneControl) and FToneDirty) then
    Exit;
  EnterCriticalSection(FLock);
  try
    LocalTone  := FToneState;
    FToneDirty := False;
  finally
    LeaveCriticalSection(FLock);
  end;
  FToneControl.SetDirectMode(LocalTone.DirectMode);
  FToneControl.SetBandFrequencies(ToneFreqsOf(LocalTone));
  FToneControl.SetBandGains(ToneGainsOf(LocalTone));
end;

// The block as it comes out of the tone control, before the gain: the level
// of every frame (the higher channel, of full scale) into FToneLevels, the
// highest as the result. The samples go through the filters exactly as the
// block routines send them (the same values in the same order), and then the
// filters get their memory back: the block itself is not touched and is
// played afterwards as if nobody had looked. A glide of the tone control to
// a new setting is walked along as RunGain's Call walks it (the same steps
// at the same frames), and put back too.
function TPlayThread.ToneLevelsOf(AKind: TGainKind; ABuffer: Pointer;
  AFrames, AChannels, ABits: Integer): Double;
var
  Saved: TToneSnapshot;
  Scale, InvScale, A, B: Double;
  I, C, First, Stop: Integer;
  Glide, ToneOn: Boolean;

  // sample AIndex as the block routine hands it to the tone control
  function Value(AIndex: Integer; AScale: Double): Double; inline;
  var
    P: PByte;
    V: Integer;
  begin
    if AKind = gkFloat then
      Result := PDouble(ABuffer)[AIndex] * AScale
    else if ABits = 16 then
      Result := PSmallInt(ABuffer)[AIndex]
    else if ABits = 32 then
      Result := PInteger(ABuffer)[AIndex]
    else
    begin
      P := PByte(ABuffer) + AIndex * 3;
      V := (P[0]) or (P[1] shl 8) or (P[2] shl 16);
      if (V and $800000) <> 0 then
        V := V or Integer($FF000000);
      Result := V;
    end;
  end;

begin
  Result := 0.0;
  if Length(FToneLevels) < AFrames then
    SetLength(FToneLevels, AFrames);
  if ABits = 16 then
    Scale := PCM16_MAX_FLT
  else if ABits = 24 then
    Scale := PCM24_MAX_FLT
  else
    Scale := PCM32_MAX_FLT;
  InvScale := 1.0 / Scale;

  FToneControl.SaveState(Saved);
  First := 0;
  while First < AFrames do
  begin
    // the frames First .. Stop - 1 meet one set of coefficients
    Glide  := FToneControl.Gliding;
    ToneOn := FToneControl.IsActive;
    Stop   := AFrames;
    if Glide and (FToneControl.GlideChunk < Stop - First) then
      Stop := First + FToneControl.GlideChunk;

    if ToneOn and (AChannels = 2) then
      for I := First to Stop - 1 do
      begin
        A := Abs(FToneControl.ProcessSampleL(Value(I * 2, Scale)));
        B := Abs(FToneControl.ProcessSampleR(Value(I * 2 + 1, Scale)));
        if B > A then
          A := B;
        A := A * InvScale;
        FToneLevels[I] := A;
        if A > Result then
          Result := A;
      end
    else
      // (as the block routines: only the first channel has the tone control;
      // and no channel has it once a glide to "off" has arrived)
      for I := First to Stop - 1 do
      begin
        A := Value(I * AChannels, Scale);
        if ToneOn then
          A := FToneControl.ProcessSampleL(A);
        A := Abs(A);
        for C := 1 to AChannels - 1 do
        begin
          B := Abs(Value(I * AChannels + C, Scale));
          if B > A then
            A := B;
        end;
        A := A * InvScale;
        FToneLevels[I] := A;
        if A > Result then
          Result := A;
      end;

    if Glide then
      FToneControl.Advance(Stop - First);
    First := Stop;
  end;
  FToneControl.RestoreState(Saved);
end;

// AFrames frames of the block in work through the block routine of AKind,
// with the gain, its glide and the headroom (see above)
procedure TPlayThread.RunGain(AKind: TGainKind; ABuffer: Pointer;
  AFrames, AChannels, ABits, ARate: Integer; out AClipped: Boolean);
var
  Target, Eff, Bound, Pk, Lv, GMax: Double;
  FrameBytes, K, S, L, N, J: Integer;
  Head, ToneOn, ToneChanged: Boolean;

  // ACount frames from AFirst on with the gain FGainNow. While the tone
  // control glides to a new setting they go in the glide's steps: after each
  // the tone control sets its next coefficients (TToneControl.Advance).
  procedure Call(AFirst, ACount: Integer);
  var
    C, Glide: Boolean;
    Cnt: Integer;
  begin
    if ACount <= 0 then
      Exit;
    if FGainNow > GMax then
      GMax := FGainNow;
    while ACount > 0 do
    begin
      Cnt   := ACount;
      Glide := Assigned(FToneControl) and FToneControl.Gliding;
      if Glide and (FToneControl.GlideChunk < Cnt) then
        Cnt := FToneControl.GlideChunk;
      if AKind = gkFloat then
      begin
        ApplyFloatDSPBlock(PDouble(ABuffer) + AFirst * AChannels, Cnt, AChannels, ABits, C);
        AClipped := AClipped or C;
      end
      else
        ApplyDSPBlock(PByte(ABuffer) + AFirst * FrameBytes, Cnt * FrameBytes);
      if Glide then
        FToneControl.Advance(Cnt);
      Inc(AFirst, Cnt);
      Dec(ACount, Cnt);
    end;
  end;

  // The frames AFrom .. ATo - 1: along the glide in work, then at its end
  procedure Run(AFrom, ATo: Integer);
  var
    I: Integer;
    G, A: Double;
  begin
    I := AFrom;
    while (I < ATo) and (FRampPos < FRampLen) do
    begin
      Inc(FRampPos);
      G        := FRampFrom + (FRampTo - FRampFrom) * (FRampPos / FRampLen);
      FGainCur := G;
      if Head then
      begin
        // an over inside a glide: this frame as loud as it can be
        if ToneOn then
          A := FToneLevels[I]
        else if AKind = gkFloat then
          A := BlockLevel(AKind, PDouble(ABuffer) + I * AChannels, AChannels, ABits)
        else
          A := BlockLevel(AKind, PByte(ABuffer) + I * FrameBytes, AChannels, ABits);
        if G * A > HEADROOM_CEILING then
          G := HEADROOM_CEILING / A;
      end;
      FGainNow := G;
      Call(I, 1);
      Inc(I);
    end;
    if I < ATo then
    begin
      FGainCur := FRampTo;
      FGainNow := FRampTo;
      Call(I, ATo - I);
    end;
  end;

begin
  AClipped   := False;
  FrameBytes := AChannels * (ABits div 8);
  Target     := TargetGain;
  // The tone control (it works before the gain, inside the block routines):
  // its settings now, so the block can be looked at behind it. A new
  // setting: what it adds is learned again, from the album's own peak.
  // (The settings are taken here in every case, not by the block routines:
  // a glide to them has to start at a block's first frame.)
  // While the tone control glides to a setting, and in the block after, what
  // it adds is learned anew as well: the levels met on the way are not those
  // of the setting it arrives at.
  ToneOn      := False;
  ToneChanged := FToneDirty or FToneGlided;
  SyncToneSettings;
  FToneGlided := Assigned(FToneControl) and FToneControl.Gliding;
  if FConfig.AutoHeadroom then
  begin
    ToneOn := Assigned(FToneControl) and FToneControl.IsActive;
    if ToneChanged then
    begin
      FHeadOverCap := HEAD_NO_CAP;
      FHeadUse     := FHeadPeak;
    end;
  end;
  // integer samples are never above full scale: only a gain above 1 or a
  // boost of the tone control can take them there
  Head := FConfig.AutoHeadroom and ((AKind = gkFloat) or (Target > 1.0 + 1e-9) or ToneOn);

  Eff := Target;
  if Head then
  begin
    if (FHeadUse > 0.0) and (Eff * FHeadUse > HEADROOM_CEILING) then
      Eff := HEADROOM_CEILING / FHeadUse;
    if Eff > FHeadOverCap then
      Eff := FHeadOverCap;
  end;

  // The first block of a stream starts at its gain: nothing to glide from
  if FGainCur < 0.0 then
  begin
    FGainCur  := Eff;
    FRampFrom := Eff;
    FRampTo   := Eff;
    FRampLen  := 0;
    FRampPos  := 0;
  end;

  // A new highest peak of the album in this block?
  K := -1;
  if Head then
  begin
    Pk := BlockLevel(AKind, ABuffer, AFrames * AChannels, ABits);
    if Pk > HEADROOM_MAX_PEAK then
      Pk := HEADROOM_MAX_PEAK;
    // the album's own peak (before the tone control) is what is remembered
    if Pk > FHeadPeak then
    begin
      FHeadPeak := Pk;
      if (FHeadKey <> '') and Assigned(HeadroomBook) then
        HeadroomBook.Learn(FHeadKey, Pk);
    end;
    // what the gain meets: the block behind the tone control when that is
    // active (a boost raises the peaks, a cut lowers them)
    if ToneOn then
    begin
      Lv := ToneLevelsOf(AKind, ABuffer, AFrames, AChannels, ABits);
      if Lv > HEADROOM_MAX_PEAK then
        Lv := HEADROOM_MAX_PEAK;
    end
    else
      Lv := Pk;
    if Lv > FHeadUse then
    begin
      // the highest gain the block would get as things were: where does
      // that go over?
      Bound := FGainCur;
      if FRampTo > Bound then
        Bound := FRampTo;
      if Bound * Lv > HEADROOM_CEILING then
      begin
        if ToneOn then
        begin
          for J := 0 to AFrames - 1 do
            if FToneLevels[J] * Bound > HEADROOM_CEILING then
            begin
              K := J;
              Break;
            end;
        end
        else
          K := FirstFrameAbove(AKind, ABuffer, AFrames, AChannels, ABits, HEADROOM_CEILING / Bound);
      end;
      FHeadUse := Lv;
      if Eff * FHeadUse > HEADROOM_CEILING then
        Eff := HEADROOM_CEILING / FHeadUse;
    end;
  end;

  // A new gain: the glide to it, always of the full length (a shorter one
  // would be a step). Before an over it ends at that frame when the block
  // has the room; else it begins here, and a frame that would go over
  // inside it is held at the ceiling (Run).
  N := (Int64(ARate) * GAIN_RAMP_MS) div 1000;
  if N < 1 then
    N := 1;
  S := -1;
  L := 0;
  if Abs(Eff - FRampTo) >= 1e-9 then
  begin
    L := N;
    if K >= N then
      S := K - N
    else
      S := 0;
  end;

  GMax          := 0.0;
  FBlockOutPeak := 0.0;
  if S < 0 then
    Run(0, AFrames)
  else
  begin
    Run(0, S);
    FRampFrom := FGainCur;
    FRampTo   := Eff;
    FRampLen  := L;
    FRampPos  := 0;
    Run(S, AFrames);
  end;

  if Head then
  begin
    // Still over full scale (nothing known does that: a last line of
    // defence): the gain that would have kept it below, from the next block on
    if (FBlockOutPeak > 1.0) and (GMax > 0.0) and
       (GMax * HEADROOM_CEILING / FBlockOutPeak < FHeadOverCap) then
      FHeadOverCap := GMax * HEADROOM_CEILING / FBlockOutPeak;

    // for the signal path: what the headroom takes off now (1/1000 dB)
    if (Target > 0.0) and (Eff < Target * (1.0 - 1e-6)) then
      InterlockedExchange(FVolatileHeadroom, Round(-20000.0 * Log10(Eff / Target)))
    else
      InterlockedExchange(FVolatileHeadroom, 0);
  end
  else
    InterlockedExchange(FVolatileHeadroom, 0);

  // samples went through the tone control: its next setting glides
  if Assigned(FToneControl) then
    FToneControl.MarkPlayed;
end;

procedure TPlayThread.ApplyDSP(Buffer: Pointer; BytesRead: integer);
var
  FrameBytes, Bits: Integer;
  Clipped: Boolean;
begin
  if (BytesRead <= 0) or (FSource = nil) then
    Exit;

  // DoP passes untouched, and behind the resampler the gain was applied
  // already (ApplyResamplerFloatDSP): no gain here, nothing to glide
  if FSource.IsDoP or (FSource.FindLayer(TResamplerSource) <> nil) then
  begin
    ApplyDSPBlock(Buffer, BytesRead);
    Exit;
  end;

  Bits       := FSource.GetBitsPerSample;
  FrameBytes := FSource.GetChannels * (Bits div 8);
  if ((Bits <> 16) and (Bits <> 24) and (Bits <> 32)) or (FrameBytes <= 0) or
     (BytesRead mod FrameBytes <> 0) then
  begin
    // nothing the glide can count in frames: the block as it is (and the
    // tone control at its settings, without a glide)
    FGainNow := TargetGain;
    SyncToneSettings;
    if Assigned(FToneControl) then
      FToneControl.FinishGlide;
    ApplyDSPBlock(Buffer, BytesRead);
    Exit;
  end;

  RunGain(gkInt, Buffer, BytesRead div FrameBytes, FSource.GetChannels, Bits,
    FSource.GetSampleRate, Clipped);
end;

procedure TPlayThread.ApplyResamplerFloatDSP(Buffer: PDouble; FrameCount, Channels, OutBits: Integer;
  out OutClipped: Boolean);
begin
  OutClipped := False;
  if (FrameCount <= 0) or (Channels <= 0) or (Buffer = nil) then
    Exit;

  RunGain(gkFloat, Buffer, FrameCount, Channels, OutBits, FOutputSampleRate, OutClipped);
end;

procedure TPlayThread.ApplyDSPBlock(Buffer: Pointer; BytesRead: integer);
const
  TPDF_DITHER_SCALE = 1.0 / 2147483648.0;
  DEFAULT_PRNG_SEED = $A341316C;

  function NextTPDFDither(var Seed: Cardinal): Double; inline;
  var
    R1, R2: Cardinal;
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

var
  P16: PSmallInt;
  P24: PByte;
  P32: PInteger;
  I, FrameCount, SampleCount, Bits, V32, Channels, ChanIdx: integer;
  VolFactor: double;

  CalcValDbl: double;
  TempPeakL, TempPeakR: double;
  MaxPeakIntL, MaxPeakIntR, AbsInt: int64;

  IsSoftClip: boolean;
  AbsVal: double;
  Diff: double;
  FinalSample: int64;

  IsDSPActive: Boolean;
  IsBitPerfectBypass: Boolean;
  Untouched: Boolean;  // ---> ADDED: the buffer reaches the DAC unchanged
  ClippedL, ClippedR: Boolean;
  LocalTone: TToneState;
  LocalSeed: Cardinal;
  ConvLayer: TAudioSource;
  SrcBits, ValidBits: integer;
begin
  if (BytesRead <= 0) or (FSource = nil) then
    Exit;

  // ---> MODIFIED: DoP is bit-perfect (the DSD bits pass unchanged); the
  // check is split only to set the flag, DoP itself is untouched
  if FSource.IsDoP then
  begin
    InterlockedExchange(FBitPerfect, 1);
    Exit; // DoP strictly bypassed
  end;

  // If TResamplerSource is in the chain, 64-bit float DSP,
  // peak metering, and single-pass TPDF dithering have already been applied
  // inside TResamplerSource.ReadData via ApplyResamplerFloatDSP!
  if FSource.FindLayer(TResamplerSource) <> nil then
  begin
    InterlockedExchange(FBitPerfect, 0);  // ---> ADDED: resampled
    // ---> ADDED: Fewer valid bits than the 32-bit container (24 in 32):
    // rounded to them with dither (the resampler rounds only to 32 bits)
    if FSource.GetBitsPerSample = 32 then
      RoundSamplesToValidBits(PLongInt(Buffer), BytesRead div 4,
        InterlockedCompareExchange(FNegotiatedValid, 0, 0), FDitherSeed);
    // ---> ADDED: The buffer is final here as well: measure the meter slices
    ScanMeterSlices(Buffer, BytesRead);
    Exit;
  end;

  // Only sync UI Tone state when FToneDirty is True
  if Assigned(FToneControl) and FToneDirty then
  begin
    EnterCriticalSection(FLock);
    try
      LocalTone  := FToneState;
      FToneDirty := False;
    finally
      LeaveCriticalSection(FLock);
    end;

    FToneControl.SetDirectMode(LocalTone.DirectMode);
    FToneControl.SetBandFrequencies(ToneFreqsOf(LocalTone));
    FToneControl.SetBandGains(ToneGainsOf(LocalTone));
  end;

  IsDSPActive := Assigned(FToneControl) and FToneControl.IsActive;

  TempPeakL := 0.0;
  TempPeakR := 0.0;
  ClippedL  := False;
  ClippedR  := False;
  Channels  := FSource.GetChannels;
  Bits      := FSource.GetBitsPerSample;

  if (Bits < 8) or (Channels < 1) then
    Exit;

  // Lock-free Volume + Pre-calculated FRGFactor (No Power() calls!)
  // ---> AulumicNS: the gain of this block from the caller (TargetGain, or a
  // step of the glide to it)
  VolFactor  := FGainNow;
  IsSoftClip := (not FConfig.DisableVolume) and FConfig.EnableSoftClipping;
  // (the DSD gain of DSD converted to PCM is part of it: applied here, with
  // the volume and the preamp, so it clips only at the end)

  SampleCount := BytesRead div (Bits div 8);
  FrameCount  := SampleCount div 2;

  // =========================================================================
  // Bit-Perfect Read-Only Fast Path (Pure Integer Peak Scan)
  // =========================================================================
  IsBitPerfectBypass := (not IsDSPActive) and (not IsSoftClip) and (Abs(VolFactor - 1.0) < 1e-9);

  // ---> ADDED: Bit-perfect = the untouched path, no DSD-to-PCM, and no bits
  // lost to the output format (padding to a wider container is lossless)
  SrcBits   := Bits;
  ConvLayer := FSource.FindLayer(TBitDepthConverterSource);
  if Assigned(ConvLayer) then
    SrcBits := TBitDepthConverterSource(ConvLayer).GetSourceBitsPerSample;
  ValidBits := InterlockedCompareExchange(FNegotiatedValid, 0, 0);
  if (ValidBits <= 0) or (ValidBits > Bits) then
    ValidBits := Bits;
  // ---> CHANGED: kept in Untouched for the rounding to the valid bits below
  Untouched := IsBitPerfectBypass and (not FCurrentIsDSD) and (SrcBits <= ValidBits);
  if Untouched then
    InterlockedExchange(FBitPerfect, 1)
  else
    InterlockedExchange(FBitPerfect, 0);

  if IsBitPerfectBypass and (Channels = 2) then
  begin
    MaxPeakIntL := 0;
    MaxPeakIntR := 0;

    if Bits = 16 then
    begin
      P16 := PSmallInt(Buffer);
      for I := 0 to FrameCount - 1 do
      begin
        AbsInt := Abs(Integer(P16^));
        if AbsInt > MaxPeakIntL then
          MaxPeakIntL := AbsInt;
        Inc(P16);

        AbsInt := Abs(Integer(P16^));
        if AbsInt > MaxPeakIntR then
          MaxPeakIntR := AbsInt;
        Inc(P16);
      end;
    end
    else if Bits = 32 then
    begin
      P32 := PInteger(Buffer);
      for I := 0 to FrameCount - 1 do
      begin
        AbsInt := Abs(Int64(P32^));
        if AbsInt > MaxPeakIntL then
          MaxPeakIntL := AbsInt;
        Inc(P32);

        AbsInt := Abs(Int64(P32^));
        if AbsInt > MaxPeakIntR then
          MaxPeakIntR := AbsInt;
        Inc(P32);
      end;
    end
    else if Bits = 24 then
    begin
      P24 := PByte(Buffer);
      for I := 0 to FrameCount - 1 do
      begin
        V32 := (P24[0]) or (P24[1] shl 8) or (P24[2] shl 16);
        if (V32 and $800000) <> 0 then
          V32 := V32 or integer($FF000000);
        AbsInt := Abs(V32);
        if AbsInt > MaxPeakIntL then
          MaxPeakIntL := AbsInt;
        Inc(P24, 3);

        V32 := (P24[0]) or (P24[1] shl 8) or (P24[2] shl 16);
        if (V32 and $800000) <> 0 then
          V32 := V32 or integer($FF000000);
        AbsInt := Abs(V32);
        if AbsInt > MaxPeakIntR then
          MaxPeakIntR := AbsInt;
        Inc(P24, 3);
      end;
    end;

    TempPeakL := MaxPeakIntL;
    TempPeakR := MaxPeakIntR;
  end
  // =========================================================================
  // Unrolled Stereo 64-bit Float DSP Processing (Channels = 2)
  // =========================================================================
  else if Channels = 2 then
  begin
    if Bits = 16 then
    begin
      LocalSeed := FDitherSeed;
      if LocalSeed = 0 then
        LocalSeed := DEFAULT_PRNG_SEED;

      P16 := PSmallInt(Buffer);
      for I := 0 to FrameCount - 1 do
      begin
        // --- LEFT CHANNEL ---
        CalcValDbl := P16^;
        if IsDSPActive then
          CalcValDbl := FToneControl.ProcessSampleL(CalcValDbl);
        CalcValDbl := CalcValDbl * VolFactor;
        AbsVal     := Abs(CalcValDbl);

        if IsSoftClip and (AbsVal > PCM16_CLIP_TH) then
        begin
          Diff   := AbsVal - PCM16_CLIP_TH;
          AbsVal := PCM16_CLIP_TH + PCM16_CLIP_HR * (Diff / (PCM16_CLIP_HR + Diff));
          if CalcValDbl < 0.0 then
            CalcValDbl := -AbsVal
          else
            CalcValDbl := AbsVal;
        end;

        if AbsVal > TempPeakL then
          TempPeakL := AbsVal;

        FinalSample := Round(CalcValDbl + NextTPDFDither(LocalSeed));
        if FinalSample > PCM16_MAX_INT then
        begin
          P16^     := PCM16_MAX_INT;
          ClippedL := True;
        end
        else if FinalSample < PCM16_MIN_INT then
        begin
          P16^     := PCM16_MIN_INT;
          ClippedL := True;
        end
        else
          P16^ := FinalSample;
        Inc(P16);

        // --- RIGHT CHANNEL ---
        CalcValDbl := P16^;
        if IsDSPActive then
          CalcValDbl := FToneControl.ProcessSampleR(CalcValDbl);
        CalcValDbl := CalcValDbl * VolFactor;
        AbsVal     := Abs(CalcValDbl);

        if IsSoftClip and (AbsVal > PCM16_CLIP_TH) then
        begin
          Diff   := AbsVal - PCM16_CLIP_TH;
          AbsVal := PCM16_CLIP_TH + PCM16_CLIP_HR * (Diff / (PCM16_CLIP_HR + Diff));
          if CalcValDbl < 0.0 then
            CalcValDbl := -AbsVal
          else
            CalcValDbl := AbsVal;
        end;

        if AbsVal > TempPeakR then
          TempPeakR := AbsVal;

        FinalSample := Round(CalcValDbl + NextTPDFDither(LocalSeed));
        if FinalSample > PCM16_MAX_INT then
        begin
          P16^     := PCM16_MAX_INT;
          ClippedR := True;
        end
        else if FinalSample < PCM16_MIN_INT then
        begin
          P16^     := PCM16_MIN_INT;
          ClippedR := True;
        end
        else
          P16^ := FinalSample;
        Inc(P16);
      end;

      FDitherSeed := LocalSeed;
    end
    else if Bits = 32 then
    begin
      P32 := PInteger(Buffer);
      for I := 0 to FrameCount - 1 do
      begin
        // --- LEFT CHANNEL ---
        CalcValDbl := P32^;
        if IsDSPActive then
          CalcValDbl := FToneControl.ProcessSampleL(CalcValDbl);
        CalcValDbl := CalcValDbl * VolFactor;
        AbsVal     := Abs(CalcValDbl);

        if IsSoftClip and (AbsVal > PCM32_CLIP_TH) then
        begin
          Diff   := AbsVal - PCM32_CLIP_TH;
          AbsVal := PCM32_CLIP_TH + PCM32_CLIP_HR * (Diff / (PCM32_CLIP_HR + Diff));
          if CalcValDbl < 0.0 then
            CalcValDbl := -AbsVal
          else
            CalcValDbl := AbsVal;
        end;

        if AbsVal > TempPeakL then
          TempPeakL := AbsVal;

        FinalSample := Round(CalcValDbl);
        if FinalSample > PCM32_MAX_INT then
        begin
          P32^     := PCM32_MAX_INT;
          ClippedL := True;
        end
        else if FinalSample < PCM32_MIN_INT then
        begin
          P32^     := PCM32_MIN_INT;
          ClippedL := True;
        end
        else
          P32^ := FinalSample;
        Inc(P32);

        // --- RIGHT CHANNEL ---
        CalcValDbl := P32^;
        if IsDSPActive then
          CalcValDbl := FToneControl.ProcessSampleR(CalcValDbl);
        CalcValDbl := CalcValDbl * VolFactor;
        AbsVal     := Abs(CalcValDbl);

        if IsSoftClip and (AbsVal > PCM32_CLIP_TH) then
        begin
          Diff   := AbsVal - PCM32_CLIP_TH;
          AbsVal := PCM32_CLIP_TH + PCM32_CLIP_HR * (Diff / (PCM32_CLIP_HR + Diff));
          if CalcValDbl < 0.0 then
            CalcValDbl := -AbsVal
          else
            CalcValDbl := AbsVal;
        end;

        if AbsVal > TempPeakR then
          TempPeakR := AbsVal;

        FinalSample := Round(CalcValDbl);
        if FinalSample > PCM32_MAX_INT then
        begin
          P32^     := PCM32_MAX_INT;
          ClippedR := True;
        end
        else if FinalSample < PCM32_MIN_INT then
        begin
          P32^     := PCM32_MIN_INT;
          ClippedR := True;
        end
        else
          P32^ := FinalSample;
        Inc(P32);
      end;
    end
    else if Bits = 24 then
    begin
      LocalSeed := FDitherSeed;
      if LocalSeed = 0 then
        LocalSeed := DEFAULT_PRNG_SEED;

      P24 := PByte(Buffer);
      for I := 0 to FrameCount - 1 do
      begin
        // --- LEFT CHANNEL ---
        V32 := (P24[0]) or (P24[1] shl 8) or (P24[2] shl 16);
        if (V32 and $800000) <> 0 then
          V32 := V32 or integer($FF000000);

        CalcValDbl := V32;
        if IsDSPActive then
          CalcValDbl := FToneControl.ProcessSampleL(CalcValDbl);
        CalcValDbl := CalcValDbl * VolFactor;
        AbsVal     := Abs(CalcValDbl);

        if IsSoftClip and (AbsVal > PCM24_CLIP_TH) then
        begin
          Diff   := AbsVal - PCM24_CLIP_TH;
          AbsVal := PCM24_CLIP_TH + PCM24_CLIP_HR * (Diff / (PCM24_CLIP_HR + Diff));
          if CalcValDbl < 0.0 then
            CalcValDbl := -AbsVal
          else
            CalcValDbl := AbsVal;
        end;

        if AbsVal > TempPeakL then
          TempPeakL := AbsVal;

        FinalSample := Round(CalcValDbl + NextTPDFDither(LocalSeed));
        if FinalSample > PCM24_MAX_INT then
        begin
          FinalSample := PCM24_MAX_INT;
          ClippedL    := True;
        end
        else if FinalSample < PCM24_MIN_INT then
        begin
          FinalSample := PCM24_MIN_INT;
          ClippedL    := True;
        end;

        P24[0] := FinalSample and $FF;
        P24[1] := (FinalSample shr 8) and $FF;
        P24[2] := (FinalSample shr 16) and $FF;
        Inc(P24, 3);

        // --- RIGHT CHANNEL ---
        V32 := (P24[0]) or (P24[1] shl 8) or (P24[2] shl 16);
        if (V32 and $800000) <> 0 then
          V32 := V32 or integer($FF000000);

        CalcValDbl := V32;
        if IsDSPActive then
          CalcValDbl := FToneControl.ProcessSampleR(CalcValDbl);
        CalcValDbl := CalcValDbl * VolFactor;
        AbsVal     := Abs(CalcValDbl);

        if IsSoftClip and (AbsVal > PCM24_CLIP_TH) then
        begin
          Diff   := AbsVal - PCM24_CLIP_TH;
          AbsVal := PCM24_CLIP_TH + PCM24_CLIP_HR * (Diff / (PCM24_CLIP_HR + Diff));
          if CalcValDbl < 0.0 then
            CalcValDbl := -AbsVal
          else
            CalcValDbl := AbsVal;
        end;

        if AbsVal > TempPeakR then
          TempPeakR := AbsVal;

        FinalSample := Round(CalcValDbl + NextTPDFDither(LocalSeed));
        if FinalSample > PCM24_MAX_INT then
        begin
          FinalSample := PCM24_MAX_INT;
          ClippedR    := True;
        end
        else if FinalSample < PCM24_MIN_INT then
        begin
          FinalSample := PCM24_MIN_INT;
          ClippedR    := True;
        end;

        P24[0] := FinalSample and $FF;
        P24[1] := (FinalSample shr 8) and $FF;
        P24[2] := (FinalSample shr 16) and $FF;
        Inc(P24, 3);
      end;

      FDitherSeed := LocalSeed;
    end;
  end
  else
  begin
    // Fallback for non-2-channel streams
    ChanIdx := 0;
    if Bits = 16 then
    begin
      LocalSeed := FDitherSeed;
      if LocalSeed = 0 then
        LocalSeed := DEFAULT_PRNG_SEED;

      P16 := PSmallInt(Buffer);
      for I := 0 to SampleCount - 1 do
      begin
        CalcValDbl := P16^ * VolFactor;
        AbsVal     := Abs(CalcValDbl);
        if (ChanIdx = 0) and (AbsVal > TempPeakL) then
          TempPeakL := AbsVal
        else if (ChanIdx = 1) and (AbsVal > TempPeakR) then
          TempPeakR := AbsVal;

        FinalSample := Round(CalcValDbl + NextTPDFDither(LocalSeed));
        if FinalSample > PCM16_MAX_INT then
        begin
          P16^ := PCM16_MAX_INT;
          if ChanIdx = 0 then ClippedL := True else ClippedR := True;
        end
        else if FinalSample < PCM16_MIN_INT then
        begin
          P16^ := PCM16_MIN_INT;
          if ChanIdx = 0 then ClippedL := True else ClippedR := True;
        end
        else
          P16^ := FinalSample;

        Inc(P16);
        Inc(ChanIdx);
        if ChanIdx >= Channels then
          ChanIdx := 0;
      end;

      FDitherSeed := LocalSeed;
    end;
  end;

  // =========================================================================
  // UI Peak & Clip Handoff
  // =========================================================================
  if Bits = 16 then
  begin
    TempPeakL := TempPeakL / PCM16_MAX_FLT;
    TempPeakR := TempPeakR / PCM16_MAX_FLT;
  end
  else if Bits = 24 then
  begin
    TempPeakL := TempPeakL / PCM24_MAX_FLT;
    TempPeakR := TempPeakR / PCM24_MAX_FLT;
  end
  else if Bits = 32 then
  begin
    TempPeakL := TempPeakL / PCM32_MAX_FLT;
    TempPeakR := TempPeakR / PCM32_MAX_FLT;
  end;

  // ---> AulumicNS: for RunGain, before the meter's limit of 1
  if TempPeakL > FBlockOutPeak then
    FBlockOutPeak := TempPeakL;
  if TempPeakR > FBlockOutPeak then
    FBlockOutPeak := TempPeakR;

  if TempPeakL > 1.0 then
    TempPeakL := 1.0;
  if TempPeakR > 1.0 then
    TempPeakR := 1.0;

  // ---> FIX: Stored as peak + 1, so 0 means "no new block measured yet"
  // (see ReadPeaks). A block of silence is stored as 1.
  UpdatePeakAtomic(FVolatilePeakL, Round(TempPeakL * 1000000) + 1);
  UpdatePeakAtomic(FVolatilePeakR, Round(TempPeakR * 1000000) + 1);

  if ClippedL or ClippedR then
    FWasClipped := True;
  if ClippedL then
    InterlockedExchange(FVolatileClipL, 1);
  if ClippedR then
    InterlockedExchange(FVolatileClipR, 1);

  // ---> ADDED: Fewer valid bits than the 32-bit container (24 in 32): a
  // changed buffer (volume, ReplayGain, tone, soft clipping, DSD to PCM, a
  // source with more bits than the DAC takes) is rounded to them with dither;
  // the DAC would cut the bits below off without it. An untouched buffer is
  // already on that grid (padded with zero bits). The last step: fades and
  // the DSP above come first.
  if (not Untouched) and (Bits = 32) then
    RoundSamplesToValidBits(PLongInt(Buffer), BytesRead div 4, ValidBits, FDitherSeed);

  // ---> ADDED: Measure the meter slices on the final output samples
  ScanMeterSlices(Buffer, BytesRead);
end;

// ---> ADDED: Peak meter slices. A WASAPI block holds a whole buffer (e.g.
// 250 ms), far too coarse for a lively meter. This read-only pass measures the
// peak of every METER_SLICE_MS of the final output samples (exactly what goes
// to the DAC) and stores it in FMeterRing; the UI plays the slices out at real
// time. Slices continue across blocks. Integer PCM 16 / 24 / 32 bit only; DoP
// is never scanned. Runs on the audio thread: no allocation, no locks.
procedure TPlayThread.ScanMeterSlices(Buffer: Pointer; BytesRead: integer);
var
  Bits, Channels, BPS, FrameBytes, Frames, I, Idx: Integer;
  Rate: Cardinal;
  P: PByte;
  VL, VR: Int64;
  V24: Integer;
  InvScale: Double;
begin
  if (BytesRead <= 0) or (Buffer = nil) or (FSource = nil) or FSource.IsDoP then
    Exit;

  Bits     := FSource.GetBitsPerSample;
  Channels := FSource.GetChannels;
  Rate     := FSource.GetSampleRate;
  if (Channels < 1) or (Rate = 0) or
     ((Bits <> 16) and (Bits <> 24) and (Bits <> 32)) then
    Exit;

  if Rate <> FSliceRate then
  begin
    FSliceRate   := Rate;
    FSliceFrames := Max(1, Integer((Rate * METER_SLICE_MS) div 1000));
    FSliceFill   := 0;
    FSliceMaxL   := 0;
    FSliceMaxR   := 0;
  end;

  case Bits of
    16: InvScale := 1.0 / 32768.0;
    24: InvScale := 1.0 / 8388608.0;
  else
    InvScale := 1.0 / 2147483648.0;
  end;

  BPS        := Bits div 8;
  FrameBytes := BPS * Channels;
  Frames     := BytesRead div FrameBytes;
  P          := PByte(Buffer);

  for I := 0 to Frames - 1 do
  begin
    case BPS of
      2:
        begin
          VL := Abs(Int64(PSmallInt(P)^));
          if Channels > 1 then
            VR := Abs(Int64(PSmallInt(P + 2)^))
          else
            VR := VL;
        end;
      3:
        begin
          V24 := P[0] or (P[1] shl 8) or (P[2] shl 16);
          if (V24 and $800000) <> 0 then
            V24 := V24 - $1000000;
          VL := Abs(Int64(V24));
          if Channels > 1 then
          begin
            V24 := P[3] or (P[4] shl 8) or (P[5] shl 16);
            if (V24 and $800000) <> 0 then
              V24 := V24 - $1000000;
            VR := Abs(Int64(V24));
          end
          else
            VR := VL;
        end;
    else
      begin
        VL := Abs(Int64(PInteger(P)^));
        if Channels > 1 then
          VR := Abs(Int64(PInteger(P + 4)^))
        else
          VR := VL;
      end;
    end;

    if VL > FSliceMaxL then
      FSliceMaxL := VL;
    if VR > FSliceMaxR then
      FSliceMaxR := VR;
    Inc(P, FrameBytes);
    Inc(FSliceFill);

    if FSliceFill >= FSliceFrames then
    begin
      Idx := FMeterWriteCount and (METER_RING_SIZE - 1);
      FMeterRing[Idx].PeakL := Min(1.0, FSliceMaxL * InvScale);
      FMeterRing[Idx].PeakR := Min(1.0, FSliceMaxR * InvScale);
      // Publish after the slice is written (locked increment = full barrier)
      InterlockedIncrement(FMeterWriteCount);
      FSliceFill := 0;
      FSliceMaxL := 0;
      FSliceMaxR := 0;
    end;
  end;
end;

procedure TPlayThread.FadeOutLastBlock(Buffer: Pointer; BytesRead: integer;
  BitDepth: integer);
var
  Samples, I: integer;
  InvSamples, Scale: double;
  P16: PSmallInt;
  P24: pbyte;
  P32: PInteger;
  V32: integer;
begin
  if (not FCurrentIsDSD) or (FSource = nil) or FSource.IsDoP then
    Exit;

  if BitDepth < 8 then
    Exit;

  Samples := BytesRead div (BitDepth div 8);
  if Samples <= 0 then
    Exit;

  InvSamples := 1.0 / Samples;

  if BitDepth = 16 then
  begin
    P16 := PSmallInt(Buffer);
    for I := 0 to Samples - 1 do
    begin
      Scale := 1.0 - (I * InvSamples);
      P16^ := Round(P16^ * Scale);
      Inc(P16);
    end;
  end
  else if BitDepth = 32 then
  begin
    P32 := PInteger(Buffer);
    for I := 0 to Samples - 1 do
    begin
      Scale := 1.0 - (I * InvSamples);
      P32^ := Round(P32^ * Scale);
      Inc(P32);
    end;
  end
  else if BitDepth = 24 then
  begin
    P24 := pbyte(Buffer);
    for I := 0 to Samples - 1 do
    begin
      Scale := 1.0 - (I * InvSamples);
      V32 := (P24[0]) or (P24[1] shl 8) or (P24[2] shl 16);
      if (V32 and $800000) <> 0 then
        V32 := V32 or integer($FF000000);
      V32 := Round(V32 * Scale);
      P24[0] := V32 and $FF;
      P24[1] := (V32 shr 8) and $FF;
      P24[2] := (V32 shr 16) and $FF;
      Inc(P24, 3);
    end;
  end;
end;

// ---> ADDED: Output format for the log in one value (see AuLog):
// rate shl 12 or container bits shl 6 or valid bits
function PackFormatCode(ARate, ABits, AValidBits: Cardinal): HRESULT;
begin
  Result := HRESULT((ARate shl 12) or ((ABits and $3F) shl 6) or (AValidBits and $3F));
end;

procedure TPlayThread.LogEvent(EventCode: integer; HRes: HRESULT);
begin
  if FNotifyHandle <> 0 then
    PostMessage(FNotifyHandle, WM_AUDIO_ENGINE_LOG, EventCode, HRes);
end;

procedure TPlayThread.LogEvent64(EventCode: integer; AValue: Int64);
begin
  if FNotifyHandle <> 0 then
    PostMessage(FNotifyHandle, WM_AUDIO_ENGINE_LOG, EventCode, LPARAM(AValue));
end;

// ---> CHANGED: Body moved to CreateSourceFor (shared with PrepareNextSource)
function TPlayThread.CreateSource(const Filename: string; out InRate, OutRate: integer): TAudioSource;
var
  LocalDsdGainDB: integer;
begin
  // ---> AUDIT FIX 3.4: Snapshot DsdGainDB under FLock
  EnterCriticalSection(FLock);
  try
    LocalDsdGainDB := FConfig.DsdGainDB;
  finally
    LeaveCriticalSection(FLock);
  end;

  Result := CreateSourceFor(FConfig, LocalDsdGainDB, @ApplyResamplerFloatDSP,
              Filename, InRate, OutRate);
end;

// =============================================================================
// Direct 64-bit Float DSP for TResamplerSource
// Preserves full floating-point inter-sample headroom above 0 dBFS through
// Tone Control, Preamp, ReplayGain, Volume, and Soft Clipping, and applies
// only a single TPDF dither pass when quantizing to 16-bit or 24-bit integer.
// =============================================================================
procedure TPlayThread.ApplyFloatDSPBlock(Buffer: PDouble; FrameCount, Channels, OutBits: Integer;
  out OutClipped: Boolean);
const
  TPDF_DITHER_SCALE = 1.0 / 2147483648.0;
  DEFAULT_PRNG_SEED = $A341316C;

  function NextTPDFDither(var Seed: Cardinal): Double; inline;
  var
    R1, R2: Cardinal;
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

var
  I, SampleCount, ChanIdx: Integer;
  P: PDouble;
  ScaleFlt, MaxRail, MinRail, ClipTh, ClipHr, VolFactor: Double;
  CalcValDbl, AbsVal, Diff, TempPeakL, TempPeakR: Double;
  IsDSPActive, IsSoftClip, UseDither, ClippedL, ClippedR: Boolean;
  LocalTone: TToneState;
  LocalSeed: Cardinal;
begin
  OutClipped := False;
  if (FrameCount <= 0) or (Channels <= 0) or (Buffer = nil) then
    Exit;

  if Assigned(FToneControl) and FToneDirty then
  begin
    EnterCriticalSection(FLock);
    try
      LocalTone  := FToneState;
      FToneDirty := False;
    finally
      LeaveCriticalSection(FLock);
    end;

    FToneControl.SetDirectMode(LocalTone.DirectMode);
    FToneControl.SetBandFrequencies(ToneFreqsOf(LocalTone));
    FToneControl.SetBandGains(ToneGainsOf(LocalTone));
  end;

  IsDSPActive := Assigned(FToneControl) and FToneControl.IsActive;

  // ---> AulumicNS: the gain of this block from the caller (TargetGain, or a
  // step of the glide to it)
  VolFactor  := FGainNow;
  IsSoftClip := (not FConfig.DisableVolume) and FConfig.EnableSoftClipping;
  // (the DSD gain of DSD converted to PCM is part of it: applied here, after
  // the resampler, with the volume and the preamp: it clips only at the end)

  if OutBits = 16 then
  begin
    ScaleFlt  := PCM16_MAX_FLT;
    MaxRail   := PCM16_MAX_INT;
    MinRail   := PCM16_MIN_INT;
    ClipTh    := PCM16_CLIP_TH;
    ClipHr    := PCM16_CLIP_HR;
    UseDither := True;
  end
  else if OutBits = 24 then
  begin
    ScaleFlt  := PCM24_MAX_FLT;
    MaxRail   := PCM24_MAX_INT;
    MinRail   := PCM24_MIN_INT;
    ClipTh    := PCM24_CLIP_TH;
    ClipHr    := PCM24_CLIP_HR;
    UseDither := True;
  end
  else
  begin
    ScaleFlt  := PCM32_MAX_FLT;
    MaxRail   := PCM32_MAX_INT;
    MinRail   := PCM32_MIN_INT;
    ClipTh    := PCM32_CLIP_TH;
    ClipHr    := PCM32_CLIP_HR;
    UseDither := False;
  end;

  LocalSeed := FDitherSeed;
  if LocalSeed = 0 then
    LocalSeed := DEFAULT_PRNG_SEED;

  TempPeakL := 0.0;
  TempPeakR := 0.0;
  ClippedL  := False;
  ClippedR  := False;
  P         := Buffer;

  if Channels = 2 then
  begin
    for I := 0 to FrameCount - 1 do
    begin
      // --- LEFT CHANNEL ---
      CalcValDbl := P^ * ScaleFlt;
      if IsDSPActive then
        CalcValDbl := FToneControl.ProcessSampleL(CalcValDbl);
      CalcValDbl := CalcValDbl * VolFactor;
      AbsVal     := Abs(CalcValDbl);

      if IsSoftClip and (AbsVal > ClipTh) then
      begin
        Diff   := AbsVal - ClipTh;
        AbsVal := ClipTh + ClipHr * (Diff / (ClipHr + Diff));
        if CalcValDbl < 0.0 then
          CalcValDbl := -AbsVal
        else
          CalcValDbl := AbsVal;
      end;

      if AbsVal > TempPeakL then
        TempPeakL := AbsVal;

      if UseDither then
        CalcValDbl := CalcValDbl + NextTPDFDither(LocalSeed);

      if CalcValDbl > MaxRail then
      begin
        CalcValDbl := MaxRail;
        ClippedL   := True;
      end
      else if CalcValDbl < MinRail then
      begin
        CalcValDbl := MinRail;
        ClippedL   := True;
      end;

      P^ := CalcValDbl;
      Inc(P);

      // --- RIGHT CHANNEL ---
      CalcValDbl := P^ * ScaleFlt;
      if IsDSPActive then
        CalcValDbl := FToneControl.ProcessSampleR(CalcValDbl);
      CalcValDbl := CalcValDbl * VolFactor;
      AbsVal     := Abs(CalcValDbl);

      if IsSoftClip and (AbsVal > ClipTh) then
      begin
        Diff   := AbsVal - ClipTh;
        AbsVal := ClipTh + ClipHr * (Diff / (ClipHr + Diff));
        if CalcValDbl < 0.0 then
          CalcValDbl := -AbsVal
        else
          CalcValDbl := AbsVal;
      end;

      if AbsVal > TempPeakR then
        TempPeakR := AbsVal;

      if UseDither then
        CalcValDbl := CalcValDbl + NextTPDFDither(LocalSeed);

      if CalcValDbl > MaxRail then
      begin
        CalcValDbl := MaxRail;
        ClippedR   := True;
      end
      else if CalcValDbl < MinRail then
      begin
        CalcValDbl := MinRail;
        ClippedR   := True;
      end;

      P^ := CalcValDbl;
      Inc(P);
    end;
  end
  else
  begin
    SampleCount := FrameCount * Channels;
    ChanIdx     := 0;
    for I := 0 to SampleCount - 1 do
    begin
      CalcValDbl := P^ * ScaleFlt;
      if IsDSPActive and (ChanIdx = 0) then
        CalcValDbl := FToneControl.ProcessSampleL(CalcValDbl);
      CalcValDbl := CalcValDbl * VolFactor;
      AbsVal     := Abs(CalcValDbl);

      if IsSoftClip and (AbsVal > ClipTh) then
      begin
        Diff   := AbsVal - ClipTh;
        AbsVal := ClipTh + ClipHr * (Diff / (ClipHr + Diff));
        if CalcValDbl < 0.0 then
          CalcValDbl := -AbsVal
        else
          CalcValDbl := AbsVal;
      end;

      if (ChanIdx = 0) and (AbsVal > TempPeakL) then
        TempPeakL := AbsVal
      else if (ChanIdx = 1) and (AbsVal > TempPeakR) then
        TempPeakR := AbsVal;

      if UseDither then
        CalcValDbl := CalcValDbl + NextTPDFDither(LocalSeed);

      if CalcValDbl > MaxRail then
      begin
        CalcValDbl := MaxRail;
        if ChanIdx = 0 then ClippedL := True else ClippedR := True;
      end
      else if CalcValDbl < MinRail then
      begin
        CalcValDbl := MinRail;
        if ChanIdx = 0 then ClippedL := True else ClippedR := True;
      end;

      P^ := CalcValDbl;
      Inc(P);
      Inc(ChanIdx);
      if ChanIdx >= Channels then
        ChanIdx := 0;
    end;

    if Channels = 1 then
    begin
      TempPeakR := TempPeakL;
      ClippedR  := ClippedL;
    end;
  end;

  FDitherSeed := LocalSeed;

  TempPeakL := TempPeakL / ScaleFlt;
  TempPeakR := TempPeakR / ScaleFlt;
  // ---> AulumicNS: for RunGain, before the meter's limit of 1
  if TempPeakL > FBlockOutPeak then
    FBlockOutPeak := TempPeakL;
  if TempPeakR > FBlockOutPeak then
    FBlockOutPeak := TempPeakR;
  if TempPeakL > 1.0 then
    TempPeakL := 1.0;
  if TempPeakR > 1.0 then
    TempPeakR := 1.0;

  // ---> FIX: Stored as peak + 1, so 0 means "no new block measured yet"
  // (see ReadPeaks). A block of silence is stored as 1.
  UpdatePeakAtomic(FVolatilePeakL, Round(TempPeakL * 1000000) + 1);
  UpdatePeakAtomic(FVolatilePeakR, Round(TempPeakR * 1000000) + 1);

  OutClipped := ClippedL or ClippedR;
  if OutClipped then
    FWasClipped := True;
  if ClippedL then
    InterlockedExchange(FVolatileClipL, 1);
  if ClippedR then
    InterlockedExchange(FVolatileClipR, 1);
end;

procedure TPlayThread.Execute;
type
  TAvSetMmThreadCharacteristicsW = function(TaskName: PWideChar; var TaskIndex: DWORD): THandle; stdcall;
  TAvRevertMmThreadCharacteristics = function(Handle: THandle): BOOL; stdcall;
const
  // ---> ADDED (ObjFPC switch): the MMCSS task, explicitly UTF-16 for the W call
  MMCSS_TASK_NAME: UnicodeString = 'Pro Audio';
var
  TaskIndex: DWORD;
  MmcssHandle: THandle;
  AvrtLib: HMODULE;
  SetMmThread: TAvSetMmThreadCharacteristicsW;
  RevertMmThread: TAvRevertMmThreadCharacteristics;

  SystemInfo: TSystemInfo;
  ProcessAffinity, SystemAffinity: DWORD_PTR;
  OptimizedMask: DWORD_PTR;
  InitialSource: TAudioSource;
  HrCoInit: HRESULT;
begin
  MmcssHandle     := 0;
  AvrtLib         := 0;
  ProcessAffinity := 0;
  SystemAffinity  := 0;
  SystemInfo      := Default(TSystemInfo);

  // 1. Start the timer FIRST
  if FConfig.UseHighResTimer then
    timeBeginPeriod(1);

  try
    // 2. Register MMCSS SECOND (Let Windows elevate the thread)
    if FConfig.EnableMMCSS then
    begin
      AvrtLib := LoadLibrary('Avrt.dll');
      if AvrtLib <> 0 then
      begin
        SetMmThread := TAvSetMmThreadCharacteristicsW(GetProcAddress(AvrtLib, 'AvSetMmThreadCharacteristicsW'));
        if Assigned(SetMmThread) then
        begin
          TaskIndex := 0;
          MmcssHandle := SetMmThread(PWideChar(MMCSS_TASK_NAME), TaskIndex);
        end;
      end;
    end;

    // 3. Set Affinity THIRD (Override the MMCSS defaults to strip Core 0)
    if FConfig.OptimizeAffinity then
    begin
      GetSystemInfo(@SystemInfo);
      if SystemInfo.dwNumberOfProcessors > 1 then
      begin
        if GetProcessAffinityMask(GetCurrentProcess(), ProcessAffinity, SystemAffinity) then
        begin
          OptimizedMask := ProcessAffinity and not DWORD_PTR(1);

          if OptimizedMask > 0 then
            SetThreadAffinityMask(GetCurrentThread(), OptimizedMask);
        end;
      end;
    end;

    // 4. Inner COM Block
    // ---> CHANGED: Multi-threaded apartment, the usual mode for a WASAPI
    // render thread (this thread has no message loop, which a single-threaded
    // apartment would need). CoUninitialize only after a successful start.
    NameThisThread('play thread');   // ---> AulumicNS: for the hang report
    HrCoInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
    try
      try
        FCurrentIsDSD := IsDSDFile(FFileName);
        FDsdGainLin := Power(10.0, FConfig.DsdGainDB / 20.0);
        InitialSource := CreateSource(FFileName, FInputSampleRate, FOutputSampleRate);

        EnterCriticalSection(FLock);
        try
          FSource := InitialSource;
        finally
          LeaveCriticalSection(FLock);
        end;

        if Assigned(FSource) then
        begin
          if FConfig.ReplayGainMode > 0 then
          begin
            CalculateReplayGainForFile(FFileName, FReplayGainDB, FReplayGainPeak);
          end;
          FRGFactor := CalculateRGFactor(FReplayGainDB, FReplayGainPeak);
          // ---> AulumicNS: automatic headroom: the album's peak so far
          HeadroomForTrack(CalcHeadroomKey(FConfig, FFileName, FInputSampleRate, FOutputSampleRate));

          try
            RunOutput;  // ---> CHANGED (output split, step 2b): was RunWasapi
          finally
            EnterCriticalSection(FLock);
            try
              FreeAndNil(FSource);
            finally
              LeaveCriticalSection(FLock);
            end;
          end;
        end;
      except
        on E: EAudioEngineError do
        begin
          SetError(E.ErrorType, E.Message, E.FailedRate);
        end;

        // ---> CHANGED: The user message stays the same (an access violation
        // is usually a device that was switched off or removed during a COM
        // call), but the log now also gets the exception class, its message
        // and the module + offset where it happened, so a real bug (e.g. in
        // a decoder) is no longer hidden behind "device disabled".
        on E: EAccessViolation do
        begin
          SetError(aeDeviceDisabled, ERR_AUDIO_DISABLED, 0,
            DescribeException(E, ExceptAddr));
        end;

        on E: Exception do
        begin
          SetError(aeUnknown, E.Message, 0,
            DescribeException(E, ExceptAddr));
        end;
        else
        begin
          SetError(aeUnknown, ERR_AUDIO_UNKNOWN, 0,
            DescribeException(nil, ExceptAddr));
        end;
      end;
    finally
      // Defensively shield the teardown from double-frees
      EnterCriticalSection(FLock);
      try
        try
          if Assigned(FSource) then
            FreeAndNil(FSource);
        except
          // Swallow silently
        end;

        try
          if Assigned(FNextSource) then
            FreeAndNil(FNextSource);
        except
          // Swallow silently
        end;
      finally
        LeaveCriticalSection(FLock);
      end;

      if Succeeded(HrCoInit) then
        CoUninitialize;
    end;

  finally
    // 5. GUARANTEED SYSTEM TEARDOWN
    if AvrtLib <> 0 then
    begin
      if MmcssHandle <> 0 then
      begin
        RevertMmThread := TAvRevertMmThreadCharacteristics(GetProcAddress(AvrtLib, 'AvRevertMmThreadCharacteristics'));
        if Assigned(RevertMmThread) then
          RevertMmThread(MmcssHandle);
      end;
      FreeLibrary(AvrtLib);
    end;

    if FConfig.UseHighResTimer then
      timeEndPeriod(1);
  end;
end;

// ---> AUDIT FIX 3.2: Synchronize error state updates under FLock
procedure TPlayThread.SetError(ErrType: TAudioErrorType; const Msg: string;
  RateInfo: Integer = 0; const ADetail: string = '');
begin
  EnterCriticalSection(FLock);
  try
    FErrorDetail      := ADetail;
    FErrorMessage     := Msg;
    FFailedSampleRate := RateInfo;
    FErrorType        := ErrType;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

// ---> CHANGED (output split, step 2b): was RunWasapi. Plays FSource on the
// output device: opens it (TAudioOutput.Open) with the retries below, fills
// its buffers (read, track switch, DSP), and reopens it for a rate switch or
// after the device dropped out. No device API here (only the creation of the
// TWasapiOutput when no OutputFactory is set).
procedure TPlayThread.RunOutput;
var
  // ---> ADDED (output split, step 2a/2b): the output (TWasapiOutput) and the
  // format it opened; this routine only talks to it
  Output            : TAudioOutput;
  OutFmt            : TAudioOutputFormat;
  OpenResult        : TOutputOpenResult;
  OpenErrorText     : string;  // as EAudioEngineError's message (no conversion)
  PData, PTail      : pbyte;
  BR, BTR, BN, BP   : integer;
  HR                : HRESULT;
  WasDoP            : boolean;
  NeedsRecovery     : boolean;
  NeedsRateSwitch   : boolean;
  TimeoutCount      : integer;
  WaitResult        : TOutputWait;
  LockRetries       : Integer;
  RecoveryStartTick : QWord;   // 0 = not recovering
  StreamOpenTick    : QWord;
  FirstOpen         : Boolean;   // True until the first successful open of this Play
  IsDeviceGone      : Boolean;
  LocalSeekPos      : double;
  ActualSeekPos     : double;
  DoSeekNow         : boolean;
  SwappedThisBuffer : boolean;
  DSPAlreadyApplied : boolean;
  RetiredSource     : TAudioSource;
  // ---> AulumicNS: the stream ended (end of the queue, a reopen at another
  // rate): let the output play what it holds before Close (Output.Drain)
  DrainBeforeClose  : boolean;
  // ---> AulumicNS: the diagnostics of this stream for the log (dropouts,
  // the longest time a buffer took to fill: read, resample, DSP)
  LastDropouts      : Integer;
  WorkStartUs       : Int64;
  MaxWorkUs         : Int64;
  BuffersOut        : Int64;
  // ---> AulumicNS: refused formats tried again (see oorFormatUnsupported)
  FormatRetries     : Integer;
  OpenStartTick     : QWord;   // RunOutput's start (InSettle)
  CloseStartTick    : QWord;   // Output.Close's start (alOutputCloseSlow)
  TieCheckTick      : QWord;   // ASIO: when to count the driver's tied windows again
  LastTied          : Integer; // the count logged last (-1 = none yet)

  // ---> AulumicNS: within FConfig.SettleMs from the start: the device was
  // used by the stream before (a switch during a track) and may still be
  // changing over
  function InSettle: Boolean;
  begin
    Result := (FConfig.SettleMs > 0) and (GetTickCount64 - OpenStartTick < QWord(FConfig.SettleMs));
  end;

  // Device not ready (switched off, being switched on, re-enumerating):
  // may we wait and try again? Never on the first open of a Play (the user
  // gets the message at once); otherwise for up to RECOVERY_WINDOW_MS.
  // ---> AulumicNS: on the first open while InSettle too
  function DeviceRetryAllowed: Boolean;
  begin
    if FirstOpen then
      Exit(InSettle);
    if RecoveryStartTick = 0 then
      RecoveryStartTick := GetTickCount64;
    Result := (GetTickCount64 - RecoveryStartTick) < RECOVERY_WINDOW_MS;
  end;

  procedure ValidateNextSource;
  begin
    if FNextSource.GetChannels > 2 then
    begin
      raise EAudioEngineError.CreateTyped(aeMultiChannel, ERR_AUDIO_MULTI_CHANNEL);
    end;

    if FNextSource.GetChannels = 1 then
      FNextSource := TMonoToStereoSource.Create(FNextSource);
  end;

  procedure CommitSeamlessSwap;
  begin
    FNextSource.PrepareGapless(FSource);
    RetiredSource := FSource;

    FDurationCache := FNextSource.GetDuration;

    // ---> CHANGED (output split, step 2a): the open stream's format (OutFmt)
    FNextSource.SetTargetBitDepth(OutFmt.Bits);

    if FNextSource.GetBitsPerSample <> OutFmt.Bits then
      FNextSource := TBitDepthConverterSource.Create(FNextSource, OutFmt.Bits);

    FSource     := FNextSource;
    FNextSource := nil;

    FInputSampleRate  := FNextInputRate;
    FOutputSampleRate := FNextOutputRate;
    FReplayGainDB     := FNextReplayGainDB;
    FReplayGainPeak   := FNextReplayGainPeak;
    FRGFactor         := FNextRGFactor;
    FCurrentIsDSD     := FNextIsDSD;
    HeadroomForTrack(FNextHeadKey);   // ---> AulumicNS: the same album keeps its level

    FTotalFrames := Trunc(FDurationCache * OutFmt.SampleRate);
    if FTotalFrames < 1 then
      FTotalFrames := 1;

    FWasClipped   := False;
    FTrackSwapped := True;
  end;

  procedure CommitHardwareRateSwap;
  begin
    RetiredSource := FSource;
    FSource       := FNextSource;
    FNextSource   := nil;

    FWasClipped          := False;
    FTrackSwapped        := True;
    FInputSampleRate     := FNextInputRate;
    FOutputSampleRate    := FNextOutputRate;
    FReplayGainDB        := FNextReplayGainDB;
    FReplayGainPeak      := FNextReplayGainPeak;
    FRGFactor            := FNextRGFactor;

    FCurrentIsDSD        := FNextIsDSD;
    // ---> AulumicNS: the device opens anew: the stream starts at its gain
    HeadroomForTrack(FNextHeadKey);
    FGainCur             := -1.0;
    FDurationCache       := FSource.GetDuration;
    FOutputFramesWritten := 0;
    FProgressCache       := 0.0;
    NeedsRateSwitch      := True;
  end;

  // ---> AulumicNS: the buffers after the first one that the output wants
  // before Start (Output.PrefillBuffers; a ring - ASIO - starts with about
  // 40 ms instead of one period). Stops at the end of the source.
  procedure PrefillMore(AUpdateProgress: Boolean);
  var
    I, N: Integer;
  begin
    for I := 2 to Output.PrefillBuffers do
    begin
      if not Output.GetBuffer(PData, HR) then
      begin
        LogEvent(ord(alBufferInvalidated), HR);
        NeedsRecovery := True;
        Exit;
      end;
      N := FillBlock(PData, BTR, OutFmt.BlockAlign, AUpdateProgress);
      Output.ReleaseBuffer(True);
      if N < BTR then
        Exit;
    end;
  end;

  // ---> AulumicNS: after each buffer: its time to fill, and a new dropout of
  // the output goes to the log at once, with about where in the track it was
  // (the count in the low 20 bits, the second in the track above them)
  // ---> AulumicNS: windows an ASIO driver made on threads of its own that
  // hang on a window of another thread (ALOutputAsio.CountTiedWindows): a
  // change of the count goes to the log (tied to the main thread = an error:
  // a click may freeze the window)
  procedure CheckTiedWindows;
  var
    ToMain, ToOther: Integer;
  begin
    if not (Output is TAsioOutput) then Exit;
    CountTiedWindows(ToMain, ToOther);
    ToMain := Min(ToMain, $FFFF);
    ToOther := Min(ToOther, $FFFF);
    if (ToMain + ToOther = 0) and (LastTied < 0) then Exit;
    if (ToMain or (ToOther shl 16)) = LastTied then Exit;
    LastTied := ToMain or (ToOther shl 16);
    LogEvent(ord(alAsioTiedWindows), LastTied);
  end;

  procedure CheckOutputHealth;
  var
    N: Integer;
    Secs: Int64;
  begin
    if (TieCheckTick <> 0) and (GetTickCount64 >= TieCheckTick) then
    begin
      TieCheckTick := 0;
      CheckTiedWindows;
    end;
    Inc(BuffersOut);
    if WorkStartUs <> 0 then
    begin
      if OutputNowUs - WorkStartUs > MaxWorkUs then
        MaxWorkUs := OutputNowUs - WorkStartUs;
      WorkStartUs := 0;
    end;
    N := Output.DropoutCount;
    if N > LastDropouts then
    begin
      LastDropouts := N;
      Secs := Round(EnsureRange(FProgressCache, 0.0, 1.0) * FDurationCache);
      LogEvent64(ord(alOutputDropout), Int64(Min(N, $FFFFF)) or (Min(Secs, $FFFFF) shl 20));
    end;
  end;

  // ---> AulumicNS: the stream's summary for the log before Close: dropouts
  // (bits 0..19), the least audio buffered ahead + 1 in ms (20..39; 0 = not
  // known), the longest fill in 10 us (40..59). Outputs that cannot tell
  // (the test program's) log nothing.
  procedure LogStreamSummary;
  var
    D, L: Int64;
  begin
    if BuffersOut = 0 then Exit;
    D := Output.DropoutCount;
    if D < 0 then Exit;
    L := Output.LeastBufferedMs + 1;
    if L < 0 then L := 0;
    LogEvent64(ord(alOutputStats), Min(D, $FFFFF) or (Min(L, $FFFFF) shl 20) or
      (Min(MaxWorkUs div 10, $FFFFF) shl 40));
  end;

  // ---> AulumicNS: the stream ends after the buffer that is playing: an
  // output that needs it (WASAPI) gets one buffer of silence, then Drain
  // waits before Close (was: closed at once, which cut the last buffer)
  procedure EndStreamHere;
  begin
    if Output.DrainTail then
    begin
      FillTail(PData, BTR, WasDoP);
      Output.ReleaseBuffer(True);
    end
    else
      Output.ReleaseBuffer(False);
    DrainBeforeClose := True;
  end;

  // ---> ADDED (output split, step 1): A forced gapless swap in this buffer
  // (FForceGaplessSwap): the same rate continues seamlessly in it, another
  // rate reopens the device (CommitHardwareRateSwap sets NeedsRateSwitch).
  // Moved unchanged from the loop; the caller frees RetiredSource and leaves
  // the loop when NeedsRateSwitch is set.
  procedure SwitchOnForcedSwap;
  begin
    EnterCriticalSection(FLock);
    try
      if Assigned(FNextSource) then
      begin
        ValidateNextSource;

        if (FNextSource.GetSampleRate = FSource.GetSampleRate) and
           (FNextSource.GetChannels = FSource.GetChannels) then
        begin
          if not WasDoP then
            FadeOutLastBlock(PData, BR, FSource.GetBitsPerSample);

          if BR > 0 then
            ApplyDSP(PData, BR);
          DSPAlreadyApplied := True;

          CommitSeamlessSwap;

          FOutputFramesWritten := 0;
          FProgressCache       := 0.0;
          FForceGaplessSwap    := False;
          SwappedThisBuffer    := True;
        end
        else
        begin
          CommitHardwareRateSwap;
          FForceGaplessSwap := False;
          Output.ReleaseBuffer(False);
        end;
      end
      else
      begin
        FForceGaplessSwap := False;
      end;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;

  // ---> ADDED (output split, step 1): The source ended inside this buffer
  // (BR < BTR). A next track at the same rate fills the rest of the buffer
  // (seamless gapless); another rate fades out and reopens the device once the
  // old track has nothing left; no next track fades out. Moved unchanged from
  // the loop; the caller frees RetiredSource and leaves the loop when
  // NeedsRateSwitch is set.
  procedure SwitchAtTrackEnd;
  var
    ReadNewTrackHead: Boolean;  // seamless swap done, read the new track after FLock
  begin
    ReadNewTrackHead := False;
    EnterCriticalSection(FLock);
    try
      if Assigned(FNextSource) then
      begin
        ValidateNextSource;

        if (FNextSource.GetSampleRate = FSource.GetSampleRate) and
           (FNextSource.GetChannels = FSource.GetChannels) then
        begin
          if BR > 0 then
            ApplyDSP(PData, BR);

          BN    := BTR - BR;
          PTail := PData + BR;

          CommitSeamlessSwap;

          // ---> AUDIT FIX: The new track's first block is read
          // below, after FLock is released (see ReadNewTrackHead)
          ReadNewTrackHead := True;
        end
        else
        begin
          if BR > 0 then
          begin
            if not WasDoP then
              FadeOutLastBlock(PData, BR, FSource.GetBitsPerSample);
          end
          else
          begin
            CommitHardwareRateSwap;
            EndStreamHere;  // ---> AulumicNS: the old track plays out first
          end;
        end;
      end
      else
      begin
        if (BR > 0) and (not WasDoP) then
          FadeOutLastBlock(PData, BR, FSource.GetBitsPerSample);
      end;
    finally
      LeaveCriticalSection(FLock);
    end;

    // ---> AUDIT FIX: Read the first block of the new track outside
    // FLock. The read can wait for the disk (a drive that sleeps or
    // a NAS that hesitates), and the UI thread takes FLock about 20
    // times a second (HasError, GetBitDepth, ...): it no longer
    // stalls with it. Only this thread replaces FSource, and the
    // normal path reads FSource without FLock too.
    if ReadNewTrackHead then
    begin
      BP := FSource.ReadData(PTail, BN);

      if BP > 0 then
        ApplyDSP(PTail, BP);

      DSPAlreadyApplied := True;
      SwappedThisBuffer := True;
      WasDoP            := FSource.IsDoP;

      // The new track's frames start at 0 (resampled output counts frames)
      if FConfig.ResamplePCM and (OutFmt.BlockAlign > 0) then
        FOutputFramesWritten := 0;
      CountOutputFrames(BP, OutFmt.BlockAlign, True);

      Inc(BR, BP);
    end;
  end;

  // ---> FIXED: DSD to PCM: is this FULL buffer the track's last one? The end
  // fade (FadeOutLastBlock) was only given to a buffer the source did not
  // fill (SwitchAtTrackEnd); a track whose last sample filled a buffer
  // exactly (about 1 in 4400 with 50 ms buffers) ended without it. The DSF
  // reader's progress is 1.0 only when every DSD byte has been read, and the
  // converter keeps no samples between reads, so the next read would return
  // nothing. Not with the resampler in the chain (its output lags its input),
  // and not when a next track continues seamlessly (same rate and channels,
  // as SwitchAtTrackEnd decides; a mono next track becomes stereo there).
  function EndsWithThisFullBuffer: Boolean;
  var
    NextChannels: Integer;
  begin
    Result := False;
    if (not FCurrentIsDSD) or WasDoP or (BR <> BTR) then
      Exit;
    if FSource.FindLayer(TResamplerSource) <> nil then
      Exit;
    if FSource.GetProgress < 1.0 then
      Exit;

    EnterCriticalSection(FLock);
    try
      if Assigned(FNextSource) then
      begin
        NextChannels := FNextSource.GetChannels;
        if NextChannels = 1 then
          NextChannels := 2;
        Result := (FNextSource.GetSampleRate <> FSource.GetSampleRate) or
                  (NextChannels <> FSource.GetChannels);
      end
      else
        Result := True;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;

begin
  LockRetries   := 0;
  FormatRetries := 0;
  OpenStartTick := GetTickCount64;
  TieCheckTick := 0;
  LastTied := -1;
  RecoveryStartTick := 0;
  FirstOpen         := True;
  RetiredSource := nil;
  Output        := nil;
  OutFmt        := Default(TAudioOutputFormat);

  EnterCriticalSection(FLock);
  try
    if Assigned(FSource) and (FSource.GetChannels > 2) then
    begin
      raise EAudioEngineError.CreateTyped(aeMultiChannel, ERR_AUDIO_MULTI_CHANNEL);
    end;

    if Assigned(FSource) and (FSource.GetChannels = 1) then
    begin
      FSource := TMonoToStereoSource.Create(FSource);
    end;

    FDurationCache := FSource.GetDuration;
  finally
    LeaveCriticalSection(FLock);
  end;

  if FConfig.BufferMs < VAL_MIN_BUFFER then
    FConfig.BufferMs := VAL_MIN_BUFFER;

  try
    while WaitForSingleObject(FStopEvent, 0) <> WAIT_OBJECT_0 do
    begin
      NeedsRecovery    := False;
      NeedsRateSwitch  := False;
      DrainBeforeClose := False;
      LastDropouts     := 0;
      WorkStartUs      := 0;
      MaxWorkUs        := 0;
      BuffersOut       := 0;

      // Interruptible 200ms wait on hardware rate transitions
      if (FLastHardwareRate > 0) and (FLastHardwareRate <> FOutputSampleRate) then
      begin
        if WaitForSingleObject(FStopEvent, 200) = WAIT_OBJECT_0 then
          Break;
      end;

      FLastHardwareRate := FOutputSampleRate;

      // ---> CHANGED (output split, step 2b): Opening the device (the
      // configured DAC only, its format, starting the stream) is the output's
      // job (TWasapiOutput.Open). The waits and retries for each kind of
      // failure stay here, the same as before the split:
      //   no device         : at once a message on the first open; during a
      //                       recovery poll every DEVICE_POLL_MS (a DAC that is
      //                       switched on, a USB device re-enumerating)
      //   lost while checking: during a recovery wait DEVICE_RETRY_MS, else
      //                       a message
      //   in use / lost while starting: during a recovery the lost device is
      //                       waited for; otherwise three tries 1 s apart, then
      //                       a message
      // ---> CHANGED (output split, step 3a): the output from OutputFactory
      // when one is set (the test program), else WASAPI
      if Assigned(FOutputFactory) then
        Output := FOutputFactory()
      // ---> AulumicNS: ASIO (same TAudioOutput contract)
      else if FConfig.OutputApi = 1 then
        Output := TAsioOutput.Create(FConfig.AsioNativeDsd)
      else
        Output := TWasapiOutput.Create;
      OpenResult := Output.Open(FConfig.DeviceId, FOutputSampleRate, FSource.GetChannels,
                                FSource.IsDoP, FConfig.BufferMs, HR, OpenErrorText);
      if OpenResult <> oorOK then
      begin
        FreeAndNil(Output);
        case OpenResult of
          oorEndpointFail:
            raise EAudioEngineError.CreateTyped(aeEndpointFail, ERR_AUDIO_ENDPOINTFAIL);

          oorNoDevice:
          begin
            if not DeviceRetryAllowed then
              raise EAudioEngineError.CreateTyped(aeDeviceDisabled, ERR_AUDIO_DEVICE_UNAVAILABLE);
            if WaitForSingleObject(FStopEvent, DEVICE_POLL_MS) = WAIT_OBJECT_0 then
              Break;
            Continue;
          end;

          oorLostWhileChecking:
          begin
            // The device disappeared or reset its stream meanwhile: not a
            // sample rate problem. During a recovery wait and try again.
            LogEvent(ord(alWasapiInitFailed), HR);
            if not DeviceRetryAllowed then
              raise EAudioEngineError.CreateTyped(aeDeviceDisabled, ERR_AUDIO_DEVICE_UNAVAILABLE);
            if WaitForSingleObject(FStopEvent, DEVICE_RETRY_MS) = WAIT_OBJECT_0 then
              Break;
            Continue;
          end;

          oorFormatUnsupported:
          begin
            // ---> AulumicNS: a DAC that has just been used another way can
            // refuse a format for a moment: asked again FORMAT_RETRIES times
            // before the message - on the first open only while InSettle (a
            // switch during a track; else at once, as before), on a reopen
            // during playback (another rate) always
            if (FormatRetries < FORMAT_RETRIES) and ((not FirstOpen) or InSettle) then
            begin
              Inc(FormatRetries);
              if WaitForSingleObject(FStopEvent, FORMAT_RETRY_MS) = WAIT_OBJECT_0 then
                Break;
              Continue;
            end;
            LogEvent(ord(alWasapiInitFailed), HR);
            raise EAudioEngineError.CreateTyped(aeSampleRateUnsupported, OpenErrorText,
              FOutputSampleRate);
          end;

          oorInUse, oorLostWhileStarting:
          begin
            LogEvent(ord(alWasapiInitFailed), HR);
            IsDeviceGone := OpenResult = oorLostWhileStarting;

            // During a recovery: keep waiting while the device comes back
            if IsDeviceGone and DeviceRetryAllowed then
            begin
              if WaitForSingleObject(FStopEvent, DEVICE_RETRY_MS) = WAIT_OBJECT_0 then
                Break;
              Continue;
            end;

            Inc(LockRetries);

            if LockRetries <= 3 then
            begin
              if WaitForSingleObject(FStopEvent, 1000) = WAIT_OBJECT_0 then
                Break;
              Continue;
            end
            else if IsDeviceGone then
              raise EAudioEngineError.CreateTyped(aeDeviceDisabled, ERR_AUDIO_DEVICE_UNAVAILABLE)
            else
              raise EAudioEngineError.CreateTyped(aeDeviceInUse, ERR_AUDIO_INUSE);
          end;
        else
          begin
            // oorFailed: a format the device refused when starting, or
            // anything else (the text names the format that was attempted)
            // ---> AulumicNS: asked again as a refused format (see there)
            if (FormatRetries < FORMAT_RETRIES) and ((not FirstOpen) or InSettle) then
            begin
              Inc(FormatRetries);
              if WaitForSingleObject(FStopEvent, FORMAT_RETRY_MS) = WAIT_OBJECT_0 then
                Break;
              Continue;
            end;
            LogEvent(ord(alWasapiInitFailed), HR);
            raise EAudioEngineError.CreateTyped(aeSampleRateUnsupported, OpenErrorText,
              FOutputSampleRate);
          end;
        end;
      end;

      // ---> AUDIT FIX 1.3: The open output is closed via try..finally even if
      // an exception occurs below or inside the inner playback loop
      try
        // ---> CHANGED (output split, step 2b): the format the output opened
        OutFmt         := Output.Format;
        LockRetries    := 0;
        FormatRetries  := 0;
        // ---> AulumicNS: the device took a shorter buffer than asked (WASAPI
        // falls back when the driver refuses the period): into the log
        if (Output.BufferedMs >= 0) and (Output.BufferedMs < (FConfig.BufferMs * 9) div 10) then
          LogEvent(ord(alOutputBufferShorter),
            HRESULT(Cardinal(Min(FConfig.BufferMs, $FFFF)) or (Cardinal(Min(Output.BufferedMs, $FFFF)) shl 16)));
        StreamOpenTick := GetTickCount64;
        FirstOpen      := False;

        if RecoveryStartTick <> 0 then
          LogEvent(ord(alDeviceReopened), HRESULT(GetTickCount64 - RecoveryStartTick));

        EnterCriticalSection(FLock);
        try
          FSource.SetTargetBitDepth(OutFmt.Bits);

          if FSource.GetBitsPerSample <> OutFmt.Bits then
            FSource := TBitDepthConverterSource.Create(FSource, OutFmt.Bits);
        finally
          LeaveCriticalSection(FLock);
        end;

        // ---> AUDIT FIX 3.3: Publish the negotiated depth for SetNextFile
        InterlockedExchange(FNegotiatedBits, OutFmt.Bits);
        InterlockedExchange(FNegotiatedValid, OutFmt.ValidBits);
        // ---> AulumicNS: for the signal path
        if (Output is TAsioOutput) and TAsioOutput(Output).NativeDsd then
          InterlockedExchange(FNativeDsdOut, 1)
        else
          InterlockedExchange(FNativeDsdOut, 0);

        // ---> MODIFIED: Log the full output format. The source note
        // (resampled / converted from DSD) is posted first; the log keeps it for
        // the "Output to DAC" line that follows.
        if FCurrentIsDSD and (not FSource.IsDoP) then
          LogEvent(ord(alStreamSource), HRESULT(2))
        else if (not FCurrentIsDSD) and (FInputSampleRate > 0) and
                (FInputSampleRate <> FOutputSampleRate) then
          LogEvent(ord(alStreamSource), HRESULT((Cardinal(FInputSampleRate) shl 2) or 1));

        // ---> AulumicNS: native DSD over ASIO has a line of its own (it
        // read "via DoP")
        if FSource.IsDoP and (InterlockedCompareExchange(FNativeDsdOut, 0, 0) = 1) then
          LogEvent(ord(alOutputNativeDsd),
            PackFormatCode(OutFmt.SampleRate, OutFmt.Bits, OutFmt.ValidBits))
        else if FSource.IsDoP then
          LogEvent(ord(alWasapiFormatDoP),
            PackFormatCode(OutFmt.SampleRate, OutFmt.Bits, OutFmt.ValidBits))
        else
          LogEvent(ord(alWasapiFormatAccepted),
            PackFormatCode(OutFmt.SampleRate, OutFmt.Bits, OutFmt.ValidBits));

        if Assigned(FToneControl) then
          FToneControl.SetSampleRate(OutFmt.SampleRate);

        BTR := Output.BufferBytes;

        FTotalFrames := Trunc(FDurationCache * OutFmt.SampleRate);
        if FTotalFrames < 1 then
          FTotalFrames := 1;
        FOutputFramesWritten := 0;

        // After a recovery the source continues mid-track: keep the progress
        // display there instead of jumping back to 0 (resampled output counts frames)
        if (RecoveryStartTick <> 0) and FConfig.ResamplePCM then
          FOutputFramesWritten := Trunc(EnsureRange(FSource.GetProgress, 0.0, 1.0) * FTotalFrames);

        // ---> AUDIT FIX N5: Apply a seek that was requested before WASAPI started
        // (Play followed immediately by Seek, as in ExitMaintenance / RestartCurrent)
        // BEFORE the prefill, so the first buffer never plays from the old position.
        EnterCriticalSection(FLock);
        try
          DoSeekNow      := FSeekRequested;
          LocalSeekPos   := FSeekPosition;
          FSeekRequested := False;
        finally
          LeaveCriticalSection(FLock);
        end;

        if DoSeekNow then
        begin
          FSource.Seek(LocalSeekPos);
          // ---> AUDIT FIX: If the source did not reach the target (failed FLAC
          // seek), show the position it really plays from instead of the target
          ActualSeekPos := EnsureRange(FSource.GetProgress, 0.0, 1.0);
          if Abs(ActualSeekPos - LocalSeekPos) > 0.005 then
            LocalSeekPos := ActualSeekPos;
          if Assigned(FToneControl) then
            FToneControl.ResetAllStates;
          FWasClipped := False;
          if FConfig.ResamplePCM then
            FOutputFramesWritten := Trunc(LocalSeekPos * FTotalFrames);
          FProgressCache := LocalSeekPos;
        end;

        if not Output.GetBuffer(PData, HR) then
        begin
          LogEvent(ord(alBufferInvalidated), HR);
          NeedsRecovery := True;
        end
        else
        begin
          // ---> CHANGED (output split, step 1): FillBlock (was written out here)
          if FillBlock(PData, BTR, OutFmt.BlockAlign, True) = BTR then
          begin
            Output.ReleaseBuffer(True);
            PrefillMore(True);
          end
          else
            Output.ReleaseBuffer(True);
        end;

        // ---> AUDIT FIX N5: Do not start the device when Pause arrived before the
        // stream started; the pause loop below starts it on Resume.
        if (not NeedsRecovery) and (not FPaused) then
          Output.Start;
        TimeoutCount := 0;
        // ---> AulumicNS: the driver's tied windows now and 3 s later (a
        // driver may make its windows when the stream runs)
        CheckTiedWindows;
        TieCheckTick := GetTickCount64 + 3000;

        while (not NeedsRecovery) and (not NeedsRateSwitch) do
        begin
          if FPaused then
          begin
            Output.Stop;
            while FPaused and (WaitForSingleObject(FStopEvent, 50) = WAIT_TIMEOUT) do
            begin
              if FSeekRequested then
              begin
                EnterCriticalSection(FLock);
                try
                  LocalSeekPos := FSeekPosition;
                finally
                  LeaveCriticalSection(FLock);
                end;
                FProgressCache := LocalSeekPos;
              end;
            end;

            if WaitForSingleObject(FStopEvent, 0) = WAIT_OBJECT_0 then
              Break;

            if not FSeekRequested then
              Output.Start;
          end;

          if FSeekRequested then
          begin
            EnterCriticalSection(FLock);
            try
              DoSeekNow      := FSeekRequested;
              LocalSeekPos   := FSeekPosition;
              FSeekRequested := False;
            finally
              LeaveCriticalSection(FLock);
            end;

            if DoSeekNow then
            begin
              Output.Stop;
              Output.Reset;
              FSource.Seek(LocalSeekPos);

              // ---> AUDIT FIX: If the source did not reach the target (failed
              // FLAC seek), show the position it really plays from instead
              ActualSeekPos := EnsureRange(FSource.GetProgress, 0.0, 1.0);
              if Abs(ActualSeekPos - LocalSeekPos) > 0.005 then
                LocalSeekPos := ActualSeekPos;

              if Assigned(FToneControl) then
                FToneControl.ResetAllStates;
              FWasClipped := False;

              if FConfig.ResamplePCM then
              begin
                FOutputFramesWritten := Trunc(LocalSeekPos * FTotalFrames);
                FProgressCache       := LocalSeekPos;
              end
              else
                FProgressCache := LocalSeekPos;

              if not Output.GetBuffer(PData, HR) then
              begin
                LogEvent(ord(alBufferInvalidated), HR);
                NeedsRecovery := True;
                Break;
              end
              else
              begin
                // ---> CHANGED (output split, step 1): FillBlock; the progress
                // stays at the seek target (only the frames are counted)
                if FillBlock(PData, BTR, OutFmt.BlockAlign, False) = BTR then
                begin
                  Output.ReleaseBuffer(True);
                  PrefillMore(False);
                  if NeedsRecovery then
                    Break;
                end
                else
                  Output.ReleaseBuffer(True);
              end;

              // ---> AUDIT FIX 3.5: Do not un-pause the device when seeking while paused!
              if not FPaused then
                Output.Start;
            end;
          end;

          // ---> CHANGED (output split, step 2a): Output.WaitForBuffer (the
          // stop event and the device's buffer event; a failed wait is
          // ignored as before)
          WaitResult := Output.WaitForBuffer(FStopEvent, 500);

          if WaitResult = owStop then
          begin
            Break;
          end
          else if WaitResult = owBufferReady then
          begin
            TimeoutCount      := 0;
            SwappedThisBuffer := False;
            DSPAlreadyApplied := False;

            // Sound has been flowing normally for a while: the recovery is over
            if (RecoveryStartTick <> 0) and (GetTickCount64 - StreamOpenTick >= RECOVERY_STABLE_MS) then
              RecoveryStartTick := 0;

            if not Output.GetBuffer(PData, HR) then
            begin
              LogEvent(ord(alBufferInvalidated), HR);
              NeedsRecovery := True;
              Break;
            end
            else
            begin
              WorkStartUs := OutputNowUs;   // ---> AulumicNS: CheckOutputHealth
              BR     := FSource.ReadData(PData, BTR);
              WasDoP := FSource.IsDoP;

              if FSource.CheckClipping then
                FWasClipped := True;

              // ---> CHANGED (output split, step 1): The track switch in two
              // routines (SwitchOnForcedSwap, SwitchAtTrackEnd; moved unchanged).
              // A switch to another rate reopens the device: leave the loop.
              if FForceGaplessSwap then
                SwitchOnForcedSwap
              else if BR < BTR then
                SwitchAtTrackEnd
              else if EndsWithThisFullBuffer then
                FadeOutLastBlock(PData, BR, FSource.GetBitsPerSample);  // ---> FIXED: see there

              if NeedsRecovery or NeedsRateSwitch then
              begin
                if Assigned(RetiredSource) then
                  FreeAndNil(RetiredSource);
                Break;
              end;

              if BR = 0 then
              begin
                EndStreamHere;  // ---> AulumicNS: was ReleaseBuffer(False)
                if Assigned(RetiredSource) then
                  FreeAndNil(RetiredSource);
                Break; // End of file
              end;

              // ---> CHANGED (output split, step 1): FillTail / CountOutputFrames
              if BR < BTR then
                FillTail(PData + BR, BTR - BR, WasDoP);

              if not SwappedThisBuffer then
                CountOutputFrames(BR, OutFmt.BlockAlign, True);

              if not DSPAlreadyApplied then
                ApplyDSP(PData, BR);

              Output.ReleaseBuffer(True);
              CheckOutputHealth;   // ---> AulumicNS: dropouts to the log

              // ---> AUDIT FIX 3.3: Hand the retired source to the UI thread instead
              // of closing files / freeing decoders on the MMCSS render thread
              if Assigned(RetiredSource) then
                DeferFreeSource(RetiredSource);
            end;
          end
          else if WaitResult = owTimeout then
          begin
            Inc(TimeoutCount);
            if TimeoutCount >= 4 then
            begin
              LogEvent(ord(alDeviceGhostTimeout));
              NeedsRecovery := True;
              Break;
            end;
          end;
        end; // End of INNER Loop
      finally
        if Assigned(RetiredSource) then
          FreeAndNil(RetiredSource);

        // ---> AulumicNS: the last buffers play before Close (see EndStreamHere)
        if DrainBeforeClose and (not NeedsRecovery) then
          Output.Drain(FStopEvent)
        // ---> AulumicNS: closed in the middle of the music (a manual switch to
        // a track of another rate, Stop): not cut at a full sample value
        else if not NeedsRecovery then
          Output.FadeOut;
        LogStreamSummary;   // ---> AulumicNS: dropouts, margin, time per buffer

        // ---> CHANGED (output split, step 2a/2b): Close stops the stream and
        // releases the device (was: AC.Stop, CloseHandle, the interfaces)
        CloseStartTick := GetTickCount64;
        Output.Close;
        FreeAndNil(Output);
        FClosedTick := GetTickCount64;   // ---> AulumicNS: see TAudioEngine.Stop
        // ---> AulumicNS: a driver that takes long to let go of the device
        // (switching back from native DSD) is on record
        if FClosedTick - CloseStartTick >= 500 then
          LogEvent(ord(alOutputCloseSlow), HRESULT(Min(FClosedTick - CloseStartTick, QWord(MaxInt))));
      end;

      if NeedsRecovery then
      begin
        // Stop when the device has not played normally again within
        // RECOVERY_WINDOW_MS, instead of 'playing' forever with a frozen timer
        if not DeviceRetryAllowed then
          raise EAudioEngineError.CreateTyped(aeDeviceDisabled, ERR_AUDIO_DEVICE_UNAVAILABLE);

        LogEvent(ord(alRecoveryTriggered));
        if WaitForSingleObject(FStopEvent, 1000) = WAIT_OBJECT_0 then
          Break;
      end
      else if NeedsRateSwitch then
      begin
        Continue;
      end
      else
        Break;

    end; // End of OUTER Loop
  finally
    if Assigned(RetiredSource) then
      FreeAndNil(RetiredSource);
  end;
end;

function TPlayThread.GetAppliedReplayGain: double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FReplayGainDB;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPlayThread.IsBitPerfect: boolean;
begin
  Result := InterlockedCompareExchange(FBitPerfect, 0, 0) = 1;
end;

// ---> AulumicNS: a snapshot of what the chain does, for the signal path. Only
// reads (the source chain under FLock as GetBitDepth does); the tone control's
// state is read as the audio thread left it (a display value).
function TPlayThread.GetSignalInfo: TSignalInfo;
var
  Conv: TAudioSource;
begin
  Result := Default(TSignalInfo);
  EnterCriticalSection(FLock);
  try
    if not Assigned(FSource) then Exit;
    Result.Valid := InterlockedCompareExchange(FNegotiatedBits, 0, 0) > 0;
    Result.IsDsd := FCurrentIsDSD;
    Result.DoP := FSource.IsDoP;
    Result.NativeDsd := Result.DoP and (InterlockedCompareExchange(FNativeDsdOut, 0, 0) = 1);
    if Result.NativeDsd then Result.DoP := False;
    Result.DsdToPcm := FCurrentIsDSD and not FSource.IsDoP;
    Result.Resampled := FSource.FindLayer(TResamplerSource) <> nil;
    Result.InRate := FInputSampleRate;
    Result.OutRate := FOutputSampleRate;
    Result.OutBits := FSource.GetBitsPerSample;
    Result.SourceBits := Result.OutBits;
    Conv := FSource.FindLayer(TBitDepthConverterSource);
    if Assigned(Conv) then Result.SourceBits := TBitDepthConverterSource(Conv).GetSourceBitsPerSample;
    Result.Channels := FSource.GetChannels;
    Result.RGFactor := FRGFactor;
  finally
    LeaveCriticalSection(FLock);
  end;
  Result.OutValidBits := InterlockedCompareExchange(FNegotiatedValid, 0, 0);
  if (Result.OutValidBits <= 0) or (Result.OutValidBits > Result.OutBits) then
    Result.OutValidBits := Result.OutBits;
  Result.ToneActive := Assigned(FToneControl) and FToneControl.IsActive;
  Result.VolumeDisabled := FConfig.DisableVolume;
  if FConfig.DisableVolume then Result.PreampDB := 0 else Result.PreampDB := FConfig.PreampDB;
  Result.Volume := FVolumeInt;
  Result.SoftClip := FConfig.EnableSoftClipping and not FConfig.DisableVolume;
  Result.OutputApi := FConfig.OutputApi;
  Result.ResampleQuality := FConfig.ResampleQuality;
  if Result.OutRate >= Result.InRate then Result.Phase := FConfig.UpsamplePhase
  else Result.Phase := FConfig.DownsamplePhase;
  Result.BitPerfect := IsBitPerfect;
  Result.Clipped := FWasClipped;
  Result.HeadroomOn := FConfig.AutoHeadroom;
  Result.HeadroomDB := -InterlockedCompareExchange(FVolatileHeadroom, 0, 0) / 1000.0;
end;

function TPlayThread.GetBitDepth: integer;
begin
  EnterCriticalSection(FLock);
  try
    if Assigned(FSource) then
      Result := FSource.GetBitsPerSample
    else
      Result := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPlayThread.GetChannels: integer;
begin
  EnterCriticalSection(FLock);
  try
    if Assigned(FSource) then
      Result := FSource.GetChannels
    else
      Result := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
