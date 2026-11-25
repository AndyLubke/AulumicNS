unit AuTheme;

{ ==============================================================================
  AulumicNS - AuTheme
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Colour palette (dark / light, six accents), DPI scaling, fonts and the
  theme-change broadcast. Controls never cache colours: they read the
  palette variables while painting, so a theme switch only needs a repaint.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Graphics, Forms, Controls, Registry, AuGfx;

type
  TAuThemeMode = (tmDark, tmLight, tmSystem);

  { colour roles - used by controls that store a colour so that a theme switch
    re-maps them automatically }
  TAuRole = (crInherit, crBg, crPanel, crSurface, crCard, crInput, crHover, crPressed,
    crBorder, crText, crTextDim, crTextFaint, crAccent, crSelection, crGood, crBad, crWarn);

var
  clBg: TARGB;          // content background
  clPanel: TARGB;       // navigation rail / side panels
  clSurface: TARGB;     // player bar
  clCard: TARGB;        // cards, popups, menus
  clInput: TARGB;       // edit boxes, combo boxes
  { the outline of an input (and under the pointer): stronger than clBorder, so
    an input stands out on a card as well as on the page }
  clInputLine: TARGB;
  clInputLineHi: TARGB;
  clHover: TARGB;
  clPressed: TARGB;
  clBorder: TARGB;
  clBorderHi: TARGB;
  clText: TARGB;
  clTextDim: TARGB;
  clTextFaint: TARGB;
  clAccent: TARGB;
  clAccentHi: TARGB;    // hover of accent fills
  clAccentLo: TARGB;    // pressed accent fill
  clAccentText: TARGB;  // accent coloured text / icons (readable on clBg)
  clOnAccent: TARGB;    // text drawn on an accent fill
  clSelection: TARGB;
  clSelectionDim: TARGB; // selection of an unfocused list
  clTextSelection: TARGB; // behind selected text in an input field
  clGood: TARGB;
  clBad: TARGB;
  clWarn: TARGB;
  clShadow: TARGB;
  clThumb: TARGB;       // scroll bar thumb
  clThumbHi: TARGB;

  ThemeMode: TAuThemeMode = tmDark;
  ThemeIsDark: Boolean = True;
  AccentIndex: Integer = 0;
  { True while the user navigates with the keyboard: focus rings are only
    drawn then (like :focus-visible in a browser) }
  KeyboardCues: Boolean = False;

const
  AccentCount = 6;
  { six hue families around the colour wheel, pastel in the
    dark theme, chosen to stay apart for colour blindness.
    Checked by simulating protanopia, deuteranopia and
    tritanopia (Machado 2009): the closest two stay >= 8 apart (CIEDE2000)
    - see AccentDark / AccentLight. }
  AccentNames: array[0..AccentCount - 1] of string = ('Blue', 'Mint', 'Yellow', 'Peach', 'Rose', 'Lilac');

var
  { DPI used by S() / SF() / UIFont(). Every window keeps its own DPI (its
    PixelsPerInch, per-monitor aware); controls switch CurDpi to the DPI of
    their window before they handle any message, so painting, layout and hit
    testing always use the scale of the monitor the window is on. }
  CurDpi: Integer = 96;
  { > 0: every window uses this DPI instead of the DPI of its monitor
    (screenshot mode of the debug build renders any scaling on any screen) }
  ForcedDpi: Integer = 0;

function S(V: Integer): Integer;
function SF(V: Single): Single;
{ the line width of a focused input's accent ring: whole pixels, so it stays
  crisp (1 at 100 / 125 %, 2 from 150 %, 3 from 300 %) }
function FocusLineW: Single;
function UIScale: Single;
procedure UseDpiOf(C: TControl);
function MonitorDpiAt(X, Y: Integer): Integer;
function WindowDpi(H: HWND): Integer;
const
  ROW_DENSITY_COMPACT = 0.82;

{ the user's text size (1 = normal), applied by the UIFont functions }
var
  FontScale: Single = 1.0;
  { the row height of the lists (playlist, library tree) as a part of the
    normal one: 1 = normal, ROW_DENSITY_COMPACT = compact rows }
  RowDensity: Single = 1.0;

function UIFont(Size: Single = 13; Bold: Boolean = False): TGfxFont;
function UIFontI(Size: Single = 13): TGfxFont;
function MonoFont(Size: Single = 12; Bold: Boolean = False): TGfxFont;
function ToTColor(C: TARGB): TColor;
function RoleColor(R: TAuRole): TARGB;
function AccentSample(I: Integer): TARGB;
function SystemPrefersDark: Boolean;
procedure SetTheme(AMode: TAuThemeMode; AAccent: Integer);
{ the WCAG contrast of two colours, 1 (the same) .. 21 }
function ContrastOf(A, B: TARGB): Double;
{ The colour behind selected text in an input field: the field's background
  with as much of the accent mixed in as leaves the text on it readable. A
  row of a list is marked with clSelection, a much weaker tint: behind a few
  letters, and on a field that is lighter than the window, that tint is
  hardly seen. }
function TextSelectionFor(ABack, AAccent, AText: TARGB): TARGB;
procedure ApplyTitleBar(H: HWND);

const
  { posted to itself by a window that was shown cloaked (TAuForm, TAuPopup) }
  AUM_UNCLOAK = WM_USER + $2A1;

{ DWM cloaking (Windows 8 and later; nothing on older systems): a cloaked
  window is not drawn by the compositor. Windows are shown cloaked and
  uncloaked once they have painted (PaintAndUncloak), so a dark window never
  shows its empty, white surface first. }
procedure SetWindowCloak(H: HWND; ACloak: Boolean);
{ paints the window and all its controls now, then uncloaks it }
procedure PaintAndUncloak(H: HWND);

var
  { called by SetTheme before the colours change (AuForms
    takes a picture of every window then, to fade over from) }
  OnThemeChanging: TProcedure = nil;

procedure RefreshAllForms;
procedure AddThemeListener(E: TNotifyEvent);
procedure RemoveThemeListener(E: TNotifyEvent);
function HashColor(const Key: string): TARGB;
{ colour choice without the Integer / Int64 overloads of Math.IfThen }
function IfC(Cond: Boolean; A, B: TARGB): TARGB; inline;

implementation

uses
  Math;

function IfC(Cond: Boolean; A, B: TARGB): TARGB; inline;
begin
  if Cond then Result := A else Result := B;
end;

var
  Listeners: array of TNotifyEvent;

const
  { the dark theme: pastel (CIE LCh L 61..88, C 30..42), contrast on the
    background 5.9 .. 13.2; the light theme: the same hues darker, contrast
    on white 3.2 (Yellow) .. 8.1. Closest pair (CIEDE2000) with normal sight
    / protanopia / deuteranopia / tritanopia: dark 20.1 / 11.3 / 8.2 / 11.1,
    light 20.2 / 9.8 / 9.8 / 10.6. }
  AccentDark: array[0..AccentCount - 1] of TARGB = ($FF75A3E1, $FF6CE0BD, $FFF0DC94, $FFECAA81, $FFCD7A98, $FFE2C7FD);
  AccentLight: array[0..AccentCount - 1] of TARGB = ($FF006DCA, $FF069463, $FFB48B07, $FFBE6243, $FF9C466A, $FF584584);

{ the WCAG relative luminance, 0 .. 1 }
function RelLuminance(C: TARGB): Double;

  function Ch(V: Integer): Double;
  begin
    Result := V / 255;
    if Result <= 0.04045 then Result := Result / 12.92
    else Result := Power((Result + 0.055) / 1.055, 2.4);
  end;

begin
  Result := 0.2126 * Ch((C shr 16) and $FF) + 0.7152 * Ch((C shr 8) and $FF) + 0.0722 * Ch(C and $FF);
end;

{ the text / icon colour on an accent fill: white or near-black, whichever
  stands out more (the pastel accents take near-black) }
function OnAccentFor(A: TARGB): TARGB;
var
  L: Double;
begin
  L := RelLuminance(A);
  if 1.05 / (L + 0.05) >= (L + 0.05) / (RelLuminance($FF111317) + 0.05) then Result := $FFFFFFFF
  else Result := $FF111317;
end;

function ContrastOf(A, B: TARGB): Double;
var
  LA, LB: Double;
begin
  LA := RelLuminance(A);
  LB := RelLuminance(B);
  if LA >= LB then Result := (LA + 0.05) / (LB + 0.05)
  else Result := (LB + 0.05) / (LA + 0.05);
end;

function TextSelectionFor(ABack, AAccent, AText: TARGB): TARGB;
const
  MIX_MOST = 0.55;            // the strongest tint
  MIX_LEAST = 0.30;
  MIX_STEP = 0.01;
  TEXT_CONTRAST = 4.5;        // the text on the tint (WCAG AA)
var
  M: Double;
begin
  { a pastel accent of the dark theme is bright: less of it, until the light
    text stands out enough }
  M := MIX_MOST;
  repeat
    Result := Blend(ABack, AAccent, M);
    if ContrastOf(AText, Result) >= TEXT_CONTRAST then Exit;
    M := M - MIX_STEP;
  until M < MIX_LEAST;
end;

function UIScale: Single;
begin
  if CurDpi < 48 then CurDpi := 96;
  Result := CurDpi / 96;
end;

procedure UseDpiOf(C: TControl);
var
  F: TCustomForm;
begin
  F := GetParentForm(C);
  if (F <> nil) and (F.PixelsPerInch >= 48) then CurDpi := F.PixelsPerInch;
end;

function MonitorDpiAt(X, Y: Integer): Integer;
var
  M: TMonitor;
begin
  Result := 0;
  if Screen <> nil then
  begin
    M := Screen.MonitorFromPoint(Point(X, Y), mdNearest);
    if M <> nil then Result := M.PixelsPerInch;
  end;
  if Result < 48 then
  begin
    if Screen <> nil then Result := Screen.PixelsPerInch else Result := 96;
  end;
end;

function WindowDpi(H: HWND): Integer;
type
  TGetDpiForWindow = function(Wnd: HWND): UINT; stdcall;
var
  F: TGetDpiForWindow;
begin
  Result := 0;
  F := TGetDpiForWindow(GetProcAddress(GetModuleHandle('user32.dll'), 'GetDpiForWindow'));
  if Assigned(F) and (H <> 0) then Result := F(H);
end;

function S(V: Integer): Integer;
begin
  Result := Round(V * UIScale);
end;

function SF(V: Single): Single;
begin
  Result := V * UIScale;
end;

function FocusLineW: Single;
begin
  Result := S(1);
  if Result < 1 then Result := 1;
end;

{ the cut of Segoe UI Variable for a text size (unscaled, as
  Windows 11 uses them: Small for captions up to 12, Text for normal text,
  Display from 20 on) }
function OpticalFor(ASize: Single): Integer;
begin
  if ASize < 12.5 then Result := foSmall
  else if ASize < 20 then Result := foText
  else Result := foDisplay;
end;

function UIFont(Size: Single; Bold: Boolean): TGfxFont;
begin
  Result := GetFont(Round(SF(Size * FontScale) * 2) / 2, Bold, False, False, OpticalFor(Size * FontScale));
end;

function UIFontI(Size: Single): TGfxFont;
begin
  Result := GetFont(Round(SF(Size * FontScale) * 2) / 2, False, False, True, OpticalFor(Size * FontScale));
end;

function MonoFont(Size: Single; Bold: Boolean): TGfxFont;
begin
  Result := GetFont(Round(SF(Size * FontScale) * 2) / 2, Bold, True);
end;

function ToTColor(C: TARGB): TColor;
begin
  Result := TColor(((C shr 16) and $FF) or (C and $FF00) or ((C and $FF) shl 16));
end;

function RoleColor(R: TAuRole): TARGB;
begin
  case R of
    crBg: Result := clBg;
    crPanel: Result := clPanel;
    crSurface: Result := clSurface;
    crCard: Result := clCard;
    crInput: Result := clInput;
    crHover: Result := clHover;
    crPressed: Result := clPressed;
    crBorder: Result := clBorder;
    crText: Result := clText;
    crTextDim: Result := clTextDim;
    crTextFaint: Result := clTextFaint;
    crAccent: Result := clAccentText;
    crSelection: Result := clSelection;
    crGood: Result := clGood;
    crBad: Result := clBad;
    crWarn: Result := clWarn;
  else
    Result := 0;
  end;
end;

function AccentSample(I: Integer): TARGB;
begin
  if (I < 0) or (I >= AccentCount) then I := 0;
  if ThemeIsDark then Result := AccentDark[I] else Result := AccentLight[I];
end;

function SystemPrefersDark: Boolean;
var
  R: TRegistry;
begin
  Result := True;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') then
    begin
      if R.ValueExists('AppsUseLightTheme') then Result := R.ReadInteger('AppsUseLightTheme') = 0;
      R.CloseKey;
    end;
  except
    Result := True;
  end;
  R.Free;
end;

{ Deterministic, pleasant colour from a string (album / artist placeholders). }
{$PUSH}{$Q-}{$R-}
function HashColor(const Key: string): TARGB;
var
  H: Cardinal;
  I: Integer;
  Hue, Sat, Lig, C, X, M, R, G, B: Single;
  HI: Integer;
begin
  H := 2166136261;
  for I := 1 to Length(Key) do
    H := (H xor Ord(Key[I])) * 16777619;
  Hue := (H mod 360);
  if ThemeIsDark then begin Sat := 0.38; Lig := 0.36; end
  else begin Sat := 0.42; Lig := 0.62; end;
  C := (1 - Abs(2 * Lig - 1)) * Sat;
  HI := Trunc(Hue / 60);
  X := C * (1 - Abs(Frac(Hue / 120) * 2 - 1));
  case HI of
    0: begin R := C; G := X; B := 0; end;
    1: begin R := X; G := C; B := 0; end;
    2: begin R := 0; G := C; B := X; end;
    3: begin R := 0; G := X; B := C; end;
    4: begin R := X; G := 0; B := C; end;
  else
    begin R := C; G := 0; B := X; end;
  end;
  M := Lig - C / 2;
  Result := $FF000000 or (Cardinal(Round((R + M) * 255)) shl 16) or
    (Cardinal(Round((G + M) * 255)) shl 8) or Cardinal(Round((B + M) * 255));
end;
{$POP}

procedure SetDarkPalette;
begin
  clBg := $FF111317;
  clPanel := $FF15171C;
  clSurface := $FF181B21;
  clCard := $FF1E2229;
  clInput := $FF282D37;
  clInputLine := $FF454C58;
  clInputLineHi := $FF5E6674;
  clHover := $FF272C35;
  clPressed := $FF30363F;
  clBorder := $FF2A2F38;
  clBorderHi := $FF3B414C;
  clText := $FFE8EAED;
  clTextDim := $FF9AA2AD;
  clTextFaint := $FF646C78;
  clGood := $FF3FB950;
  clBad := $FFF0524A;
  clWarn := $FFD9A23A;
  clShadow := $60000000;
  clThumb := $FF353B45;
  clThumbHi := $FF4C5360;
end;

procedure SetLightPalette;
begin
  clBg := $FFFAFAFB;
  clPanel := $FFF2F3F5;
  clSurface := $FFFFFFFF;
  clCard := $FFFFFFFF;
  clInput := $FFFFFFFF;
  clInputLine := $FFBEC4CD;
  clInputLineHi := $FF969DA8;
  clHover := $FFE9EBEF;
  clPressed := $FFDDE0E6;
  clBorder := $FFE0E3E8;
  clBorderHi := $FFC6CBD3;
  clText := $FF16191D;
  clTextDim := $FF5A6270;
  clTextFaint := $FF969DA8;
  clGood := $FF1A8F36;
  clBad := $FFD93A32;
  clWarn := $FFB7791F;
  clShadow := $30000000;
  clThumb := $FFCDD1D8;
  clThumbHi := $FFAEB4BE;
end;

procedure SetTheme(AMode: TAuThemeMode; AAccent: Integer);
var
  A: TARGB;
begin
  if Assigned(OnThemeChanging) then OnThemeChanging();
  ThemeMode := AMode;
  if (AAccent < 0) or (AAccent >= AccentCount) then AAccent := 0;
  AccentIndex := AAccent;
  case AMode of
    tmDark: ThemeIsDark := True;
    tmLight: ThemeIsDark := False;
  else
    ThemeIsDark := SystemPrefersDark;
  end;
  if ThemeIsDark then
  begin
    SetDarkPalette;
    A := AccentDark[AAccent];
    clAccent := A;
    clAccentHi := Blend(A, $FFFFFFFF, 0.14);
    clAccentLo := Blend(A, $FF000000, 0.18);
    clAccentText := A;              // pastel: readable as it is
    clSelection := Blend(clBg, A, 0.26);
    clSelectionDim := Blend(clBg, clText, 0.10);
    clTextSelection := TextSelectionFor(clInput, A, clText);
  end
  else
  begin
    SetLightPalette;
    A := AccentLight[AAccent];
    clAccent := A;
    clAccentHi := Blend(A, $FF000000, 0.10);
    clAccentLo := Blend(A, $FF000000, 0.22);
    clAccentText := A;
    clSelection := Blend(clBg, A, 0.16);
    clSelectionDim := Blend(clBg, clText, 0.08);
    clTextSelection := TextSelectionFor(clInput, A, clText);
  end;
  clOnAccent := OnAccentFor(clAccent);
  RefreshAllForms;
end;

procedure ApplyTitleBar(H: HWND);
type
  TDwmSet = function(Wnd: HWND; Attr: DWORD; PV: Pointer; CB: DWORD): HRESULT; stdcall;
var
  Lib: HMODULE;
  F: TDwmSet;
  V: BOOL;
  Col: DWORD;
begin
  if H = 0 then Exit;
  Lib := GetModuleHandle('dwmapi.dll');
  if Lib = 0 then Lib := LoadLibrary('dwmapi.dll');
  if Lib = 0 then Exit;
  F := TDwmSet(GetProcAddress(Lib, 'DwmSetWindowAttribute'));
  if not Assigned(F) then Exit;
  V := ThemeIsDark;
  if F(H, 20, @V, SizeOf(V)) <> 0 then F(H, 19, @V, SizeOf(V));   // immersive dark mode
  Col := ToTColor(clPanel);
  F(H, 35, @Col, SizeOf(Col));        // caption colour (Windows 11)
  Col := ToTColor(clBorder);
  F(H, 34, @Col, SizeOf(Col));        // border colour (Windows 11)
  Col := ToTColor(clTextDim);
  F(H, 36, @Col, SizeOf(Col));        // caption text colour (Windows 11)
end;

procedure SetWindowCloak(H: HWND; ACloak: Boolean);
type
  TDwmSet = function(Wnd: HWND; Attr: DWORD; PV: Pointer; CB: DWORD): HRESULT; stdcall;
const
  DWMWA_CLOAK = 13;
var
  Lib: HMODULE;
  F: TDwmSet;
  V: BOOL;
begin
  if H = 0 then Exit;
  Lib := GetModuleHandle('dwmapi.dll');
  if Lib = 0 then Lib := LoadLibrary('dwmapi.dll');
  if Lib = 0 then Exit;
  F := TDwmSet(GetProcAddress(Lib, 'DwmSetWindowAttribute'));
  if not Assigned(F) then Exit;
  V := ACloak;
  F(H, DWMWA_CLOAK, @V, SizeOf(V));
end;

procedure PaintAndUncloak(H: HWND);

var
  { called by SetTheme before the colours change (AuForms
    takes a picture of every window then, to fade over from) }
  OnThemeChanging: TProcedure = nil;

begin
  if H = 0 then Exit;
  if IsWindowVisible(H) then
    RedrawWindow(H, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_FRAME or RDW_ALLCHILDREN or RDW_UPDATENOW);
  SetWindowCloak(H, False);
end;

procedure RefreshAllForms;
var
  I: Integer;
  F: TCustomForm;
  L: array of TNotifyEvent;
begin
  if Screen = nil then Exit;
  for I := 0 to Screen.CustomFormCount - 1 do
  begin
    F := Screen.CustomForms[I];
    F.Color := ToTColor(clBg);
    if F.HandleAllocated then
    begin
      ApplyTitleBar(F.Handle);
      RedrawWindow(F.Handle, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_FRAME);
    end;
  end;
  L := Copy(Listeners);
  for I := 0 to High(L) do L[I](nil);
end;

procedure AddThemeListener(E: TNotifyEvent);
var
  N: Integer;
begin
  N := Length(Listeners);
  SetLength(Listeners, N + 1);
  Listeners[N] := E;
end;

procedure RemoveThemeListener(E: TNotifyEvent);
var
  I, J: Integer;
begin
  for I := High(Listeners) downto 0 do
    if (TMethod(Listeners[I]).Code = TMethod(E).Code) and (TMethod(Listeners[I]).Data = TMethod(E).Data) then
    begin
      for J := I to High(Listeners) - 1 do Listeners[J] := Listeners[J + 1];
      SetLength(Listeners, Length(Listeners) - 1);
    end;
end;

initialization
  if Screen <> nil then CurDpi := Screen.PixelsPerInch;
  SetDarkPalette;
  clAccent := AccentDark[0];
  clAccentHi := Blend(clAccent, $FFFFFFFF, 0.14);
  clAccentLo := Blend(clAccent, $FF000000, 0.18);
  clAccentText := clAccent;
  clOnAccent := OnAccentFor(clAccent);
  clSelection := Blend(clBg, clAccent, 0.26);
  clSelectionDim := Blend(clBg, clText, 0.10);
  clTextSelection := TextSelectionFor(clInput, clAccent, clText);

end.
