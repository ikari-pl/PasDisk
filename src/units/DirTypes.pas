{ DirTypes — results of reading one directory (portable, no OS code).

  Shared by PlatformDirReader and its callers; ported from the types of
  OpenDisk BulkDirectoryReader.swift. }

unit DirTypes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TStringDynArray = array of string;

  TDirFileEntry = record
    Name: string;
    Size: Int64;
    FileID: QWord;
    LinkCount: LongWord;
    Device: QWord;
  end;

  TDirectoryContents = record
    Files: array of TDirFileEntry;
    SubdirectoryNames: TStringDynArray;
    MountPointNames: TStringDynArray;
  end;

  TDirectoryReadKind = (drkContents, drkCrossesDevice, drkUnreadable);

  TDirectoryReadResult = record
    Kind: TDirectoryReadKind;
    Contents: TDirectoryContents;
    Device: QWord;
  end;

type
  { st_dev values a read may enter (Swift Set<dev_t>); empty = any. }
  TDeviceSet = array of QWord;

function DeviceInSet(const Devices: TDeviceSet; Device: QWord): Boolean;
procedure IncludeDevice(var Devices: TDeviceSet; Device: QWord);

implementation

function DeviceInSet(const Devices: TDeviceSet; Device: QWord): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Devices) do
    if Devices[I] = Device then
      Exit(True);
  Result := False;
end;

procedure IncludeDevice(var Devices: TDeviceSet; Device: QWord);
begin
  if (Device = 0) or DeviceInSet(Devices, Device) then
    Exit;
  SetLength(Devices, Length(Devices) + 1);
  Devices[High(Devices)] := Device;
end;

end.
