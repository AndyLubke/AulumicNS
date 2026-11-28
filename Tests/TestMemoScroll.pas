unit TestMemoScroll;

{ ==============================================================================
  AulumicNS tests - TestMemoScroll
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The scroll bar of the multi-line text box (TAuMemo): it is the scroll bar
  of the lists, shown only while the text is taller than the box, and bar
  and text move together.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, fpcunit, testregistry, AuGfx, AuTheme, AuControls;

type
  TTestMemoScroll = class(TTestCase)
  private
    FForm: TForm;
    FMemo: TAuMemo;
    function Lines(N: Integer): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AShortTextHasNoBar;
    procedure ALongTextShowsTheBar;
    procedure TheBarIsTheOneOfTheLists;
    procedure TheBarMovesTheText;
    procedure ANewTextStartsAtTheTop;
    procedure TheSameTextAgainStaysWhereItWas;
    procedure ATallerBoxNeedsNoBar;
    procedure ThePlainBoxHasItToo;
    procedure TheTextDoesNotBreakAnewWhenTheBarComes;
    procedure ALongTextBreaksAsOneMeasuredByTheLetter;
  end;

implementation

function TTestMemoScroll.Lines(N: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to N do Result := Result + 'Line ' + IntToStr(I) + LineEnding;
end;

procedure TTestMemoScroll.SetUp;
begin
  FForm := TForm.CreateNew(nil);
  FForm.SetBounds(0, 0, 600, 500);
  FMemo := TAuMemo.Create(FForm);
  FMemo.Parent := FForm;
  FMemo.SetBounds(10, 10, 400, 200);
end;

procedure TTestMemoScroll.TearDown;
begin
  FreeAndNil(FForm);
end;

{ the lines of a text of some pages are those of the plain way - every line
  grown letter by letter until it no longer fits - and are found much faster }
procedure TTestMemoScroll.ALongTextBreaksAsOneMeasuredByTheLetter;
const
  WIDTHS: array[0..2] of Integer = (520, 300, 90);
var
  S: string;
  U: UnicodeString;
  Want: array of Integer;
  I, J, K, N, WantN: Integer;
  T0, FastMs, SlowMs: QWord;

  { the plain way, as the box did it before }
  procedure SlowLines(AWidth: Integer);
  var
    F: TGfxFont;
    P, ParEnd, LineStart, LastSpace, C: Integer;

    procedure Add(AStart: Integer);
    begin
      if WantN >= Length(Want) then SetLength(Want, WantN * 2 + 64);
      Want[WantN] := AStart;
      Inc(WantN);
    end;

  begin
    F := UIFont(FMemo.TextSize);
    WantN := 0;
    P := 0;
    repeat
      ParEnd := P;
      while (ParEnd < Length(U)) and (U[ParEnd + 1] <> #10) do Inc(ParEnd);
      LineStart := P;
      if ParEnd = P then Add(P)
      else
        while LineStart < ParEnd do
        begin
          Add(LineStart);
          if TextWidthW(Copy(U, LineStart + 1, ParEnd - LineStart), F) <= AWidth then Break;
          LastSpace := -1;
          C := LineStart + 1;
          while (C < ParEnd) and (TextWidthW(Copy(U, LineStart + 1, C - LineStart + 1), F) <= AWidth) do
          begin
            if U[C + 1] = ' ' then LastSpace := C + 1;
            Inc(C);
          end;
          if LastSpace > LineStart then C := LastSpace;
          LineStart := C;
        end;
      P := ParEnd + 1;
    until ParEnd >= Length(U);
  end;

begin
  { 40 paragraphs: words of 1 to 12 letters, some with accents, double
    spaces, a word longer than any line, an empty paragraph, one that begins
    with a space }
  S := '';
  N := 7;
  for I := 1 to 40 do
  begin
    if I mod 9 = 0 then S := S + #10;
    if I mod 7 = 0 then S := S + ' ';
    for J := 1 to 70 do
    begin
      N := (N * 31 + 11) mod 1009;
      for K := 0 to N mod 12 do S := S + Chr(Ord('a') + (N + K * 5) mod 26);
      if N mod 23 = 0 then S := S + #$C3#$A9 + 'l' + #$C3#$B6;
      if N mod 41 = 0 then S := S + StringOfChar('W', 150);
      if N mod 13 = 0 then S := S + '  ' else S := S + ' ';
    end;
    S := S + #10;
  end;
  U := UTF8Decode(S);
  AssertTrue('a text of some pages', Length(U) > 15000);

  FastMs := 0;
  SlowMs := 0;
  for I := 0 to High(WIDTHS) do
  begin
    FMemo.Text := '';
    FMemo.SetBounds(10, 10, WIDTHS[I], 300);
    FMemo.Text := S;
    T0 := GetTickCount64;
    FMemo.Text := S + ' ';          // (broken again, timed)
    N := FMemo.LineCount;
    FastMs := FastMs + (GetTickCount64 - T0);
    FMemo.Text := S;
    T0 := GetTickCount64;
    SlowLines(FMemo.LineRoom);
    SlowMs := SlowMs + (GetTickCount64 - T0);
    AssertEquals(Format('the number of lines at %d px', [WIDTHS[I]]), WantN, FMemo.LineCount);
    for J := 0 to WantN - 1 do
      if Want[J] <> FMemo.LineStartOf(J) then
        Fail(Format('line %d at %d px begins at %d, not at %d', [J, WIDTHS[I], FMemo.LineStartOf(J), Want[J]]));
  end;
  AssertTrue(Format('much faster (%d ms against %d ms)', [FastMs, SlowMs]), FastMs * 3 < SlowMs);
end;

procedure TTestMemoScroll.AShortTextHasNoBar;
begin
  FMemo.Text := 'One line';
  AssertFalse('No bar for a text that fits', FMemo.ScrollBar.Visible);
  AssertEquals(0, FMemo.ScrollOffset);
end;

procedure TTestMemoScroll.ALongTextShowsTheBar;
begin
  FMemo.Text := Lines(200);
  AssertTrue('The bar is shown', FMemo.ScrollBar.Visible);
  AssertTrue('It has somewhere to go', FMemo.ScrollBar.MaxPos > 0);
  AssertEquals('A page is the box', FMemo.Height, FMemo.ScrollBar.PageSize);
  AssertTrue('It lies inside the box', (FMemo.ScrollBar.Left > FMemo.Width div 2) and
    (FMemo.ScrollBar.Left + FMemo.ScrollBar.Width <= FMemo.Width) and (FMemo.ScrollBar.Top >= 0) and
    (FMemo.ScrollBar.Top + FMemo.ScrollBar.Height <= FMemo.Height));
end;

procedure TTestMemoScroll.TheBarIsTheOneOfTheLists;
var
  B: TAuScrollBar;
begin
  FMemo.Text := Lines(200);
  B := TAuScrollBar.Create(FForm);
  AssertEquals('As wide as any scroll bar', B.Width, FMemo.ScrollBar.Width);
  AssertEquals(TAuScrollBar.ClassName, FMemo.ScrollBar.ClassName);
end;

procedure TTestMemoScroll.TheBarMovesTheText;
begin
  FMemo.Text := Lines(200);
  FMemo.ScrollBar.Position := 120;
  AssertEquals('The text follows the bar', 120, FMemo.ScrollOffset);
  FMemo.ScrollBar.Position := 1000000;
  AssertEquals('No further than the end', FMemo.ScrollBar.MaxPos, FMemo.ScrollOffset);
  FMemo.ScrollBar.Position := -5;
  AssertEquals(0, FMemo.ScrollOffset);
end;

procedure TTestMemoScroll.ANewTextStartsAtTheTop;
begin
  FMemo.Text := Lines(200);
  FMemo.ScrollBar.Position := 300;
  FMemo.Text := Lines(150);
  AssertEquals('The text', 0, FMemo.ScrollOffset);
  AssertEquals('The bar', 0, FMemo.ScrollBar.Position);
  AssertTrue(FMemo.ScrollBar.Visible);
  FMemo.ScrollBar.Position := 300;
  FMemo.Text := 'Short';
  AssertFalse('No bar any more', FMemo.ScrollBar.Visible);
  AssertEquals(0, FMemo.ScrollOffset);
end;

{ a view filled again with the text it shows (a tab opened again, a refresh
  that brought nothing new) stays where it was scrolled to }
procedure TTestMemoScroll.TheSameTextAgainStaysWhereItWas;
begin
  FMemo.Text := Lines(200);
  FMemo.ScrollBar.Position := 300;
  FMemo.Text := Lines(200);
  AssertEquals('The text', 300, FMemo.ScrollOffset);
  AssertEquals('The bar', 300, FMemo.ScrollBar.Position);
end;

procedure TTestMemoScroll.ATallerBoxNeedsNoBar;
var
  Max0: Integer;
begin
  FMemo.Text := Lines(12);
  AssertTrue('Twelve lines do not fit', FMemo.ScrollBar.Visible);
  Max0 := FMemo.ScrollBar.MaxPos;
  FMemo.ScrollBar.Position := Max0;
  FMemo.Height := FMemo.Height + 20;
  AssertEquals('Less to scroll in a taller box', Max0 - 20, FMemo.ScrollBar.MaxPos);
  AssertEquals('The text stays inside', FMemo.ScrollBar.MaxPos, FMemo.ScrollOffset);
  FMemo.Height := 2000;
  AssertFalse('Everything fits', FMemo.ScrollBar.Visible);
  AssertEquals(0, FMemo.ScrollOffset);
end;

procedure TTestMemoScroll.ThePlainBoxHasItToo;
begin
  FMemo.Plain := True;
  FMemo.Text := Lines(200);
  AssertTrue(FMemo.ScrollBar.Visible);
  AssertEquals('At the right edge', FMemo.Width, FMemo.ScrollBar.Left + FMemo.ScrollBar.Width);
  AssertEquals('Over the whole height', FMemo.Height, FMemo.ScrollBar.Height);
end;

{ the room of the bar is kept free whether it is shown or not: with one word
  per line more, the lines before stay as they were }
procedure TTestMemoScroll.TheTextDoesNotBreakAnewWhenTheBarComes;
const
  WORDS = 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen ' +
    'seventeen eighteen nineteen twenty';
var
  Fits, Tall: Integer;
begin
  FMemo.Height := 2000;
  FMemo.Text := WORDS + ' ' + WORDS + ' ' + WORDS;
  AssertFalse(FMemo.ScrollBar.Visible);
  FMemo.ScrollBar.SetParams(0, 1);
  FMemo.Height := 40;
  AssertTrue('Now it needs the bar', FMemo.ScrollBar.Visible);
  Tall := FMemo.ScrollBar.MaxPos + FMemo.Height;
  FMemo.Height := 2000;
  FMemo.Height := Tall;
  Fits := FMemo.ScrollBar.MaxPos;
  AssertEquals('The same height of text with and without the bar', 0, Fits);
  AssertFalse(FMemo.ScrollBar.Visible);
end;

initialization
  RegisterTest(TTestMemoScroll);

end.
