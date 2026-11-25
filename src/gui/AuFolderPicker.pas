unit AuFolderPicker;

{ ==============================================================================
  AulumicNS - AuFolderPicker
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Themed folder picker (replaces the system folder dialog).

  The list shows the sub folders of the current folder, or the drives at the
  top level ("This PC"). A row is opened with the arrow at its end, a double
  click, Enter or the right arrow key. The path of the current folder stands
  above the list as links: a click on a part goes back to it (Backspace and
  the left arrow key go one level up). Selecting a row puts its path in the
  path field; "Select folder" returns the path in the field, and the line
  beside the buttons names that folder. The path can also be typed or pasted.
  =============================================================================}

{$mode objfpc}{$H+}
{$WARN SYMBOL_PLATFORM OFF}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms, AuCrumbBar;

function AuPickFolder(const Title: string; var Path: string): Boolean;
{ the picker, not shown, in a made-up folder with made-up sub folders (the
  screenshots: no drive or folder of this PC) }
function CreateFolderPickerDemo(const ATitle: string): TAuForm;

implementation

type
  TPickEntry = record
    Name, Path: string;
    IsDrive: Boolean;
  end;

  { TFolderPickForm }

  TFolderPickForm = class(TAuForm)
  private
    FCrumb: TCrumbBar;
    FCrumbPaths: array of string;          // the folder each part of FCrumb stands for ('' = This PC)
    FPathEdit: TAuEdit;
    FList: TAuListView;
    FInfo: TAuLabel;
    FOk, FCancel: TAuButton;
    FCurrent: string;                      // '' = This PC
    FEntries: array of TPickEntry;
    FCellW: Single;                        // the width of a row as it was drawn
    { APath / SelectName by value: callers pass strings of FEntries, which Navigate replaces }
    procedure Navigate(APath: string; SelectName: string = '');
    procedure GoUp;
    procedure ShowCrumb;
    procedure ShowChoice;
    procedure CrumbClick(Sender: TObject; Index: Integer);
    procedure PathChange(Sender: TObject);
    procedure ListCellClick(Sender: TObject; Row, Col, XInCell: Integer);
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
    { ADemo: nothing is read from the disk; the caller fills the list }
    constructor CreatePicker(const ATitle, AStart: string; ADemo: Boolean = False);
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

constructor TFolderPickForm.CreatePicker(const ATitle, AStart: string; ADemo: Boolean);
var
  St: string;
begin
  inherited CreateAu(Application.MainForm, ATitle, 620, 520);
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];      // the LCL gives a sizeable window all buttons
  Constraints.MinWidth := S(420);
  Constraints.MinHeight := S(320);
  FitToWorkArea;          // a small screen at a large scaling

  FCrumb := TCrumbBar.Create(Self);
  FCrumb.Parent := Body;
  FCrumb.FontSize := 13;
  FCrumb.FocusOnClick := False;
  FCrumb.OnPartClick := @CrumbClick;

  FPathEdit := AddEdit(Self, 20, 20, 400);
  FPathEdit.Placeholder := 'Folder path';
  FPathEdit.OnChange := @PathChange;
  FPathEdit.TabOrder := 1;

  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.AddColumn('Name', 300, 0, True);
  FList.ShowHeader := False;
  FList.AutoFit := True;
  FList.EmptyText := 'No sub folders';
  FList.OnDrawCell := @ListDraw;
  FList.OnActivate := @ListActivate;
  FList.OnCellClick := @ListCellClick;
  FList.OnSelChange := @ListSel;
  FList.OnKeyDown := @ListKey;
  FList.TabOrder := 0;

  FInfo := AddLabel(Self, '', 24, 0, 300);

  FCancel := AddButton(Self, 'Cancel', 0, 0, 96);
  FCancel.ModalResult := mrCancel;
  FCancel.TabOrder := 4;
  FOk := AddButton(Self, 'Select folder', 0, 0, 130, bkPrimary, @OkClick);
  FOk.TabOrder := 3;
  DefaultButton := FOk;
  ActiveControl := FList;
  Layout;
  if ADemo then Exit;
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
  FCrumb.SetBounds(S(24), S(12), W - S(48), S(30));
  FList.SetBounds(S(20), S(46), W - S(40), H - S(46) - S(124));
  FPathEdit.SetBounds(S(20), H - S(114), W - S(40), S(36));
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
    FPathEdit.Placeholder := 'Folder path';
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
  ShowCrumb;
  ShowChoice;
  FList.Changed;
end;

{ the current folder as the parts of the bar above the list }
procedure TFolderPickForm.ShowCrumb;
var
  Parts, Rest, Acc: string;
  P, N: Integer;
begin
  Parts := 'This PC';
  SetLength(FCrumbPaths, 1);
  FCrumbPaths[0] := '';
  N := 1;
  Rest := ExcludeTrailingPathDelimiter(FCurrent);
  Acc := '';
  while Rest <> '' do
  begin
    P := Pos(PathDelim, Rest);
    if P = 0 then P := Length(Rest) + 1;
    if Acc = '' then Acc := Copy(Rest, 1, P - 1) + PathDelim       // 'C:\'
    else Acc := IncludeTrailingPathDelimiter(Acc) + Copy(Rest, 1, P - 1);
    Parts := Parts + #1 + Copy(Rest, 1, P - 1);
    SetLength(FCrumbPaths, N + 1);
    FCrumbPaths[N] := Acc;
    Inc(N);
    Delete(Rest, 1, P);
  end;
  FCrumb.SetPath(Parts);
end;

{ the line beside the buttons: the folder "Select folder" would return }
procedure TFolderPickForm.ShowChoice;
var
  P, Leaf: string;
begin
  P := Trim(FPathEdit.Text);
  if P = '' then
  begin
    FInfo.Caption := 'Open a drive to choose a folder';
    FInfo.Invalidate;
    Exit;
  end;
  Leaf := ExtractFileName(ExcludeTrailingPathDelimiter(P));
  if Leaf = '' then Leaf := ExcludeTrailingPathDelimiter(P);         // a drive
  FInfo.Caption := 'Selects: ' + Leaf;
  FInfo.Invalidate;
end;

procedure TFolderPickForm.PathChange(Sender: TObject);
begin
  ShowChoice;
end;

procedure TFolderPickForm.CrumbClick(Sender: TObject; Index: Integer);
var
  Target, From: string;
begin
  if (Index < 0) or (Index > High(FCrumbPaths)) then Exit;
  Target := FCrumbPaths[Index];
  { the folder that was left is the selected row, as after one level up }
  From := '';
  if Index + 1 <= High(FCrumbPaths) then From := FCrumbPaths[Index + 1];
  if Target = '' then Navigate('', From)
  else Navigate(Target, ExtractFileName(ExcludeTrailingPathDelimiter(From)));
  if FList.CanFocus then FList.SetFocus;
end;

{ one click on the arrow at the end of a row opens that folder }
procedure TFolderPickForm.ListCellClick(Sender: TObject; Row, Col, XInCell: Integer);
begin
  if (Row < 0) or (Row > High(FEntries)) then Exit;
  if (FCellW > 0) and (XInCell >= FCellW - S(44)) then Navigate(FEntries[Row].Path);
end;

procedure TFolderPickForm.GoUp;
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
  ShowChoice;
end;

procedure TFolderPickForm.ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_BACK) or (Key = VK_LEFT) then
  begin
    Key := 0;
    GoUp;
  end
  else if Key = VK_RIGHT then
  begin
    Key := 0;
    ListActivate(FList, FList.FocusedRow);
  end;
end;

procedure TFolderPickForm.ListDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
  var Handled: Boolean);
var
  Ic: TAuIcon;
begin
  if (Row < 0) or (Row > High(FEntries)) then Exit;
  if FEntries[Row].IsDrive then Ic := icDrive else Ic := icFolder;
  FCellW := W;
  DrawIcon(G, Ic, X + S(18), Y + H / 2, S(16), clTextDim);
  G.Text(FEntries[Row].Name, X + S(36), Y, W - S(84), H, UIFont(13), clText, 0, 1);
  { the arrow that opens the row }
  DrawIcon(G, icChevronRight, X + W - S(22), Y + H / 2, S(12), clTextDim);
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

function CreateFolderPickerDemo(const ATitle: string): TAuForm;
const
  DEMO_DIR = 'M:\Music\Jazz\';
  DEMO_NAMES: array[0..5] of string = ('Evening Standards', 'Late Night Sessions', 'Northern Lights',
    'Quiet Hours', 'The Blue Room', 'Winter Trio');
var
  F: TFolderPickForm;
  I: Integer;
begin
  F := TFolderPickForm.CreatePicker(ATitle, '', True);
  F.FCurrent := DEMO_DIR;
  SetLength(F.FEntries, Length(DEMO_NAMES));
  for I := 0 to High(DEMO_NAMES) do
  begin
    F.FEntries[I].Name := DEMO_NAMES[I];
    F.FEntries[I].Path := DEMO_DIR + DEMO_NAMES[I];
    F.FEntries[I].IsDrive := False;
  end;
  F.FList.RowCount := Length(DEMO_NAMES);
  F.FList.SelectOnly(2);
  F.FPathEdit.Text := F.FEntries[2].Path;
  F.ShowCrumb;
  F.ShowChoice;
  F.FList.Changed;
  Result := F;
end;
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
