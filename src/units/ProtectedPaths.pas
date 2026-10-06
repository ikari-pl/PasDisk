{ ProtectedPaths — refuse deleting system / home roots.

  Port of OpenDisk Services/ProtectedPaths.swift. Paths are compared after
  StandardizePath (so /private/var is /var, as NSString.standardizingPath
  does); the home folder comes from the user database. Root tables and
  wording live in PlatformProtectedRoots. }

unit ProtectedPaths;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function ProtectedReason(const Path: string): string;
function IsProtectedPath(const Path: string): Boolean;

implementation

uses
  PlatformFS, PlatformProtectedRoots;

function ProtectedReason(const Path: string): string;
begin
  Result := PlatformProtectedReason(StandardizePath(Path));
end;

function IsProtectedPath(const Path: string): Boolean;
begin
  Result := ProtectedReason(Path) <> '';
end;

end.
