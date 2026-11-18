unit uPlaylistFile;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uPlaylistFile
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The entry of a stored playlist: the file and the tags kept with it, so a
  track outside the library is shown without reading its file.

  The playlists are stored by uPlaylistStore (playlists.adb + journal).
  HasGenre / HasExtendedInfo say whether those fields are filled; uPlaylistStore
  and uPlaylistRows set them.
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
    // False when the fields are not filled (the caller may fill them in,
    // e.g. from the library)
    HasGenre        : Boolean;  // Genre
    HasExtendedInfo : Boolean;  // Year, DateStr, SampleRate, BitDepth
  end;
  TPlaylistEntries = array of TPlaylistEntry;

implementation

end.