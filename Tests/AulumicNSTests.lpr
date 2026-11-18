program AulumicNSTests;

{$mode ObjFPC}{$H+}
{$APPTYPE CONSOLE}

{ ==============================================================================
  Project:   AulumicNS - test program (ported from Aulumic's AulumicTests)

  Console test runner (FPCUnit) for the logic of AulumicNS. Nothing is played
  on a sound device (the playback tests play into a memory output) and only
  temporary files are used (%TEMP%\AulumicTests).

  Build and run (from the project folder):
    C:\Lazarus\lazbuild.exe Tests\AulumicNSTests.lpi
    Tests\lib\x86_64-win64\AulumicNSTests.exe
  Exit code 0 = all tests passed (1 = failures, 2 = errors, 3 = both).
  Options: --suite=TTestResamplerSignals runs one test class, -h lists all.
  The heaptrc report at the end (stderr) must say "0 unfreed memory blocks".

  Milestone 2: the engine (playback into memory, the play queue, the source
  rules, drive wake, crash tracer) and the built-in resampler. The library
  and playlist tests of Aulumic follow with milestones 3 and 4.

  Add a test: a new unit with a TTestCase class (published procedures are the
  tests) and RegisterTest in its initialization; add the unit to the uses
  clause below and to AulumicNSTests.lpi.
  =============================================================================}

uses
  Interfaces, Forms, Classes, SysUtils, consoletestrunner, uAppLifetime,
  TestHelpers, TestMemoryOutput, TestPlayback, TestPlaybackQueue, TestAudioRules,
  TestDriveWake, TestCrashTracer, TestResampler, TestLibraryLogic, TestLibraryDatabase,
  TestLibraryScanner, TestPlaylistRows, TestAutoPlaylist, TestPlaylistImport,
  TestPlaylistStore, TestReplayGainScan, TestReplayGainThread, TestMetadataCustodian, TestDemoLibrary,
  TestOutputRing, TestDsdToPcm, TestHangWatch, TestVolumePopup, TestLongPaths, TestToneControl, TestPlaylistPane,
  TestImageLimit, TestImageFormats, TestHeadroom, TestTextTags, TestInputBlock;

var
  Runner: TTestRunner;

begin
  // Some units under test use the LCL (dialogs, Application.QueueAsyncCall)
  Application.Initialize;

  DefaultFormat      := fPlain;
  DefaultRunAllTests := True;

  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Title := 'AulumicNS tests';
    Runner.Run;
  finally
    Runner.Free;
  end;

  // The global objects that unit initializations create, freed the same way
  // AulumicNS.lpr does (uAppLifetime), so heaptrc reports only leaks of the
  // code under test
  FreeAppSingletons;
end.
