unit uLibraryQuery;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  Project:   Aulumic
  Unit Name: uLibraryQuery
  Author:    André Lubke
  Created:   2026 (split from uLibraryManager)

  The auto-playlist filter: EvaluateTrack tests one library track against the
  conditions uTagParser.ParseQuery made from a query such as
  '%artist% HAS miles; %year% >= 1959'. All conditions must match; within one
  condition ' OR ' alternatives are pre-split by ParseQuery.
  No state, no threads; covered by Tests\TestLibraryLogic.pas (TTestTrackQuery).
  =============================================================================}

interface

uses
  Classes, SysUtils, uLibraryTypes, uTagParser, uUserStatsManager;

// True when Track matches all Conditions (an empty array matches every track).
// UStats (may be nil) supplies rating, play count, favorite and last played.
function EvaluateTrack(const Conditions: TQueryConditionArray; Track: PTrackInfo;
  UStats: PUserTrackStats): boolean;

implementation

uses
  uMetaUtils, uAudioUtils, uAppStrings, uAppConsts, uOSUtils;

function EvaluateTrack(const Conditions: TQueryConditionArray; Track: PTrackInfo; UStats: PUserTrackStats): boolean;
var
  I, J: integer;
  Passes, MatchFound, SubPass: boolean;
  TrackStrVal, TrackStrValLower, TrackCleanValLower: string;
  TrackNumVal, SubNum: Int64;
  IsDSD, DSDChecked: Boolean;
begin
  if Length(Conditions) = 0 then
    Exit(True);
  if not Assigned(Track) then
    Exit(False);

  IsDSD      := False;
  DSDChecked := False;

  for I := 0 to High(Conditions) do
  begin
    TrackStrVal        := '';
    TrackCleanValLower := '';
    TrackNumVal        := 0;

    // 1. DATA ROUTING: Pull the values from the Track
    case Conditions[I].DataType of
      dtString:
        begin
          case Conditions[I].TagID of
            tiTitle:
              begin
                TrackStrVal        := Track^.Title;
                TrackCleanValLower := Track^.CleanTitle;
              end;
            tiArtist:
              begin
                TrackStrVal        := Track^.Artist;
                TrackCleanValLower := Track^.CleanArtist;
              end;
            tiAlbumArtist:
              begin
                TrackStrVal        := Track^.AlbumArtist;
                TrackCleanValLower := Track^.CleanAlbumArtist;
              end;
            tiAlbum:
              begin
                TrackStrVal        := Track^.Album;
                TrackCleanValLower := Track^.CleanAlbum;
              end;
            tiGenre:
              begin
                TrackStrVal        := Track^.Genre;
                TrackCleanValLower := Track^.CleanGenre;
              end;
            tiComposer:
              begin
                TrackStrVal        := Track^.Composer;
                TrackCleanValLower := Track^.CleanComposer;
              end;
            tiPerformer:
              begin
                TrackStrVal        := Track^.Performer;
                TrackCleanValLower := Track^.CleanPerformer;
              end;
            tiComment:
              begin
                TrackStrVal        := Track^.Comment;
                TrackCleanValLower := LowerCase(StripAccents(Track^.Comment));
              end;
            tiFilePath:
              begin
                TrackStrVal        := Track^.FilePath;
                TrackCleanValLower := Track^.CleanFolder + DirectorySeparator +
                                      LowerCase(StripAccents(Track^.FileNameOnly));
              end;
            tiFileName:
              begin
                TrackStrVal        := Track^.FileNameOnly;
                TrackCleanValLower := LowerCase(StripAccents(Track^.FileNameOnly));
              end;
            tiFolder:
              begin
                TrackStrVal        := ExtractFileName(ExcludeTrailingPathDelimiter(Track^.FolderDir));
                TrackCleanValLower := LowerCase(StripAccents(TrackStrVal));
              end;

            tiCodec:
              begin
                if not DSDChecked then
                begin
                  IsDSD      := IsDSDFile(Track^.FilePath);
                  DSDChecked := True;
                end;
                if IsDSD then
                  TrackStrVal := LBL_CODEC_DSD
                else
                  TrackStrVal := UpperCase(Copy(ExtractFileExt(Track^.FileNameOnly), 2, 10));
              end;

            tiResolution:
              begin
                if not DSDChecked then
                begin
                  IsDSD      := IsDSDFile(Track^.FilePath);
                  DSDChecked := True;
                end;
                if IsDSD then
                  TrackStrVal := SafeFormat(FMT_RES_DSD, [Track^.SampleRate div DSD_BASE_RATE])
                else
                  TrackStrVal := SafeFormat(FMT_RES_PCM, [Track^.BitDepth, Track^.SampleRate / 1000.0]);
              end;
          end;
        end;

      dtNumeric:
        begin
          case Conditions[I].TagID of
            tiYear:       TrackNumVal := Track^.Year;
            tiTrackNum:   TrackNumVal := Track^.TrackNumber;
            tiRating:     if Assigned(UStats) then TrackNumVal := UStats^.Rating;
            tiPlayCount:  if Assigned(UStats) then TrackNumVal := UStats^.PlayCount;
            tiFavorite:   if Assigned(UStats) and UStats^.IsFavorite then TrackNumVal := 1;
            tiBitDepth:   TrackNumVal := Track^.BitDepth;
            tiSampleRate: TrackNumVal := Track^.SampleRate;
          end;
        end;

      dtDate:
        begin
          case Conditions[I].TagID of
            tiLastPlayed: if Assigned(UStats) then TrackNumVal := UStats^.LastPlayed;
            tiAdded:      TrackNumVal := Track^.DateAdded;
          end;
        end;
    end;

    // 2. EVALUATION ENGINE (Pre-Split & Pre-Normalized OR Logic)
    Passes := False;
    case Conditions[I].DataType of

      // --- STRING EVALUATION ---
      dtString:
        begin
          MatchFound       := False;
          TrackStrValLower := LowerCase(TrackStrVal);

          for J := 0 to High(Conditions[I].SubValues) do
          begin
            SubPass := False;
            case Conditions[I].Op of
              opEq, opNotEq:
                SubPass := (TrackStrValLower = Conditions[I].SubValues[J].LowerStr) or
                           ((TrackCleanValLower <> '') and
                            (TrackCleanValLower = Conditions[I].SubValues[J].CleanLower));
              opHas, opNotHas:
                SubPass := (Pos(Conditions[I].SubValues[J].LowerStr, TrackStrValLower) > 0) or
                           ((TrackCleanValLower <> '') and
                            (Pos(Conditions[I].SubValues[J].CleanLower, TrackCleanValLower) > 0));
              opStartsWith:
                // ---> AUDIT FIX: Check Pos(...) = 1 (not > 1) on accent-stripped string!
                SubPass := (Pos(Conditions[I].SubValues[J].LowerStr, TrackStrValLower) = 1) or
                           ((TrackCleanValLower <> '') and
                            (Pos(Conditions[I].SubValues[J].CleanLower, TrackCleanValLower) = 1));
            end;

            if SubPass then
            begin
              MatchFound := True;
              Break;
            end;
          end;

          if Conditions[I].Op in [opNotEq, opNotHas] then
            Passes := not MatchFound
          else
            Passes := MatchFound;
        end;

      // --- NUMERIC EVALUATION ---
      dtNumeric:
        begin
          MatchFound := False;

          for J := 0 to High(Conditions[I].SubValues) do
          begin
            SubPass := False;
            SubNum  := Conditions[I].SubValues[J].NumVal;

            case Conditions[I].Op of
              opEq, opNotEq: SubPass := (TrackNumVal = SubNum);
              opGT:          SubPass := (TrackNumVal > SubNum);
              opLT:          SubPass := (TrackNumVal < SubNum);
              opGTE:         SubPass := (TrackNumVal >= SubNum);
              opLTE:         SubPass := (TrackNumVal <= SubNum);
            end;

            if SubPass then
            begin
              MatchFound := True;
              Break;
            end;
          end;

          if Conditions[I].Op = opNotEq then
            Passes := not MatchFound
          else
            Passes := MatchFound;
        end;

      // --- DATE EVALUATION ---
      dtDate:
        case Conditions[I].Op of
          opInLast: Passes := (TrackNumVal > 0) and (TrackNumVal >= Conditions[I].ValNum);
        end;
    end;

    if not Passes then
      Exit(False);
  end;

  Result := True;
end;

end.
