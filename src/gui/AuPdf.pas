unit AuPdf;

{ PDF rendering with the PDF engine built into Windows 10 / 11
  (Windows.Data.Pdf, a WinRT component of the system - like Direct2D it ships
  with Windows, so the exe stays self-contained).

  TAuPdfRenderer runs the engine in its own thread (multithreaded
  apartment): it loads the document, reads the page sizes and renders the
  requested pages at the requested pixel width into bitmaps (TGfxBitmap). Requests
  are served newest first; finished pages are taken by the main thread
  with TakeResults. }

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, SyncObjs, ActiveX, AuGfx;

type
  TAuPdfPageSize = record
    W, H: Single;                // points (1/72 inch, as Windows reports them in DIPs / 96)
  end;

  TAuPdfResult = record
    Page, Width: Integer;
    Bitmap: TGfxBitmap;
  end;
  TAuPdfResults = array of TAuPdfResult;

  TAuPdfJob = record
    Page, Width: Integer;
  end;

  { TAuPdfRenderer }

  TAuPdfRenderer = class(TThread)
  private
    FFileName: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FJobs: array of TAuPdfJob;
    FResults: TAuPdfResults;
    FSizes: array of TAuPdfPageSize;
    FLoaded: Boolean;
    FError: string;
    function TakeJob(out J: TAuPdfJob): Boolean;
    procedure Work;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    procedure Request(Page, Width: Integer);
    procedure CancelRequests;
    function TakeResults: TAuPdfResults;
    function PageCount: Integer;
    function PageSize(I: Integer): TAuPdfPageSize;
    property Loaded: Boolean read FLoaded;      // pages known (or failed)
    property Error: string read FError;
  end;

function PdfEngineAvailable: Boolean;

implementation

uses
  AuAudioTypes;   // ---> AulumicNS: LongPath (paths of 260 characters and more)

type
  HSTRING = Pointer;

  IInspectable = interface(IUnknown)
    ['{AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}']
    function GetIids(out Count: Cardinal; out Iids: PGUID): HRESULT; stdcall;
    function GetRuntimeClassName(out Name: HSTRING): HRESULT; stdcall;
    function GetTrustLevel(out Level: Integer): HRESULT; stdcall;
  end;

  IAsyncInfo = interface(IInspectable)
    ['{00000036-0000-0000-C000-000000000046}']
    function get_Id(out Id: Cardinal): HRESULT; stdcall;
    function get_Status(out Status: Integer): HRESULT; stdcall;
    function get_ErrorCode(out Code: HRESULT): HRESULT; stdcall;
    function Cancel: HRESULT; stdcall;
    function Close: HRESULT; stdcall;
  end;

  IAsyncAction = interface(IInspectable)
    ['{5A648006-843A-4DA9-865B-9D26E5DFAD7B}']
    function put_Completed(Handler: Pointer): HRESULT; stdcall;
    function get_Completed(out Handler: Pointer): HRESULT; stdcall;
    function GetResults: HRESULT; stdcall;
  end;

  IPdfPageRenderOptions = interface(IInspectable)
    ['{3C98056F-B7CF-4C29-9A04-52D90267F425}']
    function get_SourceRect(out R: TGfxRectF): HRESULT; stdcall;
    function put_SourceRect(R: TGfxRectF): HRESULT; stdcall;
    function get_DestinationWidth(out W: Cardinal): HRESULT; stdcall;
    function put_DestinationWidth(W: Cardinal): HRESULT; stdcall;
    function get_DestinationHeight(out H: Cardinal): HRESULT; stdcall;
    function put_DestinationHeight(H: Cardinal): HRESULT; stdcall;
    function get_BackgroundColor(out C: Cardinal): HRESULT; stdcall;
    function put_BackgroundColor(C: Cardinal): HRESULT; stdcall;
    function get_IsIgnoringHighContrast(out V: ByteBool): HRESULT; stdcall;
    function put_IsIgnoringHighContrast(V: ByteBool): HRESULT; stdcall;
    function get_BitmapEncoderId(out Id: TGUID): HRESULT; stdcall;
    function put_BitmapEncoderId(Id: TGUID): HRESULT; stdcall;
  end;

  TWinSize = record
    W, H: Single;
  end;

  IPdfPage = interface(IInspectable)
    ['{9DB4B0C8-5320-4CFC-AD76-493FDAD0E594}']
    function RenderToStreamAsync(Stream: Pointer; out Act: IAsyncAction): HRESULT; stdcall;
    function RenderWithOptionsToStreamAsync(Stream: Pointer; Options: Pointer; out Act: IAsyncAction): HRESULT; stdcall;
    function PreparePageAsync(out Act: IAsyncAction): HRESULT; stdcall;
    function get_Index(out Index: Cardinal): HRESULT; stdcall;
    function get_Size(out Size: TWinSize): HRESULT; stdcall;
  end;

  IPdfDocument = interface(IInspectable)
    ['{AC7EBEDD-80FA-4089-846E-81B77FF5A86C}']
    function GetPage(Index: Cardinal; out Page: IPdfPage): HRESULT; stdcall;
    function get_PageCount(out Count: Cardinal): HRESULT; stdcall;
    function get_IsPasswordProtected(out V: ByteBool): HRESULT; stdcall;
  end;

  { IAsyncOperation<PdfDocument>: only used through the vtable of the
    object returned by LoadFromStreamAsync, never asked for by its IID }
  IAsyncOpPdfDocument = interface(IInspectable)
    ['{00000000-0000-0000-0000-000000000001}']
    function put_Completed(Handler: Pointer): HRESULT; stdcall;
    function get_Completed(out Handler: Pointer): HRESULT; stdcall;
    function GetResults(out Doc: IPdfDocument): HRESULT; stdcall;
  end;

  IPdfDocumentStatics = interface(IInspectable)
    ['{433A0B5F-C007-4788-90F2-08143D922599}']
    function LoadFromFileAsync(F: Pointer; out Op: IAsyncOpPdfDocument): HRESULT; stdcall;
    function LoadFromFileWithPasswordAsync(F: Pointer; Pw: HSTRING; out Op: IAsyncOpPdfDocument): HRESULT; stdcall;
    function LoadFromStreamAsync(Stream: Pointer; out Op: IAsyncOpPdfDocument): HRESULT; stdcall;
    function LoadFromStreamWithPasswordAsync(Stream: Pointer; Pw: HSTRING; out Op: IAsyncOpPdfDocument): HRESULT; stdcall;
  end;

const
  IID_IRandomAccessStream: TGUID = '{905A0FE1-BC53-11DF-8C49-001E4FC686DA}';
  BmpEncoderId: TGUID = '{69BE8BB4-D66D-47C8-865A-ED1589433782}';
  RO_INIT_MULTITHREADED = 1;

type
  TRoInitialize = function(InitType: Integer): HRESULT; stdcall;
  TRoUninitialize = procedure; stdcall;
  TRoGetActivationFactory = function(ClassId: HSTRING; const IID: TGUID; out Factory: Pointer): HRESULT; stdcall;
  TRoActivateInstance = function(ClassId: HSTRING; out Instance: Pointer): HRESULT; stdcall;
  TWindowsCreateString = function(Src: PWideChar; Len: Cardinal; out S: HSTRING): HRESULT; stdcall;
  TWindowsDeleteString = function(S: HSTRING): HRESULT; stdcall;
  TCreateRAStreamOnFile = function(FilePath: PWideChar; AccessMode: DWORD; const IID: TGUID; out Stream: Pointer): HRESULT; stdcall;
  TCreateRAStreamOverStream = function(Stream: Pointer; Options: DWORD; const IID: TGUID; out RAStream: Pointer): HRESULT; stdcall;

var
  ApiLoaded: Integer = 0;          // 0 unknown, 1 ok, -1 missing
  RoInitialize: TRoInitialize;
  RoUninitialize: TRoUninitialize;
  RoGetActivationFactory: TRoGetActivationFactory;
  RoActivateInstance: TRoActivateInstance;
  WindowsCreateString: TWindowsCreateString;
  WindowsDeleteString: TWindowsDeleteString;
  CreateRandomAccessStreamOnFile: TCreateRAStreamOnFile;
  CreateRandomAccessStreamOverStream: TCreateRAStreamOverStream;

{ ---> AulumicNS: a PDF whose path has 260 characters or more.
  CreateRandomAccessStreamOnFile takes no such path, so the file is read into
  memory here (the \\?\ form) and the engine gets a stream over that memory. }
function LongPathPdfStream(const AFileName: string; out AStream: Pointer): HRESULT;
const
  MAX_PDF_BYTES = Int64(1024) * 1024 * 1024;
var
  FS: TFileStream;
  HG: HGLOBAL;
  P: Pointer;
  Mem: IStream;
begin
  AStream := nil;
  HG := 0;
  try
    FS := TFileStream.Create(LongPath(AFileName), fmOpenRead or fmShareDenyNone);
    try
      if (FS.Size <= 0) or (FS.Size > MAX_PDF_BYTES) then Exit(E_FAIL);
      HG := GlobalAlloc(GMEM_MOVEABLE, FS.Size);
      if HG = 0 then Exit(E_OUTOFMEMORY);
      P := GlobalLock(HG);
      try
        FS.ReadBuffer(P^, FS.Size);
      finally
        GlobalUnlock(HG);
      end;
    finally
      FS.Free;
    end;
  except
    if HG <> 0 then GlobalFree(HG);
    Exit(E_FAIL);
  end;
  if CreateStreamOnHGlobal(HG, True, Mem) <> S_OK then
  begin
    GlobalFree(HG);
    Exit(E_FAIL);
  end;
  { the random access stream keeps the memory stream alive }
  Result := CreateRandomAccessStreamOverStream(Pointer(Mem), 0, IID_IRandomAccessStream, AStream);
end;

function LoadApi: Boolean;
var
  Co, Sh: HMODULE;
begin
  if ApiLoaded = 0 then
  begin
    ApiLoaded := -1;
    Co := LoadLibrary('combase.dll');
    Sh := LoadLibrary('shcore.dll');
    if (Co <> 0) and (Sh <> 0) then
    begin
      Pointer(RoInitialize) := GetProcAddress(Co, 'RoInitialize');
      Pointer(RoUninitialize) := GetProcAddress(Co, 'RoUninitialize');
      Pointer(RoGetActivationFactory) := GetProcAddress(Co, 'RoGetActivationFactory');
      Pointer(RoActivateInstance) := GetProcAddress(Co, 'RoActivateInstance');
      Pointer(WindowsCreateString) := GetProcAddress(Co, 'WindowsCreateString');
      Pointer(WindowsDeleteString) := GetProcAddress(Co, 'WindowsDeleteString');
      Pointer(CreateRandomAccessStreamOnFile) := GetProcAddress(Sh, 'CreateRandomAccessStreamOnFile');
      Pointer(CreateRandomAccessStreamOverStream) := GetProcAddress(Sh, 'CreateRandomAccessStreamOverStream');
      if Assigned(RoInitialize) and Assigned(RoGetActivationFactory) and Assigned(RoActivateInstance) and
         Assigned(WindowsCreateString) and Assigned(CreateRandomAccessStreamOnFile) and
         Assigned(CreateRandomAccessStreamOverStream) then ApiLoaded := 1;
    end;
  end;
  Result := ApiLoaded = 1;
end;

function PdfEngineAvailable: Boolean;
begin
  Result := LoadApi;
end;

function HStr(const S: UnicodeString): HSTRING;
begin
  Result := nil;
  WindowsCreateString(PWideChar(S), Length(S), Result);
end;

procedure Check(Hr: HRESULT; const What: string);
begin
  if Hr < 0 then raise Exception.CreateFmt('%s failed (0x%.8x)', [What, Cardinal(Hr)]);
end;

{ waits for an async operation (polling: no completion handler needed) }
procedure WaitAsync(Op: IUnknown; Terminated: PBoolean);
var
  Info: IAsyncInfo;
  St: Integer;
  Code: HRESULT;
  T0: QWord;
begin
  Check(Op.QueryInterface(IAsyncInfo, Info), 'IAsyncInfo');
  T0 := GetTickCount64;
  repeat
    Check(Info.get_Status(St), 'Status');
    if St <> 0 then Break;
    if (Terminated <> nil) and Terminated^ then
    begin
      Info.Cancel;
      raise Exception.Create('Cancelled');
    end;
    if GetTickCount64 - T0 > 60000 then raise Exception.Create('The PDF engine does not answer');
    Sleep(2);
  until False;
  if St <> 1 then
  begin
    Code := 0;
    Info.get_ErrorCode(Code);
    raise Exception.CreateFmt('The PDF could not be read (0x%.8x)', [Cardinal(Code)]);
  end;
end;

{ ---- TAuPdfRenderer ---- }

constructor TAuPdfRenderer.Create(const AFileName: string);
begin
  FFileName := AFileName;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  inherited Create(False);
end;

destructor TAuPdfRenderer.Destroy;
var
  I: Integer;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  for I := 0 to High(FResults) do
    if FResults[I].Bitmap <> nil then DisposeBitmap(FResults[I].Bitmap);
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TAuPdfRenderer.Request(Page, Width: Integer);
var
  I, N: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FJobs) do
      if (FJobs[I].Page = Page) and (FJobs[I].Width = Width) then Exit;
    N := Length(FJobs);
    SetLength(FJobs, N + 1);
    FJobs[N].Page := Page;
    FJobs[N].Width := Width;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TAuPdfRenderer.CancelRequests;
begin
  FLock.Enter;
  try
    FJobs := nil;
  finally
    FLock.Leave;
  end;
end;

function TAuPdfRenderer.TakeJob(out J: TAuPdfJob): Boolean;
var
  N: Integer;
begin
  FLock.Enter;
  try
    N := Length(FJobs);
    Result := N > 0;
    if Result then
    begin
      J := FJobs[N - 1];                 // newest first
      SetLength(FJobs, N - 1);
    end;
  finally
    FLock.Leave;
  end;
end;

function TAuPdfRenderer.TakeResults: TAuPdfResults;
begin
  FLock.Enter;
  try
    Result := FResults;
    FResults := nil;
  finally
    FLock.Leave;
  end;
end;

function TAuPdfRenderer.PageCount: Integer;
begin
  Result := Length(FSizes);
end;

function TAuPdfRenderer.PageSize(I: Integer): TAuPdfPageSize;
begin
  Result := FSizes[I];
end;

{ all WinRT references live in this frame, so they are gone before RoUninitialize }
procedure TAuPdfRenderer.Work;
var
  ClassId: HSTRING;
  Statics: IPdfDocumentStatics;
  P: Pointer;
  FileStream: IUnknown;
  Op: IAsyncOpPdfDocument;
  Doc: IPdfDocument;
  Count, I: Cardinal;
  Page: IPdfPage;
  Sz: TWinSize;
  Sizes: array of TAuPdfPageSize;
  J: TAuPdfJob;
  Mem: IStream;
  RA: IUnknown;
  Opts: IPdfPageRenderOptions;
  Insp: IUnknown;
  Act: IAsyncAction;
  HG: HGLOBAL;
  Data: TBytes;
  Ptr: Pointer;
  Bmp: TGfxBitmap;
  N: Integer;
begin
      { the document }
      ClassId := HStr('Windows.Data.Pdf.PdfDocument');
      try
        Check(RoGetActivationFactory(ClassId, IPdfDocumentStatics, P), 'PdfDocument factory');
      finally
        WindowsDeleteString(ClassId);
      end;
      Statics := IPdfDocumentStatics(P);
      IUnknown(P)._Release;                    // the cast above took a reference
      if Length(FFileName) >= 240 then
        Check(LongPathPdfStream(FFileName, P), 'Open the PDF')
      else
        Check(CreateRandomAccessStreamOnFile(PWideChar(UTF8Decode(FFileName)), 0, IID_IRandomAccessStream, P), 'Open the PDF');
      FileStream := IUnknown(P);
      IUnknown(P)._Release;
      Check(Statics.LoadFromStreamAsync(Pointer(FileStream), Op), 'Load the PDF');
      WaitAsync(Op, @Terminated);
      Check(Op.GetResults(Doc), 'Load the PDF');
      Check(Doc.get_PageCount(Count), 'Page count');
      Sizes := nil;
      SetLength(Sizes, Count);
      // ---> AulumicNS: Count and I are unsigned: no loop for a PDF without
      // pages (Count - 1 would be 4294967295)
      if Count > 0 then
      for I := 0 to Count - 1 do
      begin
        Check(Doc.GetPage(I, Page), 'Page');
        Check(Page.get_Size(Sz), 'Page size');
        Sizes[I].W := Sz.W;
        Sizes[I].H := Sz.H;
        Page := nil;
      end;
      FSizes := Sizes;
      FLoaded := True;

      { pages on request }
      while not Terminated do
      begin
        if not TakeJob(J) then
        begin
          FWake.WaitFor(200);
          Continue;
        end;
        if (J.Page < 0) or (J.Page >= Integer(Count)) or (J.Width < 8) then Continue;
        Bmp := nil;
        try
          Check(Doc.GetPage(J.Page, Page), 'Page');
          Check(CreateStreamOnHGlobal(0, True, Mem), 'Memory stream');
          Check(CreateRandomAccessStreamOverStream(Pointer(Mem), 0, IID_IRandomAccessStream, P), 'Stream');
          RA := IUnknown(P);
          IUnknown(P)._Release;
          ClassId := HStr('Windows.Data.Pdf.PdfPageRenderOptions');
          try
            Check(RoActivateInstance(ClassId, P), 'Render options');
          finally
            WindowsDeleteString(ClassId);
          end;
          Insp := IUnknown(P);
          IUnknown(P)._Release;
          Check(Insp.QueryInterface(IPdfPageRenderOptions, Opts), 'Render options');
          Check(Opts.put_DestinationWidth(J.Width), 'Width');
          Check(Opts.put_DestinationHeight(Round(J.Width * Sizes[J.Page].H / Sizes[J.Page].W)), 'Height');
          Opts.put_BitmapEncoderId(BmpEncoderId);
          Check(Page.RenderWithOptionsToStreamAsync(Pointer(RA), Pointer(Opts), Act), 'Render');
          WaitAsync(Act, @Terminated);
          Check(Act.GetResults, 'Render');
          { the encoded page lies in the HGLOBAL of the memory stream }
          Check(GetHGlobalFromStream(Mem, HG), 'Memory');
          N := GlobalSize(HG);
          Data := nil;
          SetLength(Data, N);
          Ptr := GlobalLock(HG);
          if (Ptr <> nil) and (N > 0) then Move(Ptr^, Data[0], N);
          GlobalUnlock(HG);
          { the engine may render larger than asked: scale to the requested width }
          Bmp := ImageFromBytes(Data, Max(J.Width, Round(J.Width * Sizes[J.Page].H / Sizes[J.Page].W)));
        except
          on E: Exception do
            if Terminated then Break;
        end;
        Act := nil;
        Opts := nil;
        Insp := nil;
        RA := nil;
        Mem := nil;
        Page := nil;
        if Bmp = nil then Continue;
        FLock.Enter;
        try
          N := Length(FResults);
          SetLength(FResults, N + 1);
          FResults[N].Page := J.Page;
          FResults[N].Width := J.Width;
          FResults[N].Bitmap := Bmp;
        finally
          FLock.Leave;
        end;
      end;
end;

procedure TAuPdfRenderer.Execute;
var
  Initialized: Boolean;
begin
  Initialized := False;
  try
    if not LoadApi then raise Exception.Create('The Windows PDF engine is not available (Windows 10 or newer is needed)');
    Initialized := RoInitialize(RO_INIT_MULTITHREADED) >= 0;
    try
      Work;
    finally
      if Initialized then RoUninitialize;
    end;
  except
    on E: Exception do
    begin
      FError := E.Message;
      FLoaded := True;
    end;
  end;
end;

end.
