unit AuPlaylistPane;

{ ==============================================================================
  AulumicNS - AuPlaylistPane
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The playlist pane on the right of the main window, on the AulumicNS group
  list (TAuGroupList): the playlist selector,
  "View" (grouping and formats) and "Edit" above the list.

  The list:
  - grouped by album (folder + album artist + album), by folder, or flat
    (uPlaylistRows.PlaylistGroupKey); a new group also starts when a file is
    in the open group already;
  - a group header: the cover thumbnail of the library scan (not when
    grouped by folder), the header format (uTagParser.FormatTrackInfo; by
    folder: the folder name) in one or two lines
    (uPlaylistRows.SplitHeaderIntoTwoLines), the average rating;
  - a track: the number (disc-track; a flat list: the position), the track
    format, the rating (click a star; the same star again clears it,
    uPlaylistRows.NextRating), the length; the playing track bold with a
    play mark;
  - collapsed groups are kept by their header text or album;
  - an auto-playlist is read only and may show a date suffix ("last played",
    "added").

  The pane holds the entries (TPlEntry, in playlist order) and builds the
  rows from them (Rebuild); the main window stores them (uPlaylistStore)
  when OnChange says the content changed. Tracks of the library come from
  its records (AddTracks; OnLookup for added files), never from the files.
  FollowEntry moves the selection to the track that starts playing ("Cursor
  follows playback") and brings it into view.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Contnrs, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuMenus, AuExtra, AuGroupList,
  uAppConsts, uLibraryTypes, uPlaylistFile;

type
  { the order of the groups shown: as the tracks were added (the order that
    is stored), or sorted - a view, the stored order stays }
  TPlSortMode = (psAdded, psArtist, psAlbum, psYear, psDateAdded);

  { the columns of a flat list, in the order they are shown. The number and
    the title are always there; the title takes the room that is left. }
  TPlColumn = (pcNumber, pcTitle, pcArtist, pcAlbum, pcAlbumArtist, pcYear, pcGenre, pcFormat,
    pcPlays, pcLastPlayed, pcAdded, pcRating, pcTime);
  TPlColumnSet = set of TPlColumn;
  TPlColRect = record
    Col: TPlColumn;
    X, W: Integer;          // pixels from the left of the row content
  end;
  TPlColRects = array of TPlColRect;

  TPlEntry = record
    Id: Integer;            // stable row id (the play queue's TrackId)
    Seq: Integer;           // its place in the order added (the stored order)
    FilePath: string;
    Title, Artist, AlbumArtist, Album, Genre: string;
    Year: Integer;
    TrackNum, DiscNum: Integer;
    DurationStr: string;
    Seconds: Integer;
    DateStr: string;
    SampleRate, BitDepth: Integer;
    Rating: Integer;        // from the user stats (RefreshRatings)
    GroupKey: string;       // the album of the play queue item
    FolderDir: string;
    TitleText: string;      // the track format, made by Rebuild / RefreshTexts
    ArtistText: string;     // the track's artist behind the title ('' = not shown)
    Work: string;           // the work of its tag ('' = none)
    WorkKnown: Boolean;     // Work was asked from the library (FillWorks asks once)
    WorkHead: string;       // a work heading belongs above this track ('' = none; FindGroupWorks)
    PartTitle: string;      // its title under that heading ('' = the whole title)
    WorkFirst, WorkLast: Integer;   // the entries of its work (-1: in no work)
    Plays: Integer;         // flat list columns, from the library and the user stats (FillStats)
    LastPlayed, Added: Int64;
  end;
  TIntArray = array of Integer;

  TPlHeader = record
    First, Count, TotalSec: Integer;   // the entries of the group
    Rating: Integer;                   // the average of its tracks
    Text: string;                      // the header format
    Info: string;                      // "11 tracks • 49:30" under the stars ('' = none)
    Album, AlbumArtist, FolderDir: string;
    FirstDisc: Integer;                // the first disc number of the group (0: none yet)
    MultiDisc: Boolean;                // its tracks have more than one disc number
    FirstArtist: string;
    MixedArtists: Boolean;             // its tracks have more than one artist
  end;

  { the selected rows of the list by the files of their tracks }
  TPlSelection = record
    Items, Heads: array of string;   // tracks; headers by their group's first track
    Focus: string;                   // the focused row's track
    FocusHead: Boolean;              // ... and whether that row is a header
    Scroll: Integer;                 // the list's scroll offset
  end;

  { a library record for a file (False: not in the library) }
  TPlLookupEvent =function(const APath: string; out ATrack: TTrackInfo): Boolean of object;
  { a click on a header's cover: the group's first entry }
  TPlCoverEvent = procedure(Sender: TObject; AEntry: Integer) of object;

  { TPlaylistPane }

  TPlaylistPane = class(TAuPanel)
  private
    FTop: TAuPanel;
    FEntries: array of TPlEntry;
    FCount: Integer;
    FWorkHeadings: Boolean;
    FHeaders: array of TPlHeader;
    FHeaderCount: Integer;
    FHeaderOf: array of Integer;       // entry -> header (-1 flat)
    FPlaying: Integer;
    FDemo: Boolean;
    FNextId: Integer;
    FOnLookup: TPlLookupEvent;
    FThumbs: TStringList;              // album hash -> TGfxBitmap (nil: none)
    FThumbPx: Integer;                 // the size the kept thumbnails were read at
    FGroupMode: TGroupingMode;
    FSortMode: TPlSortMode;
    FSortReverse: Boolean;
    FQuietCollapse: Boolean;           // ListCollapse leaves the names alone
    { the flat list: its columns (unscaled widths) and what it is sorted by -
      the column clicked last, then the one clicked before it }
    FColHead: TAuControl;
    FColMenu: TAuMenu;
    FColVisible: TPlColumnSet;
    FColWidth: array[TPlColumn] of Integer;
    FSortCol, FSortCol2: TPlColumn;
    FSortRev, FSortRev2: Boolean;
    FFlatStarsX: Single;               // where the rating column begins in a row (< 0: not shown)
    FOnViewChange: TNotifyEvent;
    FLastAdded: Integer;               // the first of the entries added last
    FWantTop: string;                  // ScrollToFile waiting for the list to have its size
    FHeaderFmt, FTrackFmt, FDateSuffix: string;
    FReadOnly: Boolean;
    FCollapsed: TStringList;           // header texts / albums to keep collapsed
    FRowW: Single;                     // content width of the rows (painting)
    FOnChange, FOnRatingChange, FOnCollapseChange: TNotifyEvent;
    FOnCoverClick: TPlCoverEvent;
    procedure TopResize(Sender: TObject);
    procedure ListResize(Sender: TObject);
    function SeqOrder: TIntArray;
    procedure RenumberSeq;
    procedure ApplySort;
    procedure FillStats;
    function NeedsStats: Boolean;
    function SuffixShows(const ATag: string): Boolean;
    procedure DrawFlatRow(G: TGfx; E: Integer; X, Y, W, H: Single);
    procedure ColMenuClick(Sender: TObject);
    procedure NotifyView;
    procedure DrawRow(Sender: TObject; G: TGfx; Row: Integer; X, Y, W, H: Single; State: TAuRowState);
    procedure DrawLead(Sender: TObject; G: TGfx; Row: Integer; X, Y, W, H: Single; State: TAuRowState);
    function RowText(Sender: TObject; Row: Integer): string;
    procedure DrawStars(G: TGfx; X, CY, Sz: Single; Rating: Integer; C: TARGB);
    procedure RowClick(Sender: TObject; Row: Integer; X, Y: Integer);
    procedure ListCollapse(Sender: TObject);
    procedure SetAllCollapsed(AValue: Boolean);
    procedure SetPlaying(V: Integer);
    function ReadEntry(const APath: string): TPlEntry;
    function ThumbOf(const H: TPlHeader; APixels: Integer): TGfxBitmap;
    function EntryFromTrack(const T: TTrackInfo): TPlEntry;
    procedure InsertEntries(const New_: array of TPlEntry; N, InsertAt: Integer);
    function TrackOf(const E: TPlEntry): TTrackInfo;
    function RatingOf(const E: TPlEntry): Integer;
    function HeaderTextWidth(const S: string): Integer;
    function StarsLeft(IsHeader: Boolean): Single;
    function DisplayNumber(E: Integer): string;
    procedure Changed;
    procedure BuildTexts;
    procedure FindGroupWorks;
    function DiscLeadAt(I: Integer): Boolean;
    procedure SetWorkHeadings(V: Boolean);
  public
    BtnPlaylist: TAuDropButton;
    BtnView, BtnSort: TAuButton;
    BtnEdit, BtnSortDir: TAuIconButton;
    List: TAuGroupList;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Clear;
    { the grouping, formats ('' = the defaults, see the main window), the date
      suffix of an auto-playlist and whether the list may be changed }
    procedure SetView(AGroupMode: TGroupingMode; const AHeaderFmt, ATrackFmt, ADateSuffix: string;
      AReadOnly: Boolean; ASortMode: TPlSortMode = psAdded; ASortReverse: Boolean = False);
    { the groups are shown in another order than the tracks were added:
      new tracks find their place by themselves, and nothing can be moved }
    function SortActive: Boolean;
    function SortName(AMode: TPlSortMode): string;
    { ---- the flat list's columns ---- }
    function ColumnTitle(C: TPlColumn): string;
    function ColumnText(E: Integer; C: TPlColumn): string;
    { the columns shown: those chosen, and the date an auto-playlist is
      sorted by }
    function ShownColumns: TPlColumnSet;
    { their places in a row AWidth pixels wide; columns that leave the title
      too little room are left out, the least important first }
    function ColumnRects(AWidth: Integer): TPlColRects;
    { the layout and the sort as texts for the playlist store ('' = default) }
    function FlatColsText: string;
    function FlatSortText: string;
    procedure SetFlatLayout(const ACols, ASort: string);
    { a click on a heading: sorts by that column, a second click reverses;
      the number column is the playlist's own order }
    procedure SortByColumn(C: TPlColumn);
    procedure ToggleColumn(C: TPlColumn);
    procedure SetColumnWidth(C: TPlColumn; AWidth: Integer);
    procedure PopupColumnMenu;
    procedure Resort;
    property SortColumn: TPlColumn read FSortCol;
    property SortColumnReverse: Boolean read FSortRev;
    { the columns, their widths or the sort of the flat list changed }
    property OnViewChange: TNotifyEvent read FOnViewChange write FOnViewChange;
    { where the entries added last begin (the insert position, or their
      place in a sorted list); -1 before anything was added }
    property LastAddedIndex: Integer read FLastAdded;
    { the track at the top of the list, and the list scrolled back to it }
    function TopFile: string;
    procedure ScrollToFile(const APath: string);
    { reads the tags of the files and adds them (at InsertAt, -1 = the end) }
    procedure AddFiles(Paths: TStrings; InsertAt: Integer = -1);
    { copies of library records (no disk access) }
    procedure AddTracks(Tracks: TTrackList; InsertAt: Integer = -1);
    { the content of a stored playlist (replaces the list) }
    procedure LoadEntries(const AEntries: TPlaylistEntries);
    function ToEntries: TPlaylistEntries;
    procedure Rebuild;
    { Rebuild for the same entries: selection, focus and scroll position stay }
    procedure RebuildKeepingSelection(ASortAgain: Boolean = False);
    { the same for a list that is loaded again (its entries are new ones):
      the rows are known by the file of their track, a header by the file of
      its group's first track. PutSelection gives the number of rows it
      selected and leaves the list alone when that is none. }
    function CopyNumbers: TIntArray;
    function SelectionKey(AEntry: Integer; const ACopies: TIntArray): string;
    function TakeSelection: TPlSelection;
    function PutSelection(const ASel: TPlSelection): Integer;
    procedure RemoveEntries(const Idx: TIntArray);
    { moves the entries to InsertAt (an index of the list before the move) }
    procedure MoveEntries(const Idx: TIntArray; InsertAt: Integer);
    { the tags of the entries again from the library (F5), the texts again }
    procedure SyncWithLibrary;
    { the ratings and the texts again from the user stats }
    procedure RefreshRatings;
    { the rating of the entries (0 = none), stored in the user stats }
    procedure RateEntries(const Idx: TIntArray; ARating: Integer);
    procedure ClearThumbCache;
    function EntryCount: Integer;
    function Entry(I: Integer): TPlEntry;
    function EntryOfRow(Row: Integer): Integer;
    function RowOfEntry(E: Integer): Integer;
    function HeaderOfEntry(E: Integer): Integer;
    function SelectedEntries: TIntArray;
    { the position of the entry in its group and the group's size / time }
    procedure GroupInfo(E: Integer; out Index, Count, TotalSec: Integer);
    function IndexOfFile(const APath: string; Near: Integer = -1): Integer;
    function IndexOfId(AId: Integer): Integer;
    { selects the entry; in a collapsed group AOpenGroup opens it, otherwise
      the header is selected }
    procedure SelectEntry(E: Integer; AOpenGroup: Boolean = True; ACenter: Boolean = False);
    { the track that starts playing (at a track
      change): selected, its group opened, and brought to the middle of the
      list when it is not in view - a row in view stays where it is }
    procedure FollowEntry(E: Integer);
    function SelectedFilePath: string;
    { where a drop at client Y goes: the entry index to insert at, and the
      drop marker (flat before / after the row, grouped before
      the group on the upper half of its header, else after the group) }
    function InsertIndexAt(Y: Integer; out AMarkRow: Integer; out AMarkAbove: Boolean): Integer;
    function CollapsedNames: TStringArray;
    procedure SetCollapsedNames(const ANames: array of string);
    procedure ExpandAll;
    procedure CollapseAll;
    procedure FillDemo;
    function StarsWidth: Single;
    property PlayingEntry: Integer read FPlaying write SetPlaying;
    property GroupMode: TGroupingMode read FGroupMode;
    property SortMode: TPlSortMode read FSortMode;
    property SortReverse: Boolean read FSortReverse;
    property ReadOnly: Boolean read FReadOnly;
    { the tracks of a work (a symphony's movements) under a heading of their
      own inside the album, with the work left out of their titles }
    property WorkHeadings: Boolean read FWorkHeadings write SetWorkHeadings;
    { the entries of the work entry E belongs to (False: it is in no work) }
    function WorkOfEntry(E: Integer; out AFirst, ALast: Integer): Boolean;
    { selects them, with the first as the focused one (False: no work) }
    function SelectWork(E: Integer): Boolean;
    property IsDemo: Boolean read FDemo;
    property OnLookup: TPlLookupEvent read FOnLookup write FOnLookup;
    { the entries changed (added, removed, moved, cleared) }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnRatingChange: TNotifyEvent read FOnRatingChange write FOnRatingChange;
    property OnCollapseChange: TNotifyEvent read FOnCollapseChange write FOnCollapseChange;
    property OnCoverClick: TPlCoverEvent read FOnCoverClick write FOnCoverClick;
  end;

function FormatDuration(Sec: Integer): string;
{ a total that may be long: m:ss below an hour, "1 h 22 min" below a day,
  "172 days 22 h" from a day on }
function FormatLongDuration(Sec: Int64): string;
{ a count with the thousands separator of the regional settings }
function FormatCount(N: Integer): string;

implementation

uses
  LazUTF8, DateUtils, uInputBlock, AuAudioTypes, ALMetadata, uAudioUtils, uMetaUtils, uUserStatsManager, uTagParser, uPlaylistRows, uPlaylistFormat, uAppStrings;

const
  PL_EMPTY_TEXT = 'This playlist is empty.' + LineEnding +
    'Drag music from the library or from Windows Explorer here,' + LineEnding +
    'or use Main menu > File > Add files... (Ctrl+O).';
  COL_HEAD_H = 28;                // the heading row of a flat list
  COL_TITLE_MIN_W = 150;          // the title keeps this much; other columns give way
  COL_MIN_W = 40;                 // a column can be dragged this narrow ...
  COL_MAX_W = 600;                // ... and this wide
  COL_GRIP_W = 5;                 // the drag zone at each side of a column's left edge
  COL_IDS: array[TPlColumn] of string = ('num', 'title', 'artist', 'album', 'albumartist', 'year',
    'genre', 'format', 'plays', 'lastplayed', 'added', 'rating', 'time');
  COL_TITLES: array[TPlColumn] of string = ('#', 'Title', 'Artist', 'Album', 'Album artist', 'Year',
    'Genre', 'Format', 'Plays', 'Last played', 'Added', 'Rating', 'Time');
  COL_DEFAULT_W: array[TPlColumn] of Integer = (46, 0, 190, 210, 170, 56, 130, 84, 56, 112, 112, 0, 64);
  COL_DEFAULT_VISIBLE = [pcNumber, pcTitle, pcArtist, pcAlbum, pcRating, pcTime];
  COL_RESIZABLE = [pcArtist, pcAlbum, pcAlbumArtist, pcYear, pcGenre, pcFormat, pcPlays, pcLastPlayed, pcAdded];
  { what gives way first when the pane is narrow }
  COL_DROP_ORDER: array[0..9] of TPlColumn = (pcAdded, pcLastPlayed, pcPlays, pcFormat, pcGenre, pcYear,
    pcAlbumArtist, pcAlbum, pcArtist, pcRating);
  LIST_READY_MIN_H = 120;         // a list lower than this has not been laid out yet
  SORT_BUTTON_MIN_PANE_W = 520;   // a narrower pane has no room for the sort button
  HEADER_TEXT_MIN_W = 220;   // a header keeps this much for its text before the track count and time appear
  ARTIST_TEXT_MIN_W = 70;    // a track's artist is shown from this much room behind the title
  PL_AUTO_EMPTY_TEXT = 'This auto-playlist is empty: no track of the library matches its rules.' + LineEnding +
    'Change its rules in the Playlist Manager (Alt+P).';

function FormatDuration(Sec: Integer): string;
begin
  if Sec < 0 then Sec := 0;
  if Sec >= 3600 then
    Result := Format('%d:%.2d:%.2d', [Sec div 3600, (Sec div 60) mod 60, Sec mod 60])
  else
    Result := Format('%d:%.2d', [Sec div 60, Sec mod 60]);
end;

function FormatLongDuration(Sec: Int64): string;
var
  M, H: Int64;
begin
  if Sec < 0 then Sec := 0;
  if Sec < 3600 then Exit(FormatDuration(Integer(Sec)));
  M := (Sec + 30) div 60;
  if M < 24 * 60 then Exit(Format('%d h %.2d min', [M div 60, M mod 60]));
  H := (Sec + 1800) div 3600;
  if H div 24 = 1 then Result := Format('1 day %d h', [H mod 24])
  else Result := Format('%s days %d h', [FormatCount(H div 24), H mod 24]);
end;

function FormatCount(N: Integer): string;
begin
  Result := Format('%.0n', [N * 1.0]);
end;

function IfIcon(AReverse: Boolean): TAuIcon;
begin
  if AReverse then Result := icSortDesc else Result := icSortAsc;
end;

{ ---- the heading row of a flat list ---- }

type
  { One heading per column, at the places ColumnRects gives the rows. A click
    sorts by the column, a right click opens the list of columns. The line
    between two headings is dragged as a splitter: it follows the pointer,
    the column on one side grows by what the other gives up. Left of the
    first such column is the title, which takes or gives the difference. }
  TPlColumnHeader = class(TAuControl)
  private
    FHotCol, FDownCol: Integer;       // Ord(TPlColumn), -1 = none
    FGrip: Integer;                   // the column whose edge is dragged, -1 = none
    FGripX, FGripW, FGripMax: Integer;
    FGripLeft, FGripLeftW: Integer;   // the column left of the dragged line, when it has a width of its own
    { the edge was only taken because a finger reaches further than the
      mouse (TOUCH_EDGE_REACH), and whether it was moved: a tap there is a
      click on the column }
    FGripWide, FGripMoved: Boolean;
    function Rects(out AX0: Integer): TPlColRects;
    function ColAt(X: Integer; out AGrip: Integer; AReach: Integer = 0): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
  public
    FPane: TPlaylistPane;
    constructor Create(AOwner: TComponent); override;
  end;

constructor TPlColumnHeader.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FocusOnClick := False;
  FHotCol := -1;
  FDownCol := -1;
  FGrip := -1;
  FGripLeft := -1;
end;

function TPlColumnHeader.Rects(out AX0: Integer): TPlColRects;
begin
  AX0 := FPane.List.Left + FPane.List.ContentLeft;
  Result := FPane.ColumnRects(FPane.List.ContentWidth);
end;

{ the column at X (-1: none) and, in AGrip, the column whose left edge is
  near enough to drag (-1: none): within AReach pixels, the nearest one
  (0 = the reach of the mouse) }
function TPlColumnHeader.ColAt(X: Integer; out AGrip: Integer; AReach: Integer): Integer;
var
  R: TPlColRects;
  I, X0, D, Best: Integer;
begin
  Result := -1;
  AGrip := -1;
  if AReach <= 0 then AReach := S(COL_GRIP_W);
  Best := AReach + 1;
  R := Rects(X0);
  for I := 0 to High(R) do
  begin
    D := Abs(X - (X0 + R[I].X));
    if (R[I].Col in COL_RESIZABLE) and (D <= AReach) and (D < Best) then
    begin
      AGrip := Ord(R[I].Col);
      Best := D;
    end;
    if (X >= X0 + R[I].X) and (X < X0 + R[I].X + R[I].W) then Result := Ord(R[I].Col);
  end;
end;

procedure TPlColumnHeader.DoPaint(G: TGfx);
var
  R: TPlColRects;
  I, X0, TW: Integer;
  F: TGfxFont;
  T: string;
  C: TPlColumn;
  Fg: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if FPane = nil then Exit;
  R := Rects(X0);
  F := UIFont(FPane.List.TextSize - 1.5);
  for I := 0 to High(R) do
  begin
    C := R[I].Col;
    T := FPane.ColumnTitle(C);
    if Ord(C) = FHotCol then
      G.FillRound(X0 + R[I].X - S(4), S(3), R[I].W, Height - S(7), S(5), Blend(EffBack, clHover, 0.9));
    if C = FPane.SortColumn then Fg := clAccentText else Fg := clTextDim;
    TW := Ceil(TextWidth(T, F));
    if C = pcTime then
    begin
      { right aligned, as the times are }
      G.Text(T, X0 + R[I].X, 0, R[I].W, Height - S(1), F, Fg, 2, 1);
      if (C = FPane.SortColumn) and FPane.SortActive then
        DrawIcon(G, IfIcon(FPane.SortColumnReverse), X0 + R[I].X + R[I].W - TW - S(10), Height / 2, S(11), Fg);
    end
    else
    begin
      G.Text(T, X0 + R[I].X, 0, R[I].W - S(8), Height - S(1), F, Fg, 0, 1);
      if (C = FPane.SortColumn) and FPane.SortActive and (TW + S(18) < R[I].W) then
        DrawIcon(G, IfIcon(FPane.SortColumnReverse), X0 + R[I].X + TW + S(10), Height / 2, S(11), Fg);
    end;
  end;
  G.FillRect(S(8), Height - 1, Width - S(16), 1, WithAlpha(clText, 30));
end;

procedure TPlColumnHeader.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Col, Grip, D: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FGrip >= 0 then
  begin
    { the left edge follows the pointer: to the left is wider }
    D := Round((X - FGripX) / UIScale);          // to the right: the left side grows
    if Abs(X - FGripX) > S(4) then FGripMoved := True;
    { a finger that has not moved yet may still be a tap }
    if FGripWide and not FGripMoved then Exit;
    if FGripLeft >= 0 then
    begin
      if COL_MIN_W - FGripLeftW > FGripW - COL_MIN_W then Exit;
      D := EnsureRange(D, COL_MIN_W - FGripLeftW, FGripW - COL_MIN_W);
      FPane.SetColumnWidth(TPlColumn(FGripLeft), FGripLeftW + D);
      FPane.SetColumnWidth(TPlColumn(FGrip), FGripW - D);
    end
    else
      FPane.SetColumnWidth(TPlColumn(FGrip), Math.Min(FGripMax, FGripW - D));
    Exit;
  end;
  Col := ColAt(X, Grip);
  if Grip >= 0 then Cursor := crHSplit else Cursor := crDefault;
  if Grip >= 0 then Col := -1;
  if Col <> FHotCol then
  begin
    FHotCol := Col;
    Invalidate;
  end;
end;

procedure TPlColumnHeader.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Col, Grip, I, X0, Spare: Integer;
  R: TPlColRects;
begin
  Spare := 0;
  inherited MouseDown(Button, Shift, X, Y);
  FDownCol := -1;
  if Button = mbRight then
  begin
    FPane.PopupColumnMenu;
    Exit;
  end;
  if Button <> mbLeft then Exit;
  Col := ColAt(X, Grip);
  FGripWide := False;
  FGripMoved := False;
  if (Grip < 0) and MouseFromTouch then
  begin
    { a finger takes the edge from further away }
    ColAt(X, Grip, S(TOUCH_EDGE_REACH));
    FGripWide := Grip >= 0;
  end;
  if Grip >= 0 then
  begin
    { from the width as it is shown (it may be squeezed), and at most as
      much wider as the title can give }
    FGrip := Grip;
    FGripX := X;
    FGripW := FPane.FColWidth[TPlColumn(Grip)];
    FGripMax := FGripW;
    R := Rects(X0);
    FGripLeft := -1;
    for I := 0 to High(R) do
    begin
      if Ord(R[I].Col) = Grip then
      begin
        FGripW := Round(R[I].W / UIScale);
        if (I > 0) and (R[I - 1].Col in COL_RESIZABLE) then
        begin
          FGripLeft := Ord(R[I - 1].Col);
          FGripLeftW := Round(R[I - 1].W / UIScale);
        end;
      end;
      if R[I].Col = pcTitle then Spare := Math.Max(0, R[I].W - S(COL_TITLE_MIN_W));
    end;
    FGripMax := FGripW + Round(Spare / UIScale);
  end
  else
    FDownCol := Col;
end;

procedure TPlColumnHeader.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Col, Grip: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if FGrip >= 0 then
  begin
    FGrip := -1;
    if FGripWide and not FGripMoved then
    begin
      { a tap beside an edge: a click on the column under the finger }
      Col := ColAt(X, Grip);
      if Col >= 0 then FPane.SortByColumn(TPlColumn(Col));
      Exit;
    end;
    FPane.NotifyView;
    Exit;
  end;
  Col := ColAt(X, Grip);
  if (Col >= 0) and (Col = FDownCol) then FPane.SortByColumn(TPlColumn(Col));
  FDownCol := -1;
end;

procedure TPlColumnHeader.MouseLeave;
begin
  inherited MouseLeave;
  if FGrip < 0 then Cursor := crDefault;
  if FHotCol >= 0 then
  begin
    FHotCol := -1;
    Invalidate;
  end;
end;

{ ---- the columns ---- }

function TPlaylistPane.ColumnTitle(C: TPlColumn): string;
begin
  Result := COL_TITLES[C];
end;

function TPlaylistPane.SuffixShows(const ATag: string): Boolean;
begin
  Result := Pos('%' + LowerCase(ATag) + '%', LowerCase(FDateSuffix)) > 0;
end;

function TPlaylistPane.ShownColumns: TPlColumnSet;
begin
  Result := FColVisible + [pcNumber, pcTitle];
  if FDateSuffix <> '' then
  begin
    if SuffixShows(MASTER_TAG_REGISTRY[tiAdded].TagStr) then Include(Result, pcAdded);
    if SuffixShows(MASTER_TAG_REGISTRY[tiLastPlayed].TagStr) then Include(Result, pcLastPlayed);
  end;
end;

{ a column that is shown or sorted by needs the library's date added or the
  play statistics }
function TPlaylistPane.NeedsStats: Boolean;
const
  STAT_COLS = [pcPlays, pcLastPlayed, pcAdded];
begin
  Result := (ShownColumns * STAT_COLS <> []) or (FSortCol in STAT_COLS) or (FSortCol2 in STAT_COLS);
end;

procedure TPlaylistPane.FillStats;
var
  I: Integer;
  T: TTrackInfo;
  St: PUserTrackStats;
begin
  T := Default(TTrackInfo);
  for I := 0 to FCount - 1 do
  begin
    KeepWindowAlive;
    FEntries[I].Plays := 0;
    FEntries[I].LastPlayed := 0;
    FEntries[I].Added := 0;
    if not (Assigned(FOnLookup) and FOnLookup(FEntries[I].FilePath, T)) then Continue;
    FEntries[I].Added := T.DateAdded;
    if UserStatsManager = nil then Continue;
    St := UserStatsManager.PeekStats(T.PrimaryFingerprint);
    if (St = nil) and (T.FallbackFingerprint <> '') then St := UserStatsManager.PeekStats(T.FallbackFingerprint);
    if St = nil then Continue;
    FEntries[I].Plays := St^.PlayCount;
    FEntries[I].LastPlayed := St^.LastPlayed;
  end;
end;

function TPlaylistPane.ColumnText(E: Integer; C: TPlColumn): string;
var
  D: TPlEntry;

  function DateText(AUnix: Int64): string;
  begin
    if AUnix > 0 then Result := FormatDateTime('dd mmm yyyy', UnixToDateTime(AUnix, False)) else Result := '';
  end;

begin
  Result := '';
  if (E < 0) or (E >= FCount) then Exit;
  D := FEntries[E];
  case C of
    pcNumber: Result := DisplayNumber(E);
    pcTitle: Result := D.TitleText;
    pcArtist: Result := FormatTagString(D.Artist, 0, ', ');
    pcAlbum: Result := D.Album;
    pcAlbumArtist: Result := FormatTagString(D.AlbumArtist, 0, ', ');
    pcYear: if D.Year > 0 then Result := IntToStr(D.Year);
    pcGenre: Result := FormatTagString(D.Genre, 0, ', ');
    pcFormat:
      if D.SampleRate > 0 then
      begin
        if IsDSDFile(D.FilePath) then Result := 'DSD' + IntToStr(D.SampleRate div 44100)
        else if D.BitDepth > 0 then Result := Format('%d/%s', [D.BitDepth, FormatFloat('0.#', D.SampleRate / 1000)])
        else Result := FormatFloat('0.#', D.SampleRate / 1000) + ' kHz';
      end;
    pcPlays: if D.Plays > 0 then Result := IntToStr(D.Plays);
    pcLastPlayed: Result := DateText(D.LastPlayed);
    pcAdded: Result := DateText(D.Added);
    pcTime: Result := D.DurationStr;
  else
    ;
  end;
end;

function TPlaylistPane.ColumnRects(AWidth: Integer): TPlColRects;
var
  Cols: TPlColumnSet;
  C: TPlColumn;
  I, N, X, Fixed, Flex, FlexMin, Room, TitleW: Integer;
  Scale: Double;

  function WidthOf(ACol: TPlColumn): Integer;
  begin
    if ACol = pcRating then Result := Round(StarsWidth) + S(20)
    else if ACol in COL_RESIZABLE then Result := Math.Max(S(COL_MIN_W), Round(S(FColWidth[ACol]) * Scale))
    else Result := S(FColWidth[ACol]);
  end;

begin
  Result := nil;
  Cols := ShownColumns;
  I := 0;
  { When the columns do not fit beside the title's least width, those with a
    width of their own are all made narrower by the same part (for the
    picture only: the widths chosen stay). Columns are left out only when
    even their least widths do not fit. So a column switched on is always
    seen, and nothing disappears while a width is dragged. }
  repeat
    Scale := 1;
    Fixed := 0;
    Flex := 0;
    FlexMin := 0;
    for C := Low(TPlColumn) to High(TPlColumn) do
      if (C in Cols) and (C <> pcTitle) then
      begin
        if C in COL_RESIZABLE then
        begin
          Inc(Flex, S(FColWidth[C]));
          Inc(FlexMin, S(COL_MIN_W));
        end
        else
          Inc(Fixed, WidthOf(C));
      end;
    Room := AWidth - Fixed - S(COL_TITLE_MIN_W);
    if Flex <= Room then Break;
    if FlexMin <= Room then
    begin
      Scale := Room / Flex;
      Break;
    end;
    { too narrow for all of them: the next column of the drop order goes }
    while (I <= High(COL_DROP_ORDER)) and not (COL_DROP_ORDER[I] in Cols) do Inc(I);
    if I > High(COL_DROP_ORDER) then Break;
    Exclude(Cols, COL_DROP_ORDER[I]);
  until False;
  TitleW := AWidth - Fixed;
  for C := Low(TPlColumn) to High(TPlColumn) do
    if (C in Cols) and (C in COL_RESIZABLE) then Dec(TitleW, WidthOf(C));
  if TitleW < S(COL_MIN_W) then TitleW := S(COL_MIN_W);
  SetLength(Result, Ord(High(TPlColumn)) + 1);
  N := 0;
  X := 0;
  for C := Low(TPlColumn) to High(TPlColumn) do
    if C in Cols then
    begin
      Result[N].Col := C;
      Result[N].X := X;
      if C = pcTitle then Result[N].W := TitleW else Result[N].W := WidthOf(C);
      Inc(X, Result[N].W);
      Inc(N);
    end;
  SetLength(Result, N);
end;

{ "artist:190:1;album:210:0;..." - every column but the number and the
  title: its width and whether it is shown }
function TPlaylistPane.FlatColsText: string;
var
  C: TPlColumn;
  IsDefault: Boolean;
begin
  Result := '';
  IsDefault := FColVisible = COL_DEFAULT_VISIBLE;
  for C := pcArtist to High(TPlColumn) do
  begin
    if FColWidth[C] <> COL_DEFAULT_W[C] then IsDefault := False;
    if Result <> '' then Result := Result + ';';
    Result := Result + COL_IDS[C] + ':' + IntToStr(FColWidth[C]) + ':' + IntToStr(Ord(C in FColVisible));
  end;
  if IsDefault then Result := '';
end;

{ "artist,0;album,1" - the column sorted by and the one before it, each with
  1 when reversed }
function TPlaylistPane.FlatSortText: string;
begin
  if (FSortCol = pcNumber) and not FSortRev then Exit('');
  Result := COL_IDS[FSortCol] + ',' + IntToStr(Ord(FSortRev)) + ';' +
    COL_IDS[FSortCol2] + ',' + IntToStr(Ord(FSortRev2));
end;

procedure TPlaylistPane.SetFlatLayout(const ACols, ASort: string);
var
  Parts, F: TStringArray;
  C: TPlColumn;
  I: Integer;

  function ColOf(const AId: string; out ACol: TPlColumn): Boolean;
  var
    K: TPlColumn;
  begin
    for K := Low(TPlColumn) to High(TPlColumn) do
      if COL_IDS[K] = AId then
      begin
        ACol := K;
        Exit(True);
      end;
    Result := False;
  end;

begin
  FColVisible := COL_DEFAULT_VISIBLE;
  for C := Low(TPlColumn) to High(TPlColumn) do FColWidth[C] := COL_DEFAULT_W[C];
  FSortCol := pcNumber;
  FSortCol2 := pcNumber;
  FSortRev := False;
  FSortRev2 := False;
  if ACols <> '' then
  begin
    Parts := ACols.Split([';']);
    for I := 0 to High(Parts) do
    begin
      F := Parts[I].Split([':']);
      if (Length(F) <> 3) or not ColOf(F[0], C) or (C in [pcNumber, pcTitle]) then Continue;
      if C in COL_RESIZABLE then FColWidth[C] := EnsureRange(StrToIntDef(F[1], COL_DEFAULT_W[C]), COL_MIN_W, COL_MAX_W);
      if F[2] = '1' then Include(FColVisible, C) else Exclude(FColVisible, C);
    end;
  end;
  if ASort <> '' then
  begin
    Parts := ASort.Split([';']);
    for I := 0 to Math.Min(1, High(Parts)) do
    begin
      F := Parts[I].Split([',']);
      if (Length(F) <> 2) or not ColOf(F[0], C) then Continue;
      if I = 0 then
      begin
        FSortCol := C;
        FSortRev := F[1] = '1';
      end
      else
      begin
        FSortCol2 := C;
        FSortRev2 := F[1] = '1';
      end;
    end;
  end;
  if FColHead <> nil then FColHead.Invalidate;
end;

procedure TPlaylistPane.NotifyView;
begin
  if Assigned(FOnViewChange) and not FDemo then FOnViewChange(Self);
end;

procedure TPlaylistPane.SetColumnWidth(C: TPlColumn; AWidth: Integer);
begin
  AWidth := EnsureRange(AWidth, COL_MIN_W, COL_MAX_W);
  if not (C in COL_RESIZABLE) or (FColWidth[C] = AWidth) then Exit;
  FColWidth[C] := AWidth;
  FColHead.Invalidate;
  List.Invalidate;
end;

procedure TPlaylistPane.ToggleColumn(C: TPlColumn);
begin
  if C in [pcNumber, pcTitle] then Exit;
  if C in FColVisible then Exclude(FColVisible, C) else Include(FColVisible, C);
  if NeedsStats then FillStats;
  FColHead.Invalidate;
  List.Invalidate;
  NotifyView;
end;

procedure TPlaylistPane.ColMenuClick(Sender: TObject);
begin
  ToggleColumn(TPlColumn(EnsureRange(TAuMenuItem(Sender).Tag, 0, Ord(High(TPlColumn)))));
end;

procedure TPlaylistPane.PopupColumnMenu;
var
  C: TPlColumn;
  It: TAuMenuItem;
begin
  FColMenu.Free;
  FColMenu := TAuMenu.Create;
  for C := pcArtist to High(TPlColumn) do
  begin
    It := FColMenu.Add(ColumnTitle(C), @ColMenuClick);
    It.Tag := Ord(C);
    It.Checked := C in FColVisible;
  end;
  FColMenu.PopupAtCursor;
end;

procedure TPlaylistPane.SortByColumn(C: TPlColumn);
begin
  if C = FSortCol then FSortRev := not FSortRev
  else
  begin
    { the column sorted by until now decides among equal values }
    FSortCol2 := FSortCol;
    FSortRev2 := FSortRev;
    FSortCol := C;
    FSortRev := False;
  end;
  Resort;
end;

{ the entries in the order of the sort as it is now; the selected tracks
  stay selected, the playing track stays the playing track }
procedure TPlaylistPane.Resort;
const
  MAX_RESELECT = 500;
var
  Sel: TIntArray;
  Ids: array of Integer;
  I, E, R: Integer;
begin
  Screen.Cursor := crHourGlass;
  try
    Sel := SelectedEntries;
    Ids := nil;
    SetLength(Ids, Math.Min(Length(Sel), MAX_RESELECT));
    for I := 0 to High(Ids) do Ids[I] := FEntries[Sel[I]].Id;
    ApplySort;
    Rebuild;
    for I := 0 to High(Ids) do
    begin
      E := IndexOfId(Ids[I]);
      if I = 0 then SelectEntry(E, True, False)
      else
      begin
        R := RowOfEntry(E);
        if R >= 0 then List.Selected[R] := True;
      end;
    end;
    FColHead.Invalidate;
  finally
    Screen.Cursor := crDefault;
  end;
  Changed;
  NotifyView;
end;

{ a track of a flat list: one text per column }
procedure TPlaylistPane.DrawFlatRow(G: TGfx; E: Integer; X, Y, W, H: Single);
var
  R: TPlColRects;
  I: Integer;
  F, BF: TGfxFont;
  Fg, Dim: TARGB;
  Playing: Boolean;
  CX, CW: Single;
begin
  Playing := E = FPlaying;
  if Playing then Fg := clAccentText else Fg := clText;
  if Playing then Dim := clAccentText else Dim := clTextDim;
  F := UIFont(List.TextSize);
  BF := UIFont(List.TextSize, True);
  FFlatStarsX := -100000;
  R := ColumnRects(Round(W));
  for I := 0 to High(R) do
  begin
    CX := X + R[I].X;
    CW := R[I].W;
    case R[I].Col of
      pcTitle:
        begin
          if Playing then
          begin
            DrawIcon(G, icPlay, CX + S(5), Y + H / 2, H * 0.42, clAccentText);
            CX := CX + S(16);
            CW := CW - S(16);
          end;
          if Playing then G.Text(FEntries[E].TitleText, CX, Y, CW - S(12), H, BF, Fg, 0, 1)
          else G.Text(FEntries[E].TitleText, CX, Y, CW - S(12), H, F, Fg, 0, 1);
        end;
      pcRating:
        begin
          FFlatStarsX := R[I].X;
          DrawStars(G, CX, Y + H / 2, Round(List.ItemHeight * 0.52), FEntries[E].Rating,
            IfC(Playing, clAccentText, clTextDim));
        end;
      pcTime: G.Text(FEntries[E].DurationStr, CX, Y, CW, H, F, Dim, 2, 1);
    else
      G.Text(ColumnText(E, R[I].Col), CX, Y, CW - S(12), H, F, Dim, 0, 1);
    end;
  end;
end;
constructor TPlaylistPane.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crBg;
  FPlaying := -1;
  FLastAdded := -1;
  FGroupMode := gmAlbum;
  FCollapsed := TStringList.Create;
  FCollapsed.Sorted := True;
  FCollapsed.Duplicates := dupIgnore;
  FCollapsed.CaseSensitive := False;
  FThumbs := TStringList.Create;
  FThumbs.Sorted := True;
  FThumbs.Duplicates := dupIgnore;
  FTop := TAuPanel.Create(Self);
  FTop.Parent := Self;
  FTop.Align := alTop;
  FTop.Height := S(50);
  FTop.OnResize := @TopResize;
  { the heading row of a flat list, between the buttons and the list }
  FColHead := TPlColumnHeader.Create(Self);
  FColHead.Parent := Self;
  FColHead.Top := FTop.Height;
  FColHead.Align := alTop;
  FColHead.Height := S(COL_HEAD_H);
  FColHead.Visible := False;
  TPlColumnHeader(FColHead).FPane := Self;
  SetFlatLayout('', '');
  BtnPlaylist := TAuDropButton.Create(Self);
  BtnPlaylist.Parent := FTop;
  BtnPlaylist.Caption := 'Default Playlist';
  BtnPlaylist.TextSize := 14;
  BtnPlaylist.Hint := 'Choose a playlist';
  BtnPlaylist.ShowHint := True;
  BtnView := TAuButton.Create(Self);
  BtnView.Parent := FTop;
  BtnView.Kind := bkFlat;
  BtnView.Icon := icAlbum;
  BtnView.Caption := 'By album';
  BtnView.Hint := 'View: grouping and layout of this playlist';
  BtnView.ShowHint := True;
  BtnSort := TAuButton.Create(Self);
  BtnSort.Parent := FTop;
  BtnSort.Kind := bkFlat;
  BtnSort.Caption := SortName(psAdded);
  BtnSort.Hint := 'Sort: the order of the albums in this playlist';
  BtnSort.ShowHint := True;
  { the direction of that order, a button of its own }
  BtnSortDir := TAuIconButton.Create(Self);
  BtnSortDir.Parent := FTop;
  BtnSortDir.Icon := icSortAsc;
  BtnSortDir.IconSize := 16;
  BtnSortDir.Style := ibRect;
  BtnSortDir.Hint := 'Reverse the order';
  BtnSortDir.ShowHint := True;
  BtnEdit := TAuIconButton.Create(Self);
  BtnEdit.Parent := FTop;
  BtnEdit.Icon := icEdit;
  BtnEdit.IconSize := 16;
  BtnEdit.Hint := 'Playlist Manager (Alt+P)';
  BtnEdit.ShowHint := True;
  List := TAuGroupList.Create(Self);
  List.Parent := Self;
  List.Align := alClient;
  List.BorderSpacing.Right := S(4);
  List.BorderSpacing.Bottom := S(4);
  List.DragEnabled := True;
  List.OnDrawRow := @DrawRow;
  List.OnDrawLead := @DrawLead;
  List.OnRowText := @RowText;   // type-ahead as in the library tree
  List.OnRowClick := @RowClick;
  List.OnCollapseChange := @ListCollapse;
  List.OnResize := @ListResize;
  List.EmptyText := PL_EMPTY_TEXT;
  BtnPlaylist.TabOrder := 0;
  BtnSortDir.TabOrder := 1;
  BtnSort.TabOrder := 2;
  BtnView.TabOrder := 3;
  BtnEdit.TabOrder := 4;
  TopResize(nil);
end;

destructor TPlaylistPane.Destroy;
begin
  ClearThumbCache;
  FColMenu.Free;
  FThumbs.Free;
  FCollapsed.Free;
  inherited Destroy;
end;

procedure TPlaylistPane.TopResize(Sender: TObject);
var
  VW, Right: Integer;
begin
  if (BtnPlaylist = nil) or (BtnView = nil) or (BtnSort = nil) or (BtnSortDir = nil) or (BtnEdit = nil) then Exit;
  BtnEdit.SetBounds(FTop.Width - S(10) - S(34), S(9), S(34), S(34));
  VW := BtnView.PreferredWidth;
  BtnView.SetBounds(BtnEdit.Left - S(4) - VW, S(10), VW, S(32));
  Right := BtnView.Left;
  { the sort buttons (direction, order): for grouped lists, where the pane
    is wide enough for them }
  BtnSort.Visible := (FGroupMode <> gmFlat) and (FTop.Width >= S(SORT_BUTTON_MIN_PANE_W));
  BtnSortDir.Visible := BtnSort.Visible;
  if BtnSort.Visible then
  begin
    { the arrow belongs to the order's name: both are narrower than a button
      of their kind, so the two stand as close as an icon and its caption }
    VW := BtnSort.PreferredWidth - S(16);
    BtnSort.SetBounds(Right - S(4) - VW, S(10), VW, S(32));
    BtnSortDir.SetBounds(BtnSort.Left - S(20), S(10), S(20), S(32));
    Right := BtnSortDir.Left;
  end;
  BtnPlaylist.SetBounds(S(10), S(10), Math.Max(S(60), Right - S(18)), S(32));
end;

procedure TPlaylistPane.Changed;
begin
  if Assigned(FOnChange) and not FDemo then FOnChange(Self);
end;

{ ---- entries ---- }

function TPlaylistPane.TrackOf(const E: TPlEntry): TTrackInfo;
begin
  Result := Default(TTrackInfo);
  Result.FilePath := E.FilePath;
  Result.FolderDir := E.FolderDir;
  Result.Title := E.Title;
  Result.Artist := E.Artist;
  Result.AlbumArtist := E.AlbumArtist;
  Result.Album := E.Album;
  Result.Genre := E.Genre;
  Result.TrackNumber := E.TrackNum;
  Result.DiscNumber := E.DiscNum;
  Result.DurationStr := E.DurationStr;
  Result.Year := E.Year;
  Result.DateStr := E.DateStr;
  Result.SampleRate := E.SampleRate;
  Result.BitDepth := E.BitDepth;
  Result.FileNameOnly := ExtractFileName(E.FilePath);
  Result.Work := E.Work;
end;

{ the rating of a track by its tags (RowRatingFingerprint) }
function TPlaylistPane.RatingOf(const E: TPlEntry): Integer;
var
  Row: TTrackNodeData;
  P: PUserTrackStats;
begin
  Result := 0;
  if UserStatsManager = nil then Exit;
  Row := Default(TTrackNodeData);
  Row.Title := E.Title;
  Row.Artist := E.Artist;
  Row.AlbumArtist := E.AlbumArtist;
  Row.Album := E.Album;
  P := UserStatsManager.PeekStats(RowRatingFingerprint(Row));
  if P <> nil then Result := EnsureRange(P^.Rating, 0, 5);
end;

function TPlaylistPane.EntryFromTrack(const T: TTrackInfo): TPlEntry;
begin
  Result := Default(TPlEntry);
  Result.FilePath := T.FilePath;
  Result.Title := CleanTag(T.Title);
  Result.Artist := CleanTag(T.Artist);
  Result.AlbumArtist := CleanTag(T.AlbumArtist);
  Result.Album := CleanTag(T.Album);
  Result.Genre := CleanTag(T.Genre);
  Result.Work := CleanTag(T.Work);
  Result.Year := T.Year;
  Result.TrackNum := T.TrackNumber;
  Result.DiscNum := T.DiscNumber;
  Result.DurationStr := T.DurationStr;
  Result.DateStr := T.DateStr;
  Result.SampleRate := T.SampleRate;
  Result.BitDepth := T.BitDepth;
  Result.FolderDir := ExcludeTrailingPathDelimiter(ExtractFilePath(T.FilePath));
  if Result.Title = '' then Result.Title := ChangeFileExt(ExtractFileName(T.FilePath), '');
  if Result.AlbumArtist = '' then Result.AlbumArtist := Result.Artist;
  Result.Seconds := TimeStrToSecs(Result.DurationStr);
  Result.GroupKey := LowerCase(Result.Album + '|' + Result.FolderDir);
  Result.Rating := RatingOf(Result);
end;

function TPlaylistPane.ReadEntry(const APath: string): TPlEntry;
var
  M: TAudioMetadata;
  T: TTrackInfo;
begin
  { a library track: its record, no disk access }
  if Assigned(FOnLookup) and FOnLookup(APath, T) then Exit(EntryFromTrack(T));
  T := Default(TTrackInfo);
  T.FilePath := APath;
  if TryReadTrackMetadata(APath, M) then
  begin
    T.Title := M.Title;
    T.Artist := NormalizeSemicolons(M.Artist);
    T.AlbumArtist := NormalizeSemicolons(M.AlbumArtist);
    T.Album := M.Album;
    T.Genre := M.Genre;
    T.Work := M.Work;
    T.Year := M.Year;
    T.TrackNumber := M.TrackNumber;
    T.DiscNumber := M.DiscNumber;
    T.DurationStr := M.DurationStr;
    T.SampleRate := M.SampleRate;
    T.BitDepth := M.BitDepth;
  end;
  { without tags: the folder name as album, Unknown Artist }
  if T.Album = '' then T.Album := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(APath)));
  if T.Artist = '' then T.Artist := LBL_UNKNOWN_ARTIST;
  Result := EntryFromTrack(T);
end;

procedure TPlaylistPane.InsertEntries(const New_: array of TPlEntry; N, InsertAt: Integer);
var
  I, MaxSeq, FirstId: Integer;
begin
  if N = 0 then Exit;
  { a sorted list finds the place itself: added last in the stored order }
  if (InsertAt < 0) or (InsertAt > FCount) or SortActive then InsertAt := FCount;
  MaxSeq := -1;
  for I := 0 to FCount - 1 do
    if FEntries[I].Seq > MaxSeq then MaxSeq := FEntries[I].Seq;
  SetLength(FEntries, FCount + N);
  for I := FCount - 1 downto InsertAt do FEntries[I + N] := FEntries[I];
  for I := 0 to N - 1 do
  begin
    Inc(FNextId);
    FEntries[InsertAt + I] := New_[I];
    FEntries[InsertAt + I].Id := FNextId;
    FEntries[InsertAt + I].Seq := MaxSeq + 1 + I;
  end;
  FirstId := FNextId - N + 1;
  if (FPlaying >= InsertAt) then Inc(FPlaying, N);
  Inc(FCount, N);
  if SortActive then ApplySort else RenumberSeq;
  FLastAdded := IndexOfId(FirstId);
  Rebuild;
  Changed;
end;

procedure TPlaylistPane.Clear;
begin
  FCount := 0;
  SetLength(FEntries, 0);
  FPlaying := -1;
  FLastAdded := -1;
  FWantTop := '';
  FDemo := False;
  Rebuild;
  Changed;
end;

procedure TPlaylistPane.AddFiles(Paths: TStrings; InsertAt: Integer);
var
  I, N: Integer;
  New_: array of TPlEntry;
begin
  if FDemo then Clear;
  if (Paths = nil) or (Paths.Count = 0) or FReadOnly then Exit;
  SetLength(New_, Paths.Count);
  N := 0;
  for I := 0 to Paths.Count - 1 do
    if IsValidMusicFile(Paths[I]) then
    begin
      KeepWindowAlive;            // (each file is read from its drive)
      New_[N] := ReadEntry(Paths[I]);
      Inc(N);
    end;
  InsertEntries(New_, N, InsertAt);
end;

procedure TPlaylistPane.AddTracks(Tracks: TTrackList; InsertAt: Integer);
var
  I: Integer;
  New_: array of TPlEntry;
begin
  if FDemo then Clear;
  if (Tracks = nil) or (Tracks.Count = 0) then Exit;
  SetLength(New_, Tracks.Count);
  for I := 0 to Tracks.Count - 1 do
  begin
    KeepWindowAlive;
    New_[I] := EntryFromTrack(Tracks[I]^);
    New_[I].WorkKnown := True;          // (a library record)
  end;
  InsertEntries(New_, Tracks.Count, InsertAt);
end;

procedure TPlaylistPane.LoadEntries(const AEntries: TPlaylistEntries);
var
  I: Integer;
begin
  FDemo := False;
  FPlaying := -1;
  FCount := Length(AEntries);
  SetLength(FEntries, FCount);
  for I := 0 to FCount - 1 do
  begin
    KeepWindowAlive;
    FEntries[I] := EntryFromTrack(TrackFromEntry(AEntries[I]));
    Inc(FNextId);
    FEntries[I].Id := FNextId;
    FEntries[I].Seq := I;
  end;
  FLastAdded := -1;
  FWantTop := '';
  if SortActive then ApplySort;
  Rebuild;
end;

function TPlaylistPane.ToEntries: TPlaylistEntries;
var
  I: Integer;
  Order: TIntArray;
begin
  { always in the order added, however the list is sorted }
  Result := nil;
  SetLength(Result, FCount);
  if SortActive then
  begin
    Order := SeqOrder;
    for I := 0 to FCount - 1 do Result[I] := uPlaylistRows.EntryFromTrack(TrackOf(FEntries[Order[I]]));
  end
  else
    for I := 0 to FCount - 1 do Result[I] := uPlaylistRows.EntryFromTrack(TrackOf(FEntries[I]));
end;

procedure TPlaylistPane.RemoveEntries(const Idx: TIntArray);
var
  Del: array of Boolean;
  I, N, NewPlaying: Integer;
begin
  if (Length(Idx) = 0) or FReadOnly then Exit;
  SetLength(Del, FCount);
  for I := 0 to High(Idx) do
    if (Idx[I] >= 0) and (Idx[I] < FCount) then Del[Idx[I]] := True;
  N := 0;
  NewPlaying := -1;
  for I := 0 to FCount - 1 do
    if not Del[I] then
    begin
      if I = FPlaying then NewPlaying := N;
      FEntries[N] := FEntries[I];
      Inc(N);
    end;
  FCount := N;
  SetLength(FEntries, N);
  FPlaying := NewPlaying;
  if not SortActive then RenumberSeq;
  Rebuild;
  Changed;
end;

procedure TPlaylistPane.MoveEntries(const Idx: TIntArray; InsertAt: Integer);
var
  Sel: array of Boolean;
  Moved, Rest: array of TPlEntry;
  I, NM, NR, At, PlayingId: Integer;
begin
  if (Length(Idx) = 0) or FReadOnly or SortActive then Exit;
  if (InsertAt < 0) or (InsertAt > FCount) then InsertAt := FCount;
  SetLength(Sel, FCount);
  for I := 0 to High(Idx) do
    if (Idx[I] >= 0) and (Idx[I] < FCount) then Sel[Idx[I]] := True;
  SetLength(Moved, FCount);
  SetLength(Rest, FCount);
  NM := 0;
  NR := 0;
  At := 0;
  for I := 0 to FCount - 1 do
  begin
    if I = InsertAt then At := NR;
    if Sel[I] then
    begin
      Moved[NM] := FEntries[I];
      Inc(NM);
    end
    else
    begin
      Rest[NR] := FEntries[I];
      Inc(NR);
    end;
  end;
  if InsertAt >= FCount then At := NR;
  if NM = 0 then Exit;
  if FPlaying >= 0 then PlayingId := FEntries[FPlaying].Id else PlayingId := 0;
  for I := 0 to At - 1 do FEntries[I] := Rest[I];
  for I := 0 to NM - 1 do FEntries[At + I] := Moved[I];
  for I := At to NR - 1 do FEntries[NM + I] := Rest[I];
  if PlayingId <> 0 then FPlaying := IndexOfId(PlayingId);
  RenumberSeq;
  Rebuild;
  for I := 0 to NM - 1 do List.Selected[RowOfEntry(At + I)] := True;
  Changed;
end;

{ which copy of its file each entry is: 0 for the first (or only) one, 1 for
  the second ... }
function TPlaylistPane.CopyNumbers: TIntArray;
var
  Seen: TFPDataHashTable;
  I: Integer;
  Key: string;
  N: PtrUInt;
begin
  Result := nil;
  SetLength(Result, FCount);
  if FCount = 0 then Exit;
  Seen := TFPDataHashTable.CreateWith(FCount * 2 + 97, @RSHash);
  try
    for I := 0 to FCount - 1 do
    begin
      Key := LowerCase(FEntries[I].FilePath);
      N := PtrUInt(Seen.Items[Key]);
      Result[I] := Integer(N);
      Seen.Items[Key] := Pointer(N + 1);
    end;
  finally
    Seen.Free;
  end;
end;

{ what a row is known by in a TPlSelection: the file of its entry, and which
  copy it is when the playlist holds the file more than once }
function TPlaylistPane.SelectionKey(AEntry: Integer; const ACopies: TIntArray): string;
begin
  Result := FEntries[AEntry].FilePath;
  if ACopies[AEntry] > 0 then Result := Result + #9 + IntToStr(ACopies[AEntry]);
end;

function TPlaylistPane.TakeSelection: TPlSelection;
var
  R, E, NI, NH: Integer;
  Copies: TIntArray;
begin
  Result := Default(TPlSelection);
  Copies := CopyNumbers;
  SetLength(Result.Items, List.RowCount);
  SetLength(Result.Heads, List.RowCount);
  NI := 0;
  NH := 0;
  for R := 0 to List.RowCount - 1 do
    if List.Selected[R] then
    begin
      E := EntryOfRow(R);
      if (E < 0) or (E >= FCount) then Continue;
      if List.Kind[R] = rkHeader then
      begin
        Result.Heads[NH] := SelectionKey(E, Copies);
        Inc(NH);
      end
      else
      begin
        Result.Items[NI] := SelectionKey(E, Copies);
        Inc(NI);
      end;
    end;
  SetLength(Result.Items, NI);
  SetLength(Result.Heads, NH);
  E := EntryOfRow(List.FocusedRow);
  if (E >= 0) and (E < FCount) then
  begin
    Result.Focus := SelectionKey(E, Copies);
    Result.FocusHead := List.Kind[List.FocusedRow] = rkHeader;
  end;
  Result.Scroll := List.ScrollOffset;
end;

function TPlaylistPane.PutSelection(const ASel: TPlSelection): Integer;
var
  Items, Heads: TStringList;
  Rows: TAuRowArray;
  R, E, At, FocusRow, FocusItem: Integer;
  Copies: TIntArray;
  Key: string;

  function PathSet(const A: array of string): TStringList;
  var
    I: Integer;
  begin
    Result := TStringList.Create;
    Result.UseLocale := False;
    Result.CaseSensitive := False;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
    for I := 0 to High(A) do Result.Add(A[I]);
  end;

begin
  Result := 0;
  if (Length(ASel.Items) = 0) and (Length(ASel.Heads) = 0) then Exit;
  Items := PathSet(ASel.Items);
  Heads := PathSet(ASel.Heads);
  try
    Copies := CopyNumbers;
    Rows := nil;
    SetLength(Rows, List.RowCount);
    FocusRow := -1;
    FocusItem := -1;
    for R := 0 to List.RowCount - 1 do
    begin
      E := EntryOfRow(R);
      if (E < 0) or (E >= FCount) then Continue;
      Key := SelectionKey(E, Copies);
      if List.Kind[R] = rkHeader then
      begin
        if Heads.Find(Key, At) then begin Rows[Result] := R; Inc(Result); end;
        if ASel.FocusHead and SameText(Key, ASel.Focus) then FocusRow := R;
      end
      else
      begin
        if Items.Find(Key, At) then begin Rows[Result] := R; Inc(Result); end;
        if (FocusItem < 0) and SameText(Key, ASel.Focus) then FocusItem := R;
      end;
    end;
    if Result = 0 then Exit;
    if (FocusRow < 0) or not ASel.FocusHead then FocusRow := FocusItem;
    if FocusRow < 0 then FocusRow := Rows[0];
    SetLength(Rows, Result);
    List.RestoreSelection(Rows, FocusRow);
    { rows hidden in a collapsed group were found but are not selected }
    Result := List.SelCount;
    if Result = 0 then Exit;
    List.ScrollTo(ASel.Scroll);
  finally
    Heads.Free;
    Items.Free;
  end;
end;

function ComparePtrAsInt(A, B: Pointer): Integer;
begin
  if PtrUInt(A) < PtrUInt(B) then Result := -1
  else if PtrUInt(A) > PtrUInt(B) then Result := 1
  else Result := 0;
end;

procedure TPlaylistPane.SyncWithLibrary;
var
  I, Id, Sq: Integer;
  T: TTrackInfo;
  Changes: Boolean;
begin
  if not Assigned(FOnLookup) or FDemo then Exit;
  Changes := False;
  for I := 0 to FCount - 1 do
    if FOnLookup(FEntries[I].FilePath, T) then
    begin
      KeepWindowAlive;
      Id := FEntries[I].Id;
      Sq := FEntries[I].Seq;
      FEntries[I] := EntryFromTrack(T);
      FEntries[I].WorkKnown := True;
      FEntries[I].Id := Id;
      FEntries[I].Seq := Sq;
      Changes := True;
    end;
  { the tags a sort goes by may have changed }
  RebuildKeepingSelection(True);
  if Changes then Changed;
end;

{ the rows again from the entries: the rows that were selected are selected
  again, the focus is where it was and the list is scrolled as before. Rows
  are known by the id of their entry (a header: of its first entry), so an
  order changed in between does no harm. ASortAgain: the entries are put
  into the order of the sort first - after the selection was read, as the
  rows still point at the entries in their present order. }
procedure TPlaylistPane.RebuildKeepingSelection(ASortAgain: Boolean = False);
var
  Items, Heads: TFPList;      // ids (above 0) as pointers, sorted
  FocusId, Scroll, R, E, N, At: Integer;
  FocusHead: Boolean;
  Rows: TAuRowArray;
  NewFocus: Integer;

  function IdOfRow(ARow: Integer): Integer;
  var
    Entry: Integer;
  begin
    Entry := EntryOfRow(ARow);
    if (Entry < 0) or (Entry >= FCount) then Result := -1 else Result := FEntries[Entry].Id;
  end;

  function Has(AList: TFPList; AId: Integer): Boolean;
  var
    Lo, Hi, Mid: Integer;
  begin
    Lo := 0;
    Hi := AList.Count - 1;
    while Lo <= Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if PtrUInt(AList[Mid]) = PtrUInt(AId) then Exit(True);
      if PtrUInt(AList[Mid]) < PtrUInt(AId) then Lo := Mid + 1 else Hi := Mid - 1;
    end;
    Result := False;
  end;

begin
  Items := TFPList.Create;
  Heads := TFPList.Create;
  try
    for R := 0 to List.RowCount - 1 do
      if List.Selected[R] then
      begin
        E := IdOfRow(R);
        if E < 0 then Continue;
        if List.Kind[R] = rkHeader then Heads.Add(Pointer(PtrUInt(E))) else Items.Add(Pointer(PtrUInt(E)));
      end;
    Items.Sort(@ComparePtrAsInt);
    Heads.Sort(@ComparePtrAsInt);
    FocusId := IdOfRow(List.FocusedRow);
    FocusHead := (List.FocusedRow >= 0) and (List.Kind[List.FocusedRow] = rkHeader);
    Scroll := List.ScrollOffset;

    if ASortAgain and SortActive then ApplySort;
    Rebuild;

    Rows := nil;
    SetLength(Rows, List.RowCount);
    N := 0;
    NewFocus := -1;
    At := -1;
    for R := 0 to List.RowCount - 1 do
    begin
      E := IdOfRow(R);
      if E < 0 then Continue;
      if List.Kind[R] = rkHeader then
      begin
        if Has(Heads, E) then begin Rows[N] := R; Inc(N); end;
        if FocusHead and (E = FocusId) then NewFocus := R;
      end
      else
      begin
        if Has(Items, E) then begin Rows[N] := R; Inc(N); end;
        if E = FocusId then At := R;
      end;
    end;
    { the focus on a header whose group now begins with another track: on
      the track itself }
    if (NewFocus < 0) or not FocusHead then
      if At >= 0 then NewFocus := At;
    SetLength(Rows, N);
    List.RestoreSelection(Rows, NewFocus);
    List.ScrollTo(Scroll);
  finally
    Heads.Free;
    Items.Free;
  end;
end;

procedure TPlaylistPane.RefreshRatings;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do FEntries[I].Rating := RatingOf(FEntries[I]);
  BuildTexts;
  List.Invalidate;
  if Assigned(FOnRatingChange) then FOnRatingChange(Self);
end;

procedure TPlaylistPane.RateEntries(const Idx: TIntArray; ARating: Integer);
var
  I: Integer;
  Rw: TTrackNodeData;
  Fp: string;
begin
  if (UserStatsManager = nil) or FDemo then Exit;
  for I := 0 to High(Idx) do
  begin
    if (Idx[I] < 0) or (Idx[I] >= FCount) then Continue;
    Rw := Default(TTrackNodeData);
    Rw.Title := FEntries[Idx[I]].Title;
    Rw.Artist := FEntries[Idx[I]].Artist;
    Rw.AlbumArtist := FEntries[Idx[I]].AlbumArtist;
    Rw.Album := FEntries[Idx[I]].Album;
    Fp := RowRatingFingerprint(Rw);
    if Fp <> '' then UserStatsManager.SetRating(Fp, EnsureRange(ARating, 0, 5));
  end;
  RefreshRatings;
end;

{ ---- view ---- }

procedure TPlaylistPane.SetView(AGroupMode: TGroupingMode; const AHeaderFmt, ATrackFmt,
  ADateSuffix: string; AReadOnly: Boolean; ASortMode: TPlSortMode; ASortReverse: Boolean);
begin
  FGroupMode := AGroupMode;
  FSortMode := ASortMode;
  FSortReverse := ASortReverse;
  { the arrow points down while the order is reversed }
  if ASortReverse then BtnSortDir.Icon := icSortDesc else BtnSortDir.Icon := icSortAsc;
  BtnSortDir.Invalidate;
  FHeaderFmt := AHeaderFmt;
  FTrackFmt := ATrackFmt;
  FDateSuffix := ADateSuffix;
  FReadOnly := AReadOnly;
  BtnSort.Caption := SortName(FSortMode);
  { an auto-playlist cannot take dropped music: its own text }
  if AReadOnly then List.EmptyText := PL_AUTO_EMPTY_TEXT else List.EmptyText := PL_EMPTY_TEXT;
  List.DragEnabled := True;
  FColHead.Visible := FGroupMode = gmFlat;
  FColHead.Invalidate;
  { the view button shows the grouping in its icon and its text (the icons
    of the grouping menu) }
  case FGroupMode of
    gmFolder:
      begin
        BtnView.Caption := 'By folder';
        BtnView.Icon := icFolder;
      end;
    gmFlat:
      begin
        BtnView.Caption := 'Flat list';
        BtnView.Icon := icList;
      end;
  else
    BtnView.Caption := 'By album';
    BtnView.Icon := icAlbum;
  end;
  TopResize(nil);
end;

{ ---- the order of the groups ---- }

function TPlaylistPane.SortActive: Boolean;
begin
  if FGroupMode = gmFlat then Result := (FSortCol <> pcNumber) or FSortRev
  else Result := (FSortMode <> psAdded) or FSortReverse;
end;

function TPlaylistPane.SortName(AMode: TPlSortMode): string;
const
  NAMES: array[TPlSortMode] of string = ('Playlist order', 'Artist', 'Album', 'Year', 'Added to library');
begin
  Result := NAMES[AMode];
end;

{ the indices of the entries in the order added (ascending Seq) }
function TPlaylistPane.SeqOrder: TIntArray;
var
  I, MaxSeq, N: Integer;
  Slot: array of Integer;
begin
  Result := nil;
  SetLength(Result, FCount);
  MaxSeq := -1;
  for I := 0 to FCount - 1 do
    if FEntries[I].Seq > MaxSeq then MaxSeq := FEntries[I].Seq;
  Slot := nil;
  SetLength(Slot, MaxSeq + 1);          // 0 = no entry has this number
  for I := 0 to FCount - 1 do
    if FEntries[I].Seq >= 0 then Slot[FEntries[I].Seq] := I + 1;
  N := 0;
  for I := 0 to MaxSeq do
    if Slot[I] > 0 then
    begin
      Result[N] := Slot[I] - 1;
      Inc(N);
    end;
  { (numbers used twice would lose entries: then the order as it is) }
  if N <> FCount then
    for I := 0 to FCount - 1 do Result[I] := I;
end;

{ the order shown is the order added }
procedure TPlaylistPane.RenumberSeq;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do FEntries[I].Seq := I;
end;

{ Puts the entries in the order of the sort mode: the groups as they follow
  from the order added (tracks that follow each other with the same group
  key), sorted by the tags of their first track; the tracks of a group keep
  their order. The numbers of the order added are made gapless on the way. }
procedure TPlaylistPane.ApplySort;
type
  TSortGroup = record
    First, Count, Year: Integer;
    Artist, Album: string;
    Added: Int64;
  end;
  TFlatKey = record
    S: string;
    N: Int64;
  end;
  TFlatKeys = array of TFlatKey;
const
  FLAT_TEXT_COLS = [pcTitle, pcArtist, pcAlbum, pcAlbumArtist, pcGenre];
var
  K1, K2: TFlatKeys;
  Order, GI: TIntArray;
  Src: array of TPlEntry;
  G: array of TSortGroup;
  I, J, N, K, PlayingId: Integer;
  Key, Cur: string;
  T: TTrackInfo;

  function Cmp(const A, B: Int64): Integer;
  begin
    if A < B then Result := -1 else if A > B then Result := 1 else Result := 0;
  end;

  { what a track is sorted by in a column: a text without accents and
    capitals, or a number }
  function KeyOf(const AEntry: TPlEntry; ACol: TPlColumn): TFlatKey;

    function TextKey(const AText: string): string;
    begin
      Result := UTF8LowerCase(StripAccents(AText));
    end;

  begin
    Result.S := '';
    Result.N := 0;
    case ACol of
      pcNumber: Result.N := AEntry.Seq;
      pcTitle: Result.S := TextKey(AEntry.Title);
      pcArtist: Result.S := TextKey(AEntry.Artist);
      pcAlbum: Result.S := TextKey(AEntry.Album);
      pcAlbumArtist: Result.S := TextKey(AEntry.AlbumArtist);
      pcGenre: Result.S := TextKey(AEntry.Genre);
      pcYear: Result.N := AEntry.Year;
      pcFormat: Result.N := Int64(AEntry.SampleRate) * 64 + AEntry.BitDepth;
      pcPlays: Result.N := AEntry.Plays;
      pcLastPlayed: Result.N := AEntry.LastPlayed;
      pcAdded: Result.N := AEntry.Added;
      pcRating: Result.N := AEntry.Rating;
      pcTime: Result.N := AEntry.Seconds;
    end;
  end;

  { a year that is not known comes last, whichever way the years run }
  function YearOf(AYear: Integer; ADescending: Boolean): Int64;
  begin
    if AYear > 0 then Result := AYear
    else if ADescending then Result := -1
    else Result := High(Integer);
  end;

  { a flat list: by the column sorted by, then by the one before it }
  function FlatCompare(A, B: Integer; ACol: TPlColumn; ARev: Boolean; const AKeys: TFlatKeys): Integer;
  begin
    if ACol in FLAT_TEXT_COLS then Result := CompareStr(AKeys[A].S, AKeys[B].S)
    else Result := Cmp(AKeys[A].N, AKeys[B].N);
    if ARev then Result := -Result;
  end;

  function Before(A, B: Integer): Boolean;
  var
    C, Dir: Integer;
  begin
    if FGroupMode = gmFlat then
    begin
      C := FlatCompare(A, B, FSortCol, FSortRev, K1);
      if C = 0 then C := FlatCompare(A, B, FSortCol2, FSortRev2, K2);
      if C = 0 then C := A - B;
      Exit(C < 0);
    end;
    { the order of the menu, or its reverse: artists and albums from A, the
      oldest year first, the album added to the library last first }
    if FSortReverse then Dir := -1 else Dir := 1;
    C := 0;
    case FSortMode of
      psAdded: ;
      psArtist:
        begin
          C := Dir * AnsiCompareText(G[A].Artist, G[B].Artist);
          if C = 0 then C := Cmp(YearOf(G[A].Year, False), YearOf(G[B].Year, False));
          if C = 0 then C := AnsiCompareText(G[A].Album, G[B].Album);
        end;
      psAlbum:
        begin
          C := Dir * AnsiCompareText(G[A].Album, G[B].Album);
          if C = 0 then C := AnsiCompareText(G[A].Artist, G[B].Artist);
        end;
      psYear:
        begin
          if not FSortReverse then C := Cmp(YearOf(G[A].Year, False), YearOf(G[B].Year, False))
          else C := Cmp(YearOf(G[B].Year, True), YearOf(G[A].Year, True));
          if C = 0 then C := AnsiCompareText(G[A].Artist, G[B].Artist);
          if C = 0 then C := AnsiCompareText(G[A].Album, G[B].Album);
        end;
      psDateAdded:
        begin
          C := Dir * Cmp(G[B].Added, G[A].Added);
          if C = 0 then C := AnsiCompareText(G[A].Artist, G[B].Artist);
          if C = 0 then C := AnsiCompareText(G[A].Album, G[B].Album);
        end;
    end;
    { equal groups stay in the order added ("As added" reversed: the last
      added first) }
    if C = 0 then
    begin
      C := A - B;
      if (FSortMode = psAdded) and FSortReverse then C := -C;
    end;
    Result := C < 0;
  end;

  procedure QuickSort(L, R: Integer);
  var
    A, B, P, Tmp: Integer;
  begin
    while L < R do
    begin
      A := L;
      B := R;
      P := GI[(L + R) div 2];
      repeat
        while Before(GI[A], P) do Inc(A);
        while Before(P, GI[B]) do Dec(B);
        if A <= B then
        begin
          Tmp := GI[A];
          GI[A] := GI[B];
          GI[B] := Tmp;
          Inc(A);
          Dec(B);
        end;
      until A > B;
      if B - L < R - A then
      begin
        QuickSort(L, B);
        L := A;
      end
      else
      begin
        QuickSort(A, R);
        R := B;
      end;
    end;
  end;

begin
  if FCount = 0 then Exit;
  if (FGroupMode = gmFlat) and NeedsStats then FillStats;
  T := Default(TTrackInfo);
  if FPlaying >= 0 then PlayingId := FEntries[FPlaying].Id else PlayingId := 0;
  Order := SeqOrder;
  Src := nil;
  SetLength(Src, FCount);
  for I := 0 to FCount - 1 do
  begin
    Src[I] := FEntries[Order[I]];
    Src[I].Seq := I;
  end;
  if not SortActive then
    for I := 0 to FCount - 1 do FEntries[I] := Src[I]
  else if FGroupMode = gmFlat then
  begin
    { the tracks themselves, by the keys of the two columns }
    K1 := nil;
    K2 := nil;
    SetLength(K1, FCount);
    SetLength(K2, FCount);
    for I := 0 to FCount - 1 do
    begin
      KeepWindowAlive;
      K1[I] := KeyOf(Src[I], FSortCol);
      K2[I] := KeyOf(Src[I], FSortCol2);
    end;
    GI := nil;
    SetLength(GI, FCount);
    for I := 0 to FCount - 1 do GI[I] := I;
    QuickSort(0, FCount - 1);
    for I := 0 to FCount - 1 do FEntries[I] := Src[GI[I]];
  end
  else
  begin
    G := nil;
    SetLength(G, FCount);
    N := 0;
    Cur := '';
    for I := 0 to FCount - 1 do
    begin
      KeepWindowAlive;
      Key := PlaylistGroupKey(TrackOf(Src[I]), FGroupMode);
      if (N = 0) or (Key <> Cur) then
      begin
        Cur := Key;
        G[N] := Default(TSortGroup);
        G[N].First := I;
        G[N].Artist := Src[I].AlbumArtist;
        if G[N].Artist = '' then G[N].Artist := Src[I].Artist;
        G[N].Album := Src[I].Album;
        G[N].Year := Src[I].Year;
        Inc(N);
      end;
      Inc(G[N - 1].Count);
      { the library's date added: the latest of the group's tracks }
      if (FSortMode = psDateAdded) and Assigned(FOnLookup) and FOnLookup(Src[I].FilePath, T) and
         (T.DateAdded > G[N - 1].Added) then
        G[N - 1].Added := T.DateAdded;
    end;
    GI := nil;
    SetLength(GI, N);
    for I := 0 to N - 1 do GI[I] := I;
    QuickSort(0, N - 1);
    K := 0;
    for I := 0 to N - 1 do
      for J := G[GI[I]].First to G[GI[I]].First + G[GI[I]].Count - 1 do
      begin
        FEntries[K] := Src[J];
        Inc(K);
      end;
  end;
  if PlayingId <> 0 then FPlaying := IndexOfId(PlayingId);
end;

function TPlaylistPane.TopFile: string;
var
  E: Integer;
begin
  Result := '';
  E := EntryOfRow(List.TopRow);
  if (E >= 0) and (E < FCount) then Result := FEntries[E].FilePath;
end;

procedure TPlaylistPane.ScrollToFile(const APath: string);
var
  E, R: Integer;
begin
  FWantTop := '';
  if APath = '' then Exit;
  { before the pane is laid out the list cannot scroll: again in ListResize }
  if List.ClientHeight < S(LIST_READY_MIN_H) then
  begin
    FWantTop := APath;
    Exit;
  end;
  E := IndexOfFile(APath);
  if E < 0 then Exit;
  R := RowOfEntry(E);
  if (R >= 0) and not List.IsVisibleRow(R) then R := List.Group[R];
  if R >= 0 then List.ScrollRowToTop(R);
end;

procedure TPlaylistPane.ListResize(Sender: TObject);
begin
  if (FWantTop <> '') and (List.ClientHeight >= S(LIST_READY_MIN_H)) then ScrollToFile(FWantTop);
end;

function TPlaylistPane.HeaderTextWidth(const S: string): Integer;
begin
  Result := Round(TextWidth(S, UIFont(List.TextSize + 1, True)));
end;

{ the texts of the headers and the tracks (the formats with the library's
  date added and the play statistics) }
procedure TPlaylistPane.BuildTexts;
var
  I, J, Total, N: Integer;
  Ctx: TTrackFormatContext;
  T: TTrackInfo;
  St: PUserTrackStats;
  Fmt: string;

  procedure MetaOf(const E: TPlEntry);
  begin
    Ctx := Default(TTrackFormatContext);
    Ctx.Meta.Title := E.Title;
    Ctx.Meta.Artist := E.Artist;
    Ctx.Meta.AlbumArtist := E.AlbumArtist;
    Ctx.Meta.Album := E.Album;
    Ctx.Meta.Genre := E.Genre;
    Ctx.Meta.TrackNumber := E.TrackNum;
    Ctx.Meta.Year := E.Year;
    Ctx.Meta.DateStr := E.DateStr;
    Ctx.Meta.SampleRate := E.SampleRate;
    Ctx.Meta.BitDepth := E.BitDepth;
    Ctx.Meta.DurationStr := E.DurationStr;
    Ctx.FilePath := E.FilePath;
    Ctx.IsDSD := IsDSDFile(E.FilePath);
    if Ctx.Meta.AlbumArtist = '' then Ctx.Meta.AlbumArtist := Ctx.Meta.Artist;
    if Ctx.Meta.AlbumArtist = '' then Ctx.Meta.AlbumArtist := LBL_UNKNOWN_ARTIST;
    if Ctx.Meta.Album = '' then Ctx.Meta.Album := LBL_UNKNOWN_ALBUM;
  end;

  { the library's date added and the play statistics of
    every entry, looked up once and only when a format shows them. One
    lookup per entry for its text and another one for its header, each a full
    copy of the library record, would cost about 0.15 s at every edit of a
    46,000 track playlist. }
  var
    EntKnown: array of Boolean;
    EntAdded: array of Int64;
    EntStats: array of PUserTrackStats;

  function UsesStats(const AFmt: string): Boolean;
  const
    IDS: array[0..4] of TTagID = (tiRating, tiFavorite, tiPlayCount, tiLastPlayed, tiAdded);
  var
    K: Integer;
    L: string;
  begin
    Result := False;
    if AFmt = '' then Exit;
    L := LowerCase(AFmt);
    for K := 0 to High(IDS) do
      if Pos('%' + MASTER_TAG_REGISTRY[IDS[K]].TagStr + '%', L) > 0 then Exit(True);
  end;

  procedure LookUpAll;
  var
    K: Integer;
  begin
    SetLength(EntKnown, FCount);
    SetLength(EntAdded, FCount);
    SetLength(EntStats, FCount);
    for K := 0 to FCount - 1 do
    begin
      KeepWindowAlive;
      EntKnown[K] := Assigned(FOnLookup) and FOnLookup(FEntries[K].FilePath, T);
      EntAdded[K] := 0;
      EntStats[K] := nil;
      if not EntKnown[K] then Continue;
      EntAdded[K] := T.DateAdded;
      if UserStatsManager = nil then Continue;
      St := UserStatsManager.PeekStats(T.PrimaryFingerprint);
      if (St = nil) and (T.FallbackFingerprint <> '') then St := UserStatsManager.PeekStats(T.FallbackFingerprint);
      EntStats[K] := St;
    end;
  end;

  { entry K into Ctx: its own values, or (AMax, a header over its tracks)
    the latest date added and the statistics of the track played last }
  procedure StatsOf(K: Integer; AMax: Boolean);
  begin
    if not EntKnown[K] then Exit;
    if (not AMax) or (EntAdded[K] > Ctx.DateAdded) then Ctx.DateAdded := EntAdded[K];
    St := EntStats[K];
    if (St <> nil) and ((not AMax) or (Ctx.UserStats = nil) or (St^.LastPlayed > Ctx.UserStats^.LastPlayed)) then
      Ctx.UserStats := St;
  end;

  { the artist of track K behind its title: in a group whose tracks are not
    all by the same artist, where it is not the album artist of the header
    and the track format does not show it }
  procedure SetArtistText(K: Integer; AFormatShowsIt: Boolean);
  var
    Hd: Integer;
  begin
    FEntries[K].ArtistText := '';
    Hd := FHeaderOf[K];
    if (Hd < 0) or (not FHeaders[Hd].MixedArtists) or AFormatShowsIt or (FEntries[K].Artist = '') or
       (FEntries[K].AlbumArtist = '') or
       (UTF8LowerCase(FEntries[K].Artist) = UTF8LowerCase(FEntries[K].AlbumArtist)) then Exit;
    FEntries[K].ArtistText := FormatTagString(FEntries[K].Artist, 0, ', ');
  end;

  function UsesTag(const AFmt: string; AId: TTagID): Boolean;
  begin
    Result := Pos('%' + MASTER_TAG_REGISTRY[AId].TagStr + '%', LowerCase(AFmt)) > 0;
  end;

  { "11 tracks • 49:30": the parts the header format does not show itself }
  function GroupInfoText(const AHeader: TPlHeader; ACount, ATime: Boolean): string;
  begin
    Result := '';
    if ACount then
      if AHeader.Count = 1 then Result := '1 track' else Result := Format('%d tracks', [AHeader.Count]);
    if ATime and (AHeader.TotalSec > 0) then
    begin
      if Result <> '' then Result := Result + '  •  ';
      Result := Result + FormatGroupDuration(AHeader.TotalSec);
    end;
  end;

var
  TrackFmt, HeaderFmt: string;
  TrackStats, HeaderStats, TrackHasArtist, InfoCount, InfoTime: Boolean;
begin
  Ctx := Default(TTrackFormatContext);
  if FDemo then
  begin
    for I := 0 to FCount - 1 do
    begin
      FEntries[I].TitleText := FEntries[I].Title;
      SetArtistText(I, False);
    end;
    for I := 0 to FHeaderCount - 1 do
    begin
      FHeaders[I].Text := FHeaders[I].Album + '  •  ' + IntToStr(FEntries[FHeaders[I].First].Year) +
        '  •  ' + FHeaders[I].AlbumArtist;
      FHeaders[I].Info := GroupInfoText(FHeaders[I], True, True);
    end;
    Exit;
  end;
  { the formats, and whether they show the date added or the statistics }
  { a flat list has columns: its title column is the plain title, and the
    date of an auto-playlist is a column too }
  if FGroupMode = gmFlat then TrackFmt := '' else TrackFmt := FTrackFmt;
  if (FGroupMode = gmFlat) and NeedsStats and not SortActive then FillStats;
  if (FGroupMode = gmFolder) or (FHeaderFmt = '') then HeaderFmt := '%folder%' else HeaderFmt := FHeaderFmt;
  if FDateSuffix <> '' then HeaderFmt := HeaderFmt + FDateSuffix;
  { what the formats show themselves is not shown a second time }
  TrackHasArtist := UsesTag(TrackFmt, tiArtist);
  InfoCount := not UsesTag(HeaderFmt, tiTrackCount);
  InfoTime := not UsesTag(HeaderFmt, tiTotalTime);
  TrackStats := UsesStats(TrackFmt);
  HeaderStats := (FHeaderCount > 0) and UsesStats(HeaderFmt);
  if TrackStats or HeaderStats then LookUpAll;
  { tracks }
  Fmt := TrackFmt;
  for I := 0 to FCount - 1 do
  begin
    KeepWindowAlive;
    MetaOf(FEntries[I]);
    { under a work heading the title is the track's part of the work }
    if FEntries[I].PartTitle <> '' then Ctx.Meta.Title := FEntries[I].PartTitle;
    if TrackStats then StatsOf(I, False);
    if Fmt = '' then FEntries[I].TitleText := Ctx.Meta.Title
    else FEntries[I].TitleText := TidyFormatted(CleanTag(FormatTrackInfo(Fmt, Ctx)));
    if FEntries[I].TitleText = '' then FEntries[I].TitleText := Ctx.Meta.Title;
    SetArtistText(I, TrackHasArtist);
  end;
  { headers }
  Fmt := HeaderFmt;
  for I := 0 to FHeaderCount - 1 do
  begin
    MetaOf(FEntries[FHeaders[I].First]);
    Ctx.TrackCount := FHeaders[I].Count;
    Ctx.TotalTimeStr := FormatGroupDuration(FHeaders[I].TotalSec);
    if HeaderStats then
      for J := FHeaders[I].First to FHeaders[I].First + FHeaders[I].Count - 1 do
        StatsOf(J, True);
    FHeaders[I].Text := TidyFormatted(CleanTag(FormatTrackInfo(Fmt, Ctx)));
    if Trim(FHeaders[I].Text) = '' then
      FHeaders[I].Text := ExtractFileName(FHeaders[I].FolderDir);
    FHeaders[I].Info := GroupInfoText(FHeaders[I], InfoCount, InfoTime);
    Total := 0;
    N := 0;
    for J := FHeaders[I].First to FHeaders[I].First + FHeaders[I].Count - 1 do
    begin
      Inc(Total, FEntries[J].Rating);
      Inc(N);
    end;
    FHeaders[I].Rating := AverageRating(Total, N);
  end;
end;

{ a "Disc n" heading belongs above entry I }
function TPlaylistPane.DiscLeadAt(I: Integer): Boolean;
var
  H: Integer;
begin
  Result := False;
  if (I < 0) or (I >= FCount) then Exit;
  H := FHeaderOf[I];
  Result := (H >= 0) and FHeaders[H].MultiDisc and (FEntries[I].DiscNum > 0) and
    ((FHeaders[H].First = I) or (FEntries[I - 1].DiscNum <> FEntries[I].DiscNum));
end;

{ The works inside each group (uPlaylistRows.FindWorks): which tracks get a
  work heading and which part of their title is shown under it. The work of
  a track comes from the library; an entry that was loaded from a stored
  playlist is asked for it once. Nothing in a flat list, with the headings
  switched off or in the demo. }
procedure TPlaylistPane.FindGroupWorks;
var
  H, I, K: Integer;
  Rows: TWorkRows;
  T: TTrackInfo;
begin
  for I := 0 to FCount - 1 do
  begin
    FEntries[I].WorkHead := '';
    FEntries[I].PartTitle := '';
    FEntries[I].WorkFirst := -1;
    FEntries[I].WorkLast := -1;
  end;
  if (not FWorkHeadings) or (FGroupMode = gmFlat) or FDemo then Exit;
  for I := 0 to FCount - 1 do
    if not FEntries[I].WorkKnown then
    begin
      KeepWindowAlive;
      FEntries[I].WorkKnown := True;
      if Assigned(FOnLookup) and FOnLookup(FEntries[I].FilePath, T) then FEntries[I].Work := CleanTag(T.Work);
    end;
  Rows := nil;
  for H := 0 to FHeaderCount - 1 do
  begin
    if FHeaders[H].Count < 2 then Continue;
    SetLength(Rows, FHeaders[H].Count);
    for K := 0 to FHeaders[H].Count - 1 do
    begin
      I := FHeaders[H].First + K;
      Rows[K].Title := FEntries[I].Title;
      Rows[K].Work := FEntries[I].Work;
      Rows[K].Disc := FEntries[I].DiscNum;
    end;
    FindWorks(Rows);
    for K := 0 to FHeaders[H].Count - 1 do
    begin
      I := FHeaders[H].First + K;
      FEntries[I].WorkHead := Rows[K].Heading;
      FEntries[I].PartTitle := Rows[K].Part;
      if Rows[K].First >= 0 then
      begin
        FEntries[I].WorkFirst := FHeaders[H].First + Rows[K].First;
        FEntries[I].WorkLast := FHeaders[H].First + Rows[K].Last;
      end;
    end;
  end;
end;

function TPlaylistPane.WorkOfEntry(E: Integer; out AFirst, ALast: Integer): Boolean;
begin
  AFirst := -1;
  ALast := -1;
  Result := (E >= 0) and (E < FCount) and (FEntries[E].WorkFirst >= 0) and
    (FEntries[E].WorkLast < FCount) and (FEntries[E].WorkLast >= FEntries[E].WorkFirst);
  if not Result then Exit;
  AFirst := FEntries[E].WorkFirst;
  ALast := FEntries[E].WorkLast;
end;

function TPlaylistPane.SelectWork(E: Integer): Boolean;
var
  A, B, I, R: Integer;
begin
  Result := WorkOfEntry(E, A, B);
  if not Result then Exit;
  SelectEntry(A, True, False);
  for I := A + 1 to B do
  begin
    R := RowOfEntry(I);
    if R >= 0 then List.Selected[R] := True;
  end;
end;

procedure TPlaylistPane.SetWorkHeadings(V: Boolean);
begin
  if V = FWorkHeadings then Exit;
  FWorkHeadings := V;
  RebuildKeepingSelection;
end;

{ the groups and the rows from the entries; nothing is selected afterwards
  (the callers select what they changed) }
procedure TPlaylistPane.Rebuild;
var
  I, H, R: Integer;
  Key, CurKey: string;
  Paths: TStringList;
  T: TTrackInfo;
begin
  { the groups }
  FHeaderCount := 0;
  SetLength(FHeaders, 0);
  SetLength(FHeaderOf, FCount);
  Paths := TStringList.Create;
  Paths.Sorted := True;
  Paths.UseLocale := False;
  Paths.CaseSensitive := False;
  try
    CurKey := #0;
    H := -1;
    for I := 0 to FCount - 1 do
    begin
      if FGroupMode = gmFlat then
      begin
        FHeaderOf[I] := -1;
        Continue;
      end;
      KeepWindowAlive;
      T := TrackOf(FEntries[I]);
      Key := PlaylistGroupKey(T, FGroupMode);
      if (H < 0) or (Key <> CurKey) or (Paths.IndexOf(FEntries[I].FilePath) >= 0) then
      begin
        CurKey := Key;
        Paths.Clear;
        Inc(FHeaderCount);
        SetLength(FHeaders, FHeaderCount);
        H := FHeaderCount - 1;
        FHeaders[H] := Default(TPlHeader);
        FHeaders[H].First := I;
        FHeaders[H].Album := FEntries[I].Album;
        FHeaders[H].AlbumArtist := FEntries[I].AlbumArtist;
        FHeaders[H].FolderDir := FEntries[I].FolderDir;
        FHeaders[H].FirstArtist := FEntries[I].Artist;
      end;
      if FEntries[I].DiscNum > 0 then
      begin
        if FHeaders[H].FirstDisc = 0 then FHeaders[H].FirstDisc := FEntries[I].DiscNum
        else if FEntries[I].DiscNum <> FHeaders[H].FirstDisc then FHeaders[H].MultiDisc := True;
      end;
      if FEntries[I].Artist <> FHeaders[H].FirstArtist then FHeaders[H].MixedArtists := True;
      Paths.Add(FEntries[I].FilePath);
      Inc(FHeaders[H].Count);
      Inc(FHeaders[H].TotalSec, FEntries[I].Seconds);
      FHeaderOf[I] := H;
    end;
  finally
    Paths.Free;
  end;
  FindGroupWorks;
  BuildTexts;
  { the rows }
  List.BeginUpdate;
  try
    List.Clear;
    for I := 0 to FCount - 1 do
    begin
      H := FHeaderOf[I];
      if (H >= 0) and (FHeaders[H].First = I) then
        List.AddHeader(-(H + 1), 2);
      KeepWindowAlive;
      R := List.AddItem(I);
      { above a track: a "Disc n" heading for the first track of each disc of
        a group with several discs, and the heading of the work it begins }
      List.SetLeadLines(R, Ord(DiscLeadAt(I)) + Ord(FEntries[I].WorkHead <> ''));
    end;
  finally
    List.EndUpdate;
  end;
  { collapsed groups, by header text or album }
  if FCollapsed.Count > 0 then
  begin
    FQuietCollapse := True;
    List.BeginUpdate;
    try
      for I := 0 to List.RowCount - 1 do
        if List.Kind[I] = rkHeader then
        begin
          H := -List.Data[I] - 1;
          if (FCollapsed.IndexOf(FHeaders[H].Text) >= 0) or
             ((FHeaders[H].Album <> '') and (FCollapsed.IndexOf(FHeaders[H].Album) >= 0)) then
            List.Collapsed[I] := True;
        end;
    finally
      List.EndUpdate;
      FQuietCollapse := False;
    end;
  end;
end;

procedure TPlaylistPane.ListCollapse(Sender: TObject);
var
  I, H: Integer;
begin
  { while the pane itself opens or closes several groups the names stay as
    they are: taking them from the list after the first group would lose
    the names of all the others }
  if FQuietCollapse then Exit;
  FCollapsed.Clear;
  for I := 0 to List.RowCount - 1 do
    if (List.Kind[I] = rkHeader) and List.Collapsed[I] then
    begin
      H := -List.Data[I] - 1;
      FCollapsed.Add(FHeaders[H].Text);
    end;
  if Assigned(FOnCollapseChange) and not FDemo then FOnCollapseChange(Self);
end;

function TPlaylistPane.CollapsedNames: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, FCollapsed.Count);
  for I := 0 to FCollapsed.Count - 1 do Result[I] := FCollapsed[I];
end;

procedure TPlaylistPane.SetCollapsedNames(const ANames: array of string);
var
  I: Integer;
begin
  FCollapsed.Clear;
  for I := 0 to High(ANames) do
    if ANames[I] <> '' then FCollapsed.Add(ANames[I]);
end;

{ every group open or closed, in one step; then the names once }
procedure TPlaylistPane.SetAllCollapsed(AValue: Boolean);
var
  I: Integer;
begin
  FQuietCollapse := True;
  List.BeginUpdate;
  try
    for I := 0 to List.RowCount - 1 do
      if List.Kind[I] = rkHeader then List.Collapsed[I] := AValue;
  finally
    List.EndUpdate;
    FQuietCollapse := False;
  end;
  ListCollapse(nil);
end;

procedure TPlaylistPane.ExpandAll;
begin
  SetAllCollapsed(False);
end;

procedure TPlaylistPane.CollapseAll;
begin
  SetAllCollapsed(True);
end;

{ ---- painting ---- }

function TPlaylistPane.StarsWidth: Single;
begin
  Result := 5 * Round(List.ItemHeight * 0.52) + 4 * S(2);
end;

procedure TPlaylistPane.DrawStars(G: TGfx; X, CY, Sz: Single; Rating: Integer; C: TARGB);
var
  K: Integer;
begin
  for K := 1 to 5 do
  begin
    if K <= Rating then DrawIcon(G, icStarFill, X + Sz / 2, CY, Sz, C)
    else DrawIcon(G, icStar, X + Sz / 2, CY, Sz, WithAlpha(clTextFaint, 200));
    X := X + Sz + S(2);
  end;
end;

{ the left edge of the stars in the row, from the content's left }
function TPlaylistPane.StarsLeft(IsHeader: Boolean): Single;
begin
  if IsHeader then Result := FRowW - StarsWidth - S(4)
  else if FGroupMode = gmFlat then Result := FFlatStarsX
  else Result := FRowW - S(64) - StarsWidth - S(8);
end;

function TPlaylistPane.DisplayNumber(E: Integer): string;
var
  D: TPlEntry;
begin
  D := FEntries[E];
  if FGroupMode = gmFlat then Exit(Format('%.2d', [E + 1]));
  if D.TrackNum > 0 then
  begin
    if D.DiscNum > 0 then Result := Format('%d-%.2d', [D.DiscNum, D.TrackNum])
    else Result := Format('%.2d', [D.TrackNum]);
  end
  else
    Result := Format('%.2d', [E + 1]);
end;

{ the thumbnail of a header, read at the size it is shown at (APixels, in
  steps of 64 up to the thumbnail's own size). Every header of a paint asks
  for the same size, so a new size is noticed by the first one - before any
  kept picture was drawn in that paint - and the kept ones are let go. }
function TPlaylistPane.ThumbOf(const H: TPlHeader; APixels: Integer): TGfxBitmap;
var
  Hash, F: string;
  Idx, Px: Integer;
begin
  Px := EnsureRange(((APixels + 63) div 64) * 64, 64, CACHE_THUMB_SIZE);
  if Px <> FThumbPx then
  begin
    for Idx := 0 to FThumbs.Count - 1 do
      if FThumbs.Objects[Idx] <> nil then DisposeBitmap(TGfxBitmap(FThumbs.Objects[Idx]));
    FThumbs.Clear;
    FThumbPx := Px;
  end;
  Hash := GenerateAlbumHash(H.AlbumArtist, H.Album, H.FolderDir);
  if FThumbs.Find(Hash, Idx) then Exit(TGfxBitmap(FThumbs.Objects[Idx]));
  Result := nil;
  F := AppCacheThumbsDir + Hash + '.jpg';
  if FileExists(LongPath(F)) then Result := ImageFromFile(F, FThumbPx);
  FThumbs.AddObject(Hash, TObject(Result));
end;

procedure TPlaylistPane.ClearThumbCache;
var
  I: Integer;
begin
  if FThumbs = nil then Exit;
  for I := 0 to FThumbs.Count - 1 do
    if FThumbs.Objects[I] <> nil then DisposeBitmap(TGfxBitmap(FThumbs.Objects[I]));
  FThumbs.Clear;
  if HandleAllocated then List.Invalidate;
end;

{ what type-ahead searches: the text a row shows (a track's
  line in the chosen format, without the number column; a header's text) }
function TPlaylistPane.RowText(Sender: TObject; Row: Integer): string;
var
  D: PtrInt;
begin
  Result := '';
  D := List.Data[Row];
  if List.Kind[Row] = rkHeader then
  begin
    D := -D - 1;
    if (D >= 0) and (D < FHeaderCount) then Result := FHeaders[D].Text;
  end
  else if (D >= 0) and (D < FCount) then
  begin
    Result := FEntries[D].TitleText;
    if Result = '' then Result := FEntries[D].Title;
  end;
end;

procedure TPlaylistPane.DrawRow(Sender: TObject; G: TGfx; Row: Integer; X, Y, W, H: Single; State: TAuRowState);
var
  E, Hd: Integer;
  D: TPlEntry;
  F, BF, HF, IFnt: TGfxFont;
  Th, TX, NumW, DurW, StW, StSz, TW, RightW, InfoW, Avail, TitleW: Single;
  Fg, Dim: TARGB;
  L1, L2: string;
  Playing: Boolean;
  Hdr: TPlHeader;
  Thumb: TGfxBitmap;
begin
  FRowW := W;
  F := UIFont(List.TextSize);
  BF := UIFont(List.TextSize, True);
  StSz := Round(List.ItemHeight * 0.52);
  StW := StarsWidth;
  if List.Kind[Row] = rkHeader then
  begin
    Hd := -List.Data[Row] - 1;
    if (Hd < 0) or (Hd >= FHeaderCount) then Exit;
    Hdr := FHeaders[Hd];
    Th := H - S(10);
    TX := X;
    if FGroupMode <> gmFolder then
    begin
      if FDemo then Thumb := nil else Thumb := ThumbOf(Hdr, Round(Th));
      DrawTileArt(G, Thumb, X, Y + S(5), Th, Th, S(5), Hdr.Album + Hdr.AlbumArtist, False);
      TX := X + Th + S(14);
    end
    else
    begin
      DrawIcon(G, icFolder, X + S(14), Y + H / 2, S(20), clAccentText);
      TX := X + S(34);
    end;
    { at the right: the stars and, where there is room for it, the group's
      track count and time under them; the header text keeps the rest }
    RightW := StW;
    IFnt := UIFont(List.TextSize - 1.5);
    InfoW := 0;
    if Hdr.Info <> '' then InfoW := Ceil(TextWidth(Hdr.Info, IFnt));
    if (InfoW > 0) and (X + W - Math.Max(StW, InfoW) - S(16) - TX >= S(HEADER_TEXT_MIN_W)) then
    begin
      RightW := Math.Max(StW, InfoW);
      DrawStars(G, X + W - StW - S(4), Y + H / 2 - IFnt.LineHeight * 0.55, StSz, Hdr.Rating, clAccentText);
      G.Text(Hdr.Info, X + W - S(4) - InfoW - S(2), Y + H / 2 + StSz * 0.25, InfoW + S(4), IFnt.LineHeight + S(2),
        IFnt, clTextDim, 2, 0);
    end
    else
      DrawStars(G, X + W - StW - S(4), Y + H / 2, StSz, Hdr.Rating, clAccentText);
    TW := X + W - RightW - S(16) - TX;
    { the header text: one line in the larger font when it fits,
      else two lines (split at a ' • ') in the smaller one }
    HF := UIFont(List.TextSize + 2, True);
    if TextWidth(Hdr.Text, HF) <= TW then
    begin
      G.Text(Hdr.Text, TX, Y, TW, H, HF, clAccentText, 0, 1);
      Exit;
    end;
    HF := UIFont(List.TextSize + 1, True);
    SplitHeaderIntoTwoLines(Hdr.Text, Round(TW), @HeaderTextWidth, L1, L2);
    if L2 = '' then
      G.Text(L1, TX, Y, TW, H, HF, clAccentText, 0, 1)
    else
    begin
      G.Text(L1, TX, Y + H / 2 - HF.LineHeight - S(1), TW, HF.LineHeight + S(2), HF, clAccentText, 0, 1);
      G.Text(L2, TX, Y + H / 2 + S(1), TW, HF.LineHeight + S(2), HF, clAccentText, 0, 1);
    end;
    Exit;
  end;
  E := List.Data[Row];
  if (E < 0) or (E >= FCount) then Exit;
  D := FEntries[E];
  Playing := E = FPlaying;
  if Playing then
  begin
    Fg := clAccentText;
    Dim := clAccentText;
  end
  else
  begin
    Fg := clText;
    Dim := clTextDim;
  end;
  if FGroupMode = gmFlat then
  begin
    DrawFlatRow(G, E, X, Y, W, H);
    Exit;
  end;
  NumW := S(46);
  DurW := S(64);
  G.Text(DisplayNumber(E), X, Y, NumW, H, F, Dim, 0, 1);
  TX := X + NumW;
  if Playing then
  begin
    DrawIcon(G, icPlay, TX + S(5), Y + H / 2, H * 0.42, clAccentText);
    TX := TX + S(16);
  end;
  Avail := X + W - DurW - StW - S(20) - TX;
  if Playing then HF := BF else HF := F;
  G.Text(D.TitleText, TX, Y, Avail, H, HF, Fg, 0, 1);
  { the track's artist behind the title, where room is left for it }
  if D.ArtistText <> '' then
  begin
    TitleW := Ceil(TextWidth(D.TitleText, HF)) + S(14);
    if Avail - TitleW >= S(ARTIST_TEXT_MIN_W) then
      G.Text(D.ArtistText, TX + TitleW, Y, Avail - TitleW, H, F, Dim, 0, 1);
  end;
  DrawStars(G, X + W - DurW - StW - S(8), Y + H / 2, StSz, D.Rating, IfC(Playing, clAccentText, clTextDim));
  G.Text(D.DurationStr, X + W - DurW, Y, DurW, H, F, Dim, 2, 1);
end;

{ the "Disc n" heading above the first track of a disc: the text and a
  hairline to the right of it }
procedure TPlaylistPane.DrawLead(Sender: TObject; G: TGfx; Row: Integer; X, Y, W, H: Single; State: TAuRowState);
var
  E: Integer;
  F: TGfxFont;
  T: string;
  TW, SH: Single;
begin
  E := List.Data[Row];
  if (E < 0) or (E >= FCount) then Exit;
  { one strip per heading: the disc first, the work under it }
  SH := List.LeadHeight;
  if DiscLeadAt(E) then
  begin
    T := Format('Disc %d', [FEntries[E].DiscNum]);
    F := UIFont(List.TextSize - 1, True);
    TW := Ceil(TextWidth(T, F));
    G.Text(T, X, Y + S(3), TW + S(4), SH - S(3), F, clTextDim, 0, 1);
    G.FillRect(X + TW + S(12), Y + S(3) + (SH - S(3)) / 2, Math.Max(0, W - TW - S(12)), 1, WithAlpha(clText, 30));
    Y := Y + SH;
  end;
  { the work: its name, in the weight of the titles under it but bold }
  if FEntries[E].WorkHead <> '' then
    G.Text(FEntries[E].WorkHead, X + S(16), Y + S(3), Math.Max(0, W - S(16)), SH - S(3),
      UIFont(List.TextSize, True), clText, 0, 1);
end;

{ a click on the stars sets the rating (a header: all its tracks) }
procedure TPlaylistPane.RowClick(Sender: TObject; Row: Integer; X, Y: Integer);
var
  IsHeader: Boolean;
  StarW, Clicked, Cur, I, Hd, E: Integer;
  Rr: Integer;
  Fp: string;
  Rw: TTrackNodeData;
  RowR: TRect;
begin
  IsHeader := List.Kind[Row] = rkHeader;
  { the cover of a header (as drawn in DrawRow): the group's cover viewer }
  if IsHeader and (FGroupMode <> gmFolder) and (not FDemo) and Assigned(FOnCoverClick) then
  begin
    RowR := List.RowRect(Row);
    Rr := RowR.Bottom - RowR.Top;
    if (X >= 0) and (X < Rr - S(10)) and (Y >= S(5)) and (Y < Rr - S(5)) then
    begin
      Hd := -List.Data[Row] - 1;
      if (Hd >= 0) and (Hd < FHeaderCount) and (FHeaders[Hd].Count > 0) then
        FOnCoverClick(Self, FHeaders[Hd].First);
      Exit;
    end;
  end;
  if (UserStatsManager = nil) or FDemo or (FRowW <= 0) then Exit;
  StarW := Round(List.ItemHeight * 0.52) + S(2);
  Clicked := StarAtOffset(X, Round(StarsLeft(IsHeader)), StarW);
  if Clicked = 0 then Exit;
  if IsHeader then
  begin
    Hd := -List.Data[Row] - 1;
    Cur := FHeaders[Hd].Rating;
  end
  else
  begin
    Hd := -1;
    Cur := FEntries[List.Data[Row]].Rating;
  end;
  Rr := NextRating(Clicked, Cur);
  for I := 0 to FCount - 1 do
  begin
    if IsHeader then
    begin
      if FHeaderOf[I] <> Hd then Continue;
    end
    else if I <> List.Data[Row] then Continue;
    E := I;
    Rw := Default(TTrackNodeData);
    Rw.Title := FEntries[E].Title;
    Rw.Artist := FEntries[E].Artist;
    Rw.AlbumArtist := FEntries[E].AlbumArtist;
    Rw.Album := FEntries[E].Album;
    Fp := RowRatingFingerprint(Rw);
    if Fp <> '' then UserStatsManager.SetRating(Fp, Rr);
  end;
  RefreshRatings;
end;

{ ---- queries ---- }

procedure TPlaylistPane.SetPlaying(V: Integer);
begin
  if V = FPlaying then Exit;
  FPlaying := V;
  List.Invalidate;
end;

function TPlaylistPane.EntryCount: Integer;
begin
  Result := FCount;
end;

function TPlaylistPane.Entry(I: Integer): TPlEntry;
begin
  Result := FEntries[I];
end;

function TPlaylistPane.EntryOfRow(Row: Integer): Integer;
var
  Hd: Integer;
begin
  if (Row < 0) or (Row >= List.RowCount) then Exit(-1);
  if List.Kind[Row] = rkHeader then
  begin
    Hd := -List.Data[Row] - 1;
    if (Hd >= 0) and (Hd < FHeaderCount) then Exit(FHeaders[Hd].First);
    Exit(-1);
  end;
  Result := List.Data[Row];
end;

function TPlaylistPane.RowOfEntry(E: Integer): Integer;
var
  R: Integer;
begin
  for R := 0 to List.RowCount - 1 do
    if (List.Kind[R] = rkItem) and (List.Data[R] = E) then Exit(R);
  Result := -1;
end;

function TPlaylistPane.HeaderOfEntry(E: Integer): Integer;
begin
  if (E < 0) or (E >= Length(FHeaderOf)) then Exit(-1);
  Result := FHeaderOf[E];
end;

function TPlaylistPane.SelectedEntries: TIntArray;
var
  Rows: TAuRowArray;
  I, J, N, Hd: Integer;
  Seen: array of Boolean;

  procedure Take(E: Integer);
  begin
    if (E < 0) or (E >= FCount) or Seen[E] then Exit;
    Seen[E] := True;
    Result[N] := E;
    Inc(N);
  end;

begin
  Result := nil;
  Rows := List.SelectedRows;
  SetLength(Seen, FCount);
  SetLength(Result, FCount);
  N := 0;
  for I := 0 to High(Rows) do
    if List.Kind[Rows[I]] = rkHeader then
    begin
      { a header stands for its whole group }
      Hd := -List.Data[Rows[I]] - 1;
      if (Hd >= 0) and (Hd < FHeaderCount) then
        for J := FHeaders[Hd].First to FHeaders[Hd].First + FHeaders[Hd].Count - 1 do Take(J);
    end
    else
      Take(List.Data[Rows[I]]);
  SetLength(Result, N);
end;

procedure TPlaylistPane.GroupInfo(E: Integer; out Index, Count, TotalSec: Integer);
var
  Hd: Integer;
begin
  Index := 0;
  Count := 0;
  TotalSec := 0;
  if (E < 0) or (E >= FCount) then Exit;
  Hd := HeaderOfEntry(E);
  if Hd < 0 then Exit;            // a flat list: no album to count in
  Index := E - FHeaders[Hd].First + 1;
  Count := FHeaders[Hd].Count;
  TotalSec := FHeaders[Hd].TotalSec;
end;

function TPlaylistPane.IndexOfFile(const APath: string; Near: Integer): Integer;
var
  I: Integer;
begin
  if (Near >= 0) and (Near < FCount) and SameText(FEntries[Near].FilePath, APath) then Exit(Near);
  for I := 0 to FCount - 1 do
    if SameText(FEntries[I].FilePath, APath) then Exit(I);
  Result := -1;
end;

function TPlaylistPane.IndexOfId(AId: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if FEntries[I].Id = AId then Exit(I);
  Result := -1;
end;

procedure TPlaylistPane.SelectEntry(E: Integer; AOpenGroup: Boolean; ACenter: Boolean);
var
  R, Hd, I: Integer;
begin
  R := RowOfEntry(E);
  if R < 0 then Exit;
  if not List.IsVisibleRow(R) then
  begin
    Hd := -1;
    for I := R downto 0 do
      if List.Kind[I] = rkHeader then
      begin
        Hd := I;
        Break;
      end;
    if Hd >= 0 then
    begin
      if AOpenGroup then List.Collapsed[Hd] := False
      else R := Hd;
    end;
  end;
  List.SelectOnly(R);
  List.EnsureVisible(R, ACenter);
end;

procedure TPlaylistPane.FollowEntry(E: Integer);
var
  R, I: Integer;
  InView: Boolean;
begin
  R := RowOfEntry(E);
  if R < 0 then Exit;
  if not List.IsVisibleRow(R) then
    for I := R downto 0 do
      if List.Kind[I] = rkHeader then
      begin
        List.Collapsed[I] := False;
        Break;
      end;
  { (in view? - asked before the row is selected: selecting brings a row to
    the edge of the list by itself) }
  InView := List.RowInView(R);
  List.SelectOnly(R);
  if not InView then
    List.EnsureVisible(R, True);
end;

function TPlaylistPane.SelectedFilePath: string;
var
  E: Integer;
begin
  Result := '';
  E := EntryOfRow(List.FocusedRow);
  if (E >= 0) and (E < FCount) then Result := FEntries[E].FilePath;
end;

function TPlaylistPane.InsertIndexAt(Y: Integer; out AMarkRow: Integer; out AMarkAbove: Boolean): Integer;
var
  R, Hd, E, Last: Integer;
begin
  List.DropTargetAt(Y, R, AMarkAbove);
  AMarkRow := R;
  if R < 0 then
  begin
    { below the last row: at the end }
    Result := FCount;
    AMarkRow := List.RowCount - 1;
    while (AMarkRow >= 0) and not List.IsVisibleRow(AMarkRow) do Dec(AMarkRow);
    AMarkAbove := False;
    Exit;
  end;
  if FGroupMode = gmFlat then
  begin
    E := List.Data[R];
    if AMarkAbove then Result := E else Result := E + 1;
    Exit;
  end;
  if List.Kind[R] = rkHeader then Hd := -List.Data[R] - 1
  else Hd := FHeaderOf[List.Data[R]];
  if (List.Kind[R] = rkHeader) and AMarkAbove then
  begin
    Result := FHeaders[Hd].First;
    Exit;
  end;
  { after the whole group: the marker under its last visible row }
  Result := FHeaders[Hd].First + FHeaders[Hd].Count;
  Last := RowOfEntry(Result - 1);
  while (Last > 0) and not List.IsVisibleRow(Last) do Dec(Last);
  AMarkRow := Last;
  AMarkAbove := False;
end;

{ ---- demo (screenshots) ---- }

procedure TPlaylistPane.FillDemo;
type
  TDemoTrack = record T: string; Sec, R: Integer; end;
const
  A1: array[0..7] of TDemoTrack = (
    (T: 'The start of silence'; Sec: 273; R: 4), (T: 'The end of silence'; Sec: 318; R: 3),
    (T: 'The start of noise'; Sec: 328; R: 0), (T: 'The middle of noise'; Sec: 350; R: 5),
    (T: 'The end of noise'; Sec: 324; R: 0), (T: 'The start of calm'; Sec: 363; R: 2),
    (T: 'The middle of calm'; Sec: 524; R: 0), (T: 'The end of calm'; Sec: 340; R: 4));
  A2: array[0..5] of TDemoTrack = (
    (T: 'Burning Return'; Sec: 175; R: 3), (T: 'Late Return'; Sec: 326; R: 5),
    (T: 'Falling Hours'; Sec: 388; R: 2), (T: 'Burning Hours'; Sec: 484; R: 2),
    (T: 'Small Signal'; Sec: 460; R: 1), (T: 'Late Waltz'; Sec: 262; R: 1));

  procedure Add(const Album, Artist, Folder: string; Year, Disc, No: Integer; const D: TDemoTrack;
    const Guest: string = '');
  begin
    SetLength(FEntries, FCount + 1);
    FEntries[FCount] := Default(TPlEntry);
    FEntries[FCount].Title := D.T;
    FEntries[FCount].Album := Album;
    FEntries[FCount].AlbumArtist := Artist;
    FEntries[FCount].Artist := Artist;
    if Guest <> '' then FEntries[FCount].Artist := Artist + '; ' + Guest;
    FEntries[FCount].Year := Year;
    FEntries[FCount].DiscNum := Disc;
    FEntries[FCount].TrackNum := No;
    FEntries[FCount].Seconds := D.Sec;
    FEntries[FCount].DurationStr := FormatDuration(D.Sec);
    FEntries[FCount].Rating := D.R;
    FEntries[FCount].FolderDir := Folder;
    FEntries[FCount].FilePath := Folder + '\' + D.T + '.flac';
    FEntries[FCount].GroupKey := Album;
    FEntries[FCount].Seq := FCount;
    Inc(FNextId);
    FEntries[FCount].Id := FNextId;
    Inc(FCount);
  end;

var
  I: Integer;
begin
  FCount := 0;
  SetLength(FEntries, 0);
  FDemo := True;
  { the first album with a guest on one track, the second on two discs }
  for I := 0 to High(A1) do
    if I = 3 then Add('Silence, Noise and Calm', 'Andy Lu', 'D:\Music\Andy Lu\Silence', 2026, 1, I + 1, A1[I], 'Ida Feld')
    else Add('Silence, Noise and Calm', 'Andy Lu', 'D:\Music\Andy Lu\Silence', 2026, 1, I + 1, A1[I]);
  for I := 0 to High(A2) do
    Add('Silent Skies', 'Northern Lights Quartet', 'D:\Music\NLQ\Silent Skies', 2005, 1 + I div 3, I mod 3 + 1, A2[I]);
  FPlaying := 0;
  Rebuild;
  { the demo's ratings are its own (no user stats) }
  for I := 0 to FHeaderCount - 1 do FHeaders[I].Rating := 0;
end;

end.
