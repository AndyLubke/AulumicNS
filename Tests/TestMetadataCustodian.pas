unit TestMetadataCustodian;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestMetadataCustodian
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The metadata custodian writes the tags of the Properties dialog
  (uMetadataCustodian, on its own thread): WAV (ID3 in an 'id3 ' chunk), FLAC
  (Vorbis comments, several values as separate fields), DSF (ID3 at the end)
  and DFF (an 'ID3 ' chunk). Each test checks that the
  changed fields are in the file afterwards, that the unchanged ones stay as
  they were and that the audio data is byte for byte the same.
  The custodian shows a dialog when a file could not be written; a console
  test must not wait for it, so the tests set Application.Terminated (only
  the custodian looks at it).
  A damaged ID3 tag: a normal job leaves the file alone, a job with RepairTag
  writes the fields in front of and behind the damage and keeps a copy of
  the old tag; a job with RestoreTagFrom puts that copy back, and the file is
  byte for byte what it was before the repair.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uMetadataPayloads;

type
  TTestMetadataCustodian = class(TTestCase)
  private
    FDir: string;
    procedure WriteTags(const APath: string; const AOrig, ACur: TAudioTagValues);
    // AMayFail: a refused file is no failure of the test; True = written
    function RunJob(Job: PMetadataJob; AMayFail: Boolean = False): Boolean;
    function TagsOf(const APath: string): TAudioTagValues;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure WavChangedFieldsAreWritten;
    procedure WavUnchangedFieldsStay;
    procedure FlacTagsAreWrittenWithSeveralArtists;
    procedure DsfTagsAreWritten;
    procedure DffTagsAreWritten;
    procedure DffTagIsReplacedNotAdded;
    procedure ReplayGainTagsAreWritten;
    procedure TrackOnlyReplayGainRemovesTheAlbumValues;
    procedure DamagedTagIsRepairedWithACopy;
    procedure RepairIsUndone;
  end;

implementation

uses
  Forms, ALMetadata, AuLog, uMetadataCustodian, uAppConsts, AudioTag, baseTag, file_dff, TestHelpers;

{ ---- the audio bytes of the test files ---- }

function ReadAll(const APath: string): TBytes;
begin
  Result := ReadFileBytes(APath);
end;

function U32LE(const B: TBytes; P: Integer): Int64;
begin
  Result := Int64(B[P]) or (Int64(B[P + 1]) shl 8) or (Int64(B[P + 2]) shl 16) or (Int64(B[P + 3]) shl 24);
end;

function U64BE(const B: TBytes; P: Integer): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 7 do Result := (Result shl 8) or B[P + I];
end;

function IdAt(const B: TBytes; P: Integer): string;
begin
  SetString(Result, PAnsiChar(@B[P]), 4);
end;

{ the payload of the WAV 'data' chunk }
function WavAudio(const APath: string): TBytes;
var
  B: TBytes;
  P: Integer;
  Size: Int64;
begin
  Result := nil;
  B := ReadAll(APath);
  P := 12;
  while P + 8 <= Length(B) do
  begin
    Size := U32LE(B, P + 4);
    if IdAt(B, P) = 'data' then Exit(Copy(B, P + 8, Size));
    P := P + 8 + Size + (Size and 1);
  end;
end;

{ everything after the FLAC metadata blocks (the frames) }
function FlacAudio(const APath: string): TBytes;
var
  B: TBytes;
  P: Integer;
  Last: Boolean;
  Len: Integer;
begin
  B := ReadAll(APath);
  P := 4;
  repeat
    Last := (B[P] and $80) <> 0;
    Len := (B[P + 1] shl 16) or (B[P + 2] shl 8) or B[P + 3];
    P := P + 4 + Len;
  until Last or (P >= Length(B));
  Result := Copy(B, P, Length(B) - P);
end;

{ the payload of the DSF 'data' chunk }
function DsfAudio(const APath: string): TBytes;
var
  B: TBytes;
  P: Integer;
begin
  Result := nil;
  B := ReadAll(APath);
  P := 28 + 52;                         // 'DSD ' and 'fmt ' chunks
  if IdAt(B, P) <> 'data' then Exit;
  Result := Copy(B, P + 12, U32LE(B, P + 4) - 12);
end;

{ the payload of a chunk inside the DFF container; ACount = how many there are }
function DffChunk(const APath, AId: string; out ACount: Integer): TBytes;
var
  B: TBytes;
  P: Integer;
  Size, FormEnd: Int64;
begin
  Result := nil;
  ACount := 0;
  B := ReadAll(APath);
  FormEnd := 12 + U64BE(B, 4);
  P := 16;
  while P + 12 <= Length(B) do
  begin
    Size := U64BE(B, P + 4);
    if IdAt(B, P) = AId then
    begin
      Inc(ACount);
      Result := Copy(B, P + 12, Size);
    end;
    P := P + 12 + Size + (Size and 1);
    if P > FormEnd + 4096 then Break;
  end;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

{ ---- TTestMetadataCustodian ---- }

procedure TTestMetadataCustodian.SetUp;
begin
  FDir := CreateTestDir;
  { no "Tags Not Saved" dialog in a console test }
  Application.Terminate;
end;

procedure TTestMetadataCustodian.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestMetadataCustodian.TagsOf(const APath: string): TAudioTagValues;
var
  M: TAudioMetadata;
begin
  M := ReadTrackMetadata(APath, False, False, True);
  Result := Default(TAudioTagValues);
  Result.Title := M.Title;
  Result.Artist := M.Artist;
  Result.AlbumArtist := M.AlbumArtist;
  Result.Album := M.Album;
  Result.Genre := M.Genre;
  Result.Composer := M.Composer;
  Result.Performer := M.Performer;
  Result.Comment := M.Comment;
  Result.Track := M.TrackNumber;
  Result.Disc := M.DiscNumber;
  Result.DateStr := M.DateStr;
end;

{ one tag editor job, done when the custodian logs the end of the batch }
procedure TTestMetadataCustodian.WriteTags(const APath: string; const AOrig, ACur: TAudioTagValues);
var
  Job: PMetadataJob;
begin
  New(Job);
  Job^ := Default(TMetadataJob);
  Job^.FilePath := APath;
  Job^.AlbumName := ACur.Album;
  Job^.ActionType := matTagEditor;
  Job^.TagEditor.Original := AOrig;
  Job^.TagEditor.Current := ACur;
  Job^.TagEditor.IsModified := True;
  RunJob(Job);
end;

{ the custodian takes the job over }
function TTestMetadataCustodian.RunJob(Job: PMetadataJob; AMayFail: Boolean): Boolean;
var
  C: TMetadataCustodian;
  L: TList;
  Start: QWord;
  LogStart, I: Integer;
  Done, Failed: Boolean;
begin
  LogStart := AppLog.Lines.Count;
  C := TMetadataCustodian.Create(nil, nil);
  try
    L := TList.Create;
    try
      L.Add(Job);
      C.EnqueueBatch(L);
    finally
      L.Free;
    end;
    Start := GetTickCount64;
    Done := False;
    Failed := False;
    repeat
      CheckSynchronize(20);
      for I := LogStart to AppLog.Lines.Count - 1 do
      begin
        if Pos('[Metadata] Batch finished', AppLog.Lines[I]) > 0 then Done := True;
        if Pos('could not be updated', AppLog.Lines[I]) > 0 then Failed := True;
        if Pos('was not updated', AppLog.Lines[I]) > 0 then Failed := True;
      end;
      if GetTickCount64 - Start > 15000 then Fail('The custodian did not finish within 15 s');
    until Done;
  finally
    C.StrangleAndStop;
    C.Free;
  end;
  Result := not Failed;
  if Failed and not AMayFail then
  begin
    for I := LogStart to AppLog.Lines.Count - 1 do
      if Pos('[Metadata]', AppLog.Lines[I]) > 0 then WriteLn(ErrOutput, AppLog.Lines[I]);
    Fail('The file was not updated (the log above says why)');
  end;
end;

{ an ID3v2.3 text frame (Latin-1) }
function TextFrame(const AID, AText: AnsiString): AnsiString;
var
  N: Integer;
begin
  N := Length(AText) + 1;
  Result := AID + AnsiChar(N shr 24) + AnsiChar((N shr 16) and $FF) + AnsiChar((N shr 8) and $FF) +
    AnsiChar(N and $FF) + #0#0 + #0 + AText;
end;

{ A WAV file with an ID3v2.3 tag at its end: a title, damaged bytes, then
  album and artist. The result is the tag. }
function WriteDamagedWav(const P: string): AnsiString;
const
  GARBAGE = #1#2#3#4#5#6#7#8#9#10#11#12;
var
  Tag, Chunk: AnsiString;
  B: TBytes;
  N: Integer;
begin
  WriteTestWav(P);
  Tag := TextFrame('TIT2', 'Old Title') + GARBAGE + TextFrame('TALB', 'The Album') +
    TextFrame('TPE1', 'The Artist') + StringOfChar(#0, 40);
  N := Length(Tag);
  Tag := 'ID3'#3#0#0 + AnsiChar((N shr 21) and $7F) + AnsiChar((N shr 14) and $7F) +
    AnsiChar((N shr 7) and $7F) + AnsiChar(N and $7F) + Tag;
  N := Length(Tag);
  Chunk := 'id3 ' + AnsiChar(N and $FF) + AnsiChar((N shr 8) and $FF) + AnsiChar((N shr 16) and $FF) +
    AnsiChar(N shr 24) + Tag;
  if Odd(N) then Chunk := Chunk + #0;
  B := ReadAll(P);
  N := Length(B);
  SetLength(B, N + Length(Chunk));
  Move(Chunk[1], B[N], Length(Chunk));
  N := Length(B) - 8;
  B[4] := N and $FF; B[5] := (N shr 8) and $FF; B[6] := (N shr 16) and $FF; B[7] := N shr 24;
  WriteFileBytes(P, B);
  Result := Tag;
end;

procedure TTestMetadataCustodian.RepairIsUndone;
var
  P, OldDir, Copy1, Found, FoundWhen: string;
  Before: TBytes;
  M: TAudioMetadata;
  Job: PMetadataJob;

  function NewJob: PMetadataJob;
  begin
    New(Result);
    Result^ := Default(TMetadataJob);
    Result^.FilePath := P;
    Result^.ActionType := matTagEditor;
  end;

begin
  P := FDir + 'track.wav';
  WriteDamagedWav(P);
  Before := ReadAll(P);
  OldDir := AppTagBackupDir;
  AppTagBackupDir := FDir + 'TagBackups' + PathDelim;
  try
    AssertEquals('No copy yet', '', FindTagBackup(P, AppTagBackupDir, FoundWhen));
    // the repair (no field changed)
    Job := NewJob;
    Job^.TagEditor.RepairTag := True;
    AssertTrue('Repaired', RunJob(Job));
    AssertFalse('Healthy now', ReadTrackMetadata(P, False, False, True).TagDamaged);
    Copy1 := FindTagBackup(P, AppTagBackupDir, FoundWhen);
    AssertTrue('The copy is found for the file', Copy1 <> '');
    AssertTrue('With the time it was made: ' + FoundWhen, Length(FoundWhen) = 19);
    AssertEquals('Not for another file', '', FindTagBackup(FDir + 'other.wav', AppTagBackupDir, FoundWhen));
    AssertEquals('The path in another case is the same file', Copy1,
      FindTagBackup(UpperCase(P), AppTagBackupDir, FoundWhen));

    // a tag edit in between: lost by the undo, as the question says
    M := ReadTrackMetadata(P, False, False, True);
    Job := NewJob;
    Job^.TagEditor.Original.Title := M.Title;
    Job^.TagEditor.Current.Title := 'Edited Later';
    Job^.TagEditor.IsModified := True;
    AssertTrue('Edited', RunJob(Job));
    AssertEquals('The edit', 'Edited Later', ReadTrackMetadata(P, False, False, True).Title);

    // the undo
    Job := NewJob;
    Job^.TagEditor.RestoreTagFrom := Copy1;
    AssertTrue('Put back', RunJob(Job));
    AssertTrue('The file is byte for byte what it was', SameBytes(Before, ReadAll(P)));
    M := ReadTrackMetadata(P, False, False, True);
    AssertTrue('With its damage', M.TagDamaged);
    AssertEquals('And its old title', 'Old Title', M.Title);
    AssertTrue('The copy is kept', FileExists(Copy1));

    // a copy that is no tag, and one that is gone: nothing is written
    Job := NewJob;
    Job^.TagEditor.RestoreTagFrom := P;           // a WAV file is no tag
    AssertFalse('A file that is no tag is refused', RunJob(Job, True));
    Job := NewJob;
    Job^.TagEditor.RestoreTagFrom := FDir + 'gone.id3';
    AssertFalse('A missing copy is refused', RunJob(Job, True));
    AssertTrue('The file is untouched', SameBytes(Before, ReadAll(P)));

    // repaired again: the newest copy is the one found
    Job := NewJob;
    Job^.TagEditor.RepairTag := True;
    AssertTrue('Repaired again', RunJob(Job));
    Found := FindTagBackup(P, AppTagBackupDir, FoundWhen);
    AssertTrue('A copy is found', Found <> '');
    DeleteFile(Found);
    Found := FindTagBackup(P, AppTagBackupDir, FoundWhen);
    AssertTrue('Without the newest the one before it (or none when both were made in the same second)',
      (Found = '') or FileExists(Found));
  finally
    AppTagBackupDir := OldDir;
  end;
end;

procedure TTestMetadataCustodian.DamagedTagIsRepairedWithACopy;
var
  P, OldDir, Index: string;
  Tag: AnsiString;
  B, Audio, Before: TBytes;
  M: TAudioMetadata;
  Orig, Cur: TAudioTagValues;
  Job: PMetadataJob;
  SR: TSearchRec;
  Copies: Integer;
  CopyName: string;
  SL: TStringList;
begin
  P := FDir + 'track.wav';
  Tag := WriteDamagedWav(P);
  Audio := WavAudio(P);
  Before := ReadAll(P);

  M := ReadTrackMetadata(P, False, False, True);
  AssertTrue('The damage is seen', M.TagDamaged);
  AssertEquals('The title in front of it', 'Old Title', M.Title);
  AssertEquals('Nothing from behind it', '', M.Album);
  M := ReadTrackMetadata(P, False, False, True, True);
  AssertEquals('A repairing read has the album', 'The Album', M.Album);
  AssertEquals('And the artist', 'The Artist', M.Artist);

  OldDir := AppTagBackupDir;
  AppTagBackupDir := FDir + 'TagBackups' + PathDelim;
  try
    // a normal job: refused, the file stays
    Orig := TagsOf(P);
    Cur := Orig;
    Cur.Title := 'New Title';
    New(Job);
    Job^ := Default(TMetadataJob);
    Job^.FilePath := P;
    Job^.ActionType := matTagEditor;
    Job^.TagEditor.Original := Orig;
    Job^.TagEditor.Current := Cur;
    Job^.TagEditor.IsModified := True;
    AssertFalse('A normal save is refused', RunJob(Job, True));
    AssertTrue('The file is as it was', SameBytes(Before, ReadAll(P)));
    AssertFalse('No copy was made', DirectoryExists(AppTagBackupDir));

    // the repair, with a changed title
    M := ReadTrackMetadata(P, False, False, True, True);
    Orig := Default(TAudioTagValues);
    Orig.Title := M.Title;
    Orig.Album := M.Album;
    Orig.Artist := M.Artist;
    Cur := Orig;
    Cur.Title := 'New Title';
    New(Job);
    Job^ := Default(TMetadataJob);
    Job^.FilePath := P;
    Job^.ActionType := matTagEditor;
    Job^.TagEditor.Original := Orig;
    Job^.TagEditor.Current := Cur;
    Job^.TagEditor.IsModified := True;
    Job^.TagEditor.RepairTag := True;
    AssertTrue('The repair is written', RunJob(Job));

    M := ReadTrackMetadata(P, False, False, True);
    AssertFalse('No damage any more', M.TagDamaged);
    AssertEquals('The new title', 'New Title', M.Title);
    AssertEquals('The album from behind the damage', 'The Album', M.Album);
    AssertEquals('The artist', 'The Artist', M.Artist);
    AssertTrue('The audio is unchanged', SameBytes(Audio, WavAudio(P)));

    // the copy of the old tag and its line in the list
    Copies := 0;
    CopyName := '';
    if FindFirst(AppTagBackupDir + '*.id3', faAnyFile, SR) = 0 then
    begin
      repeat
        Inc(Copies);
        CopyName := SR.Name;
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    AssertEquals('One copy', 1, Copies);
    AssertTrue('Named after the file: ' + CopyName, Pos('track.wav.', CopyName) = 1);
    B := ReadAll(AppTagBackupDir + CopyName);
    AssertEquals('The old tag, whole', Length(Tag), Length(B));
    AssertTrue('Byte for byte', CompareMem(@B[0], @Tag[1], Length(Tag)));
    SL := TStringList.Create;
    try
      SL.LoadFromFile(AppTagBackupDir + 'index.txt');
      Index := SL.Text;
    finally
      SL.Free;
    end;
    AssertTrue('The list names the copy', Pos(CopyName, Index) > 0);
    AssertTrue('And the file it belongs to', Pos(P, Index) > 0);

    // a job with RepairTag on a healthy file: a normal save, no copy more
    Orig := TagsOf(P);
    Cur := Orig;
    Cur.Title := 'Third Title';
    New(Job);
    Job^ := Default(TMetadataJob);
    Job^.FilePath := P;
    Job^.ActionType := matTagEditor;
    Job^.TagEditor.Original := Orig;
    Job^.TagEditor.Current := Cur;
    Job^.TagEditor.IsModified := True;
    Job^.TagEditor.RepairTag := True;
    AssertTrue('Written', RunJob(Job));
    AssertEquals('The title', 'Third Title', TagsOf(P).Title);
    Copies := 0;
    if FindFirst(AppTagBackupDir + '*.id3', faAnyFile, SR) = 0 then
    begin
      repeat
        Inc(Copies);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    AssertEquals('Still one copy', 1, Copies);
  finally
    AppTagBackupDir := OldDir;
  end;
end;

procedure TTestMetadataCustodian.WavChangedFieldsAreWritten;
var
  P: string;
  Orig, Cur, Got: TAudioTagValues;
  Audio: TBytes;
begin
  P := FDir + 'track.wav';
  WriteTestWav(P);
  AddWavId3Tag(P, ['TIT2', 'Old Title', 'TPE1', 'Old Artist', 'TALB', 'The Album']);
  Audio := WavAudio(P);
  Orig := TagsOf(P);
  AssertEquals('read back: title', 'Old Title', Orig.Title);
  Cur := Orig;
  Cur.Title := 'New Title';
  Cur.Artist := 'New Artist';
  Cur.Track := 7;
  Cur.Comment := 'Line one' + LineEnding + 'Line two';
  WriteTags(P, Orig, Cur);
  Got := TagsOf(P);
  AssertEquals('title', 'New Title', Got.Title);
  AssertEquals('artist', 'New Artist', Got.Artist);
  AssertEquals('album unchanged', 'The Album', Got.Album);
  AssertEquals('track', 7, Got.Track);
  AssertTrue('comment with both lines: ' + Got.Comment,
    (Pos('Line one', Got.Comment) > 0) and (Pos('Line two', Got.Comment) > 0));
  AssertTrue('audio unchanged', SameBytes(Audio, WavAudio(P)));
end;

procedure TTestMetadataCustodian.WavUnchangedFieldsStay;
var
  P: string;
  Orig, Cur, Got: TAudioTagValues;
begin
  P := FDir + 'track.wav';
  WriteTestWav(P);
  AddWavId3Tag(P, ['TIT2', 'Title', 'TPE1', 'Artist', 'TCON', 'Jazz', 'TRCK', '5/12']);
  Orig := TagsOf(P);
  Cur := Orig;
  Cur.Genre := 'Blues';
  WriteTags(P, Orig, Cur);
  Got := TagsOf(P);
  AssertEquals('genre', 'Blues', Got.Genre);
  AssertEquals('title', 'Title', Got.Title);
  AssertEquals('artist', 'Artist', Got.Artist);
  AssertEquals('track (the total stays in the file)', 5, Got.Track);
end;

procedure TTestMetadataCustodian.FlacTagsAreWrittenWithSeveralArtists;
var
  P: string;
  Orig, Cur, Got: TAudioTagValues;
  Audio: TBytes;
  R: TTagReader;
  I, N: Integer;
begin
  P := FDir + 'track.flac';
  WritePatternFlac(P, 4096);
  Audio := FlacAudio(P);
  Orig := TagsOf(P);
  Cur := Orig;
  Cur.Title := 'Flac Title';
  Cur.Artist := 'Artist A; Artist B';
  Cur.Album := 'Flac Album';
  WriteTags(P, Orig, Cur);
  Got := TagsOf(P);
  AssertEquals('title', 'Flac Title', Got.Title);
  AssertEquals('album', 'Flac Album', Got.Album);
  AssertTrue('both artists: ' + Got.Artist, (Pos('Artist A', Got.Artist) > 0) and (Pos('Artist B', Got.Artist) > 0));
  { two ARTIST fields, the Vorbis comment way }
  R := GetFileTagsObject(P);
  try
    N := 0;
    for I := 0 to R.Tags.Count - 1 do
      if SameText(R.Tags.Frames[I].ID, 'ARTIST') then Inc(N);
    AssertEquals('ARTIST fields', 2, N);
  finally
    R.Free;
  end;
  AssertTrue('audio frames unchanged', SameBytes(Audio, FlacAudio(P)));
end;

procedure TTestMetadataCustodian.DsfTagsAreWritten;
var
  P: string;
  Orig, Cur, Got: TAudioTagValues;
  Audio: TBytes;
begin
  P := FDir + 'track.dsf';
  WriteTestDsf(P, 8192);
  Audio := DsfAudio(P);
  Orig := TagsOf(P);
  Cur := Orig;
  Cur.Title := 'Dsf Title';
  Cur.AlbumArtist := 'Dsf Album Artist';
  WriteTags(P, Orig, Cur);
  Got := TagsOf(P);
  AssertEquals('title', 'Dsf Title', Got.Title);
  AssertEquals('album artist', 'Dsf Album Artist', Got.AlbumArtist);
  AssertTrue('DSD data unchanged', SameBytes(Audio, DsfAudio(P)));
end;

procedure TTestMetadataCustodian.DffTagsAreWritten;
var
  P: string;
  Orig, Cur, Got: TAudioTagValues;
  Audio, After: TBytes;
  N: Integer;
  R: TDffTagReader;
begin
  P := FDir + 'track.dff';
  WriteTestDff(P, 8192);
  Audio := DffChunk(P, 'DSD ', N);
  AssertEquals('one DSD chunk', 1, N);
  Orig := TagsOf(P);
  Cur := Orig;
  Cur.Title := 'Dff Title';
  Cur.Artist := 'Dff Artist';
  Cur.DateStr := '1977';
  WriteTags(P, Orig, Cur);
  Got := TagsOf(P);
  AssertEquals('title', 'Dff Title', Got.Title);
  AssertEquals('artist', 'Dff Artist', Got.Artist);
  AssertEquals('year', '1977', Got.DateStr);
  After := DffChunk(P, 'DSD ', N);
  AssertEquals('still one DSD chunk', 1, N);
  AssertTrue('DSD data unchanged', SameBytes(Audio, After));
  DffChunk(P, 'ID3 ', N);
  AssertEquals('one ID3 chunk', 1, N);
  { still a valid DSDIFF file with its format }
  R := TDffTagReader.Create;
  try
    AssertTrue('loads', R.LoadFromFile(P));
    AssertEquals('sample rate', 2822400, R.MediaProperty.Sampling);
    AssertEquals('channels', 2, R.MediaProperty.Channels);
  finally
    R.Free;
  end;
end;

procedure TTestMetadataCustodian.DffTagIsReplacedNotAdded;
var
  P: string;
  Orig, Cur, Got: TAudioTagValues;
  N: Integer;
begin
  P := FDir + 'track.dff';
  WriteTestDff(P, 4096);
  Orig := TagsOf(P);
  Cur := Orig;
  Cur.Title := 'First';
  WriteTags(P, Orig, Cur);
  Orig := TagsOf(P);
  Cur := Orig;
  Cur.Title := 'Second';
  WriteTags(P, Orig, Cur);
  Got := TagsOf(P);
  AssertEquals('title', 'Second', Got.Title);
  DffChunk(P, 'ID3 ', N);
  AssertEquals('one ID3 chunk after two saves', 1, N);
end;

procedure TTestMetadataCustodian.ReplayGainTagsAreWritten;
var
  P, Tags: string;
  Job: PMetadataJob;
  I: Integer;
begin
  for I := 0 to 1 do
  begin
    if I = 0 then
    begin
      P := FDir + 'rg.wav';
      WriteTestWav(P);
      AddWavId3Tag(P, ['TIT2', 'Title']);
    end
    else
    begin
      P := FDir + 'rg.flac';
      WritePatternFlac(P, 4096);
    end;
    New(Job);
    Job^ := Default(TMetadataJob);
    Job^.FilePath := P;
    Job^.ActionType := matReplayGain;
    Job^.ReplayGain.TrackGain := -6.2;
    Job^.ReplayGain.TrackPeak := 0.912345;
    Job^.ReplayGain.AlbumGain := -7.15;
    Job^.ReplayGain.AlbumPeak := 0.987654;
    RunJob(Job);
    Tags := UpperCase(ReadTrackMetadata(P, False, True).AllTags);
    AssertTrue(P + ': track gain in ' + Tags, Pos('-6.20 DB', Tags) > 0);
    AssertTrue(P + ': album gain', Pos('-7.15 DB', Tags) > 0);
    AssertTrue(P + ': track peak', Pos('0.912345', Tags) > 0);
    AssertTrue(P + ': album peak', Pos('0.987654', Tags) > 0);
  end;
end;

// A track without an album tag: the track gain and peak are
// written, the album gain and peak a former scan left are taken out
procedure TTestMetadataCustodian.TrackOnlyReplayGainRemovesTheAlbumValues;
var
  P, Tags: string;
  Job: PMetadataJob;
  I, Pass: Integer;
begin
  for I := 0 to 1 do
  begin
    if I = 0 then
    begin
      P := FDir + 'loose.wav';
      WriteTestWav(P);
      AddWavId3Tag(P, ['TIT2', 'Title']);
    end
    else
    begin
      P := FDir + 'loose.flac';
      WritePatternFlac(P, 4096);
    end;
    // first with album values, as an earlier scan wrote them; then track only
    for Pass := 0 to 1 do
    begin
      New(Job);
      Job^ := Default(TMetadataJob);
      Job^.FilePath := P;
      Job^.ActionType := matReplayGain;
      Job^.ReplayGain.TrackGain := -6.2 - Pass;
      Job^.ReplayGain.TrackPeak := 0.912345;
      Job^.ReplayGain.AlbumGain := -7.15;
      Job^.ReplayGain.AlbumPeak := 0.987654;
      Job^.ReplayGain.TrackOnly := Pass = 1;
      RunJob(Job);
    end;
    Tags := UpperCase(ReadTrackMetadata(P, False, True).AllTags);
    AssertTrue(P + ': the new track gain in ' + Tags, Pos('-7.20 DB', Tags) > 0);
    AssertTrue(P + ': track peak', Pos('0.912345', Tags) > 0);
    AssertEquals(P + ': no album gain', 0, Pos('REPLAYGAIN_ALBUM_GAIN', Tags));
    AssertEquals(P + ': no album peak', 0, Pos('REPLAYGAIN_ALBUM_PEAK', Tags));
    AssertEquals(P + ': the old album value is gone', 0, Pos('-7.15', Tags));
  end;
end;

initialization
  RegisterTest(TTestMetadataCustodian);

end.
