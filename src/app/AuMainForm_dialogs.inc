{%MainUnit AuMainForm.pas}
{ ==============================================================================
  AulumicNS - AuMainForm_dialogs.inc
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AuMainForm_dialogs.inc - TMainForm: the tools that work on files: the
  metadata custodian (tag writing on a background thread),
  Properties (the tag editor) from the library, the playlist or the main
  menu, the cover of a playlist group, and the ReplayGain scan with its
  notice in the status line. Debug build: the self-test of the drive wait
  (--test-drive-wait).
  =============================================================================}

{ ---- the metadata custodian ---- }

procedure TMainForm.InitCustodian;
begin
  FCustodian := TMetadataCustodian.Create(FLibrary, FPlayback);
  if AppStateManager <> nil then
  begin
    AppStateManager.OnEnqueueMetadataBatch := @FCustodian.EnqueueBatch;
    AppStateManager.OnBackgroundIOBatchFinished := @BackgroundIOBatchFinished;
    AppStateManager.OnReplayGainLabel := @RgLabel;
    AppStateManager.OnReplayGainProgress := @RgProgress;
  end;
end;

{ before the playback and the library go: the job being written ends, the
  ones still queued are dropped }
procedure TMainForm.FreeCustodian;
begin
  if AppStateManager <> nil then
  begin
    AppStateManager.OnEnqueueMetadataBatch := nil;
    AppStateManager.OnBackgroundIOBatchFinished := nil;
    AppStateManager.OnReplayGainLabel := nil;
    AppStateManager.OnReplayGainProgress := nil;
  end;
  if FCustodian = nil then Exit;
  FCustodian.StrangleAndStop;
  FreeAndNil(FCustodian);
end;

{ a batch of tag / ReplayGain writes is done: the library is saved, the
  playlist takes the new tags, the tree and the banner follow }
procedure TMainForm.BackgroundIOBatchFinished;
begin
  if FShuttingDown then Exit;
  { the status strip's "Finalizing updates..." and its nearly full bar are
    cleared after a tag or ReplayGain save (otherwise only a library scan
    that follows would clear them); a running scan keeps its own }
  if (FLibrary = nil) or not FLibrary.IsScanning then
  begin
    FStatus.Progress := -1;
    if (FPlayback = nil) or (FPlayback.State = psStopped) then FStatus.StatusText := STATUS_IDLE
    else FStatus.StatusText := '';
  end;
  { the folder watcher saw the writer's own changes: no library scan for them }
  MuteWatcherForOwnWrites;
  if (FLibrary <> nil) and FLibrary.IsDirty then FLibrary.SaveDatabase;
  FPl.ClearThumbCache;
  if not FPl.ReadOnly then FPl.SyncWithLibrary
  else ShowPlaylist(FShownPl, True);
  FPl.RefreshRatings;
  FLib.RefreshLibrary;
  if (FPlayback <> nil) and (FPlayback.State <> psStopped) then FPlayback.RefreshTrackInfo;
end;

{ ---- Properties ---- }

{ the tag editor for these files: the loader reads them, the dialog edits
  them, the custodian writes them }
procedure TMainForm.EditFileProperties(APaths: TStrings);
var
  Data: TList;
begin
  if (APaths = nil) or (APaths.Count = 0) then
  begin
    ALMessageDlg(CAP_TAG_EDITOR_PROPERTIES, MSG_NO_VALID_TRACKS, mkInfo);
    Exit;
  end;
  if (AppStateManager <> nil) and AppStateManager.HasState(esBackgroundIOBusy) then
  begin
    ALMessageDlg(TITLE_JUST_A_MOMENT, MSG_BACKGROUND_IO_BUSY, [mbOK]);
    Exit;
  end;
  Data := nil;
  try
    if not LoadTagsForEditor(APaths, Data) then Exit;
    ShowPropertiesDialog(Self, Data, FLibrary);
  finally
    DisposeTagData(Data);
  end;
end;

procedure TMainForm.LibraryPaths(const ANodes: TAuTreeNodeArray; APaths: TStrings);
var
  L: TTrackList;
  I: Integer;
  SL: TStringList;
begin
  APaths.Clear;
  if Length(ANodes) = 0 then Exit;
  L := TTrackList.Create;
  SL := TStringList.Create;
  try
    SL.Sorted := True;
    SL.Duplicates := dupIgnore;
    SL.UseLocale := False;
    Screen.Cursor := crHourGlass;
    try
      FLib.CollectTracks(ANodes, L);
    finally
      Screen.Cursor := crDefault;
    end;
    for I := 0 to L.Count - 1 do
      if L[I]^.FilePath <> '' then SL.Add(L[I]^.FilePath);
    APaths.Assign(SL);
  finally
    SL.Free;
    L.Free;
  end;
end;

procedure TMainForm.PlaylistPaths(APaths: TStrings);
var
  Sel: TIntArray;
  I: Integer;
begin
  APaths.Clear;
  Sel := FPl.SelectedEntries;
  for I := 0 to High(Sel) do APaths.Add(FPl.Entry(Sel[I]).FilePath);
end;

{ ---- Tag consistency ---- }

{ The part of the library that is selected (in the tile view without a
  selection: what the tiles show), or all of it when that is a group itself.
  The part is remembered as its files, not as nodes: the tree is built again
  when tags are saved from the window. }
procedure TMainForm.MnCheckTags(Sender: TObject);
var
  Nodes: TAuTreeNodeArray;
  Scope: string;
  Paths: TStringList;
begin
  if FLibrary = nil then Exit;
  Nodes := nil;
  if FLib.TileMode and (FLib.Tiles.Grid.SelCount = 0) then
  begin
    if FLib.Tree.FocusedNode <> nil then
    begin
      SetLength(Nodes, 1);
      Nodes[0] := FLib.Tree.FocusedNode;
    end;
  end
  else
    Nodes := FLib.ActionNodes;
  Scope := '';
  Paths := nil;
  if Length(Nodes) > 0 then
  begin
    Paths := TStringList.Create;
    LibraryPaths(Nodes, Paths);
    if Paths.Count = 0 then
      FreeAndNil(Paths)
    else if FLib.TileMode and (FLib.Tiles.Grid.SelCount > 0) then
      Scope := 'The selected albums'
    else
    begin
      Scope := StringReplace(FLib.Tree.NodePath(Nodes[0]), #1, ' > ', [rfReplaceAll]);
      if Length(Nodes) > 1 then Scope := Scope + SafeFormat(' and %d more', [Length(Nodes) - 1]);
    end;
  end;
  if Paths = nil then Scope := 'The whole library';
  CheckTagsOf(Paths, Scope);
end;

{ Main menu > Tools: the whole library }
procedure TMainForm.MnCheckTagsAll(Sender: TObject);
begin
  if FLibrary <> nil then CheckTagsOf(nil, 'The whole library');
end;

{ the playlist's menu: the selected tracks }
procedure TMainForm.MnPlCheckTags(Sender: TObject);
var
  Paths: TStringList;
begin
  if FLibrary = nil then Exit;
  Paths := TStringList.Create;
  PlaylistPaths(Paths);
  if Paths.Count = 0 then
  begin
    Paths.Free;
    Exit;
  end;
  CheckTagsOf(Paths, 'The selected tracks of the playlist');
end;

{ the window for these files (it takes the list over; nil: the whole library) }
procedure TMainForm.CheckTagsOf(APaths: TStringList; const AScope: string);
begin
  FreeAndNil(FCheckPaths);
  FCheckPaths := APaths;
  try
    ShowLibraryCheck(Self, AScope, @CheckCollect, @EditFileProperties);
  finally
    FreeAndNil(FCheckPaths);
  end;
end;

{ the tracks of that part as the library has them now }
procedure TMainForm.CheckCollect(ATracks: TTrackList);
var
  I: Integer;
  T: TTrackInfo;
begin
  ATracks.Clear;
  if FLibrary = nil then Exit;
  if FCheckPaths = nil then
  begin
    FLibrary.GetAllTracks(ATracks);
    Exit;
  end;
  for I := 0 to FCheckPaths.Count - 1 do
  begin
    KeepWindowAlive;
    if FLibrary.TryGetTrack(FCheckPaths[I], T) then ATracks.Add(T);
  end;
end;

{ the library's context menu }
procedure TMainForm.MnLibProperties(Sender: TObject);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    LibraryPaths(FLib.ActionNodes, SL);
    EditFileProperties(SL);
  finally
    SL.Free;
  end;
end;

{ the playlist's context menu }
procedure TMainForm.MnPlProperties(Sender: TObject);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    PlaylistPaths(SL);
    EditFileProperties(SL);
  finally
    SL.Free;
  end;
end;

{ Alt+Enter and the main menu: the pane with the focus (the playlist when
  neither has it) }
procedure TMainForm.MnProperties(Sender: TObject);
begin
  if FLib.ListFocused or FLib.Search.Focused then MnLibProperties(Sender)
  else MnPlProperties(Sender);
end;

{ ---- the cover viewer from a playlist header ---- }

{ the click (in the list's mouse down): the viewer opens once it is handled }
procedure TMainForm.PlCoverClick(Sender: TObject; AEntry: Integer);
begin
  if (AEntry < 0) or (AEntry >= FPl.EntryCount) then Exit;
  FCoverEntry := FPl.Entry(AEntry);
  Application.QueueAsyncCall(@ShowGroupCover, 0);
end;

procedure TMainForm.ShowGroupCover(Data: PtrInt);
var
  Meta: TAudioMetadata;
  Paths, Unreachable: TStringList;
  Path: string;
  Reachable: Boolean;
begin
  if FShuttingDown then Exit;
  Path := FCoverEntry.FilePath;
  { the header's names, for a file that cannot be read }
  Meta := Default(TAudioMetadata);
  Meta.Album := FCoverEntry.Album;
  Meta.AlbumArtist := FCoverEntry.AlbumArtist;
  if Path = '' then Exit;
  { the cover is read from the file: its drive is woken first (a window with
    Cancel when it takes a moment); a network drive that does not answer
    shows the names only, without touching the file }
  Paths := TStringList.Create;
  Unreachable := TStringList.Create;
  try
    Paths.Add(Path);
    if not WakeDrivesWithWindow(Self, Paths, APP_TITLE, Unreachable) then Exit;
    Reachable := Unreachable.Count = 0;
  finally
    Unreachable.Free;
    Paths.Free;
  end;
  if FShuttingDown then Exit;
  if Reachable and FileExists(LongPath(Path)) then
  begin
    Screen.Cursor := crHourGlass;
    try
      Meta := ReadTrackMetadata(Path, True);
    finally
      Screen.Cursor := crDefault;
    end;
    ShowCoverViewer(Self, Meta, Path);
  end
  else
    ShowCoverViewer(Self, Meta, '');
end;

{ ---- ReplayGain (the scanner with the built-in EBU R128 meter) ---- }

{ Main menu > Tools: the whole library }
procedure TMainForm.MnReplayGain(Sender: TObject);
begin
  if FLibrary <> nil then ReplayGainScanLibrary(FLibrary);
end;

{ the library menu: the albums of the selection }
procedure TMainForm.MnLibReplayGain(Sender: TObject);
var
  L: TTrackList;
begin
  if FLibrary = nil then Exit;
  L := TTrackList.Create;
  try
    Screen.Cursor := crHourGlass;
    try
      FLib.CollectTracks(FLib.ActionNodes, L);
    finally
      Screen.Cursor := crDefault;
    end;
    ReplayGainScanSelection(FLibrary, L);
  finally
    L.Free;
  end;
end;

{ the playlist menu: the albums of the selected tracks (the library's record
  of a track, else what the playlist knows of it) }
procedure TMainForm.MnPlReplayGain(Sender: TObject);
var
  L: TTrackList;
  Sel: TIntArray;
  I: Integer;
  T: TTrackInfo;
  E: TPlEntry;
begin
  if FLibrary = nil then Exit;
  L := TTrackList.Create;
  try
    Sel := FPl.SelectedEntries;
    for I := 0 to High(Sel) do
    begin
      E := FPl.Entry(Sel[I]);
      if not LibLookup(E.FilePath, T) then
      begin
        T := Default(TTrackInfo);
        T.FilePath := E.FilePath;
        T.Album := E.Album;
        T.AlbumArtist := E.AlbumArtist;
        T.Artist := E.Artist;
      end;
      L.Add(T);
    end;
    ReplayGainScanSelection(FLibrary, L);
  finally
    L.Free;
  end;
end;

{ the status line: "[ ReplayGain scanning... Click here to view ]" }
procedure TMainForm.RgLabel(AValue: Boolean);
begin
  if FShuttingDown then Exit;
  if AValue then FStatus.RgText := STATUS_BTN_RPSCANNING else FStatus.RgText := '';
end;

procedure TMainForm.RgProgress(ACurrent, ATotal: Integer);
begin
  if FShuttingDown or (FStatus.RgText = '') then Exit;
  FStatus.RgText := SafeFormat(FMT_STATUS_BTN_RPSCANNING, [ACurrent, ATotal]);
end;

procedure TMainForm.RgClick(Sender: TObject);
begin
  ShowReplayGainWindow;
end;

{$IFDEF DEBUG}
{ ---- --test-drive-wait=<report>: the wait for a drive, with a made-up slow
  drive (uDriveKeepAlive.DriveWakeProc), as a click on a cover runs it
  (WakeDrivesWithWindow). Three waits: 1.5 s (no window; a key pressed
  meanwhile does nothing, the timers run, the busy cursor is up), 7 s with
  Escape once the window is there, 3 s with Escape before it. Then a file
  written to a disk that takes 1.5 s (SaveTextFileWithWindow), and an
  hourglass that was left behind: the UI timer must take it away. Writes the
  report and closes; exit code = failures. ---- }

var
  GTestWakeMs: Integer = 0;

function TestSlowWake(const APath: string): Boolean;
begin
  Sleep(GTestWakeMs);
  Result := False;          // (not noted as "answered": every wait is a wait)
end;

function WaitWindowUp: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Screen.CustomFormCount - 1 do
    if (Screen.CustomForms[I].ClassName = 'TDriveWaitForm') and Screen.CustomForms[I].Visible then Exit(True);
end;

{ F10 (or Alt) pressed and let go on the real keyboard }
procedure PressMenuKey(AAlt: Boolean);
var
  K: Byte;
begin
  if AAlt then K := VK_MENU else K := VK_F10;
  keybd_event(K, 0, 0, 0);
  keybd_event(K, 0, KEYEVENTF_KEYUP, 0);
end;

procedure TMainForm.DriveWaitTestTick(Sender: TObject);
begin
  Inc(FWaitTestTicks);
  if FWaitTestTicks > 1 then Exit;
  FWaitTestBusy := (Screen.Cursor = crAppStart) and DriveWaitShowing and InputBlocked;
  FWaitTestPopup := WaitWindowUp;
  case FWaitTestStep of
    1: PostMessage(Handle, WM_KEYDOWN, VK_F1, 0);        // would open the help
    2, 3: PostMessage(Handle, WM_KEYDOWN, VK_ESCAPE, 0);
    5, 6: PressMenuKey(FWaitTestStep = 6);
    7, 8: PressMenuKey(FWaitTestStep = 8);   // (the wait window is up)
  end;
end;

procedure TMainForm.DriveWaitTestAsync(Data: PtrInt);
var
  R, Paths: TStringList;
  Fails, Forms0: Integer;
  T0, Took: QWord;
  Ok: Boolean;
  SaveFile, SaveErr: string;
  Saved: TFileSaveResult;

  procedure Check(ACond: Boolean; const AText: string);
  begin
    if ACond then R.Add('ok    ' + AText)
    else
    begin
      R.Add('FAIL  ' + AText);
      Inc(Fails);
    end;
  end;

  procedure Pump(AMs: Integer);
  var
    Began: QWord;
  begin
    Began := GetTickCount64;
    while GetTickCount64 - Began < AMs do
    begin
      Application.ProcessMessages;
      Sleep(10);
    end;
  end;

  procedure CloseMenuByKey;
  begin
    if not FMainMenu.IsOpen then Exit;
    keybd_event(VK_ESCAPE, 0, 0, 0);
    keybd_event(VK_ESCAPE, 0, KEYEVENTF_KEYUP, 0);
    Pump(400);
  end;

  procedure Wait(AStep, AWakeMs, ATickMs: Integer);
  begin
    GTestWakeMs := AWakeMs;
    FWaitTestStep := AStep;
    FWaitTestTicks := 0;
    FWaitTestBusy := False;
    FWaitTestPopup := False;
    FWaitTestTimer.Interval := ATickMs;
    FWaitTestTimer.Enabled := True;
    T0 := GetTickCount64;
    Ok := WakeDrivesWithWindow(Self, Paths, APP_TITLE, nil);
    Took := GetTickCount64 - T0;
    FWaitTestTimer.Enabled := False;
    R.Add(SafeFormat('--- wait %d: drive %d ms, look after %d ms: returned %s after %d ms',
      [AStep, AWakeMs, ATickMs, BoolToStr(Ok, True), Took]));
  end;

begin
  if FShuttingDown then Exit;
  Fails := 0;
  R := TStringList.Create;
  Paths := TStringList.Create;
  FWaitTestTimer := TTimer.Create(Self);
  FWaitTestTimer.Enabled := False;
  FWaitTestTimer.OnTimer := @DriveWaitTestTick;
  DriveWakeProc := @TestSlowWake;
  try
    Paths.Add('C:\made-up\track.flac');
    Forms0 := Screen.CustomFormCount;

    Wait(1, 1500, 600);
    Check(Ok, 'the wait ran to its end');
    Check((Took >= 1400) and (Took < 2600), 'in about the drive''s time');
    Check(FWaitTestTicks >= 1, 'a timer ran meanwhile (the window was alive)');
    Check(FWaitTestBusy, 'busy cursor up and input blocked during the wait');
    Check(not FWaitTestPopup, 'no "Waiting for drive..." window before its time');
    Application.ProcessMessages;
    Check(Screen.CustomFormCount = Forms0, 'F1 pressed during the wait opened nothing');
    Check(Screen.Cursor = crDefault, 'the cursor is back');
    Check((not InputBlocked) and not DriveWaitShowing, 'input is taken again');
    { the control: the same key now does open the help }
    PostMessage(Handle, WM_KEYDOWN, VK_F1, 0);
    Application.ProcessMessages;
    Check(Screen.CustomFormCount > Forms0, 'control: F1 after the wait opens the help');
    CloseHelpWindow;
    Application.ProcessMessages;

    Wait(2, 7000, DRIVE_WAIT_SHOW_DELAY_MS + 600);
    Check(FWaitTestPopup, 'the window is up after its delay');
    Check(FWaitTestBusy, 'still busy and blocked');
    Check(not Ok, 'Escape stopped the wait');
    Check(Took < 6600, 'at once, not at the drive''s end');
    Check(not WaitWindowUp, 'the window is gone');
    Check((Screen.Cursor = crDefault) and not InputBlocked, 'cursor and input are back');

    Wait(3, 3000, 600);
    Check(not FWaitTestPopup, 'no window yet');
    Check(not Ok, 'Escape stopped the wait before the window came');
    Check(Took < 1500, 'at once');
    Check((Screen.Cursor = crDefault) and not InputBlocked, 'cursor and input are back');

    { a small file written to a disk that takes its time: the write runs on a
      worker, the window stays alive }
    GTestWakeMs := 1500;
    FileSaveProc := @TestSlowWake;
    SaveFile := FWaitTestFile + '.save.tmp';
    FWaitTestStep := 4;
    FWaitTestTicks := 0;
    FWaitTestBusy := False;
    FWaitTestTimer.Interval := 600;
    FWaitTestTimer.Enabled := True;
    T0 := GetTickCount64;
    Saved := SaveTextFileWithWindow(Self, SaveFile, '', 'made-up', APP_TITLE, SaveErr);
    Took := GetTickCount64 - T0;
    FWaitTestTimer.Enabled := False;
    FileSaveProc := nil;
    R.Add(SafeFormat('--- a file saved to a disk that takes 1500 ms: returned after %d ms', [Took]));
    Check(Saved = fsrSaved, 'the file was saved');
    Check(FileExists(SaveFile), 'and is there');
    Check((Took >= 1400) and (Took < 2600), 'in about the disk''s time');
    Check(FWaitTestTicks >= 1, 'a timer ran meanwhile (the window was alive)');
    Check(FWaitTestBusy, 'busy cursor up and input blocked during the write');
    Check((Screen.Cursor = crDefault) and not InputBlocked, 'cursor and input are back');
    SysUtils.DeleteFile(SaveFile);

    { an hourglass that was left behind (and a BeginBusy without its EndBusy):
      the UI timer takes both away }
    R.Add('--- a stray hourglass');
    BeginBusy;
    BeginBusy;
    Check(Screen.Cursor = crHourGlass, 'the hourglass is up');
    T0 := GetTickCount64;
    while (Screen.Cursor <> crDefault) and (GetTickCount64 - T0 < 3000) do
    begin
      Application.ProcessMessages;
      Sleep(10);
    end;
    Check(Screen.Cursor = crDefault, SafeFormat('gone after %d ms', [GetTickCount64 - T0]));
    Check(FBusyDepth = 0, 'and the busy count is cleared');
    BeginBusy;
    EndBusy;
    Check(Screen.Cursor = crDefault, 'a later action ends without an hourglass');

    { F10 and Alt from the real keyboard open the main menu - but not while
      the program is busy or waits for a drive }
    R.Add('--- F10 and Alt while busy');
    SetForegroundWindow(Handle);
    Pump(300);
    if GetForegroundWindow <> Handle then
      R.Add('skipped: the window is not in front')
    else
    begin
      PressMenuKey(False);
      Pump(400);
      Check(FMainMenu.IsOpen, 'control: F10 opens the main menu');
      CloseMenuByKey;
      PressMenuKey(True);
      Pump(400);
      Check(FMainMenu.IsOpen, 'control: Alt opens the main menu');
      CloseMenuByKey;

      BeginBusy;
      PressMenuKey(False);
      Sleep(400);
      EndBusy;
      Pump(400);
      Check(not FMainMenu.IsOpen, 'F10 pressed in a busy section opens nothing');
      CloseMenuByKey;
      BeginBusy;
      PressMenuKey(True);
      Sleep(400);
      EndBusy;
      Pump(400);
      Check(not FMainMenu.IsOpen, 'Alt pressed in a busy section opens nothing');
      CloseMenuByKey;

      Wait(5, 1500, 600);
      Pump(400);
      Check(not FMainMenu.IsOpen, 'F10 pressed during a wait for a drive opens nothing');
      CloseMenuByKey;
      Wait(6, 1500, 600);
      Pump(400);
      Check(not FMainMenu.IsOpen, 'Alt pressed during a wait for a drive opens nothing');
      CloseMenuByKey;

      { the key goes down in the busy section and comes up after it }
      BeginBusy;
      keybd_event(VK_F10, 0, 0, 0);
      Sleep(300);
      EndBusy;
      Pump(100);
      keybd_event(VK_F10, 0, KEYEVENTF_KEYUP, 0);
      Pump(400);
      Check(not FMainMenu.IsOpen, 'F10 down while busy, up afterwards opens nothing');
      CloseMenuByKey;
      BeginBusy;
      keybd_event(VK_MENU, 0, 0, 0);
      Sleep(300);
      EndBusy;
      Pump(100);
      keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0);
      Pump(400);
      Check(not FMainMenu.IsOpen, 'Alt down while busy, up afterwards opens nothing');
      CloseMenuByKey;

      { the "Waiting for drive..." window is up and takes the keys }
      Wait(7, 7000, DRIVE_WAIT_SHOW_DELAY_MS + 600);
      Pump(400);
      Check(FWaitTestPopup, 'the window was up');
      Check(not FMainMenu.IsOpen, 'F10 pressed in the "Waiting for drive..." window opens nothing');
      CloseMenuByKey;
      Wait(8, 7000, DRIVE_WAIT_SHOW_DELAY_MS + 600);
      Pump(400);
      Check(not FMainMenu.IsOpen, 'Alt pressed in the "Waiting for drive..." window opens nothing');
      CloseMenuByKey;
    end;
  finally
    DriveWakeProc := nil;
    FileSaveProc := nil;
    FWaitTestTimer.Free;
    FWaitTestTimer := nil;
    { the two workers that were stopped still sleep: let them end }
    T0 := GetTickCount64;
    while SetAsideThreadsRunning and (GetTickCount64 - T0 < 9000) do Sleep(50);
    R.Add(SafeFormat('%d failures', [Fails]));
    try
      R.SaveToFile(FWaitTestFile);
    except
    end;
    R.Free;
    Paths.Free;
  end;
  System.ExitCode := Fails;
  Close;
end;
{$ENDIF}
