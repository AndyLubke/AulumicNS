unit TestSettings;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestSettings
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The Last.fm key file (uSettingsManager.ReadLastFmKeyFile): the key is the
  first line that is not empty and not a comment; a byte order mark, spaces
  and line ends around it are ignored; anything that is not 16 to 64 letters
  and digits, a missing file and an oversized file give no key.
  Only files in a temporary folder are used.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uSettingsManager, TestHelpers;

type
  TTestLastFmKeyFile = class(TTestCase)
  private
    FDir: string;
    function KeyOf(const AContent: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure APlainKeyIsRead;
    procedure SpacesLineEndsAndTheByteOrderMarkAreIgnored;
    procedure CommentsAndEmptyLinesAreSkipped;
    procedure OnlyTheFirstLineCounts;
    procedure WhatIsNoKeyGivesNone;
    procedure AMissingFileGivesNone;
    procedure AnOversizedFileGivesNone;
  end;

implementation

const
  SAMPLE_KEY = '0123456789abcdef0123456789ABCDEF';

procedure TTestLastFmKeyFile.SetUp;
begin
  FDir := CreateTestDir;
end;

procedure TTestLastFmKeyFile.TearDown;
begin
  RemoveTestDir(FDir);
end;

function TTestLastFmKeyFile.KeyOf(const AContent: string): string;
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, Length(AContent));
  if Length(AContent) > 0 then Move(AContent[1], B[0], Length(AContent));
  WriteFileBytes(FDir + 'LastFmKey.txt', B);
  Result := ReadLastFmKeyFile(FDir + 'LastFmKey.txt');
end;

procedure TTestLastFmKeyFile.APlainKeyIsRead;
begin
  AssertEquals(SAMPLE_KEY, KeyOf(SAMPLE_KEY));
end;

procedure TTestLastFmKeyFile.SpacesLineEndsAndTheByteOrderMarkAreIgnored;
begin
  AssertEquals('line end', SAMPLE_KEY, KeyOf(SAMPLE_KEY + #13#10));
  AssertEquals('spaces', SAMPLE_KEY, KeyOf('  ' + SAMPLE_KEY + '  ' + #10));
  AssertEquals('byte order mark', SAMPLE_KEY, KeyOf(#$EF#$BB#$BF + SAMPLE_KEY + #13#10));
end;

procedure TTestLastFmKeyFile.CommentsAndEmptyLinesAreSkipped;
begin
  AssertEquals(SAMPLE_KEY, KeyOf('# the Last.fm API key' + #13#10 + #13#10 + '; another note' + #13#10 +
    SAMPLE_KEY + #13#10));
end;

procedure TTestLastFmKeyFile.OnlyTheFirstLineCounts;
begin
  AssertEquals('the first of two', SAMPLE_KEY, KeyOf(SAMPLE_KEY + #13#10 + 'ffffffffffffffffffffffffffffffff'));
  AssertEquals('a first line that is no key hides a later one', '',
    KeyOf('paste the key below' + #13#10 + SAMPLE_KEY));
end;

procedure TTestLastFmKeyFile.WhatIsNoKeyGivesNone;
begin
  AssertEquals('empty', '', KeyOf(''));
  AssertEquals('only a comment', '', KeyOf('# nothing here'));
  AssertEquals('too short', '', KeyOf('0123456789abcde'));
  AssertEquals('too long', '', KeyOf(StringOfChar('a', 65)));
  AssertEquals('a space inside', '', KeyOf('0123456789abcdef 0123456789abcdef'));
  AssertEquals('other characters', '', KeyOf('0123456789abcdef-0123456789abcdef'));
  AssertEquals('key=value', '', KeyOf('key=' + SAMPLE_KEY));
end;

procedure TTestLastFmKeyFile.AMissingFileGivesNone;
begin
  AssertEquals('', ReadLastFmKeyFile(FDir + 'NoSuchFile.txt'));
end;

procedure TTestLastFmKeyFile.AnOversizedFileGivesNone;
begin
  AssertEquals('', KeyOf(SAMPLE_KEY + #13#10 + StringOfChar('x', 5000)));
end;

initialization
  RegisterTest(TTestLastFmKeyFile);

end.
