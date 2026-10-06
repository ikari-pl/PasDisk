{ PlatformRemove — permanent removal of a file-system item, without
  following links.

  Same contract as FileManager.removeItem (OpenDisk Collector.deleteAll):
  a symlink (or Windows reparse point) is removed itself, never its
  target; a real directory is removed depth-first. Links found inside a
  directory are unlinked, never descended into.

  Unix: directories are opened with O_NOFOLLOW | O_DIRECTORY relative to
  their parent's descriptor and emptied through that descriptor, so a
  directory swapped for a link while it is being removed is never
  followed. Iterative, with a bounded number of open directories. }

unit PlatformRemove;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ Removes Path. On failure returns False with a short reason in Error;
  items removed before the failure stay removed. }
function RemoveItem(const Path: string; out Error: string): Boolean;

{$IFDEF UNIX}
type
  { Test seam: called with Event 'list' before a directory listing starts
    (a nonzero result is taken as that listing failing with this errno)
    and 'rmdir' just before an emptied subdirectory is removed (the result
    is ignored). RelPath is relative to the removed item. }
  TRemoveTestHook = function(const Event, RelPath: string): Integer;

var
  RemoveTestHook: TRemoveTestHook = nil;
{$ENDIF}

implementation

{$IFDEF UNIX}
uses
  BaseUnix, UnixType;

{ Darwin and Linux values; the FPC 3.2 RTL does not export these. }
const
  {$IF defined(DARWIN)}
  OpenDirectoryFlag = $100000;
  OpenNoFollowFlag = $100;
  OpenCloseOnExecFlag = $1000000;
  RemoveDirFlag = $80;
  CurrentDirFd = -2;
  {$ELSEIF defined(LINUX)}
  OpenCloseOnExecFlag = $80000;
  RemoveDirFlag = $200;
  CurrentDirFd = -100;
    {$IF defined(CPUARM) or defined(CPUAARCH64) or defined(CPUPOWERPC) or defined(CPUPOWERPC64)}
  OpenDirectoryFlag = $4000;
  OpenNoFollowFlag = $8000;
    {$ELSE}
  OpenDirectoryFlag = $10000;
  OpenNoFollowFlag = $20000;
    {$ENDIF}
  {$ELSE}
    {$FATAL PlatformRemove: openat flags unknown for this Unix}
  {$ENDIF}

  {$IF defined(DARWIN) and defined(CPUX86_64)}
  FdOpenDirSym = 'fdopendir$INODE64';
  ReadDirSym = 'readdir$INODE64';
  RewindDirSym = 'rewinddir$INODE64';
  {$ELSEIF defined(LINUX)}
  FdOpenDirSym = 'fdopendir';
  ReadDirSym = 'readdir64';
  RewindDirSym = 'rewinddir';
  {$ELSE}
  FdOpenDirSym = 'fdopendir';
  ReadDirSym = 'readdir';
  RewindDirSym = 'rewinddir';
  {$ENDIF}

  DirEntryUnknown = 0;
  DirEntryDirectory = 4;

  { Directories held open at once. Deeper trees close their shallower
    ancestors and reopen each through '..' (identity-checked) on the way
    back up, so depth is not limited by the open-file limit. }
  MaxOpenLevels = 64;

function c_openat(Fd: cint; Path: PChar; Flags: cint): cint; cdecl;
  external 'c' name 'openat';
function c_unlinkat(Fd: cint; Path: PChar; Flags: cint): cint; cdecl;
  external 'c' name 'unlinkat';
function c_fdopendir(Fd: cint): Pointer; cdecl; external 'c' name FdOpenDirSym;
function c_readdir(Dir: Pointer): PDirent; cdecl; external 'c' name ReadDirSym;
procedure c_rewinddir(Dir: Pointer); cdecl; external 'c' name RewindDirSym;
function c_closedir(Dir: Pointer): cint; cdecl; external 'c' name 'closedir';
{$IFDEF DARWIN}
function c_errno_ptr: pcint; cdecl; external 'c' name '__error';
{$ELSE}
function c_errno_ptr: pcint; cdecl; external 'c' name '__errno_location';
{$ENDIF}

function LibcErrno: cint;
begin
  Result := c_errno_ptr^;
end;

type
  TDirFrame = record
    Fd: cint;          { -1 while closed to save descriptors }
    { libc DIR* over Fd, created when listing starts: fdopendir may read
      ahead, so it must not exist before a pending child removal. }
    Dir: Pointer;
    Dev, Ino: QWord;   { identity, checked when reopened through '..' }
    Name: string;      { entry name in the parent; '' for the top }
    Removed: Boolean;  { something was removed during the current listing }
  end;

{ Opens Name under AtFd as a directory without following a link.
  Returns 0, or the errno (ENOTDIR / ELOOP: not a real directory). }
function OpenDirFrame(AtFd: cint; const Name: string; out F: TDirFrame): cint;
var
  Info: Stat;
begin
  F.Dir := nil;
  F.Name := Name;
  F.Removed := False;
  F.Fd := c_openat(AtFd, PChar(Name), O_RDONLY or O_NONBLOCK or OpenDirectoryFlag or
    OpenNoFollowFlag or OpenCloseOnExecFlag);
  if F.Fd < 0 then
    Exit(LibcErrno);
  if fpFStat(F.Fd, Info) <> 0 then
  begin
    Result := fpgeterrno;
    fpClose(F.Fd);
    F.Fd := -1;
    Exit;
  end;
  F.Dev := QWord(Info.st_dev);
  F.Ino := QWord(Info.st_ino);
  Result := 0;
end;

procedure CloseDirFrame(var F: TDirFrame);
begin
  if F.Dir <> nil then
    c_closedir(F.Dir)
  else if F.Fd >= 0 then
    fpClose(F.Fd);
  F.Dir := nil;
  F.Fd := -1;
end;

{ Next entry of F's listing, or nil with Err = 0 at the end, or nil with
  the errno when the listing cannot start or a read fails. }
function NextEntry(var F: TDirFrame; const RelPath: string; out Err: cint): PDirent;
begin
  Err := 0;
  Result := nil;
  if F.Dir = nil then
  begin
    if Assigned(RemoveTestHook) then
      Err := RemoveTestHook('list', RelPath);
    if Err <> 0 then
      Exit;
    F.Dir := c_fdopendir(F.Fd);
    if F.Dir = nil then
    begin
      Err := LibcErrno;
      Exit;
    end;
  end;
  { readdir signals errors only through errno. }
  c_errno_ptr^ := 0;
  Result := c_readdir(F.Dir);
  if Result = nil then
    Err := LibcErrno;
end;

{ True when Name under AtFd is still the directory Dev/Ino (not a link,
  not a replacement). }
function SameDirectory(AtFd: cint; const Name: string; Dev, Ino: QWord): Boolean;
var
  F: TDirFrame;
begin
  Result := (OpenDirFrame(AtFd, Name, F) = 0) and (F.Dev = Dev) and (F.Ino = Ino);
  CloseDirFrame(F);
end;

function RemoveItem(const Path: string; out Error: string): Boolean;
var
  Info: Stat;
  Stack: array of TDirFrame;
  Depth, Top, I: Integer;
  Err: cint;
  Entry: PDirent;
  Name: string;
  Child: TDirFrame;
  SameDir: Boolean;

  function Where(const Leaf: string): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 1 to Depth - 1 do
      Result := Result + Stack[K].Name + '/';
    Result := Result + Leaf;
    if (Result <> '') and (Result[Length(Result)] = '/') then
      SetLength(Result, Length(Result) - 1);
  end;

  procedure Fail(const At, Reason: string);
  begin
    Result := False;
    if Error = '' then
      if At = '' then
        Error := Reason
      else
        Error := At + ': ' + Reason;
  end;

  procedure CloseAll;
  var
    K: Integer;
  begin
    for K := 0 to Depth - 1 do
      CloseDirFrame(Stack[K]);
    Depth := 0;
  end;

begin
  Error := '';
  Result := True;
  if fpLStat(PChar(Path), Info) <> 0 then
  begin
    Error := 'cannot stat (errno ' + IntToStr(fpgeterrno) + ')';
    Exit(False);
  end;

  if not fpS_ISDIR(Info.st_mode) then
  begin
    { Regular file, symlink (to anything), socket, fifo: unlink the entry. }
    Result := fpUnlink(PChar(Path)) = 0;
    if not Result then
      Error := 'cannot remove (errno ' + IntToStr(fpgeterrno) + ')';
    Exit;
  end;

  SetLength(Stack, 16);
  Err := OpenDirFrame(CurrentDirFd, Path, Stack[0]);
  if (Err = ESysENOTDIR) or (Err = ESysELOOP) then
  begin
    { Replaced by a link or file since the lstat: remove that entry itself. }
    Result := fpUnlink(PChar(Path)) = 0;
    if not Result then
      Error := 'cannot remove (errno ' + IntToStr(fpgeterrno) + ')';
    Exit;
  end;
  if Err <> 0 then
  begin
    Error := 'cannot open directory (errno ' + IntToStr(Err) + ')';
    Exit(False);
  end;
  Depth := 1;
  if (Stack[0].Dev <> QWord(Info.st_dev)) or (Stack[0].Ino <> QWord(Info.st_ino)) then
  begin
    CloseAll;
    Error := 'changed while being removed';
    Exit(False);
  end;

  while Depth > 0 do
  begin
    Top := Depth - 1;
    Entry := NextEntry(Stack[Top], Where(''), Err);
    if (Entry = nil) and (Err <> 0) then
    begin
      { The listing failed: this directory cannot be emptied, so it is
        left in place (with whatever it still holds) and reported. }
      Fail(Where(''), 'cannot list directory (errno ' + IntToStr(Err) + ')');
      CloseDirFrame(Stack[Top]);
      Dec(Depth);
      Continue;
    end;
    if Entry = nil then
    begin
      { Removing entries while listing may make the listing skip some:
        list again until a pass removes nothing. }
      if Stack[Top].Removed and (Stack[Top].Dir <> nil) then
      begin
        Stack[Top].Removed := False;
        c_rewinddir(Stack[Top].Dir);
        Continue;
      end;
      if Top = 0 then
      begin
        CloseAll;
        if Assigned(RemoveTestHook) then
          RemoveTestHook('rmdir', '');
        { Only the directory that was emptied: not one renamed into place. }
        if (fpLStat(PChar(Path), Info) <> 0) or not fpS_ISDIR(Info.st_mode) or
          (QWord(Info.st_dev) <> Stack[0].Dev) or (QWord(Info.st_ino) <> Stack[0].Ino) then
          Fail('', 'changed while being removed')
        else if fpRmdir(PChar(Path)) <> 0 then
          Fail('', 'cannot remove directory (errno ' + IntToStr(fpgeterrno) + ')');
        Break;
      end;
      if Stack[Top - 1].Fd < 0 then
      begin
        { Reopened listings start over, which also picks up anything the
          closed listing would have missed. }
        Err := OpenDirFrame(Stack[Top].Fd, '..', Child);
        if (Err <> 0) or (Child.Dev <> Stack[Top - 1].Dev) or
          (Child.Ino <> Stack[Top - 1].Ino) then
        begin
          CloseDirFrame(Child);
          Fail(Where(''), 'parent changed while being removed');
          CloseAll;
          Exit;
        end;
        Stack[Top - 1].Fd := Child.Fd;
        Stack[Top - 1].Dir := nil;
      end;
      Name := Stack[Top].Name;
      if Assigned(RemoveTestHook) then
        RemoveTestHook('rmdir', Where(''));
      { Remove only the directory that was emptied: if the name now holds
        something else (renamed or replaced meanwhile), leave it. }
      SameDir := SameDirectory(Stack[Top - 1].Fd, Name, Stack[Top].Dev, Stack[Top].Ino);
      CloseDirFrame(Stack[Top]);
      Dec(Depth);
      if not SameDir then
        Fail(Where(Name), 'changed while being removed')
      else if c_unlinkat(Stack[Top - 1].Fd, PChar(Name), RemoveDirFlag) = 0 then
        Stack[Top - 1].Removed := True
      else if LibcErrno <> ESysENOENT then
        Fail(Where(Name), 'cannot remove directory (errno ' + IntToStr(LibcErrno) + ')');
      Continue;
    end;

    Name := StrPas(PChar(@Entry^.d_name[0]));
    if (Name = '.') or (Name = '..') then
      Continue;
    if (Entry^.d_type = DirEntryDirectory) or (Entry^.d_type = DirEntryUnknown) then
    begin
      Err := OpenDirFrame(Stack[Top].Fd, Name, Child);
      if Err = 0 then
      begin
        if Depth = Length(Stack) then
          SetLength(Stack, 2 * Depth);
        Stack[Depth] := Child;
        Inc(Depth);
        I := Depth - 1 - MaxOpenLevels;
        if I >= 0 then
          CloseDirFrame(Stack[I]);
        Continue;
      end;
      { Already gone (a stale listing entry): nothing to remove. }
      if Err = ESysENOENT then
        Continue;
      if (Err <> ESysENOTDIR) and (Err <> ESysELOOP) then
      begin
        Fail(Where(Name), 'cannot open directory (errno ' + IntToStr(Err) + ')');
        Continue;
      end;
      { Not a real directory (a link, or replaced since listed): unlink it. }
    end;
    if c_unlinkat(Stack[Top].Fd, PChar(Name), 0) = 0 then
      Stack[Top].Removed := True
    else if LibcErrno <> ESysENOENT then
      Fail(Where(Name), 'cannot remove (errno ' + IntToStr(LibcErrno) + ')');
  end;
end;
{$ENDIF}

{$IFDEF WINDOWS}
uses
  Windows;

function RemoveItem(const Path: string; out Error: string): Boolean;
var
  WPath: UnicodeString;
  Attr: DWORD;
  Find: TWin32FindDataW;
  H: THandle;
  Name: UnicodeString;
  ChildError: string;
begin
  Error := '';
  WPath := UnicodeString(Path);
  Attr := GetFileAttributesW(PWideChar(WPath));
  if Attr = INVALID_FILE_ATTRIBUTES then
  begin
    Error := 'cannot read attributes (' + IntToStr(GetLastError) + ')';
    Exit(False);
  end;

  if (Attr and FILE_ATTRIBUTE_DIRECTORY) = 0 then
  begin
    Result := DeleteFileW(PWideChar(WPath));
    if not Result then
      Error := 'cannot remove (' + IntToStr(GetLastError) + ')';
    Exit;
  end;

  { Junctions and directory symlinks: remove the link, not the target. }
  if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
  begin
    Result := RemoveDirectoryW(PWideChar(WPath));
    if not Result then
      Error := 'cannot remove link (' + IntToStr(GetLastError) + ')';
    Exit;
  end;

  Result := True;
  H := FindFirstFileW(PWideChar(WPath + '\*'), Find);
  if H <> INVALID_HANDLE_VALUE then
  try
    repeat
      Name := Find.cFileName;
      if (Name = '.') or (Name = '..') then
        Continue;
      if not RemoveItem(UTF8Encode(WPath + '\' + Name), ChildError) then
      begin
        Result := False;
        if Error = '' then
          Error := UTF8Encode(Name) + ': ' + ChildError;
      end;
    until not FindNextFileW(H, Find);
  finally
    Windows.FindClose(H);
  end;

  if not RemoveDirectoryW(PWideChar(WPath)) then
  begin
    if Result then
      Error := 'cannot remove directory (' + IntToStr(GetLastError) + ')';
    Result := False;
  end;
end;
{$ENDIF}

end.
