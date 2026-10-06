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
{ The same blend for text in another colour, e.g. clHighlightText on a
  selected row's clHighlight. }
function SecondaryTextColor(Background, Ink: TColor): TColor;

implementation

function SecondaryTextColor(Background: TColor): TColor;
begin
  Result := SecondaryTextColor(Background, clWindowText);
end;

function SecondaryTextColor(Background, Ink: TColor): TColor;
var
  Bg: TColor;
begin
  Ink := ColorToRGB(Ink);
  Bg := ColorToRGB(Background);
  Result := RGBToColor(
    (Red(Ink) * 55 + Red(Bg) * 45) div 100,
    (Green(Ink) * 55 + Green(Bg) * 45) div 100,
    (Blue(Ink) * 55 + Blue(Bg) * 45) div 100);
end;

end.
