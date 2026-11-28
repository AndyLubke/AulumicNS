{ =============================================================================
  AulumicNS tests - TestTabOrder
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Tab key goes through a window as the window reads. A message box builds
  its buttons from the right edge, the help window builds its bottom line
  first: both set the order themselves.
  =============================================================================}
unit TestTabOrder;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, fpcunit, testregistry,
  AuControls, AuForms, AuHelp;

type
  TTestTabOrder = class(TTestCase)
  private
    function ButtonsInTabOrder(AParent: TWinControl): string;
  published
    procedure AMessageBoxGoesFromLeftToRight;
    procedure TheHelpEndsAtItsBottomLine;
  end;

implementation

{ the captions of the buttons on AParent in the order of the Tab key, joined
  by ' > ' }
function TTestTabOrder.ButtonsInTabOrder(AParent: TWinControl): string;
var
  L: TFPList;
  I: Integer;
begin
  Result := '';
  L := TFPList.Create;
  try
    AParent.GetTabOrderList(L);
    for I := 0 to L.Count - 1 do
      if TObject(L[I]) is TAuButton then
      begin
        if Result <> '' then Result := Result + ' > ';
        Result := Result + TAuButton(L[I]).Caption;
      end;
  finally
    L.Free;
  end;
end;

procedure TTestTabOrder.AMessageBoxGoesFromLeftToRight;
var
  F: TAuForm;
begin
  F := CreateMessageForm('Save the changes?', amInfo, abYesNoCancel, 'Test');
  try
    AssertEquals('Yes > No > Cancel', ButtonsInTabOrder(F.Body));
    AssertTrue('the default button has the focus', F.ActiveControl = F.DefaultButton);
    AssertEquals('Yes', F.DefaultButton.Caption);
  finally
    F.Free;
  end;
  F := CreateMessageForm('Go on?', amInfo, abOKCancel, 'Test');
  try
    AssertEquals('OK > Cancel', ButtonsInTabOrder(F.Body));
  finally
    F.Free;
  end;
end;

procedure TTestTabOrder.TheHelpEndsAtItsBottomLine;
var
  F: TAuForm;
  L: TFPList;
  I, FirstButton, LastOther: Integer;
begin
  F := CreateHelpForm(nil, '');
  try
    AssertEquals('the bottom line from left to right', 'A+ > A- > Close', ButtonsInTabOrder(F.Body));
    { every other control comes before the first of these buttons }
    L := TFPList.Create;
    try
      F.Body.GetTabOrderList(L);
      FirstButton := -1;
      LastOther := -1;
      for I := 0 to L.Count - 1 do
        if TObject(L[I]) is TAuButton then
        begin
          if FirstButton < 0 then FirstButton := I;
        end
        else if TWinControl(L[I]).TabStop then LastOther := I;
      AssertTrue('search box, topics and text exist', LastOther >= 2);
      AssertTrue('and come before the bottom line', LastOther < FirstButton);
    finally
      L.Free;
    end;
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TTestTabOrder);

end.
