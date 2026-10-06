{ PlatformImages — system artwork: volume and folder icons, SF Symbols.

  Darwin: NSWorkspace iconForFile: (DeviceRow.swift shows this icon at
  36 x 36) and NSImage imageWithSystemSymbolName: (the symbols SwiftUI's
  Label / ContentUnavailableView use), reached through the Objective-C
  runtime rather than the Cocoa units, which trip an FPC 3.2.2 internal
  error here. Images are rendered at twice the drawn size into LCL bitmaps
  with alpha, so Retina displays get full detail. Elsewhere, or if a lookup
  fails: a neutral placeholder, or no symbol. }

unit PlatformImages;

{$mode objfpc}{$H+}

interface

uses
  Graphics, Types;

procedure DrawVolumeIcon(ACanvas: TCanvas; const Bounds: TRect; const Path: string);

{ Forget cached icons (call when the volume list is rebuilt, so unmounted
  volumes and failed lookups do not accumulate). }
procedure ClearVolumeIconCache;

{ SF Symbol Name (e.g. 'lock.slash') as a Px x Px bitmap in Color, the
  symbol fitted and centred; nil when unavailable. Caller owns it. }
function SystemSymbolBitmap(const Name: string; Px: Integer; Color: TColor): TBitmap;

implementation

uses
  SysUtils, Classes, Math, IntfGraphics, FPImage, GraphType
  {$IFDEF DARWIN}, MacOSAll{$ENDIF};

var
  { Path -> TBitmap (owned), nil object when the lookup failed. }
  IconCache: TStringList;

procedure DrawPlaceholder(ACanvas: TCanvas; const Bounds: TRect);
begin
  ACanvas.Brush.Color := ColorToRGB(clBtnShadow);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Pen.Style := psClear;
  ACanvas.RoundRect(Bounds.Left + 4, Bounds.Top + 6,
    Bounds.Right - 4, Bounds.Bottom - 6, 8, 8);
  ACanvas.Pen.Style := psSolid;
end;

{$IFDEF DARWIN}
procedure objc_msgSend; cdecl; external 'objc' name 'objc_msgSend';
function objc_getClass(Name: PAnsiChar): Pointer; cdecl; external 'objc';
function sel_registerName(Name: PAnsiChar): Pointer; cdecl; external 'objc';

type
  TMsgObj = function(Self, Op: Pointer): Pointer; cdecl;
  TMsgObjArg = function(Self, Op, Arg: Pointer): Pointer; cdecl;
  TMsgObjArg2 = function(Self, Op, Arg1, Arg2: Pointer): Pointer; cdecl;
  TMsgCGImage = function(Self, Op: Pointer; ProposedRect: CGRectPtr;
    Context, Hints: Pointer): CGImageRef; cdecl;

function CFStr(const S: string): CFStringRef;
begin
  Result := CFStringCreateWithCString(nil, PChar(S), kCFStringEncodingUTF8);
end;

{ An NSImage rendered into a Px x Px bitmap, fitted and centred. With
  Tint, every pixel takes Tint's colour and keeps its coverage (template
  images such as SF Symbols are black shapes on transparency). }
function NSImageToBitmap(Image: Pointer; Px: Integer; Tinted: Boolean;
  Tint: TColor): TBitmap;
var
  Proposed, Dest: CGRect;
  Source: CGImageRef;
  Space: CGColorSpaceRef;
  Ctx: CGContextRef;
  Buf: array of Byte;
  Intf: TLazIntfImage;
  X, Y, I: Integer;
  W, H, Scale: Double;
  Alpha: Byte;
  Col: TFPColor;
  RGB: TColor;

  function Unpremultiply(C: Byte): Word;
  begin
    if Alpha = 0 then
      Result := 0
    else
      Result := Word(Min(255, (Integer(C) * 255 + Alpha div 2) div Alpha)) * 257;
  end;

begin
  Result := nil;
  if Image = nil then
    Exit;
  Proposed := CGRectMake(0, 0, Px, Px);
  Source := TMsgCGImage(@objc_msgSend)(Image,
    sel_registerName('CGImageForProposedRect:context:hints:'), @Proposed, nil, nil);
  if Source = nil then
    Exit;
  W := CGImageGetWidth(Source);
  H := CGImageGetHeight(Source);
  if (W <= 0) or (H <= 0) then
    Exit;
  Scale := Min(Px / W, Px / H);
  Dest := CGRectMake((Px - W * Scale) / 2, (Px - H * Scale) / 2, W * Scale, H * Scale);
  SetLength(Buf, Px * Px * 4);
  FillChar(Buf[0], Length(Buf), 0);
  Space := CGColorSpaceCreateDeviceRGB;
  Ctx := CGBitmapContextCreate(@Buf[0], Px, Px, 8, Px * 4, Space,
    kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(Space);
  if Ctx = nil then
    Exit;
  CGContextSetInterpolationQuality(Ctx, kCGInterpolationHigh);
  CGContextDrawImage(Ctx, Dest, Source);
  CGContextRelease(Ctx);
  RGB := ColorToRGB(Tint);
  { Row 0 of a bitmap context's memory is the top of the image. }
  Intf := TLazIntfImage.Create(Px, Px, [riqfRGB, riqfAlpha]);
  try
    for Y := 0 to Px - 1 do
      for X := 0 to Px - 1 do
      begin
        I := (Y * Px + X) * 4;
        Alpha := Buf[I + 3];
        if Tinted then
        begin
          Col.Red := Word(Red(RGB)) * 257;
          Col.Green := Word(Green(RGB)) * 257;
          Col.Blue := Word(Blue(RGB)) * 257;
        end
        else
        begin
          Col.Red := Unpremultiply(Buf[I]);
          Col.Green := Unpremultiply(Buf[I + 1]);
          Col.Blue := Unpremultiply(Buf[I + 2]);
        end;
        Col.Alpha := Word(Alpha) * 257;
        Intf.Colors[X, Y] := Col;
      end;
    Result := TBitmap.Create;
    Result.LoadFromIntfImage(Intf);
  finally
    Intf.Free;
  end;
end;

{ NSWorkspace icon for Path rendered at Px x Px, or nil. }
function LoadIcon(const Path: string; Px: Integer): TBitmap;
var
  Workspace, Image, PathStr: Pointer;
begin
  Result := nil;
  Workspace := TMsgObj(@objc_msgSend)(objc_getClass('NSWorkspace'),
    sel_registerName('sharedWorkspace'));
  if Workspace = nil then
    Exit;
  { CFString is toll-free bridged with NSString. }
  PathStr := CFStr(Path);
  if PathStr = nil then
    Exit;
  try
    Image := TMsgObjArg(@objc_msgSend)(Workspace,
      sel_registerName('iconForFile:'), PathStr);
  finally
    CFRelease(PathStr);
  end;
  Result := NSImageToBitmap(Image, Px, False, clNone);
end;

function SystemSymbolBitmap(const Name: string; Px: Integer; Color: TColor): TBitmap;
var
  NameStr, Image: Pointer;
begin
  Result := nil;
  NameStr := CFStr(Name);
  if NameStr = nil then
    Exit;
  try
    { macOS 11+; nil for unknown names. }
    Image := TMsgObjArg2(@objc_msgSend)(objc_getClass('NSImage'),
      sel_registerName('imageWithSystemSymbolName:accessibilityDescription:'),
      NameStr, nil);
  finally
    CFRelease(NameStr);
  end;
  Result := NSImageToBitmap(Image, Px, True, Color);
end;
{$ELSE}
function SystemSymbolBitmap(const Name: string; Px: Integer; Color: TColor): TBitmap;
begin
  Result := nil;
end;
{$ENDIF}

procedure DrawVolumeIcon(ACanvas: TCanvas; const Bounds: TRect; const Path: string);
var
  Idx: Integer;
  Icon: TBitmap;
begin
  Icon := nil;
  {$IFDEF DARWIN}
  Idx := IconCache.IndexOf(Path);
  if Idx < 0 then
    Idx := IconCache.AddObject(Path,
      LoadIcon(Path, 2 * (Bounds.Right - Bounds.Left)));
  Icon := TBitmap(IconCache.Objects[Idx]);
  {$ENDIF}
  if Icon = nil then
  begin
    DrawPlaceholder(ACanvas, Bounds);
    Exit;
  end;
  ACanvas.StretchDraw(Bounds, Icon);
end;

procedure ClearVolumeIconCache;
begin
  IconCache.Clear;
end;

initialization
  IconCache := TStringList.Create;
  IconCache.OwnsObjects := True;
  IconCache.Sorted := True;

finalization
  IconCache.Free;

end.
