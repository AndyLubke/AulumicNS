unit AuDecoder;

{ ==============================================================================
  AulumicNS - AuDecoder
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Base class of the decoders, a buffered file reader and the ReplayGain tag
  parsers (Vorbis comments, ID3v2 TXXX) shared by them.

  Decoders deliver samples unchanged:
    skPcmInt   ReadPcm   interleaved Int32, value range of BitsPerSample
    skPcmFloat ReadFloat interleaved Double
    skDsd      ReadDsd   interleaved bytes (one per channel per frame),
                         most significant bit = earliest DSD sample
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, AuAudioTypes;

type
  { TAuBufReader - fast sequential reading with seek }

  TAuBufReader = class
  private
    FStream: TFileStream;
    FBuf: array of Byte;
    FBufPos, FBufLen: Integer;
    FBufStart: Int64;
    FSize: Int64;
    procedure Fill;
  public
    constructor Create(const FileName: string; BufSize: Integer = 256 * 1024);
    destructor Destroy; override;
    function Position: Int64; inline;
    procedure Seek(Pos: Int64);
    function ReadByte: Byte; inline;
    function Read(var Dest; Count: Integer): Integer;
    procedure ReadExact(var Dest; Count: Integer);
    function ReadU16LE: Word;
    function ReadU32LE: Cardinal;
    function ReadU64LE: QWord;
    function ReadU16BE: Word;
    function ReadU32BE: Cardinal;
    function ReadU64BE: QWord;
    function ReadTag4: string;
    property Size: Int64 read FSize;
  end;

  { the few tags the player shows before the library exists }
  TAuBasicTags = record
    Title, Artist, Album, AlbumArtist, TrackNo: string;
  end;

  { TAuDecoder }

  TAuDecoder = class
  protected
    FInfo: TAuStreamInfo;
    FRg: TAuReplayGain;
    FTags: TAuBasicTags;
    FPos: Int64;
    FFileName: string;
  public
    procedure Open(const AFileName: string); virtual; abstract;
    function ReadPcm(Dest: PInt32; MaxFrames: Integer): Integer; virtual;
    function ReadFloat(Dest: PDouble; MaxFrames: Integer): Integer; virtual;
    function ReadDsd(Dest: PByte; MaxFrames: Integer): Integer; virtual;
    procedure Seek(Frame: Int64); virtual; abstract;
    property Info: TAuStreamInfo read FInfo;
    property ReplayGain: TAuReplayGain read FRg;
    property Tags: TAuBasicTags read FTags;
    property Position: Int64 read FPos;     // frames from the start
    property FileName: string read FFileName;
  end;

function OpenDecoder(const FileName: string): TAuDecoder;

procedure ApplyVorbisComment(const Comment: string; var RG: TAuReplayGain; var Tags: TAuBasicTags);
procedure ParseId3ReplayGain(const Data: TBytes; var RG: TAuReplayGain; var Tags: TAuBasicTags);
function ParseGainValue(const S: string; out V: Double): Boolean;

implementation

uses
  AuDecWav, AuDecFlac, AuDecDsd;

{ ---- TAuBufReader ---- }

constructor TAuBufReader.Create(const FileName: string; BufSize: Integer);
begin
  inherited Create;
  try
    FStream := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do raise EAuAudio.CreateKind(aekFile, 'Cannot open file: ' + E.Message);
  end;
  FSize := FStream.Size;
  if BufSize < 4096 then BufSize := 4096;
  SetLength(FBuf, BufSize);
end;

destructor TAuBufReader.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

procedure TAuBufReader.Fill;
begin
  FBufStart := FBufStart + FBufLen;
  FBufPos := 0;
  FBufLen := FStream.Read(FBuf[0], Length(FBuf));
end;

function TAuBufReader.Position: Int64;
begin
  Result := FBufStart + FBufPos;
end;

procedure TAuBufReader.Seek(Pos: Int64);
begin
  if (Pos >= FBufStart) and (Pos <= FBufStart + FBufLen) then
  begin
    FBufPos := Integer(Pos - FBufStart);
    Exit;
  end;
  if Pos > FSize then Pos := FSize;
  if Pos < 0 then Pos := 0;
  FStream.Position := Pos;
  FBufStart := Pos;
  FBufPos := 0;
  FBufLen := 0;
end;

function TAuBufReader.ReadByte: Byte;
begin
  if FBufPos >= FBufLen then
  begin
    Fill;
    if FBufLen = 0 then raise EAuAudio.CreateKind(aekFormat, 'Unexpected end of file');
  end;
  Result := FBuf[FBufPos];
  Inc(FBufPos);
end;

function TAuBufReader.Read(var Dest; Count: Integer): Integer;
var
  P: PByte;
  N: Integer;
begin
  Result := 0;
  P := @Dest;
  while Count > 0 do
  begin
    if FBufPos >= FBufLen then
    begin
      Fill;
      if FBufLen = 0 then Exit;
    end;
    N := FBufLen - FBufPos;
    if N > Count then N := Count;
    Move(FBuf[FBufPos], P^, N);
    Inc(FBufPos, N);
    Inc(P, N);
    Inc(Result, N);
    Dec(Count, N);
  end;
end;

procedure TAuBufReader.ReadExact(var Dest; Count: Integer);
begin
  if Read(Dest, Count) <> Count then raise EAuAudio.CreateKind(aekFormat, 'Unexpected end of file');
end;

function TAuBufReader.ReadU16LE: Word;
begin
  Result := ReadByte;
  Result := Result or (Word(ReadByte) shl 8);
end;

function TAuBufReader.ReadU32LE: Cardinal;
begin
  Result := ReadU16LE;
  Result := Result or (Cardinal(ReadU16LE) shl 16);
end;

function TAuBufReader.ReadU64LE: QWord;
begin
  Result := ReadU32LE;
  Result := Result or (QWord(ReadU32LE) shl 32);
end;

function TAuBufReader.ReadU16BE: Word;
begin
  Result := Word(ReadByte) shl 8;
  Result := Result or ReadByte;
end;

function TAuBufReader.ReadU32BE: Cardinal;
begin
  Result := Cardinal(ReadU16BE) shl 16;
  Result := Result or ReadU16BE;
end;

function TAuBufReader.ReadU64BE: QWord;
begin
  Result := QWord(ReadU32BE) shl 32;
  Result := Result or ReadU32BE;
end;

function TAuBufReader.ReadTag4: string;
var
  B: array[0..3] of Byte;
begin
  ReadExact(B, 4);
  SetLength(Result, 4);
  Result[1] := Chr(B[0]);
  Result[2] := Chr(B[1]);
  Result[3] := Chr(B[2]);
  Result[4] := Chr(B[3]);
end;

{ ---- TAuDecoder ---- }

function TAuDecoder.ReadPcm(Dest: PInt32; MaxFrames: Integer): Integer;
begin
  Result := 0;
  raise EAuAudio.CreateKind(aekUnsupported, 'This stream has no integer PCM');
end;

{ default: integer PCM normalised to -1 .. 1 }
function TAuDecoder.ReadFloat(Dest: PDouble; MaxFrames: Integer): Integer;
var
  Tmp: array of Int32;
  I, N: Integer;
  K: Double;
begin
  if FInfo.Kind <> skPcmInt then
    raise EAuAudio.CreateKind(aekUnsupported, 'This stream has no PCM');
  SetLength(Tmp, MaxFrames * FInfo.Channels);
  Result := ReadPcm(@Tmp[0], MaxFrames);
  N := Result * FInfo.Channels;
  K := 1 / (Int64(1) shl (FInfo.BitsPerSample - 1));
  for I := 0 to N - 1 do Dest[I] := Tmp[I] * K;
end;

function TAuDecoder.ReadDsd(Dest: PByte; MaxFrames: Integer): Integer;
begin
  Result := 0;
  raise EAuAudio.CreateKind(aekUnsupported, 'This stream has no DSD');
end;

function OpenDecoder(const FileName: string): TAuDecoder;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(FileName));
  if E = '.flac' then Result := TAuFlacDecoder.Create
  else if E = '.wav' then Result := TAuWavDecoder.Create
  else if E = '.dsf' then Result := TAuDsfDecoder.Create
  else if E = '.dff' then Result := TAuDffDecoder.Create
  else raise EAuAudio.CreateKind(aekUnsupported, 'Unsupported file type: ' + E);
  try
    Result.FFileName := FileName;
    Result.Open(FileName);
  except
    Result.Free;
    raise;
  end;
end;

{ ---- ReplayGain tags ---- }

function ParseGainValue(const S: string; out V: Double): Boolean;
var
  T: string;
  I: Integer;
  FS: TFormatSettings;
begin
  T := '';
  for I := 1 to Length(S) do
    if S[I] in ['0'..'9', '-', '+', '.', ','] then T := T + S[I]
    else if (T <> '') and (S[I] = ' ') then Break;
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := TryStrToFloat(T, V, FS);
end;

procedure ApplyKey(const Key, Value: string; var RG: TAuReplayGain);
var
  K: string;
  V: Double;
begin
  K := UpperCase(Trim(Key));
  if not ParseGainValue(Value, V) then Exit;
  if K = 'REPLAYGAIN_TRACK_GAIN' then begin RG.TrackGain := V; RG.HasTrack := True; end
  else if K = 'REPLAYGAIN_TRACK_PEAK' then RG.TrackPeak := V
  else if K = 'REPLAYGAIN_ALBUM_GAIN' then begin RG.AlbumGain := V; RG.HasAlbum := True; end
  else if K = 'REPLAYGAIN_ALBUM_PEAK' then RG.AlbumPeak := V;
end;

procedure ApplyTextTag(const Key, Value: string; var Tags: TAuBasicTags);
var
  K: string;
begin
  K := UpperCase(Trim(Key));
  if (K = 'TITLE') or (K = 'TIT2') then begin if Tags.Title = '' then Tags.Title := Value; end
  else if (K = 'ARTIST') or (K = 'TPE1') then begin if Tags.Artist = '' then Tags.Artist := Value; end
  else if (K = 'ALBUM') or (K = 'TALB') then begin if Tags.Album = '' then Tags.Album := Value; end
  else if (K = 'ALBUMARTIST') or (K = 'ALBUM ARTIST') or (K = 'TPE2') then begin if Tags.AlbumArtist = '' then Tags.AlbumArtist := Value; end
  else if (K = 'TRACKNUMBER') or (K = 'TRCK') then begin if Tags.TrackNo = '' then Tags.TrackNo := Value; end;
end;

procedure ApplyVorbisComment(const Comment: string; var RG: TAuReplayGain; var Tags: TAuBasicTags);
var
  P: Integer;
  K: string;
begin
  P := Pos('=', Comment);
  if P <= 1 then Exit;
  K := Copy(Comment, 1, P - 1);
  if Pos('REPLAYGAIN', UpperCase(K)) = 1 then ApplyKey(K, Copy(Comment, P + 1, MaxInt), RG)
  else ApplyTextTag(K, Copy(Comment, P + 1, MaxInt), Tags);
end;

{ ID3v2.3 / 2.4: only the TXXX frames with REPLAYGAIN_* are read }
procedure ParseId3ReplayGain(const Data: TBytes; var RG: TAuReplayGain; var Tags: TAuBasicTags);
var
  Ver, Flags: Byte;
  TagSize, P, FrameSize, EndP, I, Q: Integer;
  Id: string;
  Enc: Byte;
  Frame: TBytes;
  Strs: array[0..1] of string;

  function SyncSafe(Pos: Integer): Integer;
  begin
    Result := (Data[Pos] and $7F) shl 21 or (Data[Pos + 1] and $7F) shl 14 or
      (Data[Pos + 2] and $7F) shl 7 or (Data[Pos + 3] and $7F);
  end;

  { removes the unsynchronisation ($FF $00 -> $FF) }
  function Unsync(const B: TBytes): TBytes;
  var
    J, N: Integer;
  begin
    Result := nil;
    SetLength(Result, Length(B));
    N := 0;
    J := 0;
    while J < Length(B) do
    begin
      Result[N] := B[J];
      Inc(N);
      if (B[J] = $FF) and (J + 1 < Length(B)) and (B[J + 1] = 0) then Inc(J);
      Inc(J);
    end;
    SetLength(Result, N);
  end;

  { the strings of a TXXX frame: description, value }
  procedure SplitText(const B: TBytes);
  var
    J, S, K: Integer;
    W: UnicodeString;
    Cur: Integer;
    BE: Boolean;
  begin
    Strs[0] := '';
    Strs[1] := '';
    if Length(B) < 2 then Exit;
    Enc := B[0];
    Cur := 0;
    J := 1;
    if Enc in [1, 2] then
    begin
      while (J + 1 < Length(B)) and (Cur < 2) do
      begin
        BE := Enc = 2;
        if (B[J] = $FF) and (B[J + 1] = $FE) then begin BE := False; Inc(J, 2); end
        else if (B[J] = $FE) and (B[J + 1] = $FF) then begin BE := True; Inc(J, 2); end;
        W := '';
        while J + 1 < Length(B) do
        begin
          if BE then K := B[J] shl 8 or B[J + 1] else K := B[J + 1] shl 8 or B[J];
          Inc(J, 2);
          if K = 0 then Break;
          W := W + WideChar(K);
        end;
        Strs[Cur] := UTF8Encode(W);
        Inc(Cur);
      end;
    end
    else
    begin
      S := J;
      while (J < Length(B)) and (Cur < 2) do
      begin
        if B[J] = 0 then
        begin
          SetString(Strs[Cur], PAnsiChar(@B[S]), J - S);
          Inc(Cur);
          S := J + 1;
        end;
        Inc(J);
      end;
      if (Cur < 2) and (S < Length(B)) then SetString(Strs[Cur], PAnsiChar(@B[S]), Length(B) - S);
    end;
  end;

begin
  Strs[0] := '';
  Strs[1] := '';
  if (Length(Data) < 10) or (Data[0] <> Ord('I')) or (Data[1] <> Ord('D')) or (Data[2] <> Ord('3')) then Exit;
  Ver := Data[3];
  Flags := Data[5];
  if not (Ver in [3, 4]) then Exit;
  TagSize := SyncSafe(6);
  EndP := Math.Min(Length(Data), 10 + TagSize);
  P := 10;
  if Flags and $40 <> 0 then
  begin
    if Ver = 4 then Inc(P, SyncSafe(P))
    else Inc(P, (Data[P] shl 24 or Data[P + 1] shl 16 or Data[P + 2] shl 8 or Data[P + 3]) + 4);
  end;
  while P + 10 <= EndP do
  begin
    if Data[P] = 0 then Break;                       // padding
    SetString(Id, PAnsiChar(@Data[P]), 4);
    if Ver = 4 then FrameSize := SyncSafe(P + 4)
    else FrameSize := Data[P + 4] shl 24 or Data[P + 5] shl 16 or Data[P + 6] shl 8 or Data[P + 7];
    Q := P + 10;
    if (FrameSize <= 0) or (Q + FrameSize > EndP) then Break;
    if (Id = 'TXXX') or (Id = 'TIT2') or (Id = 'TPE1') or (Id = 'TALB') or (Id = 'TPE2') or (Id = 'TRCK') then
    begin
      Frame := nil;
      SetLength(Frame, FrameSize);
      for I := 0 to FrameSize - 1 do Frame[I] := Data[Q + I];
      if ((Ver = 4) and (Data[P + 9] and $02 <> 0)) or ((Ver = 3) and (Flags and $80 <> 0)) then
        Frame := Unsync(Frame);
      SplitText(Frame);
      if Id = 'TXXX' then ApplyKey(Strs[0], Strs[1], RG)
      else ApplyTextTag(Id, Strs[0], Tags);
    end;
    P := Q + FrameSize;
  end;
end;

end.
