{ ProtectedPaths parity with OpenDisk Services/ProtectedPaths.swift. }

program test_protectedpaths;

{$mode objfpc}{$H+}

uses
  SysUtils, ProtectedPaths, PlatformFS, PlatformProtectedRoots;

var
  Fail: Boolean;
  Home, Tmp: string;

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

procedure ExpectReason(const Path, Fragment: string);
var
  R: string;
begin
  R := ProtectedReason(Path);
  Expect(Pos(Fragment, R) > 0, Format('%s -> "%s" (want "%s")', [Path, R, Fragment]));
end;

procedure ExpectFree(const Path: string);
var
  R: string;
begin
  R := ProtectedReason(Path);
  Expect(R = '', Format('%s is deletable (got "%s")', [Path, R]));
end;

procedure ExpectPolicy(Policy: TProtectionPolicy; const Env: TProtectionEnv;
  const Path, Fragment: string);
var
  R: string;
begin
  R := ProtectedReasonFor(Path, Policy, Env);
  if Fragment = '' then
    Expect(R = '', Format('[%d] %s is deletable (got "%s")', [Ord(Policy), Path, R]))
  else
    Expect(Pos(Fragment, R) > 0,
      Format('[%d] %s -> "%s" (want "%s")', [Ord(Policy), Path, R, Fragment]));
end;

procedure TestPolicies;
var
  Env: TProtectionEnv;
begin
  { Linux / other Unix: FHS roots, no macOS wording or macOS table. }
  Env := Default(TProtectionEnv);
  Env.Home := '/home/alice';
  ExpectPolicy(ppUnixFHS, Env, '/', 'is the disk root');
  ExpectPolicy(ppUnixFHS, Env, '/usr', 'is a system folder');
  ExpectPolicy(ppUnixFHS, Env, '/var', 'is a system folder');
  ExpectPolicy(ppUnixFHS, Env, '/home', 'is a system folder');
  ExpectPolicy(ppUnixFHS, Env, '/home/alice', 'is your home folder');
  ExpectPolicy(ppUnixFHS, Env, '/home/bob', 'is a user account folder');
  ExpectPolicy(ppUnixFHS, Env, '/media/usb', 'is a mounted volume');
  ExpectPolicy(ppUnixFHS, Env, '/mnt/data', 'is a mounted volume');
  ExpectPolicy(ppUnixFHS, Env, '/run/media/alice/USB', 'is a mounted volume');
  ExpectPolicy(ppUnixFHS, Env, '/run/media', 'is a system folder');
  ExpectPolicy(ppUnixFHS, Env, '/run/media/alice', 'contains mounted volumes');
  ExpectPolicy(ppUnixFHS, Env, '/run/media/alice/USB/photo.jpg', '');
  ExpectPolicy(ppUnixFHS, Env, '/run/mediafoo/alice/USB', '');
  ExpectPolicy(ppUnixFHS, Env, '/media/usb/photo.jpg', '');
  ExpectPolicy(ppUnixFHS, Env, '/home/alice/Documents/x.txt', '');
  ExpectPolicy(ppUnixFHS, Env, '/System', '');
  ExpectPolicy(ppUnixFHS, Env, '/Users/alice', '');
  ExpectPolicy(ppUnixFHS, Env, '/usr/share/doc/x', '');
  Expect(Pos('macOS', ProtectedReasonFor('/usr', ppUnixFHS, Env)) = 0,
    'Linux wording does not mention macOS');

  { Windows: roots derived from the environment. }
  Env := Default(TProtectionEnv);
  Env.Home := 'D:\Profiles\alice';
  Env.SystemDrive := 'D:';
  Env.WinDir := 'D:\WINNT';
  Env.ProgramFiles := 'D:\Apps';
  Env.ProgramData := 'D:\Data\';
  ExpectPolicy(ppWindows, Env, 'D:', 'is a drive root');
  ExpectPolicy(ppWindows, Env, 'D:\WINNT', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'd:\winnt\system32', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'D:\Apps', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'D:\Data', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'D:\Program Files (x86)', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'D:\Profiles', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'D:\Profiles\alice', 'is your home folder');
  ExpectPolicy(ppWindows, Env, 'D:\Profiles\bob', 'is a user account folder');
  ExpectPolicy(ppWindows, Env, 'D:\Profiles\alice\Music\a.mp3', '');
  ExpectPolicy(ppWindows, Env, 'C:\Program Files', '');

  { Windows defaults: an empty environment means the C: layout. }
  Env := Default(TProtectionEnv);
  ExpectPolicy(ppWindows, Env, 'C:\Windows', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'C:\Program Files', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'C:\Users', 'is a Windows system folder');
  ExpectPolicy(ppWindows, Env, 'C:\Users\someone', 'is a user account folder');

  { Darwin through the pure entry point. }
  Env := Default(TProtectionEnv);
  Env.Home := '/Users/alice';
  ExpectPolicy(ppDarwin, Env, '/Users/alice/Library', 'is your Library');
  ExpectPolicy(ppDarwin, Env, '/Users/bob', 'is a user account folder');
  ExpectPolicy(ppDarwin, Env, '/System/Volumes/Data', 'is a macOS system volume');
  ExpectPolicy(ppNone, Env, '/', '');
end;

begin
  Fail := False;
  {$IFDEF DARWIN}
  TestPolicies;
  ExpectReason('/', 'is the disk root');
  ExpectReason('/System/Volumes', 'is a macOS system folder');
  ExpectReason('/System/Applications', 'is a macOS system folder');
  ExpectReason('/System/Library', 'is a macOS system folder');
  ExpectReason('/usr/', 'is a macOS system folder');
  ExpectReason('/System/Volumes/Data', 'is a macOS system volume');
  ExpectReason('/private/var', 'is a macOS system folder');
  ExpectReason('/private/etc', 'is a macOS system folder');
  ExpectReason('/Volumes/SomeDisk', 'is a mounted volume');
  ExpectReason('/Users/someone-else', 'is a user account folder');
  ExpectReason('/usr/../System', 'is a macOS system folder');

  Home := UserHomePath;
  ExpectReason(Home, 'is your home folder');
  ExpectReason(Home + '/Library', 'is your Library');
  ExpectReason(ExtractFileDir(Home), 'is a macOS system folder');

  ExpectFree(Home + '/Documents/some-file.txt');
  ExpectFree('/System/Library/Caches/x');
  Tmp := StandardizePath(GetTempDir(False)) + '/od_protect_probe';
  ExpectFree(Tmp);
  {$ELSE}
  WriteLn('test_protectedpaths: Darwin table only; skipped');
  {$ENDIF}
  if Fail then
    Halt(1);
  WriteLn('test_protectedpaths: all passed');
end.
