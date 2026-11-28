unit AuTree;

{ ==============================================================================
  AulumicNS - AuTree
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  TAuTreeView - owner-drawn tree for the library pane.
  Nodes are small objects owned by the tree;
  their children can be loaded lazily (OnExpanding) so that a library with
  tens of thousands of folders opens instantly. Features: multi-selection,
  accordion mode, dimmed (unavailable) and accent (category) nodes, a three
  dots row menu for touch screens, type-ahead search, Ctrl + mouse wheel
  text size and dragging the selection to another control (LCL drag and
  drop: the target receives this tree as Source).
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, LCLType, LazUTF8,
  AuGfx, AuAnim, AuTheme, AuIcons, AuControls;

type
  TAuTreeView = class;

  { TAuTreeNode }

  TAuTreeNode = class
  private
    FTree: TAuTreeView;
    FParent: TAuTreeNode;
    FChildren: TFPList;
    FExpanded: Boolean;
    function GetChild(I: Integer): TAuTreeNode;
    function GetCount: Integer;
    function GetLevel: Integer;
    procedure SetExpanded(V: Boolean);
  public
    Caption: string;
    { free text fields for the owner (the library: the name a node stands
      for, its folder / file, the parent's filter); freed with the node }
    Text, Path, Filter: string;
    Icon: TAuIcon;
    Data: Pointer;
    Tag: PtrInt;
    Kind: Integer;              // free for the owner (node type)
    Dim: Boolean;               // drawn faint (e.g. a folder on a missing drive)
    Accent: Boolean;            // drawn in the accent colour (category roots)
    Bold: Boolean;
    HasChildren: Boolean;       // show an expander before the children are loaded
    ChildrenLoaded: Boolean;    // OnExpanding has filled the children
    Selected: Boolean;
    constructor Create(ATree: TAuTreeView; AParent: TAuTreeNode);
    destructor Destroy; override;
    function AddChild(const ACaption: string; AIcon: TAuIcon = icNone): TAuTreeNode;
    procedure DeleteChildren;
    function IndexInParent: Integer;
    function CanExpand: Boolean;
    property Parent: TAuTreeNode read FParent;
    property Count: Integer read GetCount;
    property Children[I: Integer]: TAuTreeNode read GetChild; default;
    property Expanded: Boolean read FExpanded write SetExpanded;
    property Level: Integer read GetLevel;
  end;

  TAuTreeNodeEvent = procedure(Sender: TObject; Node: TAuTreeNode) of object;
  TAuTreeActivateEvent = procedure(Sender: TObject; Node: TAuTreeNode; var Handled: Boolean) of object;
  TAuTreeContextEvent = procedure(Sender: TObject; Node: TAuTreeNode; ScreenPt: TPoint) of object;
  TAuTreeNodeArray = array of TAuTreeNode;

  { TAuTreeView }

  TAuTreeView = class(TAuControl)
  private
    FRoot: TAuTreeNode;
    FRows: array of TAuTreeNode;
    FRowsDirty: Boolean;
    FScroll: TAuScrollBar;
    FTop, FRowH: Integer;
    FFocus, FAnchor, FHoverNode: TAuTreeNode;
    FHot: TAuHotFade;                  // the hover highlight fading from row to row
    FHoverMenu: Boolean;
    FDownNode: TAuTreeNode;
    FDownPt: TPoint;
    FDownOnSelected, FDragArmed: Boolean;
    FTextSize: Single;
    FAccordion, FMultiSelect, FRowMenu, FDragEnabled: Boolean;
    FEmptyText: string;
    FTypeText: string;
    FTypeTick: QWord;
    FUpdating: Integer;
    FOnExpanding, FOnCollapsed, FOnExpanded: TAuTreeNodeEvent;
    FOnActivate: TAuTreeActivateEvent;
    FOnSelChange, FOnTextSizeChange: TNotifyEvent;
    FOnNodeContext: TAuTreeContextEvent;
    procedure ScrollChanged(Sender: TObject);
    procedure BuildRows;
    procedure NeedRows;
    function RowCount: Integer;
    function RowOf(N: TAuTreeNode): Integer;
    function RowAt(Y: Integer): Integer;
    function VisibleRows: Integer;
    function ViewW: Integer;
    function Indent: Integer;
    function ExpanderX(N: TAuTreeNode): Integer;
    function InExpander(N: TAuTreeNode; X: Integer): Boolean;
    function InMenuButton(X: Integer): Boolean;
    function MenuGutter: Integer;
    procedure UpdateScroll;
    procedure UpdateRowHeight;
    procedure SetTextSize(V: Single);
    procedure SetTopRow(V: Integer);
    procedure SelectRangeRows(A, B: Integer; Add: Boolean);
    procedure ClearSelectionQuiet;
    procedure MoveFocusRow(R: Integer; Shift: TShiftState);
    procedure DoSelChange;
    procedure TypeAhead(const Ch: string);
    procedure NodeExpandChanged(N: TAuTreeNode);
    procedure NodeRemoved(N: TAuTreeNode);
    procedure CollapseSiblings(N: TAuTreeNode);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    function PanBy(DX, DY: Integer): Boolean; override;   // touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DpiChanged; override;
    procedure BeginUpdate;
    procedure EndUpdate;
    procedure Clear;
    function AddRoot(const ACaption: string; AIcon: TAuIcon = icNone): TAuTreeNode;
    function RootCount: Integer;
    function Roots(I: Integer): TAuTreeNode;
    procedure Changed;
    procedure Expand(N: TAuTreeNode);
    procedure Collapse(N: TAuTreeNode);
    procedure Toggle(N: TAuTreeNode);
    procedure CollapseAll;
    { expands the parents, scrolls the node into view }
    procedure MakeVisible(N: TAuTreeNode);
    { the node in the first row shown (nil: no rows) }
    function TopNode: TAuTreeNode;
    { the node's row becomes the first row shown, as far as the rows below
      it allow; False: the node is in no row (a parent is closed) }
    function ScrollNodeToTop(N: TAuTreeNode): Boolean;
    procedure SelectNode(N: TAuTreeNode);
    procedure ClearSelection;
    function SelectedNodes: TAuTreeNodeArray;
    function SelCount: Integer;
    { the captions from the root to the node, joined by #1 (to restore the
      selection after a restart) }
    function NodePath(N: TAuTreeNode): string;
    function FindPath(const APath: string; LoadChildren: Boolean): TAuTreeNode;
    function NodeAtPoint(X, Y: Integer): TAuTreeNode;
    function NodeRect(N: TAuTreeNode): TRect;
    property FocusedNode: TAuTreeNode read FFocus;
    property TextSize: Single read FTextSize write SetTextSize;
    property RowHeight: Integer read FRowH;
    { the first row shown (the scroll position) }
    property TopRow: Integer read FTop write SetTopRow;
    property Accordion: Boolean read FAccordion write FAccordion;
    property MultiSelect: Boolean read FMultiSelect write FMultiSelect;
    property RowMenu: Boolean read FRowMenu write FRowMenu;
    property DragEnabled: Boolean read FDragEnabled write FDragEnabled;
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnExpanding: TAuTreeNodeEvent read FOnExpanding write FOnExpanding;
    property OnExpanded: TAuTreeNodeEvent read FOnExpanded write FOnExpanded;
    property OnCollapsed: TAuTreeNodeEvent read FOnCollapsed write FOnCollapsed;
    property OnActivate: TAuTreeActivateEvent read FOnActivate write FOnActivate;
    property OnSelChange: TNotifyEvent read FOnSelChange write FOnSelChange;
    property OnNodeContext: TAuTreeContextEvent read FOnNodeContext write FOnNodeContext;
    property OnTextSizeChange: TNotifyEvent read FOnTextSizeChange write FOnTextSizeChange;
  end;

implementation

{ ---- TAuTreeNode ---- }

constructor TAuTreeNode.Create(ATree: TAuTreeView; AParent: TAuTreeNode);
begin
  inherited Create;
  FTree := ATree;
  FParent := AParent;
  FChildren := TFPList.Create;
end;

destructor TAuTreeNode.Destroy;
begin
  DeleteChildren;
  FChildren.Free;
  inherited Destroy;
end;

function TAuTreeNode.GetChild(I: Integer): TAuTreeNode;
begin
  Result := TAuTreeNode(FChildren[I]);
end;

function TAuTreeNode.GetCount: Integer;
begin
  Result := FChildren.Count;
end;

function TAuTreeNode.GetLevel: Integer;
var
  P: TAuTreeNode;
begin
  Result := -1;
  P := FParent;
  while P <> nil do
  begin
    Inc(Result);
    P := P.FParent;
  end;
end;

procedure TAuTreeNode.SetExpanded(V: Boolean);
begin
  if V then FTree.Expand(Self) else FTree.Collapse(Self);
end;

function TAuTreeNode.AddChild(const ACaption: string; AIcon: TAuIcon): TAuTreeNode;
begin
  Result := TAuTreeNode.Create(FTree, Self);
  Result.Caption := ACaption;
  Result.Icon := AIcon;
  FChildren.Add(Result);
  ChildrenLoaded := True;
  if FTree <> nil then FTree.FRowsDirty := True;
end;

procedure TAuTreeNode.DeleteChildren;
var
  I: Integer;
  C: TAuTreeNode;
begin
  for I := FChildren.Count - 1 downto 0 do
  begin
    C := TAuTreeNode(FChildren[I]);
    if FTree <> nil then FTree.NodeRemoved(C);
    C.Free;
  end;
  FChildren.Clear;
  if FTree <> nil then FTree.FRowsDirty := True;
end;

function TAuTreeNode.IndexInParent: Integer;
begin
  if FParent = nil then Result := -1 else Result := FParent.FChildren.IndexOf(Self);
end;

function TAuTreeNode.CanExpand: Boolean;
begin
  Result := (FChildren.Count > 0) or (HasChildren and not ChildrenLoaded);
end;

{ ---- TAuTreeView ---- }

constructor TAuTreeView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FGpuPaint := True;
  FWantKeys := True;
  TabStop := True;
  FRoot := TAuTreeNode.Create(Self, nil);
  FRoot.FExpanded := True;
  FRoot.ChildrenLoaded := True;
  FTextSize := 13;
  FMultiSelect := True;
  FRowMenu := True;
  FRowsDirty := True;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Visible := False;
  FScroll.OnScroll := @ScrollChanged;
  UpdateRowHeight;
end;

destructor TAuTreeView.Destroy;
begin
  FFocus := nil;
  FAnchor := nil;
  FHoverNode := nil;
  FDownNode := nil;
  FRoot.Free;
  FRoot := nil;
  inherited Destroy;
end;

procedure TAuTreeView.NodeRemoved(N: TAuTreeNode);
var
  I: Integer;
begin
  { a removed node (or one of its children) must not stay referenced }
  for I := 0 to N.Count - 1 do NodeRemoved(N.Children[I]);
  if FFocus = N then FFocus := nil;
  if FAnchor = N then FAnchor := nil;
  if FHoverNode = N then FHoverNode := nil;
  if FDownNode = N then FDownNode := nil;
end;

procedure TAuTreeView.UpdateRowHeight;
begin
  FRowH := Math.Max(S(18), Round(SF(FTextSize * FontScale) * 2.05 * RowDensity));
end;

procedure TAuTreeView.SetTextSize(V: Single);
begin
  V := EnsureRange(V, 8, 28);
  if V = FTextSize then Exit;
  FTextSize := V;
  UpdateRowHeight;
  UpdateScroll;
  Invalidate;
end;

procedure TAuTreeView.SetTopRow(V: Integer);
begin
  UpdateScroll;
  FScroll.Position := Math.Max(0, V);
  FTop := FScroll.Position;
  Invalidate;
end;

procedure TAuTreeView.ScaleCached(K: Double);
begin
  UpdateRowHeight;
end;

procedure TAuTreeView.DpiChanged;
begin
  UpdateRowHeight;
  inherited DpiChanged;
end;

procedure TAuTreeView.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure TAuTreeView.EndUpdate;
begin
  if FUpdating > 0 then Dec(FUpdating);
  if FUpdating = 0 then Changed;
end;

procedure TAuTreeView.Clear;
begin
  FRoot.DeleteChildren;
  FFocus := nil;
  FAnchor := nil;
  FHoverNode := nil;
  FDownNode := nil;
  FRowsDirty := True;
  if FUpdating = 0 then Changed;
end;

function TAuTreeView.AddRoot(const ACaption: string; AIcon: TAuIcon): TAuTreeNode;
begin
  Result := FRoot.AddChild(ACaption, AIcon);
end;

function TAuTreeView.RootCount: Integer;
begin
  Result := FRoot.Count;
end;

function TAuTreeView.Roots(I: Integer): TAuTreeNode;
begin
  Result := FRoot.Children[I];
end;

procedure TAuTreeView.Changed;
begin
  FRowsDirty := True;
  if FUpdating > 0 then Exit;
  UpdateScroll;
  Invalidate;
end;

procedure TAuTreeView.BuildRows;
var
  N: Integer;

  procedure Walk(P: TAuTreeNode);
  var
    I: Integer;
    C: TAuTreeNode;
  begin
    for I := 0 to P.Count - 1 do
    begin
      C := P.Children[I];
      if N >= Length(FRows) then SetLength(FRows, Math.Max(64, Length(FRows) * 2));
      FRows[N] := C;
      Inc(N);
      if C.FExpanded and (C.Count > 0) then Walk(C);
    end;
  end;

begin
  N := 0;
  Walk(FRoot);
  SetLength(FRows, N);
  FRowsDirty := False;
end;

procedure TAuTreeView.NeedRows;
begin
  if FRowsDirty then BuildRows;
end;

function TAuTreeView.RowCount: Integer;
begin
  NeedRows;
  Result := Length(FRows);
end;

function TAuTreeView.RowOf(N: TAuTreeNode): Integer;
var
  I: Integer;
begin
  NeedRows;
  if N <> nil then
    for I := 0 to High(FRows) do
      if FRows[I] = N then Exit(I);
  Result := -1;
end;

function TAuTreeView.VisibleRows: Integer;
begin
  Result := Math.Max(1, ClientHeight div Math.Max(1, FRowH));
end;

function TAuTreeView.ViewW: Integer;
begin
  Result := ClientWidth;
  if FScroll.Visible then Dec(Result, FScroll.Width);
end;

function TAuTreeView.RowAt(Y: Integer): Integer;
begin
  if (Y < 0) or (FRowH <= 0) then Exit(-1);
  Result := FTop + Y div FRowH;
  if Result >= RowCount then Result := -1;
end;

function TAuTreeView.Indent: Integer;
begin
  Result := Math.Max(S(14), Round(FRowH * 0.72));
end;

function TAuTreeView.ExpanderX(N: TAuTreeNode): Integer;
begin
  Result := S(6) + N.Level * Indent;
end;

function TAuTreeView.InExpander(N: TAuTreeNode; X: Integer): Boolean;
var
  EX: Integer;
begin
  EX := ExpanderX(N);
  Result := N.CanExpand and (X >= EX - S(2)) and (X < EX + Indent);
end;

function TAuTreeView.MenuGutter: Integer;
begin
  if FRowMenu and Assigned(FOnNodeContext) then Result := S(34) else Result := 0;
end;

function TAuTreeView.InMenuButton(X: Integer): Boolean;
begin
  Result := (MenuGutter > 0) and (X >= ViewW - S(34)) and (X < ViewW - S(2));
end;

procedure TAuTreeView.UpdateScroll;
var
  NeedV: Boolean;
  SB, RC: Integer;
begin
  RC := RowCount;
  SB := S(12);
  NeedV := RC * FRowH > ClientHeight;
  FScroll.Visible := NeedV;
  FScroll.SetBounds(ClientWidth - SB, 0, SB, ClientHeight);
  FScroll.SetParams(RC, VisibleRows);
  FTop := FScroll.Position;
end;

procedure TAuTreeView.ScrollChanged(Sender: TObject);
begin
  FTop := FScroll.Position;
  Invalidate;
end;

procedure TAuTreeView.Resize;
begin
  inherited Resize;
  UpdateScroll;
end;

procedure TAuTreeView.NodeExpandChanged(N: TAuTreeNode);
begin
  FRowsDirty := True;
  if FUpdating = 0 then
  begin
    UpdateScroll;
    Invalidate;
  end;
end;

procedure TAuTreeView.CollapseSiblings(N: TAuTreeNode);
var
  P: TAuTreeNode;
  I: Integer;
begin
  P := N.Parent;
  if P = nil then Exit;
  for I := 0 to P.Count - 1 do
    if (P.Children[I] <> N) and P.Children[I].FExpanded then
    begin
      P.Children[I].FExpanded := False;
      if Assigned(FOnCollapsed) then FOnCollapsed(Self, P.Children[I]);
    end;
end;

procedure TAuTreeView.Expand(N: TAuTreeNode);
var
  R: Integer;
begin
  if (N = nil) or N.FExpanded then Exit;
  if not N.ChildrenLoaded then
  begin
    if Assigned(FOnExpanding) then FOnExpanding(Self, N);
    N.ChildrenLoaded := True;
  end;
  if N.Count = 0 then
  begin
    N.HasChildren := False;
    Invalidate;
    Exit;
  end;
  if FAccordion then CollapseSiblings(N);
  N.FExpanded := True;
  NodeExpandChanged(N);
  if Assigned(FOnExpanded) then FOnExpanded(Self, N);
  { show as many of the new children as fit - not inside an update: finding
    the row lists all rows again, once per node that is opened }
  if FUpdating > 0 then Exit;
  R := RowOf(N);
  if R >= 0 then
  begin
    if R + N.Count >= FTop + VisibleRows then
      FScroll.Position := Math.Min(R, R + N.Count - VisibleRows + 1);
    FTop := FScroll.Position;
  end;
end;

procedure TAuTreeView.Collapse(N: TAuTreeNode);
var
  P: TAuTreeNode;
begin
  if (N = nil) or not N.FExpanded then Exit;
  N.FExpanded := False;
  { a selected / focused node inside the collapsed branch moves to N }
  P := FFocus;
  while (P <> nil) and (P <> N) do P := P.Parent;
  if (P = N) and (FFocus <> N) then FFocus := N;
  NodeExpandChanged(N);
  if Assigned(FOnCollapsed) then FOnCollapsed(Self, N);
end;

procedure TAuTreeView.Toggle(N: TAuTreeNode);
begin
  if N = nil then Exit;
  if N.FExpanded then Collapse(N) else Expand(N);
end;

procedure TAuTreeView.CollapseAll;

  procedure Walk(P: TAuTreeNode);
  var
    I: Integer;
  begin
    for I := 0 to P.Count - 1 do
    begin
      P.Children[I].FExpanded := False;
      Walk(P.Children[I]);
    end;
  end;

begin
  Walk(FRoot);
  Changed;
end;

procedure TAuTreeView.MakeVisible(N: TAuTreeNode);
var
  P: TAuTreeNode;
  R: Integer;
begin
  if N = nil then Exit;
  P := N.Parent;
  while (P <> nil) and (P <> FRoot) do
  begin
    if not P.FExpanded then
    begin
      P.FExpanded := True;
      FRowsDirty := True;
    end;
    P := P.Parent;
  end;
  UpdateScroll;
  R := RowOf(N);
  if R < 0 then Exit;
  if R < FTop then FScroll.Position := R
  else if R >= FTop + VisibleRows then FScroll.Position := R - VisibleRows + 1;
  FTop := FScroll.Position;
  Invalidate;
end;

function TAuTreeView.TopNode: TAuTreeNode;
begin
  NeedRows;
  if (FTop >= 0) and (FTop <= High(FRows)) then Result := FRows[FTop] else Result := nil;
end;

function TAuTreeView.ScrollNodeToTop(N: TAuTreeNode): Boolean;
var
  R: Integer;
begin
  UpdateScroll;
  R := RowOf(N);
  Result := R >= 0;
  if not Result then Exit;
  FScroll.Position := R;
  FTop := FScroll.Position;
  Invalidate;
end;

procedure TAuTreeView.ClearSelectionQuiet;

  procedure Walk(P: TAuTreeNode);
  var
    I: Integer;
  begin
    for I := 0 to P.Count - 1 do
    begin
      P.Children[I].Selected := False;
      Walk(P.Children[I]);
    end;
  end;

begin
  Walk(FRoot);
end;

procedure TAuTreeView.ClearSelection;
begin
  ClearSelectionQuiet;
  Invalidate;
  DoSelChange;
end;

procedure TAuTreeView.SelectNode(N: TAuTreeNode);
begin
  ClearSelectionQuiet;
  if N <> nil then
  begin
    N.Selected := True;
    FFocus := N;
    FAnchor := N;
    MakeVisible(N);
  end;
  Invalidate;
  DoSelChange;
end;

function TAuTreeView.SelectedNodes: TAuTreeNodeArray;
var
  N: Integer;

  procedure Walk(P: TAuTreeNode);
  var
    I: Integer;
  begin
    for I := 0 to P.Count - 1 do
    begin
      if P.Children[I].Selected then
      begin
        if N >= Length(Result) then SetLength(Result, Math.Max(16, Length(Result) * 2));
        Result[N] := P.Children[I];
        Inc(N);
      end;
      Walk(P.Children[I]);
    end;
  end;

begin
  Result := nil;
  N := 0;
  Walk(FRoot);
  SetLength(Result, N);
end;

function TAuTreeView.SelCount: Integer;
begin
  Result := Length(SelectedNodes);
end;

procedure TAuTreeView.SelectRangeRows(A, B: Integer; Add: Boolean);
var
  I, T: Integer;
begin
  NeedRows;
  if not Add then ClearSelectionQuiet;
  if A > B then begin T := A; A := B; B := T; end;
  if A < 0 then A := 0;
  for I := A to Math.Min(B, High(FRows)) do FRows[I].Selected := True;
end;

procedure TAuTreeView.DoSelChange;
begin
  if Assigned(FOnSelChange) then FOnSelChange(Self);
end;

procedure TAuTreeView.MoveFocusRow(R: Integer; Shift: TShiftState);
var
  A: Integer;
begin
  if RowCount = 0 then Exit;
  R := EnsureRange(R, 0, RowCount - 1);
  FFocus := FRows[R];
  A := RowOf(FAnchor);
  if (ssShift in Shift) and FMultiSelect and (A >= 0) then
    SelectRangeRows(A, R, ssCtrl in Shift)
  else if not (ssCtrl in Shift) then
  begin
    SelectRangeRows(R, R, False);
    FAnchor := FFocus;
  end;
  MakeVisible(FFocus);
  DoSelChange;
end;

function TAuTreeView.NodePath(N: TAuTreeNode): string;
begin
  Result := '';
  while (N <> nil) and (N <> FRoot) do
  begin
    if Result = '' then Result := N.Caption else Result := N.Caption + #1 + Result;
    N := N.Parent;
  end;
end;

function TAuTreeView.FindPath(const APath: string; LoadChildren: Boolean): TAuTreeNode;
var
  Parts: TStringList;
  P, C: TAuTreeNode;
  I, J: Integer;
begin
  Result := nil;
  if APath = '' then Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := #1;
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := APath;
    P := FRoot;
    for I := 0 to Parts.Count - 1 do
    begin
      if (P <> FRoot) and not P.ChildrenLoaded and LoadChildren then
      begin
        if Assigned(FOnExpanding) then FOnExpanding(Self, P);
        P.ChildrenLoaded := True;
        FRowsDirty := True;
      end;
      C := nil;
      for J := 0 to P.Count - 1 do
        if P.Children[J].Caption = Parts[I] then
        begin
          C := P.Children[J];
          Break;
        end;
      if C = nil then Break;
      P := C;
      Result := C;
    end;
  finally
    Parts.Free;
  end;
end;

function TAuTreeView.NodeAtPoint(X, Y: Integer): TAuTreeNode;
var
  R: Integer;
begin
  R := RowAt(Y);
  if R < 0 then Result := nil else Result := FRows[R];
end;

function TAuTreeView.NodeRect(N: TAuTreeNode): TRect;
var
  R: Integer;
begin
  R := RowOf(N);
  if R < 0 then Exit(Rect(0, 0, 0, 0));
  Result := Rect(0, (R - FTop) * FRowH, ViewW, (R - FTop + 1) * FRowH);
end;

procedure TAuTreeView.DoPaint(G: TGfx);
var
  F, BF: TGfxFont;
  R, Y, VW, EX, TX: Integer;
  N: TAuTreeNode;
  Bg, Fg: TARGB;
  Sel, Foc: Boolean;
  IcSz: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  NeedRows;
  VW := ViewW;
  F := UIFont(FTextSize);
  BF := UIFont(FTextSize, True);
  Foc := Focused;
  if (Length(FRows) = 0) and (FEmptyText <> '') then
  begin
    G.Text(FEmptyText, S(16), 0, VW - S(32), ClientHeight, UIFont(13), clTextFaint, 1, 1, tfWrap);
    Exit;
  end;
  if FHoverNode = nil then HotSet(FHot, HOT_NONE, Self) else HotSet(FHot, PtrInt(FHoverNode), Self);
  IcSz := FRowH * 0.5;
  { while the wheel's glide runs the rows are still on their way: shifted by
    what is left of it, starting with the row that reaches into the top }
  Y := FScroll.GlideOffset;
  R := FTop;
  if (Y <> 0) and (FRowH > 0) then
  begin
    R := Math.Max(0, FTop + Floor(-Y / FRowH));
    Y := Y + (R - FTop) * FRowH;
  end;
  while (R <= High(FRows)) and (Y < ClientHeight) do
  begin
    N := FRows[R];
    Sel := N.Selected;
    Bg := 0;
    if Sel then
    begin
      if Foc then Bg := clSelection else Bg := clSelectionDim;
    end
    else if HotLevel(FHot, PtrInt(N)) > 0 then Bg := Blend(EffBack, clHover, HotLevel(FHot, PtrInt(N)));
    if Bg <> 0 then G.FillRound(S(4), Y + 1, VW - S(8), FRowH - 2, S(5), Bg);
    if Foc and KeyboardCues and (N = FFocus) then
      G.StrokeRound(S(4), Y + 1, VW - S(8), FRowH - 2, S(5), SF(1.5), clAccent);
    EX := ExpanderX(N);
    if N.CanExpand then
    begin
      if N.FExpanded then DrawIcon(G, icTriDown, EX + Indent / 2, Y + FRowH / 2, IcSz * 0.9, clTextDim)
      else DrawIcon(G, icTriRight, EX + Indent / 2, Y + FRowH / 2, IcSz * 0.9, clTextDim);
    end;
    TX := EX + Indent;
    if N.Dim then Fg := clTextFaint
    else if N.Accent then Fg := clAccentText
    else if Sel then Fg := clText
    else Fg := clText;
    if N.Icon <> icNone then
    begin
      if N.Dim then DrawIcon(G, N.Icon, TX + IcSz / 2 + S(1), Y + FRowH / 2, IcSz, clTextFaint)
      else if N.Accent then DrawIcon(G, N.Icon, TX + IcSz / 2 + S(1), Y + FRowH / 2, IcSz, clAccentText)
      else DrawIcon(G, N.Icon, TX + IcSz / 2 + S(1), Y + FRowH / 2, IcSz, clTextDim);
      Inc(TX, Round(IcSz) + S(7));
    end;
    if N.Bold or N.Accent then
      G.Text(N.Caption, TX, Y, VW - TX - MenuGutter - S(6), FRowH, BF, Fg, 0, 1)
    else
      G.Text(N.Caption, TX, Y, VW - TX - MenuGutter - S(6), FRowH, F, Fg, 0, 1);
    if (MenuGutter > 0) and (Sel or (N = FHoverNode)) then
    begin
      if Bg = 0 then Bg := EffBack;
      if (N = FHoverNode) and FHoverMenu then
        G.FillRound(VW - S(34), Y + S(2), S(30), FRowH - S(4), S(5), Blend(Bg, clText, 0.12));
      DrawIcon(G, icMore, VW - S(19), Y + FRowH / 2, Math.Min(S(16), FRowH * 0.7), clTextDim);
    end;
    Inc(Y, FRowH);
    Inc(R);
  end;
end;

procedure TAuTreeView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: Integer;
  N: TAuTreeNode;
begin
  inherited MouseDown(Button, Shift, X, Y);
  R := RowAt(Y);
  FDownNode := nil;
  FDragArmed := False;
  FDownOnSelected := False;
  if R < 0 then
  begin
    if (Button = mbLeft) and not (ssCtrl in Shift) then ClearSelection;
    Exit;
  end;
  N := FRows[R];
  { the three dots }
  if (Button = mbLeft) and InMenuButton(X) then
  begin
    if not N.Selected then
    begin
      SelectRangeRows(R, R, False);
      FAnchor := N;
    end;
    FFocus := N;
    Invalidate;
    DoSelChange;
    if Assigned(FOnNodeContext) then
      FOnNodeContext(Self, N, ClientToScreen(Point(ViewW - S(34), (R - FTop + 1) * FRowH)));
    Exit;
  end;
  if (Button = mbLeft) and InExpander(N, X) and not (ssShift in Shift) and not (ssCtrl in Shift) then
  begin
    Toggle(N);
    Exit;
  end;
  if Button = mbRight then
  begin
    if not N.Selected then
    begin
      SelectRangeRows(R, R, False);
      FAnchor := N;
    end;
    FFocus := N;
    Invalidate;
    DoSelChange;
    if Assigned(FOnNodeContext) then FOnNodeContext(Self, N, ClientToScreen(Point(X, Y)));
    Exit;
  end;
  if Button <> mbLeft then Exit;
  FFocus := N;
  FDownNode := N;
  FDownPt := Point(X, Y);
  if (ssShift in Shift) and FMultiSelect and (RowOf(FAnchor) >= 0) then
    SelectRangeRows(RowOf(FAnchor), R, ssCtrl in Shift)
  else if (ssCtrl in Shift) and FMultiSelect then
  begin
    N.Selected := not N.Selected;
    FAnchor := N;
  end
  else if N.Selected and (SelCount > 1) then
    FDownOnSelected := True           // keep the selection: maybe a drag starts
  else
  begin
    SelectRangeRows(R, R, False);
    FAnchor := N;
  end;
  FDragArmed := FDragEnabled and N.Selected;
  Invalidate;
  DoSelChange;
end;

procedure TAuTreeView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  R: Integer;
  N: TAuTreeNode;
  M: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragArmed and (ssLeft in Shift) and (FDownNode <> nil) and
     ((Abs(X - FDownPt.X) > S(6)) or (Abs(Y - FDownPt.Y) > S(6))) then
  begin
    FDragArmed := False;
    FDownOnSelected := False;
    BeginDrag(True);
    Exit;
  end;
  R := RowAt(Y);
  if R < 0 then N := nil else N := FRows[R];
  M := (N <> nil) and InMenuButton(X);
  if (N <> FHoverNode) or (M <> FHoverMenu) then
  begin
    FHoverNode := N;
    FHoverMenu := M;
    Invalidate;
  end;
end;

procedure TAuTreeView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  R := RowAt(Y);
  if FDownOnSelected and (R >= 0) and (FRows[R] = FDownNode) then
  begin
    SelectRangeRows(R, R, False);
    FAnchor := FDownNode;
    Invalidate;
    DoSelChange;
  end;
  FDownOnSelected := False;
  FDragArmed := False;
  FDownNode := nil;
end;

procedure TAuTreeView.MouseLeave;
begin
  inherited MouseLeave;
  FHoverNode := nil;
  FHoverMenu := False;
  Invalidate;
end;

procedure TAuTreeView.DblClick;
var
  P: TPoint;
  R: Integer;
  N: TAuTreeNode;
  Handled: Boolean;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  R := RowAt(P.Y);
  if R < 0 then Exit;
  N := FRows[R];
  if InExpander(N, P.X) or InMenuButton(P.X) then Exit;
  Handled := False;
  if Assigned(FOnActivate) then FOnActivate(Self, N, Handled);
  if not Handled then Toggle(N);
end;

procedure TAuTreeView.KeyDown(var Key: Word; Shift: TShiftState);
var
  R: Integer;
  Handled: Boolean;
  P: TPoint;
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  R := RowOf(FFocus);
  case Key of
    VK_UP: MoveFocusRow(R - 1, Shift);
    VK_DOWN: MoveFocusRow(R + 1, Shift);
    VK_PRIOR: MoveFocusRow(R - VisibleRows + 1, Shift);
    VK_NEXT: MoveFocusRow(R + VisibleRows - 1, Shift);
    VK_HOME: MoveFocusRow(0, Shift);
    VK_END: MoveFocusRow(RowCount - 1, Shift);
    VK_LEFT, VK_SUBTRACT:
      if FFocus <> nil then
      begin
        if FFocus.FExpanded then Collapse(FFocus)
        else if (Key = VK_LEFT) and (FFocus.Parent <> nil) and (FFocus.Parent <> FRoot) then
          SelectNode(FFocus.Parent);
      end;
    VK_RIGHT, VK_ADD:
      if FFocus <> nil then
      begin
        if not FFocus.FExpanded then Expand(FFocus)
        else if (Key = VK_RIGHT) and (FFocus.Count > 0) then SelectNode(FFocus.Children[0]);
      end;
    VK_RETURN:
      if FFocus <> nil then
      begin
        Handled := False;
        if Assigned(FOnActivate) then FOnActivate(Self, FFocus, Handled);
        if not Handled then Toggle(FFocus);
      end;
    VK_APPS, VK_F10:
      begin
        if (Key = VK_F10) and not (ssShift in Shift) then Exit;
        if (FFocus <> nil) and Assigned(FOnNodeContext) then
        begin
          MakeVisible(FFocus);
          R := RowOf(FFocus);
          P := ClientToScreen(Point(S(40), (R - FTop + 1) * FRowH));
          FOnNodeContext(Self, FFocus, P);
        end;
      end;
  else
    if (ssCtrl in Shift) and (Key = Ord('A')) and FMultiSelect then
    begin
      SelectRangeRows(0, RowCount - 1, False);
      Invalidate;
      DoSelChange;
    end
    else Exit;
  end;
  Key := 0;
end;

procedure TAuTreeView.TypeAhead(const Ch: string);
var
  I, Start, N: Integer;
  U: string;
begin
  if GetTickCount64 - FTypeTick > 900 then FTypeText := '';
  FTypeTick := GetTickCount64;
  FTypeText := FTypeText + Ch;
  U := UTF8LowerCase(FTypeText);
  N := RowCount;
  if N = 0 then Exit;
  Start := Math.Max(0, RowOf(FFocus));
  if Length(FTypeText) = Length(Ch) then Start := Start + 1;   // a new search starts after the focus
  for I := 0 to N - 1 do
    if Pos(U, UTF8LowerCase(FRows[(Start + I) mod N].Caption)) = 1 then
    begin
      MoveFocusRow((Start + I) mod N, []);
      Exit;
    end;
end;

procedure TAuTreeView.UTF8KeyPress(var UTF8Key: TUTF8Char);
begin
  inherited UTF8KeyPress(UTF8Key);
  if (UTF8Key <> '') and (UTF8Key[1] >= ' ') and not ((Length(UTF8Key) = 1) and (UTF8Key[1] in ['+', '-'])) then
  begin
    TypeAhead(UTF8Key);
    UTF8Key := '';
  end;
end;

function TAuTreeView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if ssCtrl in Shift then
  begin
    TextSize := FTextSize + Sign(WheelDelta);
    if Assigned(FOnTextSizeChange) then FOnTextSizeChange(Self);
    Exit;
  end;
  { the position (rows) jumps, the picture glides after it (DoPaint) }
  FScroll.WheelRows(-Sign(WheelDelta) * 3, FRowH);
  FTop := FScroll.Position;
  Invalidate;
end;

function TAuTreeView.PanBy(DX, DY: Integer): Boolean;
var
  N: Integer;
begin
  if not FScroll.Visible then Exit(inherited PanBy(DX, DY));
  N := PanRows(DY, FRowH);
  if N <> 0 then
  begin
    FScroll.Position := FScroll.Position + N;
    FTop := FScroll.Position;
    Invalidate;
  end;
  Result := True;
end;

function TAuTreeView.ScrollOffset: Integer;
begin
  Result := FTop;
end;

end.
