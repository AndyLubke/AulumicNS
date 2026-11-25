{
  AulumicTag - modified for Aulumic by André Lubke, 2026.
  AulumicTag is a fork of OvoTag (C) 2011 Marco Caselli; see README.md.
  Changes:
    Registers the DSF and the DFF (DSDIFF) reader.
    Only the readers of the formats the program plays are compiled in: FLAC,
    WAV, AIFF, DSF and DFF, and M4A read only (file_m4a). The readers of the other formats (file_mp3, file_mp4,
    file_ogg, file_opus, file_wma, file_monkey) are still in this folder; one
    of them is added to the uses clause below when its format is played.
}

unit RegisterAllReader;

{$mode objfpc}{$H+}

interface

uses
  file_Dummy, file_flac, file_dsf, file_dff, file_Wave, file_aiff, file_m4a;

implementation

end.

