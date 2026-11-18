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
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uMetadataPayloads;

type
  TTestMetadataCustodian = class(TTestCase)
  private
    FDir: string;
    procedure WriteTags(const APath: string; const AOrig, ACur: TAudioTagValues);
    procedure RunJob(Job: PMetadataJob);
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
  end;

implementation

uses
  Forms, ALMetadata, AuLog, uMetadataCustodian, AudioTag, baseTag, file_dff, TestHelpers;

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
procedure TTestMetadataCustodian.RunJob(Job: PMetadataJob);
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
  if Failed then
  begin
    for I := LogStart to AppLog.Lines.Count - 1 do
      if Pos('[Metadata]', AppLog.Lines[I]) > 0 then WriteLn(ErrOutput, AppLog.Lines[I]);
    Fail('The file was not updated (the log above says why)');
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
