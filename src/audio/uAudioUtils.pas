unit uAudioUtils;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uAudioUtils
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Various helper routines for audio files.
==============================================================================}

interface

uses
  Classes, SysUtils, StrUtils, uAppConsts, uAppStrings;

const
  EXT_WAV     = '.wav';
  EXT_AIFF    = '.aiff';
  EXT_AIF     = '.aif';
  EXT_AIFC    = '.aifc';
  EXT_M4A     = '.m4a';   // Apple Lossless
  EXT_FLAC    = '.flac';
  EXT_DSF     = '.dsf';
  EXT_DFF     = '.dff';   // DSDIFF
  EXT_AULLINK = '.aullink';

type
  TAudioStats = record
    IsPlaying         : Boolean;
    BitDepth          : Integer;
    Channels          : Integer;
    InputRate         : Integer;
    OutputRate        : Integer;
    BufferSizeMs      : Integer;
    AppliedReplayGain : Double;
    IsBitPerfect      : Boolean;  // nothing touches the signal
  end;

  // The stages of the signal path (the badge's popup), read
  // from the play thread by TPlaybackManager.GetSignalInfo. Valid = a stream
  // is open.
  TSignalInfo = record
    Valid          : Boolean;
    IsDsd          : Boolean;   // the source is DSD
    DoP            : Boolean;   // DSD packed into PCM frames (DoP)
    NativeDsd      : Boolean;   // DSD sent as DSD (ASIO)
    DsdToPcm       : Boolean;   // DSD converted to PCM
    Resampled      : Boolean;
    InRate         : Integer;
    OutRate        : Integer;
    SourceBits     : Integer;   // before a bit depth conversion
    OutBits        : Integer;   // the device format: container bits
    OutValidBits   : Integer;   //   and valid bits (24 in 32)
    Channels       : Integer;
    ToneActive     : Boolean;
    VolumeDisabled : Boolean;   // Preferences: volume fixed at 100 %
    Volume         : Integer;   // 0 .. 1000 (1000 = 100 %)
    RGFactor       : Double;    // the linear ReplayGain factor applied (1 = none)
    PreampDB       : Double;    // the preamp in RGFactor (also without ReplayGain)
    SoftClip       : Boolean;
    OutputApi      : Integer;   // 0 WASAPI exclusive, 1 ASIO
    ResampleQuality: Integer;
    Phase          : Integer;   // of the resampler in use (up or down)
    BitPerfect     : Boolean;
    Clipped        : Boolean;
    // Automatic headroom (TPlayThread.RunGain): switched on,
    // and what it takes off at the moment (0 or negative, dB)
    HeadroomOn     : Boolean;
    HeadroomDB     : Double;
    // How often the device ran out of audio since it was opened for this
    // stream (each one is an audible gap)
    Dropouts       : Integer;
    // A source with more than two channels mixed to stereo: its channel
    // count (0 = none) and the level of the mix before volume and headroom
    // (0 or negative, dB)
    DownmixFrom    : Integer;
    DownmixBits    : Integer;   // the bit depth of that source
    DownmixDB      : Double;
  end;

  TRateArray = array of Integer;  // sample rates (TargetRateChoices)

// Check for valid music file (wav, flac, dsf, dff)
function IsValidMusicFile(const FileName: string): boolean; inline;

// Check for dsd file
function IsDSDFile(const FileName: string): boolean; inline;

// The DSD multiple of a DSD bit rate in Hz: 64 for DSD64 of
// both families (2.8224 MHz = 64 x 44.1 kHz, 3.072 MHz = 64 x 48 kHz; a
// plain div 44100 would make DSD69 of the second); 0 for no rate. DsdRateName:
// 'DSD64'. A DoP carrier rate is the DSD rate / 16.
function DsdMultiple(ADsdRate: Integer): Integer;
function DsdRateName(ADsdRate: Integer): string;

{ Names the calling thread for the hang report (Windows'
  SetThreadDescription, Windows 10 1607 and later; nothing on older ones) }
procedure NameThisThread(const AName: string);

// Check for flac file
function IsFlacFile(const FileName: string): boolean; inline;

// Check for wav file
function IsWavFile(const FileName: string): boolean; inline;
function IsAiffFile(const FileName: string): boolean; inline;
function IsM4aFile(const FileName: string): boolean; inline;
// The format of a file as it is shown and asked for (%codec%): its
// extension in capitals, AIFF for every AIFF extension
function FormatNameOf(const FileName: string): string;

// Centralized check for virtual folder links
function IsAulLinkFile(const FileName: string): boolean; inline;

// Make a friendly shortened name of the Windows WASAPI Audio Device Name
function CleanDeviceName(const OriginalString: string): string;

// Parse paths in a Aullink file. ACheckExists = False also keeps targets that
// cannot be reached right now (the library scanner stores all of them).
// False when the file could not be read.
function ParseAulLinkFile(const AulLinkPath: string; OutPaths: TStringList;
  ACheckExists: Boolean = True): Boolean;

// Sample rate as text for the log, always with a dot:
// 44100 -> '44.1 kHz', 48000 -> '48 kHz', 11025 -> '11.025 kHz'
function FormatRateKHz(ARate: Cardinal): string;

// The family of a sample rate, as the resampler's rate map
// (TPlaybackManager.PrepareEngineForTrack) groups them: RATE_FAMILY_48K for a
// multiple of 48 kHz (48, 96, ... 3072 kHz), otherwise RATE_FAMILY_44K (also
// for 0 and rates of neither family). It decides which target rate setting
// (TargetSampleRate44 / 48) a rate belongs to.
function SampleRateFamily(ARate: Integer): Integer;

// The target rates a family can be resampled to, ascending: the
// same list the preferences offer (TARGET_RATE_44_OPTIONS / _48_OPTIONS), so
// the rate menu of the main window and the "choose another rate" dialog never
// offer a rate the settings do not take. AFamily: any rate of the family
// (SampleRateFamily decides).
function TargetRateChoices(AFamily: Integer): TRateArray;

implementation

uses
  AuAudioTypes, Windows;

// =========================================================================
// Inlined case-insensitive extension checks for fast UI/Tree loops
// =========================================================================
function IsValidMusicFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_FLAC, FileName) or
            EndsText(EXT_DSF, FileName) or
            EndsText(EXT_DFF, FileName) or
            EndsText(EXT_WAV, FileName) or
            EndsText(EXT_AIFF, FileName) or
            EndsText(EXT_AIF, FileName) or
            EndsText(EXT_AIFC, FileName) or
            EndsText(EXT_M4A, FileName);
end;

function DsdMultiple(ADsdRate: Integer): Integer;
begin
  if ADsdRate <= 0 then
    Exit(0);
  if ((ADsdRate mod 44100) <> 0) and ((ADsdRate mod 48000) = 0) then
    Result := ADsdRate div 48000
  else
    Result := (ADsdRate + 22050) div 44100;
end;

function DsdRateName(ADsdRate: Integer): string;
begin
  Result := 'DSD' + IntToStr(DsdMultiple(ADsdRate));
end;

type
  TSetThreadDescription = function(hThread: Windows.HANDLE; lpThreadDescription: PWideChar): HRESULT; stdcall;

procedure NameThisThread(const AName: string);
var
  P: TSetThreadDescription;
  W: UnicodeString;
begin
  P := TSetThreadDescription(Windows.GetProcAddress(Windows.GetModuleHandle('kernel32.dll'),
    'SetThreadDescription'));
  if not Assigned(P) then Exit;
  W := UTF8Decode(AName);
  P(Windows.GetCurrentThread, PWideChar(W));
end;

function IsDSDFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_DSF, FileName) or EndsText(EXT_DFF, FileName);
end;

function IsFlacFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_FLAC, FileName);
end;

function IsWavFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_WAV, FileName);
end;

function IsAiffFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_AIFF, FileName) or EndsText(EXT_AIF, FileName) or
            EndsText(EXT_AIFC, FileName);
end;

function IsM4aFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_M4A, FileName);
end;

function IsAulLinkFile(const FileName: string): boolean; inline;
begin
  Result := EndsText(EXT_AULLINK, FileName);
end;

function FormatNameOf(const FileName: string): string;
begin
  if IsAiffFile(FileName) then
    Result := 'AIFF'
  else
    Result := UpperCase(Copy(ExtractFileExt(FileName), 2, 10));
end;

// =========================================================================

// Shortens the audio device name as presented by Windows.
function CleanDeviceName(const OriginalString: string): string;
var
  TrimmedStr: string;
  PosL, PosR, I: Integer;
begin
  // Start with a clean baseline
  TrimmedStr := Trim(OriginalString);
  Result     := TrimmedStr;

  // 1. Find the first '(' from the left
  PosL := Pos('(', TrimmedStr);

  // 2. Find the first ')' from the right
  PosR := 0;
  for I := Length(TrimmedStr) downto 1 do
  begin
    if TrimmedStr[I] = ')' then
    begin
      PosR := I;
      Break;
    end;
  end;

  // 3. Extract everything between them if valid bounds are found
  // Slice from TrimmedStr (not OriginalString) so leading
  // whitespace never shifts PosL/PosR!
  if (PosL > 0) and (PosR > PosL) then
  begin
    Result := Trim(Copy(TrimmedStr, PosL + 1, PosR - PosL - 1));

    // 4. Fallback if the extracted string was empty (e.g., "Device ()")
    if Result = '' then
      Result := TrimmedStr;
  end;
end;

function ParseAulLinkFile(const AulLinkPath: string; OutPaths: TStringList;
  ACheckExists: Boolean): Boolean;
var
  LinkLines: TStringList;
  I: Integer;
  TargetPath: string;
begin
  Result := False;
  if (not Assigned(OutPaths)) or (not FileExists(LongPath(AulLinkPath))) then
    Exit;

  LinkLines := TStringList.Create;
  try
    try
      LinkLines.LoadFromFile(AulLinkPath, TEncoding.UTF8);
      Result := True;
      for I := 0 to LinkLines.Count - 1 do
      begin
        TargetPath := Trim(LinkLines[I]);
        if (TargetPath = '') or StartsText('#', TargetPath) or StartsText('//', TargetPath) then
          Continue;

        // Resolve relative paths
        if (ExtractFileDrive(TargetPath) <> '') or StartsText('\', TargetPath) or StartsText('/', TargetPath) then
          TargetPath := ExpandFileName(TargetPath)
        else
          TargetPath := ExpandFileName(IncludeTrailingPathDelimiter(ExtractFilePath(AulLinkPath)) + TargetPath);

        // Clean up the path so ExtractFileName gets the actual folder name
        TargetPath := ExcludeTrailingPathDelimiter(TargetPath);

        // Avoid adding duplicate directories from the same .aullink file
        if ((not ACheckExists) or DirectoryExists(LongPath(TargetPath))) and
           (OutPaths.IndexOf(TargetPath) < 0) then
          OutPaths.Add(TargetPath);
      end;
    except
      // Silently swallow locked text files
    end;
  finally
    LinkLines.Free;
  end;
end;

function FormatRateKHz(ARate: Cardinal): string;
var
  Frac: string;
begin
  Result := IntToStr(ARate div 1000);
  if ARate mod 1000 <> 0 then
  begin
    Frac := IntToStr(ARate mod 1000);
    while Length(Frac) < 3 do
      Frac := '0' + Frac;
    while (Frac <> '') and (Frac[Length(Frac)] = '0') do
      Delete(Frac, Length(Frac), 1);
    Result := Result + '.' + Frac;
  end;
  Result := Result + ' kHz';
end;

function SampleRateFamily(ARate: Integer): Integer;
begin
  if (ARate > 0) and (ARate mod RATE_FAMILY_48K = 0) and (ARate mod RATE_FAMILY_44K <> 0) then
    Result := RATE_FAMILY_48K
  else
    Result := RATE_FAMILY_44K;
end;

function TargetRateChoices(AFamily: Integer): TRateArray;
var
  I: Integer;
begin
  Result := nil;
  if SampleRateFamily(AFamily) = RATE_FAMILY_48K then
  begin
    SetLength(Result, Length(TARGET_RATE_48_OPTIONS));
    for I := Low(TARGET_RATE_48_OPTIONS) to High(TARGET_RATE_48_OPTIONS) do
      Result[I - Low(TARGET_RATE_48_OPTIONS)] := StrToInt(TARGET_RATE_48_OPTIONS[I].DataStr);
  end
  else
  begin
    SetLength(Result, Length(TARGET_RATE_44_OPTIONS));
    for I := Low(TARGET_RATE_44_OPTIONS) to High(TARGET_RATE_44_OPTIONS) do
      Result[I - Low(TARGET_RATE_44_OPTIONS)] := StrToInt(TARGET_RATE_44_OPTIONS[I].DataStr);
  end;
end;

end.
