{ SearchController — name search off the UI thread.

  DiskAnalyzer.swift rebuildSearchIndex / runActiveSearch: the index is
  built in the background from a copy of the tree (marked partial when the
  scan is still running), and the newest query runs against the newest
  index; a superseded query's results are never published. Results are
  ready-made rows (FolderItem), so the UI never touches the copied tree.

  The owner calls SetTree / SetQuery from one thread and polls TakeResults
  from that same thread; a single worker thread does the work. }

unit SearchController;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileTree, SearchIndex;

type
  { Models/FolderItem.swift. }
  TFolderItem = record
    Name: string;
    Path: string;
    Size: Int64;
    IsDirectory: Boolean;
    ItemCount: Integer;
  end;
  TFolderItems = array of TFolderItem;

  TSearchSnapshot = record
    Query: string;
    Items: TFolderItems;
    TotalMatches: Integer;
    { searchResultsArePartial: the index came from a partial scan. }
    Partial: Boolean;
  end;

  TSearchController = class
  private
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FThread: TThread;
    FStopping: Boolean;
    { Pending work, guarded by FLock. }
    FPendingTree: TFileTree;
    FPendingPartial: Boolean;
    FQuery: string;
    FQueryVersion: Integer;
    { Worker state. }
    FIndex: TSearchIndex;
    FIndexPartial: Boolean;
    FDoneVersion: Integer;
    FRunning: Boolean;
    { Published result, guarded by FLock. }
    FResult: TSearchSnapshot;
    FHasResult: Boolean;
    procedure WorkerLoop;
  public
    constructor Create;
    destructor Destroy; override;
    { Indexes a copy of Tree (the caller keeps Tree). }
    procedure SetTree(Tree: TFileTree; IsPartial: Boolean);
    { Trimmed like Swift; '' clears the results. }
    procedure SetQuery(const Query: string);
    { The newest published results since the last call, if any. }
    function TakeResults(out Snapshot: TSearchSnapshot): Boolean;
    { True while an index build or a search is in progress. }
    function IsRunning: Boolean;
    function HasIndex: Boolean;
  end;

implementation

type
  TSearchWorker = class(TThread)
  private
    FOwner: TSearchController;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TSearchController);
  end;

constructor TSearchWorker.Create(Owner: TSearchController);
begin
  FOwner := Owner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSearchWorker.Execute;
begin
  FOwner.WorkerLoop;
end;

constructor TSearchController.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
  FThread := TSearchWorker.Create(Self);
end;

destructor TSearchController.Destroy;
begin
  EnterCriticalSection(FLock);
  FStopping := True;
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FWake);
  FThread.WaitFor;
  FThread.Free;
  FPendingTree.Free;
  FIndex.Free;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TSearchController.SetTree(Tree: TFileTree; IsPartial: Boolean);
var
  Copy: TFileTree;
begin
  Copy := Tree.Clone;
  EnterCriticalSection(FLock);
  FPendingTree.Free;
  FPendingTree := Copy;
  FPendingPartial := IsPartial;
  { Re-run the current query against the new index. }
  Inc(FQueryVersion);
  FRunning := True;
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FWake);
end;

procedure TSearchController.SetQuery(const Query: string);
begin
  EnterCriticalSection(FLock);
  FQuery := Trim(Query);
  Inc(FQueryVersion);
  FRunning := True;
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FWake);
end;

function TSearchController.TakeResults(out Snapshot: TSearchSnapshot): Boolean;
begin
  EnterCriticalSection(FLock);
  Result := FHasResult;
  if Result then
  begin
    Snapshot := FResult;
    FHasResult := False;
  end;
  LeaveCriticalSection(FLock);
end;

function TSearchController.IsRunning: Boolean;
begin
  EnterCriticalSection(FLock);
  Result := FRunning;
  LeaveCriticalSection(FLock);
end;

function TSearchController.HasIndex: Boolean;
begin
  EnterCriticalSection(FLock);
  Result := FIndex <> nil;
  LeaveCriticalSection(FLock);
end;

procedure TSearchController.WorkerLoop;
var
  Tree: TFileTree;
  Partial, Stop: Boolean;
  Query: string;
  Version, I: Integer;
  Found: TSearchResults;
  Snap: TSearchSnapshot;
  NewIndex: TSearchIndex;
begin
  repeat
    RTLEventWaitFor(FWake, 200);
    repeat
      EnterCriticalSection(FLock);
      Stop := FStopping;
      Tree := FPendingTree;
      FPendingTree := nil;
      Partial := FPendingPartial;
      Query := FQuery;
      Version := FQueryVersion;
      LeaveCriticalSection(FLock);
      if Stop then
      begin
        Tree.Free;
        Exit;
      end;

      if Tree <> nil then
      begin
        { The index owns its tree copy. }
        NewIndex := TSearchIndex.Create(Tree, True);
        EnterCriticalSection(FLock);
        FIndex.Free;
        FIndex := NewIndex;
        FIndexPartial := Partial;
        LeaveCriticalSection(FLock);
        Continue;
      end;

      if Version = FDoneVersion then
        Break;
      FDoneVersion := Version;
      Snap.Query := Query;
      Snap.Items := nil;
      Snap.TotalMatches := 0;
      Snap.Partial := FIndexPartial;
      if (Query <> '') and (FIndex <> nil) then
      begin
        Found := FIndex.Search(Query, ssAll);
        Snap.TotalMatches := Found.TotalMatches;
        SetLength(Snap.Items, Length(Found.Hits));
        for I := 0 to High(Found.Hits) do
          with FIndex.Tree do
          begin
            Snap.Items[I].Name := NameOf(Found.Hits[I].ID);
            Snap.Items[I].Path := PathOf(Found.Hits[I].ID);
            Snap.Items[I].Size := Found.Hits[I].Size;
            Snap.Items[I].IsDirectory := IsDirectory(Found.Hits[I].ID);
            if Snap.Items[I].IsDirectory then
              Snap.Items[I].ItemCount := ChildCount(Found.Hits[I].ID)
            else
              Snap.Items[I].ItemCount := 0;
          end;
      end;
      EnterCriticalSection(FLock);
      { Publish only when no newer query or tree arrived meanwhile. }
      if (Version = FQueryVersion) and (FPendingTree = nil) then
      begin
        FResult := Snap;
        FHasResult := True;
        { Waiting for an index with a query set still counts as running. }
        FRunning := (Query <> '') and (FIndex = nil);
      end;
      LeaveCriticalSection(FLock);
    until False;
  until False;
end;

end.
