{ FSEventsJournal: history replay ends on HistoryDone (FSEventsChangeJournal
  .swift), so an unchanged tree answers quickly; changes are still seen. }

program test_fsevents;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, FSEventsJournal, PlatformFS;

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

procedure Touch(const Path: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  F.Free;
end;

procedure FreeChanges(var Ev: TFSEventsChanges);
begin
  Ev.ChangedDirectories.Free;
  Ev.SubtreesToRescan.Free;
end;

var
  EventID: QWord;
  Ev: TFSEventsChanges;
  Started: QWord;
  Elapsed: Double;
begin
  {$IFNDEF DARWIN}
  WriteLn('test_fsevents: skipped (FSEvents is Darwin-only)');
  Exit;
  {$ENDIF}
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_fse_' + IntToStr(GetProcessID);
  ForceDirectories(Root + '/sub');
  try
    { Let the directory creation events land before taking the id. }
    Sleep(1500);
    EventID := CurrentFSEventsID;

    Started := GetTickCount64;
    Ev := CollectFSEventsChanges(EventID, Root, 10.0);
    Elapsed := (GetTickCount64 - Started) / 1000.0;
    Expect(Ev.OK, 'unchanged tree: history replay completes');
    Expect(Elapsed < 1.5, Format('unchanged tree answers fast (%.2fs < 1.5s, timeout 10s)', [Elapsed]));
    if Ev.OK then
    begin
      Expect(Ev.ChangedDirectories.Count + Ev.SubtreesToRescan.Count = 0,
        'unchanged tree reports no changes');
      FreeChanges(Ev);
    end;

    Touch(Root + '/sub/new-file');
    Sleep(1500);
    Ev := CollectFSEventsChanges(EventID, Root, 10.0);
    Expect(Ev.OK, 'changed tree: history replay completes');
    if Ev.OK then
    begin
      Expect(Ev.ChangedDirectories.IndexOf(Root + '/sub') >= 0,
        'new file reports its directory as changed');
      FreeChanges(Ev);
    end;

    { Live window keeps listening for the full window and succeeds. }
    Started := GetTickCount64;
    Ev := CollectFSEventsChanges(CurrentFSEventsID, Root, 1.0, jmLiveWindow);
    Elapsed := (GetTickCount64 - Started) / 1000.0;
    Expect(Ev.OK and (Elapsed >= 0.9), Format('live window runs its window (%.2fs)', [Elapsed]));
    if Ev.OK then
      FreeChanges(Ev);

    Expect(Abs(ReplayTimeBudget(0) - 2) < 1e-9, 'replay budget floor is 2s');
    Expect(Abs(ReplayTimeBudget(10) - 5) < 1e-9, 'replay budget is half the full scan');
    Expect(Abs(ReplayTimeBudget(600) - 30) < 1e-9, 'replay budget caps at 30s');
  finally
    DeleteFile(Root + '/sub/new-file');
    RemoveDir(Root + '/sub');
    RemoveDir(Root);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_fsevents: all passed');
end.
