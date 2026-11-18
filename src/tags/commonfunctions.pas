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
    Bug fixes: bounds checks for year / genre / text helpers, correct byte
    swapping.
}
{$I ovotag.inc}
unit CommonFunctions;

interface

uses
  Classes, SysUtils;

const
  { Unicode ID }
  UNICODE_ID = #1;

function ExtractTrack(const TrackString: string): word;

function ExtractString(p: pbyte; size: cardinal): string; overload;
function ExtractString(Encoding: byte; p: pbyte; size: cardinal): string; overload;

function ExtractString_ANSI(p: pbyte; size: cardinal): string;
function ExtractString_UTF8(p: pbyte; size: cardinal): string;
function ExtractString_UTF16(p: pbyte; size: cardinal; Encoding: byte): string;

procedure FixTrack(const TrackString: string; const TrackNr: integer; out TrackStringFixed: string;
  out TrackNrFixed: integer); overload;

procedure FixTrack(const TrackString: widestring; const TrackNr: integer; out TrackStringFixed: widestring;
  out TrackNrFixed: integer); overload;

function Swap32(const Figure: DWORD): DWORD;
function DecodeChannelNumber(Channels: integer): string;

function GetContent(const Content1, Content2: string): string;
function ExtractYear(const YearString, DateString: string): string;
function isValidYear(const YearString: string): boolean;
function ExtractGenre(const GenreString: string; offset: integer = 0): string;
function SyncSafe_Decode(const SyncDWord: DWord): DWord;
function SyncSafe_Encode(const SyncDWord: DWord): DWord;

// Bit Operations
function GetBit(const Value: DWord; const Bit: byte): boolean; inline;
function ClearBit(const Value: DWord; const Bit: byte): DWord; inline;
function SetBit(const Value: DWord; const Bit: byte): DWord; inline;
function EnableBit(const Value: DWord; const Bit: byte; const TurnOn: boolean): DWord; inline;

implementation

uses
  ID3v1Genres, lconvencoding, lazutf8;

function DecodeChannelNumber(Channels: integer): string;
begin
  case Channels of
    0: Result := 'Unknown';
    1: Result := 'Mono';
    2: Result := 'Stereo';
  else
    Result := Format('Multi Channel (%d)', [Channels]);
  end;
end;

function SyncSafe_Encode(const SyncDWord: DWord): DWord;
var
  tmp: DWord;
begin
  tmp    := SyncDWord and $FFFFFFF;
  Result := NtoBE((tmp and $7F) or ((tmp and $3F80) shl 1) or
                  ((tmp and $1FC000) shl 2) or ((tmp and $FE00000) shl 3));
end;

function SyncSafe_Decode(const SyncDWord: DWord): DWord;
begin
  Result := ((SyncDWord and $000000FF) shl 21) xor
            ((SyncDWord and $0000FF00) shl 6) xor
            ((SyncDWord and $00FF0000) shr 9) xor
            ((SyncDWord and $FF000000) shr 24);
end;

function GetContent(const Content1, Content2: string): string;
begin
  Result := Content1;
  if Result = '' then
    Result := Content2;
end;

function ExtractYear(const YearString, DateString: string): string;
begin
  Result := YearString;
  if Result = '' then
    Result := Copy(DateString, 1, 4);
end;

// ---> AUDIT FIX: Check Length(YearString) = 4 BEFORE indexing YearString[1..4]!
function isValidYear(const YearString: string): boolean;
var
  i: Integer;
begin
  Result := False;
  if Length(YearString) <> 4 then
    Exit;

  for i := 1 to 4 do
    if not (YearString[i] in ['0'..'9']) then
      Exit;

  Result := True;
end;

// ---> AUDIT FIX: Check lower bound (>= 0) as well as upper bound (<= ID3_MaxGenreExtended)
function ExtractGenre(const GenreString: string; offset: integer = 0): string;
var
  GenreNumber, TargetIdx: integer;
  TmpString: string;
  DelimPos: SizeInt;
begin
  Result    := '';
  TmpString := GenreString;

  while TmpString.StartsWith('(') do
  begin
    if (Length(TmpString) > 1) and (TmpString[2] = '(') then
    begin
      Delete(TmpString, 1, 1);
      Result    := Result + ' ' + TmpString;
      TmpString := '';
      Break;
    end
    else
    begin
      DelimPos := Pos(')', TmpString);
      if DelimPos = 0 then
        Break;

      GenreNumber := 255;
      if TryStrToInt(Copy(TmpString, 2, DelimPos - 2), GenreNumber) then
      begin
        TargetIdx := GenreNumber + offset;
        if (TargetIdx >= 0) and (TargetIdx <= ID3_MaxGenreExtended) then
          Result := Result + ' ' + v1Genres[TargetIdx]
        else
        begin
          Result    := Result + TmpString;
          TmpString := '';
          Break;
        end;
      end
      else
      begin
        Result    := Result + TmpString;
        TmpString := '';
        Break;
      end;
      Delete(TmpString, 1, DelimPos);
    end;
  end;

  if Result = '' then
  begin
    if TryStrToInt(TmpString, GenreNumber) then
    begin
      TargetIdx := GenreNumber + offset;
      if (TargetIdx >= 0) and (TargetIdx <= ID3_MaxGenreExtended) then
        Result := Result + ' ' + v1Genres[TargetIdx]
      else
        Result := Result + ' ' + TmpString;
    end
    else
      Result := Result + ' ' + TmpString;
  end
  else
    Result := Result + ' ' + TmpString;

  Result := Trim(Result);
end;

// ---> AUDIT FIX: Use SwapEndian instead of broken shr 24/16/8 on 8-bit bytes!
function Swap32(const Figure: DWORD): DWORD;
begin
  Result := SwapEndian(Figure);
end;

procedure WideSwapEndian(PWC: pwidechar; size: integer);
begin
  while size >= SizeOf(widechar) do
  begin
    PWC^ := widechar(SwapEndian(word(PWC^)));
    Inc(PWC);
    Dec(size, SizeOf(widechar));
  end;
end;

function ExtractString(p: pbyte; size: cardinal): string;
var
  Encoding: byte;
begin
  Result := '';
  if (p <> nil) and (size > 0) then
  begin
    Encoding := p^;
    Dec(size);
    Inc(p);
    Result := ExtractString(Encoding, p, size);
  end;
end;

function ExtractString(Encoding: byte; p: pbyte; size: cardinal): string;
var
  l: cardinal;
begin
  Result := '';
  if (p = nil) or (size = 0) then
    Exit;

  case Encoding of
    0:
      Result := ExtractString_ANSI(p, size);
    1, 2:
      Result := ExtractString_UTF16(p, size, Encoding);
    3:
      Result := ExtractString_UTF8(p, size);
  end;

  l := Length(Result);
  while (l > 0) and (Result[l] = #0) do
    Dec(l);
  SetLength(Result, l);
end;

// ---> AUDIT FIX: Respect the size parameter instead of reading past the buffer with PAnsiChar!
function ExtractString_ANSI(p: pbyte; size: cardinal): string;
var
  RawS: RawByteString;
begin
  Result := '';
  if (p = nil) or (size = 0) then
    Exit;
  SetString(RawS, PAnsiChar(p), size);
  Result := ISO_8859_1ToUTF8(RawS);
end;

function ExtractString_UTF8(p: pbyte; size: cardinal): string;
begin
  Result := '';
  if (p = nil) or (size = 0) then
    Exit;
  SetString(Result, PAnsiChar(p), size);
end;

function ExtractString_UTF16(p: pbyte; size: cardinal; Encoding: byte): string;
var
  l, i: cardinal;
  be: boolean;
  ws: widestring;
begin
  ws   := '';
  size := size and $FFFFFFFE;
  l    := size;
  if (p = nil) or (l = 0) then
    Exit('');

  if pword(p)^ = $FEFF then
  begin
    be := False;
    Inc(p, 2);
    Dec(l, 2);
  end
  else if pword(p)^ = $FFFE then
  begin
    be := True;
    Inc(p, 2);
    Dec(l, 2);
  end
  else
    be := Encoding = 2;

  l := ((l + 1) div 2) * 2;
  SetLength(ws, l div 2);
  if be then
  begin
    for i := 1 to l div 2 do
    begin
      word(ws[i]) := BEtoN(pword(p)^);
      Inc(p, 2);
    end;
  end
  else if l > 1 then
    Move(p^, ws[1], l);

  Result := UTF16ToUTF8(ws);
end;

procedure FixTrack(const TrackString: string; const TrackNr: integer; out TrackStringFixed: string;
  out TrackNrFixed: integer);
begin
  TrackStringFixed := TrackString;
  TrackNrFixed     := TrackNr;

  if (TrackNrFixed = 0) and (TrackStringFixed <> '') then
    TrackNrFixed := ExtractTrack(TrackStringFixed)
  else if (TrackNrFixed <> 0) and (TrackStringFixed = '') then
    TrackStringFixed := IntToStr(TrackNrFixed);
end;

procedure FixTrack(const TrackString: widestring; const TrackNr: integer; out TrackStringFixed: widestring;
  out TrackNrFixed: integer);
begin
  TrackStringFixed := TrackString;
  TrackNrFixed     := TrackNr;

  if (TrackNrFixed = 0) and (TrackStringFixed <> '') then
    TrackNrFixed := ExtractTrack(UTF8Encode(TrackStringFixed))
  else if (TrackNrFixed <> 0) and (TrackStringFixed = '') then
    TrackStringFixed := WideString(IntToStr(TrackNrFixed));
end;

function ExtractTrack(const TrackString: string): word;
var
  Track: string;
  Index, Value, Code: integer;
begin
  Track := Trim(TrackString);
  Index := Pos('/', Track);
  if Index = 0 then
    Val(Track, Value, Code)
  else
    Val(Trim(Copy(Track, 1, Index - 1)), Value, Code);

  if (Code = 0) and (Value > 0) and (Value <= High(Word)) then
    Result := Word(Value)
  else
    Result := 0;
end;

function GetBit(const Value: DWord; const Bit: byte): boolean;
begin
  Result := (Value and (DWord(1) shl Bit)) <> 0;
end;

function ClearBit(const Value: DWord; const Bit: byte): DWord;
begin
  Result := Value and not (DWord(1) shl Bit);
end;

function SetBit(const Value: DWord; const Bit: byte): DWord;
begin
  Result := Value or (DWord(1) shl Bit);
end;

function EnableBit(const Value: DWord; const Bit: byte; const TurnOn: boolean): DWord;
begin
  Result := (Value or (DWord(1) shl Bit)) xor (DWord(integer(not TurnOn)) shl Bit);
end;

end.
