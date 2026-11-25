{%MainUnit AuMainForm.pas}
{ ==============================================================================
  AulumicNS - AuMainForm_files.inc
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AuMainForm_files.inc - TMainForm: files into the play list and the play
  list into the play queue:
    CollectMusicFiles, AddPaths, PlayEntry, SyncQueueWithList,
    RemoveSelected, FormDropFiles, CheckIncoming, JumpToNowPlaying,
    MnAddFiles, MnAddFolder, MnPlaySelected, MnRemoveSelected, MnClearList,
    MnShowInExplorer
  Files go into the playlist on screen (an auto-playlist on
  screen: the Default playlist); an Explorer drop over the
  playlist is inserted there; the play queue is made from the shown
  playlist and stays with it (FPlayingPl).
  =============================================================================}

{ the music files of a folder and its sub folders, sorted per folder }
procedure TMainForm.CollectMusicFiles(const APath: string; AList: TStrings);
var
  SR: TSearchRec;
  Dir: string;
  Files, Dirs: TStringList;
  I: Integer;
begin
  Dir := IncludeTrailingPathDelimiter(APath);
  Files := TStringList.Create;
  Dirs := TStringList.Create;
  try
    if FindFirst(LongPath(Dir + '*'), faAnyFile, SR) = 0 then
    try
      repeat
        KeepWindowAlive;        // (a large or slow folder)
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
        begin
          if (SR.Attr and FILE_ATTRIBUTE_HIDDEN) = 0 then Dirs.Add(Dir + SR.Name);
        end
        else if IsValidMusicFile(SR.Name) then
          Files.Add(Dir + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Files.Sort;
    Dirs.Sort;
    AList.AddStrings(Files);
    for I := 0 to Dirs.Count - 1 do CollectMusicFiles(Dirs[I], AList);
  finally
    Files.Free;
    Dirs.Free;
  end;
end;

{ adds files and folders to the play list; PlayNow plays the first added
  track, Replace empties the list first }
procedure TMainForm.AddPaths(const Paths: array of string; PlayNow, Replace: Boolean);
var
  L: TStringList;
  I, First, Before: Integer;
begin
  L := TStringList.Create;
  try
    { busy from here, not only once the files are known:
      looking through a large or slow folder is the long part }
    BeginBusy;
    try
      for I := 0 to High(Paths) do
        if DirectoryExists(LongPath(Paths[I])) then CollectMusicFiles(Paths[I], L)
        else if FileExists(LongPath(Paths[I])) and IsValidMusicFile(Paths[I]) then L.Add(Paths[I]);
    finally
      EndBusy;
    end;
    if L.Count = 0 then
    begin
      if Length(Paths) > 0 then
        FToast.ShowToast('No music files', 'Nothing to add: Aulumic plays FLAC, WAV, DSF and DFF.', icInfo, 2600);
      Exit;
    end;
    BeginBusy;
    try
      { an auto-playlist cannot take files: the Default playlist does }
      if FPl.ReadOnly or Replace then ShowPlaylist(LBL_DEFAULT_PLAYLIST);
      if Replace then
      begin
        if FPlayback <> nil then FPlayback.Stop;
        FPl.Clear;
      end;
      Before := FPl.EntryCount;
      if (FDropAt >= 0) and (FDropAt <= Before) and not Replace then
      begin
        FPl.AddFiles(L, FDropAt);
        First := FDropAt;
      end
      else
      begin
        FPl.AddFiles(L);
        First := Before;
      end;
      { (a sorted playlist puts them where they belong) }
      if (FPl.EntryCount > Before) and (FPl.LastAddedIndex >= 0) then First := FPl.LastAddedIndex;
    finally
      EndBusy;
    end;
    if L.Count > 1 then
      AddLog(SafeFormat('%d files added to the play list.', [FPl.EntryCount - Before]));
    if PlayNow and (First < FPl.EntryCount) then PlayEntry(First)
    else if First < FPl.EntryCount then FPl.SelectEntry(First, True, False);
  finally
    L.Free;
  end;
end;

{ plays entry E of the play list: the play queue becomes the whole list
  (shuffle and repeat work on it), playing starts at E }
procedure TMainForm.PlayEntry(E: Integer);
var
  I: Integer;
  En: TPlEntry;
begin
  if (FPlayback = nil) or (E < 0) or (E >= FPl.EntryCount) then Exit;
  BeginBusy;         // (the whole list becomes the queue)
  try
    FPlayback.ClearQueue;
    { the queue is this playlist }
    FPlayingPl := FShownPl;
    for I := 0 to FPl.EntryCount - 1 do
    begin
      En := FPl.Entry(I);
      FPlayback.AddToQueue(En.FilePath, En.GroupKey, En.Id, FPlayingPl);
    end;
    FOpeningSince := GetTickCount64;
    FOpeningFile := FPl.Entry(E).FilePath;
    FRateShown := False;
    UpdateBannerNotice;
    FPlayback.StartQueue(E);
    FPl.SelectEntry(E, True, False);
    UpdateTimerPace;
  finally
    EndBusy;
  end;
end;

{ the list changed (files added or removed): the queue follows, the playing
  track keeps playing when it is still in the list - or, with AKeepPlaying,
  also when it is not (the list was built again, the user removed nothing) }
procedure TMainForm.SyncQueueWithList(AKeepPlaying: Boolean);
var
  L: TList;
  I: Integer;
  En: TPlEntry;
  Q: PQueueItem;
begin
  if (FPlayback = nil) or (FPlayback.QueueCount = 0) then Exit;
  { only the playing playlist feeds the queue }
  if not SameText(FShownPl, FPlayingPl) then Exit;
  L := TList.Create;
  try
    for I := 0 to FPl.EntryCount - 1 do
    begin
      KeepWindowAlive;
      En := FPl.Entry(I);
      New(Q);
      Q^.FilePath := En.FilePath;
      Q^.Album := En.GroupKey;
      Q^.TrackId := En.Id;
      Q^.SourceID := FPlayingPl;
      L.Add(Q);
    end;
    FPlayback.SyncQueue(L, AKeepPlaying);   // takes the items
  finally
    L.Free;
  end;
end;

procedure TMainForm.RemoveSelected;
var
  Sel: TIntArray;
  Row: Integer;
begin
  if FPl.ReadOnly then Exit;
  Sel := FPl.SelectedEntries;
  if Length(Sel) = 0 then Exit;
  Row := FPl.List.FocusedRow;
  BeginBusy;
  try
    FPl.RemoveEntries(Sel);      // OnChange: stored, the queue follows
    if FPl.List.RowCount > 0 then
      FPl.List.SelectOnly(EnsureRange(Row, 0, FPl.List.RowCount - 1));
  finally
    EndBusy;
  end;
end;

{ files dropped from Explorer: added to the list; with Ctrl the list is
  replaced and playing starts }
procedure TMainForm.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  Replace: Boolean;
  At: Integer;
begin
  Replace := GetKeyState(VK_CONTROL) < 0;
  { over the playlist: inserted where it was dropped }
  if (not Replace) and PlaylistDropIndex(Mouse.CursorPos, At) then FDropAt := At;
  try
    AddPaths(FileNames, Replace or (FPl.EntryCount = 0), Replace);
  finally
    FDropAt := -1;
  end;
end;

{ files handed over by a second start of the program (Explorer "Open with") }
procedure TMainForm.CheckIncoming;
var
  L: TStringList;
  A: array of string;
  I: Integer;
begin
  L := TStringList.Create;
  try
    if not TakeIncoming(L) then Exit;
    SetLength(A, L.Count);
    for I := 0 to L.Count - 1 do A[I] := L[I];
    AddPaths(A, True, False);
    if WindowState = wsMinimized then WindowState := wsNormal;
    Application.BringToFront;
  finally
    L.Free;
  end;
end;

{ switches to the playlist that plays, opens the track's group }
procedure TMainForm.JumpToNowPlaying;
begin
  if FPlayingPath = '' then Exit;
  if (FPlayingPl <> '') and not SameText(FShownPl, FPlayingPl) then ShowPlaylist(FPlayingPl);
  if FPl.PlayingEntry < 0 then Exit;
  FPl.SelectEntry(FPl.PlayingEntry, True, True);
  if FPl.List.CanFocus then FPl.List.SetFocus;
end;

{ ---- menu items ---- }

procedure TMainForm.MnAddFiles(Sender: TObject);
var
  D: TOpenDialog;
  A: array of string;
  I: Integer;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := TITLE_ADD_FILES;
    D.Filter := DIALOG_FILTER_AUDIO_FILES;
    D.Options := [ofAllowMultiSelect, ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if AppSettings.Data.LastAddDir <> '' then D.InitialDir := AppSettings.Data.LastAddDir;
    if not D.Execute then Exit;
    SetLength(A, D.Files.Count);
    for I := 0 to D.Files.Count - 1 do A[I] := D.Files[I];
    if D.Files.Count > 0 then AppSettings.Data.LastAddDir := ExtractFileDir(D.Files[0]);
    AddPaths(A, FPl.EntryCount = 0, False);
  finally
    D.Free;
  end;
end;

procedure TMainForm.MnAddFolder(Sender: TObject);
var
  Dir: string;
begin
  Dir := AppSettings.Data.LastAddDir;
  if not AuPickFolder('Add a folder to the play list', Dir) then Exit;
  AppSettings.Data.LastAddDir := Dir;
  AddPaths([Dir], FPl.EntryCount = 0, False);
end;

procedure TMainForm.MnPlaySelected(Sender: TObject);
var
  Sel: TIntArray;
begin
  Sel := FPl.SelectedEntries;
  if Length(Sel) > 0 then PlayEntry(Sel[0]);
end;

procedure TMainForm.MnRemoveSelected(Sender: TObject);
begin
  RemoveSelected;
end;

procedure TMainForm.MnClearList(Sender: TObject);
begin
  if (FPl.EntryCount = 0) or FPl.ReadOnly then Exit;
  BeginBusy;
  try
    FPl.Clear;                   // OnChange: stored; the playing playlist's queue ends
  finally
    EndBusy;
  end;
end;

procedure TMainForm.MnShowInExplorer(Sender: TObject);
var
  Sel: TIntArray;
begin
  Sel := FPl.SelectedEntries;
  if Length(Sel) > 0 then RevealPath(FPl.Entry(Sel[0]).FilePath);
end;

{ a right-click on the Now Playing banner: the folder of the playing track }
procedure TMainForm.BannerContext(Sender: TObject; ScreenPt: TPoint);
begin
  if FPlayingPath = '' then Exit;
  FCtxMenu.Free;
  FCtxMenu := TAuMenu.Create;
  FCtxMenu.Add('Open folder...', @MnBannerOpenFolder, icFolder);
  FCtxMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

procedure TMainForm.MnBannerOpenFolder(Sender: TObject);
begin
  if FPlayingPath <> '' then RevealPath(FPlayingPath);
end;

{ Explorer at a file or folder. Its drive is woken first on a
  worker thread ("Waiting for drive..." with Cancel when it takes a moment):
  RevealFileInExplorer's FileExists would freeze the window while a NAS wakes up. A
  network drive that does not answer gets a note instead. }
procedure TMainForm.RevealPath(const APath: string);
begin
  if Trim(APath) = '' then Exit;
  if DriveAwakeFor(APath) then RevealFileInExplorer(APath);
end;

{ The window's title while nothing plays: the name and the version (the
  screenshots show the name alone, so they do not change with every build) }
function TMainForm.IdleCaption: string;
begin
  Result := AppTitle;
  if not Application.HasOption('shots') then Result := Result + ' ' + GetAppVersion;
end;

{ Wakes the drive of a file or folder on a worker thread before the window's
  thread reads there. False: the wait was stopped, the program is closing, or
  a network drive does not answer (a note says so). }
function TMainForm.DriveAwakeFor(const APath: string): Boolean;
var
  Paths, Unreachable: TStringList;
  Reachable: Boolean;
begin
  Result := False;
  Paths := TStringList.Create;
  Unreachable := TStringList.Create;
  try
    Paths.Add(APath);
    if not WakeDrivesWithWindow(Self, Paths, APP_TITLE, Unreachable) then Exit;
    Reachable := Unreachable.Count = 0;
  finally
    Unreachable.Free;
    Paths.Free;
  end;
  if FShuttingDown then Exit;
  if not Reachable then FToast.ShowToast('Drive not reachable', ExtractFileDrive(APath), icInfo, 2600);
  Result := Reachable;
end;
