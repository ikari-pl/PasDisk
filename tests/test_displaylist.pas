{ DisplayList: DiskAnalyzer.swift folderItems display rules. }

program test_displaylist;

{$mode objfpc}{$H+}

uses
  SysUtils, FileTree, DisplayList;

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

procedure Run;
var
  T: TFileTree;
  Sub, F: TNodeID;
  I: Integer;
  V: TNodeIDArray;
begin
  T := TFileTree.Create('/r');
  try
    Sub := T.AddNode('sub', RootID, 0, True);
    for I := 1 to 150 do
      T.AddNode(Format('f%.3d', [I]), Sub, 2000 + I, False);
    T.AddNode('tiny', Sub, 1024, False);
    T.AddNode('zero', Sub, 0, False);
    T.AddNode('b-tie', RootID, 5000, False);
    T.AddNode('a-tie', RootID, 5000, False);
    T.AddNode('small', RootID, 100, False);
    for I := 1 to 120 do
      T.AddNode(Format('root%.3d', [I]), RootID, 4096, False);
    T.RollUpDirectorySizes;

    V := VisibleChildren(T, Sub, False, False);
    Expect(Length(V) = 100, Format('below the root: at most 100 (%d)', [Length(V)]));
    Expect((Length(V) > 0) and (T.NameOf(V[0]) = 'f150'), 'largest first');

    V := VisibleChildren(T, RootID, True, False);
    Expect(Length(V) = 1 + 2 + 120, Format('root: no limit, small ones hidden (%d)', [Length(V)]));
    Expect((T.NameOf(V[1]) = 'a-tie') and (T.NameOf(V[2]) = 'b-tie'), 'equal sizes by name');
    F := T.ChildNamed(RootID, 'small');
    Expect(F <> NoNode, 'fixture has the small file');

    { 1024 bytes is not shown: the filter is size > 1 KiB. }
    T.Free;
    T := TFileTree.Create('/r');
    Sub := T.AddNode('sub', RootID, 0, True);
    T.AddNode('tiny', Sub, 1024, False);
    T.AddNode('just', Sub, 1025, False);
    T.AddNode('zero', Sub, 0, False);
    T.RollUpDirectorySizes;
    V := VisibleChildren(T, Sub, False, False);
    Expect((Length(V) = 1) and (T.NameOf(V[0]) = 'just'), 'only sizes above 1 KiB');
    V := VisibleChildren(T, Sub, False, True);
    Expect(Length(V) = 3, 'partial results keep everything, zero size included');
    Expect(Length(VisibleChildren(T, T.ChildNamed(Sub, 'just'), False, False)) = 0,
      'a file has no children');
  finally
    T.Free;
  end;
end;

begin
  Failures := 0;
  Run;
  if Failures > 0 then
  begin
    WriteLn('test_displaylist: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_displaylist: all passed');
end.
