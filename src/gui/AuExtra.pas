unit AuExtra;

{ ==============================================================================
  AulumicNS - AuExtra
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Controls of the main window:
  TAuDropButton - a button that looks like a combo box (or a flat text
                  button with a chevron) and opens a menu or popup of the
                  owner (playlist selector, output device, view options)
  TAuPeakMeter  - stereo peak meter whose background can be painted by the
                  owner (the banner gradient), so it repaints on its own
                  without the banner. A thin frame, fine
                  blocks, a colour per block from green over amber to red,
                  60 dB scale, a quick rise and a slow fall, a red top block
                  after clipping
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls;

type
  TAuPaintBackEvent = procedure(Sender: TObject; G: TGfx) of object;

var
  { the debug build's --ui-bench: block height factor, paints counted }
  MeterBlockScale: Single = 1;
  MeterPaints: Integer = 0;
  MeterPaintTicks: Int64 = 0;      // QueryPerformanceCounter ticks inside DoPaint

type

  { TAuDropButton }

  TAuDropButton = class(TAuControl)
  private
    FCaption: string;
    FIcon, FTextIcon: TAuIcon;
    FFlat, FPressed, FDropped, FChevron, FDim: Boolean;
    FTextSize: Single;
    procedure SetCaption(const V: string);
    procedure SetIcon(V: TAuIcon);
    procedure SetDropped(V: Boolean);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    function PreferredWidth: Integer;
    property Caption: string read FCaption write SetCaption;
    { icon before the caption }
    property Icon: TAuIcon read FIcon write SetIcon;
    { small icon drawn after the caption (e.g. a funnel for auto-playlists) }
    property TextIcon: TAuIcon read FTextIcon write FTextIcon;
    { no input box: a text button }
    property Flat: Boolean read FFlat write FFlat;
    property Chevron: Boolean read FChevron write FChevron;
    { the caption in the dimmer text colour (a secondary choice under another control) }
    property Dim: Boolean read FDim write FDim;
    property Dropped: Boolean read FDropped write SetDropped;
    property TextSize: Single read FTextSize write FTextSize;
  end;

  { TAuPeakMeter }

  TAuPeakMeter = class(TAuControl)
  private
    FLevel: array[0..1] of Single;      // shown, 0 .. 1 of the 60 dB scale
    FClipUntil: array[0..1] of QWord;   // the red top block shows until then
    FActive: Boolean;
    FOnPaintBack: TAuPaintBackEvent;
    { what the last paint showed: a new level repaints only when it lights
      another number of blocks (CheckChanged) }
    FShownN: Integer;                   // blocks per bar (0 = not painted)
    FShownLit: array[0..1] of Integer;
    FShownClip: array[0..1] of Boolean;
    { all blocks of a bar, lit, in their colours: a paint copies the lit part }
    FColumn: TGfxBitmap;
    FColKey: string;
    procedure SetActive(V: Boolean);
    procedure Geometry(out N, BlockH, Gap, BarW, BarGap: Integer);
    procedure CheckChanged;
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { new peaks (linear, 0 .. 1), once per UI read (50 ms): the rise
      (35 % of the way) and fall (at most 7 %) on the 60 dB scale }
    procedure SetLevels(L, R: Single);
    { the engine saw a clipped sample: the top block turns red for 1.5 s }
    procedure SetClip(L, R: Boolean);
    procedure Reset;
    property Active: Boolean read FActive write SetActive;
    property OnPaintBack: TAuPaintBackEvent read FOnPaintBack write FOnPaintBack;
  end;

implementation

{ ---- TAuDropButton ---- }

constructor TAuDropButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(200);
  Height := S(32);
  TabStop := True;
  FChevron := True;
  FTextSize := 13;
  FIcon := icNone;
  FTextIcon := icNone;
end;

procedure TAuDropButton.SetCaption(const V: string);
begin
  if V = FCaption then Exit;
  FCaption := V;
  Invalidate;
end;

procedure TAuDropButton.SetIcon(V: TAuIcon);
begin
  if V = FIcon then Exit;
  FIcon := V;
  Invalidate;
end;

procedure TAuDropButton.SetDropped(V: Boolean);
begin
  if V = FDropped then Exit;
  FDropped := V;
  Invalidate;
end;

function TAuDropButton.PreferredWidth: Integer;
begin
  Result := Ceil(TextWidth(FCaption, UIFont(FTextSize))) + S(20);
  if FIcon <> icNone then Inc(Result, S(24));
  if FChevron then Inc(Result, S(22));
  if FTextIcon <> icNone then Inc(Result, S(20));
end;

procedure TAuDropButton.DoPaint(G: TGfx);
var
  Bg, Bd, Fg: TARGB;
  X, TW, Right: Single;
  F: TGfxFont;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if not Enabled then Fg := clTextFaint
  else if FDim then Fg := clTextDim
  else Fg := clText;
  if FFlat then
  begin
    if FPressed or FDropped then G.FillRound(0, 0, Width, Height, S(7), clPressed)
    else if HoverT > 0 then G.FillRound(0, 0, Width, Height, S(7), HoverMix(EffBack, clHover));
    if ShowFocus then G.StrokeRound(0, 0, Width, Height, S(7), FocusLineW, clAccent);
  end
  else
  begin
    Bg := clInput;
    if FDropped then Bg := Blend(clInput, clText, 0.04) else Bg := Blend(clInput, clText, 0.04 * HoverT);
    G.FillRound(0, 0, Width, Height, S(7), Bg);
    if FDropped or ShowFocus then Bd := clAccent
    else Bd := HoverMix(clInputLine, clInputLineHi);
    if FDropped or ShowFocus then G.StrokeRound(0, 0, Width, Height, S(7), FocusLineW, Bd)
    else G.StrokeRound(0, 0, Width, Height, S(7), 1, Bd);
  end;
  X := S(10);
  if FIcon <> icNone then
  begin
    DrawIcon(G, FIcon, X + S(8), Height / 2, S(16), clTextDim);
    X := X + S(24);
  end;
  Right := Width - S(8);
  if FChevron then Right := Right - S(20);
  F := UIFont(FTextSize);
  TW := Math.Min(TextWidth(FCaption, F), Right - X - IfThen(FTextIcon <> icNone, S(20), 0));
  G.Text(FCaption, X, 0, Math.Max(0, TW + S(2)), Height, F, Fg, 0, 1);
  if FTextIcon <> icNone then DrawIcon(G, FTextIcon, X + TW + S(12), Height / 2, S(13), clTextDim);
  if FChevron then
  begin
    if FDropped then DrawIcon(G, icChevronUp, Width - S(18), Height / 2, S(13), clTextDim)
    else DrawIcon(G, icChevronDown, Width - S(18), Height / 2, S(13), clTextDim);
  end;
end;

procedure TAuDropButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

procedure TAuDropButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FPressed := False;
  Invalidate;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TAuDropButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (Key in [VK_SPACE, VK_RETURN]) or ((Key = VK_DOWN) and (ssAlt in Shift)) or (Key = VK_F4) then
  begin
    Key := 0;
    Click;
  end;
end;

procedure TAuDropButton.Click;
begin
  if not Enabled then Exit;
  inherited Click;
end;

{ ---- TAuPeakMeter ---- }

constructor TAuPeakMeter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FGpuPaint := True;                  // 20 paints a second while music plays
  Width := S(32);
  Height := S(120);
  FocusOnClick := False;
end;

destructor TAuPeakMeter.Destroy;
begin
  if FColumn <> nil then DisposeBitmap(FColumn);
  inherited Destroy;
end;

procedure TAuPeakMeter.SetActive(V: Boolean);
begin
  if V = FActive then Exit;
  FActive := V;
  if not V then Reset;
  Invalidate;
end;

{ the blocks per bar and the sizes (as DoPaint draws them) }
procedure TAuPeakMeter.Geometry(out N, BlockH, Gap, BarW, BarGap: Integer);
begin
  BlockH := Math.Max(3, Round(SF(1.8 * MeterBlockScale)));
  Gap := Math.Max(1, Round(SF(0.9)));
  N := (Height - 4 + Gap) div (BlockH + Gap);
  BarGap := Math.Max(2, Round(SF(2.7)));
  BarW := (Width - 4 - BarGap) div 2;
end;

{ repaint only when the picture changes - another number of
  lit blocks or the clip block (a repaint on every 50 ms read costs about
  12 % of a slow core at 4K) }
procedure TAuPeakMeter.CheckChanged;
var
  N, BlockH, Gap, BarW, BarGap, I: Integer;
  Now: QWord;
begin
  if not FActive then Exit;
  UseDpiOf(Self);
  Geometry(N, BlockH, Gap, BarW, BarGap);
  if N <> FShownN then
  begin
    Invalidate;
    Exit;
  end;
  Now := GetTickCount64;
  for I := 0 to 1 do
    if (Round(FLevel[I] * N) <> FShownLit[I]) or ((Now < FClipUntil[I]) <> FShownClip[I]) then
    begin
      Invalidate;
      Exit;
    end;
end;

procedure TAuPeakMeter.Reset;
var
  I: Integer;
begin
  for I := 0 to 1 do
  begin
    FLevel[I] := 0;
    FClipUntil[I] := 0;
  end;
  Invalidate;
end;

{ a linear peak on the meter scale: -60 .. 0 dBFS (log10 / 3 + 1) }
function MeterPos(V: Single): Single;
begin
  if V <= 0.0001 then Exit(0);
  Result := EnsureRange(Log10(V) / 3 + 1, 0, 1);
end;

procedure TAuPeakMeter.SetLevels(L, R: Single);
var
  V: array[0..1] of Single;
  I: Integer;
begin
  V[0] := MeterPos(L);
  V[1] := MeterPos(R);
  for I := 0 to 1 do
  begin
    { up 35 % of the way, down at most 7 % (never
      below the new value); the floor and the ceiling }
    if V[I] >= FLevel[I] then FLevel[I] := FLevel[I] + (V[I] - FLevel[I]) * 0.35
    else FLevel[I] := Math.Max(V[I], FLevel[I] * 0.93);
    if FLevel[I] < 0.01 then FLevel[I] := 0
    else if FLevel[I] > 1 then FLevel[I] := 1;
  end;
  CheckChanged;
end;

procedure TAuPeakMeter.SetClip(L, R: Boolean);
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if L then FClipUntil[0] := Now + 1500;
  if R then FClipUntil[1] := Now + 1500;
  CheckChanged;
end;

{ the meter's colours (low / mid / high) and its gradient
  table: the lower half low, a blend to mid up to 65 %,
  mid to 75 %, a blend to high up to 85 %, high above }
function MeterColor(Pct: Single): TARGB;
var
  Lo, Mid, Hi: TARGB;
begin
  if ThemeIsDark then
  begin
    Lo := $FF406E40;               // forest green  (64, 110, 64)
    Mid := $FFA0965F;              // amber         (160, 150, 95)
    Hi := $FFFF4040;               // bright red    (255, 64, 64)
  end
  else
  begin
    Lo := $FF32A032;               // (50, 160, 50)
    Mid := $FFD28C1E;              // (210, 140, 30)
    Hi := $FFDC3C28;               // (220, 60, 40)
  end;
  if Pct < 0.50 then Result := Lo
  else if Pct < 0.65 then Result := Blend(Lo, Mid, (Pct - 0.50) / 0.15)
  else if Pct < 0.75 then Result := Mid
  else if Pct < 0.85 then Result := Blend(Mid, Hi, (Pct - 0.75) / 0.10)
  else Result := Hi;
end;

{ A 1 px frame;
  inside it the two bars, only their lit blocks. The blocks are fine at
  every scaling (about 1.8 +
  0.9 logical px, at least 3 + 1 px), all of the same whole-pixel height,
  stacked from the bottom; each takes its colour from its height
  (MeterColor). After a clipped sample the top block is red. }
procedure TAuPeakMeter.DoPaint(G: TGfx);
var
  I, K, N, Lit, BlockH, Gap, Pitch, BarGap, BarW, IH, Bottom, ColH, H, X: Integer;
  Frame: TARGB;
  Now: QWord;
  Key: string;
  CX: TGfx;
  Clip: Boolean;
  Q0, Q1: Int64;
begin
  QueryPerformanceCounter(Q0);
  try
  if Assigned(FOnPaintBack) then FOnPaintBack(Self, G)
  else G.FillRect(0, 0, Width, Height, EffBack);
  FShownN := 0;
  if not FActive then Exit;
  Inc(MeterPaints);
  { the frame }
  if ThemeIsDark then Frame := WithAlpha(clText, 46) else Frame := WithAlpha(clText, 60);
  G.FillRect(0, 0, Width, 1, Frame);
  G.FillRect(0, Height - 1, Width, 1, Frame);
  G.FillRect(0, 1, 1, Height - 2, Frame);
  G.FillRect(Width - 1, 1, 1, Height - 2, Frame);
  { inside: 1 px of air around the bars }
  Geometry(N, BlockH, Gap, BarW, BarGap);
  if (N < 2) or (BarW < 1) then Exit;
  Pitch := BlockH + Gap;
  IH := Height - 4;
  Bottom := 2 + IH;
  ColH := N * Pitch - Gap;
  { the column: block K (from the bottom) at ColH - K * Pitch - BlockH }
  Key := Format('%d/%d/%d/%d/%s', [BarW, N, BlockH, Gap, BoolToStr(ThemeIsDark, 'd', 'l')]);
  if (FColumn = nil) or (Key <> FColKey) then
  begin
    if FColumn <> nil then DisposeBitmap(FColumn);
    FColKey := Key;
    CX := TGfx.CreateBitmap(BarW, ColH);
    try
      for K := 0 to N - 1 do
        CX.FillRect(0, ColH - K * Pitch - BlockH, BarW, BlockH, MeterColor(K / (N - 1)));
      FColumn := CX.ToBitmap;
    finally
      CX.Free;
    end;
  end;
  Now := GetTickCount64;
  for I := 0 to 1 do
  begin
    X := 2 + I * (BarW + BarGap);
    Lit := Round(FLevel[I] * N);
    if (Lit > 0) and (FColumn <> nil) then
    begin
      H := Lit * Pitch - Gap;          // the lit blocks: the lower part of the column
      G.DrawBitmapPart(FColumn, X, Bottom - H, BarW, H, 0, ColH - H, BarW, H, True);
    end;
    Clip := Now < FClipUntil[I];
    if Clip then G.FillRect(X, Bottom - (N - 1) * Pitch - BlockH, BarW, BlockH, MeterColor(1));
    FShownLit[I] := Lit;
    FShownClip[I] := Clip;
  end;
  FShownN := N;
  finally
    QueryPerformanceCounter(Q1);
    Inc(MeterPaintTicks, Q1 - Q0);
  end;
end;

end.
