unit AuDialogs;

{ ==============================================================================
  AulumicNS - AuDialogs
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The message dialogs (ALMessageDlg) in the style of AulumicNS: buttons as
  TMsgDlgButtons, a default button, the kind of message, or two own
  captions, shown with the themed TAuForm.
  =============================================================================}

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, Dialogs, AuGfx, AuTheme, AuIcons, AuControls, AuForms;

type
  TALMsgKind = (mkAuto, mkNone, mkInfo, mkQuestion, mkWarning, mkError);

procedure ALMessageDlg(const ATitle, AMsg: string; AKind: TALMsgKind = mkAuto); overload;
function ALMessageDlg(const ATitle, AMsg: string; Buttons: TMsgDlgButtons;
  DefaultButton: TMsgDlgBtn = mbOK; AKind: TALMsgKind = mkAuto): TModalResult; overload;
{ two own captions: Yes = CustomYesCaption, No = CustomNoCaption (+ Cancel) }
function ALMessageDlg(const ATitle, AMsg: string; const CustomYesCaption,
  CustomNoCaption: string; ShowCancel: Boolean = False;
  DefaultButton: TMsgDlgBtn = mbYes; AKind: TALMsgKind = mkAuto): TModalResult; overload;

{ An error that nothing caught, in the themed message window - also before
  the main window exists and after it is gone. One at a time: an error raised
  while the window is open is not shown. The plain system box is used only
  when the themed window itself cannot be shown. }
procedure ShowErrorBox(E: Exception);
{ makes ShowErrorBox the handler of every exception that escapes an event
  (Application.OnException); the main window puts its own in front while it
  lives, which writes the log first }
procedure InstallErrorBox;

var
  { no error windows at all: the tool modes of the debug build, which nobody
    watches and which must end by themselves }
  ErrorBoxesOff: Boolean = False;

implementation

uses
  uAppStrings, uOSUtils;

type
  TBtnDef = record
    Caption: string;
    Result: TModalResult;
    Btn: TMsgDlgBtn;
  end;

  TMsgIcon = class(TAuControl)
  public
    Kind: TALMsgKind;
  protected
    procedure DoPaint(G: TGfx); override;
  end;

procedure TMsgIcon.DoPaint(G: TGfx);
var
  C: TARGB;
  Ic: TAuIcon;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  case Kind of
    mkWarning: begin C := clWarn; Ic := icWarning; end;
    mkError: begin C := clBad; Ic := icWarning; end;
    mkQuestion: begin C := clAccentText; Ic := icHelp; end;
  else
    begin C := clAccentText; Ic := icInfo; end;
  end;
  G.FillCircle(Width / 2, Height / 2, Width / 2, Blend(EffBack, C, 0.16));
  DrawIcon(G, Ic, Width / 2, Height / 2, Width * 0.55, C);
end;

function ShowDlg(const ATitle, AMsg: string; const Btns: array of TBtnDef;
  DefaultButton: TMsgDlgBtn; AKind: TALMsgKind): TModalResult;
var
  F: TAuForm;
  L: TAuLabel;
  IV: TMsgIcon;
  B: TAuButton;
  TH, H, X, I: Integer;
  Owner: TComponent;
begin
  Owner := Screen.ActiveCustomForm;
  if Owner = nil then Owner := Application.MainForm;
  TH := Ceil(TextHeightWrapped(AMsg, UIFont(13), S(380)) / UIScale);
  H := Math.Max(140, TH + 104);
  if H > 640 then H := 640;
  F := TAuForm.CreateAu(Owner, ATitle, 500, H);
  try
    if AKind <> mkNone then
    begin
      IV := TMsgIcon.Create(F);
      IV.Parent := F.Body;
      IV.Kind := AKind;
      IV.SetBounds(S(24), S(18), S(40), S(40));
    end;
    L := F.AddLabel(F, AMsg, 84, 18, 392, False);
    L.Height := S(H - 90);
    L.WordWrap := True;
    L.VAlign := 0;
    X := 476;
    for I := High(Btns) downto 0 do
    begin
      if Btns[I].Btn = DefaultButton then B := F.AddButton(F, Btns[I].Caption, 0, 0, 100, bkPrimary)
      else B := F.AddButton(F, Btns[I].Caption, 0, 0, 100);
      B.ModalResult := Btns[I].Result;
      B.Width := Math.Max(S(100), B.PreferredWidth);
      X := X - Round(B.Width / UIScale);
      B.Left := S(X);
      B.Top := S(H - 56);
      X := X - 10;
      if Btns[I].Btn = DefaultButton then
      begin
        F.DefaultButton := B;
        F.ActiveControl := B;
      end;
    end;
    Result := F.ShowModal;
  finally
    F.Free;
  end;
end;

const
  SYSTEM_BOX_ERROR_ICON = $10;   // MB_ICONERROR

type
  TErrorBoxHandler = class
    procedure AppException(Sender: TObject; E: Exception);
  end;

var
  GErrorBoxHandler: TErrorBoxHandler = nil;
  GInErrorBox: Boolean = False;

procedure ShowErrorBox(E: Exception);
var
  T: string;
begin
  if ErrorBoxesOff or GInErrorBox or (E = nil) then Exit;
  GInErrorBox := True;
  try
    T := E.Message;
    if Trim(T) = '' then T := E.ClassName;
    T := SafeFormat(FMT_ERR_UNEXPECTED, [T]);
    try
      ALMessageDlg(TITLE_ERROR, T, [mbOK], mbOK, mkError);
    except
      try
        Application.MessageBox(PChar(T), PChar(TITLE_ERROR), SYSTEM_BOX_ERROR_ICON);
      except
      end;
    end;
  finally
    GInErrorBox := False;
  end;
end;

procedure TErrorBoxHandler.AppException(Sender: TObject; E: Exception);
begin
  ShowErrorBox(E);
end;

procedure InstallErrorBox;
begin
  if GErrorBoxHandler = nil then GErrorBoxHandler := TErrorBoxHandler.Create;
  Application.OnException := @GErrorBoxHandler.AppException;
end;

procedure ALMessageDlg(const ATitle, AMsg: string; AKind: TALMsgKind);
begin
  ALMessageDlg(ATitle, AMsg, [mbOK], mbOK, AKind);
end;

function ALMessageDlg(const ATitle, AMsg: string; Buttons: TMsgDlgButtons;
  DefaultButton: TMsgDlgBtn; AKind: TALMsgKind): TModalResult;
var
  Defs: array of TBtnDef;

  procedure AddB(B: TMsgDlgBtn; const C: string; R: TModalResult);
  begin
    if not (B in Buttons) then Exit;
    SetLength(Defs, Length(Defs) + 1);
    Defs[High(Defs)].Caption := C;
    Defs[High(Defs)].Result := R;
    Defs[High(Defs)].Btn := B;
  end;

begin
  if AKind = mkAuto then
  begin
    if (mbYes in Buttons) or (mbNo in Buttons) then AKind := mkQuestion else AKind := mkInfo;
  end;
  Defs := nil;
  AddB(mbYes, 'Yes', mrYes);
  AddB(mbNo, 'No', mrNo);
  AddB(mbOK, 'OK', mrOK);
  AddB(mbRetry, 'Retry', mrRetry);
  AddB(mbIgnore, 'Ignore', mrIgnore);
  AddB(mbCancel, 'Cancel', mrCancel);
  AddB(mbAbort, 'Abort', mrAbort);
  if Length(Defs) = 0 then AddB(mbOK, 'OK', mrOK);
  if Length(Defs) = 0 then
  begin
    SetLength(Defs, 1);
    Defs[0].Caption := 'OK';
    Defs[0].Result := mrOK;
    Defs[0].Btn := mbOK;
  end;
  Result := ShowDlg(ATitle, AMsg, Defs, DefaultButton, AKind);
  { closed with Esc / the title bar: "Cancel", or "No" when there is no Cancel }
  if (Result = mrCancel) and not (mbCancel in Buttons) then
  begin
    if mbNo in Buttons then Result := mrNo
    else if mbOK in Buttons then Result := mrOK;
  end;
end;

function ALMessageDlg(const ATitle, AMsg: string; const CustomYesCaption,
  CustomNoCaption: string; ShowCancel: Boolean; DefaultButton: TMsgDlgBtn;
  AKind: TALMsgKind): TModalResult;
var
  Defs: array of TBtnDef;
begin
  if AKind = mkAuto then AKind := mkQuestion;
  if ShowCancel then SetLength(Defs, 3) else SetLength(Defs, 2);
  Defs[0].Caption := CustomYesCaption;
  Defs[0].Result := mrYes;
  Defs[0].Btn := mbYes;
  Defs[1].Caption := CustomNoCaption;
  Defs[1].Result := mrNo;
  Defs[1].Btn := mbNo;
  if ShowCancel then
  begin
    Defs[2].Caption := 'Cancel';
    Defs[2].Result := mrCancel;
    Defs[2].Btn := mbCancel;
  end;
  Result := ShowDlg(ATitle, AMsg, Defs, DefaultButton, AKind);
  if (Result = mrCancel) and not ShowCancel then Result := mrNo;
end;

finalization
  FreeAndNil(GErrorBoxHandler);

end.
