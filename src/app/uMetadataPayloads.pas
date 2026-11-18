unit uMetadataPayloads;

{$mode ObjFPC}{$H+}

// =============================================================================
// Project:      Aulumic
// Unit Name:    uMetadataPayloads
// Author:       André Lubke
// Date Created: 08-Jul-26
//
// Defines the strict data records, structures, and pointer types
// (like TMetadataJob) used to safely pass information between the UI and
// background threads.
// =============================================================================

interface

uses
  Classes, SysUtils;

type
  TMetadataActionType = (matReplayGain, matTagEditor);

  TReplayGainPayload = record
    TrackGain : Double;
    AlbumGain : Double;
    TrackPeak : Double;
    AlbumPeak : Double;
    // ---> AulumicNS: a track without an album tag: only the track gain and
    // peak are written (album gain and peak fields are removed)
    TrackOnly : Boolean;
  end;

  TAudioTagValues = record
    Title       : string;
    Artist      : string;
    AlbumArtist : string;
    Composer    : string;
    Performer   : string;
    Album       : string;
    Genre       : string;
    Track       : Integer;
    Disc        : Integer;
    DateStr     : string;
    Comment     : string;
    CustomTags  : string;
  end;

  TTagEditorPayload = record
    Current            : TAudioTagValues;
    // ---> AUDIT FIX: Values as loaded from the file; the custodian only
    // writes the fields where Current differs from Original.
    Original           : TAudioTagValues;
    IsModified         : Boolean;
    CoverModified      : Boolean;
    HasCover           : Boolean;
    CoverData          : TBytes;
    CoverMimeType      : string;
  end;

  PMetadataJob = ^TMetadataJob;
  TMetadataJob = record
    FilePath   : string;
    AlbumName  : string;
    ActionType : TMetadataActionType;
    ReplayGain : TReplayGainPayload;
    TagEditor  : TTagEditorPayload;
  end;

implementation

end.
