unit uInspectorSummary;

{ ==============================================================================
  AulumicNS - uInspectorSummary
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The text the Inspector of Properties shows for several selected tracks: how
  many, their total time and size, and for each property what the tracks have
  in common - one value, or the most frequent values with their counts.
  The caller fills one TInspectorItem per track from what it already knows
  (the library's record, the values in the editor, the play statistics); no
  file is read here.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  { so many different values of a property are named, the rest is counted }
  INSPECTOR_MAX_VALUES = 4;

type
  TInspectorItem = record
    FilePath      : string;
    FormatName    : string;
    { the library has a record of the file: size, length, rate, depth, date
      added and the ReplayGain flag are known }
    InLibrary     : Boolean;
    FileSize      : Int64;
    Seconds       : Integer;
    SampleRate    : Integer;
    BitDepth      : Integer;
    DateAdded     : Int64;      // Unix time, 0 = unknown
    HasReplayGain : Boolean;
    AlbumArtist   : string;
    Album         : string;
    Year          : string;
    Genre         : string;
    PlayCount     : Integer;
    LastPlayed    : Int64;      // Unix time, 0 = never
    Rating        : Integer;    // 0 = not rated
    Favourite     : Boolean;
  end;
  TInspectorItems = array of TInspectorItem;

{ 'm:ss' below an hour, 'h:mm:ss' from there on }
function SecondsToDuration(ASeconds: Int64): string;
{ megabytes, gigabytes from 1024 MB on }
function InspectorSizeText(ABytes: Int64): string;
{ AWithStats: with the section of the play statistics }
function InspectorSummary(const AItems: TInspectorItems; AWithStats: Boolean): string;

implementation

uses
  DateUtils, uAppConsts, uAppStrings;

type
  { the different values of one property with the number of tracks that have
    each, in the order they were first seen }
  TTally = class
  private
    FNames: TStringList;
    FLast: Integer;   // the value added last: tracks of an album repeat it
    function CountOf(AIndex: Integer): Integer;
    function Order: TBoundArray;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AValue: string);
    function Count: Integer;
    { one value: the value; several: 'A (10), B (4), and 3 more' }
    function Text: string;
    { several values, one per line: '  A (10)' ... '  and 3 more' }
    function Lines: string;
    function First: string;
  end;

constructor TTally.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FNames.CaseSensitive := True;
  FNames.UseLocale := False;
  FLast := -1;
end;

destructor TTally.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

procedure TTally.Add(const AValue: string);
var
  I: Integer;
  V: string;
begin
  V := Trim(AValue);
  if V = '' then V := INS_VAL_EMPTY;
  if (FLast >= 0) and (FNames[FLast] = V) then I := FLast
  else I := FNames.IndexOf(V);
  if I < 0 then I := FNames.AddObject(V, TObject(PtrInt(1)))
  else FNames.Objects[I] := TObject(PtrInt(CountOf(I) + 1));
  FLast := I;
end;

function TTally.Count: Integer;
begin
  Result := FNames.Count;
end;

function TTally.CountOf(AIndex: Integer): Integer;
begin
  Result := Integer(PtrInt(FNames.Objects[AIndex]));
end;

function TTally.First: string;
begin
  if FNames.Count > 0 then Result := FNames[0] else Result := '';
end;

{ the values by their counts, the most frequent first; values with the same
  count keep the order they were first seen in }
function TTally.Order: TBoundArray;
var
  I, J, T: Integer;
begin
  Result := nil;
  SetLength(Result, FNames.Count);
  for I := 0 to High(Result) do Result[I] := I;
  for I := 1 to High(Result) do
  begin
    T := Result[I];
    J := I - 1;
    while (J >= 0) and (CountOf(Result[J]) < CountOf(T)) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := T;
  end;
end;

function TTally.Text: string;
var
  O: TBoundArray;
  I: Integer;
begin
  Result := '';
  if FNames.Count = 0 then Exit;
  if FNames.Count = 1 then Exit(FNames[0]);
  O := Order;
  for I := 0 to High(O) do
  begin
    if I >= INSPECTOR_MAX_VALUES then
    begin
      Result := Result + Format(FMT_INS_MORE, [Length(O) - I]);
      Break;
    end;
    if I > 0 then Result := Result + ', ';
    Result := Result + Format(FMT_INS_COUNTED, [FNames[O[I]], CountOf(O[I])]);
  end;
end;

function TTally.Lines: string;
var
  O: TBoundArray;
  I: Integer;
begin
  Result := '';
  O := Order;
  for I := 0 to High(O) do
  begin
    if I >= INSPECTOR_MAX_VALUES then
    begin
      Result := Result + Format(FMT_INS_MORE_LINE, [Length(O) - I]) + LineEnding;
      Break;
    end;
    Result := Result + '  ' + Format(FMT_INS_COUNTED, [FNames[O[I]], CountOf(O[I])]) + LineEnding;
  end;
end;

function SecondsToDuration(ASeconds: Int64): string;
begin
  if ASeconds < 0 then ASeconds := 0;
  if ASeconds >= 3600 then
    Result := Format('%d:%.2d:%.2d', [ASeconds div 3600, (ASeconds mod 3600) div 60, ASeconds mod 60])
  else
    Result := Format('%d:%.2d', [ASeconds div 60, ASeconds mod 60]);
end;

function InspectorSizeText(ABytes: Int64): string;
begin
  if ABytes >= Int64(1024) * BYTES_PER_MB then
    Result := Format(FMT_SIZE_GB, [ABytes / BYTES_PER_MB / 1024])
  else
    Result := Format(FMT_SIZE_MB, [ABytes / BYTES_PER_MB]);
end;

function InspectorSummary(const AItems: TInspectorItems; AWithStats: Boolean): string;
var
  Formats, Rates, Depths, Folders, AlbumArtists, Albums, Years, Genres: TTally;
  I, InLib, WithGain, Never, Rated, Favourites: Integer;
  TotalSize, TotalSecs, TotalPlays, RatingSum, FirstAdded, LastAdded, LastPlayed: Int64;
  S, D1, D2: string;

  procedure Line(const ALabel, AValue: string);
  begin
    if AValue <> '' then S := S + ALabel + AValue + LineEnding;
  end;

begin
  Result := '';
  if Length(AItems) = 0 then Exit;
  Formats := TTally.Create;
  Rates := TTally.Create;
  Depths := TTally.Create;
  Folders := TTally.Create;
  AlbumArtists := TTally.Create;
  Albums := TTally.Create;
  Years := TTally.Create;
  Genres := TTally.Create;
  try
    InLib := 0;
    WithGain := 0;
    Never := 0;
    Rated := 0;
    Favourites := 0;
    TotalSize := 0;
    TotalSecs := 0;
    TotalPlays := 0;
    RatingSum := 0;
    FirstAdded := 0;
    LastAdded := 0;
    LastPlayed := 0;
    for I := 0 to High(AItems) do
    begin
      Formats.Add(AItems[I].FormatName);
      Folders.Add(ExtractFileDir(AItems[I].FilePath));
      AlbumArtists.Add(AItems[I].AlbumArtist);
      Albums.Add(AItems[I].Album);
      Years.Add(AItems[I].Year);
      Genres.Add(AItems[I].Genre);
      if AItems[I].InLibrary then
      begin
        Inc(InLib);
        Inc(TotalSize, AItems[I].FileSize);
        if AItems[I].Seconds > 0 then Inc(TotalSecs, AItems[I].Seconds);
        if AItems[I].SampleRate > 0 then Rates.Add(Format(FMT_INS_SAMPLE_RATE, [AItems[I].SampleRate]));
        if AItems[I].BitDepth > 0 then Depths.Add(Format(FMT_INS_BIT_DEPTH, [AItems[I].BitDepth]));
        if AItems[I].HasReplayGain then Inc(WithGain);
        if AItems[I].DateAdded > 0 then
        begin
          if (FirstAdded = 0) or (AItems[I].DateAdded < FirstAdded) then FirstAdded := AItems[I].DateAdded;
          if AItems[I].DateAdded > LastAdded then LastAdded := AItems[I].DateAdded;
        end;
      end;
      Inc(TotalPlays, AItems[I].PlayCount);
      if AItems[I].PlayCount = 0 then Inc(Never);
      if AItems[I].LastPlayed > LastPlayed then LastPlayed := AItems[I].LastPlayed;
      if AItems[I].Rating > 0 then
      begin
        Inc(Rated);
        Inc(RatingSum, AItems[I].Rating);
      end;
      if AItems[I].Favourite then Inc(Favourites);
    end;

    S := INS_HDR_SELECTION + LineEnding;
    Line(INS_LBL_TRACKS_SELECTED, IntToStr(Length(AItems)));
    if InLib < Length(AItems) then Line(INS_LBL_NOT_IN_LIBRARY, IntToStr(Length(AItems) - InLib));
    if TotalSecs > 0 then Line(INS_LBL_TOTAL_TIME, SecondsToDuration(TotalSecs));
    if InLib > 0 then Line(INS_LBL_TOTAL_FILE_SIZE, InspectorSizeText(TotalSize));

    S := S + LineEnding + INS_HDR_AUDIO_CHAR + LineEnding;
    Line(INS_LBL_FORMAT, Formats.Text);
    Line(INS_LBL_SAMPLE_RATE, Rates.Text);
    Line(INS_LBL_BIT_DEPTH, Depths.Text);

    S := S + LineEnding + INS_HDR_FILE_INFO + LineEnding;
    if Folders.Count = 1 then
      Line(INS_LBL_FOLDER_PATH, Folders.First)
    else
    begin
      Line(INS_LBL_FOLDERS, IntToStr(Folders.Count));
      S := S + Folders.Lines;
    end;
    if FirstAdded > 0 then
    begin
      D1 := DateToStr(UnixToDateTime(FirstAdded, False));
      D2 := DateToStr(UnixToDateTime(LastAdded, False));
      if D1 = D2 then Line(INS_LBL_DATE_ADDED, D1)
      else Line(INS_LBL_DATE_ADDED, Format(FMT_INS_DATE_RANGE, [D1, D2]));
    end;

    S := S + LineEnding + INS_HDR_TAGS + LineEnding;
    Line(INS_LBL_ALBUM_ARTIST, AlbumArtists.Text);
    Line(INS_LBL_ALBUM, Albums.Text);
    Line(INS_LBL_YEAR, Years.Text);
    Line(INS_LBL_GENRE, Genres.Text);
    if InLib > 0 then
    begin
      if WithGain = InLib then Line(INS_LBL_REPLAYGAIN, INS_VAL_ALL_TRACKS)
      else if WithGain = 0 then Line(INS_LBL_REPLAYGAIN, INS_VAL_NO_TRACK)
      else Line(INS_LBL_REPLAYGAIN, Format(FMT_INS_OF_TRACKS, [WithGain, InLib]));
    end;

    if AWithStats then
    begin
      S := S + LineEnding + INS_HDR_USER_STATS + LineEnding;
      D1 := Format(FMT_INS_PLAYS, [TotalPlays]);
      if (Never > 0) and (TotalPlays > 0) then D1 := D1 + Format(FMT_INS_NEVER_PLAYED, [Never]);
      Line(INS_LBL_PLAY_COUNT, D1);
      if LastPlayed > 0 then Line(INS_LBL_LAST_PLAYED, DateTimeToStr(UnixToDateTime(LastPlayed, False)))
      else Line(INS_LBL_LAST_PLAYED, LBL_NEVER);
      if Rated > 0 then
        Line(INS_LBL_RATING, Format(FMT_INS_RATED, [Rated, Length(AItems), RatingSum / Rated]))
      else
        Line(INS_LBL_RATING, INS_VAL_NOT_RATED);
      if Favourites > 0 then Line(INS_LBL_FAVOURITES, IntToStr(Favourites));
    end;
    Result := TrimRight(S);
  finally
    Formats.Free;
    Rates.Free;
    Depths.Free;
    Folders.Free;
    AlbumArtists.Free;
    Albums.Free;
    Years.Free;
    Genres.Free;
  end;
end;

end.
