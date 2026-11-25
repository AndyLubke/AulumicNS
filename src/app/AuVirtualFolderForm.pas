unit AuVirtualFolderForm;

{ ==============================================================================
  AulumicNS - AuVirtualFolderForm
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Virtual Folder editor (the library menu:
  Create / Edit Virtual Folder...): a virtual folder is a .aullink file in a
  library folder that shows other folders inside it (e.g. all recordings of
  one composer from everywhere in the library).
    Name          the name in the tree (fixed when editing)
    Auto-Find     a term and where to look (Artist / Performer, Composer,
                  Album / Title, Comment / Genre, Folder name): the library
                  folders whose tracks match every word are added (and
                  selected, to be checked)
    Folders       the folders inside it: Add Folder..., Remove (Del), folders
                  dropped from Explorer
  The paths are kept relative to the folder of the link. The
  search runs on a copy of the library (no disk access).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms, AuFolderPicker, uLibraryManager, uLibraryTypes;

{ the dialog, shown modal: AName and APaths in and out }
function EditVirtualFolder(AOwner: TComponent; const ABaseDir: string; var AName: string; APaths: TStringList;
  AIsEdit: Boolean; ALibrary: TLibraryManager): Boolean;
{ the dialog, not shown (screenshot mode) }
function CreateVirtualFolderForm(AOwner: TComponent; const ABaseDir, AName: string; APaths: TStrings;
  AIsEdit: Boolean; ALibrary: TLibraryManager): TAuForm;

implementation

uses
  uAppConsts, uAppStrings, uOSUtils, uMetaUtils, uAudioUtils, AuTagLoader, AuMenus;

type
  { TVirtualFolderForm }

  TVirtualFolderForm = class(TAuForm)
  private
    FBaseDir, FOriginal: string;
    FIsEdit: Boolean;
    FLibrary: TLibraryManager;
    FPaths: TStringList;
    FName, FSearch: TAuEdit;
    FChecks: array[0..4] of TAuCheckBox;
    FList: TAuListView;
    FBtnAdd, FBtnFind, FBtnRemove, FBtnFolder, FBtnSave, FBtnCancel: TAuButton;
    FRowMenu: TAuMenu;               // the menu of a right-clicked folder (kept until its entry ran)
    FLocation, FStatus, FNameCap, FSearchCap, FInCap: TAuLabel;
    procedure Layout;
    procedure UpdateButtons;
    procedure AnyChange(Sender: TObject);
    procedure ListCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure AddRelative(const ADir: string; ASelect: Boolean);
    procedure AddClick(Sender: TObject);
    procedure FindClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure FolderClick(Sender: TObject);
    procedure ListContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
    procedure SaveClick(Sender: TObject);
    procedure SearchEnter(Sender: TObject);
    procedure FormDrop(Sender: TObject; const FileNames: array of string);
    function ValidateInput: Boolean;
  protected
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateEditor(AOwner: TComponent; const ABaseDir, AName: string; APaths: TStrings;
      AIsEdit: Boolean; ALibrary: TLibraryManager);
    destructor Destroy; override;
  end;

var
  { the search choices of the session }
  LastChecks: array[0..4] of Boolean = (True, True, True, False, True);

const
  DLG_W = 760;
  DLG_H = 600;
  CHECK_CAPS: array[0..4] of string = (LBL_ALIAS_TAG_ARTIST, LBL_ALIAS_TAG_COMPOSER, LBL_ALIAS_TAG_ALBUM_TITLE,
    LBL_ALIAS_TAG_COMMENT_GENRE, LBL_ALIAS_TAG_FOLDER);
  CHECK_HINTS: array[0..4] of string = (HINT_ALIAS_TAG_ARTIST, HINT_ALIAS_TAG_COMPOSER, HINT_ALIAS_TAG_ALBUM_TITLE,
    HINT_ALIAS_TAG_COMMENT_GENRE, HINT_ALIAS_TAG_FOLDER);

{ the track's folder, or its parent when the
  parent is the album's folder (a disc folder inside an album folder) }
function ResolveAlbumFolder(const ATrack: PTrackInfo; const ANormBase: string): string;
var
  CleanDir, LeafName, CleanLeaf, ParentDir, ParentName, CleanParent, CleanAlb: string;
  ParentMatchesAlbum, ParentIsArtistOrComposer: Boolean;
begin
  CleanDir := ExcludeTrailingPathDelimiter(ATrack^.FolderDir);
  Result := CleanDir;
  CleanAlb := Trim(ATrack^.CleanAlbum);
  if (CleanAlb = '') or SameText(ATrack^.Album, LBL_UNKNOWN_ALBUM) then Exit;
  LeafName := ExtractFileName(CleanDir);
  CleanLeaf := LowerCase(StripAccents(Trim(LeafName)));
  if CleanLeaf = '' then Exit;
  if (Pos(CleanAlb, CleanLeaf) > 0) or ((Length(CleanLeaf) >= 4) and (Pos(CleanLeaf, CleanAlb) > 0)) then Exit;
  ParentDir := ExcludeTrailingPathDelimiter(ExtractFilePath(CleanDir));
  ParentName := ExtractFileName(ParentDir);
  if (ParentDir = '') or (ParentDir = CleanDir) or (ParentName = '') or
     SameText(IncludeTrailingPathDelimiter(ParentDir), ANormBase) then Exit;
  CleanParent := LowerCase(StripAccents(Trim(ParentName)));
  if Length(CleanParent) < 2 then Exit;
  ParentIsArtistOrComposer := (CleanParent = ATrack^.CleanAlbumArtist) or (CleanParent = ATrack^.CleanArtist) or
    (CleanParent = ATrack^.CleanComposer);
  ParentMatchesAlbum := (Pos(CleanAlb, CleanParent) > 0) or
    ((not ParentIsArtistOrComposer) and (Length(CleanParent) >= 3) and (Pos(CleanParent, CleanAlb) > 0));
  if ParentMatchesAlbum then Result := ParentDir;
end;

function EditVirtualFolder(AOwner: TComponent; const ABaseDir: string; var AName: string; APaths: TStringList;
  AIsEdit: Boolean; ALibrary: TLibraryManager): Boolean;
var
  F: TVirtualFolderForm;
begin
  F := TVirtualFolderForm.CreateEditor(AOwner, ABaseDir, AName, APaths, AIsEdit, ALibrary);
  try
    Result := F.ShowModal = mrOK;
    if Result then
    begin
      AName := Trim(F.FName.Text);
      APaths.Assign(F.FPaths);
    end;
  finally
    F.Free;
  end;
end;

function CreateVirtualFolderForm(AOwner: TComponent; const ABaseDir, AName: string; APaths: TStrings;
  AIsEdit: Boolean; ALibrary: TLibraryManager): TAuForm;
begin
  Result := TVirtualFolderForm.CreateEditor(AOwner, ABaseDir, AName, APaths, AIsEdit, ALibrary);
end;

{ ---- TVirtualFolderForm ---- }

constructor TVirtualFolderForm.CreateEditor(AOwner: TComponent; const ABaseDir, AName: string; APaths: TStrings;
  AIsEdit: Boolean; ALibrary: TLibraryManager);
var
  FolderName: string;
  I: Integer;
begin
  FBaseDir := ExcludeTrailingPathDelimiter(ABaseDir);
  FolderName := ExtractFileName(FBaseDir);
  if FolderName = '' then FolderName := FBaseDir;
  if AIsEdit then CreateAu(AOwner, SafeFormat(FMT_TITLE_EDIT_VIRTUAL_FOLDER, [FolderName]), DLG_W, DLG_H)
  else CreateAu(AOwner, SafeFormat(FMT_TITLE_CREATE_VIRTUAL_FOLDER, [FolderName]), DLG_W, DLG_H);
  HelpKeyword := 'Virtual Folders';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];
  Constraints.MinWidth := S(FORM_ALIAS_MINWIDTH);
  Constraints.MinHeight := S(FORM_ALIAS_MINHEIGHT);
  FitToWorkArea;          // a small screen at a large scaling
  FOriginal := AName;
  FIsEdit := AIsEdit;
  FLibrary := ALibrary;
  FPaths := TStringList.Create;
  if APaths <> nil then FPaths.Assign(APaths);

  FNameCap := AddLabel(Self, 'Name', 24, 18, 160, False);
  FName := AddEdit(Self, 190, 14, 400);
  FName.Hint := HINT_ALIAS_NAME;
  FName.ShowHint := True;
  FName.OnChange := @AnyChange;
  if (not AIsEdit) and (Trim(AName) = '') then FName.Text := FolderName else FName.Text := AName;
  FName.Enabled := not AIsEdit;
  if AIsEdit then FNameCap.TextRole := crTextFaint;

  FSearchCap := AddLabel(Self, LBL_ALIAS_SEARCH_TERM, 24, 60, 160, False);
  FSearch := AddEdit(Self, 190, 56, 400, FName.Text);
  FSearch.Hint := HINT_ALIAS_SEARCH_TERM;
  FSearch.ShowHint := True;
  FSearch.Placeholder := 'e.g. Bach';
  FSearch.OnChange := @AnyChange;
  FSearch.OnEnterKey := @SearchEnter;
  FInCap := AddLabel(Self, LBL_ALIAS_SEARCH_IN, 24, 100, 160, False);
  FInCap.Hint := HINT_ALIAS_SEARCH_IN;
  for I := 0 to 4 do
  begin
    FChecks[I] := AddCheck(Self, CHECK_CAPS[I], 190, 98, 180, LastChecks[I]);
    FChecks[I].Hint := CHECK_HINTS[I];
    FChecks[I].ShowHint := True;
    FChecks[I].OnChange := @AnyChange;
  end;

  FLocation := AddLabel(Self, SafeFormat(FMT_ALIAS_LOCATION_HEADER, [FolderName]), 24, 0, DLG_W - 48);
  FLocation.FontSize := 12;
  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.ShowHeader := False;
  FList.MultiSelect := True;
  FList.RowMenu := False;
  FList.AutoFit := True;
  FList.RowHeight := S(30);
  FList.AddColumn('Folder', 300, 0, True);
  FList.BackRole := crCard;
  FList.EmptyText := 'No folders yet: add some, drop them here from Explorer or use Auto-find.';
  FList.Hint := HINT_ALIAS_LIST;
  FList.OnDrawCell := @ListCell;
  FList.OnSelChange := @AnyChange;
  FList.OnKeyDown := @ListKey;
  FBtnAdd := AddButton(Self, 'Add folder...', 0, 0, 150, bkNormal, @AddClick);
  FBtnAdd.Icon := icFolderPlus;
  FBtnAdd.Hint := HINT_ALIAS_ADD;
  FBtnAdd.ShowHint := True;
  FBtnFind := AddButton(Self, 'Auto-find', 0, 0, 150, bkNormal, @FindClick);
  FBtnFind.Icon := icSearch;
  FBtnFind.Hint := HINT_ALIAS_AUTOFIND;
  FBtnFind.ShowHint := True;
  FBtnRemove := AddButton(Self, 'Remove', 0, 0, 150, bkNormal, @RemoveClick);
  FBtnRemove.Icon := icTrash;
  FBtnRemove.Hint := HINT_ALIAS_REMOVE;
  FBtnRemove.ShowHint := True;
  FBtnFolder := AddButton(Self, 'Open folder', 0, 0, 150, bkNormal, @FolderClick);
  FBtnFolder.Icon := icFolder;
  FBtnFolder.Hint := 'Show the selected folder in Explorer.';
  FBtnFolder.ShowHint := True;
  FList.OnRowContext := @ListContext;

  FStatus := AddLabel(Self, '', 24, 0, 400);
  FStatus.FontSize := 12;
  FStatus.WordWrap := True;
  FStatus.VAlign := 1;
  FBtnCancel := AddButton(Self, 'Cancel', 0, 0, 110);
  FBtnCancel.ModalResult := mrCancel;
  FBtnSave := AddButton(Self, 'Save', 0, 0, 110, bkPrimary, @SaveClick);
  FBtnSave.Hint := HINT_ALIAS_SAVE;
  FBtnSave.ShowHint := True;
  DefaultButton := FBtnSave;

  FName.TabOrder := 0;
  FSearch.TabOrder := 1;
  for I := 0 to 4 do FChecks[I].TabOrder := 2 + I;
  FList.TabOrder := 7;
  FBtnAdd.TabOrder := 8;
  FBtnFind.TabOrder := 9;
  FBtnRemove.TabOrder := 10;
  FBtnSave.TabOrder := 11;
  FBtnCancel.TabOrder := 12;

  AllowDropFiles := True;
  OnDropFiles := @FormDrop;
  FList.RowCount := FPaths.Count;
  Layout;
  UpdateButtons;
  if FName.Enabled then ActiveControl := FName else ActiveControl := FSearch;
end;

destructor TVirtualFolderForm.Destroy;
var
  I: Integer;
begin
  for I := 0 to 4 do LastChecks[I] := FChecks[I].Checked;
  FRowMenu.Free;
  FPaths.Free;
  inherited Destroy;
end;

procedure TVirtualFolderForm.Layout;
var
  W, H, X, Y, I, CW, ListTop, BY: Integer;
begin
  if FBtnSave = nil then Exit;
  W := ClientWidth;
  H := BodyHeight;
  FName.Width := W - S(190) - S(24);
  FSearch.Width := W - S(190) - S(24);
  { the search choices flow into rows }
  CW := S(176);
  X := S(190);
  Y := S(98);
  for I := 0 to 4 do
  begin
    if (X > S(190)) and (X + CW > W - S(24)) then
    begin
      X := S(190);
      Inc(Y, S(30));
    end;
    FChecks[I].SetBounds(X, Y, CW - S(8), S(26));
    Inc(X, CW);
  end;
  FLocation.SetBounds(S(24), Y + S(44), W - S(48), S(22));
  ListTop := Y + S(72);
  BY := H - S(24) - S(34);
  FList.SetBounds(S(24), ListTop, W - S(48) - S(150) - S(16), BY - S(16) - ListTop);
  FBtnAdd.SetBounds(W - S(24) - S(150), ListTop, S(150), S(34));
  FBtnFind.SetBounds(W - S(24) - S(150), ListTop + S(42), S(150), S(34));
  FBtnRemove.SetBounds(W - S(24) - S(150), ListTop + S(84), S(150), S(34));
  FBtnFolder.SetBounds(W - S(24) - S(150), ListTop + S(126), S(150), S(34));
  FBtnSave.SetBounds(W - S(24) - S(110), BY, S(110), S(34));
  FBtnCancel.SetBounds(FBtnSave.Left - S(10) - S(110), BY, S(110), S(34));
  FStatus.SetBounds(S(24), BY - S(6), Math.Max(0, FBtnCancel.Left - S(36)), S(46));
end;

procedure TVirtualFolderForm.Resize;
begin
  inherited Resize;
  Layout;
end;

{ Enter in the Auto-Find box searches, elsewhere it saves }
procedure TVirtualFolderForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and (Shift = []) and (ActiveControl = FSearch) then
  begin
    Key := 0;
    if FBtnFind.Enabled then FindClick(nil);
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

{ Explorer at the first selected folder }
procedure TVirtualFolderForm.FolderClick(Sender: TObject);
var
  Sel: TIntegerArray;
begin
  Sel := FList.SelectedRows;
  if (Length(Sel) = 0) or (Sel[0] < 0) or (Sel[0] >= FPaths.Count) then Exit;
  OpenFolderWithWindow(Self, IncludeTrailingPathDelimiter(FPaths[Sel[0]]));
end;

procedure TVirtualFolderForm.ListContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
begin
  if FList.SelCount = 0 then Exit;
  FRowMenu.Free;
  FRowMenu := TAuMenu.Create;
  FRowMenu.Add('Open folder...', @FolderClick, icFolder);
  FRowMenu.Add('Remove', @RemoveClick, icTrash);
  FRowMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

procedure TVirtualFolderForm.UpdateButtons;
var
  AnyCheck: Boolean;
  I: Integer;
begin
  AnyCheck := False;
  for I := 0 to 4 do AnyCheck := AnyCheck or FChecks[I].Checked;
  FBtnFind.Enabled := AnyCheck and ((Trim(FSearch.Text) <> '') or (Trim(FName.Text) <> '')) and (FLibrary <> nil);
  FBtnRemove.Enabled := FList.SelCount > 0;
  FBtnFolder.Enabled := FList.SelCount > 0;
  FBtnSave.Enabled := (Trim(FName.Text) <> '') and (FPaths.Count > 0);
end;

procedure TVirtualFolderForm.AnyChange(Sender: TObject);
begin
  UpdateButtons;
end;

procedure TVirtualFolderForm.SearchEnter(Sender: TObject);
begin
  if FBtnFind.Enabled then FindClick(nil);
end;

procedure TVirtualFolderForm.ListCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
  var Handled: Boolean);
begin
  if (Row < 0) or (Row >= FPaths.Count) then Exit;
  Handled := True;
  DrawIcon(G, icFolder, X + S(14), Y + H / 2, S(16), clTextDim);
  G.Text(FPaths[Row], X + S(30), Y, W - S(34), H, UIFont(12.5), clText, 0, 1);
end;

procedure TVirtualFolderForm.ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_DELETE) and (Shift = []) then
  begin
    Key := 0;
    RemoveClick(nil);
  end;
end;

{ a folder as a path relative to the link's folder (once) }
procedure TVirtualFolderForm.AddRelative(const ADir: string; ASelect: Boolean);
var
  Rel: string;
  I: Integer;
begin
  Rel := ExcludeTrailingPathDelimiter(ExtractRelativePath(IncludeTrailingPathDelimiter(FBaseDir),
    ExcludeTrailingPathDelimiter(ADir)));
  if Rel = '' then Exit;
  I := FPaths.IndexOf(Rel);
  if I < 0 then
  begin
    I := FPaths.Add(Rel);
    FList.RowCount := FPaths.Count;
  end;
  if ASelect then FList.Selected[I] := True;
end;

procedure TVirtualFolderForm.AddClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := FBaseDir;
  if not AuPickFolder('Add a folder to the virtual folder', Dir) then Exit;
  FList.ClearSelection;
  AddRelative(Dir, True);
  FList.Changed;
  UpdateButtons;
end;

procedure TVirtualFolderForm.FormDrop(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
begin
  for I := 0 to High(FileNames) do
    if DirectoryExists(FileNames[I]) then AddRelative(FileNames[I], False);
  FList.Changed;
  UpdateButtons;
end;

procedure TVirtualFolderForm.RemoveClick(Sender: TObject);
var
  Sel: TIntegerArray;
  I: Integer;
begin
  Sel := FList.SelectedRows;
  if Length(Sel) = 0 then Exit;
  for I := High(Sel) downto 0 do
    if Sel[I] < FPaths.Count then FPaths.Delete(Sel[I]);
  FList.ClearSelection;
  FList.RowCount := FPaths.Count;
  FList.Changed;
  UpdateButtons;
end;

{ Auto-Find: the album folders of the library tracks that contain
  every word of the term (whole words, accents ignored) in the chosen tags }
procedure TVirtualFolderForm.FindClick(Sender: TObject);

  function IsWordChar(C: Char): Boolean; inline;
  begin
    Result := C in ['a'..'z', 'A'..'Z', '0'..'9', #128..#255];
  end;

  function ContainsWholeWord(const H, N: string): Boolean;
  var
    P, Start, NL, HL: Integer;
  begin
    Result := False;
    NL := Length(N);
    HL := Length(H);
    if (NL = 0) or (NL > HL) then Exit;
    Start := 1;
    while Start <= HL - NL + 1 do
    begin
      P := PosEx(N, H, Start);
      if P = 0 then Exit(False);
      if ((P = 1) or not IsWordChar(H[P - 1])) and ((P + NL - 1 = HL) or not IsWordChar(H[P + NL])) then
        Exit(True);
      Start := P + 1;
    end;
  end;

  procedure Tokens(const S: string; L: TStringList);
  var
    I, P: Integer;
    T: string;
  begin
    L.Clear;
    P := 0;
    for I := 1 to Length(S) do
      if not (S[I] in [' ', #9, '-', '/', '\', ',', ';', ':', '.', '(', ')', '[', ']']) then
      begin
        if P = 0 then P := I;
      end
      else if P > 0 then
      begin
        T := Trim(Copy(S, P, I - P));
        if Length(T) >= 2 then L.Add(T);
        P := 0;
      end;
    if P > 0 then
    begin
      T := Trim(Copy(S, P, MaxInt));
      if Length(T) >= 2 then L.Add(T);
    end;
  end;

var
  Query, Clean, NormBase, Cand, NormCand, Comment, Tok: string;
  Toks, Found, Roots: TStringList;
  I, J, Added, Existing, Idx: Integer;
  Tracks: TTrackInfoArray;
  T: PTrackInfo;
  IsRoot, Match, Hit: Boolean;
  UseArt, UseComp, UseAlb, UseCom, UseFold: Boolean;
begin
  if (FLibrary = nil) or not FBtnFind.Enabled then
  begin
    if FLibrary = nil then FStatus.Caption := ERR_ALIAS_DB_UNAVAILABLE;
    Exit;
  end;
  Query := Trim(FSearch.Text);
  if Query = '' then
  begin
    Query := Trim(FName.Text);
    FSearch.Text := Query;
  end;
  if Length(Query) < 2 then
  begin
    FStatus.Caption := MSG_ALIAS_MIN_SEARCH_LEN;
    Exit;
  end;
  UseArt := FChecks[0].Checked;
  UseComp := FChecks[1].Checked;
  UseAlb := FChecks[2].Checked;
  UseCom := FChecks[3].Checked;
  UseFold := FChecks[4].Checked;
  Clean := LowerCase(StripAccents(Query));
  Toks := TStringList.Create;
  Found := TStringList.Create;
  Roots := TStringList.Create;
  try
    Found.Sorted := True;
    Found.Duplicates := dupIgnore;
    Tokens(Clean, Toks);
    if Toks.Count = 0 then Toks.Add(Clean);
    NormBase := IncludeTrailingPathDelimiter(FBaseDir);
    { a library folder itself may take its own sub folders, a folder inside one
      only folders from elsewhere }
    IsRoot := False;
    FLibrary.GetScanFolders(Roots);
    for I := 0 to Roots.Count - 1 do
      if SameText(NormBase, IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(Roots[I]))) then IsRoot := True;
    Screen.Cursor := crHourGlass;
    try
      Tracks := FLibrary.SnapshotTracks;
      for I := 0 to High(Tracks) do
      begin
        T := @Tracks[I];
        if T^.FolderDir = '' then Continue;
        Cand := ResolveAlbumFolder(T, NormBase);
        NormCand := IncludeTrailingPathDelimiter(Cand);
        if SameText(NormCand, NormBase) or ((not IsRoot) and AnsiStartsText(NormBase, NormCand)) then Continue;
        if Found.IndexOf(Cand) >= 0 then Continue;
        Match := True;
        Comment := '';
        if UseCom and (T^.Comment <> '') then Comment := LowerCase(StripAccents(T^.Comment));
        for J := 0 to Toks.Count - 1 do
        begin
          Tok := Toks[J];
          Hit := False;
          if UseArt then
            Hit := ContainsWholeWord(T^.CleanArtist, Tok) or ContainsWholeWord(T^.CleanAlbumArtist, Tok) or
              ContainsWholeWord(T^.CleanPerformer, Tok);
          if (not Hit) and UseComp then Hit := ContainsWholeWord(T^.CleanComposer, Tok);
          if (not Hit) and UseAlb then
            Hit := ContainsWholeWord(T^.CleanAlbum, Tok) or ContainsWholeWord(T^.CleanTitle, Tok);
          if (not Hit) and UseCom then
            Hit := ContainsWholeWord(T^.CleanGenre, Tok) or ((Comment <> '') and ContainsWholeWord(Comment, Tok));
          if (not Hit) and UseFold then Hit := ContainsWholeWord(T^.CleanFolder, Tok);
          if not Hit then
          begin
            Match := False;
            Break;
          end;
        end;
        if Match then Found.Add(Cand);
      end;
      Tracks := nil;
    finally
      Screen.Cursor := crDefault;
    end;
    Added := 0;
    Existing := 0;
    FList.ClearSelection;
    for I := 0 to Found.Count - 1 do
    begin
      Idx := FPaths.IndexOf(ExcludeTrailingPathDelimiter(ExtractRelativePath(NormBase, Found[I])));
      if Idx >= 0 then Inc(Existing)
      else
      begin
        AddRelative(Found[I], True);
        Inc(Added);
      end;
    end;
    FList.Changed;
    UpdateButtons;
    if Added > 0 then FStatus.Caption := SafeFormat(FMT_ALIAS_AUTOFIND_ADDED, [Added, Query])
    else if Existing > 0 then FStatus.Caption := SafeFormat(FMT_ALIAS_AUTOFIND_EXISTING, [Existing, Query])
    else FStatus.Caption := SafeFormat(FMT_ALIAS_AUTOFIND_NONE, [Query]);
  finally
    Roots.Free;
    Found.Free;
    Toks.Free;
  end;
end;

function TVirtualFolderForm.ValidateInput: Boolean;
var
  N: string;
begin
  Result := False;
  N := FName.Text;
  case SanitizeAndValidateFileName(N) of
    feEmpty:
      begin
        AuMessage(ERR_EDIT_EMPTYNAME, amWarning, abOK, TITLE_WARNING);
        if FName.CanFocus then FName.SetFocus;
        Exit;
      end;
    feIllegalChar:
      begin
        AuMessage(ERR_EDIT_INVALIDCHARS, amWarning, abOK, TITLE_WARNING);
        if FName.CanFocus then FName.SetFocus;
        Exit;
      end;
  end;
  if ((not FIsEdit) or not SameText(N, FOriginal)) and
     FileExists(IncludeTrailingPathDelimiter(FBaseDir) + N + EXT_AULLINK) then
  begin
    AuMessage(SafeFormat(FMT_ERR_NAME_DUPLICATE, [N]), amWarning, abOK, TITLE_WARNING);
    if FName.CanFocus then FName.SetFocus;
    Exit;
  end;
  FName.Text := N;
  Result := True;
end;

{ the check of the name looks into the link's folder, whose drive may be asleep:
  it is woken first, on a worker thread }
procedure TVirtualFolderForm.SaveClick(Sender: TObject);
var
  Paths: TStringList;
begin
  if not FBtnSave.Enabled then Exit;
  Paths := TStringList.Create;
  try
    Paths.Add(FBaseDir);
    if not WakeDrivesWithWindow(Self, Paths, APP_TITLE) then Exit;
  finally
    Paths.Free;
  end;
  if ValidateInput then ModalResult := mrOK;
end;

end.
