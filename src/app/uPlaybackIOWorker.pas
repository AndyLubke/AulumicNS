unit uPlaybackIOWorker;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uPlaybackIOWorker
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Background disk access for TPlaybackManager, so a sleeping USB / network
  drive never freezes the user interface:
    * Open  : optional pre-delay (DAC release), then up to 3 existence checks
              with 250 ms pauses (wakes sleeping drives).
    * Probe : existence check + tag read (no cover art) of the next gapless
              track, returning its sample rate. When it can follow the
              current track gaplessly, its audio source is built here too
              (PrepareNextSource: decoder, resampler, ReplayGain), so the UI
              thread only hands it to the engine.
    * Meta  : full tag read (with cover art) of the track that just
              started, plus the folder cover image when there is no embedded
              cover and the PDF booklet check, so the UI thread does no disk
              access at a track change.

  Safety rules (deliberately simple):
    1. One permanent thread, owned by TPlaybackManager. No FreeOnTerminate
       during normal operation, no Synchronize, no TThread.Queue.
    2. Requests and results are plain records (copies of strings/numbers).
       The worker never touches LCL objects, the queue or the audio engine.
       The one object in a result (Prepared.Source, a new audio source) is
       owned by whoever holds the result and freed when it is dropped.
    3. The UI thread collects results itself (FetchResults, called from
       TPlaybackManager.Update on the 50 ms UI timer).
    4. Every request carries a generation number; the manager ignores results
       whose generation is no longer current.
    5. Each job runs inside try..except, so one bad file cannot stop the thread.
    6. Shutdown waits a limited time. A thread still blocked in the file
       system (e.g. an unreachable network share) is set aside
       (uDriveKeepAlive.SetThreadAside: its file access aborted where
       possible, freed once it has ended); it holds no references to other
       objects.
  =============================================================================}

interface

uses
  Classes, SysUtils, SyncObjs, ALMetadata,
  ALSourceFactory;  // PrepareNextSource

type
  TPlaybackIOJobKind = (iojOpen, iojProbe, iojMeta);

  TPlaybackIOResult = record
    Kind       : TPlaybackIOJobKind;
    Generation : Integer;
    FilePath   : string;
    Found      : Boolean;
    SampleRate : Integer;          // iojProbe only
    Meta       : TAudioMetadata;   // iojMeta only (plain copy, owned by the result)
    // iojProbe only: the next track's source when it was built
    // (Source = nil otherwise). Owned by the result: see FreePreparedNext.
    Prepared   : TPreparedNext;
  end;
  TPlaybackIOResults = array of TPlaybackIOResult;

  { TPlaybackIOWorker }

  TPlaybackIOWorker = class(TThread)
  private
    FLock         : SyncObjs.TCriticalSection;
    FWakeEvent    : SyncObjs.TEvent;

    // Pending requests (one slot per kind, newest wins), guarded by FLock
    FOpenPending  : Boolean;
    FOpenGen      : Integer;
    FOpenPath     : string;
    FOpenDelayMs  : Integer;

    FProbePending : Boolean;
    FProbeGen     : Integer;
    FProbePath    : string;
    // Build the probed track's source (see RequestProbe)
    FProbePrepare : Boolean;
    FProbeParams  : TNextPrepareParams;
    FProbeCurRate : Integer;
    FProbeCurDSD  : Boolean;

    FMetaPending  : Boolean;
    FMetaGen      : Integer;
    FMetaPath     : string;

    // Finished results, guarded by FLock
    FResults      : TPlaybackIOResults;

    function  IsOpenSuperseded(AGen: Integer): Boolean;
    procedure AddResult(var AResult: TPlaybackIOResult);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;

    // UI thread
    procedure RequestOpen(AGeneration: Integer; const AFilePath: string; APreDelayMs: Integer);
    // APrepare = also build the track's source with AParams when
    // it can follow the current track gaplessly: same DSD / PCM kind
    // (ACurrentIsDSD) and the same sample rate (ACurrentRate; 0 = not known
    // yet, then it is built anyway and the UI thread checks the rate)
    procedure RequestProbe(AGeneration: Integer; const AFilePath: string;
      APrepare: Boolean; const AParams: TNextPrepareParams;
      ACurrentRate: Integer; ACurrentIsDSD: Boolean);
    procedure RequestMeta(AGeneration: Integer; const AFilePath: string);
    procedure CancelAll;
    function  FetchResults(out AResults: TPlaybackIOResults): Boolean;

    // Stops the thread; returns False if it did not finish within ATimeoutMs
    function  Shutdown(ATimeoutMs: Cardinal): Boolean;
  end;

implementation

uses
  AuAudioTypes, Windows, uAppConsts, uMetaUtils, uDriveKeepAlive, uAudioUtils;

// Frees the prepared sources of AResults (nil is fine)
procedure FreeResultSources(var AResults: TPlaybackIOResults);
var
  I: Integer;
begin
  for I := 0 to High(AResults) do
    FreePreparedNext(AResults[I].Prepared);
end;

const
  MAX_FOLDER_COVER_BYTES = 15 * 1024 * 1024;  // same ceiling as embedded covers

// Worker thread: tags + cover of the started track, the folder cover (only
// without an embedded cover) and the PDF check. Plain file access only; no LCL.
function ReadTrackInfo(const APath: string): TAudioMetadata;
var
  CoverPath : string;
  FS        : TFileStream;
  Pdfs      : TStringList;
begin
  Result := ReadTrackMetadata(APath, True);

  if (not Result.HasCover) or (Length(Result.CoverData) = 0) then
  begin
    CoverPath := FindCoverArt(APath);
    if CoverPath <> '' then
    begin
      try
        FS := TFileStream.Create(LongPath(CoverPath), fmOpenRead or fmShareDenyWrite);
        try
          if (FS.Size > 0) and (FS.Size <= MAX_FOLDER_COVER_BYTES) then
          begin
            SetLength(Result.FolderCoverData, FS.Size);
            FS.ReadBuffer(Result.FolderCoverData[0], FS.Size);
          end;
        finally
          FS.Free;
        end;
      except
        SetLength(Result.FolderCoverData, 0);
      end;
    end;
  end;

  // The booklets the viewer finds (also in Scans / Artwork sub
  // folders and next to a disc folder), not only a PDF beside the track
  Result.FolderHasPDF := False;
  Pdfs := TStringList.Create;
  try
    try
      FindBooklets(ExtractFileDir(APath), Pdfs);
      Result.FolderHasPDF := Pdfs.Count > 0;
    except
      Result.FolderHasPDF := False;
    end;
  finally
    Pdfs.Free;
  end;

  Result.FolderInfoValid := True;
end;

{ TPlaybackIOWorker }

constructor TPlaybackIOWorker.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Priority        := tpLower;

  FLock         := SyncObjs.TCriticalSection.Create;
  FWakeEvent    := SyncObjs.TEvent.Create(nil, False, False, '');  // auto-reset
  FOpenPending  := False;
  FProbePending := False;
  FMetaPending  := False;
  SetLength(FResults, 0);

  Start;
end;

destructor TPlaybackIOWorker.Destroy;
begin
  // Normally Shutdown has already been called; make sure the thread is gone
  // before the synchronization objects are freed. (A worker that
  // did not stop in time is set aside, uDriveKeepAlive.SetThreadAside, and
  // freed only after its thread has ended, so Finished is True then.)
  // "not Suspended" as in TThread.Destroy: when the
  // constructor fails before Start, the thread never ran and WaitFor would
  // wait forever.
  if (not Finished) and (not Suspended) then
  begin
    Terminate;
    if Assigned(FWakeEvent) then
      FWakeEvent.SetEvent;
    WaitFor;
  end;

  // Sources built for results nobody collected
  FreeResultSources(FResults);

  FWakeEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPlaybackIOWorker.Shutdown(ATimeoutMs: Cardinal): Boolean;
begin
  Terminate;
  CancelAll;
  FWakeEvent.SetEvent;
  Result := Windows.WaitForSingleObject(Handle, ATimeoutMs) = WAIT_OBJECT_0;
end;

procedure TPlaybackIOWorker.RequestOpen(AGeneration: Integer; const AFilePath: string;
  APreDelayMs: Integer);
begin
  FLock.Enter;
  try
    FOpenPending := True;
    FOpenGen     := AGeneration;
    FOpenPath    := AFilePath;
    UniqueString(FOpenPath);
    FOpenDelayMs := APreDelayMs;
  finally
    FLock.Leave;
  end;
  FWakeEvent.SetEvent;
end;

procedure TPlaybackIOWorker.RequestProbe(AGeneration: Integer; const AFilePath: string;
  APrepare: Boolean; const AParams: TNextPrepareParams;
  ACurrentRate: Integer; ACurrentIsDSD: Boolean);
begin
  FLock.Enter;
  try
    FProbePending := True;
    FProbeGen     := AGeneration;
    FProbePath    := AFilePath;
    UniqueString(FProbePath);
    FProbePrepare := APrepare;
    FProbeParams  := AParams;
    FProbeCurRate := ACurrentRate;
    FProbeCurDSD  := ACurrentIsDSD;
  finally
    FLock.Leave;
  end;
  FWakeEvent.SetEvent;
end;

procedure TPlaybackIOWorker.RequestMeta(AGeneration: Integer; const AFilePath: string);
begin
  FLock.Enter;
  try
    FMetaPending := True;
    FMetaGen     := AGeneration;
    FMetaPath    := AFilePath;
    UniqueString(FMetaPath);
  finally
    FLock.Leave;
  end;
  FWakeEvent.SetEvent;
end;

procedure TPlaybackIOWorker.CancelAll;
begin
  FLock.Enter;
  try
    FOpenPending  := False;
    FProbePending := False;
    FMetaPending  := False;
    FreeResultSources(FResults);
    SetLength(FResults, 0);
  finally
    FLock.Leave;
  end;
end;

function TPlaybackIOWorker.FetchResults(out AResults: TPlaybackIOResults): Boolean;
begin
  FLock.Enter;
  try
    AResults := FResults;
    SetLength(FResults, 0);   // AResults keeps its own reference to the data
  finally
    FLock.Leave;
  end;
  Result := Length(AResults) > 0;
end;

// Worker thread: a newer open request (or CancelAll) makes the running one
// obsolete, so its remaining retries are skipped.
function TPlaybackIOWorker.IsOpenSuperseded(AGen: Integer): Boolean;
begin
  if Terminated then
    Exit(True);
  FLock.Enter;
  try
    Result := FOpenPending and (FOpenGen <> AGen);
  finally
    FLock.Leave;
  end;
end;

// var: the result list takes over AResult.Prepared.Source (the
// caller drops its copy); when it is not added, its source is freed here
procedure TPlaybackIOWorker.AddResult(var AResult: TPlaybackIOResult);
begin
  if Terminated then
  begin
    FreePreparedNext(AResult.Prepared);
    Exit;
  end;
  FLock.Enter;
  try
    SetLength(FResults, Length(FResults) + 1);
    FResults[High(FResults)] := AResult;
    UniqueString(FResults[High(FResults)].FilePath);
  finally
    FLock.Leave;
  end;
  AResult.Prepared.Source := nil;
end;

procedure TPlaybackIOWorker.Execute;
var
  HaveJob : Boolean;
  Kind    : TPlaybackIOJobKind;
  Gen     : Integer;
  Path    : string;
  DelayMs : Integer;
  Res     : TPlaybackIOResult;
  Retry   : Integer;
  Meta    : TAudioMetadata;
  // Probe: build the source as well (copies taken under FLock)
  WantPrep   : Boolean;
  PrepParams : TNextPrepareParams;
  CurRate    : Integer;
  CurDSD     : Boolean;
begin
  while not Terminated do
  begin
    WantPrep   := False;
    PrepParams := Default(TNextPrepareParams);
    CurRate    := 0;
    CurDSD     := False;

    // ---- Take one job: opening a track first, then the started track's info
    // (its sample rate is needed by the gapless probe), then the probe ----
    HaveJob := False;
    Kind    := iojOpen;
    Gen     := 0;
    DelayMs := 0;
    Path    := '';

    FLock.Enter;
    try
      if FOpenPending then
      begin
        HaveJob      := True;
        Kind         := iojOpen;
        Gen          := FOpenGen;
        Path         := FOpenPath;
        DelayMs      := FOpenDelayMs;
        FOpenPending := False;
      end
      else if FMetaPending then
      begin
        HaveJob      := True;
        Kind         := iojMeta;
        Gen          := FMetaGen;
        Path         := FMetaPath;
        FMetaPending := False;
      end
      else if FProbePending then
      begin
        HaveJob       := True;
        Kind          := iojProbe;
        Gen           := FProbeGen;
        Path          := FProbePath;
        WantPrep      := FProbePrepare;
        PrepParams    := FProbeParams;
        CurRate       := FProbeCurRate;
        CurDSD        := FProbeCurDSD;
        FProbePending := False;
        FProbeParams  := Default(TNextPrepareParams);
      end;
      UniqueString(Path);
    finally
      FLock.Leave;
    end;

    if not HaveJob then
    begin
      FWakeEvent.WaitFor(INFINITE);
      Continue;
    end;

    Res            := Default(TPlaybackIOResult);
    Res.Kind       := Kind;
    Res.Generation := Gen;
    Res.FilePath   := Path;
    Res.Found      := False;
    Res.SampleRate := 0;

    // ---- Run it; never let an exception escape ----
    try
      case Kind of
        iojOpen:
          begin
            // Let the DAC release its exclusive-mode lock first
            if (DelayMs > 0) and (not Terminated) then
              Sleep(DelayMs);

            // The 3-strike retry loop for sleeping mechanical / network drives
            for Retry := 1 to DRIVE_WAKE_RETRIES do
            begin
              if IsOpenSuperseded(Gen) then
                Break;
              if FileExists(LongPath(Path)) then
              begin
                Res.Found := True;
                // FileExists is answered from Windows' folder
                // cache, also while the drive sleeps. Read the start of the
                // file for real, so the drive spins up here ("Opening...")
                // and not later in the audio thread.
                if not IsOpenSuperseded(Gen) then
                  WakeFile(Path);
                Break;
              end;
              Sleep(DRIVE_WAKE_RETRY_MS);
            end;

            if IsOpenSuperseded(Gen) then
              Continue;   // Obsolete: report nothing
          end;

        iojProbe:
          begin
            Res.Found := FileExists(LongPath(Path));
            if Res.Found and (not Terminated) then
            begin
              Meta           := ReadTrackMetadata(Path, False);
              Res.SampleRate := Meta.SampleRate;

              // Build the source too when the track can follow the
              // current one gaplessly (the same test as ApplyGaplessProbe), so
              // the UI thread does no disk access at the change. A failure
              // leaves Prepared.Source nil: the UI thread then tries itself.
              if WantPrep and (not Terminated) and
                 (IsDSDFile(Path) = CurDSD) and
                 ((CurRate = 0) or (Meta.SampleRate = CurRate)) then
                PrepareNextSource(PrepParams, Path, Res.Prepared);
            end;
          end;

        iojMeta:
          begin
            if not Terminated then
            begin
              Res.Meta  := ReadTrackInfo(Path);
              Res.Found := True;
            end;
          end;
      end;
    except
      Res.Found := False;
      Res.Meta  := Default(TAudioMetadata);
      FreePreparedNext(Res.Prepared);
    end;

    AddResult(Res);
    // Drop this thread's references to the result data (cover bytes) now
    Res  := Default(TPlaybackIOResult);
    Meta := Default(TAudioMetadata);
  end;
end;

end.
