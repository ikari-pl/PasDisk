{ DisplayList — which children a folder view lists.

  DiskAnalyzer.swift folderItems(for:limit:): children largest first (ties
  by name), at most MaxVisibleChildren below the scan root (no limit at
  the root), then only those larger than MinVisibleSize — except while the
  result is partial, when everything is kept. The limit applies before the
  size filter, as in Swift. }

unit DisplayList;

{$mode objfpc}{$H+}

interface

uses
  Classes, FileTree;

const
  MaxVisibleChildren = 100;
  MinVisibleSize = 1024;

type
  TNodeIDArray = array of TNodeID;

function VisibleChildren(Tree: TFileTree; Node: TNodeID; IsScanRoot,
  IsPartial: Boolean): TNodeIDArray;

implementation

function VisibleChildren(Tree: TFileTree; Node: TNodeID; IsScanRoot,
  IsPartial: Boolean): TNodeIDArray;
var
  Sorted: TFPList;
  I, Limit, N: Integer;
  MinSize: Int64;
  Child: TNodeID;
begin
  Result := nil;
  if (Tree = nil) or (Node = NoNode) or not Tree.IsDirectory(Node) then
    Exit;
  if IsPartial then
    MinSize := -1
  else
    MinSize := MinVisibleSize;
  Sorted := TFPList.Create;
  try
    Tree.ChildrenSortedForDisplay(Node, Sorted);
    Limit := Sorted.Count;
    if (not IsScanRoot) and (Limit > MaxVisibleChildren) then
      Limit := MaxVisibleChildren;
    SetLength(Result, Limit);
    N := 0;
    for I := 0 to Limit - 1 do
    begin
      Child := TNodeID(PtrUInt(Sorted[I]));
      if Tree.SizeOf(Child) > MinSize then
      begin
        Result[N] := Child;
        Inc(N);
      end;
    end;
    SetLength(Result, N);
  finally
    Sorted.Free;
  end;
end;

end.
