{ PlatformPreferences round trip in a private domain. }

program test_preferences;

{$mode objfpc}{$H+}

uses
  SysUtils, PlatformPreferences;

var
  Failures: Integer;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('ok: ', Msg)
  else
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end;
end;

begin
  Failures := 0;
  SetPreferencesDomain('software.ikari.opendisk.tests');
  try
    RemovePreference('flag');
    Expect(GetBoolPreference('flag', True), 'missing key gives the default (True)');
    Expect(not GetBoolPreference('flag', False), 'missing key gives the default (False)');
    SetBoolPreference('flag', False);
    Expect(not GetBoolPreference('flag', True), 'stored False wins over the default');
    SetBoolPreference('flag', True);
    Expect(GetBoolPreference('flag', False), 'stored True wins over the default');
    RemovePreference('flag');
    Expect(GetBoolPreference('flag', True) and not GetBoolPreference('flag', False),
      'removed key falls back to the default');
  finally
    SetPreferencesDomain('');
  end;
  if Failures > 0 then
  begin
    WriteLn('test_preferences: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_preferences: all passed');
end.
