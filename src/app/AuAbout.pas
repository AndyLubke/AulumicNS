unit AuAbout;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - AuAbout
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The About window (Main menu > About...): the logo, the name, the version and
  build of this program file (uVersionHelper: read from the file itself), the
  data folder and the project's page as links, the credits. "Copy info" puts the facts on the clipboard for a
  problem report. "Check for updates" asks GitHub for the latest release when
  it is clicked (uUpdateCheck) and says in the line beside it what it found;
  with a newer version there, the New version box comes up and the button
  opens the download page.

  The New version box (PromptNewVersion) is also what the check at start
  shows: open the download page, not now, or - at start only - skip this
  version.
  =============================================================================}

interface

uses
  Classes, SysUtils, Controls, Forms, ExtCtrls, LCLType, LCLIntf, Clipbrd,
  AuGfx, AuTheme, AuControls, AuForms;

{ the window, not shown (the main window shows it modal; the screenshot mode
  renders it). ADemo: no folder of this PC in it. }
function CreateAboutForm(AOwner: TComponent; ADemo: Boolean = False): TAuForm;
procedure ShowAbout(AOwner: TComponent);

type
  TUpdateChoice = (ucNotNow, ucOpen, ucSkip);

{ The version a check for updates compares with the latest release: this
  program's. The debug switch --test-update-as=<version> puts another one in
  its place (an older one shows the New version box). }
function VersionForUpdateCheck: string;
{ the New version box, not shown. AWithSkip: with "Skip this version" (the
  check at start; a check the user asked for has nothing to skip). }
function CreateUpdatePromptForm(AOwner: TComponent; const ALatest: string; AWithSkip: Boolean = True): TAuForm;
{ Shows the box for version ALatest and does what was chosen: opens the
  download page, or remembers the version as skipped (the settings). }
function PromptNewVersion(AOwner: TComponent; const ALatest: string; AWithSkip: Boolean = True): TUpdateChoice;

implementation

uses
  AuAppIcon, AuSettings, uVersionHelper, uUpdateCheck, uSettingsManager, uOSUtils;

const
  ABOUT_W   = 580;
  ABOUT_H   = 602;
  MARGIN    = 28;
  LOGO      = 84;
  ROW_H     = 26;
  LABEL_W   = 110;
  ROWS_TOP  = 176;
  CHECK_TOP = 122;
  CHECK_W   = 170;
  CHECK_POLL_MS = 100;
  ROW_COUNT = 6;

  { the program is called Aulumic, its file AulumicNS.exe (the name it was
    developed under): what the NS stands for }
  NS_MEANING = 'NS stands for Native Sound';

  { the project's page: the releases, the source, the README }
  PROJECT_PAGE_URL  = 'https://github.com/AndyLubke/AulumicNS';
  PROJECT_PAGE_TEXT = 'github.com/AndyLubke/AulumicNS';

  TAGLINE = 'Bit-perfect music player for Windows';
  CREDITS =
    'Developed with Lazarus and Free Pascal. The FLAC decoder, the resampler, the EBU R128 ' +
    'loudness meter and the user interface are own code; booklets are shown with the PDF ' +
    'engine of Windows.' + LineEnding + LineEnding +
    'Tag reading and writing: AulumicTag, a fork of OvoTag, Copyright © 2011 Marco Caselli, ' +
    'modified LGPL. Artist information comes from Last.fm, Wikipedia and TheAudioDB. ' +
    'ASIO is a trademark and software of Steinberg Media Technologies GmbH.' +
    LineEnding + LineEnding +
    'Aulumic is free software under the GNU General Public License, version 3: it may be ' +
    'used, shared and changed. It comes without any warranty. The source code is on GitHub.';

type
  { the background: the logo and the two thin lines around the facts }
  TAboutArt = class(TAuControl)
  protected
    procedure DoPaint(G: TGfx); override;
  end;

  TAboutForm = class(TAuForm)
  private
    FInfo: string;
    FCheck: TUpdateCheck;        // the running check, nil without one
    FCheckTimer: TTimer;         // looks whether it has ended
    FCheckBtn: TAuButton;
    FCheckNote: TAuLabel;
    FNewerFound: Boolean;        // the button opens the download page
    FDataDir: string;            // the data folder as a link ('' in the screenshots: a made-up one)
    procedure CopyClick(Sender: TObject);
    procedure CheckClick(Sender: TObject);
    procedure CheckTick(Sender: TObject);
    procedure CheckNote(const AText: string; ARole: TAuRole);
    function Row(AIndex: Integer; const AName, AValue: string): TAuLabel;
    procedure WebClick(Sender: TObject);
    procedure DataClick(Sender: TObject);
  public
    constructor CreateAbout(AOwner: TComponent; ADemo: Boolean);
    destructor Destroy; override;
  end;

procedure TAboutArt.DoPaint(G: TGfx);
var
  Y: Integer;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  DrawAppLogo(G, S(MARGIN), S(24), S(LOGO));
  Y := S(ROWS_TOP - 14);
  G.FillRect(S(MARGIN), Y, Width - 2 * S(MARGIN), 1, clBorder);
  Y := S(ROWS_TOP + ROW_COUNT * ROW_H + 10);
  G.FillRect(S(MARGIN), Y, Width - 2 * S(MARGIN), 1, clBorder);
end;

{ a row of the facts; the label of its value }
function TAboutForm.Row(AIndex: Integer; const AName, AValue: string): TAuLabel;
var
  L: TAuLabel;
  Y: Integer;
begin
  Y := ROWS_TOP + AIndex * ROW_H;
  L := AddLabel(Self, AName, MARGIN, Y, LABEL_W, True);
  L.Height := S(ROW_H);
  L := AddLabel(Self, AValue, MARGIN + LABEL_W + 12, Y, ABOUT_W - 2 * MARGIN - LABEL_W - 12, False);
  L.Height := S(ROW_H);
  Result := L;
  FInfo := FInfo + AName + ': ' + AValue + LineEnding;
end;

procedure TAboutForm.WebClick(Sender: TObject);
begin
  OpenURL(PROJECT_PAGE_URL);
end;

procedure TAboutForm.DataClick(Sender: TObject);
begin
  if FDataDir <> '' then RevealFileInExplorer(IncludeTrailingPathDelimiter(FDataDir));
end;

constructor TAboutForm.CreateAbout(AOwner: TComponent; ADemo: Boolean);
var
  Art: TAboutArt;
  L: TAuLabel;
  B: TAuButton;
  TX, Y: Integer;
  DataDir, Copyright: string;
begin
  CreateAu(AOwner, 'About Aulumic', ABOUT_W, ABOUT_H);
  BorderIcons := [biSystemMenu];
  Position := poOwnerFormCenter;

  { first, so it lies below the labels }
  Art := TAboutArt.Create(Self);
  Art.Parent := Body;
  Art.Align := alClient;
  Art.FocusOnClick := False;

  TX := MARGIN + LOGO + 24;
  L := AddLabel(Self, 'Aulumic', TX, 22, ABOUT_W - TX - MARGIN, False);
  L.FontSize := 26;
  L.Bold := True;
  L.Height := S(40);
  L := AddLabel(Self, TAGLINE, TX, 64, ABOUT_W - TX - MARGIN, True);
  L.FontSize := 14;
  L.Height := S(24);
  L := AddLabel(Self, 'Version ' + GetAppVersion, TX, 90, ABOUT_W - TX - MARGIN, False);
  L.FontSize := 14;
  L.TextRole := crAccent;
  L.Height := S(24);

  FCheckBtn := AddButton(Self, 'Check for updates', TX, CHECK_TOP, CHECK_W, bkNormal, @CheckClick);
  FCheckBtn.Height := S(30);
  FCheckBtn.Hint := 'Ask GitHub whether a newer version is available.';
  FCheckBtn.ShowHint := True;
  FCheckNote := AddLabel(Self, '', TX + CHECK_W + 12, CHECK_TOP, ABOUT_W - TX - CHECK_W - 12 - MARGIN, True);
  FCheckNote.Height := S(30);
  FCheckTimer := TTimer.Create(Self);
  FCheckTimer.Enabled := False;
  FCheckTimer.Interval := CHECK_POLL_MS;
  FCheckTimer.OnTimer := @CheckTick;

  if ADemo then DataDir := 'C:\Music Player\Data\' else DataDir := AppDataDir;
  Copyright := GetAppCopyright;
  if Copyright = '' then Copyright := 'Copyright (c) 2026 André Lubke';
  Copyright := StringReplace(Copyright, 'Copyright ', '', [rfIgnoreCase]);
  Copyright := StringReplace(Copyright, '(c)', '©', [rfIgnoreCase]);
  { the version is in the head; the copied text has it as its first line }
  FInfo := 'Aulumic ' + GetAppVersion + LineEnding;
  Row(0, 'Built', GetAppBuildDate);
  Row(1, 'Made with', GetCompilerInfo);
  { the folder with the library, the settings and the log, as a link }
  L := Row(2, 'Data folder', DataDir);
  if not ADemo then FDataDir := DataDir;
  L.TextRole := crAccent;
  L.Cursor := crHandPoint;
  L.Hint := 'Open the data folder in Explorer.';
  L.ShowHint := True;
  L.OnClick := @DataClick;
  L.FitWidth;
  Row(3, 'Program file', ExtractFileName(ParamStr(0)) + ' - ' + NS_MEANING);
  { the project's page as a link }
  L := Row(4, 'Website', PROJECT_PAGE_TEXT);
  L.TextRole := crAccent;
  L.Cursor := crHandPoint;
  L.Hint := 'Open the project page in the browser.';
  L.ShowHint := True;
  L.OnClick := @WebClick;
  L.FitWidth;          // only the text is the link, not the whole row
  Row(5, 'Copyright', Copyright);

  Y := ROWS_TOP + ROW_COUNT * ROW_H + 24;
  L := AddLabel(Self, CREDITS, MARGIN, Y, ABOUT_W - 2 * MARGIN, True);
  L.WordWrap := True;
  L.VAlign := 0;
  L.FontSize := 12;
  L.Height := S(ABOUT_H - 64 - Y - 8);

  B := AddButton(Self, 'Copy info', MARGIN, ABOUT_H - 54, 120, bkNormal, @CopyClick);
  B.Hint := 'Copy the version and build of this program, for a problem report.';
  B.ShowHint := True;
  B := AddButton(Self, 'Close', ABOUT_W - MARGIN - 110, ABOUT_H - 54, 110, bkPrimary);
  B.ModalResult := mrOK;
  DefaultButton := B;
  ActiveControl := B;
end;

destructor TAboutForm.Destroy;
begin
  { a check that still runs ends on its own; nothing waits for it here }
  ReleaseUpdateCheck(FCheck);
  inherited Destroy;
end;

procedure TAboutForm.CheckNote(const AText: string; ARole: TAuRole);
begin
  FCheckNote.TextRole := ARole;
  FCheckNote.Caption := AText;
  FCheckNote.Invalidate;
end;

procedure TAboutForm.CheckClick(Sender: TObject);
begin
  if FNewerFound then
  begin
    OpenURL(UPDATE_PAGE_URL);
    Exit;
  end;
  if FCheck <> nil then Exit;
  FCheck := TUpdateCheck.Create(VersionForUpdateCheck);
  FCheckBtn.Enabled := False;
  CheckNote('Checking...', crTextDim);
  FCheckTimer.Enabled := True;
end;

procedure TAboutForm.CheckTick(Sender: TObject);
var
  State: TUpdateState;
  Latest: string;
begin
  if (FCheck <> nil) and not FCheck.Finished then Exit;
  FCheckTimer.Enabled := False;
  if FCheck = nil then Exit;
  State := FCheck.State;
  Latest := FCheck.Latest;
  ReleaseUpdateCheck(FCheck);
  FCheckBtn.Enabled := True;
  case State of
    usNewer:
      begin
        FNewerFound := True;
        FCheckBtn.Caption := 'Open download page';
        FCheckBtn.Hint := 'Open the page of the newest version in the browser.';
        FCheckBtn.Invalidate;
        CheckNote('Version ' + Latest + ' is available.', crAccent);
        PromptNewVersion(Self, Latest, False);
      end;
    usUpToDate: CheckNote('Aulumic is up to date.', crText);
  else
    CheckNote('Could not check (no connection).', crTextDim);
  end;
end;

procedure TAboutForm.CopyClick(Sender: TObject);
begin
  Clipboard.AsText := FInfo;
end;

function VersionForUpdateCheck: string;
begin
  Result := GetAppVersion;
  {$IFDEF DEBUG}
  if Application.HasOption('test-update-as') then Result := Application.GetOptionValue('test-update-as');
  {$ENDIF}
end;

function CreateUpdatePromptForm(AOwner: TComponent; const ALatest: string; AWithSkip: Boolean): TAuForm;
const
  W = 540;
  PAD = 24;
  BTN_Y = 96;
var
  F: TAuForm;
  L: TAuLabel;
  B: TAuButton;
begin
  F := TAuForm.CreateAu(AOwner, 'New version', W, BTN_Y + 34 + 22);
  F.BorderIcons := [biSystemMenu];
  if AOwner is TCustomForm then F.Position := poOwnerFormCenter else F.Position := poScreenCenter;
  L := F.AddLabel(F, 'Aulumic ' + ALatest + ' is available.', PAD, 20, W - 2 * PAD, False);
  L.FontSize := 14;
  L.Height := S(26);
  L := F.AddLabel(F, 'This is version ' + GetAppVersion + '.', PAD, 48, W - 2 * PAD, True);
  L.Height := S(24);
  if AWithSkip then
  begin
    B := F.AddButton(F, 'Skip this version', PAD, BTN_Y, 160);
    B.ModalResult := mrIgnore;
    B.Hint := 'Do not show this at start again until a version after this one is there.';
    B.ShowHint := True;
  end;
  B := F.AddButton(F, 'Not now', W - PAD - 190 - 10 - 100, BTN_Y, 100);
  B.ModalResult := mrCancel;
  B := F.AddButton(F, 'Open download page', W - PAD - 190, BTN_Y, 190, bkPrimary);
  B.ModalResult := mrOK;
  B.Hint := 'Open the page of the new version in the browser.';
  B.ShowHint := True;
  F.DefaultButton := B;
  F.ActiveControl := B;
  Result := F;
end;

function PromptNewVersion(AOwner: TComponent; const ALatest: string; AWithSkip: Boolean): TUpdateChoice;
var
  F: TAuForm;
begin
  Result := ucNotNow;
  F := CreateUpdatePromptForm(AOwner, ALatest, AWithSkip);
  try
    case F.ShowModal of
      mrOK: Result := ucOpen;
      mrIgnore: Result := ucSkip;
    end;
  finally
    F.Free;
  end;
  case Result of
    ucOpen: OpenURL(UPDATE_PAGE_URL);
    ucSkip: AppSettings.Data.SkippedVersion := ALatest;
  end;
end;

function CreateAboutForm(AOwner: TComponent; ADemo: Boolean): TAuForm;
begin
  Result := TAboutForm.CreateAbout(AOwner, ADemo);
end;

procedure ShowAbout(AOwner: TComponent);
var
  F: TAuForm;
begin
  F := CreateAboutForm(AOwner);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.
