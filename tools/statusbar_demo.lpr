program statusbar_demo;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Controls, ScanStatusBar, SysUtils;

var
  Form: TForm;
  Bar: TScanStatusBar;
  State: string;
begin
  Application.Initialize;
  Form := TForm.Create(nil);
  Form.Caption := 'ScanStatusBar demo';
  Form.Width := 760;
  Form.Height := 100;
  Bar := TScanStatusBar.Create(Form);
  Bar.Parent := Form;
  Bar.Align := alBottom;
  State := GetEnvironmentVariable('OPENDISK_DEMO_STATE');
  if State = 'finished' then
  begin
    Bar.SetTotals(84900000, 42);
    Bar.SetFinished(84900000, 42, 12.4);
  end
  else if State = 'checking-changes' then
  begin
    Bar.SetTotals(84900000, 42);
    Bar.SetScanning(0, 0, sspCheckingChanges, -1, Now - 2 / 86400);
  end
  else if State = 'capacity' then
  begin
    Bar.SetTotals(84900000, 42);
    Bar.SetFinished(84900000, 42, 12.4);
    Bar.SetVolumeCapacity(1000000000000, 640000000000, 16000000000);
  end
  else
  begin
    Bar.SetTotals(84900000, 42);
    Bar.SetScanning(42500000, 18, sspScanning, 0.5, Now - 2 / 86400);
  end;
  Form.Show;
  Application.Run;
end.
