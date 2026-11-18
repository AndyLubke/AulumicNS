unit TestAutoPlaylist;

{$mode ObjFPC}{$H+}
{$codepage UTF8}

{ ==============================================================================
  AulumicNS tests - TestAutoPlaylist
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for uAutoPlaylist:
    TTestAutoPlaylistOrder : SortAutoPlaylistByDate: "added" and "last
                             played" auto-playlists newest first, flat and
                             grouped by album / folder, and when it leaves the
                             list alone; groups with the same date
                             in the library order (accents, numbers)
  Only files in a temporary folder are used.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uAppConsts, uLibraryTypes, uAutoPlaylist;

type
  TTestAutoPlaylistOrder = class(TTestCase)
  private
    FDir   : string;
    FTracks: TTrackList;
    procedure AddTrack(const APath, ATitle, AAlbum: string; ATrackNr: Integer;
      ADateAdded: Int64; const APrimary: string = ''; const AFallback: string = '');
    function  Titles: string;
    function  Sort(const AQuery: string; AGrouping: TGroupingMode;
      out ASuffix: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure QueryWithoutDatesLeavesTheOrder;
    procedure AddedFlatNewestFirst;
    procedure AddedGroupedByAlbumKeepsAlbumsTogether;
    procedure AddedGroupedByFolderKeepsFoldersTogether;
    procedure GroupsWithTheSameDateInLibraryOrder;
    procedure FewerThanTwoTracksAreNotSorted;
    procedure LastPlayedNeedsPlayStatistics;
    procedure LastPlayedUsesThePlayStatistics;
  end;

implementation

uses
  uUserStatsManager, TestHelpers, TestLibraryLogic;

const
  ADDED_QUERY       = '%added% IN LAST 30d';
  LAST_PLAYED_QUERY = '%lastplayed% IN LAST 7d';

{ TTestAutoPlaylistOrder }

procedure TTestAutoPlaylistOrder.SetUp;
begin
  FDir    := CreateTestDir;
  FTracks := TTrackList.Create;
  // Added: A1 100, B1 200, A2 300, D1 250, C1 50. D1 is in A's folder but on
  // another album, and its file name sorts first in that folder.
  AddTrack('D:\M\Alpha\01 - A1.flac', 'A1', 'Alpha', 1, 100, 'fp-a1');
  AddTrack('D:\M\Beta\01 - B1.flac',  'B1', 'Beta',  1, 200, 'fp-b1');
  AddTrack('D:\M\Alpha\02 - A2.flac', 'A2', 'Alpha', 2, 300, 'fp-a2');
  AddTrack('D:\M\Alpha\00 - D1.flac', 'D1', 'Delta', 1, 250, 'fp-d1');
  AddTrack('D:\M\Gamma\01 - C1.flac', 'C1', 'Gamma', 1, 50,  'fp-c1-old', 'fp-c1');
end;

procedure TTestAutoPlaylistOrder.TearDown;
begin
  FTracks.Free;
  RemoveTestDir(FDir);
end;

procedure TTestAutoPlaylistOrder.AddTrack(const APath, ATitle, AAlbum: string;
  ATrackNr: Integer; ADateAdded: Int64; const APrimary: string; const AFallback: string);
var
  T: TTrackInfo;
begin
  T := MakeTrack(APath, ATitle, 'Artist', AAlbum, ATrackNr);
  T.DateAdded           := ADateAdded;
  T.PrimaryFingerprint  := APrimary;
  T.FallbackFingerprint := AFallback;
  FTracks.Add(T);
end;

function TTestAutoPlaylistOrder.Titles: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FTracks.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + FTracks[I]^.Title;
  end;
end;

function TTestAutoPlaylistOrder.Sort(const AQuery: string; AGrouping: TGroupingMode;
  out ASuffix: string): Boolean;
begin
  Result := SortAutoPlaylistByDate(FTracks.List, AQuery, AGrouping, ASuffix);
end;

procedure TTestAutoPlaylistOrder.QueryWithoutDatesLeavesTheOrder;
var
  Suffix: string;
begin
  AssertFalse('Not sorted', Sort('%artist% HAS art', gmFlat, Suffix));
  AssertEquals('No date suffix', '', Suffix);
  AssertEquals('Order unchanged', 'A1,B1,A2,D1,C1', Titles);
end;

procedure TTestAutoPlaylistOrder.AddedFlatNewestFirst;
var
  Suffix: string;
begin
  AssertTrue('Sorted', Sort(ADDED_QUERY, gmFlat, Suffix));
  AssertEquals('Date suffix', '[ (%added%)]', Suffix);
  AssertEquals('Newest first', 'A2,D1,B1,A1,C1', Titles);
end;

procedure TTestAutoPlaylistOrder.AddedGroupedByAlbumKeepsAlbumsTogether;
var
  Suffix: string;
begin
  // Albums by their newest track: Alpha 300, Delta 250, Beta 200, Gamma 50;
  // inside an album in track order
  AssertTrue('Sorted', Sort(ADDED_QUERY, gmAlbum, Suffix));
  AssertEquals('Albums newest first, tracks in order', 'A1,A2,D1,B1,C1', Titles);
end;

procedure TTestAutoPlaylistOrder.AddedGroupedByFolderKeepsFoldersTogether;
var
  Suffix: string;
begin
  // Folder Alpha (A1, A2 and D1) newest 300; in the folder by file name
  AssertTrue('Sorted', Sort(ADDED_QUERY, gmFolder, Suffix));
  AssertEquals('Folders newest first, files in order', 'D1,A1,A2,B1,C1', Titles);
end;

// Groups added at exactly the same time (e.g. by one scan) follow
// the library order: accented names with their letter, numbers by value
// (CompareText would put 'Ánimals' after Z and 'CD10' before 'CD2')
procedure TTestAutoPlaylistOrder.GroupsWithTheSameDateInLibraryOrder;
const
  GROUPINGS: array[0..1] of TGroupingMode = (gmFolder, gmAlbum);
var
  Suffix: string;
  G: Integer;
begin
  for G := Low(GROUPINGS) to High(GROUPINGS) do
  begin
    FTracks.Clear;
    AddTrack('D:\M\Bach\01 - B.flac',    'Bach',    'Bach',    1, 500, 'fp-b');
    AddTrack('D:\M\CD10\01 - C10.flac',  'CD10',    'CD10',    1, 500, 'fp-c10');
    AddTrack('D:\M\Ánimals\01 - A.flac', 'Ánimals', 'Ánimals', 1, 500, 'fp-a');
    AddTrack('D:\M\CD2\01 - C2.flac',    'CD2',     'CD2',     1, 500, 'fp-c2');
    AssertTrue('Sorted', Sort(ADDED_QUERY, GROUPINGS[G], Suffix));
    AssertEquals(Format('Grouping %d: the same date, in library order', [Ord(GROUPINGS[G])]),
      'Ánimals,Bach,CD2,CD10', Titles);
  end;
end;

procedure TTestAutoPlaylistOrder.FewerThanTwoTracksAreNotSorted;
var
  Suffix: string;
  One: TTrackList;
begin
  One := TTrackList.Create;
  try
    One.Add(FTracks[0]^);
    AssertFalse('One track: nothing to sort',
      SortAutoPlaylistByDate(One.List, ADDED_QUERY, gmFlat, Suffix));
    AssertEquals('The date suffix is still given', '[ (%added%)]', Suffix);
  finally
    One.Free;
  end;
end;

procedure TTestAutoPlaylistOrder.LastPlayedNeedsPlayStatistics;
var
  Suffix: string;
begin
  AssertNull('No play statistics in the test program', UserStatsManager);
  AssertFalse('Not sorted', Sort(LAST_PLAYED_QUERY, gmFlat, Suffix));
  AssertEquals('Date suffix', '[ (%lastplayed%)]', Suffix);
  AssertEquals('Order unchanged', 'A1,B1,A2,D1,C1', Titles);
end;

procedure TTestAutoPlaylistOrder.LastPlayedUsesThePlayStatistics;
var
  Stats: TUserStatsManager;
  Suffix: string;
begin
  Stats := TUserStatsManager.Create(FDir + 'UserStats.db');
  UserStatsManager := Stats;
  try
    // B1 30, C1 20 (under its fallback fingerprint), A1 10; A2 and D1 never
    Stats.GetStats('fp-b1')^.LastPlayed := 30;
    Stats.GetStats('fp-c1')^.LastPlayed := 20;
    Stats.GetStats('fp-a1')^.LastPlayed := 10;

    AssertTrue('Sorted', Sort(LAST_PLAYED_QUERY, gmFlat, Suffix));
    AssertEquals('Date suffix', '[ (%lastplayed%)]', Suffix);
    // Never played (0) last, among themselves in file name order
    AssertEquals('Last played first', 'B1,C1,A1,D1,A2', Titles);
  finally
    UserStatsManager := nil;
    Stats.Free;
  end;
end;

initialization
  RegisterTest(TTestAutoPlaylistOrder);

end.
