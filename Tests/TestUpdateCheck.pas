unit TestUpdateCheck;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestUpdateCheck
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The check for a newer version without the network: version texts as
  numbers, which of two is newer, and what the answer about the latest
  release means for this program (newer, up to date, no usable answer).
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uUpdateCheck;

type
  TTestUpdateCheck = class(TTestCase)
  published
    procedure AVersionIsUpToFourNumbers;
    procedure NumbersAreComparedAsNumbers;
    procedure ANewerReleaseIsReported;
    procedure TheSameOrAnOlderReleaseIsUpToDate;
    procedure AnAnswerWithoutAVersionIsAFailure;
    procedure ASkippedVersionIsNotAskedAboutAgain;
  end;

implementation

const
  ANSWER = '{"url":"https://api.example/releases/1","tag_name":"%s","name":"Aulumic","draft":false,' +
           '"assets":[{"name":"a.zip","size":3}],"body":"# Changes\r\n\"quoted\" tag_name text"}';

procedure TTestUpdateCheck.AVersionIsUpToFourNumbers;
var
  V: TVersionNumbers;
begin
  AssertTrue('Four numbers', ParseVersion('1.1.0.18', V));
  AssertEquals(1, V[0]);
  AssertEquals(1, V[1]);
  AssertEquals(0, V[2]);
  AssertEquals(18, V[3]);
  AssertTrue('With the v of a tag', ParseVersion(' v2.0 ', V));
  AssertEquals(2, V[0]);
  AssertEquals('Missing numbers are 0', 0, V[3]);
  AssertFalse('Empty', ParseVersion('', V));
  AssertFalse('Only the v', ParseVersion('v', V));
  AssertFalse('Words', ParseVersion('latest', V));
  AssertFalse('A dot at the end', ParseVersion('1.2.', V));
  AssertFalse('Two dots', ParseVersion('1..2', V));
  AssertFalse('Five numbers', ParseVersion('1.2.3.4.5', V));
  AssertFalse('A suffix', ParseVersion('1.2.3-beta', V));
  AssertFalse('Too long for a number', ParseVersion('1.99999999999', V));
end;

procedure TTestUpdateCheck.NumbersAreComparedAsNumbers;
begin
  AssertTrue('19 after 18', CompareVersionText('1.1.0.19', '1.1.0.18') > 0);
  AssertTrue('100 after 99, not by text', CompareVersionText('1.1.0.100', '1.1.0.99') > 0);
  AssertTrue('The minor number before the build', CompareVersionText('1.2.0.1', '1.1.0.50') > 0);
  AssertTrue('Older', CompareVersionText('1.0.0.12', '1.1.0.14') < 0);
  AssertEquals('The same, with and without v', 0, CompareVersionText('v1.1.0.18', '1.1.0.18'));
  AssertEquals('Missing numbers are 0', 0, CompareVersionText('1.1', '1.1.0.0'));
  AssertTrue('No version is older than a version', CompareVersionText('nothing', '0.0.0.1') < 0);
end;

procedure TTestUpdateCheck.ANewerReleaseIsReported;
var
  Latest: string;
begin
  AssertTrue(JudgeLatest(Format(ANSWER, ['v1.1.0.19']), '1.1.0.18', Latest) = usNewer);
  AssertEquals('Without the v', '1.1.0.19', Latest);
  AssertTrue('A larger step', JudgeLatest(Format(ANSWER, ['v1.2.0.25']), '1.1.0.18', Latest) = usNewer);
end;

procedure TTestUpdateCheck.TheSameOrAnOlderReleaseIsUpToDate;
var
  Latest: string;
begin
  AssertTrue('The released version itself',
    JudgeLatest(Format(ANSWER, ['v1.1.0.18']), '1.1.0.18', Latest) = usUpToDate);
  AssertEquals('1.1.0.18', Latest);
  AssertTrue('A test build after the release',
    JudgeLatest(Format(ANSWER, ['v1.1.0.18']), '1.1.0.19', Latest) = usUpToDate);
end;

procedure TTestUpdateCheck.AnAnswerWithoutAVersionIsAFailure;
var
  Latest: string;
begin
  AssertTrue('Nothing came', JudgeLatest('', '1.1.0.18', Latest) = usFailed);
  AssertEquals('', Latest);
  AssertTrue('Not JSON', JudgeLatest('<html>Not found</html>', '1.1.0.18', Latest) = usFailed);
  AssertTrue('Cut off', JudgeLatest('{"tag_name":"v1.1.0', '1.1.0.18', Latest) = usFailed);
  AssertTrue('A list', JudgeLatest('[1,2]', '1.1.0.18', Latest) = usFailed);
  AssertTrue('No tag', JudgeLatest('{"message":"Not Found"}', '1.1.0.18', Latest) = usFailed);
  AssertTrue('A tag that is no version',
    JudgeLatest(Format(ANSWER, ['nightly']), '1.1.0.18', Latest) = usFailed);
  AssertEquals('', Latest);
  AssertTrue('A number where the text belongs', JudgeLatest('{"tag_name":5}', '1.1.0.18', Latest) = usFailed);
end;

procedure TTestUpdateCheck.ASkippedVersionIsNotAskedAboutAgain;
begin
  AssertTrue('Newer and nothing skipped', UpdateWanted('1.1.0.20', '1.1.0.19', ''));
  AssertFalse('The skipped version itself', UpdateWanted('1.1.0.20', '1.1.0.19', '1.1.0.20'));
  AssertTrue('A version after the skipped one', UpdateWanted('1.1.0.21', '1.1.0.19', '1.1.0.20'));
  AssertFalse('Older than the skipped one', UpdateWanted('1.1.0.20', '1.1.0.19', '1.1.0.22'));
  AssertFalse('Not newer than this program', UpdateWanted('1.1.0.19', '1.1.0.19', ''));
  AssertFalse('Older than this program', UpdateWanted('1.1.0.18', '1.1.0.19', ''));
  AssertTrue('A skipped text that is no version counts as none', UpdateWanted('1.1.0.20', '1.1.0.19', 'x'));
  AssertFalse('No answer', UpdateWanted('', '1.1.0.19', ''));
end;

initialization
  RegisterTest(TTestUpdateCheck);

end.
