{ ProtectedPaths parity with OpenDisk Services/ProtectedPaths.swift. }

program test_protectedpaths;

{$mode objfpc}{$H+}

uses
  SysUtils, ProtectedPaths, PlatformFS;

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

begin
  Fail := False;
  {$IFDEF DARWIN}
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
