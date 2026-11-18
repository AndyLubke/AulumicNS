unit AuVolumePopup;

{ ==============================================================================
  AulumicNS - AuVolumePopup
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The volume popup of the speaker button: a slider 0 .. 100 %, the
  percentage, mute, and a note
  when the volume is fixed (Lock Volume to 100 %, or DSD sent as DSD). The
  value is 0 .. 1; the engine works with it in 64-bit floating point.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls;

type
  TVolumeEvent = procedure(Sender: TObject; AVolume: Double) of object;

  { TVolumePopup }

  TVolumePopup = class(TAuPopup)
  private
    FSlider: TAuSlider;
    FPct: TAuLabel;
    FNote: TAuLabel;
    FMute: TAuIconButton;
    FLocked, FMuted: Boolean;
    FOnVolume: TVolumeEvent;
    FOnMute: TNotifyEvent;
    procedure SliderChange(Sender: TObject);
    procedure MuteClick(Sender: TObject);
    procedure UpdateTexts;
    procedure PopupKey(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor CreateVolume(AOwner: TComponent);
    procedure Setup(AVolume: Double; AMuted, ALocked: Boolean; const ALockText: string);
    procedure ShowNear(C: TControl);
    property OnVolume: TVolumeEvent read FOnVolume write FOnVolume;
    property OnMute: TNotifyEvent read FOnMute write FOnMute;
  end;

implementation

constructor TVolumePopup.CreateVolume(AOwner: TComponent);
var
  Bg: TAuPanel;
begin
  CreatePopup(nil);
  KeyPreview := True;
  OnKeyDown := @PopupKey;
  Bg := TAuPanel.Create(Self);
  Bg.Parent := Self;
  Bg.Align := alClient;
  Bg.BackRole := crCard;
  FMute := TAuIconButton.Create(Self);
  FMute.Parent := Bg;
  FMute.SetBounds(S(10), S(12), S(36), S(36));
  FMute.IconSize := 18;
  FMute.Hint := 'Mute (Ctrl+M)';
  FMute.ShowHint := True;
  FMute.OnClick := @MuteClick;
  FSlider := TAuSlider.Create(Self);
  FSlider.Parent := Bg;
  FSlider.SetBounds(S(50), S(14), S(190), S(32));
  FSlider.SetRange(0, 1);
  FSlider.Step := 0.01;
  FSlider.BigStep := 0.1;
  FSlider.AlwaysThumb := True;
  FSlider.TabStop := True;
  FSlider.OnChange := @SliderChange;
  FSlider.OnChangeEnd := @SliderChange;
  FPct := TAuLabel.Create(Self);
  FPct.Parent := Bg;
  FPct.SetBounds(S(244), S(14), S(52), S(32));
  FPct.HAlign := 2;
  FPct.Bold := True;
  FNote := TAuLabel.Create(Self);
  FNote.Parent := Bg;
  FNote.SetBounds(S(14), S(50), S(280), S(20));
  FNote.FontSize := 11.5;
  FNote.TextRole := crTextDim;
end;

procedure TVolumePopup.Setup(AVolume: Double; AMuted, ALocked: Boolean; const ALockText: string);
begin
  FLocked := ALocked;
  FMuted := AMuted;
  if ALocked then FSlider.Position := 1 else FSlider.Position := EnsureRange(AVolume, 0, 1);
  FSlider.Enabled := not ALocked;
  FMute.Enabled := not ALocked;
  if ALocked then FNote.Caption := ALockText
  else FNote.Caption := 'Scroll or use the arrow keys; 100 % = bit-perfect';
  UpdateTexts;
end;

procedure TVolumePopup.UpdateTexts;
var
  V: Double;
begin
  V := FSlider.Position;
  if FMuted and not FLocked then
  begin
    FPct.Caption := 'Mute';
    FMute.Icon := icMute;
  end
  else
  begin
    FPct.Caption := IntToStr(Round(V * 100)) + '%';
    if V <= 0.001 then FMute.Icon := icVolume0
    else if V < 0.5 then FMute.Icon := icVolume1
    else FMute.Icon := icVolume2;
  end;
  FMute.Active := FMuted;
end;

procedure TVolumePopup.SliderChange(Sender: TObject);
begin
  if FLocked then Exit;
  if FMuted then
  begin
    { moving the slider ends the mute }
    FMuted := False;
    if Assigned(FOnMute) then FOnMute(Self);
  end;
  UpdateTexts;
  if Assigned(FOnVolume) then FOnVolume(Self, FSlider.Position);
end;

procedure TVolumePopup.MuteClick(Sender: TObject);
begin
  if FLocked then Exit;
  FMuted := not FMuted;
  UpdateTexts;
  if Assigned(FOnMute) then FOnMute(Self);
end;

procedure TVolumePopup.PopupKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    CloseTree;
  end;
end;

procedure TVolumePopup.ShowNear(C: TControl);
var
  P: TPoint;
  W, H: Integer;
begin
  W := S(306);
  H := S(78);
  P := C.ClientToScreen(Point(C.Width - W, -H - S(6)));
  ShowAt(P.X, P.Y, W, H, -1);
  if FSlider.CanFocus then FSlider.SetFocus;
end;

end.
