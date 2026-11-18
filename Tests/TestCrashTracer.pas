unit TestCrashTracer;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestCrashTracer
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Tests for uCrashTracer's DescribeCodeAddress / DescribeExceptionPlace: the
  place of an exception as 'module+$offset' with its callers, as the log
  shows it for unhandled exceptions (Tools\FindCodeAddress.ps1 looks it up).
  ---> AulumicNS: the shutdown trace as TMainForm's close uses it: a clean
  close writes nothing; a failing step (LogShutdownStepError) writes the
  steps so far and the error, and every later step directly.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uCrashTracer;

type
  TTestCrashTracer = class(TTestCase)
  published
    procedure ExceptionPlaceNamesTheModuleAndCallers;
    procedure AddressOutsideAnyModule;
    procedure CleanCloseWritesNoTrace;
    procedure FailingStepWritesTheTrace;
  end;

implementation

procedure RaiseTestError;
begin
  raise Exception.Create('test error');
end;

procedure TTestCrashTracer.ExceptionPlaceNamesTheModuleAndCallers;
var
  Place, ExeName: string;
begin
  Place := '';
  try
    RaiseTestError;
  except
    Place := DescribeExceptionPlace;
  end;
  ExeName := ExtractFileName(ParamStr(0));
  AssertEquals('Starts with the module and an offset: ' + Place, 1,
    Pos(ExeName + '+$', Place));
  AssertTrue('Lists the calls that led there: ' + Place, Pos(' <- ' + ExeName + '+$', Place) > 0);
end;

procedure TTestCrashTracer.AddressOutsideAnyModule;
begin
  AssertEquals('A plain address', '$' + IntToHex(16, SizeOf(Pointer) * 2),
    DescribeCodeAddress(CodePointer(16)));
  AssertEquals('nil', '$' + IntToHex(0, SizeOf(Pointer) * 2),
    DescribeCodeAddress(nil));
end;

function TracePath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'ShutdownTraceLog.txt';
end;

function ReadTrace: string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    if FileExists(TracePath) then L.LoadFromFile(TracePath);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

procedure TTestCrashTracer.CleanCloseWritesNoTrace;
begin
  SysUtils.DeleteFile(TracePath);
  BeginShutdownTrace;
  WriteShutDownTrace('Close: a step');
  WriteShutDownTrace('* a sub step');
  AssertFalse('a clean close leaves no file', FileExists(TracePath));
end;

procedure TTestCrashTracer.FailingStepWritesTheTrace;
var
  T: string;
begin
  SysUtils.DeleteFile(TracePath);
  try
    BeginShutdownTrace;
    WriteShutDownTrace('Close: step one');
    AssertFalse('nothing written before the error', FileExists(TracePath));
    try
      RaiseTestError;
    except
      LogShutdownStepError('Close: step two');
    end;
    AssertTrue('written at the first error', FileExists(TracePath));
    WriteShutDownTrace('Close: step three');
    T := ReadTrace;
    AssertTrue('the start: ' + T, Pos('Application Teardown Started', T) > 0);
    AssertTrue('the step before: ' + T, Pos('Close: step one', T) > 0);
    AssertTrue('the error: ' + T, Pos('Close: step two -> Exception: test error', T) > 0);
    AssertTrue('the step after: ' + T, Pos('Close: step three', T) > 0);
  finally
    SysUtils.DeleteFile(TracePath);
    BeginShutdownTrace;   // a new trace: the test program's own exit writes nothing
  end;
end;

initialization
  RegisterTest(TTestCrashTracer);

end.
