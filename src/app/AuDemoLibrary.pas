unit AuDemoLibrary;

{ ==============================================================================
  AulumicNS - AuDemoLibrary
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The demo library of the help screenshots (debug build:
  AulumicNS.exe --make-demo-library=<folder>). Made-up artists and albums -
  nothing of a real person - as FLAC files of digital silence: CONSTANT
  subframes keep a five minute track at a few KB, so the albums have real
  lengths, formats (16 / 44.1 up to 24 / 192) and play (silently). Every
  album gets a drawn cover (folder.jpg, also embedded), the tags the help
  shows (artists, composer, genre, year, track / disc numbers, ReplayGain
  for two albums), one album two disc folders and a Scans folder, and two
  albums a small PDF booklet (cover page and text pages).
  The writers (WriteSilentFlac, WriteDemoBookletPdf) are tested by
  TTestDemoLibrary.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, AuGfx;

{ writes the library into AFolder\Demo Music; the number of music files
  (0 = failed). An existing Demo Music folder is replaced. }
function MakeDemoLibrary(const AFolder: string): Integer;

{ a FLAC file of digital silence with Vorbis comments (ATags: KEY=value
  lines) and, when ACover is not empty, a front cover (JPEG) }
function WriteSilentFlac(const AFile: string; ARate, ABits, AChannels: Integer;
  ATotalSamples: Int64; ATags: TStrings; const ACover: TBytes): Boolean;

{ a small PDF booklet: the JPEG on page 1, then one text page per entry of
  APages (lines separated by LineEnding; the first line is the heading).
  Plain ASCII text (the standard Helvetica fonts). }
function WriteDemoBookletPdf(const AFile: string; const AJpeg: TBytes; AJpegW, AJpegH: Integer;
  APages: TStrings): Boolean;

const
  DEMO_FLAC_BLOCK = 4096;

implementation

type
  TDemoAlbum = record
    Artist, Album, Genre, Composer, Performer, Comment: string;
    Year, Rate, Bits, Discs: Integer;
    C1, C2: Cardinal;          // the cover's gradient (RGB)
    Motif: Integer;            // the cover's picture
    Booklet, Scans, RG: Boolean;
    { 'Title=m:ss' entries separated by '|'; 'Title=m:ss@Artist' for a
      compilation }
    Tracks: string;
  end;

const
  ALBUMS: array[0..5] of TDemoAlbum = (
    (Artist: 'The Example Quartet'; Album: 'First Light'; Genre: 'Jazz'; Composer: 'Jonas Marlow';
     Performer: 'The Example Quartet'; Comment: 'Recorded live to two-track tape.';
     Year: 2019; Rate: 44100; Bits: 16; Discs: 1; C1: $1B3A6B; C2: $E8913A; Motif: 0;
     Booklet: True; Scans: False; RG: True;
     Tracks: 'Morning Over the Bridge=5:12|Blue Hour=6:40|Paper Boats=4:05|The Long Way Round=7:21|' +
       'Quiet Harbour=5:48|Sunday Waltz=3:56|Lamplighter=6:02|First Light=8:14'),
    (Artist: 'The Example Quartet'; Album: 'Night Train'; Genre: 'Jazz'; Composer: 'Jonas Marlow';
     Performer: 'The Example Quartet'; Comment: '';
     Year: 2021; Rate: 96000; Bits: 24; Discs: 1; C1: $12121E; C2: $5B3C88; Motif: 1;
     Booklet: False; Scans: False; RG: True;
     Tracks: 'Departure=4:44|Sleeper Car=6:18|Crossing the Border=5:30|Station Lights=4:12|' +
       'Coffee at Three=7:05|Arrival=5:51'),
    (Artist: 'Mira Solenne'; Album: 'Glass Gardens'; Genre: 'Ambient'; Composer: 'Mira Solenne';
     Performer: 'Mira Solenne'; Comment: 'Headphones recommended.';
     Year: 2022; Rate: 48000; Bits: 24; Discs: 1; C1: $0F5C5A; C2: $B8E0D2; Motif: 2;
     Booklet: False; Scans: False; RG: False;
     Tracks: 'Greenhouse=6:30|Condensation=4:58|Fern Light=7:44|Slow Bloom=9:02|' +
       'Through the Panes=5:16|Dew Point=6:11|Evening Glass=8:27'),
    (Artist: 'Northbound Chamber Orchestra'; Album: 'Seasons in Blue'; Genre: 'Classical';
     Composer: 'Elias Varden'; Performer: 'Northbound Chamber Orchestra; Anna Kestrel (violin)';
     Comment: 'Four concertos for violin and strings.';
     Year: 2018; Rate: 192000; Bits: 24; Discs: 2; C1: $1D2B45; C2: $8FB3D9; Motif: 3;
     Booklet: True; Scans: True; RG: False;
     Tracks: 'Concerto No. 1 "Thaw" - I. Allegro=5:42|Concerto No. 1 "Thaw" - II. Largo=6:55|' +
       'Concerto No. 1 "Thaw" - III. Presto=4:21|Concerto No. 2 "Tide" - I. Moderato=6:08|' +
       'Concerto No. 2 "Tide" - II. Adagio=8:12|Concerto No. 2 "Tide" - III. Allegro vivo=4:47|' +
       'Concerto No. 3 "Ember" - I. Allegro=5:33|Concerto No. 3 "Ember" - II. Andante=7:19|' +
       'Concerto No. 3 "Ember" - III. Vivace=4:02|Concerto No. 4 "Frost" - I. Allegro non troppo=6:26|' +
       'Concerto No. 4 "Frost" - II. Lento=9:10|Concerto No. 4 "Frost" - III. Finale=5:05'),
    (Artist: 'Copper Lanterns'; Album: 'Harbour Songs'; Genre: 'Folk'; Composer: 'Copper Lanterns';
     Performer: 'Copper Lanterns'; Comment: '';
     Year: 2016; Rate: 44100; Bits: 16; Discs: 1; C1: $5A2A12; C2: $F2C46B; Motif: 4;
     Booklet: False; Scans: False; RG: False;
     Tracks: 'Ropes and Rain=3:41|The Ferryman''s Daughter=4:26|Salt in the Air=3:12|Low Tide=5:03|' +
       'Lantern Dance=2:58|Fog Bell=4:44|Mending Nets=3:37|Last Boat Home=5:21|North Wind=4:09'),
    (Artist: 'Various Artists'; Album: 'Late Night Sessions'; Genre: 'Jazz'; Composer: '';
     Performer: ''; Comment: 'A compilation of the demo library.';
     Year: 2023; Rate: 44100; Bits: 16; Discs: 1; C1: $0B0E1A; C2: $2E4A7A; Motif: 5;
     Booklet: False; Scans: False; RG: False;
     Tracks: 'After Hours=5:35@The Example Quartet|Moon Pool=6:48@Mira Solenne|' +
       'Harbour Lights (Live)=4:51@Copper Lanterns|Small Hours=5:14@June Halloway Trio|' +
       'Nocturne for Strings=6:22@Northbound Chamber Orchestra|Last Call=4:37@June Halloway Trio'));

{ ---- byte helpers ---- }

procedure PutBE(S: TStream; V: QWord; N: Integer);
var
  I: Integer;
  B: Byte;
begin
  for I := N - 1 downto 0 do
  begin
    B := Byte(V shr (8 * I));
    S.WriteBuffer(B, 1);
  end;
end;

procedure PutLE32(S: TStream; V: Cardinal);
var
  B: array[0..3] of Byte;
begin
  B[0] := Byte(V); B[1] := Byte(V shr 8); B[2] := Byte(V shr 16); B[3] := Byte(V shr 24);
  S.WriteBuffer(B, 4);
end;

procedure PutStr(S: TStream; const T: RawByteString);
begin
  if T <> '' then S.WriteBuffer(T[1], Length(T));
end;

function Crc8(const P: array of Byte; N: Integer): Byte;
var
  I, J: Integer;
  C: Byte;
begin
  C := 0;
  for I := 0 to N - 1 do
  begin
    C := C xor P[I];
    for J := 0 to 7 do
      if C and $80 <> 0 then C := Byte((C shl 1) xor $07) else C := Byte(C shl 1);
  end;
  Result := C;
end;

function Crc16(const P: array of Byte; N: Integer): Word;
var
  I, J: Integer;
  C: Word;
begin
  C := 0;
  for I := 0 to N - 1 do
  begin
    C := C xor (Word(P[I]) shl 8);
    for J := 0 to 7 do
      if C and $8000 <> 0 then C := Word((C shl 1) xor $8005) else C := Word(C shl 1);
  end;
  Result := C;
end;

{ ---- FLAC ---- }

function RateCode(ARate: Integer): Integer;
begin
  case ARate of
    88200: Result := 1;
    176400: Result := 2;
    192000: Result := 3;
    32000: Result := 8;
    44100: Result := 9;
    48000: Result := 10;
    96000: Result := 11;
  else
    Result := -1;
  end;
end;

function SizeCode(ABits: Integer): Integer;
begin
  case ABits of
    8: Result := 1;
    16: Result := 4;
    24: Result := 6;
  else
    Result := -1;
  end;
end;

procedure MetaHeader(S: TStream; AType: Byte; ALast: Boolean; ALen: Integer);
var
  B: Byte;
begin
  B := AType;
  if ALast then B := B or $80;
  S.WriteBuffer(B, 1);
  PutBE(S, ALen, 3);
end;

function WriteSilentFlac(const AFile: string; ARate, ABits, AChannels: Integer;
  ATotalSamples: Int64; ATags: TStrings; const ACover: TBytes): Boolean;
var
  FS: TFileStream;
  M: TMemoryStream;
  Fr: array[0..63] of Byte;
  N, I, C, Rc, Sc, BlockLen, BsCode: Integer;
  FrameNo, Done: Int64;
  Q: QWord;
  Crc: Word;
  V: RawByteString;
  Zero: array[0..15] of Byte;
begin
  Result := False;
  Rc := RateCode(ARate);
  Sc := SizeCode(ABits);
  if (Rc < 0) or (Sc < 0) or (AChannels < 1) or (AChannels > 8) or (ATotalSamples <= 0) then Exit;
  FillChar(Zero, SizeOf(Zero), 0);
  M := TMemoryStream.Create;
  try
    PutStr(M, 'fLaC');
    { STREAMINFO }
    MetaHeader(M, 0, False, 34);
    PutBE(M, DEMO_FLAC_BLOCK, 2);
    PutBE(M, DEMO_FLAC_BLOCK, 2);
    PutBE(M, 0, 3);                      // min / max frame size: unknown
    PutBE(M, 0, 3);
    Q := (QWord(ARate) shl 44) or (QWord(AChannels - 1) shl 41) or (QWord(ABits - 1) shl 36) or
      (QWord(ATotalSamples) and $FFFFFFFFF);
    PutBE(M, Q, 8);
    M.WriteBuffer(Zero, 16);             // MD5: unknown
    { VORBIS_COMMENT }
    V := 'Aulumic demo library';
    N := 4 + Length(V) + 4;
    if ATags <> nil then
      for I := 0 to ATags.Count - 1 do Inc(N, 4 + Length(RawByteString(ATags[I])));
    MetaHeader(M, 4, False, N);
    PutLE32(M, Length(V));
    PutStr(M, V);
    if ATags <> nil then PutLE32(M, ATags.Count) else PutLE32(M, 0);
    if ATags <> nil then
      for I := 0 to ATags.Count - 1 do
      begin
        V := ATags[I];
        PutLE32(M, Length(V));
        PutStr(M, V);
      end;
    { PICTURE (front cover) }
    if Length(ACover) > 0 then
    begin
      V := 'image/jpeg';
      MetaHeader(M, 6, False, 32 + Length(V) + Length(ACover));
      PutBE(M, 3, 4);                    // front cover
      PutBE(M, Length(V), 4);
      PutStr(M, V);
      PutBE(M, 0, 4);                    // no description
      PutBE(M, 0, 4);                    // width, height, depth, colours: unknown
      PutBE(M, 0, 4);
      PutBE(M, 0, 4);
      PutBE(M, 0, 4);
      PutBE(M, Length(ACover), 4);
      M.WriteBuffer(ACover[0], Length(ACover));
    end;
    { PADDING (room for tag edits in place) }
    MetaHeader(M, 1, True, 1024);
    for I := 1 to 64 do M.WriteBuffer(Zero, 16);
    { the frames: CONSTANT subframes of 0 }
    FrameNo := 0;
    Done := 0;
    while Done < ATotalSamples do
    begin
      BlockLen := DEMO_FLAC_BLOCK;
      if ATotalSamples - Done < BlockLen then BlockLen := Integer(ATotalSamples - Done);
      if BlockLen = DEMO_FLAC_BLOCK then BsCode := 12 else BsCode := 7;
      Fr[0] := $FF;
      Fr[1] := $F8;
      Fr[2] := Byte((BsCode shl 4) or Rc);
      Fr[3] := Byte(((AChannels - 1) shl 4) or (Sc shl 1));
      N := 4;
      { the frame number, UTF-8 coded }
      if FrameNo < $80 then
      begin
        Fr[N] := Byte(FrameNo); Inc(N);
      end
      else if FrameNo < $800 then
      begin
        Fr[N] := Byte($C0 or (FrameNo shr 6)); Fr[N + 1] := Byte($80 or (FrameNo and $3F)); Inc(N, 2);
      end
      else if FrameNo < $10000 then
      begin
        Fr[N] := Byte($E0 or (FrameNo shr 12)); Fr[N + 1] := Byte($80 or ((FrameNo shr 6) and $3F));
        Fr[N + 2] := Byte($80 or (FrameNo and $3F)); Inc(N, 3);
      end
      else
      begin
        Fr[N] := Byte($F0 or ((FrameNo shr 18) and $07)); Fr[N + 1] := Byte($80 or ((FrameNo shr 12) and $3F));
        Fr[N + 2] := Byte($80 or ((FrameNo shr 6) and $3F)); Fr[N + 3] := Byte($80 or (FrameNo and $3F)); Inc(N, 4);
      end;
      if BsCode = 7 then
      begin
        Fr[N] := Byte((BlockLen - 1) shr 8);
        Fr[N + 1] := Byte(BlockLen - 1);
        Inc(N, 2);
      end;
      Fr[N] := Crc8(Fr, N);
      Inc(N);
      for C := 1 to AChannels do
      begin
        Fr[N] := 0;                      // CONSTANT, no wasted bits
        Inc(N);
        for I := 1 to ABits div 8 do
        begin
          Fr[N] := 0;
          Inc(N);
        end;
      end;
      Crc := Crc16(Fr, N);
      Fr[N] := Byte(Crc shr 8);
      Fr[N + 1] := Byte(Crc);
      Inc(N, 2);
      M.WriteBuffer(Fr, N);
      Inc(Done, BlockLen);
      Inc(FrameNo);
    end;
    ForceDirectories(ExtractFileDir(AFile));
    FS := TFileStream.Create(AFile, fmCreate);
    try
      M.Position := 0;
      FS.CopyFrom(M, M.Size);
    finally
      FS.Free;
    end;
    Result := True;
  finally
    M.Free;
  end;
end;

{ ---- PDF ---- }

function PdfText(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['(', ')', '\'] then Result := Result + '\' + S[I]
    else if S[I] in [#32..#126] then Result := Result + S[I]
    else Result := Result + '?';
end;

function WriteDemoBookletPdf(const AFile: string; const AJpeg: TBytes; AJpegW, AJpegH: Integer;
  APages: TStrings): Boolean;
const
  PW = 340;
  PH = 340;
var
  M: TMemoryStream;
  Offs: array of Int64;
  NObj, I, J, PageCount, ImgObj, FontB, FontR, Y: Integer;
  Kids, Content: string;
  Lines: TStringList;
  FS: TFileStream;

  procedure BeginObj(ANum: Integer);
  begin
    if ANum >= Length(Offs) then SetLength(Offs, ANum + 1);
    Offs[ANum] := M.Position;
    PutStr(M, IntToStr(ANum) + ' 0 obj' + #10);
  end;

  procedure EndObj;
  begin
    PutStr(M, 'endobj' + #10);
  end;

  procedure StreamObj(ANum: Integer; const ADict, AData: string);
  begin
    BeginObj(ANum);
    PutStr(M, '<< ' + ADict + ' /Length ' + IntToStr(Length(AData)) + ' >>' + #10 + 'stream' + #10);
    PutStr(M, AData);
    PutStr(M, #10 + 'endstream' + #10);
    EndObj;
  end;

begin
  Result := False;
  if (Length(AJpeg) = 0) or (AJpegW <= 0) or (AJpegH <= 0) then Exit;
  M := TMemoryStream.Create;
  Lines := TStringList.Create;
  try
    PutStr(M, '%PDF-1.4' + #10 + '%' + #$E2#$E3#$CF#$D3 + #10);
    PageCount := 1 + APages.Count;
    { objects: 1 catalog, 2 pages, 3.. page + content pairs, then image, fonts }
    ImgObj := 3 + 2 * PageCount;
    FontB := ImgObj + 1;
    FontR := ImgObj + 2;
    NObj := FontR;
    Kids := '';
    for I := 0 to PageCount - 1 do Kids := Kids + IntToStr(3 + 2 * I) + ' 0 R ';
    BeginObj(1);
    PutStr(M, '<< /Type /Catalog /Pages 2 0 R >>' + #10);
    EndObj;
    BeginObj(2);
    PutStr(M, '<< /Type /Pages /Kids [' + Kids + '] /Count ' + IntToStr(PageCount) + ' >>' + #10);
    EndObj;
    for I := 0 to PageCount - 1 do
    begin
      BeginObj(3 + 2 * I);
      PutStr(M, Format('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Resources << /XObject << /Im1 %d 0 R >> ' +
        '/Font << /F1 %d 0 R /F2 %d 0 R >> >> /Contents %d 0 R >>', [PW, PH, ImgObj, FontB, FontR, 4 + 2 * I]) + #10);
      EndObj;
      if I = 0 then
        Content := Format('q %d 0 0 %d 0 0 cm /Im1 Do Q', [PW, PH])
      else
      begin
        Lines.Text := APages[I - 1];
        { a dark page with light text, the cover small in the corner }
        Content := '0.09 0.10 0.13 rg 0 0 ' + IntToStr(PW) + ' ' + IntToStr(PH) + ' re f' + #10 +
          Format('q 54 0 0 54 %d %d cm /Im1 Do Q', [PW - 78, PH - 78]) + #10;
        Y := PH - 52;
        for J := 0 to Lines.Count - 1 do
        begin
          if J = 0 then
            Content := Content + Format('0.96 0.85 0.62 rg BT /F1 16 Tf 24 %d Td (%s) Tj ET', [Y, PdfText(Lines[J])]) + #10
          else
            Content := Content + Format('0.86 0.88 0.92 rg BT /F2 10 Tf 24 %d Td (%s) Tj ET', [Y, PdfText(Lines[J])]) + #10;
          if J = 0 then Dec(Y, 30) else Dec(Y, 16);
          if Y < 20 then Break;
        end;
      end;
      StreamObj(4 + 2 * I, '', Content);
    end;
    BeginObj(ImgObj);
    PutStr(M, Format('<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB ' +
      '/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>', [AJpegW, AJpegH, Length(AJpeg)]) + #10 + 'stream' + #10);
    M.WriteBuffer(AJpeg[0], Length(AJpeg));
    PutStr(M, #10 + 'endstream' + #10);
    EndObj;
    BeginObj(FontB);
    PutStr(M, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>' + #10);
    EndObj;
    BeginObj(FontR);
    PutStr(M, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>' + #10);
    EndObj;
    { the cross reference table: 20 bytes per entry }
    J := M.Position;
    PutStr(M, 'xref' + #10 + '0 ' + IntToStr(NObj + 1) + #10 + '0000000000 65535 f' + #13#10);
    for I := 1 to NObj do PutStr(M, Format('%.10d 00000 n', [Offs[I]]) + #13#10);
    PutStr(M, 'trailer' + #10 + '<< /Size ' + IntToStr(NObj + 1) + ' /Root 1 0 R >>' + #10 +
      'startxref' + #10 + IntToStr(J) + #10 + '%%EOF' + #10);
    ForceDirectories(ExtractFileDir(AFile));
    FS := TFileStream.Create(AFile, fmCreate);
    try
      M.Position := 0;
      FS.CopyFrom(M, M.Size);
    finally
      FS.Free;
    end;
    Result := True;
  finally
    Lines.Free;
    M.Free;
  end;
end;

{ ---- covers ---- }

function Argb(RGB: Cardinal; A: Byte = 255): TARGB;
begin
  Result := (Cardinal(A) shl 24) or (RGB and $FFFFFF);
end;

{ the album's cover as JPEG bytes (Size x Size) }
function MakeCover(const A: TDemoAlbum; Size: Integer; const AFile: string; out ABytes: TBytes): Boolean;
var
  B: TGfxBitmap;
  G: TGfx;
  K, X, Y, R: Single;
  I: Integer;
  FS: TFileStream;
begin
  Result := False;
  ABytes := nil;
  B := nil;
  G := TGfx.CreateBitmap(Size, Size);
  try
    K := Size / 100;
    G.FillRoundGrad(0, 0, Size, Size, 0, Argb(A.C1), Argb(A.C2), True);
    case A.Motif of
      0: begin
           { a sun over the water }
           G.FillCircle(62 * K, 40 * K, 17 * K, Argb($FFF1D0, 235));
           G.FillCircle(62 * K, 40 * K, 24 * K, Argb($FFF1D0, 40));
           for I := 0 to 6 do
             G.Line(10 * K + I * 3 * K, 64 * K + I * 3.4 * K, 90 * K - I * 3 * K, 64 * K + I * 3.4 * K,
               1.2 * K, Argb($FFFFFF, 120 - I * 12));
         end;
      1: begin
           { train lights in the night }
           for I := 0 to 9 do
             G.FillRound(8 * K + I * 9 * K, 56 * K, 6 * K, 4 * K, 1 * K, Argb($FFD27A, 200 - I * 14));
           G.Line(0, 62 * K, Size, 62 * K, 0.8 * K, Argb($FFFFFF, 90));
           for I := 0 to 30 do
             G.FillCircle(((I * 37) mod 100) * K, ((I * 53) mod 45) * K, 0.5 * K, Argb($FFFFFF, 160));
         end;
      2: begin
           { panes of glass }
           for I := 0 to 7 do
           begin
             X := 12 * K + (I mod 4) * 20 * K;
             Y := 14 * K + (I div 4) * 26 * K;
             G.FillRound(X, Y, 16 * K, 22 * K, 2 * K, Argb($FFFFFF, 30 + I * 8));
             G.StrokeRound(X, Y, 16 * K, 22 * K, 2 * K, 0.4 * K, Argb($FFFFFF, 140));
           end;
         end;
      3: begin
           { waves }
           for I := 0 to 7 do
             G.Arc(50 * K, 120 * K + I * 4 * K, 70 * K + I * 6 * K, 200, 140, 0.9 * K, Argb($FFFFFF, 150 - I * 15));
           G.FillCircle(74 * K, 24 * K, 6 * K, Argb($FFFFFF, 200));
         end;
      4: begin
           { lanterns }
           for I := 0 to 4 do
           begin
             X := 18 * K + I * 16 * K;
             Y := 30 * K + (I mod 2) * 9 * K;
             G.Line(X, 0, X, Y - 5 * K, 0.4 * K, Argb($FFFFFF, 120));
             G.FillCircle(X, Y, 9 * K, Argb($FFC860, 50));
             G.FillCircle(X, Y, 4.5 * K, Argb($FFE3A0, 230));
           end;
         end;
    else
      begin
        { a crescent and stars }
        R := 14 * K;
        G.FillCircle(68 * K, 30 * K, R, Argb($F3EFD8, 235));
        G.FillCircle(73 * K, 26 * K, R, Argb(A.C1, 255));
        for I := 0 to 40 do
          G.FillCircle(((I * 29) mod 100) * K, ((I * 41) mod 60) * K, 0.45 * K, Argb($FFFFFF, 170));
      end;
    end;
    { the names }
    G.FillRect(0, 74 * K, Size, 26 * K, Argb($000000, 70));
    G.Text(A.Artist, 7 * K, 77 * K, 86 * K, 7 * K, GetFont(4.6 * K), Argb($FFFFFF, 220), 0, 1);
    G.Text(A.Album, 7 * K, 84 * K, 86 * K, 12 * K, GetFont(8.2 * K, True), Argb($FFFFFF), 0, 1);
    B := G.ToBitmap;
  finally
    G.Free;
  end;
  try
    ForceDirectories(ExtractFileDir(AFile));
    if not SaveBitmapJpeg(B, AFile) then Exit;
  finally
    DisposeBitmap(B);
  end;
  FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    SetLength(ABytes, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(ABytes[0], FS.Size);
  finally
    FS.Free;
  end;
  Result := Length(ABytes) > 0;
end;

{ ---- the library ---- }

function SafeName(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in ['\', '/', ':', '*', '?', '"', '<', '>', '|'] then Result[I] := '_';
end;

function ParseSeconds(const S: string): Integer;
var
  P: Integer;
begin
  P := Pos(':', S);
  if P = 0 then Exit(StrToIntDef(S, 0));
  Result := StrToIntDef(Copy(S, 1, P - 1), 0) * 60 + StrToIntDef(Copy(S, P + 1, 9), 0);
end;

procedure DeleteTree(const ADir: string);
var
  SR: TSearchRec;
  D: string;
begin
  D := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(D + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if SR.Attr and faDirectory <> 0 then DeleteTree(D + SR.Name)
      else SysUtils.DeleteFile(D + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(ADir);
end;

function MakeDemoLibrary(const AFolder: string): Integer;
var
  Root, AlbumDir, Dir, T, Title, TrackArtist, Ext: string;
  A, I, P, At, Sec, PerDisc, Disc, No, Total: Integer;
  Tags, Pages, Notes: TStringList;
  Items: TStringArray;
  BackAlbum: TDemoAlbum;
  Cover, Back: TBytes;
  Gain: Double;
  FmtS: TFormatSettings;
begin
  Result := 0;
  FmtS := DefaultFormatSettings;
  FmtS.DecimalSeparator := '.';
  Root := IncludeTrailingPathDelimiter(ExpandFileName(AFolder)) + 'Demo Music';
  if DirectoryExists(Root) then DeleteTree(Root);
  Tags := TStringList.Create;
  Pages := TStringList.Create;
  Notes := TStringList.Create;
  try
    for A := 0 to High(ALBUMS) do
    begin
      AlbumDir := IncludeTrailingPathDelimiter(Root) + SafeName(ALBUMS[A].Artist) + '\' +
        IntToStr(ALBUMS[A].Year) + ' - ' + SafeName(ALBUMS[A].Album);
      if not MakeCover(ALBUMS[A], 600, AlbumDir + '\folder.jpg', Cover) then Exit(0);
      { (split by hand: the titles contain quotes) }
      Items := ALBUMS[A].Tracks.Split(['|']);
      Total := Length(Items);
      PerDisc := (Total + ALBUMS[A].Discs - 1) div ALBUMS[A].Discs;
      Notes.Clear;
      for I := 0 to High(Items) do
      begin
        T := Items[I];
        P := Pos('=', T);
        Title := Copy(T, 1, P - 1);
        T := Copy(T, P + 1, MaxInt);
        At := Pos('@', T);
        if At > 0 then
        begin
          TrackArtist := Copy(T, At + 1, MaxInt);
          T := Copy(T, 1, At - 1);
        end
        else
          TrackArtist := ALBUMS[A].Artist;
        Sec := ParseSeconds(T);
        Disc := I div PerDisc + 1;
        No := I mod PerDisc + 1;
        Notes.Add(Format('%d. %s  (%s)', [I + 1, Title, T]));
        if ALBUMS[A].Discs > 1 then Dir := AlbumDir + '\CD' + IntToStr(Disc) else Dir := AlbumDir;
        Tags.Clear;
        Tags.Add('TITLE=' + Title);
        Tags.Add('ARTIST=' + TrackArtist);
        Tags.Add('ALBUMARTIST=' + ALBUMS[A].Artist);
        Tags.Add('ALBUM=' + ALBUMS[A].Album);
        Tags.Add('DATE=' + IntToStr(ALBUMS[A].Year));
        Tags.Add('GENRE=' + ALBUMS[A].Genre);
        Tags.Add('TRACKNUMBER=' + IntToStr(No));
        if ALBUMS[A].Discs > 1 then Tags.Add('TRACKTOTAL=' + IntToStr(PerDisc))
        else Tags.Add('TRACKTOTAL=' + IntToStr(Total));
        Tags.Add('DISCNUMBER=' + IntToStr(Disc));
        Tags.Add('DISCTOTAL=' + IntToStr(ALBUMS[A].Discs));
        if ALBUMS[A].Composer <> '' then Tags.Add('COMPOSER=' + ALBUMS[A].Composer);
        if ALBUMS[A].Performer <> '' then Tags.Add('PERFORMER=' + ALBUMS[A].Performer);
        if (ALBUMS[A].Comment <> '') and (I = 0) then Tags.Add('COMMENT=' + ALBUMS[A].Comment);
        if ALBUMS[A].RG then
        begin
          Gain := -4.1 - (I mod 5) * 0.73;
          Tags.Add('REPLAYGAIN_TRACK_GAIN=' + FormatFloat('0.00', Gain, FmtS) + ' dB');
          Tags.Add('REPLAYGAIN_TRACK_PEAK=' + FormatFloat('0.000000', 0.71 + (I mod 4) * 0.07, FmtS));
          Tags.Add('REPLAYGAIN_ALBUM_GAIN=' + FormatFloat('0.00', -5.62 - A * 0.4, FmtS) + ' dB');
          Tags.Add('REPLAYGAIN_ALBUM_PEAK=' + FormatFloat('0.000000', 0.94, FmtS));
        end;
        Ext := '.flac';
        if not WriteSilentFlac(Format('%s\%.2d - %s%s', [Dir, No, SafeName(Title), Ext]),
          ALBUMS[A].Rate, ALBUMS[A].Bits, 2, Int64(Sec) * ALBUMS[A].Rate, Tags, Cover) then Exit(0);
        Inc(Result);
      end;
      { a disc folder gets the cover too (the scan finds it next to the tracks) }
      if ALBUMS[A].Discs > 1 then
        for Disc := 1 to ALBUMS[A].Discs do
          CopyFile(PChar(AlbumDir + '\folder.jpg'), PChar(AlbumDir + '\CD' + IntToStr(Disc) + '\folder.jpg'), False);
      if ALBUMS[A].Scans then
      begin
        { a back cover in Scans (the cover viewer steps through it) }
        BackAlbum := ALBUMS[A];
        BackAlbum.C1 := ALBUMS[A].C2;
        BackAlbum.C2 := ALBUMS[A].C1;
        BackAlbum.Album := 'Back cover';
        MakeCover(BackAlbum, 600, AlbumDir + '\Scans\back.jpg', Back);
      end;
      if ALBUMS[A].Booklet then
      begin
        Pages.Clear;
        if Notes.Count > 9 then
        begin
          T := 'Tracks' + LineEnding;
          for I := 0 to 8 do T := T + Notes[I] + LineEnding;
          Pages.Add(T);
          T := 'Tracks (continued)' + LineEnding;
          for I := 9 to Notes.Count - 1 do T := T + Notes[I] + LineEnding;
          Pages.Add(T);
        end
        else
          Pages.Add('Tracks' + LineEnding + Notes.Text);
        Pages.Add('About this album' + LineEnding + ALBUMS[A].Artist + ' - ' + ALBUMS[A].Album +
          ' (' + IntToStr(ALBUMS[A].Year) + ')' + LineEnding + LineEnding +
          'This booklet belongs to the demo library of Aulumic.' + LineEnding +
          'The artists, the albums and the music are made up;' + LineEnding +
          'the files contain digital silence.' + LineEnding + LineEnding +
          'Music: ' + ALBUMS[A].Composer + LineEnding + 'Performed by: ' + ALBUMS[A].Performer);
        if not WriteDemoBookletPdf(AlbumDir + '\' + SafeName(ALBUMS[A].Album) + ' - Booklet.pdf', Cover, 600, 600,
          Pages) then Exit(0);
      end;
    end;
  finally
    Notes.Free;
    Pages.Free;
    Tags.Free;
  end;
end;

end.
