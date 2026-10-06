{ Incremental never refreshes another volume mounted inside the scan
  (IncrementalUpdater.swift resolveTarget + allowedDevices). Mounts a
  small disk image with hdiutil (no root needed); Darwin only. }

program test_volumeroot;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Process, FileTree, DirTypes, PlatformDirReader, Traversal, Incremental, ChangeJournal,
  PlatformFS, Volumes;

var
  Fail: Boolean;
  Root, Image, Mount: string;

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

function Run(const Args: array of string): Boolean;
var
  Output: string;
begin
  Result := RunCommand('/usr/bin/hdiutil', Args, Output, [poStderrToOutPut]);
end;

procedure WriteBytes(const Path: string; Count: Integer);
var
  F: TFileStream;
  Data: array of Byte;
begin
  SetLength(Data, Count);
  FillChar(Data[0], Count, 1);
  F := TFileStream.Create(Path, fmCreate);
  try
    F.WriteBuffer(Data[0], Count);
  finally
    F.Free;
  end;
end;

var
  Tree: TFileTree;
  Node: TNodeID;
  Before: Int64;
  Changes: TChangeSet;
begin
  {$IFNDEF DARWIN}
  WriteLn('test_volumeroot: skipped (hdiutil is macOS-only)');
  Exit;
  {$ENDIF}
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_vroot_' + IntToStr(GetProcessID);
  Image := Root + '.dmg';
  Mount := Root + '/mnt';
  ForceDirectories(Mount);
  WriteBytes(Root + '/local', 64 * 1024);
  if not Run(['create', '-quiet', '-size', '4m', '-fs', 'HFS+', '-volname',
    'odvroot', Image]) or
     not Run(['attach', '-quiet', '-nobrowse', '-mountpoint', Mount, Image]) then
  begin
    WriteLn('test_volumeroot: skipped (hdiutil could not create/attach an image)');
    RemoveDir(Mount);
    DeleteFile(Root + '/local');
    RemoveDir(Root);
    DeleteFile(Image);
    Exit;
  end;
  try
    WriteBytes(Mount + '/foreign', 1024 * 1024);

    Expect(IsVolumeRoot(Mount), 'mounted image is a volume root');
    Expect(not IsVolumeRoot(Root), 'scan root is not a volume root');
    Expect(not IsVolumeRoot('/Users'), '/Users (firmlink) is not a volume root');

    Tree := ScanPath(Root);
    try
      Node := Tree.ChildNamed(RootID, 'mnt');
      Expect((Node <> NoNode) and (Tree.ChildCount(Node) = 0),
        'full scan records the mount point without entering it');
      Before := Tree.SizeOf(RootID);
      Expect(Before < 1024 * 1024, 'foreign volume bytes are not counted');

      Changes.ChangedDirectories := TStringList.Create;
      Changes.SubtreesToRescan := TStringList.Create;
      try
        Changes.ChangedDirectories.Add(Mount);
        Changes.SubtreesToRescan.Add(Mount);
        Expect(ApplyChanges(Tree, Root, Changes, UnixTimeNow),
          'events on a mounted volume root apply (skipped)');
      finally
        Changes.ChangedDirectories.Free;
        Changes.SubtreesToRescan.Free;
      end;
      Expect(Tree.ChildCount(Tree.ChildNamed(RootID, 'mnt')) = 0,
        'incremental update does not pull the foreign volume in');
      Expect(Tree.SizeOf(RootID) = Before,
        Format('total unchanged after mount-point events (%d = %d)',
          [Tree.SizeOf(RootID), Before]));

      Changes.ChangedDirectories := TStringList.Create;
      Changes.SubtreesToRescan := TStringList.Create;
      try
        Changes.ChangedDirectories.Add(Root);
        Expect(ApplyChanges(Tree, Root, Changes, UnixTimeNow),
          'refreshing the parent directory applies');
      finally
        Changes.ChangedDirectories.Free;
        Changes.SubtreesToRescan.Free;
      end;
      Expect(Tree.ChildCount(Tree.ChildNamed(RootID, 'mnt')) = 0,
        'parent refresh keeps the mount point as an empty leaf');
    finally
      Tree.Free;
    end;
  finally
    Run(['detach', '-quiet', '-force', Mount]);
    RemoveDir(Mount);
    DeleteFile(Root + '/local');
    RemoveDir(Root);
    DeleteFile(Image);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_volumeroot: all passed');
end.
