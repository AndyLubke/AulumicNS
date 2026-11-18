unit uAutoPlaylist;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uAutoPlaylist
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Auto-playlists without any UI:
    SortAutoPlaylistByDate   the order of a "last played" / "added"
                             auto-playlist (newest first, grouped like the view)
  Which tracks belong to an auto-playlist is decided by the library
  (TLibraryManager.GetTracksByQuery with uLibraryQuery.EvaluateTrack).
  The auto-playlists themselves are stored in uPlaylistStore.
  Covered by Tests\TestAutoPlaylist.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils, uAppConsts;

// For an auto-playlist whose query uses "last played" (or else "added"):
// orders ATracks (PTrackInfo) newest first and returns True. Grouped by
// album or folder, the groups are ordered by their newest track and keep
// their tracks together (in track order when the dates are equal).
// Groups with the same date are in the library order
// (uLibraryTypes.CompareLibraryNamesNatural).
// ADateSuffix is the header / track format suffix that shows the date
// ('' when the query uses neither). False (ATracks unchanged) when the query
// uses neither, ATracks has fewer than 2 tracks, or "last played" is
// needed without play statistics (UserStatsManager = nil).
function SortAutoPlaylistByDate(ATracks: TList; const AQuery: string;
  AGrouping: TGroupingMode; out ADateSuffix: string): Boolean;

implementation

uses
  uOSUtils, uTagParser, uUserStatsManager, uLibraryTypes, uPlaylistRows;

type
  PAutoSortItem = ^TAutoSortItem;
  TAutoSortItem = record
    Track      : PTrackInfo;
    TrackStamp : Int64;
    GroupStamp : Int64;
    GroupKey   : string;
  end;

function CompareLastPlayed_Flat(Item1, Item2: Pointer): Integer;
var
  A, B: PAutoSortItem;
begin
  A := PAutoSortItem(Item1);
  B := PAutoSortItem(Item2);

  if B^.TrackStamp > A^.TrackStamp then
    Exit(1)
  else if B^.TrackStamp < A^.TrackStamp then
    Exit(-1);

  Result := SmartTrackCompare(A^.Track, B^.Track);
end;

function CompareLastPlayed_Grouped(Item1, Item2: Pointer): Integer;
var
  A, B: PAutoSortItem;
begin
  A := PAutoSortItem(Item1);
  B := PAutoSortItem(Item2);

  if B^.GroupStamp > A^.GroupStamp then
    Exit(1)
  else if B^.GroupStamp < A^.GroupStamp then
    Exit(-1);

  // Groups with the same date in the library order (accents with their
  // letter, numbers by value; CompareText would put 'Ánimals' after Z)
  Result := CompareLibraryNamesNatural(A^.GroupKey, B^.GroupKey);
  if Result <> 0 then
    Exit;

  Result := SmartTrackCompare(A^.Track, B^.Track);
end;

function SortAutoPlaylistByDate(ATracks: TList; const AQuery: string;
  AGrouping: TGroupingMode; out ADateSuffix: string): Boolean;
var
  Conds         : TQueryConditionArray;
  HasLastPlayed : Boolean;
  HasAdded      : Boolean;
  I, Idx        : Integer;
  TInfo         : PTrackInfo;
  Stats         : PUserTrackStats;
  Stamp         : Int64;
  GKey          : string;
  GroupMaxMap   : TStringList;
  SortItems     : TList;
  Item          : PAutoSortItem;
begin
  Result        := False;
  ADateSuffix   := '';
  HasLastPlayed := False;
  HasAdded      := False;

  Conds := ParseQuery(AQuery);
  for I := 0 to High(Conds) do
  begin
    if Conds[I].TagID = tiLastPlayed then
      HasLastPlayed := True
    else if Conds[I].TagID = tiAdded then
      HasAdded := True;
  end;

  if HasLastPlayed then
    ADateSuffix := '[ (%lastplayed%)]'
  else if HasAdded then
    ADateSuffix := '[ (%added%)]'
  else
    Exit;

  if (not Assigned(ATracks)) or (ATracks.Count <= 1) then
    Exit;

  if HasLastPlayed and (not Assigned(UserStatsManager)) then
    Exit;

  GroupMaxMap               := TStringList.Create;
  GroupMaxMap.Sorted        := True;
  GroupMaxMap.CaseSensitive := False;
  // Internal lookup only: plain (non-locale) comparison. The locale
  // comparison would take seconds for a large library.
  GroupMaxMap.UseLocale     := False;
  SortItems                 := TList.Create;
  try
    SortItems.Capacity := ATracks.Count;

    for I := 0 to ATracks.Count - 1 do
    begin
      TInfo := PTrackInfo(ATracks[I]);
      Stamp := 0;

      if HasLastPlayed then
      begin
        Stats := UserStatsManager.PeekStats(TInfo^.PrimaryFingerprint);
        if (not Assigned(Stats)) and (TInfo^.FallbackFingerprint <> '') then
          Stats := UserStatsManager.PeekStats(TInfo^.FallbackFingerprint);
        if Assigned(Stats) then
          Stamp := Stats^.LastPlayed;
      end
      else if HasAdded then
      begin
        Stamp := TInfo^.DateAdded;
      end;

      // The playlist's own group key (uPlaylistRows),
      // so the date order keeps exactly the groups the view shows
      GKey := PlaylistGroupKey(TInfo^, AGrouping);

      New(Item);
      Item^.Track      := TInfo;
      Item^.TrackStamp := Stamp;
      Item^.GroupStamp := Stamp;
      Item^.GroupKey   := GKey;
      SortItems.Add(Item);

      if AGrouping <> gmFlat then
      begin
        Idx := GroupMaxMap.IndexOf(GKey);
        if Idx < 0 then
          GroupMaxMap.AddObject(GKey, TObject(PtrInt(Stamp)))
        else if Stamp > PtrInt(GroupMaxMap.Objects[Idx]) then
          GroupMaxMap.Objects[Idx] := TObject(PtrInt(Stamp));
      end;
    end;

    if AGrouping <> gmFlat then
    begin
      for I := 0 to SortItems.Count - 1 do
      begin
        Item := PAutoSortItem(SortItems[I]);
        Idx  := GroupMaxMap.IndexOf(Item^.GroupKey);
        if Idx >= 0 then
          Item^.GroupStamp := PtrInt(GroupMaxMap.Objects[Idx]);
      end;
      SortItems.Sort(@CompareLastPlayed_Grouped);
    end
    else
    begin
      SortItems.Sort(@CompareLastPlayed_Flat);
    end;

    for I := 0 to SortItems.Count - 1 do
      ATracks[I] := PAutoSortItem(SortItems[I])^.Track;

    Result := True;
  finally
    for I := 0 to SortItems.Count - 1 do
      Dispose(PAutoSortItem(SortItems[I]));
    SortItems.Free;
    GroupMaxMap.Free;
  end;
end;

end.
