{ ChartItem — hierarchical ring-chart model built from a FileTree. }

unit ChartItem;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileTree;

type
  TChartKind = (ckFile, ckDirectory, ckSynthetic);

  { One flat child of a synthetic chart root. }
  TChartLeaf = record
    Name: string;
    Path: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;
  TChartLeaves = array of TChartLeaf;

  TChartItem = class
  private
    FName: string;
    FPath: string;
    FSize: Int64;
    FDepth: Integer;
    FRelStart: Double;
    FRelSize: Double;
    FFractionOfRoot: Double;
    FKind: TChartKind;
    FHasHiddenChildren: Boolean;
    FChildren: TFPList;
  public
    constructor Create;
    destructor Destroy; override;
    class function Build(Tree: TFileTree; Node: TNodeID;
      const AName, APath: string): TChartItem;
    { DiskAnalyzer.swift cleanableChartRoot: a synthetic root of the leaves'
      total with one ring of childless leaves in the given order; nil when
      the total is not positive. }
    class function BuildSynthetic(const AName, APath: string;
      const Leaves: TChartLeaves): TChartItem;
    property Name: string read FName;
    property Path: string read FPath;
    property Size: Int64 read FSize;
    property Depth: Integer read FDepth;
    property RelStart: Double read FRelStart;
    property RelSize: Double read FRelSize;
    property FractionOfRoot: Double read FFractionOfRoot;
    property Kind: TChartKind read FKind;
    property HasHiddenChildren: Boolean read FHasHiddenChildren;
    property Children: TFPList read FChildren;
  end;

const
  ChartMaxDepth = 5;
  ChartMinVisibleFraction = 0.0015;

implementation

constructor TChartItem.Create;
begin
  inherited Create;
  FChildren := TFPList.Create;
end;

destructor TChartItem.Destroy;
var
  I: Integer;
begin
  for I := 0 to FChildren.Count - 1 do
    TChartItem(FChildren[I]).Free;
  FChildren.Free;
  inherited Destroy;
end;

function DirectoryPrefix(const Path: string): string;
begin
  if (Path <> '') and (Path[Length(Path)] = DirectorySeparator) then
    Result := Path
  else if Path = DirectorySeparator then
    Result := Path
  else
    Result := Path + DirectorySeparator;
end;

class function TChartItem.BuildSynthetic(const AName, APath: string;
  const Leaves: TChartLeaves): TChartItem;
var
  Total: Int64;
  I: Integer;
  Cursor, Share: Double;
  Child: TChartItem;
begin
  Total := 0;
  for I := 0 to High(Leaves) do
    Inc(Total, Leaves[I].Size);
  if Total <= 0 then
    Exit(nil);
  Result := TChartItem.Create;
  Result.FName := AName;
  Result.FPath := APath;
  Result.FSize := Total;
  Result.FDepth := 0;
  Result.FRelStart := 0;
  Result.FRelSize := 100;
  Result.FFractionOfRoot := 1;
  Result.FKind := ckSynthetic;
  Cursor := 0;
  for I := 0 to High(Leaves) do
  begin
    Share := Leaves[I].Size / Total * 100;
    Child := TChartItem.Create;
    Child.FName := Leaves[I].Name;
    Child.FPath := Leaves[I].Path;
    Child.FSize := Leaves[I].Size;
    Child.FDepth := 1;
    Child.FRelStart := Cursor;
    Child.FRelSize := Share;
    Child.FFractionOfRoot := Share / 100;
    if Leaves[I].IsDirectory then
      Child.FKind := ckDirectory
    else
      Child.FKind := ckFile;
    Result.FChildren.Add(Child);
    Cursor := Cursor + Share;
  end;
end;

class function TChartItem.Build(Tree: TFileTree; Node: TNodeID;
  const AName, APath: string): TChartItem;

  function BuildItem(ANode: TNodeID; const Name, Path: string;
    Depth: Integer; RelStart, RelSize, Fraction: Double): TChartItem;
  var
    Sorted: TFPList;
    ChildID: TNodeID;
    I: Integer;
    ParentSize: Int64;
    ChildSize: Int64;
    Share, ChildFraction: Double;
    Cursor: Double;
    ChildName: string;
    IsDir, HasKids: Boolean;
  begin
    Result := TChartItem.Create;
    Result.FName := Name;
    Result.FPath := Path;
    Result.FSize := Tree.SizeOf(ANode);
    Result.FDepth := Depth;
    Result.FRelStart := RelStart;
    Result.FRelSize := RelSize;
    Result.FFractionOfRoot := Fraction;
    IsDir := Tree.IsDirectory(ANode);
    if IsDir then
      Result.FKind := ckDirectory
    else
      Result.FKind := ckFile;
    HasKids := IsDir and (Tree.ChildCount(ANode) > 0);
    Result.FHasHiddenChildren := HasKids and (Depth >= ChartMaxDepth);

    if HasKids and (Depth < ChartMaxDepth) then
    begin
      ParentSize := Result.FSize;
      if ParentSize < 1 then
        ParentSize := 1;
      Cursor := 0;
      Sorted := TFPList.Create;
      try
        Tree.ChildrenSortedForDisplay(ANode, Sorted);
        for I := 0 to Sorted.Count - 1 do
        begin
          ChildID := TNodeID(PtrInt(Sorted[I]));
          ChildSize := Tree.SizeOf(ChildID);
          if ChildSize <= 0 then
            Break;
          Share := ChildSize / ParentSize * 100.0;
          ChildFraction := Fraction * Share / 100.0;
          if ChildFraction < ChartMinVisibleFraction then
            Break;
          ChildName := Tree.NameOf(ChildID);
          Result.FChildren.Add(BuildItem(
            ChildID, ChildName, DirectoryPrefix(Path) + ChildName,
            Depth + 1, Cursor, Share, ChildFraction));
          Cursor := Cursor + Share;
        end;
      finally
        Sorted.Free;
      end;
    end;
  end;

begin
  Result := BuildItem(Node, AName, APath, 0, 0, 100, 1);
end;

end.
