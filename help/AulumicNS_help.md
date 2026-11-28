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

With the volume at 100 % and nothing else switched on, the DAC gets the audio exactly as it's stored in the file (bit-perfect). The Signal path badge in the top banner is green with a tick when that's the case right now and amber with a dot when it isn't; click it to see the whole signal path. See *Configuring bit-perfect playback*.

When something does change the audio, such as the volume, ReplayGain, the tone control or the resampler, it is calculated in 64-bit floating point and rounded once, at the very end. The figures are in Audio concepts.

![The main window while an album plays](02-dark-playing)

The parts of the window are explained one by one in The main interface.

The whole program is one file, `AulumicNS.exe`. The NS stands for Native Sound, because the audio reaches the DAC as it is in the file. The library, playlists and settings live in a Data folder next to it, so it runs from any folder or a USB stick.

# Getting started

![Preferences: Library, where the music is added](24-prefs-0)

1. **Add music:** Open Preferences (the gear in the title bar, or Ctrl+P). On the Library page, click Add folder and choose the folder that holds the music. The scan starts right away; the page and the status line show its progress.
2. **Choose the output:** Click the device name at the bottom right of the main window and pick the DAC. WASAPI devices and ASIO drivers share one list.
3. **Play:** Double-click an album or a folder in the library on the left (in the tree, or an album tile), or drag it onto the playlist on the right.

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

- **Lossless only:** FLAC, WAV, AIFF, Apple Lossless (ALAC, in M4A files), DSF and DFF. MP3, AAC and other lossy formats won't play. AIFF files must be uncompressed (the usual kind).
- **M4A files:** Only those with Apple Lossless inside play; an M4A file with AAC is listed but refused with a message.
- **More than two channels:** FLAC, WAV, AIFF and Apple Lossless files with more channels (5.1, for example) are mixed to stereo; the Signal path badge is then amber. A DSD file with more than two channels is converted to PCM for this, also when Play DSD natively is on.
- **High resolution:** High-resolution PCM (including DXD) in FLAC, WAV, AIFF or Apple Lossless, and DSD in DSF and DFF files.
- **Local files:** A music collection on local or network drives. There's no internet radio or streaming.

**Gapless playback:** No pauses or clicks between tracks that run into each other, as on live albums, concept albums or classical works.

**Volume control:** Leave the volume to the DAC for bit-perfect playback, or use the built-in volume control.

**Library management:** Browse by folder, artist, album or genre - and by composer, when that group is switched on -, in a tree or as album tiles, search the whole library, edit tags (including Composer, Performer and Work) and covers, and combine folders with Virtual Folders. Aulumic keeps an eye on the library folders, so new and changed files show up by themselves.

**Built-in tools:** A ReplayGain scanner (EBU R128), a check of the tags for things that don't agree, a booklet viewer for the PDF booklets of albums, a cover viewer, artist biographies and pictures, and a five-band tone control.

**Classical music:** The movements of a work (a symphony, a concerto) stand under a heading of their own inside the album, and the library can be browsed by composer.

**Resampling:** Optional up- and downsampling of PCM audio with linear, intermediate or minimum phase filters. With Headroom on *Automatic*, an album whose peaks would not fit after resampling is lowered just far enough.

**Windows playback optimization:** Windows is asked to give the audio priority, so dropouts are less likely when the PC is busy.

**Look and feel:** Dark and light mode switch at once (or follow Windows), six accent colours, vector icons that stay sharp at every screen scaling, and a text size for all windows.

**Touch screens:** Swipe up and down to scroll the library, the playlist, the help and the pages of Preferences. In the booklet viewer, swipe to turn the pages, or to move a zoomed-in page. Every row has a three dots button for its menu.

# The main interface

![The main window](02-dark-playing){1=mainmenu 2=preferences 3=banner 4=search 5=libview 6=selector 7=sortdir 8=view 9=manager 10=tree 11=playlist 12=transport}

From top to bottom; the numbers are those in the picture:

**Title bar:** In the colours of the theme. Drag it to move the window, double-click it to maximize; snapping to the screen edges and the snap layouts of Windows 11 work as usual. The Main menu button (three lines) {1} is at the left, next to the program icon (F10 or Alt opens it from the keyboard); the Preferences gear {2} is at the right, before the minimize button. A click on the program icon itself opens the window menu of Windows (Restore, Move, Size ...), as in every Windows program. The title shows the playing track; while nothing plays, it shows the version number.

{1} **Main menu:** The button with the three lines at the left of the title bar opens all main functions and tools:

- **File:** Add files or a folder to the playlist.
- **Playback:** Play, stop, previous and next, the shuffle and repeat modes, the Tone Control and Jump to Now Playing. Stop after current track lets the playing track be the last one: the Stop button is marked until then, and Play later goes on with the next track.
- **Now playing:** The Cover Art Viewer, Artist Info, the Booklet Viewer, the Signal Path and Favourite for the playing track. The same as a click in the Now Playing banner, for the keyboard.
- **Library:** Search, refresh, rescan and the library folders.
- **Playlist:** New playlist, the Playlist Manager, import and export, expand or collapse all albums, remove dead items and clear the playlist.
- **View:** The switches that are changed now and then, without opening Preferences: dark or light mode and the accent colour under Theme, Compact rows, Peak meter, Keep album headers in view, Cursor follows playback and Library as tiles. A tick shows what is on.
- **Tools:** Properties, Calculate ReplayGain for the library and Check tag consistency of the library (both for everything in the library; the same two for a selection are in the right-click menus), the log and the Debug Queue.
- **Below these:** Preferences, Help, About and Quit. The About window has a Check for updates button: a click asks GitHub for the latest version. When a newer one is there, a box offers to open its download page. The Data folder and Website rows are links.

{2} **Preferences:** The gear at the right of the title bar opens Preferences (also with Ctrl+P), where all settings are.

{3} **Now Playing banner:** Shows the cover, title, album, genre, the credited artists, performers and composers, and the audio format of the playing track. Right-click it for Open folder.

- **Cover & album title:** Click the cover or the album title to open the Cover Art Viewer.
- **Artists, performers & composers:** Everyone is listed once, with what they do behind the name in smaller text (*piano, composer*). Click a name to open Artist Info. If the line gets too long, the roles are left out to make room for more names; if there are still more names than fit, click +n more at the end of the line for the others.
- **Signal path badge:** Green with a tick while the DAC gets the file's samples unchanged, amber with a dot otherwise. Click it to see the Signal Path.
- **Booklet & favourite:** If the album folder contains a PDF booklet, a Booklet icon appears; click it to read the booklet. Click the Heart to mark the playing album as a favourite.
- **Output sample rate:** Click the output rate on the right of the banner to choose another resampling target rate.
- **Sizes:** Drag the lower edge of the banner to make it smaller or larger, and the border between the library and the playlist to change their widths.

{4} **Search bar:** Filters the library on title, artist, album artist, composer, performer, album, genre and folder. Accents are ignored (searching for *Dvorak* also finds *Dvořák*), and so are full stops and commas (*op 27* finds *Op. 27*, *js bach* finds *J.S. Bach*). The tree shows what was found; with the tiles shown, they show the albums found.

{5} **Tree or tiles:** The two buttons next to the search bar switch the library pane between the tree (the button with the lines) and album tiles (the button with the squares). Ctrl+G does the same, and so does Library as tiles in the View menu of the main menu.

- **Narrow pane:** There is one button, which switches between the two.
- **Sort buttons:** With the tiles shown, their two sort buttons stand between the search bar and these buttons.
- **More:** The tiles are described further down.

**Rescan button:** The round arrow at the right of this row checks the library folders for new, changed and removed files (Ctrl+F5).

{6} **Playlist selector:** Switches between the playlists. Ordinary playlists come first, auto-playlists follow with a funnel icon. To create, rename or delete playlists, open the Playlist Manager.

{7} **Sort:** Two buttons set the order of the albums in this playlist.

- **The button with the name:** Chooses the order: Playlist order (the order in which the music was put in), Artist, Album, Year (the oldest first) or Added to library (the newest first).
- **The arrow button:** Reverses that order; the arrow points down while it is reversed.
- **A sort is a view:** It changes what is shown and the order of playback. The order in which the music was added is kept, and Playlist order brings it back.
- **While sorted or reversed:** Albums can't be dragged to another place, and added music finds its own place.
- **Remembered:** Each playlist keeps its choice. The buttons aren't there in a flat list, which is sorted by its column headings.

{8} **View & edit:** The View button changes how the playlist is grouped and shown; the pencil {9} opens the Playlist Manager. Album header format and Track format each offer a few common formats and Choose fields, which opens the boxes described under Playlist Editor. The album header format can only be chosen while the playlist is grouped By album, and the track format not in a flat list. Work headings, at the bottom of that menu, switches the headings of works on or off for all playlists.

{10} **Library pane:** The music collection, grouped by folder, artist, album or genre, as a tree or as album tiles {5}. Right-click (or click the three dots on a row) for more options, such as playing or adding to a playlist (Replace current playlist empties the playlist first), Auto-collapse other nodes, Virtual Folders, Tools (ReplayGain and the tag consistency check for the selection) or Properties. If a library folder sits on a drive that isn't connected, it's dimmed and marked (not available); its tracks stay in the library.

- **Groups:** The Show entry of the right-click menu switches the groups Artists, Composers, Albums and Genres on or off; a group comes or goes at once. The same four switches are in Preferences > Appearance.
- **Composers:** This group is off at first. It lists the composers from the composer tag with their albums; a track with several composers stands under each of them. An album is named with its artist there, so recordings of the same work stay apart.
- **Virtual Folders in a folder:** A folder counts with the Virtual Folders inside it: playing or adding the folder takes their tracks along, and its tiles show their albums.
- **Position:** The library is as it was when Aulumic was closed: the same nodes open, the same selection and scroll position, and the tiles at the same place.
- **Refresh:** F5 reads the selected folder again from the library and brings the playlist up to date.

{11} **Playlist pane:** The tracks of the selected playlist, with the album covers in the album headers. Click the stars to rate a track or a whole album; click the cover in an album header to open the Cover Art Viewer. Right-click for more options: what can be done with the selected tracks comes first (Play, Select work, Rating, Favourite - five stars, Add to, Open folder, Tools - ReplayGain and the tag consistency check -, Remove from playlist), then what concerns the whole playlist, then the Playlist Manager and Properties.

- **Album headers:** Under the stars a header shows how many tracks the album has and how long it plays, unless the header format shows these already or the pane is too narrow. While scrolling through a long album, its header stays at the top of the list, and it works there as usual: click the cover, the stars or the triangle. This can be switched off in Preferences > Playlists, or with Keep album headers in view in the View menu of the main menu.
- **Flat list:** The view Flat list shows the tracks as a table: number, title, artist, album, rating and time.
  - **Sorting:** Click a heading to sort by that column, and again to reverse. The column sorted by before decides among equal values: click Album, then Artist, for artists with their albums together. A click on # brings back the playlist order.
  - **Columns:** Right-click the headings to choose them; album artist, year, genre, format, plays, last played and added are there too.
  - **Widths:** Drag the line between two headings. In a very narrow pane the least important columns are left out.
  - **Remembered:** Each playlist keeps its own columns, widths and sort. As with the album sort, the order in which the music was added is kept, and tracks can't be dragged while a column sort is on. The track format isn't used in a flat list.
- **Position:** Each playlist remembers its scroll position and which albums were closed, also after a restart.
- **Several discs:** An album on more than one disc gets a small Disc 1, Disc 2 heading above the first track of each disc.
- **Works:** The movements of a classical work stand under a heading of their own. This is described further down.
- **Guest artists:** In an album whose tracks aren't all by the same artist (a compilation, or a track with a guest), the artist is shown behind the title of each track that isn't by the album artist alone. If the track format shows the artist itself, this is left out.

Drag tracks or folders here from the library or from Windows Explorer; they are inserted where they are dropped, and an album is never split. Drag tracks inside the playlist to change the order. Hold Ctrl while dropping from Explorer to replace the playlist and start playing.

Remove dead items (right-click menu) takes out the tracks whose files are gone. Tracks on a drive that isn't connected, or on a NAS that doesn't answer, are kept. Before anything is removed, Aulumic reports how many tracks it found and how many it keeps, and asks. While a drive wakes up, a small window with Cancel is shown.

{12} **Transport controls:** Shuffle, Stop, Previous, Play/Pause, Next, Jump to Now Playing and Repeat, with the position bar above them.

**Output & audio controls:** Click the device name to choose the output device, the sliders icon to open the Tone Control, or the speaker icon to change or mute the volume.

**Status line:** At the left it shows background tasks, such as a library scan, a ReplayGain scan or saving tags; otherwise the number of tracks in the playlist and their total time, or the same for the selection when several tracks are selected. At the right, during playback, it shows the processor load, and a note for a few seconds when the sound was interrupted.

![Searching the library](09-library-search)

While typing in the search bar, the library shows only what matches, with the albums and tracks found. With the Composers group switched on, the composers of what was found are listed too. With the tiles shown, the albums found appear as tiles.

![The library as album tiles](11-library-tiles)

**Album tiles:** A second way to look at the library: the albums as covers, with the album and the artist under each. The tree stays the way to choose what is shown.

- **What is shown:** The albums under the node that is selected in the tree: a genre, an artist, a composer, a folder (with the albums of the Virtual Folders inside it). A line above the tiles shows the path to it (*Folders > Music > Jazz*). Click a part of the path to go up to it; the first part and the cross behind the path show all albums. With the keyboard: Tab to the path, Left and Right to choose a part, Enter to go there. With the top node of a group selected, all albums are shown, and the line says All albums.
- **Order:** At the right end of the line above the tiles are two buttons, as above the playlist. The button with the name chooses the order: Artist, Composer, Album, Year (the oldest first), Added to library (the newest first) or Folder (as the folders stand in the tree). The arrow button next to it reverses that order; the arrow points down while it is reversed. By composer, the composer stands under each album; an album with several composers is listed as *Various composers*.
- **Buttons on a tile:** The tile under the pointer and the selected tile show two round buttons: one plays the album, the one with the three dots opens the tile's menu. With several tiles selected, they act on all of them.
- **Size:** Hold Ctrl and scroll the mouse wheel over the tiles, or choose it in Preferences > Appearance. The smallest size is a list: a small cover with the album and the artist beside it. A text that doesn't fit is cut short; resting the pointer on the tile shows all of it.
- **Using a tile:** A tile stands for all tracks of its album. Double-click plays it (or shows it in the tree, as set for the double click in Preferences), drag it onto the playlist to add it, right-click for the menu: Play, Add to and Replace current playlist, Show in tree, Open folder, Tools (ReplayGain and the tag consistency check) and Properties. Several tiles can be selected with Ctrl and Shift.
- **Search:** The search bar fills the tiles with the albums found. An album that is there because of some of its tracks says how many were found; the menu entry Show in tree then shows the tracks themselves.
- **Typing a letter:** Jumps to the next tile that starts with it - the artist when the tiles are sorted by artist, the composer when sorted by composer, else the album.
- **Width:** When the border between the library and the playlist is dragged while the tiles are shown, the tiles keep that width for themselves, and the tree keeps its own.
- **Covers:** The tiles use the small covers made by the library scan. An album without a cover gets a coloured tile.

![The works of a classical album in the playlist](12-playlist-works)

**Works:** In classical music an album holds a few large pieces, each cut into several tracks: the movements of a concerto or a symphony. In the playlist such tracks get a heading with the name of the work above the first of them, and show only their own part under it: *I. Allegro* under *Symphony No. 5*.

- **Where the work comes from:** From the Work field of the tags (see Properties). Without it, from the titles, when two or more tracks in a row begin with the same text and a colon.
- **Single pieces:** A piece of one track gets no heading; its title says it all.
- **Select work:** In the right-click menu of a track, it selects all tracks of its work, to play, rate or add them together.
- **Switching it off:** View > Work headings above the playlist. The flat list never has these headings.

![The light theme with a smaller banner](04-light-small-banner)

The same window in the light theme, with a smaller banner.

# Signal Path

Click the Signal path badge in the banner to see every stage between the file and the DAC. A stage that changes the signal is amber and has a dot at its icon. The popup keeps up with playback while it's open; click the badge again or press Esc to close it.

![The signal path of a processed DSD stream](44-signal-path)

- **Green:** The stage passes the signal on unchanged (for example *Resampler: Bypassed*).
- **Amber:** The stage changes the signal (for example ReplayGain, the tone control, the resampler or a volume below 100 %).
- **Grey:** The source file and the output device.

The stages are the source file, the decoder or the DSD transport (DoP, native DSD or DSD to PCM), the downmix of a file with more than two channels, ReplayGain, the tone control, the resampler, the volume, dither or the bit depth, warnings such as clipping or dropouts, and the output format the device accepted. When the summary at the top says **Bit-perfect**, the DAC gets the file's samples unchanged.

# Keyboard shortcuts

![Preferences: Shortcuts lists them all](24-prefs-8)

All shortcuts are also listed in Preferences > Shortcuts.

## Playback & navigation

- **Play / pause:** `Space` or `Media Play/Pause`
- **Stop:** `Media Stop`
- **Stop after current track:** `Ctrl + E`
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

- **Main menu:** `F10` or `Alt`
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

Open Preferences from the main menu, with the gear in the title bar, or with Ctrl+P. The settings are on nine pages, listed on the left: Library, Appearance, Playlists, Output, DSD, Resampler, Volume, System and Shortcuts. Every setting has a short description under its name. OK keeps the changes, Cancel drops them.

**Cards:** Settings that are set once and then left alone sit in cards at the bottom of a page. Click a card to open it, and again to close it.

**Related settings:** Some pages end with buttons that lead to a neighbouring subject, for example from Output to the audio thread settings on the System page.

## 1. Library page

![Preferences: Library](24-prefs-0)

- **Library folders:** The folders that make up the music library. The Add folder button adds one; Remove takes one out of the library (the files stay on disk). The folder button beside Remove opens the selected folder in Explorer.
- **Choosing a folder:** In the folder dialog, the arrow at the end of a row opens that folder, and the path above the list leads back. Select folder takes the folder named beside the button.
- **Scan now:** Checks the library folders for new, changed or removed files. A cover that was changed in another program also updates the album thumbnail. Folders on a drive that is disconnected or asleep keep their tracks. The progress is shown on the page.
- **Repair:** Rebuilds the library from scratch, including all album thumbnails. Try it when tracks are missing or the library looks wrong.
- **Watch the library folders:** New and changed files show up in the library by themselves a few seconds later. Network folders aren't watched; press Refresh (F5) or Rescan (Ctrl+F5) for those.
- **Auto-scan on startup:** Checks the library for changes at every start.

## 2. Appearance page

![Preferences: Appearance](24-prefs-1){1=19.5,14.5 2=76,22 3=80,66 4=91,87.5 5=64.5,87.5 6=12,87.5}

Every page of Preferences is built the same way; the numbers are those in the picture:

- {1} **Pages:** The pages are listed at the left; click one to show it.
- {2} **Settings:** Every setting has a short description under its name.
- {3} **Cards:** Settings that are set once are in cards: click a card to open it, and again to close it.
- {4} **OK:** Keeps the changes; Cancel (or Esc) drops them.
- {5} **Apply:** Uses the changes at once and keeps Preferences open. What was applied stays, also after Cancel.
- {6} **Reset this page:** Sets the settings of the page in view back to their defaults; nothing changes until OK or Apply. The output device, the library folders, the volume lock and the Last.fm key are kept.

The settings of this page:

- **Theme:** Dark, light, or the app setting of Windows. Changes at once.
- **Accent colour:** Used for the selection, the sliders and the highlights.
- **Text size:** The size of the text in all windows.
- **Compact rows:** Lower rows in the playlist and the library tree, so more of them fit on the screen.

### Card: Main window

![The Main window card, open](24-prefs-1-mainwindow)

- **Double click:** What double-clicking a library node does: play it at once, or only open or close it. For an album tile the second choice shows the album in the tree.
- **Auto-collapse other nodes (accordion):** Closes the other open folders when one is opened.
- **Show Artists, Composers, Albums, Genres:** Shows or hides these groups in the library pane. Composers is off at first.
- **Show peak meter:** Shows the peak meter in the banner. Its top block turns red for a moment when a sample was clipped.

### Card: Text and tile size of the panes

- **Library / playlist text size:** The text size of the two panes. Holding Ctrl and scrolling the mouse wheel over a pane changes it too.
- **Album tile size:** The size of the album tiles in the library pane: List, Small, Medium or Large. Holding Ctrl and scrolling the mouse wheel over the tiles changes it too.

## 3. Playlists page

![Preferences: Playlists](24-prefs-2)

- **Playlists grouping:** The default grouping of the playlists; each playlist can override it in the Playlist Editor.
- **Album header format, Track format:** The fields of the album headers and of the track lines: up to four, one per box, in the order of the line. The line under the boxes shows an example. Each playlist can override them.
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

- **Play DSD natively:** Sends DSD to the DAC as DSD: over WASAPI packed as DoP, over ASIO as native DSD when the driver supports it (otherwise as DoP). When it is off, DSD is converted to PCM. A DSD file with more than two channels is always converted, since it is mixed to stereo.
- **DSD low-pass:** Applies a low-pass filter when DSD is converted to PCM.
- **DSD gain:** The level of DSD converted to PCM. `+0.0 dB` keeps the original level; `+6.0 dB` brings DSD closer to the level of FLAC and WAV files. Loud passages can then exceed full scale; Headroom on *Automatic* (Volume page) lowers the album just as far as needed.
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
  - **A fixed amount:** From `0.0 dB` to `-6.0 dB`. Lowers everything by that much. It is not applied when the volume is locked to 100 %.
- **Enable soft clipping limiter:** Gently rounds off peaks that would otherwise clip. It is not needed with Headroom on Automatic; it is of use with a fixed headroom.

### Card: ReplayGain scan

![The ReplayGain scan card, open](24-prefs-6-rgscan)

- **Tracks at the same time:** How many tracks of an album the ReplayGain scanner measures at once. More is faster, but the processor gets warmer. The measured values are the same.

### How automatic headroom works

- **What it does:** Some albums come out above full scale after upsampling, after DSD is converted to PCM, or when more than two channels are mixed to stereo, and would clip. The peaks are measured during playback, and the album is lowered just as far as its highest peak needs. Nothing is clipped or limited.
- **Per album:** All tracks of an album get the same level. The peak is remembered, so the next time the album starts at the right level.
- **Never touched:** Quiet albums and bit-perfect playback.
- **Where it is shown:** The signal path shows what is taken off, for example `Headroom -0.8 dB`.

## 8. System page

![Preferences: System](24-prefs-7)

- **Keep music drives awake during playback:** Stops the drives with the playing music from falling asleep, so the next track starts without a delay.
- **Animations:** Short fades and gliding movements. They are only shown while *Animation effects* is switched on in the Windows settings. Turn the switch off to have everything change at once.
- **Use the graphics card:** The graphics card draws the lists and other large areas, which keeps scrolling smooth. Turn it off if parts of a window stay black or flicker.

### Card: Audio thread

![The Audio thread card, open](24-prefs-7-thread)

These settings help Windows give audio playback priority over other tasks. Leave them on unless they cause trouble on older hardware.

- **Optimize CPU core affinity:** Keeps the audio thread off CPU core 0, where Windows handles most interrupts.
- **Enable MMCSS ('Pro Audio' mode):** Registers the audio thread with Windows as a "Pro Audio" task, so it gets priority and is not throttled.
- **Enable high-resolution kernel timer (1 ms):** Sets the Windows timer to 1 ms during playback and stops Windows from slowing the player down to save power. Turn it off to save battery on a laptop.

### Card: Log

- **Always save the log:** Writes the log to `AulumicNSLog.txt` in the Data folder at every exit (the file is replaced each time). Without this switch a log is only saved after an error, as `AulumicNSLog_<date>.txt`. Turn it on to report a problem or to see what the last session did.

### Card: Internet

- **Check for updates at start:** Asks GitHub once at every start whether a newer version is available. When there is one, a box offers to open its download page; Skip this version keeps the box away until a later version is released. Off by default.
- **Last.fm API key:** Optional. Without a key Artist Info takes its biographies from Wikipedia; with a personal key from Last.fm, which knows more artists. Aulumic has no key built in.
  - **Getting one:** It's free. Create an API account at last.fm/api and paste its "API key" into this field.
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

![The Playlist Editor of a standard playlist](33-playlist-editor){1=84,15.9 2=84,25.8 3=90,43.6 4=90,65.2}

## General settings

- {1} **Playlist name:** The name of the playlist. "Default" is reserved.
- {2} **Grouping:** By album, By folder or Flat list. *Use global preferences* follows the setting in Preferences > Playlists.
- {3} **Album header format:** The fields of the album headers, up to four, in the order of the line (only when grouped By album). With every box on (nothing), the playlist follows Preferences.
- {4} **Track format:** The fields of the track lines, chosen the same way.

## Auto-playlist rules

![The Playlist Editor of an auto-playlist](34-autoplaylist-editor){1=84,10.3 2=84,16.8 3=90,28.4 4=90,42.5 5=84,55.6 6=75,62.1 7=84,71.2 8=61.5,80.5}

An auto-playlist has the general settings of every playlist ({1}, {2}, {3} and {4}, see above) and is built from one or more rules; each rule checks one tag.

- {5} **Rules:** A ready-made set of rules, or *Custom* for own rules.
- {6} **Query builder:** Pick the tag, the operator and the value, then click Add.
- {7} **The rules:** The rules of this playlist. Click one to load it into the boxes above it.
- {8} **Remove:** Takes the selected rule out of the list. The Rules button opens this help topic.

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
- **Codec:** The file format: FLAC, WAV, AIFF, M4A, DSF or DFF.
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

{1} The selected tracks. Click a track to edit it, or select several (Shift, Ctrl or Ctrl+A) to edit them together. A dot marks a track with unsaved changes; a track whose tag cannot be read is marked with an exclamation mark and is never changed.

## 1. Tags tab

The tabs {2} switch between the tags and the Inspector.

- {3} **Fields:** Title, Artist, Album artist, Album, Genre, Composer, Year, Track, Disc, Work, Performer and Comment (several lines).
- **Work:** The large piece a track is a part of, such as the symphony whose movement it is. Give all its tracks the same text here (select them together); the playlist then shows them under a heading with that name.
- **Several names:** For Artist, Album artist, Genre, Composer and Performer, separate several entries with a semicolon (;). For a performer, the instrument or role can be put in brackets behind the name, such as *Ida Feld (double bass)*; the banner shows it next to the name.
- **Several tracks:** Fields that differ between the selected tracks show Varies; Title and Track show Unique and are edited one track at a time. A value typed in a shared field is applied to all selected tracks. Only the changed fields are written.
- {4} **Cover:** The Load button chooses an image file, Search the web looks for the cover online, and Remove takes the cover out of the selected files. An image file can also be dropped on the window or pasted with Ctrl+V.
- {5} **Save:** Writes the changes. They're written in the background, so listening can go on. Cancel (or Esc) drops them. DFF files can be tagged too.
- **Open folder:** Shows the selected file in Explorer; also in the right-click menu of the file list.
- **Damaged tag:** A WAV, DSF or DFF file whose tag is damaged isn't saved, because whatever lies behind the damage would be lost. A Repair tag button next to Cancel shows what can be recovered and asks first; Save then writes the repaired tag. A copy of the old tag is kept in the folder `TagBackups` of the data folder.
- **Undo repair:** For a single file whose tag was repaired, an Undo repair button stands in the same place. Save then puts the old tag back exactly as it was; tag changes made since the repair are lost.

## 2. Inspector tab

![Properties: the Inspector tab](36-properties-inspector)

The Inspector shows the technical details of the files; nothing can be changed here. It lists the audio format, the file (size, location, date added), the play statistics and every tag exactly as it is stored in the file. With several tracks selected it shows a summary of the selection: the number of tracks, their total time and size, the formats, the folders, album artist, album, year and genre, how many tracks have ReplayGain, and the play statistics. A property that differs between the tracks lists its most frequent values with their counts.

# Tag consistency

Tag consistency lists what may need a look in the tags of a part of the library.

![Tag consistency](49-tag-consistency)

Open it for a selection with Tools > Check tag consistency in the right-click menu of the library, the tiles or the playlist, or for everything with Main menu > Tools > Check tag consistency of the library.

- **The basics:** Tracks without an album, an artist, a title (only the file name) or a track number.
- **An album that disagrees with itself:** Several album names in one folder; several album artists or years in one album; a track number twice; a gap in the track numbers.
- **Composer:** An album where no track has a composer, or only some of them.
- **Names:** Composers with the same surname that are written in more than one way, side by side with the number of tracks of each: *Johann Sebastian Bach (311) | J. S. Bach (48)*. For artists and genres: names that are the same once capitals, accents, spaces and punctuation are left out, such as *Dvorak* and *Dvořák*.
- **Not every line is a mistake:** A gap can be an album of which only some tracks are there, and two composers can share a surname.
- **Filter:** The box at the top right shows the findings of one kind, with the number of each.
- **Order:** Click a column heading to sort by it, and again to reverse; Sort by in the right-click menu does the same. Sorted by Finding, all lines of one album stand together.
- **Open in Properties:** Double-click a line (or press Enter) to open its files in Properties, where they are changed and saved as usual. Several lines can be selected with Ctrl or Shift and opened together.
- **Open folder:** Shows the folder of the selected line in Explorer; also in the right-click menu.
- **Check again:** Reads the same part of the library anew.

# Tone Control

The Tone Control shapes the sound in five bands. Open it with Ctrl+T or the sliders icon next to the speaker icon.

![The Tone Control](46-tone-control){1=33,11.6 2=71,11.6 3=88,21.5 4=22,38.8 5=4.2,43.5 6=78.5,54.6 7=6,72}

Each of the five bands (bass, low mid, mid, high mid and treble) has its own frequency and gain. Bass and treble raise or lower everything below or above their frequency; the three middle bands work around theirs.

- {1} **Presets:** Shows the preset in use: its name, "Flat" when all bands are at 0 dB, or "Custom" for a setting that isn't saved. Click it to choose a preset or Flat, or to save, rename or delete a preset. A preset doesn't switch the tone control on or off.
- {2} **Enable:** Turns the tone control on or off. When it's off, it's out of the signal path completely and playback stays bit-perfect.
- {3} **The curve:** Shows what the five bands do together, from 20 Hz to 20 kHz, with a dot for each band that is set. When the tone control is off, the curve is grey.
- {4} **Level line:** A boost raises the peaks of the music. With Headroom set to Automatic (Preferences > Volume), the level is lowered just enough to keep them from clipping, and this line says by how much: "Level lowered by 1.4 dB to avoid clipping".
- {5} **Frequency:** The centre frequency of each band.
- {6} **Width:** How wide a middle band works around its frequency; click the word under the frequency to change it: Narrow (about one octave), Normal (about two) or Wide (about three). Bass and treble have no width.
- {7} **Gain:** Up to ±10.0 dB per band; 0 dB leaves a band out. Scroll the mouse wheel over a slider, or use the arrow keys when it has the focus.

A change glides in, so there is never a click while the music plays.

When DSD goes out as DSD, the tone control and the volume control don't apply. The Tone Control window then says "disabled for DSD" in its title and its controls are greyed out.

# ReplayGain scanner

The ReplayGain scanner measures the loudness of music files with the built-in EBU R128 meter, so tracks and albums play at a similar level. Open it from the main menu (Tools > Calculate ReplayGain for the library), or right-click items in the library or the playlist and choose Tools > Calculate ReplayGain.

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

Each file is listed with its track gain and peak, its album gain and peak (empty for a track without an album tag), or the reason it could not be measured (for example a disconnected drive, a moved file or a damaged file). Nothing is written to the files until Save all is clicked; the tags are then written in the background. Cancel drops the results. Right-click a row for Open folder.

# Virtual Folders

Sometimes an album belongs in more than one place: under the composer and under the orchestra, for example. A Virtual Folder lets albums appear in another library folder without copying or moving any files.

![The Virtual Folder editor](39-virtual-folder)

## What is a Virtual Folder?

A Virtual Folder is a small link file (`.aullink`) inside a library folder that shows the contents of one or more other folders. It opens right inside the library tree, as if the music were stored there; it is shown with a link icon.

## Creating and managing Virtual Folders

Right-click a folder in the library and choose Create Virtual Folder, or right-click a Virtual Folder and choose Edit Virtual Folder or Remove Virtual Folder.

- **Name:** The name in the library tree.
- **Auto-find term:** The name or word to search for; press Enter to run Auto-find at once. Several searches in a row combine several artists or composers. If left empty, Auto-find uses the name.
- **Search in:** Artist / performer, Composer, Album / title, Comment / genre and Folder name.
- **Auto-find:** Searches the library for folders whose tracks match every word; accents are ignored. Tracks in disc sub folders (such as `CD1`) are added as their album folder. New folders are added to the list and selected, so they are easy to check.
- **Add folder...:** Choose a folder by hand, or drag folders from Windows Explorer into the list.
- **Open folder:** Shows the selected folder in Explorer.
- **Remove:** Removes the selected folders from the list (Del). The folders themselves are not changed.

## Common use cases

- **Composer and performer:** For an orchestra folder, run Auto-find with the orchestra's name: every album where the orchestra is credited (as Artist, Album artist or Performer) is linked into it.
- **Own collections:** For a collection such as "Late Night Favourites", create a Virtual Folder and link the albums with Auto-find or by dragging folders. The albums stay where they are and also appear in the collection.

A folder counts with the Virtual Folders inside it: playing or adding that folder takes the linked albums along, and its album tiles show them.

# Cover Art Viewer

The Cover Art Viewer shows an album's cover at full size. To open it, click the cover or the album title in the banner, or the cover in an album header of the playlist. From the keyboard: Now playing in the main menu, or Cover Art Viewer in the playlist's right-click menu.

![The Cover Art Viewer](40-cover-viewer)

The cover is shown as large as the window allows, with the format of the track below it. If the album folder holds more images (a back cover, booklet scans in a *Scans* folder), click, right-click, scroll the mouse wheel or use the arrow keys to step through them; Home and End go to the first and the last. The embedded cover comes first, unless the folder has its own front cover.

# Artist Info

Artist Info shows a biography and a picture of an artist. To open it, click an artist, performer or composer in the banner.

![Artist Info](41-artist-info)

Next to the biography and the picture, it says how many albums and tracks of the artist are in the library. The information comes from Last.fm, Wikipedia and TheAudioDB (the artist's name is sent to these services) and is kept in the Data folder, so it's there right away next time. The biography is the introduction of the artist's English Wikipedia article, or Last.fm's text when a free Last.fm API key is entered in Preferences > System > Internet. The line under the text names the source; a click on it opens that page.

- **Edit (F2):** Edit the biography; it is saved automatically.
- **Picture (Ctrl+O):** Choose a picture, drop an image file on the window, or paste one with Ctrl+V. Remove (Del) deletes it.
- **Search the web:** Opens a web search for the artist (and starts editing, so text can be pasted).
- **Refresh (F5):** Reloads the information from the online sources. A chosen picture and an edited biography are kept; to get the online version back, remove the picture or empty the biography, then press F5.

![Editing the biography](42-artist-info)

# Booklet Viewer

When the playing album has a PDF booklet (in its folder, in a sub folder such as *Scans* or *Artwork*, or in the album folder above a *CD1* / *Disc 2* folder), the Booklet icon appears in the banner. Click it to read the booklet in the built-in viewer.

![The Booklet Viewer showing two pages side by side](45-booklet)

- **Single / Spread:** One page at a time, or two facing pages like an open booklet (the cover alone first).
- **Zoom:** The minus, fit and plus buttons, the `+` and `-` keys, Ctrl with the mouse wheel, or a double-click. Drag the page or use the mouse wheel to move around when zoomed in.
- **Other booklets:** When the album has more than one PDF, the button on the left switches between them.
- **Open with the PDF program of Windows:** The folder button on the right.
- **Open folder:** Right-click the page.

# Audio concepts

![The Signal Path shows what happens to the audio](44-signal-path)

## I. Core playback & formats

- **Bit-perfect:** The audio reaches the DAC exactly as it is stored in the file, without any change.
- **PCM (pulse code modulation):** The basis of almost all digital audio, including CD, WAV and FLAC. PCM stores the sound wave as a series of measurements (samples). The sample rate is how many samples are taken per second (for example 44.1 kHz); the bit depth is how precise each sample is (for example 16 or 24 bits).
- **FLAC and Apple Lossless (ALAC):** Both make files smaller without losing any quality; when played, the audio is identical to the original. WAV and AIFF store the same audio uncompressed. Lossy formats such as MP3 or AAC permanently remove audio information.
- **DSD (Direct Stream Digital):** A 1-bit format, used for SACD (DSF and DFF files). DSD can be sent unchanged to a DAC that supports it; volume control and processing such as ReplayGain are then not applied. If the DAC doesn't support DSD, turn off *Play DSD natively*; DSD is then converted to PCM during playback.
- **DoP (DSD over PCM):** DoP packs the unchanged DSD data into 24-bit PCM frames, so connections that only handle PCM can carry it. The DAC unpacks it and plays it as native DSD, without any loss.
- **Native DSD (ASIO):** Over ASIO, a driver that supports DSD receives the DSD data directly, without DoP packing.

## II. Digital signal processing (DSP) & resampling

- **Resampling:** Upsampling (for example from 44.1 kHz to 176.4 kHz) moves most of the filtering from the DAC to the PC: the DAC still filters, but at a higher rate, where its filter has less to do. Whether that sounds better depends on the DAC. Downsampling is needed when a file has a higher rate than the DAC supports.
- **Filter phase:** Resampling needs a digital filter, and this filter affects the timing of the frequencies.
  - **Linear phase:** All frequencies stay exactly in time, but a very short "pre-ringing" can occur just before a sharp sound.
  - **Minimum phase:** No pre-ringing; the ringing moves to just after the sound, where it is usually considered less audible.
  - **Intermediate phase:** Halfway between the two.
- **Downmix:** A file with more than two channels is mixed to stereo: the front channels at full level, the centre and the surround channels 3 dB lower into their side, and the subwoofer channel left out.

## III. Volume & dynamics

- **64-bit floating-point volume:** Volume and all other PCM processing are calculated in 64-bit floating point and dithered at the end, so the calculation itself adds no audible error. A digital volume control still uses fewer of the DAC's bits the further it is turned down; for the last bit of resolution, lock the volume and use the DAC or amplifier.
- **ReplayGain and clipping:** Albums are mastered at very different levels. ReplayGain adjusts the playback level, so the volume doesn't have to be changed all the time. Raising a quiet track can push peaks above 0 dBFS, which causes clipping; the peak stored with the ReplayGain values and the Headroom setting prevent this.
- **Inter-sample peaks and headroom:** Digital audio stores samples, but what is heard is the smooth wave through them, and between two samples that wave can be higher than both. After resampling such peaks may not fit into the output and would be clipped. Headroom on Automatic lowers the level of such an album by exactly the missing amount, usually a fraction of a dB.

## IV. System performance

- **MMCSS (Multimedia Class Scheduler Service):** A Windows service that gives registered audio threads priority. The audio thread is registered as a "Pro Audio" task (Preferences > System), also while the window is minimized.
- **Power throttling:** Windows slows down programs whose window is minimized or hidden. With the *High-resolution kernel timer* option on, the player asks to be left out of that.

## V. What the processing adds

- **Decoding:** FLAC, Apple Lossless, WAV and AIFF give exactly the samples that were stored.
- **Rounding:** Once, at the end, with dither, and only when a stage changed the samples.
- **Resampler:** Measured with test tones, images and aliasing stay below -150 dB at 24-bit precision, and below -200 dB at 32-bit precision. The level in the pass band is right to within 0.001 dB.
- **DSD to PCM:** What the conversion folds back into the audible range lies below -165 dBFS, measured on recordings.
- **Tone control:** The error of its filters lies below -230 dBFS. For comparison, the last bit of a 32-bit DAC is at -186 dBFS.
- **Automatic headroom:** Lowers the level; never clips and never limits.

# Configuring bit-perfect playback

![Preferences: Output](24-prefs-3)

Out of the box the output is bit-perfect as long as the volume is at 100 %. To make sure it stays that way:

- **Lock the volume:** In Preferences > Volume, turn on *Lock volume to 100%*, so it can't be turned down by accident.
- **ReplayGain off:** Keep ReplayGain turned off, so the level of the tracks is not changed.
- **Resampling off:** Keep PCM resampling turned off.
- **Tone control off:** Keep the tone control disabled (Ctrl+T).
- **DSD natively:** Keep *Play DSD natively* turned on, so DSF and DFF files reach the DAC as DSD.
- **Two channels:** A file with more than two channels is mixed to stereo, so it is never bit-perfect.

> The Signal path badge in the banner is green when the DAC receives the samples unchanged. Click it to see which stage changes the signal when it's amber.

# Log files & troubleshooting

Aulumic keeps a log of each session: library scans, playback errors, files that couldn't be saved and the like.

![The log window](22-log)

- **Show log:** Main menu > Tools > Show log... (or Ctrl+L). Warnings and errors are marked. The buttons Copy, Save to file and Clear work on the whole log.
- **Saved log:** If errors were logged, the log is saved as `AulumicNSLog_<date>.txt` in the Data folder at exit. If there were no errors, nothing is saved, unless *Always save the log* is on (Preferences > System > Log): then `AulumicNSLog.txt` is written at every exit.
- **Dropouts:** If the music cuts out for a moment, the Signal Path shows a Dropouts line with their number, and the log has a line "Dropout at about m:ss in the track". A larger buffer size (Preferences > Output for PCM, Preferences > DSD for DSD sent as DSD) helps. If the log shows no dropout, the cause lies outside Aulumic: the driver, USB or the DAC.
- **A file that won't play:** The message says why. The usual cases: an M4A file with AAC inside, a compressed AIFF file, a DFF file with DST compression, or a damaged file.
- **Black or flickering areas in a window:** Turn off *Use the graphics card* (Preferences > System), and please report the graphics card and its driver version.
- **Debug Queue (Ctrl+D):** Shows what the player is doing: the play queue, the next track and the engine's state. Useful when reporting a problem.
- **ShutdownTraceLog.txt:** Only written next to the program when an error occurs while it closes. Please include it and the log when reporting a problem.
- **HangReport_<date>.txt:** Written next to the program when the window stops responding for 5 seconds. If it stays frozen, end it in the Task Manager; the report is already written. Please include it when reporting a freeze.

# Data and settings

![Aulumic in the light theme](04-light-small-banner)

Everything lives in a Data folder next to the program: the library, the play statistics (ratings, play counts, favourites), the playlists, the peaks remembered by the automatic headroom, the artist information and the settings (`AulumicNS.ini`). Album thumbnails are kept in a Cache folder. If the program folder can't be written to (for example in *Program Files*), `%APPDATA%\AulumicNS` is used instead.

**Library update:** After a new version that keeps more about each track, Aulumic asks at start whether to update the library. This reads the tags of all music files once and can take a while; music can go on playing. With No, the question comes again at the next start.

The library and the playlists are saved at once after every change, so a crash or a power cut loses nothing. To move to another computer, copy the program together with its Data folder. To remove it, delete the program file with its Data and Cache folders. Nothing is installed anywhere else, and music files are only ever changed when tags or ReplayGain values are saved.

# System requirements

![Aulumic in the light theme](04-light-small-banner)

## Minimum requirements

- **Operating system:** Windows 10 or Windows 11 (64-bit).
- **Graphics:** Any graphics card with a Windows 10 driver.
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

Developed with Lazarus and Free Pascal (FPC). The FLAC and Apple Lossless decoders, the resampler, the EBU R128 loudness meter and the user interface are own code; the interface is drawn with Direct2D and DirectWrite, and PDF booklets are shown with the PDF engine of Windows.

## Third-party acknowledgements

- **Tag reading and writing (AulumicTag, a fork of OvoTag):** Copyright © 2011 Marco Caselli. Distributed under a modified LGPL (Library GNU General Public License with a linking exception), the same licence structure as the Lazarus Component Library (LCL).
- **Artist information:** Biographies and pictures from Last.fm, Wikipedia and TheAudioDB, subject to the terms of these services.
- **ASIO:** ASIO is a trademark and software of Steinberg Media Technologies GmbH.

*The screenshots in this help show a made-up demo library: the artists, albums and covers do not exist.*
