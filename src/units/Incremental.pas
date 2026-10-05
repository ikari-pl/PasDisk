{ Incremental — apply directory/subtree change lists to an existing FileTree.

  Port of OpenDisk IncrementalUpdater.swift: directory refresh, subtree
  rescan, and HardLinkPolicy. A hard link is accepted when its key is
  already in the cached tree or its file was born after the cache capture;
  otherwise ApplyChanges returns False and the caller must scan fully.
  Hard links are normalized afterwards so each inode counts once. }

unit Incremental;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileTree, DirReader, Traversal, PlatformFS;

type
  TChangeSet = record
    ChangedDirectories: TStringList;
    SubtreesToRescan: TStringList;
  end;

{ Applies the change set in place. Like IncrementalUpdater.apply, a False
  result can leave Tree partially updated: callers must discard it and run
  a full scan (ScanEngine.swift falls through to traverse). }
function ApplyChanges(Tree: TFileTree; const RootPath: string;
  const Changes: TChangeSet; CapturedAt: Double;
  Progress: TScanProgress = nil): Boolean;

implementation

type
  { Snapshot of hard-link keys known before the changes, plus the capture
    time (IncrementalUpdater.swift HardLinkPolicy). }
  THardLinkPolicy = class
  private
    FKnown: array of THardLinkKey;
    FCapturedAt: Double;
    function IsKnown(const Key: THardLinkKey): Boolean;
  public
    constructor Create(Tree: TFileTree; CapturedAt: Double);
    function Allows(const Key: THardLinkKey; const Path: string): Boolean;
  end;

function CompareKeys(const A, B: THardLinkKey): Integer;
begin
  if A.Device < B.Device then Exit(-1);
  if A.Device > B.Device then Exit(1);
  if A.FileID < B.FileID then Exit(-1);
  if A.FileID > B.FileID then Exit(1);
  Result := 0;
end;

constructor THardLinkPolicy.Create(Tree: TFileTree; CapturedAt: Double);
var
  I, J, K: Integer;
  Tmp: THardLinkKey;
begin
  inherited Create;
  FCapturedAt := CapturedAt;
  SetLength(FKnown, Tree.HardLinkCount);
  for I := 0 to High(FKnown) do
    FKnown[I] := Tree.HardLinkKeyAt(I);
  { Shell sort — keys arrive in node order, not key order. }
  J := Length(FKnown) div 2;
  while J > 0 do
  begin
    for I := J to High(FKnown) do
    begin
      Tmp := FKnown[I];
      K := I;
      while (K >= J) and (CompareKeys(FKnown[K - J], Tmp) > 0) do
      begin
        FKnown[K] := FKnown[K - J];
        Dec(K, J);
      end;
      FKnown[K] := Tmp;
    end;
    J := J div 2;
  end;
end;

function THardLinkPolicy.IsKnown(const Key: THardLinkKey): Boolean;
var
  Lo, Hi, Mid, Cmp: Integer;
begin
  Lo := 0;
  Hi := High(FKnown);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    Cmp := CompareKeys(FKnown[Mid], Key);
    if Cmp = 0 then
      Exit(True);
    if Cmp < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := False;
end;

function THardLinkPolicy.Allows(const Key: THardLinkKey;
  const Path: string): Boolean;
var
  Birth: Double;
begin
  Result := IsKnown(Key) or
    (FileBirthTime(Path, Birth) and (Birth > FCapturedAt));
end;

{ IncrementalUpdater.swift adoptScannedSubtree: scan Path into a separate
  tree, check every hard link in it against the policy, and only then copy
  its children under Node. A rejected subtree is never linked in. }
function AdoptScannedSubtree(Tree: TFileTree; const Path: string;
  Node: TNodeID; Policy: THardLinkPolicy; const AllowedDevices: TDeviceSet;
  Progress: TScanProgress): Boolean;
var
  Scanned: TFileTree;
  I: Integer;
  Kids: TFPList;
begin
  Scanned := ScanPath(Path, Progress, AllowedDevices);
  Kids := TFPList.Create;
  try
    for I := 0 to Scanned.HardLinkCount - 1 do
      if not Policy.Allows(Scanned.HardLinkKeyAt(I),
        Scanned.PathOf(Scanned.HardLinkNodeAt(I))) then
        Exit(False);
    Scanned.ChildrenOf(RootID, Kids);
    for I := 0 to Kids.Count - 1 do
      Tree.AdoptSubtree(Scanned, TNodeID(PtrUInt(Kids[I])), Node);
    Result := True;
  finally
    Kids.Free;
    Scanned.Free;
  end;
end;

function DepthOfPath(const Path: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(Path) do
    if Path[I] = DirectorySeparator then
      Inc(Result);
end;

{ Sort by path depth, shallow first, so parents are refreshed before their
  children; equal depths keep their original order (index tie-break).
  Depth is computed once per path. }
procedure SortPathsShallowFirst(List: TStringList);
var
  Depths: array of Integer;
  Order: array of Integer;
  Sorted: TStringList;
  I: Integer;

  function Before(A, B: Integer): Boolean;
  begin
    if Depths[A] <> Depths[B] then
      Exit(Depths[A] < Depths[B]);
    Result := A < B;
  end;

  procedure QSort(L, R: Integer);
  var
    Lo, Hi, Pivot, Tmp: Integer;
  begin
    while L < R do
    begin
      Lo := L;
      Hi := R;
      Pivot := Order[(L + R) div 2];
      repeat
        while Before(Order[Lo], Pivot) do Inc(Lo);
        while Before(Pivot, Order[Hi]) do Dec(Hi);
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
        QSort(L, Hi);
        L := Lo;
      end
      else
      begin
        QSort(Lo, R);
        R := Hi;
      end;
    end;
  end;

begin
  if List.Count < 2 then
    Exit;
  SetLength(Depths, List.Count);
  SetLength(Order, List.Count);
  for I := 0 to List.Count - 1 do
  begin
    Depths[I] := DepthOfPath(List[I]);
    Order[I] := I;
  end;
  QSort(0, List.Count - 1);
  Sorted := TStringList.Create;
  try
    for I := 0 to High(Order) do
      Sorted.Add(List[Order[I]]);
    List.Sorted := False;
    List.Assign(Sorted);
  finally
    Sorted.Free;
  end;
end;

{ IncrementalUpdater.swift resolveTarget: the directory node for Path, or
  NoNode when it is unknown, not a directory, or the root of another volume
  mounted inside the scan (never refreshed into the tree). }
function ResolveTarget(Tree: TFileTree; const RootPath, Path: string): TNodeID;
begin
  Result := NoNode;
  if (Path <> RootPath) and IsVolumeRoot(Path) then
    Exit;
  Result := Tree.NodeIDForPath(Path, RootPath);
  if (Result <> NoNode) and not Tree.IsDirectory(Result) then
    Result := NoNode;
end;

function UpdateDirectory(Tree: TFileTree; const RootPath, DirPath: string;
  Policy: THardLinkPolicy; const AllowedDevices: TDeviceSet;
  Progress: TScanProgress): Boolean;
var
  Node, Child, Existing: TNodeID;
  Read: TDirectoryReadResult;
  Surviving: TStringList;
  Kids: TFPList;
  I: Integer;
  Name: string;
  Prefix: string;
  FileEntry: TDirFileEntry;
  Key: THardLinkKey;
  NewID: TNodeID;
begin
  Result := True;
  Node := ResolveTarget(Tree, RootPath, DirPath);
  if Node = NoNode then
    Exit;

  Read := ReadDirectory(DirPath, AllowedDevices);
  if Read.Kind <> drkContents then
  begin
    Tree.RemoveAllChildren(Node);
    Exit;
  end;

  Prefix := IncludeTrailingPathDelimiter(DirPath);
  for I := 0 to High(Read.Contents.Files) do
  begin
    FileEntry := Read.Contents.Files[I];
    if (FileEntry.LinkCount > 1) and (FileEntry.FileID > 0) then
    begin
      Key.Device := FileEntry.Device;
      Key.FileID := FileEntry.FileID;
      if not Policy.Allows(Key, Prefix + FileEntry.Name) then
        Exit(False);
    end;
  end;

  Surviving := TStringList.Create;
  Kids := TFPList.Create;
  try
    Surviving.Sorted := True;
    Surviving.Duplicates := dupIgnore;
    Tree.ChildrenOf(Node, Kids);
    for I := 0 to Kids.Count - 1 do
    begin
      Child := TNodeID(PtrInt(Kids[I]));
      if Tree.IsDirectory(Child) then
        Surviving.AddObject(Tree.NameOf(Child), TObject(PtrInt(Child)));
    end;

    Tree.RemoveAllChildren(Node);

    for I := 0 to High(Read.Contents.Files) do
    begin
      FileEntry := Read.Contents.Files[I];
      if (FileEntry.LinkCount > 1) and (FileEntry.FileID > 0) then
      begin
        Key.Device := FileEntry.Device;
        Key.FileID := FileEntry.FileID;
        NewID := Tree.AddNode(FileEntry.Name, Node, FileEntry.Size, False);
        Tree.RecordHardLink(NewID, Key, FileEntry.Size);
      end
      else
        Tree.AddNode(FileEntry.Name, Node, FileEntry.Size, False);
    end;

    for I := 0 to High(Read.Contents.SubdirectoryNames) do
    begin
      Name := Read.Contents.SubdirectoryNames[I];
      if Surviving.IndexOf(Name) >= 0 then
      begin
        Existing := TNodeID(PtrInt(Surviving.Objects[Surviving.IndexOf(Name)]));
        Tree.Relink(Existing, Node);
      end
      else
      begin
        NewID := Tree.AddNode(Name, Node, 0, True);
        if not AdoptScannedSubtree(Tree, Prefix + Name, NewID, Policy,
          AllowedDevices, Progress) then
          Exit(False);
      end;
    end;

    for I := 0 to High(Read.Contents.MountPointNames) do
      Tree.AddNode(Read.Contents.MountPointNames[I], Node, 0, True);
  finally
    Kids.Free;
    Surviving.Free;
  end;
end;

function RescanSubtree(Tree: TFileTree; const RootPath, SubtreePath: string;
  Policy: THardLinkPolicy; const AllowedDevices: TDeviceSet;
  Progress: TScanProgress): Boolean;
var
  Node: TNodeID;
begin
  Result := True;
  Node := ResolveTarget(Tree, RootPath, SubtreePath);
  if Node = NoNode then
    Exit;
  Tree.RemoveAllChildren(Node);
  Result := AdoptScannedSubtree(Tree, SubtreePath, Node, Policy,
    AllowedDevices, Progress);
end;

function ApplyChanges(Tree: TFileTree; const RootPath: string;
  const Changes: TChangeSet; CapturedAt: Double;
  Progress: TScanProgress): Boolean;
var
  I: Integer;
  Policy: THardLinkPolicy;
  Devices: TDeviceSet;
begin
  Result := False;
  if Tree = nil then
    Exit;
  Devices := SubtreeAllowedDevices(RootPath);
  Policy := THardLinkPolicy.Create(Tree, CapturedAt);
  try
    if Changes.ChangedDirectories <> nil then
    begin
      SortPathsShallowFirst(Changes.ChangedDirectories);
      for I := 0 to Changes.ChangedDirectories.Count - 1 do
        if not UpdateDirectory(Tree, RootPath, Changes.ChangedDirectories[I],
          Policy, Devices, Progress) then
          Exit;
    end;
    if Changes.SubtreesToRescan <> nil then
      for I := 0 to Changes.SubtreesToRescan.Count - 1 do
        if not RescanSubtree(Tree, RootPath, Changes.SubtreesToRescan[I],
          Policy, Devices, Progress) then
          Exit;
  finally
    Policy.Free;
  end;
  Tree.NormalizeHardLinks;
  Tree.ResetDirectorySizes;
  Tree.RollUpDirectorySizes;
  Result := True;
end;

end.
