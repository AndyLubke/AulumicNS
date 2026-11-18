unit ALAudioOutput;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALAudioOutput
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The output device as the play thread sees it (TPlayThread.RunOutput): an
  open stream that asks for whole buffers. The play thread fills them (read,
  track switch, DSP); the output only hands them to the device. Kept free of
  any device API, so other outputs (ASIO, ALSA) and a test output can be
  added beside TWasapiOutput (ALOutputWasapi).

  ---> CHANGED (step 2b): Open finds the device, chooses the format and
  starts the stream; it reports a failure by kind (TOutputOpenResult). The
  waits and retries for each kind are the play thread's (TPlayThread.
  RunOutput), the same for every output.

  ---> CHANGED (ObjFPC switch, step 1): ObjFPC like the rest of Aulumic: the
  device id and the error text are UTF-8 strings.
  ============================================================================}

interface

type
  // The format the device was opened with
  TAudioOutputFormat = record
    SampleRate : Cardinal;
    Channels   : Word;
    Bits       : Word;   // container bits per sample (16, 24, 32)
    ValidBits  : Word;   // valid bits (24 in a 32-bit container)
    BlockAlign : Word;   // bytes per frame (all channels)
  end;

  // ---> ADDED (step 2b): Open's answer. The play thread decides by the kind:
  // waits for a device that is not there yet (during a recovery), retries a
  // device in use, reports a format the device does not take. The two "lost"
  // kinds are handled differently (as before the split): lost while checking
  // the formats is retried only during a recovery; lost while starting the
  // stream is also retried three times like a device in use.
  TOutputOpenResult = (
    oorOK,
    oorEndpointFail,        // the device system itself could not be used
    oorNoDevice,            // the device is missing, not active or cannot be used now
    oorLostWhileChecking,   // the device went away while the formats were checked
    oorFormatUnsupported,   // the device takes none of the formats (rate / depth)
    oorInUse,               // another program uses the device
    oorLostWhileStarting,   // the device went away while the stream was started
    oorFailed               // anything else (AErrorText says what)
  );

  // WaitForBuffer's answer
  TOutputWait = (
    owBufferReady,  // the device wants the next buffer
    owStop,         // the stop event was set
    owTimeout,      // nothing within the time (a device that stopped asking)
    owFailed        // the wait itself failed (ignored, as before the split)
  );

  { TAudioOutput: an open output stream. Every buffer is BufferBytes long and
    is filled completely (the rest as silence) or released empty. Used only
    by the play thread. }
  TAudioOutput = class
  public
    // ---> ADDED (step 2b): Opens ADeviceId ('' = the default device; never
    // another one) for ARate / AChannels with the best bit depth it takes
    // (DoP: at least 24 bits) and a buffer of about ABufferMs, and prepares
    // the stream (not started). Not oorOK: AError = the device's error code
    // (for the log), AErrorText = the message for oorFormatUnsupported /
    // oorFailed (the message of EAudioEngineError). Closes a stream that is
    // still open first. ---> CHANGED (ObjFPC switch): both strings are UTF-8.
    function Open(const ADeviceId: string; ARate: Cardinal; AChannels: Word;
      AIsDoP: Boolean; ABufferMs: Integer; out AError: HRESULT;
      out AErrorText: string): TOutputOpenResult; virtual; abstract;

    function Format: TAudioOutputFormat; virtual; abstract;
    // Bytes of one buffer
    function BufferBytes: Integer; virtual; abstract;

    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    // Drops what the device has queued (before refilling after a seek)
    procedure Reset; virtual; abstract;

    // Waits until the device wants the next buffer or AStopEvent is set
    function WaitForBuffer(AStopEvent: THandle; ATimeoutMs: Cardinal): TOutputWait; virtual; abstract;
    // The next buffer to fill (BufferBytes). False: the device lost the
    // stream (AError = the device's error code, for the log): recover.
    function GetBuffer(out AData: PByte; out AError: HRESULT): Boolean; virtual; abstract;
    // Hands the buffer from GetBuffer to the device: AFull = all BufferBytes,
    // otherwise none of it (the buffer is dropped)
    procedure ReleaseBuffer(AFull: Boolean); virtual; abstract;

    // Stops the stream and releases the device; safe to call more than once
    procedure Close; virtual; abstract;

    // ---> AulumicNS: buffers the play thread fills before Start (WASAPI 1;
    // a ring - ASIO - a few, so the device does not start on one period).
    // They are got and released one after another, without WaitForBuffer.
    function PrefillBuffers: Integer; virtual;
    // ---> AulumicNS: True = at the end of the stream the play thread hands
    // over one buffer of silence before Drain (WASAPI plays a buffer it was
    // not given as whatever it still holds)
    function DrainTail: Boolean; virtual;
    // ---> AulumicNS: waits until what was handed over has played, or
    // AStopEvent: before Close at the end of the stream and before a reopen at
    // another rate (they cut the last buffers before)
    procedure Drain(AStopEvent: THandle); virtual;
    // ---> AulumicNS: before a Close in the middle of the music (a manual
    // switch to a track of another rate, Stop): the sound goes down to nothing
    // over a few milliseconds, where the output can do that at once (ASIO, PCM;
    // see TPeriodFade). The default does nothing.
    procedure FadeOut; virtual;
    // ---> AulumicNS: diagnostics for the log (TPlayThread.RunOutput): the
    // times the device found no buffer ready since Open (a dropout; ASIO:
    // counted by the ring, WASAPI: a buffer released after it should have
    // started playing) and the least audio that was ready ahead in ms.
    // -1 = the output cannot tell (the default; the test program's output).
    function DropoutCount: Integer; virtual;
    function LeastBufferedMs: Integer; virtual;
    // ---> AulumicNS: the audio the open stream holds ahead in ms (WASAPI:
    // its buffer, which Open may have made shorter than asked; ASIO: the
    // ring). -1 = not known.
    function BufferedMs: Integer; virtual;
  end;

  // ---> ADDED (output split, step 3a): Makes the output the play thread opens
  // (TPlayThread.OutputFactory). Called on the play thread for each open (a
  // rate switch or a recovery opens a new one); the play thread frees it.
  // Not set = TWasapiOutput. The test program sets it to a memory output.
  TAudioOutputFactory = function: TAudioOutput of object;

// ---> AulumicNS: microseconds of the performance counter (the output
// diagnostics and the play thread's time per buffer)
function OutputNowUs: Int64;

implementation

uses
  Windows;

var
  QpcFrequency: Int64 = 0;

function OutputNowUs: Int64;
var
  C: Int64;
begin
  if QpcFrequency = 0 then
    if not QueryPerformanceFrequency(QpcFrequency) or (QpcFrequency = 0) then
      QpcFrequency := 1000000;
  QueryPerformanceCounter(C);
  Result := (C div QpcFrequency) * 1000000 + ((C mod QpcFrequency) * 1000000) div QpcFrequency;
end;

function TAudioOutput.DropoutCount: Integer;
begin
  Result := -1;
end;

function TAudioOutput.LeastBufferedMs: Integer;
begin
  Result := -1;
end;

function TAudioOutput.BufferedMs: Integer;
begin
  Result := -1;
end;

function TAudioOutput.PrefillBuffers: Integer;
begin
  Result := 1;
end;

function TAudioOutput.DrainTail: Boolean;
begin
  Result := False;
end;

procedure TAudioOutput.FadeOut;
begin
end;

procedure TAudioOutput.Drain(AStopEvent: THandle);
begin
end;

end.
