{ RingsChart — LCL control over RingsLayout (Swift geometry port). }

unit RingsChart;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Graphics, Controls, ChartItem, Formatters, RingsLayout,
  GuiColors, PlatformChartCanvas, ChartHoverTip, DesignTokens, PlatformChartAccessibility,
  Motion, PlatformMotion;

type
  { A segment's shape: start angle, sweep, inner and outer radius. }
  TRingGeometry = record
    A0, Sweep, RIn, ROut: Double;
  end;

  TDepartedRing = record
    Geometry: TRingGeometry;
    Color: TColor;
  end;

  TRingSelectEvent = procedure(Sender: TObject; const Path: string;
    IsCenter: Boolean) of object;

  { A drag of a segment began (RingsChartView fileDrag). }
  TRingDragEvent = procedure(Sender: TObject; Seg: TRingSegment) of object;

  TRingsChart = class(TCustomControl)
  private
    FRoot: TChartItem;
    FOwnsRoot: Boolean;
    FHoverPath: string;
    FHoverX, FHoverY: Integer;
    FHoverActive: Boolean;
    FEnvHoverApplied: Boolean;
    FOnSelect: TRingSelectEvent;
    FOnDragSegment: TRingDragEvent;
    { DragGesture(minimumDistance: 4) from the press point. }
    FPressX, FPressY: Integer;
    FPressed, FDragging: Boolean;
    FLayout: TRingsLayout;
    { Folder paths of the accessible elements ('' for files). }
    FAccessiblePaths: array of string;
    FStaticLayer: TChartCanvasCache;
    { Chart motion (owner decision, not in Swift): when the root or its
      sizes change, each segment eases from where it was drawn (FFrom,
      by index into FLayout.Segments) to its new place; segments new to
      the chart grow out of their parent's old arc or fade in
      (FFadeIn); segments that left fade out where they were. Entering a
      folder thereby zooms: its children were already drawn one ring
      out, and it widens into the centre disk. }
    FFrom: array of TRingGeometry;
    FFadeIn: array of Boolean;
    { The colour each segment had where it was drawn: colours are relative
      to the root, so they change on navigation and blend over. }
    FFromColor: array of TColor;
    FDeparted: array of TDepartedRing;
    FMotion: TAnimatedValue;
    FMotionClock: TFrameClock;
    { No frame drawn yet: the motion's clock starts with the first one, so
      main-thread work right after the change (navigation, list refresh)
      does not eat its start. }
    FMotionWaiting: Boolean;
    procedure MotionFrame(Sender: TObject);
    function Animating: Boolean;
    function ShownGeometry(Index: Integer; P: Double): TRingGeometry;
    function ShownColor(Index: Integer; P: Double): TColor;
    procedure ChangeRoot(ARoot: TChartItem; Owns: Boolean);
    procedure PaintMotion(const R: TRect);
    procedure SetRoot(AValue: TChartItem);
    procedure RebuildLayout;
    procedure DrawBackground(ACanvas: TCanvas; const R: TRect);
    procedure DrawSegment(ACanvas: TCanvas; Seg: TRingSegment; Highlighted: Boolean);
    procedure DrawSegmentLabels(ACanvas: TCanvas; Seg: TRingSegment);
    function ColorFor(ColorPosition: Double; Depth: Integer;
      Highlighted: Boolean): TColor;
    procedure ApplyEnvironmentHover;
    procedure UpdateAccessibility;
    procedure AccessiblePress(Index: Integer);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Click; override;
  public
    { The drag ended (its mouse-up never reaches the control). }
    procedure DragFinished;
    { RingsChartView.draggableSegment(at:): depth >= 1, a file or folder;
      nil elsewhere. }
    function DraggableSegmentAt(X, Y: Integer): TRingSegment;
    { Colours come from the appearance: drop the cached layer. }
    procedure AppearanceChanged;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure TakeRoot(ARoot: TChartItem);
    property Root: TChartItem read FRoot write SetRoot;
    property OnSelect: TRingSelectEvent read FOnSelect write FOnSelect;
    property OnDragSegment: TRingDragEvent read FOnDragSegment write FOnDragSegment;
    property OnContextPopup;
  end;

implementation

constructor TRingsChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FOwnsRoot := False;
  FLayout := nil;
  FHoverX := 0;
  FHoverY := 0;
  FHoverActive := False;
  FEnvHoverApplied := False;
  FStaticLayer := TChartCanvasCache.Create;
  DoubleBuffered := True;
  Color := clWindow;
end;

destructor TRingsChart.Destroy;
begin
  FreeAndNil(FMotionClock);
  FreeAndNil(FLayout);
  FreeAndNil(FStaticLayer);
  if FOwnsRoot then
    FRoot.Free;
  inherited Destroy;
end;

procedure TRingsChart.SetRoot(AValue: TChartItem);
begin
  ChangeRoot(AValue, False);
end;

procedure TRingsChart.TakeRoot(ARoot: TChartItem);
begin
  ChangeRoot(ARoot, True);
end;

const
  ChartZoomMs = 150;
  ChartSettleMs = 125;
  { Departing segments are gone within this share of the motion (owner:
    fade-outs much faster than the movement). }
  ChartFadeOutShare = 0.3;

function Blend(C1, C2: TColor; T: Double): TColor; forward;

{ The colour segment Index shows at progress P. }
function TRingsChart.ShownColor(Index: Integer; P: Double): TColor;
var
  Seg: TRingSegment;
begin
  Seg := TRingSegment(FLayout.Segments[Index]);
  Result := ColorToRGB(ColorFor(Seg.ColorPosition, Seg.Depth, False));
  if Index <= High(FFromColor) then
    Result := Blend(FFromColor[Index], Result, P);
end;

function GeometryOf(Seg: TRingSegment): TRingGeometry;
begin
  if Seg.Depth = 0 then
  begin
    { The centre disk: a full turn from the centre out. }
    Result.A0 := 0;
    Result.Sweep := 2 * Pi;
    Result.RIn := 0;
  end
  else
  begin
    Result.A0 := Seg.StartAngle;
    Result.Sweep := Seg.Sweep;
    Result.RIn := Seg.InnerRadius;
  end;
  Result.ROut := Seg.OuterRadius;
end;

function LerpGeometry(const A, B: TRingGeometry; P: Double): TRingGeometry;
var
  D: Double;
begin
  { Start angles take the shorter way round. }
  D := B.A0 - A.A0;
  while D > Pi do
    D := D - 2 * Pi;
  while D < -Pi do
    D := D + 2 * Pi;
  Result.A0 := A.A0 + D * P;
  Result.Sweep := A.Sweep + (B.Sweep - A.Sweep) * P;
  Result.RIn := A.RIn + (B.RIn - A.RIn) * P;
  Result.ROut := A.ROut + (B.ROut - A.ROut) * P;
end;

function TRingsChart.Animating: Boolean;
begin
  Result := (FMotionClock <> nil) and FMotionClock.Running;
end;

function TRingsChart.ShownGeometry(Index: Integer; P: Double): TRingGeometry;
begin
  Result := GeometryOf(TRingSegment(FLayout.Segments[Index]));
  if Index <= High(FFrom) then
    Result := LerpGeometry(FFrom[Index], Result, P);
end;

{ New root (navigation) or new sizes (a scan update): the chart is laid
  out again, and moves there from what it showed. }
procedure TRingsChart.ChangeRoot(ARoot: TChartItem; Owns: Boolean);
var
  OldPaths, NewPaths: TStringList;
  OldShapes: array of TRingGeometry;
  OldColors: array of TColor;
  OldRoot: string;
  Seg: TRingSegment;
  I, K, Up, N: Integer;
  P, F: Double;
  PG, NG, PF: TRingGeometry;
  Navigating: Boolean;
  Slow: Integer;
begin
  OldPaths := nil;
  OldRoot := '';
  { Where each segment is drawn now (mid-motion: where it is on screen). }
  if (FLayout <> nil) and HandleAllocated and IsVisible and not ReduceMotion then
  begin
    P := 1;
    if Animating then
      P := ValueAt(FMotion, GetTickCount64);
    OldPaths := TStringList.Create;
    OldPaths.Sorted := True;
    OldPaths.Duplicates := dupIgnore;
    SetLength(OldShapes, FLayout.Segments.Count);
    SetLength(OldColors, FLayout.Segments.Count);
    for I := 0 to FLayout.Segments.Count - 1 do
    begin
      Seg := TRingSegment(FLayout.Segments[I]);
      if Seg.Depth = 0 then
        OldRoot := Seg.Path;
      OldShapes[I] := ShownGeometry(I, P);
      OldColors[I] := ShownColor(I, P);
      if Seg.Path <> '' then
        OldPaths.AddObject(Seg.Path, TObject(PtrInt(I)));
    end;
  end;

  if FOwnsRoot and (FRoot <> ARoot) then
    FreeAndNil(FRoot);
  FRoot := ARoot;
  FOwnsRoot := Owns;
  FEnvHoverApplied := False;
  RebuildLayout;
  FStaticLayer.Invalidate;
  FFrom := nil;
  FFadeIn := nil;
  FFromColor := nil;
  FDeparted := nil;
  try
    if (OldPaths = nil) or (FLayout = nil) then
    begin
      if FMotionClock <> nil then
        FMotionClock.Stop;
      Exit;
    end;
    NewPaths := TStringList.Create;
    try
      NewPaths.Sorted := True;
      NewPaths.Duplicates := dupIgnore;
      SetLength(FFrom, FLayout.Segments.Count);
      SetLength(FFadeIn, FLayout.Segments.Count);
      SetLength(FFromColor, FLayout.Segments.Count);
      Navigating := False;
      for I := 0 to FLayout.Segments.Count - 1 do
      begin
        Seg := TRingSegment(FLayout.Segments[I]);
        if Seg.Path <> '' then
          NewPaths.AddObject(Seg.Path, TObject(PtrInt(I)));
        if (Seg.Depth = 0) and (Seg.Path <> OldRoot) then
          Navigating := True;
        NG := GeometryOf(Seg);
        FFrom[I] := NG;
        FFadeIn[I] := False;
        FFromColor[I] := ColorToRGB(ColorFor(Seg.ColorPosition, Seg.Depth, False));
        if (Seg.Path <> '') and OldPaths.Find(Seg.Path, K) then
        begin
          FFrom[I] := OldShapes[PtrInt(OldPaths.Objects[K])];
          FFromColor[I] := OldColors[PtrInt(OldPaths.Objects[K])];
          Continue;
        end;
        { New here: out of its parent's old arc, when the parent was
          drawn; else it fades in. Parents come before their children. }
        FFadeIn[I] := True;
        if NewPaths.Find(ExtractFileDir(Seg.Path), K) then
        begin
          Up := PtrInt(NewPaths.Objects[K]);
          if (Up < I) and not FFadeIn[Up] then
          begin
            PG := GeometryOf(TRingSegment(FLayout.Segments[Up]));
            PF := FFrom[Up];
            if PG.Sweep > 0 then
            begin
              F := PF.Sweep / PG.Sweep;
              FFrom[I].A0 := PF.A0 + (NG.A0 - PG.A0) * F;
              FFrom[I].Sweep := NG.Sweep * F;
              FFrom[I].RIn := PF.ROut;
              FFrom[I].ROut := PF.ROut;
              FFadeIn[I] := False;
            end;
          end;
        end;
      end;
      { Segments no longer in the chart fade out where they were. }
      N := 0;
      SetLength(FDeparted, Length(OldShapes));
      for I := 0 to OldPaths.Count - 1 do
        if not NewPaths.Find(OldPaths[I], K) then
        begin
          FDeparted[N].Geometry := OldShapes[PtrInt(OldPaths.Objects[I])];
          FDeparted[N].Color := OldColors[PtrInt(OldPaths.Objects[I])];
          Inc(N);
        end;
      SetLength(FDeparted, N);
    finally
      NewPaths.Free;
    end;
    FMotion := AnimatedAt(0);
    { Entering or leaving a folder is a spatial move (ease-out); a scan
      update settles (snappy). Owner-tuned: quick, so the chart never
      lags the list. }
    { Debug: OPENDISK_DEBUG_MOTION_SLOW=<n> stretches it n times, to
      inspect frames. }
    Slow := StrToIntDef(GetEnvironmentVariable('OPENDISK_DEBUG_MOTION_SLOW'), 1);
    if Navigating then
      Retarget(FMotion, 1, GetTickCount64, ChartZoomMs * Max(1, Slow), eaEaseOut)
    else
      Retarget(FMotion, 1, GetTickCount64, ChartSettleMs * Max(1, Slow), eaSnappy);
    FMotionWaiting := True;
    if FMotionClock = nil then
      FMotionClock := TFrameClock.Create(Self, @MotionFrame);
    FMotionClock.Start;
  finally
    OldPaths.Free;
    Invalidate;
  end;
end;

procedure TRingsChart.MotionFrame(Sender: TObject);
var
  Duration: Integer;
  Easing: TEasing;
begin
  if FMotionWaiting then
  begin
    FMotionWaiting := False;
    Duration := FMotion.DurationMs;
    Easing := FMotion.Easing;
    FMotion := AnimatedAt(0);
    Retarget(FMotion, 1, GetTickCount64, Duration, Easing);
  end;
  if GetEnvironmentVariable('OPENDISK_DEBUG_MOTION') = '1' then
  begin
    WriteLn(Format('chart frame %.3f (%d segments, %d leaving)',
      [ValueAt(FMotion, GetTickCount64), Length(FFrom), Length(FDeparted)]));
    Flush(Output);
  end;
  if AtRest(FMotion, GetTickCount64) then
  begin
    FMotionClock.Stop;
    FFrom := nil;
    FFadeIn := nil;
    FFromColor := nil;
    FDeparted := nil;
  end;
  Invalidate;
end;

{ One frame of chart motion, drawn directly (the static layer holds only
  the resting chart). Labels and hover wait until it lands. }
procedure TRingsChart.PaintMotion(const R: TRect);
var
  P, T: Double;
  I: Integer;
  G: TRingGeometry;
  Seg: TRingSegment;
  Border: TColor;
begin
  P := ValueAt(FMotion, GetTickCount64);
  { Linear time share for the fade-out, over its own shorter span. }
  T := 1;
  if FMotion.DurationMs > 0 then
    T := Min(1, (GetTickCount64 - FMotion.StartMs) / (FMotion.DurationMs * ChartFadeOutShare));
  DrawBackground(Canvas, R);
  Border := ColorToRGB(clBtnShadow);
  for I := 0 to High(FDeparted) do
  begin
    SetCanvasAlpha(Canvas, 1 - T);
    G := FDeparted[I].Geometry;
    FillAnnularSector(Canvas, FLayout.CenterX, FLayout.CenterY, G.RIn, G.ROut,
      G.A0, G.A0 + G.Sweep, FDeparted[I].Color, Border, 1);
  end;
  for I := 0 to FLayout.Segments.Count - 1 do
  begin
    Seg := TRingSegment(FLayout.Segments[I]);
    G := ShownGeometry(I, P);
    if (I <= High(FFadeIn)) and FFadeIn[I] then
      SetCanvasAlpha(Canvas, P)
    else
      SetCanvasAlpha(Canvas, 1);
    if (G.Sweep >= 2 * Pi - 1e-6) and (G.RIn <= 0.5) then
      FillAnnularSector(Canvas, FLayout.CenterX, FLayout.CenterY, 0, G.ROut,
        0, 2 * Pi, ShownColor(I, P), Border, 1)
    else
      FillAnnularSector(Canvas, FLayout.CenterX, FLayout.CenterY, G.RIn, G.ROut,
        G.A0, G.A0 + G.Sweep, ShownColor(I, P), Border, 1);
  end;
  SetCanvasAlpha(Canvas, 1);
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
  FEnvHoverApplied := False;
  FStaticLayer.Resize(R.Right - R.Left, R.Bottom - R.Top, BackingScaleFor(Self));
  FStaticLayer.Invalidate;
  UpdateAccessibility;
end;

{ RingsChartView chartAccessibilityLabel / accessibilitySegmentList: the
  chart's label, and one element per first-ring segment (name; size and
  percentage of the root; a button that opens folders). }
procedure TRingsChart.UpdateAccessibility;
var
  Items: array of TChartAccessibleItem;
  Seg: TRingSegment;
  I, N, K, Count: Integer;
  A, X, Y, MinX, MinY, MaxX, MaxY: Double;
  Dot: TFormatSettings;
  ChartLabel: string;
begin
  if (FRoot = nil) or (FLayout = nil) or not HandleAllocated then
    Exit;
  Dot := DefaultFormatSettings;
  Dot.DecimalSeparator := '.';
  Count := FRoot.Children.Count;
  ChartLabel := 'Disk usage chart for ' + FRoot.Name + ', ' + IntToStr(Count) + ' item';
  if Count <> 1 then
    ChartLabel := ChartLabel + 's';
  ChartLabel := ChartLabel + ', total size ' + FormatFileSize(FRoot.Size);
  SetLength(Items, FLayout.Segments.Count);
  N := 0;
  SetLength(FAccessiblePaths, 0);
  SetLength(FAccessiblePaths, FLayout.Segments.Count);
  for I := 0 to FLayout.Segments.Count - 1 do
  begin
    Seg := TRingSegment(FLayout.Segments[I]);
    if Seg.Depth <> 1 then
      Continue;
    Items[N].ItemLabel := Seg.Name;
    Items[N].Value := FormatFileSize(Seg.Size) + ', ' +
      FormatFloat('0.0', Seg.FractionOfRoot * 100, Dot) + ' percent';
    Items[N].IsButton := Seg.Kind = ckDirectory;
    { The annular sector's bounds, from points along both arcs. }
    MinX := MaxDouble;
    MinY := MaxDouble;
    MaxX := -MaxDouble;
    MaxY := -MaxDouble;
    for K := 0 to 16 do
    begin
      A := Seg.StartAngle + Seg.Sweep * K / 16;
      X := FLayout.CenterX + Cos(A) * Seg.OuterRadius;
      Y := FLayout.CenterY + Sin(A) * Seg.OuterRadius;
      MinX := Min(MinX, X); MaxX := Max(MaxX, X);
      MinY := Min(MinY, Y); MaxY := Max(MaxY, Y);
      X := FLayout.CenterX + Cos(A) * Seg.InnerRadius;
      Y := FLayout.CenterY + Sin(A) * Seg.InnerRadius;
      MinX := Min(MinX, X); MaxX := Max(MaxX, X);
      MinY := Min(MinY, Y); MaxY := Max(MaxY, Y);
    end;
    Items[N].Bounds := Rect(Floor(MinX), Floor(MinY), Ceil(MaxX), Ceil(MaxY));
    if Items[N].IsButton then
      FAccessiblePaths[N] := Seg.Path
    else
      FAccessiblePaths[N] := '';
    Inc(N);
  end;
  SetLength(Items, N);
  SetLength(FAccessiblePaths, N);
  SetChartAccessibility(Self, ChartLabel, Items, @AccessiblePress);
end;

{ .accessibilityAction: folders navigate (onSelectDirectory); files do
  nothing. }
procedure TRingsChart.AccessiblePress(Index: Integer);
begin
  if (Index >= 0) and (Index <= High(FAccessiblePaths)) and
    (FAccessiblePaths[Index] <> '') and Assigned(FOnSelect) then
    FOnSelect(Self, FAccessiblePaths[Index], False);
end;

procedure TRingsChart.ApplyEnvironmentHover;
var
  Value, XText, YText: string;
  Comma, X, Y: Integer;
  Hit: TRingSegment;
begin
  if FEnvHoverApplied or (FLayout = nil) then Exit;
  FEnvHoverApplied := True;
  Value := GetEnvironmentVariable('OPENDISK_GUI_HOVER');
  Comma := Pos(',', Value);
  if Comma <= 1 then Exit;
  XText := Trim(Copy(Value, 1, Comma - 1));
  YText := Trim(Copy(Value, Comma + 1, MaxInt));
  if (not TryStrToInt(XText, X)) or (not TryStrToInt(YText, Y)) then Exit;
  if (X < 0) or (Y < 0) or (X >= ClientWidth) or (Y >= ClientHeight) then Exit;
  Hit := FLayout.SegmentAt(X, Y);
  if Hit = nil then Exit;
  FHoverX := X;
  FHoverY := Y;
  FHoverPath := Hit.Path;
  FHoverActive := True;
end;

procedure TRingsChart.AppearanceChanged;
begin
  FStaticLayer.Invalidate;
  Invalidate;
end;

procedure TRingsChart.Resize;
begin
  inherited Resize;
  RebuildLayout;
  FStaticLayer.Resize(ClientWidth, ClientHeight, BackingScaleFor(Self));
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
  { ChartPalette.level / levelHighlighted: fixed light greys (#D3D6D1,
    #E0E2DD), not the accent colour. }
  if Depth = 0 then
  begin
    if Highlighted then
      Exit(TColor($00DDE2E0))
    else
      Exit(TColor($00D1D6D3));
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
  A0, A1, Mid: Double;
  SX, SY: Integer;
begin
  A0 := Seg.StartAngle;
  A1 := Seg.StartAngle + Seg.Sweep;

  if Seg.Depth = 0 then
  begin
    ACanvas.Brush.Color := ColorFor(Seg.ColorPosition, Seg.Depth, Highlighted);
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Pen.Color := clBtnShadow;
    ACanvas.Pen.Width := 1;
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

  FillAnnularSector(ACanvas, FLayout.CenterX, FLayout.CenterY,
    Seg.InnerRadius, Seg.OuterRadius, A0, A1,
    ColorFor(Seg.ColorPosition, Seg.Depth, Highlighted),
    ColorToRGB(clBtnShadow), 1);

  if Seg.HasHiddenChildren then
  begin
    StrokeContinuedEdge(ACanvas, FLayout.CenterX, FLayout.CenterY,
      Seg.OuterRadius + 4, A0, A1,
      ColorFor(Seg.ColorPosition, Seg.Depth, Highlighted), 3);
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

procedure TRingsChart.DrawSegmentLabels(ACanvas: TCanvas; Seg: TRingSegment);
var
  Mid: Double;
  LabelWidth, MaxWidth: Double;
  NameText, SizeText: string;
  Fill, Ink: TColor;
const
  { SwiftUI .caption2 on macOS. }
  LabelFontSize = 10; { .caption2, RingsChartView.swift:246-254 }
begin
  if Seg.Depth = 0 then
  begin
    NameText := Seg.Name;
    SizeText := FormatFileSize(Seg.Size);
    ACanvas.Font.Color := ContrastTextColor(ColorFor(Seg.ColorPosition, Seg.Depth, False));
    ACanvas.Font.Style := [fsBold];
    ACanvas.Font.Size := 11;
    ACanvas.Brush.Style := bsClear;
    MaxWidth := Seg.OuterRadius * 1.7;
    LabelWidth := ACanvas.TextWidth(NameText);
    if LabelWidth > MaxWidth then
    begin
      ACanvas.Font.Style := [];
      ACanvas.Font.Size := 9;
      ACanvas.Font.Color := ContrastTextColor(ColorFor(Seg.ColorPosition, Seg.Depth, False));
      ACanvas.TextOut(Round(FLayout.CenterX) - ACanvas.TextWidth(SizeText) div 2,
        Round(FLayout.CenterY) - ACanvas.TextHeight(SizeText) div 2, SizeText);
      Exit;
    end;
    ACanvas.TextOut(
      Round(FLayout.CenterX) - ACanvas.TextWidth(NameText) div 2,
      Round(FLayout.CenterY) - ACanvas.TextHeight(NameText) div 2 -
        ACanvas.TextHeight(SizeText) div 2 - 1, NameText);
    ACanvas.Font.Style := [];
    ACanvas.Font.Size := 9;
    ACanvas.TextOut(Round(FLayout.CenterX) - ACanvas.TextWidth(SizeText) div 2,
      Round(FLayout.CenterY) + 1, SizeText);
    Exit;
  end;
  Mid := (Seg.InnerRadius + Seg.OuterRadius) / 2;
  { RingsChartView.swift:241-260. DrawTextOnArc mirrors lines 262-277. }
  if (FLayout.Thickness >= 12) and (Seg.Sweep * Mid >= 30) then
  begin
    { .caption2 (10 pt on macOS) in black at 0.75 opacity: over the
      segment's own fill that is the fill scaled to a quarter. }
    Fill := ColorToRGB(ColorFor(Seg.ColorPosition, Seg.Depth, False));
    Ink := RGBToColor(Red(Fill) div 4, Green(Fill) div 4, Blue(Fill) div 4);
    ApplyTextStyle(ACanvas.Font, tsCaption2); { RingsChartView.swift:246-254 }
    ACanvas.Font.Style := [];
    ACanvas.Brush.Style := bsClear;
    LabelWidth := ACanvas.TextWidth(Seg.Name);
    { totalWidth <= arcLength * 0.85, lineHeight <= thickness * 0.85 }
    if (LabelWidth > Seg.Sweep * Mid * 0.85) or
      (ACanvas.TextHeight(Seg.Name) > FLayout.Thickness * 0.85) then
      Exit;
    DrawTextOnArc(ACanvas, Seg.Name, FLayout.CenterX, FLayout.CenterY, Mid,
      Seg.StartAngle + Seg.Sweep / 2, Ink, LabelFontSize,
      Sin(Seg.StartAngle + Seg.Sweep / 2) > 0);
  end;
end;

procedure TRingsChart.Paint;
var
  R: TRect;
  I: Integer;
  Seg: TRingSegment;
begin
  R := ClientRect;
  if FStaticLayer = nil then
    Exit;
  FStaticLayer.Resize(R.Right - R.Left, R.Bottom - R.Top, BackingScaleFor(Self));
  if FRoot = nil then
  begin
    DrawBackground(Canvas, R);
    Canvas.Font.Color := SecondaryTextColor(clWindow);
    Canvas.Font.Size := 12;
    Canvas.TextOut(R.Left + 24, R.Top + 24, 'Rings appear after a scan.');
    Exit;
  end;
  if FLayout = nil then
    RebuildLayout;
  if FLayout = nil then
    Exit;
  ApplyEnvironmentHover;
  if Animating and (Length(FFrom) = FLayout.Segments.Count) then
  begin
    PaintMotion(R);
    Exit;
  end;
  if not FStaticLayer.Valid then
  begin
    FStaticLayer.BeginStatic;
    for I := 0 to FLayout.Segments.Count - 1 do
    begin
      Seg := TRingSegment(FLayout.Segments[I]);
      if Seg.Depth = 0 then
        FStaticLayer.FillDisk(FLayout.CenterX, FLayout.CenterY, Seg.OuterRadius,
          ColorFor(Seg.ColorPosition, Seg.Depth, False), ColorToRGB(clBtnShadow), 1)
      else
        FStaticLayer.FillSector(FLayout.CenterX, FLayout.CenterY,
          Seg.InnerRadius, Seg.OuterRadius, Seg.StartAngle,
          Seg.StartAngle + Seg.Sweep,
          ColorFor(Seg.ColorPosition, Seg.Depth, False), ColorToRGB(clBtnShadow), 1);
    end;
    FStaticLayer.EndStatic;
    FStaticLayer.Valid := True;
  end;
  FStaticLayer.DrawTo(Canvas);
  if FHoverPath <> '' then
    for I := 0 to FLayout.Segments.Count - 1 do
    begin
      Seg := TRingSegment(FLayout.Segments[I]);
      if Seg.Path = FHoverPath then
      begin
        FillAnnularSector(Canvas, FLayout.CenterX, FLayout.CenterY,
          Seg.InnerRadius, Seg.OuterRadius, Seg.StartAngle,
          Seg.StartAngle + Seg.Sweep,
          ColorFor(Seg.ColorPosition, Seg.Depth, True),
          ColorToRGB(clBtnShadow), 1);
        if Seg.HasHiddenChildren then
          StrokeContinuedEdge(Canvas, FLayout.CenterX, FLayout.CenterY,
            Seg.OuterRadius + 4, Seg.StartAngle,
            Seg.StartAngle + Seg.Sweep,
            ColorFor(Seg.ColorPosition, Seg.Depth, True), 3);
        Break;
      end;
    end;
  { Labels last, so the hover highlight never covers them. }
  for I := 0 to FLayout.Segments.Count - 1 do
  begin
    Seg := TRingSegment(FLayout.Segments[I]);
    DrawSegmentLabels(Canvas, Seg);
  end;
  if FHoverActive and (FHoverPath <> '') then
    for I := 0 to FLayout.Segments.Count - 1 do
    begin
      Seg := TRingSegment(FLayout.Segments[I]);
      if Seg.Path = FHoverPath then
      begin
        DrawChartHoverTip(Canvas, Seg.Name, Seg.Size, Seg.FractionOfRoot,
          FHoverX, FHoverY, ClientWidth, ClientHeight);
        Break;
      end;
    end;
end;

procedure TRingsChart.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Hit: TRingSegment;
  NewPath: string;
begin
  inherited;
  if FPressed and not FDragging and (ssLeft in Shift) and
    (Sqr(X - FPressX) + Sqr(Y - FPressY) >= 16) then
  begin
    { draggableSegment(at: startLocation): depth >= 1, a file or folder. }
    FDragging := True;
    if FLayout <> nil then
    begin
      Hit := DraggableSegmentAt(FPressX, FPressY);
      if (Hit <> nil) and Assigned(FOnDragSegment) then
        FOnDragSegment(Self, Hit);
    end;
    Exit;
  end;
  NewPath := '';
  if FLayout <> nil then
  begin
    Hit := FLayout.SegmentAt(X, Y);
    if Hit <> nil then
      NewPath := Hit.Path;
  end;
  if (NewPath <> FHoverPath) or (X <> FHoverX) or (Y <> FHoverY) then
  begin
    FHoverPath := NewPath;
    FHoverX := X;
    FHoverY := Y;
    FHoverActive := NewPath <> '';
    { Invalidate coalesces successive mouse events into the next GUI paint. }
    Invalidate;
  end;
end;

procedure TRingsChart.MouseLeave;
begin
  inherited;
  if FHoverPath <> '' then
  begin
    FHoverPath := '';
    FHoverActive := False;
    Invalidate;
  end;
end;

procedure TRingsChart.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FPressX := X;
    FPressY := Y;
    FPressed := True;
    FDragging := False;
  end;
end;

procedure TRingsChart.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button = mbLeft then
    FPressed := False;
end;

function TRingsChart.DraggableSegmentAt(X, Y: Integer): TRingSegment;
begin
  Result := nil;
  if FLayout = nil then
    Exit;
  Result := FLayout.SegmentAt(X, Y);
  if (Result <> nil) and not ((Result.Depth >= 1) and
    (Result.Kind in [ckDirectory, ckFile])) then
    Result := nil;
end;

procedure TRingsChart.DragFinished;
begin
  FPressed := False;
  FDragging := False;
end;

procedure TRingsChart.Click;
var
  P: TPoint;
  Hit: TRingSegment;
begin
  inherited Click;
  { A drag is not a click. }
  if (FLayout = nil) or FDragging then
    Exit;
  P := ScreenToClient(Mouse.CursorPos);
  Hit := FLayout.SegmentAt(P.X, P.Y);
  if Hit = nil then
    Exit;
  if Assigned(FOnSelect) then
    FOnSelect(Self, Hit.Path, Hit.Depth = 0);
end;

end.
