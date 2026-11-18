unit uPlaylistStore;

{ ==============================================================================
  AulumicNS - uPlaylistStore
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  All playlists and auto-playlists of AulumicNS in the Aulos format
  (uDbStore, as the library): Data\Playlists\playlists.adb (snapshot) and
  playlists.jnl (journal). Aulumic kept one file per playlist (.pdb, .apq);
  their readers are kept for the tests only (AulumicNS has no import).

  One record per playlist (TStoredPlaylist): the name, the kind (normal /
  auto), Aulumic's per-playlist view (grouping, header and track format, the
  collapsed groups), the auto-playlist's query, the entries (path and the
  cached tags of uPlaylistFile.TPlaylistEntry, so a track outside the
  library is shown without reading its file) and the last selected file
  (Aulumic's playlist state).

  Every change journals the whole record at once (PUT) or its removal (DEL),
  so a crash loses no playlist edit; Save writes a new snapshot (at exit and
  when the journal has grown past PL_JOURNAL_COMPACT_BYTES). The Default
  playlist always exists and cannot be removed or renamed. Names are unique
  (case-insensitive). UI thread only (no lock).
  Covered by Tests\TestPlaylistStore.pas.
  =============================================================================}

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, uDbStore, uPlaylistFile;

type
  TPlaylistKind = (pkNormal, pkAuto);

  PStoredPlaylist = ^TStoredPlaylist;
  TStoredPlaylist = record
    Name      : string;
    Kind      : TPlaylistKind;
    GroupMode : Integer;          // Ord(TGroupingMode); -1 = the default
    HeaderFmt : string;           // '' = the default
    TrackFmt  : string;           // '' = the default
    Query     : string;           // auto-playlists
    Entries   : TPlaylistEntries; // normal playlists
    Collapsed : array of string;  // header texts / albums of collapsed groups
    LastFile  : string;           // the selected track when the playlist was left
    Modified  : TDateTime;
  end;

  { TPlaylistStore }

  TPlaylistStore = class
  private
    FFile: string;
    FJournal: TDbJournal;
    FGeneration: QWord;
    FItems: TFPList;              // PStoredPlaylist
    FDirty: Boolean;
    FLoadFailed: Boolean;
    FDefaultName: string;
    procedure ClearItems;
    procedure EnsureDefault;
    procedure JournalPut(P: PStoredPlaylist);
    procedure JournalDelete(const AName: string);
    procedure ApplyJournalRecord(const AData: TBytes);
    procedure PutItem(const AItem: TStoredPlaylist);
  public
    { AFile: the snapshot (playlists.adb); ADefaultName: the Default playlist }
    constructor Create(const AFile, ADefaultName: string);
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    function Count: Integer;
    function Item(I: Integer): PStoredPlaylist;
    function IndexOf(const AName: string): Integer;
    function Find(const AName: string): PStoredPlaylist;
    function IsDefault(const AName: string): Boolean;
    { a new playlist (nil when the name is taken or empty) }
    function Add(const AName: string; AKind: TPlaylistKind): PStoredPlaylist;
    function Rename(const AOldName, ANewName: string): Boolean;
    function Delete(const AName: string): Boolean;
    { after the caller changed P's fields: journaled at once }
    procedure Changed(P: PStoredPlaylist);
    procedure SetEntries(P: PStoredPlaylist; const AEntries: TPlaylistEntries);
    { AName, or AName (2), AName (3) ... when it is taken }
    function UniqueName(const AName: string): string;
    { the Default playlist, then the normal playlists, then the
      auto-playlists (each sorted); AList.Objects = Ord(TPlaylistKind) }
    procedure GetNames(AList: TStrings);
    property Dirty: Boolean read FDirty;
    property DefaultName: string read FDefaultName;
    property FileName: string read FFile;
  end;

{ a name a playlist may have: trimmed, no control characters }
function CleanPlaylistName(const AName: string): string;

implementation

uses
  uOSUtils, AuLog, uAppStrings;

const
  PL_MAGIC                 = 'AUNSPLST';
  PL_JOURNAL_MAGIC         = 'AUNSPJNL';
  PL_JOURNAL_COMPACT_BYTES = 8 * 1024 * 1024;
  JR_PL_PUT                = 1;
  JR_PL_DELETE             = 2;

function CleanPlaylistName(const AName: string): string;
var
  I: Integer;
begin
  Result := AName;
  for I := 1 to Length(Result) do
    if Ord(Result[I]) < 32 then Result[I] := ' ';
  Result := Trim(Result);
end;

procedure WriteEntry(W: TDbWriter; const E: TPlaylistEntry);
begin
  W.Str(E.FilePath);
  W.Str(E.Title);
  W.Str(E.Artist);
  W.Str(E.AlbumArtist);
  W.Str(E.Album);
  W.Str(E.Genre);
  W.Str(E.DurationStr);
  W.I32(E.TrackNum);
  W.I32(E.DiscNum);
  W.I32(E.Year);
  W.Str(E.DateStr);
  W.I32(E.SampleRate);
  W.I32(E.BitDepth);
end;

function ReadEntry(R: TDbReader): TPlaylistEntry;
begin
  Result := Default(TPlaylistEntry);
  Result.FilePath    := R.Str;
  Result.Title       := R.Str;
  Result.Artist      := R.Str;
  Result.AlbumArtist := R.Str;
  Result.Album       := R.Str;
  Result.Genre       := R.Str;
  Result.DurationStr := R.Str;
  Result.TrackNum    := R.I32;
  Result.DiscNum     := R.I32;
  Result.Year        := R.I32;
  Result.DateStr     := R.Str;
  Result.SampleRate  := R.I32;
  Result.BitDepth    := R.I32;
  Result.HasGenre        := True;
  Result.HasExtendedInfo := True;
end;

const
  ENTRY_MIN_BYTES = 9 * 4 + 5 * 4;

procedure WritePlaylist(W: TDbWriter; const P: TStoredPlaylist);
var
  I: Integer;
begin
  W.Str(P.Name);
  W.U8(Ord(P.Kind));
  W.I32(P.GroupMode);
  W.Str(P.HeaderFmt);
  W.Str(P.TrackFmt);
  W.Str(P.Query);
  W.Str(P.LastFile);
  W.Dbl(P.Modified);
  W.U32(Length(P.Collapsed));
  for I := 0 to High(P.Collapsed) do W.Str(P.Collapsed[I]);
  W.U32(Length(P.Entries));
  for I := 0 to High(P.Entries) do WriteEntry(W, P.Entries[I]);
end;

function ReadPlaylist(R: TDbReader): TStoredPlaylist;
var
  I, N: Integer;
  K: Byte;
begin
  Result := Default(TStoredPlaylist);
  Result.Name      := R.Str;
  K                := R.U8;
  if K > Ord(High(TPlaylistKind)) then K := 0;
  Result.Kind      := TPlaylistKind(K);
  Result.GroupMode := R.I32;
  Result.HeaderFmt := R.Str;
  Result.TrackFmt  := R.Str;
  Result.Query     := R.Str;
  Result.LastFile  := R.Str;
  Result.Modified  := R.Dbl;
  N := R.Count(4);
  SetLength(Result.Collapsed, N);
  for I := 0 to N - 1 do Result.Collapsed[I] := R.Str;
  N := R.Count(ENTRY_MIN_BYTES);
  SetLength(Result.Entries, N);
  for I := 0 to N - 1 do Result.Entries[I] := ReadEntry(R);
end;

{ TPlaylistStore }

constructor TPlaylistStore.Create(const AFile, ADefaultName: string);
begin
  inherited Create;
  FFile := AFile;
  FDefaultName := ADefaultName;
  FItems := TFPList.Create;
  FJournal := TDbJournal.Create(ChangeFileExt(AFile, '.jnl'), PL_JOURNAL_MAGIC);
  EnsureDefault;
end;

destructor TPlaylistStore.Destroy;
begin
  if FDirty then Save;
  ClearItems;
  FItems.Free;
  FJournal.Free;
  inherited Destroy;
end;

procedure TPlaylistStore.ClearItems;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do Dispose(PStoredPlaylist(FItems[I]));
  FItems.Clear;
end;

procedure TPlaylistStore.EnsureDefault;
var
  P: PStoredPlaylist;
begin
  if IndexOf(FDefaultName) >= 0 then Exit;
  New(P);
  P^ := Default(TStoredPlaylist);
  P^.Name := FDefaultName;
  P^.GroupMode := -1;
  FItems.Insert(0, P);
end;

function TPlaylistStore.Count: Integer;
begin
  Result := FItems.Count;
end;

function TPlaylistStore.Item(I: Integer): PStoredPlaylist;
begin
  Result := PStoredPlaylist(FItems[I]);
end;

function TPlaylistStore.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if SameText(PStoredPlaylist(FItems[I])^.Name, AName) then Exit(I);
  Result := -1;
end;

function TPlaylistStore.Find(const AName: string): PStoredPlaylist;
var
  I: Integer;
begin
  I := IndexOf(AName);
  if I >= 0 then Result := Item(I) else Result := nil;
end;

function TPlaylistStore.IsDefault(const AName: string): Boolean;
begin
  Result := SameText(AName, FDefaultName);
end;

procedure TPlaylistStore.PutItem(const AItem: TStoredPlaylist);
var
  I: Integer;
  P: PStoredPlaylist;
begin
  if AItem.Name = '' then Exit;
  I := IndexOf(AItem.Name);
  if I >= 0 then
    Item(I)^ := AItem
  else
  begin
    New(P);
    P^ := AItem;
    FItems.Add(P);
  end;
end;

{ ---- journal ---- }

procedure TPlaylistStore.JournalPut(P: PStoredPlaylist);
var
  W: TDbWriter;
begin
  W := TDbWriter.Create;
  try
    W.U8(JR_PL_PUT);
    WritePlaylist(W, P^);
    FJournal.Append(W.Bytes);
  finally
    W.Free;
  end;
  if FJournal.Size > PL_JOURNAL_COMPACT_BYTES then Save;
end;

procedure TPlaylistStore.JournalDelete(const AName: string);
var
  W: TDbWriter;
begin
  W := TDbWriter.Create;
  try
    W.U8(JR_PL_DELETE);
    W.Str(AName);
    FJournal.Append(W.Bytes);
  finally
    W.Free;
  end;
end;

procedure TPlaylistStore.ApplyJournalRecord(const AData: TBytes);
var
  R: TDbReader;
  T: Byte;
  I: Integer;
begin
  R := TDbReader.Create(AData);
  try
    T := R.U8;
    if T = JR_PL_PUT then
      PutItem(ReadPlaylist(R))
    else if T = JR_PL_DELETE then
    begin
      I := IndexOf(R.Str);
      if I >= 0 then
      begin
        Dispose(Item(I));
        FItems.Delete(I);
      end;
    end;
  finally
    R.Free;
  end;
end;

{ ---- load / save ---- }

procedure TPlaylistStore.Load;
var
  Body: TBytes;
  Err, BackupPath: string;
  Gen: QWord;
  R: TDbReader;
  N, I: Integer;
  Payloads: TList;
begin
  ClearItems;
  FDirty := False;
  FLoadFailed := False;
  FGeneration := 0;
  if LoadSnapshot(FFile, PL_MAGIC, Gen, Body, Err) then
  begin
    R := TDbReader.Create(Body);
    try
      try
        N := R.Count(8);
        for I := 0 to N - 1 do PutItem(ReadPlaylist(R));
        FGeneration := Gen;
      except
        on E: Exception do
        begin
          ClearItems;
          Err := E.Message;
        end;
      end;
    finally
      R.Free;
    end;
  end;
  if Err <> '' then
  begin
    FLoadFailed := True;
    AddLog(SafeFormat(FMT_LOG_PLAYLISTS_LOAD_FAILED, [Err]), False, True);
    if BackupFileWithTimestamp(FFile, BackupPath) then
    begin
      AddLog(SafeFormat(FMT_LOG_PLAYLISTS_BACKUP, [BackupPath]), False, True);
      BackupFileWithTimestamp(FJournal.FileName, BackupPath);
      FLoadFailed := False;
    end;
  end;
  if not FLoadFailed then
  begin
    Payloads := TList.Create;
    try
      if FJournal.Replay(FGeneration, Payloads) > 0 then
      begin
        for I := 0 to Payloads.Count - 1 do
          try
            ApplyJournalRecord(PDbPayload(Payloads[I])^.Data);
          except
            // a damaged record (its CRC was right): skipped
          end;
        FDirty := True;
      end;
    finally
      FreePayloads(Payloads);
      Payloads.Free;
    end;
  end;
  EnsureDefault;
end;

procedure TPlaylistStore.Save;
var
  W: TDbWriter;
  I: Integer;
  Err: string;
begin
  if FLoadFailed and FileExists(FFile) then Exit;
  W := TDbWriter.Create;
  try
    W.U32(FItems.Count);
    for I := 0 to FItems.Count - 1 do WritePlaylist(W, Item(I)^);
    if SaveSnapshot(FFile, PL_MAGIC, FGeneration + 1, W.Bytes, Err) then
    begin
      Inc(FGeneration);
      FJournal.Reset(FGeneration);
      FDirty := False;
    end
    else
      AddLog(SafeFormat(FMT_LOG_PLAYLISTS_SAVE_FAILED, [Err]), False, True);
  finally
    W.Free;
  end;
end;

{ ---- changes ---- }

function TPlaylistStore.Add(const AName: string; AKind: TPlaylistKind): PStoredPlaylist;
var
  N: string;
begin
  Result := nil;
  N := CleanPlaylistName(AName);
  if (N = '') or (IndexOf(N) >= 0) then Exit;
  New(Result);
  Result^ := Default(TStoredPlaylist);
  Result^.Name := N;
  Result^.Kind := AKind;
  Result^.GroupMode := -1;
  Result^.Modified := Now;
  FItems.Add(Result);
  FDirty := True;
  JournalPut(Result);
end;

function TPlaylistStore.Rename(const AOldName, ANewName: string): Boolean;
var
  P: PStoredPlaylist;
  N, Old: string;
  J: Integer;
begin
  Result := False;
  N := CleanPlaylistName(ANewName);
  P := Find(AOldName);
  if (P = nil) or (N = '') or IsDefault(AOldName) or IsDefault(N) then Exit;
  J := IndexOf(N);
  if (J >= 0) and (Item(J) <> P) then Exit;
  Old := P^.Name;
  P^.Name := N;
  P^.Modified := Now;
  FDirty := True;
  JournalDelete(Old);
  JournalPut(P);
  Result := True;
end;

function TPlaylistStore.Delete(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if IsDefault(AName) then Exit;
  I := IndexOf(AName);
  if I < 0 then Exit;
  Dispose(Item(I));
  FItems.Delete(I);
  FDirty := True;
  JournalDelete(AName);
  Result := True;
end;

procedure TPlaylistStore.Changed(P: PStoredPlaylist);
begin
  if P = nil then Exit;
  P^.Modified := Now;
  FDirty := True;
  JournalPut(P);
end;

procedure TPlaylistStore.SetEntries(P: PStoredPlaylist; const AEntries: TPlaylistEntries);
begin
  if P = nil then Exit;
  P^.Entries := Copy(AEntries);
  Changed(P);
end;

function TPlaylistStore.UniqueName(const AName: string): string;
var
  Base: string;
  K: Integer;
begin
  Base := CleanPlaylistName(AName);
  if Base = '' then Base := 'Playlist';
  Result := Base;
  K := 2;
  while IndexOf(Result) >= 0 do
  begin
    Result := Format('%s (%d)', [Base, K]);
    Inc(K);
  end;
end;

procedure TPlaylistStore.GetNames(AList: TStrings);
var
  Normal, Auto: TStringList;
  I: Integer;
  P: PStoredPlaylist;
begin
  AList.Clear;
  AList.AddObject(FDefaultName, TObject(PtrInt(Ord(pkNormal))));
  Normal := TStringList.Create;
  Auto := TStringList.Create;
  try
    Normal.CaseSensitive := False;
    Auto.CaseSensitive := False;
    for I := 0 to FItems.Count - 1 do
    begin
      P := Item(I);
      if IsDefault(P^.Name) then Continue;
      if P^.Kind = pkAuto then Auto.Add(P^.Name) else Normal.Add(P^.Name);
    end;
    Normal.Sort;
    Auto.Sort;
    for I := 0 to Normal.Count - 1 do AList.AddObject(Normal[I], TObject(PtrInt(Ord(pkNormal))));
    for I := 0 to Auto.Count - 1 do AList.AddObject(Auto[I], TObject(PtrInt(Ord(pkAuto))));
  finally
    Normal.Free;
    Auto.Free;
  end;
end;

end.
