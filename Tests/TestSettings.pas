unit TestSettings;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestSettings
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Last.fm key file (uSettingsManager.ReadLastFmKeyFile): the key is the
  first line that is not empty and not a comment; a byte order mark, spaces
  and line ends around it are ignored; anything that is not 16 to 64 letters
  and digits, a missing file and an oversized file give no key.
  Only files in a temporary folder are used.

  A remembered window position (uSettingsManager.FitWindowToWorkAreas) with
  made-up monitor layouts: a window inside a work area is left alone; one
  that hangs over an edge, lies in a corner no monitor shows, or was on a
  monitor that is gone comes wholly onto the monitor it covers most or the
  nearest one; a window larger than the work area is made as small as it.

  The settings as a first start has them (DefaultData), and what "Reset this
  page" of Preferences puts back: the settings of that page and no others,
  never the output device, the volume lock or the Last.fm key.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uSettingsManager, AuPrefs, TestHelpers;

type
  TTestLastFmKeyFile = class(TTestCase)
  private
    FDir: string;
    function KeyOf(const AContent: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure APlainKeyIsRead;
    procedure SpacesLineEndsAndTheByteOrderMarkAreIgnored;
    procedure CommentsAndEmptyLinesAreSkipped;
    procedure OnlyTheFirstLineCounts;
    procedure WhatIsNoKeyGivesNone;
    procedure AMissingFileGivesNone;
    procedure AnOversizedFileGivesNone;
  end;

  TTestWindowFit = class(TTestCase)
  private
    function Fit(const AAreas: array of TRect; L, T, W, H: Integer): string;
  published
    procedure AWindowInsideIsLeftAlone;
    procedure AWindowOverAnEdgeComesBack;
    procedure AWindowOfAMonitorThatIsGoneGoesToTheNearest;
    procedure ACornerNoMonitorShowsIsNoPlace;
    procedure AWindowLargerThanTheScreenIsMadeToFit;
    procedure AMonitorLeftOfThePrimaryHasNegativePositions;
    procedure WithoutMonitorsNothingChanges;
  end;

  TTestSettingsDefaults = class(TTestCase)
  private
    FKept: TAppSettingsData;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheDefaultsAreThoseOfAFirstStart;
    procedure AskingForTheDefaultsChangesNothing;
    procedure AResetTouchesOnlyItsPage;
    procedure AResetKeepsDeviceVolumeLockAndKey;
    procedure TheShortcutsPageHasNothingToReset;
  end;

implementation

{ ---- TTestSettingsDefaults ---- }

procedure TTestSettingsDefaults.SetUp;
begin
  FKept := AppSettings.Data;
end;

procedure TTestSettingsDefaults.TearDown;
begin
  AppSettings.Data := FKept;
end;

procedure TTestSettingsDefaults.TheDefaultsAreThoseOfAFirstStart;
var
  D: TAppSettingsData;
begin
  D := AppSettings.DefaultData;
  AssertFalse('No check for updates at start', D.CheckUpdatesAtStart);
  AssertEquals('Nothing skipped', '', D.SkippedVersion);
  AssertTrue('Work headings on', D.WorkHeadings);
  AssertFalse('Composers group off', D.ShowLibComposer);
  AssertEquals('The plain album', '%album%', D.DefaultHeaderFormat);
  AssertEquals('The plain title', '%title%', D.DefaultTrackFormat);
  AssertEquals('PCM buffer', 250, D.Audio.PCMBufferMs);
  AssertEquals('DSD buffer', 500, D.Audio.DSDBufferMs);
  AssertTrue('Automatic headroom', D.Audio.AutoHeadroom);
  AssertFalse('Volume not locked', D.Audio.VolumeLocked);
end;

procedure TTestSettingsDefaults.AskingForTheDefaultsChangesNothing;
var
  D: TAppSettingsData;
begin
  AppSettings.Data.CheckUpdatesAtStart := True;
  AppSettings.Data.Audio.PCMBufferMs := 1000;
  AppSettings.Data.DefaultHeaderFormat := '[%year% • ]%album%';
  D := AppSettings.DefaultData;
  AssertFalse('The defaults', D.CheckUpdatesAtStart);
  AssertTrue('The settings in use are as they were', AppSettings.Data.CheckUpdatesAtStart);
  AssertEquals(1000, AppSettings.Data.Audio.PCMBufferMs);
  AssertEquals('[%year% • ]%album%', AppSettings.Data.DefaultHeaderFormat);
end;

procedure TTestSettingsDefaults.AResetTouchesOnlyItsPage;
var
  Def, D: TAppSettingsData;
begin
  Def := AppSettings.DefaultData;
  D := Def;
  D.Audio.ResamplePCM := not Def.Audio.ResamplePCM;
  D.Audio.ResampleQuality := Def.Audio.ResampleQuality + 1;
  D.Audio.PCMBufferMs := 1000;
  D.Audio.DSDBufferMs := 1000;
  D.CheckUpdatesAtStart := True;
  D.ShowLibComposer := True;
  D.DefaultHeaderFormat := '[%year% • ]%album%';
  CopyPageDefaults(PREFS_RESAMPLER, Def, D);
  AssertEquals('The resampler is back', Def.Audio.ResamplePCM, D.Audio.ResamplePCM);
  AssertEquals(Def.Audio.ResampleQuality, D.Audio.ResampleQuality);
  AssertEquals('The Output page is untouched', 1000, D.Audio.PCMBufferMs);
  AssertEquals('The DSD page', 1000, D.Audio.DSDBufferMs);
  AssertTrue('The System page', D.CheckUpdatesAtStart);
  AssertTrue('The Appearance page', D.ShowLibComposer);
  AssertEquals('The Playlists page', '[%year% • ]%album%', D.DefaultHeaderFormat);
  CopyPageDefaults(PREFS_OUTPUT, Def, D);
  AssertEquals('Now the PCM buffer', Def.Audio.PCMBufferMs, D.Audio.PCMBufferMs);
  AssertEquals('Not the DSD buffer', 1000, D.Audio.DSDBufferMs);
  CopyPageDefaults(PREFS_DSD, Def, D);
  AssertEquals(Def.Audio.DSDBufferMs, D.Audio.DSDBufferMs);
  CopyPageDefaults(PREFS_SYSTEM, Def, D);
  AssertFalse(D.CheckUpdatesAtStart);
  CopyPageDefaults(PREFS_APPEARANCE, Def, D);
  AssertFalse(D.ShowLibComposer);
  CopyPageDefaults(PREFS_PLAYLISTS, Def, D);
  AssertEquals(Def.DefaultHeaderFormat, D.DefaultHeaderFormat);
end;

procedure TTestSettingsDefaults.AResetKeepsDeviceVolumeLockAndKey;
var
  Def, D: TAppSettingsData;
  P: Integer;
begin
  Def := AppSettings.DefaultData;
  D := Def;
  D.OutputApi := 1;
  D.WasapiDeviceID := 'a device';
  D.AsioDriverID := 'a driver';
  D.Audio.VolumeLocked := not Def.Audio.VolumeLocked;
  D.LastFmApiKey := 'a key';
  for P := PREFS_LIBRARY to PREFS_SHORTCUTS do CopyPageDefaults(P, Def, D);
  AssertEquals('The output interface', 1, D.OutputApi);
  AssertEquals('The device', 'a device', D.WasapiDeviceID);
  AssertEquals('The driver', 'a driver', D.AsioDriverID);
  AssertTrue('The volume lock', D.Audio.VolumeLocked <> Def.Audio.VolumeLocked);
  AssertEquals('The Last.fm key', 'a key', D.LastFmApiKey);
end;

procedure TTestSettingsDefaults.TheShortcutsPageHasNothingToReset;
var
  P: Integer;
begin
  for P := PREFS_LIBRARY to PREFS_SYSTEM do AssertTrue(PageHasSettings(P));
  AssertFalse(PageHasSettings(PREFS_SHORTCUTS));
  AssertFalse(PageHasSettings(-1));
end;

const
  SAMPLE_KEY = '0123456789abcdef0123456789ABCDEF';

procedure TTestLastFmKeyFile.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestLastFmKeyFile.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestLastFmKeyFile.KeyOf(const AContent: string): string;
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, Length(AContent));
  if Length(AContent) > 0 then Move(AContent[1], B[0], Length(AContent));
  WriteFileBytes(FDir + 'LastFmKey.txt', B);
  Result := ReadLastFmKeyFile(FDir + 'LastFmKey.txt');
end;

procedure TTestLastFmKeyFile.APlainKeyIsRead;
begin
  AssertEquals(SAMPLE_KEY, KeyOf(SAMPLE_KEY));
end;

procedure TTestLastFmKeyFile.SpacesLineEndsAndTheByteOrderMarkAreIgnored;
begin
  AssertEquals('line end', SAMPLE_KEY, KeyOf(SAMPLE_KEY + #13#10));
  AssertEquals('spaces', SAMPLE_KEY, KeyOf('  ' + SAMPLE_KEY + '  ' + #10));
  AssertEquals('byte order mark', SAMPLE_KEY, KeyOf(#$EF#$BB#$BF + SAMPLE_KEY + #13#10));
end;

procedure TTestLastFmKeyFile.CommentsAndEmptyLinesAreSkipped;
begin
  AssertEquals(SAMPLE_KEY, KeyOf('# the Last.fm API key' + #13#10 + #13#10 + '; another note' + #13#10 +
    SAMPLE_KEY + #13#10));
end;

procedure TTestLastFmKeyFile.OnlyTheFirstLineCounts;
begin
  AssertEquals('the first of two', SAMPLE_KEY, KeyOf(SAMPLE_KEY + #13#10 + 'ffffffffffffffffffffffffffffffff'));
  AssertEquals('a first line that is no key hides a later one', '',
    KeyOf('paste the key below' + #13#10 + SAMPLE_KEY));
end;

procedure TTestLastFmKeyFile.WhatIsNoKeyGivesNone;
begin
  AssertEquals('empty', '', KeyOf(''));
  AssertEquals('only a comment', '', KeyOf('# nothing here'));
  AssertEquals('too short', '', KeyOf('0123456789abcde'));
  AssertEquals('too long', '', KeyOf(StringOfChar('a', 65)));
  AssertEquals('a space inside', '', KeyOf('0123456789abcdef 0123456789abcdef'));
  AssertEquals('other characters', '', KeyOf('0123456789abcdef-0123456789abcdef'));
  AssertEquals('key=value', '', KeyOf('key=' + SAMPLE_KEY));
end;

procedure TTestLastFmKeyFile.AMissingFileGivesNone;
begin
  AssertEquals('', ReadLastFmKeyFile(FDir + 'NoSuchFile.txt'));
end;

procedure TTestLastFmKeyFile.AnOversizedFileGivesNone;
begin
  AssertEquals('', KeyOf(SAMPLE_KEY + #13#10 + StringOfChar('x', 5000)));
end;

{ ---- window positions ---- }

const
  { a 1920 x 1080 screen with a 40 pixel taskbar at the bottom }
  FULL_HD: TRect = (Left: 0; Top: 0; Right: 1920; Bottom: 1040);
  { a higher monitor to the right of it, its top 360 pixels above }
  TALL_RIGHT: TRect = (Left: 1920; Top: -360; Right: 4480; Bottom: 1040);
  { a monitor to the left of the primary one }
  LEFT_OF: TRect = (Left: -1920; Top: 0; Right: 0; Bottom: 1040);

function TTestWindowFit.Fit(const AAreas: array of TRect; L, T, W, H: Integer): string;
begin
  FitWindowToWorkAreas(AAreas, L, T, W, H);
  Result := Format('%d,%d %dx%d', [L, T, W, H]);
end;

procedure TTestWindowFit.AWindowInsideIsLeftAlone;
begin
  AssertEquals('100,80 1200x800', Fit([FULL_HD], 100, 80, 1200, 800));
  AssertEquals('filling the work area', '0,0 1920x1040', Fit([FULL_HD], 0, 0, 1920, 1040));
  AssertEquals('on the second monitor', '2000,-300 1200x800', Fit([FULL_HD, TALL_RIGHT], 2000, -300, 1200, 800));
end;

procedure TTestWindowFit.AWindowOverAnEdgeComesBack;
begin
  AssertEquals('right', '720,80 1200x800', Fit([FULL_HD], 1500, 80, 1200, 800));
  AssertEquals('left and top', '0,0 1200x800', Fit([FULL_HD], -300, -50, 1200, 800));
  AssertEquals('under the taskbar', '100,240 1200x800', Fit([FULL_HD], 100, 600, 1200, 800));
  { across two monitors: onto the one that shows most of it }
  AssertEquals('mostly on the left one', '720,80 1200x800', Fit([FULL_HD, TALL_RIGHT], 1000, 80, 1200, 800));
  AssertEquals('mostly on the right one', '1920,80 1200x800', Fit([FULL_HD, TALL_RIGHT], 1700, 80, 1200, 800));
end;

procedure TTestWindowFit.AWindowOfAMonitorThatIsGoneGoesToTheNearest;
begin
  { it was on a monitor at the right that is no longer connected }
  AssertEquals('720,80 1200x800', Fit([FULL_HD], 2400, 80, 1200, 800));
  AssertEquals('far away', '720,240 1200x800', Fit([FULL_HD], 30000, 30000, 1200, 800));
  AssertEquals('to the nearer of two: its left edge', '-1920,80 1200x800', Fit([FULL_HD, LEFT_OF], -5000, 80, 1200, 800));
end;

procedure TTestWindowFit.ACornerNoMonitorShowsIsNoPlace;
begin
  { above the lower monitor, left of the higher one: inside the rectangle
    around both, on neither }
  AssertEquals('down onto the lower monitor', '100,0 1200x300', Fit([FULL_HD, TALL_RIGHT], 100, -340, 1200, 300));
end;

procedure TTestWindowFit.AWindowLargerThanTheScreenIsMadeToFit;
begin
  AssertEquals('0,0 1920x1040', Fit([FULL_HD], -200, -100, 3000, 2000));
  AssertEquals('only too high', '100,0 1200x1040', Fit([FULL_HD], 100, 50, 1200, 1400));
end;

procedure TTestWindowFit.AMonitorLeftOfThePrimaryHasNegativePositions;
begin
  AssertEquals('-1800,100 1200x800', Fit([FULL_HD, LEFT_OF], -1800, 100, 1200, 800));
  AssertEquals('over its left edge', '-1920,100 1200x800', Fit([FULL_HD, LEFT_OF], -2500, 100, 1200, 800));
end;

procedure TTestWindowFit.WithoutMonitorsNothingChanges;
begin
  AssertEquals('5000,5000 1200x800', Fit([], 5000, 5000, 1200, 800));
end;

initialization
  RegisterTest(TTestSettingsDefaults);
  RegisterTest(TTestWindowFit);
  RegisterTest(TTestLastFmKeyFile);

end.
