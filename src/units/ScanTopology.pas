{ ScanTopology — what a scan of a path actually walks.

  Port of ScanEngine.swift performScan:
  - '/' is the boot volume group: the root volume (plus the Data volume
    behind its firmlinks) and then every other volume under
    /System/Volumes, each on its own device, merged into the tree at
    /System/Volumes/<name>; the top-level 'Volumes' folder (other disks'
    mount points) is dropped (scanBootVolumeGroup, :288-359).
  - Any other path that does not exist but does under the Data volume is
    scanned there, keeping the requested path as the tree's root name
    (resolveDataVolumeAlias, :152-177).
  Platforms without these volumes scan the path as is. }

unit ScanTopology;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileTree, Traversal;

{ The path to walk for Path: the Data-volume copy when Path is missing
  and that copy exists, else Path. }
function ResolveDataVolumeAlias(const Path: string): string;

{ Other volumes of the boot volume group, by name under
  SystemVolumesDirectory (not Data, no dot names, volume roots only). }
function SiblingVolumeNames: TStringArray;

{ Scans Path as the Swift app does; Unreadable (optional) counts folders
  that could not be listed across every volume walked. Progress reports
  totals across volumes. OnPartial receives snapshots composed like the
  final tree (ScanEngine.swift PartialResultAssembler). With UseCache the
  root tree (the root volume for '/') goes through scanRootTreeUsingCache:
  a cached tree updated from the change journal when possible, else a
  full walk; either way the cache is saved. }
type
  { ScanPhase: True while the cache is checked against the change journal
    ('Checking what changed since the last scan…'), False when walking. }
  TScanPhaseChanged = procedure(CheckingChanges: Boolean);

function ScanForAnalysis(const Path: string; Progress: TScanProgress = nil;
  IsCancelled: TScanCancelled = nil; Unreadable: PInteger = nil;
  OnPartial: TScanPartial = nil; UseCache: Boolean = False;
  OnPhase: TScanPhaseChanged = nil): TFileTree;

implementation

uses
  PlatformVolumes, PlatformProcessTuning, Volumes, PlatformFS, ScanCache,
  ChangeJournal, JournalFactory, Incremental, DirTypes;

function ResolveDataVolumeAlias(const Path: string): string;
var
  Data: string;
begin
  Result := Path;
  Data := DataVolumeMountPoint;
  if (Data = '') or FileExists(Path) or DirectoryExists(Path) then
    Exit;
  if FileExists(Data + Path) or DirectoryExists(Data + Path) then
    Result := Data + Path;
end;

function SiblingVolumeNames: TStringArray;
var
  Dir: string;
  SR: TSearchRec;
  N: Integer;
begin
  Result := nil;
  N := 0;
  Dir := SystemVolumesDirectory;
  if Dir = '' then
    Exit;
  if FindFirst(Dir + '/*', faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '') or (SR.Name[1] = '.') or (SR.Name = 'Data') then
        Continue;
      if not IsVolumeRoot(Dir + '/' + SR.Name) then
        Continue;
      SetLength(Result, N + 1);
      Result[N] := SR.Name;
      Inc(N);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ ScanEngine.swift traverse: a whole volume gets more workers. }
function WorkersFor(const Path: string): Integer;
begin
  if IsVolumeRoot(Path) then
    Result := VolumeWorkerCount
  else
    Result := SubtreeWorkerCount;
end;

threadvar
  CacheEnabled: Boolean;
  UserPhase: TScanPhaseChanged;

procedure SetPhase(CheckingChanges: Boolean);
begin
  if Assigned(UserPhase) then
    UserPhase(CheckingChanges);
end;

function CacheHeader(EventID: QWord; CapturedAt, FullScanSeconds: Double): TScanCacheHeader;
begin
  Result.EventID := EventID;
  Result.CapturedAt := CapturedAt;
  Result.FullScanSeconds := FullScanSeconds;
end;

{ ScanEngine.swift scanRootTreeUsingCache. RootName is the tree's root
  name (the requested path when ScanPath is an alias). }
function ScanRootTreeUsingCache(const ScanPathName, RootName: string;
  Progress: TScanProgress; const AllowedDevices: TDeviceSet;
  IsCancelled: TScanCancelled; Unreadable: PInteger; Workers: Integer;
  OnPartial: TScanPartial): TFileTree;
var
  Journal: TChangeJournal;
  StartEventID: QWord;
  StartedAt, Expected: Double;
  Header: TScanCacheHeader;
  FileBytes: Int64;
  Collected: TJournalResult;
  Changes: TChangeSet;
  Cached: TScanCacheEntry;
  Applied: Boolean;
  Started: QWord;
begin
  Journal := CreateChangeJournal;
  try
    StartEventID := Journal.CurrentEventID;
    StartedAt := UnixTimeNow;
    { FSEvents reports real paths: a path that is not its own real path
      (e.g. /var vs /private/var) would never match the changes, so its
      cache could only be replayed stale. Walk instead. }
    if CacheEnabled and (ResolveRealPath(ScanPathName) = ScanPathName) and
      ScanCachePeek(ScanPathName, Header, FileBytes) then
    begin
      SetPhase(True);
      if Header.FullScanSeconds > 0 then
        Expected := Header.FullScanSeconds
      else
        Expected := FileBytes / 10000000.0;
      Collected := Journal.Collect(Header.EventID, ScanPathName,
        ReplayTimeBudget(Expected), jmHistory, Changes);
      try
        Cached := ScanCacheLoad(ScanPathName);
        if Cached.OK and (Cached.Tree.NameOf(RootID) = RootName) then
        begin
          { The cached tree is shown while the changes are applied. }
          if Assigned(OnPartial) then
            OnPartial(Cached.Tree.Clone);
          SetPhase(False);
          Applied := (Collected = jrChanges) and
            ApplyChanges(Cached.Tree, ScanPathName, Changes, Cached.Header.CapturedAt, Progress);
          if Applied then
          begin
            if Unreadable <> nil then
              Unreadable^ := 0;
            ScanCacheSave(Cached.Tree, ScanPathName,
              CacheHeader(StartEventID, StartedAt, Header.FullScanSeconds));
            Exit(Cached.Tree);
          end;
          Cached.Tree.Free;
        end
        else
        begin
          Cached.Tree.Free;
          SetPhase(False);
        end;
      finally
        if Collected = jrChanges then
        begin
          Changes.ChangedDirectories.Free;
          Changes.SubtreesToRescan.Free;
        end;
      end;
    end;
  finally
    Journal.Free;
  end;

  Started := GetTickCount64;
  Result := ScanPath(ScanPathName, Progress, AllowedDevices, IsCancelled,
    Unreadable, Workers, OnPartial);
  Result.SetRootName(RootName);
  if CacheEnabled and not (Assigned(IsCancelled) and IsCancelled()) then
    ScanCacheSave(Result, ScanPathName,
      CacheHeader(StartEventID, StartedAt, (GetTickCount64 - Started) / 1000.0));
end;

threadvar
  { Progress across several ScanPath calls: totals of the finished ones,
    and the caller's callback. }
  BaseBytes: Int64;
  BaseItems: Integer;
  LastBytes: Int64;
  LastItems: Integer;
  UserProgress: TScanProgress;
  { Partial snapshots: the caller's callback, the requested root name, and
    during a boot-group scan the merged tree and the sibling being walked. }
  UserPartial: TScanPartial;
  PartialRootName: string;
  BootTree: TFileTree;
  SiblingMount: string;

procedure CombinedProgress(BytesScanned: Int64; ItemsScanned: Integer);
begin
  LastBytes := BytesScanned;
  LastItems := ItemsScanned;
  if Assigned(UserProgress) then
    UserProgress(BaseBytes + BytesScanned, BaseItems + ItemsScanned);
end;

procedure SubtreePartial(Tree: TFileTree);
begin
  Tree.SetRootName(PartialRootName);
  UserPartial(Tree);
end;

{ composeBootVolumeGroup applied to a snapshot. }
procedure ComposeBoot(Tree: TFileTree);
begin
  Tree.RemoveChildNamed(RootID, 'Volumes');
  Tree.ResetDirectorySizes;
  Tree.RollUpDirectorySizes;
end;

procedure RootVolumePartial(Tree: TFileTree);
begin
  ComposeBoot(Tree);
  UserPartial(Tree);
end;

procedure SiblingPartial(Tree: TFileTree);
var
  Merged: TFileTree;
  Target: TNodeID;
begin
  try
    Merged := BootTree.Clone;
    Target := Merged.NodeIDForPath(SiblingMount, '/');
    if (Target <> NoNode) and Merged.IsDirectory(Target) then
      Merged.Merge(Tree, Target);
  finally
    Tree.Free;
  end;
  ComposeBoot(Merged);
  UserPartial(Merged);
end;

function PartialFor(Handler: TScanPartial): TScanPartial;
begin
  if Assigned(UserPartial) then
    Result := Handler
  else
    Result := nil;
end;

function ScanBootVolumeGroup(Progress: TScanProgress; IsCancelled: TScanCancelled;
  Unreadable: PInteger): TFileTree;
var
  Names: TStringArray;
  I, Count: Integer;
  Sibling: TFileTree;
  Target: TNodeID;
  Mount: string;
begin
  Names := SiblingVolumeNames;
  UserProgress := Progress;
  BaseBytes := 0;
  BaseItems := 0;
  LastBytes := 0;
  LastItems := 0;
  Result := ScanRootTreeUsingCache('/', '/', @CombinedProgress,
    SubtreeAllowedDevices('/'), IsCancelled, Unreadable, WorkersFor('/'),
    PartialFor(@RootVolumePartial));
  for I := 0 to High(Names) do
  begin
    if Assigned(IsCancelled) and IsCancelled() then
      Break;
    Inc(BaseBytes, LastBytes);
    Inc(BaseItems, LastItems);
    LastBytes := 0;
    LastItems := 0;
    Mount := SystemVolumesDirectory + '/' + Names[I];
    Count := 0;
    BootTree := Result;
    SiblingMount := Mount;
    try
      Sibling := ScanPath(Mount, @CombinedProgress, nil, IsCancelled, @Count,
        WorkersFor(Mount), PartialFor(@SiblingPartial));
    finally
      { Never leave a pointer to a tree that may be freed. }
      BootTree := nil;
    end;
    try
      if Unreadable <> nil then
        Inc(Unreadable^, Count);
      Target := Result.NodeIDForPath(Mount, '/');
      if (Target <> NoNode) and Result.IsDirectory(Target) then
        Result.Merge(Sibling, Target);
    finally
      Sibling.Free;
    end;
  end;
  UserProgress := nil;
  Result.RemoveChildNamed(RootID, 'Volumes');
  Result.ResetDirectorySizes;
  Result.RollUpDirectorySizes;
end;

function ScanForAnalysis(const Path: string; Progress: TScanProgress;
  IsCancelled: TScanCancelled; Unreadable: PInteger;
  OnPartial: TScanPartial; UseCache: Boolean;
  OnPhase: TScanPhaseChanged): TFileTree;
var
  ScanRoot: string;
begin
  TuneProcessForScanning;
  UserPartial := OnPartial;
  PartialRootName := Path;
  CacheEnabled := UseCache;
  UserPhase := OnPhase;
  try
    if (Path = '/') and (SystemVolumesDirectory <> '') then
      Exit(ScanBootVolumeGroup(Progress, IsCancelled, Unreadable));
    ScanRoot := ResolveDataVolumeAlias(Path);
    Result := ScanRootTreeUsingCache(ScanRoot, Path, Progress,
      SubtreeAllowedDevices(ScanRoot), IsCancelled, Unreadable,
      WorkersFor(ScanRoot), PartialFor(@SubtreePartial));
  finally
    UserPartial := nil;
    UserPhase := nil;
    CacheEnabled := False;
  end;
end;

end.
