{ ChangeJournal — directories changed since a journal position (portable).

  Port of the contract of OpenDisk FSEventsChangeJournal.swift. The journal
  itself is per OS (PlatformChangeJournal: FSEvents on Darwin, none
  elsewhere); callers get one from JournalFactory and never name the
  platform unit. The unit graph has no cycle:
  ChangeJournal <- PlatformChangeJournal <- JournalFactory. }

unit ChangeJournal;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  { Directories whose direct contents changed, and subtrees to rescan in
    full (the journal could not say what changed below them). }
  TChangeSet = record
    ChangedDirectories: TStringList;
    SubtreesToRescan: TStringList;
  end;

  TJournalMode = (
    { Replay history since the event id and finish when the history is
      done, like FSEventsChangeJournal.swift; running out of time means the
      history is incomplete. }
    jmHistory,
    { CLI watch: collect live events for the whole window; the window
      ending is success. }
    jmLiveWindow
  );

  TJournalResult = (
    { Changes holds the change set; the caller frees both lists. }
    jrChanges,
    { History timed out, events were dropped or too many paths changed:
      the caller must full-scan (ScanEngine.swift falls back to traverse). }
    jrIncomplete,
    { No change journal on this platform: the caller must full-scan. }
    jrUnavailable
  );

  { One Collect at a time per instance; an instance is not shared between
    threads. }
  TChangeJournal = class
  public
    { Opaque position, monotonic for the life of the volume; 0 when the
      journal is unavailable. }
    function CurrentEventID: QWord; virtual; abstract;
    { Blocks for at most TimeoutSec. Changes' lists are allocated, and
      owned by the caller, only when the result is jrChanges; otherwise
      both are nil. }
    function Collect(SinceID: QWord; const Root: string; TimeoutSec: Double;
      Mode: TJournalMode; out Changes: TChangeSet): TJournalResult;
      virtual; abstract;
  end;

{ History replay timeout: half the expected full-scan time, clamped to
  2..30 s (ScanEngine.swift replayTimeBudget). }
function ReplayTimeBudget(ExpectedFullScanSeconds: Double): Double;

implementation

function ReplayTimeBudget(ExpectedFullScanSeconds: Double): Double;
begin
  Result := ExpectedFullScanSeconds * 0.5;
  if Result < 2 then
    Result := 2;
  if Result > 30 then
    Result := 30;
end;

end.
