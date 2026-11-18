unit TestReplayGainScan;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestReplayGainScan
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for uReplayGainScan (the rules of a ReplayGain scan, no UI, no thread):
    TTestReplayGainRules  : the gain of a loudness (reference -18 LUFS, limits,
                            silence, invalid values), the status texts, the
                            album key
    TTestReplayGainAlbums : the albums of the library and of a selection (each
                            selected album completed with its other library
                            tracks, each file once), "missing only", the album
                            group list owning its lists
  The library is a text library of six tracks in a temporary folder; no audio
  file is read. It is imported into the library's store
  (ImportAulumicDatabase), as the other library tests do.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uLibraryTypes, uLibraryManager,
  uReplayGainScan;

type
  TTestReplayGainRules = class(TTestCase)
  published
    procedure GainIsTheDistanceToMinus18LUFS;
    procedure GainIsLimited;
    procedure SilenceAndInvalidValuesGiveZero;
    procedure EveryStatusHasItsText;
    procedure AlbumKeyIsFolderAlbumArtistAndAlbum;
  end;

  TTestReplayGainAlbums = class(TTestCase)
  private
    FDir: string;
    FLib: TLibraryManager;
    // Files of AGroup without their folder, comma-separated
    function Names(AGroup: TStringList): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure LibraryGroupsEveryAlbum;
    procedure SelectionIsCompletedWithTheWholeAlbum;
    procedure MissingOnlyDropsAlbumsWithReplayGain;
    procedure NothingToGroup;
    procedure GroupListOwnsItsLists;
  end;

implementation

uses
  Math, uAppStrings, uLibraryDatabase, TestHelpers, TestLibraryLogic;

const
  ALPHA_DIR = 'D:\M\Alpha\';
  BETA_DIR  = 'D:\M\Beta\';
  DELTA     = 0.0001;

{ TTestReplayGainRules }

procedure TTestReplayGainRules.GainIsTheDistanceToMinus18LUFS;
begin
  AssertEquals('-23 LUFS (EBU R128 broadcast level)', 5.0, GainFromLoudness(-23.0), DELTA);
  AssertEquals('-18 LUFS (the reference)', 0.0, GainFromLoudness(-18.0), DELTA);
  AssertEquals('-8 LUFS (a loud master)', -10.0, GainFromLoudness(-8.0), DELTA);
end;

procedure TTestReplayGainRules.GainIsLimited;
begin
  AssertEquals('Very quiet: at most +24 dB', 24.0, GainFromLoudness(-69.0), DELTA);
  AssertEquals('Louder than possible: at least -60 dB', -60.0, GainFromLoudness(50.0), DELTA);
end;

procedure TTestReplayGainRules.SilenceAndInvalidValuesGiveZero;
begin
  AssertEquals('-70 LUFS counts as silence', 0.0, GainFromLoudness(-70.0), DELTA);
  AssertEquals('Below -70 LUFS', 0.0, GainFromLoudness(-120.0), DELTA);
  AssertEquals('NaN', 0.0, GainFromLoudness(NaN), DELTA);
  AssertEquals('+Infinity', 0.0, GainFromLoudness(Infinity), DELTA);
  AssertEquals('-Infinity (digital silence)', 0.0, GainFromLoudness(NegInfinity), DELTA);
end;

procedure TTestReplayGainRules.EveryStatusHasItsText;
var
  S, T: TRGResultStatus;
begin
  AssertEquals('Ready', STATUS_RG_READY_TO_SAVE, RGStatusText(rsReadyToSave));
  AssertEquals('Album incomplete', STATUS_RG_ALBUM_INCOMPLETE, RGStatusText(rsAlbumIncomplete));
  AssertEquals('Decode error', STATUS_RG_DECODE_ERROR, RGStatusText(rsDecodeError));
  AssertEquals('File missing', STATUS_RG_FILE_MISSING, RGStatusText(rsFileMissing));
  AssertEquals('Drive offline', STATUS_RG_DRIVE_OFFLINE, RGStatusText(rsDriveOffline));

  for S := Low(TRGResultStatus) to High(TRGResultStatus) do
    for T := Low(TRGResultStatus) to High(TRGResultStatus) do
      if S <> T then
        AssertTrue('Texts differ', RGStatusText(S) <> RGStatusText(T));
end;

procedure TTestReplayGainRules.AlbumKeyIsFolderAlbumArtistAndAlbum;
var
  A, B: TTrackInfo;
begin
  A := MakeTrack(ALPHA_DIR + '01.flac', 'One', 'Artist', 'Alpha');
  B := MakeTrack('d:\m\alpha\02.flac', 'Two', ' ARTIST ', 'alpha ');
  AssertEquals('Case and spaces do not matter', RGAlbumKey(A), RGAlbumKey(B));

  B := MakeTrack(BETA_DIR + '01.flac', 'One', 'Artist', 'Alpha');
  AssertTrue('Another folder', RGAlbumKey(A) <> RGAlbumKey(B));

  B := MakeTrack(ALPHA_DIR + '02.flac', 'Two', 'Other Artist', 'Alpha');
  AssertTrue('Another album artist', RGAlbumKey(A) <> RGAlbumKey(B));

  B := MakeTrack(ALPHA_DIR + '02.flac', 'Two', 'Artist', 'Bonus');
  AssertTrue('Another album in the same folder', RGAlbumKey(A) <> RGAlbumKey(B));
end;

{ TTestReplayGainAlbums }

procedure TTestReplayGainAlbums.SetUp;
var
  SL: TStringList;

  procedure AddTrack(const APath, AArtist, AAlbum: string; AHasGain: Boolean);
  var
    T: TTrackInfo;
  begin
    T := MakeTrack(APath, ExtractFileName(APath), AArtist, AAlbum);
    T.HasReplayGain := AHasGain;
    SL.Add(FormatTrackLine(T));
  end;

begin
  FDir := CreateTestDir;
  SL := TStringList.Create;
  try
    // Alpha: one track without ReplayGain. Bonus: another album in the same
    // folder. Beta: all tracks with ReplayGain.
    AddTrack(ALPHA_DIR + 'A1.flac', 'X', 'Alpha', True);
    AddTrack(ALPHA_DIR + 'A2.flac', 'X', 'Alpha', False);
    AddTrack(BETA_DIR  + 'B1.flac', 'Y', 'Beta',  True);
    AddTrack(ALPHA_DIR + 'A3.flac', 'X', 'Alpha', True);
    AddTrack(BETA_DIR  + 'B2.flac', 'Y', 'Beta',  True);
    AddTrack(ALPHA_DIR + 'C1.flac', 'X', 'Bonus', True);
    SL.SaveToFile(FDir + 'Library.db', TEncoding.UTF8);
  finally
    SL.Free;
  end;

  FLib := TLibraryManager.Create(FDir + 'library.adb');
  AssertEquals('imported', 6, ImportAulumicDatabase(FLib, FDir + 'Library.db'));
end;

procedure TTestReplayGainAlbums.TearDown;
begin
  FreeAndNil(FLib);
  RemoveTestTree(FDir);
end;

function TTestReplayGainAlbums.Names(AGroup: TStringList): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AGroup.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + ExtractFileName(AGroup[I]);
  end;
end;

procedure TTestReplayGainAlbums.LibraryGroupsEveryAlbum;
var
  Groups: TRGAlbumGroups;
  Missing: Integer;
begin
  AssertEquals('Library loaded', 6, FLib.GetTrackCount);

  Groups := LibraryAlbumGroups(FLib, Missing);
  try
    AssertEquals('Alpha, Beta, Bonus', 3, Groups.Count);
    AssertEquals('Alpha (library order)', 'A1.flac,A2.flac,A3.flac', Names(Groups[0]));
    AssertEquals('Beta', 'B1.flac,B2.flac', Names(Groups[1]));
    AssertEquals('Bonus', 'C1.flac', Names(Groups[2]));
    AssertEquals('One album has a track without ReplayGain', 1, Missing);
  finally
    Groups.Free;
  end;
end;

procedure TTestReplayGainAlbums.SelectionIsCompletedWithTheWholeAlbum;
var
  Sel: TTrackList;
  Groups: TRGAlbumGroups;
  Tracks, Missing: Integer;
begin
  Sel := TTrackList.Create;
  try
    // A1 twice (e.g. selected through its artist and its genre), B2, and a
    // file outside the library
    Sel.Add(MakeTrack(ALPHA_DIR + 'A1.flac', 'A1', 'X', 'Alpha'));
    Sel.Add(MakeTrack(BETA_DIR  + 'B2.flac', 'B2', 'Y', 'Beta'));
    Sel.Add(MakeTrack(ALPHA_DIR + 'A1.flac', 'A1', 'X', 'Alpha'));
    Sel.Add(MakeTrack('E:\New\N1.flac', 'N1', 'Z', 'New'));

    Groups := SelectionAlbumGroups(FLib, Sel, Tracks, Missing);
    try
      AssertEquals('Alpha, Beta, New', 3, Groups.Count);
      AssertEquals('Alpha: the selected track, then the rest of the album',
        'A1.flac,A2.flac,A3.flac', Names(Groups[0]));
      AssertEquals('Beta: the selected track, then the rest', 'B2.flac,B1.flac', Names(Groups[1]));
      AssertEquals('Outside the library: only itself', 'N1.flac', Names(Groups[2]));
      AssertEquals('Each file once (Bonus not added)', 6, Tracks);
      AssertEquals('Only Alpha misses ReplayGain', 1, Missing);
    finally
      Groups.Free;
    end;
  finally
    Sel.Free;
  end;
end;

procedure TTestReplayGainAlbums.MissingOnlyDropsAlbumsWithReplayGain;
var
  Groups: TRGAlbumGroups;
  Missing: Integer;
begin
  Groups := LibraryAlbumGroups(FLib, Missing);
  try
    RemoveAlbumsWithGain(FLib, Groups);
    AssertEquals('Only Alpha is left', 1, Groups.Count);
    AssertEquals('Alpha', 'A1.flac,A2.flac,A3.flac', Names(Groups[0]));
  finally
    Groups.Free;
  end;
end;

procedure TTestReplayGainAlbums.NothingToGroup;
var
  Sel: TTrackList;
  Groups: TRGAlbumGroups;
  Tracks, Missing: Integer;
begin
  Sel := TTrackList.Create;
  try
    Sel.Add(MakeTrack('', 'No path', 'X', 'Alpha'));

    Groups := SelectionAlbumGroups(FLib, Sel, Tracks, Missing);
    try
      AssertEquals('A track without a path: no groups', 0, Groups.Count);
      AssertEquals('No tracks', 0, Tracks);
      AssertEquals('Nothing missing', 0, Missing);
    finally
      Groups.Free;
    end;

    Groups := SelectionAlbumGroups(nil, Sel, Tracks, Missing);
    try
      AssertEquals('No library: no groups', 0, Groups.Count);
    finally
      Groups.Free;
    end;
  finally
    Sel.Free;
  end;

  Groups := LibraryAlbumGroups(nil, Missing);
  try
    AssertEquals('No library: no albums', 0, Groups.Count);
    AssertEquals('Nothing missing', 0, Missing);
  finally
    Groups.Free;
  end;
end;

procedure TTestReplayGainAlbums.GroupListOwnsItsLists;
var
  Groups: TRGAlbumGroups;
  L: TStringList;
begin
  // Every list is freed by the group list (heaptrc reports a leak otherwise)
  Groups := TRGAlbumGroups.Create;
  try
    L := TStringList.Create;
    L.Add('a');
    Groups.Add(L);
    L := TStringList.Create;
    L.Add('b');
    Groups.Add(L);

    Groups.Delete(0);
    AssertEquals('One left', 1, Groups.Count);
    AssertEquals('The second one', 'b', Groups[0][0]);
  finally
    Groups.Free;
  end;
end;

initialization
  RegisterTest(TTestReplayGainRules);
  RegisterTest(TTestReplayGainAlbums);

end.
