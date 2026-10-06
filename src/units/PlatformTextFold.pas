{ PlatformTextFold — case- and normalization-insensitive form of a name.

  Swift's SearchIndex folds with String.lowercased() (Unicode, not
  locale-specific) followed by precomposedStringWithCanonicalMapping (NFC),
  so a decomposed 'A' + U+0308 on disk matches a typed 'ä'.
  macOS: CFStringLowercase with no locale, then CFStringNormalize to form C.
  Elsewhere: the RTL's Unicode lower-casing (needs a widestring manager on
  Unix; plain ASCII otherwise) and no normalization. }

unit PlatformTextFold;

{$mode objfpc}{$H+}

interface

{ Lower-cased, NFC-composed UTF-8 of a UTF-8 string. }
function FoldText(const S: string): string;

implementation

uses
  SysUtils
  {$IFDEF DARWIN}, MacOSAll{$ENDIF};

{$IFDEF DARWIN}
function FoldText(const S: string): string;
var
  Src: CFStringRef;
  Mut: CFMutableStringRef;
  Range: CFRange;
  Used: CFIndex;
begin
  Result := S;
  if S = '' then
    Exit;
  Src := CFStringCreateWithBytes(nil, @S[1], Length(S), kCFStringEncodingUTF8, False);
  if Src = nil then
    Exit;
  Mut := CFStringCreateMutableCopy(nil, 0, Src);
  CFRelease(Src);
  if Mut = nil then
    Exit;
  try
    CFStringLowercase(Mut, nil);
    CFStringNormalize(Mut, kCFStringNormalizationFormC);
    Range.location := 0;
    Range.length := CFStringGetLength(Mut);
    Used := 0;
    CFStringGetBytes(Mut, Range, kCFStringEncodingUTF8, 0, False, nil, 0, Used);
    SetLength(Result, Used);
    if Used > 0 then
      CFStringGetBytes(Mut, Range, kCFStringEncodingUTF8, 0, False,
        @Result[1], Used, Used);
  finally
    CFRelease(Mut);
  end;
end;
{$ELSE}
function FoldText(const S: string): string;
begin
  Result := UTF8Encode(WideLowerCase(UTF8Decode(S)));
end;
{$ENDIF}

end.
