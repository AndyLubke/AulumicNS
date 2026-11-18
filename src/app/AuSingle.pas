unit AuSingle;

{ ==============================================================================
  AulumicNS - AuSingle
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  One AulumicNS at a time: the audio device is used exclusively, so a second
  copy could not play anyway.

  The first copy owns a named mutex and publishes two window handles in a
  small named shared memory block: its main window (to bring it to the
  front) and a hidden message window of its own (to receive the files; the
  LCL does not pass WM_COPYDATA on to a form). A second start finds the
  mutex, activates the first copy and hands over the files of its command
  line (Explorer "Open with", double click on a music file) with
  WM_COPYDATA; then it ends. The main window takes the files with
  TakeIncoming.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils;

{ True when another AulumicNS runs (this call claims the mutex otherwise) }
function OtherInstanceRunning: Boolean;
{ the first copy: its main window and the receiver, for later starts }
procedure PublishMainWindow(Wnd: HWND);
{ the second copy: activates the first one and passes the paths; waits up
  to 3 s for a copy that is still starting }
procedure HandOverToRunning(const Paths: array of string);
{ files handed over by later starts since the last call }
function TakeIncoming(Paths: TStrings): Boolean;

implementation

const
  MutexName = 'Local\AulumicNS.MusicPlayer.Instance';
  MapName = 'Local\AulumicNS.MusicPlayer.Window';
  ReceiverClass = 'AulumicNS.MusicPlayer.Receiver';
  CopyDataId = $41554C53;          // 'AULS'
  HWND_MESSAGE_ = HWND(-3);

type
  TPublished = record
    MainWnd, Receiver: HWND;
  end;
  PPublished = ^TPublished;

var
  MutexHandle: THandle = 0;
  MapHandle: THandle = 0;
  MapView: PPublished = nil;
  ReceiverWnd: HWND = 0;
  Incoming: TStringList = nil;

function OtherInstanceRunning: Boolean;
begin
  MutexHandle := CreateMutexW(nil, False, MutexName);
  Result := (MutexHandle <> 0) and (GetLastError = ERROR_ALREADY_EXISTS);
  if Result then
  begin
    CloseHandle(MutexHandle);
    MutexHandle := 0;
  end;
  { the first copy keeps the handle until it ends (Windows closes it) }
end;

function ReceiverProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  CD: PCopyDataStruct;
  S: UTF8String;
  P, Q: Integer;
begin
  if Msg = WM_COPYDATA then
  begin
    CD := PCopyDataStruct(LP);
    if (CD <> nil) and (CD^.dwData = CopyDataId) and (CD^.cbData > 0) and (CD^.cbData <= 4 * 1024 * 1024) then
    begin
      SetString(S, PAnsiChar(CD^.lpData), CD^.cbData);
      if Incoming = nil then Incoming := TStringList.Create;
      P := 1;
      for Q := 1 to Length(S) do
        if S[Q] = #0 then
        begin
          if Q > P then Incoming.Add(string(Copy(S, P, Q - P)));
          P := Q + 1;
        end;
      Exit(1);
    end;
  end;
  Result := DefWindowProcW(Wnd, Msg, WP, LP);
end;

procedure CreateReceiver;
var
  WC: TWndClassW;
begin
  if ReceiverWnd <> 0 then Exit;
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @ReceiverProc;
  WC.hInstance := HInstance;
  WC.lpszClassName := ReceiverClass;
  RegisterClassW(WC);
  { a message-only window: never visible, receives sent messages }
  ReceiverWnd := CreateWindowExW(0, ReceiverClass, 'AulumicNS', 0, 0, 0, 0, 0, HWND_MESSAGE_, 0, HInstance, nil);
end;

procedure PublishMainWindow(Wnd: HWND);
begin
  { only the copy that owns the mutex (test modes of the debug build do not) }
  if MutexHandle = 0 then Exit;
  CreateReceiver;
  if MapHandle = 0 then
  begin
    MapHandle := CreateFileMappingW(INVALID_HANDLE_VALUE, nil, PAGE_READWRITE, 0, SizeOf(TPublished), MapName);
    if MapHandle = 0 then Exit;
    MapView := MapViewOfFile(MapHandle, FILE_MAP_WRITE, 0, 0, SizeOf(TPublished));
  end;
  if MapView <> nil then
  begin
    MapView^.MainWnd := Wnd;
    MapView^.Receiver := ReceiverWnd;
  end;
end;

function ReadPublished(out Pub: TPublished): Boolean;
var
  H: THandle;
  P: PPublished;
begin
  Pub := Default(TPublished);
  H := OpenFileMappingW(FILE_MAP_READ, False, MapName);
  if H <> 0 then
  begin
    P := MapViewOfFile(H, FILE_MAP_READ, 0, 0, SizeOf(TPublished));
    if P <> nil then
    begin
      Pub := P^;
      UnmapViewOfFile(P);
    end;
    CloseHandle(H);
  end;
  Result := (Pub.MainWnd <> 0) and IsWindow(Pub.MainWnd);
end;

procedure HandOverToRunning(const Paths: array of string);
var
  Pub: TPublished;
  T0: QWord;
  Data: UTF8String;
  I: Integer;
  CD: TCopyDataStruct;
  Res: DWORD_PTR;
begin
  T0 := GetTickCount64;
  while not ReadPublished(Pub) do
  begin
    if GetTickCount64 - T0 > 3000 then Exit;
    Sleep(100);                      // the first copy may still be starting
  end;
  { this process was started by the user, so it may give the focus away }
  if IsIconic(Pub.MainWnd) then ShowWindow(Pub.MainWnd, SW_RESTORE);
  SetForegroundWindow(Pub.MainWnd);
  if (Length(Paths) = 0) or (Pub.Receiver = 0) then Exit;
  Data := '';
  for I := 0 to High(Paths) do
    Data := Data + UTF8String(ExpandFileName(Paths[I])) + #0;
  CD.dwData := CopyDataId;
  CD.cbData := Length(Data);
  CD.lpData := PAnsiChar(Data);
  Res := 0;
  SendMessageTimeoutW(Pub.Receiver, WM_COPYDATA, 0, LPARAM(@CD), SMTO_ABORTIFHUNG, 5000, @Res);
end;

function TakeIncoming(Paths: TStrings): Boolean;
begin
  Result := (Incoming <> nil) and (Incoming.Count > 0);
  if not Result then Exit;
  Paths.Assign(Incoming);
  Incoming.Clear;
end;

finalization
  if ReceiverWnd <> 0 then DestroyWindow(ReceiverWnd);
  Incoming.Free;
  if MapView <> nil then UnmapViewOfFile(MapView);
  if MapHandle <> 0 then CloseHandle(MapHandle);
  if MutexHandle <> 0 then CloseHandle(MutexHandle);

end.
