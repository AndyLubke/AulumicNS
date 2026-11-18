unit AuAppIcon;

{ ==============================================================================
  AulumicNS - AuAppIcon
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The application icon: the AulumicNS logo (a golden "A" whose crossbar
  flows out as sound waves, on a dark tile), drawn as vector graphics so it
  is sharp at every size. Used for the window (HICON at the system sizes)
  and written as an .ico file for the executable (AulumicNS.ico, made with
  "AulumicNS.exe --make-icon=<file>" of the debug build; the project embeds
  it). "--icon-preview=<file.png>" writes a 256 px PNG to check the design.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, AuGfx;

function AppIconBitmap(Size: Integer): TGfxBitmap;
function AppIconHandle(Size: Integer): HICON;
{ draws the logo into any graphics (about box, title of the help) }
procedure DrawAppLogo(G: TGfx; X, Y, Size: Single; WithTile: Boolean = True);
{ a multi-size .ico (16 - 256 pixels) with uncompressed 32 bit images: PNG
  compressed entries are fine for Windows but not for the icon reader of the
  LCL, which loads the exe's icon at start }
function SaveAppIconFile(const FileName: string): Boolean;
function SaveAppIconPng(const FileName: string; Size: Integer): Boolean;

implementation

const
  GoldHi = $FFF4DC93;
  GoldLo = $FF9C7329;
  TileHi = $FF34353A;
  TileLo = $FF121214;

const
  { the letter is drawn wider than designed (it would look
    squeezed): its x coordinates are stretched by LOGO_KX (small: by
    LOGO_KX_SMALL) around LOGO_CX and the drawing moves LOGO_SHIFT to the
    left. The waves follow the letter up to WAVE_RIGHT (past the right leg);
    their tail is pressed together to end at WAVE_END instead of 248. }
  LOGO_CX = 120;
  LOGO_KX = 1.2;
  LOGO_KX_SMALL = 1.15;
  LOGO_SHIFT = 8;
  WAVE_RIGHT = 182;
  WAVE_END = 240;

procedure DrawAppLogo(G: TGfx; X, Y, Size: Single; WithTile: Boolean);
var
  U, KX: Single;
  Small: Boolean;
  P: TGfxPath;
  P1, P2: TGfxPoint;
  K, N: Integer;
  O, LW: Single;

  { the letter's x on the design grid, stretched }
  function XL(V: Single): Single;
  begin
    Result := LOGO_CX + (V - LOGO_CX) * KX - LOGO_SHIFT;
  end;

  { a wave's x: as the letter up to WAVE_RIGHT, then the tail pressed }
  function XW(V: Single): Single;
  begin
    if V <= WAVE_RIGHT then Result := XL(V)
    else Result := XL(WAVE_RIGHT) + (V - WAVE_RIGHT) * (WAVE_END - XL(WAVE_RIGHT)) / (248 - WAVE_RIGHT);
  end;

  function PX(V: Single): Single;
  begin
    Result := X + XL(V) * U;
  end;

  function WX(V: Single): Single;
  begin
    Result := X + XW(V) * U;
  end;

  function PY(V: Single): Single;
  begin
    Result := Y + V * U;
  end;

  function Pt(AX, AY: Single): TGfxPoint;
  begin
    Result := GPt(PX(AX), PY(AY));
  end;

begin
  { design grid: 256 x 256 }
  U := Size / 256;
  Small := Size <= 32;
  if Small then KX := LOGO_KX_SMALL else KX := LOGO_KX;
  if WithTile then
  begin
    if Small then G.FillRoundGrad(X, Y, Size, Size, Size * 0.14, TileHi, TileLo, True)
    else G.FillRoundGrad(X + Size / 64, Y + Size / 64, Size - Size / 32, Size - Size / 32, Size * 0.16, TileHi, TileLo, True);
  end;

  { the letter: a thick left leg, a slim right leg, no crossbar }
  { the gold: a gradient across the whole logo }
  P1 := Pt(70, 60);
  P2 := Pt(190, 212);
  P := TGfxPath.Create;
  if Small then
  begin
    P.AddLine(PX(40), PY(220), PX(100), PY(40));
    P.AddLine(PX(100), PY(40), PX(142), PY(40));
    P.AddLine(PX(142), PY(40), PX(198), PY(220));
    P.AddLine(PX(198), PY(220), PX(166), PY(220));
    P.AddLine(PX(166), PY(220), PX(121), PY(88));
    P.AddLine(PX(121), PY(88), PX(88), PY(220));
  end
  else
  begin
    P.AddLine(PX(58), PY(208), PX(106), PY(62));
    P.AddLine(PX(106), PY(62), PX(136), PY(62));
    P.AddLine(PX(136), PY(62), PX(181), PY(208));
    P.AddLine(PX(181), PY(208), PX(162), PY(208));
    P.AddLine(PX(162), PY(208), PX(121), PY(96));
    P.AddLine(PX(121), PY(96), PX(96), PY(208));
  end;
  P.CloseFigure;
  G.FillPathGrad(P, P1.X, P1.Y, P2.X, P2.Y, GoldHi, GoldLo);
  P.Free;

  { the sound waves: strands that leave the left leg where the crossbar
    would be, swing through the right leg and meet in a point }
  if Small then begin N := 2; LW := Max(1.2, 15 * U); end
  else begin N := 4; LW := Max(1.0, 4.2 * U); end;
  begin
    for K := 0 to N - 1 do
    begin
      if Small then O := (K - 0.5) * 26 else O := (K - 1.5) * 15;
      P := TGfxPath.Create;
      { from the left leg up through the right leg }
      P.AddBezier(WX(80), PY(172 + O * 0.3), WX(116), PY(166 + O * 0.8),
        WX(132), PY(104 + O * 1.5), WX(158), PY(110 + O * 1.15));
      { a swing below and back up }
      P.AddBezier(WX(158), PY(110 + O * 1.15), WX(182), PY(116 + O * 1.0),
        WX(184), PY(168 - O * 1.5), WX(204), PY(150 - O * 0.9));
      { narrowing into the point }
      P.AddBezier(WX(204), PY(150 - O * 0.9), WX(216), PY(136 + O * 0.4),
        WX(226), PY(136 + O * 0.1), WX(248), PY(136));
      G.StrokePathGrad(P, LW, P1.X, P1.Y, P2.X, P2.Y, GoldHi, GoldLo);
      P.Free;
    end;
  end;
end;

function AppIconBitmap(Size: Integer): TGfxBitmap;
var
  X: TGfx;
begin
  X := TGfx.CreateBitmap(Size, Size);
  try
    DrawAppLogo(X, 0, 0, Size, True);
    Result := X.ToBitmap;
  finally
    X.Free;
  end;
end;

function AppIconHandle(Size: Integer): HICON;
var
  B: TGfxBitmap;
begin
  Result := 0;
  B := AppIconBitmap(Size);
  if B = nil then Exit;
  Result := BitmapToIcon(B);
  DisposeBitmap(B);
end;

{ an icon image: BITMAPINFOHEADER (double height), BGRA rows bottom up,
  AND mask (all zero: the alpha channel decides) }
function DibBytes(B: TGfxBitmap; Size: Integer): TBytes;
var
  Hdr: TBitmapInfoHeader;
  MaskRow, I, Y, P: Integer;
  Src: PARGB;
  Px: TARGB;
begin
  Result := nil;
  if (B = nil) or (B.Width < Size) or (B.Height < Size) then Exit;
  begin
    MaskRow := ((Size + 31) div 32) * 4;
    FillChar(Hdr, SizeOf(Hdr), 0);
    Hdr.biSize := SizeOf(Hdr);
    Hdr.biWidth := Size;
    Hdr.biHeight := Size * 2;
    Hdr.biPlanes := 1;
    Hdr.biBitCount := 32;
    Hdr.biCompression := BI_RGB;
    Hdr.biSizeImage := Size * Size * 4 + MaskRow * Size;
    SetLength(Result, SizeOf(Hdr) + Size * Size * 4 + MaskRow * Size);
    FillChar(Result[0], Length(Result), 0);
    Move(Hdr, Result[0], SizeOf(Hdr));
    P := SizeOf(Hdr);
    for Y := Size - 1 downto 0 do
    begin
      { an icon's colours are not multiplied by alpha }
      Src := B.Row(Y);
      for I := 0 to Size - 1 do
      begin
        Px := StraightPixel(Src[I]);
        Move(Px, Result[P + I * 4], 4);
      end;
      Inc(P, Size * 4);
    end;
  end;
end;

function SaveAppIconFile(const FileName: string): Boolean;
const
  Sizes: array[0..9] of Integer = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256);
var
  Imgs: array[0..9] of TBytes;
  I: Integer;
  B: TGfxBitmap;
  F: TFileStream;
  Ofs: Cardinal;
  W: Word;
  D: Cardinal;
  By: Byte;
begin
  Result := False;
  for I := 0 to High(Sizes) do
  begin
    B := AppIconBitmap(Sizes[I]);
    if B = nil then Exit;
    Imgs[I] := DibBytes(B, Sizes[I]);
    DisposeBitmap(B);
    if Length(Imgs[I]) = 0 then Exit;
  end;
  F := TFileStream.Create(FileName, fmCreate);
  try
    W := 0; F.WriteBuffer(W, 2);
    W := 1; F.WriteBuffer(W, 2);                  // icon
    W := Length(Sizes); F.WriteBuffer(W, 2);
    Ofs := 6 + 16 * Length(Sizes);
    for I := 0 to High(Sizes) do
    begin
      if Sizes[I] >= 256 then By := 0 else By := Sizes[I];
      F.WriteBuffer(By, 1);                       // width
      F.WriteBuffer(By, 1);                       // height
      By := 0;
      F.WriteBuffer(By, 1);                       // colours
      F.WriteBuffer(By, 1);                       // reserved
      W := 1; F.WriteBuffer(W, 2);                // planes
      W := 32; F.WriteBuffer(W, 2);               // bits
      D := Length(Imgs[I]); F.WriteBuffer(D, 4);
      F.WriteBuffer(Ofs, 4);
      Inc(Ofs, Length(Imgs[I]));
    end;
    for I := 0 to High(Sizes) do F.WriteBuffer(Imgs[I][0], Length(Imgs[I]));
    Result := True;
  finally
    F.Free;
  end;
end;

function SaveAppIconPng(const FileName: string; Size: Integer): Boolean;
var
  B: TGfxBitmap;
begin
  Result := False;
  B := AppIconBitmap(Size);
  if B = nil then Exit;
  Result := SaveBitmapPng(B, FileName);
  DisposeBitmap(B);
end;

end.
