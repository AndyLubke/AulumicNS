unit ALMetadata;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:      Aulumic
  Unit Name:    ALMetadata
  Author:       André Lubke
  Date Created: 24-feb-26

  Reads metadata (using AulumicTags package) from tracks.
==============================================================================}

interface

uses
  Classes, SysUtils, AudioTag, baseTag;

type
  TAudioMetadata = record
    Title       : string;
    Artist      : string;
    AlbumArtist : string;
    Album       : string;
    Genre       : string;
    Composer    : string;
    Performer   : string;
    Comment     : string;
    TrackNumber : integer;
    DiscNumber  : integer;
    DurationStr : string;
    SampleRate  : integer;
    BitDepth    : integer;
    Channels    : integer;
    Year        : integer;
    DateStr     : string;
    IsValid     : boolean;
    // ---> AUDIT FIX: True only when the file and its tag were read without
    // error. The tag editor never saves a file whose read failed, because its
    // fields would be empty and saving would clear the real tags.
    ReadOk      : boolean;
    AllTags     : string;
    // All text frames, one per line, for display in the tag editor Inspector.
    // Only filled when ReadTrackMetadata is called with IncludeAllTags = True;
    // AllTags itself stays limited to ReplayGain / R128 (used for detection).
    AllTagsDisplay : string;
    HasCover    : boolean;
    CoverData   : TBytes;
    // ---> ADDED: Filled only by the playback I/O worker at a track change, so
    // the UI thread needs no disk access for the banner: the folder cover
    // image (only when there is no embedded cover) and whether the folder has
    // a PDF booklet. FolderInfoValid = False means: not looked up.
    FolderInfoValid : boolean;
    FolderCoverData : TBytes;
    FolderHasPDF    : boolean;
  end;

// IncludeAllTags: also fill AllTagsDisplay with every text frame (tag editor
// Inspector only; never during scans, to keep memory use low)
// KeepCommentLineBreaks: the comment keeps its line breaks (as CR LF), and
// several comment frames are separated by an empty line (tag editor only;
// scans and playback keep the one-line comment)
function ReadTrackMetadata(const FileName: string;
  ExtractPicture: boolean = True; IncludeAllTags: boolean = False;
  KeepCommentLineBreaks: boolean = False): TAudioMetadata;

// ---> ADDED: For playlist imports of tracks that are not in the library: the
// file is checked only once (by the tag reader itself) instead of twice, which
// matters for thousands of tracks on a network drive. False (AMeta not usable)
// when the file does not exist or its tags could not be read. No picture.
function TryReadTrackMetadata(const FileName: string; out AMeta: TAudioMetadata): boolean;

// ---> AulumicNS: the text fields only (title, album, ReplayGain values ...):
// embedded pictures are not even loaded (basetag.TagReadTextOnly), so
// HasCover is always False here. For the play thread, which reads the
// ReplayGain values and the album of a track before it plays.
function ReadTrackTextTags(const FileName: string): TAudioMetadata;

// One-line form of a comment, as scans store it in the library
function CompactCommentText(const S: string): string;

function ExtractTagNumber(const TagStr: string): Integer;

implementation

uses
  uAppConsts, uAppStrings, tag_id3v2,
  AuAudioTypes,   // ---> AulumicNS: LongPath (paths of 260 characters and more)
  // ---> MOVED (from uFormTagEditor): links the AulumicTag file readers (FLAC,
  // WAV, DSF, ...). Each registers itself with AudioTag in its initialization;
  // without them GetFileTagsObject silently returns TDummyReader and every
  // file reads as untagged (no title, sample rate 0) - in Aulumic, in the test
  // program and in any other program that reads metadata through this unit.
  // The compiler reports it as "not used" because no identifier from it is
  // referenced; the hint is hidden ({%H-}). Do NOT remove.
  // Guarded by Tests\TestLibraryLogic.pas (TTestTagReaders).
  {%H-}RegisterAllReader;

const
  MAX_STANDARD_TAG_LEN = 1024;
  MAX_COMMENT_TAG_LEN  = 4096;
  MAX_FRAME_RAW_LEN    = 16384; // Hard ceiling against corrupt multi-MB text frames

function ClearMetaData: TAudioMetaData;
begin
  Result             := Default(TAudioMetaData);
  Result.DurationStr := LBL_NO_DURATION;
end;

// =============================================================================
// ---> AUDIT FIX 2.2: Helper to step back over any incomplete trailing UTF-8
// multi-byte sequence when a string is truncated at a fixed byte limit.
// =============================================================================
procedure TrimIncompleteTrailingUTF8(const S: string; var Len: Integer);
var
  LeadIdx, SeqLen, ExpectedLen: Integer;
  B: Byte;
begin
  if (Len <= 0) or (Len > Length(S)) then
    Exit;

  // Fast path: 7-bit ASCII byte is always a complete character
  if (Byte(S[Len]) and $80) = 0 then
    Exit;

  // Walk backwards over UTF-8 continuation bytes (10xxxxxx = $80..$BF)
  LeadIdx := Len;
  while (LeadIdx > 1) and ((Byte(S[LeadIdx]) and $C0) = $80) and ((Len - LeadIdx) < 4) do
    Dec(LeadIdx);

  B := Byte(S[LeadIdx]);
  if (B and $E0) = $C0 then
    ExpectedLen := 2
  else if (B and $F0) = $E0 then
    ExpectedLen := 3
  else if (B and $F8) = $F0 then
    ExpectedLen := 4
  else
  begin
    // Orphan continuation or invalid byte: strip back before it
    Len := LeadIdx - 1;
    Exit;
  end;

  SeqLen := Len - LeadIdx + 1;
  if SeqLen < ExpectedLen then
    Len := LeadIdx - 1;
end;

// =============================================================================
// Single-pass in-place string sanitizer & semicolon compactor.
// Replaces the multi-pass "while Pos(';;') > 0 do StringReplace" loop, strips
// embedded binary/control characters (#0..#31), and enforces a safe length cap!
// =============================================================================
function SanitizeAndCompactTag(const RawStr: string; MaxLen: Integer = MAX_STANDARD_TAG_LEN): string;
var
  I, WriteIdx, Limit: Integer;
  C: Char;
  LastWasSemi, LastWasSpace: Boolean;
begin
  if RawStr = '' then
    Exit('');

  Limit := Length(RawStr);
  if Limit > MaxLen then
    Limit := MaxLen;

  SetLength(Result, Limit);
  WriteIdx     := 0;
  LastWasSemi  := True; // Prevents leading semicolons
  LastWasSpace := True; // Prevents leading spaces

  for I := 1 to Limit do
  begin
    C := RawStr[I];

    if C = #0 then
    begin
      // ID3v2 multi-value separator: collapse consecutive #0/; into a single ';'
      if not LastWasSemi then
      begin
        if LastWasSpace and (WriteIdx > 0) then
          Dec(WriteIdx);
        Inc(WriteIdx);
        Result[WriteIdx] := ';';
        LastWasSemi      := True;
        LastWasSpace     := False;
      end;
    end
    else if C in [#9, #10, #13, ' '] then
    begin
      if (not LastWasSpace) and (not LastWasSemi) then
      begin
        Inc(WriteIdx);
        Result[WriteIdx] := ' ';
        LastWasSpace     := True;
      end;
    end
    else if C = ';' then
    begin
      if not LastWasSemi then
      begin
        if LastWasSpace and (WriteIdx > 0) then
          Dec(WriteIdx);
        Inc(WriteIdx);
        Result[WriteIdx] := ';';
        LastWasSemi      := True;
        LastWasSpace     := False;
      end;
    end
    else if Ord(C) >= 32 then
    begin
      Inc(WriteIdx);
      Result[WriteIdx] := C;
      LastWasSemi      := False;
      LastWasSpace     := False;
    end;
    // All other control/binary bytes (#1..#8, #11..#12, #14..#31) are skipped
  end;

  // ---> AUDIT FIX 2.2: Ensure truncation at Limit never leaves half a UTF-8 char
  if Length(RawStr) > MaxLen then
    TrimIncompleteTrailingUTF8(Result, WriteIdx);

  // Trim any trailing spaces or semicolons in-place without reallocating
  while (WriteIdx > 0) and (Result[WriteIdx] in [' ', ';']) do
    Dec(WriteIdx);

  SetLength(Result, WriteIdx);
end;

procedure AppendTag(var Target: string; const Value: string; MaxTotalLen: Integer = MAX_STANDARD_TAG_LEN;
  const Separator: string = '; ');
var
  NewLen: Integer;
begin
  if Value = '' then
    Exit;
  if Length(Target) >= MaxTotalLen then
    Exit;

  if Target = '' then
    Target := Value
  else
    Target := Target + Separator + Value;

  if Length(Target) > MaxTotalLen then
  begin
    NewLen := MaxTotalLen;
    // ---> AUDIT FIX 2.2: Keep UTF-8 boundary intact when capping combined length
    TrimIncompleteTrailingUTF8(Target, NewLen);
    SetLength(Target, NewLen);
  end;
end;

// ---> AUDIT FIX: Comment cleanup for the tag editor. Like
// SanitizeAndCompactTag (control bytes removed, #0 separators become '; ',
// capped at MaxLen without splitting a UTF-8 character), but line breaks are
// kept and normalized to CR LF, and spacing inside the text is not changed.
function SanitizeCommentKeepLines(const RawStr: string; MaxLen: Integer): string;
var
  I, Limit, W: Integer;
  C: Char;
begin
  Result := '';
  if RawStr = '' then
    Exit;

  Limit := Length(RawStr);
  if Limit > MaxLen then
    Limit := MaxLen;

  // A lone CR or LF becomes CR LF, so the result is at most twice as long
  SetLength(Result, Limit * 2);
  W := 0;
  I := 1;
  while I <= Limit do
  begin
    C := RawStr[I];
    if (C = #13) or (C = #10) then
    begin
      Inc(W); Result[W] := #13;
      Inc(W); Result[W] := #10;
      if (C = #13) and (I < Limit) and (RawStr[I + 1] = #10) then
        Inc(I);
    end
    else if C = #9 then
    begin
      Inc(W); Result[W] := ' ';
    end
    else if C = #0 then
    begin
      // ID3v2 multi-value separator
      if (W > 0) and (Result[W] <> ' ') and (Result[W] <> ';') then
      begin
        Inc(W); Result[W] := ';';
        Inc(W); Result[W] := ' ';
      end;
    end
    else if Ord(C) >= 32 then
    begin
      Inc(W); Result[W] := C;
    end;
    // Other control bytes (#1..#8, #11, #12, #14..#31) are skipped
    Inc(I);
  end;

  if Length(RawStr) > MaxLen then
    TrimIncompleteTrailingUTF8(Result, W);
  SetLength(Result, W);

  Result := Trim(Result);
  while (Result <> '') and (Result[Length(Result)] = ';') do
    Result := TrimRight(Copy(Result, 1, Length(Result) - 1));
end;

function CompactCommentText(const S: string): string;
begin
  Result := SanitizeAndCompactTag(S, MAX_COMMENT_TAG_LEN);
end;

function ExtractTagNumber(const TagStr: string): Integer;
var
  CleanStr : string;
  SlashPos : Integer;
begin
  CleanStr := Trim(TagStr);
  if CleanStr = '' then
    Exit(0);

  SlashPos := Pos('/', CleanStr);
  if SlashPos > 0 then
    CleanStr := Trim(Copy(CleanStr, 1, SlashPos - 1));

  Result := StrToIntDef(CleanStr, 0);
  if Result < 0 then
    Result := 0;
end;

function IsBinaryOrImageFrameID(const UpperID: string): Boolean; inline;
begin
  // Never call Frame.AsString on binary or embedded picture frames!
  Result :=
    (UpperID = 'APIC') or
    (UpperID = 'PIC') or
    (UpperID = 'GEOB') or
    (UpperID = 'PRIV') or
    (UpperID = 'MCDI') or
    (UpperID = 'SYLT') or
    (UpperID = 'USLT') or
    (UpperID = 'AENC') or
    (UpperID = 'ENCR') or
    (UpperID = 'GRID') or
    (UpperID = 'POPM') or
    (UpperID = 'PCNT') or
    (UpperID = 'UFID') or
    (UpperID = 'METADATA_BLOCK_PICTURE') or
    (UpperID = 'COVERART') or
    (UpperID = 'UNSYNCEDLYRICS') or
    (UpperID = 'LYRICS');
end;

function ReadMetadataInternal(const FileName: string; ExtractPicture,
  IncludeAllTags, KeepCommentLineBreaks, ACheckExists: boolean;
  ATextOnly: boolean = False): TAudioMetadata; forward;

function ReadTrackMetadata(const FileName: string; ExtractPicture: boolean = True;
  IncludeAllTags: boolean = False; KeepCommentLineBreaks: boolean = False): TAudioMetadata;
begin
  Result := ReadMetadataInternal(FileName, ExtractPicture, IncludeAllTags,
    KeepCommentLineBreaks, True);
end;

function ReadTrackTextTags(const FileName: string): TAudioMetadata;
begin
  Result := ReadMetadataInternal(FileName, False, False, False, True, True);
end;

function TryReadTrackMetadata(const FileName: string; out AMeta: TAudioMetadata): boolean;
begin
  // No FileExists here: TTagReader.Create checks the file itself and sets
  // LoadFailed (ReadOk = False) when it is missing or unreadable
  AMeta  := ReadMetadataInternal(FileName, False, False, False, False);
  Result := AMeta.ReadOk;
end;

function ReadMetadataInternal(const FileName: string; ExtractPicture,
  IncludeAllTags, KeepCommentLineBreaks, ACheckExists: boolean;
  ATextOnly: boolean = False): TAudioMetadata;
var
  TagReader  : TTagReader;
  CommonTags : TCommonTags;
  MediaProps : TMediaProperty;
  I, MaxTags : Integer;
  Secs       : Int64;
  Frame      : TFrameElement;
  ImgStream  : TStream;
  CleanStr   : string;
  UpperID    : string;
  UpperClean : string;
  PairDesc   : string;
  PairValue  : string;
begin
  Result := ClearMetaData;

  if ACheckExists and (not FileExists(LongPath(FileName))) then
    Exit;

  try
    TagReader := nil;
    try
      // ---> AulumicNS: ATextOnly: the pictures are not loaded at all
      TagReader := GetFileTagsObject(FileName, ATextOnly);
      if not Assigned(TagReader) then
        Exit;

      // OvoTag loads embedded pictures into TagReader.Tags.Images
      // even when ExtractPicture = False! Extract or purge those multi-megabyte
      // streams FIRST before allocating any Result strings on top of them!
      if Assigned(TagReader.Tags) and (TagReader.Tags.ImageCount > 0) then
      begin
        if Assigned(TagReader.Tags.Images[0]) and Assigned(TagReader.Tags.Images[0].Image) then
        begin
          // ---> AUDIT FIX 3.3: Use base TStream rather than unchecked TMemoryStream cast
          ImgStream := TagReader.Tags.Images[0].Image;
          if (ImgStream.Size > 0) and (ImgStream.Size <= 15728640) then
          begin
            Result.HasCover := True;
            if ExtractPicture then
            begin
              SetLength(Result.CoverData, ImgStream.Size);
              ImgStream.Position := 0;
              ImgStream.ReadBuffer(Result.CoverData[0], ImgStream.Size);
            end;
          end;
        end;

        // Purge all internal TImageElement streams immediately so they drop off
        // the top of the heap before Result strings are allocated!
        for I := 0 to TagReader.Tags.ImageCount - 1 do
        begin
          if Assigned(TagReader.Tags.Images[I]) and Assigned(TagReader.Tags.Images[I].Image) then
          begin
            // ---> AUDIT FIX 3.3: Safe class check before calling TMemoryStream.Clear
            if TagReader.Tags.Images[I].Image is TMemoryStream then
              TMemoryStream(TagReader.Tags.Images[I].Image).Clear
            else
              TagReader.Tags.Images[I].Image.Size := 0;
          end;
        end;
      end;

      CommonTags := TagReader.GetCommonTags;
      MediaProps := TagReader.MediaProperty;

      // Sanitize and cap CommonTags so corrupt/null-padded tags
      // can never inject megabytes of hidden #0 bytes into Title or Album!
      Result.Title       := SanitizeAndCompactTag(CommonTags.Title, 512);
      Result.Album       := SanitizeAndCompactTag(CommonTags.Album, 512);
      Result.TrackNumber := CommonTags.Track;
      Result.SampleRate  := MediaProps.Sampling;
      Result.BitDepth    := MediaProps.BitDepth;
      Result.Channels    := MediaProps.Channels;

      Result.DateStr := SanitizeAndCompactTag(CommonTags.Year, 32);
      if Length(Result.DateStr) >= 4 then
        Result.Year := StrToIntDef(Copy(Result.DateStr, 1, 4), 0)
      else
        Result.Year := StrToIntDef(Result.DateStr, 0);

      // ---> AUDIT FIX 1.1: Compute duration in 64-bit Int64 and clamp to a
      // sane ceiling (99 hours = 359,999 seconds) to prevent 32-bit wrap-around!
      if CommonTags.Duration > 0 then
      begin
        Secs := CommonTags.Duration div 1000;
        if Secs < 0 then
          Secs := 0
        else if Secs > 359999 then
          Secs := 359999;
        Result.DurationStr := Format('%d:%.2d', [Secs div 60, Secs mod 60]);
      end;

      Result.IsValid := (Result.Title <> '') or (Trim(CommonTags.Artist) <> '');
      if Result.Title = '' then
        Result.Title := ChangeFileExt(ExtractFileName(FileName), '');

      if Assigned(TagReader.Tags) then
      begin
        MaxTags := TagReader.Tags.Count;
        if MaxTags > 250 then
          MaxTags := 250;

        for I := 0 to MaxTags - 1 do
        begin
          Frame := TagReader.Tags.Frames[I];
          if (not Assigned(Frame)) or (Frame is TImageElement) then
            Continue;

          // ---> AUDIT FIX 3.1: Skip oversized text frames BEFORE calling
          // Frame.AsString so multi-megabyte corrupt frames are never decoded!
          if Frame.Size > MAX_FRAME_RAW_LEN then
            Continue;

          UpperID := UpperCase(Trim(Frame.ID));
          if IsBinaryOrImageFrameID(UpperID) then
            Continue;

          // Cap raw frame extraction to MAX_FRAME_RAW_LEN so corrupt frames never blow up RAM
          CleanStr := SanitizeAndCompactTag(Frame.AsString, MAX_FRAME_RAW_LEN);
          if CleanStr = '' then
            Continue;

          // ---> Tag editor Inspector only: every text frame, with custom
          // TXXX / TXX frames shown as 'description = value'
          if IncludeAllTags then
          begin
            if ((UpperID = 'TXXX') or (UpperID = 'TXX')) and (Frame is TID3Frame) and
               TID3Frame(Frame).SplitTextPair(PairDesc, PairValue) then
              Result.AllTagsDisplay := Result.AllTagsDisplay + UpperID + ': ' +
                SanitizeAndCompactTag(PairDesc, 512) + ' = ' +
                SanitizeAndCompactTag(PairValue, MAX_FRAME_RAW_LEN) + #13#10
            else
              Result.AllTagsDisplay := Result.AllTagsDisplay + UpperID + ': ' + CleanStr + #13#10;
          end;

          // Only append ReplayGain / R128 frames to AllTags!
          if (Pos(TAG_RG_PREFIX, UpperID) > 0) or (Pos(TAG_R128_PREFIX, UpperID) > 0) or
             (UpperID = 'TXXX') or (UpperID = 'COMMENT') or (UpperID = 'COMM') then
          begin
            UpperClean := UpperCase(CleanStr);
            if (Pos(TAG_RG_PREFIX, UpperID) > 0) or (Pos(TAG_R128_PREFIX, UpperID) > 0) or
               (Pos(TAG_RG_PREFIX, UpperClean) > 0) or (Pos(TAG_R128_PREFIX, UpperClean) > 0) then
            begin
              Result.AllTags := Result.AllTags + UpperID + ': ' + CleanStr + #13#10;
            end;
          end;

          case UpperID of
            // ---> AUDIT FIX: ID3v2.2 frame IDs (TCO, TP1, TP2, TCM, TP3, COM, TPA,
            // TRK) are read as well; the tag editor writes them for v2.2 tags.
            'GENRE', 'TCON', 'TCO':
              AppendTag(Result.Genre, SanitizeAndCompactTag(CleanStr, 512), 1024);
            'ARTIST', 'TPE1', 'TP1':
              AppendTag(Result.Artist, SanitizeAndCompactTag(CleanStr, 512), 1024);
            'ALBUMARTIST', 'TPE2', 'TP2':
              AppendTag(Result.AlbumArtist, SanitizeAndCompactTag(CleanStr, 512), 1024);
            'COMPOSER', 'TCOM', 'TCM':
              AppendTag(Result.Composer, SanitizeAndCompactTag(CleanStr, 512), 1024);
            'PERFORMER', 'TPE3', 'TP3':
              AppendTag(Result.Performer, SanitizeAndCompactTag(CleanStr, 512), 1024);
            'COMMENT', 'COMM', 'COM':
              begin
                // Ignore ID3v2 iTunNORM / ReplayGain hex dumps inside standard comments
                if Pos('ITUNNORM', UpperCase(CleanStr)) = 0 then
                begin
                  if KeepCommentLineBreaks then
                    AppendTag(Result.Comment,
                      SanitizeCommentKeepLines(Frame.AsString, MAX_COMMENT_TAG_LEN),
                      MAX_COMMENT_TAG_LEN, #13#10#13#10)
                  else
                    AppendTag(Result.Comment, SanitizeAndCompactTag(CleanStr, MAX_COMMENT_TAG_LEN), MAX_COMMENT_TAG_LEN);
                end;
              end;
            'TPOS', 'TPA', 'DISCNUMBER':
              Result.DiscNumber := ExtractTagNumber(CleanStr);
            'TRCK', 'TRK', 'TRACKNUMBER', 'TRACK':
              Result.TrackNumber := ExtractTagNumber(CleanStr);
          end;
        end;

        if Result.Genre = '' then
          Result.Genre := SanitizeAndCompactTag(CommonTags.Genre, 512);
        if Result.Artist = '' then
          Result.Artist := SanitizeAndCompactTag(CommonTags.Artist, 512);
        //if Result.AlbumArtist = '' then
        //  Result.AlbumArtist := SanitizeAndCompactTag(CommonTags.AlbumArtist, 512);
        if Result.Comment = '' then
        begin
          if not KeepCommentLineBreaks then
            Result.Comment := SanitizeAndCompactTag(CommonTags.Comment, MAX_COMMENT_TAG_LEN)
          // ---> AUDIT FIX: Tag editor: for ID3 the loop above already read every
          // comment it shows; the common-tags comment would only add the iTunNORM
          // frames that the editor never writes or removes. For FLAC this is the
          // DESCRIPTION field (shown when there is no COMMENT).
          else if not (TagReader.Tags is TID3Tags) then
            Result.Comment := SanitizeCommentKeepLines(CommonTags.Comment, MAX_COMMENT_TAG_LEN);
        end;
      end;

      Result.ReadOk := not TagReader.LoadFailed;

      // Clear temporary CommonTags strings before TagReader.Free
      CommonTags := Default(TCommonTags);
    finally
      if Assigned(TagReader) then
        TagReader.Free;
    end;
  except
    Result := ClearMetaData;
  end;
end;

end.
