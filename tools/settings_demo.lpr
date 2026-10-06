program settings_demo;

{ Shows the Settings window, or with OPENDISK_DEMO=prompt the startup
  alert (prompt preferences go to a test domain so nothing sticks). }

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, SysUtils, FullDiskAccessUI, PlatformPreferences;

begin
  Application.Initialize;
  if GetEnvironmentVariable('OPENDISK_DEMO') = 'prompt' then
  begin
    SetPreferencesDomain('software.ikari.opendisk.demo');
    PromptForFullDiskAccessAtStartup;
    Exit;
  end;
  ShowSettingsWindow;
  Application.Run;
end.
