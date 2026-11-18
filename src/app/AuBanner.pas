unit AuBanner;

{ The "Now Playing" banner at the top of the main window (Aulumic layout):
    cover  Title                               FLAC        |peak |
           Album (link)                        24 bit/96   |meter|
           Genre                               Stereo      |     |
           Artist • Performer • Composer (...)  Rate (link) |     |
           Track 1 of 8 • 4:33 / 47:17  [badge] [book] [heart]
  ---> AulumicNS: the main menu and Preferences buttons are in the title bar
  (TAuTitleBar.AddButton); the sun / moon theme button was removed (2026-11-11).
  Everything is painted by this one control (clickable parts are hot
  spots), so the banner never flickers; only the peak meter is an own
  child control (it repaints up to 25 times a second).
  When the banner is made lower (the splitter below it) the fonts shrink
  and the rows disappear one by one, like in Aulumic. The background is a
  vertical gradient tinted with the main colour of the cover. }

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls, AuExtra, AuAppIcon;

type
  TBannerHot = (bhNone, bhCover, bhAlbum, bhArtist, bhMoreArtists,
    bhRate, bhBadge, bhBooklet, bhHeart);
  TBannerBadge = (bbNone, bbBitPerfect, bbProcessed);
  TBannerPointEvent = procedure(Sender: TObject; ScreenPt: TPoint) of object;
  TBannerArtistEvent = procedure(Sender: TObject; const AName: string) of object;

  { TNowPlayingBanner }

  TNowPlayingBanner = class(TAuControl)
  private
    FMeter: TAuPeakMeter;
    FCover: TGfxBitmap;
    FAmbient: TARGB;
    FPlaying: Boolean;
    FTitle, FAlbum, FGenre, FMeta: string;
    FArtists: TStringList;
    FCodec, FResolution, FChannels, FRate, FNotice: string;
    FBadge: TBannerBadge;
    FBadgeText: string;
    FFavorite, FHasBooklet, FShowMeter: Boolean;
    FHot: TBannerHot;
    FHotArtist: Integer;
    FDown: TBannerHot;
    { layout, computed by Layout }
    FRects: array[TBannerHot] of TRect;
    FArtistRects: array of TRect;
    FShownArtists: Integer;
    FOnRate, FOnBadge, FOnMoreArtists: TBannerPointEvent;
    FOnCover, FOnAlbum, FOnHeart, FOnBooklet: TNotifyEvent;
    FOnArtist: TBannerArtistEvent;
    procedure MeterBack(Sender: TObject; G: TGfx);
    procedure PaintBackground(G: TGfx; OffX, OffY, W, H: Single);
    function Ratio: Single;
    function InfoColumnW(R: Single; InfoR, TextL: Integer): Integer;
    function MinH: Integer;
    function MaxH: Integer;
    procedure Layout;
    function HotAt(X, Y: Integer; out ArtistIdx: Integer): TBannerHot;
    procedure SetShowMeter(V: Boolean);
    function GradTop: TARGB;
    function GradBottom: TARGB;
    function FontPx(Pt: Single): Single;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DpiChanged; override;
    { the cover (the banner keeps its own copy; nil = the logo) }
    procedure SetCover(B: TGfxBitmap);
    procedure SetArtists(const Names: array of string);
    function OverflowArtists: TStringArray;
    procedure Clear;
    procedure Changed;
    { the colour at the top of the banner gradient (the title bar above it) }
    function TopColor: TARGB;
    property Meter: TAuPeakMeter read FMeter;
    property Playing: Boolean read FPlaying write FPlaying;
    property Title: string read FTitle write FTitle;
    property Album: string read FAlbum write FAlbum;
    property Genre: string read FGenre write FGenre;
    property Meta: string read FMeta write FMeta;
    property Codec: string read FCodec write FCodec;
    property Resolution: string read FResolution write FResolution;
    property Channels: string read FChannels write FChannels;
    property RateText: string read FRate write FRate;
    { "Opening..." / "Waiting for drive...": shown in place of the codec }
    property Notice: string read FNotice write FNotice;
    property Badge: TBannerBadge read FBadge write FBadge;
    property BadgeText: string read FBadgeText write FBadgeText;
    property Favorite: Boolean read FFavorite write FFavorite;
    property HasBooklet: Boolean read FHasBooklet write FHasBooklet;
    property AmbientColor: TARGB read FAmbient write FAmbient;
    property ShowMeter: Boolean read FShowMeter write SetShowMeter;
    property OnCover: TNotifyEvent read FOnCover write FOnCover;
    property OnAlbum: TNotifyEvent read FOnAlbum write FOnAlbum;
    property OnArtist: TBannerArtistEvent read FOnArtist write FOnArtist;
    property OnMoreArtists: TBannerPointEvent read FOnMoreArtists write FOnMoreArtists;
    property OnRate: TBannerPointEvent read FOnRate write FOnRate;
    property OnBadge: TBannerPointEvent read FOnBadge write FOnBadge;
    property OnHeart: TNotifyEvent read FOnHeart write FOnHeart;
    property OnBooklet: TNotifyEvent read FOnBooklet write FOnBooklet;
  end;

const
  BannerDefaultHeight = 200;    // unscaled, like Aulumic
  BannerMinHeight = 60;
  BannerMaxHeight = 400;

{ the main colour of a cover for the tint of the banner (Aulumic's ambient
  colour): the average of about 48 x 48 sampled pixels, colourful pixels
  weighted more than grey, near black or near white ones; 0 = none }
function CoverAmbientColor(B: TGfxBitmap): TARGB;

implementation

function CoverAmbientColor(B: TGfxBitmap): TARGB;
var
  W, H: Integer;
  X, Y, StepX, StepY, Cr, Cg, Cb, Mx, Mn: Integer;
  P: PCardinal;
  C: Cardinal;
  Wt, SW, SR, SG, SB: Double;
begin
  Result := 0;
  if not BitmapSize(B, W, H) then Exit;
  SW := 0;
  SR := 0;
  SG := 0;
  SB := 0;
  begin
    StepX := Max(1, Integer(W) div 48);
    StepY := Max(1, Integer(H) div 48);
    Y := 0;
    while Y < Integer(H) do
    begin
      P := PCardinal(B.Row(Y));      // (a cover has no transparency)
      X := 0;
      while X < Integer(W) do
      begin
        C := P[X];
        Cr := (C shr 16) and $FF;
        Cg := (C shr 8) and $FF;
        Cb := C and $FF;
        Mx := Max(Cr, Max(Cg, Cb));
        Mn := Min(Cr, Min(Cg, Cb));
        Wt := 0.05 + (Mx - Mn) / 255;
        if (Mx < 30) or (Mn > 235) then Wt := Wt * 0.2;
        SW := SW + Wt;
        SR := SR + Wt * Cr;
        SG := SG + Wt * Cg;
        SB := SB + Wt * Cb;
        Inc(X, StepX);
      end;
      Inc(Y, StepY);
    end;
  end;
  if SW <= 0 then Exit;
  Result := TARGB($FF000000 or (Cardinal(Round(SR / SW)) shl 16) or
    (Cardinal(Round(SG / SW)) shl 8) or Cardinal(Round(SB / SW)));
end;

const
  EdgeW = 20;         // ---> AulumicNS: margin left / right (was an icon column of 30 + 10)
  InfoW = 180;        // the source information column (at least; wider when its text needs it)
  TextMinW = 160;     // ---> AulumicNS: what the title column keeps at the least
  MeterW = 22;        // ---> AulumicNS (test list 2): narrower bars (was 32)

constructor TNowPlayingBanner.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FocusOnClick := False;
  FArtists := TStringList.Create;
  FShowMeter := True;
  FHot := bhNone;
  FDown := bhNone;
  FHotArtist := -1;
  Height := S(BannerDefaultHeight);
  FMeter := TAuPeakMeter.Create(Self);
  FMeter.Parent := Self;
  FMeter.OnPaintBack := @MeterBack;
  Clear;
end;

destructor TNowPlayingBanner.Destroy;
begin
  if FCover <> nil then DisposeBitmap(FCover);
  FArtists.Free;
  inherited Destroy;
end;

procedure TNowPlayingBanner.Clear;
begin
  FPlaying := False;
  FTitle := 'Aulumic';
  FAlbum := '';
  FGenre := '';
  FMeta := '';
  FArtists.Clear;
  FCodec := '';
  FResolution := '';
  FChannels := '';
  FRate := '';
  FNotice := '';
  FBadge := bbNone;
  FBadgeText := '';
  FFavorite := False;
  FHasBooklet := False;
  FAmbient := 0;
  SetCover(nil);
  FMeter.Active := False;
  Changed;
end;

procedure TNowPlayingBanner.SetCover(B: TGfxBitmap);
begin
  if FCover <> nil then DisposeBitmap(FCover);
  FCover := nil;
  if B <> nil then FCover := CloneBitmap(B);
  Invalidate;
end;

procedure TNowPlayingBanner.SetArtists(const Names: array of string);
var
  I, J: Integer;
  N: string;
  Dup: Boolean;
begin
  FArtists.Clear;
  for I := 0 to High(Names) do
  begin
    N := Trim(Names[I]);
    if N = '' then Continue;
    { skip names already shown (also as a part of another name) }
    Dup := False;
    for J := 0 to FArtists.Count - 1 do
      if SameText(FArtists[J], N) or (Pos(LowerCase(N), LowerCase(FArtists[J])) > 0) or
         (Pos(LowerCase(FArtists[J]), LowerCase(N)) > 0) then
      begin
        Dup := True;
        Break;
      end;
    if not Dup then FArtists.Add(N);
  end;
end;

function TNowPlayingBanner.OverflowArtists: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  for I := FShownArtists to FArtists.Count - 1 do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := FArtists[I];
  end;
end;

procedure TNowPlayingBanner.Changed;
begin
  Layout;
  Invalidate;
end;

procedure TNowPlayingBanner.SetShowMeter(V: Boolean);
begin
  if V = FShowMeter then Exit;
  FShowMeter := V;
  Changed;
end;

procedure TNowPlayingBanner.DpiChanged;
begin
  Layout;
  inherited DpiChanged;
end;

procedure TNowPlayingBanner.Resize;
begin
  inherited Resize;
  Layout;
end;

function TNowPlayingBanner.MinH: Integer;
begin
  Result := S(BannerMinHeight);
end;

function TNowPlayingBanner.MaxH: Integer;
begin
  Result := S(BannerDefaultHeight);
end;

{ 0 at the smallest height, 1 at the default height and above }
function TNowPlayingBanner.Ratio: Single;
begin
  if Height <= MinH then Result := 0
  else if Height >= MaxH then Result := 1
  else Result := (Height - MinH) / (MaxH - MinH);
end;

function TNowPlayingBanner.FontPx(Pt: Single): Single;
begin
  { Aulumic's sizes are in points; the GUI fonts are in pixels at 96 dpi }
  Result := Pt * 4 / 3;
end;

function TNowPlayingBanner.GradTop: TARGB;
begin
  if FAmbient <> 0 then Result := Blend(clSurface, FAmbient, 0.30)
  else Result := Blend(clSurface, clAccent, 0.06);
end;

function TNowPlayingBanner.TopColor: TARGB;
begin
  Result := GradTop;
end;

function TNowPlayingBanner.GradBottom: TARGB;
begin
  Result := clPanel;
end;

procedure TNowPlayingBanner.PaintBackground(G: TGfx; OffX, OffY, W, H: Single);
begin
  { the gradient of the whole banner, seen through a window at OffX, OffY }
  G.FillRectGrad(0, 0, W, H, 0, -OffY - 1, 0, Height - OffY + 1, GradTop, GradBottom);
end;

procedure TNowPlayingBanner.MeterBack(Sender: TObject; G: TGfx);
begin
  PaintBackground(G, FMeter.Left, FMeter.Top, FMeter.Width, FMeter.Height);
end;

{ ---> AulumicNS (test list 2): the width of the source column - InfoW, or
  what its widest row needs at the text size in use ("DSD to PCM: 705.6 kHz"
  was cut at Larger), but the title column keeps TextMinW. Layout and
  DoPaint use it alike. }
function TNowPlayingBanner.InfoColumnW(R: Single; InfoR, TextL: Integer): Integer;
var
  F, FB: TGfxFont;
  Room: Integer;

  procedure Fit(const T: string; AFont: TGfxFont);
  begin
    if T <> '' then Result := Math.Max(Result, Ceil(TextWidth(T, AFont)) + S(4));
  end;

begin
  Result := S(InfoW);
  F := UIFont(FontPx(12 - (1 - R) * 3));
  FB := UIFont(FontPx(12 - (1 - R) * 3), True);
  if FNotice <> '' then Fit(FNotice, F) else Fit(FCodec, FB);
  Fit(FResolution, F);
  Fit(FChannels, F);
  Fit(FRate, F);
  Room := InfoR - TextL - S(12) - S(TextMinW);
  if Result > Room then Result := Math.Max(S(InfoW), Room);
end;

procedure TNowPlayingBanner.Layout;
var
  R: Single;
  Step, H, TopY, BotY, CoverSz, InfoL, InfoR, TextL, TextR, X, Y, RowH, I, W, MoreW, DotW: Integer;
  F: TGfxFont;
  MeterOn: Boolean;
  H0: TBannerHot;
begin
  for H0 := Low(TBannerHot) to High(TBannerHot) do FRects[H0] := Rect(0, 0, 0, 0);
  SetLength(FArtistRects, 0);
  FShownArtists := 0;
  H := Height;
  if (Width <= 0) or (H <= 0) then Exit;
  R := Ratio;
  Step := (MaxH - MinH) div 4;
  TopY := S(20);
  BotY := H - S(10);
  { cover (---> AulumicNS: no icon column on the left any more) }
  CoverSz := Math.Max(S(24), BotY - TopY);
  X := S(EdgeW);
  FRects[bhCover] := Rect(X, TopY, X + CoverSz, TopY + CoverSz);
  { right part: peak meter and the source column }
  InfoR := Width - S(EdgeW);
  MeterOn := FShowMeter and (H >= MinH + Step div 2);
  FMeter.Visible := MeterOn;
  if MeterOn then
  begin
    FMeter.SetBounds(InfoR - S(MeterW), TopY, S(MeterW), BotY - TopY);
    InfoR := InfoR - S(MeterW) - S(20);
  end;
  TextL := FRects[bhCover].Right + S(20);
  InfoL := InfoR - InfoColumnW(R, InfoR, TextL);
  TextR := InfoL - S(12);
  { source column: codec / res / channels / rate rows, then badge, booklet, heart }
  { the same row height as DoPaint uses for the source column }
  RowH := Math.Max(S(20), Round(UIFont(FontPx(12 - (1 - R) * 3)).LineHeight * 1.45));
  Y := TopY;
  if FRate <> '' then
  begin
    { the rate row (4th) }
    if H >= MinH + Step * 3 then
    begin
      F := UIFont(FontPx(12 - (1 - R) * 3));
      W := Ceil(TextWidth(FRate, F));
      FRects[bhRate] := Rect(InfoR - W, Y + 3 * RowH, InfoR, Y + 4 * RowH);
    end;
  end;
  if FPlaying and (H >= MinH + Step div 2) then
  begin
    X := InfoR;
    FRects[bhHeart] := Rect(X - S(28), BotY - S(28), X, BotY);
    X := X - S(32);
    if FHasBooklet then
    begin
      FRects[bhBooklet] := Rect(X - S(28), BotY - S(28), X, BotY);
      X := X - S(32);
    end;
    if FBadge <> bbNone then
    begin
      F := UIFont(11.5, True);
      W := Ceil(TextWidth(FBadgeText, F)) + S(26);
      FRects[bhBadge] := Rect(X - W, BotY - S(24), X, BotY - S(4));
    end;
  end;
  { text column: title, album, genre, artists, meta }
  Y := TopY;
  F := UIFont(FontPx(16 - (1 - R) * 6), True);
  Inc(Y, Ceil(F.LineHeight) + S(10));
  if FAlbum <> '' then
  begin
    F := UIFont(FontPx(14 - (1 - R) * 4), True);
    if H >= MinH + Step then
    begin
      W := Math.Min(Ceil(TextWidth(FAlbum, F)), TextR - TextL);
      FRects[bhAlbum] := Rect(TextL, Y, TextL + W, Y + Ceil(F.LineHeight));
      Inc(Y, Ceil(F.LineHeight) + S(10));
    end;
  end
  else if H >= MinH + Step then Inc(Y, Ceil(UIFont(FontPx(14 - (1 - R) * 4), True).LineHeight) + S(10));
  if H >= MinH + Step * 2 then
    Inc(Y, Ceil(UIFont(FontPx(12 - (1 - R) * 3)).LineHeight) + S(10));
  { the artists line: as many names as fit, then "(...)" }
  if (FArtists.Count > 0) and (H >= MinH + Step * 3) then
  begin
    F := UIFont(FontPx(12));
    MoreW := Ceil(TextWidth(' (...)', F)) + S(6);
    DotW := Ceil(TextWidth(' • ', F)) + S(8);
    X := TextL;
    SetLength(FArtistRects, FArtists.Count);
    for I := 0 to FArtists.Count - 1 do
    begin
      W := Ceil(TextWidth(FArtists[I], F));
      if (I = FArtists.Count - 1) and (X + W > TextR) then Break;
      if (I < FArtists.Count - 1) and (X + W + MoreW > TextR) then Break;
      FArtistRects[I] := Rect(X, Y, X + W, Y + Ceil(F.LineHeight));
      Inc(FShownArtists);
      X := X + W + DotW;
    end;
    if (FShownArtists = 0) and (FArtists.Count > 0) then
    begin
      { at least the first, cut off }
      FArtistRects[0] := Rect(TextL, Y, Math.Max(TextL + S(20), TextR - MoreW), Y + Ceil(F.LineHeight));
      FShownArtists := 1;
      X := FArtistRects[0].Right + DotW;
    end;
    SetLength(FArtistRects, FShownArtists);
    if FShownArtists < FArtists.Count then
      FRects[bhMoreArtists] := Rect(X - DotW + S(2), Y, X - DotW + S(2) + MoreW, Y + Ceil(F.LineHeight));
  end;
end;

function TNowPlayingBanner.HotAt(X, Y: Integer; out ArtistIdx: Integer): TBannerHot;
var
  H: TBannerHot;
  I: Integer;
  P: TPoint;
begin
  ArtistIdx := -1;
  P := Point(X, Y);
  for I := 0 to High(FArtistRects) do
    if PtInRect(FArtistRects[I], P) then
    begin
      ArtistIdx := I;
      Exit(bhArtist);
    end;
  for H := Succ(bhNone) to High(TBannerHot) do
    if (H <> bhArtist) and PtInRect(FRects[H], P) then
    begin
      if (H = bhCover) and not FPlaying then Continue;
      Exit(H);
    end;
  Result := bhNone;
end;

procedure TNowPlayingBanner.DoPaint(G: TGfx);
var
  R: Single;
  Step, H, TopY, BotY, TextL, TextR, InfoL, InfoR, Y, I, RowH: Integer;
  F: TGfxFont;
  Fg, C: TARGB;
  Rc: TRect;
  T: string;
  Rows: array[0..3] of string;

  procedure HotBack(HB: TBannerHot);
  var
    RR: TRect;
  begin
    RR := FRects[HB];
    if FHot = HB then
      G.FillRound(RR.Left, RR.Top, RR.Right - RR.Left, RR.Bottom - RR.Top, S(6), WithAlpha(clText, 22));
  end;

begin
  PaintBackground(G, 0, 0, Width, Height);
  H := Height;
  R := Ratio;
  Step := (MaxH - MinH) div 4;
  TopY := S(20);
  BotY := H - S(10);
  { cover }
  Rc := FRects[bhCover];
  if FCover <> nil then
  begin
    G.FillRound(Rc.Left + S(2), Rc.Top + S(3), Rc.Right - Rc.Left, Rc.Bottom - Rc.Top, S(8), WithAlpha($FF000000, 60));
    G.DrawBitmapCover(FCover, Rc.Left, Rc.Top, Rc.Right - Rc.Left, Rc.Bottom - Rc.Top, S(8));
  end
  else
    DrawAppLogo(G, Rc.Left, Rc.Top, Rc.Right - Rc.Left, True);
  if FPlaying and (FHot = bhCover) then
    G.StrokeRound(Rc.Left, Rc.Top, Rc.Right - Rc.Left, Rc.Bottom - Rc.Top, S(8), SF(1.5), WithAlpha(clText, 120));
  { columns }
  InfoR := Width - S(EdgeW);
  if FMeter.Visible then InfoR := FMeter.Left - S(20);
  TextL := FRects[bhCover].Right + S(20);
  InfoL := InfoR - InfoColumnW(R, InfoR, TextL);
  TextR := InfoL - S(12);
  { title }
  Y := TopY;
  F := UIFont(FontPx(16 - (1 - R) * 6), True);
  G.Text(FTitle, TextL, Y, TextR - TextL, Ceil(F.LineHeight) + S(2), F, clText, 0, 0);
  Inc(Y, Ceil(F.LineHeight) + S(10));
  { album }
  if H >= MinH + Step then
  begin
    F := UIFont(FontPx(14 - (1 - R) * 4), True);
    if FAlbum <> '' then
    begin
      if FHot = bhAlbum then Fg := clAccentText else Fg := clText;
      G.Text(FAlbum, TextL, Y, TextR - TextL, Ceil(F.LineHeight) + S(2), F, Fg, 0, 0);
      if FHot = bhAlbum then
        G.FillRect(FRects[bhAlbum].Left, FRects[bhAlbum].Bottom - S(1), FRects[bhAlbum].Right - FRects[bhAlbum].Left, SF(1.2), Fg);
    end;
    Inc(Y, Ceil(F.LineHeight) + S(10));
  end;
  { genre }
  if H >= MinH + Step * 2 then
  begin
    F := UIFont(FontPx(12 - (1 - R) * 3));
    G.Text(FGenre, TextL, Y, TextR - TextL, Ceil(F.LineHeight) + S(2), F, clTextDim, 0, 0);
    Inc(Y, Ceil(F.LineHeight) + S(10));
  end;
  { artists }
  if Length(FArtistRects) > 0 then
  begin
    F := UIFont(FontPx(12));
    for I := 0 to High(FArtistRects) do
    begin
      Rc := FArtistRects[I];
      if (FHot = bhArtist) and (FHotArtist = I) then Fg := clAccentText else Fg := clText;
      G.Text(FArtists[I], Rc.Left, Rc.Top, Rc.Right - Rc.Left + S(2), Rc.Bottom - Rc.Top + S(2), F, Fg, 0, 0);
      if (FHot = bhArtist) and (FHotArtist = I) then
        G.FillRect(Rc.Left, Rc.Bottom - S(1), Math.Min(Rc.Right - Rc.Left, Ceil(TextWidth(FArtists[I], F))), SF(1.2), Fg);
      if (I < High(FArtistRects)) or (FShownArtists < FArtists.Count) then
        if I < High(FArtistRects) then
          G.Text(' • ', Rc.Right + S(2), Rc.Top, S(30), Rc.Bottom - Rc.Top + S(2), F, clTextDim, 0, 0);
    end;
    Rc := FRects[bhMoreArtists];
    if Rc.Right > Rc.Left then
    begin
      if FHot = bhMoreArtists then Fg := clAccentText else Fg := clText;
      G.Text(' (...)', Rc.Left, Rc.Top, Rc.Right - Rc.Left + S(4), Rc.Bottom - Rc.Top + S(2), F, Fg, 0, 0);
    end;
  end;
  { meta line, at the bottom of the text column }
  if (FMeta <> '') and (H >= MinH + Step div 2) then
  begin
    F := UIFont(FontPx(10 - (1 - R) * 3));
    G.Text(FMeta, TextL, BotY - Ceil(F.LineHeight) - S(2), TextR - TextL, Ceil(F.LineHeight) + S(2), F, clTextDim, 0, 0);
  end;
  { source column }
  F := UIFont(FontPx(12 - (1 - R) * 3));
  RowH := Math.Max(S(20), Round(F.LineHeight * 1.45));
  if FNotice <> '' then Rows[0] := FNotice else Rows[0] := FCodec;
  Rows[1] := '';
  Rows[2] := '';
  Rows[3] := '';
  if H >= MinH + Step then Rows[1] := FResolution;
  if H >= MinH + Step * 2 then Rows[2] := FChannels;
  for I := 0 to 2 do
  begin
    T := Rows[I];
    if T = '' then Continue;
    if (I = 0) and (FNotice = '') then
      G.Text(T, InfoL, TopY + I * RowH, InfoR - InfoL, RowH, UIFont(FontPx(12 - (1 - R) * 3), True), clText, 2, 0)
    else
      G.Text(T, InfoL, TopY + I * RowH, InfoR - InfoL, RowH, F, clTextDim, 2, 0);
  end;
  Rc := FRects[bhRate];
  if Rc.Right > Rc.Left then
  begin
    if FHot = bhRate then Fg := clAccentText else Fg := clTextDim;
    G.Text(FRate, InfoL, Rc.Top, InfoR - InfoL, RowH, F, Fg, 2, 0);
    if FHot = bhRate then G.FillRect(Rc.Left, Rc.Top + Ceil(F.LineHeight) - S(1), Rc.Right - Rc.Left, SF(1.2), Fg);
  end;
  { badge, booklet, heart }
  Rc := FRects[bhBadge];
  if Rc.Right > Rc.Left then
  begin
    if FBadge = bbBitPerfect then C := clGood else C := clWarn;
    G.FillRound(Rc.Left, Rc.Top, Rc.Right - Rc.Left, Rc.Bottom - Rc.Top, (Rc.Bottom - Rc.Top) / 2,
      Blend(GradBottom, C, IfThen(FHot = bhBadge, 0.30, 0.18)));
    G.FillCircle(Rc.Left + S(11), (Rc.Top + Rc.Bottom) / 2, SF(3.2), C);
    G.Text(FBadgeText, Rc.Left + S(19), Rc.Top, Rc.Right - Rc.Left - S(22), Rc.Bottom - Rc.Top, UIFont(11.5, True), C, 0, 1);
  end;
  Rc := FRects[bhBooklet];
  if Rc.Right > Rc.Left then
  begin
    HotBack(bhBooklet);
    DrawIcon(G, icBook, (Rc.Left + Rc.Right) / 2, (Rc.Top + Rc.Bottom) / 2, S(18), IfC(FHot = bhBooklet, clText, clTextDim));
  end;
  Rc := FRects[bhHeart];
  if Rc.Right > Rc.Left then
  begin
    HotBack(bhHeart);
    if FFavorite then DrawIcon(G, icHeartFill, (Rc.Left + Rc.Right) / 2, (Rc.Top + Rc.Bottom) / 2, S(18), clAccentText)
    else DrawIcon(G, icHeart, (Rc.Left + Rc.Right) / 2, (Rc.Top + Rc.Bottom) / 2, S(18), IfC(FHot = bhHeart, clText, clTextDim));
  end;
end;

procedure TNowPlayingBanner.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  H: TBannerHot;
  A: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  H := HotAt(X, Y, A);
  if (H <> FHot) or (A <> FHotArtist) then
  begin
    FHot := H;
    FHotArtist := A;
    if H = bhNone then Cursor := crDefault else Cursor := crHandPoint;
    Invalidate;
  end;
end;

procedure TNowPlayingBanner.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  A: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then FDown := HotAt(X, Y, A) else FDown := bhNone;
end;

procedure TNowPlayingBanner.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  H: TBannerHot;
  A: Integer;
  Rc: TRect;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  H := HotAt(X, Y, A);
  if (H = bhNone) or (H <> FDown) then
  begin
    FDown := bhNone;
    Exit;
  end;
  FDown := bhNone;
  Rc := FRects[H];
  case H of
    bhCover: if Assigned(FOnCover) then FOnCover(Self);
    bhAlbum: if Assigned(FOnAlbum) then FOnAlbum(Self);
    bhArtist: if Assigned(FOnArtist) and (A >= 0) and (A < FArtists.Count) then FOnArtist(Self, FArtists[A]);
    bhMoreArtists: if Assigned(FOnMoreArtists) then FOnMoreArtists(Self, ClientToScreen(Point(Rc.Left, Rc.Bottom + S(4))));
    bhRate: if Assigned(FOnRate) then FOnRate(Self, ClientToScreen(Point(Rc.Left, Rc.Bottom + S(4))));
    bhBadge: if Assigned(FOnBadge) then FOnBadge(Self, ClientToScreen(Point(Rc.Left, Rc.Bottom + S(4))));
    bhHeart: if Assigned(FOnHeart) then FOnHeart(Self);
    bhBooklet: if Assigned(FOnBooklet) then FOnBooklet(Self);
  end;
end;

procedure TNowPlayingBanner.MouseLeave;
begin
  inherited MouseLeave;
  FHot := bhNone;
  FHotArtist := -1;
  Cursor := crDefault;
  Invalidate;
end;

end.
