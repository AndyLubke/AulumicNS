unit TestImageLimit;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   AulumicNS - test program
  Unit Name: TestImageLimit

  The size limit of the picture loaders (AuGfx): a cover, an artist picture
  or a folder picture with more than MAX_IMAGE_PIXELS (8192 x 8192) is not
  decoded - ImageFromBytes / ImageFromFile return nil for it - while its size
  can still be read from the header (ImageSizeFromBytes / ImageSizeFromFile),
  so the program can say why nothing is shown.

  The limit counts pixels, not the longer side: a booklet page may be a wide
  fold-out of more than 8192 px (AuBooklet keeps its pages below 20 MP).

  The test pictures are PNG files written here: 1 bit grey, all black. Such a
  picture of 9000 x 9000 px is a few KB as a file and 324 MB as a 32 bit
  bitmap.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTestImageLimit = class(TTestCase)
  private
    FDir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ASmallPictureIsDecoded;
    procedure AHugePictureIsRefusedButItsSizeIsKnown;
    procedure AHugePictureFileIsRefused;
    procedure AWideFoldOutPageIsDecoded;
    procedure TheLimitCountsPixels;
    procedure NoPictureHasNoSize;
  end;

implementation

uses
  zstream, crc, AuGfx, TestHelpers;

procedure PutBE32(var ABuf: TBytes; APos: Integer; AValue: Cardinal);
begin
  ABuf[APos]     := Byte(AValue shr 24);
  ABuf[APos + 1] := Byte(AValue shr 16);
  ABuf[APos + 2] := Byte(AValue shr 8);
  ABuf[APos + 3] := Byte(AValue);
end;

{ one PNG chunk: length, type, data, CRC of type + data }
procedure WriteChunk(AStrm: TStream; const AType: string; const AData: TBytes);
var
  Head: TBytes;
  C: Cardinal;
begin
  Head := nil;
  SetLength(Head, 8);
  PutBE32(Head, 0, Length(AData));
  Move(AType[1], Head[4], 4);
  AStrm.WriteBuffer(Head[0], 8);
  C := crc32(0, nil, 0);
  C := crc32(C, @Head[4], 4);
  if Length(AData) > 0 then
  begin
    C := crc32(C, @AData[0], Length(AData));
    AStrm.WriteBuffer(AData[0], Length(AData));
  end;
  PutBE32(Head, 0, C);
  AStrm.WriteBuffer(Head[0], 4);
end;

{ a black PNG of AWidth x AHeight, 1 bit grey }
function MakeBlackPng(AWidth, AHeight: Integer): TBytes;
const
  SIGNATURE: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
var
  Png, Packed_: TMemoryStream;
  Z: TCompressionStream;
  Hdr, Row, Data: TBytes;
  Y: Integer;
begin
  Result := nil;
  Hdr := nil;
  Row := nil;
  Data := nil;
  Png := TMemoryStream.Create;
  Packed_ := TMemoryStream.Create;
  try
    Png.WriteBuffer(SIGNATURE, SizeOf(SIGNATURE));
    SetLength(Hdr, 13);
    PutBE32(Hdr, 0, AWidth);
    PutBE32(Hdr, 4, AHeight);
    Hdr[8] := 1;    // bit depth
    Hdr[9] := 0;    // grey
    WriteChunk(Png, 'IHDR', Hdr);
    { every row: the filter byte (none) and the pixels, all 0 }
    SetLength(Row, 1 + (AWidth + 7) div 8);
    Z := TCompressionStream.Create(clDefault, Packed_);
    try
      for Y := 1 to AHeight do Z.WriteBuffer(Row[0], Length(Row));
    finally
      Z.Free;
    end;
    SetLength(Data, Packed_.Size);
    Move(Packed_.Memory^, Data[0], Length(Data));
    WriteChunk(Png, 'IDAT', Data);
    WriteChunk(Png, 'IEND', nil);
    SetLength(Result, Png.Size);
    Move(Png.Memory^, Result[0], Length(Result));
  finally
    Packed_.Free;
    Png.Free;
  end;
end;

{ TTestImageLimit }

procedure TTestImageLimit.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestImageLimit.TearDown;
begin
  RemoveTestDir(FDir);
end;

procedure TTestImageLimit.ASmallPictureIsDecoded;
var
  Png: TBytes;
  B: TGfxBitmap;
  W, H: Integer;
begin
  Png := MakeBlackPng(640, 480);
  AssertTrue('Size from the header', ImageSizeFromBytes(Png, W, H));
  AssertEquals('Width', 640, W);
  AssertEquals('Height', 480, H);
  B := ImageFromBytes(Png, 0);
  AssertTrue('Decoded', B <> nil);
  try
    AssertTrue('Size of the bitmap', BitmapSize(B, W, H));
    AssertEquals('Bitmap width', 640, W);
    AssertEquals('Bitmap height', 480, H);
  finally
    DisposeBitmap(B);
  end;
end;

procedure TTestImageLimit.AHugePictureIsRefusedButItsSizeIsKnown;
var
  Png: TBytes;
  B: TGfxBitmap;
  W, H: Integer;
begin
  Png := MakeBlackPng(9000, 9000);
  AssertTrue('A small file', Length(Png) < 1024 * 1024);
  AssertTrue('Size from the header', ImageSizeFromBytes(Png, W, H));
  AssertEquals('Width', 9000, W);
  AssertEquals('Height', 9000, H);
  AssertFalse('Over the limit', ImagePixelsAllowed(W, H));
  B := ImageFromBytes(Png, 0);
  if B <> nil then DisposeBitmap(B);
  AssertTrue('Not decoded at full size', B = nil);
  { a smaller copy would still decode all of it first }
  B := ImageFromBytes(Png, 640);
  if B <> nil then DisposeBitmap(B);
  AssertTrue('Not decoded for a small copy', B = nil);
end;

procedure TTestImageLimit.AHugePictureFileIsRefused;
var
  Pic: string;
  B: TGfxBitmap;
  W, H: Integer;
begin
  Pic := FDir + 'folder.png';
  WriteFileBytes(Pic, MakeBlackPng(9000, 9000));
  AssertTrue('Size from the header', ImageSizeFromFile(Pic, W, H));
  AssertEquals('Width', 9000, W);
  AssertEquals('Height', 9000, H);
  B := ImageFromFile(Pic, 2400);
  if B <> nil then DisposeBitmap(B);
  AssertTrue('Not decoded', B = nil);
  { the file is not held open }
  AssertTrue('The file can be deleted', SysUtils.DeleteFile(Pic));
end;

procedure TTestImageLimit.AWideFoldOutPageIsDecoded;
var
  Png: TBytes;
  B: TGfxBitmap;
  W, H: Integer;
begin
  { 18 MP, wider than 8192 px: a booklet page as AuBooklet may ask for }
  Png := MakeBlackPng(9000, 2000);
  AssertTrue('Size from the header', ImageSizeFromBytes(Png, W, H));
  AssertTrue('Within the limit', ImagePixelsAllowed(W, H));
  B := ImageFromBytes(Png, 900);
  AssertTrue('Decoded', B <> nil);
  try
    AssertTrue('Size of the bitmap', BitmapSize(B, W, H));
    AssertEquals('Bitmap width', 900, W);
    AssertEquals('Bitmap height', 200, H);
  finally
    DisposeBitmap(B);
  end;
end;

procedure TTestImageLimit.TheLimitCountsPixels;
begin
  AssertTrue('8192 x 8192', ImagePixelsAllowed(8192, 8192));
  AssertFalse('8193 x 8192', ImagePixelsAllowed(8193, 8192));
  AssertTrue('A long strip', ImagePixelsAllowed(30000, 2000));
  AssertFalse('No width', ImagePixelsAllowed(0, 100));
  AssertFalse('Negative', ImagePixelsAllowed(-5, 100));
  { no overflow of 32 bits }
  AssertFalse('65536 x 65536', ImagePixelsAllowed(65536, 65536));
  AssertEquals('The limit', 8192 * 8192, MAX_IMAGE_PIXELS);
end;

procedure TTestImageLimit.NoPictureHasNoSize;
var
  Junk: TBytes;
  W, H, I: Integer;
  B: TGfxBitmap;
begin
  Junk := nil;
  SetLength(Junk, 4096);
  for I := 0 to High(Junk) do Junk[I] := Byte(I * 7 + 3);
  AssertFalse('No size', ImageSizeFromBytes(Junk, W, H));
  AssertEquals('Width 0', 0, W);
  AssertFalse('No size without data', ImageSizeFromBytes(nil, W, H));
  AssertFalse('No size without a file', ImageSizeFromFile(FDir + 'none.png', W, H));
  B := ImageFromBytes(Junk, 0);
  AssertTrue('Nothing decoded', B = nil);
end;

initialization
  RegisterTest(TTestImageLimit);

end.
