unit uLibraryTypes;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uLibraryTypes
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The library's track record and the functions that order tracks:
    TTrackInfo / PTrackInfo / TTrackInfoArray
    TTrackList           list that owns copies of track records (the
                         library's GetTracks... results)
    TScanProgressEvent / TScanDoneEvent (library scan events)
    NaturalCompareText   'Track 2' before 'Track 10', case-insensitive
    SmartTrackCompare    order inside an album: disc, then file name (when it
                         starts with a digit) or track number
    SortTracks_By...     TList sort functions for PTrackInfo lists; the names
                         compared as the library pane does (CompareLibraryNames);
                         TTrackList.Sort runs them as SortTracksFast (sort keys)
    CompareTrackInfo     folder, album artist, album, track (library order)
    RegroupTracksByFolder, ContainsDelimitedItem
  No shared state, no threads; covered by Tests\TestLibraryLogic.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils;

type
  PTrackInfo = ^TTrackInfo;

  TTrackInfo = record
    FilePath      : string;
    FolderDir     : string;
    Title         : string;
    Artist        : string;
    AlbumArtist   : string;
    Album         : string;
    Genre         : string;
    Composer      : string;
    Performer     : string;
    TrackNumber   : integer;
    DiscNumber    : integer;
    LastModified  : int64;
    FileSize      : Int64;
    DurationStr   : string;
    Comment       : string;

    Year          : Integer;
    DateStr       : string;
    SampleRate    : integer;
    BitDepth      : integer;
    DateAdded     : Int64;
    HasReplayGain : Boolean;

    // CACHED STRINGS FOR INSTANT SEARCH (Pre-lowercased & accent-stripped)
    CleanTitle       : string;
    CleanArtist      : string;
    CleanAlbumArtist : string;
    CleanAlbum       : string;
    CleanGenre       : string;
    CleanComposer    : string;
    CleanPerformer   : string;
    CleanFolder      : string;
    FileNameOnly     : string;

    // CACHED FINGERPRINTS FOR INSTANT QUERIES
    PrimaryFingerprint  : string;
    FallbackFingerprint : string;
  end;

  // Copies of library records (TLibraryManager.SnapshotTracks)
  TTrackInfoArray = array of TTrackInfo;

  { TTrackList }

  // A list of track records that it owns. Add stores a copy;
  // Clear and Free dispose the copies. The items are PTrackInfo, so the sort
  // functions below work on it. The library's GetTracks... methods fill it
  // with copies of their records: these stay valid for as long as the caller
  // keeps the list, whatever the library does meanwhile (a scan replacing all
  // records, an edit), and they are read without the library lock.
  TTrackList = class
  private
    FList: TList;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): PTrackInfo;
  public
    constructor Create;
    destructor Destroy; override;
    // Adds a copy of ATrack at the end and returns that copy
    function  Add(const ATrack: TTrackInfo): PTrackInfo;
    // Adds copies of all tracks of ASource at the end
    procedure AddList(ASource: TTrackList);
    procedure Clear;
    // With SortTracks_ByArtist / ByAlbum / ByFolder it sorts
    // with SortTracksFast (the same order, much faster); any other compare
    // function sorts the list directly
    procedure Sort(ACompare: TListSortCompare);
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: PTrackInfo read GetItem; default;
    // The PTrackInfo items as a TList, for code that takes one.
    // Reading and reordering are fine; never
    // add or delete through it: the TTrackList owns the items.
    property List: TList read FList;
  end;

  TScanProgressEvent = procedure(Sender: TObject; const ScanMsg: string;
    const CurrentFolder: string; TrackCount, TotalTracks: integer) of object;

  TScanDoneEvent = procedure(Sender: TObject; HasChanges: boolean) of object;
function NaturalCompareText(const S1, S2: string): integer;
function SmartTrackCompare(T1, T2: PTrackInfo): integer;

// Compares two names the way the library pane sorts them. The
// pane's lists (TStringList, CaseSensitive = False, UseLocale = True) use
// AnsiCompareText, which Lazarus' LazUTF8 turns into Windows' language-aware
// comparison of the UTF-8 text (UTF8CompareText: UTF-16, CompareStringW), so
// 'Édith' sorts with the E's and not after 'Z' as with CompareText. Names
// that are equal apart from the case of A..Z are answered by the fast
// CompareText first (most comparisons in a sort are within one album).
function CompareLibraryNames(const S1, S2: string): Integer;

// As CompareLibraryNames, and numbers by their value ('CD2'
// before 'CD10', as NaturalCompareText): Windows' comparison with
// SORT_DIGITSASNUMBERS (CompareStringW, LOCALE_USER_DEFAULT, NORM_IGNORECASE).
// Equal numbers with other leading zeros: the one with more zeros first
// ('Vol. 02' before 'Vol. 2'). Should Windows refuse the flag (it needs
// Windows 7), NaturalCompareText decides.
function CompareLibraryNamesNatural(const S1, S2: string): Integer;

type
  // The orders of SortTracks_ByArtist / ByAlbum / ByFolder and
  // of CompareTrackInfo, the library order (tsoLibrary)
  TTrackSortOrder = (tsoArtist, tsoAlbum, tsoFolder, tsoLibrary);

// Sorts AList (PTrackInfo) exactly like AList.Sort with the
// compare function of AOrder (SortTracks_By..., CompareTrackInfo), but fast:
// the Windows sort key of every distinct name is made once (LCMapStringW,
// LCMAP_SORTKEY with the flags of the comparison: LOCALE_USER_DEFAULT,
// NORM_IGNORECASE, for tsoLibrary also SORT_DIGITSASNUMBERS; comparing such
// keys byte by byte gives CompareStringW's order), then only the keys are
// compared
procedure SortTracksFast(AList: TList; AOrder: TTrackSortOrder);

// TList sort functions (items are PTrackInfo). The names
// (album artist, album, folder) are compared with CompareLibraryNames, so a
// playlist that gets several albums or folders at once orders them as the
// library pane shows them
function SortTracks_ByArtist(Item1, Item2: Pointer): Integer;
function SortTracks_ByAlbum(Item1, Item2: Pointer): Integer;
function SortTracks_ByFolder(Item1, Item2: Pointer): Integer;
// Library order: folder, album artist, album, then SmartTrackCompare.
// The names are compared with CompareLibraryNamesNatural (accents with
// their letter, numbers by value)
function CompareTrackInfo(Item1, Item2: Pointer): integer;

// True when TargetItem is one of the ';'-separated items of RawString (case-
// insensitive); an empty RawString matches the "Unknown Artist / Genre" labels
function ContainsDelimitedItem(const RawString, TargetItem: string): boolean;

implementation

uses
  Windows, contnrs, uAppStrings;

{ TTrackList }

constructor TTrackList.Create;begin
  inherited Create;
  FList := TList.Create;
end;

destructor TTrackList.Destroy;
begin
  if Assigned(FList) then
    Clear;
  FList.Free;
  inherited Destroy;
end;

function TTrackList.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TTrackList.GetItem(AIndex: Integer): PTrackInfo;
begin
  Result := PTrackInfo(FList[AIndex]);
end;

function TTrackList.Add(const ATrack: TTrackInfo): PTrackInfo;
begin
  New(Result);
  try
    Result^ := ATrack;
    FList.Add(Result);
  except
    Dispose(Result);
    raise;
  end;
end;

procedure TTrackList.AddList(ASource: TTrackList);
var
  I: Integer;
begin
  if (not Assigned(ASource)) or (ASource = Self) then
    Exit;
  FList.Capacity := FList.Count + ASource.Count;
  for I := 0 to ASource.Count - 1 do
    Add(ASource[I]^);
end;

procedure TTrackList.Clear;
var
  I: Integer;
begin
  for I := 0 to FList.Count - 1 do
    if Assigned(FList[I]) then
      Dispose(PTrackInfo(FList[I]));
  FList.Clear;
end;

procedure TTrackList.Sort(ACompare: TListSortCompare);
begin
  if FList.Count < 2 then
    Exit;
  // The library orders go through SortTracksFast: the same
  // order, but with sort keys instead of a Windows comparison per step
  // (50,000 tracks: about 0.2 s instead of 1.3-1.7 s)
  if ACompare = @SortTracks_ByArtist then
    SortTracksFast(FList, tsoArtist)
  else if ACompare = @SortTracks_ByAlbum then
    SortTracksFast(FList, tsoAlbum)
  else if ACompare = @SortTracks_ByFolder then
    SortTracksFast(FList, tsoFolder)
  else if ACompare = @CompareTrackInfo then
    SortTracksFast(FList, tsoLibrary)
  else
    FList.Sort(ACompare);
end;

const
  AL_SORT_DIGITSASNUMBERS = $00000008;  // Windows 7: numbers by their value
  AL_LCMAP_SORTKEY        = $00000400;

function CompareLibraryNames(const S1, S2: string): Integer;
begin
  Result := CompareText(S1, S2);
  if Result <> 0 then
    Result := AnsiCompareText(S1, S2);
end;

function CompareLibraryNamesNatural(const S1, S2: string): Integer;
var
  W1, W2: UnicodeString;
  R: Integer;
begin
  Result := CompareText(S1, S2);
  if Result = 0 then
    Exit;
  // An empty name first (as an empty sort key)
  if S1 = '' then
    Exit(-1);
  if S2 = '' then
    Exit(1);
  W1 := UTF8Decode(S1);
  W2 := UTF8Decode(S2);
  R  := CompareStringW(LOCALE_USER_DEFAULT, NORM_IGNORECASE or AL_SORT_DIGITSASNUMBERS,
          PWideChar(W1), Length(W1), PWideChar(W2), Length(W2));
  if R = 0 then
    Result := NaturalCompareText(S1, S2)  // the flag was refused
  else
    Result := R - 2;
end;

{ SortTracksFast }

type
  // One track and the sort keys of its names (in the order's sequence)
  TFastSortItem = record
    Track: PTrackInfo;
    Keys : array[0..2] of TBytes;
  end;
  PFastSortItem = ^TFastSortItem;

// The Windows sort key of S ('' = an empty key) with AFlags (NORM_IGNORECASE,
// for the library order also AL_SORT_DIGITSASNUMBERS; should
// Windows refuse that flag, the key is made without it)
function NameSortKey(const S: string; AFlags: DWORD): TBytes;
var
  W: UnicodeString;
  Len: Integer;
begin
  Result := nil;
  if S = '' then
    Exit;
  W   := UTF8Decode(S);
  Len := LCMapStringW(LOCALE_USER_DEFAULT, AL_LCMAP_SORTKEY or AFlags,
           PWideChar(W), Length(W), nil, 0);
  if (Len <= 0) and ((AFlags and AL_SORT_DIGITSASNUMBERS) <> 0) then
  begin
    AFlags := AFlags and not AL_SORT_DIGITSASNUMBERS;
    Len    := LCMapStringW(LOCALE_USER_DEFAULT, AL_LCMAP_SORTKEY or AFlags,
                PWideChar(W), Length(W), nil, 0);
  end;
  if Len <= 0 then
    Exit;
  SetLength(Result, Len);
  // For a sort key the destination is a byte buffer of Len bytes
  if LCMapStringW(LOCALE_USER_DEFAULT, AL_LCMAP_SORTKEY or AFlags,
       PWideChar(W), Length(W), PWideChar(@Result[0]), Len) <= 0 then
    Result := nil;
end;

// Byte order of two sort keys (memcmp, the shorter one first when equal so far)
function CompareSortKeys(const A, B: TBytes): Integer;
var
  L: Integer;
begin
  L := Length(A);
  if Length(B) < L then
    L := Length(B);
  if L > 0 then
    Result := CompareByte(A[0], B[0], L)
  else
    Result := 0;
  if Result = 0 then
    Result := Length(A) - Length(B);
end;

function CompareFastSortItems(Item1, Item2: Pointer): Integer;
var
  I1, I2: PFastSortItem;
  K: Integer;
begin
  I1 := PFastSortItem(Item1);
  I2 := PFastSortItem(Item2);
  for K := 0 to 2 do
  begin
    Result := CompareSortKeys(I1^.Keys[K], I2^.Keys[K]);
    if Result <> 0 then
      Exit;
  end;
  Result := SmartTrackCompare(I1^.Track, I2^.Track);
end;

procedure SortTracksFast(AList: TList; AOrder: TTrackSortOrder);
var
  Items   : array of TFastSortItem;
  Ptrs    : TList;
  Names   : TFPDataHashTable;  // exact spelling -> 1 + index into KeyStore
  KeyStore: array of TBytes;
  KeyCount: Integer;
  KeyFlags: DWORD;
  I, K    : Integer;
  T       : PTrackInfo;
  N       : string;

  // The key of AName, made once per distinct spelling
  function KeyOf(const AName: string): TBytes;
  var
    Slot: PtrInt;
  begin
    if AName = '' then
      Exit(nil);
    Slot := PtrInt(Names.Items[AName]);
    if Slot = 0 then
    begin
      if KeyCount = Length(KeyStore) then
        SetLength(KeyStore, 2 * KeyCount + 256);
      KeyStore[KeyCount] := NameSortKey(AName, KeyFlags);
      Inc(KeyCount);
      Slot := KeyCount;
      Names.Add(AName, Pointer(Slot));
    end;
    Result := KeyStore[Slot - 1];
  end;

begin
  if (AList = nil) or (AList.Count < 2) then
    Exit;

  // The flags of the order's compare function (CompareLibraryNames /
  // CompareLibraryNamesNatural)
  KeyFlags := NORM_IGNORECASE;
  if AOrder = tsoLibrary then
    KeyFlags := KeyFlags or AL_SORT_DIGITSASNUMBERS;

  SetLength(Items, AList.Count);
  KeyCount := 0;
  Names    := TFPDataHashTable.Create;
  Ptrs     := TList.Create;
  try
    for I := 0 to AList.Count - 1 do
    begin
      T := PTrackInfo(AList[I]);
      Items[I].Track := T;
      for K := 0 to 2 do
      begin
        case AOrder of
          tsoArtist:
            case K of
              0: N := T^.AlbumArtist;
              1: N := T^.Album;
            else
              N := T^.FolderDir;
            end;
          tsoAlbum:
            case K of
              0: N := T^.Album;
              1: N := T^.AlbumArtist;
            else
              N := ExtractFileDir(T^.FilePath);
            end;
          tsoLibrary:  // CompareTrackInfo
            case K of
              0: N := T^.FolderDir;
              1: N := T^.AlbumArtist;
            else
              N := T^.Album;
            end;
        else
          if K = 0 then
            N := T^.FolderDir
          else
            N := '';
        end;
        Items[I].Keys[K] := KeyOf(N);
      end;
    end;

    Ptrs.Capacity := Length(Items);
    for I := 0 to High(Items) do
      Ptrs.Add(@Items[I]);
    Ptrs.Sort(@CompareFastSortItems);

    for I := 0 to Ptrs.Count - 1 do
      AList[I] := PFastSortItem(Ptrs[I])^.Track;
  finally
    Ptrs.Free;
    Names.Free;
  end;
end;

function SortTracks_ByArtist(Item1, Item2: Pointer): Integer;
var
  T1, T2: PTrackInfo;
begin
  T1 := PTrackInfo(Item1);
  T2 := PTrackInfo(Item2);
  Result := CompareLibraryNames(T1^.AlbumArtist, T2^.AlbumArtist);
  if Result <> 0 then
    Exit;
  Result := CompareLibraryNames(T1^.Album, T2^.Album);
  if Result <> 0 then
    Exit;
  Result := CompareLibraryNames(T1^.FolderDir, T2^.FolderDir);
  if Result <> 0 then
    Exit;

  Result := SmartTrackCompare(T1, T2);
end;

function SortTracks_ByAlbum(Item1, Item2: Pointer): Integer;
var
  T1, T2: PTrackInfo;
begin
  T1 := PTrackInfo(Item1);
  T2 := PTrackInfo(Item2);

  Result := CompareLibraryNames(T1^.Album, T2^.Album);
  if Result <> 0 then
    Exit;

  Result := CompareLibraryNames(T1^.AlbumArtist, T2^.AlbumArtist);
  if Result <> 0 then
    Exit;

  Result := CompareLibraryNames(ExtractFileDir(T1^.FilePath), ExtractFileDir(T2^.FilePath));
  if Result <> 0 then
    Exit;

  Result := SmartTrackCompare(T1, T2);
end;

function SortTracks_ByFolder(Item1, Item2: Pointer): Integer;
var
  T1, T2: PTrackInfo;
begin
  T1 := PTrackInfo(Item1);
  T2 := PTrackInfo(Item2);
  Result := CompareLibraryNames(T1^.FolderDir, T2^.FolderDir);
  if Result <> 0 then
    Exit;

  Result := SmartTrackCompare(T1, T2);
end;

function SmartTrackCompare(T1, T2: PTrackInfo): integer;
var
  Digit1, Digit2: boolean;
begin
  if (T1^.DiscNumber > 0) and (T2^.DiscNumber > 0) and (T1^.DiscNumber <> T2^.DiscNumber) then
  begin
    if T1^.DiscNumber < T2^.DiscNumber then
      Exit(-1)
    else
      Exit(1);
  end;

  Digit1 := (Length(T1^.FileNameOnly) > 0) and (T1^.FileNameOnly[1] in ['0'..'9']);
  Digit2 := (Length(T2^.FileNameOnly) > 0) and (T2^.FileNameOnly[1] in ['0'..'9']);

  if Digit1 and Digit2 then
  begin
    Result := NaturalCompareText(T1^.FileNameOnly, T2^.FileNameOnly);
    if Result <> 0 then
      Exit;
  end
  else
  begin
    if T1^.TrackNumber < T2^.TrackNumber then
      Exit(-1);
    if T1^.TrackNumber > T2^.TrackNumber then
      Exit(1);
  end;

  Result := NaturalCompareText(T1^.FileNameOnly, T2^.FileNameOnly);
end;

function NaturalCompareText(const S1, S2: string): integer;
const
  MAX_SAFE_INT64 = (High(Int64) - 9) div 10;
var
  I1, I2, Len1, Len2: integer;
  Num1, Num2: int64;
  C1, C2: char;
begin
  I1   := 1;
  I2   := 1;
  Len1 := Length(S1);
  Len2 := Length(S2);
  while (I1 <= Len1) and (I2 <= Len2) do
  begin
    C1 := S1[I1];
    C2 := S2[I2];
    if (C1 in ['0'..'9']) and (C2 in ['0'..'9']) then
    begin
      Num1 := 0;
      while (I1 <= Len1) and (S1[I1] in ['0'..'9']) do
      begin
        if Num1 <= MAX_SAFE_INT64 then
          Num1 := Num1 * 10 + Ord(S1[I1]) - Ord('0');
        Inc(I1);
      end;

      Num2 := 0;
      while (I2 <= Len2) and (S2[I2] in ['0'..'9']) do
      begin
        if Num2 <= MAX_SAFE_INT64 then
          Num2 := Num2 * 10 + Ord(S2[I2]) - Ord('0');
        Inc(I2);
      end;

      if Num1 < Num2 then
        Exit(-1);
      if Num1 > Num2 then
        Exit(1);
    end
    else
    begin
      if UpCase(C1) < UpCase(C2) then
        Exit(-1);
      if UpCase(C1) > UpCase(C2) then
        Exit(1);
      Inc(I1);
      Inc(I2);
    end;
  end;
  if Len1 < Len2 then
    Exit(-1);
  if Len1 > Len2 then
    Exit(1);
  Result := 0;
end;

function CompareTrackInfo(Item1, Item2: Pointer): integer;
var
  T1, T2: PTrackInfo;
begin
  T1 := PTrackInfo(Item1);
  T2 := PTrackInfo(Item2);

  // CompareLibraryNamesNatural (NaturalCompareText would put accented
  // names after Z); TTrackList.Sort runs this order as
  // SortTracksFast(tsoLibrary)
  Result := CompareLibraryNamesNatural(T1^.FolderDir, T2^.FolderDir);
  if Result <> 0 then
    Exit;

  Result := CompareLibraryNamesNatural(T1^.AlbumArtist, T2^.AlbumArtist);
  if Result <> 0 then
    Exit;

  Result := CompareLibraryNamesNatural(T1^.Album, T2^.Album);
  if Result <> 0 then
    Exit;

  Result := SmartTrackCompare(T1, T2);
end;

function ContainsDelimitedItem(const RawString, TargetItem: string): boolean;
var
  Rem, S: string;
  p: integer;
begin
  Rem := Trim(RawString);
  if Rem = '' then
  begin
    Result := SameText(TargetItem, LBL_UNKNOWN_ARTIST) or
              SameText(TargetItem, LBL_UNKNOWN_GENRE);
    Exit;
  end;
  while True do
  begin
    p := Pos(';', Rem);
    if p > 0 then
    begin
      S := Trim(Copy(Rem, 1, p - 1));
      if SameText(S, TargetItem) then
        Exit(True);
      Rem := Trim(Copy(Rem, p + 1, Length(Rem)));
    end
    else
    begin
      if SameText(Trim(Rem), TargetItem) then
        Exit(True);
      Break;
    end;
  end;
  Result := False;
end;

end.
