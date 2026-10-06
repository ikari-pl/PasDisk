{ Collector: undo only on real change, safe deletion that never follows
  links, failed items stay staged (OpenDisk Models/Collector.swift). }

program test_collector;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils, Classes, Collector, PlatformFS;

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

procedure WriteText(const Path, Text: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := Text;
    L.SaveToFile(Path);
  finally
    L.Free;
  end;
end;

function MakeSymlink(const Target, Link: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := fpSymlink(PChar(Target), PChar(Link)) = 0;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

procedure TestAddManyAndDragOut;
var
  C: TCollector;
  Dir: string;
  Files: array of TCollectedEntry;
  I: Integer;
begin
  Dir := Root + '/addmany';
  ForceDirectories(Dir);
  SetLength(Files, 3);
  for I := 0 to 2 do
  begin
    Files[I].Name := 'f' + IntToStr(I);
    Files[I].Path := Dir + '/' + Files[I].Name;
    Files[I].Size := 10 * (I + 1);
    Files[I].IsDirectory := False;
    WriteText(Files[I].Path, 'x');
  end;
  C := TCollector.Create;
  try
    { add(_ files:) is one recordingUndo. }
    Expect(C.AddMany(Files) = 3, 'AddMany stages all three');
    Expect(C.UndoCount = 1, 'AddMany records a single undo step');
    Expect(C.AddMany(Files) = 0, 'AddMany of staged files stages none');
    Expect(C.UndoCount = 1, 'a no-op AddMany records no undo');
    C.RemoveMany([Files[0].Path, Files[1].Path, '/nonexistent']);
    Expect((C.Count = 1) and (C.UndoCount = 2), 'RemoveMany is one undo step');
    Expect(C.Undo and (C.Count = 3), 'undo restores both removed items');

    { Drag-out dropped outside the keep zones unstages, as one step. }
    C.BeginDragOut([Files[0].Path, Files[2].Path, '/not/staged']);
    Expect(C.IsDraggingOut, 'drag-out pending');
    C.ResolveDragOut(False);
    Expect((C.Count = 1) and not C.IsDraggingOut, 'drop outside unstages the dragged items');
    Expect(C.Undo and (C.Count = 3), 'one undo brings the dragged items back');
    { Dropped back on the bar: kept. }
    C.BeginDragOut([Files[1].Path]);
    C.ResolveDragOut(True);
    Expect(C.Count = 3, 'drop on a keep zone keeps the items');
    { endDragOut with no operation (dropped nowhere) unstages. }
    C.BeginDragOut([Files[1].Path]);
    C.EndDragOut(False);
    Expect((C.Count = 2) and not C.Contains(Files[1].Path), 'drag ended with no operation unstages');
    { Another app accepted the drop: kept, pending until cancelled. }
    C.BeginDragOut([Files[0].Path]);
    C.EndDragOut(True);
    Expect(C.IsDraggingOut and (C.Count = 2), 'accepted drop keeps items');
    C.CancelDragOut;
    Expect(not C.IsDraggingOut, 'cancel clears the drag-out');
  finally
    C.Free;
  end;
  for I := 0 to 2 do
    DeleteFile(Files[I].Path);
  RemoveDir(Dir);
end;

procedure TestUndoOnlyOnChange;
var
  C: TCollector;
begin
  C := TCollector.Create;
  try
    C.Clear;
    Expect(not C.CanUndo, 'clear on empty records no undo');
    C.Remove(Root + '/nothing');
    Expect(not C.CanUndo, 'removing an absent path records no undo');
    Expect(not C.Add(Root + '/missing', 'missing', 1, False),
      'adding a missing path is rejected');
    Expect(not C.CanUndo, 'rejected add records no undo');

    Expect(C.Add(Root + '/dir', 'dir', 100, True), 'add directory');
    Expect(C.UndoCount = 1, 'real add records one undo');
    Expect(not C.Add(Root + '/dir', 'dir', 100, True), 're-adding the same path is a no-op');
    Expect(not C.Add(Root + '/dir/a.txt', 'a.txt', 10, False),
      'adding a child of a staged directory is a no-op');
    Expect(C.UndoCount = 1, 'no-op adds record no undo');

    C.Clear;
    Expect((C.Count = 0) and (C.UndoCount = 2), 'clear with items records undo');
    Expect(C.Undo and (C.Count = 1), 'undo restores the cleared item');
  finally
    C.Free;
  end;
end;

procedure TestNestedDedup;
var
  C: TCollector;
begin
  C := TCollector.Create;
  try
    Expect(C.Add(Root + '/dir/a.txt', 'a.txt', 10, False), 'stage a child file');
    Expect(C.Add(Root + '/dir', 'dir', 100, True), 'stage its parent directory');
    Expect((C.Count = 1) and (TCollectedFile(C.Items[0]).Path = Root + '/dir'),
      'parent directory replaces staged children');
  finally
    C.Free;
  end;
end;

procedure TestSymlinkNeverFollowed;
var
  C: TCollector;
  Freed: Int64;
begin
  ForceDirectories(Root + '/target/deep');
  WriteText(Root + '/target/keep.txt', 'precious');
  WriteText(Root + '/target/deep/keep2.txt', 'precious');
  ForceDirectories(Root + '/staged');
  WriteText(Root + '/staged/own.txt', 'mine');
  Expect(MakeSymlink(Root + '/target', Root + '/link-to-target'), 'create top-level dir symlink');
  Expect(MakeSymlink(Root + '/target', Root + '/staged/inner-link'), 'create dir symlink inside a staged dir');

  C := TCollector.Create;
  try
    Expect(C.Add(Root + '/link-to-target', 'link-to-target', 0, True), 'stage symlink to directory');
    Expect(C.Add(Root + '/staged', 'staged', 4, True), 'stage directory containing a symlink');
    Freed := C.DeleteAll;
    Expect(C.Failures.Count = 0, 'both removals succeed');
    Expect(Freed = 4, Format('freed counts successful items (%d)', [Freed]));
    Expect(FileExists(Root + '/target/keep.txt') and FileExists(Root + '/target/deep/keep2.txt'),
      'symlink targets are untouched');
    Expect(not DirectoryExists(Root + '/staged'), 'staged directory removed');
    Expect(not FileExists(Root + '/link-to-target') and not DirectoryExists(Root + '/link-to-target'),
      'top-level symlink removed');
  finally
    C.Free;
  end;
end;

procedure TestFailedItemsStayStaged;
var
  C: TCollector;
  Freed: Int64;
begin
  ForceDirectories(Root + '/locked/inner');
  WriteText(Root + '/locked/inner/f.txt', 'x');
  WriteText(Root + '/ok.txt', 'y');
  C := TCollector.Create;
  try
    Expect(C.Add(Root + '/locked/inner/f.txt', 'f.txt', 7, False), 'stage file in read-only dir');
    Expect(C.Add(Root + '/ok.txt', 'ok.txt', 3, False), 'stage deletable file');
    {$IFDEF UNIX}
    fpChmod(PChar(Root + '/locked/inner'), &555);
    {$ENDIF}
    Freed := C.DeleteAll;
    Expect(Freed = 3, Format('only the successful removal is counted (%d)', [Freed]));
    Expect((C.Count = 1) and (TCollectedFile(C.Items[0]).Path = Root + '/locked/inner/f.txt'),
      'failed item stays staged');
    Expect(C.Failures.Count = 1, 'failure is reported');
    Expect(not C.CanUndo, 'delete clears undo history');
  finally
    {$IFDEF UNIX}
    fpChmod(PChar(Root + '/locked/inner'), &755);
    {$ENDIF}
    C.Free;
  end;
end;

procedure Cleanup(const Path: string);
var
  SR: TSearchRec;
  P: string;
begin
  {$IFDEF UNIX}
  if fpReadLink(Path) <> '' then
  begin
    fpUnlink(PChar(Path));
    Exit;
  end;
  {$ENDIF}
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

begin
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_coll_' + IntToStr(GetProcessID);
  Cleanup(Root);
  ForceDirectories(Root + '/dir');
  WriteText(Root + '/dir/a.txt', 'a');
  try
    TestUndoOnlyOnChange;
    TestAddManyAndDragOut;
    TestNestedDedup;
    TestSymlinkNeverFollowed;
    TestFailedItemsStayStaged;
  finally
    Cleanup(Root);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_collector: all passed');
end.
