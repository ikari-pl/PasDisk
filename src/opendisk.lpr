{ OpenDisk CLI — scan a path, or open an HTML rings view. }

program opendisk;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads, Unix,
  {$ENDIF}
  SysUtils, Classes, DateUtils, FileTree, Traversal, Formatters, ChartItem, RingsSVG,
  SearchIndex, Incremental, FSEventsJournal, ScanCache, Volumes, PlatformFS;

var
  LastProgressAt: QWord;

function ResolvePath(const Path: string): string;
begin
  Result := ResolveRealPath(Path);
end;

procedure OnProgress(BytesScanned: Int64; ItemsScanned: Integer);
var
  NowTick: QWord;
begin
  NowTick := GetTickCount64;
  if (NowTick - LastProgressAt) < 200 then
    Exit;
  LastProgressAt := NowTick;
  Write(Format(#13'Scanning: %s (%d items)',
    [FormatFileSize(BytesScanned), ItemsScanned]));
  Flush(Output);
end;

procedure PrintUsage;
begin
  WriteLn('OpenDisk — cross-platform disk usage scanner');
  WriteLn('Usage:');
  WriteLn('  opendisk scan <path>           Full scan (saves cache)');
  WriteLn('  opendisk rescan <path>         Apply FSEvents deltas to cache (macOS)');
  WriteLn('  opendisk view <path>           Scan and open SVG rings in the browser');
  WriteLn('  opendisk search <path> <query> Scan then search names (largest first)');
  WriteLn('  opendisk watch <path>          Live FSEvents window after a scan');
  WriteLn('  opendisk volumes               List mounted volumes');
  WriteLn('  opendisk version               Print version');
end;

{ EventID and CapturedAt are taken when the scan starts (ScanEngine.swift
  startEventID / startedAt), so changes during the scan replay next time. }
procedure SaveScanCache(Tree: TFileTree; const RootPath: string;
  EventID: QWord; CapturedAt, FullScanSeconds: Double);
var
  Header: TScanCacheHeader;
begin
  Header.EventID := EventID;
  Header.CapturedAt := CapturedAt;
  Header.FullScanSeconds := FullScanSeconds;
  if ScanCacheSave(Tree, RootPath, Header) then
    WriteLn('Cache saved: ', ScanCacheFilePath(RootPath))
  else
    WriteLn(StdErr, 'Warning: could not save scan cache');
end;

{ ScanEngine.swift: recorded full-scan time, else cache size at 10 MB/s. }
function ExpectedFullScanSeconds(const Header: TScanCacheHeader;
  const RootPath: string): Double;
var
  SR: TSearchRec;
begin
  if Header.FullScanSeconds > 0 then
    Exit(Header.FullScanSeconds);
  Result := 0;
  if FindFirst(ScanCacheFilePath(RootPath), faAnyFile, SR) = 0 then
  begin
    Result := SR.Size / 10000000.0;
    FindClose(SR);
  end;
end;

function DoScan(const Path: string): TFileTree;
var
  Expanded: string;
begin
  Expanded := ResolvePath(Path);
  if not DirectoryExists(Expanded) then
  begin
    WriteLn(StdErr, 'Not a directory: ', Expanded);
    Halt(1);
  end;
  WriteLn('Scanning ', Expanded, ' …');
  LastProgressAt := 0;
  Result := ScanPath(Expanded, @OnProgress, SubtreeAllowedDevices(Expanded));
  Write(#13, StringOfChar(' ', 60), #13);
end;

procedure FillLargestList(Tree: TFileTree; Dest: TStrings; Limit: Integer);
var
  Children: TFPList;
  I: Integer;
  ID: TNodeID;
  Line: string;
begin
  Children := TFPList.Create;
  try
    Tree.ChildrenSortedForDisplay(RootID, Children);
    if Limit > Children.Count then
      Limit := Children.Count;
    for I := 0 to Limit - 1 do
    begin
      ID := TNodeID(PtrUInt(Children[I]));
      Line := Format('%10s  %s',
        [FormatFileSize(Tree.SizeOf(ID)), Tree.NameOf(ID)]);
      if Tree.IsDirectory(ID) then
        Line := Line + DirectorySeparator;
      Dest.Add(Line);
    end;
  finally
    Children.Free;
  end;
end;

procedure CmdScan(const Path: string);
var
  Tree: TFileTree;
  Lines: TStringList;
  I: Integer;
  EventID: QWord;
  Started: QWord;
  StartedAt: Double;
begin
  EventID := CurrentFSEventsID;
  StartedAt := UnixTimeNow;
  Started := GetTickCount64;
  Tree := DoScan(Path);
  try
    SaveScanCache(Tree, Tree.NameOf(RootID), EventID, StartedAt,
      (GetTickCount64 - Started) / 1000.0);
    WriteLn('Total: ', FormatFileSize(Tree.SizeOf(RootID)),
      '  (', Tree.NodeCount - 1, ' items)');
    WriteLn;
    Lines := TStringList.Create;
    try
      FillLargestList(Tree, Lines, 40);
      for I := 0 to Lines.Count - 1 do
        WriteLn(Lines[I]);
    finally
      Lines.Free;
    end;
  finally
    Tree.Free;
  end;
end;

procedure CmdRescan(const Path: string);
var
  Expanded: string;
  Cached: TScanCacheEntry;
  Ev: TFSEventsChanges;
  Changes: TChangeSet;
  Before, After: Int64;
  EventID: QWord;
  Started: QWord;
  StartedAt: Double;
begin
  EventID := CurrentFSEventsID;
  StartedAt := UnixTimeNow;
  Expanded := ResolvePath(Path);
  Cached := ScanCacheLoad(Expanded);
  if not Cached.OK then
  begin
    WriteLn('No usable cache for ', Expanded, ' — doing a full scan.');
    CmdScan(Path);
    Exit;
  end;
  try
    Before := Cached.Tree.SizeOf(RootID);
    WriteLn('Cache hit (event ', Cached.Header.EventID, ', total ',
      FormatFileSize(Before), '). Checking FSEvents…');
    Ev := CollectFSEventsChanges(Cached.Header.EventID, Expanded,
      ReplayTimeBudget(ExpectedFullScanSeconds(Cached.Header, Expanded)));
    if not Ev.OK then
    begin
      WriteLn('Change journal unreliable — falling back to full scan.');
      Cached.Tree.Free;
      Cached.Tree := nil;
      CmdScan(Path);
      Exit;
    end;
    try
      Changes.ChangedDirectories := Ev.ChangedDirectories;
      Changes.SubtreesToRescan := Ev.SubtreesToRescan;
      WriteLn('Changes: ', Ev.ChangedDirectories.Count, ' dirs, ',
        Ev.SubtreesToRescan.Count, ' subtrees');
      if (Ev.ChangedDirectories.Count = 0) and (Ev.SubtreesToRescan.Count = 0) then
      begin
        WriteLn('Up to date. Total ', FormatFileSize(Before));
        SaveScanCache(Cached.Tree, Expanded, EventID, StartedAt,
          Cached.Header.FullScanSeconds);
        Exit;
      end;
      Started := GetTickCount64;
      if not ApplyChanges(Cached.Tree, Expanded, Changes,
        Cached.Header.CapturedAt, @OnProgress) then
      begin
        WriteLn('Incremental apply failed — full scan.');
        Cached.Tree.Free;
        Cached.Tree := nil;
        CmdScan(Path);
        Exit;
      end;
      Write(#13, StringOfChar(' ', 60), #13);
      After := Cached.Tree.SizeOf(RootID);
      WriteLn('Applied in ', Format('%.2fs', [(GetTickCount64 - Started) / 1000.0]),
        '. Total ', FormatFileSize(Before), ' → ', FormatFileSize(After));
      SaveScanCache(Cached.Tree, Expanded, EventID, StartedAt,
        Cached.Header.FullScanSeconds);
    finally
      Ev.ChangedDirectories.Free;
      Ev.SubtreesToRescan.Free;
    end;
  finally
    Cached.Tree.Free;
  end;
end;

procedure CmdVolumes;
var
  Vols: TVolumeInfoArray;
  I: Integer;
begin
  Vols := ListVolumes;
  if Length(Vols) = 0 then
  begin
    WriteLn('No volumes found.');
    Exit;
  end;
  for I := 0 to High(Vols) do
    WriteLn(Format('%-20s  %10s available / %10s  %s',
      [Vols[I].Name,
       FormatFileSize(Int64(Vols[I].AvailableBytes)),
       FormatFileSize(Int64(Vols[I].TotalBytes)),
       Vols[I].Path]));
end;

procedure OpenInBrowser(const FilePath: string);
begin
  WriteLn('Open this file in a browser:');
  WriteLn(FilePath);
  {$IFDEF DARWIN}
  try
    ExecuteProcess('/usr/bin/open', FilePath);
  except
    { path printed above }
  end;
  {$ENDIF}
end;

procedure CmdView(const Path: string);
var
  Tree: TFileTree;
  Chart: TChartItem;
  Lines: TStringList;
  HTML, OutFile, RootName, Expanded: string;
begin
  Expanded := ExpandFileName(Path);
  Tree := DoScan(Path);
  try
    RootName := ExtractFileName(ExcludeTrailingPathDelimiter(Expanded));
    if RootName = '' then
      RootName := Expanded;
    Chart := TChartItem.Build(Tree, RootID, RootName, Expanded);
    try
      Lines := TStringList.Create;
      try
        FillLargestList(Tree, Lines, 60);
        HTML := ChartToHTML(Chart, RootName, Expanded, Lines);
        OutFile := IncludeTrailingPathDelimiter(GetTempDir) +
          'opendisk-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.html';
        Lines.Text := HTML;
        Lines.SaveToFile(OutFile);
        WriteLn('Wrote ', OutFile);
        OpenInBrowser(OutFile);
      finally
        Lines.Free;
      end;
    finally
      Chart.Free;
    end;
  finally
    Tree.Free;
  end;
end;

procedure CmdSearch(const Path, Query: string);
var
  Tree: TFileTree;
  Index: TSearchIndex;
  Hits: TFPList;
  I: Integer;
  Hit: PSearchHit;
begin
  Tree := DoScan(Path);
  Index := TSearchIndex.Create(Tree, True);
  Hits := TFPList.Create;
  try
    Index.Search(Query, ssAll, Hits, 40);
    WriteLn('Matches for "', Query, '": ', Hits.Count);
    WriteLn;
    for I := 0 to Hits.Count - 1 do
    begin
      Hit := PSearchHit(Hits[I]);
      WriteLn(Format('%10s  %s',
        [FormatFileSize(Hit^.Size), Index.Tree.PathOf(Hit^.ID)]));
    end;
  finally
    FreeSearchHits(Hits);
    Hits.Free;
    Index.Free;
  end;
end;

procedure CmdWatch(const Path: string);
var
  Expanded: string;
  Tree: TFileTree;
  EventID: QWord;
  Ev: TFSEventsChanges;
  Changes: TChangeSet;
  Before, After: Int64;
  StartedAt: Double;
begin
  Expanded := ResolvePath(Path);
  EventID := CurrentFSEventsID;
  StartedAt := UnixTimeNow;
  Tree := DoScan(Path);
  try
    { Tree root name is the resolved scan path }
    Expanded := Tree.NameOf(RootID);
    Before := Tree.SizeOf(RootID);
    WriteLn('Watching for FSEvents since ', EventID, ' (5s window)…');
    WriteLn('Touch files under ', Expanded, ' now.');
    Ev := CollectFSEventsChanges(EventID, Expanded, 5.0, jmLiveWindow);
    if not Ev.OK then
    begin
      WriteLn('No reliable change set (timeout or dropped events). Tree unchanged.');
      WriteLn('Total still ', FormatFileSize(Before));
      Exit;
    end;
    try
      Changes.ChangedDirectories := Ev.ChangedDirectories;
      Changes.SubtreesToRescan := Ev.SubtreesToRescan;
      WriteLn('Changes: ', Ev.ChangedDirectories.Count, ' dirs, ',
        Ev.SubtreesToRescan.Count, ' subtrees');
      if ApplyChanges(Tree, Expanded, Changes, StartedAt, @OnProgress) then
      begin
        Write(#13, StringOfChar(' ', 60), #13);
        After := Tree.SizeOf(RootID);
        WriteLn('Applied. Total ', FormatFileSize(Before), ' → ',
          FormatFileSize(After), ' (', Tree.NodeCount - 1, ' nodes)');
      end
      else
        WriteLn('Incremental apply failed; re-run scan for a full refresh.');
    finally
      Ev.ChangedDirectories.Free;
      Ev.SubtreesToRescan.Free;
    end;
  finally
    Tree.Free;
  end;
end;

begin
  if ParamCount < 1 then
  begin
    PrintUsage;
    Halt(1);
  end;

  case LowerCase(ParamStr(1)) of
    'scan':
      begin
        if ParamCount < 2 then
        begin
          WriteLn(StdErr, 'scan requires a path');
          Halt(1);
        end;
        CmdScan(ParamStr(2));
      end;
    'rescan':
      begin
        if ParamCount < 2 then
        begin
          WriteLn(StdErr, 'rescan requires a path');
          Halt(1);
        end;
        CmdRescan(ParamStr(2));
      end;
    'volumes':
      CmdVolumes;
    'view':
      begin
        if ParamCount < 2 then
        begin
          WriteLn(StdErr, 'view requires a path');
          Halt(1);
        end;
        CmdView(ParamStr(2));
      end;
    'search':
      begin
        if ParamCount < 3 then
        begin
          WriteLn(StdErr, 'search requires a path and a query');
          Halt(1);
        end;
        CmdSearch(ParamStr(2), ParamStr(3));
      end;
    'watch':
      begin
        if ParamCount < 2 then
        begin
          WriteLn(StdErr, 'watch requires a path');
          Halt(1);
        end;
        CmdWatch(ParamStr(2));
      end;
    'version', '-v', '--version':
      WriteLn('opendisk 0.2.0-dev (pascal)');
    'help', '-h', '--help':
      PrintUsage;
  else
    WriteLn(StdErr, 'Unknown command: ', ParamStr(1));
    PrintUsage;
    Halt(1);
  end;
end.
