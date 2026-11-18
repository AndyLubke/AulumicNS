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
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuMenus, AuExtra, AuGroupList,
  uAppConsts, uLibraryTypes, uPlaylistFile;

type
  TPlEntry = record
    Id: Integer;            // stable row id (the play queue's TrackId)
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
  end;
  TIntArray = array of Integer;

  TPlHeader = record
    First, Count, TotalSec: Integer;   // the entries of the group
    Rating: Integer;                   // the average of its tracks
    Text: string;                      // the header format
    Album, AlbumArtist, FolderDir: string;
  end;

  { a library record for a file (False: not in the library) }
  TPlLookupEvent = function(const APath: string; out ATrack: TTrackInfo): Boolean of object;
  { a click on a header's cover: the group's first entry }
  TPlCoverEvent = procedure(Sender: TObject; AEntry: Integer) of object;

  { TPlaylistPane }

  TPlaylistPane = class(TAuPanel)
  private
    FTop: TAuPanel;
    FEntries: array of TPlEntry;
    FCount: Integer;
    FHeaders: array of TPlHeader;
    FHeaderCount: Integer;
    FHeaderOf: array of Integer;       // entry -> header (-1 flat)
    FPlaying: Integer;
    FDemo: Boolean;
    FNextId: Integer;
    FOnLookup: TPlLookupEvent;
    FThumbs: TStringList;              // album hash -> TGfxBitmap (nil: none)
    FGroupMode: TGroupingMode;
    FHeaderFmt, FTrackFmt, FDateSuffix: string;
    FReadOnly: Boolean;
    FCollapsed: TStringList;           // header texts / albums to keep collapsed
    FRowW: Single;                     // content width of the rows (painting)
    FOnChange, FOnRatingChange, FOnCollapseChange: TNotifyEvent;
    FOnCoverClick: TPlCoverEvent;
    procedure TopResize(Sender: TObject);
    procedure DrawRow(Sender: TObject; G: TGfx; Row: Integer; X, Y, W, H: Single; State: TAuRowState);
    function RowText(Sender: TObject; Row: Integer): string;
    procedure DrawStars(G: TGfx; X, CY, Sz: Single; Rating: Integer; C: TARGB);
    procedure RowClick(Sender: TObject; Row: Integer; X, Y: Integer);
    procedure ListCollapse(Sender: TObject);
    procedure SetPlaying(V: Integer);
    function ReadEntry(const APath: string): TPlEntry;
    function ThumbOf(const H: TPlHeader): TGfxBitmap;
    function EntryFromTrack(const T: TTrackInfo): TPlEntry;
    procedure InsertEntries(const New_: array of TPlEntry; N, InsertAt: Integer);
    function TrackOf(const E: TPlEntry): TTrackInfo;
    function RatingOf(const E: TPlEntry): Integer;
    function HeaderTextWidth(const S: string): Integer;
    function StarsLeft(IsHeader: Boolean): Single;
    function DisplayNumber(E: Integer): string;
    procedure Changed;
    procedure BuildTexts;
  public
    BtnPlaylist: TAuDropButton;
    BtnView: TAuButton;
    BtnEdit: TAuIconButton;
    List: TAuGroupList;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Clear;
    { the grouping, formats ('' = the defaults, see the main window), the date
      suffix of an auto-playlist and whether the list may be changed }
    procedure SetView(AGroupMode: TGroupingMode; const AHeaderFmt, ATrackFmt, ADateSuffix: string;
      AReadOnly: Boolean);
    { reads the tags of the files and adds them (at InsertAt, -1 = the end) }
    procedure AddFiles(Paths: TStrings; InsertAt: Integer = -1);
    { copies of library records (no disk access) }
    procedure AddTracks(Tracks: TTrackList; InsertAt: Integer = -1);
    { the content of a stored playlist (replaces the list) }
    procedure LoadEntries(const AEntries: TPlaylistEntries);
    function ToEntries: TPlaylistEntries;
    procedure Rebuild;
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
    property ReadOnly: Boolean read FReadOnly;
    property IsDemo: Boolean read FDemo;
    property OnLookup: TPlLookupEvent read FOnLookup write FOnLookup;
    { the entries changed (added, removed, moved, cleared) }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnRatingChange: TNotifyEvent read FOnRatingChange write FOnRatingChange;
    property OnCollapseChange: TNotifyEvent read FOnCollapseChange write FOnCollapseChange;
    property OnCoverClick: TPlCoverEvent read FOnCoverClick write FOnCoverClick;
  end;

function FormatDuration(Sec: Integer): string;

implementation

uses
  AuAudioTypes, ALMetadata, uAudioUtils, uMetaUtils, uUserStatsManager, uTagParser, uPlaylistRows, uAppStrings;

const
  PL_EMPTY_TEXT = 'This playlist is empty.' + LineEnding +
    'Drag music from the library or from Windows Explorer here,' + LineEnding +
    'or use Main menu > File > Add files... (Ctrl+O).';
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

constructor TPlaylistPane.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crBg;
  FPlaying := -1;
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
  BtnPlaylist := TAuDropButton.Create(Self);
  BtnPlaylist.Parent := FTop;
  BtnPlaylist.Caption := 'Default Playlist';
  BtnPlaylist.TextSize := 14;
  BtnPlaylist.Hint := 'Choose a playlist';
  BtnPlaylist.ShowHint := True;
  BtnView := TAuButton.Create(Self);
  BtnView.Parent := FTop;
  BtnView.Kind := bkFlat;
  BtnView.Icon := icEye;
  BtnView.Caption := 'By album';
  BtnView.Hint := 'View: grouping and layout of this playlist';
  BtnView.ShowHint := True;
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
  List.OnRowText := @RowText;   // type-ahead as in the library tree
  List.OnRowClick := @RowClick;
  List.OnCollapseChange := @ListCollapse;
  List.EmptyText := PL_EMPTY_TEXT;
  BtnPlaylist.TabOrder := 0;
  BtnView.TabOrder := 1;
  BtnEdit.TabOrder := 2;
  TopResize(nil);
end;

destructor TPlaylistPane.Destroy;
begin
  ClearThumbCache;
  FThumbs.Free;
  FCollapsed.Free;
  inherited Destroy;
end;

procedure TPlaylistPane.TopResize(Sender: TObject);
var
  VW: Integer;
begin
  if (BtnPlaylist = nil) or (BtnView = nil) or (BtnEdit = nil) then Exit;
  BtnEdit.SetBounds(FTop.Width - S(10) - S(34), S(9), S(34), S(34));
  VW := BtnView.PreferredWidth;
  BtnView.SetBounds(BtnEdit.Left - S(4) - VW, S(10), VW, S(32));
  BtnPlaylist.SetBounds(S(10), S(10), Math.Max(S(60), BtnView.Left - S(18)), S(32));
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
  I: Integer;
begin
  if N = 0 then Exit;
  if (InsertAt < 0) or (InsertAt > FCount) then InsertAt := FCount;
  SetLength(FEntries, FCount + N);
  for I := FCount - 1 downto InsertAt do FEntries[I + N] := FEntries[I];
  for I := 0 to N - 1 do
  begin
    Inc(FNextId);
    FEntries[InsertAt + I] := New_[I];
    FEntries[InsertAt + I].Id := FNextId;
  end;
  if (FPlaying >= InsertAt) then Inc(FPlaying, N);
  Inc(FCount, N);
  Rebuild;
  Changed;
end;

procedure TPlaylistPane.Clear;
begin
  FCount := 0;
  SetLength(FEntries, 0);
  FPlaying := -1;
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
  for I := 0 to Tracks.Count - 1 do New_[I] := EntryFromTrack(Tracks[I]^);
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
    FEntries[I] := EntryFromTrack(TrackFromEntry(AEntries[I]));
    Inc(FNextId);
    FEntries[I].Id := FNextId;
  end;
  Rebuild;
end;

function TPlaylistPane.ToEntries: TPlaylistEntries;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, FCount);
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
  Rebuild;
  Changed;
end;

procedure TPlaylistPane.MoveEntries(const Idx: TIntArray; InsertAt: Integer);
var
  Sel: array of Boolean;
  Moved, Rest: array of TPlEntry;
  I, NM, NR, At, PlayingId: Integer;
begin
  if (Length(Idx) = 0) or FReadOnly then Exit;
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
  Rebuild;
  for I := 0 to NM - 1 do List.Selected[RowOfEntry(At + I)] := True;
  Changed;
end;

procedure TPlaylistPane.SyncWithLibrary;
var
  I, Id: Integer;
  T: TTrackInfo;
  Changes: Boolean;
begin
  if not Assigned(FOnLookup) or FDemo then Exit;
  Changes := False;
  for I := 0 to FCount - 1 do
    if FOnLookup(FEntries[I].FilePath, T) then
    begin
      Id := FEntries[I].Id;
      FEntries[I] := EntryFromTrack(T);
      FEntries[I].Id := Id;
      Changes := True;
    end;
  Rebuild;
  if Changes then Changed;
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
  ADateSuffix: string; AReadOnly: Boolean);
begin
  FGroupMode := AGroupMode;
  FHeaderFmt := AHeaderFmt;
  FTrackFmt := ATrackFmt;
  FDateSuffix := ADateSuffix;
  FReadOnly := AReadOnly;
  { an auto-playlist cannot take dropped music: its own text }
  if AReadOnly then List.EmptyText := PL_AUTO_EMPTY_TEXT else List.EmptyText := PL_EMPTY_TEXT;
  List.DragEnabled := True;
  case FGroupMode of
    gmFolder: BtnView.Caption := 'By folder';
    gmFlat: BtnView.Caption := 'Flat list';
  else
    BtnView.Caption := 'By album';
  end;
  TopResize(nil);
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

var
  TrackFmt, HeaderFmt: string;
  TrackStats, HeaderStats: Boolean;
begin
  Ctx := Default(TTrackFormatContext);
  if FDemo then
  begin
    for I := 0 to FCount - 1 do FEntries[I].TitleText := FEntries[I].Title;
    for I := 0 to FHeaderCount - 1 do
      FHeaders[I].Text := FHeaders[I].Album + '  •  ' + IntToStr(FEntries[FHeaders[I].First].Year) +
        '  •  ' + FHeaders[I].AlbumArtist;
    Exit;
  end;
  { the formats, and whether they show the date added or the statistics }
  TrackFmt := FTrackFmt;
  if (FGroupMode = gmFlat) and (FDateSuffix <> '') then TrackFmt := TrackFmt + FDateSuffix;
  if (FGroupMode = gmFolder) or (FHeaderFmt = '') then HeaderFmt := '%folder%' else HeaderFmt := FHeaderFmt;
  if FDateSuffix <> '' then HeaderFmt := HeaderFmt + FDateSuffix;
  TrackStats := UsesStats(TrackFmt);
  HeaderStats := (FHeaderCount > 0) and UsesStats(HeaderFmt);
  if TrackStats or HeaderStats then LookUpAll;
  { tracks }
  Fmt := TrackFmt;
  for I := 0 to FCount - 1 do
  begin
    MetaOf(FEntries[I]);
    if TrackStats then StatsOf(I, False);
    if Fmt = '' then FEntries[I].TitleText := FEntries[I].Title
    else FEntries[I].TitleText := CleanTag(FormatTrackInfo(Fmt, Ctx));
    if FEntries[I].TitleText = '' then FEntries[I].TitleText := FEntries[I].Title;
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
    FHeaders[I].Text := CleanTag(FormatTrackInfo(Fmt, Ctx));
    if Trim(FHeaders[I].Text) = '' then
      FHeaders[I].Text := ExtractFileName(FHeaders[I].FolderDir);
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

{ the groups and the rows from the entries; nothing is selected afterwards
  (the callers select what they changed) }
procedure TPlaylistPane.Rebuild;
var
  I, H: Integer;
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
      end;
      Paths.Add(FEntries[I].FilePath);
      Inc(FHeaders[H].Count);
      Inc(FHeaders[H].TotalSec, FEntries[I].Seconds);
      FHeaderOf[I] := H;
    end;
  finally
    Paths.Free;
  end;
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
      List.AddItem(I);
    end;
  finally
    List.EndUpdate;
  end;
  { collapsed groups, by header text or album }
  if FCollapsed.Count > 0 then
    for I := 0 to List.RowCount - 1 do
      if List.Kind[I] = rkHeader then
      begin
        H := -List.Data[I] - 1;
        if (FCollapsed.IndexOf(FHeaders[H].Text) >= 0) or
           ((FHeaders[H].Album <> '') and (FCollapsed.IndexOf(FHeaders[H].Album) >= 0)) then
          List.Collapsed[I] := True;
      end;
end;

procedure TPlaylistPane.ListCollapse(Sender: TObject);
var
  I, H: Integer;
begin
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

procedure TPlaylistPane.ExpandAll;
var
  I: Integer;
begin
  for I := 0 to List.RowCount - 1 do
    if List.Kind[I] = rkHeader then List.Collapsed[I] := False;
  ListCollapse(nil);
end;

procedure TPlaylistPane.CollapseAll;
var
  I: Integer;
begin
  for I := 0 to List.RowCount - 1 do
    if List.Kind[I] = rkHeader then List.Collapsed[I] := True;
  ListCollapse(nil);
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

function TPlaylistPane.ThumbOf(const H: TPlHeader): TGfxBitmap;
var
  Hash, F: string;
  Idx: Integer;
begin
  Hash := GenerateAlbumHash(H.AlbumArtist, H.Album, H.FolderDir);
  if FThumbs.Find(Hash, Idx) then Exit(TGfxBitmap(FThumbs.Objects[Idx]));
  Result := nil;
  F := AppCacheThumbsDir + Hash + '.jpg';
  if FileExists(LongPath(F)) then Result := ImageFromFile(F, 256);
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
  F, BF, HF: TGfxFont;
  Th, TX, NumW, DurW, StW, StSz, TW: Single;
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
      if FDemo then Thumb := nil else Thumb := ThumbOf(Hdr);
      DrawTileArt(G, Thumb, X, Y + S(5), Th, Th, S(5), Hdr.Album + Hdr.AlbumArtist, False);
      TX := X + Th + S(14);
    end
    else
    begin
      DrawIcon(G, icFolder, X + S(14), Y + H / 2, S(20), clAccentText);
      TX := X + S(34);
    end;
    DrawStars(G, X + W - StW - S(4), Y + H / 2, StSz, Hdr.Rating, clAccentText);
    TW := X + W - StW - S(16) - TX;
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
  NumW := S(46);
  DurW := S(64);
  G.Text(DisplayNumber(E), X, Y, NumW, H, F, Dim, 0, 1);
  TX := X + NumW;
  if Playing then
  begin
    DrawIcon(G, icPlay, TX + S(5), Y + H / 2, H * 0.42, clAccentText);
    TX := TX + S(16);
  end;
  if Playing then G.Text(D.TitleText, TX, Y, X + W - DurW - StW - S(20) - TX, H, BF, Fg, 0, 1)
  else G.Text(D.TitleText, TX, Y, X + W - DurW - StW - S(20) - TX, H, F, Fg, 0, 1);
  DrawStars(G, X + W - DurW - StW - S(8), Y + H / 2, StSz, D.Rating, IfC(Playing, clAccentText, clTextDim));
  G.Text(D.DurationStr, X + W - DurW, Y, DurW, H, F, Dim, 2, 1);
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
  Rc: TRect;
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
  Rc := List.RowRect(R);
  InView := (Rc.Bottom > Rc.Top) and (Rc.Top >= 0) and (Rc.Bottom <= List.ClientHeight);
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

  procedure Add(const Album, Artist, Folder: string; Year, No: Integer; const D: TDemoTrack);
  begin
    SetLength(FEntries, FCount + 1);
    FEntries[FCount] := Default(TPlEntry);
    FEntries[FCount].Title := D.T;
    FEntries[FCount].Album := Album;
    FEntries[FCount].AlbumArtist := Artist;
    FEntries[FCount].Artist := Artist;
    FEntries[FCount].Year := Year;
    FEntries[FCount].DiscNum := 1;
    FEntries[FCount].TrackNum := No;
    FEntries[FCount].Seconds := D.Sec;
    FEntries[FCount].DurationStr := FormatDuration(D.Sec);
    FEntries[FCount].Rating := D.R;
    FEntries[FCount].FolderDir := Folder;
    FEntries[FCount].FilePath := Folder + '\' + D.T + '.flac';
    FEntries[FCount].GroupKey := Album;
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
  for I := 0 to High(A1) do Add('Silence, Noise and Calm', 'Andy Lu', 'D:\Music\Andy Lu\Silence', 2026, I + 1, A1[I]);
  for I := 0 to High(A2) do Add('Silent Skies', 'Northern Lights Quartet', 'D:\Music\NLQ\Silent Skies', 2005, I + 1, A2[I]);
  FPlaying := 0;
  Rebuild;
  { the demo's ratings are its own (no user stats) }
  for I := 0 to FHeaderCount - 1 do FHeaders[I].Rating := 0;
end;

end.
