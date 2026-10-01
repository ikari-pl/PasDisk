{ OpenDisk Traversal — depth-first directory scan into a FileTree.

  Single-threaded MVP. Worker pools and Darwin getattrlistbulk come next. }

unit Traversal;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileTree, DirReader;

type
  TScanProgress = procedure(BytesScanned: Int64; ItemsScanned: Integer);

function ScanPath(const Path: string; Progress: TScanProgress = nil): TFileTree;

implementation

type
  TWorkItem = record
    DirectoryID: TNodeID;
    Path: string;
  end;

  THardLinkSeen = class
  private
    FKeys: array of THardLinkKey;
    FCount: Integer;
  public
    function Insert(const Key: THardLinkKey): Boolean;
  end;

function THardLinkSeen.Insert(const Key: THardLinkKey): Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if HardLinkKeyEqual(FKeys[I], Key) then
      Exit(False);
  if Length(FKeys) <= FCount then
    SetLength(FKeys, FCount * 2 + 8);
  FKeys[FCount] := Key;
  Inc(FCount);
  Result := True;
end;

function ScanPath(const Path: string; Progress: TScanProgress): TFileTree;
var
  Tree: TFileTree;
  Stack: array of TWorkItem;
  StackTop: Integer;
  Seen: THardLinkSeen;
  RootDevice: QWord;
  Item: TWorkItem;
  Read: TDirectoryReadResult;
  I: Integer;
  Size: Int64;
  Key: THardLinkKey;
  NodeID: TNodeID;
  Prefix: string;
  Bytes: Int64;
  Items: Integer;
  Child: TWorkItem;
begin
  Tree := TFileTree.Create(Path);
  Seen := THardLinkSeen.Create;
  Bytes := 0;
  Items := 0;
  try
    RootDevice := DeviceIDOfPath(Path);
    if RootDevice = 0 then
      Exit(Tree);

    SetLength(Stack, 64);
    StackTop := 0;
    Stack[0].DirectoryID := RootID;
    Stack[0].Path := Path;

    while StackTop >= 0 do
    begin
      Item := Stack[StackTop];
      Dec(StackTop);

      Read := ReadDirectory(Item.Path, nil, True, RootDevice);
      if Read.Kind <> drkContents then
        Continue;

      Prefix := IncludeTrailingPathDelimiter(Item.Path);

      for I := 0 to High(Read.Contents.Files) do
      begin
        Size := Read.Contents.Files[I].Size;
        if (Read.Contents.Files[I].LinkCount > 1) and
           (Read.Contents.Files[I].FileID > 0) then
        begin
          Key.Device := Read.Contents.Files[I].Device;
          Key.FileID := Read.Contents.Files[I].FileID;
          if not Seen.Insert(Key) then
            Size := 0;
          NodeID := Tree.AddNode(Read.Contents.Files[I].Name, Item.DirectoryID,
            Size, False);
          Tree.RecordHardLink(NodeID, Key, Read.Contents.Files[I].Size);
        end
        else
          NodeID := Tree.AddNode(Read.Contents.Files[I].Name, Item.DirectoryID,
            Size, False);
        Bytes := Bytes + Size;
        Inc(Items);
      end;

      for I := 0 to High(Read.Contents.SubdirectoryNames) do
      begin
        NodeID := Tree.AddNode(Read.Contents.SubdirectoryNames[I],
          Item.DirectoryID, 0, True);
        Inc(StackTop);
        if StackTop >= Length(Stack) then
          SetLength(Stack, Length(Stack) * 2);
        Child.DirectoryID := NodeID;
        Child.Path := Prefix + Read.Contents.SubdirectoryNames[I];
        Stack[StackTop] := Child;
        Inc(Items);
      end;

      for I := 0 to High(Read.Contents.MountPointNames) do
      begin
        Tree.AddNode(Read.Contents.MountPointNames[I], Item.DirectoryID, 0, True);
        Inc(Items);
      end;

      if Assigned(Progress) then
        Progress(Bytes, Items);
    end;

    Tree.RollUpDirectorySizes;
  finally
    Seen.Free;
  end;
  Result := Tree;
end;

end.
