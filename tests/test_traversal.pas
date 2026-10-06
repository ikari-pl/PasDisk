{ Traversal.ScanPath: hard links count once; symlinks are listed as leaf
  files and never followed (BulkDirectoryReader.swift treats every
  non-directory as a file); roll-up equals the sum of children. }

program test_traversal;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, FileTree, Traversal, PlatformFS, DirTypes, PlatformDirReader, PlatformVolumes;

var
  Fail: Boolean;
  Root: string;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Fail := True;
  end
  else
    WriteLn('ok: ', Msg);
end;

procedure WriteBytes(const Path: string; Count: Integer);
var
  F: TFileStream;
  Data: array of Byte;
begin
  SetLength(Data, Count);
  FillChar(Data[0], Count, 7);
  F := TFileStream.Create(Path, fmCreate);
  try
    F.WriteBuffer(Data[0], Count);
  finally
    F.Free;
  end;
end;

function Total: Int64;
var
  T: TFileTree;
begin
  T := ScanPath(Root);
  try
    Result := T.SizeOf(RootID);
  finally
    T.Free;
  end;
end;

procedure Cleanup(const Path: string);
var
  SR: TSearchRec;
  P: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile or faSymLink, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Path) + SR.Name;
      {$IFDEF UNIX}
      if fpReadLink(P) <> '' then
      begin
        fpUnlink(PChar(P));
        Continue;
      end;
      {$ENDIF}
      if (SR.Attr and faDirectory) <> 0 then
        Cleanup(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

var
  Before, WithLink, WithSymlinks: Int64;
  T: TFileTree;
  Dir: TNodeID;
  Kids: TFPList;
  I: Integer;
  Sum: Int64;
var
  CancelPolls, CancelAfter: Integer;

function CancelAfterPolls: Boolean;
begin
  Inc(CancelPolls);
  Result := CancelPolls > CancelAfter;
end;

procedure TestCancellation;
var
  Full, Part: TFileTree;
begin
  { TraversalScanner.swift isCancelled: polled per directory; a cancelled
    scan stops early and returns what it has. }
  Full := ScanPath(Root);
  try
    CancelPolls := 0;
    CancelAfter := 0;
    Part := ScanPath(Root, nil, nil, @CancelAfterPolls);
    try
      Expect(Part.NodeCount = 1, Format('cancelled at once: root only (%d nodes)', [Part.NodeCount]));
    finally
      Part.Free;
    end;
    CancelPolls := 0;
    CancelAfter := 1;
    Part := ScanPath(Root, nil, nil, @CancelAfterPolls);
    try
      Expect((Part.NodeCount > 1) and (Part.NodeCount < Full.NodeCount),
        Format('cancelled after one directory: partial tree (%d of %d nodes)',
          [Part.NodeCount, Full.NodeCount]));
    finally
      Part.Free;
    end;
    CancelPolls := 0;
    CancelAfter := MaxInt;
    Part := ScanPath(Root, nil, nil, @CancelAfterPolls);
    try
      Expect(Part.NodeCount = Full.NodeCount, 'never cancelled: full tree');
      Expect(CancelPolls >= 3, Format('polled once per directory (%d polls)', [CancelPolls]));
    finally
      Part.Free;
    end;
  finally
    Full.Free;
  end;
end;

procedure TestAllowedDevices;
var
  Devs: TDeviceSet;
  Data: string;
begin
  { ScanEngine.swift subtreeAllowedDevices: a scan of / also walks the Data
    volume behind the firmlinks; any other root stays on its own device. }
  Devs := SubtreeAllowedDevices('/');
  Expect(DeviceInSet(Devs, VolumeDeviceOf('/')), '/ allows its own device');
  Data := DataVolumeMountPoint;
  if Data <> '' then
    Expect(DeviceInSet(Devs, VolumeDeviceOf(Data)),
      '/ also allows the Data volume (' + Data + ')')
  else
    WriteLn('skip: no separate Data volume');
  Devs := SubtreeAllowedDevices(Root);
  Expect((Length(Devs) = 1) and (Devs[0] = VolumeDeviceOf(Root)),
    'a non-root scan allows only its own device');
end;

var
  CallerThread: TThreadID;
  OffThreadCalls: Integer;
  ProgressCalls: Integer;

procedure CheckThreadProgress(BytesScanned: Int64; ItemsScanned: Integer);
begin
  Inc(ProgressCalls);
  if GetCurrentThreadId <> CallerThread then
    Inc(OffThreadCalls);
end;

function CheckThreadCancelled: Boolean;
begin
  if GetCurrentThreadId <> CallerThread then
    Inc(OffThreadCalls);
  Result := False;
end;

function CancelAtOnce: Boolean;
begin
  Result := True;
end;

{ Every path with its size, plus totals. Which hard link carries the size
  depends on the visiting order (as in Swift), so hard-linked files and
  the folders holding them are compared by path only. }
function HoldsHardLink(T: TFileTree; Dir: TNodeID): Boolean;
var
  I: Integer;
  P: TNodeID;
  Key: THardLinkKey;
  Alloc: Int64;
begin
  for I := 1 to T.NodeCount - 1 do
    if T.HardLinkOf(I, Key, Alloc) then
    begin
      P := T.ParentOf(I);
      while P <> NoNode do
      begin
        if P = Dir then
          Exit(True);
        P := T.ParentOf(P);
      end;
    end;
  Result := False;
end;

function Fingerprint(T: TFileTree): string;
var
  L: TStringList;
  I: Integer;
  Key: THardLinkKey;
  Alloc: Int64;
begin
  L := TStringList.Create;
  try
    for I := 1 to T.NodeCount - 1 do
      if T.HardLinkOf(I, Key, Alloc) or (T.IsDirectory(I) and HoldsHardLink(T, I)) then
        L.Add(T.PathOf(I) + ' link')
      else
        L.Add(T.PathOf(I) + ' ' + IntToStr(T.SizeOf(I)));
    L.Sort;
    Result := Format('%d nodes, %d bytes|', [T.NodeCount, T.SizeOf(RootID)]) + L.Text;
  finally
    L.Free;
  end;
end;

{ TraversalScanner.swift: several workers build the same tree. }
procedure TestParallel;
var
  Base, D: string;
  I, J, Count: Integer;
  Seq, Par: TFileTree;
begin
  Base := Root + '/parallel';
  for I := 1 to 12 do
  begin
    D := Format('%s/d%d', [Base, I]);
    for J := 1 to I do
      D := D + '/n';
    ForceDirectories(D);
    for J := 1 to 20 do
      WriteBytes(Format('%s/f%d', [D, J]), 100 * J + I);
  end;
  {$IFDEF UNIX}
  WriteBytes(Base + '/d1/hard-a', 50000);
  fpLink(PChar(Base + '/d1/hard-a'), PChar(Base + '/d7/hard-b'));
  {$ENDIF}
  Seq := ScanPath(Base);
  CallerThread := GetCurrentThreadId;
  OffThreadCalls := 0;
  ProgressCalls := 0;
  Par := ScanPath(Base, @CheckThreadProgress, nil, @CheckThreadCancelled, @Count, 4);
  try
    Expect(Fingerprint(Par) = Fingerprint(Seq), 'parallel scan builds the same tree as one worker');
    Expect(Par.SizeOf(RootID) = Seq.SizeOf(RootID),
      Format('hard link counted once in parallel too (%d = %d)', [Par.SizeOf(RootID), Seq.SizeOf(RootID)]));
    Expect(Count = 0, 'no unreadable folders');
    Expect(ProgressCalls > 0, 'progress is reported');
    Expect(OffThreadCalls = 0, 'progress and cancellation run on the calling thread only');
  finally
    Seq.Free;
    Par.Free;
  end;
  Par := ScanPath(Base, nil, nil, @CancelAtOnce, nil, 4);
  try
    Expect(Par.NodeCount < 300, Format('cancelled parallel scan stops early (%d nodes)', [Par.NodeCount]));
  finally
    Par.Free;
  end;
  Expect((SubtreeWorkerCount >= 3) and (SubtreeWorkerCount <= 5) and
    (VolumeWorkerCount >= 4) and (VolumeWorkerCount <= 8), 'worker counts within Swift bounds');
end;

var
  Partials, PartialsOffThread, BadPartials: Integer;
  FinalNodes: Integer;

var
  Snapshots: array of TFileTree;
  SnapshotSubset: Boolean;

procedure KeepSnapshot(Tree: TFileTree);
begin
  SetLength(Snapshots, Length(Snapshots) + 1);
  Snapshots[High(Snapshots)] := Tree;
end;

procedure CountPartial(Tree: TFileTree);
begin
  Inc(Partials);
  if GetCurrentThreadId <> CallerThread then
    Inc(PartialsOffThread);
  if (Tree.NodeCount < 1) or (Tree.SizeOf(RootID) < 0) then
    Inc(BadPartials);
  Tree.Free;
end;

{ ScanEngine.swift partial snapshots, in both scan modes. }
procedure TestPartials;
var
  T: TFileTree;
  W: Integer;
  I, J: Integer;
begin
  SetSnapshotTiming(0, 0);
  try
    for W in [1, 4] do
    begin
      Partials := 0;
      PartialsOffThread := 0;
      BadPartials := 0;
      CallerThread := GetCurrentThreadId;
      T := ScanPath(Root + '/parallel', nil, nil, nil, nil, W, @CountPartial);
      try
        Expect(Partials > 0, Format('%d worker(s): snapshots published (%d)', [W, Partials]));
        Expect(PartialsOffThread = 0, Format('%d worker(s): snapshots on the calling thread', [W]));
        Expect(BadPartials = 0, Format('%d worker(s): snapshots are valid trees', [W]));
      finally
        T.Free;
      end;
    end;
  finally
    SetSnapshotTiming(500, 15000);
  end;
  Partials := 0;
  T := ScanPath(Root + '/parallel', nil, nil, nil, nil, 4, @CountPartial);
  T.Free;
  Expect(Partials = 0, 'a scan shorter than 500 ms publishes no snapshot');

  { Backoff: 8x the time a snapshot took, between 500 ms and 15 s. }
  Expect(SnapshotDelayAfter(0) = 500, 'backoff floor 500 ms');
  Expect(SnapshotDelayAfter(100) = 800, 'backoff 8x');
  Expect(SnapshotDelayAfter(5000) = 15000, 'backoff ceiling 15 s');

  { Content and lifetime: each snapshot is a subset of the final tree and
    belongs to the callee (changing it leaves the scan untouched). }
  SetSnapshotTiming(0, 0);
  try
    SnapshotSubset := True;
    T := ScanPath(Root + '/parallel', nil, nil, nil, nil, 1, @KeepSnapshot);
    try
      for I := 0 to High(Snapshots) do
      begin
        if Snapshots[I].SizeOf(RootID) > T.SizeOf(RootID) then
          SnapshotSubset := False;
        for J := 1 to Snapshots[I].NodeCount - 1 do
          if T.NodeIDForPath(Snapshots[I].PathOf(J), T.NameOf(RootID)) = NoNode then
            SnapshotSubset := False;
        Snapshots[I].AddNode('callee-owned', RootID, 1, False);
      end;
      Expect(Length(Snapshots) > 0, 'snapshots kept by the callee');
      Expect(SnapshotSubset, 'every snapshot path and size is within the final tree');
      Expect(T.ChildNamed(RootID, 'callee-owned') = NoNode,
        'changing a snapshot does not touch the scan');
    finally
      T.Free;
      for I := 0 to High(Snapshots) do
        Snapshots[I].Free;
      Snapshots := nil;
    end;
  finally
    SetSnapshotTiming(500, 15000);
  end;
end;

{ ScanMetrics.swift unreadableDirectories: folders that cannot be listed,
  the root included. }
procedure TestUnreadable;
{$IFDEF UNIX}
var
  T: TFileTree;
  Count: Integer;
  Base: string;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Base := Root + '/unreadable';
  ForceDirectories(Base + '/locked/inner');
  ForceDirectories(Base + '/open');
  fpChmod(PChar(Base + '/locked'), &000);
  T := ScanPath(Base, nil, nil, nil, @Count);
  T.Free;
  Expect(Count = 1, Format('one locked folder counts once (%d)', [Count]));
  T := ScanPath(Base + '/locked', nil, nil, nil, @Count);
  Expect((Count = 1) and (T.NodeCount = 1),
    Format('an unreadable root counts and yields no items (%d)', [Count]));
  T.Free;
  T := ScanPath(Base + '/open', nil, nil, nil, @Count);
  T.Free;
  Expect(Count = 0, 'a readable tree has no unreadable folders');
  fpChmod(PChar(Base + '/locked'), &755);
  {$ENDIF}
end;

begin
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_trav_' + IntToStr(GetProcessID);
  Cleanup(Root);
  ForceDirectories(Root + '/a/b');
  ForceDirectories(Root + '/outside-target');
  WriteBytes(Root + '/outside-target/big', 256 * 1024);
  try
    WriteBytes(Root + '/a/data', 100 * 1024);
    WriteBytes(Root + '/a/b/more', 50 * 1024);
    Before := Total;
    TestAllowedDevices;
    TestCancellation;

    Expect(CreateHardLink(Root + '/a/data', Root + '/a/b/data-link'), 'create hard link');
    WithLink := Total;
    Expect(WithLink = Before, Format('hard link counts once (%d = %d)', [WithLink, Before]));

    {$IFDEF UNIX}
    Expect(fpSymlink(PChar(Root + '/outside-target'), PChar(Root + '/a/dir-link')) = 0,
      'create directory symlink');
    Expect(fpSymlink(PChar(Root + '/outside-target/big'), PChar(Root + '/a/file-link')) = 0,
      'create file symlink');
    WithSymlinks := Total;
    Expect(WithSymlinks = WithLink,
      Format('symlinks add nothing and are not followed (%d = %d)', [WithSymlinks, WithLink]));
    {$ENDIF}

    T := ScanPath(Root + '/a');
    Kids := TFPList.Create;
    try
      {$IFDEF UNIX}
      Dir := T.ChildNamed(RootID, 'dir-link');
      Expect((Dir <> NoNode) and not T.IsDirectory(Dir) and (T.ChildCount(Dir) = 0),
        'directory symlink is a leaf file, not descended into');
      Dir := T.ChildNamed(RootID, 'file-link');
      Expect((Dir <> NoNode) and (T.SizeOf(Dir) < 256 * 1024),
        'file symlink counts its own size, not the target''s');
      {$ENDIF}
      Dir := T.ChildNamed(RootID, 'b');
      Expect((Dir <> NoNode) and T.IsDirectory(Dir), 'subdirectory is scanned');
      T.ChildrenOf(RootID, Kids);
      Sum := 0;
      for I := 0 to Kids.Count - 1 do
        Sum := Sum + T.SizeOf(TNodeID(PtrUInt(Kids[I])));
      Expect(Sum = T.SizeOf(RootID), 'directory size equals the sum of its children');
    finally
      Kids.Free;
      T.Free;
    end;
    TestUnreadable;
    TestParallel;
    TestPartials;
  finally
    Cleanup(Root);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_traversal: all passed');
end.
