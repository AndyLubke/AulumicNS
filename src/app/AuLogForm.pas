unit AuLogForm;

{ ==============================================================================
  AulumicNS - AuLogForm
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Log window (Main menu > Tools > Show Log...,
  Ctrl+L): the lines of AuLog in a list with a fixed-width font; the time
  is dimmed, warnings and errors are shown in their colours. Not modal, one
  window; while it is open it follows the log (it stays at the end when it
  was at the end).
    - select lines and copy them: Ctrl+C or Copy (nothing selected: all),
      Ctrl+A selects all
    - Save to File... (Ctrl+S): the log and the error history
    - Clear: the lines (the error history stays)
  The lines are a list, not a memo, so they keep the
  colours and the window stays fast with the 5000 lines of a long session.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, Dialogs, LCLType, Clipbrd,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms;

function ShowLogWindow(AOwner: TComponent): TAuForm;
procedure CloseLogWindow;

implementation

uses
  AuLog, uAppConsts, uAppStrings;

type
  { TLogForm }

  TLogForm = class(TAuForm)
  private
    FList: TAuListView;
    FInfo: TAuLabel;
    FBtnSave, FBtnCopy, FBtnClear, FBtnClose: TAuButton;
    FMaxLen: Integer;          // the longest line (characters)
    FMeasured: Integer;        // lines measured so far
    procedure LogChanged(Sender: TObject);
    procedure SyncRows;
    procedure UpdateWidth;
    procedure UpdateInfo;
    procedure DrawCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure SelChange(Sender: TObject);
    procedure ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SaveClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure Layout;
  protected
    procedure Resize; override;
    procedure DpiUpdated; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateLog(AOwner: TComponent);
    destructor Destroy; override;
  end;

var
  GLogForm: TLogForm = nil;

const
  LOG_FONT = 12;
  TIME_CHARS = 11;              // 'hh:nn:ss - '

function ShowLogWindow(AOwner: TComponent): TAuForm;
begin
  if GLogForm = nil then GLogForm := TLogForm.CreateLog(AOwner);
  GLogForm.Show;
  if GLogForm.WindowState = wsMinimized then GLogForm.WindowState := wsNormal;
  GLogForm.BringToFront;
  Result := GLogForm;
end;

procedure CloseLogWindow;
begin
  FreeAndNil(GLogForm);
end;

function CharWidth: Single;
begin
  Result := TextWidth('0000000000', MonoFont(LOG_FONT)) / 10;
end;

{ ---- TLogForm ---- }

constructor TLogForm.CreateLog(AOwner: TComponent);
begin
  CreateAu(AOwner, 'Log', FORM_APPLOG_WIDTH, FORM_APPLOG_HEIGHT);
  HelpKeyword := 'Log files & troubleshooting';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Position := poOwnerFormCenter;
  Constraints.MinWidth := S(FORM_APPLOG_MINWIDTH);
  Constraints.MinHeight := S(FORM_APPLOG_MINHEIGHT);
  FitToWorkArea;          // a small screen at a large scaling

  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.ShowHeader := False;
  FList.MultiSelect := True;
  FList.RowMenu := False;
  FList.RowHeight := S(20);
  FList.AddColumn('Line', 600);
  FList.FitPending := False;
  FList.EmptyText := 'The log is empty.';
  FList.BackRole := crCard;
  FList.OnDrawCell := @DrawCell;
  FList.OnSelChange := @SelChange;
  FList.OnKeyDown := @ListKey;
  FList.TabOrder := 0;

  FInfo := AddLabel(Self, '', 20, 0, 300);
  FInfo.HAlign := 2;
  FBtnSave := AddButton(Self, 'Save to file...', 0, 0, 140, bkNormal, @SaveClick);
  FBtnSave.Icon := icExport;
  FBtnSave.Hint := 'Save the log and the error history to a text file (Ctrl+S).';
  FBtnSave.ShowHint := True;
  FBtnCopy := AddButton(Self, 'Copy', 0, 0, 100, bkNormal, @CopyClick);
  FBtnCopy.Icon := icCopy;
  FBtnCopy.Hint := 'Copy the selected lines, or all lines when none is selected (Ctrl+C).';
  FBtnCopy.ShowHint := True;
  FBtnClear := AddButton(Self, 'Clear', 0, 0, 100, bkNormal, @ClearClick);
  FBtnClear.Icon := icTrash;
  FBtnClear.Hint := 'Remove the lines from the window. The error history is kept for Save to file.';
  FBtnClear.ShowHint := True;
  FBtnClose := AddButton(Self, 'Close', 0, 0, 100, bkPrimary, @CloseClick);
  FBtnSave.TabOrder := 1;
  FBtnCopy.TabOrder := 2;
  FBtnClear.TabOrder := 3;
  FBtnClose.TabOrder := 4;
  ActiveControl := FList;

  AppLog.OnChanged := @LogChanged;
  SyncRows;
  Layout;
  if FList.RowCount > 0 then FList.EnsureVisible(FList.RowCount - 1);
end;

destructor TLogForm.Destroy;
begin
  if (GLogForm = Self) then GLogForm := nil;
  if AppLog.OnChanged = @LogChanged then AppLog.OnChanged := nil;
  inherited Destroy;
end;

procedure TLogForm.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  CloseAction := caFree;
end;

procedure TLogForm.Layout;
var
  W, H, X, BY: Integer;
begin
  if FList = nil then Exit;
  W := ClientWidth;
  H := BodyHeight;
  BY := H - S(52);
  FList.SetBounds(S(16), S(12), W - S(32), BY - S(12) - S(12));
  X := S(16);
  FBtnSave.Width := Math.Max(S(140), FBtnSave.PreferredWidth);
  FBtnSave.SetBounds(X, BY, FBtnSave.Width, S(34));
  Inc(X, FBtnSave.Width + S(8));
  FBtnCopy.SetBounds(X, BY, Math.Max(S(100), FBtnCopy.PreferredWidth), S(34));
  Inc(X, FBtnCopy.Width + S(8));
  FBtnClear.SetBounds(X, BY, Math.Max(S(100), FBtnClear.PreferredWidth), S(34));
  Inc(X, FBtnClear.Width + S(16));
  FBtnClose.SetBounds(W - S(16) - S(100), BY, S(100), S(34));
  FInfo.SetBounds(X, BY, Math.Max(0, FBtnClose.Left - S(12) - X), S(34));
end;

procedure TLogForm.Resize;
begin
  inherited Resize;
  Layout;
end;

procedure TLogForm.DpiUpdated;
begin
  inherited DpiUpdated;
  FMeasured := 0;
  FMaxLen := 0;
  UpdateWidth;
  Layout;
end;

procedure TLogForm.LogChanged(Sender: TObject);
begin
  SyncRows;
end;

{ the rows follow the log; at the end the window stays at the end }
procedure TLogForm.SyncRows;
var
  N: Integer;
  AtEnd: Boolean;
begin
  N := AppLog.Lines.Count;
  AtEnd := (FList.RowCount = 0) or (FList.TopRow + FList.PageRows >= FList.RowCount);
  if N < FList.RowCount then
  begin
    { cleared or purged: the old lines are gone }
    FList.ClearSelection;
    FMeasured := 0;
    FMaxLen := 0;
  end;
  FList.RowCount := N;
  UpdateWidth;
  if AtEnd and (N > 0) then FList.EnsureVisible(N - 1);
  FList.Invalidate;
  UpdateInfo;
end;

{ the column is as wide as the longest line (fixed-width font: characters
  times the width of one) }
procedure TLogForm.UpdateWidth;
var
  I, L: Integer;
  Lines: TStringList;
begin
  Lines := AppLog.Lines;
  if FMeasured > Lines.Count then FMeasured := 0;
  for I := FMeasured to Lines.Count - 1 do
  begin
    L := Length(UTF8Decode(Lines[I]));
    if L > FMaxLen then FMaxLen := L;
  end;
  FMeasured := Lines.Count;
  FList.SetColumnWidth(0, Math.Max(400, Ceil(FMaxLen * CharWidth / UIScale) + 32));
end;

procedure TLogForm.UpdateInfo;
begin
  if FList.SelCount > 1 then
    FInfo.Caption := Format('%d of %d lines selected', [FList.SelCount, FList.RowCount])
  else if FList.RowCount = 1 then
    FInfo.Caption := '1 line'
  else
    FInfo.Caption := Format('%d lines', [FList.RowCount]);
end;

procedure TLogForm.SelChange(Sender: TObject);
begin
  UpdateInfo;
end;

procedure TLogForm.DrawCell(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
var
  Line, Head, Rest, Sev: string;
  F: TGfxFont;
  C: TARGB;
  CW: Single;
begin
  Handled := True;
  if (Row < 0) or (Row >= AppLog.Lines.Count) then Exit;
  Line := AppLog.Lines[Row];
  F := MonoFont(LOG_FONT);
  CW := CharWidth;
  X := X + S(8);
  { "hh:nn:ss - [SEVERITY] text": the time dimmed, the rest by severity }
  if (Length(Line) > TIME_CHARS + 2) and (Line[3] = ':') and (Line[6] = ':') and
     (Copy(Line, 9, 3) = ' - ') then
  begin
    Head := Copy(Line, 1, TIME_CHARS);
    Rest := Copy(Line, TIME_CHARS + 1, MaxInt);
    Sev := Copy(Rest, 1, 9);
    if Copy(Sev, 1, 7) = '[ERROR]' then C := clBad
    else if Sev = '[WARNING]' then C := clWarn
    else C := clText;
    G.Text(Head, X, Y, TIME_CHARS * CW + S(4), H, F, clTextFaint, 0, 1);
    G.Text(Rest, X + TIME_CHARS * CW, Y, Math.Max(0, W - TIME_CHARS * CW), H, F, C, 0, 1);
  end
  else
  begin
    { a date line, a detail line, the purge notice }
    if Copy(Line, 1, 4) = '--- ' then C := clAccentText
    else if (Line <> '') and (Line[1] = ' ') then C := clText
    else C := clTextDim;
    G.Text(Line, X, Y, W, H, F, C, 0, 1);
  end;
end;

procedure TLogForm.ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = Ord('C')) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    CopyClick(nil);
  end;
end;

procedure TLogForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = Ord('S')) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    SaveClick(nil);
    Exit;
  end;
  if (Key = Ord('L')) and (Shift = [ssCtrl]) then
  begin
    { Ctrl+L again closes the window }
    Key := 0;
    Close;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TLogForm.SaveClick(Sender: TObject);
var
  D: TSaveDialog;
  Err: string;
begin
  D := TSaveDialog.Create(Self);
  try
    D.Title := DIALOG_TITLE_SAVE_LOG;
    D.Filter := DIALOG_FILTER_TEXT_FILES;
    D.DefaultExt := 'txt';
    D.FileName := Format(FMT_LOG_SAVE_FILE_NAME, [FormatDateTime('yyyymmdd_hhnn', Now)]);
    D.Options := D.Options + [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    if not AppLog.SaveToFileEx(D.FileName, Err) then
      AuMessage(Format(FMT_ERR_SAVE_LOG, [D.FileName, Err]), amError, abOK, TITLE_ERROR);
  finally
    D.Free;
  end;
end;

procedure TLogForm.CopyClick(Sender: TObject);
var
  SL: TStringList;
  Sel: TIntegerArray;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    Sel := FList.SelectedRows;
    if Length(Sel) = 0 then SL.Assign(AppLog.Lines)
    else
      for I := 0 to High(Sel) do
        if Sel[I] < AppLog.Lines.Count then SL.Add(AppLog.Lines[Sel[I]]);
    if SL.Count > 0 then Clipboard.AsText := TrimRight(SL.Text);
  finally
    SL.Free;
  end;
end;

procedure TLogForm.ClearClick(Sender: TObject);
begin
  AppLog.Clear;
end;

procedure TLogForm.CloseClick(Sender: TObject);
begin
  Close;
end;

end.
