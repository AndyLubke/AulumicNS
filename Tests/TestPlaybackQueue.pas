unit TestPlaybackQueue;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestPlaybackQueue
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for the play queue of TPlaybackManager (shuffle modes). Nothing is
  played: the queue is only filled and reordered while the manager is
  stopped, and read back with GetQueueSnapshot.
  Each queue item's file name is 'A<album>T<track>.flac', so the order can be
  checked from the snapshot.
  TTestSampleRateFamily: the rate family rule (uAudioUtils.SampleRateFamily)
  that decides which target rate setting the sample rate dialog changes.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uPlaybackManager,
  uAppConsts, uAppStrings, uAudioUtils;

type
  TTestPlaybackQueue = class(TTestCase)
  private
    FManager: TPlaybackManager;
    procedure FillQueue(AAlbums, ATracksPerAlbum: Integer);
    // File names in play order (from GetQueueSnapshot)
    function  PlayOrder: TStringList;
    procedure SetShuffle(AMode: TShuffleMode);
    procedure CheckEveryTrackOnce(AOrder: TStringList; AAlbums, ATracksPerAlbum: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ShuffleOffKeepsOriginalOrder;
    procedure TrackShuffleKeepsEveryTrackOnce;
    procedure TrackShuffleChangesTheOrder;
    procedure AlbumShuffleKeepsAlbumsTogether;
    procedure AlbumShuffleKeepsEveryTrackOnce;
    procedure ShuffleOffRestoresOriginalOrder;
    procedure ShuffleModeCycles;
    procedure ClearQueueEmptiesTheQueue;
    // The list was built again (SyncQueue): the playing track ...
    procedure APlayingTrackThatIsStillInTheListPlaysOn;
    procedure APlayingTrackTheUserRemovedStops;
    procedure APlayingTrackThatLeftAnAutoPlaylistPlaysOn;
  private
    function NewList(ASkipId: Integer): TList;
  end;

  { TTestSampleRateFamily }
  TTestSampleRateFamily = class(TTestCase)
  published
    // The track rates of the resampler's rate map, by family
    procedure RateMapRatesHaveTheirFamily;
    // The refused rate of a resampled track is a target option: every option
    // of a family must be in that family (the dialog relies on it)
    procedure TargetOptionsHaveTheirFamily;
    // 0 (unknown) and rates of neither family count as 44.1 kHz
    procedure OtherRatesAre44Family;
    // TargetRateChoices (the main window's rate menu, the "choose another
    // rate" dialog) = the preferences' list of the family, ascending
    procedure ChoicesAreThePreferencesList;
    procedure ChoicesStayInTheirFamily;
  end;

implementation

function TrackFileName(AAlbum, ATrack: Integer): string;
begin
  Result := Format('A%.2dT%.2d.flac', [AAlbum, ATrack]);
end;

{ TTestPlaybackQueue }

procedure TTestPlaybackQueue.SetUp;
begin
  FManager := TPlaybackManager.Create;
end;

procedure TTestPlaybackQueue.TearDown;
begin
  FreeAndNil(FManager);
end;

procedure TTestPlaybackQueue.FillQueue(AAlbums, ATracksPerAlbum: Integer);
var
  A, T, Id: Integer;
begin
  Id := 0;
  for A := 1 to AAlbums do
    for T := 1 to ATracksPerAlbum do
    begin
      Inc(Id);
      FManager.AddToQueue('D:\Music\Album ' + IntToStr(A) + '\' + TrackFileName(A, T),
        'Album ' + IntToStr(A), Id, 'Test Playlist');
    end;
end;

function TTestPlaybackQueue.PlayOrder: TStringList;
var
  Snapshot : TStringList;
  CurIdx   : Integer;
  I, P     : Integer;
begin
  Result   := TStringList.Create;
  Snapshot := TStringList.Create;
  try
    FManager.GetQueueSnapshot(Snapshot, CurIdx);
    // Lines look like '[3] A01T04.flac'
    for I := 0 to Snapshot.Count - 1 do
    begin
      P := Pos('] ', Snapshot[I]);
      Result.Add(Copy(Snapshot[I], P + 2, MaxInt));
    end;
  finally
    Snapshot.Free;
  end;
end;

// ToggleShuffle cycles Off -> Track -> Album -> Off and rebuilds the queue
procedure TTestPlaybackQueue.SetShuffle(AMode: TShuffleMode);
var
  Guard: Integer;
begin
  for Guard := 1 to 3 do
  begin
    FManager.ToggleShuffle;
    if FManager.ShuffleMode = AMode then
      Exit;
  end;
  Fail('Shuffle mode not reached: ' + IntToStr(Ord(AMode)));
end;

procedure TTestPlaybackQueue.CheckEveryTrackOnce(AOrder: TStringList;
  AAlbums, ATracksPerAlbum: Integer);
var
  A, T: Integer;
  Sorted: TStringList;
begin
  AssertEquals('Track count', AAlbums * ATracksPerAlbum, AOrder.Count);
  Sorted := TStringList.Create;
  try
    Sorted.Sorted     := True;
    Sorted.Duplicates := dupError;
    try
      Sorted.AddStrings(AOrder);
    except
      on E: EStringListError do
        Fail('A track appears twice in the queue');
    end;
    for A := 1 to AAlbums do
      for T := 1 to ATracksPerAlbum do
        AssertTrue('Missing ' + TrackFileName(A, T),
          Sorted.IndexOf(TrackFileName(A, T)) >= 0);
  finally
    Sorted.Free;
  end;
end;

procedure TTestPlaybackQueue.ShuffleOffKeepsOriginalOrder;
var
  Order: TStringList;
  A, T, I: Integer;
begin
  FillQueue(3, 4);
  SetShuffle(smTrack);
  SetShuffle(smOff);
  Order := PlayOrder;
  try
    I := 0;
    for A := 1 to 3 do
      for T := 1 to 4 do
      begin
        AssertEquals(Format('Position %d', [I]), TrackFileName(A, T), Order[I]);
        Inc(I);
      end;
  finally
    Order.Free;
  end;
end;

procedure TTestPlaybackQueue.TrackShuffleKeepsEveryTrackOnce;
var
  Order: TStringList;
begin
  FillQueue(5, 8);
  SetShuffle(smTrack);
  Order := PlayOrder;
  try
    CheckEveryTrackOnce(Order, 5, 8);
  finally
    Order.Free;
  end;
end;

procedure TTestPlaybackQueue.TrackShuffleChangesTheOrder;
var
  Order: TStringList;
  A, T, I, SamePlace: Integer;
begin
  // 40 tracks: the chance that a shuffle leaves more than half of them in
  // place is negligible
  FillQueue(5, 8);
  SetShuffle(smTrack);
  Order := PlayOrder;
  try
    SamePlace := 0;
    I := 0;
    for A := 1 to 5 do
      for T := 1 to 8 do
      begin
        if Order[I] = TrackFileName(A, T) then
          Inc(SamePlace);
        Inc(I);
      end;
    AssertTrue(Format('Shuffle left %d of 40 tracks in place', [SamePlace]), SamePlace < 20);
  finally
    Order.Free;
  end;
end;

procedure TTestPlaybackQueue.AlbumShuffleKeepsAlbumsTogether;
var
  Order: TStringList;
  I, T, BlockStart: Integer;
  Album: string;
begin
  FillQueue(6, 5);
  SetShuffle(smAlbum);
  Order := PlayOrder;
  try
    AssertEquals('Track count', 30, Order.Count);
    // Every block of 5 is one album, its tracks in their original order
    BlockStart := 0;
    while BlockStart < Order.Count do
    begin
      Album := Copy(Order[BlockStart], 1, 3);  // 'A03'
      for T := 1 to 5 do
      begin
        I := BlockStart + T - 1;
        AssertEquals(Format('Position %d', [I]), Album + Format('T%.2d.flac', [T]), Order[I]);
      end;
      Inc(BlockStart, 5);
    end;
  finally
    Order.Free;
  end;
end;

procedure TTestPlaybackQueue.AlbumShuffleKeepsEveryTrackOnce;
var
  Order: TStringList;
begin
  FillQueue(6, 5);
  SetShuffle(smAlbum);
  Order := PlayOrder;
  try
    CheckEveryTrackOnce(Order, 6, 5);
  finally
    Order.Free;
  end;
end;

procedure TTestPlaybackQueue.ShuffleOffRestoresOriginalOrder;
var
  Order: TStringList;
begin
  FillQueue(4, 4);
  SetShuffle(smTrack);
  SetShuffle(smAlbum);
  SetShuffle(smOff);
  Order := PlayOrder;
  try
    AssertEquals('First', TrackFileName(1, 1), Order[0]);
    AssertEquals('Fifth', TrackFileName(2, 1), Order[4]);
    AssertEquals('Last',  TrackFileName(4, 4), Order[Order.Count - 1]);
  finally
    Order.Free;
  end;
end;

procedure TTestPlaybackQueue.ShuffleModeCycles;
begin
  AssertEquals('Starts off', Ord(smOff), Ord(FManager.ShuffleMode));
  FManager.ToggleShuffle;
  AssertEquals('Then track', Ord(smTrack), Ord(FManager.ShuffleMode));
  FManager.ToggleShuffle;
  AssertEquals('Then album', Ord(smAlbum), Ord(FManager.ShuffleMode));
  FManager.ToggleShuffle;
  AssertEquals('Then off again', Ord(smOff), Ord(FManager.ShuffleMode));
end;

procedure TTestPlaybackQueue.ClearQueueEmptiesTheQueue;
var
  Order: TStringList;
begin
  FillQueue(2, 3);
  SetShuffle(smTrack);
  AssertEquals('Filled', 6, FManager.QueueCount);
  FManager.ClearQueue;
  AssertEquals('QueueCount', 0, FManager.QueueCount);
  AssertEquals('CurrentIndex', -1, FManager.CurrentIndex);
  Order := PlayOrder;
  try
    AssertEquals('Play order', 0, Order.Count);
  finally
    Order.Free;
  end;
end;

// The 6 tracks of FillQueue(2, 3) again as new queue items, without ASkipId
function TTestPlaybackQueue.NewList(ASkipId: Integer): TList;
var
  A, T, Id: Integer;
  Q: PQueueItem;
begin
  Result := TList.Create;
  Id := 0;
  for A := 1 to 2 do
    for T := 1 to 3 do
    begin
      Inc(Id);
      if Id = ASkipId then
        Continue;
      New(Q);
      Q^ := Default(TQueueItem);
      Q^.FilePath := 'D:\Music\Album ' + IntToStr(A) + '\' + TrackFileName(A, T);
      Q^.Album    := 'Album ' + IntToStr(A);
      Q^.TrackId  := 100 + Id;          // a list built again has new ids
      Q^.SourceID := 'Test Playlist';
      Result.Add(Q);
    end;
end;

procedure TTestPlaybackQueue.APlayingTrackThatIsStillInTheListPlaysOn;
var
  L: TList;
begin
  FillQueue(2, 3);
  FManager.AssumePaused(3);
  L := NewList(0);
  try
    FManager.SyncQueue(L);
  finally
    L.Free;
  end;
  AssertTrue('still playing', FManager.State <> psStopped);
  AssertEquals('the same track', TrackFileName(2, 1), ExtractFileName(FManager.GetCurrentItem^.FilePath));
  AssertEquals('6 tracks', 6, FManager.QueueCount);
end;

procedure TTestPlaybackQueue.APlayingTrackTheUserRemovedStops;
var
  L: TList;
begin
  FillQueue(2, 3);
  FManager.AssumePaused(3);
  L := NewList(4);
  try
    FManager.SyncQueue(L);
  finally
    L.Free;
  end;
  AssertTrue('stopped', FManager.State = psStopped);
  AssertEquals('5 tracks', 5, FManager.QueueCount);
end;

procedure TTestPlaybackQueue.APlayingTrackThatLeftAnAutoPlaylistPlaysOn;
var
  L: TList;
  Order: TStringList;
begin
  FillQueue(2, 3);
  FManager.AssumePaused(3);
  L := NewList(4);
  try
    FManager.SyncQueue(L, True);
  finally
    L.Free;
  end;
  AssertTrue('still playing', FManager.State <> psStopped);
  AssertEquals('the same track', TrackFileName(2, 1), ExtractFileName(FManager.GetCurrentItem^.FilePath));
  Order := PlayOrder;
  try
    AssertEquals('it stays in the queue', 6, Order.Count);
    AssertEquals('at its old place', TrackFileName(2, 1), Order[3]);
    AssertEquals('the list goes on after it', TrackFileName(2, 2), Order[4]);
  finally
    Order.Free;
  end;
end;

{ TTestSampleRateFamily }

procedure TTestSampleRateFamily.RateMapRatesHaveTheirFamily;
const
  Rates44: array[0..6] of Integer = (44100, 88200, 176400, 352800, 705600, 1411200, 2822400);
  Rates48: array[0..6] of Integer = (48000, 96000, 192000, 384000, 768000, 1536000, 3072000);
var
  I: Integer;
begin
  for I := Low(Rates44) to High(Rates44) do
    AssertEquals(IntToStr(Rates44[I]), RATE_FAMILY_44K, SampleRateFamily(Rates44[I]));
  for I := Low(Rates48) to High(Rates48) do
    AssertEquals(IntToStr(Rates48[I]), RATE_FAMILY_48K, SampleRateFamily(Rates48[I]));
end;

procedure TTestSampleRateFamily.TargetOptionsHaveTheirFamily;
var
  I, Rate: Integer;
begin
  for I := Low(TARGET_RATE_44_OPTIONS) to High(TARGET_RATE_44_OPTIONS) do
  begin
    Rate := StrToInt(TARGET_RATE_44_OPTIONS[I].DataStr);
    AssertEquals('44.1 kHz option ' + IntToStr(Rate), RATE_FAMILY_44K, SampleRateFamily(Rate));
  end;
  for I := Low(TARGET_RATE_48_OPTIONS) to High(TARGET_RATE_48_OPTIONS) do
  begin
    Rate := StrToInt(TARGET_RATE_48_OPTIONS[I].DataStr);
    AssertEquals('48 kHz option ' + IntToStr(Rate), RATE_FAMILY_48K, SampleRateFamily(Rate));
  end;
end;

procedure TTestSampleRateFamily.OtherRatesAre44Family;
begin
  AssertEquals('0', RATE_FAMILY_44K, SampleRateFamily(0));
  AssertEquals('Negative', RATE_FAMILY_44K, SampleRateFamily(-48000));
  AssertEquals('22050', RATE_FAMILY_44K, SampleRateFamily(22050));
  AssertEquals('32000', RATE_FAMILY_44K, SampleRateFamily(32000));
end;

procedure TTestSampleRateFamily.ChoicesAreThePreferencesList;
var
  Rates: TRateArray;
  I: Integer;
begin
  Rates := TargetRateChoices(RATE_FAMILY_44K);
  AssertEquals('44.1 kHz count', Length(TARGET_RATE_44_OPTIONS), Length(Rates));
  for I := 0 to High(Rates) do
    AssertEquals('44.1 kHz choice ' + IntToStr(I),
      StrToInt(TARGET_RATE_44_OPTIONS[Low(TARGET_RATE_44_OPTIONS) + I].DataStr), Rates[I]);

  Rates := TargetRateChoices(RATE_FAMILY_48K);
  AssertEquals('48 kHz count', Length(TARGET_RATE_48_OPTIONS), Length(Rates));
  for I := 0 to High(Rates) do
    AssertEquals('48 kHz choice ' + IntToStr(I),
      StrToInt(TARGET_RATE_48_OPTIONS[Low(TARGET_RATE_48_OPTIONS) + I].DataStr), Rates[I]);

  // Any rate of the family gives its list; the menu's highest rate is the
  // preferences' highest (it offered 1411.2 / 1536 kHz before)
  Rates := TargetRateChoices(192000);
  AssertEquals('From 192 kHz: first', 48000, Rates[0]);
  AssertEquals('From 192 kHz: last', 768000, Rates[High(Rates)]);
  Rates := TargetRateChoices(88200);
  AssertEquals('From 88.2 kHz: first', 44100, Rates[0]);
  AssertEquals('From 88.2 kHz: last', 705600, Rates[High(Rates)]);
end;

procedure TTestSampleRateFamily.ChoicesStayInTheirFamily;
var
  Rates: TRateArray;
  I: Integer;
begin
  Rates := TargetRateChoices(RATE_FAMILY_44K);
  for I := 0 to High(Rates) do
  begin
    AssertEquals('44.1 kHz family ' + IntToStr(Rates[I]), RATE_FAMILY_44K, SampleRateFamily(Rates[I]));
    if I > 0 then
      AssertTrue('44.1 kHz ascending at ' + IntToStr(I), Rates[I] > Rates[I - 1]);
  end;

  Rates := TargetRateChoices(RATE_FAMILY_48K);
  for I := 0 to High(Rates) do
  begin
    AssertEquals('48 kHz family ' + IntToStr(Rates[I]), RATE_FAMILY_48K, SampleRateFamily(Rates[I]));
    if I > 0 then
      AssertTrue('48 kHz ascending at ' + IntToStr(I), Rates[I] > Rates[I - 1]);
  end;
end;

initialization
  RegisterTest(TTestPlaybackQueue);
  RegisterTest(TTestSampleRateFamily);

end.
