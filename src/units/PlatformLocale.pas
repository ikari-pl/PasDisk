{ PlatformLocale — the user's number separators.

  macOS: the current CFLocale (System Settings > Language & Region), which
  is what ByteCountFormatter uses in the Swift app. Elsewhere: FPC's
  DefaultFormatSettings. }

unit PlatformLocale;

{$mode objfpc}{$H+}

interface

{ Decimal and grouping separators of the user's locale, as UTF-8. }
procedure NumberSeparators(out Decimal, Grouping: string);

implementation

uses
  SysUtils
  {$IFDEF DARWIN}, MacOSAll{$ENDIF};

{$IFDEF DARWIN}
function CFStringToUTF8(S: CFStringRef): string;
var
  Buf: array[0..63] of AnsiChar;
begin
  Result := '';
  if (S <> nil) and CFStringGetCString(S, @Buf[0], SizeOf(Buf),
    kCFStringEncodingUTF8) then
    Result := StrPas(@Buf[0]);
end;

procedure NumberSeparators(out Decimal, Grouping: string);
var
  Loc: CFLocaleRef;
begin
  Decimal := '.';
  Grouping := ',';
  Loc := CFLocaleCopyCurrent;
  if Loc = nil then
    Exit;
  try
    Decimal := CFStringToUTF8(CFStringRef(CFLocaleGetValue(Loc, kCFLocaleDecimalSeparator)));
    Grouping := CFStringToUTF8(CFStringRef(CFLocaleGetValue(Loc, kCFLocaleGroupingSeparator)));
    if Decimal = '' then
      Decimal := '.';
  finally
    CFRelease(Loc);
  end;
end;
{$ELSE}
procedure NumberSeparators(out Decimal, Grouping: string);
begin
  Decimal := DefaultFormatSettings.DecimalSeparator;
  Grouping := DefaultFormatSettings.ThousandSeparator;
end;
{$ENDIF}

end.
