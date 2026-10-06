{ OpenDisk FileTree — packed sibling/child directory tree.

  Port of the Swift FileTree model: each node stores size, parent,
  first-child and next-sibling links. Directories roll sizes up after a
  scan. Hard-link keys are recorded so allocated bytes count once. }

unit FileTree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TNodeID = LongInt;

const
  NoNode: TNodeID = -1;
  RootID: TNodeID = 0;

type
  THardLinkKey = record
    Device: QWord;
    FileID: QWord;
  end;

  TBooleanArray = array of Boolean;

  TFileTree = class
  private
    type
      THardLink = record
        Key: THardLinkKey;
        AllocatedSize: Int64;
      end;
      TNode = record
        Size: Int64;
        Parent: TNodeID;
        FirstChild: TNodeID;
        NextSibling: TNodeID;
        IsDirectory: Boolean;
      end;
    var
      FNodes: array of TNode;
      FNames: array of string;
      FHardLinks: array of THardLink;
      FHardLinkIDs: array of TNodeID;
      FHardLinkCount: Integer;
    function SearchHardLink(ID: TNodeID): Integer;
    function FindHardLinkIndex(ID: TNodeID): Integer;
  public
    constructor Create(const RootName: string);
    procedure ReserveCapacity(Count: Integer);
    function AddNode(const Name: string; Parent: TNodeID; Size: Int64;
      IsDirectory: Boolean): TNodeID;
    function AppendUnlinked(const Name: string; Size: Int64;
      IsDirectory: Boolean): TNodeID;
    procedure Link(ID, Parent: TNodeID);
    procedure RecordHardLink(ID: TNodeID; const Key: THardLinkKey;
      AllocatedSize: Int64);
    procedure RollUpDirectorySizes;
    { Zeroes every directory's size before a fresh roll-up. }
    procedure ResetDirectorySizes;
    function NodeCount: Integer;
    function NameOf(ID: TNodeID): string;
    function SizeOf(ID: TNodeID): Int64;
    function IsDirectory(ID: TNodeID): Boolean;
    function ParentOf(ID: TNodeID): TNodeID;
    function ChildCount(ID: TNodeID): Integer;
    function ChildNamed(ID: TNodeID; const Name: string): TNodeID;
    function PathOf(ID: TNodeID): string;
    function NodeIDForPath(const Path, RootPath: string): TNodeID;
    procedure ChildrenOf(ID: TNodeID; Dest: TFPList);
    procedure RemoveAllChildren(Parent: TNodeID);
    procedure Relink(ID, Parent: TNodeID);
    procedure UpdateAllocatedSize(ID: TNodeID; Size: Int64);
    { Hard-link records, in ascending node ID order after NormalizeHardLinks. }
    function HardLinkCount: Integer;
    function HardLinkNodeAt(Index: Integer): TNodeID;
    function HardLinkKeyAt(Index: Integer): THardLinkKey;
    { Drops records for unreachable nodes and gives each key's allocated
      size to its lowest reachable node ID; other links get 0
      (FileTree.swift normalizeHardLinks). }
    procedure NormalizeHardLinks;
    { Reachable non-directory nodes whose size, or whose hard-link record
      when the node carries 0, is at least Minimum (FileTree.swift
      reachableFiles(allocatedAtLeast:)). }
    procedure ReachableFiles(AllocatedAtLeast: Int64; Dest: TFPList);
    { Per node: reachable from the root through child links (FileTree.swift
      reachabilityBitmap); detached nodes left by incremental updates are
      False. }
    function ReachabilityBitmap: TBooleanArray;
    { Hard-link record of ID, if any. }
    function HardLinkOf(ID: TNodeID; out Key: THardLinkKey;
      out AllocatedSize: Int64): Boolean;
    { Copies OtherNode and its descendants from Other under Parent;
      directories get size 0 until the next roll-up, hard-link records
      come along (FileTree.swift adoptSubtree). }
    procedure AdoptSubtree(Other: TFileTree; OtherNode, Parent: TNodeID);
    { Detaches Parent's child called Name and returns it, or NoNode
      (FileTree.swift removeChild(named:of:)). }
    function RemoveChildNamed(Parent: TNodeID; const Name: string): TNodeID;
    { Copies Other's root children into Directory: directories already
      present are merged recursively, a file in the way of a directory is
      replaced, anything else already present is kept (FileTree.swift
      merge(_:into:)). Sizes need a roll-up afterwards. }
    procedure Merge(Other: TFileTree; Directory: TNodeID);
    { The name (and so the path prefix) of the root node. }
    procedure SetRootName(const Name: string);
    { Fills Dest with direct children of ID, sorted largest-first. }
    procedure ChildrenSortedForDisplay(ID: TNodeID; Dest: TFPList);
    { Binary serialization — magic DMT3, matches Swift FileTree layout. }
    procedure WriteSerialized(Stream: TStream);
    class function LoadSerialized(Stream: TStream): TFileTree;
  end;

const
  FileTreeSerializationMagic: LongWord = $444D5433;

function HardLinkKeyEqual(const A, B: THardLinkKey): Boolean;

implementation

function HardLinkKeyEqual(const A, B: THardLinkKey): Boolean;
begin
  Result := (A.Device = B.Device) and (A.FileID = B.FileID);
end;

constructor TFileTree.Create(const RootName: string);
begin
  inherited Create;
  SetLength(FNodes, 1);
  SetLength(FNames, 1);
  FNodes[0].Size := 0;
  FNodes[0].Parent := NoNode;
  FNodes[0].FirstChild := NoNode;
  FNodes[0].NextSibling := NoNode;
  FNodes[0].IsDirectory := True;
  FNames[0] := RootName;
  FHardLinkCount := 0;
end;

procedure TFileTree.ReserveCapacity(Count: Integer);
begin
  if Length(FNodes) < Count then
  begin
    SetLength(FNodes, Count);
    SetLength(FNames, Count);
  end;
end;

function TFileTree.AppendUnlinked(const Name: string; Size: Int64;
  IsDirectory: Boolean): TNodeID;
var
  N: Integer;
begin
  N := Length(FNodes);
  SetLength(FNodes, N + 1);
  SetLength(FNames, N + 1);
  FNodes[N].Size := Size;
  FNodes[N].Parent := NoNode;
  FNodes[N].FirstChild := NoNode;
  FNodes[N].NextSibling := NoNode;
  FNodes[N].IsDirectory := IsDirectory;
  FNames[N] := Name;
  Result := N;
end;

procedure TFileTree.Link(ID, Parent: TNodeID);
begin
  FNodes[ID].Parent := Parent;
  FNodes[ID].NextSibling := FNodes[Parent].FirstChild;
  FNodes[Parent].FirstChild := ID;
end;

function TFileTree.AddNode(const Name: string; Parent: TNodeID; Size: Int64;
  IsDirectory: Boolean): TNodeID;
begin
  Result := AppendUnlinked(Name, Size, IsDirectory);
  Link(Result, Parent);
end;

{ Records are kept in ascending node ID order (Swift keys them by NodeID),
  so lookups are a binary search. Returns the index of ID, or -(insertion
  point + 1) when absent. }
function TFileTree.SearchHardLink(ID: TNodeID): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := FHardLinkCount - 1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FHardLinkIDs[Mid] = ID then
      Exit(Mid);
    if FHardLinkIDs[Mid] < ID then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := -(Lo + 1);
end;

function TFileTree.FindHardLinkIndex(ID: TNodeID): Integer;
begin
  Result := SearchHardLink(ID);
  if Result < 0 then
    Result := -1;
end;

procedure TFileTree.RecordHardLink(ID: TNodeID; const Key: THardLinkKey;
  AllocatedSize: Int64);
var
  Idx, I: Integer;
begin
  { New nodes get the highest ID so far: the common case appends. }
  if (FHardLinkCount > 0) and (FHardLinkIDs[FHardLinkCount - 1] < ID) then
    Idx := -(FHardLinkCount + 1)
  else
    Idx := SearchHardLink(ID);
  if Idx < 0 then
  begin
    Idx := -(Idx + 1);
    Inc(FHardLinkCount);
    if Length(FHardLinks) < FHardLinkCount then
    begin
      SetLength(FHardLinks, FHardLinkCount * 2 + 8);
      SetLength(FHardLinkIDs, Length(FHardLinks));
    end;
    for I := FHardLinkCount - 1 downto Idx + 1 do
    begin
      FHardLinkIDs[I] := FHardLinkIDs[I - 1];
      FHardLinks[I] := FHardLinks[I - 1];
    end;
    FHardLinkIDs[Idx] := ID;
  end;
  FHardLinks[Idx].Key := Key;
  FHardLinks[Idx].AllocatedSize := AllocatedSize;
end;

function TFileTree.ReachabilityBitmap: TBooleanArray;
var
  Stack: array of TNodeID;
  Top: Integer;
  Current, Child: TNodeID;
begin
  SetLength(Result, Length(FNodes));
  if Length(FNodes) = 0 then
    Exit;
  SetLength(Stack, Length(FNodes));
  Result[RootID] := True;
  Stack[0] := RootID;
  Top := 0;
  while Top >= 0 do
  begin
    Current := Stack[Top];
    Dec(Top);
    Child := FNodes[Current].FirstChild;
    while Child <> NoNode do
    begin
      if not Result[Child] then
      begin
        Result[Child] := True;
        Inc(Top);
        Stack[Top] := Child;
      end;
      Child := FNodes[Child].NextSibling;
    end;
  end;
end;

procedure TFileTree.ReachableFiles(AllocatedAtLeast: Int64; Dest: TFPList);
var
  Reachable: TBooleanArray;
  I, Idx: Integer;
begin
  Dest.Clear;
  Reachable := ReachabilityBitmap;
  for I := 0 to High(FNodes) do
  begin
    if (not Reachable[I]) or FNodes[I].IsDirectory then
      Continue;
    if FNodes[I].Size >= AllocatedAtLeast then
      Dest.Add(Pointer(PtrUInt(I)))
    else if FNodes[I].Size = 0 then
    begin
      Idx := FindHardLinkIndex(I);
      if (Idx >= 0) and (FHardLinks[Idx].AllocatedSize >= AllocatedAtLeast) then
        Dest.Add(Pointer(PtrUInt(I)));
    end;
  end;
end;

function TFileTree.HardLinkOf(ID: TNodeID; out Key: THardLinkKey;
  out AllocatedSize: Int64): Boolean;
var
  Idx: Integer;
begin
  Idx := FindHardLinkIndex(ID);
  Result := Idx >= 0;
  if Result then
  begin
    Key := FHardLinks[Idx].Key;
    AllocatedSize := FHardLinks[Idx].AllocatedSize;
  end
  else
  begin
    Key.Device := 0;
    Key.FileID := 0;
    AllocatedSize := 0;
  end;
end;

function TFileTree.RemoveChildNamed(Parent: TNodeID; const Name: string): TNodeID;
var
  Previous, Current: TNodeID;
begin
  Previous := NoNode;
  Current := FNodes[Parent].FirstChild;
  while Current <> NoNode do
  begin
    if FNames[Current] = Name then
    begin
      if Previous = NoNode then
        FNodes[Parent].FirstChild := FNodes[Current].NextSibling
      else
        FNodes[Previous].NextSibling := FNodes[Current].NextSibling;
      FNodes[Current].Parent := NoNode;
      FNodes[Current].NextSibling := NoNode;
      Exit(Current);
    end;
    Previous := Current;
    Current := FNodes[Current].NextSibling;
  end;
  Result := NoNode;
end;

procedure TFileTree.Merge(Other: TFileTree; Directory: TNodeID);

  procedure MergeChildren(Into, OtherDirectory: TNodeID);
  var
    Kids: TFPList;
    I: Integer;
    OtherChild, Existing: TNodeID;
    ChildName: string;
  begin
    Kids := TFPList.Create;
    try
      Other.ChildrenOf(OtherDirectory, Kids);
      for I := 0 to Kids.Count - 1 do
      begin
        OtherChild := TNodeID(PtrUInt(Kids[I]));
        ChildName := Other.NameOf(OtherChild);
        Existing := ChildNamed(Into, ChildName);
        if Other.IsDirectory(OtherChild) and (Existing <> NoNode) then
        begin
          if IsDirectory(Existing) then
            MergeChildren(Existing, OtherChild)
          else
          begin
            RemoveChildNamed(Into, ChildName);
            AdoptSubtree(Other, OtherChild, Into);
          end;
        end
        else if Existing = NoNode then
          AdoptSubtree(Other, OtherChild, Into);
      end;
    finally
      Kids.Free;
    end;
  end;

begin
  MergeChildren(Directory, RootID);
end;

procedure TFileTree.SetRootName(const Name: string);
begin
  FNames[RootID] := Name;
end;

procedure TFileTree.AdoptSubtree(Other: TFileTree; OtherNode, Parent: TNodeID);
type
  TWork = record
    Source: TNodeID;
    NewParent: TNodeID;
  end;
var
  Stack: array of TWork;
  Top: Integer;
  Item: TWork;
  Copy_, Child: TNodeID;
  Key: THardLinkKey;
  Allocated, Size: Int64;
begin
  SetLength(Stack, 64);
  Top := 0;
  Stack[0].Source := OtherNode;
  Stack[0].NewParent := Parent;
  while Top >= 0 do
  begin
    Item := Stack[Top];
    Dec(Top);
    if Other.IsDirectory(Item.Source) then
      Size := 0
    else
      Size := Other.SizeOf(Item.Source);
    Copy_ := AddNode(Other.NameOf(Item.Source), Item.NewParent, Size,
      Other.IsDirectory(Item.Source));
    if Other.HardLinkOf(Item.Source, Key, Allocated) then
      RecordHardLink(Copy_, Key, Allocated);
    Child := Other.FNodes[Item.Source].FirstChild;
    while Child <> NoNode do
    begin
      Inc(Top);
      if Top >= Length(Stack) then
        SetLength(Stack, Length(Stack) * 2);
      Stack[Top].Source := Child;
      Stack[Top].NewParent := Copy_;
      Child := Other.FNodes[Child].NextSibling;
    end;
  end;
end;

procedure TFileTree.ResetDirectorySizes;
var
  I: Integer;
begin
  for I := 0 to High(FNodes) do
    if FNodes[I].IsDirectory then
      FNodes[I].Size := 0;
end;

procedure TFileTree.RollUpDirectorySizes;
var
  Count, I: Integer;
  Visited: array of Boolean;
  Order: array of TNodeID;
  Stack: array of TNodeID;
  StackTop, OrderLen: Integer;
  Current, Child, Parent: TNodeID;
begin
  Count := Length(FNodes);
  SetLength(Visited, Count);
  SetLength(Order, Count);
  SetLength(Stack, Count);
  for I := 0 to Count - 1 do
    Visited[I] := False;
  StackTop := 0;
  OrderLen := 0;
  Stack[0] := RootID;
  Visited[RootID] := True;
  while StackTop >= 0 do
  begin
    Current := Stack[StackTop];
    Dec(StackTop);
    Order[OrderLen] := Current;
    Inc(OrderLen);
    Child := FNodes[Current].FirstChild;
    while Child <> NoNode do
    begin
      if not Visited[Child] then
      begin
        Visited[Child] := True;
        Inc(StackTop);
        Stack[StackTop] := Child;
      end;
      Child := FNodes[Child].NextSibling;
    end;
  end;
  for I := OrderLen - 1 downto 0 do
  begin
    Current := Order[I];
    if Current = RootID then
      Continue;
    Parent := FNodes[Current].Parent;
    if Parent <> NoNode then
      FNodes[Parent].Size := FNodes[Parent].Size + FNodes[Current].Size;
  end;
end;

function TFileTree.NodeCount: Integer;
begin
  Result := Length(FNodes);
end;

function TFileTree.NameOf(ID: TNodeID): string;
begin
  Result := FNames[ID];
end;

function TFileTree.SizeOf(ID: TNodeID): Int64;
begin
  Result := FNodes[ID].Size;
end;

function TFileTree.IsDirectory(ID: TNodeID): Boolean;
begin
  Result := FNodes[ID].IsDirectory;
end;

function TFileTree.ParentOf(ID: TNodeID): TNodeID;
begin
  Result := FNodes[ID].Parent;
end;

function TFileTree.ChildCount(ID: TNodeID): Integer;
var
  Current: TNodeID;
  Remaining: Integer;
begin
  Result := 0;
  Remaining := Length(FNodes);
  Current := FNodes[ID].FirstChild;
  while (Current <> NoNode) and (Remaining > 0) do
  begin
    Dec(Remaining);
    Inc(Result);
    Current := FNodes[Current].NextSibling;
  end;
end;

function TFileTree.ChildNamed(ID: TNodeID; const Name: string): TNodeID;
var
  Current: TNodeID;
  Remaining: Integer;
begin
  Remaining := Length(FNodes);
  Current := FNodes[ID].FirstChild;
  while (Current <> NoNode) and (Remaining > 0) do
  begin
    Dec(Remaining);
    if FNames[Current] = Name then
      Exit(Current);
    Current := FNodes[Current].NextSibling;
  end;
  Result := NoNode;
end;

function TFileTree.PathOf(ID: TNodeID): string;
var
  Parts: TStringList;
  Current: TNodeID;
  Remaining: Integer;
  I: Integer;
begin
  if ID = RootID then
    Exit(FNames[0]);
  Parts := TStringList.Create;
  try
    Remaining := Length(FNodes);
    Current := ID;
    while (Current <> RootID) and (Current <> NoNode) and (Remaining > 0) do
    begin
      Dec(Remaining);
      Parts.Add(FNames[Current]);
      Current := FNodes[Current].Parent;
    end;
    Result := FNames[0];
    if (Length(Result) = 0) or (Result[Length(Result)] <> DirectorySeparator) then
      if Result <> DirectorySeparator then
        Result := Result + DirectorySeparator;
    for I := Parts.Count - 1 downto 0 do
    begin
      Result := Result + Parts[I];
      if I > 0 then
        Result := Result + DirectorySeparator;
    end;
  finally
    Parts.Free;
  end;
end;

function TFileTree.NodeIDForPath(const Path, RootPath: string): TNodeID;
var
  Prefix, Rest, Part: string;
  Current: TNodeID;
  I, Start: Integer;
begin
  if Path = RootPath then
    Exit(RootID);
  Prefix := IncludeTrailingPathDelimiter(RootPath);
  if (Length(Path) < Length(Prefix)) or
     (Copy(Path, 1, Length(Prefix)) <> Prefix) then
    Exit(NoNode);
  Rest := Copy(Path, Length(Prefix) + 1, MaxInt);
  Current := RootID;
  Start := 1;
  for I := 1 to Length(Rest) + 1 do
  begin
    if (I > Length(Rest)) or (Rest[I] = DirectorySeparator) then
    begin
      if I > Start then
      begin
        Part := Copy(Rest, Start, I - Start);
        Current := ChildNamed(Current, Part);
        if Current = NoNode then
          Exit(NoNode);
      end;
      Start := I + 1;
    end;
  end;
  Result := Current;
end;

procedure TFileTree.ChildrenOf(ID: TNodeID; Dest: TFPList);
var
  Current: TNodeID;
  Remaining: Integer;
begin
  Dest.Clear;
  Remaining := Length(FNodes);
  Current := FNodes[ID].FirstChild;
  while (Current <> NoNode) and (Remaining > 0) do
  begin
    Dec(Remaining);
    Dest.Add(Pointer(PtrInt(Current)));
    Current := FNodes[Current].NextSibling;
  end;
end;

procedure TFileTree.RemoveAllChildren(Parent: TNodeID);
var
  Current, Next: TNodeID;
begin
  Current := FNodes[Parent].FirstChild;
  while Current <> NoNode do
  begin
    Next := FNodes[Current].NextSibling;
    FNodes[Current].Parent := NoNode;
    FNodes[Current].NextSibling := NoNode;
    Current := Next;
  end;
  FNodes[Parent].FirstChild := NoNode;
end;

procedure TFileTree.Relink(ID, Parent: TNodeID);
begin
  Link(ID, Parent);
end;

procedure TFileTree.UpdateAllocatedSize(ID: TNodeID; Size: Int64);
var
  Idx: Integer;
begin
  Idx := FindHardLinkIndex(ID);
  if Idx >= 0 then
    FHardLinks[Idx].AllocatedSize := Size
  else
    FNodes[ID].Size := Size;
end;

function TFileTree.HardLinkCount: Integer;
begin
  Result := FHardLinkCount;
end;

function TFileTree.HardLinkNodeAt(Index: Integer): TNodeID;
begin
  Result := FHardLinkIDs[Index];
end;

function TFileTree.HardLinkKeyAt(Index: Integer): THardLinkKey;
begin
  Result := FHardLinks[Index].Key;
end;

function CompareHardLinkKeys(const A, B: THardLinkKey): Integer;
begin
  if A.Device < B.Device then Exit(-1);
  if A.Device > B.Device then Exit(1);
  if A.FileID < B.FileID then Exit(-1);
  if A.FileID > B.FileID then Exit(1);
  Result := 0;
end;

procedure TFileTree.NormalizeHardLinks;
var
  Reachable: array of Boolean;
  Stack: array of TNodeID;
  Order: array of Integer;
  StackTop, I, J, Kept, Run: Integer;
  Current, Child, TmpID: TNodeID;
  TmpLink: THardLink;

  function Less(A, B: Integer): Boolean;
  var
    Cmp: Integer;
  begin
    Cmp := CompareHardLinkKeys(FHardLinks[A].Key, FHardLinks[B].Key);
    if Cmp <> 0 then
      Exit(Cmp < 0);
    Result := FHardLinkIDs[A] < FHardLinkIDs[B];
  end;

  procedure SortOrder(L, R: Integer);
  var
    Lo, Hi, Pivot, Tmp: Integer;
  begin
    while L < R do
    begin
      Lo := L;
      Hi := R;
      Pivot := Order[(L + R) div 2];
      repeat
        while Less(Order[Lo], Pivot) do Inc(Lo);
        while Less(Pivot, Order[Hi]) do Dec(Hi);
        if Lo <= Hi then
        begin
          Tmp := Order[Lo];
          Order[Lo] := Order[Hi];
          Order[Hi] := Tmp;
          Inc(Lo);
          Dec(Hi);
        end;
      until Lo > Hi;
      if Hi - L < R - Lo then
      begin
        SortOrder(L, Hi);
        L := Lo;
      end
      else
      begin
        SortOrder(Lo, R);
        R := Hi;
      end;
    end;
  end;

begin
  if FHardLinkCount = 0 then
    Exit;

  SetLength(Reachable, Length(FNodes));
  SetLength(Stack, Length(FNodes));
  Reachable[RootID] := True;
  Stack[0] := RootID;
  StackTop := 0;
  while StackTop >= 0 do
  begin
    Current := Stack[StackTop];
    Dec(StackTop);
    Child := FNodes[Current].FirstChild;
    while Child <> NoNode do
    begin
      if not Reachable[Child] then
      begin
        Reachable[Child] := True;
        Inc(StackTop);
        Stack[StackTop] := Child;
      end;
      Child := FNodes[Child].NextSibling;
    end;
  end;

  { Drop unreachable records. RecordHardLink keeps ascending node ID order;
    the insertion sort only re-checks that invariant (linear when sorted). }
  Kept := 0;
  for I := 0 to FHardLinkCount - 1 do
    if Reachable[FHardLinkIDs[I]] then
    begin
      TmpID := FHardLinkIDs[I];
      TmpLink := FHardLinks[I];
      J := Kept - 1;
      while (J >= 0) and (FHardLinkIDs[J] > TmpID) do
      begin
        FHardLinkIDs[J + 1] := FHardLinkIDs[J];
        FHardLinks[J + 1] := FHardLinks[J];
        Dec(J);
      end;
      FHardLinkIDs[J + 1] := TmpID;
      FHardLinks[J + 1] := TmpLink;
      Inc(Kept);
    end;
  FHardLinkCount := Kept;
  if Kept = 0 then
    Exit;

  { Group by key; the lowest node ID in each group carries the bytes. }
  SetLength(Order, Kept);
  for I := 0 to Kept - 1 do
    Order[I] := I;
  SortOrder(0, Kept - 1);
  Run := 0;
  for I := 0 to Kept - 1 do
  begin
    if (I = 0) or
       (CompareHardLinkKeys(FHardLinks[Order[I]].Key,
         FHardLinks[Order[Run]].Key) <> 0) then
    begin
      Run := I;
      FNodes[FHardLinkIDs[Order[I]]].Size := FHardLinks[Order[I]].AllocatedSize;
    end
    else
      FNodes[FHardLinkIDs[Order[I]]].Size := 0;
  end;
end;

type
  PSortItem = ^TSortItem;
  TSortItem = record
    ID: TNodeID;
    Size: Int64;
    Name: string;
  end;

function SortItemCompare(Item1, Item2: Pointer): Integer;
var
  A, B: PSortItem;
begin
  A := PSortItem(Item1);
  B := PSortItem(Item2);
  if A^.Size = B^.Size then
  begin
    if A^.Name < B^.Name then
      Result := -1
    else if A^.Name > B^.Name then
      Result := 1
    else
      Result := 0;
  end
  else if A^.Size > B^.Size then
    Result := -1
  else
    Result := 1;
end;

procedure TFileTree.ChildrenSortedForDisplay(ID: TNodeID; Dest: TFPList);
var
  Current: TNodeID;
  Remaining: Integer;
  Item: PSortItem;
  Temp: TFPList;
  I: Integer;
begin
  Dest.Clear;
  Temp := TFPList.Create;
  try
    Remaining := Length(FNodes);
    Current := FNodes[ID].FirstChild;
    while (Current <> NoNode) and (Remaining > 0) do
    begin
      Dec(Remaining);
      New(Item);
      Item^.ID := Current;
      Item^.Size := FNodes[Current].Size;
      Item^.Name := FNames[Current];
      Temp.Add(Item);
      Current := FNodes[Current].NextSibling;
    end;
    Temp.Sort(@SortItemCompare);
    for I := 0 to Temp.Count - 1 do
    begin
      Item := PSortItem(Temp[I]);
      Dest.Add(Pointer(PtrInt(Item^.ID)));
      Dispose(Item);
    end;
  finally
    Temp.Free;
  end;
end;

procedure WriteU32(Stream: TStream; Value: LongWord);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

procedure WriteI64(Stream: TStream; Value: Int64);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

procedure WriteI32(Stream: TStream; Value: LongInt);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

procedure WriteU64(Stream: TStream; Value: QWord);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

procedure TFileTree.WriteSerialized(Stream: TStream);
var
  Count, I, BlobLen: Integer;
  Flag: Byte;
  NameBytes: RawByteString;
begin
  Count := Length(FNodes);
  WriteU32(Stream, FileTreeSerializationMagic);
  WriteU32(Stream, LongWord(Count));
  for I := 0 to Count - 1 do
    WriteI64(Stream, FNodes[I].Size);
  for I := 0 to Count - 1 do
    WriteI32(Stream, FNodes[I].Parent);
  for I := 0 to Count - 1 do
    WriteI32(Stream, FNodes[I].FirstChild);
  for I := 0 to Count - 1 do
    WriteI32(Stream, FNodes[I].NextSibling);
  for I := 0 to Count - 1 do
  begin
    if FNodes[I].IsDirectory then
      Flag := 1
    else
      Flag := 0;
    Stream.WriteBuffer(Flag, 1);
  end;
  BlobLen := 0;
  for I := 0 to Count - 1 do
  begin
    NameBytes := RawByteString(FNames[I]);
    WriteU32(Stream, LongWord(Length(NameBytes)));
    Inc(BlobLen, Length(NameBytes));
  end;
  WriteU32(Stream, LongWord(BlobLen));
  for I := 0 to Count - 1 do
  begin
    NameBytes := RawByteString(FNames[I]);
    if Length(NameBytes) > 0 then
      Stream.WriteBuffer(NameBytes[1], Length(NameBytes));
  end;
  WriteU32(Stream, LongWord(FHardLinkCount));
  for I := 0 to FHardLinkCount - 1 do
    WriteI32(Stream, FHardLinkIDs[I]);
  for I := 0 to FHardLinkCount - 1 do
    WriteU64(Stream, FHardLinks[I].Key.Device);
  for I := 0 to FHardLinkCount - 1 do
    WriteU64(Stream, FHardLinks[I].Key.FileID);
  for I := 0 to FHardLinkCount - 1 do
    WriteI64(Stream, FHardLinks[I].AllocatedSize);
end;

function ReadU32(Stream: TStream): LongWord;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

function ReadI64(Stream: TStream): Int64;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

function ReadI32(Stream: TStream): LongInt;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

function ReadU64(Stream: TStream): QWord;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

class function TFileTree.LoadSerialized(Stream: TStream): TFileTree;
var
  Magic, Count32, BlobLen, LinkCount32: LongWord;
  Count, I, L, LinkCount: Integer;
  Flag: Byte;
  NameLens: array of LongWord;
  NameBytes: RawByteString;
  Bound: TNodeID;
  ID: TNodeID;
  J: Integer;
  Record_: THardLink;

  { Bytes left in Stream: like FileTree.swift readArray, every block is
    checked against it before reading, so a short or corrupt cache yields
    nil instead of a read error or a huge allocation. }
  function Left: Int64;
  begin
    Result := Stream.Size - Stream.Position;
  end;

begin
  Result := nil;
  try
  if Left < 8 then
    Exit;
  Magic := ReadU32(Stream);
  if Magic <> FileTreeSerializationMagic then
    Exit;
  Count32 := ReadU32(Stream);
  if Count32 = 0 then
    Exit;
  { Size, parent, first child, next sibling, flag and name length per node. }
  if (Count32 > LongWord(High(Integer))) or
    (Int64(Count32) * (8 + 4 + 4 + 4 + 1 + 4) + 4 > Left) then
    Exit;
  Count := Integer(Count32);
  Bound := Count;

  Result := TFileTree.Create('');
  SetLength(Result.FNodes, Count);
  SetLength(Result.FNames, Count);

  for I := 0 to Count - 1 do
    Result.FNodes[I].Size := ReadI64(Stream);
  for I := 0 to Count - 1 do
    Result.FNodes[I].Parent := ReadI32(Stream);
  for I := 0 to Count - 1 do
    Result.FNodes[I].FirstChild := ReadI32(Stream);
  for I := 0 to Count - 1 do
    Result.FNodes[I].NextSibling := ReadI32(Stream);
  for I := 0 to Count - 1 do
  begin
    Stream.ReadBuffer(Flag, 1);
    Result.FNodes[I].IsDirectory := Flag <> 0;
  end;

  SetLength(NameLens, Count);
  for I := 0 to Count - 1 do
    NameLens[I] := ReadU32(Stream);
  BlobLen := ReadU32(Stream);
  if Int64(BlobLen) > Left then
  begin
    FreeAndNil(Result);
    Exit;
  end;
  for I := 0 to Count - 1 do
  begin
    if (NameLens[I] > LongWord(High(Integer))) or (Int64(NameLens[I]) > Left) then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    L := Integer(NameLens[I]);
    SetLength(NameBytes, L);
    if L > 0 then
      Stream.ReadBuffer(NameBytes[1], L);
    Result.FNames[I] := string(NameBytes);
  end;

  for I := 0 to Count - 1 do
  begin
    if (Result.FNodes[I].Parent < NoNode) or (Result.FNodes[I].Parent >= Bound) then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    if (Result.FNodes[I].FirstChild < NoNode) or (Result.FNodes[I].FirstChild >= Bound) then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    if (Result.FNodes[I].NextSibling < NoNode) or (Result.FNodes[I].NextSibling >= Bound) then
    begin
      FreeAndNil(Result);
      Exit;
    end;
  end;

  if Left < 4 then
  begin
    FreeAndNil(Result);
    Exit;
  end;
  LinkCount32 := ReadU32(Stream);
  LinkCount := Integer(LinkCount32);
  if (LinkCount < 0) or (LinkCount > Count) or
    (Int64(LinkCount) * (4 + 8 + 8 + 8) > Left) then
  begin
    FreeAndNil(Result);
    Exit;
  end;
  Result.FHardLinkCount := LinkCount;
  SetLength(Result.FHardLinks, LinkCount);
  SetLength(Result.FHardLinkIDs, LinkCount);
  for I := 0 to LinkCount - 1 do
    Result.FHardLinkIDs[I] := ReadI32(Stream);
  for I := 0 to LinkCount - 1 do
    Result.FHardLinks[I].Key.Device := ReadU64(Stream);
  for I := 0 to LinkCount - 1 do
    Result.FHardLinks[I].Key.FileID := ReadU64(Stream);
  for I := 0 to LinkCount - 1 do
    Result.FHardLinks[I].AllocatedSize := ReadI64(Stream);
  for I := 0 to LinkCount - 1 do
  begin
    ID := Result.FHardLinkIDs[I];
    if (ID <= RootID) or (ID >= Bound) or Result.FNodes[ID].IsDirectory then
    begin
      FreeAndNil(Result);
      Exit;
    end;
  end;
  { Swift keys hard links by node ID, so file order carries no meaning;
    lookups here binary-search, so restore ascending ID order and refuse
    duplicate IDs. Writers emit sorted records, making this linear. }
  for I := 1 to LinkCount - 1 do
  begin
    ID := Result.FHardLinkIDs[I];
    Record_ := Result.FHardLinks[I];
    J := I - 1;
    while (J >= 0) and (Result.FHardLinkIDs[J] > ID) do
    begin
      Result.FHardLinkIDs[J + 1] := Result.FHardLinkIDs[J];
      Result.FHardLinks[J + 1] := Result.FHardLinks[J];
      Dec(J);
    end;
    Result.FHardLinkIDs[J + 1] := ID;
    Result.FHardLinks[J + 1] := Record_;
  end;
  for I := 1 to LinkCount - 1 do
    if Result.FHardLinkIDs[I] = Result.FHardLinkIDs[I - 1] then
    begin
      FreeAndNil(Result);
      Exit;
    end;
  except
    on EReadError do
      FreeAndNil(Result);
  end;
end;

end.
