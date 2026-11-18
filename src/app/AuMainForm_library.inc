{%MainUnit AuMainForm.pas}
{ ==============================================================================
  AulumicNS - AuMainForm_library.inc
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AuMainForm_library.inc - TMainForm: the library (milestone 3):
    InitLibrary, FreeLibrary, LibLookup, RequestLibraryScan,
    LibraryScanProgress, LibraryScanDone, StateStatus, StateClearThumbs,
    RestartWatcher, CheckWatcher, LibPlay, LibAdd, TreeActivate,
    TreeContext and its menu items, MnLibraryFolders, MnRefresh, MnRescan,
    CountPlay, CommitPlay, TrackStats, BannerHeart
  =============================================================================}

const
  { ---> AulumicNS: after the tag writer's batch the folder changes are its own
    writes for this long (CheckWatcher) }
  OWN_WRITES_GRACE_MS = 3000;

procedure TMainForm.InitLibrary;
var
  StartTick: QWord;
  Err: string;
begin
  ForceDirectories(AppLibraryDir);
  UserStatsManager := TUserStatsManager.Create(AppLibraryDir + FILE_USER_STATS);
  UserStatsManager.LoadFromFile;
  { ---> AulumicNS: the peaks the automatic headroom has learned (a damaged
    file: they are learned again) }
  HeadroomBook := THeadroomBook.Create(AppLibraryDir + HEADROOM_FILE);
  if not HeadroomBook.Load(Err) then
    AddLog(SafeFormat(FMT_LOG_HEADROOM_LOAD_FAILED, [Err]), False, True);
  FLibrary := TLibraryManager.Create(AppLibraryDir + FILE_DB);
  StartTick := GetTickCount64;
  FLibrary.LoadDatabase;
  AddLog(FLibrary.GetLoadSummary, StartTick);
  FLibrary.OnScanProgress := @LibraryScanProgress;
  FLibrary.OnScanDone := @LibraryScanDone;
  if AppStateManager <> nil then
  begin
    AppStateManager.OnRequestLibraryScan := @RequestLibraryScan;
    AppStateManager.OnClearThumbCache := @StateClearThumbs;
    AppStateManager.OnStatusUpdate := @StateStatus;
  end;
end;

{ at exit (FormCloseQuery): the scan stopped, the library and the stats saved }
procedure TMainForm.FreeLibrary;
begin
  StopLibraryWatcher(FWatcher);
  CommitPlay;
  if AppStateManager <> nil then
  begin
    AppStateManager.OnRequestLibraryScan := nil;
    AppStateManager.OnClearThumbCache := nil;
    AppStateManager.OnStatusUpdate := nil;
  end;
  if FLibrary <> nil then
  begin
    FLibrary.OnScanProgress := nil;
    FLibrary.OnScanDone := nil;
    FLibrary.BeginShutdown;
    FLibrary.StopScan;
    FLibrary.SaveDatabase;
  end;
  if UserStatsManager <> nil then UserStatsManager.SaveToFile;
  SaveHeadroom;
end;

{ ---> AulumicNS: the peaks the automatic headroom learned since the last
  save (ALHeadroom; at a track change, a stop and at exit). A few KB, and
  only when something was learned. }
procedure TMainForm.SaveHeadroom;
var
  Err: string;
begin
  if (HeadroomBook = nil) or not HeadroomBook.Dirty then Exit;
  if not HeadroomBook.Save(Err) then
    AddLog(SafeFormat(FMT_LOG_HEADROOM_SAVE_FAILED, [Err]), False, True);
end;

function TMainForm.LibLookup(const APath: string; out ATrack: TTrackInfo): Boolean;
begin
  Result := (FLibrary <> nil) and FLibrary.TryGetTrack(APath, ATrack);
end;

{ Aulumic's RequestLibraryScan: SilentQueue = no message when a scan is
  already running (it is queued) }
procedure TMainForm.RequestLibraryScan(FullRebuild, SilentQueue: Boolean);
begin
  if FShuttingDown or (FLibrary = nil) then Exit;
  FPl.ClearThumbCache;
  FLib.ShowScanning(True);
  FLibrary.QueueOrStartScan(FullRebuild, SilentQueue);
  if not FLibrary.IsScanning then FLib.ShowScanning(False);
end;

procedure TMainForm.LibraryScanProgress(Sender: TObject; const ScanMsg: string;
  const CurrentFolder: string; TrackCount, TotalTracks: Integer);
var
  T: string;
begin
  if TrackCount < 0 then
  begin
    T := ScanMsg;
    FStatus.Progress := -1;
  end
  else if TrackCount = 0 then
  begin
    T := SafeFormat(FMT_STATUS_SCAN_FOUND, [ScanMsg, TotalTracks]);
    FStatus.Progress := -1;
  end
  else
  begin
    T := SafeFormat(FMT_STATUS_SCAN_TRACKS, [ScanMsg, TrackCount, TotalTracks]);
    if TotalTracks > 0 then FStatus.Progress := TrackCount / TotalTracks
    else FStatus.Progress := -1;
  end;
  FStatus.StatusText := T;
  PrefsScanStatus(T);
end;

procedure TMainForm.LibraryScanDone(Sender: TObject; HasChanges: Boolean);
begin
  if FShuttingDown then Exit;
  PrefsScanStatus('');
  FLib.ShowScanning(False);
  FStatus.Progress := -1;
  if FPlayback.State = psStopped then FStatus.StatusText := STATUS_IDLE
  else FStatus.StatusText := '';
  { also when folders were shown while their drive was missing (Aulumic) }
  if HasChanges or FLib.HasOfflineFolders or FLibrary.LastScanHadUnavailableRoots or
     (FLib.Tree.RootCount = 0) then
    FLib.RefreshLibrary;
  { the scan may have made covers that were missing }
  FPl.ClearThumbCache;
  { ---> AulumicNS: the playlist's texts (date added, statistics) again only
    when the library changed (was: after every scan; with a very large
    playlist that is a pause of 0.1 .. 0.2 s for nothing) }
  if HasChanges then FPl.RefreshRatings;
  { a new library folder may be reachable now }
  if HasChanges then RestartWatcher;
  {$IF DEFINED(DEBUG) or DEFINED(MEMTEST)}
  if FMemTest <> '' then
  begin
    Inc(FMemStep);
    MemTestNote(SafeFormat('scan %d done (changes=%d, tracks=%d)', [FMemStep, Ord(HasChanges), FLibrary.GetTrackCount]));
    Application.QueueAsyncCall(@MemTestLater, FMemStep);
  end;
  {$ENDIF}
end;

{$IF DEFINED(DEBUG) or DEFINED(MEMTEST)}
type
  TMemCounters = record
    cb, PageFaultCount: DWORD;
    PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage,
    PrivateUsage: PtrUInt;
  end;

function K32GetProcessMemoryInfo(AProcess: THandle; out ACounters: TMemCounters;
  ASize: DWORD): BOOL; stdcall; external 'kernel32.dll';

{ one line: the process as Task Manager sees it, and the Pascal heap (how much
  of what it took from Windows is in use) }
procedure TMainForm.MemTestNote(const AWhat: string);
var
  C: TMemCounters;
  H: TFPCHeapStatus;
  F: TextFile;
begin
  if FMemStart = 0 then FMemStart := GetTickCount64;
  C := Default(TMemCounters);
  C.cb := SizeOf(C);
  K32GetProcessMemoryInfo(GetCurrentProcess, C, SizeOf(C));
  H := GetFPCHeapStatus;
  AssignFile(F, FMemTest);
  if FileExists(FMemTest) then Append(F) else Rewrite(F);
  WriteLn(F, SafeFormat('%5d s  %-40s private=%4d MB peak=%4d MB workingset=%4d MB | heap size=%4d MB used=%4d MB free=%4d MB max=%4d MB',
    [Integer((GetTickCount64 - FMemStart) div 1000), AWhat, Integer(C.PrivateUsage shr 20), Integer(C.PeakPagefileUsage shr 20), Integer(C.WorkingSetSize shr 20),
     Integer(H.CurrHeapSize shr 20), Integer(H.CurrHeapUsed shr 20), Integer(H.CurrHeapFree shr 20), Integer(H.MaxHeapSize shr 20)]));
  CloseFile(F);
end;

procedure TMainForm.MemTestLater(Data: PtrInt);
var
  T: QWord;
begin
  { the save and the tree are done after a few seconds }
  T := GetTickCount64;
  while GetTickCount64 - T < 4000 do
  begin
    Application.ProcessMessages;
    Sleep(20);
  end;
  MemTestNote(SafeFormat('  4 s after scan %d', [Integer(Data)]));
  if FMemStep < StrToIntDef(Application.GetOptionValue('test-repair-count'), 2) then
    RequestLibraryScan(True, True)                      // repairs: does it grow each time?
  else Close;
end;
{$ENDIF}

procedure TMainForm.StateStatus(const AMsg: string; ProgressPct: Double);
begin
  if FShuttingDown then Exit;
  FStatus.StatusText := AMsg;
  if ProgressPct < 0 then FStatus.Progress := -1 else FStatus.Progress := ProgressPct / 100;
end;

procedure TMainForm.StateClearThumbs;
begin
  if not FShuttingDown then FPl.ClearThumbCache;
end;

{ ---- watching the library folders (local folders only) ---- }

procedure TMainForm.RestartWatcher;
var
  SL: TStringList;
begin
  StopLibraryWatcher(FWatcher);
  {$IFDEF DEBUG}
  if FShotDir <> '' then Exit;
  {$ENDIF}
  if (FLibrary = nil) or (not AppSettings.Data.WatchFolders) or (not FLibrary.HasScanFolders) then Exit;
  SL := TStringList.Create;
  try
    FLibrary.GetScanFolders(SL);
    FWatcher := TLibraryWatcher.Create(SL);
  finally
    SL.Free;
  end;
end;

procedure TMainForm.CheckWatcher;
const
  WATCH_QUIET_MS = 4000;     // the files are copied, then the refresh starts
begin
  if (FWatcher = nil) or (FLibrary = nil) or FLibrary.IsScanning then Exit;
  { ---> AulumicNS: FIX the program's own tag / ReplayGain writes started a
    library scan after every save: while the tag writer works and for
    OWN_WRITES_GRACE_MS after its batch (BackgroundIOBatchFinished) the
    changes are forgotten; the writer updates the library records itself }
  if (AppStateManager <> nil) and AppStateManager.HasState(esBackgroundIOBusy) then
    FWatchMuteUntil := GetTickCount64 + OWN_WRITES_GRACE_MS;
  if GetTickCount64 < FWatchMuteUntil then
  begin
    FWatcher.Discard;
    Exit;
  end;
  if FWatcher.TakeChange(WATCH_QUIET_MS) then
  begin
    AddLog('[Library] Changes in the library folders: refreshing the library.');
    RequestLibraryScan(False, True);
  end;
end;

{ ---- tree actions (Aulumic: Play, Add to / Send to current Playlist) ---- }

{ the tracks of the nodes replace the play list and play from the first }
procedure TMainForm.LibPlay(const ANodes: TAuTreeNodeArray);
var
  L: TTrackList;
begin
  L := TTrackList.Create;
  BeginBusy;
  try
    FLib.CollectTracks(ANodes, L);
    if L.Count = 0 then Exit;
    if FPlayback <> nil then FPlayback.Stop;
    { Aulumic's PlayImmediatelyFromLibrary: in the Default playlist }
    ShowPlaylist(LBL_DEFAULT_PLAYLIST);
    FPl.Clear;
    FPl.AddTracks(L);
    PlayEntry(0);
    FPl.List.EnsureVisible(0);
  finally
    EndBusy;
    L.Free;
  end;
end;

{ Add (AReplace = False) or Send (AReplace = True) to the current playlist }
procedure TMainForm.LibAdd(const ANodes: TAuTreeNodeArray; AReplace: Boolean);
var
  L: TTrackList;
  First: Integer;
begin
  if FPl.ReadOnly then Exit;       // an auto-playlist on screen (Aulumic: disabled)
  L := TTrackList.Create;
  BeginBusy;
  try
    FLib.CollectTracks(ANodes, L);
    if L.Count = 0 then Exit;
    if AReplace then FPl.Clear;
    First := FPl.EntryCount;
    FPl.AddTracks(L);             // OnChange: stored, the queue follows
    FToast.ShowToast(SafeFormat('%d tracks added', [L.Count]), FPl.BtnPlaylist.Caption, icPlaylist, 1800);
    if First < FPl.EntryCount then FPl.List.EnsureVisible(FPl.RowOfEntry(First));
  finally
    EndBusy;
    L.Free;
  end;
end;

procedure TMainForm.TreeActivate(Sender: TObject; Node: TAuTreeNode; var Handled: Boolean);
var
  A: TAuTreeNodeArray;
begin
  { double click / Enter: "Play Immediately" or "Expand / Collapse" (Preferences) }
  if (AppSettings.Data.DoubleClickAction <> 0) or (FLib.NodeType(Node) = lntCategory) then Exit;
  Handled := True;
  SetLength(A, 1);
  A[0] := Node;
  LibPlay(A);
end;

procedure TMainForm.TreeContext(Sender: TObject; Node: TAuTreeNode; ScreenPt: TPoint);
var
  It: TAuMenuItem;
  IsRoot, IsTrack, OneNode: Boolean;
begin
  { the right-clicked node becomes the selection (unless it is in it) }
  if (Node <> nil) and not Node.Selected then FLib.Tree.SelectNode(Node);
  FCtxNode := Node;
  IsRoot := (Node <> nil) and (Node.Level = 0);
  IsTrack := (Node <> nil) and (FLib.NodeType(Node) = lntTrack);
  OneNode := FLib.Tree.SelCount <= 1;
  { the menu runs its item after the popup is gone: kept in FCtxMenu }
  FCtxMenu.Free;
  FCtxMenu := TAuMenu.Create;
  It := FCtxMenu.Add('Play', @MnLibPlay, icPlay, 'Enter');
  It.Enabled := (Node <> nil) and not IsRoot;
  It := FCtxMenu.Add('Add to current playlist', @MnLibAdd, icPlus);
  It.Enabled := (Node <> nil) and not IsRoot and not FPl.ReadOnly;
  It := FCtxMenu.Add('Send to current playlist', @MnLibSend, icPlaylist);
  It.Enabled := (Node <> nil) and not IsRoot and not FPl.ReadOnly;
  if (Node <> nil) and not IsRoot and (FPlaylists <> nil) then
    AddToPlaylistMenu(FCtxMenu.AddSub('Add to playlist', icPlaylist), @MnLibAddTo);
  FCtxMenu.AddSeparator;
  if (Node <> nil) and Node.Expanded then
    It := FCtxMenu.Add(LBL_COLLAPSE_NODE, @MnLibToggle, icTriDown)
  else
    It := FCtxMenu.Add(LBL_EXPAND_NODE, @MnLibToggle, icTriRight);
  It.Enabled := (Node <> nil) and not IsTrack;
  It := FCtxMenu.Add('Expand all', @MnLibExpandAll, icTriDown);
  It.Enabled := (Node <> nil) and not IsTrack;
  It := FCtxMenu.Add('Collapse all', @MnLibCollapseAll, icTriRight);
  It.Enabled := FLib.Tree.RootCount > 0;
  FCtxMenu.AddSeparator;
  It := FCtxMenu.Add('Properties...', @MnLibProperties, icTag, 'Alt+Enter');
  It.Enabled := Node <> nil;
  It := FCtxMenu.Add('Calculate ReplayGain...', @MnLibReplayGain, icWave);
  It.Enabled := (Node <> nil) and not IsRoot;
  FCtxMenu.AddSeparator;
  if (Node <> nil) and FLib.IsVirtualLink(Node) then
  begin
    It := FCtxMenu.Add('Edit Virtual Folder...', @MnVirtualFolder, icLink);
    It.Enabled := OneNode;
    It := FCtxMenu.Add('Remove Virtual Folder...', @MnRemoveVirtualFolder, icTrash);
    It.Enabled := OneNode;
  end
  else
  begin
    It := FCtxMenu.Add('Create Virtual Folder...', @MnVirtualFolder, icLink);
    It.Enabled := (Node <> nil) and OneNode and (FLib.NodeType(Node) = lntFolder) and
      (not IsRoot) and not FLib.IsInsideVirtualLink(Node);
  end;
  FCtxMenu.AddSeparator;
  FCtxMenu.Add('Refresh', @MnRefresh, icRefresh, 'F5');
  { no disk access here: only whether the drive / share is there }
  It := FCtxMenu.Add('Open folder...', @MnLibOpenFolder, icFolder);
  It.Enabled := (Node <> nil) and OneNode and (Node.Path <> '') and
    FLibrary.IsRootAvailable(Node.Path);
  FCtxMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

procedure TMainForm.MnLibPlay(Sender: TObject);
begin
  LibPlay(FLib.ActionNodes);
end;

procedure TMainForm.MnLibAdd(Sender: TObject);
begin
  LibAdd(FLib.ActionNodes, False);
end;

procedure TMainForm.MnLibSend(Sender: TObject);
begin
  LibAdd(FLib.ActionNodes, True);
end;

procedure TMainForm.MnLibToggle(Sender: TObject);
begin
  if FCtxNode <> nil then FLib.Tree.Toggle(FCtxNode);
end;

procedure TMainForm.MnLibExpandAll(Sender: TObject);
var
  OldCursor: TCursor;
begin
  if FCtxNode = nil then Exit;
  FLib.Tree.BeginUpdate;
  OldCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    FLib.ExpandAll(FCtxNode);
  finally
    FLib.Tree.EndUpdate;
    Screen.Cursor := OldCursor;
  end;
end;

procedure TMainForm.MnLibCollapseAll(Sender: TObject);
begin
  FLib.Tree.CollapseAll;
end;

procedure TMainForm.MnLibOpenFolder(Sender: TObject);
begin
  if FCtxNode = nil then Exit;
  if FLib.NodeType(FCtxNode) = lntTrack then RevealPath(FCtxNode.Path)
  else RevealPath(IncludeTrailingPathDelimiter(FCtxNode.Path));
end;

{ Create / Edit Virtual Folder (Aulumic's popManageVirtualLinkClick): a
  .aullink file in the folder (create) or the link itself (edit) }
procedure TMainForm.MnVirtualFolder(Sender: TObject);
var
  Node: TAuTreeNode;
  BaseDir, LinkName, LinkPath, OldLink: string;
  IsEdit: Boolean;
  SL: TStringList;
begin
  Node := FCtxNode;
  if (Node = nil) or (FLibrary = nil) or (FLib.NodeType(Node) <> lntFolder) then Exit;
  SL := TStringList.Create;
  try
    OldLink := '';
    IsEdit := FLib.IsVirtualLink(Node);
    if IsEdit then
    begin
      BaseDir := ExtractFilePath(Node.Path);
      LinkName := ChangeFileExt(ExtractFileName(Node.Path), '');
      OldLink := Node.Path;
      if FileExists(OldLink) then
      try
        SL.LoadFromFile(OldLink, TEncoding.UTF8);
      except
        SL.Clear;
      end;
    end
    else
    begin
      BaseDir := Node.Path;
      LinkName := '';
    end;
    if not EditVirtualFolder(Self, BaseDir, LinkName, SL, IsEdit, FLibrary) then Exit;
    if Trim(LinkName) = '' then Exit;
    LinkPath := IncludeTrailingPathDelimiter(BaseDir) + Trim(LinkName) + EXT_AULLINK;
    try
      if IsEdit and (OldLink <> '') and not SameText(OldLink, LinkPath) and FileExists(OldLink) then
        SysUtils.DeleteFile(OldLink);
      SL.WriteBOM := False;
      SL.SaveToFile(LinkPath, TEncoding.UTF8);
      if IsEdit and (OldLink <> '') and not SameText(OldLink, LinkPath) then FLibrary.RefreshVirtualLink(OldLink);
      FLibrary.RefreshVirtualLink(LinkPath);
      AddLog(SafeFormat('[Library] Virtual folder saved: "%s" (%d folders).', [LinkPath, SL.Count]));
      if (not IsEdit) and not Node.Expanded then Node.Expanded := True;
      FLib.RefreshLibrary;
    except
      on E: Exception do
        AuMessage(SafeFormat(FMT_ERR_SHORTCUT_FILESAVE, [E.Message]), amError, abOK, TITLE_ERROR);
    end;
  finally
    SL.Free;
  end;
end;

{ Aulumic's popDeleteVirtualLinkClick: the .aullink file goes (the folders
  it shows are not touched) }
procedure TMainForm.MnRemoveVirtualFolder(Sender: TObject);
var
  Node: TAuTreeNode;
  Link: string;
begin
  Node := FCtxNode;
  if (Node = nil) or (FLibrary = nil) or not FLib.IsVirtualLink(Node) then Exit;
  Link := Node.Path;
  if ALMessageDlg(TITLE_CONFIRM_DELETE, SafeFormat(FMT_CONFIRM_DELETE_VIRTUAL_FOLDER,
    [ChangeFileExt(ExtractFileName(Link), '')]), [mbYes, mbNo], mbNo, mkWarning) <> mrYes then Exit;
  if (not FileExists(Link)) or SysUtils.DeleteFile(Link) then
  begin
    FLibrary.RefreshVirtualLink(Link);
    AddLog(SafeFormat('[Library] Virtual folder removed: "%s".', [Link]));
    if (Node.Parent <> nil) and (Node.Parent.Level > 0) then FLib.Tree.SelectNode(Node.Parent);
    FCtxNode := nil;
    FLib.RefreshLibrary;
  end
  else
    ALMessageDlg(TITLE_ERROR, ERR_SHORTCUT_DELETE, mkError);
end;

{ ---- the library menu ---- }

{ the Library Folders dialog of milestone 3 is now Preferences > Library }
procedure TMainForm.MnLibraryFolders(Sender: TObject);
begin
  ShowPrefsPage(PREFS_LIBRARY);
end;

{ the library folders of Preferences (OK, Scan, Repair); True when they
  changed (the tree and the watcher follow; the caller starts the scan) }
function TMainForm.ApplyLibraryFolders(AFolders: TStrings): Boolean;
var
  Old: TStringList;
begin
  Result := False;
  if FLibrary = nil then Exit;
  Old := TStringList.Create;
  try
    FLibrary.GetScanFolders(Old);
    Result := Old.Text <> AFolders.Text;
    if not Result then Exit;
    FLibrary.SetScanFolders(AFolders);
    FLibrary.IsDirty := True;
    FLibrary.SaveDatabase;          // the folders survive a crash before the scan ends
    LogLibraryFolderChanges(Old, AFolders);
    RestartWatcher;
    FLib.RefreshLibrary;
  finally
    Old.Free;
  end;
end;

{ Scan / Repair in Preferences: the folder list at once, then the scan }
procedure TMainForm.PrefsScan(AFolders: TStrings; FullRebuild: Boolean);
begin
  ApplyLibraryFolders(AFolders);
  RequestLibraryScan(FullRebuild, False);
end;

{ F5: the focused folder again from the library (Aulumic: and the playlist
  synced with the library - milestone 4) }
procedure TMainForm.MnRefresh(Sender: TObject);
begin
  if FShuttingDown then Exit;
  BeginBusy;
  try
    FLib.RefreshCurrentFolder;
    { Aulumic's AutoSyncWithLibrary: the tags from the library; an
      auto-playlist runs its query again }
    if FPl.ReadOnly then ShowPlaylist(FShownPl, True)
    else FPl.SyncWithLibrary;
    FPl.RefreshRatings;
  finally
    EndBusy;
  end;
end;

{ Ctrl+F5 and the button: look for new, changed and removed files }
procedure TMainForm.MnRescan(Sender: TObject);
begin
  RequestLibraryScan(False, False);
end;

{ ---- play counts (Aulumic's scrobble: 30 s or half the track) ---- }

procedure TMainForm.CountPlay(DeltaSec: Double);
var
  Dur: Double;
begin
  if (FPlayback = nil) or (FPlayback.State <> psPlaying) or (FPlayingPath = '') then Exit;
  if (DeltaSec < 0) or (DeltaSec > 2.5) then DeltaSec := 1.0;
  FActivePlaySeconds := FActivePlaySeconds + DeltaSec;
  if not FIsScrobbled then
  begin
    Dur := FPlayback.GetDuration;
    if (FActivePlaySeconds >= 30.0) or ((Dur > 0) and (FActivePlaySeconds >= Dur * 0.5)) then
      FIsScrobbled := True;
  end;
end;

{ the track that played counts once (journaled at once, uUserStatsManager) }
procedure TMainForm.CommitPlay;
var
  Fp: string;
begin
  if FIsScrobbled and (FScrobblePath <> '') and (UserStatsManager <> nil) then
  begin
    Fp := TrackStatsFingerprint(FScrobblePath, FScrobbleMeta);
    UserStatsManager.LogPlay(Fp);
  end;
  FIsScrobbled := False;
  FActivePlaySeconds := 0;
  FScrobblePath := '';
  FScrobbleMeta := Default(TAudioMetadata);
  { ---> AulumicNS: a track is over: what the automatic headroom learned }
  SaveHeadroom;
end;

{ Aulumic's TrackStatsFingerprint: the library's identity of the track, else
  the file's tag values }
function TMainForm.TrackStatsFingerprint(const APath: string; const AMeta: TAudioMetadata): string;
var
  T: TTrackInfo;
begin
  Result := '';
  if UserStatsManager = nil then Exit;
  if LibLookup(APath, T) then Result := T.PrimaryFingerprint;
  if Result = '' then
    Result := UserStatsManager.GenerateFingerprint(AMeta.AlbumArtist, AMeta.Album, AMeta.Title);
end;

{ Aulumic's FindTrackStats: primary, fallback, then the tag values }
function TMainForm.TrackStats(const APath: string; const AMeta: TAudioMetadata): PUserTrackStats;
var
  T: TTrackInfo;
begin
  Result := nil;
  if UserStatsManager = nil then Exit;
  if LibLookup(APath, T) then
  begin
    if T.PrimaryFingerprint <> '' then Result := UserStatsManager.PeekStats(T.PrimaryFingerprint);
    if (Result = nil) and (T.FallbackFingerprint <> '') then
      Result := UserStatsManager.PeekStats(T.FallbackFingerprint);
  end;
  if Result = nil then
    Result := UserStatsManager.PeekStats(
      UserStatsManager.GenerateFingerprint(AMeta.AlbumArtist, AMeta.Album, AMeta.Title));
end;

{ the heart: the playing album as a favourite (all its tracks 5 stars) }
procedure TMainForm.BannerHeart(Sender: TObject);
begin
  if (FPlayingPath = '') or (FLibrary = nil) then Exit;
  FBanner.Favorite := FLibrary.ToggleAlbumFavorite(FCurrentMeta.AlbumArtist, FCurrentMeta.Album,
    FCurrentMeta.Title);
  FBanner.Changed;
  FPl.RefreshRatings;
end;
