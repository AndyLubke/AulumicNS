unit uAppConsts;

{$mode ObjFPC}{$H+}

// =============================================================================
// AulumicNS - uAppConsts
// Copyright (C) 2026 André Lubke
// Licensed under the GNU General Public License, version 3 (see LICENSE).
//
// Central unit for global constants, global enums, global variables, and
// global directory paths.
// =============================================================================

interface

uses
  SysUtils;

type
  TGroupingMode = (gmAlbum, gmFolder, gmFlat);

  TFormatDef = record
    DisplayName: string;
    DataStr: string;
  end;

// =========================================================================
// 1. NON-TRANSLATABLE ENGINE CONSTANTS (Locked safe from translation)
// =========================================================================
const
  APP_TITLE           = 'Aulumic';
  ZERO_TIME           = '0:00';

  VAL_UNINITIALIZED_POS = -1;

  // Standardized ReplayGain Tags for universal compatibility
  RG_TAGS_TRACK_GAIN  = 'REPLAYGAIN_TRACK_GAIN; TXXX:REPLAYGAIN_TRACK_GAIN; R128_TRACK_GAIN';
  RG_TAGS_ALBUM_GAIN  = 'REPLAYGAIN_ALBUM_GAIN; TXXX:REPLAYGAIN_ALBUM_GAIN; R128_ALBUM_GAIN';
  RG_TAGS_TRACK_PEAK  = 'REPLAYGAIN_TRACK_PEAK; TXXX:REPLAYGAIN_TRACK_PEAK; R128_TRACK_PEAK';
  RG_TAGS_ALBUM_PEAK  = 'REPLAYGAIN_ALBUM_PEAK; TXXX:REPLAYGAIN_ALBUM_PEAK; R128_ALBUM_PEAK';

  // Sample rate bases
  RATE_FAMILY_44K             = 44100;  // 44.1 kHz sample rate family base
  RATE_FAMILY_48K             = 48000;  // 48 kHz sample rate family base
  DSD_BASE_RATE               = 44100;  // DSD64 = 64 x 44100 Hz; DSDn rate div DSD_BASE_RATE = n
  DSD64_SAMPLE_RATE           = 64 * DSD_BASE_RATE;  // 2822400 Hz
  DSD64_48K_SAMPLE_RATE       = 64 * RATE_FAMILY_48K;  // 3072000 Hz (48 kHz based DSD)
  DOP_DSD_FACTOR              = 16;  // DoP: DSD rate = PCM carrier rate div DSD_BASE_RATE * 16

  // Tag field names (ReplayGain)
  TAG_RG_PREFIX               = 'REPLAYGAIN';
  TAG_R128_PREFIX             = 'R128';
  TAG_RG_TRACK_GAIN           = 'REPLAYGAIN_TRACK_GAIN';
  TAG_RG_ALBUM_GAIN           = 'REPLAYGAIN_ALBUM_GAIN';
  TAG_RG_TRACK_PEAK           = 'REPLAYGAIN_TRACK_PEAK';
  TAG_RG_ALBUM_PEAK           = 'REPLAYGAIN_ALBUM_PEAK';

  // Auto-playlist query operators (shared by the editor and the parser)
  QUERY_OP_IS                 = 'IS';
  QUERY_OP_HAS                = 'HAS';
  QUERY_OP_NOT_HAS            = 'NOT HAS';
  QUERY_OP_STARTSWITH         = 'STARTSWITH';
  QUERY_OP_IN_LAST            = 'IN LAST';

  // File formats & markers
  MIME_JPEG                   = 'image/jpeg';
  MIME_PNG                    = 'image/png';
  BYTES_PER_MB                = 1024 * 1024;

  M3U_HEADER                  = '#EXTM3U';
  M3U_EXTINF                  = '#EXTINF:';
  FILE_EXT_M3U8               = '.m3u8';
  FILE_ARTIST_BIO             = 'artist_bio.txt';  // per-artist cache files in MusicInfo\<artist>\
  FILE_ARTIST_IMAGE           = 'artist_image.jpg';
  // Empty marker files: the bio / picture was set by the user (kept by Refresh)
  FILE_ARTIST_BIO_USER        = 'artist_bio.user';
  FILE_ARTIST_IMAGE_USER      = 'artist_image.user';
  // Next to the program file: a Last.fm API key for a program that has none
  // in its settings yet (uSettingsManager.ReadLastFmKeyFile)
  FILE_LASTFM_KEY             = 'LastFmKey.txt';

  // The icons are the vector icons of AuIcons

  //Thread delay in ms
  THREAD_DELAY_MS             = 150;

  // Timer intervals, waits and retries (ms unless stated otherwise)
  UI_TIMER_INTERVAL_MS        = 50;   // main UI timer (TMainForm.FUiTimer), 20 times per second
  UI_TIMER_IDLE_INTERVAL_MS   = 250;  // FUiTimer when nothing is playing or changing (4 times per second)
  LIB_SEARCH_DELAY_MS         = 300;  // typing pause before the library search runs
  PANEL_LOAD_DELAY_MS         = 250;  // artist info / cover art popup deferred load
  TAGLOADER_TIMER_MS          = 50;
  DEBUG_QUEUE_INTERVAL_MS     = 500;
  FILE_REPLACE_WAIT_STEP_MS   = 100;  // custodian: wait for a file that cannot be replaced yet
  FILE_REPLACE_WAIT_STEPS     = 50;   // 50 x 100 ms = 5 s
  CUSTODIAN_JOB_YIELD_MS      = 5;
  // Longest wait for the play thread to end after Stop; a thread
  // that is still running then is set aside (see TAudioEngine.Stop)
  PLAY_THREAD_STOP_TIMEOUT_MS = 5000;
  // Longest wait at exit for a drive-wake worker that still runs
  // after a Cancel (uDriveKeepAlive.FinishSetAsideThreads)
  DRIVE_WAKE_EXIT_WAIT_MS     = 2000;
  // "Waiting for drive..." appears only when waking the drives takes longer
  // than this (an awake drive answers within milliseconds; with a shorter
  // delay a drive that needs a second would show the window for a moment at
  // every click on the cover). Until then the wait looks like a busy
  // window - the busy cursor, no input (uInputBlock), everything still
  // painting; the window with its Cancel button is for a disk that really
  // has to spin up. Escape stops the wait before and after.
  DRIVE_WAIT_SHOW_DELAY_MS    = 5000;
  // A drive that answered within this time (a wake, the track
  // that plays, the keep-alive read) is awake: WakeDrives does not check it
  // again. Far below any sleep timer (minutes); short, so a NAS that was
  // switched off is asked again soon.
  DRIVE_ANSWER_MEMORY_MS      = 20000;
  // A NAS / network share whose server does not answer within
  // this time counts as not connected (uDriveKeepAlive.ServerAnswers; a
  // server on the network answers within milliseconds, even with its disks
  // asleep). Windows itself waits 20-60 s for it.
  NAS_ANSWER_TIMEOUT_MS       = 1500;
  CUSTODIAN_BATCH_SETTLE_MS   = 200;
  DRIVE_WAKE_RETRIES          = 3;    // file check retries for a sleeping drive
  DRIVE_WAKE_RETRY_MS         = 250;
  RG_THERMAL_PAUSE_MS         = 10;   // ReplayGain scanner: short pause to keep the CPU cool
  RG_MAX_THREADS              = 8;    // ReplayGain scanner: tracks of an album measured at once

  SAVE_FAILED_MAX_LINES       = 10;   // max. files listed in the "Tags Not Saved" dialog

  // UI Metrics and Dimensions
  MIN_FORM_WIDTH              = 600;
  MIN_FORM_HEIGHT             = 400;
  MIN_LPANEL_WIDTH            = 180;
  MIN_RPANEL_WIDTH            = 400;

  DEFAULT_FORM_WIDTH          = MIN_FORM_WIDTH;
  DEFAULT_FORM_HEIGHT         = MIN_FORM_HEIGHT;
  DEFAULT_LPANEL_WIDTH        = 400;

  FORM_DEBUG_WIDTH            = 400;
  FORM_DEBUG_HEIGHT           = 600;

  // Minimum dimensions for the Virtual Folder (Alias) Editor
  FORM_ALIAS_MINWIDTH         = 680;
  FORM_ALIAS_MINHEIGHT        = 480;

  FORM_TONE_POPUP_WIDTH       = 260;
  FORM_TONE_POPUP_HEIGHT      = 280;

  // Log window (at 96 dpi). The minimum width keeps the three
  // buttons (Save to File... / Clear / Close) in view
  FORM_APPLOG_WIDTH           = 900;
  FORM_APPLOG_HEIGHT          = 600;
  FORM_APPLOG_MINWIDTH        = 560;
  FORM_APPLOG_MINHEIGHT       = 300;

  CACHE_THUMB_SIZE            = 128;

  // Font Sizes
  FONT_LISTDEFAULTSIZE        = 12;
  FONT_MAIN_MINSIZE           = 6;
  FONT_MAIN_MAXSIZE           = 20;

  FORMAT_MAIN_CAPTION         = '%title% | Aulumic';

  // UI Panels
  UI_TOP_PANEL_DEFAULTHEIGHT  = 200;

  // File Paths and Masks
  FILE_VALID_EXTS             = '.flac,.wav,.dsf,.dff';
  // The library and the user stats are stored by uDbStore (snapshot .adb +
  // journal .jnl)
  FILE_DB                     = 'library.adb';
  FILE_USER_STATS             = 'stats.adb';
  FILE_PLAYLISTS              = 'playlists.adb';   // all playlists (uPlaylistStore)

  FOLDER_LIBRARY              = 'Library\';
  FOLDER_PLAYLISTS            = 'Playlists\';
  FOLDER_PLUGINS              = 'plugins\';
  FOLDER_MUSICINFO            = 'MusicInfo\';

  COVER_ART_NAMES : array[0..27] of string =
  ('folder.jpg' , 'folder.jpeg' , 'folder.png' , 'folder.bmp',
   'cover.jpg'  , 'cover.jpeg'  , 'cover.png'  , 'cover.bmp',
   'front.jpg'  , 'front.jpeg'  , 'front.png'  , 'front.bmp',
   'folder*.jpg', 'folder*.jpeg', 'folder*.png', 'folder*.bmp',
   'cover*.jpg' , 'cover*.jpeg' , 'cover*.png' , 'cover*.bmp',
   'front*.jpg' , 'front*.jpeg' , 'front*.png' , 'front*.bmp',
   '*.jpg'      , '*.jpeg'      , '*.png'      , '*.bmp');

// =========================================================================
// 2. APPLICATION RUNTIME VARIABLES
// =========================================================================
var
  AppExePath        : string;
  AppBaseDir        : string;
  AppLibraryDir     : string;
  AppIniPath        : string;
  AppPlaylistsDir   : string;
  AppPluginsDir     : string;
  AppCacheThumbsDir : string;
  AppMusicInfoDir   : string;
  AppLogDir         : string;   // the log file (the data folder)

implementation

uses
  AuSettings;

initialization
  // Portable - everything in Data\ and Cache\ next to the exe
  // (or %APPDATA%\AulumicNS when that folder cannot be written, see AuSettings)
  AppExePath        := ParamStr(0);
  AppBaseDir        := IncludeTrailingPathDelimiter(ExtractFilePath(AppExePath));
  AppIniPath        := AppDataDir + 'AulumicNS.ini';
  AppLibraryDir     := AppDataDir + FOLDER_LIBRARY;
  AppPlaylistsDir   := AppDataDir + FOLDER_PLAYLISTS;
  AppPluginsDir     := AppBaseDir + FOLDER_PLUGINS;
  AppMusicInfoDir   := AppDataDir + FOLDER_MUSICINFO;
  AppCacheThumbsDir := CacheDir + 'Thumbs\';
  AppLogDir         := AppDataDir;

end.
