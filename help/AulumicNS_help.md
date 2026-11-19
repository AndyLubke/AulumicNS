<!--
===============================================================================
  AULUMICNS HELP - MARKDOWN (rendered by AuHelp)
===============================================================================
  # Topic / ## Sub topic   -> in the topic list on the left
  ### Minor heading
  - item / "  - item"      -> bullets (two levels);  1. item -> numbered
  > text                   -> note box
  | a | b |                -> table (header row when followed by |---|)
  **bold**  *italic*  `code`     \*  \`  \\  escapes
  ![Caption](name)         -> a screenshot: help\shots\<name>.png, built into
                              the exe by Tools\MakeHelpShots.ps1
  HTML comments            -> ignored (like this block)
===============================================================================
-->

# Aulumic overview

Aulumic is a free music player for Windows. It sends your music straight to your DAC, over WASAPI exclusive mode or your DAC's ASIO driver. Out of the box nothing is touched: resampling is off, DSD goes out as DSD, and the only thing in the way is the volume control.

With the volume at 100 % and nothing else switched on, your DAC gets the audio exactly as it's stored in the file (bit-perfect). The **Bit-perfect** badge in the top banner tells you whether that's the case right now; click it to see the whole signal path. See *Configuring bit-perfect playback*.

![The main window while an album plays](02-dark-playing)

The whole program is one file, `AulumicNS.exe`: no DLLs, no separate PDF viewer. The NS stands for Native Sound, because the audio reaches your DAC as it is in the file. Your library, playlists and settings live in a **Data** folder next to it, so you can run it from any folder or a USB stick.

# Getting started

1. **Add your music:** Open Preferences (the gear in the title bar, or Ctrl+P). On the Library page, click **Add folder...** and choose the folder that holds your music. The scan starts right away, and you can follow it on the page and in the status line.
2. **Choose the output:** Click the device name at the bottom right of the main window and pick your DAC. WASAPI devices and ASIO drivers share one list.
3. **Play:** Double-click an album or a folder in the library on the left, or drag it onto the playlist on the right.

## WASAPI or ASIO?

- **WASAPI exclusive** works with any DAC that has a Windows driver. It's the one to start with.
- **ASIO** needs the ASIO driver from your DAC's maker. Go for it when you want DSD sent as native DSD instead of DoP, or when WASAPI gives you dropouts.

Both skip the Windows mixer, so neither changes your audio.

# Features

**WASAPI exclusive mode and ASIO:** Both skip the Windows audio mixer, so Windows doesn't resample or change anything. Over ASIO, DSD is sent as native DSD when the driver supports it.
*Note: while Aulumic plays, it has the device to itself. Your browser and Windows' own sounds stay silent on that device.*

**Automatic sample rate switching:** Your DAC is switched to the sample rate of each track (for example from 44.1 kHz to 192 kHz), so Windows never has to convert it.

**Supported file formats:**

- **Lossless only:** FLAC, WAV, DSF and DFF. MP3, AAC and other lossy formats won't play.
- **Mono and stereo:** Files with more than two channels won't play.
- **High resolution:** High-resolution PCM (including DXD) in FLAC or WAV, and DSD in DSF and DFF files.
- **Local files:** Your own music collection. There's no internet radio or streaming.

**Gapless playback:** No pauses or clicks between tracks that run into each other, as on live albums, concept albums or classical works.

**Volume control:** Leave the volume to your DAC for bit-perfect playback, or use the built-in volume control. It calculates in 64-bit floating point and dithers the result, so the program itself adds no rounding errors. Like every digital volume control, it uses fewer of your DAC's bits the further you turn it down.

**Library management:** Browse by folder, artist, album or genre, search the whole library, edit tags (including Composer and Performer) and covers, and combine folders with Virtual Folders. Aulumic keeps an eye on your library folders, so new and changed files show up by themselves.

**Built-in tools:** A ReplayGain scanner (EBU R128), a booklet viewer for the PDF booklets of your albums, a cover viewer, artist biographies and pictures, and a five-band tone control.

**Resampling:** Optional up- and downsampling of PCM audio with linear, intermediate or minimum phase filters. With **Headroom** on *Automatic*, an album whose peaks would not fit after resampling is lowered just far enough.

**Windows playback optimization:** The audio thread is registered with the Windows Multimedia Class Scheduler (MMCSS), so dropouts are less likely when your PC is busy.

**Look and feel:** Dark and light mode switch at once (or follow Windows), six accent colours, vector icons that stay sharp at every screen scaling, and a text size for all windows.

**Touch screens:** Swipe up and down to scroll the library, the playlist, the help and the pages of Preferences. In the booklet viewer, swipe to turn the pages, or to move a zoomed-in page. Every row has a three dots button for its menu.

# The main interface

From top to bottom:

**Title bar:** In the colours of the theme. Drag it to move the window, double-click it to maximize; snapping to the screen edges and the snap layouts of Windows 11 work as usual. The **Main menu** button (three lines) is at the left, next to the program icon; the **Preferences** gear is at the right, before the minimize button. A click on the program icon itself opens the window menu of Windows (Restore, Move, Size ...), as in every Windows program.

**Main menu:** The button with the three lines at the left of the title bar opens all main functions and tools. Dark or light mode and the accent colour are under **Theme** in this menu (and in Preferences > Appearance).

**Now Playing banner:** Shows the cover, title, album, genre, the credited artists, performers and composers, and the audio format of the playing track.

- **Cover & album title:** Click the cover or the album title to open the **Cover Art Viewer**.
- **Artists, performers & composers:** Click a name to open **Artist Info**. If there are more names than fit, click **(...)** at the end of the line to choose from the others.
- **Bit-perfect / Processed badge:** Click it to see the **Signal Path**.
- **Booklet & favourite:** If the album folder contains a PDF booklet, a **Booklet** icon appears; click it to read the booklet. Click the **Heart** to mark the playing album as a favourite.
- **Output sample rate:** Click the output rate on the right of the banner to choose another resampling target rate.
- Drag the lower edge of the banner to make it smaller or larger, and the border between the library and the playlist to change their widths. Both follow your pointer as you drag. (With *Use the graphics card* switched off, only a line moves and the size changes when you let go.)

**Search bar:** Filters the library on title, artist, album artist, composer, performer, album, genre and folder. Accents are ignored (searching for *Dvorak* also finds *Dvořák*).

![Searching the library](09-library-search)

**Refresh button:** Checks the library folders for changes and reloads the library view (F5).

**Playlist selector:** Switches between your playlists. Your own playlists come first, auto-playlists follow with a funnel icon. To create, rename or delete playlists, open the Playlist Manager.

**View & edit:** **View** changes how the playlist is grouped and shown; the pencil opens the Playlist Manager. The album header format can only be chosen while the playlist is grouped By album.

**Library pane:** Your music collection, grouped by folder, artist, album or genre. Right-click (or click the three dots on a row) for more options, such as Properties, ReplayGain or Virtual Folders. If a library folder sits on a drive that isn't connected, it's dimmed and marked **(not available)**; its tracks stay in your library.

**Playlist pane:** The tracks of the selected playlist, with the album covers in the album headers. Click the stars to rate a track or a whole album; click the cover in an album header to open the Cover Art Viewer. Right-click for more options, including the Playlist Manager.

Drag tracks or folders here from the library or from Windows Explorer; they are inserted where you drop them, and an album is never split. Drag tracks inside the playlist to change the order. Hold **Ctrl** while dropping from Explorer to replace the playlist and start playing.

**Remove dead items** (right-click menu) takes out the tracks whose files are gone. Tracks on a drive that isn't connected, or on a NAS that doesn't answer, are kept, and the message tells you how many. While a drive wakes up you'll see a small window with **Cancel**.

**Transport controls:** Shuffle, Stop, Previous, Play/Pause, Next, Jump to Now Playing and Repeat, with the position bar above them.

**Output & audio controls:** Click the device name to choose the output device, the sliders icon to open the Tone Control, or the speaker icon to change or mute the volume.

**Status line:** Shows background tasks, such as a library scan, a ReplayGain scan or saving tags. During playback it also shows engine details.

![The light theme with a smaller banner](04-light-small-banner)

# Signal Path

Click the **Bit-perfect** or **Processed** badge in the banner to see every stage between the file and your DAC. The popup keeps up with playback while it's open; click the badge again or press Esc to close it.

![The signal path of a processed DSD stream](44-signal-path)

- **Green:** The stage passes the signal on unchanged (for example *Resampler: Bypassed*).
- **Amber:** The stage changes the signal (for example ReplayGain, the tone control, the resampler or a volume below 100 %).
- **Grey:** The source file and the output device.

The stages are the source file, the decoder or the DSD transport (DoP, native DSD or DSD to PCM), ReplayGain, the tone control, the resampler, the volume, dither or the bit depth, warnings such as clipping, and the output format the device accepted. When the summary at the top says **Bit-perfect**, your DAC gets the file's samples unchanged.

# Keyboard shortcuts

All shortcuts are also listed in Preferences > Shortcuts.

## Playback & navigation

- **Play / pause:** `Space` or `Media Play/Pause`
- **Stop:** `Media Stop`
- **Next / previous track:** `Media Next` / `Media Previous`
- **Seek forward / backward:** `Ctrl + Arrow Right` / `Ctrl + Arrow Left`
- **Volume up / down:** `Ctrl + Arrow Up` / `Ctrl + Arrow Down`
- **Mute:** `Ctrl + M`
- **Shuffle / repeat:** `Ctrl + S` / `Ctrl + R`
- **Jump to Now Playing:** `Ctrl + J`
- **Play selected item:** `Enter`
- **Jump to a row:** type the first letters of its name (library tree and playlist)
- **Rate the selected playlist tracks:** `Ctrl + 1` ... `Ctrl + 5` (on a group header: the whole album); `Ctrl + 0` clears the rating
- **Change text size of a pane:** `Ctrl + Mouse Wheel`

## Application controls

- **Search:** `Ctrl + F`
- **Switch between library and playlist:** `Ctrl + Tab`
- **Add files:** `Ctrl + O`
- **Preferences:** `Ctrl + P`
- **Playlist Manager:** `Alt + P`
- **Properties (tag editor):** `Alt + Enter`
- **Tone Control:** `Ctrl + T`
- **Refresh library and playlist:** `F5`
- **Rescan library:** `Ctrl + F5`
- **Show log:** `Ctrl + L`
- **Show Debug Queue:** `Ctrl + D`
- **Help:** `F1` (in a dialog: the help of that dialog)
- **Quit:** `Ctrl + Q` / `Alt + F4`

## Shortcuts in dialogs

- **OK / Save:** `Enter`
- **Cancel / Close:** `Esc`

## Shortcuts in Playlist Manager

- **New playlist:** `Ctrl + N`
- **Edit selected playlist:** `F2`
- **Remove selected playlists:** `Del`
- **Show selected playlist:** `Enter` (or double-click)
- **Close:** `Esc`

## Shortcuts in Artist Info

- **Edit biography / finish editing:** `F2` (`Esc` also finishes editing)
- **Reload from online sources:** `F5` (not while editing; your own picture and edited biography are kept)
- **Choose artist picture:** `Ctrl + O`
- **Paste artist picture:** `Ctrl + V`
- **Remove artist picture:** `Del` (asks first; not while editing)
- **Close:** `Esc` (changes are saved automatically)

## Shortcuts in the Booklet Viewer

- **Next / previous page:** `Arrow Right` / `Arrow Left`, `Page Down` / `Page Up`, `Space`, or the mouse wheel
- **First / last page:** `Home` / `End`
- **Zoom in / out:** `+` / `-`, or `Ctrl + Mouse Wheel`; double-click switches between fit and 200 %
- **Fit to window:** `0`
- **Single pages / spreads:** `S`
- **Close:** `Esc`

# Preferences

Open Preferences from the main menu, with the gear in the title bar, or with Ctrl+P. The settings are on nine pages, listed on the left: Library, Appearance, Playlists, Output, DSD, Resampler, Volume, System and Shortcuts. Every setting has a short description under its name. **OK** keeps your changes, **Cancel** drops them.

**Cards:** Settings you set once and then leave alone sit in cards at the bottom of a page. A card is one row with a title and a line that sums up what's inside; click it (or press the space bar on it) to open it right there, and again to close it. With all cards closed a page fits the window; open a few and it scrolls. Cards you left open are open again next time.

**Related settings:** Some pages end with buttons that take you to a neighbouring subject, for example from Output to the audio thread settings on the System page.

## 1. Library page

![Preferences: Library](24-prefs-0)

- **Library folders:** The folders that make up your music library. **Add folder...** adds one; **Remove** takes it out of the library (your files stay on disk).
- **Scan now:** Checks the library folders for new, changed or removed files. A cover that was changed in another program also updates the album thumbnail. Folders on a drive that is disconnected or asleep keep their tracks. The progress is shown on the page.
- **Repair:** Rebuilds the library from scratch, including all album thumbnails. Try it when tracks are missing or the library looks wrong.
- **Watch the library folders:** New and changed files show up in the library by themselves a few seconds later. Network folders aren't watched (some NAS would never get to sleep); press Refresh (F5) or Rescan (Ctrl+F5) for those.
- **Auto-scan on startup:** Checks your library for changes at every start.

## 2. Appearance page

![Preferences: Appearance](24-prefs-1)

- **Theme:** Dark, light, or the app setting of Windows. Changes at once.
- **Accent colour:** Used for the selection, the sliders and the highlights.
- **Text size:** The size of the text in all windows.

### Card: Main Window

![The Main window card, open](24-prefs-1-mainwindow)

- **Double click:** What double-clicking a library node does: play it at once, or only open or close it.
- **Auto-collapse other nodes (accordion):** Closes the other open folders when you open one.
- **Show Artists, Albums, Genres:** Shows or hides these groups in the library pane.
- **Show peak meter:** Shows the peak meter in the banner. It covers 60 dB: green in the lower half, amber higher up, red in the top part (above about -9 dB). The top block turns red for a moment when a sample was clipped.

### Card: Text Size of the Panes

- **Library / playlist text size:** The text size of the two panes. You can also hold Ctrl and scroll the mouse wheel over a pane.

## 3. Playlists page

![Preferences: Playlists](24-prefs-2)

- **Playlists grouping, Album header format, Track format:** The defaults of the playlists; each playlist can override them in the Playlist Editor.
- **Cursor follows playback:** When a track starts, the selection moves to it, and it scrolls into view if it wasn't visible. This only happens in the playlist that is playing; a playlist you're browsing meanwhile stays where you left it. Switch it off if you'd rather keep your own selection.

## 4. Output page

![Preferences: Output](24-prefs-3)

- **Output interface:** *WASAPI exclusive* (every DAC with a Windows driver) or *ASIO* (the DAC's own ASIO driver).
- **Output device:** The DAC or sound card to play to. If you switch this device off or unplug it, it stays selected: playback stops with a message and never jumps to another device on its own. If your DAC drops out briefly while playing, Aulumic waits up to 20 seconds and then carries on.
- **PCM buffer size:** How much PCM audio is buffered ahead, in milliseconds, over WASAPI and ASIO alike; DSD converted to PCM uses it too. Make it larger if you hear stutters or dropouts. The price: volume and tone control changes reach your ears a little later.
- **Related settings:** *DSD* opens the DSD page; *Audio thread* opens that card on the System page (priority, timer and CPU core of the audio thread, which matter when you have dropouts).

## 5. DSD page

![Preferences: DSD](24-prefs-4)

- **Play DSD natively:** Sends DSD to your DAC as DSD: over WASAPI packed as DoP, over ASIO as native DSD when the driver supports it (otherwise as DoP). When it is off, DSD is converted to PCM.
- **DSD low-pass:** Applies a low-pass filter when DSD is converted to PCM.
- **DSD gain:** The level of DSD converted to PCM. `+0.0 dB` keeps the original level; `+6.0 dB` brings DSD closer to the level of FLAC and WAV files. The gain is applied at the end, together with the volume. SACDs may peak up to about 3 dB above their reference level, so with `+6.0 dB` loud passages can exceed full scale; **Headroom** on *Automatic* (Volume page) then lowers the album just as far as needed.
- **DSD buffer size:** How much DSD audio is buffered ahead when DSD goes to the DAC as DSD (DoP, or native over ASIO). A dropout there is a pop, so it needs more than PCM.

## 6. Resampler page

![Preferences: Resampler](24-prefs-5)

- **Enable PCM resampling:** Resamples PCM audio with the built-in resampler. Turn it off for bit-perfect playback.
- **Target rate for 44.1 kHz / 48 kHz:** The output rate for all files of the 44.1 kHz family (44.1, 88.2, 176.4 kHz ...) and of the 48 kHz family (48, 96, 192 kHz ...). Only whole multiples are offered.
- **Exclude:** Sample rates that are never resampled.
- **Exclude DSD from resampling:** DSD converted to PCM is not resampled afterwards.

### Card: Quality and Filter

![The Quality and filter card, open](24-prefs-5-filter)

These settings are used while PCM resampling is on. When it is off, the rows are greyed out and the summary line of the card says so.

- **Resample quality:** Higher settings resample more precisely but use more CPU.
- **Upsampling / downsampling phase:** The phase response of the filter. *Linear phase* keeps all frequencies in time but adds pre-ringing; *Minimum phase* has no pre-ringing; *Intermediate phase* is a compromise. See *Audio concepts*.
- **Bandwidth:** Where the high-frequency filter starts. *Slow roll-off* covers the full range of human hearing with a gentle filter; *Medium* and *Fast* keep more treble but need a steeper filter.
- **Anti-aliasing:** The strength of the ultrasonic filter. *Maximum* suppresses what lies above the limit most strongly but can add a little pre-ringing; *Standard* lets a small amount through, far below the music, and has less ringing.

## 7. Volume page

![Preferences: Volume](24-prefs-6)

- **Lock volume to 100%:** Leaves the volume to your DAC or amplifier. This also turns off ReplayGain, a fixed headroom and the soft clipper. At 100 % the output is bit-perfect without the lock too; the lock makes sure it stays there.
- **ReplayGain mode:** Evens out the loudness between tracks. *Track* plays every song at the same loudness; *Album* plays whole albums at the same loudness and keeps the differences between their tracks.
- **Headroom:** Room for peaks that would not fit into the output. One setting with two ways:
  - **Automatic** (the default) lowers the level only where it is needed.
  - **A fixed amount** (`0.0 dB` to `-6.0 dB`) lowers everything by that much; nothing is measured. Choose it when you want every album lowered by the same amount. With ReplayGain on, it is added to the ReplayGain gain, and the loudest sample of the track (or album) never comes above this level. It is not applied when the volume is locked to 100 %.

- **Enable soft clipping limiter:** Gently rounds off peaks that would otherwise clip. It is not needed with Headroom on Automatic; it is of use with a fixed headroom.

### Card: ReplayGain Scan

![The ReplayGain scan card, open](24-prefs-6-rgscan)

- **Tracks at the same time:** How many tracks of an album the ReplayGain scanner measures at once. With 1 track the processor stays coolest; with 4 tracks an album is scanned about three and a half times as fast, but the processor gets warmer and its fan louder. The measured values are exactly the same.

### How automatic headroom works

- **Why:** A loudly mastered recording can come out up to about 2.5 dB above full scale after upsampling, because the waveform between its samples peaks higher than the samples themselves. DSD converted to PCM with a DSD gain can do the same. Without headroom those peaks are clipped.
- **What happens:** The peaks are measured during playback, and the level of the album is lowered just as far as its highest peak needs. Nothing is clipped or limited; the album simply plays a little quieter.
- **Per album:** All tracks of an album get the same level (the tracks in one folder with the same album and album artist). A track without an album tag stands for itself.
- **First play:** The level can come down a little a few times during the loudest tracks, each time gliding within 10 ms. The album's peak is remembered, so the next time it starts at the right level.
- **Tone control:** A boost is counted in and lowered before it can clip, also without resampling; a cut costs no level. This part is found anew each time, not remembered.
- **Never touched:** Quiet albums, anything played with the volume turned down far enough, and bit-perfect playback (no resampling, no gain, tone control off).
- **Where it is kept:** In `Data\Library\headroom.adb`. Nothing is written to your music files. Delete that file to forget all remembered peaks.
- **Where you see it:** The signal path shows what is taken off, for example `Headroom -0.8 dB`. Automatic also works with the volume locked to 100 %.

## 8. System page

![Preferences: System](24-prefs-7)

- **Keep music drives awake during playback:** Stops the drives you play from falling asleep, so the next track starts without a delay. Only a tiny piece of the current and next track is read now and then; nothing is written.
- **Animations:** Short fades and gliding movements: a highlight that fades in under the pointer, lists that glide when you turn the mouse wheel, menus and dialogs that fade in. They are only shown while *Animation effects* is switched on in the Windows settings (Accessibility > Visual effects). Turn the switch off if you prefer everything to change at once.
- **Use the graphics card:** The graphics card draws the lists and other large areas, which keeps scrolling smooth, also on a 4K screen. Turn it off if parts of a window stay black or flicker with your graphics driver. The processor then draws everything, which works everywhere but is slower with large windows.

### Card: Audio Thread

![The Audio thread card, open](24-prefs-7-thread)

These settings help Windows give audio playback priority over other tasks. Leave them on unless they cause trouble on older hardware.

- **Optimize CPU core affinity:** Keeps the audio thread off CPU core 0, where Windows handles most interrupts.
- **Enable MMCSS ('Pro Audio' mode):** Registers the audio thread with Windows as a "Pro Audio" task, so it gets priority and is not throttled.
- **Enable high-resolution kernel timer (1 ms):** Sets the Windows timer to 1 ms during playback and stops Windows from slowing the player down to save power. Turn it off to save battery on a laptop.

### Card: Log

- **Always save the log:** Writes the log to `AulumicNSLog.txt` in the Data folder at every exit (the file is replaced each time). Without this switch a log is only saved after an error, as `AulumicNSLog_<date>.txt`. Turn it on when you want to report a problem or see what the last session did.

### Card: Artist information

- **Last.fm API key:** Artist Info gets its biographies from Last.fm, and Last.fm asks every program for a key. Aulumic has none built in, so you need one of your own. It's free: create an API account at last.fm/api and paste the "API key" you get into this field. Biographies you already have are still shown without a key. If someone gives you a file `LastFmKey.txt` with a key in it, put it next to `AulumicNS.exe`: while no key is entered here, Aulumic takes the key from that file at start and keeps it, so the file is only needed once.

## 9. Shortcuts page

![Preferences: Shortcuts](24-prefs-8)

All keyboard shortcuts at a glance; see also *Keyboard shortcuts*.

# Playlist Manager

The Playlist Manager is where you create, edit, import and export playlists. Open it from the main menu, with the pencil next to the playlist selector, from the playlist's right-click menu, or with Alt+P.

![The Playlist Manager](32-playlist-manager)

## Managing playlists

The list shows all your playlists: the Default playlist, your playlists, and the auto-playlists with a funnel icon. Select a playlist and use the buttons:

- **New playlist...:** Creates an ordinary playlist that you fill yourself. (Ctrl+N)
- **New auto-playlist...:** Creates an auto-playlist that fills itself from rules you set.
- **Edit...:** Changes the name, display settings and, for an auto-playlist, the rules. (F2)
- **Remove:** Deletes the selected playlists. (Del)
- **Import...:** Imports an .m3u or .m3u8 file as a new playlist.
- **Export...:** Saves the selected playlist as an .m3u8 file, to back it up or use it in another player. An auto-playlist is exported with the tracks it contains at that moment.

Double-click a playlist (or press Enter) to show it.

# Playlist Editor

The Playlist Editor opens when you create or edit a playlist.

![The Playlist Editor of a standard playlist](33-playlist-editor)

## General settings

- **Playlist name:** The name of the playlist. "Default" is reserved.
- **Grouping:** By album, By folder or Flat list. *Use global preferences* follows the setting in Preferences > Playlists.
- **Album header format:** The layout of the album headers (only when grouped By album).
- **Track format:** The layout of the tracks.

## Auto-playlist rules

![The Playlist Editor of an auto-playlist](34-autoplaylist-editor)

An auto-playlist is built from one or more rules, and each rule checks one tag. Pick a ready-made template, or build your own rules with the query builder: pick the tag, the operator and the value, then click **Add**.

### Combining rules (AND / OR)

- **AND:** A track must match every rule in the list.
- **OR:** To accept several values for one tag, type `OR` (in capitals) in the value. For example, Genre `Rock OR Jazz` includes tracks of either genre.

### Operators

- **Text:** `IS` (exact match), `<>` (is not), `HAS` (contains), `NOT HAS` (does not contain), `STARTSWITH`.
- **Numbers:** `=`, `<>`, `>`, `<`, `>=`, `<=`.
- **Dates:** `IN LAST`, followed by a number and a unit: `d` (days), `w` (weeks), `m` (months) or `y` (years). For example, `6m` means the last six months.

## Available query tags

### Text tags

- **Title, Artist, Album artist, Album, Genre, Composer, Performer, Comment:** The tags of the track.
- **Codec:** The file format: FLAC, WAV, DSF or DFF.
- **Resolution:** The audio quality as shown in the program, for example "24-bit / 96 kHz".
- **Date:** The release date as stored in the file, usually YYYY or YYYY-MM-DD.
- **File name / File path:** The name of the file and the folder where it is stored. Useful to include or exclude certain drives or folders, for example File path `HAS` "\High-Res Audio\".

### Numeric tags

- **Year:** The release year, for example 1994.
- **Track number:** The position of the track on the album.
- **Rating:** Your rating, from 1 to 5.
- **Favourite:** 1 for a favourite, 0 otherwise.
- **Play count:** How often the track was played.
- **Bit depth:** For example 16, 24 or 32.
- **Sample rate:** In Hertz, for example 44100, 96000 or 352800.

### Date tags

- **Date added:** When the track was added to your library. Use it with `IN LAST`, for example `7d`, `2w`, `6m` or `1y`.
- **Last played:** When you last played the track. It works the same way.

# Properties

Properties is where you edit the tags and cover of your files, and look up their technical details and play statistics. Open it from the main menu (Tools), by right-clicking tracks in the library or the playlist, or with Alt+Enter.

You can resize or maximize the window: the file list, the fields, the Comment box and the Inspector grow with it, and it remembers its size. On a small screen the Tags page scrolls.

![Properties: the Tags tab](35-properties)

## File list

The tracks you selected. Click a track to edit it, or select several (Shift, Ctrl or Ctrl+A) to edit them together. A dot marks a track with unsaved changes; a track whose tag cannot be read is marked with **!** and is never changed.

## 1. Tags Tab

- **Fields:** Title, Artist, Album artist, Album, Genre, Year, Track, Disc, Composer, Performer and Comment (several lines).
- **Several names:** For Artist, Album artist, Genre, Composer and Performer, separate several entries with a semicolon (;).
- **Several tracks:** Fields that differ between the selected tracks show *Multiple values*; Title and Track stay unique per track. A value you type in a shared field is applied to all selected tracks. Only the fields you change are written.
- **Cover:** **Load...** chooses an image file, **Search the web** looks for the cover online, **Remove** takes the cover out of the selected files. You can also drop an image file on the window or paste one with Ctrl+V.

## 2. Inspector Tab

![Properties: the Inspector tab](36-properties-inspector)

The technical details of your files; you can't change anything here: the audio format, the file (size, location, date added), the play statistics and every tag exactly as it is stored in the file. With several tracks selected it shows their number and total size.

Click **Save** to write the changes; they're written in the background, so you can keep listening. **Cancel** (or Esc) drops them. DFF files can be tagged too.

# Tone Control

Open the Tone Control with Ctrl+T or the sliders icon next to the speaker icon.

![The Tone Control](46-tone-control)

A five-band semi-parametric tone control (bass, low mid, mid, high mid and treble): for each band you choose the frequency and the gain. Bass and treble are shelves: they raise or lower everything below or above their frequency. The three middle bands work around their frequency.

- **Enable:** Turns the tone control on or off. When it's off, it's out of the signal path completely.
- **Frequency:** The centre frequency of each band.
- **Gain:** Up to ±10.0 dB per band. Scroll the mouse wheel over a slider, or use the arrow keys when it has the focus. **Flat** sets all bands to 0 dB.
- **The curve:** The graph above the bands shows what the five bands do together, from 20 Hz to 20 kHz. It's worked out from the filters that are really used, so what you see is what you hear. A dot marks each band you've set. When the tone control is off, the curve is grey: it shows your settings, but they aren't applied.

A boost raises the peaks of the music. With Headroom set to Automatic (Preferences > Volume), the level is lowered just enough to keep them from clipping, and a line under the curve tells you by how much: "Level lowered by 1.4 dB to avoid clipping".

A change glides in over a fraction of a second, also when you switch the tone control on or off, so you never hear a click while the music plays.

When DSD goes out as DSD, the tone control and the volume control don't apply: a DSD stream is passed on as it is. The Tone Control window then says "disabled for DSD" in its title and its controls are greyed out; your settings are kept and work again with the next PCM track.

# ReplayGain scanner

The ReplayGain scanner measures the loudness of your files with the built-in EBU R128 meter, so tracks and albums play at a similar level. Open it from the main menu (Tools > Calculate ReplayGain, for the whole library), or right-click items in the library or the playlist.

## The scanning process

![The ReplayGain scanner at work](37-replaygain-scan)

First choose whether only the files without ReplayGain tags are scanned, or all of them. The scan reads all the audio, so a large library or DSD albums can take a while; Preferences > Volume > ReplayGain scan lets it measure several tracks of an album at the same time.

- **Albums** are always scanned complete, so the album gain is right. An album is the tracks of one folder with the same album and album artist.
- **Tracks without an album tag** don't count as an album: each is measured on its own and gets a track gain only (the results and the log say so). In Album mode such a track plays with its track gain.

- **Hide:** Hides the window while the scan continues; the status line shows the progress, click it to show the window again.
- **Stop:** Stops the scan after the current track.

## Scan results

![The results of a scan](38-replaygain-results)

Each file is listed with its track gain and peak, its album gain and peak (empty for a track without an album tag), or the reason it could not be measured (for example a disconnected drive, a moved file or a damaged file). Nothing is written to your files until you click **Save all**; the tags are then written in the background. **Cancel** drops the results.

# Virtual Folders

Sometimes an album belongs in more than one place: under the composer and under the orchestra, for example. A Virtual Folder lets albums appear in another library folder without copying or moving any files.

![The Virtual Folder editor](39-virtual-folder)

## What is a Virtual Folder?

A Virtual Folder is a small link file (`.aullink`) inside a library folder that shows the contents of one or more other folders. It opens right inside the library tree, as if the music were stored there; it is shown with a link icon.

## Creating and managing Virtual Folders

Right-click a folder in the library and choose **Create Virtual Folder...**, or right-click a Virtual Folder and choose **Edit Virtual Folder...** or **Remove Virtual Folder**.

- **Name:** The name in the library tree.
- **Auto-find term:** The name or word to search for; press Enter to run **Auto-find** at once. You can run several searches in a row to combine several artists or composers. If left empty, Auto-find uses the name.
- **Search in:** Artist / performer, Composer, Album / title, Comment / genre and Folder name.
- **Auto-find:** Searches the library for folders whose tracks match every word; accents are ignored. Tracks in disc sub folders (such as `CD1`) are added as their album folder. New folders are added to the list and selected, so you can check them.
- **Add folder...:** Choose a folder yourself, or drag folders from Windows Explorer into the list.
- **Remove:** Removes the selected folders from the list (Del). The folders themselves are not changed.

## Common use cases

- **Composer and performer:** For an orchestra folder, run **Auto-find** with the orchestra's name: every album where the orchestra is credited (as Artist, Album artist or Performer) is linked into it.
- **Your own collections:** For a collection such as "Late Night Favourites", create a Virtual Folder and link the albums with **Auto-find** or by dragging folders. The albums stay where they are and also appear in your collection.

# Cover Art Viewer

Click the cover or the album title in the banner, or the cover in an album header of the playlist.

![The Cover Art Viewer](40-cover-viewer)

The viewer shows the cover as large as the window allows, with the format of the track below it. If the album folder holds more images (a back cover, booklet scans in a *Scans* folder), click, right-click, scroll the mouse wheel or use the arrow keys to step through them; Home and End go to the first and the last. The embedded cover comes first, unless the folder has its own front cover.

# Artist Info

Click an artist, performer or composer in the banner.

![Artist Info](41-artist-info)

Artist Info shows the biography and a picture of the artist, and how many albums and tracks of the artist are in your library. The information comes from Last.fm, Wikipedia and TheAudioDB (the artist's name is sent to these services) and is kept in the Data folder, so it's there right away next time. For the biographies you need a free Last.fm API key: enter it in Preferences > System > Artist information.

- **Edit (F2):** Edit the biography; it is saved automatically.
- **Picture (Ctrl+O):** Choose your own picture, drop an image file on the window, or paste one with Ctrl+V. **Remove (Del)** deletes it.
- **Search the web:** Opens a web search for the artist (and starts editing, so you can paste text).
- **Refresh (F5):** Reloads the information from the online sources. A picture you chose and a biography you edited are kept; to get the online version back, remove the picture or empty the biography, then press F5.

![Editing the biography](42-artist-info)

# Booklet Viewer

When the playing album has a PDF booklet (in its folder, in a sub folder such as *Scans* or *Artwork*, or in the album folder above a *CD1* / *Disc 2* folder), the **Booklet** icon appears in the banner. Click it to read the booklet in the built-in viewer, which uses the PDF engine of Windows.

![The Booklet Viewer showing two pages side by side](45-booklet)

- **Single / Spread:** One page at a time, or two facing pages like an open booklet (the cover alone first).
- **Zoom:** The minus, fit and plus buttons, `+` / `-`, `Ctrl + Mouse Wheel` or a double-click. Drag the page or use the mouse wheel to move around when zoomed in.
- **Other booklets:** When the album has more than one PDF, the button on the left switches between them.
- **Open with the PDF program of Windows:** The folder button on the right.

# Audio concepts

## I. Core playback & formats

- **Bit-perfect:** The audio reaches your DAC exactly as it is stored in the file, without any change.
- **PCM (pulse code modulation):** The basis of almost all digital audio, including CD, WAV and FLAC. PCM stores the sound wave as a series of measurements (samples). The sample rate is how many samples are taken per second (for example 44.1 kHz); the bit depth is how precise each sample is (for example 16 or 24 bits).
- **FLAC (Free Lossless Audio Codec):** FLAC makes files smaller without losing any quality; when played, the audio is identical to the original. Lossy formats such as MP3 or AAC permanently remove audio information.
- **DSD (Direct Stream Digital):** A 1-bit format, used for SACD (DSF and DFF files). DSD can be sent unchanged to a DAC that supports it; volume control and processing such as ReplayGain are then not applied. If your DAC doesn't support DSD, turn off *Play DSD natively*; DSD is then converted to PCM during playback.
- **DoP (DSD over PCM):** DoP packs the unchanged DSD data into 24-bit PCM frames, so connections that only handle PCM can carry it. The DAC unpacks it and plays it as native DSD, without any loss.
- **Native DSD (ASIO):** Over ASIO, a driver that supports DSD receives the DSD data directly, without DoP packing.

## II. Digital signal processing (DSP) & resampling

- **Resampling:** Upsampling (for example from 44.1 kHz to 176.4 kHz) moves most of the filtering from the DAC to your PC: the DAC still filters, but at a higher rate, where its filter has less to do. Whether that sounds better depends on the DAC. Downsampling is needed when a file has a higher rate than your DAC supports.
- **Filter phase:** Resampling needs a digital filter, and this filter affects the timing of the frequencies.
  - **Linear phase:** All frequencies stay exactly in time, but a very short "pre-ringing" can occur just before a sharp sound.
  - **Minimum phase:** No pre-ringing; the ringing moves to just after the sound, where it is usually considered less audible.
  - **Intermediate phase:** Halfway between the two.

## III. Volume & dynamics

- **64-bit floating-point volume:** Volume and all other PCM processing are calculated in 64-bit floating point, so the calculation itself adds no audible error. When the result has fewer bits than the calculation, it is dithered (TPDF). A digital volume control still lowers the signal inside the DAC's fixed number of bits: at -24 dB a 24-bit DAC has about 20 bits left for the music. For most listening that is plenty; for the last bit of resolution, lock the volume and use the DAC or amplifier.
- **ReplayGain and clipping:** Albums are mastered at very different levels. ReplayGain adjusts the playback level, so you don't have to keep changing the volume. Raising a quiet track can push peaks above 0 dBFS, which causes clipping; the peak stored with the ReplayGain values and the Headroom setting prevent this.
- **Inter-sample peaks and headroom:** Digital audio stores samples, but what you hear is the smooth wave through them, and between two samples that wave can be higher than both. Modern masters are often pushed until their samples touch full scale, so the wave itself goes above it. A resampler computes new samples on that wave and finds those peaks; they do not fit into the output format and would be cut off (clipping). Headroom on Automatic lowers the level of such an album by exactly the missing amount, usually a fraction of a dB and rarely more than 2.5 dB. Everything else stays as it is.

## IV. System performance

- **MMCSS (Multimedia Class Scheduler Service):** A Windows service that gives registered audio threads priority. The audio thread is registered as a "Pro Audio" task (Preferences > System), also while the window is minimized.
- **Power throttling:** Windows slows down programs whose window is minimized or hidden. With the *High-resolution kernel timer* option on, the player asks to be left out of that.

# Configuring bit-perfect playback

Out of the box the output is bit-perfect as long as the volume is at 100 %. To make sure it stays that way:

- **Lock the volume:** In Preferences > Volume, turn on *Lock volume to 100%*, so you can't turn it down by accident.
- **ReplayGain off:** Keep ReplayGain turned off, so the level of the tracks is not changed.
- **Resampling off:** Keep PCM resampling turned off.
- **Tone control off:** Keep the tone control disabled (Ctrl+T).
- **DSD natively:** Keep *Play DSD natively* turned on, so DSF and DFF files reach your DAC as DSD.

> The badge in the banner shows **Bit-perfect** when the DAC receives the samples unchanged. Click it to see which stage changes the signal when it shows **Processed**.

# Log files & troubleshooting

Aulumic keeps a log of each session: library scans, playback errors, files that couldn't be saved and the like.

![The log window](22-log)

- **Show log:** Main menu > Tools > Show log... (or `Ctrl + L`). Warnings and errors are marked. **Copy**, **Save to file...** and **Clear** work on the whole log.
- **Saved log:** If errors were logged, the log is saved as `AulumicNSLog_<date>.txt` in the Data folder at exit. If there were no errors, nothing is saved, unless *Always save the log* is on (Preferences > System > Log): then `AulumicNSLog.txt` is written at every exit.
- **Dropouts:** If the music cuts out for a moment, check the log: you'll find "Dropout at about m:ss in the track", which means the output buffer ran empty. When a stream ends, a summary line shows the number of dropouts, the least music that was buffered ahead and the slowest buffer. A larger buffer size (Preferences > Output for PCM, Preferences > DSD for DSD sent as DSD) helps with dropouts. If you hear a hiccup and the log shows no dropout, the cause lies outside Aulumic: the driver, USB or the DAC.
- **Black or flickering areas in a window:** Turn off *Use the graphics card* (Preferences > System), and please let me know which graphics card and driver version you have.
- **Debug Queue (Ctrl+D):** Shows what the player is doing: the play queue, the next track and the engine's state. Useful when you report a problem.
- **ShutdownTraceLog.txt:** Only written next to the program when an error occurs while it closes. Please include it and the log when you report a problem.
- **HangReport_<date>.txt:** Written next to the program when the window stops responding for 5 seconds (Windows shows "Not responding"). It lists what each part of the program was doing at that moment, and its last line says when the window responded again. If it stays frozen, end it in the Task Manager; the report is already written. Please include it when you report a freeze.

# Your data

Everything lives in a **Data** folder next to the program: the library, the play statistics (ratings, play counts, favourites), the playlists, the peaks remembered by the automatic headroom, the artist information and the settings (`AulumicNS.ini`). Album thumbnails are kept in a **Cache** folder. If the program folder can't be written to (for example in *Program Files*), `%APPDATA%\AulumicNS` is used instead.

The library and the playlists are saved at once after every change, so a crash or a power cut loses nothing. To move to another computer, copy the program together with its Data folder. To remove it, delete the program file with its Data and Cache folders. Nothing is installed anywhere else, and your music files are only ever changed when you save tags or ReplayGain values yourself.

# System requirements

## Minimum requirements

- **Operating system:** Windows 10 or Windows 11 (64-bit). The booklet viewer uses the PDF engine of Windows 10 and later. Text is set in Segoe UI Variable on Windows 11 and in Segoe UI on Windows 10.
- **Graphics:** Any graphics card with a Windows 10 driver. Without a usable one the processor draws everything.
- **Processor (CPU):** Any 64-bit (x86-64) dual-core processor. Resampling at the highest quality and DSD-to-PCM conversion at high rates need more processing power.
- **Memory (RAM):** 4 GB.
- **Screen resolution:** 1280 x 720.

## Recommended specifications

- **Processor (CPU):** Intel Core i5 / AMD Ryzen 5 or better.
- **Memory (RAM):** 8 GB or more, for large libraries and playlists.
- **Screen resolution:** 1920 x 1080 or higher. 4K displays and every Windows scaling are supported.
- **Audio hardware:** A DAC or sound card with a Windows driver (WASAPI Exclusive Mode) or an ASIO driver.

# Acknowledgements

**Aulumic Music Player:** Copyright © 2026 André Lubke.

Aulumic is free software: you may use, share and change it under the terms of the GNU General Public License, version 3. It comes without any warranty. The source code is on GitHub.

Developed with Lazarus and Free Pascal (FPC). The FLAC decoder, the resampler, the EBU R128 loudness meter and the user interface are own code; the interface is drawn with Direct2D and DirectWrite, and PDF booklets are shown with the PDF engine of Windows.

## Third-party acknowledgements

- **Tag reading and writing (AulumicTag, a fork of OvoTag):** Copyright © 2011 Marco Caselli. Distributed under a modified LGPL (Library GNU General Public License with a linking exception), the same licence structure as the Lazarus Component Library (LCL).
- **Artist information:** Biographies and pictures from Last.fm, Wikipedia and TheAudioDB, subject to the terms of these services.
- **ASIO:** ASIO is a trademark and software of Steinberg Media Technologies GmbH.

*The screenshots in this help show a made-up demo library: the artists, albums and covers do not exist.*
