unit uAppStrings;

{$mode ObjFPC}{$H+}

// =============================================================================
// AulumicNS - uAppStrings
// Copyright (C) 2026 André Lubke
// Licensed under the GNU General Public License, version 3 (see LICENSE).
//
// The central repository for all static user-facing application strings.
// =============================================================================

interface

uses
  SysUtils, uAppConsts;

function GetWasapiErrorString(hr: HRESULT): string;
// A combo box shows the DisplayName of each option of AArray and leaves out
// the '-' separators (DataStr = ''), so row N of the combo box is
// not AArray[N] when AArray has them. These convert between the two by
// position (never by the row's text). -1 = no such option / row.
//   OptionOfComboRow: the AArray index of combo row ARow
//   ComboRowOfOption: the combo row of AArray[AOptionIndex]
//   FormatOptionByData: the AArray index whose DataStr is AValue
function OptionOfComboRow(const AArray: array of TFormatDef; ARow: Integer): Integer;
function ComboRowOfOption(const AArray: array of TFormatDef; AOptionIndex: Integer): Integer;
function FormatOptionByData(const AArray: array of TFormatDef; const AValue: string): Integer;

const
  // =========================================================================
  // 1. DIALOG TITLES (Prefix: TITLE_)
  // =========================================================================
  TITLE_ERROR                 = 'Error';
  TITLE_PLAYBACK_ERROR        = 'Playback error';
  TITLE_CONFIRM_DELETE        = 'Confirm deletion';
  //TITLE_FILE_EXISTS           = 'File Already Exists';
  TITLE_JUST_A_MOMENT         = 'Just a moment...';
  TITLE_NEW_PLAYLIST          = 'New playlist';
  TITLE_EDIT_PLAYLIST         = 'Edit playlist';
  TITLE_NEW_AUTOPLAYLIST      = 'New auto-playlist';
  TITLE_EDIT_AUTOPLAYLIST     = 'Edit auto-playlist';
  TITLE_WARNING               = 'Warning';
  TITLE_ADD_FILES             = 'Add audio files to playlist';
  TITLE_ENGINE_BUSY           = 'Engine busy';
  TITLE_LIBRARY_EMPTY         = 'Library empty';
  TITLE_SELECTION_EMPTY       = 'Selection empty';
  TITLE_FILE_BUSY             = 'File busy';
  TITLE_AUDIO_DEVICE_ERROR    = 'Audio device error';
  TITLE_SCAN_IN_PROGRESS      = 'Scan in progress';
  TITLE_SCAN_QUEUED           = 'Library scan queued';
  TITLE_TAGS_NOT_SAVED        = 'Tags not saved';
  TITLE_PREFERENCES           = 'Preferences';
  TITLE_REPAIR_LIBRARY        = 'Repair library database';
  TITLE_SCANNING_FILES        = 'Scanning files...';
  TITLE_STORAGE_OFFLINE       = 'Storage offline';
  TITLE_MISSING_FILES         = 'Missing files detected';

  // =========================================================================
  // 2. STATIC UI LABELS & FALLBACKS (Prefix: LBL_)
  // =========================================================================
  LBL_UNKNOWN_ARTIST          = 'Unknown Artist';
  LBL_UNKNOWN_ALBUM           = 'Unknown Album';
  LBL_UNKNOWN_GENRE           = 'Unknown Genre';
  LBL_UNKNOWN_DEVICE          = 'Unknown Device';
  LBL_ARTIST_INFO_UNAVAILABLE = 'No artist information available.';

  LBL_DEFAULT_PLAYLIST        = 'Default PlayList';
  LBL_USE_GLOBAL_PREFS        = '[ Use global preferences ]';
  LBL_CUSTOM_PREFS            = '[Custom]';
  LBL_UNIQUE_PER_TRACK        = '(Unique per track)';
  LBL_MULTIPLE_VALUES         = '<< Multiple Values >>';
  LBL_NOT_AVAILABLE           = ' (not available)';  // Suffix for an unreachable library folder

  // Standard Button Labels (uMetadataCustodian)
  LBL_BTN_RETRY               = 'Retry';
  LBL_BTN_DISCARD             = 'Discard';
  LBL_META_KIND_TAGS          = 'tags';        // kind of a failed save in the "Tags Not Saved" dialog
  LBL_META_KIND_REPLAYGAIN    = 'ReplayGain';

  LBL_BY_ALBUM                = 'By album';
  LBL_BY_FOLDER               = 'By folder';
  LBL_FLAT_LIST               = 'Flat list (no groups)';
  LBL_CODEC_DSD               = 'DSD';
  FMT_MENU_DSD_DOP            = 'Native DSD%d (DoP Output)';
  FMT_MENU_DSD_PCM            = 'DSD%d (PCM Conversion)';
  LBL_MENU_NATIVE_RATE        = 'Native rate (bypass)';
  LBL_COLLAPSE_NODE           = 'Collapse node';
  LBL_EXPAND_NODE             = 'Expand node';
  LBL_EMBEDDED_ART            = 'Embedded';
  LBL_NO_DURATION             = '-:--';
  LBL_CHANNELS_MONO           = 'Mono';
  LBL_CHANNELS_STEREO         = 'Stereo';
  // Hints
  HINT_SHUFFLE_OFF            = 'Shuffle (off)';
  HINT_SHUFFLE_TRACKS         = 'Shuffle (tracks)';
  HINT_SHUFFLE_ALBUMS         = 'Shuffle (albums)';
  HINT_REPEAT_OFF             = 'Repeat (off)';
  HINT_REPEAT_ALL             = 'Repeat (all)';
  HINT_REPEAT_TRACK           = 'Repeat (track)';

  // =========================================================================
  // 3. STATUS BAR & PROGRESS TEXT (Prefix: STATUS_)
  // =========================================================================
  STATUS_IDLE                 = '';
  STATUS_PREP_SCAN            = 'Preparing library scan...';
  STATUS_SCANNING_FULL        = 'Scanning library...';
  STATUS_REPAIRING_FULL       = 'Repairing library...';
  STATUS_BTN_RPSCANNING       = '[ ReplayGain scanning... Click here to view ]';
  FMT_STATUS_BTN_RPSCANNING   = '[ ReplayGain scanning (%d/%d)... Click here to view ]';  // album x of y
  STATUS_CLEANING_CACHE       = 'Cleaning cache...';
  STATUS_PREPARING_TRACK_UPDATES = 'Preparing track updates...';
  FMT_STATUS_SAVING_METADATA  = 'Saving track metadata (%d / %d)...';
  STATUS_FINALIZING_UPDATES   = 'Finalizing updates...';
  FMT_STATUS_SCAN_FOUND       = '%s (%d found)';
  FMT_STATUS_SCAN_TRACKS      = '%s (Tracks: %d / %d)';
  FMT_STATUS_SCANNING_TRACK   = 'Scanning track %d of %d...';
  FMT_STATUS_RG_CHECKING      = 'Checking existing tags %d/%d...';
  STATUS_RG_SKIPPING          = '(Skipping — already scanned)';
  FMT_STATUS_RG_FAST_FORWARD  = 'Fast-forwarding Album %d of %d...';
  FMT_STATUS_RG_ANALYZING     = 'Analyzing Album %d of %d (Track %d/%d)';
  FMT_STATUS_RG_PARALLEL      = '%s  (+%d more)';   // the track started last, the others in work
  STATUS_RG_DECODE_ERROR      = 'Decode error / unsupported';
  STATUS_RG_ALBUM_INCOMPLETE  = 'Album incomplete (not saved)';

  // =========================================================================
  // 4. MESSAGES use in MessageBoxes (Prefix: MSG_)
  // =========================================================================
  MSG_BACKGROUND_IO_BUSY      = 'Background file updates are running.' + sLineBreak + sLineBreak +
                                'Please wait a few seconds and try again.';
  MSG_IMPORT_COMPLETE         = 'Import complete!';
  FMT_MSG_IMPORTED_AS         = 'Import complete!' + sLineBreak + sLineBreak +
                                'A playlist with that name already exists, so the playlist was saved as "%s".';
  MSG_EXPORT_COMPLETE         = 'Export complete!';
  MSG_NO_VALID_TRACKS         = 'No valid tracks found in the current selection.';
  MSG_FILE_BUSY               = 'This audio track is currently being updated in the background.' + sLineBreak +
                                'Please try playing it again in a few seconds.';
  MSG_DEVICE_SETTINGS_FAILED  = 'Could not apply settings to the audio device.';
  MSG_SCAN_IN_PROGRESS        = 'A library scan is already running.';
  MSG_BACKGROUND_TASK_RUNNING = 'A background task is currently running.';
  MSG_SCAN_QUEUED             = 'A library scan has been queued and will start automatically once this task is complete.';
  MSG_REPAIR_LIBRARY_CONFIRM  = 'This will completely rebuild your current library and perform a deep scan from scratch.' + sLineBreak +
                                'This may take a while depending on the size of your library.' + sLineBreak + sLineBreak +
                                'Are you sure you want to proceed?';
  MSG_STORAGE_OFFLINE         = 'One or more of the selected tracks are located on a disconnected drive.' + sLineBreak + sLineBreak +
                                'Please reconnect the drive to edit these tags.';
  MSG_MISSING_FILES_RESCAN    = 'One or more of the selected tracks no longer exist on your drive.' + sLineBreak + sLineBreak +
                                'Would you like to rescan your library now to fix these broken links?';

  // =========================================================================
  // 5. PASCAL FORMAT TEMPLATES (Prefix: FMT_ requires SafeFormat %s %d)
  // =========================================================================
  FMT_LOG_SCAN_CHANGES        = '[Library Manager] Scan complete. Found %d tracks (%d added, %d modified, %d deleted). Saving database...';
  FMT_LOG_SCAN_NO_CHANGES     = '[Library Manager] Scan complete. Found %d tracks. No changes detected.';

  FMT_ERR_NAME_DUPLICATE      = 'The name "%s" already exists.' + sLineBreak + 'Please choose a different name.';
  FMT_ERR_PLAYEDIT_RESERVED   = '"%s" is a reserved system playlist name.' + sLineBreak + 'Please choose a different name.';

  // For TMainForm.AppException
  FMT_ERR_UNEXPECTED          = 'An unexpected error occurred:' + sLineBreak + sLineBreak +
                                '%s' + sLineBreak + sLineBreak +
                                'The details have been written to the log.';
  FMT_ERR_SHORTCUT_FILESAVE   = 'Could not save the shortcut: ' + sLineBreak + 'Error: %s';
  FMT_ERR_PL_EXPORT           = 'Failed to export playlist:' + sLineBreak + 'Error: %s';
  FMT_CONFIRM_DELETE_ONE_PL   = 'Are you sure you want to delete %s?';
  FMT_CONFIRM_DELETE_MULTI_PL = 'Are you sure you want to delete %d selected playlists?';

  FMT_MSG_FILE_NOT_FOUND      = 'The file could not be found or the drive is offline:' + sLineBreak + 'Path: "%s"';
  FMT_MSG_DEVICE_SETTINGS_FAILED = 'Could not apply settings to the audio device:' + sLineBreak + '%s';
  FMT_RES_DSD                 = 'DSD%d';
  FMT_RES_PCM                 = '%d-bit / %.1f kHz';
  FMT_MSG_SAVE_FAILED_HEAD    = '%d of %d files could not be updated:';
  FMT_MSG_SAVE_FAILED_LINE    = '• %s (%s): %s';
  FMT_MSG_SAVE_FAILED_MORE    = '… and %d more files (see the application log).';
  MSG_SAVE_FAILED_RETRY       = 'Retry to save these files again, or Discard the changes.';
  FMT_TOP_META_TRACK_OF       = 'Track %d of %d  •  %s / %s';
  FMT_TOP_META_TRACK          = 'Track %d  •  %s';
  FMT_RATE_KHZ_DEC            = '%.1f kHz';
  FMT_RATE_KHZ_INT            = '%d kHz';
  FMT_DURATION_HM             = '%dh %dm';
  FMT_DURATION_MS             = '%dm %ds';
  FMT_INS_SAMPLE_RATE         = '%d Hz';
  FMT_INS_BIT_DEPTH           = '%d-bit';
  FMT_SIZE_MB                 = '%.2f MB';
  FMT_INS_RATING              = '%d / 5';
  FMT_COVER_PAGE_INFO         = '%s   •   [%d/%d] %s';
  FMT_COVER_INFO_DSD          = 'DSD%d (1-bit / %.1f MHz)  •  %s';
  FMT_COVER_INFO_PCM          = '%d-bit / %.1f kHz  •  %s';
  FMT_CHANNELS_MULTI          = '%d Channels';

  // =========================================================================
  // 6. ENGINE TAG TEMPLATES (Prefix: TAGFMT_ requires custom text replacement)
  // =========================================================================
  LBL_BIT_PERFECT             = 'Bit-Perfect';
  // Top banner while a track is being opened
  LBL_WAITING_FOR_DRIVE       = 'Waiting for drive...';
  FMT_LOG_PLAYBACK_STALLED    = '[Playback] Playback of "%s" waited %d.%d s for the drive (slow or sleeping drive?).';
  FMT_LOG_SLOW_OPEN           = '[Playback] Opening "%s" took %d.%d s (slow or sleeping drive?).';

  // =========================================================================
  // 7. ERROR MESSAGES (Prefix: ERR_)
  // =========================================================================

  // 7A. Startup & File System Errors
  ERR_FILE_NOT_FOUND          = 'File not found:';

  // 7B. Audio Engine & WASAPI Errors
  ERR_AUDIO_UNKNOWN           = 'An unknown system or driver fault occurred during audio playback. Please check your DAC connection or restart the application.';
  ERR_AUDIO_INVALID           = 'Invalid audio format or corrupted file header.';
  ERR_AUDIO_INUSE             = 'The audio device is being used by another application in Exclusive Mode.';
  ERR_AUDIO_EXCLDISABLED      = 'Exclusive Mode is disabled for this device in Windows Sound Settings.';
  ERR_AUDIO_RATE              = 'The selected Sample rate is not supported by this device.';
  ERR_AUDIO_DISABLED          = 'Audio device disconnected or invalid output. Please check your DAC settings.';
  ERR_AUDIO_RESOURCES_INVALID = 'The device reset the audio stream (for example when it was switched on or off).';
  ERR_AUDIO_DEVICE_UNAVAILABLE = 'The audio device is not available. It may be switched off or disconnected. Switch it on, or choose another device in Preferences, and press Play again.';
  ERR_AUDIO_ENDPOINTFAIL      = 'Failed to create audio endpoint.';
  ERR_AUDIO_BUFFUNALIGNED     = 'The buffer duration is not aligned with the period.';
  ERR_AUDIO_ACCESSDENIED      = 'Access Denied. Check device permissions.';
  ERR_AUDIO_FAIL              = 'Unspecified Error (E_FAIL). The device may be unstable.';
  ERR_AUDIO_MULTI_CHANNEL     = 'Audio with more than 2 channels is not supported. Playback is limited to mono and stereo files.';

  // 7C. Decoder Specific Errors
  ERR_DECODE_NOTDSD           = 'Not a DSF File.';
  ERR_DECODE_DSDHEADER        = 'Invalid DSF Header: BlockSize or Channels is zero.';
  ERR_DECODE_FLACINIT         = 'FLAC Decoder could not be initialized.';
  ERR_DECODE_FLACFAIL         = 'FLAC Init Failed.';
  ERR_DECODE_NOTWAV           = 'Not a valid WAV file.';
  ERR_DECODE_WAVINVALID       = 'Could not find audio data in WAV file.';

  // 7D. Editor & Validation Errors
  ERR_EDIT_EMPTYNAME          = 'The name cannot be empty.';
  ERR_EDIT_INVALIDCHARS       = 'The name contains invalid characters: \ / : * ? " < > |';
  ERR_EDIT_RENAMEFAIL         = 'Could not rename the playlist file. It may be locked or open in another program.';
  ERR_EDIT_VALIDNUMBER        = 'Numeric field requires valid numbers (e.g. 1990 OR 1995).';
  ERR_EDIT_VALIDDATE          = 'Date format error. Use: 14d, 2w, 1m, or 1y.';
  ERR_SHORTCUT_DELETE         = 'Could not delete the shortcut. It may be locked by another program.';
  // 7F. File, Playlist, Decoder & Resampler Errors
  ERR_READING_FILE_PREFIX     = 'Error reading file: ';
  MSG_TAG_EDITOR_READ_FAILED  = 'The tags of this file could not be read. It will not be changed when you save.';
  FMT_LOG_TAGEDIT_SKIPPED     = 'Tag editor: %d file(s) could not be read and were not changed.';
  ERR_DECODE_DSF_RATE         = 'Invalid or corrupted DSF sample rate.';
  ERR_DECODE_DSF_STEREO       = 'DSD-to-PCM requires a 2-channel stereo DSF file.';
  ERR_RESAMPLER_INIT               = 'Failed to initialize the resampler.';   // the built-in resampler (AuResample)
  ERR_INVALID_FILE_PATH       = 'Invalid file path.';
  FMT_ERR_OS_ERROR            = 'OS Error %d: %s';
  ERR_RENAME_FAILED           = 'RenameFile failed.';
  ERR_ATOMIC_SAVE_PARAMS      = 'Invalid parameters for atomic save.';
  ERR_ATOMIC_SAVE_UNKNOWN     = 'Unknown exception during atomic save.';
  FMT_ERR_ATTEMPTED_FORMAT    = ' (Attempted %d Hz / %d-bit)';
  ERR_LASTFM_NO_RESPONSE      = 'no response from ws.audioscrobbler.com';

  // ===========================================================================
  // 7E. LAST.FM SCRAPER STATUS & ERROR STRINGS (uLastFmScraper)
  // ===========================================================================
  ERR_LASTFM_MISSING_API_KEY = 'Biographies come from Last.fm, and that needs a Last.fm API key of your own (free). Enter it in Preferences > System > Artist information.';
  ERR_LASTFM_NETWORK_PREFIX  = 'Last.fm network error: ';
  ERR_LASTFM_API_PREFIX      = 'Last.fm: ';
  ERR_LASTFM_GENERIC         = 'Last.fm returned an error.';
  // Last.fm error 10 (invalid key) / 26 (suspended key)
  ERR_LASTFM_KEY_REJECTED    = 'Artist information is not available: Last.fm did not accept the API key. Check it in Preferences > System > Artist information. Saved biographies and pictures still work.';
  LOG_LASTFM_KEY_REJECTED    = '[Artist Info] Last.fm did not accept the API key (invalid or blocked). Biographies of new artists cannot be fetched until the key is replaced.';
  ERR_LASTFM_PARSE_PREFIX    = 'Error parsing biography data: ';
  ERR_LASTFM_RESOLVE_PREFIX  = 'Error resolving biography: ';

  // ===========================================================================
  // General open / save dialog filters
  // ===========================================================================
  DIALOG_FILTER_PLAYLISTS     = 'Playlists (*.m3u;*.m3u8)|*.m3u;*.m3u8';
  DIALOG_FILTER_AUDIO_FILES   = 'Audio Files (*.flac;*.wav;*.dsf;*.dff)|*.flac;*.wav;*.dsf;*.dff';

  // ===========================================================================
  // ARTIST INFO & COVER ART POPUP HINTS (AuArtistInfo / AuCoverViewer)
  // ===========================================================================

  // Artist Info Popup Hints
  HINT_ARTIST_WEB               = 'Search the web for this artist';
  HINT_ARTIST_IMAGE             = 'Add or replace the artist picture (Ctrl+O, drop a file, or paste with Ctrl+V)';
  HINT_ARTIST_CLEAR_IMAGE       = 'Remove the artist picture (Del)';
  HINT_ARTIST_EDIT_START        = 'Edit the biography (F2)';
  HINT_ARTIST_EDIT_DONE         = 'Finish editing (F2). Changes are saved automatically.';
  HINT_ARTIST_REFRESH           = 'Reload the biography and picture from online sources (F5). Your own picture and edited biography are kept.';
  HINT_ARTIST_IMG_EDIT          = 'Click or press Ctrl+O to replace the picture. You can also drop an image file or paste one with Ctrl+V.';
  HINT_ARTIST_MEMO_EDIT         = 'Type or paste the biography. Press F2 when done; changes are saved automatically.';

  // Cover Art Popup Hints
  HINT_COVER_PREV               = 'Previous image (Left arrow, right-click or scroll up)';
  HINT_COVER_NEXT               = 'Next image (Right arrow, click or scroll down)';
  // Playlist Manager Hints (AuPlaylistManager)
  HINT_PLM_LIST                 = 'Your playlists. Auto-playlists (funnel icon) are listed below the divider; their tracks are chosen by rules.';
  HINT_PLM_NEW                  = 'Create a new standard playlist (Ctrl+N).';
  HINT_PLM_NEW_AUTO             = 'Create a new auto-playlist. Its tracks are chosen automatically by rules you set.';
  HINT_PLM_EDIT                 = 'Edit the selected playlist (F2). For an auto-playlist this includes its rules.';
  HINT_PLM_REMOVE               = 'Remove the selected playlist(s) (Del).';
  HINT_PLM_IMPORT               = 'Import an M3U or M3U8 file as a standard playlist. If the name is taken, a number is added, e.g. "Name (2)".';
  HINT_PLM_EXPORT               = 'Export the selected playlist as an M3U8 file. An auto-playlist is exported with its current tracks, without its rules.';

  // ===========================================================================
  // ARTIST INFO POPUP DIALOGS & STATUS (AuArtistInfo)
  // ===========================================================================
  LBL_FETCHING_INFO             = 'Fetching information...';
  LBL_BIO_UNAVAILABLE           = 'Biography not available.';
  FMT_ARTIST_LIB_STATS          = 'Library: %d Albums, %d Tracks';

  DLG_SELECT_ARTIST_PIC_TITLE   = 'Select artist picture';
  DLG_FILTER_ARTIST_PIC         = 'All Supported Images|*.jpg;*.jpeg;*.png;*.bmp|JPEG Images (*.jpg;*.jpeg)|*.jpg;*.jpeg|PNG Images (*.png)|*.png|Bitmap Images (*.bmp)|*.bmp';

  DLG_REMOVE_ARTIST_PIC_TITLE   = 'Remove artist picture';
  MSG_REMOVE_ARTIST_PIC_CONFIRM = 'Are you sure you want to remove the picture for %s?';

  DLG_REFRESH_ARTIST_TITLE      = 'Refresh Artist Info';
  MSG_REFRESH_ARTIST_CONFIRM    = 'Refreshing from online sources will overwrite the existing biography and picture for %s.' + LineEnding + LineEnding + 'Do you want to continue?';

  // ===========================================================================
  // TAG EDITOR & INSPECTOR STRINGS (AuPropertiesForm)
  // ===========================================================================
  CAP_TAG_EDITOR_PROPERTIES     = 'Properties';
  HINT_BTN_WEB_COVER            = 'Search the web for the album cover. Copy an image and press Ctrl+V here, or drop an image file.';
  DLG_SELECT_COVER_ART_TITLE    = 'Select new cover art';
  DLG_FILTER_COVER_ART          = 'All Supported Images|*.jpg;*.jpeg;*.png;*.bmp|JPEG Images (*.jpg;*.jpeg)|*.jpg;*.jpeg|PNG Images (*.png)|*.png|Bitmap Images (*.bmp)|*.bmp';

  // Cover Art Size Validation Strings
  TITLE_COVER_TOO_LARGE         = 'Cover art too large';
  ERR_COVER_TOO_LARGE           = 'The selected cover image exceeds the 15 MB maximum limit for embedded artwork.';
  FMT_ERR_COVER_FILE_TOO_LARGE  = '"%s" (%.1f MB) exceeds the 15 MB maximum size limit for embedded cover art.';
  FMT_ERR_COVER_TOO_MANY_PIXELS = '"%s" is %d x %d pixels. Pictures of more than 67 megapixels (8192 x 8192) are not opened.';
  FMT_COVER_TOO_MANY_PIXELS     = 'This picture is %d x %d pixels: too large to show (the limit is 67 megapixels, 8192 x 8192).';

  LBL_INSPECTOR_DEFAULT         = '  Inspector';
  LBL_INSPECTOR_FILE_PREFIX     = '  File: ';
  LBL_INSPECTOR_MULTI_SELECTION = 'Multiple selection:';
  LBL_NEVER                     = 'Never';

  INS_HDR_AUDIO_CHAR            = '--- AUDIO CHARACTERISTICS ---';
  INS_HDR_FILE_INFO             = '--- FILE INFORMATION ---';
  INS_HDR_USER_STATS            = '--- USER STATISTICS ---';
  INS_HDR_RAW_META              = '--- RAW METADATA ---';

  INS_LBL_FORMAT                = 'Format: ';
  INS_LBL_SAMPLE_RATE           = 'Sample Rate: ';
  INS_LBL_BIT_DEPTH             = 'Bit Depth: ';
  INS_LBL_DURATION              = 'Duration: ';
  INS_LBL_FILE_SIZE             = 'File Size: ';
  INS_LBL_FOLDER_PATH           = 'Folder Path: ';
  INS_LBL_FILE_NAME             = 'File Name: ';
  INS_LBL_DATE_ADDED            = 'Date Added: ';
  INS_LBL_PLAY_COUNT            = 'Play Count: ';
  INS_LBL_LAST_PLAYED           = 'Last Played: ';
  INS_LBL_RATING                = 'Rating: ';
  INS_LBL_TRACKS_SELECTED       = 'Tracks Selected: ';
  INS_LBL_TOTAL_FILE_SIZE       = 'Total File Size: ';

  // ===========================================================================
  // VIRTUAL FOLDER / ALIAS EDITOR STRINGS (AuVirtualFolderForm)
  // ===========================================================================
  FMT_TITLE_CREATE_VIRTUAL_FOLDER    = 'Create Virtual Folder - %s';
  FMT_TITLE_EDIT_VIRTUAL_FOLDER      = 'Edit Virtual Folder - %s';
  FMT_ALIAS_LOCATION_HEADER          = 'External folders to merge into "%s" (or click Auto-find to scan library):';
  FMT_CONFIRM_DELETE_VIRTUAL_FOLDER  = 'Are you sure you want to remove the virtual folder "%s"?' + sLineBreak + sLineBreak +
                                       'Your actual music files will NOT be deleted or modified.';

  LBL_ALIAS_SEARCH_TERM              = 'Auto-find term:';
  LBL_ALIAS_SEARCH_IN                = 'Search in:';
  LBL_ALIAS_TAG_ARTIST               = 'Artist / performer';
  LBL_ALIAS_TAG_COMPOSER             = 'Composer';
  LBL_ALIAS_TAG_ALBUM_TITLE          = 'Album / title';
  LBL_ALIAS_TAG_COMMENT_GENRE        = 'Comment / genre';
  LBL_ALIAS_TAG_FOLDER               = 'Folder name';

  ERR_ALIAS_DB_UNAVAILABLE           = 'Library database reference is not available.';
  MSG_ALIAS_MIN_SEARCH_LEN           = 'Please enter at least 2 characters in the Auto-find Term box to search.';

  FMT_ALIAS_AUTOFIND_ADDED           = 'Auto-find added %d related folder(s) matching "%s" (highlighted above). Press Delete or click Remove to exclude any unwanted folders.';
  FMT_ALIAS_AUTOFIND_EXISTING        = 'All %d external folder(s) matching "%s" are already in the list.';
  FMT_ALIAS_AUTOFIND_NONE            = 'No external folders found matching "%s". You can type another search term or enable more tags above and click Auto-find again.';

  HINT_ALIAS_NAME                    = 'The name of this virtual folder in the library tree.';
  HINT_ALIAS_SEARCH_TERM             = 'The name or word Auto-find searches for, e.g. Bach. Leave empty to use the virtual folder name.';
  HINT_ALIAS_SEARCH_IN               = 'Choose which tags Auto-find searches.';
  HINT_ALIAS_TAG_ARTIST              = 'Search the Artist, Album artist and Performer tags.';
  HINT_ALIAS_TAG_COMPOSER             = 'Search the Composer tag.';
  HINT_ALIAS_TAG_ALBUM_TITLE          = 'Search the Album and Title tags.';
  HINT_ALIAS_TAG_COMMENT_GENRE       = 'Search the Comment and Genre tags.';
  HINT_ALIAS_TAG_FOLDER              = 'Search the folder names on disk.';
  HINT_ALIAS_LIST                    = 'The folders shown inside this virtual folder. Folders just found by Auto-find are highlighted, so you can check them.';
  HINT_ALIAS_ADD                     = 'Choose one or more folders to add. You can also drag folders here from Windows Explorer.';
  HINT_ALIAS_AUTOFIND                = 'Search the library for folders whose tracks match the Auto-find term in the selected tags.';
  HINT_ALIAS_REMOVE                  = 'Remove the selected folder(s) from the list (Del). The folders themselves are not changed.';
  HINT_ALIAS_SAVE                    = 'Save the virtual folder and update the library.';

  // ===========================================================================
  // REPLAYGAIN SCANNER STRINGS (AuReplayGainForm)
  // ===========================================================================
  TITLE_RG_SCANNER                   = 'ReplayGain scanner';
  TITLE_RG_SCAN_COMPLETE             = 'Scan complete';
  TITLE_RG_SCANNER_BUSY              = 'Scanner busy';
  TITLE_RG_SCANNER_CRASHED           = 'Scanner crashed';

  LBL_RG_COL_ALBUM_TRACK             = 'Album / track';
  LBL_RG_COL_TRACK_GAIN              = 'Track gain';
  LBL_RG_COL_TRACK_PEAK              = 'Track peak';
  LBL_RG_COL_ALBUM_GAIN              = 'Album gain';
  LBL_RG_COL_ALBUM_PEAK              = 'Album peak';
  LBL_RG_COL_STATUS                  = 'Status';
  LBL_RG_EMPTY_CELL                  = '---';

  STATUS_RG_INITIALIZING             = 'Initializing ...';
  STATUS_RG_ABORTING                 = 'Aborting engine...';
  STATUS_RG_HALTING                  = 'Halting scan after current track completes...';
  STATUS_RG_READY_TO_SAVE            = 'Ready to save';
  STATUS_RG_TRACK_ONLY               = 'Ready to save (track gain only: no album tag)';
  STATUS_RG_DRIVE_OFFLINE            = 'Drive offline';
  STATUS_RG_FILE_MISSING             = 'File missing';

  MSG_RG_INFO_TEXT                   = 'ReplayGain scans your audio files to ensure consistent playback volume ' +
                                       'across your entire library, preserving full dynamic range without clipping.' + sLineBreak + sLineBreak +
                                       'Note: This requires a deep, high-precision analysis of your audio data. ' +
                                       'Scanning large libraries or high-resolution DSD albums may take a long time to finish.';
  MSG_RG_LIBRARY_EMPTY               = 'No scanned audio tracks were found in the database.';
  MSG_RG_SELECTION_EMPTY             = 'No valid audio tracks were highlighted.';
  MSG_RG_SCANNER_BUSY                = 'A ReplayGain calculation is actively running.';
  MSG_RG_ALL_FILES_HAVE_INFO         = 'All audio files already carry ReplayGain info.';
  MSG_RG_SELECTED_HAVE_INFO          = 'All selected audio files already carry ReplayGain info.';

  ERR_RG_UNKNOWN_THREAD_FAULT        = 'An unknown thread fault occurred.';

  FMT_ERR_RG_THREAD_CRASH            = 'The background analysis thread encountered a fatal error:' + sLineBreak + sLineBreak + '%s';
  FMT_RG_ALL_HAVE_INFO               = 'All %d audio tracks (%d albums) already have ReplayGain info.' + sLineBreak + sLineBreak +
                                       'Do you want to re-calculate them anyway?';
  FMT_RG_FOUND_MISSING               = 'Analysed selection. Found %d albums missing ReplayGain info.' + sLineBreak + sLineBreak +
                                       'How would you like to proceed?';
  FMT_RG_BTN_SCAN_MISSING            = 'Scan Missing Only (%d)';
  FMT_RG_BTN_RECALC_ALL              = 'Recalculate All (%d)';
  FMT_RG_GRID_ALBUM_TRACK            = '[%s]  %s';
  FMT_RG_WARN_DRIVE_OFFLINE          = '⚠️ WARNING: %d file(s) are on a disconnected drive. Please reconnect it.';
  FMT_RG_WARN_FILES_MISSING          = '⚠️ WARNING: %d file(s) are missing. A Library Rescan is recommended.';
  FMT_RG_WARN_DECODE_FAILED          = '⚠️ WARNING: %d file(s) failed to decode or are unsupported.';
  FMT_RG_WARN_ALBUM_INCOMPLETE       = '⚠️ WARNING: %d file(s) not saved because their album could not be analysed completely.';
  FMT_RG_WARN_NO_ALBUM_TAG           = '⚠️ NOTE: %d file(s) have no album tag: they get a track gain only, no album gain.';

  // =========================================================================
  // 8. LOG MESSAGES (Prefix: LOG_ plain text, FMT_LOG_ SafeFormat templates)
  //    Severity ([INFO] / [WARNING] / [ERROR]) is added by AddLog / AddWarning,
  //    so a message never contains its own severity tag.
  // =========================================================================
  // For TMainForm.AppException
  FMT_LOG_UNHANDLED_EXCEPTION = '[Unhandled Exception] %s: %s';
  LOG_UNHANDLED_NO_OBJECT     = '[Unhandled Exception] (no exception object)';
  FMT_LOG_EXCEPTION_SENDER    = ' (Sender: %s)';
  FMT_LOG_EXCEPTION_PLACE     = ' at %s';
  FMT_LOG_FILE_BUSY           = '[File busy] Error playing file "%s" because of a background update.';
  FMT_LOG_FILE_NOT_FOUND      = '[Playback error] File "%s" could not be found or the drive is offline.';
  FMT_LOG_PLAY_FAILED         = '[Engine Error] Failed to play file: "%s". Reason: %s';
  LOG_REASON_UNKNOWN          = 'unknown.';
  FMT_LOG_DEVICE_SETTINGS_FAILED = '[Device Error] Could not apply settings. Reason: %s';
  FMT_LOG_OPENING_TRACK       = 'Opening track for playback: "%s"';
  FMT_LOG_PAUSED              = '[Paused] "%s"';
  FMT_LOG_RESUMED             = '[Resumed] "%s"';
  LOG_PREFIX_ENGINE_FATAL     = '[Engine Fatal Error] ';
  // Technical details of an unexpected audio engine exception
  FMT_LOG_ENGINE_ERROR_DETAIL = '[Engine Fatal Error] Details: %s';
  FMT_LOG_DB_LOAD_FAILED      = '[Library Manager] Failed to load library database: %s';
  FMT_LOG_DB_BACKUP           = '[Library Manager] Original database preserved as "%s".';
  LOG_DB_NOT_SAVED            = '[Library Manager] Database not saved: the previous database could not be loaded or backed up.';
  FMT_LOG_DB_SAVE_FAILED      = '[Library Manager] Failed to save database: %s';
  LOG_DB_REPAIR_STARTED       = '[Library Manager] Database repair started.';
  LOG_DB_SCAN_STARTED         = '[Library Manager] Database scan started.';
  FMT_LOG_REASON_DRIVE_MISSING = 'drive "%s" not found: disconnected, or its drive letter changed';
  LOG_REASON_FOLDER_MISSING   = 'folder not found on the drive: renamed, moved or deleted';
  FMT_LOG_LIB_ROOT_LOST       = '[Library Manager] Library folder "%s" became unavailable during the scan (%s). ' +
                                'It was skipped and its library entries were kept. Rescan when the folder is available again.';
  FMT_LOG_LIB_ROOT_OFFLINE    = '[Library Manager] Library folder "%s" is not available (%s). ' +
                                'It was skipped and its library entries were kept.';
  LOG_LIB_SCAN_ABORTED        = '[Library Manager] The scan was aborted by an unexpected error. ' +
                                'The existing library was kept unchanged; please rescan.';
  FMT_LOG_META_COVER_TOO_LARGE = '[Metadata] Cover art for "%s" is larger than %d MB and was not written; the existing cover was kept.';
  FMT_LOG_META_NOT_UPDATED    = '[Metadata] "%s" was not updated: %s.';
  LOG_SKIP_FILE_MISSING       = 'the file no longer exists or the drive is offline';
  LOG_SKIP_FILE_IN_USE_OTHER  = 'the file is in use by another program';
  LOG_SKIP_FILE_UNREADABLE    = 'the file could not be read';
  LOG_SKIP_NOT_WRITABLE       = 'tags cannot be written to this file';
  FMT_LOG_SKIP_FILE_IN_USE    = 'the file is in use by %s';
  LOG_SKIP_TAGS_NOT_PREPARED  = 'the new tag values could not be prepared';
  LOG_SKIP_FILE_NOT_SAVED     = 'the file could not be saved';
  FMT_LOG_META_PARTIAL_TAG    = '[Metadata] "%s": the tag was partly unreadable; the unreadable part was discarded.';
  FMT_LOG_META_SAVE_ERROR     = '[Metadata] Error saving tags to "%s": %s';
  FMT_LOG_META_BATCH_STARTED  = '[Metadata] Background batch started. Processing %d files...';
  FMT_LOG_META_WORKER_FAULT   = '[Metadata] Unexpected worker fault: %s';
  FMT_LOG_META_BATCH_PARTIAL  = '[Metadata] Batch finished. %d of %d files updated, %d could not be updated (see the messages above).';
  FMT_LOG_META_BATCH_DONE     = '[Metadata] Batch finished successfully. %d files updated.';

  // Settings log (uSettingsLog). Names as in the Preferences window
  LOG_SET_AUDIO               = 'Audio settings:';
  LOG_SET_RESAMPLER           = 'Resampler settings:';
  LOG_SET_SYSTEM              = 'System settings:';
  FMT_LOG_SET_ITEM            = '%s: %s';
  LOG_PURGED_NOTICE           = '--- [Older log lines removed to save memory] ---';
  // Log window > Save to File...
  DIALOG_TITLE_SAVE_LOG       = 'Save log';
  DIALOG_FILTER_TEXT_FILES    = 'Text Files (*.txt)|*.txt';
  FMT_LOG_SAVE_FILE_NAME      = 'AulumicNSLog_%s.txt';   // %s = the date and time
  FMT_ERR_SAVE_LOG            = 'The log could not be saved to "%s".'#13#10#13#10'%s';
  ERR_LOG_EMPTY               = 'The log is empty.';
  FMT_LOG_PREF_CHANGED        = 'Preferences: %s changed from %s to %s';
  FMT_LOG_PREF_TURNED         = 'Preferences: %s turned %s';
  FMT_LOG_PREF_FOLDER_ADDED   = 'Preferences: Library folder added: "%s"';
  FMT_LOG_PREF_FOLDER_REMOVED = 'Preferences: Library folder removed: "%s"';
  LBL_SET_ON                  = 'ON';
  LBL_SET_OFF                 = 'OFF';
  LBL_SET_DEVICE              = 'Output device';
  // The output interface
  LBL_SET_OUTPUT_API          = 'Output interface';
  LBL_SET_API_WASAPI          = 'WASAPI exclusive';
  LBL_SET_API_ASIO            = 'ASIO';
  LBL_SET_PCM_BUFFER          = 'PCM buffer size';
  LBL_SET_DSD_BUFFER          = 'DSD buffer size';
  LBL_SET_DOP                 = 'Play DSD natively (DoP)';
  LBL_SET_DSD_GAIN            = 'DSD gain';
  LBL_SET_DSD_LOWPASS         = 'DSD low-pass';
  LBL_SET_RESAMPLE            = 'Enable PCM resampling';
  LBL_SET_LOCK_VOLUME         = 'Lock volume to 100%';
  LBL_SET_REPLAYGAIN          = 'ReplayGain mode';
  LBL_SET_PREAMP              = 'Headroom';
  LBL_SET_SOFTCLIP            = 'Enable soft clipping limiter';
  LBL_SET_RS_QUALITY          = 'Resample quality';
  LBL_SET_RS_TARGET44         = 'Target rate for 44.1 kHz';
  LBL_SET_RS_TARGET48         = 'Target rate for 48 kHz';
  LBL_SET_RS_UPPHASE          = 'Upsampling phase';
  LBL_SET_RS_DOWNPHASE        = 'Downsampling phase';
  LBL_SET_RS_EXCLUDE          = 'Exclude';
  LBL_SET_RS_NO_DSD           = 'Exclude DSD from resampling';
  LBL_SET_RS_BANDWIDTH        = 'Bandwidth';
  LBL_SET_RS_ANTIALIAS        = 'Anti-Aliasing';
  LBL_SET_HIGHRES_TIMER       = 'Enable high-resolution kernel timer';
  LBL_SET_AFFINITY            = 'Optimize CPU core affinity';
  LBL_SET_MMCSS               = 'Enable MMCSS';
  LBL_SET_KEEP_AWAKE          = 'Keep music drives awake during playback';

  // Output format lines of the audio engine (AuLog)
  FMT_LOG_OUT_PCM             = 'Output to DAC: %s, %s (PCM%s)';
  FMT_LOG_OUT_DOP             = 'Output to DAC: native %s (%s MHz) via DoP';
  FMT_LOG_OUT_NATIVE_DSD      = 'Output to DAC: native %s (%s MHz) over ASIO';
  FMT_LOG_OUT_BITS            = '%d-bit';
  FMT_LOG_OUT_BITS_CONTAINER  = '%d-bit in a %d-bit container';
  FMT_LOG_OUT_RESAMPLED       = ', resampled from %s';
  LOG_OUT_FROM_DSD            = ', converted from DSD';

  // Drive keep-alive (logged once per change)
  FMT_LOG_KEEPALIVE_LOST      = '[Keep-Alive] Drive "%s" cannot be reached; Aulumic keeps trying.';
  FMT_LOG_KEEPALIVE_BACK      = '[Keep-Alive] Drive "%s" is reachable again.';
  FMT_LOG_KEEPALIVE_START_FAILED = '[Keep-Alive] Could not start: %s. Playback continues without it.';
  // Sample rate fallback dialog
  FMT_LOG_FALLBACK_REFUSED    = '[Playback] The DAC did not accept %s.';
  FMT_LOG_FALLBACK_RESAMPLE   = '[Playback] Sample rate fallback: resampling to %s.';
  LOG_FALLBACK_CANCELLED      = '[Playback] Sample rate fallback cancelled; the track was not played.';
  // Why the next track is not gapless
  FMT_LOG_GAPLESS_RATE        = '[Playback] Next track "%s" is %s (current %s): the stream is reopened, so this change is not gapless.';
  FMT_LOG_GAPLESS_DSD_RATE    = '[Playback] Next track "%s" has another DSD rate: the stream is reopened, so this change is not gapless.';
  FMT_LOG_GAPLESS_DSD_PCM     = '[Playback] Next track "%s" switches between DSD and PCM: the stream is reopened, so this change is not gapless.';
  // Phase timing in seconds as whole seconds + milliseconds (dot, like the durations)
  FMT_LOG_DB_LOADED_DETAIL    = 'Library Database Loaded (%d tracks; read %d.%.3ds, parse %d.%.3ds, dictionary %d.%.3ds)';
  // Counterpart of the load line (build = under the library lock,
  // write = temporary file, flush and replace; together the pause in the UI)
  FMT_LOG_DB_SAVED_DETAIL     = '[Library Manager] Library database saved (%d tracks, %d.%d MB; build %d.%.3ds, write %d.%.3ds)';
  FMT_LOG_RG_PARTIAL_DECODE   = '[ReplayGain scanner] "%s" decoded only %d of %d frames; skipped.';
  FMT_LOG_RG_ALBUM_INCOMPLETE = '[ReplayGain scanner] Album "%s": only %d of %d tracks could be analysed; album not saved.';
  FMT_LOG_RG_FILE_ERROR       = '[ReplayGain scanner] Error on file "%s": %s';
  FMT_LOG_RG_NO_ALBUM_TAG     = '[ReplayGain scanner] %d track(s) without an album tag in "%s": track gain only, no album gain (first: "%s").';
  LOG_RG_ERROR_UNKNOWN        = 'Error unknown';
  FMT_LOG_RG_STARTED          = '[ReplayGain scanner] Scan started. Albums in queue: %d (Force Overwrite: %s)';
  LOG_RG_ABORTED              = '[ReplayGain scanner] Scan aborted by the user.';
  FMT_LOG_RG_FINISHED         = '[ReplayGain scanner] Scan finished. Harvested tracks: %d. Stale/Missing files: %d.';
  FMT_LOG_STATS_LOAD_FAILED   = '[UserStats] Failed to load user stats database: %s';
  // Automatic headroom (ALHeadroom)
  FMT_LOG_HEADROOM_LOAD_FAILED = '[Headroom] The learned peaks could not be read (%s). They will be learned again.';
  FMT_LOG_HEADROOM_SAVE_FAILED = '[Headroom] The learned peaks could not be saved: %s';
  FMT_LOG_STATS_BACKUP        = '[UserStats] Original stats file preserved as "%s".';
  FMT_LOG_STATS_SAVE_FAILED   = '[UserStats] Failed to save user stats database: %s';
  FMT_LOG_PLAYLISTS_LOAD_FAILED = '[Playlists] Failed to load the playlists: %s';
  FMT_LOG_PLAYLISTS_BACKUP    = '[Playlists] Original playlists file preserved as "%s".';
  FMT_LOG_PLAYLISTS_SAVE_FAILED = '[Playlists] Failed to save the playlists: %s';
  FMT_LOG_FILE_USERS_MANY     = '%d programs';
  LOG_FILE_USER_SELF          = 'Aulumic itself';
  LOG_FILE_USER_UNKNOWN       = 'unknown program';
  FMT_LOG_FILE_USER_PID       = '%s (PID %d)';
  // =========================================================================
  // 11. CONFIGURATION ARRAYS (Dropdowns, Queries, and Engine Mapping)
  // =========================================================================

  // Busy messages per TAppEngineState (the array itself is in uEngineStateManager,
  // so this unit does not need uEngineStateManager: no circular unit reference)
  BUSY_MSG_LIBRARY            = 'The library scanner is currently running.';
  BUSY_MSG_REPLAYGAIN         = 'The ReplayGain scanner is currently running.';
  BUSY_MSG_TAG_EDITOR         = 'The Properties Editor is currently saving metadata to files.';
  BUSY_MSG_BACKGROUND_IO      = 'Metadata is currently being saved to files.';

  PREBAKED_QUERIES: array[0..7] of TFormatDef = (
    (DisplayName: '--- Select a template ---'; DataStr: ''),
    (DisplayName: 'Recently added (14 days)'; DataStr: '%added% IN LAST 14d'),
    (DisplayName: 'Recently added (30 days)'; DataStr: '%added% IN LAST 30d'),
    (DisplayName: 'Top rated (4 & 5 stars)'; DataStr: '%rating% >= 4'),
    (DisplayName: 'Favourites (hearted)'; DataStr: '%favorite% = 1'),
    (DisplayName: 'Last played (30 days)'; DataStr: '%lastplayed% IN LAST 30d'),
    (DisplayName: 'Heavy Rotation (> 20 Plays)'; DataStr: '%playcount% >= 20'),
    (DisplayName: 'High-Res Audiophile'; DataStr: '%bitdepth% >= 24; %samplerate% >= 88200')
  );

  // 14 items (0..13) — uses [ • %resolution%] without %codec% or parentheses
  HEADER_FORMAT_OPTIONS: array[0..13] of TFormatDef = (

    // Album-First
    (DisplayName: 'Album';                         DataStr: '%album%'),
    (DisplayName: 'Album • Artist';                DataStr: '%album%[ • %first_albumartist%]'),
    (DisplayName: 'Album • Artist • Specs';        DataStr: '%album%[ • %first_albumartist%][ • %resolution%]'),
    (DisplayName: 'Album • Year • Artist';         DataStr: '%album%[ • %year%][ • %first_albumartist%]'),
    (DisplayName: 'Album • Year • Artist • Specs'; DataStr: '%album%[ • %year%][ • %first_albumartist%][ • %resolution%]'),
    (DisplayName: '-'; DataStr: ''),

    // Artist-First (Standard)
    (DisplayName: 'Artist • Album';                DataStr: '[%first_albumartist% • ]%album%'),
    (DisplayName: 'Artist • Album • Specs';        DataStr: '[%first_albumartist% • ]%album%[ • %resolution%]'),
    (DisplayName: 'Artist • Year • Album';         DataStr: '[%first_albumartist% • ][%year% • ]%album%'),
    (DisplayName: 'Artist • Year • Album • Specs'; DataStr: '[%first_albumartist% • ][%year% • ]%album%[ • %resolution%]'),
    (DisplayName: '-'; DataStr: ''),

    // Year, Genre & Folder
    (DisplayName: 'Year • Album';                  DataStr: '[%year% • ]%album%'),
    (DisplayName: 'Year • Album • Specs';          DataStr: '[%year% • ]%album%[ • %resolution%]'),
    (DisplayName: 'Genre • Artist • Album';        DataStr: '[%first_genre% • ][%first_albumartist% • ]%album%')
  );

  // 9 items (0..8) — uses [ • %resolution%] without %codec% or parentheses
  TRACK_FORMAT_OPTIONS: array[0..8] of TFormatDef = (
    // Title-First (Grouped Views)
    (DisplayName: 'Title';                        DataStr: '%title%'),
    (DisplayName: 'Title • Specs';                DataStr: '%title%[ • %resolution%]'),
    (DisplayName: 'Title • Artist';               DataStr: '%title%[ • %first_artist%]'),
    (DisplayName: '-'; DataStr: ''),

    // Artist-First (Flat List & Compilations)
    (DisplayName: 'Artist • Title';               DataStr: '[%first_artist% • ]%title%'),
    (DisplayName: 'Artist • Title • Specs';       DataStr: '[%first_artist% • ]%title%[ • %resolution%]'),
    (DisplayName: 'Artist • Album • Title';       DataStr: '[%first_artist% • ][%album% • ]%title%'),
    (DisplayName: '-'; DataStr: ''),

    // Physical
    (DisplayName: 'File name';                    DataStr: '%filename%')
  );

  DBLCLICK_OPTIONS: array[0..1] of TFormatDef = (
    (DisplayName: 'Play immediately'; DataStr: '0'),
    (DisplayName: 'Expand / collapse node'; DataStr: '1')
  );

  RESAMPLE_QUAL_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: 'Ultra high (32-bit precision)'; DataStr: '0'),
    (DisplayName: 'Very high (28-bit precision)'; DataStr: '1'),
    (DisplayName: 'High (24-bit precision)'; DataStr: '2'),
    (DisplayName: 'Medium (20-bit precision)'; DataStr: '3'),
    (DisplayName: 'Standard (16-bit precision)'; DataStr: '4')
  );

  BYPASS_THRESH_OPTIONS: array[0..8] of TFormatDef = (
    (DisplayName: 'None (resample all)'; DataStr: '0'),
    (DisplayName: 'Rates >= 88200'; DataStr: '88200'),
    (DisplayName: 'Rates >= 96000'; DataStr: '96000'),
    (DisplayName: 'Rates >= 176400'; DataStr: '176400'),
    (DisplayName: 'Rates >= 192000'; DataStr: '192000'),
    (DisplayName: 'Rates >= 352800'; DataStr: '352800'),
    (DisplayName: 'Rates >= 384000'; DataStr: '384000'),
    (DisplayName: 'Rates >= 705600'; DataStr: '705600'),
    (DisplayName: 'Rates >= 768000'; DataStr: '768000')
  );

  REPLAYGAIN_OPTIONS: array[0..2] of TFormatDef = (
    (DisplayName: 'Disabled'; DataStr: '0'),
    (DisplayName: 'Track level'; DataStr: '1'),
    (DisplayName: 'Album level'; DataStr: '2')
  );

  DSD_GAIN_OPTIONS: array[0..1] of TFormatDef = (
    (DisplayName: '+0.0 dB (purist - preserve headroom)'; DataStr: '0'),
    (DisplayName: '+6.0 dB (standard - match PCM volume)'; DataStr: '6')
  );

  GROUPING_MODE_OPTIONS: array[0..2] of TFormatDef = (
    (DisplayName: 'By album'; DataStr: '0'),
    (DisplayName: 'By folder'; DataStr: '1'),
    (DisplayName: 'Flat list (no grouping)'; DataStr: '2')
  );

  PHASE_OPTIONS: array[0..2] of TFormatDef = (
    (DisplayName: 'Linear phase'; DataStr: '0'),
    (DisplayName: 'Intermediate phase'; DataStr: '1'),
    (DisplayName: 'Minimum phase'; DataStr: '2')
  );

  BANDWIDTH_OPTIONS: array[0..2] of TFormatDef = (
    (DisplayName: 'Slow roll-off (default)'; DataStr: '0'),
    (DisplayName: 'Medium roll-off'; DataStr: '1'),
    (DisplayName: 'Fast roll-off'; DataStr: '2')
  );

  ANTI_ALIAS_OPTIONS: array[0..2] of TFormatDef = (
    (DisplayName: 'Maximum (steep filter / no aliasing)'; DataStr: '0'),
    (DisplayName: 'High (moderate filter / balanced)'; DataStr: '1'),
    (DisplayName: 'Standard (gentle filter / best timing)'; DataStr: '2')
  );

  TARGET_RATE_44_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '44100'; DataStr: '44100'),
    (DisplayName: '88200'; DataStr: '88200'),
    (DisplayName: '176400'; DataStr: '176400'),
    (DisplayName: '352800'; DataStr: '352800'),
    (DisplayName: '705600'; DataStr: '705600')
  );

  TARGET_RATE_48_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '48000'   ; DataStr: '48000'),
    (DisplayName: '96000'   ; DataStr: '96000'),
    (DisplayName: '192000'  ; DataStr: '192000'),
    (DisplayName: '384000'  ; DataStr: '384000'),
    (DisplayName: '768000'  ; DataStr: '768000')
  );

  BUFFER_SIZE_OPTIONS: array[0..7] of TFormatDef = (
    (DisplayName: '50 ms'   ; DataStr: '50'),
    (DisplayName: '100 ms'  ; DataStr: '100'),
    (DisplayName: '200 ms'  ; DataStr: '200'),
    (DisplayName: '250 ms'  ; DataStr: '250'),
    (DisplayName: '300 ms'  ; DataStr: '300'),
    (DisplayName: '350 ms'  ; DataStr: '350'),
    (DisplayName: '500 ms'  ; DataStr: '500'),
    (DisplayName: '1000 ms' ; DataStr: '1000')
  );

  PREAMP_DB_OPTIONS: array[0..6] of TFormatDef = (
    (DisplayName: '0.0 dB'; DataStr: '0'),
    (DisplayName: '-1.0 dB'; DataStr: '-1'),
    (DisplayName: '-2.0 dB'; DataStr: '-2'),
    (DisplayName: '-3.0 dB'; DataStr: '-3'),
    (DisplayName: '-4.0 dB'; DataStr: '-4'),
    (DisplayName: '-5.0 dB'; DataStr: '-5'),
    (DisplayName: '-6.0 dB'; DataStr: '-6')
  );

  // The one Headroom setting of Preferences >
  // Volume: Automatic (TManagerConfig.AutoHeadroom, PreampDB 0) or a fixed
  // preamp (AutoHeadroom off). The fixed values are PREAMP_DB_OPTIONS'.
  HEADROOM_AUTO = 'auto';
  HEADROOM_OPTIONS: array[0..7] of TFormatDef = (
    (DisplayName: 'Automatic'; DataStr: HEADROOM_AUTO),
    (DisplayName: '0.0 dB'; DataStr: '0'),
    (DisplayName: '-1.0 dB'; DataStr: '-1'),
    (DisplayName: '-2.0 dB'; DataStr: '-2'),
    (DisplayName: '-3.0 dB'; DataStr: '-3'),
    (DisplayName: '-4.0 dB'; DataStr: '-4'),
    (DisplayName: '-5.0 dB'; DataStr: '-5'),
    (DisplayName: '-6.0 dB'; DataStr: '-6')
  );

  // ReplayGain scan, tracks of an album measured at the same time
  RG_THREADS_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '1 track (coolest)'; DataStr: '1'),
    (DisplayName: '2 tracks'; DataStr: '2'),
    (DisplayName: '3 tracks'; DataStr: '3'),
    (DisplayName: '4 tracks'; DataStr: '4'),
    (DisplayName: '8 tracks (fastest)'; DataStr: '8')
  );

  TONE_BASS_HZ_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '80 Hz'; DataStr: '80'),
    (DisplayName: '120 Hz'; DataStr: '120'),
    (DisplayName: '150 Hz'; DataStr: '150'),
    (DisplayName: '200 Hz'; DataStr: '200'),
    (DisplayName: '250 Hz'; DataStr: '250')
  );

  // Five bands. The three middle bands share out
  // the range 220 Hz .. 3 kHz, so they never cross.
  TONE_LOWMID_HZ_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '220 Hz'; DataStr: '220'),
    (DisplayName: '300 Hz'; DataStr: '300'),
    (DisplayName: '400 Hz'; DataStr: '400'),
    (DisplayName: '500 Hz'; DataStr: '500'),
    (DisplayName: '700 Hz'; DataStr: '700')
  );

  TONE_MID_HZ_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '800 Hz'; DataStr: '800'),
    (DisplayName: '1000 Hz'; DataStr: '1000'),
    (DisplayName: '1500 Hz'; DataStr: '1500'),
    (DisplayName: '2000 Hz'; DataStr: '2000'),
    (DisplayName: '2500 Hz'; DataStr: '2500')
  );

  TONE_HIGHMID_HZ_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '3000 Hz'; DataStr: '3000'),
    (DisplayName: '4000 Hz'; DataStr: '4000'),
    (DisplayName: '5000 Hz'; DataStr: '5000'),
    (DisplayName: '6000 Hz'; DataStr: '6000'),
    (DisplayName: '8000 Hz'; DataStr: '8000')
  );

  TONE_TREBLE_HZ_OPTIONS: array[0..4] of TFormatDef = (
    (DisplayName: '4000 Hz'; DataStr: '4000'),
    (DisplayName: '6000 Hz'; DataStr: '6000'),
    (DisplayName: '8000 Hz'; DataStr: '8000'),
    (DisplayName: '10000 Hz'; DataStr: '10000'),
    (DisplayName: '12000 Hz'; DataStr: '12000')
  );

implementation

function OptionOfComboRow(const AArray: array of TFormatDef; ARow: Integer): Integer;
var
  I, Row: Integer;
begin
  Result := -1;
  if ARow < 0 then
    Exit;
  Row := 0;
  for I := Low(AArray) to High(AArray) do
    if AArray[I].DataStr <> '' then
    begin
      if Row = ARow then
        Exit(I);
      Inc(Row);
    end;
end;

function ComboRowOfOption(const AArray: array of TFormatDef; AOptionIndex: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (AOptionIndex < Low(AArray)) or (AOptionIndex > High(AArray)) or
     (AArray[AOptionIndex].DataStr = '') then
    Exit;
  Result := 0;
  for I := Low(AArray) to AOptionIndex - 1 do
    if AArray[I].DataStr <> '' then
      Inc(Result);
end;

function FormatOptionByData(const AArray: array of TFormatDef; const AValue: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if AValue = '' then
    Exit;
  for I := Low(AArray) to High(AArray) do
    if (AArray[I].DataStr <> '') and SameText(AArray[I].DataStr, AValue) then
      Exit(I);
end;

function GetWasapiErrorString(hr: HRESULT): string;
begin
  case DWORD(hr) of
    $8889000A,
    $80040000: Result := ERR_AUDIO_INUSE;
    $8889000E: Result := ERR_AUDIO_EXCLDISABLED;
    $88890008,
    $80070057: Result := ERR_AUDIO_RATE;
    $88890004: Result := ERR_AUDIO_DISABLED;
    $88890026: Result := ERR_AUDIO_RESOURCES_INVALID;
    $8889000F: Result := ERR_AUDIO_ENDPOINTFAIL;
    $88890001: Result := ERR_AUDIO_BUFFUNALIGNED;
    $80070005: Result := ERR_AUDIO_ACCESSDENIED;
    $80004005: Result := ERR_AUDIO_FAIL;
    else
      Result := Format('WASAPI Initialization Failed. Unknown Error Code: 0x%x', [DWORD(hr)]);
  end;
end;

end.
