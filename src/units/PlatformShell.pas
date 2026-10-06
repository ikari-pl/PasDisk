{ PlatformShell — hand a file to the desktop environment. }

unit PlatformShell;

{$mode objfpc}{$H+}

interface

{ Opens Path with its default application (macOS `open`). False when the
  platform has no such hook or the launch failed. }
function OpenDocument(const Path: string): Boolean;

{ Opens a URL (e.g. x-apple.systempreferences:) with its handler. }
function OpenURL(const URL: string): Boolean;

{ Shows Path selected in the file manager (Finder: activateFileViewerSelecting). }
function RevealInFileManager(const Path: string): Boolean;

{ Starts a new instance of this application (the .app bundle when running
  from one, else the executable). The caller then quits. }
function LaunchNewInstance: Boolean;

implementation

uses
  SysUtils;

{$IFDEF DARWIN}
{ Arguments as an array: a single command line would be split on spaces. }
function RunOpen(const Args: array of string): Boolean;
begin
  try
    Result := ExecuteProcess('/usr/bin/open', Args) = 0;
  except
    Result := False;
  end;
end;
{$ENDIF}

function OpenDocument(const Path: string): Boolean;
begin
  {$IFDEF DARWIN}
  Result := RunOpen([Path]);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function OpenURL(const URL: string): Boolean;
begin
  {$IFDEF DARWIN}
  Result := RunOpen([URL]);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function RevealInFileManager(const Path: string): Boolean;
begin
  {$IFDEF DARWIN}
  Result := RunOpen(['-R', Path]);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function LaunchNewInstance: Boolean;
{$IFDEF DARWIN}
var
  Exe: string;
  P: Integer;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  Exe := ParamStr(0);
  P := Pos('.app/Contents/MacOS/', Exe);
  if P > 0 then
    { FullDiskAccess.relaunch: createsNewApplicationInstance. }
    Result := RunOpen(['-n', Copy(Exe, 1, P + 3)])
  else
    Result := RunOpen(['-n', '-a', Exe]);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

end.
