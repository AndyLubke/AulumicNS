unit AuCoverViewer;

{ ==============================================================================
  AulumicNS - AuCoverViewer
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The cover viewer (a click on the cover or the album in the banner): the playing album's cover as large as
  the window allows, and every other image of the album folder (back cover,
  scans) to step through - click / right click, the mouse wheel, the arrow
  keys, Page Up / Down, Home / End. The footer shows the format and which
  image it is. The embedded cover comes first unless the folder has its own
  front cover. One window; it follows the next album when
  it is opened again.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuForms, ALMetadata;

procedure ShowCoverViewer(AOwner: TComponent; const AMeta: TAudioMetadata; const AFilePath: string);
procedure CloseCoverViewer;
{ the open viewer (nil: none) }
function CurrentCoverViewer: TAuForm;
{ the window, not shown (screenshot mode) }
function CreateCoverViewer(AOwner: TComponent; const AMeta: TAudioMetadata; const AFilePath: string): TAuForm;

implementation

uses
  AuAudioTypes, uMetaUtils, uAppConsts, uAppStrings, uOSUtils, uAudioUtils, uSettingsManager;

const
  TOKEN_EMBEDDED = '<EMBEDDED>';

type
  { TCoverView: the image, fitted and centred }

  TCoverView = class(TAuControl)
  public
    Bitmap: TGfxBitmap;
  protected
    procedure DoPaint(G: TGfx); override;
  end;

  { TCoverViewerForm }

  TCoverViewerForm = class(TAuForm)
  private
    FAlbum, FArtist, FInfo: TAuLabel;
    FView: TCoverView;
    FPrev, FNext: TAuIconButton;
    FPaths: TStringList;
    FIndex: Integer;
    FCover: TBytes;
    FBaseInfo: string;
    procedure Layout;
    procedure ShowImage(AIndex: Integer);
    procedure FreeBitmap;
    procedure PrevClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure ViewDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
  protected
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateViewer(AOwner: TComponent);
    destructor Destroy; override;
    procedure LoadAlbum(const AMeta: TAudioMetadata; const AFilePath: string);
  end;

var
  GViewer: TCoverViewerForm = nil;

procedure ShowCoverViewer(AOwner: TComponent; const AMeta: TAudioMetadata; const AFilePath: string);
begin
  if GViewer = nil then GViewer := TCoverViewerForm.CreateViewer(AOwner);
  GViewer.LoadAlbum(AMeta, AFilePath);
  GViewer.Show;
  if GViewer.WindowState = wsMinimized then GViewer.WindowState := wsNormal;
  GViewer.BringToFront;
end;

procedure CloseCoverViewer;
begin
  FreeAndNil(GViewer);
end;

function CurrentCoverViewer: TAuForm;
begin
  Result := GViewer;
end;

function CreateCoverViewer(AOwner: TComponent; const AMeta: TAudioMetadata; const AFilePath: string): TAuForm;
var
  F: TCoverViewerForm;
begin
  F := TCoverViewerForm.CreateViewer(AOwner);
  F.LoadAlbum(AMeta, AFilePath);
  Result := F;
end;

{ ---- TCoverView ---- }

procedure TCoverView.DoPaint(G: TGfx);
var
  BW, BH: Integer;
  K, W, H: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if (Bitmap = nil) or not BitmapSize(Bitmap, BW, BH) or (BW <= 0) or (BH <= 0) then
  begin
    G.FillRound(Width / 2 - S(60), Height / 2 - S(60), S(120), S(120), S(12), Blend(EffBack, clText, 0.06));
    DrawIcon(G, icImage, Width / 2, Height / 2, S(48), clTextFaint);
    Exit;
  end;
  K := Math.Min(Width / BW, Height / BH);
  W := BW * K;
  H := BH * K;
  G.DrawBitmap(Bitmap, (Width - W) / 2, (Height - H) / 2, W, H);
end;

{ ---- TCoverViewerForm ---- }

constructor TCoverViewerForm.CreateViewer(AOwner: TComponent);
var
  W, H: Integer;
begin
  { 900 x 940 at first, then the size it had }
  ToolWindowSize(AppSettings.Data.CoverWinW, AppSettings.Data.CoverWinH, 900, 940, W, H);
  CreateAu(AOwner, 'Cover Art', W, H);
  DropIn := VIEWER_DROP_PX;                // comes down from above as it opens
  HelpKeyword := 'Cover Art Viewer';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Constraints.MinWidth := S(360);
  Constraints.MinHeight := S(400);
  FitToWorkArea;
  FPaths := TStringList.Create;
  FAlbum := AddLabel(Self, '', 20, 10, 600, False);
  FAlbum.FontSize := 16;
  FAlbum.Bold := True;
  FArtist := AddLabel(Self, '', 20, 40, 600);
  FView := TCoverView.Create(Self);
  FView.Parent := Body;
  FView.OnMouseDown := @ViewDown;
  FView.FocusOnClick := False;
  FPrev := TAuIconButton.Create(Self);
  FPrev.Parent := Body;
  FPrev.Icon := icChevronLeft;
  FPrev.Hint := HINT_COVER_PREV;
  FPrev.ShowHint := True;
  FPrev.OnClick := @PrevClick;
  FNext := TAuIconButton.Create(Self);
  FNext.Parent := Body;
  FNext.Icon := icChevronRight;
  FNext.Hint := HINT_COVER_NEXT;
  FNext.ShowHint := True;
  FNext.OnClick := @NextClick;
  FInfo := AddLabel(Self, '', 20, 0, 600);
  FInfo.FontSize := 12;
  FInfo.HAlign := 1;
  Layout;
end;

destructor TCoverViewerForm.Destroy;
begin
  FreeBitmap;
  FPaths.Free;
  if GViewer = Self then GViewer := nil;
  inherited Destroy;
end;

procedure TCoverViewerForm.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  CloseAction := caFree;
end;

procedure TCoverViewerForm.FreeBitmap;
begin
  if FView.Bitmap <> nil then DisposeBitmap(FView.Bitmap);
  FView.Bitmap := nil;
end;

procedure TCoverViewerForm.Layout;
var
  W, H, BW: Integer;
begin
  if FInfo = nil then Exit;
  W := ClientWidth;
  H := BodyHeight;
  BW := S(44);
  FAlbum.SetBounds(S(20), S(8), W - S(40), S(30));
  FArtist.SetBounds(S(20), S(38), W - S(40), S(22));
  FView.SetBounds(S(20) + BW, S(70), W - 2 * (S(20) + BW), H - S(70) - S(46));
  FPrev.SetBounds(S(16), FView.Top + FView.Height div 2 - S(24), BW - S(4), S(48));
  FNext.SetBounds(W - S(16) - BW + S(4), FPrev.Top, BW - S(4), S(48));
  FInfo.SetBounds(S(20), H - S(38), W - S(40), S(28));
end;

procedure TCoverViewerForm.Resize;
begin
  inherited Resize;
  Layout;
  { the size for the next time (not a maximized one) }
  if Showing and (WindowState = wsNormal) then
    SizeToRemember(AppSettings.Data.CoverWinW, AppSettings.Data.CoverWinH);
end;

procedure TCoverViewerForm.LoadAlbum(const AMeta: TAudioMetadata; const AFilePath: string);
var
  First: string;
  HasFront: Boolean;
begin
  FreeBitmap;
  FPaths.Clear;
  FIndex := 0;
  FCover := nil;
  if AMeta.Album <> '' then FAlbum.Caption := AMeta.Album else FAlbum.Caption := LBL_UNKNOWN_ALBUM;
  if AMeta.AlbumArtist <> '' then FArtist.Caption := AMeta.AlbumArtist else FArtist.Caption := AMeta.Artist;
  if (AMeta.BitDepth = 1) and (AMeta.SampleRate >= DSD64_SAMPLE_RATE) then
    FBaseInfo := SafeFormat(FMT_COVER_INFO_DSD, [DsdMultiple(AMeta.SampleRate), AMeta.SampleRate / 1000000.0,
      AMeta.DurationStr])
  else if AMeta.SampleRate > 0 then
    FBaseInfo := SafeFormat(FMT_COVER_INFO_PCM, [AMeta.BitDepth, AMeta.SampleRate / 1000.0, AMeta.DurationStr])
  else
    FBaseInfo := '';
  Screen.Cursor := crHourGlass;
  try
    if AFilePath <> '' then FindAllCoverArt(AFilePath, FPaths);
    if AMeta.HasCover and (Length(AMeta.CoverData) > 0) then
    begin
      FCover := Copy(AMeta.CoverData, 0, Length(AMeta.CoverData));
      { the embedded cover first, unless the folder has its own front cover }
      if FPaths.Count = 0 then FPaths.Add(TOKEN_EMBEDDED)
      else
      begin
        First := LowerCase(ExtractFileName(FPaths[0]));
        HasFront := (Pos('front', First) = 1) or (Pos('cover', First) = 1) or (Pos('folder', First) = 1);
        if not HasFront then FPaths.Insert(0, TOKEN_EMBEDDED);
      end;
    end
    else if (FPaths.Count = 0) and AMeta.FolderInfoValid and (Length(AMeta.FolderCoverData) > 0) then
    begin
      FCover := Copy(AMeta.FolderCoverData, 0, Length(AMeta.FolderCoverData));
      FPaths.Add(TOKEN_EMBEDDED);
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  ShowImage(0);
end;

procedure TCoverViewerForm.ShowImage(AIndex: Integer);
var
  P, PageName: string;
  Many, TooLarge: Boolean;
  PW, PH: Integer;
begin
  FreeBitmap;
  TooLarge := False;
  PW := 0;
  PH := 0;
  Many := FPaths.Count > 1;
  FPrev.Visible := Many;
  FNext.Visible := Many;
  if Many then FView.Cursor := crHandPoint else FView.Cursor := crDefault;
  if FPaths.Count = 0 then
  begin
    FInfo.Caption := FBaseInfo;
    FView.Invalidate;
    Exit;
  end;
  if AIndex < 0 then AIndex := FPaths.Count - 1
  else if AIndex >= FPaths.Count then AIndex := 0;
  FIndex := AIndex;
  P := FPaths[FIndex];
  Screen.Cursor := crHourGlass;
  try
    if P = TOKEN_EMBEDDED then FView.Bitmap := ImageFromBytes(FCover, 2400)
    else if FileExists(LongPath(P)) then FView.Bitmap := ImageFromFile(P, 2400);
    { not shown because it is too large? Then say so. }
    TooLarge := False;
    if FView.Bitmap = nil then
    begin
      if P = TOKEN_EMBEDDED then TooLarge := ImageSizeFromBytes(FCover, PW, PH)
      else TooLarge := ImageSizeFromFile(P, PW, PH);
      TooLarge := TooLarge and not ImagePixelsAllowed(PW, PH);
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  if TooLarge then
    FInfo.Caption := SafeFormat(FMT_COVER_TOO_MANY_PIXELS, [PW, PH])
  else if Many then
  begin
    if P = TOKEN_EMBEDDED then PageName := LBL_EMBEDDED_ART else PageName := ExtractFileName(P);
    FInfo.Caption := SafeFormat(FMT_COVER_PAGE_INFO, [FBaseInfo, FIndex + 1, FPaths.Count, PageName]);
  end
  else
    FInfo.Caption := FBaseInfo;
  FView.Invalidate;
end;

procedure TCoverViewerForm.PrevClick(Sender: TObject);
begin
  ShowImage(FIndex - 1);
end;

procedure TCoverViewerForm.NextClick(Sender: TObject);
begin
  ShowImage(FIndex + 1);
end;

procedure TCoverViewerForm.ViewDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if FPaths.Count <= 1 then Exit;
  if Button = mbLeft then ShowImage(FIndex + 1)
  else if Button = mbRight then ShowImage(FIndex - 1);
end;

function TCoverViewerForm.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := FPaths.Count > 1;
  if not Result then Exit;
  if WheelDelta < 0 then ShowImage(FIndex + 1) else ShowImage(FIndex - 1);
end;

procedure TCoverViewerForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (FPaths.Count > 1) and (Shift * [ssCtrl, ssAlt, ssShift] = []) then
    case Key of
      VK_LEFT, VK_UP, VK_PRIOR: begin Key := 0; ShowImage(FIndex - 1); Exit; end;
      VK_RIGHT, VK_DOWN, VK_NEXT: begin Key := 0; ShowImage(FIndex + 1); Exit; end;
      VK_HOME: begin Key := 0; ShowImage(0); Exit; end;
      VK_END: begin Key := 0; ShowImage(FPaths.Count - 1); Exit; end;
    end;
  inherited KeyDown(Key, Shift);
end;

end.
