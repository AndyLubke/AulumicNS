unit uDbStore;

{ ==============================================================================
  Project:   AulumicNS
  Unit Name: uDbStore

  The storage of the library and the user statistics, in the format family
  of Aulos (library.adb + library.jnl):

    <name>.adb   snapshot: header (magic, format version, generation, body
                 length), the body, CRC-32 over header and body. Written
                 atomically (uOSUtils.SaveStreamAtomic: temporary file,
                 flushed, renamed over the old one).
    <name>.jnl   journal of the changes since that snapshot: a header with
                 the generation of its snapshot, then records
                 [length][CRC-32][payload]. A torn last record (crash during a
                 write) is ignored and cut off before the next append; a
                 journal of another generation is ignored (it was already
                 merged into a newer snapshot when the snapshot was written).

  TDbWriter / TDbReader read and write little-endian fields; the reader
  checks every length and raises EDbFormat on a damaged body. TDbStrPool
  interns the strings of a snapshot (folders, artists, albums repeat), so a
  track stores small ids.

  No shared state; a TDbJournal is used by one owner under its own lock.
  =============================================================================}

{$mode ObjFPC}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, contnrs;

type
  EDbFormat = class(Exception);

  { TDbWriter }

  TDbWriter = class
  private
    FData: TBytes;
    FLen: Integer;
    procedure Need(N: Integer); inline;
  public
    procedure U8(V: Byte);
    procedure U32(V: Cardinal);
    procedure I32(V: Integer);
    procedure I64(V: Int64);
    procedure U64(V: QWord);
    procedure Bool(V: Boolean);
    procedure Dbl(V: Double);
    { UTF-8 text with a 32-bit length }
    procedure Str(const S: string);
    procedure Raw(const Buf; N: Integer);
    function Bytes: TBytes;
    property Size: Integer read FLen;
  end;

  { TDbReader }

  TDbReader = class
  private
    FData: TBytes;
    FPos, FEnd: Integer;
    procedure Need(N: Integer); inline;
  public
    constructor Create(const AData: TBytes; AStart: Integer = 0; ALen: Integer = -1);
    function U8: Byte;
    function U32: Cardinal;
    function I32: Integer;
    function I64: Int64;
    function U64: QWord;
    function Bool: Boolean;
    function Dbl: Double;
    function Str: string;
    { a count that the rest of the data can hold (each item at least AMinItemBytes) }
    function Count(AMinItemBytes: Integer): Integer;
    function AtEnd: Boolean;
    property Position: Integer read FPos;
  end;

  { TDbStrPool: the strings of a snapshot; id 0 is the empty string }

  TDbStrPool = class
  private
    FItems: array of string;
    FCount: Integer;
    FMap: TFPDataHashTable;      // string -> id + 1
  public
    constructor Create;
    destructor Destroy; override;
    function Intern(const S: string): Cardinal;
    { as Intern, but a new text is kept as a copy made here (the caller's
      string may live in another thread's memory) }
    function InternCopy(const S: string): Cardinal;
    function Str(Id: Cardinal): string;
    procedure WriteTo(W: TDbWriter);
    procedure ReadFrom(R: TDbReader);
    property Count: Integer read FCount;
  end;

  { TDbJournal }

  TDbJournal = class
  private
    FFile: string;
    FMagic: AnsiString;
    FStream: TFileStream;
    FGeneration: QWord;
    FValidEnd: Int64;            // end of the last good record (from Replay)
    FKnown: Boolean;             // FGeneration / FValidEnd describe the file
    function OpenForAppend: Boolean;
  public
    constructor Create(const AFile: string; const AMagic: AnsiString);
    destructor Destroy; override;
    { the payloads of the journal of snapshot AGeneration (none when the
      journal is missing, damaged in its header or of another generation) }
    function Replay(AGeneration: QWord; APayloads: TList): Integer;
    { a new, empty journal for snapshot AGeneration }
    function Reset(AGeneration: QWord): Boolean;
    { appends one record and flushes it to the disk }
    function Append(const APayload: TBytes): Boolean;
    procedure Close;
    function Size: Int64;
    property FileName: string read FFile;
  end;

  { a payload of TDbJournal.Replay (owned by the list: FreePayloads) }
  PDbPayload = ^TDbPayload;
  TDbPayload = record
    Data: TBytes;
  end;

const
  DB_FORMAT_VERSION = 1;

function Crc32Of(P: PByte; Len: Integer; Crc: Cardinal = 0): Cardinal;

{ writes a snapshot atomically; AMagic is 8 characters }
function SaveSnapshot(const AFile: string; const AMagic: AnsiString; AGeneration: QWord;
  const ABody: TBytes; out AError: string): Boolean;
{ reads a snapshot: False with AError when it is missing (AError = ''),
  of another kind or damaged }
function LoadSnapshot(const AFile: string; const AMagic: AnsiString; out AGeneration: QWord;
  out ABody: TBytes; out AError: string): Boolean;

procedure FreePayloads(AList: TList);

implementation

uses
  Windows, uOSUtils;

const
  SNAP_HEADER = 8 + 4 + 8 + 8;          // magic, version, generation, body length
  JNL_HEADER  = 8 + 4 + 8 + 4;          // magic, version, generation, CRC of the header
  MAX_RECORD  = 64 * 1024 * 1024;

var
  CrcTable: array[0..255] of Cardinal;

procedure MakeCrcTable;
var
  I, K: Integer;
  C: Cardinal;
begin
  for I := 0 to 255 do
  begin
    C := Cardinal(I);
    for K := 0 to 7 do
      if (C and 1) <> 0 then C := $EDB88320 xor (C shr 1) else C := C shr 1;
    CrcTable[I] := C;
  end;
end;

function Crc32Of(P: PByte; Len: Integer; Crc: Cardinal): Cardinal;
var
  I: Integer;
begin
  Result := not Crc;
  for I := 0 to Len - 1 do
  begin
    Result := CrcTable[(Result xor P^) and $FF] xor (Result shr 8);
    Inc(P);
  end;
  Result := not Result;
end;

{ TDbWriter }

procedure TDbWriter.Need(N: Integer);
var
  Cap: Integer;
begin
  if FLen + N <= Length(FData) then Exit;
  Cap := Length(FData) * 2;
  if Cap < 4096 then Cap := 4096;
  while Cap < FLen + N do Cap := Cap * 2;
  SetLength(FData, Cap);
end;

procedure TDbWriter.Raw(const Buf; N: Integer);
begin
  if N <= 0 then Exit;
  Need(N);
  Move(Buf, FData[FLen], N);
  Inc(FLen, N);
end;

procedure TDbWriter.U8(V: Byte);
begin
  Raw(V, 1);
end;

procedure TDbWriter.U32(V: Cardinal);
begin
  V := NtoLE(V);
  Raw(V, 4);
end;

procedure TDbWriter.I32(V: Integer);
begin
  U32(Cardinal(V));
end;

procedure TDbWriter.I64(V: Int64);
begin
  V := NtoLE(V);
  Raw(V, 8);
end;

procedure TDbWriter.U64(V: QWord);
begin
  V := NtoLE(V);
  Raw(V, 8);
end;

procedure TDbWriter.Bool(V: Boolean);
begin
  U8(Ord(V));
end;

procedure TDbWriter.Dbl(V: Double);
begin
  Raw(V, 8);
end;

procedure TDbWriter.Str(const S: string);
begin
  U32(Length(S));
  if S <> '' then Raw(S[1], Length(S));
end;

function TDbWriter.Bytes: TBytes;
begin
  Result := Copy(FData, 0, FLen);
end;

{ TDbReader }

constructor TDbReader.Create(const AData: TBytes; AStart: Integer; ALen: Integer);
begin
  inherited Create;
  FData := AData;
  FPos := AStart;
  if ALen < 0 then FEnd := Length(AData) else FEnd := AStart + ALen;
  if (FPos < 0) or (FEnd > Length(AData)) or (FPos > FEnd) then
    raise EDbFormat.Create('invalid data range');
end;

procedure TDbReader.Need(N: Integer);
begin
  if (N < 0) or (FPos + N > FEnd) then
    raise EDbFormat.Create('data ends too early');
end;

function TDbReader.U8: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TDbReader.U32: Cardinal;
begin
  Need(4);
  Move(FData[FPos], Result, 4);
  Result := LEtoN(Result);
  Inc(FPos, 4);
end;

function TDbReader.I32: Integer;
begin
  Result := Integer(U32);
end;

function TDbReader.I64: Int64;
begin
  Need(8);
  Move(FData[FPos], Result, 8);
  Result := LEtoN(Result);
  Inc(FPos, 8);
end;

function TDbReader.U64: QWord;
begin
  Need(8);
  Move(FData[FPos], Result, 8);
  Result := LEtoN(Result);
  Inc(FPos, 8);
end;

function TDbReader.Bool: Boolean;
begin
  Result := U8 <> 0;
end;

function TDbReader.Dbl: Double;
begin
  Need(8);
  Move(FData[FPos], Result, 8);
  Inc(FPos, 8);
end;

function TDbReader.Str: string;
var
  N: Cardinal;
begin
  N := U32;
  if N > Cardinal(FEnd - FPos) then raise EDbFormat.Create('text longer than the data');
  Result := '';
  if N = 0 then Exit;
  SetLength(Result, N);
  Move(FData[FPos], Result[1], N);
  Inc(FPos, N);
end;

function TDbReader.Count(AMinItemBytes: Integer): Integer;
var
  N: Cardinal;
begin
  N := U32;
  if AMinItemBytes < 1 then AMinItemBytes := 1;
  if Int64(N) * AMinItemBytes > FEnd - FPos then raise EDbFormat.Create('count larger than the data');
  Result := Integer(N);
end;

function TDbReader.AtEnd: Boolean;
begin
  Result := FPos >= FEnd;
end;

{ TDbStrPool }

constructor TDbStrPool.Create;
begin
  inherited Create;
  FMap := TFPDataHashTable.Create;
  SetLength(FItems, 256);
  FItems[0] := '';
  FCount := 1;
end;

destructor TDbStrPool.Destroy;
begin
  FMap.Free;
  inherited Destroy;
end;

function TDbStrPool.Intern(const S: string): Cardinal;
var
  P: Pointer;
begin
  if S = '' then Exit(0);
  P := FMap.Items[S];
  if P <> nil then Exit(Cardinal(PtrUInt(P)) - 1);
  if FCount = Length(FItems) then SetLength(FItems, FCount * 2);
  FItems[FCount] := S;
  Result := FCount;
  Inc(FCount);
  FMap.Add(S, Pointer(PtrUInt(Result) + 1));
end;

function TDbStrPool.InternCopy(const S: string): Cardinal;
var
  P: Pointer;
begin
  if S = '' then Exit(0);
  P := FMap.Items[S];
  if P <> nil then Exit(Cardinal(PtrUInt(P)) - 1);
  Result := Intern(Copy(S, 1, Length(S)));
end;

function TDbStrPool.Str(Id: Cardinal): string;
begin
  if Id >= Cardinal(FCount) then raise EDbFormat.Create('unknown text id');
  Result := FItems[Id];
end;

procedure TDbStrPool.WriteTo(W: TDbWriter);
var
  I: Integer;
begin
  W.U32(FCount - 1);
  for I := 1 to FCount - 1 do W.Str(FItems[I]);
end;

procedure TDbStrPool.ReadFrom(R: TDbReader);
var
  N, I: Integer;
begin
  N := R.Count(4);
  SetLength(FItems, N + 1);
  FItems[0] := '';
  for I := 1 to N do FItems[I] := R.Str;
  FCount := N + 1;
end;

{ snapshots }

function SaveSnapshot(const AFile: string; const AMagic: AnsiString; AGeneration: QWord;
  const ABody: TBytes; out AError: string): Boolean;
var
  W: TDbWriter;
  All: TBytes;
  Crc: Cardinal;
  MS: TBytesStream;
begin
  Result := False;
  AError := '';
  if Length(AMagic) <> 8 then raise EDbFormat.Create('snapshot magic must have 8 characters');
  W := TDbWriter.Create;
  try
    W.Raw(AMagic[1], 8);
    W.U32(DB_FORMAT_VERSION);
    W.U64(AGeneration);
    W.U64(Length(ABody));
    if Length(ABody) > 0 then W.Raw(ABody[0], Length(ABody));
    All := W.Bytes;
  finally
    W.Free;
  end;
  Crc := NtoLE(Crc32Of(@All[0], Length(All)));
  MS := TBytesStream.Create(nil);
  try
    MS.WriteBuffer(All[0], Length(All));
    MS.WriteBuffer(Crc, 4);
    MS.Position := 0;
    try
      Result := SaveStreamAtomic(MS, AFile, True);
      if not Result then AError := SysErrorMessage(GetLastError);
    except
      on E: Exception do AError := E.Message;
    end;
  finally
    MS.Free;
  end;
end;

function LoadSnapshot(const AFile: string; const AMagic: AnsiString; out AGeneration: QWord;
  out ABody: TBytes; out AError: string): Boolean;
var
  FS: TFileStream;
  All: TBytes;
  Magic: AnsiString;
  Ver: Cardinal;
  BodyLen: QWord;
  Crc, Stored: Cardinal;
begin
  Result := False;
  AGeneration := 0;
  ABody := nil;
  AError := '';
  if not FileExists(AFile) then Exit;
  try
    FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
    try
      if FS.Size < SNAP_HEADER + 4 then
      begin
        AError := 'the file is too short';
        Exit;
      end;
      SetLength(All, FS.Size);
      FS.ReadBuffer(All[0], Length(All));
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit;
    end;
  end;
  SetString(Magic, PAnsiChar(@All[0]), 8);
  if Magic <> AMagic then
  begin
    AError := 'not a file of this kind';
    Exit;
  end;
  Move(All[8], Ver, 4);
  Ver := LEtoN(Ver);
  if Ver > DB_FORMAT_VERSION then
  begin
    AError := Format('made by a newer version (format %d)', [Ver]);
    Exit;
  end;
  Move(All[12], AGeneration, 8);
  AGeneration := LEtoN(AGeneration);
  Move(All[20], BodyLen, 8);
  BodyLen := LEtoN(BodyLen);
  if BodyLen <> QWord(Length(All) - SNAP_HEADER - 4) then
  begin
    AError := 'the file is incomplete';
    Exit;
  end;
  Move(All[Length(All) - 4], Stored, 4);
  Stored := LEtoN(Stored);
  Crc := Crc32Of(@All[0], Length(All) - 4);
  if Crc <> Stored then
  begin
    AError := 'checksum error (the file is damaged)';
    Exit;
  end;
  ABody := Copy(All, SNAP_HEADER, BodyLen);
  Result := True;
end;

procedure FreePayloads(AList: TList);
var
  I: Integer;
begin
  if AList = nil then Exit;
  for I := 0 to AList.Count - 1 do Dispose(PDbPayload(AList[I]));
  AList.Clear;
end;

{ TDbJournal }

constructor TDbJournal.Create(const AFile: string; const AMagic: AnsiString);
begin
  inherited Create;
  if Length(AMagic) <> 8 then raise EDbFormat.Create('journal magic must have 8 characters');
  FFile := AFile;
  FMagic := AMagic;
end;

destructor TDbJournal.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TDbJournal.Close;
begin
  FreeAndNil(FStream);
end;

function TDbJournal.Size: Int64;
begin
  if FStream <> nil then Result := FStream.Size
  else if FKnown then Result := FValidEnd
  else Result := 0;
end;

function TDbJournal.Replay(AGeneration: QWord; APayloads: TList): Integer;
var
  FS: TFileStream;
  Head: array[0..JNL_HEADER - 1] of Byte;
  Magic: AnsiString;
  Ver, HCrc, Len, Crc: Cardinal;
  Gen: QWord;
  P: PDbPayload;
  Pos, Total: Int64;
begin
  Result := 0;
  Close;
  FKnown := False;
  FGeneration := AGeneration;
  FValidEnd := 0;
  if not FileExists(FFile) then Exit;
  try
    FS := TFileStream.Create(FFile, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  try
    Total := FS.Size;
    if Total < JNL_HEADER then Exit;
    FS.ReadBuffer(Head, JNL_HEADER);
    SetString(Magic, PAnsiChar(@Head[0]), 8);
    Move(Head[8], Ver, 4);
    Move(Head[12], Gen, 8);
    Move(Head[20], HCrc, 4);
    Ver := LEtoN(Ver);
    Gen := LEtoN(Gen);
    HCrc := LEtoN(HCrc);
    if (Magic <> FMagic) or (Ver > DB_FORMAT_VERSION) or (HCrc <> Crc32Of(@Head[0], 20)) then Exit;
    if Gen <> AGeneration then Exit;           // already merged into a newer snapshot
    Pos := JNL_HEADER;
    while Pos + 8 <= Total do
    begin
      FS.Position := Pos;
      FS.ReadBuffer(Len, 4);
      FS.ReadBuffer(Crc, 4);
      Len := LEtoN(Len);
      Crc := LEtoN(Crc);
      if (Len = 0) or (Len > MAX_RECORD) or (Pos + 8 + Len > Total) then Break;
      New(P);
      SetLength(P^.Data, Len);
      FS.ReadBuffer(P^.Data[0], Len);
      if Crc32Of(@P^.Data[0], Len) <> Crc then
      begin
        Dispose(P);
        Break;                                 // torn or damaged: the rest is not trusted
      end;
      APayloads.Add(P);
      Inc(Result);
      Pos := Pos + 8 + Len;
    end;
    FValidEnd := Pos;
    FKnown := True;
  finally
    FS.Free;
  end;
end;

function TDbJournal.Reset(AGeneration: QWord): Boolean;
var
  Head: array[0..JNL_HEADER - 1] of Byte;
  V32: Cardinal;
  V64: QWord;
begin
  Result := False;
  Close;
  FGeneration := AGeneration;
  FKnown := False;
  Move(FMagic[1], Head[0], 8);
  V32 := NtoLE(Cardinal(DB_FORMAT_VERSION));
  Move(V32, Head[8], 4);
  V64 := NtoLE(AGeneration);
  Move(V64, Head[12], 8);
  V32 := NtoLE(Crc32Of(@Head[0], 20));
  Move(V32, Head[20], 4);
  try
    ForceDirectories(ExtractFileDir(FFile));
    FStream := TFileStream.Create(FFile, fmCreate or fmShareDenyWrite);
    FStream.WriteBuffer(Head, JNL_HEADER);
    FlushFileBuffers(FStream.Handle);
    FValidEnd := JNL_HEADER;
    FKnown := True;
    Result := True;
  except
    FreeAndNil(FStream);
  end;
end;

function TDbJournal.OpenForAppend: Boolean;
begin
  Result := FStream <> nil;
  if Result then Exit;
  { no journal of this snapshot yet (or a stale one): start it }
  if not (FKnown and FileExists(FFile)) then Exit(Reset(FGeneration));
  try
    FStream := TFileStream.Create(FFile, fmOpenReadWrite or fmShareDenyWrite);
    { a torn record at the end is cut off: new records must follow a good one }
    if FStream.Size <> FValidEnd then FStream.Size := FValidEnd;
    FStream.Position := FValidEnd;
    Result := True;
  except
    { not reachable now: the good records stay, the next append tries again }
    FreeAndNil(FStream);
    Result := False;
  end;
end;

function TDbJournal.Append(const APayload: TBytes): Boolean;
var
  Len, Crc: Cardinal;
begin
  Result := False;
  if Length(APayload) = 0 then Exit;
  if not OpenForAppend then Exit;
  Len := NtoLE(Cardinal(Length(APayload)));
  Crc := NtoLE(Crc32Of(@APayload[0], Length(APayload)));
  try
    FStream.Position := FStream.Size;
    FStream.WriteBuffer(Len, 4);
    FStream.WriteBuffer(Crc, 4);
    FStream.WriteBuffer(APayload[0], Length(APayload));
    FlushFileBuffers(FStream.Handle);
    FValidEnd := FStream.Size;
    Result := True;
  except
    { the disk is full or gone: the change stays in memory (dirty); a partial
      record is cut off at the next append (FValidEnd is the last good one) }
    FreeAndNil(FStream);
  end;
end;

initialization
  MakeCrcTable;

end.
