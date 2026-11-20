unit TestMetaNames;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestMetaNames
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The names of a track (uMetaUtils): SplitTags cuts a tag with several
  entries at semicolons, and at commas and "featuring" words only outside
  brackets (the comma only in a tag without semicolons); SplitNameRole takes
  the role out of the bracket behind a name; AddPeople lists each person
  once and joins the roles.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uMetaUtils;

type
  TTestMetaNames = class(TTestCase)
  private
    function Joined(const ARaw: string): string;
    function PeopleText(const APeople: TPersonArray): string;
  published
    procedure SemicolonsSeparate;
    procedure ACommaInsideBracketsStays;
    procedure ACommaSeparatesOnlyWithoutSemicolons;
    procedure FeaturingSeparatesOnlyOutsideBrackets;
    procedure AnOpenBracketDoesNotSwallowTheRest;
    procedure EmptyEntriesAreLeftOut;
    procedure TheRoleIsTheLastBracket;
    procedure ANameWithoutARoleStaysWhole;
    procedure APersonIsListedOnceWithAllRoles;
    procedure NamesThatOnlyContainAnotherStayApart;
    procedure OnlyPerformersHaveRoles;
  end;

implementation

function TTestMetaNames.Joined(const ARaw: string): string;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := '';
  Parts := SplitTags(ARaw);
  for I := 0 to High(Parts) do
  begin
    if I > 0 then Result := Result + '|';
    Result := Result + Parts[I];
  end;
end;

function TTestMetaNames.PeopleText(const APeople: TPersonArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(APeople) do
  begin
    if I > 0 then Result := Result + '|';
    Result := Result + APeople[I].Name;
    if APeople[I].Roles <> '' then Result := Result + '=' + APeople[I].Roles;
  end;
end;

procedure TTestMetaNames.SemicolonsSeparate;
begin
  AssertEquals('Minimal|Classical|Audiophile', Joined('Minimal; Classical; Audiophile'));
  AssertEquals('no space', 'A|B', Joined('A;B'));
end;

procedure TTestMetaNames.ACommaInsideBracketsStays;
begin
  AssertEquals('Yang Bao (piano, synthesizer)|Jeeihn Kim (violin)|Licheng (Mark) Chen (violin)',
    Joined('Yang Bao (piano, synthesizer); Jeeihn Kim (violin); Licheng (Mark) Chen (violin)'));
  AssertEquals('without semicolons', 'Yang Bao (piano, synthesizer)|Jeeihn Kim (violin)',
    Joined('Yang Bao (piano, synthesizer), Jeeihn Kim (violin)'));
  AssertEquals('square brackets', 'A [x, y]|B', Joined('A [x, y], B'));
end;

procedure TTestMetaNames.ACommaSeparatesOnlyWithoutSemicolons;
begin
  AssertEquals('Rock|Pop', Joined('Rock, Pop'));
  AssertEquals('Bach, Johann Sebastian|Gould, Glenn', Joined('Bach, Johann Sebastian; Gould, Glenn'));
  AssertEquals('a comma without a space is part of the entry', '10,000 Maniacs', Joined('10,000 Maniacs'));
end;

procedure TTestMetaNames.FeaturingSeparatesOnlyOutsideBrackets;
begin
  AssertEquals('Alpha|Beta', Joined('Alpha feat. Beta'));
  AssertEquals('any case', 'Alpha|Beta', Joined('Alpha FEAT. Beta'));
  AssertEquals('Alpha (feat. Beta)', Joined('Alpha (feat. Beta)'));
end;

procedure TTestMetaNames.AnOpenBracketDoesNotSwallowTheRest;
begin
  AssertEquals('Alpha (piano|Beta|Gamma', Joined('Alpha (piano; Beta; Gamma'));
  AssertEquals('a closing bracket without an opening one', 'Sunn O)))|Beta', Joined('Sunn O))), Beta'));
end;

procedure TTestMetaNames.EmptyEntriesAreLeftOut;
begin
  AssertEquals('', Joined(''));
  AssertEquals('', Joined('  ;  ; '));
  AssertEquals('A|B', Joined(' A ;; B ; '));
end;

procedure TTestMetaNames.TheRoleIsTheLastBracket;
var
  N, R: string;
begin
  SplitNameRole('Jeeihn Kim (violin)', N, R);
  AssertEquals('Jeeihn Kim', N);
  AssertEquals('violin', R);
  SplitNameRole('Licheng (Mark) Chen (violin)', N, R);
  AssertEquals('Licheng (Mark) Chen', N);
  AssertEquals('violin', R);
  SplitNameRole('  Yang Bao [piano, synthesizer] ', N, R);
  AssertEquals('Yang Bao', N);
  AssertEquals('piano, synthesizer', R);
  SplitNameRole('Alpha (conductor (guest))', N, R);
  AssertEquals('Alpha', N);
  AssertEquals('conductor (guest)', R);
end;

procedure TTestMetaNames.ANameWithoutARoleStaysWhole;
var
  N, R: string;
begin
  SplitNameRole('Licheng (Mark) Chen', N, R);
  AssertEquals('Licheng (Mark) Chen', N);
  AssertEquals('', R);
  SplitNameRole('Sunn O)))', N, R);
  AssertEquals('Sunn O)))', N);
  AssertEquals('', R);
  SplitNameRole('(untitled)', N, R);
  AssertEquals('nothing before the bracket', '(untitled)', N);
  AssertEquals('', R);
  SplitNameRole('', N, R);
  AssertEquals('', N);
  AssertEquals('', R);
end;

procedure TTestMetaNames.APersonIsListedOnceWithAllRoles;
var
  P: TPersonArray;
begin
  P := nil;
  AddPeople(P, 'Yang Bao', False);
  AddPeople(P, 'Yang Bao', False);
  AddPeople(P, 'Yang Bao (piano, synthesizer); Jeeihn Kim (violin); Licheng (Mark) Chen (violin)', True);
  AddPeople(P, 'yang bao (Piano); Jeeihn Kim (viola)', True);
  AddPeople(P, 'Yang Bao; Clara Stone', False, ROLE_COMPOSER);
  AssertEquals('Yang Bao=piano, synthesizer, composer|Jeeihn Kim=violin, viola|Licheng (Mark) Chen=violin|' +
    'Clara Stone=composer', PeopleText(P));
end;

procedure TTestMetaNames.NamesThatOnlyContainAnotherStayApart;
var
  P: TPersonArray;
begin
  P := nil;
  AddPeople(P, 'Miles Davis', False);
  AddPeople(P, 'Miles Davis Quintet; Davis', True);
  AssertEquals('Miles Davis|Miles Davis Quintet|Davis', PeopleText(P));
end;

procedure TTestMetaNames.OnlyPerformersHaveRoles;
var
  P: TPersonArray;
begin
  { an artist tag keeps a bracket as part of the name }
  P := nil;
  AddPeople(P, 'Alpha (The Band)', False);
  AddPeople(P, 'Alpha (The Band)', True);
  AssertEquals('Alpha (The Band)|Alpha=The Band', PeopleText(P));
end;

initialization
  RegisterTest(TTestMetaNames);

end.
