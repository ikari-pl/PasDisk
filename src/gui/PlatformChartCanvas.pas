unit PlatformChartCanvas;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, Graphics, Math, Controls
{$IFDEF DARWIN}, MacOSAll{$ENDIF};

type
  TChartCanvasCache = class
  private
    FBitmap: TBitmap;
    FValid: Boolean;
    FWidth, FHeight: Integer;
    FScale: Double;
{$IFDEF DARWIN}
    FContext: Pointer;
    FImage: Pointer;
    FColorSpace: Pointer;
{$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
    procedure Invalidate;
    procedure Resize(AWidth, AHeight: Integer; AScale: Double);
    procedure BeginStatic;
    procedure EndStatic;
    procedure FillSector(CX, CY, InnerR, OuterR, A0, A1: Double;
      FillColor, BorderColor: TColor; BorderWidth: Double);
    procedure FillDisk(CX, CY, Radius: Double; FillColor, BorderColor: TColor;
      BorderWidth: Double);
    procedure DrawTo(ACanvas: TCanvas);
    property Valid: Boolean read FValid write FValid;
  end;

{ Device pixels per point of the window showing Control (NSWindow
  backingScaleFactor; the main screen's before the control is in a
  window); 1 off macOS. }
function BackingScaleFor(Control: TWinControl): Double;

procedure FillAnnularSector(ACanvas: TCanvas; CX, CY, InnerR, OuterR,
  A0, A1: Double; FillColor, BorderColor: TColor; BorderWidth: Double);
procedure FillAnnularSectorFallback(ACanvas: TCanvas; CX, CY, InnerR, OuterR,
  A0, A1: Double; FillColor, BorderColor: TColor; BorderWidth: Double);
procedure StrokeContinuedEdge(ACanvas: TCanvas; CX, CY, Radius, A0, A1: Double;
  Color: TColor; Width: Double);

implementation

{$IFDEF DARWIN}
uses CocoaGDIObjects;

procedure objc_msgSend; cdecl; external 'objc' name 'objc_msgSend';
function objc_getClass(Name: PAnsiChar): Pointer; cdecl; external 'objc';
function sel_registerName(Name: PAnsiChar): Pointer; cdecl; external 'objc';

type
  TMsgObj = function(Self, Op: Pointer): Pointer; cdecl;
  TMsgDouble = function(Self, Op: Pointer): Double; cdecl;

function BackingScaleFor(Control: TWinControl): Double;
var
  Owner: Pointer;
begin
  Result := 0;
  Owner := nil;
  if (Control <> nil) and Control.HandleAllocated then
    Owner := TMsgObj(@objc_msgSend)(Pointer(Control.Handle), sel_registerName('window'));
  if Owner = nil then
    Owner := TMsgObj(@objc_msgSend)(objc_getClass('NSScreen'), sel_registerName('mainScreen'));
  if Owner <> nil then
    Result := TMsgDouble(@objc_msgSend)(Owner, sel_registerName('backingScaleFactor'));
  if Result < 1 then
    Result := 1;
end;

{ The CGContext behind an LCL canvas (its Handle is a TCocoaContext). }
function CanvasCGContext(ACanvas: TCanvas): CGContextRef;
begin
  Result := nil;
  if (ACanvas <> nil) and (ACanvas.Handle <> 0) then
    Result := TCocoaContext(ACanvas.Handle).CGContext;
end;
{$ELSE}
function BackingScaleFor(Control: TWinControl): Double;
begin
  Result := 1;
end;
{$ENDIF}

constructor TChartCanvasCache.Create;
begin
  inherited Create;
  FBitmap := TBitmap.Create;
  FValid := False;
  FWidth := 0;
  FHeight := 0;
  FScale := 1;
{$IFDEF DARWIN}
  FContext := nil;
  FImage := nil;
  FColorSpace := nil;
{$ENDIF}
end;

destructor TChartCanvasCache.Destroy;
begin
{$IFDEF DARWIN}
  if FImage <> nil then CGImageRelease(CGImageRef(FImage));
  if FContext <> nil then CGContextRelease(CGContextRef(FContext));
  if FColorSpace <> nil then CGColorSpaceRelease(CGColorSpaceRef(FColorSpace));
{$ENDIF}
  FBitmap.Free;
  inherited Destroy;
end;

procedure TChartCanvasCache.Invalidate;
begin
  FValid := False;
end;

procedure TChartCanvasCache.Resize(AWidth, AHeight: Integer; AScale: Double);
begin
  if (FWidth <> AWidth) or (FHeight <> AHeight) or (Abs(FScale - AScale) > 0.001) then
  begin
    FWidth := AWidth;
    FHeight := AHeight;
    FScale := Max(1, AScale);
{$IFDEF DARWIN}
    if FImage <> nil then CGImageRelease(CGImageRef(FImage));
    if FContext <> nil then CGContextRelease(CGContextRef(FContext));
    if FColorSpace <> nil then CGColorSpaceRelease(CGColorSpaceRef(FColorSpace));
    FImage := nil;
    FContext := nil;
    FColorSpace := Pointer(CGColorSpaceCreateDeviceRGB);
    FContext := Pointer(CGBitmapContextCreate(nil, Round(AWidth * FScale),
      Round(AHeight * FScale), 8, Round(AWidth * FScale) * 4,
      CGColorSpaceRef(FColorSpace), kCGImageAlphaPremultipliedLast));
{$ELSE}
    FBitmap.SetSize(Max(1, AWidth), Max(1, AHeight));
{$ENDIF}
    FValid := False;
  end;
end;

procedure TChartCanvasCache.BeginStatic;
begin
{$IFDEF DARWIN}
  if FContext <> nil then
  begin
    CGContextSaveGState(CGContextRef(FContext));
    { Y-down logical coordinates like LCL: the translation comes before the
      scale, so it is in device pixels (the bitmap is FHeight * FScale
      tall). The raster is then upright; DrawTo flips once for the
      flipped view. }
    CGContextTranslateCTM(CGContextRef(FContext), 0, FHeight * FScale);
    CGContextScaleCTM(CGContextRef(FContext), FScale, -FScale);
    CGContextSetAllowsAntialiasing(CGContextRef(FContext), 1);
    CGContextSetRGBFillColor(CGContextRef(FContext), 1, 1, 1, 0);
    CGContextClearRect(CGContextRef(FContext), CGRectMake(0, 0, FWidth, FHeight));
  end;
{$ELSE}
  FBitmap.Canvas.Brush.Style := bsSolid;
{$ENDIF}
end;

procedure TChartCanvasCache.EndStatic;
begin
{$IFDEF DARWIN}
  if FContext <> nil then
  begin
    CGContextRestoreGState(CGContextRef(FContext));
    if FImage <> nil then CGImageRelease(CGImageRef(FImage));
    FImage := Pointer(CGBitmapContextCreateImage(CGContextRef(FContext)));
  end;
{$ENDIF}
end;

procedure TChartCanvasCache.FillSector(CX, CY, InnerR, OuterR, A0, A1: Double;
  FillColor, BorderColor: TColor; BorderWidth: Double);
begin
{$IFDEF DARWIN}
  if FContext <> nil then
  begin
    CGContextBeginPath(CGContextRef(FContext));
    CGContextMoveToPoint(CGContextRef(FContext), CX + Cos(A0) * InnerR, CY + Sin(A0) * InnerR);
    CGContextAddLineToPoint(CGContextRef(FContext), CX + Cos(A0) * OuterR, CY + Sin(A0) * OuterR);
    CGContextAddArc(CGContextRef(FContext), CX, CY, OuterR, A0, A1, 0);
    CGContextAddLineToPoint(CGContextRef(FContext), CX + Cos(A1) * InnerR, CY + Sin(A1) * InnerR);
    CGContextAddArc(CGContextRef(FContext), CX, CY, InnerR, A1, A0, 1);
    CGContextClosePath(CGContextRef(FContext));
    CGContextSetRGBFillColor(CGContextRef(FContext), Red(ColorToRGB(FillColor)) / 255,
      Green(ColorToRGB(FillColor)) / 255, Blue(ColorToRGB(FillColor)) / 255, 1);
    CGContextSetRGBStrokeColor(CGContextRef(FContext), Red(ColorToRGB(BorderColor)) / 255,
      Green(ColorToRGB(BorderColor)) / 255, Blue(ColorToRGB(BorderColor)) / 255, 1);
    CGContextSetLineWidth(CGContextRef(FContext), BorderWidth);
    CGContextDrawPath(CGContextRef(FContext), kCGPathFillStroke);
  end;
{$ELSE}
  FillAnnularSectorFallback(FBitmap.Canvas, CX, CY, InnerR, OuterR, A0, A1,
    FillColor, BorderColor, BorderWidth);
{$ENDIF}
end;

procedure TChartCanvasCache.FillDisk(CX, CY, Radius: Double; FillColor,
  BorderColor: TColor; BorderWidth: Double);
begin
{$IFDEF DARWIN}
  if FContext <> nil then
  begin
    CGContextBeginPath(FContext);
    CGContextAddEllipseInRect(FContext, CGRectMake(CX - Radius, CY - Radius,
      Radius * 2, Radius * 2));
    CGContextSetRGBFillColor(FContext, Red(ColorToRGB(FillColor)) / 255,
      Green(ColorToRGB(FillColor)) / 255, Blue(ColorToRGB(FillColor)) / 255, 1);
    CGContextSetRGBStrokeColor(FContext, Red(ColorToRGB(BorderColor)) / 255,
      Green(ColorToRGB(BorderColor)) / 255, Blue(ColorToRGB(BorderColor)) / 255, 1);
    CGContextSetLineWidth(FContext, BorderWidth);
    CGContextDrawPath(FContext, kCGPathFillStroke);
  end;
{$ELSE}
  FBitmap.Canvas.Brush.Color := FillColor;
  FBitmap.Canvas.Brush.Style := bsSolid;
  FBitmap.Canvas.Pen.Color := BorderColor;
  FBitmap.Canvas.Pen.Width := Round(BorderWidth);
  FBitmap.Canvas.Ellipse(Round(CX - Radius), Round(CY - Radius),
    Round(CX + Radius), Round(CY + Radius));
{$ENDIF}
end;

procedure TChartCanvasCache.DrawTo(ACanvas: TCanvas);
{$IFDEF DARWIN}
var
  Ctx: CGContextRef;
{$ENDIF}
begin
  if not FValid then Exit;
{$IFDEF DARWIN}
  Ctx := CanvasCGContext(ACanvas);
  if (Ctx <> nil) and (FImage <> nil) then
  begin
    CGContextSaveGState(Ctx);
    CGContextSetInterpolationQuality(Ctx, kCGInterpolationNone);
    CGContextTranslateCTM(Ctx, 0, FHeight);
    CGContextScaleCTM(Ctx, 1, -1);
    CGContextDrawImage(Ctx, CGRectMake(0, 0, FWidth, FHeight), FImage);
    CGContextRestoreGState(Ctx);
  end;
{$ELSE}
  ACanvas.Draw(0, 0, FBitmap);
{$ENDIF}
end;

{$IFDEF DARWIN}
procedure FillAnnularSector(ACanvas: TCanvas; CX, CY, InnerR, OuterR,
  A0, A1: Double; FillColor, BorderColor: TColor; BorderWidth: Double);
var
  Ctx: CGContextRef;
  FillRGB, BorderRGB: TColor;
begin
  Ctx := CanvasCGContext(ACanvas);
  if Ctx = nil then Exit;
  FillRGB := ColorToRGB(FillColor);
  BorderRGB := ColorToRGB(BorderColor);
  CGContextSaveGState(Ctx);
  CGContextSetAllowsAntialiasing(Ctx, 1);
  CGContextBeginPath(Ctx);
  CGContextMoveToPoint(Ctx, CX + Cos(A0) * InnerR, CY + Sin(A0) * InnerR);
  CGContextAddLineToPoint(Ctx, CX + Cos(A0) * OuterR, CY + Sin(A0) * OuterR);
  CGContextAddArc(Ctx, CX, CY, OuterR, A0, A1, 0);
  CGContextAddLineToPoint(Ctx, CX + Cos(A1) * InnerR, CY + Sin(A1) * InnerR);
  CGContextAddArc(Ctx, CX, CY, InnerR, A1, A0, 1);
  CGContextClosePath(Ctx);
  CGContextSetRGBFillColor(Ctx, Red(FillRGB) / 255, Green(FillRGB) / 255,
    Blue(FillRGB) / 255, 1);
  CGContextSetRGBStrokeColor(Ctx, Red(BorderRGB) / 255, Green(BorderRGB) / 255,
    Blue(BorderRGB) / 255, 1);
  CGContextSetLineWidth(Ctx, BorderWidth);
  CGContextDrawPath(Ctx, kCGPathFillStroke);
  CGContextRestoreGState(Ctx);
end;

procedure StrokeContinuedEdge(ACanvas: TCanvas; CX, CY, Radius, A0, A1: Double;
  Color: TColor; Width: Double);
var
  Ctx: CGContextRef;
begin
  Ctx := CanvasCGContext(ACanvas);
  if Ctx = nil then Exit;
  CGContextSaveGState(Ctx);
  CGContextSetAllowsAntialiasing(Ctx, 1);
  CGContextBeginPath(Ctx);
  CGContextAddArc(Ctx, CX, CY, Radius, A0, A1, 0);
  Color := ColorToRGB(Color);
  CGContextSetRGBStrokeColor(Ctx, Red(Color) / 255, Green(Color) / 255,
    Blue(Color) / 255, 1);
  CGContextSetLineWidth(Ctx, Width);
  CGContextStrokePath(Ctx);
  CGContextRestoreGState(Ctx);
end;

procedure FillAnnularSectorFallback(ACanvas: TCanvas; CX, CY, InnerR, OuterR,
  A0, A1: Double; FillColor, BorderColor: TColor; BorderWidth: Double);
var
  Pts: array of TPoint;
  Steps, I: Integer;
  A: Double;
begin
  Steps := Max(8, Round(Abs(A1 - A0) / (Pi / 64)));
  SetLength(Pts, (Steps + 1) * 2);
  for I := 0 to Steps do
  begin
    A := A0 + (A1 - A0) * I / Steps;
    Pts[I].X := Round(CX + Cos(A) * OuterR);
    Pts[I].Y := Round(CY + Sin(A) * OuterR);
    A := A1 - (A1 - A0) * I / Steps;
    Pts[Steps + 1 + I].X := Round(CX + Cos(A) * InnerR);
    Pts[Steps + 1 + I].Y := Round(CY + Sin(A) * InnerR);
  end;
  ACanvas.Brush.Color := FillColor;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Pen.Color := BorderColor;
  ACanvas.Pen.Width := Round(BorderWidth);
  ACanvas.Polygon(Pts);
end;
{$ELSE}
procedure FillAnnularSector(ACanvas: TCanvas; CX, CY, InnerR, OuterR,
  A0, A1: Double; FillColor, BorderColor: TColor; BorderWidth: Double);
var
  Pts: array of TPoint;
  Steps, I: Integer;
  A: Double;
begin
  Steps := Max(8, Round(Abs(A1 - A0) / (Pi / 64)));
  SetLength(Pts, (Steps + 1) * 2);
  for I := 0 to Steps do
  begin
    A := A0 + (A1 - A0) * I / Steps;
    Pts[I] := Point(Round(CX + Cos(A) * OuterR), Round(CY + Sin(A) * OuterR));
    Pts[Steps + 1 + I] := Point(Round(CX + Cos(A1 - (A1 - A0) * I / Steps) * InnerR),
      Round(CY + Sin(A1 - (A1 - A0) * I / Steps) * InnerR));
  end;
  ACanvas.Brush.Color := FillColor;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Pen.Color := BorderColor;
  ACanvas.Pen.Width := Round(BorderWidth);
  ACanvas.Polygon(Pts);
end;

procedure FillAnnularSectorFallback(ACanvas: TCanvas; CX, CY, InnerR, OuterR,
  A0, A1: Double; FillColor, BorderColor: TColor; BorderWidth: Double);
begin
  FillAnnularSector(ACanvas, CX, CY, InnerR, OuterR, A0, A1,
    FillColor, BorderColor, BorderWidth);
end;

procedure StrokeContinuedEdge(ACanvas: TCanvas; CX, CY, Radius, A0, A1: Double;
  Color: TColor; Width: Double);
var
  Pts: array of TPoint;
  Steps, I: Integer;
  A: Double;
begin
  Steps := Max(8, Round(Abs(A1 - A0) / (Pi / 64)));
  SetLength(Pts, Steps + 1);
  for I := 0 to Steps do
  begin
    A := A0 + (A1 - A0) * I / Steps;
    Pts[I] := Point(Round(CX + Cos(A) * Radius), Round(CY + Sin(A) * Radius));
  end;
  ACanvas.Pen.Color := Color;
  ACanvas.Pen.Width := Round(Width);
  ACanvas.Polyline(Pts);
end;
{$ENDIF}

end.
