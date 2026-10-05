{ ProtectedPaths — refuse deleting system / home roots.

  Port of OpenDisk Services/ProtectedPaths.swift. Paths are compared after
  StandardizePath (so /private/var is /var, as NSString.standardizingPath
  does); the home folder comes from the user database. Root tables and
  wording are per-platform data; the rules are shared. }

unit ProtectedPaths;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function ProtectedReason(const Path: string): string;
function IsProtectedPath(const Path: string): Boolean;

implementation

uses
  PlatformFS;

function ParentPath(const Path: string): string;
begin
  Result := ExtractFileDir(Path);
  if Result = '' then
    Result := PathDelim;
end;

function IsAncestorOf(const Ancestor, Path: string): Boolean;
begin
  Result := (Length(Path) > Length(Ancestor) + 1) and
    (Copy(Path, 1, Length(Ancestor) + 1) = Ancestor + PathDelim);
end;

{$IFDEF UNIX}
const
  SystemRoots: array[0..19] of string = (
    '/', '/System', '/Library', '/usr', '/bin', '/sbin', '/private',
    '/etc', '/var', '/tmp', '/cores', '/opt', '/dev', '/Network',
    '/Volumes', '/Applications', '/Users',
    '/System/Volumes', '/System/Applications', '/System/Library'
  );
  {$IFDEF DARWIN}
  OSName = 'macOS ';
  {$ELSE}
  OSName = '';
  {$ENDIF}

function UnixReason(const P: string): string;
var
  R, Home: string;
begin
  Result := '';
  if P = '/' then
    Exit('is the disk root and can''t be deleted');
  for R in SystemRoots do
    if P = R then
      Exit('is a ' + OSName + 'system folder and can''t be deleted');
  Home := UserHomePath;
  if P = Home then
    Exit('is your home folder and can''t be deleted');
  if P = Home + '/Library' then
    Exit('is your Library and can''t be deleted');
  case ParentPath(P) of
    '/Users':
      Exit('is a user account folder and can''t be deleted');
    '/Volumes':
      Exit('is a mounted volume and can''t be deleted');
    '/System/Volumes':
      Exit('is a ' + OSName + 'system volume and can''t be deleted');
  end;
  for R in SystemRoots do
    if IsAncestorOf(P, R) then
      Exit('contains ' + OSName + 'system files and can''t be deleted');
  if IsAncestorOf(P, Home) then
    Exit('contains your home folder and can''t be deleted');
end;
{$ENDIF}
{$IFDEF WINDOWS}
function WindowsReason(const P: string): string;
var
  Upper, Home, Windir, SysDir, Par: string;
begin
  Result := '';
  Upper := UpperCase(P);
  if (Length(Upper) = 2) and (Upper[2] = ':') then
    Exit('is a drive root and can''t be deleted');
  Windir := GetEnvironmentVariable('WINDIR');
  if Windir = '' then
    Windir := 'C:\Windows';
  Windir := StandardizePath(Windir);
  SysDir := Windir + '\System32';
  if (Upper = UpperCase(Windir)) or (Upper = UpperCase(SysDir))
     or (Upper = 'C:\PROGRAM FILES') or (Upper = 'C:\PROGRAM FILES (X86)')
     or (Upper = 'C:\PROGRAMDATA') or (Upper = 'C:\USERS') then
    Exit('is a Windows system folder and can''t be deleted');
  Home := UserHomePath;
  if Upper = UpperCase(Home) then
    Exit('is your home folder and can''t be deleted');
  Par := ParentPath(P);
  if UpperCase(Par) = 'C:\USERS' then
    Exit('is a user account folder and can''t be deleted');
  if (Length(Home) > Length(P)) and
     (UpperCase(Copy(Home, 1, Length(P) + 1)) = UpperCase(P) + '\') then
    Exit('contains your home folder and can''t be deleted');
end;
{$ENDIF}

function ProtectedReason(const Path: string): string;
var
  P: string;
begin
  P := StandardizePath(Path);
  {$IFDEF UNIX}
  Result := UnixReason(P);
  {$ELSE}
  {$IFDEF WINDOWS}
  Result := WindowsReason(P);
  {$ELSE}
  Result := '';
  {$ENDIF}
  {$ENDIF}
end;

function IsProtectedPath(const Path: string): Boolean;
begin
  Result := ProtectedReason(Path) <> '';
end;

end.
