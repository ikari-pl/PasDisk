{ PlatformVolumes — OS-specific mounted-volume primitives behind one interface.

  Darwin uses CoreFoundation's mounted-volume enumerator and URL resource
  keys (the CF side of FileManager.mountedVolumeURLs / URLResourceValues
  that OpenDisk DeviceMonitor.swift uses), falling back to statfs.
  Windows enumerates logical drives. Other Unix reports only the root. }

unit PlatformVolumes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TMountInfo = record
    Path: string;
    { Volume name as the OS presents it; empty when unknown. }
    Name: string;
    Browsable: Boolean;
  end;

  TMountInfoArray = array of TMountInfo;

  TVolumeCapacity = record
    TotalBytes: Int64;
    FreeBytes: Int64;
    { Free space including purgeable data the OS frees on demand;
      -1 when the platform cannot say. }
    AvailableForImportantUsage: Int64;
  end;

{ Mounted volumes the user would see in Finder (hidden volumes skipped),
  sorted by path. }
function EnumerateMounts: TMountInfoArray;

function VolumeCapacityOf(const Path: string; out Capacity: TVolumeCapacity): Boolean;

{ Device id of the file system holding Path (st_dev / volume serial). }
function DeviceOfPath(const Path: string; out Device: QWord): Boolean;

{ Device id that defines volume boundaries: DeviceOfPath, which follows
  symlinks like VolumeAttributes.swift deviceID(ofPath:); 0 when Path
  cannot be stat'ed. }
function VolumeDeviceOf(const Path: string): QWord;

function IsReadablePath(const Path: string): Boolean;

{ Root of the system volume: '/' on Unix, the Windows system drive. }
function SystemRootPath: string;

{ Mount point of the volume holding Path (statfs f_mntonname /
  GetVolumePathName); '' when the platform cannot say. }
function MountPointOf(const Path: string): string;

{ macOS writable data volume that firmlinks share with the system volume
  ('/System/Volumes/Data'); '' on other platforms. }
function DataVolumeMountPoint: string;

{ Where macOS mounts the boot volume group's other volumes (VM, Preboot,
  Update, ...: '/System/Volumes'); '' on other platforms. }
function SystemVolumesDirectory: string;

implementation

{$IFDEF DARWIN}
uses
  BaseUnix, CFBase, CFString, CFNumber, CFURL, CFURLEnumerator, CFError;

var
  kCFURLVolumeAvailableCapacityForImportantUsageKey: CFStringRef; cvar; external;

type
  TStatFS = record
    f_bsize: LongWord;
    f_iosize: LongInt;
    f_blocks: QWord;
    f_bfree: QWord;
    f_bavail: QWord;
    f_files: QWord;
    f_ffree: QWord;
    f_fsid: array[0..1] of LongInt;
    f_owner: LongWord;
    f_type: LongWord;
    f_flags: LongWord;
    f_fssubtype: LongWord;
    f_fstypename: array[0..15] of AnsiChar;
    f_mntonname: array[0..1023] of AnsiChar;
    f_mntfromname: array[0..1023] of AnsiChar;
    f_reserved: array[0..7] of LongWord;
  end;

{ The 64-bit-inode layout above; on Intel it is the $INODE64 variant. }
function c_statfs(path: PChar; var buf: TStatFS): Integer; cdecl;
  external 'c' name {$IFDEF CPUX86_64}'statfs$INODE64'{$ELSE}'statfs'{$ENDIF};

function URLForPath(const Path: string): CFURLRef;
begin
  Result := CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
    PChar(Path), Length(Path), True);
end;

function CopyString(URL: CFURLRef; Key: CFStringRef; out Value: string): Boolean;
var
  Ref: CFTypeRef;
  Buf: array[0..1023] of AnsiChar;
begin
  Value := '';
  Ref := nil;
  Result := CFURLCopyResourcePropertyForKey(URL, Key, @Ref, nil) and (Ref <> nil);
  if not Result then
    Exit;
  Result := CFStringGetCString(CFStringRef(Ref), @Buf[0], SizeOf(Buf),
    kCFStringEncodingUTF8);
  if Result then
    Value := StrPas(@Buf[0]);
  CFRelease(Ref);
end;

function CopyInt64(URL: CFURLRef; Key: CFStringRef; out Value: Int64): Boolean;
var
  Ref: CFTypeRef;
begin
  Value := 0;
  Ref := nil;
  Result := CFURLCopyResourcePropertyForKey(URL, Key, @Ref, nil) and (Ref <> nil);
  if not Result then
    Exit;
  Result := CFNumberGetValue(CFNumberRef(Ref), kCFNumberSInt64Type, @Value);
  CFRelease(Ref);
end;

function CopyBool(URL: CFURLRef; Key: CFStringRef; out Value: Boolean): Boolean;
var
  Ref: CFTypeRef;
begin
  Value := False;
  Ref := nil;
  Result := CFURLCopyResourcePropertyForKey(URL, Key, @Ref, nil) and (Ref <> nil);
  if not Result then
    Exit;
  Value := CFBooleanGetValue(CFBooleanRef(Ref));
  CFRelease(Ref);
end;

function EnumerateMounts: TMountInfoArray;
var
  Enum: CFURLEnumeratorRef;
  URL: CFURLRef;
  Err: CFErrorRef;
  Status: CFURLEnumeratorResult;
  Buf: array[0..1023] of AnsiChar;
  Info: TMountInfo;
  I, J, N, Guard: Integer;
  Tmp: TMountInfo;
begin
  Result := nil;
  Enum := CFURLEnumeratorCreateForMountedVolumes(kCFAllocatorDefault,
    kCFURLEnumeratorSkipInvisibles, nil);
  if Enum = nil then
    Exit;
  Guard := 0;
  try
    repeat
      { CF reports per-URL errors then End; the guard stops a stuck one. }
      Inc(Guard);
      if Guard > 10000 then
        Break;
      Err := nil;
      Status := CFURLEnumeratorGetNextURL(Enum, URL, Err);
      if Status <> kCFURLEnumeratorSuccess then
        Continue;
      if not CFURLGetFileSystemRepresentation(URL, True, @Buf[0], SizeOf(Buf)) then
        Continue;
      Info.Path := StrPas(@Buf[0]);
      CopyString(URL, kCFURLVolumeNameKey, Info.Name);
      CopyBool(URL, kCFURLVolumeIsBrowsableKey, Info.Browsable);
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Info;
    until Status = kCFURLEnumeratorEnd;
  finally
    CFRelease(Enum);
  end;
  for I := 1 to High(Result) do
  begin
    Tmp := Result[I];
    J := I - 1;
    while (J >= 0) and (Result[J].Path > Tmp.Path) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := Tmp;
  end;
end;

function VolumeCapacityOf(const Path: string; out Capacity: TVolumeCapacity): Boolean;
var
  URL: CFURLRef;
  Info: TStatFS;
  Total, Free, Important: Int64;
begin
  Capacity.TotalBytes := 0;
  Capacity.FreeBytes := 0;
  Capacity.AvailableForImportantUsage := -1;
  URL := URLForPath(Path);
  if URL <> nil then
  try
    if CopyInt64(URL, kCFURLVolumeTotalCapacityKey, Total) then
    begin
      Capacity.TotalBytes := Total;
      if CopyInt64(URL, kCFURLVolumeAvailableCapacityKey, Free) then
        Capacity.FreeBytes := Free;
      if CopyInt64(URL, kCFURLVolumeAvailableCapacityForImportantUsageKey,
        Important) then
        Capacity.AvailableForImportantUsage := Important;
      Exit(True);
    end;
  finally
    CFRelease(URL);
  end;
  Result := c_statfs(PChar(Path), Info) = 0;
  if Result then
  begin
    Capacity.TotalBytes := Int64(QWord(Info.f_bsize) * Info.f_blocks);
    Capacity.FreeBytes := Int64(QWord(Info.f_bsize) * Info.f_bavail);
  end;
end;

function DeviceOfPath(const Path: string; out Device: QWord): Boolean;
var
  Info: Stat;
begin
  Result := fpStat(PChar(Path), Info) = 0;
  if Result then
    Device := QWord(Info.st_dev)
  else
    Device := 0;
end;

function IsReadablePath(const Path: string): Boolean;
begin
  Result := fpAccess(PChar(Path), R_OK) = 0;
end;

function SystemRootPath: string;
begin
  Result := '/';
end;

function MountPointOf(const Path: string): string;
var
  Info: TStatFS;
begin
  if c_statfs(PChar(Path), Info) = 0 then
    Result := StrPas(@Info.f_mntonname[0])
  else
    Result := '';
end;

function DataVolumeMountPoint: string;
begin
  Result := '/System/Volumes/Data';
end;

function SystemVolumesDirectory: string;
begin
  Result := '/System/Volumes';
end;

{$ELSE}
{$IFDEF WINDOWS}
uses
  Windows;

function DriveIsBrowsable(const Root: string): Boolean;
begin
  Result := GetDriveTypeW(PWideChar(UnicodeString(Root))) in
    [DRIVE_FIXED, DRIVE_REMOVABLE, DRIVE_REMOTE];
end;

function EnumerateMounts: TMountInfoArray;
var
  Bits: DWORD;
  Drive: Char;
  Root: string;
  NameBuf: array[0..MAX_PATH] of WideChar;
  N: Integer;
begin
  SetLength(Result, 0);
  Bits := GetLogicalDrives;
  for Drive := 'A' to 'Z' do
    if (Bits and (1 shl (Ord(Drive) - Ord('A')))) <> 0 then
    begin
      Root := Drive + ':\';
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N].Path := Root;
      Result[N].Browsable := DriveIsBrowsable(Root);
      if GetVolumeInformationW(PWideChar(UnicodeString(Root)), @NameBuf[0],
        Length(NameBuf), nil, nil, nil, nil, 0) and (NameBuf[0] <> #0) then
        Result[N].Name := UTF8Encode(UnicodeString(PWideChar(@NameBuf[0])))
      else
        Result[N].Name := Drive + ':';
    end;
end;

function VolumeCapacityOf(const Path: string; out Capacity: TVolumeCapacity): Boolean;
var
  Caller, Total, Free: ULARGE_INTEGER;
begin
  Capacity.AvailableForImportantUsage := -1;
  Result := GetDiskFreeSpaceExW(PWideChar(UnicodeString(Path)), @Caller, @Total, @Free);
  if Result then
  begin
    Capacity.TotalBytes := Int64(Total.QuadPart);
    Capacity.FreeBytes := Int64(Caller.QuadPart);
  end
  else
  begin
    Capacity.TotalBytes := 0;
    Capacity.FreeBytes := 0;
  end;
end;

function DeviceOfPath(const Path: string; out Device: QWord): Boolean;
var
  Serial: DWORD;
begin
  Result := GetVolumeInformationW(
    PWideChar(UnicodeString(ExtractFileDrive(ExpandFileName(Path)) + '\')),
    nil, 0, @Serial, nil, nil, nil, 0);
  if Result then
    Device := Serial
  else
    Device := 0;
end;

function IsReadablePath(const Path: string): Boolean;
begin
  Result := DirectoryExists(Path);
end;

{ Not declared by FPC 3.2.2's Windows unit. }
function GetVolumePathNameW(lpszFileName: LPCWSTR; lpszVolumePathName: LPWSTR;
  cchBufferLength: DWORD): BOOL; stdcall; external 'kernel32' name 'GetVolumePathNameW';

function MountPointOf(const Path: string): string;
var
  Buf: array[0..MAX_PATH] of WideChar;
begin
  if GetVolumePathNameW(PWideChar(UnicodeString(Path)), @Buf[0], Length(Buf)) then
    Result := ExcludeTrailingPathDelimiter(UTF8Encode(UnicodeString(PWideChar(@Buf[0]))))
  else
    Result := '';
end;

function DataVolumeMountPoint: string;
begin
  Result := '';
end;

function SystemVolumesDirectory: string;
begin
  Result := '';
end;

function SystemRootPath: string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFileDrive(SysUtils.GetEnvironmentVariable('SystemRoot')));
  if Result = PathDelim then
    Result := 'C:\';
end;

{$ELSE}
uses
  BaseUnix;

function EnumerateMounts: TMountInfoArray;
begin
  SetLength(Result, 0);
end;

function VolumeCapacityOf(const Path: string; out Capacity: TVolumeCapacity): Boolean;
begin
  { Portable statfs is not wired yet (od-31j.29). }
  Capacity.TotalBytes := 0;
  Capacity.FreeBytes := 0;
  Capacity.AvailableForImportantUsage := -1;
  Result := False;
end;

function DeviceOfPath(const Path: string; out Device: QWord): Boolean;
var
  Info: Stat;
begin
  Result := fpStat(PChar(Path), Info) = 0;
  if Result then
    Device := QWord(Info.st_dev)
  else
    Device := 0;
end;

function IsReadablePath(const Path: string): Boolean;
begin
  Result := fpAccess(PChar(Path), R_OK) = 0;
end;

function SystemRootPath: string;
begin
  Result := '/';
end;

function MountPointOf(const Path: string): string;
begin
  { Portable statfs/mntent lookup is not wired yet (od-31j.29). }
  Result := '';
end;

function DataVolumeMountPoint: string;
begin
  Result := '';
end;

function SystemVolumesDirectory: string;
begin
  Result := '';
end;
{$ENDIF}
{$ENDIF}


function VolumeDeviceOf(const Path: string): QWord;
begin
  if not DeviceOfPath(Path, Result) then
    Result := 0;
end;

end.
