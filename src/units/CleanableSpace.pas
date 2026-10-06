{ CleanableSpace — the synthetic "Purgeable Space" folder.

  Port of DiskAnalyzer.swift cleanableCacheEntries / display(node:) /
  displayCleanableSpace (Models/HiddenSpace.swift): catalogued cache
  folders that exist as directories in the scanned tree with a size above
  zero. At the scan root they are summarised as one row named
  HiddenSpaceFolderName (path HiddenSpaceSentinelPath, never a real path);
  opening it lists the entries largest first, ties by name. }

unit CleanableSpace;

{$mode objfpc}{$H+}

interface

uses
  FileTree, PlatformCacheCatalog;

const
  HiddenSpaceFolderName = 'Purgeable Space';
  HiddenSpaceSentinelPath = '::' + HiddenSpaceFolderName;

type
  TCleanableEntry = record
    Name: string;
    Path: string;
    Size: Int64;
  end;
  TCleanableEntries = array of TCleanableEntry;

{ Catalogue order, as Swift's compactMap keeps it. }
function CleanableCacheEntries(Tree: TFileTree; const RootPath: string;
  const Locations: TCacheLocations): TCleanableEntries;

{ The same, for the platform catalogue. }
function CleanableCacheEntriesOf(Tree: TFileTree; const RootPath: string): TCleanableEntries;

{ Sum of the entries' sizes (the summary row's size). }
function CleanableTotal(const Entries: TCleanableEntries): Int64;

{ Entries largest first, ties by name (displayCleanableSpace). }
function SortedForDisplay(const Entries: TCleanableEntries): TCleanableEntries;

implementation

uses
  SysUtils;

function CleanableCacheEntries(Tree: TFileTree; const RootPath: string;
  const Locations: TCacheLocations): TCleanableEntries;
var
  I, N: Integer;
  Node: TNodeID;
  Size: Int64;
begin
  Result := nil;
  N := 0;
  if Tree = nil then
    Exit;
  for I := 0 to High(Locations) do
  begin
    Node := Tree.NodeIDForPath(Locations[I].Path, RootPath);
    if (Node = NoNode) or not Tree.IsDirectory(Node) then
      Continue;
    Size := Tree.SizeOf(Node);
    if Size <= 0 then
      Continue;
    SetLength(Result, N + 1);
    Result[N].Name := Locations[I].Name;
    Result[N].Path := Locations[I].Path;
    Result[N].Size := Size;
    Inc(N);
  end;
end;

function CleanableCacheEntriesOf(Tree: TFileTree; const RootPath: string): TCleanableEntries;
begin
  Result := CleanableCacheEntries(Tree, RootPath, CleanableCacheLocations);
end;

function CleanableTotal(const Entries: TCleanableEntries): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Entries) do
    Inc(Result, Entries[I].Size);
end;

function SortedForDisplay(const Entries: TCleanableEntries): TCleanableEntries;
var
  I, J: Integer;
  X: TCleanableEntry;

  function Before(const A, B: TCleanableEntry): Boolean;
  begin
    if A.Size <> B.Size then
      Result := A.Size > B.Size
    else
      Result := CompareStr(A.Name, B.Name) < 0;
  end;

begin
  Result := Copy(Entries);
  for I := 1 to High(Result) do
  begin
    X := Result[I];
    J := I - 1;
    while (J >= 0) and Before(X, Result[J]) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := X;
  end;
end;

end.
