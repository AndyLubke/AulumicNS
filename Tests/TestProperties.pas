unit TestProperties;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestProperties
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Tags page of the Properties window with made-up records (no file is
  read or written): one file shows its values; several files show a value
  they share and "<< Multiple Values >>" where they differ; Title and Track
  cannot be set for several files at once; a text typed into a field goes to
  every selected file and to no other, and marks only those as changed; a
  field left alone changes nothing. The Work field among them.
  =============================================================================}

interface

uses
  Classes, SysUtils, Forms, fpcunit, testregistry, AuForms, AuTagLoader, AuPropertiesForm;

type
  TTestProperties = class(TTestCase)
  private
    FForm: TAuForm;
    function Rec(I: Integer): PTagEditNodeData;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure OneFileShowsItsValues;
    procedure SeveralFilesShowWhatTheyShare;
    procedure TitleAndTrackAreNotForSeveralFiles;
    procedure ATypedValueGoesToEverySelectedFile;
    procedure AFieldLeftAloneChangesNothing;
    procedure AnEmptiedFieldClearsTheValue;
    procedure TheFolderOfAFileEndsWithADelimiter;
  end;

implementation

uses
  uAppStrings;

{ three tracks of one album: the first two are one work, the third another;
  the composer differs on the third }
procedure TTestProperties.SetUp;
const
  TITLES: array[0..2] of string = ('Symphony No. 5: I. Allegro', 'Symphony No. 5: II. Andante', 'Overture');
  WORKS: array[0..2] of string = ('Symphony No. 5', 'Symphony No. 5', 'Egmont');
var
  Data: TList;
  D: PTagEditNodeData;
  I: Integer;
begin
  Data := TList.Create;
  for I := 0 to 2 do
  begin
    New(D);
    D^ := Default(TTagEditNodeData);
    D^.FilePath := Format('C:\No Such Folder\%.2d.flac', [I + 1]);
    D^.Current.Title := TITLES[I];
    D^.Current.Artist := 'An Orchestra';
    D^.Current.AlbumArtist := 'An Orchestra';
    D^.Current.Album := 'The Album';
    D^.Current.Genre := 'Classical';
    D^.Current.Composer := 'Beethoven';
    D^.Current.Work := WORKS[I];
    D^.Current.Track := I + 1;
    D^.Current.Disc := 1;
    D^.Current.DateStr := '1977';
    D^.Original := D^.Current;
    Data.Add(D);
  end;
  FForm := CreatePropertiesForm(nil, Data, nil);
  Data.Free;                 // (nil when the form took the list over)
end;

procedure TTestProperties.TearDown;
begin
  FreeAndNil(FForm);
end;

function TTestProperties.Rec(I: Integer): PTagEditNodeData;
begin
  Result := PropertiesRecord(FForm, I);
  AssertTrue('Record ' + IntToStr(I), Result <> nil);
end;

procedure TTestProperties.OneFileShowsItsValues;
begin
  PropertiesSelectRows(FForm, [1]);
  AssertEquals('Symphony No. 5: II. Andante', PropertiesFieldText(FForm, 'Title'));
  AssertEquals('The Album', PropertiesFieldText(FForm, 'Album'));
  AssertEquals('Beethoven', PropertiesFieldText(FForm, 'Composer'));
  AssertEquals('Symphony No. 5', PropertiesFieldText(FForm, 'Work'));
  AssertEquals('2', PropertiesFieldText(FForm, 'Track'));
  AssertEquals('1977', PropertiesFieldText(FForm, 'Year'));
  AssertEquals('No hint for one file', '', PropertiesFieldHint(FForm, 'Work'));
  AssertTrue('The title of one file can be edited', PropertiesFieldEnabled(FForm, 'Title'));
end;

procedure TTestProperties.SeveralFilesShowWhatTheyShare;
begin
  PropertiesSelectRows(FForm, [0, 1, 2]);
  AssertEquals('A value all share', 'The Album', PropertiesFieldText(FForm, 'Album'));
  AssertEquals('No hint then', '', PropertiesFieldHint(FForm, 'Album'));
  AssertEquals('The work differs: the field is empty', '', PropertiesFieldText(FForm, 'Work'));
  AssertEquals('And says so', LBL_MULTIPLE_VALUES, PropertiesFieldHint(FForm, 'Work'));
  AssertTrue('It can be edited', PropertiesFieldEnabled(FForm, 'Work'));

  { the two movements alone share their work }
  PropertiesSelectRows(FForm, [0, 1]);
  AssertEquals('Symphony No. 5', PropertiesFieldText(FForm, 'Work'));
  AssertEquals('', PropertiesFieldHint(FForm, 'Work'));
end;

procedure TTestProperties.TitleAndTrackAreNotForSeveralFiles;
begin
  PropertiesSelectRows(FForm, [0, 1]);
  AssertFalse('Title', PropertiesFieldEnabled(FForm, 'Title'));
  AssertFalse('Track', PropertiesFieldEnabled(FForm, 'Track'));
  AssertEquals(LBL_UNIQUE_PER_TRACK, PropertiesFieldHint(FForm, 'Title'));
  AssertEquals('The title field is empty', '', PropertiesFieldText(FForm, 'Title'));
  { typing there changes no file }
  PropertiesTypeField(FForm, 'Title', 'One Title For All');
  AssertEquals('Symphony No. 5: I. Allegro', Rec(0)^.Current.Title);
  AssertEquals('Symphony No. 5: II. Andante', Rec(1)^.Current.Title);
  AssertFalse('Nothing is marked as changed', Rec(0)^.IsModified or Rec(1)^.IsModified);
end;

procedure TTestProperties.ATypedValueGoesToEverySelectedFile;
begin
  PropertiesSelectRows(FForm, [0, 1]);
  PropertiesTypeField(FForm, 'Work', 'Symphony No. 5 in C minor, Op. 67');
  AssertEquals('The first', 'Symphony No. 5 in C minor, Op. 67', Rec(0)^.Current.Work);
  AssertEquals('The second', 'Symphony No. 5 in C minor, Op. 67', Rec(1)^.Current.Work);
  AssertEquals('Not the file that was not selected', 'Egmont', Rec(2)^.Current.Work);
  AssertTrue('The two are marked as changed', Rec(0)^.IsModified and Rec(1)^.IsModified);
  AssertFalse('The third is not', Rec(2)^.IsModified);
  AssertEquals('What was loaded is kept to compare with', 'Symphony No. 5', Rec(0)^.Original.Work);
  AssertEquals('The other fields stay', 'Beethoven', Rec(0)^.Current.Composer);
  AssertEquals('The titles too', 'Symphony No. 5: II. Andante', Rec(1)^.Current.Title);

  { a field that showed "multiple values": one value for all }
  PropertiesSelectRows(FForm, [0, 1, 2]);
  AssertEquals(LBL_MULTIPLE_VALUES, PropertiesFieldHint(FForm, 'Work'));
  PropertiesTypeField(FForm, 'Work', 'One Work');
  AssertEquals('One Work', Rec(0)^.Current.Work);
  AssertEquals('One Work', Rec(2)^.Current.Work);
  PropertiesSelectRows(FForm, [0, 1, 2]);
  AssertEquals('Shared now', 'One Work', PropertiesFieldText(FForm, 'Work'));
  AssertEquals('No hint any more', '', PropertiesFieldHint(FForm, 'Work'));

  { typed back to what the file had: not changed any more }
  PropertiesSelectRows(FForm, [2]);
  PropertiesTypeField(FForm, 'Work', 'Egmont');
  AssertFalse('Back to the loaded value', Rec(2)^.IsModified);
end;

procedure TTestProperties.AFieldLeftAloneChangesNothing;
var
  I: Integer;
begin
  PropertiesSelectRows(FForm, [0, 1, 2]);
  PropertiesSelectRows(FForm, [0]);
  PropertiesSelectRows(FForm, [1, 2]);
  PropertiesSelectRows(FForm, [0, 1, 2]);
  for I := 0 to 2 do
    AssertFalse('Selecting files changes none of them', Rec(I)^.IsModified);
  AssertEquals('Symphony No. 5', Rec(0)^.Current.Work);
  AssertEquals('Egmont', Rec(2)^.Current.Work);
  { another field edited: the works that differ stay as they are }
  PropertiesTypeField(FForm, 'Genre', 'Orchestral');
  AssertEquals('Orchestral', Rec(2)^.Current.Genre);
  AssertEquals('Symphony No. 5', Rec(1)^.Current.Work);
  AssertEquals('Egmont', Rec(2)^.Current.Work);
end;

procedure TTestProperties.AnEmptiedFieldClearsTheValue;
begin
  PropertiesSelectRows(FForm, [0, 1]);
  PropertiesTypeField(FForm, 'Work', '');
  AssertEquals('The first', '', Rec(0)^.Current.Work);
  AssertEquals('The second', '', Rec(1)^.Current.Work);
  AssertTrue('Marked as changed', Rec(0)^.IsModified and Rec(1)^.IsModified);
  AssertEquals('The third keeps its work', 'Egmont', Rec(2)^.Current.Work);
end;

{ what "Open folder" hands to Explorer for a file's folder }
procedure TTestProperties.TheFolderOfAFileEndsWithADelimiter;
begin
  AssertEquals('m:\music\album\', FolderOfFile('m:\music\album\01 - Track.flac'));
  AssertEquals('A file in a drive''s root', 'm:\', FolderOfFile('m:\track.flac'));
  AssertEquals('No folder', '', FolderOfFile('track.flac'));
end;

initialization
  RegisterTest(TTestProperties);

end.
