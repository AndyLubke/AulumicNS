unit AuFormatBoxes;

{$mode objfpc}{$H+}

{ ==============================================================================
  AulumicNS - AuFormatBoxes
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The row a playlist format is chosen with: four drop-downs, each one field
  or "(nothing)", in the order of the line, and under them the line a
  made-up track gets (uPlaylistFormat: the fields and their format text).

  With no field chosen Format is '' and the preview shows the format given
  with SetEmpty behind its prefix ("As in Preferences: ..."): what the caller
  falls back to. A text that is no field format is kept as it is until a box
  is changed.

  ChooseFormatsDialog is the small window with both rows for one playlist
  (the playlist's View menu > Choose fields).
  =============================================================================}

interface

uses
  Classes, SysUtils, Controls, Forms, AuTheme, AuControls, AuForms, uPlaylistFormat;

const
  { the height of the row with its preview line (unscaled) }
  FORMAT_BOXES_H = 56;

type
  TFormatBoxes = class(TComponent)
  private
    FKind: TFmtKind;
    FChoices: TFmtFieldArray;
    FCombos: array[0..FMT_SLOTS - 1] of TAuCombo;
    FPreview: TAuLabel;
    FEmptyPrefix, FEmptyFormat: string;
    FKept: string;               // a text that is no field format, shown as no fields
    FLoading: Boolean;
    FEnabled: Boolean;
    FOnChange: TNotifyEvent;
    function GetFormat: string;
    procedure SetFormat(const AValue: string);
    procedure SetEnabled(AValue: Boolean);
    function GetFields: TFmtFields;
    procedure ComboChange(Sender: TObject);
    procedure UpdatePreview;
  public
    { X, Y, W unscaled, on AParent; the row is FORMAT_BOXES_H high }
    constructor CreateBoxes(AForm: TAuForm; AParent: TWinControl; AKind: TFmtKind; X, Y, W: Integer);
    { what the preview shows while no field is chosen }
    procedure SetEmpty(const APrefix, AFormat: string);
    { puts a field into a box, as a pick from its list does }
    procedure Choose(ASlot: Integer; AField: TFmtField);
    function PreviewText: string;
    function FirstBox: TAuCombo;
    property Format: string read GetFormat write SetFormat;
    property Enabled: Boolean read FEnabled write SetEnabled;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

{ the line a made-up track gets with a format }
function FormatPreview(const AFmt: string): string;

{ The two formats of one playlist, shown modal; '' = as in Preferences
  (ADefHeader, ADefTrack: what that is). A row whose format the playlist's
  grouping does not use is shown but cannot be changed. }
function ChooseFormatsDialog(AOwner: TComponent; const APlaylist: string;
  var AHeaderFmt, ATrackFmt: string; const ADefHeader, ADefTrack: string;
  AHeaderUsed, ATrackUsed: Boolean): Boolean;
{ the dialog, not shown; AHeader / ATrack: its two rows }
function CreateFormatsForm(AOwner: TComponent; const APlaylist, AHeaderFmt, ATrackFmt,
  ADefHeader, ADefTrack: string; AHeaderUsed, ATrackUsed: Boolean;
  out AHeader, ATrack: TFormatBoxes): TAuForm;
implementation

uses
  ALMetadata, uTagParser, uAppStrings;

const
  BOX_GAP = 8;
  BOX_H = 32;
  DLG_W = 640;
  DLG_X = 28;

function CreateFormatsForm(AOwner: TComponent; const APlaylist, AHeaderFmt, ATrackFmt,
  ADefHeader, ADefTrack: string; AHeaderUsed, ATrackUsed: Boolean;
  out AHeader, ATrack: TFormatBoxes): TAuForm;
var
  F: TAuForm;
  L: TAuLabel;
  B: TAuButton;
  Y, RW: Integer;
begin
  F := TAuForm.CreateAu(AOwner, 'Formats: ' + APlaylist, DLG_W, 300);
  F.BorderIcons := [biSystemMenu];
  F.Position := poOwnerFormCenter;
  F.HelpKeyword := 'Playlist Editor';
  RW := DLG_W - 2 * DLG_X;
  Y := 18;
  L := F.AddLabel(F, 'Album header', DLG_X, Y, RW, False);
  if not AHeaderUsed then L.TextRole := crTextFaint;
  Inc(Y, 26);
  AHeader := TFormatBoxes.CreateBoxes(F, F.Body, fkHeader, DLG_X, Y, RW);
  AHeader.SetEmpty(LBL_FORMAT_AS_PREFS, ADefHeader);
  AHeader.Format := AHeaderFmt;
  AHeader.Enabled := AHeaderUsed;
  Inc(Y, FORMAT_BOXES_H + 14);
  L := F.AddLabel(F, 'Track', DLG_X, Y, RW, False);
  if not ATrackUsed then L.TextRole := crTextFaint;
  Inc(Y, 26);
  ATrack := TFormatBoxes.CreateBoxes(F, F.Body, fkTrack, DLG_X, Y, RW);
  ATrack.SetEmpty(LBL_FORMAT_AS_PREFS, ADefTrack);
  ATrack.Format := ATrackFmt;
  ATrack.Enabled := ATrackUsed;
  Inc(Y, FORMAT_BOXES_H + 10);
  L := F.AddLabel(F, 'Up to four fields, in the order of the line. With every box on (nothing), ' +
    'the playlist follows Preferences.', DLG_X, Y, RW, True);
  L.FontSize := 12;
  L.WordWrap := True;
  L.VAlign := 0;
  L.Height := S(36);
  Inc(Y, 36 + 14);
  F.ClientHeight := S(Y + 34 + 22) + F.TitleBar.Height;
  B := F.AddButton(F, 'Cancel', DLG_W - DLG_X - 2 * 110 - 10, Y, 110);
  B.ModalResult := mrCancel;
  B := F.AddButton(F, 'OK', DLG_W - DLG_X - 110, Y, 110, bkPrimary);
  B.ModalResult := mrOK;
  F.DefaultButton := B;
  if AHeaderUsed then F.ActiveControl := AHeader.FirstBox
  else if ATrackUsed then F.ActiveControl := ATrack.FirstBox;
  Result := F;
end;

function ChooseFormatsDialog(AOwner: TComponent; const APlaylist: string;
  var AHeaderFmt, ATrackFmt: string; const ADefHeader, ADefTrack: string;
  AHeaderUsed, ATrackUsed: Boolean): Boolean;
var
  F: TAuForm;
  H, T: TFormatBoxes;
begin
  F := CreateFormatsForm(AOwner, APlaylist, AHeaderFmt, ATrackFmt, ADefHeader, ADefTrack,
    AHeaderUsed, ATrackUsed, H, T);
  try
    Result := F.ShowModal = mrOK;
    if Result then
    begin
      AHeaderFmt := H.Format;
      ATrackFmt := T.Format;
    end;
  finally
    F.Free;
  end;
end;
function FormatPreview(const AFmt: string): string;
var
  Ctx: TTrackFormatContext;
begin
  Ctx := Default(TTrackFormatContext);
  Ctx.Meta.Title := 'First Snow';
  Ctx.Meta.Artist := 'Mara Lindqvist';
  Ctx.Meta.AlbumArtist := 'Mara Lindqvist';
  Ctx.Meta.Album := 'Northern Lights';
  Ctx.Meta.Genre := 'Jazz';
  Ctx.Meta.Composer := 'Erik Sandvik';
  Ctx.Meta.Year := 2019;
  Ctx.Meta.BitDepth := 24;
  Ctx.Meta.SampleRate := 96000;
  Ctx.Meta.Channels := 2;
  Ctx.FilePath := 'C:\Music\Northern Lights\01 - First Snow.flac';
  Result := TidyFormatted(FormatTrackInfo(AFmt, Ctx));
end;

constructor TFormatBoxes.CreateBoxes(AForm: TAuForm; AParent: TWinControl; AKind: TFmtKind; X, Y, W: Integer);
var
  I, J, BW: Integer;
begin
  inherited Create(AForm);
  FKind := AKind;
  FEnabled := True;
  FChoices := FieldChoices(AKind);
  FEmptyFormat := FMT_DEFAULT[AKind];
  BW := (W - (FMT_SLOTS - 1) * BOX_GAP) div FMT_SLOTS;
  FLoading := True;
  try
    for I := 0 to FMT_SLOTS - 1 do
    begin
      FCombos[I] := AForm.AddCombo(AParent, X + I * (BW + BOX_GAP), Y, BW, [FMT_FIELD_NAMES[ffNone]], 0);
      for J := 0 to High(FChoices) do FCombos[I].Items.Add(FMT_FIELD_NAMES[FChoices[J]]);
      FCombos[I].OnChange := @ComboChange;
    end;
  finally
    FLoading := False;
  end;
  FPreview := AForm.AddLabel(AParent, '', X, Y + BOX_H + 2, W, True);
  FPreview.FontSize := 12;
  FPreview.Height := S(FORMAT_BOXES_H - BOX_H - 2);
  UpdatePreview;
end;

function TFormatBoxes.FirstBox: TAuCombo;
begin
  Result := FCombos[0];
end;

function TFormatBoxes.GetFields: TFmtFields;
var
  I, K: Integer;
begin
  for I := 0 to FMT_SLOTS - 1 do
  begin
    K := FCombos[I].ItemIndex - 1;
    if (K >= 0) and (K <= High(FChoices)) then Result[I] := FChoices[K] else Result[I] := ffNone;
  end;
end;

function TFormatBoxes.GetFormat: string;
begin
  Result := FieldsToFormat(FKind, GetFields);
  if Result = '' then Result := FKept;
end;

procedure TFormatBoxes.SetFormat(const AValue: string);
var
  F: TFmtFields;
  I, J, K: Integer;
begin
  FKept := '';
  if not FormatToFields(FKind, AValue, F) then FKept := AValue;   // F is empty then
  FLoading := True;
  try
    for I := 0 to FMT_SLOTS - 1 do
    begin
      K := 0;
      for J := 0 to High(FChoices) do
        if FChoices[J] = F[I] then K := J + 1;
      FCombos[I].ItemIndex := K;
      FCombos[I].Invalidate;
    end;
  finally
    FLoading := False;
  end;
  UpdatePreview;
end;

procedure TFormatBoxes.SetEmpty(const APrefix, AFormat: string);
begin
  FEmptyPrefix := APrefix;
  FEmptyFormat := AFormat;
  UpdatePreview;
end;

procedure TFormatBoxes.SetEnabled(AValue: Boolean);
var
  I: Integer;
begin
  if FEnabled = AValue then Exit;
  FEnabled := AValue;
  for I := 0 to FMT_SLOTS - 1 do
  begin
    FCombos[I].Enabled := AValue;
    FCombos[I].Invalidate;
  end;
  UpdatePreview;
end;

procedure TFormatBoxes.Choose(ASlot: Integer; AField: TFmtField);
var
  J, K: Integer;
begin
  if (ASlot < 0) or (ASlot >= FMT_SLOTS) then Exit;
  K := 0;
  for J := 0 to High(FChoices) do
    if FChoices[J] = AField then K := J + 1;
  FLoading := True;
  try
    FCombos[ASlot].ItemIndex := K;
    FCombos[ASlot].Invalidate;
  finally
    FLoading := False;
  end;
  ComboChange(FCombos[ASlot]);
end;

procedure TFormatBoxes.ComboChange(Sender: TObject);
begin
  if FLoading then Exit;
  FKept := '';
  UpdatePreview;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TFormatBoxes.PreviewText: string;
var
  Fmt: string;
begin
  Fmt := GetFormat;
  if Fmt <> '' then Result := FormatPreview(Fmt)
  else Result := FEmptyPrefix + FormatPreview(FEmptyFormat);
end;

procedure TFormatBoxes.UpdatePreview;
begin
  if FPreview = nil then Exit;
  if FEnabled then FPreview.TextRole := crTextDim else FPreview.TextRole := crTextFaint;
  FPreview.Caption := PreviewText;
  FPreview.Invalidate;
end;

end.
