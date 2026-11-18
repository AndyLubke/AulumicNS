unit AuAnim;

{ ==============================================================================
  AulumicNS - AuAnim
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  ---> AulumicNS: short animations of the GUI (hover fades, a sliding switch,
  gliding scroll positions, windows that fade in). An animated number is a
  TAuAnim record that lives in the control (a field); AnimTo starts its way to
  a new value, one timer for the whole program moves all running ones about
  60 times a second and has the owner repaint (or calls its step routine).

  Animations run only when AnimActive: the program's setting (AnimationsOn,
  Preferences > System) and Windows' own "Animation effects" setting, and
  not in a remote session. When they do not run, AnimTo sets the end value at
  once - so the code that uses a TAuAnim needs no second path. The debug tool
  modes (--shots, --touch-probe, --ui-bench) leave AnimationsOn off.

  A control must call AnimForget(Self) in its destructor (TAuControl does).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls;

type
  TAuAnim = record
    Value: Single;          // what is drawn
    FromV, ToV: Single;
    StartMs: Double;
    DurMs: Integer;
    Running: Boolean;
    Linear: Boolean;        // False: fast at first, slowing down (the default)
  end;
  PAuAnim = ^TAuAnim;

  { the highlight of the row under the pointer in a list: the row it moved to
    lights up, the one it left goes dark (one at a time; an older one is
    dark at once). An item is a row number or a pointer; HOT_NONE = none. }
  TAuHotFade = record
    Cur, Old: PtrInt;
    InA, OutA: TAuAnim;
    Ready: Boolean;
  end;

  { called for every step instead of Owner.Invalidate; ADone: the last one }
  TAuAnimStep = procedure(Sender: TObject; ADone: Boolean) of object;

const
  { durations (ms), after the ones Windows 11 uses }
  ANIM_FAST = 90;       // hover in
  ANIM_NORMAL = 160;    // hover out, switches, popups
  ANIM_SLOW = 240;      // pages, scrolling
  ANIM_DROP = 320;      // a window that comes down into its place

  HOT_NONE = -1;

var
  { the program's setting; off until the settings are loaded }
  AnimationsOn: Boolean = False;
  { --anim-slow=<factor> (debug): every animation that many times longer }
  AnimSlowFactor: Single = 1;

{ True when animations are shown (see the unit's header) }
function AnimActive: Boolean;
{ moves A to ATarget within AMs milliseconds; AOwner is invalidated at every
  step unless AOnStep is given. Without animations: the value at once, one
  step (ADone = True). }
procedure AnimTo(var A: TAuAnim; ATarget: Single; AMs: Integer; AOwner: TControl; AOnStep: TAuAnimStep = nil);
{ the row under the pointer is AItem now (call it whenever it may have
  changed, also from the paint: nothing happens when it is the same) }
procedure HotSet(var H: TAuHotFade; AItem: PtrInt; AOwner: TControl);
{ how bright AItem's highlight is: 0 .. 1 }
function HotLevel(const H: TAuHotFade; AItem: PtrInt): Single;
{ sets the value without a step and stops the animation }
procedure AnimSet(var A: TAuAnim; AValue: Single);
{ where A is going (its value when it is not running) }
function AnimTarget(const A: TAuAnim): Single;
{ stops every animation of this owner (it is being destroyed) }
procedure AnimForget(AOwner: TObject);
function AnimNowMs: Double;
function EaseOut(T: Single): Single;

implementation

uses
  Windows, ExtCtrls;

type
  TAnimItem = class
    P: PAuAnim;
    Owner: TControl;
    OnStep: TAuAnimStep;
  end;

  TAnimator = class
  private
    FItems: TList;
    FTimer: TTimer;
    procedure Tick(Sender: TObject);
  public
    constructor Create;
    destructor Destroy; override;
    function Find(P: PAuAnim): TAnimItem;
    procedure Add(P: PAuAnim; AOwner: TControl; AOnStep: TAuAnimStep);
    procedure Remove(P: PAuAnim);
    procedure Forget(AOwner: TObject);
  end;

var
  Animator: TAnimator = nil;
  SysChecked: QWord = 0;
  SysOn: Boolean = True;
  Freq: Int64 = 0;

function AnimNowMs: Double;
var
  C: Int64;
begin
  if Freq = 0 then QueryPerformanceFrequency(Freq);
  QueryPerformanceCounter(C);
  Result := C * 1000.0 / Freq;
end;

function EaseOut(T: Single): Single;
begin
  if T <= 0 then Exit(0);
  if T >= 1 then Exit(1);
  T := 1 - T;
  Result := 1 - T * T * T;
end;

function AnimActive: Boolean;
const
  SPI_GETCLIENTAREAANIMATION = $1042;
var
  B: BOOL;
  Now: QWord;
begin
  if not AnimationsOn then Exit(False);
  Now := GetTickCount64;
  if (SysChecked = 0) or (Now - SysChecked > 2000) then
  begin
    SysChecked := Now;
    B := True;
    if not SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, @B, 0) then B := True;
    SysOn := B and (GetSystemMetrics(SM_REMOTESESSION) = 0);
  end;
  Result := SysOn;
end;

{ TAnimator }

constructor TAnimator.Create;
begin
  inherited Create;
  FItems := TList.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := 10;
  FTimer.OnTimer := @Tick;
end;

destructor TAnimator.Destroy;
var
  I: Integer;
begin
  FTimer.Free;
  for I := 0 to FItems.Count - 1 do TAnimItem(FItems[I]).Free;
  FItems.Free;
  inherited Destroy;
end;

function TAnimator.Find(P: PAuAnim): TAnimItem;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if TAnimItem(FItems[I]).P = P then Exit(TAnimItem(FItems[I]));
  Result := nil;
end;

procedure TAnimator.Add(P: PAuAnim; AOwner: TControl; AOnStep: TAuAnimStep);
var
  It: TAnimItem;
begin
  It := Find(P);
  if It = nil then
  begin
    It := TAnimItem.Create;
    It.P := P;
    FItems.Add(It);
  end;
  It.Owner := AOwner;
  It.OnStep := AOnStep;
  FTimer.Enabled := True;
end;

procedure TAnimator.Remove(P: PAuAnim);
var
  It: TAnimItem;
begin
  It := Find(P);
  if It = nil then Exit;
  FItems.Remove(It);
  It.Free;
end;

procedure TAnimator.Forget(AOwner: TObject);
var
  I: Integer;
  It: TAnimItem;
begin
  for I := FItems.Count - 1 downto 0 do
  begin
    It := TAnimItem(FItems[I]);
    if (It.Owner = AOwner) or (TMethod(It.OnStep).Data = Pointer(AOwner)) then
    begin
      It.P^.Running := False;
      FItems.Delete(I);
      It.Free;
    end;
  end;
end;

procedure TAnimator.Tick(Sender: TObject);
var
  Snap: array of TAnimItem;
  I: Integer;
  It: TAnimItem;
  Now: Double;
  T: Single;
  Done: Boolean;
  Owner: TControl;
  Step: TAuAnimStep;
begin
  { a step routine may start or stop animations: work on a copy and look
    whether an item is still there before touching it }
  Snap := nil;
  SetLength(Snap, FItems.Count);
  for I := 0 to FItems.Count - 1 do Snap[I] := TAnimItem(FItems[I]);
  Now := AnimNowMs;
  for I := 0 to High(Snap) do
  begin
    It := Snap[I];
    if FItems.IndexOf(It) < 0 then Continue;
    if It.P^.DurMs <= 0 then T := 1
    else T := (Now - It.P^.StartMs) / It.P^.DurMs;
    Done := T >= 1;
    if Done then It.P^.Value := It.P^.ToV
    else
    begin
      if not It.P^.Linear then T := EaseOut(T);
      It.P^.Value := It.P^.FromV + (It.P^.ToV - It.P^.FromV) * T;
    end;
    Owner := It.Owner;
    Step := It.OnStep;
    if Done then
    begin
      It.P^.Running := False;
      FItems.Remove(It);
      It.Free;
    end;
    if Assigned(Step) then Step(Owner, Done)
    else if Owner <> nil then Owner.Invalidate;
  end;
  if FItems.Count = 0 then FTimer.Enabled := False;
end;

procedure AnimTo(var A: TAuAnim; ATarget: Single; AMs: Integer; AOwner: TControl; AOnStep: TAuAnimStep);
begin
  if A.Running and (A.ToV = ATarget) then Exit;
  if not A.Running and (A.Value = ATarget) then Exit;
  if (AMs <= 0) or not AnimActive then
  begin
    if A.Running and (Animator <> nil) then Animator.Remove(@A);
    A.Running := False;
    A.Value := ATarget;
    A.ToV := ATarget;
    if Assigned(AOnStep) then AOnStep(AOwner, True)
    else if AOwner <> nil then AOwner.Invalidate;
    Exit;
  end;
  A.FromV := A.Value;
  A.ToV := ATarget;
  A.StartMs := AnimNowMs;
  A.DurMs := Round(AMs * AnimSlowFactor);
  A.Running := True;
  if Animator = nil then Animator := TAnimator.Create;
  Animator.Add(@A, AOwner, AOnStep);
end;

procedure AnimSet(var A: TAuAnim; AValue: Single);
begin
  if A.Running and (Animator <> nil) then Animator.Remove(@A);
  A.Running := False;
  A.Value := AValue;
  A.ToV := AValue;
end;

function AnimTarget(const A: TAuAnim): Single;
begin
  if A.Running then Result := A.ToV else Result := A.Value;
end;

procedure HotSet(var H: TAuHotFade; AItem: PtrInt; AOwner: TControl);
var
  Level: Single;
begin
  { a record that was never set (all zero) starts with no item }
  if not H.Ready then
  begin
    H.Cur := HOT_NONE;
    H.Old := HOT_NONE;
    H.Ready := True;
  end;
  if AItem = H.Cur then Exit;
  Level := H.InA.Value;
  H.Old := H.Cur;
  H.Cur := AItem;
  AnimSet(H.OutA, Level);
  AnimSet(H.InA, 0);
  if H.Old <> HOT_NONE then AnimTo(H.OutA, 0, ANIM_NORMAL, AOwner);
  if H.Cur <> HOT_NONE then AnimTo(H.InA, 1, ANIM_FAST, AOwner);
end;

function HotLevel(const H: TAuHotFade; AItem: PtrInt): Single;
begin
  if (AItem = HOT_NONE) or not H.Ready then Result := 0
  else if AItem = H.Cur then Result := H.InA.Value
  else if AItem = H.Old then Result := H.OutA.Value
  else Result := 0;
end;

procedure AnimForget(AOwner: TObject);
begin
  if Animator <> nil then Animator.Forget(AOwner);
end;

finalization
  FreeAndNil(Animator);

end.
