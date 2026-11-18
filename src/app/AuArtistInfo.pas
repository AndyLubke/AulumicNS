unit AuArtistInfo;

{ ==============================================================================
  AulumicNS - AuArtistInfo
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Artist Info (Aulumic's uPanelArtistInfo in its popup; a click on an artist
  in the banner): the biography and picture from Last.fm / Wikipedia /
  TheAudioDB (uLastFmScraper, one worker thread), saved in Data\MusicInfo,
  and how much of the artist the library holds. The biography can be edited
  (F2) and the picture replaced (Ctrl+O, a dropped file, Ctrl+V) or removed
  (Del); the user's own biography and picture are kept by Refresh (F5).
  One window; it follows the next artist when it is opened again.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, Dialogs, LCLType,
  LCLIntf, Clipbrd, Graphics,
  AuGfx, AuTheme, AuIcons, AuControls, AuForms, uLibraryManager;

procedure ShowArtistInfo(AOwner: TComponent; ALibrary: TLibraryManager; const AArtist: string);
procedure CloseArtistInfo;
{ the window with a given text and no lookup (screenshot mode) }
function CreateArtistInfoDemo(AOwner: TComponent; const AArtist, ABio, AStats: string;
  AEditing: Boolean): TAuForm;

implementation

uses
  uLastFmScraper, uLibraryTypes, uAppConsts, uAppStrings, uOSUtils, AuLog, uSettingsManager;

var
  { the rejected Last.fm key is logged once per session (Aulumic) }
  LastFmKeyRejectedLogged: Boolean = False;

const
  MAX_ARTIST_IMAGE_PX = 800;
  BTN = 38;

type
  { TArtistPicture: the picture, fitted and centred; in edit mode an empty
    box to click when there is none }

  TArtistPicture = class(TAuControl)
  public
    Bitmap: TGfxBitmap;
    Editing: Boolean;
  protected
    procedure DoPaint(G: TGfx); override;
  end;

  { TArtistInfoForm }

  TArtistInfoForm = class(TAuForm)
  private
    FLibrary: TLibraryManager;
    FScraper: TLastFmWorker;
    FLoadTimer: TTimer;
    FArtistLbl, FStatsLbl, FEditHint: TAuLabel;
    FBtnWeb, FBtnPic, FBtnClear, FBtnEdit, FBtnRefresh: TAuIconButton;
    FPicView: TArtistPicture;
    FBioMemo: TAuMemo;
    FCurrentArtist: string;
    FQueuedArtist: string;
    FQueuedForce: Boolean;
    FFetching: Boolean;          // between LoadArtist and the scraper's answer
    FIsEditing: Boolean;
    FBioModified: Boolean;
    FBioIsPlaceholder: Boolean;  // the memo shows one of our messages
    FBioText: string;            // the biography shown ('' with a message)
    FModalPromptActive: Boolean;
    FDemo: Boolean;
    procedure LayoutControls;
    procedure SetPicture(B: TGfxBitmap);
    function HasPicture: Boolean;
    function BioFilePath: string;
    function ImageFilePath: string;
    procedure SetBioText(const AText: string; AIsPlaceholder: Boolean);
    function IsPlaceholderBioText(const AText: string): Boolean;
    procedure CancelLookup;
    procedure StopTimer;
    procedure UpdateButtons;
    procedure SetEditMode(AEnable: Boolean);
    procedure SaveBioIfNeeded;
    function SaveImageBytes(const ABytes: TBytes): Boolean;
    function LoadImageFile(const AFileName: string): Boolean;
    function PasteImage: Boolean;
    procedure LoadTimer(Sender: TObject);
    procedure BioReceived(const AArtistName, ABioText, AImagePath: string);
    procedure BioChange(Sender: TObject);
    procedure WebClick(Sender: TObject);
    procedure PicClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure PicViewClick(Sender: TObject);
    procedure FormDrop(Sender: TObject; const FileNames: array of string);
    function AddBtn(AIcon: TAuIcon; const AHint: string; AClick: TNotifyEvent): TAuIconButton;
  protected
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateInfo(AOwner: TComponent; ALibrary: TLibraryManager);
    destructor Destroy; override;
    procedure LoadArtist(const AArtist: string; ForceRefresh: Boolean = False);
    procedure ShowDemo(const AArtist, ABio, AStats: string; AEditing: Boolean);
  end;

var
  GArtistInfo: TArtistInfoForm = nil;

procedure ShowArtistInfo(AOwner: TComponent; ALibrary: TLibraryManager; const AArtist: string);
begin
  if GArtistInfo = nil then GArtistInfo := TArtistInfoForm.CreateInfo(AOwner, ALibrary);
  GArtistInfo.Show;
  if GArtistInfo.WindowState = wsMinimized then GArtistInfo.WindowState := wsNormal;
  GArtistInfo.BringToFront;
  GArtistInfo.LoadArtist(AArtist);
end;

procedure CloseArtistInfo;
begin
  FreeAndNil(GArtistInfo);
end;

function CreateArtistInfoDemo(AOwner: TComponent; const AArtist, ABio, AStats: string;
  AEditing: Boolean): TAuForm;
var
  F: TArtistInfoForm;
begin
  F := TArtistInfoForm.CreateInfo(AOwner, nil);
  F.ShowDemo(AArtist, ABio, AStats, AEditing);
  Result := F;
end;

{ an empty marker file: the biography / picture is the user's own }
procedure WriteUserMarker(const APath: string);
var
  FS: TFileStream;
begin
  try
    FS := TFileStream.Create(APath, fmCreate);
    FS.Free;
  except
    { a missing marker only means Refresh may replace the item }
  end;
end;

{ ---- TArtistPicture ---- }

procedure TArtistPicture.DoPaint(G: TGfx);
var
  BW, BH: Integer;
  K, W, H: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if (Bitmap = nil) or not BitmapSize(Bitmap, BW, BH) or (BW <= 0) or (BH <= 0) then
  begin
    if Editing then
    begin
      G.FillRound(0, 0, Width, Height, S(10), Blend(EffBack, clText, 0.04));
      G.StrokeRound(0, 0, Width, Height, S(10), 1, clBorder);
      DrawIcon(G, icImage, Width / 2, Height / 2, S(36), clTextFaint);
    end;
    Exit;
  end;
  K := Math.Min(Width / BW, Height / BH);
  W := BW * K;
  H := BH * K;
  G.DrawBitmap(Bitmap, (Width - W) / 2, (Height - H) / 2, W, H);
end;

{ ---- TArtistInfoForm ---- }

function TArtistInfoForm.AddBtn(AIcon: TAuIcon; const AHint: string; AClick: TNotifyEvent): TAuIconButton;
begin
  Result := TAuIconButton.Create(Self);
  Result.Parent := Body;
  Result.Icon := AIcon;
  Result.Hint := AHint;
  Result.ShowHint := True;
  Result.OnClick := AClick;
end;

constructor TArtistInfoForm.CreateInfo(AOwner: TComponent; ALibrary: TLibraryManager);
var
  W, H: Integer;
begin
  { ---> AulumicNS: wider at first (was 600 x 780), then the size it had }
  ToolWindowSize(AppSettings.Data.ArtistWinW, AppSettings.Data.ArtistWinH, 900, 780, W, H);
  CreateAu(AOwner, 'Artist Info', W, H);
  DropIn := VIEWER_DROP_PX;                // comes down from above as it opens
  HelpKeyword := 'Artist Info';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Constraints.MinWidth := S(400);
  Constraints.MinHeight := S(420);
  FitToWorkArea;
  FLibrary := ALibrary;
  FArtistLbl := AddLabel(Self, '', 20, 14, 400, False);
  FArtistLbl.FontSize := 18;
  FArtistLbl.Bold := True;
  FBtnWeb := AddBtn(icGlobe, HINT_ARTIST_WEB, @WebClick);
  FBtnPic := AddBtn(icImage, HINT_ARTIST_IMAGE, @PicClick);
  FBtnClear := AddBtn(icTrash, HINT_ARTIST_CLEAR_IMAGE, @ClearClick);
  FBtnEdit := AddBtn(icEdit, HINT_ARTIST_EDIT_START, @EditClick);
  FBtnRefresh := AddBtn(icRefresh, HINT_ARTIST_REFRESH, @RefreshClick);
  FPicView := TArtistPicture.Create(Self);
  FPicView.Parent := Body;
  FPicView.FocusOnClick := False;
  FPicView.OnClick := @PicViewClick;
  FStatsLbl := AddLabel(Self, '', 20, 0, 400);
  FStatsLbl.FontSize := 12;
  FStatsLbl.HAlign := 1;
  FBioMemo := TAuMemo.Create(Self);
  FBioMemo.Parent := Body;
  FBioMemo.ReadOnly := True;
  FBioMemo.Plain := True;
  FBioMemo.TextSize := 14;
  FBioMemo.OnChange := @BioChange;
  FEditHint := AddLabel(Self, HINT_ARTIST_MEMO_EDIT, 20, 0, 400);
  FEditHint.FontSize := 12;
  FEditHint.Visible := False;
  FLoadTimer := TTimer.Create(Self);
  FLoadTimer.Enabled := False;
  FLoadTimer.Interval := PANEL_LOAD_DELAY_MS;
  FLoadTimer.OnTimer := @LoadTimer;
  AllowDropFiles := True;
  OnDropFiles := @FormDrop;
  { the biography has the focus: the arrows and page keys scroll it }
  ActiveControl := FBioMemo;
  UpdateButtons;
  LayoutControls;
end;

destructor TArtistInfoForm.Destroy;
begin
  SaveBioIfNeeded;
  StopTimer;
  { aborts a running request and waits for the worker: it never calls back
    into a window that is gone }
  FreeAndNil(FScraper);
  SetPicture(nil);
  if GArtistInfo = Self then GArtistInfo := nil;
  inherited Destroy;
end;

procedure TArtistInfoForm.DoClose(var CloseAction: TCloseAction);
begin
  SaveBioIfNeeded;
  inherited DoClose(CloseAction);
  CloseAction := caFree;
end;

function TArtistInfoForm.HasPicture: Boolean;
begin
  Result := (FPicView <> nil) and (FPicView.Bitmap <> nil);
end;

procedure TArtistInfoForm.SetPicture(B: TGfxBitmap);
begin
  if FPicView = nil then
  begin
    if B <> nil then DisposeBitmap(B);
    Exit;
  end;
  if FPicView.Bitmap <> nil then DisposeBitmap(FPicView.Bitmap);
  FPicView.Bitmap := B;
  FPicView.Invalidate;
end;

procedure TArtistInfoForm.LayoutControls;
var
  W, H, Y, X, PicH, Bottom: Integer;
  BioVisible: Boolean;
begin
  if FEditHint = nil then Exit;
  W := ClientWidth;
  H := BodyHeight;
  X := W - S(20) - S(BTN);
  FBtnRefresh.SetBounds(X, S(12), S(BTN), S(BTN)); Dec(X, S(BTN));
  FBtnEdit.SetBounds(X, S(12), S(BTN), S(BTN)); Dec(X, S(BTN));
  FBtnClear.SetBounds(X, S(12), S(BTN), S(BTN)); Dec(X, S(BTN));
  FBtnPic.SetBounds(X, S(12), S(BTN), S(BTN)); Dec(X, S(BTN));
  FBtnWeb.SetBounds(X, S(12), S(BTN), S(BTN));
  FArtistLbl.SetBounds(S(20), S(12), Math.Max(S(40), X - S(28)), S(BTN));
  Y := S(64);
  { Aulumic: without a biography the picture takes the whole window }
  BioVisible := FIsEditing or FFetching or (not HasPicture) or (Trim(FBioText) <> '');
  if FIsEditing then Bottom := S(44) else Bottom := S(16);
  if HasPicture or FIsEditing then
  begin
    if not HasPicture then PicH := S(120)
    else if BioVisible then PicH := Math.Min(W - S(40), S(300))
    else PicH := H - Y - S(30) - Bottom;
    PicH := Math.Max(S(40), PicH);
    FPicView.SetBounds(S(20), Y, W - S(40), PicH);
    FPicView.Visible := True;
    Inc(Y, PicH + S(10));
  end
  else
    FPicView.Visible := False;
  FPicView.Editing := FIsEditing;
  if FIsEditing then FPicView.Cursor := crHandPoint else FPicView.Cursor := crDefault;
  FStatsLbl.SetBounds(S(20), Y, W - S(40), S(22));
  Inc(Y, S(30));
  FBioMemo.Visible := BioVisible;
  FBioMemo.SetBounds(S(20), Y, W - S(40), Math.Max(S(40), H - Y - Bottom));
  FEditHint.Visible := FIsEditing;
  FEditHint.SetBounds(S(20), H - S(34), W - S(40), S(22));
end;

procedure TArtistInfoForm.Resize;
begin
  inherited Resize;
  LayoutControls;
  { ---> AulumicNS: the size for the next time (not a maximized one) }
  if Showing and (WindowState = wsNormal) then
    SizeToRemember(AppSettings.Data.ArtistWinW, AppSettings.Data.ArtistWinH);
end;

function TArtistInfoForm.BioFilePath: string;
begin
  if Trim(FCurrentArtist) = '' then Exit('');
  Result := ResolveArtistCacheDir(FCurrentArtist) + FILE_ARTIST_BIO;
end;

function TArtistInfoForm.ImageFilePath: string;
begin
  if Trim(FCurrentArtist) = '' then Exit('');
  Result := ResolveArtistCacheDir(FCurrentArtist) + FILE_ARTIST_IMAGE;
end;

procedure TArtistInfoForm.SetBioText(const AText: string; AIsPlaceholder: Boolean);
begin
  FBioIsPlaceholder := AIsPlaceholder;
  if AIsPlaceholder then FBioText := '' else FBioText := AText;
  FBioMemo.Text := AText;
end;

{ whether a text the scraper delivered is empty or one of our messages }
function TArtistInfoForm.IsPlaceholderBioText(const AText: string): Boolean;
var
  T: string;
begin
  T := Trim(AText);
  Result := (T = '') or (T = LBL_FETCHING_INFO) or (T = LBL_BIO_UNAVAILABLE) or
    (T = LBL_ARTIST_INFO_UNAVAILABLE) or (T = ERR_LASTFM_MISSING_API_KEY) or
    (T = ERR_LASTFM_GENERIC) or (T = ERR_LASTFM_KEY_REJECTED) or
    (Pos(ERR_LASTFM_NETWORK_PREFIX, T) = 1) or (Pos(ERR_LASTFM_API_PREFIX, T) = 1) or
    (Pos(ERR_LASTFM_PARSE_PREFIX, T) = 1) or (Pos(ERR_LASTFM_RESOLVE_PREFIX, T) = 1);
end;

procedure TArtistInfoForm.CancelLookup;
begin
  if FScraper <> nil then FScraper.Cancel;
  FFetching := False;
end;

procedure TArtistInfoForm.StopTimer;
begin
  if (FLoadTimer <> nil) and FLoadTimer.Enabled then FLoadTimer.Enabled := False;
end;

procedure TArtistInfoForm.UpdateButtons;
var
  HasArtist: Boolean;
begin
  HasArtist := (Trim(FCurrentArtist) <> '') and not FDemo;
  FBtnWeb.Enabled := HasArtist;
  FBtnPic.Enabled := HasArtist;
  FBtnEdit.Enabled := HasArtist;
  FBtnRefresh.Enabled := HasArtist and not FIsEditing;
  FBtnClear.Enabled := HasArtist and HasPicture;
  FBtnEdit.Active := FIsEditing;
  if FIsEditing then FBtnEdit.Hint := HINT_ARTIST_EDIT_DONE else FBtnEdit.Hint := HINT_ARTIST_EDIT_START;
  if FIsEditing then FPicView.Hint := HINT_ARTIST_IMG_EDIT else FPicView.Hint := '';
  FPicView.ShowHint := FIsEditing;
end;

procedure TArtistInfoForm.BioChange(Sender: TObject);
begin
  if not FIsEditing then Exit;
  FBioModified := True;
  FBioText := FBioMemo.Text;
end;

procedure TArtistInfoForm.SaveBioIfNeeded;
var
  BioFile, ArtistDir, CleanText: string;
  SL: TStringList;
begin
  if (not FBioModified) or (Trim(FCurrentArtist) = '') or FDemo then Exit;
  FBioModified := False;
  BioFile := BioFilePath;
  ArtistDir := IncludeTrailingPathDelimiter(ExtractFileDir(BioFile));
  CleanText := Trim(FBioText);
  try
    if CleanText = '' then
    begin
      if FileExists(BioFile) then SysUtils.DeleteFile(BioFile);
      { an emptied biography is fetched from the web again }
      SysUtils.DeleteFile(ArtistDir + FILE_ARTIST_BIO_USER);
    end
    else
    begin
      ForceDirectories(ArtistDir);
      SL := TStringList.Create;
      try
        SL.Text := CleanText;
        if SaveStringsAtomic(SL, BioFile, TEncoding.UTF8) then
          WriteUserMarker(ArtistDir + FILE_ARTIST_BIO_USER);
      finally
        SL.Free;
      end;
    end;
  except
    { a disk error leaves the old biography }
  end;
end;

procedure TArtistInfoForm.SetEditMode(AEnable: Boolean);
begin
  if AEnable = FIsEditing then Exit;
  if AEnable then
  begin
    if Trim(FCurrentArtist) = '' then Exit;
    { a lookup still running must not overwrite the edit }
    StopTimer;
    CancelLookup;
    FIsEditing := True;
    if FBioIsPlaceholder then SetBioText('', False);
    FBioMemo.ReadOnly := False;
    FBioMemo.Plain := False;
    LayoutControls;
    UpdateButtons;
    if FBioMemo.CanFocus then FBioMemo.SetFocus;
  end
  else
  begin
    SaveBioIfNeeded;
    FIsEditing := False;
    FBioMemo.ReadOnly := True;
    FBioMemo.Plain := True;
    if (Trim(FBioText) = '') and not HasPicture then SetBioText(LBL_BIO_UNAVAILABLE, True);
    LayoutControls;
    UpdateButtons;
  end;
end;

{ the picture as a JPEG of at most 800 px in the artist's folder, marked as
  the user's own (Refresh keeps it) }
function TArtistInfoForm.SaveImageBytes(const ABytes: TBytes): Boolean;
var
  B, Check: TGfxBitmap;
  ImgFile, Tmp: string;
begin
  Result := False;
  if (Length(ABytes) < 8) or (Trim(FCurrentArtist) = '') or FDemo then Exit;
  StopTimer;
  CancelLookup;
  B := ImageFromBytes(ABytes, MAX_ARTIST_IMAGE_PX);
  if B = nil then Exit;
  ImgFile := ImageFilePath;
  Tmp := ChangeFileExt(ImgFile, '.tmp.jpg');
  try
    ForceDirectories(ExtractFileDir(ImgFile));
    SysUtils.DeleteFile(Tmp);
    if not SaveBitmapJpeg(B, Tmp) then Exit;
    Check := ImageFromFile(Tmp, 0);
    if Check = nil then Exit;
    DisposeBitmap(Check);
    if CommitAtomicFile(Tmp, ImgFile, False) then
    begin
      WriteUserMarker(ExtractFilePath(ImgFile) + FILE_ARTIST_IMAGE_USER);
      SetPicture(B);
      B := nil;
      Result := True;
    end;
  finally
    if B <> nil then DisposeBitmap(B);
    if FileExists(Tmp) then SysUtils.DeleteFile(Tmp);
  end;
  if Result then
  begin
    LayoutControls;
    UpdateButtons;
  end;
end;

function TArtistInfoForm.LoadImageFile(const AFileName: string): Boolean;
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  Result := False;
  if (AFileName = '') or not FileExists(AFileName) then Exit;
  try
    FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      if (FS.Size < 4) or (FS.Size > 50 * BYTES_PER_MB) then Exit;
      SetLength(Bytes, FS.Size);
      FS.ReadBuffer(Bytes[0], FS.Size);
    finally
      FS.Free;
    end;
  except
    Exit;
  end;
  Result := SaveImageBytes(Bytes);
end;

{ Ctrl+V: a copied picture (as a bitmap, saved and read back as a picture file) }
function TArtistInfoForm.PasteImage: Boolean;
var
  Bmp: Graphics.TBitmap;
  Tmp: string;
begin
  Result := False;
  if (Trim(FCurrentArtist) = '') or FDemo then Exit;
  try
    if not Clipboard.HasFormat(CF_BITMAP) then Exit;
    Tmp := GetTempDir(False) + Format('AulumicNS_artist_%d.bmp', [GetCurrentProcessId]);
    Bmp := Graphics.TBitmap.Create;
    try
      Bmp.LoadFromClipboardFormat(CF_BITMAP);
      Bmp.SaveToFile(Tmp);
    finally
      Bmp.Free;
    end;
    try
      Result := LoadImageFile(Tmp);
    finally
      SysUtils.DeleteFile(Tmp);
    end;
  except
    Result := False;
  end;
end;

procedure TArtistInfoForm.FormDrop(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
  Ext: string;
begin
  if (Trim(FCurrentArtist) = '') or FModalPromptActive then Exit;
  for I := 0 to High(FileNames) do
  begin
    Ext := LowerCase(ExtractFileExt(FileNames[I]));
    if ((Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.png') or (Ext = '.bmp')) and LoadImageFile(FileNames[I]) then
      Break;
  end;
end;

procedure TArtistInfoForm.WebClick(Sender: TObject);
begin
  if Trim(FCurrentArtist) = '' then Exit;
  { Aulumic: the search is for copying text in, so editing starts }
  SetEditMode(True);
  OpenURL('https://www.google.com/search?q=' + SimpleURLEncode(ExtractFirstArtist(FCurrentArtist) + ' biography'));
end;

procedure TArtistInfoForm.PicClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  if (Trim(FCurrentArtist) = '') or FModalPromptActive then Exit;
  D := TOpenDialog.Create(Self);
  FModalPromptActive := True;
  try
    D.Title := DLG_SELECT_ARTIST_PIC_TITLE;
    D.Filter := DLG_FILTER_ARTIST_PIC;
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then LoadImageFile(D.FileName);
  finally
    FModalPromptActive := False;
    D.Free;
  end;
end;

procedure TArtistInfoForm.ClearClick(Sender: TObject);
var
  ImgFile: string;
  Res: TModalResult;
begin
  if (Trim(FCurrentArtist) = '') or (not HasPicture) or FModalPromptActive then Exit;
  FModalPromptActive := True;
  try
    Res := AuMessage(SafeFormat(MSG_REMOVE_ARTIST_PIC_CONFIRM, [FCurrentArtist]), amWarning, abYesNo,
      DLG_REMOVE_ARTIST_PIC_TITLE);
  finally
    FModalPromptActive := False;
  end;
  if Res <> mrYes then Exit;
  StopTimer;
  CancelLookup;
  ImgFile := ImageFilePath;
  if ImgFile <> '' then
  begin
    if FileExists(ImgFile) then SysUtils.DeleteFile(ImgFile);
    { without a picture, Refresh may download one again }
    SysUtils.DeleteFile(ExtractFilePath(ImgFile) + FILE_ARTIST_IMAGE_USER);
  end;
  SetPicture(nil);
  if (not FIsEditing) and (not FBioIsPlaceholder) and (Trim(FBioText) = '') then
    SetBioText(LBL_BIO_UNAVAILABLE, True);
  LayoutControls;
  UpdateButtons;
end;

procedure TArtistInfoForm.EditClick(Sender: TObject);
begin
  SetEditMode(not FIsEditing);
end;

procedure TArtistInfoForm.PicViewClick(Sender: TObject);
begin
  if FIsEditing then PicClick(Sender);
end;

procedure TArtistInfoForm.RefreshClick(Sender: TObject);
var
  BioFile, ImgFile: string;
  HasSavedBio, HasSavedImg: Boolean;
begin
  if (FCurrentArtist = '') or FIsEditing or FModalPromptActive or FDemo then Exit;
  BioFile := BioFilePath;
  ImgFile := ImageFilePath;
  { the user's own biography / picture are kept, so only downloaded ones ask }
  HasSavedBio := FileExists(BioFile) and (Trim(FBioText) <> '') and
    not FileExists(ExtractFilePath(BioFile) + FILE_ARTIST_BIO_USER);
  HasSavedImg := FileExists(ImgFile) and not FileExists(ExtractFilePath(ImgFile) + FILE_ARTIST_IMAGE_USER);
  if HasSavedBio or HasSavedImg then
  begin
    FModalPromptActive := True;
    try
      if AuMessage(SafeFormat(MSG_REFRESH_ARTIST_CONFIRM, [FCurrentArtist]), amQuestion, abYesNo,
        DLG_REFRESH_ARTIST_TITLE) <> mrYes then Exit;
    finally
      FModalPromptActive := False;
    end;
  end;
  LoadArtist(FCurrentArtist, True);
end;

procedure TArtistInfoForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if FModalPromptActive then
  begin
    inherited KeyDown(Key, Shift);
    Exit;
  end;
  if (Key = Ord('V')) and (Shift = [ssCtrl]) and PasteImage then
  begin
    Key := 0;
    Exit;
  end;
  if (Key = Ord('O')) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    PicClick(nil);
    Exit;
  end;
  if Shift = [] then
    case Key of
      VK_F2:
        begin
          Key := 0;
          SetEditMode(not FIsEditing);
          Exit;
        end;
      VK_F5:
        begin
          Key := 0;
          if FBtnRefresh.Enabled then RefreshClick(nil);
          Exit;
        end;
      VK_DELETE:
        { while editing, Del belongs to the biography }
        if not FIsEditing then
        begin
          Key := 0;
          if FBtnClear.Enabled then ClearClick(nil);
          Exit;
        end;
      VK_ESCAPE:
        { Esc ends editing first, then closes }
        if FIsEditing then
        begin
          Key := 0;
          SetEditMode(False);
          if FBioMemo.Visible and FBioMemo.CanFocus then FBioMemo.SetFocus;
          Exit;
        end;
    end;
  inherited KeyDown(Key, Shift);
end;

{ ---- loading ---- }

procedure TArtistInfoForm.LoadArtist(const AArtist: string; ForceRefresh: Boolean);
begin
  SaveBioIfNeeded;
  FIsEditing := False;
  FBioModified := False;
  FBioMemo.ReadOnly := True;
  FBioMemo.Plain := True;
  StopTimer;
  CancelLookup;
  SetPicture(nil);
  if Trim(AArtist) = '' then
  begin
    FCurrentArtist := '';
    FArtistLbl.Caption := LBL_UNKNOWN_ARTIST;
    FStatsLbl.Caption := '';
    SetBioText(LBL_ARTIST_INFO_UNAVAILABLE, True);
    LayoutControls;
    UpdateButtons;
    Exit;
  end;
  FCurrentArtist := AArtist;
  FArtistLbl.Caption := AArtist;
  FStatsLbl.Caption := '';
  SetBioText(LBL_FETCHING_INFO, True);
  FFetching := True;
  FQueuedArtist := AArtist;
  FQueuedForce := ForceRefresh;
  LayoutControls;
  UpdateButtons;
  { the window first, then the lookup (Aulumic's short delay) }
  FLoadTimer.Enabled := True;
end;

procedure TArtistInfoForm.LoadTimer(Sender: TObject);
var
  Tracks: TTrackList;
  Albums: TStringList;
  I: Integer;
  P: PTrackInfo;
  Cached: string;
begin
  FLoadTimer.Enabled := False;
  if FQueuedArtist <> FCurrentArtist then Exit;
  Cached := ResolveArtistCacheDir(FQueuedArtist) + FILE_ARTIST_IMAGE;
  if FileExists(Cached) then SetPicture(ImageFromFile(Cached, 1600));
  if FLibrary <> nil then
  begin
    Tracks := TTrackList.Create;
    Albums := TStringList.Create;
    try
      Albums.Sorted := True;
      Albums.Duplicates := dupIgnore;
      FLibrary.GetTracksByArtist(FQueuedArtist, Tracks);
      if (Tracks.Count = 0) and (Pos(';', FQueuedArtist) > 0) then
        FLibrary.GetTracksByArtist(ExtractFirstArtist(FQueuedArtist), Tracks);
      for I := 0 to Tracks.Count - 1 do
      begin
        P := Tracks[I];
        if (P <> nil) and (P^.Album <> '') then Albums.Add(P^.Album);
      end;
      FStatsLbl.Caption := SafeFormat(FMT_ARTIST_LIB_STATS, [Albums.Count, Tracks.Count]);
    finally
      Albums.Free;
      Tracks.Free;
    end;
  end;
  LayoutControls;
  UpdateButtons;
  { one permanent worker; a newer request supersedes this one }
  if FScraper = nil then FScraper := TLastFmWorker.Create(@BioReceived);
  FFetching := True;
  FScraper.RequestArtist(FQueuedArtist, FQueuedForce);
end;

procedure TArtistInfoForm.BioReceived(const AArtistName, ABioText, AImagePath: string);
begin
  if (ABioText = ERR_LASTFM_KEY_REJECTED) and not LastFmKeyRejectedLogged then
  begin
    LastFmKeyRejectedLogged := True;
    AddWarning(LOG_LASTFM_KEY_REJECTED);
  end;
  if (csDestroying in ComponentState) or (AArtistName <> FCurrentArtist) or FIsEditing then Exit;
  FFetching := False;
  if (AImagePath <> '') and FileExists(AImagePath) then SetPicture(ImageFromFile(AImagePath, 1600));
  if HasPicture and IsPlaceholderBioText(ABioText) then
    SetBioText('', False)
  else
    SetBioText(ABioText, (Trim(ABioText) <> '') and IsPlaceholderBioText(ABioText));
  if (FBioText = '') and not FBioIsPlaceholder and not HasPicture then
    SetBioText(LBL_BIO_UNAVAILABLE, True);
  LayoutControls;
  UpdateButtons;
end;

procedure TArtistInfoForm.ShowDemo(const AArtist, ABio, AStats: string; AEditing: Boolean);
begin
  FCurrentArtist := AArtist;
  FArtistLbl.Caption := AArtist;
  FStatsLbl.Caption := AStats;
  SetBioText(ABio, False);
  FDemo := True;
  if AEditing then
  begin
    FIsEditing := True;
    FBioMemo.ReadOnly := False;
    FBioMemo.Plain := False;
  end;
  LayoutControls;
  UpdateButtons;
  { the buttons look as they would for a real artist }
  FBtnWeb.Enabled := True;
  FBtnPic.Enabled := True;
  FBtnEdit.Enabled := True;
  FBtnRefresh.Enabled := not AEditing;
end;

end.
