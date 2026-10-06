{ Collector background deletion (Collector.swift deleteAll with
  DeletionProgress). }

program test_deletejob;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, Collector;

var
  Failures: Integer;
  Base: string;

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

procedure WriteFile(const Path: string; Bytes: Integer);
var
  F: TFileStream;
  Buf: array of Byte;
begin
  SetLength(Buf, Bytes);
  F := TFileStream.Create(Path, fmCreate);
  try
    if Bytes > 0 then
      F.WriteBuffer(Buf[0], Bytes);
  finally
    F.Free;
  end;
end;

procedure TestBackgroundDelete;
var
  C: TCollector;
  Job: TDeleteJob;
  P, Last: TDeletionProgress;
  I, J, Polls: Integer;
  Freed: Int64;
  Monotonic, Consistent: Boolean;
  Dir: string;
begin
  C := TCollector.Create;
  try
    for I := 1 to 40 do
    begin
      Dir := Format('%s/item%d', [Base, I]);
      ForceDirectories(Dir);
      for J := 1 to 25 do
        WriteFile(Format('%s/f%d', [Dir, J]), 100);
      C.Add(Dir, ExtractFileName(Dir), 2500, True);
    end;
    {$IFDEF UNIX}
    ForceDirectories(Base + '/locked/inner');
    WriteFile(Base + '/locked/inner/x', 10);
    fpChmod(PChar(Base + '/locked/inner'), &555);
    C.Add(Base + '/locked', 'locked', 10, True);
    {$ENDIF}
    Expect(C.CanUndo, 'staging recorded undo');

    Job := C.StartDelete;
    Monotonic := True;
    Consistent := True;
    Last.Completed := 0;
    Polls := 0;
    repeat
      P := Job.Progress;
      Inc(Polls);
      if P.Completed < Last.Completed then
        Monotonic := False;
      if (P.Total <> C.Count) or (P.Completed > P.Total) or
        (P.FreedBytes > Int64(P.Completed) * 2500) then
        Consistent := False;
      Last := P;
      Sleep(1);
    until Job.Finished;
    P := Job.Progress;
    Expect(Monotonic and Consistent, Format('progress is monotonic and consistent (%d polls)', [Polls]));
    Expect((P.Completed = P.Total) and (P.CurrentName = ''), 'final progress: all done');
    Freed := C.FinishDelete(Job);
    Expect(Freed = 40 * 2500, Format('freed bytes reported (%d)', [Freed]));
    Expect(not DirectoryExists(Base + '/item1') and not DirectoryExists(Base + '/item40'),
      'items removed from disk');
    {$IFDEF UNIX}
    Expect((C.Count = 1) and C.Contains(Base + '/locked'), 'the failed item stays staged');
    Expect((C.Failures.Count = 1) and (Pos(Base + '/locked'#9, C.Failures[0]) = 1),
      'the failure is listed');
    fpChmod(PChar(Base + '/locked/inner'), &755);
    {$ENDIF}
    Expect(not C.CanUndo, 'deleting clears undo');
  finally
    C.Free;
  end;
end;

begin
  Failures := 0;
  Base := GetTempDir(False) + 'opendisk-test-deletejob-' + IntToStr(GetProcessID);
  ForceDirectories(Base);
  TestBackgroundDelete;
  with TCollector.Create do
  try
    Add(Base, 'base', 0, True);
    DeleteAll;
  finally
    Free;
  end;
  if Failures > 0 then
  begin
    WriteLn('test_deletejob: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_deletejob: all passed');
end.
