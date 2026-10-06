unit DesignTokens;

{$mode objfpc}{$H+}

interface

uses
  Graphics;

type
  TTextStyle = (tsLargeTitle, tsTitle, tsTitle2, tsTitle3, tsHeadline,
    tsBody, tsCallout, tsSubheadline, tsFootnote, tsCaption, tsCaption2);
  TTextStyleMetrics = record
    Size: Integer;
    Semibold: Boolean;
  end;

function TextStyleMetrics(Style: TTextStyle): TTextStyleMetrics;
procedure ApplyTextStyle(Font: TFont; Style: TTextStyle);

const
  Space4 = 4;
  Space8 = 8;
  Space12 = 12;
  Space16 = 16;
  Space20 = 20;
  Space24 = 24;
  Space32 = 32;

implementation

function TextStyleMetrics(Style: TTextStyle): TTextStyleMetrics;
begin
  { Apple HIG Typography and AppKit preferredFont(forTextStyle:),
    https://developer.apple.com/design/human-interface-guidelines/typography
    (macOS 14/15 default Dynamic Type/AppKit point sizes). Checked
    against NSFont.preferredFont(forTextStyle:) on macOS 26: 26/22/17/15,
    headline 13 bold (weight 0.4), body 13, callout 12, subheadline 11,
    footnote/caption/caption2 10. }
  Result.Semibold := False;
  case Style of
    tsLargeTitle: Result.Size := 26;
    tsTitle: Result.Size := 22;
    tsTitle2: Result.Size := 17;
    tsTitle3: Result.Size := 15;
    tsHeadline: begin Result.Size := 13; Result.Semibold := True; end;
    tsBody: Result.Size := 13;
    tsCallout: Result.Size := 12;
    tsSubheadline: Result.Size := 11;
    tsFootnote: Result.Size := 10;
    tsCaption: Result.Size := 10;
    tsCaption2: Result.Size := 10;
  end;
end;

procedure ApplyTextStyle(Font: TFont; Style: TTextStyle);
var
  M: TTextStyleMetrics;
begin
  if Font = nil then Exit;
  M := TextStyleMetrics(Style);
  Font.Size := M.Size;
  if M.Semibold then Font.Style := Font.Style + [fsBold]
  else Font.Style := Font.Style - [fsBold];
end;

end.
