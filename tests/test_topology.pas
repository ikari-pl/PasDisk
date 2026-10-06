{ ScanTopology: ScanEngine.swift performScan topology. }

program test_topology;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, FileTree, ScanTopology, PlatformVolumes;

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

begin
  Failures := 0;
  TestAlias;
  TestSiblings;
  TestSubtreeRootName;
  if Failures > 0 then
  begin
    WriteLn('test_topology: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_topology: all passed');
end.
