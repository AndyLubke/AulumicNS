unit ALHeadroom;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - ALHeadroom
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Automatic headroom: what the play thread has learned about the peaks of the
  albums it played.

  A resampler rebuilds the waveform between the samples, and there a loud
  master goes above full scale (inter-sample peaks: +0.1 .. +2.4 dB measured,
  +4.3 dB in one case with an intermediate phase filter). DSD converted to
  PCM with the DSD gain does the same, and so does a ReplayGain gain without
  a peak tag. The play thread (TPlayThread.RunGain) measures the peak of every
  block before the gain and never lets the gain go above HEADROOM_CEILING /
  that peak. The highest peak of an album is kept here, so the album starts
  at the right level the next time: the level is the same for all its tracks.

  The key of an entry is the album (folder, album artist, album: the rule of
  the ReplayGain scan; a track without an album tag is keyed by its file,
  HeadroomAlbumKey) and the chain that made the peak (rates, resampler
  settings, DSD filter): another filter gives other peaks and learns its own
  value. The peak is the one before the gain (of full scale), so it holds for
  every volume, preamp and ReplayGain setting.

  The book is in memory; Save writes it as one small snapshot (uDbStore) when
  it has changed. The program saves it at a track change, at a stop and when
  it closes: a crash loses what was learned since, and that is learned again.
  A damaged file starts an empty book. Nothing is written to the music files.

  Threads: every method may be called from any thread (one lock; the play
  thread calls Known at a track change and Learn at a new highest peak, never
  Save).
  =============================================================================}

interface

uses
  Classes, SysUtils, fgl;

const
  { the level the highest peak is lowered to, of full scale (-0.009 dB): the
    last steps stay free for the dither and the rounding to the output format }
  HEADROOM_CEILING  = 0.999;
  { a peak above this (+24 dB) is not believed }
  HEADROOM_MAX_PEAK = 16.0;
  HEADROOM_FILE     = 'headroom.adb';

type
  THeadroomMap = specialize TFPGMap<string, Double>;

  { THeadroomBook }

  THeadroomBook = class
  private
    FLock: TRTLCriticalSection;
    FMap: THeadroomMap;
    FFile: string;
    FDirty: Boolean;
    FGeneration: QWord;
    function GetDirty: Boolean;
  public
    { AFile: the snapshot; '' = in memory only }
    constructor Create(const AFile: string);
    destructor Destroy; override;
    { reads the file. False with AError when it is damaged (the book is empty
      then); a missing file is no error }
    function Load(out AError: string): Boolean;
    { writes the file when the book has changed. False with AError when it
      could not be written (it stays changed) }
    function Save(out AError: string): Boolean;
    { the highest peak learned for AKey (of full scale); 0 = none }
    function Known(const AKey: string): Double;
    { a peak of AKey; True when it is higher than what was known }
    function Learn(const AKey: string; APeak: Double): Boolean;
    { forgets everything }
    procedure Clear;
    function Count: Integer;
    property Dirty: Boolean read GetDirty;
    property FileName: string read FFile;
  end;

{ the album of a file as the ReplayGain scan sees it (uReplayGainScan.
  RGAlbumKey): its folder, album artist and album. A file without an album
  tag is an album of its own (its path). }
function HeadroomAlbumKey(const AFileName, AAlbumArtist, AAlbum: string): string;
{ a gain factor in dB (0 for a factor of 1 and for nonsense) }
function FactorToDb(AFactor: Double): Double;

var
  { the program's book; nil = the peaks live only as long as a stream plays
    (the tests, the simulator) }
  HeadroomBook: THeadroomBook = nil;

implementation

uses
  Math, uDbStore;

const
  HEADROOM_MAGIC   = 'AUNSHEAD';
  HEADROOM_VERSION = 1;

function HeadroomAlbumKey(const AFileName, AAlbumArtist, AAlbum: string): string;
begin
  // no album tag: the track is its own album (the loose tracks of a folder
  // are no album: the loudest would set the level of all of them)
  if Trim(AAlbum) = '' then
    Result := LowerCase(Trim(AFileName)) + '||'
  else
    Result := LowerCase(Trim(ExtractFileDir(AFileName)) + '|' + Trim(AAlbumArtist) + '|' + Trim(AAlbum));
end;

function FactorToDb(AFactor: Double): Double;
begin
  if IsNan(AFactor) or IsInfinite(AFactor) or (AFactor <= 0.0) then
    Result := 0.0
  else
    Result := 20.0 * Log10(AFactor);
end;

function ValidPeak(APeak: Double): Boolean;
begin
  Result := (not IsNan(APeak)) and (not IsInfinite(APeak)) and (APeak > 0.0) and
            (APeak <= HEADROOM_MAX_PEAK);
end;

{ THeadroomBook }

constructor THeadroomBook.Create(const AFile: string);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FMap := THeadroomMap.Create;
  FMap.Sorted := True;
  FFile := AFile;
end;

destructor THeadroomBook.Destroy;
begin
  FMap.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function THeadroomBook.GetDirty: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDirty;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THeadroomBook.Count: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FMap.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THeadroomBook.Clear;
begin
  EnterCriticalSection(FLock);
  try
    if FMap.Count > 0 then
      FDirty := True;
    FMap.Clear;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THeadroomBook.Known(const AKey: string): Double;
var
  I: Integer;
begin
  Result := 0.0;
  if AKey = '' then
    Exit;
  EnterCriticalSection(FLock);
  try
    if FMap.Find(AKey, I) then
      Result := FMap.Data[I];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THeadroomBook.Learn(const AKey: string; APeak: Double): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (AKey = '') or not ValidPeak(APeak) then
    Exit;
  EnterCriticalSection(FLock);
  try
    if FMap.Find(AKey, I) then
    begin
      if APeak > FMap.Data[I] then
      begin
        FMap.Data[I] := APeak;
        Result := True;
      end;
    end
    else
    begin
      FMap.Add(AKey, APeak);
      Result := True;
    end;
    if Result then
      FDirty := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THeadroomBook.Load(out AError: string): Boolean;
var
  Body: TBytes;
  Gen: QWord;
  R: TDbReader;
  N, I: Integer;
  Key: string;
  Peak: Double;
begin
  AError := '';
  Result := True;
  if FFile = '' then
    Exit;
  Body := nil;
  EnterCriticalSection(FLock);
  try
    FMap.Clear;
    FDirty := False;
    FGeneration := 0;
    if not LoadSnapshot(FFile, HEADROOM_MAGIC, Gen, Body, AError) then
    begin
      // missing: no error, an empty book
      Result := AError = '';
      Exit;
    end;
    R := TDbReader.Create(Body);
    try
      try
        if R.U32 <> HEADROOM_VERSION then
          raise Exception.Create('Unknown version');
        N := R.Count(4 + 8);
        for I := 0 to N - 1 do
        begin
          Key  := R.Str;
          Peak := R.Dbl;
          if (Key <> '') and ValidPeak(Peak) then
            FMap[Key] := Peak;
        end;
        FGeneration := Gen;
      except
        on E: Exception do
        begin
          FMap.Clear;
          AError := E.Message;
          Result := False;
        end;
      end;
    finally
      R.Free;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THeadroomBook.Save(out AError: string): Boolean;
var
  W: TDbWriter;
  Body: TBytes;
  I: Integer;
  Gen: QWord;
begin
  AError := '';
  Result := True;
  if FFile = '' then
    Exit;
  Body := nil;
  // the body under the lock, the file outside it: the play thread never
  // waits for the disk
  EnterCriticalSection(FLock);
  try
    if not FDirty then
      Exit;
    W := TDbWriter.Create;
    try
      W.U32(HEADROOM_VERSION);
      W.U32(Cardinal(FMap.Count));
      for I := 0 to FMap.Count - 1 do
      begin
        W.Str(FMap.Keys[I]);
        W.Dbl(FMap.Data[I]);
      end;
      Body := W.Bytes;
    finally
      W.Free;
    end;
    Gen := FGeneration + 1;
    FDirty := False;
  finally
    LeaveCriticalSection(FLock);
  end;

  Result := SaveSnapshot(FFile, HEADROOM_MAGIC, Gen, Body, AError);

  EnterCriticalSection(FLock);
  try
    if Result then
      FGeneration := Gen
    else
      FDirty := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
