unit uReplayGainScan;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uReplayGainScan
  Author:    André Lubke
  Created:   2026 (split from uFormReplayGain / uReplayGainThread)

  The rules of a ReplayGain scan, without UI and without the scan thread:
    TRGScanResult / TRGResultStatus  one scanned track and what became of it
                                     (RGStatusText: its text in the results)
    TRGAlbumGroups                   the albums to scan: one list of file
                                     paths per album (owns the lists)
    LibraryAlbumGroups               all albums of the library
    SelectionAlbumGroups             the albums of selected tracks, each
                                     completed with its other library tracks
    RemoveAlbumsWithGain             "missing only": drops the albums whose
                                     tracks all have ReplayGain
    RGAlbumKey                       folder + album artist + album
    GainFromLoudness                 the gain of a measured loudness
  uFormReplayGain asks what to scan and shows the results; uReplayGainThread
  measures the loudness. Covered by Tests\TestReplayGainScan.pas.
  =============================================================================}

interface

uses
  Classes, SysUtils, Contnrs, uLibraryTypes, uLibraryManager;

type
  // What became of a track in a scan
  TRGResultStatus = (
    rsReadyToSave,      // analysed: its track and album gain can be saved
    rsTrackOnly,        // ---> AulumicNS: analysed, no album tag: its track gain can be saved
    rsAlbumIncomplete,  // analysed, but not every track of its album: not saved
    rsDecodeError,      // could not be decoded (unsupported or damaged)
    rsFileMissing,      // the file no longer exists
    rsDriveOffline      // its drive or network share cannot be reached
  );

  // ---> MOVED (phase 6a) from uFormReplayGain; StatusMsg (the shown text, also
  // compared to decide what is saved) became Status
  TRGScanResult = record
    FilePath : string;
    Album    : string;
    Title    : string;
    TrackGain: Double;
    TrackPeak: Double;
    AlbumGain: Double;
    AlbumPeak: Double;
    Status   : TRGResultStatus;
  end;
  PRGScanResult = ^TRGScanResult;

  { TRGAlbumGroups: the albums to scan, one TStringList of file paths per
    album. Owns the lists: they are freed with it or when deleted. }
  TRGAlbumGroups = class
  private
    FList: TObjectList;
    function GetCount: Integer;
    function GetGroup(AIndex: Integer): TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    // Adds AFiles (owned from now on)
    procedure Add(AFiles: TStringList);
    // Frees the group at AIndex
    procedure Delete(AIndex: Integer);
    property Count: Integer read GetCount;
    property Groups[AIndex: Integer]: TStringList read GetGroup; default;
  end;

// The text of a status in the results list
function RGStatusText(AStatus: TRGResultStatus): string;

// The album of a track for a scan: folder + album artist + album, trimmed and
// in lower case (as TLibraryManager.GetDistinctAlbumBuckets groups)
function RGAlbumKey(const ATrack: TTrackInfo): string;

// The ReplayGain of a measured loudness (EBU R128, LUFS): reference level
// -18 LUFS, so -18 - ALoudness, limited to -60..+24 dB. Silence (-70 LUFS
// and below) and an invalid value (NaN, infinite) give 0 dB.
function GainFromLoudness(ALoudness: Double): Double;

// All albums of the library. AMissingAlbums: the albums with a track
// without ReplayGain.
function LibraryAlbumGroups(AManager: TLibraryManager; out AMissingAlbums: Integer): TRGAlbumGroups;

// The albums of the selected tracks (each file once per album), every album
// completed with its other library tracks: an album gain must be measured
// over the whole album. ATrackCount: the files in all groups;
// AMissingAlbums: the albums with a track without ReplayGain. No groups when
// no track has a file path.
function SelectionAlbumGroups(AManager: TLibraryManager; ATracks: TTrackList;
  out ATrackCount, AMissingAlbums: Integer): TRGAlbumGroups;

// "Missing only": removes the albums whose tracks all have ReplayGain (in the
// library; a file outside the library counts as having it)
procedure RemoveAlbumsWithGain(AManager: TLibraryManager; AGroups: TRGAlbumGroups);

implementation

uses
  Math, uAppStrings;

const
  RG_REFERENCE_LUFS = -18.0;  // ReplayGain 2.0 reference level
  RG_SILENCE_LUFS   = -70.0;  // at or below: silent, gain 0 dB
  RG_MIN_GAIN_DB    = -60.0;
  RG_MAX_GAIN_DB    = 24.0;

{ TRGAlbumGroups }

constructor TRGAlbumGroups.Create;
begin
  inherited Create;
  FList := TObjectList.Create(True);
end;

destructor TRGAlbumGroups.Destroy;
begin
  FList.Free;
  inherited Destroy;
end;

function TRGAlbumGroups.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TRGAlbumGroups.GetGroup(AIndex: Integer): TStringList;
begin
  Result := TStringList(FList[AIndex]);
end;

procedure TRGAlbumGroups.Add(AFiles: TStringList);
begin
  FList.Add(AFiles);
end;

procedure TRGAlbumGroups.Delete(AIndex: Integer);
begin
  FList.Delete(AIndex);
end;

{ Rules }

function RGStatusText(AStatus: TRGResultStatus): string;
begin
  case AStatus of
    rsReadyToSave     : Result := STATUS_RG_READY_TO_SAVE;
    rsTrackOnly       : Result := STATUS_RG_TRACK_ONLY;
    rsAlbumIncomplete : Result := STATUS_RG_ALBUM_INCOMPLETE;
    rsDecodeError     : Result := STATUS_RG_DECODE_ERROR;
    rsFileMissing     : Result := STATUS_RG_FILE_MISSING;
    rsDriveOffline    : Result := STATUS_RG_DRIVE_OFFLINE;
  else
    Result := '';
  end;
end;

// ---> MOVED (phase 6a) from TfrmReplayGain.ExecuteExplicitSelectionScan
// (AlbumBucketKey), unchanged
function RGAlbumKey(const ATrack: TTrackInfo): string;
begin
  Result := LowerCase(Trim(ExtractFileDir(ATrack.FilePath)) + '|' +
                      Trim(ATrack.AlbumArtist) + '|' +
                      Trim(ATrack.Album));
end;

// ---> MOVED (phase 6a) from TReplayGainThread.Execute (the same rule for a
// track and an album), unchanged
function GainFromLoudness(ALoudness: Double): Double;
begin
  if (not IsNan(ALoudness)) and (not IsInfinite(ALoudness)) and (ALoudness > RG_SILENCE_LUFS) then
    Result := EnsureRange(RG_REFERENCE_LUFS - ALoudness, RG_MIN_GAIN_DB, RG_MAX_GAIN_DB)
  else
    Result := 0.0;
end;

function LibraryAlbumGroups(AManager: TLibraryManager; out AMissingAlbums: Integer): TRGAlbumGroups;
var
  Buckets: TList;
  I: Integer;
begin
  Result         := TRGAlbumGroups.Create;
  AMissingAlbums := 0;
  if not Assigned(AManager) then
    Exit;

  Buckets := nil;
  try
    try
      AManager.GetDistinctAlbumBuckets(Buckets, AMissingAlbums);
      if Assigned(Buckets) then
      begin
        // The lists move into Result, which frees them from now on
        for I := 0 to Buckets.Count - 1 do
        begin
          Result.Add(TStringList(Buckets[I]));
          Buckets[I] := nil;
        end;
      end;
    finally
      Buckets.Free;
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

// ---> MOVED (phase 6a) from TfrmReplayGain.ExecuteExplicitSelectionScan
// (unchanged; the fallback group for "no album key" was dropped: every track
// with a file path gets a key, so it could only ever be empty). The selected
// tracks grouped by album into AGroups, each album completed with its other
// library tracks; ATrackCount counts the files added.
procedure AddSelectionGroups(AManager: TLibraryManager; ATracks: TTrackList;
  AGroups: TRGAlbumGroups; var ATrackCount: Integer);
var
  DistinctAlbums: TStringList;
  FileList      : TStringList;
  LibTracks     : TTrackInfoArray;
  Track         : PTrackInfo;
  I, Idx        : Integer;
  AlbKey        : string;
begin
  DistinctAlbums := TStringList.Create;
  try
    DistinctAlbums.Sorted        := True;
    DistinctAlbums.Duplicates    := dupIgnore;
    DistinctAlbums.CaseSensitive := False;
    DistinctAlbums.UseLocale     := False; // internal lookup list (never displayed)

    // The selected tracks, grouped by album (each file once)
    for I := 0 to ATracks.Count - 1 do
    begin
      Track := ATracks[I];
      if (not Assigned(Track)) or (Track^.FilePath = '') then
        Continue;

      AlbKey := RGAlbumKey(Track^);
      Idx    := DistinctAlbums.IndexOf(AlbKey);
      if Idx < 0 then
      begin
        FileList := TStringList.Create;
        AGroups.Add(FileList);
        DistinctAlbums.AddObject(AlbKey, FileList);
      end
      else
        FileList := TStringList(DistinctAlbums.Objects[Idx]);

      if FileList.IndexOf(Track^.FilePath) < 0 then
      begin
        FileList.Add(Track^.FilePath);
        Inc(ATrackCount);
      end;
    end;

    // ---> AUDIT FIX: Complete every selected album with all its library
    // tracks. The album gain must be measured over the whole album; measured
    // over the selected tracks only, it was wrong (and differed from the
    // album gain of the tracks that were not selected).
    if DistinctAlbums.Count > 0 then
    begin
      // ---> CHANGED: A copy of the library instead of its lock
      LibTracks := AManager.SnapshotTracks;
      for I := 0 to High(LibTracks) do
      begin
        Track := @LibTracks[I];
        if Track^.FilePath = '' then
          Continue;

        Idx := DistinctAlbums.IndexOf(RGAlbumKey(Track^));
        if Idx < 0 then
          Continue;

        FileList := TStringList(DistinctAlbums.Objects[Idx]);
        if FileList.IndexOf(Track^.FilePath) < 0 then
        begin
          FileList.Add(Track^.FilePath);
          Inc(ATrackCount);
        end;
      end;
      LibTracks := nil;
    end;
  finally
    DistinctAlbums.Free;
  end;
end;

function SelectionAlbumGroups(AManager: TLibraryManager; ATracks: TTrackList;
  out ATrackCount, AMissingAlbums: Integer): TRGAlbumGroups;
var
  I: Integer;
begin
  Result         := TRGAlbumGroups.Create;
  ATrackCount    := 0;
  AMissingAlbums := 0;
  if (not Assigned(AManager)) or (not Assigned(ATracks)) then
    Exit;

  try
    AddSelectionGroups(AManager, ATracks, Result, ATrackCount);

    for I := 0 to Result.Count - 1 do
      if AManager.AnyTrackMissingReplayGain(Result[I]) then
        Inc(AMissingAlbums);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

procedure RemoveAlbumsWithGain(AManager: TLibraryManager; AGroups: TRGAlbumGroups);
var
  I: Integer;
begin
  if (not Assigned(AManager)) or (not Assigned(AGroups)) then
    Exit;
  for I := AGroups.Count - 1 downto 0 do
    if not AManager.AnyTrackMissingReplayGain(AGroups[I]) then
      AGroups.Delete(I);
end;

end.
