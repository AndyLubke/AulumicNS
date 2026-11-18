unit ALReaderDFF;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALReaderDFF
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Reads DSDIFF (.dff) files for the DSD path of the engine.
  TDsfReader hands a DFF file to this reader, so the rest of the engine
  (TDsfSource, DoP, DSD to PCM, gapless) treats both formats the same.

  The output is exactly what TDsfReader produces: stereo DoP frames of 24 bit
  (6 bytes): [second DSD byte] [first DSD byte] [marker $05 / $FA], left then
  right, the DSD bits MSB first (DFF stores them MSB first, so - unlike DSF -
  no bit reversal). Mono files are sent as dual mono; files with more than
  two channels report their channel count (the source factory refuses them).
  The DFF container is parsed by AuDecDsd.TAuDffDecoder (DST compressed files
  are refused there).
==============================================================================}

interface

uses
  SysUtils, Classes, Math, AuAudioTypes, AuDecoder, AuDecDsd;

type
  { TDffReader }

  TDffReader = class
  private
    FDec: TAuDffDecoder;
    FFileChannels: word;
    FChannelCount: word;
    FSampleRate: cardinal;          // DoP carrier rate (DSD rate / 16)
    FValidBytesPerChan: int64;
    FValidAudioBytes: int64;        // 2 * bytes per channel (as TDsfReader)
    FBytesRead: int64;
    FMarker: byte;
    FRaw: array of byte;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    function ReadData(Buffer: Pointer; BytesToRead: integer): integer;
    function GetProgress: double;
    procedure Seek(Percent: double);
    function GetDoPMarker: byte;
    procedure SetDoPMarker(Value: byte);
    property SampleRate: cardinal read FSampleRate;
    property Channels: word read FChannelCount;
    property DataSize: int64 read FValidAudioBytes;
  end;

{ True when the file starts like a DSDIFF file ('FRM8') }
function IsDffFile(const FileName: string): Boolean;

implementation

uses uAppStrings;

const
  DSD_SILENCE = $69;

function IsDffFile(const FileName: string): Boolean;
var
  F: TFileStream;
  Sig: array[0..3] of AnsiChar;
begin
  Result := False;
  try
    F := TFileStream.Create(LongPath(FileName), fmOpenRead or fmShareDenyNone);
    try
      if F.Read(Sig, 4) = 4 then Result := Sig = 'FRM8';
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

constructor TDffReader.Create(const FileName: string);
begin
  inherited Create;
  FDec := TAuDffDecoder.Create;
  try
    FDec.Open(FileName);
  except
    on E: EAuAudio do
    begin
      FreeAndNil(FDec);
      if E.Kind = aekUnsupported then raise Exception.Create(ERR_DECODE_DSDHEADER + ' (' + E.Message + ')')
      else raise Exception.Create(ERR_DECODE_NOTDSD);
    end;
    on E: Exception do
    begin
      FreeAndNil(FDec);
      raise;
    end;
  end;
  if ((FDec.Info.SampleRate mod 2822400) <> 0) and ((FDec.Info.SampleRate mod 3072000) <> 0) then
  begin
    FreeAndNil(FDec);
    raise Exception.Create(ERR_DECODE_DSDHEADER);
  end;
  FFileChannels := word(FDec.Info.Channels);
  if FFileChannels = 1 then FChannelCount := 2 else FChannelCount := FFileChannels;
  FSampleRate := FDec.Info.SampleRate div 16;
  FValidBytesPerChan := FDec.Info.TotalFrames;
  FValidAudioBytes := FValidBytesPerChan * 2;
  FMarker := $05;
  FBytesRead := 0;
  SetLength(FRaw, 8192 * Integer(FFileChannels));
end;

destructor TDffReader.Destroy;
begin
  FDec.Free;
  inherited Destroy;
end;

function TDffReader.ReadData(Buffer: Pointer; BytesToRead: integer): integer;
var
  POut: PByte;
  Frames, Want, Got, I, C, Ch, RC: Integer;
  Marker: byte;
  L0, L1, R0, R1: byte;
begin
  Result := 0;
  if FDec = nil then Exit;
  POut := PByte(Buffer);
  Marker := FMarker;
  Ch := FFileChannels;
  if Ch >= 2 then RC := 1 else RC := 0;   // the right channel (mono: the left one)
  while Result + 6 <= BytesToRead do
  begin
    if FBytesRead >= FValidAudioBytes then Break;
    Frames := (BytesToRead - Result) div 6;              // DoP frames wanted
    if Frames > Length(FRaw) div (2 * Ch) then Frames := Length(FRaw) div (2 * Ch);
    Want := Frames * 2;                                  // DSD bytes per channel
    Got := FDec.ReadDsd(@FRaw[0], Want);
    if Got <= 0 then Break;
    if Odd(Got) then
    begin
      { the last odd byte: completed with DSD silence }
      for C := 0 to Ch - 1 do FRaw[Got * Ch + C] := DSD_SILENCE;
      Inc(Got);
    end;
    Frames := Got div 2;
    for I := 0 to Frames - 1 do
    begin
      L0 := FRaw[(2 * I) * Ch];
      L1 := FRaw[(2 * I + 1) * Ch];
      R0 := FRaw[(2 * I) * Ch + RC];
      R1 := FRaw[(2 * I + 1) * Ch + RC];
      POut[0] := L1;
      POut[1] := L0;
      POut[2] := Marker;
      POut[3] := R1;
      POut[4] := R0;
      POut[5] := Marker;
      Inc(POut, 6);
      Marker := Marker xor $FF;
    end;
    Inc(Result, Frames * 6);
    Inc(FBytesRead, Int64(Frames) * 4);
    if FBytesRead > FValidAudioBytes then FBytesRead := FValidAudioBytes;
  end;
  FMarker := Marker;
end;

procedure TDffReader.Seek(Percent: double);
var
  Target: int64;
begin
  if (FDec = nil) or (FValidBytesPerChan <= 0) then Exit;
  Target := Round(EnsureRange(Percent, 0.0, 1.0) * FValidBytesPerChan);
  Target := Target and not 1;                            // whole DoP frames
  if Target >= FValidBytesPerChan then Target := Max(0, (FValidBytesPerChan - 2) and not 1);
  FDec.Seek(Target);
  FBytesRead := Target * 2;
end;

function TDffReader.GetProgress: double;
begin
  if FValidAudioBytes <= 0 then Result := 0.0
  else Result := double(FBytesRead) / double(FValidAudioBytes);
end;

function TDffReader.GetDoPMarker: byte;
begin
  Result := FMarker;
end;

procedure TDffReader.SetDoPMarker(Value: byte);
begin
  if (Value = $05) or (Value = $FA) then FMarker := Value else FMarker := $05;
end;

end.
