unit uSettingsManager;

{$mode objfpc}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uSettingsManager
  Author:    André Lubke
  Created:   2026

  Loads and saves all application settings to and from the .ini file.
  =============================================================================}

interface

uses
  Classes, SysUtils, IniFiles, Forms, uPlaybackManager;

function SettingsAdjust(aNum, aMin, aMax : integer) : integer;
{ ---> AulumicNS: the size (96-DPI units) a tool window opens with: the
  remembered one (0 = ADefW / ADefH), at most 92 % of the work area at the
  current scaling }
procedure ToolWindowSize(ARememberedW, ARememberedH, ADefW, ADefH: Integer; out W, H: Integer);
// ---> AulumicNS: tone settings of the builds with three bands - the Mid
// setting goes to the band that has its frequency among the five (below
// 800 Hz: low mid, from 3 kHz: high mid), and the Mid band is flat at 1 kHz
procedure MoveThreeBandMid(var AMidHz, AMidDB, ALowMidHz, ALowMidDB, AHighMidHz, AHighMidDB: Integer);

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
    ToneWinLeft         : integer;
    ToneWinTop          : integer;
    // ---> AulumicNS: the sizes of the cover viewer and Artist Info, in 96-DPI
    // units (their client area below the title bar; 0 = the default)
    CoverWinW, CoverWinH   : integer;
    ArtistWinW, ArtistWinH : integer;
    PropsWinW, PropsWinH   : integer;   // Properties (sizable since 2026-11-11)

    LibrarySelection    : string;
    PlaylistSelection   : string;
    ActivePlayList      : string;

    LibraryFontSize     : integer;
    PlaylistFontSize    : integer;

    ShowLibArtist       : Boolean;
    ShowLibAlbum        : Boolean;
    ShowLibGenre        : Boolean;

    // --- GENERAL AUDIO STATE (Not part of the Engine Config) ---
    Volume              : integer;
    ModificationVersion : integer;

    // --- UI & BEHAVIOR PREFERENCES ---
    AccordionEnabled    : boolean;
    DoubleClickAction   : integer;
    AutoRescanLibrary   : boolean;
    DarkMode            : boolean;
    DefaultGroupingMode : integer;
    DefaultHeaderFormat : string;
    DefaultTrackFormat  : string;
    // ---> AulumicNS: the selection moves to the track that starts playing
    // (as in Aulumic, where it always did; an option here, the user 2026-11-17)
    CursorFollowsPlayback: Boolean;
    ShowPeakmeter       : boolean;
    LastFMApiKey        : string;

    // --- AulumicNS ---
    ThemeMode           : integer;   // 0 dark, 1 light, 2 follow Windows (DarkMode follows it)
    Accent              : integer;   // 0 .. AccentCount - 1
    UIFontSize          : integer;   // the whole UI text, percent (90 .. 130)
    Animations          : boolean;   // ---> AulumicNS: short fades and gliding movements (AuAnim)
    GpuPaint            : boolean;   // ---> AulumicNS: large controls drawn by the graphics card (AuControls.GpuPaintAllowed)
    Muted               : boolean;
    ShuffleMode         : integer;   // 0 off, 1 tracks, 2 albums (TShuffleMode)
    RepeatMode          : integer;   // 0 off, 1 all, 2 one
    OutputApi           : integer;   // 0 WASAPI, 1 ASIO (copied to Audio.OutputApi)
    WasapiDeviceID      : string;    // the device of each interface; Audio.DeviceID
    AsioDriverID        : string;    // is the one of the chosen interface
    WatchFolders        : boolean;
    PrefsPage           : integer;
    PrefsCards          : string;    // ---> AulumicNS: the cards of Preferences that are open (ids, comma separated)
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
  public
    Data : TAppSettingsData;

    constructor Create;
    destructor  Destroy; override;
    procedure   Load;
    procedure   Save(AForm: TForm);
    // ---> AulumicNS: Audio.OutputApi / DeviceID from OutputApi and the device
    // of that interface (WasapiDeviceID / AsioDriverID)
    procedure   SyncOutputDevice;
  end;

var
  AppSettings: TAppSettings;

implementation

uses Windows, uAppStrings, uAppConsts, ALAudioTypes, uOSUtils, Math, AuTheme;

const
  SEC_MAIN              = 'Main';
  SEC_WINDOW            = 'Window';
  SEC_AUDIO             = 'Audio';
  SEC_LIBRARY           = 'Library';
  SEC_UI                = 'UI';
  SEC_ADVANCED          = 'Advanced';

  KEY_MOD_VERSION       = 'ModificationVersion';

  KEY_WIN_LEFT          = 'Left';
  KEY_WIN_TOP           = 'Top';
  KEY_WIN_WIDTH         = 'Width';
  KEY_WIN_HEIGHT        = 'Height';
  KEY_WIN_STATE         = 'WindowState';
  KEY_PANEL_TOP         = 'TopPanelHeight';
  KEY_PANEL_LEFT        = 'LeftPanelWidth';

  KEY_LIB_SELECTION     = 'LibrarySelection';
  KEY_PLAY_SELECTION    = 'PlaylistSelection';
  KEY_ACTIVE_PLAYLIST   = 'ActivePlaylist';

  KEY_LIBRARYFONTSIZE   = 'LibraryFontSize';
  KEY_DARK_MODE         = 'DarkMode';
  KEY_PLAYLISTFONTSIZE  = 'PlayListFontSize';

  KEY_SHOW_LIB_ARTIST   = 'ShowLibArtist';
  KEY_SHOW_LIB_ALBUM    = 'ShowLibAlbum';
  KEY_SHOW_LIB_GENRE    = 'ShowLibGenre';

  KEY_GROUPING_MODE     = 'DefaultGroupingMode';
  KEY_HEADER_FORMAT     = 'DefaultHeaderFormat';
  KEY_TRACK_FORMAT      = 'DefaultTrackFormat';
  KEY_CURSOR_FOLLOWS    = 'CursorFollowsPlayback';

  KEY_DEVICE_ID         = 'OutputDeviceID';
  KEY_DOP               = 'UseDoP';
  KEY_RESAMPLE          = 'ResamplePCM';
  KEY_VOLUME            = 'MasterVolume';

  KEY_VOLUME_LOCKED     = 'VolumeLocked';
  KEY_PREAMP_DB         = 'PreampDB';
  KEY_ENABLE_SOFTCLIP   = 'EnableSoftClipping';
  KEY_AUTO_HEADROOM     = 'AutoHeadroom';   // ---> AulumicNS
  KEY_HEADROOM_MERGED   = 'HeadroomMerged'; // ---> AulumicNS: see LoadSettings

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
  KEY_AUTO_RESCAN         = 'AutoRescanLibrary';

  KEY_SHOWPEAKMETER       = 'ShowPeakMeter';

  KEY_LASTFM_API_KEY      = 'LastFmAPIKey';

  KEY_TONE_DIRECT         = 'ToneDirect';
  KEY_TONE_BASS           = 'ToneBass';
  KEY_TONE_MID            = 'ToneMid';
  KEY_TONE_TREBLE         = 'ToneTreble';
  KEY_TONE_BASSHZ         = 'ToneBassHz';
  KEY_TONE_MIDHZ          = 'ToneMidHz';
  KEY_TONE_TREBLEHZ       = 'ToneTrebleHz';
  // ---> AulumicNS: five bands (2026-11-14)
  KEY_TONE_LOWMID         = 'ToneLowMid';
  KEY_TONE_HIGHMID        = 'ToneHighMid';
  KEY_TONE_LOWMIDHZ       = 'ToneLowMidHz';
  KEY_TONE_HIGHMIDHZ      = 'ToneHighMidHz';
  KEY_TONE_WIN_LEFT       = 'ToneWinLeft';
  KEY_TONE_WIN_TOP        = 'ToneWinTop';
  KEY_COVER_WIN_W         = 'CoverWinWidth';
  KEY_COVER_WIN_H         = 'CoverWinHeight';
  KEY_ARTIST_WIN_W        = 'ArtistWinWidth';
  KEY_ARTIST_WIN_H        = 'ArtistWinHeight';
  KEY_PROPS_WIN_W         = 'PropertiesWinWidth';
  KEY_PROPS_WIN_H         = 'PropertiesWinHeight';

  // ---> AulumicNS
  KEY_THEME_MODE          = 'ThemeMode';
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

function SettingsAdjust(aNum, aMin, aMax : integer) : integer;
begin
  Result := aNum;
  if Result < aMin then
    Result := aMin;
  if (aMax > 0) and (Result > aMax) then
    Result := aMax;
end;

// ---> AUDIT FIX: True when the file exists, is not empty and contains at least
// one [Section] header. A file truncated or zero-filled by a crash / power loss
// fails this check, so it is never loaded and never copied over the backup.
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

// ---> AUDIT FIX: Copies ASource to ATarget through a flushed temp file plus an
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

// ---> AUDIT FIX: Durable write-through flush of an already written file
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

// ---> AUDIT FIX: Crash-safe settings save.
//  1. TMemIniFile writes to <ini>.tmp (same encoding as before; clears Dirty).
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

  // ---> AUDIT FIX: Restore the backup when the ini is missing OR damaged
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

{ ---> AulumicNS: the system DPI from Windows itself; Screen.PixelsPerInch
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
  { ---> AulumicNS: the panel widths are logical pixels (S() scales them),
    the work area is physical: at 225 % a quarter of it was 960 "logical"
    pixels (the library pane then took a narrow window's whole width) }
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
  Data.PlaylistSelection := FIniFile.ReadString(SEC_WINDOW, KEY_PLAY_SELECTION, '');
  Data.ActivePlaylist    := FIniFile.ReadString(SEC_UI, KEY_ACTIVE_PLAYLIST, LBL_DEFAULT_PLAYLIST);

  Data.LibraryFontSize   := FIniFile.ReadInteger(SEC_UI, KEY_LIBRARYFONTSIZE,  FONT_LISTDEFAULTSIZE);
  Data.PlayListFontSize  := FIniFile.ReadInteger(SEC_UI, KEY_PLAYLISTFONTSIZE, FONT_LISTDEFAULTSIZE);

  Data.LibraryFontSize   := SettingsAdjust(Data.LibraryFontSize,  FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  Data.PlayListFontSize  := SettingsAdjust(Data.PlayListFontSize, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);

  Data.Audio.DeviceID    := FIniFile.ReadString(SEC_AUDIO, KEY_DEVICE_ID, '');
  // ---> AulumicNS: DoP on by default (as the help describes the first start)
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
  // ---> AulumicNS: on unless switched off (the user's choice, 2026-11-12)
  Data.Audio.AutoHeadroom       := FIniFile.ReadBool(SEC_AUDIO, KEY_AUTO_HEADROOM, True);
  // ---> AulumicNS (2026-11-12): the automatic headroom and the preamp are
  // one setting now (Automatic, or a fixed value). A settings file from
  // before that goes to Automatic once (agreed with the user).
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

  // ---> AulumicNS: five bands (2026-11-14)
  Data.Audio.ToneLowMidDB  := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_LOWMID,    0);
  Data.Audio.ToneHighMidDB := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_HIGHMID,   0);
  Data.Audio.ToneLowMidHz  := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_LOWMIDHZ,  VAL_DEF_LOWMIDHZ);
  Data.Audio.ToneHighMidHz := FIniFile.ReadInteger(SEC_AUDIO, KEY_TONE_HIGHMIDHZ, VAL_DEF_HIGHMIDHZ);
  // Settings written with three bands: the Mid band could be at 220 Hz ..
  // 3 kHz. Its setting moves to the band that has that frequency now, so it
  // sounds as it did (the filters are the same; a band at 0 dB is skipped).
  if not FIniFile.ValueExists(SEC_AUDIO, KEY_TONE_LOWMIDHZ) then
    MoveThreeBandMid(Data.Audio.ToneMidHz, Data.Audio.ToneMidDB,
      Data.Audio.ToneLowMidHz, Data.Audio.ToneLowMidDB,
      Data.Audio.ToneHighMidHz, Data.Audio.ToneHighMidDB);

  Data.AccordionEnabled  := FIniFile.ReadBool(SEC_LIBRARY, KEY_ACCORDION, False);
  Data.DoubleClickAction := FIniFile.ReadInteger(SEC_LIBRARY, KEY_DBL_CLICK, VAL_DEF_DBL_CLICK);
  Data.AutoRescanLibrary := FIniFile.ReadBool(SEC_LIBRARY, KEY_AUTO_RESCAN, False);

  Data.DarkMode          := FIniFile.ReadBool(SEC_UI, KEY_DARK_MODE, True);
  Data.ShowLibArtist     := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_ARTIST, True);
  Data.ShowLibAlbum      := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_ALBUM,  True);
  Data.ShowLibGenre      := FIniFile.ReadBool(SEC_UI, KEY_SHOW_LIB_GENRE,  True);

  Data.DefaultGroupingMode := FIniFile.ReadInteger(SEC_UI, KEY_GROUPING_MODE, VAL_DEF_GROUPING_MODE);
  Data.DefaultHeaderFormat := FIniFile.ReadString(SEC_UI, KEY_HEADER_FORMAT, HEADER_FORMAT_OPTIONS[0].DataStr);
  Data.DefaultTrackFormat  := FIniFile.ReadString(SEC_UI, KEY_TRACK_FORMAT,  TRACK_FORMAT_OPTIONS[0].DataStr);
  Data.CursorFollowsPlayback := FIniFile.ReadBool(SEC_UI, KEY_CURSOR_FOLLOWS, True);

  Data.ShowPeakMeter := FIniFile.ReadBool(SEC_UI, KEY_SHOWPEAKMETER, True);
  // ---> AulumicNS: no key is built in (the source is public): the user's own
  // key, entered in Preferences > System > Artist information.
  Data.LastFmApiKey  := Trim(FIniFile.ReadString(SEC_ADVANCED, KEY_LASTFM_API_KEY, ''));

  Data.Audio.UseHighResTimer  := FIniFile.ReadBool(SEC_AUDIO, KEY_USE_HIGHRES_TIMER, True);
  Data.Audio.OptimizeAffinity := FIniFile.ReadBool(SEC_AUDIO, KEY_OPTIMIZE_AFFINITY, True);
  Data.Audio.EnableMMCSS      := FIniFile.ReadBool(SEC_AUDIO, KEY_ENABLE_MMCSS, True);
  Data.Audio.KeepDrivesAwake  := FIniFile.ReadBool(SEC_AUDIO, KEY_KEEP_DRIVES_AWAKE, False);

  // ---> AulumicNS
  Data.ThemeMode    := SettingsAdjust(FIniFile.ReadInteger(SEC_UI, KEY_THEME_MODE, 0), 0, 2);
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
  // on by default (milestone 3; network folders are never watched)
  Data.WatchFolders := FIniFile.ReadBool(SEC_LIBRARY, KEY_WATCH_FOLDERS, True);
  Data.RGScanThreads := FIniFile.ReadInteger(SEC_ADVANCED, KEY_RG_SCAN_THREADS, 1);
  Data.AlwaysSaveLog := FIniFile.ReadBool(SEC_ADVANCED, KEY_ALWAYS_SAVE_LOG, False);
  Data.PrefsPage    := FIniFile.ReadInteger(SEC_UI, KEY_PREFS_PAGE, 0);
  Data.PrefsCards   := FIniFile.ReadString(SEC_UI, KEY_PREFS_CARDS, '');
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

  function IsValidStrOption(const Value: string; const Options: array of TFormatDef): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    if Trim(Value) = '' then
      Exit(False);

    for I := Low(Options) to High(Options) do
    begin
      if (Options[I].DataStr <> '') and SameText(Value, Options[I].DataStr) then
        Exit(True);
    end;
  end;

begin
  if (Ord(Data.WinState) < Ord(Low(TWindowState))) or
     (Ord(Data.WinState) > Ord(High(TWindowState))) then
    Data.WinState := TWindowState(VAL_DEF_WIN_STATE)
  else if Data.WinState = wsMinimized then
    Data.WinState := wsNormal;

  if Data.WinWidth > Screen.DesktopWidth then
    Data.WinWidth := Screen.DesktopWidth;

  if Data.WinHeight > Screen.DesktopHeight then
    Data.WinHeight := Screen.DesktopHeight;

  // ---> AUDIT FIX: Support multi-monitor negative DesktopLeft / DesktopTop coordinates
  if Data.WinLeft <> VAL_UNINITIALIZED_POS then
  begin
    Data.WinLeft := SettingsAdjust(Data.WinLeft, Screen.DesktopLeft,
                                   Screen.DesktopLeft + Screen.DesktopWidth - Data.WinWidth);
    Data.WinTop  := SettingsAdjust(Data.WinTop,  Screen.DesktopTop,
                                   Screen.DesktopTop + Screen.DesktopHeight - Data.WinHeight);
  end;

  if Data.ToneWinLeft <> VAL_UNINITIALIZED_POS then
  begin
    Data.ToneWinLeft := SettingsAdjust(Data.ToneWinLeft, Screen.DesktopLeft,
                                       Screen.DesktopLeft + Screen.DesktopWidth - FORM_TONE_POPUP_WIDTH);
    Data.ToneWinTop  := SettingsAdjust(Data.ToneWinTop,  Screen.DesktopTop,
                                       Screen.DesktopTop + Screen.DesktopHeight - FORM_TONE_POPUP_HEIGHT);
  end;

  if Trim(Data.ActivePlaylist) = '' then
    Data.ActivePlaylist := LBL_DEFAULT_PLAYLIST;

  if not IsValidStrOption(Data.DefaultHeaderFormat, HEADER_FORMAT_OPTIONS) then
    Data.DefaultHeaderFormat := HEADER_FORMAT_OPTIONS[0].DataStr;

  if not IsValidStrOption(Data.DefaultTrackFormat, TRACK_FORMAT_OPTIONS) then
    Data.DefaultTrackFormat := TRACK_FORMAT_OPTIONS[0].DataStr;

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

  // ---> AulumicNS: the only two bands whose choices meet are bass (up to
  // 250 Hz) and low mid (from 220 Hz): the low mid stays above the bass
  if Data.Audio.ToneLowMidHz <= Data.Audio.ToneBassHz then
    Data.Audio.ToneLowMidHz := 300;

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
end;

procedure TAppSettings.Save(AForm: TForm);
begin
  FIniFile.Clear;

  FIniFile.WriteInteger(SEC_MAIN, KEY_MOD_VERSION, Data.ModificationVersion);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_STATE, Ord(AForm.WindowState));

  // ---> AUDIT FIX: Always persist normal/restored window bounds even when closing Maximized!
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

  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_LEFT,   Data.WinLeft);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_TOP,    Data.WinTop);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_WIDTH,  Data.WinWidth);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_WIN_HEIGHT, Data.WinHeight);

  FIniFile.WriteInteger(SEC_WINDOW, KEY_PANEL_TOP,  Data.TopPanelHeight);
  FIniFile.WriteInteger(SEC_WINDOW, KEY_PANEL_LEFT, Data.LeftPanelWidth);

  FIniFile.WriteString(SEC_WINDOW, KEY_LIB_SELECTION,  Data.LibrarySelection);
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

  // ---> AulumicNS: the WASAPI device (the ASIO driver has its own key)
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

  FIniFile.WriteBool(SEC_LIBRARY, KEY_ACCORDION,       Data.AccordionEnabled);
  FIniFile.WriteInteger(SEC_LIBRARY, KEY_DBL_CLICK,    Data.DoubleClickAction);
  FIniFile.WriteBool(SEC_LIBRARY, KEY_AUTO_RESCAN,     Data.AutoRescanLibrary);
  FIniFile.WriteBool(SEC_UI, KEY_DARK_MODE,            Data.DarkMode);

  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_ARTIST,      Data.ShowLibArtist);
  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_ALBUM,       Data.ShowLibAlbum);
  FIniFile.WriteBool(SEC_UI, KEY_SHOW_LIB_GENRE,       Data.ShowLibGenre);

  FIniFile.WriteInteger(SEC_UI, KEY_GROUPING_MODE,     Data.DefaultGroupingMode);
  FIniFile.WriteString(SEC_UI, KEY_HEADER_FORMAT,      Data.DefaultHeaderFormat);
  FIniFile.WriteString(SEC_UI, KEY_TRACK_FORMAT,       Data.DefaultTrackFormat);
  FIniFile.WriteBool(SEC_UI, KEY_CURSOR_FOLLOWS,       Data.CursorFollowsPlayback);

  FIniFile.WriteBool(SEC_UI, KEY_SHOWPEAKMETER,        Data.ShowPeakMeter);
  // ---> MODIFIED: The built-in key is not stored (empty value, see Load)
  FIniFile.WriteString(SEC_ADVANCED, KEY_LASTFM_API_KEY, Data.LastFmApiKey);

  FIniFile.WriteBool(SEC_AUDIO, KEY_USE_HIGHRES_TIMER, Data.Audio.UseHighResTimer);
  FIniFile.WriteBool(SEC_AUDIO, KEY_OPTIMIZE_AFFINITY, Data.Audio.OptimizeAffinity);
  FIniFile.WriteBool(SEC_AUDIO, KEY_ENABLE_MMCSS,      Data.Audio.EnableMMCSS);
  FIniFile.WriteBool(SEC_AUDIO, KEY_KEEP_DRIVES_AWAKE, Data.Audio.KeepDrivesAwake);

  // ---> AulumicNS
  FIniFile.WriteInteger(SEC_UI, KEY_THEME_MODE,     Data.ThemeMode);
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
  FIniFile.WriteInteger(SEC_UI, KEY_PREFS_PAGE,     Data.PrefsPage);
  FIniFile.WriteString(SEC_UI, KEY_PREFS_CARDS,     Data.PrefsCards);
  FIniFile.WriteString(SEC_UI, KEY_LAST_ADD_DIR,    Data.LastAddDir);

  AtomicSaveIniFile;
end;

initialization
  AppSettings := TAppSettings.Create;

end.
