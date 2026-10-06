{ RingsLayout parity with OpenDisk Views/Charts/RingsChartLayout.swift. }

program test_ringslayout;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, FileTree, ChartItem, RingsLayout;

var
  Fail: Boolean;

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

function Near(A, B: Double): Boolean;
begin
  Result := Abs(A - B) < 1e-9;
end;

function At(L: TRingsLayout; Radius, Angle: Double): TRingSegment;
begin
  Result := L.SegmentAt(L.CenterX + Cos(Angle) * Radius,
    L.CenterY + Sin(Angle) * Radius);
end;

var
  Tree: TFileTree;
  Root: TChartItem;
  L: TRingsLayout;
  Seg, First: TRingSegment;
  I, Depth1: Integer;
  SweepSum, T: Double;
  HasTiny: Boolean;
{ DiskAnalyzer.swift cleanableChartRoot. }
procedure TestSyntheticRoot;
var
  Leaves: TChartLeaves;
  Root: TChartItem;
begin
  SetLength(Leaves, 2);
  Leaves[0].Name := 'Big'; Leaves[0].Path := '/c/big'; Leaves[0].Size := 300; Leaves[0].IsDirectory := True;
  Leaves[1].Name := 'Small'; Leaves[1].Path := '/c/small'; Leaves[1].Size := 100; Leaves[1].IsDirectory := True;
  Root := TChartItem.BuildSynthetic('Purgeable Space', '::Purgeable Space', Leaves);
  try
    Expect((Root <> nil) and (Root.Kind = ckSynthetic) and (Root.Size = 400) and
      (Root.Path = '::Purgeable Space'), 'synthetic root carries the total');
    Expect((Root.Children.Count = 2) and
      (Abs(TChartItem(Root.Children[0]).RelSize - 75) < 1e-9) and
      (Abs(TChartItem(Root.Children[1]).RelStart - 75) < 1e-9) and
      (TChartItem(Root.Children[1]).Depth = 1) and
      (TChartItem(Root.Children[0]).Children.Count = 0),
      'leaves share the ring in order, without children');
  finally
    Root.Free;
  end;
  SetLength(Leaves, 0);
  Expect(TChartItem.BuildSynthetic('x', '::x', Leaves) = nil, 'no total, no chart');
end;

begin
  TestSyntheticRoot;
  Fail := False;
  Tree := TFileTree.Create('/root');
  Tree.AddNode('a', RootID, 6000, False);
  Tree.AddNode('b', RootID, 3000, False);
  Tree.AddNode('c', RootID, 960, False);
  Tree.AddNode('tiny', RootID, 40, False);   { 0.4%: sweep 0.025 < 0.03 }
  Tree.RollUpDirectorySizes;
  Root := TChartItem.Build(Tree, RootID, 'root', '/root');
  L := TRingsLayout.Create(Root, 420, 420);
  try
    T := L.Thickness;
    Expect(Near(L.CenterX, 210) and Near(L.CenterY, 210), 'center is half the size');
    Expect(Near(T, (210 - Double(RingPadding)) / (ChartMaxDepth + 1)),
      'thickness = (min/2 - padding) / (maxDepth + 1)');

    Seg := TRingSegment(L.Segments[0]);
    Expect((Seg.Depth = 0) and Near(Seg.StartAngle, 0) and Near(Seg.Sweep, 2 * Pi),
      'root segment starts at angle 0 (no -pi/2 offset) and sweeps 2pi');
    Expect(Near(Seg.InnerRadius, 0) and Near(Seg.OuterRadius, T), 'root ring is [0, thickness]');

    SweepSum := 0;
    Depth1 := 0;
    First := nil;
    HasTiny := False;
    for I := 1 to L.Segments.Count - 1 do
    begin
      Seg := TRingSegment(L.Segments[I]);
      if Seg.Name = 'tiny' then
        HasTiny := True;
      if Seg.Depth <> 1 then
        Continue;
      Inc(Depth1);
      SweepSum := SweepSum + Seg.Sweep;
      if (First = nil) or (Seg.StartAngle < First.StartAngle) then
        First := Seg;
      Expect(Near(Seg.InnerRadius, T) and Near(Seg.OuterRadius, 2 * T),
        Seg.Name + ' ring is [thickness, 2*thickness]');
      Expect(Near(Seg.ColorPosition, (Seg.StartAngle + Seg.Sweep / 2) / (2 * Pi) * 200),
        Seg.Name + ' colorPosition = mid-angle / 2pi * 200');
    end;
    Expect(Depth1 = 3, Format('three visible children (got %d)', [Depth1]));
    Expect(not HasTiny, 'child under itemMinAngle (0.03 rad) is not laid out');
    Expect((First <> nil) and Near(First.StartAngle, 0), 'first child starts at angle 0');
    Expect(Near(SweepSum, 2 * Pi * 0.996), 'visible child sweeps match their share');

    Expect(L.SegmentAt(L.CenterX, L.CenterY) = TRingSegment(L.Segments[0]),
      'center hit returns root');
    Expect(At(L, T, 1.0) = TRingSegment(L.Segments[0]),
      'radius == root outer radius is still root (<=)');
    Expect(At(L, 1.5 * T, 0.001) = First, 'just past angle 0 in ring 1 hits the first child');
    Expect(At(L, 2 * T, 0.001) = First, 'outer boundary of ring 1 belongs to ring 1 (<=)');
    Expect(At(L, 2 * T + 0.5, 0.001) = nil, 'empty ring 2 hits nothing');
    Expect(At(L, 205, 0.001) = nil, 'outside the chart hits nothing');
  finally
    L.Free;
    Root.Free;
    Tree.Free;
  end;
  if Fail then
    Halt(1);
  WriteLn('test_ringslayout: all passed');
end.
