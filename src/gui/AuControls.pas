unit AuControls;

{ ==============================================================================
  AulumicNS - AuControls
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Owner-drawn control library. Every control paints itself with Direct2D (AuGfx)
  in the colours of the current theme (AuTheme) - no native Windows widget is
  used, so scroll bars, combo drop-downs, hints and popups are all themed.
  Every interactive control is a tab stop and fully keyboard operable.
  =============================================================================}

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, Controls, Forms, ExtCtrls, Graphics, LCLType,
  LMessages, LCLIntf, Clipbrd, AuGfx, AuTheme, AuIcons, AuAnim;

const
  { TAuControl.GesturePan }
  GESTURE_PAN_NONE = 0;
  GESTURE_PAN_V = 1;
  GESTURE_PAN_VH = 3;
  { How far (unscaled) beside an edge that can be dragged - a splitter, the
    edge of a column - a finger still takes hold of it. The mouse has to hit
    the edge as it is drawn. }
  TOUCH_EDGE_REACH = 12;

{ True while the mouse message in work was made by Windows from a touch or a pen }
function MouseFromTouch: Boolean;

type
  TAuRowEvent = procedure(Sender: TObject; Index: Integer) of object;

  { TAuControl - base of all controls }

  TAuControl = class(TCustomControl)
  private
    FBackRole: TAuRole;
    FFocusOnClick: Boolean;
    FGesX, FGesY, FGesAcc: Integer;      // the pan gesture: last point, rest of a row
    FGesTaken: Boolean;                  // PanBy(0, 0) at its start: this pan is handled
    FOldProc: Windows.WNDPROC;           // the LCL's window procedure (see GestureProc)
    procedure WMGetDlgCode(var Msg: TLMNoParams); message LM_GETDLGCODE;
    procedure SetBackRole(R: TAuRole);
    procedure ConfigureGestures;
    function HandleGesture(AInfo: LPARAM): Boolean;
  protected
    FHover: Boolean;
    FHoverA: TAuAnim;                    // 0 .. 1: the hover highlight fading in and out
    { True for a large control that repaints in full and often
      (a list that scrolls): it gets a render target of its own on the
      graphics card (AuGfx.TGfxWindowTarget) }
    FGpuPaint: Boolean;
    FWinTarget: TGfxWindowTarget;
    FWantKeys: Boolean;
    procedure CreateWnd; override;
    procedure EraseBackground(DC: HDC); override;
    procedure Paint; override;
    procedure DoPaint(G: TGfx); virtual;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure EnabledChanged; override;
    function ShowFocus: Boolean;
    procedure DrawFocusRing(G: TGfx; X, Y, W, H, R: Single);
    { how far the hover highlight has faded in (0 .. 1), and
      a colour between the plain and the hovered one }
    function HoverT: Single;
    function HoverMix(ABase, AHot: TARGB): TARGB;
    procedure WndProc(var Message: TLMessage); override;
    procedure Resize; override;
    procedure DoAutoAdjustLayout(const AMode: TLayoutAdjustmentPolicy;
      const AXProportion, AYProportion: Double); override;
    { rescales pixel values the control keeps itself (row heights ...) }
    procedure ScaleCached(K: Double); virtual;
    { touch. A pan gesture (a swiping finger) moved DX, DY
      pixels since the last call (0, 0 at its start); True = this control or
      an ancestor scrolled (or would). The default asks the parent: a field
      inside a scrolled page, a list that cannot scroll in a scroll box. }
    function PanBy(DX, DY: Integer): Boolean; virtual;
    { the pan gestures this control takes: GESTURE_PAN_V (default: lists and
      pages, swiped up and down), GESTURE_PAN_VH (both ways: the booklet) or
      GESTURE_PAN_NONE (a touch drag stays a mouse drag: sliders, scroll
      bars, splitters) }
    function GesturePan: Integer; virtual;
    { True when a finger that goes down at X, Y (client) drags something of
      this control that a pan gesture would take away from it - an edge that
      is dragged up or down in a control that also scrolls. That touch then
      gives no pan and arrives as mouse messages. }
    function TouchDragAt(X, Y: Integer): Boolean; virtual;
    { a row-based list: the rows the finger's DY pixels add up to (the rest
      is kept for the next call); to add to the scroll position }
    function PanRows(DY, ARowH: Integer): Integer;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { called after the DPI of the window changed: lay out again and repaint }
    procedure DpiChanged; virtual;
    { paints the control and its children into G (screenshots, previews):
      independent of the window being visible on screen }
    procedure RenderTo(G: TGfx);
    function EffBack: TARGB;
    function ParentBack: TARGB;
    { the scroll position (pixels or rows; 0 = does not
      scroll) - read by the touch probe of the debug build }
    function ScrollOffset: Integer; virtual;
    property BackRole: TAuRole read FBackRole write SetBackRole;
    { a render target of its own whatever the size (see Paint): for a small
      control that repaints many times a second }
    property GpuPaint: Boolean read FGpuPaint write FGpuPaint;
    property FocusOnClick: Boolean read FFocusOnClick write FFocusOnClick;
    property OnClick;
    property OnDblClick;
    { LCL drag and drop (the library tree onto the playlist, reordering) }
    property OnDragOver;
    property OnDragDrop;
    property OnEndDrag;
    property OnMouseDown;
    property OnMouseUp;
    property OnMouseMove;
    property OnResize;
    property OnKeyDown;
    property OnContextPopup;
    property OnEnter;
    property OnExit;
  end;

  { TAuPanel }

  TAuPanel = class(TAuControl)
  private
    FRadius: Integer;
    FBorderRole: TAuRole;
    FBorderSides: Byte;       // bit 0 left, 1 top, 2 right, 3 bottom (only when Radius = 0)
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Radius: Integer read FRadius write FRadius;
    property BorderRole: TAuRole read FBorderRole write FBorderRole;
    property BorderSides: Byte read FBorderSides write FBorderSides;
  end;

  { TAuLabel }

  TAuLabel = class(TAuControl)
  private
    FCaption: string;
    FSize: Single;
    FBold, FWrap, FMono, FItalic, FAutoWidth: Boolean;
    FRole: TAuRole;
    FHAlign, FVAlign: Integer;
    procedure SetCaption(const V: string);
    procedure SetRole(V: TAuRole);
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    function Font: TGfxFont;
    procedure FitWidth;
    property Caption: string read FCaption write SetCaption;
    property FontSize: Single read FSize write FSize;
    property Bold: Boolean read FBold write FBold;
    property Mono: Boolean read FMono write FMono;
    property Italic: Boolean read FItalic write FItalic;
    property WordWrap: Boolean read FWrap write FWrap;
    property AutoWidth: Boolean read FAutoWidth write FAutoWidth;
    property TextRole: TAuRole read FRole write SetRole;
    property HAlign: Integer read FHAlign write FHAlign;
    property VAlign: Integer read FVAlign write FVAlign;
  end;

  TAuButtonKind = (bkNormal, bkPrimary, bkFlat, bkDanger);

  { TAuButton }

  TAuButton = class(TAuControl)
  private
    FCaption: string;
    FKind: TAuButtonKind;
    FIcon: TAuIcon;
    FPressed, FDown: Boolean;
    FModalResult: TModalResult;
    procedure SetCaption(const V: string);
    procedure SetDown(V: Boolean);
    procedure SetIcon(V: TAuIcon);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    function PreferredWidth: Integer;
    property Caption: string read FCaption write SetCaption;
    property Kind: TAuButtonKind read FKind write FKind;
    property Icon: TAuIcon read FIcon write SetIcon;
    property Down: Boolean read FDown write SetDown;
    property ModalResult: TModalResult read FModalResult write FModalResult;
  end;

  TAuIconButtonStyle = (ibFlat, ibFilled, ibCircle);

  { TAuIconButton - round icon-only button (transport, toolbars) }

  TAuIconButton = class(TAuControl)
  private
    FIcon: TAuIcon;
    FIconSize: Integer;
    FStyle: TAuIconButtonStyle;
    FActive, FPressed, FShowDot: Boolean;
    FIconRole: TAuRole;
    procedure SetIcon(V: TAuIcon);
    procedure SetActive(V: Boolean);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Icon: TAuIcon read FIcon write SetIcon;
    property IconSize: Integer read FIconSize write FIconSize;
    property Style: TAuIconButtonStyle read FStyle write FStyle;
    property Active: Boolean read FActive write SetActive;    // toggled state: accent icon
    property ShowDot: Boolean read FShowDot write FShowDot;   // small dot under an active icon
    property IconRole: TAuRole read FIconRole write FIconRole;
  end;

  { TAuCheckBox }

  TAuCheckBox = class(TAuControl)
  private
    FCaption: string;
    FChecked: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(V: Boolean);
    procedure SetCaption(const V: string);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Caption: string read FCaption write SetCaption;
    property Checked: Boolean read FChecked write SetChecked;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuRadio - radio button; radios of one parent with the same GroupIndex
    are exclusive, the arrow keys move within the group }

  TAuRadio = class(TAuControl)
  private
    FCaption: string;
    FChecked: Boolean;
    FGroup: Integer;
    FOnChange: TNotifyEvent;
    procedure SetChecked(V: Boolean);
    procedure SetCaption(const V: string);
    function Siblings: TList;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Caption: string read FCaption write SetCaption;
    property Checked: Boolean read FChecked write SetChecked;
    property GroupIndex: Integer read FGroup write FGroup;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuSwitch - on / off toggle with caption on the left }

  TAuSwitch = class(TAuControl)
  private
    FCaption, FDescription: string;
    FChecked: Boolean;
    FKnobA: TAuAnim;                     // the knob on its way: 0 = off, 1 = on
    FOnChange: TNotifyEvent;
    procedure SetChecked(V: Boolean);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Caption: string read FCaption write FCaption;
    property Description: string read FDescription write FDescription;
    property Checked: Boolean read FChecked write SetChecked;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TAuOrientation = (aoVertical, aoHorizontal);

  { TAuScrollBar - slim overlay-style scroll bar }

  TAuScrollBar = class(TAuControl)
  private
    FKind: TAuOrientation;
    FMax, FPage, FPos, FSmall: Integer;
    FDrag: Boolean;
    FDragAt, FDragPos: Integer;
    FOnScroll: TNotifyEvent;
    { gliding. FGlideA: the position on its way (WheelBy).
      FOffsA: for a list that scrolls by rows - the position jumps, the
      picture follows (WheelRows; the pixels it still lags behind). }
    FGlideA, FOffsA: TAuAnim;
    FInGlide, FInRows: Boolean;
    procedure GlideStep(Sender: TObject; ADone: Boolean);
    procedure OffsStep(Sender: TObject; ADone: Boolean);
    procedure SetPos(V: Integer);
    procedure GetThumb(out T, H: Integer);
    function TrackLen: Integer;
  protected
    function GesturePan: Integer; override;   // a touch drag moves the thumb
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetParams(AMax, APage: Integer);
    function NeedScroll: Boolean;
    function MaxPos: Integer;
    { the mouse wheel and the like: the position glides there (at once
      without animations) }
    procedure WheelBy(ADelta: Integer);
    { glides to this position; GlideTarget: where it is going (the position
      when nothing glides) }
    procedure GlideTo(APos: Integer);
    function GlideTarget: Integer;
    { for a list whose position counts rows of ARowPx pixels: the position
      moves ARows at once, GlideOffset tells the owner's paint how many
      pixels the picture still has to go (it shifts its rows by that) }
    procedure WheelRows(ARows, ARowPx: Integer);
    function GlideOffset: Integer;
    property Kind: TAuOrientation read FKind write FKind;
    property Position: Integer read FPos write SetPos;
    property PageSize: Integer read FPage;
    property SmallStep: Integer read FSmall write FSmall;
    property OnScroll: TNotifyEvent read FOnScroll write FOnScroll;
  end;

  { TAuSlider - horizontal value slider (seek bar, volume) }

  TAuSlider = class(TAuControl)
  private
    FMin, FMax, FPos, FStep, FBigStep: Double;
    FDragging: Boolean;
    FAlwaysAccent, FAlwaysThumb: Boolean;
    FOnChange, FOnChangeEnd: TNotifyEvent;
    FHoverX: Integer;
    procedure SetPos(V: Double);
    function TrackLeft: Single;
    function TrackWidth: Single;
    function ValueAt(X: Integer): Double;
    procedure UserSet(V: Double; Final: Boolean);
  protected
    function GesturePan: Integer; override;   // a touch drag moves the knob
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetRange(AMin, AMax: Double);
    property Min: Double read FMin;
    property Max: Double read FMax;
    property Position: Double read FPos write SetPos;
    property Step: Double read FStep write FStep;
    property BigStep: Double read FBigStep write FBigStep;
    property Dragging: Boolean read FDragging;
    property AlwaysAccent: Boolean read FAlwaysAccent write FAlwaysAccent;
    property AlwaysThumb: Boolean read FAlwaysThumb write FAlwaysThumb;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;        // while the user moves it
    property OnChangeEnd: TNotifyEvent read FOnChangeEnd write FOnChangeEnd; // user released / key step
  end;

  { TAuProgress }

  TAuProgress = class(TAuControl)
  private
    FPos: Single;
    procedure SetPos(V: Single);
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Position: Single read FPos write SetPos;
  end;

  { TAuEdit - single line edit; optionally numeric with spin buttons, or a
    search box with a magnifier and a clear button }

  TAuEdit = class(TAuControl)
  private
    FText: UnicodeString;
    FCaret, FAnchor: Integer;
    FScrollX: Single;
    FReadOnly, FNumeric, FSpin, FMouseSel, FSearch: Boolean;
    FMin, FMax: Integer;
    FSpinHot: Integer;            // -1 none, 0 up arrow, 1 down arrow
    FPlaceholder: string;
    FOnChange, FOnEnterKey: TNotifyEvent;
    function GetText: string;
    function SpinLeft: Integer;
    procedure SetText(const V: string);
    function GetValue: Integer;
    procedure SetValue(V: Integer);
    function HasSel: Boolean;
    procedure DeleteSel;
    procedure InsertText(const T: UnicodeString);
    function TextLeft: Integer;
    function TextAreaW: Integer;
    function PosFromX(X: Integer): Integer;
    function CaretPx(I: Integer): Single;
    function ClearRect: TRect;
    procedure EnsureCaretVisible;
    procedure DoChanged;
    procedure StepValue(D: Integer);
  protected
    procedure DoPaint(G: TGfx); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure MouseLeave; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    CaretOn: Boolean;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SelectAll;
    property Text: string read GetText write SetText;
    property Value: Integer read GetValue write SetValue;
    property MinValue: Integer read FMin write FMin;
    property MaxValue: Integer read FMax write FMax;
    property Numeric: Boolean read FNumeric write FNumeric;
    property Spin: Boolean read FSpin write FSpin;
    property Search: Boolean read FSearch write FSearch;
    property ReadOnly: Boolean read FReadOnly write FReadOnly;
    property Placeholder: string read FPlaceholder write FPlaceholder;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnEnterKey: TNotifyEvent read FOnEnterKey write FOnEnterKey;
  end;

  { TAuMemo - multi-line text (word wrapped); Enter starts a new line. Shares
    the caret, the selection and the clipboard of TAuEdit; Text has CR LF
    line breaks (they are kept as LF inside). }

  TAuMemoLine = record
    Start, Len: Integer;        // 0-based index into FText; Len without the line break
  end;

  TAuMemo = class(TAuEdit)
  private
    FLines: array of TAuMemoLine;
    FLayoutW: Integer;
    FLayoutValid: Boolean;
    FScrollY: Integer;
    FWantX: Single;             // the x the caret keeps on Up / Down (-1 none)
    FTextSize: Single;
    FPlain: Boolean;
    function GetMemoText: string;
    procedure SetMemoText(const V: string);
    procedure SetTextSize(V: Single);
    procedure SetPlain(V: Boolean);
    function MemoFont: TGfxFont;
    function LineH: Integer;
    function PadX: Integer;
    function PadY: Integer;
    procedure Layout;
    function LineOf(APos: Integer): Integer;
    function XOf(APos: Integer): Single;
    function PosAt(X, Y: Integer): Integer;
    function PosInLine(L: Integer; X: Single): Integer;
    procedure InsertMemo(const T: UnicodeString);
    procedure MemoChanged;
    procedure ScrollToCaret;
    function ContentH: Integer;
  protected
    function PanBy(DX, DY: Integer): Boolean; override;   // touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    procedure DoEnter; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Text: string read GetMemoText write SetMemoText;
    { the font size (unscaled, default 13) }
    property TextSize: Single read FTextSize write SetTextSize;
    { no box: the text on the parent's background (a text to read) }
    property Plain: Boolean read FPlain write SetPlain;
  end;

  { a window that fades in when it opens (menus, popups,
    dialogs), a popup also moving a few pixels into its place. The window is
    made a layered one for it (and stays one, fully opaque afterwards);
    without animations (AuAnim.AnimActive) Start only shows the window. }
  TAuWindowFade = class
  private
    FForm: TCustomForm;
    FA: TAuAnim;
    FSlide, FLeft0, FTop0: Integer;
    procedure Step(Sender: TObject; ADone: Boolean);
  public
    constructor Create(AForm: TCustomForm);
    destructor Destroy; override;
    { paints the (cloaked) window, shows it and fades it in; ASlidePx: the
      way it moves down into its place (0: none; a maximized window does
      not move); AMs: how long }
    procedure Start(ASlidePx: Integer; AMs: Integer = ANIM_NORMAL);
  end;

  { TAuPopup - borderless themed popup window (combo drop-downs, menus).
    Popups form chains (sub menus); the whole chain closes when the user
    activates any window outside of it. }

  TAuPopup = class(TForm)
  private
    FParentPopup, FChild: TAuPopup;
    FClosing: Boolean;
    FCloakPending: Boolean;     // shown cloaked, AUM_UNCLOAK posted
    FFade: TAuWindowFade;
    procedure DoDeact(Sender: TObject);
    procedure CheckDeact(Data: PtrInt);
    procedure PopupClose(Sender: TObject; var CloseAction: TCloseAction);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure WndProc(var Message: TLMessage); override;
  public
    OnClosed: TNotifyEvent;
    constructor CreatePopup(AParentPopup: TAuPopup);
    destructor Destroy; override;
    function Root: TAuPopup;
    procedure CloseTree;
    procedure ShowAt(X, Y, W, H: Integer; AboveY: Integer = -1);
    property ParentPopup: TAuPopup read FParentPopup;
    property ChildPopup: TAuPopup read FChild;
  end;

  { TAuPopupList - item list used inside a combo drop-down }

  TAuPopupList = class(TAuControl)
  private
    FItems: TStrings;
    FIndex, FTop, FRowH, FMaxRows: Integer;
    FScroll: TAuScrollBar;
    FOnPick: TAuRowEvent;
    procedure ScrollChanged(Sender: TObject);
    function RowAt(Y: Integer): Integer;
  protected
    function PanBy(DX, DY: Integer): Boolean; override;   // touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Setup(AItems: TStrings; AIndex, AMaxRows: Integer);
    procedure MoveIndex(D: Integer);
    procedure EnsureVisible(I: Integer);
    function ContentHeight: Integer;
    function ContentWidth: Integer;
    property ItemIndex: Integer read FIndex;
    property RowHeight: Integer read FRowH;
    property OnPick: TAuRowEvent read FOnPick write FOnPick;
  end;

  { TAuCombo }

  TAuCombo = class(TAuControl)
  private
    FItems: TStringList;
    FItemIndex: Integer;
    FOnChange: TNotifyEvent;
    FPopup: TAuPopup;
    FList: TAuPopupList;
    FLastClose: QWord;
    procedure SetItemIndex(V: Integer);
    function GetText: string;
    procedure ListPick(Sender: TObject; Index: Integer);
    procedure PopupClosed(Sender: TObject);
    procedure PopupKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OpenPopup;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SelectText(const AText: string);
    property Items: TStringList read FItems;
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property Text: string read GetText;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuTabs - underlined tab header strip }

  TAuTabs = class(TAuControl)
  private
    FTabs: TStringList;
    FTabIndex, FHoverTab: Integer;
    FOnChange: TNotifyEvent;
    procedure SetTabIndex(V: Integer);
    function TabAt(X: Integer): Integer;
    function TabLeft(I: Integer): Integer;
    function TabWidth(I: Integer): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddTab(const ACaption: string);
    property Tabs: TStringList read FTabs;
    property TabIndex: Integer read FTabIndex write SetTabIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuSegmented - pill shaped segmented control }

  TAuSegmented = class(TAuControl)
  private
    FItems: TStringList;
    FIcons: array of TAuIcon;
    FIndex, FHoverIdx: Integer;
    FOnChange: TNotifyEvent;
    procedure SetIndex(V: Integer);
    function SegW: Single;
    function SegAt(X: Integer): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetItems(const ACaptions: array of string);
    procedure SetIcons(const AIcons: array of TAuIcon);
    property Items: TStringList read FItems;
    property ItemIndex: Integer read FIndex write SetIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuScrollBox - vertically scrolling content panel }

  TAuScrollBox = class(TAuControl)
  private
    FContent: TAuPanel;
    FScroll: TAuScrollBar;
    FContentHeight: Integer;
    procedure ScrollChanged(Sender: TObject);
    procedure SetContentHeight(V: Integer);
  protected
    function PanBy(DX, DY: Integer): Boolean; override;   // touch
  public
    function ScrollOffset: Integer; override;
  protected
    procedure Resize; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Relayout;
    { scrolls as little as needed to show C with AMargin (unscaled) around it }
    procedure ScrollIntoView(C: TControl; AMargin: Integer = 8);
    property Content: TAuPanel read FContent;
    property ContentHeight: Integer read FContentHeight write SetContentHeight;
  end;

  { TAuSplitter - drag handle that resizes a neighbouring control.
    Without the graphics card (FLive) only a line follows the pointer while
    it is dragged (a small window of its own above the panes: nothing below
    it is painted); the target gets its new size once, when the button or the
    finger is let go. Resizing and repainting the panes in software at every
    mouse move would make the drag lag behind the hand on a slow PC.
    For a finger the splitter reaches TOUCH_EDGE_REACH further on both
    sides than it is drawn: a touch that lands there on a neighbouring
    control drags the splitter (TakeTouch). A touch that does not move is
    handed back to that control as a click, and the mouse keeps the splitter
    at its drawn width. }

  TAuSplitter = class(TAuControl)
  private
    FTarget: TControl;
    FDrag: Boolean;
    FStartX, FStartW: Integer;
    FNewW: Integer;                // the size the target gets at the end of the drag
    FGhost: HWND;                  // the line shown during the drag (0 = none)
    { this drag resizes the panes while it moves (the graphics
      card draws: GpuPaintAllowed); else only the line moves until the end }
    FLive: Boolean;
    FMinSize, FMaxSize: Integer;
    FOnMoved: TNotifyEvent;
    { a drag taken over from a touch on a neighbouring control: that
      control's window and its press (given back when the finger did not
      move), and whether the finger moved }
    FTouchFrom: HWND;
    FTouchWP: WPARAM;
    FTouchLP: LPARAM;
    FTouchMoved: Boolean;
    procedure BeginDragAt(const AScreenPt: TPoint);
    procedure SetTarget(V: TControl);
    function IsVertical: Boolean;
    procedure ApplySize(ASize: Integer);
    procedure ShowGhost;
    procedure MoveGhost;
    procedure HideGhost;
    procedure EndDrag(AApply: Boolean);
    procedure LMCaptureChanged(var Msg: TLMessage); message LM_CAPTURECHANGED;
    procedure CaptureLost(Data: PtrInt);
  protected
    function GesturePan: Integer; override;   // a touch drag resizes
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure ScaleCached(K: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { a target aligned alTop / alBottom is resized in height (horizontal splitter) }
    property Target: TControl read FTarget write SetTarget;
    property MinSize: Integer read FMinSize write FMinSize;
    property MaxSize: Integer read FMaxSize write FMaxSize;
    property OnMoved: TNotifyEvent read FOnMoved write FOnMoved;
    { True while it is being dragged }
    property Dragging: Boolean read FDrag;
    { A finger went down at AScreenPt on the window AFrom (its press: AWP,
      ALP): the splitter takes the mouse and is dragged from there. }
    procedure TakeTouch(AFrom: HWND; AWP: WPARAM; ALP: LPARAM; const AScreenPt: TPoint);
  end;

  { TAuCover - cover art picture with rounded corners or a generated placeholder }

  TAuCover = class(TAuControl)
  private
    FBitmap: TGfxBitmap;
    FOwnsBitmap: Boolean;
    FRadius: Integer;
    FKey: string;
    FShadow: Boolean;
  protected
    procedure DoPaint(G: TGfx); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetBitmap(B: TGfxBitmap; AOwns: Boolean);
    property Bitmap: TGfxBitmap read FBitmap;
    property Radius: Integer read FRadius write FRadius;
    property PlaceholderKey: string read FKey write FKey;
    property Shadow: Boolean read FShadow write FShadow;
  end;

  { TAuSwatches - accent colour picker }

  TAuSwatches = class(TAuControl)
  private
    FIndex, FHoverIdx: Integer;
    FOnChange: TNotifyEvent;
    procedure SetIndex(V: Integer);
    function ItemAt(X: Integer): Integer;
  protected
    procedure DoPaint(G: TGfx); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    property ItemIndex: Integer read FIndex write SetIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TAuHintWindow - themed tool tips (replaces the native hint window) }

  { lies over a container for a moment and fades from a picture
    of how it looked to a picture of how it looks now (a Preferences page,
    the banner at a new track, the theme). Made by CrossFadeFrom; it frees
    itself. The mouse goes through it. }
  TAuCrossFade = class(TAuControl)
  private
    FBefore, FAfter: TGfxBitmap;      // FBefore = nil: an entrance over FBackColor
    FBackColor: TARGB;
    FA: TAuAnim;
    FSlide: Integer;
    procedure Step(Sender: TObject; ADone: Boolean);
    procedure FreeSelf(Data: PtrInt);
    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;
  protected
    procedure DoPaint(G: TGfx); override;
  public
    destructor Destroy; override;
  end;

  TAuHintWindow = class(THintWindow)
  protected
    procedure Paint; override;
    procedure EraseBackground(DC: HDC); override;
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    function CalcHintRect(MaxWidth: Integer; const AHint: string; AData: Pointer): TRect; override;
  end;

procedure ApplyPopupFrame(H: HWND);
procedure DrawCheckBox(G: TGfx; X, Y, B: Single; Checked, Hot, Enabled: Boolean);

var
  { the debug build's --ui-bench: paints per class and their time (nil = off) }
  PaintTally: TStringList = nil;
  { controls may have a render target of their own on the
    graphics card (TAuControl.Paint). Off: everything through the paint
    buffer and Direct2D's software renderer (the setting "Use the graphics
    card", and --no-gpu-paint of the debug build). }
  GpuPaintAllowed: Boolean = True;

{ a picture of AParent with its controls as they are drawn
  now; nil when animations are off or AParent is not on screen (then no
  cross-fade happens and nothing is rendered for it) }
function SnapshotControls(AParent: TWinControl): TGfxBitmap;
{ fades AParent from ABefore (a SnapshotControls taken before the change;
  freed here, nil = no fade) to its present look; ASlidePx: the new look also
  moves up that many pixels into its place.
  ABeside: the fade lies on AParent's parent, over AParent (for a container
  that scrolls its controls, or one that replaces another of the same place:
  ABefore is then the picture of the one that was there) }
procedure CrossFadeFrom(AParent: TWinControl; ABefore: TGfxBitmap; ASlidePx: Integer = 0;
  ABeside: Boolean = False);
{ a container that has just been shown in place of another one (a page): it
  fades in over its plain background and moves up ASlidePx into its place.
  The fade lies on its parent, over it. Nothing happens without animations. }
procedure EntranceFade(AShown: TWinControl; ASlidePx: Integer);

implementation

type
  TCaretHandler = class
    procedure Tick(Sender: TObject);
    procedure UserInput(Sender: TObject; Msg: Cardinal);
  end;

var
  CaretTimer: TTimer = nil;
  CaretHandler: TCaretHandler = nil;
  FocusedEdit: TAuEdit = nil;

procedure TCaretHandler.Tick(Sender: TObject);
begin
  if FocusedEdit <> nil then
  begin
    FocusedEdit.CaretOn := not FocusedEdit.CaretOn;
    FocusedEdit.Invalidate;
  end;
end;

{ keyboard use switches focus rings on, mouse use switches them off }
procedure TCaretHandler.UserInput(Sender: TObject; Msg: Cardinal);
var
  NewCues: Boolean;
begin
  NewCues := KeyboardCues;
  case Msg of
    WM_KEYDOWN, WM_SYSKEYDOWN:
      if (GetKeyState(VK_TAB) < 0) or (GetKeyState(VK_LEFT) < 0) or (GetKeyState(VK_RIGHT) < 0) or
         (GetKeyState(VK_UP) < 0) or (GetKeyState(VK_DOWN) < 0) or (GetKeyState(VK_MENU) < 0) then
        NewCues := True;
    WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_NCLBUTTONDOWN:
      NewCues := False;
  end;
  if NewCues <> KeyboardCues then
  begin
    KeyboardCues := NewCues;
    if (Screen <> nil) and (Screen.ActiveControl <> nil) then Screen.ActiveControl.Invalidate;
  end;
end;

procedure EnsureCaretTimer;
begin
  if CaretTimer = nil then
  begin
    CaretTimer := TTimer.Create(nil);
    CaretTimer.Interval := 530;
    CaretTimer.OnTimer := @CaretHandler.Tick;
  end;
end;

procedure ApplyPopupFrame(H: HWND);
type
  TDwmSet = function(Wnd: HWND; Attr: DWORD; PV: Pointer; CB: DWORD): HRESULT; stdcall;
var
  Lib: HMODULE;
  F: TDwmSet;
  V: DWORD;
begin
  Lib := GetModuleHandle('dwmapi.dll');
  if Lib = 0 then Lib := LoadLibrary('dwmapi.dll');
  if Lib = 0 then Exit;
  F := TDwmSet(GetProcAddress(Lib, 'DwmSetWindowAttribute'));
  if not Assigned(F) then Exit;
  V := 3;                                  // DWMWCP_ROUNDSMALL
  F(H, 33, @V, SizeOf(V));
  V := ToTColor(clBorderHi);
  F(H, 34, @V, SizeOf(V));
end;

procedure DrawCheckBox(G: TGfx; X, Y, B: Single; Checked, Hot, Enabled: Boolean);
begin
  if Checked then
  begin
    if Enabled then G.FillRound(X, Y, B, B, S(4), clAccent)
    else G.FillRound(X, Y, B, B, S(4), clBorderHi);
    DrawIcon(G, icCheck, X + B / 2, Y + B / 2, B * 0.75, clOnAccent);
  end
  else
  begin
    G.FillRound(X, Y, B, B, S(4), clInput);
    if Hot then G.StrokeRound(X, Y, B, B, S(4), SF(1.2), clTextFaint)
    else G.StrokeRound(X, Y, B, B, S(4), SF(1.2), clBorderHi);
  end;
end;

{ ---- TAuControl ---- }

constructor TAuControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  { buffered by Paint itself, not by the LCL (see there) }
  DoubleBuffered := False;
  ControlStyle := ControlStyle + [csOpaque] - [csSetCaption];
  FBackRole := crInherit;
  FFocusOnClick := True;
  TabStop := False;
end;

destructor TAuControl.Destroy;
begin
  AnimForget(Self);
  FreeAndNil(FWinTarget);
  inherited Destroy;
end;

function TAuControl.HoverT: Single;
begin
  Result := FHoverA.Value;
end;

function TAuControl.HoverMix(ABase, AHot: TARGB): TARGB;
begin
  if FHoverA.Value <= 0 then Result := ABase
  else if FHoverA.Value >= 1 then Result := AHot
  else Result := Blend(ABase, AHot, FHoverA.Value);
end;

procedure TAuControl.WMGetDlgCode(var Msg: TLMNoParams);
begin
  if FWantKeys then Msg.Result := DLGC_WANTARROWS or DLGC_WANTCHARS
  else inherited;
end;

{ ---- touch: pan gestures ----
  Windows turns a swiping finger into WM_GESTURE / GID_PAN for the window
  under it; unhandled, it scrolls only windows with standard scroll bars,
  and these controls draw their own.
  The LCL hands a control only the window messages it knows (and those from
  WM_USER on): WM_GESTURENOTIFY and WM_GESTURE never reach WndProc. So
  CreateWnd puts GestureProc in front of the LCL's window procedure (as
  AuTitleBar does), and WM_NCDESTROY puts it back. Checked by the touch
  probe of the debug build (AuTouchProbe, Tools\ProbeTouch.ps1). }
const
  WM_GESTURE_ = $0119;
  WM_GESTURENOTIFY_ = $011A;
  GID_PAN_ = 4;
  GF_BEGIN_ = 1;
  GC_PAN_ = $01;
  GC_PAN_WITH_SINGLE_FINGER_VERTICALLY_ = $02;
  GC_PAN_WITH_SINGLE_FINGER_HORIZONTALLY_ = $04;
  GC_PAN_WITH_GUTTER_ = $08;
  GC_PAN_WITH_INERTIA_ = $10;

type
  {$PUSH}{$PACKRECORDS C}
  TGestureInfo_ = record
    cbSize, dwFlags, dwID: DWORD;
    hwndTarget: HWND;
    ptsX, ptsY: SmallInt;              // POINTS ptsLocation (screen)
    dwInstanceID, dwSequenceID: DWORD;
    ullArguments: QWord;
    cbExtraArgs: UINT;
  end;
  TGestureConfig_ = record
    dwID, dwWant, dwBlock: DWORD;
  end;
  {$POP}

function GetGestureInfo_(hGestureInfo: THandle; var pGestureInfo: TGestureInfo_): BOOL; stdcall;
  external 'user32.dll' name 'GetGestureInfo';
function CloseGestureInfoHandle_(hGestureInfo: THandle): BOOL; stdcall;
  external 'user32.dll' name 'CloseGestureInfoHandle';
function SetGestureConfig_(hwnd: HWND; dwReserved, cIDs: DWORD; pGestureConfig: Pointer; cbSize: UINT): BOOL; stdcall;
  external 'user32.dll' name 'SetGestureConfig';

function TAuControl.PanBy(DX, DY: Integer): Boolean;
begin
  Result := (Parent is TAuControl) and TAuControl(Parent).PanBy(DX, DY);
end;

function TAuControl.GesturePan: Integer;
begin
  Result := GESTURE_PAN_V;
end;

function TAuControl.TouchDragAt(X, Y: Integer): Boolean;
begin
  Result := False;
end;

function TAuControl.ScrollOffset: Integer;
begin
  Result := 0;
end;

function TAuControl.PanRows(DY, ARowH: Integer): Integer;
begin
  Result := 0;
  if ARowH <= 0 then Exit;
  FGesAcc := FGesAcc - DY;                 // finger up: further down the list
  Result := FGesAcc div ARowH;
  FGesAcc := FGesAcc - Result * ARowH;
end;

{ WM_GESTURENOTIFY: the gestures this window takes (before a gesture starts) }
procedure TAuControl.ConfigureGestures;
var
  C: TGestureConfig_;
  P: Integer;
begin
  if not HandleAllocated then Exit;
  P := GesturePan;
  C.dwID := GID_PAN_;
  if P = GESTURE_PAN_NONE then
  begin
    C.dwWant := 0;
    C.dwBlock := GC_PAN_;
  end
  else
  begin
    C.dwWant := GC_PAN_ or GC_PAN_WITH_SINGLE_FINGER_VERTICALLY_ or GC_PAN_WITH_GUTTER_ or GC_PAN_WITH_INERTIA_;
    C.dwBlock := 0;
    { horizontally a touch drag stays a mouse drag (drag and drop from the
      library onto the playlist) unless the control pans both ways }
    if P = GESTURE_PAN_VH then C.dwWant := C.dwWant or GC_PAN_WITH_SINGLE_FINGER_HORIZONTALLY_
    else C.dwBlock := GC_PAN_WITH_SINGLE_FINGER_HORIZONTALLY_;
  end;
  SetGestureConfig_(Handle, 0, 1, @C, SizeOf(C));
end;

function TAuControl.HandleGesture(AInfo: LPARAM): Boolean;
var
  GI: TGestureInfo_;
begin
  Result := False;
  FillChar(GI, SizeOf(GI), 0);
  GI.cbSize := SizeOf(GI);
  if not GetGestureInfo_(THandle(AInfo), GI) then Exit;
  if GI.dwID <> GID_PAN_ then Exit;
  if (GI.dwFlags and GF_BEGIN_) <> 0 then
  begin
    FGesX := GI.ptsX;
    FGesY := GI.ptsY;
    FGesAcc := 0;
    FGesTaken := PanBy(0, 0);
    Result := FGesTaken;
  end
  else if (GI.ptsX = FGesX) and (GI.ptsY = FGesY) then
    { no movement (inertia sends such messages): PanBy(0, 0) would be read
      as a new swipe (the booklet turned two pages per swipe) }
    Result := FGesTaken
  else
  begin
    Result := PanBy(GI.ptsX - FGesX, GI.ptsY - FGesY);
    FGesX := GI.ptsX;
    FGesY := GI.ptsY;
  end;
  { handled: the handle is closed here; else DefWindowProc does it }
  if Result then CloseGestureInfoHandle_(THandle(AInfo));
end;

var
  GestureAtom: ATOM = 0;     // the window property that points to the control

function GestureProp: PWideChar; inline;
begin
  Result := PWideChar(PtrUInt(GestureAtom));
end;


{ The splitter that a finger at AScreenPt on AControl takes hold of: one of
  AControl's form that is shown, with the point on it or within the reach
  beside it. nil = none (also when AControl is a splitter itself). }
function SplitterInTouchReach(AControl: TControl; const AScreenPt: TPoint): TAuSplitter; forward;

type
  { the lParam of WM_GESTURENOTIFY }
  TGestureNotify_ = record
    cbSize: UINT;
    dwFlags: DWORD;
    hwndTarget: HWND;
    ptsLocation: packed record x, y: SmallInt; end;   // screen
    dwInstanceID: DWORD;
  end;
  PGestureNotify_ = ^TGestureNotify_;

function MouseFromTouch: Boolean;
begin
  Result := (PtrUInt(GetMessageExtraInfo) and $FFFFFF00) = $FF515700;
end;

{ this touch gives no pan gesture on AWnd }
procedure BlockPan(AWnd: HWND);
var
  Cfg: TGestureConfig_;
begin
  Cfg.dwID := GID_PAN_;
  Cfg.dwWant := 0;
  Cfg.dwBlock := GC_PAN_;
  SetGestureConfig_(AWnd, 0, 1, @Cfg, SizeOf(Cfg));
end;

function GestureProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  C: TAuControl;
  Old: Windows.WNDPROC;
  Sp: TAuSplitter;
  Pt: Windows.TPoint;
begin
  C := TAuControl(Pointer(GetPropW(Wnd, GestureProp)));
  if C = nil then Exit(DefWindowProcW(Wnd, Msg, WP, LP));
  case Msg of
    WM_GESTURENOTIFY_:
      begin
        { configured here and not passed on (as in Microsoft's sample): the
          parents would configure themselves too }
        C.ConfigureGestures;
        { a finger beside a splitter: no pan, so that its drag arrives as
          mouse messages and the splitter can take it }
        if LP <> 0 then
        begin
          Pt.x := PGestureNotify_(LP)^.ptsLocation.x;
          Pt.y := PGestureNotify_(LP)^.ptsLocation.y;
          if SplitterInTouchReach(C, Classes.Point(Pt.x, Pt.y)) <> nil then
            BlockPan(Wnd)
          else
          begin
            { or on an edge of the control itself that is dragged }
            Windows.ScreenToClient(Wnd, Pt);
            UseDpiOf(C);
            if C.TouchDragAt(Pt.x, Pt.y) then BlockPan(Wnd);
          end;
        end;
        Exit(0);
      end;
    WM_LBUTTONDOWN:
      { a press that comes from a finger, beside a splitter: the splitter
        is dragged }
      if MouseFromTouch then
      begin
        Pt.x := SmallInt(LP and $FFFF);
        Pt.y := SmallInt((LP shr 16) and $FFFF);
        Windows.ClientToScreen(Wnd, Pt);
        Sp := SplitterInTouchReach(C, Classes.Point(Pt.x, Pt.y));
        if Sp <> nil then
        begin
          UseDpiOf(C);
          Sp.TakeTouch(Wnd, WP, LP, Classes.Point(Pt.x, Pt.y));
          Exit(0);
        end;
      end;
    WM_GESTURE_:
      begin
        UseDpiOf(C);
        if C.HandleGesture(LP) then Exit(0);
      end;
    WM_NCDESTROY:
      begin
        Old := C.FOldProc;
        SetWindowLongPtrW(Wnd, GWLP_WNDPROC, LONG_PTR(Pointer(Old)));
        RemovePropW(Wnd, GestureProp);
        C.FOldProc := nil;
        Exit(CallWindowProcW(Old, Wnd, Msg, WP, LP));
      end;
  end;
  Result := CallWindowProcW(C.FOldProc, Wnd, Msg, WP, LP);
end;

procedure TAuControl.CreateWnd;
begin
  inherited CreateWnd;
  if GestureAtom = 0 then GestureAtom := GlobalAddAtomW('AulumicNS.AuControl');
  if (GestureAtom = 0) or (GetPropW(Handle, GestureProp) <> 0) then Exit;
  FOldProc := Windows.WNDPROC(GetWindowLongPtrW(Handle, GWLP_WNDPROC));
  SetPropW(Handle, GestureProp, THandle(Pointer(Self)));
  SetWindowLongPtrW(Handle, GWLP_WNDPROC, LONG_PTR(@GestureProc));
end;

procedure TAuControl.WndProc(var Message: TLMessage);
var
  Q0, Q1: Int64;
  I: Integer;
begin
  UseDpiOf(Self);
  if (PaintTally <> nil) and (Message.Msg = LM_PAINT) then
  begin
    QueryPerformanceCounter(Q0);
    inherited WndProc(Message);
    QueryPerformanceCounter(Q1);
    I := PaintTally.IndexOfName('WM_PAINT ' + ClassName);
    if I < 0 then I := PaintTally.Add('WM_PAINT ' + ClassName + '=0');
    PaintTally.Objects[I] := TObject(PtrInt(PaintTally.Objects[I]) + 1);
    PaintTally.ValueFromIndex[I] := IntToStr(StrToInt64Def(PaintTally.ValueFromIndex[I], 0) + Q1 - Q0);
    Exit;
  end;
  inherited WndProc(Message);
end;

procedure TAuControl.DoAutoAdjustLayout(const AMode: TLayoutAdjustmentPolicy;
  const AXProportion, AYProportion: Double);
begin
  inherited DoAutoAdjustLayout(AMode, AXProportion, AYProportion);
  if AMode = lapAutoAdjustForDPI then ScaleCached(AXProportion);
end;

procedure TAuControl.ScaleCached(K: Double);
begin
end;

procedure TAuControl.DpiChanged;
begin
  Resize;
  Invalidate;
end;

procedure TAuControl.SetBackRole(R: TAuRole);
begin
  if FBackRole = R then Exit;
  FBackRole := R;
  Invalidate;
end;

procedure TAuControl.EraseBackground(DC: HDC);
begin
  { painted completely in Paint }
end;

{ a resized control paints all of itself again. Windows keeps
  the old pixels of a resized window and repaints only the new strip, so
  what depends on the size (right-aligned columns, the splitter's line,
  centred content) would leave stale lines behind while a splitter is dragged. }
procedure TAuControl.Resize;
begin
  inherited Resize;
  if HandleAllocated then Invalidate;
end;

{ the paint buffer. The LCL's DoubleBuffered keeps one bitmap
  for all windows, as large as the largest one painted (in the main window
  nearly the whole window), and fills ALL of it before every paint: at
  3840 x 2037 px about 30 MB, some 3.4 ms of kernel time for every repaint
  of the peak meter or the seek bar (measured with --ui-bench). Here each
  paint uses a 32 bit DIB of the control's own size (from a small cache):
  Direct2D draws into it (AuGfx), and the copy to the screen is
  quick. (Not one large shared bitmap: the copy out of it
  takes 16 ms as a DIB and 30 ms as a bitmap compatible with the window,
  however small the part.) }
{ a 32 bit top-down DIB section and a memory DC with it }
function NewPaintBitmap(W, H: Integer; out ADC: HDC; out AOld: HBITMAP): HBITMAP;
var
  BI: TBitmapInfo;
  Bits: Pointer;
begin
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := W;
  BI.bmiHeader.biHeight := -H;
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  Bits := nil;
  ADC := CreateCompatibleDC(0);
  Result := CreateDIBSection(ADC, BI, DIB_RGB_COLORS, Bits, 0, 0);
  AOld := SelectObject(ADC, Result);
end;

{ the last few paint bitmaps, kept for a control of the same size (a list
  that scrolls paints the same size over and over; a new DIB is committed
  and zeroed by Windows each time) }
const
  PAINT_CACHE = 4;
  { a control of this many pixels or more paints through a render target of
    its own (400 x 400) }
  GPU_PAINT_MIN_PIXELS = 160000;
type
  TPaintBuf = record
    DC: HDC;
    Bmp, Old: HBITMAP;
    W, H: Integer;
    Busy: Boolean;
    Used: QWord;
  end;
var
  GPaintBufs: array[0..PAINT_CACHE - 1] of TPaintBuf;
  GPaintUse: QWord = 0;

procedure FreePaintBuf(var B: TPaintBuf);
begin
  if B.DC = 0 then Exit;
  SelectObject(B.DC, B.Old);
  DeleteObject(B.Bmp);
  DeleteDC(B.DC);
  B := Default(TPaintBuf);
end;

{ a bitmap of W x H from the cache (made when none is free), marked busy }
function TakePaintBuf(W, H: Integer): Integer;
var
  I, Oldest: Integer;
begin
  Inc(GPaintUse);
  for I := 0 to PAINT_CACHE - 1 do
    if (GPaintBufs[I].DC <> 0) and not GPaintBufs[I].Busy and (GPaintBufs[I].W = W) and
       (GPaintBufs[I].H = H) then
    begin
      GPaintBufs[I].Busy := True;
      GPaintBufs[I].Used := GPaintUse;
      Exit(I);
    end;
  { the least recently used one that is not busy is replaced }
  Oldest := -1;
  for I := 0 to PAINT_CACHE - 1 do
    if not GPaintBufs[I].Busy and ((Oldest < 0) or (GPaintBufs[I].Used < GPaintBufs[Oldest].Used)) then
      Oldest := I;
  Result := Oldest;
  if Result < 0 then Exit;            // all busy (paints inside paints): the caller makes one
  FreePaintBuf(GPaintBufs[Result]);
  GPaintBufs[Result].Bmp := NewPaintBitmap(W, H, GPaintBufs[Result].DC, GPaintBufs[Result].Old);
  GPaintBufs[Result].W := W;
  GPaintBufs[Result].H := H;
  GPaintBufs[Result].Busy := True;
  GPaintBufs[Result].Used := GPaintUse;
end;

procedure FreePaintBuffer;
var
  I: Integer;
begin
  for I := 0 to PAINT_CACHE - 1 do FreePaintBuf(GPaintBufs[I]);
end;

procedure TallyStep(const AName: string; var AQ: Int64);
var
  Q: Int64;
  I: Integer;
begin
  if PaintTally = nil then Exit;
  QueryPerformanceCounter(Q);
  I := PaintTally.IndexOfName(AName);
  if I < 0 then I := PaintTally.Add(AName + '=0');
  PaintTally.Objects[I] := TObject(PtrInt(PaintTally.Objects[I]) + 1);
  PaintTally.ValueFromIndex[I] := IntToStr(StrToInt64Def(PaintTally.ValueFromIndex[I], 0) + Q - AQ);
  AQ := Q;
end;

procedure TAuControl.Paint;
var
  G: TGfx;
  Q0, Q1, QS: Int64;
  I, W, H: Integer;
  DC, MemDC: HDC;
  Bmp, OldBmp: HBITMAP;
  Own: Boolean;
  R: TRect;
  Br: HBRUSH;
  C: TARGB;
begin
  if PaintTally <> nil then QueryPerformanceCounter(Q0);
  QS := Q0;
  W := Width;
  H := Height;
  if (W <= 0) or (H <= 0) or GfxStopped then Exit;
  DC := Canvas.Handle;
  TallyStep(' step: canvas', QS);
  { a large control, or one that repaints all the time, has a
    render target of its own: the graphics card draws and shows it (a list of
    2400 x 1600 px: 3 ms; through the buffer below 29 ms, nearly all of it
    copying). Small controls take the buffer: a target each would cost memory
    for nothing. }
  { Not in a popup (a menu, the volume or Signal Path popup): it is painted
    once while still invisible and then revealed, and the first picture of a
    new target can be lost or late - the popup would appear empty and fill a
    moment later. Through the buffer the picture is there before it shows. }
  G := nil;
  if GpuPaintAllowed and HandleAllocated and (FGpuPaint or (Int64(W) * H >= GPU_PAINT_MIN_PIXELS)) and
    not (GetParentForm(Self) is TAuPopup) then
  begin
    if FWinTarget = nil then FWinTarget := TGfxWindowTarget.Create;
    G := FWinTarget.BeginPaint(Handle, W, H);
  end
  else if FWinTarget <> nil then
    FreeAndNil(FWinTarget);
  if G <> nil then
  begin
    TallyStep(' step: d2d begin', QS);
    try
      G.Clear(EffBack);
      DoPaint(G);
      TallyStep(' step: DoPaint', QS);
    finally
      G.Free;
    end;
    TallyStep(' step: d2d end', QS);
  end
  else
  begin
  { a buffer of this control's size (a copy out of a large shared bitmap took
    16 - 30 ms, however small the part copied), from the cache }
  I := TakePaintBuf(W, H);
  Own := I < 0;
  if Own then Bmp := NewPaintBitmap(W, H, MemDC, OldBmp)
  else MemDC := GPaintBufs[I].DC;
  try
    { this control's part only: its background (a control paints all of it;
      nothing of an earlier paint shows if one does not) }
    { clipped to this control's part: drawing on an unclipped DC of the large
      shared bitmap took 40 ms per paint (it works on the whole clip area) }
    TallyStep(' step: buffer', QS);
    IntersectClipRect(MemDC, 0, 0, W, H);
    C := EffBack;
    Br := CreateSolidBrush(RGB((C shr 16) and $FF, (C shr 8) and $FF, C and $FF));
    R := Rect(0, 0, W, H);
    Windows.FillRect(MemDC, R, Br);
    DeleteObject(Br);
    TallyStep(' step: clear', QS);
    G := TGfx.Create(MemDC, W, H);
    TallyStep(' step: d2d begin', QS);
    try
      DoPaint(G);
      TallyStep(' step: DoPaint', QS);
    finally
      G.Free;
    end;
    TallyStep(' step: d2d end', QS);
    SelectClipRgn(MemDC, 0);
    { (the paint DC is clipped to what needs painting) }
    BitBlt(DC, 0, 0, W, H, MemDC, 0, 0, SRCCOPY);
    TallyStep(' step: blit', QS);
  finally
    if Own then
    begin
      SelectObject(MemDC, OldBmp);
      DeleteObject(Bmp);
      DeleteDC(MemDC);
    end
    else
      GPaintBufs[I].Busy := False;
  end;
  end;
  if PaintTally <> nil then
  begin
    { count and time per class (Objects: paints; the value: ticks) }
    QueryPerformanceCounter(Q1);
    I := PaintTally.IndexOfName(ClassName);
    if I < 0 then I := PaintTally.Add(ClassName + '=0');
    PaintTally.Objects[I] := TObject(PtrInt(PaintTally.Objects[I]) + 1);
    PaintTally.ValueFromIndex[I] := IntToStr(StrToInt64Def(PaintTally.ValueFromIndex[I], 0) + Q1 - Q0);
  end;
  { a render target was lost with this paint (the graphics driver was
    restarted): everything is painted again, with new targets }
  if GfxTargetWasLost then RefreshAllForms;
end;

procedure TAuControl.DoPaint(G: TGfx);
begin
  G.FillRect(0, 0, Width, Height, EffBack);
end;

procedure RenderChildrenOf(AParent: TWinControl; G: TGfx); forward;

procedure TAuControl.RenderTo(G: TGfx);
begin
  DoPaint(G);
  RenderChildrenOf(Self, G);
end;

procedure TAuControl.MouseEnter;
begin
  inherited MouseEnter;
  FHover := True;
  Invalidate;
  AnimTo(FHoverA, 1, ANIM_FAST, Self);
end;

procedure TAuControl.MouseLeave;
begin
  inherited MouseLeave;
  FHover := False;
  Invalidate;
  AnimTo(FHoverA, 0, ANIM_NORMAL, Self);
end;

procedure TAuControl.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if FFocusOnClick and TabStop and CanFocus and not Focused then SetFocus;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TAuControl.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (not KeyboardCues) and (Key in [VK_TAB, VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN, VK_HOME, VK_END,
    VK_PRIOR, VK_NEXT, VK_SPACE, VK_RETURN]) then
  begin
    KeyboardCues := True;
    Invalidate;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TAuControl.DoEnter;
var
  P: TWinControl;
begin
  inherited DoEnter;
  if GetKeyState(VK_TAB) < 0 then
  begin
    KeyboardCues := True;
    { the Tab key came to a control of a scrolled page: the
      page follows, so the control with the focus is in view (it glides
      there with animations on) }
    P := Parent;
    while P <> nil do
    begin
      if P is TAuScrollBox then
      begin
        TAuScrollBox(P).ScrollIntoView(Self, 28);
        Break;
      end;
      P := P.Parent;
    end;
  end;
  Invalidate;
end;

procedure TAuControl.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TAuControl.EnabledChanged;
begin
  inherited EnabledChanged;
  Invalidate;
end;

function TAuControl.ShowFocus: Boolean;
begin
  Result := Focused and KeyboardCues;
end;

procedure TAuControl.DrawFocusRing(G: TGfx; X, Y, W, H, R: Single);
begin
  if ShowFocus then G.StrokeRound(X, Y, W, H, R, SF(2), clAccent);
end;

function TAuControl.ParentBack: TARGB;
begin
  if Parent is TAuControl then Result := TAuControl(Parent).EffBack
  else if (Parent is TAuPopup) then Result := clCard
  else Result := clBg;
end;

function TAuControl.EffBack: TARGB;
begin
  if FBackRole <> crInherit then Result := RoleColor(FBackRole)
  else Result := ParentBack;
end;

{ ---- TAuPanel ---- }

constructor TAuPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRadius := 0;
  FBorderRole := crInherit;
  FBorderSides := 15;
end;

procedure TAuPanel.DoPaint(G: TGfx);
var
  BC: TARGB;
begin
  BC := 0;
  if FBorderRole <> crInherit then BC := RoleColor(FBorderRole);
  if FRadius > 0 then
  begin
    G.FillRect(0, 0, Width, Height, ParentBack);
    G.FillRound(0, 0, Width, Height, S(FRadius), EffBack);
    if BC <> 0 then G.StrokeRound(0, 0, Width, Height, S(FRadius), 1, BC);
  end
  else
  begin
    G.FillRect(0, 0, Width, Height, EffBack);
    if BC <> 0 then
    begin
      if FBorderSides and 1 <> 0 then G.FillRect(0, 0, 1, Height, BC);
      if FBorderSides and 2 <> 0 then G.FillRect(0, 0, Width, 1, BC);
      if FBorderSides and 4 <> 0 then G.FillRect(Width - 1, 0, 1, Height, BC);
      if FBorderSides and 8 <> 0 then G.FillRect(0, Height - 1, Width, 1, BC);
    end;
  end;
end;

{ ---- TAuLabel ---- }

constructor TAuLabel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSize := 13;
  FRole := crText;
  FVAlign := 1;
  Height := S(20);
  Width := S(100);
end;

function TAuLabel.Font: TGfxFont;
begin
  if FMono then Result := MonoFont(FSize, FBold)
  else if FItalic then Result := UIFontI(FSize)
  else Result := UIFont(FSize, FBold);
end;

procedure TAuLabel.FitWidth;
begin
  Width := Ceil(TextWidth(FCaption, Font)) + S(4);
end;

procedure TAuLabel.SetCaption(const V: string);
begin
  if V = FCaption then Exit;
  FCaption := V;
  if FAutoWidth then FitWidth;
  Invalidate;
end;

procedure TAuLabel.SetRole(V: TAuRole);
begin
  if V = FRole then Exit;
  FRole := V;
  Invalidate;
end;

procedure TAuLabel.DoPaint(G: TGfx);
var
  C: TARGB;
  Fl: Integer;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  C := RoleColor(FRole);
  if C = 0 then C := clText;
  if not Enabled then C := clTextFaint;
  Fl := 0;
  if FWrap then Fl := tfWrap;
  G.Text(FCaption, 0, 0, Width, Height, Font, C, FHAlign, FVAlign, Fl);
end;

{ ---- TAuButton ---- }

constructor TAuButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(96);
  Height := S(32);
  TabStop := True;
  FKind := bkNormal;
end;

procedure TAuButton.SetCaption(const V: string);
begin
  FCaption := V;
  Invalidate;
end;

procedure TAuButton.SetDown(V: Boolean);
begin
  if V = FDown then Exit;
  FDown := V;
  Invalidate;
end;

procedure TAuButton.SetIcon(V: TAuIcon);
begin
  FIcon := V;
  Invalidate;
end;

function TAuButton.PreferredWidth: Integer;
begin
  Result := Ceil(TextWidth(FCaption, UIFont(13, FKind = bkPrimary))) + S(32);
  if FIcon <> icNone then Inc(Result, S(24));
  if FCaption = '' then Result := Height;
end;

procedure TAuButton.DoPaint(G: TGfx);
var
  Bg, Fg, Bd: TARGB;
  R, IconSz, TW, Total, X0: Single;
  F: TGfxFont;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  R := S(7);
  Bd := 0;
  case FKind of
    bkPrimary:
      begin
        Bg := HoverMix(clAccent, clAccentHi); Fg := clOnAccent;
        if FPressed then Bg := clAccentLo;
      end;
    bkFlat:
      begin
        Bg := 0; Fg := HoverMix(clTextDim, clText);
        if FPressed then begin Bg := clPressed; Fg := clText; end
        else if HoverT > 0 then Bg := HoverMix(EffBack, clHover);
      end;
    bkDanger:
      begin
        Bg := Blend(EffBack, clBad, 0.16); Fg := clBad;
        if FPressed then Bg := Blend(EffBack, clBad, 0.30) else Bg := Blend(EffBack, clBad, 0.16 + 0.07 * HoverT);
      end;
  else
    begin
      Bg := HoverMix(clCard, clHover); Fg := clText; Bd := clBorder;
      if FPressed then Bg := clPressed;
    end;
  end;
  if FDown then
  begin
    Bg := clSelection; Fg := clText;
  end;
  if not Enabled then
  begin
    Fg := clTextFaint;
    if FKind = bkPrimary then Bg := Blend(clAccent, EffBack, 0.6);
  end;
  if Bg <> 0 then G.FillRound(0, 0, Width, Height, R, Bg);
  if Bd <> 0 then G.StrokeRound(0, 0, Width, Height, R, 1, Bd);
  DrawFocusRing(G, 0, 0, Width, Height, R);
  F := UIFont(13, FKind = bkPrimary);
  IconSz := S(16);
  if FIcon <> icNone then
  begin
    if FCaption = '' then
      DrawIcon(G, FIcon, Width / 2, Height / 2, IconSz, Fg)
    else
    begin
      TW := TextWidth(FCaption, F);
      Total := IconSz + S(8) + TW;
      X0 := (Width - Total) / 2;
      DrawIcon(G, FIcon, X0 + IconSz / 2, Height / 2, IconSz, Fg);
      G.Text(FCaption, X0 + IconSz + S(8), 0, TW + S(4), Height, F, Fg, 0, 1, tfNoEllipsis);
    end;
  end
  else
    G.Text(FCaption, S(6), 0, Width - S(12), Height, F, Fg, 1, 1);
end;

procedure TAuButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

procedure TAuButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FPressed := False;
  Invalidate;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TAuButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key in [VK_SPACE, VK_RETURN] then
  begin
    Key := 0;
    Click;
  end;
end;

procedure TAuButton.Click;
var
  F: TCustomForm;
begin
  if not Enabled then Exit;
  inherited Click;
  if FModalResult <> mrNone then
  begin
    F := GetParentForm(Self);
    if F <> nil then F.ModalResult := FModalResult;
  end;
end;

{ ---- TAuIconButton ---- }

constructor TAuIconButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(36);
  Height := S(36);
  FIconSize := 18;
  FIconRole := crTextDim;
  TabStop := True;
end;

procedure TAuIconButton.SetIcon(V: TAuIcon);
begin
  if V = FIcon then Exit;
  FIcon := V;
  Invalidate;
end;

procedure TAuIconButton.SetActive(V: Boolean);
begin
  if V = FActive then Exit;
  FActive := V;
  Invalidate;
end;

procedure TAuIconButton.DoPaint(G: TGfx);
var
  Fg, Bg: TARGB;
  R, CX, CY, D: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  D := Math.Min(Width, Height);
  R := D / 2;
  CX := Width / 2;
  CY := Height / 2;
  Fg := RoleColor(FIconRole);
  Bg := 0;
  case FStyle of
    ibFilled:
      begin
        Bg := clText;
        Fg := EffBack;
        if FPressed then Bg := Blend(clText, EffBack, 0.25)
        else Bg := Blend(clText, clAccent, 0.35 * HoverT);
      end;
    ibCircle:
      begin
        Bg := clHover;
        if FPressed then Bg := clPressed else Bg := Blend(clHover, clText, 0.08 * HoverT);
        Fg := HoverMix(Fg, clText);
      end;
  else
    begin
      if FPressed then Bg := clPressed else if HoverT > 0 then Bg := HoverMix(EffBack, clHover);
      if FPressed then Fg := clText else Fg := HoverMix(Fg, clText);
    end;
  end;
  if FActive and (FStyle <> ibFilled) then Fg := clAccentText;
  if not Enabled then
  begin
    Fg := clTextFaint;
    if FStyle = ibFilled then begin Bg := clBorderHi; Fg := EffBack; end
    else Bg := 0;
  end;
  if Bg <> 0 then G.FillCircle(CX, CY, R - 0.5, Bg);
  if ShowFocus then G.StrokeCircle(CX, CY, R - SF(1.5), SF(2), clAccent);
  DrawIcon(G, FIcon, CX, CY, S(FIconSize), Fg);
  if FActive and FShowDot then G.FillCircle(CX, CY + S(FIconSize) / 2 + S(4), SF(1.8), clAccentText);
end;

procedure TAuIconButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

procedure TAuIconButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FPressed := False;
  Invalidate;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TAuIconButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key in [VK_SPACE, VK_RETURN] then
  begin
    Key := 0;
    Click;
  end;
end;

procedure TAuIconButton.Click;
begin
  if not Enabled then Exit;
  inherited Click;
end;

{ ---- TAuCheckBox ---- }

constructor TAuCheckBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(200);
  Height := S(26);
  TabStop := True;
end;

procedure TAuCheckBox.SetChecked(V: Boolean);
begin
  if V = FChecked then Exit;
  FChecked := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TAuCheckBox.SetCaption(const V: string);
begin
  FCaption := V;
  Invalidate;
end;

procedure TAuCheckBox.DoPaint(G: TGfx);
var
  B, Y0: Single;
  Fg: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  B := S(17);
  Y0 := (Height - B) / 2;
  DrawCheckBox(G, S(5), Y0, B, FChecked, FHover, Enabled);
  if ShowFocus then G.StrokeRound(S(5) - SF(3), Y0 - SF(3), B + SF(6), B + SF(6), S(6), SF(1.6), clAccent);
  Fg := clText;
  if not Enabled then Fg := clTextFaint;
  G.Text(FCaption, B + S(15), 0, Width - B - S(15), Height, UIFont(13), Fg, 0, 1);
end;

procedure TAuCheckBox.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = VK_SPACE then
  begin
    Key := 0;
    Click;
  end;
end;

procedure TAuCheckBox.Click;
begin
  if not Enabled then Exit;
  Checked := not Checked;
  inherited Click;
end;

{ ---- TAuRadio ---- }

constructor TAuRadio.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(200);
  Height := S(26);
  TabStop := True;
  FWantKeys := True;
end;

function TAuRadio.Siblings: TList;
var
  I: Integer;
  C: TControl;
begin
  Result := TList.Create;
  if Parent = nil then Exit;
  for I := 0 to Parent.ControlCount - 1 do
  begin
    C := Parent.Controls[I];
    if (C is TAuRadio) and (TAuRadio(C).FGroup = FGroup) then Result.Add(C);
  end;
end;

procedure TAuRadio.SetChecked(V: Boolean);
var
  L: TList;
  I: Integer;
begin
  if V = FChecked then Exit;
  FChecked := V;
  if V then
  begin
    L := Siblings;
    for I := 0 to L.Count - 1 do
      if L[I] <> Pointer(Self) then TAuRadio(L[I]).Checked := False;
    L.Free;
  end;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TAuRadio.SetCaption(const V: string);
begin
  FCaption := V;
  Invalidate;
end;

procedure TAuRadio.DoPaint(G: TGfx);
var
  R, CY: Single;
  Fg: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  R := S(9);
  CY := Height / 2;
  if FChecked then
  begin
    G.FillCircle(S(5) + R, CY, R, clAccent);
    G.FillCircle(S(5) + R, CY, R * 0.42, clOnAccent);
  end
  else
  begin
    G.FillCircle(S(5) + R, CY, R, clInput);
    if FHover then G.StrokeCircle(S(5) + R, CY, R - SF(0.6), SF(1.2), clTextFaint)
    else G.StrokeCircle(S(5) + R, CY, R - SF(0.6), SF(1.2), clBorderHi);
  end;
  if ShowFocus then G.StrokeCircle(S(5) + R, CY, R + SF(2.5), SF(1.6), clAccent);
  Fg := clText;
  if not Enabled then Fg := clTextFaint;
  G.Text(FCaption, 2 * R + S(15), 0, Width - 2 * R - S(15), Height, UIFont(13), Fg, 0, 1);
end;

procedure TAuRadio.KeyDown(var Key: Word; Shift: TShiftState);
var
  L: TList;
  I: Integer;
  Nxt: TAuRadio;
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_SPACE: begin Key := 0; Click; end;
    VK_UP, VK_LEFT, VK_DOWN, VK_RIGHT:
      begin
        L := Siblings;
        I := L.IndexOf(Self);
        if Key in [VK_UP, VK_LEFT] then Dec(I) else Inc(I);
        if I < 0 then I := L.Count - 1;
        if I >= L.Count then I := 0;
        Nxt := TAuRadio(L[I]);
        L.Free;
        Key := 0;
        if Nxt.CanFocus then Nxt.SetFocus;
        Nxt.Checked := True;
      end;
  end;
end;

procedure TAuRadio.Click;
begin
  if not Enabled then Exit;
  Checked := True;
  inherited Click;
end;

{ ---- TAuSwitch ---- }

constructor TAuSwitch.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(300);
  Height := S(28);
  TabStop := True;
end;

procedure TAuSwitch.SetChecked(V: Boolean);
begin
  if V = FChecked then Exit;
  FChecked := V;
  Invalidate;
  { a switch that is not on screen yet is simply set }
  if HandleAllocated and IsVisible then AnimTo(FKnobA, Ord(V), ANIM_NORMAL, Self)
  else AnimSet(FKnobA, Ord(V));
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TAuSwitch.DoPaint(G: TGfx);
var
  TW, TH, TX, TY, KR, K: Single;
  Fg, Tr: TARGB;
  Desc: Boolean;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  TW := S(36);
  TH := S(20);
  TX := Width - TW - S(6);      // room for the focus ring
  TY := (Height - TH) / 2;
  Desc := FDescription <> '';
  if Desc then TY := S(4);
  { the knob slides, the track changes colour with it (FKnobA: 0 = off, 1 = on) }
  K := FKnobA.Value;
  Tr := Blend(HoverMix(clThumb, clBorderHi), clAccent, K);
  if not Enabled then Tr := Blend(Tr, EffBack, 0.5);
  G.FillRound(TX, TY, TW, TH, TH / 2, Tr);
  KR := TH / 2 - S(3);
  G.FillCircle(TX + TH / 2 + (TW - TH) * K, TY + TH / 2, KR, Blend(Blend(clText, Tr, 0.15), clOnAccent, K));
  if ShowFocus then G.StrokeRound(TX - SF(3), TY - SF(3), TW + SF(6), TH + SF(6), (TH + SF(6)) / 2, SF(1.6), clAccent);
  Fg := clText;
  if not Enabled then Fg := clTextFaint;
  if Desc then
  begin
    G.Text(FCaption, 0, 0, TX - S(12), S(28), UIFont(13), Fg, 0, 1);
    G.Text(FDescription, 0, S(26), TX - S(12), Height - S(26), UIFont(12), IfC(Enabled, clTextDim, clTextFaint), 0, 0, tfWrap);
  end
  else
    G.Text(FCaption, 0, 0, TX - S(12), Height, UIFont(13), Fg, 0, 1);
end;

procedure TAuSwitch.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = VK_SPACE then
  begin
    Key := 0;
    Click;
  end;
end;

procedure TAuSwitch.Click;
begin
  if not Enabled then Exit;
  Checked := not Checked;
  inherited Click;
end;

{ ---- TAuScrollBar ---- }

constructor TAuScrollBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(12);
  Height := S(12);
  FMax := 0;
  FPage := 1;
  FSmall := 1;
  FFocusOnClick := False;
end;

function TAuScrollBar.MaxPos: Integer;
begin
  Result := FMax - FPage;
  if Result < 0 then Result := 0;
end;

function TAuScrollBar.NeedScroll: Boolean;
begin
  Result := FMax > FPage;
end;

procedure TAuScrollBar.SetParams(AMax, APage: Integer);
begin
  if APage < 1 then APage := 1;
  FMax := AMax;
  FPage := APage;
  if FPos > MaxPos then FPos := MaxPos;
  if FPos < 0 then FPos := 0;
  Invalidate;
end;

procedure TAuScrollBar.SetPos(V: Integer);
begin
  if V > MaxPos then V := MaxPos;
  if V < 0 then V := 0;
  { set from outside (thumb, keys, a finger): a glide on its way ends here }
  if not FInGlide and FGlideA.Running then AnimSet(FGlideA, V);
  if not FInGlide and not FInRows and (FOffsA.Value <> 0) then AnimSet(FOffsA, 0);
  if V = FPos then Exit;
  FPos := V;
  Invalidate;
  if Assigned(FOnScroll) then FOnScroll(Self);
end;

const
  SCROLL_GLIDE_MS = 200;

procedure TAuScrollBar.GlideStep(Sender: TObject; ADone: Boolean);
begin
  FInGlide := True;
  try
    SetPos(Round(FGlideA.Value));
  finally
    FInGlide := False;
  end;
end;

procedure TAuScrollBar.OffsStep(Sender: TObject; ADone: Boolean);
begin
  if Assigned(FOnScroll) then FOnScroll(Self);
end;

function TAuScrollBar.GlideTarget: Integer;
begin
  if FGlideA.Running then Result := Round(FGlideA.ToV) else Result := FPos;
end;

procedure TAuScrollBar.GlideTo(APos: Integer);
begin
  if not FGlideA.Running then AnimSet(FGlideA, FPos);
  AnimTo(FGlideA, EnsureRange(APos, 0, MaxPos), SCROLL_GLIDE_MS, Self, @GlideStep);
end;

procedure TAuScrollBar.WheelBy(ADelta: Integer);
begin
  GlideTo(GlideTarget + ADelta);
end;

procedure TAuScrollBar.WheelRows(ARows, ARowPx: Integer);
var
  Old: Integer;
  Lag: Single;
begin
  Old := FPos;
  FInRows := True;
  try
    SetPos(FPos + ARows);
  finally
    FInRows := False;
  end;
  if (FPos = Old) or not AnimActive then Exit;
  Lag := FOffsA.Value + (FPos - Old) * ARowPx;
  AnimSet(FOffsA, Lag);
  AnimTo(FOffsA, 0, SCROLL_GLIDE_MS, Self, @OffsStep);
end;

function TAuScrollBar.GlideOffset: Integer;
begin
  Result := Round(FOffsA.Value);
end;

function TAuScrollBar.TrackLen: Integer;
begin
  if FKind = aoVertical then Result := Height - S(4) else Result := Width - S(4);
end;

procedure TAuScrollBar.GetThumb(out T, H: Integer);
var
  Track: Integer;
begin
  Track := TrackLen;
  if FMax <= 0 then
  begin
    T := S(2); H := Track;
    Exit;
  end;
  H := Round(Track * FPage / FMax);
  if H < S(32) then H := S(32);
  if H > Track then H := Track;
  if MaxPos > 0 then T := S(2) + Round((Track - H) * FPos / MaxPos) else T := S(2);
end;

procedure TAuScrollBar.DoPaint(G: TGfx);
var
  T, H: Integer;
  C: TARGB;
  W: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if not NeedScroll then Exit;
  GetThumb(T, H);
  C := clThumb;
  W := S(5);
  if FDrag then begin C := clThumbHi; W := S(8); end
  else begin C := HoverMix(clThumb, clThumbHi); W := S(5) + (S(8) - S(5)) * HoverT; end;   // the thumb grows under the pointer
  if FKind = aoVertical then
    G.FillRound((Width - W) / 2, T, W, H, W / 2, C)
  else
    G.FillRound(T, (Height - W) / 2, H, W, W / 2, C);
end;

procedure TAuScrollBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  T, H, P: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not NeedScroll then Exit;
  GetThumb(T, H);
  if FKind = aoVertical then P := Y else P := X;
  if (P >= T) and (P < T + H) then
  begin
    FDrag := True;
    FDragAt := P;
    FDragPos := FPos;
    Invalidate;
  end
  else if P < T then Position := FPos - FPage
  else Position := FPos + FPage;
end;

procedure TAuScrollBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  T, H, Track, P: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDrag then Exit;
  GetThumb(T, H);
  Track := TrackLen - H;
  if Track <= 0 then Exit;
  if FKind = aoVertical then P := Y else P := X;
  Position := FDragPos + Round((P - FDragAt) * MaxPos / Track);
end;

procedure TAuScrollBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDrag := False;
  Invalidate;
end;

function TAuScrollBar.GesturePan: Integer;
begin
  Result := GESTURE_PAN_NONE;
end;

function TAuScrollBar.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  WheelBy(-Sign(WheelDelta) * FSmall * 3);
  Result := True;
end;

procedure TAuScrollBar.ScaleCached(K: Double);
begin
  if FSmall > 1 then FSmall := Math.Max(1, Round(FSmall * K));
end;

{ ---- TAuSlider ---- }

constructor TAuSlider.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := S(160);
  Height := S(24);
  FMin := 0;
  FMax := 1;
  FStep := 0.02;
  FBigStep := 0.1;
  TabStop := True;
  FWantKeys := True;
  FHoverX := -1;
end;

procedure TAuSlider.SetRange(AMin, AMax: Double);
begin
  if AMax <= AMin then AMax := AMin + 1;
  FMin := AMin;
  FMax := AMax;
  if FPos < FMin then FPos := FMin;
  if FPos > FMax then FPos := FMax;
  Invalidate;
end;

procedure TAuSlider.SetPos(V: Double);
var
  Old: Double;
begin
  if FDragging then Exit;      // the user is moving it - external updates wait
  if V < FMin then V := FMin;
  if V > FMax then V := FMax;
  if V = FPos then Exit;
  Old := FPos;
  FPos := V;
  { a repaint only when the fill's end moves to another pixel
    (the seek bar is set 20 times a second; on a 1080p screen its end moves
    less than half a pixel per step) }
  if (FMax > FMin) and (Round(TrackWidth * (V - FMin) / (FMax - FMin)) =
    Round(TrackWidth * (Old - FMin) / (FMax - FMin))) then Exit;
  Invalidate;
end;

procedure TAuSlider.UserSet(V: Double; Final: Boolean);
begin
  if V < FMin then V := FMin;
  if V > FMax then V := FMax;
  if V <> FPos then
  begin
    FPos := V;
    Invalidate;
    if Assigned(FOnChange) then FOnChange(Self);
  end;
  if Final and Assigned(FOnChangeEnd) then FOnChangeEnd(Self);
end;

{ the track is inset by the radius of the focus halo, so the halo is never
  clipped at either end }
function TAuSlider.TrackLeft: Single;
begin
  Result := S(11);
end;

function TAuSlider.TrackWidth: Single;
begin
  Result := Width - 2 * S(11);
end;

function TAuSlider.ValueAt(X: Integer): Double;
var
  T: Double;
begin
  T := (X - TrackLeft) / Math.Max(1, TrackWidth);
  if T < 0 then T := 0;
  if T > 1 then T := 1;
  Result := FMin + T * (FMax - FMin);
end;

procedure TAuSlider.DoPaint(G: TGfx);
var
  TY, TH, FX, KX: Single;
  Hot: Boolean;
  Fill: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  Hot := FHover or FDragging or ShowFocus;
  TH := S(4);
  TY := (Height - TH) / 2;
  G.FillRound(TrackLeft, TY, TrackWidth, TH, TH / 2, clThumb);
  FX := TrackWidth * (FPos - FMin) / (FMax - FMin);
  if Hot or FAlwaysAccent then Fill := clAccent else Fill := clTextDim;
  if not Enabled then Fill := clBorderHi;
  if FX > 0 then G.FillRound(TrackLeft, TY, Math.Max(TH, FX), TH, TH / 2, Fill);
  if (Hot or FAlwaysThumb) and Enabled then
  begin
    KX := TrackLeft + FX;
    if ShowFocus then G.FillCircle(KX, Height / 2, S(10), WithAlpha(clAccent, $50));
    G.FillCircle(KX, Height / 2, S(7), clText);
  end;
end;

procedure TAuSlider.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  FDragging := True;
  UserSet(ValueAt(X), False);
end;

procedure TAuSlider.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  FHoverX := X;
  if FDragging then UserSet(ValueAt(X), False);
end;

procedure TAuSlider.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging then
  begin
    UserSet(ValueAt(X), False);
    FDragging := False;
    if Assigned(FOnChangeEnd) then FOnChangeEnd(Self);
    Invalidate;
  end;
end;

procedure TAuSlider.KeyDown(var Key: Word; Shift: TShiftState);
var
  St: Double;
begin
  inherited KeyDown(Key, Shift);
  St := FStep * (FMax - FMin);
  if ssShift in Shift then St := FBigStep * (FMax - FMin);
  case Key of
    VK_LEFT, VK_DOWN: UserSet(FPos - St, True);
    VK_RIGHT, VK_UP: UserSet(FPos + St, True);
    VK_PRIOR: UserSet(FPos + FBigStep * (FMax - FMin), True);
    VK_NEXT: UserSet(FPos - FBigStep * (FMax - FMin), True);
    VK_HOME: UserSet(FMin, True);
    VK_END: UserSet(FMax, True);
  else
    Exit;
  end;
  Key := 0;
end;

function TAuSlider.GesturePan: Integer;
begin
  Result := GESTURE_PAN_NONE;
end;

function TAuSlider.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := Enabled;
  if Result then UserSet(FPos + Sign(WheelDelta) * FStep * (FMax - FMin), True);
end;

{ ---- TAuProgress ---- }

constructor TAuProgress.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := S(6);
end;

procedure TAuProgress.SetPos(V: Single);
begin
  if V < 0 then V := 0;
  if V > 1 then V := 1;
  FPos := V;
  Invalidate;
end;

procedure TAuProgress.DoPaint(G: TGfx);
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  G.FillRound(0, 0, Width, Height, Height / 2, clThumb);
  if FPos > 0 then G.FillRound(0, 0, Math.Max(Height, Width * FPos), Height, Height / 2, clAccent);
end;

{ ---- TAuEdit ---- }

constructor TAuEdit.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FWantKeys := True;
  TabStop := True;
  Width := S(160);
  Height := S(32);
  FMin := -MaxInt;
  FMax := MaxInt;
  FSpinHot := -1;
  Cursor := crIBeam;
end;

function TAuEdit.SpinLeft: Integer;
begin
  Result := Width - S(26);
end;

procedure TAuEdit.MouseLeave;
begin
  FSpinHot := -1;
  inherited MouseLeave;
end;

destructor TAuEdit.Destroy;
begin
  if FocusedEdit = Self then FocusedEdit := nil;
  inherited Destroy;
end;

function TAuEdit.GetText: string;
begin
  Result := UTF8Encode(FText);
end;

procedure TAuEdit.SetText(const V: string);
begin
  FText := UTF8Decode(V);
  FCaret := Length(FText);
  FAnchor := FCaret;
  FScrollX := 0;
  Invalidate;
end;

function TAuEdit.GetValue: Integer;
begin
  Result := StrToIntDef(Trim(GetText), FMin);
  if Result < FMin then Result := FMin;
  if Result > FMax then Result := FMax;
end;

procedure TAuEdit.SetValue(V: Integer);
begin
  if V < FMin then V := FMin;
  if V > FMax then V := FMax;
  SetText(IntToStr(V));
end;

procedure TAuEdit.StepValue(D: Integer);
var
  V: Int64;
begin
  V := Int64(GetValue) + D;
  if V < FMin then V := FMin;
  if V > FMax then V := FMax;
  SetValue(Integer(V));
  DoChanged;
end;

function TAuEdit.HasSel: Boolean;
begin
  Result := FCaret <> FAnchor;
end;

procedure TAuEdit.DeleteSel;
var
  A, B: Integer;
begin
  A := Math.Min(FCaret, FAnchor);
  B := Math.Max(FCaret, FAnchor);
  Delete(FText, A + 1, B - A);
  FCaret := A;
  FAnchor := A;
end;

procedure TAuEdit.InsertText(const T: UnicodeString);
var
  U: UnicodeString;
  I: Integer;
begin
  if FReadOnly then Exit;
  U := '';
  for I := 1 to Length(T) do
    if T[I] >= ' ' then U := U + T[I];
  if HasSel then DeleteSel;
  Insert(U, FText, FCaret + 1);
  Inc(FCaret, Length(U));
  FAnchor := FCaret;
  DoChanged;
end;

function TAuEdit.TextLeft: Integer;
begin
  if FSearch then Result := S(34) else Result := S(10);
end;

function TAuEdit.TextAreaW: Integer;
begin
  Result := Width - TextLeft - S(10);
  if FSpin then Dec(Result, S(18));
  if FSearch then Dec(Result, S(22));
end;

function TAuEdit.ClearRect: TRect;
begin
  Result := Rect(Width - S(30), 0, Width, Height);
end;

function TAuEdit.CaretPx(I: Integer): Single;
begin
  Result := TextWidthW(Copy(FText, 1, I), UIFont(13));
end;

function TAuEdit.PosFromX(X: Integer): Integer;
var
  I: Integer;
  Px, Prev, Target: Single;
begin
  Target := X - TextLeft + FScrollX;
  Prev := 0;
  for I := 1 to Length(FText) do
  begin
    Px := CaretPx(I);
    if Target < (Prev + Px) / 2 then Exit(I - 1);
    Prev := Px;
  end;
  Result := Length(FText);
end;

procedure TAuEdit.EnsureCaretVisible;
var
  Px: Single;
begin
  Px := CaretPx(FCaret);
  if Px - FScrollX > TextAreaW then FScrollX := Px - TextAreaW + S(2);
  if Px - FScrollX < 0 then FScrollX := Px;
  if FScrollX < 0 then FScrollX := 0;
end;

procedure TAuEdit.DoChanged;
begin
  EnsureCaretVisible;
  CaretOn := True;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TAuEdit.SelectAll;
begin
  FAnchor := 0;
  FCaret := Length(FText);
  Invalidate;
end;

procedure TAuEdit.DoPaint(G: TGfx);
var
  Bd, Bg: TARGB;
  TL, A, B: Integer;
  X1, X2, CX, R: Single;
  F: TGfxFont;
  Fg: TARGB;
  St: UINT;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  { a search box looks like every other input (and like a drop button next
    to it): the same corners, fill and border }
  R := S(7);
  Bg := clInput;
  G.FillRound(0, 0, Width, Height, R, Bg);
  if Focused then Bd := clAccent
  else if HoverT > 0 then Bd := HoverMix(clInputLine, clInputLineHi)
  else Bd := clInputLine;
  if Bd <> 0 then
  begin
    if Focused then G.StrokeRound(0, 0, Width, Height, R, FocusLineW, Bd)
    else G.StrokeRound(0, 0, Width, Height, R, 1, Bd);
  end;
  if FSearch then DrawIcon(G, icSearch, S(18), Height / 2, S(15), clTextDim);
  F := UIFont(13);
  TL := TextLeft;
  { intersect (a replaced clip would lose the parent's in RenderTo:
    a field of a scrolled page would show outside it in the screenshots) }
  St := G.Save;
  G.IntersectClipRect(TL - 1, 1, TextAreaW + 2, Height - 2);
  if Focused and HasSel then
  begin
    A := Math.Min(FCaret, FAnchor);
    B := Math.Max(FCaret, FAnchor);
    X1 := TL + CaretPx(A) - FScrollX;
    X2 := TL + CaretPx(B) - FScrollX;
    G.FillRect(X1, S(6), X2 - X1, Height - S(12), clTextSelection);
  end;
  Fg := clText;
  if not Enabled then Fg := clTextFaint;
  if FText = '' then
  begin
    if not (Focused and not FSearch) then
      G.Text(FPlaceholder, TL, 0, TextAreaW, Height, F, clTextFaint, 0, 1);
  end
  else
    G.TextW(FText, TL - FScrollX, 0, 100000, Height, F, Fg, 0, 1, tfNoEllipsis);
  if Focused and CaretOn and not FReadOnly then
  begin
    CX := Round(TL + CaretPx(FCaret) - FScrollX);
    G.FillRect(CX, S(8), SF(1.2), Height - S(16), clText);
  end;
  G.Restore(St);
  if FSpin then
  begin
    if FSpinHot = 0 then
      G.FillRound(SpinLeft + S(2), S(3), Width - SpinLeft - S(5), Height / 2 - S(3), S(4), clHover)
    else if FSpinHot = 1 then
      G.FillRound(SpinLeft + S(2), Height / 2, Width - SpinLeft - S(5), Height / 2 - S(3), S(4), clHover);
    G.FillRect(SpinLeft, S(6), 1, Height - S(12), clBorder);
    if FSpinHot = 0 then DrawIcon(G, icChevronUp, Width - S(13), Height / 2 - S(5), S(12), clText)
    else DrawIcon(G, icChevronUp, Width - S(13), Height / 2 - S(5), S(12), clTextDim);
    if FSpinHot = 1 then DrawIcon(G, icChevronDown, Width - S(13), Height / 2 + S(5), S(12), clText)
    else DrawIcon(G, icChevronDown, Width - S(13), Height / 2 + S(5), S(12), clTextDim);
  end;
  if FSearch and (FText <> '') then
    DrawIcon(G, icClose, Width - S(16), Height / 2, S(12), clTextDim);
end;

procedure TAuEdit.KeyDown(var Key: Word; Shift: TShiftState);
var
  Shf: Boolean;
  A, B: Integer;
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;
  Shf := ssShift in Shift;
  case Key of
    VK_LEFT:
      begin
        if (not Shf) and HasSel then FCaret := Math.Min(FCaret, FAnchor)
        else if FCaret > 0 then Dec(FCaret);
        if not Shf then FAnchor := FCaret;
      end;
    VK_RIGHT:
      begin
        if (not Shf) and HasSel then FCaret := Math.Max(FCaret, FAnchor)
        else if FCaret < Length(FText) then Inc(FCaret);
        if not Shf then FAnchor := FCaret;
      end;
    VK_HOME: begin FCaret := 0; if not Shf then FAnchor := FCaret; end;
    VK_END: begin FCaret := Length(FText); if not Shf then FAnchor := FCaret; end;
    VK_BACK:
      if not FReadOnly then
      begin
        if HasSel then DeleteSel
        else if FCaret > 0 then
        begin
          Delete(FText, FCaret, 1);
          Dec(FCaret);
          FAnchor := FCaret;
        end;
        DoChanged;
      end;
    VK_DELETE:
      if not FReadOnly then
      begin
        if HasSel then DeleteSel
        else if FCaret < Length(FText) then Delete(FText, FCaret + 1, 1);
        DoChanged;
      end;
    VK_ESCAPE:
      if FSearch and (FText <> '') then
      begin
        FText := '';
        FCaret := 0;
        FAnchor := 0;
        DoChanged;
      end
      else
        Exit;
    VK_UP: if FSpin then begin if Shf then StepValue(10) else StepValue(1); end else Exit;
    VK_DOWN: if FSpin then begin if Shf then StepValue(-10) else StepValue(-1); end else Exit;
    VK_RETURN: begin if Assigned(FOnEnterKey) then FOnEnterKey(Self) else Exit; end;
  else
    if ssCtrl in Shift then
    begin
      case Key of
        Ord('A'): SelectAll;
        Ord('C'), Ord('X'):
          if HasSel then
          begin
            A := Math.Min(FCaret, FAnchor);
            B := Math.Max(FCaret, FAnchor);
            Clipboard.AsText := UTF8Encode(Copy(FText, A + 1, B - A));
            if (Key = Ord('X')) and not FReadOnly then
            begin
              DeleteSel;
              DoChanged;
            end;
          end;
        Ord('V'): if not FReadOnly then InsertText(UTF8Decode(Clipboard.AsText));
      else
        Exit;
      end;
    end
    else
      Exit;
  end;
  Key := 0;
  CaretOn := True;
  EnsureCaretVisible;
  Invalidate;
end;

procedure TAuEdit.UTF8KeyPress(var UTF8Key: TUTF8Char);
var
  U: UnicodeString;
begin
  inherited UTF8KeyPress(UTF8Key);
  if UTF8Key = '' then Exit;
  U := UTF8Decode(UTF8Key);
  UTF8Key := '';
  if (U = '') or (U[1] < ' ') then Exit;
  if FNumeric and not ((U[1] >= '0') and (U[1] <= '9') or (U[1] = '-')) then Exit;
  InsertText(U);
end;

procedure TAuEdit.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if FSpin and (X >= SpinLeft) then
  begin
    if Y < Height div 2 then StepValue(1) else StepValue(-1);
    Exit;
  end;
  if FSearch and (FText <> '') and (X >= ClearRect.Left) then
  begin
    FText := '';
    FCaret := 0;
    FAnchor := 0;
    DoChanged;
    Exit;
  end;
  FCaret := PosFromX(X);
  if not (ssShift in Shift) then FAnchor := FCaret;
  FMouseSel := True;
  CaretOn := True;
  Invalidate;
end;

procedure TAuEdit.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Hot: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FMouseSel then
  begin
    FCaret := PosFromX(X);
    EnsureCaretVisible;
    Invalidate;
  end;
  Hot := -1;
  if FSpin and (X >= SpinLeft) and not FMouseSel then
  begin
    if Y < Height div 2 then Hot := 0 else Hot := 1;
  end;
  if Hot <> FSpinHot then
  begin
    FSpinHot := Hot;
    Invalidate;
  end;
  { arrow over the spin buttons and the clear button, I-beam over the text }
  if Hot >= 0 then Cursor := crArrow
  else if FSearch and (FText <> '') and (X >= ClearRect.Left) then Cursor := crHandPoint
  else Cursor := crIBeam;
end;

procedure TAuEdit.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FMouseSel := False;
end;

procedure TAuEdit.DblClick;
begin
  inherited DblClick;
  SelectAll;
end;

procedure TAuEdit.DoEnter;
begin
  inherited DoEnter;
  EnsureCaretTimer;
  FocusedEdit := Self;
  CaretOn := True;
  CaretTimer.Enabled := False;
  CaretTimer.Enabled := True;
  if KeyboardCues then SelectAll;
end;

procedure TAuEdit.DoExit;
begin
  inherited DoExit;
  if FocusedEdit = Self then FocusedEdit := nil;
  FAnchor := FCaret;
  Invalidate;
end;

function TAuEdit.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := False;
  if FSpin and Focused then
  begin
    StepValue(Sign(WheelDelta));
    Result := True;
  end;
end;

{ ---- TAuMemo ---- }

constructor TAuMemo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := S(96);
  FWantX := -1;
  FTextSize := 13;
end;

procedure TAuMemo.SetTextSize(V: Single);
begin
  if V < 6 then V := 6;
  if V = FTextSize then Exit;
  FTextSize := V;
  FLayoutValid := False;
  Invalidate;
end;

procedure TAuMemo.SetPlain(V: Boolean);
begin
  if V = FPlain then Exit;
  FPlain := V;
  Invalidate;
end;

function TAuMemo.MemoFont: TGfxFont;
begin
  Result := UIFont(FTextSize);
end;

function TAuMemo.GetMemoText: string;
begin
  Result := StringReplace(UTF8Encode(FText), #10, LineEnding, [rfReplaceAll]);
end;

procedure TAuMemo.SetMemoText(const V: string);
var
  U: UnicodeString;
begin
  U := UTF8Decode(StringReplace(StringReplace(V, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]));
  FText := U;
  FCaret := 0;
  FAnchor := 0;
  FScrollY := 0;
  FLayoutValid := False;
  Invalidate;
end;

function TAuMemo.LineH: Integer;
begin
  Result := Round(S(19) * FontScale * FTextSize / 13);
end;

function TAuMemo.PadX: Integer;
begin
  if FPlain then Result := S(2) else Result := S(10);
end;

function TAuMemo.PadY: Integer;
begin
  if FPlain then Result := S(2) else Result := S(7);
end;

{ the visual lines: each paragraph broken at the last space that fits (a word
  longer than the line is broken where it must) }
procedure TAuMemo.Layout;
var
  W, P, ParEnd, LineStart, LastSpace, I, N: Integer;
  F: TGfxFont;

  procedure AddLine(AStart, ALen: Integer);
  begin
    if N >= Length(FLines) then SetLength(FLines, N * 2 + 8);
    FLines[N].Start := AStart;
    FLines[N].Len := ALen;
    Inc(N);
  end;

begin
  W := Width - 2 * PadX - S(8);
  if FLayoutValid and (W = FLayoutW) then Exit;
  FLayoutW := W;
  FLayoutValid := True;
  F := MemoFont;
  N := 0;
  SetLength(FLines, 8);
  P := 0;
  repeat
    ParEnd := P;
    while (ParEnd < Length(FText)) and (FText[ParEnd + 1] <> #10) do Inc(ParEnd);
    LineStart := P;
    if ParEnd = P then AddLine(P, 0)
    else
      while LineStart < ParEnd do
      begin
        if TextWidthW(Copy(FText, LineStart + 1, ParEnd - LineStart), F) <= W then
        begin
          AddLine(LineStart, ParEnd - LineStart);
          LineStart := ParEnd;
          Break;
        end;
        { the longest part that fits, ending after a space if there is one }
        LastSpace := -1;
        I := LineStart + 1;
        while (I < ParEnd) and (TextWidthW(Copy(FText, LineStart + 1, I - LineStart + 1), F) <= W) do
        begin
          if FText[I + 1] = ' ' then LastSpace := I + 1;
          Inc(I);
        end;
        if LastSpace > LineStart then I := LastSpace;
        if I <= LineStart then I := LineStart + 1;
        AddLine(LineStart, I - LineStart);
        LineStart := I;
      end;
    P := ParEnd + 1;          // after the line break
  until ParEnd >= Length(FText);
  SetLength(FLines, N);
end;

function TAuMemo.ContentH: Integer;
begin
  Layout;
  Result := Length(FLines) * LineH + 2 * PadY;
end;

function TAuMemo.LineOf(APos: Integer): Integer;
var
  I: Integer;
begin
  Layout;
  Result := 0;
  for I := 0 to High(FLines) do
    if FLines[I].Start <= APos then Result := I else Break;
  { the end of a wrapped line belongs to the next line, except at a line break }
  if (Result < High(FLines)) and (APos >= FLines[Result + 1].Start) then Inc(Result);
end;

function TAuMemo.XOf(APos: Integer): Single;
var
  L: Integer;
begin
  L := LineOf(APos);
  Result := TextWidthW(Copy(FText, FLines[L].Start + 1, APos - FLines[L].Start), MemoFont);
end;

function TAuMemo.PosInLine(L: Integer; X: Single): Integer;
var
  I: Integer;
  Px, Prev: Single;
  F: TGfxFont;
begin
  F := MemoFont;
  Prev := 0;
  for I := 1 to FLines[L].Len do
  begin
    Px := TextWidthW(Copy(FText, FLines[L].Start + 1, I), F);
    if X < (Prev + Px) / 2 then Exit(FLines[L].Start + I - 1);
    Prev := Px;
  end;
  Result := FLines[L].Start + FLines[L].Len;
  { a wrapped line ends before the space that broke it: stay on this line }
  if (L < High(FLines)) and (Result = FLines[L + 1].Start) and (Result > FLines[L].Start) then Dec(Result);
end;

function TAuMemo.PosAt(X, Y: Integer): Integer;
var
  L: Integer;
begin
  Layout;
  L := (Y - PadY + FScrollY) div LineH;
  if L < 0 then L := 0;
  if L > High(FLines) then L := High(FLines);
  Result := PosInLine(L, X - PadX);
end;

procedure TAuMemo.ScrollToCaret;
var
  L, LTop, H: Integer;
begin
  Layout;
  L := LineOf(FCaret);
  LTop := L * LineH;
  H := Height - 2 * PadY;
  if LTop < FScrollY then FScrollY := LTop
  else if LTop + LineH > FScrollY + H then FScrollY := LTop + LineH - H;
  FScrollY := Math.Max(0, Math.Min(FScrollY, ContentH - Height));
end;

procedure TAuMemo.MemoChanged;
begin
  FLayoutValid := False;
  FWantX := -1;
  ScrollToCaret;
  CaretOn := True;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TAuMemo.InsertMemo(const T: UnicodeString);
var
  U: UnicodeString;
  I: Integer;
begin
  if FReadOnly then Exit;
  U := '';
  for I := 1 to Length(T) do
    if (T[I] >= ' ') or (T[I] = #10) then U := U + T[I]
    else if T[I] = #9 then U := U + ' ';
  if HasSel then DeleteSel;
  Insert(U, FText, FCaret + 1);
  Inc(FCaret, Length(U));
  FAnchor := FCaret;
  MemoChanged;
end;

procedure TAuMemo.Resize;
begin
  inherited Resize;
  FLayoutValid := False;
end;

procedure TAuMemo.ScaleCached(K: Double);
begin
  inherited ScaleCached(K);
  FLayoutValid := False;
end;

procedure TAuMemo.DoEnter;
begin
  inherited DoEnter;
  { the whole comment is not selected when tabbing in (unlike an edit) }
  FAnchor := FCaret;
end;

procedure TAuMemo.DoPaint(G: TGfx);
var
  Bd: TARGB;
  R, X1, X2, CX: Single;
  I, A, B, S0, E0, Y: Integer;
  F: TGfxFont;
  Fg: TARGB;
  Line: UnicodeString;
  St: UINT;
begin
  Layout;
  G.FillRect(0, 0, Width, Height, EffBack);
  if not FPlain then
  begin
    R := S(7);
    G.FillRound(0, 0, Width, Height, R, clInput);
    if Focused then Bd := clAccent else Bd := HoverMix(clInputLine, clInputLineHi);
    if Focused then G.StrokeRound(0, 0, Width, Height, R, FocusLineW, Bd)
    else G.StrokeRound(0, 0, Width, Height, R, 1, Bd);
  end;
  F := MemoFont;
  Fg := clText;
  if not Enabled then Fg := clTextFaint;
  St := G.Save;      // intersect, see TAuEdit.DoPaint
  G.IntersectClipRect(1, S(2), Width - 2, Height - S(4));
  A := Math.Min(FCaret, FAnchor);
  B := Math.Max(FCaret, FAnchor);
  if (FText = '') and not Focused then
    G.Text(FPlaceholder, PadX, PadY, Width - 2 * PadX, LineH, F, clTextFaint, 0, 1);
  for I := 0 to High(FLines) do
  begin
    Y := PadY + I * LineH - FScrollY;
    if Y + LineH < 0 then Continue;
    if Y > Height then Break;
    if Focused and (A <> B) then
    begin
      S0 := Math.Max(A, FLines[I].Start);
      E0 := Math.Min(B, FLines[I].Start + FLines[I].Len);
      if E0 > S0 then
      begin
        X1 := PadX + TextWidthW(Copy(FText, FLines[I].Start + 1, S0 - FLines[I].Start), F);
        X2 := PadX + TextWidthW(Copy(FText, FLines[I].Start + 1, E0 - FLines[I].Start), F);
        G.FillRect(X1, Y + S(1), X2 - X1, LineH - S(2), clTextSelection);
      end;
    end;
    Line := Copy(FText, FLines[I].Start + 1, FLines[I].Len);
    if Line <> '' then G.TextW(Line, PadX, Y, Width - PadX, LineH, F, Fg, 0, 1, tfNoEllipsis);
  end;
  if Focused and CaretOn and not FReadOnly then
  begin
    I := LineOf(FCaret);
    Y := PadY + I * LineH - FScrollY;
    CX := Round(PadX + XOf(FCaret));
    G.FillRect(CX, Y + S(2), SF(1.2), LineH - S(4), clText);
  end;
  G.Restore(St);
  { a slim scroll indicator when the text is taller than the box }
  if ContentH > Height then
  begin
    X1 := Height * Height / ContentH;
    X2 := (Height - X1) * FScrollY / Math.Max(1, ContentH - Height);
    G.FillRound(Width - S(6), X2 + S(3), S(3), X1 - S(6), SF(1.5), clThumb);
  end;
end;

procedure TAuMemo.KeyDown(var Key: Word; Shift: TShiftState);
var
  Shf: Boolean;
  L: Integer;
  X: Single;
begin
  Shf := ssShift in Shift;
  { read only: the arrows and the page keys scroll the text (no caret shown) }
  if FReadOnly and (Shift = []) and ((Key = VK_UP) or (Key = VK_DOWN) or (Key = VK_PRIOR) or (Key = VK_NEXT)) then
  begin
    Layout;
    case Key of
      VK_UP: Dec(FScrollY, LineH);
      VK_DOWN: Inc(FScrollY, LineH);
      VK_PRIOR: Dec(FScrollY, Math.Max(LineH, Height - LineH));
      VK_NEXT: Inc(FScrollY, Math.Max(LineH, Height - LineH));
    end;
    FScrollY := Math.Max(0, Math.Min(FScrollY, ContentH - Height));
    Key := 0;
    Invalidate;
    Exit;
  end;
  case Key of
    VK_RETURN:
      begin
        if Shift - [ssShift] <> [] then Exit;
        InsertMemo(#10);
        Key := 0;
        Exit;
      end;
    VK_UP, VK_DOWN, VK_PRIOR, VK_NEXT:
      begin
        Layout;
        L := LineOf(FCaret);
        if FWantX < 0 then FWantX := XOf(FCaret);
        X := FWantX;
        case Key of
          VK_UP: Dec(L);
          VK_DOWN: Inc(L);
          VK_PRIOR: Dec(L, Math.Max(1, Height div LineH - 1));
          VK_NEXT: Inc(L, Math.Max(1, Height div LineH - 1));
        end;
        if L < 0 then FCaret := 0
        else if L > High(FLines) then FCaret := Length(FText)
        else FCaret := PosInLine(L, X);
        if not Shf then FAnchor := FCaret;
        Key := 0;
        CaretOn := True;
        ScrollToCaret;
        FWantX := X;
        Invalidate;
        Exit;
      end;
    VK_HOME, VK_END:
      begin
        Layout;
        if ssCtrl in Shift then
        begin
          if Key = VK_HOME then FCaret := 0 else FCaret := Length(FText);
        end
        else
        begin
          L := LineOf(FCaret);
          if Key = VK_HOME then FCaret := FLines[L].Start
          else FCaret := PosInLine(L, 1E9);
        end;
        if not Shf then FAnchor := FCaret;
        Key := 0;
        CaretOn := True;
        FWantX := -1;
        ScrollToCaret;
        Invalidate;
        Exit;
      end;
    Ord('V'):
      if (Shift = [ssCtrl]) and not FReadOnly then
      begin
        InsertMemo(UTF8Decode(StringReplace(Clipboard.AsText, #13#10, #10, [rfReplaceAll])));
        Key := 0;
        Exit;
      end;
  end;
  inherited KeyDown(Key, Shift);
  if Key = 0 then
  begin
    { Left / Right / Back / Delete / cut changed the caret or the text }
    FLayoutValid := False;
    FWantX := -1;
    ScrollToCaret;
  end;
end;

procedure TAuMemo.UTF8KeyPress(var UTF8Key: TUTF8Char);
var
  U: UnicodeString;
begin
  if UTF8Key = '' then Exit;
  U := UTF8Decode(UTF8Key);
  UTF8Key := '';
  if (U = '') or (U[1] < ' ') then Exit;
  InsertMemo(U);
end;

procedure TAuMemo.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if CanFocus and not Focused then SetFocus;
  if Button <> mbLeft then Exit;
  FCaret := PosAt(X, Y);
  if not (ssShift in Shift) then FAnchor := FCaret;
  FMouseSel := True;
  FWantX := -1;
  CaretOn := True;
  Invalidate;
end;

procedure TAuMemo.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  if FMouseSel then
  begin
    FCaret := PosAt(X, Y);
    ScrollToCaret;
    Invalidate;
  end;
  Cursor := crIBeam;
end;

procedure TAuMemo.DblClick;
var
  A, B: Integer;
begin
  { the word under the caret }
  A := FCaret;
  B := FCaret;
  while (A > 0) and (FText[A] > ' ') do Dec(A);
  while (B < Length(FText)) and (FText[B + 1] > ' ') do Inc(B);
  FAnchor := A;
  FCaret := B;
  Invalidate;
end;

function TAuMemo.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := ContentH > Height;
  if not Result then Exit;
  FScrollY := FScrollY - Sign(WheelDelta) * LineH * 2;
  FScrollY := Math.Max(0, Math.Min(FScrollY, ContentH - Height));
  Invalidate;
end;

function TAuMemo.PanBy(DX, DY: Integer): Boolean;
begin
  if ContentH <= Height then Exit(inherited PanBy(DX, DY));
  if DY <> 0 then
  begin
    FScrollY := Math.Max(0, Math.Min(FScrollY - DY, ContentH - Height));
    Invalidate;
  end;
  Result := True;
end;

function TAuMemo.ScrollOffset: Integer;
begin
  Result := FScrollY;
end;

{ ---- TAuPopup ---- }

constructor TAuPopup.CreatePopup(AParentPopup: TAuPopup);
var
  D: Integer;
begin
  D := CurDpi;                    // the DPI of the window that opens it
  inherited CreateNew(nil, 0);
  Scaled := False;
  PixelsPerInch := D;
  CurDpi := D;
  BorderStyle := bsNone;
  ShowInTaskBar := stNever;
  FormStyle := fsStayOnTop;
  Color := ToTColor(clCard);
  KeyPreview := True;
  FParentPopup := AParentPopup;
  if AParentPopup <> nil then AParentPopup.FChild := Self;
  OnDeactivate := @DoDeact;
  OnClose := @PopupClose;
end;

destructor TAuPopup.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FFade);
  if (FParentPopup <> nil) and (FParentPopup.FChild = Self) then FParentPopup.FChild := nil;
  if FChild <> nil then FChild.FParentPopup := nil;
  inherited Destroy;
end;

{ ---- TAuCrossFade ---- }

procedure RenderChildrenOf(AParent: TWinControl; G: TGfx);
var
  I: Integer;
  C: TControl;
  St: UINT;
begin
  for I := 0 to AParent.ControlCount - 1 do
  begin
    C := AParent.Controls[I];
    if not (C.Visible and (C is TAuControl)) or (C is TAuCrossFade) then Continue;
    St := G.Save;
    G.Translate(C.Left, C.Top);
    G.IntersectClipRect(0, 0, C.Width, C.Height);
    TAuControl(C).RenderTo(G);
    G.Restore(St);
  end;
end;

function SnapshotControls(AParent: TWinControl): TGfxBitmap;
var
  G: TGfx;
  W, H: Integer;
begin
  Result := nil;
  if (AParent = nil) or not AnimActive or not AParent.HandleAllocated or
     not IsWindowVisible(AParent.Handle) then Exit;
  W := AParent.ClientWidth;
  H := AParent.ClientHeight;
  if (W <= 0) or (H <= 0) then Exit;
  G := TGfx.CreateBitmap(W, H, True);
  try
    if AParent is TAuControl then TAuControl(AParent).RenderTo(G)
    else
    begin
      G.FillRect(0, 0, W, H, clBg);
      RenderChildrenOf(AParent, G);
    end;
    Result := G.ToBitmap;
  finally
    G.Free;
  end;
end;

procedure CrossFadeFrom(AParent: TWinControl; ABefore: TGfxBitmap; ASlidePx: Integer; ABeside: Boolean);
var
  After: TGfxBitmap;
  X: TAuCrossFade;
  I: Integer;
  Host: TWinControl;
begin
  if ABefore = nil then Exit;
  if ABeside then Host := AParent.Parent else Host := AParent;
  if Host = nil then
  begin
    ABefore.Free;
    Exit;
  end;
  { one that is still running there ends here }
  for I := Host.ControlCount - 1 downto 0 do
    if Host.Controls[I] is TAuCrossFade then Host.Controls[I].Free;
  After := SnapshotControls(AParent);
  if (After = nil) or (After.Width <> ABefore.Width) or (After.Height <> ABefore.Height) then
  begin
    ABefore.Free;
    After.Free;
    Exit;
  end;
  X := TAuCrossFade.Create(Host);
  X.FBefore := ABefore;
  X.FAfter := After;
  X.FSlide := ASlidePx;
  if ABeside then X.SetBounds(AParent.Left, AParent.Top, After.Width, After.Height)
  else X.SetBounds(0, 0, After.Width, After.Height);
  X.Parent := Host;
  X.BringToFront;
  AnimTo(X.FA, 1, ANIM_SLOW, X, @X.Step);
end;

procedure EntranceFade(AShown: TWinControl; ASlidePx: Integer);
var
  After: TGfxBitmap;
  X: TAuCrossFade;
  I: Integer;
  Host: TWinControl;
begin
  Host := AShown.Parent;
  if Host = nil then Exit;
  for I := Host.ControlCount - 1 downto 0 do
    if Host.Controls[I] is TAuCrossFade then Host.Controls[I].Free;
  After := SnapshotControls(AShown);
  if After = nil then Exit;
  X := TAuCrossFade.Create(Host);
  X.FAfter := After;
  if AShown is TAuControl then X.FBackColor := TAuControl(AShown).EffBack else X.FBackColor := clBg;
  X.FSlide := ASlidePx;
  X.SetBounds(AShown.Left, AShown.Top, After.Width, After.Height);
  X.Parent := Host;
  X.BringToFront;
  AnimTo(X.FA, 1, ANIM_SLOW, X, @X.Step);
end;

destructor TAuCrossFade.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FBefore);
  FreeAndNil(FAfter);
  inherited Destroy;
end;

procedure TAuCrossFade.Step(Sender: TObject; ADone: Boolean);
begin
  if ADone then
  begin
    Visible := False;
    Application.QueueAsyncCall(@FreeSelf, 0);
  end
  else
    Invalidate;
end;

procedure TAuCrossFade.FreeSelf(Data: PtrInt);
begin
  Free;
end;

procedure TAuCrossFade.WMNCHitTest(var Msg: TLMessage);
begin
  Msg.Result := HTTRANSPARENT;
end;

procedure TAuCrossFade.DoPaint(G: TGfx);
var
  T: Single;
begin
  T := FA.Value;
  if FBefore <> nil then G.DrawBitmap(FBefore, 0, 0, Width, Height)
  else G.FillRect(0, 0, Width, Height, FBackColor);
  if FAfter <> nil then G.DrawBitmap(FAfter, 0, FSlide * (1 - T), Width, Height, T);
end;

{ ---- TAuWindowFade ---- }

constructor TAuWindowFade.Create(AForm: TCustomForm);
begin
  inherited Create;
  FForm := AForm;
end;

destructor TAuWindowFade.Destroy;
begin
  AnimForget(Self);
  inherited Destroy;
end;

procedure TAuWindowFade.Start(ASlidePx: Integer; AMs: Integer);
var
  H: HWND;
  R: TRect;
begin
  if not FForm.HandleAllocated then Exit;
  H := FForm.Handle;
  if not AnimActive then
  begin
    PaintAndUncloak(H);
    Exit;
  end;
  { invisible at first, then painted and shown (still invisible), then the
    opacity goes up }
  SetWindowLongPtrW(H, GWL_EXSTYLE, GetWindowLongPtrW(H, GWL_EXSTYLE) or WS_EX_LAYERED);
  SetLayeredWindowAttributes(H, 0, 0, LWA_ALPHA);
  FSlide := ASlidePx;
  if IsZoomed(H) then FSlide := 0;
  if FSlide <> 0 then
  begin
    Windows.GetWindowRect(H, R);
    FLeft0 := R.Left;
    FTop0 := R.Top;
    SetWindowPos(H, 0, FLeft0, FTop0 - FSlide, 0, 0, SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
  end;
  PaintAndUncloak(H);
  AnimSet(FA, 0);
  AnimTo(FA, 1, AMs, nil, @Step);
end;

procedure TAuWindowFade.Step(Sender: TObject; ADone: Boolean);
var
  H: HWND;
begin
  if not FForm.HandleAllocated then Exit;
  H := FForm.Handle;
  SetLayeredWindowAttributes(H, 0, EnsureRange(Round(FA.Value * 255), 0, 255), LWA_ALPHA);
  if FSlide <> 0 then
    SetWindowPos(H, 0, FLeft0, FTop0 - Round(FSlide * (1 - FA.Value)), 0, 0,
      SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
end;

procedure TAuPopup.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW;
  Params.WindowClass.style := Params.WindowClass.style or CS_DROPSHADOW;
end;

procedure TAuPopup.CreateWnd;
begin
  inherited CreateWnd;
  ApplyPopupFrame(Handle);
end;

procedure TAuPopup.WndProc(var Message: TLMessage);
begin
  { only a created window has its final DPI - during construction the LCL
    already dispatches messages while PixelsPerInch is still the default }
  if HandleAllocated and (PixelsPerInch >= 48) then CurDpi := PixelsPerInch;
  { popups keep the DPI of their owner; the system must not rescale them }
  if Message.Msg = LM_DPICHANGED then
  begin
    Message.Result := 0;
    Exit;
  end;
  { no white flash: shown cloaked, uncloaked once painted (as TAuForm) }
  if Message.Msg = AUM_UNCLOAK then
  begin
    FCloakPending := False;
    if FFade = nil then FFade := TAuWindowFade.Create(Self);
    FFade.Start(S(6));
    Message.Result := 0;
    Exit;
  end;
  if (Message.Msg = WM_SHOWWINDOW) and (Message.WParam <> 0) and (Message.LParam = 0) and
    HandleAllocated and not FCloakPending then
  begin
    SetWindowCloak(Handle, True);
    FCloakPending := True;
    PostMessage(Handle, AUM_UNCLOAK, 0, 0);
  end;
  inherited WndProc(Message);
end;

function TAuPopup.Root: TAuPopup;
begin
  Result := Self;
  while Result.FParentPopup <> nil do Result := Result.FParentPopup;
end;

procedure TAuPopup.CloseTree;
begin
  if FChild <> nil then FChild.CloseTree;
  if not FClosing then Close;
end;

procedure TAuPopup.DoDeact(Sender: TObject);
begin
  if not FClosing then Application.QueueAsyncCall(@CheckDeact, 0);
end;

procedure TAuPopup.CheckDeact(Data: PtrInt);
var
  A: TCustomForm;
begin
  if FClosing then Exit;
  A := Screen.ActiveForm;
  if (A is TAuPopup) and (TAuPopup(A).Root = Root) then Exit;
  Root.CloseTree;
end;

procedure TAuPopup.PopupClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  FClosing := True;
  CloseAction := caFree;
  if FChild <> nil then FChild.CloseTree;
  if Assigned(OnClosed) then OnClosed(Self);
  OnClosed := nil;
  if (FParentPopup <> nil) and (FParentPopup.FChild = Self) then
  begin
    FParentPopup.FChild := nil;
    if FParentPopup.Visible and not FParentPopup.FClosing then FParentPopup.SetFocus;
  end;
end;

procedure TAuPopup.ShowAt(X, Y, W, H: Integer; AboveY: Integer);
var
  WA: TRect;
begin
  WA := Screen.MonitorFromPoint(Point(X, Y)).WorkareaRect;
  if Y + H > WA.Bottom then
  begin
    if AboveY >= 0 then Y := AboveY - H else Y := WA.Bottom - H;
  end;
  if Y < WA.Top then Y := WA.Top;
  if X + W > WA.Right then X := WA.Right - W;
  if X < WA.Left then X := WA.Left;
  SetBounds(X, Y, W, H);
  Show;
end;

{ ---- TAuPopupList ---- }

constructor TAuPopupList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BackRole := crCard;
  FRowH := S(30);
  FIndex := -1;
  FMaxRows := 12;
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Visible := False;
  FScroll.OnScroll := @ScrollChanged;
end;

procedure TAuPopupList.Setup(AItems: TStrings; AIndex, AMaxRows: Integer);
begin
  FItems := AItems;
  FIndex := AIndex;
  FMaxRows := AMaxRows;
end;

function TAuPopupList.ContentHeight: Integer;
var
  N: Integer;
begin
  N := FItems.Count;
  if N > FMaxRows then N := FMaxRows;
  if N < 1 then N := 1;
  Result := N * FRowH + S(8);
end;

function TAuPopupList.ContentWidth: Integer;
var
  I: Integer;
  W: Single;
begin
  W := 0;
  for I := 0 to FItems.Count - 1 do W := Math.Max(W, TextWidth(FItems[I], UIFont(13)));
  Result := Ceil(W) + S(52);
end;

procedure TAuPopupList.Resize;
begin
  inherited Resize;
  FScroll.SetBounds(Width - S(12), S(4), S(12), Height - S(8));
  FScroll.SetParams(FItems.Count, (Height - S(8)) div FRowH);
  FScroll.Visible := FScroll.NeedScroll;
  FTop := FScroll.Position;
end;

procedure TAuPopupList.ScaleCached(K: Double);
begin
  FRowH := Math.Max(8, Round(FRowH * K));
end;

procedure TAuPopupList.ScrollChanged(Sender: TObject);
begin
  FTop := FScroll.Position;
  Invalidate;
end;

function TAuPopupList.RowAt(Y: Integer): Integer;
begin
  Result := FTop + (Y - S(4)) div FRowH;
  if (Y < S(4)) or (Result >= FItems.Count) then Result := -1;
end;

procedure TAuPopupList.EnsureVisible(I: Integer);
var
  Vis: Integer;
begin
  Vis := Math.Max(1, (Height - S(8)) div FRowH);
  if I < FTop then FScroll.Position := I
  else if I >= FTop + Vis then FScroll.Position := I - Vis + 1;
  FTop := FScroll.Position;
  Invalidate;
end;

procedure TAuPopupList.MoveIndex(D: Integer);
var
  N: Integer;
begin
  N := FIndex + D;
  if N < 0 then N := 0;
  if N >= FItems.Count then N := FItems.Count - 1;
  FIndex := N;
  EnsureVisible(N);
end;

procedure TAuPopupList.DoPaint(G: TGfx);
var
  I, Y, W: Integer;
begin
  G.FillRect(0, 0, Width, Height, clCard);
  W := Width;
  if FScroll.Visible then Dec(W, FScroll.Width);
  Y := S(4);
  I := FTop;
  while (I < FItems.Count) and (Y < Height) do
  begin
    if I = FIndex then G.FillRound(S(4), Y, W - S(8), FRowH, S(6), clHover);
    G.Text(FItems[I], S(30), Y, W - S(40), FRowH, UIFont(13), clText, 0, 1);
    Inc(Y, FRowH);
    Inc(I);
  end;
end;

procedure TAuPopupList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  R: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  R := RowAt(Y);
  if (R >= 0) and (R <> FIndex) then
  begin
    FIndex := R;
    Invalidate;
  end;
end;

procedure TAuPopupList.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  R := RowAt(Y);
  if (Button = mbLeft) and (R >= 0) and Assigned(FOnPick) then FOnPick(Self, R);
end;

function TAuPopupList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  FScroll.Position := FScroll.Position - Sign(WheelDelta) * 3;
  FTop := FScroll.Position;
  Invalidate;
  Result := True;
end;

function TAuPopupList.PanBy(DX, DY: Integer): Boolean;
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

function TAuPopupList.ScrollOffset: Integer;
begin
  Result := FTop;
end;

{ ---- TAuCombo ---- }

constructor TAuCombo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FWantKeys := True;
  TabStop := True;
  FItems := TStringList.Create;
  FItemIndex := -1;
  Width := S(200);
  Height := S(32);
end;

destructor TAuCombo.Destroy;
begin
  if FPopup <> nil then
  begin
    FPopup.OnClosed := nil;
    FPopup.Release;
  end;
  FItems.Free;
  inherited Destroy;
end;

procedure TAuCombo.SetItemIndex(V: Integer);
begin
  if V >= FItems.Count then V := FItems.Count - 1;
  if V < -1 then V := -1;
  if V = FItemIndex then Exit;
  FItemIndex := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TAuCombo.GetText: string;
begin
  if (FItemIndex >= 0) and (FItemIndex < FItems.Count) then Result := FItems[FItemIndex]
  else Result := '';
end;

procedure TAuCombo.SelectText(const AText: string);
var
  I: Integer;
begin
  I := FItems.IndexOf(AText);
  if I >= 0 then ItemIndex := I;
end;

procedure TAuCombo.DoPaint(G: TGfx);
var
  Bg, Bd, Fg: TARGB;
  Open: Boolean;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  Open := FPopup <> nil;
  Bg := clInput;
  if Open then Bg := Blend(clInput, clText, 0.04) else Bg := Blend(clInput, clText, 0.04 * HoverT);
  G.FillRound(0, 0, Width, Height, S(7), Bg);
  if Open or ShowFocus then Bd := clAccent
  else Bd := HoverMix(clInputLine, clInputLineHi);
  if Open or ShowFocus then G.StrokeRound(0, 0, Width, Height, S(7), FocusLineW, Bd)
  else G.StrokeRound(0, 0, Width, Height, S(7), 1, Bd);
  if Enabled then Fg := clText else Fg := clTextFaint;
  G.Text(GetText, S(12), 0, Width - S(40), Height, UIFont(13), Fg, 0, 1);
  if Open then DrawIcon(G, icChevronUp, Width - S(18), Height / 2, S(14), clTextDim)
  else DrawIcon(G, icChevronDown, Width - S(18), Height / 2, S(14), clTextDim);
end;

procedure TAuCombo.OpenPopup;
var
  P: TPoint;
  W, H: Integer;
begin
  if (FItems.Count = 0) or (FPopup <> nil) then Exit;
  FPopup := TAuPopup.CreatePopup(nil);
  FPopup.OnClosed := @PopupClosed;
  FPopup.OnKeyDown := @PopupKey;
  FList := TAuPopupList.Create(FPopup);
  FList.Setup(FItems, FItemIndex, 12);
  FList.OnPick := @ListPick;
  FList.Parent := FPopup;
  FList.Align := alClient;
  W := Math.Max(Width, FList.ContentWidth);
  H := FList.ContentHeight;
  P := ClientToScreen(Point(0, Height + S(4)));
  FPopup.ShowAt(P.X, P.Y, W, H, P.Y - Height - S(8));
  if FItemIndex >= 0 then FList.EnsureVisible(FItemIndex);
  Invalidate;
end;

procedure TAuCombo.ListPick(Sender: TObject; Index: Integer);
begin
  if FPopup <> nil then FPopup.Close;
  ItemIndex := Index;
end;

procedure TAuCombo.PopupKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_ESCAPE, VK_TAB: FPopup.Close;
    VK_UP: FList.MoveIndex(-1);
    VK_DOWN: FList.MoveIndex(1);
    VK_PRIOR: FList.MoveIndex(-10);
    VK_NEXT: FList.MoveIndex(10);
    VK_HOME: FList.MoveIndex(-MaxInt div 2);
    VK_END: FList.MoveIndex(MaxInt div 2);
    VK_RETURN, VK_SPACE: if FList.ItemIndex >= 0 then ListPick(nil, FList.ItemIndex) else FPopup.Close;
  else
    Exit;
  end;
  Key := 0;
end;

procedure TAuCombo.PopupClosed(Sender: TObject);
begin
  FPopup := nil;
  FList := nil;
  FLastClose := GetTickCount64;
  Invalidate;
  if CanFocus then SetFocus;
end;

procedure TAuCombo.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if FPopup <> nil then FPopup.Close
  else if GetTickCount64 - FLastClose > 200 then OpenPopup;
end;

procedure TAuCombo.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_UP, VK_LEFT: if FItemIndex > 0 then ItemIndex := FItemIndex - 1;
    VK_DOWN, VK_RIGHT:
      if ssAlt in Shift then OpenPopup
      else if FItemIndex < FItems.Count - 1 then ItemIndex := FItemIndex + 1;
    VK_HOME: if FItems.Count > 0 then ItemIndex := 0;
    VK_END: ItemIndex := FItems.Count - 1;
    VK_SPACE, VK_F4, VK_RETURN: OpenPopup;
  else
    Exit;
  end;
  Key := 0;
end;

function TAuCombo.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := False;
  if not Focused then Exit;
  if WheelDelta > 0 then
  begin
    if FItemIndex > 0 then ItemIndex := FItemIndex - 1;
  end
  else if FItemIndex < FItems.Count - 1 then ItemIndex := FItemIndex + 1;
  Result := True;
end;

{ ---- TAuTabs ---- }

constructor TAuTabs.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTabs := TStringList.Create;
  FHoverTab := -1;
  Height := S(38);
  TabStop := True;
  FWantKeys := True;
end;

destructor TAuTabs.Destroy;
begin
  FTabs.Free;
  inherited Destroy;
end;

procedure TAuTabs.AddTab(const ACaption: string);
begin
  FTabs.Add(ACaption);
  Invalidate;
end;

procedure TAuTabs.SetTabIndex(V: Integer);
begin
  if V = FTabIndex then Exit;
  FTabIndex := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TAuTabs.TabWidth(I: Integer): Integer;
begin
  Result := Ceil(TextWidth(FTabs[I], UIFont(13, True))) + S(28);
end;

function TAuTabs.TabLeft(I: Integer): Integer;
var
  J: Integer;
begin
  Result := 0;
  for J := 0 to I - 1 do Inc(Result, TabWidth(J));
end;

function TAuTabs.TabAt(X: Integer): Integer;
var
  I, L: Integer;
begin
  Result := -1;
  for I := 0 to FTabs.Count - 1 do
  begin
    L := TabLeft(I);
    if (X >= L) and (X < L + TabWidth(I)) then Exit(I);
  end;
end;

procedure TAuTabs.DoPaint(G: TGfx);
var
  I, L, W: Integer;
  C: TARGB;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  G.FillRect(0, Height - 1, Width, 1, clBorder);
  for I := 0 to FTabs.Count - 1 do
  begin
    L := TabLeft(I);
    W := TabWidth(I);
    if I = FTabIndex then C := clText
    else if I = FHoverTab then C := Blend(clTextDim, clText, 0.5)
    else C := clTextDim;
    G.Text(FTabs[I], L, 0, W, Height - S(2), UIFont(13, True), C, 1, 1, tfNoEllipsis);
    if I = FTabIndex then
    begin
      G.FillRound(L + S(10), Height - S(3), W - S(20), S(3), SF(1.5), clAccent);
      if ShowFocus then G.StrokeRound(L + S(2), S(4), W - S(4), Height - S(10), S(6), SF(1.6), clAccent);
    end;
  end;
end;

procedure TAuTabs.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  T: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  T := TabAt(X);
  if T >= 0 then TabIndex := T;
end;

procedure TAuTabs.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  T: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  T := TabAt(X);
  if T <> FHoverTab then
  begin
    FHoverTab := T;
    Invalidate;
  end;
end;

procedure TAuTabs.MouseLeave;
begin
  inherited MouseLeave;
  FHoverTab := -1;
  Invalidate;
end;

procedure TAuTabs.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_LEFT: if FTabIndex > 0 then TabIndex := FTabIndex - 1;
    VK_RIGHT: if FTabIndex < FTabs.Count - 1 then TabIndex := FTabIndex + 1;
    VK_HOME: TabIndex := 0;
    VK_END: TabIndex := FTabs.Count - 1;
  else
    Exit;
  end;
  Key := 0;
end;

{ ---- TAuSegmented ---- }

constructor TAuSegmented.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FItems := TStringList.Create;
  FHoverIdx := -1;
  Height := S(32);
  Width := S(240);
  TabStop := True;
  FWantKeys := True;
end;

destructor TAuSegmented.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TAuSegmented.SetItems(const ACaptions: array of string);
var
  I: Integer;
begin
  FItems.Clear;
  for I := 0 to High(ACaptions) do FItems.Add(ACaptions[I]);
  Invalidate;
end;

procedure TAuSegmented.SetIcons(const AIcons: array of TAuIcon);
var
  I: Integer;
begin
  SetLength(FIcons, Length(AIcons));
  for I := 0 to High(AIcons) do FIcons[I] := AIcons[I];
  Invalidate;
end;

procedure TAuSegmented.SetIndex(V: Integer);
begin
  if (V < 0) or (V >= FItems.Count) or (V = FIndex) then Exit;
  FIndex := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TAuSegmented.SegW: Single;
begin
  if FItems.Count = 0 then Result := Width
  else Result := (Width - S(6)) / FItems.Count;
end;

function TAuSegmented.SegAt(X: Integer): Integer;
begin
  Result := Trunc((X - S(3)) / SegW);
  if (Result < 0) or (Result >= FItems.Count) then Result := -1;
end;

procedure TAuSegmented.DoPaint(G: TGfx);
var
  I: Integer;
  X0, W, IconW, TW: Single;
  C: TARGB;
  F: TGfxFont;
  HasIcon: Boolean;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  G.FillRound(0, 0, Width, Height, Height / 2, Blend(EffBack, clText, 0.07));
  W := SegW;
  F := UIFont(12.5, True);
  for I := 0 to FItems.Count - 1 do
  begin
    X0 := S(3) + I * W;
    if I = FIndex then
    begin
      G.FillRound(X0, S(3), W, Height - S(6), (Height - S(6)) / 2, clCard);
      if not ThemeIsDark then G.StrokeRound(X0, S(3), W, Height - S(6), (Height - S(6)) / 2, 1, clBorder);
      C := clText;
      if ShowFocus then G.StrokeRound(X0, S(3), W, Height - S(6), (Height - S(6)) / 2, SF(1.6), clAccent);
    end
    else if I = FHoverIdx then C := clText
    else C := clTextDim;
    HasIcon := (I <= High(FIcons)) and (FIcons[I] <> icNone);
    if HasIcon and (FItems[I] = '') then
      DrawIcon(G, FIcons[I], X0 + W / 2, Height / 2, S(15), C)
    else if HasIcon then
    begin
      IconW := S(15);
      TW := TextWidth(FItems[I], F);
      DrawIcon(G, FIcons[I], X0 + (W - IconW - S(6) - TW) / 2 + IconW / 2, Height / 2, IconW, C);
      G.Text(FItems[I], X0 + (W - IconW - S(6) - TW) / 2 + IconW + S(6), 0, TW + S(4), Height, F, C, 0, 1, tfNoEllipsis);
    end
    else
      G.Text(FItems[I], X0, 0, W, Height, F, C, 1, 1);
  end;
end;

procedure TAuSegmented.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  I := SegAt(X);
  if I >= 0 then ItemIndex := I;
end;

procedure TAuSegmented.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  I := SegAt(X);
  if I <> FHoverIdx then
  begin
    FHoverIdx := I;
    Invalidate;
  end;
end;

procedure TAuSegmented.MouseLeave;
begin
  inherited MouseLeave;
  FHoverIdx := -1;
  Invalidate;
end;

procedure TAuSegmented.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_LEFT, VK_UP: ItemIndex := FIndex - 1;
    VK_RIGHT, VK_DOWN: ItemIndex := FIndex + 1;
    VK_HOME: ItemIndex := 0;
    VK_END: ItemIndex := FItems.Count - 1;
  else
    Exit;
  end;
  Key := 0;
end;

{ ---- TAuScrollBox ---- }

constructor TAuScrollBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScroll := TAuScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.OnScroll := @ScrollChanged;
  FScroll.SmallStep := S(20);
  FContent := TAuPanel.Create(Self);
  FContent.Parent := Self;
end;

procedure TAuScrollBox.Relayout;
var
  W: Integer;
begin
  FScroll.SetParams(FContentHeight, ClientHeight);
  FScroll.Visible := FScroll.NeedScroll;
  FScroll.SetBounds(ClientWidth - S(12), 0, S(12), ClientHeight);
  W := ClientWidth;
  if FScroll.Visible then Dec(W, FScroll.Width);
  FContent.SetBounds(0, -FScroll.Position, W, Math.Max(FContentHeight, ClientHeight));
end;

procedure TAuScrollBox.ScrollChanged(Sender: TObject);
begin
  FContent.Top := -FScroll.Position;
end;

procedure TAuScrollBox.SetContentHeight(V: Integer);
begin
  FContentHeight := V;
  Relayout;
end;

procedure TAuScrollBox.ScrollIntoView(C: TControl; AMargin: Integer);
var
  P: TPoint;
  Target: Integer;
begin
  { only what lies in the scrolled content (not the scroll bar, which is a
    control of the box itself: ClientToParent raises for it) }
  if not FScroll.NeedScroll or (C = nil) or not FContent.IsParentOf(C) then Exit;
  P := C.ClientToParent(Point(0, 0), FContent);
  { from where the page is going, not where it is on its way there }
  Target := FScroll.GlideTarget;
  { its top wins when it is higher than the view }
  if P.Y + C.Height + S(AMargin) > Target + ClientHeight then Target := P.Y + C.Height - ClientHeight + S(AMargin);
  if P.Y - S(AMargin) < Target then Target := P.Y - S(AMargin);
  { (glides with animations on, else at once) }
  if Target <> FScroll.GlideTarget then FScroll.GlideTo(Target);
end;

procedure TAuScrollBox.Resize;
begin
  inherited Resize;
  Relayout;
end;

procedure TAuScrollBox.ScaleCached(K: Double);
begin
  FContentHeight := Round(FContentHeight * K);
end;

function TAuScrollBox.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  FScroll.WheelBy(-Sign(WheelDelta) * S(60));
  Result := True;
end;

function TAuScrollBox.PanBy(DX, DY: Integer): Boolean;
begin
  if not FScroll.Visible then Exit(inherited PanBy(DX, DY));
  if DY <> 0 then FScroll.Position := FScroll.Position - DY;
  Result := True;
end;

function TAuScrollBox.ScrollOffset: Integer;
begin
  Result := FScroll.Position;
end;

{ ---- TAuSplitter ---- }

var
  { every splitter there is (SplitterInTouchReach) }
  SplitterList: TFPList = nil;

function SplitterInTouchReach(AControl: TControl; const AScreenPt: TPoint): TAuSplitter;
var
  I, Reach: Integer;
  Sp: TAuSplitter;
  Form: TCustomForm;
  R: Windows.TRect;
begin
  Result := nil;
  if (SplitterList = nil) or (AControl = nil) or (AControl is TAuSplitter) then Exit;
  Form := GetParentForm(AControl);
  if Form = nil then Exit;
  for I := 0 to SplitterList.Count - 1 do
  begin
    Sp := TAuSplitter(SplitterList[I]);
    if (Sp.FTarget = nil) or (not Sp.HandleAllocated) or (not Sp.Enabled) or
       (GetParentForm(Sp) <> Form) or (not IsWindowVisible(Sp.Handle)) then Continue;
    if not Windows.GetWindowRect(Sp.Handle, R) then Continue;
    UseDpiOf(Sp);
    Reach := S(TOUCH_EDGE_REACH);
    { wider across its line only: along the line it ends where it is drawn }
    if Sp.IsVertical then
    begin
      Dec(R.Top, Reach);
      Inc(R.Bottom, Reach);
    end
    else
    begin
      Dec(R.Left, Reach);
      Inc(R.Right, Reach);
    end;
    if (AScreenPt.X >= R.Left) and (AScreenPt.X < R.Right) and
       (AScreenPt.Y >= R.Top) and (AScreenPt.Y < R.Bottom) then Exit(Sp);
  end;
end;

constructor TAuSplitter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  if SplitterList = nil then SplitterList := TFPList.Create;
  SplitterList.Add(Self);
  Width := S(5);
  Cursor := crHSplit;
  FMinSize := S(160);
  FMaxSize := S(600);
  FFocusOnClick := False;
end;

procedure TAuSplitter.ScaleCached(K: Double);
begin
  FMinSize := Round(FMinSize * K);
  FMaxSize := Round(FMaxSize * K);
end;

procedure TAuSplitter.SetTarget(V: TControl);
begin
  FTarget := V;
  if IsVertical then Cursor := crVSplit else Cursor := crHSplit;
end;

function TAuSplitter.IsVertical: Boolean;
begin
  Result := (FTarget <> nil) and (FTarget.Align in [alTop, alBottom]);
end;

function TAuSplitter.GesturePan: Integer;
begin
  Result := GESTURE_PAN_NONE;
end;

procedure TAuSplitter.DoPaint(G: TGfx);
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  if IsVertical then
  begin
    if FHover or FDrag then G.FillRect(0, (Height - S(2)) / 2, Width, S(2), clAccent)
    else G.FillRect(0, Height div 2, Width, 1, clBorder);
  end
  else if FHover or FDrag then G.FillRect((Width - S(2)) / 2, 0, S(2), Height, clAccent)
  else G.FillRect(Width div 2, 0, 1, Height, clBorder);
end;

{ the line of a drag: a layered popup in the accent colour, owned by the
  form, that takes no input and no focus. Moving it costs no painting below. }

const
  GHOST_CLASS = 'AulumicNSSplitGhost';

var
  GhostClassDone: Boolean = False;
  GhostColor: COLORREF = 0;

function GhostProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  R: Windows.TRect;
  Br: HBRUSH;
begin
  if Msg = WM_ERASEBKGND then
  begin
    Windows.GetClientRect(Wnd, R);
    Br := CreateSolidBrush(GhostColor);
    Windows.FillRect(HDC(WP), R, Br);
    DeleteObject(Br);
    Exit(1);
  end;
  Result := DefWindowProcW(Wnd, Msg, WP, LP);
end;

procedure TAuSplitter.ShowGhost;
var
  WC: Windows.WNDCLASSW;
  Own: HWND;
  F: TCustomForm;
begin
  HideGhost;
  if not GhostClassDone then
  begin
    FillChar(WC, SizeOf(WC), 0);
    WC.lpfnWndProc := @GhostProc;
    WC.hInstance := HInstance;
    WC.lpszClassName := GHOST_CLASS;
    Windows.RegisterClassW(@WC);
    GhostClassDone := True;
  end;
  GhostColor := RGB((clAccent shr 16) and $FF, (clAccent shr 8) and $FF, clAccent and $FF);
  Own := 0;
  F := GetParentForm(Self);
  if (F <> nil) and F.HandleAllocated then Own := F.Handle;
  FGhost := CreateWindowExW(WS_EX_LAYERED or WS_EX_TRANSPARENT or WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE,
    GHOST_CLASS, nil, WS_POPUP, 0, 0, 1, 1, Own, 0, HInstance, nil);
  if FGhost = 0 then Exit;
  SetLayeredWindowAttributes(FGhost, 0, 220, LWA_ALPHA);
  MoveGhost;
end;

{ the line where the splitter will be with the target at FNewW }
procedure TAuSplitter.MoveGhost;
var
  P: TPoint;
  D, T: Integer;
begin
  if FGhost = 0 then Exit;
  D := FNewW - FStartW;
  if FTarget.Align in [alRight, alBottom] then D := -D;
  P := ClientToScreen(Point(0, 0));
  T := S(2);
  if IsVertical then
    SetWindowPos(FGhost, HWND_TOP, P.X, P.Y + D + (Height - T) div 2, Width, T,
      SWP_NOACTIVATE or SWP_SHOWWINDOW)
  else
    SetWindowPos(FGhost, HWND_TOP, P.X + D + (Width - T) div 2, P.Y, T, Height,
      SWP_NOACTIVATE or SWP_SHOWWINDOW);
end;

procedure TAuSplitter.HideGhost;
begin
  if FGhost <> 0 then
  begin
    DestroyWindow(FGhost);
    FGhost := 0;
  end;
end;

destructor TAuSplitter.Destroy;
begin
  if SplitterList <> nil then SplitterList.Remove(Self);
  Application.RemoveAsyncCalls(Self);
  HideGhost;
  inherited Destroy;
end;

procedure TAuSplitter.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or (FTarget = nil) then Exit;
  FTouchFrom := 0;
  BeginDragAt(ClientToScreen(Point(X, Y)));
end;

procedure TAuSplitter.TakeTouch(AFrom: HWND; AWP: WPARAM; ALP: LPARAM; const AScreenPt: TPoint);
begin
  if (FTarget = nil) or (not HandleAllocated) or FDrag then Exit;
  FTouchFrom := AFrom;
  FTouchWP := AWP;
  FTouchLP := ALP;
  FTouchMoved := False;
  { the moves and the release of this touch come here }
  Windows.SetCapture(Handle);
  BeginDragAt(AScreenPt);
  Invalidate;
end;

procedure TAuSplitter.BeginDragAt(const AScreenPt: TPoint);
begin
  FDrag := True;
  if IsVertical then
  begin
    FStartX := AScreenPt.Y;
    FStartW := FTarget.Height;
  end
  else
  begin
    FStartX := AScreenPt.X;
    FStartW := FTarget.Width;
  end;
  FNewW := FStartW;
  { with the graphics card the panes repaint in a few milliseconds: they
    follow the pointer. Drawn by the processor a repaint of both panes per
    mouse move lags behind the hand, so there only a line moves. }
  FLive := GpuPaintAllowed;
  if not FLive then ShowGhost;
end;

{ the target at this size, and the panes painted at once }
procedure TAuSplitter.ApplySize(ASize: Integer);
var
  Resized: Boolean;
begin
  if FTarget = nil then Exit;
  if IsVertical then
  begin
    Resized := FTarget.Height <> ASize;
    if Resized then FTarget.Height := ASize;
  end
  else
  begin
    Resized := FTarget.Width <> ASize;
    if Resized then FTarget.Width := ASize;
  end;
  { (not when Windows finds the time) }
  if Resized and (Parent <> nil) and Parent.HandleAllocated then
    RedrawWindow(Parent.Handle, nil, 0, RDW_UPDATENOW or RDW_ALLCHILDREN);
end;

procedure TAuSplitter.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  D, W: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDrag then Exit;
  { the button went up somewhere we did not see it: the drag is over }
  if not (ssLeft in Shift) then
  begin
    EndDrag(False);
    Exit;
  end;
  if IsVertical then D := ClientToScreen(Point(X, Y)).Y - FStartX
  else D := ClientToScreen(Point(X, Y)).X - FStartX;
  if Abs(D) > S(4) then FTouchMoved := True;
  if FTarget.Align in [alRight, alBottom] then D := -D;
  W := FStartW + D;
  if W < FMinSize then W := FMinSize;
  if W > FMaxSize then W := FMaxSize;
  if W = FNewW then Exit;
  FNewW := W;
  { the panes follow, or only the line moves and they keep their size until
    the end of the drag }
  if FLive then ApplySize(W) else MoveGhost;
end;

{ the end of a drag: the line goes; AApply: the target takes the new size }
procedure TAuSplitter.EndDrag(AApply: Boolean);
begin
  if not FDrag then Exit;
  FDrag := False;
  HideGhost;
  Invalidate;
  if not AApply then
  begin
    { a live drag that was cancelled: back to the size it began with }
    if FLive then ApplySize(FStartW);
    Exit;
  end;
  ApplySize(FNewW);
  if Assigned(FOnMoved) then FOnMoved(Self);
end;

procedure TAuSplitter.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  From: HWND;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  From := FTouchFrom;
  FTouchFrom := 0;
  if From = 0 then
  begin
    EndDrag(True);
    Exit;
  end;
  { a drag taken over from a touch }
  if HandleAllocated and (Windows.GetCapture = Handle) then Windows.ReleaseCapture;
  if FTouchMoved then EndDrag(True)
  else
  begin
    { the finger did not move: a tap on the control it touched. The press
      goes there now (posted messages are not from a touch, so they are not
      taken over again). }
    EndDrag(False);
    if IsWindow(From) then
    begin
      PostMessageW(From, WM_LBUTTONDOWN, FTouchWP, FTouchLP);
      PostMessageW(From, WM_LBUTTONUP, FTouchWP and not WPARAM(MK_LBUTTON), FTouchLP);
    end;
  end;
end;

{ the capture went to another window in the middle of a drag (Alt+Tab, a
  dialog): nothing is resized, the line must not stay }
procedure TAuSplitter.LMCaptureChanged(var Msg: TLMessage);
begin
  inherited;
  { At a normal end the capture goes first and MouseUp comes right after it:
    look again once the messages in work are through. A drag that is still
    open then has lost its mouse. }
  if FDrag then Application.QueueAsyncCall(@CaptureLost, 0);
end;

procedure TAuSplitter.CaptureLost(Data: PtrInt);
begin
  if FDrag and HandleAllocated and (Windows.GetCapture <> Handle) then
  begin
    FTouchFrom := 0;
    EndDrag(False);
  end;
end;
{ ---- TAuCover ---- }

constructor TAuCover.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRadius := 8;
  Width := S(56);
  Height := S(56);
end;

destructor TAuCover.Destroy;
begin
  if FOwnsBitmap and (FBitmap <> nil) then DisposeBitmap(FBitmap);
  inherited Destroy;
end;

procedure TAuCover.SetBitmap(B: TGfxBitmap; AOwns: Boolean);
begin
  if FOwnsBitmap and (FBitmap <> nil) and (FBitmap <> B) then DisposeBitmap(FBitmap);
  FBitmap := B;
  FOwnsBitmap := AOwns;
  Invalidate;
end;

procedure DrawPlaceholderArt(G: TGfx; X, Y, W, H, R: Single; const Key: string);
var
  C1, C2: TARGB;
begin
  C1 := HashColor(Key);
  C2 := Blend(C1, HashColor(Key + '#'), 0.5);
  if ThemeIsDark then C2 := Blend(C2, $FF000000, 0.35) else C2 := Blend(C2, $FFFFFFFF, 0.2);
  G.FillRoundGrad(X, Y, W, H, R, C1, C2, True);
  DrawIcon(G, icNote, X + W / 2, Y + H / 2, Math.Min(W, H) * 0.34, WithAlpha($FFFFFF, $90));
end;

procedure TAuCover.DoPaint(G: TGfx);
var
  R, Pad, E: Single;
  I: Integer;
  A: Byte;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  R := S(FRadius);
  Pad := 0;
  if FShadow then
  begin
    { soft shadow: stacked, slightly larger translucent layers, offset down }
    Pad := S(14);
    if ThemeIsDark then A := 14 else A := 6;
    for I := 6 downto 1 do
    begin
      E := I * Pad / 6;
      G.FillRound(Pad - E, Pad / 2 + Pad * 0.35 - E, Width - 2 * Pad + 2 * E, Height - 2 * Pad + 2 * E,
        R + E, WithAlpha($000000, A));
    end;
  end;
  if FBitmap <> nil then G.DrawBitmapCover(FBitmap, Pad, Pad / 2, Width - 2 * Pad, Height - 2 * Pad, R)
  else DrawPlaceholderArt(G, Pad, Pad / 2, Width - 2 * Pad, Height - 2 * Pad, R, FKey);
end;

{ ---- TAuSwatches ---- }

constructor TAuSwatches.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := S(36);
  Width := S(AccentCount * 40);
  FHoverIdx := -1;
  TabStop := True;
  FWantKeys := True;
end;

procedure TAuSwatches.SetIndex(V: Integer);
begin
  if (V < 0) or (V >= AccentCount) or (V = FIndex) then Exit;
  FIndex := V;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TAuSwatches.ItemAt(X: Integer): Integer;
begin
  Result := X div S(40);
  if (Result < 0) or (Result >= AccentCount) then Result := -1;
end;

procedure TAuSwatches.DoPaint(G: TGfx);
var
  I: Integer;
  CX, CY: Single;
begin
  G.FillRect(0, 0, Width, Height, EffBack);
  CY := Height / 2;
  for I := 0 to AccentCount - 1 do
  begin
    CX := I * S(40) + S(18);
    if I = FIndex then
    begin
      G.StrokeCircle(CX, CY, S(15), SF(2), AccentSample(I));
      if ShowFocus then G.StrokeCircle(CX, CY, SF(17.5), SF(1.2), clText);
    end
    else if I = FHoverIdx then G.StrokeCircle(CX, CY, S(15), SF(1.5), clBorderHi);
    G.FillCircle(CX, CY, S(11), AccentSample(I));
    if I = FIndex then DrawIcon(G, icCheck, CX, CY, S(12), $FFFFFFFF);
  end;
end;

procedure TAuSwatches.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  I := ItemAt(X);
  if I >= 0 then ItemIndex := I;
end;

procedure TAuSwatches.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  I := ItemAt(X);
  if I <> FHoverIdx then
  begin
    FHoverIdx := I;
    Invalidate;
  end;
end;

procedure TAuSwatches.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_LEFT, VK_UP: ItemIndex := FIndex - 1;
    VK_RIGHT, VK_DOWN: ItemIndex := FIndex + 1;
  else
    Exit;
  end;
  Key := 0;
end;

{ ---- TAuHintWindow ---- }

constructor TAuHintWindow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := ToTColor(clCard);
end;

procedure TAuHintWindow.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.WindowClass.style := Params.WindowClass.style or CS_DROPSHADOW;
end;

function TAuHintWindow.CalcHintRect(MaxWidth: Integer; const AHint: string; AData: Pointer): TRect;
var
  W, H: Single;
  F: TGfxFont;
begin
  F := UIFont(12);
  W := TextWidth(AHint, F);
  if W > S(360) then
  begin
    W := S(360);
    H := TextHeightWrapped(AHint, F, W);
  end
  else
    H := F.LineHeight;
  Result := Rect(0, 0, Ceil(W) + S(20), Ceil(H) + S(12));
end;

procedure TAuHintWindow.EraseBackground(DC: HDC);
begin
end;

procedure TAuHintWindow.Paint;
var
  G: TGfx;
begin
  if GfxStopped then Exit;
  G := TGfx.Create(Canvas.Handle, Width, Height);
  try
    G.FillRect(0, 0, Width, Height, clCard);
    G.StrokeRect(0, 0, Width, Height, 1, clBorderHi);
    G.Text(Caption, S(10), S(6), Width - S(20), Height - S(12), UIFont(12), clText, 0, 1, tfWrap);
  finally
    G.Free;
  end;
end;

initialization
  CaretHandler := TCaretHandler.Create;
  HintWindowClass := TAuHintWindow;
  Application.AddOnUserInputHandler(@CaretHandler.UserInput);

finalization
  FreeAndNil(SplitterList);
  FreePaintBuffer;
  if Application <> nil then Application.RemoveOnUserInputHandler(@CaretHandler.UserInput);
  CaretTimer.Free;
  CaretHandler.Free;

end.
