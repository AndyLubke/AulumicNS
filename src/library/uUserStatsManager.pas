unit uUserStatsManager;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uUserStatsManager
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Stores / Loads the UserStats database (date added, number of times played,
  ratings etc.).

  ---> AulumicNS: stored in the Aulos format (uDbStore): a snapshot
  (stats.adb) and a journal (stats.jnl). Every change (LogPlay, SetRating,
  SetFavorite, MigrateStats) appends the new state of its entry to the
  journal at once, so a play or a rating survives a crash; SaveToFile writes
  a new snapshot and starts a new journal (also when the journal has grown
  past STATS_JOURNAL_COMPACT_BYTES). Aulumic's text file (UserStats.db) is
  not read (AulumicNS has no import).
  =============================================================================}

interface

uses
  Classes, SysUtils, SyncObjs, DateUtils, uDbStore;

type
  PUserTrackStats = ^TUserTrackStats;
  TUserTrackStats = record
    IsFavorite  : Boolean;
    Rating      : Integer;  // 0..5 (or 0..10)
    PlayCount   : Integer;  // Ready for Step 5
    LastPlayed  : Int64;    // Ready for Step 5
  end;

  { TUserStatsManager }
  TUserStatsManager = class
  private
    FStatsLedger     : TStringList;
    FFilePath        : string;
    FCriticalSection : TCriticalSection;
    FIsDirty         : Boolean;
    // ---> AUDIT FIX U1: Prevents overwriting a valid stats file if LoadFromFile failed
    FLoadFailed      : Boolean;
    // ---> AulumicNS: the journal of the changes since the snapshot
    FJournal         : TDbJournal;
    FGeneration      : QWord;

    procedure ClearLedger;
    // ---> AulumicNS: appends the state of one entry (under the lock)
    procedure JournalEntry(const Fingerprint: string; Stats: PUserTrackStats);
    procedure ApplyJournalRecord(const AData: TBytes);
    function  EntryOf(const Key: string): PUserTrackStats;
  public
    // AFilePath: the snapshot (stats.adb); the journal is next to it (.jnl)
    constructor Create(const AFilePath: string);
    destructor Destroy; override;

    procedure LoadFromFile;
    procedure SaveToFile;

    // The universal ID generators
    function GenerateFingerprint(const Artist, Album, Title: string): string;
    function GenerateFingerprintFromClean(const CleanArtist, CleanAlbum, CleanTitle: string): string;

    // Migrates Rating, Favorite, PlayCount, and LastPlayed when tags are edited
    procedure MigrateStats(const OldPrimary, OldFallback, NewPrimary: string);

    // Core Interaction
    function GetStats(const Fingerprint: string): PUserTrackStats;
    function PeekStats(const Fingerprint: string): PUserTrackStats;
    procedure LogPlay(const Fingerprint: string);

    // Quick Actions
    procedure SetRating(const Fingerprint: string; ARating: Integer);
    procedure SetFavorite(const Fingerprint: string; AIsFavorite: Boolean);
    function ToggleFavorite(const Fingerprint: string): Boolean;

    // ---> AulumicNS: writable like TLibraryManager.IsDirty (tests: False =
    // the destructor writes no snapshot, as after a crash)
    property IsDirty: Boolean read FIsDirty write FIsDirty;
  end;

var
  // Global Singleton instance
  UserStatsManager: TUserStatsManager = nil;

implementation

uses uMetaUtils, uOSUtils, AuLog, uAppStrings;

const
  STATS_MAGIC                  = 'AUNSSTAT';
  STATS_JOURNAL_MAGIC          = 'AUNSSJNL';
  STATS_JOURNAL_COMPACT_BYTES  = 1024 * 1024;  // a new snapshot when the journal is larger
  JR_STATS_ENTRY               = 1;            // journal record: the state of one entry

// ---> AUDIT FIX U2: Strips control characters (#0..#31, especially Tab #9, CR, LF)
// so fingerprints can never corrupt tab-separated lines in the stats database!
function SanitizeFingerprintToken(const S: string): string;
var
  I, WriteIdx, Len: Integer;
  C: Char;
  HasControl: Boolean;
begin
  Len := Length(S);
  if Len = 0 then
    Exit('');

  HasControl := False;
  for I := 1 to Len do
  begin
    if Ord(S[I]) < 32 then
    begin
      HasControl := True;
      Break;
    end;
  end;

  if not HasControl then
    Exit(Trim(S));

  SetLength(Result, Len);
  WriteIdx := 0;
  for I := 1 to Len do
  begin
    C := S[I];
    if C in [#9, #10, #13] then
    begin
      if (WriteIdx > 0) and (Result[WriteIdx] <> ' ') then
      begin
        Inc(WriteIdx);
        Result[WriteIdx] := ' ';
      end;
    end
    else if Ord(C) >= 32 then
    begin
      Inc(WriteIdx);
      Result[WriteIdx] := C;
    end;
  end;
  SetLength(Result, WriteIdx);
  Result := Trim(Result);
end;

{ TUserStatsManager }

constructor TUserStatsManager.Create(const AFilePath: string);
begin
  inherited Create;
  FFilePath                  := AFilePath;
  FCriticalSection           := TCriticalSection.Create;
  FStatsLedger               := TStringList.Create;
  FStatsLedger.Sorted        := True;
  FStatsLedger.Duplicates    := dupIgnore;
  FStatsLedger.CaseSensitive := False;
  // ---> AUDIT FIX: Plain (non-locale) comparison. The keys are fingerprints
  // that are already lower case and accent-free; the locale comparison (UTF-16
  // conversion + Windows call per comparison) made every PeekStats slow, e.g.
  // for 'last played' auto-playlists over the whole library.
  FStatsLedger.UseLocale     := False;

  FIsDirty    := False;
  FLoadFailed := False;
  FJournal    := TDbJournal.Create(ChangeFileExt(AFilePath, '.jnl'), STATS_JOURNAL_MAGIC);
end;

destructor TUserStatsManager.Destroy;
begin
  SaveToFile; // Emergency auto-save on teardown
  ClearLedger;
  FStatsLedger.Free;
  FJournal.Free;
  FCriticalSection.Free;
  inherited Destroy;
end;

function TUserStatsManager.EntryOf(const Key: string): PUserTrackStats;
var
  Idx: Integer;
begin
  Idx := FStatsLedger.IndexOf(Key);
  if Idx >= 0 then
    Result := PUserTrackStats(FStatsLedger.Objects[Idx])
  else
  begin
    New(Result);
    Result^ := Default(TUserTrackStats);
    FStatsLedger.AddObject(Key, TObject(Result));
  end;
end;

procedure TUserStatsManager.JournalEntry(const Fingerprint: string; Stats: PUserTrackStats);
var
  W: TDbWriter;
begin
  if (Fingerprint = '') or (Stats = nil) then
    Exit;
  W := TDbWriter.Create;
  try
    W.U8(JR_STATS_ENTRY);
    W.Str(Fingerprint);
    W.Bool(Stats^.IsFavorite);
    W.I32(Stats^.Rating);
    W.I32(Stats^.PlayCount);
    W.I64(Stats^.LastPlayed);
    FJournal.Append(W.Bytes);
  finally
    W.Free;
  end;
  if FJournal.Size > STATS_JOURNAL_COMPACT_BYTES then
    SaveToFile;
end;

procedure TUserStatsManager.ApplyJournalRecord(const AData: TBytes);
var
  R: TDbReader;
  Key: string;
  Stats: PUserTrackStats;
begin
  R := TDbReader.Create(AData);
  try
    if R.U8 <> JR_STATS_ENTRY then
      Exit;                          // a record of a newer version: skipped
    Key   := R.Str;
    if Key = '' then
      Exit;
    Stats := EntryOf(Key);
    Stats^.IsFavorite := R.Bool;
    Stats^.Rating     := R.I32;
    Stats^.PlayCount  := R.I32;
    Stats^.LastPlayed := R.I64;
  finally
    R.Free;
  end;
end;

procedure TUserStatsManager.ClearLedger;
var
  I: Integer;
begin
  if not Assigned(FStatsLedger) then
    Exit;

  for I := 0 to FStatsLedger.Count - 1 do
    if Assigned(FStatsLedger.Objects[I]) then
      Dispose(PUserTrackStats(FStatsLedger.Objects[I]));

  FStatsLedger.Clear;
end;

function TUserStatsManager.GenerateFingerprint(const Artist, Album, Title: string): string;
begin
  // Lowercase, stripped of accents and control characters, separated by a unique token
  Result := SanitizeFingerprintToken(LowerCase(StripAccents(Artist))) + '::' +
            SanitizeFingerprintToken(LowerCase(StripAccents(Album))) + '::' +
            SanitizeFingerprintToken(LowerCase(StripAccents(Title)));
end;

function TUserStatsManager.GenerateFingerprintFromClean(const CleanArtist, CleanAlbum, CleanTitle: string): string;
begin
  Result := SanitizeFingerprintToken(CleanArtist) + '::' +
            SanitizeFingerprintToken(CleanAlbum) + '::' +
            SanitizeFingerprintToken(CleanTitle);
end;

procedure TUserStatsManager.MigrateStats(const OldPrimary, OldFallback, NewPrimary: string);
var
  SrcIdx, DstIdx: Integer;
  SrcStats, DstStats: PUserTrackStats;
begin
  if (NewPrimary = '') or SameText(OldPrimary, NewPrimary) then
    Exit;

  FCriticalSection.Enter;
  try
    SrcStats := nil;

    if OldPrimary <> '' then
    begin
      SrcIdx := FStatsLedger.IndexOf(OldPrimary);
      if SrcIdx >= 0 then
        SrcStats := PUserTrackStats(FStatsLedger.Objects[SrcIdx]);
    end;

    if (not Assigned(SrcStats)) and (OldFallback <> '') and
       (not SameText(OldFallback, NewPrimary)) then
    begin
      SrcIdx := FStatsLedger.IndexOf(OldFallback);
      if SrcIdx >= 0 then
        SrcStats := PUserTrackStats(FStatsLedger.Objects[SrcIdx]);
    end;

    if not Assigned(SrcStats) then
      Exit;

    // Only migrate if the old entry actually holds user activity
    if (not SrcStats^.IsFavorite) and (SrcStats^.Rating <= 0) and
       (SrcStats^.PlayCount <= 0) and (SrcStats^.LastPlayed <= 0) then
      Exit;

    DstIdx := FStatsLedger.IndexOf(NewPrimary);
    if DstIdx >= 0 then
    begin
      DstStats := PUserTrackStats(FStatsLedger.Objects[DstIdx]);
      if Assigned(DstStats) and (DstStats <> SrcStats) then
      begin
        if SrcStats^.IsFavorite then
          DstStats^.IsFavorite := True;
        if SrcStats^.Rating > DstStats^.Rating then
          DstStats^.Rating := SrcStats^.Rating;
        if SrcStats^.PlayCount > DstStats^.PlayCount then
          DstStats^.PlayCount := SrcStats^.PlayCount;
        if SrcStats^.LastPlayed > DstStats^.LastPlayed then
          DstStats^.LastPlayed := SrcStats^.LastPlayed;
        FIsDirty := True;
        JournalEntry(NewPrimary, DstStats);
      end;
    end
    else
    begin
      New(DstStats);
      DstStats^ := SrcStats^;
      FStatsLedger.AddObject(NewPrimary, TObject(DstStats));
      FIsDirty := True;
      JournalEntry(NewPrimary, DstStats);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TUserStatsManager.GetStats(const Fingerprint: string): PUserTrackStats;
var
  Idx: Integer;
begin
  Result := nil;
  if Fingerprint = '' then
    Exit;

  FCriticalSection.Enter;
  try
    Idx := FStatsLedger.IndexOf(Fingerprint);

    if Idx >= 0 then
      Result := PUserTrackStats(FStatsLedger.Objects[Idx])
    else
    begin
      New(Result);
      Result^.IsFavorite := False;
      Result^.Rating     := 0;
      Result^.PlayCount  := 0;
      Result^.LastPlayed := 0;

      FStatsLedger.AddObject(Fingerprint, TObject(Result));
      FIsDirty := True;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TUserStatsManager.PeekStats(const Fingerprint: string): PUserTrackStats;
var
  Idx: Integer;
begin
  Result := nil;
  if Fingerprint = '' then
    Exit;

  FCriticalSection.Enter;
  try
    Idx := FStatsLedger.IndexOf(Fingerprint);
    if Idx >= 0 then
      Result := PUserTrackStats(FStatsLedger.Objects[Idx]);
  finally
    FCriticalSection.Leave;
  end;
end;

// ---> AUDIT FIX U3: Modify Stats fields under FCriticalSection
procedure TUserStatsManager.LogPlay(const Fingerprint: string);
var
  Stats: PUserTrackStats;
begin
  if Fingerprint = '' then
    Exit;

  FCriticalSection.Enter;
  try
    Stats := GetStats(Fingerprint);
    if Assigned(Stats) then
    begin
      Inc(Stats^.PlayCount);
      Stats^.LastPlayed := DateTimeToUnix(Now, False);
      FIsDirty          := True;
      JournalEntry(Fingerprint, Stats);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TUserStatsManager.SetRating(const Fingerprint: string; ARating: Integer);
var
  Stats: PUserTrackStats;
begin
  if Fingerprint = '' then
    Exit;

  FCriticalSection.Enter;
  try
    Stats := GetStats(Fingerprint);
    if Assigned(Stats) and (Stats^.Rating <> ARating) then
    begin
      Stats^.Rating     := ARating;
      Stats^.IsFavorite := (ARating >= 5);
      FIsDirty          := True;
      JournalEntry(Fingerprint, Stats);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TUserStatsManager.SetFavorite(const Fingerprint: string; AIsFavorite: Boolean);
var
  Stats: PUserTrackStats;
begin
  if Fingerprint = '' then
    Exit;

  FCriticalSection.Enter;
  try
    Stats := GetStats(Fingerprint);
    if Assigned(Stats) and (Stats^.IsFavorite <> AIsFavorite) then
    begin
      Stats^.IsFavorite := AIsFavorite;
      if AIsFavorite then
        Stats^.Rating := 5
      else
        Stats^.Rating := 0;
      FIsDirty := True;
      JournalEntry(Fingerprint, Stats);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TUserStatsManager.ToggleFavorite(const Fingerprint: string): Boolean;
var
  Stats: PUserTrackStats;
begin
  Result := False;
  if Fingerprint = '' then
    Exit;

  FCriticalSection.Enter;
  try
    Stats := GetStats(Fingerprint);
    if Assigned(Stats) then
    begin
      SetFavorite(Fingerprint, not Stats^.IsFavorite);
      Result := Stats^.IsFavorite;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

// ---> AulumicNS: the snapshot (stats.adb), then the journal of its
// generation. Snapshot body: count, then per entry fingerprint, favorite,
// rating, play count, last played (Unix time).
procedure TUserStatsManager.LoadFromFile;
var
  Body: TBytes;
  Err, Key, BackupPath: string;
  Gen: QWord;
  R: TDbReader;
  N, I: Integer;
  Stats: PUserTrackStats;
  Payloads: TList;
  Fav: Boolean;
  Rating, Plays: Integer;
  Last: Int64;
begin
  FCriticalSection.Enter;
  try
    ClearLedger;
    FIsDirty    := False;
    FLoadFailed := False;
    FGeneration := 0;
    if LoadSnapshot(FFilePath, STATS_MAGIC, Gen, Body, Err) then
    begin
      R := TDbReader.Create(Body);
      try
        try
          N := R.Count(4 + 1 + 4 + 4 + 8);
          FStatsLedger.Capacity := N;
          for I := 0 to N - 1 do
          begin
            Key    := R.Str;
            Fav    := R.Bool;
            Rating := R.I32;
            Plays  := R.I32;
            Last   := R.I64;
            if Key = '' then
              Continue;
            Stats := EntryOf(Key);
            Stats^.IsFavorite := Fav;
            Stats^.Rating     := Rating;
            Stats^.PlayCount  := Plays;
            Stats^.LastPlayed := Last;
          end;
          FGeneration := Gen;
        except
          on E: Exception do
          begin
            ClearLedger;
            Err := E.Message;
          end;
        end;
      finally
        R.Free;
      end;
    end;
    if Err <> '' then
    begin
      // ---> AUDIT FIX U1: an unreadable file is never overwritten by an empty
      // ledger: kept as a backup first
      FLoadFailed := True;
      AddLog(SafeFormat(FMT_LOG_STATS_LOAD_FAILED, [Err]), False, True);
      if BackupFileWithTimestamp(FFilePath, BackupPath) then
      begin
        AddLog(SafeFormat(FMT_LOG_STATS_BACKUP, [BackupPath]), False, True);
        FLoadFailed := False;
      end;
    end;

    // The changes since that snapshot
    Payloads := TList.Create;
    try
      if (not FLoadFailed) and (FJournal.Replay(FGeneration, Payloads) > 0) then
      begin
        for I := 0 to Payloads.Count - 1 do
          try
            ApplyJournalRecord(PDbPayload(Payloads[I])^.Data);
          except
            // a damaged record (CRC was right): skipped
          end;
        FIsDirty := True;       // merged into the next snapshot
      end;
    finally
      FreePayloads(Payloads);
      Payloads.Free;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TUserStatsManager.SaveToFile;
var
  W: TDbWriter;
  I, N: Integer;
  Stats: PUserTrackStats;
  Err: string;
  Body: TBytes;
begin
  FCriticalSection.Enter;
  try
    if not FIsDirty then
      Exit;
    // ---> AUDIT FIX U1: Never overwrite an existing stats file after a failed
    // load unless it was backed up first (FIsDirty stays True)
    if FLoadFailed and FileExists(FFilePath) then
      Exit;

    { only entries with user activity are kept }
    N := 0;
    for I := 0 to FStatsLedger.Count - 1 do
    begin
      Stats := PUserTrackStats(FStatsLedger.Objects[I]);
      if Assigned(Stats) and
         ((Stats^.Rating > 0) or Stats^.IsFavorite or (Stats^.PlayCount > 0)) then
        Inc(N);
    end;
    W := TDbWriter.Create;
    try
      W.U32(N);
      for I := 0 to FStatsLedger.Count - 1 do
      begin
        Stats := PUserTrackStats(FStatsLedger.Objects[I]);
        if Assigned(Stats) and
           ((Stats^.Rating > 0) or Stats^.IsFavorite or (Stats^.PlayCount > 0)) then
        begin
          W.Str(SanitizeFingerprintToken(FStatsLedger[I]));
          W.Bool(Stats^.IsFavorite);
          W.I32(Stats^.Rating);
          W.I32(Stats^.PlayCount);
          W.I64(Stats^.LastPlayed);
        end;
      end;
      Body := W.Bytes;
    finally
      W.Free;
    end;

    if SaveSnapshot(FFilePath, STATS_MAGIC, FGeneration + 1, Body, Err) then
    begin
      Inc(FGeneration);
      FIsDirty    := False;
      FLoadFailed := False;
      // the journal now starts after the new snapshot
      FJournal.Reset(FGeneration);
    end
    else
      AddLog(SafeFormat(FMT_LOG_STATS_SAVE_FAILED, [Err]), False, True);
  finally
    FCriticalSection.Leave;
  end;
end;

end.
