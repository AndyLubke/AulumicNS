unit uPlaylistRows;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uPlaylistRows
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The playlist's rows without any UI:
    TTrackNodeData            the data of one playlist row (track or group
                              header), as the playlist tree stores it
    EntryFromTrack /          the fields a library track and a stored
    TrackFromEntry            playlist entry share, copied between them
    CleanTag                  a tag as a row shows it (one line)
    TimeStrToSecs /           track lengths ('m:ss', 'h:mm:ss') and a group's
    FormatGroupDuration       total time ('1h 5m', '42m 7s')
    PlaylistGroupKey          which group a track belongs to (also the
                              groups of a date-ordered auto-playlist)

    RatingTags / RowRating-   the album artist / album / title a row's rating
    Fingerprint               is stored under (the library's rule)
    AverageRating, StarAt-    group rating, which star a click hits, and
    Offset, NextRating        "the same star again clears the rating"
    FitTextWithEllipsis /     a group header's text in one or two lines of a
    SplitHeaderIntoTwoLines   given width (measured by a width function)
    RowFileState /            Remove dead items: present, missing, or on a
    IsOnOfflineDrive          drive that is not connected (the row is kept)
  Covered by Tests\TestPlaylistRows.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils, uAppConsts, uLibraryTypes, uPlaylistFile;

type
  PTrackNodeData = ^TTrackNodeData;

  TTrackNodeData = record
    IsGroupHeader: boolean;
    AlbumTitle: string;
    TrackNum: integer;
    DiscNum: integer;
    Title: string;
    Artist: string;
    AlbumArtist: string;
    Album: string;
    Genre: string;
    DurationStr: string;
    FilePath: string;
    SessionId: Integer;

    Year: integer;
    DateStr: string;
    SampleRate: integer;
    BitDepth: integer;
    // Track is not in the library. Not shown yet.
    NotInLibrary: boolean;
  end;

  // Width of S in pixels (a canvas' TextWidth in the playlist)
  TTextWidthFunc = function(const S: string): Integer of object;

  // Remove dead items: what became of a row's file (RowFileState)
  TRowFileState = (
    rfsPresent,       // the file exists
    rfsMissing,       // its drive answers, the file is gone: a dead row
    rfsDriveOffline   // its drive cannot be reached: the row is kept
  );
  // Does the file exist (FileExists; a parameter, so the rule can be tested)
  TFileExistsFunc = function(const APath: string): Boolean;

// ---- Copying between a row, a library track and a playlist-file entry ----

// A playlist-file entry of the track (HasGenre / HasExtendedInfo set)
function  EntryFromTrack(const ATrack: TTrackInfo): TPlaylistEntry;
// A track with the entry's path (FolderDir from it) and fields; the rest empty
function  TrackFromEntry(const AEntry: TPlaylistEntry): TTrackInfo;

// ---- Works (a symphony whose movements are tracks) ----

type
  // A track of a group, for FindWorks
  TWorkRow = record
    Title, Work: string;   // in: the title and the work of its tag ('' = none)
    Disc: Integer;         // in: its disc number
    Heading: string;       // out: the work's name when a heading belongs above this track
    Part: string;          // out: the title to show under a heading ('' = the whole title)
    First, Last: Integer;  // out: the first and last track of its work in the list (-1: in no work)
  end;
  TWorkRows = array of TWorkRow;

// The work a title names in front of a colon: 'Symphony No. 5: I. Allegro'
// is the work 'Symphony No. 5' and its part 'I. Allegro'. False without
// ': ', or when the work is shorter than three characters or the part empty.
function  SplitWorkTitle(const ATitle: string; out AWork, APart: string): Boolean;
// The works among the tracks of one group, in their order. A work is two or
// more tracks in a row of one disc with the same work: that of the tag, else
// the one their titles name (SplitWorkTitle). Its first track gets the
// heading; the tracks get their part as the title when all their titles
// name the same work in front of the colon. A work of a single track gets
// no heading: its title says it all.
procedure FindWorks(var ARows: TWorkRows);

// ---- Row rules ----

// S trimmed and on one line (CR / LF become spaces)
function  CleanTag(const S: string): string;
// 'm:ss' or 'h:mm:ss' in seconds; 0 when there is no ':'
function  TimeStrToSecs(const S: string): Integer;
// A group's total time: '1h 5m' from one hour on, else '42m 7s'
function  FormatGroupDuration(ATotalSecs: Integer): string;
// The group of ATrack: its folder (gmFolder); folder, album artist and album
// (gmAlbum); '' in a flat list
function  PlaylistGroupKey(const ATrack: TTrackInfo; AGrouping: TGroupingMode): string;
// Remove dead items. True when APath is on a drive in AOfflineDrives (drives
// / shares that could not be reached, as ExtractFileDrive gives them: 'E:',
// '\\NAS\Music'; any case).
function  IsOnOfflineDrive(const APath: string; AOfflineDrives: TStrings): Boolean;
// The file of a row at APath: on an offline drive rfsDriveOffline, and
// AFileExists is not called (it could hang on an unreachable share);
// otherwise present or missing by AFileExists.
function  RowFileState(const APath: string; AOfflineDrives: TStrings;
  AFileExists: TFileExistsFunc): TRowFileState;

// ---- Ratings ----

// The album artist and album a row's rating is stored under: album artist,
// else artist, else 'Unknown Artist'; album, else 'Unknown Album' (as the
// library builds its fingerprints)
procedure RatingTags(const ARow: TTrackNodeData; out AArtist, AAlbum: string);
// The play-statistics key of the row's rating ('' without UserStatsManager)
function  RowRatingFingerprint(const ARow: TTrackNodeData): string;
// The rounded average of ACount ratings that add up to ATotal (0 when none)
function  AverageRating(ATotal, ACount: Integer): Integer;
// The star (1..5) at AOffset when 5 stars of AStarWidth start at AStartX;
// 0 when the offset is not on the stars
function  StarAtOffset(AOffset, AStartX, AStarWidth: Integer): Integer;
// The new rating after a click on star AClicked: clicking the current
// rating again clears it (0)
function  NextRating(AClicked, ACurrent: Integer): Integer;

// ---- Group header text ----

// AText, shortened with '...' at the end when wider than AMaxWidth
function  FitTextWithEllipsis(const AText: string; AMaxWidth: Integer;
  AWidthOf: TTextWidthFunc): string;
// AText in two lines of at most AMaxWidth: preferably split at a ' • '
// (the last one where both halves fit, else the last one where the first
// half fits), else after the last space / '\' / '/' that fits; what still
// does not fit is shortened with '...'. ALine2 = '' when one line is used.
procedure SplitHeaderIntoTwoLines(const AText: string; AMaxWidth: Integer;
  AWidthOf: TTextWidthFunc; out ALine1, ALine2: string);

implementation

uses
  StrUtils, uAppStrings, uOSUtils, uUserStatsManager;

{ Works }

function SplitWorkTitle(const ATitle: string; out AWork, APart: string): Boolean;
var
  P: Integer;
begin
  AWork := '';
  APart := '';
  P := Pos(': ', ATitle);
  if P < 2 then Exit(False);
  AWork := Trim(Copy(ATitle, 1, P - 1));
  APart := Trim(Copy(ATitle, P + 2, MaxInt));
  Result := (Length(AWork) >= 3) and (APart <> '');
  if not Result then
  begin
    AWork := '';
    APart := '';
  end;
end;

procedure FindWorks(var ARows: TWorkRows);
var
  Cand, InTitle, Parts: array of string;
  N, I, J, K: Integer;
  SamePrefix: Boolean;
begin
  N := Length(ARows);
  Cand := nil;
  InTitle := nil;
  Parts := nil;
  SetLength(Cand, N);
  SetLength(InTitle, N);
  SetLength(Parts, N);
  for I := 0 to N - 1 do
  begin
    ARows[I].Heading := '';
    ARows[I].Part := '';
    ARows[I].First := -1;
    ARows[I].Last := -1;
    SplitWorkTitle(ARows[I].Title, InTitle[I], Parts[I]);
    Cand[I] := Trim(ARows[I].Work);
    if Cand[I] = '' then Cand[I] := InTitle[I];
  end;
  I := 0;
  while I < N do
  begin
    J := I;
    if Cand[I] <> '' then
      while (J + 1 < N) and (ARows[J + 1].Disc = ARows[I].Disc) and (AnsiCompareText(Cand[J + 1], Cand[I]) = 0) do
        Inc(J);
    if J > I then
    begin
      ARows[I].Heading := Cand[I];
      for K := I to J do
      begin
        ARows[K].First := I;
        ARows[K].Last := J;
      end;
      SamePrefix := InTitle[I] <> '';
      for K := I + 1 to J do
        if (InTitle[K] = '') or (AnsiCompareText(InTitle[K], InTitle[I]) <> 0) then SamePrefix := False;
      if SamePrefix then
        for K := I to J do ARows[K].Part := Parts[K];
    end;
    I := J + 1;
  end;
end;

{ Copying }

function EntryFromTrack(const ATrack: TTrackInfo): TPlaylistEntry;
begin
  Result             := Default(TPlaylistEntry);
  Result.FilePath    := ATrack.FilePath;
  Result.Title       := ATrack.Title;
  Result.Artist      := ATrack.Artist;
  Result.AlbumArtist := ATrack.AlbumArtist;
  Result.Album       := ATrack.Album;
  Result.Genre       := ATrack.Genre;
  Result.DurationStr := ATrack.DurationStr;
  Result.TrackNum    := ATrack.TrackNumber;
  Result.DiscNum     := ATrack.DiscNumber;
  Result.Year        := ATrack.Year;
  Result.DateStr     := ATrack.DateStr;
  Result.SampleRate  := ATrack.SampleRate;
  Result.BitDepth    := ATrack.BitDepth;
  Result.HasGenre        := True;
  Result.HasExtendedInfo := True;
end;

function TrackFromEntry(const AEntry: TPlaylistEntry): TTrackInfo;
begin
  Result             := Default(TTrackInfo);
  Result.FilePath    := AEntry.FilePath;
  Result.FolderDir   := ExtractFileDir(AEntry.FilePath);
  Result.Title       := AEntry.Title;
  Result.Artist      := AEntry.Artist;
  Result.AlbumArtist := AEntry.AlbumArtist;
  Result.Album       := AEntry.Album;
  Result.Genre       := AEntry.Genre;
  Result.DurationStr := AEntry.DurationStr;
  Result.TrackNumber := AEntry.TrackNum;
  Result.DiscNumber  := AEntry.DiscNum;
  Result.Year        := AEntry.Year;
  Result.DateStr     := AEntry.DateStr;
  Result.SampleRate  := AEntry.SampleRate;
  Result.BitDepth    := AEntry.BitDepth;
end;

{ Row rules }

function CleanTag(const S: string): string;
var
  K: Integer;
  HasCtrl: Boolean;
begin
  Result := Trim(S);
  if Result = '' then Exit;

  HasCtrl := False;
  for K := 1 to Length(Result) do
    if Result[K] in [#10, #13] then
    begin
      HasCtrl := True;
      Break;
    end;

  if not HasCtrl then Exit;

  Result := StringReplace(Result, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
end;

function TimeStrToSecs(const S: string): Integer;
var
  P1, P2, H, M, Sec: integer;
begin
  Result := 0;
  P1 := Pos(':', S);
  if P1 = 0 then Exit;
  P2 := PosEx(':', S, P1 + 1);
  if P2 > 0 then
  begin
    H      := StrToIntDef(Copy(S, 1, P1 - 1), 0);
    M      := StrToIntDef(Copy(S, P1 + 1, P2 - P1 - 1), 0);
    Sec    := StrToIntDef(Copy(S, P2 + 1, Length(S)), 0);
    Result := (H * 3600) + (M * 60) + Sec;
  end
  else
  begin
    M      := StrToIntDef(Copy(S, 1, P1 - 1), 0);
    Sec    := StrToIntDef(Copy(S, P1 + 1, Length(S)), 0);
    Result := (M * 60) + Sec;
  end;
end;

function FormatGroupDuration(ATotalSecs: Integer): string;
begin
  if ATotalSecs >= 3600 then
    Result := SafeFormat(FMT_DURATION_HM, [ATotalSecs div 3600, (ATotalSecs mod 3600) div 60])
  else
    Result := SafeFormat(FMT_DURATION_MS, [ATotalSecs div 60, ATotalSecs mod 60]);
end;

// The group key of the playlist's rows and of
// uAutoPlaylist.SortAutoPlaylistByDate (GKey)
function PlaylistGroupKey(const ATrack: TTrackInfo; AGrouping: TGroupingMode): string;
begin
  case AGrouping of
    gmFolder: Result := ATrack.FolderDir;
    gmAlbum:  Result := ATrack.FolderDir + '|' + ATrack.AlbumArtist + '|' + ATrack.Album;
  else
    Result := '';
  end;
end;

function IsOnOfflineDrive(const APath: string; AOfflineDrives: TStrings): Boolean;
var
  Drive: string;
  I    : Integer;
begin
  Result := False;
  if not Assigned(AOfflineDrives) then
    Exit;
  Drive := ExtractFileDrive(Trim(APath));
  if Drive = '' then
    Exit;
  for I := 0 to AOfflineDrives.Count - 1 do
    if SameText(AOfflineDrives[I], Drive) then
      Exit(True);
end;

// Only a file that is gone from a drive that answers is dead. (Without this
// rule Remove dead items would remove every row of a USB disk that is not
// connected.) Used by TMainForm.MnRemoveDead.
function RowFileState(const APath: string; AOfflineDrives: TStrings;
  AFileExists: TFileExistsFunc): TRowFileState;
begin
  if IsOnOfflineDrive(APath, AOfflineDrives) then
    Exit(rfsDriveOffline);

  if AFileExists(APath) then
    Result := rfsPresent
  else
    Result := rfsMissing;
end;

{ Ratings }

// The rule of the star clicks and the rating menu
procedure RatingTags(const ARow: TTrackNodeData; out AArtist, AAlbum: string);
begin
  AArtist := ARow.AlbumArtist;
  if AArtist = '' then AArtist := ARow.Artist;
  if AArtist = '' then AArtist := LBL_UNKNOWN_ARTIST;
  AAlbum := ARow.Album;
  if AAlbum = '' then AAlbum := LBL_UNKNOWN_ALBUM;
end;

function RowRatingFingerprint(const ARow: TTrackNodeData): string;
var
  Artist, Album: string;
begin
  Result := '';
  if not Assigned(UserStatsManager) then
    Exit;
  RatingTags(ARow, Artist, Album);
  Result := UserStatsManager.GenerateFingerprint(Artist, Album, ARow.Title);
end;

function AverageRating(ATotal, ACount: Integer): Integer;
begin
  if ACount > 0 then
    Result := Round(ATotal / ACount)
  else
    Result := 0;
end;

function StarAtOffset(AOffset, AStartX, AStarWidth: Integer): Integer;
begin
  Result := 0;
  if (AStarWidth <= 0) or (AOffset < AStartX) or (AOffset > AStartX + AStarWidth * 5) then
    Exit;
  Result := ((AOffset - AStartX) div AStarWidth) + 1;
  if Result > 5 then Result := 5;
  if Result < 1 then Result := 1;
end;

function NextRating(AClicked, ACurrent: Integer): Integer;
begin
  if AClicked = ACurrent then
    Result := 0
  else
    Result := AClicked;
end;

{ Group header text }

// The text is measured by AWidthOf, so no canvas is needed
function FitTextWithEllipsis(const AText: string; AMaxWidth: Integer;
  AWidthOf: TTextWidthFunc): string;
var
  TempStr: UnicodeString;
begin
  Result := AText;
  if (Result = '') or (AMaxWidth <= 0) or (AWidthOf(Result) <= AMaxWidth) then
    Exit;

  TempStr := UnicodeString(Result);
  while (Length(TempStr) > 1) and
        (AWidthOf(String(TempStr) + '...') > AMaxWidth) do
  begin
    SetLength(TempStr, Length(TempStr) - 1);
  end;
  Result := TrimRight(String(TempStr)) + '...';
end;

// The text is measured by AWidthOf, so no canvas is needed
procedure SplitHeaderIntoTwoLines(const AText: string; AMaxWidth: Integer;
  AWidthOf: TTextWidthFunc; out ALine1, ALine2: string);
const
  BULLET_SEP = ' • ';
var
  SearchPos, FoundPos, BestFitPos, LastFitBulletPos: Integer;
  CandidateL1, CandidateL2: string;
  I, BestSpacePos: Integer;
begin
  ALine1 := Trim(AText);
  ALine2 := '';
  if (ALine1 = '') or (AMaxWidth <= 0) then
    Exit;

  BestFitPos       := 0;
  LastFitBulletPos := 0;
  SearchPos        := 1;

  while SearchPos <= Length(AText) do
  begin
    FoundPos := Pos(BULLET_SEP, Copy(AText, SearchPos, MaxInt));
    if FoundPos = 0 then
      Break;

    FoundPos    := SearchPos + FoundPos - 1;
    CandidateL1 := Trim(Copy(AText, 1, FoundPos - 1));
    CandidateL2 := Trim(Copy(AText, FoundPos + Length(BULLET_SEP), MaxInt));

    if (CandidateL1 <> '') and (AWidthOf(CandidateL1) <= AMaxWidth) then
    begin
      LastFitBulletPos := FoundPos;
      if AWidthOf(CandidateL2) <= AMaxWidth then
        BestFitPos := FoundPos;
    end;

    SearchPos := FoundPos + Length(BULLET_SEP);
  end;

  if BestFitPos > 0 then
  begin
    ALine1 := Trim(Copy(AText, 1, BestFitPos - 1));
    ALine2 := Trim(Copy(AText, BestFitPos + Length(BULLET_SEP), MaxInt));
  end
  else if LastFitBulletPos > 0 then
  begin
    ALine1 := Trim(Copy(AText, 1, LastFitBulletPos - 1));
    ALine2 := FitTextWithEllipsis(
      Trim(Copy(AText, LastFitBulletPos + Length(BULLET_SEP), MaxInt)),
      AMaxWidth,
      AWidthOf
    );
  end
  else
  begin
    BestSpacePos := 0;
    for I := 1 to Length(AText) do
    begin
      if AText[I] in [' ', '\', '/'] then
      begin
        if AText[I] in ['\', '/'] then
          CandidateL1 := Trim(Copy(AText, 1, I))
        else
          CandidateL1 := Trim(Copy(AText, 1, I - 1));

        if (CandidateL1 <> '') and (AWidthOf(CandidateL1) <= AMaxWidth) then
          BestSpacePos := I
        else if AWidthOf(CandidateL1) > AMaxWidth then
          Break;
      end;
    end;

    if BestSpacePos > 0 then
    begin
      if AText[BestSpacePos] in ['\', '/'] then
      begin
        ALine1 := Trim(Copy(AText, 1, BestSpacePos));
        ALine2 := Trim(Copy(AText, BestSpacePos + 1, MaxInt));
      end
      else
      begin
        ALine1 := Trim(Copy(AText, 1, BestSpacePos - 1));
        ALine2 := Trim(Copy(AText, BestSpacePos + 1, MaxInt));
      end;
      ALine2 := FitTextWithEllipsis(ALine2, AMaxWidth, AWidthOf);
    end
    else
    begin
      ALine1 := FitTextWithEllipsis(AText, AMaxWidth, AWidthOf);
      ALine2 := '';
    end;
  end;
end;

end.
