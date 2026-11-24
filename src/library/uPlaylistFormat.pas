unit uPlaylistFormat;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - uPlaylistFormat
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The album header format and the track format of a playlist as up to four
  fields in a row (Album, Artist, Year ...), which is how they are chosen on
  the screen. They are stored as a format text for FormatTrackInfo:

    [%first_albumartist% • ][%year% • ]%album%[ • %resolution%]

  One field, the anchor, stands without brackets; the fields before it carry
  their separator behind them and those after it in front, each in brackets,
  so a field that is empty for a track leaves the line together with its
  separator. The anchor is the field that is never empty when there is one
  (the album or the artist of a header; the title, the file name, the artist
  or the album of a track), else the first field - then the line can begin
  with a separator, which TidyFormatted takes away.

  FormatToFields reads only texts that FieldsToFormat writes; any other text
  is not a format of this kind.
  =============================================================================}

interface

uses
  Classes, SysUtils;

const
  FMT_SLOTS = 4;
  FMT_SEPARATOR = ' • ';

type
  TFmtKind = (fkHeader, fkTrack);
  TFmtField = (ffNone, ffAlbum, ffArtist, ffYear, ffGenre, ffComposer, ffSpecs, ffTitle, ffFileName);
  TFmtFields = array[0..FMT_SLOTS - 1] of TFmtField;
  TFmtFieldArray = array of TFmtField;

const
  FMT_FIELD_NAMES: array[TFmtField] of string = (
    '(nothing)', 'Album', 'Artist', 'Year', 'Genre', 'Composer', 'Specs', 'Title', 'File name');

  { what a format is when nothing is chosen }
  FMT_DEFAULT: array[TFmtKind] of string = ('%album%', '%title%');

  { the few formats offered in the playlist's View menu }
  FMT_QUICK_HEADER: array[0..3] of string = (
    '%album%',
    '[%first_albumartist% • ]%album%',
    '[%first_albumartist% • ][%year% • ]%album%',
    '[%first_albumartist% • ]%album%[ • %resolution%]');
  FMT_QUICK_TRACK: array[0..3] of string = (
    '%title%',
    '%title%[ • %first_artist%]',
    '[%first_artist% • ]%title%',
    '%title%[ • %resolution%]');

{ the fields a format of this kind can have, in the order they are offered }
function FieldChoices(AKind: TFmtKind): TFmtFieldArray;
{ the fields without the empty places, without a field a second time and
  without fields the kind does not have; the rest is ffNone }
function TidyFields(AKind: TFmtKind; const AFields: TFmtFields): TFmtFields;
{ the format text of these fields; '' when none is chosen }
function FieldsToFormat(AKind: TFmtKind; const AFields: TFmtFields): string;
{ the fields of a format text. False (and no fields) when the text is not
  one FieldsToFormat writes for this kind. }
function FormatToFields(AKind: TFmtKind; const AFmt: string; out AFields: TFmtFields): Boolean;
function IsFieldFormat(AKind: TFmtKind; const AFmt: string): Boolean;
{ "Artist • Year • Album"; '' for a text that is no format of this kind }
function FormatName(AKind: TFmtKind; const AFmt: string): string;
{ a formatted line without a separator at its start or end }
function TidyFormatted(const S: string): string;

implementation

const
  HEADER_CHOICES: array[0..5] of TFmtField = (ffAlbum, ffArtist, ffYear, ffGenre, ffComposer, ffSpecs);
  TRACK_CHOICES: array[0..5] of TFmtField = (ffTitle, ffArtist, ffAlbum, ffComposer, ffSpecs, ffFileName);
  { the fields that are never empty, the best anchor first }
  HEADER_ANCHORS: array[0..1] of TFmtField = (ffAlbum, ffArtist);
  TRACK_ANCHORS: array[0..3] of TFmtField = (ffTitle, ffFileName, ffArtist, ffAlbum);

function FieldChoices(AKind: TFmtKind): TFmtFieldArray;
var
  I: Integer;
begin
  Result := nil;
  if AKind = fkHeader then
  begin
    SetLength(Result, Length(HEADER_CHOICES));
    for I := 0 to High(HEADER_CHOICES) do Result[I] := HEADER_CHOICES[I];
  end
  else
  begin
    SetLength(Result, Length(TRACK_CHOICES));
    for I := 0 to High(TRACK_CHOICES) do Result[I] := TRACK_CHOICES[I];
  end;
end;

{ the tag of the format language that shows a field }
function TagOf(AKind: TFmtKind; AField: TFmtField): string;
begin
  case AField of
    ffAlbum:    Result := 'album';
    ffArtist:   if AKind = fkHeader then Result := 'first_albumartist' else Result := 'first_artist';
    ffYear:     Result := 'year';
    ffGenre:    Result := 'first_genre';
    ffComposer: Result := 'composer';
    ffSpecs:    Result := 'resolution';
    ffTitle:    Result := 'title';
    ffFileName: Result := 'filename';
  else
    Result := '';
  end;
end;

function HasChoice(AKind: TFmtKind; AField: TFmtField): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AKind = fkHeader then
  begin
    for I := 0 to High(HEADER_CHOICES) do
      if HEADER_CHOICES[I] = AField then Exit(True);
  end
  else
    for I := 0 to High(TRACK_CHOICES) do
      if TRACK_CHOICES[I] = AField then Exit(True);
end;

function TidyFields(AKind: TFmtKind; const AFields: TFmtFields): TFmtFields;
var
  I, J, N: Integer;
  Twice: Boolean;
begin
  for I := 0 to FMT_SLOTS - 1 do Result[I] := ffNone;
  N := 0;
  for I := 0 to FMT_SLOTS - 1 do
  begin
    if not HasChoice(AKind, AFields[I]) then Continue;
    Twice := False;
    for J := 0 to N - 1 do
      if Result[J] = AFields[I] then Twice := True;
    if Twice then Continue;
    Result[N] := AFields[I];
    Inc(N);
  end;
end;

{ the place of the field that stands without brackets; -1 without fields }
function AnchorOf(AKind: TFmtKind; const AFields: TFmtFields): Integer;
var
  I, J: Integer;
begin
  if AFields[0] = ffNone then Exit(-1);
  if AKind = fkHeader then
  begin
    for J := 0 to High(HEADER_ANCHORS) do
      for I := 0 to FMT_SLOTS - 1 do
        if AFields[I] = HEADER_ANCHORS[J] then Exit(I);
  end
  else
    for J := 0 to High(TRACK_ANCHORS) do
      for I := 0 to FMT_SLOTS - 1 do
        if AFields[I] = TRACK_ANCHORS[J] then Exit(I);
  Result := 0;
end;

function FieldsToFormat(AKind: TFmtKind; const AFields: TFmtFields): string;
var
  F: TFmtFields;
  I, Anchor: Integer;
  Tag: string;
begin
  Result := '';
  F := TidyFields(AKind, AFields);
  Anchor := AnchorOf(AKind, F);
  if Anchor < 0 then Exit;
  for I := 0 to FMT_SLOTS - 1 do
  begin
    if F[I] = ffNone then Break;
    Tag := '%' + TagOf(AKind, F[I]) + '%';
    if I < Anchor then Result := Result + '[' + Tag + FMT_SEPARATOR + ']'
    else if I = Anchor then Result := Result + Tag
    else Result := Result + '[' + FMT_SEPARATOR + Tag + ']';
  end;
end;

function FormatToFields(AKind: TFmtKind; const AFmt: string; out AFields: TFmtFields): Boolean;
var
  I, P, Q, N: Integer;
  Tag: string;
  F, Found: TFmtField;
  Choices: TFmtFieldArray;
begin
  Result := False;
  for I := 0 to FMT_SLOTS - 1 do AFields[I] := ffNone;
  if AFmt = '' then Exit;
  Choices := FieldChoices(AKind);
  N := 0;
  P := 1;
  { the tags of the text, in their order }
  while P <= Length(AFmt) do
  begin
    if AFmt[P] <> '%' then
    begin
      Inc(P);
      Continue;
    end;
    Q := P + 1;
    while (Q <= Length(AFmt)) and (AFmt[Q] <> '%') do Inc(Q);
    if Q > Length(AFmt) then Break;
    Tag := Copy(AFmt, P + 1, Q - P - 1);
    Found := ffNone;
    for F in Choices do
      if TagOf(AKind, F) = Tag then Found := F;
    if (Found <> ffNone) and (N < FMT_SLOTS) then
    begin
      AFields[N] := Found;
      Inc(N);
    end
    else
      N := FMT_SLOTS + 1;          // an unknown tag or too many
    if N > FMT_SLOTS then Break;
    P := Q + 1;
  end;
  { only the very text these fields are written as }
  Result := (N >= 1) and (N <= FMT_SLOTS) and (FieldsToFormat(AKind, AFields) = AFmt);
  if not Result then
    for I := 0 to FMT_SLOTS - 1 do AFields[I] := ffNone;
end;

function IsFieldFormat(AKind: TFmtKind; const AFmt: string): Boolean;
var
  F: TFmtFields;
begin
  Result := FormatToFields(AKind, AFmt, F);
end;

function FormatName(AKind: TFmtKind; const AFmt: string): string;
var
  F: TFmtFields;
  I: Integer;
begin
  Result := '';
  if not FormatToFields(AKind, AFmt, F) then Exit;
  for I := 0 to FMT_SLOTS - 1 do
    if F[I] <> ffNone then
    begin
      if Result <> '' then Result := Result + FMT_SEPARATOR;
      Result := Result + FMT_FIELD_NAMES[F[I]];
    end;
end;

function TidyFormatted(const S: string): string;
const
  DOT = '•';
var
  Again: Boolean;
begin
  Result := Trim(S);
  repeat
    Again := False;
    if Copy(Result, 1, Length(DOT)) = DOT then
    begin
      Result := Trim(Copy(Result, Length(DOT) + 1, MaxInt));
      Again := True;
    end;
    if (Length(Result) >= Length(DOT)) and
       (Copy(Result, Length(Result) - Length(DOT) + 1, Length(DOT)) = DOT) then
    begin
      Result := Trim(Copy(Result, 1, Length(Result) - Length(DOT)));
      Again := True;
    end;
  until not Again;
end;

end.
