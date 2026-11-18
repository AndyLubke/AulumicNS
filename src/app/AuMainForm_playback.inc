{%MainUnit AuMainForm.pas}
{ ==============================================================================
  AulumicNS - AuMainForm_playback.inc
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AuMainForm_playback.inc - TMainForm: the engine (Aulumic's TPlaybackManager)
  and everything that shows or changes playback:
    InitPlayback, UpdateManagerConfig, UiTimerTick, UpdateTimerPace,
    UpdatePosition, UpdateMeter, UpdateEngineStatus, CheckOpeningUI,
    CheckStallUI, EndOpeningUI, EndStallUI, UpdateBannerNotice, UpdateBanner,
    UpdateRateLine, UpdateDeviceButton, UpdateVolumeUI, UpdateToneButton,
    UpdateModeButtons, IsVolumeLocked, CurrentDeviceName, the manager events
    (ManagerTrackChange ... ManagerBackgroundRequest), PlayPause,
    StopPlayback, NextTrack, PrevTrack, SeekBy, ChangeVolume, ToggleMute,
    ShowTone, ToneChanged, VolumeChanged, VolumeMuted, DeviceClick,
    DevicePick, BannerRate, RatePick, VolumeClick, SeekChange, SeekEnd
  =============================================================================}

{ ---> AulumicNS: what the rate line shows, in one string: a change of any of
  it (a restart with other settings, the next track at another rate) shows
  the line again (UiTimerTick) }
function SignalKey(const S: TSignalInfo): string;
begin
  if not S.Valid then Exit('');
  Result := Format('%d|%d|%d|%d|%d|%d|%d', [Ord(S.DoP), Ord(S.NativeDsd), Ord(S.DsdToPcm),
    Ord(S.Resampled), Ord(S.BitPerfect), S.InRate, S.OutRate]);
end;

{ ---- setup ---- }

procedure TMainForm.InitPlayback;
var
  I, N: Integer;
  Paths: array of string;
begin
  FPlayback := TPlaybackManager.Create;
  FPlayback.OnTrackChange := @ManagerTrackChange;
  FPlayback.OnTrackInfoRefreshed := @ManagerTrackInfoRefreshed;
  FPlayback.OnStateChange := @ManagerStateChange;
  FPlayback.OnModeChange := @ManagerModeChange;
  FPlayback.OnSampleRateError := @ManagerSampleRateError;
  FPlayback.OnBackgroundRequest := @ManagerBackgroundRequest;
  if HandleAllocated then FPlayback.NotifyHandle := Handle;
  UpdateManagerConfig;
  InitCustodian;
  { the shuffle / repeat modes of the last session }
  for I := 1 to 3 do
    if Ord(FPlayback.ShuffleMode) <> AppSettings.Data.ShuffleMode then FPlayback.ToggleShuffle;
  for I := 1 to 3 do
    if Ord(FPlayback.RepeatMode) <> AppSettings.Data.RepeatMode then FPlayback.ToggleRepeat;
  UpdateModeButtons;
  UpdateVolumeUI;
  UpdateToneButton;
  UpdateDeviceButton;
  FStatus.StatusText := STATUS_IDLE;
  FUiTimer.Enabled := True;
  AddLog(SafeFormat('%s %s (built %s) started.', [APP_TITLE, GetAppVersion, GetAppBuildDate]), True);
  { ---> AulumicNS: the resampler's inner loop on this CPU (AVX or SSE2) }
  AddLog('Resampler: ' + ResampleSimdName + ', long filters by FFT (the output is the same with each)');
  LogSettingsSummary(AppSettings.Data.Audio);
  MarkLogHead;
  {$IFDEF DEBUG}
  if FShotDir <> '' then Exit;
  {$ENDIF}
  { files given on the command line (Explorer "Open with", a double click) }
  N := 0;
  SetLength(Paths, ParamCount);
  for I := 1 to ParamCount do
    if (ParamStr(I) <> '') and (ParamStr(I)[1] <> '-') then
    begin
      Paths[N] := ParamStr(I);
      Inc(N);
    end;
  SetLength(Paths, N);
  if N > 0 then AddPaths(Paths, True, True);
end;

procedure TMainForm.UpdateManagerConfig;
begin
  if FPlayback = nil then Exit;
  AppSettings.SyncOutputDevice;
  FPlayback.Config := AppSettings.Data.Audio;
  SetPowerThrottlingOptOut(AppSettings.Data.Audio.UseHighResTimer);
  UpdateVolumeUI;
end;

{ ---- the UI timer ---- }

procedure TMainForm.UiTimerTick(Sender: TObject);
begin
  if FShuttingDown or (csDestroying in ComponentState) or (FPlayback = nil) then Exit;
  try
    CheckIncoming;
    CheckOpeningUI;
    CheckStallUI;
    { ---> AulumicNS: FIX the "busy" cursor (arrow + hourglass) stayed after an
      error had interrupted the code that resets it (seen after an access
      violation on a slow NAS): it belongs only to "Opening...", "Waiting for
      drive..." and the drive-wait window }
    if (Screen.Cursor = crAppStart) and (FOpeningSince = 0) and (not FStallShown) and
       (not DriveWaitShowing) then
      Screen.Cursor := crDefault;
    { ---> AulumicNS: the same safety net for the hourglass. Every place that
      shows it works on this thread without handling messages and takes it
      away in a finally, so by the time this timer runs none of them is at
      work: an hourglass seen here was left behind (an OldCursor saved while
      another hourglass was up, an error outside a try). FBusyDepth > 0 here
      can only be a BeginBusy that never got its EndBusy: it is cleared too,
      or every later action would end without taking the hourglass away. }
    if Screen.Cursor = crHourGlass then
    begin
      FBusyDepth := 0;
      Screen.Cursor := crDefault;
    end;
    FPlayback.Update;
    { the library: the scan at start (once the window is up), the watcher }
    if not FStartupScanDone then
    begin
      FStartupScanDone := True;
      {$IFDEF DEBUG}
      if FDebugScan then RequestLibraryScan(False, True)
      else if FShotDir = '' then
      {$ENDIF}
        if AppSettings.Data.AutoRescanLibrary and (FLibrary <> nil) and FLibrary.HasScanFolders then
          RequestLibraryScan(False, True);
    end;
    CheckWatcher;
    CheckPlaylistSave;
    { play counting, about once a second (also while minimized) }
    if GetTickCount64 - FPlayCountTick >= 1000 then
    begin
      if FPlayCountTick <> 0 then CountPlay((GetTickCount64 - FPlayCountTick) / 1000);
      FPlayCountTick := GetTickCount64;
    end;
    if WindowState <> wsMinimized then
    begin
      UpdatePosition;
      UpdateMeter;
      if (GetTickCount64 - FLastStatusTick > 1000) or
         ((FPlayback.State = psPlaying) and not FRateShown) then
      begin
        FLastStatusTick := GetTickCount64;
        UpdateEngineStatus;
        { ---> AulumicNS: also when what the stream does has changed }
        if (FPlayback.State = psPlaying) and
           ((not FRateShown) or (SignalKey(FPlayback.GetSignalInfo) <> FRateKey)) then
          UpdateRateLine;
      end
      { ---> AulumicNS: four times a second in between (was: only with the
        status line, once a second): after a setting that restarts the track
        - Play DSD natively, Lock volume, the output - the rate line, the
        volume icon and the Tone Control follow within a quarter of a second }
      else if (FPlayback.State = psPlaying) and (GetTickCount64 - FKeyTick >= 250) then
      begin
        FKeyTick := GetTickCount64;
        if SignalKey(FPlayback.GetSignalInfo) <> FRateKey then UpdateRateLine;
        UpdateToneHeadroom;
      end;
    end;
  finally
    UpdateTimerPace;
  end;
end;

procedure TMainForm.UpdateTimerPace;
var
  Fast: Boolean;
  NewInterval: Cardinal;
begin
  if FShuttingDown or (FPlayback = nil) then Exit;
  Fast := (FPlayback.State = psPlaying) or FPlayback.HasPendingIO or (FOpeningSince <> 0) or
    FBanner.Meter.Active;
  if Fast then NewInterval := UI_TIMER_INTERVAL_MS else NewInterval := UI_TIMER_IDLE_INTERVAL_MS;
  if FUiTimer.Interval <> NewInterval then FUiTimer.Interval := NewInterval;
end;

procedure TMainForm.UpdatePosition;
var
  Prog, Dur: Double;
  Sec: Integer;
begin
  if FPlayback.State in [psPlaying, psPaused] then
  begin
    Prog := FPlayback.GetProgress;
    Dur := FPlayback.GetDuration;
    FTransport.Seek.Enabled := Dur > 0;
    if FTransport.Seek.Dragging then Exit;
    FTransport.Seek.Position := Prog;
    if Dur > 0 then
    begin
      Sec := Trunc(Prog * Dur);
      if Sec <> FLastPlaySec then
      begin
        FLastPlaySec := Sec;
        FTransport.LblPos.Caption := FormatDuration(Sec);
        FTransport.LblTotal.Caption := FormatDuration(Round(Dur));
      end;
    end;
  end
  else if FLastPlaySec <> -1 then
  begin
    FLastPlaySec := -1;
    FTransport.Seek.Position := 0;
    FTransport.Seek.Enabled := False;
    FTransport.LblPos.Caption := ZERO_TIME;
    FTransport.LblTotal.Caption := ZERO_TIME;
  end;
end;

{ The audio thread measures the peak of every 20 ms of output (meter slices)
  when it hands the audio to the device: in bursts of a buffer, about one
  buffer ahead of what is heard. The slices wait in a FIFO and are shown at
  the pace of real time, as in Aulumic (TPeakMeterState.ProcessMeterSlices):
  each tick takes the slices due since the last one (elapsed time / 20 ms)
  and shows their peak; with none due, the last value stays. So the meter
  moves with the music, about in step with the sound.
  ---> AulumicNS (test list 2: "a bit too jumpy"): before, every slice beyond
  one buffer was shown at once and the ticks in between showed 0 - the meter
  jumped up with every burst and fell back in between. }
procedure TMainForm.UpdateMeter;
const
  FIFO_MAX_BACKLOG = 75;     // 1.5 s: the display fell behind (e.g. after a stall)
  FIFO_TRIM_TO     = 50;     // ... then the oldest slices go, down to 1 s
  NO_DATA_FALL_MS  = 1500;   // no slices for this long: the meter falls
  MAX_TICK_MS      = 250;
var
  N, I, Due: Integer;
  L, R: Double;
  HasL, HasR, CL, CR: Boolean;
  PL, PR: Single;
  NowTick, Elapsed: QWord;
begin
  if not (FBanner.ShowMeter and FBanner.Meter.Visible) then Exit;
  {$IFDEF DEBUG}
  { the screenshots keep the demo levels (DemoBanner); --ui-bench drives it }
  if (FShotDir <> '') or (FUiBenchFile <> '') then Exit;
  {$ENDIF}
  if (FPlayback.State = psPlaying) and not FIsCurrentDoP then
  begin
    FPlayback.Engine.ReadPeaks(L, R, HasL, HasR, CL, CR);
    FPlayback.Engine.ReadMeterSlices(FMeterSlices, N);
    if FPlayback.Engine.MeterEpoch <> FMeterEpochSeen then
    begin
      { a seek or a new stream: what was waiting belongs to the old position }
      FMeterEpochSeen := FPlayback.Engine.MeterEpoch;
      FMeterFifoLen := 0;
      FMeterAccMs := 0;
      FMeterNoDataMs := 0;
      N := 0;
    end;
    if FMeterFifoLen + N > Length(FMeterFifo) then SetLength(FMeterFifo, FMeterFifoLen + N + 64);
    for I := 0 to N - 1 do
    begin
      FMeterFifo[FMeterFifoLen] := FMeterSlices[I];
      Inc(FMeterFifoLen);
    end;
    if FMeterFifoLen > FIFO_MAX_BACKLOG then
    begin
      Move(FMeterFifo[FMeterFifoLen - FIFO_TRIM_TO], FMeterFifo[0], FIFO_TRIM_TO * SizeOf(TMeterSlice));
      FMeterFifoLen := FIFO_TRIM_TO;
    end;
    { the slices due since the last tick }
    NowTick := GetTickCount64;
    if (FMeterLastTick = 0) or (NowTick < FMeterLastTick) then Elapsed := UI_TIMER_INTERVAL_MS
    else
    begin
      Elapsed := NowTick - FMeterLastTick;
      if Elapsed > MAX_TICK_MS then Elapsed := MAX_TICK_MS;
    end;
    FMeterLastTick := NowTick;
    FMeterAccMs := FMeterAccMs + Elapsed;
    Due := Trunc(FMeterAccMs / METER_SLICE_MS);
    FMeterAccMs := FMeterAccMs - Due * METER_SLICE_MS;
    if Due > FMeterFifoLen then
    begin
      { not enough yet: show what there is, without building up a debt
        (which would play the next burst out too fast) }
      Due := FMeterFifoLen;
      FMeterAccMs := 0;
    end;
    if Due > 0 then
    begin
      PL := 0;
      PR := 0;
      for I := 0 to Due - 1 do
      begin
        if FMeterFifo[I].PeakL > PL then PL := FMeterFifo[I].PeakL;
        if FMeterFifo[I].PeakR > PR then PR := FMeterFifo[I].PeakR;
      end;
      if FMeterFifoLen > Due then
        Move(FMeterFifo[Due], FMeterFifo[0], (FMeterFifoLen - Due) * SizeOf(TMeterSlice));
      Dec(FMeterFifoLen, Due);
      FMeterLastL := PL;
      FMeterLastR := PR;
      FMeterNoDataMs := 0;
    end
    else
    begin
      if FMeterNoDataMs < NO_DATA_FALL_MS then Inc(FMeterNoDataMs, Integer(Elapsed));
      if FMeterNoDataMs >= NO_DATA_FALL_MS then
      begin
        FMeterLastL := 0;
        FMeterLastR := 0;
      end;
    end;
    FBanner.Meter.Active := True;
    FBanner.Meter.SetLevels(FMeterLastL, FMeterLastR);
    FBanner.Meter.SetClip(CL, CR);           // ---> AulumicNS: the red top block (as Aulumic)
  end
  else if FPlayback.State = psPaused then
  begin
    FMeterLastTick := 0;
    FBanner.Meter.SetLevels(0, 0)            // falls back
  end
  else if FBanner.Meter.Active then
  begin
    FMeterFifoLen := 0;
    FMeterLastTick := 0;
    FMeterAccMs := 0;
    FMeterLastL := 0;
    FMeterLastR := 0;
    FBanner.Meter.Active := False;
  end;
end;

{ the status line during playback (Aulumic's TAGFMT_STATUS_ENGINE):
  [resampling phase | ][gain | ]Buffer: n ms | CPU: x % }
procedure TMainForm.UpdateEngineStatus;
var
  St: TAudioStats;
  A: TManagerConfig;
  T, Part: string;
  Phase: Integer;
begin
  if FPlayback.State <> psPlaying then
  begin
    if FPlayback.State = psStopped then FStatus.EngineText := '';
    Exit;
  end;
  St := FPlayback.GetEngineStats;
  A := AppSettings.Data.Audio;
  T := '';
  if (St.InputRate > 0) and (St.OutputRate > 0) and A.ResamplePCM and (not FIsCurrentDoP) and
     (not (FIsCurrentDsd and A.DisableResampleForDSD)) and (St.InputRate <> St.OutputRate) then
  begin
    if St.OutputRate > St.InputRate then
    begin
      Phase := A.UpsamplePhase;
      Part := 'Upsampling: ';
    end
    else
    begin
      Phase := A.DownsamplePhase;
      Part := 'Downsampling: ';
    end;
    T := Part + PHASE_OPTIONS[EnsureRange(Phase, 0, High(PHASE_OPTIONS))].DisplayName + '  |  ';
  end;
  if (not FIsCurrentDoP) and (not A.VolumeLocked) then
  begin
    if (Abs(St.AppliedReplayGain) > 0.001) and (A.PreampDB < 0) then
      T := T + Format('Gain: %.2f dB (RG) + %.1f dB (Preamp)', [St.AppliedReplayGain, A.PreampDB]) + '  |  '
    else if Abs(St.AppliedReplayGain) > 0.001 then
      T := T + Format('Gain: %.2f dB (RG)', [St.AppliedReplayGain]) + '  |  '
    else if A.PreampDB < 0 then
      T := T + Format('Gain: %.1f dB (Preamp)', [A.PreampDB]) + '  |  ';
  end;
  if (FCpuTick = 0) or (GetTickCount64 - FCpuTick >= 1000) then
  begin
    FCpuTick := GetTickCount64;
    FCpuText := Format('%.1f%%', [GetAppCPUUsage]);
  end;
  T := T + 'Buffer: ' + IntToStr(St.BufferSizeMs) + ' ms  |  CPU: ' + FCpuText;
  if A.OutputApi = 1 then T := T + '  |  ASIO';
  FStatus.EngineText := T;
end;

{ ---- "Opening..." and "Waiting for drive..." ---- }

procedure TMainForm.CheckOpeningUI;
const
  OPENING_GIVE_UP_MS = 30000;
begin
  if FOpeningSince = 0 then Exit;
  if (FPlayback.State = psPlaying) and (FPlayback.Engine.GetOutputRate > 0) then
    EndOpeningUI(True)
  else if ((not FPlayback.IsOpening) and (FPlayback.State <> psPlaying)) or
          (GetTickCount64 - FOpeningSince > OPENING_GIVE_UP_MS) then
    EndOpeningUI(False)
  else if Screen.Cursor = crDefault then
    Screen.Cursor := crAppStart;
end;

procedure TMainForm.CheckStallUI;
const
  STALL_SHOW_MS = 2000;
var
  P: Double;
  NowTick: QWord;
begin
  if (FPlayback.State <> psPlaying) or (FOpeningSince <> 0) or (FPlayback.Engine.GetOutputRate <= 0) then
  begin
    if FStallShown then EndStallUI(False);
    FStallSince := 0;
    Exit;
  end;
  P := FPlayback.Engine.GetProgress;
  NowTick := GetTickCount64;
  if (FStallSince = 0) or (P <> FStallProgress) then
  begin
    if FStallShown then EndStallUI(True);
    { ---> AulumicNS: the track moves on: its drive delivers, so a click on a
      cover of the same drive needs no "is it awake?" check (WakeDrives) }
    if FStallSince <> 0 then NoteDriveAnswered(FPlayingPath);
    FStallProgress := P;
    FStallSince := NowTick;
    Exit;
  end;
  if (not FStallShown) and (NowTick - FStallSince >= STALL_SHOW_MS) then
  begin
    FStallShown := True;
    UpdateBannerNotice;
  end;
  if FStallShown and (Screen.Cursor = crDefault) then Screen.Cursor := crAppStart;
end;

procedure TMainForm.EndStallUI(ALog: Boolean);
var
  Elapsed: QWord;
begin
  if not FStallShown then Exit;
  FStallShown := False;
  Elapsed := GetTickCount64 - FStallSince;
  if Screen.Cursor = crAppStart then Screen.Cursor := crDefault;
  if ALog then
    AddLog(SafeFormat(FMT_LOG_PLAYBACK_STALLED, [ExtractFileName(FPlayingPath),
      Integer(Elapsed div 1000), Integer((Elapsed mod 1000) div 100)]));
  UpdateBannerNotice;
  UpdateRateLine;
end;

procedure TMainForm.EndOpeningUI(ADone: Boolean);
const
  SLOW_OPEN_LOG_MS = 1000;
var
  Elapsed: QWord;
begin
  if FOpeningSince = 0 then Exit;
  Elapsed := GetTickCount64 - FOpeningSince;
  FOpeningSince := 0;
  if Screen.Cursor = crAppStart then Screen.Cursor := crDefault;
  if ADone and (Elapsed >= SLOW_OPEN_LOG_MS) then
    AddLog(SafeFormat(FMT_LOG_SLOW_OPEN, [ExtractFileName(FOpeningFile),
      Integer(Elapsed div 1000), Integer((Elapsed mod 1000) div 100)]));
  FOpeningFile := '';
  UpdateBannerNotice;
  UpdateRateLine;
end;

procedure TMainForm.UpdateBannerNotice;
var
  N: string;
begin
  if FStallShown then N := 'Waiting for drive...'
  else if FOpeningSince <> 0 then N := 'Opening...'
  else N := '';
  if N <> FBanner.Notice then
  begin
    FBanner.Notice := N;
    FBanner.Changed;
  end;
end;

{ ---- the banner ---- }

function KHzText(Rate: Integer): string;
begin
  if Rate mod 1000 = 0 then Result := IntToStr(Rate div 1000)
  else Result := FormatFloat('0.0##', Rate / 1000);
end;

procedure TMainForm.UpdateBanner;
var
  M: TAudioMetadata;
  Names: array of string;
  Parts: TStringArray;
  E, Idx, Cnt, Total: Integer;
  Data: TBytes;
  B, Before: TGfxBitmap;
  Ext: string;
  St: PUserTrackStats;

  procedure AddNames(const Raw: string);
  var
    K: Integer;
  begin
    Parts := SplitTags(Raw);
    for K := 0 to High(Parts) do
    begin
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := Parts[K];
    end;
  end;

begin
  if FPlayingPath = '' then
  begin
    FBanner.Clear;
    Exit;
  end;
  M := FCurrentMeta;
  { ---> AulumicNS: another track: the banner fades over to it }
  if FBanner.Title <> M.Title then Before := SnapshotControls(FBanner) else Before := nil;
  FBanner.Playing := True;
  FBanner.Title := M.Title;
  FBanner.Album := M.Album;
  if Trim(M.Genre) <> '' then FBanner.Genre := FormatTagString(M.Genre, 0)
  else FBanner.Genre := LBL_UNKNOWN_GENRE;
  Names := nil;
  AddNames(M.AlbumArtist);
  AddNames(M.Artist);
  AddNames(M.Performer);
  AddNames(M.Composer);
  FBanner.SetArtists(Names);
  { "Track 1 of 8  •  4:33 / 47:17" }
  E := FPl.IndexOfId(FPlayingId);
  FPl.GroupInfo(E, Idx, Cnt, Total);
  if Cnt > 0 then FBanner.Meta := SafeFormat(FMT_TOP_META_TRACK_OF, [Idx, Cnt, M.DurationStr, FormatDuration(Total)])
  else FBanner.Meta := SafeFormat(FMT_TOP_META_TRACK, [M.TrackNumber, M.DurationStr]);
  { source information }
  if FIsCurrentDsd then
  begin
    FBanner.Codec := LBL_CODEC_DSD;
    if M.SampleRate > 0 then FBanner.Resolution := DsdRateName(M.SampleRate)
    else FBanner.Resolution := '';
  end
  else
  begin
    Ext := UpperCase(Copy(ExtractFileExt(FPlayingPath), 2, 10));
    FBanner.Codec := Ext;
    if (M.BitDepth > 0) and (M.SampleRate > 0) then
      FBanner.Resolution := Format('%d bit / %s kHz', [M.BitDepth, KHzText(M.SampleRate)])
    else if M.SampleRate > 0 then
      FBanner.Resolution := KHzText(M.SampleRate) + ' kHz'
    else
      FBanner.Resolution := '';
  end;
  case M.Channels of
    0: FBanner.Channels := '';
    1: FBanner.Channels := LBL_CHANNELS_MONO;
    2: FBanner.Channels := LBL_CHANNELS_STEREO;
  else
    FBanner.Channels := IntToStr(M.Channels) + ' channels';
  end;
  { the cover: the embedded picture, else the folder's (both read by the
    playback I/O worker, no disk access here) }
  Data := nil;
  if M.HasCover and (Length(M.CoverData) > 0) then Data := M.CoverData
  else if M.FolderInfoValid and (Length(M.FolderCoverData) > 0) then Data := M.FolderCoverData;
  B := nil;
  if Length(Data) > 0 then B := ImageFromBytes(Data, 640);
  FBanner.SetCover(B);
  if B <> nil then
  begin
    FBanner.AmbientColor := CoverAmbientColor(B);
    DisposeBitmap(B);
  end
  else
    FBanner.AmbientColor := 0;
  FBanner.HasBooklet := M.FolderInfoValid and M.FolderHasPDF;
  St := TrackStats(FPlayingPath, M);
  FBanner.Favorite := (St <> nil) and St^.IsFavorite;
  FBanner.Changed;
  CrossFadeFrom(FBanner, Before);
end;

{ the rate line of the banner and the bit-perfect badge
  ---> AulumicNS: from what the engine really does (the snapshot of the signal
  path), no longer from the settings when the track started: they change
  while it plays (the output, "Play DSD natively", resampling DSD), and a
  restart sends no track change. A stale DoP flag read the 88.2 kHz of DSD64
  converted to PCM as "DSD32". }
procedure TMainForm.UpdateRateLine;
var
  Si: TSignalInfo;
  OutText, T: string;
  Stale: Boolean;
begin
  Si := FPlayback.GetSignalInfo;
  { ---> AulumicNS: right after a track change the engine may still describe
    the stream of the track before (the device is reopened for another rate
    or for DSD). Taken as the new track's, a PCM track after DSD showed the
    volume as fixed - and played at 100 % - and DSD after PCM did not, until
    something else updated the volume icon. Such a snapshot is not shown: the
    timer asks again at once (FRateShown stays False). After 3 s whatever the
    engine says counts (a file whose tags give another rate than its audio). }
  Stale := Si.Valid and (GetTickCount64 - FTrackTick < 3000) and
    ((Si.IsDsd <> FIsCurrentDsd) or
     ((not Si.IsDsd) and (FCurrentMeta.SampleRate > 0) and (Si.InRate <> FCurrentMeta.SampleRate)));
  if (FPlayingPath = '') or (FPlayback.State = psStopped) or (not Si.Valid) or (Si.OutRate <= 0) or Stale then
  begin
    FRateShown := False;
    FRateKey := '';
    if (FBanner.RateText <> '') or (FBanner.Badge <> bbNone) then
    begin
      FBanner.RateText := '';
      FBanner.Badge := bbNone;
      FBanner.Changed;
    end;
    Exit;
  end;
  { the rate menu and the tone control's note follow the stream as well }
  { ---> AulumicNS: everything on the main window that depends on "DSD goes
    out as DSD" follows together: the Tone Control and its button, and the
    volume (fixed at 100 % or not; before, only the tone control followed) }
  if FIsCurrentDoP <> (Si.DoP or Si.NativeDsd) then
  begin
    FIsCurrentDoP := Si.DoP or Si.NativeDsd;
    UpdateToneButton;
    UpdateVolumeUI;
  end;
  FIsCurrentDsdToPcm := Si.DsdToPcm;
  { the Tone Control's curve is that of the filters at this rate }
  if (FTone <> nil) and not FIsCurrentDoP then FTone.SetCurveRate(Si.OutRate);
  { DSD as DSD: the DoP carrier rate x 16 is the DSD rate }
  if FIsCurrentDoP then OutText := DsdRateName(Si.OutRate * DOP_DSD_FACTOR)
  else OutText := FormatRateKHz(Si.OutRate);
  FLastBitPerfect := Si.BitPerfect;
  if Si.BitPerfect then T := LBL_BIT_PERFECT + ': ' + OutText
  else if FIsCurrentDoP then T := 'DSD Direct: ' + OutText
  else if FIsCurrentDsdToPcm then T := 'DSD to PCM: ' + OutText
  else if Si.Resampled then T := 'Resample: ' + OutText
  else T := 'Native Rate: ' + OutText;
  FRateKey := SignalKey(Si);
  FBanner.RateText := T;
  if Si.BitPerfect then
  begin
    FBanner.Badge := bbBitPerfect;
    FBanner.BadgeText := 'Bit-perfect';
  end
  else
  begin
    FBanner.Badge := bbProcessed;
    FBanner.BadgeText := 'Processed';
  end;
  FRateShown := True;
  FBanner.Changed;
end;

{ ---- device ---- }

function TMainForm.CurrentDeviceName: string;
var
  L: TStringList;
  I, P, DefIdx: Integer;
  Id: string;
begin
  Result := LBL_UNKNOWN_DEVICE;
  L := TStringList.Create;
  try
    if AppSettings.Data.OutputApi = 1 then
    begin
      TAudioEngine.EnumerateAsioDevices(L);
      Id := AppSettings.Data.AsioDriverID;
      for I := 0 to L.Count - 1 do
      begin
        P := Pos('|', L[I]);
        if (P > 0) and SameText(Copy(L[I], P + 1, MaxInt), Id) then Exit(Copy(L[I], 1, P - 1));
      end;
      if (Id = '') and (L.Count > 0) then
      begin
        { no driver chosen yet: the first one }
        P := Pos('|', L[0]);
        AppSettings.Data.AsioDriverID := Copy(L[0], P + 1, MaxInt);
        AppSettings.SyncOutputDevice;
        Exit(Copy(L[0], 1, P - 1));
      end;
      if L.Count = 0 then Result := 'No ASIO driver';
    end
    else
    begin
      TAudioEngine.EnumerateDevices(L, DefIdx);
      Id := AppSettings.Data.WasapiDeviceID;
      for I := 0 to L.Count - 1 do
      begin
        P := Pos('|', L[I]);
        if (P > 0) and SameText(Copy(L[I], P + 1, MaxInt), Id) then Exit(CleanDeviceName(Copy(L[I], 1, P - 1)));
      end;
      { the configured DAC is switched off or unplugged: keep it and show its name }
      if Id <> '' then
      begin
        Result := TAudioEngine.GetDeviceFriendlyName(Id);
        if Result <> '' then Result := CleanDeviceName(Result) else Result := LBL_UNKNOWN_DEVICE;
      end
      else if (DefIdx >= 0) and (DefIdx < L.Count) then
      begin
        P := Pos('|', L[DefIdx]);
        AppSettings.Data.WasapiDeviceID := Copy(L[DefIdx], P + 1, MaxInt);
        AppSettings.SyncOutputDevice;
        Result := CleanDeviceName(Copy(L[DefIdx], 1, P - 1));
      end;
    end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.UpdateDeviceButton;
begin
  if AppSettings.Data.OutputApi = 1 then FTransport.BtnDevice.Icon := icBolt
  else FTransport.BtnDevice.Icon := icHeadphones;
  FTransport.SetDeviceName(CurrentDeviceName);
end;

procedure TMainForm.DeviceClick(Sender: TObject);
var
  L: TStringList;
  I, P, DefIdx: Integer;
  It: TAuMenuItem;
  Id: string;
  ChosenListed: Boolean;
begin
  FDeviceMenu.Free;
  FDeviceMenu := TAuMenu.Create;
  FDeviceIds.Clear;
  L := TStringList.Create;
  try
    It := FDeviceMenu.Add('WASAPI exclusive', nil, icHeadphones);
    It.Enabled := False;
    TAudioEngine.EnumerateDevices(L, DefIdx);
    ChosenListed := False;
    for I := 0 to L.Count - 1 do
    begin
      P := Pos('|', L[I]);
      if P = 0 then Continue;
      Id := Copy(L[I], P + 1, MaxInt);
      It := FDeviceMenu.Add(CleanDeviceName(Copy(L[I], 1, P - 1)), @DevicePick);
      It.Tag := FDeviceIds.Add('0|' + Id);
      It.Checked := (AppSettings.Data.OutputApi = 0) and SameText(Id, AppSettings.Data.WasapiDeviceID);
      if SameText(Id, AppSettings.Data.WasapiDeviceID) then ChosenListed := True;
    end;
    { ---> AulumicNS: the chosen WASAPI device also when Windows does not list
      it as active, as Preferences does: during native DSD over ASIO the DAC's
      WASAPI device is gone (on the user's NUC the menu had no WASAPI entry
      then, so there was no way back). Picking it stops ASIO; the new stream
      waits for the device to come back (TPlayThreadConfig.SettleMs). }
    Id := AppSettings.Data.WasapiDeviceID;
    if (not ChosenListed) and (Id <> '') then
    begin
      It := FDeviceMenu.Add(DeviceNameForID(0, Id), @DevicePick);
      It.Tag := FDeviceIds.Add('0|' + Id);
      It.Checked := AppSettings.Data.OutputApi = 0;
    end
    else if (not ChosenListed) and (FDeviceIds.Count = 0) then
    begin
      It := FDeviceMenu.Add('No WASAPI device found', nil);
      It.Enabled := False;
    end;
    FDeviceMenu.AddSeparator;
    It := FDeviceMenu.Add('ASIO', nil, icBolt);
    It.Enabled := False;
    TAudioEngine.EnumerateAsioDevices(L);
    if L.Count = 0 then
    begin
      It := FDeviceMenu.Add('No ASIO driver installed', nil);
      It.Enabled := False;
    end;
    for I := 0 to L.Count - 1 do
    begin
      P := Pos('|', L[I]);
      if P = 0 then Continue;
      Id := Copy(L[I], P + 1, MaxInt);
      It := FDeviceMenu.Add(Copy(L[I], 1, P - 1), @DevicePick);
      It.Tag := FDeviceIds.Add('1|' + Id);
      It.Checked := (AppSettings.Data.OutputApi = 1) and SameText(Id, AppSettings.Data.AsioDriverID);
    end;
  finally
    L.Free;
  end;
  FTransport.BtnDevice.Dropped := True;
  FDeviceMenu.PopupBelow(FTransport.BtnDevice, True);
  FTransport.BtnDevice.Dropped := False;
end;

procedure TMainForm.DevicePick(Sender: TObject);
var
  S: string;
  Api: Integer;
begin
  S := FDeviceIds[TAuMenuItem(Sender).Tag];
  Api := StrToIntDef(Copy(S, 1, 1), 0);
  Delete(S, 1, 2);
  if (Api = AppSettings.Data.OutputApi) and
     SameText(S, AppSettings.Data.Audio.DeviceID) then Exit;
  AppSettings.Data.OutputApi := Api;
  if Api = 1 then AppSettings.Data.AsioDriverID := S else AppSettings.Data.WasapiDeviceID := S;
  UpdateManagerConfig;
  UpdateDeviceButton;
  if Api = 1 then AddLog('[Output] ASIO driver: ' + CurrentDeviceName)
  else AddLog('[Output] WASAPI device: ' + CurrentDeviceName);
  if FPlayback.State <> psStopped then
  begin
    FPlayback.RestartCurrent;
    FRateShown := False;
  end;
end;

{ ---- the output rate (resampling target) from the banner ---- }

procedure TMainForm.BannerRate(Sender: TObject; ScreenPt: TPoint);
var
  It: TAuMenuItem;
  Base, I, DsdRate: Integer;
  Rates: TRateArray;
  Is44: Boolean;
  A: TManagerConfig;
begin
  if FPlayingPath = '' then Exit;
  A := AppSettings.Data.Audio;
  FRateMenu.Free;
  FRateMenu := TAuMenu.Create;
  if FIsCurrentDoP or (FIsCurrentDsdToPcm and A.DisableResampleForDSD) then
  begin
    if FCurrentMeta.SampleRate > 0 then DsdRate := DsdMultiple(FCurrentMeta.SampleRate) else DsdRate := 64;
    if FIsCurrentDoP then It := FRateMenu.Add(SafeFormat(FMT_MENU_DSD_DOP, [DsdRate]), nil, icWave)
    else It := FRateMenu.Add(SafeFormat(FMT_MENU_DSD_PCM, [DsdRate]), nil, icWave);
    It.Enabled := False;
    FRateMenu.Popup(ScreenPt.X, ScreenPt.Y);
    Exit;
  end;
  Base := SampleRateFamily(FCurrentMeta.SampleRate);
  Is44 := Base = RATE_FAMILY_44K;
  It := FRateMenu.Add(LBL_MENU_NATIVE_RATE, @RatePick);
  It.Tag := 0;
  It.Checked := not A.ResamplePCM;
  FRateMenu.AddSeparator;
  Rates := TargetRateChoices(Base);
  for I := 0 to High(Rates) do
  begin
    if Rates[I] mod 1000 > 0 then It := FRateMenu.Add(SafeFormat(FMT_RATE_KHZ_DEC, [Rates[I] / 1000.0]), @RatePick)
    else It := FRateMenu.Add(SafeFormat(FMT_RATE_KHZ_INT, [Rates[I] div 1000]), @RatePick);
    It.Tag := Rates[I];
    if A.ResamplePCM then
      It.Checked := (Is44 and (A.TargetSampleRate44 = Rates[I])) or ((not Is44) and (A.TargetSampleRate48 = Rates[I]));
  end;
  FRateMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

procedure TMainForm.RatePick(Sender: TObject);
var
  R: Integer;
begin
  R := TAuMenuItem(Sender).Tag;
  if R = 0 then AppSettings.Data.Audio.ResamplePCM := False
  else
  begin
    AppSettings.Data.Audio.ResamplePCM := True;
    if SampleRateFamily(R) = RATE_FAMILY_44K then AppSettings.Data.Audio.TargetSampleRate44 := R
    else AppSettings.Data.Audio.TargetSampleRate48 := R;
  end;
  UpdateManagerConfig;
  if FPlayback.State <> psStopped then
  begin
    FPlayback.RestartCurrent;
    FRateShown := False;
  end;
end;

{ ---- volume ---- }

function TMainForm.IsVolumeLocked: Boolean;
begin
  Result := AppSettings.Data.Audio.VolumeLocked or FIsCurrentDoP;
end;

procedure TMainForm.UpdateVolumeUI;
var
  V: Integer;
begin
  V := AppSettings.Data.Volume;
  if FPlayback <> nil then
  begin
    if IsVolumeLocked then FPlayback.SetVolume(1000)
    else if AppSettings.Data.Muted then FPlayback.SetVolume(0)
    else FPlayback.SetVolume(V);
  end;
  FTransport.SetVolumeDisplay(V / 1000, AppSettings.Data.Muted and not IsVolumeLocked, IsVolumeLocked);
end;

procedure TMainForm.ChangeVolume(Delta: Integer);
begin
  if IsVolumeLocked then Exit;
  AppSettings.Data.Volume := EnsureRange(AppSettings.Data.Volume + Delta, 0, 1000);
  AppSettings.Data.Muted := False;
  UpdateVolumeUI;
end;

procedure TMainForm.ToggleMute;
begin
  if IsVolumeLocked then Exit;
  AppSettings.Data.Muted := not AppSettings.Data.Muted;
  UpdateVolumeUI;
end;

procedure TMainForm.VolumeClick(Sender: TObject);
var
  Txt: string;
begin
  { ---> AulumicNS: a popup frees itself when it closes (TAuPopup: caFree);
    VolumePopupClosed forgets it then. Before, FVolPopup kept pointing at
    the freed popup and the next click used it: an access violation as soon
    as its memory had been reused (seen on the NUC, 2026-11-11). }
  if FVolPopup = nil then
  begin
    FVolPopup := TVolumePopup.CreateVolume(Self);
    FVolPopup.OnVolume := @VolumeChanged;
    FVolPopup.OnMute := @VolumeMuted;
    FVolPopup.OnClosed := @VolumePopupClosed;
  end;
  if FIsCurrentDoP then Txt := 'DSD is sent as DSD: the volume is fixed at 100 %.'
  else Txt := 'Locked to 100 % (Preferences > Volume): bit-perfect.';
  FVolPopup.Setup(AppSettings.Data.Volume / 1000, AppSettings.Data.Muted, IsVolumeLocked, Txt);
  FVolPopup.ShowNear(FTransport.BtnVolume);
end;

procedure TMainForm.VolumePopupClosed(Sender: TObject);
begin
  if FVolPopup = Sender then FVolPopup := nil;
end;

procedure TMainForm.VolumeChanged(Sender: TObject; AVolume: Double);
begin
  AppSettings.Data.Volume := EnsureRange(Round(AVolume * 1000), 0, 1000);
  UpdateVolumeUI;
end;

procedure TMainForm.VolumeMuted(Sender: TObject);
begin
  ToggleMute;
end;

{ ---- tone control ---- }

procedure TMainForm.UpdateToneButton;
var
  A: TManagerConfig;
begin
  A := AppSettings.Data.Audio;
  { ---> AulumicNS: not lit while DSD goes out as DSD (it does not apply), and
    the Tone Control window follows (Aulumic: SetDSDMode) }
  FTransport.BtnTone.Active := (not A.ToneDirect) and (not FIsCurrentDoP) and
    ((A.ToneBassDB <> 0) or (A.ToneLowMidDB <> 0) or (A.ToneMidDB <> 0) or (A.ToneHighMidDB <> 0) or
     (A.ToneTrebleDB <> 0));
  if FTone <> nil then FTone.SetDsdNote(FIsCurrentDoP);
  UpdateToneHeadroom;
end;

{ ---> AulumicNS: the Tone Control shows what the automatic headroom takes off
  at the moment (a boost raises the peaks, so the level comes down): from the
  play thread's snapshot, four times a second while the window is open }
procedure TMainForm.UpdateToneHeadroom;
var
  Si: TSignalInfo;
  Db: Double;
begin
  if (FTone = nil) or not FTone.Visible then Exit;
  Db := 0.0;
  if (FPlayback <> nil) and (FPlayback.State <> psStopped) then
  begin
    Si := FPlayback.GetSignalInfo;
    if Si.Valid and Si.HeadroomOn and not (Si.DoP or Si.NativeDsd) then Db := Si.HeadroomDB;
  end;
  FTone.SetHeadroom(Db);
end;

procedure TMainForm.ShowTone;
var
  T: TToneState;
  A: TManagerConfig;
  Si: TSignalInfo;
begin
  if FTone = nil then
  begin
    FTone := TAuToneForm.CreateTone(Self);
    FTone.OnChange := @ToneChanged;
    if AppSettings.Data.ToneWinLeft <> VAL_UNINITIALIZED_POS then
    begin
      FTone.Position := poDesigned;
      FTone.Left := AppSettings.Data.ToneWinLeft;
      FTone.Top := AppSettings.Data.ToneWinTop;
    end;
  end;
  if FTone.Visible then
  begin
    FTone.Hide;
    Exit;
  end;
  A := AppSettings.Data.Audio;
  T.DirectMode := A.ToneDirect;
  T.BassDB := A.ToneBassDB;
  T.LowMidDB := A.ToneLowMidDB;
  T.MidDB := A.ToneMidDB;
  T.HighMidDB := A.ToneHighMidDB;
  T.TrebleDB := A.ToneTrebleDB;
  T.BassHz := A.ToneBassHz;
  T.LowMidHz := A.ToneLowMidHz;
  T.MidHz := A.ToneMidHz;
  T.HighMidHz := A.ToneHighMidHz;
  T.TrebleHz := A.ToneTrebleHz;
  FTone.SetValues(T);
  FTone.SetDsdNote(FIsCurrentDoP);
  Si := FPlayback.GetSignalInfo;
  if Si.Valid and (Si.OutRate > 0) and (FPlayback.State <> psStopped) and not (Si.DoP or Si.NativeDsd) then
    FTone.SetCurveRate(Si.OutRate);
  FTone.Show;
  UpdateToneHeadroom;
end;

procedure TMainForm.ToneChanged(Sender: TObject);
var
  T: TToneState;
begin
  T := FTone.Values;
  AppSettings.Data.Audio.ToneDirect := T.DirectMode;
  AppSettings.Data.Audio.ToneBassDB := T.BassDB;
  AppSettings.Data.Audio.ToneLowMidDB := T.LowMidDB;
  AppSettings.Data.Audio.ToneMidDB := T.MidDB;
  AppSettings.Data.Audio.ToneHighMidDB := T.HighMidDB;
  AppSettings.Data.Audio.ToneTrebleDB := T.TrebleDB;
  AppSettings.Data.Audio.ToneBassHz := T.BassHz;
  AppSettings.Data.Audio.ToneLowMidHz := T.LowMidHz;
  AppSettings.Data.Audio.ToneMidHz := T.MidHz;
  AppSettings.Data.Audio.ToneHighMidHz := T.HighMidHz;
  AppSettings.Data.Audio.ToneTrebleHz := T.TrebleHz;
  if FPlayback <> nil then
  begin
    FPlayback.SetToneControl(T);
    FPlayback.Config := AppSettings.Data.Audio;
  end;
  UpdateToneButton;
end;

{ ---- shuffle / repeat ---- }

procedure TMainForm.UpdateModeButtons;
begin
  if FPlayback = nil then Exit;
  case FPlayback.ShuffleMode of
    smTrack: begin FTransport.BtnShuffle.Active := True; FTransport.BtnShuffle.ShowDot := False; FTransport.BtnShuffle.Hint := HINT_SHUFFLE_TRACKS; end;
    smAlbum: begin FTransport.BtnShuffle.Active := True; FTransport.BtnShuffle.ShowDot := True; FTransport.BtnShuffle.Hint := HINT_SHUFFLE_ALBUMS; end;
  else
    begin FTransport.BtnShuffle.Active := False; FTransport.BtnShuffle.ShowDot := False; FTransport.BtnShuffle.Hint := HINT_SHUFFLE_OFF; end;
  end;
  FTransport.BtnShuffle.Invalidate;
  case FPlayback.RepeatMode of
    rmAll: FTransport.SetRepeatMode(1);
    rmOne: FTransport.SetRepeatMode(2);
  else
    FTransport.SetRepeatMode(0);
  end;
  case FPlayback.RepeatMode of
    rmAll: FTransport.BtnRepeat.Hint := HINT_REPEAT_ALL;
    rmOne: FTransport.BtnRepeat.Hint := HINT_REPEAT_TRACK;
  else
    FTransport.BtnRepeat.Hint := HINT_REPEAT_OFF;
  end;
end;

{ ---- the manager's events ---- }

procedure TMainForm.ManagerTrackChange(const Item: TQueueItem; const Meta: TAudioMetadata);
begin
  { the track before counts as played (30 s or half of it, Aulumic) }
  CommitPlay;
  FCurrentMeta := Meta;
  FPlayingPath := Item.FilePath;
  FPlayingId := Item.TrackId;
  if FCurrentMeta.Title = '' then FCurrentMeta.Title := ChangeFileExt(ExtractFileName(Item.FilePath), '');
  FCurrentMeta.Artist := NormalizeSemicolons(FCurrentMeta.Artist);
  if FCurrentMeta.Artist = '' then FCurrentMeta.Artist := LBL_UNKNOWN_ARTIST;
  FCurrentMeta.AlbumArtist := NormalizeSemicolons(FCurrentMeta.AlbumArtist);
  if FCurrentMeta.AlbumArtist = '' then FCurrentMeta.AlbumArtist := FCurrentMeta.Artist;
  if FCurrentMeta.Album = '' then FCurrentMeta.Album := LBL_UNKNOWN_ALBUM;
  FIsCurrentDsd := IsDSDFile(Item.FilePath);
  FIsCurrentDoP := FIsCurrentDsd and AppSettings.Data.Audio.UseDoP;
  FIsCurrentDsdToPcm := FIsCurrentDsd and not AppSettings.Data.Audio.UseDoP;
  FTrackTick := GetTickCount64;
  FPl.PlayingEntry := FPl.IndexOfId(Item.TrackId);
  { ---> AulumicNS (the user, 2026-11-17; Aulumic: FocusLastPlayedTrack at
    every track change): the selection goes with the track, and the track
    comes into view - only in the playlist that plays, and only when
    "Cursor follows playback" is on (Preferences > Playlists) }
  if AppSettings.Data.CursorFollowsPlayback and SameText(FShownPl, FPlayingPl) and
     (FPl.PlayingEntry >= 0) then
    FPl.FollowEntry(FPl.PlayingEntry);
  FRateShown := False;
  FScrobblePath := FPlayingPath;
  FScrobbleMeta := FCurrentMeta;
  Caption := StringReplace(FORMAT_MAIN_CAPTION, '%title%', FCurrentMeta.Title, []);
  UpdateBanner;
  UpdateRateLine;
  UpdateVolumeUI;
  UpdateToneButton;
end;

procedure TMainForm.ManagerTrackInfoRefreshed(const Item: TQueueItem; const Meta: TAudioMetadata);
begin
  if (FPlayingPath = '') or not SameText(Item.FilePath, FPlayingPath) then Exit;
  FCurrentMeta := Meta;
  if FCurrentMeta.Title = '' then FCurrentMeta.Title := ChangeFileExt(ExtractFileName(FPlayingPath), '');
  UpdateBanner;
end;

procedure TMainForm.ManagerStateChange(NewState: TPlaybackState);
begin
  if FShuttingDown or (FPlayback = nil) then Exit;
  case NewState of
    psPlaying: FTransport.SetPlaying(True);
    psPaused: FTransport.SetPlaying(False);
    psStopped:
      begin
        if not FPlayback.IsOpening then EndOpeningUI(False);
        FTransport.SetPlaying(False);
        CommitPlay;
        FPlayingPath := '';
        FPlayingId := 0;
        FCurrentMeta := Default(TAudioMetadata);
        FIsCurrentDsd := False;
        FIsCurrentDoP := False;
        FIsCurrentDsdToPcm := False;
        UpdateToneButton;
        FPl.PlayingEntry := -1;
        FStatus.EngineText := '';
        Caption := AppTitle;
        FRateShown := False;
        UpdateBanner;
        UpdateRateLine;
        UpdateVolumeUI;
        UpdatePosition;
      end;
  end;
  UpdateTimerPace;
end;

procedure TMainForm.ManagerModeChange(RepeatMode: TRepeatMode; ShuffleMode: TShuffleMode);
begin
  AppSettings.Data.ShuffleMode := Ord(ShuffleMode);
  AppSettings.Data.RepeatMode := Ord(RepeatMode);
  UpdateModeButtons;
end;

procedure TMainForm.ManagerBackgroundRequest(Sender: TObject);
begin
  if (FPlayback <> nil) and FPlayback.IsOpening then
  begin
    if (FOpeningSince = 0) or not SameText(FOpeningFile, FPlayback.OpeningFilePath) then
    begin
      FOpeningSince := GetTickCount64;
      FOpeningFile := FPlayback.OpeningFilePath;
    end;
    FRateShown := False;
    UpdateBannerNotice;
  end;
  UpdateTimerPace;
end;

{ the DAC refused the sample rate: offer to resample (as Aulumic's sample
  rate fallback dialog) }
procedure TMainForm.ManagerSampleRateError(AttemptedRate: Integer; AIsDSD: Boolean);
var
  F: TAuForm;
  L: TAuLabel;
  Cb: TAuCombo;
  B1, B2: TAuButton;
  Rates: TRateArray;
  Pick: array of Integer;
  I, Chosen: Integer;
  IsDoP, IsDsdToPcm: Boolean;
begin
  EndOpeningUI(False);
  AddLog(SafeFormat(FMT_LOG_FALLBACK_REFUSED, [FormatRateKHz(AttemptedRate)]));
  IsDoP := AIsDSD and AppSettings.Data.Audio.UseDoP;
  IsDsdToPcm := AIsDSD and not AppSettings.Data.Audio.UseDoP;
  if IsDoP or (IsDsdToPcm and AppSettings.Data.Audio.DisableResampleForDSD) then
  begin
    if IsDoP then
      ALMessageDlg(TITLE_PLAYBACK_ERROR, SafeFormat('Your DAC does not accept %s as DoP.' + LineEnding + LineEnding +
        'Turn off "Play DSD natively" in Preferences > DSD to convert DSD to PCM.',
        [FormatRateKHz(AttemptedRate)]), mkError)
    else
      ALMessageDlg(TITLE_PLAYBACK_ERROR, SafeFormat('Your DAC does not support %s.', [FormatRateKHz(AttemptedRate)]), mkError);
    Exit;
  end;
  Rates := TargetRateChoices(SampleRateFamily(AttemptedRate));
  Pick := nil;
  for I := 0 to High(Rates) do
    if Rates[I] <> AttemptedRate then
    begin
      SetLength(Pick, Length(Pick) + 1);
      Pick[High(Pick)] := Rates[I];
    end;
  if Length(Pick) = 0 then Exit;
  F := TAuForm.CreateAu(Self, 'Sample rate not supported', 480, 210);
  try
    L := F.AddLabel(F, SafeFormat('Your DAC does not support %s.' + LineEnding +
      'Play it resampled to another rate? (Preferences > Resampler keeps this choice.)',
      [FormatRateKHz(AttemptedRate)]), 24, 20, 432, False);
    L.Height := S(60);
    L.WordWrap := True;
    L.VAlign := 0;
    Cb := F.AddCombo(F, 24, 92, 220, []);
    for I := 0 to High(Pick) do Cb.Items.Add(FormatRateKHz(Pick[I]));
    { the highest rate below the refused one }
    Cb.ItemIndex := 0;
    for I := 0 to High(Pick) do
      if Pick[I] < AttemptedRate then Cb.ItemIndex := I;
    B2 := F.AddButton(F, 'Cancel', 252, 154, 100);
    B2.ModalResult := mrCancel;
    B1 := F.AddButton(F, 'Resample', 360, 154, 100, bkPrimary);
    B1.ModalResult := mrOK;
    F.DefaultButton := B1;
    F.ActiveControl := Cb;
    if F.ShowModal <> mrOK then
    begin
      AddLog(LOG_FALLBACK_CANCELLED);
      Exit;
    end;
    Chosen := Pick[EnsureRange(Cb.ItemIndex, 0, High(Pick))];
  finally
    F.Free;
  end;
  AppSettings.Data.Audio.ResamplePCM := True;
  if SampleRateFamily(Chosen) = RATE_FAMILY_44K then AppSettings.Data.Audio.TargetSampleRate44 := Chosen
  else AppSettings.Data.Audio.TargetSampleRate48 := Chosen;
  AddLog(SafeFormat(FMT_LOG_FALLBACK_RESAMPLE, [FormatRateKHz(Chosen)]));
  UpdateManagerConfig;
  FPlayback.RetryCurrent;
end;

{ ---- transport ---- }

procedure TMainForm.PlayPause;
var
  E: Integer;
begin
  if FPlayback = nil then Exit;
  case FPlayback.State of
    psPaused: FPlayback.Resume;
    psPlaying: FPlayback.Pause;
  else
    begin
      E := FPl.EntryOfRow(FPl.List.FocusedRow);
      if E < 0 then E := 0;
      if E < FPl.EntryCount then PlayEntry(E);
    end;
  end;
end;

procedure TMainForm.StopPlayback;
begin
  if FPlayback <> nil then FPlayback.Stop;
end;

procedure TMainForm.NextTrack;
begin
  if FPlayback = nil then Exit;
  Screen.Cursor := crHourGlass;
  try
    FPlayback.PlayNext(True);
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TMainForm.PrevTrack;
begin
  if FPlayback = nil then Exit;
  Screen.Cursor := crHourGlass;
  try
    FPlayback.PlayPrev;
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TMainForm.SeekBy(Seconds: Double);
var
  Dur: Double;
begin
  if (FPlayback = nil) or not (FPlayback.State in [psPlaying, psPaused]) then Exit;
  Dur := FPlayback.GetDuration;
  if Dur <= 0 then Exit;
  FPlayback.Seek(EnsureRange(FPlayback.GetProgress + Seconds / Dur, 0, 0.999));
end;

procedure TMainForm.SeekChange(Sender: TObject);
var
  Dur: Double;
begin
  { while dragging: the time under the thumb }
  if (FPlayback = nil) or not FTransport.Seek.Dragging then Exit;
  Dur := FPlayback.GetDuration;
  if Dur > 0 then FTransport.LblPos.Caption := FormatDuration(Trunc(FTransport.Seek.Position * Dur));
end;

procedure TMainForm.SeekEnd(Sender: TObject);
begin
  if (FPlayback = nil) or not (FPlayback.State in [psPlaying, psPaused]) then Exit;
  FPlayback.Seek(EnsureRange(FTransport.Seek.Position, 0, 0.999));
  FLastPlaySec := -2;
end;
