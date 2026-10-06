{ JournalFactory — the change journal for this platform.

  The only unit that knows both the portable ChangeJournal contract and
  PlatformChangeJournal, so neither of those has to reference the other's
  implementation. }

unit JournalFactory;

{$mode objfpc}{$H+}

interface

uses
  ChangeJournal;

{ The journal for this platform; the caller frees it. }
function CreateChangeJournal: TChangeJournal;

implementation

uses
  PlatformChangeJournal;

function CreateChangeJournal: TChangeJournal;
begin
  Result := PlatformCreateChangeJournal;
end;

end.
