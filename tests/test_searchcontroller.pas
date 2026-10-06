{ SearchController: background index + newest-query-wins results. }

program test_searchcontroller;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, FileTree, SearchController;

var
  Failures: Integer;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('ok: ', Msg)
  else
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end;
end;

function WaitResults(C: TSearchController; out S: TSearchSnapshot): Boolean;
var
  I: Integer;
begin
  for I := 1 to 400 do
  begin
    if C.TakeResults(S) and not C.IsRunning then
      Exit(True);
    Sleep(5);
  end;
  Result := False;
end;

procedure Run;
var
  T: TFileTree;
  Docs: TNodeID;
  C: TSearchController;
  S: TSearchSnapshot;
  I: Integer;
begin
  T := TFileTree.Create('/r');
  Docs := T.AddNode('Docs', RootID, 0, True);
  T.AddNode('report-big.pdf', Docs, 900, False);
  T.AddNode('report-small.pdf', Docs, 100, False);
  T.AddNode('notes.txt', RootID, 50, False);
  for I := 1 to 3000 do
    T.AddNode(Format('file%d.bin', [I]), Docs, I, False);
  T.RollUpDirectorySizes;
  C := TSearchController.Create;
  try
    { A query before any index: results arrive once the tree is indexed. }
    C.SetQuery('  report ');
    Expect(C.IsRunning, 'running while waiting for an index');
    C.SetTree(T, True);
    T.AddNode('report-after-copy.pdf', RootID, 5000, False);
    Expect(WaitResults(C, S), 'results published');
    Expect((S.Query = 'report') and (S.TotalMatches = 2) and (Length(S.Items) = 2),
      Format('query trimmed, matches from the copied tree (%d)', [S.TotalMatches]));
    Expect((Length(S.Items) = 2) and (S.Items[0].Name = 'report-big.pdf') and
      (S.Items[0].Path = '/r/Docs/report-big.pdf') and (S.Items[0].Size = 900) and
      not S.Items[0].IsDirectory, 'rows carry name, path, size, kind');
    Expect(S.Partial, 'results from a partial index are marked partial');

    { Newest query wins. }
    C.SetQuery('file1');
    C.SetQuery('docs');
    Expect(WaitResults(C, S) and (S.Query = 'docs'), 'only the newest query is published');
    Expect((Length(S.Items) = 1) and S.Items[0].IsDirectory and (S.Items[0].ItemCount = 3002),
      'directory rows carry their item count');

    { A final tree replaces the partial index and re-runs the query. }
    C.SetTree(T, False);
    Expect(WaitResults(C, S) and not S.Partial, 'final index re-runs the query');

    C.SetQuery('');
    Expect(WaitResults(C, S) and (S.TotalMatches = 0) and (Length(S.Items) = 0),
      'empty query clears the results');
    Expect(C.HasIndex, 'index kept');
  finally
    C.Free;
    T.Free;
  end;
end;

begin
  Failures := 0;
  Run;
  if Failures > 0 then
  begin
    WriteLn('test_searchcontroller: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_searchcontroller: all passed');
end.
