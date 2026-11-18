unit uAppLifetime;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uAppLifetime
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The one place where the global objects are freed at the end of the program.
  Used by AulumicNS.lpr (normal exit and the early exits) and by the test
  program, so all of them free in the same order.

  The global objects are created by unit initializations:
    AppSettings      (uSettingsManager)
    AppStateManager  (uEngineStateManager)
    GlobalRegistry   (uFileLockRegistry)
    GlobalCPUMonitor (uOSUtils)
    the log          (AuLog)
  and the threads set aside because they did not end in time (uDriveKeepAlive).
  ---> AulumicNS: no audio DLLs to unload (FLAC, resampler and ReplayGain are
  built in); no theme / modern-control singletons (the GUI library keeps no
  global objects that need freeing).
  EndProcessIfThreadsLeft is the last call of AulumicNS.lpr: when such a
  thread (or a play thread) is still running, the process ends there, without
  the runtime's own final cleanup (a thread that ends during it can deadlock).
  =============================================================================}

interface

{ frees the global objects listed above; safe to call more than once }
procedure FreeAppSingletons;

procedure EndProcessIfThreadsLeft;

implementation

uses
  Windows, SysUtils, uSettingsManager, uEngineStateManager, uFileLockRegistry, uOSUtils,
  uCrashTracer, ALAudioEngine, uAppConsts, uDriveKeepAlive, AuLog;

procedure FreeAppSingletons;
begin
  WriteShutDownTrace('Freeing Global App Settings & Singletons');

  { a thread set aside (a cancelled drive wake, a playback worker blocked by
    its drive) may still wait for its drive: a short wait, then it is freed
    (or, still blocked, left to Windows) }
  FinishSetAsideThreads(DRIVE_WAKE_EXIT_WAIT_MS);

  if Assigned(AppSettings) then
  begin
    FreeAndNil(AppSettings);
    WriteShutDownTrace('* [uSettingsManager] AppSettings destroyed.');
  end;

  if Assigned(AppStateManager) then
  begin
    FreeAndNil(AppStateManager);
    WriteShutDownTrace('* [uEngineStateManager] AppStateManager destroyed.');
  end;

  FreeFileLockRegistry;
  FreeOSUtilsSingletons;
  FreeAppLog;
end;

procedure EndProcessIfThreadsLeft;
begin
  if not (SetAsideThreadsRunning or PlayThreadsStillRunning) then
    Exit;
  { ---> a note (as Aulumic): the trace is written, so a stuck thread at exit
    is on record }
  WriteShutDownNote('A thread is still running: the process ends now, ' +
                    'without the final runtime cleanup (no memory report).');
  TerminateProcess(GetCurrentProcess, ExitCode);
end;

end.
