{ PlatformShell — hand a file to the desktop environment. }

unit PlatformShell;

{$mode objfpc}{$H+}

interface

{ Opens Path with its default application (macOS `open`). False when the
  platform has no such hook or the launch failed. }
function OpenDocument(const Path: string): Boolean;

implementation

uses
  SysUtils;

function OpenDocument(const Path: string): Boolean;
begin
  {$IFDEF DARWIN}
  try
    Result := ExecuteProcess('/usr/bin/open', Path) = 0;
  except
    Result := False;
  end;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

end.
