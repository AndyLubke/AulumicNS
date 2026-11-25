unit AuReplayGainForm;

{ ==============================================================================
  AulumicNS - AuReplayGainForm
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The ReplayGain scanner window: Main menu >
  Tools > Calculate ReplayGain (the whole library), the library menu (the
  selection - each album completed with its other tracks), the status line
  while a hidden scan runs.
    1. what to scan: "missing only" or "recalculate all" (PromptScanScope)
    2. the scan page: the album and the track with their progress; Hide keeps
       it running (the status line shows it), Stop ends it after the track
    3. the results: every track with its gains and peaks or why it was not
       measured; Save All hands the measured ones to the metadata custodian
  The loudness is measured by the built-in EBU R128 meter (AuLoudness).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, Dialogs, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms,
  uLibraryManager, uLibraryTypes, uReplayGainScan, uReplayGainThread;

{ the whole library }
function ReplayGainScanLibrary(AManager: TLibraryManager): Boolean;
{ the albums of these tracks }
function ReplayGainScanSelection(AManager: TLibraryManager; ATracks: TTrackList): Boolean;
{ the status line's notice: the hidden window again }
procedure ShowReplayGainWindow;
{ at exit: the scan stops, the window goes }
procedure CloseReplayGainWindow;
{ the window, not shown (screenshot mode): AResults shows the results page }
function CreateReplayGainDemo(AOwner: TComponent; AResults: Boolean): TAuForm;

implementation

uses
  uMetadataPayloads, uAppConsts, uAppStrings, uEngineStateManager, uOSUtils, AuDialogs,
  uSettingsManager, AuMenus, AuTagLoader;

type
  { TReplayGainForm }

  TReplayGainForm = class(TAuForm)
  private
    FLibrary: TLibraryManager;
    FThread, FFinished: TReplayGainThread;
    FResults: TList;                 // PRGScanResult
    FRowMenu: TAuMenu;               // the menu of a right-clicked row (kept until its entry ran)
    FCommitting, FStopPending: Boolean;
    FCrashMessage: string;
    FOnResults: Boolean;
    { scan page }
    FInfo, FAlbum, FTrack, FStats: TAuLabel;
    FBarAlbum, FBarTrack: TAuProgress;
    FBtnHide, FBtnStop: TAuButton;
    { results page }
    FHead, FWarn: TAuLabel;
    FGrid: TAuListView;
    FBtnSave, FBtnCancel: TAuButton;
    procedure Layout;
    procedure ShowPage(AResults: Boolean);
    procedure ClearResults;
    procedure Launch(AGroups: TRGAlbumGroups; AForce: Boolean);
    procedure ShowProgress(Sender: TObject; const P: TRGProgress);
    procedure TakeResults(Sender: TObject; AResults: TList);
    procedure ThreadTerminated(Sender: TObject);
    procedure ShowCrashAsync(Data: PtrInt);
    procedure CommitHealed(AHealed: TStringList);
    procedure ShowResults;
    procedure StopThread;
    procedure Teardown;
    procedure GridCell(Sender: TObject; Row, Col: Integer; var AText: string);
    procedure GridStyle(Sender: TObject; Row: Integer; var ABold: Boolean; var AColor: TARGB);
    procedure GridContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
    procedure FolderClick(Sender: TObject);
    procedure HideClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  protected
    procedure Resize; override;
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateRg(AOwner: TComponent; ALibrary: TLibraryManager);
    destructor Destroy; override;
  end;

var
  GRgForm: TReplayGainForm = nil;

const
  SCAN_W = 560;
  SCAN_H = 330;
  RES_W = 960;
  RES_H = 560;

function FmtDb(V: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := Format('%.2f dB', [V], FS);
end;

function FmtPeak(V: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := Format('%.6f', [V], FS);
end;

{ asks what to scan: missing only or all }
function PromptScanScope(ATracks, AAlbums, AMissing: Integer; out AForce: Boolean): Boolean;
var
  R: TModalResult;
begin
  Result := False;
  AForce := False;
  if AMissing = 0 then
  begin
    if ALMessageDlg(TITLE_RG_SCANNER, SafeFormat(FMT_RG_ALL_HAVE_INFO, [ATracks, AAlbums]), [mbYes, mbNo]) = mrYes then
    begin
      AForce := True;
      Result := True;
    end;
  end
  else
  begin
    R := ALMessageDlg(TITLE_RG_SCANNER, SafeFormat(FMT_RG_FOUND_MISSING, [AMissing]),
      SafeFormat(FMT_RG_BTN_SCAN_MISSING, [AMissing]), SafeFormat(FMT_RG_BTN_RECALC_ALL, [AAlbums]), True);
    if R = mrYes then Result := True
    else if R = mrNo then
    begin
      AForce := True;
      Result := True;
    end;
  end;
end;

function Busy: Boolean;
begin
  Result := False;
  if GRgForm <> nil then
  begin
    ShowReplayGainWindow;
    Exit(True);
  end;
  if (AppStateManager <> nil) and not AppStateManager.IsIdle then
  begin
    ALMessageDlg(TITLE_ENGINE_BUSY, AppStateManager.GetBusyMessage, [mbOK]);
    Exit(True);
  end;
end;

procedure StartScan(AManager: TLibraryManager; var AGroups: TRGAlbumGroups; AForce: Boolean);
var
  G: TRGAlbumGroups;
begin
  if AppStateManager <> nil then AppStateManager.PushState(esReplayGainBusy);
  GRgForm := TReplayGainForm.CreateRg(Application.MainForm, AManager);
  G := AGroups;
  AGroups := nil;                  // the scan thread owns them now
  GRgForm.Launch(G, AForce);
  GRgForm.Show;
end;

function ReplayGainScanLibrary(AManager: TLibraryManager): Boolean;
var
  Groups: TRGAlbumGroups;
  Missing: Integer;
  Force: Boolean;
begin
  Result := False;
  if (AManager = nil) or Busy then Exit;
  Groups := LibraryAlbumGroups(AManager, Missing);
  try
    if Groups.Count = 0 then
    begin
      ALMessageDlg(TITLE_LIBRARY_EMPTY, MSG_RG_LIBRARY_EMPTY, [mbOK]);
      Exit;
    end;
    if not PromptScanScope(AManager.GetTrackCount, Groups.Count, Missing, Force) then Exit;
    if not Force then RemoveAlbumsWithGain(AManager, Groups);
    if Groups.Count = 0 then
    begin
      ALMessageDlg(TITLE_RG_SCAN_COMPLETE, MSG_RG_ALL_FILES_HAVE_INFO, [mbOK]);
      Exit;
    end;
    StartScan(AManager, Groups, Force);
    Result := True;
  finally
    Groups.Free;
  end;
end;

function ReplayGainScanSelection(AManager: TLibraryManager; ATracks: TTrackList): Boolean;
var
  Groups: TRGAlbumGroups;
  Missing, Count: Integer;
  Force: Boolean;
begin
  Result := False;
  if (ATracks = nil) or (ATracks.Count = 0) or (AManager = nil) then
  begin
    ALMessageDlg(TITLE_SELECTION_EMPTY, MSG_RG_SELECTION_EMPTY, [mbOK]);
    Exit;
  end;
  if GRgForm <> nil then
  begin
    ShowReplayGainWindow;
    ALMessageDlg(TITLE_RG_SCANNER_BUSY, MSG_RG_SCANNER_BUSY, [mbOK]);
    Exit;
  end;
  if Busy then Exit;
  Groups := SelectionAlbumGroups(AManager, ATracks, Count, Missing);
  try
    if Groups.Count = 0 then Exit;
    if not PromptScanScope(Count, Groups.Count, Missing, Force) then Exit;
    if not Force then RemoveAlbumsWithGain(AManager, Groups);
    if Groups.Count = 0 then
    begin
      ALMessageDlg(TITLE_RG_SCAN_COMPLETE, MSG_RG_SELECTED_HAVE_INFO, [mbOK]);
      Exit;
    end;
    StartScan(AManager, Groups, Force);
    Result := True;
  finally
    Groups.Free;
  end;
end;

procedure ShowReplayGainWindow;
begin
  if GRgForm = nil then Exit;
  if not GRgForm.Visible then GRgForm.Show;
  if GRgForm.WindowState = wsMinimized then GRgForm.WindowState := wsNormal;
  GRgForm.BringToFront;
end;

procedure CloseReplayGainWindow;
begin
  FreeAndNil(GRgForm);
end;

function CreateReplayGainDemo(AOwner: TComponent; AResults: Boolean): TAuForm;
const
  Albums: array[0..1] of string = ('Silence, Noise and Calm', 'Northern Lights');
var
  F: TReplayGainForm;
  P: PRGScanResult;
  I: Integer;
begin
  F := TReplayGainForm.CreateRg(AOwner, nil);
  Result := F;
  if not AResults then
  begin
    F.FAlbum.Caption := Albums[0];
    F.FTrack.Caption := '03 - The end of calm.flac';
    F.FStats.Caption := SafeFormat(FMT_STATUS_RG_ANALYZING, [1, 2, 3, 8]);
    F.FBarAlbum.Position := 0.5;
    F.FBarTrack.Position := 0.62;
    Exit;
  end;
  for I := 0 to 6 do
  begin
    New(P);
    P^ := Default(TRGScanResult);
    P^.Album := Albums[I div 4];
    P^.FilePath := Format('C:\Music\%s\0%d - Track %d.flac', [P^.Album, I mod 4 + 1, I mod 4 + 1]);
    P^.Title := ExtractFileName(P^.FilePath);
    P^.TrackGain := -6.2 - I * 0.7;
    P^.TrackPeak := 0.91 + I * 0.01;
    P^.AlbumGain := -7.1 - (I div 4);
    P^.AlbumPeak := 0.98;
    if I = 6 then P^.Status := rsDecodeError else P^.Status := rsReadyToSave;
    F.FResults.Add(P);
  end;
  F.ShowResults;
end;

{ ---- TReplayGainForm ---- }

constructor TReplayGainForm.CreateRg(AOwner: TComponent; ALibrary: TLibraryManager);
begin
  CreateAu(AOwner, 'Calculate ReplayGain', SCAN_W, SCAN_H);
  HelpKeyword := 'ReplayGain scanner';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize];
  Constraints.MinWidth := S(SCAN_W);
  Constraints.MinHeight := S(SCAN_H) + TitleBar.Height;
  FLibrary := ALibrary;
  FResults := TList.Create;
  OnCloseQuery := @FormCloseQuery;

  { the scan page }
  FInfo := AddLabel(Self, MSG_RG_INFO_TEXT, 24, 16, SCAN_W - 48);
  FInfo.FontSize := 12;
  FInfo.WordWrap := True;
  FInfo.VAlign := 0;
  FInfo.Height := S(56);
  FAlbum := AddLabel(Self, STATUS_RG_INITIALIZING, 24, 84, SCAN_W - 48, False);
  FAlbum.Bold := True;
  FBarAlbum := TAuProgress.Create(Self);
  FBarAlbum.Parent := Body;
  FTrack := AddLabel(Self, '', 24, 140, SCAN_W - 48, False);
  FBarTrack := TAuProgress.Create(Self);
  FBarTrack.Parent := Body;
  FStats := AddLabel(Self, '', 24, 196, SCAN_W - 48);
  FStats.FontSize := 12;
  FBtnHide := AddButton(Self, 'Hide', 0, 0, 110, bkNormal, @HideClick);
  FBtnHide.Hint := 'Hide the window; the scan goes on (the status line shows it, click it to come back).';
  FBtnHide.ShowHint := True;
  FBtnStop := AddButton(Self, 'Stop', 0, 0, 110, bkNormal, @StopClick);
  FBtnStop.Icon := icStopSolid;
  FBtnStop.Hint := 'Stop the scan after the current track. The results so far can still be saved.';
  FBtnStop.ShowHint := True;

  { the results page }
  FHead := AddHeading(Self, 'Results', 24, 14, 400);
  FGrid := TAuListView.Create(Self);
  FGrid.Parent := Body;
  FGrid.AddColumn(LBL_RG_COL_ALBUM_TRACK, 360, 0, True);
  FGrid.AddColumn(LBL_RG_COL_TRACK_GAIN, 100, 2);
  FGrid.AddColumn(LBL_RG_COL_TRACK_PEAK, 100, 2);
  FGrid.AddColumn(LBL_RG_COL_ALBUM_GAIN, 100, 2);
  FGrid.AddColumn(LBL_RG_COL_ALBUM_PEAK, 100, 2);
  FGrid.AddColumn(LBL_RG_COL_STATUS, 220);
  FGrid.AutoFit := True;
  FGrid.MultiSelect := True;
  FGrid.RowMenu := False;
  FGrid.BackRole := crCard;
  FGrid.OnGetCell := @GridCell;
  FGrid.OnRowStyle := @GridStyle;
  FGrid.OnRowContext := @GridContext;
  FWarn := AddLabel(Self, '', 24, 0, 600, False);
  FWarn.TextRole := crWarn;
  FWarn.Bold := True;
  FBtnCancel := AddButton(Self, 'Cancel', 0, 0, 110, bkNormal, @CancelClick);
  FBtnCancel.Hint := 'Close without saving. Nothing is written into the files.';
  FBtnCancel.ShowHint := True;
  FBtnSave := AddButton(Self, 'Save all', 0, 0, 120, bkPrimary, @SaveClick);
  FBtnSave.Icon := icCheck;
  FBtnSave.Hint := 'Write the ReplayGain tags of the measured tracks into the files (in the background).';
  FBtnSave.ShowHint := True;

  if AppStateManager <> nil then AppStateManager.ShowReplayGainLabel(True);
  ShowPage(False);
end;

destructor TReplayGainForm.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  StopThread;
  ClearResults;
  FResults.Free;
  FRowMenu.Free;
  if AppStateManager <> nil then
  begin
    AppStateManager.PopState(esReplayGainBusy);
    AppStateManager.ShowReplayGainLabel(False);
  end;
  if GRgForm = Self then GRgForm := nil;
  inherited Destroy;
end;

procedure TReplayGainForm.ShowPage(AResults: Boolean);
begin
  FOnResults := AResults;
  FInfo.Visible := not AResults;
  FAlbum.Visible := not AResults;
  FBarAlbum.Visible := not AResults;
  FTrack.Visible := not AResults;
  FBarTrack.Visible := not AResults;
  FStats.Visible := not AResults;
  FBtnHide.Visible := not AResults;
  FBtnStop.Visible := not AResults;
  FHead.Visible := AResults;
  FGrid.Visible := AResults;
  FWarn.Visible := AResults and (FWarn.Caption <> '');
  FBtnCancel.Visible := AResults;
  FBtnSave.Visible := AResults;
  if AResults then DefaultButton := FBtnSave else DefaultButton := nil;
  Layout;
end;

procedure TReplayGainForm.Layout;
var
  W, H, BY: Integer;
begin
  if FBtnSave = nil then Exit;
  W := ClientWidth;
  H := BodyHeight;
  BY := H - S(24) - S(34);
  if FOnResults then
  begin
    FGrid.SetBounds(S(24), S(52), W - S(48), BY - S(52) - S(16));
    FBtnSave.SetBounds(W - S(24) - S(120), BY, S(120), S(34));
    FBtnCancel.SetBounds(FBtnSave.Left - S(10) - S(110), BY, S(110), S(34));
    FWarn.SetBounds(S(24), BY, Math.Max(0, FBtnCancel.Left - S(36)), S(34));
  end
  else
  begin
    FInfo.Width := W - S(48);
    FAlbum.Width := W - S(48);
    FTrack.Width := W - S(48);
    FStats.Width := W - S(48);
    FBarAlbum.SetBounds(S(24), S(112), W - S(48), S(6));
    FBarTrack.SetBounds(S(24), S(168), W - S(48), S(6));
    FBtnStop.SetBounds(W - S(24) - S(110), BY, S(110), S(34));
    FBtnHide.SetBounds(FBtnStop.Left - S(10) - S(110), BY, S(110), S(34));
  end;
end;

procedure TReplayGainForm.Resize;
begin
  inherited Resize;
  Layout;
end;

procedure TReplayGainForm.ClearResults;
var
  I: Integer;
begin
  if FResults = nil then Exit;
  for I := 0 to FResults.Count - 1 do Dispose(PRGScanResult(FResults[I]));
  FResults.Clear;
end;

procedure TReplayGainForm.Launch(AGroups: TRGAlbumGroups; AForce: Boolean);
begin
  FAlbum.Caption := STATUS_RG_INITIALIZING;
  FTrack.Caption := '';
  FStats.Caption := '';
  FBtnStop.Enabled := True;
  FThread := TReplayGainThread.Create(AGroups, AForce, FLibrary);
  { Preferences > Volume > ReplayGain scan }
  FThread.ThreadCount := AppSettings.Data.RGScanThreads;
  FThread.OnProgress := @ShowProgress;
  FThread.OnResults := @TakeResults;
  FThread.OnTerminate := @ThreadTerminated;
  FThread.Start;
end;

procedure TReplayGainForm.ShowProgress(Sender: TObject; const P: TRGProgress);
begin
  if (P.TotalAlbums > 0) and (AppStateManager <> nil) then
    AppStateManager.ShowReplayGainProgress(P.CurAlbum, P.TotalAlbums);
  FAlbum.Caption := P.AlbumText;
  if not FStopPending then FTrack.Caption := P.TrackText;
  FStats.Caption := P.StatusText;
  FBarTrack.Position := EnsureRange(P.TrackPct, 0, 100) / 100;
  FBarAlbum.Position := EnsureRange(P.AlbumPct, 0, 100) / 100;
end;

procedure TReplayGainForm.TakeResults(Sender: TObject; AResults: TList);
var
  I: Integer;
begin
  for I := 0 to AResults.Count - 1 do FResults.Add(AResults[I]);
end;

{ the albums that already had their tags: the library gets their flags }
procedure TReplayGainForm.CommitHealed(AHealed: TStringList);
begin
  if (AHealed = nil) or (AHealed.Count = 0) or (FLibrary = nil) then Exit;
  FLibrary.SetReplayGainFlags(AHealed, True);
  FLibrary.SaveDatabase;
  if AppStateManager <> nil then AppStateManager.UpdateInfoBars;
end;

procedure TReplayGainForm.ThreadTerminated(Sender: TObject);
var
  T: TReplayGainThread;
  Crashed: Boolean;
begin
  T := TReplayGainThread(Sender);
  Crashed := T.FatalException <> nil;
  if Crashed then
  begin
    if T.FatalException is Exception then FCrashMessage := Exception(T.FatalException).Message
    else FCrashMessage := ERR_RG_UNKNOWN_THREAD_FAULT;
  end
  else
    CommitHealed(T.HealedFiles);
  { freed later: OnTerminate runs inside the thread's own Synchronize }
  FFinished := T;
  FThread := nil;
  if Crashed then Application.QueueAsyncCall(@ShowCrashAsync, 0)
  else if FResults.Count > 0 then ShowResults
  else
  begin
    if not Visible then Show;
    Teardown;
  end;
end;

procedure TReplayGainForm.ShowCrashAsync(Data: PtrInt);
begin
  if not Visible then Show;
  BringToFront;
  ALMessageDlg(TITLE_RG_SCANNER_CRASHED, SafeFormat(FMT_ERR_RG_THREAD_CRASH, [FCrashMessage]), [mbOK], mbOK, mkError);
  Teardown;
end;

procedure TReplayGainForm.ShowResults;
var
  I, Ready, Offline, Missing, Decode, Incomplete, TrackOnly: Integer;
  R: PRGScanResult;
  WA: TRect;
  W, H: Integer;
begin
  Ready := 0;
  Offline := 0;
  Missing := 0;
  Decode := 0;
  Incomplete := 0;
  TrackOnly := 0;
  for I := 0 to FResults.Count - 1 do
  begin
    R := PRGScanResult(FResults[I]);
    case R^.Status of
      rsReadyToSave: Inc(Ready);
      rsTrackOnly: begin Inc(Ready); Inc(TrackOnly); end;
      rsDriveOffline: Inc(Offline);
      rsFileMissing: Inc(Missing);
      rsAlbumIncomplete: Inc(Incomplete);
    else
      Inc(Decode);
    end;
  end;
  if Offline > 0 then FWarn.Caption := SafeFormat(FMT_RG_WARN_DRIVE_OFFLINE, [Offline])
  else if Missing > 0 then FWarn.Caption := SafeFormat(FMT_RG_WARN_FILES_MISSING, [Missing])
  else if Decode > 0 then FWarn.Caption := SafeFormat(FMT_RG_WARN_DECODE_FAILED, [Decode])
  else if Incomplete > 0 then FWarn.Caption := SafeFormat(FMT_RG_WARN_ALBUM_INCOMPLETE, [Incomplete])
  else if TrackOnly > 0 then FWarn.Caption := SafeFormat(FMT_RG_WARN_NO_ALBUM_TAG, [TrackOnly])
  else FWarn.Caption := '';
  FWarn.Caption := StringReplace(FWarn.Caption, '⚠️ ', '', []);
  FWarn.Caption := StringReplace(FWarn.Caption, 'NOTE: ', '', []);
  FHead.Caption := Format('Results - %d of %d tracks measured', [Ready, FResults.Count]);
  FBtnSave.Enabled := Ready > 0;
  FGrid.RowCount := FResults.Count;
  { a bigger window for the table (within the work area) }
  W := S(RES_W);
  H := S(RES_H) + TitleBar.Height;
  WA := Screen.MonitorFromWindow(Handle).WorkareaRect;
  W := Math.Min(W, WA.Right - WA.Left - S(40));
  H := Math.Min(H, WA.Bottom - WA.Top - S(40));
  SetBounds(Left + (Width - W) div 2, Top + (Height - H) div 2, W, H);
  if Top < WA.Top then Top := WA.Top;
  if Left < WA.Left then Left := WA.Left;
  if not Visible then Show;
  BringToFront;
  ShowPage(True);
  FGrid.FitColumns;
end;

procedure TReplayGainForm.GridCell(Sender: TObject; Row, Col: Integer; var AText: string);
var
  R: PRGScanResult;
  Ok, HasAlbum: Boolean;
begin
  if (Row < 0) or (Row >= FResults.Count) then Exit;
  R := PRGScanResult(FResults[Row]);
  Ok := R^.Status in [rsReadyToSave, rsTrackOnly];
  HasAlbum := R^.Status = rsReadyToSave;
  case Col of
    0: AText := SafeFormat(FMT_RG_GRID_ALBUM_TRACK, [R^.Album, ExtractFileName(R^.FilePath)]);
    1: if Ok then AText := FmtDb(R^.TrackGain) else AText := LBL_RG_EMPTY_CELL;
    2: if Ok then AText := FmtPeak(R^.TrackPeak) else AText := LBL_RG_EMPTY_CELL;
    3: if HasAlbum then AText := FmtDb(R^.AlbumGain) else AText := LBL_RG_EMPTY_CELL;
    4: if HasAlbum then AText := FmtPeak(R^.AlbumPeak) else AText := LBL_RG_EMPTY_CELL;
    5: AText := RGStatusText(R^.Status);
  end;
end;

procedure TReplayGainForm.GridContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
begin
  if FGrid.SelCount = 0 then Exit;
  FRowMenu.Free;
  FRowMenu := TAuMenu.Create;
  FRowMenu.Add('Open folder...', @FolderClick, icFolder);
  FRowMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

{ Explorer at the file of the first selected row }
procedure TReplayGainForm.FolderClick(Sender: TObject);
var
  Sel: TIntegerArray;
begin
  Sel := FGrid.SelectedRows;
  if (Length(Sel) = 0) or (Sel[0] < 0) or (Sel[0] >= FResults.Count) then Exit;
  OpenFolderWithWindow(Self, PRGScanResult(FResults[Sel[0]])^.FilePath);
end;

procedure TReplayGainForm.GridStyle(Sender: TObject; Row: Integer; var ABold: Boolean; var AColor: TARGB);
begin
  if (Row >= 0) and (Row < FResults.Count) and (PRGScanResult(FResults[Row])^.Status <> rsReadyToSave) then
    AColor := clWarn;
end;

procedure TReplayGainForm.HideClick(Sender: TObject);
begin
  Hide;
end;

procedure TReplayGainForm.StopClick(Sender: TObject);
begin
  FBtnStop.Enabled := False;
  FTrack.Caption := STATUS_RG_HALTING;
  FStopPending := True;
  if FThread <> nil then FThread.Terminate;
end;

procedure TReplayGainForm.SaveClick(Sender: TObject);
var
  I: Integer;
  R: PRGScanResult;
  Job: PMetadataJob;
  Batch: TList;
begin
  if (FResults.Count = 0) or FCommitting then Exit;
  FCommitting := True;
  FBtnSave.Enabled := False;
  FBtnCancel.Enabled := False;
  Batch := TList.Create;
  try
    for I := 0 to FResults.Count - 1 do
    begin
      R := PRGScanResult(FResults[I]);
      if not (R^.Status in [rsReadyToSave, rsTrackOnly]) then Continue;
      New(Job);
      Job^ := Default(TMetadataJob);
      Job^.FilePath := R^.FilePath;
      Job^.AlbumName := R^.Album;
      Job^.ActionType := matReplayGain;
      Job^.ReplayGain.TrackGain := R^.TrackGain;
      Job^.ReplayGain.TrackPeak := R^.TrackPeak;
      Job^.ReplayGain.AlbumGain := R^.AlbumGain;
      Job^.ReplayGain.AlbumPeak := R^.AlbumPeak;
      Job^.ReplayGain.TrackOnly := R^.Status = rsTrackOnly;
      Batch.Add(Job);
    end;
    if Batch.Count > 0 then
    begin
      if AppStateManager <> nil then AppStateManager.EnqueueMetadataBatch(Batch)
      else
        for I := 0 to Batch.Count - 1 do Dispose(PMetadataJob(Batch[I]));
    end;
  finally
    Batch.Free;
    FCommitting := False;
  end;
  Teardown;
end;

procedure TReplayGainForm.CancelClick(Sender: TObject);
begin
  Teardown;
end;

{ a running scan stops first (the window closes once it has ended) }
procedure TReplayGainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FCommitting then
  begin
    CanClose := False;
    Exit;
  end;
  if FThread <> nil then
  begin
    CanClose := False;
    FStopPending := True;
    FBtnStop.Enabled := False;
    FTrack.Caption := STATUS_RG_ABORTING;
    FThread.Terminate;
    Exit;
  end;
  CanClose := True;
end;

procedure TReplayGainForm.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  CloseAction := caNone;
  Teardown;
end;

procedure TReplayGainForm.Teardown;
begin
  if FThread <> nil then
  begin
    FThread.OnTerminate := nil;
    FThread.Detach;
    FThread.Terminate;
  end;
  if AppStateManager <> nil then
  begin
    AppStateManager.PopState(esReplayGainBusy);
    AppStateManager.ShowReplayGainLabel(False);
  end;
  if FLibrary <> nil then FLibrary.TryDispatchPendingQueue;
  if Application.MainForm <> nil then Application.MainForm.BringToFront;
  Hide;
  if GRgForm = Self then GRgForm := nil;
  Release;
end;

procedure TReplayGainForm.StopThread;
var
  T: TReplayGainThread;
begin
  if FThread <> nil then
  begin
    T := FThread;
    FThread := nil;
    T.OnTerminate := nil;
    T.Detach;
    T.LibraryManager := nil;
    T.FreeOnTerminate := False;
    T.Terminate;
    T.WaitFor;
    TThread.RemoveQueuedEvents(T);
    T.Free;
  end;
  if FFinished <> nil then
  begin
    FFinished.WaitFor;
    TThread.RemoveQueuedEvents(FFinished);
    FreeAndNil(FFinished);
  end;
end;

end.
