{
This file is part of OvoTag
Copyright (C) 2011 Marco Caselli

OvoTag is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
}
{
  AulumicTag - modified for Aulumic by André Lubke, 2026.
  AulumicTag is a fork of OvoTag (C) 2011 Marco Caselli; see README.md.
  Changes:
    Text decoding (UTF-16 / BOM / TXXX), picture (APIC) reading and writing,
    size limits, protection against saving a partly read tag, extended header
    and header flag handling.
}
{$I ovotag.inc}
unit tag_id3v2;

interface

uses
  Classes, SysUtils, basetag, LConvEncoding;

type

  TID3V1Record = packed record
    Header: array [1..3] of ansichar;
    Title: array [1..30] of ansichar;
    Artist: array [1..30] of ansichar;
    Album: array [1..30] of ansichar;
    Year: array [1..4] of ansichar;
    Comment: array [1..28] of ansichar;
    Stopper: ansichar;
    Track: byte;
    Genre: byte;
  end;

  { TID3Frame }

  TID3Frame = class(TFrameElement)
  protected
    fSize: DWord;
    fFlags: DWord;
    Data: rawbytestring;
    function IsValid: boolean;
  protected
    function GetSize: DWord; override;
  public
    destructor Destroy; override;
    function GetAsString: string; override;
    procedure SetAsString(const AValue: string); override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;

    //Alub added:
    procedure LoadFromImageStream(ImageStream: TMemoryStream; MIMEType: string; PictureType: Byte; IsV22: Boolean);
    // Splits a TXXX / TXX frame into its description and value
    // (AsString returns both glued together). False when the frame has no
    // valid encoding byte or no description terminator.
    function SplitTextPair(out ADesc, AValue: string): boolean;
  end;

  { TID3FrameComment }

  TID3FrameComment = class(TID3Frame)
  private
    fLanguageID: string;
    fDescription: string;
  public
    function GetAsString: string; override;
    procedure SetAsString(const AValue: string); override;
    constructor Create(AID: string); override; overload;
  end;

  { TID3Tags }
  RHeaderInfo = record
    ID: string;
    Flags: integer;
    DataSize: integer;
  end;

  TID3Tags = class(TTags)
  private
    fPadding: Integer;
    fTotalSize: DWORD;
    // Set when ReadFromStream skipped an oversized frame, or when
    // WriteToStream had to drop a frame. Savers refuse to rewrite the file in
    // either case so frames are never silently lost.
    fSkippedFrames: boolean;
    fWriteDroppedFrames: boolean;
    // Set when reading stopped at damaged data inside the tag (not at normal
    // zero padding). Everything after that point was not loaded, so the
    // savers refuse to rewrite the file.
    fUnreadableData: boolean;
    // A repairing read (basetag.TagReadRecover). Damage does not end it: the
    // next place from which frames line up to the end of the tag is searched,
    // and reading goes on there. fUnreadableData stays False, so the tag can
    // be saved without the damaged bytes.
    fRecover: boolean;
    fRecovered: boolean;
    fRecoverKept: Integer;
    fRecoverDiscarded: Int64;
    fRecoverRaw: TBytes;
    // The frame sizes of an ID3v2.4 tag are read as plain numbers (some
    // programs wrote them so; the format wants 7 bits per byte)
    fPlainSizes: boolean;
    // A whole tag (header and all) that WriteToStream writes in place of the
    // frames: an old tag put back as it was
    fRawForWrite: TBytes;
    function GetRecoverRescued: Integer;
    function GetHasRawForWrite: boolean;
    procedure DecodeFrameToImage(Frame: TID3Frame; Image: TImageElement);
    function GetBestMatch(Index1, Index2: integer; NewFrame: boolean): string;
    function GetRealSize: DWord;
    function ImportFromID3V1(AStream: TStream): boolean;
    function IsValid(ID: string): boolean;
    function ReadTagHeader(AStream: TStream; MaxEndPos: Int64; out ID: string;
      out DataSize, Flags: integer): boolean;
  public
    Version: word;
    FromV1: boolean;
  public
    property Size: DWORD read fTotalSize;
    property RealSize: DWord read GetRealSize;
    property Padding: Integer read fPadding write fPadding;
    property HasSkippedFrames: boolean read fSkippedFrames;
    property LastWriteDroppedFrames: boolean read fWriteDroppedFrames;
    property HasUnreadableData: boolean read fUnreadableData;
    // After a repairing read: True when the tag was damaged. RecoverKept
    // frames stood in front of the damage, RecoverRescued behind it,
    // RecoverDiscarded bytes could not be read, RecoverRaw is the tag as it
    // stands in the file, RecoverPlainSizes says that the frame sizes were
    // written in the wrong form (nothing is lost then).
    property Recovered: boolean read fRecovered;
    property RecoverKept: Integer read fRecoverKept;
    property RecoverRescued: Integer read GetRecoverRescued;
    property RecoverDiscarded: Int64 read fRecoverDiscarded;
    property RecoverRaw: TBytes read fRecoverRaw;
    property RecoverPlainSizes: boolean read fPlainSizes;
    // Lets the next save write ATag, a whole ID3v2 tag as it once stood in a
    // file, in place of the frames in memory. False (and nothing is set)
    // when ATag is not one tag from its header to its end.
    function SetRawForWrite(const ATag: TBytes): boolean;
    property HasRawForWrite: boolean read GetHasRawForWrite;
    function GetCommonTags: TCommonTags; override;
    procedure SetCommonTags(const CommonTags: TCommonTags); override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;
  end;

  TID3Header = packed record
    Marker: array[0..2] of ansichar;
    Version: word;
    Flags: byte;
    size: dword;
  end;

const
  ID3_HEADER_MARKER = 'ID3';

implementation

uses
  CommonFunctions, ID3v1Genres, lazutf8;

type

  TID3FrameHeader = packed record
    ID: array [0..3] of ansichar;
    Size: DWord;
    Flags: word;
  end;

  TID3FrameHeaderOld = packed record
    ID: array [0..2] of ansichar;
    Size: array [0..2] of byte;
  end;

const
  TAG_VERSION_2_2   = 2;
  TAG_VERSION_2_3   = 3;
  TAG_VERSION_2_4   = 4;
  ID3V2_FRAME_COUNT = 18;
  // Frames larger than these are
  // passed over by ReadFromStream, so the text frames behind them are still read
  MAX_ID3_FRAME_SIZE      = 32 * 1024 * 1024; // 32 MB max for APIC/PIC frames
  MAX_ID3_TEXT_FRAME_SIZE = 2 * 1024 * 1024;  // 2 MB max for non-image frames
  MAX_ID3_TAG_SYNCSAFE    = $0FFFFFFF;        // 256 MB - 1 (28-bit synchsafe limit)
  MAX_ID3_V22_FRAME_SIZE  = $00FFFFFF;        // 16 MB - 1 (24-bit v2.2 frame limit)

  { Names of supported tag frames (ID3v2.3.x & ID3v2.4.x) }
  ID3V2_KNOWNFRAME: array [1..ID3V2_FRAME_COUNT, boolean] of ansistring = (
    ('TIT2', 'TT2'),    // 1
    ('TPE1', 'TP1'),
    ('TALB', 'TAL'),
    ('TRCK', 'TRK'),
    ('TYER', 'TYE'),    // 5
    ('TCON', 'TCO'),
    ('COMM', 'COM'),    // 7
    ('TCOM', 'TCM'),
    ('TENC', 'TEN'),
    ('TCOP', 'TCR'),    // 10
    ('TLAN', 'TLA'),
    ('WXXX', 'WXX'),
    ('TDRC', 'TOR'),
    ('TOPE', 'TOA'),
    ('TIT1', 'TT1'),    // 15
    ('TOAL', 'TOT'),
    ('TSIZ', 'TSI'),
    ('TPE2', 'TP2')
  );

// Spec-compliant UTF-16 TXXX frames carry a separate BOM for
// the description and the value. Remove any BOM code units ($FEFF, or a
// byte-swapped $FFFE) left inside the decoded string so callers such as
// ExtractReplayGain see the plain text.
procedure StripEmbeddedBOMs(var W: UnicodeString);
var
  I, J: Integer;
begin
  J := 0;
  for I := 1 to Length(W) do
  begin
    if (Word(W[I]) = $FEFF) or (Word(W[I]) = $FFFE) then
      Continue;
    Inc(J);
    if J <> I then
      W[J] := W[I];
  end;
  if J <> Length(W) then
    SetLength(W, J);
end;

// The values of a text frame as one text: a text frame may hold several
// values with a zero character between them (ID3v2.4). They are joined with
// '; '; zeros at the start and the end (terminators) and empty values give no
// separator.
function JoinTextValues(const S: string): string;
var
  I, First, Last: Integer;
  Pending: Boolean;
begin
  Result := '';
  First  := 1;
  Last   := Length(S);
  while (First <= Last) and (S[First] = #0) do Inc(First);
  while (Last >= First) and (S[Last] = #0) do Dec(Last);
  Pending := False;
  for I := First to Last do
  begin
    if S[I] = #0 then
      Pending := True
    else
    begin
      if Pending then
      begin
        Result  := TrimRight(Result) + '; ';
        Pending := False;
      end;
      Result := Result + S[I];
    end;
  end;
end;

// Custom Text Decoder with strict buffer-length clamping. AMulti: the text may
// hold several values (see JoinTextValues); without it zero characters are
// only removed.
function CustomDecodeID3Text(Encoding: byte; const Buffer: rawbytestring; StartIdx, Len: integer;
  AMulti: boolean = False): string;
var
  S8: UTF8String;
  WStr: UnicodeString;
  BOM1, BOM2: byte;
  I, MaxAvail: integer;
begin
  Result := '';
  if (Len <= 0) or (StartIdx < 1) or (StartIdx > Length(Buffer)) then
    Exit;

  MaxAvail := Length(Buffer) - StartIdx + 1;
  if Len > MaxAvail then
    Len := MaxAvail;
  if Len <= 0 then
    Exit;

  try
    case Encoding of
      0: // ISO-8859-1 / Latin-1
        begin
          SetString(S8, PAnsiChar(@Buffer[StartIdx]), Len);
          Result := ISO_8859_1ToUTF8(S8);
        end;
      3: // UTF-8
        begin
          SetString(S8, PAnsiChar(@Buffer[StartIdx]), Len);
          Result := string(S8);
        end;
      1, 2: // UTF-16
        begin
          if Len < 2 then
            Exit;
          BOM1 := byte(Buffer[StartIdx]);
          BOM2 := byte(Buffer[StartIdx + 1]);

          if (BOM1 = $FF) and (BOM2 = $FE) then // Little Endian
          begin
            SetString(WStr, PWideChar(@Buffer[StartIdx + 2]), (Len - 2) div 2);
            StripEmbeddedBOMs(WStr);
            Result := UTF16ToUTF8(WStr);
          end
          else if (BOM1 = $FE) and (BOM2 = $FF) then // Big Endian
          begin
            SetLength(WStr, (Len - 2) div 2);
            for I := 1 to Length(WStr) do
              PWord(@WStr[I])^ := (byte(Buffer[StartIdx + 2 * I]) shl 8) or
                                  byte(Buffer[StartIdx + 2 * I + 1]);
            StripEmbeddedBOMs(WStr);
            Result := UTF16ToUTF8(WStr);
          end
          else if Encoding = 2 then // UTF-16BE without BOM
          begin
            SetLength(WStr, Len div 2);
            for I := 1 to Length(WStr) do
              PWord(@WStr[I])^ := (byte(Buffer[StartIdx + 2 * I - 2]) shl 8) or
                                  byte(Buffer[StartIdx + 2 * I - 1]);
            StripEmbeddedBOMs(WStr);
            Result := UTF16ToUTF8(WStr);
          end
          else // Assume Little Endian without BOM
          begin
            SetString(WStr, PWideChar(@Buffer[StartIdx]), Len div 2);
            StripEmbeddedBOMs(WStr);
            Result := UTF16ToUTF8(WStr);
          end;
        end;
    end;

    if AMulti then
      Result := JoinTextValues(Result);

    // Eliminate all #0 characters which cause Windows UI controls to truncate text
    Result := Trim(StringReplace(Result, #0, '', [rfReplaceAll]));
  except
    Result := '';
  end;
end;

{ TID3Tags }

function TID3Tags.GetBestMatch(Index1, Index2: integer; NewFrame: boolean): string;
begin
  Result := GetFrameValue(ID3V2_KNOWNFRAME[Index1, NewFrame]);
  if Result = '' then
    Result := GetFrameValue(ID3V2_KNOWNFRAME[Index2, NewFrame]);
end;

function TID3Tags.GetHasRawForWrite: boolean;
begin
  Result := Length(fRawForWrite) > 0;
end;

function TID3Tags.SetRawForWrite(const ATag: TBytes): boolean;
var
  TagBytes: Int64;
begin
  Result := False;
  if (Length(ATag) < 10) or (Int64(Length(ATag)) > Int64(MAX_ID3_TAG_SYNCSAFE) + 10) then
    Exit;
  if (ATag[0] <> Ord('I')) or (ATag[1] <> Ord('D')) or (ATag[2] <> Ord('3')) then
    Exit;
  if ((ATag[6] or ATag[7] or ATag[8] or ATag[9]) and $80) <> 0 then
    Exit;
  TagBytes := (Int64(ATag[6]) shl 21) or (Int64(ATag[7]) shl 14) or (Int64(ATag[8]) shl 7) or ATag[9];
  if TagBytes + 10 <> Length(ATag) then
    Exit;
  fRawForWrite := Copy(ATag, 0, Length(ATag));
  Result := True;
end;

function TID3Tags.GetRecoverRescued: Integer;
begin
  if fRecovered and (not fPlainSizes) then
    Result := Count - fRecoverKept
  else
    Result := 0;
end;

function TID3Tags.GetRealSize: DWord;
var
  HeadSize, i: Integer;
begin
  if Version >= TAG_VERSION_2_3 then
    HeadSize := 10
  else
    HeadSize := 6;

  Result := 0;
  for i := 0 to Count - 1 do
  begin
    if Frames[i].Size > 0 then
      Result := Result + Frames[i].Size + DWord(HeadSize);
  end;
end;

function TID3Tags.ImportFromID3V1(AStream: TStream): boolean;
var
  V1Rec: TID3V1Record;
  Frame: TID3Frame;
begin
  fTotalSize := 0;
  Result     := False;

  if (not Assigned(AStream)) or (AStream.Size < SizeOf(V1Rec)) then
    Exit;

  AStream.Seek(AStream.Size - SizeOf(V1Rec), soFromBeginning);
  if AStream.Read(V1Rec, SizeOf(V1Rec)) < SizeOf(V1Rec) then
    Exit;

  if V1Rec.Header <> 'TAG' then
    Exit;

  Version := TAG_VERSION_2_3;
  if Trim(V1Rec.Artist) <> '' then
  begin
    Frame          := TID3Frame.Create('TPE1');
    Frame.Tagger   := Self;
    Frame.fFlags   := 0;
    Frame.AsString := ISO_8859_1ToUTF8(Trim(V1Rec.Artist));
    Add(Frame);
  end;

  if Trim(V1Rec.Album) <> '' then
  begin
    Frame          := TID3Frame.Create('TALB');
    Frame.Tagger   := Self;
    Frame.fFlags   := 0;
    Frame.AsString := ISO_8859_1ToUTF8(Trim(V1Rec.Album));
    Add(Frame);
  end;

  if Trim(V1Rec.Title) <> '' then
  begin
    Frame          := TID3Frame.Create('TIT2');
    Frame.Tagger   := Self;
    Frame.fFlags   := 0;
    Frame.AsString := ISO_8859_1ToUTF8(Trim(V1Rec.Title));
    Add(Frame);
  end;

  if Trim(V1Rec.Year) <> '' then
  begin
    Frame          := TID3Frame.Create('TYER');
    Frame.Tagger   := Self;
    Frame.fFlags   := 0;
    Frame.AsString := ISO_8859_1ToUTF8(Trim(V1Rec.Year));
    Add(Frame);
  end;

  if V1Rec.Genre <= ID3_MaxGenreExtended then
  begin
    Frame          := TID3Frame.Create('TCON');
    Frame.Tagger   := Self;
    Frame.fFlags   := 0;
    Frame.AsString := ISO_8859_1ToUTF8(v1Genres[V1Rec.Genre]);
    Add(Frame);
  end;

  if V1Rec.Stopper = #00 then
  begin
    if Trim(V1Rec.Comment) <> '' then
    begin
      Frame          := TID3FrameComment.Create('COMM');
      Frame.Tagger   := Self;
      Frame.fFlags   := 0;
      Frame.AsString := ISO_8859_1ToUTF8(Trim(V1Rec.Comment));
      Add(Frame);
    end;

    if V1Rec.Track > 0 then
    begin
      Frame          := TID3Frame.Create('TRCK');
      Frame.Tagger   := Self;
      Frame.fFlags   := 0;
      Frame.AsString := IntToStr(V1Rec.Track);
      Add(Frame);
    end;
  end
  else
  begin
    if Trim(V1Rec.Comment + V1Rec.Stopper + Char(V1Rec.Track)) <> '' then
    begin
      Frame          := TID3FrameComment.Create('COMM');
      Frame.Tagger   := Self;
      Frame.fFlags   := 0;
      Frame.AsString := ISO_8859_1ToUTF8(Trim(V1Rec.Comment + V1Rec.Stopper + Char(V1Rec.Track)));
      Add(Frame);
    end;
  end;
  Result := True;
end;

function TID3Tags.IsValid(ID: string): boolean;
var
  C: char;
begin
  Result := False;
  if Length(ID) < 3 then
    Exit;

  for C in ID do
    if not (C in ['A'..'Z', '0'..'9']) then
      Exit;

  Result := True;
end;

function TID3Tags.ReadTagHeader(AStream: TStream; MaxEndPos: Int64; out ID: string;
  out DataSize, Flags: integer): boolean;
var
  Header: TID3FrameHeader;
  HeaderOld: TID3FrameHeaderOld;
begin
  Result   := False;
  ID       := '';
  DataSize := 0;
  Flags    := 0;

  if Version < TAG_VERSION_2_3 then
  begin
    if (MaxEndPos - AStream.Position) < SizeOf(HeaderOld) then
      Exit;
    if AStream.Read(HeaderOld, SizeOf(HeaderOld)) < SizeOf(HeaderOld) then
      Exit;
    SetString(ID, PAnsiChar(@HeaderOld.ID[0]), 3);
    Flags := 0;
    if not IsValid(ID) then
      Exit;
    DataSize := (Integer(HeaderOld.Size[0]) shl 16) +
                (Integer(HeaderOld.Size[1]) shl 8) +
                Integer(HeaderOld.Size[2]);
  end
  else
  begin
    if (MaxEndPos - AStream.Position) < 10 then
      Exit;
    if AStream.Read(Header, 10) < 10 then
      Exit;
    SetString(ID, PAnsiChar(@Header.ID[0]), 4);
    if not IsValid(ID) then
      Exit;
    Flags := Header.Flags;
    if (Version >= TAG_VERSION_2_4) and (not fPlainSizes) then
      DataSize := Integer(SyncSafe_Decode(Header.Size))
    else
      DataSize := Integer(BEtoN(Header.Size));
  end;

  // Only negative and past-the-end sizes are rejected here. A frame larger
  // than the memory cap is passed over by ReadFromStream, and so is an empty
  // frame (size 0, written by some programs): the frames behind it are read.
  if (DataSize < 0) or ((AStream.Position + DataSize) > MaxEndPos) then
    Exit;

  Result := True;
end;

function TID3Tags.GetCommonTags: TCommonTags;
var
  UseOldTag: boolean;
  i: integer;
  TempComment, FrameID: string;
begin
  Result    := inherited GetCommonTags;
  UseOldTag := (Version <= TAG_VERSION_2_2) and not FromV1;

  Result.Artist      := GetBestMatch(2, 14, UseOldTag);
  Result.Title       := GetBestMatch(1, 15, UseOldTag);
  Result.Album       := GetBestMatch(3, 16, UseOldTag);
  Result.Year        := GetBestMatch(13, 5, UseOldTag);
  Result.AlbumArtist := GetContent(GetFrameValue(ID3V2_KNOWNFRAME[18, UseOldTag]), Result.Artist);
  Result.Track       := ExtractTrack(GetFrameValue(ID3V2_KNOWNFRAME[4, UseOldTag]));
  Result.TrackString := GetFrameValue(ID3V2_KNOWNFRAME[4, UseOldTag]);

  TempComment := '';
  FrameID     := ID3V2_KNOWNFRAME[7, UseOldTag]; // 'COMM' or 'COM'
  for i := 0 to Count - 1 do
  begin
    if (Frames[i].ID = FrameID) and (Frames[i].Size <= MAX_ID3_TEXT_FRAME_SIZE) then
    begin
      if Length(TempComment) < 16384 then
      begin
        if TempComment <> '' then
          TempComment := TempComment + #13#10#13#10;
        TempComment := TempComment + Copy(Frames[i].AsString, 1, 16384);
      end;
    end;
  end;
  Result.Comment := TempComment;

  Result.Genre    := ExtractGenre(GetFrameValue(ID3V2_KNOWNFRAME[6, UseOldTag]));
  Result.HasImage := ImageCount > 0;
end;

procedure TID3Tags.SetCommonTags(const CommonTags: TCommonTags);
var
  UseOldTag: boolean;
begin
  inherited SetCommonTags(CommonTags);
  if Version = 0 then
    Version := TAG_VERSION_2_3;

  UseOldTag := (Version <= TAG_VERSION_2_2) and not FromV1;
  SetFrameValue(ID3V2_KNOWNFRAME[2, UseOldTag], CommonTags.Artist, TID3Frame);
  SetFrameValue(ID3V2_KNOWNFRAME[1, UseOldTag], CommonTags.Title, TID3Frame);
  SetFrameValue(ID3V2_KNOWNFRAME[3, UseOldTag], CommonTags.Album, TID3Frame);

  if Trim(CommonTags.Year) = '' then
  begin
    SetFrameValue(ID3V2_KNOWNFRAME[5, UseOldTag], '', TID3Frame);
    SetFrameValue(ID3V2_KNOWNFRAME[13, UseOldTag], '', TID3Frame);
  end
  else if (Length(CommonTags.Year) = 4) and isValidYear(CommonTags.Year) then
  begin
    SetFrameValue(ID3V2_KNOWNFRAME[13, UseOldTag], '', TID3Frame);
    SetFrameValue(ID3V2_KNOWNFRAME[5, UseOldTag], CommonTags.Year, TID3Frame);
  end
  else
  begin
    SetFrameValue(ID3V2_KNOWNFRAME[5, UseOldTag], '', TID3Frame);
    SetFrameValue(ID3V2_KNOWNFRAME[13, UseOldTag], CommonTags.Year, TID3Frame);
  end;

  SetFrameValue(ID3V2_KNOWNFRAME[18, UseOldTag], CommonTags.AlbumArtist, TID3Frame);
  SetFrameValue(ID3V2_KNOWNFRAME[4, UseOldTag], CommonTags.TrackString, TID3Frame);
  SetFrameValue(ID3V2_KNOWNFRAME[7, UseOldTag], CommonTags.Comment, TID3FrameComment);
  SetFrameValue(ID3V2_KNOWNFRAME[6, UseOldTag], CommonTags.Genre, TID3Frame);
end;

procedure TID3Tags.DecodeFrameToImage(Frame: TID3Frame; Image: TImageElement);
var
  BufLen, PosIdx, StartIdx, DescLen, ImgBytes: Integer;
  Encoding: Byte;
begin
  Image.FrameRef := Frame;
  if (not Assigned(Frame)) or (Frame.fSize < 6) or (Length(Frame.Data) < Integer(Frame.fSize)) then
    Exit;

  BufLen   := Integer(Frame.fSize);
  Encoding := Byte(Frame.Data[1]);
  PosIdx   := 2;

  // 1. Extract MIME Type
  if (Version <= TAG_VERSION_2_2) and SameText(Frame.ID, 'PIC') then
  begin
    StartIdx := PosIdx;
    while (PosIdx <= BufLen) and (Frame.Data[PosIdx] <> #0) and ((PosIdx - StartIdx) < 32) do
      Inc(PosIdx);

    if (PosIdx <= BufLen) and (Frame.Data[PosIdx] = #0) and ((PosIdx - StartIdx) <= 16) then
    begin
      Image.MIMEType := Copy(string(Frame.Data), StartIdx, PosIdx - StartIdx);
      Inc(PosIdx); // Skip #0
    end
    else
    begin
      PosIdx         := StartIdx;
      Image.MIMEType := Copy(string(Frame.Data), PosIdx, 3);
      Inc(PosIdx, 3);
    end;
  end
  else
  begin
    StartIdx := PosIdx;
    while (PosIdx <= BufLen) and (Frame.Data[PosIdx] <> #0) do
      Inc(PosIdx);
    Image.MIMEType := Copy(string(Frame.Data), StartIdx, PosIdx - StartIdx);
    if PosIdx <= BufLen then
      Inc(PosIdx); // Skip #0
  end;

  if PosIdx > BufLen then
    Exit;

  // 2. Picture Type (1 byte)
  if Version > TAG_VERSION_2_2 then
  begin
    Image.PictureType := Byte(Frame.Data[PosIdx]);
    Inc(PosIdx);
  end
  else if PosIdx <= BufLen then
  begin
    if Frame.Data[PosIdx] in [#0..#20] then
    begin
      Image.PictureType := Byte(Frame.Data[PosIdx]);
      Inc(PosIdx);
    end;
  end;

  if PosIdx > BufLen then
    Exit;

  // 3. Description (Null-terminated according to Encoding)
  StartIdx := PosIdx;
  if (Encoding = 1) or (Encoding = 2) then
  begin
    while (PosIdx + 1 <= BufLen) and
          not ((Frame.Data[PosIdx] = #0) and (Frame.Data[PosIdx + 1] = #0)) do
      Inc(PosIdx, 2);
    DescLen := PosIdx - StartIdx;
    Image.Description := CustomDecodeID3Text(Encoding, Frame.Data, StartIdx, DescLen);
    Inc(PosIdx, 2); // Skip $00 $00
  end
  else
  begin
    while (PosIdx <= BufLen) and (Frame.Data[PosIdx] <> #0) do
      Inc(PosIdx);
    DescLen := PosIdx - StartIdx;
    Image.Description := CustomDecodeID3Text(Encoding, Frame.Data, StartIdx, DescLen);
    Inc(PosIdx); // Skip $00
  end;

  if PosIdx > BufLen then
    Exit;

  // 4. Copy raw image payload safely
  ImgBytes := BufLen - PosIdx + 1;
  if ImgBytes > 0 then
  begin
    Image.Image.Size     := 0;
    Image.Image.Position := 0;
    Image.Image.WriteBuffer(Frame.Data[PosIdx], ImgBytes);
    Image.Image.Position := 0;
  end;
end;

function TID3Tags.WriteToStream(AStream: TStream): DWord;
var
  header: TID3Header;
  tmpSize, FrameSz: QWord;
  i: integer;
  HeadSize: integer;
  tmpbuf: array of byte;
  Include: array of boolean;
begin
  Result              := 0;
  fWriteDroppedFrames := False;
  Include             := nil;
  if Length(fRawForWrite) > 0 then
  begin
    AStream.WriteBuffer(fRawForWrite[0], Length(fRawForWrite));
    Exit(DWord(Length(fRawForWrite) - 10));
  end;
  if Version = 0 then
    Version := TAG_VERSION_2_3;

  header.Marker  := ID3_HEADER_MARKER;
  header.Version := Version;
  if Version >= TAG_VERSION_2_3 then
    HeadSize := 10
  else
    HeadSize := 6;
  header.Flags := 0;
  tmpSize      := 0;

  // Decide once which frames are written, so the header size and
  // the frames actually written can never disagree. Frames that cannot fit in
  // v2.2 (16 MB) or the 256 MB synchsafe header are skipped and flagged.
  SetLength(Include, Count);
  for i := 0 to Count - 1 do
  begin
    Include[i] := False;
    FrameSz    := Frames[i].Size;
    if FrameSz > 0 then
    begin
      if (Version < TAG_VERSION_2_3) and (FrameSz > MAX_ID3_V22_FRAME_SIZE) then
      begin
        fWriteDroppedFrames := True;
        Continue;
      end;
      if (tmpSize + FrameSz + QWord(HeadSize)) > MAX_ID3_TAG_SYNCSAFE then
      begin
        fWriteDroppedFrames := True;
        Continue;
      end;
      Include[i] := True;
      Inc(tmpSize, FrameSz + QWord(HeadSize));
    end;
  end;

  if fPadding > 0 then
  begin
    if (tmpSize + QWord(fPadding)) <= MAX_ID3_TAG_SYNCSAFE then
      Inc(tmpSize, QWord(fPadding))
    else
      fPadding := 0;
  end;

  header.size := SyncSafe_Encode(DWord(tmpSize));
  AStream.WriteBuffer(header, SizeOf(header));

  for i := 0 to Count - 1 do
  begin
    if Include[i] then
      Frames[i].WriteToStream(AStream);
  end;
  Result := DWord(tmpSize);

  if fPadding > 0 then
  begin
    SetLength(tmpbuf, fPadding);
    FillByte(tmpbuf[0], fPadding, $00);
    AStream.WriteBuffer(tmpbuf[0], fPadding);
  end;
end;

function TID3Tags.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
var
  header: TID3Header;
  Frame: TID3Frame;
  Image: TImageElement;
  Stop: boolean;
  HeaderInfo: RHeaderInfo;
  TagStartPos, TagEndPos: Int64;
  FrameHeadSize, MaxFrameCap: Integer;
  ReadOk: Boolean;
  FramePos: Int64;

  // True when the range [AFrom, ATo) contains anything but zero bytes, i.e.
  // real data rather than padding. Scans at most 1 MB.
  function HasNonZeroBytes(AFrom, ATo: Int64): boolean;
  const
    MAX_SCAN = 1024 * 1024;
  var
    Buf: array[0..4095] of byte;
    ToRead, Got, K: Integer;
    SavedPos: Int64;
  begin
    Result := False;
    if ATo - AFrom > MAX_SCAN then
      ATo := AFrom + MAX_SCAN;
    if ATo <= AFrom then
      Exit;
    SavedPos := AStream.Position;
    try
      AStream.Position := AFrom;
      while (AStream.Position < ATo) and (not Result) do
      begin
        ToRead := SizeOf(Buf);
        if ATo - AStream.Position < ToRead then
          ToRead := Integer(ATo - AStream.Position);
        Got := AStream.Read(Buf[0], ToRead);
        if Got <= 0 then
          Break;
        for K := 0 to Got - 1 do
          if Buf[K] <> 0 then
          begin
            Result := True;
            Break;
          end;
      end;
    finally
      AStream.Position := SavedPos;
    end;
  end;

  // Skips the ID3v2.3 / v2.4 extended header, so reading starts
  // at the first frame. v2.3: the size field excludes itself; v2.4: it is
  // synchsafe and includes itself. False when the size is invalid.
  function SkipExtendedHeader: boolean;
  var
    Raw: DWord;
    ExtSize: Int64;
  begin
    Result := False;
    if (TagEndPos - AStream.Position) < 4 then
      Exit;
    Raw := 0;
    if AStream.Read(Raw, 4) < 4 then
      Exit;
    if Version >= TAG_VERSION_2_4 then
      ExtSize := Int64(SyncSafe_Decode(Raw)) - 4
    else
      ExtSize := Int64(BEtoN(Raw));
    if (ExtSize < 0) or ((AStream.Position + ExtSize) > TagEndPos) then
      Exit;
    AStream.Position := AStream.Position + ExtSize;
    Dec(fPadding, Integer(ExtSize) + 4);
    Result := True;
  end;

  // True when frames line up from APos to the end of the tag: header after
  // header, then nothing but zero padding (at least one frame). With
  // AAllowDamage two frames in a row are enough when damage follows them: a
  // single frame between two damaged places is not told from chance.
  function ChainFrom(APos: Int64; AAllowDamage: boolean = False): boolean;
  var
    SavedPos, P: Int64;
    ChainID: string;
    ChainSize, ChainFlags, N: Integer;
  begin
    Result   := False;
    SavedPos := AStream.Position;
    try
      P := APos;
      N := 0;
      while P < TagEndPos do
      begin
        AStream.Position := P;
        if not ReadTagHeader(AStream, TagEndPos, ChainID, ChainSize, ChainFlags) then
        begin
          if HasNonZeroBytes(P, TagEndPos) then
            Exit(AAllowDamage and (N >= 2));
          Break;
        end;
        P := AStream.Position + ChainSize;
        Inc(N);
      end;
      Result := N > 0;
    finally
      AStream.Position := SavedPos;
    end;
  end;

  // The next place behind AFrom where frames line up to the end of the tag
  function FindNextFrame(AFrom: Int64; out APos: Int64): boolean;
  var
    P: Int64;
    B: byte;
  begin
    Result := False;
    APos   := 0;
    P      := AFrom + 1;
    while P + FrameHeadSize <= TagEndPos do
    begin
      AStream.Position := P;
      B := 0;
      if AStream.Read(B, 1) < 1 then
        Break;
      // a frame ID begins with a capital letter or a digit
      if (AnsiChar(B) in ['A'..'Z', '0'..'9']) and ChainFrom(P, True) then
      begin
        APos   := P;
        Result := True;
        Break;
      end;
      Inc(P);
    end;
  end;

  // The end of the data from AFrom on: behind the last byte that is not zero
  // (what follows is padding)
  function DataEnd(AFrom: Int64): Int64;
  var
    Buf: array[0..4095] of byte;
    Got, K: Integer;
    P: Int64;
  begin
    Result := AFrom;
    P      := AFrom;
    AStream.Position := AFrom;
    while P < TagEndPos do
    begin
      Got := SizeOf(Buf);
      if TagEndPos - P < Got then
        Got := Integer(TagEndPos - P);
      Got := AStream.Read(Buf[0], Got);
      if Got <= 0 then
        Break;
      for K := 0 to Got - 1 do
        if Buf[K] <> 0 then
          Result := P + K + 1;
      Inc(P, Got);
    end;
  end;

  // Damage at AFrom during a repairing read. True when reading goes on (the
  // stream stands at the next frame); False when nothing more can be read.
  function RecoverAt(AFrom: Int64): boolean;
  var
    Next: Int64;
  begin
    if not fRecovered then
      fRecoverKept := Count;
    fRecovered := True;
    Result     := FindNextFrame(AFrom, Next);
    if Result then
    begin
      Inc(fRecoverDiscarded, Next - AFrom);
      Dec(fPadding, Integer(Next - AFrom));
      AStream.Position := Next;
    end
    else
      Inc(fRecoverDiscarded, DataEnd(AFrom) - AFrom);
  end;

begin
  Clear;
  Result            := False;
  FromV1            := False;
  fSkippedFrames    := False;
  fUnreadableData   := False;
  fRecover          := TagReadRecover;
  fRecovered        := False;
  fRecoverKept      := 0;
  fRecoverDiscarded := 0;
  fRecoverRaw       := nil;
  fPlainSizes       := False;
  fRawForWrite      := nil;

  if (not Assigned(AStream)) or ((AStream.Size - AStream.Position) < SizeOf(header)) then
    Exit;

  TagStartPos := AStream.Position;
  if AStream.Read(header, SizeOf(header)) < SizeOf(header) then
    Exit;

  if header.Marker <> ID3_HEADER_MARKER then
  begin
    FromV1 := ImportFromID3V1(AStream);
    Result := FromV1;
    Exit;
  end;

  Version    := Lo(header.Version);
  fTotalSize := SyncSafe_Decode(header.size);
  fPadding   := Integer(fTotalSize);
  Stop       := False;

  TagEndPos := TagStartPos + SizeOf(header) + Int64(fTotalSize);
  if TagEndPos > AStream.Size then
    TagEndPos := AStream.Size;

  if Version >= TAG_VERSION_2_3 then
    FrameHeadSize := 10
  else
    FrameHeadSize := 6;

  // Tag header flags. The tag is always rewritten without them:
  // - Unsynchronisation ($80) in v2.2 / v2.3: the frame data is stored with
  //   inserted $00 bytes; writing it back as-is would damage pictures, so
  //   such a tag is never saved (v2.4 marks this per frame; those frame flags
  //   are kept on rewrite).
  // - $40 in v2.2 means compression: the frames cannot be read, never save.
  // - $40 in v2.3 / v2.4 is the extended header: skip it so the frames are
  //   found (it is not written back). If its size is invalid, never save.
  if (Version in [TAG_VERSION_2_2..TAG_VERSION_2_4]) and (fTotalSize > 0) then
  begin
    if (Version <= TAG_VERSION_2_3) and ((header.Flags and $80) <> 0) then
      fSkippedFrames := True;

    if (header.Flags and $40) <> 0 then
    begin
      if (Version <= TAG_VERSION_2_2) or (not SkipExtendedHeader) then
      begin
        fSkippedFrames := True;
        Stop           := True;
      end;
    end;
  end;

  // A repairing read of an ID3v2.4 tag whose frames do not line up: when they
  // do with their sizes read as plain numbers, the tag is read that way (a
  // save writes the sizes in the right form)
  if fRecover and (not Stop) and (Version = TAG_VERSION_2_4) and (fTotalSize > 0) and
     (not ChainFrom(AStream.Position)) then
  begin
    fPlainSizes := True;
    if ChainFrom(AStream.Position) then
      fRecovered := True
    else
      fPlainSizes := False;
  end;

  if (Version in [TAG_VERSION_2_2..TAG_VERSION_2_4]) and (fTotalSize > 0) then
  begin
    while (AStream.Position < TagEndPos) and (not Stop) do
    begin
      FramePos := AStream.Position;
      if not ReadTagHeader(AStream, TagEndPos, HeaderInfo.ID, HeaderInfo.DataSize, HeaderInfo.Flags) then
      begin
        // End of the frames: normal when only zero padding follows, damage otherwise
        if HasNonZeroBytes(FramePos, TagEndPos) then
        begin
          if fRecover then
          begin
            if RecoverAt(FramePos) then
              Continue;
          end
          else
            fUnreadableData := True;
        end;
        Stop := True;
        Continue;
      end;

      // An empty frame holds nothing: it is left out (a save does not write
      // it again) and reading goes on with the frame behind it
      if HeaderInfo.DataSize = 0 then
      begin
        Dec(fPadding, FrameHeadSize);
        Continue;
      end;

      // If a frame is larger than our RAM cap (e.g. a >32 MB APIC
      // or a >2 MB binary GEOB frame), Seek() past it and continue reading
      // the remaining text frames instead of aborting the tag scan!
      if (HeaderInfo.ID = 'APIC') or (HeaderInfo.ID = 'PIC') then
        MaxFrameCap := MAX_ID3_FRAME_SIZE
      else
        MaxFrameCap := MAX_ID3_TEXT_FRAME_SIZE;

      // text only (basetag.TagReadTextOnly): pictures are
      // passed over like a frame that is too large
      if (HeaderInfo.DataSize > MaxFrameCap) or
         (TagReadTextOnly and ((HeaderInfo.ID = 'APIC') or (HeaderInfo.ID = 'PIC'))) then
      begin
        AStream.Seek(HeaderInfo.DataSize, soFromCurrent);
        Dec(fPadding, HeaderInfo.DataSize + FrameHeadSize);
        // Remember that this tag is incomplete in memory so it is never rewritten
        fSkippedFrames := True;
        Continue;
      end;

      if (HeaderInfo.ID = 'COMM') or (HeaderInfo.ID = 'COM') then
        Frame := TID3FrameComment.Create
      else
        Frame := TID3Frame.Create;

      Frame.Tagger := Self;
      try
        ReadOk := Frame.ReadFromStream(AStream, @HeaderInfo);
      except
        FreeAndNil(Frame);
        raise;
      end;

      if ReadOk then
      begin
        Add(Frame);
        if (Frame.ID = 'APIC') or (Frame.ID = 'PIC') then
        begin
          Image := TImageElement.Create;
          try
            DecodeFrameToImage(Frame, Image);
          except
            FreeAndNil(Image);
            raise;
          end;

          if Image.Image.Size > 0 then
            AddImage(Image)
          else
            FreeAndNil(Image);
        end;
        Dec(fPadding, Integer(Frame.Size) + FrameHeadSize);
      end
      else
      begin
        // A frame with a valid header whose content could not be decoded
        FreeAndNil(Frame);
        if fRecover then
        begin
          if not RecoverAt(FramePos) then
            Stop := True;
        end
        else
        begin
          fUnreadableData := True;
          Stop := True;
        end;
      end;
    end;
  end;

  if fPadding < 0 then
    fPadding := 0;

  // The tag as it stands in the file, for a copy before it is repaired
  if fRecovered and (TagEndPos > TagStartPos) then
  begin
    SetLength(fRecoverRaw, TagEndPos - TagStartPos);
    AStream.Position := TagStartPos;
    AStream.ReadBuffer(fRecoverRaw[0], Length(fRecoverRaw));
  end;


  Result := Count > 0;
  if Result then
    fTotalSize := fTotalSize + SizeOf(header);
end;

{ TID3FrameComment }

function TID3FrameComment.GetAsString: string;
var
  Encoding: byte;
  TerminatorSize: integer;
  WSize: integer;
  NextOffset: integer;
  CleanDesc, CleanVal: string;
begin
  Result := '';
  if (fSize < 5) or (Length(Data) < Integer(fSize)) then
    Exit;

  Encoding    := byte(Data[1]);
  fLanguageID := Copy(Data, 2, 3);

  case Encoding of
    00, 03: TerminatorSize := 1;
    01, 02: TerminatorSize := 2;
  else
    begin
      fLanguageID := '   ';
      Result      := '';
      Exit;
    end;
  end;

  WSize := 0;

  if TerminatorSize = 2 then
  begin
    while (5 + WSize + 1) <= Integer(fSize) do
    begin
      if (byte(Data[5 + WSize]) = 0) and (byte(Data[5 + WSize + 1]) = 0) then
        Break;
      Inc(WSize, 2);
    end;
  end
  else
  begin
    while (5 + WSize) <= Integer(fSize) do
    begin
      if byte(Data[5 + WSize]) = 0 then
        Break;
      Inc(WSize, 1);
    end;
  end;

  CleanDesc := CustomDecodeID3Text(Encoding, Data, 5, WSize);

  NextOffset := 5 + WSize + TerminatorSize;
  if NextOffset <= Integer(fSize) then
    CleanVal := CustomDecodeID3Text(Encoding, Data, NextOffset, Integer(fSize) - NextOffset + 1)
  else
    CleanVal := '';

  if (Length(CleanDesc) > 0) and (Length(CleanVal) > 0) then
    Result := CleanDesc + #13#10 + CleanVal
  else if Length(CleanDesc) > 0 then
    Result := CleanDesc
  else
    Result := CleanVal;
end;

procedure TID3FrameComment.SetAsString(const AValue: string);
var
  UTF8_Value: utf8string;
  UTF8_Desc: utf8string;
  UTF16_Value: unicodestring;
  UTF16_Description: unicodestring;
  LangStr: ansistring;
  ValLen, DescLen, Offset: integer;
  UseV24: boolean;
begin
  UTF8_Value := AValue;
  ValLen     := Length(UTF8_Value);

  if ValLen = 0 then
  begin
    fSize := 0;
    SetLength(Data, 0);
    Exit;
  end;

  LangStr := AnsiString(Copy(fLanguageID + '   ', 1, 3));
  UseV24  := Assigned(Tagger) and (TID3Tags(Tagger).Version >= TAG_VERSION_2_4);

  if UseV24 then
  begin
    UTF8_Desc := fDescription;
    DescLen   := Length(UTF8_Desc);
    fSize     := DWord(1 + 3 + DescLen + 1 + ValLen);

    SetLength(Data, fSize);
    Data[1] := #03; // UTF-8
    Data[2] := LangStr[1];
    Data[3] := LangStr[2];
    Data[4] := LangStr[3];
    Offset  := 5;

    if DescLen > 0 then
    begin
      Move(UTF8_Desc[1], Data[Offset], DescLen);
      Inc(Offset, DescLen);
    end;

    Data[Offset] := #00;
    Inc(Offset);

    Move(UTF8_Value[1], Data[Offset], ValLen);
  end
  else
  begin
    UTF16_Value       := UTF8ToUTF16(UTF8_Value);
    UTF16_Description := UTF8ToUTF16(fDescription);
    DescLen           := Length(UTF16_Description);
    ValLen            := Length(UTF16_Value);

    fSize := DWord(1 + 3 + 2 + (DescLen * SizeOf(unicodechar)) + 2 + 2 + (ValLen * SizeOf(unicodechar)));
    SetLength(Data, fSize);

    Data[1] := #01; // UTF-16 with BOM
    Data[2] := LangStr[1];
    Data[3] := LangStr[2];
    Data[4] := LangStr[3];
    Offset  := 4;

    Data[Offset + 1] := #$FF;
    Data[Offset + 2] := #$FE;
    Inc(Offset, 2);

    if DescLen > 0 then
    begin
      Move(UTF16_Description[1], Data[Offset + 1], DescLen * SizeOf(unicodechar));
      Inc(Offset, DescLen * SizeOf(unicodechar));
    end;

    Data[Offset + 1] := #00;
    Data[Offset + 2] := #00;
    Inc(Offset, 2);

    Data[Offset + 1] := #$FF;
    Data[Offset + 2] := #$FE;
    Inc(Offset, 2);

    if ValLen > 0 then
      Move(UTF16_Value[1], Data[Offset + 1], ValLen * SizeOf(unicodechar));
  end;
end;

constructor TID3FrameComment.Create(AID: string);
begin
  inherited Create(AID);
  fDescription := '';
  fLanguageID  := '   ';
end;

{ TID3Frame }

function TID3Frame.GetAsString: string;
var
  Encoding: byte;
begin
  Result := '';
  if (Length(ID) = 0) or (fSize <= 1) or (Length(Data) < Integer(fSize)) then
    Exit;

  case ID[1] of
    'T', 'W':
      begin
        Encoding := byte(Data[1]);
        // A text frame may hold several values. A user text frame (description
        // and value, see SplitTextPair) and a link frame hold one.
        Result   := CustomDecodeID3Text(Encoding, Data, 2, Integer(fSize) - 1,
          (ID[1] = 'T') and (ID <> 'TXXX') and (ID <> 'TXX'));
      end;
  else
    Result := '<unknown>';
  end;
end;

procedure TID3Frame.SetAsString(const AValue: string);
var
  xValue: utf8string;
  wvalue, wdesc, wval: unicodestring;
  UseV24: boolean;
  SepPos, Offset: integer;
begin
  xValue := AValue;
  fSize  := Length(xValue);

  if fSize = 0 then
  begin
    SetLength(Data, 0);
    Exit;
  end;

  UseV24 := Assigned(Tagger) and (TID3Tags(Tagger).Version >= TAG_VERSION_2_4);

  if UseV24 then
  begin
    Inc(fSize, 1);
    SetLength(Data, fSize);
    Data[1] := #03; // UTF-8
    Move(xValue[1], Data[2], Length(xValue));
  end
  else
  begin
    wvalue := UTF8ToUTF16(xValue);
    SepPos := 0;
    if SameText(ID, 'TXXX') or SameText(ID, 'TXX') then
      SepPos := Pos(WideChar(#0), wvalue);

    if SepPos > 0 then
    begin
      // ID3v2.2/2.3 TXXX = Encoding, Description, $00 $00, Value,
      // where Description and Value are each a complete UTF-16 string with its own BOM.
      wdesc  := Copy(wvalue, 1, SepPos - 1);
      wval   := Copy(wvalue, SepPos + 1, MaxInt);
      fSize  := DWord(1 + 2 + Length(wdesc) * SizeOf(unicodechar) + 2 +
                      2 + Length(wval) * SizeOf(unicodechar));
      SetLength(Data, fSize);
      Data[1] := #01; // UTF-16 with BOM
      Data[2] := #$FF;
      Data[3] := #$FE;
      Offset  := 4;
      if Length(wdesc) > 0 then
      begin
        Move(wdesc[1], Data[Offset], Length(wdesc) * SizeOf(unicodechar));
        Inc(Offset, Length(wdesc) * SizeOf(unicodechar));
      end;
      Data[Offset]     := #0; // UTF-16 terminator
      Data[Offset + 1] := #0;
      Data[Offset + 2] := #$FF; // BOM for the value
      Data[Offset + 3] := #$FE;
      Inc(Offset, 4);
      if Length(wval) > 0 then
        Move(wval[1], Data[Offset], Length(wval) * SizeOf(unicodechar));
    end
    else
    begin
      fSize  := DWord(Length(wvalue) * SizeOf(unicodechar) + 3);
      SetLength(Data, fSize);
      Data[1] := #01; // UTF-16
      Data[2] := #$FF;
      Data[3] := #$FE;

      if Length(wvalue) > 0 then
        Move(wvalue[1], Data[4], Length(wvalue) * SizeOf(unicodechar));
    end;
  end;
end;

function TID3Frame.IsValid: boolean;
var
  C: char;
begin
  Result := False;
  if Length(ID) < 3 then
    Exit;

  for C in ID do
    if not (C in ['A'..'Z', '0'..'9']) then
      Exit;

  Result := True;
end;

function TID3Frame.GetSize: DWord;
begin
  Result := fSize;
end;

destructor TID3Frame.Destroy;
begin
  Self.Tagger := nil;
  SetLength(Data, 0);
  inherited Destroy;
end;

function TID3Frame.WriteToStream(AStream: TStream): DWord;
var
  Header: TID3FrameHeader;
  HeaderOld: TID3FrameHeaderOld;
  DataSize: DWord;
  headsize: DWord;
  IDStr: ansistring;
  Ver: Word;
begin
  Result := 0;
  if (fSize = 0) or (Length(Data) < Integer(fSize)) then
    Exit;

  if Assigned(Tagger) then
    Ver := TID3Tags(Tagger).Version
  else
    Ver := TAG_VERSION_2_3;

  if Ver >= TAG_VERSION_2_3 then
  begin
    IDStr     := AnsiString(Copy(ID + '    ', 1, 4));
    Move(IDStr[1], Header.ID[0], 4);
    if Ver >= TAG_VERSION_2_4 then
      Header.Size := SyncSafe_Encode(fSize)
    else
      Header.Size := NtoBE(fSize);
    Header.Flags := fFlags;
    headsize     := 10;
    AStream.WriteBuffer(Header, headsize);
  end
  else
  begin
    if fSize > MAX_ID3_V22_FRAME_SIZE then
      Exit(0);
    IDStr             := AnsiString(Copy(ID + '   ', 1, 3));
    Move(IDStr[1], HeaderOld.ID[0], 3);
    DataSize          := fSize;
    HeaderOld.Size[0] := (DataSize and $FF0000) shr 16;
    HeaderOld.Size[1] := (DataSize and $00FF00) shr 8;
    HeaderOld.Size[2] := (DataSize and $0000FF);
    headsize          := 6;
    AStream.WriteBuffer(HeaderOld, headsize);
  end;

  AStream.WriteBuffer(Data[1], fSize);
  Result := fSize + headsize;
end;

procedure TID3Frame.LoadFromImageStream(ImageStream: TMemoryStream; MIMEType: string; PictureType: Byte; IsV22: Boolean);
var
  ms: TMemoryStream;
  MimeA: AnsiString;
  B: Byte;
  MaxImgBytes: Int64;
begin
  // Silently ignore oversized images instead of raising an Exception!
  if IsV22 then
    MaxImgBytes := MAX_ID3_V22_FRAME_SIZE - 64
  else
    MaxImgBytes := MAX_ID3_FRAME_SIZE - 64;

  if (not Assigned(ImageStream)) or (ImageStream.Size <= 0) or (ImageStream.Size > MaxImgBytes) then
  begin
    fSize := 0;
    SetLength(Data, 0);
    Exit;
  end;

  ms := TMemoryStream.Create;
  try
    B := 0; // Text Encoding: 0 = ISO-8859-1 (Standard for APIC descriptions)
    ms.WriteBuffer(B, 1);

    MimeA := AnsiString(MIMEType);
    if MimeA = '' then
    begin
      if IsV22 then
        MimeA := 'JPG'
      else
        MimeA := 'image/jpeg';
    end;
    ms.WriteBuffer(MimeA[1], Length(MimeA));

    B := 0;
    ms.WriteBuffer(B, 1); // Null terminator for MIME string

    if not IsV22 then
      ms.WriteBuffer(PictureType, 1);

    B := 0;
    ms.WriteBuffer(B, 1); // Null terminator for empty Description

    // Copy the actual raw JPG/PNG bytes
    ImageStream.Position := 0;
    ms.CopyFrom(ImageStream, ImageStream.Size);

    // Push the constructed block natively into OvoTag's memory array
    fSize := ms.Size;
    SetLength(Data, fSize + 1);
    ms.Position := 0;
    if fSize > 0 then
      ms.ReadBuffer(Data[1], fSize);
  finally
    ms.Free;
  end;
end;

function TID3Frame.SplitTextPair(out ADesc, AValue: string): boolean;
var
  Enc: byte;
  I, Term, TermLen, Len: integer;
begin
  Result := False;
  ADesc  := '';
  AValue := '';
  Len    := Integer(fSize);
  if (Len < 2) or (Length(Data) < Len) then
    Exit;

  Enc := byte(Data[1]);
  case Enc of
    0, 3: TermLen := 1;
    1, 2: TermLen := 2;
  else
    Exit;
  end;

  // Find the end of the description: $00 (Latin-1 / UTF-8) or $00 $00 on a
  // character boundary (UTF-16)
  Term := 0;
  I    := 2;
  if TermLen = 1 then
  begin
    while I <= Len do
    begin
      if Data[I] = #0 then
      begin
        Term := I;
        Break;
      end;
      Inc(I);
    end;
  end
  else
  begin
    while (I + 1) <= Len do
    begin
      if (Data[I] = #0) and (Data[I + 1] = #0) then
      begin
        Term := I;
        Break;
      end;
      Inc(I, 2);
    end;
  end;
  if Term = 0 then
    Exit;

  ADesc := CustomDecodeID3Text(Enc, Data, 2, Term - 2);
  if (Term + TermLen) <= Len then
    AValue := CustomDecodeID3Text(Enc, Data, Term + TermLen, Len - (Term + TermLen) + 1);
  Result := True;
end;

function TID3Frame.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
var
  HeaderInfo: RHeaderInfo;
begin
  Result := False;
  if (not Assigned(AStream)) or (not Assigned(ExtInfo)) then
    Exit;

  HeaderInfo := RHeaderInfo(ExtInfo^);
  if (HeaderInfo.DataSize <= 0) or (HeaderInfo.DataSize > MAX_ID3_FRAME_SIZE) or
     ((AStream.Size - AStream.Position) < HeaderInfo.DataSize) then
    Exit;

  SetLength(Data, HeaderInfo.DataSize + 1);
  FillByte(Data[1], HeaderInfo.DataSize + 1, 0);
  if AStream.Read(Data[1], HeaderInfo.DataSize) < HeaderInfo.DataSize then
  begin
    SetLength(Data, 0);
    Exit;
  end;

  ID     := HeaderInfo.ID;
  fFlags := HeaderInfo.Flags;
  fSize  := DWord(HeaderInfo.DataSize);
  Result := True;
end;

end.
