{ =============================================================================
  AulumicNS tests - TestKeyboardLinks
  Copyright (C) 2026 André Lubke
  Licensed under the GNU General Public License, version 3 (see LICENSE).

  What is clicked can also be reached with the keyboard: a label that is a
  link takes the Tab key and is clicked by Enter and Space; the path bar
  takes the Tab key while it has a part to go to, Left and Right move from
  part to part and Enter goes there.
  =============================================================================}
unit TestKeyboardLinks;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType, fpcunit, testregistry,
  AuControls, AuCrumbBar, AuLists, AuForms, uPlaylistFile, uPlaylistStore, AuPlaylistManager, AuPrefs, TestHelpers;

type
  TTestKeyboardLinks = class(TTestCase)
  private
    FForm: TForm;
    FClicks: Integer;
    FPart: Integer;
    procedure LabelClick(Sender: TObject);
    procedure PartClick(Sender: TObject; Index: Integer);
    procedure RowText(Sender: TObject; Row, Col: Integer; var AText: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ALinkLabelTakesTabEnterAndSpace;
    procedure ThePathBarIsWalkedWithTheArrowKeys;
    procedure ALetterGoesToTheNextEntryThatBeginsWithIt;
    procedure TypingInAListGoesToTheRow;
    procedure TypingWorksInAListThatDrawsItsOwnRows;
    procedure EnterInThePageListOfPreferencesKeepsItOpen;
  end;

implementation

type
  TLabelKeys = class(TAuLabel);
  TCrumbKeys = class(TCrumbBar);
  TComboKeys = class(TAuCombo);
  TListKeys = class(TAuListView);

const
  ROWS: array[0..5] of string = ('Alpha', 'Beta', 'Bravo', 'Charlie', 'beta max', 'Delta');

procedure TTestKeyboardLinks.SetUp;
begin
  FForm := TForm.CreateNew(nil);
  FForm.SetBounds(0, 0, 600, 200);
  FClicks := 0;
  FPart := -1;
end;

procedure TTestKeyboardLinks.TearDown;
begin
  FreeAndNil(FForm);
end;

procedure TTestKeyboardLinks.LabelClick(Sender: TObject);
begin
  Inc(FClicks);
end;

procedure TTestKeyboardLinks.PartClick(Sender: TObject; Index: Integer);
begin
  FPart := Index;
end;

procedure TTestKeyboardLinks.ALinkLabelTakesTabEnterAndSpace;
var
  L: TAuLabel;
  Key: Word;
begin
  L := TAuLabel.Create(FForm);
  L.Parent := FForm;
  L.Caption := 'https://example.org';
  L.OnClick := @LabelClick;
  AssertFalse('a plain label is no tab stop', L.TabStop);
  Key := VK_RETURN;
  TLabelKeys(L).KeyDown(Key, []);
  AssertEquals('and Enter does nothing on it', 0, FClicks);

  L.Link := True;
  AssertTrue('a link is a tab stop', L.TabStop);
  Key := VK_RETURN;
  TLabelKeys(L).KeyDown(Key, []);
  AssertEquals('Enter clicks it', 1, FClicks);
  AssertEquals('and the key is used up', 0, Key);
  Key := VK_SPACE;
  TLabelKeys(L).KeyDown(Key, []);
  AssertEquals('Space too', 2, FClicks);
  Key := VK_RETURN;
  TLabelKeys(L).KeyDown(Key, [ssCtrl]);
  AssertEquals('not with Ctrl', 2, FClicks);
  Key := Ord('A');
  TLabelKeys(L).KeyDown(Key, []);
  AssertEquals('no other key', 2, FClicks);

  L.Link := False;
  AssertFalse('no link any more: no tab stop', L.TabStop);
end;

procedure TTestKeyboardLinks.ThePathBarIsWalkedWithTheArrowKeys;
var
  B: TCrumbBar;
  Key: Word;

  procedure Press(AKey: Word);
  begin
    Key := AKey;
    TCrumbKeys(B).KeyDown(Key, []);
  end;

begin
  B := TCrumbBar.Create(FForm);
  B.Parent := FForm;
  B.SetBounds(0, 0, 600, 30);
  B.OnPartClick := @PartClick;

  B.SetPath('All albums');
  AssertFalse('one part: nothing to go to, no tab stop', B.TabStop);
  Press(VK_RETURN);
  AssertEquals(-1, FPart);

  B.SetPath('Folders'#1'Jazz'#1'Miles'#1'Kind of Blue');
  AssertTrue('a path: a tab stop', B.TabStop);
  AssertEquals('it starts on the part above the last', 2, B.KeyPart);
  Press(VK_RETURN);
  AssertEquals('Enter: one level up', 2, FPart);

  Press(VK_LEFT);
  AssertEquals(1, B.KeyPart);
  Press(VK_LEFT);
  Press(VK_LEFT);
  AssertEquals('no further left than the first part', 0, B.KeyPart);
  Press(VK_SPACE);
  AssertEquals('Space goes there', 0, FPart);
  Press(VK_RIGHT);
  Press(VK_RIGHT);
  Press(VK_RIGHT);
  AssertEquals('the last part is where the path is: not a place to go to', 2, B.KeyPart);
  Press(VK_HOME);
  AssertEquals(0, B.KeyPart);
  Press(VK_END);
  AssertEquals(2, B.KeyPart);

  { another path: the keyboard is on its part above the last again }
  B.SetPath('Folders'#1'Jazz');
  AssertEquals(0, B.KeyPart);
  FPart := -1;
  Press(VK_RETURN);
  AssertEquals(0, FPart);
end;

procedure TTestKeyboardLinks.RowText(Sender: TObject; Row, Col: Integer; var AText: string);
begin
  if (Col = 0) and (Row >= 0) and (Row <= High(ROWS)) then AText := ROWS[Row];
end;

procedure TTestKeyboardLinks.ALetterGoesToTheNextEntryThatBeginsWithIt;
var
  C: TAuCombo;
  Key: Word;
  I: Integer;
begin
  AssertEquals('a letter', 'B', LetterOfKey(Ord('B'), []));
  AssertEquals('with Shift too', 'B', LetterOfKey(Ord('B'), [ssShift]));
  AssertEquals('a digit', '4', LetterOfKey(Ord('4'), []));
  AssertEquals('not with Ctrl', #0, LetterOfKey(Ord('B'), [ssCtrl]));
  AssertEquals('not another key', #0, LetterOfKey(VK_DOWN, []));

  C := TAuCombo.Create(FForm);
  C.Parent := FForm;
  for I := 0 to High(ROWS) do C.Items.Add(ROWS[I]);
  C.ItemIndex := 0;
  AssertEquals('the first after the entry shown', 1, IndexStartingWith(C.Items, 0, 'B'));
  AssertEquals('then the next', 2, IndexStartingWith(C.Items, 1, 'B'));
  AssertEquals('small and capital letters alike', 4, IndexStartingWith(C.Items, 2, 'B'));
  AssertEquals('and round to the first again', 1, IndexStartingWith(C.Items, 4, 'B'));
  AssertEquals('none begins with it', -1, IndexStartingWith(C.Items, 0, 'X'));
  AssertEquals('nothing chosen yet', 0, IndexStartingWith(C.Items, -1, 'A'));

  { the closed box: the letter chooses }
  Key := Ord('C');
  TComboKeys(C).KeyDown(Key, []);
  AssertEquals('Charlie', 3, C.ItemIndex);
  AssertEquals('the key is used up', 0, Key);
  Key := Ord('B');
  TComboKeys(C).KeyDown(Key, []);
  AssertEquals('the next B after Charlie', 4, C.ItemIndex);
  Key := Ord('X');
  TComboKeys(C).KeyDown(Key, []);
  AssertEquals('no such entry: it stays', 4, C.ItemIndex);
  AssertEquals('and the key goes on', Ord('X'), Key);
end;

procedure TTestKeyboardLinks.TypingInAListGoesToTheRow;
var
  L: TAuListView;

  procedure Typed(const S1: string);
  var
    I: Integer;
    Ch: TUTF8Char;
  begin
    for I := 1 to Length(S1) do
    begin
      Ch := S1[I];
      TListKeys(L).UTF8KeyPress(Ch);
    end;
  end;

begin
  L := TAuListView.Create(FForm);
  L.Parent := FForm;
  L.SetBounds(0, 0, 300, 180);
  L.AddColumn('Name', 200);
  L.OnGetCell := @RowText;
  L.RowCount := Length(ROWS);
  L.SelectOnly(0);

  Typed('c');
  AssertEquals('one letter: the next row that begins with it', 3, L.FocusedRow);
  AssertTrue('and it is selected', L.Selected[3]);
  { letters typed one after the other belong together }
  L.SelectOnly(0);
  Typed('br');
  AssertEquals('Bravo, not Beta', 2, L.FocusedRow);
  L.SelectOnly(0);
  Typed('beta m');
  AssertEquals('a space inside the text, capitals or not', 4, L.FocusedRow);
end;

{ the Playlist Manager draws its rows itself (an icon, the name, a note): the
  list still knows what a row is called }
procedure TTestKeyboardLinks.TypingWorksInAListThatDrawsItsOwnRows;
var
  Dir: string;
  Store: TPlaylistStore;
  F: TAuForm;
  L: TAuListView;
  Names: TStringList;
  I: Integer;

  procedure Typed(const S1: string);
  var
    K: Integer;
    Ch: TUTF8Char;
  begin
    for K := 1 to Length(S1) do
    begin
      Ch := S1[K];
      TListKeys(L).UTF8KeyPress(Ch);
    end;
  end;

  function FocusedName: string;
  begin
    if (L.FocusedRow >= 0) and (L.FocusedRow < Names.Count) then Result := Names[L.FocusedRow] else Result := '';
  end;

begin
  Dir := CreateTestDir;
  Store := TPlaylistStore.Create(Dir + 'playlists.adb', 'Default playlist');
  Names := TStringList.Create;
  try
    Store.Load;
    Store.Add('Jazz evenings', pkNormal);
    Store.Add('Morning', pkNormal);
    Store.Add('Mozart only', pkNormal);
    Store.Add('Zebra', pkAuto);
    Store.GetNames(Names);
    F := CreatePlaylistManagerForm(nil, Store, '');
    try
      L := nil;
      for I := 0 to F.ComponentCount - 1 do
        if F.Components[I] is TAuListView then L := TAuListView(F.Components[I]);
      AssertNotNull('the list of the Playlist Manager', L);
      AssertEquals('all playlists are listed', Names.Count, L.RowCount);
      L.SelectOnly(0);
      Typed('z');
      AssertEquals('Zebra', FocusedName);
      L.SelectOnly(0);
      Typed('mo');
      AssertEquals('the first that begins with mo', 'Morning', FocusedName);
      L.SelectOnly(0);
      Typed('moz');
      AssertEquals('Mozart only', FocusedName);
    finally
      F.Free;
    end;
  finally
    Names.Free;
    Store.Free;
    RemoveTestDir(Dir);
  end;
end;

{ Enter on a page's name in Preferences goes into the page; it does not run
  the default button OK }
procedure TTestKeyboardLinks.EnterInThePageListOfPreferencesKeepsItOpen;
var
  Folders: TStringList;
  F: TAuForm;
  L: TAuListView;
  I: Integer;
  Key: Word;
begin
  Folders := TStringList.Create;
  try
    F := CreatePrefsForm(nil, Folders, 0);
    try
      L := nil;
      for I := 0 to F.ComponentCount - 1 do
        if (L = nil) and (F.Components[I] is TAuListView) then L := TAuListView(F.Components[I]);
      AssertNotNull('the list of pages', L);
      AssertTrue('it lists the pages', L.RowCount >= 9);
      F.Show;
      try
        L.SetFocus;
        L.SelectOnly(3);
        Key := VK_RETURN;
        TListKeys(L).KeyDown(Key, []);
        AssertEquals('the window stays open', Integer(mrNone), Integer(F.ModalResult));
        AssertEquals('the page stays the chosen one', 3, L.FocusedRow);
        AssertTrue('the focus went into the page', (F.ActiveControl <> nil) and (F.ActiveControl <> L));
      finally
        F.Hide;
      end;
    finally
      F.Free;
    end;
  finally
    Folders.Free;
  end;
end;

initialization
  RegisterTest(TTestKeyboardLinks);

end.
