unit AuPlaylistManager;

{ ==============================================================================
  AulumicNS - AuPlaylistManager
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Playlist Manager (Main menu >
  Playlist > Playlist Manager..., Alt+P, the Edit button above the
  playlist): all playlists - the Default playlist, your playlists, the
  auto-playlists (funnel) - with
    New... (Ctrl+N), New Auto-playlist..., Edit... (F2, the Playlist Editor),
    Remove (Del), Import... (M3U / M3U8), Export... (M3U8), Close.
  Double click or Enter shows the playlist and closes the manager.
  The changes go straight into the playlist store (uPlaylistStore);
  the main window learns about renames, the playlists whose
  view or rules changed and the one to show (TPlaylistManagerResult).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, Dialogs, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms, uPlaylistStore;

type
  { an M3U file into a new playlist: its name ('' = failed; AError says why) }
  TPlImportEvent = function(const AFile: string; out AError: string): string of object;
  { a playlist as an M3U8 file }
  TPlExportEvent = function(const AName, AFile: string; out AError: string): Boolean of object;

  TPlaylistManagerResult = record
    Activated: string;            // double click / Enter: show this one
    RenamedFrom, RenamedTo: TStringList;
    Changed: TStringList;         // view, rules or tracks changed (names after renames)
  end;

{ AResult's lists are created by the caller }
procedure ShowPlaylistManager(AOwner: TComponent; AStore: TPlaylistStore; const ASelect: string;
  AOnImport: TPlImportEvent; AOnExport: TPlExportEvent; var AResult: TPlaylistManagerResult);
{ the dialog, not shown (screenshot mode) }
function CreatePlaylistManagerForm(AOwner: TComponent; AStore: TPlaylistStore; const ASelect: string): TAuForm;

implementation

uses
  uAppConsts, uAppStrings, uOSUtils, AuPlaylistEditor;

type
  { TPlaylistManagerForm }

  TPlaylistManagerForm = class(TAuForm)
  private
    FStore: TPlaylistStore;
    FNames: TStringList;            // Objects = Ord(TPlaylistKind)
    FList: TAuListView;
    FBtnNew, FBtnNewAuto, FBtnEdit, FBtnRemove, FBtnImport, FBtnExport: TAuButton;
    FOnImport: TPlImportEvent;
    FOnExport: TPlExportEvent;
    FResult: ^TPlaylistManagerResult;
    { the list again; ASelect is selected, or without it the row AElseRow }
    procedure LoadNames(const ASelect: string; AElseRow: Integer = 0);
    function SelectedName: string;
    function KindOf(Row: Integer): TPlaylistKind;
    procedure UpdateButtons;
    procedure RecordRename(const AOld, ANew: string);
    procedure RecordChange(const AName: string);
    function RowName(Sender: TObject; Row: Integer): string;
    procedure DrawRow(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure SelChange(Sender: TObject);
    procedure ListActivate(Sender: TObject; Row: Integer);
    procedure NewClick(Sender: TObject);
    procedure NewAutoClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure NewPlaylist(AAuto: Boolean);
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateManager(AOwner: TComponent; AStore: TPlaylistStore; const ASelect: string);
    destructor Destroy; override;
  end;

const
  DLG_W = 720;
  DLG_H = 480;
  SIDE_W = 190;

procedure ShowPlaylistManager(AOwner: TComponent; AStore: TPlaylistStore; const ASelect: string;
  AOnImport: TPlImportEvent; AOnExport: TPlExportEvent; var AResult: TPlaylistManagerResult);
var
  F: TPlaylistManagerForm;
begin
  F := TPlaylistManagerForm.CreateManager(AOwner, AStore, ASelect);
  try
    F.FOnImport := AOnImport;
    F.FOnExport := AOnExport;
    F.FResult := @AResult;
    F.ShowModal;
  finally
    F.Free;
  end;
end;

function CreatePlaylistManagerForm(AOwner: TComponent; AStore: TPlaylistStore; const ASelect: string): TAuForm;
begin
  Result := TPlaylistManagerForm.CreateManager(AOwner, AStore, ASelect);
end;

{ ---- TPlaylistManagerForm ---- }

constructor TPlaylistManagerForm.CreateManager(AOwner: TComponent; AStore: TPlaylistStore; const ASelect: string);
var
  X, Y: Integer;
  B: TAuButton;

  function Btn(const ACaption, AHint: string; AIcon: TAuIcon; AClick: TNotifyEvent): TAuButton;
  begin
    Result := AddButton(Self, ACaption, X, Y, SIDE_W, bkNormal, AClick);
    Result.Icon := AIcon;
    Result.Hint := AHint;
    Result.ShowHint := True;
    Inc(Y, 32 + 8);
  end;

begin
  CreateAu(AOwner, 'Playlist Manager', DLG_W, DLG_H);
  HelpKeyword := 'Playlist Manager';
  FStore := AStore;
  FNames := TStringList.Create;
  AddHeading(Self, 'Playlists', 24, 16, 300);
  with AddLabel(Self, HINT_PLM_LIST, 24, 44, DLG_W - 48 - SIDE_W - 20) do
  begin
    FontSize := 12;
    WordWrap := True;
    VAlign := 0;
    Height := S(36);
  end;
  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.SetBounds(S(24), S(86), S(DLG_W - 48 - SIDE_W - 20), S(DLG_H - 86 - 24));
  FList.ShowHeader := False;
  FList.MultiSelect := True;
  FList.RowMenu := False;
  FList.AutoFit := True;
  FList.RowHeight := S(34);
  FList.AddColumn('Playlist', 300, 0, True);
  FList.BackRole := crCard;
  FList.EmptyText := 'No playlists.';
  FList.OnDrawCell := @DrawRow;
  FList.OnTypeText := @RowName;
  FList.OnSelChange := @SelChange;
  FList.OnActivate := @ListActivate;
  FList.TabOrder := 0;
  X := DLG_W - 24 - SIDE_W;
  Y := 86;
  FBtnNew := Btn('New playlist...', HINT_PLM_NEW, icPlus, @NewClick);
  FBtnNewAuto := Btn('New auto-playlist...', HINT_PLM_NEW_AUTO, icFunnel, @NewAutoClick);
  FBtnEdit := Btn('Edit...', HINT_PLM_EDIT, icEdit, @EditClick);
  FBtnRemove := Btn('Remove', HINT_PLM_REMOVE, icTrash, @RemoveClick);
  Inc(Y, 12);
  FBtnImport := Btn('Import...', HINT_PLM_IMPORT, icImport, @ImportClick);
  FBtnExport := Btn('Export...', HINT_PLM_EXPORT, icExport, @ExportClick);
  B := AddButton(Self, 'Close', X, DLG_H - 24 - 34, SIDE_W, bkPrimary, @CloseClick);
  DefaultButton := B;
  LoadNames(ASelect);
  ActiveControl := FList;
end;

destructor TPlaylistManagerForm.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

procedure TPlaylistManagerForm.LoadNames(const ASelect: string; AElseRow: Integer);
var
  I, Sel: Integer;
begin
  FNames.Clear;
  if FStore <> nil then FStore.GetNames(FNames);
  FList.ClearSelection;
  FList.RowCount := FNames.Count;
  FList.Changed;
  Sel := -1;
  for I := 0 to FNames.Count - 1 do
    if SameText(FNames[I], ASelect) then Sel := I;
  if (Sel < 0) and (FNames.Count > 0) then Sel := EnsureRange(AElseRow, 0, FNames.Count - 1);
  if Sel >= 0 then FList.SelectOnly(Sel);
  UpdateButtons;
end;

{ what typing the first letters is matched against: the playlist's name }
function TPlaylistManagerForm.RowName(Sender: TObject; Row: Integer): string;
begin
  if (Row >= 0) and (Row < FNames.Count) then Result := FNames[Row] else Result := '';
end;

function TPlaylistManagerForm.KindOf(Row: Integer): TPlaylistKind;
begin
  if (Row >= 0) and (Row < FNames.Count) then Result := TPlaylistKind(PtrInt(FNames.Objects[Row]))
  else Result := pkNormal;
end;

function TPlaylistManagerForm.SelectedName: string;
var
  Sel: TIntegerArray;
begin
  Result := '';
  Sel := FList.SelectedRows;
  if Length(Sel) = 1 then Result := FNames[Sel[0]];
end;

procedure TPlaylistManagerForm.UpdateButtons;
var
  Sel: TIntegerArray;
  I: Integer;
  AnyRemovable: Boolean;
begin
  Sel := FList.SelectedRows;
  AnyRemovable := False;
  for I := 0 to High(Sel) do
    if (FStore <> nil) and not FStore.IsDefault(FNames[Sel[I]]) then AnyRemovable := True;
  FBtnEdit.Enabled := Length(Sel) = 1;
  FBtnExport.Enabled := (Length(Sel) = 1) and Assigned(FOnExport);
  FBtnRemove.Enabled := AnyRemovable;
  FBtnImport.Enabled := FStore <> nil;
  FBtnNew.Enabled := FStore <> nil;
  FBtnNewAuto.Enabled := FStore <> nil;
end;

{ X -> Y followed by Y -> Z is recorded as X -> Z }
procedure TPlaylistManagerForm.RecordRename(const AOld, ANew: string);
var
  I: Integer;
begin
  if (FResult = nil) or SameText(AOld, ANew) then Exit;
  I := FResult^.RenamedTo.IndexOf(AOld);
  if I >= 0 then FResult^.RenamedTo[I] := ANew
  else
  begin
    FResult^.RenamedFrom.Add(AOld);
    FResult^.RenamedTo.Add(ANew);
  end;
  I := FResult^.Changed.IndexOf(AOld);
  if I >= 0 then FResult^.Changed[I] := ANew;
end;

procedure TPlaylistManagerForm.RecordChange(const AName: string);
begin
  if (FResult <> nil) and (FResult^.Changed.IndexOf(AName) < 0) then FResult^.Changed.Add(AName);
end;

{ icon, name; on the right the number of tracks or the rules }
procedure TPlaylistManagerForm.DrawRow(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
  var Handled: Boolean);
var
  P: PStoredPlaylist;
  Info: string;
  IW: Single;
  FS: TGfxFont;
  Ic: TAuIcon;
begin
  if (Row < 0) or (Row >= FNames.Count) then Exit;
  Handled := True;
  P := nil;
  if FStore <> nil then P := FStore.Find(FNames[Row]);
  if KindOf(Row) = pkAuto then Ic := icFunnel
  else if (FStore <> nil) and FStore.IsDefault(FNames[Row]) then Ic := icHome
  else Ic := icPlaylist;
  DrawIcon(G, Ic, X + S(16), Y + H / 2, S(16), IfC(KindOf(Row) = pkAuto, clAccentText, clTextDim));
  Info := '';
  if P <> nil then
  begin
    if P^.Kind = pkAuto then Info := P^.Query
    else if Length(P^.Entries) = 1 then Info := '1 track'
    else Info := Format('%d tracks', [Length(P^.Entries)]);
  end;
  { the divider above the first auto-playlist }
  if (KindOf(Row) = pkAuto) and (Row > 0) and (KindOf(Row - 1) <> pkAuto) then
    G.FillRect(X + S(4), Y, W - S(8), Math.Max(1, S(1)), clBorderHi);
  FS := UIFont(12);
  IW := Math.Min(TextWidth(Info, FS) + S(8), W * 0.45);
  G.Text(Info, X + W - IW - S(8), Y, IW, H, FS, clTextFaint, 2, 1);
  G.Text(FNames[Row], X + S(34), Y, W - S(42) - IW, H, UIFont(13), clText, 0, 1);
end;

procedure TPlaylistManagerForm.SelChange(Sender: TObject);
begin
  UpdateButtons;
end;

procedure TPlaylistManagerForm.ListActivate(Sender: TObject; Row: Integer);
begin
  if (Row < 0) or (Row >= FNames.Count) then Exit;
  if FResult <> nil then FResult^.Activated := FNames[Row];
  ModalResult := mrOK;
end;

procedure TPlaylistManagerForm.CloseClick(Sender: TObject);
begin
  ModalResult := mrOK;
end;

procedure TPlaylistManagerForm.NewPlaylist(AAuto: Boolean);
var
  N, HF, TF, Q: string;
  G: Integer;
  P: PStoredPlaylist;
begin
  if FStore = nil then Exit;
  if AAuto then N := FStore.UniqueName('New auto-playlist') else N := FStore.UniqueName('New playlist');
  G := -1;
  HF := '';
  TF := '';
  Q := '';
  if not EditPlaylistDialog(Self, FStore, N, G, HF, TF, Q, AAuto, False) then Exit;
  if AAuto then P := FStore.Add(N, pkAuto) else P := FStore.Add(N, pkNormal);
  if P = nil then Exit;
  P^.GroupMode := G;
  P^.HeaderFmt := HF;
  P^.TrackFmt := TF;
  P^.Query := Q;
  FStore.Changed(P);
  RecordChange(N);
  LoadNames(N);
end;

procedure TPlaylistManagerForm.NewClick(Sender: TObject);
begin
  NewPlaylist(False);
end;

procedure TPlaylistManagerForm.NewAutoClick(Sender: TObject);
begin
  NewPlaylist(True);
end;

procedure TPlaylistManagerForm.EditClick(Sender: TObject);
var
  Old, N, HF, TF, Q: string;
  G: Integer;
  P: PStoredPlaylist;
begin
  Old := SelectedName;
  if (Old = '') or (FStore = nil) then Exit;
  P := FStore.Find(Old);
  if P = nil then Exit;
  N := P^.Name;
  G := P^.GroupMode;
  HF := P^.HeaderFmt;
  TF := P^.TrackFmt;
  Q := P^.Query;
  if not EditPlaylistDialog(Self, FStore, N, G, HF, TF, Q, P^.Kind = pkAuto, True) then Exit;
  if N <> Old then
  begin
    if not FStore.Rename(Old, N) then
    begin
      AuMessage(ERR_EDIT_RENAMEFAIL, amError, abOK, TITLE_ERROR);
      Exit;
    end;
    RecordRename(Old, N);
  end;
  P := FStore.Find(N);
  if P = nil then Exit;
  P^.GroupMode := G;
  P^.HeaderFmt := HF;
  P^.TrackFmt := TF;
  if P^.Kind = pkAuto then P^.Query := Q;
  FStore.Changed(P);
  RecordChange(N);
  LoadNames(N);
end;

procedure TPlaylistManagerForm.RemoveClick(Sender: TObject);
var
  Sel: TIntegerArray;
  Names: TStringList;
  I: Integer;
  Msg: string;
begin
  if (FStore = nil) or not FBtnRemove.Enabled then Exit;
  Sel := FList.SelectedRows;
  Names := TStringList.Create;
  try
    for I := 0 to High(Sel) do
      if not FStore.IsDefault(FNames[Sel[I]]) then Names.Add(FNames[Sel[I]]);
    if Names.Count = 0 then Exit;
    if Names.Count = 1 then Msg := SafeFormat(FMT_CONFIRM_DELETE_ONE_PL, ['"' + Names[0] + '"'])
    else Msg := SafeFormat(FMT_CONFIRM_DELETE_MULTI_PL, [Names.Count]);
    Msg := Msg + LineEnding + 'The music files are not deleted.';
    if AuMessage(Msg, amWarning, abYesNo, TITLE_CONFIRM_DELETE) <> mrYes then Exit;
    for I := 0 to Names.Count - 1 do FStore.Delete(Names[I]);
  finally
    Names.Free;
  end;
  { the playlist that is now where the first removed one was }
  LoadNames('', Sel[0]);
end;

procedure TPlaylistManagerForm.ImportClick(Sender: TObject);
var
  D: TOpenDialog;
  N, Wanted, Err, Msg: string;
begin
  if not Assigned(FOnImport) then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Import playlist';
    D.Filter := DIALOG_FILTER_PLAYLISTS;
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    Wanted := Trim(ChangeFileExt(ExtractFileName(D.FileName), ''));
    Screen.Cursor := crHourGlass;
    try
      N := FOnImport(D.FileName, Err);
    finally
      Screen.Cursor := crDefault;
    end;
    if N = '' then
    begin
      AuMessage('The playlist could not be read: ' + Err, amError, abOK, 'Import playlist');
      Exit;
    end;
    RecordChange(N);
    LoadNames(N);
    if SameText(N, Wanted) then Msg := MSG_IMPORT_COMPLETE
    else Msg := SafeFormat(FMT_MSG_IMPORTED_AS, [N]);
    AuMessage(Msg, amInfo, abOK, 'Import playlist');
  finally
    D.Free;
  end;
end;

procedure TPlaylistManagerForm.ExportClick(Sender: TObject);
var
  D: TSaveDialog;
  N, Err: string;
  Ok: Boolean;
begin
  N := SelectedName;
  if (N = '') or not Assigned(FOnExport) then Exit;
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'Export playlist';
    D.Filter := 'M3U8 playlist (*.m3u8)|*.m3u8|M3U playlist (*.m3u)|*.m3u';
    D.DefaultExt := 'm3u8';
    D.FileName := N + FILE_EXT_M3U8;
    D.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    Screen.Cursor := crHourGlass;
    try
      Ok := FOnExport(N, D.FileName, Err);
    finally
      Screen.Cursor := crDefault;
    end;
    if Ok then AuMessage(MSG_EXPORT_COMPLETE, amInfo, abOK, 'Export playlist')
    else AuMessage(SafeFormat(FMT_ERR_PL_EXPORT, [Err]), amError, abOK, TITLE_ERROR);
  finally
    D.Free;
  end;
end;

procedure TPlaylistManagerForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = Ord('N')) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    NewClick(nil);
    Exit;
  end;
  if (Key = VK_F2) and (Shift = []) then
  begin
    Key := 0;
    EditClick(nil);
    Exit;
  end;
  if (Key = VK_DELETE) and (Shift = []) and (ActiveControl = FList) then
  begin
    Key := 0;
    RemoveClick(nil);
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

end.
