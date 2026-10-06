{ OpenDisk Formatters — human-readable byte sizes.

  Port of OpenDisk Utilities/Formatters.swift ByteFormatter, which uses
  Foundation's ByteCountFormatter. Reproduced rules (checked against the
  real formatter, tests/data/bytecount_*.tsv): decimal units (1 KB = 1000
  bytes); 0 decimals for KB, 1 for MB, 2 for GB and TB; half-up rounding,
  after which a value reaching 1000 moves to the next unit; trailing zero
  decimals dropped; TB is the largest unit and groups thousands; 0 is
  'Zero bytes', 1 is '1 byte'. Separators follow the user's locale. }

unit Formatters;

{$mode objfpc}{$H+}

interface

{ ByteFormatter.formatFileSize: ByteCountFormatter, countStyle .file,
  units bytes..TB, with the user's locale separators. }
function FormatFileSize(Bytes: Int64): string;

{ ByteFormatter.formatDecimalNoFraction: GB/TB only, and the first '.' or
  ',' followed by digits removed, exactly as Swift's regex does (so a
  grouped TB value such as '2,000 TB' also loses its group: '2 TB'). }
function FormatDecimalNoFraction(Bytes: Int64): string;

{ DurationFormatter.scanDuration: 'Scanned in 850 ms' under a second,
  'Scanned in 12.4 seconds' under a minute, else 'Scanned in 3:07'.
  Like Swift's String(format:), digits are not localized. }
function FormatScanDuration(Seconds: Double): string;

{ The same with explicit separators (portable; used by the tests). }
function FormatFileSizeWith(Bytes: Int64; const DecimalSep, GroupSep: string): string;
function FormatDecimalNoFractionWith(Bytes: Int64;
  const DecimalSep, GroupSep: string): string;

implementation

uses
  SysUtils, PlatformLocale;

const
  UnitNames: array[1..4] of string = ('KB', 'MB', 'GB', 'TB');
  { ByteCountFormatter fraction digits per unit. }
  UnitDigits: array[1..4] of Integer = (0, 1, 2, 2);

function Pow10(N: Integer): QWord;
begin
  Result := 1;
  while N > 0 do
  begin
    Result := Result * 10;
    Dec(N);
  end;
end;

function Grouped(Whole: QWord; const GroupSep: string): string;
var
  Digits: string;
  I, Count: Integer;
begin
  Digits := IntToStr(Whole);
  Result := '';
  Count := 0;
  for I := Length(Digits) downto 1 do
  begin
    if (Count > 0) and (Count mod 3 = 0) then
      Result := GroupSep + Result;
    Result := Digits[I] + Result;
    Inc(Count);
  end;
end;

{ Abs(Bytes) rounded half-up to Digits decimals of 1000^Power: whole part
  and fraction digits, in exact integer arithmetic. }
procedure RoundToUnit(A: QWord; Power, Digits: Integer; out Whole, Frac: QWord);
var
  Step, Q, R: QWord;
begin
  Step := Pow10(3 * Power - Digits);
  Q := A div Step;
  R := A mod Step;
  if 2 * R >= Step then
    Inc(Q);
  Whole := Q div Pow10(Digits);
  Frac := Q mod Pow10(Digits);
end;

function FractionText(Frac: QWord; Digits: Integer; const DecimalSep: string): string;
begin
  Result := '';
  if Digits = 0 then
    Exit;
  Result := IntToStr(Frac);
  while Length(Result) < Digits do
    Result := '0' + Result;
  while (Result <> '') and (Result[Length(Result)] = '0') do
    SetLength(Result, Length(Result) - 1);
  if Result <> '' then
    Result := DecimalSep + Result;
end;

function Magnitude(Bytes: Int64; out Sign: string): QWord;
begin
  Sign := '';
  if Bytes < 0 then
  begin
    Sign := '-';
    Result := QWord(-(Bytes + 1)) + 1;
  end
  else
    Result := QWord(Bytes);
end;

function FormatFileSizeWith(Bytes: Int64; const DecimalSep, GroupSep: string): string;
var
  A, Whole, Frac: QWord;
  Sign: string;
  Power: Integer;
begin
  if Bytes = 0 then
    Exit('Zero bytes');
  A := Magnitude(Bytes, Sign);
  if A < 1000 then
  begin
    if A = 1 then
      Exit(Sign + '1 byte');
    Exit(Sign + IntToStr(A) + ' bytes');
  end;
  Power := 1;
  while (Power < 4) and (A >= Pow10(3 * (Power + 1))) do
    Inc(Power);
  repeat
    RoundToUnit(A, Power, UnitDigits[Power], Whole, Frac);
    if (Whole < 1000) or (Power = 4) then
      Break;
    Inc(Power);
  until False;
  Result := Sign + Grouped(Whole, GroupSep) +
    FractionText(Frac, UnitDigits[Power], DecimalSep) + ' ' + UnitNames[Power];
end;

function FormatDecimalNoFractionWith(Bytes: Int64;
  const DecimalSep, GroupSep: string): string;
var
  A, Whole, Frac: QWord;
  Sign: string;
  Power, I, J: Integer;
begin
  A := Magnitude(Bytes, Sign);
  Power := 3;
  RoundToUnit(A, Power, 2, Whole, Frac);
  if Whole >= 1000 then
  begin
    Power := 4;
    RoundToUnit(A, Power, 2, Whole, Frac);
  end;
  Result := Sign + Grouped(Whole, GroupSep) + FractionText(Frac, 2, DecimalSep) +
    ' ' + UnitNames[Power];
  { Swift: formatted.range(of: "[.,]\\d+") removed once. }
  for I := 1 to Length(Result) - 1 do
    if (Result[I] in ['.', ',']) and (Result[I + 1] in ['0'..'9']) then
    begin
      J := I + 1;
      while (J <= Length(Result)) and (Result[J] in ['0'..'9']) do
        Inc(J);
      Delete(Result, I, J - I);
      Break;
    end;
end;

function FormatScanDuration(Seconds: Double): string;
var
  Fmt: TFormatSettings;
  Minutes, Secs: Int64;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  if Seconds < 1 then
    Exit(Format('Scanned in %.0f ms', [Seconds * 1000], Fmt));
  if Seconds < 60 then
    Exit(Format('Scanned in %.1f seconds', [Seconds], Fmt));
  Minutes := Trunc(Seconds / 60);
  Secs := Trunc(Seconds - Minutes * 60);
  Result := Format('Scanned in %d:%.2d', [Minutes, Secs], Fmt);
end;

var
  { Read once at startup, before any thread formats a size. }
  LocaleDecimal, LocaleGroup: string;

function FormatFileSize(Bytes: Int64): string;
begin
  Result := FormatFileSizeWith(Bytes, LocaleDecimal, LocaleGroup);
end;

function FormatDecimalNoFraction(Bytes: Int64): string;
begin
  Result := FormatDecimalNoFractionWith(Bytes, LocaleDecimal, LocaleGroup);
end;

initialization
  NumberSeparators(LocaleDecimal, LocaleGroup);
end.
