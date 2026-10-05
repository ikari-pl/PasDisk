{ Traversal.ScanPath: hard links count once; symlinks are listed as leaf
  files and never followed (BulkDirectoryReader.swift treats every
  non-directory as a file); roll-up equals the sum of children. }

program test_traversal;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils, Classes, FileTree, Traversal, PlatformFS, DirReader, PlatformVolumes;

var
  Fail: Boolean;
  Root: string;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Fail := True;
  end
  else
    WriteLn('ok: ', Msg);
end;

procedure WriteBytes(const Path: string; Count: Integer);
var
  F: TFileStream;
  Data: array of Byte;
begin
  SetLength(Data, Count);
  FillChar(Data[0], Count, 7);
  F := TFileStream.Create(Path, fmCreate);
  try
    F.WriteBuffer(Data[0], Count);
  finally
    F.Free;
  end;
end;

function Total: Int64;
var
  T: TFileTree;
begin
  T := ScanPath(Root);
  try
    Result := T.SizeOf(RootID);
  finally
    T.Free;
  end;
end;

procedure Cleanup(const Path: string);
var
  SR: TSearchRec;
  P: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile or faSymLink, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Path) + SR.Name;
      {$IFDEF UNIX}
      if fpReadLink(P) <> '' then
      begin
        fpUnlink(PChar(P));
        Continue;
      end;
      {$ENDIF}
      if (SR.Attr and faDirectory) <> 0 then
        Cleanup(P)
      else
        DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

var
  Before, WithLink, WithSymlinks: Int64;
  T: TFileTree;
  Dir: TNodeID;
  Kids: TFPList;
  I: Integer;
  Sum: Int64;
procedure TestAllowedDevices;
var
  Devs: TDeviceSet;
  Data: string;
begin
  { ScanEngine.swift subtreeAllowedDevices: a scan of / also walks the Data
    volume behind the firmlinks; any other root stays on its own device. }
  Devs := SubtreeAllowedDevices('/');
  Expect(DeviceInSet(Devs, DeviceIDOfPath('/')), '/ allows its own device');
  Data := DataVolumeMountPoint;
  if Data <> '' then
    Expect(DeviceInSet(Devs, DeviceIDOfPath(Data)),
      '/ also allows the Data volume (' + Data + ')')
  else
    WriteLn('skip: no separate Data volume');
  Devs := SubtreeAllowedDevices(Root);
  Expect((Length(Devs) = 1) and (Devs[0] = DeviceIDOfPath(Root)),
    'a non-root scan allows only its own device');
end;

begin
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_trav_' + IntToStr(GetProcessID);
  Cleanup(Root);
  ForceDirectories(Root + '/a/b');
  ForceDirectories(Root + '/outside-target');
  WriteBytes(Root + '/outside-target/big', 256 * 1024);
  try
    WriteBytes(Root + '/a/data', 100 * 1024);
    WriteBytes(Root + '/a/b/more', 50 * 1024);
    Before := Total;
    TestAllowedDevices;

    Expect(CreateHardLink(Root + '/a/data', Root + '/a/b/data-link'), 'create hard link');
    WithLink := Total;
    Expect(WithLink = Before, Format('hard link counts once (%d = %d)', [WithLink, Before]));

    {$IFDEF UNIX}
    Expect(fpSymlink(PChar(Root + '/outside-target'), PChar(Root + '/a/dir-link')) = 0,
      'create directory symlink');
    Expect(fpSymlink(PChar(Root + '/outside-target/big'), PChar(Root + '/a/file-link')) = 0,
      'create file symlink');
    WithSymlinks := Total;
    Expect(WithSymlinks = WithLink,
      Format('symlinks add nothing and are not followed (%d = %d)', [WithSymlinks, WithLink]));
    {$ENDIF}

    T := ScanPath(Root + '/a');
    Kids := TFPList.Create;
    try
      {$IFDEF UNIX}
      Dir := T.ChildNamed(RootID, 'dir-link');
      Expect((Dir <> NoNode) and not T.IsDirectory(Dir) and (T.ChildCount(Dir) = 0),
        'directory symlink is a leaf file, not descended into');
      Dir := T.ChildNamed(RootID, 'file-link');
      Expect((Dir <> NoNode) and (T.SizeOf(Dir) < 256 * 1024),
        'file symlink counts its own size, not the target''s');
      {$ENDIF}
      Dir := T.ChildNamed(RootID, 'b');
      Expect((Dir <> NoNode) and T.IsDirectory(Dir), 'subdirectory is scanned');
      T.ChildrenOf(RootID, Kids);
      Sum := 0;
      for I := 0 to Kids.Count - 1 do
        Sum := Sum + T.SizeOf(TNodeID(PtrUInt(Kids[I])));
      Expect(Sum = T.SizeOf(RootID), 'directory size equals the sum of its children');
    finally
      Kids.Free;
      T.Free;
    end;
  finally
    Cleanup(Root);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_traversal: all passed');
end.
