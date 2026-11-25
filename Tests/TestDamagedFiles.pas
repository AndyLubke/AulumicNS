unit TestDamagedFiles;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestDamagedFiles
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Damaged files of every format the program plays: a good, tagged file is
  cut short or has some of its bytes changed, a few hundred different ways
  (the same ones at every run), and each damaged file goes through what the
  program does with a file - its tags are read and a changed title is saved,
  the library reads its properties, the engine opens, reads and seeks it.

  A damaged file may be refused, and the engine may say so with an exception
  of its own. What must never happen: an access violation, a range or
  overflow error, a division by zero, an invalid pointer, running out of
  memory over a size read from the file - and the tag library must never
  raise at all. The test program counts memory blocks: none may be left.

  The damaged files exist in memory only. The readers open every file
  through AuAudioTypes.AuOpenFile, and this test answers for the names that
  start with "mem:\" - so no damaged file is ever written to a disk, where a
  virus scanner would take a randomly damaged media file for an attack on a
  player and raise an alarm. The good files are made on the disk as usual
  and read into memory once. Before any damage is done, each good file goes
  through the same steps from memory and must give its title and its sound:
  that is the proof that the steps really read the file in memory.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestDamagedFiles = class(TTestCase)
  private
    FDir: string;
    FProblems: TStringList;
    procedure Tag(const AFile, AID, AID3: string);
    procedure Exercise(const AFile, AWhat: string);
    procedure CheckGood(const AGood: TBytes; const AExt: string);
    procedure Damage(const AGood: TBytes; const AExt: string; ARounds: Integer);
    procedure Report(const AFormat: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DamagedM4aFiles;
    procedure DamagedAiffFiles;
    procedure DamagedWavFiles;
    procedure DamagedFlacFiles;
    procedure DamagedDsfFiles;
    procedure DamagedDffFiles;
  end;

implementation

uses
  base64, AuAudioTypes, ALAudioTypes, ALReaders, ALSourceFactory, ALMetadata, AudioTag, baseTag, tag_id3v2,
  tag_vorbis, TestHelpers;

{$I AlacFixtures.inc}

const
  ROUNDS = 1000;
  MEM = 'mem:\';            // the names of the files that live in memory

var
  Seed: Cardinal;

{ ---- files in memory ---- }

type
  TMemFile = class
    Data: TBytes;
  end;

  // A file being written: its bytes go into the list when it is closed
  TMemOutStream = class(TMemoryStream)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

var
  MemFiles: TStringList = nil;

function IsMemName(const AName: string): Boolean;
begin
  Result := (MemFiles <> nil) and (Pos(MEM, AName) = 1);
end;

procedure PutMemFile(const AName: string; const AData: TBytes);
var
  I: Integer;
  F: TMemFile;
begin
  I := MemFiles.IndexOf(AName);
  if I < 0 then
  begin
    F := TMemFile.Create;
    MemFiles.AddObject(AName, F);
  end
  else
    F := TMemFile(MemFiles.Objects[I]);
  F.Data := Copy(AData, 0, Length(AData));
end;

function GetMemFile(const AName: string): TBytes;
var
  I: Integer;
begin
  I := MemFiles.IndexOf(AName);
  if I < 0 then Result := nil else Result := TMemFile(MemFiles.Objects[I]).Data;
end;

constructor TMemOutStream.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

destructor TMemOutStream.Destroy;
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, Size);
  if Size > 0 then
    Move(Memory^, B[0], Size);
  if MemFiles <> nil then
    PutMemFile(FName, B);
  inherited Destroy;
end;

function MemOpen(const AFileName: string; AMode: Word; out AStream: TStream): Boolean;
var
  I: Integer;
  M: TMemoryStream;
begin
  AStream := nil;
  Result  := IsMemName(AFileName);
  if not Result then
    Exit;
  if (AMode and fmCreate) = fmCreate then
  begin
    AStream := TMemOutStream.Create(AFileName);
    Exit;
  end;
  I := MemFiles.IndexOf(AFileName);
  if I < 0 then
    raise EFOpenError.CreateFmt('Unable to open file "%s"', [AFileName]);
  M := TMemoryStream.Create;
  if Length(TMemFile(MemFiles.Objects[I]).Data) > 0 then
    M.WriteBuffer(TMemFile(MemFiles.Objects[I]).Data[0], Length(TMemFile(MemFiles.Objects[I]).Data));
  M.Position := 0;
  AStream := M;
end;

function MemExists(const AFileName: string; out AExists: Boolean): Boolean;
begin
  Result  := IsMemName(AFileName);
  AExists := Result and (MemFiles.IndexOf(AFileName) >= 0);
end;

function MemDelete(const AFileName: string): Boolean;
var
  I: Integer;
begin
  Result := IsMemName(AFileName);
  if not Result then
    Exit;
  I := MemFiles.IndexOf(AFileName);
  if I >= 0 then
  begin
    MemFiles.Objects[I].Free;
    MemFiles.Delete(I);
  end;
end;

// The same numbers at every run
function Next(ARange: Integer): Integer;
begin
  {$push}{$Q-}{$R-}
  Seed := Seed * 1664525 + 1013904223;
  {$pop}
  if ARange <= 0 then
    Result := 0
  else
    Result := Integer((Seed shr 8) mod Cardinal(ARange));
end;

function Min(A, B: Integer): Integer;
begin
  if A < B then Result := A else Result := B;
end;

// An exception that says the code went wrong, not the file
function IsFault(E: Exception): Boolean;
begin
  Result := (E is EAccessViolation) or (E is ERangeError) or (E is EIntOverflow) or (E is EDivByZero) or
            (E is EInvalidPointer) or (E is EOutOfMemory) or (E is EInvalidCast) or (E is EZeroDivide) or
            (E is EOverflow) or (E is EInvalidOp);
end;

procedure TTestDamagedFiles.SetUp;
begin
  FDir := CreateTestDir;
  FProblems := TStringList.Create;
  Seed := 20261125;
  MemFiles := TStringList.Create;
  MemFiles.CaseSensitive := False;
  AuOpenFileHook   := @MemOpen;
  AuFileExistsHook := @MemExists;
  AuDeleteFileHook := @MemDelete;
end;

procedure TTestDamagedFiles.TearDown;
var
  I: Integer;
begin
  AuOpenFileHook   := nil;
  AuFileExistsHook := nil;
  AuDeleteFileHook := nil;
  for I := 0 to MemFiles.Count - 1 do
    MemFiles.Objects[I].Free;
  FreeAndNil(MemFiles);
  FProblems.Free;
  RemoveTestDir(FDir);
end;

// Gives a good file a title (and an M4A file a picture) through the tag library
procedure TTestDamagedFiles.Tag(const AFile, AID, AID3: string);
var
  R: TTagReader;
  Pic: TImageElement;
  Data: AnsiString;
begin
  R := GetFileTagsObject(AFile);
  try
    AssertFalse('The good file is read', R.LoadFailed);
    if R.Tags is TID3Tags then
      R.Tags.SetFrameValue(AID3, 'A title', TID3Frame)
    else
    begin
      R.Tags.SetFrameValue(AID, 'A title', TVorbisFrame);
      R.Tags.SetFrameValue('ARTIST', 'An artist', TVorbisFrame);
      if LowerCase(ExtractFileExt(AFile)) = '.m4a' then
      begin
        Data := #$FF#$D8#$FF#$E0 + StringOfChar(#5, 600);
        Pic := TImageElement.Create;
        Pic.MIMEType := 'image/jpeg';
        Pic.PictureType := 3;
        Pic.Image.WriteBuffer(Data[1], Length(Data));
        Pic.Image.Position := 0;
        R.Tags.AddImage(Pic);
      end;
    end;
    AssertTrue('The good file is saved', R.UpdateFile);
  finally
    R.Free;
  end;
end;

// Everything the program does with a file; what goes wrong is noted with AWhat
procedure TTestDamagedFiles.Exercise(const AFile, AWhat: string);
var
  R: TTagReader;
  M: TAudioMetadata;
  S: TAudioSource;
  C: TPlayThreadConfig;
  InRate, OutRate, I: Integer;
  Buf: array[0..16383] of Byte;

  // where it was raised: the first frames of the call stack
  procedure Note(const AStep: string; E: Exception);
  var
    Where: string;
    K: Integer;
  begin
    if FProblems.Count >= 12 then
      Exit;
    Where := Trim(BackTraceStrFunc(ExceptAddr));
    for K := 0 to ExceptFrameCount - 1 do
      if K < 3 then
        Where := Where + ' < ' + Trim(BackTraceStrFunc(ExceptFrames[K]));
    FProblems.Add(Format('%s, %s: %s "%s" at %s', [AWhat, AStep, E.ClassName, E.Message, Where]));
  end;

begin
  // the tag library: read, change, save - it answers, it never raises
  try
    R := GetFileTagsObject(AFile);
    try
      if Assigned(R) and (not R.LoadFailed) and Assigned(R.Tags) then
      begin
        for I := 0 to R.Tags.Count - 1 do
          if Assigned(R.Tags.Frames[I]) then
            R.Tags.Frames[I].AsString;
        if R.Tags is TID3Tags then
          R.Tags.SetFrameValue('TIT2', 'Another title', TID3Frame)
        else if R.Tags is TVorbisTags then
          R.Tags.SetFrameValue('TITLE', 'Another title', TVorbisFrame);
        // the new file is written beside it, in memory as well
        R.SaveToFile(MEM + 'saved' + ExtractFileExt(AFile));
      end;
    finally
      R.Free;
    end;
  except
    on E: Exception do
      Note('tags', E);
  end;

  // the library's view of the file
  try
    M := ReadTrackMetadata(AFile, False);
    if M.Title = #0 then ;
  except
    on E: Exception do
      Note('metadata', E);
  end;

  // the engine: it may refuse a file with an exception of its own
  S := nil;
  try
    try
      C := Default(TPlayThreadConfig);
      S := CreateSourceFor(C, 0, nil, AFile, InRate, OutRate);
      if Assigned(S) then
      begin
        for I := 1 to 8 do
          if S.ReadData(@Buf[0], SizeOf(Buf)) <= 0 then
            Break;
        S.Seek(0.5);
        S.ReadData(@Buf[0], SizeOf(Buf));
        S.Seek(0.999);
        S.ReadData(@Buf[0], SizeOf(Buf));
        S.GetDuration;
        S.GetProgress;
      end;
    except
      on E: Exception do
        if IsFault(E) then
          Note('engine', E);
    end;
  finally
    S.Free;
  end;
end;

// The good file, from memory, through the same steps: its title is read and
// a new one is saved and read back, the library has its title, the engine
// reads its sound. So the steps really work on the file in memory.
procedure TTestDamagedFiles.CheckGood(const AGood: TBytes; const AExt: string);
var
  F, Saved, Title: string;
  R: TTagReader;
  M: TAudioMetadata;
  S: TAudioSource;
  C: TPlayThreadConfig;
  InRate, OutRate, Got: Integer;
  Buf: array[0..4095] of Byte;
  HasTitle: Boolean;
begin
  F     := MEM + 'good' + AExt;
  Saved := MEM + 'goodsaved' + AExt;
  PutMemFile(F, AGood);
  AssertTrue('The file is found in memory', AuFileExists(F));
  AssertFalse('And no such file is on a disk', FileExists(F));

  R := GetFileTagsObject(F);
  try
    AssertFalse(AExt + ': the tags are read from memory', R.LoadFailed);
    if R.Tags is TID3Tags then Title := R.Tags.GetFrameValue('TIT2') else Title := R.Tags.GetFrameValue('TITLE');
    HasTitle := Title <> '';
    if HasTitle then
      AssertEquals(AExt + ': the title', 'A title', Title);
    if R.Tags is TID3Tags then
      R.Tags.SetFrameValue('TIT2', 'Another title', TID3Frame)
    else
      R.Tags.SetFrameValue('TITLE', 'Another title', TVorbisFrame);
    AssertTrue(AExt + ': saved into memory', R.SaveToFile(Saved));
  finally
    R.Free;
  end;
  AssertTrue('The saved file is in memory', Length(GetMemFile(Saved)) > 0);
  R := GetFileTagsObject(Saved);
  try
    if R.Tags is TID3Tags then Title := R.Tags.GetFrameValue('TIT2') else Title := R.Tags.GetFrameValue('TITLE');
    AssertEquals(AExt + ': the saved title reads back', 'Another title', Title);
  finally
    R.Free;
  end;

  M := ReadTrackMetadata(F, False);
  AssertTrue(AExt + ': the library reads it from memory', M.ReadOk and (M.SampleRate > 0));
  if HasTitle then
    AssertEquals(AExt + ': the library has the title', 'A title', M.Title);

  C := Default(TPlayThreadConfig);
  S := CreateSourceFor(C, 0, nil, F, InRate, OutRate);
  try
    AssertTrue(AExt + ': the engine opens it from memory', Assigned(S));
    Got := S.ReadData(@Buf[0], SizeOf(Buf));
    AssertTrue(AExt + ': and reads its sound', Got > 0);
  finally
    S.Free;
  end;
end;

// ARounds damaged copies of AGood, each through Exercise
procedure TTestDamagedFiles.Damage(const AGood: TBytes; const AExt: string; ARounds: Integer);
var
  Round, Kind, Pos, N, I, Len: Integer;
  Bad: TBytes;
  F, What: string;

  // most damage near the start and the end, where the descriptions are
  function Where: Integer;
  begin
    case Next(4) of
      0, 1: Result := Next(Min(Length(AGood), 1024));
      2:    Result := Length(AGood) - 1 - Next(Min(Length(AGood), 2048));
    else
      Result := Next(Length(AGood));
    end;
    if Result < 0 then Result := 0;
    if Result >= Length(AGood) then Result := Length(AGood) - 1;
  end;

begin
  CheckGood(AGood, AExt);
  F := MEM + 'bad' + AExt;
  for Round := 1 to ARounds do
  begin
    Bad := Copy(AGood, 0, Length(AGood));
    Kind := Next(5);
    Pos  := Where;
    case Kind of
      0: begin                               // cut short
           Len := Next(Length(AGood));
           SetLength(Bad, Len);
           What := Format('cut to %d bytes', [Len]);
         end;
      1: begin                               // some bytes changed
           N := 1 + Next(8);
           for I := 1 to N do
             Bad[Where] := Byte(Next(256));
           What := Format('%d bytes changed', [N]);
         end;
      2: begin                               // a size that says "everything"
           for I := 0 to 3 do
             if Pos + I < Length(Bad) then Bad[Pos + I] := $FF;
           What := Format('FF FF FF FF at %d', [Pos]);
         end;
      3: begin                               // a size that says "nothing"
           for I := 0 to 3 do
             if Pos + I < Length(Bad) then Bad[Pos + I] := 0;
           What := Format('00 00 00 00 at %d', [Pos]);
         end;
    else
      begin                                  // a piece taken out
        N := 1 + Next(64);
        if Pos + N < Length(Bad) then
        begin
          Move(Bad[Pos + N], Bad[Pos], Length(Bad) - Pos - N);
          SetLength(Bad, Length(Bad) - N);
        end;
        What := Format('%d bytes taken out at %d', [N, Pos]);
      end;
    end;
    What := Format('round %d (%s)', [Round, What]);
    PutMemFile(F, Bad);
    Exercise(F, What);
  end;
end;

procedure TTestDamagedFiles.Report(const AFormat: string);
begin
  if FProblems.Count > 0 then
    Fail(AFormat + ': ' + IntToStr(FProblems.Count) + ' faults, the first ones:' + LineEnding + FProblems.Text);
end;

function FromString(const S: AnsiString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

procedure TTestDamagedFiles.DamagedM4aFiles;
var
  F: string;
begin
  // a compressed file of another encoder, with tags and a picture
  F := FDir + 'good.m4a';
  WriteFileBytes(F, FromString(DecodeStringBase64(ALAC_FIX16_B64)));
  Tag(F, 'TITLE', '');
  Damage(ReadFileBytes(F), '.m4a', ROUNDS);
  // and as that encoder wrote it (its description behind the sound, no tags)
  Damage(FromString(DecodeStringBase64(ALAC_FIX24_B64)), '.m4a', ROUNDS);
  Report('M4A');
end;

procedure TTestDamagedFiles.DamagedAiffFiles;
var
  F: string;
  S, Snd: AnsiString;
  I: Integer;
begin
  // FORM AIFF: a description, the sound, then the tag the library adds
  Snd := '';
  SetLength(Snd, 8000);
  for I := 1 to Length(Snd) do
    Snd[I] := AnsiChar((I * 31) and $FF);
  S := 'AIFF' +
    'COMM' + #0#0#0#18 + #0#2 + #0#0#$07#$D0 + #0#16 + #$40#$0E#$AC#$44#0#0#0#0#0#0 +
    'SSND' + #0#0#$1F#$48 + #0#0#0#0 + #0#0#0#0 + Snd;
  S := 'FORM' + AnsiChar(Length(S) shr 24) + AnsiChar((Length(S) shr 16) and $FF) +
       AnsiChar((Length(S) shr 8) and $FF) + AnsiChar(Length(S) and $FF) + S;
  F := FDir + 'good.aiff';
  WriteFileBytes(F, FromString(S));
  Tag(F, '', 'TIT2');
  Damage(ReadFileBytes(F), '.aiff', ROUNDS);
  Report('AIFF');
end;

procedure TTestDamagedFiles.DamagedWavFiles;
var
  F: string;
begin
  F := FDir + 'good.wav';
  WritePatternWav(F, 3000);
  Tag(F, '', 'TIT2');
  Damage(ReadFileBytes(F), '.wav', ROUNDS);
  Report('WAV');
end;

procedure TTestDamagedFiles.DamagedFlacFiles;
var
  F: string;
begin
  F := FDir + 'good.flac';
  WritePatternFlac(F, 9000);
  Tag(F, 'TITLE', '');
  Damage(ReadFileBytes(F), '.flac', ROUNDS);
  Report('FLAC');
end;

procedure TTestDamagedFiles.DamagedDsfFiles;
var
  F: string;
begin
  F := FDir + 'good.dsf';
  WriteTestDsf(F, 3 * 4096, dpSquare);
  Tag(F, '', 'TIT2');
  Damage(ReadFileBytes(F), '.dsf', ROUNDS);
  Report('DSF');
end;

procedure TTestDamagedFiles.DamagedDffFiles;
var
  F: string;
begin
  F := FDir + 'good.dff';
  WriteTestDff(F, 3 * 4096, dpSquare);
  Tag(F, '', 'TIT2');
  Damage(ReadFileBytes(F), '.dff', ROUNDS);
  Report('DFF');
end;

initialization
  RegisterTest(TTestDamagedFiles);

end.
