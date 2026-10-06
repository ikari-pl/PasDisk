{ Incremental ApplyChanges vs full scan — hard-link accounting.

  Mirrors OpenDisk IncrementalUpdater.swift: known hard-link keys are
  accepted and normalized so allocated bytes count once; an unknown key on
  a file born before the cache capture rejects the incremental apply. }

program test_incremental;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, FileTree, Traversal, Incremental, ChangeJournal, PlatformFS;

var
  Fail: Boolean;
  Root, Outside: string;

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
  FillChar(Data[0], Count, $5A);
  F := TFileStream.Create(Path, fmCreate);
  try
    F.WriteBuffer(Data[0], Count);
  finally
    F.Free;
  end;
end;

procedure HardLink(const Existing, NewPath: string);
begin
  if not CreateHardLink(Existing, NewPath) then
    raise Exception.CreateFmt('link %s -> %s failed', [NewPath, Existing]);
end;

procedure RemoveTree(const Path: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      if (SR.Attr and faDirectory) <> 0 then
        RemoveTree(IncludeTrailingPathDelimiter(Path) + SR.Name)
      else
        DeleteFile(IncludeTrailingPathDelimiter(Path) + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

function FullScanSize: Int64;
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

function ApplyTo(Tree: TFileTree; const Dirs, Subtrees: array of string;
  CapturedAt: Double): Boolean;
var
  Changes: TChangeSet;
  I: Integer;
begin
  Changes.ChangedDirectories := TStringList.Create;
  Changes.SubtreesToRescan := TStringList.Create;
  try
    for I := 0 to High(Dirs) do
      Changes.ChangedDirectories.Add(Dirs[I]);
    for I := 0 to High(Subtrees) do
      Changes.SubtreesToRescan.Add(Subtrees[I]);
    Result := ApplyChanges(Tree, Root, Changes, CapturedAt);
  finally
    Changes.ChangedDirectories.Free;
    Changes.SubtreesToRescan.Free;
  end;
end;

function Apply(Tree: TFileTree; const Dirs: array of string;
  CapturedAt: Double): Boolean;
var
  Changes: TChangeSet;
  I: Integer;
begin
  Changes.ChangedDirectories := TStringList.Create;
  Changes.SubtreesToRescan := TStringList.Create;
  try
    for I := 0 to High(Dirs) do
      Changes.ChangedDirectories.Add(Dirs[I]);
    Result := ApplyChanges(Tree, Root, Changes, CapturedAt);
  finally
    Changes.ChangedDirectories.Free;
    Changes.SubtreesToRescan.Free;
  end;
end;

procedure TestLateLinkToKnownInode;
var
  Tree: TFileTree;
  CapturedAt: Double;
  Expected: Int64;
begin
  WriteBytes(Root + '/big', 100 * 1024);
  CreateDir(Root + '/sub1');
  CreateDir(Root + '/sub3');
  HardLink(Root + '/big', Root + '/sub1/link1');
  WriteBytes(Root + '/sub3/small', 4096);

  Tree := ScanPath(Root);
  try
    CapturedAt := UnixTimeNow;
    Sleep(1100);
    HardLink(Root + '/big', Root + '/sub3/late-link');
    Expected := FullScanSize;
    Expect(Apply(Tree, [Root + '/sub3'], CapturedAt),
      'late link to known inode applies incrementally');
    Expect(Tree.SizeOf(RootID) = Expected,
      Format('late link counted once (incremental %d = full %d)',
        [Tree.SizeOf(RootID), Expected]));
    { Applying the same change again must be idempotent. }
    Expect(Apply(Tree, [Root + '/sub3'], CapturedAt) and
      (Tree.SizeOf(RootID) = Expected), 'repeated apply is stable');
  finally
    Tree.Free;
  end;
end;

procedure TestUnknownPreCaptureInodeRejected;
var
  Tree: TFileTree;
  CapturedAt: Double;
begin
  { Born before capture, outside the tree, then linked in afterwards:
    the journal cannot prove where else it is linked, so rescan fully. }
  WriteBytes(Outside + '/old', 64 * 1024);
  HardLink(Outside + '/old', Outside + '/old-twin');
  Tree := ScanPath(Root);
  try
    Sleep(1100);
    CapturedAt := UnixTimeNow;
    HardLink(Outside + '/old', Root + '/sub3/imported');
    Expect(not Apply(Tree, [Root + '/sub3'], CapturedAt),
      'unknown hard link born before capture rejects incremental apply');
  finally
    Tree.Free;
  end;
  DeleteFile(Root + '/sub3/imported');
end;

procedure TestNewInodeAfterCaptureAccepted;
var
  Tree: TFileTree;
  CapturedAt: Double;
  Expected: Int64;
begin
  Tree := ScanPath(Root);
  try
    CapturedAt := UnixTimeNow;
    Sleep(1100);
    WriteBytes(Root + '/sub3/fresh', 32 * 1024);
    HardLink(Root + '/sub3/fresh', Root + '/sub3/fresh-twin');
    Expected := FullScanSize;
    Expect(Apply(Tree, [Root + '/sub3'], CapturedAt),
      'new hard-linked file born after capture is accepted');
    Expect(Tree.SizeOf(RootID) = Expected,
      Format('new hard link pair counted once (incremental %d = full %d)',
        [Tree.SizeOf(RootID), Expected]));
  finally
    Tree.Free;
  end;
end;

procedure TestRemovedLinkReleasesSize;
var
  Tree: TFileTree;
  CapturedAt: Double;
  Expected: Int64;
begin
  { sub1/link1 currently carries the size of 'big' in scan order only if it
    was seen first; deleting the root-level 'big' must move the bytes to a
    surviving link rather than dropping them. }
  Tree := ScanPath(Root);
  try
    CapturedAt := UnixTimeNow;
    DeleteFile(Root + '/big');
    Expected := FullScanSize;
    Expect(Apply(Tree, [Root], CapturedAt), 'removing one link applies');
    Expect(Tree.SizeOf(RootID) = Expected,
      Format('surviving links still count the inode once (incremental %d = full %d)',
        [Tree.SizeOf(RootID), Expected]));
  finally
    Tree.Free;
  end;
end;

procedure TestOldInodeInNewSubdirRejected;
var
  Tree: TFileTree;
  CapturedAt: Double;
begin
  { The unknown link sits in a directory that did not exist at capture, so
    the check runs on the freshly scanned subtree, not the direct files. }
  WriteBytes(Outside + '/old2', 16 * 1024);
  HardLink(Outside + '/old2', Outside + '/old2-twin');
  Tree := ScanPath(Root);
  try
    Sleep(1100);
    CapturedAt := UnixTimeNow;
    CreateDir(Root + '/newdir');
    HardLink(Outside + '/old2', Root + '/newdir/imported');
    Expect(not ApplyTo(Tree, [Root], [], CapturedAt),
      'unknown old link inside a new subdirectory rejects incremental apply');
    Expect((Tree.ChildNamed(RootID, 'newdir') <> NoNode) and
      (Tree.ChildCount(Tree.ChildNamed(RootID, 'newdir')) = 0),
      'rejected subtree is validated before adoption and never linked in');
  finally
    Tree.Free;
  end;
  DeleteFile(Root + '/newdir/imported');
  RemoveDir(Root + '/newdir');
end;

procedure TestNewSubdirectoryAdopted;
var
  Tree: TFileTree;
  CapturedAt: Double;
  Expected: Int64;
  Dir: TNodeID;
begin
  Tree := ScanPath(Root);
  try
    CapturedAt := UnixTimeNow;
    Sleep(1100);
    ForceDirectories(Root + '/fresh/inner');
    WriteBytes(Root + '/fresh/inner/data', 24 * 1024);
    HardLink(Root + '/fresh/inner/data', Root + '/fresh/data-twin');
    Expected := FullScanSize;
    Expect(ApplyTo(Tree, [Root], [], CapturedAt), 'new subdirectory tree applies');
    Dir := Tree.NodeIDForPath(Root + '/fresh/inner', Root);
    Expect((Dir <> NoNode) and (Tree.ChildNamed(Dir, 'data') <> NoNode),
      'new nested subdirectory is adopted with its files');
    Expect(Tree.SizeOf(RootID) = Expected,
      Format('adopted subtree matches full scan (incremental %d = full %d)',
        [Tree.SizeOf(RootID), Expected]));
  finally
    Tree.Free;
  end;
end;

procedure TestKnownKeyInRescannedSubtree;
var
  Tree: TFileTree;
  CapturedAt: Double;
  Expected: Int64;
begin
  WriteBytes(Root + '/shared', 48 * 1024);
  HardLink(Root + '/shared', Root + '/sub1/shared-link');
  Tree := ScanPath(Root);
  try
    CapturedAt := UnixTimeNow;
    Sleep(1100);
    HardLink(Root + '/shared', Root + '/sub3/shared-late');
    Expected := FullScanSize;
    Expect(ApplyTo(Tree, [], [Root + '/sub3'], CapturedAt),
      'known key inside a rescanned subtree applies');
    Expect(Tree.SizeOf(RootID) = Expected,
      Format('subtree rescan counts the inode once (incremental %d = full %d)',
        [Tree.SizeOf(RootID), Expected]));
  finally
    Tree.Free;
  end;
end;

procedure TestHardLinkScale;
const
  N = 40000;
var
  Tree: TFileTree;
  I: Integer;
  Dir, F: TNodeID;
  Key: THardLinkKey;
  Started: QWord;
  Elapsed: QWord;
begin
  { 40k directories each holding one link to one of 20k inodes. }
  Tree := TFileTree.Create('/bench');
  try
    Started := GetTickCount64;
    for I := 0 to N - 1 do
    begin
      Dir := Tree.AddNode('d' + IntToStr(I), RootID, 0, True);
      F := Tree.AddNode('f', Dir, 4096, False);
      Key.Device := 1;
      Key.FileID := QWord(I div 2) + 1;
      Tree.RecordHardLink(F, Key, 4096);
    end;
    Tree.NormalizeHardLinks;
    Tree.ResetDirectorySizes;
    Tree.RollUpDirectorySizes;
    for I := 0 to Tree.HardLinkCount - 1 do
      Tree.UpdateAllocatedSize(Tree.HardLinkNodeAt(I), 4096);
    Elapsed := GetTickCount64 - Started;
    Expect(Tree.SizeOf(RootID) = Int64(N div 2) * 4096,
      'scale: 40k links to 20k inodes count each inode once');
    Expect(Elapsed < 200, Format('scale: record + normalize + roll-up in %d ms (< 200)', [Elapsed]));
  finally
    Tree.Free;
  end;
end;

procedure AppendBytes(const Path: string; Count: Integer);
var
  F: TFileStream;
  Data: array of Byte;
begin
  SetLength(Data, Count);
  FillChar(Data[0], Count, $A5);
  F := TFileStream.Create(Path, fmOpenReadWrite);
  try
    F.Seek(0, soEnd);
    F.WriteBuffer(Data[0], Count);
  finally
    F.Free;
  end;
end;

function ScanSizeOf(const Path: string): Int64;
var
  T: TFileTree;
begin
  T := ScanPath(Path);
  try
    Result := T.SizeOf(RootID);
  finally
    T.Free;
  end;
end;

function ApplyNothing(Tree: TFileTree; const RootPath: string): Boolean;
var
  Changes: TChangeSet;
begin
  Changes.ChangedDirectories := TStringList.Create;
  Changes.SubtreesToRescan := TStringList.Create;
  try
    Result := ApplyChanges(Tree, RootPath, Changes, UnixTimeNow);
  finally
    Changes.ChangedDirectories.Free;
    Changes.SubtreesToRescan.Free;
  end;
end;

procedure TestLargeFileDrift;
var
  Dir: string;
  Tree: TFileTree;
  Grow, Small, Linked: TNodeID;
  Before, Expected, SmallNow: Int64;
begin
  { In-place rewrites change no directory, so FSEvents reports nothing;
    IncrementalUpdater.swift refreshLargeFileSizes re-stats big files. }
  Dir := Root + '_drift';
  RemoveTree(Dir);
  CreateDir(Dir);
  try
    WriteBytes(Dir + '/grow', 64 * 1024);
    WriteBytes(Dir + '/small', 4096);
    HardLink(Dir + '/grow', Dir + '/grow-link');
    Tree := ScanPath(Dir);
    try
      Grow := Tree.ChildNamed(RootID, 'grow');
      Small := Tree.ChildNamed(RootID, 'small');
      Linked := Tree.ChildNamed(RootID, 'grow-link');
      Before := Tree.SizeOf(Small);
      AppendBytes(Dir + '/grow', 192 * 1024);
      AppendBytes(Dir + '/small', 64 * 1024);
      Expected := ScanSizeOf(Dir);

      RefreshLargeFileSizes(Tree, 32 * 1024);
      Tree.NormalizeHardLinks;
      Tree.ResetDirectorySizes;
      Tree.RollUpDirectorySizes;
      Expect(Tree.SizeOf(Small) = Before,
        'file under the drift minimum is not re-stat''ed');
      Expect(Tree.SizeOf(Grow) + Tree.SizeOf(Linked) >= 256 * 1024,
        'grown hard-linked file picks up its new allocation');
      Expect((Tree.SizeOf(Grow) = 0) or (Tree.SizeOf(Linked) = 0),
        'grown hard link still counts once');
      Expect(FileAllocatedSize(Dir + '/small', SmallNow), 'small file stat');
      Expect(Tree.SizeOf(RootID) = Expected - (SmallNow - Before),
        Format('refreshed total matches a full scan apart from the small file (%d = %d)',
          [Tree.SizeOf(RootID), Expected - (SmallNow - Before)]));
    finally
      Tree.Free;
    end;

    { ApplyChanges itself refreshes files of at least 64 MiB. }
    DeleteFile(Dir + '/grow');
    DeleteFile(Dir + '/grow-link');
    DeleteFile(Dir + '/small');
    WriteBytes(Dir + '/huge', DriftCheckMinimumBytes + 1024 * 1024);
    Tree := ScanPath(Dir);
    try
      AppendBytes(Dir + '/huge', 1024 * 1024);
      Expected := ScanSizeOf(Dir);
      Expect(Tree.SizeOf(RootID) < Expected, 'cached tree is stale after in-place growth');
      Expect(ApplyNothing(Tree, Dir), 'apply with no directory changes succeeds');
      Expect(Tree.SizeOf(RootID) = Expected,
        Format('apply re-stats a >= 64 MiB file (incremental %d = full %d)',
          [Tree.SizeOf(RootID), Expected]));
    finally
      Tree.Free;
    end;
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestVanishedSubtree;
var
  Tree: TFileTree;
  Node: TNodeID;
begin
  Tree := TFileTree.Create(Root);
  try
    Node := Tree.AddNode('gone', RootID, 0, True);
    Expect(ScanInto(Tree, Node, Root + '/gone-since-read'),
      'ScanInto on a vanished path adopts an empty subtree');
    Expect(Tree.ChildCount(Node) = 0, 'vanished subtree stays empty');
  finally
    Tree.Free;
  end;
end;

begin
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_incr_' + IntToStr(GetProcessID);
  Outside := Root + '_outside';
  RemoveTree(Root);
  RemoveTree(Outside);
  CreateDir(Root);
  CreateDir(Outside);
  try
    TestLateLinkToKnownInode;
    TestUnknownPreCaptureInodeRejected;
    TestNewInodeAfterCaptureAccepted;
    TestRemovedLinkReleasesSize;
    TestOldInodeInNewSubdirRejected;
    TestKnownKeyInRescannedSubtree;
    TestNewSubdirectoryAdopted;
    TestHardLinkScale;
    TestVanishedSubtree;
    TestLargeFileDrift;
  finally
    RemoveTree(Root);
    RemoveTree(Outside);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_incremental: all passed');
end.
