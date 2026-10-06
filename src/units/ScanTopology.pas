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
  final tree (ScanEngine.swift PartialResultAssembler). }
function ScanForAnalysis(const Path: string; Progress: TScanProgress = nil;
  IsCancelled: TScanCancelled = nil; Unreadable: PInteger = nil;
  OnPartial: TScanPartial = nil): TFileTree;

implementation

uses
  PlatformVolumes, PlatformProcessTuning, Volumes;

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
  Result := ScanPath('/', @CombinedProgress, SubtreeAllowedDevices('/'),
    IsCancelled, Unreadable, WorkersFor('/'), PartialFor(@RootVolumePartial));
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
  OnPartial: TScanPartial): TFileTree;
var
  ScanRoot: string;
begin
  TuneProcessForScanning;
  UserPartial := OnPartial;
  PartialRootName := Path;
  try
    if (Path = '/') and (SystemVolumesDirectory <> '') then
      Exit(ScanBootVolumeGroup(Progress, IsCancelled, Unreadable));
    ScanRoot := ResolveDataVolumeAlias(Path);
    Result := ScanPath(ScanRoot, Progress, SubtreeAllowedDevices(ScanRoot),
      IsCancelled, Unreadable, WorkersFor(ScanRoot), PartialFor(@SubtreePartial));
  finally
    UserPartial := nil;
  end;
  Result.SetRootName(Path);
end;

end.
