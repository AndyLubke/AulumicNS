unit uLastFmScraper;

{ ==============================================================================
  AulumicNS - uLastFmScraper
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Scrapes Artist info from the LastFM site and
  album info from TheaudioDB, LastFM and Wikipedia (in that order)

  ---> AulumicNS: copied from Aulumic; only the user agent changed. WinHTTP
  is part of Windows, so no DLL ships with the program.
  =============================================================================}

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, fpjson, jsonparser, Windows, SyncObjs,
  uSettingsManager;

type
  TLastFmBioEvent = procedure(const AArtistName, ABioText, AImagePath: string) of object;

  { TLastFmWorker (Artist Biography & Image) }

  // ---> AUDIT FIX: One permanent worker thread replaces the former
  // FreeOnTerminate TLastFmThread that was started for every artist click.
  //  * RequestArtist / Cancel are called on the UI thread. Every request gets a
  //    new generation number; a newer request (or Cancel) makes the running
  //    lookup stop at its next check and aborts its running HTTP request.
  //  * The worker never touches LCL objects. Results are queued in FResults
  //    (copies only) and delivered on the UI thread by DrainResults via
  //    TThread.Queue; results of an outdated generation are discarded.
  //  * All HTTP traffic uses WinHTTP (winhttp.dll, part of Windows) with
  //    resolve/connect/send/receive timeouts and without the Windows internet
  //    cache, so URLs containing the API key are never written to disk.
  //  * The owner frees the worker; Destroy aborts any running request and
  //    waits for the thread (no FreeOnTerminate, no Synchronize).
  TLastFmWorker = class(TThread)
  private
    FLock          : SyncObjs.TCriticalSection;
    FWakeEvent     : SyncObjs.TEvent;
    FGeneration    : Integer;      // Current request generation (Interlocked)
    FHasJob        : Boolean;      // Guarded by FLock
    FJobArtist     : string;       // Guarded by FLock
    FJobForce      : Boolean;      // Guarded by FLock
    FJobApiKey     : string;       // Guarded by FLock
    FJobGeneration : Integer;      // Guarded by FLock
    FResults       : TList;        // PLastFmResult items, guarded by FLock
    FActiveRequest : Pointer;      // Running WinHTTP request handle, guarded by FLock
    FSession       : Pointer;      // WinHTTP session, used by the worker only
    FCallback      : TLastFmBioEvent;

    function  IsCancelled(AGeneration: Integer): Boolean;
    procedure CloseActiveRequest;
    procedure PostResult(AGeneration: Integer; const AArtistName, ABioText, AImagePath: string);
    procedure DrainResults;
    function  HttpGet(const AUrl: string; AGeneration: Integer; AMaxBytes: Int64;
      ADest: TStream; ANoCache: Boolean; out AStatus: Integer): Boolean;
    procedure ProcessJob(const AArtistName: string; AForceRefresh: Boolean;
      const AApiKey: string; AGeneration: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(ACallback: TLastFmBioEvent);
    destructor Destroy; override;

    // UI thread only
    procedure RequestArtist(const AArtistName: string; AForceRefresh: Boolean);
    procedure Cancel;
  end;

// Utility exports
function SanitizeFolderName(const S: string): string;
function ExtractFirstArtist(const AArtist: string): string;
function CleanArtistSearchName(const AArtist: string): string;
function SimpleURLEncode(const S: string): string;
// ---> AUDIT FIX: MusicInfo folder (with trailing delimiter) of an artist, in the
// same order the scraper uses its caches. The artist panel saves edited bios and
// own pictures there, so they end up in the folder that is shown.
function ResolveArtistCacheDir(const AArtist: string): string;

implementation

uses
  uAppStrings, uAppConsts, uMetaUtils, uOSUtils;

// =============================================================================
// ---> AUDIT FIX: Minimal WinHTTP declarations (winhttp.dll is a standard
// Windows system DLL; FPC ships no import unit for it).
// =============================================================================
type
  HINTERNET = Pointer;

  {$PACKRECORDS C}
  TAL_URL_COMPONENTS = record
    dwStructSize      : DWORD;
    lpszScheme        : PWideChar;
    dwSchemeLength    : DWORD;
    nScheme           : Integer;
    lpszHostName      : PWideChar;
    dwHostNameLength  : DWORD;
    nPort             : Word;
    lpszUserName      : PWideChar;
    dwUserNameLength  : DWORD;
    lpszPassword      : PWideChar;
    dwPasswordLength  : DWORD;
    lpszUrlPath       : PWideChar;
    dwUrlPathLength   : DWORD;
    lpszExtraInfo     : PWideChar;
    dwExtraInfoLength : DWORD;
  end;
  {$PACKRECORDS DEFAULT}

const
  WINHTTP_DLL                         = 'winhttp.dll';
  AL_WINHTTP_ACCESS_TYPE_DEFAULT_PROXY   = 0;
  AL_WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4;   // Windows 8.1+ (system proxy settings)
  AL_WINHTTP_FLAG_SECURE              = $00800000;
  AL_INTERNET_SCHEME_HTTPS            = 2;
  AL_WINHTTP_QUERY_STATUS_CODE        = 19;
  AL_WINHTTP_QUERY_FLAG_NUMBER        = $20000000;

  // Timeouts (ms)
  HTTP_TIMEOUT_RESOLVE = 5000;
  HTTP_TIMEOUT_CONNECT = 5000;
  HTTP_TIMEOUT_SEND    = 10000;
  HTTP_TIMEOUT_RECEIVE = 10000;

  // Response size limits
  MAX_JSON_BYTES  = 4 * BYTES_PER_MB;
  MAX_IMAGE_BYTES = 25 * BYTES_PER_MB;

  HTTP_USER_AGENT = 'Aulumic (Windows audio player)';  // ---> AulumicNS: own name

function AL_WinHttpOpen(pszAgentW: PWideChar; dwAccessType: DWORD; pszProxyW,
  pszProxyBypassW: PWideChar; dwFlags: DWORD): HINTERNET; stdcall;
  external WINHTTP_DLL name 'WinHttpOpen';
function AL_WinHttpConnect(hSession: HINTERNET; pswzServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): HINTERNET; stdcall;
  external WINHTTP_DLL name 'WinHttpConnect';
function AL_WinHttpOpenRequest(hConnect: HINTERNET; pwszVerb, pwszObjectName,
  pwszVersion, pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer;
  dwFlags: DWORD): HINTERNET; stdcall;
  external WINHTTP_DLL name 'WinHttpOpenRequest';
function AL_WinHttpSendRequest(hRequest: HINTERNET; lpszHeaders: PWideChar;
  dwHeadersLength: DWORD; lpOptional: Pointer; dwOptionalLength,
  dwTotalLength: DWORD; dwContext: PtrUInt): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpSendRequest';
function AL_WinHttpReceiveResponse(hRequest: HINTERNET; lpReserved: Pointer): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpReceiveResponse';
function AL_WinHttpQueryHeaders(hRequest: HINTERNET; dwInfoLevel: DWORD;
  pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
  lpdwIndex: Pointer): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpQueryHeaders';
function AL_WinHttpQueryDataAvailable(hRequest: HINTERNET;
  var lpdwNumberOfBytesAvailable: DWORD): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpQueryDataAvailable';
function AL_WinHttpReadData(hRequest: HINTERNET; lpBuffer: Pointer;
  dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpReadData';
function AL_WinHttpSetTimeouts(hInternet: HINTERNET; nResolveTimeout,
  nConnectTimeout, nSendTimeout, nReceiveTimeout: Integer): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpSetTimeouts';
function AL_WinHttpCloseHandle(hInternet: HINTERNET): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpCloseHandle';
function AL_WinHttpCrackUrl(pwszUrl: PWideChar; dwUrlLength: DWORD;
  dwFlags: DWORD; var lpUrlComponents: TAL_URL_COMPONENTS): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpCrackUrl';

type
  PLastFmResult = ^TLastFmResult;
  TLastFmResult = record
    Generation : Integer;
    ArtistName : string;
    BioText    : string;
    ImagePath  : string;
  end;

{ --- Global Utilities --- }

function ExtractFirstArtist(const AArtist: string): string;
var
  p: integer;
begin
  Result := Trim(AArtist);
  p := Pos(';', Result);
  if p > 0 then
    Result := Trim(Copy(Result, 1, p - 1));

  if Result = '' then
    Result := LBL_UNKNOWN_ARTIST;
end;

// =============================================================================
// Cleans performer strings:
// 1. Strips everything between (), [], and {} including the brackets.
// 2. Strips '-' (or en-dash / em-dash) and everything behind it.
// =============================================================================
function CleanArtistSearchName(const AArtist: string): string;
var
  I, OutLen, Depth, DashPos: integer;
  WorkStr: string;
  C: Char;
begin
  WorkStr := Trim(AArtist);
  if WorkStr = '' then
    Exit('');

  // 1. Strip everything between (), [], and {} and collapse double spaces in one pass
  SetLength(Result, Length(WorkStr));
  OutLen      := 0;
  Depth       := 0;

  for I := 1 to Length(WorkStr) do
  begin
    C := WorkStr[I];
    case C of
      '(', '[', '{':
        begin
          Inc(Depth);
        end;
      ')', ']', '}':
        begin
          if Depth > 0 then
            Dec(Depth);
        end;
      else
        if Depth = 0 then
        begin
          if (C = ' ') and ((OutLen = 0) or (Result[OutLen] = ' ')) then
            Continue;
          Inc(OutLen);
          Result[OutLen] := C;
        end;
    end;
  end;

  while (OutLen > 0) and (Result[OutLen] = ' ') do
    Dec(OutLen);
  SetLength(Result, OutLen);

  if Result = '' then
    Exit('');

  // Only run UTF-8 dash replacements if multi-byte dash prefix exists
  if Pos(#$E2#$80, Result) > 0 then
  begin
    Result := StringReplace(Result, #$E2#$80#$93, ' - ', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$94, ' - ', [rfReplaceAll]);
  end;

  // 2. Strip '- <instrument>' suffix after the name
  // ---> AUDIT FIX: Only a spaced dash separates a suffix ("Jean-Luc Ponty -
  // Violin"). The former fallback to an unspaced '-' cut hyphenated names
  // ("Jay-Z" -> "Jay", "a-ha" -> "a", "Wu-Tang Clan" -> "Wu"), so they were
  // looked up and cached as another artist.
  DashPos := Pos(' -', Result);
  if DashPos = 0 then
    DashPos := Pos('- ', Result);

  if DashPos > 0 then
    Result := Trim(Copy(Result, 1, DashPos - 1));
end;

function SimpleURLEncode(const S: string): string;
const
  HEX_CHARS: array[0..15] of Char = '0123456789ABCDEF';
var
  I, OutIdx: integer;
  C: Char;
begin
  if S = '' then
    Exit('');

  // Single-pass pre-allocated buffer
  SetLength(Result, Length(S) * 3);
  OutIdx := 0;

  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then
    begin
      Inc(OutIdx);
      Result[OutIdx] := C;
    end
    else
    begin
      Inc(OutIdx);
      Result[OutIdx] := '%';
      Inc(OutIdx);
      Result[OutIdx] := HEX_CHARS[Ord(C) shr 4];
      Inc(OutIdx);
      Result[OutIdx] := HEX_CHARS[Ord(C) and $0F];
    end;
  end;

  SetLength(Result, OutIdx);
end;

function StripHTML(const S: string): string;
var
  I, OutLen, ReadMorePos: integer;
  InTag: boolean;
begin
  if S = '' then
    Exit('');

  // Single-pass buffer allocation instead of char-by-char reallocation
  SetLength(Result, Length(S));
  OutLen := 0;
  InTag  := False;

  for I := 1 to Length(S) do
  begin
    if S[I] = '<' then
      InTag := True
    else if S[I] = '>' then
      InTag := False
    else if not InTag then
    begin
      Inc(OutLen);
      Result[OutLen] := S[I];
    end;
  end;

  SetLength(Result, OutLen);

  // Only scan for HTML entities if '&' is actually present
  if Pos('&', Result) > 0 then
  begin
    Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
    Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
    Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
    Result := StringReplace(Result, '&#39;', '''', [rfReplaceAll]);
    Result := StringReplace(Result, '&nbsp;', ' ', [rfReplaceAll]);
    Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
    Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  end;

  ReadMorePos := Pos('Read more on Last.fm', Result);
  if ReadMorePos > 0 then
    SetLength(Result, ReadMorePos - 1);

  Result := Trim(Result);
end;

function SanitizeFolderName(const S: string): string;
var
  I: integer;
begin
  Result := Trim(S);
  for I := Length(Result) downto 1 do
  begin
    if Result[I] in [#0..#31, '<', '>', ':', '"', '/', '\', '|', '?', '*'] then
      Result[I] := '_';
  end;

  // Windows silently strips trailing periods and spaces from directory
  // names (breaking cache paths for artists like "R.E.M." or "St. Vincent").
  while (Length(Result) > 0) and (Result[Length(Result)] in ['.', ' ']) do
    Result[Length(Result)] := '_';

  if Result = '' then
    Result := '_';

  // ---> AUDIT FIX: Windows cannot create a folder named after a device
  // ("Nul", "Aux", "Con.Funk", ...). A leading underscore makes the name legal;
  // such folders could never be created before, so no existing cache is lost.
  if IsReservedDeviceName(Result) then
    Result := '_' + Result;
end;

function ResolveArtistCacheDir(const AArtist: string): string;
var
  FirstArtist, Cleaned, PrimaryDir, FallbackDir: string;
begin
  FirstArtist := ExtractFirstArtist(AArtist);
  Cleaned     := CleanArtistSearchName(FirstArtist);

  if (Cleaned = '') or (Cleaned = FirstArtist) then
    Exit(AppMusicInfoDir + SanitizeFolderName(FirstArtist) + DirectorySeparator);

  // Same priority as ProcessJob: cleaned name first, the full name as fallback
  PrimaryDir  := AppMusicInfoDir + SanitizeFolderName(Cleaned) + DirectorySeparator;
  FallbackDir := AppMusicInfoDir + SanitizeFolderName(FirstArtist) + DirectorySeparator;

  if FileExists(PrimaryDir + FILE_ARTIST_BIO) then
    Result := PrimaryDir
  else if FileExists(FallbackDir + FILE_ARTIST_BIO) then
    Result := FallbackDir
  else if FileExists(PrimaryDir + FILE_ARTIST_IMAGE) then
    Result := PrimaryDir
  else if FileExists(FallbackDir + FILE_ARTIST_IMAGE) then
    Result := FallbackDir
  else
    Result := PrimaryDir;   // where a new lookup saves first
end;

{ TLastFmWorker }

constructor TLastFmWorker.Create(ACallback: TLastFmBioEvent);
begin
  // Create suspended so every field is initialized before Execute runs
  inherited Create(True);
  FreeOnTerminate := False;
  Priority        := tpLower;

  FLock          := SyncObjs.TCriticalSection.Create;
  FWakeEvent     := SyncObjs.TEvent.Create(nil, False, False, '');  // auto-reset
  FResults       := TList.Create;
  FGeneration    := 0;
  FHasJob        := False;
  FJobGeneration := 0;
  FActiveRequest := nil;
  FSession       := nil;
  FCallback      := ACallback;

  Start;
end;

destructor TLastFmWorker.Destroy;
var
  I: Integer;
begin
  // Invalidate every pending result, abort a running request, wake and wait
  FCallback := nil;
  InterlockedIncrement(FGeneration);
  Terminate;
  CloseActiveRequest;
  if Assigned(FWakeEvent) then
    FWakeEvent.SetEvent;
  WaitFor;
  TThread.RemoveQueuedEvents(Self);

  if Assigned(FResults) then
  begin
    for I := 0 to FResults.Count - 1 do
      Dispose(PLastFmResult(FResults[I]));
    FResults.Free;
  end;

  FWakeEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLastFmWorker.RequestArtist(const AArtistName: string; AForceRefresh: Boolean);
var
  Gen    : Integer;
  ApiKey : string;
begin
  // Read the setting here, on the UI thread (never inside the worker)
  ApiKey := '';
  if Assigned(AppSettings) then
    ApiKey := Trim(AppSettings.Data.LastFmApiKey);
  UniqueString(ApiKey);

  Gen := InterlockedIncrement(FGeneration);

  FLock.Enter;
  try
    FJobArtist := AArtistName;
    UniqueString(FJobArtist);
    FJobForce      := AForceRefresh;
    FJobApiKey     := ApiKey;
    FJobGeneration := Gen;
    FHasJob        := True;
  finally
    FLock.Leave;
  end;

  // Abort the download of an older request right away instead of waiting
  // for it to finish or time out
  CloseActiveRequest;
  FWakeEvent.SetEvent;
end;

procedure TLastFmWorker.Cancel;
begin
  InterlockedIncrement(FGeneration);
  FLock.Enter;
  try
    FHasJob := False;
  finally
    FLock.Leave;
  end;
  CloseActiveRequest;
end;

function TLastFmWorker.IsCancelled(AGeneration: Integer): Boolean;
begin
  Result := Terminated or (InterlockedCompareExchange(FGeneration, 0, 0) <> AGeneration);
end;

// Any thread. Closing a WinHTTP request handle from another thread is the
// documented way to abort a synchronous WinHTTP call that is in progress.
procedure TLastFmWorker.CloseActiveRequest;
begin
  if not Assigned(FLock) then
    Exit;
  FLock.Enter;
  try
    if FActiveRequest <> nil then
    begin
      AL_WinHttpCloseHandle(FActiveRequest);
      FActiveRequest := nil;
    end;
  finally
    FLock.Leave;
  end;
end;

// Worker thread: store a copy of the result and ask the UI thread to drain
procedure TLastFmWorker.PostResult(AGeneration: Integer;
  const AArtistName, ABioText, AImagePath: string);
var
  R: PLastFmResult;
begin
  if IsCancelled(AGeneration) then
    Exit;

  New(R);
  R^.Generation := AGeneration;
  R^.ArtistName := AArtistName;
  R^.BioText    := ABioText;
  R^.ImagePath  := AImagePath;
  UniqueString(R^.ArtistName);
  UniqueString(R^.BioText);
  UniqueString(R^.ImagePath);

  FLock.Enter;
  try
    FResults.Add(R);
  finally
    FLock.Leave;
  end;

  TThread.Queue(Self, @DrainResults);
end;

// UI thread: deliver every queued result that still belongs to the current
// request. Items are removed one at a time, so an exception raised by the
// callback can never leak the remaining items (they are delivered by the
// next queued DrainResults call or disposed in Destroy).
procedure TLastFmWorker.DrainResults;
var
  R          : PLastFmResult;
  Gen        : Integer;
  AName      : string;
  ABio       : string;
  AImage     : string;
  CurrentGen : Integer;
  Handler    : TLastFmBioEvent;
begin
  while True do
  begin
    R := nil;
    FLock.Enter;
    try
      if FResults.Count > 0 then
      begin
        R := PLastFmResult(FResults[0]);
        FResults.Delete(0);
      end;
    finally
      FLock.Leave;
    end;

    if R = nil then
      Break;

    Gen    := R^.Generation;
    AName  := R^.ArtistName;
    ABio   := R^.BioText;
    AImage := R^.ImagePath;
    Dispose(R);

    CurrentGen := InterlockedCompareExchange(FGeneration, 0, 0);
    Handler    := FCallback;
    if (Gen = CurrentGen) and (not Terminated) and
       (not Application.Terminated) and Assigned(Handler) then
      Handler(AName, ABio, AImage);
  end;
end;

// Worker thread: GET AUrl into ADest. Returns True when the complete body was
// received (any HTTP status; see AStatus). Aborts on cancellation, timeouts,
// or when the body exceeds AMaxBytes.
function TLastFmWorker.HttpGet(const AUrl: string; AGeneration: Integer;
  AMaxBytes: Int64; ADest: TStream; ANoCache: Boolean; out AStatus: Integer): Boolean;
const
  VERB_GET: UnicodeString = 'GET';
  NO_CACHE_HEADERS: UnicodeString = 'Cache-Control: no-cache'#13#10'Pragma: no-cache'#13#10;
var
  WUrl, Host, UrlPath, Extra, ObjName : UnicodeString;
  UC          : TAL_URL_COMPONENTS;
  HConnect    : HINTERNET;
  HRequest    : HINTERNET;
  Flags       : DWORD;
  StatusCode  : DWORD;
  StatusLen   : DWORD;
  Avail, Got  : DWORD;
  ReadNow     : DWORD;
  Total       : Int64;
  SendOK      : BOOL;
  Buf         : array[0..16383] of Byte;
begin
  Result  := False;
  AStatus := 0;
  if (FSession = nil) or (AUrl = '') or (not Assigned(ADest)) or IsCancelled(AGeneration) then
    Exit;

  WUrl := UTF8Decode(AUrl);

  UC := Default(TAL_URL_COMPONENTS);
  UC.dwStructSize      := SizeOf(UC);
  UC.dwSchemeLength    := DWORD($FFFFFFFF);
  UC.dwHostNameLength  := DWORD($FFFFFFFF);
  UC.dwUrlPathLength   := DWORD($FFFFFFFF);
  UC.dwExtraInfoLength := DWORD($FFFFFFFF);
  if not AL_WinHttpCrackUrl(PWideChar(WUrl), 0, 0, UC) then
    Exit;

  SetString(Host,    UC.lpszHostName,  UC.dwHostNameLength);
  SetString(UrlPath, UC.lpszUrlPath,   UC.dwUrlPathLength);
  SetString(Extra,   UC.lpszExtraInfo, UC.dwExtraInfoLength);
  ObjName := UrlPath + Extra;
  if ObjName = '' then
    ObjName := '/';
  if Host = '' then
    Exit;

  Flags := 0;
  if UC.nScheme = AL_INTERNET_SCHEME_HTTPS then
    Flags := AL_WINHTTP_FLAG_SECURE;

  HConnect := AL_WinHttpConnect(FSession, PWideChar(Host), UC.nPort, 0);
  if HConnect = nil then
    Exit;
  try
    HRequest := AL_WinHttpOpenRequest(HConnect, PWideChar(VERB_GET), PWideChar(ObjName),
                  nil, nil, nil, Flags);
    if HRequest = nil then
      Exit;

    // Publish the handle so Cancel / RequestArtist / Destroy can abort it
    FLock.Enter;
    try
      FActiveRequest := HRequest;
    finally
      FLock.Leave;
    end;

    try
      if IsCancelled(AGeneration) then
        Exit;

      if ANoCache then
        SendOK := AL_WinHttpSendRequest(HRequest, PWideChar(NO_CACHE_HEADERS),
                    DWORD($FFFFFFFF), nil, 0, 0, 0)
      else
        SendOK := AL_WinHttpSendRequest(HRequest, nil, 0, nil, 0, 0, 0);

      if (not SendOK) or IsCancelled(AGeneration) then
        Exit;
      if not AL_WinHttpReceiveResponse(HRequest, nil) then
        Exit;

      StatusCode := 0;
      StatusLen  := SizeOf(StatusCode);
      if AL_WinHttpQueryHeaders(HRequest,
           AL_WINHTTP_QUERY_STATUS_CODE or AL_WINHTTP_QUERY_FLAG_NUMBER,
           nil, @StatusCode, StatusLen, nil) then
        AStatus := Integer(StatusCode);

      Total := 0;
      repeat
        if IsCancelled(AGeneration) then
          Exit;

        Avail := 0;
        if not AL_WinHttpQueryDataAvailable(HRequest, Avail) then
          Exit;
        if Avail = 0 then
          Break;   // End of body

        while Avail > 0 do
        begin
          ReadNow := Avail;
          if ReadNow > SizeOf(Buf) then
            ReadNow := SizeOf(Buf);

          Got := 0;
          if not AL_WinHttpReadData(HRequest, @Buf[0], ReadNow, Got) then
            Exit;
          if Got = 0 then
            Break;

          Inc(Total, Got);
          if Total > AMaxBytes then
            Exit;

          ADest.WriteBuffer(Buf[0], Got);
          Dec(Avail, Got);
        end;
      until False;

      Result := not IsCancelled(AGeneration);
    finally
      // Close the request unless another thread already closed it to abort it
      FLock.Enter;
      try
        if FActiveRequest = HRequest then
        begin
          FActiveRequest := nil;
          AL_WinHttpCloseHandle(HRequest);
        end;
      finally
        FLock.Leave;
      end;
    end;
  finally
    AL_WinHttpCloseHandle(HConnect);
  end;
end;

procedure TLastFmWorker.Execute;
var
  HasJob   : Boolean;
  JArtist  : string;
  JForce   : Boolean;
  JApiKey  : string;
  JGen     : Integer;
begin
  // One WinHTTP session for the lifetime of the worker. Prefer the system
  // proxy settings (Windows 8.1+), fall back to the WinHTTP default.
  FSession := AL_WinHttpOpen(PWideChar(UnicodeString(HTTP_USER_AGENT)),
                AL_WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0);
  if FSession = nil then
    FSession := AL_WinHttpOpen(PWideChar(UnicodeString(HTTP_USER_AGENT)),
                  AL_WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0);
  if FSession <> nil then
    AL_WinHttpSetTimeouts(FSession, HTTP_TIMEOUT_RESOLVE, HTTP_TIMEOUT_CONNECT,
      HTTP_TIMEOUT_SEND, HTTP_TIMEOUT_RECEIVE);

  try
    while not Terminated do
    begin
      FWakeEvent.WaitFor(INFINITE);
      if Terminated then
        Break;

      FLock.Enter;
      try
        HasJob  := FHasJob;
        JArtist := FJobArtist;
        JForce  := FJobForce;
        JApiKey := FJobApiKey;
        JGen    := FJobGeneration;
        UniqueString(JArtist);
        UniqueString(JApiKey);
        FHasJob := False;
      finally
        FLock.Leave;
      end;

      if (not HasJob) or IsCancelled(JGen) then
        Continue;

      // One failing lookup must never stop the worker
      try
        ProcessJob(JArtist, JForce, JApiKey, JGen);
      except
        // Swallow: the panel keeps its previous content
      end;
      // A request that arrived meanwhile left FWakeEvent signaled (auto-reset),
      // so the loop picks it up immediately.
    end;
  finally
    if FSession <> nil then
    begin
      AL_WinHttpCloseHandle(FSession);
      FSession := nil;
    end;
  end;
end;

// Worker thread. The lookup logic is unchanged from the former
// TLastFmThread.Execute; only cancellation (IsCancelled instead of
// Terminated), result delivery (PostResult instead of Synchronize) and the
// HTTP transport (WinHTTP instead of UrlMon / fphttpclient) differ.
procedure TLastFmWorker.ProcessJob(const AArtistName: string; AForceRefresh: Boolean;
  const AApiKey: string; AGeneration: Integer);
var
  ArtistDir, JsonFile: string;
  FirstArtist, CleanedArtist, PrimaryArtist, FallbackArtist, ActiveArtist: string;
  ResultText, ResultImagePath: string;
  ImageFound: boolean;
  BioWasAlreadyCached: boolean;
  NeedImageFetch: boolean;
  ProgressImage: string;
  KeepUserBio, UserImage: boolean;

  function Cancelled: boolean;
  begin
    Result := IsCancelled(AGeneration);
  end;

  function IsValidDownloadedFile(const AFilePath: string; MinBytes: Int64 = 1024): boolean;
  var
    SearchRec: TSearchRec;
  begin
    Result := False;
    try
      if FindFirst(AFilePath, faAnyFile, SearchRec) = 0 then
      begin
        try
          Result := ((SearchRec.Attr and faDirectory) = 0) and (SearchRec.Size >= MinBytes);
        finally
          SysUtils.FindClose(SearchRec);
        end;
      end;
    except
      Result := False;
    end;
  end;

  // Returns the response body. When AcceptAnyStatus is False only HTTP 200
  // bodies are returned (the Last.fm API sends its JSON error messages with
  // 4xx codes, so that caller accepts any status).
  function DownloadHTTPSJSON(const AUrl: string; AcceptAnyStatus: boolean = False): string;
  var
    SS: TStringStream;
    Status: Integer;
  begin
    Result := '';
    if Cancelled then
      Exit;

    SS := TStringStream.Create('');
    try
      try
        if HttpGet(AUrl, AGeneration, MAX_JSON_BYTES, SS, AForceRefresh, Status) and
           (AcceptAnyStatus or (Status = 200)) and (not Cancelled) then
          Result := SS.DataString;
      except
        Result := '';
      end;
    finally
      SS.Free;
    end;
  end;

  // ===========================================================================
  // Fast Disk-Cache Check (Zero Network I/O)
  // Checks if MusicInfo\<ACandidateName>\artist_bio.txt already exists on disk.
  // ===========================================================================
  function TryLoadCachedArtistBio(const ACandidateName: string): boolean;
  var
    CandidateDir, CandidateJson, LoadedBio: string;
    SL: TStringList;
  begin
    Result := False;
    if Cancelled or (ACandidateName = '') then
      Exit;

    CandidateDir  := AppMusicInfoDir + SanitizeFolderName(ACandidateName) + DirectorySeparator;
    CandidateJson := CandidateDir + FILE_ARTIST_BIO;

    if not FileExists(CandidateJson) then
      Exit;

    LoadedBio := '';
    SL        := TStringList.Create;
    try
      try
        SL.LoadFromFile(CandidateJson, TEncoding.UTF8);
        LoadedBio := Trim(SL.Text);
      except
        LoadedBio := '';
      end;
    finally
      SL.Free;
    end;

    if LoadedBio <> '' then
    begin
      ActiveArtist        := ACandidateName;
      ArtistDir           := CandidateDir;
      JsonFile            := CandidateJson;
      ResultImagePath     := CandidateDir + FILE_ARTIST_IMAGE;
      BioWasAlreadyCached := True;
      ResultText          := LoadedBio;
      Result              := True;
    end;
  end;

  // Uses &autocorrect=1 for Last.fm spelling/diacritic resolution
  function TryFetchLastFmBio(const ASearchArtist: string; out AErrorMsg: string): string;
  var
    JSONRaw: string;
    JSONData, TempNode, ArtistNode, BioNode, ContentNode: TJSONData;
  begin
    Result    := '';
    AErrorMsg := '';
    if Cancelled or (ASearchArtist = '') then
      Exit;

    // HTTPS, so the API key is never sent in clear text
    JSONRaw := '';
    try
      JSONRaw := DownloadHTTPSJSON('https://ws.audioscrobbler.com/2.0/?method=artist.getinfo&artist=' +
        SimpleURLEncode(ASearchArtist) + '&autocorrect=1&api_key=' + SimpleURLEncode(AApiKey) +
        '&format=json', True);
    except
      on E: Exception do
      begin
        AErrorMsg := ERR_LASTFM_NETWORK_PREFIX + E.Message;
        JSONRaw   := '';
      end;
      else
        JSONRaw := '';
    end;

    if (JSONRaw = '') and (AErrorMsg = '') and (not Cancelled) then
      AErrorMsg := ERR_LASTFM_NETWORK_PREFIX + ERR_LASTFM_NO_RESPONSE;

    if (JSONRaw = '') or Cancelled then
      Exit;

    try
      JSONData := GetJSON(JSONRaw);
      try
        if Assigned(JSONData) then
        begin
          TempNode := JSONData.FindPath('error');
          // ---> ADDED: 10 = invalid API key, 26 = suspended (blocked) key:
          // a fixed Aulumic text, recognised (and logged once) by the panel
          if Assigned(TempNode) and (TempNode.JSONType = jtNumber) and
             ((TempNode.AsInteger = 10) or (TempNode.AsInteger = 26)) then
            AErrorMsg := ERR_LASTFM_KEY_REJECTED
          else if Assigned(TempNode) then
          begin
            TempNode := JSONData.FindPath('message');
            if Assigned(TempNode) and (TempNode.JSONType = jtString) then
              AErrorMsg := ERR_LASTFM_API_PREFIX + TempNode.AsString
            else
              AErrorMsg := ERR_LASTFM_GENERIC;
          end
          else
          begin
            ArtistNode := JSONData.FindPath('artist');
            if Assigned(ArtistNode) and (ArtistNode.JSONType = jtObject) then
            begin
              BioNode := ArtistNode.FindPath('bio');
              if Assigned(BioNode) and (BioNode.JSONType = jtObject) then
              begin
                ContentNode := BioNode.FindPath('content');
                if Assigned(ContentNode) and (ContentNode.JSONType = jtString) then
                begin
                  if Trim(ContentNode.AsString) <> '' then
                    Result := StripHTML(ContentNode.AsString);
                end;
              end;
            end;
          end;
        end;
      finally
        JSONData.Free;
      end;
    except
      on E: Exception do
        AErrorMsg := ERR_LASTFM_PARSE_PREFIX + E.Message;
      else
        ;
    end;
  end;

  function TryFetchAndSaveArtistBio(const ACandidateName: string): boolean;
  var
    SL: TStringList;
    CachedBioText, FetchedBio, ErrorText: string;
  begin
    Result        := False;
    CachedBioText := '';
    FetchedBio    := '';
    ErrorText     := '';

    if Cancelled or (ACandidateName = '') then
      Exit;

    ActiveArtist        := ACandidateName;
    ArtistDir           := AppMusicInfoDir + SanitizeFolderName(ACandidateName) + DirectorySeparator;
    JsonFile            := ArtistDir + FILE_ARTIST_BIO;
    ResultImagePath     := ArtistDir + FILE_ARTIST_IMAGE;
    BioWasAlreadyCached := FileExists(JsonFile);

    try
      if BioWasAlreadyCached then
      begin
        SL := TStringList.Create;
        try
          try
            SL.LoadFromFile(JsonFile, TEncoding.UTF8);
            CachedBioText := Trim(SL.Text);
          except
            CachedBioText := '';
          end;
        finally
          SL.Free;
        end;
      end;

      if not Cancelled then
      begin
        if AApiKey = '' then
        begin
          ResultText := ERR_LASTFM_MISSING_API_KEY;
          Exit;
        end;

        FetchedBio := TryFetchLastFmBio(ACandidateName, ErrorText);

        if (FetchedBio <> '') and (not Cancelled) then
        begin
          ResultText := FetchedBio;
          Result     := True;

          if not DirectoryExists(ArtistDir) then
            ForceDirectories(ArtistDir);

          // Skip the cache write when this lookup was cancelled, and write it
          // atomically so a reader never sees a half-written bio file
          if not Cancelled then
          begin
            SL := TStringList.Create;
            try
              try
                SL.Text := ResultText;
                if SaveStringsAtomic(SL, JsonFile, TEncoding.UTF8) then
                  SysUtils.DeleteFile(ArtistDir + FILE_ARTIST_BIO_USER);
              except
              end;
            finally
              SL.Free;
            end;
          end;
        end
        else if CachedBioText <> '' then
        begin
          ResultText := CachedBioText;
          Result     := True;
        end
        else if ErrorText <> '' then
        begin
          ResultText := ErrorText;
        end;
      end;
    except
      on E: Exception do
      begin
        if CachedBioText <> '' then
        begin
          ResultText := CachedBioText;
          Result     := True;
        end
        else
          ResultText := ERR_LASTFM_RESOLVE_PREFIX + E.Message;
      end
      else
      begin
        if CachedBioText <> '' then
        begin
          ResultText := CachedBioText;
          Result     := True;
        end;
      end;
    end;
  end;

  function DownloadAndProcessImage(const AUrl: string): boolean;
  var
    TempImgPath : string;
    FS          : TFileStream;
    Status      : Integer;
    Downloaded  : boolean;
  begin
    Result := False;
    if (AUrl = '') or Cancelled then
      Exit;

    if not DirectoryExists(ArtistDir) then
      ForceDirectories(ArtistDir);

    TempImgPath := ResultImagePath + '.' + IntToStr(GetCurrentThreadId) + '.tmp.jpg';
    SysUtils.DeleteFile(TempImgPath);

    try
      Downloaded := False;
      Status     := 0;
      try
        FS := TFileStream.Create(TempImgPath, fmCreate);
        try
          Downloaded := HttpGet(AUrl, AGeneration, MAX_IMAGE_BYTES, FS, AForceRefresh, Status);
        finally
          FS.Free;
        end;
      except
        Downloaded := False;
      end;

      if Downloaded and (Status = 200) and (not Cancelled) and
         IsValidDownloadedFile(TempImgPath, 2048) then
      begin
        // Atomic replace (no delete-then-rename gap)
        if DownscaleImageFile(TempImgPath, 800) and (not Cancelled) then
          Result := CommitAtomicFile(TempImgPath, ResultImagePath, False);
        // A downloaded picture is not the user's own
        if Result then
          SysUtils.DeleteFile(ArtistDir + FILE_ARTIST_IMAGE_USER);
      end;
    finally
      if FileExists(TempImgPath) then
        SysUtils.DeleteFile(TempImgPath);
    end;
  end;

  // ---> AUDIT FIX: Asks Wikidata whether an entry is a music artist, by the
  // presence of a MusicBrainz artist ID (property P434). Language independent:
  // "Biosphere" (the ecological term) has none, Biosphere the musician has one.
  // Returns 1 = music artist, 0 = not a music artist, -1 = unknown (no answer).
  function WikidataIsMusicArtist(const AItemID: string): Integer;
  var
    I: Integer;
    JSONResp: string;
    WdJSON, ClaimsNode, P434Node: TJSONData;
  begin
    Result := -1;
    if Cancelled or (Length(AItemID) < 2) or (UpCase(AItemID[1]) <> 'Q') then
      Exit;
    for I := 2 to Length(AItemID) do
      if not (AItemID[I] in ['0'..'9']) then
        Exit;

    JSONResp := DownloadHTTPSJSON('https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=' +
      AItemID + '&property=P434&format=json');
    if (JSONResp = '') or Cancelled then
      Exit;

    try
      WdJSON := GetJSON(JSONResp);
      try
        if Assigned(WdJSON) and (WdJSON.JSONType = jtObject) and
           (WdJSON.FindPath('error') = nil) then
        begin
          ClaimsNode := WdJSON.FindPath('claims');
          if Assigned(ClaimsNode) then
          begin
            Result   := 0;
            P434Node := nil;
            if ClaimsNode.JSONType = jtObject then
              P434Node := ClaimsNode.FindPath('P434');
            if Assigned(P434Node) and (P434Node.JSONType = jtArray) and (P434Node.Count > 0) then
              Result := 1;
          end;
        end;
      finally
        WdJSON.Free;
      end;
    except
      Result := -1;
    end;
  end;

  function TryFetchWikipediaImage(const SearchName: string; out IsDisambiguation: boolean): boolean;
  var
    WikiUrl, JSONResp, ImgUrl, ThumbUrl, ItemID: string;
    WikiJSON, TypeNode, ImgNode: TJSONData;
    FormattedTitle: string;
  begin
    Result           := False;
    IsDisambiguation := False;
    if Cancelled or (SearchName = '') then
      Exit;

    FormattedTitle := StringReplace(SearchName, ' ', '_', [rfReplaceAll]);
    WikiUrl        := 'https://en.wikipedia.org/api/rest_v1/page/summary/' + SimpleURLEncode(FormattedTitle);

    JSONResp := DownloadHTTPSJSON(WikiUrl);
    if (JSONResp = '') or Cancelled then
      Exit;

    ImgUrl   := '';
    ThumbUrl := '';
    ItemID   := '';
    try
      WikiJSON := GetJSON(JSONResp);
      try
        if Assigned(WikiJSON) and (WikiJSON.JSONType = jtObject) then
        begin
          TypeNode := WikiJSON.FindPath('type');
          if Assigned(TypeNode) and (TypeNode.JSONType = jtString) and
             SameText(TypeNode.AsString, 'disambiguation') then
          begin
            IsDisambiguation := True;
            Exit(False);
          end;

          ImgNode := WikiJSON.FindPath('originalimage.source');
          if Assigned(ImgNode) and (ImgNode.JSONType = jtString) then
            ImgUrl := ImgNode.AsString;

          ImgNode := WikiJSON.FindPath('thumbnail.source');
          if Assigned(ImgNode) and (ImgNode.JSONType = jtString) then
            ThumbUrl := ImgNode.AsString;

          ImgNode := WikiJSON.FindPath('wikibase_item');
          if Assigned(ImgNode) and (ImgNode.JSONType = jtString) then
            ItemID := Trim(ImgNode.AsString);

          if ImgUrl = '' then
          begin
            ImgUrl   := ThumbUrl;
            ThumbUrl := '';
          end;
        end;
      finally
        WikiJSON.Free;
      end;
    except
      // Silently swallow JSON errors
    end;

    if (ImgUrl = '') or Cancelled then
      Exit(False);

    // ---> AUDIT FIX: A page that is not about a music artist (e.g. the word
    // "Biosphere") is treated like a disambiguation page, so the caller tries
    // "<name> (musician)" / "<name> (band)" and TheAudioDB. When Wikidata gives
    // no answer, the picture is accepted as before.
    if (ItemID <> '') and (WikidataIsMusicArtist(ItemID) = 0) then
    begin
      IsDisambiguation := True;
      Exit(False);
    end;
    if Cancelled then
      Exit(False);

    Result := DownloadAndProcessImage(ImgUrl);

    // ---> AUDIT FIX: The full-size image can be too large to decode
    // (> 8192 px); Wikipedia's smaller version is tried next
    if (not Result) and (not Cancelled) and (ThumbUrl <> '') and (ThumbUrl <> ImgUrl) then
      Result := DownloadAndProcessImage(ThumbUrl);
  end;

  function TryFetchAudioDbImage(const SearchName: string): boolean;
  var
    AudioDbUrl, JSONResp, ImgUrl: string;
    AudioDbJSON, ArtistsArray, ThumbNode: TJSONData;
  begin
    Result := False;
    if Cancelled or (SearchName = '') then
      Exit;

    AudioDbUrl := 'https://www.theaudiodb.com/api/v1/json/123/search.php?s=' + SimpleURLEncode(SearchName);

    JSONResp := DownloadHTTPSJSON(AudioDbUrl);
    if (JSONResp = '') or Cancelled then
      Exit;

    ImgUrl := '';
    try
      AudioDbJSON := GetJSON(JSONResp);
      try
        if Assigned(AudioDbJSON) then
        begin
          ArtistsArray := AudioDbJSON.FindPath('artists');
          if Assigned(ArtistsArray) and (ArtistsArray.JSONType = jtArray) and (ArtistsArray.Count > 0) then
          begin
            ThumbNode := ArtistsArray.Items[0].FindPath('strArtistThumb');
            if Assigned(ThumbNode) and (ThumbNode.JSONType = jtString) and (ThumbNode.AsString <> '') then
              ImgUrl := ThumbNode.AsString;
          end;
        end;
      finally
        AudioDbJSON.Free;
      end;
    except
      // Silently swallow JSON errors
    end;

    Result := DownloadAndProcessImage(ImgUrl);
  end;

  function TryFetchArtistImageForName(const CandidateName: string): boolean;
  var
    FuzzyName: string;
    WasDisambig, DummyDisambig: boolean;
  begin
    Result := False;
    if Cancelled or (CandidateName = '') then
      Exit;

    // 1. Primary Wikipedia lookup
    Result := TryFetchWikipediaImage(CandidateName, WasDisambig);

    // 2. Only try "(musician)" / "(band)" if Wikipedia returned a disambiguation page
    if (not Result) and WasDisambig and (not Cancelled) then
    begin
      Result := TryFetchWikipediaImage(CandidateName + ' (musician)', DummyDisambig);
      if (not Result) and (not Cancelled) then
        Result := TryFetchWikipediaImage(CandidateName + ' (band)', DummyDisambig);
    end;

    // 3. Dedicated music database lookup (TheAudioDB)
    if (not Result) and (not Cancelled) then
      Result := TryFetchAudioDbImage(CandidateName);

    // 4. Accent-stripped fallback
    if (not Result) and (not Cancelled) then
    begin
      FuzzyName := StripAccents(CandidateName);
      if FuzzyName <> CandidateName then
      begin
        Result := TryFetchWikipediaImage(FuzzyName, DummyDisambig);
        if (not Result) and (not Cancelled) then
          Result := TryFetchAudioDbImage(FuzzyName);
      end;
    end;
  end;

begin
  ResultText          := LBL_BIO_UNAVAILABLE;
  ResultImagePath     := '';
  ArtistDir           := '';
  JsonFile            := '';
  ActiveArtist        := '';
  BioWasAlreadyCached := False;
  FirstArtist         := ExtractFirstArtist(AArtistName);
  CleanedArtist       := CleanArtistSearchName(FirstArtist);

  // Prioritize CleanedArtist first so "Maya Fridman (cello)" queries and caches
  // under "Maya Fridman" on the very first attempt, with FirstArtist as fallback
  if (CleanedArtist <> '') and (CleanedArtist <> FirstArtist) then
  begin
    PrimaryArtist  := CleanedArtist;
    FallbackArtist := FirstArtist;
  end
  else
  begin
    PrimaryArtist  := FirstArtist;
    FallbackArtist := '';
  end;

  // ===========================================================================
  // 1. ISOLATED BIO EXTRACTION (PrimaryArtist -> FallbackArtist)
  // ===========================================================================
  // ---> AUDIT FIX: Refresh keeps a biography the user edited
  KeepUserBio := AForceRefresh and
                 FileExists(ResolveArtistCacheDir(AArtistName) + FILE_ARTIST_BIO_USER);

  if ((not AForceRefresh) or KeepUserBio) and
     (TryLoadCachedArtistBio(PrimaryArtist) or
      ((FallbackArtist <> '') and TryLoadCachedArtistBio(FallbackArtist))) then
  begin
    // Loaded directly from MusicInfo disk cache (zero network calls)
  end
  else
  begin
    if not TryFetchAndSaveArtistBio(PrimaryArtist) then
    begin
      if (not Cancelled) and (FallbackArtist <> '') then
      begin
        if not TryFetchAndSaveArtistBio(FallbackArtist) then
        begin
          ActiveArtist    := PrimaryArtist;
          ArtistDir       := AppMusicInfoDir + SanitizeFolderName(PrimaryArtist) + DirectorySeparator;
          ResultImagePath := ArtistDir + FILE_ARTIST_IMAGE;
        end;
      end;
    end;
  end;

  if Cancelled then
    Exit;

  // ===========================================================================
  // 2. PROGRESSIVE UI UPDATE + ISOLATED IMAGE EXTRACTION
  // Push the biography text to the UI immediately before fetching images!
  // ===========================================================================
  // ---> AUDIT FIX: Refresh keeps a picture the user chose
  UserImage := (ResultImagePath <> '') and FileExists(ResultImagePath) and
               FileExists(ExtractFilePath(ResultImagePath) + FILE_ARTIST_IMAGE_USER);

  NeedImageFetch := (not UserImage) and
                    ((not FileExists(ResultImagePath)) or AForceRefresh) and
                    ((not BioWasAlreadyCached) or AForceRefresh);

  if NeedImageFetch and (not Cancelled) then
  begin
    ProgressImage := ResultImagePath;
    if not FileExists(ProgressImage) then
      ProgressImage := '';
    PostResult(AGeneration, AArtistName, ResultText, ProgressImage);
  end;

  ImageFound := False;
  if NeedImageFetch and (not Cancelled) then
  begin
    try
      ImageFound := TryFetchArtistImageForName(ActiveArtist);

      if (not ImageFound) and (not Cancelled) and
         (ActiveArtist <> PrimaryArtist) and (PrimaryArtist <> '') then
        ImageFound := TryFetchArtistImageForName(PrimaryArtist);

      if (not ImageFound) and (not Cancelled) and
         (FallbackArtist <> '') and (ActiveArtist <> FallbackArtist) then
        ImageFound := TryFetchArtistImageForName(FallbackArtist);
    except
      // Swallow
    end;
  end;

  if not FileExists(ResultImagePath) then
    ResultImagePath := '';

  if (not Cancelled) and ((not NeedImageFetch) or ImageFound) then
    PostResult(AGeneration, AArtistName, ResultText, ResultImagePath);
end;

end.
