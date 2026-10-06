{ Motion — time-based animation values (portable, no OS code).

  The SwiftUI curves OpenDisk uses: .easeInOut (hover highlight 0.15 s,
  tints 0.15 s), .spring(duration: 0.3) (collector list and notice,
  counts, phases) and .snappy (deletion progress 0.25 s, list updates
  0.18 s). A value is a function of elapsed time, not of frames, so a
  dropped frame does not change the duration or the end state; changing
  the target mid-flight starts from where the value is now. }

unit Motion;

{$mode objfpc}{$H+}

interface

type
  TEasing = (eaLinear, eaEaseInOut, eaEaseOut, eaSpring, eaSnappy);

  { Eases T in [0, 1]; 0 -> 0 and 1 -> 1. }
function Ease(Easing: TEasing; T: Double): Double;

type
  { One animated number. Times are in milliseconds from any fixed clock. }
  TAnimatedValue = record
    FromValue: Double;
    ToValue: Double;
    StartMs: QWord;
    DurationMs: Integer;
    Easing: TEasing;
  end;

{ A value resting at Value. }
function AnimatedAt(Value: Double): TAnimatedValue;
{ The presentation value at NowMs. }
function ValueAt(const A: TAnimatedValue; NowMs: QWord): Double;
{ True once the value has reached its target. }
function AtRest(const A: TAnimatedValue; NowMs: QWord): Boolean;
{ Heads for Target from the current presentation value (no jump back to
  the old start); DurationMs <= 0 (Reduce Motion) lands immediately. A
  target that is already being approached is left as it is. }
procedure Retarget(var A: TAnimatedValue; Target: Double; NowMs: QWord;
  DurationMs: Integer; Easing: TEasing);

implementation

uses
  Math;

{ A critically damped spring normalised to reach 1 at T = 1 — SwiftUI's
  .spring(duration:) with no bounce settles the same way. Omega is the
  stiffness of the settling. }
function CriticalSpring(T, Omega: Double): Double;
var
  EndValue: Double;
begin
  EndValue := 1 - (1 + Omega) * Exp(-Omega);
  Result := (1 - (1 + Omega * T) * Exp(-Omega * T)) / EndValue;
end;

function Ease(Easing: TEasing; T: Double): Double;
begin
  if T <= 0 then
    Exit(0);
  if T >= 1 then
    Exit(1);
  case Easing of
    eaLinear:
      Result := T;
    eaEaseInOut:
      { The cubic ease-in-out CSS and Core Animation approximate. }
      if T < 0.5 then
        Result := 4 * T * T * T
      else
        Result := 1 - Power(-2 * T + 2, 3) / 2;
    eaEaseOut:
      Result := 1 - Power(1 - T, 3);
    eaSpring:
      Result := CriticalSpring(T, 7);
    eaSnappy:
      { Stiffer: most of the way there sooner. }
      Result := CriticalSpring(T, 9);
  else
    Result := T;
  end;
end;

function AnimatedAt(Value: Double): TAnimatedValue;
begin
  Result.FromValue := Value;
  Result.ToValue := Value;
  Result.StartMs := 0;
  Result.DurationMs := 0;
  Result.Easing := eaLinear;
end;

function ValueAt(const A: TAnimatedValue; NowMs: QWord): Double;
var
  T: Double;
begin
  if (A.DurationMs <= 0) or (NowMs >= A.StartMs + QWord(A.DurationMs)) then
    Exit(A.ToValue);
  if NowMs <= A.StartMs then
    Exit(A.FromValue);
  T := (NowMs - A.StartMs) / A.DurationMs;
  Result := A.FromValue + (A.ToValue - A.FromValue) * Ease(A.Easing, T);
end;

function AtRest(const A: TAnimatedValue; NowMs: QWord): Boolean;
begin
  Result := (A.DurationMs <= 0) or (NowMs >= A.StartMs + QWord(A.DurationMs));
end;

procedure Retarget(var A: TAnimatedValue; Target: Double; NowMs: QWord;
  DurationMs: Integer; Easing: TEasing);
begin
  if SameValue(A.ToValue, Target) then
    Exit;
  A.FromValue := ValueAt(A, NowMs);
  A.ToValue := Target;
  A.StartMs := NowMs;
  A.DurationMs := Max(0, DurationMs);
  A.Easing := Easing;
end;

end.
