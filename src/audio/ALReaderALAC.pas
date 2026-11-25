unit ALReaderALAC;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALReaderALAC
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Used by ALReaders to read Apple Lossless files (.m4a): the packets from the
  MP4 container (ALMp4), decoded by ALDecAlac.
  The samples come out as the engine takes them from every PCM reader:
  interleaved, little-endian, 16, 24 or 32 bit signed (20 bit as 24).

  An .m4a file may hold AAC instead: that is refused with its own message.
  The channels of a file with more than two come in the order the format
  stores them (the centre first); Roles says what each one is.
  The file name is UTF-8.
==============================================================================}

interface

uses
  SysUtils, Classes, ALAudioTypes, ALMp4, ALDecAlac;

type
  TAlacReader = class
  private
    FFile: TStream;
    FMp4: TMp4File;
    FDecoder: TAlacDecoder;
    FSampleRate: cardinal;
    FChannels: word;
    FBitsPerSample: word;    // of the output
    FOutBytes: integer;
    FUpShift: integer;       // 20 bit is put into 24
    FTotalFrames: int64;
    FFramesRead: int64;
    FPacket: integer;        // the packet to decode next
    FPacketBuf: array of byte;
    FChans: array of TAlacChannel;
    FHave: integer;          // decoded samples per channel waiting in FChans
    FHavePos: integer;       // the first of them not handed out yet
    FSkip: integer;          // samples to drop after a seek
    function DecodeNext: boolean;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;

    function ReadData(Buffer: Pointer; Count: integer): integer;
    function GetProgress: double;
    procedure Seek(Percent: double);
    // What each channel is (nil for one or two channels)
    function Roles: TChannelRoles;
    function DataSize: int64;

    property SampleRate: cardinal read FSampleRate;
    property Channels: word read FChannels;
    property BitsPerSample: word read FBitsPerSample;
  end;

// The channel layouts of Apple Lossless by channel count
function AlacChannelRoles(AChannels: integer): TChannelRoles;

implementation

uses
  Math, uAppStrings,
  AuAudioTypes;  // LongPath (paths of 260 characters and more)

function AlacChannelRoles(AChannels: integer): TChannelRoles;
const
  // the centre comes first, the LFE last
  L3: array[0..2] of TChannelRole = (chCentre, chLeft, chRight);
  L4: array[0..3] of TChannelRole = (chCentre, chLeft, chRight, chRear);
  L5: array[0..4] of TChannelRole = (chCentre, chLeft, chRight, chSurroundLeft, chSurroundRight);
  L6: array[0..5] of TChannelRole = (chCentre, chLeft, chRight, chSurroundLeft, chSurroundRight, chLfe);
  L7: array[0..6] of TChannelRole = (chCentre, chLeft, chRight, chSurroundLeft, chSurroundRight, chRear, chLfe);
  // 7.1: centre, the two between centre and front, the fronts, the surrounds
  L8: array[0..7] of TChannelRole = (chCentre, chSurroundLeft, chSurroundRight, chLeft, chRight,
                                    chSurroundLeft, chSurroundRight, chLfe);

  function Copied(const A: array of TChannelRole): TChannelRoles;
  var
    I: integer;
  begin
    Result := nil;
    SetLength(Result, Length(A));
    for I := 0 to High(A) do
      Result[I] := A[I];
  end;

begin
  case AChannels of
    3: Result := Copied(L3);
    4: Result := Copied(L4);
    5: Result := Copied(L5);
    6: Result := Copied(L6);
    7: Result := Copied(L7);
    8: Result := Copied(L8);
  else
    Result := nil;
  end;
end;

constructor TAlacReader.Create(const FileName: string);
var
  I: integer;
begin
  inherited Create;
  if not AuFileExists(FileName) then
    raise Exception.Create(ERR_FILE_NOT_FOUND + ' ' + FileName);

  try
    FMp4 := TMp4File.Create(FileName);
  except
    on E: EMp4Error do
      raise Exception.Create(ERR_DECODE_M4A_INVALID + ' (' + E.Message + ')');
  end;
  if FMp4.Codec = 'mp4a' then
    raise Exception.Create(ERR_DECODE_M4A_AAC);
  if FMp4.Codec <> 'alac' then
    raise Exception.Create(ERR_DECODE_M4A_OTHER);
  if FMp4.PacketCount = 0 then
    raise Exception.Create(ERR_DECODE_M4A_INVALID);

  try
    FDecoder := TAlacDecoder.Create(FMp4.Cookie);
  except
    on E: EAlacError do
      raise Exception.Create(ERR_DECODE_M4A_INVALID + ' (' + E.Message + ')');
  end;

  FSampleRate := FDecoder.SampleRate;
  FChannels   := FDecoder.Channels;
  case FDecoder.BitDepth of
    16: FOutBytes := 2;
    20: begin FOutBytes := 3; FUpShift := 4; end;
    24: FOutBytes := 3;
  else
    FOutBytes := 4;
  end;
  FBitsPerSample := FOutBytes * 8;

  // The length of the track: from its table of durations, at most what its
  // packets can hold
  FTotalFrames := FMp4.TotalFrames;
  if (FTotalFrames <= 0) or (FTotalFrames > Int64(FMp4.PacketCount) * FDecoder.FrameLength) then
    FTotalFrames := Int64(FMp4.PacketCount) * FDecoder.FrameLength;

  SetLength(FChans, FChannels);
  for I := 0 to FChannels - 1 do
    SetLength(FChans[I], FDecoder.FrameLength);

  FFile := AuOpenFile(FileName, fmOpenRead or fmShareDenyWrite);
end;

destructor TAlacReader.Destroy;
begin
  FFile.Free;
  FDecoder.Free;
  FMp4.Free;
  inherited;
end;

function TAlacReader.DataSize: int64;
begin
  Result := FTotalFrames * FOutBytes * FChannels;
end;

function TAlacReader.Roles: TChannelRoles;
begin
  Result := AlacChannelRoles(FChannels);
end;

// The next packet into FChans. False at the end of the file, or when a
// packet cannot be read or decoded (the track ends there).
function TAlacReader.DecodeNext: boolean;
var
  Size: cardinal;
  Offset: int64;
begin
  Result   := False;
  FHave    := 0;
  FHavePos := 0;
  if FPacket >= FMp4.PacketCount then
    Exit;
  Size   := FMp4.PacketSize(FPacket);
  Offset := FMp4.PacketOffset(FPacket);
  Inc(FPacket);
  if (Size = 0) or (Offset < 0) then
    Exit;
  if cardinal(Length(FPacketBuf)) < Size then
    SetLength(FPacketBuf, Size);
  FFile.Position := Offset;
  if FFile.Read(FPacketBuf[0], Size) < integer(Size) then
    Exit;
  try
    FHave := FDecoder.Decode(@FPacketBuf[0], Size, FChans);
  except
    on E: EAlacError do
    begin
      FHave := 0;
      Exit;
    end;
  end;
  Result := FHave > 0;
end;

function TAlacReader.ReadData(Buffer: Pointer; Count: integer): integer;
var
  OutFrame, FramesWanted, N, I, C, V: integer;
  POut: pbyte;
begin
  Result   := 0;
  OutFrame := FOutBytes * FChannels;
  if (Count <= 0) or (OutFrame <= 0) then
    Exit;
  FramesWanted := Count div OutFrame;
  if FFramesRead + FramesWanted > FTotalFrames then
    FramesWanted := FTotalFrames - FFramesRead;
  POut := pbyte(Buffer);

  while FramesWanted > 0 do
  begin
    if FHavePos >= FHave then
      if not DecodeNext then
        Break;

    // after a seek: the samples of the packet before the target
    if FSkip > 0 then
    begin
      N := Min(FSkip, FHave - FHavePos);
      Inc(FHavePos, N);
      Dec(FSkip, N);
      Continue;
    end;

    N := Min(FramesWanted, FHave - FHavePos);
    for I := FHavePos to FHavePos + N - 1 do
      for C := 0 to FChannels - 1 do
      begin
        V := FChans[C][I] shl FUpShift;
        case FOutBytes of
          2: begin
               POut[0] := byte(V);
               POut[1] := byte(V shr 8);
             end;
          3: begin
               POut[0] := byte(V);
               POut[1] := byte(V shr 8);
               POut[2] := byte(V shr 16);
             end;
        else
          PInteger(POut)^ := V;
        end;
        Inc(POut, FOutBytes);
      end;
    Inc(FHavePos, N);
    Inc(FFramesRead, N);
    Dec(FramesWanted, N);
    Inc(Result, N * OutFrame);
  end;
end;

procedure TAlacReader.Seek(Percent: double);
var
  Target: int64;
begin
  Target := Round(EnsureRange(Percent, 0.0, 1.0) * FTotalFrames);
  if Target > FTotalFrames then
    Target := FTotalFrames;
  if Target < 0 then
    Target := 0;
  // every packet stands for itself: start at the one that holds the target
  FPacket     := Target div FDecoder.FrameLength;
  FSkip       := Target mod FDecoder.FrameLength;
  FHave       := 0;
  FHavePos    := 0;
  FFramesRead := Target;
end;

function TAlacReader.GetProgress: double;
begin
  if FTotalFrames <= 0 then
    Result := 0.0
  else
    Result := double(FFramesRead) / double(FTotalFrames);
  if Result > 1.0 then
    Result := 1.0;
end;

end.
