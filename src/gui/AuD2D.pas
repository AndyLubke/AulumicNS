unit AuD2D;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

{ ==============================================================================
  AulumicNS - AuD2D
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  ---> AulumicNS: the parts of Direct2D, DirectWrite and the Windows Imaging
  Component (WIC) that AuGfx uses, declared by hand (FPC 3.2.2 has no units
  for them). The interfaces are declared in full up to the last method that
  is called: the ORDER of the methods is the binary contract (the vtable), so
  never reorder or remove one. Methods that are not called keep their slot as
  a parameterless procedure (calling one of those would corrupt the stack).
  A C++ method that returns a structure takes a hidden pointer to the result
  as its first parameter (after Self): such methods are declared as a
  procedure with an "out" parameter.
  =============================================================================}

interface

uses
  Windows, ActiveX;

const
  d2d1lib = 'd2d1.dll';
  dwritelib = 'dwrite.dll';

  DXGI_FORMAT_B8G8R8A8_UNORM = 87;

  D2D1_ALPHA_MODE_PREMULTIPLIED = 1;
  D2D1_ALPHA_MODE_IGNORE = 3;

  D2D1_RENDER_TARGET_TYPE_DEFAULT = 0;
  D2D1_RENDER_TARGET_TYPE_SOFTWARE = 1;
  D2D1_RENDER_TARGET_TYPE_HARDWARE = 2;

  D2D1_FACTORY_TYPE_SINGLE_THREADED = 0;
  D2D1_FACTORY_TYPE_MULTI_THREADED = 1;

  D2D1_ANTIALIAS_MODE_PER_PRIMITIVE = 0;
  D2D1_ANTIALIAS_MODE_ALIASED = 1;

  D2D1_TEXT_ANTIALIAS_MODE_DEFAULT = 0;
  D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE = 1;
  D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE = 2;

  D2D1_FIGURE_BEGIN_FILLED = 0;
  D2D1_FIGURE_END_OPEN = 0;
  D2D1_FIGURE_END_CLOSED = 1;
  D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE = 0;
  D2D1_SWEEP_DIRECTION_CLOCKWISE = 1;
  D2D1_ARC_SIZE_SMALL = 0;
  D2D1_ARC_SIZE_LARGE = 1;
  D2D1_FILL_MODE_ALTERNATE = 0;
  D2D1_FILL_MODE_WINDING = 1;
  D2D1_CAP_STYLE_FLAT = 0;
  D2D1_CAP_STYLE_ROUND = 2;
  D2D1_LINE_JOIN_MITER = 0;
  D2D1_LINE_JOIN_ROUND = 2;
  D2D1_DASH_STYLE_SOLID = 0;
  D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR = 0;
  D2D1_BITMAP_INTERPOLATION_MODE_LINEAR = 1;
  D2D1_EXTEND_MODE_CLAMP = 0;
  D2D1_GAMMA_2_2 = 0;
  D2D1_DRAW_TEXT_OPTIONS_NONE = 0;
  D2D1_DRAW_TEXT_OPTIONS_CLIP = 2;
  D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT = 4;
  D2D1_LAYER_OPTIONS_NONE = 0;
  D2D1_LAYER_OPTIONS_INITIALIZE_FOR_CLEARTYPE = 1;
  D2D1_GEOMETRY_RELATION_DISJOINT = 1;

  D2DERR_RECREATE_TARGET = HRESULT($8899000C);

  D2D1_PRESENT_OPTIONS_NONE = 0;
  D2D1_PRESENT_OPTIONS_RETAIN_CONTENTS = 1;
  D2D1_PRESENT_OPTIONS_IMMEDIATELY = 2;

  DWRITE_FACTORY_TYPE_SHARED = 0;
  DWRITE_FONT_WEIGHT_NORMAL = 400;
  DWRITE_FONT_WEIGHT_SEMI_BOLD = 600;
  DWRITE_FONT_WEIGHT_BOLD = 700;
  DWRITE_FONT_STYLE_NORMAL = 0;
  DWRITE_FONT_STYLE_ITALIC = 2;
  DWRITE_FONT_STRETCH_NORMAL = 5;
  DWRITE_TEXT_ALIGNMENT_LEADING = 0;
  DWRITE_TEXT_ALIGNMENT_TRAILING = 1;
  DWRITE_TEXT_ALIGNMENT_CENTER = 2;
  DWRITE_PARAGRAPH_ALIGNMENT_NEAR = 0;
  DWRITE_PARAGRAPH_ALIGNMENT_FAR = 1;
  DWRITE_PARAGRAPH_ALIGNMENT_CENTER = 2;
  DWRITE_WORD_WRAPPING_WRAP = 0;
  DWRITE_WORD_WRAPPING_NO_WRAP = 1;
  DWRITE_TRIMMING_GRANULARITY_NONE = 0;
  DWRITE_TRIMMING_GRANULARITY_CHARACTER = 1;
  DWRITE_TRIMMING_GRANULARITY_WORD = 2;

  WICDecodeMetadataCacheOnDemand = 0;
  WICBitmapDitherTypeNone = 0;
  WICBitmapPaletteTypeCustom = 0;
  WICBitmapInterpolationModeFant = 3;
  WICBitmapEncoderNoCache = 2;

  CLSID_WICImagingFactory: TGUID = '{CACAF262-9370-4615-A13B-9F5539DA4C0A}';
  GUID_WICPixelFormat1bppIndexed: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC901}';
  GUID_WICPixelFormat8bppIndexed: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC904}';
  GUID_WICPixelFormatBlackWhite: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC905}';
  GUID_WICPixelFormat24bppBGR: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC90C}';
  GUID_WICPixelFormat32bppBGRA: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC90F}';
  GUID_WICPixelFormat32bppPBGRA: TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC910}';
  GUID_ContainerFormatPng: TGUID = '{1B7CFAF4-713F-473C-BBCD-6137425FAEAF}';
  GUID_ContainerFormatJpeg: TGUID = '{19E4A5AA-5662-4FC5-A0C0-1758028E1057}';

type
  TD2DPoint = record
    X, Y: Single;
  end;
  PD2DPoint = ^TD2DPoint;

  TD2DSizeU = record
    W, H: UINT;
  end;

  TD2DSizeF = record
    W, H: Single;
  end;

  TD2DRect = record
    Left, Top, Right, Bottom: Single;
  end;
  PD2DRect = ^TD2DRect;

  TD2DColor = record
    R, G, B, A: Single;
  end;

  TD2DMatrix = record
    M11, M12, M21, M22, DX, DY: Single;
  end;

  TD2DPixelFormat = record
    Format: UINT;
    AlphaMode: UINT;
  end;

  TD2DRenderTargetProps = record
    Kind: UINT;
    PixelFormat: TD2DPixelFormat;
    DpiX, DpiY: Single;
    Usage: UINT;
    MinLevel: UINT;
  end;

  TD2DBitmapProps = record
    PixelFormat: TD2DPixelFormat;
    DpiX, DpiY: Single;
  end;

  TD2DBrushProps = record
    Opacity: Single;
    Transform: TD2DMatrix;
  end;

  TD2DBitmapBrushProps = record
    ExtendX, ExtendY: UINT;
    Interpolation: UINT;
  end;

  TD2DLinearGradientProps = record
    StartPoint, EndPoint: TD2DPoint;
  end;

  TD2DGradientStop = record
    Position: Single;
    Color: TD2DColor;
  end;

  TD2DRoundedRect = record
    Rect: TD2DRect;
    RadiusX, RadiusY: Single;
  end;

  TD2DEllipse = record
    Center: TD2DPoint;
    RadiusX, RadiusY: Single;
  end;

  TD2DBezier = record
    P1, P2, P3: TD2DPoint;
  end;

  TD2DArc = record
    Point: TD2DPoint;
    Size: TD2DSizeF;
    Rotation: Single;
    Sweep: UINT;
    ArcSize: UINT;
  end;

  TD2DStrokeProps = record
    StartCap, EndCap, DashCap, LineJoin: UINT;
    MiterLimit: Single;
    DashStyle: UINT;
    DashOffset: Single;
  end;

  TD2DLayerParams = record
    ContentBounds: TD2DRect;
    GeometricMask: Pointer;
    MaskAntialias: UINT;
    MaskTransform: TD2DMatrix;
    Opacity: Single;
    OpacityBrush: Pointer;
    LayerOptions: UINT;
  end;

  TDWriteTextMetrics = record
    Left, Top, Width, WidthWithTrailing, Height, LayoutWidth, LayoutHeight: Single;
    MaxBidiDepth, LineCount: UINT;
  end;

  TDWriteTrimming = record
    Granularity, Delimiter, DelimiterCount: UINT;
  end;

  TWICRect = record
    X, Y, Width, Height: Integer;
  end;
  PWICRect = ^TWICRect;

  { ---- Direct2D ---- }

  ID2D1Factory = interface;
  ID2D1Geometry = interface;

  ID2D1Resource = interface(IUnknown)
    ['{2CD90691-12E2-11DC-9FED-001143A055F9}']
    procedure GetFactory(out AFactory: ID2D1Factory); stdcall;
  end;

  ID2D1Bitmap = interface(ID2D1Resource)
    ['{A2296057-EA42-4099-983B-539FB6505426}']
    procedure GetSize(out ASize: TD2DSizeF); stdcall;
    procedure GetPixelSize(out ASize: TD2DSizeU); stdcall;
  end;

  ID2D1GradientStopCollection = interface(ID2D1Resource)
    ['{2CD906A7-12E2-11DC-9FED-001143A055F9}']
  end;

  ID2D1Brush = interface(ID2D1Resource)
    ['{2CD906A8-12E2-11DC-9FED-001143A055F9}']
    procedure SetOpacity(AOpacity: Single); stdcall;
    procedure SetTransform(constref ATransform: TD2DMatrix); stdcall;
    function GetOpacity: Single; stdcall;
    procedure GetTransform(out ATransform: TD2DMatrix); stdcall;
  end;

  ID2D1BitmapBrush = interface(ID2D1Brush)
    ['{2CD906AA-12E2-11DC-9FED-001143A055F9}']
  end;

  ID2D1SolidColorBrush = interface(ID2D1Brush)
    ['{2CD906A9-12E2-11DC-9FED-001143A055F9}']
    procedure SetColor(constref AColor: TD2DColor); stdcall;
  end;

  ID2D1LinearGradientBrush = interface(ID2D1Brush)
    ['{2CD906AB-12E2-11DC-9FED-001143A055F9}']
  end;

  ID2D1StrokeStyle = interface(ID2D1Resource)
    ['{2CD9069D-12E2-11DC-9FED-001143A055F9}']
  end;

  ID2D1Layer = interface(ID2D1Resource)
    ['{2CD9069B-12E2-11DC-9FED-001143A055F9}']
  end;

  ID2D1SimplifiedGeometrySink = interface(IUnknown)
    ['{2CD9069E-12E2-11DC-9FED-001143A055F9}']
    procedure SetFillMode(AMode: UINT); stdcall;
    procedure SetSegmentFlags(AFlags: UINT); stdcall;
    procedure BeginFigure(AStart: TD2DPoint; AFigureBegin: UINT); stdcall;
    procedure AddLines(APoints: PD2DPoint; ACount: UINT); stdcall;
    procedure AddBeziers(ABeziers: Pointer; ACount: UINT); stdcall;
    procedure EndFigure(AFigureEnd: UINT); stdcall;
    function Close: HRESULT; stdcall;
  end;

  ID2D1GeometrySink = interface(ID2D1SimplifiedGeometrySink)
    ['{2CD9069F-12E2-11DC-9FED-001143A055F9}']
    procedure AddLine(APoint: TD2DPoint); stdcall;
    procedure AddBezier(constref ABezier: TD2DBezier); stdcall;
    procedure AddQuadraticBezier(ABezier: Pointer); stdcall;
    procedure AddQuadraticBeziers(ABeziers: Pointer; ACount: UINT); stdcall;
    procedure AddArc(constref AArc: TD2DArc); stdcall;
  end;

  ID2D1Geometry = interface(ID2D1Resource)
    ['{2CD906A1-12E2-11DC-9FED-001143A055F9}']
    function GetBounds(ATransform: Pointer; out ABounds: TD2DRect): HRESULT; stdcall;
    procedure Slot_GetWidenedBounds; stdcall;
    procedure Slot_StrokeContainsPoint; stdcall;
    procedure Slot_FillContainsPoint; stdcall;
    procedure Slot_CompareWithGeometry; stdcall;
    procedure Slot_Simplify; stdcall;
    procedure Slot_Tessellate; stdcall;
    procedure Slot_CombineWithGeometry; stdcall;
    procedure Slot_Outline; stdcall;
    procedure Slot_ComputeArea; stdcall;
    procedure Slot_ComputeLength; stdcall;
    procedure Slot_ComputePointAtLength; stdcall;
    procedure Slot_Widen; stdcall;
  end;

  ID2D1PathGeometry = interface(ID2D1Geometry)
    ['{2CD906A5-12E2-11DC-9FED-001143A055F9}']
    function Open(out ASink: ID2D1GeometrySink): HRESULT; stdcall;
  end;

  ID2D1GeometryGroup = interface(ID2D1Geometry)
    ['{2CD906A6-12E2-11DC-9FED-001143A055F9}']
  end;

  ID2D1RenderTarget = interface(ID2D1Resource)
    ['{2CD90694-12E2-11DC-9FED-001143A055F9}']
    function CreateBitmap(ASize: TD2DSizeU; AData: Pointer; APitch: UINT; constref AProps: TD2DBitmapProps;
      out ABitmap: ID2D1Bitmap): HRESULT; stdcall;
    procedure Slot_CreateBitmapFromWicBitmap; stdcall;
    procedure Slot_CreateSharedBitmap; stdcall;
    function CreateBitmapBrush(ABitmap: ID2D1Bitmap; ABitmapBrushProps: Pointer; ABrushProps: Pointer;
      out ABrush: ID2D1BitmapBrush): HRESULT; stdcall;
    function CreateSolidColorBrush(constref AColor: TD2DColor; ABrushProps: Pointer;
      out ABrush: ID2D1SolidColorBrush): HRESULT; stdcall;
    function CreateGradientStopCollection(AStops: Pointer; ACount: UINT; AGamma: UINT; AExtend: UINT;
      out AStopsOut: ID2D1GradientStopCollection): HRESULT; stdcall;
    function CreateLinearGradientBrush(constref AProps: TD2DLinearGradientProps; ABrushProps: Pointer;
      AStops: ID2D1GradientStopCollection; out ABrush: ID2D1LinearGradientBrush): HRESULT; stdcall;
    procedure Slot_CreateRadialGradientBrush; stdcall;
    procedure Slot_CreateCompatibleRenderTarget; stdcall;
    function CreateLayer(ASize: Pointer; out ALayer: ID2D1Layer): HRESULT; stdcall;
    procedure Slot_CreateMesh; stdcall;
    procedure DrawLine(P0, P1: TD2DPoint; ABrush: ID2D1Brush; AWidth: Single; AStyle: ID2D1StrokeStyle); stdcall;
    procedure DrawRectangle(constref ARect: TD2DRect; ABrush: ID2D1Brush; AWidth: Single; AStyle: ID2D1StrokeStyle); stdcall;
    procedure FillRectangle(constref ARect: TD2DRect; ABrush: ID2D1Brush); stdcall;
    procedure DrawRoundedRectangle(constref ARect: TD2DRoundedRect; ABrush: ID2D1Brush; AWidth: Single;
      AStyle: ID2D1StrokeStyle); stdcall;
    procedure FillRoundedRectangle(constref ARect: TD2DRoundedRect; ABrush: ID2D1Brush); stdcall;
    procedure DrawEllipse(constref AEllipse: TD2DEllipse; ABrush: ID2D1Brush; AWidth: Single;
      AStyle: ID2D1StrokeStyle); stdcall;
    procedure FillEllipse(constref AEllipse: TD2DEllipse; ABrush: ID2D1Brush); stdcall;
    procedure DrawGeometry(AGeometry: ID2D1Geometry; ABrush: ID2D1Brush; AWidth: Single;
      AStyle: ID2D1StrokeStyle); stdcall;
    procedure FillGeometry(AGeometry: ID2D1Geometry; ABrush: ID2D1Brush; AOpacityBrush: ID2D1Brush); stdcall;
    procedure Slot_FillMesh; stdcall;
    procedure Slot_FillOpacityMask; stdcall;
    procedure DrawBitmap(ABitmap: ID2D1Bitmap; ADest: PD2DRect; AOpacity: Single; AInterpolation: UINT;
      ASource: PD2DRect); stdcall;
    procedure Slot_DrawText; stdcall;
    procedure DrawTextLayout(AOrigin: TD2DPoint; ALayout: IUnknown; ABrush: ID2D1Brush; AOptions: UINT); stdcall;
    procedure Slot_DrawGlyphRun; stdcall;
    procedure SetTransform(constref ATransform: TD2DMatrix); stdcall;
    procedure GetTransform(out ATransform: TD2DMatrix); stdcall;
    procedure SetAntialiasMode(AMode: UINT); stdcall;
    function GetAntialiasMode: UINT; stdcall;
    procedure SetTextAntialiasMode(AMode: UINT); stdcall;
    function GetTextAntialiasMode: UINT; stdcall;
    procedure SetTextRenderingParams(AParams: IUnknown); stdcall;
    procedure Slot_GetTextRenderingParams; stdcall;
    procedure Slot_SetTags; stdcall;
    procedure Slot_GetTags; stdcall;
    procedure PushLayer(constref AParams: TD2DLayerParams; ALayer: ID2D1Layer); stdcall;
    procedure PopLayer; stdcall;
    function Flush(ATag1, ATag2: Pointer): HRESULT; stdcall;
    procedure Slot_SaveDrawingState; stdcall;
    procedure Slot_RestoreDrawingState; stdcall;
    procedure PushAxisAlignedClip(constref ARect: TD2DRect; AMode: UINT); stdcall;
    procedure PopAxisAlignedClip; stdcall;
    procedure Clear(AColor: Pointer); stdcall;
    procedure BeginDraw; stdcall;
    function EndDraw(ATag1, ATag2: Pointer): HRESULT; stdcall;
    procedure Slot_GetPixelFormat; stdcall;
    procedure SetDpi(ADpiX, ADpiY: Single); stdcall;
    procedure GetDpi(out ADpiX, ADpiY: Single); stdcall;
    procedure Slot_GetSize; stdcall;
    procedure Slot_GetPixelSize; stdcall;
    function GetMaximumBitmapSize: UINT; stdcall;
    procedure Slot_IsSupported; stdcall;
  end;

  TD2DHwndTargetProps = record
    Wnd: HWND;
    PixelSize: TD2DSizeU;
    PresentOptions: UINT;
  end;

  ID2D1HwndRenderTarget = interface(ID2D1RenderTarget)
    ['{2CD90698-12E2-11DC-9FED-001143A055F9}']
    function CheckWindowState: UINT; stdcall;
    function Resize(constref ASize: TD2DSizeU): HRESULT; stdcall;
    function GetHwnd: HWND; stdcall;
  end;

  ID2D1DCRenderTarget = interface(ID2D1RenderTarget)
    ['{1C51BC64-DE61-46FD-9899-63A5D8F03950}']
    function BindDC(ADC: HDC; const ARect: TRect): HRESULT; stdcall;
  end;

  ID2D1Factory = interface(IUnknown)
    ['{06152247-6F50-465A-9245-118BFD3B6007}']
    function ReloadSystemMetrics: HRESULT; stdcall;
    procedure GetDesktopDpi(out ADpiX, ADpiY: Single); stdcall;
    procedure Slot_CreateRectangleGeometry; stdcall;
    function CreateRoundedRectangleGeometry(constref ARect: TD2DRoundedRect; out AGeometry: ID2D1Geometry): HRESULT; stdcall;
    function CreateEllipseGeometry(constref AEllipse: TD2DEllipse; out AGeometry: ID2D1Geometry): HRESULT; stdcall;
    function CreateGeometryGroup(AFillMode: UINT; AGeometries: Pointer; ACount: UINT;
      out AGroup: ID2D1GeometryGroup): HRESULT; stdcall;
    procedure Slot_CreateTransformedGeometry; stdcall;
    function CreatePathGeometry(out AGeometry: ID2D1PathGeometry): HRESULT; stdcall;
    function CreateStrokeStyle(constref AProps: TD2DStrokeProps; ADashes: Pointer; ADashCount: UINT;
      out AStyle: ID2D1StrokeStyle): HRESULT; stdcall;
    procedure Slot_CreateDrawingStateBlock; stdcall;
    procedure Slot_CreateWicBitmapRenderTarget; stdcall;
    function CreateHwndRenderTarget(constref AProps: TD2DRenderTargetProps; constref AWndProps: TD2DHwndTargetProps;
      out ATarget: ID2D1HwndRenderTarget): HRESULT; stdcall;
    procedure Slot_CreateDxgiSurfaceRenderTarget; stdcall;
    function CreateDCRenderTarget(constref AProps: TD2DRenderTargetProps; out ATarget: ID2D1DCRenderTarget): HRESULT; stdcall;
  end;

  { ---- DirectWrite ---- }

  IDWriteFontCollection = interface(IUnknown)
    ['{A84CEE02-3EEA-4EEE-A827-87C1A02A0FCC}']
    function GetFontFamilyCount: UINT; stdcall;
    procedure Slot_GetFontFamily; stdcall;
    function FindFamilyName(AName: PWideChar; out AIndex: UINT; out AExists: BOOL): HRESULT; stdcall;
  end;

  IDWriteInlineObject = interface(IUnknown)
    ['{8339FDE3-106F-47AB-8373-1C6295EB10B3}']
  end;

  IDWriteTextFormat = interface(IUnknown)
    ['{9C906818-31D7-4FD3-A151-7C5E225DB55A}']
    function SetTextAlignment(AAlign: UINT): HRESULT; stdcall;
    function SetParagraphAlignment(AAlign: UINT): HRESULT; stdcall;
    function SetWordWrapping(AWrap: UINT): HRESULT; stdcall;
    procedure Slot_SetReadingDirection; stdcall;
    procedure Slot_SetFlowDirection; stdcall;
    procedure Slot_SetIncrementalTabStop; stdcall;
    function SetTrimming(constref ATrimming: TDWriteTrimming; ASign: IDWriteInlineObject): HRESULT; stdcall;
    procedure Slot_SetLineSpacing; stdcall;
    procedure Slot_GetTextAlignment; stdcall;
    procedure Slot_GetParagraphAlignment; stdcall;
    procedure Slot_GetWordWrapping; stdcall;
    procedure Slot_GetReadingDirection; stdcall;
    procedure Slot_GetFlowDirection; stdcall;
    procedure Slot_GetIncrementalTabStop; stdcall;
    procedure Slot_GetTrimming; stdcall;
    procedure Slot_GetLineSpacing; stdcall;
    procedure Slot_GetFontCollection; stdcall;
    procedure Slot_GetFontFamilyNameLength; stdcall;
    procedure Slot_GetFontFamilyName; stdcall;
    procedure Slot_GetFontWeight; stdcall;
    procedure Slot_GetFontStyle; stdcall;
    procedure Slot_GetFontStretch; stdcall;
    procedure Slot_GetFontSize; stdcall;
    procedure Slot_GetLocaleNameLength; stdcall;
    procedure Slot_GetLocaleName; stdcall;
  end;

  IDWriteTextLayout = interface(IDWriteTextFormat)
    ['{53737037-6D14-410B-9BFE-0B182BB70961}']
    function SetMaxWidth(AWidth: Single): HRESULT; stdcall;
    function SetMaxHeight(AHeight: Single): HRESULT; stdcall;
    procedure Slot_SetFontCollection; stdcall;
    procedure Slot_SetFontFamilyName; stdcall;
    procedure Slot_SetFontWeight; stdcall;
    procedure Slot_SetFontStyle; stdcall;
    procedure Slot_SetFontStretch; stdcall;
    procedure Slot_SetFontSize; stdcall;
    procedure Slot_SetUnderline; stdcall;
    procedure Slot_SetStrikethrough; stdcall;
    procedure Slot_SetDrawingEffect; stdcall;
    procedure Slot_SetInlineObject; stdcall;
    procedure Slot_SetTypography; stdcall;
    procedure Slot_SetLocaleName; stdcall;
    procedure Slot_GetMaxWidth; stdcall;
    procedure Slot_GetMaxHeight; stdcall;
    procedure Slot_GetFontCollection2; stdcall;
    procedure Slot_GetFontFamilyNameLength2; stdcall;
    procedure Slot_GetFontFamilyName2; stdcall;
    procedure Slot_GetFontWeight2; stdcall;
    procedure Slot_GetFontStyle2; stdcall;
    procedure Slot_GetFontStretch2; stdcall;
    procedure Slot_GetFontSize2; stdcall;
    procedure Slot_GetUnderline; stdcall;
    procedure Slot_GetStrikethrough; stdcall;
    procedure Slot_GetDrawingEffect; stdcall;
    procedure Slot_GetInlineObject; stdcall;
    procedure Slot_GetTypography; stdcall;
    procedure Slot_GetLocaleNameLength2; stdcall;
    procedure Slot_GetLocaleName2; stdcall;
    procedure Slot_Draw; stdcall;
    procedure Slot_GetLineMetrics; stdcall;
    function GetMetrics(out AMetrics: TDWriteTextMetrics): HRESULT; stdcall;
  end;

  IDWriteFactory = interface(IUnknown)
    ['{B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}']
    function GetSystemFontCollection(out ACollection: IDWriteFontCollection; ACheckUpdates: BOOL): HRESULT; stdcall;
    procedure Slot_CreateCustomFontCollection; stdcall;
    procedure Slot_RegisterFontCollectionLoader; stdcall;
    procedure Slot_UnregisterFontCollectionLoader; stdcall;
    procedure Slot_CreateFontFileReference; stdcall;
    procedure Slot_CreateCustomFontFileReference; stdcall;
    procedure Slot_CreateFontFace; stdcall;
    procedure Slot_CreateRenderingParams; stdcall;
    procedure Slot_CreateMonitorRenderingParams; stdcall;
    procedure Slot_CreateCustomRenderingParams; stdcall;
    procedure Slot_RegisterFontFileLoader; stdcall;
    procedure Slot_UnregisterFontFileLoader; stdcall;
    function CreateTextFormat(AFamily: PWideChar; ACollection: IDWriteFontCollection; AWeight, AStyle, AStretch: UINT;
      ASize: Single; ALocale: PWideChar; out AFormat: IDWriteTextFormat): HRESULT; stdcall;
    procedure Slot_CreateTypography; stdcall;
    procedure Slot_GetGdiInterop; stdcall;
    function CreateTextLayout(AText: PWideChar; ALength: UINT; AFormat: IDWriteTextFormat; AMaxWidth, AMaxHeight: Single;
      out ALayout: IDWriteTextLayout): HRESULT; stdcall;
    procedure Slot_CreateGdiCompatibleTextLayout; stdcall;
    function CreateEllipsisTrimmingSign(AFormat: IDWriteTextFormat; out ASign: IDWriteInlineObject): HRESULT; stdcall;
  end;

  { ---- WIC ---- }

  IWICBitmapSource = interface(IUnknown)
    ['{00000120-A8F2-4877-BA0A-FD2B6645FB94}']
    function GetSize(out AWidth, AHeight: UINT): HRESULT; stdcall;
    function GetPixelFormat(out AFormat: TGUID): HRESULT; stdcall;
    function GetResolution(out ADpiX, ADpiY: Double): HRESULT; stdcall;
    function CopyPalette(APalette: IUnknown): HRESULT; stdcall;
    function CopyPixels(ARect: PWICRect; AStride, ABufferSize: UINT; ABuffer: Pointer): HRESULT; stdcall;
  end;

  { a PROPVARIANT, as far as the metadata reader below is asked for (24 bytes) }
  TWicPropVariant = record
    vt: Word;
    wReserved1, wReserved2, wReserved3: Word;
    case Integer of
      0: (uiVal: Word);
      1: (ulVal: DWORD);
      2: (p1, p2: Pointer);
  end;

  IWICMetadataQueryReader = interface(IUnknown)
    ['{30989668-E1C9-4597-B395-458EEDB808DF}']
    procedure Slot_GetContainerFormat; stdcall;
    procedure Slot_GetLocation; stdcall;
    function GetMetadataByName(AName: PWideChar; out AValue: TWicPropVariant): HRESULT; stdcall;
  end;

  IWICBitmapFrameDecode = interface(IWICBitmapSource)
    ['{3B16811B-6A43-4EC9-A813-3D930C13B940}']
    function GetMetadataQueryReader(out AReader: IWICMetadataQueryReader): HRESULT; stdcall;
  end;

  IWICBitmapDecoder = interface(IUnknown)
    ['{9EDDE9E7-8DEE-47EA-99DF-E6FAF2ED44BF}']
    procedure Slot_QueryCapability; stdcall;
    procedure Slot_Initialize; stdcall;
    procedure Slot_GetContainerFormat; stdcall;
    procedure Slot_GetDecoderInfo; stdcall;
    procedure Slot_CopyPalette; stdcall;
    procedure Slot_GetMetadataQueryReader; stdcall;
    procedure Slot_GetPreview; stdcall;
    procedure Slot_GetColorContexts; stdcall;
    procedure Slot_GetThumbnail; stdcall;
    function GetFrameCount(out ACount: UINT): HRESULT; stdcall;
    function GetFrame(AIndex: UINT; out AFrame: IWICBitmapFrameDecode): HRESULT; stdcall;
  end;

  IWICFormatConverter = interface(IWICBitmapSource)
    ['{00000301-A8F2-4877-BA0A-FD2B6645FB94}']
    function Initialize(ASource: IWICBitmapSource; const AFormat: TGUID; ADither: UINT; APalette: IUnknown;
      AAlphaThreshold: Double; APaletteType: UINT): HRESULT; stdcall;
  end;

  IWICBitmapScaler = interface(IWICBitmapSource)
    ['{00000302-A8F2-4877-BA0A-FD2B6645FB94}']
    function Initialize(ASource: IWICBitmapSource; AWidth, AHeight: UINT; AMode: UINT): HRESULT; stdcall;
  end;

  IWICStream = interface(IStream)
    ['{135FF860-22B7-4DDF-B0F6-218F4F299A43}']
    function InitializeFromIStream(AStream: IStream): HRESULT; stdcall;
    function InitializeFromFilename(AName: PWideChar; AAccess: DWORD): HRESULT; stdcall;
    function InitializeFromMemory(AData: Pointer; ASize: DWORD): HRESULT; stdcall;
  end;

  IWICBitmapFrameEncode = interface(IUnknown)
    ['{00000105-A8F2-4877-BA0A-FD2B6645FB94}']
    function Initialize(AOptions: IUnknown): HRESULT; stdcall;
    function SetSize(AWidth, AHeight: UINT): HRESULT; stdcall;
    function SetResolution(ADpiX, ADpiY: Double): HRESULT; stdcall;
    function SetPixelFormat(var AFormat: TGUID): HRESULT; stdcall;
    procedure Slot_SetColorContexts; stdcall;
    procedure Slot_SetPalette; stdcall;
    procedure Slot_SetThumbnail; stdcall;
    function WritePixels(ALines, AStride, ABufferSize: UINT; APixels: Pointer): HRESULT; stdcall;
    function WriteSource(ASource: IWICBitmapSource; ARect: PWICRect): HRESULT; stdcall;
    function Commit: HRESULT; stdcall;
  end;

  IWICBitmapEncoder = interface(IUnknown)
    ['{00000103-A8F2-4877-BA0A-FD2B6645FB94}']
    function Initialize(AStream: IStream; ACache: UINT): HRESULT; stdcall;
    procedure Slot_GetContainerFormat; stdcall;
    procedure Slot_GetEncoderInfo; stdcall;
    procedure Slot_SetColorContexts; stdcall;
    procedure Slot_SetPalette; stdcall;
    procedure Slot_SetThumbnail; stdcall;
    procedure Slot_SetPreview; stdcall;
    function CreateNewFrame(out AFrame: IWICBitmapFrameEncode; AOptions: Pointer): HRESULT; stdcall;
    function Commit: HRESULT; stdcall;
  end;

  IWICBitmap = interface(IWICBitmapSource)
    ['{00000121-A8F2-4877-BA0A-FD2B6645FB94}']
  end;

  IWICImagingFactory = interface(IUnknown)
    ['{EC5EC8A9-C395-4314-9C77-54D7A935FF70}']
    function CreateDecoderFromFilename(AName: PWideChar; AVendor: PGUID; AAccess: DWORD; AOptions: UINT;
      out ADecoder: IWICBitmapDecoder): HRESULT; stdcall;
    function CreateDecoderFromStream(AStream: IStream; AVendor: PGUID; AOptions: UINT;
      out ADecoder: IWICBitmapDecoder): HRESULT; stdcall;
    procedure Slot_CreateDecoderFromFileHandle; stdcall;
    procedure Slot_CreateComponentInfo; stdcall;
    procedure Slot_CreateDecoder; stdcall;
    function CreateEncoder(const AContainer: TGUID; AVendor: PGUID; out AEncoder: IWICBitmapEncoder): HRESULT; stdcall;
    procedure Slot_CreatePalette; stdcall;
    function CreateFormatConverter(out AConverter: IWICFormatConverter): HRESULT; stdcall;
    function CreateBitmapScaler(out AScaler: IWICBitmapScaler): HRESULT; stdcall;
    procedure Slot_CreateBitmapClipper; stdcall;
    procedure Slot_CreateBitmapFlipRotator; stdcall;
    function CreateStream(out AStream: IWICStream): HRESULT; stdcall;
    procedure Slot_CreateColorContext; stdcall;
    procedure Slot_CreateColorTransformer; stdcall;
    procedure Slot_CreateBitmap; stdcall;
    procedure Slot_CreateBitmapFromSource; stdcall;
    procedure Slot_CreateBitmapFromSourceRect; stdcall;
    function CreateBitmapFromMemory(AWidth, AHeight: UINT; const AFormat: TGUID; AStride, ABufferSize: UINT;
      ABuffer: Pointer; out ABitmap: IWICBitmap): HRESULT; stdcall;
  end;

function D2D1CreateFactory(AType: UINT; const AIID: TGUID; AOptions: Pointer; out AFactory: ID2D1Factory): HRESULT;
  stdcall; external d2d1lib;
function DWriteCreateFactory(AType: UINT; const AIID: TGUID; out AFactory: IDWriteFactory): HRESULT;
  stdcall; external dwritelib;

function D2DPt(X, Y: Single): TD2DPoint; inline;
function D2DRc(X, Y, W, H: Single): TD2DRect; inline;
function D2DIdentity: TD2DMatrix; inline;

implementation

function D2DPt(X, Y: Single): TD2DPoint; inline;
begin
  Result.X := X;
  Result.Y := Y;
end;

function D2DRc(X, Y, W, H: Single): TD2DRect; inline;
begin
  Result.Left := X;
  Result.Top := Y;
  Result.Right := X + W;
  Result.Bottom := Y + H;
end;

function D2DIdentity: TD2DMatrix; inline;
begin
  Result.M11 := 1; Result.M12 := 0;
  Result.M21 := 0; Result.M22 := 1;
  Result.DX := 0; Result.DY := 0;
end;

end.
