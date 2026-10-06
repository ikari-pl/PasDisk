{ GuiColors — concrete colours derived from LCL system colours. }

unit GuiColors;

{$mode objfpc}{$H+}

interface

uses
  Graphics;

{ Secondary text as a concrete colour: the label colour blended toward
  Background, like Cocoa secondaryLabelColor. Use it instead of clGrayText
  wherever a colour is resolved or drawn on a canvas: ColorToRGB(clGrayText)
  is black on the Cocoa widgetset. Recompute it after appearance changes. }
function SecondaryTextColor(Background: TColor): TColor;

implementation

function SecondaryTextColor(Background: TColor): TColor;
var
  Ink, Bg: TColor;
begin
  Ink := ColorToRGB(clWindowText);
  Bg := ColorToRGB(Background);
  Result := RGBToColor(
    (Red(Ink) * 55 + Red(Bg) * 45) div 100,
    (Green(Ink) * 55 + Green(Bg) * 45) div 100,
    (Blue(Ink) * 55 + Blue(Bg) * 45) div 100);
end;

end.
