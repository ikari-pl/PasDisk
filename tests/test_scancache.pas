{ Round-trip FileTree serialization used by ScanCache, plus cache pruning
  (ScanCache.swift:111-145). All cache files go to a private temp dir. }

program test_scancache;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, BaseUnix, FileTree, Traversal, ScanCache;

var
  Tree, Loaded: TFileTree;
  Stream: TMemoryStream;
  Entry: TScanCacheEntry;
  Header: TScanCacheHeader;
  Path, CacheDir, SampleDir: string;
  Fail: Boolean;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Fail := True;
  end;
end;

{ Write Size bytes to Dir/Name and set its mtime to Now + AgeOffset seconds. }
procedure MakeFile(const Dir, Name: string; Size: Integer; AgeOffset: Int64);
var
  F: TFileStream;
  Buf: array of Byte;
  Times: TUTimBuf;
begin
  F := TFileStream.Create(IncludeTrailingPathDelimiter(Dir) + Name, fmCreate);
  try
    SetLength(Buf, Size);
    if Size > 0 then
    begin
      FillChar(Buf[0], Size, 0);
      F.WriteBuffer(Buf[0], Size);
    end;
  finally
    F.Free;
  end;
  Times.actime := fpTime + AgeOffset;
  Times.modtime := fpTime + AgeOffset;
  fpUtime(IncludeTrailingPathDelimiter(Dir) + Name, @Times);
end;

function Exists(const Dir, Name: string): Boolean;
begin
  Result := FileExists(IncludeTrailingPathDelimiter(Dir) + Name);
end;

function CountExt(const Dir, Ext: string): Integer;
var
  Rec: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*' + Ext, faAnyFile, Rec) = 0 then
  try
    repeat
      Inc(Result);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

procedure ClearDir(const Dir: string);
var
  Rec: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Rec) = 0 then
  try
    repeat
      if (Rec.Name <> '.') and (Rec.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(Dir) + Rec.Name);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

function CacheName(I: Integer): string;
begin
  Result := Format('%16.16x.dmscan', [I]);
end;

procedure TestCountCap;
var
  I: Integer;
begin
  ClearDir(CacheDir);
  { c0 is the oldest, c11 the newest. }
  for I := 0 to 11 do
    MakeFile(CacheDir, CacheName(I), 10, -1000 + I * 10);
  ScanCachePrune(CacheDir, '', 8, Int64(4) shl 30);
  Expect(CountExt(CacheDir, '.dmscan') = 8, 'count cap leaves 8');
  for I := 0 to 3 do
    Expect(not Exists(CacheDir, CacheName(I)), 'oldest evicted ' + IntToStr(I));
  for I := 4 to 11 do
    Expect(Exists(CacheDir, CacheName(I)), 'newest kept ' + IntToStr(I));
end;

procedure TestSizeCap;
var
  I: Integer;
begin
  ClearDir(CacheDir);
  for I := 0 to 4 do
    MakeFile(CacheDir, CacheName(I), 100, -1000 + I * 10);
  { Running total newest-first: 100, 200, 300 > 250 -> evict c2, c1, c0. }
  ScanCachePrune(CacheDir, '', 8, 250);
  Expect(CountExt(CacheDir, '.dmscan') = 2, 'size cap leaves 2');
  Expect(Exists(CacheDir, CacheName(4)) and Exists(CacheDir, CacheName(3)),
    'size cap keeps newest');
end;

procedure TestKeepNeverEvicted;
var
  I: Integer;
begin
  ClearDir(CacheDir);
  for I := 0 to 4 do
    MakeFile(CacheDir, CacheName(I), 10, -1000 + I * 10);
  { The protected file is the oldest; every other over-cap file goes. }
  ScanCachePrune(CacheDir, IncludeTrailingPathDelimiter(CacheDir) + CacheName(0),
    2, Int64(4) shl 30);
  Expect(Exists(CacheDir, CacheName(0)), 'kept path survives');
  Expect(Exists(CacheDir, CacheName(4)) and Exists(CacheDir, CacheName(3)),
    'two newest survive');
  Expect(CountExt(CacheDir, '.dmscan') = 3, 'keep + 2 newest');
end;

procedure TestTempFiles;
begin
  ClearDir(CacheDir);
  MakeFile(CacheDir, 'stale.tmp', 10, -7200);
  MakeFile(CacheDir, 'fresh.tmp', 10, -60);
  MakeFile(CacheDir, 'other.txt', 10, -7200);
  ScanCachePrune(CacheDir, '', 8, Int64(4) shl 30);
  Expect(not Exists(CacheDir, 'stale.tmp'), 'stale tmp removed');
  Expect(Exists(CacheDir, 'fresh.tmp'), 'fresh tmp kept');
  Expect(Exists(CacheDir, 'other.txt'), 'unrelated file ignored');
end;

procedure TestSavePrunes(T: TFileTree; const Root: string);
var
  I: Integer;
  Written: string;
begin
  ClearDir(CacheDir);
  Written := ScanCacheFilePath(Root);
  { Ten older caches: saving must leave 8, the new one among them. }
  for I := 0 to 9 do
    MakeFile(CacheDir, CacheName(I), 10, -1000 + I * 10);
  Expect(ScanCacheSave(T, Root, Header), 'save with old caches');
  Expect(FileExists(Written), 'new cache present');
  Expect(CountExt(CacheDir, '.dmscan') = 8, 'save prunes to 8');
  Expect(not Exists(CacheDir, CacheName(0)) and not Exists(CacheDir, CacheName(2)),
    'save evicts oldest');
  Expect(Exists(CacheDir, CacheName(3)), 'save keeps 7 newest old caches');

  { Eight caches newer than the one being written: the new file is 9th by
    date but must not be evicted (ScanCache.swift:141-142). }
  ClearDir(CacheDir);
  for I := 0 to 7 do
    MakeFile(CacheDir, CacheName(I), 10, 1000 + I * 10);
  Expect(ScanCacheSave(T, Root, Header), 'save with newer caches');
  Expect(FileExists(Written), 'just-written cache never evicted');
  Expect(CountExt(CacheDir, '.dmscan') = 9, 'newer caches all kept');
end;

begin
  Fail := False;
  CacheDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    Format('opendisk-scancache-test-%d', [fpGetPid]);
  SampleDir := CacheDir + '-tree';
  ForceDirectories(CacheDir);
  ForceDirectories(SampleDir);
  ScanCacheSetDirectory(CacheDir);
  Header.EventID := 42;
  Header.CapturedAt := 1;
  Header.FullScanSeconds := 0.5;

  TestCountCap;
  TestSizeCap;
  TestKeepNeverEvicted;
  TestTempFiles;

  MakeFile(SampleDir, 'a.bin', 64, 0);
  Tree := ScanPath(SampleDir);
  try
    TestSavePrunes(Tree, Tree.NameOf(RootID));
  finally
    Tree.Free;
  end;

  Path := ParamStr(1);
  if Path = '' then
    Path := '/tmp/opendisk-rings-test';
  if not DirectoryExists(Path) then
    WriteLn('skip round trip: missing ', Path)
  else
  begin
    Tree := ScanPath(Path);
    try
      Stream := TMemoryStream.Create;
      try
        Tree.WriteSerialized(Stream);
        Stream.Position := 0;
        Loaded := TFileTree.LoadSerialized(Stream);
        Expect(Loaded <> nil, 'load');
        if Loaded <> nil then
        try
          Expect(Loaded.NodeCount = Tree.NodeCount, 'node count');
          Expect(Loaded.SizeOf(RootID) = Tree.SizeOf(RootID), 'root size');
          Expect(Loaded.NameOf(RootID) = Tree.NameOf(RootID), 'root name');
        finally
          Loaded.Free;
        end;
      finally
        Stream.Free;
      end;

      Expect(ScanCacheSave(Tree, Tree.NameOf(RootID), Header), 'save');
      Entry := ScanCacheLoad(Tree.NameOf(RootID));
      Expect(Entry.OK, 'cache load');
      if Entry.OK then
      try
        Expect(Entry.Header.EventID = 42, 'event id');
        Expect(Entry.Tree.SizeOf(RootID) = Tree.SizeOf(RootID), 'cached size');
      finally
        Entry.Tree.Free;
      end;
    finally
      Tree.Free;
    end;
  end;

  ClearDir(CacheDir);
  RemoveDir(CacheDir);
  ClearDir(SampleDir);
  RemoveDir(SampleDir);

  if Fail then
    Halt(1);
  WriteLn('OK scan-cache round trip + pruning');
end.
