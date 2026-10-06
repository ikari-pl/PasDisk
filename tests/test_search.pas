{ SearchIndex tests: the rules of Services/Search/SearchIndex.swift. }

program test_search;

{$mode objfpc}{$H+}

uses
  SysUtils, FileTree, SearchIndex;

var
  Failures: Integer;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end;
end;

function Names(Index: TSearchIndex; const R: TSearchResults): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(R.Hits) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + Index.Tree.NameOf(R.Hits[I].ID);
  end;
end;

procedure TestFolding;
begin
  Expect(FoldName('ReadMe.MD') = 'readme.md', 'ASCII lower-cased');
  Expect(FoldName('plain') = 'plain', 'lower ASCII unchanged');
  { U+00C4 -> U+00E4 }
  Expect(FoldName('Ärger') = 'ärger', 'Unicode lower-cased');
  { 'A' + U+0308 composes to U+00E4 (NFC) }
  Expect(FoldName('A'#$CC#$88'rger') = 'ärger', 'decomposed name composed');
  Expect(FoldName('ΣΟΦΙΑ') = 'σοφια', 'Greek lower-cased');
end;

procedure TestTokens;
var
  T: TStringArray;
begin
  T := SearchTokens('  Foo   BAR ');
  Expect((Length(T) = 2) and (T[0] = 'foo') and (T[1] = 'bar'), 'ASCII whitespace split');
  { U+00A0 and U+3000 separate tokens like Swift's isWhitespace }
  T := SearchTokens('a'#$C2#$A0'b'#$E3#$80#$80'c');
  Expect((Length(T) = 3) and (T[2] = 'c'), 'Unicode whitespace split');
  T := SearchTokens(#9' '#$E2#$80#$83);
  Expect(Length(T) = 0, 'whitespace-only query has no tokens');
end;

procedure TestMatching;
var
  Tree: TFileTree;
  Index: TSearchIndex;
  Docs: TNodeID;
  R: TSearchResults;
begin
  Tree := TFileTree.Create('project');
  Docs := Tree.AddNode('Docs', RootID, 300, True);
  Tree.AddNode('README.md', Docs, 10, False);
  Tree.AddNode('bar-foo.txt', RootID, 30, False);
  Tree.AddNode('foo.txt', RootID, 20, False);
  Tree.AddNode('Ärger.txt', RootID, 5, False);
  Tree.AddNode('A'#$CC#$88'rger2.txt', RootID, 6, False);
  Tree.AddNode('aaaa', RootID, 1, False);
  Tree.AddNode('ab', RootID, 1, False);
  Tree.AddNode('cd', RootID, 1, False);
  Tree.AppendUnlinked('orphan-foo', 999, False);
  Index := TSearchIndex.Create(Tree, True);
  try
    R := Index.Search('readme', ssAll);
    Expect(Names(Index, R) = 'README.md', 'case-insensitive match');

    R := Index.Search('BAR foo', ssAll);
    Expect((R.TotalMatches = 1) and (Names(Index, R) = 'bar-foo.txt'),
      'every token must match, in any order: ' + Names(Index, R));

    R := Index.Search('foo', ssAll);
    Expect((R.TotalMatches = 2) and (Names(Index, R) = 'bar-foo.txt,foo.txt'),
      'detached nodes skipped, largest first: ' + Names(Index, R));

    R := Index.Search('ärger', ssAll);
    Expect((R.TotalMatches = 2) and (Names(Index, R) = 'A'#$CC#$88'rger2.txt,Ärger.txt'),
      'composed and decomposed names both match: ' + Names(Index, R));

    R := Index.Search('project', ssAll);
    Expect(R.TotalMatches = 0, 'root is never a result');

    R := Index.Search('a', ssAll);
    Expect(Pos('aaaa', Names(Index, R)) > 0, 'repeated token in one name');
    Expect(R.TotalMatches = Length(R.Hits), 'total equals hits under the limit');

    R := Index.Search('bc', ssAll);
    Expect(R.TotalMatches = 0, 'a match never spans two names');

    R := Index.Search('docs', ssFolders);
    Expect(Names(Index, R) = 'Docs', 'folder scope keeps folders');
    R := Index.Search('docs', ssFiles);
    Expect(R.TotalMatches = 0, 'file scope drops folders');
    R := Index.Search('.txt', ssFolders);
    Expect(R.TotalMatches = 0, 'folder scope drops files');

    R := Index.Search('   ', ssAll);
    Expect((R.TotalMatches = 0) and (Length(R.Hits) = 0), 'blank query');
  finally
    Index.Free;
  end;
end;

procedure TestRankingAndLimit;
var
  Tree: TFileTree;
  Index: TSearchIndex;
  R: TSearchResults;
  I: Integer;
  Sorted: Boolean;
begin
  Tree := TFileTree.Create('/');
  { Equal sizes: ordered by name. }
  Tree.AddNode('tie-b', RootID, 7, False);
  Tree.AddNode('tie-a', RootID, 7, False);
  Tree.AddNode('tie-c', RootID, 9, False);
  for I := 1 to 600 do
    Tree.AddNode(Format('many-%d', [I]), RootID, I, False);
  Index := TSearchIndex.Create(Tree, True);
  try
    R := Index.Search('tie', ssAll);
    Expect(Names(Index, R) = 'tie-c,tie-a,tie-b', 'size then name: ' + Names(Index, R));

    R := Index.Search('many', ssAll);
    Expect(R.TotalMatches = 600, 'total counts all matches');
    Expect(Length(R.Hits) = SearchResultLimit, 'hits capped at the limit');
    Sorted := True;
    for I := 1 to High(R.Hits) do
      if R.Hits[I].Size > R.Hits[I - 1].Size then
        Sorted := False;
    Expect(Sorted, 'hits largest first');
    Expect((R.Hits[0].Size = 600) and (R.Hits[High(R.Hits)].Size = 101),
      'the 500 largest are kept');
  finally
    Index.Free;
  end;
end;

begin
  Failures := 0;
  TestFolding;
  TestTokens;
  TestMatching;
  TestRankingAndLimit;
  if Failures > 0 then
  begin
    WriteLn('test_search: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_search: all passed');
end.
