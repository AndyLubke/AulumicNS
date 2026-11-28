unit uStartTimes;

{ ==============================================================================
  AulumicNS - uStartTimes
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  How long the program takes to start: the time since Windows created the
  process is noted at a few points of the start (StartMark), and when the main
  window is on the screen StartReport says what it came to and how the time
  was spent. One line in the log; nothing is measured afterwards.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

{ milliseconds since Windows created this process }
function MsSinceProcessStart: Integer;
{ the point of the start that has just been reached }
procedure StartMark(const AName: string);
{ the same with a given time (tests) }
procedure StartMarkAt(const AName: string; AMs: Integer);
{ "Window on screen after 640 ms (loading the program 45, library 330 ...)":
  the last mark is the whole time, each part is the time since the mark
  before it; '' without marks }
function StartReport: string;
procedure ClearStartMarks;

implementation

var
  Names: array of string;
  Times: array of Integer;

function FileTimeMs(const T: TFileTime): QWord;
begin
  Result := ((QWord(T.dwHighDateTime) shl 32) or T.dwLowDateTime) div 10000;
end;

function MsSinceProcessStart: Integer;
var
  Created, Ended, Kernel, User, Now_: TFileTime;
  A, B: QWord;
begin
  Result := 0;
  Created := Default(TFileTime);
  Ended := Default(TFileTime);
  Kernel := Default(TFileTime);
  User := Default(TFileTime);
  Now_ := Default(TFileTime);
  if not GetProcessTimes(GetCurrentProcess, Created, Ended, Kernel, User) then Exit;
  GetSystemTimeAsFileTime(Now_);
  A := FileTimeMs(Created);
  B := FileTimeMs(Now_);
  if (B > A) and (B - A < 3600000) then Result := Integer(B - A);
end;

procedure StartMarkAt(const AName: string; AMs: Integer);
begin
  { a clock set back during the start: no part of it gets a negative time }
  if (Length(Times) > 0) and (AMs < Times[High(Times)]) then AMs := Times[High(Times)];
  SetLength(Names, Length(Names) + 1);
  SetLength(Times, Length(Names));
  Names[High(Names)] := AName;
  Times[High(Times)] := AMs;
end;

procedure StartMark(const AName: string);
begin
  StartMarkAt(AName, MsSinceProcessStart);
end;

procedure ClearStartMarks;
begin
  Names := nil;
  Times := nil;
end;

function StartReport: string;
var
  I, Prev: Integer;
  Parts: string;
begin
  Result := '';
  if Length(Names) = 0 then Exit;
  Parts := '';
  Prev := 0;
  for I := 0 to High(Names) do
  begin
    if Parts <> '' then Parts := Parts + ', ';
    Parts := Parts + Names[I] + ' ' + IntToStr(Times[I] - Prev);
    Prev := Times[I];
  end;
  Result := Format('Window on screen after %d ms (%s)', [Times[High(Times)], Parts]);
end;

end.