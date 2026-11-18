unit uLibraryWatcher;

{ ==============================================================================
  AulumicNS - uLibraryWatcher
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Watches the library folders and reports when
  something in them changed; the main window then starts a quiet library
  refresh after a calm period (TakeChange).

  Only local folders are watched (fixed and removable drives). A network
  folder is left out: a standing change request keeps some NAS units from
  hibernating, so network folders are only checked by Refresh / Rescan and
  the scan at start.

  The change notifications are opened on the watcher's own thread: opening
  one on a drive that is asleep can block until it has spun up, and the UI
  must never wait for that. Stop (UI thread) waits a short time; a watcher
  still blocked by its drive is set aside (uDriveKeepAlive.SetThreadAside)
  and never waited for longer.
  =============================================================================}

{$mode ObjFPC}{$H+}

interface

uses
  Windows, Classes, SysUtils;

type
  { TLibraryWatcher }

  TLibraryWatcher = class(TThread)
  private
    FRoots: TStringList;
    FStop: THandle;              // Windows event (WaitForMultipleObjects needs the raw handle)
    FChanged: LongInt;
    FLastChange: QWord;
    FWatched: LongInt;
  protected
    procedure Execute; override;
  public
    { ARoots: the library folders; the network ones are left out }
    constructor Create(ARoots: TStrings);
    destructor Destroy; override;
    { True once after a change, when nothing changed for AQuietMs since }
    function TakeChange(AQuietMs: QWord): Boolean;
    { Forgets the changes seen so far (the program's own tag
      and ReplayGain writes: the library records are updated by the writer;
      a change notification does not say which files changed) }
    procedure Discard;
  end;

{ True for a folder on a network drive or a UNC path }
function IsNetworkFolder(const AFolder: string): Boolean;

{ ends the watcher (UI thread): signals it and waits up to AWaitMs; one still
  blocked by its drive is set aside. AWatcher is nil afterwards. }
procedure StopLibraryWatcher(var AWatcher: TLibraryWatcher; AWaitMs: Cardinal = 1000);

implementation

uses
  uDriveKeepAlive;

function IsNetworkFolder(const AFolder: string): Boolean;
var
  Root: UnicodeString;
begin
  Result := False;
  if AFolder = '' then Exit;
  if (Length(AFolder) >= 2) and (AFolder[1] = '\') and (AFolder[2] = '\') then Exit(True);
  if (Length(AFolder) >= 2) and (AFolder[2] = ':') then
  begin
    Root := UnicodeString(Copy(AFolder, 1, 2)) + '\';
    Result := GetDriveTypeW(PWideChar(Root)) = DRIVE_REMOTE;
  end;
end;

{ TLibraryWatcher }

constructor TLibraryWatcher.Create(ARoots: TStrings);
var
  I: Integer;
begin
  FRoots := TStringList.Create;
  for I := 0 to ARoots.Count - 1 do
    if (Trim(ARoots[I]) <> '') and not IsNetworkFolder(ARoots[I]) then
      FRoots.Add(IncludeTrailingPathDelimiter(Trim(ARoots[I])));
  FStop := CreateEvent(nil, True, False, nil);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TLibraryWatcher.Destroy;
begin
  Terminate;
  SetEvent(FStop);
  inherited Destroy;           // waits for Execute (StopLibraryWatcher waits with a limit first)
  CloseHandle(FStop);
  FRoots.Free;
end;

procedure TLibraryWatcher.Execute;
var
  H: array of THandle;
  N, I: Integer;
  W: DWORD;
  Hd: THandle;
begin
  H := nil;
  SetLength(H, 1);
  H[0] := FStop;
  N := 1;
  for I := 0 to FRoots.Count - 1 do
  begin
    if Terminated or (N >= MAXIMUM_WAIT_OBJECTS) then Break;
    Hd := FindFirstChangeNotificationW(PWideChar(UTF8Decode(FRoots[I])), True,
      FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_DIR_NAME or FILE_NOTIFY_CHANGE_SIZE or
      FILE_NOTIFY_CHANGE_LAST_WRITE);
    if Hd = INVALID_HANDLE_VALUE then Continue;    // offline: watched again after the next start
    SetLength(H, N + 1);
    H[N] := Hd;
    Inc(N);
  end;
  InterlockedExchange(FWatched, N - 1);
  try
    while not Terminated do
    begin
      if N = 1 then
      begin
        WaitForSingleObject(FStop, INFINITE);
        Break;
      end;
      W := WaitForMultipleObjects(N, @H[0], False, INFINITE);
      if Terminated or (W = WAIT_OBJECT_0) or (W = WAIT_FAILED) then Break;
      if (W > WAIT_OBJECT_0) and (W < WAIT_OBJECT_0 + DWORD(N)) then
      begin
        FLastChange := GetTickCount64;
        InterlockedExchange(FChanged, 1);
        if not FindNextChangeNotification(H[W - WAIT_OBJECT_0]) then Break;
      end;
    end;
  finally
    for I := 1 to N - 1 do FindCloseChangeNotification(H[I]);
  end;
end;

function TLibraryWatcher.TakeChange(AQuietMs: QWord): Boolean;
begin
  Result := False;
  if FChanged = 0 then Exit;
  if GetTickCount64 - FLastChange < AQuietMs then Exit;
  Result := InterlockedExchange(FChanged, 0) = 1;
end;

procedure TLibraryWatcher.Discard;
begin
  InterlockedExchange(FChanged, 0);
end;

procedure StopLibraryWatcher(var AWatcher: TLibraryWatcher; AWaitMs: Cardinal);
var
  W: TLibraryWatcher;
begin
  W := AWatcher;
  AWatcher := nil;
  if W = nil then Exit;
  W.Terminate;
  SetEvent(W.FStop);
  if WaitForSingleObject(W.Handle, AWaitMs) = WAIT_OBJECT_0 then
    W.Free
  else
    SetThreadAside(W);           // blocked by a sleeping drive: freed once it has ended
end;

end.
