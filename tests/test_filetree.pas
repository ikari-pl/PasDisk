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

{ Hard-link section is the stream tail: count, IDs (i32), devices,
  file IDs, sizes (u64/i64 each). Patch the IDs in place. }
function WithLinkIDs(Tree: TFileTree; A, B: LongInt): TFileTree;
var
  Stream: TMemoryStream;
  P: PByte;
begin
  Stream := TMemoryStream.Create;
  try
    Tree.WriteSerialized(Stream);
    P := PByte(Stream.Memory) + Stream.Size - 2 * (8 + 8 + 8) - 2 * 4;
    PLongInt(P)^ := A;
    PLongInt(P + 4)^ := B;
    Stream.Position := 0;
    Result := TFileTree.LoadSerialized(Stream);
  finally
    Stream.Free;
  end;
end;

procedure TestLoadHardLinkOrder;
var
  Tree, Loaded: TFileTree;
  F1, F2: TNodeID;
  Key: THardLinkKey;
begin
  Tree := TFileTree.Create('/h');
  try
    F1 := Tree.AddNode('one', RootID, 10, False);
    F2 := Tree.AddNode('two', RootID, 10, False);
    Key.Device := 1;
    Key.FileID := 7;
    Tree.RecordHardLink(F1, Key, 10);
    Tree.RecordHardLink(F2, Key, 10);

    Loaded := WithLinkIDs(Tree, F2, F1);
    Expect(Loaded <> nil, 'out-of-order hard-link IDs still load');
    if Loaded <> nil then
    begin
      Expect((Loaded.HardLinkCount = 2) and
        (Loaded.HardLinkNodeAt(0) < Loaded.HardLinkNodeAt(1)),
        'loaded hard-link records are in ascending ID order');
      Loaded.NormalizeHardLinks;
      Loaded.RollUpDirectorySizes;
      Expect(Loaded.SizeOf(RootID) = 10, 'shared inode counts once after load');
      Loaded.Free;
    end;

    Loaded := WithLinkIDs(Tree, F1, F1);
    Expect(Loaded = nil, 'duplicate hard-link IDs are rejected');
    Loaded.Free;
  finally
    Tree.Free;
  end;
end;

procedure TestReachableFiles;
var
  Tree: TFileTree;
  List: TFPList;
  Big, Small, Linked, Orphan: TNodeID;
  Key: THardLinkKey;
begin
  Tree := TFileTree.Create('/r');
  List := TFPList.Create;
  try
    Big := Tree.AddNode('big', RootID, 100, False);
    Small := Tree.AddNode('small', RootID, 5, False);
    Linked := Tree.AddNode('link', RootID, 0, False);
    Key.Device := 1;
    Key.FileID := 2;
    Tree.RecordHardLink(Linked, Key, 200);
    Orphan := Tree.AppendUnlinked('orphan', 500, False);
    Tree.ReachableFiles(100, List);
    Expect(List.IndexOf(Pointer(PtrUInt(Big))) >= 0, 'large file is reachable');
    Expect(List.IndexOf(Pointer(PtrUInt(Linked))) >= 0,
      'zero-size hard link with a large record is reachable');
    Expect(List.IndexOf(Pointer(PtrUInt(Small))) < 0, 'small file is skipped');
    Expect(List.IndexOf(Pointer(PtrUInt(Orphan))) < 0, 'unlinked node is skipped');
  finally
    List.Free;
    Tree.Free;
  end;
end;

begin
  Failures := 0;
  TestRollUp;
  TestReachableFiles;
  TestLoadHardLinkOrder;
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
