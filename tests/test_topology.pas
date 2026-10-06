{ ScanTopology: ScanEngine.swift performScan topology. }

program test_topology;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, FileTree, ScanTopology, PlatformVolumes, ScanCache, PlatformFS;

var
  Failures: Integer;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('ok: ', Msg)
  else
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end;
end;

procedure TestAlias;
begin
  Expect(ResolveDataVolumeAlias('/tmp') = '/tmp', 'an existing path is used as is');
  Expect(ResolveDataVolumeAlias('/no-such-path-opendisk') = '/no-such-path-opendisk',
    'a path missing on both volumes is unchanged');
end;

procedure TestSiblings;
var
  Names: TStringArray;
  I: Integer;
  Clean: Boolean;
begin
  Names := SiblingVolumeNames;
  if SystemVolumesDirectory = '' then
  begin
    Expect(Length(Names) = 0, 'no boot volume group off macOS');
    Exit;
  end;
  Clean := True;
  for I := 0 to High(Names) do
    if (Names[I] = 'Data') or (Names[I][1] = '.') then
      Clean := False;
  Expect(Clean, 'Data and dot names are never siblings');
  Expect(Length(Names) > 0, 'this Mac has boot-group siblings: ' + string.Join(',', Names));
end;

procedure TestSubtreeRootName;
var
  Dir: string;
  T: TFileTree;
begin
  Dir := GetTempDir(False) + 'opendisk-topology-' + IntToStr(GetProcessID);
  ForceDirectories(Dir + '/sub');
  T := ScanForAnalysis(Dir);
  try
    Expect(T.NameOf(RootID) = Dir, 'root name is the requested path');
    Expect(T.ChildNamed(RootID, 'sub') <> NoNode, 'a plain subtree scan walks the path');
  finally
    T.Free;
    RemoveDir(Dir + '/sub');
    RemoveDir(Dir);
  end;
end;

var
  Phases: string;
  CachedSnapshots: Integer;

procedure RecordPhase(CheckingChanges: Boolean);
begin
  if CheckingChanges then
    Phases := Phases + 'C'
  else
    Phases := Phases + 'S';
end;

procedure CountSnapshot(Tree: TFileTree);
begin
  Inc(CachedSnapshots);
  Tree.Free;
end;

{ ScanEngine.swift scanRootTreeUsingCache. }
procedure TestCache;
var
  Dir, CacheDir: string;
  T: TFileTree;
  F: TFileStream;
begin
  Dir := GetTempDir(False) + 'opendisk-topology-cache-' + IntToStr(GetProcessID);
  CacheDir := Dir + '-cache';
  ForceDirectories(Dir + '/sub');
  ForceDirectories(CacheDir);
  { Callers pass real paths (FSEvents reports /private/var, not /var). }
  Dir := ResolveRealPath(Dir);
  ScanCacheSetDirectory(CacheDir);
  try
    F := TFileStream.Create(Dir + '/sub/a.bin', fmCreate);
    F.Size := 50000;
    F.Free;
    Phases := '';
    T := ScanForAnalysis(Dir, nil, nil, nil, nil, True, @RecordPhase);
    T.Free;
    Expect(Phases = '', 'first scan: no cache, no checking phase');
    Expect(FileExists(ScanCacheFilePath(Dir)), 'first scan saves the cache');

    F := TFileStream.Create(Dir + '/sub/b.bin', fmCreate);
    F.Size := 70000;
    F.Free;
    { Let FSEvents write the change to its history. }
    Sleep(3000);
    Phases := '';
    CachedSnapshots := 0;
    T := ScanForAnalysis(Dir, nil, nil, nil, @CountSnapshot, True, @RecordPhase);
    try
      Expect(Phases = 'CS', 'second scan checks the cache first (phases ' + Phases + ')');
      Expect(CachedSnapshots >= 1, 'the cached tree is shown while changes apply');
      Expect(T.NodeIDForPath(Dir + '/sub/b.bin', Dir) <> NoNode,
        'the file added between scans is in the result');
      Expect(T.NameOf(RootID) = Dir, 'root name kept');
    finally
      T.Free;
    end;

    Phases := '';
    T := ScanForAnalysis(Dir, nil, nil, nil, nil, False, @RecordPhase);
    T.Free;
    Expect(Phases = '', 'without UseCache the cache is ignored');
  finally
    ScanCacheSetDirectory('');
    DeleteFile(Dir + '/sub/a.bin');
    DeleteFile(Dir + '/sub/b.bin');
    RemoveDir(Dir + '/sub');
    RemoveDir(Dir);
  end;
end;

begin
  Failures := 0;
  TestAlias;
  TestSiblings;
  TestSubtreeRootName;
  TestCache;
  if Failures > 0 then
  begin
    WriteLn('test_topology: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_topology: all passed');
end.
