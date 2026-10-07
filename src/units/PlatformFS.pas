{ PlatformFS — OS-specific file-system primitives behind one interface.

  Callers stay free of IFDEFs and C externs: path resolution, file birth
  time, and wall-clock time in Unix seconds (UTC, like Swift's
  Date.timeIntervalSince1970). Each primitive reports when the platform
  cannot answer instead of guessing. }

unit PlatformFS;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ Canonical absolute path with symlinks and firmlinks resolved
  (/tmp -> /private/tmp on macOS). Falls back to ExpandFileName. }
function ResolveRealPath(const Path: string): string;

{ Absolute path with '.', '..' and trailing separators removed and, on
  macOS, a leading /private dropped when the shorter path exists — the
  NSString.standardizingPath rules OpenDisk ProtectedPaths.swift relies on
  (/private/var -> /var). Symlinks are not resolved. }
function StandardizePath(const Path: string): string;

{ The account's home directory from the user database (getpwuid), not
  $HOME — UserHome.swift. }
function UserHomePath: string;

{ Creation time of Path itself (symlinks not followed), Unix seconds UTC.
  False when the file is missing or the platform has no birth time. }
function FileBirthTime(const Path: string; out UnixSeconds: Double): Boolean;

{ On-disk allocation of the regular file at Path (symlinks not followed):
  st_blocks * 512 on Unix, GetCompressedFileSize on Windows. False for
  missing paths and non-regular files. }
function FileAllocatedSize(const Path: string; out Size: Int64): Boolean;

{ Current time from the OS real-time clock, Unix seconds UTC, microsecond
  precision (no local-time round trip). }
function UnixTimeNow: Double;

{ Modification time (Unix seconds UTC) and size of Path, following
  symlinks. False when Path cannot be stat'ed. }
function FileModifiedAndSize(const Path: string; out ModifiedUnix: Double;
  out Size: Int64): Boolean;

{ Allocation of a directory entry itself (lstat, never followed):
  st_blocks * 512 for regular files and symlinks, like getattrlistbulk
  ATTR_FILE_ALLOCSIZE; 0 for anything else or a missing path. }
function EntryAllocatedSize(const Path: string): Int64;

{ Path itself is a symbolic link (lstat; a reparse point on Windows). }
function IsSymLink(const Path: string): Boolean;

{ Hard-link identity of Path itself (lstat): device, inode / file index and
  link count. False when Path cannot be read. }
function FileIdentity(const Path: string; out Device, FileID: QWord;
  out LinkCount: LongWord): Boolean;

{ Per-user cache directory for AppName: ~/Library/Caches/<AppName> on
  macOS, the application config directory elsewhere. }
function AppCacheDirectory(const AppName: string): string;

{ Creates NewPath as a hard link to Existing (tests build hard-link
  fixtures with it). }
function CreateHardLink(const Existing, NewPath: string): Boolean;

implementation

{$IFDEF UNIX}
uses
  BaseUnix, Unix, DateUtils;

function c_realpath(file_name: PChar; resolved_name: PChar): PChar; cdecl;
  external 'c' name 'realpath';
{$ENDIF}

{$IFDEF DARWIN}
type
  { struct passwd, <pwd.h> on Darwin }
  TPasswd = record
    pw_name: PChar;
    pw_passwd: PChar;
    pw_uid: LongWord;
    pw_gid: LongWord;
    pw_change: Int64;
    pw_class: PChar;
    pw_gecos: PChar;
    pw_dir: PChar;
    pw_shell: PChar;
    pw_expire: Int64;
  end;
  PPasswd = ^TPasswd;

function c_getpwuid(uid: LongWord): PPasswd; cdecl; external 'c' name 'getpwuid';
{$ENDIF}

{$IFDEF WINDOWS}
uses
  Windows, DateUtils;

{ Not declared by FPC 3.2.2's Windows unit (WinBase.h). }
const
  FILE_FLAG_OPEN_REPARSE_POINT = $00200000;

function CreateHardLinkW(lpFileName, lpExistingFileName: LPCWSTR;
  lpSecurityAttributes: Pointer): BOOL; stdcall; external 'kernel32' name 'CreateHardLinkW';
{$ENDIF}

function ResolveRealPath(const Path: string): string;
{$IFDEF UNIX}
var
  Buf: array[0..4095] of Char;
{$ENDIF}
begin
  Result := ExpandFileName(Path);
  {$IFDEF UNIX}
  if c_realpath(PChar(Result), @Buf[0]) <> nil then
    Result := StrPas(@Buf[0]);
  {$ENDIF}
end;

function StandardizePath(const Path: string): string;
{$IFDEF DARWIN}
const
  PrivatePrefix = '/private/';
{$ENDIF}
begin
  Result := ExpandFileName(Path);
  while (Length(Result) > 1) and (Result[Length(Result)] = PathDelim) do
    SetLength(Result, Length(Result) - 1);
  {$IFDEF DARWIN}
  if (Copy(Result, 1, Length(PrivatePrefix)) = PrivatePrefix) and
     (FileExists(Copy(Result, Length('/private') + 1, MaxInt)) or
      DirectoryExists(Copy(Result, Length('/private') + 1, MaxInt))) then
    Result := Copy(Result, Length('/private') + 1, MaxInt);
  {$ENDIF}
end;

function UserHomePath: string;
{$IFDEF DARWIN}
var
  Entry: PPasswd;
{$ENDIF}
begin
  Result := '';
  {$IFDEF DARWIN}
  Entry := c_getpwuid(fpGetUID);
  if (Entry <> nil) and (Entry^.pw_dir <> nil) then
    Result := StrPas(Entry^.pw_dir);
  {$ENDIF}
  if Result = '' then
    Result := GetUserDir;
  Result := StandardizePath(Result);
end;

function FileBirthTime(const Path: string; out UnixSeconds: Double): Boolean;
{$IFDEF DARWIN}
var
  Info: Stat;
begin
  Result := fpLStat(PChar(Path), Info) = 0;
  if Result then
    UnixSeconds := Double(Info.st_birthtime) +
      Double(Info.st_birthtimensec) / Double(1e9)
  else
    UnixSeconds := 0;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  Data: TWin32FileAttributeData;
  Ticks: QWord;
const
  { 100 ns ticks between 1601-01-01 and 1970-01-01 }
  EpochDelta = QWord(116444736000000000);
begin
  Result := GetFileAttributesExW(PWideChar(UnicodeString(Path)),
    GetFileExInfoStandard, @Data);
  if Result then
  begin
    Ticks := (QWord(Data.ftCreationTime.dwHighDateTime) shl 32) or
      Data.ftCreationTime.dwLowDateTime;
    UnixSeconds := Double(Int64(Ticks) - Int64(EpochDelta)) / Double(1e7);
  end
  else
    UnixSeconds := 0;
end;
{$ELSE}
begin
  { Linux statx birth time is not wired yet; callers must treat unknown
    as "not provably new". }
  UnixSeconds := 0;
  Result := False;
end;
{$ENDIF}
{$ENDIF}

function FileAllocatedSize(const Path: string; out Size: Int64): Boolean;
{$IFDEF UNIX}
var
  Info: Stat;
begin
  Size := 0;
  Result := (fpLStat(PChar(Path), Info) = 0) and fpS_ISREG(Info.st_mode);
  if Result then
    Size := Int64(Info.st_blocks) * 512;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  High_: DWORD;
  Low_: DWORD;
  Attr: DWORD;
begin
  Size := 0;
  Attr := GetFileAttributesW(PWideChar(UnicodeString(Path)));
  Result := (Attr <> INVALID_FILE_ATTRIBUTES) and
    ((Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) = 0);
  if not Result then
    Exit;
  Low_ := GetCompressedFileSizeW(PWideChar(UnicodeString(Path)), @High_);
  Result := not ((Low_ = INVALID_FILE_SIZE) and (GetLastError <> NO_ERROR));
  if Result then
    Size := (Int64(High_) shl 32) or Low_;
end;
{$ELSE}
begin
  Size := 0;
  Result := False;
end;
{$ENDIF}
{$ENDIF}

function UnixTimeNow: Double;
{$IFDEF UNIX}
var
  TV: TTimeVal;
begin
  if fpgettimeofday(@TV, nil) = 0 then
    Result := Double(TV.tv_sec) + Double(TV.tv_usec) / Double(1e6)
  else
    Result := (LocalTimeToUniversal(Now) - UnixDateDelta) * SecsPerDay;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  FT: TFileTime;
  Ticks: QWord;
const
  EpochDelta = QWord(116444736000000000);
begin
  GetSystemTimeAsFileTime(FT);
  Ticks := (QWord(FT.dwHighDateTime) shl 32) or FT.dwLowDateTime;
  Result := Double(Int64(Ticks) - Int64(EpochDelta)) / Double(1e7);
end;
{$ELSE}
begin
  Result := (LocalTimeToUniversal(Now) - UnixDateDelta) * SecsPerDay;
end;
{$ENDIF}
{$ENDIF}

function FileModifiedAndSize(const Path: string; out ModifiedUnix: Double;
  out Size: Int64): Boolean;
{$IFDEF UNIX}
var
  Info: Stat;
begin
  ModifiedUnix := 0;
  Size := 0;
  Result := fpStat(PChar(Path), Info) = 0;
  if not Result then
    Exit;
  { The nanosecond field is st_mtimensec on Darwin/BSD, st_mtime_nsec on
    Linux. }
  ModifiedUnix := Double(Info.st_mtime) +
    Double({$IFDEF LINUX}Info.st_mtime_nsec{$ELSE}Info.st_mtimensec{$ENDIF}) / Double(1e9);
  Size := Info.st_size;
end;
{$ELSE}
var
  Rec: TSearchRec;
begin
  ModifiedUnix := 0;
  Size := 0;
  Result := FindFirst(Path, faAnyFile, Rec) = 0;
  if not Result then
    Exit;
  { TSearchRec.TimeStamp is local time. }
  ModifiedUnix := (LocalTimeToUniversal(Rec.TimeStamp) - UnixDateDelta) * SecsPerDay;
  Size := Rec.Size;
  SysUtils.FindClose(Rec);
end;
{$ENDIF}

function IsSymLink(const Path: string): Boolean;
{$IFDEF UNIX}
var
  Info: Stat;
begin
  Result := (fpLStat(PChar(Path), Info) = 0) and fpS_ISLNK(Info.st_mode);
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  Attr: DWORD;
begin
  Attr := GetFileAttributesW(PWideChar(UnicodeString(Path)));
  Result := (Attr <> INVALID_FILE_ATTRIBUTES) and
    ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}
{$ENDIF}

function EntryAllocatedSize(const Path: string): Int64;
{$IFDEF UNIX}
var
  Info: Stat;
begin
  Result := 0;
  if fpLStat(PChar(Path), Info) <> 0 then
    Exit;
  if fpS_ISREG(Info.st_mode) or fpS_ISLNK(Info.st_mode) then
    Result := Int64(Info.st_blocks) * 512;
end;
{$ELSE}
{ FindFirst wraps FindFirstFileW, which reports the directory entry itself
  and never follows a reparse point: a symlink or junction yields its own
  (zero) size, and a directory-like link is skipped as a directory. }
var
  Rec: TSearchRec;
begin
  Result := 0;
  if FindFirst(Path, faAnyFile, Rec) = 0 then
  begin
    if (Rec.Attr and faDirectory) = 0 then
      Result := Rec.Size;
    SysUtils.FindClose(Rec);
  end;
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
  { OPEN_REPARSE_POINT: identify a symlink / junction itself, not its
    target (lstat semantics). }
  Handle := CreateFile(PChar(Path), 0, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT, 0);
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

function AppCacheDirectory(const AppName: string): string;
begin
  {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(GetUserDir) + 'Library/Caches/' + AppName;
  {$ELSE}
  Result := ExcludeTrailingPathDelimiter(GetAppConfigDir(False));
  {$ENDIF}
end;

function CreateHardLink(const Existing, NewPath: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := fpLink(PChar(Existing), PChar(NewPath)) = 0;
  {$ELSE}
  {$IFDEF WINDOWS}
  Result := CreateHardLinkW(PWideChar(UnicodeString(NewPath)),
    PWideChar(UnicodeString(Existing)), nil);
  {$ELSE}
  Result := False;
  {$ENDIF}
  {$ENDIF}
end;

end.
