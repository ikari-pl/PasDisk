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
    function NodeCount: Integer;
    function NameOf(ID: TNodeID): string;
    function SizeOf(ID: TNodeID): Int64;
    function IsDirectory(ID: TNodeID): Boolean;
    function ParentOf(ID: TNodeID): TNodeID;
    function ChildCount(ID: TNodeID): Integer;
    function ChildNamed(ID: TNodeID; const Name: string): TNodeID;
    function PathOf(ID: TNodeID): string;
    { Fills Dest with direct children of ID, sorted largest-first. }
    procedure ChildrenSortedForDisplay(ID: TNodeID; Dest: TFPList);
  end;

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

function TFileTree.FindHardLinkIndex(ID: TNodeID): Integer;
var
  I: Integer;
begin
  for I := 0 to FHardLinkCount - 1 do
    if FHardLinkIDs[I] = ID then
      Exit(I);
  Result := -1;
end;

procedure TFileTree.RecordHardLink(ID: TNodeID; const Key: THardLinkKey;
  AllocatedSize: Int64);
var
  Idx: Integer;
begin
  Idx := FindHardLinkIndex(ID);
  if Idx < 0 then
  begin
    Idx := FHardLinkCount;
    Inc(FHardLinkCount);
    if Length(FHardLinks) < FHardLinkCount then
    begin
      SetLength(FHardLinks, FHardLinkCount * 2 + 8);
      SetLength(FHardLinkIDs, Length(FHardLinks));
    end;
    FHardLinkIDs[Idx] := ID;
  end;
  FHardLinks[Idx].Key := Key;
  FHardLinks[Idx].AllocatedSize := AllocatedSize;
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

end.
