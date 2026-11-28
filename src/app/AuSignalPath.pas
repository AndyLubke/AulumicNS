unit AuSignalPath;

{ ==============================================================================
  AulumicNS - AuSignalPath
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The signal path (TAuSignalPath): every stage
  between the file and the DAC - source, decoder or DSD transport,
  ReplayGain, tone control, resampler, volume, dither, output - green when it
  passes the signal on unchanged, amber when it changes it, with a summary
  line (bit-perfect or processed).
  It is a popup under the badge of the banner (a click on it) that
  follows the playback while it is open (refreshed twice a second). The
  stages come from the play thread's snapshot (TPlaybackManager.
  GetSignalInfo), the playing file and the settings (BuildSignalPath).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuForms, ALMetadata, uAudioUtils;

type
  TAuStageState = (stNeutral, stTransparent, stModified);

  TAuStage = record
    Icon: TAuIcon;
    Title, Detail: string;
    State: TAuStageState;
  end;

  { TAuSignalPath }

  TAuSignalPath = class(TAuControl)
  private
    FStages: array of TAuStage;
    FSummary: string;
    FSummaryState: TAuStageState;
    FMaxHeight: Integer;
    function Pitch: Integer;
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure ClearStages;
    procedure AddStage(AIcon: TAuIcon; const ATitle, ADetail: string; AState: TAuStageState);
    procedure SetSummary(const AText: string; AState: TAuStageState);
    function PreferredHeight: Integer;
    function StageCount: Integer;
    function Stage(I: Integer): TAuStage;
    property Summary: string read FSummary;
    property SummaryState: TAuStageState read FSummaryState;
    { the most it may take (px; 0 = no limit): the stages close up }
    property MaxHeight: Integer read FMaxHeight write FMaxHeight;
  end;

  { fills the view with the current stages (the main window) }
  TSignalPathFill = procedure(P: TAuSignalPath) of object;

{ the popup at X, Y (screen; above AboveY when it does not fit below) }
procedure ShowSignalPath(X, Y, AboveY: Integer; AFill: TSignalPathFill);
procedure CloseSignalPath;
{ Where the popup's top goes when its height becomes ANewHeight (a stage more
  or less): it keeps its place - its lower edge when it was opened above the
  badge (AAboveY >= 0 and above it), else its top - and never leaves the work
  area AWorkTop .. AWorkBottom; the top wins when it is higher than that. }
function SignalPathTop(ATop, ANewHeight, AAboveY, AWorkTop, AWorkBottom: Integer): Integer;
function SignalPathOpen: Boolean;

{ the stages of the playing stream. AInfo.Valid = False: idle / stopped }
procedure BuildSignalPath(P: TAuSignalPath; const AInfo: TSignalInfo; const AMeta: TAudioMetadata;
  const AFilePath, ADeviceName: string; APaused: Boolean);
{ a long example (DSD to PCM with every stage active), for the screenshots }
procedure BuildDemoSignalPath(P: TAuSignalPath);
{ the example as a window of the popup's size, not shown (screenshot mode) }
function CreateSignalPathDemo(AOwner: TComponent): TAuForm;

{ the width of the popup (unscaled) }
const
  SIGNAL_PATH_W = 470;

implementation

uses
  uAppConsts, uAppStrings, uSettingsManager, ALReaders;

type
  { TSignalPathPopup }

  TSignalPathPopup = class(TAuPopup)
  private
    FBg: TAuPanel;
    FPath: TAuSignalPath;
    FFill: TSignalPathFill;
    FTimer: TTimer;
    FAboveY: Integer;
    procedure Tick(Sender: TObject);
    procedure Refill;
    procedure PopupKey(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor CreatePath(AFill: TSignalPathFill);
    destructor Destroy; override;
  end;

var
  GPopup: TSignalPathPopup = nil;

{ ---- TAuSignalPath ---- }

constructor TAuSignalPath.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := S(300);
end;

procedure TAuSignalPath.ClearStages;
begin
  SetLength(FStages, 0);
  Invalidate;
end;

procedure TAuSignalPath.AddStage(AIcon: TAuIcon; const ATitle, ADetail: string; AState: TAuStageState);
var
  N: Integer;
begin
  N := Length(FStages);
  SetLength(FStages, N + 1);
  FStages[N].Icon := AIcon;
  FStages[N].Title := ATitle;
  FStages[N].Detail := ADetail;
  FStages[N].State := AState;
  Invalidate;
end;

procedure TAuSignalPath.SetSummary(const AText: string; AState: TAuStageState);
begin
  FSummary := AText;
  FSummaryState := AState;
  Invalidate;
end;

{ the distance of the stages: 52, closer (down to 40) when
  all of them would not fit into MaxHeight (a small screen at a large scaling) }
function TAuSignalPath.Pitch: Integer;
var
  N: Integer;
begin
  Result := S(52);
  N := Length(FStages);
  if (FMaxHeight <= 0) or (N = 0) then Exit;
  Result := Math.Max(S(40), Math.Min(S(52), (FMaxHeight - S(68)) div N));
end;

function TAuSignalPath.PreferredHeight: Integer;
begin
  Result := S(56) + Length(FStages) * Pitch + S(12);
end;

function TAuSignalPath.StageCount: Integer;
begin
  Result := Length(FStages);
end;

function TAuSignalPath.Stage(I: Integer): TAuStage;
begin
  Result := FStages[I];
end;

function StateColor(St: TAuStageState): TARGB;
begin
  case St of
    stTransparent: Result := clGood;
    stModified: Result := clWarn;
  else
    Result := clTextDim;
  end;
end;

procedure TAuSignalPath.DoPaint(G: TGfx);
var
  I, P: Integer;
  Y, CX: Single;
  C: TARGB;
begin
  P := Pitch;
  G.FillRect(0, 0, Width, Height, ParentBack);
  G.FillRound(0, 0, Width, Height, S(12), clCard);
  if not ThemeIsDark then G.StrokeRound(0, 0, Width, Height, S(12), 1, clBorder);
  { summary pill }
  C := StateColor(FSummaryState);
  G.FillRound(S(16), S(14), Width - S(32), S(30), S(15), Blend(clCard, C, 0.14));
  { a tick, a dot or nothing: the state does not rest on the colour alone }
  if FSummaryState = stTransparent then DrawIcon(G, icCheck, S(32), S(29), S(13), C)
  else G.FillCircle(S(32), S(29), SF(4), C);
  G.Text(FSummary, S(44), S(14), Width - S(72), S(30), UIFont(12.5, True), C, 0, 1);
  CX := S(36);
  Y := S(56);
  for I := 0 to High(FStages) do
  begin
    if I < High(FStages) then G.FillRect(CX - SF(0.75), Y + S(34), SF(1.5), P - S(34), clBorderHi);
    C := StateColor(FStages[I].State);
    G.FillCircle(CX, Y + S(18), S(16), Blend(clCard, C, 0.16));
    DrawIcon(G, FStages[I].Icon, CX, Y + S(18), S(15), C);
    { a stage that changes the samples carries a dot at its upper right }
    if FStages[I].State = stModified then
    begin
      G.FillCircle(CX + S(12), Y + S(7), SF(5.5), clCard);
      G.FillCircle(CX + S(12), Y + S(7), SF(3.5), C);
    end;
    G.Text(FStages[I].Title, CX + S(28), Y + S(2), Width - CX - S(44), S(18), UIFont(13, True), clText, 0, 1);
    G.Text(FStages[I].Detail, CX + S(28), Y + S(20), Width - CX - S(44), S(18), UIFont(12), clTextDim, 0, 1);
    Y := Y + P;
  end;
end;

{ ---- the popup ---- }

function SignalPathTop(ATop, ANewHeight, AAboveY, AWorkTop, AWorkBottom: Integer): Integer;
begin
  { opened above the badge: its lower edge stays there and it grows upwards }
  if (AAboveY >= 0) and (ATop < AAboveY) then Result := AAboveY - ANewHeight
  else Result := ATop;
  if Result + ANewHeight > AWorkBottom then Result := AWorkBottom - ANewHeight;
  if Result < AWorkTop then Result := AWorkTop;
end;

constructor TSignalPathPopup.CreatePath(AFill: TSignalPathFill);
begin
  CreatePopup(nil);
  OnKeyDown := @PopupKey;
  FFill := AFill;
  FBg := TAuPanel.Create(Self);
  FBg.Parent := Self;
  FBg.Align := alClient;
  FBg.BackRole := crCard;
  FPath := TAuSignalPath.Create(Self);
  FPath.Parent := FBg;
  FPath.Align := alClient;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 500;
  FTimer.OnTimer := @Tick;
end;

destructor TSignalPathPopup.Destroy;
begin
  if GPopup = Self then GPopup := nil;
  inherited Destroy;
end;

procedure TSignalPathPopup.Refill;
var
  H, T: Integer;
  WA: TRect;
begin
  if Assigned(FFill) then FFill(FPath);
  { the screen the popup is on, by its middle: a corner can lie outside }
  WA := Screen.MonitorFromPoint(Point(Left + Width div 2, Top + Height div 2)).WorkareaRect;
  FPath.MaxHeight := WA.Bottom - WA.Top - S(16);
  H := FPath.PreferredHeight;
  if H <> ClientHeight then
  begin
    T := SignalPathTop(Top, H, FAboveY, WA.Top, WA.Bottom);
    SetBounds(Left, T, Width, H);
  end;
end;

procedure TSignalPathPopup.Tick(Sender: TObject);
begin
  if Visible then Refill;
end;

procedure TSignalPathPopup.PopupKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    CloseTree;
  end;
end;

procedure ShowSignalPath(X, Y, AboveY: Integer; AFill: TSignalPathFill);
begin
  if GPopup <> nil then
  begin
    { a second click on the badge closes it }
    GPopup.CloseTree;
    Exit;
  end;
  GPopup := TSignalPathPopup.CreatePath(AFill);
  GPopup.FAboveY := AboveY;
  with Screen.MonitorFromPoint(Point(X, Y)).WorkareaRect do
    GPopup.FPath.MaxHeight := Bottom - Top - S(16);
  if Assigned(AFill) then AFill(GPopup.FPath);
  GPopup.ShowAt(X, Y, S(SIGNAL_PATH_W), GPopup.FPath.PreferredHeight, AboveY);
  GPopup.FTimer.Enabled := True;
end;

procedure CloseSignalPath;
begin
  if GPopup <> nil then
  begin
    GPopup.FTimer.Enabled := False;
    GPopup.FFill := nil;
    FreeAndNil(GPopup);
  end;
end;

function SignalPathOpen: Boolean;
begin
  Result := GPopup <> nil;
end;

{ ---- the stages ---- }

function RateText(ARate: Integer): string;
begin
  if ARate <= 0 then Exit('?');
  if ARate mod 1000 = 0 then Result := IntToStr(ARate div 1000)
  else Result := FormatFloat('0.0##', ARate / 1000, DefaultFormatSettings);
end;

function DsdName(ARate: Integer): string;
begin
  Result := DsdRateName(ARate);   // both DSD families (uAudioUtils)
end;

function CodecOf(const APath: string): string;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(APath));
  if E = '.flac' then Result := 'FLAC'
  else if E = '.wav' then Result := 'WAV'
  else if (E = '.aiff') or (E = '.aif') or (E = '.aifc') then Result := 'AIFF'
  else if E = '.m4a' then Result := 'ALAC'
  else if E = '.dsf' then Result := 'DSF'
  else if E = '.dff' then Result := 'DFF'
  else Result := UpperCase(Copy(E, 2, 8));
end;

function ChannelText(N: Integer): string;
begin
  if N = 1 then Result := 'mono'
  else if N = 2 then Result := 'stereo'
  else if N <= DOWNMIX_MAX_CHANNELS then
    Result := ChannelLayoutName(N) + ' (' + IntToStr(N) + ' channels)'
  else Result := IntToStr(N) + ' channels';
end;

{ the layout that is mixed down, as the first word of its stage }
function DownmixName(N: Integer): string;
begin
  if N = 4 then Result := 'Quadraphonic'
  else Result := ChannelLayoutName(N);
end;

{ ATenths: the tone gain in tenths of a dB (as the settings keep it) }
function ToneText(ATenths, AHz: Integer): string;
begin
  Result := FormatFloat('+0.0;-0.0;0.0', ATenths / 10, DefaultFormatSettings) + ' dB at ';
  if AHz >= 1000 then Result := Result + FormatFloat('0.#', AHz / 1000, DefaultFormatSettings) + ' kHz'
  else Result := Result + IntToStr(AHz) + ' Hz';
end;

{ the bands of the tone control that are set (all five would not fit a
  line) }
function ToneBandsText: string;
const
  NAMES: array[0..4] of string = ('Bass', 'Low mid', 'Mid', 'High mid', 'Treble');
var
  Db, Hz: array[0..4] of Integer;
  B: Integer;
begin
  Db[0] := AppSettings.Data.Audio.ToneBassDB;     Hz[0] := AppSettings.Data.Audio.ToneBassHz;
  Db[1] := AppSettings.Data.Audio.ToneLowMidDB;   Hz[1] := AppSettings.Data.Audio.ToneLowMidHz;
  Db[2] := AppSettings.Data.Audio.ToneMidDB;      Hz[2] := AppSettings.Data.Audio.ToneMidHz;
  Db[3] := AppSettings.Data.Audio.ToneHighMidDB;  Hz[3] := AppSettings.Data.Audio.ToneHighMidHz;
  Db[4] := AppSettings.Data.Audio.ToneTrebleDB;   Hz[4] := AppSettings.Data.Audio.ToneTrebleHz;
  Result := '';
  for B := 0 to 4 do
    if Db[B] <> 0 then
    begin
      if Result <> '' then Result := Result + '  ·  ';
      Result := Result + NAMES[B] + ' ' + ToneText(Db[B], Hz[B]);
    end;
end;

function GainText(ADb: Double): string;
begin
  Result := FormatFloat('+0.00;-0.00;0.00', ADb, DefaultFormatSettings) + ' dB';
end;

procedure BuildSignalPath(P: TAuSignalPath; const AInfo: TSignalInfo; const AMeta: TAudioMetadata;
  const AFilePath, ADeviceName: string; APaused: Boolean);
var
  Src, Fmt, Api, S2: string;
  DsdOut, PcmWork: Boolean;
  VolDb, RgDb: Double;
  Q, Ph: Integer;
begin
  P.ClearStages;
  if (not AInfo.Valid) or (AFilePath = '') then
  begin
    if AFilePath <> '' then P.SetSummary('Stopped - the device is released', stNeutral)
    else P.SetSummary('Idle - no signal', stNeutral);
    P.AddStage(icDocument, 'Source', 'Nothing playing', stNeutral);
    P.AddStage(icSpeaker, 'Output', 'The device is released while nothing plays', stNeutral);
    Exit;
  end;
  DsdOut := AInfo.DoP or AInfo.NativeDsd;
  { source }
  if AInfo.IsDsd then
    Src := Format('%s  ·  %s  ·  1 bit  ·  %s MHz', [CodecOf(AFilePath), DsdName(AMeta.SampleRate),
      FormatFloat('0.0###', AMeta.SampleRate / 1000000, DefaultFormatSettings)])
  else if AInfo.DownmixFrom > 0 then
    Src := Format('%s  ·  %d bit  ·  %s kHz', [CodecOf(AFilePath), AInfo.DownmixBits, RateText(AInfo.InRate)])
  else
    Src := Format('%s  ·  %d bit  ·  %s kHz', [CodecOf(AFilePath), AInfo.SourceBits, RateText(AInfo.InRate)]);
  if AInfo.DownmixFrom > 0 then Src := Src + '  ·  ' + ChannelText(AInfo.DownmixFrom)
  else Src := Src + '  ·  ' + ChannelText(AInfo.Channels);
  P.AddStage(icDocument, 'Source file', Src, stNeutral);
  { decoder / DSD transport }
  if AInfo.DoP then
    P.AddStage(icDisc, 'DSD transport', Format('DoP  ·  packed into %s kHz / %d bit PCM frames',
      [RateText(AInfo.OutRate), AInfo.OutBits]), stTransparent)
  else if AInfo.NativeDsd then
    P.AddStage(icDisc, 'DSD transport', 'Native DSD  ·  ASIO', stTransparent)
  else if AInfo.DsdToPcm then
  begin
    S2 := Format('Decimation to %s kHz  ·  %s', [RateText(AInfo.InRate),
      GainText(AppSettings.Data.Audio.DsdToPcmGain)]);
    { the gain is applied with the volume (after the
      resampler), so it clips only at the end, where the preamp helps }
    if AppSettings.Data.Audio.DsdToPcmGain = 6 then S2 := S2 + ' (SACD reference, with the volume)'
    else if AppSettings.Data.Audio.DsdToPcmGain <> 0 then S2 := S2 + ' (with the volume)';
    if AppSettings.Data.Audio.DsdLowPassFilter then S2 := S2 + '  ·  low-pass';
    if AInfo.DownmixFrom > 0 then S2 := S2 + '  ·  needed for the downmix';
    P.AddStage(icDisc, 'DSD to PCM', S2, stModified);
  end
  else if CodecOf(AFilePath) = 'FLAC' then
    P.AddStage(icBolt, 'Decoder', 'Built-in FLAC decoder  ·  lossless', stTransparent)
  else if CodecOf(AFilePath) = 'ALAC' then
    P.AddStage(icBolt, 'Decoder', 'Built-in Apple Lossless decoder  ·  lossless', stTransparent)
  else
    P.AddStage(icBolt, 'Decoder', 'PCM, read as stored', stTransparent);
  { more than two channels: mixed to stereo right behind the decoder }
  if AInfo.DownmixFrom > 0 then
  begin
    S2 := Format('%s to stereo  ·  centre and surround at -3 dB', [DownmixName(AInfo.DownmixFrom)]);
    if AInfo.DownmixDB <= -0.005 then S2 := S2 + '  ·  ' + GainText(AInfo.DownmixDB) + ' so it cannot clip';
    P.AddStage(icSliders, 'Downmix', S2, stModified);
  end;
  { ReplayGain (RGFactor also holds the preamp: shown as a
    stage of its own, the ReplayGain stage shows the rest) }
  RgDb := 0;
  if AInfo.RGFactor > 0 then RgDb := 20 * Log10(AInfo.RGFactor);
  if not DsdOut then RgDb := RgDb - AInfo.PreampDB;
  if DsdOut and (AppSettings.Data.Audio.ReplayGainMode <> 0) then
    P.AddStage(icSliders, 'ReplayGain', 'Not applied  ·  a DSD stream is passed on unchanged', stTransparent)
  else if (AppSettings.Data.Audio.ReplayGainMode <> 0) and AInfo.VolumeDisabled then
    P.AddStage(icSliders, 'ReplayGain', 'Not applied  ·  the volume is locked to 100 %', stTransparent)
  else if (AppSettings.Data.Audio.ReplayGainMode <> 0) and (Abs(RgDb) >= 0.005) then
  begin
    if AppSettings.Data.Audio.ReplayGainMode = 2 then S2 := 'Album' else S2 := 'Track';
    P.AddStage(icSliders, 'ReplayGain', S2 + ' gain ' + GainText(RgDb), stModified);
  end
  else if AppSettings.Data.Audio.ReplayGainMode <> 0 then
    P.AddStage(icSliders, 'ReplayGain', 'No gain to apply (no ReplayGain tags, or 0 dB)', stTransparent)
  else
    P.AddStage(icSliders, 'ReplayGain', 'Off', stTransparent);
  { the preamp (Preferences > Volume), when one is set }
  if Abs(AInfo.PreampDB) >= 0.005 then
  begin
    if DsdOut then
      P.AddStage(icSliders, 'Headroom', 'Fixed, not applied  ·  a DSD stream is passed on unchanged', stTransparent)
    else
      P.AddStage(icSliders, 'Headroom', GainText(AInfo.PreampDB) + '  ·  fixed (Preferences > Volume)', stModified);
  end
  else if AInfo.VolumeDisabled and (Abs(AppSettings.Data.Audio.PreampDB) >= 0.005) and not DsdOut then
    { a preamp is set, but the locked volume leaves the level alone }
    P.AddStage(icSliders, 'Headroom', 'Fixed, not applied  ·  the volume is locked to 100 %', stTransparent);
  { tone control }
  if AInfo.ToneActive and not DsdOut then
    P.AddStage(icEqualizer, 'Tone control', ToneBandsText, stModified)
  else if (not AppSettings.Data.Audio.ToneDirect) and DsdOut then
    P.AddStage(icEqualizer, 'Tone control', 'Not applied  ·  a DSD stream is passed on unchanged', stTransparent)
  else if not AppSettings.Data.Audio.ToneDirect then
    P.AddStage(icEqualizer, 'Tone control', 'Flat  ·  bypassed', stTransparent);
  { resampler }
  if AInfo.Resampled then
  begin
    Q := EnsureRange(AInfo.ResampleQuality, 0, High(RESAMPLE_QUAL_OPTIONS));
    Ph := EnsureRange(AInfo.Phase, 0, High(PHASE_OPTIONS));
    P.AddStage(icWave, 'Resampler', Format('%s -> %s kHz  ·  %s  ·  %s', [RateText(AInfo.InRate),
      RateText(AInfo.OutRate), PHASE_OPTIONS[Ph].DisplayName, RESAMPLE_QUAL_OPTIONS[Q].DisplayName]), stModified);
  end
  else if not DsdOut then
    P.AddStage(icWave, 'Resampler', 'Bypassed  ·  the device takes the rate', stTransparent);
  { volume }
  if DsdOut then
    P.AddStage(icVolume2, 'Volume', 'Not applied to DSD  ·  use the volume of the DAC', stTransparent)
  else if AInfo.VolumeDisabled then
    P.AddStage(icVolume2, 'Volume', 'Locked to 100 % (Preferences > Volume)', stTransparent)
  else if AInfo.Volume <= 0 then
    P.AddStage(icMute, 'Volume', 'Muted', stModified)
  else if AInfo.Volume < 1000 then
  begin
    VolDb := 40 * Log10(AInfo.Volume / 1000);
    S2 := Format('Digital %s dB  (%d %%)', [FormatFloat('0.0', VolDb, DefaultFormatSettings), Round(AInfo.Volume / 10)]);
    if AInfo.SoftClip then S2 := S2 + '  ·  soft clipping';
    P.AddStage(icVolume1, 'Volume', S2, stModified);
  end
  else
    P.AddStage(icVolume2, 'Volume', 'Bypassed (100 %)', stTransparent);
  { automatic headroom (it is part of the gain: shown where
    it lowers something, or could) }
  if AInfo.HeadroomOn and not DsdOut then
  begin
    if AInfo.HeadroomDB <= -0.005 then
      P.AddStage(icSliders, 'Headroom', GainText(AInfo.HeadroomDB) +
        '  ·  automatic, for the highest peak of this album', stModified)
    else if AInfo.Resampled or AInfo.DsdToPcm or AInfo.ToneActive then
      P.AddStage(icSliders, 'Headroom', 'Automatic  ·  nothing to lower so far', stTransparent);
  end;
  { bit depth: dither when the signal is processed, padding is lossless }
  PcmWork := (not DsdOut) and not AInfo.BitPerfect;
  if PcmWork and (AInfo.Resampled or AInfo.ToneActive or AInfo.DsdToPcm or (AInfo.DownmixFrom > 0) or
    ((not AInfo.VolumeDisabled) and ((AInfo.Volume < 1000) or (Abs(RgDb + AInfo.PreampDB) >= 0.005)))) then
    P.AddStage(icSliders, 'Dither', Format('TPDF to %d bit', [AInfo.OutValidBits]), stModified)
  else if (not DsdOut) and (AInfo.OutValidBits < AInfo.SourceBits) then
    P.AddStage(icSliders, 'Bit depth', Format('%d -> %d bit  ·  the device takes fewer bits',
      [AInfo.SourceBits, AInfo.OutValidBits]), stModified)
  else if (not DsdOut) and (AInfo.OutBits > AInfo.SourceBits) then
    P.AddStage(icSliders, 'Bit depth', Format('%d bit in a %d bit frame  ·  padded, lossless',
      [AInfo.SourceBits, AInfo.OutBits]), stTransparent);
  if AInfo.Clipped then
    P.AddStage(icWarning, 'Clipping', 'Samples were limited at full scale (lower the volume or the preamp)', stModified);
  { the device ran out of audio: each time is a gap that was heard }
  if AInfo.Dropouts = 1 then
    P.AddStage(icWarning, 'Dropouts', '1 since the device was opened  ·  a larger buffer can help', stModified)
  else if AInfo.Dropouts > 1 then
    P.AddStage(icWarning, 'Dropouts', Format('%d since the device was opened  ·  a larger buffer can help',
      [AInfo.Dropouts]), stModified);
  { output }
  if AInfo.OutputApi = 1 then Api := 'ASIO' else Api := 'WASAPI exclusive';
  if AInfo.NativeDsd then Fmt := DsdName(AMeta.SampleRate) + ' (native)'
  else if AInfo.DoP then Fmt := Format('%s kHz / %d bit (DoP)', [RateText(AInfo.OutRate), AInfo.OutBits])
  else
  begin
    Fmt := Format('%s kHz / %d bit', [RateText(AInfo.OutRate), AInfo.OutValidBits]);
    if AInfo.OutValidBits < AInfo.OutBits then Fmt := Fmt + Format(' (in %d)', [AInfo.OutBits]);
  end;
  if ADeviceName <> '' then S2 := Api + '  ·  ' + ADeviceName + '  ·  ' + Fmt else S2 := Api + '  ·  ' + Fmt;
  P.AddStage(icSpeaker, 'Output', S2, stNeutral);
  { summary }
  if AInfo.BitPerfect then
  begin
    if APaused then P.SetSummary('Bit-perfect  -  paused', stTransparent)
    else P.SetSummary('Bit-perfect  -  the DAC receives the file''s samples unchanged', stTransparent);
  end
  else if APaused then P.SetSummary('Processed  -  paused', stModified)
  else P.SetSummary('Processed  -  not bit-perfect', stModified);
end;

function CreateSignalPathDemo(AOwner: TComponent): TAuForm;
var
  Bg: TAuPanel;
  P: TAuSignalPath;
begin
  Result := TAuForm.CreateNew(AOwner);
  Result.BorderStyle := bsNone;
  Bg := TAuPanel.Create(Result);
  Bg.Parent := Result;
  Bg.Align := alClient;
  Bg.BackRole := crCard;
  Bg.BorderSides := 0;
  P := TAuSignalPath.Create(Result);
  P.Parent := Bg;
  P.Align := alClient;
  BuildDemoSignalPath(P);
  Result.ClientWidth := S(SIGNAL_PATH_W);
  Result.ClientHeight := P.PreferredHeight;
end;

procedure BuildDemoSignalPath(P: TAuSignalPath);
begin
  P.ClearStages;
  P.SetSummary('Processed  -  not bit-perfect', stModified);
  P.AddStage(icDocument, 'Source file', 'DSF  ·  DSD64  ·  1 bit  ·  2.8224 MHz  ·  stereo', stNeutral);
  P.AddStage(icDisc, 'DSD to PCM', 'Decimation to 176.4 kHz  ·  +6.00 dB (SACD reference)  ·  low-pass', stModified);
  P.AddStage(icSliders, 'ReplayGain', 'Album gain -3.20 dB', stModified);
  P.AddStage(icEqualizer, 'Tone control', 'Bass ' + ToneText(30, 120) + '  ·  Mid ' + ToneText(0, 1000) + '  ·  Treble ' + ToneText(-20, 10000), stModified);
  P.AddStage(icWave, 'Resampler', '176.4 -> 352.8 kHz  ·  Linear phase  ·  Very high (28-bit precision)', stModified);
  P.AddStage(icVolume1, 'Volume', 'Digital -6.0 dB  (71 %)', stModified);
  P.AddStage(icSliders, 'Dither', 'TPDF to 24 bit', stModified);
  P.AddStage(icSpeaker, 'Output', 'WASAPI exclusive  ·  Speakers (USB DAC)  ·  352.8 kHz / 24 bit (in 32)', stNeutral);
end;

end.
