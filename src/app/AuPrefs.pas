unit AuPrefs;

{ ==============================================================================
  AulumicNS - AuPrefs
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Preferences dialog (Main menu > Preferences..., Ctrl+P, the gear in the
  title bar): the pages on the left, every setting with a description
  line under its name (no hint bar).

  Nine pages, grouped by
  subject, with CARDS for the settings that are set once and then left
  alone. A card is one row (title, a line that sums up its settings, a
  chevron); a click opens it in place. With all cards closed every page fits
  the dialog without scrolling at 1920 x 1080 / 150 % (the screenshot run
  writes prefs-fit.txt); a page scrolls when open cards make it longer, and
  on smaller screens. The open cards are remembered (PrefsCards). "Related
  settings" buttons lead to the page or card where a neighbouring subject
  lives.

    Library      the library folders (with Scan and Repair), watching the
                 folders, the scan at start
    Appearance   theme and accent (shown at once; Cancel puts them back),
                 the text size. Cards: Main window (the library tree's
                 double click and accordion; the groups and the peak meter
                 shown or not), Text size of the panes
    Playlists    the default grouping and formats of the playlists, cursor
                 follows playback
    Output       WASAPI exclusive / ASIO, the device, the PCM buffer.
                 Related: DSD, Audio thread
    DSD          native DSD, low-pass, gain, the DSD buffer. Related:
                 Output, Resampler
    Resampler    on / off, the target rates, exclusions, DSD. Card: Quality
                 and filter (quality, the phases, bandwidth, anti-aliasing)
    Volume       lock to 100 %, ReplayGain, headroom, soft clipping. Card:
                 ReplayGain scan (tracks at the same time)
    System       keeping the drives awake; animations, the graphics card.
                 Cards: Audio thread (CPU affinity, MMCSS, the timer), Log,
                 Artist information (the user's Last.fm API key)
    Shortcuts    the keyboard shortcuts

  A new setting goes where its subject is: visible when people change it
  now and then, into a card when it is set once. A page that would scroll
  with its cards closed gets a card more, not a page more.
  The dialog edits a copy of the settings and of the folder list; the main
  window applies them after OK (TMainForm.ShowPrefsPage). Scan
  and Repair hand the folder list to the main window at once and start the
  scan; the progress shows in the dialog.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls, AuLists, AuForms, AuFolderPicker,
  uAppConsts, uSettingsManager, uLibraryManager, uPlaybackManager;

type
  { Scan / Repair: apply these folders and scan (FullRebuild = Repair) }
  TPrefsScanEvent = procedure(AFolders: TStrings; FullRebuild: Boolean) of object;

const
  PREFS_LIBRARY = 0;
  PREFS_APPEARANCE = 1;
  PREFS_PLAYLISTS = 2;
  PREFS_OUTPUT = 3;
  PREFS_DSD = 4;
  PREFS_RESAMPLER = 5;
  PREFS_VOLUME = 6;
  PREFS_SYSTEM = 7;
  PREFS_SHORTCUTS = 8;
  PREFS_PAGE_COUNT = 9;

  { the cards (their ids are kept in the settings: PrefsCards) }
  CARD_MAINWINDOW = 'mainwindow';
  CARD_PANETEXT = 'panetext';
  CARD_FILTER = 'filter';
  CARD_RGSCAN = 'rgscan';
  CARD_THREAD = 'thread';
  CARD_LOG = 'log';
  CARD_ARTISTINFO = 'artistinfo';

{ shows AppSettings.Data; with OK (True) its own settings are written back
  into AppSettings.Data and AFolders holds the new library folders. APage < 0
  opens the page shown last time (AppSettings.Data.PrefsPage, always kept). }
function ShowPreferences(AOwner: TComponent; AFolders: TStrings; ALibrary: TLibraryManager;
  AOnScan: TPrefsScanEvent; APage: Integer = -1): Boolean;
{ the open dialog shows the scan's progress; '' = the scan has ended }
procedure PrefsScanStatus(const AText: string);
function PrefsOpen: Boolean;
{ the dialog, not shown (screenshot mode). AOpenCard: this card of the page
  open and in view, all others closed ('': all closed) }
function CreatePrefsForm(AOwner: TComponent; AFolders: TStrings; APage: Integer;
  const AOpenCard: string = ''): TAuForm;
{ the height every page needs and has, one line per page (logical pixels;
  the screenshot run writes it next to the pictures) }
function PrefsPageFit(AForm: TAuForm): string;

var
  { screenshot mode: the device list shows a made-up device instead of the
    devices of this computer (the help screenshots) }
  PrefsDemoDevices: Boolean = False;
{ True when a changed audio setting needs the playing track restarted
  (the device is compared by the caller) }
function PlaybackRestartNeeded(const A, B: TManagerConfig): Boolean;

implementation

uses
  Dialogs, uAppStrings, uLibraryWatcher, uAudioUtils, uSettingsLog, AuDialogs,
  ALAudioEngine;

function PlaybackRestartNeeded(const A, B: TManagerConfig): Boolean;
begin
  Result :=
    (A.VolumeLocked <> B.VolumeLocked) or
    (A.PreampDB <> B.PreampDB) or
    (A.EnableSoftClipping <> B.EnableSoftClipping) or
    (A.AutoHeadroom <> B.AutoHeadroom) or
    (A.UseDoP <> B.UseDoP) or
    (A.AsioNativeDsd <> B.AsioNativeDsd) or
    (A.ResamplePCM <> B.ResamplePCM) or
    (A.TargetSampleRate44 <> B.TargetSampleRate44) or
    (A.TargetSampleRate48 <> B.TargetSampleRate48) or
    (A.ResampleQuality <> B.ResampleQuality) or
    (A.UpsamplePhase <> B.UpsamplePhase) or
    (A.DownsamplePhase <> B.DownsamplePhase) or
    (A.ResampleBandWidthIndex <> B.ResampleBandWidthIndex) or
    (A.ResampleAntiAliasIndex <> B.ResampleAntiAliasIndex) or
    (A.BypassThreshold <> B.BypassThreshold) or
    (A.PCMBufferMs <> B.PCMBufferMs) or
    (A.ReplayGainMode <> B.ReplayGainMode) or
    (A.DisableResampleForDSD <> B.DisableResampleForDSD) or
    (A.DSDBufferMs <> B.DSDBufferMs) or
    (A.DsdToPcmGain <> B.DsdToPcmGain) or
    (A.DsdLowPassFilter <> B.DsdLowPassFilter) or
    (A.UseHighResTimer <> B.UseHighResTimer) or
    (A.OptimizeAffinity <> B.OptimizeAffinity) or
    (A.EnableMMCSS <> B.EnableMMCSS);
end;

type
  TPrefsRow = record
    Ctrl: TControl;
    Cap, Desc: TAuLabel;
  end;

  { the line under a card's title: what its settings are at the moment }
  TCardSummary = function: string of object;

  { the head of a card: its title, the summary, a chevron. A click or the
    space bar opens and closes it. }
  TPrefsCardHead = class(TAuControl)
  private
    FTitle: string;
    FIcon: TAuIcon;
    FOpen: Boolean;
    FOpenA: TAuAnim;                 // 0 = closed, 1 = open: the body on its way
    FSummary: TCardSummary;
    FOnToggle: TNotifyEvent;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Click; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  { the body of a card: its rows, on the card's colour, round at the bottom }
  TPrefsCardBody = class(TAuControl)
  protected
    procedure DoPaint(G: TGfx); override;
  end;

  { what a page consists of, from the top: segments (rows outside cards) and
    the heads and bodies of cards. LayoutPage stacks them. }
  TPrefsBlockKind = (pbSegment, pbHead, pbBody);
  TPrefsBlock = record
    Page: Integer;
    Kind: TPrefsBlockKind;
    Ctrl: TControl;
    H: Integer;                      // unscaled
    Card: Integer;
  end;

  TPrefsCard = record
    Id: string;
    Page: Integer;
    Head: TPrefsCardHead;
    Body: TPrefsCardBody;
  end;

  TPrefsLink = record
    Btn: TAuButton;
    Page: Integer;
    Card: string;
  end;

  { TPrefsForm }

  TPrefsForm = class(TAuForm)
  private
    FData: TAppSettingsData;
    FLibrary: TLibraryManager;
    FOnScan: TPrefsScanEvent;
    FOrigTheme, FOrigAccent: Integer;
    FNav: TAuListView;
    FPages: array of TAuScrollBox;
    FNeed: array of Integer;          // the height each page's content needs (logical)
    FNavCaptions: array of string;
    FNavIcons: array of TAuIcon;
    FRows: array of TPrefsRow;
    FStatus: TAuLabel;
    { the page being built }
    FCur: TWinControl;
    FPageContent: TWinControl;
    FX, FY: Integer;                  // FX: the left edge of the rows (X0; inside a card CARD_PAD)
    FBlocks: array of TPrefsBlock;
    FCards: array of TPrefsCard;
    FLinks: array of TPrefsLink;
    FFirstRow, FFirstSection: Boolean;
    FLastCap, FLastDesc: TAuLabel;
    { library }
    FFolders: TStringList;
    FFolderList: TAuListView;
    FBtnAdd, FBtnRemove, FBtnScan, FBtnRepair: TAuButton;
    FWatch, FRescan, FAccordion, FCursorFollows, FStickyHeaders, FCompactRows: TAuSwitch;
    FDblClick: TAuCombo;
    FScanning: Boolean;
    { output }
    FApi: TAuSegmented;
    FDevice: TAuCombo;
    FDevIds: TStringList;
    FWasapiId, FAsioId: string;
    FDoP, FDsdLowPass: TAuSwitch;
    FDsdGain, FPcmBuffer, FDsdBuffer: TAuCombo;
    { resampler }
    FResample, FNoDsdResample: TAuSwitch;
    FTarget44, FTarget48, FBypass, FQuality, FUpPhase, FDownPhase, FBandwidth, FAntiAlias: TAuCombo;
    { volume }
    FLockVolume, FSoftClip: TAuSwitch;
    FReplayGain, FPreamp: TAuCombo;
    { appearance }
    FTheme: TAuSegmented;
    FAccent: TAuSwatches;
    FAnimations, FGpuPaint: TAuSwitch;
    FTextSize: TAuSegmented;
    FLibFont, FPlFont: TAuEdit;
    FLastFmKey: TAuEdit;
    FGrouping, FHeaderFmt, FTrackFmt: TAuCombo;
    FShowArtist, FShowAlbum, FShowGenre, FPeakMeter: TAuSwitch;
    { system }
    FAffinity, FMMCSS, FKeepAwake, FHighRes, FAlwaysLog: TAuSwitch;
    FRgThreads: TAuCombo;
    FShortcuts: TAuListView;
    { building }
    procedure NewPage(const ACaption: string; AIcon: TAuIcon);
    procedure EndPage;
    procedure StartSegment(AFirstY: Integer);
    procedure CloseSegment;
    procedure AddBlock(AKind: TPrefsBlockKind; ACtrl: TControl; AH, ACard: Integer);
    procedure BeginCard(const AId, ATitle: string; AIcon: TAuIcon; ASummary: TCardSummary);
    procedure EndCard;
    procedure LinkRow(const ATitles: array of string; const APages: array of Integer;
      const ACards: array of string);
    procedure LayoutPage(APage: Integer);
    function PageHeight(APage: Integer; AAllClosed: Boolean): Integer;
    function CardIndex(const AId: string): Integer;
    procedure SetCardOpen(AIndex: Integer; AOpen, AAnimate: Boolean);
    procedure CardToggle(Sender: TObject);
    procedure CardStep(Sender: TObject; ADone: Boolean);
    procedure LinkClick(Sender: TObject);
    procedure GoToPage(APage: Integer; const ACard: string; AFocus: Boolean);
    function OpenCardIds: string;
    function SumMainWindow: string;
    function SumPaneText: string;
    function SumFilter: string;
    function SumRgScan: string;
    function SumThread: string;
    function SumLog: string;
    function SumArtistInfo: string;
    procedure Section(const ATitle: string);
    procedure RowGap;
    function TextBlock(const ACaption, ADesc: string; AW: Integer): Integer;
    procedure AddRow(ACtrl: TControl);
    function ComboRow(const ACaption, ADesc: string; const AOpts: array of TFormatDef): TAuCombo;
    function SwitchRow(const ACaption, ADesc: string): TAuSwitch;
    function SpinRow(const ACaption, ADesc: string; AMin, AMax: Integer): TAuEdit;
    procedure StackRow(const ACaption, ADesc: string; ACtrl: TControl; AW, AH: Integer);
    procedure SideRow(const ACaption, ADesc: string; ACtrl: TControl; AW, AH: Integer);
    procedure SetRowEnabled(ACtrl: TControl; AEnabled: Boolean);
    procedure BuildLibrary;
    procedure BuildPlaylists;
    procedure BuildOutput;
    procedure BuildDsd;
    procedure BuildResampler;
    procedure BuildVolume;
    procedure BuildAppearance;
    procedure BuildSystem;
    procedure BuildShortcuts;
    { values }
    procedure LoadValues;
    procedure StoreValues(var D: TAppSettingsData);
    procedure EnableControls;
    procedure FillDevices;
    function SelectedApi: Integer;
    { events }
    procedure NavCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure NavSel(Sender: TObject);
    procedure NavActivate(Sender: TObject; Row: Integer);
    procedure AnyChange(Sender: TObject);
    procedure ApiChange(Sender: TObject);
    procedure DeviceChange(Sender: TObject);
    procedure ThemePreview(Sender: TObject);
    procedure FolderCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure FolderSel(Sender: TObject);
    procedure FolderKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ShortcutCell(Sender: TObject; Row, Col: Integer; var AText: string);
    procedure AddFolderClick(Sender: TObject);
    procedure RemoveFolderClick(Sender: TObject);
    procedure ScanClick(Sender: TObject);
    procedure RepairClick(Sender: TObject);
    procedure UpdateLibraryButtons;
  public
    constructor CreatePrefs(AOwner: TComponent; AFolders: TStrings; APage: Integer);
    destructor Destroy; override;
  protected
    procedure DpiUpdated; override;
  public
    procedure ScanStatus(const AText: string);
    function CurrentPage: Integer;
  end;

const
  DLG_W = 900;
  DLG_H = 640;
  SIDE_W = 216;
  BOTTOM_H = 64;
  X0 = 32;                   // left edge of the rows on a page
  RW = 616;                  // row width (the page is DLG_W - SIDE_W wide)
  CTRL_W = 270;              // the control on the right of a row
  CARD_PAD = 14;             // a card reaches this far left and right of the rows
  CARD_H = 58;               // the head of a card
  CARD_GAP = 8;              // between two cards
  PAGE_W = DLG_W - SIDE_W;
  TEXT_SIZES: array[0..3] of Integer = (90, 100, 110, 120);

  { the keyboard shortcuts of the Shortcuts page }
  SHORTCUTS: array[0..32, 0..1] of string = (
    ('Space', 'Play / pause'),
    ('Ctrl+Left / Ctrl+Right', 'Back / forward 10 seconds'),
    ('Ctrl+Up / Ctrl+Down', 'Volume up / down'),
    ('Ctrl+M', 'Mute on / off'),
    ('Ctrl+S', 'Shuffle off / tracks / albums'),
    ('Ctrl+R', 'Repeat off / all / one'),
    ('Ctrl+J', 'Jump to Now Playing'),
    ('Ctrl+T', 'Tone Control'),
    ('Media keys', 'Play / pause, stop, next, previous'),
    ('Ctrl+O', 'Add files to the playlist'),
    ('Ctrl+F', 'Search the library'),
    ('Enter', 'Play the selection (library or playlist)'),
    ('Del', 'Remove the selected tracks from the playlist'),
    ('Ctrl+1 .. Ctrl+5', 'Rate the selected playlist tracks (a header: its whole album)'),
    ('Ctrl+0', 'Clear the rating of the selected playlist tracks'),
    ('Ctrl+A', 'Select all'),
    ('Ctrl+Tab', 'Switch between the library and the playlist'),
    ('F5', 'Refresh the library folder and the playlist'),
    ('Ctrl+F5', 'Rescan the library'),
    ('Alt+P', 'Playlist Manager'),
    ('Alt+Enter', 'Properties (tags) of the selection'),
    ('Ctrl+P', 'Preferences'),
    ('Ctrl+L', 'Log window'),
    ('Ctrl+D', 'Debug Queue'),
    ('F1', 'Help'),
    ('Ctrl+Q', 'Quit'),
    ('Ctrl+mouse wheel', 'Text size of the library or the playlist'),
    ('Shift+F10 / Menu key', 'Context menu of the selection'),
    ('Right click / three dots', 'Context menu (also on touch screens)'),
    ('Tab / Shift+Tab', 'Move between the controls'),
    ('Esc', 'Close a dialog or menu'),
    ('Arrow keys', 'Move in lists and the tree; open and close folders'),
    ('Page Up / Page Down / Home / End', 'Scroll lists and the tree'));

var
  GPrefs: TPrefsForm = nil;

procedure FillOptions(C: TAuCombo; const AOpts: array of TFormatDef);
var
  I: Integer;
begin
  C.Items.Clear;
  for I := Low(AOpts) to High(AOpts) do
    if AOpts[I].DataStr <> '' then C.Items.Add(AOpts[I].DisplayName);
end;

{ the row of the option with this value (0 when it is not among them) }
procedure SelectOption(C: TAuCombo; const AOpts: array of TFormatDef; const AValue: string);
var
  R: Integer;
begin
  R := ComboRowOfOption(AOpts, FormatOptionByData(AOpts, AValue));
  if (R < 0) or (R >= C.Items.Count) then R := 0;
  C.ItemIndex := R;
end;

function OptionValue(C: TAuCombo; const AOpts: array of TFormatDef; const ADefault: string): string;
var
  I: Integer;
begin
  I := OptionOfComboRow(AOpts, C.ItemIndex);
  if I >= 0 then Result := AOpts[I].DataStr else Result := ADefault;
end;

function OptionInt(C: TAuCombo; const AOpts: array of TFormatDef; ADefault: Integer): Integer;
begin
  Result := StrToIntDef(OptionValue(C, AOpts, IntToStr(ADefault)), ADefault);
end;

{ ---- the calls ---- }

function CreatePrefsForm(AOwner: TComponent; AFolders: TStrings; APage: Integer;
  const AOpenCard: string): TAuForm;
var
  F: TPrefsForm;
  I: Integer;
begin
  F := TPrefsForm.CreatePrefs(AOwner, AFolders, APage);
  { whatever the settings say: the pictures show what was asked for }
  for I := 0 to High(F.FCards) do F.SetCardOpen(I, F.FCards[I].Id = AOpenCard, False);
  if AOpenCard <> '' then F.GoToPage(APage, AOpenCard, False);
  Result := F;
end;

function PrefsPageFit(AForm: TAuForm): string;
var
  F: TPrefsForm;
  I, Avail: Integer;
  Note: string;
begin
  Result := '';
  if not (AForm is TPrefsForm) then Exit;
  F := TPrefsForm(AForm);
  { the room of the shown page (hidden ones are not laid out); pixels of
    the window's scaling, as ContentHeight }
  Avail := F.FPages[F.CurrentPage].ClientHeight;
  for I := 0 to High(F.FPages) do
  begin
    if F.FPages[I].ContentHeight > Avail then Note := '  SCROLLS' else Note := '';
    Result := Result + Format('%-18s needs %4d of %4d px (%d logical)%s', [F.FNavCaptions[I],
      F.FPages[I].ContentHeight, Avail, F.FNeed[I], Note]) + LineEnding;
  end;
end;

function ShowPreferences(AOwner: TComponent; AFolders: TStrings; ALibrary: TLibraryManager;
  AOnScan: TPrefsScanEvent; APage: Integer): Boolean;
var
  F: TPrefsForm;
begin
  Result := False;
  if GPrefs <> nil then Exit;
  if APage < 0 then APage := AppSettings.Data.PrefsPage;
  APage := EnsureRange(APage, 0, PREFS_SHORTCUTS);
  F := TPrefsForm.CreatePrefs(AOwner, AFolders, APage);
  GPrefs := F;
  try
    F.FLibrary := ALibrary;
    F.FOnScan := AOnScan;
    if (ALibrary <> nil) and ALibrary.IsScanning then F.ScanStatus(STATUS_SCANNING_FULL);
    Result := F.ShowModal = mrOK;
    AppSettings.Data.PrefsPage := F.CurrentPage;
    AppSettings.Data.PrefsCards := F.OpenCardIds;        // kept with OK and with Cancel, as the page
    if Result then
    begin
      F.StoreValues(AppSettings.Data);
      AFolders.Assign(F.FFolders);
    end
    else if (Ord(ThemeMode) <> F.FOrigTheme) or (AccentIndex <> F.FOrigAccent) then
      SetTheme(TAuThemeMode(F.FOrigTheme), F.FOrigAccent);
  finally
    GPrefs := nil;
    F.Free;
  end;
end;

procedure PrefsScanStatus(const AText: string);
begin
  if GPrefs <> nil then GPrefs.ScanStatus(AText);
end;

function PrefsOpen: Boolean;
begin
  Result := GPrefs <> nil;
end;

{ ---- TPrefsForm ---- }

constructor TPrefsForm.CreatePrefs(AOwner: TComponent; AFolders: TStrings; APage: Integer);
var
  Side, Bottom: TAuPanel;
  B: TAuButton;
  I: Integer;
begin
  CreateAu(AOwner, TITLE_PREFERENCES, DLG_W, DLG_H);
  { the pages scroll, the buttons are aligned at the bottom:
    on a small screen at a large scaling the window gets lower }
  FitToWorkArea;
  HelpKeyword := 'Preferences';
  FData := AppSettings.Data;
  FFolders := TStringList.Create;
  if AFolders <> nil then FFolders.Assign(AFolders);
  FDevIds := TStringList.Create;
  FOrigTheme := Ord(ThemeMode);
  FOrigAccent := AccentIndex;

  Bottom := TAuPanel.Create(Self);
  Bottom.Parent := Body;
  Bottom.Align := alBottom;
  Bottom.Height := S(BOTTOM_H);
  Bottom.BorderRole := crBorder;
  Bottom.BorderSides := 2;

  Side := TAuPanel.Create(Self);
  Side.Parent := Body;
  Side.Align := alLeft;
  Side.Width := S(SIDE_W);
  Side.BackRole := crPanel;
  Side.BorderRole := crBorder;
  Side.BorderSides := 4;

  FNav := TAuListView.Create(Self);
  FNav.Parent := Side;
  FNav.Align := alClient;
  FNav.BorderSpacing.Around := S(10);
  FNav.ShowHeader := False;
  FNav.MultiSelect := False;
  FNav.RowMenu := False;
  FNav.RowHeight := S(40);
  FNav.AddColumn('', 100, 0, True);
  FNav.AutoFit := True;
  FNav.BackRole := crPanel;
  FNav.OnDrawCell := @NavCell;
  FNav.OnSelChange := @NavSel;
  FNav.OnActivate := @NavActivate;

  { in the order of the PREFS_* constants }
  BuildLibrary;
  BuildAppearance;
  BuildPlaylists;
  BuildOutput;
  BuildDsd;
  BuildResampler;
  BuildVolume;
  BuildSystem;
  BuildShortcuts;
  Assert(Length(FPages) = PREFS_PAGE_COUNT);
  { the cards that were open last time }
  for I := 0 to High(FCards) do
    SetCardOpen(I, Pos(',' + FCards[I].Id + ',', ',' + AppSettings.Data.PrefsCards + ',') > 0, False);
  FNav.RowCount := Length(FPages);

  FStatus := AddLabel(Bottom, '', 24, 16, DLG_W - 24 - 2 * 110 - 40);
  FStatus.Height := S(32);
  B := AddButton(Bottom, 'Cancel', DLG_W - 24 - 2 * 110 - 10, 16, 110);
  B.ModalResult := mrCancel;
  B := AddButton(Bottom, 'OK', DLG_W - 24 - 110, 16, 110, bkPrimary);
  B.ModalResult := mrOK;
  DefaultButton := B;

  LoadValues;
  if (APage < 0) or (APage > High(FPages)) then APage := 0;
  FNav.SelectOnly(APage);
  for I := 0 to High(FPages) do FPages[I].Visible := I = APage;
  ActiveControl := FNav;
end;

destructor TPrefsForm.Destroy;
begin
  if GPrefs = Self then GPrefs := nil;
  FFolders.Free;
  FDevIds.Free;
  inherited Destroy;
end;

function TPrefsForm.CurrentPage: Integer;
begin
  Result := FNav.FocusedRow;
  if (Result < 0) or (Result > High(FPages)) then Result := 0;
end;

{ ---- building the pages ---- }

procedure TPrefsForm.NewPage(const ACaption: string; AIcon: TAuIcon);
var
  N: Integer;
  Box: TAuScrollBox;
  L: TAuLabel;
begin
  Box := TAuScrollBox.Create(Self);
  Box.Parent := Body;
  Box.Align := alClient;
  Box.Visible := False;
  N := Length(FPages);
  SetLength(FPages, N + 1);
  SetLength(FNavCaptions, N + 1);
  SetLength(FNavIcons, N + 1);
  FPages[N] := Box;
  FNavCaptions[N] := ACaption;
  FNavIcons[N] := AIcon;
  FPageContent := Box.Content;
  FX := X0;
  StartSegment(0);
  L := AddHeading(FCur, ACaption, X0, 20, RW);
  L.FontSize := 20;
  L.Height := S(34);
  FY := 62;
  FFirstRow := True;
  FFirstSection := True;
end;

procedure TPrefsForm.EndPage;
var
  P: Integer;
begin
  CloseSegment;
  P := High(FPages);
  LayoutPage(P);
  SetLength(FNeed, Length(FPages));
  FNeed[P] := PageHeight(P, True);
end;

{ ---- segments and cards ---- }

procedure TPrefsForm.AddBlock(AKind: TPrefsBlockKind; ACtrl: TControl; AH, ACard: Integer);
var
  N: Integer;
begin
  N := Length(FBlocks);
  SetLength(FBlocks, N + 1);
  FBlocks[N].Page := High(FPages);
  FBlocks[N].Kind := AKind;
  FBlocks[N].Ctrl := ACtrl;
  FBlocks[N].H := AH;
  FBlocks[N].Card := ACard;
end;

{ the rows that follow go into a new strip of the page (they move as one
  when a card above them opens) }
procedure TPrefsForm.StartSegment(AFirstY: Integer);
var
  P: TAuPanel;
begin
  P := TAuPanel.Create(Self);
  P.Parent := FPageContent;
  P.BorderSides := 0;
  FCur := P;
  FX := X0;
  FY := AFirstY;
  FFirstRow := True;
end;

procedure TPrefsForm.CloseSegment;
begin
  if FCur = nil then Exit;
  if FCur.ControlCount = 0 then FCur.Free
  else AddBlock(pbSegment, FCur, FY, -1);
  FCur := nil;
end;

{ the rows up to EndCard are the content of a card }
procedure TPrefsForm.BeginCard(const AId, ATitle: string; AIcon: TAuIcon; ASummary: TCardSummary);
var
  N: Integer;
begin
  CloseSegment;
  N := Length(FCards);
  SetLength(FCards, N + 1);
  FCards[N].Id := AId;
  FCards[N].Page := High(FPages);
  FCards[N].Head := TPrefsCardHead.Create(Self);
  FCards[N].Head.Parent := FPageContent;
  FCards[N].Head.FTitle := ATitle;
  FCards[N].Head.FIcon := AIcon;
  FCards[N].Head.FSummary := ASummary;
  FCards[N].Head.FOnToggle := @CardToggle;
  FCards[N].Body := TPrefsCardBody.Create(Self);
  FCards[N].Body.Parent := FPageContent;
  FCards[N].Body.BackRole := crCard;
  FCards[N].Body.Visible := False;
  AddBlock(pbHead, FCards[N].Head, CARD_H, N);
  FCur := FCards[N].Body;
  FX := CARD_PAD;
  FY := 16;
  FFirstRow := True;
  FFirstSection := True;
end;

procedure TPrefsForm.EndCard;
begin
  AddBlock(pbBody, FCur, FY + 16, High(FCards));
  { what follows the card on the page }
  StartSegment(12);
  FFirstSection := False;
end;

function TPrefsForm.CardIndex(const AId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FCards) do
    if FCards[I].Id = AId then Exit(I);
  Result := -1;
end;

{ the height of a page (unscaled); AAllClosed: as if every card were closed }
function TPrefsForm.PageHeight(APage: Integer; AAllClosed: Boolean): Integer;
var
  I: Integer;
  Prev: TPrefsBlockKind;
  First: Boolean;
begin
  Result := 0;
  Prev := pbSegment;
  First := True;
  for I := 0 to High(FBlocks) do
    if FBlocks[I].Page = APage then
    begin
      case FBlocks[I].Kind of
        pbSegment: Inc(Result, FBlocks[I].H);
        pbHead:
          begin
            if not First then
            begin
              if Prev = pbSegment then Inc(Result, 18) else Inc(Result, CARD_GAP);
            end;
            Inc(Result, CARD_H);
          end;
        pbBody:
          if not AAllClosed then
            Inc(Result, Round(FBlocks[I].H * FCards[FBlocks[I].Card].Head.FOpenA.Value));
      end;
      Prev := FBlocks[I].Kind;
      First := False;
    end;
  Inc(Result, 28);
end;

{ stacks the page's segments and cards from the top; a body shows as much of
  itself as its card is open }
procedure TPrefsForm.LayoutPage(APage: Integer);
var
  I, Y, H: Integer;
  Prev: TPrefsBlockKind;
  First: Boolean;
begin
  if (APage < 0) or (APage > High(FPages)) then Exit;
  Y := 0;
  Prev := pbSegment;
  First := True;
  for I := 0 to High(FBlocks) do
    if FBlocks[I].Page = APage then
    begin
      case FBlocks[I].Kind of
        pbSegment:
          begin
            FBlocks[I].Ctrl.SetBounds(0, S(Y), S(PAGE_W - 12), S(FBlocks[I].H));
            Inc(Y, FBlocks[I].H);
          end;
        pbHead:
          begin
            if not First then
            begin
              if Prev = pbSegment then Inc(Y, 18) else Inc(Y, CARD_GAP);
            end;
            FBlocks[I].Ctrl.SetBounds(S(X0 - CARD_PAD), S(Y), S(RW + 2 * CARD_PAD), S(CARD_H));
            Inc(Y, CARD_H);
          end;
        pbBody:
          begin
            H := Round(FBlocks[I].H * FCards[FBlocks[I].Card].Head.FOpenA.Value);
            FBlocks[I].Ctrl.Visible := H > 0;
            if H > 0 then
              FBlocks[I].Ctrl.SetBounds(S(X0 - CARD_PAD), S(Y), S(RW + 2 * CARD_PAD), S(H));
            Inc(Y, H);
          end;
      end;
      Prev := FBlocks[I].Kind;
      First := False;
    end;
  FPages[APage].ContentHeight := S(Y + 28);
end;

procedure TPrefsForm.SetCardOpen(AIndex: Integer; AOpen, AAnimate: Boolean);
var
  Head: TPrefsCardHead;
begin
  if (AIndex < 0) or (AIndex > High(FCards)) then Exit;
  Head := FCards[AIndex].Head;
  Head.FOpen := AOpen;
  Head.Invalidate;
  if AAnimate then AnimTo(Head.FOpenA, Ord(AOpen), ANIM_NORMAL, Head, @CardStep)
  else
  begin
    AnimSet(Head.FOpenA, Ord(AOpen));
    LayoutPage(FCards[AIndex].Page);
  end;
end;

procedure TPrefsForm.CardToggle(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to High(FCards) do
    if FCards[I].Head = Sender then SetCardOpen(I, not FCards[I].Head.FOpen, True);
end;

{ a card on its way open or closed: the page is stacked anew at every step;
  an opened card is brought into view }
procedure TPrefsForm.CardStep(Sender: TObject; ADone: Boolean);
var
  I: Integer;
begin
  for I := 0 to High(FCards) do
    if FCards[I].Head = Sender then
    begin
      LayoutPage(FCards[I].Page);
      FCards[I].Head.Invalidate;
      if ADone and FCards[I].Head.FOpen then
      begin
        FPages[FCards[I].Page].ScrollIntoView(FCards[I].Body);
        FPages[FCards[I].Page].ScrollIntoView(FCards[I].Head);
      end;
    end;
end;

function TPrefsForm.OpenCardIds: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FCards) do
    if FCards[I].Head.FOpen then
    begin
      if Result <> '' then Result := Result + ',';
      Result := Result + FCards[I].Id;
    end;
end;

{ "Related settings": buttons that lead to another page (and a card there) }
procedure TPrefsForm.LinkRow(const ATitles: array of string; const APages: array of Integer;
  const ACards: array of string);
var
  I, N, X, W: Integer;
  B: TAuButton;
begin
  Section('Related settings');
  X := FX;
  for I := 0 to High(ATitles) do
  begin
    W := Ceil(TextWidth(ATitles[I], UIFont(13)) / UIScale) + 58;
    B := AddButton(FCur, ATitles[I], X, FY, W, bkNormal, @LinkClick);
    B.Icon := icChevronRight;
    N := Length(FLinks);
    SetLength(FLinks, N + 1);
    FLinks[N].Btn := B;
    FLinks[N].Page := APages[I];
    FLinks[N].Card := ACards[I];
    Inc(X, W + 10);
  end;
  Inc(FY, 32);
end;

procedure TPrefsForm.LinkClick(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to High(FLinks) do
    if FLinks[I].Btn = Sender then
    begin
      GoToPage(FLinks[I].Page, FLinks[I].Card, True);
      Exit;
    end;
end;

{ shows a page; ACard <> '': that card open and in view }
procedure TPrefsForm.GoToPage(APage: Integer; const ACard: string; AFocus: Boolean);
var
  I, C: Integer;
begin
  if (APage < 0) or (APage > High(FPages)) then Exit;
  FNav.SelectOnly(APage);
  if not FPages[APage].Visible then
  begin
    for I := 0 to High(FPages) do FPages[I].Visible := I = APage;
    if AFocus then EntranceFade(FPages[APage], S(12));
  end;
  C := CardIndex(ACard);
  if C < 0 then Exit;
  SetCardOpen(C, True, False);
  FPages[APage].ScrollIntoView(FCards[C].Body);
  FPages[APage].ScrollIntoView(FCards[C].Head);
  if AFocus and FCards[C].Head.CanFocus then FCards[C].Head.SetFocus;
end;

procedure TPrefsForm.DpiUpdated;
var
  I: Integer;
begin
  inherited DpiUpdated;
  for I := 0 to High(FPages) do LayoutPage(I);
end;

{ ---- the cards' summaries ---- }

function ComboText(C: TAuCombo): string;
begin
  if (C <> nil) and (C.ItemIndex >= 0) and (C.ItemIndex < C.Items.Count) then Result := C.Items[C.ItemIndex]
  else Result := '';
end;

{ an option's name without what follows in brackets: 'High (24-bit Precision)' -> 'High' }
function ShortText(C: TAuCombo): string;
var
  P: Integer;
begin
  Result := ComboText(C);
  P := Pos(' (', Result);
  if P > 1 then Result := Copy(Result, 1, P - 1);
end;

function TPrefsForm.SumMainWindow: string;
var
  S1: string;
  procedure Add(AOn: Boolean; const AName: string);
  begin
    if not AOn then Exit;
    if S1 <> '' then S1 := S1 + ', ';
    S1 := S1 + AName;
  end;
begin
  S1 := '';
  Add(FShowArtist.Checked, 'Artists');
  Add(FShowAlbum.Checked, 'Albums');
  Add(FShowGenre.Checked, 'Genres');
  Add(FPeakMeter.Checked, 'peak meter');
  if S1 = '' then S1 := 'only the folders';
  Result := 'Shown: ' + S1 + '. Double click: ' + ComboText(FDblClick);
end;

function TPrefsForm.SumPaneText: string;
begin
  Result := Format('Library %s, playlist %s', [FLibFont.Text, FPlFont.Text]);
end;

function TPrefsForm.SumFilter: string;
begin
  if not FResample.Checked then Exit('Not used: PCM resampling is off');
  Result := Format('Quality %s; %s up, %s down; %s', [ShortText(FQuality),
    StringReplace(ShortText(FUpPhase), ' Phase', '', []), StringReplace(ShortText(FDownPhase), ' Phase', '', []),
    ShortText(FBandwidth)]);
end;

function TPrefsForm.SumRgScan: string;
begin
  Result := 'Tracks at the same time: ' + ComboText(FRgThreads);
end;

function TPrefsForm.SumThread: string;
var
  S1: string;
  procedure Add(AOn: Boolean; const AName: string);
  begin
    if not AOn then Exit;
    if S1 <> '' then S1 := S1 + ', ';
    S1 := S1 + AName;
  end;
begin
  S1 := '';
  Add(FAffinity.Checked, 'core affinity');
  Add(FMMCSS.Checked, 'MMCSS');
  Add(FHighRes.Checked, '1 ms timer');
  if S1 = '' then Result := 'All off' else Result := 'On: ' + S1;
end;

function TPrefsForm.SumLog: string;
begin
  if FAlwaysLog.Checked then Result := 'Saved every time Aulumic closes'
  else Result := 'Saved only after an error';
end;

function TPrefsForm.SumArtistInfo: string;
begin
  if Trim(FLastFmKey.Text) = '' then Result := 'No Last.fm API key'
  else Result := 'Last.fm API key entered';
end;

{ ---- TPrefsCardHead / TPrefsCardBody ---- }

constructor TPrefsCardHead.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Cursor := crHandPoint;
end;

procedure TPrefsCardHead.DoPaint(G: TGfx);
var
  Bg: TARGB;
  R, T: Single;
  Sum: string;
begin
  G.FillRect(0, 0, Width, Height, ParentBack);
  Bg := HoverMix(clCard, clHover);
  R := S(8);
  T := FOpenA.Value;
  G.FillRound(0, 0, Width, Height, R, Bg);
  G.StrokeRound(0, 0, Width, Height, R, 1, clBorder);
  if T > 0 then
  begin
    { open: square below, where the body joins }
    G.FillRect(0, Height - R, Width, R, Bg);
    G.FillRect(0, Height - R, 1, R, clBorder);
    G.FillRect(Width - 1, Height - R, 1, R, clBorder);
    G.FillRect(1, Height - 1, Width - 2, 1, Blend(Bg, clBorder, T));
  end;
  if FIcon <> icNone then DrawIcon(G, FIcon, S(26), Height / 2, S(17), clTextDim);
  Sum := '';
  if Assigned(FSummary) then Sum := FSummary();
  if Sum <> '' then
  begin
    G.Text(FTitle, S(50), S(9), Width - S(100), S(22), UIFont(13.5), clText, 0, 1);
    G.Text(Sum, S(50), S(30), Width - S(100), S(19), UIFont(12), clTextDim, 0, 1);
  end
  else
    G.Text(FTitle, S(50), 0, Width - S(100), Height, UIFont(13.5), clText, 0, 1);
  if FOpen then DrawIcon(G, icChevronUp, Width - S(26), Height / 2, S(15), clTextDim)
  else DrawIcon(G, icChevronDown, Width - S(26), Height / 2, S(15), clTextDim);
  DrawFocusRing(G, 0, 0, Width, Height, R);
end;

procedure TPrefsCardHead.Click;
begin
  inherited Click;
  if Assigned(FOnToggle) then FOnToggle(Self);
end;

procedure TPrefsCardHead.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = VK_SPACE then
  begin
    Key := 0;
    if Assigned(FOnToggle) then FOnToggle(Self);
  end;
end;

procedure TPrefsCardBody.DoPaint(G: TGfx);
var
  R: Single;
begin
  { the card's colour, round at the bottom; the corners show the page }
  R := S(8);
  G.FillRect(0, 0, Width, Height, ParentBack);
  G.FillRound(0, 0, Width, Height, R, clCard);
  G.StrokeRound(0, 0, Width, Height, R, 1, clBorder);
  if Height > 2 * R then
  begin
    G.FillRect(0, 0, Width, R, clCard);
    G.FillRect(0, 0, 1, R, clBorder);
    G.FillRect(Width - 1, 0, 1, R, clBorder);
  end;
end;
procedure TPrefsForm.Section(const ATitle: string);
var
  L: TAuLabel;
begin
  if FFirstSection then Inc(FY, 6) else Inc(FY, 30);
  FFirstSection := False;
  L := AddLabel(FCur, UpperCase(ATitle), FX, FY, RW, False);
  L.FontSize := 11;
  L.Bold := True;
  L.TextRole := crAccent;
  Inc(FY, 28);
  FFirstRow := True;
end;

{ a thin line between the rows of a section }
procedure TPrefsForm.RowGap;
var
  P: TAuPanel;
begin
  if FFirstRow then
  begin
    FFirstRow := False;
    Exit;
  end;
  P := TAuPanel.Create(Self);
  P.Parent := FCur;
  P.BackRole := crBorder;
  P.BorderSides := 0;
  P.SetBounds(S(FX), S(FY + 11), S(RW), Math.Max(1, S(1)));
  Inc(FY, 23);
end;

{ the name and the description of a setting at (FX, FY), AW wide; the height }
function TPrefsForm.TextBlock(const ACaption, ADesc: string; AW: Integer): Integer;
var
  DH: Integer;
begin
  FLastCap := AddLabel(FCur, ACaption, FX, FY, AW, False);
  FLastDesc := nil;
  DH := 0;
  if ADesc <> '' then
  begin
    DH := Ceil(TextHeightWrapped(ADesc, UIFont(12), S(AW)) / UIScale) + 2;
    FLastDesc := AddLabel(FCur, ADesc, FX, FY + 22, AW);
    FLastDesc.FontSize := 12;
    FLastDesc.WordWrap := True;
    FLastDesc.VAlign := 0;
    FLastDesc.Height := S(DH);
  end;
  Result := 22 + DH;
end;

procedure TPrefsForm.AddRow(ACtrl: TControl);
var
  N: Integer;
begin
  N := Length(FRows);
  SetLength(FRows, N + 1);
  FRows[N].Ctrl := ACtrl;
  FRows[N].Cap := FLastCap;
  FRows[N].Desc := FLastDesc;
end;

function TPrefsForm.ComboRow(const ACaption, ADesc: string; const AOpts: array of TFormatDef): TAuCombo;
var
  H: Integer;
begin
  RowGap;
  H := TextBlock(ACaption, ADesc, RW - CTRL_W - 24);
  Result := AddCombo(FCur, FX + RW - CTRL_W, FY + Math.Max(0, (Math.Min(H, 64) - 32) div 2), CTRL_W, []);
  FillOptions(Result, AOpts);
  Result.OnChange := @AnyChange;
  AddRow(Result);
  Inc(FY, Math.Max(H, 32));
end;

function TPrefsForm.SpinRow(const ACaption, ADesc: string; AMin, AMax: Integer): TAuEdit;
var
  H: Integer;
begin
  RowGap;
  H := TextBlock(ACaption, ADesc, RW - CTRL_W - 24);
  Result := AddSpin(FCur, FX + RW - 120, FY + Math.Max(0, (Math.Min(H, 64) - 32) div 2), 120, AMin, AMax, AMin);
  AddRow(Result);
  Inc(FY, Math.Max(H, 32));
end;

{ the switch draws its name and description itself (the toggle on the right) }
function TPrefsForm.SwitchRow(const ACaption, ADesc: string): TAuSwitch;
var
  H: Integer;
begin
  RowGap;
  Result := AddSwitch(FCur, ACaption, ADesc, FX, FY - 3, RW, False);
  if ADesc <> '' then
  begin
    H := 28 + Ceil(TextHeightWrapped(ADesc, UIFont(12), S(RW - 54)) / UIScale) + 4;
    Result.Height := S(H);
  end
  else
    H := 28;
  Result.OnChange := @AnyChange;
  FLastCap := nil;
  FLastDesc := nil;
  AddRow(Result);
  Inc(FY, H - 3);
end;

{ name and description, the control below them }
procedure TPrefsForm.StackRow(const ACaption, ADesc: string; ACtrl: TControl; AW, AH: Integer);
var
  H: Integer;
begin
  RowGap;
  H := TextBlock(ACaption, ADesc, RW);
  Inc(FY, H + 10);
  ACtrl.Parent := FCur;
  ACtrl.SetBounds(S(FX), S(FY), S(AW), S(AH));
  AddRow(ACtrl);
  Inc(FY, AH);
end;

{ name and description on the left, the control on the right (as a combo) }
procedure TPrefsForm.SideRow(const ACaption, ADesc: string; ACtrl: TControl; AW, AH: Integer);
var
  H: Integer;
begin
  RowGap;
  H := TextBlock(ACaption, ADesc, RW - AW - 24);
  ACtrl.Parent := FCur;
  ACtrl.SetBounds(S(FX + RW - AW), S(FY + Math.Max(0, (Math.Min(H, 64) - AH) div 2)), S(AW), S(AH));
  AddRow(ACtrl);
  Inc(FY, Math.Max(H, AH));
end;

procedure TPrefsForm.SetRowEnabled(ACtrl: TControl; AEnabled: Boolean);
var
  I: Integer;
begin
  ACtrl.Enabled := AEnabled;
  for I := 0 to High(FRows) do
    if FRows[I].Ctrl = ACtrl then
    begin
      if FRows[I].Cap <> nil then
      begin
        if AEnabled then FRows[I].Cap.TextRole := crText else FRows[I].Cap.TextRole := crTextFaint;
      end;
      if FRows[I].Desc <> nil then
      begin
        if AEnabled then FRows[I].Desc.TextRole := crTextDim else FRows[I].Desc.TextRole := crTextFaint;
      end;
    end;
  ACtrl.Invalidate;
end;

procedure TPrefsForm.BuildLibrary;
var
  H: Integer;
begin
  NewPage('Library', icLibrary);
  Section('Library folders');
  H := TextBlock('Folders',
    'The folders that hold your music. Aulumic shows everything in them, sub folders included.', RW);
  Inc(FY, H + 10);
  FFolderList := TAuListView.Create(Self);
  FFolderList.Parent := FCur;
  FFolderList.SetBounds(S(X0), S(FY), S(RW), S(176));
  FFolderList.ShowHeader := False;
  FFolderList.MultiSelect := True;
  FFolderList.AutoFit := True;
  FFolderList.RowMenu := False;
  FFolderList.AddColumn('Folder', 300, 0, True);
  FFolderList.EmptyText := 'No library folder yet.' + LineEnding + 'Add the folders with your music.';
  FFolderList.BackRole := crCard;
  FFolderList.OnDrawCell := @FolderCell;
  FFolderList.OnSelChange := @FolderSel;
  FFolderList.OnKeyDown := @FolderKey;
  Inc(FY, 176 + 12);
  FBtnAdd := AddButton(FCur, 'Add folder...', X0, FY, 140, bkNormal, @AddFolderClick);
  FBtnAdd.Icon := icFolderPlus;
  FBtnAdd.Hint := 'Adds a folder to your library (Insert).';
  FBtnAdd.ShowHint := True;
  FBtnRemove := AddButton(FCur, 'Remove', X0 + 150, FY, 120, bkNormal, @RemoveFolderClick);
  FBtnRemove.Icon := icTrash;
  FBtnRemove.Hint := 'Removes the selected folder from the library (Del). Your files stay on disk.';
  FBtnRemove.ShowHint := True;
  FBtnRepair := AddButton(FCur, 'Repair...', X0 + RW - 120, FY, 120, bkNormal, @RepairClick);
  FBtnRepair.Icon := icRefresh;
  FBtnRepair.Hint := 'Rebuilds your library from scratch, thumbnails included. ' +
    'Try this when tracks are missing or the library looks wrong.';
  FBtnRepair.ShowHint := True;
  FBtnScan := AddButton(FCur, 'Scan now', X0 + RW - 120 - 10 - 130, FY, 130, bkNormal, @ScanClick);
  FBtnScan.Icon := icScan;
  FBtnScan.Hint := 'Checks your library folders for new, changed or removed files.';
  FBtnScan.ShowHint := True;
  Inc(FY, 32 + 8);
  FFirstRow := False;
  FWatch := SwitchRow('Watch the library folders',
    'New and changed files show up by themselves a few seconds later. Network folders aren''t ' +
    'watched (some NAS would never sleep): press Refresh (F5) or Rescan (Ctrl+F5) for those.');
  FRescan := SwitchRow('Auto-scan on startup',
    'Check your library for changes every time Aulumic starts.');
  EndPage;
end;

procedure TPrefsForm.BuildPlaylists;
begin
  NewPage('Playlists', icPlaylist);
  FGrouping := ComboRow('Playlists grouping',
    'Default grouping of playlists: By album, By folder or Flat list. Each playlist can override it.',
    GROUPING_MODE_OPTIONS);
  FHeaderFmt := ComboRow('Album header format',
    'Default layout of the album headers in playlists (only when grouped By album). Each playlist ' +
    'can override it.', HEADER_FORMAT_OPTIONS);
  FTrackFmt := ComboRow('Playlists track format',
    'Default layout of the tracks in playlists. Each playlist can override it.', TRACK_FORMAT_OPTIONS);
  FCursorFollows := SwitchRow('Cursor follows playback',
    'When a track starts, the selection moves to it and it scrolls into view. Only in the playlist ' +
    'that is playing; other playlists stay where you left them.');
  FStickyHeaders := SwitchRow('Keep album headers in view',
    'While you scroll through an album, its header stays at the top of the playlist.');
  EndPage;
end;

procedure TPrefsForm.BuildOutput;
begin
  NewPage('Output', icSpeaker);
  FApi := TAuSegmented.Create(Self);
  FApi.SetItems(['WASAPI exclusive', 'ASIO']);
  FApi.SetIcons([icHeadphones, icBolt]);
  FApi.OnChange := @ApiChange;
  StackRow('Output interface',
    'WASAPI exclusive mode or the ASIO driver of your DAC. Both keep the Windows mixer out of the ' +
    'signal path; while Aulumic plays, no other program can use the device.', FApi, 360, 36);
  FDevice := TAuCombo.Create(Self);
  FDevice.OnChange := @DeviceChange;
  StackRow('Output device', 'The audio device (DAC or sound card) Aulumic plays to.', FDevice, 440, 32);
  FPcmBuffer := ComboRow('PCM buffer size',
    'How much PCM audio is buffered ahead (WASAPI and ASIO), also DSD converted to PCM. ' +
    'Hearing stutters or dropouts? Make it larger. Default: 250 ms.', BUFFER_SIZE_OPTIONS);
  LinkRow(['DSD', 'Audio thread'], [PREFS_DSD, PREFS_SYSTEM], ['', CARD_THREAD]);
  EndPage;
end;

procedure TPrefsForm.BuildDsd;
begin
  NewPage('DSD', icDisc);
  FDoP := SwitchRow('Play DSD natively',
    'Send DSD to your DAC as DSD, without converting it to PCM: as DoP over WASAPI, as native DSD ' +
    'over ASIO when the driver can (else DoP). Your DAC must support DSD.');
  FDsdLowPass := SwitchRow('DSD low-pass',
    'Apply a 30 kHz low-pass filter when DSD is converted to PCM. Turning it off can cause ' +
    'distortion when ReplayGain is used.');
  FDsdGain := ComboRow('DSD gain',
    'Level of DSD converted to PCM, applied with the volume. +6 dB matches FLAC and WAV files ' +
    'more closely (loud SACDs then need Preamp -3 dB against clipping); +0 dB keeps the original.',
    DSD_GAIN_OPTIONS);
  FDsdBuffer := ComboRow('DSD buffer size',
    'How much DSD audio is buffered ahead when it goes to the DAC as DSD (DoP, or native over ' +
    'ASIO). A dropout there is a pop, so it needs more than PCM. Default: 500 ms.', BUFFER_SIZE_OPTIONS);
  LinkRow(['Output', 'Resampler'], [PREFS_OUTPUT, PREFS_RESAMPLER], ['', '']);
  EndPage;
end;

procedure TPrefsForm.BuildResampler;
begin
  NewPage('Resampler', icWave);
  FResample := SwitchRow('Enable PCM resampling',
    'Resamples PCM audio with the built-in resampler. Turn it off for bit-perfect playback.');
  FTarget44 := ComboRow('Target rate for 44.1 kHz',
    'Output rate for files of the 44.1 kHz family. Only whole multiples are offered, e.g. 88.2 or ' +
    '176.4 kHz.', TARGET_RATE_44_OPTIONS);
  FTarget48 := ComboRow('Target rate for 48 kHz',
    'Output rate for files of the 48 kHz family. Only whole multiples are offered, e.g. 96 or ' +
    '192 kHz.', TARGET_RATE_48_OPTIONS);
  FBypass := ComboRow('Exclude',
    'Sample rates that are never resampled; they play at their own rate.', BYPASS_THRESH_OPTIONS);
  FNoDsdResample := SwitchRow('Exclude DSD from resampling',
    'Do not resample DSD. When DSD is converted to PCM (Play DSD natively is off), it is not ' +
    'resampled afterwards.');
  { set once: the quality and the filter's shape }
  BeginCard(CARD_FILTER, 'Quality and filter', icFilter, @SumFilter);
  FQuality := ComboRow('Resample quality',
    'Higher settings resample more precisely but use more CPU.', RESAMPLE_QUAL_OPTIONS);
  FUpPhase := ComboRow('Upsampling phase',
    'Filter phase for upsampling: Linear, Intermediate (default) or Minimum. See Help > Audio Concepts.',
    PHASE_OPTIONS);
  FDownPhase := ComboRow('Downsampling phase',
    'Filter phase for downsampling: Linear, Intermediate or Minimum (default). See Help > Audio Concepts.',
    PHASE_OPTIONS);
  FBandwidth := ComboRow('Bandwidth',
    'Where the high-frequency filter starts: 91.3% (slow roll-off, the default), 95% or 99% (fast) ' +
    'of the Nyquist limit. Slow sounds smoother; fast keeps the most treble.', BANDWIDTH_OPTIONS);
  FAntiAlias := ComboRow('Anti-aliasing',
    'Strength of the ultrasonic filter. Maximum blocks all noise but adds some pre-ringing; Standard ' +
    'lets a little inaudible noise through and keeps transients sharper.', ANTI_ALIAS_OPTIONS);
  EndCard;
  EndPage;
end;

procedure TPrefsForm.BuildVolume;
var
  L: TAuLabel;
begin
  NewPage('Volume', icVolume2);
  FLockVolume := SwitchRow('Lock volume to 100%',
    'Keep the volume at 100% and let your DAC or amplifier control it. This also turns off ' +
    'ReplayGain, a fixed headroom and soft clipping. Needed for bit-perfect playback.');
  FReplayGain := ComboRow('ReplayGain mode',
    'Track: every song plays at the same loudness. Album: whole albums play at the same loudness, ' +
    'keeping the differences between their tracks.', REPLAYGAIN_OPTIONS);
  { one setting for the automatic headroom and
    the fixed preamp (HEADROOM_OPTIONS). Not disabled by the locked volume:
    Automatic works there too (it only acts where the sound is converted
    anyway); a fixed value is not applied then. }
  FPreamp := ComboRow('Headroom',
    'Automatic: lowers an album just as far as its peaks after upsampling or DSD to PCM need; ' +
    'a tone control boost is counted in. Bit-perfect playback is never touched. Or a fixed amount.',
    HEADROOM_OPTIONS);
  FSoftClip := SwitchRow('Enable soft clipping limiter',
    'Gently rounds off peaks that would otherwise clip. You don''t need it with Headroom on ' +
    'Automatic; it helps with a fixed headroom.');
  Inc(FY, 20);
  L := AddLabel(FCur, 'Any change of the level (volume below 100%, ReplayGain, headroom, tone control) ' +
    'means the output is no longer bit-perfect; the badge in the banner shows it.', X0, FY, RW);
  L.WordWrap := True;
  L.VAlign := 0;
  L.FontSize := 12;
  L.TextRole := crTextFaint;
  L.Height := S(40);
  Inc(FY, 40);
  BeginCard(CARD_RGSCAN, 'ReplayGain scan', icScan, @SumRgScan);
  FRgThreads := ComboRow('Tracks at the same time',
    'How many tracks of an album the ReplayGain scan measures at once. More is faster, but ' +
    'the processor gets warmer and its fan louder. The results are the same.', RG_THREADS_OPTIONS);
  EndCard;
  EndPage;
end;

procedure TPrefsForm.BuildAppearance;
begin
  NewPage('Appearance', icSun);
  Section('Theme');
  FTheme := TAuSegmented.Create(Self);
  FTheme.SetItems(['Dark', 'Light', 'Follow Windows']);
  FTheme.SetIcons([icMoon, icSun, icSettings]);
  FTheme.OnChange := @ThemePreview;
  StackRow('Theme', 'Dark, light, or the Windows app setting. Changes at once.', FTheme, 420, 36);
  FAccent := TAuSwatches.Create(Self);
  FAccent.OnChange := @ThemePreview;
  SideRow('Accent colour', 'Used for the selection, the sliders and the highlights.', FAccent,
    AccentCount * 40, 40);
  FTextSize := TAuSegmented.Create(Self);
  FTextSize.SetItems(['Small', 'Normal', 'Large', 'Larger']);
  SideRow('Text size', 'The size of the text in all windows (the panes have their own sizes below).',
    FTextSize, CTRL_W + 30, 36);
  FCompactRows := SwitchRow('Compact rows',
    'Lower rows in the playlist and the library tree, so more of them fit on the screen.');
  BeginCard(CARD_MAINWINDOW, 'Main window', icHome, @SumMainWindow);
  Section('Library tree');
  FDblClick := ComboRow('Double click',
    'What double-clicking a library folder does: play it right away in the default playlist, ' +
    'or only open or close it.', DBLCLICK_OPTIONS);
  FAccordion := SwitchRow('Auto-collapse other nodes (accordion)',
    'Closes the other open folders when you open one, which keeps the tree tidy.');
  Section('Show');
  FShowArtist := SwitchRow('Show Artists in library', 'Show the Artists group in the library pane.');
  FShowAlbum := SwitchRow('Show Albums in library', 'Show the Albums group in the library pane.');
  FShowGenre := SwitchRow('Show Genres in library', 'Show the Genres group in the library pane.');
  FPeakMeter := SwitchRow('Show peak meter', 'Show the peak meter in the top banner.');
  EndCard;
  BeginCard(CARD_PANETEXT, 'Text size of the panes', icLibrary, @SumPaneText);
  FLibFont := SpinRow('Library text size',
    'Tip: hold Ctrl and scroll the mouse wheel over the library to change it quickly.',
    FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  FPlFont := SpinRow('Playlist text size',
    'Tip: hold Ctrl and scroll the mouse wheel over the playlist to change it quickly.',
    FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  EndCard;
  EndPage;
end;

procedure TPrefsForm.BuildSystem;
begin
  NewPage('System', icCpu);
  Section('Drives');
  FKeepAwake := SwitchRow('Keep music drives awake during playback',
    'Stops the drives you play from falling asleep mid-album. Handy for external drives ' +
    'and NAS.');
  Section('Drawing');
  FAnimations := SwitchRow('Animations',
    'Short fades and gliding movements. They are only shown while "Animation effects" is switched ' +
    'on in the Windows settings.');
  FGpuPaint := SwitchRow('Use the graphics card',
    'The graphics card draws the lists and other large areas, which keeps scrolling smooth. See ' +
    'black or flickering areas? Switch it off, and Aulumic draws everything itself.');
  { set once per PC }
  BeginCard(CARD_THREAD, 'Audio thread', icCpu, @SumThread);
  FAffinity := SwitchRow('Optimize CPU core affinity',
    'Keeps the audio thread off CPU core 0, where Windows is busiest. Turn it off if you use a ' +
    'tool like Process Lasso to manage your cores.');
  FMMCSS := SwitchRow('Enable MMCSS (''Pro Audio'' mode)',
    'Registers the audio thread with Windows as a "Pro Audio" task, so it gets priority and isn''t ' +
    'throttled. Turn it off if an older DAC driver crashes or stutters.');
  FHighRes := SwitchRow('Enable high-resolution kernel timer (1 ms)',
    'Sets the Windows timer to 1 ms while playing, for lower latency, and stops Windows from ' +
    'slowing Aulumic down to save power. Turn it off to save battery on a laptop.');
  EndCard;
  BeginCard(CARD_LOG, 'Log', icLog, @SumLog);
  FAlwaysLog := SwitchRow('Always save the log',
    'Writes AulumicNSLog.txt into the Data folder every time Aulumic closes. Otherwise it''s ' +
    'only written after an error. Handy when you report a problem.');
  EndCard;
  BeginCard(CARD_ARTISTINFO, 'Artist information', icArtist, @SumArtistInfo);
  FLastFmKey := AddEdit(FCur, 0, 0, 300);
  FLastFmKey.OnChange := @AnyChange;
  SideRow('Last.fm API key',
    'Artist Info gets its biographies from Last.fm, which asks every program for a key. A key is ' +
    'free: create an API account at last.fm/api and paste the "API key" here.', FLastFmKey, 300, 32);
  EndCard;
  EndPage;
end;

procedure TPrefsForm.BuildShortcuts;
begin
  NewPage('Shortcuts', icKey);
  FShortcuts := TAuListView.Create(Self);
  FShortcuts.Parent := FCur;
  FShortcuts.SetBounds(S(X0), S(FY + 4), S(RW), S(DLG_H - BOTTOM_H - FY - 28));
  FShortcuts.AddColumn('Keys', 230);
  FShortcuts.AddColumn('Action', 300, 0, True);
  FShortcuts.AutoFit := True;
  FShortcuts.RowMenu := False;
  FShortcuts.MultiSelect := False;
  FShortcuts.BackRole := crCard;
  FShortcuts.OnGetCell := @ShortcutCell;
  FShortcuts.RowCount := Length(SHORTCUTS);
  Inc(FY, DLG_H - BOTTOM_H - FY - 24);
  EndPage;
end;

{ ---- values ---- }

procedure TPrefsForm.LoadValues;
var
  D: TAppSettingsData;
  I: Integer;
begin
  D := FData;
  { library }
  FFolderList.RowCount := FFolders.Count;
  FWatch.Checked := D.WatchFolders;
  FRescan.Checked := D.AutoRescanLibrary;
  SelectOption(FDblClick, DBLCLICK_OPTIONS, IntToStr(D.DoubleClickAction));
  FAccordion.Checked := D.AccordionEnabled;
  FCursorFollows.Checked := D.CursorFollowsPlayback;
  FStickyHeaders.Checked := D.StickyHeaders;
  FCompactRows.Checked := D.CompactRows;
  { output }
  FWasapiId := D.WasapiDeviceID;
  FAsioId := D.AsioDriverID;
  FApi.ItemIndex := EnsureRange(D.OutputApi, 0, 1);
  FillDevices;
  FDoP.Checked := D.Audio.UseDoP;
  FDsdLowPass.Checked := D.Audio.DsdLowPassFilter;
  SelectOption(FDsdGain, DSD_GAIN_OPTIONS, IntToStr(D.Audio.DsdToPcmGain));
  SelectOption(FPcmBuffer, BUFFER_SIZE_OPTIONS, IntToStr(D.Audio.PCMBufferMs));
  SelectOption(FDsdBuffer, BUFFER_SIZE_OPTIONS, IntToStr(D.Audio.DSDBufferMs));
  { resampler }
  FResample.Checked := D.Audio.ResamplePCM;
  SelectOption(FTarget44, TARGET_RATE_44_OPTIONS, IntToStr(D.Audio.TargetSampleRate44));
  SelectOption(FTarget48, TARGET_RATE_48_OPTIONS, IntToStr(D.Audio.TargetSampleRate48));
  SelectOption(FBypass, BYPASS_THRESH_OPTIONS, IntToStr(D.Audio.BypassThreshold));
  FNoDsdResample.Checked := D.Audio.DisableResampleForDSD;
  SelectOption(FQuality, RESAMPLE_QUAL_OPTIONS, IntToStr(D.Audio.ResampleQuality));
  SelectOption(FUpPhase, PHASE_OPTIONS, IntToStr(D.Audio.UpsamplePhase));
  SelectOption(FDownPhase, PHASE_OPTIONS, IntToStr(D.Audio.DownsamplePhase));
  FBandwidth.ItemIndex := EnsureRange(D.Audio.ResampleBandWidthIndex, 0, FBandwidth.Items.Count - 1);
  FAntiAlias.ItemIndex := EnsureRange(D.Audio.ResampleAntiAliasIndex, 0, FAntiAlias.Items.Count - 1);
  { volume }
  FLockVolume.Checked := D.Audio.VolumeLocked;
  SelectOption(FReplayGain, REPLAYGAIN_OPTIONS, IntToStr(D.Audio.ReplayGainMode));
  if D.Audio.AutoHeadroom then
    SelectOption(FPreamp, HEADROOM_OPTIONS, HEADROOM_AUTO)
  else
    SelectOption(FPreamp, HEADROOM_OPTIONS, IntToStr(Round(D.Audio.PreampDB)));
  FSoftClip.Checked := D.Audio.EnableSoftClipping;
  { appearance }
  FTheme.ItemIndex := Ord(ThemeMode);
  FAccent.ItemIndex := AccentIndex;
  FAnimations.Checked := D.Animations;
  FGpuPaint.Checked := D.GpuPaint;
  FTextSize.ItemIndex := 1;
  for I := 0 to High(TEXT_SIZES) do
    if D.UIFontSize >= TEXT_SIZES[I] - 4 then FTextSize.ItemIndex := I;
  FLibFont.Value := EnsureRange(D.LibraryFontSize, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  FPlFont.Value := EnsureRange(D.PlaylistFontSize, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  SelectOption(FGrouping, GROUPING_MODE_OPTIONS, IntToStr(D.DefaultGroupingMode));
  SelectOption(FHeaderFmt, HEADER_FORMAT_OPTIONS, D.DefaultHeaderFormat);
  SelectOption(FTrackFmt, TRACK_FORMAT_OPTIONS, D.DefaultTrackFormat);
  FShowArtist.Checked := D.ShowLibArtist;
  FShowAlbum.Checked := D.ShowLibAlbum;
  FShowGenre.Checked := D.ShowLibGenre;
  FPeakMeter.Checked := D.ShowPeakmeter;
  { system }
  FAffinity.Checked := D.Audio.OptimizeAffinity;
  FMMCSS.Checked := D.Audio.EnableMMCSS;
  FHighRes.Checked := D.Audio.UseHighResTimer;
  FKeepAwake.Checked := D.Audio.KeepDrivesAwake;
  SelectOption(FRgThreads, RG_THREADS_OPTIONS, IntToStr(D.RGScanThreads));
  FAlwaysLog.Checked := D.AlwaysSaveLog;
  FLastFmKey.Text := D.LastFmApiKey;
  EnableControls;
  UpdateLibraryButtons;
end;

{ only the settings of the dialog are written into D }
procedure TPrefsForm.StoreValues(var D: TAppSettingsData);
begin
  { library }
  D.WatchFolders := FWatch.Checked;
  D.AutoRescanLibrary := FRescan.Checked;
  D.DoubleClickAction := OptionInt(FDblClick, DBLCLICK_OPTIONS, 0);
  D.AccordionEnabled := FAccordion.Checked;
  D.CursorFollowsPlayback := FCursorFollows.Checked;
  D.StickyHeaders := FStickyHeaders.Checked;
  D.CompactRows := FCompactRows.Checked;
  { output }
  D.OutputApi := SelectedApi;
  D.WasapiDeviceID := FWasapiId;
  D.AsioDriverID := FAsioId;
  D.Audio.UseDoP := FDoP.Checked;
  D.Audio.DsdLowPassFilter := FDsdLowPass.Checked;
  D.Audio.DsdToPcmGain := OptionInt(FDsdGain, DSD_GAIN_OPTIONS, 6);
  D.Audio.PCMBufferMs := OptionInt(FPcmBuffer, BUFFER_SIZE_OPTIONS, 250);
  D.Audio.DSDBufferMs := OptionInt(FDsdBuffer, BUFFER_SIZE_OPTIONS, 500);
  { resampler }
  D.Audio.ResamplePCM := FResample.Checked;
  D.Audio.TargetSampleRate44 := OptionInt(FTarget44, TARGET_RATE_44_OPTIONS, 176400);
  D.Audio.TargetSampleRate48 := OptionInt(FTarget48, TARGET_RATE_48_OPTIONS, 192000);
  D.Audio.BypassThreshold := OptionInt(FBypass, BYPASS_THRESH_OPTIONS, 0);
  D.Audio.DisableResampleForDSD := FNoDsdResample.Checked;
  D.Audio.ResampleQuality := OptionInt(FQuality, RESAMPLE_QUAL_OPTIONS, 2);
  D.Audio.UpsamplePhase := OptionInt(FUpPhase, PHASE_OPTIONS, 1);
  D.Audio.DownsamplePhase := OptionInt(FDownPhase, PHASE_OPTIONS, 2);
  if FBandwidth.ItemIndex >= 0 then D.Audio.ResampleBandWidthIndex := FBandwidth.ItemIndex;
  if FAntiAlias.ItemIndex >= 0 then D.Audio.ResampleAntiAliasIndex := FAntiAlias.ItemIndex;
  { volume }
  D.Audio.VolumeLocked := FLockVolume.Checked;
  D.Audio.ReplayGainMode := OptionInt(FReplayGain, REPLAYGAIN_OPTIONS, 0);
  { Automatic: no fixed preamp }
  D.Audio.AutoHeadroom := OptionValue(FPreamp, HEADROOM_OPTIONS, HEADROOM_AUTO) = HEADROOM_AUTO;
  if D.Audio.AutoHeadroom then
    D.Audio.PreampDB := 0
  else
    D.Audio.PreampDB := OptionInt(FPreamp, HEADROOM_OPTIONS, 0);
  D.Audio.EnableSoftClipping := FSoftClip.Checked;
  { appearance }
  D.ThemeMode := EnsureRange(FTheme.ItemIndex, 0, 2);
  D.Accent := EnsureRange(FAccent.ItemIndex, 0, AccentCount - 1);
  D.Animations := FAnimations.Checked;
  D.GpuPaint := FGpuPaint.Checked;
  D.DarkMode := ThemeIsDark;
  D.UIFontSize := TEXT_SIZES[EnsureRange(FTextSize.ItemIndex, 0, High(TEXT_SIZES))];
  D.LibraryFontSize := EnsureRange(FLibFont.Value, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  D.PlaylistFontSize := EnsureRange(FPlFont.Value, FONT_MAIN_MINSIZE, FONT_MAIN_MAXSIZE);
  D.DefaultGroupingMode := OptionInt(FGrouping, GROUPING_MODE_OPTIONS, 0);
  D.DefaultHeaderFormat := OptionValue(FHeaderFmt, HEADER_FORMAT_OPTIONS, HEADER_FORMAT_OPTIONS[0].DataStr);
  D.DefaultTrackFormat := OptionValue(FTrackFmt, TRACK_FORMAT_OPTIONS, TRACK_FORMAT_OPTIONS[0].DataStr);
  D.ShowLibArtist := FShowArtist.Checked;
  D.ShowLibAlbum := FShowAlbum.Checked;
  D.ShowLibGenre := FShowGenre.Checked;
  D.ShowPeakmeter := FPeakMeter.Checked;
  { system }
  D.Audio.OptimizeAffinity := FAffinity.Checked;
  D.Audio.EnableMMCSS := FMMCSS.Checked;
  D.Audio.UseHighResTimer := FHighRes.Checked;
  D.Audio.KeepDrivesAwake := FKeepAwake.Checked;
  D.RGScanThreads := OptionInt(FRgThreads, RG_THREADS_OPTIONS, 1);
  D.AlwaysSaveLog := FAlwaysLog.Checked;
  D.LastFmApiKey := Trim(FLastFmKey.Text);
end;

{ the settings that depend on another one }
procedure TPrefsForm.EnableControls;
var
  R, V: Boolean;
begin
  R := FResample.Checked;
  SetRowEnabled(FTarget44, R);
  SetRowEnabled(FTarget48, R);
  SetRowEnabled(FBypass, R);
  SetRowEnabled(FNoDsdResample, R);
  SetRowEnabled(FQuality, R);
  SetRowEnabled(FUpPhase, R);
  SetRowEnabled(FDownPhase, R);
  SetRowEnabled(FBandwidth, R);
  SetRowEnabled(FAntiAlias, R);
  V := not FLockVolume.Checked;
  SetRowEnabled(FReplayGain, V);
  SetRowEnabled(FSoftClip, V);
  SetRowEnabled(FDsdGain, not FDoP.Checked);
  SetRowEnabled(FDsdLowPass, not FDoP.Checked);
end;

function TPrefsForm.SelectedApi: Integer;
begin
  Result := EnsureRange(FApi.ItemIndex, 0, 1);
end;

{ the devices of the chosen interface; the configured device stays listed
  under its name when it is switched off or unplugged }
procedure TPrefsForm.FillDevices;
var
  L: TStringList;
  I, P, DefIdx, Sel: Integer;
  Id, DevName: string;
begin
  FDevice.Items.Clear;
  FDevIds.Clear;
  L := TStringList.Create;
  try
    DefIdx := -1;
    if PrefsDemoDevices then
    begin
      if SelectedApi = 1 then L.Add('USB Audio ASIO Driver|demo') else L.Add('Speakers (USB Audio DAC)|demo');
      Id := 'demo';
    end
    else if SelectedApi = 1 then
    begin
      TAudioEngine.EnumerateAsioDevices(L);
      Id := FAsioId;
    end
    else
    begin
      TPlaybackManager.EnumerateDevices(L, DefIdx);
      Id := FWasapiId;
    end;
    Sel := -1;
    for I := 0 to L.Count - 1 do
    begin
      P := Pos('|', L[I]);
      if P = 0 then Continue;
      DevName := Copy(L[I], 1, P - 1);
      if SelectedApi = 0 then DevName := CleanDeviceName(DevName);
      FDevice.Items.Add(DevName);
      FDevIds.Add(Trim(Copy(L[I], P + 1, MaxInt)));
      if SameText(FDevIds[FDevIds.Count - 1], Id) then Sel := FDevIds.Count - 1;
    end;
    if (Sel < 0) and (Id <> '') then
    begin
      DevName := DeviceNameForID(SelectedApi, Id);
      FDevice.Items.Add(DevName);
      FDevIds.Add(Id);
      Sel := FDevIds.Count - 1;
    end;
    if Sel < 0 then
    begin
      if (DefIdx >= 0) and (DefIdx < FDevIds.Count) then Sel := DefIdx
      else if FDevIds.Count > 0 then Sel := 0;
    end;
    if FDevice.Items.Count = 0 then
    begin
      if SelectedApi = 1 then FDevice.Items.Add('No ASIO driver installed')
      else FDevice.Items.Add('No audio device found');
      FDevIds.Add('');
      Sel := 0;
    end;
    FDevice.ItemIndex := -1;
    FDevice.ItemIndex := Sel;
    DeviceChange(nil);
  finally
    L.Free;
  end;
end;

{ ---- events ---- }

procedure TPrefsForm.NavCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
var
  C: TARGB;
begin
  Handled := True;
  if (Row < 0) or (Row > High(FNavCaptions)) then Exit;
  if FNav.Selected[Row] then C := clAccentText else C := clTextDim;
  DrawIcon(G, FNavIcons[Row], X + S(20), Y + H / 2, S(17), C);
  if FNav.Selected[Row] then C := clText;
  G.Text(FNavCaptions[Row], X + S(42), Y, W - S(46), H, UIFont(13.5, FNav.Selected[Row]), C, 0, 1);
end;

procedure TPrefsForm.NavSel(Sender: TObject);
var
  I, P: Integer;
begin
  P := FNav.FocusedRow;
  if (P < 0) or (P > High(FPages)) or not FNav.Selected[P] then Exit;
  if FPages[P].Visible then Exit;
  for I := 0 to High(FPages) do FPages[I].Visible := I = P;
  { the new page fades in, moving up a little }
  EntranceFade(FPages[P], S(12));
end;

{ Enter on the page list: OK (the list itself has no use for it) }
procedure TPrefsForm.NavActivate(Sender: TObject; Row: Integer);
begin
  ModalResult := mrOK;
end;

procedure TPrefsForm.AnyChange(Sender: TObject);
var
  I: Integer;
begin
  if (Sender = FResample) or (Sender = FLockVolume) or (Sender = FDoP) then EnableControls;
  { the cards' summary lines show the settings }
  for I := 0 to High(FCards) do FCards[I].Head.Invalidate;
end;

procedure TPrefsForm.ApiChange(Sender: TObject);
begin
  FillDevices;
end;

procedure TPrefsForm.DeviceChange(Sender: TObject);
var
  Id: string;
begin
  if (FDevice.ItemIndex < 0) or (FDevice.ItemIndex >= FDevIds.Count) then Exit;
  Id := FDevIds[FDevice.ItemIndex];
  if Id = '' then Exit;
  if SelectedApi = 1 then FAsioId := Id else FWasapiId := Id;
end;

procedure TPrefsForm.ThemePreview(Sender: TObject);
begin
  SetTheme(TAuThemeMode(EnsureRange(FTheme.ItemIndex, 0, 2)), FAccent.ItemIndex);
end;

procedure TPrefsForm.ShortcutCell(Sender: TObject; Row, Col: Integer; var AText: string);
begin
  if (Row >= 0) and (Row <= High(SHORTCUTS)) and (Col >= 0) and (Col <= 1) then AText := SHORTCUTS[Row, Col];
end;

{ the folder with an icon; network folders say that they are not watched }
procedure TPrefsForm.FolderCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
  var Handled: Boolean);
var
  F, FS: TGfxFont;
  NoteW: Single;
  Note: string;
  C: TARGB;
begin
  if (Row < 0) or (Row >= FFolders.Count) then Exit;
  Handled := True;
  if FFolderList.Enabled then C := clText else C := clTextFaint;
  DrawIcon(G, icFolder, X + S(14), Y + H / 2, S(16), clTextDim);
  F := UIFont(13);
  NoteW := 0;
  if IsNetworkFolder(FFolders[Row]) then
  begin
    FS := UIFont(11.5);
    Note := 'network - not watched';
    NoteW := TextWidth(Note, FS) + S(8);
    G.Text(Note, X + W - NoteW, Y, NoteW - S(4), H, FS, clTextFaint, 2, 1);
  end;
  G.Text(FFolders[Row], X + S(30), Y, W - S(34) - NoteW, H, F, C, 0, 1);
end;

procedure TPrefsForm.FolderSel(Sender: TObject);
begin
  UpdateLibraryButtons;
end;

procedure TPrefsForm.FolderKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if FScanning then Exit;
  if (Key = VK_DELETE) and (Shift = []) then
  begin
    Key := 0;
    RemoveFolderClick(nil);
  end
  else if (Key = VK_INSERT) and (Shift = []) then
  begin
    Key := 0;
    AddFolderClick(nil);
  end;
end;

{ Remove works on the selected folders; Scan Now and Repair always on all of
  them, so they only need a folder (not FLibrary <> nil, which
  ShowPreferences sets after the constructor: they would
  stay off until the first selection change) }
procedure TPrefsForm.UpdateLibraryButtons;
begin
  FFolderList.Enabled := not FScanning;
  FBtnAdd.Enabled := not FScanning;
  FBtnRemove.Enabled := (not FScanning) and (FFolderList.SelCount > 0);
  FBtnScan.Enabled := (not FScanning) and (FFolders.Count > 0);
  FBtnRepair.Enabled := (not FScanning) and (FFolders.Count > 0);
  FFolderList.Invalidate;
end;

procedure TPrefsForm.AddFolderClick(Sender: TObject);
var
  Dir, D, Existing: string;
  I: Integer;
begin
  Dir := '';
  if FFolders.Count > 0 then Dir := FFolders[FFolders.Count - 1];
  if not AuPickFolder('Add a library folder', Dir) then Exit;
  D := IncludeTrailingPathDelimiter(Dir);
  { a folder inside a library folder is already part of it }
  for I := 0 to FFolders.Count - 1 do
  begin
    Existing := IncludeTrailingPathDelimiter(FFolders[I]);
    if SameText(Copy(D, 1, Length(Existing)), Existing) then
    begin
      AuMessage('"' + Dir + '" is already in the library: it is inside "' + FFolders[I] + '".',
        amInfo, abOK, TITLE_PREFERENCES);
      Exit;
    end;
  end;
  { folders inside the new one are taken over by it }
  for I := FFolders.Count - 1 downto 0 do
    if SameText(Copy(IncludeTrailingPathDelimiter(FFolders[I]), 1, Length(D)), D) then
      FFolders.Delete(I);
  FFolders.Add(ExcludeTrailingPathDelimiter(Dir));
  FFolderList.RowCount := FFolders.Count;
  FFolderList.SelectOnly(FFolders.Count - 1);
  FFolderList.Changed;
  UpdateLibraryButtons;
end;

procedure TPrefsForm.RemoveFolderClick(Sender: TObject);
var
  Sel: TIntegerArray;
  I: Integer;
begin
  Sel := FFolderList.SelectedRows;
  if Length(Sel) = 0 then Exit;
  for I := High(Sel) downto 0 do
    if (Sel[I] >= 0) and (Sel[I] < FFolders.Count) then FFolders.Delete(Sel[I]);
  FFolderList.ClearSelection;
  FFolderList.RowCount := FFolders.Count;
  FFolderList.Changed;
  UpdateLibraryButtons;
end;

{ the folder list is applied at once, then the scan starts }
procedure TPrefsForm.ScanClick(Sender: TObject);
begin
  if (FLibrary = nil) or not Assigned(FOnScan) or FScanning then Exit;
  ScanStatus(STATUS_SCANNING_FULL);
  FOnScan(FFolders, False);
  if not FLibrary.IsScanning then ScanStatus('');
end;

procedure TPrefsForm.RepairClick(Sender: TObject);
begin
  if (FLibrary = nil) or not Assigned(FOnScan) or FScanning then Exit;
  if ALMessageDlg(TITLE_REPAIR_LIBRARY, MSG_REPAIR_LIBRARY_CONFIRM, [mbYes, mbNo], mbNo, mkWarning) <> mrYes then
    Exit;
  ScanStatus(STATUS_SCANNING_FULL);
  FOnScan(FFolders, True);
  if not FLibrary.IsScanning then ScanStatus('');
end;

procedure TPrefsForm.ScanStatus(const AText: string);
begin
  FScanning := AText <> '';
  FStatus.Caption := AText;
  UpdateLibraryButtons;
end;

end.
