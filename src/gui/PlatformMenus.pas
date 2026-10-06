{ PlatformMenus — SF Symbol images on menu items, as SwiftUI's
  Label("…", systemImage:) shows them in menus. The image is a template,
  so it follows the menu's text colour in light, dark and highlighted
  rows. }

unit PlatformMenus;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Menus;

procedure SetMenuItemSymbol(Item: TMenuItem; const Symbol: string);

implementation

{$IFDEF DARWIN}
uses
  CocoaAll, Graphics, CocoaGDIObjects, PlatformImages;

{ LCL sets a menu item's native image from its Bitmap whenever it syncs
  the item, so the symbol goes in as the Bitmap: rendered at 32 px, shown
  at 16 pt, and marked as a template so the menu tints it (dark in light
  mode, light in dark mode and on the highlighted row). }
procedure SetMenuItemSymbol(Item: TMenuItem; const Symbol: string);
var
  Bmp: TBitmap;
  Image: NSImage;
  Size: NSSize;
begin
  Bmp := SystemSymbolBitmap(Symbol, 32, clBlack);
  if Bmp = nil then
    Exit;
  try
    Item.Bitmap := Bmp;
  finally
    Bmp.Free;
  end;
  if (Item.Bitmap = nil) or (Item.Bitmap.Handle = 0) then
    Exit;
  Image := TCocoaBitmap(Item.Bitmap.Handle).Image;
  if Image = nil then
    Exit;
  Image.setTemplate(True);
  Size.width := 16;
  Size.height := 16;
  Image.setSize(Size);
end;
{$ELSE}
procedure SetMenuItemSymbol(Item: TMenuItem; const Symbol: string);
begin
end;
{$ENDIF}

end.
