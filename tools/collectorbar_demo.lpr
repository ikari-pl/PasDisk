program collectorbar_demo;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Controls, Graphics, CollectorBarView, SysUtils;

var
  Form: TForm;
  Bar: TCollectorBarView;
  Items: TCollectorItems;
  State: string;
begin
  Application.Initialize;
  Form := TForm.Create(nil);
  Form.Caption := 'OpenDisk CollectorBar demo';
  Form.Width := 760; Form.Height := 620;
  Form.Color := clWindow;
  Bar := TCollectorBarView.Create(Form); Bar.Parent := Form; Bar.Align := alBottom;
  { CollectorBar.swift .padding(.horizontal, 12).padding(.bottom, 10) }
  Bar.BorderSpacing.Left := 12; Bar.BorderSpacing.Right := 12; Bar.BorderSpacing.Bottom := 10;
  State := GetEnvironmentVariable('OPENDISK_DEMO_STATE');
  SetLength(Items, 3);
  Items[0].Name := 'report.pdf'; Items[0].Path := '/tmp/report.pdf'; Items[0].Size := 420000;
  Items[1].Name := 'Build'; Items[1].Path := '/Users/ikari/src/OpenDisk-pascal'; Items[1].Size := 2400000; Items[1].IsDirectory := True;
  Items[2].Name := 'archive.zip'; Items[2].Path := '/tmp/archive.zip'; Items[2].Size := 8200000;
  if (State = 'items') or (State = 'hover') or (State = 'deleting') or
    (State = 'done') or (State = 'notice') then Bar.SetItems(Items);
  if State = 'hover' then Bar.SetListVisible(True);
  if State = 'targeted' then Bar.SetPhase(cbTargeted)
  else if State = 'rejecting' then Bar.SetPhase(cbRejecting, 'This item cannot be deleted')
  else if State = 'deleting' then
  begin
    Bar.SetPhase(cbDeleting);
    Bar.SetDeletionProgress('archive.zip', 4200000, 2, 3);
  end
  else if State = 'done' then
  begin
    Bar.SetPhase(cbDone);
    Bar.SetDoneResult(12000000, 1);
  end
  else if State = 'notice' then Bar.ShowNotice('“System” is protected by macOS and can’t be deleted')
  else if State = 'empty' then Bar.SetPhase(cbIdle)
  else Bar.SetPhase(cbIdle);
  Form.Show; Application.Run;
end.
