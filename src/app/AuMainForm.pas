unit AuMainForm;

{ ==============================================================================
  AulumicNS - AuMainForm
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The main window of AulumicNS - the layout of Aulumic, built with the
  AulumicNS GUI library (no .lfm, no VirtualTreeView, vector icons, own
  title bar):

    +------------------------------------------------------------------+
    | title bar (main menu, caption, Preferences)                       |
    | Now Playing banner (cover, texts, source info, peak meter)        |
    +------------------------- splitter -------------------------------+
    | search  [rescan] | playlist selector  [View] [Edit]               |
    | library tree     | playlist (grouped by album)                    |
    +------------------------------------------------------------------+
    | position bar / transport buttons / device, tone, volume           |
    | status line                                                       |
    +------------------------------------------------------------------+

  Split like Aulumic's main window: this unit builds the window, the menus,
  the theme and the keys; AuMainForm_playback.inc drives the engine (the UI
  timer, the banner, the transport, device / rate / volume / tone);
  AuMainForm_files.inc adds files and keeps the play list in sync with the
  play queue; AuMainForm_library.inc is the library's side (scans, the
  tree's actions, the folder watcher, play counts); AuMainForm_playlist.inc
  the playlists (the selector, the View menu, drag and drop, M3U);
  AuMainForm_dialogs.inc Properties, the tag writer and the ReplayGain scan.

  The engine is Aulumic's with the built-in decoders and resampler, over
  WASAPI and ASIO; the library is Aulumic's library manager, stored in the
  Aulos format; the playlists are in uPlaylistStore.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType, LMessages, Dialogs,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls, AuMenus, AuForms, AuExtra, AuTree, AuGroupList,
  AuAppIcon, AuTitleBar, AuSingle, AuSettings, AuBanner, AuTransport, AuLibraryPane, AuPlaylistPane,
  AuToneForm, AuVolumePopup, AuLog, AuDialogs, AuPrefs, AuPlaylistManager, AuPlaylistEditor,
  ALAudioTypes, ALMetadata, uAppConsts, uAppStrings, uSettingsManager, uPlaybackManager,
  uAudioUtils, uMetaUtils, uOSUtils, uLibraryTypes, uLibraryManager, uUserStatsManager,
  uLibraryWatcher, uEngineStateManager, uPlaylistStore, uPlaylistFile, uPlaylistRows,
  uPlaylistImport, uAutoPlaylist, uMetadataCustodian, AuTagLoader, AuPropertiesForm, AuReplayGainForm, AuVirtualFolderForm,
  AuSignalPath, uCrashTracer, AuResample{$IFDEF DEBUG}, AuTouchProbe{$ENDIF};

type
  { TMainForm }

  TMainForm = class(TAuForm)
  private
    FBanner: TNowPlayingBanner;
    FTopSplit, FMainSplit: TAuSplitter;
    FLibWanted: Integer;              // the library pane's width as the user set it (unscaled)
    FMid: TAuPanel;
    FLib: TLibraryPane;
    FPl: TPlaylistPane;
    FTransport: TTransportBar;
    FStatus: TStatusStrip;
    FToast: TAuToast;
    FMainMenu, FPlaylistMenu, FViewMenu, FDeviceMenu, FRateMenu, FArtistMenu, FThemeMenu: TAuMenu;
    FCtxMenu: TAuMenu;           // the last context menu (kept until its item ran)
    FIconBig, FIconSmall: HICON;
    FTone: TAuToneForm;
    FVolPopup: TVolumePopup;
    FShuttingDown: Boolean;
    { playback }
    FPlayback: TPlaybackManager;
    FUiTimer: TTimer;
    FPlayingPath: string;
    FPlayingId: Integer;
    FCurrentMeta: TAudioMetadata;
    FOverflowArtists: TStringArray;   // the banner's "more artists" menu
    FCoverEntry: TPlEntry;            // the playlist header whose cover was clicked
    FSigDevice: string;               // the device name of the open signal path
    FIsCurrentDsd, FIsCurrentDoP, FIsCurrentDsdToPcm: Boolean;
    FTrackTick: QWord;           // when the playing track changed (UpdateRateLine: a stale signal path)
    FKeyTick: QWord;             // the last look at the signal path between the status updates
    FOpeningSince: QWord;
    FOpeningFile: string;
    FStallSince: QWord;
    FStallProgress: Double;
    FStallShown: Boolean;
    FLastStatusTick: QWord;
    FLastPlaySec: Integer;
    FLastBitPerfect: Boolean;
    FRateShown: Boolean;
    FRateKey: string;             // ---> AulumicNS: what the rate line shows (SignalKey)
    FMeterSlices: array[0..METER_RING_SIZE - 1] of TMeterSlice;
    FMeterFifo: array of TMeterSlice;
    FMeterFifoLen: Integer;
    FMeterEpochSeen: Integer;
    { ---> AulumicNS: the slices shown at the pace of real time (Aulumic's
      TPeakMeterState.ProcessMeterSlices) }
    FMeterLastTick: QWord;
    FMeterAccMs: Double;
    FMeterNoDataMs: Integer;
    FMeterLastL, FMeterLastR: Single;
    FCpuText: string;
    FCpuTick: QWord;
    { library (milestone 3) }
    FLibrary: TLibraryManager;
    FWatcher: TLibraryWatcher;
    FWatchMuteUntil: QWord;      // the watcher's changes are the program's own writes until then
    FCtxNode: TAuTreeNode;       // the node of the library context menu
    FStartupScanDone: Boolean;
    FActivePlaySeconds: Double;  // play counting (Aulumic's scrobble)
    FIsScrobbled: Boolean;
    FScrobblePath: string;
    FScrobbleMeta: TAudioMetadata;
    FPlayCountTick: QWord;
    { playlists (milestone 4) }
    FPlaylists: TPlaylistStore;
    FShownPl: string;            // the playlist on screen
    FPlayingPl: string;          // the playlist the play queue was made from
    FBusyDepth: Integer;         // BeginBusy / EndBusy
    // ---> AulumicNS: ShowPlaylist is filling the pane (PlChanged leaves the
    // queue alone: an auto-playlist is cleared first, and syncing the queue of
    // the playing playlist with that empty list stopped the playback)
    FLoadingPl: Boolean;
    FInExceptionDialog: Boolean; // AppException shows one dialog at a time
    FPlSaveDue: QWord;           // when the shown playlist's changes are stored
    FDropAt: Integer;            // an Explorer drop over the playlist: insert here (-1 none)
    FMenuPlNames, FAddToNames: TStringList;   // the playlists of the open menus (Tag = index)
    FDeviceIds: TStringList;     // "api|id" of the device menu items (Tag = index)
    { tools (milestone 5) }
    FCustodian: TMetadataCustodian;   // writes tags and ReplayGain in the background
    {$IF DEFINED(DEBUG) or DEFINED(MEMTEST)}
    FMemTest: string;            // --test-repair=<report>: memory around a repair
    FMemStep: Integer;
    FMemStart: QWord;
    {$ENDIF}
    {$IFDEF DEBUG}
    FShotDir: string;
    FShotStep: Integer;
    FShotTimer: TTimer;
    FDebugScan: Boolean;         // --add-folder: scan at start
    FShotWait: Integer;
    FShotForm: TAuForm;          // the dialog of a dialog screenshot
    FShotName: string;
    FShotStore: TPlaylistStore;  // playlists for the Playlist Manager screenshot
    FTouchReport: string;        // --touch-probe=<report> (AuTouchProbe, Tools\ProbeTouch.ps1)
    { --ui-bench=<report> [--ui-bench-nometer]: the screen of 15 s of playback
      (seek bar, time, meter at the 50 ms pace), the process CPU measured }
    FUiBenchFile: string;
    FUiBenchTimer: TTimer;
    FUiBenchTick, FUiBenchT0, FUiBenchCpu0, FUiBenchUi0, FUiBenchOther0, FUiBenchKernel0: QWord;
    FUiBenchN: Integer;
    { --test-drive-wait=<report>: waits for a made-up slow drive, see
      DriveWaitTestAsync }
    FWaitTestFile: string;
    FWaitTestTimer: TTimer;
    FWaitTestStep, FWaitTestTicks: Integer;
    FWaitTestBusy, FWaitTestPopup: Boolean;
    procedure DriveWaitTestAsync(Data: PtrInt);
    procedure DriveWaitTestTick(Sender: TObject);
    procedure TouchProbeAsync(Data: PtrInt);
    procedure UiBenchAsync(Data: PtrInt);
    procedure UiBenchTimer(Sender: TObject);
    procedure ShotTick(Sender: TObject);
    function ShotDialog(AIndex: Integer; out AName: string): TAuForm;
    procedure CaptureWindow(const AName: string);
    {$ENDIF}
    procedure BuildUI;
    procedure BuildMenus;
    procedure SetAppIcon;
    procedure ApplyWindowSettings;
    procedure SaveWindowSettings;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    function ConfirmCloseWhileBusy: Boolean;
    // ---> AulumicNS: Windows is shutting down, restarting or logging off
    // (Aulumic's AppQueryEndSession / AppEndSession): everything is saved
    // when Windows asks; when the session really ends, the close runs
    procedure AppQueryEndSession(var Cancel: Boolean);
    procedure AppEndSession(Sender: TObject);
    procedure TerminateAfterEndSession(Data: PtrInt);
    procedure SaveForSessionEnd;
    // ---> AulumicNS: the hang watchdog (uHangWatch), once the message loop runs
    procedure StartWatchAsync(Data: PtrInt);
    // ---> AulumicNS: Aulumic's handler for exceptions that escape an event
    // handler (was not wired up: an access violation showed the plain LCL
    // message and left no trace)
    procedure AppException(Sender: TObject; E: Exception);
    procedure ShowPrefsPage(APage: Integer);
    { theme }
    procedure SetThemeMode(M: TAuThemeMode);
    procedure SetAccent(A: Integer);
    { ---- AuMainForm_playback.inc ---- }
    procedure InitPlayback;
    procedure UpdateManagerConfig;
    procedure UiTimerTick(Sender: TObject);
    procedure UpdateTimerPace;
    procedure UpdatePosition;
    procedure UpdateMeter;
    procedure UpdateEngineStatus;
    procedure CheckOpeningUI;
    procedure CheckStallUI;
    procedure EndOpeningUI(ADone: Boolean);
    procedure EndStallUI(ALog: Boolean);
    procedure UpdateBannerNotice;
    procedure UpdateBanner;
    procedure UpdateRateLine;
    procedure UpdateDeviceButton;
    procedure UpdateVolumeUI;
    procedure UpdateToneButton;
    procedure UpdateToneHeadroom;
    procedure UpdateModeButtons;
    function IsVolumeLocked: Boolean;
    function CurrentDeviceName: string;
    procedure ManagerTrackChange(const Item: TQueueItem; const Meta: TAudioMetadata);
    procedure ManagerTrackInfoRefreshed(const Item: TQueueItem; const Meta: TAudioMetadata);
    procedure ManagerStateChange(NewState: TPlaybackState);
    procedure ManagerModeChange(RepeatMode: TRepeatMode; ShuffleMode: TShuffleMode);
    procedure ManagerSampleRateError(AttemptedRate: Integer; AIsDSD: Boolean);
    procedure ManagerBackgroundRequest(Sender: TObject);
    procedure PlayPause;
    procedure StopPlayback;
    procedure NextTrack;
    procedure PrevTrack;
    procedure SeekBy(Seconds: Double);
    procedure ChangeVolume(Delta: Integer);
    procedure ToggleMute;
    procedure ShowTone;
    procedure ToneChanged(Sender: TObject);
    procedure VolumeChanged(Sender: TObject; AVolume: Double);
    procedure VolumeMuted(Sender: TObject);
    procedure VolumePopupClosed(Sender: TObject);
    procedure DevicePick(Sender: TObject);
    procedure RatePick(Sender: TObject);
    { ---- AuMainForm_files.inc ---- }
    procedure CollectMusicFiles(const APath: string; AList: TStrings);
    procedure AddPaths(const Paths: array of string; PlayNow, Replace: Boolean);
    procedure PlayEntry(E: Integer);
    procedure SyncQueueWithList(AKeepPlaying: Boolean = False);
    procedure RemoveSelected;
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure CheckIncoming;
    procedure JumpToNowPlaying;
    { ---- AuMainForm_playlist.inc ---- }
    procedure InitPlaylists;
    procedure FreePlaylists;
    function ShownPlaylist: PStoredPlaylist;
    procedure ShowPlaylist(const AName: string; AForce: Boolean = False);
    procedure ApplyView(P: PStoredPlaylist; const ADateSuffix: string);
    function PlGroupMode(P: PStoredPlaylist): TGroupingMode;
    procedure SaveShownPlaylist(ANow: Boolean);
    procedure CheckPlaylistSave;
    procedure PlChanged(Sender: TObject);
    procedure PlCollapseChanged(Sender: TObject);
    procedure PlRatingChanged(Sender: TObject);
    function AskPlaylistName(const ATitle: string; var AName: string): Boolean;
    procedure ViewChanged;
    procedure BeginBusy;
    procedure EndBusy;
    procedure MnViewGroup(Sender: TObject);
    procedure MnViewHeader(Sender: TObject);
    procedure MnViewTrack(Sender: TObject);
    procedure AddToPlaylistMenu(AMenu: TAuMenu; AClick: TNotifyEvent);
    function AddToTarget(Sender: TObject): string;
    procedure AddTracksToPlaylist(const AName: string; ATracks: TTrackList);
    procedure SelectedPlTracks(AList: TTrackList);
    procedure MnPlAddTo(Sender: TObject);
    procedure MnLibAddTo(Sender: TObject);
    procedure MnPlRate(Sender: TObject);
    procedure RateSelection(ARating: Integer);
    procedure MnPlExpandAll(Sender: TObject);
    procedure MnPlCollapseAll(Sender: TObject);
    procedure MnRemoveDead(Sender: TObject);
    procedure PlDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState; var Accept: Boolean);
    procedure PlDragDrop(Sender, Source: TObject; X, Y: Integer);
    procedure PlEndDrag(Sender, Target: TObject; X, Y: Integer);
    function PlaylistDropIndex(const AScreenPt: TPoint; out AIndex: Integer): Boolean;
    procedure MnImportM3U(Sender: TObject);
    procedure MnExportM3U(Sender: TObject);
    function ImportM3UFile(const AFile: string; out AError: string): string;
    function ExportPlaylistM3U(const AName, AFile: string; out AError: string): Boolean;
    { ---- AuMainForm_library.inc ---- }
    procedure InitLibrary;
    procedure FreeLibrary;
    function LibLookup(const APath: string; out ATrack: TTrackInfo): Boolean;
    procedure RequestLibraryScan(FullRebuild, SilentQueue: Boolean);
    procedure LibraryScanProgress(Sender: TObject; const ScanMsg: string;
      const CurrentFolder: string; TrackCount, TotalTracks: Integer);
    procedure LibraryScanDone(Sender: TObject; HasChanges: Boolean);
    {$IF DEFINED(DEBUG) or DEFINED(MEMTEST)}
    procedure MemTestNote(const AWhat: string);
    procedure MemTestLater(Data: PtrInt);
    {$ENDIF}
    procedure StateStatus(const AMsg: string; ProgressPct: Double);
    procedure StateClearThumbs;
    procedure RestartWatcher;
    procedure CheckWatcher;
    procedure LibPlay(const ANodes: TAuTreeNodeArray);
    procedure LibAdd(const ANodes: TAuTreeNodeArray; AReplace: Boolean);
    procedure MnLibPlay(Sender: TObject);
    procedure MnLibAdd(Sender: TObject);
    procedure MnLibSend(Sender: TObject);
    procedure MnLibToggle(Sender: TObject);
    procedure MnLibExpandAll(Sender: TObject);
    procedure MnLibCollapseAll(Sender: TObject);
    procedure MnLibOpenFolder(Sender: TObject);
    procedure MnVirtualFolder(Sender: TObject);
    procedure MnRemoveVirtualFolder(Sender: TObject);
    procedure MnLibraryFolders(Sender: TObject);
    { ---- AuMainForm_dialogs.inc ---- }
    procedure InitCustodian;
    procedure FreeCustodian;
    procedure BackgroundIOBatchFinished;
    procedure EditFileProperties(APaths: TStrings);
    procedure LibraryPaths(const ANodes: TAuTreeNodeArray; APaths: TStrings);
    procedure PlaylistPaths(APaths: TStrings);
    procedure MnLibProperties(Sender: TObject);
    procedure MnPlProperties(Sender: TObject);
    procedure PlCoverClick(Sender: TObject; AEntry: Integer);
    procedure ShowGroupCover(Data: PtrInt);
    procedure MnLibReplayGain(Sender: TObject);
    procedure MnPlReplayGain(Sender: TObject);
    procedure RgLabel(AValue: Boolean);
    procedure RgProgress(ACurrent, ATotal: Integer);
    function ApplyLibraryFolders(AFolders: TStrings): Boolean;
    procedure PrefsScan(AFolders: TStrings; FullRebuild: Boolean);
    procedure CountPlay(DeltaSec: Double);
    procedure CommitPlay;
    procedure SaveHeadroom;
    function TrackStatsFingerprint(const APath: string; const AMeta: TAudioMetadata): string;
    function TrackStats(const APath: string; const AMeta: TAudioMetadata): PUserTrackStats;
    { events }
    procedure TitleBack(Sender: TObject; G: TGfx);
    procedure TitleMenuClick(Sender: TObject);
    procedure TitlePrefsClick(Sender: TObject);
    procedure BannerCover(Sender: TObject);
    procedure BannerAlbum(Sender: TObject);
    procedure BannerArtist(Sender: TObject; const AName: string);
    procedure BannerMoreArtists(Sender: TObject; ScreenPt: TPoint);
    procedure BannerRate(Sender: TObject; ScreenPt: TPoint);
    procedure BannerBadge(Sender: TObject; ScreenPt: TPoint);
    procedure FillSignalPath(P: TAuSignalPath);
    procedure BannerHeart(Sender: TObject);
    procedure BannerBooklet(Sender: TObject);
    procedure TopSplitMoved(Sender: TObject);
    procedure MainSplitMoved(Sender: TObject);
    procedure MidResize(Sender: TObject);
    procedure LibTextSize(Sender: TObject);
    procedure PlTextSize(Sender: TObject);
    procedure TreeActivate(Sender: TObject; Node: TAuTreeNode; var Handled: Boolean);
    procedure TreeContext(Sender: TObject; Node: TAuTreeNode; ScreenPt: TPoint);
    procedure PlActivate(Sender: TObject; Row: Integer);
    procedure PlContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
    procedure PlKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PlaylistDrop(Sender: TObject);
    procedure PlaylistPick(Sender: TObject);
    procedure ViewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure RescanClick(Sender: TObject);
    procedure PlayClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure PrevClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure JumpClick(Sender: TObject);
    procedure ShuffleClick(Sender: TObject);
    procedure RepeatClick(Sender: TObject);
    procedure DeviceClick(Sender: TObject);
    procedure ToneClick(Sender: TObject);
    procedure VolumeClick(Sender: TObject);
    procedure SeekChange(Sender: TObject);
    procedure SeekEnd(Sender: TObject);
    procedure RgClick(Sender: TObject);
    { menu items }
    procedure MnAddFiles(Sender: TObject);
    procedure MnAddFolder(Sender: TObject);
    procedure MnSearch(Sender: TObject);
    procedure MnRefresh(Sender: TObject);
    procedure MnRescan(Sender: TObject);
    procedure MnPlaylistManager(Sender: TObject);
    procedure MnProperties(Sender: TObject);
    procedure MnReplayGain(Sender: TObject);
    procedure MnLog(Sender: TObject);
    procedure MnDebugQueue(Sender: TObject);
    procedure MnPrefs(Sender: TObject);
    procedure MnHelp(Sender: TObject);
    procedure MnAbout(Sender: TObject);
    procedure MnQuit(Sender: TObject);
    procedure MnThemeDark(Sender: TObject);
    procedure MnThemeLight(Sender: TObject);
    procedure MnThemeSystem(Sender: TObject);
    procedure MnAccent(Sender: TObject);
    procedure MnPlaySelected(Sender: TObject);
    procedure MnRemoveSelected(Sender: TObject);
    procedure MnClearList(Sender: TObject);
    procedure MnShowInExplorer(Sender: TObject);
    procedure RevealPath(const APath: string);
    procedure MnOverflowArtist(Sender: TObject);
    procedure MainMenuPopup(Sender: TObject);
  protected
    procedure CreateWnd; override;
    procedure WndProc(var Message: TLMessage); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure ThemeUpdated; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

uses
  AuAudioTypes, ALAudioEngine, AuFolderPicker, AuLogForm, AuDebugQueue, uSettingsLog,
  AuCoverViewer, AuArtistInfo, AuBooklet, AuHelp, uHangWatch, uDriveKeepAlive, ALHeadroom,
  AuAbout, uVersionHelper, uInputBlock;

{ Aulumic's list font sizes are 6 .. 20; the panes use pixels }
function PaneTextPx(FontSize: Integer): Single;
begin
  Result := FontSize + 2;
end;

{ ---> AulumicNS: the hang report's last log lines. Runs on the watchdog
  thread while the UI thread hangs (the log is only changed by the UI thread,
  which is stuck then); no lock that the UI thread might hold. }
function HangLogTail: string;
var
  L: TStringList;
  I, First: Integer;
begin
  Result := '';
  L := AppLog.Lines;
  First := L.Count - 40;
  if First < 0 then First := 0;
  for I := First to L.Count - 1 do
    Result := Result + '  ' + L[I] + LineEnding;
end;

{ ---> AulumicNS: Aulumic's AppException. Every exception that escapes an
  event handler goes to the log with its place and callers (module+$offset:
  look them up in the .dbg of the same build), the log is saved at once (the
  program may not get to close normally), and a themed message is shown -
  never during the close and never stacked (an error on every repaint). }
procedure TMainForm.AppException(Sender: TObject; E: Exception);
var
  Msg, ErrText: string;
begin
  try
    if Assigned(E) then
      Msg := SafeFormat(FMT_LOG_UNHANDLED_EXCEPTION, [E.ClassName, E.Message])
    else
      Msg := LOG_UNHANDLED_NO_OBJECT;
    Msg := Msg + SafeFormat(FMT_LOG_EXCEPTION_PLACE, [DescribeExceptionPlace(16)]);
    if Assigned(Sender) then
      Msg := Msg + SafeFormat(FMT_LOG_EXCEPTION_SENDER, [Sender.ClassName]);
    AddLog(Msg, True, True);
    SaveLog(True, True);
  except
    // logging must never raise from inside the exception handler
  end;
  if FShuttingDown or FInExceptionDialog or (not Assigned(E)) then Exit;
  ErrText := E.Message;
  if Trim(ErrText) = '' then ErrText := E.ClassName;
  FInExceptionDialog := True;
  try
    try
      ALMessageDlg(TITLE_ERROR, SafeFormat(FMT_ERR_UNEXPECTED, [ErrText]), [mbOK], mbOK, mkError);
    except
      try
        Application.ShowException(E);
      except
      end;
    end;
  finally
    FInExceptionDialog := False;
  end;
end;

procedure TMainForm.StartWatchAsync(Data: PtrInt);
begin
  if FShuttingDown then Exit;
  NameThisThread('UI');
  HangReportExtra := @HangLogTail;
  StartHangWatch(Handle);
  {$IFDEF DEBUG}
  { --test-hang=<s>: the window stops taking messages for <s> seconds (the
    hang report must be written, then "answered again") }
  if Application.HasOption('test-hang') then
    Sleep(1000 * EnsureRange(StrToIntDef(Application.GetOptionValue('test-hang'), 8), 1, 60));
  {$ENDIF}
end;

{$I AuMainForm_playback.inc}
{$I AuMainForm_files.inc}
{$I AuMainForm_library.inc}
{$I AuMainForm_playlist.inc}
{$I AuMainForm_dialogs.inc}

{ ---- creation ---- }

constructor TMainForm.Create(AOwner: TComponent);
var
  D: Integer;
begin
  { build the window for the DPI of the monitor it will open on (screenshot
    mode: the forced DPI of --shot-dpi) }
  if ForcedDpi > 0 then
    D := ForcedDpi
  else if (AppSettings.Data.WinLeft <> VAL_UNINITIALIZED_POS) and (AppSettings.Data.WinWidth > 0) then
    D := MonitorDpiAt(AppSettings.Data.WinLeft + AppSettings.Data.WinWidth div 2,
      AppSettings.Data.WinTop + AppSettings.Data.WinHeight div 2)
  else
    D := MonitorDpiAt(Screen.WorkAreaLeft + Screen.WorkAreaWidth div 2, Screen.WorkAreaTop + Screen.WorkAreaHeight div 2);
  CurDpi := D;
  FDeviceIds := TStringList.Create;
  FMenuPlNames := TStringList.Create;
  FDropAt := -1;
  FAddToNames := TStringList.Create;
  FLastPlaySec := -1;
  CreateNew(AOwner, 0);
  PixelsPerInch := D;
  Caption := AppTitle;
  { the library before the panes that show it }
  InitLibrary;
  { our own title bar, drawn in the theme (first: it is the topmost control);
    the debug build's --ui-bench-noframe leaves it out (a measurement) }
  {$IFDEF DEBUG}
  if not Application.HasOption('ui-bench-noframe') then
  {$ENDIF}
  begin
    EnableCustomFrame;
    TitleBar.OnPaintBack := @TitleBack;
    { ---> AulumicNS: the main menu at the left, next to the icon (where a
      program's menu is looked for; the icon itself opens Windows' window menu) }
    TitleBar.AddButton(icMenu, 'Main menu', @TitleMenuClick, True);
    TitleBar.AddButton(icSettings, 'Preferences (Ctrl+P)', @TitlePrefsClick);
  end;
  BuildUI;
  BuildMenus;
  FPl.OnLookup := @LibLookup;
  FPl.OnChange := @PlChanged;
  FPl.OnCollapseChange := @PlCollapseChanged;
  FPl.OnRatingChange := @PlRatingChanged;
  FPl.OnCoverClick := @PlCoverClick;
  FPl.List.OnDragOver := @PlDragOver;
  FPl.List.OnDragDrop := @PlDragDrop;
  FPl.List.OnEndDrag := @PlEndDrag;
  ApplyView(nil, '');           // the default grouping and formats (also for the screenshots)
  ApplyWindowSettings;
  OnCloseQuery := @FormCloseQuery;
  Application.OnException := @AppException;
  Application.AddOnQueryEndSessionHandler(@AppQueryEndSession);
  Application.AddOnEndSessionHandler(@AppEndSession);
  AllowDropFiles := True;
  OnDropFiles := @FormDropFiles;
  {$IFDEF DEBUG}
  { --add-folder=<folder>: adds a library folder and scans it at start (tests;
    with --shots the screenshots show that library instead of the demo) }
  if Application.HasOption('add-folder') then
  begin
    FLibrary.AddScanFolder(ExpandFileName(Application.GetOptionValue('add-folder')));
    FLibrary.IsDirty := True;
    FLibrary.SaveDatabase;
    FDebugScan := True;
  end;
  {$ENDIF}
  { --test-repair=<report>: repairs the library twice (after the scan of
    --add-folder, or the library there is), writes the memory before / after
    into the report and closes. Also in a release build made with
    --opt=-dMEMTEST: the debug build's heaptrc changes what is measured. }
  {$IF DEFINED(DEBUG) or DEFINED(MEMTEST)}
  if Application.HasOption('test-repair') then
  begin
    FMemTest := Application.GetOptionValue('test-repair');
    {$IFNDEF DEBUG}
    if Application.HasOption('add-folder') then
    begin
      FLibrary.AddScanFolder(ExpandFileName(Application.GetOptionValue('add-folder')));
      FLibrary.IsDirty := True;
      FLibrary.SaveDatabase;
    end;
    {$ENDIF}
    {$IFDEF DEBUG}if not FDebugScan then{$ENDIF} Application.QueueAsyncCall(@MemTestLater, 0);
  end;
  {$ENDIF}
  {$IFDEF DEBUG}
  { --shots=<folder>: renders the window in both themes as PNG files, then closes }
  if Application.HasOption('shots') then
  begin
    FShotDir := IncludeTrailingPathDelimiter(Application.GetOptionValue('shots'));
    ForceDirectories(FShotDir);
    PrefsDemoDevices := True;
    FShotTimer := TTimer.Create(Self);
    FShotTimer.Interval := 700;
    FShotTimer.OnTimer := @ShotTick;
    if FDebugScan then FLib.Init(FLibrary) else FLib.FillDemo;
    { with a library the playlist is filled from it (ShotTick) }
    if not FDebugScan then FPl.FillDemo;
  end
  else
  {$ENDIF}
  begin
    FLib.Init(FLibrary);
    InitPlaylists;
    RestartWatcher;
    Application.QueueAsyncCall(@StartWatchAsync, 0);
    {$IFDEF DEBUG}
    { --touch-probe=<report> [--touch-pdf=<booklet>]: the demo tree and
      playlist; AuTouchProbe swipes over them, Preferences, the help and the
      booklet with simulated touch input, writes the report and closes
      (exit code = failures; Tools\ProbeTouch.ps1) }
    if Application.HasOption('touch-probe') then
    begin
      FTouchReport := Application.GetOptionValue('touch-probe');
      FLib.FillDemo;
      FPl.FillDemo;
      Application.QueueAsyncCall(@TouchProbeAsync, 0);
    end;
    if Application.HasOption('test-drive-wait') then
    begin
      FWaitTestFile := Application.GetOptionValue('test-drive-wait');
      Application.QueueAsyncCall(@DriveWaitTestAsync, 0);
    end;
    if Application.HasOption('ui-bench') then
    begin
      FUiBenchFile := Application.GetOptionValue('ui-bench');
      FLib.FillDemo;
      FPl.FillDemo;
      Application.QueueAsyncCall(@UiBenchAsync, 0);
    end;
    {$ENDIF}
  end;
  InitPlayback;
end;

{$IFDEF DEBUG}
procedure TMainForm.TouchProbeAsync(Data: PtrInt);
var
  Pdf: string;
begin
  if FShuttingDown then Exit;
  Pdf := '';
  if FTouchReport <> '' then
    with TStringList.Create do
    try
      Add('the probe started');
      SaveToFile(FTouchReport);
    finally
      Free;
    end;
  if Application.HasOption('touch-pdf') then Pdf := Application.GetOptionValue('touch-pdf');
  ExitCode := RunTouchProbe(Self, FPl.List, FLib.Tree, Pdf, FTouchReport);
  Close;
end;

var
  UiKernel100ns: QWord;        // ThreadCpu: the UI thread's kernel part

{ the CPU of this process's threads (100 ns units): the UI thread, the others }
procedure ThreadCpu(out AUi, AOthers: QWord);
type
  TThreadEntry32 = record
    dwSize, cntUsage, th32ThreadID, th32OwnerProcessID: DWORD;
    tpBasePri, tpDeltaPri: LongInt;
    dwFlags: DWORD;
  end;
const
  TH32CS_SNAPTHREAD = $00000004;
  THREAD_QUERY_LIMITED_INFORMATION = $0800;
var
  Snap, H: THandle;
  E: TThreadEntry32;
  C, X, K, U: TFileTime;
  Pid: DWORD;
  T: QWord;
  First, Next: function(Snap: THandle; var E: TThreadEntry32): BOOL; stdcall;
  Snapshot: function(Flags, Pid: DWORD): THandle; stdcall;
  Kernel: HMODULE;
begin
  AUi := 0;
  AOthers := 0;
  Kernel := GetModuleHandle('kernel32.dll');
  Pointer(Snapshot) := GetProcAddress(Kernel, 'CreateToolhelp32Snapshot');
  Pointer(First) := GetProcAddress(Kernel, 'Thread32First');
  Pointer(Next) := GetProcAddress(Kernel, 'Thread32Next');
  if not (Assigned(Snapshot) and Assigned(First) and Assigned(Next)) then Exit;
  Pid := GetCurrentProcessId;
  Snap := Snapshot(TH32CS_SNAPTHREAD, 0);
  if Snap = INVALID_HANDLE_VALUE then Exit;
  try
    E.dwSize := SizeOf(E);
    if First(Snap, E) then
      repeat
        if E.th32OwnerProcessID = Pid then
        begin
          H := OpenThread(THREAD_QUERY_LIMITED_INFORMATION, False, E.th32ThreadID);
          if H <> 0 then
          begin
            if GetThreadTimes(H, C, X, K, U) then
            begin
              T := QWord(K) + QWord(U);
              if E.th32ThreadID = MainThreadID then
              begin
                Inc(AUi, T);
                UiKernel100ns := QWord(K);
              end
              else Inc(AOthers, T);
            end;
            CloseHandle(H);
          end;
        end;
        E.dwSize := SizeOf(E);
      until not Next(Snap, E);
  finally
    CloseHandle(Snap);
  end;
end;

function ProcessCpu100ns: QWord;
var
  C, E, K, U: TFileTime;
begin
  Result := 0;
  if GetProcessTimes(GetCurrentProcess, C, E, K, U) then
    Result := QWord(K) + QWord(U);
end;

procedure TMainForm.UiBenchAsync(Data: PtrInt);
var
  S: string;
  P: Integer;
begin
  if FShuttingDown then Exit;
  { --ui-bench-block=<factor>: the meter's block height; --ui-bench-size=WxH:
    the window in pixels (else as it opens, maximized at first) }
  MeterBlockScale := StrToFloatDef(Application.GetOptionValue('ui-bench-block'), 1);
  S := Application.GetOptionValue('ui-bench-size');
  P := Pos('x', S);
  if P > 0 then
  begin
    WindowState := wsNormal;
    Constraints.MinWidth := 0;
    Constraints.MinHeight := 0;
    SetBounds(0, 0, StrToIntDef(Copy(S, 1, P - 1), Width), StrToIntDef(Copy(S, P + 1, 9), Height));
  end;
  FTransport.SetPlaying(True);
  FBanner.Playing := True;
  FBanner.ShowMeter := not Application.HasOption('ui-bench-nometer');
  FBanner.Meter.Active := FBanner.ShowMeter;
  FTransport.Seek.Enabled := True;
  FUiBenchTimer := TTimer.Create(Self);
  FUiBenchTimer.Interval := UI_TIMER_INTERVAL_MS;
  FUiBenchTimer.OnTimer := @UiBenchTimer;
  FUiBenchTick := GetTickCount64;
  FUiBenchT0 := 0;
end;

{ as UiTimerTick while playing: the seek bar every tick, the time once a
  second, the meter (levels like music); 2 s to settle, then 15 s measured }
procedure TMainForm.UiBenchTimer(Sender: TObject);
var
  T: Double;
  Cpu, Wall, Ui1, Other1: QWord;
  W: string;
  Freq: Int64;
  I: Integer;
begin
  Inc(FUiBenchN);
  T := FUiBenchN * UI_TIMER_INTERVAL_MS / 1000;
  { --ui-bench-only=seek|time|meter|none: one part alone }
  W := Application.GetOptionValue('ui-bench-only');
  { --ui-bench-seekms=<ms>: the seek bar set only that often (else every tick) }
  if ((W = '') or (W = 'seek')) and
     (FUiBenchN mod Math.Max(1, StrToIntDef(Application.GetOptionValue('ui-bench-seekms'), 50) div 50) = 0) then
    FTransport.Seek.Position := Frac(T / 240);
  if ((W = '') or (W = 'time')) and (FUiBenchN mod 20 = 0) then
    FTransport.LblPos.Caption := FormatDuration(Trunc(T));
  { --ui-bench-only=lists: the playlist and the library tree painted anew at
    every tick (what a scrolling list costs) }
  if W = 'lists' then
  begin
    FPl.List.Invalidate;
    FLib.Tree.Invalidate;
  end;
  if FBanner.Meter.Active and ((W = '') or (W = 'meter')) then
  begin
    { like music: a slow envelope, peaks that differ from read to read }
    FBanner.Meter.SetLevels((0.05 + 0.2 * Abs(Sin(T * 3.1))) * (0.6 + 0.4 * Random),
      (0.05 + 0.2 * Abs(Sin(T * 2.3))) * (0.6 + 0.4 * Random));
    FBanner.Meter.SetClip(False, False);
  end;
  if (FUiBenchT0 = 0) and (GetTickCount64 - FUiBenchTick >= 2000) then
  begin
    FUiBenchT0 := GetTickCount64;
    FUiBenchCpu0 := ProcessCpu100ns;
    ThreadCpu(FUiBenchUi0, FUiBenchOther0);
    FUiBenchKernel0 := UiKernel100ns;
    MeterPaints := 0;
    MeterPaintTicks := 0;
    if PaintTally = nil then PaintTally := TStringList.Create;
    PaintTally.Clear;
  end
  else if (FUiBenchT0 <> 0) and (GetTickCount64 - FUiBenchT0 >= 15000) then
  begin
    FUiBenchTimer.Enabled := False;
    Wall := GetTickCount64 - FUiBenchT0;
    Cpu := ProcessCpu100ns - FUiBenchCpu0;
    with TStringList.Create do
    try
      Add(Format('%s, meter %s, window %d x %d px: %.1f %% of one CPU (%.0f ms CPU in %d ms), ' +
        'meter paints %.1f / s', [Application.GetOptionValue('ui-bench-only'),
         BoolToStr(FBanner.Meter.Active, 'on', 'off'), Width, Height, Cpu / 100 / Wall,
         Cpu / 10000, Wall, MeterPaints * 1000 / Wall]));
      ThreadCpu(Ui1, Other1);
      Add(Format('  UI thread %.1f %% (kernel %.1f %%), the other threads %.1f %% of one CPU',
        [(Ui1 - FUiBenchUi0) / 100 / Wall, (UiKernel100ns - FUiBenchKernel0) / 100 / Wall,
         (Other1 - FUiBenchOther0) / 100 / Wall]));
      QueryPerformanceFrequency(Freq);
      if MeterPaints > 0 then
        Add(Format('  inside the meter''s DoPaint: %.3f ms per paint', [MeterPaintTicks * 1000 / Freq / MeterPaints]));
      if PaintTally <> nil then
      begin
        for I := 0 to PaintTally.Count - 1 do
          Add(Format('  paints: %-22s %5d, %.3f ms each', [PaintTally.Names[I],
            PtrInt(PaintTally.Objects[I]), StrToInt64Def(PaintTally.ValueFromIndex[I], 0) * 1000 / Freq /
            Math.Max(1, PtrInt(PaintTally.Objects[I]))]));
        FreeAndNil(PaintTally);
      end;
      SaveToFile(FUiBenchFile);
    finally
      Free;
    end;
    Close;
  end;
end;
{$ENDIF}

destructor TMainForm.Destroy;
var
  P: TPlaybackManager;
begin
  FShuttingDown := True;
  { ---> AulumicNS: traced step by step; a failing step is written to
    ShutdownTraceLog.txt and the next ones still run (see FormCloseQuery) }
  WriteShutDownTrace('Destroy: closing the tool windows');
  try
    StopHangWatch;     // (when the close did not go through FormCloseQuery)
    Application.OnException := nil;
    Application.RemoveOnQueryEndSessionHandler(@AppQueryEndSession);
    Application.RemoveOnEndSessionHandler(@AppEndSession);
    Application.RemoveAsyncCalls(Self);
    CloseSignalPath;
    if FVolPopup <> nil then
    begin
      { still open: its events point at this window }
      FVolPopup.OnClosed := nil;
      FVolPopup.OnVolume := nil;
      FVolPopup.OnMute := nil;
      FreeAndNil(FVolPopup);
    end;
    if FUiTimer <> nil then FUiTimer.Enabled := False;
    { the tool windows read the playback manager and the log }
    CloseDebugQueue;
    CloseLogWindow;
    CloseReplayGainWindow;
    CloseCoverViewer;
    CloseBooklet;
    CloseHelpWindow;
    { saves an edited biography; reads the library }
    CloseArtistInfo;
  except
    LogShutdownStepError('Destroy: close the tool windows');
  end;
  WriteShutDownTrace('Destroy: stopping the tag writer');
  try
    { the tag writer uses the playback manager and the library }
    FreeCustodian;
  except
    LogShutdownStepError('Destroy: stop the tag writer');
  end;
  WriteShutDownTrace('Destroy: freeing the playback');
  try
    if FPlayback <> nil then
    begin
      P := FPlayback;
      FPlayback := nil;
      { its Stop reports back: no events into a window being destroyed }
      P.OnTrackChange := nil;
      P.OnTrackInfoRefreshed := nil;
      P.OnStateChange := nil;
      P.OnModeChange := nil;
      P.OnSampleRateError := nil;
      P.OnBackgroundRequest := nil;
      P.Free;
    end;
  except
    LogShutdownStepError('Destroy: free the playback');
  end;
  WriteShutDownTrace('Destroy: saving and freeing the library and the playlists');
  try
    { the library after the playback (the play count of the last track) }
    FreeLibrary;
    FreeAndNil(FPlaylists);
    {$IFDEF DEBUG}
    FreeAndNil(FShotForm);
    FreeAndNil(FShotStore);
    {$ENDIF}
    FreeAndNil(FLibrary);
    FreeAndNil(UserStatsManager);
    { ---> AulumicNS: saved in FreeLibrary. The play threads are gone (the
      playback was freed above) - unless one did not stop in time and was
      set aside (stuck in a driver or a file read): it may still wake up and
      meet a new peak, so the book is left to it and to the end of the
      process then (a few KB, and only in that case). }
    if not PlayThreadsStillRunning then
      FreeAndNil(HeadroomBook);
  except
    LogShutdownStepError('Destroy: free the library and the playlists');
  end;
  WriteShutDownTrace('Destroy: freeing the menus');
  FMainMenu.Free;
  FPlaylistMenu.Free;
  FViewMenu.Free;
  FDeviceMenu.Free;
  FRateMenu.Free;
  FArtistMenu.Free;
  FCtxMenu.Free;
  FDeviceIds.Free;
  FMenuPlNames.Free;
  FAddToNames.Free;
  if FIconBig <> 0 then DestroyIcon(FIconBig);
  if FIconSmall <> 0 then DestroyIcon(FIconSmall);
  inherited Destroy;
end;

procedure TMainForm.CreateWnd;
begin
  inherited CreateWnd;
  SetAppIcon;
  PublishMainWindow(Handle);
  if FPlayback <> nil then FPlayback.NotifyHandle := Handle;
end;

procedure TMainForm.SetAppIcon;
begin
  if FIconBig = 0 then FIconBig := AppIconHandle(GetSystemMetrics(SM_CXICON));
  if FIconSmall = 0 then FIconSmall := AppIconHandle(GetSystemMetrics(SM_CXSMICON));
  SendMessage(Handle, WM_SETICON, ICON_BIG, LPARAM(FIconBig));
  SendMessage(Handle, WM_SETICON, ICON_SMALL, LPARAM(FIconSmall));
end;

procedure TMainForm.BuildUI;
var
  Dat: TAppSettingsData;
begin
  Dat := AppSettings.Data;
  Constraints.MinWidth := Math.Min(S(860), Screen.WorkAreaWidth);
  Constraints.MinHeight := Math.Min(S(560), Screen.WorkAreaHeight);

  { bottom: status line (lowest), transport above it }
  FStatus := TStatusStrip.Create(Self);
  FStatus.Parent := Self;
  FStatus.Align := alBottom;
  FStatus.Top := 100000;
  FStatus.OnRgClick := @RgClick;
  FTransport := TTransportBar.Create(Self);
  FTransport.Parent := Self;
  FTransport.Align := alBottom;
  FTransport.BtnPlay.OnClick := @PlayClick;
  FTransport.BtnStop.OnClick := @StopClick;
  FTransport.BtnPrev.OnClick := @PrevClick;
  FTransport.BtnNext.OnClick := @NextClick;
  FTransport.BtnJump.OnClick := @JumpClick;
  FTransport.BtnShuffle.OnClick := @ShuffleClick;
  FTransport.BtnRepeat.OnClick := @RepeatClick;
  FTransport.BtnDevice.OnClick := @DeviceClick;
  FTransport.BtnTone.OnClick := @ToneClick;
  FTransport.BtnVolume.OnClick := @VolumeClick;
  FTransport.Seek.OnChange := @SeekChange;
  FTransport.Seek.OnChangeEnd := @SeekEnd;
  FTransport.Seek.Enabled := False;

  { top: the banner and its splitter }
  FBanner := TNowPlayingBanner.Create(Self);
  FBanner.Parent := Self;
  FBanner.Align := alTop;
  if TitleBar <> nil then FBanner.Top := TitleBar.Top + TitleBar.Height;
  FBanner.Height := S(EnsureRange(Dat.TopPanelHeight, BannerMinHeight, BannerMaxHeight));
  FBanner.ShowMeter := Dat.ShowPeakmeter;
  FBanner.OnCover := @BannerCover;
  FBanner.OnAlbum := @BannerAlbum;
  FBanner.OnArtist := @BannerArtist;
  FBanner.OnMoreArtists := @BannerMoreArtists;
  FBanner.OnRate := @BannerRate;
  FBanner.OnBadge := @BannerBadge;
  FBanner.OnHeart := @BannerHeart;
  FBanner.OnBooklet := @BannerBooklet;
  FTopSplit := TAuSplitter.Create(Self);
  FTopSplit.Parent := Self;
  FTopSplit.Align := alTop;
  FTopSplit.Height := S(6);
  FTopSplit.Top := FBanner.Top + FBanner.Height + 1;
  FTopSplit.Target := FBanner;
  FTopSplit.MinSize := S(BannerMinHeight);
  FTopSplit.MaxSize := S(BannerMaxHeight);
  FTopSplit.BackRole := crBg;
  FTopSplit.OnMoved := @TopSplitMoved;

  { middle: library | playlist }
  FMid := TAuPanel.Create(Self);
  FMid.Parent := Self;
  FMid.Align := alClient;
  FMid.BackRole := crBg;
  FLib := TLibraryPane.Create(Self);
  FLib.Parent := FMid;
  FLib.Align := alLeft;
  FLibWanted := EnsureRange(Dat.LeftPanelWidth, MIN_LPANEL_WIDTH, 900);
  FLib.Width := S(FLibWanted);
  FLib.Tree.TextSize := PaneTextPx(Dat.LibraryFontSize);
  FLib.Tree.Accordion := Dat.AccordionEnabled;
  FLib.Tree.OnTextSizeChange := @LibTextSize;
  FLib.Tree.OnActivate := @TreeActivate;
  FLib.Tree.OnNodeContext := @TreeContext;
  FLib.BtnRescan.OnClick := @RescanClick;
  FMainSplit := TAuSplitter.Create(Self);
  FMainSplit.Parent := FMid;
  FMainSplit.Align := alLeft;
  FMainSplit.Left := FLib.Left + FLib.Width + 1;
  FMainSplit.Target := FLib;
  FMainSplit.MinSize := S(MIN_LPANEL_WIDTH);
  FMainSplit.MaxSize := S(900);
  FMainSplit.BackRole := crBg;
  FMainSplit.OnMoved := @MainSplitMoved;
  FMid.OnResize := @MidResize;
  FPl := TPlaylistPane.Create(Self);
  FPl.Parent := FMid;
  FPl.Align := alClient;
  FPl.List.TextSize := PaneTextPx(Dat.PlayListFontSize);
  FPl.List.OnTextSizeChange := @PlTextSize;
  FPl.List.OnActivate := @PlActivate;
  FPl.List.OnRowContext := @PlContext;
  FPl.List.OnKeyDown := @PlKeyDown;
  FPl.BtnPlaylist.OnClick := @PlaylistDrop;
  FPl.BtnPlaylist.Caption := LBL_DEFAULT_PLAYLIST;
  FPl.BtnView.OnClick := @ViewClick;
  FPl.BtnEdit.OnClick := @EditClick;

  FToast := TAuToast.Create(Self);
  FToast.Parent := FMid;
  FToast.BottomOffset := S(16);

  { tab order of the areas }
  FMid.TabOrder := 0;
  FTransport.TabOrder := 1;
  FLib.TabOrder := 0;
  FPl.TabOrder := 1;

  FUiTimer := TTimer.Create(Self);
  FUiTimer.Interval := UI_TIMER_IDLE_INTERVAL_MS;
  FUiTimer.OnTimer := @UiTimerTick;
end;

procedure TMainForm.BuildMenus;
var
  M, Sub: TAuMenu;
  I: Integer;
  It: TAuMenuItem;
begin
  { the main menu (the three-lines button of the title bar) }
  FMainMenu := TAuMenu.Create;
  FMainMenu.OnPopup := @MainMenuPopup;
  M := FMainMenu.AddSub('File', icFolder);
  M.Add('Add files...', @MnAddFiles, icPlus, 'Ctrl+O');
  M.Add('Add folder...', @MnAddFolder, icFolderPlus);
  M.AddSeparator;
  M.Add('Import playlist...', @MnImportM3U, icImport);
  M.Add('Export playlist...', @MnExportM3U, icExport);
  M := FMainMenu.AddSub('Playback', icPlay);
  M.Add('Play / pause', @PlayClick, icPlay, 'Space');
  M.Add('Stop', @StopClick, icStopSolid);
  M.Add('Previous', @PrevClick, icPrev);
  M.Add('Next', @NextClick, icNext);
  M.AddSeparator;
  M.Add('Jump to Now Playing', @JumpClick, icLocate, 'Ctrl+J');
  M := FMainMenu.AddSub('Library', icLibrary);
  M.Add('Search', @MnSearch, icSearch, 'Ctrl+F');
  M.Add('Refresh', @MnRefresh, icRefresh, 'F5');
  M.Add('Rescan library', @MnRescan, icScan, 'Ctrl+F5');
  M.AddSeparator;
  M.Add('Library folders...', @MnLibraryFolders, icFolderPlus);
  M := FMainMenu.AddSub('Playlist', icPlaylist);
  M.Add('Playlist Manager...', @MnPlaylistManager, icEdit, 'Alt+P');
  M.Add('Clear the playlist', @MnClearList, icTrash);
  M := FMainMenu.AddSub('Tools', icSliders);
  M.Add('Edit properties...', @MnProperties, icTag, 'Alt+Enter');
  M.Add('Calculate ReplayGain', @MnReplayGain, icWave);
  M.AddSeparator;
  M.Add('Show log...', @MnLog, icLog, 'Ctrl+L');
  M.Add('Show Debug Queue', @MnDebugQueue, icBug, 'Ctrl+D');
  FMainMenu.AddSeparator;
  FMainMenu.Add('Preferences...', @MnPrefs, icSettings, 'Ctrl+P');
  Sub := FMainMenu.AddSub('Theme', icSun);
  FThemeMenu := Sub;
  Sub.Add('Dark', @MnThemeDark, icMoon, '', 0);
  Sub.Add('Light', @MnThemeLight, icSun, '', 1);
  Sub.Add('Follow Windows', @MnThemeSystem, icSettings, '', 2);
  Sub.AddSeparator;
  for I := 0 to AccentCount - 1 do
  begin
    It := Sub.Add(AccentNames[I], @MnAccent, icNone, '', I);
    It.Tag := I;
  end;
  FMainMenu.AddSeparator;
  FMainMenu.Add('Help...', @MnHelp, icHelp, 'F1');
  FMainMenu.Add('About...', @MnAbout, icInfo);
  FMainMenu.AddSeparator;
  FMainMenu.Add('Quit', @MnQuit, icPower, 'Ctrl+Q');

  FPlaylistMenu := TAuMenu.Create;
  FViewMenu := TAuMenu.Create;
  FDeviceMenu := TAuMenu.Create;
  FRateMenu := TAuMenu.Create;
  FArtistMenu := TAuMenu.Create;
end;

procedure TMainForm.MainMenuPopup(Sender: TObject);
var
  I: Integer;
begin
  { tick the current theme and accent }
  FThemeMenu.Item(0).Checked := ThemeMode = tmDark;
  FThemeMenu.Item(1).Checked := ThemeMode = tmLight;
  FThemeMenu.Item(2).Checked := ThemeMode = tmSystem;
  for I := 0 to AccentCount - 1 do FThemeMenu.Item(4 + I).Checked := AccentIndex = I;
end;

procedure TMainForm.ApplyWindowSettings;
var
  Dat: TAppSettingsData;
begin
  Dat := AppSettings.Data;
  Position := poDesigned;
  if (Dat.WinLeft <> VAL_UNINITIALIZED_POS) and (Dat.WinWidth >= MIN_FORM_WIDTH) then
    SetBounds(Dat.WinLeft, Dat.WinTop, Dat.WinWidth, Dat.WinHeight)
  else
  begin
    Width := Math.Min(S(1440), Screen.WorkAreaWidth - S(40));
    Height := Math.Min(S(900), Screen.WorkAreaHeight - S(40));
    Left := Screen.WorkAreaLeft + (Screen.WorkAreaWidth - Width) div 2;
    Top := Screen.WorkAreaTop + (Screen.WorkAreaHeight - Height) div 2;
  end;
  if Dat.WinState = wsMaximized then WindowState := wsMaximized;
end;

procedure TMainForm.SaveWindowSettings;
begin
  { the width the user chose, not the one a narrow window allows just now }
  AppSettings.Data.LeftPanelWidth := FLibWanted;
  AppSettings.Data.TopPanelHeight := Round(FBanner.Height / UIScale);
  AppSettings.Data.LibraryFontSize := EnsureRange(Round(FLib.Tree.TextSize) - 2, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  AppSettings.Data.PlayListFontSize := EnsureRange(Round(FPl.List.TextSize) - 2, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  AppSettings.Save(Self);
end;

{ ---> AulumicNS: the close as Aulumic's teardown: traced step by step
  (uCrashTracer: written to ShutdownTraceLog.txt only when a step fails), and
  a failing step no longer stops the ones after it }
{ ---> AulumicNS: closing while tags are written, ReplayGain is calculated or
  the library is scanned asks first (it closed at once) }
function TMainForm.ConfirmCloseWhileBusy: Boolean;
var
  Lines: string;
begin
  Result := True;
  if AppStateManager = nil then Exit;
  Lines := '';
  if AppStateManager.HasState(esBackgroundIOBusy) then
    Lines := Lines + '- Tags are being written to your files. Files not written yet keep their old tags.' + sLineBreak;
  if AppStateManager.HasState(esReplayGainBusy) then
    Lines := Lines + '- ReplayGain is being calculated, or its results are not saved yet. They are lost.' + sLineBreak;
  if (FLibrary <> nil) and FLibrary.IsScanning then
    Lines := Lines + '- The library is being scanned. Refresh the library later to finish it.' + sLineBreak;
  if Lines = '' then Exit;
  Result := ALMessageDlg('Still working', 'Aulumic is still busy:' + sLineBreak + sLineBreak + Lines +
    sLineBreak + 'Close anyway?', 'Close anyway', 'Keep running', False, mbNo, mkWarning) = mrYes;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := True;
  if (not FShuttingDown) and not ConfirmCloseWhileBusy then
  begin
    CanClose := False;
    Exit;
  end;
  { the close may keep the window busy for seconds: no hang report for it }
  StopHangWatch;
  BeginShutdownTrace;
  FShuttingDown := True;
  WriteShutDownTrace('Close: stopping the timer and the playback');
  try
    if FUiTimer <> nil then FUiTimer.Enabled := False;
    if FTone <> nil then
    begin
      AppSettings.Data.ToneWinLeft := FTone.Left;
      AppSettings.Data.ToneWinTop := FTone.Top;
    end;
    if FPlayback <> nil then FPlayback.Stop;
  except
    LogShutdownStepError('Close: stop the playback');
  end;
  {$IFDEF DEBUG}
  if FShotDir <> '' then Exit;   // screenshot mode leaves no trace
  {$ENDIF}
  WriteShutDownTrace('Close: saving the playlists');
  try
    FreePlaylists;
  except
    LogShutdownStepError('Close: save the playlists');
  end;
  WriteShutDownTrace('Close: saving the window settings');
  try
    SaveWindowSettings;
  except
    LogShutdownStepError('Close: save the window settings');
  end;
  WriteShutDownTrace('Close: saving the log');
  try
    { ---> AulumicNS: always when Preferences > Advanced says so, else only
      when an error was logged }
    SaveLog(True, not AppSettings.Data.AlwaysSaveLog);
  except
    LogShutdownStepError('Close: save the log');
  end;
end;

{ ---- Windows ends the session ---- }

{ everything that is only saved at the close, without closing anything: the
  session may still go on (another program can refuse the shutdown) }
procedure TMainForm.SaveForSessionEnd;
begin
  {$IFDEF DEBUG}
  if FShotDir <> '' then Exit;   // screenshot mode leaves no trace
  {$ENDIF}
  try
    { a playlist edit of the last moments, the playlist shown }
    if FPlaylists <> nil then
    begin
      SaveShownPlaylist(True);
      AppSettings.Data.ActivePlayList := FShownPl;
      FPlaylists.Save;
    end;
  except
    LogShutdownStepError('Session end: save the playlists');
  end;
  try
    if FTone <> nil then
    begin
      AppSettings.Data.ToneWinLeft := FTone.Left;
      AppSettings.Data.ToneWinTop := FTone.Top;
    end;
    SaveWindowSettings;
  except
    LogShutdownStepError('Session end: save the settings');
  end;
  try
    { changes since the last snapshot are in the journals already; the
      snapshots make the next start as fast as usual }
    if (FLibrary <> nil) and FLibrary.IsDirty then FLibrary.SaveDatabase;
    if (UserStatsManager <> nil) and UserStatsManager.IsDirty then UserStatsManager.SaveToFile;
    SaveHeadroom;
  except
    LogShutdownStepError('Session end: save the library and the statistics');
  end;
  try
    { ---> AulumicNS: always when Preferences > Advanced says so, else only
      when an error was logged }
    SaveLog(True, not AppSettings.Data.AlwaysSaveLog);
  except
    LogShutdownStepError('Session end: save the log');
  end;
end;

{ Windows asks whether the session may end: never refused, but saved now -
  after this the process may be ended at any moment }
procedure TMainForm.AppQueryEndSession(var Cancel: Boolean);
begin
  Cancel := False;
  if FShuttingDown then Exit;
  SaveForSessionEnd;
end;

{ the session ends now: the close without its question (the playback stops,
  everything is saved), then the program leaves its message loop. Queued:
  Application.Terminate inside the WM_ENDSESSION that Windows waits for could
  block (Aulumic: about 1 shutdown in 5 never ended). Windows usually ends
  the process as soon as this returns. }
procedure TMainForm.AppEndSession(Sender: TObject);
var
  CanClose: Boolean;
begin
  if FShuttingDown then Exit;
  FShuttingDown := True;
  CanClose := True;
  FormCloseQuery(Self, CanClose);
  try
    if (FLibrary <> nil) and FLibrary.IsDirty then FLibrary.SaveDatabase;
    if (UserStatsManager <> nil) and UserStatsManager.IsDirty then UserStatsManager.SaveToFile;
  except
    LogShutdownStepError('Session end: save the library and the statistics');
  end;
  Application.QueueAsyncCall(@TerminateAfterEndSession, 0);
end;

procedure TMainForm.TerminateAfterEndSession(Data: PtrInt);
begin
  Application.Terminate;
end;

{ ---- theme ---- }

procedure TMainForm.SetThemeMode(M: TAuThemeMode);
begin
  SetTheme(M, AccentIndex);
  AppSettings.Data.ThemeMode := Ord(ThemeMode);
  AppSettings.Data.DarkMode := ThemeIsDark;
end;

procedure TMainForm.SetAccent(A: Integer);
begin
  SetTheme(ThemeMode, A);
  AppSettings.Data.Accent := AccentIndex;
end;

procedure TMainForm.ThemeUpdated;
begin
  inherited ThemeUpdated;
  if FBanner <> nil then FBanner.Changed;
  if TitleBar <> nil then TitleBar.Invalidate;
end;

procedure TMainForm.WndProc(var Message: TLMessage);
begin
  if Message.Msg = WM_AUDIO_ENGINE_LOG then
  begin
    { a log line of the audio engine (posted by the play thread) }
    AppLog.EngineMessage(Message.WParam, Message.LParam);
    Message.Result := 0;
    Exit;
  end;
  if Message.Msg = WM_APPCOMMAND then
  begin
    { media keys while the window is active }
    case (Message.LParam shr 16) and $0FFF of
      14: begin PlayPause; Message.Result := 1; Exit; end;   // APPCOMMAND_MEDIA_PLAY_PAUSE
      13: begin StopPlayback; Message.Result := 1; Exit; end; // APPCOMMAND_MEDIA_STOP
      11: begin NextTrack; Message.Result := 1; Exit; end;    // APPCOMMAND_MEDIA_NEXTTRACK
      12: begin PrevTrack; Message.Result := 1; Exit; end;    // APPCOMMAND_MEDIA_PREVIOUSTRACK
    end;
  end;
  inherited WndProc(Message);
  if (Message.Msg = WM_SETTINGCHANGE) and (ThemeMode = tmSystem) and (Message.LParam <> 0) and
     (UnicodeString(PWideChar(Message.LParam)) = 'ImmersiveColorSet') then
    SetTheme(tmSystem, AccentIndex);
end;

procedure TMainForm.MnThemeDark(Sender: TObject);
begin
  SetThemeMode(tmDark);
end;

procedure TMainForm.MnThemeLight(Sender: TObject);
begin
  SetThemeMode(tmLight);
end;

procedure TMainForm.MnThemeSystem(Sender: TObject);
begin
  SetThemeMode(tmSystem);
end;

procedure TMainForm.MnAccent(Sender: TObject);
begin
  SetAccent(TAuMenuItem(Sender).Tag);
end;

{ ---- banner ---- }

procedure TMainForm.TitleBack(Sender: TObject; G: TGfx);
begin
  { the title bar continues the top colour of the banner }
  if FBanner <> nil then G.FillRect(0, 0, TitleBar.Width, TitleBar.Height, FBanner.TopColor)
  else G.FillRect(0, 0, TitleBar.Width, TitleBar.Height, clPanel);
end;

{ ---> AulumicNS: the main menu and Preferences buttons are in the title bar
  (were in the banner, with a sun / moon theme button that was removed) }
procedure TMainForm.TitleMenuClick(Sender: TObject);
var
  R: TRect;
begin
  R := TitleBar.ButtonScreenRect(0);
  FMainMenu.Popup(R.Left, R.Bottom);
end;

procedure TMainForm.TitlePrefsClick(Sender: TObject);
begin
  MnPrefs(Sender);
end;

procedure TMainForm.BannerCover(Sender: TObject);
begin
  if FPlayingPath = '' then Exit;
  ShowCoverViewer(Self, FCurrentMeta, FPlayingPath);
end;

procedure TMainForm.BannerAlbum(Sender: TObject);
begin
  BannerCover(Sender);
end;

procedure TMainForm.BannerArtist(Sender: TObject; const AName: string);
begin
  ShowArtistInfo(Self, FLibrary, AName);
end;

procedure TMainForm.BannerMoreArtists(Sender: TObject; ScreenPt: TPoint);
var
  I: Integer;
begin
  FOverflowArtists := FBanner.OverflowArtists;
  FArtistMenu.Clear;
  for I := 0 to High(FOverflowArtists) do
    FArtistMenu.Add(FOverflowArtists[I], @MnOverflowArtist, icArtist, '', I);
  FArtistMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

{ the signal path (Aulos) as a popup under the badge; a second click closes
  it. The device name is looked up once (it enumerates the devices). }
procedure TMainForm.BannerBadge(Sender: TObject; ScreenPt: TPoint);
begin
  if not SignalPathOpen then FSigDevice := CurrentDeviceName;
  ShowSignalPath(ScreenPt.X, ScreenPt.Y, ScreenPt.Y - S(36), @FillSignalPath);
end;

procedure TMainForm.FillSignalPath(P: TAuSignalPath);
begin
  if FShuttingDown or (FPlayback = nil) then Exit;
  BuildSignalPath(P, FPlayback.GetSignalInfo, FCurrentMeta, FPlayingPath, FSigDevice,
    FPlayback.State = psPaused);
end;

{ the built-in booklet viewer (Aulos; Aulumic opened SumatraPDF): the PDFs
  of the playing album's folder, its sub folders and a disc folder's parent }
procedure TMainForm.BannerBooklet(Sender: TObject);
var
  L: TStringList;
begin
  if FPlayingPath = '' then Exit;
  L := TStringList.Create;
  try
    FindBooklets(ExtractFileDir(FPlayingPath), L);
    if L.Count > 0 then ShowBooklet(L)
    else AuMessage('This album has no PDF booklet.', amInfo, abOK, 'Booklet');
  finally
    L.Free;
  end;
end;

{ ---- panes ---- }

procedure TMainForm.TopSplitMoved(Sender: TObject);
begin
  AppSettings.Data.TopPanelHeight := Round(FBanner.Height / UIScale);
end;

procedure TMainForm.MainSplitMoved(Sender: TObject);
begin
  FLibWanted := Round(FLib.Width / UIScale);
  AppSettings.Data.LeftPanelWidth := FLibWanted;
end;

{ ---> AulumicNS: as Aulumic's FormResize, the playlist keeps at least
  MIN_RPANEL_WIDTH (a narrower window narrows the library pane, down to
  MIN_LPANEL_WIDTH); the splitter cannot go past that either.
  2026-11-13: when the window gets wider again the pane goes back to the
  width the user chose (FLibWanted, set by the splitter). Before, it stayed
  narrow: with the TV at the NUC switched off Windows gives the desktop a
  small size for a moment, the window shrinks with it - and the library pane
  was narrow for good when the TV came back. }
procedure TMainForm.MidResize(Sender: TObject);
var
  MaxW, W: Integer;
begin
  if (FLib = nil) or (FMainSplit = nil) or (WindowState = wsMinimized) or
    (FMid.ClientWidth <= 0) then Exit;
  UseDpiOf(FMid);
  MaxW := Max(S(MIN_LPANEL_WIDTH), Min(S(900), FMid.ClientWidth - FMainSplit.Width - S(MIN_RPANEL_WIDTH)));
  FMainSplit.MaxSize := MaxW;
  if FMainSplit.Dragging then
  begin
    if FLib.Width > MaxW then FLib.Width := MaxW;
    Exit;
  end;
  W := EnsureRange(S(FLibWanted), S(MIN_LPANEL_WIDTH), MaxW);
  if FLib.Width <> W then FLib.Width := W;
end;

procedure TMainForm.LibTextSize(Sender: TObject);
begin
  AppSettings.Data.LibraryFontSize := EnsureRange(Round(FLib.Tree.TextSize) - 2, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  FLib.Tree.TextSize := PaneTextPx(AppSettings.Data.LibraryFontSize);
end;

procedure TMainForm.PlTextSize(Sender: TObject);
begin
  AppSettings.Data.PlayListFontSize := EnsureRange(Round(FPl.List.TextSize) - 2, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  FPl.List.TextSize := PaneTextPx(AppSettings.Data.PlayListFontSize);
end;

procedure TMainForm.PlActivate(Sender: TObject; Row: Integer);
begin
  PlayEntry(FPl.EntryOfRow(Row));
end;

procedure TMainForm.PlKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_DELETE) and (Shift = []) then
  begin
    Key := 0;
    RemoveSelected;
  end;
end;

procedure TMainForm.EditClick(Sender: TObject);
begin
  MnPlaylistManager(Sender);
end;

procedure TMainForm.RescanClick(Sender: TObject);
begin
  MnRescan(Sender);
end;

{ ---- transport ---- }

procedure TMainForm.PlayClick(Sender: TObject);
begin
  PlayPause;
end;

procedure TMainForm.StopClick(Sender: TObject);
begin
  StopPlayback;
end;

procedure TMainForm.PrevClick(Sender: TObject);
begin
  PrevTrack;
end;

procedure TMainForm.NextClick(Sender: TObject);
begin
  NextTrack;
end;

procedure TMainForm.JumpClick(Sender: TObject);
begin
  JumpToNowPlaying;
end;

procedure TMainForm.ShuffleClick(Sender: TObject);
begin
  if FPlayback <> nil then FPlayback.ToggleShuffle;
end;

procedure TMainForm.RepeatClick(Sender: TObject);
begin
  if FPlayback <> nil then FPlayback.ToggleRepeat;
end;

procedure TMainForm.ToneClick(Sender: TObject);
begin
  ShowTone;
end;

{ ---- menu items ---- }

procedure TMainForm.MnSearch(Sender: TObject);
begin
  if FLib.Search.CanFocus then
  begin
    FLib.Search.SetFocus;
    FLib.Search.SelectAll;
  end;
end;


procedure TMainForm.MnLog(Sender: TObject);
begin
  ShowLogWindow(Self);
end;

procedure TMainForm.MnDebugQueue(Sender: TObject);
begin
  if DebugQueueVisible then CloseDebugQueue
  else ShowDebugQueue(Self, FPlayback);
end;

procedure TMainForm.MnPrefs(Sender: TObject);
begin
  ShowPrefsPage(-1);
end;

{ the Preferences dialog; after OK the new settings are applied as in
  Aulumic's TfrmMain.ShowPrefsDialog: the engine gets its config (the
  playing track restarts when an audio setting or the device changed), the
  playlist is shown again when its default formats changed, the library
  tree is filled again for other groups, new folders are scanned }
procedure TMainForm.ShowPrefsPage(APage: Integer);
var
  Old, New: TAppSettingsData;
  OldFolders, NewFolders: TStringList;
  OldDevName, NewDevName: string;
  DeviceChanged, Restart, FormatsChanged, FoldersChanged: Boolean;
begin
  if FShuttingDown or PrefsOpen then Exit;
  OldDevName := CurrentDeviceName;
  Old := AppSettings.Data;
  OldFolders := TStringList.Create;
  NewFolders := TStringList.Create;
  try
    if FLibrary <> nil then FLibrary.GetScanFolders(OldFolders);
    NewFolders.Assign(OldFolders);
    { with OK the dialog's settings are in AppSettings.Data }
    if not ShowPreferences(Self, NewFolders, FLibrary, @PrefsScan, APage) then Exit;
    AppSettings.SyncOutputDevice;
    New := AppSettings.Data;
    DeviceChanged := (Old.OutputApi <> New.OutputApi) or not SameText(Old.Audio.DeviceID, New.Audio.DeviceID);
    if DeviceChanged then NewDevName := CurrentDeviceName else NewDevName := OldDevName;
    New := AppSettings.Data;
    LogSettingsChanges(Old.Audio, New.Audio, OldDevName, NewDevName);
    Restart := DeviceChanged or PlaybackRestartNeeded(Old.Audio, New.Audio);
    FormatsChanged := (Old.DefaultGroupingMode <> New.DefaultGroupingMode) or
      not SameText(Old.DefaultHeaderFormat, New.DefaultHeaderFormat) or
      not SameText(Old.DefaultTrackFormat, New.DefaultTrackFormat);
    AnimationsOn := New.Animations;
    if Old.GpuPaint <> New.GpuPaint then
    begin
      GpuPaintAllowed := New.GpuPaint;
      RefreshAllForms;
    end;
    { the text size of all windows }
    if Old.UIFontSize <> New.UIFontSize then
    begin
      FontScale := New.UIFontSize / 100;
      RefreshAllForms;
    end;
    { the panes }
    FLib.Tree.TextSize := PaneTextPx(New.LibraryFontSize);
    FPl.List.TextSize := PaneTextPx(New.PlaylistFontSize);
    FLib.Tree.Accordion := New.AccordionEnabled;
    FBanner.ShowMeter := New.ShowPeakmeter;
    FBanner.Changed;
    { the engine }
    UpdateManagerConfig;
    if DeviceChanged then UpdateDeviceButton;
    if Restart and (FPlayback <> nil) and (FPlayback.State <> psStopped) then
    begin
      FPlayback.RestartCurrent;
      FRateShown := False;
    end;
    { the playlist with the new default formats }
    if FormatsChanged and (FPlaylists <> nil) then
    begin
      BeginBusy;
      try
        ShowPlaylist(FShownPl, True);
      finally
        EndBusy;
      end;
    end;
    { the library }
    FoldersChanged := (FLibrary <> nil) and ApplyLibraryFolders(NewFolders);
    if (not FoldersChanged) and ((Old.ShowLibArtist <> New.ShowLibArtist) or
       (Old.ShowLibAlbum <> New.ShowLibAlbum) or (Old.ShowLibGenre <> New.ShowLibGenre)) then
      FLib.RefreshLibrary;
    if Old.WatchFolders <> New.WatchFolders then RestartWatcher;
    if FoldersChanged then RequestLibraryScan(False, False);
    SaveWindowSettings;
  finally
    OldFolders.Free;
    NewFolders.Free;
  end;
end;

{ the help (Aulos' Markdown window with the screenshots built in) }
procedure TMainForm.MnHelp(Sender: TObject);
begin
  ShowHelpWindow('');
end;

procedure TMainForm.MnAbout(Sender: TObject);
begin
  { ---> AulumicNS: a window of its own with the version of this program
    file (it showed a version written into the source) }
  ShowAbout(Self);
end;

procedure TMainForm.MnQuit(Sender: TObject);
begin
  Close;
end;

{ an artist of the banner's "more artists" menu (the item's Tag indexes
  FOverflowArtists; no caption as state) }
procedure TMainForm.MnOverflowArtist(Sender: TObject);
var
  I: PtrInt;
begin
  I := TAuMenuItem(Sender).Tag;
  if (I >= 0) and (I <= High(FOverflowArtists)) then
    ShowArtistInfo(Self, FLibrary, FOverflowArtists[I]);
end;

{$IFDEF DEBUG}
{ ---- screenshot mode (debug build) ---- }

{ renders the client area of the window into a PNG file: every control
  paints itself into one bitmap (RenderTo), so the capture does not depend
  on the window being composited on screen }
procedure TMainForm.CaptureWindow(const AName: string);
begin
  SaveImage(FShotDir + AName + '.png');
end;

procedure TMainForm.ShotTick(Sender: TObject);

  { --add-folder with the demo library (--make-demo-library): the playlist
    from it, with a few ratings (the stats of the run folder) }
  procedure LibraryPlaylist;
  var
    L: TTrackList;
    Idx: TIntArray;
    I: Integer;
  begin
    if not FDebugScan then Exit;
    L := TTrackList.Create;
    try
      FLibrary.GetTracksByArtist('The Example Quartet', L);
      if L.Count = 0 then Exit;
      FPl.AddTracks(L);
    finally
      L.Free;
    end;
    SetLength(Idx, 1);
    for I := 0 to FPl.EntryCount - 1 do
      if I mod 3 <> 2 then
      begin
        Idx[0] := I;
        FPl.RateEntries(Idx, 5 - I mod 4);
      end;
  end;

  { the banner as if the first playlist track played (the demo library's
    cover), else made-up names }
  procedure DemoBanner;
  var
    E: TPlEntry;
    B: TGfxBitmap;
    Gi, Gc, Gt, I: Integer;
  begin
    FBanner.Playing := True;
    if FDebugScan and (FPl.EntryCount > 0) and not FPl.IsDemo then
    begin
      E := FPl.Entry(0);
      FBanner.Title := E.Title;
      FBanner.Album := E.Album;
      FBanner.Genre := E.Genre;
      FBanner.SetArtists([E.Artist]);
      FBanner.Resolution := Format('%d bit / %s', [E.BitDepth, FormatRateKHz(E.SampleRate)]);
      FBanner.RateText := 'Bit-Perfect: ' + FormatRateKHz(E.SampleRate);
      FPl.GroupInfo(0, Gi, Gc, Gt);
      FBanner.Meta := Format('Track %d of %d  •  1:24 / %s', [Gi, Gc, FormatDuration(Gt)]);
      FBanner.HasBooklet := FileExists(LongPath(ExtractFilePath(E.FilePath) + E.Album + ' - Booklet.pdf'));
      B := nil;
      if FileExists(LongPath(ExtractFilePath(E.FilePath) + 'folder.jpg')) then
        B := ImageFromFile(ExtractFilePath(E.FilePath) + 'folder.jpg', 640);
      FBanner.SetCover(B);
      if B <> nil then
      begin
        FBanner.AmbientColor := CoverAmbientColor(B);
        DisposeBitmap(B);
      end;
    end
    else
    begin
      FBanner.Title := 'Morning Over the Bridge';
      FBanner.Album := 'First Light';
      FBanner.Genre := 'Jazz';
      FBanner.SetArtists(['The Example Quartet', 'Jonas Marlow']);
      FBanner.Resolution := '16 bit / 44.1 kHz';
      FBanner.RateText := 'Bit-Perfect: 44.1 kHz';
      FBanner.Meta := 'Track 1 of 8  •  1:24 / 47:18';
      FBanner.HasBooklet := True;
    end;
    FBanner.Codec := 'FLAC';
    FBanner.Channels := 'Stereo';
    FBanner.Badge := bbBitPerfect;
    FBanner.BadgeText := 'Bit-perfect';
    FBanner.Meter.Active := True;
    { (about -16 / -18 dBFS: up to the amber; the meter rises 35 % of the
      way per read, so it reads a while) }
    for I := 1 to 30 do FBanner.Meter.SetLevels(0.16, 0.12);
    FBanner.Changed;
  end;

  { the position bar and its two times as the banner says: 1:24 into the
    first track (they stayed at 00:00 under a banner that said 1:24) }
  procedure DemoPosition;
  const
    AT_SEC = 84;
  var
    Total: string;
    Sec, C: Integer;
  begin
    Total := '5:12';
    if FDebugScan and (FPl.EntryCount > 0) and not FPl.IsDemo and (FPl.Entry(0).DurationStr <> '') then
      Total := FPl.Entry(0).DurationStr;
    { m:ss (the demo library has no track of an hour) }
    C := Pos(':', Total);
    Sec := StrToIntDef(Copy(Total, 1, C - 1), 0) * 60 + StrToIntDef(Copy(Total, C + 1, 2), 0);
    if Sec <= AT_SEC then Sec := 312;
    FTransport.Seek.Enabled := True;
    FTransport.Seek.Position := AT_SEC / Sec;
    FTransport.LblPos.Caption := FormatDuration(AT_SEC);
    FTransport.LblTotal.Caption := Total;
  end;
var
  N: TAuTreeNode;
  ShotNodes: TAuTreeNodeArray;
  I, J: Integer;
begin
  { --add-folder: the scan first (at most about a minute) }
  if FDebugScan and (FShotStep = 0) and (FShotWait < 90) and
     ((not FStartupScanDone) or FLibrary.IsScanning) then
  begin
    Inc(FShotWait);
    Exit;
  end;
  case FShotStep of
    0: begin
         SetTheme(tmDark, AccentIndex);
         { the help shows no device of this computer, and a window of the
           same size on every screen }
         FTransport.SetDeviceName('USB Audio DAC');
         WindowState := wsNormal;
         SetBounds(Left, Top, S(1320), S(820));
         LibraryPlaylist;
         DemoBanner;
       end;
    1: CaptureWindow('01-dark-main');
    2: begin FTransport.SetPlaying(True); FPl.List.SelectOnly(3); DemoPosition; end;
    3: CaptureWindow('02-dark-playing');
    4: SetTheme(tmLight, AccentIndex);
    5: CaptureWindow('03-light-playing');
    6: begin FBanner.Height := S(110); end;
    7: CaptureWindow('04-light-small-banner');
    8: begin SetTheme(tmDark, 2); FBanner.Height := S(200); end;
    9: CaptureWindow('05-dark-accent');
    10: begin SetTheme(tmDark, 0); FBanner.Height := S(BannerMinHeight); end;
    11: CaptureWindow('06-dark-min-banner');
    12: FBanner.Height := S(BannerMinHeight + 20);
    13: CaptureWindow('07-dark-min-banner-meter');
    14: begin
          { the library: Folders and the first library folder open }
          FBanner.Height := S(200);
          if FLib.Tree.RootCount > 0 then
          begin
            N := FLib.Tree.Roots(0);
            N.Expanded := True;
            if N.Count > 0 then N[0].Expanded := True;
          end;
        end;
    15: CaptureWindow('08-library');
    16: begin
          { a word of the demo library: a track, an album, a compilation track }
          FLib.Search.Text := 'harbour';
          FLib.PerformSearch;
        end;
    17: CaptureWindow('09-library-search');
    18: begin
          { the first library folder sent to the playlist (nothing is played):
            the album headers with the covers of the library scan }
          FLib.ClearSearch;
          if FLib.Tree.RootCount > 0 then FLib.Tree.Roots(0).Expanded := True;
          if (FLib.Tree.RootCount > 0) and (FLib.Tree.Roots(0).Count > 0) then
          begin
            SetLength(ShotNodes, 1);
            ShotNodes[0] := FLib.Tree.Roots(0)[0];
            LibAdd(ShotNodes, True);
          end;
        end;
    19: CaptureWindow('10-library-playlist');
  else
    { the dialogs: shown (not modal), captured, freed }
    if (FShotStep - 20) mod 2 = 0 then
    begin
      FShotForm := ShotDialog((FShotStep - 20) div 2, FShotName);
      if FShotForm = nil then
      begin
        FShotTimer.Enabled := False;
        Close;
      end
      else
        FShotForm.Show;
    end
    else
    begin
      FShotForm.SaveImage(FShotDir + FShotName + '.png');
      if FShotName = '24-prefs-0' then
        with TStringList.Create do
        try
          Text := PrefsPageFit(FShotForm);
          SaveToFile(FShotDir + 'prefs-fit.txt');
        finally
          Free;
        end;
      { a remembered size must bring the window back as it was: made at
        1000 x 612 (the default), it must remember 1000 x 612 }
      if FShotName = '35-properties' then
        with TStringList.Create do
        try
          FShotForm.SizeToRemember(I, J);
          Add(Format('Properties made at 1000 x 612, remembers %d x %d', [I, J]));
          SaveToFile(FShotDir + 'size-check.txt');
        finally
          Free;
        end;
      FreeAndNil(FShotForm);
    end;
  end;
  Inc(FShotStep);
end;

{ the dialogs of the screenshots, in turn; nil when all are done }
function TMainForm.ShotDialog(AIndex: Integer; out AName: string): TAuForm;
var
  SL: TStringList;
  I: Integer;
  P: PStoredPlaylist;
  Data: TList;
  ShotNodes: TAuTreeNodeArray;
  Folders: TStringList;
  Meta: TAudioMetadata;
  Tone: TAuToneForm;
  Ts: TToneState;
  Dir, Card: string;
  WasOn: Boolean;
begin
  Result := nil;
  AName := '';
  case AIndex of
    0: begin
         SetTheme(tmDark, 0);
         AName := '20-dialog-message';
         Result := CreateMessageForm('Do you want to delete the playlist "Evening"?' + LineEnding +
           'The music files are not deleted.', amQuestion, abYesNo, 'Delete playlist');
       end;
    1: begin
         SetTheme(tmLight, 0);
         AName := '21-dialog-message-light';
         Result := CreateMessageForm('The library folders were changed. Aulumic scans them now.',
           amInfo, abOK, 'Library folders');
       end;
    2: begin
         SetTheme(tmDark, 0);
         { made-up lines: the log of this run names this computer's devices
           and folders }
         AppLog.Clear;
         AddLog(APP_TITLE + ' 1.0.0.0 started', True);
         AddLog('[Settings] Output: WASAPI exclusive  ·  Speakers (USB Audio DAC)  ·  buffer 200 ms');
         AddLog('[Library] 48 tracks in 6 albums loaded (0.02 s)');
         AddLog('[Library] Watching 1 library folder for changes');
         AddLog('Opening track: 01 - Morning Over the Bridge.flac');
         AddLog('Output to DAC: 44.1 kHz / 16 bit in a 24 bit frame (bit-perfect)');
         AddWarning('[Library] M:\Archive is not available (the drive is not connected); its tracks are kept');
         AddLog('[Playback] 07 - Lamplighter.flac could not be opened: the file is in use by another program',
           False, True);
         AName := '22-log';
         Result := ShowLogWindow(Self);
       end;
    3: begin
         AName := '23-debug-queue';
         Result := ShowDebugQueue(Self, FPlayback);
       end;
    4..11, 28..32, 35:
      begin
        { Preferences. 4..10 and 28, 29: the nine pages with their cards
          closed, 24-prefs-<page>; 11: the Output page in the light theme;
          30, 31, 32, 35: a page with one card open and in view,
          24-prefs-<page>-<card> (the numbers are the ones the twelve pages
          of before had). prefs-fit.txt: the height each page needs with
          its cards closed. }
        if AIndex = 11 then SetTheme(tmLight, 0) else SetTheme(tmDark, 0);
        SL := TStringList.Create;
        WasOn := AppSettings.Data.Audio.ResamplePCM;
        Card := '';
        try
          if FLibrary <> nil then FLibrary.GetScanFolders(SL);
          case AIndex of
            11: begin I := PREFS_OUTPUT; AName := '31-prefs-light'; end;
            30: begin I := PREFS_APPEARANCE; Card := CARD_MAINWINDOW; end;
            31: begin I := PREFS_RESAMPLER; Card := CARD_FILTER; end;
            32: begin I := PREFS_SYSTEM; Card := CARD_THREAD; end;
            35: begin I := PREFS_VOLUME; Card := CARD_RGSCAN; end;
            28, 29: I := AIndex - 28 + 7;
          else
            I := AIndex - 4;
          end;
          if AIndex <> 11 then
          begin
            if Card <> '' then AName := Format('24-prefs-%d-%s', [I, Card])
            else AName := Format('24-prefs-%d', [I]);
          end;
          { the resampler page as it is used: resampling on (the default is
            off); put back at once, the screenshots leave no settings }
          if I = PREFS_RESAMPLER then AppSettings.Data.Audio.ResamplePCM := True;
          Result := CreatePrefsForm(Self, SL, I, Card);
        finally
          AppSettings.Data.Audio.ResamplePCM := WasOn;
          SL.Free;
        end;
      end;
    12: begin
          { the Playlist Manager with a few playlists (a store in the shots folder) }
          SetTheme(tmDark, 0);
          if FShotStore = nil then
          begin
            ForceDirectories(FShotDir + 'store');
            FShotStore := TPlaylistStore.Create(FShotDir + 'store\' + FILE_PLAYLISTS, LBL_DEFAULT_PLAYLIST);
            FShotStore.Load;
            { (a folder used before already has them) }
            if FShotStore.Find('Evening') = nil then FShotStore.Add('Evening', pkNormal);
            if FShotStore.Find('Road Trip') = nil then FShotStore.Add('Road Trip', pkNormal);
            P := FShotStore.Find('Top Rated');
            if P = nil then P := FShotStore.Add('Top Rated', pkAuto);
            if P <> nil then P^.Query := '%rating% >= 4';
            P := FShotStore.Find('Recently Added');
            if P = nil then P := FShotStore.Add('Recently Added', pkAuto);
            if P <> nil then P^.Query := '%added% IN LAST 30d';
          end;
          AName := '32-playlist-manager';
          Result := CreatePlaylistManagerForm(Self, FShotStore, 'Evening');
        end;
    13: begin
          AName := '33-playlist-editor';
          Result := CreatePlaylistEditorForm(Self, 'Evening', -1, '', '', '', False, True);
        end;
    14: begin
          AName := '34-autoplaylist-editor';
          Result := CreatePlaylistEditorForm(Self, 'Late Night Jazz', 0, '', '',
            '%genre% IS Jazz OR Blues;%year% >= 1955', True, True);
        end;
    15, 16, 33, 34:
      begin
        { Properties: the tracks of the first library folder (--add-folder),
          the Tags tab, then the Inspector; 33 / 34: the Tags tab small (as
          1920 x 1080 at 175 % leaves: the page scrolls) and large (the
          Comment grows) - not in the help }
        SetTheme(tmDark, 0);
        SL := TStringList.Create;
        Data := TList.Create;
        try
          if (FLibrary <> nil) and (FLib.Tree.RootCount > 0) and (FLib.Tree.Roots(0).Count > 0) then
          begin
            SetLength(ShotNodes, 1);
            ShotNodes[0] := FLib.Tree.Roots(0)[0];
            LibraryPaths(ShotNodes, SL);
          end;
          { six files for the Tags tab, one for the Inspector (its details) }
          if AIndex = 16 then I := 1 else I := 6;
          while SL.Count > I do SL.Delete(SL.Count - 1);
          for I := 0 to SL.Count - 1 do Data.Add(ReadTagRecord(SL[I]));
          case AIndex of
            15: AName := '35-properties';
            16: AName := '36-properties-inspector';
            33: AName := '35-properties-small';
          else
            AName := '35-properties-large';
          end;
          if Data.Count > 0 then Result := CreatePropertiesForm(Self, Data, FLibrary)
          else Result := nil;
          if (Result <> nil) and (AIndex = 16) then SelectPropertiesTab(Result, 1);
          if (Result <> nil) and (AIndex = 33) then
          begin
            Result.ClientWidth := S(920);
            Result.ClientHeight := S(520);
          end;
          if (Result <> nil) and (AIndex = 34) then
          begin
            Result.ClientWidth := S(1400);
            Result.ClientHeight := S(900);
          end;
        finally
          DisposeTagData(Data);
          SL.Free;
        end;
        if Result = nil then
        begin
          { no library (screenshots without --add-folder): the next dialog }
          Result := ShotDialog(AIndex + 1, AName);
        end;
      end;
    17, 18:
      begin
        { the ReplayGain scanner: scanning, then its results }
        SetTheme(tmDark, 0);
        if AIndex = 17 then AName := '37-replaygain-scan' else AName := '38-replaygain-results';
        Result := CreateReplayGainDemo(Self, AIndex = 18);
      end;
    19, 20:
      begin
        { the Virtual Folder editor, then the cover viewer: the album folders
          and the first track of the first library folder (--add-folder) }
        SL := TStringList.Create;
        try
          if (FLibrary <> nil) and (FLib.Tree.RootCount > 0) and (FLib.Tree.Roots(0).Count > 0) then
          begin
            SetLength(ShotNodes, 1);
            ShotNodes[0] := FLib.Tree.Roots(0)[0];
            LibraryPaths(ShotNodes, SL);
          end;
          if AIndex = 19 then
          begin
            Folders := TStringList.Create;
            try
              Folders.Sorted := True;
              Folders.Duplicates := dupIgnore;
              for I := 0 to SL.Count - 1 do Folders.Add(ExtractFileDir(SL[I]));
              if Folders.Count = 0 then
              begin
                Folders.Add('D:\Music\Example Quartet\First Light');
                Folders.Add('D:\Music\Example Quartet\Night Train');
              end;
              Folders.Sorted := False;
              AName := '39-virtual-folder';
              { in the library folder (its name is in the title) }
              if FDebugScan then Dir := ExpandFileName(Application.GetOptionValue('add-folder'))
              else Dir := FShotDir;
              Result := CreateVirtualFolderForm(Self, Dir, 'Late Night Favourites', Folders, False, FLibrary);
            finally
              Folders.Free;
            end;
          end
          else
          begin
            AName := '40-cover-viewer';
            if SL.Count > 0 then
            begin
              Meta := ReadTrackMetadata(SL[0], True);
              Result := CreateCoverViewer(Self, Meta, SL[0]);
            end
            else
            begin
              Meta := Default(TAudioMetadata);
              Meta.Album := 'First Light';
              Meta.AlbumArtist := 'The Example Quartet';
              Meta.SampleRate := 96000;
              Meta.BitDepth := 24;
              Meta.DurationStr := '6:12';
              Result := CreateCoverViewer(Self, Meta, '');
            end;
          end;
        finally
          SL.Free;
        end;
      end;
    21, 22:
      begin
        { Artist Info: reading, then editing in the light theme (a made-up
          artist; nothing is fetched) }
        if AIndex = 22 then SetTheme(tmLight, 0) else SetTheme(tmDark, 0);
        AName := Format('%d-artist-info', [AIndex + 20]);
        Result := CreateArtistInfoDemo(Self, 'The Example Quartet',
          'The Example Quartet is a made-up band for the screenshots of the help. ' +
          'It was founded in a rehearsal room that never existed and has recorded ' +
          'three albums of quiet, warm chamber jazz.' + LineEnding + LineEnding +
          'The biography of a real artist comes from Last.fm and is saved next to ' +
          'the program, so it is shown at once the next time. Press F2 to edit it; ' +
          'your own text and picture are kept when the information is refreshed.',
          SafeFormat(FMT_ARTIST_LIB_STATS, [3, 34]), AIndex = 22);
      end;
    23: begin
          { the cover viewer the way a click on a playlist header opens it
            (the playlist of step 18; skipped without a library) }
          SetTheme(tmDark, 0);
          AName := '43-cover-viewer-playlist';
          if (FPl.EntryCount > 0) and not FPl.IsDemo then
          begin
            FCoverEntry := FPl.Entry(0);
            ShowGroupCover(0);
            Result := CurrentCoverViewer;
          end;
          if Result = nil then Result := ShotDialog(AIndex + 1, AName);
        end;
    24: begin
          { the signal path popup with every stage active (a made-up stream) }
          SetTheme(tmDark, 0);
          AName := '44-signal-path';
          Result := CreateSignalPathDemo(Self);
        end;
    25: begin
          { the booklet viewer with the demo library's booklet (pages 2-3 as a
            spread); skipped without one }
          AName := '45-booklet';
          SL := TStringList.Create;
          try
            if FDebugScan then
            begin
              { --add-folder is the Demo Music folder or the folder above it }
              FindBooklets(ExpandFileName(Application.GetOptionValue('add-folder')) +
                '\The Example Quartet\2019 - First Light', SL);
              if SL.Count = 0 then
                FindBooklets(ExpandFileName(Application.GetOptionValue('add-folder')) +
                  '\Demo Music\The Example Quartet\2019 - First Light', SL);
            end;
            if SL.Count > 0 then
            begin
              ShowBooklet(SL, 0, 1);
              if BookletWindow is TAuForm then Result := TAuForm(BookletWindow);
            end;
          finally
            SL.Free;
          end;
          if Result = nil then Result := ShotDialog(AIndex + 1, AName);
        end;
    26: begin
          { the Tone Control window with a gentle setting }
          AName := '46-tone-control';
          Tone := TAuToneForm.CreateTone(Self);
          Ts := Default(TToneState);
          Ts.DirectMode := False;
          Ts.BassDB := 30;
          Ts.LowMidDB := -20;
          Ts.MidDB := 0;
          Ts.HighMidDB := 15;
          Ts.TrebleDB := -15;
          Ts.BassHz := 120;
          Ts.LowMidHz := 400;
          Ts.MidHz := 1000;
          Ts.HighMidHz := 4000;
          Ts.TrebleHz := 10000;
          Tone.SetValues(Ts);
          Tone.SetHeadroom(-1.4);
          Result := Tone;
        end;
    27: begin
          { the help window at the signal path (not used in the help itself) }
          AName := '47-help';
          Result := CreateHelpForm(Self, 'Signal Path');
        end;
    36: begin
          { the About window (no folder of this PC) }
          AName := '48-about';
          Result := CreateAboutForm(Self, True);
        end;
  end;
end;
{$ENDIF}

{ ---- keyboard ---- }

procedure TMainForm.KeyDown(var Key: Word; Shift: TShiftState);
var
  InEdit: Boolean;
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  InEdit := ActiveControl is TAuEdit;
  if Shift = [ssCtrl] then
    case Key of
      Ord('F'): MnSearch(nil);
      Ord('J'): JumpToNowPlaying;
      Ord('P'): MnPrefs(nil);
      Ord('T'): ShowTone;
      Ord('L'): MnLog(nil);
      Ord('D'): MnDebugQueue(nil);
      Ord('Q'): MnQuit(nil);
      Ord('O'): MnAddFiles(nil);
      Ord('M'): ToggleMute;
      Ord('S'): ShuffleClick(nil);
      Ord('R'): RepeatClick(nil);
      VK_UP: ChangeVolume(20);
      VK_DOWN: ChangeVolume(-20);
      VK_LEFT: if InEdit then Exit else SeekBy(-10);
      VK_RIGHT: if InEdit then Exit else SeekBy(10);
      VK_F5: MnRescan(nil);
      VK_TAB:
        if FLib.Tree.Focused then FPl.List.SetFocus
        else FLib.Tree.SetFocus;
      { ---> AulumicNS: the rating of the selected playlist rows (a header:
        its whole group), 0 = no rating }
      Ord('0')..Ord('5'), VK_NUMPAD0..VK_NUMPAD5:
        if InEdit or FLib.Tree.Focused then Exit
        else RateSelection(IfThen(Key >= VK_NUMPAD0, Key - VK_NUMPAD0, Key - Ord('0')));
    else
      Exit;
    end
  else if Shift = [ssAlt] then
    case Key of
      Ord('P'): MnPlaylistManager(nil);
      VK_RETURN: MnProperties(nil);
    else
      Exit;
    end
  else if Shift = [] then
    case Key of
      VK_SPACE: if InEdit then Exit else PlayPause;
      VK_F1: MnHelp(nil);
      VK_F5: MnRefresh(nil);
      VK_MEDIA_PLAY_PAUSE: PlayPause;
      VK_MEDIA_STOP: StopPlayback;
      VK_MEDIA_NEXT_TRACK: NextTrack;
      VK_MEDIA_PREV_TRACK: PrevTrack;
    else
      Exit;
    end
  else
    Exit;
  Key := 0;
end;

end.
