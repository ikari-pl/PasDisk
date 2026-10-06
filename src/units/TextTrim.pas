{ TextTrim — shorten UTF-8 text without splitting characters. }

unit TextTrim;

{$mode objfpc}{$H+}

interface

{ Number of Unicode code points in the UTF-8 string S. }
function CodePointCount(const S: string): Integer;

{ S shortened to Keep code points plus one ellipsis (U+2026) in the middle:
  the head keeps the extra code point when Keep is odd. S itself when it
  has at most Keep code points. Never splits a UTF-8 sequence, so emoji and
  other characters outside the BMP survive intact. }
function TruncateMiddle(const S: string; Keep: Integer): string;

implementation

type
  TIntArray = array of Integer;

{ Byte length of the UTF-8 sequence starting with B (1 for stray bytes, so
  malformed input still advances). }
function SeqLen(B: Byte): Integer;
begin
  if B < $80 then
    Result := 1
  else if (B and $E0) = $C0 then
    Result := 2
  else if (B and $F0) = $E0 then
    Result := 3
  else if (B and $F8) = $F0 then
    Result := 4
  else
    Result := 1;
end;

{ Byte offsets (1-based) where each code point of S starts. }
function CodePointStarts(const S: string): TIntArray;
var
  I, N: Integer;
begin
  SetLength(Result, Length(S));
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    Result[N] := I;
    Inc(N);
    Inc(I, SeqLen(Byte(S[I])));
  end;
  SetLength(Result, N);
end;

function CodePointCount(const S: string): Integer;
begin
  Result := Length(CodePointStarts(S));
end;

function TruncateMiddle(const S: string; Keep: Integer): string;
const
  Ellipsis = #$E2#$80#$A6;
var
  Starts: TIntArray;
  Count, Head, Tail: Integer;
begin
  Starts := CodePointStarts(S);
  Count := Length(Starts);
  if (Keep < 0) or (Count <= Keep) then
    Exit(S);
  Head := (Keep + 1) div 2;
  Tail := Keep - Head;
  Result := Copy(S, 1, Starts[Head] - 1) + Ellipsis;
  if Tail > 0 then
    Result := Result + Copy(S, Starts[Count - Tail], MaxInt);
end;

end.
