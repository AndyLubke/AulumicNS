unit uTonePresets;

{ ==============================================================================
  AulumicNS - uTonePresets
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The presets of the tone control: named settings of the five bands (gain and
  frequency of each, and the width of the three middle ones). A preset does
  not hold the on / off switch.

  The list is kept in the order the presets were saved. Names are compared
  without regard to case; "Flat" and "Custom" are what the Tone Control shows
  for all bands at 0 dB and for a setting that is no preset, so they cannot
  be the name of one. One preset is one line of text in the settings file:
  the gains, the frequencies, the widths and the name, separated by
  semicolons - the name last, so it may hold any character.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, LazUTF8, ALAudioTypes;

const
  TONE_PRESET_MAX      = 40;    // presets in the list
  TONE_PRESET_NAME_MAX = 40;    // characters of a name
  TONE_PRESET_FLAT     = 'Flat';
  TONE_PRESET_CUSTOM   = 'Custom';

type
  TTonePreset = record
    Name: string;
    Db, Hz: TToneInts;          // tenths of a dB; Hz
    Width: TToneInts;           // TONE_WIDTH_*; 0 for the two shelves
  end;
  TTonePresets = array of TTonePreset;

{ a name as it is kept: no control characters, no spaces at the ends, at most
  TONE_PRESET_NAME_MAX characters }
function CleanPresetName(const S: string): string;
{ not empty and not one of the two names the program uses itself }
function TonePresetNameAllowed(const AName: string): Boolean;

function TonePresetToText(const P: TTonePreset): string;
{ False when the text is no preset (numbers missing, no name); the gains and
  the widths come back inside their ranges, the frequencies as written }
function TonePresetFromText(const S: string; out P: TTonePreset): Boolean;

{ the bands of a setting under a name, and the bands of a preset put into a
  setting (its on / off switch stays) }
function TonePresetOf(const AName: string; const S: TToneState): TTonePreset;
procedure ApplyTonePreset(const P: TTonePreset; var S: TToneState);

{ all gains at 0 dB: that is Flat, which is no preset (a setting cannot be
  both) - such a preset is not kept }
function TonePresetIsFlat(const P: TTonePreset): Boolean;

{ the index of the preset with this name, or -1 }
function FindTonePreset(const L: TTonePresets; const AName: string): Integer;
{ the first preset with the gains, frequencies and widths of this setting,
  or -1 - also for a setting with all gains at 0 dB, which is Flat }
function MatchTonePreset(const L: TTonePresets; const S: TToneState): Integer;

{ takes the place of the preset with the same name, or goes to the end;
  the index, or -1 when the name is not allowed, the preset is flat or the
  list is full }
function PutTonePreset(var L: TTonePresets; const P: TTonePreset): Integer;
procedure DeleteTonePreset(var L: TTonePresets; AIndex: Integer);
{ False when the name is not allowed or another preset has it }
function RenameTonePreset(var L: TTonePresets; AIndex: Integer; const ANewName: string): Boolean;
{ drops what cannot be kept: names that are not allowed, a name a second
  time, everything past TONE_PRESET_MAX; brings the gains and the widths into
  their ranges }
procedure SanitizeTonePresets(var L: TTonePresets);

implementation

function CleanPresetName(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] < ' ' then Result[I] := ' ';
  Result := Trim(Result);
  if UTF8Length(Result) > TONE_PRESET_NAME_MAX then
    Result := Trim(UTF8Copy(Result, 1, TONE_PRESET_NAME_MAX));
end;

function SameName(const A, B: string): Boolean;
begin
  Result := UTF8CompareText(A, B) = 0;
end;

function TonePresetNameAllowed(const AName: string): Boolean;
begin
  Result := (AName <> '') and (AName = CleanPresetName(AName)) and
    not SameName(AName, TONE_PRESET_FLAT) and not SameName(AName, TONE_PRESET_CUSTOM);
end;

function IntsToText(const A: TToneInts): string;
var
  B: Integer;
begin
  Result := '';
  for B := 0 to TONE_BANDS - 1 do
  begin
    if B > 0 then Result := Result + ',';
    Result := Result + IntToStr(A[B]);
  end;
end;

{ exactly TONE_BANDS whole numbers, separated by commas }
function TextToInts(const S: string; out A: TToneInts): Boolean;
var
  B, P, Start: Integer;
  Part: string;
begin
  Result := False;
  for B := 0 to TONE_BANDS - 1 do A[B] := 0;
  Start := 1;
  for B := 0 to TONE_BANDS - 1 do
  begin
    P := Start;
    while (P <= Length(S)) and (S[P] <> ',') do Inc(P);
    Part := Trim(Copy(S, Start, P - Start));
    if not TryStrToInt(Part, A[B]) then Exit;
    if (B < TONE_BANDS - 1) and (P > Length(S)) then Exit;   // too few
    if (B = TONE_BANDS - 1) and (P <= Length(S)) then Exit;  // too many
    Start := P + 1;
  end;
  Result := True;
end;

function TonePresetToText(const P: TTonePreset): string;
begin
  Result := IntsToText(P.Db) + ';' + IntsToText(P.Hz) + ';' + IntsToText(P.Width) + ';' + P.Name;
end;

{ gains and widths as the tone control takes them }
procedure BringIntoRange(var P: TTonePreset);
var
  B: Integer;
begin
  for B := 0 to TONE_BANDS - 1 do
  begin
    P.Db[B] := EnsureRange(P.Db[B], VAL_MIN_TONE_GAIN, VAL_MAX_TONE_GAIN);
    if (P.Width[B] < 0) or (P.Width[B] > TONE_WIDTH_MAX) or (B = 0) or (B = TONE_BANDS - 1) then
      P.Width[B] := TONE_WIDTH_NORMAL;
  end;
end;

function TonePresetFromText(const S: string; out P: TTonePreset): Boolean;
var
  P1, P2, P3: Integer;
begin
  Result := False;
  P := Default(TTonePreset);
  P1 := Pos(';', S);
  if P1 = 0 then Exit;
  P2 := P1 + 1;
  while (P2 <= Length(S)) and (S[P2] <> ';') do Inc(P2);
  if P2 > Length(S) then Exit;
  P3 := P2 + 1;
  while (P3 <= Length(S)) and (S[P3] <> ';') do Inc(P3);
  if P3 > Length(S) then Exit;
  if not TextToInts(Copy(S, 1, P1 - 1), P.Db) then Exit;
  if not TextToInts(Copy(S, P1 + 1, P2 - P1 - 1), P.Hz) then Exit;
  if not TextToInts(Copy(S, P2 + 1, P3 - P2 - 1), P.Width) then Exit;
  P.Name := CleanPresetName(Copy(S, P3 + 1, MaxInt));
  if P.Name = '' then Exit;
  BringIntoRange(P);
  Result := True;
end;

function TonePresetOf(const AName: string; const S: TToneState): TTonePreset;
begin
  Result.Name := AName;
  Result.Db := ToneGainsOf(S);
  Result.Hz := ToneFreqsOf(S);
  Result.Width := ToneWidthsOf(S);
end;

procedure ApplyTonePreset(const P: TTonePreset; var S: TToneState);
begin
  SetToneGains(S, P.Db);
  SetToneFreqs(S, P.Hz);
  SetToneWidths(S, P.Width);
end;

function TonePresetIsFlat(const P: TTonePreset): Boolean;
var
  B: Integer;
begin
  Result := True;
  for B := 0 to TONE_BANDS - 1 do
    if P.Db[B] <> 0 then Exit(False);
end;

function FindTonePreset(const L: TTonePresets; const AName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(L) do
    if SameName(L[I].Name, AName) then Exit(I);
end;

function MatchTonePreset(const L: TTonePresets; const S: TToneState): Integer;
var
  I, B: Integer;
  Db, Hz, Wd: TToneInts;
  Same: Boolean;
begin
  Result := -1;
  if not ToneAnyGain(S) then Exit;
  Db := ToneGainsOf(S);
  Hz := ToneFreqsOf(S);
  Wd := ToneWidthsOf(S);
  for I := 0 to High(L) do
  begin
    Same := True;
    for B := 0 to TONE_BANDS - 1 do
      if (L[I].Db[B] <> Db[B]) or (L[I].Hz[B] <> Hz[B]) or (L[I].Width[B] <> Wd[B]) then Same := False;
    if Same then Exit(I);
  end;
end;

function PutTonePreset(var L: TTonePresets; const P: TTonePreset): Integer;
begin
  Result := -1;
  if not TonePresetNameAllowed(P.Name) or TonePresetIsFlat(P) then Exit;
  Result := FindTonePreset(L, P.Name);
  if Result < 0 then
  begin
    if Length(L) >= TONE_PRESET_MAX then Exit;
    SetLength(L, Length(L) + 1);
    Result := High(L);
  end;
  L[Result] := P;
end;

procedure DeleteTonePreset(var L: TTonePresets; AIndex: Integer);
var
  I: Integer;
begin
  if (AIndex < 0) or (AIndex > High(L)) then Exit;
  for I := AIndex to High(L) - 1 do L[I] := L[I + 1];
  SetLength(L, Length(L) - 1);
end;

function RenameTonePreset(var L: TTonePresets; AIndex: Integer; const ANewName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (AIndex < 0) or (AIndex > High(L)) then Exit;
  if not TonePresetNameAllowed(ANewName) then Exit;
  I := FindTonePreset(L, ANewName);
  if (I >= 0) and (I <> AIndex) then Exit;
  L[AIndex].Name := ANewName;
  Result := True;
end;

procedure SanitizeTonePresets(var L: TTonePresets);
var
  Kept: TTonePresets;
  I: Integer;
  P: TTonePreset;
begin
  Kept := nil;
  for I := 0 to High(L) do
  begin
    P := L[I];
    P.Name := CleanPresetName(P.Name);
    if not TonePresetNameAllowed(P.Name) then Continue;
    if FindTonePreset(Kept, P.Name) >= 0 then Continue;
    if TonePresetIsFlat(P) then Continue;
    if Length(Kept) >= TONE_PRESET_MAX then Break;
    BringIntoRange(P);
    SetLength(Kept, Length(Kept) + 1);
    Kept[High(Kept)] := P;
  end;
  L := Kept;
end;

end.
