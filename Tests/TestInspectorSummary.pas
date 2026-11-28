unit TestInspectorSummary;

{ ==============================================================================
  AulumicNS tests - TestInspectorSummary
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Inspector's summary of several tracks (uInspectorSummary): totals,
  one value against several values with their counts, the limit of named
  values, folders, tracks the library does not know, the play statistics.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, fpcunit, testregistry, uInspectorSummary;

type
  TTestInspectorSummary = class(TTestCase)
  private
    function Item(const AFile, AGenre: string; ASeconds: Integer): TInspectorItem;
    procedure Has(const AText, APart: string);
    procedure HasNot(const AText, APart: string);
  published
    procedure Durations;
    procedure Sizes;
    procedure NoTracksNoText;
    procedure TotalsAndSharedValues;
    procedure DifferentValuesWithTheirCounts;
    procedure OnlyTheMostFrequentValuesAreNamed;
    procedure AnEmptyValueIsNamed;
    procedure SeveralFoldersAreListed;
    procedure TracksOutsideTheLibrary;
    procedure ReplayGainOfSomeTracks;
    procedure DateAddedAsARange;
    procedure PlayStatistics;
    procedure WithoutPlayStatistics;
  end;

implementation

uses
  uAppStrings;

function TTestInspectorSummary.Item(const AFile, AGenre: string; ASeconds: Integer): TInspectorItem;
begin
  Result := Default(TInspectorItem);
  Result.FilePath := AFile;
  Result.FormatName := 'FLAC';
  Result.InLibrary := True;
  Result.FileSize := 10 * 1024 * 1024;
  Result.Seconds := ASeconds;
  Result.SampleRate := 44100;
  Result.BitDepth := 16;
  Result.AlbumArtist := 'An Artist';
  Result.Album := 'An Album';
  Result.Year := '1999';
  Result.Genre := AGenre;
end;

procedure TTestInspectorSummary.Has(const AText, APart: string);
begin
  AssertTrue('"' + APart + '" is missing in:' + LineEnding + AText, Pos(APart, AText) > 0);
end;

procedure TTestInspectorSummary.HasNot(const AText, APart: string);
begin
  AssertTrue('"' + APart + '" must not be in:' + LineEnding + AText, Pos(APart, AText) = 0);
end;

procedure TTestInspectorSummary.Durations;
begin
  AssertEquals('0:00', SecondsToDuration(0));
  AssertEquals('0:59', SecondsToDuration(59));
  AssertEquals('59:59', SecondsToDuration(3599));
  AssertEquals('1:00:00', SecondsToDuration(3600));
  AssertEquals('27:46:39', SecondsToDuration(99999));
  AssertEquals('A negative time', '0:00', SecondsToDuration(-5));
end;

procedure TTestInspectorSummary.Sizes;
begin
  AssertEquals(Format(FMT_SIZE_MB, [1.5]), InspectorSizeText(1024 * 1024 + 512 * 1024));
  AssertEquals(Format(FMT_SIZE_MB, [1023.0]), InspectorSizeText(Int64(1023) * 1024 * 1024));
  AssertEquals(Format(FMT_SIZE_GB, [2.0]), InspectorSizeText(Int64(2048) * 1024 * 1024));
end;

procedure TTestInspectorSummary.NoTracksNoText;
begin
  AssertEquals('', InspectorSummary(nil, True));
end;

procedure TTestInspectorSummary.TotalsAndSharedValues;
var
  A: TInspectorItems;
  S: string;
begin
  A := nil;
  SetLength(A, 3);
  A[0] := Item('C:\M\Album\01.flac', 'Jazz', 200);
  A[1] := Item('C:\M\Album\02.flac', 'Jazz', 3500);
  A[2] := Item('C:\M\Album\03.flac', 'Jazz', 100);
  S := InspectorSummary(A, True);
  Has(S, INS_LBL_TRACKS_SELECTED + '3');
  Has(S, INS_LBL_TOTAL_TIME + '1:03:20');
  Has(S, INS_LBL_TOTAL_FILE_SIZE + Format(FMT_SIZE_MB, [30.0]));
  Has(S, INS_LBL_FORMAT + 'FLAC' + LineEnding);
  Has(S, INS_LBL_SAMPLE_RATE + '44100 Hz' + LineEnding);
  Has(S, INS_LBL_BIT_DEPTH + '16-bit' + LineEnding);
  Has(S, INS_LBL_FOLDER_PATH + 'C:\M\Album' + LineEnding);
  Has(S, INS_LBL_ALBUM_ARTIST + 'An Artist' + LineEnding);
  Has(S, INS_LBL_ALBUM + 'An Album' + LineEnding);
  Has(S, INS_LBL_YEAR + '1999' + LineEnding);
  Has(S, INS_LBL_GENRE + 'Jazz' + LineEnding);
  HasNot(S, INS_LBL_NOT_IN_LIBRARY);
  HasNot(S, INS_LBL_FOLDERS);
end;

procedure TTestInspectorSummary.DifferentValuesWithTheirCounts;
var
  A: TInspectorItems;
  S: string;
begin
  A := nil;
  SetLength(A, 4);
  A[0] := Item('C:\M\A\01.flac', 'Blues', 60);
  A[1] := Item('C:\M\A\02.flac', 'Jazz', 60);
  A[2] := Item('C:\M\A\03.flac', 'Jazz', 60);
  A[3] := Item('C:\M\A\04.dsf', 'Jazz', 60);
  A[3].FormatName := 'DSF';
  A[3].SampleRate := 2822400;
  A[3].BitDepth := 1;
  S := InspectorSummary(A, False);
  Has(S, INS_LBL_GENRE + 'Jazz (3), Blues (1)' + LineEnding);
  Has(S, INS_LBL_FORMAT + 'FLAC (3), DSF (1)' + LineEnding);
  Has(S, INS_LBL_SAMPLE_RATE + '44100 Hz (3), 2822400 Hz (1)' + LineEnding);
  Has(S, INS_LBL_BIT_DEPTH + '16-bit (3), 1-bit (1)' + LineEnding);
end;

{ the most frequent first; values with the same count in the order seen }
procedure TTestInspectorSummary.OnlyTheMostFrequentValuesAreNamed;
const
  GENRES: array[0..7] of string = ('A', 'B', 'C', 'C', 'D', 'E', 'F', 'G');
var
  A: TInspectorItems;
  I: Integer;
begin
  A := nil;
  SetLength(A, Length(GENRES));
  for I := 0 to High(GENRES) do A[I] := Item(Format('C:\M\A\%.2d.flac', [I]), GENRES[I], 60);
  Has(InspectorSummary(A, False), INS_LBL_GENRE + 'C (2), A (1), B (1), D (1), and 3 more' + LineEnding);
end;

procedure TTestInspectorSummary.AnEmptyValueIsNamed;
var
  A: TInspectorItems;
begin
  A := nil;
  SetLength(A, 3);
  A[0] := Item('C:\M\A\01.flac', 'Jazz', 60);
  A[1] := Item('C:\M\A\02.flac', '  ', 60);
  A[2] := Item('C:\M\A\03.flac', 'Jazz', 60);
  Has(InspectorSummary(A, False), INS_LBL_GENRE + 'Jazz (2), ' + INS_VAL_EMPTY + ' (1)' + LineEnding);
end;

procedure TTestInspectorSummary.SeveralFoldersAreListed;
var
  A: TInspectorItems;
  S: string;
  I: Integer;
begin
  A := nil;
  SetLength(A, 3);
  A[0] := Item('C:\M\CD1\01.flac', 'Jazz', 60);
  A[1] := Item('C:\M\CD2\01.flac', 'Jazz', 60);
  A[2] := Item('C:\M\CD2\02.flac', 'Jazz', 60);
  S := InspectorSummary(A, False);
  Has(S, INS_LBL_FOLDERS + '2' + LineEnding + '  C:\M\CD2 (2)' + LineEnding + '  C:\M\CD1 (1)' + LineEnding);
  HasNot(S, INS_LBL_FOLDER_PATH);

  SetLength(A, 7);
  for I := 0 to 6 do A[I] := Item(Format('C:\M\CD%d\01.flac', [I + 1]), 'Jazz', 60);
  S := InspectorSummary(A, False);
  Has(S, INS_LBL_FOLDERS + '7' + LineEnding);
  Has(S, '  C:\M\CD4 (1)' + LineEnding + '  and 3 more' + LineEnding);
  HasNot(S, 'C:\M\CD5');
end;

{ a file the library does not know has no size, length or rate: it is
  counted, and left out of those numbers }
procedure TTestInspectorSummary.TracksOutsideTheLibrary;
var
  A: TInspectorItems;
  S: string;
begin
  A := nil;
  SetLength(A, 2);
  A[0] := Item('C:\M\A\01.flac', 'Jazz', 90);
  A[1] := Item('C:\M\A\02.flac', 'Jazz', 0);
  A[1].InLibrary := False;
  A[1].FileSize := 0;
  A[1].SampleRate := 0;
  A[1].BitDepth := 0;
  S := InspectorSummary(A, False);
  Has(S, INS_LBL_TRACKS_SELECTED + '2' + LineEnding + INS_LBL_NOT_IN_LIBRARY + '1' + LineEnding);
  Has(S, INS_LBL_TOTAL_TIME + '1:30');
  Has(S, INS_LBL_TOTAL_FILE_SIZE + Format(FMT_SIZE_MB, [10.0]));
  Has(S, INS_LBL_SAMPLE_RATE + '44100 Hz' + LineEnding);
  Has(S, INS_LBL_REPLAYGAIN + INS_VAL_NO_TRACK);

  A[0].InLibrary := False;
  S := InspectorSummary(A, False);
  Has(S, INS_LBL_NOT_IN_LIBRARY + '2');
  HasNot(S, INS_LBL_TOTAL_TIME);
  HasNot(S, INS_LBL_TOTAL_FILE_SIZE);
  HasNot(S, INS_LBL_SAMPLE_RATE);
  HasNot(S, INS_LBL_REPLAYGAIN);
  Has(S, INS_LBL_ALBUM + 'An Album');
end;

procedure TTestInspectorSummary.ReplayGainOfSomeTracks;
var
  A: TInspectorItems;
begin
  A := nil;
  SetLength(A, 3);
  A[0] := Item('C:\M\A\01.flac', 'Jazz', 60);
  A[1] := Item('C:\M\A\02.flac', 'Jazz', 60);
  A[2] := Item('C:\M\A\03.flac', 'Jazz', 60);
  Has(InspectorSummary(A, False), INS_LBL_REPLAYGAIN + INS_VAL_NO_TRACK);
  A[0].HasReplayGain := True;
  A[2].HasReplayGain := True;
  Has(InspectorSummary(A, False), INS_LBL_REPLAYGAIN + Format(FMT_INS_OF_TRACKS, [2, 3]));
  A[1].HasReplayGain := True;
  Has(InspectorSummary(A, False), INS_LBL_REPLAYGAIN + INS_VAL_ALL_TRACKS);
end;

procedure TTestInspectorSummary.DateAddedAsARange;
var
  A: TInspectorItems;
  T1, T2: Int64;
  S: string;
begin
  T1 := DateTimeToUnix(EncodeDate(2026, 3, 3) + 0.5, False);
  T2 := DateTimeToUnix(EncodeDate(2026, 5, 12) + 0.5, False);
  A := nil;
  SetLength(A, 3);
  A[0] := Item('C:\M\A\01.flac', 'Jazz', 60);
  A[1] := Item('C:\M\A\02.flac', 'Jazz', 60);
  A[2] := Item('C:\M\A\03.flac', 'Jazz', 60);
  HasNot(InspectorSummary(A, False), INS_LBL_DATE_ADDED);
  A[0].DateAdded := T2;
  A[2].DateAdded := T1;
  S := InspectorSummary(A, False);
  Has(S, INS_LBL_DATE_ADDED + Format(FMT_INS_DATE_RANGE,
    [DateToStr(EncodeDate(2026, 3, 3)), DateToStr(EncodeDate(2026, 5, 12))]) + LineEnding);
  A[0].DateAdded := T1 + 60;
  Has(InspectorSummary(A, False), INS_LBL_DATE_ADDED + DateToStr(EncodeDate(2026, 3, 3)) + LineEnding);
end;

procedure TTestInspectorSummary.PlayStatistics;
var
  A: TInspectorItems;
  S: string;
  T: Int64;
begin
  A := nil;
  SetLength(A, 4);
  A[0] := Item('C:\M\A\01.flac', 'Jazz', 60);
  A[1] := Item('C:\M\A\02.flac', 'Jazz', 60);
  A[2] := Item('C:\M\A\03.flac', 'Jazz', 60);
  A[3] := Item('C:\M\A\04.flac', 'Jazz', 60);
  S := InspectorSummary(A, True);
  Has(S, INS_LBL_PLAY_COUNT + Format(FMT_INS_PLAYS, [0]) + LineEnding);
  Has(S, INS_LBL_LAST_PLAYED + LBL_NEVER);
  Has(S, INS_LBL_RATING + INS_VAL_NOT_RATED);
  HasNot(S, INS_LBL_FAVOURITES);

  T := DateTimeToUnix(EncodeDate(2026, 11, 21) + 0.75, False);
  A[0].PlayCount := 30;
  A[0].LastPlayed := T - 86400;
  A[0].Rating := 5;
  A[0].Favourite := True;
  A[1].PlayCount := 7;
  A[1].LastPlayed := T;
  A[1].Rating := 4;
  S := InspectorSummary(A, True);
  Has(S, INS_LBL_PLAY_COUNT + Format(FMT_INS_PLAYS, [37]) + Format(FMT_INS_NEVER_PLAYED, [2]) + LineEnding);
  Has(S, INS_LBL_LAST_PLAYED + DateTimeToStr(UnixToDateTime(T, False)));
  Has(S, INS_LBL_RATING + Format(FMT_INS_RATED, [2, 4, 4.5]));
  Has(S, INS_LBL_FAVOURITES + '1');
end;

procedure TTestInspectorSummary.WithoutPlayStatistics;
var
  A: TInspectorItems;
  S: string;
begin
  A := nil;
  SetLength(A, 2);
  A[0] := Item('C:\M\A\01.flac', 'Jazz', 60);
  A[1] := Item('C:\M\A\02.flac', 'Jazz', 60);
  S := InspectorSummary(A, False);
  HasNot(S, INS_HDR_USER_STATS);
  HasNot(S, INS_LBL_PLAY_COUNT);
  Has(S, INS_HDR_TAGS);
end;

initialization
  RegisterTest(TTestInspectorSummary);

end.
