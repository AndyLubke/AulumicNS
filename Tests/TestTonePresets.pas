unit TestTonePresets;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestTonePresets
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The presets of the tone control (uTonePresets): a preset as one line of
  text and back, with any character in its name; lines that are no preset
  (also a line without the widths of the middle bands);
  names (trimmed, cut, compared without case, "Flat" and "Custom" refused);
  the list (put, replace, rename, delete, the limit, the clean-up after
  loading); which preset a setting of the bands matches, and that a preset
  leaves the on / off switch alone; that a setting with all gains at 0 dB is
  Flat and never a preset.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, ALAudioTypes, uTonePresets;

type
  TTestTonePresets = class(TTestCase)
  private
    function Sample(const AName: string; ABass: Integer): TTonePreset;
  published
    procedure APresetSurvivesTheTextForm;
    procedure ANameMayHoldSeparators;
    procedure WhatIsNoPresetIsRefused;
    procedure GainsOutOfRangeAreBroughtIn;
    procedure NamesAreTrimmedAndCut;
    procedure TheProgramsOwnNamesAreRefused;
    procedure PutAddsAndReplacesByName;
    procedure TheListHasALimit;
    procedure RenameRefusesATakenName;
    procedure DeleteRemovesOne;
    procedure ASettingMatchesItsPreset;
    procedure APresetLeavesTheSwitchAlone;
    procedure TheCleanUpDropsWhatCannotBeKept;
    procedure AllBandsAtZeroIsFlatAndNoPreset;
  end;

implementation

function TTestTonePresets.Sample(const AName: string; ABass: Integer): TTonePreset;
const
  HZ: TToneInts = (120, 400, 1000, 4000, 10000);
begin
  Result := Default(TTonePreset);
  Result.Name := AName;
  Result.Hz := HZ;
  Result.Db[0] := ABass;
  Result.Db[3] := 15;
  Result.Db[4] := -15;
  Result.Width[1] := TONE_WIDTH_NARROW;
  Result.Width[3] := TONE_WIDTH_WIDE;
end;

procedure TTestTonePresets.APresetSurvivesTheTextForm;
var
  P, Q: TTonePreset;
  B: Integer;
begin
  P := Sample('Late night', 30);
  AssertEquals('30,0,0,15,-15;120,400,1000,4000,10000;0,1,0,2,0;Late night', TonePresetToText(P));
  AssertTrue(TonePresetFromText(TonePresetToText(P), Q));
  AssertEquals('Late night', Q.Name);
  for B := 0 to TONE_BANDS - 1 do
  begin
    AssertEquals('gain ' + IntToStr(B), P.Db[B], Q.Db[B]);
    AssertEquals('frequency ' + IntToStr(B), P.Hz[B], Q.Hz[B]);
    AssertEquals('width ' + IntToStr(B), P.Width[B], Q.Width[B]);
  end;
end;

procedure TTestTonePresets.ANameMayHoldSeparators;
var
  Q: TTonePreset;
begin
  AssertTrue(TonePresetFromText(TonePresetToText(Sample('Room; left, right = 3', 10)), Q));
  AssertEquals('Room; left, right = 3', Q.Name);
  AssertTrue(TonePresetFromText(TonePresetToText(Sample('Küche für Ärzte', 10)), Q));
  AssertEquals('Küche für Ärzte', Q.Name);
end;

procedure TTestTonePresets.WhatIsNoPresetIsRefused;
var
  Q: TTonePreset;
begin
  AssertFalse('empty', TonePresetFromText('', Q));
  AssertFalse('no name', TonePresetFromText('0,0,0,0,0;120,400,1000,4000,10000;0,0,0,0,0;', Q));
  AssertFalse('name of spaces', TonePresetFromText('0,0,0,0,0;120,400,1000,4000,10000;0,0,0,0,0;   ', Q));
  AssertFalse('four gains', TonePresetFromText('0,0,0,0;120,400,1000,4000,10000;0,0,0,0,0;A', Q));
  AssertFalse('six gains', TonePresetFromText('0,0,0,0,0,0;120,400,1000,4000,10000;0,0,0,0,0;A', Q));
  AssertFalse('a word as a gain', TonePresetFromText('0,x,0,0,0;120,400,1000,4000,10000;0,0,0,0,0;A', Q));
  AssertFalse('no frequencies', TonePresetFromText('0,0,0,0,0;A', Q));
  AssertFalse('only a name', TonePresetFromText('A', Q));
  AssertFalse('no widths', TonePresetFromText('0,0,0,0,0;120,400,1000,4000,10000;A', Q));
  AssertFalse('four widths', TonePresetFromText('0,0,0,0,0;120,400,1000,4000,10000;0,0,0,0;A', Q));
end;

procedure TTestTonePresets.GainsOutOfRangeAreBroughtIn;
var
  Q: TTonePreset;
begin
  AssertTrue(TonePresetFromText('900,-900,0,0,0;120,400,1000,4000,10000;0,0,0,0,0;A', Q));
  AssertEquals(VAL_MAX_TONE_GAIN, Q.Db[0]);
  AssertEquals(VAL_MIN_TONE_GAIN, Q.Db[1]);
  { a width that is no choice, and one on a shelf, are the normal width }
  AssertTrue(TonePresetFromText('0,0,0,0,0;120,400,1000,4000,10000;2,9,-1,2,1;A', Q));
  AssertEquals('bass shelf', TONE_WIDTH_NORMAL, Q.Width[0]);
  AssertEquals(TONE_WIDTH_NORMAL, Q.Width[1]);
  AssertEquals(TONE_WIDTH_NORMAL, Q.Width[2]);
  AssertEquals(TONE_WIDTH_WIDE, Q.Width[3]);
  AssertEquals('treble shelf', TONE_WIDTH_NORMAL, Q.Width[4]);
end;

procedure TTestTonePresets.NamesAreTrimmedAndCut;
var
  Long: string;
begin
  AssertEquals('Late night', CleanPresetName('  Late night  '));
  AssertEquals('A B', CleanPresetName('A'#9'B'));
  AssertEquals('', CleanPresetName(' '#13#10' '));
  Long := StringOfChar('x', TONE_PRESET_NAME_MAX + 20);
  AssertEquals(TONE_PRESET_NAME_MAX, Length(CleanPresetName(Long)));
  { cut by characters, not bytes: no half character at the end }
  Long := '';
  while Length(Long) < 3 * TONE_PRESET_NAME_MAX do Long := Long + 'ü';
  AssertEquals(2 * TONE_PRESET_NAME_MAX, Length(CleanPresetName(Long)));
end;

procedure TTestTonePresets.TheProgramsOwnNamesAreRefused;
begin
  AssertFalse(TonePresetNameAllowed(''));
  AssertFalse(TonePresetNameAllowed('Flat'));
  AssertFalse(TonePresetNameAllowed('flat'));
  AssertFalse(TonePresetNameAllowed('CUSTOM'));
  AssertFalse('not cleaned', TonePresetNameAllowed(' A '));
  AssertTrue(TonePresetNameAllowed('Flat for headphones'));
end;

procedure TTestTonePresets.PutAddsAndReplacesByName;
var
  L: TTonePresets;
begin
  L := nil;
  AssertEquals(0, PutTonePreset(L, Sample('One', 10)));
  AssertEquals(1, PutTonePreset(L, Sample('Two', 20)));
  AssertEquals('same name, other case: replaced', 0, PutTonePreset(L, Sample('ONE', 30)));
  AssertEquals(2, Length(L));
  AssertEquals(30, L[0].Db[0]);
  AssertEquals('ONE', L[0].Name);
  AssertEquals('a name of the program', -1, PutTonePreset(L, Sample('Flat', 30)));
  AssertEquals(2, Length(L));
  AssertEquals(1, FindTonePreset(L, 'two'));
  AssertEquals(-1, FindTonePreset(L, 'Three'));
end;

procedure TTestTonePresets.TheListHasALimit;
var
  L: TTonePresets;
  I: Integer;
begin
  L := nil;
  for I := 1 to TONE_PRESET_MAX do
    AssertEquals(I - 1, PutTonePreset(L, Sample('P' + IntToStr(I), I)));
  AssertEquals('full', -1, PutTonePreset(L, Sample('One more', 1)));
  AssertEquals('replacing still works', 4, PutTonePreset(L, Sample('p5', 50)));
  AssertEquals(TONE_PRESET_MAX, Length(L));
end;

procedure TTestTonePresets.RenameRefusesATakenName;
var
  L: TTonePresets;
begin
  L := nil;
  PutTonePreset(L, Sample('One', 10));
  PutTonePreset(L, Sample('Two', 20));
  AssertFalse('taken', RenameTonePreset(L, 0, 'two'));
  AssertFalse('the program''s', RenameTonePreset(L, 0, 'Custom'));
  AssertFalse('empty', RenameTonePreset(L, 0, ''));
  AssertFalse('no such preset', RenameTonePreset(L, 2, 'Three'));
  AssertTrue('its own name in another case', RenameTonePreset(L, 0, 'ONE'));
  AssertTrue(RenameTonePreset(L, 1, 'Three'));
  AssertEquals('ONE', L[0].Name);
  AssertEquals('Three', L[1].Name);
  AssertEquals(20, L[1].Db[0]);
end;

procedure TTestTonePresets.DeleteRemovesOne;
var
  L: TTonePresets;
begin
  L := nil;
  PutTonePreset(L, Sample('One', 10));
  PutTonePreset(L, Sample('Two', 20));
  PutTonePreset(L, Sample('Three', 30));
  DeleteTonePreset(L, 1);
  AssertEquals(2, Length(L));
  AssertEquals('One', L[0].Name);
  AssertEquals('Three', L[1].Name);
  DeleteTonePreset(L, 5);
  DeleteTonePreset(L, -1);
  AssertEquals(2, Length(L));
end;

procedure TTestTonePresets.ASettingMatchesItsPreset;
var
  L: TTonePresets;
  S: TToneState;
begin
  L := nil;
  PutTonePreset(L, Sample('One', 10));
  PutTonePreset(L, Sample('Two', 20));
  S := Default(TToneState);
  ApplyTonePreset(L[1], S);
  AssertEquals(1, MatchTonePreset(L, S));
  S.MidDB := 5;
  AssertEquals('a gain moved', -1, MatchTonePreset(L, S));
  S.MidDB := 0;
  S.TrebleHz := 8000;
  AssertEquals('a frequency changed', -1, MatchTonePreset(L, S));
  S.TrebleHz := 10000;
  AssertEquals(1, MatchTonePreset(L, S));
  AssertEquals('the widths came with the preset', TONE_WIDTH_NARROW, S.LowMidWidth);
  AssertEquals(TONE_WIDTH_WIDE, S.HighMidWidth);
  S.MidWidth := TONE_WIDTH_WIDE;
  AssertEquals('a width changed', -1, MatchTonePreset(L, S));
  AssertEquals(TONE_WIDTH_WIDE, TonePresetOf('Two', S).Width[2]);
  S.TrebleHz := 8000;
  AssertEquals('the bands under a name', 'Two', TonePresetOf('Two', S).Name);
  AssertEquals(8000, TonePresetOf('Two', S).Hz[4]);
end;

procedure TTestTonePresets.APresetLeavesTheSwitchAlone;
var
  S: TToneState;
begin
  S := Default(TToneState);
  S.DirectMode := True;
  ApplyTonePreset(Sample('One', 10), S);
  AssertTrue(S.DirectMode);
  AssertEquals(10, S.BassDB);
  AssertEquals(10000, S.TrebleHz);
  S.DirectMode := False;
  ApplyTonePreset(Sample('Two', 20), S);
  AssertFalse(S.DirectMode);
end;

procedure TTestTonePresets.TheCleanUpDropsWhatCannotBeKept;
var
  L: TTonePresets;
  I: Integer;
begin
  L := nil;
  SetLength(L, TONE_PRESET_MAX + 6);
  L[0] := Sample('  One  ', 10);
  L[1] := Sample('one', 20);            // the name a second time
  L[2] := Sample('Flat', 30);
  L[3] := Sample('', 40);
  L[4] := Sample('Loud', 5000);
  for I := 5 to High(L) do L[I] := Sample('P' + IntToStr(I), I);
  SanitizeTonePresets(L);
  AssertEquals(TONE_PRESET_MAX, Length(L));
  AssertEquals('One', L[0].Name);
  AssertEquals(10, L[0].Db[0]);
  AssertEquals('Loud', L[1].Name);
  AssertEquals(VAL_MAX_TONE_GAIN, L[1].Db[0]);
  AssertEquals('P5', L[2].Name);
end;

{ a flat setting saved as a preset would take Flat's place in the window:
  it is not saved, not kept after loading and never matched }
procedure TTestTonePresets.AllBandsAtZeroIsFlatAndNoPreset;
var
  L: TTonePresets;
  Flat: TTonePreset;
  S: TToneState;
begin
  Flat := Sample('Test', 0);
  Flat.Db[3] := 0;
  Flat.Db[4] := 0;
  AssertTrue(TonePresetIsFlat(Flat));
  AssertFalse(TonePresetIsFlat(Sample('One', 10)));
  L := nil;
  AssertEquals('not saved', -1, PutTonePreset(L, Flat));
  AssertEquals(0, Length(L));
  SetLength(L, 2);
  L[0] := Flat;
  L[1] := Sample('One', 10);
  S := Default(TToneState);
  ApplyTonePreset(Flat, S);
  AssertEquals('a flat setting matches no preset', -1, MatchTonePreset(L, S));
  SanitizeTonePresets(L);
  AssertEquals('not kept', 1, Length(L));
  AssertEquals('One', L[0].Name);
end;

initialization
  RegisterTest(TTestTonePresets);
end.
