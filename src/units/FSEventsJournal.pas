{ FSEventsJournal — Darwin change journal since an FSEvents event id.

  Port of OpenDisk FSEventsChangeJournal, using CFRunLoop instead of
  DispatchQueue so we stay in plain FPC (univint FSEvents + CFRunLoop). }

unit FSEventsJournal;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TFSEventsChanges = record
    ChangedDirectories: TStringList;
    SubtreesToRescan: TStringList;
    OK: Boolean;
  end;

  TJournalMode = (
    { Replay history since the event id and finish on HistoryDone, like
      FSEventsChangeJournal.swift; a timeout means the history is
      incomplete and fails the collection. }
    jmHistory,
    { CLI watch: keep collecting live events for the whole window; the
      window ending is success. }
    jmLiveWindow
  );

function CurrentFSEventsID: QWord;
{ History replay timeout: half the expected full-scan time, clamped to
  2..30 s (ScanEngine.swift replayTimeBudget). }
function ReplayTimeBudget(ExpectedFullScanSeconds: Double): Double;
{ Returns OK=False when history is incomplete/unreliable or timed out.
  Caller must Free the string lists when OK. }
function CollectFSEventsChanges(SinceEventID: QWord; const RootPath: string;
  TimeoutSec: Double; Mode: TJournalMode = jmHistory): TFSEventsChanges;

implementation

{$IFDEF DARWIN}
uses
  BaseUnix, Unix, CFBase, CFArray, CFString, CFRunLoop, FSEvents, PlatformFS;

type
  PCollector = ^TCollector;
  TCollector = record
    Changed: TStringList;
    Subtrees: TStringList;
    RootPrefix: string;
    Unreliable: Boolean;
    Finished: Boolean;
    Completed: Boolean;
    StopOnHistoryDone: Boolean;
    ChangeLimit: Integer;
  end;

function DistinctCount(C: PCollector): Integer;
begin
  Result := C^.Changed.Count + C^.Subtrees.Count;
end;

procedure FinishCollector(C: PCollector; Completed: Boolean);
begin
  if C^.Finished then
    Exit;
  C^.Finished := True;
  C^.Completed := Completed;
end;

procedure StreamCallback(
  streamRef: ConstFSEventStreamRef;
  clientCallBackInfo: Pointer;
  numEvents: PtrUInt;
  eventPaths: Pointer;
  eventFlags: FSEventStreamEventFlagsPtr;
  eventIds: FSEventStreamEventIdPtr
); mwpascal;
var
  C: PCollector;
  Paths: CFArrayRef;
  I: Integer;
  Flags: FSEventStreamEventFlags;
  PathRef: CFStringRef;
  PathBuf: array[0..4095] of AnsiChar;
  Path, Normalized: string;
begin
  C := PCollector(clientCallBackInfo);
  if (C = nil) or C^.Finished then
    Exit;

  Paths := CFArrayRef(eventPaths);
  for I := 0 to Integer(numEvents) - 1 do
  begin
    Flags := eventFlags[I];

    if (Flags and kFSEventStreamEventFlagHistoryDone) <> 0 then
    begin
      if C^.StopOnHistoryDone then
      begin
        FinishCollector(C, True);
        Exit;
      end;
      Continue;
    end;

    if (Flags and (
         kFSEventStreamEventFlagEventIdsWrapped or
         kFSEventStreamEventFlagUserDropped or
         kFSEventStreamEventFlagKernelDropped or
         kFSEventStreamEventFlagRootChanged)) <> 0 then
    begin
      C^.Unreliable := True;
      Continue;
    end;

    PathRef := CFStringRef(CFArrayGetValueAtIndex(Paths, I));
    if PathRef = nil then
      Continue;
    if not CFStringGetCString(PathRef, @PathBuf[0], SizeOf(PathBuf),
      kCFStringEncodingUTF8) then
      Continue;
    Path := StrPas(PathBuf);

    if not ((Copy(Path, 1, Length(C^.RootPrefix)) = C^.RootPrefix) or
            (Path + DirectorySeparator = C^.RootPrefix)) then
      Continue;

    Normalized := Path;
    if (Length(Normalized) > 1) and
       (Normalized[Length(Normalized)] = DirectorySeparator) then
      SetLength(Normalized, Length(Normalized) - 1);

    { Sorted + dupIgnore lists act as sets (Swift uses Set<String>). }
    if (Flags and kFSEventStreamEventFlagMustScanSubDirs) <> 0 then
      C^.Subtrees.Add(Normalized)
    else
      C^.Changed.Add(Normalized);

    if DistinctCount(C) > C^.ChangeLimit then
    begin
      FinishCollector(C, False);
      Exit;
    end;
  end;
end;

function CurrentFSEventsID: QWord;
begin
  Result := FSEventsGetCurrentEventId;
end;

function CollectFSEventsChanges(SinceEventID: QWord; const RootPath: string;
  TimeoutSec: Double; Mode: TJournalMode): TFSEventsChanges;
var
  Collector: TCollector;
  Context: FSEventStreamContext;
  Stream: FSEventStreamRef;
  Paths: CFArrayRef;
  PathStr: CFStringRef;
  Started: QWord;
  Latency: Double;
  RealRoot: string;
begin
  Result.OK := False;
  Result.ChangedDirectories := nil;
  Result.SubtreesToRescan := nil;

  { FSEvents emits real paths (/private/tmp/…); resolve symlinks so filters match. }
  RealRoot := ResolveRealPath(RootPath);

  FillChar(Collector, SizeOf(Collector), 0);
  Collector.Changed := TStringList.Create;
  Collector.Changed.Sorted := True;
  Collector.Changed.Duplicates := dupIgnore;
  Collector.Subtrees := TStringList.Create;
  Collector.Subtrees.Sorted := True;
  Collector.Subtrees.Duplicates := dupIgnore;
  Collector.RootPrefix := IncludeTrailingPathDelimiter(RealRoot);
  Collector.ChangeLimit := 40000;
  Collector.Finished := False;
  Collector.Completed := False;
  Collector.StopOnHistoryDone := Mode = jmHistory;
  Collector.Unreliable := False;

  PathStr := CFStringCreateWithCString(kCFAllocatorDefault, PChar(RealRoot),
    kCFStringEncodingUTF8);
  Paths := CFArrayCreate(kCFAllocatorDefault, @PathStr, 1, @kCFTypeArrayCallBacks);

  FillChar(Context, SizeOf(Context), 0);
  Context.info := @Collector;

  Latency := 0.05;
  Stream := FSEventStreamCreate(
    kCFAllocatorDefault,
    @StreamCallback,
    @Context,
    Paths,
    SinceEventID,
    Latency,
    kFSEventStreamCreateFlagUseCFTypes
  );
  CFRelease(Paths);
  CFRelease(PathStr);

  if Stream = nil then
  begin
    Collector.Changed.Free;
    Collector.Subtrees.Free;
    Exit;
  end;

  FSEventStreamScheduleWithRunLoop(Stream, CFRunLoopGetCurrent,
    kCFRunLoopDefaultMode);
  if not FSEventStreamStart(Stream) then
  begin
    FSEventStreamInvalidate(Stream);
    FSEventStreamRelease(Stream);
    Collector.Changed.Free;
    Collector.Subtrees.Free;
    Exit;
  end;

  Started := GetTickCount64;
  while not Collector.Finished do
  begin
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, True);
    if (GetTickCount64 - Started) / 1000.0 >= TimeoutSec then
    begin
      { History mode: no HistoryDone yet, so the replay is incomplete.
        Live window: the window ending is the normal finish. }
      FinishCollector(@Collector, Mode = jmLiveWindow);
      Break;
    end;
  end;

  FSEventStreamStop(Stream);
  FSEventStreamInvalidate(Stream);
  FSEventStreamRelease(Stream);

  if Collector.Completed and (not Collector.Unreliable) and
     (DistinctCount(@Collector) <= Collector.ChangeLimit) then
  begin
    Result.OK := True;
    { Hand back plain lists; callers reorder them (by depth). }
    Collector.Changed.Sorted := False;
    Collector.Subtrees.Sorted := False;
    Result.ChangedDirectories := Collector.Changed;
    Result.SubtreesToRescan := Collector.Subtrees;
  end
  else
  begin
    Collector.Changed.Free;
    Collector.Subtrees.Free;
  end;
end;

{$ELSE}

function CurrentFSEventsID: QWord;
begin
  Result := 0;
end;

function CollectFSEventsChanges(SinceEventID: QWord; const RootPath: string;
  TimeoutSec: Double; Mode: TJournalMode): TFSEventsChanges;
begin
  Result.OK := False;
  Result.ChangedDirectories := nil;
  Result.SubtreesToRescan := nil;
end;

{$ENDIF}

function ReplayTimeBudget(ExpectedFullScanSeconds: Double): Double;
begin
  Result := ExpectedFullScanSeconds * 0.5;
  if Result < 2 then
    Result := 2;
  if Result > 30 then
    Result := 30;
end;

end.
