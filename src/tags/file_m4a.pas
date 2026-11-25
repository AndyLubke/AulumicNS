{ ==============================================================================
  AulumicNS - file_m4a
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The tags of an MP4 / M4A file for the tag library (AulumicTag, a fork of
  OvoTag (C) 2011 Marco Caselli).

  The iTunes tag list of the file is handed out under the field names of a
  FLAC file (TITLE, ARTIST, ALBUMARTIST, TRACKNUMBER, REPLAYGAIN_TRACK_GAIN
  ...), so everything that reads or edits tags finds them where it looks.
  Free-form entries keep their own name, in capitals.

  A save keeps what was not edited: every entry of the list is remembered as
  it stands in the file, and is written back byte for byte unless the values
  of its field were changed. Entries the fields do not show (compilation
  flag, sort names, purchase data ...) are always written back. The file
  itself is rewritten by ALMp4.Mp4ReplaceTags, which checks the sound of the
  new file against the old one before the save counts as done.
  =============================================================================}
{$I ovotag.inc}
unit file_m4a;

interface

uses
  Classes, SysUtils, AudioTag, baseTag, tag_vorbis;

const
  M4aFileMask: string = '*.m4a;';

type
  // One entry of the tag list as it was read
  TM4aEntry = record
    Raw: TBytes;             // with its box header
    Name: string;            // its four characters, or its free-form name
    FreeForm: Boolean;
    Field: string;           // the field it is handed out as ('' = none)
    IsCover: Boolean;
    Values: array of string; // the values it gave to its field
  end;

  { TM4aTagReader }

  TM4aTagReader = class(TTagReader)
  private
    fTags: TVorbisTags;
    fMediaProperty: TMediaProperty;
    fDurationMs: int64;
    fEntries: array of TM4aEntry;
    fCovers: array of TBytes;
    // False: the list holds something that was not read; a save would lose it
    fListComplete: boolean;
    function FieldValues(const AField: string): TStringList;
    function CoversChanged: boolean;
  protected
    function GetDuration: int64; override;
    function GetTags: TTags; override;
    function DumpInfo: TMediaProperty; override;
  public
    function LoadFromFile(const AFileName: Tfilename): boolean; override;
    function SaveToFile(const AFileName: Tfilename): boolean; override;
    function isUpdateable: boolean; override;
  end;

// The field an entry of the iTunes tag list is handed out as ('' = none),
// and the entry a field is written as ('' = as a free-form entry)
function M4aFieldName(const AName: string): string;
function M4aEntryName(const AField: string): string;

implementation

uses
  CommonFunctions, ID3v1Genres, ALMp4;

const
  C = #$A9;                                // the first byte of most names

type
  TNamePair = record
    Entry, Field: string;
  end;

const
  NAMES: array[0..12] of TNamePair = (
    (Entry: C + 'nam'; Field: 'TITLE'),
    (Entry: C + 'ART'; Field: 'ARTIST'),
    (Entry: 'aART';    Field: 'ALBUMARTIST'),
    (Entry: C + 'alb'; Field: 'ALBUM'),
    (Entry: C + 'gen'; Field: 'GENRE'),
    (Entry: C + 'day'; Field: 'DATE'),
    (Entry: C + 'wrt'; Field: 'COMPOSER'),
    (Entry: C + 'cmt'; Field: 'COMMENT'),
    (Entry: C + 'wrk'; Field: 'WORK'),
    (Entry: C + 'grp'; Field: 'GROUPING'),
    (Entry: C + 'too'; Field: 'ENCODER'),
    (Entry: C + 'lyr'; Field: 'LYRICS'),
    (Entry: 'cprt';    Field: 'COPYRIGHT'));

function M4aFieldName(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(NAMES) do
    if NAMES[I].Entry = AName then
      Exit(NAMES[I].Field);
  if AName = 'trkn' then Result := 'TRACKNUMBER'
  else if AName = 'disk' then Result := 'DISCNUMBER'
  else if AName = 'gnre' then Result := 'GENRE'        // a genre by its number
  else Result := '';
end;

function M4aEntryName(const AField: string): string;
var
  I: Integer;
begin
  for I := 0 to High(NAMES) do
    if SameText(NAMES[I].Field, AField) then
      Exit(NAMES[I].Entry);
  if SameText(AField, 'TRACKNUMBER') then Result := 'trkn'
  else if SameText(AField, 'DISCNUMBER') then Result := 'disk'
  else Result := '';
end;

function TextOf(const AData: TBytes): string;
begin
  Result := '';
  if Length(AData) > 0 then
    SetString(Result, PAnsiChar(@AData[0]), Length(AData));
  // a value that ends in zero bytes
  while (Result <> '') and (Result[Length(Result)] = #0) do
    SetLength(Result, Length(Result) - 1);
end;

// 'trkn' and 'disk': two bytes of nothing, the number, the total
function NumberOf(const AData: TBytes): string;
var
  N, Total: Integer;
begin
  Result := '';
  if Length(AData) < 4 then
    Exit;
  N := (Integer(AData[2]) shl 8) or AData[3];
  if N <= 0 then
    Exit;
  Result := IntToStr(N);
  if Length(AData) >= 6 then
  begin
    Total := (Integer(AData[4]) shl 8) or AData[5];
    if Total > 0 then
      Result := Result + '/' + IntToStr(Total);
  end;
end;

// "3" or "3/12" as the bytes of 'trkn' (eight) or 'disk' (six); nil when it
// is no number
function NumberBytes(const AValue: string; ALength: Integer): TBytes;
var
  P, N, Total: Integer;
begin
  Result := nil;
  P := Pos('/', AValue);
  if P > 0 then
  begin
    N     := StrToIntDef(Trim(Copy(AValue, 1, P - 1)), 0);
    Total := StrToIntDef(Trim(Copy(AValue, P + 1, MaxInt)), 0);
  end
  else
  begin
    N     := StrToIntDef(Trim(AValue), 0);
    Total := 0;
  end;
  if (N <= 0) or (N > 65535) or (Total < 0) or (Total > 65535) then
    Exit;
  SetLength(Result, ALength);
  FillChar(Result[0], ALength, 0);
  Result[2] := Byte(N shr 8);
  Result[3] := Byte(N);
  Result[4] := Byte(Total shr 8);
  Result[5] := Byte(Total);
end;

// A genre stored by its number: the list of ID3v1, counted from one
function GenreOf(const AData: TBytes): string;
var
  N: Integer;
begin
  Result := '';
  if Length(AData) < 2 then
    Exit;
  N := ((Integer(AData[0]) shl 8) or AData[1]) - 1;
  if (N >= 0) and (N <= High(v1Genres)) then
    Result := v1Genres[N];
end;

procedure Append(var ADest: TBytes; const ASrc: TBytes);
var
  N: Integer;
begin
  if Length(ASrc) = 0 then
    Exit;
  N := Length(ADest);
  SetLength(ADest, N + Length(ASrc));
  Move(ASrc[0], ADest[N], Length(ASrc));
end;

{ TM4aTagReader }

function TM4aTagReader.GetDuration: int64;
begin
  Result := fDurationMs;
end;

function TM4aTagReader.GetTags: TTags;
begin
  if not Assigned(fTags) then
    fTags := TVorbisTags.Create;
  Result := fTags;
end;

function TM4aTagReader.DumpInfo: TMediaProperty;
begin
  Result := fMediaProperty;
end;

function TM4aTagReader.isUpdateable: boolean;
begin
  Result := True;
end;

function TM4aTagReader.LoadFromFile(const AFileName: Tfilename): boolean;
var
  Mp4: TMp4File;
  Items: TMp4Tags;
  I, K, Bits, Rate: Integer;
  Value: string;
  Frame: TVorbisFrame;
  Pic: TImageElement;
  Cookie: TBytes;
  Raw: TBytes;
begin
  inherited LoadFromFile(AFileName);
  Result         := False;
  fMediaProperty := Default(TMediaProperty);
  fDurationMs    := 0;
  fEntries       := nil;
  fCovers        := nil;
  fListComplete  := False;
  if Assigned(fTags) then
    FreeAndNil(fTags);
  fTags := TVorbisTags.Create;

  Mp4 := nil;
  try
    try
      Mp4 := TMp4File.Create(FileName, True, not TagReadTextOnly);
      fListComplete := Mp4.TagListComplete;

      // What the sound is: for Apple Lossless the decoder's settings name the
      // bit depth and the rate, for anything else the description of the track
      Bits := Mp4.SampleSize;
      Rate := Mp4.SampleRate;
      Cookie := Mp4.Cookie;
      if (Mp4.Codec = 'alac') and (Length(Cookie) >= 24) then
      begin
        Bits := Cookie[5];
        Rate := (Integer(Cookie[20]) shl 24) or (Integer(Cookie[21]) shl 16) or
                (Integer(Cookie[22]) shl 8) or Cookie[23];
        if Bits = 20 then
          Bits := 24;                       // played as 24 bit
      end;
      fMediaProperty.Channels    := Mp4.Channels;
      fMediaProperty.ChannelMode := DecodeChannelNumber(Mp4.Channels);
      fMediaProperty.Sampling    := Rate;
      fMediaProperty.BitDepth    := Bits;
      if Rate > 0 then
        fDurationMs := Trunc(Double(Mp4.TotalFrames) / Rate * 1000.0);

      // Every entry of the list as it stands in the file
      SetLength(fEntries, Mp4.TagBoxCount);
      for K := 0 to High(fEntries) do
      begin
        Raw := Mp4.TagBox(K);
        fEntries[K].Raw      := Raw;
        fEntries[K].Name     := Mp4.TagBoxName(K);
        fEntries[K].FreeForm := (Length(Raw) >= 8) and (Raw[4] = Ord('-')) and (Raw[5] = Ord('-')) and
                                (Raw[6] = Ord('-')) and (Raw[7] = Ord('-'));
        fEntries[K].IsCover  := (not fEntries[K].FreeForm) and (fEntries[K].Name = 'covr');
        if fEntries[K].IsCover then
          fEntries[K].Field := ''
        else if fEntries[K].FreeForm then
        begin
          // a free-form entry without a name of its own is only kept
          if fEntries[K].Name = '----' then fEntries[K].Field := ''
          else fEntries[K].Field := UpperCase(Trim(fEntries[K].Name));
        end
        else
          fEntries[K].Field := M4aFieldName(fEntries[K].Name);
      end;

      Items := Mp4.Tags;
      for I := 0 to High(Items) do
      begin
        K := Items[I].Box;
        if (K < 0) or (K > High(fEntries)) then
          Continue;

        if fEntries[K].IsCover then
        begin
          if Length(Items[I].Data) = 0 then
            Continue;
          Pic := TImageElement.Create;
          try
            if Items[I].Kind = 14 then Pic.MIMEType := 'image/png' else Pic.MIMEType := 'image/jpeg';
            Pic.PictureType := 3;           // the front cover
            Pic.Image.WriteBuffer(Items[I].Data[0], Length(Items[I].Data));
            Pic.Image.Position := 0;
          except
            Pic.Free;
            raise;
          end;
          fTags.AddImage(Pic);              // the tags own it from here on
          SetLength(fCovers, Length(fCovers) + 1);
          fCovers[High(fCovers)] := Items[I].Data;
          Continue;
        end;

        if fEntries[K].Field = '' then
          Continue;
        if (fEntries[K].Name = 'trkn') or (fEntries[K].Name = 'disk') then
          Value := NumberOf(Items[I].Data)
        else if fEntries[K].Name = 'gnre' then
          Value := GenreOf(Items[I].Data)
        else if Items[I].Kind in [0, 1] then
          Value := TextOf(Items[I].Data)
        else
          Value := '';
        if Value = '' then
          Continue;

        SetLength(fEntries[K].Values, Length(fEntries[K].Values) + 1);
        fEntries[K].Values[High(fEntries[K].Values)] := Value;
        Frame := TVorbisFrame.Create(fEntries[K].Field);
        try
          Frame.AsString := Value;
        except
          Frame.Free;
          raise;
        end;
        fTags.Add(Frame);                   // the tags own it from here on
      end;

      Result := True;
    except
      on E: Exception do
        Result := False;
    end;
  finally
    Mp4.Free;
  end;
end;

// The values the tags hold for AField now, in their order
function TM4aTagReader.FieldValues(const AField: string): TStringList;
var
  I: Integer;
  F: TFrameElement;
begin
  Result := TStringList.Create;
  try
    for I := 0 to fTags.Count - 1 do
    begin
      F := fTags.Frames[I];
      if Assigned(F) and (not (F is TImageElement)) and SameText(Trim(F.ID), AField) and (F.AsString <> '') then
        Result.Add(F.AsString);
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

// True when the pictures of the tags are not the ones that were read
function TM4aTagReader.CoversChanged: boolean;
var
  I: Integer;
  S: TStream;
  Buf: TBytes;
begin
  if fTags.ImageCount <> Length(fCovers) then
    Exit(True);
  Result := False;
  for I := 0 to High(fCovers) do
  begin
    if (fTags.Images[I] = nil) or (fTags.Images[I].Image = nil) then
      Exit(True);
    S := fTags.Images[I].Image;
    if S.Size <> Length(fCovers[I]) then
      Exit(True);
    Buf := nil;
    SetLength(Buf, S.Size);
    S.Position := 0;
    if Length(Buf) > 0 then
    begin
      S.ReadBuffer(Buf[0], Length(Buf));
      if not CompareMem(@Buf[0], @fCovers[I][0], Length(Buf)) then
        Exit(True);
    end;
    S.Position := 0;
  end;
end;

function TM4aTagReader.SaveToFile(const AFileName: Tfilename): boolean;
var
  Entries: TBytes;
  Done: TStringList;        // the fields that are written
  K, I, J: Integer;
  Now_: TStringList;
  Field, Name, Err: string;
  Same, NewCovers, CoverDone: Boolean;
  F: TFrameElement;

  // The pictures of the tags as one 'covr' entry, each picture a 'data' box
  // of its own (nil without pictures)
  function CoverEntry: TBytes;
  var
    N: Integer;
    Pic, Boxes, One: TBytes;
    PicStream: TStream;
    Kind: Integer;
  begin
    Result := nil;
    Boxes  := nil;
    for N := 0 to fTags.ImageCount - 1 do
    begin
      if fTags.Images[N] = nil then
        Continue;
      PicStream := fTags.Images[N].Image;
      if (PicStream = nil) or (PicStream.Size = 0) then
        Continue;
      Pic := nil;
      SetLength(Pic, PicStream.Size);
      PicStream.Position := 0;
      PicStream.ReadBuffer(Pic[0], Length(Pic));
      PicStream.Position := 0;
      if SameText(fTags.Images[N].MIMEType, 'image/png') then Kind := 14 else Kind := 13;
      // an entry with one value; its 'data' box lies behind the eight bytes
      // of the entry's own header
      One := Mp4DataEntry('covr', Kind, Pic);
      Append(Boxes, Copy(One, 8, Length(One) - 8));
    end;
    if Length(Boxes) = 0 then
      Exit;
    SetLength(Result, 8);
    Result[0] := Byte((Length(Boxes) + 8) shr 24);
    Result[1] := Byte((Length(Boxes) + 8) shr 16);
    Result[2] := Byte((Length(Boxes) + 8) shr 8);
    Result[3] := Byte(Length(Boxes) + 8);
    Result[4] := Ord('c');
    Result[5] := Ord('o');
    Result[6] := Ord('v');
    Result[7] := Ord('r');
    Append(Result, Boxes);
  end;
  // The values of AField as one entry; AOld: an entry of the file the field
  // came from, whose name is kept
  procedure WriteField(const AField: string; AValues: TStringList; AOld: Integer);
  var
    V: array of string;
    N: Integer;
    EntryName, FreeName: string;
    Num: TBytes;
  begin
    if AValues.Count = 0 then
      Exit;                                 // the field was emptied
    V := nil;
    SetLength(V, AValues.Count);
    for N := 0 to AValues.Count - 1 do
      V[N] := AValues[N];

    EntryName := M4aEntryName(AField);
    if (AOld >= 0) and fEntries[AOld].FreeForm then
      EntryName := '';
    if (EntryName = 'trkn') or (EntryName = 'disk') then
    begin
      if EntryName = 'trkn' then Num := NumberBytes(V[0], 8) else Num := NumberBytes(V[0], 6);
      if Num <> nil then
        Append(Entries, Mp4DataEntry(EntryName, 0, Num));
    end
    else if EntryName <> '' then
      Append(Entries, Mp4TextEntry(EntryName, V))
    else
    begin
      // free-form: the name as the file had it, else as the field is called
      // (ReplayGain fields in small letters, as other programs write them)
      if (AOld >= 0) and fEntries[AOld].FreeForm then
        FreeName := fEntries[AOld].Name
      else if Pos('REPLAYGAIN_', UpperCase(AField)) = 1 then
        FreeName := LowerCase(AField)
      else
        FreeName := AField;
      Append(Entries, Mp4FreeFormEntry(FreeName, V));
    end;
  end;

begin
  Result := False;
  // What was not read to its end is never written back
  if (not fListComplete) or FLoadFailed or (not Assigned(fTags)) then
    Exit;

  Entries := nil;
  try
  Done := TStringList.Create;
  try
    Done.CaseSensitive := False;
    NewCovers := CoversChanged;
    CoverDone := False;

    for K := 0 to High(fEntries) do
    begin
      // the pictures: as they were, or the new ones where the first one stood
      if fEntries[K].IsCover then
      begin
        if not NewCovers then
          Append(Entries, fEntries[K].Raw)
        else if not CoverDone then
        begin
          CoverDone := True;
          Append(Entries, CoverEntry);
        end;
        Continue;
      end;

      // an entry no field shows: always as it was
      Field := fEntries[K].Field;
      if Field = '' then
      begin
        Append(Entries, fEntries[K].Raw);
        Continue;
      end;
      if Done.IndexOf(Field) >= 0 then
        Continue;                           // written with the first entry of its field

      // the values the file had for this field, over all its entries
      Now_ := FieldValues(Field);
      try
        Same := True;
        J := 0;
        for I := K to High(fEntries) do
          if (not fEntries[I].IsCover) and SameText(fEntries[I].Field, Field) then
            for Name in fEntries[I].Values do
            begin
              if (J >= Now_.Count) or (Now_[J] <> Name) then
                Same := False;
              Inc(J);
            end;
        if J <> Now_.Count then
          Same := False;

        if Same then
        begin
          // not edited: every entry of the field byte for byte
          for I := K to High(fEntries) do
            if (not fEntries[I].IsCover) and SameText(fEntries[I].Field, Field) then
              Append(Entries, fEntries[I].Raw);
        end
        else
          WriteField(Field, Now_, K);
        Done.Add(Field);
      finally
        Now_.Free;
      end;
    end;

    // fields the file did not have
    for I := 0 to fTags.Count - 1 do
    begin
      F := fTags.Frames[I];
      if (not Assigned(F)) or (F is TImageElement) then
        Continue;
      Field := UpperCase(Trim(F.ID));
      if (Field = '') or (Done.IndexOf(Field) >= 0) then
        Continue;
      Now_ := FieldValues(Field);
      try
        WriteField(Field, Now_, -1);
      finally
        Now_.Free;
      end;
      Done.Add(Field);
    end;

    // pictures for a file that had none
    if NewCovers and (not CoverDone) then
      Append(Entries, CoverEntry);
  finally
    Done.Free;
  end;

  Result := Mp4ReplaceTags(FileName, AFileName, Entries, Err);
  except
    // a save answers with False, it never raises: the caller then leaves
    // the file as it is
    on E: Exception do
      Result := False;
  end;
end;

initialization
  RegisterTagReader(M4aFileMask, TM4aTagReader);
end.
