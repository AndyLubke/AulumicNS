unit uSettingsLog;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uSettingsLog
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Writes the audio / system settings to the log, with the names used in the
  Preferences window:
    * LogSettingsSummary      - once at startup (Audio / Resampler / System),
                                a header line with one indented row per setting
    * LogSettingsChanges      - after Preferences > OK, one line per change
    * LogLibraryFolderChanges - library folders added / removed

  All three groups are built by one function per group (AudioItems,
  ResamplerItems, SystemItems), so the summary and the change lines always use
  the same names and values. The value texts come from the same option tables
  as the Preferences comboboxes (uAppStrings).

  ---> AulumicNS: the log is AuLog (no log window unit); the output interface
  (WASAPI exclusive / ASIO) is one more audio item, and DeviceNameForID knows
  the ASIO drivers.
  =============================================================================}

interface

uses
  Classes, SysUtils, uPlaybackManager;

// Startup: the settings that affect playback (UI thread)
procedure LogSettingsSummary(const AConfig: TManagerConfig);

// After Preferences > OK: one line per changed setting. The device names are
// passed in, because the new device ID is only stored after the dialog.
procedure LogSettingsChanges(const AOld, ANew: TManagerConfig;
  const AOldDeviceName, ANewDeviceName: string);

// After Preferences > OK, when the folder list was applied
procedure LogLibraryFolderChanges(AOldFolders, ANewFolders: TStrings);

// Friendly name of an output device ('Unknown Device' when not found);
// ---> AulumicNS: AApi 0 = WASAPI endpoint id, 1 = ASIO driver CLSID
function DeviceNameForID(AApi: Integer; const ADeviceID: string): string;

implementation

uses
  uAppConsts, uAppStrings, uAudioUtils, AuLog, ALAudioEngine;

type
  TSettingItem = record
    Caption : string;
    Value   : string;
    IsBool  : Boolean;
  end;
  TSettingItems = array of TSettingItem;

procedure AddItem(var AItems: TSettingItems; const ACaption, AValue: string;
  AIsBool: Boolean = False);
var
  N: Integer;
begin
  N := Length(AItems);
  SetLength(AItems, N + 1);
  AItems[N].Caption := ACaption;
  AItems[N].Value   := AValue;
  AItems[N].IsBool  := AIsBool;
end;

procedure AddBool(var AItems: TSettingItems; const ACaption: string; AValue: Boolean);
begin
  if AValue then
    AddItem(AItems, ACaption, LBL_SET_ON, True)
  else
    AddItem(AItems, ACaption, LBL_SET_OFF, True);
end;

// Display text of a stored value (DataStr), as shown in the combobox
function OptionName(const AOptions: array of TFormatDef; AValue: Integer): string;
var
  I: Integer;
  S: string;
begin
  S := IntToStr(AValue);
  for I := Low(AOptions) to High(AOptions) do
    if AOptions[I].DataStr = S then
      Exit(AOptions[I].DisplayName);
  Result := S;
end;

// Display text of a stored combobox index
function OptionByIndex(const AOptions: array of TFormatDef; AIndex: Integer): string;
begin
  if (AIndex >= Low(AOptions)) and (AIndex <= High(AOptions)) then
    Result := AOptions[AIndex].DisplayName
  else
    Result := IntToStr(AIndex);
end;

function AudioItems(const A: TManagerConfig; const ADeviceName: string): TSettingItems;
begin
  Result := nil;
  // ---> AulumicNS: the output interface
  if A.OutputApi = 1 then
    AddItem(Result, LBL_SET_OUTPUT_API, LBL_SET_API_ASIO)
  else
    AddItem(Result, LBL_SET_OUTPUT_API, LBL_SET_API_WASAPI);
  AddItem(Result, LBL_SET_DEVICE,     '"' + ADeviceName + '"');
  AddItem(Result, LBL_SET_PCM_BUFFER, OptionName(BUFFER_SIZE_OPTIONS, A.PCMBufferMs));
  AddItem(Result, LBL_SET_DSD_BUFFER, OptionName(BUFFER_SIZE_OPTIONS, A.DSDBufferMs));
  AddBool(Result, LBL_SET_DOP,        A.UseDoP);
  AddItem(Result, LBL_SET_DSD_GAIN,   OptionName(DSD_GAIN_OPTIONS, A.DsdToPcmGain));
  AddBool(Result, LBL_SET_DSD_LOWPASS, A.DsdLowPassFilter);
  AddBool(Result, LBL_SET_RESAMPLE,   A.ResamplePCM);
  AddBool(Result, LBL_SET_LOCK_VOLUME, A.VolumeLocked);
  AddItem(Result, LBL_SET_REPLAYGAIN, OptionName(REPLAYGAIN_OPTIONS, A.ReplayGainMode));
  // ---> AulumicNS: one setting: Automatic or the fixed preamp
  if A.AutoHeadroom then
    AddItem(Result, LBL_SET_PREAMP,   HEADROOM_OPTIONS[0].DisplayName)
  else
    AddItem(Result, LBL_SET_PREAMP,   OptionName(PREAMP_DB_OPTIONS, Round(A.PreampDB)));
  AddBool(Result, LBL_SET_SOFTCLIP,   A.EnableSoftClipping);
end;

function ResamplerItems(const A: TManagerConfig): TSettingItems;
begin
  Result := nil;
  AddItem(Result, LBL_SET_RS_QUALITY,  OptionName(RESAMPLE_QUAL_OPTIONS, A.ResampleQuality));
  AddItem(Result, LBL_SET_RS_TARGET44, FormatRateKHz(A.TargetSampleRate44));
  AddItem(Result, LBL_SET_RS_TARGET48, FormatRateKHz(A.TargetSampleRate48));
  AddItem(Result, LBL_SET_RS_UPPHASE,  OptionName(PHASE_OPTIONS, A.UpsamplePhase));
  AddItem(Result, LBL_SET_RS_DOWNPHASE, OptionName(PHASE_OPTIONS, A.DownsamplePhase));
  AddItem(Result, LBL_SET_RS_EXCLUDE,  OptionName(BYPASS_THRESH_OPTIONS, A.BypassThreshold));
  AddBool(Result, LBL_SET_RS_NO_DSD,   A.DisableResampleForDSD);
  AddItem(Result, LBL_SET_RS_BANDWIDTH, OptionByIndex(BANDWIDTH_OPTIONS, A.ResampleBandWidthIndex));
  AddItem(Result, LBL_SET_RS_ANTIALIAS, OptionByIndex(ANTI_ALIAS_OPTIONS, A.ResampleAntiAliasIndex));
end;

function SystemItems(const A: TManagerConfig): TSettingItems;
begin
  Result := nil;
  AddBool(Result, LBL_SET_HIGHRES_TIMER, A.UseHighResTimer);
  AddBool(Result, LBL_SET_AFFINITY,      A.OptimizeAffinity);
  AddBool(Result, LBL_SET_MMCSS,         A.EnableMMCSS);
  AddBool(Result, LBL_SET_KEEP_AWAKE,    A.KeepDrivesAwake);
end;

// A header line, then one indented row per setting
procedure LogItemBlock(const AHeader: string; const AItems: TSettingItems);
var
  I: Integer;
begin
  AddLog(AHeader);
  for I := 0 to High(AItems) do
    AddLogDetail(Format(FMT_LOG_SET_ITEM, [AItems[I].Caption, AItems[I].Value]));
end;

// Old and new lists come from the same function, so the items line up
procedure LogItemChanges(const AOld, ANew: TSettingItems);
var
  I: Integer;
begin
  for I := 0 to High(ANew) do
  begin
    if (I > High(AOld)) or (AOld[I].Value = ANew[I].Value) then
      Continue;

    if ANew[I].IsBool then
      AddLog(Format(FMT_LOG_PREF_TURNED, [ANew[I].Caption, ANew[I].Value]))
    else
      AddLog(Format(FMT_LOG_PREF_CHANGED, [ANew[I].Caption, AOld[I].Value, ANew[I].Value]));
  end;
end;

// Same lookup as the device button: the list of active devices first
// ('Name|Id'), then the friendly name of a WASAPI device that is switched off
// or unplugged
function DeviceNameForID(AApi: Integer; const ADeviceID: string): string;
var
  DevList: TStringList;
  DefaultIdx, I, P: Integer;
  S: string;
begin
  Result := LBL_UNKNOWN_DEVICE;
  if ADeviceID = '' then
    Exit;
  try
    DevList := TStringList.Create;
    try
      if AApi = 1 then
        TAudioEngine.EnumerateAsioDevices(DevList)
      else
        TPlaybackManager.EnumerateDevices(DevList, DefaultIdx);
      for I := 0 to DevList.Count - 1 do
      begin
        S := DevList[I];
        P := Pos('|', S);
        if (P > 0) and SameText(Trim(Copy(S, P + 1, Length(S))), ADeviceID) then
        begin
          if AApi = 1 then Exit(Copy(S, 1, P - 1));
          Exit(CleanDeviceName(Copy(S, 1, P - 1)));
        end;
      end;
    finally
      DevList.Free;
    end;

    if AApi <> 1 then
    begin
      S := TPlaybackManager.GetDeviceFriendlyName(ADeviceID);
      if S <> '' then
        Result := CleanDeviceName(S);
    end;
  except
    // Device enumeration failed: keep 'Unknown Device'
  end;
end;

procedure LogSettingsSummary(const AConfig: TManagerConfig);
begin
  LogItemBlock(LOG_SET_AUDIO, AudioItems(AConfig, DeviceNameForID(AConfig.OutputApi, AConfig.DeviceID)));
  if AConfig.ResamplePCM then
    LogItemBlock(LOG_SET_RESAMPLER, ResamplerItems(AConfig));
  LogItemBlock(LOG_SET_SYSTEM, SystemItems(AConfig));
end;

procedure LogSettingsChanges(const AOld, ANew: TManagerConfig;
  const AOldDeviceName, ANewDeviceName: string);
begin
  LogItemChanges(AudioItems(AOld, AOldDeviceName), AudioItems(ANew, ANewDeviceName));
  LogItemChanges(ResamplerItems(AOld), ResamplerItems(ANew));
  LogItemChanges(SystemItems(AOld), SystemItems(ANew));
end;

function ContainsFolder(AList: TStrings; const AFolder: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to AList.Count - 1 do
    if SameText(AList[I], AFolder) then
      Exit(True);
  Result := False;
end;

procedure LogLibraryFolderChanges(AOldFolders, ANewFolders: TStrings);
var
  I: Integer;
begin
  if (AOldFolders = nil) or (ANewFolders = nil) then
    Exit;

  for I := 0 to ANewFolders.Count - 1 do
    if not ContainsFolder(AOldFolders, ANewFolders[I]) then
      AddLog(Format(FMT_LOG_PREF_FOLDER_ADDED, [ANewFolders[I]]));

  for I := 0 to AOldFolders.Count - 1 do
    if not ContainsFolder(ANewFolders, AOldFolders[I]) then
      AddLog(Format(FMT_LOG_PREF_FOLDER_REMOVED, [AOldFolders[I]]));
end;

end.
