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
  Windows, Classes, SysUtils, Types, Math, Controls, Forms, ExtCtrls, LCLType, AuGfx, AuAnim, AuTheme, AuIcons, AuControls,
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
    ImgCaption: string;           // the caption as plain text (the picture panel)
    ImgMarks: string;             // the numbered markers: "1=banner 2=40,55" (see TMdPicture)
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
    FPinImages: Boolean;
    FInLayout: Boolean;           // the scroll position is being set by a new layout
    FOnScrolled: TNotifyEvent;
    procedure Parse(const Md: UnicodeString);
    procedure ParseInline(const S: UnicodeString; out Toks: TMdToks; out Plain: UnicodeString);
    procedure ParseInlineRaw(const S: UnicodeString; out Toks: TMdToks; out Plain: UnicodeString);
    function FontFor(Kind: TMdKind; B, I, C: Boolean): TGfxFont;
    procedure LayoutToks(const Toks: TMdToks; Kind: TMdKind; MaxW: Single; out Lines: TMdLines; out H: Single);
    procedure Layout;
    function MarkDisc: Single;
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
    { The pictures are not laid out in the text (a picture panel shows them):
      set before LoadMarkdown. }
    property PinImages: Boolean read FPinImages write FPinImages;
    property InLayout: Boolean read FInLayout;
    function BlockTop(ABlock: Integer): Single;
    function MaxScroll: Integer;
    { one notch of the mouse wheel, as DoMouseWheel takes it (the help probe) }
    procedure WheelNotch(ADown: Boolean);
    { a turn of the wheel that arrived somewhere else (over the picture) }
    procedure WheelFrom(Shift: TShiftState; WheelDelta: Integer);
    { the picture that belongs to the text at content position AY: the block
      of the last picture at or before it in its section (## inside #), else
      the section's first; a section without one shows the last picture
      before it in its topic (#), a topic's start the picture of its
      introduction; -1 = none }
    function PictureFor(AY: Single): Integer;
    { the pictures of the section the picture ABlock is in (for stepping
      through them by hand) }
    function SectionPictures(ABlock: Integer): TIntegerDynArray;
    function PictureName(ABlock: Integer): string;
    function PictureCaption(ABlock: Integer): string;
    function PictureMarks(ABlock: Integer): string;
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
{$IFDEF DEBUG}
{ --help-probe: opens the help and drives the real window - scrolls through
  the whole text down and up, goes to every topic, enlarges the picture,
  changes the text size and the window size, hides and shows the window -
  and checks at every step that the picture of the place is shown, that the
  text does not jump when the picture panel changes, and that a topic's
  heading stands under the picture. Writes the report; the result is the
  number of failed checks. }
function RunHelpProbe(const AReport: string): Integer;
{$ENDIF}

implementation

type
  { The picture panel above the help text: the screenshot of the section
    being read, scaled to fit, with its caption and its numbered markers.
    The markers are drawn here, not into the picture files (which are made
    again by a script after every change of the program): each has a number
    and a place, either a named place of that screenshot ("banner"; the shot
    run writes them down, see HelpAnchorPos) or a position in per cent of
    the picture ("40,55"). The numbers in the text are the same numbers. }
  TMdMark = record
    Number: Integer;
    X, Y: Single;             // the middle, 0 .. 1 of the picture
    W, H: Single;             // the size of a named place (0: a position)
  end;

  TMdPicture = class(TAuControl)
  private
    FName, FCaption, FMarkSpec: string;
    FMarks: array of TMdMark;
    FBmp: TGfxBitmap;
    FDecW: Integer;
    FNatW, FNatH: Integer;
    FDots, FDot: Integer;         // the pictures of the section and the one shown
    FEnlarged: Boolean;
    FDragging: Boolean;
    FDragY: Integer;
    FOnToggle, FOnStep: TNotifyEvent;
    FOnDragBy: TNotifyEvent;
    function DotAt(X, Y: Integer): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    { the wheel over the picture scrolls the text }
    WheelTarget: TMdView;
    DragDelta: Integer;           // how far the lower edge was dragged (OnDragBy)
    StepTo: Integer;              // the dot clicked (OnStep)
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetPicture(const AName, ACaption, AMarks: string; ADots, ADot: Integer);
    { the height the panel wants for its picture at this width, at most AMaxH }
    function HeightFor(AWidth, AMaxH: Integer): Integer;
    function ImageRect: TRect;
    property PictureName: string read FName;
    function MarkCount: Integer;
    function HasBitmap: Boolean;
    property Enlarged: Boolean read FEnlarged write FEnlarged;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
    property OnStep: TNotifyEvent read FOnStep write FOnStep;
    property OnDragBy: TNotifyEvent read FOnDragBy write FOnDragBy;
  end;
  { THelpWindow }

  THelpWindow = class(TAuForm)
  private
    FView: TMdView;
    FTopics: TAuListView;
    FSearch: TAuEdit;
    FSyncing: Boolean;
    FRight: TAuPanel;
    FPic: TMdPicture;
    FPicFrac: Single;             // the most of the pane's height the picture takes
    FPicBlock, FManualBlock: Integer;
    FPicBusy: Boolean;
    FPicH: Integer;               // the height the picture panel has now (0: closed)
    FPicTarget: Integer;          // the height it is on its way to
    FPicAnim: TAuAnim;
    FHeldTimer: TTimer;
    procedure UpdatePicture(AInstant: Boolean);
    procedure PicAnimStep(Sender: TObject; ADone: Boolean);
    procedure HeldTimerTick(Sender: TObject);
    procedure ArrangeRight;
    procedure JumpToBlock(ABlock: Integer);
    procedure RightResize(Sender: TObject);
    procedure PicToggle(Sender: TObject);
    procedure PicStep(Sender: TObject);
    procedure PicDragBy(Sender: TObject);    procedure TopicDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
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
    {$IFDEF DEBUG}
    function Probe(R: TStrings): Integer;
    {$ENDIF}
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

// The number of a marker is kept in the text as one character (the circled
// digits 1 .. 20) and drawn as a disc like the marker on the picture
function IsMarkChar(C: WideChar): Boolean; inline;
begin
  Result := (Ord(C) >= $2460) and (Ord(C) <= $2473);
end;

function IsMarkText(const T: UnicodeString): Boolean; inline;
begin
  Result := (Length(T) = 1) and IsMarkChar(T[1]);
end;

// A number in braces in the text - an opening brace, 3, a closing brace - is
// the number of a marker on a picture (1 .. 20)
procedure TMdView.ParseInline(const S: UnicodeString; out Toks: TMdToks; out Plain: UnicodeString);
var
  U: UnicodeString;
  I, J, N: Integer;
begin
  U := S;
  I := 1;
  while I <= Length(U) - 2 do
  begin
    if U[I] = '{' then
    begin
      J := I + 1;
      N := 0;
      while (J <= Length(U)) and (U[J] >= '0') and (U[J] <= '9') and (J - I <= 2) do
      begin
        N := N * 10 + Ord(U[J]) - Ord('0');
        Inc(J);
      end;
      if (J > I + 1) and (J <= Length(U)) and (U[J] = '}') and (N >= 1) and (N <= 20) then
      begin
        Delete(U, I, J - I + 1);
        Insert(WideChar($2460 + N - 1), U, I);
      end;
    end;
    Inc(I);
  end;
  ParseInlineRaw(U, Toks, Plain);
end;

procedure TMdView.ParseInlineRaw(const S: UnicodeString; out Toks: TMdToks; out Plain: UnicodeString);
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
      if IsMarkChar(Seg[PA]) then PB := PA + 1    // a marker's number is a piece of its own
      else
        while (PB <= Length(Seg)) and ((Seg[PB] = ' ') = Sp) and not IsMarkChar(Seg[PB]) do PB := PB + 1;
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
  Num, PE: Integer;
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
      else if (Copy(T, 1, 2) = '![') and (Pos('](', T) > 0) and ((T[Length(T)] = ')') or (T[Length(T)] = '}')) then
      begin
        // a screenshot: ![caption](name), or with its markers in braces behind it
        PB := Pos('](', T);
        PE := PB + 2;
        while (PE <= Length(T)) and (T[PE] <> ')') do Inc(PE);
        AddBlock(mkImage, Copy(T, 3, PB - 3), 0);
        FBlocks[NB - 1].ImgName := Trim(UTF8Encode(Copy(T, PB + 2, PE - PB - 2)));
        FBlocks[NB - 1].ImgCaption := UTF8Encode(Copy(T, 3, PB - 3));
        if (PE < Length(T)) and (T[PE + 1] = '{') and (T[Length(T)] = '}') then
          FBlocks[NB - 1].ImgMarks := Trim(UTF8Encode(Copy(T, PE + 2, Length(T) - PE - 2)));
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

function TMdView.MarkDisc: Single;
begin
  Result := Round(FontFor(mkPara, False, False, False).LineHeight * 1.02);
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
    if IsMarkText(Tk.Text) then Exit(MarkDisc + S(3));
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
  I, R, C, NC, BW, BH, KeepBlock: Integer;
  Y, W, Indent, TopSp, BotSp, H, Natural, Total, Avail, CellPad, KeepOff: Single;
  Nat: array of Single;
  Lines: TMdLines;
begin
  if ClientWidth <= 0 then Exit;
  { the text at the top stays the text at the top: the block there and how
    far it is scrolled into, put back after the new layout }
  KeepBlock := -1;
  KeepOff := 0;
  if FLayoutW > 0 then
    for I := 0 to High(FBlocks) do
      if FBlocks[I].Bottom > FScroll.Position then
      begin
        KeepBlock := I;
        KeepOff := FScroll.Position - FBlocks[I].Top;
        Break;
      end;
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
    { a pinned picture takes no room in the text: the panel shows it }
    if FPinImages and (FBlocks[I].Kind = mkImage) then
    begin
      FBlocks[I].Top := Y;
      FBlocks[I].Bottom := Y;
      Continue;
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
  if KeepBlock >= 0 then
  begin
    FInLayout := True;
    try
      FScroll.Position := Round(FBlocks[KeepBlock].Top + KeepOff);
    finally
      FInLayout := False;
    end;
  end;
end;

procedure TMdView.Resize;
begin
  inherited Resize;
  if (FLayoutW <> ClientWidth) and (Length(FBlocks) > 0) then Layout
  else
  begin
    FInLayout := True;
    try
      FScroll.SetParams(FContentH, ClientHeight);
    finally
      FInLayout := False;
    end;
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
  Ry, D: Single;
begin
  for L := 0 to High(Lines) do
  begin
    Ry := Y + Lines[L].Y;
    if (Ry > Height) or (Ry + Lines[L].H < 0) then Continue;
    for R := 0 to High(Lines[L].Runs) do
    begin
      Run := Lines[L].Runs[R];
      F := FontFor(Kind, Run.Bold, Run.Italic, Run.Code);
      if IsMarkText(Run.Text) then
      begin
        { the same disc as on the picture, as high as the text }
        D := MarkDisc;
        G.FillCircle(X + Run.X + D / 2, Ry + Lines[L].H / 2, D / 2, clAccent);
        G.Text(IntToStr(Ord(Run.Text[1]) - $2460 + 1), X + Run.X, Ry + Lines[L].H / 2 - D / 2, D, D,
          GetFont(Round(SF(FSize * 0.72) * 2) / 2, True, False, False), clOnAccent, 1, 1, tfNoEllipsis);
      end
      else if Run.Code then
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
        if not FPinImages then
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

function TMdView.BlockTop(ABlock: Integer): Single;
begin
  if (ABlock >= 0) and (ABlock <= High(FBlocks)) then Result := FBlocks[ABlock].Top else Result := 0;
end;

procedure TMdView.WheelFrom(Shift: TShiftState; WheelDelta: Integer);
begin
  DoMouseWheel(Shift, WheelDelta, Point(0, 0));
end;

procedure TMdView.WheelNotch(ADown: Boolean);
begin
  if ADown then DoMouseWheel([], -120, Point(0, 0)) else DoMouseWheel([], 120, Point(0, 0));
end;

function TMdView.MaxScroll: Integer;
begin
  Result := Math.Max(0, FContentH - ClientHeight);
end;

{ ---- the pictures of the sections ---- }

function TMdView.PictureName(ABlock: Integer): string;
begin
  if (ABlock >= 0) and (ABlock <= High(FBlocks)) then Result := FBlocks[ABlock].ImgName else Result := '';
end;

function TMdView.PictureCaption(ABlock: Integer): string;
begin
  if (ABlock >= 0) and (ABlock <= High(FBlocks)) then Result := FBlocks[ABlock].ImgCaption else Result := '';
end;

function TMdView.PictureMarks(ABlock: Integer): string;
begin
  if (ABlock >= 0) and (ABlock <= High(FBlocks)) then Result := FBlocks[ABlock].ImgMarks else Result := '';
end;

function TMdView.PictureFor(AY: Single): Integer;
var
  I, BI, H1a, H1b, H2a, H2b: Integer;
begin
  Result := -1;
  if Length(FBlocks) = 0 then Exit;
  BI := 0;
  for I := 0 to High(FBlocks) do
    if FBlocks[I].Top <= AY then BI := I else Break;
  { the topic (#) and the section (##) the text is in }
  H1a := 0;
  for I := BI downto 0 do
    if FBlocks[I].Kind = mkH1 then
    begin
      H1a := I;
      Break;
    end;
  H1b := Length(FBlocks);
  for I := BI + 1 to High(FBlocks) do
    if FBlocks[I].Kind = mkH1 then
    begin
      H1b := I;
      Break;
    end;
  H2a := -1;
  for I := BI downto H1a do
    if FBlocks[I].Kind = mkH2 then
    begin
      H2a := I;
      Break;
    end;
  if H2a >= 0 then
  begin
    H2b := H1b;
    for I := BI + 1 to H1b - 1 do
      if FBlocks[I].Kind = mkH2 then
      begin
        H2b := I;
        Break;
      end;
    { the section's own: the last at or before the text, else its first }
    for I := Math.Min(BI, H2b - 1) downto H2a do
      if FBlocks[I].Kind = mkImage then Exit(I);
    for I := BI + 1 to H2b - 1 do
      if FBlocks[I].Kind = mkImage then Exit(I);
  end;
  { the last picture before the text in the topic }
  for I := BI downto H1a do
    if FBlocks[I].Kind = mkImage then Exit(I);
  { nothing above the text: the first picture of the topic, so a topic that
    starts with a few lines of introduction already shows what it is about }
  for I := BI + 1 to H1b - 1 do
    if FBlocks[I].Kind = mkImage then Exit(I);
end;

function TMdView.SectionPictures(ABlock: Integer): TIntegerDynArray;
var
  I, A, B: Integer;
begin
  Result := nil;
  if (ABlock < 0) or (ABlock > High(FBlocks)) then Exit;
  { back to the heading above the picture, on to the next heading }
  A := 0;
  for I := ABlock downto 0 do
    if FBlocks[I].Kind in [mkH1, mkH2] then
    begin
      A := I;
      Break;
    end;
  B := Length(FBlocks);
  for I := ABlock + 1 to High(FBlocks) do
    if FBlocks[I].Kind in [mkH1, mkH2] then
    begin
      B := I;
      Break;
    end;
  for I := A to B - 1 do
    if FBlocks[I].Kind = mkImage then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := I;
    end;
end;

{ ---- named places of the screenshots ---- }

var
  GAnchors: TStringList = nil;      // "shot|place" = "x y" in 1/10000 of the picture

{ The places the screenshot run wrote down (anchors.txt in help\shots next
  to the exe, else the resource AULUMICNSHELPANCHORS): a line is
  shot|place|x|y|w|h, x and y the middle of the place and w and h its size
  in 1/10000 of the picture. }
procedure LoadAnchors;
var
  SL: TStringList;
  R: TResourceStream;
  FN: string;
  I: Integer;
  F: TStringArray;
begin
  GAnchors := TStringList.Create;
  GAnchors.Sorted := True;
  GAnchors.Duplicates := dupIgnore;
  SL := TStringList.Create;
  try
    try
      FN := ExtractFilePath(Application.ExeName) + 'help' + PathDelim + 'shots' + PathDelim + 'anchors.txt';
      if FileExists(FN) then SL.LoadFromFile(FN)
      else if FindResource(HInstance, 'AULUMICNSHELPANCHORS', RT_RCDATA) <> 0 then
      begin
        R := TResourceStream.Create(HInstance, 'AULUMICNSHELPANCHORS', RT_RCDATA);
        try
          SL.LoadFromStream(R);
        finally
          R.Free;
        end;
      end;
    except
      SL.Clear;
    end;
    for I := 0 to SL.Count - 1 do
    begin
      F := SL[I].Split(['|']);
      if Length(F) = 6 then
        GAnchors.Add(LowerCase(F[0] + '|' + F[1]) + '=' + F[2] + ' ' + F[3] + ' ' + F[4] + ' ' + F[5]);
    end;
  finally
    SL.Free;
  end;
end;

function HelpAnchorPos(const AShot, APlace: string; out X, Y, W, H: Single): Boolean;
var
  F: TStringArray;
begin
  Result := False;
  X := 0;
  Y := 0;
  W := 0;
  H := 0;
  if GAnchors = nil then LoadAnchors;
  F := GAnchors.Values[LowerCase(AShot + '|' + APlace)].Split([' ']);
  if Length(F) <> 4 then Exit;
  X := StrToIntDef(F[0], -1) / 10000;
  Y := StrToIntDef(F[1], -1) / 10000;
  W := StrToIntDef(F[2], 0) / 10000;
  H := StrToIntDef(F[3], 0) / 10000;
  Result := (X >= 0) and (X <= 1) and (Y >= 0) and (Y <= 1);
end;

{ the small named places of a screenshot (a button, a box - not the large
  panes), as left, top, right, bottom in 0 .. 1 of the picture }
type
  TPlaceRect = record
    L, T, R, B: Single;
  end;
  TPlaceRects = array of TPlaceRect;

function HelpSmallPlaces(const AShot: string): TPlaceRects;
const
  SMALL_W = 0.4;
  SMALL_H = 0.08;
var
  I: Integer;
  K, Prefix: string;
  F: TStringArray;
  X, Y, W, H: Single;
begin
  Result := nil;
  if GAnchors = nil then LoadAnchors;
  Prefix := LowerCase(AShot) + '|';
  for I := 0 to GAnchors.Count - 1 do
  begin
    K := GAnchors.Names[I];
    if Copy(K, 1, Length(Prefix)) <> Prefix then Continue;
    F := GAnchors.ValueFromIndex[I].Split([' ']);
    if Length(F) <> 4 then Continue;
    X := StrToIntDef(F[0], 0) / 10000;
    Y := StrToIntDef(F[1], 0) / 10000;
    W := StrToIntDef(F[2], 0) / 10000;
    H := StrToIntDef(F[3], 0) / 10000;
    if (W <= 0) or (W > SMALL_W) or (H > SMALL_H) then Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].L := X - W / 2;
    Result[High(Result)].T := Y - H / 2;
    Result[High(Result)].R := X + W / 2;
    Result[High(Result)].B := Y + H / 2;
  end;
end;

{ ---- TMdPicture ---- }

const
  PIC_PAD = 14;             // around the picture
  PIC_CAPTION_H = 26;       // the caption line under it
  PIC_GRIP_H = 6;           // the lower edge that is dragged
  PIC_TEXT_GAP = 14;        // between the panel and the text under it
  PIC_MARK_R = 11;          // the radius of a marker
  PIC_DOT_STEP = 16;        // from one dot to the next

function TMdPicture.MarkCount: Integer;
begin
  Result := Length(FMarks);
end;

function TMdPicture.HasBitmap: Boolean;
begin
  Result := FBmp <> nil;
end;

constructor TMdPicture.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FocusOnClick := False;
  FDecW := -1;
end;

destructor TMdPicture.Destroy;
begin
  if FBmp <> nil then DisposeBitmap(FBmp);
  inherited Destroy;
end;

procedure TMdPicture.SetPicture(const AName, ACaption, AMarks: string; ADots, ADot: Integer);
var
  Parts, F, XY: TStringArray;
  I, N: Integer;
  FS: TFormatSettings;
  M: TMdMark;
  Ok: Boolean;
begin
  FDots := ADots;
  FDot := ADot;
  if (AName = FName) and (ACaption = FCaption) and (AMarks = FMarkSpec) then
  begin
    Invalidate;
    Exit;
  end;
  { the same screenshot may follow itself with other markers: the bitmap stays }
  if AName <> FName then
  begin
    FName := AName;
    if FBmp <> nil then DisposeBitmap(FBmp);
    FBmp := nil;
    FDecW := -1;
    FNatW := 0;
    FNatH := 0;
    HelpImageSize(FName, FNatW, FNatH);
  end;
  FCaption := ACaption;
  FMarkSpec := AMarks;
  { the markers: "number=place" or "number=x,y" (per cent), separated by spaces }
  FMarks := nil;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Parts := AMarks.Split([' ']);
  for I := 0 to High(Parts) do
  begin
    F := Parts[I].Split(['=']);
    if Length(F) <> 2 then Continue;
    N := StrToIntDef(F[0], 0);
    if (N < 1) or (N > 20) then Continue;
    M.Number := N;
    M.W := 0;
    M.H := 0;
    XY := F[1].Split([',']);
    if Length(XY) = 2 then
    begin
      M.X := StrToFloatDef(XY[0], -1, FS) / 100;
      M.Y := StrToFloatDef(XY[1], -1, FS) / 100;
      Ok := (M.X >= 0) and (M.X <= 1) and (M.Y >= 0) and (M.Y <= 1);
    end
    else
      Ok := HelpAnchorPos(FName, F[1], M.X, M.Y, M.W, M.H);
    if not Ok then Continue;
    SetLength(FMarks, Length(FMarks) + 1);
    FMarks[High(FMarks)] := M;
  end;
  Invalidate;
end;

function TMdPicture.HeightFor(AWidth, AMaxH: Integer): Integer;
var
  W, H, Room: Single;
begin
  if (FName = '') or (FNatW <= 0) or (FNatH <= 0) then Exit(0);
  { the screenshots are made at 150 %: at most their size at this scaling }
  W := Math.Min(AWidth - 2 * S(PIC_PAD), FNatW * UIScale / 1.5);
  H := FNatH * W / FNatW;
  Room := AMaxH - S(PIC_PAD) - S(PIC_CAPTION_H) - S(PIC_GRIP_H);
  if H > Room then H := Room;
  if H < S(60) then H := S(60);
  Result := Round(H) + S(PIC_PAD) + S(PIC_CAPTION_H) + S(PIC_GRIP_H);
end;

{ where the picture is drawn: as large as the panel allows, centred }
function TMdPicture.ImageRect: TRect;
var
  AvW, AvH, W, H: Single;
begin
  Result := Rect(0, 0, 0, 0);
  if (FNatW <= 0) or (FNatH <= 0) then Exit;
  AvW := ClientWidth - 2 * S(PIC_PAD);
  AvH := ClientHeight - S(PIC_PAD) - S(PIC_CAPTION_H) - S(PIC_GRIP_H);
  if (AvW < 8) or (AvH < 8) then Exit;
  W := AvW;
  if not FEnlarged then W := Math.Min(AvW, FNatW * UIScale / 1.5);
  H := FNatH * W / FNatW;
  if H > AvH then
  begin
    H := AvH;
    W := FNatW * H / FNatH;
  end;
  Result.Left := Round((ClientWidth - W) / 2);
  Result.Top := S(PIC_PAD);
  Result.Right := Result.Left + Round(W);
  Result.Bottom := Result.Top + Round(H);
end;

function TMdPicture.DotAt(X, Y: Integer): Integer;
var
  I, X0, CY: Integer;
begin
  Result := -1;
  if FDots < 2 then Exit;
  X0 := ClientWidth - S(PIC_PAD) - FDots * S(PIC_DOT_STEP);
  CY := ClientHeight - S(PIC_GRIP_H) - S(PIC_CAPTION_H) div 2;
  if Abs(Y - CY) > S(10) then Exit;
  for I := 0 to FDots - 1 do
    if (X >= X0 + I * S(PIC_DOT_STEP)) and (X < X0 + (I + 1) * S(PIC_DOT_STEP)) then Exit(I);
end;

procedure TMdPicture.DoPaint(G: TGfx);
var
  R: TRect;
  I, W, H, CY, X0: Integer;
  MX, MY, PW, PH, CX0, CY0, Rad: Single;
  Side, J: Integer;
  Free_: Boolean;
  Places: TPlaceRects;
  T: string;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  Places := HelpSmallPlaces(FName);
  R := ImageRect;
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  if (W > 0) and (H > 0) then
  begin
    if (FBmp = nil) or (FDecW <> W) then
    begin
      if FBmp <> nil then DisposeBitmap(FBmp);
      FDecW := W;
      FBmp := LoadHelpImage(FName, Math.Max(W, H));
    end;
    if FBmp <> nil then
    begin
      G.FillRect(R.Left + S(3), R.Top + S(4), W, H, $38000000);
      G.DrawBitmap(FBmp, R.Left, R.Top, W, H);
      G.StrokeRect(R.Left, R.Top, W, H, 1, clBorder);
    end
    else
      DrawIcon(G, icImage, Width / 2, R.Top + H / 2, S(28), clTextFaint);
    { the numbered markers: the same size however small the picture is shown }
    for I := 0 to High(FMarks) do
    begin
      MX := R.Left + FMarks[I].X * W;
      MY := R.Top + FMarks[I].Y * H;
      PW := FMarks[I].W * W;
      PH := FMarks[I].H * H;
      { A marker must not cover what it points at, nor its neighbours. A
        large place has it in its middle; a low and wide one (the search box)
        towards its right end; a small one (a button) beside it: at the
        left, the right, below or above - the first of these that is inside
        the picture and on no other small place of it. }
      if (PW > 0) and (PH < 3.2 * S(PIC_MARK_R)) then
      begin
        if PW >= 6 * S(PIC_MARK_R) then MX := MX - PW / 2 + PW * 0.72
        else
        begin
          CX0 := MX;
          CY0 := MY;
          Rad := S(PIC_MARK_R);
          for Side := 0 to 3 do
          begin
            case Side of
              0: begin MX := CX0 - PW / 2 - Rad - S(3); MY := CY0; end;
              1: begin MX := CX0 + PW / 2 + Rad + S(3); MY := CY0; end;
              2: begin MX := CX0; MY := CY0 + PH / 2 + Rad + S(3); end;
            else
              begin MX := CX0; MY := CY0 - PH / 2 - Rad - S(3); end;
            end;
            Free_ := (MX - Rad >= R.Left) and (MX + Rad <= R.Right) and (MY - Rad >= R.Top) and (MY + Rad <= R.Bottom);
            if Free_ then
              for J := 0 to High(Places) do
              begin
                { (its own place is the one its middle is in) }
                if (FMarks[I].X > Places[J].L) and (FMarks[I].X < Places[J].R) and
                   (FMarks[I].Y > Places[J].T) and (FMarks[I].Y < Places[J].B) then Continue;
                if (MX + Rad > R.Left + Places[J].L * W) and (MX - Rad < R.Left + Places[J].R * W) and
                   (MY + Rad > R.Top + Places[J].T * H) and (MY - Rad < R.Top + Places[J].B * H) then
                begin
                  Free_ := False;
                  Break;
                end;
              end;
            if Free_ then Break;
          end;
        end;
      end;
      G.FillCircle(MX, MY, S(PIC_MARK_R) + SF(1.5), EffBack);
      G.FillCircle(MX, MY, S(PIC_MARK_R), clAccent);
      G.Text(IntToStr(FMarks[I].Number), MX - S(PIC_MARK_R), MY - S(PIC_MARK_R),
        2 * S(PIC_MARK_R), 2 * S(PIC_MARK_R), UIFont(11.5, True), clOnAccent, 1, 1, tfNoEllipsis);
    end;
  end;
  { the caption; the dots of a section with several pictures }
  CY := ClientHeight - S(PIC_GRIP_H) - S(PIC_CAPTION_H);
  T := FCaption;
  if FEnlarged then T := T + '  ·  click to make it small again';
  G.Text(T, S(PIC_PAD), CY, ClientWidth - 2 * S(PIC_PAD), S(PIC_CAPTION_H), UIFont(12), clTextDim, 1, 1);
  if FDots > 1 then
  begin
    X0 := ClientWidth - S(PIC_PAD) - FDots * S(PIC_DOT_STEP);
    for I := 0 to FDots - 1 do
      G.FillCircle(X0 + I * S(PIC_DOT_STEP) + S(PIC_DOT_STEP) / 2, CY + S(PIC_CAPTION_H) / 2, SF(3.5),
        IfC(I = FDot, clAccent, clTextFaint));
  end;
  { the lower edge: dragged to give the picture more or less room }
  G.FillRect(0, ClientHeight - 1, ClientWidth, 1, clBorder);
  G.FillRound(ClientWidth / 2 - S(18), ClientHeight - S(4), S(36), S(2), S(1), clTextFaint);
end;

procedure TMdPicture.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  D: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if (Y >= ClientHeight - S(PIC_GRIP_H) - S(2)) and not FEnlarged then
  begin
    FDragging := True;
    FDragY := Mouse.CursorPos.Y;
    Exit;
  end;
  D := DotAt(X, Y);
  if D >= 0 then
  begin
    StepTo := D;
    if Assigned(FOnStep) then FOnStep(Self);
    Exit;
  end;
  if Assigned(FOnToggle) then FOnToggle(Self);
end;

procedure TMdPicture.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  NowY: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then
  begin
    NowY := Mouse.CursorPos.Y;
    DragDelta := NowY - FDragY;
    FDragY := NowY;
    if (DragDelta <> 0) and Assigned(FOnDragBy) then FOnDragBy(Self);
    Exit;
  end;
  if (Y >= ClientHeight - S(PIC_GRIP_H) - S(2)) and not FEnlarged then Cursor := crVSplit
  else if (DotAt(X, Y) >= 0) or PtInRect(ImageRect, Point(X, Y)) then Cursor := crHandPoint
  else Cursor := crDefault;
end;

function TMdPicture.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if (WheelTarget <> nil) and not FEnlarged then WheelTarget.WheelFrom(Shift, WheelDelta);
end;

procedure TMdPicture.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
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

  { the right side: the picture of the section being read stays at the top,
    the text scrolls under it }
  FPicFrac := 0.45;
  FPicBlock := -1;
  FManualBlock := -1;
  FRight := TAuPanel.Create(Self);
  FRight.Parent := Body;
  FRight.Align := alClient;
  FRight.OnResize := @RightResize;
  FPic := TMdPicture.Create(Self);
  FPic.Parent := FRight;
  FPic.Visible := False;
  FPic.OnToggle := @PicToggle;
  FPic.OnStep := @PicStep;
  FPic.OnDragBy := @PicDragBy;
  FView := TMdView.Create(Self);
  FView.Parent := FRight;
  FView.PinImages := True;
  FView.OnScrolled := @ViewScrolled;
  FView.LoadMarkdown(LoadHelpText);
  FPic.WheelTarget := FView;
  ArrangeRight;
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
    JumpToBlock(FView.Topics[Row].Block);
    if not FTopics.Selected[Row] then FTopics.SelectOnly(Row);
  finally
    FSyncing := False;
  end;
end;

{ Shows the picture that belongs to the text being read, and gives it its
  room. "Being read" is the text at a fixed line of the right side (not of
  the text view, whose top moves with the panel), so the choice does not
  flip when the panel changes its height. When it does change, the text is
  scrolled by the same amount: the lines stay where they are on the screen
  and the room appears or goes above them. }
{ a jump to a topic or a search hit: the place at the top of the text, and
  with it the picture of that place }
procedure THelpWindow.JumpToBlock(ABlock: Integer);
begin
  FView.ScrollToBlock(ABlock);
  UpdatePicture(False);
end;

{ Shows the picture that belongs to the text at the top of the text view,
  and gives the panel its height. The text is never moved behind the panel:
  the panel takes its room above the text, sliding open or shut (an
  animation; at once when AInstant - the window sized, the panel's edge
  dragged), and the text view follows it, its top line staying its top line.
  The line that decides is a little below the top of the text view and so
  does not depend on the panel's height: a choice cannot flip back and forth. }
procedure THelpWindow.UpdatePicture(AInstant: Boolean);
const
  READ_LINE = 48;           // below the top of the text view
var
  Blk, NewH, I, Dot: Integer;
  Sec: TIntegerDynArray;
  InSec, Held: Boolean;
begin
  if FPicBusy or (FView = nil) or (FPic = nil) or (FRight.ClientHeight < S(160)) then Exit;
  FPicBusy := True;
  try
    Blk := FView.PictureFor(FView.ScrollOffset + S(READ_LINE));
    Sec := FView.SectionPictures(Blk);
    { a picture chosen by its dot stays while the text is in its section }
    InSec := False;
    for I := 0 to High(Sec) do
      if Sec[I] = FManualBlock then InSec := True;
    if InSec then Blk := FManualBlock else FManualBlock := -1;
    Dot := 0;
    for I := 0 to High(Sec) do
      if Sec[I] = Blk then Dot := I;
    if Blk < 0 then FPic.Enlarged := False
    else
      FPic.SetPicture(FView.PictureName(Blk), FView.PictureCaption(Blk), FView.PictureMarks(Blk), Length(Sec), Dot);
    FPicBlock := Blk;
    if Blk < 0 then NewH := 0
    else if FPic.Enlarged then NewH := FRight.ClientHeight
    else NewH := FPic.HeightFor(FRight.ClientWidth, Round(FRight.ClientHeight * FPicFrac));
    { While the thumb of the text's scroll bar is held, the panel keeps its
      height: opening or closing it moves the scroll bar under the mouse,
      which scrolls the text, which changes the picture again - without end.
      The height follows when the mouse button is let go (FHeldTimer). }
    Held := (not AInstant) and (GetKeyState(VK_LBUTTON) < 0) and (GetCaptureControl <> nil) and
      ((GetCaptureControl = FView) or (GetCaptureControl.Parent = FView));
    if Held then
    begin
      if NewH <> FPicTarget then
      begin
        if FHeldTimer = nil then
        begin
          FHeldTimer := TTimer.Create(Self);
          FHeldTimer.Interval := 60;
          FHeldTimer.OnTimer := @HeldTimerTick;
        end;
        FHeldTimer.Enabled := True;
      end;
    end
    else if (NewH <> FPicTarget) or (AInstant and (FPicH <> NewH)) then
    begin
      FPicTarget := NewH;
      if AInstant then AnimSet(FPicAnim, NewH)
      else AnimTo(FPicAnim, NewH, ANIM_NORMAL, Self, @PicAnimStep);
      { (no animation running: set at once, or animations are off) }
      if not FPicAnim.Running then
      begin
        FPicH := NewH;
        ArrangeRight;
      end;
    end;
  finally
    FPicBusy := False;
  end;
end;

{ the mouse button was held on the scroll bar: once it is let go, the panel
  gets the height of the picture it shows }
procedure THelpWindow.HeldTimerTick(Sender: TObject);
begin
  if GetKeyState(VK_LBUTTON) < 0 then Exit;
  FHeldTimer.Enabled := False;
  UpdatePicture(False);
end;

procedure THelpWindow.PicAnimStep(Sender: TObject; ADone: Boolean);
begin
  FPicH := Round(FPicAnim.Value);
  if ADone then FPicH := FPicTarget;
  ArrangeRight;
end;

{ The picture and the text are placed here, not by the alignment of the
  LCL: the text must be where it will be drawn at once. A panel that has
  closed keeps its picture until it has slid shut. }
procedure THelpWindow.ArrangeRight;
var
  W, H, PH, Gap: Integer;
begin
  W := FRight.ClientWidth;
  H := FRight.ClientHeight;
  PH := EnsureRange(FPicH, 0, H);
  FPic.SetBounds(0, 0, W, PH);
  FPic.Visible := PH > 0;
  { a little air between the picture's lower edge and the first line of text }
  Gap := 0;
  if (PH > 0) and (PH < H) then Gap := Math.Min(S(PIC_TEXT_GAP), H - PH);
  FView.SetBounds(0, PH + Gap, W, H - PH - Gap);
  FView.Visible := PH < H;
end;

procedure THelpWindow.RightResize(Sender: TObject);
begin
  ArrangeRight;
  UpdatePicture(True);
end;

{ a click on the picture: as large as the right side, and back }
procedure THelpWindow.PicToggle(Sender: TObject);
begin
  if FPicBlock < 0 then Exit;
  FPic.Enlarged := not FPic.Enlarged;
  UpdatePicture(False);
  FPic.Invalidate;
end;

{ a dot: another picture of the section }
procedure THelpWindow.PicStep(Sender: TObject);
var
  Sec: TIntegerDynArray;
begin
  Sec := FView.SectionPictures(FPicBlock);
  if (FPic.StepTo < 0) or (FPic.StepTo > High(Sec)) then Exit;
  FManualBlock := Sec[FPic.StepTo];
  UpdatePicture(False);
end;

{ the lower edge of the picture dragged: more or less room for pictures }
procedure THelpWindow.PicDragBy(Sender: TObject);
begin
  if FRight.ClientHeight <= 0 then Exit;
  FPicFrac := EnsureRange((FPicH + FPic.DragDelta) / FRight.ClientHeight, 0.2, 0.75);
  UpdatePicture(True);
end;

procedure THelpWindow.ViewScrolled(Sender: TObject);
var
  B, I, Sel: Integer;
begin
  UpdatePicture(False);
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
  JumpToBlock(Hit);
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
  if Hit >= 0 then JumpToBlock(Hit) else FView.Invalidate;
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

{$IFDEF DEBUG}
function PrintWindow(hWnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall; external 'user32.dll' name 'PrintWindow';

function THelpWindow.Probe(R: TStrings): Integer;
const
  STEP = 90;
var
  Fails, I, Prev, Guard, WithPic, Changes, LastBlk, Want: Integer;
  PrevLine, Line_: Single;
  PrevH: Integer;
  S0: string;

  procedure Pump;
  var
    TP: QWord;
  begin
    Application.ProcessMessages;
    { the panel slides to its height: wait until it is there }
    TP := GetTickCount64;
    while (FPicH <> FPicTarget) and (GetTickCount64 - TP < 1500) do
    begin
      Application.ProcessMessages;
      Sleep(4);
    end;
    FPic.Repaint;
    FView.Repaint;
    Application.ProcessMessages;
  end;

  procedure Check(const AText: string; AOk: Boolean; const ADetail: string = '');
  begin
    if AOk then Exit;
    Inc(Fails);
    if Fails <= 60 then R.Add('FAIL  ' + AText + '  ' + ADetail);
  end;

  { the text at the top of the text view (in document coordinates) }
  function TextAtLine: Single;
  begin
    Result := FView.ScrollOffset;
  end;

  { the state must fit the place: a picture wanted = a panel with a picture }
  procedure CheckState(const AWhere: string);
  var
    RefY: Single;
  begin
    RefY := FView.ScrollOffset + S(48);
    Want := FView.PictureFor(RefY);
    S0 := Format('%s: scroll %d, wanted block %d, shown block %d, panel %d of %d, view top %d',
      [AWhere, FView.ScrollOffset, Want, FPicBlock, FPicH, FRight.ClientHeight, FView.Top]);
    if FManualBlock < 0 then Check('the picture of the place is the one shown', Want = FPicBlock, S0);
    if FPicBlock >= 0 then
    begin
      Check('a picture is wanted: the panel is open', FPic.Visible and (FPic.Height >= S(80)), S0);
      Check('the panel has its picture', FPic.HasBitmap, S0 + ', name ' + FPic.PictureName);
      Check('the panel is where it should be', (FPic.Top = 0) and (FPic.Height = FPicH) and (FPicH = FPicTarget), S0);
    end
    else
      Check('no picture is wanted: the panel is closed', (FPicH = 0) and (FPicTarget = 0) and not FPic.Visible, S0);
    if not FPic.Enlarged then
      Check('the text is under the panel', FView.Visible and (FView.Top >= FPicH) and (FView.Top <= FPicH + S(PIC_TEXT_GAP)) and
        (FView.Top + FView.Height = FRight.ClientHeight), S0);
  end;

  procedure Walk(ADir: Integer; const AName: string);
  begin
    Guard := 0;
    WithPic := 0;
    Changes := 0;
    LastBlk := FPicBlock;
    repeat
      Prev := FView.ScrollOffset;
      PrevLine := TextAtLine;
      PrevH := FPicH;
      FView.ScrollTo(FView.ScrollOffset + ADir * S(STEP));
      Pump;
      CheckState(AName);
      if FPicBlock >= 0 then Inc(WithPic);
      if FPicBlock <> LastBlk then Inc(Changes);
      LastBlk := FPicBlock;
      Line_ := TextAtLine;
      { the text moved by the step, also when the panel changed its height
        (not at the ends, where the scroll position is held back) }
      if (FView.ScrollOffset <> Prev) and (Prev > S(60)) and (Abs(Abs(Line_ - PrevLine) - S(STEP)) > 3) and
         (Abs(FView.ScrollOffset - Prev) >= S(STEP) - 2) then
        Check('the text does not jump when the panel changes', False,
          Format('%s at scroll %d: the text at a fixed line moved by %.0f, the step is %d (panel %d -> %d)',
          [AName, FView.ScrollOffset, Abs(Line_ - PrevLine), S(STEP), PrevH, FPicH]));
      Inc(Guard);
    until (FView.ScrollOffset = Prev) or (Guard > 4000);
    R.Add(Format('%s: %d steps, %d with a picture, %d picture changes, ends at %d', [AName, Guard, WithPic, Changes,
      FView.ScrollOffset]));
    Check(AName + ': pictures were shown on the way', WithPic > 20, Format('%d steps with a picture', [WithPic]));
  end;

  { What the picture panel shows on the screen, taken from its window (as the
    desktop composes it): the number of different colours on a grid over the
    picture. A picture has many; an empty panel one or two. }
  function PanelColours: Integer;
  const
    PW_RENDERFULLCONTENT_ = 2;
  var
    DC, MemDC: HDC;
    Bmp, Old: HBITMAP;
    W, H, X, Y, I2, N: Integer;
    C: COLORREF;
    Seen: array[0..63] of COLORREF;
    Known: Boolean;
    Rc: TRect;
  begin
    Result := 0;
    Seen[0] := 0;
    FillChar(Seen, SizeOf(Seen), 0);
    if not (FPic.Visible and FPic.HandleAllocated) then Exit;
    W := FPic.Width;
    H := FPic.Height;
    if (W < 20) or (H < 20) then Exit;
    Rc := FPic.ImageRect;
    DC := GetDC(FPic.Handle);
    MemDC := CreateCompatibleDC(DC);
    Bmp := CreateCompatibleBitmap(DC, W, H);
    Old := SelectObject(MemDC, Bmp);
    try
      PrintWindow(FPic.Handle, MemDC, PW_RENDERFULLCONTENT_);
      N := 0;
      for Y := 1 to 14 do
        for X := 1 to 14 do
        begin
          C := GetPixel(MemDC, Rc.Left + (Rc.Right - Rc.Left) * X div 15, Rc.Top + (Rc.Bottom - Rc.Top) * Y div 15);
          Known := False;
          for I2 := 0 to N - 1 do
            if Seen[I2] = C then Known := True;
          if (not Known) and (N <= High(Seen)) then
          begin
            Seen[N] := C;
            Inc(N);
          end;
        end;
      Result := N;
    finally
      SelectObject(MemDC, Old);
      DeleteObject(Bmp);
      DeleteDC(MemDC);
      ReleaseDC(FPic.Handle, DC);
    end;
  end;

  procedure CheckDrawn(const AWhere: string);
  var
    N: Integer;
  begin
    if FPicBlock < 0 then Exit;
    N := PanelColours;
    Check('the picture is really on the screen', N >= 8, Format('%s: %d colours in the panel (picture %s, panel %d x %d)',
      [AWhere, N, FPic.PictureName, FPic.Width, FPic.Height]));
  end;

  { the window pulled to many sizes, as a hand does it, then maximized and
    put back: the picture must be there after every one }
  procedure ResizeStorm;
  const
    SIZES: array[0..11, 0..1] of Integer = ((1180, 820), (900, 820), (760, 820), (760, 480), (1000, 480), (1180, 560),
      (1400, 700), (1180, 900), (800, 600), (1180, 820), (1600, 1000), (1180, 820));
  var
    K, J, W0, H0: Integer;
  begin
    W0 := Width;
    H0 := Height;
    for K := 0 to High(SIZES) do
    begin
      { in steps, as a drag: many sizes on the way }
      for J := 1 to 8 do
      begin
        SetBounds(Left, Top, Width + (S(SIZES[K, 0]) - Width) * J div 8, Height + (S(SIZES[K, 1]) - Height) * J div 8);
        Application.ProcessMessages;
      end;
      Pump;
      CheckState(Format('resized to %d x %d', [SIZES[K, 0], SIZES[K, 1]]));
      CheckDrawn(Format('resized to %d x %d', [SIZES[K, 0], SIZES[K, 1]]));
    end;
    WindowState := wsMaximized;
    Pump;
    Sleep(200);
    Pump;
    CheckState('maximized');
    CheckDrawn('maximized');
    WindowState := wsNormal;
    Pump;
    Sleep(200);
    Pump;
    CheckState('restored');
    CheckDrawn('restored');
    SetBounds(Left, Top, W0, H0);
    Pump;
    CheckState('the first size again');
    CheckDrawn('the first size again');
    R.Add('resize storm done');
  end;

  { The lower edge of the picture dragged with the real mouse: up as far as
    it goes, down as far as it goes, and to the middle - the picture must be
    there after each, and when the text is scrolled afterwards. }
  procedure DragEdge(ABy: Integer; const AName: string);
  var
    P: TPoint;
    K, Steps: Integer;
    T0: QWord;

    procedure Wait(AMs: Integer);
    begin
      T0 := GetTickCount64;
      while GetTickCount64 - T0 < AMs do
      begin
        Application.ProcessMessages;
        Sleep(3);
      end;
    end;

  begin
    if not FPic.Visible then
    begin
      Check(AName + ': there is a picture to drag', False, '');
      Exit;
    end;
    BringToFront;
    SetForegroundWindow(Handle);
    Wait(150);
    P := FPic.ClientToScreen(Point(FPic.Width div 2, FPic.Height - S(3)));
    SetCursorPos(P.X, P.Y);
    Wait(60);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    Wait(60);
    Steps := Abs(ABy) div 12 + 1;
    for K := 1 to Steps do
    begin
      SetCursorPos(P.X, P.Y + S(ABy) * K div Steps);
      mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, 0);
      Wait(12);
    end;
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    Wait(200);
    Pump;
    R.Add(Format('%s: the panel is %d of %d high, picture %s, enlarged %s', [AName, FPicH, FRight.ClientHeight,
      FPic.PictureName, BoolToStr(FPic.Enlarged, True)]));
    CheckState(AName);
    CheckDrawn(AName);
    Check(AName + ': dragging did not enlarge the picture', not FPic.Enlarged, '');
  end;

  { The thumb of the text's scroll bar dragged with the real mouse through
    sections with and without pictures: it must come to an end (the panel
    must not open and close under the mouse), and afterwards the picture of
    the place must be shown. }
  procedure DragThumb(const AName: string);
  var
    Sb: TAuScrollBar;
    P: TPoint;
    K, Changes0: Integer;
    T0, TStart: QWord;
    LastH: Integer;

    procedure Wait(AMs: Integer);
    begin
      T0 := GetTickCount64;
      while GetTickCount64 - T0 < AMs do
      begin
        Application.ProcessMessages;
        if FPicH <> LastH then
        begin
          Inc(Changes0);
          LastH := FPicH;
        end;
        Sleep(3);
      end;
    end;

  begin
    Sb := FView.FScroll;
    FView.ScrollTo(0);
    Pump;
    BringToFront;
    SetForegroundWindow(Handle);
    LastH := FPicH;
    Changes0 := 0;
    Wait(150);
    TStart := GetTickCount64;
    P := Sb.ClientToScreen(Point(Sb.Width div 2, S(14)));
    SetCursorPos(P.X, P.Y);
    Wait(60);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    Wait(60);
    Changes0 := 0;
    for K := 1 to 60 do
    begin
      SetCursorPos(P.X, P.Y + (Sb.Height * 3 div 5) * K div 60);
      mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, 0);
      Wait(25);
    end;
    { held still for a moment: nothing may go on by itself }
    Prev := FView.ScrollOffset;
    Wait(600);
    Check(AName + ': the panel keeps its height while the thumb is held', Changes0 = 0,
      Format('%d changes of the panel during the drag', [Changes0]));
    Check(AName + ': nothing scrolls by itself while the thumb is held still', FView.ScrollOffset = Prev,
      Format('%d -> %d', [Prev, FView.ScrollOffset]));
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    Wait(400);
    Pump;
    R.Add(Format('%s: at scroll %d after %d ms, the panel is %d', [AName, FView.ScrollOffset, GetTickCount64 - TStart, FPicH]));
    Check(AName + ': the thumb moved the text', FView.ScrollOffset > S(500), IntToStr(FView.ScrollOffset));
    CheckState(AName);
    CheckDrawn(AName);
  end;

  { the wheel, as a reader turns it: notch after notch while the list still
    glides, a look at the state whenever it has come to rest }
  procedure WheelWalk(ADown: Boolean; const AName: string);
  var
    N, K, Rests, Open, Flips, LastH: Integer;
    T0: QWord;
  begin
    N := 0;
    Rests := 0;
    Open := 0;
    Flips := 0;
    LastH := FPicH;
    repeat
      Prev := FView.ScrollOffset;
      PrevLine := TextAtLine;
      for K := 1 to 6 do
      begin
        { (every other time over the picture, where the wheel must scroll the
          text as well) }
        if Odd(Rests) and FPic.Visible then FPic.DoMouseWheel([], IfThen(ADown, -120, 120), Point(0, 0))
        else FView.WheelNotch(ADown);
        T0 := GetTickCount64;
        while GetTickCount64 - T0 < 45 do
        begin
          Application.ProcessMessages;
          if FPicH <> LastH then
          begin
            Inc(Flips);
            LastH := FPicH;
          end;
          Sleep(4);
        end;
        Inc(N);
      end;
      T0 := GetTickCount64;
      while GetTickCount64 - T0 < 320 do
      begin
        Application.ProcessMessages;
        Sleep(5);
      end;
      Pump;
      Inc(Rests);
      CheckState(AName);
      if FPicBlock >= 0 then Inc(Open);
      { six notches moved the text by six notches, whatever the picture
        panel did meanwhile (not at the ends of the text) }
      if (Prev > S(100)) and (FView.ScrollOffset < FView.MaxScroll - S(100)) and (FView.ScrollOffset > S(100)) and
         (Abs(Abs(TextAtLine - PrevLine) - 6 * S(80)) > 4) then
        Check(AName + ': the text moves by what the wheel turned', False,
          Format('at scroll %d the text at a fixed line moved by %.0f, six notches are %d', [FView.ScrollOffset,
          Abs(TextAtLine - PrevLine), 6 * S(80)]));
    until (FView.ScrollOffset = Prev) or (N > 3000);
    R.Add(Format('%s: %d notches, %d rests, %d of them with a picture, the panel changed %d times, ends at %d',
      [AName, N, Rests, Open, Flips, FView.ScrollOffset]));
    Check(AName + ': pictures were shown on the way', Open > 8, Format('%d rests with a picture', [Open]));
    Check(AName + ': the panel does not flicker', Flips < 3 * Rests, Format('%d changes in %d rests', [Flips, Rests]));
  end;

begin
  Fails := 0;
  Show;
  Pump;
  R.Add(Format('window %d x %d, right side %d x %d, %d topics', [ClientWidth, ClientHeight, FRight.ClientWidth,
    FRight.ClientHeight, Length(FView.Topics)]));
  FView.ScrollTo(0);
  Pump;
  CheckState('at the top');
  Walk(1, 'down');
  Walk(-1, 'up');
  Check('back at the top', FView.ScrollOffset = 0, IntToStr(FView.ScrollOffset));
  WheelWalk(True, 'wheel down');
  WheelWalk(False, 'wheel up');
  Check('the wheel came back to the top', FView.ScrollOffset = 0, IntToStr(FView.ScrollOffset));
  { every topic: its heading under the picture, the picture of the topic }
  for I := 0 to High(FView.Topics) do
  begin
    TopicClick(nil, I);
    Pump;
    CheckState('topic "' + FView.Topics[I].Title + '"');
    Check('the heading of the topic is at the top of the text',
      (FView.BlockTop(FView.Topics[I].Block) - FView.ScrollOffset >= 0) and
      (FView.BlockTop(FView.Topics[I].Block) - FView.ScrollOffset <= S(60)) or
      (FView.ScrollOffset >= FView.MaxScroll - 2),
      Format('"%s": heading %.0f below the top of the text (scroll %d of %d)', [FView.Topics[I].Title,
      FView.BlockTop(FView.Topics[I].Block) - FView.ScrollOffset, FView.ScrollOffset, FView.MaxScroll]));
    if FView.Topics[I].Title = 'The main interface' then
    begin
      Check('the main window picture is shown', FPic.PictureName = '02-dark-playing', FPic.PictureName);
      Check('with its 11 markers', FPic.MarkCount = 11, Format('%d markers', [FPic.MarkCount]));
    end;
    if FView.Topics[I].Title = 'Aulumic overview' then
      Check('the overview has the main window picture', FPic.PictureName = '02-dark-playing', FPic.PictureName);
  end;
  { the window in many sizes: at a topic with a picture, then in the middle
    of the text }
  GoTopic('The main interface');
  Pump;
  CheckDrawn('before the resizes');
  ResizeStorm;
  GoTopic('Properties');
  Pump;
  FView.ScrollTo(FView.ScrollOffset + S(300));
  Pump;
  ResizeStorm;
  Walk(1, 'down after the resizes');
  Walk(-1, 'up after the resizes');
  { the scroll bar's thumb dragged by the mouse }
  DragThumb('thumb dragged');
  DragThumb('thumb dragged again');
  { the picture's edge dragged by the mouse }
  GoTopic('The main interface');
  Pump;
  DragEdge(-900, 'edge dragged far up');
  DragEdge(1400, 'edge dragged far down');
  DragEdge(-150, 'edge dragged up a little');
  DragEdge(-2000, 'edge dragged out of the window at the top');
  Walk(1, 'down after the drags');
  Walk(-1, 'up after the drags');
  GoTopic('The main interface');
  Pump;
  CheckDrawn('the main interface after the drags');
  DragEdge(400, 'edge dragged down again');
  WheelWalk(True, 'wheel down after the drags');
  WheelWalk(False, 'wheel up after the drags');
  { enlarged and back }
  GoTopic('The main interface');
  Pump;
  PrevH := FPicH;
  PicToggle(nil);
  Pump;
  Check('enlarged: the picture fills the right side', FPic.Enlarged and (FPic.Height = FRight.ClientHeight) and FPic.HasBitmap,
    Format('panel %d of %d', [FPic.Height, FRight.ClientHeight]));
  PicToggle(nil);
  Pump;
  CheckState('small again');
  Check('small again: as before', (not FPic.Enlarged) and (FPicH = PrevH), Format('%d, was %d', [FPicH, PrevH]));
  { scrolling while enlarged must not lose the picture }
  PicToggle(nil);
  Pump;
  FView.ScrollTo(FView.ScrollOffset + S(400));
  Pump;
  PicToggle(nil);
  Pump;
  CheckState('enlarged, scrolled, small again');
  { the text size }
  GoTopic('The main interface');
  Pump;
  FView.Zoom(2);
  Pump;
  CheckState('larger text');
  FView.Zoom(-2);
  Pump;
  CheckState('normal text again');
  { the window size }
  SetBounds(Left, Top, Width - S(200), Height - S(200));
  Pump;
  CheckState('a smaller window');
  SetBounds(Left, Top, Width + S(200), Height + S(200));
  Pump;
  CheckState('the window as it was');
  { hidden and shown again }
  Hide;
  Application.ProcessMessages;
  Show;
  Pump;
  CheckState('hidden and shown again');
  Walk(1, 'down after all that');
  { a search hit }
  FSearch.Text := 'transport';
  SearchEnter(nil);
  Pump;
  CheckState('a search hit');
  FSearch.Text := '';
  R.Add(Format('failures: %d', [Fails]));
  Result := Fails;
end;

function RunHelpProbe(const AReport: string): Integer;
var
  R: TStringList;
begin
  R := TStringList.Create;
  try
    ShowHelpWindow('');
    if HelpForm = nil then
    begin
      R.Add('FAIL  the help window could not be opened');
      Result := 1;
    end
    else
      try
        Result := HelpForm.Probe(R);
      except
        on E: Exception do
        begin
          R.Add('FAIL  exception: ' + E.ClassName + ': ' + E.Message);
          Result := 1000;
        end;
      end;
    try
      R.SaveToFile(AReport);
    except
    end;
  finally
    R.Free;
  end;
end;
{$ENDIF}

initialization
  AuShowHelp := @ShowHelpWindow;

finalization
  FreeAndNil(GAnchors);

end.
