{ PlatformChangeJournal — the change journal for this OS.

  Darwin: FSEvents history / live stream (port of OpenDisk
  FSEventsChangeJournal.swift, using CFRunLoop instead of a DispatchQueue so
  it stays in plain FPC). Elsewhere: no journal yet (jrUnavailable; od-31j.15
  adds inotify / ReadDirectoryChangesW). Only JournalFactory uses this
  unit. }

unit PlatformChangeJournal;

{$mode objfpc}{$H+}

interface

uses
  ChangeJournal;

function PlatformCreateChangeJournal: TChangeJournal;

implementation

uses
  SysUtils, Classes
  {$IFDEF DARWIN}, BaseUnix, Unix, CFBase, CFArray, CFString, CFRunLoop,
  FSEvents, PlatformFS{$ENDIF};

type
  TNullChangeJournal = class(TChangeJournal)
  public
    function CurrentEventID: QWord; override;
    function Collect(SinceID: QWord; const Root: string; TimeoutSec: Double;
      Mode: TJournalMode; out Changes: TChangeSet): TJournalResult; override;
  end;

function TNullChangeJournal.CurrentEventID: QWord;
begin
  Result := 0;
end;

function TNullChangeJournal.Collect(SinceID: QWord; const Root: string;
  TimeoutSec: Double; Mode: TJournalMode; out Changes: TChangeSet): TJournalResult;
begin
  Changes.ChangedDirectories := nil;
  Changes.SubtreesToRescan := nil;
  Result := jrUnavailable;
end;

{$IFDEF DARWIN}
type
  TFSEventsChangeJournal = class(TChangeJournal)
  public
    function CurrentEventID: QWord; override;
    function Collect(SinceID: QWord; const Root: string; TimeoutSec: Double;
      Mode: TJournalMode; out Changes: TChangeSet): TJournalResult; override;
  end;

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

function TFSEventsChangeJournal.CurrentEventID: QWord;
begin
  Result := FSEventsGetCurrentEventId;
end;

function TFSEventsChangeJournal.Collect(SinceID: QWord; const Root: string;
  TimeoutSec: Double; Mode: TJournalMode; out Changes: TChangeSet): TJournalResult;
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
  Result := jrIncomplete;
  Changes.ChangedDirectories := nil;
  Changes.SubtreesToRescan := nil;

  { FSEvents emits real paths (/private/tmp/…); resolve symlinks so filters match. }
  RealRoot := ResolveRealPath(Root);

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
    SinceID,
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
    Result := jrChanges;
    { Hand back plain lists; callers reorder them (by depth). }
    Collector.Changed.Sorted := False;
    Collector.Subtrees.Sorted := False;
    Changes.ChangedDirectories := Collector.Changed;
    Changes.SubtreesToRescan := Collector.Subtrees;
  end
  else
  begin
    Collector.Changed.Free;
    Collector.Subtrees.Free;
  end;
end;
{$ENDIF}

function PlatformCreateChangeJournal: TChangeJournal;
begin
  {$IFDEF DARWIN}
  Result := TFSEventsChangeJournal.Create;
  {$ELSE}
  Result := TNullChangeJournal.Create;
  {$ENDIF}
end;

end.
