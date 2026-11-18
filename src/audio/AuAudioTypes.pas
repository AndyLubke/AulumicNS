unit AuAudioTypes;

{ ==============================================================================
  AulumicNS - AuAudioTypes
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Types shared by the decoders, the DSP stages, the outputs and the engine.
  =============================================================================}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  TAuSampleKind = (
    skPcmInt,     // integer PCM, BitsPerSample valid bits (8 .. 32)
    skPcmFloat,   // IEEE float PCM (32 or 64 bit)
    skDsd         // 1-bit DSD; one "frame" = one byte (8 DSD samples) per channel
  );

  { Describes a decoded stream. For DSD SampleRate is the bit rate
    (2822400 = DSD64) and TotalFrames counts bytes per channel. }
  TAuStreamInfo = record
    Kind: TAuSampleKind;
    Codec: string;              // 'FLAC', 'WAV', 'DSF', 'DFF'
    SampleRate: Cardinal;
    Channels: Integer;
    BitsPerSample: Integer;
    TotalFrames: Int64;         // -1 = unknown
  end;

  { ReplayGain values read from the tags }
  TAuReplayGain = record
    HasTrack, HasAlbum: Boolean;
    TrackGain, TrackPeak: Double;   // dB, linear peak (0 = unknown)
    AlbumGain, AlbumPeak: Double;
  end;

  TAuErrorKind = (aekNone, aekFile, aekFormat, aekUnsupported, aekDevice, aekDeviceBusy,
    aekDeviceFormat, aekDeviceLost);

  EAuAudio = class(Exception)
  public
    Kind: TAuErrorKind;
    constructor CreateKind(AKind: TAuErrorKind; const Msg: string);
  end;

  TAuOutputApi = (oaWasapi, oaAsio);

  { How a DSD stream reaches the DAC }
  TAuDsdMode = (dmDoP, dmNative, dmPcm);

  { Format the output device was opened with. For native DSD SampleRate is
    the DSD bit rate and Bits = 1. }
  TAuOutFormat = record
    SampleRate: Cardinal;
    Channels: Integer;
    Bits: Integer;          // container bits per sample (16, 24, 32; 1 = native DSD)
    ValidBits: Integer;     // valid bits (24 in a 32-bit container)
    DoP: Boolean;           // DSD over PCM frames
    NativeDsd: Boolean;
  end;

  TAuDevice = record
    Api: TAuOutputApi;
    Id: string;             // WASAPI endpoint id / ASIO driver CLSID
    Name: string;
  end;
  TAuDeviceArray = array of TAuDevice;

const
  StandardRates: array[0..11] of Cardinal = (44100, 48000, 88200, 96000, 176400, 192000,
    352800, 384000, 705600, 768000, 1411200, 1536000);
  DsdSilence = $69;         // idle pattern of a DSD stream

function DsdName(Rate: Cardinal): string;
function RateText(Rate: Cardinal): string;
{ the \\?\ form of long paths (260 characters and more) for the file APIs }
function LongPath(const Path: string): string;

implementation

constructor EAuAudio.CreateKind(AKind: TAuErrorKind; const Msg: string);
begin
  inherited Create(Msg);
  Kind := AKind;
end;

function DsdName(Rate: Cardinal): string;
begin
  if Rate mod 44100 = 0 then Result := 'DSD' + IntToStr(Rate div 44100)
  else Result := 'DSD' + IntToStr(Rate div 48000) + 'x48';
end;

function RateText(Rate: Cardinal): string;
begin
  if Rate mod 1000 = 0 then Result := IntToStr(Rate div 1000)
  else Result := FormatFloat('0.###', Rate / 1000, DefaultFormatSettings);
end;

{ Used at every file call that takes the path of a music file
  or of a file next to it (the tag readers and writers, the readers, the
  scanner, the helpers of uOSUtils / uMetaUtils). Only full paths get the
  prefix (X:\... or \\server\share\...): Windows takes a \\?\ path as it is,
  so one with '/', '\.\' or '\..\' in it, or a relative one, is left alone.
  From 240 bytes on, so the temporary file next to a file (a longer name) and
  a folder (limit 248) are covered too. }
function LongPath(const Path: string): string;
var
  L: Integer;
begin
  Result := Path;
  L := Length(Path);
  if (L < 240) or (Path[1] = '\') and (Path[2] = '\') and (Path[3] in ['?', '.']) then Exit;
  if (Pos('/', Path) > 0) or (Pos('\.\', Path) > 0) or (Pos('\..\', Path) > 0) then Exit;
  if (Path[1] = '\') and (Path[2] = '\') then
    Result := '\\?\UNC\' + Copy(Path, 3, MaxInt)
  else if (Path[1] in ['A'..'Z', 'a'..'z']) and (Path[2] = ':') and (Path[3] = '\') then
    Result := '\\?\' + Path;
end;

end.
