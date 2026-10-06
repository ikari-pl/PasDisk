unit PlatformAppearance;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, Themes, Graphics;

procedure WatchAppearanceChanges(OnChange: TNotifyEvent);
procedure StopWatchingAppearance;

{ The user's accent colour (NSColor.controlAccentColor), which native
  controls such as a linear ProgressView fill with; Fallback elsewhere. }
function AccentColor(Fallback: TColor): TColor;

implementation

{$IFDEF DARWIN}
uses
  CocoaAll;

type
  TMsgColor = function(Cls: id; Op: SEL): NSColor; cdecl;

function AccentColor(Fallback: TColor): TColor;
var
  C: NSColor;
begin
  Result := Fallback;
  if not NSObject(id(NSColor.classClass)).respondsToSelector(sel_registerName('controlAccentColor')) then
    Exit;
  C := TMsgColor(@objc_msgSend)(id(NSColor.classClass), sel_registerName('controlAccentColor'));
  if C = nil then
    Exit;
  C := C.colorUsingColorSpace(NSColorSpace.sRGBColorSpace);
  if C = nil then
    Exit;
  Result := RGBToColor(Round(C.redComponent * 255), Round(C.greenComponent * 255),
    Round(C.blueComponent * 255));
end;
{$ELSE}
function AccentColor(Fallback: TColor): TColor;
begin
  Result := Fallback;
end;
{$ENDIF}

type
  TAppearanceWatcher = class
    procedure ThemeServicesChanged(Sender: TObject);
  end;

var
  AppearanceWatcher: TAppearanceWatcher;
  AppearanceChangeHandler: TNotifyEvent;
  PreviousThemeChange: TNotifyEvent;
  AppearanceHookInstalled: Boolean;

procedure TAppearanceWatcher.ThemeServicesChanged(Sender: TObject);
begin
  try
    if Assigned(PreviousThemeChange) then
      PreviousThemeChange(Sender);
  finally
    if Assigned(AppearanceChangeHandler) then
      AppearanceChangeHandler(Sender);
  end;
end;

procedure WatchAppearanceChanges(OnChange: TNotifyEvent);
begin
{$IFDEF DARWIN}
  StopWatchingAppearance;
  if AppearanceWatcher = nil then
    AppearanceWatcher := TAppearanceWatcher.Create;
  PreviousThemeChange := ThemeServices.OnThemeChange;
  AppearanceChangeHandler := OnChange;
  ThemeServices.OnThemeChange := @AppearanceWatcher.ThemeServicesChanged;
  AppearanceHookInstalled := True;
{$ELSE}
  { Other widgetsets do not need this Cocoa-specific observer bridge. }
{$ENDIF}
end;

procedure StopWatchingAppearance;
begin
{$IFDEF DARWIN}
  if AppearanceHookInstalled and
    (ThemeServices.OnThemeChange = @AppearanceWatcher.ThemeServicesChanged) then
    ThemeServices.OnThemeChange := PreviousThemeChange;
  AppearanceChangeHandler := nil;
  PreviousThemeChange := nil;
  AppearanceHookInstalled := False;
{$ENDIF}
end;

finalization
{$IFDEF DARWIN}
  StopWatchingAppearance;
  AppearanceWatcher.Free;
{$ENDIF}

end.
