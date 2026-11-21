# AulumicTag

AulumicTag is a library, written in Free Pascal / Lazarus, to read and modify
the metadata ("tags") of audio files. It is used by the Aulumic music player.

AulumicTag is a **fork of OvoTag** by Marco Caselli (Copyright (C) 2011). The original copyright notices are kept
in every unit; units changed for Aulumic carry an additional notice that
describes the changes.

## Supported file formats

|File format|Notes|
|-----|-----|
|wav | read and save ID3v2 tags in the RIFF `id3 ` chunk (classic RIFF up to 4 GB) |
|flac | read and save Vorbis comments and pictures |
|dsf (DSD) | read and save the ID3v2 tag at the end of the file (new in AulumicTag) |
|dff (DSDIFF) | read and save the ID3v2 tag in the `ID3 ` chunk (new in AulumicTag) |
|mp3 | read ID3v1 and ID3v2 (any version), save ID3v2 |
|mp4 (m4a, aac) | read and save atom tags for m4a, only durations for aac |
|wma | read and save ASF tags |
|ogg / opus | read and save Vorbis comments |
|ape (Monkey's Audio) | read APE, ID3v1 or ID3v2 tags, save APE tags |

Aulumic itself uses the WAV, FLAC, DSF and DFF readers, and only these are
compiled into it (`registerallreader.pas`). The other formats are inherited
from OvoTag, essentially unchanged and not tested with Aulumic.

## Changes compared to OvoTag

Data safety (saving):
- Files are saved through a temporary file that is flushed to disk and then
  replaces the original atomically (MoveFileExW). The original is never
  deleted while another program has it open.
- A file is not saved when its existing tag could not be read, or was only
  partly read (skipped or damaged ID3v2 frames, unreadable Vorbis comments or
  FLAC pictures, unsupported ID3v2 header flags). Saving would otherwise
  replace fields and pictures that were not read. The reason is available in
  `LastUpdateError`.
- A damaged ID3v2 tag can be repaired on request: a repairing read
  (`GetFileTagsObject(FileName, False, True)`) finds the frames behind the
  damaged bytes, reads frame sizes written in the wrong form, and hands out
  the tag as it stood in the file so the caller can keep a copy.
- A save changes only the fields that were set: FLAC comments that were not
  edited are written back byte for byte, ID3v2 frames keep their data.
- Oversized frames and pictures are handled with size limits instead of
  failing or allocating unbounded memory.

New and extended formats:
- DSF (DSD Stream File): reading and writing of the ID3v2 tag, with checks so
  the audio data is never cut off.
- WAV: reading and writing of the ID3v2 tag chunk with strict RIFF validation
  (chunk IDs, pad bytes, the data chunk is always preserved, bytes after the
  RIFF form are kept).
- FLAC: robust metadata block parsing (also with a prepended ID3 tag) and
  writing of picture blocks.
- ID3v2: correct UTF-16 / BOM and TXXX handling, picture (APIC) reading and
  writing, extended header support, text frames with several values, empty
  frames.

Robustness:
- Bounds checks on all lengths and offsets read from files, and exception
  handling, so damaged files cannot crash the application.
- Various bug fixes in the helper functions (year / genre / text handling,
  byte swapping, 64-bit file positions).

## License

Unchanged from OvoTag: a modified LGPL license which allows linking into
executables; see [FPC modified LGPL](https://wiki.freepascal.org/FPC_modified_LGPL)
and the files `COPYING.LGPL.txt` and `COPYING.modifiedLGPL.txt`.
Changes to the library itself are distributed under the same license.

Note on the file headers (checked 2026-11-12 against github.com/varianus/ovotag, branch main):
the comment at the top of the units still carries the GNU General Public License text of
OvoPlayer, the player the library was taken out of (audiotag.pas even reads "OvoPlayer is
free software"). That is so in the upstream repository too. The upstream README and the two
COPYING files state the modified LGPL, and that is the licence the author gives the library.
The headers are left as upstream has them; correcting them is the upstream author's to do.
