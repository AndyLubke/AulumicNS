unit AuLibraryCheck;

{ ==============================================================================
  AulumicNS - AuLibraryCheck
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Tag consistency window (Main menu > Library and the library's menu): the
  findings of uLibraryCheck for a part of the library as a list - what kind
  of finding, the album or the spellings, and a note. A finding opens its
  files in Properties (double click, Enter or the button), where they are
  changed and saved as always; the window itself changes nothing. "Check
  again" reads the same part of the library anew.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuMenus, AuForms, uLibraryTypes, uLibraryCheck;

type
  { the files of a finding, for Properties }
  TCheckOpenEvent = procedure(APaths: TStrings) of object;
  { the tracks of the part of the library that is checked, as they are now }
  TCheckCollectEvent = procedure(ATracks: TTrackList) of object;

{ the window, shown modal. AScope: what is checked, in words. }
procedure ShowLibraryCheck(AOwner: TComponent; const AScope: string; AOnCollect: TCheckCollectEvent;
  AOnOpen: TCheckOpenEvent);
{ the window with the findings of ATracks, not shown (screenshot mode) }
function CreateLibraryCheckForm(AOwner: TComponent; const AScope: string; ATracks: TTrackList): TAuForm;
{ for tests, on a form of CreateLibraryCheckForm: these lines become the
  selection and are opened as the button does it; AOnOpen gets their files }
procedure LibraryCheckOpenRows(AForm: TAuForm; const ARows: array of Integer; AOnOpen: TCheckOpenEvent);
function LibraryCheckRowCount(AForm: TAuForm): Integer;
{ the filter set to the kind with this name ('' = all kinds); False: no such entry }
function LibraryCheckFilter(AForm: TAuForm; const AKindName: string): Boolean;
{ a click on the heading of column ACol (0 Kind, 1 Finding, 2 Note), and the text of a cell }
procedure LibraryCheckSort(AForm: TAuForm; ACol: Integer);
function LibraryCheckCell(AForm: TAuForm; ARow, ACol: Integer): string;
{ these lines selected as a click would do it (the last one has the focus),
  and the lines that are selected: kind and finding, joined by ' | ' }
procedure LibraryCheckSelect(AForm: TAuForm; const ARows: array of Integer);
function LibraryCheckSelection(AForm: TAuForm): string;

implementation

uses
  AuTagLoader;

const
  DLG_W = 980;
  DLG_H = 600;

type

  { TLibraryCheckForm }

  TLibraryCheckForm = class(TAuForm)
  private
    FScope: string;
    FFound: TCheckFindings;
    FTrackCount: Integer;
    FOnCollect: TCheckCollectEvent;
    FOnOpen: TCheckOpenEvent;
    FHead, FNote: TAuLabel;
    FFilter: TAuCombo;
    FFilterKinds: array of Integer;   // the kind of each entry of the filter (-1: all kinds)
    FShown: array of Integer;         // the findings in the list (places in FFound)
    FSortCol: Integer;                // the column the list is sorted by (0: by kind, as found)
    FSortDesc: Boolean;
    FList: TAuListView;
    FBtnAgain, FBtnFolder, FBtnOpen, FBtnClose: TAuButton;
    FRowMenu: TAuMenu;                // the menu of a right-clicked finding (kept until its entry ran)
    FSelKeys: TStringList;            // the selected findings by kind and text, to find them in a list filled again
    FFocusKey: string;                // ... and the focused one
    FRestoring: Boolean;              // the list is being filled: its selection is not what was chosen
    function FindingKey(AFinding: Integer): string;
    procedure NoteSelection;
    procedure Layout;
    procedure TakeTracks(ATracks: TTrackList);
    procedure UpdateState;
    procedure FillFilter;
    procedure ApplyFilter;
    procedure FilterChange(Sender: TObject);
    procedure HeaderClick(Sender: TObject; Col: Integer);
    procedure SortShown;
    function ShownBefore(A, B: Integer): Boolean;
    function ShownFinding(ARow: Integer): Integer;
    procedure ListCell(Sender: TObject; Row, Col: Integer; var AText: string);
    procedure ListActivate(Sender: TObject; Index: Integer);
    procedure ListSel(Sender: TObject);
    procedure AgainClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure OpenRows(const ARows: TIntegerArray);
    procedure FolderClick(Sender: TObject);
    procedure ListContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
    procedure SortItemClick(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor CreateCheck(AOwner: TComponent; const AScope: string);
    destructor Destroy; override;
  end;

procedure ShowLibraryCheck(AOwner: TComponent; const AScope: string; AOnCollect: TCheckCollectEvent;
  AOnOpen: TCheckOpenEvent);
var
  F: TLibraryCheckForm;
begin
  F := TLibraryCheckForm.CreateCheck(AOwner, AScope);
  try
    F.FOnCollect := AOnCollect;
    F.FOnOpen := AOnOpen;
    F.AgainClick(nil);
    F.ShowModal;
  finally
    F.Free;
  end;
end;

function CreateLibraryCheckForm(AOwner: TComponent; const AScope: string; ATracks: TTrackList): TAuForm;
var
  F: TLibraryCheckForm;
begin
  F := TLibraryCheckForm.CreateCheck(AOwner, AScope);
  F.TakeTracks(ATracks);
  Result := F;
end;

procedure LibraryCheckOpenRows(AForm: TAuForm; const ARows: array of Integer; AOnOpen: TCheckOpenEvent);
var
  F: TLibraryCheckForm;
  I: Integer;
begin
  if not (AForm is TLibraryCheckForm) then Exit;
  F := TLibraryCheckForm(AForm);
  F.FOnOpen := AOnOpen;
  F.FList.ClearSelection;
  for I := 0 to High(ARows) do F.FList.Selected[ARows[I]] := True;
  F.UpdateState;
  F.OpenClick(nil);
end;

function LibraryCheckFilter(AForm: TAuForm; const AKindName: string): Boolean;
var
  F: TLibraryCheckForm;
  I: Integer;
begin
  Result := False;
  if not (AForm is TLibraryCheckForm) then Exit;
  F := TLibraryCheckForm(AForm);
  for I := 0 to High(F.FFilterKinds) do
    if ((AKindName = '') and (F.FFilterKinds[I] < 0)) or
       ((F.FFilterKinds[I] >= 0) and SameText(CHECK_KIND_NAMES[TCheckKind(F.FFilterKinds[I])], AKindName)) then
    begin
      F.FFilter.ItemIndex := I;
      F.ApplyFilter;
      Exit(True);
    end;
end;

procedure LibraryCheckSort(AForm: TAuForm; ACol: Integer);
begin
  if AForm is TLibraryCheckForm then TLibraryCheckForm(AForm).HeaderClick(nil, ACol);
end;

function LibraryCheckCell(AForm: TAuForm; ARow, ACol: Integer): string;
begin
  Result := '';
  if AForm is TLibraryCheckForm then TLibraryCheckForm(AForm).ListCell(nil, ARow, ACol, Result);
end;

function LibraryCheckRowCount(AForm: TAuForm): Integer;
begin
  if AForm is TLibraryCheckForm then Result := TLibraryCheckForm(AForm).FList.RowCount else Result := -1;
end;

procedure LibraryCheckSelect(AForm: TAuForm; const ARows: array of Integer);
var
  F: TLibraryCheckForm;
  Rows: TIntegerArray;
  I: Integer;
begin
  if not (AForm is TLibraryCheckForm) or (Length(ARows) = 0) then Exit;
  F := TLibraryCheckForm(AForm);
  Rows := nil;
  SetLength(Rows, Length(ARows));
  for I := 0 to High(ARows) do Rows[I] := ARows[I];
  F.FList.RestoreSelection(Rows, ARows[High(ARows)], -1);
end;

function LibraryCheckSelection(AForm: TAuForm): string;
var
  F: TLibraryCheckForm;
  Sel: TIntegerArray;
  I: Integer;
begin
  Result := '';
  if not (AForm is TLibraryCheckForm) then Exit;
  F := TLibraryCheckForm(AForm);
  Sel := F.FList.SelectedRows;
  for I := 0 to High(Sel) do
  begin
    if I > 0 then Result := Result + ' | ';
    Result := Result + LibraryCheckCell(AForm, Sel[I], 0) + ': ' + LibraryCheckCell(AForm, Sel[I], 1);
  end;
end;

constructor TLibraryCheckForm.CreateCheck(AOwner: TComponent; const AScope: string);
begin
  CreateAu(AOwner, 'Tag consistency', DLG_W, DLG_H);
  HelpKeyword := 'Tag consistency';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];
  Constraints.MinWidth := S(640);
  Constraints.MinHeight := S(360);
  FitToWorkArea;
  FScope := AScope;

  FHead := AddLabel(Self, '', 24, 16, DLG_W - 48, False);
  FFilter := TAuCombo.Create(Self);
  FFilter.Parent := Body;
  FFilter.Hint := 'Show the findings of one kind only.';
  FFilter.ShowHint := True;
  FFilter.OnChange := @FilterChange;
  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.RowMenu := False;
  FList.MultiSelect := True;
  FList.RowHeight := S(30);
  FList.BackRole := crCard;
  FList.AddColumn('Kind', 210);
  FList.AddColumn('Finding', 480, 0, True);
  FList.AddColumn('Note', 190);
  FList.OnGetCell := @ListCell;
  FList.OnHeaderClick := @HeaderClick;
  FList.SortColumn := 0;
  FList.OnActivate := @ListActivate;
  FList.OnSelChange := @ListSel;

  FNote := AddLabel(Self, 'Nothing is changed here. A finding opens its files in Properties.', 24, 0, 400);
  FNote.FontSize := 12;
  FBtnAgain := AddButton(Self, 'Check again', 0, 0, 140, bkNormal, @AgainClick);
  FBtnAgain.Icon := icRefresh;
  FBtnAgain.Hint := 'Read this part of the library again, after tags were changed.';
  FBtnAgain.ShowHint := True;
  FBtnFolder := AddButton(Self, 'Open folder', 0, 0, 150, bkNormal, @FolderClick);
  FBtnFolder.Icon := icFolder;
  FBtnFolder.Hint := 'Show the folder of the selected finding in Explorer.';
  FBtnFolder.ShowHint := True;
  FList.OnRowContext := @ListContext;
  FBtnClose := AddButton(Self, 'Close', 0, 0, 110);
  FBtnClose.ModalResult := mrCancel;
  FBtnOpen := AddButton(Self, 'Open in Properties', 0, 0, 190, bkPrimary, @OpenClick);
  FBtnOpen.Icon := icTag;
  DefaultButton := FBtnOpen;

  FFilter.TabOrder := 0;
  FList.TabOrder := 1;
  FBtnAgain.TabOrder := 2;
  FBtnOpen.TabOrder := 3;
  FBtnClose.TabOrder := 4;
  Layout;
  UpdateState;
end;

destructor TLibraryCheckForm.Destroy;
begin
  FSelKeys.Free;
  FRowMenu.Free;
  inherited Destroy;
end;

procedure TLibraryCheckForm.Layout;
var
  W, H, BY: Integer;
begin
  if FBtnOpen = nil then Exit;
  W := ClientWidth;
  H := BodyHeight;
  BY := H - S(24) - S(34);
  FFilter.SetBounds(W - S(24) - S(300), S(12), S(300), S(32));
  FHead.SetBounds(S(24), S(16), Math.Max(0, FFilter.Left - S(40)), S(24));
  FList.SetBounds(S(24), S(54), W - S(48), BY - S(16) - S(28) - S(54));
  FNote.SetBounds(S(24), FList.Top + FList.Height + S(6), W - S(48), S(22));
  FBtnAgain.SetBounds(S(24), BY, S(140), S(34));
  FBtnFolder.SetBounds(S(24) + S(140) + S(10), BY, S(150), S(34));
  FBtnClose.SetBounds(W - S(24) - S(110), BY, S(110), S(34));
  FBtnOpen.SetBounds(FBtnClose.Left - S(10) - S(190), BY, S(190), S(34));
end;

procedure TLibraryCheckForm.Resize;
begin
  inherited Resize;
  Layout;
end;

procedure TLibraryCheckForm.TakeTracks(ATracks: TTrackList);
begin
  if ATracks = nil then FTrackCount := 0 else FTrackCount := ATracks.Count;
  CheckTracks(ATracks, FFound);
  FillFilter;
  ApplyFilter;
end;

{ the filter's entries: all kinds, then each kind that has findings, with
  their counts; the kind that was chosen stays chosen while it has any }
procedure TLibraryCheckForm.FillFilter;
var
  Counts: array[TCheckKind] of Integer;
  K: TCheckKind;
  I, Was, N: Integer;
begin
  Was := -1;
  if (FFilter.ItemIndex >= 0) and (FFilter.ItemIndex < Length(FFilterKinds)) then Was := FFilterKinds[FFilter.ItemIndex];
  for K := Low(TCheckKind) to High(TCheckKind) do Counts[K] := 0;
  for I := 0 to High(FFound) do Inc(Counts[FFound[I].Kind]);
  FFilter.Items.Clear;
  SetLength(FFilterKinds, Ord(High(TCheckKind)) + 2);
  FFilter.Items.Add(Format('All kinds (%d)', [Length(FFound)]));
  FFilterKinds[0] := -1;
  N := 1;
  for K := Low(TCheckKind) to High(TCheckKind) do
    if Counts[K] > 0 then
    begin
      FFilter.Items.Add(Format('%s (%d)', [CHECK_KIND_NAMES[K], Counts[K]]));
      FFilterKinds[N] := Ord(K);
      Inc(N);
    end;
  SetLength(FFilterKinds, N);
  FFilter.OnChange := nil;
  try
    FFilter.ItemIndex := 0;
    for I := 0 to N - 1 do
      if FFilterKinds[I] = Was then FFilter.ItemIndex := I;
  finally
    FFilter.OnChange := @FilterChange;
  end;
  FFilter.Invalidate;
end;

{ the findings of the chosen kind into the list }
procedure TLibraryCheckForm.ApplyFilter;
var
  Kind, I, N, NSel, Focus, At, OldTop, OldFocus, OldCount: Integer;
  Rows: TIntegerArray;
  Key: string;
begin
  Kind := -1;
  if (FFilter.ItemIndex >= 0) and (FFilter.ItemIndex < Length(FFilterKinds)) then Kind := FFilterKinds[FFilter.ItemIndex];
  SetLength(FShown, Length(FFound));
  N := 0;
  for I := 0 to High(FFound) do
    if (Kind < 0) or (Ord(FFound[I].Kind) = Kind) then
    begin
      FShown[N] := I;
      Inc(N);
    end;
  SetLength(FShown, N);
  SortShown;
  { the findings that were selected are selected again, wherever they are
    now; the same list in the same order stays where it was scrolled to }
  OldTop := FList.TopRow;
  OldFocus := FList.FocusedRow;
  OldCount := FList.RowCount;
  FRestoring := True;
  try
    FList.ClearSelection;
    FList.RowCount := N;
    Rows := nil;
    SetLength(Rows, N);
    NSel := 0;
    Focus := -1;
    if FSelKeys <> nil then
      for I := 0 to N - 1 do
      begin
        Key := FindingKey(FShown[I]);
        if FSelKeys.Find(Key, At) then
        begin
          Rows[NSel] := I;
          Inc(NSel);
        end;
        if Key = FFocusKey then Focus := I;
      end;
    SetLength(Rows, NSel);
    if NSel = 0 then
    begin
      if N > 0 then FList.SelectOnly(0);
    end
    else
    begin
      if Focus < 0 then Focus := Rows[0];
      if (N = OldCount) and (Focus = OldFocus) then FList.RestoreSelection(Rows, Focus, OldTop)
      else FList.RestoreSelection(Rows, Focus, -1);
    end;
  finally
    FRestoring := False;
  end;
  NoteSelection;
  FList.Changed;
  UpdateState;
end;

function TLibraryCheckForm.FindingKey(AFinding: Integer): string;
begin
  if (AFinding < 0) or (AFinding > High(FFound)) then Exit('');
  Result := IntToStr(Ord(FFound[AFinding].Kind)) + #1 + FFound[AFinding].Text;
end;

{ which findings are selected, in a form that outlives the list's rows }
procedure TLibraryCheckForm.NoteSelection;
var
  Sel: TIntegerArray;
  I: Integer;
begin
  if FSelKeys = nil then
  begin
    FSelKeys := TStringList.Create;
    FSelKeys.UseLocale := False;
    FSelKeys.CaseSensitive := True;
    FSelKeys.Sorted := True;
    FSelKeys.Duplicates := dupIgnore;
  end;
  FSelKeys.Clear;
  Sel := FList.SelectedRows;
  for I := 0 to High(Sel) do FSelKeys.Add(FindingKey(ShownFinding(Sel[I])));
  FFocusKey := FindingKey(ShownFinding(FList.FocusedRow));
end;

{ A click on a column heading sorts by it, a second one backwards. Kind: by
  kind and within one the most files first (the order of the check). Finding:
  by its text, so the lines of one album stand together. Note: by the number
  of files, the most first. }
procedure TLibraryCheckForm.HeaderClick(Sender: TObject; Col: Integer);
begin
  if (Col < 0) or (Col > 2) then Exit;
  if Col = FSortCol then FSortDesc := not FSortDesc
  else
  begin
    FSortCol := Col;
    FSortDesc := False;
  end;
  FList.SortColumn := FSortCol;
  FList.SortDescending := FSortDesc;
  ApplyFilter;
end;

{ finding A (a place in FFound) comes before B in the chosen order }
function TLibraryCheckForm.ShownBefore(A, B: Integer): Boolean;
var
  R: Integer;
begin
  R := 0;
  case FSortCol of
    1: R := AnsiCompareText(FFound[A].Text, FFound[B].Text);
    2: R := Length(FFound[B].Paths) - Length(FFound[A].Paths);
  end;
  { FFound is in the order of the check: the place decides what is left }
  if R = 0 then R := A - B;
  if FSortDesc then R := -R;
  Result := R < 0;
end;

procedure TLibraryCheckForm.SortShown;

  procedure Sort(L, R: Integer);
  var
    I, J, P, Tmp: Integer;
  begin
    while L < R do
    begin
      I := L;
      J := R;
      P := FShown[(L + R) shr 1];
      repeat
        while ShownBefore(FShown[I], P) do Inc(I);
        while ShownBefore(P, FShown[J]) do Dec(J);
        if I <= J then
        begin
          Tmp := FShown[I];
          FShown[I] := FShown[J];
          FShown[J] := Tmp;
          Inc(I);
          Dec(J);
        end;
      until I > J;
      if J - L < R - I then
      begin
        Sort(L, J);
        L := I;
      end
      else
      begin
        Sort(I, R);
        R := J;
      end;
    end;
  end;

begin
  if (FSortCol = 0) and not FSortDesc then Exit;      // (as found)
  if Length(FShown) > 1 then Sort(0, High(FShown));
end;

procedure TLibraryCheckForm.FilterChange(Sender: TObject);
begin
  ApplyFilter;
end;

{ the finding of a line of the list (-1: none) }
function TLibraryCheckForm.ShownFinding(ARow: Integer): Integer;
begin
  if (ARow >= 0) and (ARow < Length(FShown)) then Result := FShown[ARow] else Result := -1;
end;

procedure TLibraryCheckForm.UpdateState;
var
  S1: string;
begin
  if FTrackCount = 1 then S1 := '1 track' else S1 := Format('%d tracks', [FTrackCount]);
  if Length(FFound) = 1 then S1 := S1 + ', 1 finding'
  else S1 := S1 + Format(', %d findings', [Length(FFound)]);
  FHead.Caption := FScope + ':  ' + S1;
  if FTrackCount = 0 then FList.EmptyText := 'No tracks here.'
  else FList.EmptyText := 'Nothing found.';
  FBtnOpen.Enabled := FList.SelCount > 0;
  FBtnFolder.Enabled := FList.SelCount > 0;
end;

procedure TLibraryCheckForm.ListCell(Sender: TObject; Row, Col: Integer; var AText: string);
begin
  Row := ShownFinding(Row);
  if Row < 0 then Exit;
  case Col of
    0: AText := CHECK_KIND_NAMES[FFound[Row].Kind];
    1: AText := FFound[Row].Text;
    2: AText := FFound[Row].Note;
  end;
end;

procedure TLibraryCheckForm.ListSel(Sender: TObject);
begin
  if not FRestoring then NoteSelection;
  UpdateState;
end;

{ a double click: the selected findings when the line is one of them, else
  that line alone }
procedure TLibraryCheckForm.ListActivate(Sender: TObject; Index: Integer);
var
  One: TIntegerArray;
begin
  if (Index >= 0) and FList.Selected[Index] then
    OpenRows(FList.SelectedRows)
  else
  begin
    One := nil;
    SetLength(One, 1);
    One[0] := Index;
    OpenRows(One);
  end;
end;

procedure TLibraryCheckForm.OpenClick(Sender: TObject);
begin
  if FBtnOpen.Enabled then OpenRows(FList.SelectedRows);
end;

{ the files of these findings, each file once, in the order of the findings }
procedure TLibraryCheckForm.OpenRows(const ARows: TIntegerArray);
var
  SL, Seen: TStringList;
  I, K, F, At: Integer;
begin
  if not Assigned(FOnOpen) then Exit;
  SL := TStringList.Create;
  Seen := TStringList.Create;
  try
    Seen.UseLocale := False;
    Seen.CaseSensitive := False;
    Seen.Sorted := True;
    for K := 0 to High(ARows) do
    begin
      F := ShownFinding(ARows[K]);
      if F < 0 then Continue;
      for I := 0 to High(FFound[F].Paths) do
        if not Seen.Find(FFound[F].Paths[I], At) then
        begin
          Seen.Add(FFound[F].Paths[I]);
          SL.Add(FFound[F].Paths[I]);
        end;
    end;
    if SL.Count > 0 then FOnOpen(SL);
  finally
    Seen.Free;
    SL.Free;
  end;
end;

{ Explorer at the folder of the first selected finding (the folder of its
  first file: a finding about names can reach over several folders) }
procedure TLibraryCheckForm.FolderClick(Sender: TObject);
var
  Rows: TIntegerArray;
  F: Integer;
begin
  Rows := FList.SelectedRows;
  if Length(Rows) = 0 then Exit;
  F := ShownFinding(Rows[0]);
  if (F < 0) or (Length(FFound[F].Paths) = 0) then Exit;
  OpenFolderWithWindow(Self, FolderOfFile(FFound[F].Paths[0]));
end;

procedure TLibraryCheckForm.SortItemClick(Sender: TObject);
begin
  if Sender is TAuMenuItem then HeaderClick(nil, TAuMenuItem(Sender).Tag);
end;

procedure TLibraryCheckForm.ListContext(Sender: TObject; Row: Integer; ScreenPt: TPoint);
const
  SORT_NAMES: array[0..2] of string = ('Kind', 'Finding', 'Note');
var
  Sub: TAuMenu;
  It: TAuMenuItem;
  I: Integer;
begin
  if FList.SelCount = 0 then Exit;
  FRowMenu.Free;
  FRowMenu := TAuMenu.Create;
  FRowMenu.Add('Open in Properties', @OpenClick, icTag);
  FRowMenu.Add('Open folder...', @FolderClick, icFolder);
  { what a click on a column heading does, for the keyboard }
  Sub := FRowMenu.AddSub('Sort by', icSortAsc);
  for I := 0 to High(SORT_NAMES) do
  begin
    It := Sub.Add(SORT_NAMES[I], @SortItemClick, icNone, '', I);
    It.Checked := I = FSortCol;
  end;
  FRowMenu.Popup(ScreenPt.X, ScreenPt.Y);
end;

{ the same part of the library, as its records are now }
procedure TLibraryCheckForm.AgainClick(Sender: TObject);
var
  TL: TTrackList;
  OldCursor: TCursor;
begin
  if not Assigned(FOnCollect) then Exit;
  TL := TTrackList.Create;
  OldCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    FOnCollect(TL);
    TakeTracks(TL);
  finally
    Screen.Cursor := OldCursor;
    TL.Free;
  end;
end;

end.
