unit uPlaybackManager;

{$mode ObjFPC}{$H+}

// =============================================================================
// AulumicNS - uPlaybackManager
// Copyright (C) 2026 André Lubke
// Licensed under the GNU General Public License, version 3 (see LICENSE).
//
// Acts as the bridge between the raw audio thread and the user interface.
// Manages high-level engine states, gapless track handoffs, seeking, and
// pause/resume logic.
// =============================================================================

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, ALAudioEngine, ALMetadata,
  ALReaders, uAppConsts, AuDialogs, uFileLockRegistry, uAudioUtils,
  ALAudioTypes, uPlaybackIOWorker, uDriveKeepAlive,
  ALSourceFactory;  // TPreparedNext

type
  TPlaybackState  = (psStopped, psPlaying, psPaused, psMaintenance);
  TRepeatMode     = (rmOff, rmAll, rmOne);
  TShuffleMode    = (smOff, smTrack, smAlbum);

  TManagerConfig = record
    ReplayGainMode          : Integer;
    PCMBufferMs             : Integer;
    DSDBufferMs             : Integer;
    UseDoP                  : Boolean;
    DisableResampleForDSD   : Boolean;
    ResamplePCM             : Boolean;
    ResampleQuality         : integer;
    DeviceID                : string;
    // 0 WASAPI (DeviceID = endpoint id), 1 ASIO (DeviceID =
    // driver CLSID); AsioNativeDsd: DSD as DSD over ASIO (else DoP)
    OutputApi               : Integer;
    AsioNativeDsd           : Boolean;
    TargetSampleRate44      : Integer;
    TargetSampleRate48      : Integer;
    VolumeLocked            : Boolean;
    PreampDB                : Double;  // e.g., 0.0, -2.0, -3.0
    EnableSoftClipping      : Boolean;
    // Automatic headroom (ALHeadroom): the level of an album
    // is lowered as far as its highest peak needs, no further
    AutoHeadroom            : Boolean;

    UpsamplePhase           : Integer; // (0=Linear, 1=Intermediate, 2=Minimum)
    DownsamplePhase         : Integer; // (0=Linear, 1=Intermediate, 2=Minimum)

    // Resampler filter properties
    ResampleBandWidthIndex  : Integer;
    ResampleAntiAliasIndex  : Integer;

    BypassThreshold         : Integer;
    DsdToPcmGain            : Integer;
    DsdLowPassFilter        : boolean;
    UseHighResTimer         : Boolean;
    OptimizeAffinity        : Boolean;
    EnableMMCSS             : Boolean;
    KeepDrivesAwake         : Boolean;  // see uDriveKeepAlive

    ToneDirect              : Boolean;
    ToneBassDB              : Integer; // -100 to +100 (represents -10.0dB to +10.0dB)
    ToneLowMidDB               : Integer;
    ToneMidDB               : Integer;
    ToneHighMidDB               : Integer;
    ToneTrebleDB            : Integer;
    ToneBassHz              : Integer; // e.g., 150
    ToneLowMidHz               : Integer;
    ToneMidHz               : Integer; // e.g., 220
    ToneHighMidHz               : Integer;
    ToneTrebleHz            : Integer; // e.g., 8000
  end;

  PQueueItem = ^TQueueItem;
  TQueueItem = record
    FilePath  : string;
    Album     : string;
    TrackId   : Integer;
    SourceID  : string;
  end;

  TTrackChangeEvent     = procedure(const Item: TQueueItem;
                            const Meta: TAudioMetadata) of object;
  TStateChangeEvent     = procedure(NewState: TPlaybackState) of object;
  TModeChangeEvent      = procedure(RepeatMode: TRepeatMode;
                            ShuffleMode: TShuffleMode) of object;
  // AIsDSD = the failed track is a DSD file. Taken from the
  // queue before the stop: the owner's own "current track" state is cleared
  // by the stop (or may still be the previous track's when the error comes
  // before the new track's info).
  TSampleRateErrorEvent = procedure(AttemptedRate: Integer; AIsDSD: Boolean) of object;

  // The dialog ShowEngineErrorAsync opens (see Update)
  TEngineErrorDialog = (eedMessage, eedSampleRate);

  { TPlaybackManager }

  TPlaybackManager = class
  private
    FAudioEngine     : TAudioEngine;
    FNotifyHandle    : THandle;

    // Background disk access (see uPlaybackIOWorker). Results
    // are collected on the UI thread in Update (ProcessIOResults).
    FIOWorker          : TPlaybackIOWorker;
    FOpenGeneration    : Integer;   // Current "open track" request
    FOpenPending       : Boolean;   // A track is being opened in the background
    FOpenFilePath      : string;    // the file of that open request
    FGaplessGeneration : Integer;   // Current gapless probe request
    FProbePath         : string;    // Next track being probed
    FProbeTrackId      : Integer;
    // The started track's tags / cover are read on the I/O worker
    FMetaGeneration    : Integer;   // Current track-info request
    FMetaPending       : Boolean;   // Waiting for the started track's info
    FMetaIsRefresh     : Boolean;   // that request is a RefreshTrackInfo
    FProbeDeferred     : Boolean;   // A gapless probe result arrived before it

    // Keeps the drives of the current and next track awake
    // (Config.KeepDrivesAwake). Created on first use; targets are updated
    // from Update on the UI timer (UpdateKeepAlive).
    FKeepAlive         : TDriveKeepAlive;
    FKeepAliveCurrent  : string;    // last targets handed to FKeepAlive
    FKeepAliveNext     : string;
    FPauseStartTick    : QWord;     // 0 = not paused
    FKeepAliveLost     : string;    // drive logged as "cannot be reached"
    FKeepAliveFailed   : Boolean;   // the thread could not be created: no retry
    FGaplessLogKey     : string;    // current|next of the last "not gapless" line

    // An engine error dialog waiting for ShowEngineErrorAsync
    FPendingErrMsg     : string;
    FPendingFailRate   : Integer;
    FPendingFailIsDSD  : Boolean;   // the failed track is a DSD file

    // The "Two-List" Memory System
    FOriginalQueue   : TList;
    FPlayQueue       : TList;
    FQueueRevision   : Integer;

    FCurrentIndex        : Integer;
    // Guards the single retry in UpdateGapless when the engine
    // rejects a stale "next" track because a swap happened in between.
    FInGaplessRetry      : Boolean;
    // Tracks both the file path and unique TrackId
    // preloaded into FNextSource so gapless swaps and custodian checks are exact!
    FQueuedNextFilePath  : string;
    FQueuedNextTrackId   : Integer;
    FState               : TPlaybackState;
    FOrigState           : TPlaybackState;
    FMaintenanceProgress : Double;

    FCurrentMeta     : TAudioMetadata;

    FRepeatMode      : TRepeatMode;
    FShuffleMode     : TShuffleMode;

    FOnTrackChange     : TTrackChangeEvent;
    FOnTrackInfoRefreshed : TTrackChangeEvent;  // RefreshTrackInfo's result
    FOnStateChange     : TStateChangeEvent;
    FOnModeChange      : TModeChangeEvent;
    FOnSampleRateError : TSampleRateErrorEvent;
    FOnBackgroundRequest : TNotifyEvent;  // a request went to the I/O worker

    FConfig          : TManagerConfig;

    procedure PrepareEngineForTrack(const AFilePath: string);
    procedure AttemptPlayCurrent;
    // Second halves of the background requests (UI thread)
    procedure ProcessIOResults;
    procedure ContinuePlayCurrent(const AFilePath: string; AFound: Boolean);
    function  ResolveGaplessNext(out ANextItem: PQueueItem): Boolean;
    procedure ApplyGaplessProbe(const AFilePath: string; AFound: Boolean; ASampleRate: Integer;
      var APrep: TPreparedNext);
    procedure CancelBackgroundIO;
    procedure UpdateKeepAlive;
    procedure ShowEngineErrorAsync(Data: PtrInt);

    procedure SetState(const Value: TPlaybackState);
    procedure TriggerTrackChange;
    procedure ApplyTrackInfo(const AFilePath: string; AFound: Boolean;
      const AMeta: TAudioMetadata);
    procedure RebuildPlayQueue(const ActiveID: integer = 0);
    procedure SetNotifyHandle(Value: THandle);
    procedure ChangeRevision;

  public
    constructor Create;
    destructor Destroy; override;

    procedure ClearQueue;
    procedure AddToQueue(const AFilePath, AAlbum: string; ATrackId: Integer; const ASourceID: string);
    procedure StartQueue(StartIndex: Integer = 0);
    // AKeepCurrent: when the playing track is not among the new items it stays
    // in the queue at its old place and plays on (a tag edit took it out of an
    // auto-playlist); without it the playback stops (the user removed it)
    procedure SyncQueue(NewQueueItems: TList; AKeepCurrent: Boolean = False);
    // A playlist was renamed: queue items from it get the new name
    procedure RenameQueueSource(const AOldSourceID, ANewSourceID: string);
    // For the tests: the queue as if the track at AIndex were playing and
    // paused, without opening it (no device, no file)
    procedure AssumePaused(AIndex: Integer);

    procedure PlayNext(ForceUserClick: Boolean = False);
    procedure PlayPrev;
    procedure Pause;
    procedure Resume;
    procedure Stop;
    procedure Seek(Percent: Double);

    procedure SetVolume(Vol: Integer);

    procedure ToggleRepeat;
    procedure ToggleShuffle;

    function  GetProgress: Double;
    function  GetDuration: Double;
    procedure GetQueueSnapshot(Dest: TStrings; out CurrentIdx: Integer);
    function  QueueCount: Integer;
    function  GetCurrentItem: PQueueItem;
    procedure Update;
    procedure UpdateGapless;
    // Helpers for custodian and pre-Update swap handling
    procedure ClearGaplessPreload;
    function  ConsumePendingTrackSwap: Boolean;
    procedure RestartCurrent;
    procedure EnterMaintenance;
    procedure ExitMaintenance;
    procedure RetryCurrent;
    // Reads the current track's tags, cover and folder info again
    // on the I/O worker (after a library change: tags edited, a scan, a
    // ReplayGain save) and reports them with OnTrackInfoRefreshed. Unlike a
    // track change nothing else happens (no play is counted). Nothing to do
    // while a track change's info is still on its way (it is read anew).
    procedure RefreshTrackInfo;
    procedure SetToneControl(const State: TToneState);

    function  GetEngineStats: TAudioStats;
    // The stages of the signal path (the badge popup)
    function  GetSignalInfo: TSignalInfo;
    // True while a track open or track-info request is outstanding
    function  HasPendingIO: Boolean;
    // A track is being opened (existence check on the I/O worker)
    property  IsOpening: Boolean read FOpenPending;
    property  OpeningFilePath: string read FOpenFilePath;
    class procedure EnumerateDevices(List: TStrings; out DefaultIdx: Integer);
    class function GetDeviceFriendlyName(const DeviceId: string): string;

    property Config: TManagerConfig read FConfig write FConfig;
    property Engine: TAudioEngine read FAudioEngine;
    property State: TPlaybackState read FState;
    property CurrentIndex: Integer read FCurrentIndex;
    property QueuedNextFilePath: string read FQueuedNextFilePath;
    property RepeatMode: TRepeatMode read FRepeatMode;
    property ShuffleMode: TShuffleMode read FShuffleMode;
    property NotifyHandle: THandle read FNotifyHandle write SetNotifyHandle;
    property QueueRevision: integer read FQueueRevision;

    property OnTrackChange     : TTrackChangeEvent read FOnTrackChange
                                 write FOnTrackChange;
    // The result of RefreshTrackInfo (UI thread)
    property OnTrackInfoRefreshed : TTrackChangeEvent read FOnTrackInfoRefreshed
                                    write FOnTrackInfoRefreshed;
    property OnStateChange     : TStateChangeEvent read FOnStateChange
                                 write FOnStateChange;
    property OnModeChange      : TModeChangeEvent read FOnModeChange
                                 write FOnModeChange;
    property OnSampleRateError : TSampleRateErrorEvent read FOnSampleRateError
                                 write FOnSampleRateError;
    // Fired on the UI thread right after a request is handed to the
    // I/O worker, so the owner can collect the result without delay
    property OnBackgroundRequest : TNotifyEvent read FOnBackgroundRequest
                                   write FOnBackgroundRequest;
  end;

// The buffer of a DSD track: DSDBufferMs when the DSD goes to
// the DAC as DSD ("Play DSD natively": DoP over WASAPI, native or DoP over
// ASIO), PCMBufferMs when it is converted to PCM
function DsdBufferFor(const AConfig: TManagerConfig): Integer;

implementation

uses AuLog, Math, uAppStrings, uOSUtils;

function DsdBufferFor(const AConfig: TManagerConfig): Integer;
begin
  if AConfig.UseDoP then
    Result := AConfig.DSDBufferMs
  else
    Result := AConfig.PCMBufferMs;
end;

constructor TPlaybackManager.Create;
begin
  inherited Create;
  FAudioEngine        := TAudioEngine.Create;
  FOriginalQueue      := TList.Create;
  FPlayQueue          := TList.Create;
  FCurrentIndex       := -1;
  FInGaplessRetry     := False;
  FIOWorker           := TPlaybackIOWorker.Create;
  FOpenGeneration     := 0;
  FOpenPending        := False;
  FMetaGeneration     := 0;
  FMetaPending        := False;
  FProbeDeferred      := False;
  FKeepAlive          := nil;
  FKeepAliveCurrent   := '';
  FKeepAliveNext      := '';
  FPauseStartTick     := 0;
  FKeepAliveLost      := '';
  FKeepAliveFailed    := False;
  FGaplessLogKey      := '';
  FGaplessGeneration  := 0;
  FProbePath          := '';
  FProbeTrackId       := 0;
  FQueuedNextFilePath := '';
  FQueuedNextTrackId  := 0;
  FState              := psStopped;
  FRepeatMode         := rmOff;
  FShuffleMode        := smOff;
  Randomize;
end;

destructor TPlaybackManager.Destroy;
begin
  // An engine error dialog that has not opened yet
  if Assigned(Application) then
    Application.RemoveAsyncCalls(Self);

  Stop;
  ClearQueue;

  // Stop the keep-alive thread. A read can be stuck on a sleeping
  // or unreachable drive.
  // Its read is aborted first where Windows can (a network
  // share), so it usually ends at once. If it is still blocked after 3 s, it
  // is set aside (uDriveKeepAlive.SetThreadAside): freed once it has ended or
  // left to Windows at exit. It never frees itself: that could happen
  // while the program is already being taken down.
  if Assigned(FKeepAlive) then
  begin
    FKeepAlive.Terminate;
    CancelThreadFileAccess(FKeepAlive);
    if FKeepAlive.Shutdown(3000) then
      FreeAndNil(FKeepAlive)
    else
    begin
      SetThreadAside(FKeepAlive);
      FKeepAlive := nil;
    end;
  end;

  // Stop the I/O worker. It may be blocked in the file system
  // (opening a track on a sleeping drive, an unreachable network share).
  // As the keep-alive thread above: its file access is aborted
  // first where possible (terminated before, so its retry loop ends), after
  // 3 s it is set aside (it never frees itself); it may still be building
  // the next track then.
  if Assigned(FIOWorker) then
  begin
    FIOWorker.Terminate;
    CancelThreadFileAccess(FIOWorker);
    if FIOWorker.Shutdown(3000) then
      FreeAndNil(FIOWorker)
    else
    begin
      SetThreadAside(FIOWorker);
      FIOWorker := nil;
    end;
  end;

  FOriginalQueue.Free;
  FPlayQueue.Free;
  FAudioEngine.Free;
  inherited Destroy;
end;

procedure TPlaybackManager.SetState(const Value: TPlaybackState);
begin
  if FState <> Value then
  begin
    FState := Value;
    if Assigned(FOnStateChange) then
      FOnStateChange(FState);
  end;
end;

function TPlaybackManager.QueueCount: Integer;
begin
  Result := FOriginalQueue.Count;
end;

function TPlaybackManager.GetCurrentItem: PQueueItem;
begin
  if (FCurrentIndex >= 0) and (FCurrentIndex < FPlayQueue.Count) then
    Result := PQueueItem(FPlayQueue[FCurrentIndex])
  else
    Result := nil;
end;

procedure TPlaybackManager.ClearQueue;
var
  I: Integer;
begin
  for I := 0 to FOriginalQueue.Count - 1 do
    if Assigned(FOriginalQueue[I]) then
      Dispose(PQueueItem(FOriginalQueue[I]));

  FOriginalQueue.Clear;
  FPlayQueue.Clear;
  FCurrentIndex       := -1;
  FQueuedNextFilePath := '';
  FQueuedNextTrackId  := 0;
  ChangeRevision;
end;

procedure TPlaybackManager.AddToQueue(const AFilePath, AAlbum: string;
  ATrackId: Integer; const ASourceID: string);
var
  NewItem: PQueueItem;
begin
  NewItem           := New(PQueueItem);
  NewItem^.FilePath := AFilePath;
  NewItem^.Album    := AAlbum;
  NewItem^.TrackId  := ATrackId;
  NewItem^.SourceID := ASourceID;
  FOriginalQueue.Add(NewItem);
end;

procedure TPlaybackManager.RebuildPlayQueue(const ActiveID: integer);
var
  I, J, SwapIdx, ActiveBlockIdx: Integer;
  TempItem: Pointer;
  Item: PQueueItem;
  AlbumBlocks: TList;
  CurrentBlock: TList;
  CurrentAlbum: string;
begin
  FPlayQueue.Clear;

  // 1. STANDARD LINEAR PLAYBACK
  if FShuffleMode = smOff then
  begin
    for I := 0 to FOriginalQueue.Count - 1 do
      FPlayQueue.Add(FOriginalQueue[I]);
  end

  // 2. TRACK SHUFFLE (Fisher-Yates with ActiveID pinned to Index 0)
  else if FShuffleMode = smTrack then
  begin
    for I := 0 to FOriginalQueue.Count - 1 do
      FPlayQueue.Add(FOriginalQueue[I]);

    for I := FPlayQueue.Count - 1 downto 1 do
    begin
      SwapIdx             := Random(I + 1);
      TempItem            := FPlayQueue[I];
      FPlayQueue[I]       := FPlayQueue[SwapIdx];
      FPlayQueue[SwapIdx] := TempItem;
    end;

    // Pin the currently active track to Index 0 so the whole queue plays after it!
    if ActiveID > 0 then
    begin
      for I := 1 to FPlayQueue.Count - 1 do
      begin
        if PQueueItem(FPlayQueue[I])^.TrackId = ActiveID then
        begin
          TempItem      := FPlayQueue[0];
          FPlayQueue[0] := FPlayQueue[I];
          FPlayQueue[I] := TempItem;
          Break;
        end;
      end;
    end;
  end

  // 3. ALBUM SHUFFLE (Fisher-Yates on Album Blocks with Active Album pinned to Block 0)
  else if FShuffleMode = smAlbum then
  begin
    AlbumBlocks := TList.Create;
    try
      CurrentBlock := nil;
      CurrentAlbum := #1;

      for I := 0 to FOriginalQueue.Count - 1 do
      begin
        Item := PQueueItem(FOriginalQueue[I]);
        if (Item^.Album <> CurrentAlbum) or (CurrentBlock = nil) then
        begin
          CurrentBlock := TList.Create;
          AlbumBlocks.Add(CurrentBlock);
          CurrentAlbum := Item^.Album;
        end;
        CurrentBlock.Add(Item);
      end;

      for I := AlbumBlocks.Count - 1 downto 1 do
      begin
        SwapIdx              := Random(I + 1);
        TempItem             := AlbumBlocks[I];
        AlbumBlocks[I]       := AlbumBlocks[SwapIdx];
        AlbumBlocks[SwapIdx] := TempItem;
      end;

      // Pin the album block containing ActiveID to Block 0!
      if ActiveID > 0 then
      begin
        ActiveBlockIdx := -1;
        for I := 1 to AlbumBlocks.Count - 1 do
        begin
          CurrentBlock := TList(AlbumBlocks[I]);
          for J := 0 to CurrentBlock.Count - 1 do
          begin
            if PQueueItem(CurrentBlock[J])^.TrackId = ActiveID then
            begin
              ActiveBlockIdx := I;
              Break;
            end;
          end;
          if ActiveBlockIdx >= 0 then
            Break;
        end;

        if ActiveBlockIdx > 0 then
        begin
          TempItem                    := AlbumBlocks[0];
          AlbumBlocks[0]              := AlbumBlocks[ActiveBlockIdx];
          AlbumBlocks[ActiveBlockIdx] := TempItem;
        end;
      end;

      for I := 0 to AlbumBlocks.Count - 1 do
      begin
        CurrentBlock := TList(AlbumBlocks[I]);
        for SwapIdx := 0 to CurrentBlock.Count - 1 do
          FPlayQueue.Add(CurrentBlock[SwapIdx]);
        CurrentBlock.Free;
      end;
    finally
      AlbumBlocks.Free;
    end;
  end;

  ChangeRevision;

  if FPlayQueue.Count = 0 then
  begin
    FCurrentIndex := -1;
    Exit;
  end;

  FCurrentIndex := 0;

  if ActiveID > 0 then
  begin
    for I := 0 to FPlayQueue.Count - 1 do
    begin
      if PQueueItem(FPlayQueue[I])^.TrackId = ActiveID then
      begin
        FCurrentIndex := I;
        Break;
      end;
    end;
  end;
end;

procedure TPlaybackManager.SetNotifyHandle(Value: THandle);
begin
  FNotifyHandle := Value;

  if Assigned(FAudioEngine) then
    FAudioEngine.NotifyHandle := Value;

end;

procedure TPlaybackManager.ChangeRevision;
begin
  if FQueueRevision = MaxInt - 10 then
    FQueueRevision := 0
  else
    Inc(FQueueRevision);
end;

procedure TPlaybackManager.StartQueue(StartIndex: Integer);
var
  ActiveID: Integer;
begin
  if (StartIndex < 0) or (StartIndex >= FOriginalQueue.Count) then
    Exit;

  ActiveID := PQueueItem(FOriginalQueue[StartIndex])^.TrackId;
  RebuildPlayQueue(ActiveID);

  AttemptPlayCurrent;
end;

procedure TPlaybackManager.RenameQueueSource(const AOldSourceID, ANewSourceID: string);
var
  I: Integer;
begin
  if (AOldSourceID = '') or (ANewSourceID = '') then
    Exit;
  // FPlayQueue holds the same item pointers as FOriginalQueue
  for I := 0 to FOriginalQueue.Count - 1 do
    if Assigned(FOriginalQueue[I]) and
       SameText(PQueueItem(FOriginalQueue[I])^.SourceID, AOldSourceID) then
      PQueueItem(FOriginalQueue[I])^.SourceID := ANewSourceID;
end;

procedure TPlaybackManager.AssumePaused(AIndex: Integer);
begin
  if FPlayQueue.Count <> FOriginalQueue.Count then
    RebuildPlayQueue;
  if (AIndex < 0) or (AIndex >= FPlayQueue.Count) then
    Exit;
  FCurrentIndex := AIndex;
  FState        := psPaused;
end;

procedure TPlaybackManager.SyncQueue(NewQueueItems: TList; AKeepCurrent: Boolean = False);
var
  I, TargetID, OldPlace: Integer;
  Found: Boolean;
  Kept: PQueueItem;
  TargetFilePath: string;
  TrackStillExists: Boolean;
  OldState: TPlaybackState;
begin
  // Process any pending track swap against the current queue
  // BEFORE rebuilding the queue!
  if FState <> psStopped then
    ConsumePendingTrackSwap;

  TargetID       := 0;
  TargetFilePath := '';
  OldState       := FState;

  // 1. Capture the exact ID and Path we are currently playing
  if (FCurrentIndex >= 0) and (FCurrentIndex < FPlayQueue.Count) then
  begin
    TargetID       := PQueueItem(FPlayQueue[FCurrentIndex])^.TrackId;
    TargetFilePath := PQueueItem(FPlayQueue[FCurrentIndex])^.FilePath;
  end;

  // The playing track is not in the new list and is to play
  // on: a copy of its item goes into the new list where the track was
  if AKeepCurrent and (FState <> psStopped) and Assigned(NewQueueItems) and
     (FCurrentIndex >= 0) and (FCurrentIndex < FPlayQueue.Count) then
  begin
    Found := False;
    for I := 0 to NewQueueItems.Count - 1 do
      if Assigned(NewQueueItems[I]) and
         ((PQueueItem(NewQueueItems[I])^.TrackId = TargetID) or
          SameText(PQueueItem(NewQueueItems[I])^.FilePath, TargetFilePath)) then
      begin
        Found := True;
        Break;
      end;
    if not Found then
    begin
      OldPlace := FOriginalQueue.IndexOf(FPlayQueue[FCurrentIndex]);
      if (OldPlace < 0) or (OldPlace > NewQueueItems.Count) then
        OldPlace := NewQueueItems.Count;
      New(Kept);
      Kept^ := PQueueItem(FPlayQueue[FCurrentIndex])^;
      NewQueueItems.Insert(OldPlace, Kept);
    end;
  end;

  if FState = psPlaying then
    FState := psPaused;

  // Only dispose old items that are NOT present in NewQueueItems
  for I := 0 to FOriginalQueue.Count - 1 do
  begin
    if Assigned(FOriginalQueue[I]) and
       ((not Assigned(NewQueueItems)) or (NewQueueItems.IndexOf(FOriginalQueue[I]) < 0)) then
      Dispose(PQueueItem(FOriginalQueue[I]));
  end;
  FOriginalQueue.Clear;
  FPlayQueue.Clear;
  FCurrentIndex := -1;
  ChangeRevision;

  // Prevent duplicate PQueueItem pointers in FOriginalQueue
  if Assigned(NewQueueItems) then
  begin
    for I := 0 to NewQueueItems.Count - 1 do
      if Assigned(NewQueueItems[I]) and (FOriginalQueue.IndexOf(NewQueueItems[I]) < 0) then
        FOriginalQueue.Add(NewQueueItems[I]);
  end;

  // 2. Try to restore by the exact ID (Handles normal Drag & Drop perfectly)
  RebuildPlayQueue(TargetID);

  if OldState <> psStopped then
  begin
    TrackStillExists := False;
    if (FCurrentIndex >= 0) and (FCurrentIndex < FPlayQueue.Count) then
      TrackStillExists := (PQueueItem(FPlayQueue[FCurrentIndex])^.TrackId = TargetID);

    // If the ID vanished, search the ENTIRE queue for the file path
    if (not TrackStillExists) and (TargetFilePath <> '') then
    begin
      for I := 0 to FPlayQueue.Count - 1 do
      begin
        if SameText(PQueueItem(FPlayQueue[I])^.FilePath, TargetFilePath) then
        begin
          FCurrentIndex    := I;
          TrackStillExists := True;
          Break;
        end;
      end;
    end;

    if not TrackStillExists then
    begin
      // The track was genuinely deleted from the playlist
      Stop;
    end
    else
    begin
      // The track survived! Update gapless and beam the NEW ID back to the UI
      FState := OldState;
      UpdateGapless;
    end;
  end
  else
  begin
    FCurrentIndex := -1;
  end;
end;

procedure TPlaybackManager.ToggleShuffle;
var
  TargetID: Integer;
begin
  // Process any pending track swap BEFORE reshuffling!
  if FState <> psStopped then
    ConsumePendingTrackSwap;

  case FShuffleMode of
    smOff:   FShuffleMode := smTrack;
    smTrack: FShuffleMode := smAlbum;
    smAlbum: FShuffleMode := smOff;
  end;

  TargetID := 0;
  if Assigned(GetCurrentItem) then
    TargetID := GetCurrentItem^.TrackId;

  RebuildPlayQueue(TargetID);
  if FState = psStopped then
    FCurrentIndex := -1
  else
    UpdateGapless;

  if Assigned(FOnModeChange) then
    FOnModeChange(FRepeatMode, FShuffleMode);
end;

// First half of starting a track (UI thread). The existence
// check with its retries (and the 50 ms DAC release pause) runs on the I/O
// worker, so a sleeping drive does not freeze the window. ContinuePlayCurrent
// finishes the start once the worker reports back (via Update, <= 50 ms later).
procedure TPlaybackManager.AttemptPlayCurrent;
var
  Item: PQueueItem;
  WasEngineActive: Boolean;
begin
  Item := GetCurrentItem;

  // The same track is still being opened (an impatient second
  // double-click / Enter / Play): let that open finish instead of starting
  // over. ContinuePlayCurrent compares by path, so a rebuilt queue is fine.
  if FOpenPending and Assigned(Item) and SameText(Item^.FilePath, FOpenFilePath) then
    Exit;

  CancelBackgroundIO;

  if not Assigned(Item) then
  begin
    Stop;
    Exit;
  end;

  // =========================================================================
  // THE COLLISION SHIELD:
  // Reject playback immediately if the background daemon is rewriting this file!
  // =========================================================================
  if Assigned(FileLockRegistry) and FileLockRegistry.IsFileBusy(Item^.FilePath) then
  begin
    Stop;
    Screen.Cursor := crDefault;
    AddLog(SafeFormat(FMT_LOG_FILE_BUSY, [Item^.FilePath]), False, True);
    ALMessageDlg(TITLE_FILE_BUSY, MSG_FILE_BUSY, [mbOK], mbOK, mkWarning);
    Exit;
  end;

  WasEngineActive     := FAudioEngine.IsPlaying;
  FState              := psStopped;
  FQueuedNextFilePath := '';
  FQueuedNextTrackId  := 0;
  FAudioEngine.Stop;

  // 1. THE 3-STRIKE RETRY LOOP runs on the worker (with the 50 ms pause first
  //    if the hardware DAC lock was actually active)
  Inc(FOpenGeneration);
  FOpenPending  := True;
  FOpenFilePath := Item^.FilePath;
  if WasEngineActive then
    FIOWorker.RequestOpen(FOpenGeneration, Item^.FilePath, 50)
  else
    FIOWorker.RequestOpen(FOpenGeneration, Item^.FilePath, 0);

  if Assigned(FOnBackgroundRequest) then
    FOnBackgroundRequest(Self);
end;

// Second half of starting a track (UI thread)
procedure TPlaybackManager.ContinuePlayCurrent(const AFilePath: string; AFound: Boolean);
var
  Item: PQueueItem;
begin
  FOpenPending := False;

  Item := GetCurrentItem;
  if not Assigned(Item) then
  begin
    Stop;
    Exit;
  end;

  // The queue changed while the file was being checked: open the track that
  // is current now instead
  if not SameText(Item^.FilePath, AFilePath) then
  begin
    AttemptPlayCurrent;
    Exit;
  end;

  // 2. PROACTIVE FILE CHECK (Graceful Exit if the drive is completely dead)
  if not AFound then
  begin
    Stop;
    Screen.Cursor := crDefault;
    AddLog(SafeFormat(FMT_LOG_FILE_NOT_FOUND, [Item^.FilePath]), False, True);
    ALMessageDlg(TITLE_PLAYBACK_ERROR, SafeFormat(FMT_MSG_FILE_NOT_FOUND, [Item^.FilePath]), [mbOK], mbOK, mkError);
    Exit;
  end;

  // The tagger may have started on this file while it was being checked
  if Assigned(FileLockRegistry) and FileLockRegistry.IsFileBusy(Item^.FilePath) then
  begin
    Stop;
    Screen.Cursor := crDefault;
    AddLog(SafeFormat(FMT_LOG_FILE_BUSY, [Item^.FilePath]), False, True);
    ALMessageDlg(TITLE_FILE_BUSY, MSG_FILE_BUSY, [mbOK], mbOK, mkWarning);
    Exit;
  end;

  // 3. SAFE ENGINE STARTUP
  PrepareEngineForTrack(Item^.FilePath);
  try
    FAudioEngine.Play(Item^.FilePath, FConfig.DeviceID);
    SetState(psPlaying);

    TriggerTrackChange;
    UpdateGapless;
  except
    on E: Exception do
    begin
      Stop;
      AddLog(SafeFormat(FMT_LOG_PLAY_FAILED, [Item^.FilePath, E.Message]), False, True);
    end;
    else
    begin
      Stop;
      AddLog(SafeFormat(FMT_LOG_PLAY_FAILED, [Item^.FilePath, LOG_REASON_UNKNOWN]), False, True);
    end;
  end;
end;

// Invalidates every outstanding background request
procedure TPlaybackManager.CancelBackgroundIO;
begin
  Inc(FOpenGeneration);
  Inc(FGaplessGeneration);
  Inc(FMetaGeneration);
  FMetaPending   := False;
  FProbeDeferred := False;
  FOpenPending  := False;
  FProbePath    := '';
  FProbeTrackId := 0;
  if Assigned(FIOWorker) then
    FIOWorker.CancelAll;
end;

// Collects finished background requests (UI thread, called
// from Update). Results of an outdated generation are ignored.
procedure TPlaybackManager.ProcessIOResults;
var
  Results: TPlaybackIOResults;
  I: Integer;
begin
  if (not Assigned(FIOWorker)) or (not FIOWorker.FetchResults(Results)) then
    Exit;

  try
    for I := 0 to High(Results) do
    begin
      case Results[I].Kind of
        iojOpen:
          if FOpenPending and (Results[I].Generation = FOpenGeneration) then
            ContinuePlayCurrent(Results[I].FilePath, Results[I].Found);

        iojProbe:
          if (Results[I].Generation = FGaplessGeneration) and
             ((FState = psPlaying) or (FState = psPaused)) then
          begin
            // The probe compares with the current track's sample
            // rate, which is only known once its info has arrived
            if FMetaPending then
              FProbeDeferred := True
            else
              ApplyGaplessProbe(Results[I].FilePath, Results[I].Found,
                Results[I].SampleRate, Results[I].Prepared);
          end;

        iojMeta:
          if FMetaPending and (Results[I].Generation = FMetaGeneration) then
            ApplyTrackInfo(Results[I].FilePath, Results[I].Found, Results[I].Meta);
      end;
    end;
  finally
    // Prepared next-track sources that were not handed to the
    // engine (outdated, deferred, not gapless, ...)
    for I := 0 to High(Results) do
      FreePreparedNext(Results[I].Prepared);
  end;
end;

procedure TPlaybackManager.PlayNext(ForceUserClick: Boolean = False);
begin
  if FPlayQueue.Count = 0 then
  begin
    Stop;
    Exit;
  end;

  if (FRepeatMode = rmOne) and (not ForceUserClick) then
  begin
    AttemptPlayCurrent;
    Exit;
  end;

  if FCurrentIndex + 1 < FPlayQueue.Count then
  begin
    FCurrentIndex := FCurrentIndex + 1;
    AttemptPlayCurrent;
  end
  else if FRepeatMode = rmAll then
  begin
    // INFINITE SHUFFLE: Re-roll the random queue for the next loop
    if FShuffleMode <> smOff then
      RebuildPlayQueue(0);

    FCurrentIndex := 0;
    AttemptPlayCurrent;
  end
  else
    Stop;
end;

procedure TPlaybackManager.PlayPrev;
begin
  if FPlayQueue.Count = 0 then
  begin
    Stop;
    Exit;
  end;

  if (GetProgress * GetDuration) > 3.0 then
    AttemptPlayCurrent
  else if FCurrentIndex - 1 >= 0 then
  begin
    FCurrentIndex := FCurrentIndex - 1;
    AttemptPlayCurrent;
  end
  else if FRepeatMode = rmAll then
  begin
    FCurrentIndex := FPlayQueue.Count - 1;
    AttemptPlayCurrent;
  end
  else
  begin
    FCurrentIndex := 0;
    AttemptPlayCurrent;
  end;
end;

procedure TPlaybackManager.RestartCurrent;
var
  Prog: Double;
  WasPaused: Boolean;
  Item: PQueueItem;
begin
  if (FState = psPlaying) or (FState = psPaused) then
  begin
    ConsumePendingTrackSwap;
    Prog      := GetProgress;
    WasPaused := (FState = psPaused);
    Item      := GetCurrentItem;

    if Assigned(Item) then
    begin
      // Direct assignment bypasses the OnStateChange broadcast
      FState              := psStopped;
      FQueuedNextFilePath := '';
      FQueuedNextTrackId  := 0;
      FAudioEngine.Stop;

      // Only check that the drive is there (no disk access, so a drive
      // that fell asleep during a long pause does not freeze the UI). The
      // audio thread opens the file; a deleted file is reported by it.
      if not IsDrivePresent(Item^.FilePath) then
      begin
        Stop;
        Exit;
      end;

      PrepareEngineForTrack(Item^.FilePath);
      try
        FAudioEngine.Play(Item^.FilePath, FConfig.DeviceID);

        if WasPaused then
        begin
          FAudioEngine.Pause;
          FState := psPaused;
        end
        else
        begin
          FState := psPlaying;
        end;

        if Prog > 0.0 then
          FAudioEngine.Seek(Prog);

        UpdateGapless;
      except
        on E: Exception do
        begin
          Stop;
          AddLog(SafeFormat(FMT_LOG_DEVICE_SETTINGS_FAILED, [E.Message]), False, True);
          ALMessageDlg(TITLE_AUDIO_DEVICE_ERROR, SafeFormat(FMT_MSG_DEVICE_SETTINGS_FAILED, [E.Message]), [mbOK], mbOK, mkError);
        end;
        else
        begin
          Stop;
          AddLog(SafeFormat(FMT_LOG_DEVICE_SETTINGS_FAILED, [LOG_REASON_UNKNOWN]), False, True);
          ALMessageDlg(TITLE_AUDIO_DEVICE_ERROR, MSG_DEVICE_SETTINGS_FAILED, [mbOK], mbOK, mkError);
        end;
      end;
    end;
  end;
end;

procedure TPlaybackManager.EnterMaintenance;
begin
  // A track that is still being opened in the background is
  // cancelled and restarted from the beginning by ExitMaintenance
  if FOpenPending and (FState = psStopped) then
  begin
    CancelBackgroundIO;
    FOrigState           := psPlaying;
    FMaintenanceProgress := 0.0;
    FState               := psMaintenance;
    Exit;
  end;

  if (FState = psPlaying) or (FState = psPaused) then
  begin
    ConsumePendingTrackSwap;
    FOrigState           := FState;
    FMaintenanceProgress := GetProgress;
    FQueuedNextFilePath  := '';
    FQueuedNextTrackId   := 0;

    FAudioEngine.Stop;
    FState := psMaintenance;
  end;
end;

procedure TPlaybackManager.ExitMaintenance;
var
  Item: PQueueItem;
begin
  if FState <> psMaintenance then
    Exit;

  Item := GetCurrentItem;
  // Only checks that the drive is there, as PlayCurrent does (no
  // disk access: after a long pause the drive may be asleep, and FileExists
  // would freeze the window until it woke). The audio thread opens the file and
  // reports a file that is gone.
  if Assigned(Item) and IsDrivePresent(Item^.FilePath) then
  begin
    PrepareEngineForTrack(Item^.FilePath);
    try
      FAudioEngine.Play(Item^.FilePath, FConfig.DeviceID);

      if FOrigState = psPaused then
      begin
        FAudioEngine.Pause;
        FState := psPaused;
      end
      else
      begin
        FState := psPlaying;
      end;

      if FMaintenanceProgress > 0.0 then
        FAudioEngine.Seek(FMaintenanceProgress);

      UpdateGapless;
    except
      Stop;
    end;
  end
  else
    Stop;
end;

procedure TPlaybackManager.RetryCurrent;
begin
  AttemptPlayCurrent;
end;

procedure TPlaybackManager.SetToneControl(const State: TToneState);
begin
  FConfig.ToneDirect   := State.DirectMode;
  FConfig.ToneBassDB   := State.BassDB;
  FConfig.ToneLowMidDB    := State.LowMidDB;
  FConfig.ToneMidDB    := State.MidDB;
  FConfig.ToneHighMidDB    := State.HighMidDB;
  FConfig.ToneTrebleDB := State.TrebleDB;
  FConfig.ToneBassHz   := State.BassHz;
  FConfig.ToneLowMidHz    := State.LowMidHz;
  FConfig.ToneMidHz    := State.MidHz;
  FConfig.ToneHighMidHz    := State.HighMidHz;
  FConfig.ToneTrebleHz := State.TrebleHz;

  if Assigned(FAudioEngine) then
    FAudioEngine.SetToneControl(State);
end;

procedure TPlaybackManager.ToggleRepeat;
begin
  if FState <> psStopped then
    ConsumePendingTrackSwap;

  case FRepeatMode of
    rmOff: FRepeatMode := rmAll;
    rmAll: FRepeatMode := rmOne;
    rmOne: FRepeatMode := rmOff;
  end;
  if FState <> psStopped then
    UpdateGapless;
  if Assigned(FOnModeChange) then
    FOnModeChange(FRepeatMode, FShuffleMode);
end;

// The tags, cover and folder info of the started track are
// read on the I/O worker (no disk access on the UI thread at a track change).
// OnTrackChange fires when the result arrives (Update -> ProcessIOResults,
// normally within one 50 ms timer tick). Playback itself is not delayed.
procedure TPlaybackManager.TriggerTrackChange;
var
  Item: PQueueItem;
begin
  Item := GetCurrentItem;
  if not Assigned(Item) then
    Exit;

  Inc(FMetaGeneration);
  FMetaPending   := True;
  FMetaIsRefresh := False;
  FCurrentMeta   := Default(TAudioMetadata);
  if Assigned(FIOWorker) then
    FIOWorker.RequestMeta(FMetaGeneration, Item^.FilePath);

  if Assigned(FOnBackgroundRequest) then
    FOnBackgroundRequest(Self);
end;

procedure TPlaybackManager.RefreshTrackInfo;
var
  Item: PQueueItem;
begin
  // A track change's info is on its way: it is read from the file anew anyway
  if FMetaPending and (not FMetaIsRefresh) then
    Exit;

  Item := GetCurrentItem;
  if (not Assigned(Item)) or (not Assigned(FIOWorker)) then
    Exit;

  // A newer generation: an older refresh still under way is ignored
  Inc(FMetaGeneration);
  FMetaPending   := True;
  FMetaIsRefresh := True;
  FIOWorker.RequestMeta(FMetaGeneration, Item^.FilePath);

  if Assigned(FOnBackgroundRequest) then
    FOnBackgroundRequest(Self);
end;

// Second half of TriggerTrackChange (UI thread)
procedure TPlaybackManager.ApplyTrackInfo(const AFilePath: string; AFound: Boolean;
  const AMeta: TAudioMetadata);
var
  Item: PQueueItem;
begin
  Item := GetCurrentItem;
  if not Assigned(Item) then
  begin
    FMetaPending := False;
    Exit;
  end;

  // The current track changed meanwhile (without a new request): read it again
  if not SameText(Item^.FilePath, AFilePath) then
  begin
    TriggerTrackChange;
    Exit;
  end;

  FMetaPending := False;
  if AFound then
    FCurrentMeta := AMeta
  else
    FCurrentMeta := Default(TAudioMetadata);

  // A RefreshTrackInfo result only updates what is shown
  if FMetaIsRefresh then
  begin
    FMetaIsRefresh := False;
    if Assigned(FOnTrackInfoRefreshed) then
      FOnTrackInfoRefreshed(Item^, FCurrentMeta);
  end
  else if Assigned(FOnTrackChange) then
    FOnTrackChange(Item^, FCurrentMeta);

  // The manager only needs the tags; the cover bytes live in the UI copy
  SetLength(FCurrentMeta.CoverData, 0);
  SetLength(FCurrentMeta.FolderCoverData, 0);

  // A gapless probe that arrived before the sample rate was known
  if FProbeDeferred then
  begin
    FProbeDeferred := False;
    if (FState = psPlaying) or (FState = psPaused) then
      UpdateGapless;
  end;
end;

procedure TPlaybackManager.ClearGaplessPreload;
begin
  // Also drop a gapless probe that is still running
  Inc(FGaplessGeneration);
  FProbePath    := '';
  FProbeTrackId := 0;

  FQueuedNextFilePath := '';
  FQueuedNextTrackId  := 0;
  if Assigned(FAudioEngine) then
    FAudioEngine.SetNextFile('');
end;

// =============================================================================
// Central handler for WasTrackSwapped.
// 1. Called from Update() on the main timer, AND called before any queue
//    mutation (SyncQueue, ToggleShuffle, ToggleRepeat, UpdateGapless) so a
//    swap that already occurred on the audio thread is never overwritten!
// 2. Resolves the new index by FQueuedNextTrackId first, then searches forward
//    from FCurrentIndex by FQueuedNextFilePath so duplicate tracks in a queue
//    never jump backwards to an earlier copy!
// =============================================================================
function TPlaybackManager.ConsumePendingTrackSwap: Boolean;
var
  I, SearchIdx, CandidateIdx: Integer;
  FoundMatch: Boolean;
  Item: PQueueItem;
begin
  Result := False;
  if (not Assigned(FAudioEngine)) or (not FAudioEngine.WasTrackSwapped) then
    Exit;

  Result       := True;
  CandidateIdx := FCurrentIndex;
  if FRepeatMode = rmOne then
    { Do nothing, index stays the same }
  else if FCurrentIndex + 1 < FPlayQueue.Count then
    CandidateIdx := FCurrentIndex + 1
  else if FRepeatMode = rmAll then
    CandidateIdx := 0;

  FoundMatch := False;

  // 1. Check if CandidateIdx already matches the exact TrackId or FilePath
  if (CandidateIdx >= 0) and (CandidateIdx < FPlayQueue.Count) then
  begin
    if (FQueuedNextTrackId > 0) and
       (PQueueItem(FPlayQueue[CandidateIdx])^.TrackId = FQueuedNextTrackId) then
      FoundMatch := True
    else if (FQueuedNextTrackId = 0) and (FQueuedNextFilePath <> '') and
            SameText(PQueueItem(FPlayQueue[CandidateIdx])^.FilePath, FQueuedNextFilePath) then
      FoundMatch := True;
  end;

  // 2. Search by TrackId, forward (wrapping) from FCurrentIndex.
  // The same library track queued twice shares one TrackId,
  // so searching from index 0 would jump back to the earlier copy.
  if (not FoundMatch) and (FQueuedNextTrackId > 0) and (FPlayQueue.Count > 0) then
  begin
    for I := 1 to FPlayQueue.Count do
    begin
      SearchIdx := (Max(0, FCurrentIndex) + I) mod FPlayQueue.Count;
      if PQueueItem(FPlayQueue[SearchIdx])^.TrackId = FQueuedNextTrackId then
      begin
        CandidateIdx := SearchIdx;
        FoundMatch   := True;
        Break;
      end;
    end;
  end;

  // 3. Fallback: Search forward from FCurrentIndex by FilePath
  if (not FoundMatch) and (FQueuedNextFilePath <> '') and (FPlayQueue.Count > 0) then
  begin
    for I := 1 to FPlayQueue.Count do
    begin
      SearchIdx := (Max(0, FCurrentIndex) + I) mod FPlayQueue.Count;
      if SameText(PQueueItem(FPlayQueue[SearchIdx])^.FilePath, FQueuedNextFilePath) then
      begin
        CandidateIdx := SearchIdx;
        Break;
      end;
    end;
  end;

  FCurrentIndex       := CandidateIdx;
  FQueuedNextFilePath := '';
  FQueuedNextTrackId  := 0;

  Item := GetCurrentItem;
  if Assigned(Item) then
  begin
    AddLog(SafeFormat(FMT_LOG_OPENING_TRACK, [ExtractFileName(Item^.FilePath)]));
  end;

  TriggerTrackChange;
end;

// Selects the next gapless candidate (UI thread). Returns False
// (after disabling gapless preload) when there is no usable next track.
function TPlaybackManager.ResolveGaplessNext(out ANextItem: PQueueItem): Boolean;
var
  NextIdx: Integer;
begin
  Result    := False;
  ANextItem := nil;

  // Out of bounds memory shield
  if (FCurrentIndex < 0) or
     (FCurrentIndex >= FPlayQueue.Count) or
     (FPlayQueue.Count = 0) then
    Exit;

  if FRepeatMode = rmOne then
    NextIdx := FCurrentIndex
  else if FCurrentIndex + 1 < FPlayQueue.Count then
    NextIdx := FCurrentIndex + 1
  else if FRepeatMode = rmAll then
  begin
    // INFINITE SHUFFLE SAFETY:
    // If shuffle is ON, disable gapless for the final track so PlayNext can reshuffle
    if FShuffleMode <> smOff then
      Exit
    else
      NextIdx := 0;
  end
  else
    Exit;

  ANextItem := PQueueItem(FPlayQueue[NextIdx]);

  // Do not pre-open a next file that is locked by the tagger
  if (not Assigned(ANextItem)) or
     (Assigned(FileLockRegistry) and FileLockRegistry.IsFileBusy(ANextItem^.FilePath)) then
  begin
    ANextItem := nil;
    Exit;
  end;

  Result := True;
end;

// First half of the gapless preload (UI thread). The existence
// check and tag read of the next file run on the I/O worker; the engine keeps
// its current "next" (and FQueuedNext* keep describing it) until
// ApplyGaplessProbe replaces it.
procedure TPlaybackManager.UpdateGapless;
var
  NextItem   : PQueueItem;
  CurItem    : PQueueItem;
  PrepParams : TNextPrepareParams;
  WantPrep   : Boolean;
begin
  if not Assigned(FAudioEngine) then
    Exit;

  // If the audio thread already swapped to the next track
  // before Update() polled it, advance FCurrentIndex first!
  if (FState = psPlaying) or (FState = psPaused) then
    ConsumePendingTrackSwap;

  Inc(FGaplessGeneration);
  FProbePath    := '';
  FProbeTrackId := 0;

  if not ResolveGaplessNext(NextItem) then
  begin
    FQueuedNextFilePath := '';
    FQueuedNextTrackId  := 0;
    FAudioEngine.SetNextFile('');
    Exit;
  end;

  FProbePath    := NextItem^.FilePath;
  FProbeTrackId := NextItem^.TrackId;

  // Let the worker also build the next track's source (with the
  // current play thread's settings), so ApplyGaplessProbe does no disk access.
  // The sample rate is 0 while the current track's info is still pending.
  CurItem  := GetCurrentItem;
  WantPrep := Assigned(CurItem) and FAudioEngine.GetNextPrepareParams(PrepParams);
  if Assigned(CurItem) then
    FIOWorker.RequestProbe(FGaplessGeneration, NextItem^.FilePath, WantPrep, PrepParams,
      FCurrentMeta.SampleRate, IsDSDFile(CurItem^.FilePath))
  else
    FIOWorker.RequestProbe(FGaplessGeneration, NextItem^.FilePath, False, PrepParams,
      0, False);
end;

// Second half of the gapless preload (UI thread)
// APrep = the source the I/O worker built (Source may be nil).
// Handed to the engine when it is used; otherwise the caller frees it.
procedure TPlaybackManager.ApplyGaplessProbe(const AFilePath: string; AFound: Boolean;
  ASampleRate: Integer; var APrep: TPreparedNext);
var
  NextItem: PQueueItem;
  CurItem: PQueueItem;
  PrevQueuedPath: string;
  PrevQueuedId: Integer;
  Accepted: Boolean;
begin
  if not Assigned(FAudioEngine) then
    Exit;

  // The queue may have changed while the file was being probed: make sure the
  // probed file is still the next track, otherwise start a new probe
  if (not ResolveGaplessNext(NextItem)) or
     (not SameText(NextItem^.FilePath, AFilePath)) or
     (NextItem^.TrackId <> FProbeTrackId) then
  begin
    UpdateGapless;
    Exit;
  end;

  CurItem := GetCurrentItem;
  if (not Assigned(CurItem)) or (not AFound) or
     (IsDSDFile(NextItem^.FilePath) <> IsDSDFile(CurItem^.FilePath)) or
     (ASampleRate <> FCurrentMeta.SampleRate) then
  begin
    // Say why the next change is not gapless (once per pair)
    if Assigned(CurItem) and AFound and
       (FGaplessLogKey <> CurItem^.FilePath + '|' + NextItem^.FilePath) then
    begin
      FGaplessLogKey := CurItem^.FilePath + '|' + NextItem^.FilePath;
      if IsDSDFile(NextItem^.FilePath) <> IsDSDFile(CurItem^.FilePath) then
        AddLog(SafeFormat(FMT_LOG_GAPLESS_DSD_PCM, [ExtractFileName(NextItem^.FilePath)]))
      else if IsDSDFile(NextItem^.FilePath) then
        AddLog(SafeFormat(FMT_LOG_GAPLESS_DSD_RATE, [ExtractFileName(NextItem^.FilePath)]))
      else
        AddLog(SafeFormat(FMT_LOG_GAPLESS_RATE, [ExtractFileName(NextItem^.FilePath),
          FormatRateKHz(ASampleRate), FormatRateKHz(FCurrentMeta.SampleRate)]));
    end;

    FQueuedNextFilePath := '';
    FQueuedNextTrackId  := 0;
    FAudioEngine.SetNextFile('');
    Exit;
  end;

  // What the engine currently holds as its "next" track; needed to resolve a
  // swap that happened while the probe was running (see below)
  PrevQueuedPath := FQueuedNextFilePath;
  PrevQueuedId   := FQueuedNextTrackId;

  FQueuedNextFilePath := NextItem^.FilePath;
  FQueuedNextTrackId  := NextItem^.TrackId;

  // Hand over the source the I/O worker has built (no disk access
  // here). Without one (not built, failed, or built for an earlier play
  // thread) the engine builds it here.
  if Assigned(APrep.Source) and (APrep.StreamId = FAudioEngine.StreamId) then
    Accepted := FAudioEngine.SetPreparedNext(APrep)
  else
  begin
    FreePreparedNext(APrep);
    Accepted := FAudioEngine.SetNextFile(NextItem^.FilePath);
  end;

  if not Accepted then
  begin
    // The audio thread swapped to the previously queued track
    // before this call, so the track chosen here is stale and was rejected.
    // Restore the previous queued identity so the swap resolves to the track
    // that is really playing, consume it, and start a new probe once.
    FQueuedNextFilePath := PrevQueuedPath;
    FQueuedNextTrackId  := PrevQueuedId;
    if ConsumePendingTrackSwap and (not FInGaplessRetry) then
    begin
      FInGaplessRetry := True;
      try
        UpdateGapless;
      finally
        FInGaplessRetry := False;
      end;
    end;
  end;
end;

procedure TPlaybackManager.Pause;
var
  Item: PQueueItem;
begin
  if FState = psPlaying then
  begin
    FAudioEngine.Pause;
    SetState(psPaused);

    Item := GetCurrentItem;
    if Assigned(Item) then
      AddLog(SafeFormat(FMT_LOG_PAUSED, [ExtractFileName(Item^.FilePath)]));
  end;
end;

procedure TPlaybackManager.Resume;
var
  Item: PQueueItem;
begin
  if FState = psPaused then
  begin
    FAudioEngine.Resume;
    SetState(psPlaying);

    Item := GetCurrentItem;
    if Assigned(Item) then
      AddLog(SafeFormat(FMT_LOG_RESUMED, [ExtractFileName(Item^.FilePath)]));
  end;
end;

procedure TPlaybackManager.Stop;
begin
  // Drop a track that is still being opened / probed
  CancelBackgroundIO;

  FState              := psStopped;
  FQueuedNextFilePath := '';
  FQueuedNextTrackId  := 0;
  FCurrentMeta        := Default(TAudioMetadata);

  FAudioEngine.Stop;
  FCurrentIndex := -1;

  if Assigned(FOnStateChange) then
    FOnStateChange(psStopped);
end;

procedure TPlaybackManager.Seek(Percent: Double);
begin
  if Percent < 0.0 then
    Percent := 0.0;

  if Percent > 0.999 then
    Percent := 0.999;

  if FState <> psStopped then
    FAudioEngine.Seek(Percent);
end;

procedure TPlaybackManager.SetVolume(Vol: Integer);
begin
  if not Assigned(FAudioEngine) then
    Exit;

  if FConfig.VolumeLocked then
    FAudioEngine.SetVolume(1000)
  else
    FAudioEngine.SetVolume(Vol);
end;

function TPlaybackManager.GetProgress: Double;
begin
  if Assigned(FAudioEngine) then
    Result := FAudioEngine.GetProgress
  else
    Result := 0.0;
end;

function TPlaybackManager.GetDuration: Double;
begin
  if Assigned(FAudioEngine) then
    Result := FAudioEngine.GetDuration
  else
    Result := 0.0;
end;

// Drive keep-alive targets (UI thread, called from Update).
// Active while playing, and while paused up to KEEPALIVE_PAUSE_LIMIT_MS; then
// the drives may sleep. Only when the targets change are they handed over.
procedure TPlaybackManager.UpdateKeepAlive;
const
  KEEPALIVE_PAUSE_LIMIT_MS = 30 * 60 * 1000;  // 30 minutes
var
  Want: Boolean;
  Item, NextItem: PQueueItem;
  CurPath, NextPath, Lost: string;
begin
  Want := FConfig.KeepDrivesAwake and ((FState = psPlaying) or (FState = psPaused));

  if FState = psPaused then
  begin
    if FPauseStartTick = 0 then
      FPauseStartTick := GetTickCount64;
    if GetTickCount64 - FPauseStartTick > KEEPALIVE_PAUSE_LIMIT_MS then
      Want := False;
  end
  else
    FPauseStartTick := 0;

  CurPath  := '';
  NextPath := '';
  if Want then
  begin
    Item := GetCurrentItem;
    if Assigned(Item) then
      CurPath := Item^.FilePath;
    // The next track by queue / repeat / shuffle, also when it cannot be
    // played gaplessly (e.g. another sample rate) and may be on another drive
    if ResolveGaplessNext(NextItem) then
      NextPath := NextItem^.FilePath;
  end;

  // Log once when a drive cannot be reached / is back
  if Assigned(FKeepAlive) then
  begin
    if Want then
      Lost := FKeepAlive.LostDrive
    else
      Lost := FKeepAliveLost;  // stopped / option off: nothing to report

    if Lost <> FKeepAliveLost then
    begin
      if Lost <> '' then
        AddWarning(SafeFormat(FMT_LOG_KEEPALIVE_LOST, [Lost]))
      else
        AddLog(SafeFormat(FMT_LOG_KEEPALIVE_BACK, [FKeepAliveLost]));
      FKeepAliveLost := Lost;
    end;

    if not Want then
      FKeepAliveLost := '';
  end;

  if (CurPath = FKeepAliveCurrent) and (NextPath = FKeepAliveNext) then
    Exit;

  FKeepAliveCurrent := CurPath;
  FKeepAliveNext    := NextPath;

  // A thread that cannot be created (out of resources) must
  // not raise from the UI timer: log once, playback goes on without it
  if (not Assigned(FKeepAlive)) and (not FKeepAliveFailed) and
     ((CurPath <> '') or (NextPath <> '')) then
  begin
    try
      FKeepAlive := TDriveKeepAlive.Create;
    except
      on E: Exception do
      begin
        FKeepAlive       := nil;
        FKeepAliveFailed := True;
        AddLog(SafeFormat(FMT_LOG_KEEPALIVE_START_FAILED, [E.Message]), False, True);
      end;
    end;
  end;

  if Assigned(FKeepAlive) then
    FKeepAlive.SetTargets(CurPath, NextPath);
end;

procedure TPlaybackManager.Update;
var
  FailedIndex: Integer;
  FailedItem: PQueueItem;
  LocalErrType: TAudioErrorType;
  LocalErrMsg: string;
  LocalErrDetail: string;
  LocalFailRate: Integer;
  LocalFailIsDSD: Boolean;
begin
  // Finish background requests first (also while stopped,
  // because a track that is being opened is still in psStopped)
  ProcessIOResults;

  // Hand the current / next track to the drive keep-alive
  UpdateKeepAlive;

  if (FState = psStopped) or (FState = psMaintenance) then
    Exit;

  if FAudioEngine.HasError then
  begin
    // Capture the error details BEFORE calling Stop (which frees the thread)
    LocalErrType   := FAudioEngine.GetErrorType;
    LocalErrMsg    := FAudioEngine.GetErrorMessage;
    LocalErrDetail := FAudioEngine.GetErrorDetail;
    LocalFailRate  := FAudioEngine.GetFailedSampleRate;

    FailedIndex := FCurrentIndex;
    // What kind of track failed, also taken before the stop
    FailedItem     := GetCurrentItem;
    LocalFailIsDSD := Assigned(FailedItem) and IsDSDFile(FailedItem^.FilePath);

    Stop;
    Screen.Cursor := crDefault;

    // The dialogs open from the message loop (ShowEngineErrorAsync),
    // not here inside the UI timer: the timer would keep firing during the modal
    // dialog and run Update and the rest of the UI tick again while this call
    // was still in progress.
    if LocalErrType = aeSampleRateUnsupported then
    begin
      FCurrentIndex     := FailedIndex;
      FPendingFailRate  := LocalFailRate;
      FPendingFailIsDSD := LocalFailIsDSD;
      Application.QueueAsyncCall(@ShowEngineErrorAsync, Ord(eedSampleRate));
    end
    else
    begin
      AddLog(LOG_PREFIX_ENGINE_FATAL + LocalErrMsg, False, True);
      // Exception class, message and place (unexpected errors only)
      if LocalErrDetail <> '' then
        AddLog(SafeFormat(FMT_LOG_ENGINE_ERROR_DETAIL, [LocalErrDetail]), False, True);
      FPendingErrMsg := LocalErrMsg;
      Application.QueueAsyncCall(@ShowEngineErrorAsync, Ord(eedMessage));
    end;

    Exit;
  end;

  // Bulletproof Gapless Index & UI Update
  if ConsumePendingTrackSwap then
  begin
    UpdateGapless;
  end
  else if FAudioEngine.HasFinished then
  begin
    PlayNext(False);
  end;
end;

// Opens the engine error dialog queued by Update, from the message
// loop. FOnSampleRateError is nil during shutdown; Destroy removes a call that
// is still queued.
procedure TPlaybackManager.ShowEngineErrorAsync(Data: PtrInt);
begin
  case TEngineErrorDialog(Data) of
    eedSampleRate:
      if Assigned(FOnSampleRateError) then
        FOnSampleRateError(FPendingFailRate, FPendingFailIsDSD);
    eedMessage:
      ALMessageDlg(TITLE_PLAYBACK_ERROR, FPendingErrMsg, [mbOK], mbOK, mkError);
  end;
end;

procedure TPlaybackManager.GetQueueSnapshot(Dest: TStrings; out CurrentIdx: Integer);
var
  I: Integer;
  Item: PQueueItem;
begin
  Dest.Clear;
  CurrentIdx := FCurrentIndex;

  for I := 0 to FPlayQueue.Count - 1 do
  begin
    Item := PQueueItem(FPlayQueue[I]);
    Dest.Add(Format('[%d] %s', [I, ExtractFileName(Item^.FilePath)]));
  end;
end;

procedure TPlaybackManager.PrepareEngineForTrack(const AFilePath: string);
var
  Maps    : array of TRateMap;
  I       : Integer;
  ToneCfg : TToneState;
begin
  Maps := nil;

  if FConfig.VolumeLocked then
    FAudioEngine.ReplayGainMode := 0
  else
    FAudioEngine.ReplayGainMode := FConfig.ReplayGainMode;

  FAudioEngine.RGTrackTags       := RG_TAGS_TRACK_GAIN;
  FAudioEngine.RGAlbumTags       := RG_TAGS_ALBUM_GAIN;
  FAudioEngine.RGTrackPeakTags   := RG_TAGS_TRACK_PEAK;
  FAudioEngine.RGAlbumPeakTags   := RG_TAGS_ALBUM_PEAK;

  FAudioEngine.UseDoP            := FConfig.UseDoP;
  FAudioEngine.OutputApi         := FConfig.OutputApi;
  FAudioEngine.AsioNativeDsd     := FConfig.AsioNativeDsd;
  FAudioEngine.ResampleQuality   := FConfig.ResampleQuality;

  FAudioEngine.DisableVolume     := FConfig.VolumeLocked;
  FAudioEngine.PreampDB          := FConfig.PreampDB;
  FAudioEngine.EnableSoftClipping:= FConfig.EnableSoftClipping;
  FAudioEngine.AutoHeadroom      := FConfig.AutoHeadroom;

  FAudioEngine.UpsamplePhase     := FConfig.UpsamplePhase;
  FAudioEngine.DownsamplePhase   := FConfig.DownsamplePhase;

  // Translate the UI Combobox Index into physical float values
  case FConfig.ResampleBandWidthIndex of
    1: FAudioEngine.ResampleBandWidth := VAL_BANDWIDTH_MED;  // Medium Roll-off
    2: FAudioEngine.ResampleBandWidth := VAL_BANDWIDTH_FAST; // Fast Roll-off
    else
      FAudioEngine.ResampleBandWidth := VAL_DEF_BANDWIDTH_FLOAT; // 0 = Slow Roll-off (Default)
  end;

  case FConfig.ResampleAntiAliasIndex of
    1: FAudioEngine.ResampleAntiAlias := VAL_ANTIALIAS_HIGH; // High Suppression
    2: FAudioEngine.ResampleAntiAlias := VAL_ANTIALIAS_STD;  // Standard Suppression
    else
      FAudioEngine.ResampleAntiAlias := VAL_DEF_ANTI_ALIAS_FLOAT; // 0 = Max Suppression (Default)
  end;

  FAudioEngine.UseHighResTimer  := FConfig.UseHighResTimer;
  FAudioEngine.OptimizeAffinity := FConfig.OptimizeAffinity;
  FAudioEngine.EnableMMCSS      := FConfig.EnableMMCSS;

  ToneCfg.DirectMode := FConfig.ToneDirect;
  ToneCfg.BassDB     := FConfig.ToneBassDB;
  ToneCfg.LowMidDB      := FConfig.ToneLowMidDB;
  ToneCfg.MidDB      := FConfig.ToneMidDB;
  ToneCfg.HighMidDB      := FConfig.ToneHighMidDB;
  ToneCfg.TrebleDB   := FConfig.ToneTrebleDB;
  ToneCfg.BassHz     := FConfig.ToneBassHz;
  ToneCfg.LowMidHz      := FConfig.ToneLowMidHz;
  ToneCfg.MidHz      := FConfig.ToneMidHz;
  ToneCfg.HighMidHz      := FConfig.ToneHighMidHz;
  ToneCfg.TrebleHz   := FConfig.ToneTrebleHz;

  FAudioEngine.SetToneControl(ToneCfg);

  if IsDSDFile(AFilePath) then
  begin
    // The DSD buffer only for DSD that goes to the DAC as DSD
    // (DoP, native over ASIO): a dropout there is a pop (the DAC loses the
    // DSD stream). DSD converted to PCM is PCM from then on: the PCM buffer.
    FAudioEngine.BufferSizeMs     := DsdBufferFor(FConfig);
    FAudioEngine.DsdGainDB        := FConfig.DsdToPcmGain;
    FAudioEngine.DsdLowPassFilter := FConfig.DsdLowPassFilter;

    if FConfig.UseDoP then
      FAudioEngine.ResamplePCM := False
    else if FConfig.DisableResampleForDSD then
      FAudioEngine.ResamplePCM := False
    else
      FAudioEngine.ResamplePCM := FConfig.ResamplePCM;
  end
  else
  begin
    FAudioEngine.BufferSizeMs := FConfig.PCMBufferMs;
    FAudioEngine.ResamplePCM  := FConfig.ResamplePCM;
  end;

  SetLength(Maps, 14);

  // 44.1 kHz Family
  Maps[0].InRate := 44100;   Maps[0].OutRate := FConfig.TargetSampleRate44;
  Maps[1].InRate := 88200;   Maps[1].OutRate := FConfig.TargetSampleRate44;
  Maps[2].InRate := 176400;  Maps[2].OutRate := FConfig.TargetSampleRate44;
  Maps[3].InRate := 352800;  Maps[3].OutRate := FConfig.TargetSampleRate44;
  Maps[4].InRate := 705600;  Maps[4].OutRate := FConfig.TargetSampleRate44; // DSD512 Decimated
  Maps[5].InRate := 1411200; Maps[5].OutRate := FConfig.TargetSampleRate44; // DSD1024 Decimated
  Maps[6].InRate := 2822400; Maps[6].OutRate := FConfig.TargetSampleRate44; // DSD64 Raw

  // 48 kHz Family
  Maps[7].InRate  := 48000;   Maps[7].OutRate  := FConfig.TargetSampleRate48;
  Maps[8].InRate  := 96000;   Maps[8].OutRate  := FConfig.TargetSampleRate48;
  Maps[9].InRate  := 192000;  Maps[9].OutRate  := FConfig.TargetSampleRate48;
  Maps[10].InRate := 384000;  Maps[10].OutRate := FConfig.TargetSampleRate48;
  Maps[11].InRate := 768000;  Maps[11].OutRate := FConfig.TargetSampleRate48;
  Maps[12].InRate := 1536000; Maps[12].OutRate := FConfig.TargetSampleRate48;
  Maps[13].InRate := 3072000; Maps[13].OutRate := FConfig.TargetSampleRate48;

  // Never allow an OutRate of 0 Hz in the rate map!
  for I := 0 to High(Maps) do
  begin
    if (Maps[I].OutRate <= 0) or
       ((FConfig.BypassThreshold > 0) and (Maps[I].InRate >= FConfig.BypassThreshold)) then
      Maps[I].OutRate := Maps[I].InRate;
  end;

  FAudioEngine.SetRateMapping(Maps);

  AddLog(SafeFormat(FMT_LOG_OPENING_TRACK, [ExtractFileName(AFilePath)]));
end;

// Lets the owner keep its UI timer fast until the results are in
function TPlaybackManager.HasPendingIO: Boolean;
begin
  Result := FOpenPending or FMetaPending;
end;

function TPlaybackManager.GetSignalInfo: TSignalInfo;
begin
  if Assigned(FAudioEngine) then Result := FAudioEngine.GetSignalInfo
  else Result := Default(TSignalInfo);
end;

function TPlaybackManager.GetEngineStats: TAudioStats;
begin
  Result := Default(TAudioStats);
  if Assigned(FAudioEngine) then
  begin
    Result.IsPlaying         := FAudioEngine.IsPlaying;
    Result.BitDepth          := FAudioEngine.GetBitDepth;
    Result.Channels          := FAudioEngine.GetChannels;
    Result.InputRate         := FAudioEngine.GetInputRate;
    Result.OutputRate        := FAudioEngine.GetOutputRate;
    Result.BufferSizeMs      := FAudioEngine.BufferSizeMs;
    Result.AppliedReplayGain := FAudioEngine.GetAppliedReplayGain;
    Result.IsBitPerfect      := FAudioEngine.IsBitPerfect;
  end;
end;

class procedure TPlaybackManager.EnumerateDevices(List: TStrings; out DefaultIdx: Integer);
begin
  TAudioEngine.EnumerateDevices(List, DefaultIdx);
end;

class function TPlaybackManager.GetDeviceFriendlyName(const DeviceId: string): string;
begin
  Result := TAudioEngine.GetDeviceFriendlyName(DeviceId);
end;

end.
