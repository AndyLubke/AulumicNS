program AulumicNS;

{ ==============================================================================
  AulumicNS
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  AulumicNS - bit-perfect music player (WASAPI exclusive / ASIO).
  A self-contained GUI library: one executable, no external DLLs besides
  Windows itself, no .lfm files, vector icons, live dark / light theme.
  =============================================================================}

{$mode objfpc}{$H+}

uses
  SysUtils, Windows,
  { the drawing layer (Direct2D) before the LCL: units are
    closed in the reverse order, so it is still there while the LCL destroys
    the windows at the end (a window may paint once more then) }
  AuD2D, AuGfx,
  Interfaces, Forms,
  { the GUI library }
  AuAnim, AuTheme, AuIcons, AuControls, AuMenus, AuLists, AuForms, AuTree, AuGroupList, AuExtra, AuTitleBar,
  AuFolderPicker, AuAppIcon,
  { the program }
  AuSingle, AuSettings, AuLog, AuDialogs, uAppConsts, uAppStrings, uSettingsManager, uAppLifetime,
  uPlaybackManager, AuBanner, AuTransport, AuLibraryPane, AuPlaylistPane, AuToneForm, AuVolumePopup,
  uCrashTracer, uHangWatch, uDriveKeepAlive, uInputBlock, uEngineStateManager, uFileLockRegistry, uMetadataPayloads, uMetaUtils,
  uOSUtils, uPlaybackIOWorker, {$IFDEF DEBUG}AuTouchProbe,{$ENDIF}
  { the engine (with the built-in decoders and resampler) }
  ALAudioTypes, ALAudioOutput, ALWasapiApi, ALOutputWasapi, ALOutputAsio, ALOutputRing, ALMetadata, ALReaders,
  ALReaderFLAC, ALReaderWAV, ALReaderDSF, ALReaderDFF, ALSourceFactory, ALHeadroom, ALAudioThread, ALAudioEngine,
  AuAudioTypes, AuDecoder, AuDecFlac, AuDecWav, AuDecDsd, AuResample, uToneControl, uAudioUtils,
  { the library (stored by uDbStore) }
  uDbStore, uLibraryTypes, uLibraryQuery, uTagParser, uUserStatsManager,
  uLibraryScanner, uLibraryManager, uLibraryWatcher, AuLogForm, AuDebugQueue, AuPrefs, uSettingsLog, AuPlaylistEditor, AuPlaylistManager, uMetadataCustodian, AuTagLoader, AuPropertiesForm, AuLoudness, uReplayGainScan, uReplayGainThread, AuReplayGainForm, AuVirtualFolderForm, uLastFmScraper, AuCoverViewer, AuArtistInfo, AuPdf, AuBooklet, AuSignalPath, AuDemoLibrary, AuHelp, uVersionHelper, AuAbout,
  uPlaylistFile, uPlaylistRows, uAutoPlaylist, uPlaylistImport, uPlaylistStore,
  { tags (the AulumicTag units) }
  audiotag, basetag, commonfunctions, id3v1genres, song, registerallreader, file_dsf, file_dff, file_dummy,
  file_flac, file_monkey, file_mp3, file_mp4, file_ogg, file_opus, file_wave, file_wma, tag_ape,
  tag_dummy, tag_id3v2, tag_mp4, tag_vorbis, tag_wma,
  AuMainForm;

{$R *.res}
{ the help text and its screenshots (written by Tools\MakeHelpShots.ps1) }
{$R AulumicNS_help.rc}

{ The manifest already declares per-monitor V2 DPI awareness; this is the
  fallback in case the manifest is missing (it fails harmlessly otherwise). }
procedure MakeDpiAware;
type
  TSetContext = function(Ctx: THandle): BOOL; stdcall;
  TSetAware = function: BOOL; stdcall;
const
  DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = THandle(-4);
var
  Lib: HMODULE;
  F: TSetContext;
  F2: TSetAware;
begin
  Lib := GetModuleHandle('user32.dll');
  if Lib = 0 then Exit;
  F := TSetContext(GetProcAddress(Lib, 'SetProcessDpiAwarenessContext'));
  if Assigned(F) then
  begin
    F(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    Exit;
  end;
  F2 := TSetAware(GetProcAddress(Lib, 'SetProcessDPIAware'));
  if Assigned(F2) then F2();
end;

var
  Paths: array of string;
  I: Integer;
  {$IFDEF DEBUG}
  Ok: Boolean;
  {$ENDIF}
begin
  {$IFDEF DEBUG}
  { memory leak report of the debug build goes to a file next to the exe }
  {$if declared(UseHeapTrace)}
  if UseHeapTrace then
  begin
    SysUtils.DeleteFile(ExtractFilePath(ParamStr(0)) + 'heaptrc.log');
    SetHeapTraceOutput(ExtractFilePath(ParamStr(0)) + 'heaptrc.log');
  end;
  {$endif}
  { AulumicNS.exe --make-icon=<file.ico>: writes the application icon and exits;
    --icon-preview=<file.png> [--icon-size=<px>]: the icon as a PNG (256 px) }
  { --make-demo-library=<folder>: the made-up library of the help screenshots
    into <folder>\Demo Music (AuDemoLibrary). These switches exit at once
    (the global objects freed first: no leak report). }
  if Application.HasOption('make-icon') or Application.HasOption('icon-preview') or
    Application.HasOption('make-demo-library') then
  begin
    if Application.HasOption('make-icon') then Ok := SaveAppIconFile(Application.GetOptionValue('make-icon'))
    else if Application.HasOption('icon-preview') then
      Ok := SaveAppIconPng(Application.GetOptionValue('icon-preview'),
        StrToIntDef(Application.GetOptionValue('icon-size'), 256))
    else Ok := MakeDemoLibrary(Application.GetOptionValue('make-demo-library')) > 0;
    FreeAppSingletons;
    { Exit, not Halt: the main block's strings are freed too }
    if not Ok then ExitCode := 1;
    Exit;
  end;
  { --shot-dpi=<dpi>: every window at this DPI (144 = 150 %; the help
    screenshots), whatever the monitor }
  if Application.HasOption('shot-dpi') then
  begin
    ForcedDpi := StrToIntDef(Application.GetOptionValue('shot-dpi'), 0);
    if (ForcedDpi < 48) or (ForcedDpi > 480) then ForcedDpi := 0;
    if ForcedDpi > 0 then CurDpi := ForcedDpi;
  end;
  { --d2d=software|hardware: the kind of the Direct2D render target (default:
    Direct2D chooses); for comparing with --ui-bench }
  if Application.GetOptionValue('d2d') = 'software' then GfxTargetKind := D2D1_RENDER_TARGET_TYPE_SOFTWARE
  else if Application.GetOptionValue('d2d') = 'hardware' then GfxTargetKind := D2D1_RENDER_TARGET_TYPE_HARDWARE;
  if Application.HasOption('no-gpu-paint') then GpuPaintAllowed := False;
  { --test-target-loss=<n>: see AuGfx.GfxTestLoseEvery; --font=segoe: GfxClassicFont }
  GfxTestLoseEvery := StrToIntDef(Application.GetOptionValue('test-target-loss'), 0);
  GfxClassicFont := Application.GetOptionValue('font') = 'segoe';
  { --anim-slow=<factor>: animations that many times longer (to look at them) }
  if Application.HasOption('anim-slow') then
    AnimSlowFactor := StrToIntDef(Application.GetOptionValue('anim-slow'), 1);
  {$ENDIF}
  { one AulumicNS at a time (it uses the audio device exclusively): a second
    start activates the first copy and hands over its files. Not the tool
    modes of the debug build (they play nothing and use the data next to
    their own exe): a screenshot run with AulumicNS open would hand over
    and make no pictures - MakeHelpShots would then empty help\shots. }
  if {$IFDEF DEBUG}not (Application.HasOption('shots') or Application.HasOption('ui-bench') or
    Application.HasOption('touch-probe') or Application.HasOption('test-drive-wait')) and {$ENDIF} OtherInstanceRunning then
  begin
    SetLength(Paths, 0);
    for I := 1 to ParamCount do
      if (ParamStr(I) <> '') and (ParamStr(I)[1] <> '-') then
      begin
        SetLength(Paths, Length(Paths) + 1);
        Paths[High(Paths)] := ParamStr(I);
      end;
    HandOverToRunning(Paths);
    FreeAppSingletons;
    Exit;
  end;
  MakeDpiAware;
  Application.Scaled := False;          // all sizes are scaled by AuTheme.S()
  Randomize;
  AppSettings.Load;
  {$IFDEF DEBUG}
  { the screenshots always show the default look }
  if Application.HasOption('shots') then
  begin
    AppSettings.Data.UIFontSize := 100;
    AppSettings.Data.Accent := 0;
  end;
  {$ENDIF}
  { animations: the setting; never in the tool modes of the debug build (their
    pictures and measurements want the end state at once) }
  AnimationsOn := AppSettings.Data.Animations {$IFDEF DEBUG} and not (Application.HasOption('shots') or
    Application.HasOption('ui-bench') or Application.HasOption('touch-probe')) {$ENDIF};
  if not AppSettings.Data.GpuPaint then GpuPaintAllowed := False;
  FontScale := AppSettings.Data.UIFontSize / 100;
  if AppSettings.Data.CompactRows then RowDensity := ROW_DENSITY_COMPACT;
  SetTheme(TAuThemeMode(AppSettings.Data.ThemeMode mod 3), AppSettings.Data.Accent);
  Application.Title := APP_TITLE;
  {$PUSH}{$WARN 5044 OFF}   // MainFormOnTaskBar is Windows only (as is the whole program)
  Application.MainFormOnTaskBar := True;
  {$POP}
  Application.HintPause := 450;
  Application.HintHidePause := 6000;
  { an error that nothing catches is shown in the themed message window, from
    the first moment (the main window puts its own handler in front, which
    writes the log too). The tool modes of the debug build show none: they
    write the trace and end with exit code 1. }
  {$IFDEF DEBUG}
  ErrorBoxesOff := Application.HasOption('shots') or Application.HasOption('ui-bench') or
    Application.HasOption('touch-probe') or Application.HasOption('help-probe') or Application.HasOption('test-repair') or
    Application.HasOption('test-hang') or Application.HasOption('test-drive-wait') or
    Application.HasOption('make-demo-library') or Application.HasOption('make-icon') or
    Application.HasOption('icon-preview');
  {$ENDIF}
  InstallErrorBox;
  try
    Application.Initialize;
    Application.CreateForm(TMainForm, MainForm);
    Application.Run;
  except
    on E: Exception do
    begin
      { the main window could not be built, or an error left the message loop }
      LogShutdownStepError('LPR: start or run');
      ShowErrorBox(E);
      ExitCode := 1;
    end;
  end;
  { all windows and the play thread are gone: the global objects (settings,
    log, ...) are freed; a thread still blocked by a sleeping
    drive ends with the process. Traced as the rest of the close
    (uCrashTracer: ShutdownTraceLog.txt only when something fails). }
  try
    WriteShutDownTrace('Destroying the main window');
    FreeAndNil(MainForm);
    FreeAppSingletons;
    WriteShutDownTrace('========== Shutdown Completed Successfully ==========');
  except
    LogShutdownStepError('LPR: final cleanup');
  end;
  EndProcessIfThreadsLeft;
end.
