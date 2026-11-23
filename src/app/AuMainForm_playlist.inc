{%MainUnit AuMainForm.pas}
{ ==============================================================================
  AulumicNS - AuMainForm_playlist.inc
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AuMainForm_playlist.inc - TMainForm: the playlists:
    InitPlaylists, FreePlaylists, ShownPlaylist, ShowPlaylist, ApplyView,
    SaveShownPlaylist, PlChanged, PlCollapseChanged, CheckPlaylistSave,
    the playlist selector (PlaylistDrop, PlaylistPick, New / Rename /
    Delete), the View menu, the playlist context menu and its items,
    AddToPlaylistMenu / AddTracksToPlaylist, drag and drop (PlDragOver,
    PlDragDrop, PlEndDrag), M3U import / export, Remove dead items, and
    BeginBusy / EndBusy (the hourglass around work on a large playlist).
  The playlists are in uPlaylistStore (playlists.adb + journal); the pane
  shows one of them (FShownPl). The play queue belongs to the playlist that
  was played from (FPlayingPl).
  =============================================================================}

const
  PL_SAVE_DELAY_MS = 1500;     // a change is stored this long after the last one

{ TStoredPlaylist.SortMode: the order in the low four bits (the numbers are
  stored: never change them), SORT_STORED_REVERSE added when reversed.
  4 was "newest first" as an order of its own: the year, reversed. }
const
  SORT_STORED: array[TPlSortMode] of Integer = (0, 1, 2, 3, 5);
  SORT_STORED_YEAR_DOWN = 4;
  SORT_STORED_REVERSE = 16;

procedure DecodeSort(ACode: Integer; out AMode: TPlSortMode; out AReverse: Boolean);
var
  M: TPlSortMode;
begin
  AMode := psAdded;
  AReverse := False;
  if (ACode < 0) or (ACode >= 2 * SORT_STORED_REVERSE) then Exit;
  AReverse := ACode >= SORT_STORED_REVERSE;
  ACode := ACode mod SORT_STORED_REVERSE;
  if ACode = SORT_STORED_YEAR_DOWN then
  begin
    AMode := psYear;
    AReverse := True;
    Exit;
  end;
  for M := Low(TPlSortMode) to High(TPlSortMode) do
    if SORT_STORED[M] = ACode then AMode := M;
end;

function EncodeSort(AMode: TPlSortMode; AReverse: Boolean): Integer;
begin
  Result := SORT_STORED[AMode];
  if AReverse then Inc(Result, SORT_STORED_REVERSE);
end;

procedure TMainForm.InitPlaylists;
var
  Old: string;
  L: TStringList;
  I: Integer;
  P: PStoredPlaylist;
begin
  ForceDirectories(AppPlaylistsDir);
  FPlaylists := TPlaylistStore.Create(AppPlaylistsDir + FILE_PLAYLISTS, LBL_DEFAULT_PLAYLIST);
  FPlaylists.Load;
  { a NowPlaying.m3u8 in the data folder becomes the Default playlist (once) }
  Old := AppDataDir + 'NowPlaying.m3u8';
  P := FPlaylists.Find(LBL_DEFAULT_PLAYLIST);
  if FileExists(LongPath(Old)) and (Length(P^.Entries) = 0) then
  begin
    L := TStringList.Create;
    try
      try
        L.LoadFromFile(Old);
      except
        L.Clear;
      end;
      for I := L.Count - 1 downto 0 do
        if (Trim(L[I]) = '') or (L[I][1] = '#') then L.Delete(I);
      FPl.AddFiles(L);
      FPlaylists.SetEntries(P, FPl.ToEntries);
      FPl.Clear;
    finally
      L.Free;
    end;
    RenameFile(LongPath(Old), LongPath(Old + '.imported'));
  end;
  ShowPlaylist(AppSettings.Data.ActivePlayList, True);
end;

procedure TMainForm.FreePlaylists;
begin
  if FPlaylists = nil then Exit;
  SaveShownPlaylist(True);
  AppSettings.Data.ActivePlayList := FShownPl;
  FPlaylists.Save;
end;

function TMainForm.ShownPlaylist: PStoredPlaylist;
begin
  if FPlaylists = nil then Exit(nil);
  Result := FPlaylists.Find(FShownPl);
end;

{ the grouping and formats of the shown playlist (its own, else the
  defaults of the preferences) }
procedure TMainForm.ApplyView(P: PStoredPlaylist; const ADateSuffix: string);
var
  G: TGroupingMode;
  HF, TF: string;
  SM: TPlSortMode;
  Rev: Boolean;
begin
  if (P <> nil) and (P^.GroupMode >= 0) and (P^.GroupMode <= Ord(High(TGroupingMode))) then
    G := TGroupingMode(P^.GroupMode)
  else
    G := TGroupingMode(EnsureRange(AppSettings.Data.DefaultGroupingMode, 0, Ord(High(TGroupingMode))));
  if (P <> nil) and (P^.HeaderFmt <> '') then HF := P^.HeaderFmt else HF := AppSettings.Data.DefaultHeaderFormat;
  if (P <> nil) and (P^.TrackFmt <> '') then TF := P^.TrackFmt else TF := AppSettings.Data.DefaultTrackFormat;
  SM := psAdded;
  Rev := False;
  if P <> nil then DecodeSort(P^.SortMode, SM, Rev);
  { the columns and the sort of its flat list }
  if P <> nil then FPl.SetFlatLayout(P^.FlatCols, P^.FlatSort) else FPl.SetFlatLayout('', '');
  FPl.SetView(G, HF, TF, ADateSuffix, (P <> nil) and (P^.Kind = pkAuto), SM, Rev);
end;

procedure TMainForm.ShowPlaylist(const AName: string; AForce: Boolean);
var
  P: PStoredPlaylist;
  L: TTrackList;
  Suffix: string;
  E, OldSel: Integer;
  Sel: TIntArray;
begin
  if FPlaylists = nil then Exit;
  if (not AForce) and SameText(AName, FShownPl) then Exit;
  { the same playlist built again (tags were saved): where the selection was }
  OldSel := -1;
  if SameText(AName, FShownPl) then
  begin
    Sel := FPl.SelectedEntries;
    if Length(Sel) > 0 then OldSel := Sel[0];
  end;
  { the playlist on screen keeps its changes and the selected track }
  SaveShownPlaylist(True);
  P := FPlaylists.Find(AName);
  if P = nil then P := FPlaylists.Find(LBL_DEFAULT_PLAYLIST);
  FShownPl := P^.Name;
  FPl.BtnPlaylist.Caption := FShownPl;
  if P^.Kind = pkAuto then FPl.BtnPlaylist.Icon := icFunnel else FPl.BtnPlaylist.Icon := icPlaylist;
  FPl.ClearThumbCache;
  FPl.SetCollapsedNames(P^.Collapsed);
  { the play queue follows only the complete list (below), not the steps on
    the way (FLoadingPl) }
  FLoadingPl := True;
  try
    if P^.Kind = pkAuto then
    begin
      { the tracks of the query, from the library }
      Suffix := '';
      L := TTrackList.Create;
      try
        if FLibrary <> nil then FLibrary.GetTracksByQuery(P^.Query, L, True);
        if not SortAutoPlaylistByDate(L.List, P^.Query, PlGroupMode(P), Suffix) then Suffix := '';
        ApplyView(P, Suffix);
        FPl.Clear;
        FPl.AddTracks(L);
      finally
        L.Free;
      end;
    end
    else
    begin
      ApplyView(P, '');
      FPl.LoadEntries(P^.Entries);
    end;
  finally
    FLoadingPl := False;
  end;
  FPlSaveDue := 0;
  { the playing track, when this is the playlist that plays }
  if SameText(FShownPl, FPlayingPl) and (FPlayingPath <> '') then
  begin
    E := FPl.IndexOfFile(FPlayingPath);
    FPl.PlayingEntry := E;
    if E >= 0 then FPlayingId := FPl.Entry(E).Id;
    { a tag edit can take the playing track out of an
      auto-playlist (its genre does not fit any more): it plays on, then the
      list goes on from where it was }
    SyncQueueWithList(True);
  end
  else
    FPl.PlayingEntry := -1;
  { the track selected when the playlist was left }
  if P^.LastFile <> '' then
  begin
    E := FPl.IndexOfFile(P^.LastFile);
    { the selected track left the list: the one that is at its place now }
    if (E < 0) and (OldSel >= 0) and (FPl.EntryCount > 0) then
      E := Min(OldSel, FPl.EntryCount - 1);
    if E >= 0 then FPl.SelectEntry(E, False, True);
  end;
  { and the list where it was scrolled to }
  FPl.ScrollToFile(P^.TopFile);
  AppSettings.Data.ActivePlayList := FShownPl;
end;

function TMainForm.PlGroupMode(P: PStoredPlaylist): TGroupingMode;
begin
  if (P <> nil) and (P^.GroupMode >= 0) and (P^.GroupMode <= Ord(High(TGroupingMode))) then
    Result := TGroupingMode(P^.GroupMode)
  else
    Result := TGroupingMode(EnsureRange(AppSettings.Data.DefaultGroupingMode, 0, Ord(High(TGroupingMode))));
end;

{ the shown playlist into the store (journaled); ANow = also when nothing
  is due (switching, closing: the selected track) }
procedure TMainForm.SaveShownPlaylist(ANow: Boolean);
var
  P: PStoredPlaylist;
  Sel, TopF: string;
begin
  P := ShownPlaylist;
  if (P = nil) or FPl.IsDemo then Exit;
  Sel := FPl.SelectedFilePath;
  TopF := FPl.TopFile;
  if (FPlSaveDue <> 0) and (P^.Kind = pkNormal) then
  begin
    P^.Entries := FPl.ToEntries;
    P^.Collapsed := FPl.CollapsedNames;
    P^.LastFile := Sel;
    P^.TopFile := TopF;
    FPlaylists.Changed(P);
  end
  else if ANow and ((Sel <> P^.LastFile) or (TopF <> P^.TopFile)) then
  begin
    P^.LastFile := Sel;
    P^.TopFile := TopF;
    P^.Collapsed := FPl.CollapsedNames;
    FPlaylists.Changed(P);
  end;
  FPlSaveDue := 0;
end;

procedure TMainForm.CheckPlaylistSave;
begin
  if (FPlSaveDue <> 0) and (GetTickCount64 >= FPlSaveDue) then SaveShownPlaylist(False);
end;

{ the pane's entries changed: stored a moment later; the play queue follows
  when this is the playing playlist }
procedure TMainForm.PlChanged(Sender: TObject);
begin
  if FShuttingDown or FPl.IsDemo or FLoadingPl then Exit;
  if not FPl.ReadOnly then FPlSaveDue := GetTickCount64 + PL_SAVE_DELAY_MS;
  if SameText(FShownPl, FPlayingPl) then
  begin
    if FPl.PlayingEntry < 0 then FPl.PlayingEntry := FPl.IndexOfId(FPlayingId);
    SyncQueueWithList;
  end;
end;

procedure TMainForm.PlCollapseChanged(Sender: TObject);
var
  P: PStoredPlaylist;
begin
  P := ShownPlaylist;
  if (P = nil) or FPl.IsDemo then Exit;
  if FPlSaveDue = 0 then FPlSaveDue := GetTickCount64 + PL_SAVE_DELAY_MS;
  if P^.Kind = pkAuto then
  begin
    { an auto-playlist keeps only its view }
    P^.Collapsed := FPl.CollapsedNames;
    FPlaylists.Changed(P);
    FPlSaveDue := 0;
  end;
end;

procedure TMainForm.PlRatingChanged(Sender: TObject);
var
  St: PUserTrackStats;
begin
  if FPlayingPath = '' then Exit;
  St := TrackStats(FPlayingPath, FCurrentMeta);
  if FBanner.Favorite <> ((St <> nil) and St^.IsFavorite) then
  begin
    FBanner.Favorite := (St <> nil) and St^.IsFavorite;
    FBanner.Changed;
  end;
end;

{ ---- the playlist selector ---- }

procedure TMainForm.PlaylistDrop(Sender: TObject);
var
  It: TAuMenuItem;
  I: Integer;
  Names: TStringList;
  First: Boolean;
begin
  if FPlaylists = nil then Exit;     // the screenshot mode has no playlists
  FPlaylistMenu.Free;
  FPlaylistMenu := TAuMenu.Create;
  FMenuPlNames.Clear;
  Names := TStringList.Create;
  try
    FPlaylists.GetNames(Names);
    First := True;
    for I := 0 to Names.Count - 1 do
    begin
      if (TPlaylistKind(PtrInt(Names.Objects[I])) = pkAuto) and First then
      begin
        FPlaylistMenu.AddSeparator;
        First := False;
      end;
      if TPlaylistKind(PtrInt(Names.Objects[I])) = pkAuto then
        It := FPlaylistMenu.Add(Names[I], @PlaylistPick, icFunnel)
      else
        It := FPlaylistMenu.Add(Names[I], @PlaylistPick, icPlaylist);
      It.Tag := FMenuPlNames.Add(Names[I]);
      It.Checked := SameText(Names[I], FShownPl);
    end;
  finally
    Names.Free;
  end;
  { the selector lists the playlists
    and auto-playlists, nothing else. New / edit / rename / delete are in
    the Playlist Manager (the pencil beside the selector, Alt+P, the
    playlist's context menu). }
  FPlaylistMenu.MinWidth := FPl.BtnPlaylist.Width;
  FPl.BtnPlaylist.Dropped := True;
  FPlaylistMenu.PopupBelow(FPl.BtnPlaylist);
  FPl.BtnPlaylist.Dropped := False;
end;

procedure TMainForm.PlaylistPick(Sender: TObject);
var
  K: Integer;
begin
  K := TAuMenuItem(Sender).Tag;
  if (K < 0) or (K >= FMenuPlNames.Count) then Exit;
  BeginBusy;
  try
    ShowPlaylist(FMenuPlNames[K]);
  finally
    EndBusy;
  end;
end;

{ work on the playlist that takes a
  moment on this thread - another grouping or format, another playlist: all
  rows are built again. The hourglass shows meanwhile, and the clicks and keys
  of that time are dropped at the end (uInputBlock.DiscardPendingInput): they
  would run afterwards, on rows that are not where they were clicked. }
procedure TMainForm.BeginBusy;
begin
  Inc(FBusyDepth);
  if FBusyDepth = 1 then Screen.Cursor := crHourGlass;
end;

procedure TMainForm.EndBusy;
begin
  if FBusyDepth = 0 then Exit;
  Dec(FBusyDepth);
  if FBusyDepth > 0 then Exit;
  try
    DiscardPendingInput;
  finally
    Screen.Cursor := crDefault;
  end;
end;

function TMainForm.AskPlaylistName(const ATitle: string; var AName: string): Boolean;
begin
  Result := False;
  repeat
    if not AuInput(ATitle, 'Name of the playlist:', AName) then Exit;
    AName := CleanPlaylistName(AName);
    if AName = '' then Continue;
    if FPlaylists.Find(AName) = nil then Exit(True);
    AuMessage('There is a playlist "' + AName + '" already. Choose another name.', amInfo, abOK, ATitle);
  until False;
end;

{ ---- the View menu (the shown playlist's grouping and formats) ---- }

procedure TMainForm.ViewClick(Sender: TObject);
var
  Sub: TAuMenu;
  It: TAuMenuItem;
  P: PStoredPlaylist;
  I: Integer;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  FViewMenu.Free;
  FViewMenu := TAuMenu.Create;
  Sub := FViewMenu.AddSub('Grouping', icPlaylist);
  It := Sub.Add('Use global preferences', @MnViewGroup);
  It.Tag := -1;
  It.Checked := P^.GroupMode < 0;
  Sub.AddSeparator;
  for I := 0 to High(GROUPING_MODE_OPTIONS) do
  begin
    case TGroupingMode(I) of
      gmFolder: It := Sub.Add(GROUPING_MODE_OPTIONS[I].DisplayName, @MnViewGroup, icFolder);
      gmFlat: It := Sub.Add(GROUPING_MODE_OPTIONS[I].DisplayName, @MnViewGroup, icList);
    else
      It := Sub.Add(GROUPING_MODE_OPTIONS[I].DisplayName, @MnViewGroup, icAlbum);
    end;
    It.Tag := I;
    It.Checked := P^.GroupMode = I;
  end;
  Sub := FViewMenu.AddSub('Album header format', icAlbum);
  { only headers of albums have a format - by the grouping in
    effect, the playlist's own or the default }
  FViewMenu.Item(FViewMenu.Count - 1).Enabled := PlGroupMode(P) = gmAlbum;
  It := Sub.Add('Use global preferences', @MnViewHeader);
  It.Tag := -1;
  It.Checked := P^.HeaderFmt = '';
  Sub.AddSeparator;
  for I := 0 to High(HEADER_FORMAT_OPTIONS) do
  begin
    It := Sub.Add(HEADER_FORMAT_OPTIONS[I].DisplayName, @MnViewHeader);
    It.Tag := I;
    It.Checked := (P^.HeaderFmt <> '') and (P^.HeaderFmt = HEADER_FORMAT_OPTIONS[I].DataStr);
  end;
  Sub := FViewMenu.AddSub('Track format', icNote);
  { a flat list has columns, no track format }
  FViewMenu.Item(FViewMenu.Count - 1).Enabled := PlGroupMode(P) <> gmFlat;
  It := Sub.Add('Use global preferences', @MnViewTrack);
  It.Tag := -1;
  It.Checked := P^.TrackFmt = '';
  Sub.AddSeparator;
  for I := 0 to High(TRACK_FORMAT_OPTIONS) do
  begin
    It := Sub.Add(TRACK_FORMAT_OPTIONS[I].DisplayName, @MnViewTrack);
    It.Tag := I;
    It.Checked := (P^.TrackFmt <> '') and (P^.TrackFmt = TRACK_FORMAT_OPTIONS[I].DataStr);
  end;
  { the tracks of a work under a heading of their own (all playlists) }
  FViewMenu.AddSeparator;
  It := FViewMenu.Add('Work headings', @MnViewWorks);
  It.Checked := AppSettings.Data.WorkHeadings;
  It.Enabled := PlGroupMode(P) <> gmFlat;
  FViewMenu.PopupBelow(FPl.BtnView, True);
end;

procedure TMainForm.MnPlSelectWork(Sender: TObject);
begin
  FPl.SelectWork(FCtxPlEntry);
end;

procedure TMainForm.MnViewWorks(Sender: TObject);
begin
  AppSettings.Data.WorkHeadings := not AppSettings.Data.WorkHeadings;
  BeginBusy;
  try
    FPl.WorkHeadings := AppSettings.Data.WorkHeadings;
  finally
    EndBusy;
  end;
end;

{ the sort button: the order of the groups of the shown playlist (its
  direction is the arrow button beside it: MnSortReverse) }
procedure TMainForm.SortClick(Sender: TObject);
var
  P: PStoredPlaylist;
  M: TPlSortMode;
  It: TAuMenuItem;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  FViewMenu.Free;
  FViewMenu := TAuMenu.Create;
  for M := Low(TPlSortMode) to High(TPlSortMode) do
  begin
    It := FViewMenu.Add(FPl.SortName(M), @MnSort);
    It.Tag := Ord(M);
    It.Checked := FPl.SortMode = M;
    if M = psAdded then FViewMenu.AddSeparator;
  end;
  FViewMenu.PopupBelow(FPl.BtnSort, True);
end;

procedure TMainForm.MnSort(Sender: TObject);
var
  P: PStoredPlaylist;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  SaveShownPlaylist(True);
  P^.SortMode := EncodeSort(TPlSortMode(EnsureRange(TAuMenuItem(Sender).Tag, 0, Ord(High(TPlSortMode)))),
    FPl.SortReverse);
  ViewChanged;
end;

{ the flat list's columns, their widths or its sort changed: kept with the
  playlist }
procedure TMainForm.PlViewChanged(Sender: TObject);
var
  P: PStoredPlaylist;
begin
  P := ShownPlaylist;
  if (P = nil) or FPl.IsDemo or FLoadingPl then Exit;
  if (P^.FlatCols = FPl.FlatColsText) and (P^.FlatSort = FPl.FlatSortText) then Exit;
  P^.FlatCols := FPl.FlatColsText;
  P^.FlatSort := FPl.FlatSortText;
  FPlaylists.Changed(P);
end;

procedure TMainForm.MnSortReverse(Sender: TObject);
var
  P: PStoredPlaylist;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  SaveShownPlaylist(True);
  P^.SortMode := EncodeSort(FPl.SortMode, not FPl.SortReverse);
  ViewChanged;
end;

procedure TMainForm.ViewChanged;
var
  P: PStoredPlaylist;
  Sel: string;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  BeginBusy;
  try
    SaveShownPlaylist(True);
    FPlaylists.Changed(P);
    Sel := FPl.SelectedFilePath;
    ShowPlaylist(FShownPl, True);
    if Sel <> '' then FPl.SelectEntry(FPl.IndexOfFile(Sel), False, True);
    { on the screen before the hourglass goes: what is clicked next is what
      is seen }
    FPl.List.Update;
  finally
    EndBusy;
  end;
end;

procedure TMainForm.MnViewGroup(Sender: TObject);
var
  P: PStoredPlaylist;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  SaveShownPlaylist(True);
  P^.GroupMode := TAuMenuItem(Sender).Tag;
  ViewChanged;
end;

procedure TMainForm.MnViewHeader(Sender: TObject);
var
  P: PStoredPlaylist;
  K: Integer;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  SaveShownPlaylist(True);
  K := TAuMenuItem(Sender).Tag;
  if K < 0 then P^.HeaderFmt := '' else P^.HeaderFmt := HEADER_FORMAT_OPTIONS[K].DataStr;
  ViewChanged;
end;

procedure TMainForm.MnViewTrack(Sender: TObject);
var
  P: PStoredPlaylist;
  K: Integer;
begin
  P := ShownPlaylist;
  if P = nil then Exit;
  SaveShownPlaylist(True);
  K := TAuMenuItem(Sender).Tag;
  if K < 0 then P^.TrackFmt := '' else P^.TrackFmt := TRACK_FORMAT_OPTIONS[K].DataStr;
  ViewChanged;
end;

{ ---- "Add to" (a submenu of playlists) ---- }

procedure TMainForm.AddToPlaylistMenu(AMenu: TAuMenu; AClick: TNotifyEvent);
var
  Names: TStringList;
  I: Integer;
  It: TAuMenuItem;
begin
  FAddToNames.Clear;
  if FPlaylists = nil then Exit;
  It := AMenu.Add('New playlist...', AClick, icPlus);
  It.Tag := -1;
  AMenu.AddSeparator;
  Names := TStringList.Create;
  try
    FPlaylists.GetNames(Names);
    for I := 0 to Names.Count - 1 do
      if TPlaylistKind(PtrInt(Names.Objects[I])) = pkNormal then
      begin
        It := AMenu.Add(Names[I], AClick, icPlaylist);
        It.Tag := FAddToNames.Add(Names[I]);
      end;
  finally
    Names.Free;
  end;
end;

{ the target playlist of an "Add to" item (a new one: asks its name) }
function TMainForm.AddToTarget(Sender: TObject): string;
var
  K: Integer;
  N: string;
begin
  Result := '';
  K := TAuMenuItem(Sender).Tag;
  if K < 0 then
  begin
    N := FPlaylists.UniqueName('New playlist');
    if not AskPlaylistName('New playlist', N) then Exit;
    if FPlaylists.Add(N, pkNormal) = nil then Exit;
    Result := N;
  end
  else if K < FAddToNames.Count then
    Result := FAddToNames[K];
end;

procedure TMainForm.AddTracksToPlaylist(const AName: string; ATracks: TTrackList);
var
  P: PStoredPlaylist;
  E: TPlaylistEntries;
  I, N: Integer;
begin
  if (AName = '') or (ATracks.Count = 0) then Exit;
  P := FPlaylists.Find(AName);
  if (P = nil) or (P^.Kind = pkAuto) then Exit;
  if SameText(AName, FShownPl) then
    FPl.AddTracks(ATracks)
  else
  begin
    E := Copy(P^.Entries);
    N := Length(E);
    SetLength(E, N + ATracks.Count);
    for I := 0 to ATracks.Count - 1 do E[N + I] := uPlaylistRows.EntryFromTrack(ATracks[I]^);
    FPlaylists.SetEntries(P, E);
  end;
  FToast.ShowToast(SafeFormat('%d tracks added', [ATracks.Count]), AName, icPlaylist, 1800);
end;

{ the selected playlist tracks as library-style records }
procedure TMainForm.SelectedPlTracks(AList: TTrackList);
var
  Sel: TIntArray;
  I: Integer;
  T: TTrackInfo;
  E: TPlEntry;
begin
  Sel := FPl.SelectedEntries;
  for I := 0 to High(Sel) do
  begin
    E := FPl.Entry(Sel[I]);
    if not LibLookup(E.FilePath, T) then
    begin
      T := Default(TTrackInfo);
      T.FilePath := E.FilePath;
      T.FolderDir := E.FolderDir;
      T.Title := E.Title;
      T.Artist := E.Artist;
      T.AlbumArtist := E.AlbumArtist;
      T.Album := E.Album;
      T.Genre := E.Genre;
      T.TrackNumber := E.TrackNum;
      T.DiscNumber := E.DiscNum;
      T.DurationStr := E.DurationStr;
      T.Year := E.Year;
      T.DateStr := E.DateStr;
      T.SampleRate := E.SampleRate;
      T.BitDepth := E.BitDepth;
    end;
    AList.Add(T);
  end;
end;

procedure TMainForm.MnPlAddTo(Sender: TObject);
var
  L: TTrackList;
  Target: string;
begin
  Target := AddToTarget(Sender);
  if Target = '' then Exit;
  L := TTrackList.Create;
  BeginBusy;         // (after the question for a new playlist's name)
  try
    SelectedPlTracks(L);
    AddTracksToPlaylist(Target, L);
  finally
    EndBusy;
    L.Free;
  end;
end;

procedure TMainForm.MnLibAddTo(Sender: TObject);
var
  L: TTrackList;
  Target: string;
begin
  Target := AddToTarget(Sender);
  if Target = '' then Exit;
  L := TTrackList.Create;
  BeginBusy;
  try
    FLib.CollectTracks(FLib.ActionNodes, L);
    AddTracksToPlaylist(Target, L);
  finally
    EndBusy;
    L.Free;
  end;
end;

{ ---- the playlist context menu ---- }

procedure TMainForm.PlContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
var
  Sub: TAuMenu;
  I: Integer;
  It: TAuMenuItem;
  HasSel, RO: Boolean;
  WorkLast: Integer;
begin
  HasSel := Length(FPl.SelectedEntries) > 0;
  RO := FPl.ReadOnly;
  FCtxMenu.Free;
  FCtxMenu := TAuMenu.Create;
  { what it acts on, from the selected tracks to the whole playlist; the
    windows last, Properties at the very end }
  It := FCtxMenu.Add('Play', @MnPlaySelected, icPlay, 'Enter');
  It.Enabled := HasSel;
  { the movements of the work the clicked track belongs to (work headings) }
  FCtxPlEntry := FPl.EntryOfRow(Row);
  It := FCtxMenu.Add('Select work', @MnPlSelectWork, icNote);
  It.Enabled := FPl.WorkOfEntry(FCtxPlEntry, I, WorkLast);
  Sub := FCtxMenu.AddSub('Rating', icStar);
  for I := 5 downto 1 do
  begin
    It := Sub.Add(StringOfChar('*', I), @MnPlRate, icStarFill);
    It.Tag := I;
  end;
  It := Sub.Add('No rating', @MnPlRate, icStar);
  It.Tag := 0;
  { a favourite is a track with five stars: ticked when all selected are }
  It := FCtxMenu.Add('Favourite', @MnPlFavourite, icHeart);
  It.Enabled := HasSel;
  It.Checked := SelectionIsFavourite;
  Sub := FCtxMenu.AddSub('Add to', icPlaylist);
  AddToPlaylistMenu(Sub, @MnPlAddTo);
  FCtxMenu.AddSeparator;
  It := FCtxMenu.Add('Open folder...', @MnShowInExplorer, icFolder);
  It.Enabled := HasSel;
  { what works on the selected tracks as a whole }
  Sub := FCtxMenu.AddSub('Tools', icSliders);
  It := Sub.Add('Calculate ReplayGain...', @MnPlReplayGain, icWave);
  It.Enabled := HasSel;
  It := Sub.Add('Check tag consistency...', @MnPlCheckTags, icDocument);
  It.Enabled := HasSel;
  FCtxMenu.AddSeparator;
  It := FCtxMenu.Add('Remove from playlist', @MnRemoveSelected, icTrash, 'Del');
  It.Enabled := HasSel and not RO;
  FCtxMenu.AddSeparator;
  FCtxMenu.Add('Expand all', @MnPlExpandAll, icTriDown);
  FCtxMenu.Add('Collapse all', @MnPlCollapseAll, icTriRight);
  It := FCtxMenu.Add('Jump to Now Playing', @JumpClick, icLocate, 'Ctrl+J');
  It.Enabled := FPlayingPath <> '';
  FCtxMenu.Add('Refresh', @MnRefresh, icRefresh, 'F5');
  It := FCtxMenu.Add('Remove dead items', @MnRemoveDead, icTrash);
  It.Enabled := (FPl.EntryCount > 0) and not RO;
  It := FCtxMenu.Add('Clear the playlist', @MnClearList, icTrash);
  It.Enabled := (FPl.EntryCount > 0) and not RO;
  FCtxMenu.AddSeparator;
  FCtxMenu.Add('Playlist Manager...', @MnPlaylistManager, icEdit, 'Alt+P');
  It := FCtxMenu.Add('Properties...', @MnPlProperties, icTag, 'Alt+Enter');
  It.Enabled := HasSel;
  FCtxMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

{ the selected tracks all have five stars (none selected: no) }
function TMainForm.SelectionIsFavourite: Boolean;
var
  Sel: TIntArray;
  I: Integer;
begin
  Sel := FPl.SelectedEntries;
  Result := Length(Sel) > 0;
  for I := 0 to High(Sel) do
    if FPl.Entry(Sel[I]).Rating < 5 then Exit(False);
end;

{ makes the selected tracks favourites (five stars), or takes the stars
  away when they all are }
procedure TMainForm.MnPlFavourite(Sender: TObject);
begin
  if SelectionIsFavourite then RateSelection(0) else RateSelection(5);
end;

procedure TMainForm.MnNewPlaylist(Sender: TObject);
var
  N: string;
begin
  if FPlaylists = nil then Exit;
  N := FPlaylists.UniqueName('New playlist');
  if not AskPlaylistName('New playlist', N) then Exit;
  if FPlaylists.Add(N, pkNormal) = nil then Exit;
  BeginBusy;
  try
    ShowPlaylist(N);
  finally
    EndBusy;
  end;
end;

procedure TMainForm.MnPlSticky(Sender: TObject);
begin
  AppSettings.Data.StickyHeaders := not AppSettings.Data.StickyHeaders;
  FPl.List.StickyHeaders := AppSettings.Data.StickyHeaders;
  FPl.List.Invalidate;
end;

procedure TMainForm.MnPlRate(Sender: TObject);
begin
  RateSelection(TAuMenuItem(Sender).Tag);
end;

{ the rating menu and Ctrl+0 .. Ctrl+5: the selected rows of
  the playlist (a header stands for its whole group) }
procedure TMainForm.RateSelection(ARating: Integer);
var
  Sel: TIntArray;
begin
  Sel := FPl.SelectedEntries;
  if Length(Sel) = 0 then Exit;
  BeginBusy;
  try
    FPl.RateEntries(Sel, EnsureRange(ARating, 0, 5));
  finally
    EndBusy;
  end;
end;

procedure TMainForm.MnPlExpandAll(Sender: TObject);
begin
  BeginBusy;
  try
    FPl.ExpandAll;
  finally
    EndBusy;
  end;
end;

procedure TMainForm.MnPlCollapseAll(Sender: TObject);
begin
  BeginBusy;
  try
    FPl.CollapseAll;
  finally
    EndBusy;
  end;
end;

{ the file check of uPlaylistRows.RowFileState (long paths too) }
function DeadItemFileExists(const APath: string): Boolean;
begin
  Result := FileExists(LongPath(APath));
end;

{ "Remove dead items": a file that is gone from a drive that is
  there; a file on a drive that is not connected stays.
  First the drives and shares
  of the playlist are checked on a worker thread (FindOfflineDrives; the
  "Waiting for drive..." window with Cancel when it takes a moment: a USB disk
  that spins up, a NAS that does not answer). Files on a drive that cannot be
  reached are not touched and stay in the playlist (RowFileState). When
  something is missing, a question with the numbers comes before anything is
  removed. Checking
  every file from the window's own thread would make the window wait for
  each file of a playlist on a NAS that is down. }
procedure TMainForm.MnRemoveDead(Sender: TObject);
var
  Dead: TIntArray;
  I, N, Kept: Integer;
  Paths, Offline: TStringList;
  KeptText, Ask: string;
begin
  if FPl.ReadOnly or (FPl.EntryCount = 0) then Exit;
  Paths := TStringList.Create;
  Offline := TStringList.Create;
  try
    for I := 0 to FPl.EntryCount - 1 do Paths.Add(FPl.Entry(I).FilePath);
    { Cancel: the playlist stays as it is }
    if not FindOfflineDrivesWithWindow(Self, Paths, Offline, APP_TITLE) then Exit;
    if FShuttingDown or (FPl.EntryCount <> Paths.Count) then Exit;
    Dead := nil;
    SetLength(Dead, Paths.Count);
    N := 0;
    Kept := 0;
    Screen.Cursor := crHourGlass;
    try
      for I := 0 to Paths.Count - 1 do
      begin
        KeepWindowAlive;        // (every file is looked for on its drive)
        case RowFileState(Paths[I], Offline, @DeadItemFileExists) of
          rfsMissing:
            begin
              Dead[N] := I;
              Inc(N);
            end;
          rfsDriveOffline: Inc(Kept);
        else
          ;
        end;
      end;
    finally
      Screen.Cursor := crDefault;
    end;
    SetLength(Dead, N);
    KeptText := '';
    if Kept > 0 then
      KeptText := SafeFormat('Kept %d on drives that are not connected (%s).', [Kept, DriveListText(Offline)]);
    if N = 0 then
    begin
      if Kept > 0 then FToast.ShowToast('No dead items', KeptText, icInfo, 4500)
      else FToast.ShowToast('No dead items', 'Every track of this playlist is there.', icInfo, 2200);
      Exit;
    end;
    { Nothing leaves the playlist without a yes; the question names what was
      found, and what stays because its drive cannot be reached }
    if N = 1 then Ask := SafeFormat('Remove 1 track whose file no longer exists from "%s"?', [FShownPl])
    else Ask := SafeFormat('Remove %d tracks whose files no longer exist from "%s"?', [N, FShownPl]);
    if Kept > 0 then Ask := Ask + sLineBreak + sLineBreak + KeptText;
    if ALMessageDlg('Remove dead items', Ask, 'Remove', 'Cancel', False, mbNo, mkWarning) <> mrYes then Exit;
    if FShuttingDown or (FPl.EntryCount <> Paths.Count) then Exit;
    FPl.RemoveEntries(Dead);
    if Kept > 0 then FToast.ShowToast(SafeFormat('%d dead items removed', [N]), KeptText, icTrash, 4500)
    else FToast.ShowToast(SafeFormat('%d dead items removed', [N]), FShownPl, icTrash, 2200);
  finally
    Offline.Free;
    Paths.Free;
  end;
end;

{ ---- drag and drop ---- }

procedure TMainForm.PlDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState;
  var Accept: Boolean);
var
  MarkRow: Integer;
  MarkAbove: Boolean;
begin
  Accept := ((Source = FLib.Tree) or (Source = FLib.Tiles.Grid) or (Source = FPl.List)) and not FPl.ReadOnly;
  { a sorted list: nothing is moved in it, and what is dropped finds its
    place by itself - no marker }
  if FPl.SortActive then
  begin
    if Source = FPl.List then Accept := False;
    FPl.List.SetDropMarker(-1, False);
    Exit;
  end;
  if (State = dsDragLeave) or not Accept then
  begin
    FPl.List.SetDropMarker(-1, False);
    Exit;
  end;
  FPl.InsertIndexAt(Y, MarkRow, MarkAbove);
  FPl.List.SetDropMarker(MarkRow, MarkAbove);
end;

procedure TMainForm.PlDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  MarkRow, At, First: Integer;
  MarkAbove: Boolean;
  L: TTrackList;
begin
  FPl.List.SetDropMarker(-1, False);
  if FPl.ReadOnly then Exit;
  At := FPl.InsertIndexAt(Y, MarkRow, MarkAbove);
  { a large selection moved, or a whole part of the library
    dropped: busy until the list is built again }
  BeginBusy;
  try
    if Source = FPl.List then
    begin
      if FPl.SortActive then
        FToast.ShowToast('This playlist is sorted', 'Choose "' + FPl.SortName(psAdded) +
          '" in the sort menu to arrange it by hand.', icInfo, 3200)
      else
        FPl.MoveEntries(FPl.SelectedEntries, At);
    end
    else if (Source = FLib.Tree) or (Source = FLib.Tiles.Grid) then
    begin
      L := TTrackList.Create;
      try
        FLib.CollectTracks(FLib.ActionNodes, L);
        if L.Count = 0 then Exit;
        FPl.AddTracks(L, At);
        First := FPl.LastAddedIndex;
        if First >= 0 then FPl.SelectEntry(First, True, False);
      finally
        L.Free;
      end;
    end;
  finally
    EndBusy;
  end;
end;

procedure TMainForm.PlEndDrag(Sender, Target: TObject; X, Y: Integer);
begin
  FPl.List.SetDropMarker(-1, False);
end;

{ an Explorer drop over the playlist: inserted at that point }
function TMainForm.PlaylistDropIndex(const AScreenPt: TPoint; out AIndex: Integer): Boolean;
var
  P: TPoint;
  MarkRow: Integer;
  MarkAbove: Boolean;
begin
  AIndex := -1;
  P := FPl.List.ScreenToClient(AScreenPt);
  Result := (P.X >= 0) and (P.Y >= 0) and (P.X < FPl.List.Width) and (P.Y < FPl.List.Height) and
    not FPl.ReadOnly;
  if Result then AIndex := FPl.InsertIndexAt(P.Y, MarkRow, MarkAbove);
end;

{ ---- M3U ---- }

{ an M3U / M3U8 file into a new playlist (the library's tags for its tracks);
  the new playlist's name, '' when the file could not be read }
function TMainForm.ImportM3UFile(const AFile: string; out AError: string): string;
var
  Entries: TM3UEntries;
  L: TTrackList;
  I: Integer;
  T: TTrackInfo;
  N: string;
  P: PStoredPlaylist;
  E: TPlaylistEntries;
begin
  Result := '';
  AError := '';
  if FPlaylists = nil then Exit;
  try
    ParseM3UEntries(AFile, Entries);
  except
    on Ex: Exception do
    begin
      AError := Ex.Message;
      Exit;
    end;
  end;
  L := TTrackList.Create;
  try
    for I := 0 to High(Entries) do
      if TrackFromM3UEntry(Entries[I], FLibrary, False, T) <> msLeftOut then L.Add(T);
    N := FPlaylists.UniqueName(ChangeFileExt(ExtractFileName(AFile), ''));
    P := FPlaylists.Add(N, pkNormal);
    if P = nil then
    begin
      AError := 'The playlist could not be made.';
      Exit;
    end;
    E := nil;
    SetLength(E, L.Count);
    for I := 0 to L.Count - 1 do E[I] := uPlaylistRows.EntryFromTrack(L[I]^);
    FPlaylists.SetEntries(P, E);
  finally
    L.Free;
  end;
  AddLog(SafeFormat('[Playlists] Imported "%s": %d tracks.', [AFile, Length(E)]));
  Result := N;
end;

{ a playlist as an M3U8 file: the stored tracks, or the tracks of an
  auto-playlist's rules now }
function TMainForm.ExportPlaylistM3U(const AName, AFile: string; out AError: string): Boolean;
var
  P: PStoredPlaylist;
  SL: TStringList;
  L: TTrackList;
  I: Integer;
  Suffix: string;

  procedure AddTrack(const APath, AArtist, ATitle: string; ASeconds: Integer);
  var
    Who: string;
  begin
    Who := AArtist;
    if Who <> '' then Who := Who + ' - ';
    SL.Add(SafeFormat('%s%d,%s%s', [M3U_EXTINF, ASeconds, Who, ATitle]));
    SL.Add(APath);
  end;

begin
  Result := False;
  AError := '';
  if FPlaylists = nil then Exit;
  if SameText(AName, FShownPl) then SaveShownPlaylist(True);   // the pane's changes first
  P := FPlaylists.Find(AName);
  if P = nil then
  begin
    AError := 'The playlist does not exist.';
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.Add(M3U_HEADER);
    if P^.Kind = pkAuto then
    begin
      L := TTrackList.Create;
      try
        if FLibrary <> nil then FLibrary.GetTracksByQuery(P^.Query, L, True);
        Suffix := '';
        SortAutoPlaylistByDate(L.List, P^.Query, PlGroupMode(P), Suffix);
        for I := 0 to L.Count - 1 do
          AddTrack(L[I]^.FilePath, L[I]^.Artist, L[I]^.Title, TimeStrToSecs(L[I]^.DurationStr));
      finally
        L.Free;
      end;
    end
    else
      for I := 0 to High(P^.Entries) do
        AddTrack(P^.Entries[I].FilePath, P^.Entries[I].Artist, P^.Entries[I].Title,
          TimeStrToSecs(P^.Entries[I].DurationStr));
    try
      SL.WriteBOM := False;
      SL.SaveToFile(AFile, TEncoding.UTF8);
      Result := True;
      AddLog(SafeFormat('[Playlists] Exported "%s" to "%s".', [AName, AFile]));
    except
      on Ex: Exception do AError := Ex.Message;
    end;
  finally
    SL.Free;
  end;
end;

procedure TMainForm.MnImportM3U(Sender: TObject);
var
  D: TOpenDialog;
  N, Err: string;
begin
  if FPlaylists = nil then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Import playlist';
    D.Filter := 'Playlists (*.m3u8;*.m3u)|*.m3u8;*.m3u|All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    Screen.Cursor := crHourGlass;
    try
      N := ImportM3UFile(D.FileName, Err);
    finally
      Screen.Cursor := crDefault;
    end;
    if N = '' then
      AuMessage('The playlist could not be read: ' + Err, amError, abOK, 'Import playlist')
    else
      ShowPlaylist(N);
  finally
    D.Free;
  end;
end;

procedure TMainForm.MnExportM3U(Sender: TObject);
var
  D: TSaveDialog;
  Err: string;
  Ok: Boolean;
begin
  if (FPlaylists = nil) or (FPl.EntryCount = 0) then Exit;
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'Export playlist';
    D.Filter := 'M3U8 playlist (*.m3u8)|*.m3u8|M3U playlist (*.m3u)|*.m3u';
    D.DefaultExt := 'm3u8';
    D.FileName := FShownPl + '.m3u8';
    D.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    BeginBusy;
    try
      Ok := ExportPlaylistM3U(FShownPl, D.FileName, Err);
    finally
      EndBusy;
    end;
    if Ok then
      FToast.ShowToast('Playlist exported', ExtractFileName(D.FileName), icExport, 2200)
    else
      AuMessage('The playlist could not be written: ' + Err, amError, abOK, 'Export playlist');
  finally
    D.Free;
  end;
end;

{ ---- the Playlist Manager and the Playlist Editor ---- }

{ the Playlist Manager; afterwards the renames reach the shown and
  the playing playlist, a deleted shown playlist gives way to Default, a
  changed one is shown again, a double clicked one is shown }
procedure TMainForm.MnPlaylistManager(Sender: TObject);
var
  R: TPlaylistManagerResult;
  I: Integer;
  Shown: string;
begin
  if (FPlaylists = nil) or FShuttingDown then Exit;
  SaveShownPlaylist(True);
  R.Activated := '';
  R.RenamedFrom := TStringList.Create;
  R.RenamedTo := TStringList.Create;
  R.Changed := TStringList.Create;
  try
    ShowPlaylistManager(Self, FPlaylists, FShownPl, @ImportM3UFile, @ExportPlaylistM3U, R);
    Shown := FShownPl;
    for I := 0 to R.RenamedFrom.Count - 1 do
    begin
      if SameText(Shown, R.RenamedFrom[I]) then Shown := R.RenamedTo[I];
      if SameText(FPlayingPl, R.RenamedFrom[I]) then
      begin
        FPlayingPl := R.RenamedTo[I];
        if FPlayback <> nil then FPlayback.RenameQueueSource(R.RenamedFrom[I], R.RenamedTo[I]);
      end;
    end;
    if (FPlayingPl <> '') and (FPlaylists.Find(FPlayingPl) = nil) then FPlayingPl := '';
    if not SameText(Shown, FShownPl) then
    begin
      { the shown playlist was renamed: the pane still holds its tracks }
      FShownPl := Shown;
      FPl.BtnPlaylist.Caption := Shown;
      AppSettings.Data.ActivePlayList := Shown;
    end;
    if R.Activated <> '' then ShowPlaylist(R.Activated, R.Changed.IndexOf(R.Activated) >= 0)
    else if FPlaylists.Find(FShownPl) = nil then ShowPlaylist(LBL_DEFAULT_PLAYLIST, True)
    else if R.Changed.IndexOf(FShownPl) >= 0 then ShowPlaylist(FShownPl, True);
  finally
    R.RenamedFrom.Free;
    R.RenamedTo.Free;
    R.Changed.Free;
  end;
end;

