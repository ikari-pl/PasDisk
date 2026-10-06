program test_motion;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, Motion;

var
  Fail: Boolean = False;

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

procedure TestCurves;
var
  E: TEasing;
  I: Integer;
  Prev, V: Double;
  Monotonic, Ends: Boolean;
begin
  Monotonic := True;
  Ends := True;
  for E := Low(TEasing) to High(TEasing) do
  begin
    Ends := Ends and SameValue(Ease(E, 0), 0) and SameValue(Ease(E, 1), 1, 1e-9);
    Prev := 0;
    for I := 1 to 100 do
    begin
      V := Ease(E, I / 100);
      if V < Prev - 1e-12 then
        Monotonic := False;
      Prev := V;
    end;
  end;
  Expect(Ends, 'every curve runs from 0 to 1');
  Expect(Monotonic, 'no curve overshoots or turns back (no bounce)');
  Expect(SameValue(Ease(eaEaseInOut, 0.5), 0.5, 1e-9), 'ease-in-out is symmetric');
  Expect(Ease(eaSpring, 0.5) > 0.8, 'the spring has mostly arrived halfway through');
  Expect(Ease(eaSnappy, 0.3) > Ease(eaSpring, 0.3), 'snappy leads the spring');
end;

procedure TestValues;
var
  A: TAnimatedValue;
  Mid: Double;
begin
  A := AnimatedAt(0);
  Expect(AtRest(A, 1000) and SameValue(ValueAt(A, 1000), 0), 'a resting value');

  Retarget(A, 1, 1000, 150, eaEaseInOut);
  Expect(SameValue(ValueAt(A, 1000), 0), 'starts where it was');
  Expect(SameValue(ValueAt(A, 1075), 0.5, 1e-9), 'halfway in time is halfway (ease-in-out)');
  Expect(not AtRest(A, 1100), 'moving before its duration');
  Expect(AtRest(A, 1150) and SameValue(ValueAt(A, 1150), 1), 'lands on time');
  Expect(SameValue(ValueAt(A, 5000), 1), 'a late frame lands on the target, not past it');

  { Reversing mid-flight: no jump back to the old start. }
  A := AnimatedAt(0);
  Retarget(A, 1, 0, 150, eaEaseInOut);
  Mid := ValueAt(A, 100);
  Retarget(A, 0, 100, 150, eaEaseInOut);
  Expect(SameValue(ValueAt(A, 100), Mid), 'a reversal continues from the presentation value');
  Expect(SameValue(ValueAt(A, 250), 0), 'and ends at the new target');

  { Retargeting to the same target keeps the running animation. }
  A := AnimatedAt(0);
  Retarget(A, 1, 0, 300, eaSpring);
  Retarget(A, 1, 200, 300, eaSpring);
  Expect(A.StartMs = 0, 'the same target does not restart the animation');

  { Reduce Motion: zero duration lands at once. }
  A := AnimatedAt(0);
  Retarget(A, 1, 0, 0, eaSpring);
  Expect(AtRest(A, 0) and SameValue(ValueAt(A, 0), 1), 'zero duration lands immediately');
end;

begin
  TestCurves;
  TestValues;
  if Fail then
  begin
    WriteLn('test_motion: FAILED');
    Halt(1);
  end;
  WriteLn('test_motion: all passed');
end.
