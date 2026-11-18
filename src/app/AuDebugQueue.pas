unit AuDebugQueue;

{ The Debug Queue window (Aulumic's uDebugQueue, Main menu > Tools > Show
  Debug Queue, Ctrl+D): the play queue of the playback manager in play
  order (shuffled when shuffle is on), the playing track highlighted and
  kept in view. The title shows the state, the index and the count. Stays
  on top, not modal; Esc or Ctrl+D closes it. Refreshes every 500 ms, the
  list only when the queue changed (QueueRevision). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Forms, ExtCtrls, LCLType,
  AuGfx, AuTheme, AuControls, AuLists, AuForms, uPlaybackManager;

function ShowDebugQueue(AOwner: TComponent; AManager: TPlaybackManager): TAuForm;
{ closes the window (before the playback manager is freed) }
procedure CloseDebugQueue;
function DebugQueueVisible: Boolean;

implementation

uses
  uAppConsts;

type
  { TDebugQueueForm }

  TDebugQueueForm = class(TAuForm)
  private
    FList: TAuListView;
    FItems: TStringList;
    FTimer: TTimer;
    FManager: TPlaybackManager;
    FLastRevision, FLastIndex: Integer;
    procedure TimerTick(Sender: TObject);
    procedure GetCell(Sender: TObject; Row, Col: Integer; var AText: string);
    procedure RowStyle(Sender: TObject; Row: Integer; var ABold: Boolean; var AColor: TARGB);
    procedure ScrollToCurrent;
  protected
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateQueue(AOwner: TComponent; AManager: TPlaybackManager);
    destructor Destroy; override;
  end;

var
  GQueueForm: TDebugQueueForm = nil;

function ShowDebugQueue(AOwner: TComponent; AManager: TPlaybackManager): TAuForm;
begin
  Result := nil;
  if AManager = nil then Exit;
  if GQueueForm = nil then GQueueForm := TDebugQueueForm.CreateQueue(AOwner, AManager);
  GQueueForm.Show;
  GQueueForm.BringToFront;
  Result := GQueueForm;
end;

procedure CloseDebugQueue;
begin
  FreeAndNil(GQueueForm);
end;

function DebugQueueVisible: Boolean;
begin
  Result := (GQueueForm <> nil) and GQueueForm.Visible;
end;

{ ---- TDebugQueueForm ---- }

constructor TDebugQueueForm.CreateQueue(AOwner: TComponent; AManager: TPlaybackManager);
begin
  CreateAu(AOwner, 'Debug Queue', FORM_DEBUG_WIDTH, FORM_DEBUG_HEIGHT);
  HelpKeyword := 'Log files & troubleshooting';
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];      // the LCL gives a sizeable window all buttons
  FormStyle := fsStayOnTop;
  Constraints.MinWidth := S(260);
  Constraints.MinHeight := S(200);
  FitToWorkArea;          // ---> AulumicNS: a small screen at a large scaling
  FManager := AManager;
  FLastRevision := -1;
  FLastIndex := -2;
  FItems := TStringList.Create;
  FList := TAuListView.Create(Self);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.BorderSpacing.Around := S(10);
  FList.ShowHeader := False;
  FList.MultiSelect := False;
  FList.RowMenu := False;
  FList.AutoFit := True;
  FList.RowHeight := S(26);
  FList.AddColumn('Track', 200, 0, True);
  FList.EmptyText := 'The play queue is empty.';
  FList.OnGetCell := @GetCell;
  FList.OnRowStyle := @RowStyle;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := DEBUG_QUEUE_INTERVAL_MS;
  FTimer.OnTimer := @TimerTick;
  TimerTick(nil);
  FTimer.Enabled := True;
end;

destructor TDebugQueueForm.Destroy;
begin
  if FTimer <> nil then
  begin
    FTimer.Enabled := False;
    FTimer.OnTimer := nil;
  end;
  if GQueueForm = Self then GQueueForm := nil;
  FItems.Free;
  inherited Destroy;
end;

procedure TDebugQueueForm.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  FTimer.Enabled := False;
  CloseAction := caFree;
end;

procedure TDebugQueueForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = Ord('D')) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    Close;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TDebugQueueForm.Resize;
begin
  inherited Resize;
  if FList <> nil then ScrollToCurrent;
end;

procedure TDebugQueueForm.GetCell(Sender: TObject; Row, Col: Integer; var AText: string);
begin
  if (Row >= 0) and (Row < FItems.Count) then AText := FItems[Row];
end;

procedure TDebugQueueForm.RowStyle(Sender: TObject; Row: Integer; var ABold: Boolean; var AColor: TARGB);
begin
  if Row = FLastIndex then
  begin
    ABold := True;
    AColor := clAccentText;
  end;
end;

{ the playing track in the middle of the list }
procedure TDebugQueueForm.ScrollToCurrent;
var
  T: Integer;
begin
  if (FLastIndex < 0) or (FLastIndex >= FList.RowCount) then Exit;
  T := Math.Max(0, FLastIndex - FList.PageRows div 2);
  FList.EnsureVisible(Math.Min(FList.RowCount - 1, T + FList.PageRows - 1));
  FList.EnsureVisible(T);
end;

procedure TDebugQueueForm.TimerTick(Sender: TObject);
var
  Idx, Rev, N: Integer;
  Cap: string;
begin
  if FManager = nil then Exit;
  Idx := FManager.CurrentIndex;
  Rev := FManager.QueueRevision;
  N := FManager.QueueCount;
  case FManager.State of
    psPlaying: Cap := Format('Debug: Playing [Index: %d / Total: %d]', [Idx, N]);
    psPaused: Cap := Format('Debug: Paused [Index: %d / Total: %d]', [Idx, N]);
    psMaintenance: Cap := Format('Debug: Maintenance [Index: %d / Total: %d]', [Idx, N]);
  else
    Cap := Format('Debug: Stopped [Total: %d]', [N]);
  end;
  if Caption <> Cap then Caption := Cap;
  { the revision changes when the queue is rebuilt (e.g. shuffle switched) }
  if Rev <> FLastRevision then
  begin
    FManager.GetQueueSnapshot(FItems, Idx);
    FLastRevision := Rev;
    FLastIndex := Idx;
    FList.RowCount := FItems.Count;
    ScrollToCurrent;
    FList.Invalidate;
  end
  else if Idx <> FLastIndex then
  begin
    FLastIndex := Idx;
    ScrollToCurrent;
    FList.Invalidate;
  end;
end;

end.
