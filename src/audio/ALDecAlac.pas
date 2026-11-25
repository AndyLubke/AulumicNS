unit ALDecAlac;

{$mode ObjFPC}{$H+}
{$R-}{$Q-}

{ ==============================================================================
  AulumicNS - ALDecAlac
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Decodes Apple Lossless (ALAC) packets, written after the published format.

  A packet holds one or more elements: a single channel, a channel pair, or
  the LFE channel, then an end mark. Each element is stored either as it is
  or compressed: the samples are predicted by a short adaptive filter and the
  differences are written with an adaptive Golomb-Rice code. A channel pair
  may be stored as a sum and a difference, and the low bytes of samples wider
  than 16 bit may lie uncoded in front of the coded data.

  Every packet stands for itself (the filter starts anew), so any packet can
  be decoded without the ones before it. The arithmetic wraps at 32 bit as
  the format defines it: range and overflow checks are off in this unit.
==============================================================================}

interface

uses
  SysUtils;

const
  ALAC_MAX_CHANNELS = 8;

type
  EAlacError = class(Exception);

  TAlacChannel = array of Integer;

  { TAlacDecoder }

  TAlacDecoder = class
  private
    FFrameLength: Cardinal;
    FBitDepth: Integer;
    FPb, FMb, FKb: Integer;
    FChannels: Integer;
    FMaxRun: Integer;
    FSampleRate: Cardinal;
    // the packet in work, with room behind it for reads beyond its end
    FData: array of Byte;
    FBits: Int64;            // bits of the packet
    FPos: Int64;             // the bit to read next
    FPredictor: array of Integer;
    FShift: array of Word;
    FMixU, FMixV: array of Integer;
    function Peek32(APos: Int64): Cardinal;
    function Read(ABits: Integer): Cardinal;
    procedure Skip(ABits: Int64);
    procedure Entropy(APb: Integer; ACount: Integer; AMaxSize: Integer);
    procedure Unpredict(var AOut: array of Integer; ACount: Integer; var ACoefs: array of SmallInt;
      ANumActive, AChanBits, ADenShift: Integer);
    procedure Element(APair: Boolean; var ALeft, ARight: TAlacChannel; var ACount: Integer);
  public
    // ACookie: the decoder's settings as the file stores them (24 bytes, or
    // with the 12 bytes of an older form in front)
    constructor Create(const ACookie: array of Byte);
    // Decodes one packet into AOut (one array of FrameLength samples per
    // channel, in the order the packet stores them); returns the samples per
    // channel. The samples have the file's bit depth.
    function Decode(APacket: PByte; ASize: Integer; var AOut: array of TAlacChannel): Integer;
    property FrameLength: Cardinal read FFrameLength;
    property BitDepth: Integer read FBitDepth;
    property Channels: Integer read FChannels;
    property SampleRate: Cardinal read FSampleRate;
  end;

implementation

const
  // The elements of a packet
  ID_SCE = 0;   // one channel
  ID_CPE = 1;   // a channel pair
  ID_CCE = 2;
  ID_LFE = 3;
  ID_DSE = 4;   // data to pass over
  ID_PCE = 5;
  ID_FIL = 6;   // filling
  ID_END = 7;

  // The adaptive Golomb-Rice code
  QBSHIFT          = 9;
  QB               = 1 shl QBSHIFT;
  MMULSHIFT        = 2;
  MDENSHIFT        = QBSHIFT - MMULSHIFT - 1;
  MOFF             = 1 shl (MDENSHIFT - 2);
  BITOFF           = 24;
  MAX_PREFIX       = 9;
  MAX_RUN_BITS     = 16;
  N_MAX_MEAN_CLAMP = $FFFF;
  N_MEAN_CLAMP_VAL = $FFFF;

  PAD_BYTES = 16;

// The number of zero bits in front of the first one (32 for 0)
function Lead(AValue: Cardinal): Integer; inline;
begin
  if AValue = 0 then
    Result := 32
  else
    Result := 31 - BsrDWord(AValue);
end;

function SignOf(AValue: Integer): Integer; inline;
begin
  if AValue > 0 then Result := 1
  else if AValue < 0 then Result := -1
  else Result := 0;
end;

// The lowest ABits bits of AValue as a signed number
function Extend(AValue: Integer; ABits: Integer): Integer; inline;
begin
  if ABits >= 32 then
    Result := AValue
  else
    Result := SarLongint(Integer(Cardinal(AValue) shl (32 - ABits)), 32 - ABits);
end;

{ TAlacDecoder }

constructor TAlacDecoder.Create(const ACookie: array of Byte);
var
  O: Integer;

  function U32(APos: Integer): Cardinal;
  begin
    Result := (Cardinal(ACookie[APos]) shl 24) or (Cardinal(ACookie[APos + 1]) shl 16) or
              (Cardinal(ACookie[APos + 2]) shl 8) or ACookie[APos + 3];
  end;

begin
  inherited Create;
  // Older files put a 'frma' box and the box header in front of the settings
  O := 0;
  if (Length(ACookie) >= 36) and (ACookie[4] = Ord('f')) and (ACookie[5] = Ord('r')) and
     (ACookie[6] = Ord('m')) and (ACookie[7] = Ord('a')) then
    O := 12;
  if (Length(ACookie) >= O + 36) and (ACookie[O + 4] = Ord('a')) and (ACookie[O + 5] = Ord('l')) and
     (ACookie[O + 6] = Ord('a')) and (ACookie[O + 7] = Ord('c')) then
    Inc(O, 12);
  if Length(ACookie) < O + 24 then
    raise EAlacError.Create('ALAC: the decoder settings are missing');

  FFrameLength := U32(O);
  FBitDepth    := ACookie[O + 5];
  FPb          := ACookie[O + 6];
  FMb          := ACookie[O + 7];
  FKb          := ACookie[O + 8];
  FChannels    := ACookie[O + 9];
  FMaxRun      := (Integer(ACookie[O + 10]) shl 8) or ACookie[O + 11];
  FSampleRate  := U32(O + 20);

  if (FFrameLength = 0) or (FFrameLength > 65536) or (FChannels < 1) or (FChannels > ALAC_MAX_CHANNELS) or
     (not (FBitDepth in [16, 20, 24, 32])) or (FSampleRate = 0) or (FKb < 1) or (FKb > 24) then
    raise EAlacError.Create('ALAC: the decoder settings are not usable');

  SetLength(FPredictor, FFrameLength);
  SetLength(FShift, FFrameLength * 2);
  SetLength(FMixU, FFrameLength);
  SetLength(FMixV, FFrameLength);
end;

// The 32 bits from bit APos on; bits behind the packet read as zero
function TAlacDecoder.Peek32(APos: Int64): Cardinal;
var
  P: Int64;
  V: QWord;
begin
  P := APos shr 3;
  if P + 5 > Length(FData) then
    Exit(0);
  V := (QWord(FData[P]) shl 32) or (QWord(FData[P + 1]) shl 24) or (QWord(FData[P + 2]) shl 16) or
       (QWord(FData[P + 3]) shl 8) or FData[P + 4];
  Result := Cardinal(V shr (8 - (APos and 7)));
end;

function TAlacDecoder.Read(ABits: Integer): Cardinal;
begin
  if ABits <= 0 then
    Exit(0);
  if FPos + ABits > FBits then
    raise EAlacError.Create('ALAC: a packet ends before its data');
  Result := Peek32(FPos) shr (32 - ABits);
  Inc(FPos, ABits);
end;

procedure TAlacDecoder.Skip(ABits: Int64);
begin
  if (ABits < 0) or (FPos + ABits > FBits) then
    raise EAlacError.Create('ALAC: a packet ends before its data');
  Inc(FPos, ABits);
end;

// The coded differences of one channel into FPredictor. APb: how fast the
// mean of the code follows the data; AMaxSize: the bits of a value that is
// stored uncoded.
procedure TAlacDecoder.Entropy(APb: Integer; ACount: Integer; AMaxSize: Integer);
var
  C, J: Integer;
  Mb, M, K, N, V, Pre, Stream, ZMode, NDecode, Mz, Wb: Cardinal;
  Multiplier: Integer;
begin
  if AMaxSize > 32 then
    AMaxSize := 32;
  Mb    := Cardinal(FMb);
  Wb    := (Cardinal(1) shl FKb) - 1;
  ZMode := 0;
  C     := 0;
  while C < ACount do
  begin
    if FPos >= FBits then
      raise EAlacError.Create('ALAC: a packet ends before its data');

    M := Mb shr QBSHIFT;
    K := 31 - Lead(M + 3);
    if K > Cardinal(FKb) then
      K := Cardinal(FKb);
    M := (Cardinal(1) shl K) - 1;

    // one value: a run of ones, a zero, then K bits - or, after nine ones,
    // the value itself
    Stream := Peek32(FPos);
    Pre    := Lead(not Stream);
    if Pre >= MAX_PREFIX then
    begin
      Inc(FPos, MAX_PREFIX);
      N := Read(AMaxSize);
    end
    else
    begin
      Inc(FPos, Pre + 1);
      N := Pre;
      if K <> 1 then
      begin
        V := Peek32(FPos) shr (32 - K);
        N := Pre * M;
        if V >= 2 then
        begin
          N := N + V - 1;
          Inc(FPos, K);
        end
        else
          Inc(FPos, K - 1);
      end;
    end;

    // the lowest bit is the sign
    NDecode    := N + ZMode;
    Multiplier := -Integer(NDecode and 1);
    Multiplier := Multiplier or 1;
    FPredictor[C] := Integer((NDecode + 1) shr 1) * Multiplier;
    Inc(C);

    Mb := Cardinal(APb) * (N + ZMode) + Mb - ((Cardinal(APb) * Mb) shr QBSHIFT);
    if N > N_MAX_MEAN_CLAMP then
      Mb := N_MEAN_CLAMP_VAL;
    ZMode := 0;

    // a small mean: a run of zeros follows, its length coded the same way
    if ((Mb shl MMULSHIFT) < QB) and (C < ACount) then
    begin
      ZMode := 1;
      K  := Cardinal(Lead(Mb) - BITOFF) + ((Mb + MOFF) shr MDENSHIFT);
      Mz := ((Cardinal(1) shl K) - 1) and Wb;

      Stream := Peek32(FPos);
      Pre    := Lead(not Stream);
      if Pre >= MAX_PREFIX then
      begin
        Inc(FPos, MAX_PREFIX);
        N := Peek32(FPos) shr (32 - MAX_RUN_BITS);
        Inc(FPos, MAX_RUN_BITS);
      end
      else
      begin
        Inc(FPos, Pre + 1);
        V := Peek32(FPos) shr (32 - K);
        if V >= 2 then
        begin
          N := Pre * Mz + V - 1;
          Inc(FPos, K);
        end
        else
        begin
          N := Pre * Mz;
          Inc(FPos, K - 1);
        end;
      end;

      if Int64(C) + N > ACount then
        raise EAlacError.Create('ALAC: a run of zeros is longer than the packet');
      for J := 1 to Integer(N) do
      begin
        FPredictor[C] := 0;
        Inc(C);
      end;
      if N >= 65535 then
        ZMode := 0;
      Mb := 0;
    end;
  end;
  if FPos > FBits then
    raise EAlacError.Create('ALAC: a packet ends before its data');
end;

// The samples of one channel from the differences in FPredictor: each one is
// the difference plus what the filter foretells from the samples before it,
// and the filter follows the sign of every difference.
// ANumActive 31: every sample is the one before plus its difference.
procedure TAlacDecoder.Unpredict(var AOut: array of Integer; ACount: Integer; var ACoefs: array of SmallInt;
  ANumActive, AChanBits, ADenShift: Integer);
var
  J, K, Lim, Sum, Del, Del0, Sg, Sgn, Dd, Top, Prev, DenHalf: Integer;
begin
  if ACount <= 0 then
    Exit;
  AOut[0] := FPredictor[0];
  if ANumActive = 0 then
  begin
    for J := 1 to ACount - 1 do
      AOut[J] := FPredictor[J];
    Exit;
  end;

  if ANumActive = 31 then
  begin
    Prev := AOut[0];
    for J := 1 to ACount - 1 do
    begin
      Prev    := Extend(FPredictor[J] + Prev, AChanBits);
      AOut[J] := Prev;
    end;
    Exit;
  end;

  // the first samples, before the filter has enough behind it
  for J := 1 to ANumActive do
  begin
    if J >= ACount then
      Exit;
    AOut[J] := Extend(FPredictor[J] + AOut[J - 1], AChanBits);
  end;

  Lim := ANumActive + 1;
  if ADenShift > 0 then
    DenHalf := 1 shl (ADenShift - 1)
  else
    DenHalf := 0;
  for J := Lim to ACount - 1 do
  begin
    Top := AOut[J - Lim];
    Sum := 0;
    for K := 0 to ANumActive - 1 do
      Sum := Sum + ACoefs[K] * (AOut[J - 1 - K] - Top);

    Del  := FPredictor[J];
    Del0 := Del;
    Sg   := SignOf(Del);
    Del  := Del + Top + SarLongint(Sum + DenHalf, ADenShift);
    AOut[J] := Extend(Del, AChanBits);

    if Sg > 0 then
    begin
      for K := ANumActive - 1 downto 0 do
      begin
        Dd  := Top - AOut[J - 1 - K];
        Sgn := SignOf(Dd);
        ACoefs[K] := SmallInt(ACoefs[K] - Sgn);
        Del0 := Del0 - (ANumActive - K) * SarLongint(Sgn * Dd, ADenShift);
        if Del0 <= 0 then
          Break;
      end;
    end
    else if Sg < 0 then
    begin
      for K := ANumActive - 1 downto 0 do
      begin
        Dd  := Top - AOut[J - 1 - K];
        Sgn := SignOf(Dd);
        ACoefs[K] := SmallInt(ACoefs[K] + Sgn);
        Del0 := Del0 - (ANumActive - K) * SarLongint(-Sgn * Dd, ADenShift);
        if Del0 >= 0 then
          Break;
      end;
    end;
  end;
end;

// One element: a single channel into ALeft, or a pair into ALeft and ARight
procedure TAlacDecoder.Element(APair: Boolean; var ALeft, ARight: TAlacChannel; var ACount: Integer);
var
  Header, BytesShifted, ChanBits, Shift, MixBits, MixRes, I, N, ExtraBits: Integer;
  Partial, Escape: Boolean;
  Mode, DenShift, PbFactor, NumCoefs: array[0..1] of Integer;
  Coefs: array[0..1] of array[0..31] of SmallInt;
  ShiftStart, After: Int64;
  Ch, NCh, L, R, Val: Integer;
begin
  if APair then NCh := 2 else NCh := 1;
  for Ch := 0 to 1 do
  begin
    Mode[Ch]     := 0;
    DenShift[Ch] := 0;
    PbFactor[Ch] := 0;
    NumCoefs[Ch] := 0;
  end;

  Read(4);                                // the number of the element
  if Read(12) <> 0 then
    raise EAlacError.Create('ALAC: a packet is damaged');
  Header       := Read(4);
  Partial      := (Header shr 3) <> 0;
  BytesShifted := (Header shr 1) and 3;
  Escape       := (Header and 1) <> 0;
  if BytesShifted = 3 then
    raise EAlacError.Create('ALAC: a packet is damaged');
  Shift := BytesShifted * 8;

  N := FFrameLength;
  if Partial then
  begin
    N := Integer(Read(16) shl 16);
    N := N or Integer(Read(16));
    if (N < 0) or (Cardinal(N) > FFrameLength) then
      raise EAlacError.Create('ALAC: a packet is longer than the file allows');
  end;
  ACount := N;

  if not Escape then
  begin
    ChanBits := FBitDepth - Shift + NCh - 1;
    MixBits  := Read(8);
    MixRes   := ShortInt(Read(8));

    for Ch := 0 to NCh - 1 do
    begin
      Header        := Read(8);
      Mode[Ch]      := Header shr 4;
      DenShift[Ch]  := Header and $F;
      Header        := Read(8);
      PbFactor[Ch]  := Header shr 5;
      NumCoefs[Ch]  := Header and $1F;
      for I := 0 to NumCoefs[Ch] - 1 do
        Coefs[Ch][I] := SmallInt(Read(16));
    end;

    // the low bytes of every sample lie uncoded in front of the coded data
    ShiftStart := FPos;
    if BytesShifted <> 0 then
      Skip(Int64(Shift) * NCh * N);

    for Ch := 0 to NCh - 1 do
    begin
      Entropy((FPb * PbFactor[Ch]) div 4, N, ChanBits);
      if Ch = 0 then
      begin
        if Mode[Ch] <> 0 then
        begin
          Unpredict(FPredictor, N, Coefs[Ch], 31, ChanBits, 0);
        end;
        Unpredict(FMixU, N, Coefs[Ch], NumCoefs[Ch], ChanBits, DenShift[Ch]);
      end
      else
      begin
        if Mode[Ch] <> 0 then
          Unpredict(FPredictor, N, Coefs[Ch], 31, ChanBits, 0);
        Unpredict(FMixV, N, Coefs[Ch], NumCoefs[Ch], ChanBits, DenShift[Ch]);
      end;
    end;

    if BytesShifted <> 0 then
    begin
      After := FPos;
      FPos  := ShiftStart;
      for I := 0 to N * NCh - 1 do
        FShift[I] := Word(Read(Shift));
      FPos := After;
    end;
  end
  else
  begin
    // stored as it is
    ChanBits := FBitDepth;
    Shift    := 0;
    BytesShifted := 0;
    MixBits  := 0;
    MixRes   := 0;
    ExtraBits := ChanBits - 16;
    for I := 0 to N - 1 do
      for Ch := 0 to NCh - 1 do
      begin
        if ChanBits <= 16 then
          Val := Extend(Integer(Read(ChanBits)), ChanBits)
        else
        begin
          Val := Extend(Integer(Read(16)), 16) shl ExtraBits;
          Val := Val or Integer(Read(ExtraBits));
        end;
        if Ch = 0 then FMixU[I] := Val else FMixV[I] := Val;
      end;
  end;

  // a pair may be stored as a sum and a difference
  if APair then
  begin
    for I := 0 to N - 1 do
    begin
      if MixRes <> 0 then
      begin
        L := FMixU[I] + FMixV[I] - SarLongint(MixRes * FMixV[I], MixBits);
        R := L - FMixV[I];
      end
      else
      begin
        L := FMixU[I];
        R := FMixV[I];
      end;
      if BytesShifted <> 0 then
      begin
        L := Integer(Cardinal(L) shl Shift) or FShift[I * 2];
        R := Integer(Cardinal(R) shl Shift) or FShift[I * 2 + 1];
      end;
      ALeft[I]  := L;
      ARight[I] := R;
    end;
  end
  else
    for I := 0 to N - 1 do
    begin
      L := FMixU[I];
      if BytesShifted <> 0 then
        L := Integer(Cardinal(L) shl Shift) or FShift[I];
      ALeft[I] := L;
    end;
end;

function TAlacDecoder.Decode(APacket: PByte; ASize: Integer; var AOut: array of TAlacChannel): Integer;
var
  Tag, Channel, Count, N, Bytes: Integer;
  Dummy: TAlacChannel;
begin
  Result := 0;
  if (APacket = nil) or (ASize <= 0) then
    Exit;
  if Length(AOut) < FChannels then
    raise EAlacError.Create('ALAC: not enough room for the channels');

  if Length(FData) < ASize + PAD_BYTES then
    SetLength(FData, ASize + PAD_BYTES);
  Move(APacket^, FData[0], ASize);
  FillChar(FData[ASize], Length(FData) - ASize, 0);
  FBits := Int64(ASize) * 8;
  FPos  := 0;

  Dummy   := nil;
  Channel := 0;
  Count   := -1;
  while FPos + 3 <= FBits do
  begin
    Tag := Read(3);
    case Tag of
      ID_SCE, ID_LFE:
        begin
          if Channel >= FChannels then
            raise EAlacError.Create('ALAC: a packet has more channels than the file');
          N := 0;
          Element(False, AOut[Channel], Dummy, N);
          Inc(Channel);
        end;
      ID_CPE:
        begin
          if Channel + 1 >= FChannels then
            raise EAlacError.Create('ALAC: a packet has more channels than the file');
          N := 0;
          Element(True, AOut[Channel], AOut[Channel + 1], N);
          Inc(Channel, 2);
        end;
      ID_DSE:
        begin
          Read(4);
          N := Read(1);                       // the data starts at a whole byte
          Bytes := Read(8);
          if Bytes = 255 then
            Bytes := Bytes + Integer(Read(8));
          if N <> 0 then
            FPos := (FPos + 7) and not Int64(7);
          Skip(Int64(Bytes) * 8);
          Continue;
        end;
      ID_FIL:
        begin
          N := Read(4);
          if N = 15 then
            N := N + Integer(Read(8)) - 1;
          Skip(Int64(N) * 8);
          Continue;
        end;
      ID_END:
        Break;
    else
      raise EAlacError.Create('ALAC: a kind of packet that is not supported');
    end;

    // every element of a packet has the same number of samples
    if Count < 0 then
      Count := N
    else if N <> Count then
      raise EAlacError.Create('ALAC: a packet is damaged');
    if Channel >= FChannels then
      Break;
  end;

  if (Channel <> FChannels) or (Count < 0) then
    raise EAlacError.Create('ALAC: a packet does not hold every channel');
  Result := Count;
end;

end.
