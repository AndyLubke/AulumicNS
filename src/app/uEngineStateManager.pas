unit uEngineStateManager;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - uEngineStateManager
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Centralized 'Thread Police' to ensure threads don't interfere with each other,
  and application-wide event bus decoupling external units from the main
  window (AuMainForm).
==============================================================================}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TAppEngineState = (
    esLibraryBusy,
    esReplayGainBusy,
    esTagEditorBusy,
    esBackgroundIOBusy
  );

  TAppEngineStates = set of TAppEngineState;

  TEngineStateChangeEvent = procedure(Sender: TObject; ActiveStates: TAppEngineStates) of object;

  // ---> MODIFIED: Added parameterless TAppSimpleEvent to match UpdateInfoBars,
  // JumpToNowPlaying, ClearThumbCache, and BackgroundIOBatchFinished!
  TAppSimpleEvent         = procedure of object;
  TAppStatusEvent         = procedure(const AMsg: string; ProgressPct: Double) of object;
  TAppBoolEvent           = procedure(AValue: Boolean) of object;
  TAppCountEvent          = procedure(ACurrent, ATotal: Integer) of object;
  TAppScanRequestEvent    = procedure(FullRebuild, SilentQueue: Boolean) of object;
  TAppBatchEvent          = procedure(ABatchList: TList) of object;

  { TEngineStateManager }

  TEngineStateManager = class
  private
    FCriticalSection             : TCriticalSection;
    FActiveStates                : TAppEngineStates;
    FBroadcastPending            : Boolean;
    FOnStateChanged              : TEngineStateChangeEvent;

    // Decoupled UI & App hooks bound by TfrmMain
    FDefaultCoverObject          : TObject;
    FIsAutoPlaylistActive        : Boolean;
    FOnStatusUpdate              : TAppStatusEvent;
    FOnReplayGainLabel           : TAppBoolEvent;
    FOnReplayGainProgress        : TAppCountEvent;
    FOnRequestLibraryScan        : TAppScanRequestEvent;
    // ---> MODIFIED: Changed from TNotifyEvent to TAppSimpleEvent
    FOnUpdateInfoBars            : TAppSimpleEvent;
    FOnJumpToNowPlaying          : TAppSimpleEvent;
    FOnClearThumbCache           : TAppSimpleEvent;
    FOnBackgroundIOBatchFinished : TAppSimpleEvent;
    FOnEnqueueMetadataBatch      : TAppBatchEvent;

    procedure SyncBroadcast;
    procedure BroadcastStateChange;
  public
    constructor Create;
    destructor Destroy; override;

    // Mutators
    procedure PushState(const AState: TAppEngineState);
    procedure PopState(const AState: TAppEngineState);

    // Gatekeeper Checks
    function IsIdle: Boolean;
    function HasState(const AState: TAppEngineState): Boolean;
    function GetBusyMessage: string;

    // Decoupled UI & Engine Dispatchers
    procedure ClearUIHooks;
    procedure UpdateStatusUI(const AMsg: string; ProgressPct: Double = -1);
    procedure ShowBackgroundIOStatus(const AMsg: string; ProgressPct: Double = -1);
    procedure ShowReplayGainLabel(AShow: Boolean);
    // ---> ADDED: Live 'album x of y' in the ReplayGain status label
    procedure ShowReplayGainProgress(ACurrent, ATotal: Integer);
    procedure RequestLibraryScan(FullRebuild: Boolean = False; SilentQueue: Boolean = False);
    procedure UpdateInfoBars;
    procedure JumpToNowPlaying;
    procedure ClearThumbCache;
    procedure BackgroundIOBatchFinished;
    procedure EnqueueMetadataBatch(ABatchList: TList);

    // Event Hook for the Main UI
    property OnStateChanged: TEngineStateChangeEvent read FOnStateChanged
                                                    write FOnStateChanged;

    // Properties & Event Hooks for Main UI Decoupling
    property DefaultCoverObject: TObject read FDefaultCoverObject
                                        write FDefaultCoverObject;
    property IsAutoPlaylistActive: Boolean read FIsAutoPlaylistActive
                                          write FIsAutoPlaylistActive;
    property OnStatusUpdate: TAppStatusEvent read FOnStatusUpdate
                                            write FOnStatusUpdate;
    property OnReplayGainLabel: TAppBoolEvent read FOnReplayGainLabel
                                             write FOnReplayGainLabel;
    property OnReplayGainProgress: TAppCountEvent read FOnReplayGainProgress
                                                  write FOnReplayGainProgress;
    property OnRequestLibraryScan: TAppScanRequestEvent read FOnRequestLibraryScan
                                                       write FOnRequestLibraryScan;
    // ---> MODIFIED: Changed from TNotifyEvent to TAppSimpleEvent
    property OnUpdateInfoBars: TAppSimpleEvent read FOnUpdateInfoBars
                                              write FOnUpdateInfoBars;
    property OnJumpToNowPlaying: TAppSimpleEvent read FOnJumpToNowPlaying
                                                write FOnJumpToNowPlaying;
    property OnClearThumbCache: TAppSimpleEvent read FOnClearThumbCache
                                               write FOnClearThumbCache;
    property OnBackgroundIOBatchFinished: TAppSimpleEvent read FOnBackgroundIOBatchFinished
                                                         write FOnBackgroundIOBatchFinished;
    property OnEnqueueMetadataBatch: TAppBatchEvent read FOnEnqueueMetadataBatch
                                                   write FOnEnqueueMetadataBatch;
  end;

var
  // The global Singleton accessible anywhere in the app
  AppStateManager: TEngineStateManager = nil;

implementation

uses
  uAppStrings;

const
  // ---> AUDIT FIX: Moved here from uAppStrings (texts stay in uAppStrings), so
  // uAppStrings no longer uses uEngineStateManager. The circular reference
  // between the two units made FPC 3.2.2 crash internally while compiling.
  BUSY_STATE_MESSAGE: array[TAppEngineState] of string = (
    BUSY_MSG_LIBRARY,       // esLibraryBusy
    BUSY_MSG_REPLAYGAIN,    // esReplayGainBusy
    BUSY_MSG_TAG_EDITOR,    // esTagEditorBusy
    BUSY_MSG_BACKGROUND_IO  // esBackgroundIOBusy
  );

{ TEngineStateManager }

constructor TEngineStateManager.Create;
begin
  inherited Create;
  FCriticalSection      := TCriticalSection.Create;
  FActiveStates         := [];
  FBroadcastPending     := False;
  FDefaultCoverObject   := nil;
  FIsAutoPlaylistActive := False;
end;

destructor TEngineStateManager.Destroy;
begin
  ClearUIHooks;
  // Flush any pending queued SyncBroadcast calls before freeing
  TThread.RemoveQueuedEvents(@SyncBroadcast);
  FCriticalSection.Free;
  inherited Destroy;
end;

procedure TEngineStateManager.ClearUIHooks;
begin
  if Self = nil then
    Exit;

  FOnStateChanged              := nil;
  FOnStatusUpdate              := nil;
  FOnReplayGainLabel           := nil;
  FOnReplayGainProgress        := nil;
  FOnRequestLibraryScan        := nil;
  FOnUpdateInfoBars            := nil;
  FOnJumpToNowPlaying          := nil;
  FOnClearThumbCache           := nil;
  FOnBackgroundIOBatchFinished := nil;
  FOnEnqueueMetadataBatch      := nil;
  FDefaultCoverObject          := nil;
end;

procedure TEngineStateManager.UpdateStatusUI(const AMsg: string; ProgressPct: Double);
begin
  if (Self <> nil) and Assigned(FOnStatusUpdate) then
    FOnStatusUpdate(AMsg, ProgressPct);
end;

procedure TEngineStateManager.ShowBackgroundIOStatus(const AMsg: string; ProgressPct: Double);
begin
  if (Self <> nil) and Assigned(FOnStatusUpdate) then
    FOnStatusUpdate(AMsg, ProgressPct);
end;

procedure TEngineStateManager.ShowReplayGainLabel(AShow: Boolean);
begin
  if (Self <> nil) and Assigned(FOnReplayGainLabel) then
    FOnReplayGainLabel(AShow);
end;

procedure TEngineStateManager.ShowReplayGainProgress(ACurrent, ATotal: Integer);
begin
  if (Self <> nil) and Assigned(FOnReplayGainProgress) then
    FOnReplayGainProgress(ACurrent, ATotal);
end;

procedure TEngineStateManager.RequestLibraryScan(FullRebuild: Boolean; SilentQueue: Boolean);
begin
  if (Self <> nil) and Assigned(FOnRequestLibraryScan) then
    FOnRequestLibraryScan(FullRebuild, SilentQueue);
end;

// ---> MODIFIED: Parameterless invocation
procedure TEngineStateManager.UpdateInfoBars;
begin
  if (Self <> nil) and Assigned(FOnUpdateInfoBars) then
    FOnUpdateInfoBars();
end;

// ---> MODIFIED: Parameterless invocation
procedure TEngineStateManager.JumpToNowPlaying;
begin
  if (Self <> nil) and Assigned(FOnJumpToNowPlaying) then
    FOnJumpToNowPlaying();
end;

// ---> MODIFIED: Parameterless invocation
procedure TEngineStateManager.ClearThumbCache;
begin
  if (Self <> nil) and Assigned(FOnClearThumbCache) then
    FOnClearThumbCache();
end;

// ---> MODIFIED: Parameterless invocation
procedure TEngineStateManager.BackgroundIOBatchFinished;
begin
  if (Self <> nil) and Assigned(FOnBackgroundIOBatchFinished) then
    FOnBackgroundIOBatchFinished();
end;

procedure TEngineStateManager.EnqueueMetadataBatch(ABatchList: TList);
begin
  if (Self <> nil) and Assigned(FOnEnqueueMetadataBatch) then
    FOnEnqueueMetadataBatch(ABatchList);
end;

procedure TEngineStateManager.SyncBroadcast;
var
  SafeStates: TAppEngineStates;
  Handler: TEngineStateChangeEvent;
begin
  if Self = nil then
    Exit;

  FCriticalSection.Enter;
  try
    SafeStates        := FActiveStates;
    FBroadcastPending := False;
    Handler           := FOnStateChanged;
  finally
    FCriticalSection.Leave;
  end;

  if Assigned(Handler) then
    Handler(Self, SafeStates);
end;

procedure TEngineStateManager.BroadcastStateChange;
begin
  if not FBroadcastPending then
  begin
    FBroadcastPending := True;
    TThread.Queue(nil, @SyncBroadcast);
  end;
end;

procedure TEngineStateManager.PushState(const AState: TAppEngineState);
begin
  if Self = nil then
    Exit;

  FCriticalSection.Enter;
  try
    if not (AState in FActiveStates) then
    begin
      Include(FActiveStates, AState);
      BroadcastStateChange;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TEngineStateManager.PopState(const AState: TAppEngineState);
begin
  if Self = nil then
    Exit;

  FCriticalSection.Enter;
  try
    if AState in FActiveStates then
    begin
      Exclude(FActiveStates, AState);
      BroadcastStateChange;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TEngineStateManager.IsIdle: Boolean;
begin
  if Self = nil then
    Exit(True);

  FCriticalSection.Enter;
  try
    Result := (FActiveStates = []);
  finally
    FCriticalSection.Leave;
  end;
end;

function TEngineStateManager.HasState(const AState: TAppEngineState): Boolean;
begin
  if Self = nil then
    Exit(False);

  FCriticalSection.Enter;
  try
    Result := (AState in FActiveStates);
  finally
    FCriticalSection.Leave;
  end;
end;

function TEngineStateManager.GetBusyMessage: string;
var
  State: TAppEngineState;
begin
  Result := '';
  if Self = nil then
    Exit;

  FCriticalSection.Enter;
  try
    for State in TAppEngineState do
    begin
      if State in FActiveStates then
      begin
        Result := BUSY_STATE_MESSAGE[State];
        Break;
      end;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

initialization
  AppStateManager := TEngineStateManager.Create;

end.
