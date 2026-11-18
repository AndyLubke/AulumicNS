unit TestPlaylistStore;

{$mode ObjFPC}{$H+}
{$codepage UTF8}

{ ==============================================================================
  Project:   AulumicNS - test program
  Unit Name: TestPlaylistStore

  The playlist store (uPlaylistStore: playlists.adb + playlists.jnl): every
  field survives save + reload; adding, renaming, changing and deleting
  survive without a save (the journal, as after a crash); the Default
  playlist always exists and cannot be renamed or deleted; names are unique
  (case-insensitive) and listed Default, playlists, auto-playlists.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uPlaylistFile, uPlaylistStore;

type
  TTestPlaylistStore = class(TTestCase)
  private
    FDir, FFile: string;
    function NewStore: TPlaylistStore;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SaveAndReloadKeepsEveryField;
    procedure ChangesSurviveWithoutASave;
    procedure DefaultAlwaysExists;
    procedure NamesAreUniqueAndListedInOrder;
  end;

implementation

uses
  TestHelpers;

const
  DEF = 'Default PlayList';

function Entry(const APath, ATitle: string; ANo: Integer): TPlaylistEntry;
begin
  Result := Default(TPlaylistEntry);
  Result.FilePath := APath;
  Result.Title := ATitle;
  Result.Artist := 'Antonín Dvořák';
  Result.AlbumArtist := 'Wiener Philharmoniker';
  Result.Album := 'Symphonie Nr. 9';
  Result.Genre := 'Klassik';
  Result.DurationStr := '12:01';
  Result.TrackNum := ANo;
  Result.DiscNum := 1;
  Result.Year := 1985;
  Result.DateStr := '1985-03-01';
  Result.SampleRate := 96000;
  Result.BitDepth := 24;
end;

procedure TTestPlaylistStore.SetUp;
begin
  FDir := CreateTestDir;
  FFile := FDir + 'playlists.adb';
end;

procedure TTestPlaylistStore.TearDown;
begin
  RemoveTestTree(FDir);
end;

function TTestPlaylistStore.NewStore: TPlaylistStore;
begin
  Result := TPlaylistStore.Create(FFile, DEF);
  Result.Load;
end;

procedure TTestPlaylistStore.SaveAndReloadKeepsEveryField;
var
  S: TPlaylistStore;
  P: PStoredPlaylist;
  E: TPlaylistEntries;
begin
  S := NewStore;
  try
    P := S.Add('Jazz Classics', pkNormal);
    AssertNotNull('Added', P);
    P^.GroupMode := 1;
    P^.HeaderFmt := '%album% (%year%)';
    P^.TrackFmt := '%title%';
    P^.LastFile := 'E:\Klassik\b.flac';
    SetLength(P^.Collapsed, 1);
    P^.Collapsed[0] := 'Symphonie Nr. 9';
    E := nil;
    SetLength(E, 2);
    E[0] := Entry('E:\Klassik\a.flac', 'Largo', 2);
    E[1] := Entry('E:\Klassik\b.flac', 'Scherzo', 3);
    S.SetEntries(P, E);
    P := S.Add('Recently Added', pkAuto);
    P^.Query := '%added% IN LAST 30d';
    S.Changed(P);
    S.Save;
    AssertFalse('Clean after the save', S.Dirty);
  finally
    S.Free;
  end;
  S := NewStore;
  try
    AssertFalse('Nothing to merge', S.Dirty);
    AssertEquals('Three playlists (with Default)', 3, S.Count);
    P := S.Find('jazz classics');
    AssertNotNull('Found (any case)', P);
    AssertEquals('Grouping', 1, P^.GroupMode);
    AssertEquals('Header format', '%album% (%year%)', P^.HeaderFmt);
    AssertEquals('Track format', '%title%', P^.TrackFmt);
    AssertEquals('Last file', 'E:\Klassik\b.flac', P^.LastFile);
    AssertEquals('Collapsed', 1, Length(P^.Collapsed));
    AssertEquals('Collapsed group', 'Symphonie Nr. 9', P^.Collapsed[0]);
    AssertEquals('Entries', 2, Length(P^.Entries));
    AssertEquals('Path', 'E:\Klassik\b.flac', P^.Entries[1].FilePath);
    AssertEquals('Title', 'Scherzo', P^.Entries[1].Title);
    AssertEquals('Artist', 'Antonín Dvořák', P^.Entries[1].Artist);
    AssertEquals('Album artist', 'Wiener Philharmoniker', P^.Entries[1].AlbumArtist);
    AssertEquals('Album', 'Symphonie Nr. 9', P^.Entries[1].Album);
    AssertEquals('Genre', 'Klassik', P^.Entries[1].Genre);
    AssertEquals('Length', '12:01', P^.Entries[1].DurationStr);
    AssertEquals('Track', 3, P^.Entries[1].TrackNum);
    AssertEquals('Disc', 1, P^.Entries[1].DiscNum);
    AssertEquals('Year', 1985, P^.Entries[1].Year);
    AssertEquals('Date', '1985-03-01', P^.Entries[1].DateStr);
    AssertEquals('Rate', 96000, P^.Entries[1].SampleRate);
    AssertEquals('Bits', 24, P^.Entries[1].BitDepth);
    P := S.Find('Recently Added');
    AssertNotNull('Auto-playlist', P);
    AssertTrue('Kind', P^.Kind = pkAuto);
    AssertEquals('Query', '%added% IN LAST 30d', P^.Query);
  finally
    S.Free;
  end;
end;

procedure TTestPlaylistStore.ChangesSurviveWithoutASave;
var
  S: TPlaylistStore;
  P: PStoredPlaylist;
  E: TPlaylistEntries;
  Snap, Jnl: TBytes;
begin
  S := NewStore;
  try
    S.Add('First', pkNormal);
    S.Add('Gone', pkNormal);
    S.Save;
    { after the snapshot: only in the journal }
    P := S.Find('First');
    E := nil;
    SetLength(E, 1);
    E[0] := Entry('D:\x.flac', 'X', 1);
    S.SetEntries(P, E);
    AssertTrue('Renamed', S.Rename('First', 'Renamed'));
    AssertTrue('Deleted', S.Delete('Gone'));
    S.Add('New', pkAuto);
    S.Save;   // the state above is in the snapshot now ...
  finally
    S.Free;
  end;
  { ... and once more without a snapshot: only journal records }
  S := NewStore;
  try
    P := S.Find('Renamed');
    P^.LastFile := 'D:\x.flac';
    S.Changed(P);
    S.Add('Journal only', pkNormal);
    S.Delete('New');
    { a crash: the files as they are now (the destructor saves a snapshot) }
    Snap := ReadFileBytes(FFile);
    Jnl := ReadFileBytes(ChangeFileExt(FFile, '.jnl'));
  finally
    S.Free;
  end;
  WriteFileBytes(FFile, Snap);
  WriteFileBytes(ChangeFileExt(FFile, '.jnl'), Jnl);
  S := NewStore;
  try
    AssertTrue('Replayed: changes to merge', S.Dirty);
    AssertNull('The old name is gone', S.Find('First'));
    P := S.Find('Renamed');
    AssertNotNull('Renamed playlist', P);
    AssertEquals('Its entries', 1, Length(P^.Entries));
    AssertEquals('Change from the journal', 'D:\x.flac', P^.LastFile);
    AssertNull('Deleted before the snapshot', S.Find('Gone'));
    AssertNotNull('Added in the journal', S.Find('Journal only'));
    AssertNull('Deleted in the journal', S.Find('New'));
  finally
    S.Free;
  end;
end;

procedure TTestPlaylistStore.DefaultAlwaysExists;
var
  S: TPlaylistStore;
begin
  S := NewStore;
  try
    AssertEquals('A new store has the Default playlist', 1, S.Count);
    AssertNotNull('Default', S.Find(DEF));
    AssertFalse('Not deleted', S.Delete(DEF));
    AssertFalse('Not renamed', S.Rename(DEF, 'Other'));
    AssertNull('No second Default', S.Add('default playlist', pkNormal));
    S.Add('Mine', pkNormal);
    AssertFalse('Nothing renamed to Default', S.Rename('Mine', DEF));
  finally
    S.Free;
  end;
end;

procedure TTestPlaylistStore.NamesAreUniqueAndListedInOrder;
var
  S: TPlaylistStore;
  L: TStringList;
begin
  S := NewStore;
  L := TStringList.Create;
  try
    AssertNotNull('Zebra', S.Add('Zebra', pkNormal));
    AssertNotNull('Auto', S.Add('A smart one', pkAuto));
    AssertNotNull('Alpha', S.Add('  Alpha  ', pkNormal));
    AssertNull('Taken (other case)', S.Add('alpha', pkNormal));
    AssertNull('Empty', S.Add('   ', pkNormal));
    AssertEquals('Unique name', 'Alpha (2)', S.UniqueName('Alpha'));
    AssertEquals('Free name', 'Beta', S.UniqueName('Beta'));
    S.GetNames(L);
    AssertEquals('Order', DEF + ',Alpha,Zebra,A smart one', L.CommaText.Replace('"', ''));
    AssertEquals('Kind of the last', Ord(pkAuto), PtrInt(L.Objects[3]));
  finally
    L.Free;
    S.Free;
  end;
end;

initialization
  RegisterTest(TTestPlaylistStore);

end.
