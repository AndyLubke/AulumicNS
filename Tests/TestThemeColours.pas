unit TestThemeColours;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestThemeColours
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The colour behind selected text in an input field, for every accent in the
  dark and the light theme: it stands out from the field, clearly more than
  the tint that marks a row of a list would, and the text on it stays
  readable.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, AuGfx, AuTheme;

type
  TTestThemeColours = class(TTestCase)
  private
    FMode: TAuThemeMode;
    FAccent: Integer;
    procedure CheckTheme(AMode: TAuThemeMode; const AName: string; AMinOnField: Double);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ContrastIsTheWcagRatio;
    procedure SelectedTextShowsInTheDarkTheme;
    procedure SelectedTextShowsInTheLightTheme;
  end;

implementation

procedure TTestThemeColours.SetUp;
begin
  FMode := ThemeMode;
  FAccent := AccentIndex;
end;

procedure TTestThemeColours.TearDown;
begin
  SetTheme(FMode, FAccent);
end;

procedure TTestThemeColours.ContrastIsTheWcagRatio;
begin
  AssertEquals('Black on white', 21.0, ContrastOf($FF000000, $FFFFFFFF), 0.01);
  AssertEquals('The order does not matter', 21.0, ContrastOf($FFFFFFFF, $FF000000), 0.01);
  AssertEquals('The same colour', 1.0, ContrastOf($FF336699, $FF336699), 0.0001);
end;

procedure TTestThemeColours.CheckTheme(AMode: TAuThemeMode; const AName: string; AMinOnField: Double);
var
  I: Integer;
  Where: string;
begin
  for I := 0 to AccentCount - 1 do
  begin
    SetTheme(AMode, I);
    Where := AName + ', ' + AccentNames[I] + ': ';
    AssertTrue(Where + Format('the selection on the field is %.2f', [ContrastOf(clTextSelection, clInput)]),
      ContrastOf(clTextSelection, clInput) >= AMinOnField);
    AssertTrue(Where + Format('the text on the selection is %.2f', [ContrastOf(clText, clTextSelection)]),
      ContrastOf(clText, clTextSelection) >= 4.5);
    AssertTrue(Where + 'clearer than the tint of a list row',
      ContrastOf(clTextSelection, clInput) > ContrastOf(clSelection, clInput) + 0.3);
  end;
end;

procedure TTestThemeColours.SelectedTextShowsInTheDarkTheme;
begin
  CheckTheme(tmDark, 'dark', 2.0);
end;

procedure TTestThemeColours.SelectedTextShowsInTheLightTheme;
begin
  CheckTheme(tmLight, 'light', 1.7);
end;

initialization
  RegisterTest(TTestThemeColours);

end.