{ RingsSVG — SVG renderer over RingsLayout (Swift geometry, no freelancing). }

unit RingsSVG;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ChartItem, Formatters, RingsLayout;

function ChartToSVG(Root: TChartItem; SizePx: Integer = 720): string;
function ChartToHTML(Root: TChartItem; const Title, ScanPath: string;
  ListLines: TStrings): string;

implementation

function XmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ Port of ChartPalette.fill — hues + depth dimming }
function FillColor(ColorPosition: Double; Depth: Integer): string;
const
  Hues: array[0..5, 0..2] of Integer = (
    ($E0, $1B, $24),
    ($FF, $78, $00),
    ($F6, $D3, $2D),
    ($33, $D1, $7A),
    ($35, $84, $E4),
    ($91, $41, $AC)
  );
  BandWidth = 100.0 / 3.0;
var
  Clamped, T, Intensity: Double;
  Band: Integer;
  R, G, B: Integer;
begin
  if Depth = 0 then
    Exit('#d3d6d1');
  Clamped := ColorPosition;
  if not (Clamped = Clamped) then { NaN }
    Clamped := 0;
  if Clamped < 0 then
    Clamped := 0;
  if Clamped > 199.999 then
    Clamped := 199.999;
  Band := Trunc(Clamped / BandWidth) mod 6;
  T := (Clamped - Band * BandWidth) / BandWidth;
  R := Round(Hues[Band][0] + (Hues[(Band + 1) mod 6][0] - Hues[Band][0]) * T);
  G := Round(Hues[Band][1] + (Hues[(Band + 1) mod 6][1] - Hues[Band][1]) * T);
  B := Round(Hues[Band][2] + (Hues[(Band + 1) mod 6][2] - Hues[Band][2]) * T);
  Intensity := 1.0 - ((Depth - 1) * 0.3) / 5.0;
  R := Round(R * Intensity);
  G := Round(G * Intensity);
  B := Round(B * Intensity);
  if R < 0 then R := 0 else if R > 255 then R := 255;
  if G < 0 then G := 0 else if G > 255 then G := 255;
  if B < 0 then B := 0 else if B > 255 then B := 255;
  Result := '#' + IntToHex(R, 2) + IntToHex(G, 2) + IntToHex(B, 2);
end;

function ChartToSVG(Root: TChartItem; SizePx: Integer): string;
var
  Layout: TRingsLayout;
  Body: string;
  I: Integer;
  Seg: TRingSegment;
  Fill: string;
  A0, A1: Double;
begin
  Layout := TRingsLayout.Create(Root, SizePx, SizePx);
  try
    Body := '';
    for I := 0 to Layout.Segments.Count - 1 do
    begin
      Seg := TRingSegment(Layout.Segments[I]);
      Fill := FillColor(Seg.ColorPosition, Seg.Depth);
      if Seg.Depth = 0 then
      begin
        Body := Body + Format(
          '<circle cx="%.4f" cy="%.4f" r="%.4f" fill="%s" ' +
          'stroke="#000000" stroke-opacity="0.35" stroke-width="1"/>' + LineEnding,
          [Layout.CenterX, Layout.CenterY, Seg.OuterRadius, Fill]);
        Body := Body + Format(
          '<text x="%.4f" y="%.4f" text-anchor="middle" class="center-name">%s</text>' +
          LineEnding +
          '<text x="%.4f" y="%.4f" text-anchor="middle" class="center-size">%s</text>' +
          LineEnding,
          [Layout.CenterX, Layout.CenterY - 6, XmlEsc(Seg.Name),
           Layout.CenterX, Layout.CenterY + 14, XmlEsc(FormatFileSize(Seg.Size))]);
      end
      else
      begin
        A0 := Seg.StartAngle;
        A1 := Seg.StartAngle + Seg.Sweep;
        Body := Body + Format(
          '<path d="%s" fill="%s" stroke="#000000" stroke-opacity="0.35" stroke-width="1">' +
          '<title>%s — %s</title></path>' + LineEnding,
          [SectorPathSVG(Layout.CenterX, Layout.CenterY,
             Seg.InnerRadius, Seg.OuterRadius, A0, A1),
           Fill, XmlEsc(Seg.Name), XmlEsc(FormatFileSize(Seg.Size))]);
        if Seg.HasHiddenChildren then
          Body := Body + Format(
            '<path d="M %s A %.4f,%.4f 0 %d 1 %s" fill="none" stroke="%s" ' +
            'stroke-width="3" stroke-opacity="0.9"/>' + LineEnding,
            [Format('%.4f,%.4f', [
               Layout.CenterX + Cos(A0) * (Seg.OuterRadius + 4),
               Layout.CenterY + Sin(A0) * (Seg.OuterRadius + 4)]),
             Seg.OuterRadius + 4, Seg.OuterRadius + 4,
             Ord(Abs(Seg.Sweep) > Pi),
             Format('%.4f,%.4f', [
               Layout.CenterX + Cos(A1) * (Seg.OuterRadius + 4),
               Layout.CenterY + Sin(A1) * (Seg.OuterRadius + 4)]),
             Fill]);
      end;
    end;
    Result := Format(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" ' +
      'role="img" aria-label="Disk usage rings">' + LineEnding +
      '<rect width="100%%" height="100%%" fill="#f3f0ec"/>' + LineEnding +
      '%s</svg>',
      [SizePx, SizePx, Body]);
  finally
    Layout.Free;
  end;
end;

function ChartToHTML(Root: TChartItem; const Title, ScanPath: string;
  ListLines: TStrings): string;
var
  Rows: string;
  I: Integer;
begin
  Rows := '';
  if ListLines <> nil then
    for I := 0 to ListLines.Count - 1 do
      Rows := Rows + '<li><code>' + XmlEsc(ListLines[I]) + '</code></li>' + LineEnding;
  Result :=
    '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>' +
    '<meta name="viewport" content="width=device-width, initial-scale=1"/>' +
    '<title>' + XmlEsc(Title) + ' — PasDisk</title>' +
    '<style>' +
    ':root{--ink:#201814;--muted:#665e58;--panel:#fbfaf8;--rule:#d8dee6}' +
    '*{box-sizing:border-box}' +
    'body{margin:0;font-family:"Iowan Old Style",Palatino,Georgia,serif;' +
    'background:#f3f0ec;color:var(--ink);min-height:100vh}' +
    'header{padding:28px 36px 8px;max-width:1200px;margin:0 auto}' +
    'h1{font-size:2.4rem;letter-spacing:-0.03em;margin:0;font-weight:700}' +
    '.sub{color:var(--muted);margin-top:6px;font-size:1.05rem}' +
    'main{display:grid;grid-template-columns:minmax(280px,1fr) minmax(420px,1.2fr);' +
    'gap:28px;padding:12px 36px 48px;max-width:1200px;margin:0 auto}' +
    '@media(max-width:900px){main{grid-template-columns:1fr}}' +
    '.panel{background:var(--panel);border:1px solid var(--rule);border-radius:18px;' +
    'padding:18px 20px}' +
    '.panel h2{margin:0 0 12px;font-size:0.85rem;text-transform:uppercase;' +
    'letter-spacing:0.12em;color:var(--muted)}' +
    'ol{margin:0;padding:0;list-style:none;max-height:70vh;overflow:auto}' +
    'li{padding:8px 4px;border-bottom:1px solid #eee6de;font-family:ui-monospace,Menlo,monospace;font-size:0.92rem}' +
    '.chart{display:flex;align-items:center;justify-content:center}' +
    'svg{width:min(100%,720px);height:auto}' +
    '.center-name{font:700 15px "Iowan Old Style",Palatino,serif;fill:var(--ink)}' +
    '.center-size{font:12px ui-monospace,Menlo,monospace;fill:var(--muted)}' +
    '</style></head><body>' +
    '<header><h1>PasDisk</h1>' +
    '<p class="sub">' + XmlEsc(ScanPath) + ' · ' +
    XmlEsc(FormatFileSize(Root.Size)) + '</p></header>' +
    '<main><section class="panel"><h2>Largest first</h2><ol>' + Rows +
    '</ol></section>' +
    '<section class="panel chart">' + ChartToSVG(Root, 720) + '</section></main>' +
    '</body></html>';
end;

end.
