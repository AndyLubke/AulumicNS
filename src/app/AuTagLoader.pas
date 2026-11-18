unit AuTagLoader;

{ ==============================================================================
  AulumicNS - AuTagLoader
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Reads the tags for the Properties dialog (Aulumic's uTagLoader): a small
  progress window with Cancel (Esc) while the files are read on the UI
  thread. The drives are woken first on a worker thread (WakeDrives, also
  for other callers: WakeDrivesWithWindow). During that wait the program
  takes no input but stays alive (uInputBlock, the busy pointer); when it
  lasts longer than DRIVE_WAIT_SHOW_DELAY_MS the "Waiting for drive..."
  window appears, and Escape or its Cancel stops the wait. A
  network drive that does not answer and a missing file stop the loading
  (a missing file offers a rescan of the library, as Aulumic).
  The records (TTagEditNodeData) are the editor's working copies: Original
  as read, Current as edited.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Controls, Forms, ExtCtrls, LCLType,
  AuGfx, AuTheme, AuControls, AuForms, uMetadataPayloads;

type
  PTagEditNodeData = ^TTagEditNodeData;
  TTagEditNodeData = record
    FilePath      : string;
    IsModified    : Boolean;
    HasCover      : Boolean;
    CoverModified : Boolean;
    CoverData     : TBytes;
    CoverMimeType : string;
    Current       : TAudioTagValues;
    Original      : TAudioTagValues;
    { the tag could not be read: shown, never changed or saved }
    ReadFailed    : Boolean;
  end;

{ True with the records of APaths in AData (free them with DisposeTagData) }
function LoadTagsForEditor(APaths: TStrings; out AData: TList): Boolean;
procedure DisposeTagData(var AData: TList);
{ the record of one existing file (tags, whether it has a cover); a file whose
  tag cannot be read is marked ReadFailed }
function ReadTagRecord(const APath: string): PTagEditNodeData;
{ Aulumic's WakeDrivesWithWindow: wakes the drives of APaths on a worker
  thread; when that takes a moment, a small "Waiting for drive..." window with
  Cancel (the other windows are disabled meanwhile). False = cancelled;
  AUnreachable gets the network drives that do not answer. }
function WakeDrivesWithWindow(AOwner: TComponent; APaths: TStrings; const ACaption: string;
  AUnreachable: TStrings = nil): Boolean;
{ ---> AulumicNS: the same window while the drives of APaths are checked on a
  worker thread (uDriveKeepAlive.FindOfflineDrives): AOffline gets the drives
  and shares that cannot be reached ('E:', '\\NAS\Music'). False = cancelled
  (AOffline is then empty). }
function FindOfflineDrivesWithWindow(AOwner: TComponent; APaths, AOffline: TStrings;
  const ACaption: string): Boolean;
{ ---> AulumicNS: True while a wait of WakeDrivesWithWindow /
  FindOfflineDrivesWithWindow holds the input and the busy cursor (the window
  itself comes later, or not at all); its busy cursor is not left behind, see
  TMainForm.UiTimerTick }
function DriveWaitShowing: Boolean;

implementation

uses
  AuAudioTypes, AudioTag, baseTag, ALMetadata, uMetaUtils, uOSUtils, uAppStrings, uAppConsts,
  Dialogs, uEngineStateManager, uDriveKeepAlive, AuDialogs, AuLog, uInputBlock;

type
  { TTagLoaderForm }

  TTagLoaderForm = class(TAuForm)
  private
    FPaths: TStringList;
    FData: TList;
    FStatus: TAuLabel;
    FBar: TAuProgress;
    FBtnCancel: TAuButton;
    FTimer: TTimer;
    FCancelled, FRunning: Boolean;
    FStaleCount, FOfflineCount: Integer;
    FWaitStart: QWord;
    FWaitShown: Boolean;
    procedure ClearItems;
    function WaitForDrive: Boolean;
    procedure TimerTick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateLoader(AOwner: TComponent; APaths: TStrings);
    destructor Destroy; override;
  end;

  { TDriveWaitForm: the window of WakeDrivesWithWindow }

  TDriveWaitForm = class(TAuForm)
  private
    FCancelled: Boolean;
    procedure CancelClick(Sender: TObject);
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateWait(AOwner: TComponent; const ACaption: string);
  end;

  { TDriveWaiter: a wait for a drive, seen from the UI thread.
    ---> AulumicNS 2026-11-14 (the user: "the normal GUI freeze, but without
    the turning white"): from the first call of OnWait (20 ms into the wait)
    the program takes no input (uInputBlock) and shows the busy cursor, while
    its windows go on painting. Only after DRIVE_WAIT_SHOW_DELAY_MS the
    "Waiting for drive..." window comes, the one window that takes input
    (Cancel). Escape stops the wait at any time. A wait that is over within
    20 ms does none of this.
    Before: the window after 1.2 s, the other forms disabled from then on
    (arrow cursor, a beep per click) and free to take input until then. }

  TDriveWaiter = class
  private
    FOwner: TComponent;
    FCaption: string;
    FStart: QWord;
    FWindow: TDriveWaitForm;
    FOldCursor: TCursor;
    FBlocking: Boolean;
  public
    destructor Destroy; override;
    function OnWait: Boolean;
  end;

constructor TDriveWaitForm.CreateWait(AOwner: TComponent; const ACaption: string);
begin
  CreateAu(AOwner, ACaption, 400, 130);
  FormStyle := fsStayOnTop;
  AddLabel(Self, LBL_WAITING_FOR_DRIVE, 24, 20, 352, False);
  AddButton(Self, 'Cancel', 400 - 24 - 110, 130 - 24 - 34, 110, bkNormal, @CancelClick);
end;

procedure TDriveWaitForm.CancelClick(Sender: TObject);
begin
  FCancelled := True;
end;

procedure TDriveWaitForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    FCancelled := True;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

var
  GDriveWaitShowing: Integer = 0;

function DriveWaitShowing: Boolean;
begin
  Result := GDriveWaitShowing > 0;
end;

destructor TDriveWaiter.Destroy;
begin
  if FBlocking then
  begin
    if FWindow <> nil then
    begin
      { the window was needed - what took so long, for the log
        (LastWakeReport is empty after a Cancel and for FindOfflineDrives) }
      if LastWakeReport <> '' then
        AddLog(SafeFormat('"Waiting for drive..." was shown, the wait took %d ms. %s',
          [GetTickCount64 - FStart, LastWakeReport]));
      FreeAndNil(FWindow);
    end;
    EndInputBlock;
    Dec(GDriveWaitShowing);
    { (the busy cursor of an earlier wait is not restored) }
    if FOldCursor = crAppStart then Screen.Cursor := crDefault
    else Screen.Cursor := FOldCursor;
  end;
  inherited Destroy;
end;

function TDriveWaiter.OnWait: Boolean;
begin
  if not FBlocking then
  begin
    FBlocking := True;
    { as ShowModal does: a control holding the mouse (the playlist during a
      click on a cover) lets go - its mouse up will not arrive }
    if Windows.GetCapture <> 0 then Windows.SendMessage(Windows.GetCapture, WM_CANCELMODE, 0, 0);
    Windows.ReleaseCapture;
    BeginInputBlock;
    Inc(GDriveWaitShowing);          // (the main window leaves the cursor alone)
    FOldCursor := Screen.Cursor;
    Screen.Cursor := crAppStart;
  end;
  if (FWindow = nil) and (GetTickCount64 - FStart >= DRIVE_WAIT_SHOW_DELAY_MS) then
  begin
    FWindow := TDriveWaitForm.CreateWait(FOwner, FCaption);
    FWindow.Show;
    InputBlockAllow(FWindow.Handle);
  end;
  Application.ProcessMessages;
  Result := InputBlockEscaped or ((FWindow <> nil) and FWindow.FCancelled);
end;

function WakeDrivesWithWindow(AOwner: TComponent; APaths: TStrings; const ACaption: string;
  AUnreachable: TStrings): Boolean;
var
  W: TDriveWaiter;
begin
  W := TDriveWaiter.Create;
  try
    W.FOwner := AOwner;
    W.FCaption := ACaption;
    W.FStart := GetTickCount64;
    Result := WakeDrives(APaths, @W.OnWait, AUnreachable);
  finally
    W.Free;
  end;
end;

function FindOfflineDrivesWithWindow(AOwner: TComponent; APaths, AOffline: TStrings;
  const ACaption: string): Boolean;
var
  W: TDriveWaiter;
begin
  W := TDriveWaiter.Create;
  try
    W.FOwner := AOwner;
    W.FCaption := ACaption;
    W.FStart := GetTickCount64;
    Result := FindOfflineDrives(APaths, AOffline, @W.OnWait);
  finally
    W.Free;
  end;
end;

procedure DisposeTagData(var AData: TList);
var
  I: Integer;
begin
  if AData = nil then Exit;
  for I := 0 to AData.Count - 1 do
    if AData[I] <> nil then Dispose(PTagEditNodeData(AData[I]));
  FreeAndNil(AData);
end;

function LoadTagsForEditor(APaths: TStrings; out AData: TList): Boolean;
var
  F: TTagLoaderForm;
  R: TModalResult;
  Stale, Offline: Integer;
begin
  AData := nil;
  Result := False;
  F := TTagLoaderForm.CreateLoader(Application.MainForm, APaths);
  try
    R := F.ShowModal;
    Stale := F.FStaleCount;
    Offline := F.FOfflineCount;
    if R = mrOK then
    begin
      AData := F.FData;
      F.FData := nil;
      Result := True;
    end;
  finally
    F.Free;
  end;
  if R = mrAbort then
  begin
    { an offline drive first (no rescan needed), then the deleted files }
    if Offline > 0 then
      ALMessageDlg(TITLE_STORAGE_OFFLINE, MSG_STORAGE_OFFLINE, [mbOK], mbOK, mkWarning)
    else if Stale > 0 then
    begin
      if ALMessageDlg(TITLE_MISSING_FILES, MSG_MISSING_FILES_RESCAN, [mbYes, mbNo], mbYes) = mrYes then
        if AppStateManager <> nil then AppStateManager.RequestLibraryScan(False, False);
    end;
  end;
end;

function ReadTagRecord(const APath: string): PTagEditNodeData;
var
  D: PTagEditNodeData;
  Reader: TTagReader;
  Meta: TAudioMetadata;
begin
  New(D);
  D^ := Default(TTagEditNodeData);
  D^.FilePath := APath;
  Result := D;
  try
    { the comment keeps its line breaks in the editor }
    Meta := ReadTrackMetadata(APath, True, False, True);
    SetLength(Meta.CoverData, 0);
    D^.Current.Title := Meta.Title;
    D^.Current.Album := Meta.Album;
    D^.Current.Artist := NormalizeSemicolons(Meta.Artist);
    D^.Current.AlbumArtist := NormalizeSemicolons(Meta.AlbumArtist);
    D^.Current.Genre := NormalizeSemicolons(Meta.Genre);
    D^.Current.Composer := NormalizeSemicolons(Meta.Composer);
    D^.Current.Performer := NormalizeSemicolons(Meta.Performer);
    D^.Current.Comment := Meta.Comment;
    D^.Current.Track := Meta.TrackNumber;
    D^.Current.Disc := Meta.DiscNumber;
    D^.Current.DateStr := Meta.DateStr;
    if D^.Current.Title = '' then D^.Current.Title := ExtractFileName(D^.FilePath);
    { a tag that could not be read: never saved (it would clear the real tags) }
    if not Meta.ReadOk then
    begin
      D^.ReadFailed := True;
      D^.Current.Comment := MSG_TAG_EDITOR_READ_FAILED;
    end;
    Reader := nil;
    try
      Reader := GetFileTagsObject(APath);
      if Reader <> nil then
      begin
        D^.HasCover := (Reader.Tags <> nil) and (Reader.Tags.ImageCount > 0);
        if D^.HasCover and (Reader.Tags.Images[0] <> nil) then
          D^.CoverMimeType := Reader.Tags.Images[0].MIMEType;
      end;
    finally
      Reader.Free;
    end;
    D^.Original := D^.Current;
  except
    on E: Exception do
    begin
      if D^.Current.Title = '' then D^.Current.Title := ExtractFileName(D^.FilePath);
      D^.Current.Comment := ERR_READING_FILE_PREFIX + E.Message;
      D^.ReadFailed := True;
      D^.Original := D^.Current;
    end;
  end;
end;

{ ---- TTagLoaderForm ---- }

constructor TTagLoaderForm.CreateLoader(AOwner: TComponent; APaths: TStrings);
begin
  CreateAu(AOwner, TITLE_SCANNING_FILES, 440, 150);
  { in front: while a drive spins up the main window must not cover it }
  FormStyle := fsStayOnTop;
  FPaths := TStringList.Create;
  FPaths.Assign(APaths);
  FData := TList.Create;
  { ---> AulumicNS: not "Waiting for drive..." from the start (it stood there
    for a moment at every opening): that text comes when a drive really
    takes its time (WaitForDrive) }
  FStatus := AddLabel(Self, SafeFormat(FMT_STATUS_SCANNING_TRACK, [0, APaths.Count]), 24, 18, 392, False);
  FBar := TAuProgress.Create(Self);
  FBar.Parent := Body;
  FBar.SetBounds(S(24), S(52), S(392), S(8));
  FBtnCancel := AddButton(Self, 'Cancel', 440 - 24 - 110, 150 - 24 - 34, 110, bkNormal, @CancelClick);
  OnCloseQuery := @FormCloseQuery;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := TAGLOADER_TIMER_MS;
  FTimer.OnTimer := @TimerTick;
  FTimer.Enabled := True;           // the loop starts once the window is up
end;

destructor TTagLoaderForm.Destroy;
begin
  ClearItems;
  FData.Free;
  FPaths.Free;
  inherited Destroy;
end;

procedure TTagLoaderForm.ClearItems;
var
  I: Integer;
begin
  if FData = nil then Exit;
  for I := 0 to FData.Count - 1 do
    if FData[I] <> nil then Dispose(PTagEditNodeData(FData[I]));
  FData.Clear;
end;

procedure TTagLoaderForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FRunning then
  begin
    FCancelled := True;
    CanClose := False;              // the loop ends the dialog
  end
  else
    CanClose := True;
end;

procedure TTagLoaderForm.CancelClick(Sender: TObject);
begin
  FCancelled := True;
  FBtnCancel.Enabled := False;
end;

procedure TTagLoaderForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    CancelClick(Self);
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

{ called by WakeDrives about every 20 ms (this window is modal) }
function TTagLoaderForm.WaitForDrive: Boolean;
begin
  if (not FWaitShown) and (GetTickCount64 - FWaitStart >= DRIVE_WAIT_SHOW_DELAY_MS) then
  begin
    FWaitShown := True;
    FStatus.Caption := LBL_WAITING_FOR_DRIVE;
  end;
  Application.ProcessMessages;
  Result := FCancelled;
end;

procedure TTagLoaderForm.TimerTick(Sender: TObject);
var
  I: Integer;
  NowTick, LastUI: QWord;
  Unreachable: TStringList;
begin
  FTimer.Enabled := False;
  FRunning := True;
  LastUI := 0;
  try
    FStatus.Caption := SafeFormat(FMT_STATUS_SCANNING_TRACK, [0, FPaths.Count]);
    FWaitStart := GetTickCount64;
    FWaitShown := False;
    Unreachable := TStringList.Create;
    try
      if not WakeDrives(FPaths, @WaitForDrive, Unreachable) then FCancelled := True
      else if Unreachable.Count > 0 then
      begin
        { a network drive whose server does not answer: as a disconnected
          drive, without touching its files }
        Inc(FOfflineCount);
        FCancelled := True;
      end;
    finally
      Unreachable.Free;
    end;
    FData.Capacity := FPaths.Count;
    for I := 0 to FPaths.Count - 1 do
    begin
      if FCancelled then Break;
      NowTick := GetTickCount64;
      if (I = 0) or (I = FPaths.Count - 1) or (NowTick - LastUI >= 40) then
      begin
        LastUI := NowTick;
        FBar.Position := (I + 1) / FPaths.Count;
        FStatus.Caption := SafeFormat(FMT_STATUS_SCANNING_TRACK, [I + 1, FPaths.Count]);
        Application.ProcessMessages;
      end;
      if FCancelled then Break;
      if not FileExists(LongPath(FPaths[I])) then
      begin
        if IsDriveRootMissing(FPaths[I]) then Inc(FOfflineCount) else Inc(FStaleCount);
        FCancelled := True;
        Break;
      end;
      FData.Add(ReadTagRecord(FPaths[I]));
    end;

  finally
    FRunning := False;
  end;
  if (FStaleCount > 0) or (FOfflineCount > 0) then
  begin
    ClearItems;
    ModalResult := mrAbort;
  end
  else if FCancelled then
  begin
    ClearItems;
    ModalResult := mrCancel;
  end
  else
    ModalResult := mrOK;
end;

end.
