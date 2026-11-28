unit TestPlaylistPane;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestPlaylistPane
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The playlist pane's texts (TPlaylistPane.BuildTexts): the library's date
  added and the play statistics are looked up only when a format shows them,
  and then once per track (a lookup per track on every rebuild, used or
  not, would be the larger part of the time an edit of a very large
  playlist takes).
  A format with %added% must still show the date.
  FollowEntry ("Cursor follows playback"): the selection moves to the track
  that starts, and the list scrolls to it only when it was out of sight.
  =============================================================================}

interface

uses
  Classes, SysUtils, Forms, fpcunit, testregistry, uLibraryTypes, uPlaylistFile, AuPlaylistPane, AuGroupList;

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
    procedure TheHeaderStaysPinnedWhileItsTracksScroll;
    procedure DiscsGetAHeadingAndGuestsTheirName;
    procedure WorksGetAHeadingAndShortTitles;
    procedure ASortedViewKeepsTheOrderAdded;
    procedure EveryClosedAlbumIsRemembered;
    procedure AFlatListHasColumnsAndSortsByThem;
    procedure TheSelectionSurvivesTagsReadAgain;
    procedure TheSelectionSurvivesANewOrderOfTheSort;
    procedure OneCopyOfAFileStaysOneCopy;
    procedure ARowHiddenInAClosedAlbumIsNotSelected;
    procedure ALongTotalReadsInDaysAndHours;
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
  { the date is a column of its own, the title column is the plain title }
  AssertTrue('The column is shown', pcAdded in FPane.ShownColumns);
  AssertEquals('The date added', Want, FPane.ColumnText(0, pcAdded));
  AssertEquals('The plain title', 'Track 1', FPane.Entry(0).TitleText);
  { a flat list has no track format: no lookup for what it would show }
  FLookups := 0;
  FPane.SetView(gmFlat, '', '%title% %rating%', '', False);
  FPane.Rebuild;
  AssertEquals('The format is not used', 0, FLookups);
  AssertEquals('The plain title', 'Track 1', FPane.Entry(0).TitleText);
  { a column of the play statistics needs the lookup }
  FPane.ToggleColumn(pcPlays);
  AssertEquals('One lookup per track for the column', 6, FLookups);
end;

{ FollowEntry ("Cursor follows playback"): the track is selected; a track in
  view stays where it is, one out of view comes to the middle, a collapsed
  album opens }
{ what Properties and F5 do: the tags of the entries again from the library }
procedure TTestPlaylistPane.TheSelectionSurvivesTagsReadAgain;
var
  I, R1, R2, RHead, Scroll: Integer;
  T: TTrackInfo;
  Kept: TPlSelection;
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
  FPane.List.SetBounds(0, 40, 800, 560);
  FPane.List.HandleNeeded;

  { two tracks and the header of another album selected, the focus on the
    second track, the list scrolled so that they are in its middle }
  R1 := FPane.RowOfEntry(101);
  R2 := FPane.RowOfEntry(103);
  RHead := FPane.List.Group[FPane.RowOfEntry(120)];
  AssertTrue('a header row', (RHead >= 0) and (FPane.List.Kind[RHead] = rkHeader));
  FPane.List.SelectOnly(R1);
  FPane.List.RestoreSelection(TAuRowArray.Create(R1, R2, RHead), R2);
  FPane.List.ScrollTo(FPane.List.RowRect(R1).Top + FPane.List.ScrollOffset - 150);
  Scroll := FPane.List.ScrollOffset;
  AssertTrue('scrolled', Scroll > 0);
  AssertEquals(3, FPane.List.SelCount);

  { a title was edited }
  FTracks[103]^.Title := 'A new title';
  FPane.SyncWithLibrary;

  AssertEquals('the new title is shown', 'A new title', FPane.Entry(103).Title);
  AssertEquals('three rows selected again', 3, FPane.List.SelCount);
  AssertTrue('the first track', FPane.List.Selected[FPane.RowOfEntry(101)]);
  AssertTrue('the second track', FPane.List.Selected[FPane.RowOfEntry(103)]);
  AssertTrue('the header', FPane.List.Selected[FPane.List.Group[FPane.RowOfEntry(120)]]);
  AssertEquals('the focus where it was', FPane.RowOfEntry(103), FPane.List.FocusedRow);
  AssertEquals('scrolled as before', Scroll, FPane.List.ScrollOffset);

  { an album tag edited: the track gets a group of its own, the rows below
    move, the selection goes with them }
  FTracks[101]^.Album := 'Another album';
  FPane.SyncWithLibrary;
  AssertEquals(3, FPane.List.SelCount);
  AssertTrue('the track in its new group', FPane.List.Selected[FPane.RowOfEntry(101)]);
  AssertTrue(FPane.List.Selected[FPane.RowOfEntry(103)]);
  AssertEquals(FPane.RowOfEntry(103), FPane.List.FocusedRow);

  { the list loaded again (an auto-playlist after its query ran again): the
    entries are new ones, the rows are known by their files }
  Scroll := FPane.List.ScrollOffset;
  Kept := FPane.TakeSelection;
  AssertEquals(2, Length(Kept.Items));
  AssertEquals(1, Length(Kept.Heads));
  FPane.Clear;
  AssertEquals(0, FPane.List.SelCount);
  FPane.AddTracks(FTracks);
  AssertEquals('all three rows again', 3, FPane.PutSelection(Kept));
  AssertEquals(3, FPane.List.SelCount);
  AssertTrue(FPane.List.Selected[FPane.RowOfEntry(101)]);
  AssertTrue(FPane.List.Selected[FPane.RowOfEntry(103)]);
  AssertTrue('the header', FPane.List.Selected[FPane.List.Group[FPane.RowOfEntry(120)]]);
  AssertEquals(FPane.RowOfEntry(103), FPane.List.FocusedRow);
  AssertEquals('scrolled as before', Scroll, FPane.List.ScrollOffset);

  { nothing of it left in the list: the list is left alone }
  FPane.Clear;
  AssertEquals(0, FPane.PutSelection(Kept));
end;

{ a sorted playlist whose tags were edited: the entries change places, the
  selection stays on its track }
procedure TTestPlaylistPane.TheSelectionSurvivesANewOrderOfTheSort;
const
  ARTISTS: array[1..3] of string = ('Cee', 'Bee', 'Dee');
var
  I, E: Integer;
  Path: string;

  function EntryOf(const APath: string): Integer;
  var
    K: Integer;
  begin
    Result := -1;
    for K := 0 to FPane.EntryCount - 1 do
      if FPane.Entry(K).FilePath = APath then Exit(K);
  end;

begin
  for I := 0 to 5 do
  begin
    FTracks[I]^.Artist := ARTISTS[I div 2 + 1];
    FTracks[I]^.AlbumArtist := ARTISTS[I div 2 + 1];
  end;
  FForm.HandleNeeded;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psArtist);
  FPane.AddTracks(FTracks);
  Path := FTracks[0]^.FilePath;
  E := EntryOf(Path);
  AssertEquals('sorted by artist: Bee comes first', 2, E);
  FPane.List.SelectOnly(FPane.RowOfEntry(E));

  { its album artist now sorts before the others }
  FTracks[0]^.AlbumArtist := 'Ay';
  FTracks[0]^.Artist := 'Ay';
  FTracks[1]^.AlbumArtist := 'Ay';
  FTracks[1]^.Artist := 'Ay';
  FPane.SyncWithLibrary;

  E := EntryOf(Path);
  AssertEquals('the album moved to the top', 0, E);
  AssertEquals('one row selected', 1, FPane.List.SelCount);
  AssertTrue('the same track', FPane.List.Selected[FPane.RowOfEntry(E)]);
  AssertEquals('the focus on it', FPane.RowOfEntry(E), FPane.List.FocusedRow);
end;

{ a file that is in the playlist twice: the copy that was selected is selected
  again, not both }
procedure TTestPlaylistPane.OneCopyOfAFileStaysOneCopy;
var
  Kept: TPlSelection;
begin
  FForm.HandleNeeded;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.AddTracks(FTracks);
  FPane.AddTracks(FTracks);
  AssertEquals(12, FPane.EntryCount);
  FPane.List.SelectOnly(FPane.RowOfEntry(7));
  Kept := FPane.TakeSelection;
  FPane.Clear;
  FPane.AddTracks(FTracks);
  FPane.AddTracks(FTracks);
  AssertEquals('one row found', 1, FPane.PutSelection(Kept));
  AssertEquals(1, FPane.List.SelCount);
  AssertTrue('the second copy', FPane.List.Selected[FPane.RowOfEntry(7)]);
  AssertFalse('not the first', FPane.List.Selected[FPane.RowOfEntry(1)]);

  { the first copy is known by its file alone }
  FPane.List.SelectOnly(FPane.RowOfEntry(1));
  Kept := FPane.TakeSelection;
  AssertEquals(FTracks[1]^.FilePath, Kept.Items[0]);
  FPane.List.SelectOnly(FPane.RowOfEntry(4));
  AssertEquals(1, FPane.PutSelection(Kept));
  AssertTrue(FPane.List.Selected[FPane.RowOfEntry(1)]);
  AssertFalse(FPane.List.Selected[FPane.RowOfEntry(7)]);
end;

{ a selection put back into a list where the track's album is closed: nothing
  that cannot be seen is selected, the focus is on the album's header }
{ the totals of the status line: m:ss below an hour, hours and minutes below
  a day, days and hours from there on - rounded, never with seconds; a count
  with the thousands separator of the regional settings }
procedure TTestPlaylistPane.ALongTotalReadsInDaysAndHours;
var
  Sep: Char;
begin
  AssertEquals('47:17', FormatLongDuration(47 * 60 + 17));
  AssertEquals('59:59', FormatLongDuration(3599));
  AssertEquals('1 h 00 min', FormatLongDuration(3600));
  AssertEquals('1 h 22 min', FormatLongDuration(3600 + 21 * 60 + 55));
  AssertEquals('16 h 05 min', FormatLongDuration(16 * 3600 + 5 * 60 + 10));
  AssertEquals('the last half minute of a day', '1 day 0 h', FormatLongDuration(86400 - 20));
  AssertEquals('1 day 3 h', FormatLongDuration(86400 + 3 * 3600 + 100));
  AssertEquals('172 days 22 h', FormatLongDuration(Int64(4150) * 3600 + 3 * 60 + 11));
  AssertEquals('nothing below zero', '0:00', FormatLongDuration(-5));
  Sep := DefaultFormatSettings.ThousandSeparator;
  AssertEquals('46' + Sep + '745', FormatCount(46745));
  AssertEquals('999', FormatCount(999));
end;

procedure TTestPlaylistPane.ARowHiddenInAClosedAlbumIsNotSelected;
var
  Kept: TPlSelection;
  Head: Integer;
begin
  FForm.HandleNeeded;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.AddTracks(FTracks);
  FPane.List.SelectOnly(FPane.RowOfEntry(2));
  Kept := FPane.TakeSelection;
  FPane.List.SelectOnly(FPane.RowOfEntry(5));
  Head := FPane.List.Group[FPane.RowOfEntry(2)];
  FPane.List.Collapsed[Head] := True;
  AssertEquals('no row was put back', 0, FPane.PutSelection(Kept));
  AssertEquals('nothing hidden is selected', 0, FPane.List.SelCount);
  AssertEquals('the focus on the header', Head, FPane.List.FocusedRow);
end;

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

{ A group's header stays at the top while its tracks scroll under it, takes
  the mouse there, is pushed out by the next header, and a track never ends
  up hidden under it }
procedure TTestPlaylistPane.TheHeaderStaysPinnedWhileItsTracksScroll;
var
  I, Hd, Hd2, First, Third, HH, Y2: Integer;
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
  FPane.List.SetBounds(0, 40, 800, 560);
  FPane.List.HandleNeeded;
  Hd := 0;
  AssertTrue('Row 0 is the first header', FPane.List.Kind[Hd] = rkHeader);
  First := FPane.RowOfEntry(0);
  Third := FPane.RowOfEntry(2);
  Hd2 := FPane.RowOfEntry(10) - 1;
  AssertTrue('The second header', FPane.List.Kind[Hd2] = rkHeader);
  HH := FPane.List.RowRect(Hd).Bottom - FPane.List.RowRect(Hd).Top;
  Y2 := FPane.List.RowRect(Hd2).Top;          // (not scrolled: its place in the content)

  { not scrolled: the header is in its own place }
  AssertEquals('At the top', 0, FPane.List.RowRect(Hd).Top);
  AssertTrue('The first track can be seen', FPane.List.RowInView(First));

  { scrolled to the third track: the header is pinned and takes the mouse }
  FPane.List.ScrollTo(FPane.List.RowRect(Third).Top);
  AssertEquals('Pinned at the top', 0, FPane.List.RowRect(Hd).Top);
  AssertEquals('The mouse at the top is on the header', Hd, FPane.List.RowAtPoint(100, 5));
  AssertFalse('The third track is under the header', FPane.List.RowInView(Third));
  AssertTrue('A track below it is in view', FPane.List.RowInView(FPane.RowOfEntry(6)));

  { a track is brought out from under the header }
  FPane.List.EnsureVisible(Third);
  AssertTrue('In view now', FPane.List.RowInView(Third));
  AssertTrue('Below the header', FPane.List.RowRect(Third).Top >= FPane.List.RowRect(Hd).Bottom);
  FPane.List.EnsureVisible(First);
  AssertEquals('The first track brings the list back to its start', 0, FPane.List.ScrollOffset);

  { the next header pushes it out }
  FPane.List.ScrollTo(Y2 - HH div 2 - 20);
  Rc := FPane.List.RowRect(Hd);
  AssertTrue(Format('Partly pushed out (top %d)', [Rc.Top]), (Rc.Top < 0) and (Rc.Bottom > 0));
  AssertTrue('It ends above the next header', Rc.Bottom <= FPane.List.RowRect(Hd2).Top);
  FPane.List.ScrollTo(Y2);
  AssertEquals('The next header is at the top in its own place', 0, FPane.List.RowRect(Hd2).Top);
  AssertEquals('And the mouse is on it', Hd2, FPane.List.RowAtPoint(100, 5));

  { collapsing a pinned header brings it into view }
  FPane.List.ScrollTo(Y2 + HH + 100);
  AssertEquals('The second header is pinned', 0, FPane.List.RowRect(Hd2).Top);
  FPane.List.Collapsed[Hd2] := True;
  Rc := FPane.List.RowRect(Hd2);
  AssertTrue(Format('Collapsed and whole (top %d)', [Rc.Top]), (Rc.Top >= 0) and (Rc.Bottom - Rc.Top = HH));

  { switched off: the top of the list is a track again }
  FPane.List.Collapsed[Hd2] := False;
  FPane.List.StickyHeaders := False;
  FPane.List.ScrollTo(FPane.List.RowRect(Third).Top + FPane.List.ScrollOffset);
  AssertEquals('No pinned header', Third, FPane.List.RowAtPoint(100, 5));
end;

{ An album on two discs gets a heading above the first track of each disc;
  the artist of a track is noted where the tracks of a group differ and it
  is not the album artist, unless the track format shows the artist itself }
procedure TTestPlaylistPane.DiscsGetAHeadingAndGuestsTheirName;
var
  I, Lead: Integer;
  T: TTrackInfo;

  function GapAbove(E: Integer): Integer;
  begin
    Result := FPane.List.RowRect(FPane.RowOfEntry(E)).Top - FPane.List.RowRect(FPane.RowOfEntry(E) - 1).Bottom;
  end;

begin
  FTracks.Clear;
  for I := 1 to 8 do
  begin
    T := Default(TTrackInfo);
    T.FilePath := Format('C:\Music\Album %d\%.2d Track.flac', [(I + 3) div 4, I]);
    T.FolderDir := ExtractFileDir(T.FilePath);
    T.Title := Format('Track %d', [I]);
    T.Artist := 'An Artist';
    if I = 6 then T.Artist := 'An Artist; A Guest';
    T.AlbumArtist := 'An Artist';
    T.Album := Format('Album %d', [(I + 3) div 4]);
    T.TrackNumber := I;
    { the first album on two discs, the second on one }
    if I <= 2 then T.DiscNumber := 1 else if I <= 4 then T.DiscNumber := 2 else T.DiscNumber := 1;
    FTracks.Add(T);
  end;
  FForm.HandleNeeded;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.AddTracks(FTracks);
  FPane.List.SetBounds(0, 40, 800, 560);
  FPane.List.HandleNeeded;
  Lead := FPane.List.LeadHeight;
  AssertTrue('A heading has a height', Lead > 0);
  AssertEquals('Above the first track of disc 1', Lead, GapAbove(0));
  AssertEquals('None inside a disc', 0, GapAbove(1));
  AssertEquals('Above the first track of disc 2', Lead, GapAbove(2));
  AssertEquals('None in an album on one disc', 0, GapAbove(4));

  AssertEquals('The guest track names its artists', 'An Artist, A Guest', FPane.Entry(5).ArtistText);
  AssertEquals('The others of that album do not', '', FPane.Entry(4).ArtistText);
  AssertEquals('Nor an album by one artist', '', FPane.Entry(0).ArtistText);
  FPane.SetView(gmAlbum, '%album%', '%artist% - %title%', '', False);
  FPane.Rebuild;
  AssertEquals('Not when the format shows the artist', '', FPane.Entry(5).ArtistText);
  FPane.SetView(gmFlat, '', '%title%', '', False);
  FPane.Rebuild;
  AssertEquals('Not in a flat list', '', FPane.Entry(5).ArtistText);
  AssertEquals('A flat list has no disc headings', 0, GapAbove(2));
end;

{ The tracks of a work get a heading above the first of them and show only
  their part of it; a disc heading and a work heading stand one above the
  other; switched off, in a flat list and for entries loaded from a stored
  playlist (the work is asked from the library once) }
procedure TTestPlaylistPane.WorksGetAHeadingAndShortTitles;
const
  TITLES: array[1..6] of string = ('Symphony No. 5: I. Allegro', 'Symphony No. 5: II. Andante',
    'Allegro', 'Adagio', 'Overture', 'Encore');
  WORKS: array[1..6] of string = ('', '', 'Sonata in A', 'Sonata in A', '', '');
var
  I, Lead: Integer;
  T: TTrackInfo;
  Stored: TPlaylistEntries;

  function GapAbove(E: Integer): Integer;
  begin
    Result := FPane.List.RowRect(FPane.RowOfEntry(E)).Top - FPane.List.RowRect(FPane.RowOfEntry(E) - 1).Bottom;
  end;

begin
  FTracks.Clear;
  for I := 1 to 6 do
  begin
    T := Default(TTrackInfo);
    T.FilePath := Format('C:\Music\Album\%.2d Track.flac', [I]);
    T.FolderDir := ExtractFileDir(T.FilePath);
    T.Title := TITLES[I];
    T.Work := WORKS[I];
    T.Artist := 'An Artist';
    T.AlbumArtist := 'An Artist';
    T.Album := 'Album';
    T.TrackNumber := I;
    { the sonata begins the second disc }
    if I <= 2 then T.DiscNumber := 1 else T.DiscNumber := 2;
    FTracks.Add(T);
  end;
  FForm.HandleNeeded;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.WorkHeadings := True;
  FPane.AddTracks(FTracks);
  FPane.List.SetBounds(0, 40, 800, 560);
  FPane.List.HandleNeeded;
  Lead := FPane.List.LeadHeight;
  AssertEquals('The library was not asked for tracks that came from it', 0, FLookups);

  AssertEquals('The work of the titles', 'Symphony No. 5', FPane.Entry(0).WorkHead);
  AssertEquals('Its first part', 'I. Allegro', FPane.Entry(0).TitleText);
  AssertEquals('Its second part', 'II. Andante', FPane.Entry(1).TitleText);
  AssertEquals('No heading inside the work', '', FPane.Entry(1).WorkHead);
  AssertEquals('The work of the tag', 'Sonata in A', FPane.Entry(2).WorkHead);
  AssertEquals('Its plain titles stay', 'Allegro', FPane.Entry(2).TitleText);
  AssertEquals('A piece of one track', '', FPane.Entry(4).WorkHead);
  AssertEquals('Overture', FPane.Entry(4).TitleText);

  AssertEquals('Disc 1 and the symphony: two strips', 2 * Lead, GapAbove(0));
  AssertEquals('None inside the work', 0, GapAbove(1));
  AssertEquals('Disc 2 and the sonata: two strips', 2 * Lead, GapAbove(2));
  AssertEquals('None above a single piece', 0, GapAbove(4));

  { the entries of a work, for "Select work" }
  AssertTrue('The second movement is in a work', FPane.WorkOfEntry(1, I, Lead));
  AssertEquals('From its first track', 0, I);
  AssertEquals('To its last', 1, Lead);
  AssertFalse('A single piece is in none', FPane.WorkOfEntry(4, I, Lead));
  AssertFalse('Nor an entry that is not there', FPane.WorkOfEntry(99, I, Lead));
  AssertTrue('Selected', FPane.SelectWork(3));
  AssertEquals('Both tracks of the sonata', 2, Length(FPane.SelectedEntries));
  AssertEquals('The first of them', 2, FPane.SelectedEntries[0]);
  AssertEquals('And the second', 3, FPane.SelectedEntries[1]);
  AssertFalse('Nothing to select for a single piece', FPane.SelectWork(5));
  Lead := FPane.List.LeadHeight;

  { with a format around the title the part is what the format gets }
  FPane.SetView(gmAlbum, '%album%', '%artist% - %title%', '', False);
  FPane.Rebuild;
  AssertEquals('An Artist - II. Andante', FPane.Entry(1).TitleText);

  { switched off: the titles whole, only the disc headings }
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.WorkHeadings := False;
  AssertEquals('No work heading', '', FPane.Entry(0).WorkHead);
  AssertEquals('The whole title', 'Symphony No. 5: I. Allegro', FPane.Entry(0).TitleText);
  AssertEquals('The disc heading alone', Lead, GapAbove(0));

  { a flat list has neither }
  FPane.WorkHeadings := True;
  FPane.SetView(gmFlat, '', '%title%', '', False);
  FPane.Rebuild;
  AssertEquals('No heading in a flat list', '', FPane.Entry(0).WorkHead);
  AssertEquals('No strip', 0, GapAbove(2));

  { entries of a stored playlist do not carry the work: the library is asked,
    once per track }
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  Stored := FPane.ToEntries;
  FLookups := 0;
  FPane.LoadEntries(Stored);
  AssertEquals('The work of the tag came from the library', 'Sonata in A', FPane.Entry(2).WorkHead);
  AssertEquals('One question per track', 6, FLookups);
  FPane.Rebuild;
  AssertEquals('And none at the next rebuild', 6, FLookups);
end;

{ A sort is a view: the groups are shown in its order, the entries are
  stored in the order added, tracks added later find their place, nothing
  is moved by hand, and the playing track stays the playing track }
procedure TTestPlaylistPane.ASortedViewKeepsTheOrderAdded;
const
  ARTISTS: array[0..2] of string = ('Zed', 'Alpha', 'Mid');
  YEARS: array[0..2] of Integer = (1990, 2010, 0);
var
  I, A, PlayId: Integer;
  T: TTrackInfo;
  More: TTrackList;
  Stored: TPlaylistEntries;
  Idx: TIntArray;

  function Albums: string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to FPane.EntryCount - 1 do
      if (K = 0) or (FPane.Entry(K).Album <> FPane.Entry(K - 1).Album) then
        Result := Result + FPane.Entry(K).AlbumArtist + ' ';
    Result := Trim(Result);
  end;

  function NewTrack(const AArtist, AAlbum: string; AYear, ANo: Integer): TTrackInfo;
  begin
    Result := Default(TTrackInfo);
    Result.FilePath := Format('C:\Music\%s\%s\%.2d Track.flac', [AArtist, AAlbum, ANo]);
    Result.FolderDir := ExtractFileDir(Result.FilePath);
    Result.Title := Format('Track %d', [ANo]);
    Result.Artist := AArtist;
    Result.AlbumArtist := AArtist;
    Result.Album := AAlbum;
    Result.Year := AYear;
    Result.TrackNumber := ANo;
  end;

begin
  FTracks.Clear;
  for A := 0 to 2 do
    for I := 1 to 2 do
    begin
      T := NewTrack(ARTISTS[A], 'Album of ' + ARTISTS[A], YEARS[A], I);
      FTracks.Add(T);
    end;
  { as added }
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psAdded);
  FPane.AddTracks(FTracks);
  AssertFalse('No sort', FPane.SortActive);
  AssertEquals('Zed Alpha Mid', Albums);
  Stored := FPane.ToEntries;

  { by artist }
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psArtist);
  FPane.LoadEntries(Stored);
  AssertTrue('Sorted', FPane.SortActive);
  AssertEquals('Alpha Mid Zed', Albums);
  AssertEquals('The tracks of an album keep their order', 'Track 1', FPane.Entry(0).Title);
  AssertEquals('Stored as added', 'Zed', FPane.ToEntries[0].Artist);
  AssertEquals('To the end', 'Mid', FPane.ToEntries[5].Artist);

  { the playing track is found again after tracks were added }
  FPane.PlayingEntry := 5;                       // Zed, track 2
  PlayId := FPane.Entry(5).Id;
  More := TTrackList.Create;
  try
    T := NewTrack('Beta', 'Album of Beta', 2001, 1);
    More.Add(T);
    FPane.AddTracks(More, 0);                    // "at the top": a sorted list decides itself
  finally
    More.Free;
  end;
  AssertEquals('Alpha Beta Mid Zed', Albums);
  AssertEquals('Where the new track went', 2, FPane.LastAddedIndex);
  AssertEquals('Added last in the stored order', 'Beta', FPane.ToEntries[6].Artist);
  AssertEquals('The first stored is still the first added', 'Zed', FPane.ToEntries[0].Artist);
  AssertEquals('The playing track', PlayId, FPane.Entry(FPane.PlayingEntry).Id);

  { nothing is moved by hand }
  Idx := nil;
  SetLength(Idx, 1);
  Idx[0] := 0;
  FPane.MoveEntries(Idx, FPane.EntryCount);
  AssertEquals('Not moved', 'Alpha Beta Mid Zed', Albums);

  { removing keeps the stored order of the rest }
  Idx[0] := 2;                                   // Beta
  FPane.RemoveEntries(Idx);
  AssertEquals('Alpha Mid Zed', Albums);
  Stored := FPane.ToEntries;
  AssertEquals('Six left', 6, Length(Stored));
  AssertEquals('Zed first', 'Zed', Stored[0].Artist);
  AssertEquals('Then Alpha', 'Alpha', Stored[2].Artist);

  { the other orders; a year that is not known comes last both ways }
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psYear);
  FPane.LoadEntries(Stored);
  AssertEquals('Oldest first', 'Zed Alpha Mid', Albums);
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psYear, True);
  FPane.LoadEntries(Stored);
  AssertEquals('Reversed: newest first', 'Alpha Zed Mid', Albums);
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psArtist, True);
  FPane.LoadEntries(Stored);
  AssertEquals('Artists from Z', 'Zed Mid Alpha', Albums);
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psAdded, True);
  FPane.LoadEntries(Stored);
  AssertTrue('"As added" reversed is a sorted view', FPane.SortActive);
  AssertEquals('Added last first', 'Mid Alpha Zed', Albums);
  AssertEquals('Stored as added all the same', 'Zed', FPane.ToEntries[0].Artist);
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psAlbum);
  FPane.LoadEntries(Stored);
  AssertEquals('By album', 'Alpha Mid Zed', Albums);

  { a flat list is never sorted, and "as added" is the stored order again }
  FPane.SetView(gmFlat, '', '%title%', '', False, psArtist);
  FPane.LoadEntries(Stored);
  AssertFalse('A flat list has no sort', FPane.SortActive);
  AssertEquals('Zed Alpha Mid', Albums);
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False, psAdded);
  FPane.LoadEntries(Stored);
  AssertEquals('Zed Alpha Mid', Albums);
  Idx[0] := 0;
  FPane.MoveEntries(Idx, FPane.EntryCount);
  AssertEquals('Moved by hand, and stored that way', 'Track 1', FPane.ToEntries[5].Title);
end;

{ The closed albums are kept by name and closed again when the playlist is
  built again - all of them, not only the first }
procedure TTestPlaylistPane.EveryClosedAlbumIsRemembered;
var
  I, R, Closed: Integer;
  T: TTrackInfo;
  Names: TStringArray;
  Stored: TPlaylistEntries;
begin
  FTracks.Clear;
  for I := 1 to 40 do
  begin
    T := Default(TTrackInfo);
    T.FilePath := Format('C:\Music\Album %.2d\%.3d Track.flac', [(I + 3) div 4, I]);
    T.FolderDir := ExtractFileDir(T.FilePath);
    T.Title := Format('Track %d', [I]);
    T.Artist := 'An Artist';
    T.AlbumArtist := 'An Artist';
    T.Album := Format('Album %.2d', [(I + 3) div 4]);
    T.TrackNumber := I;
    FTracks.Add(T);
  end;
  FPane.SetView(gmAlbum, '%album%', '%title%', '', False);
  FPane.AddTracks(FTracks);
  { the 2nd, 5th and 9th album closed by hand }
  FPane.List.Collapsed[FPane.RowOfEntry(4) - 1] := True;
  FPane.List.Collapsed[FPane.RowOfEntry(16) - 1] := True;
  FPane.List.Collapsed[FPane.RowOfEntry(32) - 1] := True;
  Names := FPane.CollapsedNames;
  AssertEquals('Three names', 3, Length(Names));
  { the playlist left and shown again }
  Stored := FPane.ToEntries;
  FPane.Clear;
  FPane.SetCollapsedNames(Names);
  FPane.LoadEntries(Stored);
  Closed := 0;
  for R := 0 to FPane.List.RowCount - 1 do
    if (FPane.List.Kind[R] = rkHeader) and FPane.List.Collapsed[R] then Inc(Closed);
  AssertEquals('All three are closed again', 3, Closed);
  AssertFalse('A track of the 5th album is hidden', FPane.List.IsVisibleRow(FPane.RowOfEntry(17)));
  AssertTrue('One of the 3rd is not', FPane.List.IsVisibleRow(FPane.RowOfEntry(9)));
  AssertEquals('And the names are still all there', 3, Length(FPane.CollapsedNames));
  { all closed, all open }
  FPane.CollapseAll;
  AssertEquals('Ten names', 10, Length(FPane.CollapsedNames));
  FPane.ExpandAll;
  AssertEquals('None', 0, Length(FPane.CollapsedNames));
end;

{ The flat list: default columns, columns that give way in a narrow pane,
  the layout as a text and back, sorting by a clicked column with the column
  before it deciding among equals, and the order added kept underneath }
procedure TTestPlaylistPane.AFlatListHasColumnsAndSortsByThem;
const
  TITLES: array[0..5] of string = ('Echo', 'Alpha', 'Delta', 'Bravo', 'Foxtrot', 'Charlie');
  ARTISTS: array[0..5] of string = ('Zed', 'Mid', 'Zed', 'Mid', 'Alpha', 'Zed');
var
  I: Integer;
  T: TTrackInfo;
  R: TPlColRects;
  Cols, Sort: string;
  Stored: TPlaylistEntries;

  function Shown: string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to FPane.EntryCount - 1 do Result := Result + FPane.Entry(K).Title + ' ';
    Result := Trim(Result);
  end;

  function Has(const ARects: TPlColRects; C: TPlColumn): Boolean;
  var
    K: Integer;
  begin
    Result := False;
    for K := 0 to High(ARects) do
      if ARects[K].Col = C then Result := True;
  end;

begin
  FTracks.Clear;
  for I := 0 to 5 do
  begin
    T := Default(TTrackInfo);
    T.FilePath := Format('C:\Music\Mix\%.2d %s.flac', [I + 1, TITLES[I]]);
    T.FolderDir := ExtractFileDir(T.FilePath);
    T.Title := TITLES[I];
    T.Artist := ARTISTS[I];
    T.AlbumArtist := ARTISTS[I];
    T.Album := 'Mix';
    T.Year := 2000 + I;
    T.TrackNumber := I + 1;
    FTracks.Add(T);
  end;
  FPane.SetFlatLayout('', '');
  FPane.SetView(gmFlat, '', '%title%', '', False);
  FPane.AddTracks(FTracks);
  AssertFalse('Playlist order', FPane.SortActive);
  AssertEquals('Echo Alpha Delta Bravo Foxtrot Charlie', Shown);

  { the columns: the default ones in a wide row, fewer in a narrow one }
  R := FPane.ColumnRects(1200);
  AssertEquals('Six columns', 6, Length(R));
  AssertTrue('The number first', R[0].Col = pcNumber);
  AssertTrue('Then the title', R[1].Col = pcTitle);
  AssertEquals('The columns fill the row', 1200, R[5].X + R[5].W);
  { a narrower row: the columns are squeezed, none is left out }
  R := FPane.ColumnRects(560);
  AssertEquals('Still six columns', 6, Length(R));
  AssertTrue('The artist is narrower than chosen', R[2].W < 190);
  AssertEquals('The columns fill the row', 560, R[5].X + R[5].W);
  { a column switched on is shown even when there was no room to spare }
  FPane.ToggleColumn(pcYear);
  R := FPane.ColumnRects(560);
  AssertTrue('The year is there', Has(R, pcYear));
  AssertEquals('Seven columns', 7, Length(R));
  FPane.ToggleColumn(pcYear);
  { only a row too narrow for their least widths loses columns }
  R := FPane.ColumnRects(330);
  AssertTrue('The album gives way', not Has(R, pcAlbum));
  AssertTrue('The title and the time stay', Has(R, pcTitle) and Has(R, pcTime));
  AssertEquals('The text of a column', 'Zed', FPane.ColumnText(0, pcArtist));
  AssertEquals('The year', '2000', FPane.ColumnText(0, pcYear));

  { by title, and reversed by a second click }
  FPane.SortByColumn(pcTitle);
  AssertTrue('Sorted', FPane.SortActive);
  AssertEquals('Alpha Bravo Charlie Delta Echo Foxtrot', Shown);
  FPane.SortByColumn(pcTitle);
  AssertEquals('Foxtrot Echo Delta Charlie Bravo Alpha', Shown);
  FPane.SortByColumn(pcTitle);
  { then by artist: the titles decide among the tracks of one artist }
  FPane.SortByColumn(pcArtist);
  AssertEquals('Foxtrot Alpha Bravo Charlie Delta Echo', Shown);
  AssertEquals('Stored in the order added', 'Echo', FPane.ToEntries[0].Title);

  { the layout and the sort as texts, and back }
  FPane.ToggleColumn(pcYear);
  FPane.SetColumnWidth(pcArtist, 250);
  Cols := FPane.FlatColsText;
  Sort := FPane.FlatSortText;
  AssertTrue('A layout text', Cols <> '');
  AssertTrue('A sort text', Sort <> '');
  Stored := FPane.ToEntries;
  FPane.SetFlatLayout('', '');
  FPane.LoadEntries(Stored);
  AssertEquals('The default again', 'Echo Alpha Delta Bravo Foxtrot Charlie', Shown);
  AssertEquals('No texts for the default', '', FPane.FlatColsText + FPane.FlatSortText);
  FPane.SetFlatLayout(Cols, Sort);
  FPane.LoadEntries(Stored);
  AssertEquals('The sort is back', 'Foxtrot Alpha Bravo Charlie Delta Echo', Shown);
  AssertTrue('The year column is back', pcYear in FPane.ShownColumns);
  AssertEquals('And the texts are the same', Cols + '|' + Sort, FPane.FlatColsText + '|' + FPane.FlatSortText);

  { the number column is the playlist order again }
  FPane.SortByColumn(pcNumber);
  AssertFalse('Not sorted', FPane.SortActive);
  AssertEquals('Echo Alpha Delta Bravo Foxtrot Charlie', Shown);
end;

initialization
  RegisterTest(TTestPlaylistPane);

end.
