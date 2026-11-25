unit ALMp4;

{$mode ObjFPC}{$H+}
{$R-}{$Q-}

{ ==============================================================================
  AulumicNS - ALMp4
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Reads the description of an MP4 / M4A file: its first sound track (what it
  is coded in, the decoder's settings, where every packet lies) and its tags
  (the iTunes list under moov.udta.meta.ilst).

  Only the 'moov' box is read, into memory; the sound itself stays in the
  file. Every size and count is checked against what the file holds before it
  is used, so a damaged file gives an error and never a wild read.
  The file name is UTF-8.
==============================================================================}

interface

uses
  SysUtils, Classes;

type
  EMp4Error = class(Exception);

  // One entry of the tag list. Name: the four characters of the box
  // (#$A9'nam', 'trkn', 'covr' ...), or the name of a free-form entry
  // ('----': e.g. 'replaygain_track_gain'), then with FreeForm set.
  // Kind: the type of the value as the file gives it (1 text in UTF-8,
  // 13 JPEG, 14 PNG, 21 a whole number, 0 bytes).
  TMp4TagItem = record
    Name: string;
    FreeForm: Boolean;
    Kind: Integer;
    Data: TBytes;
    Box: Integer;            // the entry of the list it comes from (TagBox)
  end;

  TMp4Tags = array of TMp4TagItem;

  { TMp4File }

  TMp4File = class
  private
    FMoov: TBytes;
    FCodec: string;
    FCookie: TBytes;
    FTimeScale: Cardinal;
    FDuration: Int64;
    FChannels: Integer;
    FSampleSize: Integer;
    FSampleRate: Cardinal;
    FPacketOffset: array of Int64;
    FPacketSize: array of Cardinal;
    FTotalFrames: Int64;
    FTags: TMp4Tags;
    FTagBoxes: array of TBytes;
    FTagBoxNames: array of string;
    FTagListComplete: Boolean;
    FFileSize: Int64;
    FWantTags, FWantPictures: Boolean;
    function BE32(APos: Int64): Cardinal;
    function BE64(APos: Int64): Int64;
    function BoxAt(APos, ALimit: Int64; out AType: string; out ABody, AEnd: Int64): Boolean;
    function FindBox(AFrom, ATo: Int64; const AType: string; out ABody, AEnd: Int64): Boolean;
    procedure ReadTrack(ABody, AEnd: Int64; var ADone: Boolean);
    procedure ReadSampleTable(ABody, AEnd: Int64);
    procedure ReadDescription(ABody, AEnd: Int64);
    procedure ReadTags(ABody, AEnd: Int64);
    function GetPacketCount: Integer;
    function GetTagBoxCount: Integer;
  public
    // ATags: the tag list is read as well; APictures: with the pictures in it
    constructor Create(const AFileName: string; ATags: Boolean = False; APictures: Boolean = False);
    function PacketOffset(AIndex: Integer): Int64;
    function PacketSize(AIndex: Integer): Cardinal;
    // What the sound track is coded in: 'alac', 'mp4a' (AAC) ... ('' = no sound track)
    property Codec: string read FCodec;
    // The decoder's settings as the file stores them (for ALAC: 24 bytes)
    property Cookie: TBytes read FCookie;
    property Channels: Integer read FChannels;
    property SampleSize: Integer read FSampleSize;
    property SampleRate: Cardinal read FSampleRate;
    property PacketCount: Integer read GetPacketCount;
    // The frames of the whole track, from its table of durations
    property TotalFrames: Int64 read FTotalFrames;
    property Tags: TMp4Tags read FTags;
    // The entries of the tag list as they stand in the file, each with its
    // box header, in their order (read with ATags and APictures); and the
    // name of each: its four characters, or the name of a free-form entry
    property TagBoxCount: Integer read GetTagBoxCount;
    // False when the list holds bytes that are no entry: a save would lose them
    property TagListComplete: Boolean read FTagListComplete;
    function TagBox(AIndex: Integer): TBytes;
    function TagBoxName(AIndex: Integer): string;
  end;

// One entry of a tag list: text (every value a 'data' box of its own), a
// value of bytes with its kind, and a free-form entry ('----') with its name
function Mp4TextEntry(const AName: string; const AValues: array of string): TBytes;
function Mp4DataEntry(const AName: string; AKind: Integer; const AData: TBytes): TBytes;
function Mp4FreeFormEntry(const AName: string; const AValues: array of string): TBytes;

// Writes ASource to ADest with the entries of its tag list replaced by
// AEntries (the entries one after the other, each with its box header; empty:
// no tags). Everything else of the file is copied as it is; when the sound
// lies behind the description, its positions are moved by what the list grew
// or shrank. Before True is returned, ADest is read again and every packet of
// its sound is compared with ASource. False with the reason in AError when
// the file has a form this cannot rewrite safely, or the check fails; ADest
// is then not to be used.
function Mp4ReplaceTags(const ASource, ADest: string; const AEntries: TBytes; out AError: string): Boolean;

// True when the file starts like an MP4 file (an 'ftyp' box)
function IsMp4File(const AFileName: string): Boolean;

implementation

uses
  AuAudioTypes;   // LongPath (paths of 260 characters and more)

const
  MAX_MOOV_BYTES = 256 * 1024 * 1024;
  MAX_PACKETS    = 64 * 1024 * 1024;

function IsMp4File(const AFileName: string): Boolean;
var
  F: TStream;
  B: array[0..7] of Byte;
begin
  Result := False;
  try
    F := AuOpenFile(AFileName, fmOpenRead or fmShareDenyNone);
    try
      if F.Read(B, 8) = 8 then
        Result := (B[4] = Ord('f')) and (B[5] = Ord('t')) and (B[6] = Ord('y')) and (B[7] = Ord('p'));
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

{ TMp4File }

function TMp4File.BE32(APos: Int64): Cardinal;
begin
  if (APos < 0) or (APos + 4 > Length(FMoov)) then
    raise EMp4Error.Create('MP4: a box ends before its data');
  Result := (Cardinal(FMoov[APos]) shl 24) or (Cardinal(FMoov[APos + 1]) shl 16) or
            (Cardinal(FMoov[APos + 2]) shl 8) or FMoov[APos + 3];
end;

function TMp4File.BE64(APos: Int64): Int64;
begin
  Result := (Int64(BE32(APos)) shl 32) or BE32(APos + 4);
end;

// The box at APos inside FMoov, which may not reach beyond ALimit
function TMp4File.BoxAt(APos, ALimit: Int64; out AType: string; out ABody, AEnd: Int64): Boolean;
var
  Size: Int64;
begin
  Result := False;
  AType  := '';
  ABody  := 0;
  AEnd   := 0;
  if APos + 8 > ALimit then
    Exit;
  Size := BE32(APos);
  SetString(AType, PAnsiChar(@FMoov[APos + 4]), 4);
  ABody := APos + 8;
  if Size = 1 then
  begin
    if APos + 16 > ALimit then
      Exit;
    Size  := BE64(APos + 8);
    ABody := APos + 16;
  end
  else if Size = 0 then
    Size := ALimit - APos;
  AEnd := APos + Size;
  Result := (Size >= ABody - APos) and (AEnd <= ALimit);
end;

function TMp4File.FindBox(AFrom, ATo: Int64; const AType: string; out ABody, AEnd: Int64): Boolean;
var
  T: string;
  P: Int64;
begin
  T := '';
  P := AFrom;
  while BoxAt(P, ATo, T, ABody, AEnd) do
  begin
    if T = AType then
      Exit(True);
    P := AEnd;
  end;
  ABody  := 0;
  AEnd   := 0;
  Result := False;
end;

constructor TMp4File.Create(const AFileName: string; ATags: Boolean; APictures: Boolean);
var
  F: TStream;
  Hdr: array[0..15] of Byte;
  Pos, Size, Body, BoxEnd, B2, E2, B3, E3: Int64;
  T: string;
  Done: Boolean;
begin
  inherited Create;
  FWantTags        := ATags;
  FWantPictures    := APictures;
  FTagListComplete := True;
  F := AuOpenFile(AFileName, fmOpenRead or fmShareDenyNone);
  try
    FFileSize := F.Size;
    // The boxes of the file, one after the other, until 'moov'
    Pos := 0;
    while Pos + 8 <= FFileSize do
    begin
      F.Position := Pos;
      if F.Read(Hdr, 8) < 8 then
        Break;
      Size := (Int64(Hdr[0]) shl 24) or (Int64(Hdr[1]) shl 16) or (Int64(Hdr[2]) shl 8) or Hdr[3];
      SetString(T, PAnsiChar(@Hdr[4]), 4);
      Body := Pos + 8;
      if Size = 1 then
      begin
        if F.Read(Hdr[8], 8) < 8 then
          Break;
        Size := (Int64(Hdr[8]) shl 56) or (Int64(Hdr[9]) shl 48) or (Int64(Hdr[10]) shl 40) or
                (Int64(Hdr[11]) shl 32) or (Int64(Hdr[12]) shl 24) or (Int64(Hdr[13]) shl 16) or
                (Int64(Hdr[14]) shl 8) or Hdr[15];
        Body := Pos + 16;
      end
      else if Size = 0 then
        Size := FFileSize - Pos;
      if (Size < Body - Pos) or (Pos + Size > FFileSize) then
        raise EMp4Error.Create('MP4: a box runs out of the file');
      if (Pos = 0) and (T <> 'ftyp') then
        raise EMp4Error.Create('Not an MP4 file');
      if T = 'moov' then
      begin
        if Size - (Body - Pos) > MAX_MOOV_BYTES then
          raise EMp4Error.Create('MP4: the description of the file is too large');
        SetLength(FMoov, Size - (Body - Pos));
        F.Position := Body;
        if Length(FMoov) > 0 then
          F.ReadBuffer(FMoov[0], Length(FMoov));
        Break;
      end;
      Pos := Pos + Size;
    end;
  finally
    F.Free;
  end;
  if Length(FMoov) = 0 then
    raise EMp4Error.Create('MP4: no description of the sound (moov) in the file');

  // The first sound track
  Done := False;
  Pos  := 0;
  T    := '';
  while (not Done) and BoxAt(Pos, Length(FMoov), T, Body, BoxEnd) do
  begin
    if T = 'trak' then
      ReadTrack(Body, BoxEnd, Done);
    Pos := BoxEnd;
  end;

  if FWantTags and FindBox(0, Length(FMoov), 'udta', B2, E2) and FindBox(B2, E2, 'meta', B3, E3) then
  begin
    // 'meta' has four bytes of version and flags before its boxes; some
    // writers leave them out
    if FindBox(B3 + 4, E3, 'ilst', Body, BoxEnd) or FindBox(B3, E3, 'ilst', Body, BoxEnd) then
      ReadTags(Body, BoxEnd);
  end;
end;

procedure TMp4File.ReadTrack(ABody, AEnd: Int64; var ADone: Boolean);
var
  MdiaB, MdiaE, B, E, MinfB, MinfE, StblB, StblE: Int64;
  Handler: string;
begin
  if not FindBox(ABody, AEnd, 'mdia', MdiaB, MdiaE) then
    Exit;
  // Only a sound track
  if (not FindBox(MdiaB, MdiaE, 'hdlr', B, E)) or (E - B < 12) then
    Exit;
  SetString(Handler, PAnsiChar(@FMoov[B + 8]), 4);
  if Handler <> 'soun' then
    Exit;

  if FindBox(MdiaB, MdiaE, 'mdhd', B, E) and (E - B >= 20) then
  begin
    if FMoov[B] = 1 then
    begin
      if E - B >= 32 then
      begin
        FTimeScale := BE32(B + 20);
        FDuration  := BE64(B + 24);
      end;
    end
    else
    begin
      FTimeScale := BE32(B + 12);
      FDuration  := BE32(B + 16);
    end;
  end;

  if FindBox(MdiaB, MdiaE, 'minf', MinfB, MinfE) and FindBox(MinfB, MinfE, 'stbl', StblB, StblE) then
  begin
    ReadSampleTable(StblB, StblE);
    ADone := FCodec <> '';
  end;
end;

// The entry of 'stsd': what the sound is coded in and the decoder's settings
procedure TMp4File.ReadDescription(ABody, AEnd: Int64);
var
  EntrySize, Version: Integer;
  Entry, Child, ChildEnd, P, CB, CE: Int64;
  T: string;
begin
  if (AEnd - ABody < 16) or (BE32(ABody + 4) < 1) then
    Exit;
  Entry     := ABody + 8;
  EntrySize := BE32(Entry);
  if (EntrySize < 36) or (Entry + EntrySize > AEnd) then
    Exit;
  SetString(FCodec, PAnsiChar(@FMoov[Entry + 4]), 4);
  // 8 bytes of box, 6 reserved, 2 data reference, then the sound entry
  Version     := (Integer(FMoov[Entry + 16]) shl 8) or FMoov[Entry + 17];
  FChannels   := (Integer(FMoov[Entry + 24]) shl 8) or FMoov[Entry + 25];
  FSampleSize := (Integer(FMoov[Entry + 26]) shl 8) or FMoov[Entry + 27];
  FSampleRate := BE32(Entry + 32) shr 16;
  Child := Entry + 36;
  if Version = 1 then Inc(Child, 16)
  else if Version = 2 then Inc(Child, 36);
  ChildEnd := Entry + EntrySize;
  T := '';

  // The box with the decoder's settings carries the name of the coding
  P := Child;
  while BoxAt(P, ChildEnd, T, CB, CE) do
  begin
    if (T = FCodec) and (CE - CB > 4) then
    begin
      SetLength(FCookie, CE - CB - 4);          // behind version and flags
      Move(FMoov[CB + 4], FCookie[0], Length(FCookie));
      Break;
    end;
    P := CE;
  end;
end;

procedure TMp4File.ReadSampleTable(ABody, AEnd: Int64);
var
  B, E, SzB, SzE, ScB, ScE, CoB, CoE, P: Int64;
  Count, Uniform, I, ChunkCount, Entries, K, PerChunk, NextFirst, Chunk, S, N: Cardinal;
  Wide: Boolean;
  Offset: Int64;
begin
  if FindBox(ABody, AEnd, 'stsd', B, E) then
    ReadDescription(B, E);
  if FCodec = '' then
    Exit;

  // The frames of the track: the sum of its durations
  FTotalFrames := 0;
  if FindBox(ABody, AEnd, 'stts', B, E) and (E - B >= 8) then
  begin
    Entries := BE32(B + 4);
    if Int64(Entries) * 8 <= E - B - 8 then
      for I := 1 to Entries do
        Inc(FTotalFrames, Int64(BE32(B + 8 + Int64(I - 1) * 8)) * BE32(B + 12 + Int64(I - 1) * 8));
  end;

  // The size of every packet
  if (not FindBox(ABody, AEnd, 'stsz', SzB, SzE)) or (SzE - SzB < 12) then
    raise EMp4Error.Create('MP4: no table of packet sizes');
  Uniform := BE32(SzB + 4);
  Count   := BE32(SzB + 8);
  // every packet has a size of its own in the table, or all have one size:
  // then no more of them than the file has room for
  if (Count > MAX_PACKETS) or ((Uniform = 0) and (Int64(Count) * 4 > SzE - SzB - 12)) or
     ((Uniform <> 0) and (Int64(Count) * Uniform > FFileSize)) then
    raise EMp4Error.Create('MP4: the table of packet sizes is damaged');
  SetLength(FPacketSize, Count);
  SetLength(FPacketOffset, Count);
  if Count = 0 then
    Exit;
  for I := 0 to Count - 1 do
    if Uniform <> 0 then
      FPacketSize[I] := Uniform
    else
      FPacketSize[I] := BE32(SzB + 12 + Int64(I) * 4);

  // Where the chunks lie, and how many packets each holds
  Wide := False;
  if not FindBox(ABody, AEnd, 'stco', CoB, CoE) then
  begin
    Wide := True;
    if not FindBox(ABody, AEnd, 'co64', CoB, CoE) then
      raise EMp4Error.Create('MP4: no table of positions');
  end;
  if CoE - CoB < 8 then
    raise EMp4Error.Create('MP4: the table of positions is damaged');
  ChunkCount := BE32(CoB + 4);
  if (Wide and (Int64(ChunkCount) * 8 > CoE - CoB - 8)) or
     ((not Wide) and (Int64(ChunkCount) * 4 > CoE - CoB - 8)) then
    raise EMp4Error.Create('MP4: the table of positions is damaged');
  if (not FindBox(ABody, AEnd, 'stsc', ScB, ScE)) or (ScE - ScB < 8) then
    raise EMp4Error.Create('MP4: no table of chunks');
  Entries := BE32(ScB + 4);
  if (Entries = 0) or (Int64(Entries) * 12 > ScE - ScB - 8) then
    raise EMp4Error.Create('MP4: the table of chunks is damaged');

  S := 0;                                  // the packet in work
  K := 0;                                  // the entry of 'stsc' in use
  PerChunk  := BE32(ScB + 12);
  if Entries > 1 then NextFirst := BE32(ScB + 8 + 12) else NextFirst := High(Cardinal);
  for Chunk := 1 to ChunkCount do
  begin
    while (K + 1 < Entries) and (Chunk >= NextFirst) do
    begin
      Inc(K);
      PerChunk := BE32(ScB + 8 + Int64(K) * 12 + 4);
      if K + 1 < Entries then NextFirst := BE32(ScB + 8 + Int64(K + 1) * 12) else NextFirst := High(Cardinal);
    end;
    P := CoB + 8;
    if Wide then Offset := BE64(P + Int64(Chunk - 1) * 8)
    else Offset := BE32(P + Int64(Chunk - 1) * 4);
    for N := 1 to PerChunk do
    begin
      if S >= Count then
        Break;
      if (Offset < 0) or (Offset + FPacketSize[S] > FFileSize) then
        raise EMp4Error.Create('MP4: a packet lies outside the file');
      FPacketOffset[S] := Offset;
      Inc(Offset, FPacketSize[S]);
      Inc(S);
    end;
    if S >= Count then
      Break;
  end;
  // Packets the chunks do not account for cannot be found
  if S < Count then
  begin
    SetLength(FPacketSize, S);
    SetLength(FPacketOffset, S);
  end;
end;

// The entries of the iTunes tag list
procedure TMp4File.ReadTags(ABody, AEnd: Int64);
var
  P, B, E, DB, DE, NB, NE, Q: Int64;
  T, DT, Name: string;
  Item: TMp4TagItem;
  Kind: Integer;
begin
  T  := '';
  DT := '';
  P  := ABody;
  while BoxAt(P, AEnd, T, B, E) do
  begin
    Name := T;
    if (T = '----') and FindBox(B, E, 'name', NB, NE) and (NE - NB > 4) then
      // mean, name, data: the name is what tells the entries apart
      SetString(Name, PAnsiChar(@FMoov[NB + 4]), NE - NB - 4);
    // the entry as it stands in the file, for a save that keeps it
    SetLength(FTagBoxes, Length(FTagBoxes) + 1);
    SetLength(FTagBoxNames, Length(FTagBoxes));
    FTagBoxNames[High(FTagBoxes)] := Name;
    if FWantPictures or (T <> 'covr') then
    begin
      SetLength(FTagBoxes[High(FTagBoxes)], E - P);
      Move(FMoov[P], FTagBoxes[High(FTagBoxes)][0], E - P);
    end;
    P := E;
    if (T = '----') and (Name = T) then
      Continue;
    // every 'data' box of the entry is a value of its own
    Q := B;
    while BoxAt(Q, E, DT, DB, DE) do
    begin
      Q := DE;
      if (DT <> 'data') or (DE - DB < 8) then
        Continue;
      Kind := Integer(BE32(DB) and $FFFFFF);
      if (T = 'covr') and (not FWantPictures) then
        Continue;
      Item := Default(TMp4TagItem);
      Item.Name     := Name;
      Item.FreeForm := T = '----';
      Item.Kind     := Kind;
      Item.Box      := High(FTagBoxes);
      SetLength(Item.Data, DE - DB - 8);
      if Length(Item.Data) > 0 then
        Move(FMoov[DB + 8], Item.Data[0], Length(Item.Data));
      SetLength(FTags, Length(FTags) + 1);
      FTags[High(FTags)] := Item;
    end;
  end;
  // every byte of the list belongs to an entry that was read
  FTagListComplete := P = AEnd;
end;

function TMp4File.GetPacketCount: Integer;
begin
  Result := Length(FPacketSize);
end;

function TMp4File.GetTagBoxCount: Integer;
begin
  Result := Length(FTagBoxes);
end;

function TMp4File.TagBox(AIndex: Integer): TBytes;
begin
  if (AIndex < 0) or (AIndex >= Length(FTagBoxes)) then
    Result := nil
  else
    Result := FTagBoxes[AIndex];
end;

function TMp4File.TagBoxName(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex >= Length(FTagBoxNames)) then
    Result := ''
  else
    Result := FTagBoxNames[AIndex];
end;

function TMp4File.PacketOffset(AIndex: Integer): Int64;
begin
  if (AIndex < 0) or (AIndex >= Length(FPacketOffset)) then
    Result := -1
  else
    Result := FPacketOffset[AIndex];
end;

function TMp4File.PacketSize(AIndex: Integer): Cardinal;
begin
  if (AIndex < 0) or (AIndex >= Length(FPacketSize)) then
    Result := 0
  else
    Result := FPacketSize[AIndex];
end;

{ ---- writing the tag list ---- }

const
  MAX_TAG_LIST_BYTES = 64 * 1024 * 1024;

function U32At(const B: TBytes; APos: Int64): Cardinal;
begin
  if (APos < 0) or (APos + 4 > Length(B)) then
    raise EMp4Error.Create('MP4: a box ends before its data');
  Result := (Cardinal(B[APos]) shl 24) or (Cardinal(B[APos + 1]) shl 16) or
            (Cardinal(B[APos + 2]) shl 8) or B[APos + 3];
end;

procedure PutU32(var B: TBytes; APos: Int64; AValue: Cardinal);
begin
  if (APos < 0) or (APos + 4 > Length(B)) then
    raise EMp4Error.Create('MP4: a box ends before its data');
  B[APos]     := Byte(AValue shr 24);
  B[APos + 1] := Byte(AValue shr 16);
  B[APos + 2] := Byte(AValue shr 8);
  B[APos + 3] := Byte(AValue);
end;

procedure AppendBytes(var ADest: TBytes; const ASrc: TBytes);
var
  N: Integer;
begin
  if Length(ASrc) = 0 then
    Exit;
  N := Length(ADest);
  SetLength(ADest, N + Length(ASrc));
  Move(ASrc[0], ADest[N], Length(ASrc));
end;

function BytesOf(const S: AnsiString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function U32Bytes(AValue: Cardinal): TBytes;
begin
  Result := nil;
  SetLength(Result, 4);
  PutU32(Result, 0, AValue);
end;

// A box: its size, its four characters, its body
function MakeBox(const AType: AnsiString; const ABody: TBytes): TBytes;
begin
  Result := U32Bytes(8 + Length(ABody));
  AppendBytes(Result, BytesOf(Copy(AType + '    ', 1, 4)));
  AppendBytes(Result, ABody);
end;

function Mp4DataEntry(const AName: string; AKind: Integer; const AData: TBytes): TBytes;
var
  Body: TBytes;
begin
  Body := U32Bytes(Cardinal(AKind) and $FFFFFF);
  AppendBytes(Body, U32Bytes(0));
  AppendBytes(Body, AData);
  Result := MakeBox(AName, MakeBox('data', Body));
end;

function TextDataBoxes(const AValues: array of string): TBytes;
var
  I: Integer;
  Part: TBytes;
begin
  Result := nil;
  for I := 0 to High(AValues) do
  begin
    Part := U32Bytes(1);                  // text in UTF-8
    AppendBytes(Part, U32Bytes(0));
    AppendBytes(Part, BytesOf(AValues[I]));
    AppendBytes(Result, MakeBox('data', Part));
  end;
end;

function Mp4TextEntry(const AName: string; const AValues: array of string): TBytes;
begin
  Result := MakeBox(AName, TextDataBoxes(AValues));
end;

function Mp4FreeFormEntry(const AName: string; const AValues: array of string): TBytes;
var
  Body, Part: TBytes;
begin
  Part := U32Bytes(0);
  AppendBytes(Part, BytesOf('com.apple.iTunes'));
  Body := MakeBox('mean', Part);
  Part := U32Bytes(0);
  AppendBytes(Part, BytesOf(AName));
  AppendBytes(Body, MakeBox('name', Part));
  AppendBytes(Body, TextDataBoxes(AValues));
  Result := MakeBox('----', Body);
end;

// The box at APos of B, which may not reach beyond ALimit. Only boxes with
// the usual header of eight bytes: a box inside 'moov' that needs more is
// not something this rewrites.
function PlainBoxAt(const B: TBytes; APos, ALimit: Int64; out AType: string; out ABody, AEnd: Int64): Boolean;
var
  Size: Int64;
begin
  Result := False;
  AType  := '';
  ABody  := 0;
  AEnd   := 0;
  if APos + 8 > ALimit then
    Exit;
  Size := U32At(B, APos);
  SetString(AType, PAnsiChar(@B[APos + 4]), 4);
  if Size < 8 then
    Exit;
  ABody := APos + 8;
  AEnd  := APos + Size;
  Result := AEnd <= ALimit;
end;

function PlainFind(const B: TBytes; AFrom, ATo: Int64; const AType: string; out AStart, ABody, AEnd: Int64): Boolean;
var
  T: string;
  P: Int64;
begin
  T := '';
  P := AFrom;
  while PlainBoxAt(B, P, ATo, T, ABody, AEnd) do
  begin
    if T = AType then
    begin
      AStart := P;
      Exit(True);
    end;
    P := AEnd;
  end;
  AStart := 0;
  ABody  := 0;
  AEnd   := 0;
  Result := False;
end;

// True when the boxes from AFrom on fill the space up to ATo exactly
function PlainTiles(const B: TBytes; AFrom, ATo: Int64): Boolean;
var
  T: string;
  P, Body, BoxEnd: Int64;
begin
  T := '';
  P := AFrom;
  while P < ATo do
  begin
    if not PlainBoxAt(B, P, ATo, T, Body, BoxEnd) then
      Exit(False);
    P := BoxEnd;
  end;
  Result := P = ATo;
end;

// The positions of the chunks of every track in the description ABody move
// by ADelta when they lie behind AOldEnd (the old end of the description)
procedure ShiftChunkOffsets(var ABody: TBytes; AOldStart, AOldEnd, ADelta: Int64);
var
  P, TB, TE, S0, B1, E1, B2, E2, B3, E3, B4, E4, V: Int64;
  T: string;
  Count, I: Cardinal;
begin
  T := '';
  P := 0;
  while PlainBoxAt(ABody, P, Length(ABody), T, TB, TE) do
  begin
    P := TE;
    if T <> 'trak' then
      Continue;
    if not (PlainFind(ABody, TB, TE, 'mdia', S0, B1, E1) and PlainFind(ABody, B1, E1, 'minf', S0, B2, E2) and
            PlainFind(ABody, B2, E2, 'stbl', S0, B3, E3)) then
      Continue;
    if PlainFind(ABody, B3, E3, 'stco', S0, B4, E4) then
    begin
      if E4 - B4 < 8 then
        raise EMp4Error.Create('MP4: the table of positions is damaged');
      Count := U32At(ABody, B4 + 4);
      if Int64(Count) * 4 > E4 - B4 - 8 then
        raise EMp4Error.Create('MP4: the table of positions is damaged');
      if Count > 0 then
        for I := 0 to Count - 1 do
        begin
          V := U32At(ABody, B4 + 8 + Int64(I) * 4);
          if (V > AOldStart) and (V < AOldEnd) then
            raise EMp4Error.Create('MP4: sound inside the description of the file');
          if V >= AOldEnd then
          begin
            V := V + ADelta;
            if (V < 0) or (V > Int64($FFFFFFFF)) then
              raise EMp4Error.Create('MP4: the file would grow beyond what its tables can address');
            PutU32(ABody, B4 + 8 + Int64(I) * 4, Cardinal(V));
          end;
        end;
    end;
    if PlainFind(ABody, B3, E3, 'co64', S0, B4, E4) then
    begin
      if E4 - B4 < 8 then
        raise EMp4Error.Create('MP4: the table of positions is damaged');
      Count := U32At(ABody, B4 + 4);
      if Int64(Count) * 8 > E4 - B4 - 8 then
        raise EMp4Error.Create('MP4: the table of positions is damaged');
      if Count > 0 then
        for I := 0 to Count - 1 do
        begin
          V := (Int64(U32At(ABody, B4 + 8 + Int64(I) * 8)) shl 32) or U32At(ABody, B4 + 12 + Int64(I) * 8);
          if (V > AOldStart) and (V < AOldEnd) then
            raise EMp4Error.Create('MP4: sound inside the description of the file');
          if V >= AOldEnd then
          begin
            V := V + ADelta;
            PutU32(ABody, B4 + 8 + Int64(I) * 8, Cardinal(V shr 32));
            PutU32(ABody, B4 + 12 + Int64(I) * 8, Cardinal(V and $FFFFFFFF));
          end;
        end;
    end;
  end;
end;

procedure CopyRange(ASrc, ADst: TStream; AFrom, ACount: Int64);
begin
  if ACount <= 0 then
    Exit;
  ASrc.Position := AFrom;
  ADst.CopyFrom(ASrc, ACount);
end;

// The packets of the sound of ADest against those of ASource, and the tag
// list of ADest against AEntries
function SameSound(const ASource, ADest: string; const AEntries: TBytes; out AError: string): Boolean;
var
  A, B: TMp4File;
  FA, FB: TStream;
  BufA, BufB, Listed: TBytes;
  I: Integer;
  Size: Cardinal;
begin
  Result := False;
  AError := '';
  A := nil; B := nil; FA := nil; FB := nil;
  BufA := nil; BufB := nil; Listed := nil;
  try
    A := TMp4File.Create(ASource);
    B := TMp4File.Create(ADest, True, True);
    if (A.Codec <> B.Codec) or (A.PacketCount <> B.PacketCount) or (A.TotalFrames <> B.TotalFrames) or
       (A.Channels <> B.Channels) or (Length(A.Cookie) <> Length(B.Cookie)) or
       ((Length(A.Cookie) > 0) and not CompareMem(@A.Cookie[0], @B.Cookie[0], Length(A.Cookie))) then
    begin
      AError := 'the description of the sound changed';
      Exit;
    end;
    for I := 0 to B.TagBoxCount - 1 do
      AppendBytes(Listed, B.TagBox(I));
    if (not B.TagListComplete) or (Length(Listed) <> Length(AEntries)) or
       ((Length(Listed) > 0) and not CompareMem(@Listed[0], @AEntries[0], Length(Listed))) then
    begin
      AError := 'the tags do not read back as they were written';
      Exit;
    end;

    FA := AuOpenFile(ASource, fmOpenRead or fmShareDenyNone);
    FB := AuOpenFile(ADest, fmOpenRead or fmShareDenyNone);
    for I := 0 to A.PacketCount - 1 do
    begin
      Size := A.PacketSize(I);
      if Size <> B.PacketSize(I) then
      begin
        AError := 'a packet of the sound changed its size';
        Exit;
      end;
      if Size = 0 then
        Continue;
      if Cardinal(Length(BufA)) < Size then
      begin
        SetLength(BufA, Size);
        SetLength(BufB, Size);
      end;
      FA.Position := A.PacketOffset(I);
      FB.Position := B.PacketOffset(I);
      if (FA.Read(BufA[0], Size) <> Integer(Size)) or (FB.Read(BufB[0], Size) <> Integer(Size)) or
         (not CompareMem(@BufA[0], @BufB[0], Size)) then
      begin
        AError := 'the sound does not read back as it was';
        Exit;
      end;
    end;
    Result := True;
  finally
    FA.Free;
    FB.Free;
    A.Free;
    B.Free;
  end;
end;

function Mp4ReplaceTags(const ASource, ADest: string; const AEntries: TBytes; out AError: string): Boolean;
type
  TTop = record
    Kind: string;
    Pos, Size: Int64;
    Header: Integer;
  end;
var
  Src, Dst: TStream;
  Tops: array of TTop;
  Hdr: array[0..15] of Byte;
  FileSize, Pos, Size, MoovPos, MoovEnd, Delta, NewSize: Int64;
  US, UB, UE, MS, MB, ME, IS_, IB, IE, Children, S0, B0, E0: Int64;
  I, MoovIdx, MoovCount: Integer;
  T: string;
  Body, NewBody, NewList, MetaBody, Part: TBytes;
  SoundBehind: Boolean;

  procedure Splice(AAt, ARemove: Int64; const AInsert: TBytes);
  begin
    NewBody := nil;
    SetLength(NewBody, Length(Body) - ARemove + Length(AInsert));
    if AAt > 0 then
      Move(Body[0], NewBody[0], AAt);
    if Length(AInsert) > 0 then
      Move(AInsert[0], NewBody[AAt], Length(AInsert));
    if Length(Body) - AAt - ARemove > 0 then
      Move(Body[AAt + ARemove], NewBody[AAt + Length(AInsert)], Length(Body) - AAt - ARemove);
  end;

  procedure Grow(ABoxStart, ABy: Int64);
  var
    V: Int64;
  begin
    V := Int64(U32At(NewBody, ABoxStart)) + ABy;
    if (V < 8) or (V > Int64($FFFFFFFF)) then
      raise EMp4Error.Create('MP4: a box would grow beyond its limit');
    PutU32(NewBody, ABoxStart, Cardinal(V));
  end;

begin
  Result := False;
  AError := '';
  Tops := nil; Body := nil; NewBody := nil;
  Src := nil; Dst := nil;
  if Length(AEntries) > MAX_TAG_LIST_BYTES then
  begin
    AError := 'the tags are too large';
    Exit;
  end;
  try
    try
      Src := AuOpenFile(ASource, fmOpenRead or fmShareDenyNone);
      FileSize := Src.Size;

      // The boxes of the file must follow each other to its last byte
      Pos := 0;
      MoovIdx := -1;
      MoovCount := 0;
      while Pos < FileSize do
      begin
        if Pos + 8 > FileSize then
          raise EMp4Error.Create('MP4: bytes behind the last box');
        Src.Position := Pos;
        Src.ReadBuffer(Hdr, 8);
        Size := (Int64(Hdr[0]) shl 24) or (Int64(Hdr[1]) shl 16) or (Int64(Hdr[2]) shl 8) or Hdr[3];
        SetString(T, PAnsiChar(@Hdr[4]), 4);
        SetLength(Tops, Length(Tops) + 1);
        Tops[High(Tops)].Kind   := T;
        Tops[High(Tops)].Pos    := Pos;
        Tops[High(Tops)].Header := 8;
        if Size = 1 then
        begin
          if Pos + 16 > FileSize then
            raise EMp4Error.Create('MP4: a box runs out of the file');
          Src.ReadBuffer(Hdr[8], 8);
          Size := (Int64(Hdr[8]) shl 56) or (Int64(Hdr[9]) shl 48) or (Int64(Hdr[10]) shl 40) or
                  (Int64(Hdr[11]) shl 32) or (Int64(Hdr[12]) shl 24) or (Int64(Hdr[13]) shl 16) or
                  (Int64(Hdr[14]) shl 8) or Hdr[15];
          Tops[High(Tops)].Header := 16;
        end
        else if Size = 0 then
          Size := FileSize - Pos;
        if (Size < Tops[High(Tops)].Header) or (Pos + Size > FileSize) then
          raise EMp4Error.Create('MP4: a box runs out of the file');
        Tops[High(Tops)].Size := Size;
        if T = 'moov' then
        begin
          MoovIdx := High(Tops);
          Inc(MoovCount);
        end;
        // a file in fragments keeps positions this does not correct
        if (T = 'moof') or (T = 'sidx') or (T = 'mfra') then
          raise EMp4Error.Create('MP4: a file in fragments is not rewritten');
        Pos := Pos + Size;
      end;
      if (Length(Tops) = 0) or (Tops[0].Kind <> 'ftyp') then
        raise EMp4Error.Create('Not an MP4 file');
      if MoovCount <> 1 then
        raise EMp4Error.Create('MP4: the file has no description, or more than one');

      MoovPos := Tops[MoovIdx].Pos;
      MoovEnd := MoovPos + Tops[MoovIdx].Size;
      if Tops[MoovIdx].Size - Tops[MoovIdx].Header > MAX_MOOV_BYTES then
        raise EMp4Error.Create('MP4: the description of the file is too large');
      SetLength(Body, Tops[MoovIdx].Size - Tops[MoovIdx].Header);
      Src.Position := MoovPos + Tops[MoovIdx].Header;
      if Length(Body) > 0 then
        Src.ReadBuffer(Body[0], Length(Body));
      if not PlainTiles(Body, 0, Length(Body)) then
        raise EMp4Error.Create('MP4: the description of the file is not laid out as expected');

      SoundBehind := False;
      for I := MoovIdx + 1 to High(Tops) do
        if Tops[I].Kind = 'mdat' then
          SoundBehind := True;

      // The new list goes where the old one is; what holds it grows with it
      NewList := MakeBox('ilst', AEntries);
      if PlainFind(Body, 0, Length(Body), 'udta', US, UB, UE) then
      begin
        if not PlainTiles(Body, UB, UE) then
          raise EMp4Error.Create('MP4: the user data of the file is not laid out as expected');
        if PlainFind(Body, UB, UE, 'meta', MS, MB, ME) then
        begin
          // four bytes of version and flags in front of its boxes, or none
          if (ME - MB >= 4) and PlainTiles(Body, MB + 4, ME) then
            Children := MB + 4
          else if PlainTiles(Body, MB, ME) then
            Children := MB
          else
            raise EMp4Error.Create('MP4: the tag area of the file is not laid out as expected');
          if PlainFind(Body, Children, ME, 'ilst', IS_, IB, IE) then
          begin
            // a second list would be left behind with the old tags
            if PlainFind(Body, IE, ME, 'ilst', S0, B0, E0) then
              raise EMp4Error.Create('MP4: the file has more than one tag list');
            Splice(IS_, IE - IS_, NewList);
            Grow(MS, Length(NewList) - (IE - IS_));
            Grow(US, Length(NewList) - (IE - IS_));
          end
          else
          begin
            Splice(ME, 0, NewList);
            Grow(MS, Length(NewList));
            Grow(US, Length(NewList));
          end;
        end
        else
        begin
          Part := U32Bytes(0);
          AppendBytes(Part, U32Bytes(0));
          AppendBytes(Part, BytesOf('mdirappl'));
          AppendBytes(Part, BytesOf(StringOfChar(#0, 9)));
          MetaBody := U32Bytes(0);
          AppendBytes(MetaBody, MakeBox('hdlr', Part));
          AppendBytes(MetaBody, NewList);
          Part := MakeBox('meta', MetaBody);
          Splice(UE, 0, Part);
          Grow(US, Length(Part));
        end;
      end
      else
      begin
        Part := U32Bytes(0);
        AppendBytes(Part, U32Bytes(0));
        AppendBytes(Part, BytesOf('mdirappl'));
        AppendBytes(Part, BytesOf(StringOfChar(#0, 9)));
        MetaBody := U32Bytes(0);
        AppendBytes(MetaBody, MakeBox('hdlr', Part));
        AppendBytes(MetaBody, NewList);
        Part := MakeBox('udta', MakeBox('meta', MetaBody));
        Splice(Length(Body), 0, Part);
      end;

      NewSize := 8 + Int64(Length(NewBody));
      if NewSize > Int64($FFFFFFFF) then
        raise EMp4Error.Create('MP4: the description of the file would grow beyond its limit');
      Delta := NewSize - Tops[MoovIdx].Size;
      if SoundBehind and (Delta <> 0) then
        ShiftChunkOffsets(NewBody, MoovPos, MoovEnd, Delta);

      Dst := AuOpenFile(ADest, fmCreate);
      CopyRange(Src, Dst, 0, MoovPos);
      Part := U32Bytes(Cardinal(NewSize));
      AppendBytes(Part, BytesOf('moov'));
      Dst.WriteBuffer(Part[0], 8);
      if Length(NewBody) > 0 then
        Dst.WriteBuffer(NewBody[0], Length(NewBody));
      CopyRange(Src, Dst, MoovEnd, FileSize - MoovEnd);
      if Dst.Size <> FileSize + Delta then
        raise EMp4Error.Create('MP4: the new file has not the size it must have');
      FreeAndNil(Dst);
      FreeAndNil(Src);

      Result := SameSound(ASource, ADest, AEntries, AError);
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := False;
      end;
    end;
  finally
    Dst.Free;
    Src.Free;
  end;
  // a file that did not pass is not left behind
  if (not Result) and AuFileExists(ADest) then
    AuDeleteFile(ADest);
end;
end.
