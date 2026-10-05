{ PlatformRemove — permanent removal of a file-system item, without
  following links.

  Same contract as FileManager.removeItem (OpenDisk Collector.deleteAll):
  a symlink (or Windows reparse point) is removed itself, never its
  target; a real directory is removed depth-first. Links found inside a
  directory are unlinked, never descended into. }

unit PlatformRemove;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ Removes Path. On failure returns False with a short reason in Error;
  items removed before the failure stay removed. }
function RemoveItem(const Path: string; out Error: string): Boolean;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;

function RemoveItem(const Path: string; out Error: string): Boolean;
var
  Info: Stat;
  Dir: PDir;
  Entry: PDirent;
  Name: string;
  ChildError: string;
begin
  Error := '';
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

  Result := True;
  Dir := fpOpenDir(PChar(Path));
  if Dir = nil then
  begin
    Error := 'cannot open directory (errno ' + IntToStr(fpgeterrno) + ')';
    Exit(False);
  end;
  try
    repeat
      Entry := fpReadDir(Dir^);
      if Entry = nil then
        Break;
      Name := StrPas(PChar(@Entry^.d_name[0]));
      if (Name = '.') or (Name = '..') then
        Continue;
      if not RemoveItem(Path + '/' + Name, ChildError) then
      begin
        Result := False;
        if Error = '' then
          Error := Name + ': ' + ChildError;
      end;
    until False;
  finally
    fpCloseDir(Dir^);
  end;

  if fpRmdir(PChar(Path)) <> 0 then
  begin
    if Result then
      Error := 'cannot remove directory (errno ' + IntToStr(fpgeterrno) + ')';
    Result := False;
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
