unit TestOutputRing;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestOutputRing
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The ring between the play thread and the ASIO driver (ALOutputRing): the
  periods come out in the order they went in, also across the end of the
  ring; an empty take is an underrun only when it counts (not while the ring
  plays empty on purpose, TAsioOutput.Drain); the least fill; Clear keeps
  the statistics; a full ring refuses a period. RingPeriodsFor sizes the ring
  by time (three periods would be only 4 ms at 352.8 kHz: dropouts).
  The log lines of the output diagnostics (AuLog: alOutputDropout,
  alOutputStats, packed as TPlayThread.CheckOutputHealth / LogStreamSummary
  pack them).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestOutputRing = class(TTestCase)
  published
    procedure RingPeriodsFollowTheBufferTime;
    procedure PeriodsComeOutInOrderAcrossTheWrap;
    procedure EmptyTakeCountsOnlyWhenAsked;
    procedure FullRingRefusesAPeriod;
    procedure ClearKeepsTheStatistics;
    procedure DropoutLogLineNamesTheTimeInTheTrack;
    procedure StreamSummaryLogLine;
  end;

  { TPeriodFade: the fade-out before a stream is closed in the middle of
    the music (ASIO; see ALOutputRing) }
  TTestPeriodFade = class(TTestCase)
  published
    procedure WithoutStartThePeriodIsUntouched;
    procedure TheLevelGoesDownSmoothlyToNothing;
    procedure TheFadeContinuesAcrossPeriods;
    procedure AfterTheFadeEveryPeriodIsSilent;
    procedure AnEmptyRingEndsTheFade;
  end;

implementation

uses
  ALOutputRing, AuLog;

const
  FULL = 1000000000;      // the level of the test periods (every sample)

procedure FillPeriod(var A: array of LongInt);
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I] := FULL;
end;

{ TTestPeriodFade }

procedure TTestPeriodFade.WithoutStartThePeriodIsUntouched;
var
  F: TPeriodFade;
  A: array[0..199] of LongInt;
  I: Integer;
begin
  F := TPeriodFade.Create;
  try
    FillPeriod(A);
    F.Apply(@A[0], 100, 2);
    AssertFalse('not active', F.Active);
    for I := 0 to High(A) do AssertEquals('sample ' + IntToStr(I), FULL, A[I]);
  finally
    F.Free;
  end;
end;

procedure TTestPeriodFade.TheLevelGoesDownSmoothlyToNothing;
var
  F: TPeriodFade;
  A: array[0..199] of LongInt;
  I: Integer;
begin
  F := TPeriodFade.Create;
  try
    FillPeriod(A);
    F.Start(100);
    F.Apply(@A[0], 100, 2);
    AssertTrue('starts near the full level', A[0] > Round(FULL * 0.99));
    AssertEquals('both channels alike', A[40], A[41]);
    for I := 1 to 99 do
    begin
      AssertTrue('never louder again at frame ' + IntToStr(I), A[I * 2] <= A[(I - 1) * 2]);
      // a raised cosine over 100 frames: no step larger than about 1.6 % of full scale
      AssertTrue('no step at frame ' + IntToStr(I), A[(I - 1) * 2] - A[I * 2] < Round(FULL * 0.017));
    end;
    AssertEquals('ends at nothing', 0, A[198]);
    AssertEquals('ends at nothing (right)', 0, A[199]);
  finally
    F.Free;
  end;
end;

procedure TTestPeriodFade.TheFadeContinuesAcrossPeriods;
var
  F: TPeriodFade;
  A, B: array[0..63] of LongInt;
begin
  F := TPeriodFade.Create;
  try
    FillPeriod(A);
    FillPeriod(B);
    F.Start(64);                 // two periods of 32 frames
    F.Apply(@A[0], 32, 2);
    AssertTrue('half way after the first period', Abs(A[62] - FULL div 2) < FULL div 20);
    AssertEquals('no silence yet', 0, F.SilentFrames);
    F.Apply(@B[0], 32, 2);
    AssertTrue('the second goes on where the first ended', (B[0] < A[62]) and (A[62] - B[0] < FULL div 20));
    AssertEquals('ends at nothing', 0, B[62]);
  finally
    F.Free;
  end;
end;

procedure TTestPeriodFade.AfterTheFadeEveryPeriodIsSilent;
var
  F: TPeriodFade;
  A: array[0..63] of LongInt;
  I: Integer;
begin
  F := TPeriodFade.Create;
  try
    FillPeriod(A);
    F.Start(16);                 // shorter than the period of 32 frames
    F.Apply(@A[0], 32, 2);
    for I := 32 to 63 do AssertEquals('silent after the fade', 0, A[I]);
    AssertEquals('16 silent frames counted', 16, F.SilentFrames);
    FillPeriod(A);
    F.Apply(@A[0], 32, 2);
    for I := 0 to 63 do AssertEquals('the next period is silent', 0, A[I]);
    AssertEquals('48 silent frames counted', 48, F.SilentFrames);
    F.Reset;
    FillPeriod(A);
    F.Apply(@A[0], 32, 2);
    AssertEquals('after Reset untouched again', FULL, A[10]);
  finally
    F.Free;
  end;
end;

procedure TTestPeriodFade.AnEmptyRingEndsTheFade;
var
  F: TPeriodFade;
begin
  F := TPeriodFade.Create;
  try
    F.Silence(32);
    AssertEquals('nothing counted without a fade', 0, F.SilentFrames);
    F.Start(1000);
    F.Silence(32);
    AssertEquals('the silent period counts', 32, F.SilentFrames);
  finally
    F.Free;
  end;
end;

const
  PB = 16;   // bytes per period in these tests

procedure FillPeriod(var B: TBytes; AValue: Byte);
begin
  SetLength(B, PB);
  FillChar(B[0], PB, AValue);
end;

procedure TTestOutputRing.RingPeriodsFollowTheBufferTime;
begin
  { 250 ms at 352.8 kHz: 88200 frames = 172.3 periods of 512 -> 173 + 1 }
  AssertEquals('512 at 352.8 kHz', 174, RingPeriodsFor(512, 352800, 250));
  { a driver's period of 4096 at 352.8 kHz: 21.5 -> 22 + 1 }
  AssertEquals('4096 at 352.8 kHz', 23, RingPeriodsFor(4096, 352800, 250));
  AssertEquals('44.1 kHz', 23, RingPeriodsFor(512, 44100, 250));
  AssertEquals('at least 3', 3, RingPeriodsFor(512, 44100, 1));
  AssertEquals('at most 4096', 4096, RingPeriodsFor(16, 3072000, 1000));
  AssertEquals('no rate', 3, RingPeriodsFor(512, 0, 250));
end;

procedure TTestOutputRing.PeriodsComeOutInOrderAcrossTheWrap;
var
  R: TOutputRing;
  B, Got: TBytes;
  I: Integer;
begin
  R := TOutputRing.Create(PB, 3);
  try
    SetLength(Got, PB);
    for I := 1 to 10 do
    begin
      FillPeriod(B, I);
      AssertTrue('put ' + IntToStr(I), R.Put(@B[0]));
      if I mod 2 = 0 then
      begin
        { two in, two out: the read position wraps several times }
        AssertTrue(R.Take(@Got[0], True));
        AssertEquals('first of the pair', I - 1, Got[0]);
        AssertTrue(R.Take(@Got[0], True));
        AssertEquals('second of the pair', I, Got[PB - 1]);
      end;
    end;
    AssertEquals('empty', 0, R.Fill);
    AssertEquals('no underrun', 0, R.Underruns);
  finally
    R.Free;
  end;
end;

procedure TTestOutputRing.EmptyTakeCountsOnlyWhenAsked;
var
  R: TOutputRing;
  B, Got: TBytes;
begin
  R := TOutputRing.Create(PB, 4);
  try
    SetLength(Got, PB);
    AssertFalse('nothing there', R.Take(@Got[0], False));
    AssertEquals('draining: no underrun', 0, R.Underruns);
    AssertEquals('draining: no fill seen', -1, R.MinFill);
    AssertFalse(R.Take(@Got[0], True));
    AssertEquals('playing: an underrun', 1, R.Underruns);
    FillPeriod(B, 7);
    R.Put(@B[0]);
    R.Put(@B[0]);
    AssertTrue(R.Take(@Got[0], True));
    AssertEquals('the least fill a take found', 0, R.MinFill);
    R.ResetStats;
    AssertTrue(R.Take(@Got[0], True));
    AssertEquals('after ResetStats: one period was there', PB, R.MinFill);
    AssertEquals(0, R.Underruns);
  finally
    R.Free;
  end;
end;

procedure TTestOutputRing.FullRingRefusesAPeriod;
var
  R: TOutputRing;
  B: TBytes;
begin
  R := TOutputRing.Create(PB, 2);
  try
    FillPeriod(B, 1);
    AssertTrue(R.Put(@B[0]));
    AssertTrue(R.Put(@B[0]));
    AssertFalse('full', R.Put(@B[0]));
    AssertEquals(2 * PB, R.Fill);
  finally
    R.Free;
  end;
end;

procedure TTestOutputRing.ClearKeepsTheStatistics;
var
  R: TOutputRing;
  B, Got: TBytes;
begin
  R := TOutputRing.Create(PB, 3);
  try
    SetLength(Got, PB);
    R.Take(@Got[0], True);
    FillPeriod(B, 1);
    R.Put(@B[0]);
    R.Clear;
    AssertEquals('emptied (a seek)', 0, R.Fill);
    AssertEquals('the underrun stays', 1, R.Underruns);
  finally
    R.Free;
  end;
end;

procedure TTestOutputRing.DropoutLogLineNamesTheTimeInTheTrack;
var
  L: TAppLog;
  Line: string;
begin
  L := TAppLog.Create;
  try
    { 3 dropouts, at 83 s }
    L.EngineMessage(Ord(alOutputDropout), PtrInt(Int64(3) or (Int64(83) shl 20)));
    AssertEquals(1, L.Lines.Count);
    Line := L.Lines[0];
    AssertTrue(Line, Pos('[ERROR]', Line) > 0);
    AssertTrue(Line, Pos('Dropout at about 1:23 in the track', Line) > 0);
    AssertTrue(Line, Pos('(3 in this stream)', Line) > 0);
    AssertTrue('an error: the log file is written', L.HasErrors);
  finally
    L.Free;
  end;
end;

procedure TTestOutputRing.StreamSummaryLogLine;
var
  L: TAppLog;
begin
  L := TAppLog.Create;
  try
    { 0 dropouts, 46 ms (+1), 1234 us = 123 x 10 us }
    L.EngineMessage(Ord(alOutputStats), PtrInt(Int64(0) or (Int64(47) shl 20) or (Int64(123) shl 40)));
    AssertTrue(L.Lines[0], Pos('[INFO]', L.Lines[0]) > 0);
    AssertTrue(L.Lines[0], Pos('Stream closed: 0 dropout(s), at least 46 ms buffered ahead, ' +
      'longest buffer fill 1.23 ms.', L.Lines[0]) > 0);
    AssertFalse(L.HasErrors);
    { 2 dropouts, the margin not known }
    L.EngineMessage(Ord(alOutputStats), PtrInt(Int64(2) or (Int64(250) shl 40)));
    AssertTrue(L.Lines[1], Pos('[ERROR]', L.Lines[1]) > 0);
    AssertTrue(L.Lines[1], Pos('2 dropout(s), at least ? buffered ahead, longest buffer fill 2.50 ms', L.Lines[1]) > 0);
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TTestOutputRing);
  RegisterTest(TTestPeriodFade);

end.
