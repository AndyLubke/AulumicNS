unit uLibraryScanner;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uLibraryScanner
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TLibraryScannerThread recursively scans the library folders in the
  background, reads the tags of new and changed files and builds the new
  track list (and the virtual folders) without freezing the UI.
  TLibraryManager starts it (StartScan) and takes over its results when it
  has ended (HandleScannerFinished); it hands the thread its lock (for the
  existing records) and a progress method when it creates it.
  Covered by Tests\TestLibraryScanner.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils, SyncObjs, ALMetadata, uLibraryTypes, uDbStore;

type
  // ---> ADDED: Progress of a scan, called on the main thread (TThread.Queue).
  // TLibraryManager passes a method that looks up its OnScanProgress at the
  // moment of the call, so clearing that event also stops the reports.
  TScanProgressProc = procedure(const ScanMsg, CurrentFolder: string;
    TrackCount, TotalTracks: Integer) of object;

  { TLibraryScannerThread }

  TLibraryScannerThread = class(TThread)
  private
    // ---> CHANGED: The manager's lock and progress method (was the manager
    // itself, whose private fields this class used)
    FLock             : TCriticalSection;
    FOnProgress       : TScanProgressProc;
    FFoldersToScan    : TStringList;
    FTempMeta         : TAudioMetadata;
    FScannedTracks    : TList;
    FCurrentDir       : string;
    FScanMsg          : string;
    FProgressCounter  : integer;
    FExistingDict     : TStringList;
    FCheckedThumbs    : TStringList;
    // ---> AulumicNS: the texts that repeat from track to track (folder,
    // artist, album ...) once, and their search forms per pool id: the
    // records of a scan take half the memory, and the search form of an
    // artist is made once, not for every track
    FTextPool         : TDbStrPool;
    FCleanTexts       : array of string;
    FIsRefresh        : boolean;
    FExistingDBRef    : TList;
    FHasChanges       : boolean;
    FTracksAdded      : integer;
    FTracksModified   : integer;
    // ---> AUDIT FIX: Set when Execute aborted on an unexpected exception, so the
    // (partial) results are discarded instead of replacing the library.
    FScanFailed       : boolean;
    FTotalFilesToScan : integer;
    FIsCounting       : boolean;
    FLastUITick       : QWord;
    // ---> AUDIT FIX: One flag per FExistingDict entry: True once that record is
    // represented in FScannedTracks (re-read, cloned or carried over), so a
    // carry-over never duplicates a track and works across subfolders.
    FExistingTaken    : array of Boolean;
    // Scan folders whose drive disappeared during the scan (reported by
    // HandleScannerFinished)
    FRootsLost        : TStringList;
    // Scan folders that were already unavailable when the scan started
    FRootsOffline     : TStringList;
    // Virtual folders (.aullink) found by this scan: link file -> TStringList
    // of target folders (owned). Swapped into the manager when the scan ends.
    FScannedLinks     : TStringList;
    // Folders whose links were not read this time (listing failed, drive
    // gone): their existing links are kept. Objects = 1: also the subfolders.
    FLinkKeepDirs     : TStringList;
    // Link files that could not be read this time: the existing entry is kept
    FLinkKeepFiles    : TStringList;

    procedure PreScanCount(const Dir: string);
    function  ScanRootGone(const APath: string): Boolean;
    procedure HandleLostRoots;
    procedure ScanDirectory(const Dir: string);
    procedure MarkExistingTaken(const APath: string);
    procedure CarryOverExistingUnder(const ADir: string; IncludeSubDirs: Boolean);
    procedure CarryOverSingle(const APath: string);
    procedure AddLinkLocal(const ALinkPath: string);
    function PooledText(const S: string; out AId: Cardinal): string;
    function CleanText(AId: Cardinal; const ASource: string): string;
    procedure AddTrackLocal(const AFilePath, AFolderDir: string;
      var AMeta: TAudioMetadata; AFileTime: int64; AFileSize: Int64);
    procedure SyncProgress;
  protected
    procedure Execute; override;

  public
    FScannedFolderCount : integer;

    // ALock: the manager's lock (guards ExistingDB's records); AOnProgress:
    // see TScanProgressProc; ExistingDB: the manager's current track list
    constructor Create(ALock: TCriticalSection; AOnProgress: TScanProgressProc;
      Folders: TStringList; ExistingDB: TList; IsRefresh: boolean);
    destructor Destroy; override;

    // ---> CHANGED: Public (TLibraryManager.MergeScannedLinks uses it)
    function  KeepsExistingLink(const ALinkPath: string): Boolean;
    // ---> ADDED: Hands over the virtual folders found by the scan (the list
    // ScannedLinks returns) and keeps AReplacement instead, which is freed
    // with this thread. Used by TLibraryManager.MergeScannedLinks.
    function  SwapScannedLinks(AReplacement: TStringList): TStringList;

    property ScannedTracks: TList read FScannedTracks;
    property RootsLostDuringScan: TStringList read FRootsLost;
    property RootsOfflineAtStart: TStringList read FRootsOffline;
    // ---> ADDED: Results read by TLibraryManager.HandleScannerFinished (it
    // used the private fields before)
    property TracksAdded: integer read FTracksAdded;
    property TracksModified: integer read FTracksModified;
    property ScanFailed: boolean read FScanFailed;
    property HasChanges: boolean read FHasChanges;
    property ScannedLinks: TStringList read FScannedLinks;
  end;

implementation

uses
  AuAudioTypes, StrUtils, DateUtils, uAppStrings, uAppConsts, uEngineStateManager,
  uAudioUtils, uMetaUtils, uOSUtils, AuLog, uUserStatsManager;

{ TLibraryScannerThread }

constructor TLibraryScannerThread.Create(ALock: TCriticalSection;
  AOnProgress: TScanProgressProc; Folders: TStringList; ExistingDB: TList;
  IsRefresh: boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Priority        := tpLower;

  FLock            := ALock;
  FOnProgress      := AOnProgress;
  FScannedTracks   := TList.Create;
  FFoldersToScan   := TStringList.Create;
  FFoldersToScan.Assign(Folders);
  FProgressCounter := 0;

  FExistingDict               := TStringList.Create;
  FExistingDict.CaseSensitive := False;
  FExistingDict.Duplicates    := dupIgnore;
  // ---> AUDIT FIX: Plain (non-locale) comparison for this internal path list.
  // The locale comparison converts both strings to UTF-16 and calls Windows on
  // every comparison, which made sorting/lookups of ~50,000 paths slow.
  FExistingDict.UseLocale     := False;

  FTextPool                    := TDbStrPool.Create;
  FCheckedThumbs               := TStringList.Create;
  FCheckedThumbs.Sorted        := True;
  FCheckedThumbs.Duplicates    := dupIgnore;
  FCheckedThumbs.CaseSensitive := False;
  FCheckedThumbs.UseLocale     := False; // internal hash list

  FIsRefresh      := IsRefresh;
  FExistingDBRef  := ExistingDB;
  FHasChanges     := not IsRefresh;
  FTracksAdded    := 0;
  FTracksModified := 0;
  FScanFailed     := False;

  FRootsLost               := TStringList.Create;
  FRootsLost.Sorted        := True;
  FRootsLost.Duplicates    := dupIgnore;
  FRootsLost.CaseSensitive := False;

  FRootsOffline               := TStringList.Create;
  FRootsOffline.Sorted        := True;
  FRootsOffline.Duplicates    := dupIgnore;
  FRootsOffline.CaseSensitive := False;

  FScannedLinks               := TStringList.Create;
  FScannedLinks.Sorted        := True;
  FScannedLinks.Duplicates    := dupIgnore;
  FScannedLinks.CaseSensitive := False;
  FScannedLinks.UseLocale     := False;
  FScannedLinks.OwnsObjects   := True;

  FLinkKeepDirs := TStringList.Create;

  FLinkKeepFiles               := TStringList.Create;
  FLinkKeepFiles.Sorted        := True;
  FLinkKeepFiles.Duplicates    := dupIgnore;
  FLinkKeepFiles.CaseSensitive := False;
  FLinkKeepFiles.UseLocale     := False;
  SetLength(FExistingTaken, 0);
end;

destructor TLibraryScannerThread.Destroy;
var
  I: integer;
begin
  TThread.RemoveQueuedEvents(Self);
  FFoldersToScan.Free;
  FExistingDict.Free;
  FCheckedThumbs.Free;
  FTextPool.Free;
  FRootsLost.Free;
  FRootsOffline.Free;
  FScannedLinks.Free;
  FLinkKeepDirs.Free;
  FLinkKeepFiles.Free;
  SetLength(FExistingTaken, 0);

  if Assigned(FScannedTracks) then
  begin
    for I := 0 to FScannedTracks.Count - 1 do
      if Assigned(FScannedTracks[I]) then
        Dispose(PTrackInfo(FScannedTracks[I]));

    FScannedTracks.Free;
  end;

  inherited Destroy;
end;

function TLibraryScannerThread.PooledText(const S: string; out AId: Cardinal): string;
begin
  AId    := FTextPool.InternCopy(S);
  Result := FTextPool.Str(AId);
end;

// the search form (lower case, without accents) of the pooled text AId
function TLibraryScannerThread.CleanText(AId: Cardinal; const ASource: string): string;
begin
  if AId = 0 then
    Exit('');
  if AId >= Cardinal(Length(FCleanTexts)) then
    SetLength(FCleanTexts, (Integer(AId) + 1) * 2);
  if FCleanTexts[AId] = '' then
    FCleanTexts[AId] := LowerCase(StripAccents(ASource));
  Result := FCleanTexts[AId];
end;

procedure TLibraryScannerThread.AddTrackLocal(const AFilePath,
  AFolderDir: string; var AMeta: TAudioMetadata; AFileTime: int64;
  AFileSize: Int64);

  function SanitizeTagField(const S: string; MaxLen: Integer = 1024): string;
  var
    I, DestIdx, Limit: Integer;
    C: Char;
  begin
    if S = '' then
      Exit('');

    Limit := Length(S);
    if Limit > MaxLen then
      Limit := MaxLen;

    SetLength(Result, Limit);
    DestIdx := 0;

    for I := 1 to Limit do
    begin
      C := S[I];
      if not (C in [#0..#8, #11, #12, #14..#31]) then
      begin
        Inc(DestIdx);
        Result[DestIdx] := C;
      end;
    end;

    SetLength(Result, DestIdx);
    Result := Trim(Result);
  end;

  function CompactStr(const S: string): string; inline;
  begin
    Result := '';
    if S <> '' then
    begin
      SetLength(Result, Length(S));
      Move(S[1], Result[1], Length(S));
    end;
  end;

var
  PTrack, ExistingTrack: PTrackInfo;
  Idx: Integer;
  HasRG: Boolean;
  ExistingDateAdded: Int64;
  UpperAllTags, CleanFolderDir: string;
  LTitle, LAlbum, LArtist, LAlbumArtist, LGenre, LComposer, LPerformer: string;
  LDuration, LComment, LDateStr: string;
  LTrackNum, LDiscNum, LYear, LSampleRate, LBitDepth: Integer;
  IdFolder, IdAlbum, IdArtist, IdAlbumArtist, IdGenre, IdComposer, IdPerformer, IdOther: Cardinal;
begin
  // 1. Extract ReplayGain boolean
  if Length(AMeta.AllTags) <= 65536 then
    UpperAllTags := UpperCase(AMeta.AllTags)
  else
    UpperAllTags := UpperCase(Copy(AMeta.AllTags, 1, 65536));

  // ---> AUDIT FIX: Both a track gain and an album gain are required, so a
  // file with only a track gain is offered by a normal ReplayGain scan
  // ---> AulumicNS: a track without an album tag has no album gain to get
  // (the ReplayGain scan gives it its track gain only): the track gain is
  // all it needs
  HasRG := (Pos(TAG_RG_TRACK_GAIN, UpperAllTags) > 0) and
           ((Pos(TAG_RG_ALBUM_GAIN, UpperAllTags) > 0) or (Trim(AMeta.Album) = '')) and
           (Pos('DB', UpperAllTags) > 0);
  UpperAllTags := '';

  // 2. Sanitize values into temporary locals and IMMEDIATELY wipe AMeta
  LTitle := SanitizeTagField(AMeta.Title, 512);
  if LTitle = '' then
    LTitle := ExtractFileName(AFilePath);

  LAlbum := SanitizeTagField(AMeta.Album, 512);
  if LAlbum = '' then
    LAlbum := LBL_UNKNOWN_ALBUM;

  LArtist := NormalizeSemicolons(SanitizeTagField(AMeta.Artist, 512));
  if LArtist = '' then
    LArtist := LBL_UNKNOWN_ARTIST;

  LAlbumArtist := NormalizeSemicolons(SanitizeTagField(AMeta.AlbumArtist, 512));
  if LAlbumArtist = '' then
    LAlbumArtist := LArtist;

  LGenre      := NormalizeSemicolons(SanitizeTagField(AMeta.Genre, 512));
  LComposer   := NormalizeSemicolons(SanitizeTagField(AMeta.Composer, 512));
  LPerformer  := NormalizeSemicolons(SanitizeTagField(AMeta.Performer, 512));
  LDuration   := SanitizeTagField(AMeta.DurationStr, 32);
  LComment    := SanitizeTagField(AMeta.Comment, 4096);
  LDateStr    := SanitizeTagField(AMeta.DateStr, 32);
  LTrackNum   := AMeta.TrackNumber;
  LDiscNum    := AMeta.DiscNumber;
  LYear       := AMeta.Year;
  LSampleRate := AMeta.SampleRate;
  LBitDepth   := AMeta.BitDepth;

  AMeta := Default(TAudioMetadata);

  // ---> AUDIT FIX D3: Always normalize FolderDir without trailing backslash
  CleanFolderDir := ExcludeTrailingPathDelimiter(AFolderDir);

  // 3. Allocate permanent PTrackInfo in clean low heap memory
  New(PTrack);
  PTrack^             := Default(TTrackInfo);
  PTrack^.FilePath    := CompactStr(AFilePath);
  PTrack^.FolderDir   := PooledText(CleanFolderDir, IdFolder);
  PTrack^.Title       := CompactStr(LTitle);
  PTrack^.Album       := PooledText(LAlbum, IdAlbum);
  PTrack^.Artist      := PooledText(LArtist, IdArtist);
  PTrack^.AlbumArtist := PooledText(LAlbumArtist, IdAlbumArtist);
  PTrack^.Genre       := PooledText(LGenre, IdGenre);
  PTrack^.Composer    := PooledText(LComposer, IdComposer);
  PTrack^.Performer   := PooledText(LPerformer, IdPerformer);
  PTrack^.DurationStr := PooledText(LDuration, IdOther);
  PTrack^.Comment     := PooledText(LComment, IdOther);
  PTrack^.DateStr     := PooledText(LDateStr, IdOther);

  LTitle       := '';
  LAlbum       := '';
  LArtist      := '';
  LAlbumArtist := '';
  LGenre       := '';
  LComposer    := '';
  LPerformer   := '';
  LDuration    := '';
  LComment     := '';
  LDateStr     := '';

  PTrack^.TrackNumber  := LTrackNum;
  PTrack^.DiscNumber   := LDiscNum;
  PTrack^.LastModified := AFileTime;
  PTrack^.FileSize     := AFileSize;
  PTrack^.Year         := LYear;
  PTrack^.SampleRate   := LSampleRate;
  PTrack^.BitDepth     := LBitDepth;

  ExistingTrack     := nil;
  ExistingDateAdded := 0;
  Idx               := FExistingDict.IndexOf(AFilePath);
  if Idx >= 0 then
    ExistingTrack := PTrackInfo(FExistingDict.Objects[Idx]);

  // ---> AUDIT FIX S3: Read ExistingTrack under FCriticalSection
  if Assigned(ExistingTrack) then
  begin
    FLock.Enter;
    try
      ExistingDateAdded := ExistingTrack^.DateAdded;
    finally
      FLock.Leave;
    end;
  end;

  if ExistingDateAdded > 0 then
    PTrack^.DateAdded := ExistingDateAdded
  else
    PTrack^.DateAdded := DateTimeToUnix(Now, False);

  PTrack^.HasReplayGain := HasRG;

  PTrack^.CleanTitle       := CompactStr(LowerCase(StripAccents(PTrack^.Title)));
  PTrack^.CleanArtist      := CleanText(IdArtist, PTrack^.Artist);
  PTrack^.CleanAlbumArtist := CleanText(IdAlbumArtist, PTrack^.AlbumArtist);
  PTrack^.CleanAlbum       := CleanText(IdAlbum, PTrack^.Album);
  PTrack^.CleanGenre       := CleanText(IdGenre, PTrack^.Genre);
  PTrack^.CleanComposer    := CleanText(IdComposer, PTrack^.Composer);
  PTrack^.CleanPerformer   := CleanText(IdPerformer, PTrack^.Performer);
  PTrack^.CleanFolder      := CleanText(IdFolder, PTrack^.FolderDir);
  PTrack^.FileNameOnly     := CompactStr(ExtractFileName(PTrack^.FilePath));

  if Assigned(UserStatsManager) then
  begin
    PTrack^.PrimaryFingerprint := CompactStr(UserStatsManager.GenerateFingerprintFromClean(
      PTrack^.CleanAlbumArtist, PTrack^.CleanAlbum, PTrack^.CleanTitle));

    if PTrack^.CleanAlbumArtist <> PTrack^.CleanArtist then
      PTrack^.FallbackFingerprint := CompactStr(UserStatsManager.GenerateFingerprintFromClean(
        PTrack^.CleanArtist, PTrack^.CleanAlbum, PTrack^.CleanTitle))
    else
      PTrack^.FallbackFingerprint := '';
  end;

  if Terminated or (FScannedTracks = nil) then
  begin
    Dispose(PTrack);
    Exit;
  end;

  FScannedTracks.Add(PTrack);
  Inc(FProgressCounter);
end;

function TLibraryScannerThread.SwapScannedLinks(AReplacement: TStringList): TStringList;
begin
  Result        := FScannedLinks;
  FScannedLinks := AReplacement;
end;

procedure TLibraryScannerThread.SyncProgress;
var
  SafeMsg, SafeDir: string;
  SafeProgress, SafeTotal: integer;
begin
  FLock.Enter;
  try
    SafeMsg      := FScanMsg;
    SafeDir      := FCurrentDir;
    SafeProgress := FProgressCounter;
    SafeTotal    := FTotalFilesToScan;
    // ---> AulumicNS: the total of a refresh is the number of tracks the
    // library had: more files than that = the total grows with them
    if (SafeTotal > 0) and (SafeProgress > SafeTotal) then
      SafeTotal := SafeProgress;
  finally
    FLock.Leave;
  end;

  if Assigned(FOnProgress) then
    FOnProgress(SafeMsg, SafeDir, SafeProgress, SafeTotal);
end;

procedure TLibraryScannerThread.PreScanCount(const Dir: string);
var
  SR: TSearchRec;
  FullPath: string;
begin
  if Terminated then
    Exit;

  try
    if FindFirst(LongPath(IncludeTrailingPathDelimiter(Dir) + '*.*'), faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if Terminated then
            Break;
          if (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          {$PUSH}{$WARN 5044 OFF} // faHidden / faSysFile / faSymLink: Windows-only (so is Aulumic)
          if (SR.Attr and faHidden) = faHidden then
            Continue;
          if (SR.Attr and faSysFile) = faSysFile then
            Continue;
          if StartsText('$', SR.Name) or StartsText('.', SR.Name) then
            Continue;

          FullPath := IncludeTrailingPathDelimiter(Dir) + SR.Name;

          if (SR.Attr and faDirectory) = faDirectory then
          begin
            if (SR.Attr and faSymLink) = 0 then
              PreScanCount(FullPath);
            {$POP}
          end
          else
          begin
            if IsValidMusicFile(SR.Name) then
            begin
              Inc(FTotalFilesToScan);
              RateLimitThreadUI(Self, FLastUITick, @SyncProgress);
            end;
          end;
        until FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
    end;
  except
    // Silently swallow Access Denied / Locked folder errors and keep scanning!
  end;
end;

// ---> AUDIT FIX: Root-folder rule. True when the scan folder (library root
// from Preferences) that APath belongs to is no longer reachable: the drive was
// unplugged / the share went away. Everything under such a root is SKIPPED and
// its records are KEPT. When the root is still there, a missing subfolder or
// file really was deleted/renamed and its record may be dropped.
function TLibraryScannerThread.ScanRootGone(const APath: string): Boolean;
var
  I: integer;
  Root, P: string;
begin
  P := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(APath));
  for I := 0 to FFoldersToScan.Count - 1 do
  begin
    Root := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(FFoldersToScan[I]));
    if StartsText(Root, P) then
    begin
      Result := IsDriveRootMissing(Root) or (not DirectoryExists(LongPath(Root)));
      Exit;
    end;
  end;
  // Not below a known root (should not happen): only the drive itself counts
  Result := IsDriveRootMissing(P);
end;

// ---> AUDIT FIX: Moves every scan folder that is no longer reachable from
// FFoldersToScan to FRootsLost and keeps all of its records that were not
// re-read yet. Called after the pre-count and again after the actual scan.
procedure TLibraryScannerThread.HandleLostRoots;
var
  I: integer;
  Root: string;
begin
  for I := FFoldersToScan.Count - 1 downto 0 do
  begin
    if Terminated then
      Exit;
    Root := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(FFoldersToScan[I]));
    if IsDriveRootMissing(Root) or (not DirectoryExists(LongPath(Root))) then
    begin
      FRootsLost.Add(ExcludeTrailingPathDelimiter(Root));
      CarryOverExistingUnder(Root, True);
      FFoldersToScan.Delete(I);
    end;
  end;
end;

// ---> AUDIT FIX: Marks the existing library record for APath as represented
// in FScannedTracks (FExistingDict is sorted, so IndexOf is a binary search)
procedure TLibraryScannerThread.MarkExistingTaken(const APath: string);
var
  Idx: integer;
begin
  if (not Assigned(FExistingDict)) or (Length(FExistingTaken) = 0) then
    Exit;
  Idx := FExistingDict.IndexOf(APath);
  if (Idx >= 0) and (Idx <= High(FExistingTaken)) then
    FExistingTaken[Idx] := True;
end;

// ---> AUDIT FIX D2: Keeps the existing library records of a folder that cannot
// be scanned (access denied, network hiccup, drive unplugged during the scan)
// instead of deleting them. IncludeSubDirs = also everything below ADir.
// Records that are already in FScannedTracks are skipped (FExistingTaken).
procedure TLibraryScannerThread.CarryOverExistingUnder(const ADir: string; IncludeSubDirs: Boolean);
var
  K: integer;
  Src, Dst: PTrackInfo;
  DirWithSep, TrackDir: string;
begin
  DirWithSep := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(ADir));
  // The links in this folder were not read either: keep the existing ones
  FLinkKeepDirs.AddObject(DirWithSep, TObject(PtrInt(Ord(IncludeSubDirs))));

  if (not Assigned(FExistingDict)) or (Length(FExistingTaken) = 0) then
    Exit;

  FLock.Enter;
  try
    for K := 0 to FExistingDict.Count - 1 do
    begin
      if (K > High(FExistingTaken)) or FExistingTaken[K] then
        Continue;

      Src := PTrackInfo(FExistingDict.Objects[K]);
      if not Assigned(Src) then
        Continue;

      TrackDir := IncludeTrailingPathDelimiter(Src^.FolderDir);
      if IncludeSubDirs then
      begin
        if not StartsText(DirWithSep, TrackDir) then
          Continue;
      end
      else if not SameText(DirWithSep, TrackDir) then
        Continue;

      New(Dst);
      try
        Dst^ := Src^;
        FScannedTracks.Add(Dst);
      except
        Dispose(Dst);
        raise;
      end;
      FExistingTaken[K] := True;
    end;
  finally
    FLock.Leave;
  end;
end;

// ---> AUDIT FIX: Keeps the existing record of one file that vanished or could
// not be read during the scan
procedure TLibraryScannerThread.CarryOverSingle(const APath: string);
var
  Idx: integer;
  Src, Dst: PTrackInfo;
begin
  if (APath = '') or (not Assigned(FExistingDict)) or (Length(FExistingTaken) = 0) then
    Exit;
  Idx := FExistingDict.IndexOf(APath);
  if (Idx < 0) or (Idx > High(FExistingTaken)) or FExistingTaken[Idx] then
    Exit;

  FLock.Enter;
  try
    Src := PTrackInfo(FExistingDict.Objects[Idx]);
    if not Assigned(Src) then
      Exit;
    New(Dst);
    try
      Dst^ := Src^;
      FScannedTracks.Add(Dst);
    except
      Dispose(Dst);
      raise;
    end;
    FExistingTaken[Idx] := True;
  finally
    FLock.Leave;
  end;
end;

procedure TLibraryScannerThread.ScanDirectory(const Dir: string);
var
  SR               : TSearchRec;
  FullPath         : string;
  CleanDir         : string;
  FileTime         : int64;
  FileSize         : int64;
  Idx, ThumbIdx    : integer;
  ExistingTrack    : PTrackInfo;
  ClonedTrack      : PTrackInfo;
  AddedTrack       : PTrackInfo;
  ThumbHash        : string;
  TrackHasCover    : Boolean;
  CanCloneExisting : Boolean;
  FindRes          : integer;
  DirFailed        : Boolean;
  CountedAsAdded   : Boolean;

  // ---> AUDIT FIX: Carry-over moved to CarryOverExistingUnder / CarryOverSingle
  // (scanner methods), using FExistingTaken instead of a per-folder list.

  // Records the FindNext result so a listing that stops on an I/O error
  // (rather than ERROR_NO_MORE_FILES) can be detected after the loop
  function NextEntry: integer;
  begin
    FindRes := FindNext(SR);
    Result  := FindRes;
  end;

  procedure GenerateThumbIsolated(const AAudioFilePath, AThumbHash: string; NeedEmbeddedRead: Boolean;
    AForce: Boolean = False);
  var
    CoverBytes: TBytes;
  begin
    // ---> AUDIT FIX: Initialize managed array to nil to silence compiler hint
    CoverBytes := nil;
    try
      FTempMeta := Default(TAudioMetadata);

      if NeedEmbeddedRead then
      begin
        FTempMeta := ReadTrackMetadata(AAudioFilePath, True);

        CoverBytes          := FTempMeta.CoverData;
        FTempMeta.CoverData := nil;
        FTempMeta           := Default(TAudioMetadata);

        FTempMeta.HasCover  := Length(CoverBytes) > 0;
        FTempMeta.CoverData := CoverBytes;
        CoverBytes          := nil;
      end;

      try
        GenerateAndCacheThumbnail(FTempMeta, AAudioFilePath, AThumbHash, AForce);
      except
        SetLength(FTempMeta.CoverData, 0);
      end;
    finally
      SetLength(CoverBytes, 0);
      FTempMeta := Default(TAudioMetadata);
    end;
  end;

begin
  if Terminated then
    Exit;

  Inc(FScannedFolderCount);
  CleanDir := ExcludeTrailingPathDelimiter(Dir);

  FLock.Enter;
  try
    FCurrentDir := CleanDir;
  finally
    FLock.Leave;
  end;

  RateLimitThreadUI(Self, FLastUITick, @SyncProgress);

  DirFailed           := False;
  try
  try
    FindRes := FindFirst(LongPath(IncludeTrailingPathDelimiter(CleanDir) + '*.*'), faAnyFile, SR);
    // ---> AUDIT FIX: Keep the records when the folder exists but cannot be
    // listed, OR when its library root has disappeared (drive unplugged during
    // the scan). Only a folder that is really gone while its root is still
    // there is dropped (deleted / renamed by the user).
    if (FindRes <> 0) and (DirectoryExists(LongPath(CleanDir)) or ScanRootGone(CleanDir)) then
    begin
      if not Terminated then
        CarryOverExistingUnder(CleanDir, True);
    end
    else if FindRes = 0 then
    begin
      try
        repeat
          if Terminated then
            Break;
          if (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          {$PUSH}{$WARN 5044 OFF} // faHidden / faSysFile / faSymLink: Windows-only (so is Aulumic)
          if (SR.Attr and faHidden) = faHidden then
            Continue;
          if Pos('.~.', SR.Name) > 0 then
            Continue;
          if (SR.Attr and faSysFile) = faSysFile then
            Continue;
          if StartsText('$', SR.Name) or StartsText('.', SR.Name) then
            Continue;

          FullPath := IncludeTrailingPathDelimiter(CleanDir) + SR.Name;

          if (SR.Attr and faDirectory) = faDirectory then
          begin
            if (SR.Attr and faSymLink) = 0 then
              ScanDirectory(FullPath);
            {$POP}
          end
          else
          begin
            // ---> AUDIT FIX D2: Isolate each file inside its own try..except
            // so a single malformed file never aborts scanning the rest of the directory!
            ClonedTrack := nil;
            CountedAsAdded := False;
            try
              // Virtual folder: its targets are stored in the library
              if IsAulLinkFile(SR.Name) then
                AddLinkLocal(FullPath)
              else if IsValidMusicFile(SR.Name) then
              begin
                FileTime := SR.Time;
                FileSize := SR.Size;

                if FIsRefresh then
                begin
                  Idx := FExistingDict.IndexOf(FullPath);
                  if Idx >= 0 then
                  begin
                    ExistingTrack    := PTrackInfo(FExistingDict.Objects[Idx]);
                    CanCloneExisting := False;
                    ClonedTrack      := nil;

                    // ---> AUDIT FIX S3: Copy ExistingTrack^ under FCriticalSection
                    // so concurrent UpdateRecord calls on the custodian thread cannot race!
                    FLock.Enter;
                    try
                      if FileTime <= ExistingTrack^.LastModified then
                      begin
                        New(ClonedTrack);
                        ClonedTrack^     := ExistingTrack^;
                        CanCloneExisting := True;
                      end;
                    finally
                      FLock.Leave;
                    end;

                    if CanCloneExisting then
                    begin
                      if ClonedTrack^.FileSize = 0 then
                      begin
                        ClonedTrack^.FileSize := FileSize;
                        FHasChanges           := True;
                        Inc(FTracksModified);
                      end;

                      FScannedTracks.Add(ClonedTrack);
                      // Now owned by FScannedTracks: keep using it via AddedTrack,
                      // and nil ClonedTrack so the except block never disposes it
                      AddedTrack  := ClonedTrack;
                      ClonedTrack := nil;
                      if Idx <= High(FExistingTaken) then
                        FExistingTaken[Idx] := True;
                      Inc(FProgressCounter);

                      ThumbHash := GenerateAlbumHash(AddedTrack^.AlbumArtist, AddedTrack^.Album, AddedTrack^.FolderDir);
                      if (ThumbHash <> '') and (not FCheckedThumbs.Find(ThumbHash, ThumbIdx)) then
                      begin
                        FCheckedThumbs.Add(ThumbHash);
                        if not FileExists(LongPath(AppCacheThumbsDir + ThumbHash + '.jpg')) then
                          GenerateThumbIsolated(FullPath, ThumbHash, True);
                      end;
                      ThumbHash := '';

                      RateLimitThreadUI(Self, FLastUITick, @SyncProgress);
                      Continue;
                    end
                    else
                    begin
                      Inc(FTracksModified);
                    end;
                  end
                  else
                  begin
                    Inc(FTracksAdded);
                    CountedAsAdded := True;
                  end;
                end
                else
                begin
                  Inc(FTracksAdded);
                  CountedAsAdded := True;
                end;

                FTempMeta     := ReadTrackMetadata(FullPath, False);
                TrackHasCover := FTempMeta.HasCover;

                // ---> AUDIT FIX: The file vanished while it was being read.
                // Root gone (drive unplugged): keep its existing record.
                // Root still there: the file was deleted, so drop it.
                // Either way it is neither added nor modified.
                if not FileExists(LongPath(FullPath)) then
                begin
                  FTempMeta := Default(TAudioMetadata);
                  if CountedAsAdded then
                    Dec(FTracksAdded)
                  else
                    Dec(FTracksModified);
                  if ScanRootGone(CleanDir) then
                    CarryOverSingle(FullPath);
                  Continue;
                end;

                // ---> AulumicNS: FIX a change only now that the file is there
                // and gets its record (was set before the file was read: a
                // file that could not be opened - its path had 260 characters
                // or more - was neither added nor modified, but every scan
                // "had changes": the library was replaced and saved each time)
                FHasChanges := True;
                AddTrackLocal(FullPath, CleanDir, FTempMeta, FileTime, FileSize);

                if (not Terminated) and Assigned(FScannedTracks) and (FScannedTracks.Count > 0) then
                begin
                  AddedTrack := PTrackInfo(FScannedTracks[FScannedTracks.Count - 1]);
                  if Assigned(AddedTrack) and SameFileName(AddedTrack^.FilePath, FullPath) then
                  begin
                    MarkExistingTaken(FullPath);
                    ThumbHash := GenerateAlbumHash(AddedTrack^.AlbumArtist, AddedTrack^.Album, AddedTrack^.FolderDir);
                    if (ThumbHash <> '') and (not FCheckedThumbs.Find(ThumbHash, ThumbIdx)) then
                    begin
                      FCheckedThumbs.Add(ThumbHash);
                      // ---> AUDIT FIX: A file changed outside Aulumic may have a new
                      // cover: its album thumbnail is made again (once per album per
                      // scan). Aulumic's own writes store the new file date, so they
                      // do not count as changed.
                      if not CountedAsAdded then
                        GenerateThumbIsolated(FullPath, ThumbHash, TrackHasCover, True)
                      else if not FileExists(LongPath(AppCacheThumbsDir + ThumbHash + '.jpg')) then
                        GenerateThumbIsolated(FullPath, ThumbHash, TrackHasCover);
                    end;
                    ThumbHash := '';
                  end;
                end;

                RateLimitThreadUI(Self, FLastUITick, @SyncProgress);
              end;
            except
              // Swallow per-file exception and continue with the next file in Dir
              if Assigned(ClonedTrack) then
              begin
                Dispose(ClonedTrack); // allocated but never handed to FScannedTracks
                ClonedTrack := nil;
              end;
              FTempMeta := Default(TAudioMetadata);
              // ---> AUDIT FIX: Keep the existing record of a file that could
              // not be read this time
              try
                CarryOverSingle(FullPath);
              except
                // Never let recovery abort the scan
              end;
            end;
          end;
        until NextEntry <> 0;

        // 18 = ERROR_NO_MORE_FILES (normal end). Any other code means the
        // listing was cut short (network / device error).
        if (FindRes <> 0) and (FindRes <> 18) and (not Terminated) then
          DirFailed := True;
      finally
        SysUtils.FindClose(SR);
      end;
    end;
  except
    // Listing failed part-way: keep this folder's records that were not seen yet
    DirFailed := True;
  end;

  // ---> AUDIT FIX: The listing broke off: keep everything not seen yet in this
  // folder AND below it (subfolders that were never reached)
  if DirFailed and (not Terminated) then
  begin
    try
      CarryOverExistingUnder(CleanDir, True);
    except
      // Never let recovery abort the scan
    end;
  end;
  finally
  end;
end;

// Reads one .aullink file found by the scan. All targets are kept, also the
// ones that cannot be reached right now.
procedure TLibraryScannerThread.AddLinkLocal(const ALinkPath: string);
var
  Targets: TStringList;
begin
  if FScannedLinks.IndexOf(ALinkPath) >= 0 then
    Exit;

  Targets := TStringList.Create;
  try
    Targets.CaseSensitive := False;
    if ParseAulLinkFile(ALinkPath, Targets, False) then
    begin
      FScannedLinks.AddObject(ALinkPath, Targets);
      Targets := nil; // owned by FScannedLinks now
    end
    else
      FLinkKeepFiles.Add(ALinkPath); // could not be read: keep the old entry
  finally
    Targets.Free;
  end;
end;

// True when an existing link was not read by this scan (its folder could not
// be listed, its drive was gone, or the file could not be read)
function TLibraryScannerThread.KeepsExistingLink(const ALinkPath: string): Boolean;
var
  I: Integer;
  LinkDir: string;
begin
  if FLinkKeepFiles.IndexOf(ALinkPath) >= 0 then
    Exit(True);

  LinkDir := IncludeTrailingPathDelimiter(ExtractFileDir(ALinkPath));
  for I := 0 to FLinkKeepDirs.Count - 1 do
  begin
    if PtrInt(FLinkKeepDirs.Objects[I]) <> 0 then
    begin
      if StartsText(FLinkKeepDirs[I], LinkDir) then
        Exit(True);
    end
    else if SameText(FLinkKeepDirs[I], LinkDir) then
      Exit(True);
  end;
  Result := False;
end;

procedure TLibraryScannerThread.Execute;
var
  I, J: integer;
  Track: PTrackInfo;
  TargetFolder: string;
  OfflineRoots: TStringList;
  ClonedTrack : PTrackInfo;
  IsOffline: Boolean;
begin
  FLastUITick         := GetTickCount64;
  FScannedFolderCount := 0;

  OfflineRoots := TStringList.Create;
  try
    try
      if not FIsRefresh then
      begin
        FLock.Enter;
        try
          FScanMsg         := STATUS_CLEANING_CACHE;
          FCurrentDir      := '';
          FProgressCounter := -1;
        finally
          FLock.Leave;
        end;
        TThread.Queue(Self, @SyncProgress);

        ClearThumbnailCache;

        FLock.Enter;
        try
          FScanMsg         := STATUS_REPAIRING_FULL;
          FProgressCounter := 0;
        finally
          FLock.Leave;
        end;
        TThread.Queue(Self, @SyncProgress);
      end
      else
      begin
        FLock.Enter;
        try
          FScanMsg         := STATUS_SCANNING_FULL;
          FProgressCounter := 0;
        finally
          FLock.Leave;
        end;
      end;

      for I := FFoldersToScan.Count - 1 downto 0 do
      begin
        if Terminated then
          Break;
        TargetFolder := IncludeTrailingPathDelimiter(FFoldersToScan[I]);

        if not DirectoryExists(LongPath(TargetFolder)) then
        begin
          OfflineRoots.Add(TargetFolder);
          FRootsOffline.Add(ExcludeTrailingPathDelimiter(TargetFolder));
          FLinkKeepDirs.AddObject(TargetFolder, TObject(PtrInt(1)));
          FFoldersToScan.Delete(I);
        end;
      end;

      if Assigned(FExistingDBRef) then
      begin
        FLock.Enter;
        try
          FExistingDict.Sorted := False;
          FExistingDict.BeginUpdate;
          try
            FExistingDict.Capacity := FExistingDBRef.Count;

            for I := 0 to FExistingDBRef.Count - 1 do
            begin
              if Terminated then
                Break;

              Track := PTrackInfo(FExistingDBRef[I]);
              if not Assigned(Track) then
                Continue;

              IsOffline := False;
              for J := 0 to OfflineRoots.Count - 1 do
              begin
                if StartsText(OfflineRoots[J], IncludeTrailingPathDelimiter(Track^.FolderDir)) then
                begin
                  IsOffline := True;
                  Break;
                end;
              end;

              if IsOffline then
              begin
                New(ClonedTrack);
                ClonedTrack^ := Track^;
                FScannedTracks.Add(ClonedTrack);
              end
              else
              begin
                if Track^.FilePath <> '' then
                  FExistingDict.AddObject(Track^.FilePath, TObject(Track));
              end;
            end;
          finally
            FExistingDict.Sorted := True;
            FExistingDict.EndUpdate;
          end;
        finally
          FLock.Leave;
        end;
      end;

      // ---> AUDIT FIX: One "taken" flag per existing record (sorted indices are final now)
      SetLength(FExistingTaken, FExistingDict.Count);
      for I := 0 to High(FExistingTaken) do
        FExistingTaken[I] := False;

      FLock.Enter;
      try
        FScanMsg         := STATUS_PREP_SCAN;
        FProgressCounter := 0;
      finally
        FLock.Leave;
      end;

      TThread.Queue(Self, @SyncProgress);

      FIsCounting       := True;
      FTotalFilesToScan := 0;
      // ---> AulumicNS: a refresh of a library that has tracks takes their
      // number as the total for the progress bar (SyncProgress raises it
      // when more files turn up). Counting the files first walked every
      // folder a second time: half of the time of a scan without changes,
      // more on a network drive or one that has to wake up.
      if FIsRefresh and (FExistingDict.Count > 0) then
        FTotalFilesToScan := FExistingDict.Count
      else
        for I := 0 to FFoldersToScan.Count - 1 do
        begin
          if Terminated then
            Break;
          PreScanCount(FFoldersToScan[I]);
        end;
      FIsCounting := False;

      // ---> AUDIT FIX: Phase boundary pre-count -> actual scan. PreScanCount
      // swallows every error, so a drive unplugged while counting only shows
      // up as a low file count. Check the roots again here: a root that has
      // gone is skipped completely and keeps all of its records.
      if not Terminated then
        HandleLostRoots;

      if (not Terminated) and (FTotalFilesToScan > 0) then
        FScannedTracks.Capacity := FScannedTracks.Count + FTotalFilesToScan;

      FLock.Enter;
      try
        if not FIsRefresh then
          FScanMsg := STATUS_REPAIRING_FULL
        else
          FScanMsg := STATUS_SCANNING_FULL;
      finally
        FLock.Leave;
      end;

      TThread.Queue(Self, @SyncProgress);

      for I := 0 to FFoldersToScan.Count - 1 do
      begin
        if Terminated then
          Break;
        ScanDirectory(FFoldersToScan[I]);
      end;

      // ---> AUDIT FIX: A scan folder whose drive disappeared during the actual
      // scan keeps all of its existing records that were not re-read
      if not Terminated then
        HandleLostRoots;

    except
      // ---> AUDIT FIX: Still swallowed (never kill the thread), but the scan is
      // now flagged as failed so HandleScannerFinished keeps the current library
      // instead of committing an incomplete track list.
      FScanFailed := True;
    end;

  finally
    try
      if Assigned(OfflineRoots) then
        OfflineRoots.Free;
    except
      // Silent
    end;
  end;

  try
    if not Terminated then
      TThread.Queue(Self, @SyncProgress);
  except
    // Silent
  end;
end;

end.
