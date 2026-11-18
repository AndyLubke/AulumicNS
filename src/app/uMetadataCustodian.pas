unit uMetadataCustodian;

{$mode ObjFPC}{$H+}

// =============================================================================
// AulumicNS - uMetadataCustodian
// Copyright (C) 2026 André Lubke
// Licensed under the GNU General Public License, version 3 (see LICENSE).
//
// A thread-safe daemon that processes background queues for writing ID3/FLAC
// metadata and ReplayGain tags. Safely communicates with the audio engine to
// temporarily release file locks without breaking playback.
//
// It logs through AuLog and shows its messages with AuDialogs. The library
// records it changes are journaled by TLibraryManager (UpdateRecord,
// SetReplayGainFlag, ...).
// =============================================================================

interface

uses
  Classes, SysUtils, SyncObjs, uMetadataPayloads, uFileLockRegistry,
  uLibraryManager, uLibraryTypes, uPlaybackManager;

type
  { TMetadataCustodian }
  TMetadataCustodian = class(TThread)
  private
    FLibraryManager  : TLibraryManager;
    FPlaybackManager : TPlayBackManager;

    FQueue           : TList;
    FQueueLock       : TCriticalSection;
    FWakeEvent       : TSimpleEvent;
    FTaintedAlbums   : TStringList;

    FTotalBatchCount : Integer;
    FProcessedCount  : Integer;
    FUIStatusStr     : string;
    // Files of the current batch that could not be updated
    // (worker thread only) and the totals handed to SyncBatchCompleted
    FFailedCount       : Integer;
    FLastBatchFailed   : Integer;  // Guarded by FQueueLock
    FLastBatchTotal    : Integer;  // Guarded by FQueueLock
    // Failed jobs are kept (full copies) so the user can retry
    // them. FFailed* = current batch (worker), FPending* = handed to
    // SyncBatchCompleted. All four guarded by FQueueLock.
    FJobFailed         : Boolean;  // Worker only: current job failed
    FJobFailReason     : string;   // Worker only: its reason
    FFailedJobs        : TList;
    FFailedLines       : TStringList;
    FPendingRetryJobs  : TList;
    FPendingFailLines  : TStringList;

    // JIT Bouncing Carriers
    FTargetFile          : string;
    FTrackWasInterrupted : Boolean;
    FNextWasEvicted      : Boolean;
    FLogMsg              : string;
    FLogIsError          : boolean;

    // Library record update carriers. UpdateRecord replaces the
    // strings of a library record, which the UI reads without the lock, so it
    // runs on the main thread (SyncUpdateLibraryRecord), not on this thread.
    FSyncTrack           : TTrackInfo;
    FSyncEffAlbumArtist  : string;
    FSyncEffAlbum        : string;
    FSyncEffFolder       : string;

    procedure SyncAddLog;
    procedure LogSafe(const Msg: string; IsError: Boolean = False);

    procedure ProcessNextJob(Job: PMetadataJob);
    procedure RecordFailedJob(Job: PMetadataJob);
    procedure SyncProgressTicker;
    procedure SyncBatchCompleted;
    procedure SyncPauseAudioForFile;
    procedure SyncResumeAudioIfNeeded;
    procedure SyncUpdateLibraryRecord;

    function  WriteReplayGainTags(TagReader: TObject; TrkGain, AlbGain, TrkPeak, AlbPeak: Double;
                ATrackOnly: Boolean = False): Boolean;
    procedure WriteTagEditorTags(ATagReader: TObject; const P: TTagEditorPayload);
    procedure RollbackTaintedAlbums;

  protected
    procedure Execute; override;

  public
    constructor Create(ALibraryManager: TLibraryManager = nil;
      APlaybackManager: TPlayBackManager = nil);
    destructor Destroy; override;

    procedure EnqueueBatch(AJobList: TList);
    procedure StrangleAndStop;

    property LibraryManager: TLibraryManager read FLibraryManager write FLibraryManager;
    property PlaybackManager: TPlayBackManager read FPlaybackManager write FPlaybackManager;
  end;

implementation

uses
  AuAudioTypes, Math, baseTag, AudioTag, tag_id3V2, tag_vorbis, uAppConsts, uEngineStateManager,
  uMetaUtils, uOSUtils, AuLog, uAudioUtils, ALMetadata, uAppStrings,
  Forms, Controls, Dialogs, AuDialogs;

const
  MAX_CUSTODIAN_COVER_BYTES = 15 * BYTES_PER_MB; // 15 MB safety ceiling

// Date and size of a file exactly as the library scanner reads
// them (TSearchRec), so the library can store them after a save and the next
// scan does not see the program's own write as a change.
function GetScanStamp(const APath: string; out ATime, ASize: Int64): Boolean;
var
  SR: TSearchRec;
begin
  ATime  := 0;
  ASize  := 0;
  Result := SysUtils.FindFirst(LongPath(APath), faAnyFile, SR) = 0;
  if Result then
  begin
    try
      ATime := SR.Time;
      ASize := SR.Size;
    finally
      SysUtils.FindClose(SR);
    end;
    Result := ATime > 0;
  end;
end;

// Inspects the actual magic bytes of the cover buffer so the MIME string
// written into FLAC (METADATA_BLOCK_PICTURE) or ID3v2 (APIC/PIC) always matches
// the binary image format on disk.
function ResolveCoverMimeType(const ABytes: TBytes; const AFallbackMime: string): string;
begin
  if (Length(ABytes) >= 4) and
     (ABytes[0] = $89) and (ABytes[1] = $50) and
     (ABytes[2] = $4E) and (ABytes[3] = $47) then
    Exit(MIME_PNG);

  if (Length(ABytes) >= 3) and
     (ABytes[0] = $FF) and (ABytes[1] = $D8) and (ABytes[2] = $FF) then
    Exit(MIME_JPEG);

  if SameText(Trim(AFallbackMime), MIME_PNG) then
    Result := MIME_PNG
  else
    Result := MIME_JPEG;
end;

// Frees the jobs in AList (and their cover buffers) and clears it
procedure DisposeJobList(AList: TList);
var
  I   : Integer;
  Job : PMetadataJob;
begin
  if not Assigned(AList) then
    Exit;
  for I := 0 to AList.Count - 1 do
  begin
    Job := PMetadataJob(AList[I]);
    if Assigned(Job) then
    begin
      SetLength(Job^.TagEditor.CoverData, 0);
      Dispose(Job);
    end;
  end;
  AList.Clear;
end;

{ TMetadataCustodian }

constructor TMetadataCustodian.Create(ALibraryManager: TLibraryManager;
  APlaybackManager: TPlayBackManager);
begin
  // Initialize locks and lists BEFORE starting the thread
  inherited Create(True);
  FreeOnTerminate  := False;
  Priority         := tpLower;

  FLibraryManager  := ALibraryManager;
  FPlaybackManager := APlaybackManager;

  FQueue           := TList.Create;
  FQueueLock       := TCriticalSection.Create;
  FWakeEvent       := TSimpleEvent.Create;
  FTaintedAlbums   := TStringList.Create;
  FTaintedAlbums.Sorted     := True;
  FTaintedAlbums.Duplicates := dupIgnore;

  FTotalBatchCount := 0;
  FProcessedCount  := 0;
  FUIStatusStr     := '';
  FFailedCount     := 0;
  FLastBatchFailed := 0;
  FLastBatchTotal  := 0;

  FFailedJobs       := TList.Create;
  FFailedLines      := TStringList.Create;
  FPendingRetryJobs := TList.Create;
  FPendingFailLines := TStringList.Create;

  Start;
end;

destructor TMetadataCustodian.Destroy;
var
  I   : Integer;
  Job : PMetadataJob;
begin
  // Always signal FWakeEvent unconditionally before WaitFor
  // so Destroy can never hang if Terminate was already called externally!
  Terminate;
  if Assigned(FWakeEvent) then
    FWakeEvent.SetEvent;
  WaitFor;
  TThread.RemoveQueuedEvents(Self);

  FQueueLock.Enter;
  try
    for I := 0 to FQueue.Count - 1 do
    begin
      Job := PMetadataJob(FQueue[I]);
      if Assigned(Job) then
      begin
        if Job^.ActionType = matTagEditor then
          SetLength(Job^.TagEditor.CoverData, 0);
        Dispose(Job);
      end;
    end;
    FQueue.Clear;
  finally
    FQueueLock.Leave;
  end;

  DisposeJobList(FFailedJobs);
  DisposeJobList(FPendingRetryJobs);
  FFailedJobs.Free;
  FPendingRetryJobs.Free;
  FFailedLines.Free;
  FPendingFailLines.Free;

  FQueue.Free;
  FQueueLock.Free;
  FWakeEvent.Free;
  FTaintedAlbums.Free;
  inherited Destroy;
end;

procedure TMetadataCustodian.StrangleAndStop;
begin
  Terminate;
  if Assigned(FWakeEvent) then
    FWakeEvent.SetEvent;
  WaitFor;
  TThread.RemoveQueuedEvents(Self);
end;

procedure TMetadataCustodian.EnqueueBatch(AJobList: TList);
var
  I, VIPWatermark, ValidAdded : Integer;
  IsVIPBatch                  : Boolean;
  FirstJob                    : PMetadataJob;
  Candidate                   : PMetadataJob;
begin
  if (not Assigned(AJobList)) or (AJobList.Count = 0) then
    Exit;

  FirstJob := nil;
  for I := 0 to AJobList.Count - 1 do
  begin
    if Assigned(AJobList[I]) then
    begin
      FirstJob := PMetadataJob(AJobList[I]);
      Break;
    end;
  end;

  if not Assigned(FirstJob) then
    Exit;

  if Assigned(AppStateManager) then
    AppStateManager.ShowBackgroundIOStatus(STATUS_PREPARING_TRACK_UPDATES);

  IsVIPBatch := (FirstJob^.ActionType = matTagEditor);
  ValidAdded := 0;

  FQueueLock.Enter;
  try
    FQueue.Capacity := FQueue.Count + AJobList.Count;

    if IsVIPBatch then
    begin
      VIPWatermark := 0;
      while VIPWatermark < FQueue.Count do
      begin
        Candidate := PMetadataJob(FQueue[VIPWatermark]);
        if (not Assigned(Candidate)) or (Candidate^.ActionType <> matTagEditor) then
          Break;
        Inc(VIPWatermark);
      end;

      for I := 0 to AJobList.Count - 1 do
      begin
        if Assigned(AJobList[I]) then
        begin
          FQueue.Insert(VIPWatermark, AJobList[I]);
          Inc(VIPWatermark);
          Inc(ValidAdded);
        end;
      end;
    end
    else
    begin
      for I := 0 to AJobList.Count - 1 do
      begin
        if Assigned(AJobList[I]) then
        begin
          FQueue.Add(AJobList[I]);
          Inc(ValidAdded);
        end;
      end;
    end;

    Inc(FTotalBatchCount, ValidAdded);
  finally
    FQueueLock.Leave;
  end;

  if ValidAdded > 0 then
    FWakeEvent.SetEvent;
end;

procedure TMetadataCustodian.SyncProgressTicker;
var
  Pct: Double;
  SafeTotal, SafeProcessed: Integer;
  SafeStatus: string;
begin
  if Assigned(AppStateManager) then
  begin
    Pct := -1;

    FQueueLock.Enter;
    try
      SafeTotal     := FTotalBatchCount;
      SafeProcessed := FProcessedCount;
      SafeStatus    := FUIStatusStr;
    finally
      FQueueLock.Leave;
    end;

    if SafeTotal > 0 then
      Pct := (SafeProcessed / SafeTotal) * 100.0;

    AppStateManager.UpdateStatusUI(SafeStatus, Pct);
  end;
end;

procedure TMetadataCustodian.SyncBatchCompleted;
var
  Failed, Total, I : Integer;
  RetryJobs        : TList;
  FailLines        : TStringList;
  Msg              : string;
begin
  if Assigned(FLibraryManager) then
    FLibraryManager.SaveDatabase;

  RetryJobs := TList.Create;
  FailLines := TStringList.Create;
  try
    // Take over the failed jobs of this batch (copies with all
    // tag / cover / ReplayGain values) and their display lines
    FQueueLock.Enter;
    try
      Failed           := FLastBatchFailed;
      Total            := FLastBatchTotal;
      FLastBatchFailed := 0;
      FLastBatchTotal  := 0;
      for I := 0 to FPendingRetryJobs.Count - 1 do
        RetryJobs.Add(FPendingRetryJobs[I]);
      FPendingRetryJobs.Clear;
      FailLines.Assign(FPendingFailLines);
      FPendingFailLines.Clear;
    finally
      FQueueLock.Leave;
    end;

    if Assigned(AppStateManager) then
      AppStateManager.BackgroundIOBatchFinished;

    if Assigned(FLibraryManager) then
      FLibraryManager.ProcessPendingScans;

    if (Failed > 0) and (not Terminated) and (not Application.Terminated) then
    begin
      // List the failed files (at most SAVE_FAILED_MAX_LINES,
      // the log keeps all of them) and offer Retry / Discard
      Msg := SafeFormat(FMT_MSG_SAVE_FAILED_HEAD, [Failed, Total]) + sLineBreak + sLineBreak;
      for I := 0 to Min(FailLines.Count, SAVE_FAILED_MAX_LINES) - 1 do
        Msg := Msg + FailLines[I] + sLineBreak;
      if FailLines.Count > SAVE_FAILED_MAX_LINES then
        Msg := Msg + SafeFormat(FMT_MSG_SAVE_FAILED_MORE, [FailLines.Count - SAVE_FAILED_MAX_LINES]) + sLineBreak;

      if RetryJobs.Count > 0 then
      begin
        Msg := Msg + sLineBreak + MSG_SAVE_FAILED_RETRY;
        if ALMessageDlg(TITLE_TAGS_NOT_SAVED, Msg, LBL_BTN_RETRY, LBL_BTN_DISCARD,
                        False, mbYes, mkWarning) = mrYes then
        begin
          // EnqueueBatch takes ownership of the jobs
          if (not Terminated) and (not Application.Terminated) then
          begin
            EnqueueBatch(RetryJobs);
            RetryJobs.Clear;
          end;
        end;
      end
      else
        ALMessageDlg(TITLE_TAGS_NOT_SAVED, Msg, [mbOK], mbOK, mkWarning);
    end;
  finally
    DisposeJobList(RetryJobs);  // Discard (or nothing to retry)
    RetryJobs.Free;
    FailLines.Free;
  end;
end;

// =============================================================================
// TRACK-LEVEL JIT BOUNCING DELEGATES
// FTargetFile is compared against FPlaybackManager's exact current track and
// queued gapless track paths; IsFileLocked is never probed for this.
// This guarantees an external lock (Explorer, antivirus, scanner) on another
// file can never interrupt an unrelated playing track.
// =============================================================================
// Runs on the main thread (Synchronize from ProcessNextJob)
procedure TMetadataCustodian.SyncUpdateLibraryRecord;
var
  LibTrack: TTrackInfo;
begin
  if not Assigned(FLibraryManager) then
    Exit;

  // Both calls lock the library themselves
  FLibraryManager.UpdateRecord(FSyncTrack);

  if FLibraryManager.TryGetTrack(FSyncTrack.FilePath, LibTrack) then
  begin
    FSyncEffAlbumArtist := LibTrack.AlbumArtist;
    FSyncEffAlbum       := LibTrack.Album;
    FSyncEffFolder      := ExcludeTrailingPathDelimiter(LibTrack.FolderDir);
  end;
end;

procedure TMetadataCustodian.SyncPauseAudioForFile;
var
  CurrItem: PQueueItem;
begin
  FTrackWasInterrupted := False;
  FNextWasEvicted      := False;
  if (not Assigned(FPlaybackManager)) or (FPlaybackManager.State = psStopped) then
    Exit;

  // First process any track swap that already occurred on the audio thread.
  // Once it is consumed here, Update() never sees the swap
  // and never calls UpdateGapless, so make SyncResumeAudioIfNeeded re-arm it.
  if FPlaybackManager.ConsumePendingTrackSwap then
    FNextWasEvicted := True;

  // 1. Check if FTargetFile is the preloaded gapless NEXT track
  if (FPlaybackManager.QueuedNextFilePath <> '') and
     SameFileName(FPlaybackManager.QueuedNextFilePath, FTargetFile) then
  begin
    FPlaybackManager.ClearGaplessPreload;
    FNextWasEvicted := True;
  end;

  // 2. Check if FTargetFile is the ACTIVELY playing/paused track
  CurrItem := FPlaybackManager.GetCurrentItem;
  if Assigned(CurrItem) and SameFileName(CurrItem^.FilePath, FTargetFile) then
  begin
    FPlaybackManager.EnterMaintenance;
    FTrackWasInterrupted := True;
  end;
end;

procedure TMetadataCustodian.SyncResumeAudioIfNeeded;
begin
  if Assigned(FPlaybackManager) then
  begin
    if FTrackWasInterrupted then
      FPlaybackManager.ExitMaintenance
    else if FNextWasEvicted and (FPlaybackManager.State <> psStopped) then
      FPlaybackManager.UpdateGapless;
  end;

  FTrackWasInterrupted := False;
  FNextWasEvicted      := False;
end;

// =============================================================================
// TAG WRITING ENGINE
// =============================================================================
// ATrackOnly: the album gain and peak are not written (the
// old ones are removed like every ReplayGain field): a track without an album
// tag has no album to take them from
function TMetadataCustodian.WriteReplayGainTags(TagReader: TObject; TrkGain, AlbGain, TrkPeak, AlbPeak: Double;
  ATrackOnly: Boolean): Boolean;
var
  ReaderObj         : TTagReader;
  CommonTags        : TCommonTags;
  FS                : TFormatSettings;
  TrkGainStr,
  AlbGainStr,
  TrkPeakStr,
  AlbPeakStr,
  RGFrameID         : string;
  IsFLAC, IsID3     : Boolean;
  TextFrameClass    : TFrameElementClass;
  I                 : Integer;
  El                : TFrameElement;
  ReaderClass, TagsClass, UpperStr: string;
  NewID3            : TID3Frame;
begin
  Result := False;
  if not (TagReader is TTagReader) then
    Exit;
  ReaderObj := TTagReader(TagReader);
  if not Assigned(ReaderObj.Tags) then
    Exit;

  // Reject NaN or Infinite ReplayGain values so corrupt
  // strings like "Nan dB" are never written into audio files!
  if IsNan(TrkGain) or IsInfinite(TrkGain) or
     IsNan(AlbGain) or IsInfinite(AlbGain) or
     IsNan(TrkPeak) or IsInfinite(TrkPeak) or (TrkPeak < 0.0) or
     IsNan(AlbPeak) or IsInfinite(AlbPeak) or (AlbPeak < 0.0) then
    Exit(False);

  TrkGain := EnsureRange(TrkGain, -60.0, 24.0);
  AlbGain := EnsureRange(AlbGain, -60.0, 24.0);

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  TrkGainStr := Format('%.2f dB', [TrkGain], FS);
  AlbGainStr := Format('%.2f dB', [AlbGain], FS);
  TrkPeakStr := Format('%.6f',    [TrkPeak], FS);
  AlbPeakStr := Format('%.6f',    [AlbPeak], FS);

  ReaderClass := UpperCase(ReaderObj.ClassName);
  TagsClass   := UpperCase(ReaderObj.Tags.ClassName);

  IsFLAC := (Pos('FLAC', ReaderClass) > 0) or
            (Pos('FLAC', TagsClass)   > 0) or
            (Pos('VORBIS', TagsClass) > 0);

  IsID3  := (Pos('ID3', ReaderClass)  > 0) or
            (Pos('ID3', TagsClass)    > 0) or
            (Pos('DSF', ReaderClass)  > 0) or
            (Pos('WAVE', ReaderClass) > 0);

  if IsFLAC then
  begin
    // Remove every existing ReplayGain field first (duplicates
    // included), as the ID3 branch does; SetFrameValue below only updates the
    // first field of each name and would leave duplicates with their old values.
    for I := ReaderObj.Tags.Count - 1 downto 0 do
    begin
      El := ReaderObj.Tags.Frames[I];
      if Assigned(El) and
         (SameText(El.ID, TAG_RG_TRACK_GAIN) or SameText(El.ID, TAG_RG_ALBUM_GAIN) or
          SameText(El.ID, TAG_RG_TRACK_PEAK) or SameText(El.ID, TAG_RG_ALBUM_PEAK)) then
        ReaderObj.Tags.Remove(El);
    end;

    TextFrameClass := nil;
    if ReaderObj.Tags is TVorbisTags then
      TextFrameClass := TVorbisFrame
    else
    begin
      for I := 0 to ReaderObj.Tags.Count - 1 do
      begin
        if (ReaderObj.Tags.Frames[I] <> nil) and (not (ReaderObj.Tags.Frames[I] is TImageElement)) then
        begin
          TextFrameClass := TFrameElementClass(ReaderObj.Tags.Frames[I].ClassType);
          Break;
        end;
      end;
    end;

    // Seed unconditionally when TextFrameClass is nil!
    if TextFrameClass = nil then
    begin
      CommonTags       := ReaderObj.GetCommonTags;
      CommonTags.Title := '_RG_INIT_';
      ReaderObj.SetCommonTags(CommonTags);
      for I := ReaderObj.Tags.Count - 1 downto 0 do
      begin
        if (ReaderObj.Tags.Frames[I] <> nil) and (not (ReaderObj.Tags.Frames[I] is TImageElement)) then
        begin
          TextFrameClass := TFrameElementClass(ReaderObj.Tags.Frames[I].ClassType);
          ReaderObj.Tags.Remove(ReaderObj.Tags.Frames[I]);
          Break;
        end;
      end;
    end;

    if TextFrameClass <> nil then
    begin
      ReaderObj.Tags.SetFrameValue(TAG_RG_TRACK_GAIN, TrkGainStr, TextFrameClass);
      if not ATrackOnly then
        ReaderObj.Tags.SetFrameValue(TAG_RG_ALBUM_GAIN, AlbGainStr, TextFrameClass);
      ReaderObj.Tags.SetFrameValue(TAG_RG_TRACK_PEAK, TrkPeakStr, TextFrameClass);
      if not ATrackOnly then
        ReaderObj.Tags.SetFrameValue(TAG_RG_ALBUM_PEAK, AlbPeakStr, TextFrameClass);
      Result := True;
    end;
  end
  else if IsID3 then
  begin
    // Normalize any corrupt ID3 version outside 2..4 to 3 (ID3v2.3)
    if ReaderObj.Tags is TID3Tags then
    begin
      if not (TID3Tags(ReaderObj.Tags).Version in [2..4]) then
        TID3Tags(ReaderObj.Tags).Version := 3;
    end;

    if (ReaderObj.Tags is TID3Tags) and (TID3Tags(ReaderObj.Tags).Version = 2) then
      RGFrameID := 'TXX'
    else
      RGFrameID := 'TXXX';

    for I := ReaderObj.Tags.Count - 1 downto 0 do
    begin
      El := ReaderObj.Tags.Frames[I];
      if Assigned(El) and (SameText(El.ID, 'TXXX') or SameText(El.ID, 'TXX')) then
      begin
        UpperStr := UpperCase(El.AsString);
        if (Pos(TAG_RG_PREFIX, UpperStr) > 0) or (Pos(TAG_R128_PREFIX, UpperStr) > 0) then
          ReaderObj.Tags.Remove(El);
      end;
    end;

    NewID3          := TID3Frame.Create(RGFrameID);
    NewID3.Tagger   := ReaderObj.Tags;
    NewID3.AsString := TAG_RG_TRACK_GAIN + #0 + TrkGainStr;
    ReaderObj.Tags.Add(NewID3);

    if not ATrackOnly then
    begin
      NewID3          := TID3Frame.Create(RGFrameID);
      NewID3.Tagger   := ReaderObj.Tags;
      NewID3.AsString := TAG_RG_ALBUM_GAIN + #0 + AlbGainStr;
      ReaderObj.Tags.Add(NewID3);
    end;

    NewID3          := TID3Frame.Create(RGFrameID);
    NewID3.Tagger   := ReaderObj.Tags;
    NewID3.AsString := TAG_RG_TRACK_PEAK + #0 + TrkPeakStr;
    ReaderObj.Tags.Add(NewID3);

    if not ATrackOnly then
    begin
      NewID3          := TID3Frame.Create(RGFrameID);
      NewID3.Tagger   := ReaderObj.Tags;
      NewID3.AsString := TAG_RG_ALBUM_PEAK + #0 + AlbPeakStr;
      ReaderObj.Tags.Add(NewID3);
    end;

    Result := True;
  end;
end;

procedure TMetadataCustodian.WriteTagEditorTags(ATagReader: TObject; const P: TTagEditorPayload);
const
  // Matches MAX_FRAME_RAW_LEN in ALMetadata: larger ID3 comment frames are not
  // shown in the tag editor, so they are not removed when the comment changes.
  MAX_SHOWN_FRAME_LEN = 16384;
var
  ReaderObj      : TTagReader;
  K              : Integer;
  Frame          : TFrameElement;
  TextFrameClass : TFrameElementClass;
  IsFLAC, IsV22, IsV24, IsVorbis, HadComment: Boolean;
  TitleID, AlbumID, GenreID,
  ArtistID, AlbumArtistID, CompID, PerfID, DiscID, TrackID,
  AltTitleID, AltAlbumID, AltGenreID,
  AltArtistID, AltAlbumArtistID, AltCompID, AltPerfID, AltDiscID, AltTrackID,
  YearStr, CommentStr, MimeStr: string;
  imgEl          : TImageElement;
  PicFrame       : TID3Frame;
  CommFrame      : TID3FrameComment;
  imgStream      : TMemoryStream;

  // Writes one field. Frames with the alternative ID and any
  // duplicate frames are removed; the first frame with the primary ID is kept
  // and updated (or created). An empty value removes every matching frame.
  procedure WriteField(const APrimaryID, AAltID, AValue: string);
  var
    Idx, FirstIdx: Integer;
    F: TFrameElement;
  begin
    FirstIdx := -1;
    if Trim(AValue) <> '' then
    begin
      for Idx := 0 to ReaderObj.Tags.Count - 1 do
      begin
        F := ReaderObj.Tags.Frames[Idx];
        if Assigned(F) and SameText(F.ID, APrimaryID) then
        begin
          FirstIdx := Idx;
          Break;
        end;
      end;
    end;

    for Idx := ReaderObj.Tags.Count - 1 downto 0 do
    begin
      if Idx = FirstIdx then
        Continue;
      F := ReaderObj.Tags.Frames[Idx];
      if Assigned(F) and (SameText(F.ID, APrimaryID) or
         ((AAltID <> '') and SameText(F.ID, AAltID))) then
        ReaderObj.Tags.Remove(F);
    end;

    if Trim(AValue) <> '' then
      ReaderObj.Tags.SetFrameValue(APrimaryID, AValue, TextFrameClass);
  end;

  // FLAC multi-value fields (Artist, Album Artist, Genre,
  // Composer, Performer): every '; '-separated part becomes its own field
  // (ARTIST=A, ARTIST=B), the standard Vorbis comment form. All existing
  // fields with this ID are replaced; an empty value removes them all.
  procedure WriteVorbisMultiField(const AID, AValue: string);
  var
    Idx: Integer;
    F: TFrameElement;
    Parts: TStringArray;
    PartStr: string;
    NewFrame: TVorbisFrame;
  begin
    for Idx := ReaderObj.Tags.Count - 1 downto 0 do
    begin
      F := ReaderObj.Tags.Frames[Idx];
      if Assigned(F) and SameText(F.ID, AID) then
        ReaderObj.Tags.Remove(F);
    end;

    Parts := AValue.Split([';']);
    for Idx := 0 to High(Parts) do
    begin
      PartStr := Trim(Parts[Idx]);
      if PartStr = '' then
        Continue;
      NewFrame := TVorbisFrame.Create(AID);
      try
        NewFrame.Tagger   := ReaderObj.Tags;
        NewFrame.AsString := PartStr;
        ReaderObj.Tags.Add(NewFrame);
      except
        NewFrame.Free;
        raise;
      end;
    end;
  end;

  // Multi-value field: separate fields for FLAC, one '; ' value for ID3
  procedure WriteListField(const APrimaryID, AAltID, AValue: string);
  begin
    if IsVorbis then
      WriteVorbisMultiField(APrimaryID, AValue)
    else
      WriteField(APrimaryID, AAltID, AValue);
  end;

  // A changed track or disc number keeps the total that was
  // already in the file ('5/12' edited to 6 becomes '6/12').
  function NumberWithTotal(const APrimaryID, AAltID: string; ANumber: Integer): string;
  var
    OldStr, TotalStr: string;
    SlashPos: Integer;
  begin
    Result := '';
    if ANumber <= 0 then
      Exit;
    Result := IntToStr(ANumber);

    OldStr := ReaderObj.Tags.GetFrameValue(APrimaryID);
    if (OldStr = '') and (AAltID <> '') then
      OldStr := ReaderObj.Tags.GetFrameValue(AAltID);

    SlashPos := Pos('/', OldStr);
    if SlashPos > 0 then
    begin
      TotalStr := Trim(Copy(OldStr, SlashPos + 1, MaxInt));
      if TotalStr <> '' then
        Result := Result + '/' + TotalStr;
    end;
  end;

  function IsFourDigitYear(const S: string): Boolean;
  var
    I: Integer;
  begin
    Result := Length(S) = 4;
    if Result then
      for I := 1 to 4 do
        if not (S[I] in ['0'..'9']) then
          Exit(False);
  end;

begin
  if not (ATagReader is TTagReader) then
    Exit;
  ReaderObj := TTagReader(ATagReader);
  if not Assigned(ReaderObj.Tags) then
    Exit;

  IsFLAC := IsFlacFile(ReaderObj.FileName);

  // Normalize any corrupt ID3 version outside 2..4 to 3 (ID3v2.3)
  if (not IsFLAC) and (ReaderObj.Tags is TID3Tags) then
  begin
    if not (TID3Tags(ReaderObj.Tags).Version in [2..4]) then
      TID3Tags(ReaderObj.Tags).Version := 3;
  end;

  IsV22 := (not IsFLAC) and (ReaderObj.Tags is TID3Tags) and
           (TID3Tags(ReaderObj.Tags).Version = 2);

  if P.IsModified then
  begin
    // =========================================================================
    // Only the fields the user actually changed are written.
    // Every other frame in the file stays exactly as it was. (Writing all
    // fields would rewrite values the editor only shows in simplified form:
    // comments would lose their line breaks, '5/12' would become '5', untitled
    // files would get their file name as title, ID3v2.4 years would move to TYER.)
    // =========================================================================
    IsVorbis := ReaderObj.Tags is TVorbisTags;
    IsV24    := (ReaderObj.Tags is TID3Tags) and
                (TID3Tags(ReaderObj.Tags).Version = 4);

    if IsVorbis then
      TextFrameClass := TVorbisFrame
    else if ReaderObj.Tags is TID3Tags then
      TextFrameClass := TID3Frame
    else
      TextFrameClass := nil;

    if Assigned(TextFrameClass) then
    begin
      if IsVorbis then
      begin
        TitleID          := 'TITLE';        AltTitleID       := '';
        AlbumID          := 'ALBUM';        AltAlbumID       := '';
        GenreID          := 'GENRE';        AltGenreID       := '';
        ArtistID         := 'ARTIST';       AltArtistID      := '';
        AlbumArtistID    := 'ALBUMARTIST';  AltAlbumArtistID := '';
        CompID           := 'COMPOSER';     AltCompID        := '';
        PerfID           := 'PERFORMER';    AltPerfID        := '';
        DiscID           := 'DISCNUMBER';   AltDiscID        := '';
        TrackID          := 'TRACKNUMBER';  AltTrackID       := 'TRACK';
      end
      else if IsV22 then
      begin
        TitleID          := 'TT2';          AltTitleID       := 'TIT2';
        AlbumID          := 'TAL';          AltAlbumID       := 'TALB';
        GenreID          := 'TCO';          AltGenreID       := 'TCON';
        ArtistID         := 'TP1';          AltArtistID      := 'TPE1';
        AlbumArtistID    := 'TP2';          AltAlbumArtistID := 'TPE2';
        CompID           := 'TCM';          AltCompID        := 'TCOM';
        PerfID           := 'TP3';          AltPerfID        := 'TPE3';
        DiscID           := 'TPA';          AltDiscID        := 'TPOS';
        TrackID          := 'TRK';          AltTrackID       := 'TRCK';
      end
      else
      begin
        TitleID          := 'TIT2';         AltTitleID       := 'TT2';
        AlbumID          := 'TALB';         AltAlbumID       := 'TAL';
        GenreID          := 'TCON';         AltGenreID       := 'TCO';
        ArtistID         := 'TPE1';         AltArtistID      := 'TP1';
        AlbumArtistID    := 'TPE2';         AltAlbumArtistID := 'TP2';
        CompID           := 'TCOM';         AltCompID        := 'TCM';
        PerfID           := 'TPE3';         AltPerfID        := 'TP3';
        DiscID           := 'TPOS';         AltDiscID        := 'TPA';
        TrackID          := 'TRCK';         AltTrackID       := 'TRK';
      end;

      if P.Current.Title <> P.Original.Title then
        WriteField(TitleID, AltTitleID, Trim(P.Current.Title));
      if P.Current.Album <> P.Original.Album then
        WriteField(AlbumID, AltAlbumID, Trim(P.Current.Album));
      if P.Current.Genre <> P.Original.Genre then
        WriteListField(GenreID, AltGenreID, NormalizeSemicolons(P.Current.Genre));
      if P.Current.Artist <> P.Original.Artist then
        WriteListField(ArtistID, AltArtistID, NormalizeSemicolons(P.Current.Artist));
      if P.Current.AlbumArtist <> P.Original.AlbumArtist then
        WriteListField(AlbumArtistID, AltAlbumArtistID, NormalizeSemicolons(P.Current.AlbumArtist));
      if P.Current.Composer <> P.Original.Composer then
        WriteListField(CompID, AltCompID, NormalizeSemicolons(P.Current.Composer));
      if P.Current.Performer <> P.Original.Performer then
        WriteListField(PerfID, AltPerfID, NormalizeSemicolons(P.Current.Performer));

      if P.Current.Track <> P.Original.Track then
        WriteField(TrackID, AltTrackID, NumberWithTotal(TrackID, AltTrackID, P.Current.Track));
      if P.Current.Disc <> P.Original.Disc then
        WriteField(DiscID, AltDiscID, NumberWithTotal(DiscID, AltDiscID, P.Current.Disc));

      // Year: the frame that the reader prefers is replaced, the other removed
      if P.Current.DateStr <> P.Original.DateStr then
      begin
        YearStr := Trim(P.Current.DateStr);
        if IsVorbis then
          WriteField('DATE', '', YearStr)
        else if IsV22 then
          WriteField('TYE', 'TOR', YearStr)
        else if IsV24 or ((YearStr <> '') and not IsFourDigitYear(YearStr)) then
          WriteField('TDRC', 'TYER', YearStr)
        else
          WriteField('TYER', 'TDRC', YearStr);
      end;

      // Comment: the frames the editor showed as the comment are replaced by
      // one frame with the new text. Technical frames stay (ID3 iTunNORM
      // comments and oversized frames, which the editor does not show).
      if P.Current.Comment <> P.Original.Comment then
      begin
        CommentStr := Trim(P.Current.Comment);
        if IsVorbis then
        begin
          HadComment := False;
          for K := 0 to ReaderObj.Tags.Count - 1 do
            if Assigned(ReaderObj.Tags.Frames[K]) and
               SameText(ReaderObj.Tags.Frames[K].ID, 'COMMENT') then
            begin
              HadComment := True;
              Break;
            end;

          // Without a COMMENT field the editor showed DESCRIPTION instead
          for K := ReaderObj.Tags.Count - 1 downto 0 do
          begin
            Frame := ReaderObj.Tags.Frames[K];
            if Assigned(Frame) and (SameText(Frame.ID, 'COMMENT') or
               ((not HadComment) and SameText(Frame.ID, 'DESCRIPTION'))) then
              ReaderObj.Tags.Remove(Frame);
          end;

          if CommentStr <> '' then
            ReaderObj.Tags.SetFrameValue('COMMENT', CommentStr, TVorbisFrame);
        end
        else
        begin
          for K := ReaderObj.Tags.Count - 1 downto 0 do
          begin
            Frame := ReaderObj.Tags.Frames[K];
            if Assigned(Frame) and
               (SameText(Frame.ID, 'COMM') or SameText(Frame.ID, 'COM')) and
               (Frame.Size <= MAX_SHOWN_FRAME_LEN) and
               (Pos('ITUNNORM', UpperCase(Frame.AsString)) = 0) then
              ReaderObj.Tags.Remove(Frame);
          end;

          if CommentStr <> '' then
          begin
            if IsV22 then
              CommFrame := TID3FrameComment.Create('COM')
            else
              CommFrame := TID3FrameComment.Create('COMM');
            try
              CommFrame.Tagger   := ReaderObj.Tags;
              CommFrame.AsString := CommentStr;
              ReaderObj.Tags.Add(CommFrame);
            except
              CommFrame.Free;
              raise;
            end;
          end;
        end;
      end;
    end;
  end;
  // 4. IMAGE LOGIC
  // If the replacement cover exceeds the size limit, keep the
  // existing cover untouched (never delete it and write nothing).
  if P.CoverModified and P.HasCover and
     (Length(P.CoverData) > MAX_CUSTODIAN_COVER_BYTES) then
  begin
    LogSafe(SafeFormat(FMT_LOG_META_COVER_TOO_LARGE,
                   [ExtractFileName(ReaderObj.FileName), MAX_CUSTODIAN_COVER_BYTES div BYTES_PER_MB]), True);
  end
  else if P.CoverModified then
  begin
    ReaderObj.Tags.ClearImages;
    for K := ReaderObj.Tags.Count - 1 downto 0 do
    begin
      Frame := ReaderObj.Tags.Frames[K];
      if Assigned(Frame) and
         ((Frame is TImageElement) or
          SameText(Frame.ID, 'APIC') or
          SameText(Frame.ID, 'PIC') or
          SameText(Frame.ID, 'METADATA_BLOCK_PICTURE') or
          SameText(Frame.ID, 'COVERART') or
          SameText(Frame.ID, 'COVERARTMIME')) then
      begin
        ReaderObj.Tags.Remove(Frame);
      end;
    end;

    // Enforce 15 MB cover size limit in the custodian
    if P.HasCover and (Length(P.CoverData) > 0) and
       (Length(P.CoverData) <= MAX_CUSTODIAN_COVER_BYTES) then
    begin
      MimeStr := ResolveCoverMimeType(P.CoverData, P.CoverMimeType);

      if IsFLAC then
      begin
        imgEl := TImageElement.Create;
        try
          imgEl.MIMEType    := MimeStr;
          imgEl.PictureType := 3; // Front Cover
          imgEl.Description := '';
          imgEl.Image.WriteBuffer(P.CoverData[0], Length(P.CoverData));
          imgEl.Image.Position := 0;
          ReaderObj.Tags.AddImage(imgEl);
        except
          imgEl.Free;
          raise;
        end;
      end
      else if ReaderObj.Tags is TID3Tags then
      begin
        imgStream := TMemoryStream.Create;
        try
          imgStream.WriteBuffer(P.CoverData[0], Length(P.CoverData));
          imgStream.Position := 0;

          if TID3Tags(ReaderObj.Tags).Version = 2 then
          begin
            PicFrame := TID3Frame.Create('PIC');
            if SameText(MimeStr, MIME_PNG) then
              MimeStr := 'PNG'
            else
              MimeStr := 'JPG';
          end
          else
            PicFrame := TID3Frame.Create('APIC');

          try
            PicFrame.Tagger := ReaderObj.Tags;
            PicFrame.LoadFromImageStream(
              imgStream,
              MimeStr,
              3, // Front Cover
              TID3Tags(ReaderObj.Tags).Version = 2
            );
            if PicFrame.Size > 0 then
              ReaderObj.Tags.Add(PicFrame)
            else
              PicFrame.Free;
          except
            PicFrame.Free;
            raise;
          end;
        finally
          imgStream.Free;
        end;
      end;
    end;
  end;
end;

procedure TMetadataCustodian.RollbackTaintedAlbums;
begin
  if FTaintedAlbums.Count = 0 then
    Exit;
  if not Assigned(FLibraryManager) then
    Exit;

  // The library clears the flags under its own lock and
  // also marks itself changed, so the cleared flags are saved
  FLibraryManager.ClearReplayGainForAlbums(FTaintedAlbums);

  FTaintedAlbums.Clear;
end;

// =============================================================================
// TRACK-LEVEL EXECUTION
// =============================================================================

procedure TMetadataCustodian.SyncAddLog;
begin
  AddLog(FLogMsg, False, FLogIsError);
end;

procedure TMetadataCustodian.LogSafe(const Msg: string; IsError: Boolean = False);
begin
  if Terminated then
    Exit;
  FLogMsg     := Msg;
  FLogIsError := IsError;
  Synchronize(@SyncAddLog);
end;

// Keeps a full copy of a failed job (worker thread) so it can be
// retried, plus its line for the "Tags Not Saved" dialog. Must be called
// BEFORE the job's cover buffer is released.
procedure TMetadataCustodian.RecordFailedJob(Job: PMetadataJob);
var
  JobCopy : PMetadataJob;
  Kind    : string;
begin
  New(JobCopy);
  JobCopy^ := Job^;   // managed fields (strings, cover TBytes) are reference counted

  if Job^.ActionType = matReplayGain then
    Kind := LBL_META_KIND_REPLAYGAIN
  else
    Kind := LBL_META_KIND_TAGS;

  FQueueLock.Enter;
  try
    FFailedJobs.Add(JobCopy);
    FFailedLines.Add(SafeFormat(FMT_MSG_SAVE_FAILED_LINE,
                     [ExtractFileName(Job^.FilePath), Kind, FJobFailReason]));
  finally
    FQueueLock.Leave;
  end;
end;

procedure TMetadataCustodian.ProcessNextJob(Job: PMetadataJob);
var
  TagObj         : TTagReader;
  UpdatedTrk     : TTrackInfo;
  WriteOK        : Boolean;
  TagsPrepared   : Boolean;
  RetryCount     : Integer;
  EffArtist      : string;
  EffAlbumArtist : string;
  EffAlbum       : string;
  EffFolder      : string;
  ThumbHash      : string;
  TempSavePath   : string;
  TempMeta       : TAudioMetadata;
  FailReason     : string;
  LockUsers      : string;
  PartialTag     : Boolean;
  StampTime      : Int64;
  StampSize      : Int64;

  procedure QuarantineCurrentRelease;
  var
    LiveTrack: TTrackInfo;
    TargetAlb: string;
  begin
    if Job^.ActionType <> matReplayGain then
      Exit;

    TargetAlb := Job^.AlbumName;
    LiveTrack := Default(TTrackInfo);  // no warning in the release build

    if Assigned(FLibraryManager) and
       FLibraryManager.TryGetTrack(Job^.FilePath, LiveTrack) and
       (Trim(LiveTrack.Album) <> '') then
      TargetAlb := LiveTrack.Album;

    if TargetAlb <> '' then
      FTaintedAlbums.Add(TargetAlb);
  end;

  // Every skipped file is logged with its reason and
  // counted
  procedure ReportSkip(const AReason: string);
  begin
    Inc(FFailedCount);
    FJobFailed     := True;
    FJobFailReason := AReason;
    LogSafe(SafeFormat(FMT_LOG_META_NOT_UPDATED, [ExtractFileName(Job^.FilePath), AReason]), True);
  end;

begin
  if (not Assigned(Job)) or (Job^.FilePath = '') or Terminated then
    Exit;

  FTargetFile          := Job^.FilePath;
  FTrackWasInterrupted := False;
  FNextWasEvicted      := False;
  FJobFailed           := False;
  FJobFailReason       := '';
  FailReason           := '';
  PartialTag           := False;

  // Acquire FileLockRegistry BEFORE pausing audio so no
  // background scanner can open the file during the transition!
  if Assigned(FileLockRegistry) then
    FileLockRegistry.AcquireLock(Job^.FilePath);
  try
    // JIT STEP 1: If THIS file is active or preloaded in the player, step it aside.
    Synchronize(@SyncPauseAudioForFile);
    try
      if not FileExists(LongPath(Job^.FilePath)) then
      begin
        ReportSkip(LOG_SKIP_FILE_MISSING);
        QuarantineCurrentRelease;
        Exit;
      end;

      // Only wait for handles that really prevent replacing the
      // file (IsFileReplaceBlocked). Virus scanners and the search indexer read
      // files with delete sharing and do not block a save; an exclusive
      // check (IsFileLocked) would treat any open handle as a lock. Wait up to 5 s.
      RetryCount := 0;
      while (not Terminated) and IsFileReplaceBlocked(Job^.FilePath) and (RetryCount < FILE_REPLACE_WAIT_STEPS) do
      begin
        Sleep(FILE_REPLACE_WAIT_STEP_MS);
        Inc(RetryCount);
      end;

      if Terminated then
      begin
        QuarantineCurrentRelease;
        Exit;
      end;

      if IsFileReplaceBlocked(Job^.FilePath) then
      begin
        LockUsers := DescribeFileUsers(Job^.FilePath);
        if LockUsers <> '' then
          ReportSkip(SafeFormat(FMT_LOG_SKIP_FILE_IN_USE, [LockUsers]))
        else
          ReportSkip(LOG_SKIP_FILE_IN_USE_OTHER);
        QuarantineCurrentRelease;
        Exit;
      end;

      WriteOK      := False;
      TagsPrepared := False;
      TagObj       := nil;
      try
        TagObj := GetFileTagsObject(Job^.FilePath);
        if not Assigned(TagObj) then
        begin
          ReportSkip(LOG_SKIP_FILE_UNREADABLE);
          QuarantineCurrentRelease;
          Exit;
        end;
        if not TagObj.isUpdateable then
        begin
          ReportSkip(LOG_SKIP_NOT_WRITABLE);
          QuarantineCurrentRelease;
          Exit;
        end;

        case Job^.ActionType of
          matReplayGain:
            begin
              TagsPrepared := WriteReplayGainTags(TagObj,
                Job^.ReplayGain.TrackGain,
                Job^.ReplayGain.AlbumGain,
                Job^.ReplayGain.TrackPeak,
                Job^.ReplayGain.AlbumPeak,
                Job^.ReplayGain.TrackOnly);
            end;
          matTagEditor:
            begin
              WriteTagEditorTags(TagObj, Job^.TagEditor);
              TagsPrepared := True;
            end;
        end;

        // Remember whether the tag was only partly readable, so the
        // discarded part can be reported after a successful save
        if TagObj.Tags is TID3Tags then
          PartialTag := TID3Tags(TagObj.Tags).HasUnreadableData;

        if TagsPrepared then
        begin
          WriteOK := TagObj.UpdateFile;
          if not WriteOK then
            FailReason := TagObj.LastUpdateError;
        end
        else
          FailReason := LOG_SKIP_TAGS_NOT_PREPARED;

      finally
        try
          if Assigned(TagObj) then
            TagObj.Free;
        except
          // Silent swallow
        end;

        // Match the exact '.~.' temporary file name used by
        // TTagReader.UpdateFile in basetag.pas, and never delete unrelated user files!
        try
          TempSavePath := ChangeFileExt(Job^.FilePath, '.~.' + ExtractFileExt(Job^.FilePath));
          if not FileExists(LongPath(Job^.FilePath)) then
          begin
            if FileExists(LongPath(TempSavePath)) then
              WriteOK := SysUtils.RenameFile(LongPath(TempSavePath), LongPath(Job^.FilePath))
            else
              WriteOK := False;
          end
          else if FileExists(LongPath(TempSavePath)) then
          begin
            SysUtils.DeleteFile(LongPath(TempSavePath));
          end;
        except
          // Swallow recovery errors so we don't mask the original exception
        end;
      end;

      if not WriteOK then
      begin
        if FailReason = '' then
          FailReason := LOG_SKIP_FILE_NOT_SAVED;
        ReportSkip(FailReason);
        QuarantineCurrentRelease;
        Exit;
      end;

      if PartialTag then
        LogSafe(SafeFormat(FMT_LOG_META_PARTIAL_TAG, [ExtractFileName(Job^.FilePath)]));

      // New date and size of the saved file for the library record
      if not GetScanStamp(Job^.FilePath, StampTime, StampSize) then
      begin
        StampTime := 0;
        StampSize := 0;
      end;

      if Assigned(FLibraryManager) then
      begin
        if Job^.ActionType = matReplayGain then
        begin
          // Under the library's own lock; it also marks the
          // library changed, so the flag and the new date / size are saved
          FLibraryManager.SetReplayGainFlag(Job^.FilePath, True, StampTime, StampSize);
        end
        else if Job^.ActionType = matTagEditor then
        begin
          UpdatedTrk             := Default(TTrackInfo);
          UpdatedTrk.FilePath    := Job^.FilePath;
          // UpdateRecord stores these only when > 0
          UpdatedTrk.LastModified := StampTime;
          UpdatedTrk.FileSize     := StampSize;
          UpdatedTrk.Title       := Job^.TagEditor.Current.Title;
          UpdatedTrk.Artist      := Job^.TagEditor.Current.Artist;
          UpdatedTrk.AlbumArtist := Job^.TagEditor.Current.AlbumArtist;
          UpdatedTrk.Album       := Job^.TagEditor.Current.Album;
          UpdatedTrk.Genre       := Job^.TagEditor.Current.Genre;
          UpdatedTrk.Composer    := Job^.TagEditor.Current.Composer;
          UpdatedTrk.Performer   := Job^.TagEditor.Current.Performer;
          UpdatedTrk.DateStr     := Job^.TagEditor.Current.DateStr;
          UpdatedTrk.TrackNumber := Job^.TagEditor.Current.Track;
          UpdatedTrk.DiscNumber  := Job^.TagEditor.Current.Disc;
          // The editor comment may have line breaks; the
          // library keeps the one-line form, the same as after a scan
          UpdatedTrk.Comment     := CompactCommentText(Job^.TagEditor.Current.Comment);

          EffArtist := NormalizeSemicolons(Trim(UpdatedTrk.Artist));
          if EffArtist = '' then
            EffArtist := LBL_UNKNOWN_ARTIST;

          EffAlbumArtist := NormalizeSemicolons(Trim(UpdatedTrk.AlbumArtist));
          if EffAlbumArtist = '' then
            EffAlbumArtist := EffArtist;

          EffAlbum := Trim(UpdatedTrk.Album);
          if EffAlbum = '' then
            EffAlbum := LBL_UNKNOWN_ALBUM;

          EffFolder := ExcludeTrailingPathDelimiter(ExtractFileDir(Job^.FilePath));

          // Update the library record on the main thread (the UI
          // reads its strings without the lock). The effective album values for
          // the thumbnail come back through the carrier fields.
          if not Terminated then
          begin
            FSyncTrack          := UpdatedTrk;
            FSyncEffAlbumArtist := EffAlbumArtist;
            FSyncEffAlbum       := EffAlbum;
            FSyncEffFolder      := EffFolder;
            Synchronize(@SyncUpdateLibraryRecord);
            EffAlbumArtist      := FSyncEffAlbumArtist;
            EffAlbum            := FSyncEffAlbum;
            EffFolder           := FSyncEffFolder;
            FSyncTrack          := Default(TTrackInfo);
          end;

          ThumbHash := GenerateAlbumHash(EffAlbumArtist, EffAlbum, EffFolder);
          if (ThumbHash <> '') and (not FileExists(LongPath(AppCacheThumbsDir + ThumbHash + '.jpg'))) then
          begin
            TempMeta := Default(TAudioMetadata);
            // Oversized covers were not written (R6), so thumbnail from the file instead
            if Job^.TagEditor.HasCover and (Length(Job^.TagEditor.CoverData) > 0) and
               (Length(Job^.TagEditor.CoverData) <= MAX_CUSTODIAN_COVER_BYTES) then
            begin
              TempMeta.HasCover        := True;
              TempMeta.CoverData       := Job^.TagEditor.CoverData;
              Job^.TagEditor.CoverData := nil;
            end
            else if Job^.TagEditor.HasCover then
            begin
              TempMeta := ReadTrackMetadata(Job^.FilePath, True);
            end;

            try
              GenerateAndCacheThumbnail(TempMeta, Job^.FilePath, ThumbHash);
            except
              SetLength(TempMeta.CoverData, 0);
            end;
          end;
        end;
      end;

    except
      on E: Exception do
      begin
        Inc(FFailedCount);
        FJobFailed     := True;
        FJobFailReason := E.Message;
        LogSafe(SafeFormat(FMT_LOG_META_SAVE_ERROR, [ExtractFileName(Job^.FilePath), E.Message]), True);
        QuarantineCurrentRelease;
      end;
    end;

  finally
    // Keep a copy for Retry before the cover buffer is released
    if FJobFailed and (not Terminated) then
    begin
      try
        RecordFailedJob(Job);
      except
        // Never let the bookkeeping abort the worker
      end;
    end;

    if Job^.ActionType = matTagEditor then
      SetLength(Job^.TagEditor.CoverData, 0);

    // Release FileLockRegistry BEFORE calling
    // SyncResumeAudioIfNeeded so UpdateGapless sees the file is no longer busy
    // and immediately re-arms gapless playback!
    if Assigned(FileLockRegistry) then
      FileLockRegistry.ReleaseLock(Job^.FilePath);

    if (FTrackWasInterrupted or FNextWasEvicted) and (not Terminated) then
      Synchronize(@SyncResumeAudioIfNeeded);
  end;
end;

procedure TMetadataCustodian.Execute;
var
  ActiveJob                  : PMetadataJob;
  I                          : Integer;
  HasGenuineWork             : Boolean;
  LastUITick                 : QWord;
  StatePushed                : Boolean;
  LocalProcessed, LocalTotal : Integer;
begin
  while not Terminated do
  begin
    FWakeEvent.WaitFor(INFINITE);
    FWakeEvent.ResetEvent;

    if Terminated then
      Break;

    FQueueLock.Enter;
    try
      HasGenuineWork := (FQueue.Count > 0);
      LocalTotal     := FTotalBatchCount;
    finally
      FQueueLock.Leave;
    end;

    if not HasGenuineWork then
      Continue;

    if Assigned(AppStateManager) then
      AppStateManager.PushState(esBackgroundIOBusy);
    StatePushed := True;
    try
      LastUITick := 0;
      LogSafe(SafeFormat(FMT_LOG_META_BATCH_STARTED, [LocalTotal]));

      while not Terminated do
      begin
        ActiveJob := nil;
        FQueueLock.Enter;
        try
          if FQueue.Count > 0 then
          begin
            ActiveJob := PMetadataJob(FQueue[0]);
            FQueue.Delete(0);
          end;
        finally
          FQueueLock.Leave;
        end;

        if ActiveJob = nil then
          Break;

        // Shield ProcessNextJob with try..except so an unexpected
        // error in Synchronize can never terminate the custodian worker thread!
        try
          try
            ProcessNextJob(ActiveJob);
          except
            on E: Exception do
              LogSafe(SafeFormat(FMT_LOG_META_WORKER_FAULT, [E.Message]), True);
          end;
        finally
          Dispose(ActiveJob);
        end;

        FQueueLock.Enter;
        try
          Inc(FProcessedCount);
          LocalProcessed := FProcessedCount;
          LocalTotal     := FTotalBatchCount;
          FUIStatusStr   := SafeFormat(FMT_STATUS_SAVING_METADATA, [LocalProcessed, LocalTotal]);
        finally
          FQueueLock.Leave;
        end;

        if not Terminated then
        begin
          if (LocalProcessed = 1) or (LocalProcessed = LocalTotal) then
            TThread.Queue(Self, @SyncProgressTicker)
          else
            RateLimitThreadUI(Self, LastUITick, @SyncProgressTicker);

          Sleep(CUSTODIAN_JOB_YIELD_MS);
        end;
      end;

      if Terminated then
      begin
        FQueueLock.Enter;
        try
          for I := 0 to FQueue.Count - 1 do
          begin
            ActiveJob := PMetadataJob(FQueue[I]);
            if Assigned(ActiveJob) and (ActiveJob^.ActionType = matReplayGain) and (ActiveJob^.AlbumName <> '') then
              FTaintedAlbums.Add(ActiveJob^.AlbumName);
          end;
        finally
          FQueueLock.Leave;
        end;
      end;

      if FTaintedAlbums.Count > 0 then
        RollbackTaintedAlbums;

      if (not Terminated) and (LocalTotal > 0) then
      begin
        FQueueLock.Enter;
        try
          FUIStatusStr := STATUS_FINALIZING_UPDATES;
        finally
          FQueueLock.Leave;
        end;
        TThread.Queue(Self, @SyncProgressTicker);

        if FFailedCount > 0 then
          LogSafe(SafeFormat(FMT_LOG_META_BATCH_PARTIAL,
                         [LocalProcessed - FFailedCount, LocalProcessed, FFailedCount]), True)
        else
          LogSafe(SafeFormat(FMT_LOG_META_BATCH_DONE, [LocalProcessed]));

        // Hand the totals to SyncBatchCompleted (UI thread)
        FQueueLock.Enter;
        try
          FLastBatchFailed := FFailedCount;
          FLastBatchTotal  := LocalProcessed;
          // Hand the failed jobs of this batch to SyncBatchCompleted
          for I := 0 to FFailedJobs.Count - 1 do
            FPendingRetryJobs.Add(FFailedJobs[I]);
          FFailedJobs.Clear;
          FPendingFailLines.AddStrings(FFailedLines);
          FFailedLines.Clear;
        finally
          FQueueLock.Leave;
        end;

        if not Terminated then
          Sleep(CUSTODIAN_BATCH_SETTLE_MS);

        if not Terminated then
        begin
          if StatePushed and Assigned(AppStateManager) then
          begin
            AppStateManager.PopState(esBackgroundIOBusy);
            StatePushed := False;
          end;

          TThread.Queue(Self, @SyncBatchCompleted);
        end;
      end;

      FQueueLock.Enter;
      try
        if FQueue.Count = 0 then
        begin
          FTotalBatchCount := 0;
          FProcessedCount  := 0;
          FFailedCount     := 0;
        end;
      finally
        FQueueLock.Leave;
      end;

    finally
      try
        if StatePushed and Assigned(AppStateManager) then
          AppStateManager.PopState(esBackgroundIOBusy);
      except
        // Silent swallow
      end;
    end;
  end;
end;

end.
