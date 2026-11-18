unit TestDemoLibrary;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestDemoLibrary
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The demo library of the help screenshots (AuDemoLibrary): the silent FLAC
  files are read back by the built-in decoder (every sample 0, the right
  number of frames, also for a last frame shorter than the block) and by the
  tag reader (tags, length, embedded cover); the PDF booklet has a valid
  cross reference table; the whole library has its albums, covers and
  booklets. Also the booklet search (uMetaUtils.FindBooklets) and the stages
  of the signal path (AuSignalPath.BuildSignalPath).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestDemoLibrary = class(TTestCase)
  private
    FDir: string;
    function Tags(const ATitle: string): TStringList;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SilentFlacDecodesToSilence;
    procedure SilentFlacHiResKeepsItsFormat;
    procedure SilentFlacTagsAndCoverAreRead;
    procedure SilentFlacRejectsAnUnknownRate;
    procedure BookletPdfHasAValidCrossReference;
    procedure FindBookletsLooksInSubFoldersAndAboveADiscFolder;
    procedure DemoLibraryHasItsAlbums;
    procedure SignalPathBitPerfectChangesNothing;
    procedure SignalPathMarksVolumeAndResampler;
    procedure SignalPathDsdOverDoPIsTransparent;
    procedure SignalPathShowsThePreamp;
  end;

implementation

uses
  Math, AuDecoder, AuDecFlac, AuAudioTypes, ALMetadata, AuDemoLibrary, uMetaUtils, uAudioUtils, AuSignalPath,
  uSettingsManager, TestHelpers;

procedure TTestDemoLibrary.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(CreateTestDir);
end;

procedure TTestDemoLibrary.TearDown;
begin
  RemoveTestTree(FDir);
end;

function TTestDemoLibrary.Tags(const ATitle: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Add('TITLE=' + ATitle);
  Result.Add('ARTIST=The Example Quartet');
  Result.Add('ALBUM=First Light');
  Result.Add('TRACKNUMBER=3');
  Result.Add('DISCNUMBER=1');
  Result.Add('GENRE=Jazz');
end;

procedure TTestDemoLibrary.SilentFlacDecodesToSilence;
const
  TOTAL = DEMO_FLAC_BLOCK * 3 + 1234;   // a short last frame
var
  T: TStringList;
  D: TAuDecoder;
  Buf: array of Int32;
  N, I, Frames: Integer;
  NonZero: Boolean;
begin
  T := Tags('Silence');
  try
    AssertTrue('written', WriteSilentFlac(FDir + 'a.flac', 44100, 16, 2, TOTAL, T, nil));
  finally
    T.Free;
  end;
  D := OpenDecoder(FDir + 'a.flac');
  try
    AssertTrue('a FLAC decoder', D is TAuFlacDecoder);
    AssertEquals('rate', 44100, D.Info.SampleRate);
    AssertEquals('channels', 2, D.Info.Channels);
    AssertEquals('bits', 16, D.Info.BitsPerSample);
    AssertEquals('total frames', TOTAL, D.Info.TotalFrames);
    SetLength(Buf, 4096 * 2);
    Frames := 0;
    NonZero := False;
    repeat
      N := D.ReadPcm(@Buf[0], 4096);
      for I := 0 to N * 2 - 1 do
        if Buf[I] <> 0 then NonZero := True;
      Inc(Frames, N);
    until N <= 0;
    AssertEquals('decoded frames', TOTAL, Frames);
    AssertFalse('silence', NonZero);
  finally
    D.Free;
  end;
end;

procedure TTestDemoLibrary.SilentFlacHiResKeepsItsFormat;
var
  D: TAuDecoder;
begin
  { five minutes at 192 kHz / 24 bit: a few KB (CONSTANT subframes) }
  AssertTrue(WriteSilentFlac(FDir + 'b.flac', 192000, 24, 2, Int64(192000) * 300, nil, nil));
  AssertTrue('small', ReadFileBytes(FDir + 'b.flac') <> nil);
  AssertTrue('a few KB', Length(ReadFileBytes(FDir + 'b.flac')) < 250 * 1024);
  D := OpenDecoder(FDir + 'b.flac');
  try
    AssertEquals(192000, D.Info.SampleRate);
    AssertEquals(24, D.Info.BitsPerSample);
    AssertEquals(Int64(192000) * 300, D.Info.TotalFrames);
  finally
    D.Free;
  end;
end;

procedure TTestDemoLibrary.SilentFlacTagsAndCoverAreRead;
var
  T: TStringList;
  Cover: TBytes;
  M: TAudioMetadata;
  I: Integer;
begin
  { not a real JPEG: the tag reader only carries the bytes }
  SetLength(Cover, 300);
  Cover[0] := $FF; Cover[1] := $D8; Cover[2] := $FF;
  for I := 3 to High(Cover) do Cover[I] := Byte(I);
  T := Tags('Paper Boats');
  try
    AssertTrue(WriteSilentFlac(FDir + 'c.flac', 48000, 24, 2, Int64(48000) * 245, T, Cover));
  finally
    T.Free;
  end;
  M := ReadTrackMetadata(FDir + 'c.flac', True);
  AssertTrue('read', M.ReadOk);
  AssertEquals('Paper Boats', M.Title);
  AssertEquals('The Example Quartet', M.Artist);
  AssertEquals('First Light', M.Album);
  AssertEquals('Jazz', M.Genre);
  AssertEquals(3, M.TrackNumber);
  AssertEquals('4:05', M.DurationStr);
  AssertEquals(48000, M.SampleRate);
  AssertEquals(24, M.BitDepth);
  AssertTrue('cover', M.HasCover);
  AssertEquals('cover size', Length(Cover), Length(M.CoverData));
end;

procedure TTestDemoLibrary.SilentFlacRejectsAnUnknownRate;
begin
  AssertFalse('22.05 kHz has no frame header code here', WriteSilentFlac(FDir + 'd.flac', 22050, 16, 2, 1000, nil, nil));
  AssertFalse('no file', FileExists(FDir + 'd.flac'));
end;

procedure TTestDemoLibrary.BookletPdfHasAValidCrossReference;
var
  Pages: TStringList;
  Jpeg, B: TBytes;
  S, Entry: string;
  P, X, N, I, Off, K: Integer;
begin
  SetLength(Jpeg, 64);
  Pages := TStringList.Create;
  try
    Pages.Add('Tracks' + LineEnding + '1. One (1:00)' + LineEnding + 'A (bracket) and a \ backslash');
    Pages.Add('About' + LineEnding + 'Text');
    AssertTrue(WriteDemoBookletPdf(FDir + 'b.pdf', Jpeg, 8, 8, Pages));
  finally
    Pages.Free;
  end;
  B := ReadFileBytes(FDir + 'b.pdf');
  SetString(S, PAnsiChar(@B[0]), Length(B));
  AssertEquals('header', '%PDF-1.4', Copy(S, 1, 8));
  AssertTrue('end', Pos('%%EOF', S) > Length(S) - 8);
  { startxref points at the table }
  P := Pos('startxref', S);
  X := StrToInt(Trim(Copy(S, P + 10, Pos(#10, Copy(S, P + 10, 20)) - 1)));
  AssertEquals('xref', 'xref', Copy(S, X + 1, 4));
  { 0 n: the count; every entry points at "<n> 0 obj" }
  P := X + 1 + 5;
  N := StrToInt(Trim(Copy(S, P + 2, Pos(#10, Copy(S, P, 20)) - 3)));
  AssertEquals('objects: catalog, pages, 3 pages with contents, image, 2 fonts', 11, N - 1);
  P := Pos('0000000000 65535 f', S);
  for I := 1 to N - 1 do
  begin
    Entry := Copy(S, P + I * 20, 20);
    Off := StrToInt(Copy(Entry, 1, 10));
    K := Length(IntToStr(I) + ' 0 obj');
    AssertEquals('object ' + IntToStr(I), IntToStr(I) + ' 0 obj', Copy(S, Off + 1, K));
  end;
  AssertTrue('escaped bracket', Pos('A \(bracket\) and a \\ backslash', S) > 0);
end;

function OneByte: TBytes;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 1;
end;

procedure TTestDemoLibrary.FindBookletsLooksInSubFoldersAndAboveADiscFolder;
var
  L: TStringList;
begin
  ForceDirectories(FDir + 'Album\CD1\Scans');
  ForceDirectories(FDir + 'Album\CD1\Scans\Deeper');
  WriteFileBytes(FDir + 'Album\Album - Booklet.pdf', OneByte);
  WriteFileBytes(FDir + 'Album\CD1\Scans\Inlay.pdf', OneByte);
  WriteFileBytes(FDir + 'Album\CD1\Scans\Deeper\Too deep.pdf', OneByte);
  WriteFileBytes(FDir + 'Album\CD1\01 - Track.flac', OneByte);
  L := TStringList.Create;
  try
    FindBooklets(FDir + 'Album\CD1', L);
    AssertEquals('the Scans PDF and the album folder''s', 2, L.Count);
    AssertTrue(L.IndexOf(FDir + 'Album\CD1\Scans\Inlay.pdf') >= 0);
    AssertTrue(L.IndexOf(FDir + 'Album\Album - Booklet.pdf') >= 0);
    { not a disc folder: the folder above is not searched }
    ForceDirectories(FDir + 'Other\Live');
    WriteFileBytes(FDir + 'Other\Notes.pdf', OneByte);
    FindBooklets(FDir + 'Other\Live', L);
    AssertEquals(0, L.Count);
  finally
    L.Free;
  end;
end;

procedure TTestDemoLibrary.DemoLibraryHasItsAlbums;
var
  Root: string;
  L: TStringList;
begin
  AssertEquals('music files', 48, MakeDemoLibrary(FDir));
  Root := FDir + 'Demo Music\';
  AssertTrue(FileExists(Root + 'The Example Quartet\2019 - First Light\folder.jpg'));
  AssertTrue(FileExists(Root + 'The Example Quartet\2019 - First Light\01 - Morning Over the Bridge.flac'));
  AssertTrue(FileExists(Root + 'Northbound Chamber Orchestra\2018 - Seasons in Blue\CD2\folder.jpg'));
  AssertTrue(FileExists(Root + 'Northbound Chamber Orchestra\2018 - Seasons in Blue\Scans\back.jpg'));
  L := TStringList.Create;
  try
    FindBooklets(Root + 'Northbound Chamber Orchestra\2018 - Seasons in Blue\CD1', L);
    AssertEquals('the booklet above the disc folder', 1, L.Count);
    FindBooklets(Root + 'The Example Quartet\2019 - First Light', L);
    AssertEquals(1, L.Count);
  finally
    L.Free;
  end;
  { a second run replaces the library }
  AssertEquals(48, MakeDemoLibrary(FDir));
end;

{ ---- the signal path ---- }

function PcmInfo: TSignalInfo;
begin
  Result := Default(TSignalInfo);
  Result.Valid := True;
  Result.InRate := 44100;
  Result.OutRate := 44100;
  Result.SourceBits := 16;
  Result.OutBits := 24;
  Result.OutValidBits := 24;
  Result.Channels := 2;
  Result.Volume := 1000;
  Result.RGFactor := 1;
  Result.BitPerfect := True;
end;

function FindStage(P: TAuSignalPath; const ATitle: string; out St: TAuStage): Boolean;
var
  I: Integer;
begin
  for I := 0 to P.StageCount - 1 do
    if P.Stage(I).Title = ATitle then
    begin
      St := P.Stage(I);
      Exit(True);
    end;
  St := Default(TAuStage);
  Result := False;
end;

procedure TTestDemoLibrary.SignalPathBitPerfectChangesNothing;
var
  P: TAuSignalPath;
  M: TAudioMetadata;
  I: Integer;
  St: TAuStage;
begin
  M := Default(TAudioMetadata);
  P := TAuSignalPath.Create(nil);
  try
    BuildSignalPath(P, PcmInfo, M, 'C:\Music\a.flac', 'USB DAC', False);
    AssertTrue('bit-perfect', P.SummaryState = stTransparent);
    for I := 0 to P.StageCount - 1 do
      AssertFalse(P.Stage(I).Title + ' changes nothing', P.Stage(I).State = stModified);
    AssertTrue(FindStage(P, 'Decoder', St));
    AssertTrue('16 bit padded into 24', FindStage(P, 'Bit depth', St) and (St.State = stTransparent));
    AssertTrue(FindStage(P, 'Output', St) and (Pos('USB DAC', St.Detail) > 0));
  finally
    P.Free;
  end;
end;

procedure TTestDemoLibrary.SignalPathMarksVolumeAndResampler;
var
  P: TAuSignalPath;
  M: TAudioMetadata;
  Inf: TSignalInfo;
  St: TAuStage;
begin
  M := Default(TAudioMetadata);
  Inf := PcmInfo;
  Inf.BitPerfect := False;
  Inf.Volume := 500;
  Inf.Resampled := True;
  Inf.OutRate := 88200;
  P := TAuSignalPath.Create(nil);
  try
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertTrue('processed', P.SummaryState = stModified);
    AssertTrue('volume', FindStage(P, 'Volume', St) and (St.State = stModified));
    AssertTrue('-12 dB at 50 %', Pos('-12.0 dB', St.Detail) > 0);
    AssertTrue('resampler', FindStage(P, 'Resampler', St) and (St.State = stModified));
    AssertTrue('rates', Pos('44.1 -> 88.2 kHz', St.Detail) > 0);
    AssertTrue('dither', FindStage(P, 'Dither', St) and (Pos('24 bit', St.Detail) > 0));
  finally
    P.Free;
  end;
end;

procedure TTestDemoLibrary.SignalPathDsdOverDoPIsTransparent;
var
  P: TAuSignalPath;
  M: TAudioMetadata;
  Inf: TSignalInfo;
  St: TAuStage;
begin
  M := Default(TAudioMetadata);
  M.SampleRate := 2822400;
  Inf := PcmInfo;
  Inf.IsDsd := True;
  Inf.DoP := True;
  Inf.InRate := 176400;
  Inf.OutRate := 176400;
  Inf.Volume := 400;            // not applied to DSD
  P := TAuSignalPath.Create(nil);
  try
    BuildSignalPath(P, Inf, M, 'C:\Music\a.dsf', '', False);
    AssertTrue('DoP', FindStage(P, 'DSD transport', St) and (St.State = stTransparent));
    AssertTrue('volume not applied', FindStage(P, 'Volume', St) and (St.State = stTransparent));
    AssertFalse('no resampler stage for DSD', FindStage(P, 'Resampler', St));
    AssertTrue('DSD64 source', FindStage(P, 'Source file', St) and (Pos('DSD64', St.Detail) > 0));
  finally
    P.Free;
  end;
end;

{ The preamp has a stage of its own (RGFactor holds it, also
  with ReplayGain off); the ReplayGain stage shows only its own gain }
procedure TTestDemoLibrary.SignalPathShowsThePreamp;
var
  P: TAuSignalPath;
  M: TAudioMetadata;
  Inf: TSignalInfo;
  St: TAuStage;
  OldMode: Integer;
begin
  M := Default(TAudioMetadata);
  Inf := PcmInfo;
  Inf.BitPerfect := False;
  Inf.PreampDB := -3;
  Inf.RGFactor := Power(10, -3 / 20);
  OldMode := AppSettings.Data.Audio.ReplayGainMode;
  P := TAuSignalPath.Create(nil);
  try
    AppSettings.Data.Audio.ReplayGainMode := 0;
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertTrue('preamp stage', FindStage(P, 'Headroom', St) and (St.State = stModified));
    AssertTrue('-3 dB', Pos('-3.00 dB', St.Detail) > 0);
    AssertTrue('ReplayGain off', FindStage(P, 'ReplayGain', St) and (St.Detail = 'Off'));
    AssertTrue('dithered', FindStage(P, 'Dither', St));
    { ReplayGain -6 dB plus the preamp: the factor is -9 dB }
    AppSettings.Data.Audio.ReplayGainMode := 1;
    Inf.RGFactor := Power(10, -9 / 20);
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertTrue('ReplayGain stage', FindStage(P, 'ReplayGain', St));
    AssertTrue('its own -6 dB: ' + St.Detail, Pos('-6.00 dB', St.Detail) > 0);
    AssertTrue('preamp still -3 dB', FindStage(P, 'Headroom', St) and (Pos('-3.00 dB', St.Detail) > 0));
    { no preamp: no stage }
    Inf.PreampDB := 0;
    Inf.RGFactor := 1;
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertFalse('no preamp stage', FindStage(P, 'Headroom', St));
    { automatic headroom shows what it takes off; with
      nothing to lower it is there only where it could act (resampled) }
    Inf.HeadroomOn := True;
    Inf.HeadroomDB := -0.8;
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertTrue('automatic headroom stage', FindStage(P, 'Headroom', St) and (St.State = stModified));
    AssertTrue('-0.8 dB, automatic: ' + St.Detail, (Pos('-0.80 dB', St.Detail) > 0) and (Pos('automatic', St.Detail) > 0));
    Inf.HeadroomDB := 0;
    Inf.Resampled := False;
    Inf.DsdToPcm := False;
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertFalse('nothing to lower, not resampled: no stage', FindStage(P, 'Headroom', St));
    Inf.Resampled := True;
    BuildSignalPath(P, Inf, M, 'C:\Music\a.flac', '', False);
    AssertTrue('resampled: the stage says there is nothing to lower',
      FindStage(P, 'Headroom', St) and (St.State = stTransparent));
  finally
    AppSettings.Data.Audio.ReplayGainMode := OldMode;
    P.Free;
  end;
end;

initialization
  RegisterTest(TTestDemoLibrary);

end.
