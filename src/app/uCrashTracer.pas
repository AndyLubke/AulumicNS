unit uCrashTracer;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uCrashTracer
  Author:    André Lubke
  Created:   2026

  Helper unit for tracing crashes at closing down.

  ---> AUDIT FIX: Always active, writes only when something went wrong.
  Every trace step is kept in memory (a few dozen short lines). Nothing is
  written after a clean shutdown. At the first error the steps so far are
  written to ShutdownTraceLog.txt together with the error, and every later
  step is written directly, so the log shows where it happened.
  Unhandled exceptions that reach the RTL (for example during the final
  cleanup after the main form is gone) are written the same way.
  (Replaces the former ENABLE_SHUTDOWN_TRACE constant.)

  ---> ADDED: DescribeCodeAddress / DescribeExceptionPlace give the place of
  an exception as 'AulumicNS.exe+$offset' (with the calls that led there), for
  the log; Tools\FindCodeAddress.ps1 turns it into routine, file and line.
  =============================================================================}

interface

uses
  Classes, SysUtils;

procedure BeginShutdownTrace;
procedure WriteShutDownTrace(const StepName: string; IsError: Boolean = False);
// ---> ADDED: Something unusual that is no error (e.g. a thread still running
// at exit): written like an error (the trace so far goes to the file), but
// labelled 'NOTE:' instead of '!!! EXCEPTION !!!'
procedure WriteShutDownNote(const ANote: string);
function  LogShutdownException(const AContext: string; E: Exception = nil): string;
// ---> AulumicNS: for an except block of a shutdown step: the exception being
// handled (a Pascal one or an OS-level one) via LogShutdownException
procedure LogShutdownStepError(const AStep: string);

// ---> ADDED: A code address as module + offset, e.g. 'AulumicNS.exe+$1A2B3C'
// (look it up with Tools\FindCodeAddress.ps1); '$...' when it lies in no module
function  DescribeCodeAddress(AAddr: CodePointer): string;
// ---> ADDED: Where the exception being handled happened, then the calls that
// led there (at most AMaxCallers): 'AulumicNS.exe+$1A2B <- AulumicNS.exe+$3C4D
// <- ...'. Only meaningful inside an except block or Application.OnException.
function  DescribeExceptionPlace(AMaxCallers: Integer = 8): string;

implementation

uses
  Windows;

function CT_GetModuleHandleExW(dwFlags: DWORD; lpModuleName: PWideChar;
  var phModule: HMODULE): BOOL; stdcall; external 'kernel32.dll' name 'GetModuleHandleExW';

const
  CT_MODULE_FROM_ADDRESS     = $00000004; // GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
  CT_MODULE_UNCHANGED_REFCNT = $00000002; // GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT

var
  GTraceStep     : Integer = 0;
  GTraceSubStep  : Integer = 0;
  GBuffer        : TStringList = nil;   // steps kept until the first error
  GHadError      : Boolean = False;
  GOldExceptProc : TExceptProc = nil;

function TraceFilePath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'ShutdownTraceLog.txt';
end;

procedure AppendLinesToFile(ALines: TStrings);
var
  F       : TextFile;
  LogPath : string;
  I       : Integer;
begin
  if (not Assigned(ALines)) or (ALines.Count = 0) then
    Exit;

  LogPath := TraceFilePath;
  try
    AssignFile(F, LogPath);
    if FileExists(LogPath) then
      Append(F)
    else
      Rewrite(F);
    try
      for I := 0 to ALines.Count - 1 do
        Writeln(F, ALines[I]);
    finally
      CloseFile(F);
    end;
  except
    // Silently swallow I/O errors so the tracer never crashes the application.
  end;
end;

procedure WriteRawLine(const ALine: string);
var
  One: TStringList;
begin
  try
    if GHadError then
    begin
      One := TStringList.Create;
      try
        One.Add(ALine);
        AppendLinesToFile(One);
      finally
        One.Free;
      end;
    end
    else
    begin
      if not Assigned(GBuffer) then
        GBuffer := TStringList.Create;
      GBuffer.Add(ALine);
    end;
  except
    // The tracer must never raise
  end;
end;

// First error: write everything traced so far, then the error line
procedure WriteErrorLine(const ALine: string);
begin
  try
    if not GHadError then
    begin
      GHadError := True;
      if not Assigned(GBuffer) then
        GBuffer := TStringList.Create;
      GBuffer.Add(ALine);
      AppendLinesToFile(GBuffer);
      GBuffer.Clear;
    end
    else
      WriteRawLine(ALine);
  except
    // The tracer must never raise
  end;
end;

procedure BeginShutdownTrace;
begin
  GTraceStep    := 0;
  GTraceSubStep := 0;
  { ---> AulumicNS: a new trace (TMainForm.FormCloseQuery calls it once): an
    error traced before is in the file already; the steps of the close are
    written only when one of them fails (and the tests can start clean) }
  GHadError := False;
  if Assigned(GBuffer) then
    GBuffer.Clear;
  WriteRawLine('');
  WriteShutDownTrace('========== Application Teardown Started ==========');
end;

procedure WriteShutDownTrace(const StepName: string; IsError: Boolean = False);
var
  Trimmed   : string;
  Prefix    : string;
  TimeStamp : string;
begin
  Trimmed := Trim(StepName);
  if (Trimmed = '') and (not IsError) then
  begin
    WriteRawLine('');
    Exit;
  end;

  TimeStamp := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' - ';

  if IsError then
  begin
    Prefix := '!!! EXCEPTION !!! ';
  end
  else if (StepName[1] = ' ') or (Trimmed[1] = '*') or (Trimmed[1] = '[') then
  begin
    // Sub-step: increments sub-counter (e.g., [17.1], [17.2])
    Inc(GTraceSubStep);
    Prefix := Format('  [%.2d.%d] ', [GTraceStep, GTraceSubStep]);
  end
  else
  begin
    // Main step: increments main counter and resets sub-counter
    Inc(GTraceStep);
    GTraceSubStep := 0;
    Prefix := Format('[%.2d] ', [GTraceStep]);
  end;

  if IsError then
    WriteErrorLine(TimeStamp + Prefix + Trimmed)
  else
    WriteRawLine(TimeStamp + Prefix + Trimmed);
end;

procedure WriteShutDownNote(const ANote: string);
begin
  WriteErrorLine(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' - NOTE: ' + Trim(ANote));
end;

function LogShutdownException(const AContext: string; E: Exception = nil): string;
begin
  if Assigned(E) then
    Result := E.ClassName + ': ' + E.Message
  else
    Result := 'Non-Pascal / OS-level or external DLL exception';

  WriteShutDownTrace(AContext + ' -> ' + Result, True);
end;

procedure LogShutdownStepError(const AStep: string);
begin
  try
    if ExceptObject is Exception then
      LogShutdownException(AStep, Exception(ExceptObject))
    else
      LogShutdownException(AStep, nil);
  except
    // The tracer must never raise
  end;
end;

function DescribeCodeAddress(AAddr: CodePointer): string;
var
  Module : HMODULE;
  Name   : array[0..MAX_PATH] of WideChar;
  Len    : DWORD;
begin
  Module := 0;
  if (AAddr <> nil) and
     CT_GetModuleHandleExW(CT_MODULE_FROM_ADDRESS or CT_MODULE_UNCHANGED_REFCNT,
       PWideChar(AAddr), Module) and (Module <> 0) then
  begin
    Len := GetModuleFileNameW(Module, @Name[0], MAX_PATH);
    if Len > 0 then
    begin
      Result := ExtractFileName(UTF8Encode(UnicodeString(PWideChar(@Name[0])))) +
                '+$' + IntToHex(PtrUInt(AAddr) - PtrUInt(Module), 1);
      Exit;
    end;
  end;
  Result := '$' + IntToHex(PtrUInt(AAddr), SizeOf(Pointer) * 2);
end;

function DescribeExceptionPlace(AMaxCallers: Integer): string;
var
  Frames : PCodePointer;
  I, N   : Integer;
begin
  Result := '';
  try
    Result := DescribeCodeAddress(ExceptAddr);
    Frames := ExceptFrames;
    N      := ExceptFrameCount;
    if N > AMaxCallers then
      N := AMaxCallers;
    if Assigned(Frames) then
      for I := 0 to N - 1 do
        Result := Result + ' <- ' + DescribeCodeAddress(Frames[I]);
  except
    // Describing the place must never raise
  end;
end;

// ---> AUDIT FIX: Unhandled exceptions that reach the RTL (outside the LCL's own
// handler, e.g. in the final cleanup) are traced, then handled as before.
procedure TracerExceptProc(Obj: TObject; Addr: CodePointer; FrameCount: Longint;
  Frame: PCodePointer);
begin
  try
    if Obj is Exception then
      WriteShutDownTrace('Unhandled exception at $' + HexStr(Pointer(Addr)) + ': ' +
        Exception(Obj).ClassName + ': ' + Exception(Obj).Message, True)
    else if Assigned(Obj) then
      WriteShutDownTrace('Unhandled exception at $' + HexStr(Pointer(Addr)) + ': ' +
        Obj.ClassName, True)
    else
      WriteShutDownTrace('Unhandled exception at $' + HexStr(Pointer(Addr)), True);
  except
    // The tracer must never raise
  end;

  if Assigned(GOldExceptProc) then
    GOldExceptProc(Obj, Addr, FrameCount, Frame);
end;

initialization
  GOldExceptProc := ExceptProc;
  ExceptProc     := @TracerExceptProc;

finalization
  if ExceptProc = @TracerExceptProc then
    ExceptProc := GOldExceptProc;
  FreeAndNil(GBuffer);

end.
