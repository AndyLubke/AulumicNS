{ =============================================================================
  AulumicNS tests - TestStartTimes
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The line the log gets about the start: the whole time is the last mark, and
  each part is the time since the mark before it.
  =============================================================================}
unit TestStartTimes;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uStartTimes;

type
  TTestStartTimes = class(TTestCase)
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheReportSaysTheWholeAndTheParts;
    procedure TheProcessHasBeenRunningForAMoment;
  end;

implementation

procedure TTestStartTimes.SetUp;
begin
  ClearStartMarks;
end;

procedure TTestStartTimes.TearDown;
begin
  ClearStartMarks;
end;

procedure TTestStartTimes.TheReportSaysTheWholeAndTheParts;
begin
  AssertEquals('nothing noted: nothing to say', '', StartReport);
  StartMarkAt('loading the program', 40);
  StartMarkAt('library', 370);
  StartMarkAt('first picture', 640);
  AssertEquals('Window on screen after 640 ms (loading the program 40, library 330, first picture 270)',
    StartReport);
end;

procedure TTestStartTimes.TheProcessHasBeenRunningForAMoment;
var
  A, B: Integer;
begin
  A := MsSinceProcessStart;
  AssertTrue('a time since the process began', A > 0);
  AssertTrue('and not a wild one', A < 3600000);
  Sleep(30);
  B := MsSinceProcessStart;
  AssertTrue('it goes on', B >= A + 15);
end;

initialization
  RegisterTest(TTestStartTimes);

end.