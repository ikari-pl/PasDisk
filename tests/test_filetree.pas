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

function LoadBytes(const Bytes: TBytes; Len: Integer; out Raised: Boolean): TFileTree;
var
  M: TMemoryStream;
begin
  Result := nil;
  Raised := False;
  M := TMemoryStream.Create;
  try
    if Len > 0 then
      M.WriteBuffer(Bytes[0], Len);
    M.Position := 0;
    try
      Result := TFileTree.LoadSerialized(M);
    except
      Raised := True;
    end;
  finally
    M.Free;
  end;
end;

procedure PatchU32(var Bytes: TBytes; Offset: Integer; Value: LongWord);
begin
  Move(Value, Bytes[Offset], 4);
end;

type
  { Claims to be far larger than its bytes, so oversized counts pass the
    bytes-left check and reach the Integer range guard. }
  TBigClaimStream = class(TMemoryStream)
  protected
    function GetSize: Int64; override;
  end;

function TBigClaimStream.GetSize: Int64;
begin
  Result := Int64(100) shl 30;
end;

function LoadClaimingBig(const Bytes: TBytes; out Raised: Boolean): TFileTree;
var
  M: TBigClaimStream;
begin
  Result := nil;
  Raised := False;
  M := TBigClaimStream.Create;
  try
    M.WriteBuffer(Bytes[0], Length(Bytes));
    M.Position := 0;
    try
      Result := TFileTree.LoadSerialized(M);
    except
      Raised := True;
    end;
  finally
    M.Free;
  end;
end;

procedure TestCorruptStreams;
var
  Tree, Loaded: TFileTree;
  F: TNodeID;
  Key: THardLinkKey;
  M: TMemoryStream;
  Good, Bad: TBytes;
  Len, Count, NameLenAt: Integer;
  Raised, AnyRaised, AnyLoaded: Boolean;
begin
  { FileTree.swift deserialization returns nil for any short or
    inconsistent buffer; a bad cache must never raise. }
  Tree := TFileTree.Create('/c');
  M := TMemoryStream.Create;
  try
    F := Tree.AddNode('file', RootID, 10, False);
    Tree.AddNode('dir', RootID, 0, True);
    Key.Device := 1;
    Key.FileID := 2;
    Tree.RecordHardLink(F, Key, 10);
    Tree.WriteSerialized(M);
    SetLength(Good, M.Size);
    Move(M.Memory^, Good[0], M.Size);
    Count := 3;
  finally
    M.Free;
    Tree.Free;
  end;

  Loaded := LoadBytes(Good, Length(Good), Raised);
  Expect((Loaded <> nil) and not Raised, 'intact stream loads');
  Loaded.Free;

  AnyRaised := False;
  AnyLoaded := False;
  for Len := 0 to Length(Good) - 1 do
  begin
    Loaded := LoadBytes(Good, Len, Raised);
    AnyRaised := AnyRaised or Raised;
    AnyLoaded := AnyLoaded or (Loaded <> nil);
    Loaded.Free;
  end;
  Expect(not AnyRaised, 'no truncation raises');
  Expect(not AnyLoaded, 'every truncation is rejected');

  Bad := Copy(Good);
  PatchU32(Bad, 4, $FFFFFFFF);
  Loaded := LoadBytes(Bad, Length(Bad), Raised);
  Expect((Loaded = nil) and not Raised, 'huge node count is rejected before allocating');
  Loaded.Free;

  NameLenAt := 8 + Count * (8 + 4 + 4 + 4 + 1);
  Bad := Copy(Good);
  PatchU32(Bad, NameLenAt, $7FFFFFFF);
  Loaded := LoadBytes(Bad, Length(Bad), Raised);
  Expect((Loaded = nil) and not Raised, 'name length past the end is rejected');
  Loaded.Free;

  Bad := Copy(Good);
  PatchU32(Bad, 4, $80000000);
  Loaded := LoadClaimingBig(Bad, Raised);
  Expect((Loaded = nil) and not Raised, 'node count above MaxInt is rejected');
  Loaded.Free;

  Bad := Copy(Good);
  PatchU32(Bad, NameLenAt, $80000000);
  Loaded := LoadClaimingBig(Bad, Raised);
  Expect((Loaded = nil) and not Raised, 'name length above MaxInt is rejected');
  Loaded.Free;

  Bad := Copy(Good);
  PatchU32(Bad, NameLenAt + Count * 4, $7FFFFFFF);
  Loaded := LoadBytes(Bad, Length(Bad), Raised);
  Expect((Loaded = nil) and not Raised, 'name blob past the end is rejected');
  Loaded.Free;
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

{ FileTree.swift removeChild(named:of:) and merge(_:into:). }
procedure TestMergeAndRemoveChild;
var
  A, B: TFileTree;
  AX, BX, BY, Node, Detached: TNodeID;
begin
  A := TFileTree.Create('/');
  B := TFileTree.Create('/mnt');
  try
    AX := A.AddNode('x', RootID, 0, True);
    A.AddNode('a', AX, 1, False);
    A.AddNode('y', RootID, 5, False);
    A.AddNode('keep', RootID, 7, False);

    BX := B.AddNode('x', RootID, 0, True);
    B.AddNode('b', BX, 2, False);
    B.AddNode('a', BX, 9, False);
    BY := B.AddNode('y', RootID, 0, True);
    B.AddNode('z', BY, 3, False);
    B.AddNode('keep', RootID, 100, False);
    B.AddNode('new', RootID, 4, False);
    B.RollUpDirectorySizes;

    A.Merge(B, RootID);
    A.ResetDirectorySizes;
    A.RollUpDirectorySizes;

    Expect(A.SizeOf(A.ChildNamed(AX, 'a')) = 1, 'existing file in a merged directory is kept');
    Expect(A.ChildNamed(AX, 'b') <> NoNode, 'new file in a merged directory is added');
    Node := A.ChildNamed(RootID, 'y');
    Expect((Node <> NoNode) and A.IsDirectory(Node) and (A.ChildNamed(Node, 'z') <> NoNode),
      'a file in the way of a directory is replaced by it');
    Expect(A.SizeOf(A.ChildNamed(RootID, 'keep')) = 7, 'an existing file is not overwritten by a file');
    Expect(A.ChildNamed(RootID, 'new') <> NoNode, 'new top-level entry is added');
    Expect(A.SizeOf(RootID) = 1 + 2 + 3 + 7 + 4, Format('roll-up after merge (%d)', [A.SizeOf(RootID)]));

    Detached := A.RemoveChildNamed(RootID, 'x');
    Expect((Detached = AX) and (A.ChildNamed(RootID, 'x') = NoNode) and
      (A.ParentOf(AX) = NoNode), 'removeChild detaches the named child');
    Expect(A.RemoveChildNamed(RootID, 'missing') = NoNode, 'removeChild of a missing name');
    A.SetRootName('/renamed');
    Expect(A.PathOf(A.ChildNamed(RootID, 'new')) = '/renamed/new', 'root name sets the path prefix');
  finally
    A.Free;
    B.Free;
  end;
end;

begin
  Failures := 0;
  TestRollUp;
  TestReachableFiles;
  TestCorruptStreams;
  TestLoadHardLinkOrder;
  TestPathRoundTrip;
  TestSortedChildren;
  TestMergeAndRemoveChild;
  if Failures = 0 then
  begin
    WriteLn('All FileTree tests passed.');
    Halt(0);
  end;
  WriteLn(Failures, ' failure(s).');
  Halt(1);
end.
