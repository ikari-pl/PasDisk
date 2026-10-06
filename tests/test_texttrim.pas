{ TextTrim.TruncateMiddle never splits a UTF-8 character. }

program test_texttrim;

{$mode objfpc}{$H+}

uses
  SysUtils, TextTrim;

var
  Fail: Boolean;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Fail := True;
  end
  else
    WriteLn('ok: ', Msg);
end;

{ True when S is well-formed UTF-8. }
function ValidUTF8(const S: string): Boolean;
var
  I, N, K: Integer;
  B: Byte;
begin
  I := 1;
  while I <= Length(S) do
  begin
    B := Byte(S[I]);
    if B < $80 then N := 1
    else if (B and $E0) = $C0 then N := 2
    else if (B and $F0) = $E0 then N := 3
    else if (B and $F8) = $F0 then N := 4
    else Exit(False);
    if I + N - 1 > Length(S) then
      Exit(False);
    for K := 1 to N - 1 do
      if (Byte(S[I + K]) and $C0) <> $80 then
        Exit(False);
    Inc(I, N);
  end;
  Result := True;
end;

const
  Ell = #$E2#$80#$A6;
  { 'Photos ' + party popper U+1F389 x3 + ' 2026' + family emoji (ZWJ
    sequence) + ' end' — four-byte sequences throughout. }
  Emoji = 'Photos '#$F0#$9F#$8E#$89#$F0#$9F#$8E#$89#$F0#$9F#$8E#$89' 2026 '+
    #$F0#$9F#$91#$A8#$E2#$80#$8D#$F0#$9F#$91#$A9' end';
  Accented = 'Zdj'#$C4#$99'cia '#$C5#$BC#$C3#$B3#$C5#$82'te';
var
  Keep: Integer;
  T: string;
  AllValid: Boolean;
begin
  Fail := False;
  Expect(CodePointCount('abc') = 3, 'ASCII code points');
  Expect(CodePointCount(Accented) = 13, 'two-byte characters count once');
  Expect(CodePointCount(#$F0#$9F#$8E#$89) = 1, 'a four-byte emoji counts once');
  Expect(TruncateMiddle('short', 10) = 'short', 'short text is unchanged');
  Expect(TruncateMiddle('abcdefghij', 4) = 'ab' + Ell + 'ij', 'head and tail around one ellipsis');
  Expect(TruncateMiddle('abcdefghij', 5) = 'abc' + Ell + 'ij', 'odd Keep favours the head');

  AllValid := True;
  for Keep := 0 to CodePointCount(Emoji) do
  begin
    T := TruncateMiddle(Emoji, Keep);
    if not ValidUTF8(T) then
    begin
      AllValid := False;
      WriteLn('  invalid at Keep=', Keep);
    end;
    if (Keep < CodePointCount(Emoji)) and (CodePointCount(T) <> Keep + 1) then
    begin
      AllValid := False;
      WriteLn('  wrong length at Keep=', Keep);
    end;
  end;
  Expect(AllValid, 'every truncation of an emoji name is valid UTF-8 of Keep+1 code points');

  AllValid := True;
  for Keep := 0 to CodePointCount(Accented) do
    AllValid := AllValid and ValidUTF8(TruncateMiddle(Accented, Keep));
  Expect(AllValid, 'every truncation of an accented name is valid UTF-8');

  if Fail then
    Halt(1);
  WriteLn('test_texttrim: all passed');
end.
