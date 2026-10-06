{ RingsChart — LCL control over RingsLayout (Swift geometry port). }

unit RingsChart;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Graphics, Controls, ChartItem, Formatters, RingsLayout,
  GuiColors;

type
  TRingSelectEvent = procedure(Sender: TObject; const Path: string;
    IsCenter: Boolean) of object;

  TRingsChart = class(TCustomControl)
  private
    FRoot: TChartItem;
    FOwnsRoot: Boolean;
    FHoverPath: string;
    FOnSelect: TRingSelectEvent;
    FLayout: TRingsLayout;
    procedure SetRoot(AValue: TChartItem);
    procedure RebuildLayout;
    procedure DrawBackground(ACanvas: TCanvas; const R: TRect);
    procedure DrawSegment(ACanvas: TCanvas; Seg: TRingSegment; Highlighted: Boolean);
    function ColorFor(ColorPosition: Double; Depth: Integer;
      Highlighted: Boolean): TColor;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure Click; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure TakeRoot(ARoot: TChartItem);
    property Root: TChartItem read FRoot write SetRoot;
    property OnSelect: TRingSelectEvent read FOnSelect write FOnSelect;
  end;

implementation

constructor TRingsChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FOwnsRoot := False;
  FLayout := nil;
  DoubleBuffered := True;
  Color := clWindow;
end;

destructor TRingsChart.Destroy;
begin
  FreeAndNil(FLayout);
  if FOwnsRoot then
    FRoot.Free;
  inherited Destroy;
end;

procedure TRingsChart.SetRoot(AValue: TChartItem);
begin
  if FOwnsRoot then
    FreeAndNil(FRoot);
  FOwnsRoot := False;
  FRoot := AValue;
  RebuildLayout;
  Invalidate;
end;

procedure TRingsChart.TakeRoot(ARoot: TChartItem);
begin
  if FOwnsRoot then
    FreeAndNil(FRoot);
  FRoot := ARoot;
  FOwnsRoot := True;
  RebuildLayout;
  Invalidate;
end;

procedure TRingsChart.RebuildLayout;
var
  R: TRect;
begin
  FreeAndNil(FLayout);
  if FRoot = nil then
    Exit;
  R := ClientRect;
  if (R.Right - R.Left < 2) or (R.Bottom - R.Top < 2) then
    Exit;
  FLayout := TRingsLayout.Create(FRoot, R.Right - R.Left, R.Bottom - R.Top);
end;

procedure TRingsChart.Resize;
begin
  inherited Resize;
  RebuildLayout;
  Invalidate;
end;

function Blend(C1, C2: TColor; T: Double): TColor;
var
  R1, G1, B1, R2, G2, B2: Integer;
begin
  R1 := Red(C1); G1 := Green(C1); B1 := Blue(C1);
  R2 := Red(C2); G2 := Green(C2); B2 := Blue(C2);
  Result := RGBToColor(
    Round(R1 + (R2 - R1) * T),
    Round(G1 + (G2 - G1) * T),
    Round(B1 + (B2 - B1) * T));
end;

function ContrastTextColor(Background: TColor): TColor;
var
  ResolvedBackground: TColor;
  Luma: Integer;
begin
  ResolvedBackground := ColorToRGB(Background);
  Luma := (Red(ResolvedBackground) * 299 + Green(ResolvedBackground) * 587 +
    Blue(ResolvedBackground) * 114) div 1000;
  if Luma >= 150 then
    Result := ColorToRGB(clWindowText)
  else
    Result := RGBToColor(255, 255, 255);
end;

{ Port of ChartPalette.fill }
function TRingsChart.ColorFor(ColorPosition: Double; Depth: Integer;
  Highlighted: Boolean): TColor;
const
  Hues: array[0..5] of TColor = (
    $00241BE0,
    $000078FF,
    $002DD3F6,
    $007AD133,
    $00E48435,
    $00AC4191
  );
  BandWidth = 100.0 / 3.0;
var
  Clamped, T, Intensity: Double;
  Band: Integer;
  Base: TColor;
  R, G, B: Integer;
  Peak: Integer;
begin
  if Depth = 0 then
  begin
    if Highlighted then
      Exit(clHighlight)
    else
      Exit(clBtnFace);
  end;
  Clamped := ColorPosition;
  if not (Clamped = Clamped) then
    Clamped := 0;
  if Clamped < 0 then
    Clamped := 0;
  if Clamped > 199.999 then
    Clamped := 199.999;
  Band := Trunc(Clamped / BandWidth) mod 6;
  T := (Clamped - Band * BandWidth) / BandWidth;
  Base := Blend(Hues[Band], Hues[(Band + 1) mod 6], T);
  Intensity := 1.0 - ((Depth - 1) * 0.3) / 5.0;
  R := Round(Red(Base) * Intensity);
  G := Round(Green(Base) * Intensity);
  B := Round(Blue(Base) * Intensity);
  if Highlighted then
  begin
    Peak := Max(R, Max(G, B));
    if Peak > 0 then
    begin
      R := Round(R * 255 / Peak);
      G := Round(G * 255 / Peak);
      B := Round(B * 255 / Peak);
    end;
  end;
  Result := RGBToColor(R, G, B);
end;

procedure TRingsChart.DrawBackground(ACanvas: TCanvas; const R: TRect);
begin
  ACanvas.Brush.Color := clWindow;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.FillRect(R);
end;

procedure TRingsChart.DrawSegment(ACanvas: TCanvas; Seg: TRingSegment;
  Highlighted: Boolean);
var
  Pts: array of TPoint;
  Steps, I, N: Integer;
  A, A0, A1, Mid: Double;
  SX, SY: Integer;
begin
  ACanvas.Brush.Color := ColorFor(Seg.ColorPosition, Seg.Depth, Highlighted);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Pen.Color := clBtnShadow;
  ACanvas.Pen.Width := 1;

  if Seg.Depth = 0 then
  begin
    ACanvas.Ellipse(
      Round(FLayout.CenterX - Seg.OuterRadius),
      Round(FLayout.CenterY - Seg.OuterRadius),
      Round(FLayout.CenterX + Seg.OuterRadius),
      Round(FLayout.CenterY + Seg.OuterRadius));
    ACanvas.Font.Color := ContrastTextColor(ACanvas.Brush.Color);
    ACanvas.Font.Style := [fsBold];
    ACanvas.Font.Size := 11;
    ACanvas.Brush.Style := bsClear;
    ACanvas.TextOut(
      Round(FLayout.CenterX) - ACanvas.TextWidth(Seg.Name) div 2,
      Round(FLayout.CenterY) - ACanvas.TextHeight(Seg.Name) - 2,
      Seg.Name);
    ACanvas.Font.Style := [];
    ACanvas.Font.Size := 9;
    ACanvas.Font.Color := ContrastTextColor(ACanvas.Brush.Color);
    ACanvas.TextOut(
      Round(FLayout.CenterX) - ACanvas.TextWidth(FormatFileSize(Seg.Size)) div 2,
      Round(FLayout.CenterY) + 2,
      FormatFileSize(Seg.Size));
    ACanvas.Brush.Style := bsSolid;
    Exit;
  end;

  A0 := Seg.StartAngle;
  A1 := Seg.StartAngle + Seg.Sweep;
  Steps := Max(8, Round(Abs(Seg.Sweep) / (Pi / 64)));
  N := (Steps + 1) * 2;
  SetLength(Pts, N);
  for I := 0 to Steps do
  begin
    A := A0 + (A1 - A0) * I / Steps;
    Pts[I].X := Round(FLayout.CenterX + Cos(A) * Seg.OuterRadius);
    Pts[I].Y := Round(FLayout.CenterY + Sin(A) * Seg.OuterRadius);
  end;
  for I := 0 to Steps do
  begin
    A := A0 + (A1 - A0) * (Steps - I) / Steps;
    Pts[Steps + 1 + I].X := Round(FLayout.CenterX + Cos(A) * Seg.InnerRadius);
    Pts[Steps + 1 + I].Y := Round(FLayout.CenterY + Sin(A) * Seg.InnerRadius);
  end;
  ACanvas.Polygon(Pts);

  if Seg.HasHiddenChildren then
  begin
    ACanvas.Pen.Color := ACanvas.Brush.Color;
    ACanvas.Pen.Width := 3;
    ACanvas.Brush.Style := bsClear;
    { approximate continued-edge arc as polyline }
    SetLength(Pts, Steps + 1);
    for I := 0 to Steps do
    begin
      A := A0 + (A1 - A0) * I / Steps;
      Pts[I].X := Round(FLayout.CenterX + Cos(A) * (Seg.OuterRadius + 4));
      Pts[I].Y := Round(FLayout.CenterY + Sin(A) * (Seg.OuterRadius + 4));
    end;
    ACanvas.Polyline(Pts);
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Pen.Width := 1;
  end;

  Mid := (Seg.InnerRadius + Seg.OuterRadius) / 2;
  if (Seg.Sweep * Mid > 36) and (FLayout.Thickness >= 14) then
  begin
    ACanvas.Font.Size := 8;
    ACanvas.Font.Color := ContrastTextColor(ACanvas.Brush.Color);
    ACanvas.Brush.Style := bsClear;
    SX := Round(FLayout.CenterX + Cos(A0 + Seg.Sweep / 2) * Mid);
    SY := Round(FLayout.CenterY + Sin(A0 + Seg.Sweep / 2) * Mid);
    ACanvas.TextOut(SX - ACanvas.TextWidth(Seg.Name) div 2,
      SY - ACanvas.TextHeight(Seg.Name) div 2, Seg.Name);
    ACanvas.Brush.Style := bsSolid;
  end;
end;

procedure TRingsChart.Paint;
var
  R: TRect;
  I: Integer;
  Seg: TRingSegment;
begin
  R := ClientRect;
  DrawBackground(Canvas, R);
  if FRoot = nil then
  begin
    Canvas.Font.Color := SecondaryTextColor(clWindow);
    Canvas.Font.Size := 12;
    Canvas.TextOut(R.Left + 24, R.Top + 24, 'Rings appear after a scan.');
    Exit;
  end;
  if FLayout = nil then
    RebuildLayout;
  if FLayout = nil then
    Exit;
  for I := 0 to FLayout.Segments.Count - 1 do
  begin
    Seg := TRingSegment(FLayout.Segments[I]);
    DrawSegment(Canvas, Seg, Seg.Path = FHoverPath);
  end;
end;

procedure TRingsChart.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Hit: TRingSegment;
  NewPath: string;
begin
  inherited;
  NewPath := '';
  if FLayout <> nil then
  begin
    Hit := FLayout.SegmentAt(X, Y);
    if Hit <> nil then
      NewPath := Hit.Path;
  end;
  if NewPath <> FHoverPath then
  begin
    FHoverPath := NewPath;
    Invalidate;
  end;
end;

procedure TRingsChart.MouseLeave;
begin
  inherited;
  if FHoverPath <> '' then
  begin
    FHoverPath := '';
    Invalidate;
  end;
end;

procedure TRingsChart.Click;
var
  P: TPoint;
  Hit: TRingSegment;
begin
  inherited Click;
  if FLayout = nil then
    Exit;
  P := ScreenToClient(Mouse.CursorPos);
  Hit := FLayout.SegmentAt(P.X, P.Y);
  if Hit = nil then
    Exit;
  if Assigned(FOnSelect) then
    FOnSelect(Self, Hit.Path, Hit.Depth = 0);
end;

end.
