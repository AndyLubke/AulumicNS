unit AuFolderPicker;

{ ==============================================================================
  AulumicNS - AuFolderPicker
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Themed folder picker (replaces the system folder dialog).

  The list shows the sub folders of the current folder, or the drives at the
  top level ("This PC"). Double click / Enter opens a folder, Backspace or
  the Up button goes one level up. Selecting a row puts its path in the path
  field; "Select folder" returns the path in the field. The path can also be
  typed or pasted.
  =============================================================================}

{$mode objfpc}{$H+}
{$WARN SYMBOL_PLATFORM OFF}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms;

function AuPickFolder(const Title: string; var Path: string): Boolean;
{$IFDEF DEBUG}
{ screenshot mode: the picker, shown modeless, after opening the drive Drive }
function DebugPicker(const Drive: string): TCustomForm;
{$ENDIF}

implementation

type
  TPickEntry = record
    Name, Path: string;
    IsDrive: Boolean;
  end;

  { TFolderPickForm }

  TFolderPickForm = class(TAuForm)
  private
    FUp: TAuIconButton;
    FPathEdit: TAuEdit;
    FList: TAuListView;
    FInfo: TAuLabel;
    FOk, FCancel: TAuButton;
    FCurrent: string;                      // '' = This PC
    FEntries: array of TPickEntry;
    { APath / SelectName by value: callers pass strings of FEntries, which Navigate replaces }
    procedure Navigate(APath: string; SelectName: string = '');
    procedure UpClick(Sender: TObject);
    procedure ListActivate(Sender: TObject; Row: Integer);
    procedure ListSel(Sender: TObject);
    procedure ListDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OkClick(Sender: TObject);
    procedure Layout;
  protected
    procedure DpiUpdated; override;
    procedure Resize; override;
  public
    constructor CreatePicker(const ATitle, AStart: string);
    function Chosen: string;
  end;

function DriveLabel(const Root: string): string;
var
  Vol: array[0..MAX_PATH] of WideChar;
  Dummy, Flags: DWORD;
  Kind: UINT;
  OldMode: UINT;
begin
  Result := '';
  Kind := GetDriveTypeW(PWideChar(UnicodeString(Root)));
  { no label lookups on network and removable drives - they can stall }
  if Kind in [DRIVE_REMOTE, DRIVE_REMOVABLE, DRIVE_CDROM] then
  begin
    case Kind of
      DRIVE_REMOTE: Result := 'Network drive';
      DRIVE_CDROM: Result := 'Optical drive';
    else
      Result := 'Removable drive';
    end;
    Exit;
  end;
  OldMode := SetErrorMode(SEM_FAILCRITICALERRORS);
  try
    FillChar(Vol, SizeOf(Vol), 0);
    if GetVolumeInformationW(PWideChar(UnicodeString(Root)), Vol, MAX_PATH, nil, Dummy, Flags, nil, 0) then
      Result := UTF8Encode(UnicodeString(PWideChar(@Vol[0])));
  finally
    SetErrorMode(OldMode);
  end;
  if Result = '' then Result := 'Local disk';
end;

{ ---- TFolderPickForm ---- }

constructor TFolderPickForm.CreatePicker(const ATitle, AStart: string);
var
  St: string;
begin
  inherited CreateAu(Application.MainForm, ATitle, 620, 520);
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];      // the LCL gives a sizeable window all buttons
  Constraints.MinWidth := S(420);
  Constraints.MinHeight := S(320);
  FitToWorkArea;          // ---> AulumicNS: a small screen at a large scaling

  FUp := TAuIconButton.Create(Self);
  FUp.Parent := Body;
  FUp.Icon := icChevronUp;
  FUp.Hint := 'Up one level (Backspace)';
  FUp.ShowHint := True;
  FUp.OnClick := @UpClick;
  FUp.TabOrder := 0;

  FPathEdit := AddEdit(Self, 64, 20, 400);
  FPathEdit.Placeholder := 'Folder path';
  FPathEdit.TabOrder := 1;

  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.AddColumn('Name', 300, 0, True);
  FList.ShowHeader := False;
  FList.AutoFit := True;
  FList.EmptyText := 'No sub folders';
  FList.OnDrawCell := @ListDraw;
  FList.OnActivate := @ListActivate;
  FList.OnSelChange := @ListSel;
  FList.OnKeyDown := @ListKey;
  FList.TabOrder := 2;

  FInfo := AddLabel(Self, 'Double click opens a folder', 24, 0, 300);

  FCancel := AddButton(Self, 'Cancel', 0, 0, 96);
  FCancel.ModalResult := mrCancel;
  FCancel.TabOrder := 4;
  FOk := AddButton(Self, 'Select folder', 0, 0, 130, bkPrimary, @OkClick);
  FOk.TabOrder := 3;
  DefaultButton := FOk;
  ActiveControl := FList;
  Layout;
  St := ExcludeTrailingPathDelimiter(AStart);
  if (AStart = '') or not DirectoryExists(AStart) then Navigate('')
  else if Length(St) <= 2 then Navigate('', IncludeTrailingPathDelimiter(St))     // a drive root
  else Navigate(ExtractFileDir(St), ExtractFileName(St));
end;

procedure TFolderPickForm.Layout;
var
  W, H: Integer;
begin
  W := ClientWidth;
  H := BodyHeight;
  FUp.SetBounds(S(20), S(18), S(36), S(36));
  FPathEdit.SetBounds(S(64), S(18), W - S(84), S(36));
  FList.SetBounds(S(20), S(66), W - S(40), H - S(66) - S(76));
  FInfo.SetBounds(S(24), H - S(54), W - S(300), S(32));
  FOk.Width := Math.Max(S(130), FOk.PreferredWidth);
  FOk.SetBounds(W - S(20) - FOk.Width, H - S(56), FOk.Width, S(36));
  FCancel.SetBounds(FOk.Left - S(10) - S(96), H - S(56), S(96), S(36));
end;

procedure TFolderPickForm.Resize;
begin
  inherited Resize;
  if FList <> nil then Layout;
end;

procedure TFolderPickForm.DpiUpdated;
begin
  inherited DpiUpdated;
  Layout;
end;

procedure TFolderPickForm.Navigate(APath: string; SelectName: string);
var
  SR: TSearchRec;
  N, I, Sel: Integer;
  Mask: DWORD;
  Root: string;
  L: TStringList;
begin
  FEntries := nil;
  N := 0;
  if APath = '' then
  begin
    FCurrent := '';
    Mask := GetLogicalDrives;
    for I := 0 to 25 do
      if Mask and (1 shl I) <> 0 then
      begin
        Root := Chr(Ord('A') + I) + ':\';
        SetLength(FEntries, N + 1);
        FEntries[N].IsDrive := True;
        FEntries[N].Path := Root;
        FEntries[N].Name := Format('%s (%s:)', [DriveLabel(Root), Chr(Ord('A') + I)]);
        Inc(N);
      end;
    FPathEdit.Text := '';
    FPathEdit.Placeholder := 'This PC';
    FUp.Enabled := False;
  end
  else
  begin
    FCurrent := IncludeTrailingPathDelimiter(APath);
    L := TStringList.Create;
    try
      if FindFirst(FCurrent + '*', faDirectory or faHidden or faSysFile, SR) = 0 then
      try
        repeat
          if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and (SR.Name <> '..') and
             (SR.Attr and faSysFile = 0) and (SR.Name <> '$RECYCLE.BIN') then L.Add(SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
      L.Sort;
      SetLength(FEntries, L.Count);
      for I := 0 to L.Count - 1 do
      begin
        FEntries[I].Name := L[I];
        FEntries[I].Path := FCurrent + L[I];
        FEntries[I].IsDrive := False;
      end;
      N := L.Count;
    finally
      L.Free;
    end;
    FPathEdit.Text := ExcludeTrailingPathDelimiter(FCurrent);
    if Length(FCurrent) = 3 then FPathEdit.Text := FCurrent;
    FUp.Enabled := True;
  end;
  FList.ClearSelection;
  FList.RowCount := N;
  Sel := -1;
  for I := 0 to N - 1 do
    if (SelectName <> '') and ((CompareText(FEntries[I].Name, SelectName) = 0) or
       (CompareText(FEntries[I].Path, SelectName) = 0)) then Sel := I;
  if Sel >= 0 then
  begin
    FList.SelectOnly(Sel);
    FList.EnsureVisible(Sel);
    FPathEdit.Text := FEntries[Sel].Path;
  end;
  if FCurrent = '' then FInfo.Caption := Format('%d drives', [N])
  else if N = 1 then FInfo.Caption := '1 folder'
  else FInfo.Caption := Format('%d folders', [N]);
  FList.Changed;
end;

procedure TFolderPickForm.UpClick(Sender: TObject);
var
  Cur, UpDir: string;
begin
  if FCurrent = '' then Exit;
  Cur := ExcludeTrailingPathDelimiter(FCurrent);
  UpDir := ExtractFileDir(Cur);
  if (UpDir = Cur) or (UpDir = '') then Navigate('', FCurrent)
  else Navigate(UpDir, ExtractFileName(Cur));
end;

procedure TFolderPickForm.ListActivate(Sender: TObject; Row: Integer);
begin
  if (Row < 0) or (Row > High(FEntries)) then Exit;
  Navigate(FEntries[Row].Path);
end;

procedure TFolderPickForm.ListSel(Sender: TObject);
var
  R: Integer;
begin
  R := FList.FocusedRow;
  if (R >= 0) and (R <= High(FEntries)) and FList.Selected[R] then FPathEdit.Text := FEntries[R].Path
  else if FCurrent <> '' then FPathEdit.Text := ExcludeTrailingPathDelimiter(FCurrent);
end;

procedure TFolderPickForm.ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_BACK then
  begin
    Key := 0;
    UpClick(nil);
  end;
end;

procedure TFolderPickForm.ListDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
  var Handled: Boolean);
var
  Ic: TAuIcon;
begin
  if (Row < 0) or (Row > High(FEntries)) then Exit;
  if FEntries[Row].IsDrive then Ic := icDrive else Ic := icFolder;
  DrawIcon(G, Ic, X + S(18), Y + H / 2, S(16), clTextDim);
  G.Text(FEntries[Row].Name, X + S(36), Y, W - S(44), H, UIFont(13), clText, 0, 1);
  Handled := True;
end;

procedure TFolderPickForm.OkClick(Sender: TObject);
var
  P: string;
begin
  P := Trim(FPathEdit.Text);
  if (P <> '') and DirectoryExists(P) then
  begin
    ModalResult := mrOK;
    Exit;
  end;
  if P = '' then AuMessage('Choose a folder first.', amInfo)
  else AuMessage('The folder "' + P + '" does not exist.', amWarning);
end;

function TFolderPickForm.Chosen: string;
begin
  Result := Trim(FPathEdit.Text);
  if Length(Result) > 3 then Result := ExcludeTrailingPathDelimiter(Result);
end;

{$IFDEF DEBUG}
function DebugPicker(const Drive: string): TCustomForm;
var
  F: TFolderPickForm;
  I: Integer;
begin
  F := TFolderPickForm.CreatePicker('Add music folder', '');
  F.Show;
  for I := 0 to High(F.FEntries) do
    if SameText(F.FEntries[I].Path, Drive) then
    begin
      F.FList.SelectOnly(I);
      F.ListActivate(F.FList, I);
      Break;
    end;
  Result := F;
end;
{$ENDIF}

function AuPickFolder(const Title: string; var Path: string): Boolean;
var
  F: TFolderPickForm;
begin
  F := TFolderPickForm.CreatePicker(Title, Path);
  try
    Result := F.ShowModal = mrOK;
    if Result then Path := F.Chosen;
  finally
    F.Free;
  end;
end;

end.
