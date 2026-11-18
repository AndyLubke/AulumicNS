unit uMetaUtils;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS - uMetaUtils
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  Helper utils for handling metadata
  =============================================================================}

interface

uses
  Classes, SysUtils, ALMetadata;

// Returns a clean array of items (perfect for your UI layout math)
function SplitTags(const RawTags: string): TStringArray;

function StripAccents(const S: string): string;

// Returns a single formatted string (perfect for standard labels)
function FormatTagString(const RawTags: string; MaxItems: Integer = 0;
  const Separator: string = ' • '): string;

function NormalizeSemicolons(const S: string): string;

// Finds coverart: First in metadata else in file
function FindCoverArt(const APath: string): string;

// Collects all cover/artwork images in the track's folder and subfolders
procedure FindAllCoverArt(const APath: string; AList: TStrings);

// The PDF booklets of an album folder:
// the folder, its sub folders (Scans, Artwork, ...) and the parent of a disc
// folder (CD1, Disc 2). Plain file access (the playback IO worker uses it).
procedure FindBooklets(const Folder: string; List: TStrings);

function GenerateAlbumHash(const AlbumArtist, Album, FolderPath: string): string;

procedure ClearThumbnailCache;

// AForce: replace an existing thumbnail (the cover may have changed); when no
// cover can be read, an existing thumbnail is kept
procedure GenerateAndCacheThumbnail(var Meta: TAudioMetadata;
  const FilePath, DestHashFilename: string; AForce: Boolean = False);

// Returns True ONLY if AFilePath decoded cleanly and is verified as a valid JPEG on disk.
function DownscaleImageFile(const AFilePath: string; MaxDim: Integer): Boolean;

// ReplayGain Tag Extractor
function ExtractReplayGain(const AllTags, TargetKeys: string): double;

implementation

uses
  AuAudioTypes, LCLIntf, Math, StrUtils, uAppStrings, uAppConsts, md5, uOSUtils, AuGfx;

const

  // Expandable localization tokens for featured artists.
  FEAT_TOKENS: array[0..5] of string = (
    ' feat. ', ' ft. ', ' featuring ', // English
    ' met ',                           // Dutch
    ' avec ',                          // French
    ' con '                            // Spanish / Italian
  );

// Checks if a file on disk already has a valid JPEG header ($FF $D8 $FF)
function IsFileAlreadyJPEG(const AFilePath: string): Boolean;
var
  FS: TFileStream;
  Sig: array[0..2] of Byte;
begin
  Result := False;
  if (AFilePath = '') or (not FileExists(LongPath(AFilePath))) then
    Exit;

  try
    FS := TFileStream.Create(LongPath(AFilePath), fmOpenRead or fmShareDenyNone);
    try
      Sig[0] := 0;
      Sig[1] := 0;
      Sig[2] := 0;
      if FS.Read(Sig[0], 3) = 3 then
        Result := (Sig[0] = $FF) and (Sig[1] = $D8) and (Sig[2] = $FF);
    finally
      FS.Free;
    end;
  except
    Result := False;
  end;
end;

// Splits tags with multiple entries to a string array
function SplitTags(const RawTags: string): TStringArray;
var
  RawParts: TStringArray;
  I, ValidCount: Integer;
  S, Token: string;
begin
  // Initialize managed Result to nil to silence Warning 5093
  Result := nil;
  if Trim(RawTags) = '' then
    Exit;

  // 1. Standardize basic punctuation separators to semicolons
  S := StringReplace(RawTags, '; ', ';', [rfReplaceAll]);
  S := StringReplace(S, ', ', ';', [rfReplaceAll]);

  // 2. Loop through our localized tokens and convert them to semicolons
  for Token in FEAT_TOKENS do
    S := StringReplace(S, Token, ';', [rfReplaceAll, rfIgnoreCase]);

  // 3. Perform the native split
  RawParts := S.Split([';']);

  SetLength(Result, Length(RawParts));
  ValidCount := 0;

  // 4. Clean and pack the array (preserving original tag capitalization)
  for I := 0 to High(RawParts) do
  begin
    S := Trim(RawParts[I]);
    if S <> '' then
    begin
      Result[ValidCount] := S;
      Inc(ValidCount);
    end;
  end;

  SetLength(Result, ValidCount);
end;

// Strips accents (used when searching by the user)
function StripAccents(const S: string): string;
var
  I, OutLen: Integer;
  HasAccents: Boolean;
  WS, OutWS: UnicodeString;
  C: Word;

  procedure AppendAscii(Ch: WideChar); inline;
  begin
    Inc(OutLen);
    OutWS[OutLen] := Ch;
  end;

  procedure AppendTwoAscii(Ch1, Ch2: WideChar); inline;
  begin
    Inc(OutLen);
    OutWS[OutLen] := Ch1;
    Inc(OutLen);
    OutWS[OutLen] := Ch2;
  end;

begin
  // Initialize OutWS to silence Hint 5057
  OutWS := '';
  if S = '' then
    Exit('');

  HasAccents := False;
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) > 127 then
    begin
      HasAccents := True;
      Break;
    end;
  end;

  if not HasAccents then
    Exit(S);

  WS := UnicodeString(S);
  SetLength(OutWS, Length(WS) * 2);
  OutLen := 0;

  for I := 1 to Length(WS) do
  begin
    C := Ord(WS[I]);
    case C of
      $00C0..$00C5, $0100, $0102, $0104: AppendAscii('A');
      $00C6:                             AppendTwoAscii('A', 'E');
      $00C7, $0106, $0108, $010A, $010C: AppendAscii('C');
      $010E, $0110, $00D0:               AppendAscii('D');
      $00C8..$00CB, $0112, $0114,
      $0116, $0118, $011A:               AppendAscii('E');
      $011C, $011E, $0120, $0122:        AppendAscii('G');
      $00CC..$00CF, $0128, $012A,
      $012C, $012E, $0130:               AppendAscii('I');
      $0139, $013B, $013D, $0141:        AppendAscii('L');
      $00D1, $0143, $0145, $0147:        AppendAscii('N');
      $00D2..$00D6, $00D8, $014C,
      $014E, $0150:                      AppendAscii('O');
      $0152:                             AppendTwoAscii('O', 'E');
      $0154, $0156, $0158:               AppendAscii('R');
      $015A, $015C, $015E, $0160:        AppendAscii('S');
      $0162, $0164, $0166:               AppendAscii('T');
      $00D9..$00DC, $0168, $016A,
      $016C, $016E, $0170, $0172:        AppendAscii('U');
      $00DD, $0176, $0178:               AppendAscii('Y');
      $0179, $017B, $017D:               AppendAscii('Z');

      $00DF:                             AppendTwoAscii('s', 's');
      $00E0..$00E5, $0101, $0103, $0105: AppendAscii('a');
      $00E6:                             AppendTwoAscii('a', 'e');
      $00E7, $0107, $0109, $010B, $010D: AppendAscii('c');
      $010F, $0111, $00F0:               AppendAscii('d');
      $00E8..$00EB, $0113, $0115,
      $0117, $0119, $011B:               AppendAscii('e');
      $011D, $011F, $0121, $0123:        AppendAscii('g');
      $00EC..$00EF, $0129, $012B,
      $012D, $012F, $0131:               AppendAscii('i');
      $013A, $013C, $013E, $0142:        AppendAscii('l');
      $00F1, $0144, $0146, $0148:        AppendAscii('n');
      $00F2..$00F6, $00F8, $014D,
      $014F, $0151:                      AppendAscii('o');
      $0153:                             AppendTwoAscii('o', 'e');
      $0155, $0157, $0159:               AppendAscii('r');
      $015B, $015D, $015F, $0161:        AppendAscii('s');
      $0163, $0165, $0167:               AppendAscii('t');
      $00F9..$00FC, $0169, $016B,
      $016D, $016F, $0171, $0173:        AppendAscii('u');
      $00FD, $00FF, $0177:               AppendAscii('y');
      $017A, $017C, $017E:               AppendAscii('z');
    else
      AppendAscii(WS[I]);
    end;
  end;

  SetLength(OutWS, OutLen);
  Result := String(OutWS);
end;

function FormatTagString(const RawTags: string; MaxItems: Integer = 0;
  const Separator: string = ' • '): string;
var
  Parts: TStringArray;
  I, StopIdx: Integer;
begin
  Result := '';
  Parts  := SplitTags(RawTags);

  if Length(Parts) = 0 then
    Exit;

  StopIdx := High(Parts);

  if (MaxItems > 0) and (MaxItems <= High(Parts)) then
    StopIdx := MaxItems - 1;

  Result := Parts[0];
  for I := 1 to StopIdx do
    Result := Result + Separator + Parts[I];
end;

function NormalizeSemicolons(const S: string): string;
var
  Parts: TStringArray;
  I: Integer;
  Cleaned: string;
begin
  Result := Trim(S);
  if Pos(';', Result) = 0 then
    Exit; // Fast exit for single artists

  Parts  := Result.Split([';']);
  Result := '';
  for I := 0 to High(Parts) do
  begin
    Cleaned := Trim(Parts[I]);
    if Cleaned <> '' then
    begin
      if Result = '' then
        Result := Cleaned
      else
        Result := Result + '; ' + Cleaned;
    end;
  end;
end;

// =============================================================================
// Shared helper to filter out 0-byte files, macOS '._' forks,
// and tiny Windows Media Player junk thumbnails (AlbumArtSmall.jpg).
// =============================================================================
function IsValidCoverFileEntry(const SR: TSearchRec): Boolean;
var
  LowerName, Ext: string;
begin
  Result := False;

  // Must not be a directory or symlink
  if (SR.Attr and (faDirectory or $00000400)) <> 0 then
    Exit;

  // No valid JPEG/PNG/BMP header can exist in less than 128 bytes
  if SR.Size < 128 then
    Exit;

  if (SR.Name = '') or (SR.Name = '.') or (SR.Name = '..') then
    Exit;

  // Skip macOS AppleDouble resource fork files (e.g. "._cover.jpg")
  if Pos('._', SR.Name) = 1 then
    Exit;

  LowerName := LowerCase(SR.Name);

  // Skip tiny low-res Windows Media Player auto-generated junk thumbnails
  if (LowerName = 'albumartsmall.jpg') or
     ((Pos('albumart_', LowerName) = 1) and (Pos('_small.jpg', LowerName) > 0)) then
    Exit;

  Ext    := ExtractFileExt(LowerName);
  Result := (Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.png') or (Ext = '.bmp');
end;

function FindCoverArt(const APath: string): string;
var
  BaseDir, Pattern, Candidate: string;
  I: Integer;
  SR: TSearchRec;
begin
  Result := '';
  if APath = '' then
    Exit;

  try
    BaseDir := IncludeTrailingPathDelimiter(ExtractFilePath(APath));
    if (BaseDir = '') or (not DirectoryExists(LongPath(BaseDir))) then
      Exit;

    for I := Low(COVER_ART_NAMES) to High(COVER_ART_NAMES) do
    begin
      Pattern := COVER_ART_NAMES[I];
      if (Pos('*', Pattern) > 0) or (Pos('?', Pattern) > 0) then
      begin
        try
          if FindFirst(LongPath(BaseDir + Pattern), faAnyFile, SR) = 0 then
          begin
            try
              repeat
                if IsValidCoverFileEntry(SR) then
                begin
                  Result := BaseDir + SR.Name;
                  Exit;
                end;
              until FindNext(SR) <> 0;
            finally
              SysUtils.FindClose(SR);
            end;
          end;
        except
          // Silently swallow OS/network errors on individual wildcard patterns
        end;
      end
      else
      begin
        Candidate := BaseDir + Pattern;
        try
          if FileExists(LongPath(Candidate)) then
          begin
            if FindFirst(LongPath(Candidate), faAnyFile, SR) = 0 then
            begin
              try
                if IsValidCoverFileEntry(SR) then
                begin
                  Result := Candidate;
                  Exit;
                end;
              finally
                SysUtils.FindClose(SR);
              end;
            end;
          end;
        except
          // Silently swallow OS/network errors
        end;
      end;
    end;
  except
    Result := '';
  end;
end;

// The PDFs of Dir and its sub folders, for FindBooklets
procedure AddBookletPdfs(const Dir: string; List: TStrings; Depth: Integer);
var
  SR: TSearchRec;
  Sub: TStringList;
  I: Integer;
  D: string;
begin
  D := IncludeTrailingPathDelimiter(Dir);
  Sub := TStringList.Create;
  try
    if FindFirst(LongPath(D + '*'), faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if SR.Attr and faDirectory <> 0 then Sub.Add(D + SR.Name)
        else if (LowerCase(ExtractFileExt(SR.Name)) = '.pdf') and (List.IndexOf(D + SR.Name) < 0) then
          List.Add(D + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    if Depth > 0 then
    begin
      Sub.Sort;
      for I := 0 to Sub.Count - 1 do AddBookletPdfs(Sub[I], List, Depth - 1);
    end;
  finally
    Sub.Free;
  end;
end;

procedure FindBooklets(const Folder: string; List: TStrings);
var
  F, Last, Up: string;
begin
  List.Clear;
  if (Folder = '') or not DirectoryExists(LongPath(Folder)) then Exit;
  F := ExcludeTrailingPathDelimiter(Folder);
  AddBookletPdfs(F, List, 1);
  { a disc folder (CD1, Disc 2): the album folder above }
  Last := LowerCase(ExtractFileName(F));
  if (Copy(Last, 1, 2) = 'cd') or (Copy(Last, 1, 4) = 'disc') or (Copy(Last, 1, 4) = 'disk') then
  begin
    Up := ExtractFileDir(F);
    if (Up <> '') and (Up <> F) then AddBookletPdfs(Up, List, 0);
  end;
end;

// =============================================================================
// Multi-page Cover / Booklet / Scans Discovery
// =============================================================================
procedure FindAllCoverArt(const APath: string; AList: TStrings);
const
  MAX_DISCOVERED_IMAGES = 100;
  MAX_SUBFOLDER_DEPTH   = 2;
  MAX_SUBDIRS_PER_LEVEL = 32;
  FA_SYMLINK_ATTR       = $00000400;
var
  BaseDir, CleanBase, PrimaryCover, FolderName, ParentDir, CleanParent: string;

  function IsAlreadyAdded(const AFullPath: string): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := 0 to AList.Count - 1 do
    begin
      if SameFileName(AList[I], AFullPath) then
        Exit(True);
    end;
  end;

  procedure AddImageUnique(const AFullPath: string);
  begin
    if (AFullPath = '') or (AList.Count >= MAX_DISCOVERED_IMAGES) then
      Exit;
    if not IsAlreadyAdded(AFullPath) then
      AList.Add(AFullPath);
  end;

  function IsDriveRoot(const ADir: string): Boolean;
  var
    Clean: string;
  begin
    Clean  := ExcludeTrailingPathDelimiter(Trim(ADir));
    Result := (Length(Clean) <= 3) and (Pos(':', Clean) > 0);
  end;

  function IsSafeSubfolder(const SR: TSearchRec): Boolean;
  var
    LowerDir: string;
  begin
    Result := False;
    if (SR.Name = '') or (SR.Name = '.') or (SR.Name = '..') then
      Exit;

    {$PUSH}{$WARN 5044 OFF} // faHidden / faSysFile: Windows-only (so is the program)
    if (SR.Attr and (faHidden or faSysFile or FA_SYMLINK_ATTR)) <> 0 then
    {$POP}
      Exit;

    if (SR.Name[1] = '.') or (SR.Name[1] = '$') then
      Exit;

    LowerDir := LowerCase(SR.Name);
    if (LowerDir = 'system volume information') or (LowerDir = 'recovery') then
      Exit;

    Result := True;
  end;

  function GetImageSortPriority(const AFileName: string): Integer;
  var
    LowerName: string;
  begin
    LowerName := LowerCase(ChangeFileExt(ExtractFileName(AFileName), ''));
    if (Pos('front', LowerName) = 1) or (Pos('cover', LowerName) = 1) or
       (Pos('folder', LowerName) = 1) then
      Result := 10
    else if (Pos('back', LowerName) = 1) or (Pos('rear', LowerName) = 1) or
            (Pos('inlay', LowerName) = 1) or (Pos('tray', LowerName) = 1) then
      Result := 20
    else if (Pos('disc', LowerName) = 1) or (Pos('cd', LowerName) = 1) or
            (Pos('vinyl', LowerName) = 1) or (Pos('media', LowerName) = 1) or
            (Pos('label', LowerName) = 1) then
      Result := 30
    else if (Pos('booklet', LowerName) = 1) or (Pos('page', LowerName) = 1) or
            (Pos('scan', LowerName) = 1) or (Pos('inside', LowerName) = 1) or
            (Pos('insert', LowerName) = 1) or (Pos('inner', LowerName) = 1) then
      Result := 40
    else
      Result := 50;
  end;

  function IsDiscSubfolderName(const ADirName: string): Boolean;
  var
    L: string;
  begin
    L := LowerCase(Trim(ADirName));
    Result := (Pos('cd', L) = 1) or (Pos('disc', L) = 1) or
              (Pos('disk', L) = 1) or (Pos('vol', L) = 1);
  end;

  procedure ScanDirectory(const ADir: string; Depth: Integer; SkipDiscSiblings: Boolean);
  var
    SR: TSearchRec;
    DirPath, Entry, FullPath: string;
    SortedFiles, SubDirs: TStringList;
    I, SepPos: Integer;
    AllowSubfolders: Boolean;
  begin
    if (ADir = '') or (Depth > MAX_SUBFOLDER_DEPTH) or
       (AList.Count >= MAX_DISCOVERED_IMAGES) then
      Exit;

    try
      DirPath := IncludeTrailingPathDelimiter(ADir);
      if not DirectoryExists(LongPath(DirPath)) then
        Exit;

      AllowSubfolders := (Depth < MAX_SUBFOLDER_DEPTH) and (not IsDriveRoot(DirPath));

      SortedFiles := TStringList.Create;
      SubDirs     := TStringList.Create;
      try
        try
          if FindFirst(LongPath(DirPath + '*'), faAnyFile, SR) = 0 then
          begin
            try
              repeat
                if (SR.Name = '.') or (SR.Name = '..') then
                  Continue;

                if (SR.Attr and faDirectory) <> 0 then
                begin
                  if AllowSubfolders and
                     (SubDirs.Count < MAX_SUBDIRS_PER_LEVEL) and
                     IsSafeSubfolder(SR) then
                  begin
                    if SkipDiscSiblings and IsDiscSubfolderName(SR.Name) then
                      Continue;
                    SubDirs.Add(DirPath + SR.Name);
                  end;
                end
                else if IsValidCoverFileEntry(SR) then
                begin
                  SortedFiles.Add(Format('%.2d|%s|%s',
                    [GetImageSortPriority(SR.Name), LowerCase(SR.Name), DirPath + SR.Name]));
                end;
              until FindNext(SR) <> 0;
            finally
              SysUtils.FindClose(SR);
            end;
          end;
        except
          // Silently ignore access-denied or I/O errors on this directory
        end;

        // 1. Add sorted images from current directory
        SortedFiles.Sort;
        for I := 0 to SortedFiles.Count - 1 do
        begin
          Entry  := SortedFiles[I];
          SepPos := Pos('|', Entry);
          if SepPos > 0 then
          begin
            Delete(Entry, 1, SepPos);
            SepPos := Pos('|', Entry);
            if SepPos > 0 then
            begin
              FullPath := Copy(Entry, SepPos + 1, MaxInt);
              AddImageUnique(FullPath);
            end;
          end;
        end;

        // 2. Recurse into valid subfolders (Artwork, Scans, Booklet, etc.)
        if AllowSubfolders then
        begin
          SubDirs.Sort;
          for I := 0 to SubDirs.Count - 1 do
          begin
            if AList.Count >= MAX_DISCOVERED_IMAGES then
              Break;
            ScanDirectory(SubDirs[I], Depth + 1, False);
          end;
        end;
      finally
        SubDirs.Free;
        SortedFiles.Free;
      end;
    except
      // Failsafe: never let a subfolder error abort the already collected list
    end;
  end;

begin
  if not Assigned(AList) then
    Exit;

  AList.Clear;
  if Trim(APath) = '' then
    Exit;

  try
    if DirectoryExists(LongPath(APath)) then
      BaseDir := IncludeTrailingPathDelimiter(APath)
    else
      BaseDir := IncludeTrailingPathDelimiter(ExtractFilePath(APath));

    if (BaseDir = '') or (not DirectoryExists(LongPath(BaseDir))) then
      Exit;

    // 1. Ensure the primary front cover is always first (Index 0)
    PrimaryCover := FindCoverArt(APath);
    if (PrimaryCover <> '') and FileExists(LongPath(PrimaryCover)) then
      AddImageUnique(PrimaryCover);

    // 2. Scan the track's own folder and its subfolders
    ScanDirectory(BaseDir, 0, False);

    // 3. Multi-disc support
    CleanBase  := ExcludeTrailingPathDelimiter(BaseDir);
    FolderName := ExtractFileName(CleanBase);
    if IsDiscSubfolderName(FolderName) then
    begin
      ParentDir   := ExtractFilePath(CleanBase);
      CleanParent := ExcludeTrailingPathDelimiter(ParentDir);
      if (CleanParent <> '') and
         (not SameFileName(CleanParent, CleanBase)) and
         (not IsDriveRoot(CleanParent)) then
      begin
        ScanDirectory(ParentDir, 1, True);
      end;
    end;
  except
    // Master failsafe: swallow any unexpected path parsing / OS error
  end;
end;

{ The banner draws Meta.CoverData / FolderCoverData with
  AuGfx.ImageFromBytes }

function GenerateAlbumHash(const AlbumArtist, Album, FolderPath: string): string;
var
  RawStr: string;
  NormalizedFolder: string;
begin
  RawStr := LowerCase(Trim(AlbumArtist) + '|' + Trim(Album));

  if (Trim(Album) = '') or SameText(Trim(Album), LBL_UNKNOWN_ALBUM) then
  begin
    NormalizedFolder := LowerCase(Trim(ExcludeTrailingPathDelimiter(FolderPath)));
    RawStr := RawStr + '|' + NormalizedFolder;
  end;

  if RawStr = '|' then
    Result := 'unknown_album'
  else
    Result := MDPrint(MD5String(RawStr));
end;

procedure ClearThumbnailCache;
var
  SR: TSearchRec;
begin
  if not DirectoryExists(LongPath(AppCacheThumbsDir)) then
    Exit;

  if FindFirst(LongPath(AppCacheThumbsDir + '*.jpg'), faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
        begin
          try
            SysUtils.DeleteFile(LongPath(AppCacheThumbsDir + SR.Name));
          except
            // Skip locked files
          end;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

{ The thumbnail is made with the picture decoder of Windows (AuGfx / WIC),
  never with FPImage: FPImage decodes the whole cover with 16 bits per
  channel (3000 x 3000 px: 72 MB, for every album of a repair) and scales it
  in Pascal; WIC decodes a JPEG at a reduced size straight away. The result
  is CACHE_THUMB_SIZE square: a cover within 2 % of square fills it, any
  other keeps its proportions on black. }
function ThumbnailSquare(ASrc: TGfxBitmap; AFullW, AFullH: Integer): TGfxBitmap;
var
  FitW, FitH, OffX, OffY, X, Y, X0, Y0, X1, Y1, K: Integer;
  Ratio, SX, SY, FX, FY, V: Double;
  PD: PByte;
  R0, R1: PByte;
begin
  Result := TGfxBitmap.Create(CACHE_THUMB_SIZE, CACHE_THUMB_SIZE);
  { opaque black }
  for Y := 0 to CACHE_THUMB_SIZE - 1 do
  begin
    PD := PByte(Result.Row(Y));
    for X := 0 to CACHE_THUMB_SIZE - 1 do
    begin
      PD[0] := 0; PD[1] := 0; PD[2] := 0; PD[3] := 255;
      Inc(PD, 4);
    end;
  end;

  { the proportions of the cover itself (AFullW x AFullH): those of the reduced
    picture are rounded to whole pixels, and the 2 % rule would tip over }
  if (AFullW > 0) and (AFullH > 0) then Ratio := AFullW / AFullH
  else Ratio := ASrc.Width / ASrc.Height;
  if (Ratio >= 0.98) and (Ratio <= 1.02) then
  begin
    FitW := CACHE_THUMB_SIZE;
    FitH := CACHE_THUMB_SIZE;
  end
  else if Ratio > 1.0 then
  begin
    FitW := CACHE_THUMB_SIZE;
    FitH := Max(1, Round(CACHE_THUMB_SIZE / Ratio));
  end
  else
  begin
    FitH := CACHE_THUMB_SIZE;
    FitW := Max(1, Round(CACHE_THUMB_SIZE * Ratio));
  end;
  OffX := (CACHE_THUMB_SIZE - FitW) div 2;
  OffY := (CACHE_THUMB_SIZE - FitH) div 2;

  { ASrc is at most CACHE_THUMB_SIZE on its longer side (WIC made it smaller),
    so this only enlarges: a pixel or two, or a cover smaller than a thumbnail.
    Two-by-two interpolation; the pixels are premultiplied, which on black is
    the colour itself. }
  SX := ASrc.Width / FitW;
  SY := ASrc.Height / FitH;
  for Y := 0 to FitH - 1 do
  begin
    FY := (Y + 0.5) * SY - 0.5;
    if FY < 0 then FY := 0;
    Y0 := Trunc(FY);
    if Y0 > ASrc.Height - 1 then Y0 := ASrc.Height - 1;
    Y1 := Min(Y0 + 1, ASrc.Height - 1);
    FY := FY - Y0;
    R0 := PByte(ASrc.Row(Y0));
    R1 := PByte(ASrc.Row(Y1));
    PD := PByte(Result.Row(OffY + Y)) + OffX * 4;
    for X := 0 to FitW - 1 do
    begin
      FX := (X + 0.5) * SX - 0.5;
      if FX < 0 then FX := 0;
      X0 := Trunc(FX);
      if X0 > ASrc.Width - 1 then X0 := ASrc.Width - 1;
      X1 := Min(X0 + 1, ASrc.Width - 1);
      FX := FX - X0;
      for K := 0 to 2 do
      begin
        V := (R0[X0 * 4 + K] * (1 - FX) + R0[X1 * 4 + K] * FX) * (1 - FY) +
             (R1[X0 * 4 + K] * (1 - FX) + R1[X1 * 4 + K] * FX) * FY;
        PD[K] := EnsureRange(Round(V), 0, 255);
      end;
      Inc(PD, 4);
    end;
  end;
end;

procedure GenerateAndCacheThumbnail(var Meta: TAudioMetadata; const FilePath, DestHashFilename: string;
  AForce: Boolean = False);
var
  DestThumbPath, TempThumbPath, CoverPath: string;
  Src, Thumb: TGfxBitmap;
  Jpeg: TBytes;
  FullW, FullH: Integer;
  FS: TFileStream;
begin
  if (DestHashFilename = '') or (AppCacheThumbsDir = '') then
  begin
    SetLength(Meta.CoverData, 0);
    Exit;
  end;

  DestThumbPath := AppCacheThumbsDir + DestHashFilename + '.jpg';

  if not DirectoryExists(LongPath(AppCacheThumbsDir)) then
    ForceDirectories(AppCacheThumbsDir);

  if (not AForce) and FileExists(LongPath(DestThumbPath)) then
  begin
    SetLength(Meta.CoverData, 0); // Purge payload instantly
    Exit;
  end;

  Src   := nil;
  Thumb := nil;
  try
    try
      // 1. The embedded cover, at thumbnail size
      FullW := 0;
      FullH := 0;
      if Meta.HasCover and (Length(Meta.CoverData) > 0) then
      begin
        Src := ImageFromBytes(Meta.CoverData, CACHE_THUMB_SIZE);
        if Src <> nil then ImageSizeFromBytes(Meta.CoverData, FullW, FullH);
      end;
      SetLength(Meta.CoverData, 0);

      // Fall back to folder art if embedded art was missing or unreadable
      if Src = nil then
      begin
        CoverPath := FindCoverArt(FilePath);
        if CoverPath <> '' then
        begin
          Src := ImageFromFile(CoverPath, CACHE_THUMB_SIZE);
          if Src <> nil then ImageSizeFromFile(CoverPath, FullW, FullH);
        end;
      end;

      if (Src = nil) or (Src.Width <= 0) or (Src.Height <= 0) then
        Exit;

      // 2. Into the square (letterboxed on black unless it is nearly square)
      Thumb := ThumbnailSquare(Src, FullW, FullH);
      Jpeg  := BitmapToBytes(Thumb, True);
      if Length(Jpeg) = 0 then
        Exit;

      TempThumbPath := DestThumbPath + '.' + IntToStr(PtrUInt(GetThreadID)) + '.tmp';
      try
        FS := TFileStream.Create(LongPath(TempThumbPath), fmCreate);
        try
          FS.WriteBuffer(Jpeg[0], Length(Jpeg));
        finally
          FS.Free;
        end;

        // Atomic rename without hardware write-through stall
        if AForce or (not FileExists(LongPath(DestThumbPath))) then
          CommitAtomicFile(TempThumbPath, DestThumbPath, False);
      finally
        if FileExists(LongPath(TempThumbPath)) then
          SysUtils.DeleteFile(LongPath(TempThumbPath));
      end;
    except
      // a cover that cannot be read or a thumbnail that cannot be written:
      // no thumbnail (the scan goes on)
    end;
  finally
    Src.Free;
    Thumb.Free;
    SetLength(Meta.CoverData, 0); // Absolute failsafe purge
  end;
end;

// Writes the downscaled JPEG to a temporary file first and swaps atomically
// via CommitAtomicFile, so an interrupted write never truncates AFilePath.
// The output is always JPEG data, so the function only accepts
// a .jpg / .jpeg target. This prevents JPEG bytes ending up under a .png (or
// other) name.
// Uses the picture decoder of Windows (AuGfx / WIC):
// the size comes from the header, a JPEG is decoded at the reduced
// size, and pictures over AuGfx.MAX_IMAGE_PIXELS are refused there.
function DownscaleImageFile(const AFilePath: string; MaxDim: Integer): Boolean;
var
  W, H         : Integer;
  Img          : TGfxBitmap;
  Jpeg         : TBytes;
  FS           : TFileStream;
  TempFilePath : string;
  Ext          : string;
begin
  Result := False;
  if (AFilePath = '') or (MaxDim <= 0) or (not FileExists(LongPath(AFilePath))) then
    Exit;

  Ext := LowerCase(ExtractFileExt(AFilePath));
  if (Ext <> '.jpg') and (Ext <> '.jpeg') then
    Exit;

  try
    // 1. A picture at all? If it is corrupt or HTML, abort (Result = False)
    if not ImageSizeFromFile(AFilePath, W, H) then
      Exit(False);

    // 2. If the file is ALREADY a true JPEG and fits within MaxDim, keep it as-is
    if (W <= MaxDim) and (H <= MaxDim) and IsFileAlreadyJPEG(AFilePath) then
      Exit(True);

    // 3. Downscale / transcode to a temporary JPEG file and swap atomically
    Img := ImageFromFile(AFilePath, MaxDim);
    if Img = nil then
      Exit(False);
    try
      Jpeg := BitmapToBytes(Img, True);
    finally
      Img.Free;
    end;
    if Length(Jpeg) = 0 then
      Exit(False);

    TempFilePath := AFilePath + '.' + IntToStr(PtrUInt(GetThreadID)) + '.tmp';
    try
      FS := TFileStream.Create(LongPath(TempFilePath), fmCreate);
      try
        FS.WriteBuffer(Jpeg[0], Length(Jpeg));
      finally
        FS.Free;
      end;

      if IsFileAlreadyJPEG(TempFilePath) then
        Result := CommitAtomicFile(TempFilePath, AFilePath, False);
    finally
      if FileExists(LongPath(TempFilePath)) then
        SysUtils.DeleteFile(LongPath(TempFilePath));
    end;
  except
    Result := False;
  end;
end;

// =============================================================================
// Hardened ReplayGain parser
// 1. Never skips across CR/LF (#10/#13) so empty tags never steal the next line's value.
// 2. Requires the numeric value (+, -, 0..9) to begin immediately after the key's
//    delimiter (ignoring prose comments that happen to mention 'replaygain').
// 3. Clamps parsed values to [-60.0 .. +24.0] and rejects NaN / Infinite.
// =============================================================================
function ExtractReplayGain(const AllTags, TargetKeys: string): double;
var
  UpperTags, UpperKeys, Key, NumStr: string;
  KeyStart, KeyEnd, KeyLen, TagsLen: Integer;
  SearchFrom, MatchPos, ValPos, ValEnd: Integer;
  ParsedVal: Double;
  FS: TFormatSettings;
  C, PrevC: Char;
  HasDigits: Boolean;
begin
  Result := 0.0;
  if (AllTags = '') or (TargetKeys = '') then
    Exit;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  UpperTags := UpperCase(AllTags);
  UpperKeys := UpperCase(TargetKeys);
  TagsLen   := Length(UpperTags);

  KeyStart := 1;
  while KeyStart <= Length(UpperKeys) do
  begin
    // Find next ';' delimiter in TargetKeys
    KeyEnd := KeyStart;
    while (KeyEnd <= Length(UpperKeys)) and (UpperKeys[KeyEnd] <> ';') do
      Inc(KeyEnd);

    Key      := Trim(Copy(UpperKeys, KeyStart, KeyEnd - KeyStart));
    KeyLen   := Length(Key);
    KeyStart := KeyEnd + 1;

    if KeyLen = 0 then
      Continue;

    SearchFrom := 1;
    while SearchFrom <= TagsLen do
    begin
      MatchPos := PosEx(Key, UpperTags, SearchFrom);
      if MatchPos = 0 then
        Break;

      SearchFrom := MatchPos + KeyLen;

      // Verify Key is at a token boundary (start of string, after newline, or after ': ' / ';')
      if MatchPos > 1 then
      begin
        PrevC := UpperTags[MatchPos - 1];
        if not (PrevC in [#0, #9, #10, #13, ' ', ':', ';']) then
          Continue;
      end;

      ValPos := MatchPos + KeyLen;

      // Step past horizontal separators ONLY (never cross #10 or #13 into the next line!)
      while (ValPos <= TagsLen) and
            (UpperTags[ValPos] in [#0, #9, ' ', ':', '=', ';']) do
        Inc(ValPos);

      // Find the end of the current line
      ValEnd := ValPos;
      while (ValEnd <= TagsLen) and
            not (UpperTags[ValEnd] in [#0, #10, #13]) do
        Inc(ValEnd);

      // The numeric value must start immediately at ValPos (not after prose text!)
      if (ValPos >= ValEnd) or not (UpperTags[ValPos] in ['+', '-', '0'..'9']) then
        Continue;

      // Extract the numeric prefix (+, -, digits, and '.' / ',')
      NumStr    := '';
      HasDigits := False;
      while ValPos < ValEnd do
      begin
        C := UpperTags[ValPos];
        if C = ',' then
          C := '.';

        if C in ['0'..'9'] then
        begin
          NumStr    := NumStr + C;
          HasDigits := True;
        end
        else if (C in ['+', '-']) and (NumStr = '') then
          NumStr := NumStr + C
        else if (C = '.') and HasDigits and (Pos('.', NumStr) = 0) then
          NumStr := NumStr + C
        else
          Break; // Reached trailing ' dB' or unit suffix after the number

        Inc(ValPos);
      end;

      if HasDigits and TryStrToFloat(NumStr, ParsedVal, FS) then
      begin
        if (not IsNan(ParsedVal)) and (not IsInfinite(ParsedVal)) then
        begin
          // R128_TRACK_GAIN / R128_ALBUM_GAIN (RFC 7845) are Q7.8
          // fixed-point integers (1/256 dB) relative to -23 LUFS, whereas
          // ReplayGain 2.0 is in dB relative to -18 LUFS. Convert before clamping:
          // e.g. -512 -> -2.0 dB (R128) -> +3.0 dB (ReplayGain).
          if (Pos(TAG_R128_PREFIX, Key) = 1) and (Pos('GAIN', Key) > 0) then
            ParsedVal := (ParsedVal / 256.0) + 5.0;

          Result := EnsureRange(ParsedVal, -60.0, 24.0);
          Exit;
        end;
      end;
    end;
  end;
end;

end.
