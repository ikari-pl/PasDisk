{ Volumes.ListVolumes follows DeviceMonitor.swift: system root once as
  "Computer", no second entry on the boot device, sane capacities.

  ListVolumes probes every mounted volume, network shares included, so the
  live sweep runs only with OPENDISK_LIVE_VOLUMES=1. By default the test
  touches the boot volume alone. }

program test_volumes;

{$mode objfpc}{$H+}

uses
  SysUtils, Volumes, PlatformVolumes;

var
  Fail: Boolean;
  Vols: TVolumeInfoArray;
  I, J, RootCount: Integer;
  Dev, BootDev, Other: QWord;
  Cap: TVolumeCapacity;
  Probe: TVolumeProbe;

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

begin
  Fail := False;

  Cap.TotalBytes := 100;
  Cap.FreeBytes := 30;
  Cap.AvailableForImportantUsage := 70;
  Expect(AvailableBytesOf(Cap) = 70, 'available includes purgeable (max of free, important)');
  Cap.AvailableForImportantUsage := -1;
  Expect(AvailableBytesOf(Cap) = 30, 'unknown important usage falls back to free');
  Cap.AvailableForImportantUsage := 500;
  Expect(AvailableBytesOf(Cap) = 100, 'available is capped at total');

  { Deterministic regression: /Volumes/Boot is a symlink to / (same device),
    hidden and unreadable mounts are dropped, nameless mounts use basename. }
  Probe.RootPath := '/';
  Probe.RootCapacity := Cap;
  Probe.HasRootCapacity := True;
  Probe.BootDevice := 1;
  Probe.HasBootDevice := True;
  SetLength(Probe.Mounts, 5);
  SetLength(Probe.Devices, 5);
  SetLength(Probe.Readable, 5);
  SetLength(Probe.Capacities, 5);
  SetLength(Probe.HasCapacity, 5);
  for I := 0 to 4 do
  begin
    Probe.Mounts[I].Browsable := True;
    Probe.Readable[I] := True;
    Probe.Capacities[I] := Cap;
    Probe.HasCapacity[I] := True;
  end;
  Probe.Mounts[0].Path := '/'; Probe.Mounts[0].Name := 'Powerhouse HD'; Probe.Devices[0] := 1;
  Probe.Mounts[1].Path := '/Volumes/Data'; Probe.Mounts[1].Name := ''; Probe.Devices[1] := 2;
  Probe.Mounts[2].Path := '/Volumes/Hidden'; Probe.Mounts[2].Name := 'Hidden';
  Probe.Devices[2] := 3; Probe.Mounts[2].Browsable := False;
  Probe.Mounts[3].Path := '/Volumes/Locked'; Probe.Mounts[3].Name := 'Locked';
  Probe.Devices[3] := 4; Probe.Readable[3] := False;
  Probe.Mounts[4].Path := '/Volumes/Boot'; Probe.Mounts[4].Name := 'Powerhouse HD'; Probe.Devices[4] := 1;
  Vols := SelectVolumes(Probe);
  Expect(Length(Vols) = 2, Format('injected probe keeps 2 volumes (got %d)', [Length(Vols)]));
  if Length(Vols) = 2 then
  begin
    Expect((Vols[0].Path = '/') and (Vols[0].Name = 'Computer'), 'root is Computer');
    Expect((Vols[1].Path = '/Volumes/Data') and (Vols[1].Name = 'Data'),
      'nameless mount named by basename; boot-device duplicates dropped');
  end;

  { Mounts come back sorted by path, whatever the OS order. }
  Probe.Mounts[1].Path := '/Volumes/Zeta'; Probe.Mounts[1].Name := 'Zeta';
  Probe.Mounts[3].Path := '/Volumes/Alpha'; Probe.Mounts[3].Name := 'Alpha';
  Probe.Readable[3] := True;
  Vols := SelectVolumes(Probe);
  Expect((Length(Vols) = 3) and (Vols[0].Name = 'Computer') and (Vols[1].Name = 'Alpha') and
    (Vols[2].Name = 'Zeta'), 'volumes sorted by mount path after Computer');

  Expect(DeviceOfPath(SystemRootPath, BootDev), 'boot device id readable');
  Expect(VolumeCapacityOf(SystemRootPath, Cap) and (Cap.TotalBytes > 0) and
    (Cap.FreeBytes <= Cap.TotalBytes), 'boot volume capacity is sane');

  if GetEnvironmentVariable('OPENDISK_LIVE_VOLUMES') <> '1' then
  begin
    WriteLn('skip: live ListVolumes sweep (set OPENDISK_LIVE_VOLUMES=1; ',
      'it touches network shares)');
    if Fail then
      Halt(1);
    WriteLn('test_volumes: all passed');
    Halt(0);
  end;

  Vols := ListVolumes;
  Expect(Length(Vols) > 0, 'at least one volume');
  RootCount := 0;
  for I := 0 to High(Vols) do
    if Vols[I].Path = SystemRootPath then
      Inc(RootCount);
  Expect(RootCount = 1, 'system root listed exactly once');
  Expect((Length(Vols) > 0) and (Vols[0].Path = SystemRootPath) and
    (Vols[0].Name = 'Computer'), 'system root is first and named Computer');

  for I := 1 to High(Vols) do
  begin
    Expect(DeviceOfPath(Vols[I].Path, Dev) and (Dev <> BootDev),
      Vols[I].Path + ' is not on the boot device');
    for J := I + 1 to High(Vols) do
      if DeviceOfPath(Vols[J].Path, Other) then
        Expect(Other <> Dev, Vols[I].Path + ' and ' + Vols[J].Path + ' are distinct devices');
  end;
  for I := 0 to High(Vols) do
    Expect((Vols[I].TotalBytes > 0) and (Vols[I].AvailableBytes <= Vols[I].TotalBytes),
      Vols[I].Name + ' has total > 0 and available <= total');

  if Fail then
    Halt(1);
  WriteLn('test_volumes: all passed');
end.
