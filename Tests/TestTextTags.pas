unit TestTextTags;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestTextTags
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Reading the text fields of a tag without loading its pictures
  (basetag.TagReadTextOnly, audiotag.GetFileTagsObject(FileName, True),
  ALMetadata.ReadTrackTextTags): the play thread wants the ReplayGain values
  and the album of a track, not a cover of several MB.

  A FLAC file (picture block) and a WAV file (ID3v2 APIC frame), each with
  text fields, a ReplayGain value and a picture of 300 KB written with the
  tag library itself: the text-only read gives the same text, no picture, and
  such a reader refuses to save (it would drop the picture); the file and a
  normal read afterwards are as before.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestTextTags = class(TTestCase)
  private
    FDir: string;
    // AFile gets the album, a ReplayGain track gain and a picture
    procedure Tag(const AFile: string);
    procedure CheckTextOnly(const AFile: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure FlacTextWithoutThePicture;
    procedure WavTextWithoutThePicture;
    procedure TheSwitchIsBackAfterTheRead;
  end;

implementation

uses
  ALMetadata, AudioTag, baseTag, tag_id3v2, TestHelpers;

const
  PICTURE_BYTES = 300 * 1024;

procedure TTestTextTags.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestTextTags.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure TTestTextTags.Tag(const AFile: string);
var
  R: TTagReader;
  C: TCommonTags;
  Img: TImageElement;
  Pic: TMemoryStream;
  Frame: TID3Frame;
  I: Integer;
  B: Byte;
begin
  Pic := TMemoryStream.Create;
  R := GetFileTagsObject(AFile);
  try
    C := R.GetCommonTags;
    C.Title       := 'A Title';
    C.Album       := 'The Album';
    C.AlbumArtist := 'The Album Artist';
    R.SetCommonTags(C);

    // something that begins like a JPEG
    B := $FF; Pic.WriteBuffer(B, 1);
    B := $D8; Pic.WriteBuffer(B, 1);
    B := $FF; Pic.WriteBuffer(B, 1);
    for I := 3 to PICTURE_BYTES - 1 do
    begin
      B := Byte(I * 31);
      Pic.WriteBuffer(B, 1);
    end;
    Pic.Position := 0;

    if R.Tags is TID3Tags then
    begin
      Frame := TID3Frame.Create('APIC');
      Frame.Tagger := R.Tags;
      Frame.LoadFromImageStream(Pic, 'image/jpeg', 3, False);
      R.Tags.Add(Frame);
    end
    else
    begin
      Img := TImageElement.Create;
      Img.MIMEType    := 'image/jpeg';
      Img.PictureType := 3;
      Img.Description := '';
      Img.Image.CopyFrom(Pic, Pic.Size);
      Img.Image.Position := 0;
      R.Tags.AddImage(Img);
    end;
    AssertTrue('Tag written: ' + R.LastUpdateError, R.UpdateFile);
  finally
    R.Free;
    Pic.Free;
  end;
end;

procedure TTestTextTags.CheckTextOnly(const AFile: string);
var
  Full, Text: TAudioMetadata;
  R: TTagReader;
  Before, After: TBytes;
begin
  // as always: the picture is there
  Full := ReadTrackMetadata(AFile, True);
  AssertTrue('Read', Full.ReadOk);
  AssertEquals('Album', 'The Album', Full.Album);
  AssertTrue('The picture is found by a normal read', Full.HasCover);
  AssertTrue('A file with the picture in it', Length(ReadFileBytes(AFile)) > PICTURE_BYTES);

  // text only: the same text, no picture
  Text := ReadTrackTextTags(AFile);
  AssertTrue('Read', Text.ReadOk);
  AssertEquals('Title', Full.Title, Text.Title);
  AssertEquals('Album', 'The Album', Text.Album);
  AssertEquals('Album artist', 'The Album Artist', Text.AlbumArtist);
  AssertEquals('Sample rate', Full.SampleRate, Text.SampleRate);
  AssertEquals('The ReplayGain fields', Full.AllTags, Text.AllTags);
  AssertFalse('No picture', Text.HasCover);

  // the reader itself: no picture in memory, and it will not save
  Before := ReadFileBytes(AFile);
  R := GetFileTagsObject(AFile, True);
  try
    AssertTrue('Marked as text only', R.TextOnly);
    AssertFalse('Loaded', R.LoadFailed);
    AssertEquals('No picture loaded', 0, R.Tags.ImageCount);
    AssertFalse('Saving is refused', R.UpdateFile);
    AssertTrue('With a reason', R.LastUpdateError <> '');
  finally
    R.Free;
  end;
  After := ReadFileBytes(AFile);
  AssertEquals('The file has its length', Length(Before), Length(After));
  AssertTrue('And its bytes', CompareMem(@Before[0], @After[0], Length(Before)));

  // a normal reader afterwards still has the picture and may save
  R := GetFileTagsObject(AFile);
  try
    AssertFalse('Not text only', R.TextOnly);
    AssertEquals('The picture', 1, R.Tags.ImageCount);
    AssertEquals('All of it', Int64(PICTURE_BYTES), R.Tags.Images[0].Image.Size);
    AssertTrue('Saves: ' + R.LastUpdateError, R.UpdateFile);
  finally
    R.Free;
  end;
  AssertTrue('The picture is still in the file', ReadTrackMetadata(AFile, True).HasCover);
end;

procedure TTestTextTags.FlacTextWithoutThePicture;
begin
  WritePatternFlac(FDir + 'a.flac', 20000);
  Tag(FDir + 'a.flac');
  CheckTextOnly(FDir + 'a.flac');
end;

procedure TTestTextTags.WavTextWithoutThePicture;
begin
  WriteTestWav(FDir + 'a.wav');
  AddWavId3Tag(FDir + 'a.wav', ['TXXX', 'REPLAYGAIN_TRACK_GAIN'#0'-6.50 dB']);
  Tag(FDir + 'a.wav');
  AssertTrue('The ReplayGain value is read', Pos('-6.50', ReadTrackTextTags(FDir + 'a.wav').AllTags) > 0);
  CheckTextOnly(FDir + 'a.wav');
end;

procedure TTestTextTags.TheSwitchIsBackAfterTheRead;
var
  R: TTagReader;
begin
  WritePatternFlac(FDir + 'a.flac', 20000);
  AssertFalse('Off at first', TagReadTextOnly);
  R := GetFileTagsObject(FDir + 'a.flac', True);
  R.Free;
  AssertFalse('Off after a text-only read', TagReadTextOnly);
  // also for a file that is not there
  R := GetFileTagsObject(FDir + 'none.flac', True);
  try
    AssertTrue('Not loaded', R.LoadFailed);
  finally
    R.Free;
  end;
  AssertFalse('Off after a failed read', TagReadTextOnly);
  R := GetFileTagsObject(FDir + 'a.flac');
  try
    AssertFalse('The next reader is a normal one', R.TextOnly);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TTestTextTags);

end.
