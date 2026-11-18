unit uLibraryDatabase;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uLibraryDatabase
  Author:    André Lubke
  Created:   2026 (split from uLibraryManager)

  The line format of the library file (Library.db), UTF-8 text:
    ?FOLDER?<library folder>
    ?LINK?<link file>[TAB<target folder>]        (virtual folders)
    one line per track, 21 TAB-separated fields:
      FilePath FolderDir Title Artist Album Genre TrackNumber LastModified
      DurationStr AlbumArtist DiscNumber Year DateStr SampleRate BitDepth
      DateAdded HasReplayGain FileSize Comment Composer Performer
  Older files have fewer fields (at least 7) and may use '|' instead of TAB.
  Text fields are encoded with EncodeDbField: TAB -> '<tab>', line break ->
  '<br>', '<' -> '<lt>' (so a literal '<br>' in a tag survives), other control
  characters are dropped.

  ---> AulumicNS: a unit of the TEST program (it was in src\library until
  2026-11-12). AulumicNS stores its library in its own format (uDbStore) and
  has no import from Aulumic; the tests write a library by hand as this text
  and load it with ImportAulumicDatabase, which hands the records to
  TLibraryManager.ReplaceContent. Covered by Tests\TestLibraryLogic.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils, uLibraryTypes, uLibraryManager;

const
  DB_FOLDER_MARKER = '?FOLDER?';  // line prefix for a library root folder
  // Line prefix for a virtual folder (.aullink): one line per target,
  // '?LINK?<link file>'#9'<target folder>' ('?LINK?<link file>' when it has
  // none)
  DB_LINK_MARKER   = '?LINK?';

// Replaces the content of ALib with the text file AFile (folders, virtual
// folders, tracks with their dates added) and marks it changed. Returns the
// number of tracks, -1 when the file could not be read or a scan runs.
function ImportAulumicDatabase(ALib: TLibraryManager; const AFile: string): Integer;

function EncodeDbField(const S: string): string;
function DecodeDbField(const S: string): string;

// One track line in the current format (21 fields)
function FormatTrackLine(const ATrack: TTrackInfo): string;

// Reads a track line of any version. False when it has fewer than 7 fields.
// Fills the stored fields only; the search fields (Clean*, FileNameOnly) and
// the fingerprints are left empty.
function ParseTrackLine(const ALine: string; out ATrack: TTrackInfo): Boolean;

implementation

uses
  StrUtils, DateUtils, uAppConsts, uMetaUtils;

function ImportAulumicDatabase(ALib: TLibraryManager; const AFile: string): Integer;
var
  SL, Folders, Links: TStringList;
  Tracks: TTrackInfoArray;
  I, N, TabPos, Idx: Integer;
  Line, LinkPath, Target: string;
begin
  Result := -1;
  if not FileExists(AFile) then
    Exit;
  SL      := TStringList.Create;
  Folders := TStringList.Create;
  Links   := TStringList.Create;
  try
    Links.OwnsObjects := True;   // the target lists
    try
      SL.LoadFromFile(AFile, TEncoding.UTF8);
    except
      Exit;
    end;
    Tracks := nil;
    SetLength(Tracks, SL.Count);
    N := 0;
    for I := 0 to SL.Count - 1 do
    begin
      Line := SL[I];
      if StartsText(DB_FOLDER_MARKER, Line) then
      begin
        Folders.Add(DecodeDbField(Copy(Line, Length(DB_FOLDER_MARKER) + 1, MaxInt)));
        Continue;
      end;
      if StartsText(DB_LINK_MARKER, Line) then
      begin
        // '<link file>'#9'<target folder>', or only '<link file>'
        Line   := Copy(Line, Length(DB_LINK_MARKER) + 1, MaxInt);
        TabPos := Pos(#9, Line);
        if TabPos > 0 then
        begin
          LinkPath := DecodeDbField(Copy(Line, 1, TabPos - 1));
          Target   := DecodeDbField(Copy(Line, TabPos + 1, MaxInt));
        end
        else
        begin
          LinkPath := DecodeDbField(Line);
          Target   := '';
        end;
        if LinkPath = '' then
          Continue;
        Idx := Links.IndexOf(LinkPath);
        if Idx < 0 then
          Idx := Links.AddObject(LinkPath, TStringList.Create);
        if Target <> '' then
          TStringList(Links.Objects[Idx]).Add(Target);
        Continue;
      end;
      // lines with fewer than 7 fields are skipped
      if ParseTrackLine(Line, Tracks[N]) then
        Inc(N);
    end;
    SetLength(Tracks, N);
    Result := ALib.ReplaceContent(Tracks, Folders, Links);
  finally
    Links.Free;
    Folders.Free;
    SL.Free;
  end;
end;

function EncodeDbField(const S: string): string;
var
  I, DestIdx: Integer;
  C: Char;
begin
  if S = '' then
    Exit('');

  SetLength(Result, Length(S) * 5);
  DestIdx := 1;

  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      #9:
        begin
          Result[DestIdx]     := '<';
          Result[DestIdx + 1] := 't';
          Result[DestIdx + 2] := 'a';
          Result[DestIdx + 3] := 'b';
          Result[DestIdx + 4] := '>';
          Inc(DestIdx, 5);
        end;
      #10:
        begin
          if (I > 1) and (S[I - 1] = #13) then
            Continue
          else
          begin
            Result[DestIdx]     := '<';
            Result[DestIdx + 1] := 'b';
            Result[DestIdx + 2] := 'r';
            Result[DestIdx + 3] := '>';
            Inc(DestIdx, 4);
          end;
        end;
      #13, #11, #12:
        begin
          Result[DestIdx]     := '<';
          Result[DestIdx + 1] := 'b';
          Result[DestIdx + 2] := 'r';
          Result[DestIdx + 3] := '>';
          Inc(DestIdx, 4);
        end;
      // ---> AUDIT FIX D4: Escape '<' so literal '<br>' / '<tab>' text is not
      // mistaken for an encoded line break or tab when the database is reloaded
      '<':
        begin
          Result[DestIdx]     := '<';
          Result[DestIdx + 1] := 'l';
          Result[DestIdx + 2] := 't';
          Result[DestIdx + 3] := '>';
          Inc(DestIdx, 4);
        end;
      #0..#8, #14..#31: ;
    else
      begin
        Result[DestIdx] := C;
        Inc(DestIdx);
      end;
    end;
  end;

  SetLength(Result, DestIdx - 1);
end;

// ---> AUDIT FIX D4: Pass Result (not S) to the second StringReplace so
// '<br>' line-break decoding is never discarded!
function DecodeDbField(const S: string): string;
begin
  if S = '' then
    Exit('');
  // ---> AUDIT FIX: Fast path. Every encoded token starts with '<', and almost
  // no field contains one, so skip the three StringReplace calls
  if Pos('<', S) = 0 then
    Exit(S);
  Result := StringReplace(S, '<br>', sLineBreak, [rfReplaceAll]);
  Result := StringReplace(Result, '<tab>', #9, [rfReplaceAll]);
  // ---> AUDIT FIX D4: '<' is escaped as '<lt>' on save so literal '<br>' /
  // '<tab>' text in tags survives a save/load cycle. Must be decoded LAST.
  Result := StringReplace(Result, '<lt>', '<', [rfReplaceAll]);
end;

function FormatTrackLine(const ATrack: TTrackInfo): string;
begin
  Result := EncodeDbField(ATrack.FilePath) + #9 + EncodeDbField(ATrack.FolderDir) + #9 +
    EncodeDbField(ATrack.Title) + #9 + EncodeDbField(ATrack.Artist) + #9 + EncodeDbField(ATrack.Album) +
    #9 + EncodeDbField(ATrack.Genre) + #9 + IntToStr(ATrack.TrackNumber) +
    #9 + IntToStr(ATrack.LastModified) + #9 + EncodeDbField(ATrack.DurationStr) + #9 +
    EncodeDbField(ATrack.AlbumArtist) + #9 + IntToStr(ATrack.DiscNumber) +
    #9 + IntToStr(ATrack.Year) + #9 + EncodeDbField(ATrack.DateStr) + #9 +
    IntToStr(ATrack.SampleRate) + #9 + IntToStr(ATrack.BitDepth) +
    #9 + IntToStr(ATrack.DateAdded) + #9 + BoolToStr(ATrack.HasReplayGain, 'True', 'False') +
    #9 + IntToStr(ATrack.FileSize) +
    #9 + EncodeDbField(ATrack.Comment) +
    #9 + EncodeDbField(ATrack.Composer) +
    #9 + EncodeDbField(ATrack.Performer);
end;

function ParseTrackLine(const ALine: string; out ATrack: TTrackInfo): Boolean;
var
  P, StartIdx, PartCount: integer;
  Delim: Char;
  Parts: array[0..24] of string;
begin
  ATrack := Default(TTrackInfo);

  if Pos(#9, ALine) > 0 then
    Delim := #9
  else
    Delim := '|';

  for P := 0 to High(Parts) do
    Parts[P] := '';

  StartIdx  := 1;
  PartCount := 0;

  while True do
  begin
    P := PosEx(Delim, ALine, StartIdx);
    if P > 0 then
    begin
      if PartCount <= High(Parts) then
        Parts[PartCount] := Copy(ALine, StartIdx, P - StartIdx);
      StartIdx := P + 1;
      Inc(PartCount);
    end
    else
    begin
      if PartCount <= High(Parts) then
        Parts[PartCount] := Copy(ALine, StartIdx, MaxInt);
      Inc(PartCount);
      Break;
    end;
  end;

  Result := PartCount >= 7;
  if not Result then
    Exit;

  ATrack.FilePath    := DecodeDbField(Parts[0]);
  // ---> AUDIT FIX D3: Normalize FolderDir without trailing backslash
  ATrack.FolderDir   := ExcludeTrailingPathDelimiter(DecodeDbField(Parts[1]));
  if ATrack.FolderDir = '' then
    ATrack.FolderDir := ExcludeTrailingPathDelimiter(ExtractFileDir(ATrack.FilePath));

  ATrack.Title       := DecodeDbField(Parts[2]);
  ATrack.Artist      := NormalizeSemiColons(DecodeDbField(Parts[3]));
  ATrack.Album       := NormalizeSemiColons(DecodeDbField(Parts[4]));
  ATrack.Genre       := NormalizeSemiColons(DecodeDbField(Parts[5]));
  ATrack.TrackNumber := StrToIntDef(Parts[6], 0);

  if PartCount >= 8 then
    ATrack.LastModified := StrToInt64Def(Parts[7], 0)
  else
    ATrack.LastModified := 0;

  if PartCount >= 9 then
    ATrack.DurationStr := DecodeDbField(Parts[8])
  else
    ATrack.DurationStr := ZERO_TIME;

  if PartCount >= 10 then
    ATrack.AlbumArtist := NormalizeSemiColons(DecodeDbField(Parts[9]))
  else
    ATrack.AlbumArtist := ATrack.Artist;

  if PartCount >= 11 then
    ATrack.DiscNumber := StrToIntDef(Parts[10], 0)
  else
    ATrack.DiscNumber := 0;

  if PartCount >= 12 then
    ATrack.Year := StrToIntDef(Trim(Parts[11]), 0)
  else
    ATrack.Year := 0;

  if PartCount >= 13 then
    ATrack.DateStr := DecodeDbField(Trim(Parts[12]))
  else
    ATrack.DateStr := '';

  if PartCount >= 14 then
    ATrack.SampleRate := StrToIntDef(Trim(Parts[13]), 0)
  else
    ATrack.SampleRate := 0;

  if PartCount >= 15 then
    ATrack.BitDepth := StrToIntDef(Trim(Parts[14]), 0)
  else
    ATrack.BitDepth := 0;

  if PartCount >= 16 then
    ATrack.DateAdded := StrToInt64Def(Trim(Parts[15]), 0)
  else
    ATrack.DateAdded := 0;

  // Older files stored DateAdded as a file date: convert it to Unix time
  if (ATrack.DateAdded > 0) and (ATrack.DateAdded < 1000000000) then
  begin
    try
      if ATrack.LastModified > 0 then
        ATrack.DateAdded := DateTimeToUnix(FileDateToDateTime(ATrack.LastModified), False);
    except
      ATrack.DateAdded := 0;
    end;
  end;

  if PartCount >= 17 then
    ATrack.HasReplayGain := StrToBoolDef(Trim(Parts[16]), False)
  else
    ATrack.HasReplayGain := False;

  if PartCount >= 18 then
    ATrack.FileSize := StrToInt64Def(Trim(Parts[17]), 0)
  else
    ATrack.FileSize := 0;

  if PartCount >= 19 then
    ATrack.Comment := DecodeDbField(Trim(Parts[18]))
  else
    ATrack.Comment := '';

  if PartCount >= 20 then
    ATrack.Composer := NormalizeSemiColons(DecodeDbField(Trim(Parts[19])))
  else
    ATrack.Composer := '';

  if PartCount >= 21 then
    ATrack.Performer := NormalizeSemiColons(DecodeDbField(Trim(Parts[20])))
  else
    ATrack.Performer := '';
end;

end.
