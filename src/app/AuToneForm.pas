unit AuToneForm;

{ ==============================================================================
  AulumicNS - AuToneForm
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The tone control window: five bands (bass, low mid, mid, high mid,
  treble), each with a selectable frequency and a vertical slider
  (-10 .. +10 dB in 0.1 dB steps); a "semi Baxandall" tone control with
  three bands between the two shelves. Changes apply at
  once (OnChange); Enabled off, or all bands at 0 dB, keeps the playback
  bit-perfect. Above the bands: the curve of all bands together
  (TAuToneCurve), from the coefficients the engine uses, and a line that
  says how much the automatic headroom lowered the level (SetHeadroom).
  The values are a TToneState (ALAudioTypes; DirectMode = disabled, gains
  in tenths of a dB).

  Slider keys: Up / Down 0.5 dB (Ctrl 0.1 dB), Page Up / Down 2 dB,
  Home or a double click = 0 dB; the mouse wheel moves 0.5 dB. The steps
  and a mouse drag land on the 0.5 dB grid (Ctrl: 0.1 dB).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, Dialogs, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuMenus, AuForms, AuExtra, AuDialogs, ALAudioTypes, uToneControl, uTonePresets;

const
  ToneMaxDb = 100;                        // tenths: +-10.0 dB
  { the frequencies each band offers (as TONE_..._HZ_OPTIONS in uAppStrings).
    The three middle bands share out the range of the one Mid band of before,
    so they never cross; only bass and low mid meet (250 / 220 Hz). }
  ToneBandHz: array[0..TONE_BANDS - 1, 0..4] of Integer = (
    (80, 120, 150, 200, 250),
    (220, 300, 400, 500, 700),
    (800, 1000, 1500, 2000, 2500),
    (3000, 4000, 5000, 6000, 8000),
    (4000, 6000, 8000, 10000, 12000));
  { the row of the default frequency of each band (VAL_DEF_...HZ) }
  ToneBandDefRow: array[0..TONE_BANDS - 1] of Integer = (2, 2, 1, 1, 1);

type
  { TAuToneSlider - vertical slider, value in tenths of a dB }

  TAuToneSlider = class(TAuControl)
  private
    FValue: Integer;
    FDragging: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetValue(V: Integer);
    function TrackTop: Single;
    function TrackBottom: Single;
    function ValueAtY(Y: Integer): Integer;
    function YOf(V: Integer): Single;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function GesturePan: Integer; override;   // a touch drag moves the knob
  public
    constructor Create(AOwner: TComponent); override;
    property Value: Integer read FValue write SetValue;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuToneCurve - what the three bands do together: gain over frequency
    (20 Hz .. 20 kHz, -12 .. +12 dB), computed from the filters the play
    thread runs at the sample rate of the stream (ToneResponseDB). Greyed
    when the tone control is off: the curve of the settings, not in effect. }

  TAuToneCurve = class(TAuControl)
  private
    FCurve: TToneCurve;
    FLive: Boolean;
    function PlotLeft: Single;
    function PlotRight: Single;
    function PlotTop: Single;
    function PlotBottom: Single;
    function XOfHz(Hz: Double): Single;
    function YOfDb(Db: Double): Single;
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetCurve(const C: TToneState; ALive: Boolean);
    procedure SetRate(ARate: Integer);
    property Curve: TToneCurve read FCurve;
  end;

  { TAuToneForm }

  TAuToneForm = class(TAuForm)
  private
    FEnable: TAuSwitch;
    FCurve: TAuToneCurve;
    FSliders: array[0..TONE_BANDS - 1] of TAuToneSlider;
    FFreqs: array[0..TONE_BANDS - 1] of TAuCombo;
    FWidths: array[0..TONE_BANDS - 1] of TAuDropButton;   // the three middle bands; nil for the shelves
    FWidthRow: array[0..TONE_BANDS - 1] of Integer;       // the row of WidthNames each shows
    FWidthMenu: TAuMenu;
    FValues: array[0..TONE_BANDS - 1] of TAuLabel;
    FHeadNote: TAuLabel;         // what the automatic headroom takes off now
    FHeadTenths: Integer;
    FPreset: TAuDropButton;      // the preset in use; its menu chooses, saves, renames, deletes
    FPresetMenu: TAuMenu;
    FPresets: TTonePresets;
    FOnPresetsChange: TNotifyEvent;
    FUpdating: Boolean;
    FDsd: Boolean;               // DSD goes out as DSD: nothing here applies
    FOnChange: TNotifyEvent;
    procedure Changed(Sender: TObject);
    procedure FreqChanged(Sender: TObject);
    procedure SetFlat;
    procedure SetWidthRow(B, ARow: Integer);
    procedure WidthClick(Sender: TObject);
    procedure WidthPick(Sender: TObject);
    procedure PresetClick(Sender: TObject);
    procedure PresetPick(Sender: TObject);
    procedure PresetSave(Sender: TObject);
    procedure PresetRename(Sender: TObject);
    procedure PresetDelete(Sender: TObject);
    procedure PresetsChanged;
    function AskPresetName(const ATitle: string; var AName: string; ARenamed: Integer): Boolean;
    procedure UpdateLabels;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateTone(AOwner: TComponent);
    destructor Destroy; override;
    procedure SetValues(const C: TToneState);
    { the saved presets (a copy each way); OnPresetsChange after the list was
      changed in the window }
    procedure SetPresets(const L: TTonePresets);
    function Presets: TTonePresets;
    { what the preset button shows for the bands as they are: the name of the
      preset they match, "Flat" with all bands at 0 dB, else "Custom" }
    function PresetText: string;
    function Values: TToneState;
    { a DSD stream sent as DSD (DoP / native): the tone control cannot apply.
      The title says so, the switch, the sliders
      and the frequencies are disabled; the settings stay as they are for PCM }
    procedure SetDsdNote(Dsd: Boolean);
    { the sample rate the stream goes out at: the curve is drawn for it }
    procedure SetCurveRate(ARate: Integer);
    { what the automatic headroom takes off at the moment, in dB (0 or
      negative): shown under the curve, nothing at 0 }
    procedure SetHeadroom(ADb: Double);
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnPresetsChange: TNotifyEvent read FOnPresetsChange write FOnPresetsChange;
  end;

function DbText(Tenths: Integer): string;
function FreqText(Hz: Integer): string;

implementation

function FreqText(Hz: Integer): string;
begin
  if Hz >= 1000 then
  begin
    if Hz mod 1000 = 0 then Result := IntToStr(Hz div 1000) + ' kHz'
    else Result := FormatFloat('0.#', Hz / 1000) + ' kHz';
  end
  else Result := IntToStr(Hz) + ' Hz';
end;

function DbText(Tenths: Integer): string;
begin
  if Tenths > 0 then Result := '+' else Result := '';
  Result := Result + FormatFloat('0.0', Tenths / 10) + ' dB';
end;

{ ---- TAuToneSlider ---- }

constructor TAuToneSlider.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FWantKeys := True;
  Cursor := crHandPoint;
end;

procedure TAuToneSlider.SetValue(V: Integer);
begin
  V := EnsureRange(V, -ToneMaxDb, ToneMaxDb);
  if V = FValue then Exit;
  FValue := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TAuToneSlider.TrackTop: Single;
begin
  Result := S(14);
end;

function TAuToneSlider.TrackBottom: Single;
begin
  Result := Height - S(14);
end;

function TAuToneSlider.YOf(V: Integer): Single;
begin
  Result := TrackTop + (ToneMaxDb - V) / (2 * ToneMaxDb) * (TrackBottom - TrackTop);
end;

function TAuToneSlider.ValueAtY(Y: Integer): Integer;
begin
  Result := Round(ToneMaxDb - (Y - TrackTop) / Max(1, TrackBottom - TrackTop) * 2 * ToneMaxDb);
end;

{ Steps land on the 0.5 dB grid (Value + Step, then rounded to it), so the
  keys and the wheel always reach 0 dB; Ctrl keeps the 0.1 dB steps }
function OnGrid(Tenths: Integer): Integer;
begin
  Result := Round(Tenths / 5) * 5;
end;

{ a value from the mouse: on the 0.5 dB grid (Ctrl: 0.1 dB), and 0 dB a
  little wider than the others (within 0.4 dB), so a drag finds it easily }
function MouseValue(Raw: Integer; Shift: TShiftState): Integer;
begin
  if ssCtrl in Shift then Exit(Raw);
  if Abs(Raw) < 4 then Result := 0 else Result := OnGrid(Raw);
end;

procedure TAuToneSlider.DoPaint(G: TGfx);
var
  CX, Y0, YV, T, B: Single;
  Fill, Track, Thumb: TARGB;
  I: Integer;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  CX := Width / 2;
  T := TrackTop;
  B := TrackBottom;
  Y0 := YOf(0);
  YV := YOf(FValue);
  if Enabled then
  begin
    Track := Blend(EffBack, clText, 0.16);
    Fill := clAccent;
    Thumb := clAccent;
  end
  else
  begin
    Track := Blend(EffBack, clText, 0.08);
    Fill := Blend(EffBack, clText, 0.25);
    Thumb := Blend(EffBack, clText, 0.3);
  end;
  { scale: a tick every 2 dB, longer at 0 dB }
  for I := -5 to 5 do
    if I = 0 then G.FillRect(CX - S(16), YOf(0) - SF(0.5), S(32), SF(1), Blend(EffBack, clText, 0.45))
    else G.FillRect(CX - S(10), YOf(I * 20) - SF(0.5), S(6), SF(1), Blend(EffBack, clText, 0.22));
  G.FillRound(CX - S(3), T, S(6), B - T, S(3), Track);
  if YV < Y0 then G.FillRound(CX - S(3), YV, S(6), Y0 - YV, S(3), Fill)
  else if YV > Y0 then G.FillRound(CX - S(3), Y0, S(6), YV - Y0, S(3), Fill);
  G.FillCircle(CX, YV, S(10), Thumb);
  G.FillCircle(CX, YV, S(4), clOnAccent);
  if ShowFocus then G.StrokeRound(CX - S(16), YV - S(16), S(32), S(32), S(16), SF(1.6), clAccent);
end;

procedure TAuToneSlider.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  if CanFocus then SetFocus;
  FDragging := True;
  Value := MouseValue(ValueAtY(Y), Shift);
end;

procedure TAuToneSlider.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then Value := MouseValue(ValueAtY(Y), Shift);
end;

procedure TAuToneSlider.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
end;

procedure TAuToneSlider.DblClick;
begin
  inherited DblClick;
  FDragging := False;
  if Enabled then Value := 0;
end;

procedure TAuToneSlider.KeyDown(var Key: Word; Shift: TShiftState);
var
  Step: Integer;
begin
  inherited KeyDown(Key, Shift);
  if not Enabled then Exit;
  if ssCtrl in Shift then Step := 1 else Step := 5;
  case Key of
    VK_UP, VK_RIGHT: if Step = 1 then Value := FValue + 1 else Value := OnGrid(FValue + Step);
    VK_DOWN, VK_LEFT: if Step = 1 then Value := FValue - 1 else Value := OnGrid(FValue - Step);
    VK_PRIOR: Value := OnGrid(FValue + 20);
    VK_NEXT: Value := OnGrid(FValue - 20);
    VK_HOME, Ord('0'), VK_NUMPAD0: Value := 0;
  else
    Exit;
  end;
  Key := 0;
end;

function TAuToneSlider.GesturePan: Integer;
begin
  Result := GESTURE_PAN_NONE;
end;

function TAuToneSlider.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if not Enabled then Exit;
  if ssCtrl in Shift then
  begin
    if WheelDelta > 0 then Value := FValue + 1 else Value := FValue - 1;
  end
  else if WheelDelta > 0 then Value := OnGrid(FValue + 5)
  else Value := OnGrid(FValue - 5);
end;

{ ---- TAuToneCurve ---- }

const
  CurveLoHz = 20.0;
  CurveHiHz = 20000.0;
  CurveMaxDb = 12.0;
  CurveDefaultRate = 44100;

constructor TAuToneCurve.Create(AOwner: TComponent);
var
  B: Integer;
begin
  inherited Create(AOwner);
  FCurve.Rate := CurveDefaultRate;
  for B := 0 to TONE_BANDS - 1 do
    FCurve.Hz[B] := ToneBandHz[B, ToneBandDefRow[B]];
end;

procedure TAuToneCurve.SetCurve(const C: TToneState; ALive: Boolean);
var
  N: TToneCurve;
  B: Integer;
  Same: Boolean;
begin
  N := FCurve;
  N.Hz := ToneFreqsOf(C);
  N.Tenths := ToneGainsOf(C);
  N.Width := ToneWidthsOf(C);
  Same := ALive = FLive;
  for B := 0 to TONE_BANDS - 1 do
    Same := Same and (N.Hz[B] = FCurve.Hz[B]) and (N.Tenths[B] = FCurve.Tenths[B]) and (N.Width[B] = FCurve.Width[B]);
  if Same then Exit;
  FCurve := N;
  FLive := ALive;
  Invalidate;
end;

procedure TAuToneCurve.SetRate(ARate: Integer);
begin
  if ARate <= 0 then ARate := CurveDefaultRate;
  if ARate = FCurve.Rate then Exit;
  FCurve.Rate := ARate;
  Invalidate;
end;

function TAuToneCurve.PlotLeft: Single;
begin
  Result := S(34);
end;

function TAuToneCurve.PlotRight: Single;
begin
  Result := Width - S(10);
end;

function TAuToneCurve.PlotTop: Single;
begin
  Result := S(8);
end;

function TAuToneCurve.PlotBottom: Single;
begin
  Result := Height - S(20);
end;

function TAuToneCurve.XOfHz(Hz: Double): Single;
begin
  Result := PlotLeft + Ln(Hz / CurveLoHz) / Ln(CurveHiHz / CurveLoHz) * (PlotRight - PlotLeft);
end;

function TAuToneCurve.YOfDb(Db: Double): Single;
begin
  Db := EnsureRange(Db, -CurveMaxDb, CurveMaxDb);
  Result := PlotTop + (CurveMaxDb - Db) / (2 * CurveMaxDb) * (PlotBottom - PlotTop);
end;

procedure TAuToneCurve.DoPaint(G: TGfx);
const
  GridHz: array[0..2] of Integer = (100, 1000, 10000);
  GridHzText: array[0..2] of string = ('100 Hz', '1 kHz', '10 kHz');
  GridDb: array[0..2] of Integer = (10, 0, -10);
  GridDbText: array[0..2] of string = ('+10', '0 dB', '-10');
var
  Line, Fill: array of TGfxPoint;
  I, N, B: Integer;
  L, R, T, Bt, X, Y0: Single;
  Hz: Double;
  Ink, Faint, Mark: TARGB;
  F: TGfxFont;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  G.FillRound(0, 0, Width, Height, S(8), Blend(EffBack, clText, 0.045));
  L := PlotLeft;
  R := PlotRight;
  T := PlotTop;
  Bt := PlotBottom;
  Y0 := YOfDb(0);
  F := UIFont(10);
  Faint := Blend(EffBack, clText, 0.10);
  Mark := Blend(EffBack, clText, 0.50);
  if FLive then Ink := clAccent else Ink := Blend(EffBack, clText, 0.30);

  { the grid: a line per decade and at +10 / 0 / -10 dB, with their names }
  for I := 0 to 2 do
  begin
    X := XOfHz(GridHz[I]);
    G.FillRect(X - SF(0.5), T, SF(1), Bt - T, Faint);
    G.Text(GridHzText[I], X - S(30), Bt + S(2), S(60), S(16), F, Mark, 1, 1);
  end;
  for I := 0 to 2 do
  begin
    if GridDb[I] = 0 then G.FillRect(L, Y0 - SF(0.5), R - L, SF(1), Blend(EffBack, clText, 0.28))
    else G.FillRect(L, YOfDb(GridDb[I]) - SF(0.5), R - L, SF(1), Faint);
    G.Text(GridDbText[I], 0, YOfDb(GridDb[I]) - S(8), L - S(5), S(16), F, Mark, 2, 1);
  end;

  { the curve: a point every two pixels, and the area between it and 0 dB }
  N := Max(2, Round((R - L) / SF(2)) + 1);
  Line := nil;
  SetLength(Line, N);
  Fill := nil;
  SetLength(Fill, N + 2);
  for I := 0 to N - 1 do
  begin
    Hz := CurveLoHz * Power(CurveHiHz / CurveLoHz, I / (N - 1));
    Line[I] := GPt(L + (R - L) * I / (N - 1), YOfDb(ToneResponseDB(FCurve, Hz)));
    Fill[I] := Line[I];
  end;
  Fill[N] := GPt(R, Y0);
  Fill[N + 1] := GPt(L, Y0);
  G.FillPoly(Fill, WithAlpha(Ink, IfThen(FLive, 46, 26)));
  G.StrokePoly(Line, SF(1.8), Ink, False);

  { where each band that is set sits }
  for B := 0 to TONE_BANDS - 1 do
    if FCurve.Tenths[B] <> 0 then
      G.FillCircle(XOfHz(FCurve.Hz[B]), YOfDb(ToneResponseDB(FCurve, FCurve.Hz[B])), SF(3.2), Ink);
end;

{ ---- TAuToneForm ---- }

const
  BandNames: array[0..TONE_BANDS - 1] of string = ('Bass', 'Low mid', 'Mid', 'High mid', 'Treble');
  ColW = 104;                           // a band's column
  FW = 2 * 16 + TONE_BANDS * ColW;
  FH = 486;
  TopY = 14;                            // the preset and the switch
  CurveY = 60;
  CurveH = 104;
  NoteY = CurveY + CurveH + 6;          // the headroom line
  BandsY = NoteY + 26;                  // the band names; all below follows
  PresetW = 250;                        // the preset button
  SwitchW = 190;                        // the most the switch with its caption takes, at the right
  { the rows of the width drop-down, and the width each stands for }
  WidthNames: array[0..2] of string = ('Narrow', 'Normal', 'Wide');
  WidthOfRow: array[0..2] of Integer = (TONE_WIDTH_NARROW, TONE_WIDTH_NORMAL, TONE_WIDTH_WIDE);
  WidthDefRow = 1;

function FreqItems(Band: Integer): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, 5);
  for I := 0 to 4 do
    Result[I] := FreqText(ToneBandHz[Band, I]);
end;

constructor TAuToneForm.CreateTone(AOwner: TComponent);
var
  B, X: Integer;
  L: TAuLabel;
begin
  CreateAu(AOwner, 'Tone Control', FW, FH);
  HelpKeyword := 'Tone Control';
  IsDialog := True;
  { top line: the preset at the left, the switch at the right }
  FPreset := TAuDropButton.Create(Self);
  FPreset.Parent := Body;
  FPreset.SetBounds(S(20), S(TopY), S(PresetW), S(32));
  FPreset.Hint := 'Choose a preset, or save the bands as one.';
  FPreset.ShowHint := True;
  FPreset.OnClick := @PresetClick;
  FPresetMenu := TAuMenu.Create;
  FWidthMenu := TAuMenu.Create;
  FEnable := AddSwitch(Self, 'Disabled', '', FW - 20 - SwitchW, TopY, SwitchW, False);
  FEnable.SetBounds(S(FW - 20 - SwitchW), S(TopY), S(SwitchW), S(32));
  FEnable.OnChange := @Changed;
  FCurve := TAuToneCurve.Create(Self);
  FCurve.Parent := Body;
  FCurve.SetBounds(S(20), S(CurveY), S(FW - 40), S(CurveH));
  FHeadNote := AddLabel(Self, '', 20, NoteY, FW - 40, True);
  FHeadNote.HAlign := 1;
  for B := 0 to TONE_BANDS - 1 do
  begin
    X := 16 + B * ColW;
    L := AddLabel(Self, BandNames[B], X, BandsY, ColW, False);
    L.Bold := True;
    L.HAlign := 1;
    FFreqs[B] := AddCombo(Self, X + 4, BandsY + 26, ColW - 8, FreqItems(B), ToneBandDefRow[B]);
    FFreqs[B].OnChange := @FreqChanged;
    FWidthRow[B] := WidthDefRow;
    { the width of a middle band: its name alone, as a caption of the
      frequency above it (a shelf has none) }
    if (B > 0) and (B < TONE_BANDS - 1) then
    begin
      FWidths[B] := TAuDropButton.Create(Self);
      FWidths[B].Parent := Body;
      FWidths[B].Flat := True;
      FWidths[B].Dim := True;
      FWidths[B].TextSize := 12;
      FWidths[B].Tag := B;
      FWidths[B].Hint := 'How wide the band works around its frequency.';
      FWidths[B].ShowHint := True;
      FWidths[B].OnClick := @WidthClick;
      SetWidthRow(B, WidthDefRow);
    end;
    FSliders[B] := TAuToneSlider.Create(Self);
    FSliders[B].Parent := Body;
    FSliders[B].SetBounds(S(X + (ColW - 60) div 2), S(BandsY + 92), S(60), S(190));
    FSliders[B].OnChange := @Changed;
    FValues[B] := AddLabel(Self, '0.0 dB', X, BandsY + 286, ColW, False);
    FValues[B].HAlign := 1;
  end;
  FPreset.TabOrder := 0;
  FEnable.TabOrder := 1;
  for B := 0 to TONE_BANDS - 1 do
  begin
    FFreqs[B].TabOrder := 2 + 3 * B;
    if FWidths[B] <> nil then FWidths[B].TabOrder := 3 + 3 * B;
    FSliders[B].TabOrder := 4 + 3 * B;
  end;
  ActiveControl := FSliders[0];
  UpdateLabels;
end;

{ the width button of band B shows row ARow, as wide as its text and centred
  in the band's column }
procedure TAuToneForm.SetWidthRow(B, ARow: Integer);
var
  W: Integer;
begin
  ARow := EnsureRange(ARow, 0, High(WidthNames));
  FWidthRow[B] := ARow;
  if FWidths[B] = nil then Exit;
  FWidths[B].Caption := WidthNames[ARow];
  W := FWidths[B].PreferredWidth;
  FWidths[B].SetBounds(S(16 + B * ColW) + (S(ColW) - W) div 2, S(BandsY + 60), W, S(26));
end;

procedure TAuToneForm.WidthClick(Sender: TObject);
var
  B, I: Integer;
  It: TAuMenuItem;
begin
  B := TControl(Sender).Tag;
  if (B < 0) or (B >= TONE_BANDS) then Exit;
  FWidthMenu.Clear;
  for I := 0 to High(WidthNames) do
  begin
    It := FWidthMenu.Add(WidthNames[I], @WidthPick, icNone, '', B * 8 + I);
    It.Checked := I = FWidthRow[B];
  end;
  FWidthMenu.PopupBelow(FWidths[B]);
end;

procedure TAuToneForm.WidthPick(Sender: TObject);
var
  T: PtrInt;
begin
  T := TAuMenuItem(Sender).Tag;
  if (T < 0) or (T div 8 >= TONE_BANDS) or (T mod 8 > High(WidthNames)) then Exit;
  if FWidthRow[T div 8] = T mod 8 then Exit;
  SetWidthRow(T div 8, T mod 8);
  Changed(nil);
end;

procedure TAuToneForm.SetValues(const C: TToneState);
var
  Hz, Db, Wd: TToneInts;
  B, I, Row: Integer;
begin
  Hz := ToneFreqsOf(C);
  Db := ToneGainsOf(C);
  Wd := ToneWidthsOf(C);
  FUpdating := True;
  try
    FEnable.Checked := not C.DirectMode;
    for B := 0 to TONE_BANDS - 1 do
    begin
      FSliders[B].Value := Db[B];
      Row := ToneBandDefRow[B];
      for I := 0 to 4 do
        if ToneBandHz[B, I] = Hz[B] then Row := I;
      FFreqs[B].ItemIndex := Row;
      if FWidths[B] <> nil then
      begin
        Row := WidthDefRow;
        for I := 0 to High(WidthOfRow) do
          if WidthOfRow[I] = Wd[B] then Row := I;
        SetWidthRow(B, Row);
      end;
    end;
    { an overlapping pair (bass at or above the low mid): the low mid moves up }
    if ToneBandHz[0, FFreqs[0].ItemIndex] >= ToneBandHz[1, FFreqs[1].ItemIndex] then FFreqs[1].ItemIndex := 1;
  finally
    FUpdating := False;
  end;
  UpdateLabels;
end;

function TAuToneForm.Values: TToneState;
var
  Hz, Db, Wd: TToneInts;
  B: Integer;
begin
  Result := Default(TToneState);
  Result.DirectMode := not FEnable.Checked;
  for B := 0 to TONE_BANDS - 1 do
  begin
    Db[B] := FSliders[B].Value;
    Hz[B] := ToneBandHz[B, EnsureRange(FFreqs[B].ItemIndex, 0, 4)];
    Wd[B] := TONE_WIDTH_NORMAL;
    if FWidths[B] <> nil then Wd[B] := WidthOfRow[EnsureRange(FWidthRow[B], 0, High(WidthOfRow))];
  end;
  SetToneWidths(Result, Wd);
  SetToneGains(Result, Db);
  SetToneFreqs(Result, Hz);
end;

procedure TAuToneForm.UpdateLabels;
var
  B, W: Integer;
  On: Boolean;
begin
  On := FEnable.Checked and not FDsd;
  FEnable.Enabled := not FDsd;
  if FDsd then
  begin
    Caption := 'Tone Control (disabled for DSD)';
    FEnable.Caption := 'Disabled for DSD';
  end
  else if On then
  begin
    Caption := 'Tone Control';
    FEnable.Caption := 'Enabled';
  end
  else
  begin
    Caption := 'Tone Control';
    FEnable.Caption := 'Disabled';
  end;
  { the switch is as wide as its caption needs, so the caption stands next
    to it; its right edge stays }
  W := Min(S(SwitchW), Ceil(TextWidth(FEnable.Caption, UIFont(13))) + S(12 + 36 + 6 + 2));
  FEnable.SetBounds(S(FW - 20) - W, S(TopY), W, S(32));
  FEnable.Invalidate;
  for B := 0 to TONE_BANDS - 1 do
  begin
    FValues[B].Caption := DbText(FSliders[B].Value);
    FSliders[B].Enabled := On;
    FSliders[B].Invalidate;
    FFreqs[B].Enabled := On;
    if FWidths[B] <> nil then FWidths[B].Enabled := On;
    if On then FValues[B].TextRole := crText else FValues[B].TextRole := crTextFaint;
  end;
  FPreset.Enabled := On;
  FPreset.Caption := PresetText;
  FCurve.SetCurve(Values, On);
end;

procedure TAuToneForm.SetDsdNote(Dsd: Boolean);
begin
  if Dsd = FDsd then Exit;
  FDsd := Dsd;
  UpdateLabels;
end;

procedure TAuToneForm.SetHeadroom(ADb: Double);
var
  T: Integer;
begin
  T := Round(-ADb * 10);
  if T < 1 then T := 0;
  if T = FHeadTenths then Exit;
  FHeadTenths := T;
  if T = 0 then FHeadNote.Caption := ''
  else FHeadNote.Caption := 'Level lowered by ' + FormatFloat('0.0', T / 10) + ' dB to avoid clipping';
end;

procedure TAuToneForm.SetCurveRate(ARate: Integer);
begin
  FCurve.SetRate(ARate);
end;

procedure TAuToneForm.Changed(Sender: TObject);
begin
  UpdateLabels;
  if FUpdating then Exit;
  if Assigned(FOnChange) then FOnChange(Self);
end;

{ the bands stay in order. Only bass and low mid can meet (250 Hz bass and
  220 Hz low mid would overlap): the other of the two moves to the nearest
  choice that keeps the order. }
procedure TAuToneForm.FreqChanged(Sender: TObject);
var
  I: Integer;
begin
  if not FUpdating then
  begin
    FUpdating := True;
    try
      if (Sender = FFreqs[0]) and (ToneBandHz[0, FFreqs[0].ItemIndex] >= ToneBandHz[1, FFreqs[1].ItemIndex]) then
      begin
        for I := 0 to 4 do
          if ToneBandHz[1, I] > ToneBandHz[0, FFreqs[0].ItemIndex] then
          begin
            FFreqs[1].ItemIndex := I;
            Break;
          end;
      end
      else if (Sender = FFreqs[1]) and (ToneBandHz[1, FFreqs[1].ItemIndex] <= ToneBandHz[0, FFreqs[0].ItemIndex]) then
      begin
        for I := 4 downto 0 do
          if ToneBandHz[0, I] < ToneBandHz[1, FFreqs[1].ItemIndex] then
          begin
            FFreqs[0].ItemIndex := I;
            Break;
          end;
      end;
    finally
      FUpdating := False;
    end;
  end;
  Changed(Sender);
end;

{ all bands to 0 dB; frequencies and widths stay }
procedure TAuToneForm.SetFlat;
var
  B: Integer;
begin
  FUpdating := True;
  try
    for B := 0 to TONE_BANDS - 1 do FSliders[B].Value := 0;
  finally
    FUpdating := False;
  end;
  Changed(nil);
end;

{ ---- presets ---- }

const
  CAP_PRESET_SAVE   = 'Save as preset';
  CAP_PRESET_RENAME = 'Rename preset';
  CAP_PRESET_DELETE = 'Delete preset';
  MSG_PRESET_NAME   = 'Name of the preset:';
  MSG_PRESET_RESERVED = '"%s" is a name the Tone Control uses itself. Choose another name.';
  MSG_PRESET_REPLACE  = 'A preset named "%s" already exists. Do you want to replace it?';
  MSG_PRESET_TAKEN    = 'Another preset is already named "%s". Choose another name.';
  MSG_PRESET_FULL     = 'No more than %d presets can be kept. Delete one first.';
  MSG_PRESET_IS_FLAT  = 'All bands are at 0 dB: that is Flat, which is always in the list.';
  MSG_PRESET_DELETE   = 'Are you sure you want to delete the preset "%s"?';

destructor TAuToneForm.Destroy;
begin
  FreeAndNil(FPresetMenu);
  FreeAndNil(FWidthMenu);
  inherited Destroy;
end;

procedure TAuToneForm.SetPresets(const L: TTonePresets);
begin
  FPresets := Copy(L);
  if FPreset <> nil then FPreset.Caption := PresetText;
end;

function TAuToneForm.Presets: TTonePresets;
begin
  Result := Copy(FPresets);
end;

function TAuToneForm.PresetText: string;
var
  V: TToneState;
  I: Integer;
begin
  V := Values;
  I := MatchTonePreset(FPresets, V);
  if I >= 0 then Result := FPresets[I].Name
  else if not ToneAnyGain(V) then Result := TONE_PRESET_FLAT
  else Result := TONE_PRESET_CUSTOM;
end;

procedure TAuToneForm.PresetsChanged;
begin
  FPreset.Caption := PresetText;
  if Assigned(FOnPresetsChange) then FOnPresetsChange(Self);
end;

{ the menu: Flat, the saved presets (the one in use ticked), then what can be
  done with them. Rename and Delete work on the preset in use. }
procedure TAuToneForm.PresetClick(Sender: TObject);
var
  V: TToneState;
  I, Cur: Integer;
  It: TAuMenuItem;
begin
  V := Values;
  Cur := MatchTonePreset(FPresets, V);
  FPresetMenu.Clear;
  FPresetMenu.MinWidth := FPreset.Width;
  It := FPresetMenu.Add(TONE_PRESET_FLAT, @PresetPick, icNone, '', -1);
  It.Checked := not ToneAnyGain(V);
  for I := 0 to High(FPresets) do
  begin
    It := FPresetMenu.Add(FPresets[I].Name, @PresetPick, icNone, '', I);
    It.Checked := I = Cur;
  end;
  FPresetMenu.AddSeparator;
  FPresetMenu.Add(CAP_PRESET_SAVE + '...', @PresetSave);
  It := FPresetMenu.Add('Rename...', @PresetRename);
  It.Enabled := Cur >= 0;
  It := FPresetMenu.Add('Delete...', @PresetDelete);
  It.Enabled := Cur >= 0;
  FPresetMenu.PopupBelow(FPreset);
end;

{ a preset sets the gains and the frequencies of the bands; the switch stays }
procedure TAuToneForm.PresetPick(Sender: TObject);
var
  I: Integer;
  V: TToneState;
begin
  I := TAuMenuItem(Sender).Tag;
  if I < 0 then
  begin
    SetFlat;
    Exit;
  end;
  if I > High(FPresets) then Exit;
  V := Values;
  ApplyTonePreset(FPresets[I], V);
  SetValues(V);
  if Assigned(FOnChange) then FOnChange(Self);
end;

{ asks until the name can be used or the dialog is cancelled. ARenamed: the
  preset that gets the name (its own name is no clash), -1 for a new one -
  then a name that exists may be replaced after a question. }
function TAuToneForm.AskPresetName(const ATitle: string; var AName: string; ARenamed: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  repeat
    if not AuInput(ATitle, MSG_PRESET_NAME, AName) then Exit;
    AName := CleanPresetName(AName);
    if AName = '' then Exit;
    if not TonePresetNameAllowed(AName) then
    begin
      ALMessageDlg(ATitle, Format(MSG_PRESET_RESERVED, [AName]), mkInfo);
      Continue;
    end;
    I := FindTonePreset(FPresets, AName);
    if (I < 0) or (I = ARenamed) then Break;
    if ARenamed >= 0 then
    begin
      ALMessageDlg(ATitle, Format(MSG_PRESET_TAKEN, [FPresets[I].Name]), mkInfo);
      Continue;
    end;
    if ALMessageDlg(ATitle, Format(MSG_PRESET_REPLACE, [FPresets[I].Name]), [mbYes, mbNo], mbYes, mkQuestion) = mrYes then Break;
  until False;
  Result := True;
end;

procedure TAuToneForm.PresetSave(Sender: TObject);
var
  V: TToneState;
  AName: string;
  I: Integer;
begin
  V := Values;
  if not ToneAnyGain(V) then
  begin
    ALMessageDlg(CAP_PRESET_SAVE, MSG_PRESET_IS_FLAT, mkInfo);
    Exit;
  end;
  AName := '';
  I := MatchTonePreset(FPresets, V);
  if I >= 0 then AName := FPresets[I].Name;
  if not AskPresetName(CAP_PRESET_SAVE, AName, -1) then Exit;
  if PutTonePreset(FPresets, TonePresetOf(AName, V)) < 0 then
  begin
    ALMessageDlg(CAP_PRESET_SAVE, Format(MSG_PRESET_FULL, [TONE_PRESET_MAX]), mkInfo);
    Exit;
  end;
  PresetsChanged;
end;

procedure TAuToneForm.PresetRename(Sender: TObject);
var
  I: Integer;
  AName: string;
begin
  I := MatchTonePreset(FPresets, Values);
  if I < 0 then Exit;
  AName := FPresets[I].Name;
  if not AskPresetName(CAP_PRESET_RENAME, AName, I) then Exit;
  if RenameTonePreset(FPresets, I, AName) then PresetsChanged;
end;

procedure TAuToneForm.PresetDelete(Sender: TObject);
var
  I: Integer;
begin
  I := MatchTonePreset(FPresets, Values);
  if I < 0 then Exit;
  if ALMessageDlg(CAP_PRESET_DELETE, Format(MSG_PRESET_DELETE, [FPresets[I].Name]), [mbYes, mbNo], mbNo, mkQuestion) <> mrYes then Exit;
  DeleteTonePreset(FPresets, I);
  PresetsChanged;
end;

procedure TAuToneForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  { Escape closes (hides) the window }
  if (Key = VK_ESCAPE) and (Shift = []) then
  begin
    Key := 0;
    Close;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

end.
