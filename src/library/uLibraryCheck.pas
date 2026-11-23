unit uLibraryCheck;

{ ==============================================================================
  AulumicNS - uLibraryCheck
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Looks through the tags of a list of library tracks for things worth a look
  (the Tag consistency window). It reads the library records only, never a file,
  and changes nothing.
    No album, No artist, No title, No track number
                            tracks without that tag (a title that is only the
                            file's name counts as none; a single loose track
                            needs no number), per folder or album
    Several album names     one folder whose tracks carry different albums
    Several album artists, Several years
                            one album whose tracks differ in them
    Track number twice      two tracks of one disc with the same number
    Gap in the track numbers
                            numbers missing between the lowest and the highest
                            of a disc
    No composer             an album none of whose tracks names a composer
    Composer on some tracks an album where some tracks name one and some do not
    Composer names          composers that share a surname but are written in
                            more than one way ("J. S. Bach", "Johann Sebastian
                            Bach"; two people with one surname are listed too)
    Artist names, Genre names
                            names that are the same once case, accents, spaces
                            and punctuation are left out ("Dvorak" / "Dvořák",
                            "Hip-Hop" / "Hip Hop")
  An album is the tracks of one folder with one album tag.
  A finding carries the files it is about: for a name written in several ways
  those of every spelling but the most used one.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uLibraryTypes;

type
  { in the order of the list }
  TCheckKind = (ckNoAlbum, ckNoArtist, ckNoTitle, ckNoTrackNumber, ckAlbumNames, ckAlbumArtists,
    ckTrackTwice, ckTrackGap, ckYears, ckNoComposer, ckPartComposer, ckComposerNames, ckArtistNames,
    ckGenreNames);

  TCheckFinding = record
    Kind: TCheckKind;
    Text: string;                 // the album, or the spellings side by side with their track counts
    Note: string;                 // what was found, in a few words
    Paths: array of string;       // the files it is about
  end;
  TCheckFindings = array of TCheckFinding;

const
  CHECK_KIND_NAMES: array[TCheckKind] of string = ('No album', 'No artist', 'No title', 'No track number',
    'Several album names', 'Several album artists', 'Track number twice', 'Gap in the track numbers',
    'Several years', 'No composer', 'Composer on some tracks', 'Composer names', 'Artist names', 'Genre names');
  { between two spellings in a finding's text }
  CHECK_NAME_SEPARATOR = '   |   ';

{ the findings of these tracks, by kind and within a kind the one with the
  most files first }
procedure CheckTracks(ATracks: TTrackList; out AFindings: TCheckFindings);

{ what makes two names of people the same person for the check: the surname
  (the part before a comma, else the last word), in lower case without
  accents and punctuation }
function PersonKey(const AName: string): string;
{ what makes two names the same name: all of it, in lower case, without
  accents, spaces, punctuation and a leading "the" }
function NameKey(const AName: string): string;

implementation

uses
  Math, uMetaUtils, uAppStrings;

{ lower case, no accents, only letters, digits and what is not ASCII }
function Squeeze(const S: string): string;
var
  I, N: Integer;
  C: Char;
begin
  Result := '';
  SetLength(Result, Length(S));
  N := 0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C in ['a'..'z', '0'..'9']) or (C >= #128) then
    begin
      Inc(N);
      Result[N] := C;
    end;
  end;
  SetLength(Result, N);
end;

function NameKey(const AName: string): string;
var
  S: string;
begin
  S := Trim(LowerCase(StripAccents(AName)));
  if Copy(S, 1, 4) = 'the ' then Delete(S, 1, 4);
  Result := Squeeze(S);
end;

function PersonKey(const AName: string): string;
var
  S: string;
  P: Integer;
begin
  S := Trim(LowerCase(StripAccents(AName)));
  P := Pos(',', S);
  if P > 1 then
    S := Copy(S, 1, P - 1)
  else
  begin
    P := Length(S);
    while (P > 0) and (S[P] <> ' ') do Dec(P);
    S := Copy(S, P + 1, MaxInt);
  end;
  Result := Squeeze(S);
  if Result = '' then Result := NameKey(AName);
end;

type
  TKeyFunc = function(const AName: string): string;

  { one spelling of a name and the tracks (their places in the list) that have it }
  TSpelling = class
    Name: string;
    Tracks: TFPList;
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

constructor TSpelling.Create(const AName: string);
begin
  Name := AName;
  Tracks := TFPList.Create;
end;

destructor TSpelling.Destroy;
begin
  Tracks.Free;
  inherited Destroy;
end;

function NewLookup(AOwnsObjects: Boolean): TStringList;
begin
  Result := TStringList.Create;
  Result.UseLocale := False;
  Result.CaseSensitive := True;
  Result.Sorted := True;
  Result.Duplicates := dupError;
  Result.OwnsObjects := AOwnsObjects;
end;

function MoreTracksFirst(Item1, Item2: Pointer): Integer;
begin
  Result := TSpelling(Item2).Tracks.Count - TSpelling(Item1).Tracks.Count;
  if Result = 0 then Result := CompareStr(TSpelling(Item1).Name, TSpelling(Item2).Name);
end;

function AlbumArtistOf(T: PTrackInfo): string;
begin
  Result := T^.AlbumArtist;
end;

function AlbumNameOf(T: PTrackInfo): string;
begin
  Result := T^.Album;
end;

function YearOf(T: PTrackInfo): string;
begin
  if T^.Year > 0 then Result := IntToStr(T^.Year) else Result := '';
end;

procedure CheckTracks(ATracks: TTrackList; out AFindings: TCheckFindings);
var
  N: Integer;

  function NewFinding(AKind: TCheckKind): Integer;
  begin
    if N >= Length(AFindings) then SetLength(AFindings, N * 2 + 16);
    AFindings[N] := Default(TCheckFinding);
    AFindings[N].Kind := AKind;
    Result := N;
    Inc(N);
  end;

  { ---- helpers ---- }

  { a finding with the files of these tracks (their places in ATracks) }
  procedure Report(AKind: TCheckKind; const AText, ANote: string; AIdx: TFPList);
  var
    F, K: Integer;
  begin
    F := NewFinding(AKind);
    AFindings[F].Text := AText;
    AFindings[F].Note := ANote;
    SetLength(AFindings[F].Paths, AIdx.Count);
    for K := 0 to AIdx.Count - 1 do
      AFindings[F].Paths[K] := ATracks[PtrInt(AIdx[K])]^.FilePath;
  end;

  { "3 tracks" for all of them, else "3 of 12 tracks" }
  function CountText(APart, AAll: Integer): string;
  begin
    if APart >= AAll then
    begin
      if AAll = 1 then Result := '1 track' else Result := Format('%d tracks', [AAll]);
    end
    else
      Result := Format('%d of %d tracks', [APart, AAll]);
  end;

  function AlbumText(T: PTrackInfo): string;
  var
    Art, Alb: string;
  begin
    Alb := Trim(T^.Album);
    if Alb = '' then Alb := ExtractFileName(ExcludeTrailingPathDelimiter(T^.FolderDir));
    Art := Trim(T^.AlbumArtist);
    if Art = '' then Art := Trim(T^.Artist);
    if Art = '' then Art := LBL_UNKNOWN_ARTIST;
    Result := Art + ' - ' + Alb;
  end;

  { a folder by its last two parts: "Bach\Goldberg Variations" }
  function FolderText(const AFolder: string): string;
  var
    Dir, Parent: string;
  begin
    Dir := ExcludeTrailingPathDelimiter(AFolder);
    Result := ExtractFileName(Dir);
    Parent := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(Dir)));
    if Parent <> '' then Result := Parent + PathDelim + Result;
    if Result = '' then Result := AFolder;
  end;

  function NoAlbum(T: PTrackInfo): Boolean;
  begin
    Result := (Trim(T^.Album) = '') or SameText(Trim(T^.Album), LBL_UNKNOWN_ALBUM);
  end;

  { Several values of one field among AIdx's tracks (AValueOf gives a track's
    value, '' = none): a finding when there are two or more, with the values
    and their track counts and the files of all but the most used one. }
  type
    TValueOf = function(T: PTrackInfo): string;

  procedure ReportSeveral(AKind: TCheckKind; const APrefix, ANoun: string; AIdx: TFPList; AValueOf: TValueOf);
  var
    Values: TStringList;      // lower case value -> TSpelling (its first spelling, its tracks)
    Order, Rest: TFPList;
    I, At: Integer;
    V, Txt: string;
    Sp: TSpelling;
  begin
    Values := NewLookup(True);
    Order := TFPList.Create;
    Rest := TFPList.Create;
    try
      for I := 0 to AIdx.Count - 1 do
      begin
        V := Trim(AValueOf(ATracks[PtrInt(AIdx[I])]));
        if V = '' then Continue;
        if Values.Find(LowerCase(V), At) then
          Sp := TSpelling(Values.Objects[At])
        else
        begin
          Sp := TSpelling.Create(V);
          Values.AddObject(LowerCase(V), Sp);
        end;
        Sp.Tracks.Add(AIdx[I]);
      end;
      if Values.Count < 2 then Exit;
      for I := 0 to Values.Count - 1 do Order.Add(Values.Objects[I]);
      Order.Sort(@MoreTracksFirst);
      Txt := APrefix;
      for I := 0 to Order.Count - 1 do
      begin
        Sp := TSpelling(Order[I]);
        if I = 4 then
        begin
          Txt := Txt + CHECK_NAME_SEPARATOR + '...';
        end
        else if I < 4 then
        begin
          if I > 0 then Txt := Txt + CHECK_NAME_SEPARATOR;
          Txt := Txt + Format('%s (%d)', [Sp.Name, Sp.Tracks.Count]);
        end;
        if I > 0 then Rest.AddList(Sp.Tracks);
      end;
      Report(AKind, Txt, Format('%d %s', [Order.Count, ANoun]), Rest);
    finally
      Rest.Free;
      Order.Free;
      Values.Free;
    end;
  end;

  { ---- an album: the tracks of one folder with one album tag ---- }

  procedure CheckAlbum(AIdx: TFPList);
  var
    Part, Nums: TFPList;
    Discs: TStringList;          // 'disc|number' sorted, Objects = the track
    I, K, D, Num, PrevD, PrevN, Twice, MultiDisc, Shown: Integer;
    T, First: PTrackInfo;
    FileName, Miss, Key: string;
    HasGap, AllNumbered: Boolean;
  begin
    if AIdx.Count = 0 then Exit;
    First := ATracks[PtrInt(AIdx[0])];
    Part := TFPList.Create;
    Nums := TFPList.Create;
    Discs := TStringList.Create;
    try
      { no artist }
      for I := 0 to AIdx.Count - 1 do
      begin
        T := ATracks[PtrInt(AIdx[I])];
        if (Trim(T^.Artist) = '') or SameText(Trim(T^.Artist), LBL_UNKNOWN_ARTIST) then Part.Add(AIdx[I]);
      end;
      if Part.Count > 0 then Report(ckNoArtist, AlbumText(First), CountText(Part.Count, AIdx.Count), Part);

      { no title: empty, or only the name of the file }
      Part.Clear;
      for I := 0 to AIdx.Count - 1 do
      begin
        T := ATracks[PtrInt(AIdx[I])];
        FileName := ExtractFileName(T^.FilePath);
        if (Trim(T^.Title) = '') or SameText(Trim(T^.Title), FileName) or
           SameText(Trim(T^.Title), ChangeFileExt(FileName, '')) then Part.Add(AIdx[I]);
      end;
      if Part.Count > 0 then Report(ckNoTitle, AlbumText(First), CountText(Part.Count, AIdx.Count), Part);

      { no track number (a single loose track needs none) }
      Part.Clear;
      for I := 0 to AIdx.Count - 1 do
        if ATracks[PtrInt(AIdx[I])]^.TrackNumber <= 0 then Part.Add(AIdx[I]);
      AllNumbered := Part.Count = 0;
      if (Part.Count > 0) and (AIdx.Count >= 2) then
        Report(ckNoTrackNumber, AlbumText(First), CountText(Part.Count, AIdx.Count), Part);

      { the composer: on no track, or on some only }
      Part.Clear;
      for I := 0 to AIdx.Count - 1 do
        if Trim(ATracks[PtrInt(AIdx[I])]^.Composer) = '' then Part.Add(AIdx[I]);
      if Part.Count = AIdx.Count then
        Report(ckNoComposer, AlbumText(First), CountText(AIdx.Count, AIdx.Count), Part)
      else if Part.Count > 0 then
        Report(ckPartComposer, AlbumText(First), Format('%d of %d tracks without', [Part.Count, AIdx.Count]), Part);

      { several album artists, several years }
      ReportSeveral(ckAlbumArtists, AlbumText(First) + ':  ', 'album artists', AIdx, @AlbumArtistOf);
      ReportSeveral(ckYears, AlbumText(First) + ':  ', 'years', AIdx, @YearOf);

      { the track numbers of each disc: one twice, or a gap between the
        lowest and the highest (a disc may begin above 1 when the numbers run
        on from the disc before) }
      Discs.UseLocale := False;
      Discs.CaseSensitive := True;
      MultiDisc := -1;
      for I := 0 to AIdx.Count - 1 do
      begin
        T := ATracks[PtrInt(AIdx[I])];
        if T^.TrackNumber <= 0 then Continue;
        Discs.AddObject(Format('%.6d|%.6d', [Math.Max(0, T^.DiscNumber), T^.TrackNumber]), TObject(AIdx[I]));
        if MultiDisc = -1 then MultiDisc := T^.DiscNumber
        else if (MultiDisc >= 0) and (T^.DiscNumber <> MultiDisc) then MultiDisc := -2;
      end;
      Discs.Sort;
      Part.Clear;
      Twice := 0;
      Miss := '';
      Shown := 0;
      HasGap := False;
      PrevD := -1;
      PrevN := -1;
      Key := '';
      for I := 0 to Discs.Count - 1 do
      begin
        D := StrToIntDef(Copy(Discs[I], 1, 6), 0);
        Num := StrToIntDef(Copy(Discs[I], 8, 6), 0);
        if (D = PrevD) and (Num = PrevN) then
        begin
          { the number a second time: both tracks, the number once }
          if (Part.Count = 0) or (Part.Last <> Pointer(Discs.Objects[I - 1])) then Part.Add(Discs.Objects[I - 1]);
          Part.Add(Discs.Objects[I]);
          if Discs[I] <> Key then
          begin
            Inc(Twice);
            Key := Discs[I];
            Nums.Add(Pointer(PtrInt(Num)));
          end;
        end
        else if (D = PrevD) and (Num > PrevN + 1) then
        begin
          HasGap := True;
          for K := PrevN + 1 to Num - 1 do
          begin
            Inc(Shown);
            if Shown <= 6 then
            begin
              if Miss <> '' then Miss := Miss + ', ';
              if MultiDisc = -2 then Miss := Miss + Format('%d-%d', [D, K]) else Miss := Miss + IntToStr(K);
            end
            else if Shown = 7 then Miss := Miss + ' ...';
          end;
        end;
        PrevD := D;
        PrevN := Num;
      end;
      if Twice = 1 then
        Report(ckTrackTwice, AlbumText(First), Format('track %d twice', [Integer(PtrUInt(Nums[0]))]), Part)
      else if Twice > 1 then
        Report(ckTrackTwice, AlbumText(First), Format('%d numbers twice', [Twice]), Part);
      if HasGap and AllNumbered and (Twice = 0) and (AIdx.Count >= 2) then
        Report(ckTrackGap, AlbumText(First), 'missing: ' + Miss, AIdx);
    finally
      Discs.Free;
      Nums.Free;
      Part.Free;
    end;
  end;

  { ---- a folder: tracks without an album, and several album names ---- }

  procedure CheckFolder(AIdx: TFPList);
  var
    Part, WithAlbum: TFPList;
    I: Integer;
    T: PTrackInfo;
  begin
    if AIdx.Count = 0 then Exit;
    Part := TFPList.Create;
    WithAlbum := TFPList.Create;
    try
      for I := 0 to AIdx.Count - 1 do
      begin
        T := ATracks[PtrInt(AIdx[I])];
        if NoAlbum(T) then Part.Add(AIdx[I]) else WithAlbum.Add(AIdx[I]);
      end;
      T := ATracks[PtrInt(AIdx[0])];
      if Part.Count > 0 then
        Report(ckNoAlbum, FolderText(T^.FolderDir), CountText(Part.Count, AIdx.Count), Part);
      ReportSeveral(ckAlbumNames, FolderText(T^.FolderDir) + ':  ', 'album names', WithAlbum, @AlbumNameOf);
    finally
      WithAlbum.Free;
      Part.Free;
    end;
  end;

  { the tracks in runs of one key (AWithAlbum: folder and album tag, else the
    folder alone), each run to CheckAlbum or CheckFolder }
  procedure CheckRuns(AWithAlbum: Boolean);
  var
    Keys: TStringList;
    Run: TFPList;
    I, First: Integer;
    T: PTrackInfo;
    Key: string;
  begin
    Keys := TStringList.Create;
    Run := TFPList.Create;
    try
      Keys.UseLocale := False;
      Keys.CaseSensitive := True;
      for I := 0 to ATracks.Count - 1 do
      begin
        T := ATracks[I];
        Key := LowerCase(ExcludeTrailingPathDelimiter(T^.FolderDir));
        if AWithAlbum then Key := Key + #1 + LowerCase(Trim(T^.Album));
        Keys.AddObject(Key, TObject(PtrInt(I)));
      end;
      Keys.Sort;
      First := 0;
      while First < Keys.Count do
      begin
        Run.Clear;
        I := First;
        while (I < Keys.Count) and (Keys[I] = Keys[First]) do
        begin
          Run.Add(Keys.Objects[I]);
          Inc(I);
        end;
        if AWithAlbum then CheckAlbum(Run) else CheckFolder(Run);
        First := I;
      end;
    finally
      Run.Free;
      Keys.Free;
    end;
  end;
  { ---- names written in several ways ---- }

  procedure CheckNames(AKind: TCheckKind; AKey: TKeyFunc);
  var
    Spellings, Groups, Seen: TStringList;
    I, J, K, At, F: Integer;

    procedure Note(const AName: string; ATrack: Integer);
    var
      Sp: TSpelling;
    begin
      if Spellings.Find(AName, At) then
        Sp := TSpelling(Spellings.Objects[At])
      else
      begin
        Sp := TSpelling.Create(AName);
        Spellings.AddObject(AName, Sp);
      end;
      { (a name twice in the tags of one track counts once) }
      if (Sp.Tracks.Count = 0) or (PtrUInt(Sp.Tracks.Last) <> PtrUInt(ATrack)) then
        Sp.Tracks.Add(Pointer(PtrInt(ATrack)));
    end;

    procedure NoteItems(const ARaw: string; ATrack: Integer);
    var
      Rest, S: string;
      P: Integer;
    begin
      Rest := ARaw;
      repeat
        P := Pos(';', Rest);
        if P > 0 then
        begin
          S := Trim(Copy(Rest, 1, P - 1));
          Rest := Copy(Rest, P + 1, MaxInt);
        end
        else
          S := Trim(Rest);
        if S <> '' then Note(S, ATrack);
      until P = 0;
    end;

  var
    Key: string;
    L: TFPList;
    Sp: TSpelling;
    T: PTrackInfo;
  begin
    Spellings := NewLookup(True);
    Groups := NewLookup(True);
    Seen := NewLookup(False);
    try
      for I := 0 to ATracks.Count - 1 do
      begin
        T := ATracks[I];
        case AKind of
          ckComposerNames: NoteItems(T^.Composer, I);
          ckArtistNames:
            begin
              NoteItems(T^.AlbumArtist, I);
              NoteItems(T^.Artist, I);
            end;
          ckGenreNames: NoteItems(T^.Genre, I);
        end;
      end;
      { the spellings by what makes them the same name }
      for I := 0 to Spellings.Count - 1 do
      begin
        Key := AKey(Spellings[I]);
        if Key = '' then Continue;
        if Groups.Find(Key, At) then
          L := TFPList(Groups.Objects[At])
        else
        begin
          L := TFPList.Create;
          Groups.AddObject(Key, L);
        end;
        L.Add(Spellings.Objects[I]);
      end;
      for I := 0 to Groups.Count - 1 do
      begin
        L := TFPList(Groups.Objects[I]);
        if L.Count < 2 then Continue;
        L.Sort(@MoreTracksFirst);
        F := NewFinding(AKind);
        AFindings[F].Note := Format('%d spellings', [L.Count]);
        Seen.Clear;
        for J := 0 to L.Count - 1 do
        begin
          Sp := TSpelling(L[J]);
          if J > 0 then AFindings[F].Text := AFindings[F].Text + CHECK_NAME_SEPARATOR;
          AFindings[F].Text := AFindings[F].Text + Format('%s (%d)', [Sp.Name, Sp.Tracks.Count]);
          { the files of every spelling but the most used one, each once }
          if J = 0 then Continue;
          for K := 0 to Sp.Tracks.Count - 1 do
          begin
            Key := ATracks[PtrInt(Sp.Tracks[K])]^.FilePath;
            if not Seen.Find(Key, At) then Seen.Add(Key);
          end;
        end;
        SetLength(AFindings[F].Paths, Seen.Count);
        for J := 0 to Seen.Count - 1 do AFindings[F].Paths[J] := Seen[J];
      end;
    finally
      Seen.Free;
      Groups.Free;
      Spellings.Free;
    end;
  end;

  { by kind, within a kind the most files first, then by the text }
  function Before(const A, B: TCheckFinding): Boolean;
  begin
    if A.Kind <> B.Kind then Exit(A.Kind < B.Kind);
    if Length(A.Paths) <> Length(B.Paths) then Exit(Length(A.Paths) > Length(B.Paths));
    Result := CompareText(A.Text, B.Text) < 0;
  end;

  procedure SortFindings(L, R: Integer);
  var
    I, J: Integer;
    P, Tmp: TCheckFinding;
  begin
    while L < R do
    begin
      I := L;
      J := R;
      P := AFindings[(L + R) shr 1];
      repeat
        while Before(AFindings[I], P) do Inc(I);
        while Before(P, AFindings[J]) do Dec(J);
        if I <= J then
        begin
          Tmp := AFindings[I];
          AFindings[I] := AFindings[J];
          AFindings[J] := Tmp;
          Inc(I);
          Dec(J);
        end;
      until I > J;
      if J - L < R - I then
      begin
        SortFindings(L, J);
        L := I;
      end
      else
      begin
        SortFindings(I, R);
        R := J;
      end;
    end;
  end;

begin
  AFindings := nil;
  N := 0;
  if (ATracks = nil) or (ATracks.Count = 0) then Exit;
  CheckRuns(False);
  CheckRuns(True);
  CheckNames(ckComposerNames, @PersonKey);
  CheckNames(ckArtistNames, @NameKey);
  CheckNames(ckGenreNames, @NameKey);
  SetLength(AFindings, N);
  if N > 1 then SortFindings(0, N - 1);
end;

end.
