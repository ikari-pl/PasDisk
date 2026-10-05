{ RingsLayout — exact port of OpenDisk RingsChartLayout.swift }

unit RingsLayout;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, ChartItem;

const
  RingItemMinAngle = 0.03;
  RingPadding = 10.0;

type
  TRingSegment = class
  public
    Path: string;
    Name: string;
    Size: Int64;
    Kind: TChartKind;
    Depth: Integer;
    FractionOfRoot: Double;
    HasHiddenChildren: Boolean;
    StartAngle: Double;
    Sweep: Double;
    InnerRadius: Double;
    OuterRadius: Double;
    ColorPosition: Double;
  end;

  TRingsLayout = class
  private
    FCenterX: Double;
    FCenterY: Double;
    FThickness: Double;
    FSegments: TFPList;
    procedure AppendSegments(Item: TChartItem; StartAngle, Sweep, Thickness: Double);
  public
    constructor Create(Root: TChartItem; Width, Height: Double);
    destructor Destroy; override;
    { Port of RingsChartLayout.Layout.segment(at:) }
    function SegmentAt(X, Y: Double): TRingSegment;
    property CenterX: Double read FCenterX;
    property CenterY: Double read FCenterY;
    property Thickness: Double read FThickness;
    property Segments: TFPList read FSegments;
  end;

{ SVG path for an annular sector — mirrors ChartDrawing.sectorPath }
function SectorPathSVG(CX, CY, InnerR, OuterR, A0, A1: Double): string;

implementation

function PolarXY(CX, CY, Radius, Angle: Double; out X, Y: Double): string;
begin
  X := CX + Cos(Angle) * Radius;
  Y := CY + Sin(Angle) * Radius;
  Result := Format('%.4f,%.4f', [X, Y]);
end;

function SectorPathSVG(CX, CY, InnerR, OuterR, A0, A1: Double): string;
var
  Sweep, AbsSweep: Double;
  Large: Integer;
  OX0, OY0, OX1, OY1, IX0, IY0, IX1, IY1: Double;
  Outer0, Outer1, Inner0, Inner1: string;
begin
  { Swift:
      move to inner@a0
      arc outer a0→a1 CCW
      line to inner@a1
      arc inner a1→a0 CW
      close
    SVG equivalent starts on the outer rim (after the implied radial). }
  Sweep := A1 - A0;
  AbsSweep := Abs(Sweep);
  if AbsSweep > Pi then
    Large := 1
  else
    Large := 0;
  { Clamp near-full circles so SVG arc endpoints are distinct enough }
  if AbsSweep >= 2 * Pi - 1e-6 then
  begin
    A1 := A0 + 2 * Pi - 1e-4;
    Sweep := A1 - A0;
    Large := 1;
  end;
  Outer0 := PolarXY(CX, CY, OuterR, A0, OX0, OY0);
  Outer1 := PolarXY(CX, CY, OuterR, A1, OX1, OY1);
  Inner0 := PolarXY(CX, CY, InnerR, A0, IX0, IY0);
  Inner1 := PolarXY(CX, CY, InnerR, A1, IX1, IY1);
  { Exact Swift sectorPath order:
      M inner@a0 → (line to) outer@a0 → arc outer a0→a1 CCW
      → line inner@a1 → arc inner a1→a0 CW → Z }
  Result := Format(
    'M %s L %s A %.4f,%.4f 0 %d 1 %s L %s A %.4f,%.4f 0 %d 0 %s Z',
    [Inner0, Outer0, OuterR, OuterR, Large, Outer1,
     Inner1, InnerR, InnerR, Large, Inner0]);
end;

constructor TRingsLayout.Create(Root: TChartItem; Width, Height: Double);
var
  MaxRadius: Double;
begin
  inherited Create;
  FSegments := TFPList.Create;
  FCenterX := Width / 2;
  FCenterY := Height / 2;
  MaxRadius := Min(Width, Height) / 2 - RingPadding;
  if MaxRadius < 1 then
    MaxRadius := 1;
  FThickness := MaxRadius / (ChartMaxDepth + 1);
  { Swift: startAngle: 0, sweep: 2π — do not invent a -π/2 offset }
  AppendSegments(Root, 0, 2 * Pi, FThickness);
end;

destructor TRingsLayout.Destroy;
var
  I: Integer;
begin
  for I := 0 to FSegments.Count - 1 do
    TRingSegment(FSegments[I]).Free;
  FSegments.Free;
  inherited Destroy;
end;

function TRingsLayout.SegmentAt(X, Y: Double): TRingSegment;
var
  DX, DY, Radius, Angle: Double;
  I: Integer;
  Seg, Root: TRingSegment;
begin
  Result := nil;
  if FSegments.Count = 0 then
    Exit;
  Root := TRingSegment(FSegments[0]);
  DX := X - FCenterX;
  DY := Y - FCenterY;
  Radius := Sqrt(DX * DX + DY * DY);
  if Radius <= Root.OuterRadius then
    Exit(Root);
  Angle := ArcTan2(DY, DX);
  if Angle < 0 then
    Angle := Angle + 2 * Pi;
  for I := 0 to FSegments.Count - 1 do
  begin
    Seg := TRingSegment(FSegments[I]);
    if (Seg.Depth > 0)
      and (Radius > Seg.InnerRadius) and (Radius <= Seg.OuterRadius)
      and (Angle >= Seg.StartAngle)
      and (Angle < Seg.StartAngle + Seg.Sweep) then
      Exit(Seg);
  end;
end;

procedure TRingsLayout.AppendSegments(Item: TChartItem;
  StartAngle, Sweep, Thickness: Double);
var
  Seg: TRingSegment;
  InnerR: Double;
  I: Integer;
  Child: TChartItem;
begin
  if (Item.Depth > 0) and (Sweep < RingItemMinAngle) then
    Exit;
  InnerR := Item.Depth * Thickness;
  Seg := TRingSegment.Create;
  Seg.Path := Item.Path;
  Seg.Name := Item.Name;
  Seg.Size := Item.Size;
  Seg.Kind := Item.Kind;
  Seg.Depth := Item.Depth;
  Seg.FractionOfRoot := Item.FractionOfRoot;
  Seg.HasHiddenChildren := Item.HasHiddenChildren;
  Seg.StartAngle := StartAngle;
  Seg.Sweep := Sweep;
  Seg.InnerRadius := InnerR;
  Seg.OuterRadius := InnerR + Thickness;
  Seg.ColorPosition := (StartAngle + Sweep / 2) / (2 * Pi) * 200;
  FSegments.Add(Seg);
  for I := 0 to Item.Children.Count - 1 do
  begin
    Child := TChartItem(Item.Children[I]);
    AppendSegments(
      Child,
      StartAngle + Sweep * Child.RelStart / 100.0,
      Sweep * Child.RelSize / 100.0,
      Thickness);
  end;
end;

end.
