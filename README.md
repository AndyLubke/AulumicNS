# Aulumic

**A bit-perfect music player for Windows.** Aulumic sends your music straight to your DAC, over WASAPI exclusive mode or your DAC's ASIO driver. Out of the box nothing is touched: resampling is off, DSD goes out as DSD, and the only thing in the way is the volume control.

![The main window of Aulumic](help/shots/02-dark-playing.png)

Aulumic is one program file, `AulumicNS.exe` (NS stands for Native Sound). It needs no installation and no extra DLLs: the FLAC decoder, the resampler, the loudness meter and the whole user interface are part of the program.

## What it does

**Playback**
- WASAPI exclusive mode and ASIO, with a badge and a Signal Path window that show whether the output is bit-perfect, and every stage between the file and the DAC when it isn't.
- FLAC, WAV, DSF and DFF. DSD as native DSD over ASIO, as DoP, or converted to PCM.
- Gapless playback.
- A resampler you can leave off, or set up in detail (quality, phase, bandwidth, anti-aliasing).
- ReplayGain (EBU R128) with a built-in scanner, and automatic headroom against clipping.
- A five-band tone control that shows its curve.

**Library and playlists**
- A library of your music folders with a tree (folders, artists, albums, genres), search and virtual folders. Local folders are watched for changes.
- Album tiles: the albums of any part of the library as covers, next to the tree. A tile plays, drags and opens its menu like an album in the tree.
- Playlists and auto-playlists with a query builder, M3U import and export, ratings and favourites.
- A tag editor, a cover viewer, a booklet viewer for PDF booklets and artist information.

**Look and feel**
- Dark and light theme (or follow Windows), six accent colours, sharp at every Windows scaling, touch scrolling.
- A complete help inside the program (F1).

![The library as album tiles](help/shots/11-library-tiles.png)

## What it doesn't do

Aulumic does one thing: it plays your own lossless music files, unchanged, on Windows. Some things are left out on purpose, others follow from how the program is built.

- **Lossy formats (MP3, AAC, Ogg Vorbis, Opus):** not played. Aulumic uses no external DLLs, so every format needs its own decoder inside the program, and the work went into the lossless ones.
- **Other lossless formats (ALAC, AIFF, APE, WavPack) and CUE sheets:** not at present. FLAC and WAV are the PCM formats.
- **SACD ISO images:** not played. DSD plays from DSF and DFF files.
- **Streaming services (Qobuz, Tidal, Spotify) and internet radio:** no. The services only open their catalogues to programs with a contract, and Aulumic plays files, not streams.
- **Network playback (UPnP / DLNA) and remote control apps:** no. The music has to be in folders the PC can reach; a network share or NAS is fine.
- **More than two channels:** mono and stereo only.
- **Shared mode and plugins:** Aulumic takes the audio device exclusively, which is what makes bit-perfect playback possible, so other programs are silent on that device while it plays. There are no VST plugins and no room correction.
- **Linux and macOS:** Windows 10 and 11 only. The output and the whole user interface are built on Windows itself.

Wishes are welcome under **Discussions**; the Support section below says what to expect.

## Download

Take `AulumicNS-<version>-win64.zip` from the **Releases** page of this repository, unpack it into a folder of your choice and start `AulumicNS.exe`.

- Windows 10 or 11, 64 bit.
- The program isn't signed, so Windows SmartScreen may warn the first time: choose "More info", then "Run anyway".
- Aulumic is portable: it keeps its settings and library in the folders `Data` and `Cache` next to the program file. If it can't write there, it uses `%APPDATA%\AulumicNS`.
- To remove it, delete the folder.

**New versions:** to get an email from GitHub whenever a new version is released, sign in to GitHub, open this repository and choose **Watch > Custom > Releases**. Without a GitHub account, the releases can be followed in a feed reader at `https://github.com/AndyLubke/AulumicNS/releases.atom`.

## First steps

1. **Add your music:** Main menu > Preferences > Library > Add folder.
2. **Choose the output:** click the device name at the bottom right of the main window and pick your DAC. WASAPI devices and ASIO drivers share one list.
3. **Play:** double-click an album or a track.

Press F1 for the help.

### Artist biographies

Artist Info gets its biographies from Last.fm, and Last.fm asks every program for an API key. Aulumic has none built in. A key is free: create an API account at [last.fm/api](https://www.last.fm/api) and paste the key into Preferences > System > Artist information.

## Support

Aulumic is a hobby project of a retired developer, shared as it is. There's no support, and no promise of fixes or new features. That's also why the issue tracker of this repository is switched off.

Remarks and experiences are welcome under **Discussions**. They're read, but may go unanswered.

The help inside the program (F1) explains every window and setting, and has a chapter on solving problems. And you're free to change the program yourself: that's what the licence is for.

## Building from source

You need [Lazarus](https://www.lazarus-ide.org/) 4.8 with Free Pascal 3.2.2, 64 bit. The only package used is the LCL, which comes with Lazarus.

```
lazbuild --build-mode=Release AulumicNS.lpi
```

The program is written to `bin\Release\AulumicNS.exe`. Use `--build-mode=Debug` for a build with range checks and a memory leak report (`heaptrc.log`). You can also open `AulumicNS.lpi` in Lazarus and press F9.

The tests (FPCUnit, nothing is played on a device):

```
lazbuild Tests\AulumicNSTests.lpi
Tests\lib\x86_64-win64\AulumicNSTests.exe --all --format=plain
```

## What is where

| Folder | Content |
|---|---|
| `src\gui` | The user interface library: controls, lists, menus, theme and vector icons, drawn with Direct2D and DirectWrite |
| `src\app` | The program: main window, dialogs, settings |
| `src\audio` | The engine: decoders, resampler, WASAPI and ASIO output, DSD, loudness |
| `src\library` | The music library: database, scanner, queries, folder watching |
| `src\tags` | AulumicTag: reading and writing tags (a fork of OvoTag) |
| `help` | The help text (Markdown) and its screenshots, built into the program |
| `Tests` | The test program |
| `Tools` | Development tools: an audio simulator, a library benchmark, check scripts |

All windows are built in code; there are no `.lfm` form files.

## How it was made

Aulumic is the work of André Lubke: built on his earlier, hand-written player of the same name, and developed further with the help of Claude Code (Anthropic's AI coding assistant).

## Licence

Copyright © 2026 André Lubke.

Aulumic is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License, version 3**, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but **without any warranty**; without even the implied warranty of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full text.

Parts by others, and their licences, are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). In short:

- **AulumicTag** (`src\tags`) is a fork of OvoTag, Copyright © 2011 Marco Caselli, under a modified LGPL.
- **ASIO** is a trademark and software of Steinberg Media Technologies GmbH.
