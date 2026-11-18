unit AuTransport;

{ ==============================================================================
  AulumicNS - AuTransport
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The bottom of the main window (Aulumic layout):
  TTransportBar - position / seek bar with the times, the transport buttons
                  in the middle (shuffle, stop, previous, play / pause, next,
                  jump to now playing, repeat) and on the right the output
                  device, the tone control and the volume (with percent)
  TStatusStrip  - status line: background progress (a thin line on top),
                  the status text, the clickable ReplayGain scan notice and
                  the engine details
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuExtra;

type
  { TTransportBar }

  TTransportBar = class(TAuPanel)
  private
    FTimeW: Integer;
    procedure LayoutButtons;
  protected
    procedure Resize; override;
  public
    LblPos, LblTotal, LblVolPct: TAuLabel;
    Seek: TAuSlider;
    BtnShuffle, BtnStop, BtnPrev, BtnPlay, BtnNext, BtnJump, BtnRepeat: TAuIconButton;
    BtnDevice: TAuDropButton;
    BtnTone, BtnVolume: TAuIconButton;
    constructor Create(AOwner: TComponent); override;
    procedure DpiChanged; override;
    procedure SetPlaying(V: Boolean);
    procedure SetRepeatMode(M: Integer);
    procedure SetVolumeDisplay(Vol: Double; Muted, Locked: Boolean);
    procedure SetDeviceName(const AName: string);
  end;

  { TStatusStrip }

  TStatusStrip = class(TAuControl)
  private
    FStatus, FEngine, FRgText: string;
    FProgress: Single;            // < 0: no background task
    FRgRect: TRect;
    FRgHot: Boolean;
    FOnRgClick: TNotifyEvent;
    procedure SetStatus(const V: string);
    procedure SetEngine(const V: string);
    procedure SetRgText(const V: string);
    procedure SetProgress(V: Single);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    property StatusText: string read FStatus write SetStatus;
    property EngineText: string read FEngine write SetEngine;
    { "[ ReplayGain scanning... Click here to view ]" while a hidden scan runs }
    property RgText: string read FRgText write SetRgText;
    property Progress: Single read FProgress write SetProgress;
    property OnRgClick: TNotifyEvent read FOnRgClick write FOnRgClick;
  end;

const
  TransportHeight = 84;     // unscaled
  StatusHeight = 28;

implementation

{ ---- TTransportBar ---- }

constructor TTransportBar.Create(AOwner: TComponent);

  function Btn(AIcon: TAuIcon; const AHint: string; ASize: Integer = 18): TAuIconButton;
  begin
    Result := TAuIconButton.Create(Self);
    Result.Parent := Self;
    Result.Icon := AIcon;
    Result.IconSize := ASize;
    Result.Hint := AHint;
    Result.ShowHint := True;
    Result.SetBounds(0, 0, S(38), S(38));
  end;

  function Lbl(const ACaption: string; ASize: Single; AAlign: Integer): TAuLabel;
  begin
    Result := TAuLabel.Create(Self);
    Result.Parent := Self;
    Result.Caption := ACaption;
    Result.FontSize := ASize;
    Result.TextRole := crTextDim;
    Result.HAlign := AAlign;
    Result.FocusOnClick := False;
  end;

begin
  inherited Create(AOwner);
  BackRole := crSurface;
  Height := S(TransportHeight);
  FTimeW := 52;
  LblPos := Lbl('00:00', 12, 0);
  LblTotal := Lbl('00:00', 12, 2);
  Seek := TAuSlider.Create(Self);
  Seek.Parent := Self;
  Seek.GpuPaint := True;               // moves all the time while music plays
  Seek.SetRange(0, 1);
  Seek.Step := 5;
  Seek.BigStep := 30;
  Seek.AlwaysAccent := True;
  Seek.Hint := 'Position (Ctrl+Left / Ctrl+Right)';
  BtnShuffle := Btn(icShuffle, 'Shuffle (Ctrl+S)');
  BtnStop := Btn(icStopSolid, 'Stop', 17);
  BtnPrev := Btn(icPrev, 'Previous track', 18);
  BtnPlay := Btn(icPlay, 'Play / pause (Space)', 20);
  BtnPlay.Style := ibFilled;
  BtnPlay.SetBounds(0, 0, S(46), S(46));
  BtnNext := Btn(icNext, 'Next track', 18);
  BtnJump := Btn(icLocate, 'Jump to Now Playing (Ctrl+J)');
  BtnRepeat := Btn(icRepeat, 'Repeat (Ctrl+R)');
  BtnDevice := TAuDropButton.Create(Self);
  BtnDevice.Parent := Self;
  BtnDevice.Flat := True;
  BtnDevice.Icon := icHeadphones;
  BtnDevice.TextSize := 13;
  BtnDevice.Caption := 'Default device';
  BtnDevice.Hint := 'Output device';
  BtnDevice.ShowHint := True;
  BtnTone := Btn(icEqualizer, 'Tone Control (Ctrl+T)');
  BtnVolume := Btn(icVolume2, 'Volume (Ctrl+Up / Ctrl+Down, Ctrl+M mute)');
  LblVolPct := Lbl('100%', 10.5, 1);
  { tab order: transport first, then the right group, then the seek bar }
  BtnShuffle.TabOrder := 0;
  BtnStop.TabOrder := 1;
  BtnPrev.TabOrder := 2;
  BtnPlay.TabOrder := 3;
  BtnNext.TabOrder := 4;
  BtnJump.TabOrder := 5;
  BtnRepeat.TabOrder := 6;
  BtnDevice.TabOrder := 7;
  BtnTone.TabOrder := 8;
  BtnVolume.TabOrder := 9;
  Seek.TabOrder := 10;
end;

procedure TTransportBar.DpiChanged;
begin
  inherited DpiChanged;
  LayoutButtons;
end;

procedure TTransportBar.Resize;
begin
  inherited Resize;
  LayoutButtons;
end;

procedure TTransportBar.LayoutButtons;
var
  SeekH, RowTop, RowH, CX, X, W, BW, Gap, RightX: Integer;
begin
  if BtnPlay = nil then Exit;
  SeekH := S(26);
  LblPos.SetBounds(S(20), S(4), S(FTimeW), SeekH);
  LblTotal.SetBounds(Width - S(20) - S(FTimeW), S(4), S(FTimeW), SeekH);
  Seek.SetBounds(LblPos.Left + LblPos.Width + S(6), S(4), LblTotal.Left - S(6) - (LblPos.Left + LblPos.Width + S(6)), SeekH);
  RowTop := SeekH + S(6);
  RowH := Height - RowTop - S(4);
  { the transport buttons, centred }
  BW := S(38);
  Gap := S(6);
  W := 6 * BW + BtnPlay.Width + 6 * Gap;
  CX := Width div 2;
  X := CX - W div 2;
  BtnShuffle.SetBounds(X, RowTop + (RowH - BW) div 2, BW, BW); Inc(X, BW + Gap);
  BtnStop.SetBounds(X, RowTop + (RowH - BW) div 2, BW, BW); Inc(X, BW + Gap);
  BtnPrev.SetBounds(X, RowTop + (RowH - BW) div 2, BW, BW); Inc(X, BW + Gap);
  BtnPlay.SetBounds(X, RowTop + (RowH - BtnPlay.Height) div 2, BtnPlay.Width, BtnPlay.Height); Inc(X, BtnPlay.Width + Gap);
  BtnNext.SetBounds(X, RowTop + (RowH - BW) div 2, BW, BW); Inc(X, BW + Gap);
  BtnJump.SetBounds(X, RowTop + (RowH - BW) div 2, BW, BW); Inc(X, BW + Gap);
  BtnRepeat.SetBounds(X, RowTop + (RowH - BW) div 2, BW, BW);
  { right group: device, tone, volume (with the percent below) }
  RightX := Width - S(20);
  BtnVolume.SetBounds(RightX - BW, RowTop + (RowH - BW) div 2 - S(7), BW, BW);
  LblVolPct.SetBounds(BtnVolume.Left - S(8), BtnVolume.Top + BW - S(4), BW + S(16), S(16));
  BtnTone.SetBounds(BtnVolume.Left - BW - S(10), RowTop + (RowH - BW) div 2, BW, BW);
  W := Math.Min(BtnDevice.PreferredWidth, S(260));
  { never into the transport buttons }
  W := Math.Min(W, BtnTone.Left - S(10) - (BtnRepeat.Left + BW + S(24)));
  BtnDevice.Visible := W > S(60);
  if BtnDevice.Visible then
    BtnDevice.SetBounds(BtnTone.Left - S(10) - W, RowTop + (RowH - S(34)) div 2, W, S(34));
end;

procedure TTransportBar.SetPlaying(V: Boolean);
begin
  if V then
  begin
    BtnPlay.Icon := icPause;
    BtnPlay.Hint := 'Pause (Space)';
  end
  else
  begin
    BtnPlay.Icon := icPlay;
    BtnPlay.Hint := 'Play (Space)';
  end;
end;

procedure TTransportBar.SetRepeatMode(M: Integer);
begin
  case M of
    1: begin BtnRepeat.Icon := icRepeat; BtnRepeat.Active := True; BtnRepeat.Hint := 'Repeat: all (Ctrl+R)'; end;
    2: begin BtnRepeat.Icon := icRepeatOne; BtnRepeat.Active := True; BtnRepeat.Hint := 'Repeat: one track (Ctrl+R)'; end;
  else
    begin BtnRepeat.Icon := icRepeat; BtnRepeat.Active := False; BtnRepeat.Hint := 'Repeat: off (Ctrl+R)'; end;
  end;
end;

procedure TTransportBar.SetVolumeDisplay(Vol: Double; Muted, Locked: Boolean);
begin
  if Muted then BtnVolume.Icon := icMute
  else if Vol <= 0.001 then BtnVolume.Icon := icVolume0
  else if Vol < 0.5 then BtnVolume.Icon := icVolume1
  else BtnVolume.Icon := icVolume2;
  if Locked then LblVolPct.Caption := 'Fixed'
  else if Muted then LblVolPct.Caption := 'Mute'
  else LblVolPct.Caption := IntToStr(Round(Vol * 100)) + '%';
end;

procedure TTransportBar.SetDeviceName(const AName: string);
begin
  BtnDevice.Caption := AName;
  LayoutButtons;
end;

{ ---- TStatusStrip ---- }

constructor TStatusStrip.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crSurface;
  FocusOnClick := False;
  FProgress := -1;
  Height := S(StatusHeight);
end;

procedure TStatusStrip.SetStatus(const V: string);
begin
  if V = FStatus then Exit;
  FStatus := V;
  Invalidate;
end;

procedure TStatusStrip.SetEngine(const V: string);
begin
  if V = FEngine then Exit;
  FEngine := V;
  Invalidate;
end;

procedure TStatusStrip.SetRgText(const V: string);
begin
  if V = FRgText then Exit;
  FRgText := V;
  Invalidate;
end;

procedure TStatusStrip.SetProgress(V: Single);
begin
  if V = FProgress then Exit;
  FProgress := V;
  Invalidate;
end;

procedure TStatusStrip.DoPaint(G: TGfx);
var
  F: TGfxFont;
  X, W: Integer;
  Fg: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  G.FillRect(0, 0, Width, 1, clBorder);
  if FProgress >= 0 then
    G.FillRect(S(10), 0, Math.Max(0, (Width - S(20)) * Math.Min(1, FProgress)), SF(2), clAccent);
  F := UIFont(12);
  X := S(12);
  if FStatus <> '' then
  begin
    W := Ceil(TextWidth(FStatus, F));
    G.Text(FStatus, X, 0, Math.Min(W + S(4), Width - X), Height, F, clTextDim, 0, 1);
    Inc(X, W + S(16));
  end;
  FRgRect := Rect(0, 0, 0, 0);
  if FRgText <> '' then
  begin
    W := Ceil(TextWidth(FRgText, F));
    FRgRect := Rect(X, 0, X + W, Height);
    if FRgHot then Fg := clText else Fg := clAccentText;
    G.Text(FRgText, X, 0, W + S(4), Height, F, Fg, 0, 1);
    Inc(X, W + S(16));
  end;
  if (FEngine <> '') and (X < Width - S(20)) then
    G.Text(FEngine, X, 0, Width - X - S(12), Height, F, clTextFaint, 0, 1);
end;

procedure TStatusStrip.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  H: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  H := PtInRect(FRgRect, Point(X, Y));
  if H <> FRgHot then
  begin
    FRgHot := H;
    if H then Cursor := crHandPoint else Cursor := crDefault;
    Invalidate;
  end;
end;

procedure TStatusStrip.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and PtInRect(FRgRect, Point(X, Y)) and Assigned(FOnRgClick) then FOnRgClick(Self);
end;

procedure TStatusStrip.MouseLeave;
begin
  inherited MouseLeave;
  if FRgHot then
  begin
    FRgHot := False;
    Cursor := crDefault;
    Invalidate;
  end;
end;

end.
