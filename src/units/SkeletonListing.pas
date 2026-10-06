{ SkeletonListing — a scan root's first level, before the scan has sizes.

  DiskAnalyzer.swift readSkeleton: one non-recursive read of the root;
  folders first by name (case-insensitive) with their size unknown, then
  files by allocated size, largest first. Symbolic links and hidden items
  are left out. Swift hides items with the UF_HIDDEN flag as well; the
  directory reader does not report that flag, so only dot-names are
  hidden here. }

unit SkeletonListing;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSkeletonItem = record
    Name: string;
    Path: string;
    Size: Int64;
    IsDirectory: Boolean;
    { FolderItem.sizeIsKnown: False for folders until the scan sizes them. }
    SizeKnown: Boolean;
  end;
  TSkeletonItems = array of TSkeletonItem;

{ The listing of Path; empty when it cannot be read. }
function ReadSkeleton(const Path: string): TSkeletonItems;

implementation

uses
  DirTypes, PlatformDirReader, PlatformFS;

type
  TItemOrder = function(const A, B: TSkeletonItem): Integer;

function ByName(const A, B: TSkeletonItem): Integer;
begin
  Result := AnsiCompareText(A.Name, B.Name);
end;

function BySizeDescending(const A, B: TSkeletonItem): Integer;
begin
  if A.Size > B.Size then
    Result := -1
  else if A.Size < B.Size then
    Result := 1
  else
    Result := AnsiCompareText(A.Name, B.Name);
end;

procedure SortItems(var Items: TSkeletonItems; Lo, Hi: Integer; Order: TItemOrder);
var
  I, J: Integer;
  Pivot, Swap: TSkeletonItem;
begin
  while Lo < Hi do
  begin
    I := Lo;
    J := Hi;
    Pivot := Items[(Lo + Hi) div 2];
    repeat
      while Order(Items[I], Pivot) < 0 do
        Inc(I);
      while Order(Items[J], Pivot) > 0 do
        Dec(J);
      if I <= J then
      begin
        Swap := Items[I];
        Items[I] := Items[J];
        Items[J] := Swap;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    { Recurse into the smaller half, loop on the larger. }
    if J - Lo < Hi - I then
    begin
      SortItems(Items, Lo, J, Order);
      Lo := I;
    end
    else
    begin
      SortItems(Items, I, Hi, Order);
      Hi := J;
    end;
  end;
end;

function ChildPath(const Parent, Name: string): string;
begin
  { String.directoryPrefix: '/' stays '/', others gain a separator. }
  Result := IncludeTrailingPathDelimiter(Parent) + Name;
end;

function Hidden(const Name: string): Boolean;
begin
  Result := (Name = '') or (Name[1] = '.');
end;

function ReadSkeleton(const Path: string): TSkeletonItems;
var
  Read: TDirectoryReadResult;
  AnyDevice: TDeviceSet;
  Folders, Files: TSkeletonItems;
  NF, NFiles, I: Integer;

  procedure AddFolder(const Name: string);
  begin
    if Hidden(Name) then
      Exit;
    Folders[NF].Name := Name;
    Folders[NF].Path := ChildPath(Path, Name);
    Folders[NF].Size := 0;
    Folders[NF].IsDirectory := True;
    Folders[NF].SizeKnown := False;
    Inc(NF);
  end;

begin
  Result := nil;
  AnyDevice := nil;
  Read := ReadDirectory(Path, AnyDevice);
  if Read.Kind <> drkContents then
    Exit;
  SetLength(Folders, Length(Read.Contents.SubdirectoryNames) +
    Length(Read.Contents.MountPointNames));
  NF := 0;
  for I := 0 to High(Read.Contents.SubdirectoryNames) do
    AddFolder(Read.Contents.SubdirectoryNames[I]);
  { Mount points list as folders, as contentsOfDirectory reports them. }
  for I := 0 to High(Read.Contents.MountPointNames) do
    AddFolder(Read.Contents.MountPointNames[I]);
  SetLength(Folders, NF);

  SetLength(Files, Length(Read.Contents.Files));
  NFiles := 0;
  for I := 0 to High(Read.Contents.Files) do
    with Read.Contents.Files[I] do
    begin
      { The reader reports a symbolic link as a file; Swift skips links. }
      if Hidden(Name) or IsSymLink(ChildPath(Path, Name)) then
        Continue;
      Files[NFiles].Name := Name;
      Files[NFiles].Path := ChildPath(Path, Name);
      Files[NFiles].Size := Size;
      Files[NFiles].IsDirectory := False;
      Files[NFiles].SizeKnown := True;
      Inc(NFiles);
    end;
  SetLength(Files, NFiles);

  SortItems(Folders, 0, High(Folders), @ByName);
  SortItems(Files, 0, High(Files), @BySizeDescending);
  SetLength(Result, NF + NFiles);
  for I := 0 to NF - 1 do
    Result[I] := Folders[I];
  for I := 0 to NFiles - 1 do
    Result[NF + I] := Files[I];
end;

end.
