unit uSettingsManager;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - uSettingsManager
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Loads and saves all application settings to and from the .ini file.
  =============================================================================}

interface

uses
  Classes, SysUtils, IniFiles, Forms, uPlaybackManager, uTonePresets;

type
  TWorkAreas = array of TRect;

{ Puts a window wholly on one monitor. AAreas are the work areas of the
  monitors (the screen without the taskbar). The window goes to the one it
  covers most, or - when it is on none of them, a monitor that is gone - to
  the nearest; it is made as small as that area when it is larger, and moved
  so that all of it is inside. A window that is inside an area already is
  not touched. Without areas nothing happens. }
procedure FitWindowToWorkAreas(const AAreas: array of TRect; var ALeft, ATop, AWidth, AHeight: Integer);
{ the work areas of the monitors as they are now }
function MonitorWorkAreas: TWorkAreas;

function SettingsAdjust(aNum, aMin, aMax : integer) : integer;
{ The size (96-DPI units) a tool window opens with: the
  remembered one (0 = ADefW / ADefH), at most 92 % of the work area at the
  current scaling }
procedure ToolWindowSize(ARememberedW, ARememberedH, ADefW, ADefH: Integer; out W, H: Integer);
// Tone settings written with three bands - the Mid
// setting goes to the band that has its frequency among the five (below
// 800 Hz: low mid, from 3 kHz: high mid), and the Mid band is flat at 1 kHz
procedure MoveThreeBandMid(var AMidHz, AMidDB, ALowMidHz, ALowMidDB, AHighMidHz, AHighMidDB: Integer);
// The Last.fm API key in a key file: its first line that is not empty and
// not a comment (# or ;), when that is 16 to 64 letters and digits; else ''.
// A missing, unreadable or oversized file gives '' as well.
function ReadLastFmKeyFile(const AFile: string): string;

type

  { TAppSettingsData }

  TAppSettingsData = record
    // --- UI & WINDOW SETTINGS ---
    WinLeft             : integer;
    WinTop              : integer;
    WinWidth            : integer;
    WinHeight           : integer;
    WinState            : TWindowState;
    TopPanelHeight      : integer;
    LeftPanelWidth      : integer;
    LeftPanelWidthTiles : integer;   // the library pane's width with tiles (0: as with the tree)
    ToneWinLeft         : integer;
    ToneWinTop          : integer;
    // The sizes of the cover viewer and Artist Info, in 96-DPI
    // units (their client area below the title bar; 0 = the default)
    CoverWinW, CoverWinH   : integer;
    ArtistWinW, ArtistWinH : integer;
    PropsWinW, PropsWinH   : integer;   // Properties

    LibrarySelection    : string;    // the library tree's selected node (see TLibraryPane.SaveView)
    LibraryExpanded     : string;    // its opened nodes
    LibraryTopRow       : integer;   // its first row shown
    LibraryTilesAll     : boolean;   // the tiles show all albums, not the selected node
    LibraryTilesScroll  : integer;   // how far the tiles are scrolled (unscaled pixels)
    PlaylistSelection   : string;
    ActivePlayList      : string;

    LibraryFontSize     : integer;
    PlaylistFontSize    : integer;

    ShowLibArtist       : Boolean;
    ShowLibComposer     : Boolean;
    ShowLibAlbum        : Boolean;
    ShowLibGenre        : Boolean;

    // --- GENERAL AUDIO STATE (Not part of the Engine Config) ---
    Volume              : integer;
    ModificationVersion : integer;

    // --- UI & BEHAVIOR PREFERENCES ---
    AccordionEnabled    : boolean;
    DoubleClickAction   : integer;
    LibraryTiles        : boolean;   // the library pane shows tiles, not the tree
    LibraryTileSize     : integer;   // 0 = a list .. 3 = large tiles
    LibraryTileSort     : integer;   // artist, album, year, added, composer
    LibraryTileSortRev  : boolean;   // that order backwards
    AutoRescanLibrary   : boolean;
    DarkMode            : boolean;
    DefaultGroupingMode : integer;
    DefaultHeaderFormat : string;
    DefaultTrackFormat  : string;
    // The selection moves to the track that starts playing
    CursorFollowsPlayback: Boolean;
    // An album header stays at the top of the playlist while its tracks scroll
    StickyHeaders       : Boolean;
    WorkHeadings        : Boolean;   // the playlist: the tracks of a work under a heading of their own
    // Lower rows in the playlist and the library tree
    CompactRows         : Boolean;
    ShowPeakmeter       : boolean;
    LastFMApiKey        : string;
    // Ask once after the start whether a newer version is available
    CheckUpdatesAtStart : Boolean;
    // The version the user chose not to be told about at start ('' = none)
    SkippedVersion      : string;

    // --- APPEARANCE, OUTPUT & OTHER STATE ---
    ThemeMode           : integer;   // 0 dark, 1 light, 2 follow Windows (DarkMode follows it)
    Accent              : integer;   // 0 .. AccentCount - 1
    UIFontSize          : integer;   // the whole UI text, percent (90 .. 130)
    Animations          : boolean;   // short fades and gliding movements (AuAnim)
    GpuPaint            : boolean;   // large controls drawn by the graphics card (AuControls.GpuPaintAllowed)
    Muted               : boolean;
    ShuffleMode         : integer;   // 0 off, 1 tracks, 2 albums (TShuffleMode)
    RepeatMode          : integer;   // 0 off, 1 all, 2 one
    OutputApi           : integer;   // 0 WASAPI, 1 ASIO (copied to Audio.OutputApi)
    WasapiDeviceID      : string;    // the device of each interface; Audio.DeviceID
    AsioDriverID        : string;    // is the one of the chosen interface
    WatchFolders        : boolean;
    // Where Preferences was left, until the program closes (not stored): the
    // page, and the cards that are open (ids, comma separated)
    PrefsPage           : integer;
    PrefsCards          : string;
    TonePresets         : TTonePresets;  // the saved settings of the tone control
    LastAddDir          : string;    // the folder of the last "Add Files / Folder"
    RGScanThreads       : integer;   // ReplayGain scan: tracks measured at once (1 .. RG_MAX_THREADS)
    AlwaysSaveLog       : boolean;   // AulumicNSLog.txt at every exit (else only after errors)

    // =========================================================================
    // Embedded Engine Config
    // =========================================================================
    Audio: TManagerConfig;
  end;

  { TAppSettings }

  TAppSettings = class
  private
    FIniPath: string;
    FIniFile: TMemIniFile;
    procedure AtomicSaveIniFile;
    procedure SanitizeValues;
    procedure LoadTonePresets;
  public
    Data : TAppSettingsData;

    constructor Create;
    destructor  Destroy; override;
    procedure   Load;
    procedure   Save(AForm: TForm);
    // Audio.OutputApi / DeviceID from OutputApi and the device
    // of that interface (WasapiDeviceID / AsioDriverID)
    procedure   SyncOutputDevice;
  end;

var
  AppSettings: TAppSettings;

implementation

uses Windows, uAppStrings, uAppConsts, ALAudioTypes, uOSUtils, Math, AuTheme, uPlaylistFormat, uUpdateCheck;

const
  SEC_MAIN              = 'Main';
  SEC_WINDOW            = 'Window';
  SEC_AUDIO             = 'Audio';
  SEC_LIBRARY           = 'Library';
  SEC_UI                = 'UI';
  SEC_ADVANCED          = 'Advanced';
  SEC_TONE_PRESETS      = 'TonePresets';   // Preset1 .. : one preset per key
  KEY_TONE_PRESET       = 'Preset';

  KEY_MOD_VERSION       = 'ModificationVersion';

  KEY_WIN_LEFT          = 'Left';
  KEY_WIN_TOP           = 'Top';
  KEY_WIN_WIDTH         = 'Width';
  KEY_WIN_HEIGHT        = 'Height';
  KEY_WIN_STATE         = 'WindowState';
  KEY_PANEL_TOP         = 'TopPanelHeight';
  KEY_PANEL_LEFT        = 'LeftPanelWidth';
  KEY_PANEL_LEFT_TILES  = 'LeftPanelWidthTiles';

  KEY_LIB_SELECTION     = 'LibrarySelection';
  KEY_LIB_EXPANDED      = 'LibraryExpanded';
  KEY_LIB_TOP_ROW       = 'LibraryTopRow';
  KEY_LIB_TILES_ALL     = 'LibraryTilesAll';
  KEY_LIB_TILES_SCROLL  = 'LibraryTilesScroll';
  KEY_PLAY_SELECTION    = 'PlaylistSelection';
  KEY_ACTIVE_PLAYLIST   = 'ActivePlaylist';

  KEY_LIBRARYFONTSIZE   = 'LibraryFontSize';
  KEY_DARK_MODE         = 'DarkMode';
  KEY_PLAYLISTFONTSIZE  = 'PlayListFontSize';

  KEY_SHOW_LIB_ARTIST   = 'ShowLibArtist';
  KEY_SHOW_LIB_COMPOSER = 'ShowLibComposer';
  KEY_SHOW_LIB_ALBUM    = 'ShowLibAlbum';
  KEY_SHOW_LIB_GENRE    = 'ShowLibGenre';

  KEY_GROUPING_MODE     = 'DefaultGroupingMode';
  KEY_HEADER_FORMAT     = 'DefaultHeaderFormat';
  KEY_TRACK_FORMAT      = 'DefaultTrackFormat';
  KEY_CURSOR_FOLLOWS    = 'CursorFollowsPlayback';
  KEY_STICKY_HEADERS    = 'StickyHeaders';
  KEY_WORK_HEADINGS     = 'WorkHeadings';
  KEY_COMPACT_ROWS      = 'CompactRows';

  KEY_DEVICE_ID         = 'OutputDeviceID';
  KEY_DOP               = 'UseDoP';
  KEY_RESAMPLE          = 'ResamplePCM';
  KEY_VOLUME            = 'MasterVolume';

  KEY_VOLUME_LOCKED     = 'VolumeLocked';
  KEY_PREAMP_DB         = 'PreampDB';
  KEY_ENABLE_SOFTCLIP   = 'EnableSoftClipping';
  KEY_AUTO_HEADROOM     = 'AutoHeadroom';   // automatic headroom (ALHeadroom)
  KEY_HEADROOM_MERGED   = 'HeadroomMerged'; // see TAppSettings.Load

  KEY_RESAMPLE_QUAL       = 'ResampleQuality';
  KEY_UPSAMPLE_PHASE      = 'UpsamplePhase';
  KEY_DOWNSAMPLE_PHASE    = 'DownsamplePhase';
  KEY_RESAMPLE_BANDWIDTH  = 'ResampleBandWidth';
  KEY_RESAMPLE_ANTI_ALIAS = 'ResampleAntiAlias';

  KEY_TARGET_44         = 'TargetRate44Family';
  KEY_TARGET_48         = 'TargetRate48Family';

  KEY_BUFFER_MS         = 'BufferMs';
  KEY_BYPASS_THRESHOLD  = 'BypassThreshold';

  KEY_DSD_DISABLE_RESAMPLE = 'DisableResampleForDSD';
  KEY_DSD_BUFFER_MS        = 'DSDBufferMs';
  KEY_DSD_GAIN             = 'DsdToPcmGain';
  KEY_DSD_LOWPASS          = 'DsdLowPassFilter';

  KEY_USE_HIGHRES_TIMER    = 'UseHighResTimer';
  KEY_OPTIMIZE_AFFINITY    = 'OptimizeAffinity';
  KEY_ENABLE_MMCSS         = 'EnableMMCSS';
  KEY_KEEP_DRIVES_AWAKE    = 'KeepDrivesAwake';

  KEY_RG_MODE             = 'ReplayGainMode';

  KEY_ACCORDION           = 'AccordionEnabled';
  KEY_DBL_CLICK           = 'DoubleClickAction';
  KEY_LIB_TILES           = 'LibraryTiles';
  KEY_LIB_TILE_SIZE       = 'LibraryTileSize';
  KEY_LIB_TILE_SORT       = 'LibraryTileSort';
  KEY_LIB_TILE_SORT_REV   = 'LibraryTileSortReverse';
  KEY_AUTO_RESCAN         = 'AutoRescanLibrary';

  KEY_SHOWPEAKMETER       = 'ShowPeakMeter';

  KEY_LASTFM_API_KEY      = 'LastFmAPIKey';
  KEY_CHECK_UPDATES       = 'CheckUpdatesAtStart';
  KEY_SKIPPED_VERSION     = 'SkippedVersion';

  KEY_TONE_DIRECT         = 'ToneDirect';
  KEY_TONE_BASS           = 'ToneBass';
  KEY_TONE_MID            = 'ToneMid';
  KEY_TONE_TREBLE         = 'ToneTreble';
  KEY_TONE_BASSHZ         = 'ToneBassHz';
  KEY_TONE_MIDHZ          = 'ToneMidHz';
  KEY_TONE_TREBLEHZ       = 'ToneTrebleHz';
  // The low mid and high mid bands
  KEY_TONE_LOWMID        = 'ToneLowMid';
  KEY_TONE_HIGHMID        = 'ToneHighMid';
  KEY_TONE_LOWMIDHZ       = 'ToneLowMidHz';
  KEY_TONE_HIGHMIDHZ      = 'ToneHighMidHz';
  KEY_TONE_LOWMIDWIDTH    = 'ToneLowMidWidth';
  KEY_TONE_MIDWIDTH       = 'ToneMidWidth';
  KEY_TONE_HIGHMIDWIDTH   = 'ToneHighMidWidth';
  KEY_TONE_WIN_LEFT       = 'ToneWinLeft';
  KEY_TONE_WIN_TOP        = 'ToneWinTop';
  KEY_COVER_WIN_W         = 'CoverWinWidth';
  KEY_COVER_WIN_H         = 'CoverWinHeight';
  KEY_ARTIST_WIN_W        = 'ArtistWinWidth';
  KEY_ARTIST_WIN_H        = 'ArtistWinHeight';
  KEY_PROPS_WIN_W         = 'PropertiesWinWidth';
  KEY_PROPS_WIN_H         = 'PropertiesWinHeight';

  KEY_THEME_MODE         = 'ThemeMode';
  KEY_ACCENT              = 'Accent';
  KEY_UI_FONT_SIZE        = 'UIFontSize';
  KEY_ANIMATIONS          = 'Animations';
  KEY_GPU_PAINT           = 'GpuPaint';
  KEY_MUTED               = 'Muted';
  KEY_SHUFFLE             = 'Shuffle';
  KEY_REPEAT              = 'RepeatMode';
  KEY_OUTPUT_API          = 'OutputApi';
  KEY_ASIO_DRIVER         = 'AsioDriverID';
  KEY_WATCH_FOLDERS       = 'WatchFolders';
  KEY_RG_SCAN_THREADS     = 'ReplayGainScanThreads';
  KEY_ALWAYS_SAVE_LOG     = 'AlwaysSaveLog';
  KEY_PREFS_PAGE          = 'PrefsPage';
  KEY_PREFS_CARDS         = 'PrefsCards';
  KEY_LAST_ADD_DIR        = 'LastAddDir';

  VAL_DEF_WIN_STATE       = Ord(wsMaximized);
  VAL_DEF_GROUPING_MODE   = 0; // gmAlbum
  VAL_DEF_DBL_CLICK       = 0; // Play Immediately

procedure FitWindowToWorkAreas(const AAreas: array of TRect; var ALeft, ATop, AWidth, AHeight: Integer);
var
  I, Best: Integer;
  BestCover, Cover, BestDist, Dist: Int64;
  IW, IH, CX, CY, DX, DY: Int64;
  A: TRect;
begin
  if Length(AAreas) = 0 then Exit;
  if AWidth < 1 then AWidth := 1;
  if AHeight < 1 then AHeight := 1;
  { the area the window covers most ... }
  Best := -1;
  BestCover := 0;
  for I := 0 to High(AAreas) do
  begin
    IW := Int64(Min(ALeft + AWidth, AAreas[I].Right)) - Max(ALeft, AAreas[I].Left);
    IH := Int64(Min(ATop + AHeight, AAreas[I].Bottom)) - Max(ATop, AAreas[I].Top);
    if (IW <= 0) or (IH <= 0) then Continue;
    Cover := IW * IH;
    if Cover > BestCover then
    begin
      BestCover := Cover;
      Best := I;
    end;
  end;
  { ... or the one nearest to its middle }
  if Best < 0 then
  begin
    CX := Int64(ALeft) + AWidth div 2;
    CY := Int64(ATop) + AHeight div 2;
    BestDist := High(Int64);
    for I := 0 to High(AAreas) do
    begin
      DX := 0;
      if CX < AAreas[I].Left then DX := AAreas[I].Left - CX
      else if CX > AAreas[I].Right then DX := CX - AAreas[I].Right;
      DY := 0;
      if CY < AAreas[I].Top then DY := AAreas[I].Top - CY
      else if CY > AAreas[I].Bottom then DY := CY - AAreas[I].Bottom;
      Dist := DX * DX + DY * DY;
      if Dist < BestDist then
      begin
        BestDist := Dist;
        Best := I;
      end;
    end;
  end;
  if Best < 0 then Exit;
  A := AAreas[Best];
  if (A.Right <= A.Left) or (A.Bottom <= A.Top) then Exit;
  if AWidth > A.Right - A.Left then AWidth := A.Right - A.Left;
  if AHeight > A.Bottom - A.Top then AHeight := A.Bottom - A.Top;
  if ALeft < A.Left then ALeft := A.Left;
  if ALeft + AWidth > A.Right then ALeft := A.Right - AWidth;
  if ATop < A.Top then ATop := A.Top;
  if ATop + AHeight > A.Bottom then ATop := A.Bottom - AHeight;
end;

function MonitorWorkAreas: TWorkAreas;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Screen.MonitorCount);
  for I := 0 to Screen.MonitorCount - 1 do Result[I] := Screen.Monitors[I].WorkareaRect;
end;

function SettingsAdjust(aNum, aMin, aMax : integer) : integer;
begin
  Result := aNum;
  if Result < aMin then
    Result := aMin;
  if (aMax > 0) and (Result > aMax) then
    Result := aMax;
end;

procedure MoveThreeBandMid(var AMidHz, AMidDB, ALowMidHz, ALowMidDB, AHighMidHz, AHighMidDB: Integer);
begin
  if AMidHz < 800 then
  begin
    ALowMidHz := AMidHz;
    ALowMidDB := AMidDB;
  end
  else if AMidHz >= 3000 then
  begin
    AHighMidHz := AMidHz;
    AHighMidDB := AMidDB;
  end
  else
    Exit;
  AMidHz := VAL_DEF_MIDHZ;
  AMidDB := 0;
end;

function ReadLastFmKeyFile(const AFile: string): string;
const
  MAX_KEY_FILE_BYTES = 4096;
var
  FS: TFileStream;
  Raw, Line: string;
  SL: TStringList;
  I, K: Integer;
  Good: Boolean;
begin
  Result := '';
  if not FileExists(AFile) then Exit;
  try
    FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      if (FS.Size <= 0) or (FS.Size > MAX_KEY_FILE_BYTES) then Exit;
      SetLength(Raw, FS.Size);
      FS.ReadBuffer(Raw[1], FS.Size);
    finally
      FS.Free;
    end;
    // a UTF-8 byte order mark, as Notepad may write one
    if Copy(Raw, 1, 3) = #$EF#$BB#$BF then Delete(Raw, 1, 3);
    SL := TStringList.Create;
    try
      SL.Text := Raw;
      for I := 0 to SL.Count - 1 do
      begin
        Line := Trim(SL[I]);
        if (Line = '') or (Line[1] = '#') or (Line[1] = ';') then Continue;
        Good := (Length(Line) >= 16) and (Length(Line) <= 64);
        if Good then
          for K := 1 to Length(Line) do
            if not (Line[K] in ['0'..'9', 'A'..'Z', 'a'..'z']) then
            begin
              Good := False;
              Break;
            end;
        if Good then Result := Line;
        Break;
      end;
    finally
      SL.Free;
    end;
  except
    Result := '';
  end;
end;

procedure ToolWindowSize(ARememberedW, ARememberedH, ADefW, ADefH: Integer; out W, H: Integer);
var
  K: Double;
begin
  if (ARememberedW >= 200) and (ARememberedH >= 200) then
  begin
    W := ARememberedW;
    H := ARememberedH;
  end
  else
  begin
    W := ADefW;
    H := ADefH;
  end;
  K := UIScale;
  if K <= 0 then K := 1;
  { (the title bar of about 40 px is outside H) }
  W := Min(W, Round(Screen.WorkAreaWidth * 0.92 / K));
  H := Min(H, Round(Screen.WorkAreaHeight * 0.92 / K) - 40);
end;

// True when the file exists, is not empty and contains at least one [Section]
// header. A file truncated or zero-filled by a crash / power loss fails this
// check, so it is never loaded and never copied over the backup.
function IniFileLooksValid(const APath: string): Boolean;
var
  SL : TStringList;
  I  : Integer;
  S  : string;
begin
  Result := False;
  if not FileExists(APath) then
    Exit;

  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(APath);
      for I := 0 to SL.Count - 1 do
      begin
        S := Trim(SL[I]);
        if (Length(S) > 2) and (S[1] = '[') and (S[Length(S)] = ']') then
          Exit(True);
      end;
    except
      Result := False;
    end;
  finally
    SL.Free;
  end;
end;

// Copies ASource to ATarget through a flushed temp file plus an
// atomic rename, so ATarget is always either the old or the complete new copy.
function CopyFileAtomic(const ASource, ATarget: string): Boolean;
var
  MS: TMemoryStream;
begin
  Result := False;
  MS := TMemoryStream.Create;
  try
    try
      MS.LoadFromFile(ASource);
      Result := SaveStreamAtomic(MS, ATarget, True);
    except
      Result := False;
    end;
  finally
    MS.Free;
  end;
end;

// Durable write-through flush of an already written file
function FlushFileToDisk(const APath: string): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  try
    FS := TFileStream.Create(APath, fmOpenReadWrite or fmShareExclusive);
    try
      Result := FileFlush(FS.Handle);
    finally
      FS.Free;
    end;
  except
    Result := False;
  end;
end;

{ TAppSettings }

// Crash-safe settings save.
//  1. TMemIniFile writes to <ini>.tmp (same encoding; clears Dirty).
//  2. The temp file is flushed to disk; on failure nothing is replaced.
//  3. The current ini is COPIED (not moved) to <ini>.bak, and only when it is
//     valid, so a damaged ini can never overwrite a good backup.
//  4. The temp file atomically replaces the ini (MoveFileEx write-through).
// At every moment a complete ini and/or a complete backup exists on disk.
procedure TAppSettings.AtomicSaveIniFile;
var
  BackupPath : string;
  TempPath   : string;
begin
  BackupPath := FIniPath + '.bak';
  TempPath   := FIniPath + '.tmp';

  try
    if FileExists(TempPath) then
      SysUtils.DeleteFile(TempPath);

    FIniFile.Rename(TempPath, False);
    try
      FIniFile.UpdateFile;
    finally
      FIniFile.Rename(FIniPath, False);
    end;

    if not FlushFileToDisk(TempPath) then
    begin
      SysUtils.DeleteFile(TempPath);
      Exit;
    end;

    if IniFileLooksValid(FIniPath) then
      CopyFileAtomic(FIniPath, BackupPath);

    CommitAtomicFile(TempPath, FIniPath, True);
  except
    // The original ini (or its backup) is still intact; just drop the temp file
    try
      if FileExists(TempPath) then
        SysUtils.DeleteFile(TempPath);
    except
      // Silent
    end;
  end;
end;

constructor TAppSettings.Create;
var
  BackupPath: string;
begin
  FIniPath   := AppIniPath;
  BackupPath := FIniPath + '.bak';

  // Restore the backup when the ini is missing OR damaged
  // (empty / truncated by a crash). The backup itself is kept (copied, not moved).
  if (not IniFileLooksValid(FIniPath)) and IniFileLooksValid(BackupPath) then
  try
    CopyFileAtomic(BackupPath, FIniPath);
  except
    // silent fail
  end;

  FIniFile              := TMemIniFile.Create(FIniPath);
  Data.LibraryFontSize  := FONT_LISTDEFAULTSIZE;
  Data.PlayListFontSize := FONT_LISTDEFAULTSIZE;
end;

destructor TAppSettings.Destroy;
begin
  FIniFile.Free;
  inherited Destroy;
end;

{ The system DPI from Windows itself; Screen.PixelsPerInch
  is still 96 when Load runs (before Application.Initialize) }
function SystemDpi: Integer;
var
  DC: HDC;
begin
  Result := 0;
  DC := GetDC(0);
  if DC <> 0 then
  begin
    Result := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(0, DC);
  end;
  if Result < 48 then Result := 96;
end;

procedure TAppSettings.Load;
var
  LPanelW : integer;
  WorkW   : integer;
begin
  { The panel widths are logical pixels (S() scales them),
    the work area is physical: at 225 % a quarter of it would be 960 "logical"
    pixels (the library pane would take a narrow window's whole width) }
  WorkW := Round(Screen.WorkAreaWidth * 96 / SystemDpi);
  Data.WinState := TWindowState(FIniFile.ReadInteger(SEC_WINDOW, KEY_WIN_STATE, VAL_DEF_WIN_STATE));

  Data.WinLeft  := FIniFile.ReadInteger(SEC_WINDOW, KEY_WIN_LEFT, VAL_UNINITIALIZED_POS);
  Data.WinTop   := FIniFile.ReadInteger(SEC_WINDOW, KEY_WIN_TOP,  VAL_UNINITIALIZED_POS);

  Data.WinWidth := SettingsAdjust(FIniFile.ReadInteger(SEC_WINDOW, KEY_WIN_WIDTH,
                DEFAULT_FORM_WIDTH), MIN_FORM_WIDTH, 0);
  Data.WinHeight := SettingsAdjust(FIniFile.ReadInteger(SEC_WINDOW, KEY_WIN_HEIGHT,
                DEFAULT_FORM_HEIGHT), MIN_FORM_HEIGHT, 0);

  if Data.WinState = wsMaximized then
    LPanelW := Round(WorkW * 0.25)
  else
    LPanelW := DEFAULT_LPANEL_WIDTH;

  Data.TopPanelHeight := FIniFile.ReadInteger(SEC_WINDOW, KEY_PANEL_TOP,  UI_TOP_PANEL_DEFAULTHEIGHT);
  Data.LeftPanelWidth := FIniFile.ReadInteger(SEC_WINDOW, KEY_PANEL_LEFT, LPanelW);

  if Data.WinState = wsMaximized then
    Data.LeftPanelWidth := SettingsAdjust(Data.LeftPanelWidth, MIN_LPANEL_WIDTH,
                        WorkW - MIN_RPANEL_WIDTH)
  else
    Data.LeftPanelWidth := SettingsAdjust(Data.LeftPanelWidth, MIN_LPANEL_WIDTH,
                      Data.WinWidth - MIN_RPANEL_WIDTH);

  Data.ToneWinLeft       := FIniFile.ReadInteger(SEC_WINDOW, KEY_TONE_WIN_LEFT, VAL_UNINITIALIZED_POS);
  Data.ToneWinTop        := FIniFile.ReadInteger(SEC_WINDOW, KEY_TONE_WIN_TOP,  VAL_UNINITIALIZED_POS);
  Data.CoverWinW         := FIniFile.ReadInteger(SEC_WINDOW, KEY_COVER_WIN_W, 0);
  Data.CoverWinH         := FIniFile.ReadInteger(SEC_WINDOW, KEY_COVER_WIN_H, 0);
  Data.ArtistWinW        := FIniFile.ReadInteger(SEC_WINDOW, KEY_ARTIST_WIN_W, 0);
  Data.ArtistWinH        := FIniFile.ReadInteger(SEC_WINDOW, KEY_ARTIST_WIN_H, 0);
  Data.PropsWinW         := FIniFile.ReadInteger(SEC_WINDOW, KEY_PROPS_WIN_W, 0);
  Data.PropsWinH         := FIniFile.ReadInteger(SEC_WINDOW, KEY_PROPS_WIN_H, 0);
  Data.LibrarySelection  := FIniFile.ReadString(SEC_WINDOW, KEY_LIB_SELECTION, '');
  Data.LibraryExpanded   := FIniFile.ReadString(SEC_WINDOW, KEY_LIB_EXPANDED, '');
  Data.LibraryTopRow     := FIniFile.ReadInteger(SEC_WINDOW, KEY_LIB_TOP_ROW, 0);
  Data.LibraryTilesAll   := FIniFile.ReadBool(SEC_WINDOW, KEY_LIB_TILES_ALL, False);
  Data.LibraryTilesScroll := FIniFile.ReadInteger(SEC_WINDOW, KEY_LIB_TILES_SCROLL, 0);
  Data.PlaylistSelection := FIniFile.ReadString(SEC_WINDOW, KEY_PLAY_SELECTION, '');
  Data.ActivePlaylist    := FIniFile.ReadString(SEC_UI, KEY_ACTIVE_PLAYLIST, LBL_DEFAULT_PLAYLIST);

  Data.LibraryFontSize   := FIniFile.ReadInteger(SEC_UI, KEY_LIBRARYFONTSIZE,  FONT_LISTDEFAULTSIZE);
  Data.PlayListFontSize  := FIniFile.ReadInteger(SEC_UI, KEY_PLAYLISTFONTSIZE, FONT_LISTDEFAULTSIZE);

  Data.LibraryFontSize   := SettingsAdjust(Data.LibraryFontSize,  FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  Data.PlayListFontSize  := SettingsAdjust(Data.PlayListFontSize, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);

  Data.Audio.DeviceID    := FIniFile.ReadString(SEC_AUDIO, KEY_DEVICE_ID, '');
  // DoP on by default (as the help describes the first start)
  Data.Audio.UseDoP      := FIniFile.ReadBool(SEC_AUDIO, KEY_DOP, True);
  Data.Audio.ResamplePCM := FIniFile.ReadBool(SEC_AUDIO, KEY_RESAMPLE, False);
  Data.Volume            := FIniFile.ReadInteger(SEC_AUDIO, KEY_VOLUME, VAL_DEF_VOLUME);

  Data.ModificationVersion := FIniFile.ReadInteger(SEC_MAIN, KEY_MOD_VERSION, 1);

  if Data.ModificationVersion < 2 then
  begin
    if Data.Volume <= 100 then
      Data.Volume := Data.Volume * 10;

    Data.ModificationVersion := 2;
  end;

  Data.Audio.VolumeLocked       := FIniFile.ReadBool(SEC_AUDIO, KEY_VOLUME_LOCKED, False);
  Data.Audio.PreampDB           := FIniFile.ReadInteger(SEC_AUDIO, KEY_PREAMP_DB, VAL_DEF_PREAMP_DB);
  Data.Audio.EnableSoftClipping := FIniFile.ReadBool(SEC_AUDIO, KEY_ENABLE_SOFTCLIP, False);
  // On unless switched off
  Data.Audio.AutoHeadroom       := FIniFile.ReadBool(SEC_AUDIO, KEY_AUTO_HEADROOM, True);
  // The automatic headroom and the preamp are one setting (Automatic, or a
  // fixed value). A settings file without the HeadroomMerged key goes to
  // Automatic once.
  if not FIniFile.ReadBool(SEC_AUDIO, KEY_HEADROOM_MERGED, False) then
  begin
    Data.Audio.AutoHeadroom := True;
    Data.Audio.PreampDB     := 0;
  end;
  // Automatic has no fixed preamp
  if Data.Audio.AutoHeadroom then
    Data.Audio.PreampDB := 0;

  Data.Audio.ResampleQuality    := FIniFile.ReadInteger(SEC_AUDIO, KEY_RESAMPLE_QUAL,    VAL_DEF_RESAMPLE_QUAL);
  Data.Audio.UpsamplePhase      := FIniFile.ReadInteger(SEC_AUDIO, KEY_UPSAMPLE_PHASE,   VAL_DEF_UPSAMPLE_PHASE);
  Data.Audio.DownsamplePhase    := FIniFile.ReadInteger(SEC_AUDIO, KEY_DOWNSAMPLE_PHASE, VAL_DEF_DOWNSAMPLE_PHASE);

  Data.Audio.ResampleBandWidthIndex := FIniFile.ReadInteger(SEC_AUDIO, KEY_RESAMPLE_BANDWIDTH,  VAL_DEF_BANDWIDTH_IDX);
  Data.Audio.ResampleAntiAliasIndex := FIniFile.ReadInteger(SEC_AUDIO, KEY_RESAMPLE_ANTI_ALIAS, VAL_DEF_ANTI_ALIAS_IDX);

  Data.Audio.BypassThreshold    := FIniFile.ReadInteger(SEC_AUDIO, KEY_BYPASS_THRESHOLD, VAL_DEF_BYPASS_THRESH);

  Data.Audio.TargetSampleRate44 := FIniFile.ReadInteger(SEC_AUDIO, KEY_TARGET_44, VAL_DEF_SAMPLERATE44);
  Data.Audio.TargetSampleRate48 := FIniFile.ReadInteger(SEC_AUDIO, KEY_TARGET_48, VAL_DEF_SAMPLERATE48);

  Data.Audio.PCMBufferMs            := FIniFile.ReadInteger(SEC_AUDIO, KEY_BUFFER_MS, VAL_DEF_PCMBUFFER);
  Data.Audio.DisableResampleForDSD  := FIniFile.ReadBool(SEC_AUDIO, KEY_DSD_DISABLE_RESAMPLE, True);
  Data.Audio.DSDBufferMs            := FIniFile.ReadInteger(SEC_AUDIO, KEY_DSD_BUFFER_MS, VAL_DEF_DSDBUFFER);
  Data.Audio.DsdToPcmGain           := FIniFile.ReadInteger(SEC_AUDIO, KEY_DSD_GAIN, VAL_DEF_DSDGAIN);
  Data.Audio.DsdLowPassFilter       := FIniFile.ReadBool(SEC_AUDIO, KEY_DSD_LOWPASS, True);
  Data.Audio.ReplayGainMode         := FIniFile.ReadInteger(SEC_AUDIO, KEY_RG_MODE, VAL_DEF_RG_MODE);

  Data.Audio.ToneDirect   := FIniFile.ReadBool(SEC_AUDIO, KEY_TONE_DIRECT, True);
  Data.Audio.ToneBassDB   := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_BASS,   0);
  Data.Audio.ToneMidDB    := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_MID,    0);
  Data.Audio.ToneTrebleDB := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_TREBLE, 0);

  Data.Audio.ToneBassHz   := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_BASSHZ,   VAL_DEF_BASSHZ);
  Data.Audio.ToneMidHz    := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_MIDHZ,    VAL_DEF_MIDHZ);
  Data.Audio.ToneTrebleHz := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_TREBLEHZ, VAL_DEF_TREBLEHZ);

  // The low mid and high mid bands
  Data.Audio.ToneLowMidDB := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_LOWMID,    0);
  Data.Audio.ToneHighMidDB := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_HIGHMID,   0);
  Data.Audio.ToneLowMidHz  := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_LOWMIDHZ,  VAL_DEF_LOWMIDHZ);
  Data.Audio.ToneHighMidHz := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_HIGHMIDHZ, VAL_DEF_HIGHMIDHZ);
  Data.Audio.ToneLowMidWidth  := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_LOWMIDWIDTH,  TONE_WIDTH_NORMAL);
  Data.Audio.ToneMidWidth     := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_MIDWIDTH,     TONE_WIDTH_NORMAL);
  Data.Audio.ToneHighMidWidth := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_HIGHMIDWIDTH, TONE_WIDTH_NORMAL);
  // Settings written with three bands: the Mid band could be at 220 Hz ..
  // 3 kHz. Its setting moves to the band that has that frequency now, so it
  // sounds as it did (the filters are the same; a band at 0 dB is skipped).
  if not FIniFile.ValueExists(SEC_AUDIO, KEY_TONE_LOWMIDHZ) then
    MoveThreeBandMid(Data.Audio.ToneMidHz, Data.Audio.ToneMidDB,
      Data.Audio.ToneLowMidHz, Data.Audio.ToneLowMidDB,
      Data.Audio.ToneHighMidHz, Data.Audio.ToneHighMidDB);

  Data.AccordionEnabled  := FIniFile.ReadBool(SEC_LIBRARY, KEY_ACCORDION, False);
  Data.DoubleClickAction := FIniFile.ReadInteger(SEC_LIBRARY, KEY_DBL_CLICK, VAL_DEF_DBL_CLICK);
  Data.LibraryTiles      := FIniFile.ReadBool(SEC_LIBRARY, KEY_LIB_TILES, False);
  Data.LeftPanelWidthTiles := FIniFile.ReadInteger(SEC_WINDOW, KEY_PANEL_LEFT_TILES, 0);
  Data.LibraryTileSize   := FIniFile.ReadInteger(SEC_LIBRARY, KEY_LIB_TILE_SIZE, 2);
  Data.LibraryTileSort   := FIniFile.ReadInteger(SEC_LIBRARY, KEY_LIB_TILE_SORT, 0);
  Data.LibraryTileSortRev := FIniFile.ReadBool(SEC_LIBRARY, KEY_LIB_TILE_SORT_REV, False);
  Data.AutoRescanLibrary := FIniFile.ReadBool(SEC_LIBRARY, KEY_AUTO_RESCAN, False);

  Data.DarkMode          := FIniFile.ReadBool(SEC_UI, KEY_DARK_MODE, True);
  Data.ShowLibArtist     := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_ARTIST, True);
  Data.ShowLibComposer   := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_COMPOSER, False);
  Data.ShowLibAlbum      := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_ALBUM,  True);
  Data.ShowLibGenre      := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_GENRE,  True);

  Data.DefaultGroupingMode := FIniFile.ReadInteger(SEC_UI, KEY_GROUPING_MODE, VAL_DEF_GROUPING_MODE);
  Data.DefaultHeaderFormat := FIniFile.ReadString(SEC_UI, KEY_HEADER_FORMAT, FMT_DEFAULT[fkHeader]);
  Data.DefaultTrackFormat  := FIniFile.ReadString(SEC_UI, KEY_TRACK_FORMAT,  FMT_DEFAULT[fkTrack]);
  Data.CursorFollowsPlayback := FIniFile.ReadBool(SEC_UI, KEY_CURSOR_FOLLOWS, True);
  Data.StickyHeaders := FIniFile.ReadBool(SEC_UI, KEY_STICKY_HEADERS, True);
  Data.WorkHeadings  := FIniFile.ReadBool(SEC_UI, KEY_WORK_HEADINGS, True);
  Data.CompactRows   := FIniFile.ReadBool(SEC_UI, KEY_COMPACT_ROWS, False);

  Data.ShowPeakMeter := FIniFile.ReadBool(SEC_UI, KEY_SHOWPEAKMETER, True);
  // No key is built in (the source is public): the user's own
  // key, entered in Preferences > System > Internet. While none is
  // set, a key file next to the program file is taken over; Save then keeps
  // it in the settings, so the file is only needed once.
  Data.LastFmApiKey  := Trim(FIniFile.ReadString(SEC_ADVANCED, KEY_LASTFM_API_KEY, ''));
  if Data.LastFmApiKey = '' then
    Data.LastFmApiKey := ReadLastFmKeyFile(ExtractFilePath(ParamStr(0)) + FILE_LASTFM_KEY);
  Data.CheckUpdatesAtStart := FIniFile.ReadBool(SEC_ADVANCED, KEY_CHECK_UPDATES, False);
  Data.SkippedVersion := Trim(FIniFile.ReadString(SEC_ADVANCED, KEY_SKIPPED_VERSION, ''));

  Data.Audio.UseHighResTimer  := FIniFile.ReadBool(SEC_AUDIO, KEY_USE_HIGHRES_TIMER, True);
  Data.Audio.OptimizeAffinity := FIniFile.ReadBool(SEC_AUDIO, KEY_OPTIMIZE_AFFINITY, True);
  Data.Audio.EnableMMCSS      := FIniFile.ReadBool(SEC_AUDIO, KEY_ENABLE_MMCSS, True);
  Data.Audio.KeepDrivesAwake  := FIniFile.ReadBool(SEC_AUDIO, KEY_KEEP_DRIVES_AWAKE, False);

  Data.ThemeMode   := SettingsAdjust(FIniFile.ReadInteger(SEC_UI, KEY_THEME_MODE, 0), 0, 2);
  Data.DarkMode     := Data.ThemeMode <> 1;
  Data.Accent       := SettingsAdjust(FIniFile.ReadInteger(SEC_UI, KEY_ACCENT, 0), 0, 5);
  Data.UIFontSize   := SettingsAdjust(FIniFile.ReadInteger(SEC_UI, KEY_UI_FONT_SIZE, 100), 80, 130);
  Data.Animations   := FIniFile.ReadBool(SEC_UI, KEY_ANIMATIONS, True);
  Data.GpuPaint     := FIniFile.ReadBool(SEC_UI, KEY_GPU_PAINT, True);
  Data.Muted        := FIniFile.ReadBool(SEC_AUDIO, KEY_MUTED, False);
  Data.ShuffleMode  := SettingsAdjust(FIniFile.ReadInteger(SEC_AUDIO, KEY_SHUFFLE, 0), 0, 2);
  Data.RepeatMode   := SettingsAdjust(FIniFile.ReadInteger(SEC_AUDIO, KEY_REPEAT, 0), 0, 2);
  Data.OutputApi    := SettingsAdjust(FIniFile.ReadInteger(SEC_AUDIO, KEY_OUTPUT_API, 0), 0, 1);
  Data.WasapiDeviceID := Data.Audio.DeviceID;
  Data.AsioDriverID := FIniFile.ReadString(SEC_AUDIO, KEY_ASIO_DRIVER, '');
  // on by default (network folders are never watched)
  Data.WatchFolders := FIniFile.ReadBool(SEC_LIBRARY, KEY_WATCH_FOLDERS, True);
  Data.RGScanThreads := FIniFile.ReadInteger(SEC_ADVANCED, KEY_RG_SCAN_THREADS, 1);
  Data.AlwaysSaveLog := FIniFile.ReadBool(SEC_ADVANCED, KEY_ALWAYS_SAVE_LOG, False);
  { Preferences opens on its first page with every card closed }
  Data.PrefsPage    := 0;
  Data.PrefsCards   := '';
  LoadTonePresets;
  Data.LastAddDir   := FIniFile.ReadString(SEC_UI, KEY_LAST_ADD_DIR, '');
  SyncOutputDevice;

  SanitizeValues;
end;

procedure TAppSettings.SyncOutputDevice;
begin
  Data.Audio.OutputApi     := Data.OutputApi;
  // "Play DSD natively": DoP over WASAPI, native DSD over ASIO where possible
  Data.Audio.AsioNativeDsd := Data.Audio.UseDoP;
  if Data.OutputApi = 1 then
    Data.Audio.DeviceID := Data.AsioDriverID
  else
    Data.Audio.DeviceID := Data.WasapiDeviceID;
end;

{ Preset1, Preset2 ... until a number is missing; a line that is no preset is
  passed over }
procedure TAppSettings.LoadTonePresets;
var
  I: Integer;
  P: TTonePreset;
  Key: string;
begin
  Data.TonePresets := nil;
  for I := 1 to TONE_PRESET_MAX do
  begin
    Key := KEY_TONE_PRESET + IntToStr(I);
    if not FIniFile.ValueExists(SEC_TONE_PRESETS, Key) then Break;
    if TonePresetFromText(FIniFile.ReadString(SEC_TONE_PRESETS, Key, ''), P) then
    begin
      SetLength(Data.TonePresets, Length(Data.TonePresets) + 1);
      Data.TonePresets[High(Data.TonePresets)] := P;
    end;
  end;
end;

procedure TAppSettings.SanitizeValues;

  function IsValidIntOption(Value: Integer; const Options: array of TFormatDef): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := Low(Options) to High(Options) do
    begin
      if (Options[I].DataStr <> '') and
         (Value = StrToIntDef(Options[I].DataStr, VAL_SAFE_FALLBACK)) then
        Exit(True);
    end;
  end;


const
  MIN_TOOL_SIZE = 200;          // a tool window is never remembered smaller ...
  MAX_STORED_PIXELS = 20000;    // ... and no stored size is larger than this
  PREFS_PAGE_LAST = 8;          // the last page of Preferences (the dialog checks the number again)

  { a preset's frequencies are choices of their bands, and the low mid stays
    above the bass - as the tone control's own }
  procedure CheckPresetFreqs(var P: TTonePreset);
  begin
    if not IsValidIntOption(P.Hz[0], TONE_BASS_HZ_OPTIONS) then P.Hz[0] := VAL_DEF_BASSHZ;
    if not IsValidIntOption(P.Hz[1], TONE_LOWMID_HZ_OPTIONS) then P.Hz[1] := VAL_DEF_LOWMIDHZ;
    if not IsValidIntOption(P.Hz[2], TONE_MID_HZ_OPTIONS) then P.Hz[2] := VAL_DEF_MIDHZ;
    if not IsValidIntOption(P.Hz[3], TONE_HIGHMID_HZ_OPTIONS) then P.Hz[3] := VAL_DEF_HIGHMIDHZ;
    if not IsValidIntOption(P.Hz[4], TONE_TREBLE_HZ_OPTIONS) then P.Hz[4] := VAL_DEF_TREBLEHZ;
    if P.Hz[1] <= P.Hz[0] then P.Hz[1] := 300;
  end;

var
  ToneW, ToneH, I: Integer;
  SkipV: TVersionNumbers;

  procedure SaneToolSize(var W, H: Integer);
  begin
    if (W = 0) and (H = 0) then Exit;
    if (W < MIN_TOOL_SIZE) or (H < MIN_TOOL_SIZE) or (W > MAX_STORED_PIXELS) or (H > MAX_STORED_PIXELS) then
    begin
      W := 0;
      H := 0;
    end;
  end;

begin
  if (Ord(Data.WinState) < Ord(Low(TWindowState))) or
     (Ord(Data.WinState) > Ord(High(TWindowState))) then
    Data.WinState := TWindowState(VAL_DEF_WIN_STATE)
  else if Data.WinState = wsMinimized then
    Data.WinState := wsNormal;

  // The main window: wholly on a monitor that is there now, above the
  // taskbar. (The rectangle around all monitors would not do: with monitors
  // of different sizes it has corners that no monitor shows.)
  if Data.WinWidth < MIN_FORM_WIDTH then Data.WinWidth := MIN_FORM_WIDTH;
  if Data.WinHeight < MIN_FORM_HEIGHT then Data.WinHeight := MIN_FORM_HEIGHT;
  if (Data.WinLeft <> VAL_UNINITIALIZED_POS) and (Data.WinTop <> VAL_UNINITIALIZED_POS) then
    FitWindowToWorkAreas(MonitorWorkAreas, Data.WinLeft, Data.WinTop, Data.WinWidth, Data.WinHeight)
  else
  begin
    Data.WinLeft := VAL_UNINITIALIZED_POS;
    Data.WinTop := VAL_UNINITIALIZED_POS;
  end;

  // The Tone Control window: onto a monitor with its nominal size; the main
  // window fits it again with its real size when it is shown
  if (Data.ToneWinLeft = VAL_UNINITIALIZED_POS) or (Data.ToneWinTop = VAL_UNINITIALIZED_POS) then
  begin
    Data.ToneWinLeft := VAL_UNINITIALIZED_POS;
    Data.ToneWinTop := VAL_UNINITIALIZED_POS;
  end
  else
  begin
    ToneW := FORM_TONE_POPUP_WIDTH;
    ToneH := FORM_TONE_POPUP_HEIGHT;
    FitWindowToWorkAreas(MonitorWorkAreas, Data.ToneWinLeft, Data.ToneWinTop, ToneW, ToneH);
  end;

  // The remembered sizes of the tool windows (96-DPI units; 0 = none): a
  // size that cannot be right is forgotten, the window opens at its default
  SaneToolSize(Data.CoverWinW, Data.CoverWinH);
  SaneToolSize(Data.ArtistWinW, Data.ArtistWinH);
  SaneToolSize(Data.PropsWinW, Data.PropsWinH);

  // The panes (unscaled; the main window fits them to its own size)
  Data.TopPanelHeight := SettingsAdjust(Data.TopPanelHeight, 0, MAX_STORED_PIXELS);
  Data.LeftPanelWidth := SettingsAdjust(Data.LeftPanelWidth, 0, MAX_STORED_PIXELS);
  Data.LeftPanelWidthTiles := SettingsAdjust(Data.LeftPanelWidthTiles, 0, MAX_STORED_PIXELS);
  if Data.LibraryTopRow < 0 then Data.LibraryTopRow := 0;
  if Data.LibraryTilesScroll < 0 then Data.LibraryTilesScroll := 0;
  Data.LibraryFontSize  := SettingsAdjust(Data.LibraryFontSize,  FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  Data.PlayListFontSize := SettingsAdjust(Data.PlayListFontSize, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  Data.ThemeMode  := SettingsAdjust(Data.ThemeMode, 0, 2);
  Data.Accent     := SettingsAdjust(Data.Accent, 0, 5);
  Data.UIFontSize := SettingsAdjust(Data.UIFontSize, 80, 130);
  Data.PrefsPage := SettingsAdjust(Data.PrefsPage, 0, PREFS_PAGE_LAST);

  if Trim(Data.ActivePlaylist) = '' then
    Data.ActivePlaylist := LBL_DEFAULT_PLAYLIST;

  { a skipped version is a version number or nothing }
  if not ParseVersion(Data.SkippedVersion, SkipV) then Data.SkippedVersion := '';

  if not IsFieldFormat(fkHeader, Data.DefaultHeaderFormat) then
    Data.DefaultHeaderFormat := FMT_DEFAULT[fkHeader];

  if not IsFieldFormat(fkTrack, Data.DefaultTrackFormat) then
    Data.DefaultTrackFormat := FMT_DEFAULT[fkTrack];

  Data.Volume := SettingsAdjust(Data.Volume, VAL_MIN_VOLUME, VAL_MAX_VOLUME);

  if not IsValidIntOption(Data.RGScanThreads, RG_THREADS_OPTIONS) then
    Data.RGScanThreads := 1;

  Data.Audio.PreampDB := Round(Data.Audio.PreampDB);
  if not IsValidIntOption(Round(Data.Audio.PreampDB), PREAMP_DB_OPTIONS) then
    Data.Audio.PreampDB := VAL_DEF_PREAMP_DB;

  if not IsValidIntOption(Data.Audio.DsdToPcmGain, DSD_GAIN_OPTIONS) then
    Data.Audio.DsdToPcmGain := VAL_DEF_DSDGAIN;

  Data.Audio.ToneBassDB   := SettingsAdjust(Data.Audio.ToneBassDB,   VAL_MIN_TONE_GAIN, VAL_MAX_TONE_GAIN);
  Data.Audio.ToneMidDB    := SettingsAdjust(Data.Audio.ToneMidDB,    VAL_MIN_TONE_GAIN, VAL_MAX_TONE_GAIN);
  Data.Audio.ToneTrebleDB := SettingsAdjust(Data.Audio.ToneTrebleDB, VAL_MIN_TONE_GAIN, VAL_MAX_TONE_GAIN);
  Data.Audio.ToneLowMidDB  := SettingsAdjust(Data.Audio.ToneLowMidDB,  VAL_MIN_TONE_GAIN, VAL_MAX_TONE_GAIN);
  Data.Audio.ToneHighMidDB := SettingsAdjust(Data.Audio.ToneHighMidDB, VAL_MIN_TONE_GAIN, VAL_MAX_TONE_GAIN);

  if not IsValidIntOption(Data.Audio.ToneBassHz, TONE_BASS_HZ_OPTIONS) then
    Data.Audio.ToneBassHz := VAL_DEF_BASSHZ;

  if not IsValidIntOption(Data.Audio.ToneMidHz, TONE_MID_HZ_OPTIONS) then
    Data.Audio.ToneMidHz := VAL_DEF_MIDHZ;

  if not IsValidIntOption(Data.Audio.ToneTrebleHz, TONE_TREBLE_HZ_OPTIONS) then
    Data.Audio.ToneTrebleHz := VAL_DEF_TREBLEHZ;

  if not IsValidIntOption(Data.Audio.ToneLowMidHz, TONE_LOWMID_HZ_OPTIONS) then
    Data.Audio.ToneLowMidHz := VAL_DEF_LOWMIDHZ;

  if not IsValidIntOption(Data.Audio.ToneHighMidHz, TONE_HIGHMID_HZ_OPTIONS) then
    Data.Audio.ToneHighMidHz := VAL_DEF_HIGHMIDHZ;

  // The only two bands whose choices meet are bass (up to
  // 250 Hz) and low mid (from 220 Hz): the low mid stays above the bass
  if Data.Audio.ToneLowMidHz <= Data.Audio.ToneBassHz then
    Data.Audio.ToneLowMidHz := 300;

  // (a width that is no choice is the normal one, not the nearest)
  if (Data.Audio.ToneLowMidWidth < 0) or (Data.Audio.ToneLowMidWidth > TONE_WIDTH_MAX) then Data.Audio.ToneLowMidWidth := TONE_WIDTH_NORMAL;
  if (Data.Audio.ToneMidWidth < 0) or (Data.Audio.ToneMidWidth > TONE_WIDTH_MAX) then Data.Audio.ToneMidWidth := TONE_WIDTH_NORMAL;
  if (Data.Audio.ToneHighMidWidth < 0) or (Data.Audio.ToneHighMidWidth > TONE_WIDTH_MAX) then Data.Audio.ToneHighMidWidth := TONE_WIDTH_NORMAL;

  SanitizeTonePresets(Data.TonePresets);
  for I := 0 to High(Data.TonePresets) do
    CheckPresetFreqs(Data.TonePresets[I]);

  if not IsValidIntOption(Data.Audio.PCMBufferMs, BUFFER_SIZE_OPTIONS) then
    Data.Audio.PCMBufferMs := VAL_DEF_PCMBUFFER;

  if not IsValidIntOption(Data.Audio.DSDBufferMs, BUFFER_SIZE_OPTIONS) then
    Data.Audio.DSDBufferMs := VAL_DEF_DSDBUFFER;

  if not IsValidIntOption(Data.Audio.TargetSampleRate44, TARGET_RATE_44_OPTIONS) then
    Data.Audio.TargetSampleRate44 := VAL_DEF_SAMPLERATE44;

  if not IsValidIntOption(Data.Audio.TargetSampleRate48, TARGET_RATE_48_OPTIONS) then
    Data.Audio.TargetSampleRate48 := VAL_DEF_SAMPLERATE48;

  if not IsValidIntOption(Data.Audio.BypassThreshold, BYPASS_THRESH_OPTIONS) then
    Data.Audio.BypassThreshold := VAL_DEF_BYPASS_THRESH;

  Data.Audio.ReplayGainMode         := SettingsAdjust(Data.Audio.ReplayGainMode,         0, High(REPLAYGAIN_OPTIONS));
  Data.Audio.ResampleQuality        := SettingsAdjust(Data.Audio.ResampleQuality,        0, High(RESAMPLE_QUAL_OPTIONS));
  Data.Audio.UpsamplePhase          := SettingsAdjust(Data.Audio.UpsamplePhase,          0, High(PHASE_OPTIONS));
  Data.Audio.DownsamplePhase        := SettingsAdjust(Data.Audio.DownsamplePhase,        0, High(PHASE_OPTIONS));
  Data.Audio.ResampleBandWidthIndex := SettingsAdjust(Data.Audio.ResampleBandWidthIndex, 0, High(BANDWIDTH_OPTIONS));
  Data.Audio.ResampleAntiAliasIndex := SettingsAdjust(Data.Audio.ResampleAntiAliasIndex, 0, High(ANTI_ALIAS_OPTIONS));
  Data.DefaultGroupingMode          := SettingsAdjust(Data.DefaultGroupingMode,          0, High(GROUPING_MODE_OPTIONS));
  Data.DoubleClickAction            := SettingsAdjust(Data.DoubleClickAction,            0, High(DBLCLICK_OPTIONS));
  Data.LibraryTileSize              := SettingsAdjust(Data.LibraryTileSize,              0, 3);
  Data.LibraryTileSort              := SettingsAdjust(Data.LibraryTileSort,              0, 4);
end;

procedure TAppSettings.Save(AForm: TForm);
var
  I: Integer;
begin
  FIniFile.Clear;

  FIniFile.WriteInteger(SEC_MAIN, KEY_MOD_VERSION, Data.ModificationVersion);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_STATE, Ord(AForm.WindowState));

  // Always persist normal/restored window bounds even when closing Maximized!
  if AForm.WindowState = wsNormal then
  begin
    Data.WinLeft   := AForm.Left;
    Data.WinTop    := AForm.Top;
    Data.WinWidth  := AForm.Width;
    Data.WinHeight := AForm.Height;
  end
  else if (AForm.RestoredWidth > 0) and (AForm.RestoredHeight > 0) then
  begin
    Data.WinLeft   := AForm.RestoredLeft;
    Data.WinTop    := AForm.RestoredTop;
    Data.WinWidth  := AForm.RestoredWidth;
    Data.WinHeight := AForm.RestoredHeight;
  end;

  { nothing out of range is ever written (the same checks as after loading) }
  SanitizeValues;

  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_LEFT,   Data.WinLeft);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_TOP,    Data.WinTop);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_WIDTH,  Data.WinWidth);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_HEIGHT, Data.WinHeight);

  FIniFile.WriteInteger(SEC_WINDOW, KEY_PANEL_TOP,  Data.TopPanelHeight);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_PANEL_LEFT, Data.LeftPanelWidth);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_PANEL_LEFT_TILES, Data.LeftPanelWidthTiles);

  FIniFile.WriteString(SEC_WINDOW, KEY_LIB_SELECTION,  Data.LibrarySelection);
  FIniFile.WriteString(SEC_WINDOW, KEY_LIB_EXPANDED,   Data.LibraryExpanded);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_LIB_TOP_ROW,   Data.LibraryTopRow);
  FIniFile.WriteBool(SEC_WINDOW, KEY_LIB_TILES_ALL,    Data.LibraryTilesAll);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_LIB_TILES_SCROLL, Data.LibraryTilesScroll);
  FIniFile.WriteString(SEC_WINDOW, KEY_PLAY_SELECTION, Data.PlaylistSelection);
  FIniFile.WriteString(SEC_UI, KEY_ACTIVE_PLAYLIST,    Data.ActivePlaylist);

  FIniFile.WriteInteger(SEC_WINDOW, KEY_TONE_WIN_LEFT, Data.ToneWinLeft);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_TONE_WIN_TOP,  Data.ToneWinTop);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_COVER_WIN_W,   Data.CoverWinW);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_COVER_WIN_H,   Data.CoverWinH);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_ARTIST_WIN_W,  Data.ArtistWinW);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_ARTIST_WIN_H,  Data.ArtistWinH);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_PROPS_WIN_W,   Data.PropsWinW);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_PROPS_WIN_H,   Data.PropsWinH);

  Data.LibraryFontSize  := SettingsAdjust(Data.LibraryFontSize,  FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  Data.PlayListFontSize := SettingsAdjust(Data.PlayListFontSize, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);

  FIniFile.WriteInteger(SEC_UI, KEY_LIBRARYFONTSIZE,  Data.LibraryFontSize);
  FIniFile.WriteInteger(SEC_UI, KEY_PLAYLISTFONTSIZE, Data.PlayListFontSize);

  // The WASAPI device (the ASIO driver has its own key)
  FIniFile.WriteString(SEC_AUDIO, KEY_DEVICE_ID,     Data.WasapiDeviceID);
  FIniFile.WriteBool(SEC_AUDIO, KEY_DOP,             Data.Audio.UseDoP);
  FIniFile.WriteBool(SEC_AUDIO, KEY_RESAMPLE,        Data.Audio.ResamplePCM);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_VOLUME,       Data.Volume);
  FIniFile.WriteBool(SEC_AUDIO, KEY_VOLUME_LOCKED,   Data.Audio.VolumeLocked);

  FIniFile.WriteInteger(SEC_AUDIO, KEY_PREAMP_DB,       Round(Data.Audio.PreampDB));
  FIniFile.WriteBool(SEC_AUDIO, KEY_ENABLE_SOFTCLIP,    Data.Audio.EnableSoftClipping);
  FIniFile.WriteBool(SEC_AUDIO, KEY_AUTO_HEADROOM,      Data.Audio.AutoHeadroom);
  FIniFile.WriteBool(SEC_AUDIO, KEY_HEADROOM_MERGED,    True);

  FIniFile.WriteInteger(SEC_AUDIO, KEY_RESAMPLE_QUAL,       Data.Audio.ResampleQuality);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_UPSAMPLE_PHASE,      Data.Audio.UpsamplePhase);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_DOWNSAMPLE_PHASE,    Data.Audio.DownsamplePhase);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_BYPASS_THRESHOLD,    Data.Audio.BypassThreshold);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_RESAMPLE_BANDWIDTH,  Data.Audio.ResampleBandWidthIndex);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_RESAMPLE_ANTI_ALIAS, Data.Audio.ResampleAntiAliasIndex);

  FIniFile.WriteInteger(SEC_AUDIO, KEY_TARGET_44, Data.Audio.TargetSampleRate44);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TARGET_48, Data.Audio.TargetSampleRate48);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_BUFFER_MS, Data.Audio.PCMBufferMs);

  FIniFile.WriteBool(SEC_AUDIO, KEY_DSD_DISABLE_RESAMPLE, Data.Audio.DisableResampleForDSD);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_DSD_BUFFER_MS,     Data.Audio.DSDBufferMs);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_DSD_GAIN,          Data.Audio.DsdToPcmGain);
  FIniFile.WriteBool(SEC_AUDIO, KEY_DSD_LOWPASS,          Data.Audio.DsdLowPassFilter);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_RG_MODE,           Data.Audio.ReplayGainMode);

  FIniFile.WriteBool(SEC_AUDIO, KEY_TONE_DIRECT,     Data.Audio.ToneDirect);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_BASS,    Data.Audio.ToneBassDB);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_MID,     Data.Audio.ToneMidDB);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_TREBLE,  Data.Audio.ToneTrebleDB);

  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_BASSHZ,   Data.Audio.ToneBassHz);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_MIDHZ,    Data.Audio.ToneMidHz);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_TREBLEHZ, Data.Audio.ToneTrebleHz);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_LOWMID,     Data.Audio.ToneLowMidDB);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_HIGHMID,    Data.Audio.ToneHighMidDB);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_LOWMIDHZ,   Data.Audio.ToneLowMidHz);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_HIGHMIDHZ,  Data.Audio.ToneHighMidHz);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_LOWMIDWIDTH,  Data.Audio.ToneLowMidWidth);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_MIDWIDTH,     Data.Audio.ToneMidWidth);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_TONE_HIGHMIDWIDTH, Data.Audio.ToneHighMidWidth);
  for I := 0 to High(Data.TonePresets) do
    FIniFile.WriteString(SEC_TONE_PRESETS, KEY_TONE_PRESET + IntToStr(I + 1), TonePresetToText(Data.TonePresets[I]));

  FIniFile.WriteBool(SEC_LIBRARY, KEY_ACCORDION,       Data.AccordionEnabled);
  FIniFile.WriteInteger(SEC_LIBRARY, KEY_DBL_CLICK,    Data.DoubleClickAction);
  FIniFile.WriteBool(SEC_LIBRARY, KEY_LIB_TILES,       Data.LibraryTiles);
  FIniFile.WriteInteger(SEC_LIBRARY, KEY_LIB_TILE_SIZE, Data.LibraryTileSize);
  FIniFile.WriteInteger(SEC_LIBRARY, KEY_LIB_TILE_SORT, Data.LibraryTileSort);
  FIniFile.WriteBool(SEC_LIBRARY, KEY_LIB_TILE_SORT_REV, Data.LibraryTileSortRev);
  FIniFile.WriteBool(SEC_LIBRARY, KEY_AUTO_RESCAN,     Data.AutoRescanLibrary);
  FIniFile.WriteBool(SEC_UI, KEY_DARK_MODE,            Data.DarkMode);

  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_ARTIST,      Data.ShowLibArtist);
  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_COMPOSER,    Data.ShowLibComposer);
  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_ALBUM,       Data.ShowLibAlbum);
  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_GENRE,       Data.ShowLibGenre);

  FIniFile.WriteInteger(SEC_UI, KEY_GROUPING_MODE,     Data.DefaultGroupingMode);
  FIniFile.WriteString(SEC_UI, KEY_HEADER_FORMAT,      Data.DefaultHeaderFormat);
  FIniFile.WriteString(SEC_UI, KEY_TRACK_FORMAT,       Data.DefaultTrackFormat);
  FIniFile.WriteBool(SEC_UI, KEY_CURSOR_FOLLOWS,       Data.CursorFollowsPlayback);
  FIniFile.WriteBool(SEC_UI, KEY_STICKY_HEADERS,       Data.StickyHeaders);
  FIniFile.WriteBool(SEC_UI, KEY_WORK_HEADINGS,        Data.WorkHeadings);
  FIniFile.WriteBool(SEC_UI, KEY_COMPACT_ROWS,         Data.CompactRows);

  FIniFile.WriteBool(SEC_UI, KEY_SHOWPEAKMETER,        Data.ShowPeakMeter);
  // The key the user entered (empty = none, see Load)
  FIniFile.WriteString(SEC_ADVANCED, KEY_LASTFM_API_KEY, Data.LastFmApiKey);
  FIniFile.WriteBool(SEC_ADVANCED, KEY_CHECK_UPDATES, Data.CheckUpdatesAtStart);
  FIniFile.WriteString(SEC_ADVANCED, KEY_SKIPPED_VERSION, Data.SkippedVersion);

  FIniFile.WriteBool(SEC_AUDIO, KEY_USE_HIGHRES_TIMER, Data.Audio.UseHighResTimer);
  FIniFile.WriteBool(SEC_AUDIO, KEY_OPTIMIZE_AFFINITY, Data.Audio.OptimizeAffinity);
  FIniFile.WriteBool(SEC_AUDIO, KEY_ENABLE_MMCSS,      Data.Audio.EnableMMCSS);
  FIniFile.WriteBool(SEC_AUDIO, KEY_KEEP_DRIVES_AWAKE, Data.Audio.KeepDrivesAwake);

  FIniFile.WriteInteger(SEC_UI, KEY_THEME_MODE,    Data.ThemeMode);
  FIniFile.WriteInteger(SEC_UI, KEY_ACCENT,         Data.Accent);
  FIniFile.WriteInteger(SEC_UI, KEY_UI_FONT_SIZE,   Data.UIFontSize);
  FIniFile.WriteBool(SEC_UI, KEY_ANIMATIONS,        Data.Animations);
  FIniFile.WriteBool(SEC_UI, KEY_GPU_PAINT,         Data.GpuPaint);
  FIniFile.WriteBool(SEC_AUDIO, KEY_MUTED,          Data.Muted);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_SHUFFLE,     Data.ShuffleMode);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_REPEAT,      Data.RepeatMode);
  FIniFile.WriteInteger(SEC_AUDIO, KEY_OUTPUT_API,  Data.OutputApi);
  FIniFile.WriteString(SEC_AUDIO, KEY_ASIO_DRIVER,  Data.AsioDriverID);
  FIniFile.WriteBool(SEC_LIBRARY, KEY_WATCH_FOLDERS, Data.WatchFolders);
  FIniFile.WriteInteger(SEC_ADVANCED, KEY_RG_SCAN_THREADS, Data.RGScanThreads);
  FIniFile.WriteBool(SEC_ADVANCED, KEY_ALWAYS_SAVE_LOG, Data.AlwaysSaveLog);
  { no longer stored: the keys of a settings file that has them are taken out }
  FIniFile.DeleteKey(SEC_UI, KEY_PREFS_PAGE);
  FIniFile.DeleteKey(SEC_UI, KEY_PREFS_CARDS);
  FIniFile.WriteString(SEC_UI, KEY_LAST_ADD_DIR,    Data.LastAddDir);

  AtomicSaveIniFile;
end;

initialization
  AppSettings := TAppSettings.Create;

end.
