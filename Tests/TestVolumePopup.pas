unit TestVolumePopup;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestVolumePopup
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The volume popup frees itself when it closes (TAuPopup: caFree), after it
  has called OnClosed. The main window forgets its popup there
  (TMainForm.VolumePopupClosed); if it kept the freed one, the next
  click on the volume button would use it (an access violation).
  Opened and closed a few times, as the button does.
  =============================================================================}

interface

uses
  Classes, SysUtils, Forms, fpcunit, testregistry, AuVolumePopup;

type
  TTestVolumePopup = class(TTestCase)
  private
    FPopup: TVolumePopup;      // as TMainForm.FVolPopup
    FClosedCalls: Integer;
    procedure PopupClosed(Sender: TObject);
  published
    procedure ClosedPopupIsFreedAfterOnClosed;
  end;

implementation

type
  { notices when the popup is freed }
  TFreeWatch = class(TComponent)
  public
    Freed: Boolean;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  end;

procedure TFreeWatch.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if Operation = opRemove then Freed := True;
end;

procedure TTestVolumePopup.PopupClosed(Sender: TObject);
begin
  Inc(FClosedCalls);
  if FPopup = Sender then FPopup := nil;
end;

procedure TTestVolumePopup.ClosedPopupIsFreedAfterOnClosed;
var
  Round_, Wait: Integer;
  Watch: TFreeWatch;
begin
  Watch := TFreeWatch.Create(nil);
  try
    for Round_ := 1 to 5 do
    begin
      Watch.Freed := False;
      FClosedCalls := 0;
      AssertTrue(Format('Round %d: no popup kept', [Round_]), FPopup = nil);
      FPopup := TVolumePopup.CreateVolume(nil);
      FPopup.OnClosed := @PopupClosed;
      FPopup.FreeNotification(Watch);
      FPopup.Setup(0.5, False, False, '');
      FPopup.ShowAt(40, 40, 306, 78);
      Application.ProcessMessages;
      AssertTrue(Format('Round %d: shown', [Round_]), (FPopup <> nil) and FPopup.Visible);
      FPopup.CloseTree;
      AssertEquals(Format('Round %d: OnClosed once', [Round_]), 1, FClosedCalls);
      AssertTrue(Format('Round %d: forgotten in OnClosed', [Round_]), FPopup = nil);
      { the LCL frees a caFree form a moment later (Release) }
      Wait := 0;
      while not Watch.Freed and (Wait < 200) do
      begin
        Application.ProcessMessages;
        Sleep(5);
        Inc(Wait);
      end;
      AssertTrue(Format('Round %d: the popup freed itself', [Round_]), Watch.Freed);
    end;
  finally
    if FPopup <> nil then FreeAndNil(FPopup);
    Watch.Free;
  end;
end;

initialization
  RegisterTest(TTestVolumePopup);

end.
