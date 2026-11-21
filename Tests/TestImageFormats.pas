unit TestImageFormats;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestImageFormats
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The picture loader (AuGfx.ImageFromBytes, on the Windows
  Imaging Component) with the kinds of picture a cover or an artist picture
  can be, beyond the plain 24 bit JPEG: a greyscale JPEG, a CMYK JPEG (covers
  taken from print files), a PNG with 16 bits per channel, a PNG with
  transparency, a BMP. Each must come out as a 32 bit bitmap of the right
  size and colour. A damaged or cut-off file, or bytes that are no picture,
  must give nil (or a picture) without an exception.

  The test pictures are written here with WIC's encoders: a 16 x 12 picture
  of one colour.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestImageFormats = class(TTestCase)
  published
    procedure AGreyscaleJpegIsDecoded;
    procedure ACmykJpegIsDecoded;
    procedure APngWith16BitsPerChannelIsDecoded;
    procedure APngWithTransparencyKeepsItsAlpha;
    procedure ABmpIsDecoded;
    procedure ScalingAPictureDownKeepsItsColour;
    procedure ACutOffPictureRaisesNothing;
    procedure BytesThatAreNoPictureGiveNil;
    procedure APictureGoesThroughJpegAndPngAndBack;
    // a photo with the orientation a camera or phone wrote (Exif 274)
    procedure APhotoIsTurnedAsItsOrientationSays;
    procedure APhotoTurnedByAQuarterReportsItsShownSize;
    procedure AScaledPhotoIsTurnedToo;
  end;

  { the picture files the program writes (uMetaUtils, with
    WIC): the album thumbnail and the downloaded artist
    picture }
  TTestPictureFiles = class(TTestCase)
  private
    FDir, FOldThumbs: string;
    function WritePicture(const AName: string; W, H: Integer; AJpeg: Boolean): string;
    function Thumbnail(W, H: Integer): TObject;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ASquareCoverFillsTheThumbnail;
    procedure ANearlySquareCoverFillsTheThumbnail;
    procedure AWideCoverKeepsItsProportionsOnBlack;
    procedure ASmallCoverIsEnlarged;
    procedure ALargeArtistPictureIsReduced;
    procedure ASmallJpegIsLeftAsItIs;
    procedure APngUnderAJpegNameBecomesAJpeg;
    procedure AFileThatIsNoPictureIsRefused;
  end;

implementation

uses
  Windows, ActiveX, AuD2D, AuGfx, FileUtil, uAppConsts, uMetaUtils, ALMetadata;

const
  IID_Factory: TGUID = '{EC5EC8A9-C395-4314-9C77-54D7A935FF70}';
  FMT_8GRAY: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC908}';
  FMT_32CMYK: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC91C}';
  FMT_48RGB: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC915}';
  FMT_32BGRA: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC90F}';
  FMT_24BGR: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC90C}';
  CONTAINER_BMP: TGUID = '{0AF1D87E-FCFE-4188-BDEB-A7906471CBE3}';
  PW = 16;
  PH = 12;

{ a picture file of PW x PH in memory: every pixel is APixel (ABytesPer bytes
  in the pixel format AFormat); nil when the encoder does not take it }
function MakePicture(const AContainer, AFormat: TGUID; const APixel: array of Byte): TBytes;
var
  F: IWICImagingFactory;
  Mem: IStream;
  Enc: IWICBitmapEncoder;
  Frame: IWICBitmapFrameEncode;
  Fmt: TGUID;
  Pix: TBytes;
  I, J, N, Stride: Integer;
  HG: HGLOBAL;
  P: Pointer;
begin
  Result := nil;
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  if CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER, IID_Factory, F) <> S_OK then Exit;
  if CreateStreamOnHGlobal(0, True, Mem) <> S_OK then Exit;
  if F.CreateEncoder(AContainer, nil, Enc) <> S_OK then Exit;
  if Enc.Initialize(Mem, WICBitmapEncoderNoCache) <> S_OK then Exit;
  if (Enc.CreateNewFrame(Frame, nil) <> S_OK) or (Frame.Initialize(nil) <> S_OK) then Exit;
  if Frame.SetSize(PW, PH) <> S_OK then Exit;
  Fmt := AFormat;
  if (Frame.SetPixelFormat(Fmt) <> S_OK) or not CompareMem(@Fmt, @AFormat, SizeOf(TGUID)) then Exit;
  N := Length(APixel);
  Stride := PW * N;
  Pix := nil;
  SetLength(Pix, Stride * PH);
  for I := 0 to PW * PH - 1 do
    for J := 0 to N - 1 do Pix[I * N + J] := APixel[J];
  if Frame.WritePixels(PH, Stride, Length(Pix), @Pix[0]) <> S_OK then Exit;
  if (Frame.Commit <> S_OK) or (Enc.Commit <> S_OK) then Exit;
  if GetHGlobalFromStream(Mem, HG) <> S_OK then Exit;
  N := GlobalSize(HG);
  if N <= 0 then Exit;
  SetLength(Result, N);
  P := GlobalLock(HG);
  if P <> nil then Move(P^, Result[0], N);
  GlobalUnlock(HG);
end;

{ the middle pixel of a bitmap (alpha, red, green, blue as stored: multiplied by alpha) }
procedure MiddleOf(B: TGfxBitmap; out A, R, G, Bl: Integer);
var
  P: TARGB;
begin
  P := B.Row(B.Height div 2)[B.Width div 2];
  A := (P shr 24) and $FF;
  R := (P shr 16) and $FF;
  G := (P shr 8) and $FF;
  Bl := P and $FF;
end;

procedure TTestImageFormats.AGreyscaleJpegIsDecoded;
var
  Data: TBytes;
  B: TGfxBitmap;
  A, R, G, Bl: Integer;
begin
  Data := MakePicture(GUID_ContainerFormatJpeg, FMT_8GRAY, [128]);
  AssertTrue('The test picture was written', Length(Data) > 0);
  B := ImageFromBytes(Data, 0);
  try
    AssertNotNull('Decoded', B);
    AssertEquals('Width', PW, B.Width);
    AssertEquals('Height', PH, B.Height);
    MiddleOf(B, A, R, G, Bl);
    AssertEquals('Opaque', 255, A);
    AssertTrue(Format('Mid grey (%d %d %d)', [R, G, Bl]), (Abs(R - 128) <= 6) and (Abs(G - 128) <= 6) and (Abs(Bl - 128) <= 6));
  finally
    B.Free;
  end;
end;

procedure TTestImageFormats.ACmykJpegIsDecoded;
var
  Data: TBytes;
  B: TGfxBitmap;
  A, R, G, Bl: Integer;
begin
  { no cyan, full magenta and yellow, no black: red }
  Data := MakePicture(GUID_ContainerFormatJpeg, FMT_32CMYK, [0, 255, 255, 0]);
  AssertTrue('The test picture was written', Length(Data) > 0);
  B := ImageFromBytes(Data, 0);
  try
    AssertNotNull('A CMYK JPEG is decoded (covers taken from print files are CMYK)', B);
    AssertEquals('Width', PW, B.Width);
    MiddleOf(B, A, R, G, Bl);
    AssertEquals('Opaque', 255, A);
    AssertTrue(Format('Red (%d %d %d)', [R, G, Bl]), (R > 180) and (G < 90) and (Bl < 90));
  finally
    B.Free;
  end;
end;

procedure TTestImageFormats.APngWith16BitsPerChannelIsDecoded;
var
  Data: TBytes;
  B: TGfxBitmap;
  A, R, G, Bl: Integer;
begin
  { 48 bit: red, green, blue as 16 bit words - red }
  Data := MakePicture(GUID_ContainerFormatPng, FMT_48RGB, [$FF, $FF, 0, 0, 0, 0]);
  AssertTrue('The test picture was written', Length(Data) > 0);
  B := ImageFromBytes(Data, 0);
  try
    AssertNotNull('Decoded', B);
    MiddleOf(B, A, R, G, Bl);
    AssertEquals('Opaque', 255, A);
    AssertTrue(Format('Red (%d %d %d)', [R, G, Bl]), (R > 250) and (G < 5) and (Bl < 5));
  finally
    B.Free;
  end;
end;

procedure TTestImageFormats.APngWithTransparencyKeepsItsAlpha;
var
  Data: TBytes;
  B: TGfxBitmap;
  A, R, G, Bl: Integer;
begin
  { blue, green, red, alpha: white at half opacity }
  Data := MakePicture(GUID_ContainerFormatPng, FMT_32BGRA, [255, 255, 255, 128]);
  AssertTrue('The test picture was written', Length(Data) > 0);
  B := ImageFromBytes(Data, 0);
  try
    AssertNotNull('Decoded', B);
    MiddleOf(B, A, R, G, Bl);
    AssertEquals('The alpha is kept', 128, A);
    { the bitmap holds colours multiplied by alpha (what Direct2D draws) }
    AssertTrue(Format('Multiplied by alpha (%d %d %d)', [R, G, Bl]), (Abs(R - 128) <= 2) and (Abs(G - 128) <= 2) and (Abs(Bl - 128) <= 2));
    AssertEquals('StraightPixel gives the plain colour back', Integer($FF), Integer(StraightPixel(B.Row(0)[0]) and $FF));
  finally
    B.Free;
  end;
end;

procedure TTestImageFormats.ABmpIsDecoded;
var
  Data: TBytes;
  B: TGfxBitmap;
  A, R, G, Bl: Integer;
begin
  Data := MakePicture(CONTAINER_BMP, FMT_24BGR, [200, 100, 50]);
  AssertTrue('The test picture was written', Length(Data) > 0);
  B := ImageFromBytes(Data, 0);
  try
    AssertNotNull('Decoded', B);
    MiddleOf(B, A, R, G, Bl);
    AssertEquals('Opaque', 255, A);
    AssertEquals('Red', 50, R);
    AssertEquals('Green', 100, G);
    AssertEquals('Blue', 200, Bl);
  finally
    B.Free;
  end;
end;

procedure TTestImageFormats.ScalingAPictureDownKeepsItsColour;
var
  Data: TBytes;
  B, C: TGfxBitmap;
  A, R, G, Bl: Integer;
begin
  Data := MakePicture(GUID_ContainerFormatPng, FMT_24BGR, [200, 100, 50]);
  AssertTrue('The test picture was written', Length(Data) > 0);
  B := ImageFromBytes(Data, 8);
  try
    AssertNotNull('Decoded', B);
    AssertEquals('The longer side is the size asked for', 8, B.Width);
    AssertEquals('The other side follows', 6, B.Height);
    MiddleOf(B, A, R, G, Bl);
    AssertTrue(Format('The colour (%d %d %d)', [R, G, Bl]), (Abs(R - 50) <= 2) and (Abs(G - 100) <= 2) and (Abs(Bl - 200) <= 2));
    C := ScaledCopy(B, 4);
    try
      AssertNotNull('A smaller copy', C);
      AssertEquals('Its width', 4, C.Width);
      AssertEquals('Its height', 3, C.Height);
    finally
      C.Free;
    end;
  finally
    B.Free;
  end;
end;

procedure TTestImageFormats.ACutOffPictureRaisesNothing;
var
  Data, Part: TBytes;
  B: TGfxBitmap;
  N, W, H: Integer;
begin
  Data := MakePicture(GUID_ContainerFormatJpeg, FMT_24BGR, [200, 100, 50]);
  AssertTrue('The test picture was written', Length(Data) > 64);
  { the file cut off at several places: nil or a picture, never an exception }
  N := Length(Data);
  while N > 4 do
  begin
    N := N * 2 div 3;
    Part := Copy(Data, 0, N);
    B := ImageFromBytes(Part, 0);
    B.Free;
    ImageSizeFromBytes(Part, W, H);
  end;
  { the middle of the file overwritten }
  Part := Copy(Data, 0, Length(Data));
  FillChar(Part[Length(Part) div 3], Length(Part) div 3, $A5);
  B := ImageFromBytes(Part, 0);
  B.Free;
  AssertTrue('Still here', True);
end;

procedure TTestImageFormats.BytesThatAreNoPictureGiveNil;
var
  Data: TBytes;
  W, H, I: Integer;
begin
  Data := nil;
  AssertNull('Nothing', ImageFromBytes(Data, 0));
  SetLength(Data, 3);
  AssertNull('Three bytes', ImageFromBytes(Data, 0));
  SetLength(Data, 5000);
  for I := 0 to High(Data) do Data[I] := (I * 37 + 11) and $FF;
  AssertNull('Noise', ImageFromBytes(Data, 0));
  AssertFalse('Noise has no size', ImageSizeFromBytes(Data, W, H));
  AssertNull('A file that is not there', ImageFromFile('C:\this\file\is\not\there.jpg', 0));
  AssertNull('No bitmap, no copy', ScaledCopy(nil, 10));
  AssertEquals('No bitmap, no file', 0, Length(BitmapToBytes(nil, True)));
end;

procedure TTestImageFormats.APictureGoesThroughJpegAndPngAndBack;
var
  B, C: TGfxBitmap;
  X, Y, A, R, G, Bl: Integer;
  Data: TBytes;
begin
  B := TGfxBitmap.Create(40, 30);
  try
    for Y := 0 to B.Height - 1 do
      for X := 0 to B.Width - 1 do B.Row(Y)[X] := $FF3264C8;
    Data := BitmapToBytes(B, False);
    AssertTrue('PNG written', Length(Data) > 0);
    C := ImageFromBytes(Data, 0);
    try
      AssertNotNull('PNG read back', C);
      AssertEquals('PNG: the same pixel', Integer($FF3264C8), Integer(C.Row(15)[20]));
    finally
      C.Free;
    end;
    Data := BitmapToBytes(B, True);
    AssertTrue('JPEG written', Length(Data) > 0);
    C := ImageFromBytes(Data, 0);
    try
      AssertNotNull('JPEG read back', C);
      AssertEquals('JPEG: the width', 40, C.Width);
      MiddleOf(C, A, R, G, Bl);
      AssertTrue(Format('JPEG: about the same colour (%d %d %d)', [R, G, Bl]),
        (Abs(R - $32) <= 6) and (Abs(G - $64) <= 6) and (Abs(Bl - $C8) <= 6));
    finally
      C.Free;
    end;
  finally
    B.Free;
  end;
end;

{ a JPEG of 64 x 48 - red at the top left, green at the top right, blue below -
  with the Exif orientation AOrient (0: without the tag) }
function MakePhoto(AOrient: Integer): TBytes;
const
  EXIF: array[0..35] of Byte = (
    $FF, $E1, $00, $22,                         // APP1, 34 bytes
    $45, $78, $69, $66, $00, $00,               // "Exif"
    $49, $49, $2A, $00, $08, $00, $00, $00,     // TIFF, little endian, the IFD at 8
    $01, $00,                                   // one entry
    $12, $01, $03, $00, $01, $00, $00, $00,     // tag 274, a short, one value
    $00, $00, $00, $00,                         // the value (set below)
    $00, $00, $00, $00);                        // no further IFD
var
  B: TGfxBitmap;
  X, Y: Integer;
  J: TBytes;
begin
  B := TGfxBitmap.Create(64, 48);
  try
    for Y := 0 to 47 do
      for X := 0 to 63 do
        if Y >= 24 then B.Row(Y)[X] := $FF0000FF
        else if X < 32 then B.Row(Y)[X] := $FFFF0000
        else B.Row(Y)[X] := $FF00FF00;
    J := BitmapToBytes(B, True);
  finally
    B.Free;
  end;
  if (AOrient = 0) or (Length(J) < 4) then Exit(J);
  SetLength(Result, Length(J) + Length(EXIF));
  Result[0] := J[0];
  Result[1] := J[1];                            // FF D8
  Move(EXIF[0], Result[2], Length(EXIF));
  Result[2 + 28] := AOrient;
  Move(J[2], Result[2 + Length(EXIF)], Length(J) - 2);
end;

{ 'R', 'G' or 'B': the colour at the middle of a quarter of the picture
  (AQuarter: 0 top left, 1 top right, 2 bottom left, 3 bottom right) }
function QuarterColour(B: TGfxBitmap; AQuarter: Integer): Char;
var
  C: TARGB;
  X, Y: Integer;
begin
  X := B.Width div 4;
  Y := B.Height div 4;
  if Odd(AQuarter) then X := B.Width - 1 - X;
  if AQuarter >= 2 then Y := B.Height - 1 - Y;
  C := B.Row(Y)[X];
  if ((C shr 16) and $FF) > 128 then Result := 'R'
  else if ((C shr 8) and $FF) > 128 then Result := 'G'
  else Result := 'B';
end;

function Quarters(B: TGfxBitmap): string;
begin
  Result := QuarterColour(B, 0) + QuarterColour(B, 1) + QuarterColour(B, 2) + QuarterColour(B, 3);
end;

procedure TTestImageFormats.APhotoIsTurnedAsItsOrientationSays;
const
  { top left, top right, bottom left, bottom right - as the photo is to be
    seen (stored: red, green, blue, blue) }
  SHOWN: array[0..8] of string = ('RGBB', 'RGBB', 'GRBB', 'BBGR', 'BBRG', 'RBGB', 'BRBG', 'BGBR', 'GBRB');
var
  O: Integer;
  B: TGfxBitmap;
begin
  for O := 0 to 8 do
  begin
    B := ImageFromBytes(MakePhoto(O), 0);
    try
      AssertNotNull('orientation ' + IntToStr(O) + ' decoded', B);
      if O >= 5 then
      begin
        AssertEquals('orientation ' + IntToStr(O) + ': width', 48, B.Width);
        AssertEquals('orientation ' + IntToStr(O) + ': height', 64, B.Height);
      end
      else
      begin
        AssertEquals('orientation ' + IntToStr(O) + ': width', 64, B.Width);
        AssertEquals('orientation ' + IntToStr(O) + ': height', 48, B.Height);
      end;
      AssertEquals('orientation ' + IntToStr(O) + ': the corners', SHOWN[O], Quarters(B));
    finally
      B.Free;
    end;
  end;
end;

procedure TTestImageFormats.APhotoTurnedByAQuarterReportsItsShownSize;
var
  W, H: Integer;
begin
  AssertTrue('upright', ImageSizeFromBytes(MakePhoto(1), W, H));
  AssertEquals('upright: width', 64, W);
  AssertEquals('upright: height', 48, H);
  AssertTrue('a quarter turn', ImageSizeFromBytes(MakePhoto(6), W, H));
  AssertEquals('a quarter turn: width', 48, W);
  AssertEquals('a quarter turn: height', 64, H);
  AssertTrue('upside down', ImageSizeFromBytes(MakePhoto(3), W, H));
  AssertEquals('upside down: width', 64, W);
end;

procedure TTestImageFormats.AScaledPhotoIsTurnedToo;
var
  B: TGfxBitmap;
begin
  B := ImageFromBytes(MakePhoto(6), 32);
  try
    AssertNotNull('decoded', B);
    AssertEquals('width', 24, B.Width);
    AssertEquals('height', 32, B.Height);
    AssertEquals('the corners', 'BRBG', Quarters(B));
  finally
    B.Free;
  end;
end;

{ ---- TTestPictureFiles ---- }

const
  COVER_COLOUR = $FFC86432;   // the cover: R $C8, G $64, B $32

procedure TTestPictureFiles.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'AulumicNSPictureTest' + PathDelim;
  DeleteDirectory(FDir, False);
  ForceDirectories(FDir + 'Thumbs');
  FOldThumbs := AppCacheThumbsDir;
  AppCacheThumbsDir := FDir + 'Thumbs' + PathDelim;
end;

procedure TTestPictureFiles.TearDown;
begin
  AppCacheThumbsDir := FOldThumbs;
  DeleteDirectory(FDir, False);
end;

function TTestPictureFiles.WritePicture(const AName: string; W, H: Integer; AJpeg: Boolean): string;
var
  B: TGfxBitmap;
  X, Y: Integer;
  Data: TBytes;
  FS: TFileStream;
begin
  Result := FDir + AName;
  B := TGfxBitmap.Create(W, H);
  try
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
        B.Row(Y)[X] := COVER_COLOUR;
    Data := BitmapToBytes(B, AJpeg);
  finally
    B.Free;
  end;
  AssertTrue('test picture written', Length(Data) > 0);
  FS := TFileStream.Create(Result, fmCreate);
  try
    FS.WriteBuffer(Data[0], Length(Data));
  finally
    FS.Free;
  end;
end;

{ the thumbnail of a track whose folder holds a cover of W x H }
function TTestPictureFiles.Thumbnail(W, H: Integer): TObject;
var
  Meta: TAudioMetadata;
begin
  WritePicture('cover.jpg', W, H, True);
  Meta := Default(TAudioMetadata);
  GenerateAndCacheThumbnail(Meta, FDir + 'track.flac', 'thumb', True);
  AssertTrue('thumbnail file written', FileExists(AppCacheThumbsDir + 'thumb.jpg'));
  Result := ImageFromFile(AppCacheThumbsDir + 'thumb.jpg', 0);
  AssertNotNull('thumbnail read back', Result);
  AssertEquals('thumbnail width', CACHE_THUMB_SIZE, TGfxBitmap(Result).Width);
  AssertEquals('thumbnail height', CACHE_THUMB_SIZE, TGfxBitmap(Result).Height);
end;

function IsCover(B: TGfxBitmap; X, Y: Integer): Boolean;
var
  C: TARGB;
begin
  C := B.Row(Y)[X];
  Result := (Abs(Integer((C shr 16) and $FF) - $C8) <= 10) and (Abs(Integer((C shr 8) and $FF) - $64) <= 10) and
    (Abs(Integer(C and $FF) - $32) <= 10);
end;

function IsBlack(B: TGfxBitmap; X, Y: Integer): Boolean;
var
  C: TARGB;
begin
  C := B.Row(Y)[X];
  Result := (((C shr 16) and $FF) <= 10) and (((C shr 8) and $FF) <= 10) and ((C and $FF) <= 10);
end;

procedure TTestPictureFiles.ASquareCoverFillsTheThumbnail;
var
  T: TGfxBitmap;
begin
  T := TGfxBitmap(Thumbnail(600, 600));
  try
    AssertTrue('top left', IsCover(T, 1, 1));
    AssertTrue('bottom right', IsCover(T, CACHE_THUMB_SIZE - 2, CACHE_THUMB_SIZE - 2));
  finally
    T.Free;
  end;
end;

{ 1.5 % from square: filled (the reduced picture is two pixels short of
  square at a size of 128: by whole pixels alone the rule could tip over) }
procedure TTestPictureFiles.ANearlySquareCoverFillsTheThumbnail;
var
  T: TGfxBitmap;
begin
  T := TGfxBitmap(Thumbnail(600, 591));
  try
    AssertTrue('top edge', IsCover(T, CACHE_THUMB_SIZE div 2, 0));
    AssertTrue('bottom edge', IsCover(T, CACHE_THUMB_SIZE div 2, CACHE_THUMB_SIZE - 1));
  finally
    T.Free;
  end;
end;

procedure TTestPictureFiles.AWideCoverKeepsItsProportionsOnBlack;
const
  M = CACHE_THUMB_SIZE div 2;
  Q = CACHE_THUMB_SIZE div 4;
  D = CACHE_THUMB_SIZE div 12;
var
  T: TGfxBitmap;
begin
  T := TGfxBitmap(Thumbnail(800, 400));
  try
    { twice as wide as high: the cover is the middle half of the square.
      M: the middle, Q: a quarter, D: a little way from an edge }
    AssertTrue('black above', IsBlack(T, M, D));
    AssertTrue('black below', IsBlack(T, M, CACHE_THUMB_SIZE - 1 - D));
    AssertTrue('the cover in the middle', IsCover(T, M, M));
    AssertTrue('the cover to the left edge', IsCover(T, 1, M));
    AssertTrue('the cover begins at a quarter', IsCover(T, M, Q + D div 2) and IsBlack(T, M, Q - D div 2));
  finally
    T.Free;
  end;
end;

procedure TTestPictureFiles.ASmallCoverIsEnlarged;
var
  T: TGfxBitmap;
begin
  T := TGfxBitmap(Thumbnail(60, 60));
  try
    AssertTrue('top left', IsCover(T, 1, 1));
    AssertTrue('bottom right', IsCover(T, CACHE_THUMB_SIZE - 2, CACHE_THUMB_SIZE - 2));
  finally
    T.Free;
  end;
end;

procedure TTestPictureFiles.ALargeArtistPictureIsReduced;
var
  F: string;
  W, H: Integer;
begin
  F := WritePicture('artist.jpg', 2000, 1000, True);
  AssertTrue('reduced', DownscaleImageFile(F, 800));
  AssertTrue('still a picture', ImageSizeFromFile(F, W, H));
  AssertEquals('width', 800, W);
  AssertEquals('height', 400, H);
end;

procedure TTestPictureFiles.ASmallJpegIsLeftAsItIs;
var
  F: string;
  Size: Int64;
begin
  F := WritePicture('small.jpg', 300, 200, True);
  Size := FileSize(F);
  AssertTrue('accepted', DownscaleImageFile(F, 800));
  AssertEquals('the file is untouched', Size, FileSize(F));
end;

procedure TTestPictureFiles.APngUnderAJpegNameBecomesAJpeg;
var
  F: string;
  FS: TFileStream;
  Sig: array[0..2] of Byte;
  W, H: Integer;
begin
  F := WritePicture('really-a-png.jpg', 300, 200, False);
  AssertTrue('converted', DownscaleImageFile(F, 800));
  FS := TFileStream.Create(F, fmOpenRead);
  try
    FS.ReadBuffer(Sig, 3);
  finally
    FS.Free;
  end;
  AssertTrue('JPEG data now', (Sig[0] = $FF) and (Sig[1] = $D8) and (Sig[2] = $FF));
  AssertTrue('a picture', ImageSizeFromFile(F, W, H));
  AssertEquals('the same size', 300, W);
end;

procedure TTestPictureFiles.AFileThatIsNoPictureIsRefused;
var
  F: string;
  SL: TStringList;
begin
  F := FDir + 'page.jpg';
  SL := TStringList.Create;
  try
    SL.Text := '<html><body>404 not found, and some more text to fill the file</body></html>';
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  AssertFalse('refused', DownscaleImageFile(F, 800));
  AssertTrue('the file is still there', FileExists(F));
end;

initialization
  RegisterTest(TTestImageFormats);
  RegisterTest(TTestPictureFiles);

end.
