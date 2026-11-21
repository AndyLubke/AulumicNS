unit TestTagRoundTrip;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestTagRoundTrip
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  What a save with the tag library leaves of a file: one field is changed (the
  title), and everything else must still be there - the audio, the other parts
  of the file and every field that was not edited, byte for byte.

  The files are built here from their bytes (no decoder reads them), so each
  one holds exactly the case it tests: FLAC comments in another encoding than
  UTF-8 and with lower-case names, an ID3v2 tag with an empty frame in the
  middle, ID3v2.4 text frames with several values, an unsynchronised tag, a
  tag with damaged bytes behind its first frames (never saved: the frames
  behind the damage would be lost), a FLAC file with an ID3v2 tag in front, a
  file without a tag, and the DSF and DFF containers.

  The repairing read (GetFileTagsObject(F, False, True)): the frames behind
  damaged bytes are found and saved, frame sizes written in the wrong form
  are read, and the tag as it stood in the file is handed out for a copy.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestTagRoundTrip = class(TTestCase)
  private
    FDir: string;
    // Sets the title of AFile and saves; '' when saved, else the reason.
    // ARepair: with a repairing read
    function Retitle(const AFile: string; ARepair: Boolean = False): string;
    // The text of frame AID ('' when it is not there)
    function Field(const AFile, AID: string): string;
    function PictureCount(const AFile: string): Integer;
    function Bytes(const AFile: string): AnsiString;
    procedure WriteWav(const AFile: string; const ATag, AAudio: AnsiString);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure FlacKeepsAudioAndBlocks;
    procedure FlacFieldsNotEditedKeepTheirBytes;
    procedure FlacEditedFieldIsWrittenAsUtf8;
    procedure Id3EmptyFrameDoesNotEndTheTag;
    procedure Id3EmptyFrameAtTheEnd;
    procedure Id3SeveralValuesAreKeptApart;
    procedure Id3SeveralValuesStayInTheFile;
    procedure Id3TextEndingInZeroHasNoSeparator;
    procedure Id3UserTextKeepsItsForm;
    procedure Id3UnknownFramesStayInTheFile;
    procedure Id3UnsynchronisedTagIsNotSaved;
    procedure Id3DamagedTagIsNotSaved;
    procedure FlacWithATagInFront;
    procedure RepairFindsTheFramesBehindTheDamage;
    procedure RepairWithNothingBehindTheDamage;
    procedure RepairOfSizesInTheWrongForm;
    procedure RepairingReadOfAHealthyTag;
    procedure RepairInADsfFile;
    procedure WavWithoutATagGetsOne;
    procedure DsfRoundTrip;
    procedure DffRoundTrip;
  end;

implementation

uses
  ALMetadata, AudioTag, baseTag, tag_id3v2, tag_vorbis, file_flac, TestHelpers;

{ ---- bytes ---- }

function LE32(V: Cardinal): AnsiString;
begin
  Result := AnsiChar(V and $FF) + AnsiChar((V shr 8) and $FF) + AnsiChar((V shr 16) and $FF) + AnsiChar(V shr 24);
end;

function LE64(V: Int64): AnsiString;
begin
  Result := LE32(Cardinal(V and $FFFFFFFF)) + LE32(Cardinal(V shr 32));
end;

function BE32(V: Cardinal): AnsiString;
begin
  Result := AnsiChar(V shr 24) + AnsiChar((V shr 16) and $FF) + AnsiChar((V shr 8) and $FF) + AnsiChar(V and $FF);
end;

function BE64(V: Int64): AnsiString;
begin
  Result := BE32(Cardinal(V shr 32)) + BE32(Cardinal(V and $FFFFFFFF));
end;

function SyncSafe(V: Cardinal): AnsiString;
begin
  Result := AnsiChar((V shr 21) and $7F) + AnsiChar((V shr 14) and $7F) + AnsiChar((V shr 7) and $7F) + AnsiChar(V and $7F);
end;

// N bytes that stand for audio (no run of them is found elsewhere in a file)
function Audio(N: Integer): AnsiString;
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, N);
  for I := 1 to N do
    Result[I] := AnsiChar((I * 37 + I div 7) and $FF);
end;

function Has(const AHay, ANeedle: AnsiString): Boolean;
begin
  Result := Pos(ANeedle, AHay) > 0;
end;

{ ---- ID3v2 ---- }

function Frame23(const AID, AData: AnsiString): AnsiString;
begin
  Result := AID + BE32(Length(AData)) + #0#0 + AData;
end;

function Frame24(const AID, AData: AnsiString): AnsiString;
begin
  Result := AID + SyncSafe(Length(AData)) + #0#0 + AData;
end;

function Id3Tag(AVersion: Byte; const AFrames: AnsiString; APadding: Integer; AFlags: Byte = 0): AnsiString;
begin
  Result := 'ID3' + AnsiChar(AVersion) + #0 + AnsiChar(AFlags) + SyncSafe(Length(AFrames) + APadding) +
    AFrames + StringOfChar(#0, APadding);
end;

function PictureData: AnsiString;
begin
  Result := #0'image/jpeg'#0#3#0#$FF#$D8#$FF + Audio(500);
end;

{ ---- FLAC ---- }

function FlacBlock(AType: Byte; ALast: Boolean; const AData: AnsiString): AnsiString;
var
  B: Byte;
begin
  B := AType;
  if ALast then B := B or $80;
  Result := AnsiChar(B) + AnsiChar((Length(AData) shr 16) and $FF) + AnsiChar((Length(AData) shr 8) and $FF) +
    AnsiChar(Length(AData) and $FF) + AData;
end;

function CommentBlock(const AComments: array of AnsiString): AnsiString;
var
  I: Integer;
begin
  Result := LE32(9) + 'reference' + LE32(Length(AComments));
  for I := 0 to High(AComments) do
    Result := Result + LE32(Length(AComments[I])) + AComments[I];
end;

// 4096-sample blocks, 44.1 kHz, stereo, 16 bit, and an MD5 that is easy to find
function StreamInfo: AnsiString;
begin
  Result := #$10#$00#$10#$00#0#0#0#0#0#0#$0A#$C4#$42#$F0#$00#$00#$AC#$44 +
    #1#2#3#4#5#6#7#8#9#10#11#12#13#14#15#16;
end;

const
  LATIN1_COMMENT = 'COMMENT=caf'#$E9' in Latin-1';
  LOWER_COMMENT  = 'Custom Key=x';
  UTF8_NAME      = 'Bj'#$C3#$B6'rk';

function FlacAudio: AnsiString;
begin
  Result := #$FF#$F8 + Audio(6000);
end;

function ApplicationBlock: AnsiString;
begin
  Result := 'tool' + Audio(40);
end;

function TestFlac: AnsiString;
begin
  Result := 'fLaC' +
    FlacBlock(0, False, StreamInfo) +
    FlacBlock(2, False, ApplicationBlock) +
    FlacBlock(3, False, Audio(36)) +
    FlacBlock(4, False, CommentBlock(['TITLE=Old', 'ARTIST=A', 'ARTIST=B', LOWER_COMMENT,
      LATIN1_COMMENT, 'EMPTY=', 'COMPOSER=' + UTF8_NAME])) +
    FlacBlock(1, True, StringOfChar(#0, 1000)) +
    FlacAudio;
end;

{ ---- the test class ---- }

procedure TTestTagRoundTrip.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestTagRoundTrip.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestTagRoundTrip.Bytes(const AFile: string): AnsiString;
var
  B: TBytes;
begin
  B := ReadFileBytes(AFile);
  SetString(Result, PAnsiChar(@B[0]), Length(B));
end;

procedure SaveBytes(const AFile: string; const AData: AnsiString);
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, Length(AData));
  Move(AData[1], B[0], Length(AData));
  WriteFileBytes(AFile, B);
end;

function TTestTagRoundTrip.Retitle(const AFile: string; ARepair: Boolean): string;
var
  R: TTagReader;
begin
  R := GetFileTagsObject(AFile, False, ARepair);
  try
    AssertFalse('Loaded', R.LoadFailed);
    if R.Tags is TID3Tags then
    begin
      if TID3Tags(R.Tags).Version = 2 then
        R.Tags.SetFrameValue('TT2', 'New title', TID3Frame)
      else
        R.Tags.SetFrameValue('TIT2', 'New title', TID3Frame);
    end
    else
      R.Tags.SetFrameValue('TITLE', 'New title', TVorbisFrame);
    if R.UpdateFile then
      Result := ''
    else
      Result := 'not saved: ' + R.LastUpdateError;
  finally
    R.Free;
  end;
end;

function TTestTagRoundTrip.Field(const AFile, AID: string): string;
var
  R: TTagReader;
begin
  R := GetFileTagsObject(AFile);
  try
    Result := R.Tags.GetFrameValue(AID);
  finally
    R.Free;
  end;
end;

function TTestTagRoundTrip.PictureCount(const AFile: string): Integer;
var
  R: TTagReader;
begin
  R := GetFileTagsObject(AFile);
  try
    Result := R.Tags.ImageCount;
  finally
    R.Free;
  end;
end;

procedure TTestTagRoundTrip.WriteWav(const AFile: string; const ATag, AAudio: AnsiString);
var
  S: AnsiString;
begin
  S := 'WAVE' +
    'fmt ' + LE32(16) + #1#0#2#0 + LE32(44100) + LE32(176400) + #4#0#16#0 +
    'LIST' + LE32(12) + 'INFOINAM' + LE32(0) +
    'data' + LE32(Length(AAudio)) + AAudio;
  if ATag <> '' then
  begin
    S := S + 'id3 ' + LE32(Length(ATag)) + ATag;
    if Odd(Length(ATag)) then S := S + #0;
  end;
  SaveBytes(AFile, 'RIFF' + LE32(Length(S)) + S);
end;

procedure TTestTagRoundTrip.FlacKeepsAudioAndBlocks;
var
  F: string;
  After: AnsiString;
begin
  F := FDir + 'a.flac';
  SaveBytes(F, TestFlac);
  AssertEquals('Saved', '', Retitle(F));
  After := Bytes(F);
  AssertEquals('The new title', 'New title', Field(F, 'TITLE'));
  AssertTrue('The audio is the end of the file',
    Copy(After, Length(After) - Length(FlacAudio) + 1, Length(FlacAudio)) = FlacAudio);
  AssertTrue('The stream info', Has(After, StreamInfo));
  AssertTrue('The application block', Has(After, ApplicationBlock));
  AssertTrue('The seek table', Has(After, Audio(36)));
end;

procedure TTestTagRoundTrip.FlacFieldsNotEditedKeepTheirBytes;
var
  F: string;
  After: AnsiString;
begin
  F := FDir + 'a.flac';
  SaveBytes(F, TestFlac);
  AssertEquals('Saved', '', Retitle(F));
  After := Bytes(F);
  AssertTrue('Text that is not UTF-8 is left as it was', Has(After, LE32(Length(LATIN1_COMMENT)) + LATIN1_COMMENT));
  AssertTrue('A field name keeps its capitals', Has(After, LE32(Length(LOWER_COMMENT)) + LOWER_COMMENT));
  AssertTrue('Both artists', Has(After, 'ARTIST=A') and Has(After, 'ARTIST=B'));
  AssertTrue('An empty field', Has(After, LE32(6) + 'EMPTY='));
  AssertTrue('UTF-8 text', Has(After, 'COMPOSER=' + UTF8_NAME));
  // read by its name in capitals, as before
  AssertEquals('Found by name', 'x', Field(F, 'CUSTOM KEY'));
  // a second save changes nothing more
  AssertEquals('Saved again', '', Retitle(F));
  AssertTrue('The same file after a second save', After = Bytes(F));
end;

procedure TTestTagRoundTrip.FlacEditedFieldIsWrittenAsUtf8;
var
  F: string;
  R: TTagReader;
begin
  F := FDir + 'a.flac';
  SaveBytes(F, TestFlac);
  R := GetFileTagsObject(F);
  try
    R.Tags.SetFrameValue('COMMENT', 'caf'#$C3#$A9, TVorbisFrame);
    R.Tags.SetFrameValue('CUSTOM KEY', 'y', TVorbisFrame);
    AssertTrue('Saved: ' + R.LastUpdateError, R.UpdateFile);
  finally
    R.Free;
  end;
  AssertTrue('The new comment', Has(Bytes(F), LE32(13) + 'COMMENT=caf'#$C3#$A9));
  AssertFalse('The old comment is gone', Has(Bytes(F), 'caf'#$E9));
  AssertEquals('The other field', 'y', Field(F, 'CUSTOM KEY'));
  AssertEquals('The title was not touched', 'Old', Field(F, 'TITLE'));
end;

procedure TTestTagRoundTrip.Id3EmptyFrameDoesNotEndTheTag;
var
  F: string;
  R: TTagReader;
begin
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old') + Frame23('TCOP', '') + Frame23('TALB', #0'Album') +
    Frame23('APIC', PictureData), 100), Audio(8000));
  R := GetFileTagsObject(F);
  try
    AssertEquals('The frame behind the empty one', 'Album', R.Tags.GetFrameValue('TALB'));
    AssertEquals('The picture', 1, R.Tags.ImageCount);
    AssertFalse('Nothing unreadable', TID3Tags(R.Tags).HasUnreadableData);
  finally
    R.Free;
  end;
  AssertEquals('Saved', '', Retitle(F));
  AssertEquals('The title', 'New title', Field(F, 'TIT2'));
  AssertEquals('The album after the save', 'Album', Field(F, 'TALB'));
  AssertEquals('The picture after the save', 1, PictureCount(F));
  AssertTrue('The picture bytes', Has(Bytes(F), PictureData));
  AssertTrue('The audio', Has(Bytes(F), Audio(8000)));
end;

procedure TTestTagRoundTrip.Id3EmptyFrameAtTheEnd;
var
  F: string;
  R: TTagReader;
begin
  // v2.4 and v2.2 as well; the empty frame last, before the padding
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(4, Frame24('TIT2', #3'Old') + Frame24('TALB', #3'Album') + Frame24('TCOP', ''), 60),
    Audio(4000));
  R := GetFileTagsObject(F);
  try
    AssertEquals('Two frames', 2, R.Tags.Count);
    AssertFalse('Nothing unreadable', TID3Tags(R.Tags).HasUnreadableData);
  finally
    R.Free;
  end;
  AssertEquals('Saved', '', Retitle(F));
  AssertEquals('The album', 'Album', Field(F, 'TALB'));

  F := FDir + 'b.wav';
  WriteWav(F, Id3Tag(2, 'TT2'#0#0#4#0'Old' + 'TCR'#0#0#0 + 'TAL'#0#0#6#0'Album', 60), Audio(4000));
  AssertEquals('v2.2: the frame behind the empty one', 'Album', Field(F, 'TAL'));
  AssertEquals('Saved', '', Retitle(F));
  AssertEquals('v2.2: the album after the save', 'Album', Field(F, 'TAL'));
end;

procedure TTestTagRoundTrip.Id3SeveralValuesAreKeptApart;
var
  F: string;
  M: TAudioMetadata;
begin
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(4, Frame24('TIT2', #3'Old') +
    Frame24('TPE1', #3'First Artist'#0'Second Artist') +
    Frame24('TCON', #1#$FF#$FE'J'#0'a'#0'z'#0'z'#0#0#0#$FF#$FE'B'#0'l'#0'u'#0'e'#0's'#0) +
    Frame24('TCOM', #0'One'#0#0'Two'#0), 100), Audio(4000));
  AssertEquals('UTF-8', 'First Artist; Second Artist', Field(F, 'TPE1'));
  AssertEquals('UTF-16, each value with its byte order mark', 'Jazz; Blues', Field(F, 'TCON'));
  AssertEquals('An empty value between two, and a zero at the end', 'One; Two', Field(F, 'TCOM'));
  M := ReadTrackMetadata(F, False);
  AssertTrue('The program reads both artists', (Pos('First Artist', M.Artist) > 0) and (Pos('Second Artist', M.Artist) > 0));
  AssertEquals('Not glued together', 0, Pos('ArtistSecond', M.Artist));
  AssertEquals('Nor the genres', 0, Pos('JazzBlues', M.Genre));
end;

procedure TTestTagRoundTrip.Id3SeveralValuesStayInTheFile;
var
  F: string;
  Artists: AnsiString;
begin
  F := FDir + 'a.wav';
  Artists := Frame24('TPE1', #3'First Artist'#0'Second Artist');
  WriteWav(F, Id3Tag(4, Frame24('TIT2', #3'Old') + Artists, 100), Audio(4000));
  AssertEquals('Saved', '', Retitle(F));
  AssertTrue('The frame as it was', Has(Bytes(F), Artists));
end;

procedure TTestTagRoundTrip.Id3TextEndingInZeroHasNoSeparator;
var
  F: string;
begin
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old'#0) + Frame23('TALB', #1#$FF#$FE'A'#0'l'#0#0#0) +
    Frame23('TPE1', #0'  Spaces  '#0#0), 100), Audio(4000));
  AssertEquals('Latin-1', 'Old', Field(F, 'TIT2'));
  AssertEquals('UTF-16', 'Al', Field(F, 'TALB'));
  AssertEquals('Trimmed', 'Spaces', Field(F, 'TPE1'));
end;

procedure TTestTagRoundTrip.Id3UserTextKeepsItsForm;
var
  F: string;
  R: TTagReader;
  D, V: string;
begin
  // description and value of a user text frame are one text, without a separator
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old') + Frame23('TXXX', #0'REPLAYGAIN_TRACK_GAIN'#0'-6.50 dB'), 100),
    Audio(4000));
  R := GetFileTagsObject(F);
  try
    AssertEquals('As one text', 'REPLAYGAIN_TRACK_GAIN-6.50 dB', R.Tags.GetFrameValue('TXXX'));
    AssertTrue('And as a pair', TID3Frame(R.Tags.FramesByID['TXXX']).SplitTextPair(D, V));
    AssertEquals('The description', 'REPLAYGAIN_TRACK_GAIN', D);
    AssertEquals('The value', '-6.50 dB', V);
  finally
    R.Free;
  end;
  AssertTrue('The program finds the gain', Pos('-6.50', ReadTrackTextTags(F).AllTags) > 0);
end;

procedure TTestTagRoundTrip.Id3UnknownFramesStayInTheFile;
var
  F: string;
  Other: AnsiString;
begin
  F := FDir + 'a.wav';
  Other := Frame23('COMM', #0'eng'+'Desc'#0'The comment') +
    Frame23('PRIV', 'owner@x'#0#1#2#3#0#0#255) +
    Frame23('UFID', 'http://x'#0#9#8#7);
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #1#$FF#$FE'O'#0'l'#0'd'#0) + Other, 100), Audio(4000));
  AssertEquals('UTF-16 title', 'Old', Field(F, 'TIT2'));
  AssertEquals('Saved', '', Retitle(F));
  AssertTrue('Comment, private and identifier frames byte for byte', Has(Bytes(F), Other));
  AssertTrue('The LIST chunk of the file', Has(Bytes(F), 'INFOINAM'));
end;

procedure TTestTagRoundTrip.Id3UnsynchronisedTagIsNotSaved;
var
  F: string;
  Before: AnsiString;
begin
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old') + Frame23('TALB', #0'Al'#$FF#0'bum'), 100, $80), Audio(4000));
  Before := Bytes(F);
  AssertTrue('Refused', Retitle(F) <> '');
  AssertTrue('The file is as it was', Before = Bytes(F));
end;

procedure TTestTagRoundTrip.Id3DamagedTagIsNotSaved;
var
  F: string;
  R: TTagReader;
  Before: AnsiString;
begin
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old') + #1#2#3#4#5#6#7#8#9#10#11#12 +
    Frame23('TALB', #0'Album') + Frame23('APIC', PictureData), 100), Audio(4000));
  Before := Bytes(F);
  R := GetFileTagsObject(F);
  try
    AssertEquals('The frame in front of the damage is read', 'Old', R.Tags.GetFrameValue('TIT2'));
    AssertTrue('The damage is seen', TID3Tags(R.Tags).HasUnreadableData);
  finally
    R.Free;
  end;
  AssertTrue('Refused', Retitle(F) <> '');
  AssertTrue('The file is as it was', Before = Bytes(F));
  AssertTrue('With the frames behind the damage', Has(Bytes(F), Frame23('APIC', PictureData)));

  // the same in a DSF file would be the same code; a tag that only has
  // zero padding behind its frames is not damaged
  F := FDir + 'b.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old'), 500), Audio(4000));
  AssertEquals('Padding is no damage', '', Retitle(F));
end;

procedure TTestTagRoundTrip.FlacWithATagInFront;
var
  F: string;
  R: TTagReader;
  After: AnsiString;
begin
  F := FDir + 'a.flac';
  SaveBytes(F, Id3Tag(3, Frame23('TIT2', #0'From the ID3 tag'), 20) + TestFlac);
  R := GetFileTagsObject(F);
  try
    AssertTrue('A FLAC reader', R is TFlacReader);
    AssertTrue('Something in front is noticed', TFlacReader(R).HasLeadingData);
    AssertEquals('The title of the FLAC comments counts', 'Old', R.Tags.GetFrameValue('TITLE'));
  finally
    R.Free;
  end;
  AssertEquals('Saved', '', Retitle(F));
  After := Bytes(F);
  AssertTrue('The file begins with the FLAC data', Copy(After, 1, 4) = 'fLaC');
  AssertTrue('The audio is the end of the file',
    Copy(After, Length(After) - Length(FlacAudio) + 1, Length(FlacAudio)) = FlacAudio);
  R := GetFileTagsObject(F);
  try
    AssertFalse('Nothing in front any more', TFlacReader(R).HasLeadingData);
  finally
    R.Free;
  end;

  // a plain FLAC file has nothing in front
  F := FDir + 'b.flac';
  SaveBytes(F, TestFlac);
  R := GetFileTagsObject(F);
  try
    AssertFalse('A plain file', TFlacReader(R).HasLeadingData);
  finally
    R.Free;
  end;
end;

const
  GARBAGE = #1#2#3#4#5#6#7#8#9#10#11#12;

procedure TTestTagRoundTrip.RepairFindsTheFramesBehindTheDamage;
var
  F: string;
  R: TTagReader;
  T: TID3Tags;
  Tag, Raw: AnsiString;
begin
  F := FDir + 'a.wav';
  Tag := Id3Tag(3, Frame23('TIT2', #0'Old') + GARBAGE + Frame23('TALB', #0'Album') +
    Frame23('APIC', PictureData), 100);
  WriteWav(F, Tag, Audio(4000));
  R := GetFileTagsObject(F, False, True);
  try
    T := TID3Tags(R.Tags);
    AssertTrue('Damage found', T.Recovered);
    AssertFalse('Not the wrong form of sizes', T.RecoverPlainSizes);
    AssertFalse('May be saved', T.HasUnreadableData);
    AssertEquals('Frames in front of the damage', 1, T.RecoverKept);
    AssertEquals('Frames behind it', 2, T.RecoverRescued);
    AssertEquals('Bytes that could not be read', Int64(Length(GARBAGE)), T.RecoverDiscarded);
    AssertEquals('The album', 'Album', T.GetFrameValue('TALB'));
    AssertEquals('The picture', 1, T.ImageCount);
    SetString(Raw, PAnsiChar(@T.RecoverRaw[0]), Length(T.RecoverRaw));
    AssertTrue('The tag as it stands in the file', Raw = Tag);
  finally
    R.Free;
  end;
  AssertTrue('A normal save is still refused', Retitle(F) <> '');
  AssertEquals('The repairing save', '', Retitle(F, True));
  R := GetFileTagsObject(F);
  try
    AssertFalse('No damage any more', TID3Tags(R.Tags).HasUnreadableData);
    AssertEquals('Title', 'New title', R.Tags.GetFrameValue('TIT2'));
    AssertEquals('Album', 'Album', R.Tags.GetFrameValue('TALB'));
    AssertEquals('Picture', 1, R.Tags.ImageCount);
  finally
    R.Free;
  end;
  AssertTrue('The picture bytes', Has(Bytes(F), PictureData));
  AssertFalse('The damaged bytes are gone', Has(Bytes(F), GARBAGE));
  AssertTrue('The audio', Has(Bytes(F), Audio(4000)));
  AssertEquals('And now a normal save works', '', Retitle(F));
end;

procedure TTestTagRoundTrip.RepairWithNothingBehindTheDamage;
var
  F: string;
  R: TTagReader;
  T: TID3Tags;
begin
  // two damaged places with two frames between them; behind the second only
  // padding
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old') + GARBAGE + Frame23('TALB', #0'Album') +
    Frame23('TPE1', #0'Artist') + 'xyz' + GARBAGE, 100), Audio(4000));
  R := GetFileTagsObject(F, False, True);
  try
    T := TID3Tags(R.Tags);
    AssertTrue('Damage found', T.Recovered);
    AssertEquals('In front', 1, T.RecoverKept);
    AssertEquals('Behind the first damage', 2, T.RecoverRescued);
    AssertEquals('Both damaged places, without the padding',
      Int64(2 * Length(GARBAGE) + 3), T.RecoverDiscarded);
  finally
    R.Free;
  end;
  AssertEquals('Saved', '', Retitle(F, True));
  AssertEquals('The album', 'Album', Field(F, 'TALB'));
  AssertEquals('The artist', 'Artist', Field(F, 'TPE1'));
  AssertEquals('A normal save afterwards', '', Retitle(F));

  // a single frame between two damaged places is not taken
  F := FDir + 'b.wav';
  WriteWav(F, Id3Tag(3, Frame23('TIT2', #0'Old') + GARBAGE + Frame23('TALB', #0'Album') +
    'xyz' + GARBAGE, 100), Audio(4000));
  R := GetFileTagsObject(F, False, True);
  try
    AssertEquals('Only the frame in front', 1, R.Tags.Count);
    AssertEquals('Nothing behind', 0, TID3Tags(R.Tags).RecoverRescued);
  finally
    R.Free;
  end;
end;

procedure TTestTagRoundTrip.RepairOfSizesInTheWrongForm;
var
  F: string;
  R: TTagReader;
  T: TID3Tags;
  Pic: AnsiString;
begin
  // ID3v2.4 with the size of the picture frame as a plain number
  F := FDir + 'a.wav';
  Pic := PictureData;
  WriteWav(F, Id3Tag(4, Frame24('TIT2', #3'Old') + 'APIC' + BE32(Length(Pic)) + #0#0 + Pic +
    Frame24('TALB', #3'Album'), 100), Audio(4000));
  R := GetFileTagsObject(F);
  try
    AssertTrue('A normal read stops at the picture', TID3Tags(R.Tags).HasUnreadableData);
    AssertEquals('Without the album', '', R.Tags.GetFrameValue('TALB'));
  finally
    R.Free;
  end;
  R := GetFileTagsObject(F, False, True);
  try
    T := TID3Tags(R.Tags);
    AssertTrue('Seen', T.Recovered);
    AssertTrue('As sizes in the wrong form', T.RecoverPlainSizes);
    AssertEquals('Nothing is discarded', Int64(0), T.RecoverDiscarded);
    AssertEquals('All three frames', 3, T.Count);
    AssertEquals('The picture', 1, T.ImageCount);
  finally
    R.Free;
  end;
  AssertEquals('Saved', '', Retitle(F, True));
  R := GetFileTagsObject(F);
  try
    AssertFalse('Readable for everyone now', TID3Tags(R.Tags).HasUnreadableData);
    AssertEquals('Album', 'Album', R.Tags.GetFrameValue('TALB'));
    AssertEquals('Picture', 1, R.Tags.ImageCount);
    AssertEquals('The whole picture', Int64(503), R.Tags.Images[0].Image.Size);
  finally
    R.Free;
  end;
end;

procedure TTestTagRoundTrip.RepairingReadOfAHealthyTag;
var
  F: string;
  R: TTagReader;
  Before: AnsiString;
begin
  F := FDir + 'a.wav';
  WriteWav(F, Id3Tag(4, Frame24('TIT2', #3'New title') + Frame24('APIC', PictureData) +
    Frame24('TALB', #3'Album'), 0), Audio(4000));
  Before := Bytes(F);
  R := GetFileTagsObject(F, False, True);
  try
    AssertFalse('Nothing to repair', TID3Tags(R.Tags).Recovered);
    AssertEquals('No copy of the tag', 0, Length(TID3Tags(R.Tags).RecoverRaw));
    AssertEquals('Three frames', 3, R.Tags.Count);
  finally
    R.Free;
  end;
  AssertEquals('Saved', '', Retitle(F, True));
  AssertTrue('The same file', Before = Bytes(F));
  // a file without a tag, and a FLAC file
  WriteWav(FDir + 'b.wav', '', Audio(4000));
  R := GetFileTagsObject(FDir + 'b.wav', False, True);
  try
    AssertFalse('No tag: nothing to repair', TID3Tags(R.Tags).Recovered);
  finally
    R.Free;
  end;
  SaveBytes(FDir + 'c.flac', TestFlac);
  AssertEquals('FLAC is read as always', '', Retitle(FDir + 'c.flac', True));
end;

procedure TTestTagRoundTrip.RepairInADsfFile;
var
  F: string;
  Aud, S, After: AnsiString;
  Ptr: Int64;
begin
  F := FDir + 'a.dsf';
  Aud := Audio(8192);
  S := 'fmt ' + LE64(52) + LE32(1) + LE32(0) + LE32(2) + LE32(2) + LE32(2822400) + LE32(1) +
    LE64(8192 * 4) + LE32(4096) + LE32(0) +
    'data' + LE64(12 + Length(Aud)) + Aud;
  Ptr := 28 + Length(S);
  S := S + Id3Tag(3, Frame23('TIT2', #0'Old') + GARBAGE + Frame23('TALB', #0'Album'), 50);
  SaveBytes(F, 'DSD ' + LE64(28) + LE64(28 + Length(S)) + LE64(Ptr) + S);
  AssertTrue('A normal save is refused', Retitle(F) <> '');
  AssertEquals('The repairing save', '', Retitle(F, True));
  After := Bytes(F);
  AssertEquals('The album', 'Album', Field(F, 'TALB'));
  AssertTrue('The audio in its place', Copy(After, 93, Length(Aud)) = Aud);
  AssertEquals('A normal save afterwards', '', Retitle(F));
end;

procedure TTestTagRoundTrip.WavWithoutATagGetsOne;
var
  F: string;
  After: AnsiString;
begin
  F := FDir + 'a.wav';
  WriteWav(F, '', Audio(4000));
  AssertEquals('Saved', '', Retitle(F));
  AssertEquals('The title', 'New title', Field(F, 'TIT2'));
  After := Bytes(F);
  AssertTrue('The audio', Has(After, Audio(4000)));
  AssertTrue('The size in the header', Copy(After, 5, 4) = LE32(Length(After) - 8));
end;

procedure TTestTagRoundTrip.DsfRoundTrip;
var
  F: string;
  Aud, S, After: AnsiString;
  Total, Ptr: Int64;
begin
  F := FDir + 'a.dsf';
  Aud := Audio(8192);
  S := 'fmt ' + LE64(52) + LE32(1) + LE32(0) + LE32(2) + LE32(2) + LE32(2822400) + LE32(1) +
    LE64(8192 * 4) + LE32(4096) + LE32(0) +
    'data' + LE64(12 + Length(Aud)) + Aud;
  Ptr := 28 + Length(S);
  S := S + Id3Tag(3, Frame23('TIT2', #0'Old') + Frame23('TALB', #0'Album'), 50);
  SaveBytes(F, 'DSD ' + LE64(28) + LE64(28 + Length(S)) + LE64(Ptr) + S);
  AssertEquals('The album', 'Album', Field(F, 'TALB'));
  AssertEquals('Saved', '', Retitle(F));
  After := Bytes(F);
  AssertEquals('The title', 'New title', Field(F, 'TIT2'));
  AssertEquals('The album after the save', 'Album', Field(F, 'TALB'));
  AssertTrue('The audio in its place', Copy(After, 93, Length(Aud)) = Aud);
  Total := 0;
  Move(After[13], Total, 8);
  Move(After[21], Ptr, 8);
  AssertEquals('The size of the file in its header', Int64(Length(After)), Total);
  AssertEquals('The place of the tag', Int64(92 + Length(Aud)), Ptr);
  AssertTrue('A tag is there', Copy(After, Ptr + 1, 3) = 'ID3');
end;

procedure TTestTagRoundTrip.DffRoundTrip;
var
  F: string;
  Aud, Prop, S, Tag, After: AnsiString;
begin
  // the tag chunk behind the container, as some programs write it
  F := FDir + 'a.dff';
  Aud := Audio(8192);
  Prop := 'SND ' +
    'FS  ' + BE64(4) + BE32(2822400) +
    'CHNL' + BE64(10) + #0#2 + 'SLFTSRGT' +
    'CMPR' + BE64(20) + 'DSD ' + #14 + 'not compressed' + #0;
  S := 'DSD ' +
    'FVER' + BE64(4) + BE32($01050000) +
    'PROP' + BE64(Length(Prop)) + Prop +
    'DSD ' + BE64(Length(Aud)) + Aud +
    'COMT' + BE64(3) + 'abc' + #0;
  Tag := Id3Tag(3, Frame23('TIT2', #0'Old') + Frame23('TALB', #0'Album'), 51);
  S := 'FRM8' + BE64(Length(S)) + S + 'ID3 ' + BE64(Length(Tag)) + Tag;
  if Odd(Length(Tag)) then S := S + #0;
  SaveBytes(F, S);
  AssertEquals('The album', 'Album', Field(F, 'TALB'));
  AssertEquals('Saved', '', Retitle(F));
  After := Bytes(F);
  AssertEquals('The title', 'New title', Field(F, 'TIT2'));
  AssertEquals('The album after the save', 'Album', Field(F, 'TALB'));
  AssertTrue('The audio', Has(After, 'DSD ' + BE64(Length(Aud)) + Aud));
  AssertTrue('The properties', Has(After, Prop));
  AssertTrue('The comment chunk', Has(After, 'COMT' + BE64(3) + 'abc'));
  AssertTrue('The container holds the whole file', Copy(After, 5, 8) = BE64(Length(After) - 12));
end;

initialization
  RegisterTest(TTestTagRoundTrip);

end.
