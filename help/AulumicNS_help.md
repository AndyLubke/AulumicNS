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

Aulumic is a free music player for Windows. It sends the music straight to the DAC, over WASAPI exclusive mode or the DAC's ASIO driver. Out of the box nothing is touched: resampling is off, DSD goes out as DSD, and the only thing in the way is the volume control.

With the volume at 100 % and nothing else switched on, the DAC gets the audio exactly as it's stored in the file (bit-perfect). The **Bit-perfect** badge in the top banner shows whether that's the case right now; click it to see the whole signal path. See *Configuring bit-perfect playback*.

![The main window while an album plays](02-dark-playing)

The parts of the window are explained one by one in **The main interface**.

The whole program is one file, `AulumicNS.exe`: no DLLs, no separate PDF viewer. The NS stands for Native Sound, because the audio reaches the DAC as it is in the file. The library, playlists and settings live in a **Data** folder next to it, so it runs from any folder or a USB stick.

# Getting started

![Preferences: Library, where the music is added](24-prefs-0)

1. **Add music:** Open Preferences (the gear in the title bar, or Ctrl+P). On the Library page, click **Add folder...** and choose the folder that holds the music. The scan starts right away; the page and the status line show its progress.
2. **Choose the output:** Click the device name at the bottom right of the main window and pick the DAC. WASAPI devices and ASIO drivers share one list.
3. **Play:** Double-click an album or a folder in the library on the left, or drag it onto the playlist on the right.

## WASAPI or ASIO?

![Preferences: Output](24-prefs-3)

- **WASAPI exclusive:** Works with any DAC that has a Windows driver. It's the one to start with.
- **ASIO:** Needs the ASIO driver from the DAC's maker. Choose it to have DSD sent as native DSD instead of DoP, or when WASAPI gives dropouts.

Both skip the Windows mixer, so neither changes the audio.

# Features

![The main window](02-dark-playing)

**WASAPI exclusive mode and ASIO:** Both skip the Windows audio mixer, so Windows doesn't resample or change anything. Over ASIO, DSD is sent as native DSD when the driver supports it.
*Note: while Aulumic plays, it has the device to itself. The browser and Windows' own sounds stay silent on that device.*

**Automatic sample rate switching:** The DAC is switched to the sample rate of each track (for example from 44.1 kHz to 192 kHz), so Windows never has to convert it.

**Supported file formats:**

- **Lossless only:** FLAC, WAV, DSF and DFF. MP3, AAC and other lossy formats won't play.
- **Mono and stereo:** Files with more than two channels won't play.
- **High resolution:** High-resolution PCM (including DXD) in FLAC or WAV, and DSD in DSF and DFF files.
- **Local files:** A music collection on local or network drives. There's no internet radio or streaming.

**Gapless playback:** No pauses or clicks between tracks that run into each other, as on live albums, concept albums or classical works.

**Volume control:** Leave the volume to the DAC for bit-perfect playback, or use the built-in volume control. It calculates in 64-bit floating point and dithers the result, so the program itself adds no rounding errors. Like every digital volume control, it uses fewer of the DAC's bits the further it is turned down.

**Library management:** Browse by folder, artist, album or genre, in a tree or as album tiles, search the whole library, edit tags (including Composer and Performer) and covers, and combine folders with Virtual Folders. Aulumic keeps an eye on the library folders, so new and changed files show up by themselves.

**Built-in tools:** A ReplayGain scanner (EBU R128), a booklet viewer for the PDF booklets of albums, a cover viewer, artist biographies and pictures, and a five-band tone control.

**Resampling:** Optional up- and downsampling of PCM audio with linear, intermediate or minimum phase filters. With **Headroom** on *Automatic*, an album whose peaks would not fit after resampling is lowered just far enough.

**Windows playback optimization:** The audio thread is registered with the Windows Multimedia Class Scheduler (MMCSS), so dropouts are less likely when the PC is busy.

**Look and feel:** Dark and light mode switch at once (or follow Windows), six accent colours, vector icons that stay sharp at every screen scaling, and a text size for all windows.

**Touch screens:** Swipe up and down to scroll the library, the playlist, the help and the pages of Preferences. In the booklet viewer, swipe to turn the pages, or to move a zoomed-in page. Every row has a three dots button for its menu.

# The main interface

![The main window](02-dark-playing){1=mainmenu 2=preferences 3=banner 4=search 5=selector 6=sortdir 7=view 8=manager 9=tree 10=playlist 11=transport}

From top to bottom; the numbers are those in the picture:

**Title bar:** In the colours of the theme. Drag it to move the window, double-click it to maximize; snapping to the screen edges and the snap layouts of Windows 11 work as usual. The **Main menu** button (three lines) {1} is at the left, next to the program icon; the **Preferences** gear {2} is at the right, before the minimize button. A click on the program icon itself opens the window menu of Windows (Restore, Move, Size ...), as in every Windows program.

{1} **Main menu:** The button with the three lines at the left of the title bar opens all main functions and tools:

- **File:** Add files or a folder to the playlist.
- **Playback:** Play, stop, previous and next, the shuffle and repeat modes, the Tone Control and Jump to Now Playing.
- **Library:** Search, refresh, rescan and the library folders.
- **Playlist:** New playlist, the Playlist Manager, import and export, expand or collapse all albums, remove dead items and clear the playlist.
- **View:** The switches that are changed now and then, without opening Preferences: dark or light mode and the accent colour under **Theme**, **Compact rows**, **Peak meter**, **Keep album headers in view**, **Cursor follows playback** and **Library as tiles**. A tick shows what is on.
- **Tools:** Properties and ReplayGain for the whole library, the log and the Debug Queue.
- **Below these:** Preferences, Help, About and Quit.

{2} **Preferences:** The gear at the right of the title bar opens Preferences (also with Ctrl+P), where all settings are.

{3} **Now Playing banner:** Shows the cover, title, album, genre, the credited artists, performers and composers, and the audio format of the playing track.

- **Cover & album title:** Click the cover or the album title to open the **Cover Art Viewer**.
- **Artists, performers & composers:** Everyone is listed once, with what they do behind the name in smaller text (*piano, composer*). Click a name to open **Artist Info**. If the line gets too long, the roles are left out to make room for more names; if there are still more names than fit, click **+n more** at the end of the line for the others.
- **Bit-perfect / Processed badge:** Click it to see the **Signal Path**.
- **Booklet & favourite:** If the album folder contains a PDF booklet, a **Booklet** icon appears; click it to read the booklet. Click the **Heart** to mark the playing album as a favourite.
- **Output sample rate:** Click the output rate on the right of the banner to choose another resampling target rate.
- **Sizes:** Drag the lower edge of the banner to make it smaller or larger, and the border between the library and the playlist to change their widths. Both follow the pointer during the drag. (With *Use the graphics card* switched off, only a line moves and the size changes on release.)

{4} **Search bar:** Filters the library on title, artist, album artist, composer, performer, album, genre and folder. Accents are ignored (searching for *Dvorak* also finds *Dvořák*).

**Refresh button:** Checks the library folders for changes and reloads the library view (F5).

{5} **Playlist selector:** Switches between the playlists. Ordinary playlists come first, auto-playlists follow with a funnel icon. To create, rename or delete playlists, open the Playlist Manager.

{6} **Sort:** Two buttons set the order of the albums in this playlist.

- **The button with the name:** Chooses the order: **Playlist order** (the order in which the music was put in), **Artist**, **Album**, **Year** (the oldest first) or **Added to library** (the newest first).
- **The arrow button:** Reverses that order; the arrow points down while it is reversed.
- **A sort is a view:** It changes what is shown and the order of playback. The order in which the music was added is kept, and **Playlist order** brings it back.
- **While sorted or reversed:** Albums can't be dragged to another place, and added music finds its own place.
- **Remembered:** Each playlist keeps its choice. The buttons aren't there in a flat list, which is sorted by its column headings.

{7} **View & edit:** **View** changes how the playlist is grouped and shown; the pencil {8} opens the Playlist Manager. The album header format can only be chosen while the playlist is grouped By album, and the track format not in a flat list.

{9} **Library pane:** The music collection, grouped by folder, artist, album or genre. Right-click (or click the three dots on a row) for more options, such as playing or adding to a playlist (**Replace current playlist** empties the playlist first), **Auto-collapse other nodes**, Virtual Folders, ReplayGain or Properties. If a library folder sits on a drive that isn't connected, it's dimmed and marked **(not available)**; its tracks stay in the library.

- **Position:** The library is as it was when Aulumic was closed: the same nodes open, the same selection and scroll position, and the tiles at the same place.
- **Tree or tiles:** The two buttons between the search bar and the refresh button switch the pane between the tree and album tiles (also Ctrl+G, or **Library as tiles** in the View menu of the main menu). In a narrow pane there is one button, which switches to and fro. The tiles are described below, under their picture.

{10} **Playlist pane:** The tracks of the selected playlist, with the album covers in the album headers. Click the stars to rate a track or a whole album; click the cover in an album header to open the Cover Art Viewer. Right-click for more options: what can be done with the selected tracks comes first (Play, Rating, **Favourite** - five stars, Add to, Open folder, ReplayGain, Remove from playlist), then what concerns the whole playlist, then the Playlist Manager and Properties.

- **Album headers:** Under the stars a header shows how many tracks the album has and how long it plays, unless the header format shows these already or the pane is too narrow. While scrolling through a long album, its header stays at the top of the list, and it works there as usual: click the cover, the stars or the triangle. This can be switched off in Preferences > Playlists, or with **Keep album headers in view** in the View menu of the main menu.
- **Flat list:** The view **Flat list** shows the tracks as a table: number, title, artist, album, rating and time.
  - **Sorting:** Click a heading to sort by that column, and again to reverse. The column sorted by before decides among equal values: click **Album**, then **Artist**, for artists with their albums together. A click on **#** brings back the playlist order.
  - **Columns:** Right-click the headings to choose them; album artist, year, genre, format, plays, last played and added are there too.
  - **Widths:** Drag the line between two headings. The column on one side grows by what the other gives up; next to the title it is the title that gives or takes. When the columns don't fit beside the title, they all get a little narrower, and only in a very narrow pane are the least important ones left out.
  - **Remembered:** Each playlist keeps its own columns, widths and sort. As with the album sort, the order in which the music was added is kept, and tracks can't be dragged while a column sort is on. The track format isn't used in a flat list.
- **Position:** Each playlist remembers its scroll position and which albums were closed, also after a restart.
- **Several discs:** An album on more than one disc gets a small **Disc 1**, **Disc 2** heading above the first track of each disc.
- **Guest artists:** In an album whose tracks aren't all by the same artist (a compilation, or a track with a guest), the artist is shown behind the title of each track that isn't by the album artist alone. If the track format shows the artist itself, this is left out.

Drag tracks or folders here from the library or from Windows Explorer; they are inserted where they are dropped, and an album is never split. Drag tracks inside the playlist to change the order. Hold **Ctrl** while dropping from Explorer to replace the playlist and start playing.

**Remove dead items** (right-click menu) takes out the tracks whose files are gone. Tracks on a drive that isn't connected, or on a NAS that doesn't answer, are kept. Before anything is removed, Aulumic reports how many tracks it found and how many it keeps, and asks. While a drive wakes up, a small window with **Cancel** is shown.

{11} **Transport controls:** Shuffle, Stop, Previous, Play/Pause, Next, Jump to Now Playing and Repeat, with the position bar above them.

**Output & audio controls:** Click the device name to choose the output device, the sliders icon to open the Tone Control, or the speaker icon to change or mute the volume.

**Status line:** Shows background tasks, such as a library scan, a ReplayGain scan or saving tags. During playback it also shows engine details.

![Searching the library](09-library-search)

While typing in the search bar, the library shows only what matches, with the albums and tracks found.

![The library as album tiles](11-library-tiles)

**Album tiles:** A second way to look at the library: the albums as covers, with the album and the artist under each. The tree stays the way to choose what is shown.

- **What is shown:** The albums under the node that is selected in the tree: a genre, an artist, a folder. A line above the tiles shows the path to it (*Folders > Music > Jazz*). Click a part of the path to go up to it; the first part and the cross behind the path show all albums. With the top node of a group selected, all albums are shown, and the line isn't there.
- **Order:** Next to the search bar are two buttons, as above the playlist (in a narrow pane they are in the line above the tiles). The button with the name chooses the order: **Artist**, **Album**, **Year** (the oldest first) or **Added to library** (the newest first). The arrow button next to it reverses that order; the arrow points down while it is reversed.
- **Size:** Hold Ctrl and scroll the mouse wheel over the tiles, or choose it in Preferences > Appearance. The smallest size is a list: a small cover with the album and the artist beside it. A text that doesn't fit is cut short; resting the pointer on the tile shows all of it.
- **Using a tile:** A tile stands for all tracks of its album. Double-click plays it (or shows it in the tree, as set for the double click in Preferences), drag it onto the playlist to add it, right-click for the menu: Play, Add to and Replace current playlist, **Show in tree**, Open folder, ReplayGain and Properties. Several tiles can be selected with Ctrl and Shift.
- **Search:** The search bar fills the tiles with the albums found. An album that is there because of some of its tracks says how many were found; **Show in tree** then shows the tracks themselves.
- **Typing a letter:** Jumps to the next tile that starts with it - the artist when the tiles are sorted by artist, else the album.
- **Width:** When the border between the library and the playlist is dragged while the tiles are shown, the tiles keep that width for themselves, and the tree keeps its own.
- **Covers:** The tiles use the small covers made by the library scan, so no music drive is woken. An album without a cover gets a coloured tile.

![The light theme with a smaller banner](04-light-small-banner)

The same window in the light theme, with a smaller banner.

# Signal Path

Click the **Bit-perfect** or **Processed** badge in the banner to see every stage between the file and the DAC. The popup keeps up with playback while it's open; click the badge again or press Esc to close it.

![The signal path of a processed DSD stream](44-signal-path)

- **Green:** The stage passes the signal on unchanged (for example *Resampler: Bypassed*).
- **Amber:** The stage changes the signal (for example ReplayGain, the tone control, the resampler or a volume below 100 %).
- **Grey:** The source file and the output device.

The stages are the source file, the decoder or the DSD transport (DoP, native DSD or DSD to PCM), ReplayGain, the tone control, the resampler, the volume, dither or the bit depth, warnings such as clipping, and the output format the device accepted. When the summary at the top says **Bit-perfect**, the DAC gets the file's samples unchanged.

# Keyboard shortcuts

![Preferences: Shortcuts lists them all](24-prefs-8)

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
- **Jump to a row:** Type the first letters of its name (library tree, album tiles and playlist)
- **Rate the selected playlist tracks:** `Ctrl + 1` ... `Ctrl + 5` (on a group header: the whole album); `Ctrl + 0` clears the rating
- **Change text size of a pane:** `Ctrl + Mouse Wheel` (over the album tiles: their size)

## Application controls

- **Search:** `Ctrl + F`
- **Library as tree or album tiles:** `Ctrl + G`
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

## Shortcuts in the Playlist Manager

- **New playlist:** `Ctrl + N`
- **Edit selected playlist:** `F2`
- **Remove selected playlists:** `Del`
- **Show selected playlist:** `Enter` (or double-click)
- **Close:** `Esc`

## Shortcuts in Artist Info

- **Edit biography / finish editing:** `F2` (`Esc` also finishes editing)
- **Reload from online sources:** `F5` (not while editing; a chosen picture and an edited biography are kept)
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

Open Preferences from the main menu, with the gear in the title bar, or with Ctrl+P. The settings are on nine pages, listed on the left: Library, Appearance, Playlists, Output, DSD, Resampler, Volume, System and Shortcuts. Every setting has a short description under its name. **OK** keeps the changes, **Cancel** drops them.

**Cards:** Settings that are set once and then left alone sit in cards at the bottom of a page. A card is one row with a title and a line that sums up what's inside; click it (or press the space bar on it) to open it right there, and again to close it. With all cards closed a page fits the window; open a few and it scrolls. Cards left open are open again next time.

**Related settings:** Some pages end with buttons that lead to a neighbouring subject, for example from Output to the audio thread settings on the System page.

## 1. Library page

![Preferences: Library](24-prefs-0)

- **Library folders:** The folders that make up the music library. **Add folder...** adds one; **Remove** takes it out of the library (the files stay on disk).
- **Scan now:** Checks the library folders for new, changed or removed files. A cover that was changed in another program also updates the album thumbnail. Folders on a drive that is disconnected or asleep keep their tracks. The progress is shown on the page.
- **Repair:** Rebuilds the library from scratch, including all album thumbnails. Try it when tracks are missing or the library looks wrong.
- **Watch the library folders:** New and changed files show up in the library by themselves a few seconds later. Network folders aren't watched (some NAS would never get to sleep); press Refresh (F5) or Rescan (Ctrl+F5) for those.
- **Auto-scan on startup:** Checks the library for changes at every start.

## 2. Appearance page

![Preferences: Appearance](24-prefs-1){1=19.5,14.5 2=76,22 3=80,66 4=91,87.5}

Every page of Preferences is built the same way; the numbers are those in the picture:

- {1} **Pages:** The pages are listed at the left; click one to show it.
- {2} **Settings:** Every setting has a short description under its name.
- {3} **Cards:** Settings that are set once are in cards: click a card to open it, and again to close it.
- {4} **OK:** Keeps the changes; **Cancel** (or Esc) drops them.

The settings of this page:

- **Theme:** Dark, light, or the app setting of Windows. Changes at once.
- **Accent colour:** Used for the selection, the sliders and the highlights.
- **Text size:** The size of the text in all windows.
- **Compact rows:** Lower rows in the playlist and the library tree, so more of them fit on the screen.

### Card: Main window

![The Main window card, open](24-prefs-1-mainwindow)

- **Double click:** What double-clicking a library node does: play it at once, or only open or close it.
- **Auto-collapse other nodes (accordion):** Closes the other open folders when one is opened.
- **Show Artists, Albums, Genres:** Shows or hides these groups in the library pane.
- **Show peak meter:** Shows the peak meter in the banner. It covers 60 dB: green in the lower half, amber higher up, red in the top part (above about -9 dB). The top block turns red for a moment when a sample was clipped.

### Card: Text and tile size of the panes

- **Library / playlist text size:** The text size of the two panes. Holding Ctrl and scrolling the mouse wheel over a pane changes it too.
- **Album tile size:** The size of the album tiles in the library pane: List, Small, Medium or Large. Holding Ctrl and scrolling the mouse wheel over the tiles changes it too.

## 3. Playlists page

![Preferences: Playlists](24-prefs-2)

- **Playlists grouping, Album header format, Track format:** The defaults of the playlists; each playlist can override them in the Playlist Editor.
- **Keep album headers in view:** While scrolling through an album, its header stays at the top of the playlist.
- **Cursor follows playback:** When a track starts, the selection moves to it, and it scrolls into view if it wasn't visible. This only happens in the playlist that is playing; a playlist that is being browsed meanwhile stays where it is. Switch it off to keep the selection where it was put.

## 4. Output page

![Preferences: Output](24-prefs-3)

- **Output interface:** *WASAPI exclusive* (every DAC with a Windows driver) or *ASIO* (the DAC's own ASIO driver).
- **Output device:** The DAC or sound card to play to. If this device is switched off or unplugged, it stays selected: playback stops with a message and never jumps to another device on its own. If the DAC drops out briefly while playing, Aulumic waits up to 20 seconds and then carries on.
- **PCM buffer size:** How much PCM audio is buffered ahead, in milliseconds, over WASAPI and ASIO alike; DSD converted to PCM uses it too. Make it larger against stutters or dropouts. The price: volume and tone control changes are heard a little later.
- **Related settings:** *DSD* opens the DSD page; *Audio thread* opens that card on the System page (priority, timer and CPU core of the audio thread, which matter when there are dropouts).

## 5. DSD page

![Preferences: DSD](24-prefs-4)

- **Play DSD natively:** Sends DSD to the DAC as DSD: over WASAPI packed as DoP, over ASIO as native DSD when the driver supports it (otherwise as DoP). When it is off, DSD is converted to PCM.
- **DSD low-pass:** Applies a low-pass filter when DSD is converted to PCM.
- **DSD gain:** The level of DSD converted to PCM. `+0.0 dB` keeps the original level; `+6.0 dB` brings DSD closer to the level of FLAC and WAV files. The gain is applied at the end, together with the volume. SACDs may peak up to about 3 dB above their reference level, so with `+6.0 dB` loud passages can exceed full scale; **Headroom** on *Automatic* (Volume page) then lowers the album just as far as needed.
- **DSD buffer size:** How much DSD audio is buffered ahead when DSD goes to the DAC as DSD (DoP, or native over ASIO). A dropout there is a pop, so it needs more than PCM.

## 6. Resampler page

![Preferences: Resampler](24-prefs-5)

- **Enable PCM resampling:** Resamples PCM audio with the built-in resampler. Turn it off for bit-perfect playback.
- **Target rate for 44.1 kHz / 48 kHz:** The output rate for all files of the 44.1 kHz family (44.1, 88.2, 176.4 kHz ...) and of the 48 kHz family (48, 96, 192 kHz ...). Only whole multiples are offered.
- **Exclude:** Sample rates that are never resampled.
- **Exclude DSD from resampling:** DSD converted to PCM is not resampled afterwards.

### Card: Quality and filter

![The Quality and filter card, open](24-prefs-5-filter)

These settings are used while PCM resampling is on. When it is off, the rows are greyed out and the summary line of the card says so.

- **Resample quality:** Higher settings resample more precisely but use more CPU.
- **Upsampling / downsampling phase:** The phase response of the filter. *Linear phase* keeps all frequencies in time but adds pre-ringing; *Minimum phase* has no pre-ringing; *Intermediate phase* is a compromise. See *Audio concepts*.
- **Bandwidth:** Where the high-frequency filter starts. *Slow roll-off* covers the full range of human hearing with a gentle filter; *Medium* and *Fast* keep more treble but need a steeper filter.
- **Anti-aliasing:** The strength of the ultrasonic filter. *Maximum* suppresses what lies above the limit most strongly but can add a little pre-ringing; *Standard* lets a small amount through, far below the music, and has less ringing.

## 7. Volume page

![Preferences: Volume](24-prefs-6)

- **Lock volume to 100%:** Leaves the volume to the DAC or amplifier. This also turns off ReplayGain, a fixed headroom and the soft clipper. At 100 % the output is bit-perfect without the lock too; the lock makes sure it stays there.
- **ReplayGain mode:** Evens out the loudness between tracks. *Track* plays every song at the same loudness; *Album* plays whole albums at the same loudness and keeps the differences between their tracks.
- **Headroom:** Room for peaks that would not fit into the output. One setting with two ways:
  - **Automatic:** The default. Lowers the level only where it is needed.
  - **A fixed amount:** From `0.0 dB` to `-6.0 dB`. Lowers everything by that much; nothing is measured. Choose it to have every album lowered by the same amount. With ReplayGain on, it is added to the ReplayGain gain, and the loudest sample of the track (or album) never comes above this level. It is not applied when the volume is locked to 100 %.
- **Enable soft clipping limiter:** Gently rounds off peaks that would otherwise clip. It is not needed with Headroom on Automatic; it is of use with a fixed headroom.

### Card: ReplayGain scan

![The ReplayGain scan card, open](24-prefs-6-rgscan)

- **Tracks at the same time:** How many tracks of an album the ReplayGain scanner measures at once. With 1 track the processor stays coolest; with 4 tracks an album is scanned about three and a half times as fast, but the processor gets warmer and its fan louder. The measured values are exactly the same.

### How automatic headroom works

- **Why:** A loudly mastered recording can come out up to about 2.5 dB above full scale after upsampling, because the waveform between its samples peaks higher than the samples themselves. DSD converted to PCM with a DSD gain can do the same. Without headroom those peaks are clipped.
- **What happens:** The peaks are measured during playback, and the level of the album is lowered just as far as its highest peak needs. Nothing is clipped or limited; the album simply plays a little quieter.
- **Per album:** All tracks of an album get the same level (the tracks in one folder with the same album and album artist). A track without an album tag stands for itself.
- **First play:** The level can come down a little a few times during the loudest tracks, each time gliding within 10 ms. The album's peak is remembered, so the next time it starts at the right level.
- **Tone control:** A boost is counted in and lowered before it can clip, also without resampling; a cut costs no level. This part is found anew each time, not remembered.
- **Never touched:** Quiet albums, anything played with the volume turned down far enough, and bit-perfect playback (no resampling, no gain, tone control off).
- **Where it is kept:** In `Data\Library\headroom.adb`. Nothing is written to the music files. Delete that file to forget all remembered peaks.
- **Where it is shown:** The signal path shows what is taken off, for example `Headroom -0.8 dB`. Automatic also works with the volume locked to 100 %.

## 8. System page

![Preferences: System](24-prefs-7)

- **Keep music drives awake during playback:** Stops the drives with the playing music from falling asleep, so the next track starts without a delay. Only a tiny piece of the current and next track is read now and then; nothing is written.
- **Animations:** Short fades and gliding movements: a highlight that fades in under the pointer, lists that glide when the mouse wheel is turned, menus and dialogs that fade in. They are only shown while *Animation effects* is switched on in the Windows settings (Accessibility > Visual effects). Turn the switch off to have everything change at once.
- **Use the graphics card:** The graphics card draws the lists and other large areas, which keeps scrolling smooth, also on a 4K screen. Turn it off if parts of a window stay black or flicker with the graphics driver. The processor then draws everything, which works everywhere but is slower with large windows.

### Card: Audio thread

![The Audio thread card, open](24-prefs-7-thread)

These settings help Windows give audio playback priority over other tasks. Leave them on unless they cause trouble on older hardware.

- **Optimize CPU core affinity:** Keeps the audio thread off CPU core 0, where Windows handles most interrupts.
- **Enable MMCSS ('Pro Audio' mode):** Registers the audio thread with Windows as a "Pro Audio" task, so it gets priority and is not throttled.
- **Enable high-resolution kernel timer (1 ms):** Sets the Windows timer to 1 ms during playback and stops Windows from slowing the player down to save power. Turn it off to save battery on a laptop.

### Card: Log

- **Always save the log:** Writes the log to `AulumicNSLog.txt` in the Data folder at every exit (the file is replaced each time). Without this switch a log is only saved after an error, as `AulumicNSLog_<date>.txt`. Turn it on to report a problem or to see what the last session did.

### Card: Artist information

- **Last.fm API key:** Artist Info gets its biographies from Last.fm, and Last.fm asks every program for a key. Aulumic has none built in, so a personal key is needed.
  - **Getting one:** It's free. Create an API account at last.fm/api and paste its "API key" into this field.
  - **Without a key:** Biographies already downloaded are still shown.
  - **From a file:** A file `LastFmKey.txt` with a key in it can be put next to `AulumicNS.exe`. While no key is entered here, Aulumic takes the key from that file at start and keeps it, so the file is only needed once.

## 9. Shortcuts page

![Preferences: Shortcuts](24-prefs-8)

All keyboard shortcuts at a glance; see also *Keyboard shortcuts*.

# Playlist Manager

The Playlist Manager creates, edits, imports and exports playlists. Open it from the main menu, with the pencil next to the playlist selector, from the playlist's right-click menu, or with Alt+P.

![The Playlist Manager](32-playlist-manager)

## Managing playlists

The list shows all playlists: the Default playlist, the ordinary playlists, and the auto-playlists with a funnel icon. Select a playlist and use the buttons:

- **New playlist...:** Creates an ordinary playlist, to be filled by hand. (Ctrl+N)
- **New auto-playlist...:** Creates an auto-playlist that fills itself from rules.
- **Edit...:** Changes the name, display settings and, for an auto-playlist, the rules. (F2)
- **Remove:** Deletes the selected playlists. (Del)
- **Import...:** Imports an .m3u or .m3u8 file as a new playlist.
- **Export...:** Saves the selected playlist as an .m3u8 file, to back it up or use it in another player. An auto-playlist is exported with the tracks it contains at that moment.

Double-click a playlist (or press Enter) to show it.

# Playlist Editor

The Playlist Editor opens when a playlist is created or edited.

![The Playlist Editor of a standard playlist](33-playlist-editor){1=84,25.7 2=84,39.2 3=84,55.2 4=84,69.3}

## General settings

- {1} **Playlist name:** The name of the playlist. "Default" is reserved.
- {2} **Grouping:** By album, By folder or Flat list. *Use global preferences* follows the setting in Preferences > Playlists.
- {3} **Album header format:** The layout of the album headers (only when grouped By album).
- {4} **Track format:** The layout of the tracks.

## Auto-playlist rules

![The Playlist Editor of an auto-playlist](34-autoplaylist-editor){1=84,14.4 2=84,22 3=84,30.9 4=84,38.7 5=84,53 6=84,67 7=76.8,77.9 8=61.5,85}

An auto-playlist has the general settings of every playlist ({1}, {2}, {3} and {4}, see above) and is built from one or more rules; each rule checks one tag.

- {5} **Smart rule template:** A ready-made set of rules, or *Custom* for own rules.
- {6} **The rules:** The rules of this playlist. Click one to load it into the boxes below it.
- {7} **Query builder:** Pick the tag, the operator and the value, then click **Add**.
- {8} **Remove:** Takes the selected rule out of the list. **Rules** opens this help topic.

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
- **Rating:** The rating, from 1 to 5.
- **Favourite:** 1 for a favourite, 0 otherwise.
- **Play count:** How often the track was played.
- **Bit depth:** For example 16, 24 or 32.
- **Sample rate:** In Hertz, for example 44100, 96000 or 352800.

### Date tags

- **Date added:** When the track was added to the library. Use it with `IN LAST`, for example `7d`, `2w`, `6m` or `1y`.
- **Last played:** When the track was last played. It works the same way.

# Properties

Properties edits the tags and cover of music files, and shows their technical details and play statistics. Open it from the main menu (Tools), by right-clicking tracks in the library or the playlist, or with Alt+Enter.

The window can be resized or maximized: the file list, the fields, the Comment box and the Inspector grow with it, and it remembers its size. On a small screen the Tags page scrolls.

![Properties: the Tags tab](35-properties){1=20,60 2=46,9.1 3=69.3,18.9 4=95,15 5=70.5,94}

## File list

{1} The selected tracks. Click a track to edit it, or select several (Shift, Ctrl or Ctrl+A) to edit them together. A dot marks a track with unsaved changes; a track whose tag cannot be read is marked with **!** and is never changed.

## 1. Tags tab

The tabs {2} switch between the tags and the Inspector.

- {3} **Fields:** Title, Artist, Album artist, Album, Genre, Year, Track, Disc, Composer, Performer and Comment (several lines).
- **Several names:** For Artist, Album artist, Genre, Composer and Performer, separate several entries with a semicolon (;). For a performer, the instrument or role can be put in brackets behind the name, such as *Ida Feld (double bass)*; the banner shows it next to the name.
- **Several tracks:** Fields that differ between the selected tracks show *Multiple values*; Title and Track stay unique per track. A value typed in a shared field is applied to all selected tracks. Only the changed fields are written.
- {4} **Cover:** **Load...** chooses an image file, **Search the web** looks for the cover online, **Remove** takes the cover out of the selected files. An image file can also be dropped on the window or pasted with Ctrl+V.
- {5} **Save:** Writes the changes. They're written in the background, so listening can go on. **Cancel** (or Esc) drops them. DFF files can be tagged too.

## 2. Inspector tab

![Properties: the Inspector tab](36-properties-inspector)

The Inspector shows the technical details of the files; nothing can be changed here. It lists the audio format, the file (size, location, date added), the play statistics and every tag exactly as it is stored in the file. With several tracks selected it shows their number and total size.

# Tone Control

The Tone Control shapes the sound in five bands. Open it with Ctrl+T or the sliders icon next to the speaker icon.

![The Tone Control](46-tone-control){1=82.5,9.6 2=4.2,40 3=6,71.8 4=73,89 5=88,21 6=22,36}

It is a five-band semi-parametric tone control (bass, low mid, mid, high mid and treble): each band has its own frequency and gain. Bass and treble are shelves: they raise or lower everything below or above their frequency. The three middle bands work around their frequency.

- {1} **Enable:** Turns the tone control on or off. When it's off, it's out of the signal path completely.
- {2} **Frequency:** The centre frequency of each band.
- {3} **Gain:** Up to ±10.0 dB per band. Scroll the mouse wheel over a slider, or use the arrow keys when it has the focus. **Flat** {4} sets all bands to 0 dB.
- {5} **The curve:** The graph above the bands shows what the five bands do together, from 20 Hz to 20 kHz. It's worked out from the filters that are really used, so the curve shows what is heard. A dot marks each band that is set. When the tone control is off, the curve is grey: it shows the settings, but they aren't applied.

A boost raises the peaks of the music. With Headroom set to Automatic (Preferences > Volume), the level is lowered just enough to keep them from clipping, and a line under the curve {6} says by how much: "Level lowered by 1.4 dB to avoid clipping".

A change glides in over a fraction of a second, also when the tone control is switched on or off, so there is never a click while the music plays.

When DSD goes out as DSD, the tone control and the volume control don't apply: a DSD stream is passed on as it is. The Tone Control window then says "disabled for DSD" in its title and its controls are greyed out; the settings are kept and work again with the next PCM track.

# ReplayGain scanner

The ReplayGain scanner measures the loudness of music files with the built-in EBU R128 meter, so tracks and albums play at a similar level. Open it from the main menu (Tools > Calculate ReplayGain, for the whole library), or right-click items in the library or the playlist.

## The scanning process

![The ReplayGain scanner at work](37-replaygain-scan){1=33.3,31.9 2=33.3,45.7 3=41,59.2 4=64.4,81 5=85.9,81}

Before it starts, the scanner asks whether only the files without ReplayGain tags are scanned, or all of them. The scan reads all the audio, so a large library or DSD albums can take a while; Preferences > Volume > ReplayGain scan lets it measure several tracks of an album at the same time.

While it runs, the window shows the album being scanned and how far it is {1}, the track being measured {2} and the place in the whole job {3}.

- {4} **Hide:** Hides the window while the scan continues. The status line shows the progress; click it to show the window again.
- {5} **Stop:** Stops the scan after the current track.

What counts as an album:

- **Albums:** Always scanned complete, so the album gain is right. An album is the tracks of one folder with the same album and album artist.
- **Tracks without an album tag:** These don't count as an album: each is measured on its own and gets a track gain only (the results and the log say so). In Album mode such a track plays with its track gain.

## Scan results

![The results of a scan](38-replaygain-results)

Each file is listed with its track gain and peak, its album gain and peak (empty for a track without an album tag), or the reason it could not be measured (for example a disconnected drive, a moved file or a damaged file). Nothing is written to the files until **Save all** is clicked; the tags are then written in the background. **Cancel** drops the results.

# Virtual Folders

Sometimes an album belongs in more than one place: under the composer and under the orchestra, for example. A Virtual Folder lets albums appear in another library folder without copying or moving any files.

![The Virtual Folder editor](39-virtual-folder)

## What is a Virtual Folder?

A Virtual Folder is a small link file (`.aullink`) inside a library folder that shows the contents of one or more other folders. It opens right inside the library tree, as if the music were stored there; it is shown with a link icon.

## Creating and managing Virtual Folders

Right-click a folder in the library and choose **Create Virtual Folder...**, or right-click a Virtual Folder and choose **Edit Virtual Folder...** or **Remove Virtual Folder...**.

- **Name:** The name in the library tree.
- **Auto-find term:** The name or word to search for; press Enter to run **Auto-find** at once. Several searches in a row combine several artists or composers. If left empty, Auto-find uses the name.
- **Search in:** Artist / performer, Composer, Album / title, Comment / genre and Folder name.
- **Auto-find:** Searches the library for folders whose tracks match every word; accents are ignored. Tracks in disc sub folders (such as `CD1`) are added as their album folder. New folders are added to the list and selected, so they are easy to check.
- **Add folder...:** Choose a folder by hand, or drag folders from Windows Explorer into the list.
- **Remove:** Removes the selected folders from the list (Del). The folders themselves are not changed.

## Common use cases

- **Composer and performer:** For an orchestra folder, run **Auto-find** with the orchestra's name: every album where the orchestra is credited (as Artist, Album artist or Performer) is linked into it.
- **Own collections:** For a collection such as "Late Night Favourites", create a Virtual Folder and link the albums with **Auto-find** or by dragging folders. The albums stay where they are and also appear in the collection.

# Cover Art Viewer

The Cover Art Viewer shows an album's cover at full size. To open it, click the cover or the album title in the banner, or the cover in an album header of the playlist.

![The Cover Art Viewer](40-cover-viewer)

The cover is shown as large as the window allows, with the format of the track below it. If the album folder holds more images (a back cover, booklet scans in a *Scans* folder), click, right-click, scroll the mouse wheel or use the arrow keys to step through them; Home and End go to the first and the last. The embedded cover comes first, unless the folder has its own front cover.

# Artist Info

Artist Info shows a biography and a picture of an artist. To open it, click an artist, performer or composer in the banner.

![Artist Info](41-artist-info)

Next to the biography and the picture, it says how many albums and tracks of the artist are in the library. The information comes from Last.fm, Wikipedia and TheAudioDB (the artist's name is sent to these services) and is kept in the Data folder, so it's there right away next time. The biographies need a free Last.fm API key: enter it in Preferences > System > Artist information.

- **Edit (F2):** Edit the biography; it is saved automatically.
- **Picture (Ctrl+O):** Choose a picture, drop an image file on the window, or paste one with Ctrl+V. **Remove (Del)** deletes it.
- **Search the web:** Opens a web search for the artist (and starts editing, so text can be pasted).
- **Refresh (F5):** Reloads the information from the online sources. A chosen picture and an edited biography are kept; to get the online version back, remove the picture or empty the biography, then press F5.

![Editing the biography](42-artist-info)

# Booklet Viewer

When the playing album has a PDF booklet (in its folder, in a sub folder such as *Scans* or *Artwork*, or in the album folder above a *CD1* / *Disc 2* folder), the **Booklet** icon appears in the banner. Click it to read the booklet in the built-in viewer, which uses the PDF engine of Windows.

![The Booklet Viewer showing two pages side by side](45-booklet)

- **Single / Spread:** One page at a time, or two facing pages like an open booklet (the cover alone first).
- **Zoom:** The minus, fit and plus buttons, the `+` and `-` keys, Ctrl with the mouse wheel, or a double-click. Drag the page or use the mouse wheel to move around when zoomed in.
- **Other booklets:** When the album has more than one PDF, the button on the left switches between them.
- **Open with the PDF program of Windows:** The folder button on the right.

# Audio concepts

![The Signal Path shows what happens to the audio](44-signal-path)

## I. Core playback & formats

- **Bit-perfect:** The audio reaches the DAC exactly as it is stored in the file, without any change.
- **PCM (pulse code modulation):** The basis of almost all digital audio, including CD, WAV and FLAC. PCM stores the sound wave as a series of measurements (samples). The sample rate is how many samples are taken per second (for example 44.1 kHz); the bit depth is how precise each sample is (for example 16 or 24 bits).
- **FLAC (Free Lossless Audio Codec):** FLAC makes files smaller without losing any quality; when played, the audio is identical to the original. Lossy formats such as MP3 or AAC permanently remove audio information.
- **DSD (Direct Stream Digital):** A 1-bit format, used for SACD (DSF and DFF files). DSD can be sent unchanged to a DAC that supports it; volume control and processing such as ReplayGain are then not applied. If the DAC doesn't support DSD, turn off *Play DSD natively*; DSD is then converted to PCM during playback.
- **DoP (DSD over PCM):** DoP packs the unchanged DSD data into 24-bit PCM frames, so connections that only handle PCM can carry it. The DAC unpacks it and plays it as native DSD, without any loss.
- **Native DSD (ASIO):** Over ASIO, a driver that supports DSD receives the DSD data directly, without DoP packing.

## II. Digital signal processing (DSP) & resampling

- **Resampling:** Upsampling (for example from 44.1 kHz to 176.4 kHz) moves most of the filtering from the DAC to the PC: the DAC still filters, but at a higher rate, where its filter has less to do. Whether that sounds better depends on the DAC. Downsampling is needed when a file has a higher rate than the DAC supports.
- **Filter phase:** Resampling needs a digital filter, and this filter affects the timing of the frequencies.
  - **Linear phase:** All frequencies stay exactly in time, but a very short "pre-ringing" can occur just before a sharp sound.
  - **Minimum phase:** No pre-ringing; the ringing moves to just after the sound, where it is usually considered less audible.
  - **Intermediate phase:** Halfway between the two.

## III. Volume & dynamics

- **64-bit floating-point volume:** Volume and all other PCM processing are calculated in 64-bit floating point, so the calculation itself adds no audible error. When the result has fewer bits than the calculation, it is dithered (TPDF). A digital volume control still lowers the signal inside the DAC's fixed number of bits: at -24 dB a 24-bit DAC has about 20 bits left for the music. For most listening that is plenty; for the last bit of resolution, lock the volume and use the DAC or amplifier.
- **ReplayGain and clipping:** Albums are mastered at very different levels. ReplayGain adjusts the playback level, so the volume doesn't have to be changed all the time. Raising a quiet track can push peaks above 0 dBFS, which causes clipping; the peak stored with the ReplayGain values and the Headroom setting prevent this.
- **Inter-sample peaks and headroom:** Digital audio stores samples, but what is heard is the smooth wave through them, and between two samples that wave can be higher than both. Modern masters are often pushed until their samples touch full scale, so the wave itself goes above it. A resampler computes new samples on that wave and finds those peaks; they do not fit into the output format and would be cut off (clipping). Headroom on Automatic lowers the level of such an album by exactly the missing amount, usually a fraction of a dB and rarely more than 2.5 dB. Everything else stays as it is.

## IV. System performance

- **MMCSS (Multimedia Class Scheduler Service):** A Windows service that gives registered audio threads priority. The audio thread is registered as a "Pro Audio" task (Preferences > System), also while the window is minimized.
- **Power throttling:** Windows slows down programs whose window is minimized or hidden. With the *High-resolution kernel timer* option on, the player asks to be left out of that.

# Configuring bit-perfect playback

![Preferences: Output](24-prefs-3)

Out of the box the output is bit-perfect as long as the volume is at 100 %. To make sure it stays that way:

- **Lock the volume:** In Preferences > Volume, turn on *Lock volume to 100%*, so it can't be turned down by accident.
- **ReplayGain off:** Keep ReplayGain turned off, so the level of the tracks is not changed.
- **Resampling off:** Keep PCM resampling turned off.
- **Tone control off:** Keep the tone control disabled (Ctrl+T).
- **DSD natively:** Keep *Play DSD natively* turned on, so DSF and DFF files reach the DAC as DSD.

> The badge in the banner shows **Bit-perfect** when the DAC receives the samples unchanged. Click it to see which stage changes the signal when it shows **Processed**.

# Log files & troubleshooting

Aulumic keeps a log of each session: library scans, playback errors, files that couldn't be saved and the like.

![The log window](22-log)

- **Show log:** Main menu > Tools > Show log... (or Ctrl+L). Warnings and errors are marked. **Copy**, **Save to file...** and **Clear** work on the whole log.
- **Saved log:** If errors were logged, the log is saved as `AulumicNSLog_<date>.txt` in the Data folder at exit. If there were no errors, nothing is saved, unless *Always save the log* is on (Preferences > System > Log): then `AulumicNSLog.txt` is written at every exit.
- **Dropouts:** If the music cuts out for a moment, check the log: it has a line "Dropout at about m:ss in the track", which means the output buffer ran empty. When a stream ends, a summary line shows the number of dropouts, the least music that was buffered ahead and the slowest buffer. A larger buffer size (Preferences > Output for PCM, Preferences > DSD for DSD sent as DSD) helps with dropouts. If there is a hiccup and the log shows no dropout, the cause lies outside Aulumic: the driver, USB or the DAC.
- **Black or flickering areas in a window:** Turn off *Use the graphics card* (Preferences > System), and please report the graphics card and its driver version.
- **Debug Queue (Ctrl+D):** Shows what the player is doing: the play queue, the next track and the engine's state. Useful when reporting a problem.
- **ShutdownTraceLog.txt:** Only written next to the program when an error occurs while it closes. Please include it and the log when reporting a problem.
- **HangReport_<date>.txt:** Written next to the program when the window stops responding for 5 seconds (Windows shows "Not responding"). It lists what each part of the program was doing at that moment, and its last line says when the window responded again. If it stays frozen, end it in the Task Manager; the report is already written. Please include it when reporting a freeze.

# Data and settings

![Aulumic in the light theme](04-light-small-banner)

Everything lives in a **Data** folder next to the program: the library, the play statistics (ratings, play counts, favourites), the playlists, the peaks remembered by the automatic headroom, the artist information and the settings (`AulumicNS.ini`). Album thumbnails are kept in a **Cache** folder. If the program folder can't be written to (for example in *Program Files*), `%APPDATA%\AulumicNS` is used instead.

The library and the playlists are saved at once after every change, so a crash or a power cut loses nothing. To move to another computer, copy the program together with its Data folder. To remove it, delete the program file with its Data and Cache folders. Nothing is installed anywhere else, and music files are only ever changed when tags or ReplayGain values are saved.

# System requirements

![Aulumic in the light theme](04-light-small-banner)

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

![Aulumic in the light theme](04-light-small-banner)

**Aulumic Music Player:** Copyright © 2026 André Lubke.

Aulumic is free software: it may be used, shared and changed under the terms of the GNU General Public License, version 3. It comes without any warranty. The source code is on GitHub.

Developed with Lazarus and Free Pascal (FPC). The FLAC decoder, the resampler, the EBU R128 loudness meter and the user interface are own code; the interface is drawn with Direct2D and DirectWrite, and PDF booklets are shown with the PDF engine of Windows.

## Third-party acknowledgements

- **Tag reading and writing (AulumicTag, a fork of OvoTag):** Copyright © 2011 Marco Caselli. Distributed under a modified LGPL (Library GNU General Public License with a linking exception), the same licence structure as the Lazarus Component Library (LCL).
- **Artist information:** Biographies and pictures from Last.fm, Wikipedia and TheAudioDB, subject to the terms of these services.
- **ASIO:** ASIO is a trademark and software of Steinberg Media Technologies GmbH.

*The screenshots in this help show a made-up demo library: the artists, albums and covers do not exist.*
