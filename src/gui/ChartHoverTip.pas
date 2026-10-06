unit ChartHoverTip;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math, GuiColors, DesignTokens;

procedure DrawChartHoverTip(ACanvas: TCanvas; const Name: string; Size: Int64;
  FractionOfRoot: Double; PointerX, PointerY, BoundsWidth, BoundsHeight: Integer);

implementation

uses
  Formatters, TextTrim;

{ S shortened in the middle until it fits Width on ACanvas's font. }
function FitMiddle(ACanvas: TCanvas; const S: string; Width: Integer): string;
var
  Keep: Integer;
begin
  Result := S;
  Keep := CodePointCount(S);
  while (ACanvas.TextWidth(Result) > Width) and (Keep > 1) do
  begin
    Dec(Keep);
    Result := TruncateMiddle(S, Keep);
  end;
end;

procedure DrawChartHoverTip(ACanvas: TCanvas; const Name: string; Size: Int64;
  FractionOfRoot: Double; PointerX, PointerY, BoundsWidth, BoundsHeight: Integer);
const
  PadX = 8;
  PadY = 5;
  PointerOffsetX = 14;
  PointerOffsetY = -28;
  MaxTextWidth = 280;
var
  Title, Detail: string;
  TitleW, DetailW, TitleH, DetailH: Integer;
  PillW, PillH, OriginX, OriginY: Integer;
  R: TRect;
  Fmt: TFormatSettings;
  MaxW: Integer;
begin
  { String(format: "%.1f"): POSIX digits, whatever the locale. }
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Detail := Format('%s · %.1f%%', [FormatFileSize(Size), FractionOfRoot * 100], Fmt);
  { min(280, bounds.width - padding * 2) }
  MaxW := Max(40, Min(MaxTextWidth, BoundsWidth - PadX * 2));
  ACanvas.Font.Name := '';
  ApplyTextStyle(ACanvas.Font, tsCaption); { ChartHoverTip.swift:15-17 }
  ACanvas.Font.Style := [fsBold];
  { Names are file names: shorten in the middle so the start and the
    extension stay visible, and never draw past the pill. }
  Title := FitMiddle(ACanvas, Name, MaxW);
  TitleW := ACanvas.TextWidth(Title);
  TitleH := ACanvas.TextHeight(Title);
  ACanvas.Font.Style := [];
  ApplyTextStyle(ACanvas.Font, tsCaption2); { ChartHoverTip.swift:20-24 }
  Detail := FitMiddle(ACanvas, Detail, MaxW);
  DetailW := ACanvas.TextWidth(Detail);
  DetailH := ACanvas.TextHeight(Detail);
  PillW := Max(TitleW, DetailW) + PadX * 2;
  PillH := TitleH + DetailH + 2 + PadY * 2;
  OriginX := PointerX + PointerOffsetX;
  OriginY := PointerY + PointerOffsetY - PillH div 2;
  if OriginX + PillW > BoundsWidth - 4 then
    OriginX := PointerX - PointerOffsetX - PillW;
  OriginX := Min(Max(OriginX, 4), Max(BoundsWidth - PillW - 4, 4));
  OriginY := Min(Max(OriginY, 4), Max(BoundsHeight - PillH - 4, 4));
  R := Rect(OriginX, OriginY, OriginX + PillW, OriginY + PillH);
  ACanvas.Brush.Style := bsSolid;
  { Swift's black.opacity(0.8), resolved against the current window surface. }
  ACanvas.Brush.Color := RGBToColor(
    Round(Red(ColorToRGB(clWindow)) * 0.2),
    Round(Green(ColorToRGB(clWindow)) * 0.2),
    Round(Blue(ColorToRGB(clWindow)) * 0.2));
  ACanvas.Pen.Style := psClear;
  ACanvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Color := RGBToColor(255, 255, 255);
  ACanvas.Font.Style := [fsBold];
  ACanvas.TextOut(R.Left + PadX, R.Top + PadY, Title);
  ACanvas.Font.Style := [];
  ACanvas.Font.Color := RGBToColor(217, 217, 217);
  ACanvas.TextOut(R.Left + PadX, R.Top + PadY + TitleH + 2, Detail);
  ACanvas.Pen.Style := psSolid;
end;

end.
