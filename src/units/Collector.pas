{ Collector — staged deletions with undo and protected-path guards.

  Port of OpenDisk Models/Collector.swift: undo is recorded only when the
  staged items actually change; deletion removes links themselves, never
  their targets, and keeps items that failed so the user can retry. }

unit Collector;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ProtectedPaths, PlatformRemove;

type
  TCollectedFile = class
  public
    Path: string;
    Name: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;

  { Collector.swift DeletionProgress. }
  TDeletionProgress = record
    CurrentName: string;
    Completed: Integer;
    Total: Integer;
    FreedBytes: Int64;
  end;

  { One background deletion of a snapshot of the staged items
    (Collector.swift deleteAll: each removal off the main thread). The
    collector itself is only touched again by FinishDelete. }
  TDeleteJob = class
  private
    FLock: TRTLCriticalSection;
    FPaths, FNames: array of string;
    FSizes: array of Int64;
    FProgress: TDeletionProgress;
    FDeleted: array of Boolean;
    FErrors: array of string;
    FThread: TThread;
    FDone: Boolean;
  public
    constructor Create(Items: TFPList);
    destructor Destroy; override;
    { Removes every item in order, on the calling thread. }
    procedure Run;
    { A consistent copy, safe from any thread. }
    function Progress: TDeletionProgress;
    { True once Run has returned. }
    function Finished: Boolean;
  end;

  { One file for AddMany (Collector.swift CollectedFile). }
  TCollectedEntry = record
    Path: string;
    Name: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;

  TCollector = class
  private
    FItems: TFPList;
    FUndo: TFPList;
    { recordingUndo: one snapshot per change, taken before the first
      mutation of an operation. }
    FUndoTaken: Boolean;
    { Collector.swift draggingOut: paths being dragged out of the
      collector, nil when no drag-out is pending. }
    FDraggingOut: TStringList;
    FBlockedNotice: string;
    FFailures: TStringList;
    function AppendOne(const Path, Name: string; Size: Int64;
      IsDirectory: Boolean): Boolean;
    procedure BeginChange;
    procedure FreeItems(List: TFPList);
    procedure PushUndo;
    function IndexOfPath(const Path: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Add(const Path, Name: string; Size: Int64; IsDirectory: Boolean): Boolean;
    { add(_ files:): stages several files as one undo step; returns how
      many were staged. BlockedNotice names the last refused one. }
    function AddMany(const Files: array of TCollectedEntry): Integer;
    procedure Remove(const Path: string);
    { Removes several paths as one undo step. }
    procedure RemoveMany(const Paths: array of string);
    { beginDragOut: remembers which staged paths are being dragged out. }
    procedure BeginDragOut(const Paths: array of string);
    function IsDraggingOut: Boolean;
    { endDragOut: Accepted is a non-empty drag operation (another app took
      the drop): the items stay and the caller clears the drag-out after
      2 s with CancelDragOut. Otherwise the drop resolves as outside. }
    procedure EndDragOut(Accepted: Boolean);
    { resolveDragOut: a drop inside a keep zone (the bar or its list)
      keeps the items; anywhere else unstages them. }
    procedure ResolveDragOut(InKeepZone: Boolean);
    procedure CancelDragOut;
    function Undo: Boolean;
    function CanUndo: Boolean;
    function UndoCount: Integer;
    function Contains(const Path: string): Boolean;
    function Count: Integer;
    function TotalBytes: Int64;
    { Permanently removes every staged item; returns bytes freed by the
      successful removals. Failed items stay staged and are listed in
      Failures as "path<TAB>reason". }
    function DeleteAll: Int64;
    { The same in the background (needs a thread manager, e.g.
      cthreads): StartDelete snapshots the staged items and starts the
      job; once Job.Finished, FinishDelete (on the owning thread) drops
      the deleted items, records Failures, clears undo, frees the job and
      returns the bytes freed. }
    function StartDelete: TDeleteJob;
    function FinishDelete(Job: TDeleteJob): Int64;
    property Items: TFPList read FItems;
    property Failures: TStringList read FFailures;
    property BlockedNotice: string read FBlockedNotice;
  end;

implementation

constructor TCollector.Create;
begin
  inherited Create;
  FItems := TFPList.Create;
  FUndo := TFPList.Create;
  FFailures := TStringList.Create;
end;

destructor TCollector.Destroy;
begin
  Clear;
  FreeItems(FUndo);
  FUndo.Free;
  FItems.Free;
  FFailures.Free;
  FDraggingOut.Free;
  inherited Destroy;
end;

procedure TCollector.FreeItems(List: TFPList);
var
  I: Integer;
begin
  for I := 0 to List.Count - 1 do
    TObject(List[I]).Free;
  List.Clear;
end;

procedure TCollector.Clear;
begin
  FBlockedNotice := '';
  { recordingUndo: clearing an empty collector is not a change. }
  if FItems.Count = 0 then
    Exit;
  FUndoTaken := False;
  BeginChange;
  FreeItems(FItems);
  FBlockedNotice := '';
end;

function TCollector.IndexOfPath(const Path: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if TCollectedFile(FItems[I]).Path = Path then
      Exit(I);
  Result := -1;
end;

function TCollector.Contains(const Path: string): Boolean;
begin
  Result := IndexOfPath(Path) >= 0;
end;

procedure TCollector.PushUndo;
var
  Snapshot: TFPList;
  I: Integer;
  Src, Dst: TCollectedFile;
begin
  Snapshot := TFPList.Create;
  for I := 0 to FItems.Count - 1 do
  begin
    Src := TCollectedFile(FItems[I]);
    Dst := TCollectedFile.Create;
    Dst.Path := Src.Path;
    Dst.Name := Src.Name;
    Dst.Size := Src.Size;
    Dst.IsDirectory := Src.IsDirectory;
    Snapshot.Add(Dst);
  end;
  FUndo.Add(Snapshot);
  if FUndo.Count > 50 then
  begin
    FreeItems(TFPList(FUndo[0]));
    TFPList(FUndo[0]).Free;
    FUndo.Delete(0);
  end;
end;

procedure TCollector.BeginChange;
begin
  if not FUndoTaken then
  begin
    PushUndo;
    FUndoTaken := True;
  end;
end;

function TCollector.AppendOne(const Path, Name: string; Size: Int64;
  IsDirectory: Boolean): Boolean;
var
  Reason: string;
  Item: TCollectedFile;
  I: Integer;
  Existing: TCollectedFile;
begin
  Result := False;
  if (Path = '') or (Copy(Path, 1, 2) = '::') then
    Exit;
  if not (FileExists(Path) or DirectoryExists(Path)) then
    Exit;
  Reason := ProtectedReason(Path);
  if Reason <> '' then
  begin
    FBlockedNotice := '“' + Name + '” ' + Reason;
    Exit;
  end;
  if Contains(Path) then
    Exit;
  for I := 0 to FItems.Count - 1 do
  begin
    Existing := TCollectedFile(FItems[I]);
    if Existing.IsDirectory and
       (Copy(Path, 1, Length(Existing.Path) + 1) = Existing.Path + DirectorySeparator) then
      Exit;
  end;
  BeginChange;
  if IsDirectory then
  begin
    I := 0;
    while I < FItems.Count do
    begin
      Existing := TCollectedFile(FItems[I]);
      if Copy(Existing.Path, 1, Length(Path) + 1) = Path + DirectorySeparator then
      begin
        Existing.Free;
        FItems.Delete(I);
      end
      else
        Inc(I);
    end;
  end;
  Item := TCollectedFile.Create;
  Item.Path := Path;
  Item.Name := Name;
  Item.Size := Size;
  Item.IsDirectory := IsDirectory;
  FItems.Add(Item);
  Result := True;
end;

function TCollector.Add(const Path, Name: string; Size: Int64;
  IsDirectory: Boolean): Boolean;
begin
  FBlockedNotice := '';
  FUndoTaken := False;
  Result := AppendOne(Path, Name, Size, IsDirectory);
end;

function TCollector.AddMany(const Files: array of TCollectedEntry): Integer;
var
  I: Integer;
  Notice: string;
begin
  Result := 0;
  Notice := '';
  FBlockedNotice := '';
  FUndoTaken := False;
  for I := 0 to High(Files) do
  begin
    if AppendOne(Files[I].Path, Files[I].Name, Files[I].Size, Files[I].IsDirectory) then
      Inc(Result);
    if FBlockedNotice <> '' then
      Notice := FBlockedNotice;
  end;
  FBlockedNotice := Notice;
end;

procedure TCollector.Remove(const Path: string);
begin
  RemoveMany([Path]);
end;

procedure TCollector.RemoveMany(const Paths: array of string);
var
  I, Idx: Integer;
begin
  FUndoTaken := False;
  for I := 0 to High(Paths) do
  begin
    Idx := IndexOfPath(Paths[I]);
    if Idx < 0 then
      Continue;
    BeginChange;
    TCollectedFile(FItems[Idx]).Free;
    FItems.Delete(Idx);
  end;
end;

procedure TCollector.BeginDragOut(const Paths: array of string);
var
  I: Integer;
begin
  FreeAndNil(FDraggingOut);
  FDraggingOut := TStringList.Create;
  for I := 0 to High(Paths) do
    if Contains(Paths[I]) then
      FDraggingOut.Add(Paths[I]);
end;

function TCollector.IsDraggingOut: Boolean;
begin
  Result := FDraggingOut <> nil;
end;

procedure TCollector.EndDragOut(Accepted: Boolean);
begin
  if (FDraggingOut = nil) or Accepted then
    Exit;
  ResolveDragOut(False);
end;

procedure TCollector.ResolveDragOut(InKeepZone: Boolean);
var
  Paths: array of string;
  I: Integer;
begin
  if FDraggingOut = nil then
    Exit;
  SetLength(Paths, FDraggingOut.Count);
  for I := 0 to FDraggingOut.Count - 1 do
    Paths[I] := FDraggingOut[I];
  FreeAndNil(FDraggingOut);
  if not InKeepZone then
    RemoveMany(Paths);
end;

procedure TCollector.CancelDragOut;
begin
  FreeAndNil(FDraggingOut);
end;

function TCollector.Undo: Boolean;
var
  Snapshot: TFPList;
begin
  Result := False;
  if FUndo.Count = 0 then
    Exit;
  FreeItems(FItems);
  Snapshot := TFPList(FUndo[FUndo.Count - 1]);
  FUndo.Delete(FUndo.Count - 1);
  while Snapshot.Count > 0 do
  begin
    FItems.Add(Snapshot[0]);
    Snapshot.Delete(0);
  end;
  Snapshot.Free;
  Result := True;
end;

function TCollector.CanUndo: Boolean;
begin
  Result := FUndo.Count > 0;
end;

function TCollector.UndoCount: Integer;
begin
  Result := FUndo.Count;
end;

function TCollector.Count: Integer;
begin
  Result := FItems.Count;
end;

function TCollector.TotalBytes: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FItems.Count - 1 do
    Result := Result + TCollectedFile(FItems[I]).Size;
end;

constructor TDeleteJob.Create(Items: TFPList);
var
  I: Integer;
  Item: TCollectedFile;
begin
  InitCriticalSection(FLock);
  SetLength(FPaths, Items.Count);
  SetLength(FNames, Items.Count);
  SetLength(FSizes, Items.Count);
  SetLength(FDeleted, Items.Count);
  SetLength(FErrors, Items.Count);
  for I := 0 to Items.Count - 1 do
  begin
    Item := TCollectedFile(Items[I]);
    FPaths[I] := Item.Path;
    UniqueString(FPaths[I]);
    FNames[I] := Item.Name;
    UniqueString(FNames[I]);
    FSizes[I] := Item.Size;
  end;
  FProgress.Total := Items.Count;
end;

destructor TDeleteJob.Destroy;
begin
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FThread.Free;
  end;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TDeleteJob.Finished: Boolean;
begin
  EnterCriticalSection(FLock);
  Result := FDone;
  LeaveCriticalSection(FLock);
end;

type
  TDeleteThread = class(TThread)
  private
    FJob: TDeleteJob;
  protected
    procedure Execute; override;
  public
    constructor Create(Job: TDeleteJob);
  end;

constructor TDeleteThread.Create(Job: TDeleteJob);
begin
  FJob := Job;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDeleteThread.Execute;
begin
  FJob.Run;
end;

function TDeleteJob.Progress: TDeletionProgress;
begin
  EnterCriticalSection(FLock);
  try
    Result := FProgress;
    UniqueString(Result.CurrentName);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TDeleteJob.Run;
var
  I: Integer;
  Error: string;
  Freed: Int64;
begin
  Freed := 0;
  for I := 0 to High(FPaths) do
  begin
    EnterCriticalSection(FLock);
    FProgress.CurrentName := FNames[I];
    FProgress.Completed := I;
    FProgress.FreedBytes := Freed;
    LeaveCriticalSection(FLock);
    FDeleted[I] := RemoveItem(FPaths[I], Error);
    if FDeleted[I] then
      Inc(Freed, FSizes[I])
    else
      FErrors[I] := Error;
  end;
  EnterCriticalSection(FLock);
  FProgress.CurrentName := '';
  FProgress.Completed := Length(FPaths);
  FProgress.FreedBytes := Freed;
  FDone := True;
  LeaveCriticalSection(FLock);
end;

function TCollector.StartDelete: TDeleteJob;
begin
  Result := TDeleteJob.Create(FItems);
  Result.FThread := TDeleteThread.Create(Result);
end;

function TCollector.FinishDelete(Job: TDeleteJob): Int64;
var
  I, K: Integer;
  Item: TCollectedFile;
begin
  if Job.FThread <> nil then
  begin
    Job.FThread.WaitFor;
    FreeAndNil(Job.FThread);
  end;
  Result := 0;
  FFailures.Clear;
  { Drop what was deleted; failed items stay staged (Collector.swift
    removes all but the failed paths). }
  for I := 0 to High(Job.FPaths) do
    if Job.FDeleted[I] then
    begin
      Inc(Result, Job.FSizes[I]);
      K := IndexOfPath(Job.FPaths[I]);
      if K >= 0 then
      begin
        Item := TCollectedFile(FItems[K]);
        Item.Free;
        FItems.Delete(K);
      end;
    end
    else
      FFailures.Add(Job.FPaths[I] + #9 + Job.FErrors[I]);
  while FUndo.Count > 0 do
  begin
    FreeItems(TFPList(FUndo[0]));
    TFPList(FUndo[0]).Free;
    FUndo.Delete(0);
  end;
  Job.Free;
end;

function TCollector.DeleteAll: Int64;
var
  Job: TDeleteJob;
begin
  Job := TDeleteJob.Create(FItems);
  Job.Run;
  Result := FinishDelete(Job);
end;

end.
