unit AuAbout;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - AuAbout
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The About window (Main menu > About...): the logo, the name, the version and
  build of this program file (uVersionHelper: read from the file itself), the
  data folder, the credits. "Copy Info" puts the facts on the clipboard for a
  problem report.
  =============================================================================}

interface

uses
  Classes, SysUtils, Controls, Forms, LCLType, Clipbrd,
  AuGfx, AuTheme, AuControls, AuForms;

{ the window, not shown (the main window shows it modal; the screenshot mode
  renders it). ADemo: no folder of this PC in it. }
function CreateAboutForm(AOwner: TComponent; ADemo: Boolean = False): TAuForm;
procedure ShowAbout(AOwner: TComponent);

implementation

uses
  AuAppIcon, AuSettings, uVersionHelper;

const
  ABOUT_W   = 580;
  ABOUT_H   = 540;
  MARGIN    = 28;
  LOGO      = 84;
  ROW_H     = 26;
  LABEL_W   = 110;
  ROWS_TOP  = 140;
  ROW_COUNT = 5;

  { the program is called Aulumic, its file AulumicNS.exe (the name it was
    developed under): what the NS stands for }
  NS_MEANING = 'NS stands for Native Sound';

  TAGLINE = 'Bit-perfect music player for Windows';
  CREDITS =
    'Developed with Lazarus and Free Pascal. The FLAC decoder, the resampler, the EBU R128 ' +
    'loudness meter and the user interface are own code; booklets are shown with the PDF ' +
    'engine of Windows.' + LineEnding + LineEnding +
    'Tag reading and writing: AulumicTag, a fork of OvoTag, Copyright © 2011 Marco Caselli, ' +
    'modified LGPL. Artist information comes from Last.fm, Wikipedia and TheAudioDB. ' +
    'ASIO is a trademark and software of Steinberg Media Technologies GmbH.' +
    LineEnding + LineEnding +
    'Aulumic is free software under the GNU General Public License, version 3: you may ' +
    'use, share and change it. It comes without any warranty. The source code is on GitHub.';

type
  { the background: the logo and the two thin lines around the facts }
  TAboutArt = class(TAuControl)
  protected
    procedure DoPaint(G: TGfx); override;
  end;

  TAboutForm = class(TAuForm)
  private
    FInfo: string;
    procedure CopyClick(Sender: TObject);
    procedure Row(AIndex: Integer; const AName, AValue: string);
  public
    constructor CreateAbout(AOwner: TComponent; ADemo: Boolean);
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

procedure TAboutForm.Row(AIndex: Integer; const AName, AValue: string);
var
  L: TAuLabel;
  Y: Integer;
begin
  Y := ROWS_TOP + AIndex * ROW_H;
  L := AddLabel(Self, AName, MARGIN, Y, LABEL_W, True);
  L.Height := S(ROW_H);
  L := AddLabel(Self, AValue, MARGIN + LABEL_W + 12, Y, ABOUT_W - 2 * MARGIN - LABEL_W - 12, False);
  L.Height := S(ROW_H);
  FInfo := FInfo + AName + ': ' + AValue + LineEnding;
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

  if ADemo then DataDir := 'C:\Music Player\Data\' else DataDir := AppDataDir;
  Copyright := GetAppCopyright;
  if Copyright = '' then Copyright := 'Copyright (c) 2026 André Lubke';
  Copyright := StringReplace(Copyright, 'Copyright ', '', [rfIgnoreCase]);
  Copyright := StringReplace(Copyright, '(c)', '©', [rfIgnoreCase]);
  { the version is in the head; the copied text has it as its first line }
  FInfo := 'Aulumic ' + GetAppVersion + LineEnding;
  Row(0, 'Built', GetAppBuildDate);
  Row(1, 'Made with', GetCompilerInfo);
  Row(2, 'Data folder', DataDir);
  Row(3, 'Program file', ExtractFileName(ParamStr(0)) + ' - ' + NS_MEANING);
  Row(4, 'Copyright', Copyright);

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

procedure TAboutForm.CopyClick(Sender: TObject);
begin
  Clipboard.AsText := FInfo;
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
