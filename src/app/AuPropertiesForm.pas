unit AuPropertiesForm;

{ The Properties dialog (Aulumic's uFormTagEditor; Main menu > Tools > Edit
  Properties..., Alt+Enter, the library and playlist menus) in the Aulos
  layout:
    left        the files (a dot marks a changed one, ! one whose tag could
                not be read - it is never saved)
    Tags        Title, Artist, Album Artist, Album, Genre, Year, Track, Disc,
                Composer, Performer, Comment (several lines); the cover with
                Load..., Search the Web and Remove (Ctrl+V pastes an image, an
                image file can be dropped on the window)
    Inspector   the audio format, the file, the play statistics and every tag
  With several files selected a field that differs shows "Multiple Values";
  Title and Track stay unique per track. Only the fields the user changes
  are written. Save hands the changed files to the metadata custodian
  (background thread, as Aulumic) and closes.
  ---> AulumicNS: sizable (Layout); it opens at the size it had. }

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, Dialogs, LCLType, Clipbrd,
  AuGfx, AuTheme, AuIcons, AuControls, AuLists, AuForms, AuTagLoader, uLibraryManager;

{ the editor for the loaded records (AuTagLoader); takes them over }
procedure ShowPropertiesDialog(AOwner: TComponent; var AData: TList; ALibrary: TLibraryManager);
{ the dialog, not shown (screenshot mode); takes AData over }
function CreatePropertiesForm(AOwner: TComponent; var AData: TList; ALibrary: TLibraryManager): TAuForm;
{ screenshot mode: the tab shown (0 Tags, 1 Inspector) }
procedure SelectPropertiesTab(AForm: TAuForm; ATab: Integer);

implementation

uses
  AuAudioTypes, Graphics, LCLIntf, DateUtils, ALMetadata, uMetaUtils, uAppConsts, uAppStrings, uOSUtils,
  uMetadataPayloads, uEngineStateManager, uUserStatsManager, uLibraryTypes, AuLog, 
  uSettingsManager;

type
  TTagField = (tfTitle, tfArtist, tfAlbumArtist, tfAlbum, tfGenre, tfYear, tfTrack, tfDisc,
    tfComposer, tfPerformer, tfComment);
  TTagFields = set of TTagField;

  { TPropertiesForm }

  TPropertiesForm = class(TAuForm)
  private
    FLibrary: TLibraryManager;
    FItems: TList;                    // PTagEditNodeData
    FList: TAuListView;
    FTabs: TAuTabs;
    { ---> AulumicNS: the Tags page scrolls when the window is low (was a panel) }
    FPageTags: TAuScrollBox;
    FTags: TWinControl;               // its content: the fields and the cover column
    FPageInspector: TAuPanel;
    FEdits: array[TTagField] of TAuEdit;   // the comment is the memo
    FCaps: array[TTagField] of TAuLabel;
    FMemo: TAuMemo;
    FCover: TAuCover;
    FCoverInfo, FCoverLbl, FCoverNote, FTagsNote: TAuLabel;
    FBtnLoad, FBtnWeb, FBtnClear, FBtnSave, FBtnCancel: TAuButton;
    FInsTitle: TAuLabel;
    // ---> AulumicNS: a read-only memo like the Comment field (was a list of lines)
    FInsMemo: TAuMemo;
    FStatus: TAuLabel;
    FMixed: TTagFields;
    FUpdating, FCommitting: Boolean;
    FShownCoverLen: SizeInt;
    FShownCoverHash: QWord;
    function Item(I: Integer): PTagEditNodeData;
    function FieldEdit(F: TTagField): TAuEdit;
    function FieldText(F: TTagField): string;
    procedure SetFieldText(F: TTagField; const AText: string);
    procedure SyncUIToSelection;
    procedure EditorChange(Sender: TObject);
    procedure MarkRows;
    procedure ShowCoverBytes(const ABytes: TBytes);
    procedure ApplyNewCover(const ABytes: TBytes; const AMime: string);
    function LoadCoverFile(const AFileName: string): Boolean;
    function PasteCover: Boolean;
    function JpegFromBitmap(B: TGfxBitmap; out ABytes: TBytes): Boolean;
    procedure RefreshInspector;
    procedure InspectorSingle(D: PTagEditNodeData);
    procedure InspectorMulti;
    procedure InvalidateThumb(const Artist, AlbumArtist, Album, FolderPath: string);
    procedure ListDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single; var Handled: Boolean);
    procedure ListSel(Sender: TObject);
    procedure TabChange(Sender: TObject);
    procedure LoadClick(Sender: TObject);
    procedure WebClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure FormDrop(Sender: TObject; const FileNames: array of string);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure Layout;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure Resize; override;
  public
    constructor CreateProps(AOwner: TComponent; AData: TList; ALibrary: TLibraryManager);
    destructor Destroy; override;
  end;

const
  { ---> AulumicNS: the size it opens with the first time (then the size it
    had; sizable since 2026-11-11). The height was 650 (708 with the title
    bar: too high for 1920 x 1080 at 150 %, which leaves 688); 612 fits
    1280 x 720 at 100 % too. }
  DLG_W = 1000;
  DLG_H = 612;
  MIN_W = 920;                     // the fields keep about 360 px
  MIN_H = 440;
  COMMENT_H = 80;                  // the comment memo at its smallest (was 110)
  LIST_W = 260;
  PX = LIST_W + 44;                // the right part
  COVER_W = 204;                   // the cover column (at the right of the Tags page)
  { the Tags page at its smallest: five rows of fields, the Comment with its
    smallest memo, the note under it; a lower page scrolls }
  TAGS_MIN_H = 5 * 66 + 22 + COMMENT_H + 10 + 40;
  MAX_COVER_PX = 1500;
  COVER_PREVIEW_PX = 1024;   // the cover as the dialog decodes it for its preview
  MAX_COVER_BYTES = 15 * BYTES_PER_MB;
  FIELD_CAPTIONS: array[TTagField] of string = ('Title', 'Artist', 'Album artist', 'Album', 'Genre',
    'Year', 'Track', 'Disc', 'Composer', 'Performer', 'Comment');
  FIELD_HINTS: array[TTagField] of string = (
    'The title of the track.',
    'The performing artist(s). Separate several with ";".',
    'The artist of the whole album (groups the album in the library). Separate several with ";".',
    'The album.',
    'The genre(s). Separate several with ";".',
    'The year or the date of the recording.',
    'The track number.',
    'The disc number.',
    'The composer(s). Separate several with ";".',
    'The performer(s), e.g. soloists. Separate several with ";".',
    'A comment (several lines).');

{$PUSH}{$Q-}{$R-}
function CoverHash(const ABytes: TBytes): QWord;
var
  I, Len, Step: SizeInt;
begin
  Len := Length(ABytes);
  if Len = 0 then Exit(0);
  Result := QWord($CBF29CE484222325);
  Step := Math.Max(1, Len div 4096);
  I := 0;
  while I < Len do
  begin
    Result := (Result xor ABytes[I]) * QWord($100000001B3);
    Inc(I, Step);
  end;
  Result := (Result xor ABytes[Len - 1]) * QWord($100000001B3);
end;
{$POP}

{ Aulumic's CompareTagNodes: disc, track, then the file name (natural) }
function CompareNodes(Item1, Item2: Pointer): Integer;
var
  D1, D2: PTagEditNodeData;
begin
  if Item1 = Item2 then Exit(0);
  if Item1 = nil then Exit(-1);
  if Item2 = nil then Exit(1);
  D1 := PTagEditNodeData(Item1);
  D2 := PTagEditNodeData(Item2);
  if (D1^.Current.Disc > 0) and (D2^.Current.Disc > 0) and (D1^.Current.Disc <> D2^.Current.Disc) then
    Exit(IfThen(D1^.Current.Disc < D2^.Current.Disc, -1, 1));
  if (D1^.Current.Track > 0) and (D2^.Current.Track > 0) and (D1^.Current.Track <> D2^.Current.Track) then
    Exit(IfThen(D1^.Current.Track < D2^.Current.Track, -1, 1));
  Result := NaturalCompareText(ExtractFileName(D1^.FilePath), ExtractFileName(D2^.FilePath));
end;

function FirstArtistOf(const S: string): string;
var
  P: Integer;
begin
  Result := Trim(S);
  P := Pos(';', Result);
  if P > 0 then Result := Trim(Copy(Result, 1, P - 1));
end;

function URLEncode(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then Result := Result + S[I]
    else if S[I] = ' ' then Result := Result + '+'
    else Result := Result + '%' + IntToHex(Ord(S[I]), 2);
end;

procedure ShowPropertiesDialog(AOwner: TComponent; var AData: TList; ALibrary: TLibraryManager);
var
  F: TPropertiesForm;
begin
  F := TPropertiesForm.CreateProps(AOwner, AData, ALibrary);
  AData := nil;
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

function CreatePropertiesForm(AOwner: TComponent; var AData: TList; ALibrary: TLibraryManager): TAuForm;
begin
  Result := TPropertiesForm.CreateProps(AOwner, AData, ALibrary);
  AData := nil;
end;

procedure SelectPropertiesTab(AForm: TAuForm; ATab: Integer);
begin
  if not (AForm is TPropertiesForm) then Exit;
  TPropertiesForm(AForm).FTabs.TabIndex := ATab;
  TPropertiesForm(AForm).TabChange(nil);
end;

{ ---- TPropertiesForm ---- }

constructor TPropertiesForm.CreateProps(AOwner: TComponent; AData: TList; ALibrary: TLibraryManager);
var
  F: TTagField;
  I, W, H: Integer;

  { a field (its caption and edit); Layout places it }
  procedure Field(AF: TTagField);
  begin
    FCaps[AF] := AddLabel(FTags, FIELD_CAPTIONS[AF], 0, 0, 100, True);
    FCaps[AF].FontSize := 12;
    if AF = tfComment then
    begin
      FMemo := TAuMemo.Create(Self);
      FMemo.Parent := FTags;
      FMemo.OnChange := @EditorChange;
      FMemo.Hint := FIELD_HINTS[AF];
      FMemo.ShowHint := True;
      FEdits[AF] := FMemo;
    end
    else
    begin
      FEdits[AF] := AddEdit(FTags, 0, 22, 100);
      FEdits[AF].OnChange := @EditorChange;
      FEdits[AF].Hint := FIELD_HINTS[AF];
      FEdits[AF].ShowHint := True;
    end;
  end;

begin
  { ---> AulumicNS: sizable; the size it had last time (96-DPI units), else
    DLG_W x DLG_H; at most the screen (FitToWorkArea) }
  W := AppSettings.Data.PropsWinW;
  H := AppSettings.Data.PropsWinH;
  if (W < MIN_W) or (H < MIN_H) then
  begin
    W := DLG_W;
    H := DLG_H;
  end;
  CreateAu(AOwner, CAP_TAG_EDITOR_PROPERTIES, W, H);
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMaximize];
  Constraints.MinWidth := S(MIN_W);
  Constraints.MinHeight := S(MIN_H);
  FitToWorkArea;
  HelpKeyword := 'Properties';
  FLibrary := ALibrary;
  FItems := TList.Create;
  if AData <> nil then
  begin
    for I := 0 to AData.Count - 1 do
      if AData[I] <> nil then FItems.Add(AData[I]);
    AData.Free;
  end;
  FItems.Sort(@CompareNodes);

  { the files }
  AddHeading(Self, 'Files', 24, 14, LIST_W);
  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.ShowHeader := False;
  FList.MultiSelect := True;
  FList.RowMenu := False;
  FList.AutoFit := True;
  FList.RowHeight := S(30);
  FList.AddColumn('File', 200, 0, True);
  FList.BackRole := crCard;
  FList.OnDrawCell := @ListDraw;
  FList.OnSelChange := @ListSel;
  FList.TabOrder := 0;

  { the pages }
  FTabs := TAuTabs.Create(Self);
  FTabs.Parent := Body;
  FTabs.SetBounds(S(PX), S(10), S(300), S(38));
  FTabs.AddTab('Tags');
  FTabs.AddTab('Inspector');
  FTabs.OnChange := @TabChange;
  FTabs.TabOrder := 1;
  FPageTags := TAuScrollBox.Create(Self);
  FPageTags.Parent := Body;
  FPageTags.TabOrder := 2;
  FTags := FPageTags.Content;
  FPageInspector := TAuPanel.Create(Self);
  FPageInspector.Parent := Body;
  FPageInspector.BorderSides := 0;
  FPageInspector.Visible := False;

  for F := Low(TTagField) to High(TTagField) do Field(F);
  for F := Low(TTagField) to High(TTagField) do FEdits[F].TabOrder := Ord(F);

  { the cover }
  FCoverLbl := AddLabel(FTags, 'Cover', 0, 0, COVER_W, True);
  FCoverLbl.FontSize := 12;
  FCover := TAuCover.Create(Self);
  FCover.Parent := FTags;
  FCover.Radius := 8;
  FCover.Shadow := False;
  FCover.OnClick := @LoadClick;
  FCover.Cursor := crHandPoint;
  FCover.Hint := 'Click to load a cover from a file.';
  FCover.ShowHint := True;
  FCoverInfo := AddLabel(FTags, '', 0, 0, COVER_W);
  FCoverInfo.FontSize := 11.5;
  FCoverInfo.HAlign := 1;
  FBtnLoad := AddButton(FTags, 'Load...', 0, 0, COVER_W, bkNormal, @LoadClick);
  FBtnLoad.Icon := icImage;
  FBtnLoad.Hint := 'Load the cover from an image file (JPEG, PNG or BMP) for the selected files.';
  FBtnLoad.ShowHint := True;
  FBtnWeb := AddButton(FTags, 'Search the web', 0, 0, COVER_W, bkNormal, @WebClick);
  FBtnWeb.Icon := icGlobe;
  FBtnWeb.Hint := HINT_BTN_WEB_COVER;
  FBtnWeb.ShowHint := True;
  FBtnClear := AddButton(FTags, 'Remove', 0, 0, COVER_W, bkNormal, @ClearClick);
  FBtnClear.Icon := icTrash;
  FBtnClear.Hint := 'Remove the cover from the selected files.';
  FBtnClear.ShowHint := True;
  FBtnLoad.TabOrder := 20;
  FBtnWeb.TabOrder := 21;
  FBtnClear.TabOrder := 22;
  FCoverNote := AddLabel(FTags, 'Ctrl+V pastes a copied image; an image file can be dropped here.', 0, 0,
    COVER_W);
  with FCoverNote do
  begin
    FontSize := 11.5;
    WordWrap := True;
    VAlign := 0;
    Height := S(40);
    TextRole := crTextFaint;
  end;
  FTagsNote := AddLabel(FTags, 'Several values in one field: separate them with ";". Only the fields you ' +
    'change are written; the files keep all their other tags.', 0, 0, 400);
  with FTagsNote do
  begin
    FontSize := 11.5;
    WordWrap := True;
    VAlign := 0;
    Height := S(40);
    TextRole := crTextFaint;
  end;

  { the inspector }
  FInsTitle := AddLabel(FPageInspector, LBL_INSPECTOR_DEFAULT, 0, 0, 400, False);
  FInsTitle.Bold := True;
  FInsMemo := TAuMemo.Create(Self);
  FInsMemo.Parent := FPageInspector;
  FInsMemo.ReadOnly := True;
  FInsMemo.Hint := 'Select text and press Ctrl+C to copy it.';
  FInsMemo.ShowHint := True;

  { the buttons }
  FStatus := AddLabel(Self, '', 24, 0, 500);
  FStatus.Height := S(34);
  FBtnCancel := AddButton(Self, 'Cancel', 0, 0, 110);
  FBtnCancel.ModalResult := mrCancel;
  FBtnSave := AddButton(Self, 'Save', 0, 0, 110, bkPrimary, @SaveClick);
  DefaultButton := FBtnSave;
  FBtnSave.TabOrder := 30;
  FBtnCancel.TabOrder := 31;
  Layout;

  AllowDropFiles := True;
  OnDropFiles := @FormDrop;
  OnCloseQuery := @FormCloseQuery;

  FList.RowCount := FItems.Count;
  if FItems.Count = 1 then FList.SelectOnly(0)
  else
  begin
    FList.SelectAll;
    SyncUIToSelection;
  end;
  if FItems.Count = 1 then Caption := CAP_TAG_EDITOR_PROPERTIES + ' - ' + ExtractFileName(Item(0)^.FilePath)
  else Caption := Format('%s - %d files', [CAP_TAG_EDITOR_PROPERTIES, FItems.Count]);
  ActiveControl := FList;
end;

destructor TPropertiesForm.Destroy;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do Dispose(PTagEditNodeData(FItems[I]));
  FItems.Free;
  inherited Destroy;
end;

{ ---> AulumicNS: every position from the window's size (sizable since
  2026-11-11): the file list and the Inspector grow with the height, the
  fields with the width; the Comment memo takes the rest of the width and
  all the extra height. Below TAGS_MIN_H the Tags page scrolls (1920 x 1080
  at 175 % leaves about 590 px; the default height is 612). }
procedure TPropertiesForm.Layout;
var
  K: Single;
  Wd, Ht, PW, PH, FW, CX, Y, MemoH, BY, Half, Third: Integer;
  Scrolls: Boolean;

  procedure Place(C: TControl; X, AY, W, H: Integer);
  begin
    C.SetBounds(S(X), S(AY), S(W), S(H));
  end;

  { the caption, and the edit 22 px below it (the memo MemoH high) }
  procedure PlaceField(AF: TTagField; X, AY, W: Integer);
  begin
    FCaps[AF].SetBounds(S(X), S(AY), S(W), FCaps[AF].Height);
    if AF = tfComment then Place(FMemo, X, AY + 22, W, MemoH)
    else FEdits[AF].SetBounds(S(X), S(AY + 22), S(W), FEdits[AF].Height);
  end;

begin
  if (FList = nil) or (FBtnSave = nil) or (FInsMemo = nil) then Exit;
  UseDpiOf(Self);
  K := UIScale;
  if K <= 0 then K := 1;
  Wd := Trunc(ClientWidth / K);
  Ht := Trunc(BodyHeight / K);
  PW := Wd - PX - 24;
  PH := Ht - 58 - 72;
  Place(FList, 24, 50, LIST_W, Ht - 50 - 72);
  Place(FPageTags, PX, 58, PW, PH);
  Place(FPageInspector, PX, 58, PW, PH);
  FInsTitle.SetBounds(0, 0, S(PW), FInsTitle.Height);
  Place(FInsMemo, 0, 28, PW, PH - 28);

  { the Tags page: the fields left, the cover column right (fixed width);
    with the scroll bar the content is 12 px narrower }
  Scrolls := PH < TAGS_MIN_H;
  FW := PW - 28 - COVER_W;
  if Scrolls then Dec(FW, 16);
  CX := FW + 28;
  MemoH := Math.Max(COMMENT_H, PH - TAGS_MIN_H + COMMENT_H);
  Half := (FW - 16) div 2;
  Third := (FW - 32) div 3;
  Y := 0;
  PlaceField(tfTitle, 0, Y, FW);
  Inc(Y, 66);
  PlaceField(tfArtist, 0, Y, Half);
  PlaceField(tfAlbumArtist, Half + 16, Y, FW - Half - 16);
  Inc(Y, 66);
  PlaceField(tfAlbum, 0, Y, Half);
  PlaceField(tfGenre, Half + 16, Y, FW - Half - 16);
  Inc(Y, 66);
  PlaceField(tfYear, 0, Y, Third);
  PlaceField(tfTrack, Third + 16, Y, Third);
  PlaceField(tfDisc, 2 * (Third + 16), Y, FW - 2 * (Third + 16));
  Inc(Y, 66);
  PlaceField(tfComposer, 0, Y, Half);
  PlaceField(tfPerformer, Half + 16, Y, FW - Half - 16);
  Inc(Y, 66);
  PlaceField(tfComment, 0, Y, FW);
  FTagsNote.SetBounds(0, S(Y + 22 + MemoH + 10), S(FW), S(40));
  { content as high as the page (0) unless the page is lower than the fields }
  if Scrolls then FPageTags.ContentHeight := S(TAGS_MIN_H) else FPageTags.ContentHeight := 0;

  FCoverLbl.SetBounds(S(CX), 0, S(COVER_W), FCoverLbl.Height);
  Place(FCover, CX, 22, COVER_W, COVER_W);
  FCoverInfo.SetBounds(S(CX), S(22 + COVER_W + 6), S(COVER_W), FCoverInfo.Height);
  BY := 22 + COVER_W + 34;
  FBtnLoad.SetBounds(S(CX), S(BY), S(COVER_W), FBtnLoad.Height);
  FBtnWeb.SetBounds(S(CX), S(BY + 40), S(COVER_W), FBtnWeb.Height);
  FBtnClear.SetBounds(S(CX), S(BY + 80), S(COVER_W), FBtnClear.Height);
  FCoverNote.SetBounds(S(CX), S(BY + 124), S(COVER_W), S(40));

  { the bottom: the status left, Cancel and Save right }
  FStatus.SetBounds(S(24), S(Ht - 24 - 34), S(Math.Max(100, Wd - 2 * 110 - 10 - 72)), FStatus.Height);
  FBtnCancel.SetBounds(S(Wd - 24 - 2 * 110 - 10), S(Ht - 24 - 34), S(110), FBtnCancel.Height);
  FBtnSave.SetBounds(S(Wd - 24 - 110), S(Ht - 24 - 34), S(110), FBtnSave.Height);
end;

procedure TPropertiesForm.Resize;
begin
  inherited Resize;
  Layout;
  { the size for the next time (not a maximized one) }
  if Showing and (WindowState = wsNormal) then
    SizeToRemember(AppSettings.Data.PropsWinW, AppSettings.Data.PropsWinH);
end;

function TPropertiesForm.Item(I: Integer): PTagEditNodeData;
begin
  if (I >= 0) and (I < FItems.Count) then Result := PTagEditNodeData(FItems[I]) else Result := nil;
end;

function TPropertiesForm.FieldEdit(F: TTagField): TAuEdit;
begin
  Result := FEdits[F];
end;

function TPropertiesForm.FieldText(F: TTagField): string;
begin
  if F = tfComment then Result := FMemo.Text else Result := FEdits[F].Text;
end;

procedure TPropertiesForm.SetFieldText(F: TTagField; const AText: string);
begin
  if F = tfComment then
  begin
    if FMemo.Text <> AText then FMemo.Text := AText;
  end
  else if FEdits[F].Text <> AText then
    FEdits[F].Text := AText;
end;

procedure TPropertiesForm.ListDraw(Sender: TObject; G: TGfx; Row, Col: Integer; X, Y, W, H: Single;
  var Handled: Boolean);
var
  D: PTagEditNodeData;
  C: TARGB;
begin
  D := Item(Row);
  if D = nil then Exit;
  Handled := True;
  if D^.ReadFailed then DrawIcon(G, icWarning, X + S(12), Y + H / 2, S(13), clWarn)
  else if D^.IsModified or D^.CoverModified then G.FillCircle(X + S(12), Y + H / 2, SF(3.5), clAccentText);
  if D^.ReadFailed then C := clTextDim else C := clText;
  G.Text(ExtractFileName(D^.FilePath), X + S(24), Y, W - S(28), H, UIFont(12.5), C, 0, 1);
end;

procedure TPropertiesForm.MarkRows;
begin
  FList.Invalidate;
end;

procedure TPropertiesForm.ListSel(Sender: TObject);
begin
  SyncUIToSelection;
end;

procedure TPropertiesForm.TabChange(Sender: TObject);
begin
  FPageTags.Visible := FTabs.TabIndex = 0;
  FPageInspector.Visible := FTabs.TabIndex = 1;
  if FTabs.TabIndex = 1 then RefreshInspector;
end;

{ ---- the selection into the fields (Aulumic's SyncUIToSelection) ---- }

procedure TPropertiesForm.SyncUIToSelection;
var
  Sel: TIntegerArray;
  First, D: PTagEditNodeData;
  F: TTagField;
  I: Integer;
  Meta: TAudioMetadata;

  function Value(AD: PTagEditNodeData; AF: TTagField): string;
  begin
    case AF of
      tfTitle: Result := AD^.Current.Title;
      tfArtist: Result := AD^.Current.Artist;
      tfAlbumArtist: Result := AD^.Current.AlbumArtist;
      tfAlbum: Result := AD^.Current.Album;
      tfGenre: Result := AD^.Current.Genre;
      tfYear: Result := AD^.Current.DateStr;
      tfTrack: if AD^.Current.Track > 0 then Result := IntToStr(AD^.Current.Track) else Result := '';
      tfDisc: if AD^.Current.Disc > 0 then Result := IntToStr(AD^.Current.Disc) else Result := '';
      tfComposer: Result := AD^.Current.Composer;
      tfPerformer: Result := AD^.Current.Performer;
    else
      Result := AD^.Current.Comment;
    end;
  end;

begin
  Sel := FList.SelectedRows;
  if Length(Sel) = 0 then
  begin
    FStatus.Caption := 'No file selected.';
    Exit;
  end;
  First := Item(Sel[0]);
  if First = nil then Exit;
  FUpdating := True;
  try
    FMixed := [];
    if Length(Sel) = 1 then
    begin
      FStatus.Caption := First^.FilePath;
      for F := Low(TTagField) to High(TTagField) do
      begin
        FEdits[F].Enabled := not First^.ReadFailed;
        FEdits[F].Placeholder := '';
        SetFieldText(F, Value(First, F));
      end;
      if FTabs.TabIndex = 1 then InspectorSingle(First);
    end
    else
    begin
      FStatus.Caption := Format('%d of %d files selected.', [Length(Sel), FItems.Count]);
      for F := Low(TTagField) to High(TTagField) do
      begin
        if F in [tfTitle, tfTrack] then
        begin
          { unique per track }
          FEdits[F].Enabled := False;
          FEdits[F].Placeholder := LBL_UNIQUE_PER_TRACK;
          SetFieldText(F, '');
          Continue;
        end;
        FEdits[F].Enabled := True;
        for I := 1 to High(Sel) do
        begin
          D := Item(Sel[I]);
          if (D <> nil) and (Value(D, F) <> Value(First, F)) then
          begin
            Include(FMixed, F);
            Break;
          end;
        end;
        if F in FMixed then
        begin
          FEdits[F].Placeholder := LBL_MULTIPLE_VALUES;
          SetFieldText(F, '');
        end
        else
        begin
          FEdits[F].Placeholder := '';
          SetFieldText(F, Value(First, F));
        end;
      end;
      if FTabs.TabIndex = 1 then InspectorMulti;
    end;
    for F := Low(TTagField) to High(TTagField) do FEdits[F].Invalidate;
    { the cover of the first selected file }
    if First^.HasCover then
    begin
      if Length(First^.CoverData) = 0 then
      begin
        Meta := ReadTrackMetadata(First^.FilePath, True);
        First^.CoverData := Meta.CoverData;
        Meta.CoverData := nil;
      end;
      ShowCoverBytes(First^.CoverData);
    end
    else
      ShowCoverBytes(nil);
  finally
    FUpdating := False;
  end;
end;

{ an edit of the user goes into every selected file (Aulumic's EditorChange) }
procedure TPropertiesForm.EditorChange(Sender: TObject);
var
  F, Field: TTagField;
  Sel: TIntegerArray;
  I: Integer;
  D: PTagEditNodeData;
  T: string;
begin
  if FUpdating or (FItems.Count = 0) then Exit;
  Field := tfTitle;
  for F := Low(TTagField) to High(TTagField) do
    if Sender = FEdits[F] then Field := F;
  { an edited field no longer stands for "multiple values" }
  Exclude(FMixed, Field);
  if Field = tfComment then T := FMemo.Text else T := FEdits[Field].Text;
  Sel := FList.SelectedRows;
  for I := 0 to High(Sel) do
  begin
    D := Item(Sel[I]);
    if (D = nil) or D^.ReadFailed then Continue;
    if (Field in [tfTitle, tfTrack]) and (Length(Sel) > 1) then Continue;
    case Field of
      tfTitle: D^.Current.Title := T;
      tfArtist: D^.Current.Artist := T;
      tfAlbumArtist: D^.Current.AlbumArtist := T;
      tfAlbum: D^.Current.Album := T;
      tfGenre: D^.Current.Genre := T;
      tfYear: D^.Current.DateStr := T;
      tfTrack: D^.Current.Track := ExtractTagNumber(T);
      tfDisc: D^.Current.Disc := ExtractTagNumber(T);
      tfComposer: D^.Current.Composer := T;
      tfPerformer: D^.Current.Performer := T;
      tfComment: D^.Current.Comment := T;
    end;
    D^.IsModified :=
      (D^.Current.Title <> D^.Original.Title) or (D^.Current.Artist <> D^.Original.Artist) or
      (D^.Current.AlbumArtist <> D^.Original.AlbumArtist) or (D^.Current.Album <> D^.Original.Album) or
      (D^.Current.Genre <> D^.Original.Genre) or (D^.Current.DateStr <> D^.Original.DateStr) or
      (D^.Current.Track <> D^.Original.Track) or (D^.Current.Composer <> D^.Original.Composer) or
      (D^.Current.Performer <> D^.Original.Performer) or (D^.Current.Comment <> D^.Original.Comment) or
      (D^.Current.Disc <> D^.Original.Disc);
  end;
  MarkRows;
end;

{ ---- the cover ---- }

procedure TPropertiesForm.ShowCoverBytes(const ABytes: TBytes);
var
  B: TGfxBitmap;
  W, H: Integer;
  Kind: string;
begin
  if Length(ABytes) = 0 then
  begin
    FShownCoverLen := 0;
    FShownCoverHash := 0;
    FCover.SetBitmap(nil, False);
    FCover.Invalidate;
    FCoverInfo.Caption := 'No cover';
    Exit;
  end;
  if (Length(ABytes) = FShownCoverLen) and (CoverHash(ABytes) = FShownCoverHash) then Exit;
  { the size from the header, the picture itself only as large as it is shown
    (a 6000 px scan at full size: 144 MB for a thumbnail-sized preview) }
  B := nil;
  if ImageSizeFromBytes(ABytes, W, H) then
  begin
    if not ImagePixelsAllowed(W, H) then
    begin
      FShownCoverLen := 0;
      FShownCoverHash := 0;
      FCover.SetBitmap(nil, False);
      FCover.Invalidate;
      FCoverInfo.Caption := Format('%d x %d: too large to show', [W, H]);
      Exit;
    end;
    B := ImageFromBytes(ABytes, COVER_PREVIEW_PX);
  end;
  if B = nil then
  begin
    FShownCoverLen := 0;
    FShownCoverHash := 0;
    FCover.SetBitmap(nil, False);
    FCover.Invalidate;
    FCoverInfo.Caption := 'The cover cannot be shown';
    Exit;
  end;
  if (Length(ABytes) >= 4) and (ABytes[0] = $89) and (ABytes[1] = $50) then Kind := 'PNG' else Kind := 'JPEG';
  FCoverInfo.Caption := Format('%d x %d  %s  %.0f KB', [W, H, Kind, Length(ABytes) / 1024]);
  FCover.SetBitmap(B, True);
  FCover.Invalidate;
  FShownCoverLen := Length(ABytes);
  FShownCoverHash := CoverHash(ABytes);
end;

{ the new cover for every selected file that can be changed }
procedure TPropertiesForm.ApplyNewCover(const ABytes: TBytes; const AMime: string);
var
  Sel: TIntegerArray;
  I: Integer;
  D: PTagEditNodeData;
begin
  Sel := FList.SelectedRows;
  if (Length(Sel) = 0) or (Length(ABytes) = 0) then Exit;
  if Length(ABytes) > MAX_COVER_BYTES then
  begin
    AuMessage(ERR_COVER_TOO_LARGE, amWarning, abOK, TITLE_COVER_TOO_LARGE);
    Exit;
  end;
  for I := 0 to High(Sel) do
  begin
    D := Item(Sel[I]);
    if (D = nil) or D^.ReadFailed then Continue;
    D^.HasCover := True;
    D^.CoverModified := True;
    D^.CoverMimeType := AMime;
    D^.CoverData := Copy(ABytes, 0, Length(ABytes));
  end;
  ShowCoverBytes(ABytes);
  MarkRows;
end;

{ a bitmap as JPEG bytes (---> AulumicNS: encoded in memory; it went through a
  temporary file while GDI+ did it) }
function TPropertiesForm.JpegFromBitmap(B: TGfxBitmap; out ABytes: TBytes): Boolean;
begin
  ABytes := BitmapToBytes(B, True);
  Result := Length(ABytes) > 0;
end;

{ Aulumic's TryLoadCoverFromFile: JPEG and PNG up to 1500 px are taken as
  they are, anything else (larger, BMP) becomes a JPEG of at most 1500 px }
function TPropertiesForm.LoadCoverFile(const AFileName: string): Boolean;
var
  FS: TFileStream;
  Bytes, NewBytes: TBytes;
  IsJpeg, IsPng: Boolean;
  B: TGfxBitmap;
  W, H: Integer;
begin
  Result := False;
  if (AFileName = '') or not FileExists(LongPath(AFileName)) or (FList.SelCount = 0) then Exit;
  try
    FS := TFileStream.Create(LongPath(AFileName), fmOpenRead or fmShareDenyNone);
    try
      if FS.Size < 4 then Exit;
      if FS.Size > MAX_COVER_BYTES then
      begin
        AuMessage(SafeFormat(FMT_ERR_COVER_FILE_TOO_LARGE, [ExtractFileName(AFileName), FS.Size / BYTES_PER_MB]),
          amWarning, abOK, TITLE_COVER_TOO_LARGE);
        Exit;
      end;
      SetLength(Bytes, FS.Size);
      FS.ReadBuffer(Bytes[0], FS.Size);
    finally
      FS.Free;
    end;
  except
    Exit;
  end;
  IsJpeg := (Bytes[0] = $FF) and (Bytes[1] = $D8) and (Bytes[2] = $FF);
  IsPng := (Bytes[0] = $89) and (Bytes[1] = $50) and (Bytes[2] = $4E) and (Bytes[3] = $47);
  { the size from the header: nothing is decoded unless the picture must be
    made smaller }
  if not ImageSizeFromBytes(Bytes, W, H) then Exit;
  if not ImagePixelsAllowed(W, H) then
  begin
    AuMessage(SafeFormat(FMT_ERR_COVER_TOO_MANY_PIXELS, [ExtractFileName(AFileName), W, H]),
      amWarning, abOK, TITLE_COVER_TOO_LARGE);
    Exit;
  end;
  B := nil;
  try
    if (W > MAX_COVER_PX) or (H > MAX_COVER_PX) or not (IsJpeg or IsPng) then
    begin
      B := ImageFromBytes(Bytes, MAX_COVER_PX);
      if not JpegFromBitmap(B, NewBytes) then Exit;
      ApplyNewCover(NewBytes, MIME_JPEG);
    end
    else if IsPng then ApplyNewCover(Bytes, MIME_PNG)
    else ApplyNewCover(Bytes, MIME_JPEG);
    Result := True;
  finally
    if B <> nil then DisposeBitmap(B);
  end;
end;

{ Ctrl+V: a copied picture (as a bitmap, saved and read back as a picture file) }
function TPropertiesForm.PasteCover: Boolean;
var
  Bmp: Graphics.TBitmap;
  Tmp: string;
begin
  Result := False;
  if FList.SelCount = 0 then Exit;
  try
    if Clipboard.HasFormat(CF_BITMAP) then
    begin
      Tmp := GetTempDir(False) + Format('AulumicNS_paste_%d.bmp', [GetCurrentProcessId]);
      Bmp := Graphics.TBitmap.Create;
      try
        Bmp.LoadFromClipboardFormat(CF_BITMAP);
        Bmp.SaveToFile(Tmp);
      finally
        Bmp.Free;
      end;
      try
        Result := LoadCoverFile(Tmp);
      finally
        SysUtils.DeleteFile(LongPath(Tmp));
      end;
    end;
  except
    Result := False;
  end;
end;

procedure TPropertiesForm.LoadClick(Sender: TObject);
var
  D: TOpenDialog;
  Sel: TIntegerArray;
begin
  Sel := FList.SelectedRows;
  if Length(Sel) = 0 then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Title := DLG_SELECT_COVER_ART_TITLE;
    D.Filter := DLG_FILTER_COVER_ART;
    D.InitialDir := ExtractFileDir(Item(Sel[0])^.FilePath);
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then LoadCoverFile(D.FileName);
  finally
    D.Free;
  end;
end;

{ an image search for the album in the browser (Aulumic) }
procedure TPropertiesForm.WebClick(Sender: TObject);
var
  Sel: TIntegerArray;
  First: PTagEditNodeData;
  Artist, Album, Q: string;
begin
  Sel := FList.SelectedRows;
  if Length(Sel) > 0 then First := Item(Sel[0]) else First := Item(0);
  if First = nil then Exit;
  if tfAlbumArtist in FMixed then Artist := '' else Artist := Trim(FEdits[tfAlbumArtist].Text);
  if (Artist = '') and not (tfArtist in FMixed) then Artist := Trim(FEdits[tfArtist].Text);
  if Artist = '' then
  begin
    Artist := Trim(First^.Current.AlbumArtist);
    if Artist = '' then Artist := Trim(First^.Current.Artist);
  end;
  Artist := FirstArtistOf(Artist);
  if SameText(Artist, LBL_UNKNOWN_ARTIST) then Artist := '';
  if tfAlbum in FMixed then Album := '' else Album := Trim(FEdits[tfAlbum].Text);
  if Album = '' then
  begin
    Album := Trim(First^.Current.Album);
    if Album = '' then Album := Trim(First^.Current.Title);
  end;
  if (Artist <> '') and (Album <> '') then Q := Artist + ' ' + Album + ' cover'
  else if Album <> '' then Q := Album + ' cover'
  else if Artist <> '' then Q := Artist + ' cover'
  else Exit;
  OpenURL('https://www.google.com/search?tbm=isch&q=' + URLEncode(Q));
end;

procedure TPropertiesForm.ClearClick(Sender: TObject);
var
  Sel: TIntegerArray;
  I: Integer;
  D: PTagEditNodeData;
begin
  Sel := FList.SelectedRows;
  if Length(Sel) = 0 then Exit;
  for I := 0 to High(Sel) do
  begin
    D := Item(Sel[I]);
    if (D = nil) or D^.ReadFailed then Continue;
    D^.HasCover := False;
    D^.CoverModified := True;
    D^.CoverMimeType := '';
    D^.CoverData := nil;
  end;
  ShowCoverBytes(nil);
  MarkRows;
end;

procedure TPropertiesForm.FormDrop(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
  Ext: string;
begin
  if FCommitting or (FList.SelCount = 0) then Exit;
  for I := 0 to High(FileNames) do
  begin
    Ext := LowerCase(ExtractFileExt(FileNames[I]));
    if ((Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.png') or (Ext = '.bmp')) and LoadCoverFile(FileNames[I]) then
      Break;
  end;
end;

procedure TPropertiesForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = Ord('V')) and (Shift = [ssCtrl]) and not (ActiveControl is TAuEdit) then
  begin
    if (not FCommitting) and PasteCover then
    begin
      Key := 0;
      Exit;
    end;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TPropertiesForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := not FCommitting;
end;

{ ---- the inspector ---- }

procedure TPropertiesForm.RefreshInspector;
var
  Sel: TIntegerArray;
begin
  Sel := FList.SelectedRows;
  if Length(Sel) = 1 then InspectorSingle(Item(Sel[0]))
  else if Length(Sel) > 1 then InspectorMulti;
end;

procedure TPropertiesForm.InspectorSingle(D: PTagEditNodeData);
var
  Meta: TAudioMetadata;
  St: PUserTrackStats;
  Lib: TTrackInfo;
  InLib, NeedCover: Boolean;
  SR: TSearchRec;
  S, Art, FP: string;
begin
  if D = nil then Exit;
  NeedCover := D^.HasCover and (Length(D^.CoverData) = 0);
  Meta := ReadTrackMetadata(D^.FilePath, NeedCover, True);
  if NeedCover and (Length(Meta.CoverData) > 0) then
  begin
    D^.CoverData := Meta.CoverData;
    Meta.CoverData := nil;
  end;
  S := INS_HDR_AUDIO_CHAR + sLineBreak;
  S := S + INS_LBL_FORMAT + UpperCase(StringReplace(ExtractFileExt(D^.FilePath), '.', '', [rfReplaceAll])) + sLineBreak;
  if Meta.SampleRate > 0 then S := S + INS_LBL_SAMPLE_RATE + SafeFormat(FMT_INS_SAMPLE_RATE, [Meta.SampleRate]) + sLineBreak;
  if Meta.BitDepth > 0 then S := S + INS_LBL_BIT_DEPTH + SafeFormat(FMT_INS_BIT_DEPTH, [Meta.BitDepth]) + sLineBreak;
  S := S + INS_LBL_DURATION + Meta.DurationStr + sLineBreak + sLineBreak;
  S := S + INS_HDR_FILE_INFO + sLineBreak;
  InLib := (FLibrary <> nil) and FLibrary.TryGetTrack(D^.FilePath, Lib);
  if InLib and (Lib.FileSize > 0) then
    S := S + INS_LBL_FILE_SIZE + SafeFormat(FMT_SIZE_MB, [Lib.FileSize / BYTES_PER_MB]) + sLineBreak
  else if FindFirst(LongPath(D^.FilePath), faAnyFile, SR) = 0 then
  begin
    try
      S := S + INS_LBL_FILE_SIZE + SafeFormat(FMT_SIZE_MB, [SR.Size / BYTES_PER_MB]) + sLineBreak;
    finally
      SysUtils.FindClose(SR);
    end;
  end;
  S := S + INS_LBL_FOLDER_PATH + ExtractFileDir(D^.FilePath) + sLineBreak;
  S := S + INS_LBL_FILE_NAME + ExtractFileName(D^.FilePath) + sLineBreak;
  if InLib and (Lib.DateAdded > 0) then
    S := S + INS_LBL_DATE_ADDED + DateTimeToStr(UnixToDateTime(Lib.DateAdded, False)) + sLineBreak;
  S := S + sLineBreak;
  if UserStatsManager <> nil then
  begin
    S := S + INS_HDR_USER_STATS + sLineBreak;
    Art := Trim(D^.Current.AlbumArtist);
    if Art = '' then Art := Trim(D^.Current.Artist);
    FP := UserStatsManager.GenerateFingerprint(Art, D^.Current.Album, D^.Current.Title);
    St := UserStatsManager.PeekStats(FP);
    if (St = nil) and (Trim(D^.Current.Artist) <> '') and not SameText(Art, Trim(D^.Current.Artist)) then
      St := UserStatsManager.PeekStats(UserStatsManager.GenerateFingerprint(D^.Current.Artist, D^.Current.Album,
        D^.Current.Title));
    if (St = nil) and InLib then
    begin
      St := UserStatsManager.PeekStats(Lib.PrimaryFingerprint);
      if (St = nil) and (Lib.FallbackFingerprint <> '') then St := UserStatsManager.PeekStats(Lib.FallbackFingerprint);
    end;
    if St <> nil then
    begin
      S := S + INS_LBL_PLAY_COUNT + IntToStr(St^.PlayCount) + sLineBreak;
      if St^.LastPlayed > 0 then
        S := S + INS_LBL_LAST_PLAYED + DateTimeToStr(UnixToDateTime(St^.LastPlayed, False)) + sLineBreak
      else
        S := S + INS_LBL_LAST_PLAYED + LBL_NEVER + sLineBreak;
      S := S + INS_LBL_RATING + SafeFormat(FMT_INS_RATING, [St^.Rating]) + sLineBreak;
    end
    else
      S := S + INS_LBL_PLAY_COUNT + '0' + sLineBreak + INS_LBL_LAST_PLAYED + LBL_NEVER + sLineBreak +
        INS_LBL_RATING + SafeFormat(FMT_INS_RATING, [0]) + sLineBreak;
  end;
  S := S + sLineBreak + INS_HDR_RAW_META + sLineBreak;
  if Meta.AllTagsDisplay <> '' then S := S + Meta.AllTagsDisplay else S := S + Meta.AllTags;
  FInsMemo.Text := TrimRight(S);
  FInsTitle.Caption := Trim(LBL_INSPECTOR_FILE_PREFIX) + ' ' + ExtractFileName(D^.FilePath);
end;

procedure TPropertiesForm.InspectorMulti;
var
  Sel: TIntegerArray;
  I: Integer;
  Total: Int64;
  Lib: TTrackInfo;
  D: PTagEditNodeData;
begin
  Sel := FList.SelectedRows;
  Total := 0;
  for I := 0 to High(Sel) do
  begin
    D := Item(Sel[I]);
    if (D <> nil) and (FLibrary <> nil) and FLibrary.TryGetTrack(D^.FilePath, Lib) then Inc(Total, Lib.FileSize);
  end;
  FInsMemo.Text := INS_LBL_TRACKS_SELECTED + IntToStr(Length(Sel)) + LineEnding +
    INS_LBL_TOTAL_FILE_SIZE + SafeFormat(FMT_SIZE_MB, [Total / BYTES_PER_MB]);
  FInsTitle.Caption := LBL_INSPECTOR_MULTI_SELECTION;
end;

{ ---- saving (Aulumic's pnlBtnSaveAllClick) ---- }

procedure TPropertiesForm.InvalidateThumb(const Artist, AlbumArtist, Album, FolderPath: string);
var
  EffArtist, EffAlbumArtist, EffAlbum, Target: string;
begin
  if AppCacheThumbsDir = '' then Exit;
  if AppStateManager <> nil then AppStateManager.ClearThumbCache;
  EffArtist := NormalizeSemicolons(Trim(Artist));
  if EffArtist = '' then EffArtist := LBL_UNKNOWN_ARTIST;
  EffAlbumArtist := NormalizeSemicolons(Trim(AlbumArtist));
  if EffAlbumArtist = '' then EffAlbumArtist := EffArtist;
  EffAlbum := Trim(Album);
  if EffAlbum = '' then EffAlbum := LBL_UNKNOWN_ALBUM;
  Target := AppCacheThumbsDir + GenerateAlbumHash(EffAlbumArtist, EffAlbum, FolderPath) + '.jpg';
  if FileExists(LongPath(Target)) then SysUtils.DeleteFile(LongPath(Target));
end;

procedure TPropertiesForm.SaveClick(Sender: TObject);
var
  J, Skipped: Integer;
  D: PTagEditNodeData;
  Job: PMetadataJob;
  Batch: TList;
  Folder: string;
  AlbumChanged: Boolean;
begin
  if FCommitting then Exit;
  FCommitting := True;
  FBtnSave.Enabled := False;
  FBtnCancel.Enabled := False;
  Skipped := 0;
  Batch := TList.Create;
  try
    for J := 0 to FItems.Count - 1 do
    begin
      D := Item(J);
      if D = nil then Continue;
      if D^.ReadFailed then
      begin
        Inc(Skipped);
        Continue;
      end;
      if not (D^.IsModified or D^.CoverModified) then Continue;
      AlbumChanged := (D^.Current.Album <> D^.Original.Album) or
        (D^.Current.AlbumArtist <> D^.Original.AlbumArtist) or (D^.Current.Artist <> D^.Original.Artist);
      if D^.CoverModified or AlbumChanged then
      begin
        Folder := ExtractFileDir(D^.FilePath);
        InvalidateThumb(D^.Original.Artist, D^.Original.AlbumArtist, D^.Original.Album, Folder);
        if AlbumChanged then InvalidateThumb(D^.Current.Artist, D^.Current.AlbumArtist, D^.Current.Album, Folder);
      end;
      New(Job);
      Job^ := Default(TMetadataJob);
      Job^.FilePath := D^.FilePath;
      Job^.AlbumName := D^.Current.Album;
      Job^.ActionType := matTagEditor;
      Job^.TagEditor.Current := D^.Current;
      Job^.TagEditor.Original := D^.Original;
      Job^.TagEditor.IsModified := D^.IsModified;
      Job^.TagEditor.CoverModified := D^.CoverModified;
      Job^.TagEditor.HasCover := D^.HasCover;
      if D^.CoverModified and D^.HasCover then
      begin
        Job^.TagEditor.CoverData := D^.CoverData;
        D^.CoverData := nil;            // the job owns the buffer now
        Job^.TagEditor.CoverMimeType := D^.CoverMimeType;
      end;
      Batch.Add(Job);
    end;
    if Skipped > 0 then AddLog(SafeFormat(FMT_LOG_TAGEDIT_SKIPPED, [Skipped]), False, True);
    if Batch.Count > 0 then
    begin
      if AppStateManager <> nil then AppStateManager.EnqueueMetadataBatch(Batch)
      else
        for J := 0 to Batch.Count - 1 do Dispose(PMetadataJob(Batch[J]));
    end;
  finally
    Batch.Free;
    FCommitting := False;
  end;
  ModalResult := mrOK;
end;

end.
