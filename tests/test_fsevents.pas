{ ChangeJournal: on Darwin, history replay ends when the FSEvents history
  is done (FSEventsChangeJournal.swift), so an unchanged tree answers
  quickly and changes are still seen; the live window runs its window.
  Elsewhere the journal is unavailable and says so. }

program test_fsevents;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, ChangeJournal, JournalFactory, PlatformFS;

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

procedure FreeChanges(var Changes: TChangeSet);
begin
  Changes.ChangedDirectories.Free;
  Changes.SubtreesToRescan.Free;
end;

var
  Journal: TChangeJournal;
  EventID: QWord;
  Changes: TChangeSet;
  Collected: TJournalResult;
  Started: QWord;
  Elapsed: Double;
begin
  Fail := False;
  Expect(Abs(ReplayTimeBudget(0) - 2) < 1e-9, 'replay budget floor is 2s');
  Expect(Abs(ReplayTimeBudget(10) - 5) < 1e-9, 'replay budget is half the full scan');
  Expect(Abs(ReplayTimeBudget(600) - 30) < 1e-9, 'replay budget caps at 30s');

  Root := ResolveRealPath(GetTempDir(False)) + '/od_fse_' + IntToStr(GetProcessID);
  ForceDirectories(Root + '/sub');
  Journal := CreateChangeJournal;
  try
    {$IFDEF DARWIN}
    { Let the directory creation events land before taking the id. }
    Sleep(1500);
    EventID := Journal.CurrentEventID;
    Expect(EventID <> 0, 'FSEvents journal has a position');

    Started := GetTickCount64;
    Collected := Journal.Collect(EventID, Root, 10.0, jmHistory, Changes);
    Elapsed := (GetTickCount64 - Started) / 1000.0;
    Expect(Collected = jrChanges, 'unchanged tree: history replay completes');
    Expect(Elapsed < 1.5, Format('unchanged tree answers fast (%.2fs < 1.5s, timeout 10s)', [Elapsed]));
    if Collected = jrChanges then
    begin
      Expect(Changes.ChangedDirectories.Count + Changes.SubtreesToRescan.Count = 0,
        'unchanged tree reports no changes');
      FreeChanges(Changes);
    end;

    Touch(Root + '/sub/new-file');
    Sleep(1500);
    Collected := Journal.Collect(EventID, Root, 10.0, jmHistory, Changes);
    Expect(Collected = jrChanges, 'changed tree: history replay completes');
    if Collected = jrChanges then
    begin
      Expect(Changes.ChangedDirectories.IndexOf(Root + '/sub') >= 0,
        'new file reports its directory as changed');
      FreeChanges(Changes);
    end;

    { Live window keeps listening for the full window and succeeds. }
    Started := GetTickCount64;
    Collected := Journal.Collect(Journal.CurrentEventID, Root, 1.0, jmLiveWindow, Changes);
    Elapsed := (GetTickCount64 - Started) / 1000.0;
    Expect((Collected = jrChanges) and (Elapsed >= 0.9),
      Format('live window runs its window (%.2fs)', [Elapsed]));
    if Collected = jrChanges then
      FreeChanges(Changes);
    {$ELSE}
    Expect(Journal.CurrentEventID = 0, 'no journal: position is 0');
    Collected := Journal.Collect(0, Root, 1.0, jmHistory, Changes);
    Expect((Collected = jrUnavailable) and (Changes.ChangedDirectories = nil) and
      (Changes.SubtreesToRescan = nil), 'no journal: unavailable, no lists');
    {$ENDIF}
  finally
    Journal.Free;
    DeleteFile(Root + '/sub/new-file');
    RemoveDir(Root + '/sub');
    RemoveDir(Root);
  end;
  if Fail then
    Halt(1);
  WriteLn('test_fsevents: all passed');
end.
