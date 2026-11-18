unit uTagParser;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uTagParser
  Author:    André Lubke
  Created:   2026

  Parses the metatag variables (%artist% etc.) for using in queries (in auto
  playlists) and for display purposes (in status bars etc.).
  =============================================================================}

interface

uses
  Classes, SysUtils, StrUtils, DateUtils, Math, ALMetadata, uAppConsts,
  uUserStatsManager, uAudioUtils;

type
  TTrackFormatContext = record
    Meta         : TAudioMetadata;
    LiveStats    : TAudioStats;
    UserStats    : PUserTrackStats;
    DateAdded    : Int64;
    FilePath     : string;
    IsDSD        : Boolean;
    IsDoP        : Boolean;
    DeviceName   : string;
    TrackCount   : Integer;
    TotalTimeStr : string;
  end;

  { The Single Source of Truth: Every tag has a unique ID }
  TTagID = (
    tiUnknown,
    tiTitle, tiArtist, tiAlbumArtist, tiAlbum, tiGenre,
    tiComposer, tiPerformer,
    tiComment, tiTrackNum, tiYear,
    tiCodec, tiResolution, tiDate, tiFileName, tiFilePath,
    tiFirstArtist, tiFirstAlbumArtist, tiFirstGenre, tiFolder,
    tiRating, tiFavorite, tiPlayCount, tiLastPlayed, tiAdded,
    tiDuration, tiTotalTime, tiTrackCount, tiCpu, tiReplayGain, tiBitDepth,
    tiChannels, tiSampleRate, tiSampleRateKhz, tiOutRate, tiBufferSize, tiDevice,
    tiPhase, tiBitPerfect
  );

  TTagDataType  = (dtString, dtNumeric, dtDate, dtNone);
  TOperatorType = (opUnknown, opEq, opNotEq, opGT, opLT, opGTE, opLTE,
                    opHas, opNotHas, opStartsWith, opInLast);

  TTagDef = record
    FriendlyName : string;
    TagStr       : string;
    DataType     : TTagDataType;
    IsQueryable  : Boolean;
  end;

  // Pre-computed OR branch item for zero-allocation track evaluation
  TQuerySubValue = record
    RawStr     : string;
    LowerStr   : string;
    CleanLower : string;
    NumVal     : Int64;
  end;
  TQuerySubValueArray = array of TQuerySubValue;

  { The Query Engine Memory Record }
  TQueryCondition = record
    TagID     : TTagID;
    DataType  : TTagDataType;
    Op        : TOperatorType;
    ValStr    : string;
    ValNum    : Int64;
    SubValues : TQuerySubValueArray;
  end;
  TQueryConditionArray = array of TQueryCondition;

  TTagDefArray = array of TTagDef;

const
  { The Master Registry indexed by the Enum itself }
  MASTER_TAG_REGISTRY: array[TTagID] of TTagDef = (
    (FriendlyName: 'Unknown'; TagStr: ''; DataType: dtNone; IsQueryable: False),

    // Standard Metadata
    (FriendlyName: 'Title'; TagStr: 'title'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Artist'; TagStr: 'artist'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Album artist'; TagStr: 'albumartist'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Album'; TagStr: 'album'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Genre'; TagStr: 'genre'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Composer'; TagStr: 'composer'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Performer'; TagStr: 'performer'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Comment'; TagStr: 'comment'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Track number'; TagStr: 'tracknumber'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Year'; TagStr: 'year'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Codec'; TagStr: 'codec'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Resolution'; TagStr: 'resolution'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'Date'; TagStr: 'date'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'File name'; TagStr: 'filename'; DataType: dtString; IsQueryable: True),
    (FriendlyName: 'File path'; TagStr: 'filepath'; DataType: dtString; IsQueryable: True),

    // First-Item Only Tags
    (FriendlyName: 'First artist'; TagStr: 'first_artist'; DataType: dtString; IsQueryable: False),
    (FriendlyName: 'First album artist'; TagStr: 'first_albumartist'; DataType: dtString; IsQueryable: False),
    (FriendlyName: 'First genre'; TagStr: 'first_genre'; DataType: dtString; IsQueryable: False),
    (FriendlyName: 'Containing folder'; TagStr: 'folder'; DataType: dtString; IsQueryable: False),

    // Database Stats
    (FriendlyName: 'Rating'; TagStr: 'rating'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Favourite'; TagStr: 'favorite'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Play count'; TagStr: 'playcount'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Last played'; TagStr: 'lastplayed'; DataType: dtDate; IsQueryable: True),
    (FriendlyName: 'Date added'; TagStr: 'added'; DataType: dtDate; IsQueryable: True),

    // Engine Variables
    (FriendlyName: 'Duration'; TagStr: 'duration'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'Total time'; TagStr: 'totaltime'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'Track count'; TagStr: 'trackcount'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'CPU usage'; TagStr: 'cpu'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'ReplayGain'; TagStr: 'replaygain'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'Bit depth'; TagStr: 'bitdepth'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Channels'; TagStr: 'channels'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'Sample rate'; TagStr: 'samplerate'; DataType: dtNumeric; IsQueryable: True),
    (FriendlyName: 'Sample rate kHz'; TagStr: 'samplerate_khz'; DataType: dtNumeric; IsQueryable: False),
    (FriendlyName: 'Out rate'; TagStr: 'outrate'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'Buffer size'; TagStr: 'buffersize'; DataType: dtNone; IsQueryable: False),
    (FriendlyName: 'Output device'; TagStr: 'device'; DataType: dtString; IsQueryable: False),

    (FriendlyName: 'Phase response'; TagStr: 'phase'; DataType: dtString; IsQueryable: False),
    // ---> ADDED: 'Bit-Perfect' while nothing touches the signal, else empty
    (FriendlyName: 'Bit-Perfect'; TagStr: 'bitperfect'; DataType: dtNone; IsQueryable: False)
  );

{ Helper Functions }
function  GetTagIDByToken(const Token: string): TTagID;
procedure GetQueryableTags(out TagList: TTagDefArray);
function  ParseQuery(const Query: string): TQueryConditionArray;
function  FormatTrackInfo(const Fmt: string; const Ctx: TTrackFormatContext): string;

implementation

uses
  uSettingsManager, uMetaUtils, uOSUtils, uAppStrings;

const
  CPU_POLL_INTERVAL_MS = 500;

var
  GLastCpuPollTick : QWord = 0;
  GCachedCpuStr    : string = '0.0%';

function GetTagIDByToken(const Token: string): TTagID;
var
  ID: TTagID;
begin
  Result := tiUnknown;
  if Token = '' then
    Exit;

  for ID := Succ(tiUnknown) to High(TTagID) do
  begin
    if SameText(MASTER_TAG_REGISTRY[ID].TagStr, Token) then
      Exit(ID);
  end;
end;

procedure GetQueryableTags(out TagList: TTagDefArray);
var
  ID: TTagID;
  Count: Integer;
begin
  // ---> AUDIT FIX: Initialize out parameter to nil to silence Hint 5057
  TagList := nil;
  Count   := 0;
  for ID := Low(TTagID) to High(TTagID) do
  begin
    if MASTER_TAG_REGISTRY[ID].IsQueryable then
      Inc(Count);
  end;

  SetLength(TagList, Count);
  Count := 0;
  for ID := Low(TTagID) to High(TTagID) do
  begin
    if MASTER_TAG_REGISTRY[ID].IsQueryable then
    begin
      TagList[Count] := MASTER_TAG_REGISTRY[ID];
      Inc(Count);
    end;
  end;
end;

function ParseQuery(const Query: string): TQueryConditionArray;
var
  Statements: TStringArray;
  I, P, OrPos, SubCount, ClampedInt: integer;
  ClampedInt64: Int64;
  S, Token, OpStr, ValStr, RemVal, SubStr: string;
  Cond: TQueryCondition;
begin
  // ---> AUDIT FIX: Initialize managed Result to nil to silence Warning 5093
  Result := nil;
  if Trim(Query) = '' then
    Exit;

  Statements := Query.Split([';']);
  for I := 0 to High(Statements) do
  begin
    S := Trim(Statements[I]);
    if (S = '') or (S[1] <> '%') then
      Continue;

    P := PosEx('%', S, 2);
    if P <= 0 then
      Continue;

    Token := LowerCase(Copy(S, 2, P - 2));
    S     := Trim(Copy(S, P + 1, Length(S)));

    Cond       := Default(TQueryCondition);
    Cond.TagID := GetTagIDByToken(Token);
    if Cond.TagID = tiUnknown then
      Continue;

    Cond.DataType := MASTER_TAG_REGISTRY[Cond.TagID].DataType;

    P := Pos(' ', S);
    if P > 0 then
    begin
      OpStr  := UpperCase(Trim(Copy(S, 1, P - 1)));
      ValStr := Trim(Copy(S, P + 1, Length(S)));

      if (OpStr = 'NOT') and StartsText('HAS ', ValStr) then
      begin
        OpStr  := QUERY_OP_NOT_HAS;
        ValStr := Trim(Copy(ValStr, 5, Length(ValStr)));
      end
      else if (OpStr = 'IN') and StartsText('LAST ', ValStr) then
      begin
        OpStr  := QUERY_OP_IN_LAST;
        ValStr := Trim(Copy(ValStr, 6, Length(ValStr)));
      end;

      Cond.Op := opUnknown;
      case Cond.DataType of
        dtString:
          begin
            if (OpStr = QUERY_OP_IS) or (OpStr = '=') then
              Cond.Op := opEq
            else if OpStr = '<>' then
              Cond.Op := opNotEq
            else if OpStr = QUERY_OP_HAS then
              Cond.Op := opHas
            else if OpStr = QUERY_OP_NOT_HAS then
              Cond.Op := opNotHas
            else if OpStr = QUERY_OP_STARTSWITH then
              Cond.Op := opStartsWith;
          end;
        dtNumeric:
          begin
            if OpStr = '=' then
              Cond.Op := opEq
            else if OpStr = '<>' then
              Cond.Op := opNotEq
            else if OpStr = '>' then
              Cond.Op := opGT
            else if OpStr = '<' then
              Cond.Op := opLT
            else if OpStr = '>=' then
              Cond.Op := opGTE
            else if OpStr = '<=' then
              Cond.Op := opLTE;
          end;
        dtDate:
          begin
            if OpStr = QUERY_OP_IN_LAST then
              Cond.Op := opInLast;
          end;
      end;

      if Cond.Op <> opUnknown then
      begin
        Cond.ValStr := ValStr;
        Cond.ValNum := 0;

        if Cond.DataType = dtNumeric then
        begin
          Cond.ValNum := StrToInt64Def(ValStr, 0);
        end
        else if Cond.DataType = dtDate then
        begin
          // ---> AUDIT FIX T1: Clamp date lookback ranges (up to 100 years) so
          // extreme user inputs never raise EConvertError in IncMonth/IncYear
          // or overflow 64-bit multiplication!
          if EndsText('d', ValStr) then
          begin
            ClampedInt64 := EnsureRange(StrToInt64Def(Copy(ValStr, 1, Length(ValStr) - 1), 0), 0, 36500);
            Cond.ValNum  := DateTimeToUnix(Now, False) - (ClampedInt64 * 86400);
          end
          else if EndsText('w', ValStr) then
          begin
            ClampedInt64 := EnsureRange(StrToInt64Def(Copy(ValStr, 1, Length(ValStr) - 1), 0), 0, 5200);
            Cond.ValNum  := DateTimeToUnix(Now, False) - (ClampedInt64 * 604800);
          end
          else if EndsText('m', ValStr) then
          begin
            ClampedInt  := EnsureRange(StrToIntDef(Copy(ValStr, 1, Length(ValStr) - 1), 0), 0, 1200);
            Cond.ValNum := DateTimeToUnix(IncMonth(Now, -ClampedInt), False);
          end
          else if EndsText('y', ValStr) then
          begin
            ClampedInt  := EnsureRange(StrToIntDef(Copy(ValStr, 1, Length(ValStr) - 1), 0), 0, 100);
            Cond.ValNum := DateTimeToUnix(IncYear(Now, -ClampedInt), False);
          end
          else
          begin
            ClampedInt64 := EnsureRange(StrToInt64Def(ValStr, 0), 0, 36500);
            Cond.ValNum  := DateTimeToUnix(Now, False) - (ClampedInt64 * 86400);
          end;
        end;

        // Pre-split ' OR ' branches and pre-compute LowerStr, CleanLower, and NumVal
        if Cond.DataType in [dtString, dtNumeric] then
        begin
          RemVal   := ValStr;
          SubCount := 0;

          while True do
          begin
            OrPos := Pos(' OR ', UpperCase(RemVal));
            if OrPos > 0 then
            begin
              SubStr := Trim(Copy(RemVal, 1, OrPos - 1));
              RemVal := Trim(Copy(RemVal, OrPos + 4, Length(RemVal)));
            end
            else
            begin
              SubStr := Trim(RemVal);
              RemVal := '';
            end;

            if SubStr <> '' then
            begin
              SetLength(Cond.SubValues, SubCount + 1);
              Cond.SubValues[SubCount].RawStr     := SubStr;
              Cond.SubValues[SubCount].LowerStr   := LowerCase(SubStr);
              Cond.SubValues[SubCount].CleanLower := LowerCase(StripAccents(SubStr));
              if Cond.DataType = dtNumeric then
                Cond.SubValues[SubCount].NumVal := StrToInt64Def(SubStr, 0)
              else
                Cond.SubValues[SubCount].NumVal := 0;
              Inc(SubCount);
            end;

            if RemVal = '' then
              Break;
          end;
        end;

        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Cond;
      end;
    end;
  end;
end;

function FormatTrackInfo(const Fmt: string; const Ctx: TTrackFormatContext): string;

  function EvaluateTag(const ID: TTagID): string;
  var
    PhaseModeSetting: Integer;
    NowTick: QWord;
  begin
    Result := '';
    case ID of
      tiTitle:
        Result := Ctx.Meta.Title;

      tiArtist:
        begin
          Result := FormatTagString(Ctx.Meta.Artist, 0, ' / ');
          if Result = '' then
            Result := FormatTagString(Ctx.Meta.AlbumArtist, 0, ' / ');
          if Result = '' then
            Result := LBL_UNKNOWN_ARTIST;
        end;

      tiAlbumArtist:
        begin
          Result := FormatTagString(Ctx.Meta.AlbumArtist, 0, ' / ');
          if Result = '' then
            Result := FormatTagString(Ctx.Meta.Artist, 0, ' / ');
          if Result = '' then
            Result := LBL_UNKNOWN_ARTIST;
        end;

      tiAlbum:
        begin
          Result := Ctx.Meta.Album;
          if Result = '' then
            Result := LBL_UNKNOWN_ALBUM;
        end;

      tiGenre:
        Result := FormatTagString(Ctx.Meta.Genre, 0, ' / ');

      tiComposer:
        Result := FormatTagString(Ctx.Meta.Composer, 0, ' / ');

      tiPerformer:
        Result := FormatTagString(Ctx.Meta.Performer, 0, ' / ');

      tiComment:
        Result := Ctx.Meta.Comment;

      tiDate:
        Result := Ctx.Meta.DateStr;

      tiDuration:
        Result := Ctx.Meta.DurationStr;

      tiFirstArtist:
        begin
          Result := FormatTagString(Ctx.Meta.Artist, 1);
          if Result = '' then
            Result := FormatTagString(Ctx.Meta.AlbumArtist, 1);
          if Result = '' then
            Result := LBL_UNKNOWN_ARTIST;
        end;

      tiFirstAlbumArtist:
        begin
          Result := FormatTagString(Ctx.Meta.AlbumArtist, 1);
          if Result = '' then
            Result := FormatTagString(Ctx.Meta.Artist, 1);
          if Result = '' then
            Result := LBL_UNKNOWN_ARTIST;
        end;

      tiFirstGenre:
        begin
          Result := FormatTagString(Ctx.Meta.Genre, 1);
          if Result = '' then
            Result := Trim(Ctx.Meta.Genre);
        end;

      tiFilePath:
        if Ctx.FilePath <> '' then
          Result := Trim(Ctx.FilePath);

      tiFileName:
        if Ctx.FilePath <> '' then
          Result := ExtractFileName(Ctx.FilePath);

      tiFolder:
        if Ctx.FilePath <> '' then
          Result := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFileDir(Ctx.FilePath)));

      tiRating:
        if Assigned(Ctx.UserStats) then
          Result := IntToStr(Ctx.UserStats^.Rating)
        else
          Result := '0';

      tiPlayCount:
        if Assigned(Ctx.UserStats) then
          Result := IntToStr(Ctx.UserStats^.PlayCount)
        else
          Result := '0';

      tiFavorite:
        if Assigned(Ctx.UserStats) then
          Result := IntToStr(Ord(Ctx.UserStats^.IsFavorite))
        else
          Result := '0';

      tiLastPlayed:
        if Assigned(Ctx.UserStats) and (Ctx.UserStats^.LastPlayed > 0) then
          Result := FormatDateTime('dd mmm yyyy', UnixToDateTime(Ctx.UserStats^.LastPlayed, False));

      tiAdded:
        if Ctx.DateAdded > 0 then
          Result := FormatDateTime('dd mmm yyyy', UnixToDateTime(Ctx.DateAdded, False));

      tiTrackNum:
        if Ctx.Meta.TrackNumber > 0 then
          Result := IntToStr(Ctx.Meta.TrackNumber);

      tiYear:
        if Ctx.Meta.Year > 0 then
          Result := IntToStr(Ctx.Meta.Year);

      tiCodec:
        if Ctx.IsDSD then
          Result := LBL_CODEC_DSD
        else
          Result := UpperCase(Copy(ExtractFileExt(Ctx.FilePath), 2, 10));

      tiResolution:
        if Ctx.IsDSD then
        begin
          if Ctx.Meta.SampleRate > 0 then
            Result := SafeFormat(FMT_RES_DSD, [Ctx.Meta.SampleRate div DSD_BASE_RATE])
          else
            Result := LBL_CODEC_DSD;
        end
        else if (Ctx.Meta.BitDepth > 0) and (Ctx.Meta.SampleRate > 0) then
        begin
          if (Ctx.Meta.SampleRate mod 1000) = 0 then
            Result := Format('%d/%d', [Ctx.Meta.BitDepth, Ctx.Meta.SampleRate div 1000])
          else
            Result := Format('%d/%.1f', [Ctx.Meta.BitDepth, Ctx.Meta.SampleRate / 1000.0]);
        end;

      tiSampleRateKhz:
        if Ctx.Meta.SampleRate > 0 then
        begin
          if (Ctx.Meta.SampleRate mod 1000) = 0 then
            Result := IntToStr(Ctx.Meta.SampleRate div 1000)
          else
            Result := Format('%.1f', [Ctx.Meta.SampleRate / 1000.0]);
        end;

      tiSampleRate:
        Result := IntToStr(Ctx.Meta.SampleRate);

      tiBitDepth:
        Result := IntToStr(Ctx.Meta.BitDepth);

      tiChannels:
        if Ctx.Meta.Channels = 1 then
          Result := LBL_CHANNELS_MONO
        else if Ctx.Meta.Channels = 2 then
          Result := LBL_CHANNELS_STEREO
        else if Ctx.Meta.Channels > 2 then
          Result := SafeFormat(FMT_CHANNELS_MULTI, [Ctx.Meta.Channels]);

      tiTrackCount:
        Result := IntToStr(Ctx.TrackCount);

      tiTotalTime:
        Result := Ctx.TotalTimeStr;

      // --- LIVE ENGINE STATS ---
      tiCpu:
        if Ctx.LiveStats.IsPlaying then
        begin
          NowTick := GetTickCount64;
          if (GLastCpuPollTick = 0) or ((NowTick - GLastCpuPollTick) >= CPU_POLL_INTERVAL_MS) then
          begin
            GLastCpuPollTick := NowTick;
            GCachedCpuStr    := Format('%.1f%%', [GetAppCPUUsage]);
          end;
          Result := GCachedCpuStr;
        end;

      tiDevice:
        if Ctx.LiveStats.IsPlaying then
          Result := Ctx.DeviceName;

      tiOutRate:
        if Ctx.LiveStats.IsPlaying and (Ctx.LiveStats.OutputRate > 0) then
        begin
          if Ctx.IsDoP then
            Result := SafeFormat(FMT_RES_DSD, [(Ctx.LiveStats.OutputRate div DSD_BASE_RATE) * DOP_DSD_FACTOR])
          else if (Ctx.LiveStats.OutputRate mod 1000) = 0 then
            Result := SafeFormat(FMT_RATE_KHZ_INT, [Ctx.LiveStats.OutputRate div 1000])
          else
            Result := SafeFormat(FMT_RATE_KHZ_DEC, [Ctx.LiveStats.OutputRate / 1000.0]);
        end;

      tiBitPerfect:
        if Ctx.LiveStats.IsPlaying and Ctx.LiveStats.IsBitPerfect then
          Result := LBL_BIT_PERFECT;

      tiBufferSize:
        if Ctx.LiveStats.IsPlaying then
          Result := IntToStr(Ctx.LiveStats.BufferSizeMs) + ' ms';

      tiReplayGain:
        if Ctx.LiveStats.IsPlaying and (not Ctx.IsDoP) then
        begin
          if not AppSettings.Data.Audio.VolumeLocked then
          begin
            if (Abs(Ctx.LiveStats.AppliedReplayGain) > 0.001) or (AppSettings.Data.Audio.PreampDB < 0.0) then
            begin
              if Abs(Ctx.LiveStats.AppliedReplayGain) > 0.001 then
              begin
                if AppSettings.Data.Audio.PreampDB < 0.0 then
                  Result := Format('Gain: %.2f dB (RG) + %.1f dB (Preamp)', [Ctx.LiveStats.AppliedReplayGain, AppSettings.Data.Audio.PreampDB])
                else
                  Result := Format('ReplayGain: %.2f dB', [Ctx.LiveStats.AppliedReplayGain]);
              end
              else
                Result := Format('Preamp: %.1f dB', [AppSettings.Data.Audio.PreampDB]);
            end;

            if AppSettings.Data.Audio.EnableSoftClipping then
            begin
              if Result <> '' then
                Result := Result + '  |  Soft Clipper: On'
              else
                Result := 'Soft Clipper: On';
            end;
          end;

          if (not AppSettings.Data.Audio.ToneDirect) and
             ((AppSettings.Data.Audio.ToneBassDB <> 0) or
              (AppSettings.Data.Audio.ToneLowMidDB <> 0) or
              (AppSettings.Data.Audio.ToneMidDB <> 0) or
              (AppSettings.Data.Audio.ToneHighMidDB <> 0) or
              (AppSettings.Data.Audio.ToneTrebleDB <> 0)) then
          begin
            if Result <> '' then
              Result := Result + '  |  EQ: On'
            else
              Result := 'EQ: On';
          end;
        end;

      tiPhase:
        if Ctx.LiveStats.IsPlaying and
           (Ctx.LiveStats.InputRate > 0) and
           (Ctx.LiveStats.OutputRate > 0) and
           AppSettings.Data.Audio.ResamplePCM and
           (not Ctx.IsDoP) and
           (not (Ctx.IsDSD and AppSettings.Data.Audio.DisableResampleForDSD)) and
           (Ctx.LiveStats.InputRate <> Ctx.LiveStats.OutputRate) then
        begin
          if Ctx.LiveStats.OutputRate > Ctx.LiveStats.InputRate then
          begin
            PhaseModeSetting := AppSettings.Data.Audio.UpsamplePhase;
            Result           := 'Upsampling: ';
          end
          else
          begin
            PhaseModeSetting := AppSettings.Data.Audio.DownsamplePhase;
            Result           := 'Downsampling: ';
          end;

          case PhaseModeSetting of
            0: Result := Result + 'Linear phase';
            2: Result := Result + 'Minimum phase';
            else
              Result := Result + 'Intermediate phase';
          end;
        end;
    end;
  end;

  function ExpandSegment(const Segment: string; out HasNonEmptyTag: Boolean): string;
  var
    I, Len, ClosePct: Integer;
    Token, TagVal: string;
    ID: TTagID;
  begin
    Result         := '';
    HasNonEmptyTag := False;
    Len            := Length(Segment);
    I              := 1;

    while I <= Len do
    begin
      if Segment[I] = '%' then
      begin
        ClosePct := PosEx('%', Segment, I + 1);
        if ClosePct > I + 1 then
        begin
          Token := Copy(Segment, I + 1, ClosePct - I - 1);
          ID    := GetTagIDByToken(Token);
          if ID <> tiUnknown then
          begin
            TagVal := EvaluateTag(ID);
            if TagVal <> '' then
            begin
              HasNonEmptyTag := True;
              Result         := Result + TagVal;
            end;
            I := ClosePct + 1;
            Continue;
          end;
        end;
      end;

      Result := Result + Segment[I];
      Inc(I);
    end;
  end;

var
  I, Len, CloseBracket: Integer;
  DummyHasTag, BlockHasTag: Boolean;
  BlockText: string;
begin
  Result := '';
  if Fmt = '' then
    Exit;

  Len := Length(Fmt);
  I   := 1;

  while I <= Len do
  begin
    if Fmt[I] = '[' then
    begin
      CloseBracket := PosEx(']', Fmt, I + 1);
      if CloseBracket > 0 then
      begin
        BlockText := ExpandSegment(Copy(Fmt, I + 1, CloseBracket - I - 1), BlockHasTag);
        if BlockHasTag then
          Result := Result + BlockText;
        I := CloseBracket + 1;
        Continue;
      end
      else
      begin
        Inc(I);
        Continue;
      end;
    end
    else if Fmt[I] = ']' then
    begin
      Inc(I);
      Continue;
    end
    else
    begin
      CloseBracket := PosEx('[', Fmt, I);
      if CloseBracket = 0 then
        CloseBracket := Len + 1;

      Result := Result + ExpandSegment(Copy(Fmt, I, CloseBracket - I), DummyHasTag);
      I      := CloseBracket;
    end;
  end;

  Result := Trim(Result);
end;

end.
