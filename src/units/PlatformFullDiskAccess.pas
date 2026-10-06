{ PlatformFullDiskAccess — whether macOS lets this app read protected
  folders, and the way to grant it.

  Port of Services/FullDiskAccess.swift: a fixed set of TCC-protected
  locations is probed; access counts as granted when at least one exists
  and every existing one can be listed or opened. Elsewhere there is no
  such permission and access is always granted. }

unit PlatformFullDiskAccess;

{$mode objfpc}{$H+}

interface

function FullDiskAccessGranted: Boolean;

{ System Settings > Privacy & Security > Full Disk Access. }
procedure OpenFullDiskAccessSettings;

implementation

uses
  SysUtils, PlatformShell
  {$IFDEF DARWIN}, BaseUnix{$ENDIF};

{$IFDEF DARWIN}
function CanList(const Path: string): Boolean;
var
  Dir: PDir;
begin
  Dir := fpOpenDir(PChar(Path));
  Result := Dir <> nil;
  if Result then
    fpCloseDir(Dir^);
end;

function CanOpen(const Path: string): Boolean;
var
  Fd: cint;
begin
  Fd := fpOpen(PChar(Path), O_RDONLY);
  Result := Fd >= 0;
  if Result then
    fpClose(Fd);
end;

function Exists(const Path: string): Boolean;
var
  Info: Stat;
begin
  { FileManager.fileExists follows links. }
  Result := fpStat(PChar(Path), Info) = 0;
end;

function FullDiskAccessGranted: Boolean;
const
  Directories: array[0..3] of string = (
    '/Library/Containers/com.apple.stocks',
    '/Library/Safari',
    '/Library/Mail',
    '/Library/Messages');
  Files: array[0..0] of string = (
    '/Library/Preferences/com.apple.TimeMachine.plist');
var
  Home, Path: string;
  Probed, Readable, I: Integer;
begin
  Home := GetEnvironmentVariable('HOME');
  Probed := 0;
  Readable := 0;
  for I := 0 to High(Directories) do
  begin
    Path := Home + Directories[I];
    if not Exists(Path) then
      Continue;
    Inc(Probed);
    if CanList(Path) then
      Inc(Readable);
  end;
  for I := 0 to High(Files) do
  begin
    if not Exists(Files[I]) then
      Continue;
    Inc(Probed);
    if CanOpen(Files[I]) then
      Inc(Readable);
  end;
  Result := (Probed > 0) and (Readable = Probed);
end;

procedure OpenFullDiskAccessSettings;
begin
  OpenURL('x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles');
end;
{$ELSE}
function FullDiskAccessGranted: Boolean;
begin
  Result := True;
end;

procedure OpenFullDiskAccessSettings;
begin
end;
{$ENDIF}

end.
