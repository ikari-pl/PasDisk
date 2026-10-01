{ OpenDisk DirReader — portable directory listing.

  Baseline uses SysUtils.FindFirst plus platform size probes so the same
  scanner builds on macOS, Linux, and Windows. A Darwin getattrlistbulk
  fast path can replace ReadDirectory later without changing Traversal. }

unit DirReader;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

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

function DeviceIDOfPath(const Path: string): QWord;
function IsVolumeRoot(const Path: string): Boolean;
function ReadDirectory(const Path: string; const AllowedDevices: TStringList;
  RestrictDevice: Boolean; ExpectedDevice: QWord): TDirectoryReadResult;

implementation

{$IFDEF UNIX}
uses
  BaseUnix, Unix;
{$ENDIF}
{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

function DeviceIDOfPath(const Path: string): QWord;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  Result := 0;
  if FpLstat(Path, Info) = 0 then
    Result := QWord(Info.st_dev);
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  Handle: THandle;
  Info: BY_HANDLE_FILE_INFORMATION;
begin
  Result := 0;
  Handle := CreateFile(PChar(Path), 0, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
    Exit;
  try
    if GetFileInformationByHandle(Handle, Info) then
      Result := (QWord(Info.dwVolumeSerialNumber));
  finally
    CloseHandle(Handle);
  end;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}
{$ENDIF}

function IsVolumeRoot(const Path: string): Boolean;
var
  Expanded, Parent: string;
begin
  Expanded := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  if Expanded = '' then
    Exit(True);
  Parent := ExtractFileDir(Expanded);
  if Parent = Expanded then
    Exit(True);
  Result := DeviceIDOfPath(Expanded) <> DeviceIDOfPath(Parent);
end;

function AllocatedSizeOf(const Path: string): Int64;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  Result := 0;
  if FpLstat(Path, Info) = 0 then
  begin
    if (Info.st_mode and S_IFMT) = S_IFREG then
      Result := Int64(Info.st_blocks) * 512
    else
      Result := 0;
  end;
end;
{$ELSE}
begin
  Result := 0;
  if FileExists(Path) then
    Result := FileSize(Path);
end;
{$ENDIF}

function FileIdentity(const Path: string; out Device, FileID: QWord;
  out LinkCount: LongWord): Boolean;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  Result := False;
  Device := 0;
  FileID := 0;
  LinkCount := 1;
  if FpLstat(Path, Info) <> 0 then
    Exit;
  Device := QWord(Info.st_dev);
  FileID := QWord(Info.st_ino);
  LinkCount := Info.st_nlink;
  Result := True;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  Handle: THandle;
  Info: BY_HANDLE_FILE_INFORMATION;
begin
  Result := False;
  Device := 0;
  FileID := 0;
  LinkCount := 1;
  Handle := CreateFile(PChar(Path), 0, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
    Exit;
  try
    if not GetFileInformationByHandle(Handle, Info) then
      Exit;
    Device := QWord(Info.dwVolumeSerialNumber);
    FileID := (QWord(Info.nFileIndexHigh) shl 32) or QWord(Info.nFileIndexLow);
    LinkCount := Info.nNumberOfLinks;
    Result := True;
  finally
    CloseHandle(Handle);
  end;
end;
{$ELSE}
begin
  Result := False;
  Device := 0;
  FileID := 0;
  LinkCount := 1;
end;
{$ENDIF}
{$ENDIF}

procedure AppendFile(var Contents: TDirectoryContents; const Entry: TDirFileEntry);
var
  N: Integer;
begin
  N := Length(Contents.Files);
  SetLength(Contents.Files, N + 1);
  Contents.Files[N] := Entry;
end;

procedure AppendName(var Names: TStringDynArray; const Name: string);
var
  N: Integer;
begin
  N := Length(Names);
  SetLength(Names, N + 1);
  Names[N] := Name;
end;

function IsSymLinkAttr(Attr: LongInt): Boolean;
begin
  {$IFDEF UNIX}
  Result := (Attr and faSymLink) <> 0;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function ReadDirectory(const Path: string; const AllowedDevices: TStringList;
  RestrictDevice: Boolean; ExpectedDevice: QWord): TDirectoryReadResult;
var
  Search: TSearchRec;
  Code: Integer;
  Prefix, ChildPath: string;
  Entry: TDirFileEntry;
  Dev, FileID: QWord;
  Links: LongWord;
  ChildDev: QWord;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := drkUnreadable;
  SetLength(Result.Contents.Files, 0);
  SetLength(Result.Contents.SubdirectoryNames, 0);
  SetLength(Result.Contents.MountPointNames, 0);

  Result.Device := DeviceIDOfPath(Path);
  if Result.Device = 0 then
    Exit;
  if RestrictDevice and (Result.Device <> ExpectedDevice) then
  begin
    Result.Kind := drkCrossesDevice;
    Exit;
  end;

  Prefix := IncludeTrailingPathDelimiter(Path);
  Code := FindFirst(Prefix + AllFilesMask, faAnyFile, Search);
  if Code <> 0 then
    Exit;
  try
    Result.Kind := drkContents;
    while Code = 0 do
    begin
      if (Search.Name <> '.') and (Search.Name <> '..') then
      begin
        ChildPath := Prefix + Search.Name;
        if (Search.Attr and faDirectory) <> 0 then
        begin
          if not IsSymLinkAttr(Search.Attr) then
          begin
            ChildDev := DeviceIDOfPath(ChildPath);
            if (ChildDev <> 0) and (ChildDev <> Result.Device) then
              AppendName(Result.Contents.MountPointNames, Search.Name)
            else
              AppendName(Result.Contents.SubdirectoryNames, Search.Name);
          end;
        end
        else if not IsSymLinkAttr(Search.Attr) then
        begin
          Entry.Name := Search.Name;
          Entry.Size := AllocatedSizeOf(ChildPath);
          if FileIdentity(ChildPath, Dev, FileID, Links) then
          begin
            Entry.Device := Dev;
            Entry.FileID := FileID;
            Entry.LinkCount := Links;
          end
          else
          begin
            Entry.Device := Result.Device;
            Entry.FileID := 0;
            Entry.LinkCount := 1;
          end;
          AppendFile(Result.Contents, Entry);
        end;
      end;
      Code := FindNext(Search);
    end;
  finally
    FindClose(Search);
  end;
end;

end.
