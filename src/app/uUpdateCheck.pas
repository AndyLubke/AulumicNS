unit uUpdateCheck;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - uUpdateCheck
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The check for a newer version, run when the user asks for it (the About
  window) or, with the setting for it on, once after the start: one request for the latest release of the program on GitHub,
  on a thread of its own, and the comparison of that release's number with
  the number of this program file. Nothing is downloaded and nothing about
  the PC is sent.

  The window that started a check looks at TUpdateCheck.Finished from a timer
  and hands the thread to ReleaseUpdateCheck when it is done with it; a check
  that still runs then is kept until it has ended (at the latest when the
  program closes), so a window never waits for the network.
  =============================================================================}

interface

uses
  Classes, SysUtils;

const
  { where the newest release can be downloaded }
  UPDATE_PAGE_URL = 'https://github.com/AndyLubke/AulumicNS/releases/latest';

type
  TUpdateState = (usUpToDate, usNewer, usFailed);

  TVersionNumbers = array[0..3] of Integer;

  TUpdateCheck = class(TThread)
  private
    FOwnVersion: string;
    FState: TUpdateState;
    FLatest: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AOwnVersion: string);
    { valid once Finished }
    property State: TUpdateState read FState;
    property Latest: string read FLatest;
  end;

{ '1.1.0.18' or 'v1.1.0.18' as four numbers (missing ones are 0); False for
  anything that is not one to four numbers with dots between them }
function ParseVersion(const S: string; out V: TVersionNumbers): Boolean;
{ > 0: A is the newer one, 0: the same, < 0: B is. A text that is no version
  counts as older than any version. }
function CompareVersionText(const A, B: string): Integer;
{ the answer of GitHub to "the latest release" against this program's number:
  ALatest is the release's number without its 'v' }
function JudgeLatest(const AJson, AOwnVersion: string; out ALatest: string): TUpdateState;
{ a release worth a notice at start: newer than this program, and newer than
  the version the user chose to skip ('' = none) }
function UpdateWanted(const ALatest, AOwn, ASkipped: string): Boolean;
{ gives a check back: freed at once when it has ended, else when it has }
procedure ReleaseUpdateCheck(var ACheck: TUpdateCheck);

implementation

uses
  Windows, fpjson, jsonparser;

const
  LATEST_HOST: UnicodeString = 'api.github.com';
  LATEST_PATH: UnicodeString = '/repos/AndyLubke/AulumicNS/releases/latest';
  USER_AGENT: UnicodeString  = 'Aulumic (Windows audio player)';
  ACCEPT_HEADER: UnicodeString = 'Accept: application/vnd.github+json'#13#10;
  { the answer is a few kilobytes; more than this is not that answer }
  MAX_ANSWER_BYTES = 1024 * 1024;
  TIMEOUT_MS = 5000;

  WINHTTP_DLL = 'winhttp.dll';
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY   = 0;
  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4;
  WINHTTP_FLAG_SECURE                 = $00800000;
  WINHTTP_QUERY_STATUS_CODE           = 19;
  WINHTTP_QUERY_FLAG_NUMBER           = $20000000;
  INTERNET_DEFAULT_HTTPS_PORT         = 443;

type
  HINTERNET = Pointer;

function WinHttpOpen(pszAgentW: PWideChar; dwAccessType: DWORD; pszProxyW,
  pszProxyBypassW: PWideChar; dwFlags: DWORD): HINTERNET; stdcall;
  external WINHTTP_DLL name 'WinHttpOpen';
function WinHttpConnect(hSession: HINTERNET; pswzServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): HINTERNET; stdcall;
  external WINHTTP_DLL name 'WinHttpConnect';
function WinHttpOpenRequest(hConnect: HINTERNET; pwszVerb, pwszObjectName,
  pwszVersion, pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer;
  dwFlags: DWORD): HINTERNET; stdcall;
  external WINHTTP_DLL name 'WinHttpOpenRequest';
function WinHttpSendRequest(hRequest: HINTERNET; lpszHeaders: PWideChar;
  dwHeadersLength: DWORD; lpOptional: Pointer; dwOptionalLength,
  dwTotalLength: DWORD; dwContext: PtrUInt): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpSendRequest';
function WinHttpReceiveResponse(hRequest: HINTERNET; lpReserved: Pointer): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpReceiveResponse';
function WinHttpQueryHeaders(hRequest: HINTERNET; dwInfoLevel: DWORD;
  pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
  lpdwIndex: Pointer): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpQueryHeaders';
function WinHttpQueryDataAvailable(hRequest: HINTERNET;
  var lpdwNumberOfBytesAvailable: DWORD): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpQueryDataAvailable';
function WinHttpReadData(hRequest: HINTERNET; lpBuffer: Pointer;
  dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpReadData';
function WinHttpSetTimeouts(hInternet: HINTERNET; nResolveTimeout,
  nConnectTimeout, nSendTimeout, nReceiveTimeout: Integer): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpSetTimeouts';
function WinHttpCloseHandle(hInternet: HINTERNET): BOOL; stdcall;
  external WINHTTP_DLL name 'WinHttpCloseHandle';

var
  { checks given back while they still ran }
  Parked: TList = nil;

function ParseVersion(const S: string; out V: TVersionNumbers): Boolean;
var
  T: string;
  I, N, Digits: Integer;
begin
  Result := False;
  for I := 0 to 3 do V[I] := 0;
  T := Trim(S);
  if (T <> '') and (T[1] in ['v', 'V']) then Delete(T, 1, 1);
  if T = '' then Exit;
  N := 0;
  Digits := 0;
  for I := 1 to Length(T) do
    if T[I] in ['0'..'9'] then
    begin
      { more digits than a build number ever has: not a version }
      if Digits >= 6 then Exit;
      V[N] := V[N] * 10 + Ord(T[I]) - Ord('0');
      Inc(Digits);
    end
    else if (T[I] = '.') and (Digits > 0) and (N < 3) then
    begin
      Inc(N);
      Digits := 0;
    end
    else
      Exit;
  Result := Digits > 0;
end;

function CompareVersionText(const A, B: string): Integer;
var
  VA, VB: TVersionNumbers;
  OkA, OkB: Boolean;
  I: Integer;
begin
  OkA := ParseVersion(A, VA);
  OkB := ParseVersion(B, VB);
  if not (OkA and OkB) then Exit(Ord(OkA) - Ord(OkB));
  Result := 0;
  for I := 0 to 3 do
    if VA[I] <> VB[I] then Exit(VA[I] - VB[I]);
end;

function JudgeLatest(const AJson, AOwnVersion: string; out ALatest: string): TUpdateState;
var
  Data, Node: TJSONData;
  V: TVersionNumbers;
begin
  Result := usFailed;
  ALatest := '';
  if Trim(AJson) = '' then Exit;
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
      if Assigned(Data) and (Data.JSONType = jtObject) then
      begin
        Node := Data.FindPath('tag_name');
        if Assigned(Node) and (Node.JSONType = jtString) then ALatest := Trim(Node.AsString);
      end;
    except
      ALatest := '';
    end;
  finally
    Data.Free;
  end;
  if not ParseVersion(ALatest, V) then
  begin
    ALatest := '';
    Exit;
  end;
  if ALatest[1] in ['v', 'V'] then Delete(ALatest, 1, 1);
  if CompareVersionText(ALatest, AOwnVersion) > 0 then Result := usNewer
  else Result := usUpToDate;
end;

function UpdateWanted(const ALatest, AOwn, ASkipped: string): Boolean;
begin
  Result := (CompareVersionText(ALatest, AOwn) > 0) and
    ((ASkipped = '') or (CompareVersionText(ALatest, ASkipped) > 0));
end;

{ the body of the answer, '' when anything went wrong or the status is not 200 }
function FetchLatest: string;
const
  VERB_GET: UnicodeString = 'GET';
var
  Session, Connect, Request: HINTERNET;
  Status, Len, Avail, Got, ReadNow: DWORD;
  Buf: array[0..8191] of Byte;
  Body: TMemoryStream;
begin
  Result := '';
  Session := WinHttpOpen(PWideChar(USER_AGENT), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0);
  if Session = nil then
    Session := WinHttpOpen(PWideChar(USER_AGENT), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0);
  if Session = nil then Exit;
  Connect := nil;
  Request := nil;
  Body := TMemoryStream.Create;
  try
    WinHttpSetTimeouts(Session, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS);
    Connect := WinHttpConnect(Session, PWideChar(LATEST_HOST), INTERNET_DEFAULT_HTTPS_PORT, 0);
    if Connect = nil then Exit;
    Request := WinHttpOpenRequest(Connect, PWideChar(VERB_GET), PWideChar(LATEST_PATH),
      nil, nil, nil, WINHTTP_FLAG_SECURE);
    if Request = nil then Exit;
    if not WinHttpSendRequest(Request, PWideChar(ACCEPT_HEADER), DWORD($FFFFFFFF), nil, 0, 0, 0) then Exit;
    if not WinHttpReceiveResponse(Request, nil) then Exit;
    Status := 0;
    Len := SizeOf(Status);
    if not WinHttpQueryHeaders(Request, WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
      nil, @Status, Len, nil) then Exit;
    if Status <> 200 then Exit;
    repeat
      Avail := 0;
      if not WinHttpQueryDataAvailable(Request, Avail) then Exit;
      if Avail = 0 then Break;
      while Avail > 0 do
      begin
        ReadNow := Avail;
        if ReadNow > SizeOf(Buf) then ReadNow := SizeOf(Buf);
        Got := 0;
        if not WinHttpReadData(Request, @Buf[0], ReadNow, Got) then Exit;
        if Got = 0 then Break;
        if Body.Size + Got > MAX_ANSWER_BYTES then Exit;
        Body.WriteBuffer(Buf[0], Got);
        Dec(Avail, Got);
      end;
    until False;
    SetString(Result, PAnsiChar(Body.Memory), Body.Size);
  finally
    Body.Free;
    if Request <> nil then WinHttpCloseHandle(Request);
    if Connect <> nil then WinHttpCloseHandle(Connect);
    WinHttpCloseHandle(Session);
  end;
end;

constructor TUpdateCheck.Create(const AOwnVersion: string);
begin
  FOwnVersion := AOwnVersion;
  FState := usFailed;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TUpdateCheck.Execute;
begin
  try
    FState := JudgeLatest(FetchLatest, FOwnVersion, FLatest);
  except
    FState := usFailed;
  end;
end;

{ frees the parked checks that have ended; AAll: waits for the others too }
procedure SweepParked(AAll: Boolean);
var
  I: Integer;
  C: TUpdateCheck;
begin
  if Parked = nil then Exit;
  for I := Parked.Count - 1 downto 0 do
  begin
    C := TUpdateCheck(Parked[I]);
    if AAll then C.WaitFor;
    if C.Finished then
    begin
      Parked.Delete(I);
      C.Free;
    end;
  end;
end;

procedure ReleaseUpdateCheck(var ACheck: TUpdateCheck);
begin
  SweepParked(False);
  if ACheck = nil then Exit;
  if ACheck.Finished then ACheck.Free
  else
  begin
    if Parked = nil then Parked := TList.Create;
    Parked.Add(ACheck);
  end;
  ACheck := nil;
end;

finalization
  SweepParked(True);
  FreeAndNil(Parked);

end.
