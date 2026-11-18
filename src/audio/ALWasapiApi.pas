unit ALWasapiApi;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALWasapiApi
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Windows Core Audio (WASAPI / MMDevice) declarations AulumicNS uses: COM
  interfaces with their GUIDs, error codes, the wave format records and the
  device property key. The method order of each COM interface must match
  Windows exactly.
  Used by ALOutputWasapi and ALAudioThread (playback) and ALAudioEngine (the
  device list).
  The declarations hold no strings (PWideChar stays PWideChar), and the record
  layouts are checked by Tests\TestPlayback (TTestNativeLayouts).
  ============================================================================}

interface

uses
  Windows;

const
  IID_IAudioClient:         TGUID = '{1CB9AD4C-DBFA-4c32-B178-C2F568A703B2}';
  IID_IAudioRenderClient:   TGUID = '{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}';
  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  IID_IMMDeviceEnumerator:  TGUID = '{A95664D2-9614-4F35-A746-DE8DB63617E6}';
  STGM_READ = $00000000;

  PKEY_Device_FriendlyName_FMTID: TGUID = '{A45C254E-DF1C-4EFD-8020-67D146A850E0}';
  PKEY_Device_FriendlyName_PID: DWORD = 14;

  AUDCLNT_E_DEVICE_IN_USE = HRESULT($8889000A);
  AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED = HRESULT($8889000E);
  AUDCLNT_E_ENDPOINT_CREATE_FAILED = HRESULT($8889000F);
  AUDCLNT_E_UNSUPPORTED_FORMAT = HRESULT($88890008);
  AUDCLNT_E_DEVICE_INVALIDATED = HRESULT($88890004);
  AUDCLNT_E_BUFDURATION_PERIOD_NOT_ALIGNED = HRESULT($88890019);

  AUDCLNT_E_RESOURCES_INVALIDATED = HRESULT($88890026);

  DEVICE_STATE_ACTIVE = $00000001;

  E_ACCESSDENIED = HRESULT($80070005);
  E_INVALIDARG = HRESULT($80070057);
  E_FAIL = HRESULT($80004005);
  HRESULT_RESOURCE_IN_USE = HRESULT($800700AA);

  WAVE_FORMAT_EXTENSIBLE = $FFFE;
  KSDATAFORMAT_SUBTYPE_PCM: TGUID = '{00000001-0000-0010-8000-00AA00389B71}';

type
  WAVEFORMATEX = packed record
    wFormatTag, nChannels: word;
    nSamplesPerSec, nAvgBytesPerSec: DWORD;
    nBlockAlign, wBitsPerSample, cbSize: word;
  end;
  PWAVEFORMATEX = ^WAVEFORMATEX;

  WAVEFORMATEXTENSIBLE = packed record
    Format: WAVEFORMATEX;
    wValidBitsPerSample: word;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;

  TPropertyKey = record
    fmtid: TGUID;
    pid: DWORD;
  end;

  TPropVariant = packed record
    vt: word;
    wReserved1, wReserved2, wReserved3: word;
    case integer of
      0 : (bVal: byte);
      1 : (iVal: smallint);
      2 : (lVal: longint);
      3 : (fltVal: single);
      4 : (dblVal: double);
      5 : (boolVal: word);
      10: (punkVal: Pointer);
      13: (pwszVal: pwidechar);
      99: (Padding: array[0..15] of byte);
  end;

  IPropertyStore = interface(IUnknown)
    ['{886d8eeb-8cf2-4446-8d02-cdba1dbdcf99}']
    function GetCount(out cProps: DWORD): HRESULT; stdcall;
    function GetAt(iProp: DWORD; out pkey: TPropertyKey): HRESULT; stdcall;
    function GetValue(const key: TPropertyKey; out pv: TPropVariant): HRESULT; stdcall;
    function SetValue(const key: TPropertyKey; const propvar: TPropVariant): HRESULT; stdcall;
    function Commit: HRESULT; stdcall;
  end;

  IAudioClient = interface(IUnknown)
    ['{1CB9AD4C-DBFA-4c32-B178-C2F568A703B2}']
    function Initialize(ShareMode, StreamFlags: DWORD; hnsBufferDuration, hnsPeriodicity: int64; pFormat: PWAVEFORMATEX; AudioSessionGuid: PGUID): HRESULT; stdcall;
    function GetBufferSize(out pNumBufferFrames: uint32): HRESULT; stdcall;
    function GetStreamLatency(out phnsLatency: int64): HRESULT; stdcall;
    function GetCurrentPadding(out pNumPaddingFrames: uint32): HRESULT; stdcall;
    function IsFormatSupported(ShareMode: DWORD; pFormat: PWAVEFORMATEX; out ppClosestMatch: PWAVEFORMATEX): HRESULT; stdcall;
    function GetMixFormat(out ppDeviceFormat: PWAVEFORMATEX): HRESULT; stdcall;
    function GetDevicePeriod(out phnsDefaultDevicePeriod, phnsMinimumDevicePeriod: int64): HRESULT; stdcall;
    function Start: HRESULT; stdcall;
    function Stop: HRESULT; stdcall;
    function Reset: HRESULT; stdcall;
    function SetEventHandle(eventHandle: THandle): HRESULT; stdcall;
    function GetService(const riid: TGUID; out ppv: IUnknown): HRESULT; stdcall;
  end;

  IAudioRenderClient = interface(IUnknown)
    ['{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}']
    function GetBuffer(NumFramesRequested: uint32; out ppData: pbyte): HRESULT; stdcall;
    function ReleaseBuffer(NumFramesWritten: uint32; dwFlags: DWORD): HRESULT; stdcall;
  end;

  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD; pActivationParams: Pointer; out ppInterface: IUnknown): HRESULT; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out ppProperties: IPropertyStore): HRESULT; stdcall;
    function GetId(out ppstrId: pwidechar): HRESULT; stdcall;
    function GetState(out pdwState: DWORD): HRESULT; stdcall;
  end;

  IMMDeviceCollection = interface(IUnknown)
    ['{0BD7A1BE-7A1A-44DB-8397-CC5392387B5E}']
    function GetCount(out pcDevices: UINT): HRESULT; stdcall;
    function Item(nDevice: UINT; out ppDevice: IMMDevice): HRESULT; stdcall;
  end;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow, dwStateMask: DWORD; out ppDevices: IMMDeviceCollection): HRESULT; stdcall;
    function GetDefaultAudioEndpoint(dataFlow, role: DWORD; out ppEndpoint: IMMDevice): HRESULT; stdcall;
    function GetDevice(pwstrId: pwidechar; out ppDevice: IMMDevice): HRESULT; stdcall;
  end;

function PropVariantClear(var pvArg: TPropVariant): HRESULT; stdcall; external 'ole32.dll';

implementation

end.