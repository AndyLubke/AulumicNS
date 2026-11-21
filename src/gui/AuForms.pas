unit AuForms;

{ ==============================================================================
  AulumicNS - AuForms
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Base window class (TAuForm: themed title bar and background, Enter /
  Escape handling, follows theme switches), message and input dialogs, and
  toast notifications. All windows are built in code - no .lfm files.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType, LMessages,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls, AuTitleBar;

type
  { TAuForm }

  TAuForm = class(TForm)
  private
    FDefaultButton: TAuButton;
    FIsDialog: Boolean;
    FTitleBar: TAuTitleBar;
    FBody: TAuPanel;
    FCloakPending: Boolean;     // shown cloaked, AUM_UNCLOAK posted
    FFade: TAuWindowFade;       // fades in when it opens (not the main window)
    FFadeIn: Boolean;
    FDropIn: Integer;
    FThemeShot: TGfxBitmap;     // how the window looked before the theme changed
    FCreateExtra96: Integer;    // the height Windows added at CreateWnd (96 DPI)
    FCreateExtraKnown: Boolean;
    procedure ThemeFade(Data: PtrInt);
    function GetBody: TWinControl;
    function ParentFor(AParent: TWinControl): TWinControl;
    procedure ThemeChanged(Sender: TObject);
    procedure WMDpiChangedAu(var Msg: TLMessage); message LM_DPICHANGED;
  protected
    procedure CreateWnd; override;
    procedure RealSetText(const AValue: TCaption); override;
    procedure WndProc(var TheMessage: TLMessage); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure ThemeUpdated; virtual;
    procedure DpiUpdated; virtual;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    constructor CreateAu(AOwner: TComponent; const ACaption: string; AW, AH: Integer);
    destructor Destroy; override;
    { rescales the whole window (geometry, cached sizes, fonts) to a new DPI }
    procedure RescaleTo(NewDpi: Integer);
    { replaces the Windows title bar with TAuTitleBar (call before the other
      controls are created, so that it is the topmost one) }
    procedure EnableCustomFrame;
    property TitleBar: TAuTitleBar read FTitleBar;
    { the area below the title bar: a dialog (CreateAu) places its controls on
      this panel; the Add* methods take Self for it. Self without a body. }
    property Body: TWinControl read GetBody;
    { the client height below the title bar }
    function BodyHeight: Integer;
    { the size to remember for a sizable window, in 96-DPI
      units, so that CreateAu(.., W, H) brings it back as it is. The height
      is BodyHeight less the caption and frame Windows added when the handle
      was created (measured in CreateWnd; NewWindowCaptionExtra misses the
      padded border of a sizable frame) - remembering BodyHeight itself would
      make the window about 30 px higher at every opening. }
    procedure SizeToRemember(out W, H: Integer);
    { makes the window at most as large as the work area of the
      main window's monitor (less a margin). Only for a window whose content
      follows its size (a sizable one, scrolling pages): a small screen at a
      large scaling (1920 x 1080 at 150 % leaves 1280 x 688). }
    procedure FitToWorkArea;
    { renders the client area into a PNG file: every control paints itself
      (TAuControl.RenderTo), so it works without a composited desktop
      (screenshot mode, the help screenshots) }
    procedure SaveImage(const AFileName: string);
    function AddLabel(AParent: TWinControl; const ACaption: string; X, Y, W: Integer; ADim: Boolean = True): TAuLabel;
    function AddHeading(AParent: TWinControl; const ACaption: string; X, Y, W: Integer): TAuLabel;
    function AddEdit(AParent: TWinControl; X, Y, W: Integer; const AText: string = ''): TAuEdit;
    function AddSpin(AParent: TWinControl; X, Y, W, AMin, AMax, AValue: Integer): TAuEdit;
    function AddCombo(AParent: TWinControl; X, Y, W: Integer; const AItems: array of string; AIndex: Integer = 0): TAuCombo;
    function AddCheck(AParent: TWinControl; const ACaption: string; X, Y, W: Integer; AChecked: Boolean): TAuCheckBox;
    function AddSwitch(AParent: TWinControl; const ACaption, ADesc: string; X, Y, W: Integer; AChecked: Boolean): TAuSwitch;
    function AddRadio(AParent: TWinControl; const ACaption: string; X, Y, W, AGroup: Integer; AChecked: Boolean): TAuRadio;
    function AddButton(AParent: TWinControl; const ACaption: string; X, Y, W: Integer;
      AKind: TAuButtonKind = bkNormal; AClick: TNotifyEvent = nil): TAuButton;
    property DefaultButton: TAuButton read FDefaultButton write FDefaultButton;
    property IsDialog: Boolean read FIsDialog write FIsDialog;
    { fades in when it is shown (windows made with CreateAu: on) }
    property FadeIn: Boolean read FFadeIn write FFadeIn;
    { > 0: the window also comes down this far (unscaled pixels) into its
      place while it fades in - the cover and the artist viewer }
    property DropIn: Integer read FDropIn write FDropIn;
  end;

var
  { opens the help at a topic; set by the help window's unit. F1 in a
    TAuForm with a HelpKeyword calls it with that keyword. }
  AuShowHelp: procedure(const ATopic: string) = nil;

type
  TAuMsgKind = (amInfo, amWarning, amError, amQuestion);
  TAuMsgButtons = (abOK, abOKCancel, abYesNo, abYesNoCancel);

  { TAuToast - transient notification at the bottom of a window }

  TAuToast = class(TAuControl)
  private
    FTitle, FText: string;
    FIcon: TAuIcon;
    FTimer: TTimer;
    FBottom: Integer;
    procedure TimerTick(Sender: TObject);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure DpiChanged; override;
    procedure ShowToast(const ATitle, AText: string; AIcon: TAuIcon = icInfo; AMillis: Integer = 3200);
    procedure Place;
    property BottomOffset: Integer read FBottom write FBottom;
  end;

const
  { how far the cover and the artist viewer come down as they open (unscaled) }
  VIEWER_DROP_PX = 140;
  AppTitle = 'Aulumic';

function AuMessage(const Msg: string; Kind: TAuMsgKind = amInfo; Buttons: TAuMsgButtons = abOK;
  const Title: string = AppTitle): TModalResult;
function AuInput(const Title, Prompt: string; var Value: string): Boolean;
{ the message window of AuMessage, not shown yet (screenshot mode) }
function CreateMessageForm(const Msg: string; Kind: TAuMsgKind = amInfo; Buttons: TAuMsgButtons = abOK;
  const Title: string = AppTitle): TAuForm;

implementation

{ ---- TAuForm ---- }

constructor TAuForm.CreateNew(AOwner: TComponent; Num: Integer);
var
  D: Integer;
begin
  { a dialog starts with the DPI of the window that owns it }
  D := CurDpi;
  if (AOwner is TCustomForm) and (TCustomForm(AOwner).PixelsPerInch >= 48) then
    D := TCustomForm(AOwner).PixelsPerInch;
  inherited CreateNew(AOwner, Num);
  Scaled := False;              // scaling is done by RescaleTo, not by the LCL
  PixelsPerInch := D;
  CurDpi := D;
  Color := ToTColor(clBg);
  KeyPreview := True;
  AddThemeListener(@ThemeChanged);
end;

{ a dialog: our own title bar in the background colour (no icon, only the
  close button; minimize / maximize when a descendant allows them) and the
  body panel below it, AW x AH (unscaled) }
constructor TAuForm.CreateAu(AOwner: TComponent; const ACaption: string; AW, AH: Integer);
begin
  CreateNew(AOwner, 0);
  FIsDialog := True;
  FFadeIn := True;
  Caption := ACaption;
  BorderStyle := bsDialog;
  BorderIcons := [biSystemMenu];
  Position := poOwnerFormCenter;
  EnableCustomFrame;
  FTitleBar.ShowIcon := False;
  FTitleBar.BackRole := crBg;
  FBody := TAuPanel.Create(Self);
  FBody.Parent := Self;
  FBody.Align := alClient;
  FBody.BackRole := crBg;
  FBody.BorderSides := 0;
  FBody.TabStop := False;
  ClientWidth := S(AW);
  ClientHeight := S(AH) + FTitleBar.Height;
end;

function TAuForm.GetBody: TWinControl;
begin
  if FBody <> nil then Result := FBody else Result := Self;
end;

function TAuForm.ParentFor(AParent: TWinControl): TWinControl;
begin
  if (AParent = Self) and (FBody <> nil) then Result := FBody else Result := AParent;
end;

function TAuForm.BodyHeight: Integer;
begin
  Result := ClientHeight;
  if (FTitleBar <> nil) and FTitleBar.Visible then Dec(Result, FTitleBar.Height);
end;

{ the height a window grows by when its handle is created:
  until then Height is its client height; Windows puts a caption and a frame
  around it, and the own title bar (WM_NCCALCSIZE) turns them into client
  area. Measured: caption + fixed frame for a dialog, caption + resize frame
  for a sizable window (at the DPI of the main window) }
type
  TGetDpiForWindowF = function(Wnd: HWND): UINT; stdcall;
  TGetSystemMetricsForDpiF = function(Index: Integer; Dpi: UINT): Integer; stdcall;

function NewWindowCaptionExtra(ASizeable: Boolean): Integer;
var
  Lib: HMODULE;
  PDpi: TGetDpiForWindowF;
  PMet: TGetSystemMetricsForDpiF;
  Dpi: UINT;
  FrameIdx: Integer;
begin
  if ASizeable then FrameIdx := SM_CYSIZEFRAME else FrameIdx := SM_CYFIXEDFRAME;
  Lib := GetModuleHandle('user32.dll');
  PDpi := nil;
  PMet := nil;
  if Lib <> 0 then
  begin
    PDpi := TGetDpiForWindowF(GetProcAddress(Lib, 'GetDpiForWindow'));
    PMet := TGetSystemMetricsForDpiF(GetProcAddress(Lib, 'GetSystemMetricsForDpi'));
  end;
  Dpi := 0;
  if Assigned(PDpi) and (Application.MainForm <> nil) and Application.MainForm.HandleAllocated then
    Dpi := PDpi(Application.MainForm.Handle);
  if Assigned(PMet) and (Dpi >= 48) then
    Result := PMet(SM_CYCAPTION, Dpi) + PMet(FrameIdx, Dpi) + 2
  else
    Result := GetSystemMetrics(SM_CYCAPTION) + GetSystemMetrics(FrameIdx) + 2;
end;

procedure TAuForm.SizeToRemember(out W, H: Integer);
var
  Dpi: Integer;
begin
  Dpi := PixelsPerInch;
  if Dpi < 48 then Dpi := 96;
  W := Round(ClientWidth * 96 / Dpi);
  if FCreateExtraKnown then H := Round(BodyHeight * 96 / Dpi) - FCreateExtra96
  else H := Round((BodyHeight - NewWindowCaptionExtra(BorderStyle in [bsSizeable, bsSizeToolWin])) * 96 / Dpi);
end;

procedure TAuForm.FitToWorkArea;
var
  M: TMonitor;
  WA: TRect;
  Margin, MaxW, MaxH: Integer;
begin
  M := nil;
  if (Application.MainForm <> nil) and Application.MainForm.HandleAllocated then
    M := Screen.MonitorFromWindow(Application.MainForm.Handle);
  if M = nil then M := Screen.PrimaryMonitor;
  if M = nil then Exit;
  WA := M.WorkareaRect;
  Margin := S(16);
  MaxW := WA.Right - WA.Left - Margin;
  MaxH := WA.Bottom - WA.Top - Margin;
  if (MaxW < S(200)) or (MaxH < S(200)) then Exit;
  { the minimum first: it would keep the window from getting smaller }
  if Constraints.MinWidth > MaxW then Constraints.MinWidth := MaxW;
  if Constraints.MinHeight > MaxH then Constraints.MinHeight := MaxH;
  { the client area: with the own title bar it is the whole visible window
    (before the handle exists the LCL still counts a standard frame into
    Width / Height) }
  if not HandleAllocated then Dec(MaxH, NewWindowCaptionExtra(BorderStyle in [bsSizeable, bsSizeToolWin]));
  if ClientWidth > MaxW then ClientWidth := MaxW;
  if ClientHeight > MaxH then ClientHeight := MaxH;
end;

procedure TAuForm.SaveImage(const AFileName: string);
var
  B: TGfxBitmap;
  X: TGfx;
  I: Integer;
  C: TControl;
  St: UINT;
begin
  CurDpi := PixelsPerInch;
  B := nil;
  X := TGfx.CreateBitmap(ClientWidth, ClientHeight);
  try
    X.FillRect(0, 0, ClientWidth, ClientHeight, clBg);
    for I := 0 to ControlCount - 1 do
    begin
      C := Controls[I];
      if not (C.Visible and (C is TAuControl)) then Continue;
      St := X.Save;
      X.Translate(C.Left, C.Top);
      X.IntersectClipRect(0, 0, C.Width, C.Height);
      TAuControl(C).RenderTo(X);
      X.Restore(St);
    end;
    B := X.ToBitmap;
  finally
    X.Free;
  end;
  SaveBitmapPng(B, AFileName);
  DisposeBitmap(B);
end;

destructor TAuForm.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FThemeShot);
  FreeAndNil(FFade);
  RemoveThemeListener(@ThemeChanged);
  inherited Destroy;
end;

procedure TAuForm.CreateWnd;
var
  D, H0: Integer;
  R: TRect;
begin
  H0 := ClientHeight;              // before the handle: what CreateAu asked for
  inherited CreateWnd;
  ApplyTitleBar(Handle);
  if FTitleBar <> nil then
  begin
    { the border style may have changed after EnableCustomFrame }
    FTitleBar.Sizeable := BorderStyle in [bsSizeable, bsSizeToolWin];
    FTitleBar.ShowMinMax := (biMaximize in BorderIcons) and (BorderStyle in [bsSizeable, bsSingle]);
    FTitleBar.ShowMinimize := biMinimize in BorderIcons;
    InstallCustomFrame(Self, FTitleBar);
    { what Windows added to the height (caption and frame,
      now client area): SizeToRemember takes it off again }
    if not FCreateExtraKnown and Windows.GetClientRect(Handle, R) and (PixelsPerInch >= 48) then
    begin
      FCreateExtra96 := Round((R.Bottom - R.Top - H0) * 96 / PixelsPerInch);
      FCreateExtraKnown := True;
    end;
  end;
  { the window may have been created on a monitor with another DPI than the
    one the form was built for }
  if ForcedDpi > 0 then D := ForcedDpi else D := WindowDpi(Handle);
  if (D >= 48) and (D <> PixelsPerInch) then RescaleTo(D);
end;

procedure TAuForm.EnableCustomFrame;
begin
  if FTitleBar <> nil then Exit;
  FTitleBar := TAuTitleBar.Create(Self);
  FTitleBar.Parent := Self;
  FTitleBar.Align := alTop;
  FTitleBar.Top := 0;
  FTitleBar.Sizeable := BorderStyle in [bsSizeable, bsSizeToolWin];
  FTitleBar.ShowMinMax := (biMaximize in BorderIcons) and (BorderStyle in [bsSizeable, bsSingle]);
  if HandleAllocated then InstallCustomFrame(Self, FTitleBar);
end;

procedure TAuForm.RealSetText(const AValue: TCaption);
begin
  inherited RealSetText(AValue);
  if FTitleBar <> nil then FTitleBar.Invalidate;
end;

procedure TAuForm.WndProc(var TheMessage: TLMessage);
begin
  if HandleAllocated and (PixelsPerInch >= 48) then CurDpi := PixelsPerInch;
  { no white flash: the window is shown cloaked and uncloaked once all its
    controls have painted (the posted message comes before the first paint
    would; ShowModal's loop handles it too) }
  if TheMessage.Msg = AUM_UNCLOAK then
  begin
    FCloakPending := False;
    if FFadeIn then
    begin
      if FFade = nil then FFade := TAuWindowFade.Create(Self);
      if FDropIn > 0 then FFade.Start(S(FDropIn), ANIM_DROP) else FFade.Start(0);
    end
    else
      PaintAndUncloak(Handle);
    TheMessage.Result := 0;
    Exit;
  end;
  { A window that opens maximized gets no WM_SHOWWINDOW before it is on the
    screen, so the moment it is about to be shown is also taken from
    WM_WINDOWPOSCHANGING: without that it would stand there unpainted until
    the cloak came. }
  if (((TheMessage.Msg = WM_SHOWWINDOW) and (TheMessage.WParam <> 0) and (TheMessage.LParam = 0)) or
      ((TheMessage.Msg = WM_WINDOWPOSCHANGING) and (TheMessage.LParam <> 0) and
       ((PWindowPos(TheMessage.LParam)^.flags and SWP_SHOWWINDOW) <> 0))) and
    HandleAllocated and not FCloakPending then
  begin
    SetWindowCloak(Handle, True);
    FCloakPending := True;
    PostMessage(Handle, AUM_UNCLOAK, 0, 0);
  end;
  inherited WndProc(TheMessage);
end;

procedure TAuForm.WMDpiChangedAu(var Msg: TLMessage);
var
  R: PRect;
  NewDpi: Integer;
begin
  Msg.Result := 0;
  if ForcedDpi > 0 then Exit;          // screenshot mode keeps its scaling
  NewDpi := HiWord(Cardinal(Msg.WParam));
  R := PRect(Msg.LParam);
  if (NewDpi >= 48) and (NewDpi <> PixelsPerInch) then RescaleTo(NewDpi);
  { the system suggests the new window rectangle (same physical size ratio) }
  if R <> nil then
    SetBounds(R^.Left, R^.Top, R^.Right - R^.Left, R^.Bottom - R^.Top);
  Msg.Result := 0;
end;

procedure RelayoutTree(C: TWinControl);
var
  I: Integer;
begin
  for I := 0 to C.ControlCount - 1 do
  begin
    if C.Controls[I] is TAuControl then TAuControl(C.Controls[I]).DpiChanged;
    if C.Controls[I] is TWinControl then RelayoutTree(TWinControl(C.Controls[I]));
  end;
end;

procedure TAuForm.RescaleTo(NewDpi: Integer);
var
  OldDpi: Integer;
begin
  OldDpi := PixelsPerInch;
  if (NewDpi < 48) or (OldDpi < 48) or (NewDpi = OldDpi) then Exit;
  DisableAlign;
  try
    { LCL scales bounds, constraints and spacings of every control; our
      controls rescale their own cached sizes in ScaleCached }
    AutoAdjustLayout(lapAutoAdjustForDPI, OldDpi, NewDpi, Width, MulDiv(Width, NewDpi, OldDpi));
    PixelsPerInch := NewDpi;
    CurDpi := NewDpi;
  finally
    EnableAlign;
  end;
  CurDpi := NewDpi;
  RelayoutTree(Self);
  DpiUpdated;
  if HandleAllocated then
    RedrawWindow(Handle, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_FRAME);
end;

procedure TAuForm.DpiUpdated;
begin
  { descendants re-layout DPI dependent parts here }
end;

procedure TAuForm.ThemeChanged(Sender: TObject);
begin
  ThemeUpdated;
  { the fade starts when everybody has heard of the new theme }
  if FThemeShot <> nil then Application.QueueAsyncCall(@ThemeFade, 0);
end;

procedure TAuForm.ThemeFade(Data: PtrInt);
var
  B: TGfxBitmap;
begin
  B := FThemeShot;
  FThemeShot := nil;
  CrossFadeFrom(Self, B);
end;

{ before the colours change: a picture of every window that is on screen }
procedure FormsThemeChanging;
var
  I: Integer;
  F: TCustomForm;
begin
  for I := 0 to Screen.CustomFormCount - 1 do
  begin
    F := Screen.CustomForms[I];
    if (F is TAuForm) and F.Visible and (F.WindowState <> wsMinimized) then
    begin
      FreeAndNil(TAuForm(F).FThemeShot);
      TAuForm(F).FThemeShot := SnapshotControls(F);
    end;
  end;
end;

procedure TAuForm.ThemeUpdated;
begin
  { descendants refresh cached theme dependent state here }
end;

procedure TAuForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  if FIsDialog and (Key = VK_ESCAPE) then
  begin
    Key := 0;
    ModalResult := mrCancel;
    if not (fsModal in FormState) then Close;
  end
  else if (Key = VK_F1) and (Shift = []) and (HelpKeyword <> '') and Assigned(AuShowHelp) then
  begin
    { the help at this window's topic }
    Key := 0;
    AuShowHelp(HelpKeyword);
  end
  else if (Key = VK_RETURN) and (FDefaultButton <> nil) and FDefaultButton.Enabled then
  begin
    { only simple input controls pass Enter on to the default button; buttons,
      combos and lists use Enter themselves }
    if (ActiveControl = nil) or ((ActiveControl is TAuEdit) and not (ActiveControl is TAuMemo)) or (ActiveControl is TAuCheckBox) or
       (ActiveControl is TAuSwitch) or (ActiveControl is TAuRadio) or (ActiveControl is TAuSlider) or
       (ActiveControl is TAuSegmented) or (ActiveControl is TAuSwatches) or (ActiveControl is TAuTabs) then
    begin
      Key := 0;
      FDefaultButton.Click;
    end;
  end;
end;

function TAuForm.AddLabel(AParent: TWinControl; const ACaption: string; X, Y, W: Integer; ADim: Boolean): TAuLabel;
begin
  Result := TAuLabel.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(22));
  Result.Caption := ACaption;
  if ADim then Result.TextRole := crTextDim;
end;

function TAuForm.AddHeading(AParent: TWinControl; const ACaption: string; X, Y, W: Integer): TAuLabel;
begin
  Result := TAuLabel.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(28));
  Result.FontSize := 15;
  Result.Bold := True;
  Result.Caption := ACaption;
end;

function TAuForm.AddEdit(AParent: TWinControl; X, Y, W: Integer; const AText: string): TAuEdit;
begin
  Result := TAuEdit.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(32));
  Result.Text := AText;
end;

function TAuForm.AddSpin(AParent: TWinControl; X, Y, W, AMin, AMax, AValue: Integer): TAuEdit;
begin
  Result := AddEdit(AParent, X, Y, W);
  Result.Numeric := True;
  Result.Spin := True;
  Result.MinValue := AMin;
  Result.MaxValue := AMax;
  Result.Value := AValue;
end;

function TAuForm.AddCombo(AParent: TWinControl; X, Y, W: Integer; const AItems: array of string; AIndex: Integer): TAuCombo;
var
  I: Integer;
begin
  Result := TAuCombo.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(32));
  for I := 0 to High(AItems) do Result.Items.Add(AItems[I]);
  Result.ItemIndex := AIndex;
end;

function TAuForm.AddCheck(AParent: TWinControl; const ACaption: string; X, Y, W: Integer; AChecked: Boolean): TAuCheckBox;
begin
  Result := TAuCheckBox.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(26));
  Result.Caption := ACaption;
  Result.Checked := AChecked;
end;

function TAuForm.AddSwitch(AParent: TWinControl; const ACaption, ADesc: string; X, Y, W: Integer; AChecked: Boolean): TAuSwitch;
begin
  Result := TAuSwitch.Create(Self);
  Result.Parent := ParentFor(AParent);
  if ADesc <> '' then Result.SetBounds(S(X), S(Y), S(W), S(48))
  else Result.SetBounds(S(X), S(Y), S(W), S(28));
  Result.Caption := ACaption;
  Result.Description := ADesc;
  Result.Checked := AChecked;
end;

function TAuForm.AddRadio(AParent: TWinControl; const ACaption: string; X, Y, W, AGroup: Integer; AChecked: Boolean): TAuRadio;
begin
  Result := TAuRadio.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(26));
  Result.Caption := ACaption;
  Result.GroupIndex := AGroup;
  Result.Checked := AChecked;
end;

function TAuForm.AddButton(AParent: TWinControl; const ACaption: string; X, Y, W: Integer;
  AKind: TAuButtonKind; AClick: TNotifyEvent): TAuButton;
begin
  Result := TAuButton.Create(Self);
  Result.Parent := ParentFor(AParent);
  Result.SetBounds(S(X), S(Y), S(W), S(32));
  Result.Caption := ACaption;
  Result.Kind := AKind;
  Result.OnClick := AClick;
end;

{ ---- message box ---- }

type
  TMsgIconView = class(TAuControl)
  public
    Kind: TAuMsgKind;
  protected
    procedure DoPaint(G: TGfx); override;
  end;

procedure TMsgIconView.DoPaint(G: TGfx);
var
  C: TARGB;
  Ic: TAuIcon;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  case Kind of
    amWarning: begin C := clWarn; Ic := icWarning; end;
    amError: begin C := clBad; Ic := icWarning; end;
    amQuestion: begin C := clAccentText; Ic := icInfo; end;
  else
    begin C := clAccentText; Ic := icInfo; end;
  end;
  G.FillCircle(Width / 2, Height / 2, Width / 2, Blend(EffBack, C, 0.16));
  DrawIcon(G, Ic, Width / 2, Height / 2, Width * 0.55, C);
end;

function CreateMessageForm(const Msg: string; Kind: TAuMsgKind; Buttons: TAuMsgButtons; const Title: string): TAuForm;
var
  F: TAuForm;
  L: TAuLabel;
  IV: TMsgIconView;
  TH, H, X: Integer;

  function Btn(const C: string; R: TModalResult; Primary: Boolean): TAuButton;
  begin
    if Primary then Result := F.AddButton(F, C, 0, 0, 100, bkPrimary)
    else Result := F.AddButton(F, C, 0, 0, 100);
    Result.ModalResult := R;
    Result.Width := Math.Max(S(100), Result.PreferredWidth);
    X := X - Round(Result.Width / UIScale);
    Result.Left := S(X);
    Result.Top := S(H - 56);
    X := X - 10;
  end;

begin
  TH := Ceil(TextHeightWrapped(Msg, UIFont(13), S(360)) / UIScale);
  H := Math.Max(140, TH + 104);
  if H > 600 then H := 600;
  F := TAuForm.CreateAu(Application.MainForm, Title, 480, H);
  Result := F;
  try
    IV := TMsgIconView.Create(F);
    IV.Parent := F.Body;
    IV.Kind := Kind;
    IV.SetBounds(S(24), S(18), S(40), S(40));
    L := F.AddLabel(F, Msg, 84, 18, 372, False);
    L.Height := S(H - 90);
    L.WordWrap := True;
    L.VAlign := 0;
    X := 456;
    case Buttons of
      abOK: F.DefaultButton := Btn('OK', mrOK, True);
      abOKCancel:
        begin
          Btn('Cancel', mrCancel, False);
          F.DefaultButton := Btn('OK', mrOK, True);
        end;
      abYesNo:
        begin
          Btn('No', mrNo, False);
          F.DefaultButton := Btn('Yes', mrYes, True);
        end;
      abYesNoCancel:
        begin
          Btn('Cancel', mrCancel, False);
          Btn('No', mrNo, False);
          F.DefaultButton := Btn('Yes', mrYes, True);
        end;
    end;
    F.ActiveControl := F.DefaultButton;
  except
    F.Free;
    raise;
  end;
end;

function AuMessage(const Msg: string; Kind: TAuMsgKind; Buttons: TAuMsgButtons; const Title: string): TModalResult;
var
  F: TAuForm;
begin
  F := CreateMessageForm(Msg, Kind, Buttons, Title);
  try
    Result := F.ShowModal;
    if (Buttons = abYesNo) and (Result = mrCancel) then Result := mrNo;
  finally
    F.Free;
  end;
end;

function AuInput(const Title, Prompt: string; var Value: string): Boolean;
var
  F: TAuForm;
  E: TAuEdit;
  B1, B2: TAuButton;
begin
  F := TAuForm.CreateAu(Application.MainForm, Title, 520, 160);
  try
    F.AddLabel(F, Prompt, 24, 18, 472);
    E := F.AddEdit(F, 24, 46, 472, Value);
    B2 := F.AddButton(F, 'Cancel', 288, 108, 96);
    B2.ModalResult := mrCancel;
    B1 := F.AddButton(F, 'OK', 400, 108, 96, bkPrimary);
    B1.ModalResult := mrOK;
    F.DefaultButton := B1;
    F.ActiveControl := E;
    E.SelectAll;
    Result := F.ShowModal = mrOK;
    if Result then Value := E.Text;
  finally
    F.Free;
  end;
end;

{ ---- TAuToast ---- }

constructor TAuToast.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Visible := False;
  FBottom := S(24);
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerTick;
  FocusOnClick := False;
end;

procedure TAuToast.Place;
var
  W: Integer;
begin
  if Parent = nil then Exit;
  W := Ceil(Math.Max(TextWidth(FTitle, UIFont(13, True)), TextWidth(FText, UIFont(12.5)))) + S(84);
  if W > Parent.ClientWidth - S(40) then W := Parent.ClientWidth - S(40);
  if FText <> '' then Height := S(62) else Height := S(46);
  Width := W;
  Left := (Parent.ClientWidth - W) div 2;
  Top := Parent.ClientHeight - Height - FBottom;
end;

procedure TAuToast.ShowToast(const ATitle, AText: string; AIcon: TAuIcon; AMillis: Integer);
begin
  FTitle := ATitle;
  FText := AText;
  FIcon := AIcon;
  Place;
  Visible := True;
  BringToFront;
  Invalidate;
  FTimer.Enabled := False;
  FTimer.Interval := AMillis;
  FTimer.Enabled := True;
end;

procedure TAuToast.ScaleCached(K: Double);
begin
  FBottom := Round(FBottom * K);
end;

procedure TAuToast.DpiChanged;
begin
  if Visible then Place;
  inherited DpiChanged;
end;

procedure TAuToast.TimerTick(Sender: TObject);
begin
  FTimer.Enabled := False;
  Visible := False;
end;

procedure TAuToast.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  FTimer.Enabled := False;
  Visible := False;
end;

procedure TAuToast.DoPaint(G: TGfx);
begin
  G.FillRect(0, 0, Width, Height, ParentBack);
  G.FillRound(0, 0, Width, Height, S(12), clCard);
  G.StrokeRound(0, 0, Width, Height, S(12), 1, clBorderHi);
  G.FillCircle(S(30), Height / 2, S(14), Blend(clCard, clAccent, 0.18));
  DrawIcon(G, FIcon, S(30), Height / 2, S(16), clAccentText);
  if FText <> '' then
  begin
    G.Text(FTitle, S(56), S(10), Width - S(70), S(22), UIFont(13, True), clText, 0, 1);
    G.Text(FText, S(56), S(31), Width - S(70), S(20), UIFont(12.5), clTextDim, 0, 1);
  end
  else
    G.Text(FTitle, S(56), 0, Width - S(70), Height, UIFont(13, True), clText, 0, 1);
end;

initialization
  OnThemeChanging := @FormsThemeChanging;

finalization
  OnThemeChanging := nil;

end.
