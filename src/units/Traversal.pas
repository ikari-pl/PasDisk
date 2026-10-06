{ OpenDisk Traversal — directory scan into a FileTree.

  TraversalScanner.swift: a shared stack of directories; each worker pops
  one, reads it outside the lock (PlatformDirReader: getattrlistbulk on
  Darwin) and adds its entries under the lock. With one worker the scan
  runs on the calling thread, depth first. With several, the calling
  thread only coordinates: it reports progress every 33 ms and relays
  cancellation, so Progress and IsCancelled always run on the caller's
  thread. }

unit Traversal;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, contnrs, FileTree, DirTypes, PlatformDirReader, PlatformVolumes;

type
  TScanProgress = procedure(BytesScanned: Int64; ItemsScanned: Integer);
  { Polled once per directory; True stops the scan (TraversalScanner.swift
    isCancelled). }
  TScanCancelled = function: Boolean;

{ Scans Path without leaving AllowedDevices plus Path's own device
  (TraversalScanner.swift: allowedDevices.union([rootDevice])). When
  IsCancelled returns True the scan stops and the partial tree is returned;
  callers discard it, as ScanEngine.swift does. When Unreadable is given
  it receives the number of directories that could not be listed, the
  root included (ScanMetrics.swift unreadableDirectories). Workers > 1
  scans in parallel (child order then varies between runs). }
function ScanPath(const Path: string; Progress: TScanProgress = nil;
  const AllowedDevices: TDeviceSet = nil;
  IsCancelled: TScanCancelled = nil; Unreadable: PInteger = nil;
  Workers: Integer = 1): TFileTree;

{ TraversalScanner.swift worker counts: min(5, max(3, CPUs / 4)) for a
  subtree, min(8, max(4, CPUs / 2)) for a whole volume. }
function SubtreeWorkerCount: Integer;
function VolumeWorkerCount: Integer;
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
  RootDevice := VolumeDeviceOf(ScanRoot);
  if RootDevice = 0 then
    Exit;
  IncludeDevice(Result, RootDevice);
  if DataVolumeMountPoint = '' then
    Exit;
  SystemDevice := VolumeDeviceOf('/');
  DataDevice := VolumeDeviceOf(DataVolumeMountPoint);
  if (SystemDevice = RootDevice) and (DataDevice <> 0) then
    IncludeDevice(Result, DataDevice);
end;

function SubtreeWorkerCount: Integer;
begin
  Result := Min(5, Max(3, Integer(TThread.ProcessorCount) div 4));
end;

function VolumeWorkerCount: Integer;
begin
  Result := Min(8, Max(4, Integer(TThread.ProcessorCount) div 2));
end;

type
  { State shared by the workers of one parallel scan; every field but
    Cancelled is guarded by Lock. }
  TParallelScan = class
  public
    Lock: TRTLCriticalSection;
    WorkAvailable: PRTLEvent;
    Done: PRTLEvent;
    Stack: array of TWorkItem;
    Top: Integer;
    Busy: Integer;
    Finished: Boolean;
    Cancelled: Boolean;
    Tree: TFileTree;
    Seen: THardLinkSeen;
    Devices: TDeviceSet;
    Bytes: Int64;
    Items: Integer;
    Unreadable: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Push(const Item: TWorkItem);
  end;

  TScanWorker = class(TThread)
  private
    FScan: TParallelScan;
  protected
    procedure Execute; override;
  public
    constructor Create(Scan: TParallelScan);
  end;

constructor TParallelScan.Create;
begin
  inherited Create;
  InitCriticalSection(Lock);
  WorkAvailable := RTLEventCreate;
  Done := RTLEventCreate;
  SetLength(Stack, 64);
  Top := -1;
end;

destructor TParallelScan.Destroy;
begin
  RTLEventDestroy(WorkAvailable);
  RTLEventDestroy(Done);
  DoneCriticalSection(Lock);
  Seen.Free;
  inherited Destroy;
end;

procedure TParallelScan.Push(const Item: TWorkItem);
begin
  Inc(Top);
  if Top >= Length(Stack) then
    SetLength(Stack, Length(Stack) * 2);
  Stack[Top] := Item;
end;

constructor TScanWorker.Create(Scan: TParallelScan);
begin
  FScan := Scan;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TScanWorker.Execute;
var
  S: TParallelScan;
  Item, Child: TWorkItem;
  Read: TDirectoryReadResult;
  I: Integer;
  Size: Int64;
  Key: THardLinkKey;
  NodeID: TNodeID;
  Prefix: string;
  Pushed: Boolean;
begin
  S := FScan;
  repeat
    EnterCriticalSection(S.Lock);
    if S.Finished or ((S.Top < 0) and (S.Busy = 0)) then
    begin
      { Nothing queued and nobody left to queue more: the scan is over. }
      S.Finished := True;
      LeaveCriticalSection(S.Lock);
      RTLEventSetEvent(S.Done);
      RTLEventSetEvent(S.WorkAvailable);
      Exit;
    end;
    if S.Top < 0 then
    begin
      LeaveCriticalSection(S.Lock);
      { Woken by a push; the timeout covers a wake-up taken by another
        worker. }
      RTLEventWaitFor(S.WorkAvailable, 2);
      Continue;
    end;
    Item := S.Stack[S.Top];
    S.Stack[S.Top].Path := '';
    Dec(S.Top);
    Inc(S.Busy);
    LeaveCriticalSection(S.Lock);

    { Cancelled: drain the stack without reading, as Swift's workers do. }
    if S.Cancelled then
      Read.Kind := drkCrossesDevice
    else
      Read := ReadDirectory(Item.Path, S.Devices);
    Prefix := IncludeTrailingPathDelimiter(Item.Path);
    Pushed := False;

    EnterCriticalSection(S.Lock);
    try
      if Read.Kind = drkUnreadable then
        Inc(S.Unreadable);
      if Read.Kind = drkContents then
      begin
        for I := 0 to High(Read.Contents.Files) do
        begin
          Size := Read.Contents.Files[I].Size;
          if (Read.Contents.Files[I].LinkCount > 1) and
             (Read.Contents.Files[I].FileID > 0) then
          begin
            Key.Device := Read.Contents.Files[I].Device;
            Key.FileID := Read.Contents.Files[I].FileID;
            if not S.Seen.Insert(Key) then
              Size := 0;
            NodeID := S.Tree.AddNode(Read.Contents.Files[I].Name, Item.DirectoryID,
              Size, False);
            S.Tree.RecordHardLink(NodeID, Key, Read.Contents.Files[I].Size);
          end
          else
            S.Tree.AddNode(Read.Contents.Files[I].Name, Item.DirectoryID, Size, False);
          Inc(S.Bytes, Size);
          Inc(S.Items);
        end;
        for I := 0 to High(Read.Contents.SubdirectoryNames) do
        begin
          Child.DirectoryID := S.Tree.AddNode(Read.Contents.SubdirectoryNames[I],
            Item.DirectoryID, 0, True);
          Child.Path := Prefix + Read.Contents.SubdirectoryNames[I];
          S.Push(Child);
          Pushed := True;
          Inc(S.Items);
        end;
        for I := 0 to High(Read.Contents.MountPointNames) do
        begin
          S.Tree.AddNode(Read.Contents.MountPointNames[I], Item.DirectoryID, 0, True);
          Inc(S.Items);
        end;
      end;
      Dec(S.Busy);
    finally
      LeaveCriticalSection(S.Lock);
    end;
    if Pushed then
      RTLEventSetEvent(S.WorkAvailable);
  until False;
end;

function ParallelScan(const Path: string; Progress: TScanProgress;
  const AllowedDevices: TDeviceSet; IsCancelled: TScanCancelled;
  Unreadable: PInteger; Workers: Integer): TFileTree;
var
  S: TParallelScan;
  Threads: array of TScanWorker;
  RootDevice: QWord;
  Root: TWorkItem;
  I: Integer;
  Over: Boolean;
  Bytes: Int64;
  Items: Integer;
begin
  Result := TFileTree.Create(Path);
  if Unreadable <> nil then
    Unreadable^ := 0;
  RootDevice := VolumeDeviceOf(Path);
  if RootDevice = 0 then
  begin
    if Unreadable <> nil then
      Inc(Unreadable^);
    Exit;
  end;
  S := TParallelScan.Create;
  try
    S.Tree := Result;
    S.Seen := THardLinkSeen.Create;
    S.Devices := Copy(AllowedDevices);
    IncludeDevice(S.Devices, RootDevice);
    Root.DirectoryID := RootID;
    Root.Path := Path;
    S.Push(Root);
    S.Cancelled := Assigned(IsCancelled) and IsCancelled();

    SetLength(Threads, Workers);
    for I := 0 to Workers - 1 do
      Threads[I] := TScanWorker.Create(S);
    { ScanEngine.swift progressInterval: 33 ms. }
    repeat
      RTLEventWaitFor(S.Done, 33);
      EnterCriticalSection(S.Lock);
      Over := S.Finished;
      Bytes := S.Bytes;
      Items := S.Items;
      LeaveCriticalSection(S.Lock);
      if Assigned(Progress) then
        Progress(Bytes, Items);
      if (not S.Cancelled) and Assigned(IsCancelled) and IsCancelled() then
        S.Cancelled := True;
    until Over;
    for I := 0 to High(Threads) do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
    if Unreadable <> nil then
      Inc(Unreadable^, S.Unreadable);
    Result.RollUpDirectorySizes;
  finally
    S.Free;
  end;
end;

function ScanPath(const Path: string; Progress: TScanProgress;
  const AllowedDevices: TDeviceSet;
  IsCancelled: TScanCancelled; Unreadable: PInteger; Workers: Integer): TFileTree;
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
  if Workers > 1 then
    Exit(ParallelScan(Path, Progress, AllowedDevices, IsCancelled, Unreadable, Workers));
  Tree := TFileTree.Create(Path);
  Seen := THardLinkSeen.Create;
  Bytes := 0;
  Items := 0;
  if Unreadable <> nil then
    Unreadable^ := 0;
  try
    RootDevice := VolumeDeviceOf(Path);
    if RootDevice = 0 then
    begin
      if Unreadable <> nil then
        Inc(Unreadable^);
      Exit(Tree);
    end;
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
      begin
        if (Read.Kind = drkUnreadable) and (Unreadable <> nil) then
          Inc(Unreadable^);
        Continue;
      end;

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
    RootDevice := VolumeDeviceOf(Path);
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
