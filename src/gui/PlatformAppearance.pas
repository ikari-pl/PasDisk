unit PlatformAppearance;

{$mode objfpc}{$H+}

interface

uses
  Classes, Themes;

procedure WatchAppearanceChanges(OnChange: TNotifyEvent);
procedure StopWatchingAppearance;

implementation

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
