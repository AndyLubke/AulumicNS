unit TestPlaylistPane;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestPlaylistPane
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The playlist pane's texts (TPlaylistPane.BuildTexts): the library's date
  added and the play statistics are looked up only when a format shows them,
  and then once per track (it was twice per track on every rebuild, used or
  not - the larger part of the time an edit of a very large playlist took).
  A format with %added% must still show the date.
  FollowEntry ("Cursor follows playback"): the selection moves to the track
  that starts, and the list scrolls to it only when it was out of sight.
  =============================================================================}

interface

uses
  Classes, SysUtils, Forms, fpcunit, testregistry, uLibraryTypes, AuPlaylistPane, AuGroupList;

type
  TTestPlaylistPane = class(TTestCase)
  private
    FForm: TForm;
    FPane: TPlaylistPane;
    FTracks: TTrackList;
    FLookups: Integer;
    function Lookup(const APath: string; out ATrack: TTrackInfo): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure NoLookupWhenNoFormatShowsDateOrStatistics;
    procedure OneLookupPerTrackWhenTheHeaderShowsTheDate;
    procedure TheDateAddedIsShownInAFlatList;
    procedure TheSelectionFollowsTheTrackThatStarts;
  end;

implementation

uses
  DateUtils, uAppConsts;

const
  ADDED_UNIX = 1500000000;   // 14 Jul 2017

function TTestPlaylistPane.Lookup(const APath: string; out ATrack: TTrackInfo): Boolean;
var
  I: Integer;
begin
  Inc(FLookups);
  ATrack := Default(TTrackInfo);
  for I := 0 to FTracks.Count - 1 do
    if FTracks[I]^.FilePath = APath then
    begin
      ATrack := FTracks[I]^;
      Exit(True);
    end;
  Result := False;
end;

procedure TTestPlaylistPane.SetUp;
var
  I: Integer;
  T: TTrackInfo;
begin
  FForm := TForm.CreateNew(nil);
  FForm.SetBounds(0, 0, 800, 600);
  FPane := TPlaylistPane.Create(FForm);
  FPane.Parent := FForm;
  FPane.SetBounds(0, 0, 800, 600);
  FPane.OnLookup := @Lookup;
  FTracks := TTrackList.Create;
  for I := 1 to 6 do
  begin
    T := Default(TTrackInfo);
    T.FilePath := Format('C:\Music\Album %d\%.2d Track.flac', [(I + 1) div 2, I]);
    T.FolderDir := ExtractFileDir(T.FilePath);
    T.Title := Format('Track %d', [I]);
    T.Artist := 'An Artist';
    T.AlbumArtist := 'An Artist';
    T.Album := Format('Album %d', [(I + 1) div 2]);
    T.TrackNumber := I;
    T.DateAdded := ADDED_UNIX;
    FTracks.Add(T);
  end;
  FLookups := 0;
end;

procedure TTestPlaylistPane.TearDown;
begin
  FreeAndNil(FTracks);
  FreeAndNil(FForm);   // owns the pane
end;

procedure TTestPlaylistPane.NoLookupWhenNoFormatShowsDateOrStatistics;
begin
  FPane.SetView(gmAlbum, '%album% - %albumartist%', '%title%', '', False);
  FPane.AddTracks(FTracks);
  AssertEquals('Entries', 6, FPane.EntryCount);
  AssertEquals('Text from the format', 'Track 3', FPane.Entry(2).TitleText);
  AssertEquals('The library was not asked', 0, FLookups);
end;

procedure TTestPlaylistPane.OneLookupPerTrackWhenTheHeaderShowsTheDate;
begin
  FPane.SetView(gmAlbum, '%album%', '%title%', '  (%added%)', False);
  FPane.AddTracks(FTracks);
  AssertEquals('One lookup per track', 6, FLookups);
  AssertEquals('The tracks of an album list keep their plain text', 'Track 1', FPane.Entry(0).TitleText);
end;

procedure TTestPlaylistPane.TheDateAddedIsShownInAFlatList;
var
  Want: string;
begin
  Want := FormatDateTime('dd mmm yyyy', UnixToDateTime(ADDED_UNIX, False));
  FPane.SetView(gmFlat, '', '%title%', '  (%ADDED%)', False);
  FPane.AddTracks(FTracks);
  AssertEquals('One lookup per track', 6, FLookups);
  AssertTrue('The date is in the text: ' + FPane.Entry(0).TitleText,
    Pos(Want, FPane.Entry(0).TitleText) > 0);
  { a rating shown in the format is found as well }
  FLookups := 0;
  FPane.SetView(gmFlat, '', '%title% %rating%', '', False);
  FPane.Rebuild;
  AssertEquals('The statistics need the lookup too', 6, FLookups);
end;

{ FollowEntry ("Cursor follows playback"): the track is selected; a track in
  view stays where it is, one out of view comes to the middle, a collapsed
  album opens }
procedure TTestPlaylistPane.TheSelectionFollowsTheTrackThatStarts;
var
  I, R, R2, H, Hd, Top0: Integer;
  T: TTrackInfo;
  Rc: TRect;
begin
  FTracks.Clear;
  for I := 1 to 200 do
  begin
    T := Default(TTrackInfo);
    T.FilePath := Format('C:\Music\Album %.2d\%.3d Track.flac', [(I + 9) div 10, I]);
    T.FolderDir := ExtractFileDir(T.FilePath);
    T.Title := Format('Track %d', [I]);
    T.Artist := 'An Artist';
    T.AlbumArtist := 'An Artist';
    T.Album := Format('Album %.2d', [(I + 9) div 10]);
    T.TrackNumber := I;
    FTracks.Add(T);
  end;
  FForm.HandleNeeded;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.AddTracks(FTracks);
  AssertEquals('Entries', 200, FPane.EntryCount);
  { (the pane lays its list out when it is shown; here the list gets a size)
  }
  FPane.List.SetBounds(0, 40, 800, 560);
  FPane.List.HandleNeeded;
  H := FPane.List.ClientHeight;
  AssertTrue('The list has a height', H > 100);

  FPane.FollowEntry(0);
  R := FPane.RowOfEntry(0);
  AssertEquals('The first track is selected', R, FPane.List.FocusedRow);
  AssertTrue('And marked', FPane.List.Selected[R]);
  Top0 := FPane.List.RowRect(R).Top;

  { the next track is in view: nothing scrolls }
  FPane.FollowEntry(1);
  R2 := FPane.RowOfEntry(1);
  AssertEquals('The second track is selected', R2, FPane.List.FocusedRow);
  AssertFalse('The first no longer', FPane.List.Selected[R]);
  AssertEquals('The list did not move', Top0, FPane.List.RowRect(R).Top);

  { a track far down: brought to the middle }
  R := FPane.RowOfEntry(150);
  Rc := FPane.List.RowRect(R);
  AssertTrue('Out of view before', (Rc.Top >= H) or (Rc.Bottom <= 0));
  FPane.FollowEntry(150);
  Rc := FPane.List.RowRect(R);
  AssertEquals('Selected', R, FPane.List.FocusedRow);
  AssertTrue(Format('In the middle of the list (top %d of %d)', [Rc.Top, H]),
    (Rc.Top > H div 4) and (Rc.Bottom < H - H div 4));

  { a track in a collapsed album: the album opens }
  R := FPane.RowOfEntry(15);
  Hd := R;
  while (Hd > 0) and (FPane.List.Kind[Hd] <> rkHeader) do Dec(Hd);
  AssertTrue('Its header', FPane.List.Kind[Hd] = rkHeader);
  FPane.List.Collapsed[Hd] := True;
  AssertFalse('Hidden', FPane.List.IsVisibleRow(R));
  FPane.FollowEntry(15);
  AssertTrue('The album is open again', FPane.List.IsVisibleRow(R));
  AssertEquals('The track is selected', R, FPane.List.FocusedRow);
  Rc := FPane.List.RowRect(R);
  AssertTrue('And in view', (Rc.Top >= 0) and (Rc.Bottom <= H));

  FPane.FollowEntry(-1);       // no such entry: nothing happens
  AssertEquals('Unchanged', R, FPane.List.FocusedRow);
end;

initialization
  RegisterTest(TTestPlaylistPane);

end.
