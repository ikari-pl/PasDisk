{ Volumes — mounted volumes suitable as scan roots.

  Port of OpenDisk DeviceMonitor.swift currentDevices(): the system root
  first as "Computer", then browsable, readable volumes that live on a
  different device than the root (so /Volumes/<boot> → / is not listed
  twice), sorted by path. OS calls live in PlatformVolumes. }

unit Volumes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, PlatformVolumes;

type
  TVolumeInfo = record
    Path: string;
    Name: string;
    TotalBytes: QWord;
    { Swift VolumeCapacity.available: free space plus purgeable data,
      min(total, max(free, availableForImportantUsage)). }
    AvailableBytes: QWord;
  end;

  TVolumeInfoArray = array of TVolumeInfo;

function ListVolumes: TVolumeInfoArray;

type
  { OS answers ListVolumes needs, injectable for tests. }
  TVolumeProbe = record
    RootPath: string;
    RootCapacity: TVolumeCapacity;
    HasRootCapacity: Boolean;
    BootDevice: QWord;
    HasBootDevice: Boolean;
    Mounts: TMountInfoArray;
    Devices: array of QWord;        { per mount; 0 = unknown }
    Readable: array of Boolean;
    Capacities: array of TVolumeCapacity;
    HasCapacity: array of Boolean;
  end;

{ DeviceMonitor.swift currentDevices() filter over probed facts. }
function SelectVolumes(const Probe: TVolumeProbe): TVolumeInfoArray;

{ Models/DeviceInfo.swift VolumeCapacity.available. }
function AvailableBytesOf(const Capacity: TVolumeCapacity): Int64;

implementation

function AvailableBytesOf(const Capacity: TVolumeCapacity): Int64;
begin
  Result := Capacity.FreeBytes;
  if Capacity.AvailableForImportantUsage > Result then
    Result := Capacity.AvailableForImportantUsage;
  if Result > Capacity.TotalBytes then
    Result := Capacity.TotalBytes;
end;

procedure Append(var List: TVolumeInfoArray; const Path, Name: string;
  const Capacity: TVolumeCapacity);
var
  N: Integer;
begin
  N := Length(List);
  SetLength(List, N + 1);
  List[N].Path := Path;
  List[N].Name := Name;
  List[N].TotalBytes := QWord(Capacity.TotalBytes);
  List[N].AvailableBytes := QWord(AvailableBytesOf(Capacity));
end;

function SelectVolumes(const Probe: TVolumeProbe): TVolumeInfoArray;
var
  Name: string;
  I: Integer;
begin
  SetLength(Result, 0);
  if Probe.HasRootCapacity then
    Append(Result, Probe.RootPath, 'Computer', Probe.RootCapacity);
  for I := 0 to High(Probe.Mounts) do
  begin
    if not Probe.Mounts[I].Browsable then
      Continue;
    if Probe.Devices[I] = 0 then
      Continue;
    if Probe.HasBootDevice and (Probe.Devices[I] = Probe.BootDevice) then
      Continue;
    if not Probe.Readable[I] then
      Continue;
    if not Probe.HasCapacity[I] then
      Continue;
    Name := Probe.Mounts[I].Name;
    if Name = '' then
      Name := ExtractFileName(ExcludeTrailingPathDelimiter(Probe.Mounts[I].Path));
    Append(Result, Probe.Mounts[I].Path, Name, Probe.Capacities[I]);
  end;
end;

function ListVolumes: TVolumeInfoArray;
var
  Probe: TVolumeProbe;
  I, N: Integer;
begin
  Probe.RootPath := SystemRootPath;
  Probe.HasRootCapacity := VolumeCapacityOf(Probe.RootPath, Probe.RootCapacity);
  Probe.HasBootDevice := DeviceOfPath(Probe.RootPath, Probe.BootDevice);
  Probe.Mounts := EnumerateMounts;
  N := Length(Probe.Mounts);
  SetLength(Probe.Devices, N);
  SetLength(Probe.Readable, N);
  SetLength(Probe.Capacities, N);
  SetLength(Probe.HasCapacity, N);
  for I := 0 to N - 1 do
  begin
    if not DeviceOfPath(Probe.Mounts[I].Path, Probe.Devices[I]) then
      Probe.Devices[I] := 0;
    Probe.Readable[I] := IsReadablePath(Probe.Mounts[I].Path);
    Probe.HasCapacity[I] := VolumeCapacityOf(Probe.Mounts[I].Path,
      Probe.Capacities[I]);
  end;
  Result := SelectVolumes(Probe);
end;

end.
