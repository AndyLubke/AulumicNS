unit uPlaylistImport;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uPlaylistImport
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  What comes into a playlist from outside, without any UI:
    LoadM3UText / ParseM3UEntries  reading an M3U / M3U8 file (UTF-8 with or
                                   without BOM, else the Windows ANSI code
                                   page; #EXTINF title and length; relative
                                   paths resolved against the file's folder)
    CollectMusicFiles              the music files of dropped / chosen files
                                   and folders, in name order, with the
                                   library scanner's skip rules
    TrackFromM3UEntry              the track of an M3U entry (M3U import)
  The main window does the rest (the progress window, the import question,
  the rows); an added file outside the library is read by the playlist pane
  itself (TPlaylistPane.ReadEntry). Covered by Tests\TestPlaylistImport.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils, uLibraryTypes, uLibraryManager;

type
  // One track line of an M3U / M3U8 file, with its #EXTINF info
  TM3UEntry = record
    Path     : string;
    ExtTitle : string;
    ExtSecs  : Integer;
  end;
  TM3UEntries = array of TM3UEntry;

  // Where the track of an M3U entry came from (TrackFromM3UEntry)
  TM3UTrackSource = (
    msLibrary,   // the library's tags
    msFile,      // not in the library: the file's tags
    msNotFound,  // not in the library, file not readable: the #EXTINF info only
    msLeftOut,   // not in the library and only library tracks are imported
    // not in the library and on a network drive that does not
    // answer: left out, its file is not read
    msDriveNotAnswering
  );

// True when S is valid UTF-8 (no overlong 2-byte forms, nothing above U+10FFFF)
function IsValidUTF8Bytes(const S: RawByteString): Boolean;

// Reads an M3U / M3U8 file as UTF-8 when it is valid UTF-8 (with or without
// BOM); otherwise as the Windows ANSI code page, which older players use for
// .m3u. Raises on a read error.
procedure LoadM3UText(const AFileName: string; AList: TStrings);

// Reads the track lines of an M3U / M3U8 file (relative paths are resolved
// against the folder of the file). Raises on a read error.
procedure ParseM3UEntries(const AM3UPath: string; out AEntries: TM3UEntries);

// Adds to AFiles the music files (IsValidMusicFile) among APaths and in the
// folders among APaths (with their subfolders). The given items in name
// order; inside a folder its files first, then its subfolders, each in name
// order (exFAT drives and network shares list their entries in no particular
// order). Skipped, as by the library scanner: hidden and system entries,
// names starting with '.' or '$', '.~.' temporary files, linked folders.
procedure CollectMusicFiles(APaths, AFiles: TStrings);

// M3U import: the track of an M3U entry. It starts with the #EXTINF title
// (else the file name) and length; a track in the library (ALibrary may be
// nil) then takes the library's tags, any other one the file's tags (reads
// the file; a missing title keeps the one before, no album artist: the
// artist). AOnlyLibrary: a track outside the library is left out (msLeftOut,
// ATrack empty) and its file is not read. ADriveAnswers = False
// (the file is on a network drive whose server does not answer): a track
// outside the library is left out as well (msDriveNotAnswering, ATrack
// empty) and its file is not read; a library track is kept as always.
function TrackFromM3UEntry(const AEntry: TM3UEntry; ALibrary: TLibraryManager;
  AOnlyLibrary: Boolean; out ATrack: TTrackInfo;
  ADriveAnswers: Boolean = True): TM3UTrackSource;

implementation

uses
  AuAudioTypes, StrUtils, uAppConsts, uAppStrings, uAudioUtils, ALMetadata;

function WinGetACP: LongWord; stdcall; external 'kernel32.dll' name 'GetACP';

function IsValidUTF8Bytes(const S: RawByteString): Boolean;
var
  I, Len, Follow, K: Integer;
  B: Byte;
begin
  Result := False;
  Len := Length(S);
  I   := 1;
  while I <= Len do
  begin
    B := Byte(S[I]);
    if B < $80 then
      Follow := 0
    else if (B and $E0) = $C0 then
    begin
      if B < $C2 then Exit; // overlong
      Follow := 1;
    end
    else if (B and $F0) = $E0 then
      Follow := 2
    else if (B and $F8) = $F0 then
    begin
      if B > $F4 then Exit;
      Follow := 3;
    end
    else
      Exit;

    if I + Follow > Len then
      Exit;
    for K := 1 to Follow do
      if (Byte(S[I + K]) and $C0) <> $80 then
        Exit;
    Inc(I, Follow + 1);
  end;
  Result := True;
end;

// A file that is not valid UTF-8 is read as ANSI, so its accented characters
// (and with them the paths) stay intact.
procedure LoadM3UText(const AFileName: string; AList: TStrings);
var
  FS: TFileStream;
  Raw: RawByteString;
begin
  Raw := '';
  FS := TFileStream.Create(LongPath(AFileName), fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Raw, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Raw[1], FS.Size);
  finally
    FS.Free;
  end;

  if (Length(Raw) >= 3) and (Raw[1] = #$EF) and (Raw[2] = #$BB) and (Raw[3] = #$BF) then
    Delete(Raw, 1, 3);

  if IsValidUTF8Bytes(Raw) then
  begin
    SetCodePage(Raw, CP_UTF8, False);
    AList.Text := string(Raw);
  end
  else
  begin
    SetCodePage(Raw, TSystemCodePage(WinGetACP), False);
    AList.Text := UTF8Encode(UnicodeString(Raw));
  end;
end;

procedure ParseM3UEntries(const AM3UPath: string; out AEntries: TM3UEntries);
var
  SL: TStringList;
  I, Count, CommaPos, ExtSecs: Integer;
  LinePath, BaseDir, ExtTitle: string;
begin
  AEntries := nil;
  SL := TStringList.Create;
  try
    LoadM3UText(AM3UPath, SL);
    BaseDir  := ExtractFilePath(AM3UPath);
    ExtTitle := '';
    ExtSecs  := 0;
    Count    := 0;
    SetLength(AEntries, SL.Count);

    for I := 0 to SL.Count - 1 do
    begin
      LinePath := Trim(SL[I]);

      if (I = 0) and (Length(LinePath) >= 3) and (LinePath[1] = #$EF) and
         (LinePath[2] = #$BB) and (LinePath[3] = #$BF) then
        Delete(LinePath, 1, 3);

      if LinePath = '' then Continue;

      if Pos(M3U_EXTINF, UpperCase(LinePath)) = 1 then
      begin
        CommaPos := Pos(',', LinePath);
        if CommaPos > 0 then
        begin
          ExtTitle := Trim(Copy(LinePath, CommaPos + 1, Length(LinePath)));
          ExtSecs  := StrToIntDef(Trim(Copy(LinePath, 9, CommaPos - 9)), 0);
        end;
        Continue;
      end;

      if LinePath[1] = '#' then Continue;

      if (Length(LinePath) < 2) or ((LinePath[2] <> ':') and (Copy(LinePath, 1, 2) <> '\\')) then
        LinePath := ExpandFileName(IncludeTrailingPathDelimiter(BaseDir) + LinePath);

      AEntries[Count].Path     := LinePath;
      AEntries[Count].ExtTitle := ExtTitle;
      AEntries[Count].ExtSecs  := ExtSecs;
      Inc(Count);

      ExtTitle := '';
      ExtSecs  := 0;
    end;

    SetLength(AEntries, Count);
  finally
    SL.Free;
  end;
end;

function NewSortedList: TStringList;
begin
  Result               := TStringList.Create;
  Result.CaseSensitive := False;
end;

// Same rules as the library scanner: hidden and system
// entries (macOS "._" files, $RECYCLE.BIN, System Volume Information),
// names starting with '.' or '$' and '.~.' temporary files are skipped.
// Sorted per folder (files first, then the subfolders), so a dropped
// folder plays in name order also on exFAT drives and network shares,
// which list their entries in no particular order.
procedure DigDirectory(const Dir: string; AFiles: TStrings);
var
  SR: TSearchRec;
  Files, SubDirs: TStringList;
  K: Integer;
begin
  Files   := NewSortedList;
  SubDirs := NewSortedList;
  try
    if SysUtils.FindFirst(LongPath(IncludeTrailingPathDelimiter(Dir) + '*.*'), faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          {$PUSH}{$WARN 5044 OFF} // faHidden / faSysFile / faSymLink: Windows-only (so is AulumicNS)
          if ((SR.Attr and faHidden) <> 0) or ((SR.Attr and faSysFile) <> 0) then
            Continue;
          if StartsText('.', SR.Name) or StartsText('$', SR.Name) or (Pos('.~.', SR.Name) > 0) then
            Continue;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if (SR.Attr and faSymLink) = 0 then
              SubDirs.Add(SR.Name);
          end
          {$POP}
          else if IsValidMusicFile(SR.Name) then
            Files.Add(SR.Name);
        until SysUtils.FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
    end;

    Files.Sort;
    SubDirs.Sort;
    for K := 0 to Files.Count - 1 do
      AFiles.Add(IncludeTrailingPathDelimiter(Dir) + Files[K]);
    for K := 0 to SubDirs.Count - 1 do
      DigDirectory(IncludeTrailingPathDelimiter(Dir) + SubDirs[K], AFiles);
  finally
    SubDirs.Free;
    Files.Free;
  end;
end;

procedure CollectMusicFiles(APaths, AFiles: TStrings);
var
  TopPaths: TStringList;
  I: Integer;
begin
  if (not Assigned(APaths)) or (APaths.Count = 0) then
    Exit;

  TopPaths := NewSortedList;
  try
    // The dropped / chosen items in name order too (Windows passes a
    // drop in no particular order)
    TopPaths.Assign(APaths);
    TopPaths.Sort;

    // One list of supported formats: IsValidMusicFile (uAudioUtils), as
    // the library scanner uses
    for I := 0 to TopPaths.Count - 1 do
    begin
      if DirectoryExists(LongPath(TopPaths[I])) then
        DigDirectory(TopPaths[I], AFiles)
      else if FileExists(LongPath(TopPaths[I])) then
      begin
        if IsValidMusicFile(TopPaths[I]) then
          AFiles.Add(TopPaths[I]);
      end;
    end;
  finally
    TopPaths.Free;
  end;
end;

function TrackFromM3UEntry(const AEntry: TM3UEntry; ALibrary: TLibraryManager;
  AOnlyLibrary: Boolean; out ATrack: TTrackInfo;
  ADriveAnswers: Boolean): TM3UTrackSource;
var
  LibTrack: TTrackInfo;
  Meta: TAudioMetadata;
  InLibrary: Boolean;
begin
  ATrack    := Default(TTrackInfo);
  InLibrary := Assigned(ALibrary) and ALibrary.TryGetTrack(AEntry.Path, LibTrack);

  if (not InLibrary) and AOnlyLibrary then
    Exit(msLeftOut);
  if (not InLibrary) and (not ADriveAnswers) then
    Exit(msDriveNotAnswering);

  ATrack.FilePath    := AEntry.Path;
  ATrack.FolderDir   := ExtractFileDir(AEntry.Path);
  ATrack.Title       := ExtractFileName(AEntry.Path);
  ATrack.DurationStr := '';

  if AEntry.ExtTitle <> '' then ATrack.Title := AEntry.ExtTitle;
  if AEntry.ExtSecs > 0 then
    ATrack.DurationStr := IntToStr(AEntry.ExtSecs div 60) + ':' +
                          Format('%.2d', [AEntry.ExtSecs mod 60]);

  if InLibrary then
  begin
    Result := msLibrary;
    if LibTrack.Title <> '' then ATrack.Title := LibTrack.Title;
    ATrack.Artist      := LibTrack.Artist;
    ATrack.AlbumArtist := LibTrack.AlbumArtist;
    ATrack.Album       := LibTrack.Album;
    ATrack.Genre       := LibTrack.Genre;
    ATrack.TrackNumber := LibTrack.TrackNumber;
    ATrack.DiscNumber  := LibTrack.DiscNumber;
    ATrack.DurationStr := LibTrack.DurationStr;
    ATrack.Year        := LibTrack.Year;
    ATrack.DateStr     := LibTrack.DateStr;
    ATrack.SampleRate  := LibTrack.SampleRate;
    ATrack.BitDepth    := LibTrack.BitDepth;
  end
  // Not in the library: read the tags (one file check, by the tag reader)
  else if TryReadTrackMetadata(AEntry.Path, Meta) then
  begin
    Result := msFile;
    if Meta.Title <> '' then ATrack.Title := Meta.Title;
    ATrack.Artist      := Meta.Artist;
    ATrack.AlbumArtist := Meta.AlbumArtist;
    if ATrack.AlbumArtist = '' then ATrack.AlbumArtist := Meta.Artist;
    ATrack.Album       := Meta.Album;
    ATrack.Genre       := Meta.Genre;
    ATrack.TrackNumber := Meta.TrackNumber;
    ATrack.DiscNumber  := Meta.DiscNumber;
    ATrack.DurationStr := Meta.DurationStr;
    ATrack.Year        := Meta.Year;
    ATrack.DateStr     := Meta.DateStr;
    ATrack.SampleRate  := Meta.SampleRate;
    ATrack.BitDepth    := Meta.BitDepth;
  end
  else
    Result := msNotFound;
end;

end.
