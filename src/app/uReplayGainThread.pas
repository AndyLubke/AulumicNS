unit uReplayGainThread;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uReplayGainThread
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Thread used for background ReplayGain scanning: measures the loudness of
  the albums it is given and reports through events, on the
  main thread (Synchronize): OnProgress for the progress, OnResults hands
  over the results of each album (TRGScanResult, uReplayGainScan). After it
  has ended: HealedFiles, StaleFileCount. It does not know the window that
  started it; Detach stops the events when that
  window goes away. Covered by Tests\TestReplayGainThread.pas.

  The loudness is measured by the built-in EBU R128 meter
  (AuLoudness): one TAuLoudnessMeter per
  track, the album loudness over the blocks of all its tracks (as
  ebur128_loudness_global_multiple does).
  The tracks of an album are measured on ThreadCount workers (TRGTrackWorker)
  at the same time; a worker never calls Synchronize or the log, the scan
  thread reports for them.
  =============================================================================}

interface

uses
  Classes, AuLoudness, uLibraryManager, uLibraryTypes,
  uReplayGainScan;  // TRGAlbumGroups, TRGScanResult, GainFromLoudness

type
  // The meters of an album's tracks
  TLoudnessMeterArray = array of TAuLoudnessMeter;

  // The progress of a scan
  TRGProgress = record
    AlbumText  : string;   // the album being scanned
    TrackText  : string;   // its track (file name) or what happens
    StatusText : string;   // e.g. album x of y, track x of y
    TrackPct   : Integer;  // 0..100, the current track
    AlbumPct   : Integer;  // 0..100, over all albums
    CurAlbum   : Integer;  // album x of y (the main window's status label)
    TotalAlbums: Integer;
  end;

  TRGProgressEvent = procedure(Sender: TObject; const AProgress: TRGProgress) of object;
  // AResults holds PRGScanResult items. The handler takes every item over
  // (adds it to its own list, disposes it later) and leaves AResults as it
  // is; the thread then clears it.
  TRGResultsEvent = procedure(Sender: TObject; AResults: TList) of object;

  { TReplayGainThread }
  TReplayGainThread = class(TThread)
  private
    FLibraryManager      : TLibraryManager;
    FAlbumsToScan        : TRGAlbumGroups;  // owned
    FHarvestedResults    : TList;
    FForceOverwrite      : Boolean;
    FTotalHarvestedCount : Integer;

    // How many tracks of an album are measured at the same
    // time (1 .. RG_MAX_THREADS; the decode buffers belong to the workers)
    FThreadCount         : Integer;

    FLogMsg              : string;
    FLogIsError          : Boolean;

    // Events and results (the thread knows no window)
    FProgress            : TRGProgress;  // filled by the thread, sent by PushUIProgress
    FOnProgress          : TRGProgressEvent;
    FOnResults           : TRGResultsEvent;
    FDetached            : Boolean;
    FHealedFiles         : TStringList;
    FStaleFileCount      : Integer;

    procedure SyncAddLog;
    procedure LogSafe(const Msg: string; IsError: Boolean = False);

    procedure PushUIProgress;
    procedure PushHarvest;

    // Album name resolution, tag checking, and meter cleanup
    function  ResolveAlbumName(AlbumFiles, MissingInAlbum: TStringList): string;
    function  IsAlbumAlreadyScanned(AlbumFiles: TStringList; const AlbumName: string;
                                    AlbIdx: Integer; var LastTick: QWord; ANoAlbum: Boolean): Boolean;
    function  GroupHasNoAlbumTag(AlbumFiles: TStringList): Boolean;
    procedure FreeMeters(var States: TLoudnessMeterArray);
    procedure SetThreadCount(AValue: Integer);
  protected
    procedure Execute; override;
  public
    // Owns AAlbums from here on (also when Create fails)
    constructor Create(AAlbums: TRGAlbumGroups; AForceOverwrite: Boolean;
                       ALibraryManager: TLibraryManager);
    destructor Destroy; override;

    // Main thread: the receiver goes away. No more events or log lines; the
    // results not handed over yet are freed with the thread.
    procedure Detach;

    property LibraryManager: TLibraryManager read FLibraryManager write FLibraryManager;
    // Set before Start. The albums are scanned one
    // after the other; the tracks of an album are measured by this many
    // threads at once. The results and their order do not depend on it.
    property ThreadCount: Integer read FThreadCount write SetThreadCount;
    // Set before Start; called on the main thread
    property OnProgress: TRGProgressEvent read FOnProgress write FOnProgress;
    property OnResults: TRGResultsEvent read FOnResults write FOnResults;
    // After the thread has ended: the files of the albums that already had
    // ReplayGain tags (the library gets their flags), the files not found
    property HealedFiles: TStringList read FHealedFiles;
    property StaleFileCount: Integer read FStaleFileCount;
  end;

implementation

uses
  AuAudioTypes, Windows, SysUtils, Math, uAppConsts, ALMetadata, ALReaderFLAC,
  ALReaderWAV, ALReaders,
  uAudioUtils, uOSUtils, AuLog, uAppStrings;  // AuLog: AddLog

const
  INV_PCM16_FLT = 1.0 / 32768.0;
  INV_PCM24_FLT = 1.0 / 8388608.0;
  INV_PCM32_FLT = 1.0 / 2147483648.0;
  CHUNK_FRAMES  = 8192;

type
  // The tracks of one album, shared by the threads that
  // measure them. A worker takes the next index (Next, interlocked) and
  // writes only the slots of that index; the scan thread reads Done, Started
  // and Pct for the progress and takes the rest when all workers have ended.
  TRGAlbumWork = class
  public
    Files   : TStringList;          // the album's files (not owned)
    Next    : LongInt;              // the next track to take
    Done    : LongInt;              // tracks finished (measured or failed)
    Started : LongInt;              // the track taken last
    Cancel  : LongBool;             // the scan was stopped
    Meters  : TLoudnessMeterArray;  // nil: the track failed
    Peaks   : array of Double;
    Pct     : array of LongInt;     // 0 .. 100 per track
    Logs    : array of string;      // an error line per track ('' = none)
    constructor Create(AFiles: TStringList);
    destructor Destroy; override;   // frees the meters nobody took
  end;

  TRGTrackWorker = class(TThread)
  private
    FWork        : TRGAlbumWork;
    // Reused for all tracks this worker measures
    FReadBuffer  : array of Byte;
    FFloatBuffer : array of Single;
    function Measure(AIndex: Integer): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AWork: TRGAlbumWork);
  end;

constructor TReplayGainThread.Create(AAlbums: TRGAlbumGroups; AForceOverwrite: Boolean;
  ALibraryManager: TLibraryManager);
begin
  // Taken over first, so Destroy frees it even when
  // something below raises
  FAlbumsToScan := AAlbums;
  if not Assigned(FAlbumsToScan) then
    FAlbumsToScan := TRGAlbumGroups.Create;

  inherited Create(True);
  FreeOnTerminate  := False;
  Priority         := tpLower;

  FForceOverwrite     := AForceOverwrite;
  FLibraryManager      := ALibraryManager;
  FDetached            := False;

  FTotalHarvestedCount := 0;
  FStaleFileCount      := 0;
  FThreadCount         := 1;
  FHealedFiles         := TStringList.Create;
  FHarvestedResults    := TList.Create;
end;

destructor TReplayGainThread.Destroy;
var
  I: Integer;
begin
  FAlbumsToScan.Free;  // frees the album file lists too

  if Assigned(FHarvestedResults) then
  begin
    for I := 0 to FHarvestedResults.Count - 1 do
      Dispose(PRGScanResult(FHarvestedResults[I]));
    FHarvestedResults.Free;
  end;

  FHealedFiles.Free;
  inherited Destroy;
end;

procedure TReplayGainThread.SyncAddLog;
begin
  AddLog(FLogMsg, False, FLogIsError);
end;

procedure TReplayGainThread.SetThreadCount(AValue: Integer);
begin
  FThreadCount := EnsureRange(AValue, 1, RG_MAX_THREADS);
end;

procedure TReplayGainThread.Detach;
begin
  FOnProgress := nil;
  FOnResults  := nil;
  FDetached   := True;
end;

procedure TReplayGainThread.LogSafe(const Msg: string; IsError: Boolean = False);
begin
  // Only skip Synchronize if the receiver was detached;
  // allows normal user-aborted scans (where Terminated = True) to log!
  if FDetached then
    Exit;
  FLogMsg     := Msg;
  FLogIsError := IsError;
  Synchronize(@SyncAddLog);
end;

// Main thread (Synchronize)
procedure TReplayGainThread.PushUIProgress;
begin
  if Terminated or (not Assigned(FOnProgress)) then
    Exit;
  FOnProgress(Self, FProgress);
end;

// Main thread (Synchronize). The receiver takes the
// results over
procedure TReplayGainThread.PushHarvest;
begin
  if Terminated or (not Assigned(FOnResults)) then
    Exit;

  FOnResults(Self, FHarvestedResults);

  Inc(FTotalHarvestedCount, FHarvestedResults.Count);
  FHarvestedResults.Clear;
end;

// =============================================================================
// Fetches Album Name from RAM first, or disk WITHOUT cover art
// =============================================================================
function TReplayGainThread.ResolveAlbumName(AlbumFiles, MissingInAlbum: TStringList): string;
var
  LibMgr: TLibraryManager;
  LibTrack: TTrackInfo;
  Meta: TAudioMetadata;
begin
  Result := '';
  LibMgr := FLibraryManager;

  // 1. Fast path: Ask LibraryManager in RAM (thread-safe)
  if (AlbumFiles.Count > 0) and Assigned(LibMgr) and
     LibMgr.TryGetTrack(AlbumFiles[0], LibTrack) then
    Result := Trim(LibTrack.Album);

  // 2. Fallback: Read text tags only (without the
  // cover: ReadTrackTextTags)
  if (Result = '') and (AlbumFiles.Count > 0) then
  begin
    Meta   := ReadTrackTextTags(AlbumFiles[0]);
    Result := Trim(Meta.Album);
  end;

  // 3. Final fallback: Folder name
  if Result = '' then
  begin
    if AlbumFiles.Count > 0 then
      Result := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(AlbumFiles[0])))
    else if MissingInAlbum.Count > 0 then
      Result := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(MissingInAlbum[0])));
  end;
end;

// =============================================================================
// Thread-safe check for existing ReplayGain tags on disk/RAM
// =============================================================================
// The files of a group have no album tag (a group is one
// folder + album artist + album, so the first file answers for all): the
// library's record says so when it has a real album name (no disk access for
// the albums, which are nearly all); the library keeps "Unknown Album" for an
// empty tag, so then - and for a file outside the library - the file's own
// tag decides
function TReplayGainThread.GroupHasNoAlbumTag(AlbumFiles: TStringList): Boolean;
var
  LibTrack: TTrackInfo;
  Name: string;
begin
  Result := False;
  if AlbumFiles.Count = 0 then
    Exit;
  LibTrack := Default(TTrackInfo);
  if Assigned(FLibraryManager) and FLibraryManager.TryGetTrack(AlbumFiles[0], LibTrack) then
  begin
    Name := Trim(LibTrack.Album);
    if (Name <> '') and not SameText(Name, LBL_UNKNOWN_ALBUM) then
      Exit(False);
  end;
  Result := Trim(ReadTrackTextTags(AlbumFiles[0]).Album) = '';
end;

function TReplayGainThread.IsAlbumAlreadyScanned(AlbumFiles: TStringList;
  const AlbumName: string; AlbIdx: Integer; var LastTick: QWord; ANoAlbum: Boolean): Boolean;
var
  J: Integer;
  HasRGInRAM: Boolean;
  LibMgr: TLibraryManager;
  LibTrack: TTrackInfo;
  Meta: TAudioMetadata;
  UpperTags: string;
begin
  Result := False;
  if FForceOverwrite or (AlbumFiles.Count = 0) then
    Exit;

  LibMgr := FLibraryManager;
  LibTrack := Default(TTrackInfo);  // no warning in the release build

  for J := 0 to AlbumFiles.Count - 1 do
  begin
    if Terminated then
      Exit(False);

    // 1. Thread-safe RAM check
    HasRGInRAM := Assigned(LibMgr) and LibMgr.TryGetTrack(AlbumFiles[J], LibTrack) and
                  LibTrack.HasReplayGain;

    if HasRGInRAM then
      Continue;

    // 2. Throttled UI update
    if GetTickCount64 - LastTick > THREAD_DELAY_MS then
    begin
      LastTick := GetTickCount64;
      FProgress.AlbumText  := AlbumName;
      FProgress.TrackText  := ExtractFileName(AlbumFiles[J]);
      FProgress.StatusText := SafeFormat(FMT_STATUS_RG_CHECKING, [J + 1, AlbumFiles.Count]);
      Synchronize(@PushUIProgress);
    end;

    // 3. Physical tag check (without extracting embedded cover art)
    // A track counts as scanned only when it has both a track
    // gain and an album gain (the same rule as the library scan): if any
    // ReplayGain or R128 tag were enough, a file with only a track gain
    // would never get an album gain from a normal scan.
    // Tracks without an album tag (ANoAlbum) get no album
    // gain: their track gain is all there is to find
    Meta      := ReadTrackTextTags(AlbumFiles[J]);
    UpperTags := UpperCase(Meta.AllTags);
    if (Pos(TAG_RG_TRACK_GAIN, UpperTags) = 0) or
       ((not ANoAlbum) and (Pos(TAG_RG_ALBUM_GAIN, UpperTags) = 0)) then
      Exit(False);
  end;

  if Terminated then
    Exit(False);

  // All tracks in the album already have ReplayGain tags! Mark them healed.
  Result := True;
  for J := 0 to AlbumFiles.Count - 1 do
    FHealedFiles.Add(AlbumFiles[J]);

  if GetTickCount64 - LastTick > 40 then
  begin
    LastTick := GetTickCount64;
    FProgress.AlbumText  := AlbumName;
    FProgress.TrackText  := STATUS_RG_SKIPPING;
    FProgress.StatusText := SafeFormat(FMT_STATUS_RG_FAST_FORWARD, [AlbIdx + 1, FAlbumsToScan.Count]);
    FProgress.TrackPct  := 100;

    if FAlbumsToScan.Count > 0 then
      FProgress.AlbumPct := ((AlbIdx + 1) * 100) div FAlbumsToScan.Count
    else
      FProgress.AlbumPct := 0;

    Synchronize(@PushUIProgress);
  end;
end;

// =============================================================================
// Frees the loudness meters of an album
// =============================================================================
procedure TReplayGainThread.FreeMeters(var States: TLoudnessMeterArray);
var
  J: Integer;
begin
  for J := 0 to High(States) do
    FreeAndNil(States[J]);
  SetLength(States, 0);
end;

{ TRGAlbumWork }

constructor TRGAlbumWork.Create(AFiles: TStringList);
begin
  inherited Create;
  Files := AFiles;
  SetLength(Meters, AFiles.Count);
  SetLength(Peaks, AFiles.Count);
  SetLength(Pct, AFiles.Count);
  SetLength(Logs, AFiles.Count);
end;

destructor TRGAlbumWork.Destroy;
var
  J: Integer;
begin
  for J := 0 to High(Meters) do
    FreeAndNil(Meters[J]);
  inherited Destroy;
end;

{ TRGTrackWorker }

constructor TRGTrackWorker.Create(AWork: TRGAlbumWork);
begin
  FWork := AWork;
  inherited Create(True);
  FreeOnTerminate := False;
  Priority        := tpLower;
end;

procedure TRGTrackWorker.Execute;
var
  I: Integer;
begin
  NameThisThread('ReplayGain scan');
  while not FWork.Cancel do
  begin
    I := InterlockedIncrement(FWork.Next) - 1;
    if I >= FWork.Files.Count then
      Break;
    FWork.Started := I;
    Measure(I);
    InterlockedIncrement(FWork.Done);
  end;
end;

// One track: decoded and fed
// to its meter (FWork.Meters[AIndex], nil when it failed), its peak, its
// progress (FWork.Pct) and, when something went wrong, a line for the log
// (FWork.Logs). Nothing here touches the main thread: several of these run
// at the same time, and the scan thread reports for them.
function TRGTrackWorker.Measure(AIndex: Integer): Boolean;
var
  FlacReader         : TFlacReader;
  WavReader          : TWavReader;
  DsdSource          : TDsdToPcmSource;
  BytesRead, FramesRead, I, Channels, SampleRate, BitsPerSample, SampleCount, FrameSize, ReqBytes, ReqSamples: Integer;
  TotalFramesDecoded : Int64;
  ExpectedFrames     : Int64;
  P16                : PSmallInt;
  P24                : PByte;
  P32                : PInteger;
  Sample32           : Integer;
  ProgressVal        : Double;
  LastThermalTick,
  CurrentTick        : QWord;
  FileType           : Integer;
  FilePath           : string;
  OutState           : TAuLoudnessMeter;
  OutPeak            : Double;
begin
  FilePath           := FWork.Files[AIndex];
  Result             := False;
  OutState           := nil;
  OutPeak            := 0.0;
  TotalFramesDecoded := 0;
  ExpectedFrames     := 0;

  FlacReader := nil;
  WavReader  := nil;
  DsdSource  := nil;
  FileType   := 0;

  if not FileExists(LongPath(FilePath)) then
    Exit;

  // The readers take the UTF-8 path as it is
  LastThermalTick := GetTickCount64;

  try
    try
      // 1. Initialize the correct decoder object
      if IsFlacFile(FilePath) then
      begin
        FileType      := 1;
        FlacReader    := TFlacReader.Create(FilePath);
        Channels      := FlacReader.Channels;
        SampleRate    := FlacReader.SampleRate;
        BitsPerSample := FlacReader.BitsPerSample;
      end
      else if IsWavFile(FilePath) then
      begin
        FileType      := 2;
        WavReader     := TWavReader.Create(FilePath);
        Channels      := WavReader.Channels;
        SampleRate    := WavReader.SampleRate;
        BitsPerSample := WavReader.BitsPerSample;
      end
      else if IsDSDFile(FilePath) then
      begin
        FileType      := 3;
        DsdSource     := TDsdToPcmSource.Create(FilePath, 0, True);
        Channels      := DsdSource.GetChannels;
        SampleRate    := DsdSource.GetSampleRate;
        BitsPerSample := DsdSource.GetBitsPerSample;
      end
      else
        Exit;

      // 2. Validate format
      if (Channels <= 0) or (Channels > 8) or (SampleRate <= 0) or
         (SampleRate > 768000) or (not (BitsPerSample in [16, 24, 32])) then
        Exit;

      FrameSize := Channels * (BitsPerSample div 8);
      if FrameSize <= 0 then
        Exit;

      // Expected frame count from the container header (0 = unknown, e.g. streamed FLAC)
      if FileType = 1 then
        ExpectedFrames := FlacReader.DataSize div FrameSize
      else if FileType = 2 then
        ExpectedFrames := WavReader.DataSize div FrameSize
      else
        ExpectedFrames := Round(DsdSource.GetDuration * SampleRate);

      // The built-in meter (integrated loudness + sample peak)
      OutState := TAuLoudnessMeter.Create(SampleRate, Channels);

      // Only grow reusable buffers if needed
      ReqBytes   := CHUNK_FRAMES * FrameSize;
      ReqSamples := CHUNK_FRAMES * Channels;
      if Length(FReadBuffer) < ReqBytes then
        SetLength(FReadBuffer, ReqBytes);
      if Length(FFloatBuffer) < ReqSamples then
        SetLength(FFloatBuffer, ReqSamples);

      // 3. The Unified Processing Loop
      while not FWork.Cancel do
      begin
        if FileType = 1 then
          BytesRead := FlacReader.ReadData(@FReadBuffer[0], ReqBytes)
        else if FileType = 2 then
          BytesRead := WavReader.ReadData(@FReadBuffer[0], ReqBytes)
        else
          BytesRead := DsdSource.ReadData(@FReadBuffer[0], ReqBytes);

        if BytesRead < FrameSize then
          Break;

        FramesRead  := BytesRead div FrameSize;
        SampleCount := FramesRead * Channels;

        if BitsPerSample = 16 then
        begin
          P16 := PSmallInt(@FReadBuffer[0]);
          for I := 0 to SampleCount - 1 do
          begin
            FFloatBuffer[I] := P16^ * INV_PCM16_FLT;
            Inc(P16);
          end;
        end
        else if BitsPerSample = 24 then
        begin
          P24 := PByte(@FReadBuffer[0]);
          for I := 0 to SampleCount - 1 do
          begin
            Sample32        := (P24[0]) or (P24[1] shl 8) or (ShortInt(P24[2]) shl 16);
            FFloatBuffer[I] := Sample32 * INV_PCM24_FLT;
            Inc(P24, 3);
          end;
        end
        else if BitsPerSample = 32 then
        begin
          P32 := PInteger(@FReadBuffer[0]);
          for I := 0 to SampleCount - 1 do
          begin
            FFloatBuffer[I] := P32^ * INV_PCM32_FLT;
            Inc(P32);
          end;
        end;

        OutState.AddSingle(@FFloatBuffer[0], FramesRead);

        Inc(TotalFramesDecoded, FramesRead);

        if FWork.Cancel then
          Break;

        CurrentTick := GetTickCount64;

        if CurrentTick - LastThermalTick > THREAD_DELAY_MS then
        begin
          LastThermalTick := CurrentTick;
          Sleep(RG_THERMAL_PAUSE_MS);
        end;

        if FileType = 1 then
          ProgressVal := FlacReader.GetProgress
        else if FileType = 2 then
          ProgressVal := WavReader.GetProgress
        else
          ProgressVal := DsdSource.GetProgress;
        FWork.Pct[AIndex] := EnsureRange(Round(ProgressVal * 100.0), 0, 100);
      end;
      // Reject empty or failed decodes (0 frames decoded)
      // so they are marked as 'Decode error / unsupported' rather than '0.00 dB'!
      // Also reject decodes that stopped well short of the
      // length declared in the header (corrupt FLAC section, truncated file),
      // so a partial loudness measurement is never saved as the track's gain.
      if (not FWork.Cancel) and (TotalFramesDecoded > 0) and (ExpectedFrames > 0) and
         (TotalFramesDecoded < (ExpectedFrames * 9) div 10) then
      begin
        FWork.Logs[AIndex] := SafeFormat(FMT_LOG_RG_PARTIAL_DECODE,
                       [ExtractFileName(FilePath), TotalFramesDecoded, ExpectedFrames]);
        Exit;
      end;

      if (not FWork.Cancel) and (TotalFramesDecoded > 0) then
      begin
        // The meter's sample peak (the largest of the channels)
        OutPeak := OutState.Peak;
        if IsNan(OutPeak) or IsInfinite(OutPeak) then
          OutPeak := 0.0;
        Result := True;
      end;
    except
      on E: Exception do
      begin
        FWork.Logs[AIndex] := SafeFormat(FMT_LOG_RG_FILE_ERROR,
                       [ExtractFileName(FilePath), E.Message]);
        Result := False;
      end;
      else
      begin
        FWork.Logs[AIndex] := SafeFormat(FMT_LOG_RG_FILE_ERROR,
                       [ExtractFileName(FilePath), LOG_RG_ERROR_UNKNOWN]);
        Result := False;
      end;
    end;
  finally
    if not Result then
      FreeAndNil(OutState);
    FWork.Meters[AIndex] := OutState;
    FWork.Peaks[AIndex]  := OutPeak;
    if Result then
      FWork.Pct[AIndex] := 100;

    if Assigned(FlacReader) then
      FlacReader.Free;
    if Assigned(WavReader) then
      WavReader.Free;
    if Assigned(DsdSource) then
      DsdSource.Free;
  end;
end;

procedure TReplayGainThread.Execute;
var
  I, J           : Integer;
  AlbumFiles     : TStringList;
  MissingInAlbum : TStringList;
  States         : TLoudnessMeterArray;
  CleanStates    : TLoudnessBlockSets;  // the blocks of the album
  TrkLoud,
  TrkPeaks       : array of Double;
  AlbLoud,
  AlbPeak,
  AlbGainCalc,
  TrkGainCalc    : Double;
  ValidCount,
  Idx            : Integer;
  AlbumIncomplete: Boolean;
  NoAlbum: Boolean;
  AlbumName      : string;
  PRes           : PRGScanResult;
  LastTick       : QWord;
  Work           : TRGAlbumWork;

  // The tracks of the album on up to FThreadCount worker
  // threads; this thread waits for them, reports the progress every 40 ms
  // and passes a Stop on. Returns when all workers have ended.
  procedure MeasureTracks(AWork: TRGAlbumWork; const AAlbumName: string; AAlbIdx: Integer);
  var
    Workers : array of TRGTrackWorker;
    Handles : array of THandle;
    N, K, Cur, DoneN, Sum, Count: Integer;
    AllDone : Boolean;
  begin
    Count := AWork.Files.Count;
    if Count = 0 then
      Exit;
    N := EnsureRange(FThreadCount, 1, Count);
    Workers := nil;
    Handles := nil;
    SetLength(Workers, N);
    SetLength(Handles, N);
    try
      try
        for K := 0 to N - 1 do
        begin
          Workers[K] := TRGTrackWorker.Create(AWork);
          Handles[K] := Workers[K].Handle;
          Workers[K].Start;
        end;

        repeat
          AllDone := WaitForMultipleObjects(N, PWOHandleArray(@Handles[0]), True, 40) <> WAIT_TIMEOUT;
          if Terminated then
            AWork.Cancel := True
          else
          begin
            Cur   := EnsureRange(AWork.Started, 0, Count - 1);
            DoneN := AWork.Done;
            FProgress.AlbumText := AAlbumName;
            FProgress.TrackText := ExtractFileName(AWork.Files[Cur]);
            if N > 1 then
            begin
              // several tracks at once: the bar shows the album's tracks together
              if Count - DoneN > 1 then
                FProgress.TrackText := SafeFormat(FMT_STATUS_RG_PARALLEL,
                  [FProgress.TrackText, Min(N, Count - DoneN) - 1]);
              Sum := 0;
              for K := 0 to Count - 1 do
                Inc(Sum, AWork.Pct[K]);
              FProgress.TrackPct := Sum div Count;
            end
            else
              FProgress.TrackPct := AWork.Pct[Cur];

            if FAlbumsToScan.Count > 0 then
              FProgress.AlbumPct := ((AAlbIdx + 1) * 100) div FAlbumsToScan.Count
            else
              FProgress.AlbumPct := 0;

            FProgress.StatusText := SafeFormat(FMT_STATUS_RG_ANALYZING,
              [AAlbIdx + 1, FAlbumsToScan.Count, Min(DoneN + 1, Count), Count]);
            Synchronize(@PushUIProgress);
          end;
        until AllDone;
      except
        AWork.Cancel := True;   // the workers must end before AWork goes
        raise;
      end;
    finally
      for K := 0 to N - 1 do
        if Workers[K] <> nil then
        begin
          if not Workers[K].Suspended then
            Workers[K].WaitFor;
          Workers[K].Free;
        end;
    end;
  end;

begin
  LastTick    := GetTickCount64;
  States      := nil;
  CleanStates := nil;
  TrkLoud     := nil;
  TrkPeaks    := nil;

  LogSafe(SafeFormat(FMT_LOG_RG_STARTED,
          [FAlbumsToScan.Count, BoolToStr(FForceOverwrite, True)]));

  try
    FStaleFileCount      := 0;
    FTotalHarvestedCount := 0;

    for I := 0 to FAlbumsToScan.Count - 1 do
    begin
      if Terminated then
        Break;

      FProgress.CurAlbum    := I + 1;
      FProgress.TotalAlbums := FAlbumsToScan.Count;

      AlbumFiles := FAlbumsToScan[I];
      if (not Assigned(AlbumFiles)) or (AlbumFiles.Count = 0) then
        Continue;

      MissingInAlbum := TStringList.Create;
      try
        // 1. Separate missing files from valid files
        for J := AlbumFiles.Count - 1 downto 0 do
        begin
          if not FileExists(LongPath(AlbumFiles[J])) then
          begin
            Inc(FStaleFileCount);
            MissingInAlbum.Add(AlbumFiles[J]);
            AlbumFiles.Delete(J);
          end;
        end;

        if (AlbumFiles.Count = 0) and (MissingInAlbum.Count = 0) then
          Continue;

        AlbumName := ResolveAlbumName(AlbumFiles, MissingInAlbum);
        // Loose tracks without an album tag are no album:
        // each gets its track gain, none an album gain
        NoAlbum := GroupHasNoAlbumTag(AlbumFiles);

        if IsAlbumAlreadyScanned(AlbumFiles, AlbumName, I, LastTick, NoAlbum) then
          Continue;

        if NoAlbum then
          LogSafe(SafeFormat(FMT_LOG_RG_NO_ALBUM_TAG, [AlbumFiles.Count,
            ExcludeTrailingPathDelimiter(ExtractFilePath(AlbumFiles[0])),
            ExtractFileName(AlbumFiles[0])]), True);

        SetLength(States, AlbumFiles.Count);
        for J := 0 to High(States) do
          States[J] := nil;

        SetLength(TrkLoud, AlbumFiles.Count);
        SetLength(TrkPeaks, AlbumFiles.Count);

        AlbPeak    := 0.0;
        ValidCount := 0;

        // =====================================================================
        // 2. THE TRACKS, MEASURED BY FThreadCount THREADS
        // =====================================================================
        Work := TRGAlbumWork.Create(AlbumFiles);
        try
          MeasureTracks(Work, AlbumName, I);

          if Terminated then
            Break;

          for J := 0 to AlbumFiles.Count - 1 do
          begin
            if Work.Logs[J] <> '' then
              LogSafe(Work.Logs[J], True);

            States[J]      := Work.Meters[J];   // taken over (nil: the track failed)
            Work.Meters[J] := nil;
            TrkLoud[J]     := -18.0;
            TrkPeaks[J]    := 0.0;

            if States[J] <> nil then
            begin
              // The meter cannot fail; a silent track gives
              // -Infinity LUFS and so 0.00 dB below (GainFromLoudness)
              TrkLoud[J]  := States[J].Loudness;
              TrkPeaks[J] := Work.Peaks[J];
              if TrkPeaks[J] > AlbPeak then
                AlbPeak := TrkPeaks[J];
              Inc(ValidCount);
            end;
          end;
        finally
          Work.Free;
        end;
        // An album gain is only valid when every track of the
        // album was analysed. If a track failed or a file is missing, nothing
        // of this album is offered for saving ('Album Incomplete').
        // Without an album tag there is no album to complete:
        // every track that was analysed is saved (its track gain)
        AlbumIncomplete := (not NoAlbum) and
                           ((ValidCount < AlbumFiles.Count) or (MissingInAlbum.Count > 0));

        // 3. Calculate Album Loudness
        AlbLoud     := -18.0;
        AlbGainCalc := 0.0;
        if (ValidCount > 0) and (not AlbumIncomplete) and (not NoAlbum) then
        begin
          // The gates over the blocks of all tracks together
          SetLength(CleanStates, ValidCount);
          Idx := 0;
          for J := 0 to AlbumFiles.Count - 1 do
          begin
            if States[J] <> nil then
            begin
              CleanStates[Idx] := States[J].Blocks;
              Inc(Idx);
            end;
          end;
          AlbLoud := IntegratedLoudness(CleanStates);
          CleanStates := nil;
          // The rule is in uReplayGainScan (a silent
          // album: 0 dB)
          AlbGainCalc := GainFromLoudness(AlbLoud);
        end
        else if AlbumIncomplete and (ValidCount > 0) then
          LogSafe(SafeFormat(FMT_LOG_RG_ALBUM_INCOMPLETE,
                  [AlbumName, ValidCount, AlbumFiles.Count + MissingInAlbum.Count]), True);

        // 4. Append VALID and CORRUPTED files to the results
        for J := 0 to AlbumFiles.Count - 1 do
        begin
          New(PRes);
          try
            PRes^.FilePath := AlbumFiles[J];
            PRes^.Album    := AlbumName;
            PRes^.Title    := ExtractFileName(AlbumFiles[J]);

            if (States[J] <> nil) and AlbumIncomplete then
            begin
              // Analysed fine, but its album is incomplete: not saved
              PRes^.TrackGain := 0.0;
              PRes^.TrackPeak := 0.0;
              PRes^.AlbumGain := 0.0;
              PRes^.AlbumPeak := 0.0;
              PRes^.Status    := rsAlbumIncomplete;

              FreeAndNil(States[J]);
            end
            else if States[J] <> nil then
            begin
              // The rule is in uReplayGainScan
              TrkGainCalc := GainFromLoudness(TrkLoud[J]);

              PRes^.TrackGain := TrkGainCalc;
              PRes^.TrackPeak := TrkPeaks[J];
              if NoAlbum then
              begin
                PRes^.AlbumGain := 0.0;
                PRes^.AlbumPeak := 0.0;
                PRes^.Status    := rsTrackOnly;
              end
              else
              begin
                PRes^.AlbumGain := AlbGainCalc;
                PRes^.AlbumPeak := AlbPeak;
                PRes^.Status    := rsReadyToSave;
              end;

              FreeAndNil(States[J]);
            end
            else
            begin
              PRes^.TrackGain := 0.0;
              PRes^.TrackPeak := 0.0;
              PRes^.AlbumGain := 0.0;
              PRes^.AlbumPeak := 0.0;
              PRes^.Status    := rsDecodeError;
            end;

            FHarvestedResults.Add(PRes);
          except
            Dispose(PRes);
            raise;
          end;
        end;

        // 5. Append MISSING files to the results
        for J := 0 to MissingInAlbum.Count - 1 do
        begin
          New(PRes);
          try
            PRes^.FilePath  := MissingInAlbum[J];
            PRes^.Album     := AlbumName;
            PRes^.Title     := ExtractFileName(MissingInAlbum[J]);
            PRes^.TrackGain := 0.0;
            PRes^.TrackPeak := 0.0;
            PRes^.AlbumGain := 0.0;
            PRes^.AlbumPeak := 0.0;

            if IsDriveRootMissing(MissingInAlbum[J]) then
              PRes^.Status := rsDriveOffline
            else
              PRes^.Status := rsFileMissing;

            FHarvestedResults.Add(PRes);
          except
            Dispose(PRes);
            raise;
          end;
        end;

        if FHarvestedResults.Count > 0 then
          Synchronize(@PushHarvest);

      finally
        FreeMeters(States);
        MissingInAlbum.Free;
      end;
    end; // End of Album loop

  finally
    FreeMeters(States);

    if Terminated then
      LogSafe(LOG_RG_ABORTED)
    else
      LogSafe(SafeFormat(FMT_LOG_RG_FINISHED,
                     [FTotalHarvestedCount, FStaleFileCount]));
  end;
end;

end.
