unit uPlaylistFile;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uPlaylistFile
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The entry of a stored playlist: the file and the tags kept with it, so a
  track outside the library is shown without reading its file.

  ---> AulumicNS: only the record is left. This unit was Aulumic's reader and
  writer of its binary playlist files ('ALPL', *.pdb: LoadPlaylistFile,
  SavePlaylistFile). AulumicNS keeps all playlists in uPlaylistStore
  (playlists.adb + journal) and has no import from Aulumic, so that code and
  its tests were removed on 2026-11-12 (they are in the backups).
  HasGenre / HasExtendedInfo came from the old file versions that lacked
  these fields; uPlaylistRows still sets and reads them.
  =============================================================================}

interface

type
  TPlaylistEntry = record
    FilePath    : string;
    Title       : string;
    Artist      : string;
    AlbumArtist : string;
    Album       : string;
    Genre       : string;
    DurationStr : string;
    TrackNum    : Integer;
    DiscNum     : Integer;
    Year        : Integer;
    DateStr     : string;
    SampleRate  : Integer;
    BitDepth    : Integer;
    // False when the file predates the field (the caller may fill it in,
    // e.g. from the library)
    HasGenre        : Boolean;  // v6+
    HasExtendedInfo : Boolean;  // v4+: Year, DateStr, SampleRate, BitDepth
  end;
  TPlaylistEntries = array of TPlaylistEntry;

implementation

end.