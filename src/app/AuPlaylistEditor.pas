unit AuPlaylistEditor;

{ ==============================================================================
  AulumicNS - AuPlaylistEditor
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Playlist Editor:
  the name, the grouping and the two formats of a playlist ("Use Global
  Preferences" = the defaults of Preferences > Playlists); for an
  auto-playlist also the rules: a ready-made template or own rules made
  with the query builder (tag, operator, value; a track must match all
  rules, OR in a value gives alternatives).
  The playlists are kept in uPlaylistStore, so a name only has to
  be new and not "Default" (no file name rules).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms, uPlaylistStore;

{ The dialog, shown modal: AGroupMode -1 and '' formats
  are the defaults; AAuto shows the rules (AQuery: rules separated by ';').
  AStore checks that the name is free (AEditing: the old name may stay). }
function EditPlaylistDialog(AOwner: TComponent; AStore: TPlaylistStore; var AName: string;
  var AGroupMode: Integer; var AHeaderFmt, ATrackFmt, AQuery: string; AAuto, AEditing: Boolean): Boolean;
{ the dialog, not shown (screenshot mode) }
function CreatePlaylistEditorForm(AOwner: TComponent; const AName: string; AGroupMode: Integer;
  const AHeaderFmt, ATrackFmt, AQuery: string; AAuto, AEditing: Boolean): TAuForm;

implementation

uses
  uAppConsts, uAppStrings, uSettingsManager, uTagParser, uOSUtils;

type
  { TPlaylistEditorForm }

  TPlaylistEditorForm = class(TAuForm)
  private
    FStore: TPlaylistStore;
    FAuto: Boolean;
    FOriginalName: string;
    FTags: TTagDefArray;
    FRules: TStringList;
    FCustomCache: string;
    FName: TAuEdit;
    FGrouping, FHeaderFmt, FTrackFmt: TAuCombo;
    FHeaderCap: TAuLabel;
    FTemplate, FField, FOperator: TAuCombo;
    FValue: TAuEdit;
    FRuleList: TAuListView;
    FBtnAdd, FBtnRemove, FBtnHelp, FBtnOk: TAuButton;
    // the parent of the content: the body, or for an
    // auto-playlist a scroll box (the editor is ~726 high: too much for
    // 1920 x 1080 at 150 % or 1366 x 768); OK / Cancel stay below it
    FContent: TWinControl;
    FScroll: TAuScrollBox;
    function SettingRow(const ACaption, ADesc: string; Y, W: Integer; out ACap: TAuLabel): Integer;
    procedure RuleCell(Sender: TObject; Row, Col: Integer; var AText: string);
    procedure RuleSel(Sender: TObject);
    procedure RuleKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure GroupingChange(Sender: TObject);
    procedure TemplateChange(Sender: TObject);
    procedure FieldChange(Sender: TObject);
    procedure ValueChange(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure HelpClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure LoadRuleIntoInputs(const ARule: string);
    function TryAddRule: Boolean;
    function ValidateInput: Boolean;
    procedure UpdateButtons;
    procedure UpdateHeaderFormatState;
    procedure RulesChanged;
  public
    constructor CreateEditor(AOwner: TComponent; const AName: string; AGroupMode: Integer;
      const AHeaderFmt, ATrackFmt, AQuery: string; AAuto, AEditing: Boolean);
    destructor Destroy; override;
    procedure GetValues(out AName: string; out AGroupMode: Integer; out AHeaderFmt, ATrackFmt, AQuery: string);
  end;

const
  DLG_W = 660;
  X0 = 28;
  RW = DLG_W - 2 * X0;
  CTRL_W = 300;

function EditPlaylistDialog(AOwner: TComponent; AStore: TPlaylistStore; var AName: string;
  var AGroupMode: Integer; var AHeaderFmt, ATrackFmt, AQuery: string; AAuto, AEditing: Boolean): Boolean;
var
  F: TPlaylistEditorForm;
begin
  F := TPlaylistEditorForm.CreateEditor(AOwner, AName, AGroupMode, AHeaderFmt, ATrackFmt, AQuery, AAuto, AEditing);
  try
    F.FStore := AStore;
    Result := F.ShowModal = mrOK;
    if Result then F.GetValues(AName, AGroupMode, AHeaderFmt, ATrackFmt, AQuery);
  finally
    F.Free;
  end;
end;

function CreatePlaylistEditorForm(AOwner: TComponent; const AName: string; AGroupMode: Integer;
  const AHeaderFmt, ATrackFmt, AQuery: string; AAuto, AEditing: Boolean): TAuForm;
begin
  Result := TPlaylistEditorForm.CreateEditor(AOwner, AName, AGroupMode, AHeaderFmt, ATrackFmt, AQuery,
    AAuto, AEditing);
end;

{ ---- TPlaylistEditorForm ---- }

{ a setting's name and description at (X0, Y), W wide; the height }
function TPlaylistEditorForm.SettingRow(const ACaption, ADesc: string; Y, W: Integer; out ACap: TAuLabel): Integer;
var
  L: TAuLabel;
  DH: Integer;
begin
  ACap := AddLabel(FContent, ACaption, X0, Y, W, False);
  DH := 0;
  if ADesc <> '' then
  begin
    DH := Ceil(TextHeightWrapped(ADesc, UIFont(12), S(W)) / UIScale) + 2;
    L := AddLabel(FContent, ADesc, X0, Y + 22, W);
    L.FontSize := 12;
    L.WordWrap := True;
    L.VAlign := 0;
    L.Height := S(DH);
  end;
  Result := 22 + DH;
end;

constructor TPlaylistEditorForm.CreateEditor(AOwner: TComponent; const AName: string; AGroupMode: Integer;
  const AHeaderFmt, ATrackFmt, AQuery: string; AAuto, AEditing: Boolean);
var
  Y, H, I, TemplateIdx, BtnY, DlgH: Integer;
  Cap: TAuLabel;
  B: TAuButton;
  Bar: TAuPanel;
  Title: string;
begin
  FAuto := AAuto;
  if AAuto then DlgH := 700 else DlgH := 400;      // the first guess; set to the content below
  if AAuto then Title := StrUtils.IfThen(AEditing, TITLE_EDIT_AUTOPLAYLIST, TITLE_NEW_AUTOPLAYLIST)
  else Title := StrUtils.IfThen(AEditing, TITLE_EDIT_PLAYLIST, TITLE_NEW_PLAYLIST);
  CreateAu(AOwner, Title, DLG_W, DlgH);
  if AAuto then
  begin
    FScroll := TAuScrollBox.Create(Self);
    FScroll.Parent := Body;
    FScroll.SetBounds(0, 0, ClientWidth, S(DlgH));
    FContent := FScroll.Content;
  end
  else
    FContent := Body;
  if AAuto then HelpKeyword := 'Auto-playlist rules' else HelpKeyword := 'Playlist Editor';
  FRules := TStringList.Create;
  FOriginalName := AName;
  GetQueryableTags(FTags);

  Y := 18;
  H := SettingRow('Name', 'The name of the playlist.', Y, RW, Cap);
  Inc(Y, H + 8);
  FName := AddEdit(FContent, X0, Y, RW, AName);
  FName.Placeholder := 'Playlist name';
  { the Default playlist keeps its name }
  FName.Enabled := not (AEditing and SameText(AName, LBL_DEFAULT_PLAYLIST));
  Inc(Y, 32 + 18);

  { grouping and formats: the name on the left, the combo on the right }
  H := SettingRow('Grouping', 'How this playlist is grouped: By album, By folder or Flat list.', Y, RW - CTRL_W - 20, Cap);
  FGrouping := AddCombo(FContent, X0 + RW - CTRL_W, Y + Math.Max(0, (H - 32) div 2), CTRL_W,
    [LBL_USE_GLOBAL_PREFS, LBL_BY_ALBUM, LBL_BY_FOLDER, LBL_FLAT_LIST], 0);
  FGrouping.OnChange := @GroupingChange;
  Inc(Y, Math.Max(H, 32) + 16);
  H := SettingRow('Album header format', 'Layout of the album headers (only when grouped By album).', Y,
    RW - CTRL_W - 20, FHeaderCap);
  FHeaderFmt := AddCombo(FContent, X0 + RW - CTRL_W, Y + Math.Max(0, (H - 32) div 2), CTRL_W, [LBL_USE_GLOBAL_PREFS], 0);
  for I := 0 to High(HEADER_FORMAT_OPTIONS) do
    if HEADER_FORMAT_OPTIONS[I].DataStr <> '' then FHeaderFmt.Items.Add(HEADER_FORMAT_OPTIONS[I].DisplayName);
  Inc(Y, Math.Max(H, 32) + 16);
  H := SettingRow('Track format', 'Layout of the tracks in this playlist.', Y, RW - CTRL_W - 20, Cap);
  FTrackFmt := AddCombo(FContent, X0 + RW - CTRL_W, Y + Math.Max(0, (H - 32) div 2), CTRL_W, [LBL_USE_GLOBAL_PREFS], 0);
  for I := 0 to High(TRACK_FORMAT_OPTIONS) do
    if TRACK_FORMAT_OPTIONS[I].DataStr <> '' then FTrackFmt.Items.Add(TRACK_FORMAT_OPTIONS[I].DisplayName);
  Inc(Y, Math.Max(H, 32));

  if AAuto then
  begin
    Inc(Y, 22);
    Bar := TAuPanel.Create(Self);
    Bar.Parent := FContent;
    Bar.BackRole := crBorder;
    Bar.BorderSides := 0;
    Bar.SetBounds(S(X0), S(Y), S(RW), Math.Max(1, S(1)));
    Inc(Y, 18);
    with AddLabel(FContent, 'RULES', X0, Y, RW, False) do
    begin
      FontSize := 11;
      Bold := True;
      TextRole := crAccent;
    end;
    Inc(Y, 28);
    H := SettingRow('Smart rule template', 'Choose a ready-made set of rules, or make your own.', Y,
      RW - CTRL_W - 20, Cap);
    FTemplate := AddCombo(FContent, X0 + RW - CTRL_W, Y + Math.Max(0, (H - 32) div 2), CTRL_W, [LBL_CUSTOM_PREFS], 0);
    TemplateIdx := 0;
    for I := Low(PREBAKED_QUERIES) + 1 to High(PREBAKED_QUERIES) do
    begin
      FTemplate.Items.Add(PREBAKED_QUERIES[I].DisplayName);
      if SameText(AQuery, PREBAKED_QUERIES[I].DataStr) then TemplateIdx := I;
    end;
    Inc(Y, Math.Max(H, 32) + 14);
    FRuleList := TAuListView.Create(Self);
    FRuleList.Parent := FContent;
    FRuleList.SetBounds(S(X0), S(Y), S(RW), S(132));
    FRuleList.ShowHeader := False;
    FRuleList.MultiSelect := False;
    FRuleList.RowMenu := False;
    FRuleList.AutoFit := True;
    FRuleList.RowHeight := S(30);
    FRuleList.AddColumn('Rule', 300, 0, True);
    FRuleList.BackRole := crCard;
    FRuleList.EmptyText := 'No rules yet. Choose a tag, an operator and a value below, then Add.';
    FRuleList.OnGetCell := @RuleCell;
    FRuleList.OnSelChange := @RuleSel;
    FRuleList.OnKeyDown := @RuleKey;
    Inc(Y, 132 + 12);
    { the query builder: tag, operator, value, Add }
    FField := AddCombo(FContent, X0, Y, 170, []);
    for I := 0 to High(FTags) do FField.Items.Add(FTags[I].FriendlyName);
    FField.Hint := 'The tag this rule checks.';
    FField.ShowHint := True;
    FField.OnChange := @FieldChange;
    FOperator := AddCombo(FContent, X0 + 178, Y, 130, []);
    FOperator.Hint := 'How the tag is compared with the value.';
    FOperator.ShowHint := True;
    FValue := AddEdit(FContent, X0 + 316, Y, RW - 316 - 100);
    FValue.Placeholder := 'Value';
    FValue.Hint := 'The value to compare with. Use OR (in capitals) for alternatives, e.g. Rock OR Jazz.';
    FValue.ShowHint := True;
    FValue.OnChange := @ValueChange;
    FBtnAdd := AddButton(FContent, 'Add', X0 + RW - 92, Y, 92, bkNormal, @AddClick);
    FBtnAdd.Icon := icPlus;
    FBtnAdd.Hint := 'Add this rule to the list.';
    FBtnAdd.ShowHint := True;
    Inc(Y, 32 + 8);
    with AddLabel(FContent, 'A track must match all rules. Use OR (in capitals) for alternatives, e.g. Rock OR Jazz; ' +
      'dates as 14d, 2w, 1m or 1y.', X0, Y, RW - 230) do
    begin
      FontSize := 12;
      WordWrap := True;
      VAlign := 0;
      Height := S(36);
      TextRole := crTextFaint;
    end;
    FBtnRemove := AddButton(FContent, 'Remove', X0 + RW - 92 - 8 - 112, Y, 112, bkNormal, @RemoveClick);
    FBtnRemove.Icon := icTrash;
    FBtnRemove.Hint := 'Remove the selected rule (Del).';
    FBtnRemove.ShowHint := True;
    FBtnHelp := AddButton(FContent, 'Rules', X0 + RW - 92, Y, 92, bkNormal, @HelpClick);
    FBtnHelp.Icon := icHelp;
    FBtnHelp.Hint := 'How the rules work.';
    FBtnHelp.ShowHint := True;
    FTemplate.ItemIndex := TemplateIdx;
    FTemplate.OnChange := @TemplateChange;
    if TemplateIdx = 0 then FCustomCache := AQuery;
    TemplateChange(nil);
    Inc(Y, 36);
  end;

  { the height follows the content; on a small screen the content of an
    auto-playlist scrolls above OK / Cancel }
  BtnY := Y + 28;
  DlgH := BtnY + 34 + 22;
  ClientHeight := S(DlgH) + TitleBar.Height;
  if AAuto then
  begin
    FitToWorkArea;
    BtnY := Math.Min(BtnY, Round(BodyHeight / UIScale) - 34 - 22);
    FScroll.SetBounds(0, 0, ClientWidth, S(BtnY - 14));
    FScroll.ContentHeight := S(Y + 8);
  end;
  B := AddButton(Self, 'Cancel', DLG_W - X0 - 2 * 110 - 10, BtnY, 110);
  B.ModalResult := mrCancel;
  FBtnOk := AddButton(Self, 'OK', DLG_W - X0 - 110, BtnY, 110, bkPrimary, @OkClick);
  DefaultButton := FBtnOk;

  { the values }
  if (AGroupMode >= 0) and (AGroupMode <= 2) then FGrouping.ItemIndex := AGroupMode + 1
  else FGrouping.ItemIndex := 0;
  FHeaderFmt.ItemIndex :=
    ComboRowOfOption(HEADER_FORMAT_OPTIONS, FormatOptionByData(HEADER_FORMAT_OPTIONS, AHeaderFmt)) + 1;
  FTrackFmt.ItemIndex :=
    ComboRowOfOption(TRACK_FORMAT_OPTIONS, FormatOptionByData(TRACK_FORMAT_OPTIONS, ATrackFmt)) + 1;
  UpdateHeaderFormatState;
  UpdateButtons;
  ActiveControl := FName;
  FName.SelectAll;
end;

destructor TPlaylistEditorForm.Destroy;
begin
  FRules.Free;
  inherited Destroy;
end;

procedure TPlaylistEditorForm.GetValues(out AName: string; out AGroupMode: Integer;
  out AHeaderFmt, ATrackFmt, AQuery: string);
var
  I: Integer;
begin
  AName := CleanPlaylistName(FName.Text);
  if FGrouping.ItemIndex <= 0 then AGroupMode := -1 else AGroupMode := FGrouping.ItemIndex - 1;
  AHeaderFmt := '';
  I := OptionOfComboRow(HEADER_FORMAT_OPTIONS, FHeaderFmt.ItemIndex - 1);
  if I >= 0 then AHeaderFmt := HEADER_FORMAT_OPTIONS[I].DataStr;
  ATrackFmt := '';
  I := OptionOfComboRow(TRACK_FORMAT_OPTIONS, FTrackFmt.ItemIndex - 1);
  if I >= 0 then ATrackFmt := TRACK_FORMAT_OPTIONS[I].DataStr;
  AQuery := '';
  if FAuto then
  begin
    if FTemplate.ItemIndex > 0 then AQuery := PREBAKED_QUERIES[FTemplate.ItemIndex].DataStr
    else
      for I := 0 to FRules.Count - 1 do
      begin
        if AQuery <> '' then AQuery := AQuery + ';';
        AQuery := AQuery + Trim(FRules[I]);
      end;
  end;
end;

{ the album header format only matters when the effective grouping is By Album }
procedure TPlaylistEditorForm.UpdateHeaderFormatState;
var
  G: Integer;
begin
  if FGrouping.ItemIndex <= 0 then G := AppSettings.Data.DefaultGroupingMode
  else G := FGrouping.ItemIndex - 1;
  FHeaderFmt.Enabled := G = 0;
  if FHeaderFmt.Enabled then FHeaderCap.TextRole := crText else FHeaderCap.TextRole := crTextFaint;
  FHeaderFmt.Invalidate;
end;

procedure TPlaylistEditorForm.GroupingChange(Sender: TObject);
begin
  UpdateHeaderFormatState;
end;

procedure TPlaylistEditorForm.UpdateButtons;
var
  Custom: Boolean;
begin
  if FBtnOk = nil then Exit;          // still being built
  if not FAuto then
  begin
    FBtnOk.Enabled := True;
    Exit;
  end;
  Custom := FTemplate.ItemIndex = 0;
  if not Custom then FBtnOk.Enabled := True
  else FBtnOk.Enabled := (FRules.Count > 0) or (Trim(FValue.Text) <> '');
  FBtnAdd.Enabled := Custom and (Trim(FValue.Text) <> '');
  FBtnRemove.Enabled := Custom and (FRuleList.SelCount > 0);
  FField.Enabled := Custom;
  FOperator.Enabled := Custom;
  FValue.Enabled := Custom;
  FRuleList.Enabled := Custom;
  FRuleList.Invalidate;
end;

procedure TPlaylistEditorForm.RulesChanged;
begin
  FRuleList.RowCount := FRules.Count;
  FRuleList.Changed;
  UpdateButtons;
end;

procedure TPlaylistEditorForm.RuleCell(Sender: TObject; Row, Col: Integer; var AText: string);
begin
  if (Row >= 0) and (Row < FRules.Count) then AText := FRules[Row];
end;

procedure TPlaylistEditorForm.RuleSel(Sender: TObject);
var
  R: Integer;
begin
  R := FRuleList.FocusedRow;
  if (R >= 0) and (R < FRules.Count) and FRuleList.Selected[R] then LoadRuleIntoInputs(FRules[R]);
  UpdateButtons;
end;

procedure TPlaylistEditorForm.RuleKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_DELETE) and (Shift = []) then
  begin
    Key := 0;
    RemoveClick(nil);
  end;
end;

procedure TPlaylistEditorForm.ValueChange(Sender: TObject);
begin
  UpdateButtons;
end;

{ the operators of the tag's kind }
procedure TPlaylistEditorForm.FieldChange(Sender: TObject);
var
  DType: TTagDataType;
begin
  if (FField.ItemIndex < 0) or (FField.ItemIndex > High(FTags)) then Exit;
  DType := FTags[FField.ItemIndex].DataType;
  FOperator.Items.Clear;
  case DType of
    dtString:
      begin
        FOperator.Items.Add(QUERY_OP_IS);
        FOperator.Items.Add(QUERY_OP_HAS);
        FOperator.Items.Add(QUERY_OP_NOT_HAS);
        FOperator.Items.Add(QUERY_OP_STARTSWITH);
      end;
    dtNumeric:
      begin
        FOperator.Items.Add('=');
        FOperator.Items.Add('>');
        FOperator.Items.Add('<');
        FOperator.Items.Add('>=');
        FOperator.Items.Add('<=');
        FOperator.Items.Add('<>');
      end;
    dtDate:
      FOperator.Items.Add(QUERY_OP_IN_LAST);
  end;
  FOperator.ItemIndex := -1;
  FOperator.ItemIndex := 0;
end;

{ "%tag% OP value" back into the builder }
procedure TPlaylistEditorForm.LoadRuleIntoInputs(const ARule: string);
var
  S, Token, Op, Val: string;
  I, P: Integer;
begin
  S := Trim(ARule);
  if not StartsText('%', S) then Exit;
  P := PosEx('%', S, 2);
  if P <= 0 then Exit;
  Token := LowerCase(Copy(S, 2, P - 2));
  S := Trim(Copy(S, P + 1, MaxInt));
  if GetTagIDByToken(Token) = tiUnknown then Exit;
  for I := 0 to High(FTags) do
    if SameText(FTags[I].TagStr, Token) then
    begin
      FField.ItemIndex := I;
      FieldChange(nil);
      Break;
    end;
  Op := '';
  for I := 0 to FOperator.Items.Count - 1 do
    if (StartsText(FOperator.Items[I] + ' ', S) or SameText(S, FOperator.Items[I])) and
       (Length(FOperator.Items[I]) > Length(Op)) then
    begin
      Op := FOperator.Items[I];
      FOperator.ItemIndex := I;
    end;
  if Op <> '' then
  begin
    Val := Trim(Copy(S, Length(Op) + 1, MaxInt));
    FValue.Text := Val;
  end;
end;

{ the template: its rules, or the own rules again ([Custom]) }
procedure TPlaylistEditorForm.TemplateChange(Sender: TObject);
var
  Custom: Boolean;
  L: TStringList;
  I: Integer;
begin
  Custom := FTemplate.ItemIndex = 0;
  if (not Custom) and (FRules.Count > 0) and (FCustomCache = '') then
  begin
    FCustomCache := '';
    for I := 0 to FRules.Count - 1 do
    begin
      if FCustomCache <> '' then FCustomCache := FCustomCache + ';';
      FCustomCache := FCustomCache + FRules[I];
    end;
  end;
  FRules.Clear;
  L := TStringList.Create;
  try
    L.Delimiter := ';';
    L.StrictDelimiter := True;
    if Custom then
    begin
      L.DelimitedText := FCustomCache;
      FCustomCache := '';
    end
    else
      L.DelimitedText := PREBAKED_QUERIES[FTemplate.ItemIndex].DataStr;
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) <> '' then FRules.Add(Trim(L[I]));
  finally
    L.Free;
  end;
  RulesChanged;
  if FRules.Count > 0 then
  begin
    FRuleList.SelectOnly(0);
    LoadRuleIntoInputs(FRules[0]);
  end
  else
  begin
    if FField.Items.Count > 0 then
    begin
      FField.ItemIndex := 0;
      FieldChange(nil);
    end;
    FValue.Text := '';
  end;
  UpdateButtons;
end;

{ the rule of the builder into the list: False when
  the value is not valid for the tag; True also when there is nothing to add }
function TPlaylistEditorForm.TryAddRule: Boolean;
var
  ValStr, Rule, Cleaned, Rem, Sub: string;
  DType: TTagDataType;
  SL: TStringList;
  I, P: Integer;
begin
  Result := True;
  if (FField.ItemIndex < 0) or (FOperator.ItemIndex < 0) then Exit;
  ValStr := Trim(FValue.Text);
  if ValStr = '' then Exit;
  Result := False;
  ValStr := StringReplace(ValStr, '|', ' OR ', [rfReplaceAll]);
  ValStr := StringReplace(ValStr, ';', ' OR ', [rfReplaceAll]);
  if Pos(' OR ', UpperCase(ValStr)) > 0 then
  begin
    SL := TStringList.Create;
    try
      SL.CaseSensitive := False;
      SL.Sorted := True;
      SL.Duplicates := dupIgnore;
      Rem := ValStr;
      while True do
      begin
        P := Pos(' OR ', UpperCase(Rem));
        if P > 0 then
        begin
          Sub := Trim(Copy(Rem, 1, P - 1));
          if Sub <> '' then SL.Add(Sub);
          Rem := Trim(Copy(Rem, P + 4, Length(Rem)));
        end
        else
        begin
          if Trim(Rem) <> '' then SL.Add(Trim(Rem));
          Break;
        end;
      end;
      Cleaned := '';
      for I := 0 to SL.Count - 1 do
      begin
        if Cleaned <> '' then Cleaned := Cleaned + ' OR ';
        Cleaned := Cleaned + SL[I];
      end;
      ValStr := Cleaned;
    finally
      SL.Free;
    end;
  end;
  DType := FTags[FField.ItemIndex].DataType;
  if DType = dtNumeric then
  begin
    Rem := ValStr;
    while True do
    begin
      P := Pos(' OR ', UpperCase(Rem));
      if P > 0 then
      begin
        Sub := Trim(Copy(Rem, 1, P - 1));
        Rem := Trim(Copy(Rem, P + 4, Length(Rem)));
      end
      else
      begin
        Sub := Trim(Rem);
        Rem := '';
      end;
      if (Sub <> '') and (StrToInt64Def(Sub, -1) = -1) then
      begin
        AuMessage(ERR_EDIT_VALIDNUMBER, amWarning, abOK, TITLE_WARNING);
        Exit;
      end;
      if Rem = '' then Break;
    end;
  end
  else if DType = dtDate then
  begin
    if (Length(ValStr) < 2) or (StrToIntDef(Trim(Copy(ValStr, 1, Length(ValStr) - 1)), -1) <= 0) or
       not (LowerCase(ValStr)[Length(ValStr)] in ['d', 'w', 'm', 'y']) then
    begin
      AuMessage(ERR_EDIT_VALIDDATE, amWarning, abOK, TITLE_WARNING);
      Exit;
    end;
  end;
  Rule := '%' + FTags[FField.ItemIndex].TagStr + '% ' + FOperator.Text + ' ' + ValStr;
  if FRules.IndexOf(Rule) < 0 then
  begin
    FRules.Add(Rule);
    FValue.Text := '';
    RulesChanged;
  end;
  Result := True;
end;

procedure TPlaylistEditorForm.AddClick(Sender: TObject);
begin
  if TryAddRule and FValue.CanFocus then FValue.SetFocus;
end;

procedure TPlaylistEditorForm.RemoveClick(Sender: TObject);
var
  R: Integer;
begin
  if not FBtnRemove.Enabled then Exit;
  R := FRuleList.FocusedRow;
  if (R < 0) or (R >= FRules.Count) or not FRuleList.Selected[R] then Exit;
  FRules.Delete(R);
  FRuleList.ClearSelection;
  RulesChanged;
end;

procedure TPlaylistEditorForm.HelpClick(Sender: TObject);
begin
  AuMessage('An auto-playlist shows the library tracks that match all of its rules. A rule is' + LineEnding +
    '  %tag% OPERATOR value' + LineEnding + LineEnding +
    'Text tags: IS, HAS, NOT HAS, STARTSWITH (not case sensitive).' + LineEnding +
    'Numbers (year, rating, play count, bit depth, ...): = > < >= <= <>.' + LineEnding +
    'Dates (added, last played): IN LAST 14d / 2w / 1m / 1y.' + LineEnding + LineEnding +
    'OR (in capitals) gives alternatives: %genre% IS Rock OR Jazz.' + LineEnding +
    'Examples: %rating% >= 4;  %added% IN LAST 30d;  %bitdepth% >= 24.',
    amInfo, abOK, 'Auto-playlist rules');
end;

{ a name, not "Default", not taken; a rule still
  in the builder is added; own rules need at least one }
function TPlaylistEditorForm.ValidateInput: Boolean;
var
  N: string;
begin
  Result := False;
  N := CleanPlaylistName(FName.Text);
  if N = '' then
  begin
    AuMessage(ERR_EDIT_EMPTYNAME, amWarning, abOK, TITLE_WARNING);
    if FName.CanFocus then FName.SetFocus;
    Exit;
  end;
  if SameText(N, LBL_DEFAULT_PLAYLIST) and not SameText(FOriginalName, LBL_DEFAULT_PLAYLIST) then
  begin
    AuMessage(SafeFormat(FMT_ERR_PLAYEDIT_RESERVED, [LBL_DEFAULT_PLAYLIST]), amWarning, abOK, TITLE_WARNING);
    if FName.CanFocus then FName.SetFocus;
    Exit;
  end;
  if (FStore <> nil) and not SameText(N, FOriginalName) and (FStore.Find(N) <> nil) then
  begin
    AuMessage(SafeFormat(FMT_ERR_NAME_DUPLICATE, [N]), amWarning, abOK, TITLE_WARNING);
    if FName.CanFocus then FName.SetFocus;
    Exit;
  end;
  if FAuto and (FTemplate.ItemIndex = 0) then
  begin
    if not TryAddRule then
    begin
      if FValue.CanFocus then FValue.SetFocus;
      Exit;
    end;
    if FRules.Count = 0 then
    begin
      if FValue.CanFocus then FValue.SetFocus;
      Exit;
    end;
  end;
  FName.Text := N;
  Result := True;
end;

procedure TPlaylistEditorForm.OkClick(Sender: TObject);
begin
  if FBtnOk.Enabled and ValidateInput then ModalResult := mrOK;
end;

end.
