{ FileTree unit tests. }

program test_filetree;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, FileTree;

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

procedure TestRollUp;
var
  Tree: TFileTree;
  Users, Alice: TNodeID;
begin
  Tree := TFileTree.Create('/');
  try
    Users := Tree.AddNode('Users', RootID, 0, True);
    Alice := Tree.AddNode('alice', Users, 0, True);
    Tree.AddNode('big.bin', Alice, 4096, False);
    Tree.AddNode('b.txt', Users, 50, False);
    Tree.AddNode('a.txt', RootID, 100, False);
    Tree.RollUpDirectorySizes;
    Expect(Tree.SizeOf(RootID) = 4246, 'root size');
    Expect(Tree.SizeOf(Users) = 4146, 'Users size');
    Expect(Tree.SizeOf(Alice) = 4096, 'alice size');
    Expect(Tree.ChildCount(RootID) = 2, 'root children');
  finally
    Tree.Free;
  end;
end;

procedure TestPathRoundTrip;
var
  Tree: TFileTree;
  Users, Alice, Big: TNodeID;
begin
  Tree := TFileTree.Create('/');
  try
    Users := Tree.AddNode('Users', RootID, 0, True);
    Alice := Tree.AddNode('alice', Users, 0, True);
    Big := Tree.AddNode('big.bin', Alice, 4096, False);
    Expect(Tree.PathOf(Big) = '/Users/alice/big.bin', 'path of big.bin');
    Expect(Tree.ChildNamed(Users, 'alice') = Alice, 'child named alice');
    Expect(Tree.ChildNamed(Users, 'nobody') = NoNode, 'missing child');
  finally
    Tree.Free;
  end;
end;

procedure TestSortedChildren;
var
  Tree: TFileTree;
  List: TFPList;
  First: TNodeID;
begin
  Tree := TFileTree.Create('/t');
  List := TFPList.Create;
  try
    Tree.AddNode('small', RootID, 10, False);
    Tree.AddNode('large', RootID, 1000, False);
    Tree.AddNode('mid', RootID, 100, False);
    Tree.RollUpDirectorySizes;
    Tree.ChildrenSortedForDisplay(RootID, List);
    Expect(List.Count = 3, 'three children');
    First := TNodeID(PtrInt(List[0]));
    Expect(Tree.NameOf(First) = 'large', 'largest first');
  finally
    List.Free;
    Tree.Free;
  end;
end;

begin
  Failures := 0;
  TestRollUp;
  TestPathRoundTrip;
  TestSortedChildren;
  if Failures = 0 then
  begin
    WriteLn('All FileTree tests passed.');
    Halt(0);
  end;
  WriteLn(Failures, ' failure(s).');
  Halt(1);
end.
