unit AuCrumbBar;

{ ==============================================================================
  AulumicNS - AuCrumbBar
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TCrumbBar: a path shown as its parts with arrows between them. Every part
  but the last can be clicked (OnPartClick), so the bar is also the way back
  up: above the album tiles of the library, and in the folder dialog. With
  the keyboard: Tab reaches the bar, Left and Right go from part to part,
  Enter or Space goes to the part.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, LCLType,
  AuGfx, AuTheme, AuIcons, AuControls;

type
  TCrumbClickEvent = procedure(Sender: TObject; Index: Integer) of object;

  { TCrumbBar - a path as parts with arrows between them. All parts but the
    last can be clicked. A path too long for the bar loses its first parts
    (shown as "..."). }

  TCrumbBar = class(TAuControl)
  private
    FParts: array of string;
    FRects: array of TRect;           // where each part was drawn (empty: not shown)
    FLinks: Boolean;
    FHotPart: Integer;
    FKeyPart: Integer;                // the part the keyboard is on (-1: none)
    FFirstShown: Integer;             // the first part that is drawn
    FFontSize: Single;
    FOnPartClick: TCrumbClickEvent;
    function PartAt(X, Y: Integer): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
  public
    constructor Create(AOwner: TComponent); override;
    { APath: the parts joined by #1; with more than one part all but the
      last are links }
    procedure SetPath(const APath: string);
    function PartCount: Integer;
    { the part the keyboard is on while the bar has the focus (-1: none) }
    property KeyPart: Integer read FKeyPart;
    { the width the whole path needs }
    function NeededWidth: Integer;
    property FontSize: Single read FFontSize write FFontSize;
    property OnPartClick: TCrumbClickEvent read FOnPartClick write FOnPartClick;
  end;

implementation

{ a text with line ends as one line }
function OneLine(const S: string): string;
begin
  Result := Trim(S);
  if (Pos(#10, Result) = 0) and (Pos(#13, Result) = 0) then Exit;
  Result := StringReplace(Result, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
end;

{ ---- TCrumbBar ---- }

constructor TCrumbBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHotPart := -1;
  FKeyPart := -1;
  FFontSize := 12;
end;

function TCrumbBar.PartCount: Integer;
begin
  Result := Length(FParts);
end;

function TCrumbBar.NeededWidth: Integer;
var
  I: Integer;
  F: TGfxFont;
begin
  Result := 0;
  F := UIFont(FFontSize);
  for I := 0 to High(FParts) do
  begin
    Inc(Result, Ceil(TextWidth(FParts[I], F)) + S(2));
    if I > 0 then Inc(Result, S(16));
  end;
end;

procedure TCrumbBar.SetPath(const APath: string);
var
  SL: TStringList;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Delimiter := #1;
    SL.StrictDelimiter := True;
    SL.DelimitedText := APath;
    SetLength(FParts, SL.Count);
    for I := 0 to SL.Count - 1 do FParts[I] := OneLine(SL[I]);
  finally
    SL.Free;
  end;
  FLinks := Length(FParts) > 1;
  { something to go to: the Tab key stops here, on the part above the last }
  TabStop := FLinks;
  if FLinks then FKeyPart := High(FParts) - 1 else FKeyPart := -1;
  FFirstShown := 0;
  SetLength(FRects, Length(FParts));
  for I := 0 to High(FRects) do FRects[I] := Rect(0, 0, 0, 0);
  FHotPart := -1;
  Cursor := crDefault;
  Invalidate;
end;

{ a part that can be clicked at this point, or -1 }
function TCrumbBar.PartAt(X, Y: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  if not FLinks then Exit;
  for I := 0 to High(FParts) - 1 do
    if (I <= High(FRects)) and (X >= FRects[I].Left) and (X < FRects[I].Right) and
       (Y >= FRects[I].Top) and (Y < FRects[I].Bottom) then Exit(I);
end;

procedure TCrumbBar.DoPaint(G: TGfx);
const
  DOTS = '...';
var
  F: TGfxFont;
  W: array of Integer;
  I, First, Total, SepW, DotsW, X, PW: Integer;
  C: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  for I := 0 to High(FRects) do FRects[I] := Rect(0, 0, 0, 0);
  if Length(FParts) = 0 then Exit;
  F := UIFont(FFontSize);
  SepW := S(16);
  DotsW := Ceil(TextWidth(DOTS, F)) + SepW;
  W := nil;
  SetLength(W, Length(FParts));
  Total := 0;
  for I := 0 to High(FParts) do
  begin
    W[I] := Ceil(TextWidth(FParts[I], F)) + S(2);
    Inc(Total, W[I]);
    if I > 0 then Inc(Total, SepW);
  end;
  { too long: the first parts go, the last one always stays }
  First := 0;
  while (First < High(FParts)) and (Total + IfThen(First > 0, DotsW, 0) > Width) do
  begin
    Dec(Total, W[First] + SepW);
    Inc(First);
  end;
  FFirstShown := First;
  X := 0;
  if First > 0 then
  begin
    G.Text(DOTS, X, 0, DotsW - SepW, Height, F, clTextFaint, 0, 1);
    DrawIcon(G, icChevronRight, X + DotsW - SepW / 2, Height / 2, S(9), clTextFaint);
    Inc(X, DotsW);
  end;
  for I := First to High(FParts) do
  begin
    PW := Math.Min(W[I], Math.Max(S(10), Width - X));
    if I = High(FParts) then C := clText
    else if (I = FHotPart) or (ShowFocus and (I = FKeyPart)) then C := clAccentText
    else C := clTextDim;
    G.Text(FParts[I], X, 0, PW, Height, F, C, 0, 1);
    if ((I = FHotPart) or (ShowFocus and (I = FKeyPart))) and (I < High(FParts)) then
      G.FillRect(X, Height div 2 + S(9), PW - S(2), Math.Max(1, S(1)), clAccentText);
    FRects[I] := Rect(X, S(4), X + PW, Height - S(4));
    Inc(X, PW);
    if I < High(FParts) then
    begin
      DrawIcon(G, icChevronRight, X + SepW / 2, Height / 2, S(9), clTextFaint);
      Inc(X, SepW);
    end;
  end;
end;

procedure TCrumbBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  P: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  P := PartAt(X, Y);
  if P = FHotPart then Exit;
  FHotPart := P;
  if P >= 0 then Cursor := crHandPoint else Cursor := crDefault;
  Invalidate;
end;

procedure TCrumbBar.MouseLeave;
begin
  inherited MouseLeave;
  if FHotPart < 0 then Exit;
  FHotPart := -1;
  Cursor := crDefault;
  Invalidate;
end;

procedure TCrumbBar.DoEnter;
begin
  { always from the part above the last: one Enter is one level up }
  if FLinks then FKeyPart := High(FParts) - 1;
  inherited DoEnter;
end;

procedure TCrumbBar.KeyDown(var Key: Word; Shift: TShiftState);
var
  P: Integer;
begin
  inherited KeyDown(Key, Shift);
  if not FLinks or (Shift <> []) then Exit;
  { a bar so narrow that only the last part is drawn has nothing to go to }
  if FFirstShown > High(FParts) - 1 then Exit;
  P := EnsureRange(FKeyPart, FFirstShown, High(FParts) - 1);
  case Key of
    VK_LEFT: P := Math.Max(Math.Min(FFirstShown, High(FParts) - 1), P - 1);
    VK_RIGHT: P := Math.Min(High(FParts) - 1, P + 1);
    VK_HOME: P := Math.Min(FFirstShown, High(FParts) - 1);
    VK_END: P := High(FParts) - 1;
    VK_RETURN, VK_SPACE:
      begin
        Key := 0;
        FKeyPart := P;
        if Assigned(FOnPartClick) then FOnPartClick(Self, P);
        Exit;
      end;
  else
    Exit;
  end;
  Key := 0;
  if P = FKeyPart then Exit;
  FKeyPart := P;
  Invalidate;
end;

procedure TCrumbBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  P: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  P := PartAt(X, Y);
  if (P >= 0) and Assigned(FOnPartClick) then FOnPartClick(Self, P);
end;

end.
