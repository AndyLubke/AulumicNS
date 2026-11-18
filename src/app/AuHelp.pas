unit AuHelp;

{ ==============================================================================
  AulumicNS - AuHelp
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The help window, with a small native Markdown renderer.

  Supported Markdown:
    # / ## / ###           headings (# and ## appear in the topic list)
    paragraphs             consecutive lines are joined; blank line = new paragraph
    - item / * item        bullets;  "  - item" = second level
    1. item                numbered items
    > text                 note box
    ---                    horizontal rule
    | a | b |              tables (first row = header when followed by |---|)
    **bold**  *italic*  `code`     inline styles;  \*  \`  \\  escapes
    <!-- ... -->           comments
    ![caption](name)       a screenshot

  The help text is built into the exe
  (resource AULUMICNSHELP, from help\AulumicNS_help.md); a file
  AulumicNS_help.md next to the exe overrides it. The screenshots are built
  in as well (resources HELPIMG_<NAME>, from help\shots\<name>.png, made at
  150 % by Tools\MakeHelpShots.ps1); a file help\shots\<name>.png next to the
  exe overrides one. They are drawn at their size for the window's scaling,
  at most the width of the text. The controls are on Body (the own title
  bar); F1 in a dialog opens the topic of its HelpKeyword (AuShowHelp).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType, AuGfx, AuTheme, AuIcons, AuControls,
  AuLists, AuForms;

type
  TMdKind = (mkH1, mkH2, mkH3, mkPara, mkBullet1, mkBullet2, mkNumber, mkQuote, mkRule, mkTable, mkImage);

  TMdTok = record
    Text: UnicodeString;
    Bold, Italic, Code, Space: Boolean;
  end;
  TMdToks = array of TMdTok;

  TMdRun = record
    Text: UnicodeString;
    X, W: Single;
    Bold, Italic, Code: Boolean;
  end;

  TMdLine = record
    Runs: array of TMdRun;
    Y, H: Single;                 // relative to the start of the text
  end;
  TMdLines = array of TMdLine;

  TMdCell = record
    Toks: TMdToks;
    Lines: TMdLines;
    H: Single;
  end;

  TMdBlock = record
    Kind: TMdKind;
    Number: Integer;
    Toks: TMdToks;
    Plain: UnicodeString;         // lower case, for searching
    Lines: TMdLines;
    TextH: Single;
    Top, Bottom: Single;          // absolute document coordinates
    Rows: array of array of TMdCell;
    HeaderRow: Boolean;
    ColW, RowH: array of Single;
    { mkImage: the screenshot's name, its size (from the PNG header), its
      drawn size, and the bitmap decoded at that size while it is near the
      view (DecW: its width; freed when it scrolls away); the caption is Toks }
    ImgName: string;
    NatW, NatH: Integer;
    ImgTried: Boolean;
    ImgW, ImgH: Single;
    Bmp: TGfxBitmap;
    DecW: Integer;
  end;

  TMdTopic = record
    Title: string;
    Block: Integer;
    Level: Integer;
  end;

  { TMdView }

  TMdView = class(TAuControl)
  private
    FBlocks: array of TMdBlock;
    FScroll: TAuScrollBar;
    FSize: Single;
    FLayoutW: Integer;
    FContentH: Integer;
    FHighlight: Integer;
    FOnScrolled: TNotifyEvent;
    procedure Parse(const Md: UnicodeString);
    procedure ParseInline(const S: UnicodeString; out Toks: TMdToks; out Plain: UnicodeString);
    function FontFor(Kind: TMdKind; B, I, C: Boolean): TGfxFont;
    procedure LayoutToks(const Toks: TMdToks; Kind: TMdKind; MaxW: Single; out Lines: TMdLines; out H: Single);
    procedure Layout;
    function ContentLeft: Single;
    function ContentW: Single;
    procedure ScrollChanged(Sender: TObject);
    procedure DrawLines(G: TGfx; const Lines: TMdLines; Kind: TMdKind; X, Y: Single; Fg: TARGB);
    procedure FreeImages;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Resize; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function PanBy(DX, DY: Integer): Boolean; override;   // touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    Topics: array of TMdTopic;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadMarkdown(const Md: string);
    procedure ScrollToBlock(I: Integer);
    procedure ScrollTo(Y: Integer);
    function TopBlock: Integer;
    function FindText(const Q: string; FromBlock: Integer): Integer;
    procedure Zoom(Delta: Single);
    property Highlight: Integer read FHighlight write FHighlight;
    property OnScrolled: TNotifyEvent read FOnScrolled write FOnScrolled;
  end;

procedure ShowHelpWindow(const Topic: string = '');
procedure CloseHelpWindow;
{ the window at a topic, not shown (screenshot mode) }
function CreateHelpForm(AOwner: TComponent; const Topic: string): TAuForm;
{ a screenshot of the help: help\shots\<name>.png next to the exe, else the
  resource HELPIMG_<NAME>, scaled to at most AMaxSide pixels (0 = its
  size); nil when there is none }
function LoadHelpImage(const AName: string; AMaxSide: Integer = 0): TGfxBitmap;
{ its size, read from the PNG header (nothing decoded) }
function HelpImageSize(const AName: string; out W, H: Integer): Boolean;
{ the resource name of a screenshot (HELPIMG_ + the name in capitals, '-'
  and ' ' as '_'); Tools\MakeHelpShots.ps1 names them the same way }
function HelpImageResName(const AName: string): string;

implementation

type
  { THelpWindow }

  THelpWindow = class(TAuForm)
  private
    FView: TMdView;
    FTopics: TAuListView;
    FSearch: TAuEdit;
    FSyncing: Boolean;
    procedure TopicDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure TopicClick(Sender: TObject; Row: Integer);
    procedure TopicSel(Sender: TObject);
    procedure ViewScrolled(Sender: TObject);
    procedure SearchEnter(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure ZoomIn(Sender: TObject);
    procedure ZoomOut(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure HelpKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HelpClose(Sender: TObject; var CloseAction: TCloseAction);
  protected
    procedure DoShow; override;
  public
    { a topic to go to once the window is shown (its size is known then) }
    PendingTopic: string;
    constructor Create(AOwner: TComponent); override;
    procedure GoTopic(const Topic: string);
  end;

var
  HelpForm: THelpWindow = nil;

function LoadHelpText: string;
var
  FN: string;
  SL: TStringList;
  R: TResourceStream;
  S: AnsiString;
begin
  Result := '';
  FN := ExtractFilePath(Application.ExeName) + 'AulumicNS_help.md';
  if FileExists(FN) then
  begin
    SL := TStringList.Create;
    try
      SL.LoadFromFile(FN);
      Result := SL.Text;
    finally
      SL.Free;
    end;
  end
  else if FindResource(HInstance, 'AULUMICNSHELP', RT_RCDATA) <> 0 then
  begin
    R := TResourceStream.Create(HInstance, 'AULUMICNSHELP', RT_RCDATA);
    try
      SetLength(S, R.Size);
      if R.Size > 0 then R.ReadBuffer(S[1], R.Size);
      Result := S;
    finally
      R.Free;
    end;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
  if Result = '' then Result := '# Help' + LineEnding + 'The help text could not be loaded.';
end;

procedure ShowHelpWindow(const Topic: string);
begin
  if HelpForm = nil then HelpForm := THelpWindow.Create(Application);
  if HelpForm.WindowState = wsMinimized then HelpForm.WindowState := wsNormal;
  HelpForm.Show;
  HelpForm.BringToFront;
  if Topic <> '' then HelpForm.GoTopic(Topic);
end;

procedure CloseHelpWindow;
begin
  FreeAndNil(HelpForm);
end;

function CreateHelpForm(AOwner: TComponent; const Topic: string): TAuForm;
var
  F: THelpWindow;
begin
  F := THelpWindow.Create(AOwner);
  F.PendingTopic := Topic;
  Result := F;
end;

function HelpImageResName(const AName: string): string;
var
  I: Integer;
begin
  Result := 'HELPIMG_' + UpperCase(AName);
  for I := 1 to Length(Result) do
    if not (Result[I] in ['A'..'Z', '0'..'9', '_']) then Result[I] := '_';
end;

{ the stream of a screenshot (the file next to the exe, else the resource);
  nil when there is none }
function HelpImageStream(const AName: string): TStream;
var
  FN, RN: string;
begin
  Result := nil;
  if AName = '' then Exit;
  FN := ExtractFilePath(Application.ExeName) + 'help\shots\' + AName + '.png';
  if FileExists(FN) then
  begin
    try
      Result := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
    except
      Result := nil;
    end;
    Exit;
  end;
  RN := HelpImageResName(AName);
  if FindResource(HInstance, PChar(RN), RT_RCDATA) = 0 then Exit;
  Result := TResourceStream.Create(HInstance, RN, RT_RCDATA);
end;

function LoadHelpImage(const AName: string; AMaxSide: Integer): TGfxBitmap;
var
  St: TStream;
  Bytes: TBytes;
begin
  Result := nil;
  St := HelpImageStream(AName);
  if St = nil then Exit;
  try
    SetLength(Bytes, St.Size);
    if St.Size > 0 then St.ReadBuffer(Bytes[0], St.Size);
  finally
    St.Free;
  end;
  Result := ImageFromBytes(Bytes, AMaxSide);
end;

function HelpImageSize(const AName: string; out W, H: Integer): Boolean;
var
  St: TStream;
  Hd: array[0..23] of Byte;
begin
  Result := False;
  W := 0;
  H := 0;
  St := HelpImageStream(AName);
  if St = nil then Exit;
  try
    if St.Read(Hd, SizeOf(Hd)) <> SizeOf(Hd) then Exit;
  finally
    St.Free;
  end;
  { PNG: the signature, then the IHDR chunk with width and height (big endian) }
  if (Hd[0] <> $89) or (Hd[1] <> Ord('P')) or (Hd[12] <> Ord('I')) or (Hd[15] <> Ord('R')) then Exit;
  W := (Hd[16] shl 24) or (Hd[17] shl 16) or (Hd[18] shl 8) or Hd[19];
  H := (Hd[20] shl 24) or (Hd[21] shl 16) or (Hd[22] shl 8) or Hd[23];
  Result := (W > 0) and (H > 0);
end;

{ ---- TMdView: parsing ---- }

constructor TMdView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FWantKeys := True;
  TabStop := True;
  FSize := 14;
  FHighlight := -1;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alRight;
  FScroll.Width := S(12);
  FScroll.OnScroll := @ScrollChanged;
end;

destructor TMdView.Destroy;
begin
  FreeImages;
  inherited Destroy;
end;

procedure TMdView.FreeImages;
var
  I: Integer;
begin
  for I := 0 to High(FBlocks) do
    if FBlocks[I].Bmp <> nil then
    begin
      DisposeBitmap(FBlocks[I].Bmp);
      FBlocks[I].Bmp := nil;
    end;
end;

procedure TMdView.ParseInline(const S: UnicodeString; out Toks: TMdToks; out Plain: UnicodeString);
var
  P, N: Integer;
  InB, InI, InC: Boolean;
  Seg: UnicodeString;

  procedure Add(const T: UnicodeString; Sp: Boolean);
  var
    J: Integer;
  begin
    if T = '' then Exit;
    J := Length(Toks);
    SetLength(Toks, J + 1);
    Toks[J].Text := T;
    Toks[J].Bold := InB;
    Toks[J].Italic := InI;
    Toks[J].Code := InC;
    Toks[J].Space := Sp;
    Plain := Plain + T;
  end;

  procedure Flush;
  var
    PA, PB: Integer;
    Sp: Boolean;
  begin
    if InC then
    begin
      { a code span stays one piece (no line break inside) }
      Add(Seg, False);
      Seg := '';
      Exit;
    end;
    PA := 1;
    while PA <= Length(Seg) do
    begin
      Sp := Seg[PA] = ' ';
      PB := PA;
      while (PB <= Length(Seg)) and ((Seg[PB] = ' ') = Sp) do PB := PB + 1;
      if Sp then Add(' ', True) else Add(Copy(Seg, PA, PB - PA), False);
      PA := PB;
    end;
    Seg := '';
  end;

begin
  SetLength(Toks, 0);
  Plain := '';
  InB := False;
  InI := False;
  InC := False;
  Seg := '';
  P := 1;
  N := Length(S);
  while P <= N do
  begin
    if (not InC) and (S[P] = '\') and (P < N) and ((S[P + 1] = '*') or (S[P + 1] = '`') or (S[P + 1] = '\')) then
    begin
      Seg := Seg + S[P + 1];
      P := P + 2;
    end
    else if (not InC) and (P < N) and (S[P] = '*') and (S[P + 1] = '*') then
    begin
      Flush;
      InB := not InB;
      P := P + 2;
    end
    else if (not InC) and (S[P] = '*') then
    begin
      Flush;
      InI := not InI;
      P := P + 1;
    end
    else if S[P] = '`' then
    begin
      Flush;
      InC := not InC;
      P := P + 1;
    end
    else
    begin
      Seg := Seg + S[P];
      P := P + 1;
    end;
  end;
  Flush;
  Plain := LowerCase(Plain);
end;

procedure TMdView.Parse(const Md: UnicodeString);
var
  SL: TStringList;
  I, NB, J, NT: Integer;
  Raw, T, Body: UnicodeString;
  InComment: Boolean;
  Num: Integer;
  Cells: TStringList;
  TableRows: array of TStringList;
  Pending: UnicodeString;
  PendingKind: TMdKind;
  PendingNum: Integer;

  function IsSpecial(const L: UnicodeString): Boolean;
  var
    U: UnicodeString;
  begin
    U := Trim(L);
    Result := (U = '') or (Copy(U, 1, 1) = '#') or (Copy(U, 1, 2) = '- ') or (Copy(U, 1, 2) = '* ') or
      (Copy(U, 1, 1) = '>') or (Copy(U, 1, 1) = '|') or (U = '---') or (U = '***') or (Copy(U, 1, 2) = '![') or
      ((Length(U) > 2) and (U[1] in ['0'..'9']) and (Pos('. ', U) in [2, 3])) or (Copy(U, 1, 4) = '<!--');
  end;

  procedure AddBlock(AKind: TMdKind; const AText: UnicodeString; ANum: Integer);
  begin
    if NB >= Length(FBlocks) then SetLength(FBlocks, NB * 2 + 32);
    FBlocks[NB] := Default(TMdBlock);
    FBlocks[NB].Kind := AKind;
    FBlocks[NB].Number := ANum;
    ParseInline(AText, FBlocks[NB].Toks, FBlocks[NB].Plain);
    NB := NB + 1;
  end;

  procedure FlushPending;
  begin
    if Pending <> '' then AddBlock(PendingKind, Pending, PendingNum);
    Pending := '';
  end;

  procedure SplitRow(const L: UnicodeString; Dest: TStringList);
  var
    U: UnicodeString;
    K: Integer;
    Cur: UnicodeString;
  begin
    Dest.Clear;
    U := Trim(L);
    if Copy(U, 1, 1) = '|' then Delete(U, 1, 1);
    if Copy(U, Length(U), 1) = '|' then Delete(U, Length(U), 1);
    Cur := '';
    K := 1;
    while K <= Length(U) do
    begin
      if (U[K] = '\') and (K < Length(U)) and (U[K + 1] = '|') then
      begin
        Cur := Cur + '|';
        K := K + 2;
        Continue;
      end;
      if U[K] = '|' then
      begin
        Dest.Add(UTF8Encode(Trim(Cur)));
        Cur := '';
      end
      else Cur := Cur + U[K];
      K := K + 1;
    end;
    Dest.Add(UTF8Encode(Trim(Cur)));
  end;

  function IsSepRow(const L: UnicodeString): Boolean;
  var
    K: Integer;
  begin
    Result := Pos('-', L) > 0;
    for K := 1 to Length(L) do
      if not (L[K] in ['|', '-', ':', ' ']) then Exit(False);
  end;

var
  R, C, MaxC, PB: Integer;
  Pl: UnicodeString;
begin
  FreeImages;
  SetLength(FBlocks, 0);
  SetLength(Topics, 0);
  NB := 0;
  InComment := False;
  Pending := '';
  PendingKind := mkPara;
  PendingNum := 0;
  SL := TStringList.Create;
  Cells := TStringList.Create;
  try
    SL.Text := UTF8Encode(Md);
    I := 0;
    while I < SL.Count do
    begin
      Raw := UTF8Decode(SL[I]);
      T := Trim(Raw);
      I := I + 1;
      if InComment then
      begin
        if Pos('-->', T) > 0 then InComment := False;
        Continue;
      end;
      if Copy(T, 1, 4) = '<!--' then
      begin
        FlushPending;
        if Pos('-->', T) = 0 then InComment := True;
        Continue;
      end;
      if T = '' then
      begin
        FlushPending;
        Continue;
      end;
      { continuation of a paragraph / list item / note }
      if (Pending <> '') and not IsSpecial(Raw) then
      begin
        Pending := Pending + ' ' + T;
        Continue;
      end;
      if (Pending <> '') and (PendingKind = mkQuote) and (Copy(T, 1, 1) = '>') then
      begin
        Pending := Pending + ' ' + Trim(Copy(T, 2, MaxInt));
        Continue;
      end;
      FlushPending;
      if Copy(T, 1, 4) = '### ' then AddBlock(mkH3, Trim(Copy(T, 5, MaxInt)), 0)
      else if Copy(T, 1, 3) = '## ' then AddBlock(mkH2, Trim(Copy(T, 4, MaxInt)), 0)
      else if Copy(T, 1, 2) = '# ' then AddBlock(mkH1, Trim(Copy(T, 3, MaxInt)), 0)
      else if (T = '---') or (T = '***') then AddBlock(mkRule, '', 0)
      else if (Copy(T, 1, 2) = '![') and (Pos('](', T) > 0) and (T[Length(T)] = ')') then
      begin
        { a screenshot: ![caption](name) }
        PB := Pos('](', T);
        AddBlock(mkImage, Copy(T, 3, PB - 3), 0);
        FBlocks[NB - 1].ImgName := Trim(UTF8Encode(Copy(T, PB + 2, Length(T) - PB - 2)));
      end
      else if Copy(T, 1, 1) = '|' then
      begin
        { table: collect all consecutive table rows }
        SetLength(TableRows, 0);
        I := I - 1;
        while (I < SL.Count) and (Copy(Trim(UTF8Decode(SL[I])), 1, 1) = '|') do
        begin
          J := Length(TableRows);
          SetLength(TableRows, J + 1);
          TableRows[J] := TStringList.Create;
          SplitRow(UTF8Decode(SL[I]), TableRows[J]);
          if IsSepRow(Trim(UTF8Decode(SL[I]))) then TableRows[J].Insert(0, #1);
          I := I + 1;
        end;
        if NB >= Length(FBlocks) then SetLength(FBlocks, NB * 2 + 32);
        FBlocks[NB] := Default(TMdBlock);
        FBlocks[NB].Kind := mkTable;
        MaxC := 0;
        for J := 0 to High(TableRows) do
          if (TableRows[J].Count > 0) and (TableRows[J][0] <> #1) then MaxC := Max(MaxC, TableRows[J].Count);
        Pl := '';
        for J := 0 to High(TableRows) do
        begin
          if (TableRows[J].Count > 0) and (TableRows[J][0] = #1) then
          begin
            if J = 1 then FBlocks[NB].HeaderRow := True;
            Continue;
          end;
          R := Length(FBlocks[NB].Rows);
          SetLength(FBlocks[NB].Rows, R + 1);
          SetLength(FBlocks[NB].Rows[R], MaxC);
          for C := 0 to MaxC - 1 do
          begin
            if C < TableRows[J].Count then
              ParseInline(UTF8Decode(TableRows[J][C]), FBlocks[NB].Rows[R][C].Toks, Body)
            else
            begin
              SetLength(FBlocks[NB].Rows[R][C].Toks, 0);
              Body := '';
            end;
            Pl := Pl + Body + ' ';
          end;
        end;
        FBlocks[NB].Plain := Pl;
        for J := 0 to High(TableRows) do TableRows[J].Free;
        NB := NB + 1;
      end
      else if Copy(T, 1, 1) = '>' then
      begin
        Pending := Trim(Copy(T, 2, MaxInt));
        PendingKind := mkQuote;
      end
      else if ((Copy(Raw, 1, 4) = '  - ') or (Copy(Raw, 1, 4) = '  * ') or
               (Copy(Raw, 1, 5) = '    - ') or (Copy(Raw, 1, 1) = #9)) and
              ((Copy(T, 1, 2) = '- ') or (Copy(T, 1, 2) = '* ')) then
      begin
        Pending := Trim(Copy(T, 3, MaxInt));
        PendingKind := mkBullet2;
      end
      else if (Copy(T, 1, 2) = '- ') or (Copy(T, 1, 2) = '* ') then
      begin
        Pending := Trim(Copy(T, 3, MaxInt));
        PendingKind := mkBullet1;
      end
      else if (Length(T) > 2) and (T[1] in ['0'..'9']) and (Pos('. ', T) in [2, 3]) then
      begin
        Num := StrToIntDef(UTF8Encode(Copy(T, 1, Pos('. ', T) - 1)), 1);
        Pending := Trim(Copy(T, Pos('. ', T) + 2, MaxInt));
        PendingKind := mkNumber;
        PendingNum := Num;
      end
      else
      begin
        Pending := T;
        PendingKind := mkPara;
      end;
    end;
    FlushPending;
    SetLength(FBlocks, NB);
  finally
    Cells.Free;
    SL.Free;
  end;
  { topics: level 1 and 2 headings }
  NT := 0;
  for I := 0 to NB - 1 do
    if FBlocks[I].Kind in [mkH1, mkH2] then
    begin
      SetLength(Topics, NT + 1);
      Body := '';
      for J := 0 to High(FBlocks[I].Toks) do Body := Body + FBlocks[I].Toks[J].Text;
      Topics[NT].Title := UTF8Encode(Body);
      Topics[NT].Block := I;
      if FBlocks[I].Kind = mkH1 then Topics[NT].Level := 1 else Topics[NT].Level := 2;
      NT := NT + 1;
    end;
end;

procedure TMdView.LoadMarkdown(const Md: string);
begin
  Parse(UTF8Decode(Md));
  FLayoutW := -1;
  FScroll.Position := 0;
  FHighlight := -1;
  Layout;
  Invalidate;
end;

{ ---- layout ---- }

function TMdView.FontFor(Kind: TMdKind; B, I, C: Boolean): TGfxFont;
var
  Sz: Single;
begin
  case Kind of
    mkH1: Sz := FSize + 13;
    mkH2: Sz := FSize + 6;
    mkH3: Sz := FSize + 2.5;
  else
    Sz := FSize;
  end;
  if C then Exit(GetFont(Round(SF(Sz - 1) * 2) / 2, False, True));
  if Kind in [mkH1, mkH2, mkH3] then B := True;
  Result := GetFont(Round(SF(Sz) * 2) / 2, B, False, I);
end;

function TMdView.ContentLeft: Single;
begin
  Result := S(36);
end;

function TMdView.ContentW: Single;
begin
  Result := ClientWidth - FScroll.Width - 2 * ContentLeft;
  if Result > S(920) then Result := S(920);
  if Result < S(120) then Result := S(120);
end;

procedure TMdView.LayoutToks(const Toks: TMdToks; Kind: TMdKind; MaxW: Single; out Lines: TMdLines; out H: Single);
var
  T, K, NL, NR: Integer;
  X, W, GW, LH, Y: Single;
  F: TGfxFont;
  CodePad, Base: Single;
  BreakInside, NeedBreak: Boolean;

  function TokW(const Tk: TMdTok): Single;
  begin
    Result := TextWidthW(Tk.Text, FontFor(Kind, Tk.Bold, Tk.Italic, Tk.Code));
    if Tk.Code then Result := Result + CodePad;
  end;

  procedure EndLine;
  begin
    if (NR > 0) and (not Lines[NL].Runs[NR - 1].Code) and (Lines[NL].Runs[NR - 1].Text = ' ') then NR := NR - 1;
    SetLength(Lines[NL].Runs, NR);
    Lines[NL].Y := Y;
    Lines[NL].H := LH;
    Y := Y + LH;
    NL := NL + 1;
    SetLength(Lines, NL + 1);
    SetLength(Lines[NL].Runs, 0);
    NR := 0;
    X := 0;
    LH := Base;
  end;

begin
  CodePad := S(8);
  Base := FontFor(Kind, False, False, False).LineHeight * 1.38;
  SetLength(Lines, 1);
  SetLength(Lines[0].Runs, 0);
  NL := 0;
  NR := 0;
  X := 0;
  Y := 0;
  LH := Base;
  BreakInside := False;
  for T := 0 to High(Toks) do
  begin
    if Toks[T].Space and (X = 0) then Continue;
    W := TokW(Toks[T]);
    NeedBreak := False;
    if not Toks[T].Space then
    begin
      if (T = 0) or Toks[T - 1].Space then
      begin
        GW := W;
        K := T + 1;
        while (K <= High(Toks)) and not Toks[K].Space do
        begin
          GW := GW + TokW(Toks[K]);
          K := K + 1;
        end;
        BreakInside := GW > MaxW;
        NeedBreak := (X > 0) and (X + GW > MaxW);
      end
      else
        NeedBreak := BreakInside and (X > 0) and (X + W > MaxW);
    end;
    if NeedBreak then EndLine;
    if Toks[T].Space and (X = 0) then Continue;
    if NR >= Length(Lines[NL].Runs) then SetLength(Lines[NL].Runs, NR + 16);
    Lines[NL].Runs[NR].Text := Toks[T].Text;
    Lines[NL].Runs[NR].X := X;
    Lines[NL].Runs[NR].W := W;
    Lines[NL].Runs[NR].Bold := Toks[T].Bold;
    Lines[NL].Runs[NR].Italic := Toks[T].Italic;
    Lines[NL].Runs[NR].Code := Toks[T].Code;
    NR := NR + 1;
    X := X + W;
    F := FontFor(Kind, Toks[T].Bold, Toks[T].Italic, Toks[T].Code);
    if F.LineHeight * 1.38 > LH then LH := F.LineHeight * 1.38;
  end;
  SetLength(Lines[NL].Runs, NR);
  Lines[NL].Y := Y;
  Lines[NL].H := LH;
  H := Y + LH;
  SetLength(Lines, NL + 1);
end;

procedure TMdView.Layout;
var
  I, R, C, NC, BW, BH: Integer;
  Y, W, Indent, TopSp, BotSp, H, Natural, Total, Avail, CellPad: Single;
  Nat: array of Single;
  Lines: TMdLines;
begin
  if ClientWidth <= 0 then Exit;
  W := ContentW;
  CellPad := S(12);
  Y := S(18);
  for I := 0 to High(FBlocks) do
  begin
    Indent := 0;
    case FBlocks[I].Kind of
      mkH1: begin if I = 0 then TopSp := S(6) else TopSp := S(30); BotSp := S(18); end;
      mkH2: begin TopSp := S(24); BotSp := S(12); end;
      mkH3: begin TopSp := S(14); BotSp := S(6); end;
      mkBullet1, mkNumber: begin TopSp := 0; BotSp := S(5); Indent := S(26); end;
      mkBullet2: begin TopSp := 0; BotSp := S(4); Indent := S(50); end;
      mkQuote: begin TopSp := S(6); BotSp := S(16); Indent := S(22); end;
      mkRule: begin TopSp := S(10); BotSp := S(12); end;
      mkTable: begin TopSp := S(6); BotSp := S(18); end;
      mkImage: begin TopSp := S(8); BotSp := S(22); end;
    else
      begin TopSp := 0; BotSp := S(12); end;
    end;
    Y := Y + TopSp;
    FBlocks[I].Top := Y;
    case FBlocks[I].Kind of
      mkRule: H := S(1);
      mkTable:
        begin
          NC := 0;
          if Length(FBlocks[I].Rows) > 0 then NC := Length(FBlocks[I].Rows[0]);
          SetLength(Nat, NC);
          SetLength(FBlocks[I].ColW, NC);
          for C := 0 to NC - 1 do
          begin
            Nat[C] := S(40);
            for R := 0 to High(FBlocks[I].Rows) do
            begin
              LayoutToks(FBlocks[I].Rows[R][C].Toks, mkPara, 100000, Lines, H);
              Natural := 0;
              if Length(Lines) > 0 then
                if Length(Lines[0].Runs) > 0 then
                  Natural := Lines[0].Runs[High(Lines[0].Runs)].X + Lines[0].Runs[High(Lines[0].Runs)].W;
              Nat[C] := Max(Nat[C], Natural + 2 * CellPad);
            end;
          end;
          Total := 0;
          for C := 0 to NC - 1 do Total := Total + Nat[C];
          Avail := W;
          for C := 0 to NC - 1 do
            if Total > Avail then FBlocks[I].ColW[C] := Nat[C] * Avail / Total
            else FBlocks[I].ColW[C] := Nat[C];
          SetLength(FBlocks[I].RowH, Length(FBlocks[I].Rows));
          H := 0;
          for R := 0 to High(FBlocks[I].Rows) do
          begin
            FBlocks[I].RowH[R] := 0;
            for C := 0 to NC - 1 do
            begin
              LayoutToks(FBlocks[I].Rows[R][C].Toks, mkPara, FBlocks[I].ColW[C] - 2 * CellPad,
                FBlocks[I].Rows[R][C].Lines, FBlocks[I].Rows[R][C].H);
              FBlocks[I].RowH[R] := Max(FBlocks[I].RowH[R], FBlocks[I].Rows[R][C].H + S(14));
            end;
            H := H + FBlocks[I].RowH[R];
          end;
        end;
      mkQuote:
        begin
          LayoutToks(FBlocks[I].Toks, FBlocks[I].Kind, W - Indent - S(18), FBlocks[I].Lines, FBlocks[I].TextH);
          H := FBlocks[I].TextH + S(26);
        end;
      mkImage:
        begin
          if not FBlocks[I].ImgTried then
          begin
            FBlocks[I].ImgTried := True;
            if HelpImageSize(FBlocks[I].ImgName, BW, BH) then
            begin
              FBlocks[I].NatW := BW;
              FBlocks[I].NatH := BH;
            end;
          end;
          if FBlocks[I].NatW > 0 then
          begin
            { the screenshots are made at 150 %: their size at this scaling }
            FBlocks[I].ImgW := Round(Min(W, FBlocks[I].NatW * UIScale / 1.5));
            FBlocks[I].ImgH := Round(FBlocks[I].NatH * FBlocks[I].ImgW / FBlocks[I].NatW);
          end
          else
          begin
            FBlocks[I].ImgW := W;
            FBlocks[I].ImgH := S(64);
          end;
          LayoutToks(FBlocks[I].Toks, mkPara, W, FBlocks[I].Lines, FBlocks[I].TextH);
          H := FBlocks[I].ImgH + S(8) + FBlocks[I].TextH;
        end;
    else
      begin
        LayoutToks(FBlocks[I].Toks, FBlocks[I].Kind, W - Indent, FBlocks[I].Lines, FBlocks[I].TextH);
        H := FBlocks[I].TextH;
        if FBlocks[I].Kind = mkH1 then H := H + S(10);
      end;
    end;
    FBlocks[I].Bottom := Y + H;
    Y := Y + H + BotSp;
  end;
  FContentH := Round(Y + S(40));
  FLayoutW := ClientWidth;
  FScroll.SetParams(FContentH, ClientHeight);
  FScroll.Visible := FScroll.NeedScroll;
end;

procedure TMdView.Resize;
begin
  inherited Resize;
  if (FLayoutW <> ClientWidth) and (Length(FBlocks) > 0) then Layout
  else
  begin
    FScroll.SetParams(FContentH, ClientHeight);
    FScroll.Visible := FScroll.NeedScroll;
  end;
  Invalidate;
end;

procedure TMdView.Zoom(Delta: Single);
begin
  FSize := EnsureRange(FSize + Delta, 10, 26);
  Layout;
  Invalidate;
end;

procedure TMdView.ScrollChanged(Sender: TObject);
begin
  Invalidate;
  if Assigned(FOnScrolled) then FOnScrolled(Self);
end;

procedure TMdView.ScrollTo(Y: Integer);
begin
  FScroll.Position := Y;
  Invalidate;
  if Assigned(FOnScrolled) then FOnScrolled(Self);
end;

procedure TMdView.ScrollToBlock(I: Integer);
begin
  if (I < 0) or (I > High(FBlocks)) then Exit;
  ScrollTo(Round(FBlocks[I].Top - S(16)));
end;

function TMdView.TopBlock: Integer;
var
  I: Integer;
  Y: Single;
begin
  Result := 0;
  Y := FScroll.Position + S(40);
  for I := 0 to High(FBlocks) do
    if FBlocks[I].Top <= Y then Result := I else Break;
end;

function TMdView.FindText(const Q: string; FromBlock: Integer): Integer;
var
  I, N: Integer;
  U: UnicodeString;
begin
  Result := -1;
  U := LowerCase(UTF8Decode(Trim(Q)));
  if U = '' then Exit;
  N := Length(FBlocks);
  for I := 0 to N - 1 do
    if Pos(U, FBlocks[(FromBlock + I) mod N].Plain) > 0 then Exit((FromBlock + I) mod N);
end;

{ ---- painting ---- }

procedure TMdView.DrawLines(G: TGfx; const Lines: TMdLines; Kind: TMdKind; X, Y: Single; Fg: TARGB);
var
  L, R: Integer;
  Run: TMdRun;
  F: TGfxFont;
  C: TARGB;
  Ry: Single;
begin
  for L := 0 to High(Lines) do
  begin
    Ry := Y + Lines[L].Y;
    if (Ry > Height) or (Ry + Lines[L].H < 0) then Continue;
    for R := 0 to High(Lines[L].Runs) do
    begin
      Run := Lines[L].Runs[R];
      F := FontFor(Kind, Run.Bold, Run.Italic, Run.Code);
      if Run.Code then
      begin
        G.FillRound(X + Run.X + S(1), Ry + (Lines[L].H - F.LineHeight) / 2 - S(2), Run.W - S(2), F.LineHeight + S(3),
          S(4), clInput);
        G.TextW(Run.Text, X + Run.X + S(4), Ry, Run.W, Lines[L].H, F, clAccentHi, 0, 1, tfNoEllipsis);
      end
      else
      begin
        C := Fg;
        if Run.Bold and not (Kind in [mkH1, mkH2, mkH3]) then C := clText;
        G.TextW(Run.Text, X + Run.X, Ry, Run.W + S(30), Lines[L].H, F, C, 0, 1, tfNoEllipsis);
      end;
    end;
  end;
end;

procedure TMdView.DoPaint(G: TGfx);
var
  I, R, C: Integer;
  Off, X0, Y, W, X, Indent, CY: Single;
  Fg, Body: TARGB;
  B: TMdBlock;
  F: TGfxFont;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if FLayoutW <> ClientWidth then Layout;
  Off := FScroll.Position;
  X0 := ContentLeft;
  W := ContentW;
  Body := Blend(clTextDim, clText, 0.55);
  { decoded screenshots far from the view are freed (a few MB each) }
  for I := 0 to High(FBlocks) do
    if (FBlocks[I].Bmp <> nil) and ((FBlocks[I].Bottom - Off < -2 * Height) or (FBlocks[I].Top - Off > 3 * Height)) then
    begin
      DisposeBitmap(FBlocks[I].Bmp);
      FBlocks[I].Bmp := nil;
    end;
  for I := 0 to High(FBlocks) do
  begin
    B := FBlocks[I];
    if B.Bottom - Off < -S(20) then Continue;
    if B.Top - Off > Height then Break;
    Y := B.Top - Off;
    if I = FHighlight then
      G.FillRound(X0 - S(12), Y - S(6), W + S(24), B.Bottom - B.Top + S(12), S(8), WithAlpha(clWarn, $24));
    case B.Kind of
      mkH1:
        begin
          DrawLines(G, B.Lines, B.Kind, X0, Y, clText);
          G.FillRound(X0, Y + B.TextH + S(4), S(56), S(4), S(2), clAccent);
        end;
      mkH2:
        begin
          DrawLines(G, B.Lines, B.Kind, X0, Y, clText);
          G.FillRect(X0, Y + B.TextH + S(4), W, 1, clBorder);
        end;
      mkH3: DrawLines(G, B.Lines, B.Kind, X0, Y, Blend(clText, clAccentHi, 0.35));
      mkPara: DrawLines(G, B.Lines, B.Kind, X0, Y, Body);
      mkBullet1, mkBullet2, mkNumber:
        begin
          if B.Kind = mkBullet2 then Indent := S(50) else Indent := S(26);
          F := FontFor(mkPara, False, False, False);
          CY := Y + B.Lines[0].H / 2;
          case B.Kind of
            mkBullet1: G.FillCircle(X0 + Indent - S(14), CY, S(3), clAccent);
            mkBullet2: G.FillRect(X0 + Indent - S(17), CY - SF(0.75), S(8), SF(1.5), clTextDim);
            mkNumber: G.Text(IntToStr(B.Number) + '.', X0, Y, Indent - S(8), B.Lines[0].H,
              GetFont(F.Size, True), clAccentHi, 2, 1, tfNoEllipsis);
          end;
          DrawLines(G, B.Lines, mkPara, X0 + Indent, Y, Body);
        end;
      mkQuote:
        begin
          G.FillRound(X0, Y, W, B.Bottom - B.Top, S(8), clCard);
          G.FillRound(X0, Y, S(4), B.Bottom - B.Top, S(2), clAccent);
          DrawLines(G, B.Lines, B.Kind, X0 + S(22), Y + S(13), Body);
        end;
      mkRule: G.FillRect(X0, Y, W, 1, clBorder);
      mkImage:
        begin
          X := X0 + (W - B.ImgW) / 2;
          { decoded at the drawn size while it is in view }
          if (B.NatW > 0) and ((B.Bmp = nil) or (B.DecW <> Round(B.ImgW))) then
          begin
            if FBlocks[I].Bmp <> nil then DisposeBitmap(FBlocks[I].Bmp);
            FBlocks[I].DecW := Round(B.ImgW);
            FBlocks[I].Bmp := LoadHelpImage(B.ImgName, Max(Round(B.ImgW), Round(B.ImgH)));
            B := FBlocks[I];
          end;
          if B.Bmp <> nil then
          begin
            G.FillRect(X + S(3), Y + S(4), B.ImgW, B.ImgH, $38000000);
            G.DrawBitmap(B.Bmp, X, Y, B.ImgW, B.ImgH);
            G.StrokeRect(X, Y, B.ImgW, B.ImgH, 1, clBorder);
          end
          else
          begin
            G.FillRound(X0, Y, W, B.ImgH, S(8), clCard);
            DrawIcon(G, icImage, X0 + W / 2, Y + B.ImgH / 2, S(28), clTextFaint);
          end;
          { the caption, centred when it is one line }
          CY := Y + B.ImgH + S(8);
          X := X0;
          if (Length(B.Lines) = 1) and (Length(B.Lines[0].Runs) > 0) then
            X := X0 + (W - (B.Lines[0].Runs[High(B.Lines[0].Runs)].X + B.Lines[0].Runs[High(B.Lines[0].Runs)].W)) / 2;
          DrawLines(G, B.Lines, mkPara, X, CY, clTextDim);
        end;
      mkTable:
        begin
          CY := Y;
          for R := 0 to High(B.Rows) do
          begin
            Fg := Body;
            if (R = 0) and B.HeaderRow then
            begin
              G.FillRound(X0, CY, W, B.RowH[R], S(6), clCard);
              Fg := clText;
            end
            else
              G.FillRect(X0, CY + B.RowH[R] - 1, W, 1, clBorder);
            X := X0;
            for C := 0 to High(B.Rows[R]) do
            begin
              if (R = 0) and B.HeaderRow then
                DrawLines(G, B.Rows[R][C].Lines, mkPara, X + S(12), CY + S(7), clText)
              else
                DrawLines(G, B.Rows[R][C].Lines, mkPara, X + S(12), CY + S(7), Fg);
              X := X + B.ColW[C];
            end;
            CY := CY + B.RowH[R];
          end;
        end;
    end;
  end;
end;

{ ---- input ---- }

function TMdView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if ssCtrl in Shift then
  begin
    if WheelDelta > 0 then Zoom(1) else Zoom(-1);
  end
  else
    FScroll.WheelBy(-Round(WheelDelta / 120 * S(80)));
  Result := True;
end;

function TMdView.PanBy(DX, DY: Integer): Boolean;
begin
  if DY <> 0 then ScrollTo(FScroll.Position - DY);
  Result := True;
end;

function TMdView.ScrollOffset: Integer;
begin
  Result := FScroll.Position;
end;

procedure TMdView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_UP: ScrollTo(FScroll.Position - S(50));
    VK_DOWN: ScrollTo(FScroll.Position + S(50));
    VK_PRIOR: ScrollTo(FScroll.Position - (ClientHeight - S(60)));
    VK_NEXT, VK_SPACE: ScrollTo(FScroll.Position + (ClientHeight - S(60)));
    VK_HOME: ScrollTo(0);
    VK_END: ScrollTo(FScroll.MaxPos);
  else
    Exit;
  end;
  Key := 0;
end;

procedure TMdView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then SetFocus;
end;

{ ---- THelpWindow ---- }

constructor THelpWindow.Create(AOwner: TComponent);
var
  Left_, Bottom_: TAuPanel;
  B: TAuButton;
begin
  inherited CreateAu(AOwner, 'Aulumic - Help', 1180, 820);
  BorderStyle := bsSizeable;
  { no minimize button (the help is closed or put behind; minimized it
    would have no taskbar button to come back from) }
  BorderIcons := [biSystemMenu, biMaximize];
  Position := poMainFormCenter;
  Constraints.MinWidth := S(760);
  Constraints.MinHeight := S(480);
  FitToWorkArea;          // a small screen at a large scaling
  OnKeyDown := @HelpKey;
  OnClose := @HelpClose;

  Bottom_ := TAuPanel.Create(Self);
  Bottom_.Parent := Body;
  Bottom_.Align := alBottom;
  Bottom_.Height := S(56);
  Bottom_.BackRole := crPanel;
  B := AddButton(Bottom_, 'Close', 0, 12, 100, bkPrimary, @CloseClick);
  B.Align := alRight;
  B.BorderSpacing.Around := S(12);
  B := AddButton(Bottom_, 'A+', 0, 12, 52, bkNormal, @ZoomIn);
  B.Align := alLeft;
  B.BorderSpacing.Left := S(16);
  B.BorderSpacing.Top := S(12);
  B.BorderSpacing.Bottom := S(12);
  B := AddButton(Bottom_, 'A-', 0, 12, 52, bkNormal, @ZoomOut);
  B.Left := S(200);
  B.Align := alLeft;
  B.BorderSpacing.Left := S(8);
  B.BorderSpacing.Top := S(12);
  B.BorderSpacing.Bottom := S(12);
  with AddLabel(Bottom_, 'Ctrl + mouse wheel changes the text size  ·  F3 = next search hit', 0, 0, 500) do
  begin
    Left := S(400);
    Align := alLeft;
    BorderSpacing.Left := S(16);
    TextRole := crTextFaint;
    FontSize := 12;
  end;

  Left_ := TAuPanel.Create(Self);
  Left_.Parent := Body;
  Left_.Align := alLeft;
  Left_.Width := S(290);
  Left_.BackRole := crPanel;
  FSearch := AddEdit(Left_, 14, 14, 262);
  FSearch.Placeholder := 'Search the help';
  FSearch.Align := alTop;
  FSearch.BorderSpacing.Around := S(14);
  FSearch.Height := S(34);
  FSearch.OnEnterKey := @SearchEnter;
  FSearch.OnChange := @SearchChange;
  FTopics := TAuListView.Create(Self);
  FTopics.Parent := Left_;
  FTopics.Align := alClient;
  FTopics.BorderSpacing.Left := S(6);
  FTopics.BorderSpacing.Right := S(6);
  FTopics.BorderSpacing.Bottom := S(8);
  FTopics.ShowHeader := False;
  FTopics.RowHeight := S(32);
  FTopics.AddColumn('', 100, 0, True);
  FTopics.AutoFit := True;
  FTopics.MultiSelect := False;
  FTopics.OnDrawCell := @TopicDraw;
  FTopics.OnSelChange := @TopicSel;
  FTopics.OnActivate := @TopicClick;

  FView := TMdView.Create(Self);
  FView.Parent := Body;
  FView.Align := alClient;
  FView.OnScrolled := @ViewScrolled;
  FView.LoadMarkdown(LoadHelpText);
  FTopics.RowCount := Length(FView.Topics);
  if FTopics.RowCount > 0 then FTopics.SelectOnly(0);
  ActiveControl := FView;
end;

procedure THelpWindow.TopicDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
begin
  Handled := True;
  if Row > High(FView.Topics) then Exit;
  if FView.Topics[Row].Level = 1 then
    G.Text(FView.Topics[Row].Title, X + S(10), Y, W - S(16), H, UIFont(13, True), clText, 0, 1)
  else
    G.Text(FView.Topics[Row].Title, X + S(26), Y, W - S(32), H, UIFont(13), clTextDim, 0, 1);
end;

procedure THelpWindow.TopicSel(Sender: TObject);
begin
  if FSyncing then Exit;
  if (FTopics.FocusedRow >= 0) and FTopics.Selected[FTopics.FocusedRow] then TopicClick(nil, FTopics.FocusedRow);
end;
procedure THelpWindow.TopicClick(Sender: TObject; Row: Integer);
begin
  if Row > High(FView.Topics) then Exit;
  FView.Highlight := -1;
  FSyncing := True;
  try
    FView.ScrollToBlock(FView.Topics[Row].Block);
    if not FTopics.Selected[Row] then FTopics.SelectOnly(Row);
  finally
    FSyncing := False;
  end;
end;

procedure THelpWindow.ViewScrolled(Sender: TObject);
var
  B, I, Sel: Integer;
begin
  if FSyncing then Exit;
  B := FView.TopBlock;
  Sel := 0;
  for I := 0 to High(FView.Topics) do
    if FView.Topics[I].Block <= B then Sel := I;
  if not FTopics.Selected[Sel] then
  begin
    FSyncing := True;
    try
      FTopics.SelectOnly(Sel);
      FTopics.EnsureVisible(Sel);
    finally
      FSyncing := False;
    end;
  end;
end;

procedure THelpWindow.SearchEnter(Sender: TObject);
var
  Start, Hit: Integer;
begin
  if FView.Highlight >= 0 then Start := FView.Highlight + 1 else Start := FView.TopBlock;
  Hit := FView.FindText(FSearch.Text, Start);
  if Hit < 0 then
  begin
    FView.Highlight := -1;
    FView.Invalidate;
    Exit;
  end;
  FView.Highlight := Hit;
  FView.ScrollToBlock(Hit);
end;

procedure THelpWindow.SearchChange(Sender: TObject);
var
  Hit: Integer;
begin
  if Length(Trim(FSearch.Text)) < 3 then
  begin
    if FView.Highlight >= 0 then
    begin
      FView.Highlight := -1;
      FView.Invalidate;
    end;
    Exit;
  end;
  Hit := FView.FindText(FSearch.Text, 0);
  FView.Highlight := Hit;
  if Hit >= 0 then FView.ScrollToBlock(Hit) else FView.Invalidate;
end;

procedure THelpWindow.ZoomIn(Sender: TObject);
begin
  FView.Zoom(1);
end;

procedure THelpWindow.ZoomOut(Sender: TObject);
begin
  FView.Zoom(-1);
end;

procedure THelpWindow.CloseClick(Sender: TObject);
begin
  Close;
end;

procedure THelpWindow.HelpKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    Close;
  end
  else if Key = VK_F3 then
  begin
    Key := 0;
    SearchEnter(nil);
  end
  else if (Key = Ord('F')) and (ssCtrl in Shift) then
  begin
    Key := 0;
    FSearch.SetFocus;
    FSearch.SelectAll;
  end;
end;

procedure THelpWindow.HelpClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caHide;
end;

procedure THelpWindow.DoShow;
begin
  inherited DoShow;
  if PendingTopic <> '' then
  begin
    GoTopic(PendingTopic);
    PendingTopic := '';
  end;
end;

{ the exact title first, then one that starts with Topic, then
  one that contains it ("Artist Info" is not "Shortcuts in Artist Info") }
procedure THelpWindow.GoTopic(const Topic: string);
var
  I, Pass: Integer;
  T, U: string;
begin
  U := LowerCase(Trim(Topic));
  if U = '' then Exit;
  for Pass := 0 to 2 do
    for I := 0 to High(FView.Topics) do
    begin
      T := LowerCase(FView.Topics[I].Title);
      if ((Pass = 0) and (T = U)) or ((Pass = 1) and (Pos(U, T) = 1)) or ((Pass = 2) and (Pos(U, T) > 0)) then
      begin
        TopicClick(nil, I);
        Exit;
      end;
    end;
end;

initialization
  AuShowHelp := @ShowHelpWindow;

end.
