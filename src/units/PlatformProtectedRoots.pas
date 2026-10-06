{ PlatformProtectedRoots — per-OS protected roots and refusal wording.

  The Darwin policy is the root table of OpenDisk Services/ProtectedPaths.swift.
  Swift has no Linux or Windows build, so those policies are this port's own:
  Linux / other Unix protect the Filesystem Hierarchy Standard roots, and
  Windows derives its system folders from the environment (falling back to
  the default C: layout). The policies are pure string functions over a
  standardized path, so every one is testable on any host; only
  HostProtectionPolicy / HostProtectionEnv look at the running system. }

unit PlatformProtectedRoots;

{$mode objfpc}{$H+}

interface

type
  TProtectionPolicy = (ppDarwin, ppUnixFHS, ppWindows, ppNone);

  { Inputs a policy needs besides the path. Windows fields are full paths
    without a trailing separator; empty ones fall back to the C: layout. }
  TProtectionEnv = record
    Home: string;
    SystemDrive: string;
    WinDir: string;
    ProgramFiles: string;
    ProgramFilesX86: string;
    ProgramData: string;
  end;

{ Why P (already standardized) must not be deleted under Policy; '' when it
  may be. }
function ProtectedReasonFor(const P: string; Policy: TProtectionPolicy;
  const Env: TProtectionEnv): string;

function HostProtectionPolicy: TProtectionPolicy;
function HostProtectionEnv: TProtectionEnv;

{ ProtectedReasonFor with the running system's policy and environment. }
function PlatformProtectedReason(const P: string): string;

implementation

uses
  SysUtils, PlatformFS;

function ParentOf(const P: string; Sep: Char): string;
var
  I: Integer;
begin
  I := Length(P);
  while (I > 0) and (P[I] <> Sep) do
    Dec(I);
  if I <= 1 then
    Result := Sep
  else
    Result := Copy(P, 1, I - 1);
end;

function IsAncestorOf(const Ancestor, Path: string; Sep: Char;
  IgnoreCase: Boolean): Boolean;
var
  Prefix: string;
begin
  Prefix := Ancestor + Sep;
  Result := Length(Path) > Length(Prefix);
  if not Result then
    Exit;
  if IgnoreCase then
    Result := UpperCase(Copy(Path, 1, Length(Prefix))) = UpperCase(Prefix)
  else
    Result := Copy(Path, 1, Length(Prefix)) = Prefix;
end;

const
  { ProtectedPaths.swift system roots. }
  DarwinRoots: array[0..19] of string = (
    '/', '/System', '/Library', '/usr', '/bin', '/sbin', '/private',
    '/etc', '/var', '/tmp', '/cores', '/opt', '/dev', '/Network',
    '/Volumes', '/Applications', '/Users',
    '/System/Volumes', '/System/Applications', '/System/Library'
  );
  { Filesystem Hierarchy Standard top-level directories. }
  FHSRoots: array[0..20] of string = (
    '/', '/bin', '/boot', '/dev', '/etc', '/home', '/lib', '/lib32',
    '/lib64', '/media', '/mnt', '/opt', '/proc', '/root', '/run', '/sbin',
    '/srv', '/sys', '/tmp', '/usr', '/var'
  );

function DarwinReason(const P: string; const Env: TProtectionEnv): string;
const
  OSName = 'macOS ';
var
  R: string;
begin
  Result := '';
  if P = '/' then
    Exit('is the disk root and can''t be deleted');
  for R in DarwinRoots do
    if P = R then
      Exit('is a ' + OSName + 'system folder and can''t be deleted');
  if P = Env.Home then
    Exit('is your home folder and can''t be deleted');
  if P = Env.Home + '/Library' then
    Exit('is your Library and can''t be deleted');
  case ParentOf(P, '/') of
    '/Users':
      Exit('is a user account folder and can''t be deleted');
    '/Volumes':
      Exit('is a mounted volume and can''t be deleted');
    '/System/Volumes':
      Exit('is a ' + OSName + 'system volume and can''t be deleted');
  end;
  for R in DarwinRoots do
    if IsAncestorOf(P, R, '/', False) then
      Exit('contains ' + OSName + 'system files and can''t be deleted');
  if IsAncestorOf(P, Env.Home, '/', False) then
    Exit('contains your home folder and can''t be deleted');
end;

function UnixFHSReason(const P: string; const Env: TProtectionEnv): string;
var
  R: string;
begin
  Result := '';
  if P = '/' then
    Exit('is the disk root and can''t be deleted');
  for R in FHSRoots do
    if P = R then
      Exit('is a system folder and can''t be deleted');
  if P = Env.Home then
    Exit('is your home folder and can''t be deleted');
  case ParentOf(P, '/') of
    '/home':
      Exit('is a user account folder and can''t be deleted');
    '/media', '/mnt':
      Exit('is a mounted volume and can''t be deleted');
  end;
  { udisks mounts removable media at /run/media/<user>/<volume>: the
    volume root is protected like /Volumes/<volume> on macOS, files inside
    it are not, and the folders above it hold every mount. }
  if P = '/run/media' then
    Exit('is a system folder and can''t be deleted');
  if ParentOf(P, '/') = '/run/media' then
    Exit('contains mounted volumes and can''t be deleted');
  if ParentOf(ParentOf(P, '/'), '/') = '/run/media' then
    Exit('is a mounted volume and can''t be deleted');
  if IsAncestorOf(P, Env.Home, '/', False) then
    Exit('contains your home folder and can''t be deleted');
end;

function OrDefault(const Value, Fallback: string): string;
begin
  if Value <> '' then
    Result := ExcludeTrailingBackslash(Value)
  else
    Result := Fallback;
end;

function WindowsReason(const P: string; const Env: TProtectionEnv): string;
var
  Upper, Drive, WinDir, Home, UsersDir: string;
  Roots: array[0..5] of string;
  R: string;
begin
  Result := '';
  Upper := UpperCase(P);
  if (Length(Upper) = 2) and (Upper[2] = ':') then
    Exit('is a drive root and can''t be deleted');
  Drive := OrDefault(Env.SystemDrive, 'C:');
  WinDir := OrDefault(Env.WinDir, Drive + '\Windows');
  Home := Env.Home;
  if Home <> '' then
    UsersDir := ParentOf(Home, '\')
  else
    UsersDir := Drive + '\Users';
  Roots[0] := WinDir;
  Roots[1] := WinDir + '\System32';
  Roots[2] := OrDefault(Env.ProgramFiles, Drive + '\Program Files');
  Roots[3] := OrDefault(Env.ProgramFilesX86, Drive + '\Program Files (x86)');
  Roots[4] := OrDefault(Env.ProgramData, Drive + '\ProgramData');
  Roots[5] := UsersDir;
  for R in Roots do
    if Upper = UpperCase(R) then
      Exit('is a Windows system folder and can''t be deleted');
  if (Home <> '') and (Upper = UpperCase(Home)) then
    Exit('is your home folder and can''t be deleted');
  if UpperCase(ParentOf(P, '\')) = UpperCase(UsersDir) then
    Exit('is a user account folder and can''t be deleted');
  if (Home <> '') and IsAncestorOf(P, Home, '\', True) then
    Exit('contains your home folder and can''t be deleted');
end;

function ProtectedReasonFor(const P: string; Policy: TProtectionPolicy;
  const Env: TProtectionEnv): string;
begin
  case Policy of
    ppDarwin: Result := DarwinReason(P, Env);
    ppUnixFHS: Result := UnixFHSReason(P, Env);
    ppWindows: Result := WindowsReason(P, Env);
  else
    Result := '';
  end;
end;

function HostProtectionPolicy: TProtectionPolicy;
begin
  {$IFDEF DARWIN}
  Result := ppDarwin;
  {$ELSE}
  {$IFDEF UNIX}
  Result := ppUnixFHS;
  {$ELSE}
  {$IFDEF WINDOWS}
  Result := ppWindows;
  {$ELSE}
  Result := ppNone;
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
end;

function HostProtectionEnv: TProtectionEnv;
begin
  Result.Home := UserHomePath;
  Result.SystemDrive := GetEnvironmentVariable('SystemDrive');
  Result.WinDir := GetEnvironmentVariable('WINDIR');
  Result.ProgramFiles := GetEnvironmentVariable('ProgramFiles');
  Result.ProgramFilesX86 := GetEnvironmentVariable('ProgramFiles(x86)');
  Result.ProgramData := GetEnvironmentVariable('ProgramData');
end;

function PlatformProtectedReason(const P: string): string;
begin
  Result := ProtectedReasonFor(P, HostProtectionPolicy, HostProtectionEnv);
end;

end.
