{
  AulumicTag - modified for Aulumic by André Lubke, 2026.
  AulumicTag is a fork of OvoTag (C) 2011 Marco Caselli; see README.md.
  Changes:
    Registers the new DSF reader.
    AulumicNS: and the DFF (DSDIFF) reader (file_dff).
}

unit RegisterAllReader;

{$mode objfpc}{$H+}

interface

uses
  file_Dummy, file_flac, file_Monkey, file_dsf, file_dff,
  file_mp3, file_Mp4, file_ogg, file_opus, file_Wave, file_wma;

implementation

end.

