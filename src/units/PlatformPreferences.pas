{ PlatformPreferences — small persistent user settings (Swift UserDefaults /
  @AppStorage).

  macOS: CFPreferences in the app's domain (software.ikari.opendisk, the
  bundle id), so the bundled app and a bare binary share them. Elsewhere:
  a key=value file in the user's configuration directory. }

unit PlatformPreferences;

{$mode objfpc}{$H+}

interface

function GetBoolPreference(const Key: string; Default: Boolean): Boolean;
procedure SetBoolPreference(const Key: string; Value: Boolean);
procedure RemovePreference(const Key: string);

{ Test seam: another domain (macOS) or file name stem (elsewhere); ''
  restores the app's. }
procedure SetPreferencesDomain(const Domain: string);

implementation

uses
  SysUtils, Classes
  {$IFDEF DARWIN}, MacOSAll{$ENDIF};

const
  AppDomain = 'software.ikari.opendisk';

var
  CurrentDomain: string = AppDomain;

procedure SetPreferencesDomain(const Domain: string);
begin
  if Domain = '' then
    CurrentDomain := AppDomain
  else
    CurrentDomain := Domain;
end;

{$IFDEF DARWIN}
function CFStr(const S: string): CFStringRef;
begin
  Result := CFStringCreateWithCString(nil, PChar(S), kCFStringEncodingUTF8);
end;

function GetBoolPreference(const Key: string; Default: Boolean): Boolean;
var
  K, D: CFStringRef;
  Valid: Boolean;
  V: Boolean;
begin
  Result := Default;
  K := CFStr(Key);
  D := CFStr(CurrentDomain);
  try
    Valid := False;
    V := CFPreferencesGetAppBooleanValue(K, D, Valid);
    if Valid then
      Result := V;
  finally
    CFRelease(K);
    CFRelease(D);
  end;
end;

procedure WriteValue(const Key: string; Value: CFPropertyListRef);
var
  K, D: CFStringRef;
begin
  K := CFStr(Key);
  D := CFStr(CurrentDomain);
  try
    CFPreferencesSetAppValue(K, Value, D);
    CFPreferencesAppSynchronize(D);
  finally
    CFRelease(K);
    CFRelease(D);
  end;
end;

procedure SetBoolPreference(const Key: string; Value: Boolean);
begin
  if Value then
    WriteValue(Key, kCFBooleanTrue)
  else
    WriteValue(Key, kCFBooleanFalse);
end;

procedure RemovePreference(const Key: string);
begin
  WriteValue(Key, nil);
end;
{$ELSE}
function PrefsFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + CurrentDomain + '.prefs';
end;

function Load: TStringList;
begin
  Result := TStringList.Create;
  if FileExists(PrefsFile) then
    Result.LoadFromFile(PrefsFile);
end;

procedure Save(L: TStringList);
begin
  ForceDirectories(ExtractFilePath(PrefsFile));
  L.SaveToFile(PrefsFile);
end;

function GetBoolPreference(const Key: string; Default: Boolean): Boolean;
var
  L: TStringList;
  V: string;
begin
  L := Load;
  try
    V := L.Values[Key];
    if V = '' then
      Result := Default
    else
      Result := V = '1';
  finally
    L.Free;
  end;
end;

procedure SetBoolPreference(const Key: string; Value: Boolean);
var
  L: TStringList;
begin
  L := Load;
  try
    if Value then
      L.Values[Key] := '1'
    else
      L.Values[Key] := '0';
    Save(L);
  finally
    L.Free;
  end;
end;

procedure RemovePreference(const Key: string);
var
  L: TStringList;
  I: Integer;
begin
  L := Load;
  try
    I := L.IndexOfName(Key);
    if I >= 0 then
    begin
      L.Delete(I);
      Save(L);
    end;
  finally
    L.Free;
  end;
end;
{$ENDIF}

end.
