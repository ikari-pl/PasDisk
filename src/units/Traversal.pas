{ OpenDisk Traversal — depth-first directory scan into a FileTree.

  Single-threaded MVP. DirReader uses Darwin getattrlistbulk when available. }

unit Traversal;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, contnrs, FileTree, DirReader, PlatformVolumes;

type
  TScanProgress = procedure(BytesScanned: Int64; ItemsScanned: Integer);
  { Polled once per directory; True stops the scan (TraversalScanner.swift
    isCancelled). }
  TScanCancelled = function: Boolean;

{ Scans Path without leaving AllowedDevices plus Path's own device
  (TraversalScanner.swift: allowedDevices.union([rootDevice])). When
  IsCancelled returns True the scan stops and the partial tree is returned;
  callers discard it, as ScanEngine.swift does. }
function ScanPath(const Path: string; Progress: TScanProgress = nil;
  const AllowedDevices: TDeviceSet = nil;
  IsCancelled: TScanCancelled = nil): TFileTree;
{ Append a fresh scan of Path under ParentID (ParentID must already exist). }
function ScanInto(Tree: TFileTree; ParentID: TNodeID; const Path: string;
  Progress: TScanProgress = nil; const AllowedDevices: TDeviceSet = nil): Boolean;

{ ScanEngine.swift subtreeAllowedDevices(forScanRoot:): the root's device,
  plus the data volume when the root is on the system volume (firmlinked
  folders such as /Users live there). }
function SubtreeAllowedDevices(const ScanRoot: string): TDeviceSet;

implementation

type
  TWorkItem = record
    DirectoryID: TNodeID;
    Path: string;
  end;

  { Hard-link keys already counted in this scan (hash set). }
  THardLinkSeen = class
  private
    FKeys: TFPHashList;
  public
    constructor Create;
    destructor Destroy; override;
    { True when Key was not seen before. }
    function Insert(const Key: THardLinkKey): Boolean;
  end;

constructor THardLinkSeen.Create;
begin
  inherited Create;
  FKeys := TFPHashList.Create;
end;

destructor THardLinkSeen.Destroy;
begin
  FKeys.Free;
  inherited Destroy;
end;

function THardLinkSeen.Insert(const Key: THardLinkKey): Boolean;
var
  Name: ShortString;
begin
  Name := IntToHex(Key.Device, 16) + IntToHex(Key.FileID, 16);
  { TFPHashList cannot look up entries stored with nil data: store a
    non-nil marker and test membership with Find. }
  Result := FKeys.Find(Name) = nil;
  if Result then
    FKeys.Add(Name, Pointer(1));
end;

function SubtreeAllowedDevices(const ScanRoot: string): TDeviceSet;
var
  RootDevice, SystemDevice, DataDevice: QWord;
begin
  Result := nil;
  RootDevice := DeviceIDOfPath(ScanRoot);
  if RootDevice = 0 then
    Exit;
  IncludeDevice(Result, RootDevice);
  if DataVolumeMountPoint = '' then
    Exit;
  SystemDevice := DeviceIDOfPath('/');
  DataDevice := DeviceIDOfPath(DataVolumeMountPoint);
  if (SystemDevice = RootDevice) and (DataDevice <> 0) then
    IncludeDevice(Result, DataDevice);
end;

function ScanPath(const Path: string; Progress: TScanProgress;
  const AllowedDevices: TDeviceSet;
  IsCancelled: TScanCancelled): TFileTree;
var
  Devices: TDeviceSet;
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
    Devices := Copy(AllowedDevices);
    IncludeDevice(Devices, RootDevice);

    SetLength(Stack, 64);
    StackTop := 0;
    Stack[0].DirectoryID := RootID;
    Stack[0].Path := Path;

    while StackTop >= 0 do
    begin
      if Assigned(IsCancelled) and IsCancelled() then
        Break;
      Item := Stack[StackTop];
      Dec(StackTop);

      Read := ReadDirectory(Item.Path, Devices);
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

function ScanInto(Tree: TFileTree; ParentID: TNodeID; const Path: string;
  Progress: TScanProgress; const AllowedDevices: TDeviceSet): Boolean;
var
  Devices: TDeviceSet;
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
  Result := False;
  if (Tree = nil) or (ParentID = NoNode) then
    Exit;
  Seen := THardLinkSeen.Create;
  Bytes := 0;
  Items := 0;
  try
    RootDevice := DeviceIDOfPath(Path);
    { Gone since its parent was read: adopt an empty subtree, as Swift's
      TraversalScanner yields an empty tree (IncrementalUpdater.swift
      adoptScannedSubtree). }
    if RootDevice = 0 then
      Exit(True);
    Devices := Copy(AllowedDevices);
    IncludeDevice(Devices, RootDevice);

    SetLength(Stack, 64);
    StackTop := 0;
    Stack[0].DirectoryID := ParentID;
    Stack[0].Path := Path;

    while StackTop >= 0 do
    begin
      Item := Stack[StackTop];
      Dec(StackTop);

      Read := ReadDirectory(Item.Path, Devices);
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

    Result := True;
  finally
    Seen.Free;
  end;
end;

end.
