{ PlatformRemove tests (Unix): depth beyond the open-file limit, wide
  directories, links never followed, partial failure reporting. }

program test_remove;

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, PlatformRemove;

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

procedure Touch(const Path: string);
var
  F: THandle;
begin
  F := FileCreate(Path);
  if F <> THandle(-1) then
    FileClose(F);
end;

function Exists(const Path: string): Boolean;
var
  Info: Stat;
begin
  Result := fpLStat(PChar(Path), Info) = 0;
end;

procedure LimitOpenFiles(Count: Integer);
var
  Limit: TRLimit;
begin
  if fpGetRLimit(RLIMIT_NOFILE, @Limit) = 0 then
  begin
    Limit.rlim_cur := Count;
    fpSetRLimit(RLIMIT_NOFILE, @Limit);
  end;
end;

procedure TestDeepChain;
const
  Levels = 400;
var
  Root, P, Err: string;
  I: Integer;
  Ok: Boolean;
begin
  Root := Base + '/deep';
  CreateDir(Root);
  P := Root;
  for I := 1 to Levels do
  begin
    P := P + '/d';
    if not CreateDir(P) then
    begin
      WriteLn('  mkdir failed at level ', I, ' (', Length(P), ' bytes, errno ', fpgeterrno, ')');
      Break;
    end;
    if I mod 50 = 0 then
      Touch(P + '/f');
  end;
  Touch(P + '/bottom');
  Expect(Exists(P + '/bottom'), Format('built a %d-level chain', [Levels]));
  Ok := RemoveItem(Root, Err);
  Expect(Ok, 'deep chain removed: ' + Err);
  Expect(not Exists(Root), 'nothing of the chain is left');
end;

procedure TestWide;
var
  Root, Sub, Err: string;
  I, J: Integer;
  Ok: Boolean;
begin
  Root := Base + '/wide';
  CreateDir(Root);
  for I := 1 to 3000 do
    Touch(Format('%s/file-%d', [Root, I]));
  for I := 1 to 40 do
  begin
    Sub := Format('%s/sub-%d', [Root, I]);
    CreateDir(Sub);
    for J := 1 to 25 do
      Touch(Format('%s/f-%d', [Sub, J]));
  end;
  Ok := RemoveItem(Root, Err);
  Expect(Ok, 'wide tree removed: ' + Err);
  Expect(not Exists(Root), 'every entry of the wide tree is gone');
end;

procedure TestLinksNotFollowed;
var
  Root, Target, P, Err: string;
  I: Integer;
  Ok: Boolean;
begin
  Root := Base + '/links';
  Target := Base + '/target';
  CreateDir(Root);
  CreateDir(Target);
  Touch(Target + '/keep');
  { A link at a depth where shallower directories have been closed. }
  P := Root;
  for I := 1 to 80 do
  begin
    P := P + '/d';
    CreateDir(P);
  end;
  fpSymlink(PChar(Target), PChar(P + '/link'));
  fpSymlink(PChar(Target), PChar(Root + '/top-link'));
  Ok := RemoveItem(Root, Err);
  Expect(Ok, 'tree with links removed: ' + Err);
  Expect(Exists(Target + '/keep'), 'link targets are untouched');

  fpSymlink(PChar(Target), PChar(Base + '/link-item'));
  Ok := RemoveItem(Base + '/link-item', Err);
  Expect(Ok, 'a link to a directory is removable');
  Expect(not Exists(Base + '/link-item') and Exists(Target + '/keep'),
    'the link itself is removed, not its target');
end;

procedure TestPartialFailure;
var
  Root, Err: string;
  Ok: Boolean;
begin
  Root := Base + '/partial';
  CreateDir(Root);
  CreateDir(Root + '/locked');
  Touch(Root + '/locked/inner');
  Touch(Root + '/free');
  fpChmod(PChar(Root + '/locked'), &555);
  Ok := RemoveItem(Root, Err);
  Expect(not Ok, 'a locked entry makes removal fail');
  Expect(Pos('locked/inner: cannot remove', Err) = 1, 'error names the entry: ' + Err);
  Expect(not Exists(Root + '/free'), 'removable siblings are removed');
  Expect(Exists(Root + '/locked/inner'), 'the locked entry stays');
  fpChmod(PChar(Root + '/locked'), &755);
  Ok := RemoveItem(Root, Err);
  Expect(Ok, 'removable once unlocked: ' + Err);
end;

var
  HookBase: string;
  HookCalls: Integer;

{ Replaces <HookBase>/a with a new empty directory just before it is
  removed: the stranger must survive. }
function SwapChildHook(const Event, RelPath: string): Integer;
begin
  Result := 0;
  if (Event = 'rmdir') and (RelPath = 'a') then
  begin
    Inc(HookCalls);
    fpRename(PChar(HookBase + '/a'), PChar(HookBase + '-moved-a'));
    CreateDir(HookBase + '/a');
    Touch(HookBase + '/a/stranger');
    fpRename(PChar(HookBase + '/a/stranger'), PChar(HookBase + '/a/.s'));
    DeleteFile(HookBase + '/a/.s');
  end;
end;

{ Replaces the top directory itself just before its final rmdir. }
function SwapTopHook(const Event, RelPath: string): Integer;
begin
  Result := 0;
  if (Event = 'rmdir') and (RelPath = '') then
  begin
    Inc(HookCalls);
    fpRename(PChar(HookBase), PChar(HookBase + '-moved-top'));
    CreateDir(HookBase);
  end;
end;

{ Listing of <base>/b fails with EACCES. }
function ListFailsHook(const Event, RelPath: string): Integer;
begin
  Result := 0;
  if (Event = 'list') and (RelPath = 'b') then
  begin
    Inc(HookCalls);
    Result := ESysEACCES;
  end;
end;

procedure TestRaces;
var
  Err: string;
  Ok: Boolean;
begin
  HookBase := Base + '/race-child';
  ForceDirectories(HookBase + '/a/deeper');
  Touch(HookBase + '/a/deeper/f');
  HookCalls := 0;
  RemoveTestHook := @SwapChildHook;
  Ok := RemoveItem(HookBase, Err);
  RemoveTestHook := nil;
  Expect(HookCalls = 1, 'child swap hook ran');
  Expect(not Ok, 'a child replaced before its removal fails the removal');
  Expect(Err = 'a: changed while being removed', 'error names the child: ' + Err);
  Expect(DirectoryExists(HookBase + '/a'), 'the replacement directory is not removed');
  Expect(DirectoryExists(HookBase + '-moved-a') and not FileExists(HookBase + '-moved-a/deeper/f'),
    'the original was emptied where it was');
  RemoveItem(HookBase, Err);
  RemoveItem(HookBase + '-moved-a', Err);

  HookBase := Base + '/race-top';
  ForceDirectories(HookBase + '/x');
  HookCalls := 0;
  RemoveTestHook := @SwapTopHook;
  Ok := RemoveItem(HookBase, Err);
  RemoveTestHook := nil;
  Expect((HookCalls = 1) and not Ok and (Err = 'changed while being removed'),
    'a top directory replaced before its rmdir fails: ' + Err);
  Expect(DirectoryExists(HookBase), 'the replacement top directory is not removed');
  RemoveItem(HookBase, Err);
  RemoveItem(HookBase + '-moved-top', Err);
end;

procedure TestListingFailure;
var
  Root, Err: string;
  Ok: Boolean;
begin
  Root := Base + '/list-fail';
  ForceDirectories(Root + '/b');
  Touch(Root + '/b/kept');
  Touch(Root + '/gone');
  HookBase := Root;
  HookCalls := 0;
  RemoveTestHook := @ListFailsHook;
  Ok := RemoveItem(Root, Err);
  RemoveTestHook := nil;
  Expect(HookCalls >= 1, 'listing failure hook ran');
  Expect(not Ok, 'a failed listing fails the removal');
  Expect(Err = 'b: cannot list directory (errno ' + IntToStr(ESysEACCES) + ')',
    'the listing error is reported, not taken as an empty directory: ' + Err);
  Expect(FileExists(Root + '/b/kept'), 'the unlisted directory keeps its contents');
  Expect(not FileExists(Root + '/gone'), 'siblings are still removed');
  Ok := RemoveItem(Root, Err);
  Expect(Ok, 'removable without the injected failure: ' + Err);
end;

begin
  Failures := 0;
  Base := GetTempDir(False) + 'opendisk-test-remove-' + IntToStr(fpGetPid);
  CreateDir(Base);
  { Far fewer descriptors than the deep chain has levels. }
  LimitOpenFiles(96);
  TestDeepChain;
  TestWide;
  TestLinksNotFollowed;
  TestPartialFailure;
  TestRaces;
  TestListingFailure;
  RemoveItem(Base, Base);
  if Failures > 0 then
  begin
    WriteLn('test_remove: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_remove: all passed');
end.
