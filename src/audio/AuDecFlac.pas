unit AuDecFlac;

{ Native FLAC decoder (no libFLAC). Implements the complete format:
  STREAMINFO, SEEKTABLE, VORBIS_COMMENT (ReplayGain); frames with fixed or
  variable block size; subframes CONSTANT, VERBATIM, FIXED (order 0 - 4) and
  LPC (order 1 - 32); Rice coding with 4 / 5 bit parameters and escaped
  partitions; independent, left/side, side/right and mid/side stereo; wasted
  bits; 4 - 32 bits per sample. Samples are computed with 64-bit integers so
  32-bit streams (33-bit side channel) are exact.

  The MD5 signature of the decoded audio from STREAMINFO is exposed so the
  test program can prove the decoder is bit exact. }

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, Math, AuAudioTypes, AuDecoder;

type
  TAuFlacSeekPoint = record
    Sample, Offset: QWord;
  end;

  { TAuFlacDecoder }

  TAuFlacDecoder = class(TAuDecoder)
  private
    FFile: TFileStream;
    FFileSize: Int64;
    { input window }
    FData: array of Byte;
    FLen, FIdx: Integer;
    FWinStart: Int64;          // file offset of FData[0]
    FEof: Boolean;
    { bit reader }
    FBits: QWord;
    FBitCount: Integer;
    { stream }
    FFirstFrame: Int64;
    FMinBlock, FMaxBlock: Integer;
    FSeek: array of TAuFlacSeekPoint;
    FMd5: array[0..15] of Byte;
    { decoded block }
    FSub: array of array of Int64;
    FBlock: array of Int32;     // interleaved samples of the current frame
    FBlockFrames, FBlockPos: Integer;
    FBlockFirst: Int64;         // sample number of the first sample in FBlock
    procedure Refill(Need: Integer);
    function ByteAt: Byte; inline;
    function FilePos: Int64; inline;
    procedure ByteAlign;
    function ReadBits(N: Integer): QWord; inline;
    function ReadSigned(N: Integer): Int64; inline;
    function ReadUnary: Cardinal;
    function ReadUtf8Number: QWord;
    procedure SeekFile(Pos: Int64);
    function ParseHeader(out BlockSize, Bps, ChanAssign: Integer; out FirstSample: Int64): Boolean;
    function DecodeFrame: Boolean;
    procedure DecodeSubframe(Ch, BlockSize, Bps: Integer);
    procedure DecodeResidual(BlockSize, Order: Integer; Dest: PInt64);
    function FindNextFrame(out FirstSample: Int64): Boolean;
    procedure ReadMetadata;
  public
    destructor Destroy; override;
    procedure Open(const AFileName: string); override;
    function ReadPcm(Dest: PInt32; MaxFrames: Integer): Integer; override;
    procedure Seek(Frame: Int64); override;
  end;

implementation

const
  WindowSize = 4 * 1024 * 1024;
  MinAhead = 2 * 1024 * 1024 + 64;    // a frame never needs more

var
  Crc8Table: array[0..255] of Byte;

procedure InitCrc8;
var
  I, J: Integer;
  C: Byte;
begin
  for I := 0 to 255 do
  begin
    C := I;
    for J := 0 to 7 do
      if C and $80 <> 0 then C := (C shl 1) xor $07 else C := C shl 1;
    Crc8Table[I] := C;
  end;
end;

{ ---- input window and bit reader ---- }

destructor TAuFlacDecoder.Destroy;
begin
  FFile.Free;
  inherited Destroy;
end;

{ makes sure at least Need bytes after FIdx are in the window (or EOF) }
procedure TAuFlacDecoder.Refill(Need: Integer);
var
  Keep, N: Integer;
begin
  if FLen - FIdx >= Need then Exit;
  if FEof then Exit;
  Keep := FLen - FIdx;
  if Keep > 0 then Move(FData[FIdx], FData[0], Keep);
  FWinStart := FWinStart + FIdx;
  FIdx := 0;
  FLen := Keep;
  FFile.Position := FWinStart + FLen;
  N := FFile.Read(FData[FLen], WindowSize - FLen);
  if N <= 0 then FEof := True;
  Inc(FLen, Math.Max(N, 0));
  if FWinStart + FLen >= FFileSize then FEof := True;
end;

function TAuFlacDecoder.ByteAt: Byte;
begin
  if FIdx >= FLen then
  begin
    Refill(1);
    if FIdx >= FLen then raise EAuAudio.CreateKind(aekFormat, 'FLAC: unexpected end of file');
  end;
  Result := FData[FIdx];
  Inc(FIdx);
end;

function TAuFlacDecoder.FilePos: Int64;
begin
  Result := FWinStart + FIdx - FBitCount div 8;
end;

{ drops the bits up to the next byte boundary; unread whole bytes go back to the window }
procedure TAuFlacDecoder.ByteAlign;
begin
  FBitCount := FBitCount - FBitCount mod 8;
  Dec(FIdx, FBitCount div 8);
  FBitCount := 0;
  FBits := 0;
end;

procedure TAuFlacDecoder.SeekFile(Pos: Int64);
begin
  FBitCount := 0;
  FBits := 0;
  if (Pos >= FWinStart) and (Pos < FWinStart + FLen) then
  begin
    FIdx := Integer(Pos - FWinStart);
    Refill(MinAhead);
    Exit;
  end;
  FWinStart := Pos;
  FIdx := 0;
  FLen := 0;
  FEof := False;
  Refill(MinAhead);
end;

function TAuFlacDecoder.ReadBits(N: Integer): QWord;
begin
  if N = 0 then Exit(0);
  if N > 56 then
  begin
    Result := ReadBits(N - 32) shl 32;
    Result := Result or ReadBits(32);
    Exit;
  end;
  while FBitCount < N do
  begin
    FBits := (FBits shl 8) or ByteAt;
    Inc(FBitCount, 8);
  end;
  Dec(FBitCount, N);
  Result := (FBits shr FBitCount) and ((QWord(1) shl N) - 1);
end;

function TAuFlacDecoder.ReadSigned(N: Integer): Int64;
begin
  if N = 0 then Exit(0);
  Result := Int64(ReadBits(N) shl (64 - N));
  Result := SarInt64(Result, 64 - N);
end;

{ number of 0 bits before the next 1 bit (the 1 is consumed) }
function TAuFlacDecoder.ReadUnary: Cardinal;
var
  V: QWord;
  Top: Integer;
begin
  Result := 0;
  repeat
    if FBitCount = 0 then
    begin
      { fast path: whole zero bytes }
      while True do
      begin
        if FIdx >= FLen then Refill(1);
        if FIdx >= FLen then raise EAuAudio.CreateKind(aekFormat, 'FLAC: unexpected end of file');
        if FData[FIdx] <> 0 then Break;
        Inc(FIdx);
        Inc(Result, 8);
      end;
      FBits := FData[FIdx];
      Inc(FIdx);
      FBitCount := 8;
    end;
    if FBitCount = 64 then V := FBits else V := FBits and ((QWord(1) shl FBitCount) - 1);
    if V = 0 then
    begin
      Inc(Result, FBitCount);
      FBitCount := 0;
    end
    else
    begin
      Top := BsrQWord(V);
      Inc(Result, FBitCount - 1 - Top);
      FBitCount := Top;
      Exit;
    end;
  until False;
end;

function TAuFlacDecoder.ReadUtf8Number: QWord;
var
  B: Byte;
  N, I: Integer;
begin
  B := ReadBits(8);
  if B and $80 = 0 then Exit(B);
  if B and $E0 = $C0 then begin Result := B and $1F; N := 1; end
  else if B and $F0 = $E0 then begin Result := B and $0F; N := 2; end
  else if B and $F8 = $F0 then begin Result := B and $07; N := 3; end
  else if B and $FC = $F8 then begin Result := B and $03; N := 4; end
  else if B and $FE = $FC then begin Result := B and $01; N := 5; end
  else if B = $FE then begin Result := 0; N := 6; end
  else raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid frame number');
  for I := 1 to N do
  begin
    B := ReadBits(8);
    if B and $C0 <> $80 then raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid frame number');
    Result := (Result shl 6) or (B and $3F);
  end;
end;

{ ---- metadata ---- }

procedure TAuFlacDecoder.ReadMetadata;
var
  Last: Boolean;
  BType, Len, I, N, Count: Integer;
  Hdr: Byte;
  Start: Int64;
  SR: Cardinal;
  Ch, Bps: Integer;
  Total: QWord;
  S: string;

  function U32LE: Cardinal;
  begin
    Result := ReadBits(8);
    Result := Result or (Cardinal(ReadBits(8)) shl 8);
    Result := Result or (Cardinal(ReadBits(8)) shl 16);
    Result := Result or (Cardinal(ReadBits(8)) shl 24);
  end;

  function ReadStr(L: Integer): string;
  var
    J: Integer;
  begin
    SetLength(Result, L);
    for J := 1 to L do Result[J] := Chr(ReadBits(8));
  end;

begin
  Last := False;
  SR := 0; Ch := 0; Bps := 0; Total := 0;
  while not Last do
  begin
    Hdr := ReadBits(8);
    Last := Hdr and $80 <> 0;
    BType := Hdr and $7F;
    Len := ReadBits(24);
    Start := FilePos;
    case BType of
      0:  { STREAMINFO }
        begin
          FMinBlock := ReadBits(16);
          FMaxBlock := ReadBits(16);
          ReadBits(24);
          ReadBits(24);
          SR := ReadBits(20);
          Ch := ReadBits(3) + 1;
          Bps := ReadBits(5) + 1;
          Total := ReadBits(36);
          for I := 0 to 15 do FMd5[I] := ReadBits(8);
        end;
      3:  { SEEKTABLE }
        begin
          N := Len div 18;
          SetLength(FSeek, 0);
          for I := 0 to N - 1 do
          begin
            SetLength(FSeek, Length(FSeek) + 1);
            FSeek[High(FSeek)].Sample := ReadBits(64);
            FSeek[High(FSeek)].Offset := ReadBits(64);
            ReadBits(16);
            if FSeek[High(FSeek)].Sample = High(QWord) then SetLength(FSeek, Length(FSeek) - 1);
          end;
        end;
      4:  { VORBIS_COMMENT (little endian lengths) }
        begin
          N := U32LE;
          if N > Len then raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid Vorbis comment');
          ReadStr(N);
          Count := U32LE;
          for I := 1 to Count do
          begin
            N := U32LE;
            if (N < 0) or (FilePos + N > Start + Len) then Break;
            S := ReadStr(N);
            ApplyVorbisComment(S, FRg, FTags);
          end;
        end;
    end;
    SeekFile(Start + Len);
  end;
  if (SR = 0) or (Ch = 0) then raise EAuAudio.CreateKind(aekFormat, 'FLAC: missing STREAMINFO');
  FInfo.Kind := skPcmInt;
  FInfo.Codec := 'FLAC';
  FInfo.SampleRate := SR;
  FInfo.Channels := Ch;
  FInfo.BitsPerSample := Bps;
  if Total = 0 then FInfo.TotalFrames := -1 else FInfo.TotalFrames := Total;
end;

procedure TAuFlacDecoder.Open(const AFileName: string);
var
  Id3Size: Integer;
  B: array[0..9] of Byte;
begin
  try
    FFile := TFileStream.Create(LongPath(AFileName), fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do raise EAuAudio.CreateKind(aekFile, 'Cannot open file: ' + E.Message);
  end;
  FFileSize := FFile.Size;
  SetLength(FData, WindowSize);
  SeekFile(0);
  { an ID3v2 tag in front of the stream (not standard, but seen) }
  if (FLen >= 10) and (FData[0] = Ord('I')) and (FData[1] = Ord('D')) and (FData[2] = Ord('3')) then
  begin
    Move(FData[0], B, 10);
    Id3Size := (B[6] and $7F) shl 21 or (B[7] and $7F) shl 14 or (B[8] and $7F) shl 7 or (B[9] and $7F);
    SeekFile(10 + Id3Size);
  end;
  if (ReadBits(8) <> Ord('f')) or (ReadBits(8) <> Ord('L')) or (ReadBits(8) <> Ord('a')) or (ReadBits(8) <> Ord('C')) then
    raise EAuAudio.CreateKind(aekFormat, 'Not a FLAC file');
  ReadMetadata;
  FFirstFrame := FilePos;
  SetLength(FSub, FInfo.Channels);
  FBlockFrames := 0;
  FBlockPos := 0;
  FBlockFirst := 0;
  FPos := 0;
end;

{ ---- frames ---- }

{ parses a frame header at the current (byte aligned) position; False when it
  is not a valid header (wrong sync, reserved values or CRC-8 mismatch) }
function TAuFlacDecoder.ParseHeader(out BlockSize, Bps, ChanAssign: Integer; out FirstSample: Int64): Boolean;
var
  StartIdx, I: Integer;
  Sync, BsCode, SrCode, SsCode: Integer;
  Variable: Boolean;
  Num: QWord;
  Crc: Byte;
begin
  Result := False;
  BlockSize := 0; Bps := 0; ChanAssign := 0; FirstSample := 0;
  Refill(MinAhead);
  if FLen - FIdx < 6 then Exit;
  StartIdx := FIdx;
  Sync := ReadBits(15);
  if Sync <> $7FFC then Exit;
  Variable := ReadBits(1) = 1;
  BsCode := ReadBits(4);
  SrCode := ReadBits(4);
  ChanAssign := ReadBits(4);
  SsCode := ReadBits(3);
  if ReadBits(1) <> 0 then Exit;
  if (BsCode = 0) or (SrCode = 15) or (ChanAssign > 10) or (SsCode = 3) then Exit;
  try
    Num := ReadUtf8Number;
  except
    Exit;
  end;
  case BsCode of
    1: BlockSize := 192;
    2..5: BlockSize := 576 shl (BsCode - 2);
    6: BlockSize := ReadBits(8) + 1;
    7: BlockSize := ReadBits(16) + 1;
  else
    BlockSize := 256 shl (BsCode - 8);
  end;
  case SrCode of
    12: ReadBits(8);
    13, 14: ReadBits(16);
  end;
  case SsCode of
    0: Bps := FInfo.BitsPerSample;
    1: Bps := 8;
    2: Bps := 12;
    4: Bps := 16;
    5: Bps := 20;
    6: Bps := 24;
    7: Bps := 32;
  end;
  { CRC-8 over the header bytes }
  Crc := 0;
  for I := StartIdx to FIdx - 1 - FBitCount div 8 do Crc := Crc8Table[Crc xor FData[I]];
  if ReadBits(8) <> Crc then Exit;
  if Variable then FirstSample := Num
  else FirstSample := Int64(Num) * FMinBlock;
  if (Bps <> FInfo.BitsPerSample) or (BlockSize > 65535) then Exit;
  Result := True;
end;

procedure TAuFlacDecoder.DecodeResidual(BlockSize, Order: Integer; Dest: PInt64);
var
  Method, PartOrder, Parts, P, ParamBits, Esc, Param, N, I, RawBits: Integer;
  U: QWord;
  Q: Cardinal;
begin
  Method := ReadBits(2);
  if Method > 1 then raise EAuAudio.CreateKind(aekFormat, 'FLAC: reserved residual coding');
  if Method = 0 then begin ParamBits := 4; Esc := 15; end
  else begin ParamBits := 5; Esc := 31; end;
  PartOrder := ReadBits(4);
  Parts := 1 shl PartOrder;
  for P := 0 to Parts - 1 do
  begin
    N := BlockSize shr PartOrder;
    if P = 0 then Dec(N, Order);
    if N < 0 then raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid residual partition');
    Param := ReadBits(ParamBits);
    if Param = Esc then
    begin
      RawBits := ReadBits(5);
      for I := 0 to N - 1 do
      begin
        Dest^ := ReadSigned(RawBits);
        Inc(Dest);
      end;
    end
    else
      for I := 0 to N - 1 do
      begin
        Q := ReadUnary;
        U := (QWord(Q) shl Param) or ReadBits(Param);
        Dest^ := Int64(U shr 1) xor -Int64(U and 1);
        Inc(Dest);
      end;
  end;
end;

procedure TAuFlacDecoder.DecodeSubframe(Ch, BlockSize, Bps: Integer);
var
  SType, Wasted, Order, I, J, Prec, Shift: Integer;
  S: PInt64;
  Coefs: array[0..31] of Int64;
  Sum: Int64;
  V: Int64;
begin
  if ReadBits(1) <> 0 then raise EAuAudio.CreateKind(aekFormat, 'FLAC: subframe padding bit set');
  SType := ReadBits(6);
  Wasted := 0;
  if ReadBits(1) = 1 then
  begin
    Wasted := ReadUnary + 1;
    Dec(Bps, Wasted);
  end;
  if Length(FSub[Ch]) < BlockSize then SetLength(FSub[Ch], BlockSize);
  S := @FSub[Ch][0];
  if SType = 0 then
  begin
    V := ReadSigned(Bps);
    for I := 0 to BlockSize - 1 do S[I] := V;
  end
  else if SType = 1 then
  begin
    for I := 0 to BlockSize - 1 do S[I] := ReadSigned(Bps);
  end
  else if (SType >= 8) and (SType <= 12) then
  begin
    Order := SType - 8;
    if Order > BlockSize then raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid predictor order');
    for I := 0 to Order - 1 do S[I] := ReadSigned(Bps);
    DecodeResidual(BlockSize, Order, @S[Order]);
    case Order of
      1: for I := 1 to BlockSize - 1 do S[I] := S[I] + S[I - 1];
      2: for I := 2 to BlockSize - 1 do S[I] := S[I] + 2 * S[I - 1] - S[I - 2];
      3: for I := 3 to BlockSize - 1 do S[I] := S[I] + 3 * S[I - 1] - 3 * S[I - 2] + S[I - 3];
      4: for I := 4 to BlockSize - 1 do S[I] := S[I] + 4 * S[I - 1] - 6 * S[I - 2] + 4 * S[I - 3] - S[I - 4];
    end;
  end
  else if SType >= 32 then
  begin
    Order := SType - 31;
    if Order > BlockSize then raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid LPC order');
    for I := 0 to Order - 1 do S[I] := ReadSigned(Bps);
    Prec := ReadBits(4) + 1;
    if Prec = 16 then raise EAuAudio.CreateKind(aekFormat, 'FLAC: invalid LPC precision');
    Shift := ReadSigned(5);
    if Shift < 0 then raise EAuAudio.CreateKind(aekFormat, 'FLAC: negative LPC shift');
    FillChar(Coefs, SizeOf(Coefs), 0);
    for J := 0 to Order - 1 do Coefs[J] := ReadSigned(Prec);
    DecodeResidual(BlockSize, Order, @S[Order]);
    for I := Order to BlockSize - 1 do
    begin
      Sum := 0;
      for J := 0 to Order - 1 do Sum := Sum + Coefs[J] * S[I - 1 - J];
      S[I] := S[I] + SarInt64(Sum, Shift);
    end;
  end
  else
    raise EAuAudio.CreateKind(aekFormat, 'FLAC: reserved subframe type');
  if Wasted > 0 then
    for I := 0 to BlockSize - 1 do S[I] := S[I] shl Wasted;
end;

function TAuFlacDecoder.DecodeFrame: Boolean;
var
  BlockSize, Bps, CA, Ch, I, NCh: Integer;
  First: Int64;
  A, B, M: Int64;
  L, R: PInt64;
  O: PInt32;
begin
  Result := False;
  ByteAlign;
  Refill(MinAhead);
  if FIdx >= FLen then Exit;
  if not ParseHeader(BlockSize, Bps, CA, First) then
  begin
    { lost sync (damaged file): search the next frame }
    if not FindNextFrame(First) then Exit;
    if not ParseHeader(BlockSize, Bps, CA, First) then Exit;
  end;
  if CA <= 7 then NCh := CA + 1 else NCh := 2;
  if NCh <> FInfo.Channels then raise EAuAudio.CreateKind(aekFormat, 'FLAC: channel count changes');
  for Ch := 0 to NCh - 1 do
  begin
    { the side channel has one bit more }
    if ((CA = 8) and (Ch = 1)) or ((CA = 9) and (Ch = 0)) or ((CA = 10) and (Ch = 1)) then
      DecodeSubframe(Ch, BlockSize, Bps + 1)
    else
      DecodeSubframe(Ch, BlockSize, Bps);
  end;
  ByteAlign;
  ReadBits(16);   // frame CRC-16 (not verified; the stream MD5 is checked by the tests)
  if CA >= 8 then
  begin
    L := @FSub[0][0];
    R := @FSub[1][0];
    case CA of
      8: for I := 0 to BlockSize - 1 do R[I] := L[I] - R[I];              // left / side
      9: for I := 0 to BlockSize - 1 do L[I] := L[I] + R[I];              // side / right
      10: for I := 0 to BlockSize - 1 do                                  // mid / side
          begin
            M := (L[I] shl 1) or (R[I] and 1);
            A := M + R[I];
            B := M - R[I];
            L[I] := SarInt64(A, 1);
            R[I] := SarInt64(B, 1);
          end;
    end;
  end;
  if Length(FBlock) < BlockSize * NCh then SetLength(FBlock, BlockSize * NCh);
  O := @FBlock[0];
  if NCh = 2 then
  begin
    L := @FSub[0][0];
    R := @FSub[1][0];
    for I := 0 to BlockSize - 1 do
    begin
      O[2 * I] := Int32(L[I]);
      O[2 * I + 1] := Int32(R[I]);
    end;
  end
  else
    for Ch := 0 to NCh - 1 do
    begin
      L := @FSub[Ch][0];
      for I := 0 to BlockSize - 1 do O[I * NCh + Ch] := Int32(L[I]);
    end;
  FBlockFrames := BlockSize;
  FBlockPos := 0;
  FBlockFirst := First;
  Result := True;
end;

{ scans forward byte by byte for a valid frame header and stops in front of it }
function TAuFlacDecoder.FindNextFrame(out FirstSample: Int64): Boolean;
var
  Save: Int64;
  BS, Bps, CA: Integer;
begin
  Result := False;
  FirstSample := 0;
  ByteAlign;
  while True do
  begin
    Refill(MinAhead);
    if FIdx + 1 >= FLen then Exit;
    if (FData[FIdx] = $FF) and (FData[FIdx + 1] and $FE = $F8) then
    begin
      Save := FilePos;
      if ParseHeader(BS, Bps, CA, FirstSample) and (CA <= 10) then
      begin
        SeekFile(Save);
        Exit(True);
      end;
      SeekFile(Save + 1);
    end
    else
      Inc(FIdx);
  end;
end;

function TAuFlacDecoder.ReadPcm(Dest: PInt32; MaxFrames: Integer): Integer;
var
  N, Ch: Integer;
begin
  Result := 0;
  Ch := FInfo.Channels;
  while Result < MaxFrames do
  begin
    if FBlockPos >= FBlockFrames then
    begin
      if (FInfo.TotalFrames >= 0) and (FPos >= FInfo.TotalFrames) then Break;
      if not DecodeFrame then Break;
    end;
    N := FBlockFrames - FBlockPos;
    if N > MaxFrames - Result then N := MaxFrames - Result;
    if (FInfo.TotalFrames >= 0) and (FPos + N > FInfo.TotalFrames) then N := FInfo.TotalFrames - FPos;
    if N <= 0 then Break;
    Move(FBlock[FBlockPos * Ch], Dest[Result * Ch], N * Ch * SizeOf(Int32));
    Inc(FBlockPos, N);
    Inc(Result, N);
    Inc(FPos, N);
  end;
end;

procedure TAuFlacDecoder.Seek(Frame: Int64);
var
  I, Best: Integer;
  Est, Back: Int64;
  First: Int64;
  Tries: Integer;
begin
  if Frame < 0 then Frame := 0;
  if (FInfo.TotalFrames >= 0) and (Frame >= FInfo.TotalFrames) then
  begin
    FPos := FInfo.TotalFrames;
    FBlockFrames := 0;
    FBlockPos := 0;
    SeekFile(FFileSize);
    Exit;
  end;
  { 1. a start position: the seek table, otherwise an estimate }
  Best := -1;
  for I := 0 to High(FSeek) do
    if (FSeek[I].Sample <= QWord(Frame)) and ((Best < 0) or (FSeek[I].Sample > FSeek[Best].Sample)) then Best := I;
  if Best >= 0 then
  begin
    SeekFile(FFirstFrame + Int64(FSeek[Best].Offset));
    if not DecodeFrame then raise EAuAudio.CreateKind(aekFormat, 'FLAC: seek failed');
  end
  else
  begin
    Back := 0;
    Tries := 0;
    repeat
      if FInfo.TotalFrames > 0 then
        Est := FFirstFrame + Round((FFileSize - FFirstFrame) * (Frame / FInfo.TotalFrames)) - Back
      else
        Est := FFirstFrame;
      if Est < FFirstFrame then Est := FFirstFrame;
      SeekFile(Est);
      if not FindNextFrame(First) then First := High(Int64);
      if First <= Frame then
      begin
        if not DecodeFrame then raise EAuAudio.CreateKind(aekFormat, 'FLAC: seek failed');
        Break;
      end;
      if Est = FFirstFrame then
      begin
        SeekFile(FFirstFrame);
        if not DecodeFrame then raise EAuAudio.CreateKind(aekFormat, 'FLAC: seek failed');
        Break;
      end;
      if Back = 0 then Back := 64 * 1024 else Back := Back * 4;
      Inc(Tries);
    until Tries > 30;
  end;
  { 2. decode forward to the frame that holds the target sample }
  while FBlockFirst + FBlockFrames <= Frame do
    if not DecodeFrame then Break;
  FBlockPos := Integer(Math.Max(0, Math.Min(Frame - FBlockFirst, FBlockFrames)));
  FPos := FBlockFirst + FBlockPos;
end;

initialization
  InitCrc8;

end.
