unit uLibraryManager;

{$mode ObjFPC}{$H+}

// =============================================================================
// Project:      Aulumic
// Unit Name:    uLibraryManager
// Author:       André Lubke
// Date Created: 08-Jul-26
//
// The backend data layer. Manages the in-memory track dictionary, coordinates
// the background TLibraryScannerThread, and handles committing the physical
// database to disk.
//
// ---> CHANGED (split): the track record and sort functions are in
// uLibraryTypes, the auto-playlist filter in uLibraryQuery and the scanner
// thread in uLibraryScanner. (Aulumic's Library.db line format,
// uLibraryDatabase, is in the Tests folder: only the tests read it.)
//
// ---> AulumicNS: stored in the Aulos format (uDbStore) instead of the
// Library.db text file: a snapshot (library.adb: string pool, library
// folders, virtual folders, tracks) and a journal (library.jnl) of the
// records changed since (UpdateRecord, the ReplayGain flags). SaveDatabase
// writes a new snapshot and starts a new journal, all under the library lock.
// =============================================================================

interface

uses
  Classes, SysUtils, SyncObjs, StrUtils,
  Dialogs, DateUtils, uTagParser, uUserStatsManager, AuDialogs, uDbStore,
  // ---> CHANGED: TTrackInfo, the scan events and the sort / compare
  // functions are in uLibraryTypes now; the scanner thread in uLibraryScanner
  uLibraryTypes, uLibraryScanner;

type
  { TLibraryManager }

  TLibraryManager = class
  private
    FTracks            : TList;
    FTrackDict         : TStringList;
    FOnDatabaseChanged : TNotifyEvent;
    FScanFolders       : TStringList;
    FDatabaseFile      : string;

    // The names of the Artists / Genres / Albums nodes (ValidateCaches).
    // ---> AulumicNS: only the names (their counts, album lists and the folder
    // list were built for every track but never read)
    FArtistSummaryCache : TStringList;
    FGenreSummaryCache  : TStringList;
    FAlbumSummaryCache  : TStringList;
    FCachesValid        : boolean;

    // Virtual folders (.aullink files) of the library: link file -> TStringList
    // of target folders (owned). Filled by the scan, stored in Library.db as
    // ?LINK? lines, so the tree never has to read the link files.
    FLinks                  : TStringList;
    // Links created, edited or deleted while a scan was running: their
    // current state wins over the scan result
    FLinksChangedDuringScan : TStringList;
    // Folder tree of the library, built from the tracks' folders: folder ->
    // TStringList of the names of its subfolders and virtual folders (owned).
    // Only folders with music (somewhere below them) are in it.
    FFolderIndex            : TStringList;
    FFolderIndexValid       : Boolean;
    // Library folders that could not be reached during the last scan
    FUnavailableRoots       : TStringList;

    FScannerThread    : TLibraryScannerThread;
    // ---> AUDIT FIX S1: Holds completed scanner thread for deferred destruction
    // outside its own OnTerminate (Synchronize) handler!
    FFinishedScanner  : TLibraryScannerThread;
    // ---> AUDIT FIX (deadlock): The scanner whose OnTerminate (Synchronize) is
    // currently executing. CleanupFinishedScanner must never WaitFor this thread,
    // because it cannot exit until HandleScannerFinished returns.
    FTerminatingScanner : TLibraryScannerThread;
    FIsScanning       : boolean;

    FPendingScanRequested   : boolean;
    FPendingScanFullRebuild : boolean;
    // ---> ADDED: Set by BeginShutdown; StartScan does nothing from then on
    FShuttingDown           : boolean;

    // ---> AUDIT FIX: Paths whose record was updated (tag editor) while a scan
    // was running. The scanner may already have copied the old record, so these
    // records are carried over into the new track list when the scan finishes.
    FUpdatedDuringScan      : TStringList;

    FIsDirty            : boolean;
    // ---> AUDIT FIX D1: Prevents overwriting a valid database file if LoadDatabase failed
    FDatabaseLoadFailed : boolean;
    // ---> AUDIT FIX: True when the last scan skipped a library folder that was
    // not reachable (at the start or during the scan); read in OnScanDone
    FLastScanHadUnavailableRoots : boolean;

    FOnScanProgress : TScanProgressEvent;
    FOnScanDone     : TScanDoneEvent;

    // Phase timing of the last LoadDatabase (milliseconds), for the log line
    FLoadReadMs, FLoadParseMs, FLoadDictMs : QWord;

    // ---> AulumicNS: the journal of the records changed since the snapshot
    // of generation FGeneration
    FJournal    : TDbJournal;
    FGeneration : QWord;

    FStartTick : QWord;

    // ---> AulumicNS: appends the record (under the lock); a new snapshot when
    // the journal has grown
    procedure JournalTrack(Track: PTrackInfo);
    function  BuildSnapshotBody: TBytes;
    procedure ReadSnapshotBody(const ABody: TBytes);
    function  ApplyJournal: Integer;
    procedure ClearCaches;
    procedure ValidateCaches;
    procedure ClearFolderIndex;
    procedure ValidateFolderIndex;
    function  MergeScannedLinks(AScanner: TLibraryScannerThread): Boolean;
    procedure HandleScannerFinished(Sender: TObject);
    procedure CleanupFinishedScanner(Data: PtrInt);
    procedure RebuildTrackDictionary;
    procedure ExecuteAsyncSave(Data: PtrInt);
    // ---> ADDED: The scanner's progress (main thread); passes it on to
    // OnScanProgress as it is at the moment of the call
    procedure DoScanProgress(const ScanMsg, CurrentFolder: string;
      TrackCount, TotalTracks: Integer);
    // ---> CHANGED (phase 4): Was the public GetTrackByPath. The library's own
    // record of APath (nil = not in the library). Only valid while
    // FCriticalSection is held: a finished scan disposes all records. Other
    // units use TryGetTrack / ContainsTrack (copies / a yes-no answer).
    function  FindTrack(const APath: string): PTrackInfo;

  private
    // ---> CHANGED: Private (was public). Guards FTracks, FTrackDict and the
    // records. Other units use the thread-safe methods below (TryGetTrack,
    // SnapshotTracks, SetReplayGainFlag, ...); TLibraryScannerThread in this
    // unit still takes it directly.
    FCriticalSection: TCriticalSection;

  public
    constructor Create(const ADbFile: string);
    destructor Destroy; override;

    // ---> CHANGED (phase 4): Track lists are copies. The GetTracks... methods,
    // GetAllTracks and SearchLibrary fill a TTrackList (uLibraryTypes) with
    // copies of the library's records; TryGetTrack and SnapshotTracks return
    // copies as well. The library's own records (and the AllTracks list /
    // GetTrackByPath pointers that exposed them) are no longer handed out: a
    // finished scan disposes all of them, so a pointer kept across anything
    // that processes messages pointed to freed memory. The copies stay valid
    // as long as the caller keeps them and need no lock.

    // Number of tracks in the library
    function  GetTrackCount: Integer;
    // Copies of all tracks, in library order
    procedure GetAllTracks(ATracks: TTrackList);

    procedure LoadDatabase;
    procedure SaveDatabase;
    // ---> AulumicNS: replaces the whole library - the records (completed as
    // after a scan: search fields, fingerprints), the library folders and the
    // virtual folders (ALinks: the link files, Objects = a TStrings of each
    // one's target folders or nil) - and marks it changed. For tools and
    // tests that need a library with known content. Returns the number of
    // tracks, -1 while a scan runs (the library is unchanged).
    function  ReplaceContent(const ATracks: TTrackInfoArray; AFolders, ALinks: TStrings): Integer;

    procedure SetScanFolders(Folders: TStrings);
    procedure GetScanFolders(ResultList: TStrings);
    function  HasScanFolders: Boolean;

    procedure AddScanFolder(const AFolder: string);

    procedure StartScan(FullRebuild: boolean = False);
    procedure StopScan;
    // ---> ADDED: Aulumic is closing: no new scan may start any more (e.g. a
    // queued scan dispatched while the teardown waits for a worker thread)
    procedure BeginShutdown;
    function  IsScanning: boolean;
    procedure ProcessPendingScans;

    // Tracks directly in FolderDir (copies, library order)
    procedure GetTracksInFolder(const FolderDir: string; ATracks: TTrackList);

    // Names of the subfolders (with music) and virtual folders (.aullink file
    // names) of a library folder, from the library itself (no disk access)
    procedure GetSubFolders(const FolderDir: string; ResultList: TStrings);
    // Target folders of a virtual folder. From the library when the link is
    // known (no disk access; AOnlyWithMusic leaves out targets without
    // music), otherwise read from the .aullink file. False = not in the library.
    function  GetVirtualLinkTargets(const ALinkPath: string; ATargets: TStringList;
      AOnlyWithMusic: Boolean = False): Boolean;
    // Reads a .aullink file again after it was created / edited / deleted in
    // Aulumic (a deleted file is removed from the library)
    procedure RefreshVirtualLink(const ALinkPath: string);
    // Library folder reachable? Drive letters via GetLogicalDrives (no disk
    // access), network folders from the last scan
    function  IsRootAvailable(const ARoot: string): Boolean;

    procedure GetUniqueArtists(ResultList: TStrings);
    procedure GetUniqueAlbums(ResultList: TStrings);
    // The GetTracksBy... methods: copies, in library order
    procedure GetTracksByArtist(const ArtistName: string; ATracks: TTrackList);
    procedure GetTracksByAlbum(const AlbumName: string; ATracks: TTrackList);

    procedure GetUniqueGenres(ResultList: TStrings);
    procedure GetTracksByGenre(const GenreName: string; ATracks: TTrackList);

    procedure GetAlbumsByArtist(const ArtistName: string; ResultList: TStrings);
    procedure GetAlbumsByGenre(const GenreName: string; ResultList: TStrings);
    procedure GetTracksByArtistAndAlbum(const ArtistName, AlbumName: string;
      ATracks: TTrackList);
    procedure GetTracksByGenreAndAlbum(const GenreName, AlbumName: string;
      ATracks: TTrackList);

    // ---> ADDED (phase 4): True when APath is in the library (replaces
    // Assigned(GetTrackByPath(...)))
    function ContainsTrack(const APath: string): Boolean;
    // Tracks matching an auto-playlist query (copies). ASort = False skips the
    // default sort (the caller sorts the copies itself, e.g. with
    // CompareTrackInfo for the library order).
    procedure GetTracksByQuery(const Query: string; ATracks: TTrackList; ASort: Boolean = True);
    // Log text with the track count and phase timing of the last LoadDatabase
    function GetLoadSummary: string;

    procedure UpdateRecord(const UpdatedData: TTrackInfo);

    // ---> ADDED: Thread-safe access for other units (any thread). The lock is
    // taken inside; results are copies, so they stay valid after a scan.
    // A copy of the track with this path; False (and an empty record) when it
    // is not in the library
    function  TryGetTrack(const APath: string; out ATrack: TTrackInfo): Boolean;
    // Copies of all tracks, in library order (for searches over the library)
    function  SnapshotTracks: TTrackInfoArray;
    // True when at least one of AFiles is in the library without ReplayGain;
    // files that are not in the library are not counted
    function  AnyTrackMissingReplayGain(AFiles: TStrings): Boolean;
    // Sets HasReplayGain of the track APath; with AFileTime > 0 also its date
    // and size (after Aulumic saved the file). Marks the library changed when
    // anything changed. False when the track is not in the library.
    function  SetReplayGainFlag(const APath: string; AHasReplayGain: Boolean;
      AFileTime: Int64 = 0; AFileSize: Int64 = 0): Boolean;
    // SetReplayGainFlag for each of AFiles; returns the number of tracks changed
    function  SetReplayGainFlags(AFiles: TStrings; AHasReplayGain: Boolean): Integer;
    // Clears HasReplayGain of every track whose album is in AAlbums (AAlbums.
    // IndexOf); returns the number of tracks changed
    function  ClearReplayGainForAlbums(AAlbums: TStrings): Integer;

    function ToggleAlbumFavorite(const AAlbumArtist, AAlbum, ATitle: string): Boolean;

    property OnDatabaseChanged: TNotifyEvent read FOnDatabaseChanged write FOnDatabaseChanged;

    // MatchTracks: copies, in library order
    procedure SearchLibrary(const Query: string;
      MatchArtists, MatchAlbums, MatchGenres, MatchFolders: TStrings; MatchTracks: TTrackList);

    procedure QueueOrStartScan(FullRebuild: boolean = False; SilentQueue: boolean = False);
    procedure TryDispatchPendingQueue;

    property OnScanProgress: TScanProgressEvent
      read FOnScanProgress write FOnScanProgress;
    property OnScanDone: TScanDoneEvent read FOnScanDone write FOnScanDone;
    property IsDirty: Boolean read FIsDirty write FIsDirty;
    property LastScanHadUnavailableRoots: Boolean read FLastScanHadUnavailableRoots;

    // Tracks in FolderDir and all folders below it (copies, library order)
    procedure GetTracksInFolderRecursive(const FolderDir: string; ATracks: TTrackList);
    procedure GetDistinctAlbumBuckets(out AlbumBuckets: TList; out TotalMissingGain: Integer);
  end;

implementation

uses
  Windows, forms, contnrs, uAppStrings, uAppConsts, uEngineStateManager, uAudioUtils,
  uMetaUtils, uOSUtils, AuLog,
  uLibraryQuery;     // ---> CHANGED: EvaluateTrack (auto-playlist filter) moved there

const
  // ---> AulumicNS: the snapshot and the journal (see LoadDatabase)
  LIB_MAGIC                  = 'AUNSLIBR';
  LIB_JOURNAL_MAGIC          = 'AUNSLJNL';
  LIB_JOURNAL_COMPACT_BYTES  = 4 * 1024 * 1024;
  JR_TRACK_PUT               = 1;
  TRACK_TEXTS                = 11;     // the pooled texts of a track (without the path)
  TRACK_MIN_BYTES            = 4 + TRACK_TEXTS * 4 + 5 * 4 + 3 * 8 + 1;

{ TNameSet }

type
  // ---> AulumicNS: distinct strings (exact spelling) in the order they were
  // noted first. The library's name lists (artists, albums, genres, folders)
  // are sorted with Windows' language-aware comparison, which is slow; with
  // this set that comparison runs once per distinct name instead of several
  // times per track (ValidateCaches, SearchLibrary). AddTo gives the same
  // list as adding every name of every track to it did.
  TNameSet = class
  private
    FSeen : TFPDataHashTable;
    FNames: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Note(const S: string);
    // The ';'-separated items of ARaw, trimmed, empty ones left out. False:
    // there was none.
    function  NoteItems(const ARaw: string): Boolean;
    // Adds the names to AList (a sorted list that ignores duplicates)
    procedure AddTo(AList: TStrings);
  end;

constructor TNameSet.Create;
begin
  inherited Create;
  FSeen  := TFPDataHashTable.Create;
  FNames := TStringList.Create;
end;

destructor TNameSet.Destroy;
begin
  FNames.Free;
  FSeen.Free;
  inherited Destroy;
end;

procedure TNameSet.Note(const S: string);
begin
  if S = '' then
    Exit;
  if FSeen.Items[S] = nil then
  begin
    FSeen.Add(S, Pointer(1));
    FNames.Add(S);
  end;
end;

function TNameSet.NoteItems(const ARaw: string): Boolean;
var
  Rem, S: string;
  P: Integer;
begin
  Result := False;
  Rem := Trim(ARaw);
  if Rem = '' then
    Exit;
  // the usual case: one name
  if Pos(';', Rem) = 0 then
  begin
    Note(Rem);
    Exit(True);
  end;
  while True do
  begin
    P := Pos(';', Rem);
    if P > 0 then
    begin
      S := Trim(Copy(Rem, 1, P - 1));
      if S <> '' then
      begin
        Note(S);
        Result := True;
      end;
      Rem := Trim(Copy(Rem, P + 1, Length(Rem)));
    end
    else
    begin
      if Rem <> '' then
      begin
        Note(Rem);
        Result := True;
      end;
      Break;
    end;
  end;
end;

procedure TNameSet.AddTo(AList: TStrings);
var
  I: Integer;
begin
  for I := 0 to FNames.Count - 1 do
    AList.Add(FNames[I]);
end;
{ TLibraryManager }

constructor TLibraryManager.Create(const ADbFile: string);
begin
  inherited Create;
  FTracks                              := TList.Create;
  FTrackDict                           := TStringList.Create;
  FTrackDict.Sorted                    := True;
  FTrackDict.Duplicates                := dupIgnore;
  FTrackDict.CaseSensitive             := False;
  // ---> AUDIT FIX: Plain (non-locale) comparison for the path dictionary.
  // Sorting it with the locale comparison took ~1.3 s for 46,000 tracks on
  // the NUC. Case-insensitive for A..Z only, which is fine for file paths.
  FTrackDict.UseLocale                 := False;
  FIsDirty                             := False;
  FDatabaseLoadFailed                  := False;
  FFinishedScanner                     := nil;
  FTerminatingScanner                  := nil;

  FScanFolders                         := TStringList.Create;
  FScanFolders.CaseSensitive           := False;

  FUpdatedDuringScan                   := TStringList.Create;
  FUpdatedDuringScan.Sorted            := True;
  FUpdatedDuringScan.Duplicates        := dupIgnore;
  FUpdatedDuringScan.CaseSensitive     := False;
  FDatabaseFile                        := ADbFile;
  FCriticalSection                     := SyncObjs.TCriticalSection.Create;
  FIsScanning                          := False;

  FArtistSummaryCache                  := TStringList.Create;
  FArtistSummaryCache.Sorted           := True;
  FArtistSummaryCache.Duplicates       := dupIgnore;
  FArtistSummaryCache.CaseSensitive    := False;

  FGenreSummaryCache                   := TStringList.Create;
  FGenreSummaryCache.Sorted            := True;
  FGenreSummaryCache.Duplicates        := dupIgnore;
  FGenreSummaryCache.CaseSensitive     := False;

  FAlbumSummaryCache                   := TStringList.Create;
  FAlbumSummaryCache.Sorted            := True;
  FAlbumSummaryCache.Duplicates        := dupIgnore;
  FAlbumSummaryCache.CaseSensitive     := False;

  FCachesValid                         := False;

  FLinks                               := TStringList.Create;
  FLinks.Sorted                        := True;
  FLinks.Duplicates                    := dupIgnore;
  FLinks.CaseSensitive                 := False;
  FLinks.UseLocale                     := False;
  FLinks.OwnsObjects                   := True;

  FLinksChangedDuringScan              := TStringList.Create;
  FLinksChangedDuringScan.Sorted       := True;
  FLinksChangedDuringScan.Duplicates   := dupIgnore;
  FLinksChangedDuringScan.CaseSensitive := False;
  FLinksChangedDuringScan.UseLocale    := False;

  // Plain (non-locale) comparison: internal path lists
  FFolderIndex                         := TStringList.Create;
  FFolderIndex.Sorted                  := True;
  FFolderIndex.Duplicates              := dupIgnore;
  FFolderIndex.CaseSensitive           := False;
  FFolderIndex.UseLocale               := False;
  FFolderIndex.OwnsObjects             := True;
  FFolderIndexValid                    := False;

  FUnavailableRoots                    := TStringList.Create;
  FUnavailableRoots.Sorted             := True;
  FUnavailableRoots.Duplicates         := dupIgnore;
  FUnavailableRoots.CaseSensitive      := False;

  FJournal := TDbJournal.Create(ChangeFileExt(ADbFile, '.jnl'), LIB_JOURNAL_MAGIC);
end;

destructor TLibraryManager.Destroy;
var
  I: integer;
begin
  StopScan;

  if Assigned(Application) then
    Application.RemoveAsyncCalls(Self);

  CleanupFinishedScanner(0);

  if FIsDirty then
    SaveDatabase;

  ClearCaches;
  FTrackDict.Free;
  FArtistSummaryCache.Free;
  FGenreSummaryCache.Free;
  FAlbumSummaryCache.Free;
  FFolderIndex.Free;
  FLinks.Free;
  FLinksChangedDuringScan.Free;
  FUnavailableRoots.Free;
  FJournal.Free;
  FCriticalSection.Free;
  FScanFolders.Free;
  FUpdatedDuringScan.Free;

  if Assigned(FTracks) then
  begin
    for I := 0 to FTracks.Count - 1 do
      if Assigned(FTracks[I]) then
        Dispose(PTrackInfo(FTracks[I]));

    FTracks.Free;
  end;

  inherited Destroy;
end;

// ---> AUDIT FIX S1: Deferred scanner destruction outside OnTerminate
procedure TLibraryManager.CleanupFinishedScanner(Data: PtrInt);
begin
  // ---> AUDIT FIX (deadlock): Skip the scanner that is still inside its own
  // OnTerminate handler (e.g. HandleScannerFinished -> TryDispatchPendingQueue ->
  // StartScan, or a modal dialog pumping async calls). HandleScannerFinished
  // re-queues this cleanup once it has returned.
  if Assigned(FFinishedScanner) and (FFinishedScanner = FTerminatingScanner) then
    Exit;

  if Assigned(FFinishedScanner) then
  begin
    FFinishedScanner.WaitFor;
    TThread.RemoveQueuedEvents(FFinishedScanner);
    FreeAndNil(FFinishedScanner);
  end;
end;

procedure TLibraryManager.QueueOrStartScan(FullRebuild: boolean = False; SilentQueue: boolean = False);
var
  BusyReason: string;
begin
  // 1. Prevent redundant back-to-back normal scans!
  if FIsScanning and (not FullRebuild) then
  begin
    if not SilentQueue then
      ALMessageDlg(TITLE_SCAN_IN_PROGRESS, sLineBreak + MSG_SCAN_IN_PROGRESS, [mbOK]);
    Exit;
  end;

  // 2. Queue the scan if the engine is busy with OTHER tasks
  if FIsScanning or (not AppStateManager.IsIdle) then
  begin
    FPendingScanRequested   := True;
    FPendingScanFullRebuild := FullRebuild;

    if not SilentQueue then
    begin
      BusyReason := AppStateManager.GetBusyMessage;

      if BusyReason = '' then
        BusyReason := MSG_BACKGROUND_TASK_RUNNING;

      ALMessageDlg(TITLE_SCAN_QUEUED,
        BusyReason + sLineBreak + sLineBreak + MSG_SCAN_QUEUED, [mbOK]);
    end;
    Exit;
  end;

  // 3. The engine is totally idle; start instantly.
  StartScan(FullRebuild);
end;

procedure TLibraryManager.TryDispatchPendingQueue;
begin
  if FPendingScanRequested and AppStateManager.IsIdle and (not FIsScanning) then
  begin
    StartScan(FPendingScanFullRebuild);
  end;
end;

procedure TLibraryManager.GetTracksInFolderRecursive(const FolderDir: string;
  ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
  TargetDir: string;
begin
  ATracks.Clear;
  TargetDir := IncludeTrailingPathDelimiter(FolderDir);
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      if StartsText(TargetDir, IncludeTrailingPathDelimiter(Track^.FolderDir)) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

function TLibraryManager.GetTrackCount: Integer;
begin
  FCriticalSection.Enter;
  try
    Result := FTracks.Count;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetAllTracks(ATracks: TTrackList);
var
  I: Integer;
begin
  ATracks.Clear;
  FCriticalSection.Enter;
  try
    ATracks.List.Capacity := FTracks.Count;
    for I := 0 to FTracks.Count - 1 do
      if Assigned(FTracks[I]) then
        ATracks.Add(PTrackInfo(FTracks[I])^);
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.ContainsTrack(const APath: string): Boolean;
begin
  FCriticalSection.Enter;
  try
    Result := Assigned(FindTrack(APath));
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetDistinctAlbumBuckets(out AlbumBuckets: TList; out TotalMissingGain: Integer);
var
  Dict: TStringList;
  I, Idx: Integer;
  Track: PTrackInfo;
  Hash: string;
  Bucket: TStringList;
begin
  TotalMissingGain := 0;
  AlbumBuckets     := TList.Create;
  Dict             := TStringList.Create;

  FCriticalSection.Enter;
  try
    try
      Dict.Sorted        := True;
      Dict.Duplicates    := dupIgnore;
      Dict.CaseSensitive := False;
      Dict.UseLocale     := False; // internal lookup list (never displayed)

      for I := 0 to FTracks.Count - 1 do
      begin
        Track := PTrackInfo(FTracks[I]);
        if not Assigned(Track) then
          Continue;

        Hash := LowerCase(Trim(ExtractFileDir(Track^.FilePath)) + '|' +
                          Trim(Track^.AlbumArtist) + '|' +
                          Trim(Track^.Album));

        Idx := Dict.IndexOf(Hash);
        if Idx < 0 then
        begin
          Bucket := TStringList.Create;
          Dict.AddObject(Hash, TObject(Bucket));
          AlbumBuckets.Add(Bucket);
        end
        else
        begin
          Bucket := TStringList(Dict.Objects[Idx]);
        end;

        Bucket.Add(Track^.FilePath);

        if (not Track^.HasReplayGain) and (Bucket.Objects[0] = nil) then
        begin
          Bucket.Objects[0] := TObject(PtrInt(1));
          Inc(TotalMissingGain);
        end;
      end;
    except
      // ---> AUDIT FIX: Clean up AlbumBuckets if an exception occurs mid-build
      for I := 0 to AlbumBuckets.Count - 1 do
        if Assigned(AlbumBuckets[I]) then
          TObject(AlbumBuckets[I]).Free;
      FreeAndNil(AlbumBuckets);
      raise;
    end;
  finally
    FCriticalSection.Leave;
    Dict.Free;
  end;
end;

procedure TLibraryManager.SearchLibrary(const Query: string;
  MatchArtists, MatchAlbums, MatchGenres, MatchFolders: TStrings; MatchTracks: TTrackList);

  procedure GetTokens(const S: string; TargetList: TStringList);
  var
    Temp, Word: string;
    P: integer;
  begin
    Temp := Trim(S);
    while Temp <> '' do
    begin
      P := Pos(' ', Temp);
      if P > 0 then
      begin
        Word := Trim(Copy(Temp, 1, P - 1));
        if Word <> '' then
          TargetList.Add(Word);
        Temp := Trim(Copy(Temp, P + 1, Length(Temp)));
      end
      else
      begin
        TargetList.Add(Temp);
        Break;
      end;
    end;
  end;

  // The names in the order of the library pane's lists (sorted with
  // Windows' comparison, each name once)
  procedure SortedNames(ASet: TNameSet; AResult: TStrings);
  var
    SL: TStringList;
  begin
    SL := TStringList.Create;
    try
      SL.Sorted     := True;
      SL.Duplicates := dupIgnore;
      ASet.AddTo(SL);
      AResult.Assign(SL);
    finally
      SL.Free;
    end;
  end;

var
  CleanQuery: string;
  I, J: integer;
  Track: PTrackInfo;
  Txt, RTok, CTok: string;
  // ---> AulumicNS: was four sorted lists filled for every hit (a search with
  // 18,000 hits: 0.24 s, nearly all of it in Windows' string comparison)
  Artists, Albums, Genres, Folders: TNameSet;
  CleanTokens: TStringList;
  IsMatch, TokenFound: Boolean;
begin
  MatchTracks.Clear;
  if Length(Trim(Query)) < 3 then
    Exit;

  CleanQuery  := LowerCase(StripAccents(Query));
  CleanTokens := TStringList.Create;
  GetTokens(CleanQuery, CleanTokens);

  Artists := TNameSet.Create;
  Albums  := TNameSet.Create;
  Genres  := TNameSet.Create;
  Folders := TNameSet.Create;

  try
    FCriticalSection.Enter;
    try
      for I := 0 to FTracks.Count - 1 do
      begin
        Track   := PTrackInfo(FTracks[I]);
        IsMatch := True;

        for J := 0 to CleanTokens.Count - 1 do
        begin
          CTok := CleanTokens[J];

          TokenFound :=
            (Pos(CTok, Track^.CleanTitle) > 0) or
            (Pos(CTok, Track^.CleanArtist) > 0) or
            (Pos(CTok, Track^.CleanAlbumArtist) > 0) or
            (Pos(CTok, Track^.CleanComposer) > 0) or
            (Pos(CTok, Track^.CleanPerformer) > 0) or
            (Pos(CTok, Track^.CleanAlbum) > 0) or
            (Pos(CTok, Track^.CleanGenre) > 0) or
            (Pos(CTok, Track^.CleanFolder) > 0);

          if not TokenFound then
          begin
            IsMatch := False;
            Break;
          end;
        end;

        if IsMatch then
        begin
          MatchTracks.Add(Track^);

          Txt := Trim(Track^.Artist);
          if Txt = '' then
            Txt := Trim(Track^.AlbumArtist);
          if Txt = '' then
            Txt := LBL_UNKNOWN_ARTIST;
          Artists.NoteItems(Txt);

          RTok := Trim(Track^.AlbumArtist);
          if RTok = '' then
            RTok := Trim(Track^.Artist);
          if RTok = '' then
            RTok := LBL_UNKNOWN_ARTIST;

          Txt := Trim(Track^.Album);
          if Txt = '' then
            Txt := LBL_UNKNOWN_ALBUM;

          Albums.Note(RTok + ' - ' + Txt);

          Txt := Trim(Track^.Genre);
          if Txt = '' then
            Txt := LBL_UNKNOWN_GENRE;
          Genres.NoteItems(Txt);

          Folders.Note(ExcludeTrailingPathDelimiter(Track^.FolderDir));
        end;
      end;
    finally
      FCriticalSection.Leave;
    end;

    // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
    MatchTracks.Sort(@CompareTrackInfo);

    SortedNames(Artists, MatchArtists);
    SortedNames(Albums, MatchAlbums);
    SortedNames(Genres, MatchGenres);
    SortedNames(Folders, MatchFolders);

  finally
    Folders.Free;
    Genres.Free;
    Albums.Free;
    Artists.Free;
    CleanTokens.Free;
  end;
end;
procedure TLibraryManager.SetScanFolders(Folders: TStrings);
var
  I: Integer;
begin
  if FIsScanning then
    Exit;
  FCriticalSection.Enter;
  try
    FScanFolders.Clear;
    if Assigned(Folders) then
    begin
      for I := 0 to Folders.Count - 1 do
        AddScanFolder(Folders[I]);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetScanFolders(ResultList: TStrings);
begin
  FCriticalSection.Enter;
  try
    ResultList.Assign(FScanFolders);
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.HasScanFolders: Boolean;
begin
  FCriticalSection.Enter;
  try
    Result := FScanFolders.Count > 0;
  finally
    FCriticalSection.Leave;
  end;
end;

// ---> AUDIT FIX D5: Normalize scan folders and prevent overlapping/subfolder duplicates
procedure TLibraryManager.AddScanFolder(const AFolder: string);
var
  CleanNew, NewWithSep, ExistingWithSep: string;
  I: Integer;
begin
  if FIsScanning then
    Exit;

  CleanNew := ExcludeTrailingPathDelimiter(Trim(AFolder));
  if CleanNew = '' then
    Exit;

  NewWithSep := IncludeTrailingPathDelimiter(CleanNew);

  FCriticalSection.Enter;
  try
    for I := FScanFolders.Count - 1 downto 0 do
    begin
      ExistingWithSep := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(FScanFolders[I]));

      // Ignore if exact folder or a parent folder is already in FScanFolders
      if SameText(NewWithSep, ExistingWithSep) or StartsText(ExistingWithSep, NewWithSep) then
        Exit;

      // If the newly added folder is a parent of an existing subfolder, replace the child
      if StartsText(NewWithSep, ExistingWithSep) then
        FScanFolders.Delete(I);
    end;

    FScanFolders.Add(CleanNew);
    FIsDirty := True;
  finally
    FCriticalSection.Leave;
  end;
end;

{ ---- ---> AulumicNS: the snapshot and the journal (uDbStore) ----

  Snapshot body (format 1):
    string pool
    library folders  : count, text ids
    virtual folders  : count, per link: text id, target count, text ids
    tracks           : count, per track: the file path (inline), 11 text ids
                       (FolderDir, Title, Artist, AlbumArtist, Album, Genre,
                       Composer, Performer, DurationStr, Comment, DateStr),
                       TrackNumber, DiscNumber, Year, SampleRate, BitDepth,
                       LastModified, FileSize, DateAdded, HasReplayGain
  Journal record JR_TRACK_PUT: the same track fields with the texts inline;
  replayed over the snapshot (an existing path is replaced, else added). }

function TrackText(const T: TTrackInfo; I: Integer): string;
begin
  case I of
    0: Result := T.FolderDir;
    1: Result := T.Title;
    2: Result := T.Artist;
    3: Result := T.AlbumArtist;
    4: Result := T.Album;
    5: Result := T.Genre;
    6: Result := T.Composer;
    7: Result := T.Performer;
    8: Result := T.DurationStr;
    9: Result := T.Comment;
  else
    Result := T.DateStr;
  end;
end;

procedure SetTrackText(var T: TTrackInfo; I: Integer; const V: string);
begin
  case I of
    0: T.FolderDir   := V;
    1: T.Title       := V;
    2: T.Artist      := V;
    3: T.AlbumArtist := V;
    4: T.Album       := V;
    5: T.Genre       := V;
    6: T.Composer    := V;
    7: T.Performer   := V;
    8: T.DurationStr := V;
    9: T.Comment     := V;
  else
    T.DateStr := V;
  end;
end;

procedure WriteTrackNumbers(W: TDbWriter; const T: TTrackInfo);
begin
  W.I32(T.TrackNumber);
  W.I32(T.DiscNumber);
  W.I32(T.Year);
  W.I32(T.SampleRate);
  W.I32(T.BitDepth);
  W.I64(T.LastModified);
  W.I64(T.FileSize);
  W.I64(T.DateAdded);
  W.Bool(T.HasReplayGain);
end;

procedure ReadTrackNumbers(R: TDbReader; var T: TTrackInfo);
begin
  T.TrackNumber   := R.I32;
  T.DiscNumber    := R.I32;
  T.Year          := R.I32;
  T.SampleRate    := R.I32;
  T.BitDepth      := R.I32;
  T.LastModified  := R.I64;
  T.FileSize      := R.I64;
  T.DateAdded     := R.I64;
  T.HasReplayGain := R.Bool;
end;

{ the derived search fields and fingerprints (as Aulumic's LoadDatabase) }
// what is made of the search forms and the path: the file name, the fingerprints
procedure FinishDerived(var T: TTrackInfo);
begin
  T.FileNameOnly     := ExtractFileName(T.FilePath);
  T.PrimaryFingerprint  := '';
  T.FallbackFingerprint := '';
  if Assigned(UserStatsManager) then
  begin
    T.PrimaryFingerprint := UserStatsManager.GenerateFingerprintFromClean(
      T.CleanAlbumArtist, T.CleanAlbum, T.CleanTitle);
    if T.CleanAlbumArtist <> T.CleanArtist then
      T.FallbackFingerprint := UserStatsManager.GenerateFingerprintFromClean(
        T.CleanArtist, T.CleanAlbum, T.CleanTitle);
  end;
end;

procedure PrepareDerived(var T: TTrackInfo);
begin
  T.CleanTitle       := LowerCase(StripAccents(T.Title));
  T.CleanArtist      := LowerCase(StripAccents(T.Artist));
  T.CleanAlbumArtist := LowerCase(StripAccents(T.AlbumArtist));
  T.CleanAlbum       := LowerCase(StripAccents(T.Album));
  T.CleanGenre       := LowerCase(StripAccents(T.Genre));
  T.CleanComposer    := LowerCase(StripAccents(T.Composer));
  T.CleanPerformer   := LowerCase(StripAccents(T.Performer));
  T.CleanFolder      := LowerCase(StripAccents(T.FolderDir));
  FinishDerived(T);
end;

{ ---> AulumicNS: the texts that repeat from track to track (folder, artist,
  album, genre ...) are ONE string in memory, and so are the search forms made
  of them (Clean...). ACache: the search form per pool id. With 45,000 tracks
  the library takes about half the memory. }
type
  TTrackTextIds = array[0..TRACK_TEXTS - 1] of Cardinal;
  TCleanCache   = array of string;

{ the search form of the pooled text AId (ASource), made once and shared }
function PooledClean(const ASource: string; AId: Cardinal; var ACache: TCleanCache): string;
begin
  if (AId = 0) or (ASource = '') then
    Exit(LowerCase(StripAccents(ASource)));
  if AId >= Cardinal(Length(ACache)) then
    SetLength(ACache, Max(Integer(AId) + 1, Length(ACache) * 2));
  if ACache[AId] = '' then ACache[AId] := LowerCase(StripAccents(ASource));
  Result := ACache[AId];
end;

{ PrepareDerived for a record whose texts came from the pool (AIds) }
procedure PrepareDerivedPooled(var T: TTrackInfo; const AIds: TTrackTextIds; var ACache: TCleanCache);
begin
  T.CleanTitle       := LowerCase(StripAccents(T.Title));
  T.CleanFolder      := PooledClean(T.FolderDir,   AIds[0], ACache);
  T.CleanArtist      := PooledClean(T.Artist,      AIds[2], ACache);
  T.CleanAlbumArtist := PooledClean(T.AlbumArtist, AIds[3], ACache);
  T.CleanAlbum       := PooledClean(T.Album,       AIds[4], ACache);
  T.CleanGenre       := PooledClean(T.Genre,       AIds[5], ACache);
  T.CleanComposer    := PooledClean(T.Composer,    AIds[6], ACache);
  T.CleanPerformer   := PooledClean(T.Performer,   AIds[7], ACache);
  FinishDerived(T);
end;

{ the records a scan made, into ADest as the library keeps them: the scanner
  thread built them in its own memory, between the temporary blocks of reading
  the tags, and every text as a string of its own. Here each record and each
  DIFFERENT text is allocated once, by the calling thread and one after the
  other (copying first and sharing afterwards left 90 MB of holes); ASource's
  records are disposed, so the scanner's memory goes back to Windows. }
procedure TakeOverScannedTracks(ASource, ADest: TList);

  procedure Fresh(var S: string); inline;
  begin
    if S <> '' then S := Copy(S, 1, Length(S));   // Copy always allocates
  end;

  procedure FreshClean(var AField: string; AId: Cardinal; var ACache: TCleanCache);
  begin
    if (AId = 0) or (AField = '') then
    begin
      Fresh(AField);
      Exit;
    end;
    if AId >= Cardinal(Length(ACache)) then
      SetLength(ACache, Max(Integer(AId) + 1, Length(ACache) * 2));
    if ACache[AId] = '' then ACache[AId] := Copy(AField, 1, Length(AField));
    AField := ACache[AId];
  end;

var
  Pool: TDbStrPool;
  Cache: TCleanCache;
  Ids: TTrackTextIds;
  I, K: Integer;
  Old, T: PTrackInfo;
begin
  Pool  := TDbStrPool.Create;
  Cache := nil;
  try
    ADest.Capacity := ADest.Count + ASource.Count;
    for I := 0 to ASource.Count - 1 do
    begin
      Old := PTrackInfo(ASource[I]);
      if Old = nil then Continue;
      New(T);
      T^ := Old^;
      for K := 0 to TRACK_TEXTS - 1 do
      begin
        Ids[K] := Pool.InternCopy(TrackText(T^, K));
        SetTrackText(T^, K, Pool.Str(Ids[K]));
      end;
      FreshClean(T^.CleanFolder,      Ids[0], Cache);
      FreshClean(T^.CleanArtist,      Ids[2], Cache);
      FreshClean(T^.CleanAlbumArtist, Ids[3], Cache);
      FreshClean(T^.CleanAlbum,       Ids[4], Cache);
      FreshClean(T^.CleanGenre,       Ids[5], Cache);
      FreshClean(T^.CleanComposer,    Ids[6], Cache);
      FreshClean(T^.CleanPerformer,   Ids[7], Cache);
      Fresh(T^.FilePath);
      Fresh(T^.CleanTitle);
      Fresh(T^.FileNameOnly);
      Fresh(T^.PrimaryFingerprint);
      Fresh(T^.FallbackFingerprint);
      ADest.Add(T);
      Dispose(Old);
      ASource[I] := nil;
    end;
  finally
    Pool.Free;
  end;
end;

function TLibraryManager.BuildSnapshotBody: TBytes;var
  Pool: TDbStrPool;
  Rest, W: TDbWriter;
  I, J, K: Integer;
  Targets: TStringList;
  T: PTrackInfo;
begin
  Pool := TDbStrPool.Create;
  Rest := TDbWriter.Create;
  W    := TDbWriter.Create;
  try
    Rest.U32(FScanFolders.Count);
    for I := 0 to FScanFolders.Count - 1 do
      Rest.U32(Pool.Intern(FScanFolders[I]));
    Rest.U32(FLinks.Count);
    for I := 0 to FLinks.Count - 1 do
    begin
      Targets := TStringList(FLinks.Objects[I]);
      Rest.U32(Pool.Intern(FLinks[I]));
      Rest.U32(Targets.Count);
      for J := 0 to Targets.Count - 1 do
        Rest.U32(Pool.Intern(Targets[J]));
    end;
    Rest.U32(FTracks.Count);
    for I := 0 to FTracks.Count - 1 do
    begin
      T := PTrackInfo(FTracks[I]);
      Rest.Str(T^.FilePath);
      for K := 0 to TRACK_TEXTS - 1 do
        Rest.U32(Pool.Intern(TrackText(T^, K)));
      WriteTrackNumbers(Rest, T^);
    end;
    { the pool first: the reader needs it for the ids }
    Pool.WriteTo(W);
    Result := W.Bytes;
    I := Length(Result);
    SetLength(Result, I + Rest.Size);
    if Rest.Size > 0 then
      Move(Rest.Bytes[0], Result[I], Rest.Size);
  finally
    W.Free;
    Rest.Free;
    Pool.Free;
  end;
end;

procedure TLibraryManager.ReadSnapshotBody(const ABody: TBytes);
var
  Pool: TDbStrPool;
  R: TDbReader;
  N, I, J, K, NT: Integer;
  Targets: TStringList;
  Link: string;
  PTrack: PTrackInfo;
  Ids: TTrackTextIds;
  Cache: TCleanCache;
begin
  Cache := nil;
  Pool := TDbStrPool.Create;
  R    := TDbReader.Create(ABody);
  try
    Pool.ReadFrom(R);
    N := R.Count(4);
    for I := 0 to N - 1 do
      AddScanFolder(Pool.Str(R.U32));
    N := R.Count(8);
    for I := 0 to N - 1 do
    begin
      Link := Pool.Str(R.U32);
      NT   := R.Count(4);
      Targets := TStringList.Create;
      Targets.CaseSensitive := False;
      for J := 0 to NT - 1 do
        Targets.Add(Pool.Str(R.U32));
      if (Link = '') or (FLinks.IndexOf(Link) >= 0) then
        Targets.Free
      else
        FLinks.AddObject(Link, Targets);
    end;
    N := R.Count(TRACK_MIN_BYTES);
    FTracks.Capacity := N;
    for I := 0 to N - 1 do
    begin
      New(PTrack);
      try
        PTrack^ := Default(TTrackInfo);
        PTrack^.FilePath := R.Str;
        for K := 0 to TRACK_TEXTS - 1 do
        begin
          Ids[K] := R.U32;
          SetTrackText(PTrack^, K, Pool.Str(Ids[K]));
        end;
        ReadTrackNumbers(R, PTrack^);
        PrepareDerivedPooled(PTrack^, Ids, Cache);
      except
        Dispose(PTrack);
        raise;
      end;
      if PTrack^.FilePath = '' then
        Dispose(PTrack)
      else
        FTracks.Add(PTrack);
    end;
  finally
    R.Free;
    Pool.Free;
  end;
end;

{ the journal of the current snapshot, over the loaded records; the track
  dictionary must be built. Returns the number of records applied. }
function TLibraryManager.ApplyJournal: Integer;
var
  Payloads: TList;
  I, K, Idx: Integer;
  R: TDbReader;
  T: TTrackInfo;
  PTrack: PTrackInfo;
begin
  Result := 0;
  Payloads := TList.Create;
  try
    FJournal.Replay(FGeneration, Payloads);
    for I := 0 to Payloads.Count - 1 do
    begin
      R := TDbReader.Create(PDbPayload(Payloads[I])^.Data);
      try
        try
          if R.U8 <> JR_TRACK_PUT then
            Continue;                      // a record of a newer version
          T := Default(TTrackInfo);
          T.FilePath := R.Str;
          for K := 0 to TRACK_TEXTS - 1 do
            SetTrackText(T, K, R.Str);
          ReadTrackNumbers(R, T);
          if T.FilePath = '' then
            Continue;
          PrepareDerived(T);
          Idx := FTrackDict.IndexOf(T.FilePath);
          if Idx >= 0 then
            PTrackInfo(FTrackDict.Objects[Idx])^ := T
          else
          begin
            New(PTrack);
            PTrack^ := T;
            FTracks.Add(PTrack);
            FTrackDict.AddObject(PTrack^.FilePath, TObject(PTrack));
          end;
          Inc(Result);
        except
          // a damaged record (its CRC was right): skipped
        end;
      finally
        R.Free;
      end;
    end;
  finally
    FreePayloads(Payloads);
    Payloads.Free;
  end;
end;

procedure TLibraryManager.JournalTrack(Track: PTrackInfo);
var
  W: TDbWriter;
  K: Integer;
begin
  if Track = nil then
    Exit;
  W := TDbWriter.Create;
  try
    W.U8(JR_TRACK_PUT);
    W.Str(Track^.FilePath);
    for K := 0 to TRACK_TEXTS - 1 do
      W.Str(TrackText(Track^, K));
    WriteTrackNumbers(W, Track^);
    FJournal.Append(W.Bytes);
  finally
    W.Free;
  end;
  if (FJournal.Size > LIB_JOURNAL_COMPACT_BYTES) and (not FIsScanning) and Assigned(Application) then
    Application.QueueAsyncCall(@ExecuteAsyncSave, 0);
end;

procedure TLibraryManager.LoadDatabase;
var
  Body: TBytes;
  Err, BackupPath: string;
  Gen: QWord;
  I: Integer;
  TPhase: QWord;
  Loaded: Boolean;
begin
  FLoadReadMs  := 0;
  FLoadParseMs := 0;
  FLoadDictMs  := 0;

  if FIsScanning then
    Exit;

  TPhase := GetTickCount64;
  Loaded := LoadSnapshot(FDatabaseFile, LIB_MAGIC, Gen, Body, Err);
  FLoadReadMs := GetTickCount64 - TPhase;

  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
      if Assigned(FTracks[I]) then
        Dispose(PTrackInfo(FTracks[I]));
    FTracks.Clear;
    ClearCaches;
    FScanFolders.Clear;
    FLinks.Clear;
    FDatabaseLoadFailed := False;
    FGeneration := 0;

    TPhase := GetTickCount64;
    if Loaded then
      try
        ReadSnapshotBody(Body);
        FGeneration := Gen;
      except
        on E: Exception do
        begin
          for I := 0 to FTracks.Count - 1 do
            if Assigned(FTracks[I]) then
              Dispose(PTrackInfo(FTracks[I]));
          FTracks.Clear;
          FScanFolders.Clear;
          FLinks.Clear;
          Err := E.Message;
        end;
      end;
    FLoadParseMs := GetTickCount64 - TPhase;

    if Err <> '' then
    begin
      // ---> AUDIT FIX D1: SaveDatabase refuses to overwrite a database that
      // could not be read, unless it was kept as a backup first
      FDatabaseLoadFailed := True;
      AddLog(SafeFormat(FMT_LOG_DB_LOAD_FAILED, [Err]), False, True);
      if BackupFileWithTimestamp(FDatabaseFile, BackupPath) then
      begin
        AddLog(SafeFormat(FMT_LOG_DB_BACKUP, [BackupPath]), False, True);
        BackupFileWithTimestamp(FJournal.FileName, BackupPath);
        FDatabaseLoadFailed := False;
      end;
    end;

    TPhase := GetTickCount64;
    RebuildTrackDictionary;
    // the changes since the snapshot (also without a snapshot: generation 0)
    FIsDirty := (not FDatabaseLoadFailed) and (ApplyJournal > 0);
    FLoadDictMs := GetTickCount64 - TPhase;
  finally
    FCriticalSection.Leave;
  end;
end;

// ---> AulumicNS: was ImportAulumicDatabase (Aulumic's Library.db text; the
// reader of that format is with the tests now, which fill a library this way)
function TLibraryManager.ReplaceContent(const ATracks: TTrackInfoArray;
  AFolders, ALinks: TStrings): Integer;
var
  I, J, Idx: Integer;
  PTrack: PTrackInfo;
  Targets: TStringList;
  Given: TStrings;
begin
  Result := -1;
  if FIsScanning then
    Exit;
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
      if Assigned(FTracks[I]) then
        Dispose(PTrackInfo(FTracks[I]));
    FTracks.Clear;
    FTracks.Capacity := Length(ATracks);
    ClearCaches;
    FScanFolders.Clear;
    FLinks.Clear;

    if Assigned(AFolders) then
      for I := 0 to AFolders.Count - 1 do
        AddScanFolder(AFolders[I]);

    if Assigned(ALinks) then
      for I := 0 to ALinks.Count - 1 do
      begin
        if ALinks[I] = '' then
          Continue;
        Idx := FLinks.IndexOf(ALinks[I]);
        if Idx < 0 then
        begin
          Targets := TStringList.Create;
          Targets.CaseSensitive := False;
          Idx := FLinks.AddObject(ALinks[I], Targets);
        end;
        Targets := TStringList(FLinks.Objects[Idx]);
        if ALinks.Objects[I] is TStrings then
        begin
          Given := TStrings(ALinks.Objects[I]);
          for J := 0 to Given.Count - 1 do
            if (Given[J] <> '') and (Targets.IndexOf(Given[J]) < 0) then
              Targets.Add(Given[J]);
        end;
      end;

    for I := 0 to High(ATracks) do
    begin
      if ATracks[I].FilePath = '' then
        Continue;
      New(PTrack);
      try
        PTrack^ := ATracks[I];
        PrepareDerived(PTrack^);
      except
        Dispose(PTrack);
        raise;
      end;
      FTracks.Add(PTrack);
    end;
    RebuildTrackDictionary;
    FIsDirty := True;
    Result   := FTracks.Count;
  finally
    FCriticalSection.Leave;
  end;
end;
procedure TLibraryManager.SaveDatabase;
var
  ErrorMsg  : string;
  StartTick, BuiltTick: QWord;
  BuildMs, WriteMs    : Int64;
  TrackCount          : integer;
  Body                : TBytes;
begin
  if not FIsDirty then
    Exit;
  if FIsScanning then
    Exit;

  // ---> AUDIT FIX D1: Never overwrite an existing database file after a failed
  // load unless LoadDatabase managed to preserve it as a backup first
  if FDatabaseLoadFailed and FileExists(FDatabaseFile) then
  begin
    AddLog(LOG_DB_NOT_SAVED, False, True);
    Exit;
  end;

  StartTick := GetTickCount64;
  // ---> AulumicNS: under the lock from the snapshot to the new journal, so
  // no change of another thread falls in between
  FCriticalSection.Enter;
  try
    TrackCount := FTracks.Count;
    Body       := BuildSnapshotBody;
    BuiltTick  := GetTickCount64;
    if SaveSnapshot(FDatabaseFile, LIB_MAGIC, FGeneration + 1, Body, ErrorMsg) then
    begin
      Inc(FGeneration);
      FJournal.Reset(FGeneration);
      FIsDirty            := False;
      FDatabaseLoadFailed := False;
      BuildMs := BuiltTick - StartTick;
      WriteMs := GetTickCount64 - BuiltTick;
      AddLog(SafeFormat(FMT_LOG_DB_SAVED_DETAIL,
        [TrackCount,
         Length(Body) div 1048576, ((Length(Body) mod 1048576) * 10) div 1048576,
         BuildMs div 1000, BuildMs mod 1000,
         WriteMs div 1000, WriteMs mod 1000]));
    end
    else
      AddLog(SafeFormat(FMT_LOG_DB_SAVE_FAILED, [ErrorMsg]), False, True);
  finally
    FCriticalSection.Leave;
  end;

  if Assigned(UserStatsManager) and UserStatsManager.IsDirty then
    UserStatsManager.SaveToFile;
end;

procedure TLibraryManager.StartScan(FullRebuild: boolean = False);
begin
  if FIsScanning or FShuttingDown then
    Exit;

  CleanupFinishedScanner(0);

  FPendingScanRequested := False;
  FStartTick            := GetTickCount64;

  FCriticalSection.Enter;
  try
    FUpdatedDuringScan.Clear;
    FLinksChangedDuringScan.Clear;
  finally
    FCriticalSection.Leave;
  end;

  if FullRebuild then
    AddLog(LOG_DB_REPAIR_STARTED)
  else
    AddLog(LOG_DB_SCAN_STARTED);

  AppStateManager.PushState(esLibraryBusy);

  FIsScanning    := True;
  FScannerThread := TLibraryScannerThread.Create(FCriticalSection, @DoScanProgress,
                        FScanFolders, FTracks, not FullRebuild);

  FScannerThread.OnTerminate := @HandleScannerFinished;
  FScannerThread.Start;
end;

procedure TLibraryManager.HandleScannerFinished(Sender: TObject);

  // ---> AUDIT FIX: Says WHY a library folder is unavailable, so a disconnected
  // drive or a changed drive letter is easy to recognise in the log
  function UnavailableReason(const AFolder: string): string;
  var
    Drive: string;
  begin
    Drive := ExtractFileDrive(AFolder);
    if (Drive <> '') and IsDriveRootMissing(AFolder) then
      Result := SafeFormat(FMT_LOG_REASON_DRIVE_MISSING, [Drive])
    else
      Result := LOG_REASON_FOLDER_MISSING;
  end;

var
  I: integer;
  LHasChanges   : boolean;
  DeadScanner   : TLibraryScannerThread;
  OldTrackCount, NewTrackCount: Integer;
  TracksAdded, TracksModified, TracksDeleted: Integer;
  ScanFailed    : boolean;
  SavedRecs     : TTrackList;
  OldRec, NewRec, SavedRec: PTrackInfo;
begin
  if not FIsScanning then
    Exit;

  ScanFailed := False;
  FLastScanHadUnavailableRoots := False;
  if Sender is TLibraryScannerThread then
    FTerminatingScanner := TLibraryScannerThread(Sender);
  try
  try
    LHasChanges    := False;
    TracksAdded    := 0;
    TracksModified := 0;
    TracksDeleted  := 0;

    if not (Sender is TLibraryScannerThread) then
      Exit;
    DeadScanner := TLibraryScannerThread(Sender);

    if FScannerThread = DeadScanner then
      FScannerThread := nil;

    if Assigned(DeadScanner) then
    begin
      FCriticalSection.Enter;
      try
        OldTrackCount  := FTracks.Count;
        NewTrackCount  := DeadScanner.ScannedTracks.Count;
        TracksAdded    := DeadScanner.TracksAdded;
        TracksModified := DeadScanner.TracksModified;

        // ---> AUDIT FIX: An aborted scan never replaces the library. Its partial
        // results are disposed below (LHasChanges stays False).
        if DeadScanner.ScanFailed or Assigned(DeadScanner.FatalException) then
        begin
          ScanFailed := True;
        end
        else if DeadScanner.HasChanges or (OldTrackCount <> NewTrackCount) then
        begin
          FIsDirty            := True;
          LHasChanges         := True;
        end;

        // Virtual folders (.aullink) found by the scan. A change (also only
        // in the links) is saved and rebuilds the tree.
        if not ScanFailed then
        begin
          try
            if MergeScannedLinks(DeadScanner) then
            begin
              FIsDirty    := True;
              LHasChanges := True;
            end;
          except
            // Keep the current links (the swap is the last step of the merge)
          end;
        end;

        if LHasChanges then
        begin
          // ---> AUDIT FIX: Keep a copy of the records that were updated while
          // the scan ran (the scanner may hold their old version)
          SavedRecs := TTrackList.Create;
          try
            for I := 0 to FUpdatedDuringScan.Count - 1 do
            begin
              OldRec := FindTrack(FUpdatedDuringScan[I]);
              if Assigned(OldRec) then
                SavedRecs.Add(OldRec^);
            end;

            for I := 0 to FTracks.Count - 1 do
              if Assigned(FTracks[I]) then
                Dispose(PTrackInfo(FTracks[I]));

            FTracks.Clear;
            FTracks.Capacity := 0;
            ClearCaches;

            // ---> AulumicNS: into this thread's memory, the texts that
            // repeat as one string, as after loading the database (a repair
            // left the library at twice its size until the next start)
            TakeOverScannedTracks(DeadScanner.ScannedTracks, FTracks);
            DeadScanner.ScannedTracks.Clear;
            DeadScanner.ScannedTracks.Capacity := 0;

            RebuildTrackDictionary;

            // Put the updated records back (only for files that still exist in
            // the new list)
            for I := 0 to SavedRecs.Count - 1 do
            begin
              SavedRec := SavedRecs[I];
              NewRec   := FindTrack(SavedRec^.FilePath);
              if Assigned(NewRec) then
                NewRec^ := SavedRec^;
            end;
          finally
            SavedRecs.Free;  // disposes the copies
          end;
        end
        else
        begin
          for I := 0 to DeadScanner.ScannedTracks.Count - 1 do
            if Assigned(DeadScanner.ScannedTracks[I]) then
              Dispose(PTrackInfo(DeadScanner.ScannedTracks[I]));

          DeadScanner.ScannedTracks.Clear;
        end;

        FUpdatedDuringScan.Clear;
      finally
        FCriticalSection.Leave;
      end;

      // Library folders that could not be reached (for the "(not available)"
      // label of network folders, see IsRootAvailable)
      FCriticalSection.Enter;
      try
        FUnavailableRoots.Clear;
        if Assigned(DeadScanner.RootsLostDuringScan) then
          FUnavailableRoots.AddStrings(DeadScanner.RootsLostDuringScan);
        if Assigned(DeadScanner.RootsOfflineAtStart) then
          FUnavailableRoots.AddStrings(DeadScanner.RootsOfflineAtStart);
      finally
        FCriticalSection.Leave;
      end;

      // ---> AUDIT FIX: Report scan folders that went offline during the scan
      FLastScanHadUnavailableRoots :=
        (Assigned(DeadScanner.RootsLostDuringScan) and (DeadScanner.RootsLostDuringScan.Count > 0)) or
        (Assigned(DeadScanner.RootsOfflineAtStart) and (DeadScanner.RootsOfflineAtStart.Count > 0));

      if Assigned(DeadScanner.RootsLostDuringScan) then
        for I := 0 to DeadScanner.RootsLostDuringScan.Count - 1 do
          AddWarning(SafeFormat(FMT_LOG_LIB_ROOT_LOST, [DeadScanner.RootsLostDuringScan[I],
                     UnavailableReason(DeadScanner.RootsLostDuringScan[I])]));

      if Assigned(DeadScanner.RootsOfflineAtStart) then
        for I := 0 to DeadScanner.RootsOfflineAtStart.Count - 1 do
          AddWarning(SafeFormat(FMT_LOG_LIB_ROOT_OFFLINE, [DeadScanner.RootsOfflineAtStart[I],
                     UnavailableReason(DeadScanner.RootsOfflineAtStart[I])]));

      // ---> AUDIT FIX S1: Defer freeing DeadScanner via QueueAsyncCall so we
      // never destroy the thread instance inside its own OnTerminate (Synchronize) call!
      CleanupFinishedScanner(0);
      FFinishedScanner := DeadScanner;
      if Assigned(Application) then
        Application.QueueAsyncCall(@CleanupFinishedScanner, 0);
    end;

  finally
    FIsScanning := False;
    AppStateManager.PopState(esLibraryBusy);
  end;

  if ScanFailed then
  begin
    // ---> AUDIT FIX: Report the aborted scan; the library was left untouched
    AddLog(LOG_LIB_SCAN_ABORTED, FStartTick, False, True);
  end
  else if LHasChanges then
  begin
    TracksDeleted := OldTrackCount - NewTrackCount + TracksAdded;

    AddLog(SafeFormat(FMT_LOG_SCAN_CHANGES,
                     [NewTrackCount, TracksAdded, TracksModified, TracksDeleted],
                     FMT_LOG_SCAN_CHANGES), FStartTick);

    Application.QueueAsyncCall(@ExecuteAsyncSave, 0);

    if Assigned(FOnDatabaseChanged) then
      FOnDatabaseChanged(Self);
  end
  else
  begin
    AddLog(SafeFormat(FMT_LOG_SCAN_NO_CHANGES,
                     [NewTrackCount],
                     FMT_LOG_SCAN_NO_CHANGES), FStartTick);
  end;

  if Assigned(FOnScanDone) then
    FOnScanDone(Self, LHasChanges);

  TryDispatchPendingQueue;

  finally
    FTerminatingScanner := nil;
    // Re-queue the deferred cleanup in case an async call already fired (and
    // skipped) while this handler was still running
    if Assigned(FFinishedScanner) and Assigned(Application) then
      Application.QueueAsyncCall(@CleanupFinishedScanner, 0);
  end;
end;

procedure TLibraryManager.RebuildTrackDictionary;
var
  I: integer;
  Track: PTrackInfo;
begin
  FTrackDict.Sorted := False;
  FTrackDict.BeginUpdate;
  try
    FTrackDict.Clear;
    FTrackDict.Capacity := FTracks.Count;

    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      FTrackDict.AddObject(Track^.FilePath, TObject(Track));
    end;
  finally
    FTrackDict.Sorted := True;
    FTrackDict.EndUpdate;
  end;
end;

procedure TLibraryManager.ExecuteAsyncSave(Data: PtrInt);
begin
  SaveDatabase;
end;

function TLibraryManager.FindTrack(const APath: string): PTrackInfo;
var
  Idx: integer;
begin
  Result := nil;
  if APath = '' then
    Exit;

  FCriticalSection.Enter;
  try
    if Pos('/', APath) > 0 then
      Idx := FTrackDict.IndexOf(SetDirSeparators(APath))
    else
      Idx := FTrackDict.IndexOf(APath);

    if Idx >= 0 then
      Result := PTrackInfo(FTrackDict.Objects[Idx]);
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetTracksByQuery(const Query: string; ATracks: TTrackList; ASort: Boolean = True);
var
  I: integer;
  Track: PTrackInfo;
  UStats: PUserTrackStats;
  ParsedConditions: TQueryConditionArray;
  NeedsStats: Boolean;
begin
  ATracks.Clear;
  if Trim(Query) = '' then
    Exit;

  ParsedConditions := ParseQuery(Query);
  if Length(ParsedConditions) = 0 then
    Exit;

  NeedsStats := False;
  for I := 0 to High(ParsedConditions) do
  begin
    if ParsedConditions[I].TagID in [tiRating, tiFavorite, tiPlayCount, tiLastPlayed] then
    begin
      NeedsStats := True;
      Break;
    end;
  end;

  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track  := PTrackInfo(FTracks[I]);
      UStats := nil;

      if NeedsStats and Assigned(UserStatsManager) then
      begin
        UStats := UserStatsManager.PeekStats(Track^.PrimaryFingerprint);
        if (not Assigned(UStats)) and (Track^.FallbackFingerprint <> '') then
          UStats := UserStatsManager.PeekStats(Track^.FallbackFingerprint);
      end;

      if EvaluateTrack(ParsedConditions, Track, UStats) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;

  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  // (SortTrackList, which sorted under the lock, is gone: callers sort their
  // copies with CompareTrackInfo)
  if ASort then
    ATracks.Sort(@CompareTrackInfo);
end;

function TLibraryManager.GetLoadSummary: string;
begin
  Result := SafeFormat(FMT_LOG_DB_LOADED_DETAIL,
    [FTracks.Count,
     FLoadReadMs div 1000,  FLoadReadMs mod 1000,
     FLoadParseMs div 1000, FLoadParseMs mod 1000,
     FLoadDictMs div 1000,  FLoadDictMs mod 1000]);
end;

procedure TLibraryManager.UpdateRecord(const UpdatedData: TTrackInfo);
var
  Track: PTrackInfo;
  ParsedYear: Integer;
  OldPrimary, OldFallback: string;
begin
  FCriticalSection.Enter;
  try
    Track := FindTrack(UpdatedData.FilePath);

    if Assigned(Track) then
    begin
      OldPrimary  := Track^.PrimaryFingerprint;
      OldFallback := Track^.FallbackFingerprint;

      // ---> AUDIT FIX D3: Use ExcludeTrailingPathDelimiter(ExtractFileDir(...))
      // so FolderDir never gains a trailing backslash after a tag edit!
      Track^.FolderDir    := ExcludeTrailingPathDelimiter(ExtractFileDir(Track^.FilePath));
      Track^.FileNameOnly := ExtractFileName(Track^.FilePath);

      if Trim(UpdatedData.Title) <> '' then
        Track^.Title := Trim(UpdatedData.Title)
      else
        Track^.Title := Track^.FileNameOnly;

      Track^.Artist := NormalizeSemicolons(UpdatedData.Artist);
      if Track^.Artist = '' then
        Track^.Artist := LBL_UNKNOWN_ARTIST;

      Track^.AlbumArtist := NormalizeSemicolons(UpdatedData.AlbumArtist);
      if Track^.AlbumArtist = '' then
        Track^.AlbumArtist := Track^.Artist;

      Track^.Album := NormalizeSemicolons(Trim(UpdatedData.Album));
      if Track^.Album = '' then
        Track^.Album := LBL_UNKNOWN_ALBUM;

      Track^.Genre       := NormalizeSemicolons(UpdatedData.Genre);
      Track^.Composer    := NormalizeSemicolons(UpdatedData.Composer);
      Track^.Performer   := NormalizeSemicolons(UpdatedData.Performer);
      Track^.DateStr     := Trim(UpdatedData.DateStr);

      ParsedYear := StrToIntDef(Copy(Track^.DateStr, 1, 4), 0);
      if ParsedYear > 0 then
        Track^.Year := ParsedYear
      else if UpdatedData.Year > 0 then
        Track^.Year := UpdatedData.Year
      else
        Track^.Year := 0;

      Track^.TrackNumber := UpdatedData.TrackNumber;
      Track^.DiscNumber  := UpdatedData.DiscNumber;
      Track^.Comment     := UpdatedData.Comment;

      if UpdatedData.LastModified > 0 then
        Track^.LastModified := UpdatedData.LastModified;
      if UpdatedData.FileSize > 0 then
        Track^.FileSize := UpdatedData.FileSize;

      Track^.CleanTitle       := LowerCase(StripAccents(Track^.Title));
      Track^.CleanArtist      := LowerCase(StripAccents(Track^.Artist));
      Track^.CleanAlbumArtist := LowerCase(StripAccents(Track^.AlbumArtist));
      Track^.CleanAlbum       := LowerCase(StripAccents(Track^.Album));
      Track^.CleanGenre       := LowerCase(StripAccents(Track^.Genre));
      Track^.CleanComposer    := LowerCase(StripAccents(Track^.Composer));
      Track^.CleanPerformer   := LowerCase(StripAccents(Track^.Performer));
      Track^.CleanFolder      := LowerCase(StripAccents(Track^.FolderDir));

      if Assigned(UserStatsManager) then
      begin
        Track^.PrimaryFingerprint := UserStatsManager.GenerateFingerprintFromClean(
          Track^.CleanAlbumArtist, Track^.CleanAlbum, Track^.CleanTitle);

        if Track^.CleanAlbumArtist <> Track^.CleanArtist then
          Track^.FallbackFingerprint := UserStatsManager.GenerateFingerprintFromClean(
            Track^.CleanArtist, Track^.CleanAlbum, Track^.CleanTitle)
        else
          Track^.FallbackFingerprint := '';

        UserStatsManager.MigrateStats(OldPrimary, OldFallback, Track^.PrimaryFingerprint);
      end;

      ClearCaches;
      FIsDirty := True;
      JournalTrack(Track);

      // ---> AUDIT FIX: The running scan may already hold the old record
      if FIsScanning then
        FUpdatedDuringScan.Add(Track^.FilePath);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.TryGetTrack(const APath: string; out ATrack: TTrackInfo): Boolean;
var
  Track: PTrackInfo;
begin
  ATrack := Default(TTrackInfo);
  FCriticalSection.Enter;
  try
    Track  := FindTrack(APath);
    Result := Assigned(Track);
    if Result then
      ATrack := Track^;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.SnapshotTracks: TTrackInfoArray;
var
  I, N: Integer;
begin
  Result := nil;
  FCriticalSection.Enter;
  try
    SetLength(Result, FTracks.Count);
    N := 0;
    for I := 0 to FTracks.Count - 1 do
      if Assigned(FTracks[I]) then
      begin
        Result[N] := PTrackInfo(FTracks[I])^;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.AnyTrackMissingReplayGain(AFiles: TStrings): Boolean;
var
  I: Integer;
  Track: PTrackInfo;
begin
  Result := False;
  if not Assigned(AFiles) then
    Exit;
  FCriticalSection.Enter;
  try
    for I := 0 to AFiles.Count - 1 do
    begin
      Track := FindTrack(AFiles[I]);
      if Assigned(Track) and (not Track^.HasReplayGain) then
        Exit(True);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.SetReplayGainFlag(const APath: string; AHasReplayGain: Boolean;
  AFileTime: Int64; AFileSize: Int64): Boolean;
var
  Track: PTrackInfo;
  Changed: Boolean;
begin
  FCriticalSection.Enter;
  try
    Track  := FindTrack(APath);
    Result := Assigned(Track);
    if not Result then
      Exit;

    Changed := False;
    if Track^.HasReplayGain <> AHasReplayGain then
    begin
      Track^.HasReplayGain := AHasReplayGain;
      Changed := True;
    end;

    // The date and size the scanner will see, so the next scan does not take
    // Aulumic's own save for a change
    if (AFileTime > 0) and
       ((Track^.LastModified <> AFileTime) or (Track^.FileSize <> AFileSize)) then
    begin
      Track^.LastModified := AFileTime;
      Track^.FileSize     := AFileSize;
      Changed := True;
    end;
    if Changed then
    begin
      FIsDirty := True;
      JournalTrack(Track);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.SetReplayGainFlags(AFiles: TStrings; AHasReplayGain: Boolean): Integer;
var
  I: Integer;
  Track: PTrackInfo;
begin
  Result := 0;
  if not Assigned(AFiles) then
    Exit;
  FCriticalSection.Enter;
  try
    for I := 0 to AFiles.Count - 1 do
    begin
      Track := FindTrack(AFiles[I]);
      if Assigned(Track) and (Track^.HasReplayGain <> AHasReplayGain) then
      begin
        Track^.HasReplayGain := AHasReplayGain;
        JournalTrack(Track);
        Inc(Result);
      end;
    end;
    if Result > 0 then
      FIsDirty := True;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.ClearReplayGainForAlbums(AAlbums: TStrings): Integer;
var
  I: Integer;
  Track: PTrackInfo;
begin
  Result := 0;
  if (not Assigned(AAlbums)) or (AAlbums.Count = 0) then
    Exit;
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      if Assigned(Track) and Track^.HasReplayGain and (AAlbums.IndexOf(Track^.Album) >= 0) then
      begin
        Track^.HasReplayGain := False;
        JournalTrack(Track);
        Inc(Result);
      end;
    end;
    if Result > 0 then
      FIsDirty := True;
  finally
    FCriticalSection.Leave;
  end;
end;

function TLibraryManager.ToggleAlbumFavorite(const AAlbumArtist, AAlbum, ATitle: string): Boolean;
var
  Fingerprint      : string;
  I                : Integer;
  Track            : PTrackInfo;
  TrackFingerprint : string;
begin
  Result := False;
  if not Assigned(UserStatsManager) then
    Exit;

  // 1. Toggle the favorite state for the target track and capture the new state
  Fingerprint := UserStatsManager.GenerateFingerprint(AAlbumArtist, AAlbum, ATitle);
  Result      := UserStatsManager.ToggleFavorite(Fingerprint);

  // 2. Apply this state (and 5-star rating) to all tracks of the album in FTracks
  if Assigned(FTracks) then
  begin
    FCriticalSection.Enter;
    try
      for I := 0 to FTracks.Count - 1 do
      begin
        Track := PTrackInfo(FTracks[I]);
        if Assigned(Track) and
           SameText(Track^.AlbumArtist, AAlbumArtist) and
           SameText(Track^.Album, AAlbum) then
        begin
          TrackFingerprint := Track^.PrimaryFingerprint;
          if TrackFingerprint = '' then
            TrackFingerprint := UserStatsManager.GenerateFingerprint(
              Track^.AlbumArtist,
              Track^.Album,
              Track^.Title);

          UserStatsManager.SetFavorite(TrackFingerprint, Result);

          if Track^.FallbackFingerprint <> '' then
            UserStatsManager.SetFavorite(Track^.FallbackFingerprint, Result);
        end;
      end;
    finally
      FCriticalSection.Leave;
    end;
  end;

  // 3. Commit to disk immediately
  UserStatsManager.SaveToFile;
end;

// ---> AUDIT FIX S4: Pop esLibraryBusy if FIsScanning was True when StopScan is called
procedure TLibraryManager.StopScan;
var
  WasScanning: Boolean;
begin
  WasScanning := FIsScanning;
  FIsScanning := False;

  if Assigned(FScannerThread) then
  begin
    FScannerThread.OnTerminate := nil;
    FScannerThread.Terminate;
    FScannerThread.WaitFor;
    TThread.RemoveQueuedEvents(FScannerThread);
    FreeAndNil(FScannerThread);
  end;

  CleanupFinishedScanner(0);

  if WasScanning and Assigned(AppStateManager) then
    AppStateManager.PopState(esLibraryBusy);
end;

procedure TLibraryManager.DoScanProgress(const ScanMsg, CurrentFolder: string;
  TrackCount, TotalTracks: Integer);
begin
  if Assigned(FOnScanProgress) then
    FOnScanProgress(Self, ScanMsg, CurrentFolder, TrackCount, TotalTracks);
end;

procedure TLibraryManager.BeginShutdown;
begin
  FShuttingDown         := True;
  FPendingScanRequested := False;
end;

function TLibraryManager.IsScanning: boolean;
begin
  Result := FIsScanning;
end;

procedure TLibraryManager.ProcessPendingScans;
begin
  if FPendingScanRequested then
  begin
    FPendingScanRequested := False;
    QueueOrStartScan(FPendingScanFullRebuild, True);
  end;
end;

procedure TLibraryManager.GetTracksInFolder(const FolderDir: string; ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
  TargetDir: string;
begin
  ATracks.Clear;
  TargetDir := ExcludeTrailingPathDelimiter(FolderDir);
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      if SameText(ExcludeTrailingPathDelimiter(Track^.FolderDir), TargetDir) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

procedure TLibraryManager.GetUniqueArtists(ResultList: TStrings);
begin
  FCriticalSection.Enter;
  try
    ValidateCaches;
    ResultList.Assign(FArtistSummaryCache);
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetUniqueAlbums(ResultList: TStrings);
begin
  FCriticalSection.Enter;
  try
    ValidateCaches;
    ResultList.Assign(FAlbumSummaryCache);
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetTracksByArtist(const ArtistName: string; ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
begin
  ATracks.Clear;
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      if ContainsDelimitedItem(Track^.AlbumArtist, ArtistName) or
         ContainsDelimitedItem(Track^.Artist, ArtistName) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

procedure TLibraryManager.GetTracksByAlbum(const AlbumName: string; ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
  TargetAlb, TrackArt, CompositeStr: string;
begin
  ATracks.Clear;
  TargetAlb := Trim(AlbumName);
  if TargetAlb = '' then
    Exit;

  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);

      TrackArt := Trim(Track^.AlbumArtist);
      if TrackArt = '' then
        TrackArt := Trim(Track^.Artist);
      if TrackArt = '' then
        TrackArt := LBL_UNKNOWN_ARTIST;

      CompositeStr := Format('%s - %s', [TrackArt, Trim(Track^.Album)]);

      if SameText(CompositeStr, TargetAlb) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

procedure TLibraryManager.GetUniqueGenres(ResultList: TStrings);
begin
  FCriticalSection.Enter;
  try
    ValidateCaches;
    ResultList.Assign(FGenreSummaryCache);
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TLibraryManager.GetTracksByGenre(const GenreName: string; ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
begin
  ATracks.Clear;
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      if ContainsDelimitedItem(Track^.Genre, GenreName) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

procedure TLibraryManager.GetAlbumsByArtist(const ArtistName: string;
  ResultList: TStrings);
var
  I: integer;
  Track: PTrackInfo;
  TempList: TStringList;
  AAlbum: string;
begin
  TempList            := TStringList.Create;
  TempList.Sorted     := True;
  TempList.Duplicates := dupIgnore;
  // ---> AUDIT FIX: Ensure TempList is freed inside try..finally
  try
    FCriticalSection.Enter;
    try
      for I := 0 to FTracks.Count - 1 do
      begin
        Track := PTrackInfo(FTracks[I]);
        if ContainsDelimitedItem(Track^.AlbumArtist, ArtistName) or
           ContainsDelimitedItem(Track^.Artist, ArtistName) then
        begin
          AAlbum := Trim(Track^.Album);
          if AAlbum = '' then
            AAlbum := LBL_UNKNOWN_ALBUM;
          TempList.Add(AAlbum);
        end;
      end;
    finally
      FCriticalSection.Leave;
    end;
    ResultList.Assign(TempList);
  finally
    TempList.Free;
  end;
end;

procedure TLibraryManager.GetAlbumsByGenre(const GenreName: string;
  ResultList: TStrings);
var
  I: integer;
  Track: PTrackInfo;
  TempList: TStringList;
  AAlbum: string;
begin
  TempList            := TStringList.Create;
  TempList.Sorted     := True;
  TempList.Duplicates := dupIgnore;
  // ---> AUDIT FIX: Ensure TempList is freed inside try..finally
  try
    FCriticalSection.Enter;
    try
      for I := 0 to FTracks.Count - 1 do
      begin
        Track := PTrackInfo(FTracks[I]);
        if ContainsDelimitedItem(Track^.Genre, GenreName) then
        begin
          AAlbum := Trim(Track^.Album);
          if AAlbum = '' then
            AAlbum := LBL_UNKNOWN_ALBUM;
          TempList.Add(AAlbum);
        end;
      end;
    finally
      FCriticalSection.Leave;
    end;
    ResultList.Assign(TempList);
  finally
    TempList.Free;
  end;
end;

procedure TLibraryManager.GetTracksByArtistAndAlbum(const ArtistName, AlbumName: string;
  ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
  Alb: string;
begin
  ATracks.Clear;
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      Alb   := Trim(Track^.Album);
      if Alb = '' then
        Alb := LBL_UNKNOWN_ALBUM;
      if (ContainsDelimitedItem(Track^.AlbumArtist, ArtistName) or
          ContainsDelimitedItem(Track^.Artist, ArtistName)) and
         SameText(Alb, Trim(AlbumName)) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

procedure TLibraryManager.GetTracksByGenreAndAlbum(const GenreName, AlbumName: string;
  ATracks: TTrackList);
var
  I: integer;
  Track: PTrackInfo;
  Alb: string;
begin
  ATracks.Clear;
  FCriticalSection.Enter;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);
      Alb   := Trim(Track^.Album);
      if Alb = '' then
        Alb := LBL_UNKNOWN_ALBUM;
      if ContainsDelimitedItem(Track^.Genre, GenreName) and
         SameText(Alb, Trim(AlbumName)) then
        ATracks.Add(Track^);
    end;
  finally
    FCriticalSection.Leave;
  end;
  // ---> CHANGED (phase 4): Copies, so sorted after the lock is released
  ATracks.Sort(@CompareTrackInfo);
end;

procedure TLibraryManager.ClearCaches;
begin
  FArtistSummaryCache.Clear;
  FArtistSummaryCache.Capacity := 0;

  FGenreSummaryCache.Clear;
  FGenreSummaryCache.Capacity := 0;

  FAlbumSummaryCache.Clear;
  FAlbumSummaryCache.Capacity := 0;

  ClearFolderIndex;

  FCachesValid := False;
end;

procedure TLibraryManager.ClearFolderIndex;
begin
  FFolderIndex.Clear; // OwnsObjects: frees the child lists
  FFolderIndexValid := False;
end;

// Builds the folder tree of the library from the tracks' folders (and the
// virtual folders that point to music). Called under FCriticalSection.
procedure TLibraryManager.ValidateFolderIndex;
var
  Roots: TStringList;

  function ChildrenAt(AIdx: Integer): TStringList;
  begin
    Result := TStringList(FFolderIndex.Objects[AIdx]);
  end;

  function AddFolder(const ADir: string): Integer;
  var
    Children: TStringList;
  begin
    Children               := TStringList.Create;
    Children.Sorted        := True;
    Children.Duplicates    := dupIgnore;
    Children.CaseSensitive := False;
    Children.UseLocale     := False;
    Result := FFolderIndex.AddObject(ADir, Children);
  end;

  // Adds ADir and every folder above it, up to its library root (stops as
  // soon as a folder is already known: everything above it is too)
  procedure AddFolderChain(const ADir: string);
  var
    D, P: string;
    Idx: Integer;
    Existed: Boolean;
  begin
    D := ExcludeTrailingPathDelimiter(ADir);
    if (D = '') or FFolderIndex.Find(D, Idx) then
      Exit;
    AddFolder(D);

    while not Roots.Find(D, Idx) do
    begin
      P := ExcludeTrailingPathDelimiter(ExtractFileDir(D));
      if (P = '') or SameText(P, D) then
        Break;
      Existed := FFolderIndex.Find(P, Idx);
      if not Existed then
        Idx := AddFolder(P);
      ChildrenAt(Idx).Add(ExtractFileName(D));
      if Existed then
        Break;
      D := P;
    end;
  end;

var
  I, J, Idx: Integer;
  Targets: TStringList;
  LinkDir: string;
begin
  if FFolderIndexValid then
    Exit;

  ClearFolderIndex;
  Roots := TStringList.Create;
  try
    Roots.Sorted        := True;
    Roots.Duplicates    := dupIgnore;
    Roots.CaseSensitive := False;
    Roots.UseLocale     := False;
    for I := 0 to FScanFolders.Count - 1 do
      Roots.Add(ExcludeTrailingPathDelimiter(FScanFolders[I]));

    FFolderIndex.BeginUpdate;
    try
      for I := 0 to FTracks.Count - 1 do
        if Assigned(FTracks[I]) then
          AddFolderChain(PTrackInfo(FTracks[I])^.FolderDir);

      // A virtual folder is shown when at least one of its targets has music
      for I := 0 to FLinks.Count - 1 do
      begin
        Targets := TStringList(FLinks.Objects[I]);
        for J := 0 to Targets.Count - 1 do
        begin
          if FFolderIndex.Find(ExcludeTrailingPathDelimiter(Targets[J]), Idx) then
          begin
            LinkDir := ExcludeTrailingPathDelimiter(ExtractFileDir(FLinks[I]));
            AddFolderChain(LinkDir);
            if FFolderIndex.Find(LinkDir, Idx) then
              ChildrenAt(Idx).Add(ExtractFileName(FLinks[I]));
            Break;
          end;
        end;
      end;
    finally
      FFolderIndex.EndUpdate;
    end;
  finally
    Roots.Free;
  end;

  FFolderIndexValid := True;
end;

procedure TLibraryManager.GetSubFolders(const FolderDir: string; ResultList: TStrings);
var
  Idx, I: Integer;
  Children: TStringList;
begin
  ResultList.BeginUpdate;
  try
    ResultList.Clear;
    FCriticalSection.Enter;
    try
      ValidateFolderIndex;
      if FFolderIndex.Find(ExcludeTrailingPathDelimiter(FolderDir), Idx) then
      begin
        Children := TStringList(FFolderIndex.Objects[Idx]);
        for I := 0 to Children.Count - 1 do
          ResultList.Add(Children[I]);
      end;
    finally
      FCriticalSection.Leave;
    end;
  finally
    ResultList.EndUpdate;
  end;
end;

function TLibraryManager.GetVirtualLinkTargets(const ALinkPath: string;
  ATargets: TStringList; AOnlyWithMusic: Boolean): Boolean;
var
  Idx, I, Dummy: Integer;
  Targets: TStringList;
begin
  ATargets.Clear;
  FCriticalSection.Enter;
  try
    Idx    := FLinks.IndexOf(ALinkPath);
    Result := Idx >= 0;
    if Result then
    begin
      if AOnlyWithMusic then
        ValidateFolderIndex;
      Targets := TStringList(FLinks.Objects[Idx]);
      for I := 0 to Targets.Count - 1 do
        if (not AOnlyWithMusic) or
           FFolderIndex.Find(ExcludeTrailingPathDelimiter(Targets[I]), Dummy) then
          ATargets.Add(Targets[I]);
    end;
  finally
    FCriticalSection.Leave;
  end;

  // Not in the library (yet): read the link file itself
  if not Result then
    ParseAulLinkFile(ALinkPath, ATargets);
end;

procedure TLibraryManager.RefreshVirtualLink(const ALinkPath: string);
var
  Targets: TStringList;
  Idx: Integer;
begin
  if ALinkPath = '' then
    Exit;

  Targets := nil;
  try
    if FileExists(ALinkPath) then
    begin
      Targets := TStringList.Create;
      Targets.CaseSensitive := False;
      ParseAulLinkFile(ALinkPath, Targets, False);
    end;

    FCriticalSection.Enter;
    try
      Idx := FLinks.IndexOf(ALinkPath);
      if Idx >= 0 then
        FLinks.Delete(Idx); // OwnsObjects: frees the old target list
      if Assigned(Targets) then
      begin
        FLinks.AddObject(ALinkPath, Targets);
        Targets := nil; // owned by FLinks now
      end;
      if FIsScanning then
        FLinksChangedDuringScan.Add(ALinkPath);
      ClearFolderIndex;
      FIsDirty := True;
    finally
      FCriticalSection.Leave;
    end;
  finally
    Targets.Free;
  end;

  // Saved after the scan when one is running (SaveDatabase waits for it)
  if (not FIsScanning) and Assigned(Application) then
    Application.QueueAsyncCall(@ExecuteAsyncSave, 0);
end;

function TLibraryManager.IsRootAvailable(const ARoot: string): Boolean;
var
  Drive: string;
  Bit: Integer;
begin
  Drive := ExtractFileDrive(ARoot);
  if (Length(Drive) = 2) and (Drive[2] = ':') then
  begin
    // Drive letter: present? (GetLogicalDrives does not touch the disks)
    Bit := Ord(UpCase(Drive[1])) - Ord('A');
    if (Bit < 0) or (Bit > 25) or ((GetLogicalDrives and (DWORD(1) shl Bit)) = 0) then
      Exit(False);
    // A local drive that is present is available; a mapped network drive
    // stays listed while the server is off, so it is judged by the last scan
    if GetDriveType(PChar(Drive + PathDelim)) <> DRIVE_REMOTE then
      Exit(True);
  end;

  FCriticalSection.Enter;
  try
    Result := FUnavailableRoots.IndexOf(ExcludeTrailingPathDelimiter(ARoot)) < 0;
  finally
    FCriticalSection.Leave;
  end;
end;

// Puts the links found by the scan in place (main thread, under
// FCriticalSection). Keeps the existing links the scan could not read, and
// the links changed in Aulumic during the scan. True when anything changed.
function TLibraryManager.MergeScannedLinks(AScanner: TLibraryScannerThread): Boolean;

  function CopyTargets(ASource: TObject): TStringList;
  begin
    Result := TStringList.Create;
    Result.CaseSensitive := False;
    Result.Assign(TStringList(ASource));
  end;

var
  NewLinks: TStringList;
  I, Idx: Integer;
begin
  NewLinks := AScanner.ScannedLinks;

  for I := 0 to FLinks.Count - 1 do
    if (NewLinks.IndexOf(FLinks[I]) < 0) and AScanner.KeepsExistingLink(FLinks[I]) then
      NewLinks.AddObject(FLinks[I], CopyTargets(FLinks.Objects[I]));

  for I := 0 to FLinksChangedDuringScan.Count - 1 do
  begin
    Idx := NewLinks.IndexOf(FLinksChangedDuringScan[I]);
    if Idx >= 0 then
      NewLinks.Delete(Idx);
    Idx := FLinks.IndexOf(FLinksChangedDuringScan[I]);
    if Idx >= 0 then
      NewLinks.AddObject(FLinks[Idx], CopyTargets(FLinks.Objects[Idx]));
  end;
  FLinksChangedDuringScan.Clear;

  Result := NewLinks.Count <> FLinks.Count;
  if not Result then
    for I := 0 to FLinks.Count - 1 do
      if (not SameText(FLinks[I], NewLinks[I])) or
         (TStringList(FLinks.Objects[I]).Text <> TStringList(NewLinks.Objects[I]).Text) then
      begin
        Result := True;
        Break;
      end;

  // Swap: the scanner frees the old list with its own
  FLinks := AScanner.SwapScannedLinks(FLinks);
  ClearFolderIndex;
end;

// ---> AulumicNS: the names for the Artists / Albums / Genres nodes. Was: one
// language-aware sorted list per kind, searched and filled for every track
// (IndexOf / Add: a Windows comparison per step, 0.7 s for 46,000 tracks on the
// UI thread at the first opening of such a node and after every change of the
// library), with a count and an album list per name that nothing read. Now
// the distinct spellings are collected first (TNameSet) and only those go
// into the sorted lists: the same lists as before.
procedure TLibraryManager.ValidateCaches;
var
  Albums, Artists, Genres: TNameSet;
  I: Integer;
  Track: PTrackInfo;
  Art, Alb: string;
begin
  if FCachesValid then
    Exit;

  ClearCaches;
  Albums  := TNameSet.Create;
  Artists := TNameSet.Create;
  Genres  := TNameSet.Create;
  try
    for I := 0 to FTracks.Count - 1 do
    begin
      Track := PTrackInfo(FTracks[I]);

      // The album as the tree shows it: "Artist - Album" (the album artist,
      // else the artist)
      Alb := Trim(Track^.Album);
      if Alb = '' then
        Alb := LBL_UNKNOWN_ALBUM;
      Art := Trim(Track^.AlbumArtist);
      if Art = '' then
        Art := Trim(Track^.Artist);
      if Art = '' then
        Art := LBL_UNKNOWN_ARTIST;
      Albums.Note(Art + ' - ' + Alb);

      if not Artists.NoteItems(Track^.AlbumArtist) then
        Artists.Note(LBL_UNKNOWN_ARTIST);
      if not Genres.NoteItems(Track^.Genre) then
        Genres.Note(LBL_UNKNOWN_GENRE);
    end;

    Albums.AddTo(FAlbumSummaryCache);
    Artists.AddTo(FArtistSummaryCache);
    Genres.AddTo(FGenreSummaryCache);
  finally
    Genres.Free;
    Artists.Free;
    Albums.Free;
  end;

  FCachesValid := True;
end;
end.
