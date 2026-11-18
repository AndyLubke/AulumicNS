unit AuGfx;

{ ==============================================================================
  AulumicNS - AuGfx
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The drawing layer of the GUI: TGfx (anti-aliased shapes, paths, gradients,
  clipping, bitmaps, text), fonts, bitmaps in memory and picture files.
  ---> AulumicNS: Direct2D draws, DirectWrite sets the text, the Windows
  Imaging Component (WIC) reads and writes picture files. All three are part
  of Windows (bindings: AuD2D); this unit replaced the GDI+ one (AuGdip) on
  2026-11-13 and kept its calls, so the controls did not change.

  How it paints: one Direct2D render target (a "DC render target") is shared
  by the small controls. TGfx.Create binds it to the DC a control paints into
  and begins drawing; freeing the TGfx ends drawing, which puts the picture
  into that DC. A large control (the lists), or one that repaints often, has
  a render target of its own on the graphics card (TGfxWindowTarget) and
  falls back to the shared one when that target cannot be made or is lost. Pictures drawn off screen (TGfx.CreateBitmap: icon, toast, meter
  column, screenshots) get a target of their own with an alpha channel.
  Everything here is in pixels: the targets run at 96 dpi, the callers scale
  (AuTheme.S). Only the UI thread draws; picture files may be decoded on any
  thread (ImageFromBytes / ImageFromFile).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, ActiveX, AuD2D;

type
  TARGB = Cardinal;
  PARGB = ^TARGB;

  TGfxPoint = TD2DPoint;      // X, Y: Single

  TGfxRectF = record
    X, Y, Width, Height: Single;
  end;

  { a picture in memory: 32 bit, blue-green-red-alpha, the colours multiplied
    by alpha (what Direct2D and WIC use), top row first }
  TGfxBitmap = class
  private
    FW, FH: Integer;
    FBits: PByte;
    FDev: ID2D1Bitmap;        // the copy Direct2D draws from, made at the first draw
    FDevId: Integer;          // the target it was made for
  public
    constructor Create(AWidth, AHeight: Integer);
    destructor Destroy; override;
    function Stride: Integer;
    function Row(Y: Integer): PARGB;
    { call after writing into Bits: the copy for drawing is made again }
    procedure Changed;
    property Width: Integer read FW;
    property Height: Integer read FH;
    property Bits: PByte read FBits;
  end;

  { a path of lines, curves and arcs. Like the GDI+ path it replaced: what is
    added to a figure is joined to its last point by a line. }
  TGfxPath = class
  private
    FGeo: ID2D1PathGeometry;
    FSink: ID2D1GeometrySink;
    FInFigure: Boolean;
    FLast: TGfxPoint;
    procedure MoveOrLine(X, Y: Single);
  public
    constructor Create(AWinding: Boolean = False);
    destructor Destroy; override;
    procedure StartFigure;
    procedure CloseFigure;
    procedure AddLine(X1, Y1, X2, Y2: Single);
    procedure AddBezier(X1, Y1, X2, Y2, X3, Y3, X4, Y4: Single);
    { part of the ellipse in the box X, Y, W, H; angles in degrees, clockwise from 3 o'clock }
    procedure AddArc(X, Y, W, H, StartAngle, SweepAngle: Single);
    procedure AddEllipse(X, Y, W, H: Single);
    procedure AddRect(X, Y, W, H: Single);
    procedure AddPolygon(const Pts: array of TGfxPoint);
    { the finished geometry (nothing can be added after this) }
    function Geometry: ID2D1Geometry;
  end;

  TGfxFont = class
  public
    Format: IDWriteTextFormat;
    Ellipsis: IDWriteInlineObject;
    Size: Single;
    Bold, Mono, Italic: Boolean;
    Optical: Integer;
    LineHeight: Single;
  end;

const
  tfWrap = 1;          // word wrap
  tfNoEllipsis = 2;    // clip instead of '...'

  { optical sizes of Segoe UI Variable (GetFont) }
  foSmall = 0;
  foText = 1;
  foDisplay = 2;

  { ---> AulumicNS: a picture with more pixels is not decoded (8192 x 8192;
    256 MB as a 32 bit bitmap). The number of pixels, not the longer side: a
    booklet page may be a wide fold-out (AuBooklet keeps pages below 20 MP). }
  MAX_IMAGE_PIXELS = 8192 * 8192;

type
  TGfxClip = record
    IsLayer: Boolean;
  end;

  TGfxState = record
    Clips: Integer;
    M: TD2DMatrix;
  end;

  TGfxWindowTarget = class;

  { TGfx }
  TGfx = class
  private
    FWinTarget: TGfxWindowTarget;
    FRT: ID2D1RenderTarget;
    FOwnRT: ID2D1DCRenderTarget;     // off screen, or when the shared target was busy
    FTargetId: Integer;
    FShared: Boolean;
    FDrawing: Boolean;
    FOpaque: Boolean;
    FBrush: ID2D1SolidColorBrush;
    FBroken: Boolean;                // the target could not even make a brush: this paint counts as lost
    FM: TD2DMatrix;
    FClips: array of TGfxClip;
    FClipCount: Integer;
    FStates: array of TGfxState;
    FStateCount: Integer;
    { off screen }
    FDC: HDC;
    FBmp, FOldBmp: HBITMAP;
    FDibBits: Pointer;
    FW, FH: Integer;
    function OpenBrush: Boolean;
    procedure Start(ADC: HDC; AW, AH: Integer; AOpaque: Boolean);
    procedure Finish;
    procedure PushClip(AIsLayer: Boolean);
    procedure PopClips(ADownTo: Integer);
    function DeviceBitmap(B: TGfxBitmap): ID2D1Bitmap;
    function GradBrush(X1, Y1, X2, Y2: Single; C1, C2: TARGB): ID2D1Brush;
  public
    { paints into a DC of AWidth x AHeight pixels (a control's paint) }
    constructor Create(DC: HDC; AWidth, AHeight: Integer);
    { paints a window through its own render target (TGfxWindowTarget.BeginPaint) }
    constructor CreateOnWindow(ATarget: TGfxWindowTarget);
    { draws a picture of its own, transparent at first; ToBitmap takes it }
    { AOpaque: no transparency, text as on screen (a picture of controls) }
    constructor CreateBitmap(AWidth, AHeight: Integer; AOpaque: Boolean = False);
    destructor Destroy; override;
    function ToBitmap: TGfxBitmap;
    function Brush(C: TARGB): ID2D1Brush;
    procedure Clear(C: TARGB);
    procedure FillRect(X, Y, W, H: Single; C: TARGB);
    procedure FillRectGrad(X, Y, W, H: Single; X1, Y1, X2, Y2: Single; C1, C2: TARGB);
    procedure StrokeRect(X, Y, W, H, LW: Single; C: TARGB);
    procedure FillRound(X, Y, W, H, R: Single; C: TARGB);
    procedure StrokeRound(X, Y, W, H, R, LW: Single; C: TARGB);
    procedure FillRoundGrad(X, Y, W, H, R: Single; C1, C2: TARGB; Diagonal: Boolean = False);
    procedure FillCircle(CX, CY, R: Single; C: TARGB);
    procedure StrokeCircle(CX, CY, R, LW: Single; C: TARGB);
    procedure Arc(CX, CY, R, StartAngle, Sweep, LW: Single; C: TARGB);
    procedure Line(X1, Y1, X2, Y2, LW: Single; C: TARGB);
    procedure FillPath(P: TGfxPath; C: TARGB);
    procedure StrokePath(P: TGfxPath; LW: Single; C: TARGB);
    { with a colour gradient from X1, Y1 to X2, Y2 }
    procedure FillPathGrad(P: TGfxPath; X1, Y1, X2, Y2: Single; C1, C2: TARGB);
    procedure StrokePathGrad(P: TGfxPath; LW: Single; X1, Y1, X2, Y2: Single; C1, C2: TARGB);
    procedure FillPoly(const Pts: array of TGfxPoint; C: TARGB);
    procedure StrokePoly(const Pts: array of TGfxPoint; LW: Single; C: TARGB; Closed: Boolean);
    procedure Text(const S: string; X, Y, W, H: Single; F: TGfxFont; C: TARGB;
      HAlign: Integer = 0; VAlign: Integer = 1; Flags: Integer = 0);
    procedure TextW(const S: UnicodeString; X, Y, W, H: Single; F: TGfxFont; C: TARGB;
      HAlign: Integer = 0; VAlign: Integer = 1; Flags: Integer = 0);
    { Save / Restore: the clipping and the shift (Translate), nested }
    function Save: UINT;
    procedure Restore(State: UINT);
    procedure Translate(DX, DY: Single);
    procedure IntersectClipRect(X, Y, W, H: Single);
    procedure IntersectClipRound(X, Y, W, H, R: Single);
    { everything but the ellipse in the box X, Y, W, H }
    procedure ExcludeClipEllipse(X, Y, W, H: Single);
    procedure DrawBitmap(B: TGfxBitmap; X, Y, W, H: Single; AOpacity: Single = 1);
    { the part SX, SY, SW, SH of the bitmap; ANearest: no smoothing }
    procedure DrawBitmapPart(B: TGfxBitmap; X, Y, W, H, SX, SY, SW, SH: Single; ANearest: Boolean = False);
    { covers the whole target (centre crop), clipped to a rounded rectangle of radius R }
    procedure DrawBitmapCover(B: TGfxBitmap; X, Y, W, H, R: Single);
    property Opaque: Boolean read FOpaque;
  end;

  { ---> AulumicNS: a render target of its own for one window (a control):
    the graphics card draws and shows the picture without the copies a DC
    target needs (into Direct2D, back out, to the window). For the large
    controls that repaint often and in full: the lists while they scroll.
    BeginPaint returns nil when there is no such target (then the caller
    paints the usual way). }
  TGfxWindowTarget = class
  private
    FRT: ID2D1HwndRenderTarget;
    FWnd: HWND;
    FW, FH: Integer;
    FId: Integer;
    FLosses: Integer;
    FFailed: Boolean;
    FFailedAt: QWord;            // when it gave up: tried again TARGET_RETRY_MS later
    procedure GiveUp;
  public
    function BeginPaint(AWnd: HWND; AWidth, AHeight: Integer): TGfx;
    { the window is gone or the target was lost: a new one at the next paint }
    procedure Release;
  end;

function GPt(X, Y: Single): TGfxPoint; inline;
function RoundRectPath(X, Y, W, H, R: Single): TGfxPath;
{ AOptical: foSmall / foText / foDisplay - the cut of Segoe UI Variable for
  small, normal and large text (AuTheme.UIFont chooses by the unscaled size) }
function GetFont(Size: Single; Bold: Boolean = False; Mono: Boolean = False; Italic: Boolean = False;
  AOptical: Integer = foText): TGfxFont;
{ the font family of the interface: 'Segoe UI Variable' (Windows 11) or 'Segoe UI' }
function UIFontFamily: string;
function TextWidth(const S: string; F: TGfxFont): Single;
function TextWidthW(const S: UnicodeString; F: TGfxFont): Single;
function TextHeightWrapped(const S: string; F: TGfxFont; W: Single): Single;
function RGBA(RGB: Cardinal; A: Byte = 255): TARGB; inline;
function WithAlpha(C: TARGB; A: Byte): TARGB; inline;
function Blend(C1, C2: TARGB; T: Single): TARGB;
function Luminance(C: TARGB): Integer;
function BitmapSize(B: TGfxBitmap; out W, H: Integer): Boolean;
{ decodes an image (JPEG, PNG, GIF, BMP, TIFF) and scales it to at most MaxSide pixels (0 = original size);
  the result is an independent 32 bit bitmap (thread safe to call) }
function ImageFromBytes(const Data: TBytes; MaxSide: Integer): TGfxBitmap;
function ImageFromFile(const FileName: string; MaxSide: Integer): TGfxBitmap;
function ScaledCopy(Src: TGfxBitmap; MaxSide: Integer): TGfxBitmap;
{ ---> AulumicNS: the size of a picture from its header, nothing is decoded;
  False when it is no picture }
function ImageSizeFromBytes(const Data: TBytes; out W, H: Integer): Boolean;
function ImageSizeFromFile(const FileName: string; out W, H: Integer): Boolean;
{ ---> AulumicNS: False for a picture with more than MAX_IMAGE_PIXELS: the
  loaders above return nil for it instead of decoding it }
function ImagePixelsAllowed(W, H: Integer): Boolean;
function CloneBitmap(B: TGfxBitmap): TGfxBitmap;
procedure DisposeBitmap(B: TGfxBitmap);
function SaveBitmapJpeg(B: TGfxBitmap; const FileName: string): Boolean;
function SaveBitmapPng(B: TGfxBitmap; const FileName: string): Boolean;
{ the picture as a JPEG / PNG file in memory; nil when it failed }
function BitmapToBytes(B: TGfxBitmap; AJpeg: Boolean): TBytes;
{ a pixel of the bitmap as plain (not alpha-multiplied) ARGB }
function StraightPixel(P: TARGB): TARGB;
{ the bitmap as an icon; the caller destroys it (DestroyIcon) }
function BitmapToIcon(B: TGfxBitmap): HICON;
{ True once after a paint was lost with the render target (the graphics driver
  was restarted): the caller repaints everything }
function GfxTargetWasLost: Boolean;
{ True while the program ends, once this unit has let go of Direct2D: nothing
  may be drawn or measured any more (a window that still gets a paint
  message then would start Direct2D again - Windows raises an exception
  when a graphics device is made that late) }
function GfxStopped: Boolean;

var
  { --d2d=software|hardware (debug): the kind of the shared render target;
    the default lets Direct2D choose }
  GfxTargetKind: UINT = D2D1_RENDER_TARGET_TYPE_SOFTWARE;
  { --test-target-loss=<n> (debug): every n-th paint through a window render
    target ends as if the graphics device had been lost (1: every one) }
  GfxTestLoseEvery: Integer = 0;
  { --font=segoe (debug): Segoe UI although Segoe UI Variable is installed -
    how the program looks on Windows 10 }
  GfxClassicFont: Boolean = False;

implementation

uses
  Math, AuAudioTypes;   // ---> AulumicNS: LongPath (paths of 260 characters and more)

const
  IID_ID2D1Factory: TGUID = '{06152247-6F50-465A-9245-118BFD3B6007}';
  IID_IDWriteFactory: TGUID = '{B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}';
  IID_IWICImagingFactory: TGUID = '{EC5EC8A9-C395-4314-9C77-54D7A935FF70}';

var
  Factory: ID2D1Factory = nil;
  DWrite: IDWriteFactory = nil;
  RoundStroke: ID2D1StrokeStyle = nil;
  SharedRT: ID2D1DCRenderTarget = nil;
  SharedId: Integer = 0;
  SharedBusy: Boolean = False;
  NextTargetId: Integer = 0;
  TargetLost: Boolean = False;
  Fonts: TList = nil;
  VariableChecked: Boolean = False;
  HasVariable: Boolean = False;
  Locale: UnicodeString = '';
  Stopped: Boolean = False;
  TestPaints: Integer = 0;
  LostWindowStart: QWord = 0;
  LostInWindow: Integer = 0;

const
  { a window render target that failed three times in a row is tried again
    this much later; until then its control paints through the buffer }
  TARGET_RETRY_MS = 15000;

threadvar
  ComReady: Boolean;

const
  LOCALE_NAME_MAX_LENGTH = 85;

function GetUserDefaultLocaleName(AName: PWideChar; ASize: Integer): Integer; stdcall;
  external 'kernel32.dll';

function GPt(X, Y: Single): TGfxPoint; inline;
begin
  Result.X := X;
  Result.Y := Y;
end;

function RGBA(RGB: Cardinal; A: Byte): TARGB; inline;
begin
  Result := (Cardinal(A) shl 24) or (RGB and $FFFFFF);
end;

function WithAlpha(C: TARGB; A: Byte): TARGB; inline;
begin
  Result := (Cardinal(A) shl 24) or (C and $FFFFFF);
end;

function Blend(C1, C2: TARGB; T: Single): TARGB;
  function Mix(Shift: Integer): Cardinal;
  var
    A, B: Integer;
  begin
    A := (C1 shr Shift) and $FF;
    B := (C2 shr Shift) and $FF;
    Result := Cardinal(Round(A + (B - A) * T)) and $FF;
  end;
begin
  if T < 0 then T := 0;
  if T > 1 then T := 1;
  Result := (Mix(24) shl 24) or (Mix(16) shl 16) or (Mix(8) shl 8) or Mix(0);
end;

function Luminance(C: TARGB): Integer;
begin
  Result := (Integer((C shr 16) and $FF) * 299 + Integer((C shr 8) and $FF) * 587 +
    Integer(C and $FF) * 114) div 1000;
end;

function ColorF(C: TARGB): TD2DColor; inline;
begin
  Result.A := ((C shr 24) and $FF) / 255;
  Result.R := ((C shr 16) and $FF) / 255;
  Result.G := ((C shr 8) and $FF) / 255;
  Result.B := (C and $FF) / 255;
end;

function StraightPixel(P: TARGB): TARGB;
var
  A: Cardinal;
  function Un(Shift: Integer): Cardinal;
  begin
    Result := Min(255, (((P shr Shift) and $FF) * 255 + A div 2) div A);
  end;
begin
  A := P shr 24;
  if A = 0 then Exit(0);
  if A = 255 then Exit(P);
  Result := (A shl 24) or (Un(16) shl 16) or (Un(8) shl 8) or Un(0);
end;

function GfxStopped: Boolean;
begin
  Result := Stopped;
end;

procedure EnsureFactories;
var
  SP: TD2DStrokeProps;
  Buf: array[0..LOCALE_NAME_MAX_LENGTH] of WideChar;
begin
  if Stopped then Exit;
  if Factory = nil then
  begin
    D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, IID_ID2D1Factory, nil, Factory);
    if Factory <> nil then
    begin
      FillChar(SP, SizeOf(SP), 0);
      SP.StartCap := D2D1_CAP_STYLE_ROUND;
      SP.EndCap := D2D1_CAP_STYLE_ROUND;
      SP.DashCap := D2D1_CAP_STYLE_ROUND;
      SP.LineJoin := D2D1_LINE_JOIN_ROUND;
      SP.MiterLimit := 10;
      SP.DashStyle := D2D1_DASH_STYLE_SOLID;
      Factory.CreateStrokeStyle(SP, nil, 0, RoundStroke);
    end;
  end;
  if DWrite = nil then
  begin
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, IID_IDWriteFactory, DWrite);
    Buf[0] := #0;
    if GetUserDefaultLocaleName(@Buf[0], LOCALE_NAME_MAX_LENGTH) > 0 then Locale := PWideChar(@Buf[0])
    else Locale := 'en-us';
  end;
end;

function GfxTargetWasLost: Boolean;
var
  Now: QWord;
begin
  Result := TargetLost;
  TargetLost := False;
  if not Result then Exit;
  { the caller repaints every window. Should paints keep failing, that must
    not become a loop that eats a processor core: at most eight repaints
    of everything in two seconds }
  Now := GetTickCount64;
  if Now - LostWindowStart > 2000 then
  begin
    LostWindowStart := Now;
    LostInWindow := 0;
  end;
  Inc(LostInWindow);
  if LostInWindow > 8 then Result := False;
end;

{ TGfxBitmap }

constructor TGfxBitmap.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  FW := AWidth;
  FH := AHeight;
  FBits := AllocMem(PtrUInt(FW) * PtrUInt(FH) * 4);
end;

destructor TGfxBitmap.Destroy;
begin
  FDev := nil;
  if FBits <> nil then FreeMem(FBits);
  inherited Destroy;
end;

function TGfxBitmap.Stride: Integer;
begin
  Result := FW * 4;
end;

function TGfxBitmap.Row(Y: Integer): PARGB;
begin
  Result := PARGB(FBits + PtrUInt(Y) * PtrUInt(FW) * 4);
end;

procedure TGfxBitmap.Changed;
begin
  FDev := nil;
end;

function BitmapSize(B: TGfxBitmap; out W, H: Integer): Boolean;
begin
  W := 0; H := 0;
  Result := False;
  if B = nil then Exit;
  W := B.Width;
  H := B.Height;
  Result := (W > 0) and (H > 0);
end;

function CloneBitmap(B: TGfxBitmap): TGfxBitmap;
begin
  Result := nil;
  if B = nil then Exit;
  Result := TGfxBitmap.Create(B.Width, B.Height);
  Move(B.Bits^, Result.Bits^, PtrUInt(B.Width) * PtrUInt(B.Height) * 4);
end;

procedure DisposeBitmap(B: TGfxBitmap);
begin
  B.Free;
end;

{ TGfxPath }

constructor TGfxPath.Create(AWinding: Boolean);
begin
  inherited Create;
  EnsureFactories;
  if (Factory <> nil) and (Factory.CreatePathGeometry(FGeo) = S_OK) and (FGeo.Open(FSink) = S_OK) then
  begin
    if AWinding then FSink.SetFillMode(D2D1_FILL_MODE_WINDING);
  end
  else
  begin
    FSink := nil;
    FGeo := nil;
  end;
end;

destructor TGfxPath.Destroy;
begin
  if FSink <> nil then
  begin
    if FInFigure then FSink.EndFigure(D2D1_FIGURE_END_OPEN);
    FSink.Close;
    FSink := nil;
  end;
  FGeo := nil;
  inherited Destroy;
end;

procedure TGfxPath.StartFigure;
begin
  if (FSink <> nil) and FInFigure then FSink.EndFigure(D2D1_FIGURE_END_OPEN);
  FInFigure := False;
end;

procedure TGfxPath.CloseFigure;
begin
  if (FSink <> nil) and FInFigure then FSink.EndFigure(D2D1_FIGURE_END_CLOSED);
  FInFigure := False;
end;

procedure TGfxPath.MoveOrLine(X, Y: Single);
begin
  if FSink = nil then Exit;
  if not FInFigure then
  begin
    FSink.BeginFigure(D2DPt(X, Y), D2D1_FIGURE_BEGIN_FILLED);
    FInFigure := True;
  end
  else if (Abs(X - FLast.X) > 0.001) or (Abs(Y - FLast.Y) > 0.001) then
    FSink.AddLine(D2DPt(X, Y));
  FLast := D2DPt(X, Y);
end;

procedure TGfxPath.AddLine(X1, Y1, X2, Y2: Single);
begin
  MoveOrLine(X1, Y1);
  MoveOrLine(X2, Y2);
end;

procedure TGfxPath.AddBezier(X1, Y1, X2, Y2, X3, Y3, X4, Y4: Single);
var
  B: TD2DBezier;
begin
  if FSink = nil then Exit;
  MoveOrLine(X1, Y1);
  B.P1 := D2DPt(X2, Y2);
  B.P2 := D2DPt(X3, Y3);
  B.P3 := D2DPt(X4, Y4);
  FSink.AddBezier(B);
  FLast := B.P3;
end;

procedure TGfxPath.AddArc(X, Y, W, H, StartAngle, SweepAngle: Single);
var
  CX, CY, RX, RY, A0, Part, Done: Single;
  Seg: TD2DArc;
  N, I: Integer;
begin
  if (FSink = nil) or (W <= 0) or (H <= 0) or (SweepAngle = 0) then Exit;
  RX := W / 2;
  RY := H / 2;
  CX := X + RX;
  CY := Y + RY;
  if SweepAngle > 360 then SweepAngle := 360;
  if SweepAngle < -360 then SweepAngle := -360;
  A0 := StartAngle * Pi / 180;
  MoveOrLine(CX + RX * Cos(A0), CY + RY * Sin(A0));
  { in parts of at most 120 degrees: an arc of 360 has no direction, one of
    exactly 180 an ambiguous side }
  N := Ceil(Abs(SweepAngle) / 120);
  Part := SweepAngle / N;
  Done := StartAngle;
  for I := 1 to N do
  begin
    Done := Done + Part;
    A0 := Done * Pi / 180;
    Seg.Point := D2DPt(CX + RX * Cos(A0), CY + RY * Sin(A0));
    Seg.Size.W := RX;
    Seg.Size.H := RY;
    Seg.Rotation := 0;
    if Part > 0 then Seg.Sweep := D2D1_SWEEP_DIRECTION_CLOCKWISE
    else Seg.Sweep := D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE;
    Seg.ArcSize := D2D1_ARC_SIZE_SMALL;
    FSink.AddArc(Seg);
    FLast := Seg.Point;
  end;
end;

procedure TGfxPath.AddEllipse(X, Y, W, H: Single);
begin
  StartFigure;
  AddArc(X, Y, W, H, 0, 360);
  CloseFigure;
end;

procedure TGfxPath.AddRect(X, Y, W, H: Single);
begin
  StartFigure;
  MoveOrLine(X, Y);
  MoveOrLine(X + W, Y);
  MoveOrLine(X + W, Y + H);
  MoveOrLine(X, Y + H);
  CloseFigure;
end;

procedure TGfxPath.AddPolygon(const Pts: array of TGfxPoint);
var
  I: Integer;
begin
  if Length(Pts) < 2 then Exit;
  StartFigure;
  for I := 0 to High(Pts) do MoveOrLine(Pts[I].X, Pts[I].Y);
  CloseFigure;
end;

function TGfxPath.Geometry: ID2D1Geometry;
begin
  if FSink <> nil then
  begin
    if FInFigure then FSink.EndFigure(D2D1_FIGURE_END_OPEN);
    FInFigure := False;
    FSink.Close;
    FSink := nil;
  end;
  Result := FGeo;
end;

function RoundRectPath(X, Y, W, H, R: Single): TGfxPath;
var
  D: Single;
begin
  Result := TGfxPath.Create;
  if R * 2 > W then R := W / 2;
  if R * 2 > H then R := H / 2;
  if R <= 0.1 then
  begin
    Result.AddRect(X, Y, W, H);
    Exit;
  end;
  D := R * 2;
  Result.AddArc(X, Y, D, D, 180, 90);
  Result.AddArc(X + W - D, Y, D, D, 270, 90);
  Result.AddArc(X + W - D, Y + H - D, D, D, 0, 90);
  Result.AddArc(X, Y + H - D, D, D, 90, 90);
  Result.CloseFigure;
end;

{ fonts and text }

function FamilyExists(const AName: UnicodeString): Boolean;
var
  Coll: IDWriteFontCollection;
  Idx: UINT;
  Found: BOOL;
begin
  Result := False;
  Coll := nil;
  EnsureFactories;
  if (DWrite = nil) or (DWrite.GetSystemFontCollection(Coll, False) <> S_OK) or (Coll = nil) then Exit;
  Idx := 0;
  Found := False;
  Result := (Coll.FindFamilyName(PWideChar(AName), Idx, Found) = S_OK) and Found;
end;

function VariableFont: Boolean;
begin
  if not VariableChecked then
  begin
    { the three optical cuts are families of their own for DirectWrite }
    HasVariable := not GfxClassicFont and FamilyExists('Segoe UI Variable Text') and FamilyExists('Segoe UI Variable Display') and
      FamilyExists('Segoe UI Variable Small');
    VariableChecked := True;
  end;
  Result := HasVariable;
end;

function UIFontFamily: string;
begin
  if VariableFont then Result := 'Segoe UI Variable' else Result := 'Segoe UI';
end;

function MakeLayout(const S: UnicodeString; F: TGfxFont; W, H: Single; HAlign, VAlign, Flags: Integer): IDWriteTextLayout;
var
  Trim: TDWriteTrimming;
begin
  Result := nil;
  if (DWrite = nil) or (F = nil) or (F.Format = nil) then Exit;
  if DWrite.CreateTextLayout(PWideChar(S), Length(S), F.Format, W, H, Result) <> S_OK then Exit(nil);
  case HAlign of
    1: Result.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    2: Result.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_TRAILING);
  end;
  case VAlign of
    1: Result.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    2: Result.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_FAR);
  end;
  if Flags and tfWrap = 0 then Result.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  if Flags and tfNoEllipsis = 0 then
  begin
    Trim.Delimiter := 0;
    Trim.DelimiterCount := 0;
    if Flags and tfWrap <> 0 then Trim.Granularity := DWRITE_TRIMMING_GRANULARITY_WORD
    else Trim.Granularity := DWRITE_TRIMMING_GRANULARITY_CHARACTER;
    Result.SetTrimming(Trim, F.Ellipsis);
  end;
end;

function GetFont(Size: Single; Bold: Boolean; Mono: Boolean; Italic: Boolean; AOptical: Integer): TGfxFont;
var
  I: Integer;
  F: TGfxFont;
  Name: UnicodeString;
  Weight, Style: UINT;
  L: IDWriteTextLayout;
  M: TDWriteTextMetrics;
begin
  if Fonts = nil then Exit(nil);            // the program is ending (GfxStopped)
  if Mono or not VariableFont then AOptical := foText;
  for I := 0 to Fonts.Count - 1 do
  begin
    F := TGfxFont(Fonts[I]);
    if (Abs(F.Size - Size) < 0.01) and (F.Bold = Bold) and (F.Mono = Mono) and (F.Italic = Italic) and
       (F.Optical = AOptical) then Exit(F);
  end;
  EnsureFactories;
  F := TGfxFont.Create;
  F.Size := Size;
  F.Bold := Bold;
  F.Mono := Mono;
  F.Italic := Italic;
  F.Optical := AOptical;
  Weight := DWRITE_FONT_WEIGHT_NORMAL;
  if Mono then
  begin
    Name := 'Consolas';
    if Bold then Weight := DWRITE_FONT_WEIGHT_BOLD;
  end
  else
  begin
    if not VariableFont then Name := 'Segoe UI'
    else
      case AOptical of
        foSmall: Name := 'Segoe UI Variable Small';
        foDisplay: Name := 'Segoe UI Variable Display';
      else
        Name := 'Segoe UI Variable Text';
      end;
    if Bold then Weight := DWRITE_FONT_WEIGHT_SEMI_BOLD;
  end;
  if Italic then Style := DWRITE_FONT_STYLE_ITALIC else Style := DWRITE_FONT_STYLE_NORMAL;
  if DWrite <> nil then
  begin
    { a family that is not installed gets DirectWrite's fallback font }
    DWrite.CreateTextFormat(PWideChar(Name), nil, Weight, Style, DWRITE_FONT_STRETCH_NORMAL, Size,
      PWideChar(Locale), F.Format);
    if F.Format <> nil then DWrite.CreateEllipsisTrimmingSign(F.Format, F.Ellipsis);
  end;
  F.LineHeight := 0;
  L := MakeLayout('Hg', F, 10000, 10000, 0, 0, tfNoEllipsis);
  if (L <> nil) and (L.GetMetrics(M) = S_OK) then F.LineHeight := M.Height;
  if F.LineHeight <= 0 then F.LineHeight := Size * 1.33;
  Fonts.Add(F);
  Result := F;
end;

function TextWidthW(const S: UnicodeString; F: TGfxFont): Single;
var
  L: IDWriteTextLayout;
  M: TDWriteTextMetrics;
begin
  Result := 0;
  if S = '' then Exit;
  L := MakeLayout(S, F, 100000, 10000, 0, 0, tfNoEllipsis);
  if (L <> nil) and (L.GetMetrics(M) = S_OK) then Result := M.WidthWithTrailing;
end;

function TextWidth(const S: string; F: TGfxFont): Single;
begin
  Result := TextWidthW(UTF8Decode(S), F);
end;

function TextHeightWrapped(const S: string; F: TGfxFont; W: Single): Single;
var
  L: IDWriteTextLayout;
  M: TDWriteTextMetrics;
begin
  Result := 0;
  if (S = '') or (W <= 0) then Exit;
  L := MakeLayout(UTF8Decode(S), F, W, 100000, 0, 0, tfWrap or tfNoEllipsis);
  if (L <> nil) and (L.GetMetrics(M) = S_OK) then Result := M.Height;
end;

{ TGfx }

function NewTarget(AOpaque: Boolean; AKind: UINT): ID2D1DCRenderTarget;
var
  P: TD2DRenderTargetProps;
begin
  Result := nil;
  EnsureFactories;
  if Factory = nil then Exit;
  FillChar(P, SizeOf(P), 0);
  P.Kind := AKind;
  P.PixelFormat.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  if AOpaque then P.PixelFormat.AlphaMode := D2D1_ALPHA_MODE_IGNORE
  else P.PixelFormat.AlphaMode := D2D1_ALPHA_MODE_PREMULTIPLIED;
  P.DpiX := 96;
  P.DpiY := 96;
  if Factory.CreateDCRenderTarget(P, Result) <> S_OK then
  begin
    Result := nil;
    { no usable graphics card: Direct2D's software renderer }
    if AKind <> D2D1_RENDER_TARGET_TYPE_SOFTWARE then
    begin
      P.Kind := D2D1_RENDER_TARGET_TYPE_SOFTWARE;
      if Factory.CreateDCRenderTarget(P, Result) <> S_OK then Result := nil;
    end;
  end;
end;

procedure TGfx.Start(ADC: HDC; AW, AH: Integer; AOpaque: Boolean);
var
  R: TRect;
  DCRT: ID2D1DCRenderTarget;
begin
  DCRT := nil;
  FOpaque := AOpaque;
  FM := D2DIdentity;
  if AOpaque and not SharedBusy then
  begin
    if SharedRT = nil then
    begin
      SharedRT := NewTarget(True, GfxTargetKind);
      Inc(NextTargetId);
      SharedId := NextTargetId;
    end;
    if SharedRT <> nil then
    begin
      DCRT := SharedRT;
      FRT := SharedRT;
      FTargetId := SharedId;
      FShared := True;
      SharedBusy := True;
    end;
  end;
  if FRT = nil then
  begin
    { a picture with alpha, or a paint inside a paint }
    FOwnRT := NewTarget(AOpaque, D2D1_RENDER_TARGET_TYPE_SOFTWARE);
    DCRT := FOwnRT;
    FRT := FOwnRT;
    Inc(NextTargetId);
    FTargetId := NextTargetId;
  end;
  if FRT = nil then Exit;
  R := Rect(0, 0, AW, AH);
  if DCRT.BindDC(ADC, R) <> S_OK then
  begin
    if FShared then SharedBusy := False;
    FShared := False;
    FRT := nil;
    Exit;
  end;
  FRT.BeginDraw;
  FDrawing := True;
  if not OpenBrush then Exit;
  FRT.SetTransform(FM);
  FRT.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  { on a window: as Windows is set (ClearType or greyscale); with alpha only
    greyscale works }
  if AOpaque then FRT.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_DEFAULT)
  else FRT.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
end;

procedure TGfx.Finish;
var
  HR: HRESULT;
begin
  if not FDrawing then Exit;
  FDrawing := False;
  PopClips(0);
  FBrush := nil;
  HR := FRT.EndDraw(nil, nil);
  if FBroken and (HR = S_OK) then HR := E_FAIL;
  if FWinTarget <> nil then
  begin
    if GfxTestLoseEvery > 0 then
    begin
      Inc(TestPaints);
      if TestPaints mod GfxTestLoseEvery = 0 then HR := D2DERR_RECREATE_TARGET;
    end;
    if HR = S_OK then FWinTarget.FLosses := 0
    else
    begin
      { lost (the graphics driver was restarted, the screen went away ...):
        a new target at the next paint; after three in a row this window
        paints through the buffer for a while (GiveUp) }
      FWinTarget.Release;
      Inc(FWinTarget.FLosses);
      if FWinTarget.FLosses >= 3 then FWinTarget.GiveUp;
      TargetLost := True;
    end;
  end;
  if FShared then
  begin
    SharedBusy := False;
    if HR = D2DERR_RECREATE_TARGET then
    begin
      { the graphics driver was restarted: a new target at the next paint
        (the bitmaps follow, they belong to a target) }
      SharedRT := nil;
      TargetLost := True;
    end;
  end;
  FRT := nil;
  FOwnRT := nil;
end;

constructor TGfx.Create(DC: HDC; AWidth, AHeight: Integer);
begin
  inherited Create;
  Start(DC, AWidth, AHeight, True);
end;

{ TGfxWindowTarget }

function TGfxWindowTarget.BeginPaint(AWnd: HWND; AWidth, AHeight: Integer): TGfx;
var
  P: TD2DRenderTargetProps;
  WP: TD2DHwndTargetProps;
  Sz: TD2DSizeU;
begin
  Result := nil;
  if (AWidth <= 0) or (AHeight <= 0) then Exit;
  if FFailed then
  begin
    { tried again later: a screen that was switched off comes back, a driver
      is installed again }
    if GetTickCount64 - FFailedAt < TARGET_RETRY_MS then Exit;
    FFailed := False;
    FLosses := 0;
  end;
  EnsureFactories;
  if Factory = nil then Exit;
  if (FRT <> nil) and (FWnd <> AWnd) then Release;
  if FRT = nil then
  begin
    FillChar(P, SizeOf(P), 0);
    P.Kind := D2D1_RENDER_TARGET_TYPE_DEFAULT;
    P.PixelFormat.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
    P.PixelFormat.AlphaMode := D2D1_ALPHA_MODE_IGNORE;
    P.DpiX := 96;
    P.DpiY := 96;
    WP.Wnd := AWnd;
    WP.PixelSize.W := AWidth;
    WP.PixelSize.H := AHeight;
    { at once: waiting for the screen's next refresh would hold up the UI
      thread at every paint }
    WP.PresentOptions := D2D1_PRESENT_OPTIONS_IMMEDIATELY;
    if Factory.CreateHwndRenderTarget(P, WP, FRT) <> S_OK then
    begin
      FRT := nil;
      GiveUp;
      Exit;
    end;
    FWnd := AWnd;
    FW := AWidth;
    FH := AHeight;
    Inc(NextTargetId);
    FId := NextTargetId;
  end
  else if (FW <> AWidth) or (FH <> AHeight) then
  begin
    Sz.W := AWidth;
    Sz.H := AHeight;
    if FRT.Resize(Sz) <> S_OK then
    begin
      Release;
      Exit(BeginPaint(AWnd, AWidth, AHeight));
    end;
    FW := AWidth;
    FH := AHeight;
  end;
  Result := TGfx.CreateOnWindow(Self);
end;

procedure TGfxWindowTarget.GiveUp;
begin
  FFailed := True;
  FFailedAt := GetTickCount64;
end;

procedure TGfxWindowTarget.Release;
begin
  FRT := nil;
  FWnd := 0;
end;

constructor TGfx.CreateOnWindow(ATarget: TGfxWindowTarget);
begin
  inherited Create;
  FWinTarget := ATarget;
  FOpaque := True;
  FM := D2DIdentity;
  FRT := ATarget.FRT;
  FTargetId := ATarget.FId;
  FRT.BeginDraw;
  FDrawing := True;
  if not OpenBrush then Exit;
  FRT.SetTransform(FM);
  FRT.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  FRT.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_DEFAULT);
end;

constructor TGfx.CreateBitmap(AWidth, AHeight: Integer; AOpaque: Boolean);
var
  BI: TBitmapInfo;
begin
  inherited Create;
  FW := Max(1, AWidth);
  FH := Max(1, AHeight);
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := FW;
  BI.bmiHeader.biHeight := -FH;
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  FDC := CreateCompatibleDC(0);
  FBmp := CreateDIBSection(FDC, BI, DIB_RGB_COLORS, FDibBits, 0, 0);
  if FBmp = 0 then Exit;
  FOldBmp := SelectObject(FDC, FBmp);
  Start(FDC, FW, FH, AOpaque);
  if FDrawing then FRT.Clear(nil);
end;

destructor TGfx.Destroy;
begin
  Finish;
  if FDC <> 0 then
  begin
    if FBmp <> 0 then
    begin
      SelectObject(FDC, FOldBmp);
      DeleteObject(FBmp);
    end;
    DeleteDC(FDC);
  end;
  inherited Destroy;
end;

function TGfx.ToBitmap: TGfxBitmap;
var
  P: PARGB;
  I: Integer;
begin
  Result := nil;
  Finish;
  if (FBmp = 0) or (FDibBits = nil) then Exit;
  GdiFlush;
  Result := TGfxBitmap.Create(FW, FH);
  Move(FDibBits^, Result.Bits^, PtrUInt(FW) * PtrUInt(FH) * 4);
  { an opaque target leaves the alpha bytes as they were: all opaque }
  if FOpaque then
  begin
    P := PARGB(Result.Bits);
    for I := 1 to FW * FH do
    begin
      P^ := P^ or $FF000000;
      Inc(P);
    end;
  end;
end;

{ the one brush of this paint. A target that cannot make it is of no use (a
  graphics device in trouble): nothing is drawn - every drawing routine looks
  at FDrawing -, and the paint counts as lost, so the window is painted again
  with a new target. Without this a nil brush went into Direct2D's calls. }
function TGfx.OpenBrush: Boolean;
var
  Col: TD2DColor;
begin
  Col := ColorF(0);
  FBrush := nil;
  Result := (FRT.CreateSolidColorBrush(Col, nil, FBrush) = S_OK) and (FBrush <> nil);
  if not Result then
  begin
    FBroken := True;
    Finish;
  end;
end;

function TGfx.Brush(C: TARGB): ID2D1Brush;
var
  Col: TD2DColor;
begin
  { (made by OpenBrush: there is one while FDrawing) }
  Col := ColorF(C);
  if FBrush <> nil then FBrush.SetColor(Col);
  Result := FBrush;
end;

function TGfx.GradBrush(X1, Y1, X2, Y2: Single; C1, C2: TARGB): ID2D1Brush;
var
  Stops: array[0..1] of TD2DGradientStop;
  Coll: ID2D1GradientStopCollection;
  LP: TD2DLinearGradientProps;
  LB: ID2D1LinearGradientBrush;
begin
  Result := nil;
  Stops[0].Position := 0;
  Stops[0].Color := ColorF(C1);
  Stops[1].Position := 1;
  Stops[1].Color := ColorF(C2);
  if FRT.CreateGradientStopCollection(@Stops[0], 2, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP, Coll) <> S_OK then Exit;
  LP.StartPoint := D2DPt(X1, Y1);
  LP.EndPoint := D2DPt(X2, Y2);
  if FRT.CreateLinearGradientBrush(LP, nil, Coll, LB) = S_OK then Result := LB;
end;

procedure TGfx.Clear(C: TARGB);
var
  Col: TD2DColor;
begin
  if not FDrawing then Exit;
  Col := ColorF(C);
  FRT.Clear(@Col);
end;

procedure TGfx.FillRect(X, Y, W, H: Single; C: TARGB);
begin
  if (W <= 0) or (H <= 0) or not FDrawing then Exit;
  FRT.FillRectangle(D2DRc(X, Y, W, H), Brush(C));
end;

procedure TGfx.FillRectGrad(X, Y, W, H: Single; X1, Y1, X2, Y2: Single; C1, C2: TARGB);
var
  B: ID2D1Brush;
begin
  if (W <= 0) or (H <= 0) or not FDrawing then Exit;
  B := GradBrush(X1, Y1, X2, Y2, C1, C2);
  if B <> nil then FRT.FillRectangle(D2DRc(X, Y, W, H), B);
end;

procedure TGfx.StrokeRect(X, Y, W, H, LW: Single; C: TARGB);
begin
  if not FDrawing then Exit;
  FRT.DrawRectangle(D2DRc(X + LW / 2, Y + LW / 2, W - LW, H - LW), Brush(C), LW, RoundStroke);
end;

function RoundedOf(X, Y, W, H, R: Single): TD2DRoundedRect;
begin
  if R * 2 > W then R := W / 2;
  if R * 2 > H then R := H / 2;
  if R < 0 then R := 0;
  Result.Rect := D2DRc(X, Y, W, H);
  Result.RadiusX := R;
  Result.RadiusY := R;
end;

procedure TGfx.FillRound(X, Y, W, H, R: Single; C: TARGB);
begin
  if (W <= 0) or (H <= 0) or not FDrawing then Exit;
  if R <= 0.1 then FRT.FillRectangle(D2DRc(X, Y, W, H), Brush(C))
  else FRT.FillRoundedRectangle(RoundedOf(X, Y, W, H, R), Brush(C));
end;

procedure TGfx.StrokeRound(X, Y, W, H, R, LW: Single; C: TARGB);
begin
  if (W <= LW) or (H <= LW) or not FDrawing then Exit;
  if R <= 0.1 then FRT.DrawRectangle(D2DRc(X + LW / 2, Y + LW / 2, W - LW, H - LW), Brush(C), LW, RoundStroke)
  else FRT.DrawRoundedRectangle(RoundedOf(X + LW / 2, Y + LW / 2, W - LW, H - LW, R), Brush(C), LW, RoundStroke);
end;

procedure TGfx.FillRoundGrad(X, Y, W, H, R: Single; C1, C2: TARGB; Diagonal: Boolean);
var
  B: ID2D1Brush;
begin
  if (W <= 0) or (H <= 0) or not FDrawing then Exit;
  if Diagonal then B := GradBrush(X, Y - 1, X + W + 1, Y + H + 1, C1, C2)
  else B := GradBrush(X, Y - 1, X, Y + H + 1, C1, C2);
  if B = nil then Exit;
  if R <= 0.1 then FRT.FillRectangle(D2DRc(X, Y, W, H), B)
  else FRT.FillRoundedRectangle(RoundedOf(X, Y, W, H, R), B);
end;

procedure TGfx.FillCircle(CX, CY, R: Single; C: TARGB);
var
  E: TD2DEllipse;
begin
  if not FDrawing then Exit;
  E.Center := D2DPt(CX, CY);
  E.RadiusX := R;
  E.RadiusY := R;
  FRT.FillEllipse(E, Brush(C));
end;

procedure TGfx.StrokeCircle(CX, CY, R, LW: Single; C: TARGB);
var
  E: TD2DEllipse;
begin
  if not FDrawing then Exit;
  E.Center := D2DPt(CX, CY);
  E.RadiusX := R;
  E.RadiusY := R;
  FRT.DrawEllipse(E, Brush(C), LW, RoundStroke);
end;

procedure TGfx.Arc(CX, CY, R, StartAngle, Sweep, LW: Single; C: TARGB);
var
  P: TGfxPath;
begin
  if not FDrawing then Exit;
  P := TGfxPath.Create;
  try
    P.AddArc(CX - R, CY - R, R * 2, R * 2, StartAngle, Sweep);
    StrokePath(P, LW, C);
  finally
    P.Free;
  end;
end;

procedure TGfx.Line(X1, Y1, X2, Y2, LW: Single; C: TARGB);
begin
  if not FDrawing then Exit;
  FRT.DrawLine(D2DPt(X1, Y1), D2DPt(X2, Y2), Brush(C), LW, RoundStroke);
end;

procedure TGfx.FillPath(P: TGfxPath; C: TARGB);
var
  Geo: ID2D1Geometry;
begin
  if (P = nil) or not FDrawing then Exit;
  Geo := P.Geometry;
  if Geo <> nil then FRT.FillGeometry(Geo, Brush(C), nil);
end;

procedure TGfx.StrokePath(P: TGfxPath; LW: Single; C: TARGB);
var
  Geo: ID2D1Geometry;
begin
  if (P = nil) or not FDrawing then Exit;
  Geo := P.Geometry;
  if Geo <> nil then FRT.DrawGeometry(Geo, Brush(C), LW, RoundStroke);
end;

procedure TGfx.FillPathGrad(P: TGfxPath; X1, Y1, X2, Y2: Single; C1, C2: TARGB);
var
  Geo: ID2D1Geometry;
  B: ID2D1Brush;
begin
  if (P = nil) or not FDrawing then Exit;
  Geo := P.Geometry;
  B := GradBrush(X1, Y1, X2, Y2, C1, C2);
  if (Geo <> nil) and (B <> nil) then FRT.FillGeometry(Geo, B, nil);
end;

procedure TGfx.StrokePathGrad(P: TGfxPath; LW: Single; X1, Y1, X2, Y2: Single; C1, C2: TARGB);
var
  Geo: ID2D1Geometry;
  B: ID2D1Brush;
begin
  if (P = nil) or not FDrawing then Exit;
  Geo := P.Geometry;
  B := GradBrush(X1, Y1, X2, Y2, C1, C2);
  if (Geo <> nil) and (B <> nil) then FRT.DrawGeometry(Geo, B, LW, RoundStroke);
end;

procedure TGfx.FillPoly(const Pts: array of TGfxPoint; C: TARGB);
var
  P: TGfxPath;
begin
  if (Length(Pts) < 3) or not FDrawing then Exit;
  P := TGfxPath.Create;
  try
    P.AddPolygon(Pts);
    FillPath(P, C);
  finally
    P.Free;
  end;
end;

procedure TGfx.StrokePoly(const Pts: array of TGfxPoint; LW: Single; C: TARGB; Closed: Boolean);
var
  P: TGfxPath;
  I: Integer;
begin
  if (Length(Pts) < 2) or not FDrawing then Exit;
  P := TGfxPath.Create;
  try
    if Closed then P.AddPolygon(Pts)
    else
      for I := 1 to High(Pts) do P.AddLine(Pts[I - 1].X, Pts[I - 1].Y, Pts[I].X, Pts[I].Y);
    StrokePath(P, LW, C);
  finally
    P.Free;
  end;
end;

procedure TGfx.TextW(const S: UnicodeString; X, Y, W, H: Single; F: TGfxFont; C: TARGB;
  HAlign: Integer; VAlign: Integer; Flags: Integer);
const
  SLACK = 1.0;
var
  L: IDWriteTextLayout;
begin
  if (S = '') or (W <= 0) or (H <= 0) or not FDrawing then Exit;
  { a little more room than asked for: a text measured with TextWidth and
    drawn into exactly that width (rounded) must not lose its last letter to
    the ellipsis. The alignment keeps its edge. }
  if Flags and tfWrap = 0 then
    case HAlign of
      1: begin X := X - SLACK / 2; W := W + SLACK; end;
      2: begin X := X - SLACK; W := W + SLACK; end;
    else
      W := W + SLACK;
    end
  else
    H := H + SLACK;
  L := MakeLayout(S, F, W, H, HAlign, VAlign, Flags);
  if L = nil then Exit;
  FRT.DrawTextLayout(D2DPt(X, Y), L, Brush(C), D2D1_DRAW_TEXT_OPTIONS_CLIP or D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
end;

procedure TGfx.Text(const S: string; X, Y, W, H: Single; F: TGfxFont; C: TARGB;
  HAlign: Integer; VAlign: Integer; Flags: Integer);
begin
  TextW(UTF8Decode(S), X, Y, W, H, F, C, HAlign, VAlign, Flags);
end;

procedure TGfx.PushClip(AIsLayer: Boolean);
begin
  if FClipCount >= Length(FClips) then SetLength(FClips, FClipCount + 8);
  FClips[FClipCount].IsLayer := AIsLayer;
  Inc(FClipCount);
end;

procedure TGfx.PopClips(ADownTo: Integer);
begin
  if ADownTo < 0 then ADownTo := 0;
  while FClipCount > ADownTo do
  begin
    Dec(FClipCount);
    if FClips[FClipCount].IsLayer then FRT.PopLayer
    else FRT.PopAxisAlignedClip;
  end;
end;

function TGfx.Save: UINT;
begin
  if FStateCount >= Length(FStates) then SetLength(FStates, FStateCount + 8);
  FStates[FStateCount].Clips := FClipCount;
  FStates[FStateCount].M := FM;
  Inc(FStateCount);
  Result := FStateCount;
end;

procedure TGfx.Restore(State: UINT);
begin
  if (State < 1) or (Integer(State) > FStateCount) then Exit;
  FStateCount := State - 1;
  if FDrawing then PopClips(FStates[FStateCount].Clips);
  FM := FStates[FStateCount].M;
  if FDrawing then FRT.SetTransform(FM);
end;

procedure TGfx.Translate(DX, DY: Single);
begin
  { before what is set already, as the GDI+ call did (only shifts are used) }
  FM.DX := FM.DX + DX * FM.M11 + DY * FM.M21;
  FM.DY := FM.DY + DX * FM.M12 + DY * FM.M22;
  if FDrawing then FRT.SetTransform(FM);
end;

procedure TGfx.IntersectClipRect(X, Y, W, H: Single);
begin
  if not FDrawing then Exit;
  if W < 0 then W := 0;
  if H < 0 then H := 0;
  FRT.PushAxisAlignedClip(D2DRc(X, Y, W, H), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  PushClip(False);
end;

function LayerParams(AMask: ID2D1Geometry; AOpaque: Boolean): TD2DLayerParams;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ContentBounds.Left := -MaxSingle;
  Result.ContentBounds.Top := -MaxSingle;
  Result.ContentBounds.Right := MaxSingle;
  Result.ContentBounds.Bottom := MaxSingle;
  Result.GeometricMask := Pointer(AMask);
  Result.MaskAntialias := D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
  Result.MaskTransform := D2DIdentity;
  Result.Opacity := 1;
  if AOpaque then Result.LayerOptions := D2D1_LAYER_OPTIONS_INITIALIZE_FOR_CLEARTYPE
  else Result.LayerOptions := D2D1_LAYER_OPTIONS_NONE;
end;

procedure TGfx.IntersectClipRound(X, Y, W, H, R: Single);
var
  Geo: ID2D1Geometry;
  Layer: ID2D1Layer;
begin
  if not FDrawing then Exit;
  if (R <= 0.1) or (Factory.CreateRoundedRectangleGeometry(RoundedOf(X, Y, W, H, R), Geo) <> S_OK) or
     (FRT.CreateLayer(nil, Layer) <> S_OK) then
  begin
    IntersectClipRect(X, Y, W, H);
    Exit;
  end;
  FRT.PushLayer(LayerParams(Geo, FOpaque), Layer);
  PushClip(True);
end;

procedure TGfx.ExcludeClipEllipse(X, Y, W, H: Single);
var
  P: TGfxPath;
  Layer: ID2D1Layer;
  Geo: ID2D1Geometry;
begin
  if not FDrawing then Exit;
  { a very large rectangle with the ellipse as a hole (alternate filling) }
  P := TGfxPath.Create;
  try
    P.AddRect(-100000, -100000, 200000, 200000);
    P.AddEllipse(X, Y, W, H);
    Geo := P.Geometry;
    if (Geo <> nil) and (FRT.CreateLayer(nil, Layer) = S_OK) then
    begin
      FRT.PushLayer(LayerParams(Geo, FOpaque), Layer);
      PushClip(True);
    end;
  finally
    P.Free;
  end;
end;

function TGfx.DeviceBitmap(B: TGfxBitmap): ID2D1Bitmap;
var
  BP: TD2DBitmapProps;
  Sz: TD2DSizeU;
begin
  Result := nil;
  if (B = nil) or (B.FBits = nil) or (B.FW <= 0) or (B.FH <= 0) then Exit;
  if (B.FDev = nil) or (B.FDevId <> FTargetId) then
  begin
    B.FDev := nil;
    BP.PixelFormat.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
    BP.PixelFormat.AlphaMode := D2D1_ALPHA_MODE_PREMULTIPLIED;
    BP.DpiX := 96;
    BP.DpiY := 96;
    Sz.W := B.FW;
    Sz.H := B.FH;
    if FRT.CreateBitmap(Sz, B.FBits, B.FW * 4, BP, B.FDev) <> S_OK then B.FDev := nil;
    B.FDevId := FTargetId;
  end;
  Result := B.FDev;
end;

procedure TGfx.DrawBitmap(B: TGfxBitmap; X, Y, W, H: Single; AOpacity: Single);
var
  D: ID2D1Bitmap;
  R: TD2DRect;
begin
  if not FDrawing then Exit;
  D := DeviceBitmap(B);
  if D = nil then Exit;
  R := D2DRc(X, Y, W, H);
  FRT.DrawBitmap(D, @R, AOpacity, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nil);
end;

procedure TGfx.DrawBitmapPart(B: TGfxBitmap; X, Y, W, H, SX, SY, SW, SH: Single; ANearest: Boolean);
var
  D: ID2D1Bitmap;
  R, SR: TD2DRect;
  Mode: UINT;
begin
  if not FDrawing then Exit;
  D := DeviceBitmap(B);
  if D = nil then Exit;
  R := D2DRc(X, Y, W, H);
  SR := D2DRc(SX, SY, SW, SH);
  if ANearest then Mode := D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR
  else Mode := D2D1_BITMAP_INTERPOLATION_MODE_LINEAR;
  FRT.DrawBitmap(D, @R, 1, Mode, @SR);
end;

procedure TGfx.DrawBitmapCover(B: TGfxBitmap; X, Y, W, H, R: Single);
var
  BW, BH: Integer;
  SX, SY, SW, SH, K: Single;
  D: ID2D1Bitmap;
  BB: TD2DBitmapBrushProps;
  BP: TD2DBrushProps;
  Br: ID2D1BitmapBrush;
begin
  if not FDrawing or not BitmapSize(B, BW, BH) or (W <= 0) or (H <= 0) then Exit;
  K := W / H;
  if BW / BH > K then
  begin
    SH := BH; SW := BH * K;
    SX := (BW - SW) / 2; SY := 0;
  end
  else
  begin
    SW := BW; SH := BW / K;
    SX := 0; SY := (BH - SH) / 2;
  end;
  if R <= 0.1 then
  begin
    DrawBitmapPart(B, X, Y, W, H, SX, SY, SW, SH);
    Exit;
  end;
  { rounded: the picture as the paint of a rounded rectangle }
  D := DeviceBitmap(B);
  if D = nil then Exit;
  BB.ExtendX := D2D1_EXTEND_MODE_CLAMP;
  BB.ExtendY := D2D1_EXTEND_MODE_CLAMP;
  BB.Interpolation := D2D1_BITMAP_INTERPOLATION_MODE_LINEAR;
  K := W / SW;
  BP.Opacity := 1;
  BP.Transform := D2DIdentity;
  BP.Transform.M11 := K;
  BP.Transform.M22 := H / SH;
  BP.Transform.DX := X - SX * K;
  BP.Transform.DY := Y - SY * (H / SH);
  if FRT.CreateBitmapBrush(D, @BB, @BP, Br) <> S_OK then Exit;
  FRT.FillRoundedRectangle(RoundedOf(X, Y, W, H, R), Br);
end;

{ picture files (WIC) }

function WicFactory: IWICImagingFactory;
begin
  Result := nil;
  if not ComReady then
  begin
    { a thread that has no COM yet gets it, and keeps it }
    CoInitializeEx(nil, COINIT_MULTITHREADED);
    ComReady := True;
  end;
  if CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER, IID_IWICImagingFactory, Result) <> S_OK then
    Result := nil;
end;

function ImagePixelsAllowed(W, H: Integer): Boolean;
begin
  Result := (W > 0) and (H > 0) and (Int64(W) * H <= MAX_IMAGE_PIXELS);
end;

function IsIndexedFormat(const G: TGUID): Boolean;
begin
  { 1, 2, 4, 8 bit palette and black / white: ...C901 to ...C905 }
  Result := (G.D1 = GUID_WICPixelFormat8bppIndexed.D1) and (G.D2 = GUID_WICPixelFormat8bppIndexed.D2) and
    (G.D3 = GUID_WICPixelFormat8bppIndexed.D3) and CompareMem(@G.D4[0], @GUID_WICPixelFormat8bppIndexed.D4[0], 7) and
    (G.D4[7] >= 1) and (G.D4[7] <= 5);
end;

{ the first frame of the picture in the stream; nil when it is no picture }
function FrameOf(AFactory: IWICImagingFactory; AStream: IStream): IWICBitmapFrameDecode;
var
  Dec: IWICBitmapDecoder;
begin
  Result := nil;
  if AFactory.CreateDecoderFromStream(AStream, nil, WICDecodeMetadataCacheOnDemand, Dec) <> S_OK then Exit;
  if Dec.GetFrame(0, Result) <> S_OK then Result := nil;
end;

function MemoryStream(AFactory: IWICImagingFactory; const Data: TBytes): IStream;
var
  S: IWICStream;
begin
  Result := nil;
  if Length(Data) < 8 then Exit;
  if AFactory.CreateStream(S) <> S_OK then Exit;
  if S.InitializeFromMemory(@Data[0], Length(Data)) = S_OK then Result := S;
end;

{ the source as a bitmap of at most MaxSide (0: as it is) }
function BitmapFromSource(AFactory: IWICImagingFactory; ASrc: IWICBitmapSource; MaxSide: Integer): TGfxBitmap;
var
  UW, UH: UINT;
  W, H, NW, NH: Integer;
  K: Double;
  Fmt: TGUID;
  Conv: IWICFormatConverter;
  Scaler: IWICBitmapScaler;
  Cur: IWICBitmapSource;
  ScaleFirst: Boolean;

  function Convert(ASource: IWICBitmapSource): IWICBitmapSource;
  begin
    Result := nil;
    Conv := nil;
    if AFactory.CreateFormatConverter(Conv) <> S_OK then Exit;
    if Conv.Initialize(ASource, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nil, 0,
         WICBitmapPaletteTypeCustom) = S_OK then Result := Conv;
  end;

  function Scale(ASource: IWICBitmapSource): IWICBitmapSource;
  begin
    Result := nil;
    Scaler := nil;
    if AFactory.CreateBitmapScaler(Scaler) <> S_OK then Exit;
    if Scaler.Initialize(ASource, NW, NH, WICBitmapInterpolationModeFant) = S_OK then Result := Scaler;
  end;

begin
  Result := nil;
  if (ASrc = nil) or (ASrc.GetSize(UW, UH) <> S_OK) then Exit;
  W := UW;
  H := UH;
  { ---> AulumicNS: the size is known from the header; copying the pixels
    below is what decodes the picture (a 20000 x 20000 px scan: 1.6 GB) }
  if not ImagePixelsAllowed(W, H) then Exit;
  NW := W;
  NH := H;
  if (MaxSide > 0) and (Max(W, H) > MaxSide) then
  begin
    K := MaxSide / Max(W, H);
    NW := Max(1, Round(W * K));
    NH := Max(1, Round(H * K));
  end;
  if (NW = W) and (NH = H) then Cur := Convert(ASrc)
  else
  begin
    { scaling first lets a JPEG decode at a smaller size; a palette picture
      is converted first (scaled as it is, it would not be smoothed) }
    ScaleFirst := (ASrc.GetPixelFormat(Fmt) = S_OK) and not IsIndexedFormat(Fmt);
    Cur := nil;
    if ScaleFirst then
    begin
      Cur := Scale(ASrc);
      if Cur <> nil then Cur := Convert(Cur);
    end;
    if Cur = nil then
    begin
      Cur := Convert(ASrc);
      if Cur <> nil then Cur := Scale(Cur);
    end;
  end;
  if Cur = nil then Exit;
  Result := TGfxBitmap.Create(NW, NH);
  if Cur.CopyPixels(nil, NW * 4, UINT(NW) * UINT(NH) * 4, Result.Bits) <> S_OK then FreeAndNil(Result);
end;

function PropVariantClear(var AValue: TWicPropVariant): HRESULT; stdcall; external 'ole32.dll';

{ ---> AulumicNS: how a photo is to be turned to stand upright - the
  orientation a camera or phone wrote into the file (Exif tag 274): 1 = as
  stored, 2..8 = mirrored / turned. The decoder of Windows hands out the
  pixels as stored; Explorer and the photo viewer turn them, so do we. }
function FrameOrientation(AFrame: IWICBitmapFrameDecode): Integer;
const
  VT_UI2 = 18;
  NAMES: array[0..1] of WideString = ('/app1/ifd/{ushort=274}', '/ifd/{ushort=274}');   // JPEG, TIFF
var
  R: IWICMetadataQueryReader;
  V: TWicPropVariant;
  I: Integer;
begin
  Result := 1;
  R := nil;
  if (AFrame = nil) or (AFrame.GetMetadataQueryReader(R) <> S_OK) or (R = nil) then Exit;
  for I := 0 to High(NAMES) do
  begin
    V := Default(TWicPropVariant);
    if R.GetMetadataByName(PWideChar(NAMES[I]), V) = S_OK then
    begin
      if (V.vt = VT_UI2) and (V.uiVal >= 1) and (V.uiVal <= 8) then Result := V.uiVal;
      PropVariantClear(V);
      Exit;
    end;
  end;
end;

{ B as the orientation AOrient says (see FrameOrientation); B is freed when a
  new bitmap is returned. The pixels are in memory already, so this is a plain
  copy (the flip / rotate stage of WIC decodes a picture again for every column
  of a quarter turn). }
function OrientedBitmap(B: TGfxBitmap; AOrient: Integer): TGfxBitmap;
var
  W, H, X, Y, NX, NY: Integer;
  Src, Dst: PARGB;
begin
  Result := B;
  if (B = nil) or (AOrient < 2) or (AOrient > 8) then Exit;
  W := B.Width;
  H := B.Height;
  if AOrient >= 5 then Result := TGfxBitmap.Create(H, W)
  else Result := TGfxBitmap.Create(W, H);
  for Y := 0 to H - 1 do
  begin
    Src := B.Row(Y);
    for X := 0 to W - 1 do
    begin
      case AOrient of
        2: begin NX := W - 1 - X; NY := Y; end;            // mirrored left / right
        3: begin NX := W - 1 - X; NY := H - 1 - Y; end;    // upside down
        4: begin NX := X; NY := H - 1 - Y; end;            // mirrored top / bottom
        5: begin NX := Y; NY := X; end;                    // mirrored along the diagonal
        6: begin NX := H - 1 - Y; NY := X; end;            // a quarter turn clockwise
        7: begin NX := H - 1 - Y; NY := W - 1 - X; end;    // the other diagonal
      else
        begin NX := Y; NY := W - 1 - X; end;               // 8: a quarter turn anticlockwise
      end;
      Dst := Result.Row(NY);
      Dst[NX] := Src[X];
    end;
  end;
  B.Free;
end;

function ImageFromBytes(const Data: TBytes; MaxSide: Integer): TGfxBitmap;
var
  F: IWICImagingFactory;
  Stm: IStream;
  Frame: IWICBitmapFrameDecode;
begin
  Result := nil;
  try
    F := WicFactory;
    if F = nil then Exit;
    Stm := MemoryStream(F, Data);
    if Stm = nil then Exit;
    Frame := FrameOf(F, Stm);
    Result := OrientedBitmap(BitmapFromSource(F, Frame, MaxSide), FrameOrientation(Frame));
  except
    FreeAndNil(Result);
  end;
end;

function ImageSizeFromBytes(const Data: TBytes; out W, H: Integer): Boolean;
var
  F: IWICImagingFactory;
  Stm: IStream;
  Frame: IWICBitmapFrameDecode;
  UW, UH: UINT;
begin
  W := 0;
  H := 0;
  Result := False;
  try
    F := WicFactory;
    if F = nil then Exit;
    Stm := MemoryStream(F, Data);
    if Stm = nil then Exit;
    Frame := FrameOf(F, Stm);
    if (Frame = nil) or (Frame.GetSize(UW, UH) <> S_OK) then Exit;
    W := UW;
    H := UH;
    { a photo that is shown turned by a quarter (see FrameOrientation) }
    if FrameOrientation(Frame) >= 5 then
    begin
      W := UH;
      H := UW;
    end;
    Result := (W > 0) and (H > 0);
  except
    Result := False;
  end;
end;

{ ---> AulumicNS: the whole file (\\?\ form for a path of 260 characters and
  more); nil when it cannot be read or is larger than AMaxBytes }
function ReadLongPathFile(const FileName: string; AMaxBytes: Int64): TBytes;
var
  FS: TFileStream;
begin
  Result := nil;
  try
    FS := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);
    try
      if (FS.Size > 0) and (FS.Size <= AMaxBytes) then
      begin
        SetLength(Result, FS.Size);
        FS.ReadBuffer(Result[0], Length(Result));
      end;
    finally
      FS.Free;
    end;
  except
    Result := nil;
  end;
end;

const
  IMAGE_FILE_MAX = 256 * 1024 * 1024;

{ a picture file is read into memory and decoded from there: the file is
  closed again at once, and a path of any length works }
function ImageSizeFromFile(const FileName: string; out W, H: Integer): Boolean;
begin
  Result := ImageSizeFromBytes(ReadLongPathFile(FileName, IMAGE_FILE_MAX), W, H);
end;

function ImageFromFile(const FileName: string; MaxSide: Integer): TGfxBitmap;
begin
  Result := ImageFromBytes(ReadLongPathFile(FileName, IMAGE_FILE_MAX), MaxSide);
end;

function ScaledCopy(Src: TGfxBitmap; MaxSide: Integer): TGfxBitmap;
var
  F: IWICImagingFactory;
  WB: IWICBitmap;
begin
  Result := nil;
  if (Src = nil) or (Src.Width <= 0) or (Src.Height <= 0) then Exit;
  if (MaxSide <= 0) or (Max(Src.Width, Src.Height) <= MaxSide) then Exit(CloneBitmap(Src));
  try
    F := WicFactory;
    if F = nil then Exit;
    if F.CreateBitmapFromMemory(Src.Width, Src.Height, GUID_WICPixelFormat32bppPBGRA, Src.Stride,
         UINT(Src.Stride) * UINT(Src.Height), Src.Bits, WB) <> S_OK then Exit;
    Result := BitmapFromSource(F, WB, MaxSide);
  except
    FreeAndNil(Result);
  end;
end;

function BitmapToBytes(B: TGfxBitmap; AJpeg: Boolean): TBytes;
var
  F: IWICImagingFactory;
  Mem: IStream;
  Enc: IWICBitmapEncoder;
  Frame: IWICBitmapFrameEncode;
  WB: IWICBitmap;
  Conv: IWICFormatConverter;
  Fmt: TGUID;
  Stat: TStatStg;
  Pos: QWord;
  Got: DWORD;
  Ok: Boolean;
begin
  Result := nil;
  if (B = nil) or (B.Width <= 0) or (B.Height <= 0) then Exit;
  try
    F := WicFactory;
    if F = nil then Exit;
    if CreateStreamOnHGlobal(0, True, Mem) <> S_OK then Exit;
    if AJpeg then Ok := F.CreateEncoder(GUID_ContainerFormatJpeg, nil, Enc) = S_OK
    else Ok := F.CreateEncoder(GUID_ContainerFormatPng, nil, Enc) = S_OK;
    if not Ok or (Enc.Initialize(Mem, WICBitmapEncoderNoCache) <> S_OK) then Exit;
    if (Enc.CreateNewFrame(Frame, nil) <> S_OK) or (Frame.Initialize(nil) <> S_OK) then Exit;
    if Frame.SetSize(B.Width, B.Height) <> S_OK then Exit;
    { JPEG: 24 bit; PNG: 32 bit with plain alpha. The encoder is asked, the
      pixels are converted to what it takes. }
    if AJpeg then Fmt := GUID_WICPixelFormat24bppBGR else Fmt := GUID_WICPixelFormat32bppBGRA;
    if Frame.SetPixelFormat(Fmt) <> S_OK then Exit;
    if F.CreateBitmapFromMemory(B.Width, B.Height, GUID_WICPixelFormat32bppPBGRA, B.Stride,
         UINT(B.Stride) * UINT(B.Height), B.Bits, WB) <> S_OK then Exit;
    if (F.CreateFormatConverter(Conv) <> S_OK) or
       (Conv.Initialize(WB, Fmt, WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom) <> S_OK) then Exit;
    if (Frame.WriteSource(Conv, nil) <> S_OK) or (Frame.Commit <> S_OK) or (Enc.Commit <> S_OK) then Exit;
    if (Mem.Stat(Stat, STATFLAG_NONAME) <> S_OK) or (Stat.cbSize <= 0) or (Stat.cbSize > High(Integer)) then Exit;
    SetLength(Result, Stat.cbSize);
    Pos := 0;
    Mem.Seek(0, STREAM_SEEK_SET, Pos);
    Got := 0;
    if (Mem.Read(@Result[0], Length(Result), @Got) <> S_OK) or (Got <> DWORD(Length(Result))) then Result := nil;
  except
    Result := nil;
  end;
end;

function SaveBytes(const Data: TBytes; const FileName: string): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  if Length(Data) = 0 then Exit;
  try
    FS := TFileStream.Create(LongPath(FileName), fmCreate);
    try
      FS.WriteBuffer(Data[0], Length(Data));
      Result := True;
    finally
      FS.Free;
    end;
  except
    Result := False;
  end;
end;

function SaveBitmapJpeg(B: TGfxBitmap; const FileName: string): Boolean;
begin
  Result := SaveBytes(BitmapToBytes(B, True), FileName);
end;

function SaveBitmapPng(B: TGfxBitmap; const FileName: string): Boolean;
begin
  Result := SaveBytes(BitmapToBytes(B, False), FileName);
end;

function BitmapToIcon(B: TGfxBitmap): HICON;
var
  BI: TBitmapInfo;
  DC: HDC;
  Color, Mask: HBITMAP;
  Bits: Pointer;
  Info: TIconInfo;
  X, Y: Integer;
  Src, Dst: PARGB;
begin
  Result := 0;
  if (B = nil) or (B.Width <= 0) or (B.Height <= 0) then Exit;
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := B.Width;
  BI.bmiHeader.biHeight := -B.Height;
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  DC := GetDC(0);
  Bits := nil;
  Color := CreateDIBSection(DC, BI, DIB_RGB_COLORS, Bits, 0, 0);
  ReleaseDC(0, DC);
  if (Color = 0) or (Bits = nil) then Exit;
  { an icon's colours are not multiplied by alpha }
  for Y := 0 to B.Height - 1 do
  begin
    Src := B.Row(Y);
    Dst := PARGB(PByte(Bits) + PtrUInt(Y) * PtrUInt(B.Width) * 4);
    for X := 0 to B.Width - 1 do
    begin
      Dst^ := StraightPixel(Src^);
      Inc(Src);
      Inc(Dst);
    end;
  end;
  Mask := Windows.CreateBitmap(B.Width, B.Height, 1, 1, nil);
  FillChar(Info, SizeOf(Info), 0);
  Info.fIcon := True;
  Info.hbmColor := Color;
  Info.hbmMask := Mask;
  Result := CreateIconIndirect(@Info);
  DeleteObject(Color);
  DeleteObject(Mask);
end;

procedure StartGfx;
begin
  Fonts := TList.Create;
end;

procedure StopGfx;
var
  I: Integer;
begin
  Stopped := True;
  for I := 0 to Fonts.Count - 1 do TGfxFont(Fonts[I]).Free;
  FreeAndNil(Fonts);
  SharedRT := nil;
  RoundStroke := nil;
  DWrite := nil;
  { the Direct2D factory is NOT released: it stays until the process ends.
    Direct2D shares its graphics device with other users in the process -
    the PDF engine of Windows (the booklet viewer) is one. With our factory
    gone that engine made a new device in its exit handler, while its DLL
    was being unloaded, and Windows raised an exception there (exit code
    C0000005 after everything was done; found with --shots and a library). }
  Pointer(Factory) := nil;
end;

initialization
  StartGfx;

finalization
  StopGfx;

end.
