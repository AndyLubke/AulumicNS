{
This file is part of OvoTag
Copyright (C) 2011 Marco Caselli

OvoTag is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
}
{
  AulumicTag - modified for Aulumic by André Lubke, 2026.
  AulumicTag is a fork of OvoTag (C) 2011 Marco Caselli; see README.md.
  Changes:
    Data-safe saving: temporary file, flush to disk and atomic replacement
    (MoveFileExW); restricted Delete+Rename fallback; LastUpdateError and
    LoadFailed (no save when the existing tag could not be read); image stream
    handling fixes.
}

{$I ovotag.inc}
unit basetag;

interface

uses
  Classes, SysUtils, contnrs;

type
  TMediaProperty = record
    BitRate: Integer;
    BPM: Integer;
    Sampling: Integer;
    ChannelMode: string;
    BitDepth: Integer;
    Channels: Integer;
  end;

  TIDFields = (idAlbum, idAlbumArtist, idArtist, idComment, idGenre,
    idTitle, idTrack, idYear);
  TIDFieldsSet = set of TIDFields;

  { TCommonTags }
  TCommonTags = record
    Index: integer;
    ID: integer;
    FileName: string;
    Album: string;
    AlbumArtist: string;
    Artist: string;
    Comment: string;
    Duration: Int64;
    Genre: string;
    Title: string;
    Track: Dword;
    TrackString: string;
    Year: string;
    HasImage: boolean;
  end;

  ACommonTags = array of TCommonTags;

  operator = (const t1, t2: TCommonTags) b: boolean;

type

  { TFrameElement }
  TFrameElementClass = class of TFrameElement;
  TTags = class;

  TFrameElement = class
  private
    fId: string;
  protected
    function GetSize: DWord; virtual;
    function GetID: string; virtual;
    procedure SetID(AValue: string);
    function GetAsString: string; virtual; abstract;
    procedure SetAsString(const AValue: string); virtual; abstract;
  public
    Tagger: TTags;
    constructor Create; virtual; overload;
    constructor Create(ID: string); virtual; overload;
    destructor Destroy; override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; virtual; abstract;
    function WriteToStream(AStream: TStream): DWord; virtual; abstract;
  public
    property Size: DWord read GetSize;
    property ID: string read GetID write SetID;
    property AsString: string read GetAsString write SetAsString;
  end;

  { TImageElement }

  TImageElement = class(TFrameElement)
  private
    FFrameRef: TFrameElement;
    FImage: TStream;
    procedure SetFrameRef(AValue: TFrameElement);
    procedure SetImage(AValue: TStream);
  protected
    function GetAsString: string; override;
    procedure SetAsString(const AValue: string); override;
  public
    Description: string;
    MIMEType: string;
    PictureType: Integer;

    constructor Create; override;
    destructor Destroy; override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; override;
    function WriteToStream(AStream: TStream): DWord; override;
    property FrameRef: TFrameElement read FFrameRef write SetFrameRef;
    property Image: TStream read FImage write SetImage;
  end;

  { TTags }

  TTags = class
  private
    FramesList: TFPObjectList;
    ImagesList: TFPObjectList;
    function GetCount: integer;
    function GetFrameByID(ID: string): TFrameElement;
    function GetFrameByIndex(Index: integer): TFrameElement;
    function GetImageByID(ID: string): TImageElement;
    function GetImageByIndex(Index: integer): TImageElement;
    function GetImageCount: integer;
  protected
    function GetCommonTags: TCommonTags; virtual;
    procedure SetCommonTags(const CommonTags: TCommonTags); virtual;
  public
    constructor Create; virtual;
    destructor Destroy; override;
    function ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean; virtual; abstract;
    function WriteToStream(AStream: TStream): DWord; virtual; abstract;
    procedure Add(Frame: TFrameElement);
    procedure Remove(Frame: TFrameElement);
    procedure AddImage(Image: TImageElement);
    procedure Clear;
    function GetFrameValue(const ID: string): string;
    procedure SetFrameValue(const ID: string; const Value: string; FrameClass: TFrameElementClass);
  public
    property Count: integer read GetCount;
    property ImageCount: integer read GetImageCount;
    property Frames[Index: integer]: TFrameElement read GetFrameByIndex;
    property FramesByID[ID: string]: TFrameElement read GetFrameByID; default;
    property Images[Index: integer]: TImageElement read GetImageByIndex;
    property ImagesByID[ID: string]: TImageElement read GetImageByID;
    procedure ClearImages;
  end;

  { TTagReader }
  TTagReaderClass = class of TTagReader;

  TTagReader = class
  private
    FFileName: string;
  protected
    // Human-readable reason why the last UpdateFile failed
    // ('' after success), so callers can report skipped files.
    FLastUpdateError: string;
    // True when the file could not be read when this reader was
    // created (LoadFromFile returned False). UpdateFile then refuses to save:
    // the tag in memory is empty or incomplete, and saving would replace the
    // existing tag (including pictures) by it.
    FLoadFailed: boolean;
    // read with TagReadTextOnly: the pictures were left in
    // the file, the tag in memory is incomplete. UpdateFile refuses to save.
    FTextOnly: boolean;
  protected
    function GetTags: TTags; virtual; abstract;
    function GetDuration: Int64; virtual;
    function DumpInfo: TMediaProperty; virtual;
  public
    constructor Create(const FileName: TfileName); overload;
    constructor Create; overload;
    destructor Destroy; override;
    function GetCommonTags: TCommonTags;
    procedure SetCommonTags(CommonTags: TCommonTags);
    function LoadFromFile(const AFileName: Tfilename): boolean; virtual;
    function SaveToFile(const AFileName: Tfilename): boolean; virtual;
    function UpdateFile: boolean; virtual;
    function isUpdateable: boolean; virtual;
  public
    property FileName: string read FFileName;
    property Tags: TTags read GetTags;
    property Duration: int64 read GetDuration;
    property MediaProperty: TMediaProperty read DumpInfo;
    property LastUpdateError: string read FLastUpdateError;
    property LoadFailed: boolean read FLoadFailed;
    property TextOnly: boolean read FTextOnly;
  end;

// True while a reader is created that shall read the text
// fields only: embedded pictures are skipped, not loaded (a cover of several
// MB for a reader that only wants the album name or the ReplayGain values).
// Set through audiotag.GetFileTagsObject(FileName, True), never directly.
// Per thread. FLAC (picture blocks) and ID3v2 (APIC / PIC frames: WAV, DSF,
// DFF, MP3) follow it; the other formats always load their pictures.
// Such a reader cannot save (TTagReader.TextOnly).
threadvar
  TagReadTextOnly: boolean;
  // True while a reader is created that shall repair a damaged ID3v2 tag:
  // reading goes on behind damaged bytes (see TID3Tags.Recovered), and such a
  // reader may save. Set through audiotag.GetFileTagsObject, never directly.
  TagReadRecover: boolean;

function GetTagByID(const Tags: TcommonTags; Field: TIDFields): string; inline;
procedure SetTagByID(var Tags: TcommonTags; Field: TIDFields; const Value: string); inline;
function ExportToJson(const Tags: TcommonTags): string;

implementation

uses
  fpjson{$IFDEF WINDOWS}, Windows{$ENDIF},
  AuAudioTypes;   // LongPath (paths of 260 characters and more)

operator = (const t1, t2: TCommonTags) b: boolean;
begin
  Result := (t1.ID          = t2.ID) and
            (t1.FileName    = t2.FileName) and
            (t1.TrackString = t2.TrackString) and
            (t1.Track       = t2.Track) and
            (t1.Title       = t2.Title) and
            (t1.Album       = t2.Album) and
            (t1.Comment     = t2.Comment) and
            (t1.AlbumArtist = t2.AlbumArtist) and
            (t1.Artist      = t2.Artist) and
            (t1.Genre       = t2.Genre) and
            (t1.Year        = t2.Year) and
            (t1.Duration    = t2.Duration);
end;

function GetTagByID(const Tags: TcommonTags; Field: TIDFields): string;
begin
  case Field of
    idAlbum       : Result := Tags.Album;
    idAlbumArtist : Result := Tags.AlbumArtist;
    idArtist      : Result := Tags.Artist;
    idComment     : Result := Tags.Comment;
    idGenre       : Result := Tags.Genre;
    idTitle       : Result := Tags.Title;
    idTrack       : Result := Tags.TrackString;
    idYear        : Result := Tags.Year;
  else
    Result := '';
  end;
end;

procedure SetTagByID(var Tags: TcommonTags; Field: TIDFields; const Value: string);
begin
  case Field of
    idAlbum       : Tags.Album       := Value;
    idAlbumArtist : Tags.AlbumArtist := Value;
    idArtist      : Tags.Artist      := Value;
    idComment     : Tags.Comment     := Value;
    idGenre       : Tags.Genre       := Value;
    idTitle       : Tags.Title       := Value;
    idTrack       : Tags.TrackString := Value;
    idYear        : Tags.Year        := Value;
  end;
end;

function ExportToJson(const Tags: TcommonTags): string;
var
  FsongObj: TJSONObject;
begin
  FsongObj := TJSONObject.Create;
  try
    FsongObj.Add('Title', Tags.Title);
    FsongObj.Add('Album', Tags.Album);
    FsongObj.Add('AlbumArtist', Tags.AlbumArtist);
    FsongObj.Add('Artist', Tags.Artist);
    FsongObj.Add('Comment', Tags.Comment);
    FsongObj.Add('Duration', Tags.Duration);
    FsongObj.Add('Genre', Tags.Genre);
    FsongObj.Add('TrackString', Tags.TrackString);
    FsongObj.Add('Year', Tags.Year);
    Result := FsongObj.AsJSON;
  finally
    FsongObj.Free;
  end;
end;

{ TImageElement }

procedure TImageElement.SetFrameRef(AValue: TFrameElement);
begin
  if FFrameRef = AValue then
    Exit;
  FFrameRef := AValue;
end;

// Free the existing FImage stream before assigning AValue
procedure TImageElement.SetImage(AValue: TStream);
begin
  if FImage = AValue then
    Exit;
  FreeAndNil(FImage);
  FImage := AValue;
end;

function TImageElement.GetAsString: string;
begin
  Result := '';
end;

procedure TImageElement.SetAsString(const AValue: string);
begin
end;

function TImageElement.ReadFromStream(AStream: TStream; ExtInfo: pointer = nil): boolean;
begin
  Result := False;
end;

function TImageElement.WriteToStream(AStream: TStream): DWord;
begin
  Result := 0;
end;

constructor TImageElement.Create;
begin
  inherited Create;
  FImage := TMemoryStream.Create;
end;

destructor TImageElement.Destroy;
begin
  FreeAndNil(FImage);
  inherited Destroy;
end;

{ TTagReader }

function TTagReader.GetDuration: Int64;
begin
  Result := 0;
end;

constructor TTagReader.Create(const FileName: TfileName);
begin
  inherited Create;
  FFileName := FileName;
  FTextOnly := TagReadTextOnly;
  // Remember whether the existing tag could be read
  if FileExists(LongPath(FileName)) then
    FLoadFailed := not LoadFromFile(FileName)
  else
    FLoadFailed := True;
end;

constructor TTagReader.Create;
begin
  inherited Create;
end;

destructor TTagReader.Destroy;
var
  tmptags: TTags;
begin
  tmptags := GetTags;
  if Assigned(tmptags) then
  begin
    tmptags.Free;
  end;

  inherited Destroy;
end;

function TTagReader.DumpInfo: TMediaProperty;
begin
  Result := Default(TMediaProperty);
end;

function TTagReader.GetCommonTags: TCommonTags;
begin
  if Assigned(Tags) then
    Result := Tags.GetCommonTags
  else
    Result := Default(TCommonTags);

  Result.FileName := FFileName;
  Result.Duration := GetDuration;
  if Result.Title = '' then
    Result.Title := ChangeFileExt(ExtractFileName(FFileName), '');
end;

procedure TTagReader.SetCommonTags(CommonTags: TCommonTags);
begin
  if Assigned(Tags) then
    Tags.SetCommonTags(CommonTags);
end;

function TTagReader.LoadFromFile(const AFileName: Tfilename): boolean;
begin
  FFileName := AFileName;
  Result    := False;
end;

function TTagReader.SaveToFile(const AFileName: Tfilename): boolean;
begin
  Result := False;
end;

// =============================================================================
// DATA-SAFE ATOMIC FILE UPDATER
// Uses MoveFileExW(MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) on
// Windows so the original file is replaced atomically without a Delete-then-Rename
// gap! Retries if a background scanner briefly holds the file open.
// =============================================================================
function TTagReader.UpdateFile: boolean;
{$IFDEF WINDOWS}
const
  // Explicitly declare Win32 MoveFileExW flags missing from FPC's Windows unit
  MOVEFILE_REPLACE_EXISTING = $00000001;
  MOVEFILE_WRITE_THROUGH    = $00000008;
  // FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE
  AL_FILE_SHARE_ALL         = $00000007;
  AL_ERROR_ACCESS_DENIED     = 5;
  AL_ERROR_SHARING_VIOLATION = 32;
  AL_ERROR_LOCK_VIOLATION    = 33;
  // MoveFileExW not supported by the file system (some NAS / network shares)
  AL_ERROR_INVALID_FUNCTION  = 1;
  AL_ERROR_NOT_SUPPORTED     = 50;
  AL_ERROR_INVALID_PARAMETER = 87;
  // A virus scanner or the search indexer often opens a freshly
  // written file for a moment (longer for multi-GB DSF files). Retry such
  // transient sharing errors for up to ~3 s instead of giving up at once.
  TRANSIENT_RETRIES         = 30;
  TRANSIENT_DELAY_MS        = 100;
{$ENDIF}
var
  SaveFile: string;
  // the \\?\ forms of FileName and SaveFile for the file
  // calls (a path of 260 characters and more; the temporary name is longer
  // than the file's). SaveToFile takes SaveFile and does the same itself.
  LName, LSave: string;
  // True once the original file was deleted by the fallback.
  // From then on the temporary file may be the only copy and is never deleted.
  OriginalDeleted: boolean;
  // The Delete + Rename fallback is only allowed when replacing
  // is not supported at all, never after 'file in use' errors
  AllowFallback: boolean;
  {$IFDEF WINDOWS}
  WideSave, WideTarget: UnicodeString;
  HFlush: THandle;
  Attempt: Integer;
  Err: DWORD;

  function IsTransient(AErr: DWORD): boolean;
  begin
    Result := (AErr = AL_ERROR_SHARING_VIOLATION) or
              (AErr = AL_ERROR_LOCK_VIOLATION) or
              (AErr = AL_ERROR_ACCESS_DENIED);
  end;
  {$ENDIF}
var
  Flushed: boolean;
begin
  SaveFile         := ChangeFileExt(FileName, '.~.' + ExtractFileExt(FileName));
  LName            := LongPath(FileName);
  LSave            := LongPath(SaveFile);
  Result           := False;
  FLastUpdateError := '';
  OriginalDeleted  := False;
  AllowFallback    := False;

  // Never save when the existing tag could not be read: the tag
  // in memory would replace the complete existing tag (fields and pictures)
  if FLoadFailed then
  begin
    FLastUpdateError := 'the existing tag could not be read, so saving would lose it';
    Exit(False);
  end;
  // a reader without the pictures would save a tag without them
  if FTextOnly then
  begin
    FLastUpdateError := 'the tag was read without its pictures, so saving would lose them';
    Exit(False);
  end;

  try
    Result := SaveToFile(SaveFile);

    if not Result then
      FLastUpdateError := 'the tag could not be written safely (the existing tag ' +
                          'contains data that would be lost, or the file is damaged)';

    if Result then
    begin
      {$IFDEF WINDOWS}
      WideSave   := UTF8Decode(LSave);
      WideTarget := UTF8Decode(LName);

      // MOVEFILE_WRITE_THROUGH only makes the rename durable, not
      // the new file's contents. Flush the rebuilt file to disk first so a power
      // loss can never leave the audio file replaced by an unwritten one.
      // Full sharing, so a scanner that has the file open does not block us.
      Flushed := False;
      Err     := 0;
      for Attempt := 1 to TRANSIENT_RETRIES do
      begin
        HFlush := Windows.CreateFileW(PWideChar(WideSave), GENERIC_WRITE,
                                      AL_FILE_SHARE_ALL, nil, OPEN_EXISTING,
                                      FILE_ATTRIBUTE_NORMAL, 0);
        if HFlush <> INVALID_HANDLE_VALUE then
        begin
          Flushed := Windows.FlushFileBuffers(HFlush);
          if not Flushed then
            Err := Windows.GetLastError;
          Windows.CloseHandle(HFlush);
          Break;
        end;
        Err := Windows.GetLastError;
        if not IsTransient(Err) then
          Break;
        Sleep(TRANSIENT_DELAY_MS);
      end;

      if not Flushed then
        FLastUpdateError := Format('the new file could not be flushed to disk (Windows error %d)', [Err]);

      // Not flushed: leave the original file untouched (the finally block
      // removes the temp file because the original still exists)
      Result := False;
      if Flushed then
      begin
        for Attempt := 1 to TRANSIENT_RETRIES do
        begin
          Result := Windows.MoveFileExW(
                      PWideChar(WideSave),
                      PWideChar(WideTarget),
                      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH
                    );
          if Result then
            Break;
          Err := Windows.GetLastError;
          if not IsTransient(Err) then
            Break;
          Sleep(TRANSIENT_DELAY_MS);
        end;

        if not Result then
        begin
          FLastUpdateError := Format('the original file could not be replaced; ' +
                              'it may be in use by another program (Windows error %d)', [Err]);
          // Only fall back to Delete + Rename when the file system
          // does not support replacing. After 'in use' errors the original is
          // kept: deleting a file another program holds open can leave it
          // 'delete pending' (FAT / exFAT / network), so the rename fails and
          // the original disappears later.
          AllowFallback := (Err = AL_ERROR_INVALID_FUNCTION) or
                           (Err = AL_ERROR_NOT_SUPPORTED) or
                           (Err = AL_ERROR_INVALID_PARAMETER);
        end;
      end;
      {$ELSE}
      Flushed       := True;
      Result        := False;
      AllowFallback := True;
      {$ENDIF}

      // Fallback if MoveFileExW is unsupported by a network/NAS filesystem
      if (not Result) and Flushed and AllowFallback then
      begin
        Result := SysUtils.DeleteFile(LName);
        if Result then
        begin
          OriginalDeleted := True;
          Result := SysUtils.RenameFile(LSave, LName);
          if not Result then
          begin
            Sleep(25);
            Result := SysUtils.RenameFile(LSave, LName);
          end;
        end;
      end;

      if Result then
        FLastUpdateError := '';
    end;
  finally
    // CRITICAL: Only delete the temporary SaveFile while the original was never
    // deleted and still exists on disk! If DeleteFile(FileName) succeeded and
    // RenameFile failed, SaveFile is the ONLY surviving copy of the user's audio
    // track (the original may still be visible as 'delete pending').
    if (not OriginalDeleted) and FileExists(LName) and FileExists(LSave) then
    begin
      SysUtils.DeleteFile(LSave);
    end;
  end;
end;

function TTagReader.isUpdateable: boolean;
begin
  Result := False;
end;

{ TTags }

function TTags.GetFrameByID(ID: string): TFrameElement;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FramesList.Count - 1 do
  begin
    if AnsiCompareText(TFrameElement(FramesList[i]).ID, ID) = 0 then
    begin
      Result := GetFrameByIndex(i);
      Exit;
    end;
  end;
end;

function TTags.GetImageCount: integer;
begin
  Result := ImagesList.Count;
end;

function TTags.GetCount: integer;
begin
  Result := FramesList.Count;
end;

function TTags.GetFrameByIndex(Index: integer): TFrameElement;
begin
  if (Index >= 0) and (Index < FramesList.Count) then
    Result := TFrameElement(FramesList[Index])
  else
    Result := nil;
end;

function TTags.GetImageByID(ID: string): TImageElement;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to ImagesList.Count - 1 do
  begin
    if AnsiCompareText(TImageElement(ImagesList[i]).ID, ID) = 0 then
    begin
      Result := GetImageByIndex(i);
      Exit;
    end;
  end;
end;

function TTags.GetImageByIndex(Index: integer): TImageElement;
begin
  if (Index >= 0) and (Index < ImagesList.Count) then
    Result := TImageElement(ImagesList[Index])
  else
    Result := nil;
end;

constructor TTags.Create;
begin
  inherited Create;
  FramesList := TFPObjectList.Create(True);
  ImagesList := TFPObjectList.Create(True);
end;

destructor TTags.Destroy;
begin
  FreeAndNil(FramesList);
  FreeAndNil(ImagesList);
  inherited Destroy;
end;

procedure TTags.Add(Frame: TFrameElement);
begin
  if Assigned(Frame) then
    FramesList.Add(Frame);
end;

procedure TTags.Remove(Frame: TFrameElement);
begin
  if Assigned(Frame) then
    FramesList.Remove(Frame);
end;

procedure TTags.AddImage(Image: TImageElement);
begin
  if Assigned(Image) then
    ImagesList.Add(Image);
end;

procedure TTags.Clear;
begin
  FramesList.Clear;
  ImagesList.Clear;
end;

function TTags.GetCommonTags: TCommonTags;
begin
  Result    := Default(TCommonTags);
  Result.ID := -1;
end;

procedure TTags.SetCommonTags(const CommonTags: TCommonTags);
begin
end;

procedure TTags.SetFrameValue(const ID: string; const Value: string; FrameClass: TFrameElementClass);
var
  Element: TFrameElement;
begin
  // If the value is empty, loop and purge ALL matching frames!
  if Trim(Value) = '' then
  begin
    Element := FramesByID[ID];
    while Assigned(Element) do
    begin
      Self.Remove(Element);
      Element := FramesByID[ID];
    end;
    Exit;
  end;

  Element := FramesByID[ID];
  if Element = nil then
  begin
    if not Assigned(FrameClass) then
      Exit;
    Element        := FrameClass.Create(ID);
    Element.Tagger := Self;
    Add(Element);
  end;

  Element.AsString := Value;
end;

procedure TTags.ClearImages;
begin
  ImagesList.Clear;
end;

function TTags.GetFrameValue(const ID: string): string;
var
  Element: TFrameElement;
begin
  Element := FramesByID[ID];
  if Element = nil then
    Result := ''
  else
    Result := Element.AsString;
end;

{ TFrameElement }

procedure TFrameElement.SetID(AValue: string);
begin
  if fId <> AValue then
    fId := AValue;
end;

function TFrameElement.GetSize: DWord;
begin
  Result := 0;
end;

function TFrameElement.GetID: string;
begin
  Result := fId;
end;

constructor TFrameElement.Create;
begin
  inherited Create;
end;

constructor TFrameElement.Create(ID: string);
begin
  inherited Create;
  fId := ID;
end;

destructor TFrameElement.Destroy;
begin
  inherited Destroy;
end;

end.
