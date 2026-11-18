unit AuIcons;

{ Vector icon set. Every icon is drawn with strokes / fills (AuGfx) on a 16 x 16
  design grid and scaled to any size, so it is crisp at every DPI and takes
  the colour of the current theme. }

{$mode objfpc}{$H+}

interface

uses
  Windows, Math, AuGfx;

type
  TAuIcon = (icNone,
    { transport }
    icPlay, icPause, icStop, icPrev, icNext, icShuffle, icRepeat, icRepeatOne,
    icVolume0, icVolume1, icVolume2, icMute,
    { navigation }
    icHome, icLibrary, icAlbum, icArtist, icPlaylist, icFolder, icFolderPlus, icQueue,
    icNowPlaying, icSearch, icSettings, icSidebar, icGrid, icList, icBack,
    { generic }
    icSun, icMoon, icHeart, icHeartFill, icStar, icStarFill, icPlus, icMinus, icClose,
    icCheck, icChevronDown, icChevronUp, icChevronLeft, icChevronRight, icMenu, icMore,
    icInfo, icWarning, icDocument, icImage, icEdit, icTrash, icRefresh, icNote,
    icSpeaker, icHeadphones, icWave, icSortAsc, icSortDesc, icFilter, icClock, icTag,
    icSliders, icBolt, icDisc, icDrive, icFit,
    { added for AulumicNS }
    icLocate, icEye, icLink, icGlobe, icTriRight, icTriDown, icBook, icEqualizer,
    icExport, icImport, icHelp, icPower, icBug, icLog, icStopSolid, icComposer,
    icPerformer, icGenre, icFunnel, icScan, icCopy, icPaste, icKey, icCpu);

procedure DrawIcon(G: TGfx; Icon: TAuIcon; CX, CY, Sz: Single; C: TARGB);

implementation

procedure DrawIcon(G: TGfx; Icon: TAuIcon; CX, CY, Sz: Single; C: TARGB);
var
  U, LW: Single;
  I: Integer;
  A: Single;
  St: UINT;

  function X(V: Single): Single;
  begin
    Result := CX + (V - 8) * U;
  end;

  function Y(V: Single): Single;
  begin
    Result := CY + (V - 8) * U;
  end;

  function P(PX, PY: Single): TGfxPoint;
  begin
    Result := GPt(X(PX), Y(PY));
  end;

  procedure L(X1, Y1, X2, Y2: Single);
  begin
    G.Line(X(X1), Y(Y1), X(X2), Y(Y2), LW, C);
  end;

  procedure Poly(const Q: array of TGfxPoint; Closed: Boolean);
  begin
    G.StrokePoly(Q, LW, C, Closed);
  end;

  procedure PolyF(const Q: array of TGfxPoint);
  begin
    G.FillPoly(Q, C);
    G.StrokePoly(Q, LW * 0.6, C, True);    // rounds the corners
  end;

  procedure Circ(PX, PY, R: Single);
  begin
    G.StrokeCircle(X(PX), Y(PY), R * U, LW, C);
  end;

  procedure CircF(PX, PY, R: Single);
  begin
    G.FillCircle(X(PX), Y(PY), R * U, C);
  end;

  procedure ArcS(PX, PY, R, Start, Sweep: Single);
  begin
    G.Arc(X(PX), Y(PY), R * U, Start, Sweep, LW, C);
  end;

  procedure RR(PX, PY, W, H, R: Single);
  begin
    G.StrokeRound(X(PX) - LW / 2, Y(PY) - LW / 2, W * U + LW, H * U + LW, R * U, LW, C);
  end;

  procedure RRF(PX, PY, W, H, R: Single);
  begin
    G.FillRound(X(PX), Y(PY), W * U, H * U, R * U, C);
  end;

  procedure Bez(X1, Y1, X2, Y2, X3, Y3, X4, Y4: Single);
  var
    BP: TGfxPath;
  begin
    BP := TGfxPath.Create;
    BP.AddBezier(X(X1), Y(Y1), X(X2), Y(Y2), X(X3), Y(Y3), X(X4), Y(Y4));
    G.StrokePath(BP, LW, C);
    BP.Free;
  end;

  procedure Speaker;
  begin
    Poly([P(2.5, 6), P(5, 6), P(8.5, 3), P(8.5, 13), P(5, 10), P(2.5, 10)], True);
  end;

  procedure HeartPath(Fill: Boolean);
  var
    HP: TGfxPath;
  begin
    HP := TGfxPath.Create;
    HP.AddArc(X(5.4) - 2.9 * U, Y(6.2) - 2.9 * U, 5.8 * U, 5.8 * U, 135, 195);
    HP.AddArc(X(10.6) - 2.9 * U, Y(6.2) - 2.9 * U, 5.8 * U, 5.8 * U, 210, 195);
    HP.AddLine(X(12.65), Y(8.25), X(8), Y(13.3));
    HP.CloseFigure;
    if Fill then G.FillPath(HP, C);
    G.StrokePath(HP, LW, C);
    HP.Free;
  end;

  procedure StarPts(Fill: Boolean);
  var
    K: Integer;
    R, Ang: Single;
    SP: array[0..9] of TGfxPoint;
  begin
    for K := 0 to 9 do
    begin
      if Odd(K) then R := 2.7 else R := 6.2;
      Ang := -Pi / 2 + K * Pi / 5;
      SP[K] := P(8 + Cos(Ang) * R, 8.6 + Sin(Ang) * R);
    end;
    if Fill then G.FillPoly(SP, C);
    G.StrokePoly(SP, LW, C, True);
  end;

  procedure Rays(R1, R2: Single);
  var
    K: Integer;
  begin
    for K := 0 to 7 do
    begin
      A := K * Pi / 4;
      G.Line(X(8 + Cos(A) * R1), Y(8 + Sin(A) * R1), X(8 + Cos(A) * R2), Y(8 + Sin(A) * R2), LW, C);
    end;
  end;

begin
  if Icon = icNone then Exit;
  U := Sz / 16;
  LW := Max(1.15, 1.45 * U);
  case Icon of
    icPlay: PolyF([P(5, 2.8), P(13.2, 8), P(5, 13.2)]);
    icPause: begin RRF(3.8, 2.8, 3, 10.4, 1); RRF(9.2, 2.8, 3, 10.4, 1); end;
    icStop: RRF(3.5, 3.5, 9, 9, 1.6);
    icPrev: begin L(3.5, 3.5, 3.5, 12.5); PolyF([P(12.5, 3.5), P(12.5, 12.5), P(5.6, 8)]); end;
    icNext: begin L(12.5, 3.5, 12.5, 12.5); PolyF([P(3.5, 3.5), P(3.5, 12.5), P(10.4, 8)]); end;
    icShuffle:
      begin
        L(1.8, 4.5, 4.2, 4.5);
        Bez(4.2, 4.5, 8, 4.5, 8, 11.5, 11.8, 11.5);
        L(11.8, 11.5, 14, 11.5);
        L(1.8, 11.5, 4.2, 11.5);
        Bez(4.2, 11.5, 8, 11.5, 8, 4.5, 11.8, 4.5);
        L(11.8, 4.5, 14, 4.5);
        L(12, 2.5, 14, 4.5); L(12, 6.5, 14, 4.5);
        L(12, 9.5, 14, 11.5); L(12, 13.5, 14, 11.5);
      end;
    icRepeat, icRepeatOne:
      begin
        ArcS(5, 8, 3.5, 90, 180);
        L(5, 4.5, 11.5, 4.5);
        ArcS(11, 8, 3.5, 270, 180);
        L(11, 11.5, 4.5, 11.5);
        L(9.6, 2.6, 11.5, 4.5); L(9.6, 6.4, 11.5, 4.5);
        L(6.4, 9.6, 4.5, 11.5); L(6.4, 13.4, 4.5, 11.5);
        if Icon = icRepeatOne then
          G.Text('1', X(4), Y(4.8), 8 * U, 6.4 * U, GetFont(Max(6, 6.2 * U), True), C, 1, 1, tfNoEllipsis);
      end;
    icVolume0: Speaker;
    icVolume1: begin Speaker; ArcS(8.5, 8, 2.9, -50, 100); end;
    icVolume2: begin Speaker; ArcS(8.5, 8, 2.9, -50, 100); ArcS(8.5, 8, 5.4, -55, 110); end;
    icMute: begin Speaker; L(11, 6, 14.5, 9.8); L(14.5, 6, 11, 9.8); end;
    icHome:
      begin
        Poly([P(2, 7.5), P(8, 2.3), P(14, 7.5)], False);
        Poly([P(3.8, 6.2), P(3.8, 13.5), P(12.2, 13.5), P(12.2, 6.2)], False);
        Poly([P(6.6, 13.5), P(6.6, 9.8), P(9.4, 9.8), P(9.4, 13.5)], False);
      end;
    icLibrary:
      begin
        L(3, 2.8, 3, 13.2);
        L(6.4, 2.8, 6.4, 13.2);
        Poly([P(9.2, 3.6), P(11.8, 2.9), P(14.4, 12.6), P(11.8, 13.3)], True);
      end;
    icAlbum, icDisc: begin Circ(8, 8, 6); Circ(8, 8, 1.9); end;
    icArtist: begin Circ(8, 5.3, 2.8); ArcS(8, 14.6, 5.6, 200, 140); end;
    icPlaylist:
      begin
        L(2.5, 3.8, 11, 3.8); L(2.5, 7.4, 11, 7.4); L(2.5, 11, 6.8, 11);
        CircF(10.6, 12.4, 1.9);
        L(12.4, 12.4, 12.4, 6.6); L(12.4, 6.6, 14.4, 7.6);
      end;
    icQueue:
      begin
        L(2.5, 3.8, 13.5, 3.8); L(2.5, 7.6, 13.5, 7.6); L(2.5, 11.6, 7.8, 11.6);
        PolyF([P(10.4, 9.6), P(14, 11.6), P(10.4, 13.6)]);
      end;
    icFolder, icFolderPlus:
      begin
        Poly([P(2, 3.8), P(6.3, 3.8), P(7.9, 5.6), P(14, 5.6), P(14, 13), P(2, 13)], True);
        if Icon = icFolderPlus then begin L(8, 7.6, 8, 11.2); L(6.2, 9.4, 9.8, 9.4); end;
      end;
    icFit:
      begin
        Poly([P(2.5, 6), P(2.5, 2.5), P(6, 2.5)], False);
        Poly([P(10, 2.5), P(13.5, 2.5), P(13.5, 6)], False);
        Poly([P(13.5, 10), P(13.5, 13.5), P(10, 13.5)], False);
        Poly([P(6, 13.5), P(2.5, 13.5), P(2.5, 10)], False);
      end;
    icDrive:
      begin
        RR(2, 4.5, 12, 7, 1.6);
        CircF(11.3, 8, 0.9);
        L(4.4, 8, 7.6, 8);
      end;
    icNowPlaying: begin L(3.2, 13, 3.2, 8.5); L(6.4, 13, 6.4, 3.5); L(9.6, 13, 9.6, 6.2); L(12.8, 13, 12.8, 9.8); end;
    icSearch: begin Circ(7, 7, 4.3); L(10.2, 10.2, 13.6, 13.6); end;
    icSettings:
      begin
        Circ(8, 8, 2.1);
        Circ(8, 8, 4.7);
        for I := 0 to 7 do
        begin
          A := I * Pi / 4 + Pi / 8;
          G.Line(X(8 + Cos(A) * 4.9), Y(8 + Sin(A) * 4.9), X(8 + Cos(A) * 6.6), Y(8 + Sin(A) * 6.6), LW * 1.5, C);
        end;
      end;
    icSidebar: begin RR(2, 3, 12, 10, 2); L(6.2, 3, 6.2, 13); end;
    icGrid: begin RR(2.5, 2.5, 4.4, 4.4, 1); RR(9.1, 2.5, 4.4, 4.4, 1); RR(2.5, 9.1, 4.4, 4.4, 1); RR(9.1, 9.1, 4.4, 4.4, 1); end;
    icList:
      begin
        CircF(3, 4, 1); CircF(3, 8, 1); CircF(3, 12, 1);
        L(6, 4, 14, 4); L(6, 8, 14, 8); L(6, 12, 14, 12);
      end;
    icBack: begin L(13, 8, 3, 8); L(7, 4, 3, 8); L(7, 12, 3, 8); end;
    icSun: begin Circ(8, 8, 2.8); Rays(4.9, 6.6); end;
    icMoon:
      begin
        St := G.Save;
        G.ExcludeClipEllipse(X(9.8) - 4.4 * U, Y(5.2) - 4.4 * U, 8.8 * U, 8.8 * U);
        G.FillCircle(X(8), Y(8.4), 5.8 * U, C);
        G.Restore(St);
      end;
    icHeart: HeartPath(False);
    icHeartFill: HeartPath(True);
    icStar: StarPts(False);
    icStarFill: StarPts(True);
    icPlus: begin L(8, 3, 8, 13); L(3, 8, 13, 8); end;
    icMinus: L(3, 8, 13, 8);
    icClose: begin L(4, 4, 12, 12); L(12, 4, 4, 12); end;
    icCheck: begin L(3, 8.5, 6.5, 12); L(6.5, 12, 13, 4.5); end;
    icChevronDown: begin L(4, 6, 8, 10); L(8, 10, 12, 6); end;
    icChevronUp: begin L(4, 10, 8, 6); L(8, 6, 12, 10); end;
    icChevronLeft: begin L(10, 4, 6, 8); L(6, 8, 10, 12); end;
    icChevronRight: begin L(6, 4, 10, 8); L(10, 8, 6, 12); end;
    icMenu: begin L(2.5, 4.2, 13.5, 4.2); L(2.5, 8, 13.5, 8); L(2.5, 11.8, 13.5, 11.8); end;
    icMore: begin CircF(3.5, 8, 1.3); CircF(8, 8, 1.3); CircF(12.5, 8, 1.3); end;
    icInfo: begin Circ(8, 8, 6.2); L(8, 7.3, 8, 11.6); CircF(8, 4.9, 0.95); end;
    icWarning:
      begin
        Poly([P(8, 2.3), P(14.3, 13.4), P(1.7, 13.4)], True);
        L(8, 6.6, 8, 9.6);
        CircF(8, 11.6, 0.85);
      end;
    icDocument:
      begin
        Poly([P(3.5, 1.8), P(9.6, 1.8), P(12.5, 4.7), P(12.5, 14.2), P(3.5, 14.2)], True);
        Poly([P(9.6, 1.8), P(9.6, 4.7), P(12.5, 4.7)], False);
        L(5.8, 8, 10.2, 8); L(5.8, 10.6, 10.2, 10.6);
      end;
    icImage:
      begin
        RR(2, 3, 12, 10, 1.6);
        CircF(5.6, 6.3, 1.25);
        Poly([P(2.6, 12.2), P(6.4, 8.4), P(8.9, 10.8), P(10.6, 9.2), P(13.4, 12)], False);
      end;
    icEdit:
      begin
        Poly([P(10.6, 2.4), P(13.6, 5.4), P(5.6, 13.4), P(2.5, 13.5), P(2.6, 10.4)], True);
        L(9, 4, 12, 7);
      end;
    icTrash:
      begin
        L(2.4, 4.4, 13.6, 4.4);
        Poly([P(6, 4.4), P(6.4, 2.4), P(9.6, 2.4), P(10, 4.4)], False);
        Poly([P(3.9, 4.4), P(4.8, 14), P(11.2, 14), P(12.1, 4.4)], False);
        L(6.7, 7, 6.9, 11.4); L(9.3, 7, 9.1, 11.4);
      end;
    icRefresh:
      begin
        ArcS(8, 8, 5.2, 40, 290);
        L(12.5, 5.4, 12.9, 2.2);
        L(12.5, 5.4, 9.4, 5.0);
      end;
    icNote:
      begin
        CircF(5, 12, 2);
        CircF(11.4, 10.6, 2);
        L(6.8, 12, 6.8, 3.6);
        L(13.2, 10.6, 13.2, 2.4);
        G.Line(X(6.8), Y(3.6), X(13.2), Y(2.4), LW * 1.5, C);
      end;
    icSpeaker: begin RR(3.8, 1.8, 8.4, 12.4, 1.6); Circ(8, 10.2, 2.1); CircF(8, 4.9, 0.95); end;
    icHeadphones:
      begin
        ArcS(8, 9, 5.6, 180, 180);
        RRF(1.8, 8.8, 3.4, 5.2, 1.2);
        RRF(10.8, 8.8, 3.4, 5.2, 1.2);
      end;
    icWave:
      begin
        L(2, 7, 2, 9); L(4.4, 5, 4.4, 11); L(6.8, 2.6, 6.8, 13.4);
        L(9.2, 5.4, 9.2, 10.6); L(11.6, 3.8, 11.6, 12.2); L(14, 6.8, 14, 9.2);
      end;
    icSortAsc: begin L(8, 13, 8, 3); L(4.5, 6.5, 8, 3); L(11.5, 6.5, 8, 3); end;
    icSortDesc: begin L(8, 3, 8, 13); L(4.5, 9.5, 8, 13); L(11.5, 9.5, 8, 13); end;
    icFilter: Poly([P(2, 3), P(14, 3), P(9.4, 8.6), P(9.4, 13.2), P(6.6, 11.8), P(6.6, 8.6)], True);
    icClock: begin Circ(8, 8, 6.2); L(8, 8, 8, 4.4); L(8, 8, 10.6, 9.6); end;
    icTag:
      begin
        Poly([P(2.4, 2.4), P(8.4, 2.4), P(14, 8), P(8, 14), P(2.4, 8.4)], True);
        CircF(5.5, 5.5, 1.05);
      end;
    icSliders:
      begin
        L(4, 2.5, 4, 13.5); L(8, 2.5, 8, 13.5); L(12, 2.5, 12, 13.5);
        CircF(4, 10, 1.9); CircF(8, 5.2, 1.9); CircF(12, 9, 1.9);
      end;
    icBolt: PolyF([P(9.5, 1.5), P(3.5, 9), P(7.5, 9), P(6.5, 14.5), P(12.5, 7), P(8.5, 7)]);
    { ---- AulumicNS ---- }
    icLocate:                        // jump to now playing: target
      begin
        Circ(8, 8, 4.6);
        CircF(8, 8, 1.6);
        L(8, 1.2, 8, 3.4); L(8, 12.6, 8, 14.8);
        L(1.2, 8, 3.4, 8); L(12.6, 8, 14.8, 8);
      end;
    icEye:
      begin
        Bez(1.6, 8, 4, 3.6, 12, 3.6, 14.4, 8);
        Bez(1.6, 8, 4, 12.4, 12, 12.4, 14.4, 8);
        Circ(8, 8, 2.1);
      end;
    icLink:
      begin
        RR(1.8, 5.6, 7.2, 4.8, 2.4);
        RR(7, 5.6, 7.2, 4.8, 2.4);
      end;
    icGlobe:
      begin
        Circ(8, 8, 6.2);
        L(1.8, 8, 14.2, 8);
        Bez(8, 1.8, 4.6, 4.6, 4.6, 11.4, 8, 14.2);
        Bez(8, 1.8, 11.4, 4.6, 11.4, 11.4, 8, 14.2);
      end;
    icTriRight: PolyF([P(6, 4), P(11, 8), P(6, 12)]);
    icTriDown: PolyF([P(4, 6), P(12, 6), P(8, 11)]);
    icBook:                          // booklet: open book
      begin
        Poly([P(8, 4.2), P(4.8, 3), P(1.8, 3), P(1.8, 12.4), P(4.8, 12.4), P(8, 13.6)], False);
        Poly([P(8, 4.2), P(11.2, 3), P(14.2, 3), P(14.2, 12.4), P(11.2, 12.4), P(8, 13.6)], False);
        L(8, 4.2, 8, 13.6);
      end;
    icEqualizer:                     // tone control: horizontal sliders
      begin
        L(2, 4, 14, 4); L(2, 8, 14, 8); L(2, 12, 14, 12);
        CircF(10.4, 4, 1.8); CircF(5.2, 8, 1.8); CircF(9, 12, 1.8);
      end;
    icExport:
      begin
        Poly([P(6, 5), P(3, 5), P(3, 13.5), P(13, 13.5), P(13, 5), P(10, 5)], False);
        L(8, 1.8, 8, 9.6); L(5.4, 4.4, 8, 1.8); L(10.6, 4.4, 8, 1.8);
      end;
    icImport:
      begin
        Poly([P(6, 5), P(3, 5), P(3, 13.5), P(13, 13.5), P(13, 5), P(10, 5)], False);
        L(8, 1.8, 8, 9.6); L(5.4, 7, 8, 9.6); L(10.6, 7, 8, 9.6);
      end;
    icHelp:
      begin
        Circ(8, 8, 6.2);
        ArcS(8, 6.3, 2.2, 180, 230);
        L(8, 8.9, 8, 9.9);
        CircF(8, 11.9, 0.95);
      end;
    icPower: begin ArcS(8, 8.6, 5.4, -50, 280); L(8, 1.8, 8, 7.6); end;
    icBug:
      begin
        RR(5, 5.4, 6, 8, 3);
        L(8, 6.6, 8, 13);
        L(5, 8.4, 2.4, 7.4); L(11, 8.4, 13.6, 7.4);
        L(5, 11.4, 2.4, 12.6); L(11, 11.4, 13.6, 12.6);
        L(6.4, 5.2, 5.2, 2.6); L(9.6, 5.2, 10.8, 2.6);
      end;
    icLog:
      begin
        RR(2.5, 2, 11, 12, 1.6);
        L(5, 5.2, 11, 5.2); L(5, 8, 11, 8); L(5, 10.8, 8.6, 10.8);
      end;
    icStopSolid: RRF(3.5, 3.5, 9, 9, 1.6);
    icComposer:                      // a quill
      begin
        Bez(3, 13.4, 5, 8, 9, 3.6, 13.8, 2.2);
        Bez(13.8, 2.2, 12.6, 7, 9.4, 10.4, 4.6, 11.6);
        L(2.4, 14, 5.2, 11);
      end;
    icPerformer:                     // a microphone
      begin
        RR(5.6, 1.8, 4.8, 7.4, 2.4);
        ArcS(8, 6.4, 4.4, 20, 140);
        L(8, 10.8, 8, 13.8); L(5.4, 13.8, 10.6, 13.8);
      end;
    icGenre: begin Circ(8, 8, 6); Circ(8, 8, 1.6); ArcS(8, 8, 3.8, 200, 60); end;
    icFunnel: Poly([P(2, 3), P(14, 3), P(9.4, 8.6), P(9.4, 13.2), P(6.6, 11.8), P(6.6, 8.6)], True);
    icScan:
      begin
        Poly([P(2.5, 5.5), P(2.5, 2.5), P(5.5, 2.5)], False);
        Poly([P(10.5, 2.5), P(13.5, 2.5), P(13.5, 5.5)], False);
        Poly([P(13.5, 10.5), P(13.5, 13.5), P(10.5, 13.5)], False);
        Poly([P(5.5, 13.5), P(2.5, 13.5), P(2.5, 10.5)], False);
        L(4.5, 8, 11.5, 8);
      end;
    icCopy: begin RR(5.2, 5.2, 8.4, 8.8, 1.4); Poly([P(3, 10.6), P(2.4, 10.6), P(2.4, 2.4), P(9.6, 2.4), P(9.6, 3.2)], False); end;
    icPaste:
      begin
        RR(3, 3, 10, 11.2, 1.4);
        RRF(5.6, 1.6, 4.8, 2.8, 0.8);
        L(5.4, 8, 10.6, 8); L(5.4, 10.6, 9, 10.6);
      end;
    icKey: begin Circ(5.2, 10.8, 3); L(7.4, 8.6, 13.6, 2.4); L(11.4, 4.6, 13, 6.2); L(9.6, 6.4, 11, 7.8); end;
    icCpu:
      begin
        RR(4, 4, 8, 8, 1.2);
        RR(6.4, 6.4, 3.2, 3.2, 0.4);
        L(6, 1.8, 6, 4); L(10, 1.8, 10, 4); L(6, 12, 6, 14.2); L(10, 12, 10, 14.2);
        L(1.8, 6, 4, 6); L(1.8, 10, 4, 10); L(12, 6, 14.2, 6); L(12, 10, 14.2, 10);
      end;
  end;
end;

end.
