program LibBench;

{$mode ObjFPC}{$H+}
{$APPTYPE CONSOLE}

{ ==============================================================================
  AulumicNS tools - LibBench
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  LibBench - times the library's operations on a real database.

    LibBench <folder with a COPY of library.adb / library.jnl> [--save=1] [--playlist=1]
             [--scan=<folder with the thumbnails>] [--check=1]

  Loads the snapshot as the program does (TLibraryManager.LoadDatabase) and
  times what the library pane, the search, the auto-playlists and the
  ReplayGain window ask of it. One line per operation: the time in ms (the best
  of four runs; "first" = the first call, which builds the caches) and the
  size of the answer.
    --save=1      also times SaveDatabase (it WRITES the copy)
    --playlist=1  the playlist pane with the whole library as one playlist:
                  add, remove / move one track, ratings, F5, the store
    --scan=DIR    two refresh scans as at the program's start (reads the
                  library folders; DIR = Cache\Thumbs of a copy, so no
                  thumbnail is made) with the log lines: the second one must
                  say "No changes detected"
    --check=1     the tree's name lists and the lists of six searches against
                  the plain way of building them; exit code = differences
  Always work on a copy: never point it at Data\Library of the program.
  ============================================================================}

uses
  Interfaces, Forms, Classes, SysUtils, Windows, Math,
  uLibraryManager, uLibraryTypes, uUserStatsManager, uAppConsts, uAppStrings,
  uPlaylistFile, uPlaylistStore, AuPlaylistPane, AuLog, uLibraryCheck;

var
  Lib: TLibraryManager;
  Freq: Int64;

function NowMs: Double;
var
  C: Int64;
begin
  C := 0;
  QueryPerformanceCounter(C);
  Result := C / Freq * 1000.0;
end;

{ the heap in use, MB }
function PrivateMB: Double;
begin
  Result := GetFPCHeapStatus.CurrHeapUsed / (1024 * 1024);
end;

type
  TOp = procedure(out ACount: Integer);

procedure Run(const AName: string; AOp: TOp);
var
  I, N: Integer;
  T0, First, Best, D: Double;
begin
  N := 0;
  T0 := NowMs;
  AOp(N);
  First := NowMs - T0;
  Best := First;
  for I := 1 to 3 do
  begin
    T0 := NowMs;
    AOp(N);
    D := NowMs - T0;
    if D < Best then Best := D;
  end;
  WriteLn(Format('%-44s first %8.2f ms   best %8.2f ms   n=%d', [AName, First, Best, N]));
end;

var
  GArtist, GGenre, GAlbum, GRoot, GQuery, GFolder: string;

procedure OpArtists(out ACount: Integer);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try Lib.GetUniqueArtists(SL); ACount := SL.Count; finally SL.Free; end;
end;

procedure OpAlbums(out ACount: Integer);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try Lib.GetUniqueAlbums(SL); ACount := SL.Count; finally SL.Free; end;
end;

procedure OpGenres(out ACount: Integer);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try Lib.GetUniqueGenres(SL); ACount := SL.Count; finally SL.Free; end;
end;

procedure OpAlbumsByArtist(out ACount: Integer);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try Lib.GetAlbumsByArtist(GArtist, SL); ACount := SL.Count; finally SL.Free; end;
end;

{ what "Expand all" on the Artists and on the Albums category asks the
  library: every artist's albums and the tracks of each, every album's tracks
  (the count is the number of tracks listed) }
procedure OpExpandAllArtists(out ACount: Integer);
var
  Artists, Albums: TStringList;
  TL: TTrackList;
  I, J: Integer;
begin
  ACount := 0;
  Artists := TStringList.Create;
  Albums := TStringList.Create;
  TL := TTrackList.Create;
  try
    Lib.GetUniqueArtists(Artists);
    for I := 0 to Artists.Count - 1 do
    begin
      Lib.GetAlbumsByArtist(Artists[I], Albums);
      for J := 0 to Albums.Count - 1 do
      begin
        Lib.GetTracksByArtistAndAlbum(Artists[I], Albums[J], TL);
        Inc(ACount, TL.Count);
      end;
    end;
  finally
    TL.Free;
    Albums.Free;
    Artists.Free;
  end;
end;

procedure OpExpandAllAlbums(out ACount: Integer);
var
  Albums: TStringList;
  TL: TTrackList;
  I: Integer;
begin
  ACount := 0;
  Albums := TStringList.Create;
  TL := TTrackList.Create;
  try
    Lib.GetUniqueAlbums(Albums);
    for I := 0 to Albums.Count - 1 do
    begin
      Lib.GetTracksByAlbum(Albums[I], TL);
      Inc(ACount, TL.Count);
    end;
  finally
    TL.Free;
    Albums.Free;
  end;
end;

procedure OpAlbumsByGenre(out ACount: Integer);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try Lib.GetAlbumsByGenre(GGenre, SL); ACount := SL.Count; finally SL.Free; end;
end;

procedure OpTracksByArtist(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksByArtist(GArtist, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpTracksByGenre(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksByGenre(GGenre, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpTracksByAlbum(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksByAlbum(GAlbum, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpSubFolders(out ACount: Integer);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try Lib.GetSubFolders(GRoot, SL); ACount := SL.Count; finally SL.Free; end;
end;

procedure OpTracksInFolder(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksInFolder(GFolder, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpFolderRecursive(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksInFolderRecursive(GFolder, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpRootRecursive(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksInFolderRecursive(GRoot, TL); ACount := TL.Count; finally TL.Free; end;
end;

var
  GLinkDir: string = '';
  GLinkTargets: Integer = 0;

{ the folder of the virtual folder with the most targets ('' = no virtual folders) }
function BiggestLinkDir: string;
var
  Roots, Links, Targets: TStringList;
  I, J: Integer;
begin
  Result := '';
  Roots := TStringList.Create;
  Links := TStringList.Create;
  Targets := TStringList.Create;
  try
    Lib.GetScanFolders(Roots);
    for I := 0 to Roots.Count - 1 do
    begin
      Lib.GetVirtualLinksUnder(ExcludeTrailingPathDelimiter(Roots[I]), Links);
      for J := 0 to Links.Count - 1 do
      begin
        Lib.GetVirtualLinkTargets(Links[J], Targets);
        if Targets.Count > GLinkTargets then
        begin
          GLinkTargets := Targets.Count;
          Result := ExtractFileDir(Links[J]);
        end;
      end;
    end;
  finally
    Targets.Free;
    Links.Free;
    Roots.Free;
  end;
end;
{ a folder as the tiles and the folder actions ask for it: its tracks and
  those of the virtual folders in it (the library folder; the folder of the
  virtual folder with the most targets) }
procedure OpRootWithLinks(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksInFolderWithLinks(GRoot, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpLinkFolderWithLinks(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksInFolderWithLinks(GLinkDir, TL); ACount := TL.Count; finally TL.Free; end;
end;

{ the check of the tags (the Tag consistency window) for the whole library; the
  count is the number of findings }
var
  GCheckShown: Boolean = False;

procedure OpCheckTags(out ACount: Integer);
var
  TL: TTrackList;
  Found: TCheckFindings;
  K: TCheckKind;
  I, N: Integer;
begin
  TL := TTrackList.Create;
  try
    Lib.GetAllTracks(TL);
    CheckTracks(TL, Found);
    ACount := Length(Found);
    { once: how many findings of each kind }
    if not GCheckShown then
    begin
      GCheckShown := True;
      for K := Low(TCheckKind) to High(TCheckKind) do
      begin
        N := 0;
        for I := 0 to High(Found) do
          if Found[I].Kind = K then Inc(N);
        WriteLn(Format('    %-28s %6d', [CHECK_KIND_NAMES[K], N]));
      end;
    end;
  finally
    TL.Free;
  end;
end;

procedure OpSearch(out ACount: Integer);
var
  A, B, C, D: TStringList;
  TL: TTrackList;
begin
  A := TStringList.Create; B := TStringList.Create; C := TStringList.Create; D := TStringList.Create;
  TL := TTrackList.Create;
  try
    Lib.SearchLibrary(GQuery, A, B, C, D, TL);
    ACount := TL.Count;
  finally
    A.Free; B.Free; C.Free; D.Free; TL.Free;
  end;
end;

procedure OpQuery(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetTracksByQuery(GQuery, TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpAllTracks(out ACount: Integer);
var TL: TTrackList;
begin
  TL := TTrackList.Create;
  try Lib.GetAllTracks(TL); ACount := TL.Count; finally TL.Free; end;
end;

procedure OpSnapshot(out ACount: Integer);
var A: TTrackInfoArray;
begin
  A := Lib.SnapshotTracks;
  ACount := Length(A);
end;

procedure OpBuckets(out ACount: Integer);
var
  L: TList;
  Missing, I: Integer;
begin
  Lib.GetDistinctAlbumBuckets(L, Missing);
  ACount := L.Count;
  for I := 0 to L.Count - 1 do TObject(L[I]).Free;
  L.Free;
end;

procedure OpLookups(out ACount: Integer);
var
  A: TTrackInfoArray;
  T: TTrackInfo;
  I: Integer;
begin
  A := Lib.SnapshotTracks;
  ACount := 0;
  for I := 0 to High(A) do
    if Lib.TryGetTrack(A[I].FilePath, T) then Inc(ACount);
end;

procedure OpSave(out ACount: Integer);
begin
  Lib.IsDirty := True;
  Lib.SaveDatabase;
  ACount := Lib.GetTrackCount;
end;

{ ---- the playlist pane with the whole library as one playlist ---- }

type
  TLookup = class
    function Lookup(const APath: string; out ATrack: TTrackInfo): Boolean;
  end;

function TLookup.Lookup(const APath: string; out ATrack: TTrackInfo): Boolean;
begin
  Result := Lib.TryGetTrack(APath, ATrack);
end;

var
  Pane: TPlaylistPane;
  PlAll: TTrackList;
  PlStore: TPlaylistStore;
  PlDir: string;

procedure OpPlAdd(out ACount: Integer);
begin
  Pane.Clear;
  Pane.AddTracks(PlAll);
  ACount := Pane.EntryCount;
end;

procedure OpPlRemoveOne(out ACount: Integer);
var Idx: TIntArray;
begin
  Idx := nil;
  SetLength(Idx, 1);
  Idx[0] := Pane.EntryCount div 2;
  Pane.RemoveEntries(Idx);
  ACount := Pane.EntryCount;
end;

procedure OpPlMoveOne(out ACount: Integer);
var Idx: TIntArray;
begin
  Idx := nil;
  SetLength(Idx, 1);
  Idx[0] := Pane.EntryCount div 2;
  Pane.MoveEntries(Idx, 10);
  ACount := Pane.EntryCount;
end;

procedure OpPlRatings(out ACount: Integer);
begin
  Pane.RefreshRatings;
  ACount := Pane.EntryCount;
end;

procedure OpPlSync(out ACount: Integer);
begin
  Pane.SyncWithLibrary;
  ACount := Pane.EntryCount;
end;

procedure OpPlFind(out ACount: Integer);
begin
  ACount := Pane.IndexOfFile(PlAll[PlAll.Count - 1]^.FilePath);
end;

procedure OpPlToEntries(out ACount: Integer);
var E: TPlaylistEntries;
begin
  E := Pane.ToEntries;
  ACount := Length(E);
end;

procedure OpPlStore(out ACount: Integer);
var P: PStoredPlaylist;
begin
  P := PlStore.Find('Default');
  PlStore.SetEntries(P, Pane.ToEntries);
  ACount := Length(P^.Entries);
end;

procedure OpPlSave(out ACount: Integer);
begin
  PlStore.Save;
  ACount := PlStore.Count;
end;

procedure PlaylistBench(const ADir: string);
var
  F: TForm;
  L: TLookup;
begin
  PlDir := ADir;
  Application.Initialize;
  F := TForm.CreateNew(nil);
  L := TLookup.Create;
  PlAll := TTrackList.Create;
  PlStore := TPlaylistStore.Create(ADir + 'playlists-bench.adb', 'Default');
  try
    F.SetBounds(0, 0, 900, 700);
    Pane := TPlaylistPane.Create(F);
    Pane.Parent := F;
    Pane.SetBounds(0, 0, 900, 700);
    Pane.OnLookup := @L.Lookup;
    Pane.SetView(gmAlbum, '%album%', '%title%', '', False);
    Lib.GetAllTracks(PlAll);
    PlAll.Sort(@CompareTrackInfo);
    PlStore.Load;
    WriteLn('-- playlist pane, the whole library as one playlist (by album) --');
    Run('Playlist: AddTracks (all)', @OpPlAdd);
    Run('Playlist: remove one track', @OpPlRemoveOne);
    Run('Playlist: move one track', @OpPlMoveOne);
    Run('Playlist: RefreshRatings', @OpPlRatings);
    Run('Playlist: SyncWithLibrary (F5)', @OpPlSync);
    Run('Playlist: IndexOfFile (last)', @OpPlFind);
    Run('Playlist: ToEntries', @OpPlToEntries);
    Run('Playlist store: SetEntries (journal)', @OpPlStore);
    Run('Playlist store: Save (snapshot)', @OpPlSave);
  finally
    PlStore.Free;
    PlAll.Free;
    L.Free;
    F.Free;
  end;
  SysUtils.DeleteFile(ADir + 'playlists-bench.adb');
  SysUtils.DeleteFile(ADir + 'playlists-bench.jnl');
end;

{ ---- a refresh scan, as at the program's start (reads the folders; a file
  that looks changed is read again). --scan=<thumbs folder>: where the
  thumbnails are, so none is made. Prints the log lines of the scan. ---- }

procedure ScanBench(const AThumbs: string);
var
  Round, I, From: Integer;
  T0: Double;
begin
  Application.Initialize;
  AppCacheThumbsDir := IncludeTrailingPathDelimiter(AThumbs);
  for Round := 1 to 2 do
  begin
    From := AppLog.Lines.Count;
    T0 := NowMs;
    Lib.StartScan(False);
    while Lib.IsScanning do
    begin
      CheckSynchronize(20);
      Application.ProcessMessages;
    end;
    Application.ProcessMessages;
    WriteLn(Format('Refresh scan %d: %.0f ms, dirty=%s', [Round, NowMs - T0, BoolToStr(Lib.IsDirty, True)]));
    for I := From to AppLog.Lines.Count - 1 do
      WriteLn('    ', AppLog.Lines[I]);
  end;
end;

{ ---- --check=1: the name lists against the plain way of building them (a
  language-aware sorted list that gets every name of every track, as the
  library did before TNameSet) ---- }

function NewNameList: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Result.CaseSensitive := False;
end;

procedure AddItems(AList: TStringList; const ARaw, AUnknown: string);
var
  Rem, S: string;
  P, Before: Integer;
begin
  Rem := Trim(ARaw);
  if Rem = '' then
  begin
    if AUnknown <> '' then AList.Add(AUnknown);
    Exit;
  end;
  Before := AList.Count;
  P := -1;
  while True do
  begin
    P := Pos(';', Rem);
    if P > 0 then
    begin
      S := Trim(Copy(Rem, 1, P - 1));
      if S <> '' then begin AList.Add(S); Before := -1; end;
      Rem := Trim(Copy(Rem, P + 1, Length(Rem)));
    end
    else
    begin
      if Trim(Rem) <> '' then begin AList.Add(Trim(Rem)); Before := -1; end;
      Break;
    end;
  end;
  if (Before >= 0) and (AUnknown <> '') then AList.Add(AUnknown);
end;

function SameLists(const AName: string; A, B: TStrings): Boolean;
var
  I: Integer;
begin
  Result := A.Count = B.Count;
  if Result then
    for I := 0 to A.Count - 1 do
      if A[I] <> B[I] then
      begin
        Result := False;
        WriteLn(Format('  %s differs at %d of %d', [AName, I, A.Count]));
        Break;
      end;
  if not Result and (A.Count <> B.Count) then
    WriteLn(Format('  %s: %d names, expected %d', [AName, B.Count, A.Count]));
end;

function CheckLists: Integer;
const
  QUERIES: array[0..5] of string = ('pink floyd', 'the', 'bach suite', 'e a o', 'zzzqqq', 'love');
var
  All, Hits: TTrackList;
  RefArt, RefAlb, RefGen, RefFld, Got, GotAlb, GotGen, GotFld: TStringList;
  I, Q, K: Integer;
  T: PTrackInfo;
  Art, Alb, Txt, Tok, Rest: string;
  Match: Boolean;
  Tokens: TStringList;
  HitCount: Integer;
begin
  Result := 0;
  All := TTrackList.Create;
  Hits := TTrackList.Create;
  Got := TStringList.Create; GotAlb := TStringList.Create;
  GotGen := TStringList.Create; GotFld := TStringList.Create;
  Tokens := TStringList.Create;
  try
    Lib.GetAllTracks(All);
    { the tree's lists }
    RefArt := NewNameList; RefAlb := NewNameList; RefGen := NewNameList;
    try
      for I := 0 to All.Count - 1 do
      begin
        T := All[I];
        Alb := Trim(T^.Album);
        if Alb = '' then Alb := LBL_UNKNOWN_ALBUM;
        Art := Trim(T^.AlbumArtist);
        if Art = '' then Art := Trim(T^.Artist);
        if Art = '' then Art := LBL_UNKNOWN_ARTIST;
        RefAlb.Add(Format('%s - %s', [Art, Alb]));
        AddItems(RefArt, T^.AlbumArtist, LBL_UNKNOWN_ARTIST);
        AddItems(RefGen, T^.Genre, LBL_UNKNOWN_GENRE);
      end;
      Lib.GetUniqueArtists(Got);
      if not SameLists('artists', RefArt, Got) then Inc(Result);
      Lib.GetUniqueAlbums(Got);
      if not SameLists('albums', RefAlb, Got) then Inc(Result);
      Lib.GetUniqueGenres(Got);
      if not SameLists('genres', RefGen, Got) then Inc(Result);
      WriteLn(Format('check: tree lists (%d artists, %d albums, %d genres): %d differences',
        [RefArt.Count, RefAlb.Count, RefGen.Count, Result]));
    finally
      RefArt.Free; RefAlb.Free; RefGen.Free;
    end;
    { the search's lists }
    for Q := 0 to High(QUERIES) do
    begin
      Tokens.Clear;
      Rest := LowerCase(QUERIES[Q]);
      while Rest <> '' do
      begin
        K := Pos(' ', Rest);
        if K > 0 then
        begin
          Tok := Trim(Copy(Rest, 1, K - 1));
          if Tok <> '' then Tokens.Add(Tok);
          Rest := Trim(Copy(Rest, K + 1, Length(Rest)));
        end
        else
        begin
          Tokens.Add(Rest);
          Break;
        end;
      end;
      RefArt := NewNameList; RefAlb := NewNameList; RefGen := NewNameList; RefFld := NewNameList;
      try
        HitCount := 0;
        for I := 0 to All.Count - 1 do
        begin
          T := All[I];
          Match := True;
          for K := 0 to Tokens.Count - 1 do
          begin
            Tok := Tokens[K];
            if not ((Pos(Tok, T^.CleanTitle) > 0) or (Pos(Tok, T^.CleanArtist) > 0) or
                    (Pos(Tok, T^.CleanAlbumArtist) > 0) or (Pos(Tok, T^.CleanComposer) > 0) or
                    (Pos(Tok, T^.CleanPerformer) > 0) or (Pos(Tok, T^.CleanAlbum) > 0) or
                    (Pos(Tok, T^.CleanGenre) > 0) or (Pos(Tok, T^.CleanFolder) > 0)) then
            begin
              Match := False;
              Break;
            end;
          end;
          if not Match then Continue;
          Inc(HitCount);
          Txt := Trim(T^.Artist);
          if Txt = '' then Txt := Trim(T^.AlbumArtist);
          if Txt = '' then Txt := LBL_UNKNOWN_ARTIST;
          AddItems(RefArt, Txt, '');
          Art := Trim(T^.AlbumArtist);
          if Art = '' then Art := Trim(T^.Artist);
          if Art = '' then Art := LBL_UNKNOWN_ARTIST;
          Alb := Trim(T^.Album);
          if Alb = '' then Alb := LBL_UNKNOWN_ALBUM;
          RefAlb.Add(Format('%s - %s', [Art, Alb]));
          Txt := Trim(T^.Genre);
          if Txt = '' then Txt := LBL_UNKNOWN_GENRE;
          AddItems(RefGen, Txt, '');
          Txt := ExcludeTrailingPathDelimiter(T^.FolderDir);
          if Txt <> '' then RefFld.Add(Txt);
        end;
        Lib.SearchLibrary(QUERIES[Q], Got, GotAlb, GotGen, GotFld, Hits);
        K := 0;
        if Hits.Count <> HitCount then
        begin
          Inc(K);
          WriteLn(Format('  hits: %d, expected %d', [Hits.Count, HitCount]));
        end;
        if not SameLists('search artists', RefArt, Got) then Inc(K);
        if not SameLists('search albums', RefAlb, GotAlb) then Inc(K);
        if not SameLists('search genres', RefGen, GotGen) then Inc(K);
        if not SameLists('search folders', RefFld, GotFld) then Inc(K);
        WriteLn(Format('check: search "%s" (%d hits, %d artists, %d albums, %d genres, %d folders): %d differences',
          [QUERIES[Q], HitCount, RefArt.Count, RefAlb.Count, RefGen.Count, RefFld.Count, K]));
        Inc(Result, K);
      finally
        RefArt.Free; RefAlb.Free; RefGen.Free; RefFld.Free;
      end;
    end;
  finally
    Tokens.Free;
    Got.Free; GotAlb.Free; GotGen.Free; GotFld.Free;
    Hits.Free;
    All.Free;
  end;
end;

procedure SearchFor(const AQuery: string);
begin
  GQuery := AQuery;
  Run('SearchLibrary "' + AQuery + '"', @OpSearch);
end;

procedure QueryFor(const AQuery: string);
begin
  GQuery := AQuery;
  Run('GetTracksByQuery ' + AQuery, @OpQuery);
end;

procedure ExportTracks(const AFile: string);
var
  TL: TTrackList;
  SL: TStringList;
  I: Integer;
  T: PTrackInfo;

  function F(const S: string): string;
  begin
    Result := StringReplace(StringReplace(StringReplace(S, #9, ' ', [rfReplaceAll]), #13, ' ', [rfReplaceAll]),
      #10, ' ', [rfReplaceAll]);
  end;

begin
  TL := TTrackList.Create;
  SL := TStringList.Create;
  try
    Lib.GetAllTracks(TL);
    SL.Add('Path'#9'Folder'#9'Title'#9'Artist'#9'AlbumArtist'#9'Album'#9'Genre'#9'Composer'#9'Performer'#9 +
      'Track'#9'Disc'#9'Year'#9'Duration');
    for I := 0 to TL.Count - 1 do
    begin
      T := TL[I];
      SL.Add(F(T^.FilePath) + #9 + F(T^.FolderDir) + #9 + F(T^.Title) + #9 + F(T^.Artist) + #9 +
        F(T^.AlbumArtist) + #9 + F(T^.Album) + #9 + F(T^.Genre) + #9 + F(T^.Composer) + #9 +
        F(T^.Performer) + #9 + IntToStr(T^.TrackNumber) + #9 + IntToStr(T^.DiscNumber) + #9 +
        IntToStr(T^.Year) + #9 + F(T^.DurationStr));
    end;
    SL.WriteBOM := False;
    SL.SaveToFile(AFile, TEncoding.UTF8);
    WriteLn('exported ', TL.Count, ' tracks to ', AFile);
  finally
    SL.Free;
    TL.Free;
  end;
end;

var
  Dir: string;
  SL: TStringList;
  TL: TTrackList;
  T0, HeapBefore: Double;
  I, Best, N: Integer;
  Counts: TStringList;
begin
  if ParamCount < 1 then
  begin
    WriteLn('LibBench <folder with a copy of library.adb> [--save=1]');
    Halt(2);
  end;
  Freq := 1;
  QueryPerformanceFrequency(Freq);
  Dir := IncludeTrailingPathDelimiter(ParamStr(1));
  if not FileExists(Dir + 'library.adb') then
  begin
    WriteLn('no library.adb in ', Dir);
    Halt(2);
  end;

  HeapBefore := PrivateMB;
  Lib := TLibraryManager.Create(Dir + 'library.adb');
  try
    T0 := NowMs;
    Lib.LoadDatabase;
    WriteLn(Format('%-44s %8.2f ms   n=%d   heap %.1f MB', ['LoadDatabase', NowMs - T0,
      Lib.GetTrackCount, PrivateMB - HeapBefore]));
    WriteLn('  ', Lib.GetLoadSummary);

    { --export=<file>: the text fields of every track, tab-separated, one
      line per track with a heading line (to count things in a library with
      other tools), and nothing else }
    for I := 2 to ParamCount do
      if Copy(ParamStr(I), 1, 9) = '--export=' then
      begin
        ExportTracks(Copy(ParamStr(I), 10, MaxInt));
        Halt(0);
      end;

    { the arguments: the artist and the genre with the most tracks, a root }
    SL := TStringList.Create;
    TL := TTrackList.Create;
    Counts := TStringList.Create;
    try
      Lib.GetScanFolders(SL);
      if SL.Count > 0 then GRoot := ExcludeTrailingPathDelimiter(SL[0]);
      Lib.GetAllTracks(TL);
      Counts.Sorted := True;
      Counts.CaseSensitive := False;
      Counts.UseLocale := False;
      Best := 0;
      for I := 0 to TL.Count - 1 do
      begin
        if TL[I]^.AlbumArtist = '' then Continue;
        N := Counts.IndexOf(TL[I]^.AlbumArtist);
        if N < 0 then N := Counts.AddObject(TL[I]^.AlbumArtist, nil);
        Counts.Objects[N] := TObject(PtrInt(Counts.Objects[N]) + 1);
        if PtrInt(Counts.Objects[N]) > Best then
        begin
          Best := PtrInt(Counts.Objects[N]);
          GArtist := TL[I]^.AlbumArtist;
          GAlbum := TL[I]^.Album;
          GFolder := ExcludeTrailingPathDelimiter(TL[I]^.FolderDir);
        end;
      end;
      Counts.Clear;
      Best := 0;
      for I := 0 to TL.Count - 1 do
      begin
        if (TL[I]^.Genre = '') or (Pos(';', TL[I]^.Genre) > 0) then Continue;
        N := Counts.IndexOf(TL[I]^.Genre);
        if N < 0 then N := Counts.AddObject(TL[I]^.Genre, nil);
        Counts.Objects[N] := TObject(PtrInt(Counts.Objects[N]) + 1);
        if PtrInt(Counts.Objects[N]) > Best then
        begin
          Best := PtrInt(Counts.Objects[N]);
          GGenre := TL[I]^.Genre;
        end;
      end;
    finally
      Counts.Free;
      TL.Free;
      SL.Free;
    end;
    WriteLn(Format('  arguments: artist with the most tracks, genre with the most tracks, root "%s"',
      [ExtractFileDrive(GRoot)]));

    Run('GetUniqueArtists', @OpArtists);
    Run('GetUniqueAlbums', @OpAlbums);
    Run('GetUniqueGenres', @OpGenres);
    Run('GetAlbumsByArtist', @OpAlbumsByArtist);
    Run('GetAlbumsByGenre', @OpAlbumsByGenre);
    Run('GetTracksByArtist', @OpTracksByArtist);
    Run('GetTracksByGenre', @OpTracksByGenre);
    Run('GetTracksByAlbum', @OpTracksByAlbum);
    Run('Expand all: Artists', @OpExpandAllArtists);
    Run('Expand all: Albums', @OpExpandAllAlbums);
    Run('GetSubFolders (root)', @OpSubFolders);
    Run('GetTracksInFolder (one album)', @OpTracksInFolder);
    Run('GetTracksInFolderRecursive (one album)', @OpFolderRecursive);
    Run('GetTracksInFolderRecursive (root)', @OpRootRecursive);
    Run('GetTracksInFolderWithLinks (root)', @OpRootWithLinks);
    Run('CheckTracks (whole library)', @OpCheckTags);
    GLinkDir := BiggestLinkDir;
    if GLinkDir <> '' then
      Run('GetTracksInFolderWithLinks (' + IntToStr(GLinkTargets) + ' linked folders)', @OpLinkFolderWithLinks);
    SearchFor('pink floyd');
    SearchFor('the');
    SearchFor('bach suite');
    SearchFor('zzzqqq');
    SearchFor('e a o');
    QueryFor('%artist% HAS bach');
    QueryFor('%codec% IS dsd');
    QueryFor('%rating% GREATER 3');
    Run('GetAllTracks', @OpAllTracks);
    Run('SnapshotTracks', @OpSnapshot);
    Run('TryGetTrack x all', @OpLookups);
    Run('GetDistinctAlbumBuckets (ReplayGain)', @OpBuckets);
    if FindCmdLineSwitch('-save=1', ['-'], True) then
      Run('SaveDatabase', @OpSave);
    if FindCmdLineSwitch('-playlist=1', ['-'], True) then
      PlaylistBench(Dir);
    if Application.HasOption('scan') then
      ScanBench(Application.GetOptionValue('scan'));
    if FindCmdLineSwitch('-check=1', ['-'], True) then
      ExitCode := CheckLists;
    Lib.IsDirty := False;
  finally
    Lib.Free;
  end;
end.
