unit TestArtistSource;

{$mode ObjFPC}{$H+}

{ ==============================================================================
  AulumicNS tests - TestArtistSource
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  The biography of Artist Info from Wikipedia without the network: what the
  answer of the page query gives (the introduction as paragraphs, the title,
  the Wikidata item; a missing page, a disambiguation page, a stub), the
  address of an article, and which source a saved biography is credited to.
  =============================================================================}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, uLastFmScraper, uAppConsts, uAppStrings;

type
  TTestArtistSource = class(TTestCase)
  private
    FDir: string;
    procedure WriteText(const AName, AText: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TheIntroductionComesAsParagraphs;
    procedure AMissingPageGivesNothing;
    procedure ADisambiguationPageIsToldApart;
    procedure AStubOrBrokenAnswerGivesNothing;
    procedure LastFmAnswersAreToldApart;
    procedure AnArticleAddressIsEncoded;
    procedure ADownloadedTextWithoutASourceFileIsLastFm;
    procedure ATextWithAnArticleAddressIsWikipedia;
    procedure TheOwnTextHasNoSource;
    procedure OnlyAnArticleAddressIsOpened;
  end;

implementation

const
  PAGE = '{"batchcomplete":true,"query":{"pages":[{"pageid":7,"ns":0,"title":"The Example Quartet",' +
         '"extract":"The Example Quartet is a made-up band of four players.\nIt has recorded ' +
         'three albums.\n\n","pageprops":{"wikibase_item":"Q12345"}}]}}';

procedure TTestArtistSource.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    Format('AulumicNSTest_source_%d', [GetProcessID]) + DirectorySeparator;
  ForceDirectories(FDir);
end;

procedure TTestArtistSource.TearDown;
begin
  DeleteFile(FDir + FILE_ARTIST_BIO);
  DeleteFile(FDir + FILE_ARTIST_BIO_USER);
  DeleteFile(FDir + FILE_ARTIST_BIO_SOURCE);
  RemoveDir(ExcludeTrailingPathDelimiter(FDir));
end;

procedure TTestArtistSource.WriteText(const AName, AText: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(FDir + AName);
  finally
    SL.Free;
  end;
end;

procedure TTestArtistSource.TheIntroductionComesAsParagraphs;
var
  Text, Title, Item: string;
  Dis: Boolean;
begin
  AssertTrue('A page with a text', ParseWikipediaIntro(PAGE, Text, Title, Item, Dis));
  AssertEquals('The Example Quartet', Title);
  AssertEquals('Q12345', Item);
  AssertFalse(Dis);
  AssertEquals('The Example Quartet is a made-up band of four players.' + LineEnding + LineEnding +
    'It has recorded three albums.', Text);
end;

procedure TTestArtistSource.AMissingPageGivesNothing;
var
  Text, Title, Item: string;
  Dis: Boolean;
begin
  AssertFalse(ParseWikipediaIntro(
    '{"batchcomplete":true,"query":{"pages":[{"ns":0,"title":"Nobody At All","missing":true}]}}',
    Text, Title, Item, Dis));
  AssertEquals('', Text);
  AssertFalse('A missing page is no disambiguation page', Dis);
end;

procedure TTestArtistSource.ADisambiguationPageIsToldApart;
var
  Text, Title, Item: string;
  Dis: Boolean;
begin
  AssertFalse(ParseWikipediaIntro(
    '{"query":{"pages":[{"pageid":9,"title":"Example","extract":"Example may refer to several ' +
    'things, people and places with this name.","pageprops":{"disambiguation":"","wikibase_item":"Q9"}}]}}',
    Text, Title, Item, Dis));
  AssertTrue(Dis);
  AssertEquals('', Text);
end;

procedure TTestArtistSource.AStubOrBrokenAnswerGivesNothing;
var
  Text, Title, Item: string;
  Dis: Boolean;
begin
  AssertFalse('A line too short for a biography', ParseWikipediaIntro(
    '{"query":{"pages":[{"pageid":3,"title":"Short","extract":"A band."}]}}', Text, Title, Item, Dis));
  AssertFalse('No extract', ParseWikipediaIntro(
    '{"query":{"pages":[{"pageid":3,"title":"Short"}]}}', Text, Title, Item, Dis));
  AssertFalse('Not JSON', ParseWikipediaIntro('<html>error</html>', Text, Title, Item, Dis));
  AssertFalse('Cut off', ParseWikipediaIntro('{"query":{"pages":[{"pageid":3,"tit', Text, Title, Item, Dis));
  AssertFalse('Empty', ParseWikipediaIntro('', Text, Title, Item, Dis));
  AssertFalse('No pages', ParseWikipediaIntro('{"query":{"pages":[]}}', Text, Title, Item, Dis));
end;

procedure TTestArtistSource.LastFmAnswersAreToldApart;
var
  Err: string;
begin
  AssertEquals('A biography', 'A band from Leeds.', ParseLastFmBio(
    '{"artist":{"name":"X","bio":{"content":"A band from <b>Leeds</b>."}}}', Err));
  AssertEquals('', Err);

  AssertEquals('', ParseLastFmBio(
    '{"error":6,"message":"The artist you supplied could not be found"}', Err));
  AssertEquals('An unknown artist', ERR_BIO_NOT_FOUND, Err);

  AssertEquals('', ParseLastFmBio('{"artist":{"name":"X","bio":{"content":"  "}}}', Err));
  AssertEquals('A known artist without a text', ERR_BIO_NOT_FOUND, Err);
  AssertEquals('', ParseLastFmBio('{"artist":{"name":"X"}}', Err));
  AssertEquals('No bio at all', ERR_BIO_NOT_FOUND, Err);

  AssertEquals('', ParseLastFmBio('{"error":10,"message":"Invalid API key"}', Err));
  AssertEquals('An invalid key', ERR_LASTFM_KEY_REJECTED, Err);
  AssertEquals('', ParseLastFmBio('{"error":26,"message":"Suspended API key"}', Err));
  AssertEquals('A blocked key', ERR_LASTFM_KEY_REJECTED, Err);

  AssertEquals('', ParseLastFmBio('{"error":29,"message":"Rate limit exceeded"}', Err));
  AssertEquals('Another error keeps its text', ERR_LASTFM_API_PREFIX + 'Rate limit exceeded', Err);
  AssertEquals('', ParseLastFmBio('{"error":8}', Err));
  AssertEquals('An error without a text', ERR_LASTFM_GENERIC, Err);

  AssertEquals('', ParseLastFmBio('<html>error</html>', Err));
  AssertEquals('Not JSON', 1, Pos(ERR_LASTFM_PARSE_PREFIX, Err));
end;

procedure TTestArtistSource.AnArticleAddressIsEncoded;
begin
  AssertEquals('https://en.wikipedia.org/wiki/Yes_%28band%29', WikipediaPageUrl('Yes (band)'));
  AssertEquals('https://en.wikipedia.org/wiki/AC%2FDC', WikipediaPageUrl('AC/DC'));
  AssertEquals('', WikipediaPageUrl('  '));
  AssertEquals('https://www.last.fm/music/Maya%20Fridman', LastFmArtistUrl('Maya Fridman (cello); Someone Else'));
end;

procedure TTestArtistSource.ADownloadedTextWithoutASourceFileIsLastFm;
var
  Url: string;
begin
  AssertTrue('No biography, no source', ArtistBioSource(FDir, Url) = bsNone);
  WriteText(FILE_ARTIST_BIO, 'A text.');
  AssertTrue(ArtistBioSource(FDir, Url) = bsLastFm);
  AssertEquals('', Url);
end;

procedure TTestArtistSource.ATextWithAnArticleAddressIsWikipedia;
var
  Url: string;
begin
  WriteText(FILE_ARTIST_BIO, 'A text.');
  WriteText(FILE_ARTIST_BIO_SOURCE, WikipediaPageUrl('Yes (band)'));
  AssertTrue(ArtistBioSource(FDir, Url) = bsWikipedia);
  AssertEquals('https://en.wikipedia.org/wiki/Yes_%28band%29', Url);
end;

procedure TTestArtistSource.TheOwnTextHasNoSource;
var
  Url: string;
begin
  WriteText(FILE_ARTIST_BIO, 'My own text.');
  WriteText(FILE_ARTIST_BIO_SOURCE, WikipediaPageUrl('Yes (band)'));
  WriteText(FILE_ARTIST_BIO_USER, '');
  AssertTrue(ArtistBioSource(FDir, Url) = bsNone);
  AssertEquals('', Url);
end;

procedure TTestArtistSource.OnlyAnArticleAddressIsOpened;
var
  Url: string;
begin
  WriteText(FILE_ARTIST_BIO, 'A text.');
  WriteText(FILE_ARTIST_BIO_SOURCE, 'https://example.com/wiki/Yes');
  AssertTrue('Another site', ArtistBioSource(FDir, Url) = bsLastFm);
  AssertEquals('', Url);
  WriteText(FILE_ARTIST_BIO_SOURCE, 'https://en.wikipedia.org/wiki/Yes" & calc');
  AssertTrue('Characters an address does not have', ArtistBioSource(FDir, Url) = bsLastFm);
  AssertEquals('', Url);
  WriteText(FILE_ARTIST_BIO_SOURCE, 'https://en.wikipedia.org/wiki/');
  AssertTrue('No article', ArtistBioSource(FDir, Url) = bsLastFm);
end;

initialization
  RegisterTest(TTestArtistSource);

end.
