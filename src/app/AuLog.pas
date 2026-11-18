unit AuLog;

{ ==============================================================================
  AulumicNS - AuLog
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The application log of AulumicNS, without a
  window: the lines ("hh:nn:ss - [INFO]  ..."), the separate error
  history, the purge of old lines (the startup block stays), the engine's
  log events (WM_AUDIO_ENGINE_LOG) and the saved log: at exit
  AulumicNSLog_<date>.txt when errors were logged, or AulumicNSLog.txt every
  time when "Always save the log" is on. The Log window (AuLogForm) shows
  Lines and listens to OnChanged. All calls on the UI thread.
  =============================================================================}

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Windows, uAppConsts;

const
  WM_AUDIO_ENGINE_LOG = WM_USER + 100;

type
  { the log events the audio engine posts }
  TAudioLogEvent = (
    alUnknown,
    alRecoveryTriggered,
    alWasapiInitFailed,
    alDeviceGhostTimeout,
    alBufferInvalidated,
    alEngineStarting,
    alEngineStopping,
    alGaplessLoadFailed,
    alWasapiFormatAccepted,
    alWasapiFormatDoP,
    alDeviceReopened,
    alStreamSource,          // source note for the next format line
    alPlayThreadStopTimeout, // see TAudioEngine.Stop (LParam = ms)
    // TPlayThread.CheckOutputHealth / LogStreamSummary (packed
    // 64-bit LParams, formatted in EngineMessage)
    alOutputDropout,
    alOutputStats,
    alOutputBufferShorter,   // LParam: asked ms (low 16 bits), taken ms (high 16 bits)
    alOutputNativeDsd,       // as alWasapiFormatDoP: native DSD over ASIO
    alOutputCloseSlow,       // LParam: ms Output.Close took (>= 500)
    alAsioTiedWindows        // LParam: tied to the main thread (low 16 bits), others (high 16 bits)
  );

  TLogEventDef = record
    LogText: string;
    NeedsFormat: Boolean;
    IsError: Boolean;
  end;

const
  AUDIO_LOG_DEFS: array[TAudioLogEvent] of TLogEventDef = (
    (LogText: 'Unknown Event'; NeedsFormat: False; IsError: False),
    (LogText: 'Engine Recovery Sequence Started.'; NeedsFormat: False; IsError: True),
    (LogText: 'Output Init Failed. %s (HRESULT: %x)'; NeedsFormat: True; IsError: True),
    (LogText: 'CRITICAL: DAC stopped requesting data (Ghost Timeout).'; NeedsFormat: False; IsError: True),
    (LogText: 'Output Buffer Invalidated. %s (HRESULT: %x)'; NeedsFormat: True; IsError: True),
    (LogText: 'Output Engine Started.'; NeedsFormat: False; IsError: False),
    (LogText: 'Output Engine Stopped.'; NeedsFormat: False; IsError: False),
    (LogText: 'Gapless Load Failed: The next track is invalid or corrupted.'; NeedsFormat: False; IsError: True),
    (LogText: 'Output to DAC (PCM)'; NeedsFormat: False; IsError: False),
    (LogText: 'Output to DAC (DoP)'; NeedsFormat: False; IsError: False),
    (LogText: 'Audio device available again, playback resumed (after %d ms).'; NeedsFormat: True; IsError: False),
    (LogText: 'Stream source'; NeedsFormat: False; IsError: False),
    (LogText: 'The previous track did not stop within %d ms (drive or audio driver not responding). It was set aside; playback goes on.'; NeedsFormat: True; IsError: True),
    (LogText: 'Dropout at about %s in the track: the output buffer ran empty (%d in this stream).'; NeedsFormat: True; IsError: True),
    (LogText: 'Stream closed: %d dropout(s), at least %s buffered ahead, longest buffer fill %s.'; NeedsFormat: True; IsError: False),
    (LogText: 'The device does not take a buffer of %d ms at this rate; it plays with %d ms.'; NeedsFormat: True; IsError: False),
    (LogText: 'Output to DAC (native DSD)'; NeedsFormat: False; IsError: False),
    (LogText: 'Closing the output took %d ms (the audio driver let go of the device slowly).'; NeedsFormat: True; IsError: False),
    (LogText: 'The ASIO driver made windows on threads of its own: %d tied to the main window, %d to its host window.'; NeedsFormat: True; IsError: False)
  );

type
  { TAppLog }

  TAppLog = class
  private
    FLines: TStringList;
    FErrors: TStringList;
    FHeadCount: Integer;
    FNextIsWarning: Boolean;
    FPendingSourceNote: string;
    FOnChanged: TNotifyEvent;
    procedure Changed;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AMessage: string; ShowDate: Boolean = False; IsError: Boolean = False);
    procedure AddTimed(const AMessage: string; StartTick: QWord; ShowDate: Boolean = False; IsError: Boolean = False);
    procedure AddWarning(const AMessage: string; ShowDate: Boolean = False);
    procedure AddDetail(const AMessage: string);
    procedure AddRawLine(const ALine: string);
    procedure MarkHead;
    procedure Clear;
    function HasErrors: Boolean;
    function SaveToFileEx(const AFileName: string; out AErrorMsg: string): Boolean;
    { a message of the audio engine (WM_AUDIO_ENGINE_LOG: event, code) }
    procedure EngineMessage(AEvent: PtrInt; ACode: PtrInt);
    function FormatOutputLine(AEvent: TAudioLogEvent; ACode: Cardinal): string;
    property Lines: TStringList read FLines;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

{ the procedures the other units call }
procedure AddLog(const AMessage: string; ShowDate: Boolean = False; IsError: Boolean = False); overload;
procedure AddLog(const AMessage: string; StartTick: QWord; ShowDate: Boolean = False; IsError: Boolean = False); overload;
procedure AddWarning(const AMessage: string; ShowDate: Boolean = False);
procedure AddLogDetail(const AMessage: string);
procedure MarkLogHead;
{ writes the log next to the data (only when errors were logged, by default) }
procedure SaveLog(Overwrite: Boolean = True; OnlyIfErrors: Boolean = True);
function AppLog: TAppLog;
procedure FreeAppLog;

implementation

uses
  uAppStrings, uAudioUtils, uOSUtils;

var
  GLog: TAppLog = nil;

function AppLog: TAppLog;
begin
  if GLog = nil then GLog := TAppLog.Create;
  Result := GLog;
end;

procedure FreeAppLog;
begin
  FreeAndNil(GLog);
end;

procedure AddLog(const AMessage: string; ShowDate: Boolean; IsError: Boolean);
begin
  AppLog.Add(AMessage, ShowDate, IsError);
end;

procedure AddLog(const AMessage: string; StartTick: QWord; ShowDate: Boolean; IsError: Boolean);
begin
  AppLog.AddTimed(AMessage, StartTick, ShowDate, IsError);
end;

procedure AddWarning(const AMessage: string; ShowDate: Boolean);
begin
  AppLog.AddWarning(AMessage, ShowDate);
end;

procedure AddLogDetail(const AMessage: string);
begin
  AppLog.AddDetail(AMessage);
end;

procedure MarkLogHead;
begin
  AppLog.MarkHead;
end;

procedure SaveLog(Overwrite: Boolean; OnlyIfErrors: Boolean);
var
  FileName, Err: string;
begin
  if GLog = nil then Exit;
  if OnlyIfErrors and not GLog.HasErrors then Exit;
  if Overwrite then FileName := AppLogDir + 'AulumicNSLog.txt'
  else FileName := AppLogDir + 'AulumicNSLog_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.txt';
  GLog.SaveToFileEx(FileName, Err);
end;

{ ---- TAppLog ---- }

constructor TAppLog.Create;
begin
  inherited Create;
  FLines := TStringList.Create;
  FErrors := TStringList.Create;
end;

destructor TAppLog.Destroy;
begin
  FLines.Free;
  FErrors.Free;
  inherited Destroy;
end;

procedure TAppLog.Changed;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TAppLog.MarkHead;
begin
  FHeadCount := FLines.Count;
end;

procedure TAppLog.Clear;
begin
  FLines.Clear;
  FHeadCount := 0;
  Changed;
end;

function TAppLog.HasErrors: Boolean;
begin
  Result := FErrors.Count > 0;
end;

{ width of 'hh:nn:ss - [INFO]  ' plus 2: the text starts below the message }
procedure TAppLog.AddDetail(const AMessage: string);
begin
  AddRawLine(StringOfChar(' ', 21) + AMessage);
end;

procedure TAppLog.AddRawLine(const ALine: string);
begin
  FLines.Add(ALine);
  Changed;
end;

procedure TAppLog.AddWarning(const AMessage: string; ShowDate: Boolean);
begin
  FNextIsWarning := True;
  try
    Add(AMessage, ShowDate, False);
  finally
    FNextIsWarning := False;
  end;
end;

procedure TAppLog.Add(const AMessage: string; ShowDate: Boolean; IsError: Boolean);
const
  MAX_LOG_LINES = 5000;      // about half a MB; the startup block is never purged
  PURGE_AMOUNT = 500;
  MAX_ERROR_LINES = 1000;
var
  Severity, Line: string;
begin
  if FLines.Count > MAX_LOG_LINES then
  begin
    if (FHeadCount < 0) or (FHeadCount > FLines.Count div 2) then FHeadCount := 0;
    while FLines.Count > MAX_LOG_LINES - PURGE_AMOUNT do FLines.Delete(FHeadCount);
    FLines.Insert(FHeadCount, LOG_PURGED_NOTICE);
  end;
  if ShowDate then FLines.Add(FormatDateTime('--- dddddd ---', Now));
  if IsError then Severity := '[ERROR] '
  else if FNextIsWarning then Severity := '[WARNING] '
  else Severity := '[INFO]  ';
  Line := FormatDateTime('hh:nn:ss', Now) + ' - ' + Severity + AMessage;
  FLines.Add(Line);
  if IsError then
  begin
    FErrors.Add(Line);
    if FErrors.Count > MAX_ERROR_LINES then FErrors.Delete(0);
  end;
  Changed;
end;

procedure TAppLog.AddTimed(const AMessage: string; StartTick: QWord; ShowDate: Boolean; IsError: Boolean);
var
  Ms, H, M, S, R: QWord;
  T: string;
begin
  Ms := GetTickCount64 - StartTick;
  H := Ms div 3600000;
  M := (Ms mod 3600000) div 60000;
  S := (Ms mod 60000) div 1000;
  R := Ms mod 1000;
  if H > 0 then T := Format('%s (duration: %dh %dm %ds)', [AMessage, H, M, S])
  else if M > 0 then T := Format('%s (duration: %dm %ds)', [AMessage, M, S])
  else if S > 0 then T := Format('%s (duration: %d.%.3ds)', [AMessage, S, R])
  else T := Format('%s (duration: %d ms)', [AMessage, R]);
  Add(T, ShowDate, IsError);
end;

function TAppLog.SaveToFileEx(const AFileName: string; out AErrorMsg: string): Boolean;
var
  Out_: TStringList;
begin
  Result := False;
  AErrorMsg := '';
  try
    Out_ := TStringList.Create;
    try
      if FLines.Count > 0 then
      begin
        Out_.Add('=== RECENT APPLICATION LOG ===');
        Out_.AddStrings(FLines);
      end;
      if FErrors.Count > 0 then
      begin
        Out_.Add('');
        Out_.Add('=== ACCUMULATED ERROR HISTORY ===');
        Out_.AddStrings(FErrors);
      end;
      if Out_.Count > 0 then
      begin
        ForceDirectories(ExtractFilePath(AFileName));
        Result := SaveStringsAtomic(Out_, AFileName, AErrorMsg);
      end
      else
        AErrorMsg := ERR_LOG_EMPTY;
    finally
      Out_.Free;
    end;
  except
    on E: Exception do AErrorMsg := E.Message;
  end;
end;

{ "Output to DAC: ..." from the packed code of the audio thread
  (rate shl 12 or container bits shl 6 or valid bits, see PackFormatCode) }
function TAppLog.FormatOutputLine(AEvent: TAudioLogEvent; ACode: Cardinal): string;
var
  Rate, Bits, Valid: Cardinal;
  BitsText, DsdName, MHz, Frac: string;
begin
  Rate := ACode shr 12;
  Bits := (ACode shr 6) and $3F;
  Valid := ACode and $3F;
  if (Valid = 0) or (Valid > Bits) then Valid := Bits;
  if AEvent in [alWasapiFormatDoP, alOutputNativeDsd] then
  begin
    { DoP carries 16 DSD bits per PCM frame: a 176.4 kHz carrier = DSD64
      (both DSD families, DsdRateName) }
    if Rate > 0 then DsdName := DsdRateName(Integer(Rate * 16))
    else DsdName := 'DSD';
    MHz := IntToStr((Rate * 16) div 1000000);
    Frac := IntToStr(((Rate * 16) mod 1000000) div 100);
    while Length(Frac) < 4 do Frac := '0' + Frac;
    while (Frac <> '') and (Frac[Length(Frac)] = '0') do Delete(Frac, Length(Frac), 1);
    if Frac <> '' then MHz := MHz + '.' + Frac;
    if AEvent = alOutputNativeDsd then Result := Format(FMT_LOG_OUT_NATIVE_DSD, [DsdName, MHz])
    else Result := Format(FMT_LOG_OUT_DOP, [DsdName, MHz]);
  end
  else
  begin
    if Valid < Bits then BitsText := Format(FMT_LOG_OUT_BITS_CONTAINER, [Integer(Valid), Integer(Bits)])
    else BitsText := Format(FMT_LOG_OUT_BITS, [Integer(Bits)]);
    Result := Format(FMT_LOG_OUT_PCM, [FormatRateKHz(Rate), BitsText, FPendingSourceNote]);
  end;
end;

procedure TAppLog.EngineMessage(AEvent: PtrInt; ACode: PtrInt);
var
  Ev: TAudioLogEvent;
  Def: TLogEventDef;
  Code: Cardinal;
  S, LeastText: string;
  Q, Secs, Least, Work: Int64;
begin
  if (AEvent >= Ord(Low(TAudioLogEvent))) and (AEvent <= Ord(High(TAudioLogEvent))) then
    Ev := TAudioLogEvent(AEvent)
  else
    Ev := alUnknown;
  Def := AUDIO_LOG_DEFS[Ev];
  { the source note is kept for the "Output to DAC" line that follows }
  if Ev = alStreamSource then
  begin
    Code := Cardinal(ACode and $FFFFFFFF);
    case Code and 3 of
      1: FPendingSourceNote := Format(FMT_LOG_OUT_RESAMPLED, [FormatRateKHz(Code shr 2)]);
      2: FPendingSourceNote := LOG_OUT_FROM_DSD;
    else
      FPendingSourceNote := '';
    end;
    Exit;
  end;
  if Ev in [alWasapiFormatAccepted, alWasapiFormatDoP, alOutputNativeDsd] then
  begin
    Add('[Audio Engine] ' + FormatOutputLine(Ev, Cardinal(ACode and $FFFFFFFF)), False, False);
    FPendingSourceNote := '';
    Exit;
  end;
  if Ev = alOutputBufferShorter then
  begin
    Code := Cardinal(ACode and $FFFFFFFF);
    AddWarning('[Audio Engine] ' + Format(Def.LogText, [Integer(Code and $FFFF), Integer(Code shr 16)]));
    Exit;
  end;
  if Ev = alAsioTiedWindows then
  begin
    Code := Cardinal(ACode and $FFFFFFFF);
    Add('[Audio Engine] ' + Format(Def.LogText, [Integer(Code and $FFFF), Integer(Code shr 16)]),
      False, (Code and $FFFF) > 0);
    Exit;
  end;
  { count (bits 0..19), the second in the track (20..39) }
  if Ev = alOutputDropout then
  begin
    Q := Int64(ACode);
    Secs := (Q shr 20) and $FFFFF;
    Add('[Audio Engine] ' + Format(Def.LogText, [Format('%d:%.2d', [Secs div 60, Secs mod 60]),
      Integer(Q and $FFFFF)]), False, True);
    Exit;
  end;
  { dropouts (0..19), least buffered ms + 1 (20..39; 0 = not
    known), the longest fill in 10 us (40..59); a stream with dropouts is
    logged as an error (the log file is written) }
  if Ev = alOutputStats then
  begin
    Q := Int64(ACode);
    Least := (Q shr 20) and $FFFFF;
    if Least = 0 then LeastText := '?' else LeastText := IntToStr(Least - 1) + ' ms';
    Work := (Q shr 40) and $FFFFF;
    Add('[Audio Engine] ' + Format(Def.LogText, [Integer(Q and $FFFFF), LeastText,
      Format('%d.%.2d ms', [Work div 100, Work mod 100])]), False, (Q and $FFFFF) > 0);
    Exit;
  end;
  if Def.NeedsFormat then
  begin
    if Ev in [alWasapiInitFailed, alBufferInvalidated] then
      S := Format(Def.LogText, [GetWasapiErrorString(HRESULT(ACode)), Int64(ACode and $FFFFFFFF)])
    else
      S := Format(Def.LogText, [ACode]);
  end
  else
    S := Def.LogText;
  Add('[Audio Engine] ' + S, False, Def.IsError);
end;

end.
